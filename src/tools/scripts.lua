-- Scripts tool, modelled after the Loenn Scripts plugin: pick a script on the right, then click
-- in the workspace to run it. Scripts may provide prerun (whole map, returns a snapshot) and run
-- (per target room); scripts with fields open a parameter panel first.

local state = require("loaded_state")
local configs = require("configs")
local utils = require("utils")
local history = require("history")
local snapshotUtils = require("snapshot_utils")
local celesteRender = require("celeste_render")
local notifications = require("ui.notification")
local logging = require("logging")
local viewportHandler = require("viewport_handler")
local keyboardHelper = require("utils.keyboard")
local selectionUtils = require("selections")
local drawing = require("utils.drawing")
local colors = require("consts.colors")
local registry = require("scripts.registry")
local scriptsPanel = require("ui.windows.scripts_panel")

local tool = {}

tool._type = "tool"
tool.name = "scripts"
tool.group = "scripts"
-- Right below the Preview tool
tool.order = 9.7

-- Scope of the scripts, shown as the secondary entries below the tool
tool.validLayers = {"currentRoom", "allRooms"}
tool.layer = "currentRoom"
tool.subLayer = -1

tool.material = nil

-- Current Room and All Rooms are just scopes: switching them keeps the selected script
tool.sharedMaterialAcrossLayers = true

-- The tool implements the room/filler selection itself so shift clicking can also deselect a
-- room that is already part of a multi selection
tool.manualRoomLogic = true

function tool.getMaterials()
    local materials = {}

    for _, script in ipairs(registry.getScripts()) do
        table.insert(materials, {
            name = script.name,
            displayName = script.title,
            displayNameNoMods = script.title,
            description = script.description
        })
    end

    return materials
end

function tool.setMaterial(name)
    tool.material = name

    local script = name and registry.getByName(name)

    if script and script.onSelected then
        script.onSelected()
    end

    return true
end

function tool.getMaterial()
    return tool.material
end

function tool.setLayer(layer, subLayer)
    tool.layer = layer or "currentRoom"
    tool.subLayer = subLayer or -1

    return true
end

local function getTargetRooms()
    if tool.layer == "allRooms" then
        return state.map and state.map.rooms or {}
    end

    -- Current Room: every selected room, so a multi selection is affected as a whole
    local selectedRooms = selectionUtils.getSelectedRooms()

    if #selectedRooms > 0 then
        return selectedRooms
    end

    local selectedRoom = state.getSelectedRoom()

    return selectedRoom and {selectedRoom} or {}
end

local function execScript(script, args, context, targetRooms)
    local snapshots = {}
    local keepPanelOpen = false

    context = context or {}
    context.mouseX = context.mouseX or 0
    context.mouseY = context.mouseY or 0
    context.mouseMapX = context.mouseMapX or 0
    context.mouseMapY = context.mouseMapY or 0
    context.layer = tool.layer

    local room = state.getSelectedRoom()

    if room then
        context.mouseRoomX, context.mouseRoomY = context.mouseMapX - room.x, context.mouseMapY - room.y
    end

    if script.prerun then
        local prerunSnapshot, prerunKeepPanelOpen = script.prerun(args, tool.layer, context)
        keepPanelOpen = prerunKeepPanelOpen == true

        if prerunSnapshot then
            table.insert(snapshots, prerunSnapshot)
        end
    end

    if script.run then
        for _, targetRoom in ipairs(targetRooms or getTargetRooms()) do
            context.mouseRoomX, context.mouseRoomY = context.mouseMapX - targetRoom.x, context.mouseMapY - targetRoom.y

            local before = utils.deepcopy(targetRoom)

            script.run(targetRoom, args, context)

            local after = utils.deepcopy(targetRoom)

            table.insert(snapshots, snapshotUtils.roomSnapshot(targetRoom,
                "script_" .. tostring(script.name), before, after))

            celesteRender.invalidateRoomCache(targetRoom)
        end
    end

    if #snapshots > 0 then
        history.addSnapshot(snapshotUtils.multiSnapshot("script_" .. tostring(script.name), snapshots))
    end

    -- The panel decides whether it closes: a script can ask to stay open so invalid input can
    -- be corrected without filling the form again
    return not keepPanelOpen
end

local function safeExecScript(script, args, context, targetRooms)
    local success, result = pcall(execScript, script, args, context, targetRooms)

    if not success then
        logging.warning("Failed to run script!")
        logging.warning(debug.traceback(result))
        notifications.notify("Failed to run script!")

        -- Keep the panel open on errors: the user can fix the input and try again
        return false
    end

    if not script.silent then
        -- Scripts that only opened a panel do not report success on their first stage
        notifications.notify("Successfully ran script.")
    end

    return result ~= false
