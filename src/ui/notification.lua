-- TODO - Change notification start point and direction? Allow notifications from multiple locations?
-- TODO - "Rich labels", some minimal markup support
-- TODO - Add close button in notification panel? Click to close?
-- TODO - Lazy layout update the notifcation back off screen, visual odities if window is resized

local ui = require("ui")
local uiElements = require("ui.elements")
local uiUtils = require("ui.utils")
local utf8 = require("utf8")

local widgetUtils = require("ui.widgets.utils")

local notificationPopup = {}

local activeNotification
local notificationWindows = {}
local notificationGroup = uiElements.group(notificationWindows)

local edgePadding = 16

-- Lazily required: ui.ui_root requires this module, so requiring it up here would be circular.
local uiRoot

local function getWindowGroup()
    if uiRoot == nil then
        local ok, module = pcall(require, "ui.ui_root")
        uiRoot = ok and module or false
    end

    return uiRoot and uiRoot.getWindowGroup()
end

-- Notifications are anchored to the bottom right corner of the workspace (the screen space not
-- taken up by panels pinned to the right / bottom edges), not to the bottom right corner of the
-- whole window. Otherwise they cover UI elements living inside those panels, such as the
-- material search field at the bottom of the tools window.
--
-- There can be more than one panel pinned to the right edge. Only the one reaching the bottom of
-- the window is a real full height dock; the others are floating panels which happen to sit
-- against the edge, and the notification should not be pushed to the left of those.
local function getWorkspaceBounds()
    local windowWidth, windowHeight = love.graphics.getDimensions()
    local group = getWindowGroup()

    if not group or not group.children then
        return 0, windowWidth, windowHeight
    end

    local left, right, bottom = 0, windowWidth, windowHeight
    local rightBounds = {}
    local rightDockBound = nil

    for _, child in ipairs(group.children) do
        local screenX, screenY, width, height = child.screenX, child.screenY, child.width, child.height

        if screenX and screenY and width and height then
            -- Only consider windows which are actually flush with an edge, as pinned panels are
            if child._pinnedEdge == "right" and screenX > 0 and screenX + width >= windowWidth - 64 then
                -- A dock can expose the element its content starts at, for docks which keep a
                -- floating column in front of it (the tool column of the tools window)
                local contentElement = child._workspaceRightElement
                local contentX = contentElement and contentElement.screenX

                if contentX and contentX > screenX then
                    screenX = contentX
                end

                table.insert(rightBounds, screenX)

                if screenY + height >= windowHeight - 8 then
                    rightDockBound = rightDockBound and math.min(rightDockBound, screenX) or screenX
                end

            elseif child._pinnedEdge == "left" and width > 0 and screenX <= 0 then
                left = math.max(left, screenX + width)

            elseif child._pinnedEdge == "bottom" and screenY > 0 and screenY + height >= windowHeight - 64 then
                bottom = math.min(bottom, screenY)
            end
        end
    end

    if rightDockBound then
        right = rightDockBound

    else
        for _, bound in ipairs(rightBounds) do
            right = math.min(right, bound)
        end
    end

    return left, right, bottom
end

-- Long messages (map paths and the like) would stretch the popup across a large part of the
-- workspace, which makes a corner popup look like it is centered. Wrap them to the available
-- width instead, and only trim with an ellipsis when even that would take too many lines.
local function safeTextWidth(font, text)
    local ok, width = pcall(font.getWidth, font, text)

    if ok and type(width) == "number" then
        return width
    end

    return 0
end

local function trimToWidth(text, font, maxWidth)
    if safeTextWidth(font, text) <= maxWidth then
        return text
    end

    local suffix = "..."
    local length = utf8.len(text) or #text

    while length > 0 do
        local cut = utf8.offset(text, length) or 1
        local candidate = text:sub(1, cut - 1) .. suffix

        if safeTextWidth(font, candidate) <= maxWidth then
            return candidate
        end

        length = length - 1
    end

    return suffix
