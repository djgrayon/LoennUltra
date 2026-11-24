local utils = require("utils")
local fileLocations = require("file_locations")
local yaml = require("lib.yaml")
local config = require("utils.config")
local configs = require("configs")
local filesystem = require("utils.filesystem")
local logging = require("logging")
local launchArguments = require("launch_arguments")
local virtualFs = require("virtual_fs")
local startupProgress = require("startup_progress")

local modHandler = {}

local everestBuildNumberMatch = "EverestBuild(%d*)"

modHandler.everestModName = "Everest"
modHandler.everestCoreModName = "EverestCore"
modHandler.internalModContent = "@Internal@"
modHandler.commonModContent = "@ModsCommon@"
modHandler.everestYamlFilenames = {
    "everest.yaml",
    "everest.yml"
}
modHandler.specificModContentSymbol = "$"
modHandler.specificModContent = "$%s$"
modHandler.pluginFolderNames = {
    fileLocations.loennSimpleFolderName
}

-- Root of the isolated editor plugin ecosystem. Content extensions (entities, triggers, effects,
-- lang, ...) always stay under "Loenn"; the plugin categories listed below are read from here so
-- editor plugins can't interfere with content extensions or with the editor itself. Editor plugins
-- bootstrap from "libraries" too, so those are handled separately in findPluginFiletype.
modHandler.isolatedPluginRoot = "Loenn2"

modHandler.isolatedPluginCategories = {
    tools = true,
    ["ui/windows"] = true,
    scenes = true
}

-- Old mods whose editor plugins still need to work. They keep loading the
-- isolated categories from their "Loenn" folder as well
modHandler.isolatedPluginWhitelistFallback = {
    "AltSidesHelper",
    "Loenn_Searcher",
    "Loenn Searcher",
    "CameraSim",
    "LoennExtended",
}

local isolatedPluginWhitelistLookup

-- Mod folder names are the mod folder or archive name with dots replaced, e.g.
-- "AltSidesHelper_zip" for "AltSidesHelper.zip", so the whitelist compares
-- without that suffix and case insensitively
local function normalizeModName(name)
    if type(name) ~= "string" then
        return nil
    end

    return string.lower(name):gsub("_zip$", "")
end

local function getIsolatedPluginWhitelist()
    if not isolatedPluginWhitelistLookup then
        isolatedPluginWhitelistLookup = {}

        local list = modHandler.isolatedPluginWhitelistFallback

        if type(configs.general) == "table" and type(configs.general.isolatedPluginWhitelist) == "table" then
            list = configs.general.isolatedPluginWhitelist
        end

        for _, modName in ipairs(list) do
            local normalized = normalizeModName(modName)

            if normalized then
                isolatedPluginWhitelistLookup[normalized] = true
            end
        end
    end

    return isolatedPluginWhitelistLookup
end

function modHandler.isIsolatedPluginWhitelisted(modFolderName)
    if not modFolderName then
        return false
    end

    local lookup = getIsolatedPluginWhitelist()
    local normalized = normalizeModName(modFolderName)

    if lookup[normalized] then
        return true
    end

    -- Also accept the name declared in the mod metadata (everest.yaml)
    local modInfo = modHandler.loadedMods[modFolderName]
    local metadata = modInfo and modInfo.metadata

    if metadata and lookup[normalizeModName(metadata.name)] then
        return true
    end

    return false
end

-- A mod that has not migrated to the isolated plugin folder keeps working from "Loenn"
function modHandler.hasIsolatedCategory(modFolderName, startFolder)
    if not modFolderName then
        return false
    end

    local path = utils.convertToUnixPath(utils.joinpath(
        string.format(modHandler.specificModContent, modFolderName),
        modHandler.isolatedPluginRoot,
        startFolder
    ))

    return love.filesystem.getInfo(path) ~= nil
end

-- Returns the root folders that should be searched for a plugin category
function modHandler.getPluginRoots(startFolder, modFolderName)
    if modHandler.isolatedPluginCategories[startFolder] or startFolder == "libraries" then
        local roots = {modHandler.isolatedPluginRoot}

        if modHandler.isIsolatedPluginWhitelisted(modFolderName)
            or not modHandler.hasIsolatedCategory(modFolderName, startFolder) then
            for _, folderName in ipairs(modHandler.pluginFolderNames) do
                table.insert(roots, folderName)
            end
        end

        return roots
    end

    return modHandler.pluginFolderNames
end

modHandler.loadedMods = {}
modHandler.loadedNameLookup = {}
modHandler.knownPluginRequires = {}
modHandler.modMetadata = {}
modHandler.modSettings = {}
modHandler.modPersistence = {}

