-- TODO - Add texture dropdown options
-- Currently too slow both in window creation and when clicking around in the style list

local ui = require("ui")
local uiElements = require("ui.elements")
local uiUtils = require("ui.utils")

local utils = require("utils")
local loadedState = require("loaded_state")
local configs = require("configs")
local persistence = require("persistence")
local keyboardHelper = require("utils.keyboard")
local languageRegistry = require("language_registry")
local stylegroundEditor = require("ui.styleground_editor")
local history = require("history")
local snapshotStruct = require("structs.snapshot")
local listWidgets = require("ui.widgets.lists")
local splitter = require("ui.widgets.splitter")
local widgetUtils = require("ui.widgets.utils")
local formHelper = require("ui.forms.form")
local parallax = require("parallax")
local effects = require("effects")
local apply = require("apply")
local applyStruct = require("structs.apply")
local parallaxStruct = require("structs.parallax")
local effectStruct = require("structs.effect")
local formUtils = require("ui.utils.forms")
local atlases = require("atlases")
local stylegroundPreviewData = require("styleground_preview")
local logging = require("logging")

local form = require("ui.forms.form")
local tabbedWindow = require("ui.widgets.tabbed_window")
local notifications = require("ui.notification")
local dropdowns = require("ui.widgets.dropdown")

local windowPersister = require("ui.window_position_persister")
local windowPersisterName = "stylegrounds_window"
local hoverPreviewModule = require("ui.hover_preview")

local stylegroundWindow = {}

-- Separate hover preview for the small otherTexture cells. The tools window keeps hiding the
-- shared instance whenever its own list is not hovered, so this panel needs its own.
local cellHoverPreview = hoverPreviewModule.create()
local cellHoverPreviewOwned = false

-- Runtime-only memory of the last selected style per tab. This intentionally stays in memory so
-- reopening the panel can restore the row without writing anything to disk.
local lastSelectedStylegrounds = {}
local restoringStylegroundSelection = false

local parallaxTextureOptions

local stylegroundWindowGroup = uiElements.group({})

-- TODO - Layouting variables that should be more dyanmic
local PREVIEW_MAX_WIDTH = 320 * 3
local PREVIEW_MAX_HEIGHT = 180 * 3
local WINDOW_STATIC_HEIGHT = 640

local updateStylegroundWindowHeight

local function cacheParallaxTextureOptions()
    local options = parallax.getParallaxNames()

    table.sort(options)

    parallaxTextureOptions = options
end

local function addFolderIndent(text)
    return " - " .. text
end

local function applyItemIconClick(listItem, button)
    if button ~= 1 then
        return false
    end

    local interactionData = listItem.parent.interactionData
    local style = listItem.data.style

    style._collapsed = not style._collapsed

    interactionData.rebuildListItems()
end

local function getStylegroundItems(targets, items, foreground, parent)
    local language = languageRegistry.getLanguage()
    local groupIndex = 1

    items = items or {}

    for _, style in ipairs(targets) do
        local styleType = utils.typeof(style)

        if styleType == "parallax" then
            local displayName = parallax.displayName(language, style)

            table.insert(items, {
                text = displayName,
                data = {
                    style = style,
                    parentStyle = parent,
                    foreground = foreground,
                }
            })

        elseif styleType == "effect" then
            local displayName = effects.displayName(language, style)

            table.insert(items, {
                text = displayName,
                data = {
                    style = style,
                    parentStyle = parent,
                    foreground = foreground,
                }
            })

        elseif styleType == "apply" then
            if style.children then
                local childItems = getStylegroundItems(style.children, {}, foreground, style)

                local groupText = apply.displayName(language, style, groupIndex)
                local groupLabel = uiElements.label(groupText)
                local listItemData = {
                    style = style,
                    parentStyle = parent,
                    foreground = foreground,
                }

                local collapsed = style._collapsed
                local iconName = collapsed and "hidden" or "visible"

                table.insert(items, {
                    text = groupLabel,
                    data = listItemData,
                    icon = iconName,
                    iconClicked = applyItemIconClick
                })

                if not collapsed then
                    for _, child in ipairs(childItems) do
                        child.text = addFolderIndent(child.text)

                        table.insert(items, child)
                    end
                end

                groupIndex += 1
            end
        end
    end

    return items
end

-- Refreshes the row texts of the open list, e.g. after a name or texture change. Group names are
-- numbered per parent, mirroring how the rows are built.
local function updateListRowTexts(interactionData)
    local list = interactionData and interactionData.stylegroundListElement

    if not list then
        return
    end

    local language = languageRegistry.getLanguage()
    local groupCounters = {}

    for _, item in ipairs(list.children or {}) do
        local data = item.data
        local style = data and data.style

        if style and item.label then
            local styleType = utils.typeof(style)
            local text

            if styleType == "apply" then
                local key = data.parentStyle or false

                groupCounters[key] = (groupCounters[key] or 0) + 1
                text = tostring(apply.displayName(language, style, groupCounters[key]))

            elseif styleType == "parallax" then
                text = tostring(parallax.displayName(language, style))

            elseif styleType == "effect" then
                text = tostring(effects.displayName(language, style))
            end

            if text then
                -- Rows inside a group are indented, keep that when replacing the text
                if data.parentStyle then
                    text = addFolderIndent(text)
                end

                item.label.text = text
                item.label:repaint()
                item:repaint()
            end
        end
    end
end

local function getHandler(style)
    local styleType = utils.typeof(style)

    if styleType == "parallax" then
        return parallax

    elseif styleType == "effect" then
        return effects

    elseif styleType == "apply" then
        return apply
    end
end

local function getOptions(style)
    local handler = getHandler(style)
    local prepareOptions = {
        namePath = {"attribute"},
        tooltipPath = {"description"}
    }
    local dummyData, fieldInformation, fieldOrder = formUtils.prepareFormData(handler, style, prepareOptions, {style})
    local options = {
        fields = fieldInformation,
        fieldOrder = fieldOrder
    }

    -- Add cached texture options
    if utils.typeof(style) == "parallax" then
        options.fields.texture.options = parallaxTextureOptions
    end

    return options, dummyData
end

-- Returns a description of what the preview box should show:
--   sprite   - sprite meta for the big preview (image/quad/layer/real size)
--   textures - sprite metas for the extra texture cells
--   label    - text shown when there is nothing to draw
function stylegroundWindow.getStylegroundPreview(interactionData)
    local language = languageRegistry.getLanguage()
    local formData = interactionData.formData
    local listTarget = interactionData.listTarget
    local style = listTarget and listTarget.style or {}
    local styleType = utils.typeof(style)

    -- Not ready yet: still show a placeholder, otherwise the preview container has no content at
    -- all and keeps a zero size
    if not formData then
        return {label = tostring(language.ui.styleground_window.preview.no_preview)}
    end

    if styleType == "parallax" then
        local sprite = atlases.getResource(formData.texture)

        if sprite then
            return {sprite = sprite, color = formData.color}
        end

        return {label = tostring(language.ui.styleground_window.preview.unknown_texture)}
    end

    if styleType == "effect" then
        local entry = stylegroundPreviewData.getEntry(style._name)
        local sprite = stylegroundPreviewData.getPreviewSprite(entry, formData)
        local textures = stylegroundPreviewData.getOtherTextures(entry, formData)

        -- Static preview images are only a reference; attribute previews reflect the real values.
        -- The placeholder is not a real preview, so it does not get the warning either.
        local staticPreview = stylegroundPreviewData.getPreviewType(entry) == "image"
            and sprite ~= stylegroundPreviewData.getPlaceholderSprite()

        if sprite then
            return {sprite = sprite, textures = textures, staticPreview = staticPreview}
        end

        return {
            label = tostring(formData.texture or formData._name or language.ui.styleground_window.preview.no_preview),
            textures = textures
        }
    end

    return {label = tostring(formData.texture or formData._name or language.ui.styleground_window.preview.no_preview)}
end

local PREVIEW_BOX_WIDTH = 640
local PREVIEW_BOX_HEIGHT = 360
local PREVIEW_CELL_ROWS = 6
local PREVIEW_CELL_GAP = 6
local PREVIEW_GRID_GAP = 14
local PREVIEW_MARGIN_TOP = 8
local PREVIEW_MARGIN_RIGHT = 8

-- RenogareSoft with a CJK fallback, used only for the small "reference only" caption
local warningFonts = {}

local function getWarningFont(size)
    local cached = warningFonts[size]

    if cached ~= nil then
        return cached or nil
    end

    local success, font = pcall(love.graphics.newFont, "assets/fonts/RenogareSoft-Regular.ttf", size)

    if not success or not font then
        warningFonts[size] = false

        return nil
    end

    local fontsOk, fonts = pcall(require, "fonts")

    if fontsOk and fonts and fonts.addCJKFallback then
        fonts.addCJKFallback(font, size)
    end

    warningFonts[size] = font

    return font
end

-- The hover preview is attached above every window. Done lazily: the UI root can be rebuilt by a
-- UI reload while the window stays open.
local function ensureCellHoverPreviewAttached()
    local previewWindow = cellHoverPreview.getWindow()

    if ui.root and previewWindow and previewWindow.parent ~= ui.root then
        ui.root:addChild(previewWindow)
    end
end

local function hideCellHoverPreview()
    if cellHoverPreviewOwned then
        cellHoverPreview.hide()
    end

    cellHoverPreviewOwned = false
end

local function showCellHoverPreview(cell)
    local sprite = cell and cell._cellSprite

    if not sprite or not sprite.image then
        hideCellHoverPreview()

        return
    end

    local label = cell._cellLabel
    local parent = cell.parent
    local frameX = (parent and parent.screenX or 0) + (cell._cellFrameX or 0)
    local frameY = (parent and parent.screenY or 0) + (cell._cellFrameY or 0)
    local frameHeight = cell._cellFrameSize or cell.height or 0

    ensureCellHoverPreviewAttached()

    cellHoverPreview.show(frameX, frameY, frameHeight, {
        image = sprite.image,
        quad = sprite.quad,
        layer = sprite.layer,
        width = sprite.width,
        height = sprite.height,
        title = tostring(label or "Texture"),
        key = string.format("othertexture:%s:%s", tostring(sprite.image), tostring(label)),
        area = 90000,
        maxWidth = 440,
        maxHeight = 460
    })

    cellHoverPreviewOwned = true
end

local function clearChildren(element)
    while element.children and #element.children > 0 do
        element:removeChild(element.children[1])
    end
end