end

-- Word wraps the text to maxWidth, keeping explicit line breaks. Returns at most
-- maxLines lines, the last one ellipsized when not everything fits
local function wrapToWidth(text, font, maxWidth, maxLines)
    local lines = {}

    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        if paragraph == "" then
            table.insert(lines, "")

        else
            local current = ""

            for word in paragraph:gmatch("%S+") do
                local candidate = current == "" and word or (current .. " " .. word)

                if current == "" or safeTextWidth(font, candidate) <= maxWidth then
                    current = candidate

                else
                    table.insert(lines, current)
                    current = word
                end
            end

            if current ~= "" then
                table.insert(lines, current)
            end
        end
    end

    if #lines <= maxLines then
        return table.concat(lines, "\n")
    end

    local kept = {}

    for i = 1, maxLines do
        kept[i] = lines[i]
    end

    kept[maxLines] = trimToWidth(kept[maxLines] .. " " .. lines[maxLines + 1], font, maxWidth)

    return table.concat(kept, "\n")
end

local popupStartDuration = 0.4
local popupStopDuration = 0.4

local function removePopupWindow(window)
    for i = #notificationWindows, 1, -1 do
        local target = notificationWindows[i]

        if target == window then
            table.remove(notificationWindows, i)
            notificationGroup:reflow()
            ui.root:recollect()
            window:removeSelf()

            if activeNotification == target then
                activeNotification = false
            end

            return
        end
    end
end

local function createPopupWindow(popup)
    local widgets = widgetUtils.getSimpleOverlayWidget(popup.widget, popup)
    local row = uiElements.row(widgets)

    if type(popup.widget) == "string" then
        local label = widgets[1] or widgets

        if label.style and label.style.font then
            local workspaceLeft, workspaceRight = getWorkspaceBounds()
            -- Leave room for the close button and the panel padding
            local available = workspaceRight - workspaceLeft - edgePadding * 2 - 48
            local maxTextWidth = math.max(160, math.min(available, notificationPopup.maxTextWidth))

            label.text = wrapToWidth(popup.widget, label.style.font, maxTextWidth, notificationPopup.maxLines)
        end
    end

    row.style.bg = {}
    row.style.padding = 0

    local panel = uiElements.panel({row}):hook({
        update = notificationPopup.update
    }):with({
        updateHidden = true,
        interactive = 2,

        x = -1024,
        y = -1024,

        popup = popup,
    })

    if popup.settings and popup.settings.clickToClose then
        panel:with(uiUtils.hook({
            onClick = function(orig, self, x, y, button, ...)
                if button == 1 then
                    return removePopupWindow(panel)
                end

                orig(self, x, y, button, ...)
            end
        }))
    end

    local closeButton = uiElements.button(uiElements.image("ui:icons/close"), function()
        removePopupWindow(panel)
    end):with({
        y = 0,
    }):with(uiUtils.rightbound)

    closeButton.style = {
        padding = 6
    }

    table.insert(widgets, closeButton)
    table.insert(notificationWindows, panel)

    row:reflow()
    notificationGroup:reflow()
    ui.root:recollect()

    return panel
end

local popupStates = {
    "starting",
    "waiting",
    "stopping"
}

local function closePopup(popup)
    if popup.stateIndex == 2 then
        popup.durations[popup.stateIndex] = 0
    end
end

function notificationPopup.clearNotifications(tag)
    for i = #notificationWindows, 1, -1 do
        local target = notificationWindows[i]
        local popup = target.popup

        if not tag or popup.settings and popup.settings.tag == tag then
            table.remove(notificationWindows, i)

            if activeNotification == target then
                activeNotification = false
            end
        end
    end

    notificationGroup:reflow()
    ui.root:recollect()
end

notificationPopup.defaultDuration = 6

