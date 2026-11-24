local ui = require("ui")
local uiElements = require("ui.elements")
local uiUtils = require("ui.utils")

local loadedState = require("loaded_state")
local history = require("history")
local debugUtils = require("debug_utils")
local notifications = require("ui.notification")
local sceneHandler = require("scene_handler")
local configs = require("configs")
local fileLocations = require("file_locations")
local filesystem = require("utils.filesystem")
local mapImageGenerator = require("map_image")
local persistence = require("persistence")
local mods = require("mods")
local meta = require("meta")
local version = require("utils.version_parser")
local viewportDevice = require("input_devices.viewport_device")

local utils = require("utils")
local languageRegistry = require("language_registry")

local roomHotkeyUtils = require("room_hotkey_utils")
local viewportHandler = require("viewport_handler")
local windowUtils = require("window_utils")
local standardHotkeys = require("standard_hotkeys")
local toolHandler = require("tools")

local roomEditor = require("ui.room_editor")
local stylegroundEditor = require("ui.styleground_editor")
local metadataEditor = require("ui.metadata_editor")
local dependencyEditor = require("ui.dependency_editor")
local settingsEditor = require("ui.settings_editor")
local aboutWindow = require("ui.about_window_wrapper")
local tipsWindow = require("ui.tips_window_wrapper")
local ghost = require("ghost")

local activeMenubar
local devBuild = meta.version == version("0.0.0")

local menubar = {}

local function deleteCurrentRoom()
    local map = loadedState.map
    local item = loadedState.getSelectedItem()

    if map and item then
        sceneHandler.sendEvent("editorRoomDelete", map, item)
    end
end

local function openStorageDirectory()
    local fileUrl = string.format("file://%s", fileLocations.getStorageDir())

    love.system.openURL(fileUrl)
end

local function openCelesteWiki()
    love.system.openURL("https://saplonily.top/celeste_wiki/index.html")
end

local function saveMapImage()
    filesystem.saveDialog(loadedState.filename, "png", function(filename)
        if not filename then
            return
        end

        local saved, reason = mapImageGenerator.saveMapImage(filename)

        if not saved then
            local language = languageRegistry.getLanguage()
            local template = language.ui.notifications.mapImageSaveFailedReason
            local text

            if template then
                text = string.format(tostring(template), tostring(reason or "unknown error"))
            else
                text = string.format("%s: %s",
                    tostring(language.ui.notifications.mapImageSaveFailed),
                    tostring(reason or "unknown error"))
            end

            notifications.notify(text, -1)
        end
    end)
end

local function toggleOnlyShowDependencies(layer)
    return function()
        if type(layer) == "table" then
            for _, l in ipairs(layer) do
                loadedState.setShowDependendedOnMods(l, not loadedState.getShowDependedOnMods(l))
            end

        else
            loadedState.setShowDependendedOnMods(layer, not loadedState.getShowDependedOnMods(layer))
        end
    end
end

local function getOnlyShowDependencies(layer)
    return function()
        if type(layer) == "table" then
            return loadedState.getShowDependedOnMods(layer[1])

        else
            return loadedState.getShowDependedOnMods(layer)
        end
    end
end

-- The node overlay is baked into the room batches, so toggling it has to throw
-- those away to be picked up
local function toggleAlwaysShowNodes()
    configs.editor.alwaysShowNodes = not configs.editor.alwaysShowNodes

    require("utils.config").writeConfig(configs, true)

    local celesteRender = require("celeste_render")

    celesteRender.clearBatchingTasks()
    celesteRender.invalidateRoomCache()
end

local function getAlwaysShowNodes()
    return configs.editor.alwaysShowNodes
end

local function noRecentFilesNotification()
    local language = languageRegistry.getLanguage()
    local text = tostring(language.ui.menubar.no_recent_files)

    notifications.notify(text)
end