-- Parsed filename caches, keyed by mod folder name
modHandler.filenamesCache = {}

-- Mod folders that are actually mounted; everything else is mounted on demand
modHandler.mountedMods = {}

modHandler.modNamesFormat = "[%s]"
modHandler.modNamesSeparator = " + "

modHandler.persistenceBufferTime = 300

modHandler.cacheableFiletypes = {
    zip = {
        png = true,
        lang = true,
        lua = true
    },
    folder = {
        png = true
    }
}

function modHandler.getModFilenames(modFolderName, path, filenames, predicate, useCache)
    filenames = filenames or {}

    local modFilenames = {}

    if useCache then
        modFilenames = modHandler.getOrCacheFilenames(modFolderName)

    else
        modFilenames = utils.getFilenames(path, true, {}, nil, true)
    end

    for _, filename in ipairs(modFilenames) do
        if utils.startsWith(filename, path) then
            if predicate then
                if predicate(filename) then
                    table.insert(filenames, filename)
                end

            else
                table.insert(filenames, filename)
            end
        end
    end

    return filenames
end

-- Finds files in all folders that are recognized as plugin folders
function modHandler.findPluginFiletype(startFolder, filetype)
    local filenames = {}

    if modHandler.isolatedPluginCategories[startFolder] or startFolder == "libraries" then
        for modFolderName in pairs(modHandler.loadedMods) do
            for _, folderName in ipairs(modHandler.getPluginRoots(startFolder, modFolderName)) do
                local pluginStartFolder = utils.convertToUnixPath(utils.joinpath(
                    folderName,
                    startFolder
                ))

                modHandler.findModFolderFiletype(modFolderName, filenames, pluginStartFolder, filetype)
            end
        end

        return filenames
    end

    for _, folderName in ipairs(modHandler.getPluginRoots(startFolder)) do
        for modFolderName, _ in pairs(modHandler.loadedMods) do
            local pluginStartFolder = utils.convertToUnixPath(utils.joinpath(
                folderName,
                startFolder
            ))

            modHandler.findModFolderFiletype(modFolderName, filenames, pluginStartFolder, filetype)
        end
    end

    return filenames
end

function modHandler.canCacheFiletype(modFolderName, filetype)
    if not filetype then
        return false
    end

    local modInfo = modHandler.loadedMods[modFolderName]

    if not modInfo then
        return false
    end

    local isZip = modInfo.zipFile
    local cacheKey = isZip and "zip" or "folder"

    return modHandler.cacheableFiletypes[cacheKey][filetype] or false
end

-- Fine tuned search for exactly one mod folder
function modHandler.findModFolderFiletype(modFolderName, filenames, startFolder, filetype)
    local path = utils.convertToUnixPath(utils.joinpath(
        string.format(modHandler.specificModContent, modFolderName),
        startFolder
    ))

    if filetype then
        local filetypePredicate = function(filename)
            return utils.fileExtension(filename) == filetype
        end

        local canCache = modHandler.canCacheFiletype(modFolderName, filetype)

        return modHandler.getModFilenames(modFolderName, path, filenames, filetypePredicate, canCache)

    else
        return modHandler.getModFilenames(modFolderName, path, filenames)
    end
end

-- Finds files relative to the root of every loaded mod
-- This is more performant than using the common mount point when looking for files recursively
function modHandler.findModFiletype(startFolder, filetype, folderNames)
    -- Fall back to all loaded mods
    folderNames = folderNames and table.flip(folderNames) or modHandler.loadedMods

    local filenames = {}

    for modFolderName, _ in pairs(folderNames) do
        modHandler.findModFolderFiletype(modFolderName, filenames, startFolder, filetype)
    end

    return filenames
end

function modHandler.findPlugins(pluginType)
    return modHandler.findPluginFiletype(pluginType, "lua")
end

-- Custom wipes are added to the metadata form by small libraries that inject into
-- celesteEnums.wipe_names. The established location is "Loenn/libraries/wipeDropdown.lua";
-- plugin isolation otherwise stops that file from loading, so collect it explicitly.
modHandler.wipeDropdownFilename = "wipeDropdown.lua"

function modHandler.findWipeDropdownLibraries()
    local filenames = {}

    for modFolderName in pairs(modHandler.loadedMods) do
        local modFilenames = modHandler.filenamesCache[modFolderName]

        if modFilenames then
            local prefix = utils.convertToUnixPath(utils.joinpath(
                string.format(modHandler.specificModContent, modFolderName),
                fileLocations.loennSimpleFolderName,
                "libraries"
            )) .. "/"

            for _, filename in ipairs(modFilenames) do
                if utils.startsWith(filename, prefix)
                    and utils.filename(filename, "/") == modHandler.wipeDropdownFilename then
                    table.insert(filenames, filename)
                end
            end
        end
    end

    return filenames
