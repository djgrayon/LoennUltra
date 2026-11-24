local configs = require("configs")
local loadedState = require("loaded_state")
local debugUtils = require("debug_utils")
local viewportHandler = require("viewport_handler")
local history = require("history")
local roomHotkeyUtils = require("room_hotkey_utils")
local windowUtils = require("window_utils")
local ghost = require("ghost")

local hotkeys = {}

-- Debug tool: the grave accent selects it, and selects the selection tool again when it is
-- already active (it used to toggle the coordinate panel). Exposed so the menu bar can reuse it.
function hotkeys.toggleDebugTool()
    local toolHandler = require("tools")
    local target = toolHandler.currentToolName == "debug" and "selection" or "debug"

    toolHandler.selectToolThroughUi(target)
end

function hotkeys.addStandardHotkeys(hotkeyHandler)
    -- History
    hotkeyHandler.addHotkey("global", configs.hotkeys.redo, history.redo)
    hotkeyHandler.addHotkey("global", configs.hotkeys.undo, history.undo)

    -- Map
    hotkeyHandler.addHotkey("global", configs.hotkeys.new, loadedState.newMap)
    hotkeyHandler.addHotkey("global", configs.hotkeys.open, loadedState.openMap)
    hotkeyHandler.addHotkey("global", configs.hotkeys.save, (-> loadedState.saveCurrentMap()))
    hotkeyHandler.addHotkey("global", configs.hotkeys.saveAs, (-> loadedState.saveAsCurrentMap()))

    -- Room Movement
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomMoveLeft, roomHotkeyUtils.moveCurrentRoomOneTileLeft)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomMoveRight, roomHotkeyUtils.moveCurrentRoomOneTileRight)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomMoveUp, roomHotkeyUtils.moveCurrentRoomOneTileUp)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomMoveDown, roomHotkeyUtils.moveCurrentRoomOneTileDown)

    hotkeyHandler.addHotkey("global", configs.hotkeys.roomMoveLeftPrecise, roomHotkeyUtils.moveCurrentRoomOnePixelLeft)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomMoveRightPrecise, roomHotkeyUtils.moveCurrentRoomOnePixelRight)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomMoveUpPrecise, roomHotkeyUtils.moveCurrentRoomOnePixelUp)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomMoveDownPrecise, roomHotkeyUtils.moveCurrentRoomOnePixelDown)

    -- Room Resizing
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomResizeLeftGrow, roomHotkeyUtils.growCurrentRoomOneTileLeft)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomResizeRightGrow, roomHotkeyUtils.growCurrentRoomOneTileRight)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomResizeUpGrow, roomHotkeyUtils.growCurrentRoomOneTileUp)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomResizeDownGrow, roomHotkeyUtils.growCurrentRoomOneTileDown)

    hotkeyHandler.addHotkey("global", configs.hotkeys.roomResizeLeftShrink, roomHotkeyUtils.shrinkCurrentRoomOneTileLeft)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomResizeRightShrink, roomHotkeyUtils.shrinkCurrentRoomOneTileRight)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomResizeUpShrink, roomHotkeyUtils.shrinkCurrentRoomOneTileUp)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomResizeDownShrink, roomHotkeyUtils.shrinkCurrentRoomOneTileDown)

    -- Room
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomDelete, roomHotkeyUtils.deleteSelectedRoom)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomAddNew, roomHotkeyUtils.addRoom)
    hotkeyHandler.addHotkey("global", configs.hotkeys.roomConfigureCurrent, roomHotkeyUtils.configureSelectedRoom)

    -- Debug hotkeys
    hotkeyHandler.addHotkey("global", configs.hotkeys.debugReloadEverything, debugUtils.reloadEverything)
    hotkeyHandler.addHotkey("global", configs.hotkeys.debugReloadLuaInstance, debugUtils.restartLuaInstance)
    hotkeyHandler.addHotkey("global", configs.hotkeys.debugReloadEntities, debugUtils.reloadEntities)
    hotkeyHandler.addHotkey("global", configs.hotkeys.debugReloadTools, debugUtils.reloadTools)
    hotkeyHandler.addHotkey("global", configs.hotkeys.debugRedrawMap, debugUtils.redrawMap)
    hotkeyHandler.addHotkey("global", configs.hotkeys.debugMode, debugUtils.debug)

    -- Camera
    hotkeyHandler.addHotkey("global", configs.hotkeys.cameraZoomIn, viewportHandler.zoomIn)
    hotkeyHandler.addHotkey("global", configs.hotkeys.cameraZoomOut, viewportHandler.zoomOut)

    -- Window
    hotkeyHandler.addHotkey("global", configs.hotkeys.toggleFullscreen, windowUtils.toggleFullscreen)

    -- Ghosts
    hotkeyHandler.addHotkey("global", "shift + c", ghost.clear)

    -- "tools" scope instead of "global": the tool device runs after the UI device, so these plain
    -- letters do not fire while a text field is focused, but still work anywhere in the editor.
    hotkeyHandler.addHotkey("tools", "c", ghost.togglePlayer)
    hotkeyHandler.addHotkey("tools", "x", ghost.togglePlayerHitbox)

    hotkeyHandler.addHotkey("global", configs.hotkeys.toggleCoordinatePanel, hotkeys.toggleDebugTool)
end

return hotkeys