local function notYetImplementedNotification()
    local language = languageRegistry.getLanguage()
    local text = tostring(language.ui.menubar.not_yet_implemented)

    notifications.notify(text)
end

-- debugUtils.reloadUI might change, wrap in function
local function reloadUI()
    debugUtils.reloadUI()
end

-- Deletes everything Loenn caches on disk (filename lists, mod metadata,
-- compiled Lua and converted atlas images). They are all rebuilt on the next
-- start, so this is the convenient way to test from a clean slate
local function clearCache()
    local cacheDirectory = utils.joinpath(fileLocations.getStorageDir(), "Cache")

    filesystem.removeDirectoryRecursive(cacheDirectory)

    local language = languageRegistry.getLanguage()

    notifications.notify(tostring(language.ui.notifications.cacheCleared))
end

-- Restores the built-in defaults in loenn2-settings.conf. The previous file is kept as
-- loenn2-settings.backup.conf next to it, since a reset is easy to trigger by accident
local function resetSettings()
    local defaultConfig = require("default_config")
    local config = require("utils.config")

    local settingsPath = fileLocations.getSettingsPath()
    local backupPath = utils.joinpath(fileLocations.getStorageDir(), "loenn2-settings.backup.conf")

    if filesystem.isFile(settingsPath) then
        filesystem.copy(settingsPath, backupPath)
    end

    rawset(configs, "data", utils.deepcopy(defaultConfig))
    config.writeConfig(configs, true)

    local language = languageRegistry.getLanguage()

    notifications.notify(tostring(language.ui.notifications.settingsReset))
end

local function featureToggleWrapper(enabled, funcEnabled, funcDisabled, ...)
    local args = {...}

    return function()
        local featureEnabled = utils.callIfFunction(enabled, unpack(args))

        if featureEnabled then
            funcEnabled(unpack(args))

        else
            funcDisabled = funcDisabled or notYetImplementedNotification

            funcDisabled()
        end
    end
end

local function toggleLayoutBounds()
    configs.debug.showLayoutBounds = not configs.debug.showLayoutBounds
end

local function getLayoutBounds()
    return configs.debug.showLayoutBounds
end

-- Menu key -> where its activator lives, so the label shows the key the user actually has bound.
-- Entries are either {"<configs group>", "<key>"} or {"literal", "<hardcoded activator>"}.
local hotkeyHints = {
    undo = {"hotkeys", "undo"},
    redo = {"hotkeys", "redo"},
    new = {"hotkeys", "new"},
    open = {"hotkeys", "open"},
    save = {"hotkeys", "save"},
    save_as = {"hotkeys", "saveAs"},
    view_zoom_in = {"hotkeys", "cameraZoomIn"},
    view_zoom_out = {"hotkeys", "cameraZoomOut"},
    view_zoom_to_extents = {"editor", "canvasZoomExtentsButton"},
    toggle_coordinate_panel = {"hotkeys", "toggleCoordinatePanel"},
    toggle_fullscreen = {"hotkeys", "toggleFullscreen"},
    toggle_previous_tool = {"hotkeys", "togglePreviousTool"},
    toggle_toolbar = {"hotkeys", "toggleToolbar"},
    add_room = {"hotkeys", "roomAddNew"},
    configure_room = {"hotkeys", "roomConfigureCurrent"},
    delete_room = {"hotkeys", "roomDelete"},
    item_flip_horizontal = {"editor", "itemFlipHorizontal"},
    item_flip_vertical = {"editor", "itemFlipVertical"},
    item_rotate_left = {"editor", "itemRotateLeft"},
    item_rotate_right = {"editor", "itemRotateRight"},
    item_add_node = {"editor", "itemAddNode"},
    item_delete = {"editor", "itemDelete"},
    decal_to_foreground = {"editor", "decalToForeground"},
    decal_to_background = {"editor", "decalToBackground"},
    items_cut = {"hotkeys", "itemsCut"},
    items_copy = {"hotkeys", "itemsCopy"},
    items_paste = {"hotkeys", "itemsPaste"},
    items_select_all = {"hotkeys", "itemsSelectAll"},
    items_deselect = {"hotkeys", "itemsDeselect"},
    item_area_flip_horizontal = {"hotkeys", "itemAreaFlipHorizontal"},
    item_area_flip_vertical = {"hotkeys", "itemAreaFlipVertical"},
    ghost_show_player = {"literal", "c"},
    ghost_show_player_hitbox = {"literal", "x"},
    ghost_clear = {"literal", "shift + c"},
    debug_reload_entities = {"hotkeys", "debugReloadEntities"},
    debug_reload_tools = {"hotkeys", "debugReloadTools"},
    debug_reload_everything = {"hotkeys", "debugReloadEverything"},
    debug_reload_lua_instance = {"hotkeys", "debugReloadLuaInstance"},
    debug_redraw_map = {"hotkeys", "debugRedrawMap"},
    debug_mode = {"hotkeys", "debugMode"}
}