end

-- Entry point for scripts that run another script from their own UI (e.g. after a generated
-- parameter panel was confirmed): snapshots, scope and notifications are handled here.
-- targetRooms can override the tool scope for scripts that operate on specific rooms.
function tool.executeScript(script, args, context, targetRooms)
    safeExecScript(script, args, context, targetRooms)
end

local function useScript(script, context)
    if not script then
        return
    end

    -- Scripts with their own validation/panel (e.g. Auto Add Background Tiles) open themselves
    if script.open then
        script.open(context)

        return
    end

    if script.fieldOrder and #script.fieldOrder > 0 then
        scriptsPanel.open(script, context, function(args)
            return safeExecScript(script, args, context)
        end)

    else
        safeExecScript(script, {}, context)
    end
end

-- Rooms and fillers can both be clicked. Reuse the editor hit testing helpers: filler
-- coordinates are stored in tiles, rooms in pixels, and the helpers handle that.
local function getItemAt(mapX, mapY)
    local map = state.map

    if not map then
        return nil
    end

    return utils.getFillerAtCoords(mapX, mapY, map) or utils.getRoomAtCoords(mapX, mapY, map) or nil
end

function tool.mouseclicked(x, y, button, istouch, pressed)
    local script = tool.material and registry.getByName(tool.material)

    if not script then
        return false
    end

    local mouseMapX, mouseMapY = viewportHandler.getMapCoordinates(x, y or 0)
    local clickedItem = getItemAt(mouseMapX, mouseMapY)

    -- Scripts that need a different secondary action (for example copying a spike config) can
    -- handle a right click themselves. This does not affect normal left click execution.
    if button == configs.editor.contextMenuButton and script.rightclick then
        if not clickedItem then
            return false
        end

        -- Clicking an unselected room focuses it, the right click action still runs on this click
        if tool.layer ~= "allRooms" and not selectionUtils.isItemSelected(clickedItem) then
            state.selectItem(clickedItem)
        end

        script.rightclick({
            mouseX = x,
            mouseY = y or 0,
            mouseMapX = mouseMapX,
            mouseMapY = mouseMapY,
            focusedItem = clickedItem
        })

        return true
    end

    if button ~= configs.editor.toolActionButton then
        return false
    end

    local addModifier = configs.editor.selectionAddModifier

    -- Current Room runs on the focused/selected items. Shift/ctrl clicking only changes the multi
    -- selection; a plain click on another room focuses it and still runs the script on that click.
    if tool.layer ~= "allRooms" then
        if clickedItem and keyboardHelper.modifierHeld(addModifier) then
            selectionUtils.toggleItemSelection(clickedItem)

            return true
        end

        if clickedItem and not selectionUtils.isItemSelected(clickedItem) then
            state.selectItem(clickedItem)
        end
    end

    -- Scripts which only act per room (no panel, no whole map stage) need a target to work on
    local needsTarget = script.run and not script.prerun and not script.open
        and not (script.fieldOrder and #script.fieldOrder > 0)

    if needsTarget and #getTargetRooms() == 0 then
        notifications.notify("This script runs on a room: click a room or select one first.")

        return true
    end

    useScript(script, {
        mouseX = x,
        mouseY = y or 0,
        mouseMapX = mouseMapX,
        mouseMapY = mouseMapY,
        focusedItem = clickedItem or state.getSelectedItem()
    })

    return true
end

function tool.selected()
    return true
end

function tool.unselected()
    return true
end

function tool.wheelmoved(dx, dy)
    local script = tool.material and registry.getByName(tool.material)

    if script and script.wheelmoved then
        return script.wheelmoved(dx, dy)
    end

    return false
end

-- Cursor hint: a small square at the mouse position, like the scripts plugin. It shows where the
-- selected script will run.
function tool.draw()
    if not tool.material then
        return
    end

    local script = registry.getByName(tool.material)
    local mouseX, mouseY = viewportHandler.getMousePosition()
    local mapX, mapY = viewportHandler.getMapCoordinates(mouseX, mouseY)

    drawing.callKeepOriginalColor(function()
        viewportHandler.drawRelativeTo(0, 0, function()
            love.graphics.setColor(colors.brushColor)
            love.graphics.rectangle("line", mapX - 4, mapY - 4, 8, 8)
            love.graphics.rectangle("line", mapX - 1, mapY - 1, 2, 2)

            if script and script.draw then
                script.draw(mapX, mapY)
            end
        end)
    end)
end

return tool
