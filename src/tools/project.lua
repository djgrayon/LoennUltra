-- Project tool: the right sidebar panel for the mod project the current map belongs to.
--
-- The project folder comes from the loaded map file (Mods/<project>/...), the author and mod name
-- are derived from the folders below Maps/, and the collection type from the first folder name
-- ("...collab...", "...contest..."). Values the user edited are stored per project folder and take
-- precedence over the derived ones.

local utils = require("utils")
local loadedState = require("loaded_state")
local languageRegistry = require("language_registry")
local filesystem = require("utils.filesystem")
local fileLocations = require("file_locations")
local logging = require("logging")
local notifications = require("ui.notification")
local persistence = require("persistence")
local tilesetDefaults = require("tileset_defaults")
local projectTilesets = require("project_tilesets")

local tool = {}

tool._type = "tool"
tool.name = "project"
tool.group = "project"
-- Own group at the bottom of the toolbar; later panels continue below it
tool.order = 9

-- The panel is not bound to a map layer
tool.validLayers = {}

local collabTypes = {"standalone", "collab", "contest"}

-- English defaults, used whenever the active language has no entry for the key yet
local defaultStrings = {
    title = "Project Settings",
    section_project = "Project",
    section_paths = "Quick Paths",
    section_actions = "Quick Actions",
    value_project = "Project: %s",
    value_author = "Author: %s",
    value_mod = "Mod: %s",
    value_collab = "Type: %s",
    unknown = "Unknown",
    no_map = "The current map is not inside a project folder in Mods.",
    edit = "Edit project settings ...",
    edit_tooltip = "Changes the author name, the mod name and the collection type.",
    save = "Save",
    saved = "Project settings saved.",
    path_failed = "Could not create the folder: %s",
    open_failed = "Could not open the folder: %s",
    path_decals = "Decal",
    path_tilesets = "Tileset",
    path_stylegrounds = "Styleground",
    path_animated = "Animated styleground",
    path_hd = "HD styleground",
    path_modified = "Modifiable dynamic styleground",
    path_session = "Modifiable static styleground",
    path_maps = "Maps",
    path_dialog = "Dialog",
    path_xml = "XML",
    path_jumpthru = "Jump-thru",
    path_switchgate = "Switch gate",
    path_icon = "Map icon",
    path_audio = "Audio",
    path_tutorials = "Tutorials",
    path_playbacks = "Modder's Toolkit playbacks",
    path_custom_playbacks = "Kayden's Commands playbacks",
    map_title = "Open Map",
    map_field = "Map file",
    map_open = "Open",
    map_none = "No .bin map files found below %s",
    import_open = "Import tileset ...",
    import_title = "Import Tileset",
    import_field_name = "Image name",
    import_field_id = "Tileset id",
    import_field_template = "Template",
    import_field_layer = "Layer",
    import_field_vanilla = "Vanilla tilesets",
    import_tpl_vanilla = "Vanilla (texture only)",
    import_tpl_better = "Better (12x12 autotile)",
    import_tpl_spooooky = "Spooooky (full autotile + corners)",
    import_layer_fg = "Foreground",
    import_layer_bg = "Background",
    import_run = "Import",
    import_done = "Imported tileset \"%s\" (id %s).",
    import_bad_image = "Only png, jpg, jpeg, bmp and gif images can be imported.",
    import_failed = "Import failed: %s",
    import_state_template = "the id z is reserved for the template block",
    import_state_vanilla = "the id is used by the vanilla tilesets of this layer",
    import_state_used = "the id is already used in the XML of this layer",
    import_state_other = "the id is used in the other layer",
    import_state_fileName = "the file name is empty or contains a path",
    import_state_image = "the image could not be read",
    import_state_write = "the file could not be written",
    import_state_root = "the target XML has no </Data> root element",
    everest_create = "Create everest.yaml",
    everest_created = "Created everest.yaml for \"%s\".",
    everest_exists = "everest.yaml already exists.",
    field_project_name = "Project folder",
    field_project_name_tooltip = "The Mods folder of the current map. It cannot be changed here.",
    field_author_name = "Author name",
    field_author_name_tooltip = "Folder name on the author level of the asset folders.",
    field_mod_name = "Mod name",
    field_mod_name_tooltip = "Folder name on the mod level of the asset folders.",
    field_collab_type = "Collection type",
    field_collab_type_tooltip = "Collab and contest swap the places of the author name and the mod name in the paths.",
    collab_standalone = "Standalone",
    collab_collab = "Collab",
    collab_contest = "Contest"
}