local function formatHotkeyValue(value, language)
    if type(value) == "number" then
        return string.format(tostring(language.ui.userInput.mouseButton), value)
    end

    if type(value) ~= "string" then
        return nil
    end

    return (utils.titleCase(value):gsub("Plus", "+"):gsub("Minus", "-"))
end

local function getHotkeyHint(menuKey, language)
    local source = hotkeyHints[menuKey]

    if not source then
        return nil
    end

    local namespace, configKey = source[1], source[2]

    if namespace == "literal" then
        return formatHotkeyValue(configKey, language)
    end

    local group = configs[namespace]

    if not group then
        return nil
    end

    return formatHotkeyValue(group[configKey], language)
end

local function notifyMenuUnavailable(messageKey)
    sceneHandler.sendEvent("editorMenuActionUnavailable", messageKey)
end

local function withSelectionTool(action)
    return function()
        if toolHandler.currentToolName ~= "selection" then
            notifyMenuUnavailable("editorMenuNeedsSelectionTool")
            return
        end

        action(toolHandler.tools.selection)
    end
end

local function withSelectionContext(action)
    return function()
        if toolHandler.currentToolName ~= "selection" then
            notifyMenuUnavailable("editorMenuNeedsSelectionTool")
            return
        end

        local selectionTool = toolHandler.tools.selection
        local room = loadedState.getSelectedRoom()
        local targets = selectionTool and selectionTool.getSelectionTargets and selectionTool.getSelectionTargets()

        if not room or not targets or #targets == 0 then
            notifyMenuUnavailable("editorMenuNeedsSelection")
            return
        end

        action(selectionTool, room, targets)
    end
end

local function selectionKeyAction(handlerName, configKey)
    return withSelectionContext(function(selectionTool, room)
        selectionTool[handlerName](room, configs.editor[configKey])
    end)
end

local addDebug = configs.debug.enableDebugOptions
local debugMenu = {"debug", {
    {"reload", {
        {"reload_everything", debugUtils.reloadEverything},
        {"reload_scenes", debugUtils.reloadScenes},
        {"reload_tools", debugUtils.reloadTools},
        {"reload_entities", debugUtils.reloadEntities},
        {"reload_triggers", debugUtils.reloadTriggers},
        {"reload_effects", debugUtils.reloadEffects},
        {"reload_user_interface", reloadUI},
        {"reload_language_files", debugUtils.reloadLanguageFiles}
    }},
    {"redraw_map", debugUtils.redrawMap},
    {"show_layout_bounds", toggleLayoutBounds, "checkbox", getLayoutBounds},
    {},
    {"clear_cache", clearCache},
    {"reset_settings", resetSettings},
    {"test_console", debugUtils.debug}
}}