-- Notifications are allowed to get wide enough to read comfortably; anything
-- wider is wrapped, and only gets an ellipsis when it would take too many lines
notificationPopup.maxTextWidth = 720
notificationPopup.maxLines = 8

-- Duration comes from the settings (General -> Notification Duration), with the
-- default above as a fallback. Negative durations are sticky.
local function getDuration(duration)
    if duration then
        return duration
    end

    local success, configs = pcall(require, "configs")
    local configured = success and configs.general and configs.general.notificationDuration

    if type(configured) == "number" and configured > 0 then
        return configured
    end

    return notificationPopup.defaultDuration
end

-- Notifications that ask for a click are built from a widget function; plain text ones are
-- strings. While such an interactive notification is visible, text notifications are suppressed
-- entirely, so they cannot cover or distract from the one that needs an answer.
local function isInteractiveNotification(target)
    return target.popup ~= nil and type(target.popup.widget) == "function"
end

local function hasInteractiveNotification()
    for _, target in ipairs(notificationWindows) do
        if isInteractiveNotification(target) then
            return true
        end
    end

    return false
end

local function clearTextNotifications()
    for i = #notificationWindows, 1, -1 do
        local target = notificationWindows[i]

        if not isInteractiveNotification(target) then
            table.remove(notificationWindows, i)

            if activeNotification == target then
                activeNotification = false
            end
        end
    end

    notificationGroup:reflow()

    if ui.root then
        ui.root:recollect()
    end
end

function notificationPopup.notify(widget, duration, settings)
    local interactive = type(widget) == "function"

    if interactive then
        -- A notification that needs a click replaces the plain text ones in front of it
        clearTextNotifications()

    elseif hasInteractiveNotification() then
        -- Text notifications are pointless while something waits for a click
        return

    else
        -- A new text notification replaces the one currently shown instead of stacking up
        clearTextNotifications()
    end

    local popup = {
        widget = widget,
        durations = {
            popupStartDuration,
            getDuration(duration),
            popupStopDuration
        },
        settings = settings,
        timeAcc = 0,
        lerpPercent = 0,
        state = "starting",
        stateIndex = 1,
        close = closePopup
    }

    if settings and settings.clearSameTag and settings.tag then
        notificationPopup.clearNotifications(settings.tag)
    end

    return createPopupWindow(popup)
end

function notificationPopup.update(orig, self, dt)
    orig(dt)

    if not activeNotification then
        activeNotification = self
    end

    if activeNotification ~= self then
        return
    end

    local popup = self.popup

    if popup and not popup.done then
        local stateDuration = popup.durations[popup.stateIndex]

        local workspaceLeft, workspaceRight, workspaceBottom = getWorkspaceBounds()
        local startX = math.max(workspaceLeft + edgePadding, workspaceRight - self.width - edgePadding)
        local startY = workspaceBottom + self.height + edgePadding
        local stopX, stopY = startX, workspaceBottom - self.height - edgePadding

        popup.timeAcc += dt

        widgetUtils.lerpWindowPosition(self, startX, startY, stopX, stopY, popup.lerpPercent)

        if stateDuration then
            if popup.timeAcc > stateDuration and stateDuration ~= -1 then
                popup.timeAcc -= stateDuration
                popup.stateIndex += 1
                popup.state = popupStates[popup.stateIndex]
            end

        else
            popup.done = true
        end

        if popup.state == "starting" then
            popup.lerpPercent = popup.timeAcc / popupStartDuration

        elseif popup.state == "waiting" then
            -- Popup shouldn't go away if hovered
            if self.hovered then
                popup.timeAcc = 0
            end

            popup.lerpPercent = 1

        elseif popup.state == "stopping" then
            popup.lerpPercent = 1 - popup.timeAcc / popupStopDuration
        end

    else
        removePopupWindow(self)

        activeNotification = false
    end
end

function notificationPopup.getPopupWindow()
    return notificationGroup
end

return notificationPopup