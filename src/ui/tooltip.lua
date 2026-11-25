local ui = require("ui")
local uiElements = require("ui.elements")
local uiUtils = require("ui.utils")
local hoverPreview = require("ui.hover_preview")

local widgetUtils = require("ui.widgets.utils")
local configs = require("configs")

local lastX, lastY = 0, 0
local waitedDuration = 0

local targetElement
local tooltipExists = false
local tooltipWindow

local tooltipHandler = {}

-- Hovering usually lands on an inner element (a checkbox, a label) while the tooltip text sits
-- on the row that contains it. Walk up to the first ancestor that actually carries one.
local function findTooltipText(element)
    while element do
        local tooltipText = rawget(element, "tooltipText")

        if tooltipText then
            return tooltipText
        end

        element = element.parent
    end

    return nil
end

-- Submenus are appended to ui.root.children when they open, which puts them above this window.
-- Bring the tooltip back to the top whenever the hovered target changes so it is never covered.
local function raiseTooltipWindow(window)
    local root = ui.root

    if not root or not root.children then
        return
    end

    local children = root.children
    local index

    for i, child in ipairs(children) do
        if child == window then
            index = i

            break
        end
    end

    if index == #children then
        return
    end

    if index then
        table.remove(children, index)
    end

    table.insert(children, window)

    if root.recollect then
        root:recollect()
    end
end

function tooltipHandler.tooltipWindowUpdate(orig, self, dt)
    orig(self, dt)

    local tooltipWaitDuration = configs.editor.tooltipWaitDuration or 0
    local cursorX, cursorY = love.mouse.getPosition()
    local hovered = ui.hovering
    local waitedEnough = waitedDuration >= tooltipWaitDuration

    if not waitedEnough then
        if cursorX == lastX and cursorY == lastY then
            waitedDuration += dt

        else
            lastX, lastY = cursorX, cursorY
            waitedDuration = 0
        end
    end

    if hovered ~= targetElement then
        waitedDuration = 0

        if hovered then
            local tooltipText = findTooltipText(hovered)

            if tooltipText then
                tooltipWindow.children[1]:setText(tooltipText)
                raiseTooltipWindow(tooltipWindow)
            end

            targetElement = hovered
            tooltipExists = not not tooltipText

        else
            targetElement = false
            tooltipExists = false
        end
    end

    -- The hover preview already shows the tooltip text under the image
    if tooltipExists and waitedEnough and not hoverPreview.isShown() then
        widgetUtils.moveWindow(tooltipWindow, cursorX, cursorY - tooltipWindow.height)

    elseif tooltipWindow.x ~= -1024 or tooltipWindow.y ~= -1024 then
        widgetUtils.moveWindow(tooltipWindow, -1024, -1024, 0, false)
    end
end

function tooltipHandler.getTooltipWindow()
    if not tooltipWindow then
        tooltipWindow = uiElements.panel({
            uiElements.label("Test")
        }):with({
            interactive = -2,
            updateHidden = true
        }):hook({
            update = tooltipHandler.tooltipWindowUpdate
        })
    end

    return tooltipWindow
end

return tooltipHandler