-- Tree of menubar items
-- First element is translation key
-- Second element is a sub tree or a function callback
-- Third is whether element type, by default it is plain text
-- Any following elements are up to the element type to handle
-- Closes by default, some menu items might not want to close the menu, for example "View" toggles
menubar.menubar = {
    {"file", {
        {"new", loadedState.newMap},
        {"open", loadedState.openMap},
        {"recent", noRecentFilesNotification},
        {},
        {"save", loadedState.saveCurrentMap},
        {"save_as", loadedState.saveAsCurrentMap},
        {},
        {"close", loadedState.closeMap},
        {"exit", love.event.quit}
    }},
    {"edit", {
        {"undo", history.undo},
        {"redo", history.redo},
        {},
        {"items_cut", withSelectionTool(function(selectionTool)
            selectionTool.cutSelection()
        end)},
        {"items_copy", withSelectionTool(function(selectionTool)
            selectionTool.copySelection()
        end)},
        {"items_paste", withSelectionTool(function(selectionTool)
            selectionTool.pasteSelection()
        end)},
        {"items_select_all", withSelectionTool(function(selectionTool)
            selectionTool.selectAll()
        end)},
        {"items_deselect", withSelectionTool(function(selectionTool)
            selectionTool.deselect()
        end)},
        {},
        {"item_area_flip_horizontal", withSelectionTool(function(selectionTool)
            selectionTool.flipSelectionAreaHorizontal()
        end)},
        {"item_area_flip_vertical", withSelectionTool(function(selectionTool)
            selectionTool.flipSelectionAreaVertical()
        end)},
        {},
        {"item_flip_horizontal", selectionKeyAction("handleItemFlipKeys", "itemFlipHorizontal")},
        {"item_flip_vertical", selectionKeyAction("handleItemFlipKeys", "itemFlipVertical")},
        {"item_rotate_left", selectionKeyAction("handleItemRotateKeys", "itemRotateLeft")},
        {"item_rotate_right", selectionKeyAction("handleItemRotateKeys", "itemRotateRight")},
        {"item_add_node", selectionKeyAction("handleNodeAddKey", "itemAddNode")},
        {"item_delete", selectionKeyAction("handleItemDeletionKey", "itemDelete")},
        {},
        {"decal_to_foreground", selectionKeyAction("handleDecalLayerKeys", "decalToForeground")},
        {"decal_to_background", selectionKeyAction("handleDecalLayerKeys", "decalToBackground")},
        {},
        {"add_room", roomHotkeyUtils.addRoom},
        {"configure_room", roomHotkeyUtils.configureSelectedRoom},
        {"delete_room", roomHotkeyUtils.deleteSelectedRoom},
        {},
        {"settings", settingsEditor.editSettings},
    }},
    {"view", {
        {"view_only_depended_on", {
            {"view_depended_on_entities", toggleOnlyShowDependencies("entities"), "checkbox", getOnlyShowDependencies("entities")},
            {"view_depended_on_triggers", toggleOnlyShowDependencies("triggers"), "checkbox", getOnlyShowDependencies("triggers")},
            {"view_depended_on_decals", toggleOnlyShowDependencies({"decalsFg", "decalsBg"}), "checkbox", getOnlyShowDependencies({"decalsFg", "decalsBg"})},
        }},
        {},
        {"view_zoom_in", viewportHandler.zoomIn},
        {"view_zoom_out", viewportHandler.zoomOut},
        {"view_zoom_to_extents", viewportDevice.zoomToExtents},
        {},
        {"view_always_show_trigger_nodes", toggleAlwaysShowNodes, "checkbox", getAlwaysShowNodes},
        {"ghost_show_hitboxes", ghost.toggleHitboxes, "checkbox", ghost.getHitboxes},
        {},
        {"toggle_coordinate_panel", standardHotkeys.toggleDebugTool},
        {"toggle_fullscreen", windowUtils.toggleFullscreen},
        {},
        {"toggle_previous_tool", toolHandler.selectPreviousTool},
        {"toggle_toolbar", toolHandler.toggleToolbar},
    }},
    {"map", {
        {"metadata", metadataEditor.editMetadata},
        {"dependencies", dependencyEditor.editDependencies},
        {"save_map_image", saveMapImage},
        {},
        {"debug", {
            {"debug_reload_entities", debugUtils.reloadEntities},
            {"debug_redraw_map", debugUtils.redrawMap},
            {"debug_reload_tools", debugUtils.reloadTools},
            {"debug_reload_everything", debugUtils.reloadEverything},
            {"debug_reload_lua_instance", debugUtils.restartLuaInstance},
            {"debug_mode", debugUtils.debug},
        }},
    }},
    {"ghost", {
        {"ghost_helper_hint", false, "hint"},
        {"ghost_show_player", ghost.togglePlayer, "checkbox", ghost.getPlayer},
        {"ghost_show_player_hitbox", ghost.togglePlayerHitbox, "checkbox", ghost.getPlayerHitbox},
        {"ghost_show_holdables", ghost.toggleHoldables, "checkbox", ghost.getHoldables},
        {},
        {"ghost_clear", ghost.clear},
    }},
    -- Only add if enabled
    addDebug and debugMenu or false,
    {"help", {
        {"pick_random_tips", tipsWindow.show},
        {"celeste_wiki", openCelesteWiki},
        {"check_for_updates", checkForUpdates},
        {"open_storage_directory", openStorageDirectory},
        {"about", aboutWindow.showAboutWindow}
    }}
}

