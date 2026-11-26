local ui, uiUtils, uiElements = require("ui").quick()
local utils = require("utils")

local configs = require("configs")

local themer = {}

local affectedByScale = {
    spacing = true,
    padding = true,
    margin = true,
    contentPadding = true,
    radius = true,
    thickness = true,
}

function themer.dump()
    local theme = {}

    for id, el in pairs(uiElements) do
        if utils.startsWith(id, "__") then
            local style = el.__default
            style = style and style.style

            if not style then
                style = {}
            end

            local sub = {}

            for key, value in pairs(style) do
                sub[key] = value
            end

            if sub then
                theme[id] = sub
            end
        end
    end

    return theme
end

function themer.apply(theme, scale)
    if not theme then
        return
    end

    scale = configs.ui.theme.uiScale or 1

    local previousFont = uiElements.__label.__default.style.font

    themer.applyElementStyles(theme)
    themer.applyFontInfo(theme, scale, previousFont)
    themer.applyStyleScale(scale)
end

function themer.applyFontInfo(theme, scale, previousFont)
    local fonts = require("fonts")
    local defaultFontSize = configs.ui.theme.defaultFontSize or 12
    local labelFontSizeFallback = math.floor(defaultFontSize * scale)
    local labelFontSize = theme.labelFontSize or labelFontSizeFallback
    local labelFilename = theme.labelFilename
    local labelFont = theme.labelFont

    -- UI font override. Empty keeps the theme/default UI font; a path overrides it.
    local configuredFont = configs.ui.theme and configs.ui.theme.labelFontPath

    if configuredFont and configuredFont ~= "" then
        labelFilename = configuredFont
        labelFont = nil
    end

    if not labelFont then
        local defaultFont = fonts.loadUIFont(fonts.getDefaultUIFontPath(), labelFontSize)
            or love.graphics.newFont(labelFontSize)
        local targetHeight = defaultFont:getHeight()

        if labelFilename then
            local loaded = fonts.loadUIFont(labelFilename, labelFontSize)

            if loaded then
                -- Fonts have different vertical metrics. Keep the label height aligned with the
                -- default UI font so choosing a different font cannot push the whole UI upward.
                local loadedHeight = loaded:getHeight()

                if loadedHeight > 0 and loadedHeight ~= targetHeight then
                    local adjustedSize = math.max(1, math.floor(labelFontSize * targetHeight / loadedHeight + 0.5))
                    local adjusted = fonts.loadUIFont(labelFilename, adjustedSize)

                    if adjusted then
                        loaded = adjusted
                    end
                end

                loaded:setLineHeight(defaultFont:getLineHeight())
                labelFont = loaded

            else
                labelFont = defaultFont
            end

        else
            labelFont = defaultFont
        end
    end

    if labelFont then
        if fonts.addCJKFallback then
            fonts.addCJKFallback(labelFont, labelFontSize)
        end

        uiElements.__label.__default.style.font = labelFont

        -- Existing labels keep the font they were created with. Walk every known label and the
        -- current UI tree, otherwise switching back from a font theme leaves its font behind.
        if previousFont and previousFont ~= labelFont then
            local function updateLabel(label)
                local style = label and label.style

                if style and style.font == previousFont then
                    style.font = labelFont

                    if label.forceText and label._textStr then
                        label._text = false
                        label:forceText(label._textStr)

                        if label.reflow then
                            label:reflow()
                        end
                    end
                end
            end

            local labels = uiElements.label and uiElements.label.__instances

            if labels then
                for label in pairs(labels) do
                    updateLabel(label)
                end
            end

            if ui.root then
                local function updateLabels(element)
                    if not element then
                        return
                    end

                    -- Only labels have the font styling property. Reading style.font on other
                    -- elements (notably the UI root) raises an "unknown styling property" error.
                    if element.is and element:is("label") then
                        updateLabel(element)
                    end

                    for _, child in ipairs(element.children or {}) do
                        updateLabels(child)
                    end
                end

                updateLabels(ui.root)
            end
        end
    end
end

function themer.applyElementStyles(theme)
    -- Drop keys that were introduced by the previous theme but are not part of the new theme.
    -- Without this, switching from a theme with extra style keys leaves those values behind on
    -- elements that the next theme does not override.
    local previous = themer.current

    if previous and previous ~= themer.default and previous ~= theme then
        for id, previousTheme in pairs(previous) do
            local baseTheme = themer.default[id] or {}
            local nextTheme = theme[id] or {}
            local el = uiElements[id]
            local style = el and el.__default and el.__default.style

            if style then
                for key in pairs(previousTheme) do
                    if baseTheme[key] == nil and nextTheme[key] == nil then
                        style[key] = nil
                    end
                end
            end
        end
    end

    if themer.current ~= themer.default and theme ~= themer.default then
        themer.applyElementStyles(themer.default)
    end

    themer.current = theme

    for id, tel in pairs(theme) do
        local el = uiElements[id]
        local style = el and el.__default

        if el and style then
            style = style and style.style

            if not style then
                style = {}
                el.__default.style = style
            end

            for key, value in pairs(tel) do
                style[key] = value
            end
        end
    end

    if ui.root then
        ui.globalReflowID = ui.globalReflowID + 1
    end
end

-- Naively apply the scale to all default styles according to affectedByScale
function themer.applyStyleScale(scale)
    -- Nothing to do
    if not scale or scale == 1 then
        return
    end

    for id, element in pairs(uiElements) do
        if utils.startsWith(id, "__") then
            local style = element and element.__default and element.__default.style

            if style then
                for key, value in pairs(style) do
                    if affectedByScale[key] then
                        if type(value) == "number" then
                            style[key] = math.floor(value * scale)

                        elseif type(value) == "table" then
                            for i, v in ipairs(value) do
                                style[key][i] = math.floor(v * scale)
                            end
                        end
                    end
                end
            end
        end
    end
end

function themer.skin(theme, deep, element)
    theme = theme or themer.default

    local function skin(el)
        local style = el.style
        local types = el.__types

        local custom = {}

        for key, value in pairs(style) do
            custom[key] = value
        end

        for i = #types, 1, -1 do
            local elementType = types[i]
            local elementBase = uiElements[elementType]
            local elementTheme = theme[elementType]

            if elementBase then
                elementBase = elementBase.__default.style

                if elementBase then
                    for key, value in pairs(elementBase) do
                        if type(value) == "table" then
                            local copy = {}

                            for k, v in pairs(value) do
                                copy[k] = v
                            end

                            value = copy
                        end

                        style[key] = value
                    end
                end
            end

            if elementTheme then
                for key, value in pairs(elementTheme) do
                    if type(value) == "table" then
                        local copy = {}

                        for k, v in pairs(value) do
                            copy[k] = v
                        end

                        value = copy
                    end

                    style[key] = value
                end
            end
        end

        for key, value in pairs(custom) do
            style[key] = value
        end

        if deep then
            local children = el.children

            if children then
                for i = 1, #children do
                    skin(children[i])
                end
            end
        end
    end

    if element then
        return skin(element)
    end

    if element == nil and type(deep) == "table" then
        return skin(deep)
    end

    if deep == nil then
        deep = true
    end

    return skin
end

themer.default = themer.dump()
themer.current = themer.default

return themer