-- TODO - Improve in the future
-- We can most likely reuse a previous image or label, but this works for now
function stylegroundWindow.updateStylegroundPreview(interactionData)
    local previewContainer = interactionData.stylegroundPreviewGroup

    if not previewContainer then
        return
    end

    local preview = stylegroundWindow.getStylegroundPreview(interactionData)

    clearChildren(previewContainer)
    hideCellHoverPreview()

    if preview.sprite then
        local sprite = preview.sprite
        local imageElement = uiElements.image(sprite.image, sprite.quad, sprite.layer)

        -- The container positions and scales it: the sprite is drawn as a child element, so it
        -- follows the normal element transforms instead of raw screen coordinates
        imageElement._previewSprite = sprite
        imageElement._previewColor = preview.color
        imageElement.scaleRoundAuto = false

        previewContainer:addChild(imageElement)

        if sprite.animation and #sprite.animation.frames > 1 then
            previewContainer._previewAnimation = {
                animation = sprite.animation,
                element = imageElement,
                index = 1,
                time = 0
            }

        else
            previewContainer._previewAnimation = nil
        end
    end

    if preview.sprite and preview.staticPreview then
        local language = languageRegistry.getLanguage()
        local uiScale = configs.ui.theme.uiScale or 1
        local warningFont = getWarningFont(math.max(8, math.floor(14 * uiScale)))
        local warning = uiElements.label(tostring(language.ui.styleground_window.preview.static_warning),
            warningFont)

        warning._previewWarning = true
        warning._warningOutline = math.max(1, math.floor(uiScale))
        warning.interactive = -1
        warning.style.color = {1, 1, 1, 0.8}

        -- Draw an outline manually: a plain label becomes unreadable on bright preview images
        warning:hook({
            draw = function(orig, self, ...)
                local font = self.style.font
                local text = self._textStr
                local outline = self._warningOutline or 1
                local x, y = self.screenX, self.screenY
                local previousFont = love.graphics.getFont()

                love.graphics.setFont(font)
                uiUtils.setColor(0, 0, 0, 0.85)

                -- Four directions only: eight copies looked muddy at small sizes
                love.graphics.print(text, x - outline, y)
                love.graphics.print(text, x + outline, y)
                love.graphics.print(text, x, y - outline)
                love.graphics.print(text, x, y + outline)

                local color = self.style.color

                uiUtils.setColor(color[1], color[2], color[3], color[4])
                love.graphics.print(text, x, y)
                love.graphics.setFont(previousFont)

                return true
            end
        })

        previewContainer:addChild(warning)
    end

    for _, texture in ipairs(preview.textures or {}) do
        local sprite = texture.sprite or texture
        local cell = uiElements.group({})
        local image = uiElements.image(sprite.image, sprite.quad, sprite.layer)

        image.interactive = -1
        image.scaleRoundAuto = false
        cell:addChild(image)

        cell._previewCell = true
        cell._cellSprite = sprite
        cell._cellLabel = texture.label
        cell._cellImage = image
        cell.interactive = 1
        cell.cacheable = false
        cell.onEnter = showCellHoverPreview
        cell.onLeave = hideCellHoverPreview
        cell.calcSize = function(self)
            local size = self._cellFrameSize or 1

            self.width = size
            self.height = size
        end

        previewContainer:addChild(cell)
    end

    if not preview.sprite and preview.label then
        previewContainer._previewAnimation = nil
        previewContainer:addChild(uiElements.label(preview.label))
    end

    -- Fill the top right area with a fixed size box and scale the preview into it (aspect
    -- preserved, centered). Extra textures are laid out in cells to the right of that box.
    if not previewContainer._previewHooked then
        previewContainer._previewHooked = true

        previewContainer:hook({
            update = function(orig, self, dt)
                if orig then
                    orig(self, dt)
                end

                local animation = self._previewAnimation

                if not animation or not animation.element then
                    return
                end

                local frames = animation.animation.frames

                if #frames < 2 then
                    return
                end

                animation.time = animation.time + (dt or 0)

                local delay = animation.animation.delays[animation.index] or 0.1

                while animation.time >= delay do
                    animation.time = animation.time - delay
                    animation.index = animation.index % #frames + 1

                    animation.element.image = frames[animation.index]
                    animation.element:repaint()

                    delay = animation.animation.delays[animation.index] or 0.1
                end
            end,

            layoutLate = function(orig, self, ...)
                orig(self, ...)

                local parent = self.parent

                if not parent then
                    return
                end

                local availableWidth = parent.innerWidth or 0

                if availableWidth <= 0 then
                    return
                end

                local uiScale = configs.ui.theme.uiScale or 1
                local marginTop = PREVIEW_MARGIN_TOP * uiScale
                local marginRight = PREVIEW_MARGIN_RIGHT * uiScale
                local originX, originY = 0, marginTop
                local previewChild
                local warning
                local cells = {}

                for _, child in ipairs(self.children or {}) do
                    if child._previewSprite then
                        previewChild = child

                    elseif child._previewCell then
                        table.insert(cells, child)

                    elseif child._previewWarning then
                        warning = child
                    end
                end

                if not previewChild then
                    -- No preview content: keep only a compact placeholder instead of taking half
                    -- of the window away from the form.
                    local height = math.floor(48 * uiScale) + math.floor(marginTop)
                    local width = math.min(availableWidth, 640)

                    if self.width ~= width or self.height ~= height then
                        self.width = width
                        self.height = height
                    end

                    -- Drop the previous selection's frames, otherwise they would still be drawn
                    -- for a row that has no preview at all
                    self._previewOriginX = nil
                    self._previewOriginY = nil
                    self._previewBoxWidth = nil
                    self._previewBoxHeight = nil
                    self._previewImageX = nil
                    self._previewImageY = nil
                    self._previewImageWidth = nil
                    self._previewImageHeight = nil
                    self._previewWarningRect = nil

                    return
                end

                local sprite = previewChild._previewSprite
                local realWidth = sprite.realWidth or sprite.width or 0
                local realHeight = sprite.realHeight or sprite.height or 0

                if realWidth <= 0 or realHeight <= 0 then
                    return
                end

                local boxWidth = math.min(PREVIEW_BOX_WIDTH * uiScale,
                    math.max(1, availableWidth - marginRight))
                local boxHeight = PREVIEW_BOX_HEIGHT * uiScale

                -- Scale the original rectangle to fit the fixed preview box
                local scale = math.min(boxWidth / realWidth, boxHeight / realHeight)
                scale = math.max(scale, 0.01)

                previewChild.scaleX = scale
                previewChild.scaleY = scale

                -- Place the trimmed content inside the original rectangle. The atlas stores the
                -- trim as "position minus offset", so the draw offset is minus the stored value.
                -- Without offset information the trim is assumed to be symmetric.
                local offsetX = sprite.offsetX or 0
                local offsetY = sprite.offsetY or 0
                local contentWidth, contentHeight

                if sprite.quad then
                    local _, _, width, height = sprite.quad:getViewport()
                    contentWidth, contentHeight = width, height

                else
                    contentWidth, contentHeight = sprite.width, sprite.height
                end

                contentWidth = contentWidth or realWidth
                contentHeight = contentHeight or realHeight

                local childX, childY

                if offsetX ~= 0 then
                    childX = (boxWidth - realWidth * scale) / 2 - offsetX * scale

                else
                    childX = (boxWidth - contentWidth * scale) / 2
                end

                if offsetY ~= 0 then
                    childY = (boxHeight - realHeight * scale) / 2 - offsetY * scale

                else
                    childY = (boxHeight - contentHeight * scale) / 2
                end

                previewChild.x = math.floor(childX) + originX
                previewChild.y = math.floor(childY) + originY

                -- Also set the real position: the element layout may not run again before the
                -- next draw
                previewChild.realX = previewChild.x
                previewChild.realY = previewChild.y

                -- Frame the original (untrimmed) image rectangle. Atlas sprites may be trimmed,
                -- and framing only the trimmed quad would make the blue box smaller than the
                -- source image and drop the empty margins around it.
                local imageWidth = math.max(1, math.floor(realWidth * scale))
                local imageHeight = math.max(1, math.floor(realHeight * scale))

                self._previewImageX = math.floor((boxWidth - imageWidth) / 2) + originX
                self._previewImageY = math.floor((boxHeight - imageHeight) / 2) + originY
                self._previewImageWidth = imageWidth
                self._previewImageHeight = imageHeight
                self._previewOriginX = originX
                self._previewOriginY = originY

                local color = previewChild._previewColor

                if color then
                    local success, r, g, b, a = utils.parseHexColor(color)

                    if success then
                        previewChild.style.color = {r, g, b, a}
                    end
                end

                -- Extra texture cells: fill top to bottom, then continue with the next column.
                -- The cell size is derived from the box height so that exactly PREVIEW_CELL_ROWS
                -- cells (plus the gaps between them) fill the preview area.
                local cellGap = PREVIEW_CELL_GAP * uiScale
                local gridGap = PREVIEW_GRID_GAP * uiScale
                local rows = math.max(1, PREVIEW_CELL_ROWS)
                local cellSize = math.max(1, (boxHeight - (rows - 1) * cellGap) / rows)
                local columns = math.ceil(#cells / rows)

                for index, cell in ipairs(cells) do
                    local column = math.floor((index - 1) / rows)
                    local row = (index - 1) % rows
                    local cellX = originX + boxWidth + gridGap + column * (cellSize + cellGap)
                    local cellY = originY + row * (cellSize + cellGap)
                    local cellSprite = cell._cellSprite or {}
                    local cellWidth = cellSprite.width or 0
                    local cellHeight = cellSprite.height or 0

                    if cellSprite.quad then
                        local _, _, width, height = cellSprite.quad:getViewport()
                        cellWidth, cellHeight = width, height
                    end

                    cellWidth = math.max(1, cellWidth)
                    cellHeight = math.max(1, cellHeight)

                    -- Small textures get a 3x boost so they are readable, but the result is still
                    -- capped to the cell. Textures that do not fit are shrunk.
                    local cellScale = math.min(3, (cellSize - 4) / cellWidth, (cellSize - 4) / cellHeight)
                    cellScale = math.max(cellScale, 0.01)

                    local image = cell._cellImage
                    local frameX = math.floor(cellX)
                    local frameY = math.floor(cellY)
                    local frameSize = math.floor(cellSize)

                    cell._cellFrameX = frameX
                    cell._cellFrameY = frameY
                    cell._cellFrameSize = frameSize

                    -- The cell group itself is the hit area, so it must match the frame and not
                    -- the centered/scaled image. Otherwise neighboring cells' hit areas overlap.
                    cell.x = frameX
                    cell.y = frameY
                    cell.realX = frameX
                    cell.realY = frameY
                    cell.width = frameSize
                    cell.height = frameSize

                    if image then
                        image.scaleX = cellScale
                        image.scaleY = cellScale
                        image.x = math.floor((frameSize - cellWidth * cellScale) / 2)
                        image.y = math.floor((frameSize - cellHeight * cellScale) / 2)
                        image.realX = image.x
                        image.realY = image.y
                    end
                end

                if warning then
                    -- Bottom-right corner of the preview image area
                    local padding = math.floor(6 * uiScale)
                    local warningWidth = warning.width or 0
                    local warningHeight = warning.height or 0

                    warning.x = math.max(originX + padding,
                        math.floor(originX + boxWidth - padding - warningWidth))
                    warning.y = math.max(originY + padding,
                        math.floor(originY + boxHeight - padding - warningHeight))
                    warning.realX = warning.x
                    warning.realY = warning.y

                    self._previewWarningRect = {
                        x = warning.x,
                        y = warning.y,
                        width = warningWidth,
                        height = warningHeight
                    }

                else
                    self._previewWarningRect = nil
                end

                local gridWidth = columns > 0 and (columns * (cellSize + cellGap) - cellGap) or 0
                local totalWidth = originX + boxWidth + (columns > 0 and (gridGap + gridWidth) or 0) + marginRight
                local totalHeight = originY + math.max(boxHeight,
                    #cells > 0 and (rows * (cellSize + cellGap) - cellGap) or 0)

                if self.width ~= totalWidth or self.height ~= totalHeight then
                    self.width = math.floor(totalWidth)
                    self.height = math.floor(totalHeight)
                end

                self._previewBoxWidth = math.floor(boxWidth)
                self._previewBoxHeight = math.floor(boxHeight)
            end,

            draw = function(orig, self, ...)
                local screenX, screenY = self.screenX or 0, self.screenY or 0
                local originX = self._previewOriginX or 0
                local originY = self._previewOriginY or 0
                local boxX, boxY = screenX + originX, screenY + originY
                local boxWidth = self._previewBoxWidth or self.width or 0
                local boxHeight = self._previewBoxHeight or self.height or 0

                -- Backdrop behind the preview image and the texture cells
                if boxWidth > 0 and boxHeight > 0 then
                    uiUtils.setColor(0.08, 0.08, 0.08, 0.35)

                    love.graphics.rectangle("fill", boxX, boxY, boxWidth, boxHeight)
                end

                for _, child in ipairs(self.children or {}) do
                    if child._previewCell then
                        uiUtils.setColor(0.13, 0.13, 0.13, 0.6)

                        love.graphics.rectangle("fill", screenX + (child._cellFrameX or 0),
                            screenY + (child._cellFrameY or 0),
                            child._cellFrameSize or 0, child._cellFrameSize or 0)
                    end
                end

                -- Readability backdrop for the "preview only" warning
                local warningRect = self._previewWarningRect

                if warningRect and warningRect.width > 0 and warningRect.height > 0 then
                    local pad = 3

                    uiUtils.setColor(0, 0, 0, 0.35)
                    love.graphics.rectangle("fill", screenX + warningRect.x - pad,
                        screenY + warningRect.y - pad,
                        warningRect.width + pad * 2, warningRect.height + pad * 2)
                end

                orig(self, ...)

                -- Preview area frame: the fixed size box the image is fitted into
                uiUtils.setColor(1, 1, 1, 0.3)
                love.graphics.setLineWidth(1)

                if boxWidth > 0 and boxHeight > 0 then
                    love.graphics.rectangle("line", boxX + 0.5, boxY + 0.5,
                        math.max(0, boxWidth - 1), math.max(0, boxHeight - 1))
                end

                -- Actual image frame: distinguishes the drawn image from the empty margin left by
                -- an aspect ratio that does not exactly match the preview box
                local imageX = self._previewImageX
                local imageY = self._previewImageY
                local imageWidth = self._previewImageWidth
                local imageHeight = self._previewImageHeight

                if imageX and imageY and imageWidth and imageHeight
                    and imageWidth > 1 and imageHeight > 1 then
                    uiUtils.setColor(0.55, 0.75, 0.95, 0.85)

                    love.graphics.rectangle("line", screenX + imageX + 0.5, screenY + imageY + 0.5,
                        math.max(0, imageWidth - 1), math.max(0, imageHeight - 1))
                end

                uiUtils.setColor(1, 1, 1, 0.3)

                for _, child in ipairs(self.children or {}) do
                    if child._previewCell then
                        local size = child._cellFrameSize or 0

                        love.graphics.rectangle("line", screenX + (child._cellFrameX or 0) + 0.5,
                            screenY + (child._cellFrameY or 0) + 0.5,
                            math.max(0, size - 1), math.max(0, size - 1))
                    end
                end

                uiUtils.setColor(1, 1, 1, 1)
            end
        })
    end

    -- The container starts out empty: reflow so it picks up the size of the new content
    previewContainer:reflow()

    if interactionData then
        updateStylegroundWindowHeight(interactionData)
    end
end

local function prepareFormData(interactionData)
    local listTarget = interactionData.listTarget
    local formData = {}

    if not listTarget then
        return formData
    end

    local style = listTarget.style or {}
    local parentStyle = listTarget.parentStyle or {}

    -- Copy in parent style, clear name and type
    for k, v in pairs(parentStyle) do
        formData[k] = v
    end

    formData.__name = nil
    formData._type = nil

    -- Copy style
    for k, v in pairs(style) do
        formData[k] = v
    end

    -- Filter out apply children
    if type(formData.children) == "table" then
        formData.children = nil
    end

    -- Add any missing default values
    local handler = getHandler(style)
    local defaultData = handler.defaultData(style) or {}

    for k, v in pairs(defaultData) do
        if formData[k] == nil then
            formData[k] = v
        end
    end

    return formData
end

local function applyFormChanges(style, newData)
    -- TODO - Handle parent better, ignore for now

    for k, v in pairs(newData) do
        style[k] = v
    end
end

-- Returns values as follows:
-- First is fg/bg styles table from the map
-- Second is the actual parent of the style (styles table or an apply)
-- Third is the index in that parent
-- Fourth is the parent style, if it exists
-- Fifth is the index the target would have in the visual list
local function findStyleInStylegrounds(interactionData, target)
    local listIndex = 0
    local listTarget = interactionData.listTarget
    local style = target

    if not listTarget then
        return
    end

    style = style or interactionData.listTarget.style

    local map = interactionData.map
    local foreground = interactionData.listTarget.foreground
    local styles = foreground and map.stylesFg or map.stylesBg

    for i, s in ipairs(styles) do
        listIndex += 1

        if style == s then
            return styles, styles, i, nil, listIndex
        end

        local styleType = utils.typeof(s)

        if styleType == "apply" then
            for j, c in ipairs(s.children or {}) do
                if not style._collapsed then
                    listIndex += 1
                end

                if style == c then
                    return styles, s.children, j, s, listIndex
                end
            end
        end
    end

    return styles, styles, 1, nil, 1
end

local function findListIndex(interactionData, targetStyle)
    local _, _, _, _, listIndex = findStyleInStylegrounds(interactionData, targetStyle)

    return listIndex
end

local function findListItem(interactionData, targetStyle)
    local listElement = interactionData.stylegroundListElement

    for i, item in ipairs(listElement.children) do
        if item.data.style == targetStyle then
            return item, i
        end
    end
end

local function findCurrentListItem(interactionData)
    local listTarget = interactionData.listTarget

    return findListItem(interactionData, listTarget.style)
end

local function moveIndex(t, before, after)
    local value = table.remove(t, before)

    table.insert(t, after, value)
end

local function canMoveStyle(interactionData, offset)
    local listTarget = interactionData.listTarget

    if not listTarget or listTarget.defaultTarget then
        return false
    end

    local _, parent, index = findStyleInStylegrounds(interactionData)

    if parent and index then
        local newIndex = index + offset

        return index ~= newIndex and newIndex >= 1 and newIndex <= #parent
    end

    return false
end

local function updateMovementButtons(interactionData)
    -- Movement buttons were removed from the form: nothing to keep in sync
end

local function moveStyle(interactionData, offset)
    local styles, parent, index = findStyleInStylegrounds(interactionData)

    if parent and index then
        local newIndex = utils.clamp(index + offset, 1, #parent)

        if index ~= newIndex then
            local listElement = interactionData.stylegroundListElement
            local _, listIndex = findCurrentListItem(interactionData)
            local movingGroup = styles == parent

            moveIndex(parent, index, newIndex)

            if movingGroup then
                local newListIndex = findListIndex(interactionData, style)

                interactionData.rebuildListItems(newListIndex)

            else
                moveIndex(listElement.children, listIndex, listIndex + offset)
            end

            listElement:reflow()

            updateMovementButtons(interactionData)
        end
    end
end

local function createApply()
    local style = applyStruct.decode({})
    local defaultData = apply.defaultData(style) or {}

    -- Used for visuals, not saved to map bin
    style._collapsed = false

    for k, v in pairs(defaultData) do
        style[k] = v
    end

    return style
end

local function createParallax()
    local style = parallaxStruct.decode({})
    local defaultData = parallax.defaultData(style) or {}

    for k, v in pairs(defaultData) do
        style[k] = v
    end

    return style
end

local function createEffect(name)
    local style = effectStruct.decode({__name = name})
    local defaultData = effects.defaultData(style) or {}

    for k, v in pairs(defaultData) do
        style[k] = v
    end

    return style
end

-- For when the list is completely empty
local function getDefaultListTarget()
    return {
        style = createParallax(),
        foreground = true,
        defaultTarget = true
    }
end

local currentInteractionData

-- Restores a whole styleground state: used by the undo entries and by the auto-edit sessions
local function applyStyleState(map, state)
    map.stylesFg = utils.deepcopy(state.fg)
    map.stylesBg = utils.deepcopy(state.bg)

    -- Keep the open window in sync when the change is undone or redone
    if currentInteractionData and currentInteractionData.rebuildListItems then
        currentInteractionData.listTarget = getDefaultListTarget()

        currentInteractionData.rebuildListItems()
        stylegroundWindow.updateStylegroundForm(currentInteractionData)
        stylegroundWindow.updateStylegroundPreview(currentInteractionData)
    end
end

local function snapshotStyleState(map, before, after, title)
    history.addSnapshot(snapshotStruct.create(title or "Stylegrounds", {}, function()
        applyStyleState(map, before)
    end, function()
        applyStyleState(map, after)
    end))
end

-- Wraps a styleground edit into an undoable history entry. The returned commit function has to be
-- called once the mutation is done; it also marks the map as having unsaved changes.
local function beginStyleEdit(map)
    -- A pending auto-edit session (form changes) ends before a structural change happens
    local interactionData = currentInteractionData

    if interactionData then
        stylegroundWindow.endAutoEdit(interactionData)
    end

    local before = {
        fg = utils.deepcopy(map.stylesFg),
        bg = utils.deepcopy(map.stylesBg)
    }

    return function(title)
        local after = {
            fg = utils.deepcopy(map.stylesFg),
            bg = utils.deepcopy(map.stylesBg)
        }

        snapshotStyleState(map, before, after, title)
    end
end

-- Auto edits: form changes are applied immediately, but the undo entry is only created once the
-- user stops typing for a moment. That keeps one undo step per editing session instead of one per
-- keystroke.
local autoEditDelay = 0.5

function stylegroundWindow.beginAutoEdit(interactionData)
    local session = interactionData.autoEdit

    if session and love.timer.getTime() - session.time > autoEditDelay then
        stylegroundWindow.endAutoEdit(interactionData)
        session = nil
    end

    if not session then
        local map = interactionData.map

        interactionData.autoEdit = {
            time = love.timer.getTime(),
            before = {
                fg = utils.deepcopy(map.stylesFg),
                bg = utils.deepcopy(map.stylesBg)
            }
        }

    else
        session.time = love.timer.getTime()
    end
end

function stylegroundWindow.endAutoEdit(interactionData)
    local session = interactionData and interactionData.autoEdit

    if not session then
        return
    end

    interactionData.autoEdit = nil

    local map = interactionData.map
    local after = {
        fg = utils.deepcopy(map.stylesFg),
        bg = utils.deepcopy(map.stylesBg)
    }

    snapshotStyleState(map, session.before, after, "Edit styleground")
end

local function changeStyleForeground(interactionData)
    local listTarget = interactionData.listTarget
    local currentListElement = interactionData.stylegroundListElement
    local otherListElement = interactionData.stylegroundListElementOther

    local foreground = listTarget.foreground

    local movedStyle = listTarget.style
    local map = interactionData.map

    -- Update map style data
    local commit = beginStyleEdit(map)
    local fromStyles = foreground and map.stylesFg or map.stylesBg
    local toStyles = foreground and map.stylesBg or map.stylesFg

    for i, s in ipairs(fromStyles) do
        if movedStyle == s then
            table.remove(fromStyles, i)
            table.insert(toStyles, movedStyle)

            break
        end
    end

    commit("Move styleground")

    interactionData.rebuildListItems(nil, otherListElement)
    interactionData.rebuildListItems(nil, currentListElement)
end

local function addNewStyle(interactionData, formFields)
    local listTarget = interactionData.listTarget

    local newStyle
    local currentStyle = listTarget.style
    local parentStyle = listTarget.parentStyle

    local listElement = interactionData.stylegroundListElement
    local foreground = listElement == interactionData.stylegroundListElementFg
    local map = interactionData.map
    -- Diagnostic: addNewStyle currently has no call site (the "New" dropdown was removed).
    -- This line records whether a future entry point actually reaches it.
    pcall(logging.log, "INFO", string.format("[diag] styleground.addNewLayer begin method=%s",
        tostring(interactionData.addNewMethod and interactionData.addNewMethod.method)), nil, true)

    local method = interactionData.addNewMethod.method
    local commit = beginStyleEdit(map)

    if method == "basedOnCurrent" then
        if currentStyle then
            newStyle = utils.deepcopy(currentStyle)

            applyFormChanges(newStyle, form.getFormData(formFields))
        end

    elseif method == "group" then
        newStyle = createApply()

    elseif method == "parallax" then
        newStyle = createParallax()

    elseif method == "effect" then
        local effectName = interactionData.addNewMethod.name

        newStyle = createEffect(effectName)
    end

    if newStyle then
        local _, parentTable, index = findStyleInStylegrounds(interactionData)
        local _, listIndex = findCurrentListItem(interactionData)
        local targetGroup
        local newIsApply = utils.typeof(newStyle) == "apply"
        local currentIsApply = utils.typeof(currentStyle) == "apply"
        local parentIsApply = utils.typeof(parentStyle) == "apply"

        if currentIsApply then
            targetGroup = currentStyle

            -- We are adding as first element of the group
            index = 0

        elseif parentIsApply then
            targetGroup = parentStyle
        end

        local addToGroup = targetGroup and not newIsApply

        -- If we add a apply it should be added after the current group
        if newIsApply and targetGroup then
            parentTable = foreground and map.stylesFg or map.stylesBg
            _, _, index, _, listIndex = findStyleInStylegrounds(interactionData, targetGroup)
            listIndex += #targetGroup.children
        end

        -- Fallback if we don't have any items in the list yet
        if #listElement.children == 0 then
            addToGroup = false
            parentTable = foreground and map.stylesFg or map.stylesBg
            listIndex = 0
            index = 0
        end

        if addToGroup then
            if not targetGroup.children then
                targetGroup.children = {}
            end

            table.insert(targetGroup.children, index + 1, newStyle)

        else
            table.insert(parentTable, index + 1, newStyle)
        end

        -- Update list index after adding group
        if newIsApply and parentIsApply then
            listIndex = findListIndex(interactionData, newStyle) - 1
        end

        commit("Add styleground")
        interactionData.rebuildListItems(listIndex + 1)
    end

    pcall(logging.log, "INFO", "[diag] styleground.addNewLayer end ok=" .. tostring(newStyle ~= nil), nil, true)

    return not not newStyle
end

-- Selects and focuses a style in the active list. Deferred on purpose: list:updateItems()
-- restores the previous selection in a ui.runLate callback, which would overwrite an immediate
-- selection change.
local function selectStylesDeferred(interactionData, styles, list, primaryStyle)
    list = list or (interactionData and interactionData.stylegroundListElement)

    if not list or not styles or #styles == 0 then
        return
    end

    ui.runLate(function()
        if not stylegroundWindow.isOpen() or not list.parent then
            return
        end

        local styleSet = {}

        for _, style in ipairs(styles) do
            styleSet[style] = true
        end

        local primaryItem = list.setStyleSelection
            and list:setStyleSelection(styleSet, primaryStyle or styles[#styles])

        if not primaryItem then
            return
        end

        widgetUtils.focusElement(primaryItem)

        -- Focus after the material row click has finished; focusing immediately here is
        -- overwritten by the click's own focus handling.
        ui.runLate(function()
            if not stylegroundWindow.isOpen() or not primaryItem.parent then
                return
            end

            widgetUtils.focusElement(primaryItem)
            listWidgets.scrollSelectionVisible(list)
        end)
    end)
end

local function selectStyleDeferred(interactionData, style, list)
    if style then
        selectStylesDeferred(interactionData, {style}, list, style)
    end
end

local function removeStyle(interactionData)
    local list = interactionData.stylegroundListElement
    local startIndex = list and list:getSelectedIndex() or 1
    local targets = interactionData.selectedTargets or {}

    -- Multiple rows selected: remove every one of them in a single undo step
    if #targets > 1 then
        local commit = beginStyleEdit(interactionData.map)

        for _, target in ipairs(targets) do
            local fake = table.shallowcopy(interactionData)
            fake.listTarget = target

            local _, parent, index = findStyleInStylegrounds(fake)

            if parent and index then
                table.remove(parent, index)
            end
        end

        commit("Remove stylegrounds")

        interactionData.listTarget = getDefaultListTarget()
        interactionData.selectedTargets = {}

        local newItems = interactionData.rebuildListItems()

        if #newItems > 0 then
            -- Select the layer above the deleted one
            local selectIndex = math.max(math.min(startIndex - 1, #newItems), 1)
            local item = newItems[selectIndex]

            selectStyleDeferred(interactionData, item and item.data and item.data.style)

        else
            stylegroundWindow.updateStylegroundForm(interactionData)
            stylegroundWindow.updateStylegroundPreview(interactionData)
        end

        return
    end

    local _, parent, index = findStyleInStylegrounds(interactionData)

    if parent and index then
        local _, listIndex = findCurrentListItem(interactionData)
        local commit = beginStyleEdit(interactionData.map)

        table.remove(parent, index)

        commit("Remove styleground")

        local newItems = interactionData.rebuildListItems(listIndex or 1)

        if #newItems > 0 then
            -- Select the layer above the deleted one, or the first one when it was the top layer
            local selectIndex = math.max(math.min((listIndex or 1) - 1, #newItems), 1)
            local item = newItems[selectIndex]

            selectStyleDeferred(interactionData, item and item.data and item.data.style)

            return
        end

        interactionData.listTarget = getDefaultListTarget()

        stylegroundWindow.updateStylegroundForm(interactionData)
        stylegroundWindow.updateStylegroundPreview(interactionData)
    end
end

local function updateStyle(interactionData, style, newData)
    local commit = beginStyleEdit(interactionData.map)
    local targets = interactionData.selectedTargets or {}

    if #targets > 1 then
        -- Multiple rows selected: apply the form to every one of them
        for _, target in ipairs(targets) do
            applyFormChanges(target.style, newData)
        end

    else
        applyFormChanges(style, newData)
    end

    commit("Edit styleground")
    interactionData.rebuildListItems()
end

local function findBestGroupParent(interactionData)
    local listTarget = interactionData.listTarget
    local currentStyle = listTarget.style
    local closestGroup
    local seenCurrent = false

    local styles = findStyleInStylegrounds(interactionData)

    -- Try to find the closest group, prefer inserting into group above
    for _, style in ipairs(styles) do
        if style == currentStyle then
            seenCurrent = true

            if closestGroup then
                return closestGroup
            end
        end

        if utils.typeof(style) == "apply" then
            closestGroup = style

            if seenCurrent then
                return style
            end
        end
    end
end

local function addStyleToGroup(interactionData)
    local listTarget = interactionData.listTarget
    local currentStyle = listTarget.style
    local parentGroup = findBestGroupParent(interactionData)
    local styles, _, index = findStyleInStylegrounds(interactionData)
    local commit = beginStyleEdit(interactionData.map)

    -- If no groups exist create one and insert it there instead
    if not parentGroup then
        parentGroup = createApply()

        table.insert(styles, index + 1, parentGroup)
    end

    table.insert(parentGroup.children, currentStyle)
    table.remove(styles, index)

    commit("Move styleground into group")
    interactionData.rebuildListItems()
end

-- Creates a new, empty group at the current position. Unlike "add to group" this does not move
-- the selected style anywhere.
local function createEmptyGroup(interactionData)
    local styles = findStyleInStylegrounds(interactionData)

    if not styles then
        return
    end

    local _, _, index = findStyleInStylegrounds(interactionData)
    local group = createApply()
    local commit = beginStyleEdit(interactionData.map)

    -- An empty list has no valid index to insert after: clamp so insertion stays in bounds
    local insertIndex = math.min(index or #styles, #styles) + 1

    table.insert(styles, insertIndex, group)

    commit("Create styleground group")
    interactionData.rebuildListItems()
end

local function removeStyleFromGroup(interactionData)
    local listTarget = interactionData.listTarget
    local style = listTarget.style
    local parentStyle = listTarget.parentStyle
    local styles, _, index = findStyleInStylegrounds(interactionData)
    local _, _, parentIndex = findStyleInStylegrounds(interactionData, parentStyle)

    if parentStyle and parentStyle.children and styles and parentIndex then
        local commit = beginStyleEdit(interactionData.map)

        table.remove(parentStyle.children, index)
        table.insert(styles, parentIndex + 1, style)

        commit("Move styleground out of group")
        interactionData.rebuildListItems()
    end
end

local function getNewDropdownOptions(style, foreground, usingDefault, showIncorrect)
    local language = languageRegistry.getLanguage()
    local knownEffects = effects.registeredEffects
    local options = {}

    if style and not usingDefault then
        table.insert(options, {
            text = tostring(language.ui.styleground_window.new_options.based_on_current),
            data = {
                method = "basedOnCurrent"
            }
        })
    end

    table.insert(options, {
        text = tostring(language.ui.styleground_window.new_options.parallax),
        data = {
            method = "parallax"
        }
    })

    table.insert(options, {
        text = tostring(language.ui.styleground_window.new_options.apply),
        data = {
            method = "group"
        }
    })

    -- Find all effects and add them in sorted order (by display name)
    local effectOptions = {}

    for name, _ in pairs(knownEffects) do
        local fakeEffect = {_name = name}
        local displayName = effects.displayName(language, fakeEffect)
        local canForeground = effects.canForeground(fakeEffect)
        local canBackground = effects.canBackground(fakeEffect)
        local correctForegroundValue = foreground and canForeground or not foreground and canBackground

        local option = {
            text = displayName,
            data = {
                method = "effect",
                name = name,
                correctForegroundValue = correctForegroundValue
            }
        }

        -- Remove invalid options that does not match current foreground/background
        if showIncorrect or correctForegroundValue then
            table.insert(effectOptions, option)
        end
    end

    effectOptions = table.sortby(effectOptions, function(option)
        return option.text
    end)()

    for _, option in ipairs(effectOptions) do
        table.insert(options, option)
    end

    return options
end

local function notifyRemoveStyle(language, interactionData)
    notifications.notify(
        function(popup)
            return uiElements.column({
                uiElements.label(tostring(language.ui.stylegrounds_window.delete_style_warning)),
                uiElements.row({
                    uiElements.button(tostring(language.ui.button.yes), function()
                        removeStyle(interactionData)
                        popup:close()
                    end),
                    uiElements.button(tostring(language.ui.button.no), function()
                        popup:close()
                    end),
                })
            })
        end,
        -1,
        {clearSameTag = true, tag = "stylegroundDelete"}
    )
end

local function getStylegroundFormButtons(interactionData, formFields, formOptions)
    local listTarget = interactionData.listTarget or {}
    local listHasElements = false

    if interactionData.stylegroundListElement then
        listHasElements = #interactionData.stylegroundListElement.children > 0
    end

    local language = languageRegistry.getLanguage()
    local style = listTarget.style
    local foreground = interactionData.stylegroundListElement == interactionData.stylegroundListElementFg
    local isDefaultTarget = listTarget.defaultTarget
    local inGroup = not not listTarget.parentStyle
    local isGroup = utils.typeof(style) == "apply"

    local handler = getHandler(style)

    local canForeground = handler and handler.canForeground(style)
    local canBackground = handler and handler.canBackground(style)
    local canStayInCurrentLayer = (foreground and canForeground) or (not foreground and canBackground)
    local canMoveToOtherLayer = (foreground and canBackground) or (not foreground and canForeground)

    -- When the current row is already in the wrong list (for example a background-only effect
    -- that was added to the foreground before validation existed), show a one-way move button so
    -- it can be corrected. Otherwise only truly bidirectional effects get the move button.
    local canChangeForeground = not inGroup and canMoveToOtherLayer
        and (not canStayInCurrentLayer or (canForeground and canBackground))

    local moveToForegroundText = tostring(language.ui.styleground_window.form.move_to_foreground)
    local moveToBackgroundText = tostring(language.ui.styleground_window.form.move_to_background)

    local movementButtonElements = {}

    local changeForegroundButton = {
        text = foreground and moveToBackgroundText or moveToForegroundText,
        callback = function()
            changeStyleForeground(interactionData)
        end
    }
    local addToGroupButton = {
        text = tostring(language.ui.styleground_window.form.create_group or "Create Group"),
        callback = function()
            createEmptyGroup(interactionData)
        end
    }
    local removeFromGroupButton = {
        text = tostring(language.ui.styleground_window.form.remove_from_group),
        callback = function()
            removeStyleFromGroup(interactionData)
        end
    }

    interactionData.movementButtonElements = movementButtonElements

    local buttons = {
        {
            text = tostring(language.ui.styleground_window.form.remove),
            enabled = listHasElements,
            callback = function()
                -- Delete right away: the removal is undoable, so no confirmation is needed
                removeStyle(interactionData)
            end
        },
    }

    table.insert(buttons, 1, {
        text = tostring(language.ui.styleground_window.form.new),
        callback = function()
            interactionData.addNewMethod = {method = "parallax"}
            addNewStyle(interactionData, formFields)
        end
    })

    if canChangeForeground and listHasElements then
        table.insert(buttons, changeForegroundButton)
    end

    if not isGroup then
        if inGroup then
            table.insert(buttons, removeFromGroupButton)

        else
            table.insert(buttons, addToGroupButton)
        end
    end

    -- Diagnostic: 0 means the button row was built with no entries at all
    pcall(logging.log, "INFO", string.format("[diag] styleground.buttons n=%d", #buttons), nil, true)

    local buttonRow = formHelper.getFormButtonRow(buttons, formFields, formOptions)

    -- The "New" dropdown is gone; the button row carries a plain "add" button instead, and the
    -- right side of the tools window can still drag styles in.
    interactionData.addNewMethod = {method = "parallax"}

    return buttonRow
end

function stylegroundWindow.getStylegroundForm(interactionData)
    local formData = prepareFormData(interactionData)
    local formOptions, dummyData = getOptions(formData)

    -- TODO - Add to config file?
    -- 3 field pairs per row: each pair uses two grid columns (label and input)
    formOptions.columns = 6
    -- Tighter spacing: the label column already includes its own padding
    formOptions.gridColumnSpacing = 8
    formOptions.gridRowSpacing = 4
    -- Keep every label directly next to its input: the settings labels got long, which pushed
    -- short labels far away from their inputs in the shared grid columns
    formOptions.pairFieldElements = true

    -- With more than one row selected only the fields every selection has in common are shown;
    -- "Update" then applies the form to all of them
    local selectedTargets = interactionData.selectedTargets or {}

    if #selectedTargets > 1 then
        local commonFields = {}

        for _, key in ipairs(formOptions.fieldOrder) do
            local common = true

            for i = 2, #selectedTargets do
                local otherData = prepareFormData({listTarget = selectedTargets[i]})

                if otherData[key] == nil then
                    common = false

                    break
                end
            end

            if common then
                table.insert(commonFields, key)
            end
        end

        formOptions.fieldOrder = commonFields
        -- Fields that are not in the field order come from the first selection only, so they must
        -- not be offered for a multi selection
        formOptions.hideUnordered = true
    end
    formOptions.formFieldChanged = function(formFields, changedField)
        local newData = form.getFormData(formFields)

        interactionData.formData = newData

        -- Auto update: only the field the user actually changed is applied to the selected styles.
        -- Applying the whole form would overwrite every other property of the other selections.
        local targets = interactionData.selectedTargets or {}

        if changedField and changedField.name and #targets > 0 then
            stylegroundWindow.beginAutoEdit(interactionData)

            local parts = form.getNameParts(changedField.name, formOptions)
            local value = utils.getPath(newData, parts)

            for _, target in ipairs(targets) do
                utils.setPath(target.style, parts, utils.deepcopy(value), true)
            end

            history.madeChanges = true

            -- Refresh the row texts: display names depend on fields like the texture or the group
            -- name
            updateListRowTexts(interactionData)
        end

        stylegroundWindow.updateStylegroundPreview(interactionData)
    end

    local formBody, formFields = formHelper.getFormBody(dummyData, formOptions)
    local buttonRow = getStylegroundFormButtons(interactionData, formFields, formOptions)

    -- Finish all fade effects
    for _, field in ipairs(formFields) do
        for _, element in ipairs(field.elements) do
            widgetUtils.finishElementFade(element)
        end
    end

    for _, button in ipairs(buttonRow.children) do
        widgetUtils.finishElementFade(button)
    end

    return uiElements.column({formBody, buttonRow})
end

updateStylegroundWindowHeight = function(interactionData)
    local window = interactionData and interactionData.window

    if not window or not window.parent then
        return
    end

    local formContainer = interactionData.formContainerGroup
    local preview = interactionData.stylegroundPreviewGroup

    local function apply()
        if not window.parent then
            return
        end

        local form = formContainer and formContainer.children and formContainer.children[1]

        -- Lay out the new form and preview before measuring them. Measuring an element that still
        -- carries the previous selection's size makes the window grow in steps on every rebuild.
        if form then
            form:layout()
            form:layoutLate()
        end

        local formHeight = form and form.height or 0

        if preview then
            preview:layout()
            preview:layoutLate()
        end

        local previewHeight = preview and preview.height or 0
        local previewChild = preview and preview.children and preview.children[1]

        -- A placeholder/no-preview row does not need half the window. Keep only a compact area
        -- for it so a short form does not get pushed down by empty preview space.
        if not (previewChild and previewChild._previewSprite) then
            previewHeight = math.min(previewHeight, 48)
        end

        if formHeight <= 0 then
            if not interactionData._heightRetryPending then
                interactionData._heightRetryPending = true
                ui.runLate(function()
                    interactionData._heightRetryPending = false
                    apply()
                end)
            end
            return
        end

        -- Height follows the currently selected form only. Do not keep the previous taller form's
        -- height, otherwise short forms leave a huge empty window.
        local desired = math.max(WINDOW_STATIC_HEIGHT, previewHeight + formHeight + 48)
        local maxHeight = math.max(WINDOW_STATIC_HEIGHT, math.floor((love.graphics.getHeight() or 1080) - 64))
        desired = math.min(desired, maxHeight)

        if window.height ~= desired then
            window.height = desired
            window:reflow()
        end
    end

    apply()
end

function stylegroundWindow.updateStylegroundForm(interactionData)
    local formContainer = interactionData.formContainerGroup
    local newForm = stylegroundWindow.getStylegroundForm(interactionData)
    local children = formContainer.children or {}

    while #children > 0 do
        children[1]:removeSelf()
    end

    formContainer:addChild(newForm)

    updateStylegroundWindowHeight(interactionData)
end

-- Check if movement is allowed and return prepared offset and interactionData
local function listItemDragAllowed(interactionData, fromList, fromListItem, _, _, fromIndex, toIndex)
    local offset = toIndex - fromIndex

    if toIndex > fromIndex then
        offset -= 1
    end

    if offset ~= 0 then
        local fakeInteractionData = table.shallowcopy(interactionData)

        fakeInteractionData.listTarget = fromListItem.data
        fakeInteractionData.stylegroundListElement = fromList

        return canMoveStyle(fakeInteractionData, offset), offset, fakeInteractionData
    end

    return false, offset, nil
end

-- True when the drag crosses a group boundary, which is a structural move instead of a reorder
local function isCrossParentDrag(fromListItem, toListItem)
    local from = fromListItem and fromListItem.data
    local to = toListItem and toListItem.data

    return from ~= nil and to ~= nil and from.style ~= nil and to.style ~= nil
        and from.parentStyle ~= to.parentStyle
end

-- Resolves the group a drop belongs to. Dropping on the upper half of a group row targets that
-- row, dropping on its lower half inserts right after the row, so the row above the insertion
-- index has to be checked as well.
local function getGroupDropData(toList, toListItem, toIndex, fromListItem)
    local toData = toListItem and toListItem.data

    if toData and toData.style and utils.typeof(toData.style) == "apply" then
        return toData
    end

    local children = toList and toList.children

    if children and toIndex then
        local previous = children[toIndex - 1]

        if previous and previous ~= fromListItem and previous.data
            and previous.data.style and utils.typeof(previous.data.style) == "apply" then
            return previous.data
        end
    end
end

-- Moves a style into or out of a group. Returns true when the drag was a structural move.
local function moveStyleBetweenParents(interactionData, fromData, toData)
    local map = interactionData.map
    local fromStyle = fromData.style
    local toStyle = toData.style

    if not fromStyle or not toStyle or fromStyle == toStyle then
        return false
    end

    -- A group cannot be moved into another group
    if utils.typeof(fromStyle) == "apply" and toData.parentStyle then
        return false
    end

    local fake = table.shallowcopy(interactionData)
    fake.listTarget = fromData

    local _, sourceParent, sourceIndex = findStyleInStylegrounds(fake)

    if not sourceParent or not sourceIndex then
        return false
    end

    local targetParent

    if toData.parentStyle then
        targetParent = toData.parentStyle.children

    else
        targetParent = toData.foreground and map.stylesFg or map.stylesBg
    end

    if not targetParent or targetParent == sourceParent then
        return false
    end

    local commit = beginStyleEdit(map)

    table.remove(sourceParent, sourceIndex)

    -- Recompute the target index: removing the dragged item can shift it
    local targetIndex

    for i, s in ipairs(targetParent) do
        if s == toStyle then
            targetIndex = i

            break
        end
    end

    if not targetIndex then
        commit("Move styleground")

        return false
    end

    table.insert(targetParent, targetIndex, fromStyle)

    commit("Move styleground between groups")
    interactionData.rebuildListItems()

    return true
end

-- Drops a style onto a group row: it becomes a child of that group
local function moveStyleIntoGroup(interactionData, fromData, group)
    if not group or utils.typeof(fromData.style) == "apply" then
        return false
    end

    local map = interactionData.map
    local fake = table.shallowcopy(interactionData)
    fake.listTarget = fromData

    local _, sourceParent, sourceIndex = findStyleInStylegrounds(fake)

    if not sourceParent or not sourceIndex then
        return false
    end

    if group.children and sourceParent == group.children then
        return false
    end

    local commit = beginStyleEdit(map)

    table.remove(sourceParent, sourceIndex)

    group.children = group.children or {}
    table.insert(group.children, fromData.style)

    -- Expand the group so the moved style is visible right away
    group._collapsed = false

    commit("Move styleground into group")
    interactionData.rebuildListItems()

    return true
end

-- Moves a group to the position described by the drop target. Groups are only ever reordered as
-- top level rows: there is no "into group" behavior for them, so the whole group (with its
-- children) moves as one.
local function moveGroupToDropPosition(interactionData, fromData, toList, toListItem, toIndex)
    local map = interactionData.map
    local styles = fromData.foreground and map.stylesFg or map.stylesBg
    local group = fromData.style

    if not group or not styles then
        return false
    end

    local fromIndex

    for i, s in ipairs(styles) do
        if s == group then
            fromIndex = i

            break
        end
    end

    if not fromIndex then
        return false
    end

    -- Resolve the top level style the drop belongs next to: rows inside a group belong to that
    -- group at the top level
    local toData = toListItem and toListItem.data
    local targetStyle = toData and (toData.parentStyle or toData.style)

    local toPos

    if targetStyle then
        local rowIndex

        for i, item in ipairs(toList and toList.children or {}) do
            if item == toListItem then
                rowIndex = i

                break
            end
        end

        -- The insertion index is already adjusted for "after the hovered row"
        local after = rowIndex ~= nil and toIndex ~= nil and toIndex > rowIndex

        for i, s in ipairs(styles) do
            if s == targetStyle then
                toPos = i + (after and 1 or 0)

                break
            end
        end
    end

    toPos = toPos or (#styles + 1)

    -- Translate the pre-removal position to the position after the group was removed
    if toPos > fromIndex then
        toPos = toPos - 1
    end

    toPos = math.max(1, math.min(toPos, #styles + 1))

    if toPos == fromIndex then
        return false
    end

    local commit = beginStyleEdit(map)

    table.remove(styles, fromIndex)
    table.insert(styles, toPos, group)

    commit("Move styleground group")

    interactionData.rebuildListItems()

    -- Keep the moved group selected: after the rebuild the row index would point at a different
    -- style, and the form would then edit the wrong entry
    selectStyleDeferred(interactionData, group)

    return true
end

-- Moves all selected styles from one parent to the drop position as one block. This only handles
-- plain reorders within the same parent; group/cross-parent drops keep their special behavior.
local function moveSelectedStylesBlock(interactionData, fromList, fromListItem, toList, toListItem, toIndex)
    local fromData = fromListItem and fromListItem.data
    local toData = toListItem and toListItem.data

    if not fromData or not toData then
        return false
    end

    -- Dropping onto a group row means "put into group", which is a separate operation
    if toData.style and utils.typeof(toData.style) == "apply" then
        return false
    end

    local map = interactionData.map
    local sourceParent = fromData.parentStyle and fromData.parentStyle.children
        or (fromData.foreground and map.stylesFg or map.stylesBg)
    local targetParent = toData.parentStyle and toData.parentStyle.children
        or (toData.foreground and map.stylesFg or map.stylesBg)

    if not sourceParent or sourceParent ~= targetParent then
        return false
    end

    -- The dragged row must be part of the selection; otherwise this is a normal single drag.
    local selectedStyles = {}
    local selectedSet = {}
    local draggedSelected = false

    for _, item in ipairs(fromList.children or {}) do
        if item.data and item.data.style and fromList:getIsSelected(item) then
            selectedStyles[#selectedStyles + 1] = item.data.style
            selectedSet[item.data.style] = true

            if item == fromListItem then
                draggedSelected = true
            end
        end
    end

    if not draggedSelected then
        return false
    end

    local block = {}

    for _, style in ipairs(sourceParent) do
        if selectedSet[style] then
            block[#block + 1] = style
        end
    end

    if #block < 2 then
        return false
    end

    -- Dropping the block onto one of its own rows is a no-op.
    if selectedSet[toData.style] then
        return true
    end

    local targetRowIndex

    for index, item in ipairs(toList.children or {}) do
        if item == toListItem then
            targetRowIndex = index

            break
        end
    end

    local after = targetRowIndex ~= nil and toIndex ~= nil and toIndex > targetRowIndex
    local insertion = #sourceParent + 1

    for index, style in ipairs(sourceParent) do
        if style == toData.style then
            insertion = index + (after and 1 or 0)

            break
        end
    end

    local remaining = {}
    local insertAt = 1

    for index, style in ipairs(sourceParent) do
        if not selectedSet[style] then
            remaining[#remaining + 1] = style

            if index < insertion then
                insertAt = insertAt + 1
            end
        end
    end

    local alreadyThere = true

    for index, style in ipairs(block) do
        if sourceParent[insertAt + index - 1] ~= style then
            alreadyThere = false

            break
        end
    end

    if alreadyThere then
        return true
    end

    -- Styleground drag/drop is intentionally not undoable: the panel's undo stack is about form
    -- edits, and undoing a drag used to leave the multi selection/list state inconsistent.
    for index = #sourceParent, 1, -1 do
        sourceParent[index] = nil
    end

    for _, style in ipairs(remaining) do
        sourceParent[#sourceParent + 1] = style
    end

    for index = #block, 1, -1 do
        table.insert(sourceParent, insertAt, block[index])
    end

    interactionData.rebuildListItems()

    return true
end

-- After a drop the list is rebuilt by updateItems, which restores the selection by row index.
-- The primary row can therefore point at a different style. Move the primary selection and the
-- keyboard focus to the dropped row. A multi drag keeps the other selected rows; a single drag
-- collapses the old selection onto the dragged row, just like clicking it would.
local function focusDraggedStyleAfterMove(list, style, keepMultiSelection)
    if not list or not style then
        return
    end

    local function findTargetItem()
        for _, item in ipairs(list.children or {}) do
            if item.data and item.data.style == style then
                return item
            end
        end
    end

    ui.runLate(function()
        if not stylegroundWindow.isOpen() or not list.parent then
            return
        end

        local targetItem = findTargetItem()

        if not targetItem then
            return
        end

        if not keepMultiSelection and list.clearStyleSelection then
            list:clearStyleSelection()
        end

        -- setSelection only changes the primary row: selectionStyles keeps the other rows
        -- highlighted, so an existing multi selection stays intact.
        list:setSelection(targetItem.data, false, false)

        if list.setStyleSelectionAnchor then
            list:setStyleSelectionAnchor(style)
        end

        widgetUtils.focusElement(targetItem)

        -- The list was rebuilt, so its rows may only be rooted after the layout pass that runs
        -- after this callback. Look the row up again and focus it once the rebuild settled.
        ui.runLate(function()
            if not stylegroundWindow.isOpen() or not list.parent then
                return
            end

            local newItem = findTargetItem()

            if not newItem then
                return
            end

            widgetUtils.focusElement(newItem)

            if newItem.parent then
                listWidgets.scrollSelectionVisible(list)
            end
        end)
    end)
end

local function listItemDraggedHandler(interactionData)
    return function(fromList, fromListItem, toList, toListItem, fromIndex, toIndex)
        if moveSelectedStylesBlock(interactionData, fromList, fromListItem, toList, toListItem, toIndex) then
            if fromListItem and fromListItem.data and fromListItem.data.style then
                focusDraggedStyleAfterMove(fromList, fromListItem.data.style, true)
            end

            return false
        end

        local fromData = fromListItem and fromListItem.data
        local fromIsGroup = fromData ~= nil and utils.typeof(fromData.style) == "apply"
        local groupData = getGroupDropData(toList, toListItem, toIndex, fromListItem)
        local moved = false

        if fromIsGroup and fromData then
            -- Groups never enter another group: they are reordered between the top level rows
            -- and moveGroupToDropPosition already moves the selection/focus to the group
            moved = moveGroupToDropPosition(interactionData, fromData, toList, toListItem, toIndex)

        elseif groupData and fromData then
            -- Dropping a style onto a group row puts it into that group (both halves of the row)
            moved = moveStyleIntoGroup(interactionData, fromData, groupData.style)

        elseif isCrossParentDrag(fromListItem, toListItem) then
            moved = moveStyleBetweenParents(interactionData, fromListItem.data, toListItem.data)

        else
            -- Groups are always reordered as top level rows; treating a drop next to another group
            -- as "move into group" would swallow that reorder
            local allowed, offset, fakeInteraction = listItemDragAllowed(interactionData, fromList, fromListItem, toList, toListItem, fromIndex, toIndex)

            if allowed then
                moveStyle(fakeInteraction, offset)
                moved = true

                -- Force update movement buttons with the real data
                -- We might have moved in a way that should disable/enable some buttons
                updateMovementButtons(interactionData)
            end
        end

        if moved and fromData and fromData.style and not fromIsGroup then
            focusDraggedStyleAfterMove(fromList, fromData.style)
        end

        -- Manually update the list
        return false
    end
end

local function listItemCanInsertHandler(interactionData)
    return function(fromList, fromListItem, toList, toListItem, fromIndex, toIndex)
        -- Multi drags move as a block, so the single-row offset check would often reject a valid
        -- insertion (especially when dragging upwards). The block handler performs the real
        -- validation after the drop.
        local selectedCount = 0

        for _, item in ipairs(fromList.children or {}) do
            if item.data and fromList:getIsSelected(item) then
                selectedCount = selectedCount + 1
            end
        end

        if selectedCount > 1 then
            return true
        end

        local from = fromListItem and fromListItem.data
        local groupData = getGroupDropData(toList, toListItem, toIndex, fromListItem)
        local fromIsGroup = from ~= nil and utils.typeof(from.style) == "apply"

        -- Groups are reordered as top level rows, so a group drop is always a plain reorder
        if fromIsGroup then
            return true
        end

        -- Dropping onto a group row moves the style into that group, which is not a plain
        -- reorder and has to be accepted here as well. The insert line would be misleading, so it
        -- is hidden for this case.
        if from and groupData and from.style ~= groupData.style then
            return true, true
        end

        -- Dropping into or out of a group is allowed even though it is not a plain reorder
        if isCrossParentDrag(fromListItem, toListItem) then
            return true
        end

        -- Only the first return value is the "allowed" flag: the helper also returns the offset
        -- and a fake interaction data, which must not end up as the hide-insert-line flag
        local allowed = listItemDragAllowed(interactionData, fromList, fromListItem, toList, toListItem, fromIndex, toIndex)

        return allowed
    end
end

local function listItemDoubleClickedHandler(interactionData)
    return function(_, button)
        if button ~= 1 then
            return
        end

        local listTarget = interactionData.listTarget
        local style = listTarget.style
        local isGroup = utils.typeof(style) == "apply"

        if isGroup then
            style._collapsed = not style._collapsed

            interactionData.rebuildListItems()
        end
    end
end

function stylegroundWindow.getStylegroundListItems(map, fg)
    local styles = fg and map.stylesFg or map.stylesBg

    return getStylegroundItems(styles or {}, {}, fg)
end

-- The styles selected in a list: either the multi selection or the single list selection
local function getSelectedTargets(interactionData, list)
    local targets = {}

    for _, item in ipairs(list.children or {}) do
        if item.data and list:getIsSelected(item) then
            table.insert(targets, item.data)
        end
    end

    if #targets == 0 and list.selected and list.selected.data then
        table.insert(targets, list.selected.data)
    end

    return targets
end

local function getItemRange(list, fromItem, toItem)
    local fromIndex, toIndex

    for i, item in ipairs(list.children or {}) do
        if item == fromItem then
            fromIndex = i
        end

        if item == toItem then
            toIndex = i
        end
    end

    if not fromIndex or not toIndex then
        return nil
    end

    if fromIndex > toIndex then
        fromIndex, toIndex = toIndex, fromIndex
    end

    return fromIndex, toIndex
end

local function ctrlHeld()
    return love.keyboard.isDown("lctrl", "rctrl")
end

local function shiftHeld()
    return love.keyboard.isDown("lshift", "rshift")
end

-- True while a text input owns the keyboard. Clipboard and delete keys must not reach the list
-- in that case: Ctrl+X inside a form field has to edit the text, not cut a styleground.
local function textInputFocused()
    local focusing = ui.focusing

    while focusing do
        if focusing.getCursorIndex or focusing.setCursorIndex or focusing.__type == "field" then
            return true
        end

        focusing = focusing.parent
    end

    return false
end

local function getStylegroundTabKey(fg)
    return fg and "foreground" or "background"
end

local function getRememberedStyleground(fg)
    return lastSelectedStylegrounds[getStylegroundTabKey(fg)]
end

local function rememberStylegroundSelection(fg, style)
    if style then
        lastSelectedStylegrounds[getStylegroundTabKey(fg)] = style
    end
end

local function findStylegroundItemIndex(items, style)
    if not style then
        return nil
    end

    for index, item in ipairs(items or {}) do
        if item.data and item.data.style == style then
            return index
        end
    end
end

local function findStylegroundListItem(list, style)
    local children = list.children or {}
    local index = findStylegroundItemIndex(children, style)

    if index then
        return children[index]
    end
end

function stylegroundWindow.getStylegroundList(map, interactionData, fg)
    local items = stylegroundWindow.getStylegroundListItems(map, fg)
    local initialItem = findStylegroundItemIndex(items, getRememberedStyleground(fg)) or 1

    local listOptions = {
        initialItem = initialItem,
        draggable = true,
        listItemDragged = listItemDraggedHandler(interactionData),
        listItemCanInsert = listItemCanInsertHandler(interactionData),
        listItemDoubleClicked = listItemDoubleClickedHandler(interactionData),
    }

    local column, list = listWidgets.getList(function(element, listItem)
        -- Selecting something else ends a pending form edit session (one undo step per session)
        stylegroundWindow.endAutoEdit(interactionData)

        interactionData.listTarget = listItem
        interactionData.selectedTargets = getSelectedTargets(interactionData, element)
        interactionData.formData = prepareFormData(interactionData)

        -- Programmatic selections (initial opening and tab switching) must not replace the
        -- remembered row with a fallback. The callback receives the row data, not the UI item.
        if not restoringStylegroundSelection and interactionData.stylegroundListElement == element then
            rememberStylegroundSelection(fg, listItem and listItem.style)
        end

        stylegroundWindow.updateStylegroundForm(interactionData)
        stylegroundWindow.updateStylegroundPreview(interactionData)
    end, items, listOptions)

    -- Keep a little empty scroll space below the last row. The drag insertion line is drawn just
    -- below the last row; without this padding the scrollbox scissor clips it when dropping at
    -- the very end of a long list.
    list.style.padding = {0, 0, 0, 6}
    list:layout()

    -- Multi selection, like a file list: shift extends a range, ctrl toggles single rows. The
    -- selection is kept by style, so it survives the list being rebuilt.
    local selectionStyles = {}
    local anchorStyle

    -- While a layer is being dragged, do not highlight whatever row happens to be under the
    -- cursor: the ghost already represents the dragged rows and the hover flicker looks wrong.
    list:hook({
        update = function(orig, self, dt)
            local dragging = ui.dragging
            local suppressHover = stylegroundWindow.isExternalDragActive
                and stylegroundWindow.isExternalDragActive()

            while dragging and not suppressHover do
                if dragging == self then
                    suppressHover = true

                    break
                end

                dragging = dragging.parent
            end

            -- While a layer is being dragged, do not highlight whatever row happens to be under
            -- the cursor: the ghost already represents the dragged rows and the hover flicker
            -- looks wrong. This also covers effects dragged in from the tools list.
            if suppressHover then
                if ui.clearHovering then
                    ui.clearHovering()

                else
                    ui.hovering = false
                end
            end

            if orig then
                return orig(self, dt)
            end
        end
    })

    local function clearSelection()
        for k in pairs(selectionStyles) do
            selectionStyles[k] = nil
        end

        anchorStyle = nil
    end

    list.getIsSelected = function(self, item)
        local style = item.data and item.data.style

        if style and next(selectionStyles) then
            return selectionStyles[style] == true
        end

        return self.selected == item
    end

    list.setIsSelected = function(self, item, value)
        local style = item.data and item.data.style

        if not value or not style then
            clearSelection()
            self.selected = false

            return
        end

        if ctrlHeld() then
            if selectionStyles[style] then
                selectionStyles[style] = nil
                anchorStyle = nil

                -- Keep the plain selection in sync, otherwise the item would look selected again
                -- through the single selection fallback once nothing is left in the multi set
                self.selected = next(selectionStyles) and item or false

            else
                selectionStyles[style] = true
                anchorStyle = style
                self.selected = item
            end

            return
        end

        if shiftHeld() then
            local anchorItem

            if anchorStyle then
                for _, c in ipairs(self.children or {}) do
                    if c.data and c.data.style == anchorStyle then
                        anchorItem = c

                        break
                    end
                end
            end

            -- Programmatic selections (opening the panel, switching tabs, rebuilding the list and
            -- keyboard navigation) set list.selected without going through setIsSelected, so no
            -- shift anchor was recorded. Use the current selection as the anchor in that case,
            -- otherwise the first shift-click would only select the clicked row.
            if not anchorItem then
                local selectedItem = self.selected

                if selectedItem and selectedItem.data and selectedItem.data.style
                    and self:getIsSelected(selectedItem) then
                    anchorItem = selectedItem
                    anchorStyle = selectedItem.data.style
                end
            end

            if anchorItem and anchorItem.parent == item.parent then
                local fromIndex, toIndex = getItemRange(self, anchorItem, item)

                if fromIndex then
                    clearSelection()
                    anchorStyle = style

                    for i = fromIndex, toIndex do
                        local other = self.children[i]

                        if other and other.data and other.data.style then
                            selectionStyles[other.data.style] = true
                        end
                    end

                    self.selected = item

                    return
                end
            end
        end

        clearSelection()

        selectionStyles[style] = true
        anchorStyle = style
        self.selected = item
    end

    list.clearStyleSelection = function(self)
        clearSelection()
        self.selected = false
    end

    -- Moves the Shift range anchor without changing the current selection. Used after a drag so
    -- a following Shift-click extends from the row that was just dragged.
    list.setStyleSelectionAnchor = function(self, style)
        anchorStyle = style
    end

    -- Selects a set of styles at once, for example after pasting a multi selection. The primary
    -- style drives the form and receives focus; the rest stay highlighted as a multi selection.
    list.setStyleSelection = function(self, styles, primaryStyle)
        if not styles then
            return nil
        end

        clearSelection()

        local primaryItem

        for _, item in ipairs(self.children or {}) do
            local style = item.data and item.data.style

            if style and styles[style] then
                selectionStyles[style] = true

                if style == primaryStyle then
                    primaryItem = item
                end
            end
        end

        -- The requested row can be hidden (for example inside a collapsed group). Fall back to
        -- the first visible selected row so the form still switches to the pasted styles.
        if not primaryItem then
            for _, item in ipairs(self.children or {}) do
                local style = item.data and item.data.style

                if style and styles[style] then
                    primaryItem = item
                    primaryStyle = style

                    break
                end
            end
        end

        if not primaryItem then
            return nil
        end

        anchorStyle = primaryStyle
        self:setSelection(primaryItem.data, false, false)

        return primaryItem
    end

    return column, list, items
end

-- The window is a singleton while the stylegrounds tool is active
local currentWindow
local addingStyle = false

-- Keyboard shortcuts belong to the stylegrounds panel only while the cursor is over it. This
-- keeps Ctrl+C/X/V and Delete from also reaching the active workspace tool (for example the rooms
-- tool) when the panel is open.
function stylegroundWindow.isMouseInside()
    local window = currentWindow

    if not window or not window.parent then
        return false
    end

    local x, y = ui.mouseX, ui.mouseY

    if not x or not y or not window.screenX or not window.screenY then
        return false
    end

    return x >= window.screenX and x <= window.screenX + (window.width or 0)
        and y >= window.screenY and y <= window.screenY + (window.height or 0)
end

function stylegroundWindow.shouldCaptureShortcut(key)
    if not currentInteractionData or not stylegroundWindow.isMouseInside() then
        return false
    end

    if ctrlHeld() then
        return key == "c" or key == "x" or key == "v"
    end

    return key == "delete"
end

-- The panel only owns the keyboard while the cursor is over it (or while a form field is being
-- edited). This lets the active workspace tool receive shortcuts when the cursor is elsewhere.
function stylegroundWindow.shouldConsumeKeyboardEvents()
    return stylegroundWindow.isMouseInside() or textInputFocused()
end

function stylegroundWindow.handleKeyboardShortcut(key)
    if not currentInteractionData or textInputFocused() then
        return false
    end

    if ctrlHeld() then
        if key == "c" then
            stylegroundWindow.copySelection(currentInteractionData)

            return true

        elseif key == "x" then
            stylegroundWindow.cutSelection(currentInteractionData)

            return true

        elseif key == "v" then
            stylegroundWindow.pasteSelection(currentInteractionData)

            return true
        end

    elseif key == "delete" then
        removeStyle(currentInteractionData)

        return true
    end

    return false
end

-- Which list a new style goes to: the one currently shown in the window, foreground by default
local function getActiveForeground(interactionData)
    local activeList = interactionData and interactionData.stylegroundListElement

    if not activeList then
        return true
    end

    return activeList == interactionData.stylegroundListElementFg
end

-- Adds one style to the foreground or background list of the map and refreshes an open window
function stylegroundWindow.addStyle(name, foreground)
    local map = (currentInteractionData and currentInteractionData.map) or loadedState.map

    if not map or not name or addingStyle then
        return false
    end

    addingStyle = true

    if foreground == nil then
        foreground = getActiveForeground(currentInteractionData)
    end

    local styles = foreground and map.stylesFg or map.stylesBg
    local style = parallaxStruct.decode({})

    style.texture = name

    table.insert(styles, style)

    if currentInteractionData and currentInteractionData.rebuildListItems then
        local list = currentInteractionData.stylegroundListElement

        currentInteractionData.rebuildListItems(nil, list)
        selectStyleDeferred(currentInteractionData, style, list)
    end

    addingStyle = false

    return true
end

function stylegroundWindow.isOpen()
    return currentWindow ~= nil and currentWindow.parent ~= nil
end

function stylegroundWindow.closeForTool()
    if currentWindow and currentWindow.parent then
        currentWindow.parent:removeChild(currentWindow)
    end

    currentWindow = nil
    currentInteractionData = nil
end

-- Called before the UI is rebuilt. The window is created outside the regular windows registry, so
-- a stale currentWindow would otherwise keep isOpen() true even after its old window group has
-- been detached.
function stylegroundWindow.reset()
    stylegroundWindow.closeForTool()
end

-- Adds one style of a given kind to the foreground or background list: "parallax" (empty
-- texture), "group" or "effect" with the effect name
function stylegroundWindow.addStyleOfType(kind, effectName, foreground, targetParent, targetIndex)
    -- Prefer the map the open window works on: after a reload loadedState.map may be a new object
    local map = (currentInteractionData and currentInteractionData.map) or loadedState.map

    if not map or addingStyle then
        return false
    end

    addingStyle = true

    if foreground == nil then
        foreground = getActiveForeground(currentInteractionData)
    end

    local styles = foreground and map.stylesFg or map.stylesBg
    local parent = targetParent or styles
    local insertIndex = targetIndex or (#parent + 1)
    insertIndex = math.max(1, math.min(insertIndex, #parent + 1))
    local style

    if kind == "group" then
        style = createApply()

    elseif kind == "effect" and effectName then
        style = createEffect(effectName)

    else
        style = parallaxStruct.decode({})
        -- New parallax layers start with a valid texture, so the preview and the row name work
        -- right away instead of showing "Parallax - nil"
        style.texture = "bgs/00/bg0"
    end

    -- Effects declare which layer they support. Do not silently create an invalid style: the
    -- player would get a broken/ignored styleground and the user would wonder why nothing renders.
    if kind == "effect" and style then
        local allowed = foreground and effects.canForeground(style)
            or (not foreground and effects.canBackground(style))

        if not allowed then
            addingStyle = false

            local language = languageRegistry.getLanguage()
            local messageKey = foreground
                and language.ui.styleground_window.notify.effect_not_foreground
                or language.ui.styleground_window.notify.effect_not_background

            notifications.notify(string.format(tostring(messageKey), effects.displayName(language, style)))

            return false
        end
    end

    table.insert(parent, insertIndex, style)

    history.addSnapshot(snapshotStruct.create("Add styleground", {}, function()
        for i, s in ipairs(parent) do
            if s == style then
                table.remove(parent, i)

                break
            end
        end

        if currentInteractionData and currentInteractionData.rebuildListItems then
            currentInteractionData.rebuildListItems(nil, currentInteractionData.stylegroundListElement)
        end
    end, function()
        table.insert(parent, math.min(insertIndex, #parent + 1), style)

        if currentInteractionData and currentInteractionData.rebuildListItems then
            currentInteractionData.rebuildListItems(nil, currentInteractionData.stylegroundListElement)
        end
    end))

    if currentInteractionData and currentInteractionData.rebuildListItems then
        local list = currentInteractionData.stylegroundListElement

        currentInteractionData.rebuildListItems(nil, list)
        selectStyleDeferred(currentInteractionData, style, list)
    end

    addingStyle = false

    return true
end

-- Resolves the stylegrounds list position under the cursor for effects dragged from the tools
-- window. Returns nil when the cursor is not over the active stylegrounds list.
function stylegroundWindow.getDropTargetAt(x, y)
    local interactionData = currentInteractionData

    if not interactionData or not ui.root then
        return nil
    end

    local list = interactionData.stylegroundListElement
    local scroll = list and list.scrolledList

    if not list or not scroll then
        return nil
    end

    local function findList(element)
        while element and element.__type ~= "list" do
            element = element.parent
        end

        return element
    end

    local hovered = ui.root:getChildAt(x, y)
    local hoveredList = findList(hovered)

    if hoveredList and hoveredList ~= list then
        return nil
    end

    local insideScroll = x >= scroll.screenX and x <= scroll.screenX + scroll.width
        and y >= scroll.screenY and y <= scroll.screenY + scroll.height

    if not hoveredList and not insideScroll then
        return nil
    end

    local row = hovered

    while row and row.parent ~= list do
        row = row.parent
    end

    if row and row.parent ~= list then
        row = nil
    end

    local children = list.children or {}
    local rowIndex

    if row then
        for index, child in ipairs(children) do
            if child == row then
                rowIndex = index

                break
            end
        end
    end

    local after = false
    local lineY

    if row and rowIndex then
        after = y >= row.screenY + row.height * 0.5
        lineY = row.screenY + (after and row.height or 0)
    else
        local last = children[#children]
        lineY = last and (last.screenY + last.height) or list.screenY
    end

    local foreground = list == interactionData.stylegroundListElementFg
    local styles = foreground and interactionData.map.stylesFg or interactionData.map.stylesBg
    local data = row and row.data
    local targetParent = styles
    local targetStyle

    if data and data.parentStyle then
        targetParent = data.parentStyle.children or {}
        targetStyle = data.style
    elseif data and data.style then
        targetStyle = data.style
    end

    local targetIndex = #targetParent + 1

    if targetStyle then
        for index, style in ipairs(targetParent) do
            if style == targetStyle then
                targetIndex = index + (after and 1 or 0)

                break
            end
        end
    end

    return {
        foreground = foreground,
        parent = targetParent,
        index = targetIndex,
        list = list,
        lineX = list.screenX,
        lineY = lineY,
        lineWidth = list.width or list.innerWidth or 0
    }
end

-- Same list the texture dropdown of the window uses, so the tools window can show the very same
-- backgrounds as buttons
function stylegroundWindow.getParallaxOptions()
    if parallaxTextureOptions then
        return parallaxTextureOptions
    end

    local names = parallax.getParallaxNames() or {}

    table.sort(names)

    return names
end

-- Styles copied with Ctrl+C. The in-memory copy works even when the system clipboard is disabled,
-- the serialized copy lets styles be pasted into another editor instance.
local stylegroundClipboardFormat = "loenn_stylegrounds"
local stylegroundClipboard

local function writeStylegroundsToClipboard(styles, foreground)
    if not configs.editor.copyUsesClipboard then
        return
    end

    local success, text = utils.serialize({
        format = stylegroundClipboardFormat,
        foreground = foreground,
        styles = styles
    }, true, true, false)

    if success then
        love.system.setClipboardText(text)
    end
end

local function readStylegroundsFromClipboard()
    if not configs.editor.copyUsesClipboard then
        return nil
    end

    local text = love.system.getClipboardText()

    if not text or text:sub(1, 1) ~= "{" or text:sub(-1, -1) ~= "}" then
        return nil
    end

    local success, data = utils.unserialize(text, true, 3)

    if not success or type(data) ~= "table" or data.format ~= stylegroundClipboardFormat
        or type(data.styles) ~= "table" or #data.styles == 0 then
        return nil
    end

    return data
end

function stylegroundWindow.copySelection(interactionData)
    -- Recompute from the list instead of trusting the cached selectedTargets: after a rebuild or
    -- a drag the cached list can lag behind what is actually highlighted.
    local list = interactionData.stylegroundListElement
    local targets = list and getSelectedTargets(interactionData, list) or interactionData.selectedTargets or {}

    if #targets == 0 then
        return
    end

    local foreground = targets[1].foreground
    local styles = {}

    for _, target in ipairs(targets) do
        table.insert(styles, utils.deepcopy(target.style))
    end

    stylegroundClipboard = {
        foreground = foreground,
        styles = styles
    }

    writeStylegroundsToClipboard(styles, foreground)
end

function stylegroundWindow.cutSelection(interactionData)
    stylegroundWindow.copySelection(interactionData)
    removeStyle(interactionData)
end

function stylegroundWindow.pasteSelection(interactionData)
    -- Prefer the system clipboard so styles can be copied between editor instances. The
    -- in-memory copy remains the fallback when the clipboard contains something else.
    local clipboard = readStylegroundsFromClipboard() or stylegroundClipboard

    if not clipboard or #clipboard.styles == 0 then
        return
    end

    local map = interactionData.map

    -- Paste into the list that is currently shown, not into the side the styles were copied from
    local activeList = interactionData.stylegroundListElement
    local foreground = not activeList or activeList == interactionData.stylegroundListElementFg
    local styles = foreground and map.stylesFg or map.stylesBg
    local targets = interactionData.selectedTargets or {}

    -- Only the actual selection may act as the anchor. listTarget can be stale (for example after
    -- the list was rebuilt), which would insert the pasted styles somewhere in the middle.
    local anchor = targets[#targets]

    if anchor and anchor.foreground ~= foreground then
        anchor = nil
    end

    local parent = styles
    local index = #styles

    if anchor and anchor.parentStyle and anchor.parentStyle.children then
        parent = anchor.parentStyle.children
        index = #parent
    end

    if anchor then
        local found = false

        for i, s in ipairs(parent) do
            if s == anchor.style then
                index = i
                found = true

                break
            end
        end

        -- Anchor is not part of this list any more: append at the end
        if not found then
            index = #parent
        end
    end

    local commit = beginStyleEdit(map)
    local pastedStyles = {}

    for _, style in ipairs(clipboard.styles) do
        local pastedStyle = utils.deepcopy(style)

        table.insert(parent, index + 1, pastedStyle)
        table.insert(pastedStyles, pastedStyle)

        index = index + 1
    end

    commit("Paste stylegrounds")

    if interactionData.rebuildListItems then
        local list = interactionData.stylegroundListElement

        interactionData.rebuildListItems(nil, list)

        -- Move the focus/selection to the pasted rows. For a multi selection the last pasted
        -- style is the primary row, the rest stay selected together with it.
        selectStylesDeferred(interactionData, pastedStyles, list, pastedStyles[#pastedStyles])
    end
end

function stylegroundWindow.getWindowContent(map)
    local interactionData = {}
    local language = languageRegistry.getLanguage()

    -- Pick up replacement preview images dropped into assets/stylegrounds/ while the editor runs
    stylegroundPreviewData.clearImageCache()

    -- See TODO at top of file
    --cacheParallaxTextureOptions()

    interactionData.map = map

    -- Kept around so the tool can refresh the list when a style is added from the tools window
    currentInteractionData = interactionData
    interactionData.listTarget = getDefaultListTarget()
    interactionData.selectedTargets = {}

    local stylegroundFormGroup = uiElements.group({}):with(uiUtils.bottombound)
    -- Filled by updateStylegroundPreview: images are drawn by the container itself, so there is no
    -- child element to create here. Caching is disabled because a cached element draws with a
    -- translated coordinate system, which would move the sprite out of its box.
    local stylegroundPreview = uiElements.group({}):with({
        cacheable = false
    })

    local listColumnForeground, listForeground = stylegroundWindow.getStylegroundList(map, interactionData, true)
    local listColumnBackground, listBackground = stylegroundWindow.getStylegroundList(map, interactionData, false)

    listForeground.interactionData = interactionData
    listBackground.interactionData = interactionData

    interactionData.formContainerGroup = stylegroundFormGroup
    interactionData.stylegroundPreviewGroup = stylegroundPreview
    interactionData.stylegroundListElementFg = listForeground
    interactionData.stylegroundListElementBg = listBackground

    function interactionData.rebuildListItems(listTarget, list)
        if not list then
            list = interactionData.stylegroundListElement
        end

        local fg = list == interactionData.stylegroundListElementFg
        local newItems = stylegroundWindow.getStylegroundListItems(map, fg)

        -- Use current target if none specified
        if not listTarget then
            listTarget = list:getSelectedIndex()
        end

        list:updateItems(newItems, listTarget)

        return newItems
    end

    local function tabCallbackHandler(fg)
        return function()
            local currentList = fg and listForeground or listBackground
            local otherList = fg and listBackground or listForeground

            persistence.stylegroundWindowPreviousTab = fg and "foreground" or "background"
            interactionData.stylegroundListElement = currentList
            interactionData.stylegroundListElementOther = otherList

            ui.runLate(function()
                if #currentList.children > 0 then
                    local selectedStyle = currentList.selected
                        and currentList.selected.data
                        and currentList.selected.data.style
                    local targetItem = findStylegroundListItem(currentList, getRememberedStyleground(fg))
                        or findStylegroundListItem(currentList, selectedStyle)
                        or currentList.children[1]

                    restoringStylegroundSelection = true
                    widgetUtils.focusElement(targetItem)
                    currentList:setSelection(targetItem.data or targetItem, false, false)
                    restoringStylegroundSelection = false

                else
                    interactionData.listTarget = getDefaultListTarget()

                    stylegroundWindow.updateStylegroundForm(interactionData)
                    stylegroundWindow.updateStylegroundPreview(interactionData)
                end
            end)
        end
    end

    local tabs = {
        {
            title = tostring(language.ui.styleground_window.tab_foreground),
            content = listColumnForeground,
            callback = tabCallbackHandler(true)
        },
        {
            title = tostring(language.ui.styleground_window.tab_background),
            content = listColumnBackground,
            callback = tabCallbackHandler(false)
        },
    }
    local initialTab = persistence.stylegroundWindowPreviousTab == "background" and 2 or 1

    -- The left column is as wide as the longest item text, or as wide as the two tab buttons when
    -- both lists are empty
    local measureLabel = uiElements.label("")
    local measureFont = measureLabel.style.font

    local tabsWidth = 32

    for index, tab in ipairs(tabs) do
        if index > 1 then
            tabsWidth = tabsWidth + 8
        end

        tabsWidth = tabsWidth + measureFont:getWidth(tab.title)
    end

    local uiScale = configs.ui.theme.uiScale or 1
    local tabbedWindowOptions = {
        respectSiblings = false,
        initialTab = initialTab,
        -- Let the layer list determine its own width from the currently visible rows. The old
        -- value measured every row in both tabs and therefore could only ever grow.
        minWidth = math.ceil(math.max(tabsWidth, 160 * uiScale))
    }
    local _, tabbedContent = tabbedWindow.createWindow("", tabs, tabbedWindowOptions)

    -- Match the titlebar label: the panel padding inside the titlebar is 8px, so the tab strip
    -- and the layer tree need the same left inset to line up with the "Stylegrounds" title.
    tabbedContent.style.padding = {4, 0, 0, 0}

    interactionData.tabbedContent = tabbedContent

    local function applyListPaneWidth(width)
        width = width or tabbedContent.width or 0

        if width <= 0 then
            return
        end

        -- The pane width includes the new left inset; the list itself lives in the content area.
        local paddingLeft = tabbedContent.style:getIndex("padding", 1) or 0
        local paddingRight = tabbedContent.style:getIndex("padding", 3) or 0
        width = math.max(0, width - paddingLeft - paddingRight)

        for _, list in ipairs({listForeground, listBackground}) do
            list._manualWidth = width
            list.width = width
            list.maxWidth = width
            list.autoWidth = false
            list.grow = false
            list:reflow()
            list:layoutLateChildren()
        end
    end

    interactionData.applyListPaneWidth = applyListPaneWidth

    local stylegroundMinWidth = math.floor(160 * uiScale)
    local stylegroundMaxWidth = math.floor(600 * uiScale)

    local stylegroundSplitter
    stylegroundSplitter = splitter.create({
        minWidth = stylegroundMinWidth,
        maxWidth = stylegroundMaxWidth,
        line = true,

        getWidth = function()
            return tabbedContent.width
        end,

        setWidth = function(width)
            tabbedContent.width = width
            tabbedContent.maxWidth = width
            tabbedContent.autoWidth = false
            interactionData.applyListPaneWidth(width)
            tabbedContent:reflow()
        end
    })

    stylegroundWindow.updateStylegroundForm(interactionData)
    stylegroundWindow.updateStylegroundPreview(interactionData)

    -- Left: the foreground/background tabs, the tab content already fills the window height.
    -- Right: preview on top, options and buttons at the bottom.
    local rightSpacer = uiElements.new({}):with(uiUtils.fillHeight(true))

    local rightColumn = uiElements.column({
        stylegroundPreview,
        rightSpacer,
        stylegroundFormGroup
    }):with(uiUtils.fillHeight(false))

    local layout = uiElements.row({
        tabbedContent,
        stylegroundSplitter,
        rightColumn
    }):with(uiUtils.fillHeight(true))

    return layout, interactionData
end

-- Photoshop-like drag ghost for the layer rows. It is drawn by the window after its normal
-- contents, so it stays above the list and follows the cursor while a layer (or a multi
-- selection) is being dragged.
local function drawStylegroundDragGhost(interactionData, state)
    local dragging = ui.dragging
    local list = interactionData and interactionData.stylegroundListElement

    if not dragging or not list then
        state.active = false

        return
    end

    local target = dragging
    local belongsToActiveList = false

    while target do
        if target == list then
            belongsToActiveList = true

            break
        end

        target = target.parent
    end

    if not belongsToActiveList then
        state.active = false

        return
    end

    local mouseX, mouseY = ui.mouseX, ui.mouseY

    if not mouseX or not mouseY then
        return
    end

    -- Do not flash the ghost for a plain click: wait for a real drag distance.
    if not state.active then
        state.active = true
        state.startX, state.startY = mouseX, mouseY

        return
    end

    if math.abs(mouseX - state.startX) < 4 and math.abs(mouseY - state.startY) < 4 then
        return
    end

    local rows = {}
    local draggedIsSelected = false

    for _, child in ipairs(list.children or {}) do
        if child.data and list:getIsSelected(child) then
            table.insert(rows, child)

            if child == dragging then
                draggedIsSelected = true
            end
        end
    end

    -- Dragging an unselected row should not show the previously selected layers instead.
    if dragging.data and not draggedIsSelected then
        rows = {dragging}
    end

    if #rows == 0 then
        return
    end

    local screenWidth = love.graphics.getWidth()
    local barWidth = math.max(120, math.floor(list.width or 200))
    local x = math.max(4, math.min(mouseX + 12, screenWidth - barWidth - 4))
    local spacing = 1
    local y = mouseY
    local previousFont = love.graphics.getFont()
    local firstLabel = rows[1].label
    local firstFont = firstLabel and firstLabel.style and firstLabel.style.font or previousFont
    local barHeight = math.max(16, math.floor(firstFont:getHeight() + 4))
    local totalHeight = #rows * barHeight + (#rows - 1) * spacing

    for i, row in ipairs(rows) do
        local barY = math.floor(y + (i - 1) * (barHeight + spacing))
        local style = row.style
        local bg = style and style.bg

        if not bg or not bg[1] then
            bg = style and style.normalBG or {0.13, 0.13, 0.13, 0.9}
        end

        -- Semi-transparent copy of the row: same bar shape/background, just floating above the
        -- list and stacked downwards for a multi selection.
        love.graphics.setColor(bg[1], bg[2], bg[3], (bg[4] or 1) * 0.85)
        love.graphics.rectangle("fill", x, barY, barWidth, barHeight)

        local label = row.label

        if label then
            local labelStyle = label.style
            local font = labelStyle and labelStyle.font or previousFont
            local color = labelStyle and labelStyle.color
            local text = label.text or ""

            love.graphics.setFont(font)

            if color and color[1] then
                love.graphics.setColor(color[1], color[2], color[3], (color[4] or 1) * 0.95)

            else
                love.graphics.setColor(1, 1, 1, 0.95)
            end

            local textX = x + (label.realX or label.x or 8)
            local textY = barY + math.floor((barHeight - font:getHeight()) * 0.5)

            love.graphics.print(text, math.floor(textX), math.floor(textY))
        end
    end

    -- One outline around the whole ghost stack (not one per bar).
    love.graphics.setColor(0.7, 0.75, 0.85, 0.65)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x - 0.5, y - 0.5, barWidth + 1, totalHeight + 1)

    love.graphics.setLineWidth(1)
    love.graphics.setFont(previousFont)
    love.graphics.setColor(1, 1, 1, 1)
end

-- Ghost/insertion line for effects dragged from the tools window. It is kept separate from the
-- normal row drag ghost because there is no existing list item on the stylegrounds list yet.
local externalDragState = {active = false}

function stylegroundWindow.isExternalDragActive()
    return externalDragState.active
end

function stylegroundWindow.setExternalDrag(active, label, x, y, target)
    externalDragState.active = active
    externalDragState.label = label
    externalDragState.x = x
    externalDragState.y = y
    externalDragState.target = target
end

local function drawExternalDragGhost(interactionData)
    if not externalDragState.active then
        return
    end

    local list = interactionData and interactionData.stylegroundListElement
    local x = (externalDragState.x or ui.mouseX or 0) + 12
    local y = externalDragState.y or ui.mouseY or 0
    local width = math.max(120, math.floor(list and list.width or 200))
    local height = 18
    local previousFont = love.graphics.getFont()
    local firstRow = list and list.children and list.children[1]
    local font = firstRow and firstRow.label and firstRow.label.style and firstRow.label.style.font
        or previousFont

    love.graphics.setFont(font)
    love.graphics.setColor(0.13, 0.13, 0.13, 0.85)
    love.graphics.rectangle("fill", x, y, width, height)

    love.graphics.setColor(0.7, 0.75, 0.85, 0.65)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x - 0.5, y - 0.5, width + 1, height + 1)

    love.graphics.setColor(1, 1, 1, 0.95)
    love.graphics.print(tostring(externalDragState.label or ""),
        math.floor(x + 8), math.floor(y + (height - font:getHeight()) * 0.5))

    local target = externalDragState.target

    if target then
        love.graphics.setColor(1, 1, 1, 0.9)
        love.graphics.rectangle("fill", target.lineX, target.lineY, target.lineWidth, 1)
    end

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(previousFont)
end

function stylegroundWindow.editStylegrounds(map)
    if not map then
        return
    end

    -- Repeated clicks only ever open one window
    if stylegroundWindow.isOpen() then
        return currentWindow
    end

    local window
    local layout, interactionData = stylegroundWindow.getWindowContent(map)

    local language = languageRegistry.getLanguage()
    local windowTitle = tostring(language.ui.styleground_window.window_title)

    -- Figure out some smart sizing things here, this is too hardcoded
    -- Still doesn't fit all the elements, good enough for now
    window = uiElements.window(windowTitle, layout):with({
        height = WINDOW_STATIC_HEIGHT
    })
    interactionData.window = window

    -- The drag ghost is drawn after the window's contents and must not end up inside a cached
    -- window canvas, otherwise it would be clipped to the window/old cursor position.
    window.cacheable = false

    local dragGhostState = {active = false}

    window:hook({
        draw = function(orig, self, ...)
            orig(self, ...)
            drawStylegroundDragGhost(interactionData, dragGhostState)
            drawExternalDragGhost(interactionData)
        end
    })

    local windowCloseCallback = windowPersister.getWindowCloseCallback(windowPersisterName)

    local function onClose(w)
        -- Commit a pending form edit session so it stays undoable after the window is gone
        if currentInteractionData then
            stylegroundWindow.endAutoEdit(currentInteractionData)
        end

        currentWindow = nil
        currentInteractionData = nil

        cellHoverPreview.hide()
        cellHoverPreviewOwned = false

        -- The styleground clipboard lives only as long as the window
        stylegroundClipboard = nil

        -- Leaving the tool open would keep an empty list around: fall back to the selection tool
        local toolHandler = require("tools")

        if toolHandler.currentToolName == "stylegrounds" then
            -- Use the normal tools-window selection path so the top list, eventStates and all
            -- dependent lists switch together. Calling toolHandler.selectTool directly leaves
            -- the tools window thinking Stylegrounds is still selected.
            local success, toolsWindow = pcall(require, "ui/windows/tools")

            if success and toolsWindow and toolsWindow.selectTool then
                toolsWindow.selectTool("selection")
            end

            if toolHandler.currentToolName ~= "selection" then
                toolHandler.selectTool("selection")
            end

            local windowsOk, windowsHandler = pcall(require, "ui.windows")
            local tools = windowsOk and windowsHandler.windows and windowsHandler.windows.tools

            if tools then
                if tools.toolList then
                    tools.toolList:setSelection("selection", true)
                end

                if tools.eventStates then
                    tools.eventStates.tool = "selection"
                end
            end
        end

        return windowCloseCallback(w)
    end

    -- The window group is only attached once the UI root is ready: fall back to the window group
    -- of the root, so opening the window from the tool does not depend on the load order
    local parentGroup = stylegroundWindowGroup.parent

    if not parentGroup then
        local ok, uiRoot = pcall(require, "ui.ui_root")

        parentGroup = ok and uiRoot.getWindowGroup() or nil
    end

    -- The close button is part of the titlebar, so it has to be added before the layout is forced
    widgetUtils.addWindowCloseButton(window, onClose)

    -- This window is deliberately not position-persisted: it always opens centered. Layout is
    -- forced first so the size used for centering is final.
    if parentGroup then
        parentGroup:addChild(window)

        window:layout()
        window:layoutLate()

        if interactionData.applyListPaneWidth then
            ui.runLate(function()
                interactionData.applyListPaneWidth(interactionData.tabbedContent.width)
            end)
        end

        -- Center inside the area left of the right toolbar, clamped to the window
        local parentWidth = parentGroup.width or love.graphics.getWidth()
        local parentHeight = parentGroup.height or love.graphics.getHeight()
        local toolbarWidth = 0
        local success, windowsHandler = pcall(require, "ui.windows")

        if success and windowsHandler.windows and windowsHandler.windows.tools then
            local toolsWindow = windowsHandler.windows.tools

            toolbarWidth = (toolsWindow.width or 0) + (toolsWindow.style and toolsWindow.style.padding or 0)
        end

        local availableWidth = math.max(window.width, parentWidth - toolbarWidth)
        local x = math.floor((availableWidth - window.width) / 2)
        local y = math.floor((parentHeight - window.height) / 2)

        x = math.max(0, math.min(x, parentWidth - window.width))
        y = math.max(0, math.min(y, parentHeight - window.height))

        widgetUtils.moveWindow(window, x, y, 0, 0, 0)
    end

    widgetUtils.preventOutOfBoundsMovement(window)
    widgetUtils.consumeKeyboardEvents(window, stylegroundWindow.shouldConsumeKeyboardEvents)

    -- Install after consumeKeyboardEvents, so this hook is the outer one and sees the keys first.
    -- While a form field is focused its own handling wins: the list shortcuts are isolated.
    window:hook({
        onKeyPress = function(orig, self, key, scancode, isrepeat)
            if stylegroundWindow.shouldCaptureShortcut(key) then
                stylegroundWindow.handleKeyboardShortcut(key)

                return true
            end

            if orig then
                return orig(self, key, scancode, isrepeat)
            end

            return false
        end
    })

    currentWindow = window

    updateStylegroundWindowHeight(interactionData)

    ui.runLate(function()
        if currentInteractionData ~= interactionData or not window.parent then
            return
        end

        if interactionData.applyListPaneWidth then
            interactionData.applyListPaneWidth(interactionData.tabbedContent.width)
        end

        stylegroundWindow.updateStylegroundForm(interactionData)
        stylegroundWindow.updateStylegroundPreview(interactionData)
    end)

    return window
end

-- Group to get access to the main group and sanely inject windows in it
function stylegroundWindow.getWindow()
    stylegroundEditor.stylegroundWindow = stylegroundWindow

    return stylegroundWindowGroup
end

return stylegroundWindow