local function findMenuEntry(menu, key)
    if not menu then
        return
    end

    for _, entry in ipairs(menu) do
        if entry[1] == key or entry._key == key then
            return entry
        end
    end
end

-- TODO - Tooltip support
local function addLanguageStrings(menu, language)
    if utils.typeof(menu) == "table" then
        local languageKey = menu[1]
        local languageKeyType = type(languageKey)

        if languageKeyType == "string" then
            local text = tostring(language.ui.menubar[languageKey])
            local hint = getHotkeyHint(languageKey, language)

            if hint then
                text = string.format("%s (%s)", text, hint)
            end

            menu[1] = text
            menu._key = languageKey
        end

        for _, sub in pairs(menu) do
            addLanguageStrings(sub, language)
        end
    end
end

local function wrapInSubmenuClosers(menu)
    if utils.typeof(menu) == "table" then
        -- Only real entries (title + data) have to be wrapped. Submenu lists are
        -- tables of entries and would otherwise get a function injected into
        -- their second slot when they hold fewer than two entries.
        if type(menu[1]) == "string" then
            local callback = menu[2]
            local elementType = menu[3]
            local shouldCloseMenu = true
            local callbackType = type(callback)

            if elementType == "checkbox" then
                shouldCloseMenu = false

            elseif elementType == "hint" then
                shouldCloseMenu = false
                callback = nil
            end

            if callbackType == "function" or callbackType == "nil" then
                menu[2] = function(self)
                    if callback then
                        callback()
                    end

                    if shouldCloseMenu ~= false then
                        local submenu = self.parent

                        if submenu and submenu:is("menuItemSubmenu") then
                            if submenu.hasScrollbox and submenu.parent then
                                submenu.parent:removeSelf()
                            end

                            submenu:removeSelf()
                        end
                    end
                end
            end
        end

        for _, sub in pairs(menu) do
            wrapInSubmenuClosers(sub)
        end
    end
end

-- No element type means it is plain text
-- Only other supported type is currently checkboxes
local function handleElementTypes(menu)
    if utils.typeof(menu) == "table" then
        local elementType = menu[3]

        if elementType == "checkbox" then
            local visibilityFunction = menu[4]
            local initialValue = true

            if visibilityFunction then
                initialValue = visibilityFunction()
            end

            menu[1] = uiElements.checkbox(menu[1], initialValue):hook({
                update = function(orig, self, dt)
                    orig(self, dt)

                    if visibilityFunction then
                        local newValue = visibilityFunction()

                        if self.value ~= newValue then
                            self.value = newValue
                        end
                    end
                end
            })
        end

        for _, sub in pairs(menu) do
            handleElementTypes(sub)
        end
    end