end

function modHandler.findLanguageFiles(startPath)
    startPath = startPath or "lang"

    return modHandler.findPluginFiletype(startPath, "lang")
end

function modHandler.mountable(path)
    local attributes = utils.pathAttributes(path)

    if attributes and attributes.mode == "directory" then
        return true, "folder"

    elseif utils.fileExtension(path) == "zip" then
        return true, "zip"
    end

    return false
end

function modHandler.getFilenameModName(filename)
    if not filename then
        return
    end

    local celesteDir = fileLocations.getCelesteDir()
    local celesteModsDir = utils.joinpath(celesteDir, "Mods")
    local celesteParts = utils.splitpath(utils.convertToUnixPath(celesteModsDir), "/")
    local filenameParts = utils.splitpath(utils.convertToUnixPath(filename), "/")

    -- Remove empty parts from end of celesteParts
    for i = #celesteParts, 1, -1 do
        if celesteParts[i] == "" then
            celesteParts[i] = nil

        else
            break
        end
    end

    for i, part in ipairs(celesteParts) do
        if filenameParts[i] ~= part then
            return
        end
    end

    -- Make sure this is a folder and not a map file directly in mods folder
    if not filenameParts[#celesteParts + 2] then
        return
    end

    -- Fetch part after CelesteRoot/Mods/
    return filenameParts[#celesteParts + 1]
end

function modHandler.getFilenameModPath(filename)
    local modName = modHandler.getFilenameModName(filename)
    local celesteDir = fileLocations.getCelesteDir()

    if modName then
        return utils.joinpath(celesteDir, "Mods", modName)
    end
end

-- Assumes entity names are "modName/entityName"
function modHandler.getEntityModPrefix(name)
    return name:match("^(.-)/")
end

function modHandler.findPluginLoennFolder(mountPoint)
    for _, folderName in ipairs(modHandler.pluginFolderNames) do
        local folderTestPath = mountPoint .. "/" .. folderName
        local folderInfo = love.filesystem.getInfo(folderTestPath)

        if folderInfo and folderInfo.type == "directory" then
            return mountPoint .. "/" .. folderName
        end
    end
end

local function getbuildNumber(filename)
    local fullFilename = utils.joinpath(fileLocations.getCelesteDir(), filename)
    local fh = utils.getFileHandle(fullFilename, "rb")

    if fh then
        local data = fh:read("*a")
        local buildNumber = string.match(data, everestBuildNumberMatch)

        fh:close()

        return buildNumber
    end
end

function modHandler.getEverestBuildNumber()
    -- Check both, .NET core builds of Everest has it in the .dll
    return getbuildNumber("Celeste.exe") or getbuildNumber("Celeste.dll")
end

function modHandler.getEverestVersion()
    local buildNumber = modHandler.getEverestBuildNumber()

    if buildNumber then
        return string.format("1.%s.0", buildNumber)
    end
end

function modHandler.findEverestYaml(mountPoint)
    for _, filename in ipairs(modHandler.everestYamlFilenames) do
        local yamlTestPath = mountPoint .. "/" .. filename
        local info = love.filesystem.getInfo(yamlTestPath)

        if info and info.type == "file" then
            return yamlTestPath, filename
        end
    end
end

-- Find existing or fall back to first search filename
function modHandler.findEverestYamlOrDefault(mountPoint)
    local yamlTestPath, filename = modHandler.findEverestYaml(mountPoint)

    return filename or modHandler.everestYamlFilenames[1]
end

function modHandler.updateModMetadataCache(modMetadata, folderName)
    modHandler.modMetadata[folderName] = modMetadata

    if modHandler.loadedMods[folderName] then
        modHandler.loadedMods[folderName].metadata = modMetadata
    end
end

function modHandler.readModMetadata(path, mountPoint, folderName, updateCache)
    local result = {}
    local yamlFilename = modHandler.findEverestYaml(mountPoint)

    if yamlFilename then
        local content, size = love.filesystem.read(yamlFilename)

        if content then
            local success, data = pcall(yaml.read, utils.stripByteOrderMark(content))

            if success and type(data) == "table" then
                result = data
                result._mountPointLoenn = modHandler.findPluginLoennFolder(mountPoint)
            end
        end
    end

    result._mountPoint = mountPoint
    result._path = path
    result._folderName = folderName

    if updateCache ~= false then
        modHandler.updateModMetadataCache(result, folderName)
    end

    return result
end

function modHandler.findLoadedMod(name)
    for modFolderName, metadata in pairs(modHandler.modMetadata) do
        for _, info in ipairs(metadata) do
            if info.Name == name then
                return info, metadata
            end
        end
    end
end

function modHandler.hasLoadedMod(name)
    local info, metadata = modHandler.findLoadedMod(name)

    return info ~= nil
end

-- Only works on files loaded with requireFromPlugin
function modHandler.unrequireKnownPluginRequires()
    for name, _ in pairs(modHandler.knownPluginRequires) do
        utils.unrequire(name)
    end
end

function modHandler.cleanDebugSource(source)
    -- Remove @ from mod content requires, added to fix luajit profiler
    if utils.startsWith(source, "@" .. modHandler.specificModContentSymbol) then
        return string.sub(source, 2)
    end

    return source
end

-- Defaults to current mod directory
local safeStub
safeStub = setmetatable({}, {
    __index = function() return safeStub end,
    __call = function() return safeStub end,
})

function modHandler.requireFromPlugin(lib, modName)
    local requireName = modHandler.filenameFromPlugin(lib, modName, ".")

    if requireName then
        local success, result = utils.tryrequire(requireName)
        if success then
            modHandler.knownPluginRequires[requireName] = result
            return result
        end

        logging.warning(string.format(
            "[plugins] failed to require '%s' (mod: %s); using safe stub",
            tostring(requireName), tostring(modName)))
    end

    return safeStub
end

-- Defaults to current mod directory
function modHandler.filenameFromPlugin(filename, modName, resultSeparator, maxDepth)
    resultSeparator = resultSeparator or "/"
    maxDepth = maxDepth or 10

    local filenamePrefix

    if modName then
        local modInfo, pluginInfo = modHandler.findLoadedMod(modName)

        if modInfo then
            filenamePrefix = pluginInfo._mountPointLoenn
        end

    else
        local currentFilename = debug.getinfo(1).source
        local parts = {}

        -- Find first usage outside of current file
        for i = 2, maxDepth do
            local info = debug.getinfo(i)

            if info.source ~= currentFilename then
                local source = modHandler.cleanDebugSource(info.source)

                parts = string.split(source, "/")()
                filenamePrefix = table.concat(parts, resultSeparator, 1, 2)

                break
            end
        end
    end

    if filename and filenamePrefix then
        return filenamePrefix .. resultSeparator .. filename
    end
end

-- Defaults to current mod directory
function modHandler.readFromPlugin(filename, modName)
    local filenameFromPlugin = modHandler.filenameFromPlugin(filename, modName)

    if filenameFromPlugin then
        local content = utils.readAll(filenameFromPlugin)

        return content
    end
end

local function createModSettingDirectory(modName)
    -- Exit early if the requested mod isn't loaded
    -- No need to create folders for a mod that potentially doesn't exist
    if not modHandler.hasLoadedMod(modName) then
        return false
    end

    local pluginsPath = fileLocations.getPluginsPath()
    local pluginsModPath = utils.joinpath(pluginsPath, modName)

    if not filesystem.isDirectory(pluginsModPath) then
        filesystem.mkpath(pluginsModPath)
    end

    return true
end

-- Work our way up the stack to find the first plugin related source
-- This makes sure the function can be used from anywhere
function modHandler.getCurrentModName(maxDepth)
    maxDepth = maxDepth or 10

    for i = 2, maxDepth do
        local info = debug.getinfo(i)

        if not info then
            return
        end

        local source = modHandler.cleanDebugSource(info.source)

        if utils.startsWith(source, modHandler.specificModContentSymbol) then
            local parts = string.split(source, "/")()
            local specificName = parts[1]

            -- Match the specific name to a loaded mod's mount point
            for modFolderName, metadata in pairs(modHandler.modMetadata) do
                if metadata._mountPoint == specificName then
                    if metadata[1] then
                        return metadata[1].Name
                    end
                end
            end
        end
    end
end

-- Defaults to current mod
function modHandler.getModSettings(modName)
    modName = modName or modHandler.getCurrentModName()

    if modName then
        if not modHandler.modSettings[modName] then
            local pluginsPath = fileLocations.getPluginsPath()
            local settingsPath = utils.joinpath(pluginsPath, modName, "settings.conf")

            createModSettingDirectory(modName)

            modHandler.modSettings[modName] = config.readConfig(settingsPath)
        end

        return modHandler.modSettings[modName]
    end
end

-- Defaults to current mod
function modHandler.getModPersistence(modName)
    modName = modName or modHandler.getCurrentModName()

    if not modHandler.modPersistence[modName] then
        local pluginsPath = fileLocations.getPluginsPath()
        local persistencePath = utils.joinpath(pluginsPath, modName, "persistence.conf")

        createModSettingDirectory(modName)

        modHandler.modPersistence[modName] = config.readConfig(persistencePath, modHandler.persistenceBufferTime)
    end

    return modHandler.modPersistence[modName]
end

function modHandler.writeModPersistences()
    for _, persistence in pairs(modHandler.modPersistence) do
        config.writeConfig(persistence, true)
    end
end

function modHandler.invalidateFilenamesCacheFromPath(path)
    local modPath = modHandler.getFilenameModPath(path)

    if modPath then
        local metadata = modHandler.getModMetadataFromPath(modPath)

        if metadata then
            modHandler.invalidateFilenamesCache(metadata._folderName)
        end
    end
end

-- Mod metadata as it is stored in the filename cache (runtime fields stripped)
local function metadataForCache(metadata)
    local copy = {}

    for key, value in pairs(metadata or {}) do
        if type(key) ~= "string" or key:sub(1, 1) ~= "_" then
            copy[key] = value
        end
    end

    return copy
end

local function pluginMountPointFromFilenames(modFolderName, filenames)
    if not filenames then
        return
    end

    local root = "$" .. modFolderName .. "$"

    for _, folderName in ipairs(modHandler.pluginFolderNames) do
        local prefix = root .. "/" .. folderName .. "/"

        for i = 1, #filenames do
            if filenames[i]:sub(1, #prefix) == prefix then
                return root .. "/" .. folderName
            end
        end
    end
end

local function metadataFromCache(data, path, modFolderName)
    local metadata = {}

    for key, value in pairs(data or {}) do
        metadata[key] = value
    end

    metadata._mountPoint = string.format(modHandler.specificModContent, modFolderName)
    metadata._path = path
    metadata._folderName = modFolderName

    return metadata
end

function modHandler.invalidateFilenamesCache(modFolderName)
    modHandler.filenamesCache[modFolderName] = nil

    local modInfo = modHandler.loadedMods[modFolderName]

    if modInfo and modInfo.path then
        modHandler.registerModInfo(modInfo.path, modFolderName, true)
    end
end

function modHandler.getOrCacheFilenames(modFolderName, useYield, force)
    if force then
        modHandler.invalidateFilenamesCache(modFolderName)
    end

    local cached = modHandler.filenamesCache[modFolderName]

    if cached then
        return cached
    end

    local modInfo = modHandler.loadedMods[modFolderName]

    if not modInfo or not modInfo.path then
        return
    end

    modHandler.registerModInfo(modInfo.path, modFolderName, force)

    return modHandler.filenamesCache[modFolderName]
end

local function cachePath(cacheFolder, modFolderName)
    local storageDir = fileLocations.getStorageDir()

    return utils.joinpath(storageDir, "Cache", cacheFolder, modFolderName .. ".conf")
end

local function isCacheValid(cache, attributes, force)
    if force or not cache or not cache.createdAt then
        return false
    end

    -- Mod authors rarely bump their version, so compare file metadata instead:
    -- a re-exported archive changes both modification time and size
    if attributes.modification and attributes.modification > cache.createdAt then
        return false
    end

    if cache.size and attributes.size and cache.size ~= attributes.size then
        return false
    end

    return true
end

local function readCache(cacheFolder, modFolderName, attributes, force)
    local cache = config.readConfig(cachePath(cacheFolder, modFolderName))

    if not isCacheValid(cache, attributes, force) then
        return nil
    end

    return cache
end

local function writeCache(cacheFolder, modFolderName, attributes, data)
    local target = cachePath(cacheFolder, modFolderName)

    filesystem.mkpath(utils.dirname(target))

    data.createdAt = attributes.modification
    data.size = attributes.size

    local cache = config.createConfig(target, data, -1, 0, false)

    return config.writeConfig(cache, true)
end

-- File lists live in their own cache file: they are large (tens of MB in total)
-- and only change when an archive changes, while metadata is small
local function readModFilenamesCache(modFolderName, attributes, force)
    local cache = readCache("ModFilenames", modFolderName, attributes, force)

    if cache and cache.filenames then
        return cache
    end
end

local function writeModFilenamesCache(modFolderName, attributes, filenames)
    return writeCache("ModFilenames", modFolderName, attributes, {
        filenames = filenames
    })
end

local function readModMetadataCache(modFolderName, attributes, force)
    local cache = readCache("ModMetadata", modFolderName, attributes, force)

    if cache and cache.metadata then
        return cache
    end
end

local function writeModMetadataCache(modFolderName, attributes, metadata)
    return writeCache("ModMetadata", modFolderName, attributes, {
        metadata = metadataForCache(metadata)
    })
end

-- Mounts a mod's archive/folder at its own mount point (and the shared one when
-- enabled). Idempotent.
function modHandler.mountModFiles(modFolderName, path)
    if modHandler.mountedMods[modFolderName] then
        return true
    end

    if not path or not modHandler.mountable(path) then
        return false
    end

    local directory, filename = utils.dirname(path), utils.filename(path)
    local specificMountPoint = string.format(modHandler.specificModContent, modFolderName)

    -- The shared "@ModsCommon@/" mount point is what makes every archive be
    -- parsed a second time; virtual_fs resolves shared paths when it is off
    if configs.editor.mountSharedModView ~= false then
        -- Can't mount the same path twice, trick physfs into loading both
        love.filesystem.mountUnsandboxed(path, modHandler.commonModContent .. "/", 1)
    end

    love.filesystem.mountUnsandboxed(utils.joinpath(directory, ".", filename), specificMountPoint, 1)

    modHandler.mountedMods[modFolderName] = true

    local modInfo = modHandler.loadedMods[modFolderName]

    if modInfo then
        modInfo.mounted = true
    end

    virtualFs.markMounted()

    return true
end

-- Registers a mod: metadata, filename list, virtual_fs index entry and the archive mount. Archives
-- are mounted here during startup so later file access does not have to build the PhysFS index.
function modHandler.registerModInfo(path, modFolderName, force)
    local attributes = filesystem.pathAttributes(path) or {}
    local zipFile = attributes.mode == "file"
    local specificMountPoint = string.format(modHandler.specificModContent, modFolderName)
    local filenames, metadata

    if zipFile then
        local filenamesCache = readModFilenamesCache(modFolderName, attributes, force)
        local metadataCache = readModMetadataCache(modFolderName, attributes, force)

        if filenamesCache then
            filenames = filenamesCache.filenames
        end

        if metadataCache then
            metadata = metadataFromCache(metadataCache.metadata, path, modFolderName)
        end

        if not filenames or not metadata then
            if not modHandler.mountModFiles(modFolderName, path) then
                return false
            end

            if not metadata then
                metadata = modHandler.readModMetadata(path, specificMountPoint, modFolderName)

                writeModMetadataCache(modFolderName, attributes, metadata)
            end

            if not filenames then
                filenames = utils.getFilenames(specificMountPoint, true, {}, nil, true)

                writeModFilenamesCache(modFolderName, attributes, filenames)

                if configs.debug.logModFilenamesCache then
                    logging.info(string.format("Updated filename cache for '%s'", modFolderName))
                end
            end
        end

    else
        -- Folder mods have no archive to parse and change constantly while
        -- developing, so mount and walk them every time
        if not modHandler.mountModFiles(modFolderName, path) then
            return false
        end

        filenames = utils.getFilenames(specificMountPoint, true, {}, nil, true)
        metadata = modHandler.readModMetadata(path, specificMountPoint, modFolderName)
    end

    metadata._mountPointLoenn = metadata._mountPointLoenn or pluginMountPointFromFilenames(modFolderName, filenames)

    modHandler.modMetadata[modFolderName] = metadata
    modHandler.loadedMods[modFolderName] = {
        zipFile = zipFile,
        mtime = attributes.modification,
        size = attributes.size,
        path = path,
        mounted = modHandler.mountedMods[modFolderName] or false,
        metadata = metadata
    }
    modHandler.filenamesCache[modFolderName] = filenames

    virtualFs.registerMod(modFolderName, filenames, zipFile)

    -- Mount every mod up front: accessing a single file from an archive later means PhysFS has to
    -- build its index first, which caused the first hover on preview images from a zip to stall.
    -- Mounting during loading moves that cost to startup and after that every lookup is cached.
    if not modHandler.mountedMods[modFolderName] then
        modHandler.mountModFiles(modFolderName, path)
    end

    return true
end

function modHandler.mountMod(path, force)
    if not path then
        return false
    end

    local startTime = love.timer.getTime()

    -- Replace "." in ".zip" to prevent require from getting confused
    local filename = utils.filename(path)
    local modFolderName = filename:gsub("%.", "_")
    local loaded = not not modHandler.loadedMods[modFolderName]
    local gotLoaded = false

    if not loaded or force then
        if modHandler.mountable(path) then
            gotLoaded = modHandler.registerModInfo(path, modFolderName, force) or false
        end
    end

    local endTime = love.timer.getTime()

    if gotLoaded and configs.debug.logModLoading then
        local message = string.format("Loaded '%s' in %.2fms", modFolderName, (endTime - startTime) * 1000)

        logging.info(message)
    end

    return loaded
end

function modHandler.readEverestBlacklist(filename)
    filename = filename or utils.joinpath(fileLocations.getCelesteDir(), "Mods", "blacklist.txt")

    local content = utils.readAll(filename)
    local lines = string.split(content, "\n")()

    local ignored = {}

    for _, line in ipairs(lines) do
        if not utils.startsWith(line, "#") and line ~= "" then
            local lineUnderscores = line:gsub("%.", "_")

            ignored[line] = true
            ignored[lineUnderscores] = true
        end
    end

    return ignored
end

-- PhysFS's archive parser used to hold the global filesystem lock for the whole mount. Our patched
-- runtime lets the parsers run concurrently; this pre-pass keeps Lönn's registration loop unchanged
-- and only moves the expensive archive indexing off the serial critical path.
function modHandler.preMountMods(directory, filenames, ignored, noMods, alwaysLoad)
    -- Only the bundled patched LÖVE runtime can mount archives concurrently without serializing on
    -- PhysFS's global state lock. With an unpatched system LÖVE this would only add thread overhead.
    if not (love.filesystem.hasParallelMount and love.filesystem.hasParallelMount()) then
        return
    end

    local tasks = {}

    for _, filename in ipairs(filenames) do
        local modIgnored = not alwaysLoad[filename] and (ignored[filename] or noMods)

        if not modIgnored then
            local path = utils.joinpath(directory, filename)

            if modHandler.mountable(path) then
                local modFolderName = filename:gsub("%.", "_")

                -- Match the exact path string mountModFiles uses, so PhysFS sees it as already
                -- mounted instead of parsing the archive a second time.
                local mountPath = utils.joinpath(utils.dirname(path), ".", utils.filename(path))

                table.insert(tasks, {
                    path = mountPath,
                    mountPoint = string.format(modHandler.specificModContent, modFolderName)
                })
            end
        end
    end

    if #tasks == 0 then
        return
    end

    local preMountStart = love.timer.getTime()
    local threadCount = math.min(16, #tasks)
    local code = [[
        local function run(tasks, first, last, channelName)
            local physfs = require("lib.physfs")
            local channel = love.thread.getChannel(channelName)
            local failures = 0

            for i = first, last do
                local task = tasks[i]

                if physfs.mount(task.path, task.mountPoint, 1) == 0 then
                    failures = failures + 1
                end
            end

            channel:push(failures)
        end

        run(...)
    ]]

    local channelName = "mod-premount-" .. tostring(love.timer.getTime())
    local threads = {}
    local perThread = math.ceil(#tasks / threadCount)

    for i = 1, threadCount do
        local first = (i - 1) * perThread + 1
        local last = math.min(i * perThread, #tasks)

        if first <= last then
            local thread = love.thread.newThread(code)
            thread:start(tasks, first, last, channelName)
            table.insert(threads, thread)
        end
    end

    for _, thread in ipairs(threads) do
        thread:wait()
    end

    local channel = love.thread.getChannel(channelName)
    local failures = 0

    while channel:getCount() > 0 do
        failures = failures + (channel:pop() or 0)
    end

    if configs.debug.logModLoading then
        logging.info(string.format("[mods] pre-mounted %d archives in parallel (%d threads, %d failures)",
            #tasks, threadCount, failures))
    end

    logging.info(string.format("[mods] pre-mount took %.2fs", love.timer.getTime() - preMountStart))
end

function modHandler.mountMods(directory, force)
    directory = directory or utils.joinpath(fileLocations.getCelesteDir(), "Mods")

    local ignored = {}

    if configs.general.useEverestBlacklist then
        logging.info("Reading Everest blacklist")

        ignored = modHandler.readEverestBlacklist(utils.joinpath(directory, "blacklist.txt"))
    end

    -- Launch arguments: --no-mods skips everything except --load-mod entries
    local noMods = launchArguments.parsed.noMods
    local alwaysLoad = table.flip(launchArguments.parsed.loadMods or {})

    if utils.isDirectory(directory) then
        local filenames = {}

        for filename in utils.listDir(directory) do
            if filename ~= "." and filename ~= ".." then
                table.insert(filenames, filename)
            end
        end

        modHandler.preMountMods(directory, filenames, ignored, noMods, alwaysLoad)

        for index, filename in ipairs(filenames) do
            startupProgress.reportFiles(#filenames, index, string.format("Loading mod %s", filename))

            local modIgnored = not alwaysLoad[filename] and (ignored[filename] or noMods)

            if modIgnored then
                if configs.debug.logModLoading then
                    local message = string.format("Skipped '%s' due to Everest blacklist or launch arguments", filename)

                    logging.info(message)
                end

            else
                modHandler.mountMod(utils.joinpath(directory, filename), force)
            end

            coroutine.yield()
        end
    end
end

local function getModMetadataByKeyCached(value, key, hasTriedMount)
    local modFolder = modHandler.loadedNameLookup[value]

    if not modFolder then
        for modFolder, metadata in pairs(modHandler.modMetadata) do
            local metadataValue = metadata[key]

            if utils.samePath(metadataValue, value) then
                local loadedModInfo = modHandler.loadedMods[modFolder]

                if loadedModInfo then
                    modHandler.loadedNameLookup[value] = modFolder
                end

                return metadata
            end
        end
    end

    if not hasTriedMount then
        -- Try mounting the mod folder, might be a new folder since startup
        modHandler.mountMod(value)

        return getModMetadataByKeyCached(value, key, true)
    end

    return modHandler.modMetadata[modFolder]
end

local function getModMetadataFromRealFilename(filename)
    return getModMetadataByKeyCached(filename, "_path")
end

local function getModMetadataFromSpecific(filename)
    return getModMetadataByKeyCached(filename, "_mountPoint")
end

function modHandler.getModMetadataFromPath(path)
    if not path then
        return
    end

    if utils.startsWith(path, modHandler.specificModContentSymbol) then
        local parts = utils.splitpath(path, "/")
        local firstPart = parts[1]

        return getModMetadataFromSpecific(firstPart)

    elseif utils.startsWith(path, modHandler.commonModContent) then
        local realFilename = love.filesystem.getRealDirectory(path)

        if not realFilename then
            return
        end

        return getModMetadataFromRealFilename(realFilename)

    else
        -- Assume anything left over is a real filename

        return getModMetadataFromRealFilename(path)
    end
end

function modHandler.getModNamesFromMetadata(metadata)
    if metadata then
        if #metadata == 1 and metadata[1].Name then
            return {tostring(metadata[1].Name)}

        else
            local names = {}

            for _, info in ipairs(metadata) do
                if info.Name then
                    table.insert(names, tostring(info.Name))
                end
            end

            return names
        end
    end
end

function modHandler.getDependencyModNames(metadata, addSelf)
    local dependedOnMods = {}

    for _, info in ipairs(metadata) do
        if addSelf ~= false and info.Name then
            table.insert(dependedOnMods, info.Name)
        end

        for _, dependency in ipairs(info.Dependencies or {}) do
            if dependency.Name then
                table.insert(dependedOnMods, dependency.Name)
            end
        end
    end

    return dependedOnMods
end

function modHandler.getAvailableModNames()
    local availableNames = {}

    for _, metadata in pairs(modHandler.modMetadata) do
        local modNames = modHandler.getModNamesFromMetadata(metadata)

        if modNames then
            for _, modName in ipairs(modNames) do
                table.insert(availableNames, modName)
            end
        end
    end

    return availableNames
end

function modHandler.formatAssociatedMods(language, modNames)
    local displayNames = {}

    for _, modName in ipairs(modNames or {}) do
        local modNameLanguage = language.mods[modName].name

        if modNameLanguage._exists then
            displayNames[tostring(modNameLanguage)] = true

        else
            displayNames[modName] = true
        end
    end

    displayNames = table.keys(displayNames)

    if #displayNames > 0 then
        table.sort(displayNames)

        local joinedNames = table.concat(displayNames, modHandler.modNamesSeparator)

        return string.format(modHandler.modNamesFormat, joinedNames)
    end
end

function modHandler.isEverest(modName)
    return modName == modHandler.everestModName or modName == modHandler.everestCoreModName
end

function modHandler.checkForMissingMods(filename)
    local modPath = modHandler.getFilenameModPath(filename)

    if not modPath then
        return {}
    end

    local modMetadata = modHandler.getModMetadataFromPath(modPath)

    if not modMetadata or not modMetadata[1] then
        return {}
    end

    local metadata = modMetadata[1]
    local missing = {}

    for _, dependency in ipairs(metadata.Dependencies or {}) do
        local modName = dependency.Name
        local isEverest = modHandler.isEverest(modName)
        local loaded = modHandler.hasLoadedMod(dependency.Name)

        if not isEverest and not loaded then
            table.insert(missing, dependency.Name)
        end
    end

    return missing
end

return modHandler