local function getString(key)
    local language = languageRegistry.getLanguage()
    local node = language and language.ui and language.ui.project_window
    local value = node and node[key]

    -- Missing entries resolve to the language system's placeholder node
    if value == nil or (type(value) == "table" and rawget(value, "_exists") == false) then
        return defaultStrings[key] or key
    end

    return tostring(value)
end

local function getProjectSettingsStore()
    local store = persistence.projectSettings

    if type(store) ~= "table" then
        return {}
    end

    return store
end

local function getSettingsKey(projectName)
    return string.lower(tostring(projectName or ""))
end

local function getStoredSettings(projectName)
    if not projectName or projectName == "" then
        return nil
    end

    return getProjectSettingsStore()[getSettingsKey(projectName)]
end

local function setStoredSettings(projectName, values)
    local store = utils.deepcopy(getProjectSettingsStore())

    store[getSettingsKey(projectName)] = values

    persistence.projectSettings = store

    -- Write right away instead of waiting for the persistence buffer: the panel shows the values
    -- again immediately, and a crash in between must not lose them
    require("utils.config").writeConfig(persistence, true)
end

-- Folder segments of the map file below "<mod folder>/Maps/"
local function getMapSegments(modFolder)
    local filename = loadedState.filename

    if not filename or not modFolder then
        return nil
    end

    local unixFilename = utils.convertToUnixPath(filename)
    local prefix = utils.convertToUnixPath(modFolder) .. "/Maps/"

    if not utils.startsWith(unixFilename, prefix) then
        return nil
    end

    local segments = {}
    local relative = string.sub(unixFilename, #prefix + 1)

    for segment in string.gmatch(relative, "[^/]+") do
        table.insert(segments, segment)
    end

    return segments
end

local function getDetectedCollabType(folderName)
    local lowerName = string.lower(tostring(folderName or ""))

    if string.find(lowerName, "contest", 1, true) then
        return "contest"

    elseif string.find(lowerName, "collab", 1, true) then
        return "collab"
    end
end

-- Current project. Second return value is the reason when no project can be resolved
function tool.getProject()
    local modFolder, projectName, reason = tilesetDefaults.getMapModFolder()

    if not modFolder then
        return nil, reason
    end

    local project = {
        projectName = projectName,
        modFolder = modFolder,
        authorName = "",
        modName = "",
        collabType = "standalone"
    }

    local segments = getMapSegments(modFolder) or {}
    local firstSegment = segments[1]

    if firstSegment then
        local detectedType = getDetectedCollabType(firstSegment)

        if detectedType then
            project.collabType = detectedType
            project.modName = firstSegment

        else
            project.authorName = firstSegment
            project.modName = segments[2] or ""
        end
    end

    local settings = getStoredSettings(projectName) or {}

    project.collabType = settings.collabType or project.collabType
    project.modName = settings.modName or project.modName
    project.authorName = settings.authorName or project.authorName

    return project
end

local function getCollabTypeDisplayName(collabType)
    return getString("collab_" .. tostring(collabType))
end

local function refreshPanel()
    local success, toolsWindow = pcall(require, "ui/windows/tools")

    if success and toolsWindow.refreshMaterialList then
        toolsWindow.refreshMaterialList()
    end
end

-- Folders of the quick path rows. "authorMod" entries end in the author/mod folder pair, "maps"
-- follows the collection type, "plain" folders only live below the mod folder
local pathEntries = {
    {key = "path_decals", folders = {"Graphics", "Atlases", "Gameplay", "decals"}, authorMod = true},
    {key = "path_tilesets", folders = {"Graphics", "Atlases", "Gameplay", "tilesets"}, authorMod = true},
    {key = "path_stylegrounds", folders = {"Graphics", "Atlases", "Gameplay", "bgs"}, authorMod = true},
    {key = "path_animated", folders = {"Graphics", "Atlases", "Gameplay", "bgs", "MaxHelpingHand", "animatedParallax"}, authorMod = true},
    {key = "path_hd", folders = {"Graphics", "Atlases", "Gameplay", "bgs", "MaxHelpingHand", "hdParallax"}, authorMod = true},
    {key = "path_modified", folders = {"Graphics", "Atlases", "Gameplay", "bgs", "ChroniaHelper", "modifiedParallax"}, authorMod = true},
    {key = "path_session", folders = {"Graphics", "Atlases", "Gameplay", "bgs", "ChroniaHelper", "sessionParallax"}, authorMod = true},
    {key = "path_maps", folders = {"Maps"}, maps = true},
    {key = "path_dialog", folders = {"Dialog"}},
    {key = "path_xml", folders = {"Graphics"}, authorMod = true},
    {key = "path_jumpthru", folders = {"Graphics", "Atlases", "Gameplay", "objects", "jumpthru"}, authorMod = true},
    {key = "path_switchgate", folders = {"Graphics", "Atlases", "Gameplay", "objects", "switchgate"}, authorMod = true},
    {key = "path_icon", folders = {"Graphics", "Atlases", "Gui", "areas"}, authorMod = true},
    {key = "path_audio", folders = {"Audio"}}
}

-- Collabs and contests put the mod name where standalone maps put the author name
local function getAuthorModPair(project)
    if project.collabType == "standalone" then
        return project.authorName, project.modName
    end

    return project.modName, project.authorName
end

-- Playback folders live in the game directory, not in the mod folder
local actionEntries = {
    {key = "path_tutorials", folders = {"Tutorials"}},
    {key = "path_playbacks", gameDir = true, folders = {"Playbacks"}},
    {key = "path_custom_playbacks", gameDir = true, folders = {"Tutorials", "CustomPlaybacks"}}
}

local function getEntryBase(project, entry)
    if entry.gameDir then
        return fileLocations.getCelesteDir()
    end

    return project.modFolder
end

local function buildProjectPath(project, entry)
    local parts = {getEntryBase(project, entry)}
    local outer, inner = getAuthorModPair(project)

    for _, folder in ipairs(entry.folders or {}) do
        table.insert(parts, folder)
    end

    if entry.maps then
        table.insert(parts, outer)

        if project.collabType == "standalone" then
            table.insert(parts, inner)

        else
            table.insert(parts, project.collabType == "contest" and "1-Submissions" or "1-Maps")
        end

    elseif entry.authorMod then
        if outer ~= "" then
            table.insert(parts, outer)
        end

        if inner ~= "" then
            table.insert(parts, inner)
        end
    end

    return utils.joinpath(parts)
end

-- Folder URL: "file:///" needs three slashes, otherwise "E:" is read as the host name
local function toFileURL(path)
    local unixPath = filesystem.convertToUnixPath(path)

    if unixPath:sub(1, 1) ~= "/" then
        unixPath = "/" .. unixPath
    end

    unixPath = unixPath:gsub("%%", "%%25")
    unixPath = unixPath:gsub(" ", "%%20")

    return "file://" .. unixPath
end

local function openWithShell(path)
    local command = string.format('start "" "%s"', path)
    local result = os.execute(command)

    return result == 0 or result == true
end

local function openNativeFolder(path)
    local started = love.timer.getTime()
    local opened = false
    local mode = "openURL"

    -- The URL variant does not block the main loop; the shell fallback is only a last resort
    local success, result = pcall(love.system.openURL, toFileURL(path))

    if success and result ~= false then
        opened = true
    end

    if not opened and utils.getOS() == "Windows" then
        mode = "shell"
        opened = openWithShell(path)
    end

    local elapsed = (love.timer.getTime() - started) * 1000

    -- Anything slow here sits on the main loop and freezes the editor, so keep it visible
    if elapsed > 50 then
        logging.info(string.format("[project] opening '%s' via %s took %.0fms", tostring(path), mode, elapsed))
    end

    if not opened then
        logging.warning(string.format("[project] could not open folder '%s'", tostring(path)))
        notifications.notify(string.format(getString("open_failed"), tostring(path)))

        return false
    end

    return true
end

-- Opens the folder in the file manager, creating it first when it does not exist yet
local function openFolder(path)
    if not filesystem.pathAttributes(path) then
        local started = love.timer.getTime()
        local success, message = filesystem.mkpath(path)
        local elapsed = (love.timer.getTime() - started) * 1000

        if elapsed > 50 then
            logging.info(string.format("[project] creating '%s' took %.0fms", tostring(path), elapsed))
        end

        if not success then
            notifications.notify(string.format(getString("path_failed"), tostring(message or path)))

            return false
        end
    end

    return openNativeFolder(path)
end

local function openProjectFolder(entry)
    return function()
        local project = tool.getProject()

        if not project then
            notifications.notify(getString("no_map"))

            return
        end

        openFolder(buildProjectPath(project, entry))
    end
end

-- Creates a minimal everest.yaml next to the map folders, never overwrites an existing one
local function createEverestYaml()
    local project = tool.getProject()

    if not project then
        notifications.notify(getString("no_map"))

        return
    end

    local path = utils.joinpath(project.modFolder, "everest.yaml")

    if filesystem.pathAttributes(path) then
        notifications.notify(getString("everest_exists"))

        return
    end

    local modName = project.modName

    if modName == "" then
        return
    end

    local handle = utils.getFileHandle(path, "wb")

    if not handle then
        notifications.notify(string.format(getString("path_failed"), path))

        return
    end

    handle:write(string.format("- Name: %s\n  Version: 1.0.0\n", modName))
    handle:close()

    notifications.notify(string.format(getString("everest_created"), modName))
    refreshPanel()
end

-- Map folder of the project: Maps/<author>/<mod>, or Maps/<mod>/1-Maps for collabs
local function getMapBinRoot(project)
    return buildProjectPath(project, {folders = {"Maps"}, maps = true})
end

-- Entries are listed relative to the author/mod level, e.g. "Tearfall/0.bin"
local function getMapDisplayBase(project)
    local outer = getAuthorModPair(project)

    return utils.joinpath(project.modFolder, "Maps", outer)
end

-- Walks the map folder with lfs (love.filesystem cannot see absolute paths outside its mounts)
local function scanMapBins(project)
    local root = getMapBinRoot(project)

    if not filesystem.pathAttributes(root) then
        return nil, root
    end

    local bins = {}
    local stack = {{path = root, relative = ""}}
    local displayBase = filesystem.convertToUnixPath(getMapDisplayBase(project)) .. "/"

    while #stack > 0 do
        local current = table.remove(stack)
        -- lfs.dir returns (iterator, directory): the iterator needs the directory as its state
        local success, iterator, directory = pcall(filesystem.listDir, current.path)

        if success and iterator then
            for name in iterator, directory do
                if name ~= "." and name ~= ".." then
                    local fullPath = utils.joinpath(current.path, name)
                    local relativePath = current.relative == "" and name or (current.relative .. "/" .. name)
                    local attributes = filesystem.pathAttributes(fullPath)

                    if attributes and attributes.mode == "directory" then
                        table.insert(stack, {path = fullPath, relative = relativePath})

                    elseif attributes and attributes.mode == "file"
                        and string.lower(utils.fileExtension(name)) == "bin" then
                        local unixFullPath = filesystem.convertToUnixPath(fullPath)
                        local display = unixFullPath

                        if utils.startsWith(unixFullPath, displayBase) then
                            display = string.sub(unixFullPath, #displayBase + 1)
                        end

                        table.insert(bins, {path = fullPath, display = display})
                    end
                end
            end
        end
    end

    table.sort(bins, function(lhs, rhs)
        return lhs.display < rhs.display
    end)

    return bins, root
end

local function openMapPicker()
    local project = tool.getProject()

    if not project then
        notifications.notify(getString("no_map"))

        return
    end

    local bins, root = scanMapBins(project)

    if not bins or #bins == 0 then
        notifications.notify(string.format(getString("map_none"), tostring(root)))

        return
    end

    local scriptsPanel = require("ui.windows.scripts_panel")
    local options = {}

    for _, bin in ipairs(bins) do
        table.insert(options, {bin.display, bin.path})
    end

    local panelScript = {
        name = "projectMapPicker",
        title = getString("map_title"),
        fieldOrder = {"map"},
        defaultData = {map = bins[1].path},
        fieldInformation = {
            map = {
                displayName = getString("map_field"),
                options = options,
                editable = false
            }
        }
    }

    scriptsPanel.open(panelScript, nil, function(values)
        local path = values.map

        if not path or path == "" then
            return false
        end

        loadedState.loadFile(path)

        return true
    end, {
        runButtonText = getString("map_open")
    })
end

local importExtensions = {
    png = true,
    jpg = true,
    jpeg = true,
    bmp = true,
    gif = true
}

local function getImportStateText(state)
    return getString("import_state_" .. tostring(state))
end

local function refreshAfterImport()
    local renderSuccess, celesteRender = pcall(require, "celeste_render")

    if renderSuccess and celesteRender.loadCustomTilesetAutotiler then
        pcall(celesteRender.loadCustomTilesetAutotiler, loadedState)
    end

    local toolsSuccess, toolsWindow = pcall(require, "ui/windows/tools")

    if toolsSuccess and toolsWindow.refreshMaterialList then
        toolsWindow.refreshMaterialList()
    end
end

local function openImportForm(project, sourceImage, baseName)
    local scriptsPanel = require("ui.windows.scripts_panel")

    local templateOptions = {}

    for _, templateName in ipairs(projectTilesets.getTemplateNames()) do
        table.insert(templateOptions, {getString("import_tpl_" .. templateName), templateName})
    end

    local layerOptions = {
        {getString("import_layer_fg"), "tilesFg"},
        {getString("import_layer_bg"), "tilesBg"}
    }

    local panelScript = {
        name = "projectImport",
        title = getString("import_title"),
        fieldOrder = {"fileName", "tileId", "template", "layer", "vanilla"},
        defaultData = {
            fileName = baseName,
            tileId = "",
            template = "vanilla",
            layer = "tilesFg",
            vanilla = false
        },
        fieldInformation = {
            fileName = {
                displayName = getString("import_field_name"),
                tooltipText = getString("import_field_name_tooltip")
            },
            tileId = {
                displayName = getString("import_field_id"),
                tooltipText = getString("import_field_id_tooltip"),
                validator = function(value)
                    local id = utils.trim(tostring(value or ""))

                    if id == "" or string.find(id, "[%s\"&<>]") then
                        return false
                    end

                    local state = projectTilesets.getState(project, "tilesFg", id, false)

                    return state ~= "used" and state ~= "template"
                end,
                warningValidator = function(value)
                    local id = utils.trim(tostring(value or ""))

                    if id == "" then
                        return true
                    end

                    local fg = projectTilesets.getState(project, "tilesFg", id, false)
                    local bg = projectTilesets.getState(project, "tilesBg", id, false)

                    return fg ~= "used" and fg ~= "template" and bg ~= "used" and bg ~= "other"
                end
            },
            template = {
                displayName = getString("import_field_template"),
                options = templateOptions,
                editable = false
            },
            layer = {
                displayName = getString("import_field_layer"),
                options = layerOptions,
                editable = false
            },
            vanilla = {
                displayName = getString("import_field_vanilla"),
                tooltipText = getString("import_field_vanilla_tooltip")
            }
        }
    }

    scriptsPanel.open(panelScript, nil, function(values)
        local id = utils.trim(tostring(values.tileId or ""))

        local success, reason = projectTilesets.import(project, {
            sourceImage = sourceImage,
            fileName = utils.trim(tostring(values.fileName or "")),
            id = id,
            template = values.template,
            layer = values.layer,
            useVanilla = values.vanilla == true
        })

        if not success then
            notifications.notify(string.format(getString("import_failed"), getImportStateText(reason)))

            return false
        end

        notifications.notify(string.format(getString("import_done"), utils.trim(tostring(values.fileName or "")), id))
        refreshAfterImport()

        return true
    end, {
        runButtonText = getString("import_run")
    })
end

local function openImportDialog()
    local project = tool.getProject()

    if not project then
        notifications.notify(getString("no_map"))

        return
    end

    filesystem.openDialog(nil, nil, function(file)
        if not file or file == "" then
            return
        end

        local extension = string.lower(filesystem.fileExtension(file))

        if not importExtensions[extension] then
            notifications.notify(getString("import_bad_image"))

            return
        end

        local baseName = filesystem.filename(filesystem.convertToUnixPath(file), "/")
        baseName = string.gsub(baseName, "%.[^%.]*$", "")

        openImportForm(project, file, baseName)
    end)
end

-- Section header (bold) or plain value row (not bold). Labels are never clickable
-- sortIndex keeps the panel in its own order: the material list sorts rows by text otherwise
local function makeLabel(key, text, isSection, indent, sortIndex)
    return {
        name = "__project_" .. key,
        displayName = tostring(text),
        displayNameNoMods = "",
        isHeader = true,
        isSource = isSection == true,
        sourceKey = "__project_" .. key,
        sourceLabel = tostring(text),
        indent = indent or 0,
        sortIndex = sortIndex,
        ancestors = {}
    }
end

local function makeButton(key, text, onPress, tooltipText, indent, sortIndex)
    return {
        name = "__project_" .. key,
        displayName = tostring(text),
        displayNameNoMods = tostring(text),
        tooltipText = tooltipText,
        isButton = true,
        indent = indent or 1,
        sortIndex = sortIndex,
        ancestors = {},
        onPress = onPress
    }
end

local function openSettings()
    local project = tool.getProject()

    if not project then
        notifications.notify(getString("no_map"))

        return
    end

    local scriptsPanel = require("ui.windows.scripts_panel")

    local collabOptions = {}

    for _, collabType in ipairs(collabTypes) do
        table.insert(collabOptions, {getCollabTypeDisplayName(collabType), collabType})
    end

    local panelScript = {
        name = "projectSettings",
        title = getString("title"),
        fieldOrder = {"projectName", "authorName", "modName", "collabType"},
        defaultData = {
            projectName = project.projectName,
            authorName = project.authorName,
            modName = project.modName,
            collabType = project.collabType
        },
        fieldInformation = {
            projectName = {
                displayName = getString("field_project_name"),
                tooltipText = getString("field_project_name_tooltip"),
                editable = false
            },
            authorName = {
                displayName = getString("field_author_name"),
                tooltipText = getString("field_author_name_tooltip")
            },
            modName = {
                displayName = getString("field_mod_name"),
                tooltipText = getString("field_mod_name_tooltip")
            },
            collabType = {
                displayName = getString("field_collab_type"),
                tooltipText = getString("field_collab_type_tooltip"),
                options = collabOptions,
                editable = false
            }
        }
    }

    scriptsPanel.open(panelScript, nil, function(values)
        setStoredSettings(project.projectName, {
            authorName = utils.trim(values.authorName or ""),
            modName = utils.trim(values.modName or ""),
            collabType = values.collabType
        })

        notifications.notify(getString("saved"))
        refreshPanel()

        return true
    end, {
        runButtonText = getString("save")
    })
end

local function formatValue(value)
    if value == nil or value == "" then
        return getString("unknown")
    end

    return tostring(value)
end

function tool.getMaterials()
    local items = {}
    local project = tool.getProject()
    local row = 0

    local function nextRow()
        row = row + 1

        return row
    end

    table.insert(items, makeLabel("header_project", getString("section_project"), true, 0, nextRow()))

    if project then
        table.insert(items, makeLabel("value_project",
            string.format(getString("value_project"), project.projectName), false, 1, nextRow()))
        table.insert(items, makeLabel("value_author",
            string.format(getString("value_author"), formatValue(project.authorName)), false, 1, nextRow()))
        table.insert(items, makeLabel("value_mod",
            string.format(getString("value_mod"), formatValue(project.modName)), false, 1, nextRow()))
        table.insert(items, makeLabel("value_collab",
            string.format(getString("value_collab"), getCollabTypeDisplayName(project.collabType)), false, 1, nextRow()))

    else
        table.insert(items, makeLabel("no_map", getString("no_map"), false, 1, nextRow()))
    end

    table.insert(items, makeButton("edit", getString("edit"), openSettings, getString("edit_tooltip"), 1, nextRow()))

    -- Quick path rows need a project to resolve the folders below the Mods folder
    if project then
        table.insert(items, makeLabel("header_paths", getString("section_paths"), true, 0, nextRow()))

        for _, entry in ipairs(pathEntries) do
            table.insert(items, makeButton(entry.key, getString(entry.key), openProjectFolder(entry), nil, 1, nextRow()))
        end

        table.insert(items, makeLabel("header_actions", getString("section_actions"), true, 0, nextRow()))
        table.insert(items, makeButton("map", getString("map_title"), openMapPicker, nil, 1, nextRow()))
        table.insert(items, makeButton("everest", getString("everest_create"), createEverestYaml, nil, 1, nextRow()))

        for _, entry in ipairs(actionEntries) do
            table.insert(items, makeButton(entry.key, getString(entry.key), openProjectFolder(entry), nil, 1, nextRow()))
        end

        table.insert(items, makeButton("import", getString("import_open"), openImportDialog, nil, 1, nextRow()))
    end

    return items
end

return tool