end

local function removeFalseEntries(menu)
    for i = #menu, 1, -1 do
        if not menu[i] then
            table.remove(menu, i)
        end
    end
end

-- Mods like to add their own entries to the View menu, which gets crowded fast.
-- Their entries are named like "My Tool [ModName]", so move everything with such
-- a suffix into its own "Mod" menu, grouped by mod.
local modSuffixPattern = "%s*%[([^%]]+)%]%s*$"

local function collectModMenus(menu, language)
    local viewEntry = findMenuEntry(menu, "view")

    if not viewEntry or utils.typeof(viewEntry[2]) ~= "table" then
        return
    end

    local viewSubmenu = viewEntry[2]
    local grouped = {}
    local modOrder = {}
    local kept = {}

    for _, entry in ipairs(viewSubmenu) do
        local title = utils.typeof(entry) == "table" and entry[1]
        local modName = type(title) == "string" and title:match(modSuffixPattern)

        if modName then
            local cleanedTitle = utils.trim((title:gsub(modSuffixPattern, "")))

            if cleanedTitle ~= "" then
                entry[1] = cleanedTitle
            end

            local group = grouped[modName]

            if not group then
                group = {}
                grouped[modName] = group

                table.insert(modOrder, modName)
            end

            table.insert(group, entry)

        else
            table.insert(kept, entry)
        end
    end

    if #modOrder == 0 then
        return
    end

    viewEntry[2] = kept

    table.sort(modOrder)

    local modSubmenu = {}

    for _, modName in ipairs(modOrder) do
        table.insert(modSubmenu, {modName, grouped[modName]})
    end

    local modEntry = {tostring(language.ui.menubar.mod), modSubmenu}

    for index, entry in ipairs(menu) do
        if entry == viewEntry then
            table.insert(menu, index + 1, modEntry)

            break
        end
    end
end

local function addRecentFiles(menu)
    local recentFiles = persistence.recentFiles or {}
    local fileEntry = findMenuEntry(menu, "file") or {}
    local recentEntry = findMenuEntry(fileEntry[2], "recent")

    if recentEntry then
        local recentChildren = {}

        for _, filename in ipairs(recentFiles) do
            local cleanedFilename = filename
            local modPath = mods.getFilenameModPath(filename)

            -- If packaged
            if modPath then
                local relativeTo = utils.joinpath(modPath, "Maps")

                cleanedFilename = string.sub(filename, #relativeTo + 2)
                cleanedFilename = utils.stripExtension(cleanedFilename)

            else
                cleanedFilename = utils.stripExtension(filesystem.filename(filename))
            end

            table.insert(recentChildren, {
                cleanedFilename,
                function()
                    loadedState.loadFile(filename)
                end
            })
        end

        if #recentChildren > 1 then
            recentEntry[2] = recentChildren
        end
    end
end

local function hotswapMenubar()
    local newMenubar = menubar.getMenubar()

    activeMenubar.children = newMenubar.children
    activeMenubar:reflow()
    activeMenubar:repaint()
end

function menubar.getMenubar()
    local preparedMenubar = utils.deepcopy(menubar.menubar)
    local language = languageRegistry.getLanguage()

    removeFalseEntries(preparedMenubar)
    addLanguageStrings(preparedMenubar, language)
    collectModMenus(preparedMenubar, language)
    addRecentFiles(preparedMenubar)
    wrapInSubmenuClosers(preparedMenubar)
    handleElementTypes(preparedMenubar)

    local topbar = uiElements.topbar(preparedMenubar)

    topbar:hook({
        editorMapLoaded = function()
            hotswapMenubar()
        end,
        editorMapSaved = function()
            hotswapMenubar()
        end
    })

    if not activeMenubar then
        activeMenubar = topbar
    end

    return topbar
end

return menubar
