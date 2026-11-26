-- TODO - Should work without Everest.yaml
-- TODO - Makeit possible to update versions

local ui = require("ui")
local uiElements = require("ui.elements")
local uiUtils = require("ui.utils")

local loadedState = require("loaded_state")
local languageRegistry = require("language_registry")
local utils = require("utils")
local form = require("ui.forms.form")
local configs = require("configs")
local yaml = require("lib.yaml")
local notifications = require("ui.notification")

local mods = require("mods")
local dependencyEditor = require("ui.dependency_editor")
local dependencyFinder = require("dependencies")

local listWidgets = require("ui.widgets.lists")
local widgetUtils = require("ui.widgets.utils")
local gridElement = require("ui.widgets.grid")

local windowPersister = require("ui.window_position_persister")
local windowPersisterName = "dependency_window"

local fonts = require("fonts")

local COLUMN_WIDTH = 256
local TITLE_RULE_WIDTH = 200

local dependencyWindow = {}

local dependencyWindowGroup = uiElements.group({})

local function localizeModName(modName, language)
    language = language or languageRegistry.getLanguage()

    local modNameLanguage = language.mods[modName].name

    if modNameLanguage._exists then
        return tostring(modNameLanguage)
    end

    return tostring(modName)
end

local function prepareMetadataForSaving(metadata, newDependencies)
    local newMetadata = utils.deepcopy(metadata)

    -- Remove editor specific information
    for k, v in pairs(newMetadata) do
        if type(k) == "string" and utils.startsWith(k, "_") then
            newMetadata[k] = nil
        end
    end

    -- Sort dependencies by name
    newDependencies = table.sortby(newDependencies, function(dependency)
        return dependency.Name or ""
    end)()

    local firstMetadata = newMetadata[1] or {}

    -- An empty list serializes inconsistently (the YAML writer/read validation can reject it),
    -- which made removing the last dependency silently fail. Omitting the key is valid YAML.
    firstMetadata.Dependencies = #newDependencies > 0 and newDependencies or nil

    return newMetadata
end

local function updateMetadataFile(metadata, newDependencies)
    local path = metadata._path
    local mountPoint = metadata._mountPoint
    local folderName = metadata._folderName
    local filename

    if not filename then
        filename = mods.findEverestYamlOrDefault(mountPoint)
    end

    if filename then
        local realFilename = utils.joinpath(love.filesystem.getRealDirectory(mountPoint), filename)
        local newMetadata = prepareMetadataForSaving(metadata, newDependencies)
        local success, reason = yaml.write(realFilename, newMetadata)

        -- Update metadata in cache
        mods.readModMetadata(path, mountPoint, folderName)

        return success
    end

    return false
end

local moveModSection
local markMetadataChanged

local function getDependenciesList(modName)    local currentModMetadata = mods.getModMetadataFromPath(modName)
    local firstMetadata = currentModMetadata and currentModMetadata[1] or {}
    local dependencies = firstMetadata.Dependencies or {}

    return dependencies, currentModMetadata
end

local function addDependencyCallback(modName, interactionData)
    return function()
        local dependencies, currentModMetadata = getDependenciesList(interactionData.modPath)
        local modInfo, modMetadata = mods.findLoadedMod(modName)
        local modVersion = modInfo and modInfo.Version

        table.insert(dependencies, {
            Name = modName,
            Version = modVersion
        })

        local success = updateMetadataFile(currentModMetadata, dependencies)

        if success then
            markMetadataChanged()
            moveModSection(interactionData, modName, "depended_on")
        end
    end
end

local function removeDependencyCallback(modName, interactionData)
    return function()
        local dependencies, currentModMetadata = getDependenciesList(interactionData.modPath)

        for i = #dependencies, 1, -1 do
            local dependency = dependencies[i]

            if dependency.Name == modName then
                table.remove(dependencies, i)
            end
        end

        local success = updateMetadataFile(currentModMetadata, dependencies)

        if success then
            markMetadataChanged()
            moveModSection(interactionData, modName, "missing_mods")
        end
    end
end

local function getModSection(modName, localizedModName, reasons, groupName, interactionData)
    local language = languageRegistry.getLanguage()
    local buttonAdds = groupName ~= "depended_on"
    local buttonLanguageKey = buttonAdds and "add_dependency" or "remove_dependency"
    local buttonText = tostring(language.ui.dependency_window[buttonLanguageKey])

    local buttonCallbackWrapper = buttonAdds and addDependencyCallback or removeDependencyCallback
    local buttonCallback = buttonCallbackWrapper(modName, interactionData)

    -- Entity sources are shown in the Debug tool, so only the mod name is listed here
    local modContent = uiElements.label(localizedModName)

    local localizedEverestName = localizeModName(mods.everestModName)
    local isEverest = modName == mods.everestModName or modName == localizedEverestName

    local actionButton = uiElements.button(buttonText, buttonCallback)
    local column = uiElements.column({
        modContent,
    })

    column._modName = modName
    column._groupName = groupName
    column._sortName = localizedModName

    -- Everest should not be removable as a dependency
    -- All other mods should have the action button
    if not isEverest then
        column:addChild(actionButton)
    end

    return column
end

local function getModSections(groupName, mods, addPadding, interactionData)
    local language = languageRegistry.getLanguage()
    local labelText = tostring(language.ui.dependency_window.group[groupName])

    local baseFont = uiElements.label.__default.style.font or love.graphics.getFont()
    local titleLabel = uiElements.label(labelText, fonts.getScreenFont(math.floor(baseFont:getHeight() * 1.5 + 0.5)))
    local titleBlock = uiElements.column({
        titleLabel,
        uiElements.horizontalLine(TITLE_RULE_WIDTH)
    }):with({
        style = { spacing = 2, padding = {0, 6, 0, 4} }
    })

    local column = uiElements.column({}):with({ style = { spacing = 14 } })

    column._groupName = groupName
    column._title = titleBlock

    interactionData.sectionColumns = interactionData.sectionColumns or {}
    interactionData.sectionColumns[groupName] = column
    interactionData.modSections = interactionData.modSections or {}

    local orderedSections = {}

    -- Sort by mod name, but keep Everest first in the dependency column
    for modName, reasons in pairs(mods) do
        local localizedModName = localizeModName(modName)
        local modSection = getModSection(modName, localizedModName, reasons, groupName, interactionData)

        if modSection then
            table.insert(orderedSections, {localizedModName, modSection, modName})
        end
    end

    local localizedEverestName = localizeModName(mods.everestModName)

    orderedSections = table.sortby(orderedSections, function(entry)
        local isEverest = groupName == "depended_on"
            and (entry[3] == mods.everestModName or entry[3] == localizedEverestName)

        return (isEverest and "0" or "1") .. entry[1]
    end)()

    for _, entry in ipairs(orderedSections) do
        column:addChild(entry[2])

        interactionData.modSections[entry[2]._modName] = {
            element = entry[2],
            column = column,
            group = groupName
        }
    end

    return column
end

function markMetadataChanged()
    local history = require("history")

    history.madeChanges = true
    history.lastChange = os.time()
end

local function removeModSection(interactionData, modName)
    local entry = interactionData.modSections and interactionData.modSections[modName]
    local removed = false

    -- Remove every visible row for this mod, not just the cached entry. After a panel reopen
    -- the cache can point at a detached element while the real row is in another column.
    if interactionData.sectionColumns then
        for _, column in pairs(interactionData.sectionColumns) do
            for i = #(column.children or {}), 1, -1 do
                local child = column.children[i]

                if child._modName == modName then
                    child.visible = false
                    column:removeChild(child)
                    removed = true
                end
            end
        end
    end

    if not removed and entry and entry.element then
        if entry.column and entry.column.removeChild then
            if not entry.column:removeChild(entry.element) then
                entry.element:removeSelf()
            end

        else
            entry.element:removeSelf()
        end
    end

    if interactionData.modSections then
        interactionData.modSections[modName] = nil
    end
end

local function insertModSection(interactionData, modName, groupName)
    interactionData.sectionColumns = interactionData.sectionColumns or {}
    interactionData.modSections = interactionData.modSections or {}

    local column = interactionData.sectionColumns[groupName]

    if not column then
        if groupName == "missing_mods" then
            column = interactionData.missingModsSection

        elseif groupName == "depended_on" then
            column = interactionData.dependedOnSection

        else
            column = interactionData.uncategorizedSection
        end
    end

    if not column then
        return
    end

    local localizedName = localizeModName(modName)
    local section = getModSection(modName, localizedName, nil, groupName, interactionData)

    column.children = column.children or {}
    column:addChild(section)

    interactionData.modSections[modName] = {
        element = section,
        column = column,
        group = groupName
    }
end

moveModSection = function(interactionData, modName, groupName)
    removeModSection(interactionData, modName)
    insertModSection(interactionData, modName, groupName)

    local window = interactionData.window

    if window then
        -- The scrollbox caches its content height. Moving a row into a previously empty
        -- column (usually Missing Dependencies) needs the scroll content reflowed too,
        -- otherwise the new row is laid out outside the visible area.
        local scroll = interactionData.windowContentScrollable

        if scroll then
            scroll:layout()
            scroll:layoutLate()
            scroll:reflow()
        end

        window:layout()
        window:layoutLate()
        window:reflow()
    end
end

function dependencyWindow.getWindowContent(modPath, side, interactionData)
    local currentModMetadata = mods.getModMetadataFromPath(modPath)
    local currentModNames = mods.getModNamesFromMetadata(currentModMetadata)
    local currentModNamesLookup = table.flip(currentModNames)
    local dependedOnModNames = mods.getDependencyModNames(currentModMetadata)
    local availableModNames = mods.getAvailableModNames()
    local dependedOnModsLookup = table.flip(dependedOnModNames)

    local usedMods = interactionData.usedMods

    if not usedMods then
        usedMods = dependencyFinder.analyzeSide(side)
        interactionData.usedMods = usedMods
    end
    local missingMods = {}
    local dependedOnMods = {}
    local uncategorized = {}

    -- Mods with known usage
    for modName, reasons in pairs(usedMods) do
        if not currentModNamesLookup[modName] then
            if not dependedOnModsLookup[modName] then
                missingMods[modName] = reasons

            else
                dependedOnMods[modName] = reasons
            end
        end
    end

    -- Add Everest as target if missing
    local localizedEverestName = localizeModName(mods.everestModName)
    local hasEverest = dependedOnModsLookup[mods.everestModName] or dependedOnModsLookup[localizedEverestName]

    if not hasEverest and not missingMods[mods.everestModName] then
        missingMods[mods.everestModName] = false
    end

    -- Anything depended on but with no known usage
    for _, modName in ipairs(dependedOnModNames) do
        if not dependedOnMods[modName] then
            if not currentModNamesLookup[modName] then
                dependedOnMods[modName] = false
            end
        end
    end

    -- Anything not already added to the other categories
    for _, modName in ipairs(availableModNames) do
        if not currentModNamesLookup[modName] then
            if not missingMods[modName] and not dependedOnMods[modName] then
                uncategorized[modName] = false
            end
        end
    end

    -- Separator lines have to line up: the extra bottom padding used by the old stacked layout
    -- would shift the line of some columns vertically
    local missingModsSection = getModSections("missing_mods", missingMods, false, interactionData)
    local dependedOnSection = getModSections("depended_on", dependedOnMods, false, interactionData)
    local uncategorizedSection = getModSections("available_mods", uncategorized, false, interactionData)

    -- Three columns side by side instead of one long column. The columns touch so the separator
    -- lines form one continuous line across the window
    local function prepareColumn(section)
        section:with({
            width = COLUMN_WIDTH,
            minWidth = COLUMN_WIDTH,
            maxWidth = COLUMN_WIDTH
        })

        return section
    end

    local columns = uiElements.row({
        prepareColumn(missingModsSection),
        prepareColumn(dependedOnSection),
        prepareColumn(uncategorizedSection)
    }):with({
        spacing = 0,
        style = {
            padding = {20, 8, 0, 8}
        }
    })

    local function prepareTitle(section)
        local title = section._title
        title:with({
            width = COLUMN_WIDTH,
            minWidth = COLUMN_WIDTH,
            maxWidth = COLUMN_WIDTH
        })

        return title
    end

    local titleRow = uiElements.row({
        prepareTitle(missingModsSection),
        prepareTitle(dependedOnSection),
        prepareTitle(uncategorizedSection)
    }):with({
        spacing = 0,
        style = {
            padding = {20, 8, 0, 8}
        }
    })

    local scrollableColumn = uiElements.scrollbox(columns)

    scrollableColumn:hook({
        calcWidth = function(orig, self)
            return self.inner.width
        end
    })
    scrollableColumn:with(uiUtils.fillHeight(true))

    local windowContent = uiElements.column({titleRow, scrollableColumn}):with({
        style = {
            spacing = 0
        }
    }):with(uiUtils.fillHeight(true))

    interactionData.sectionsColumn = columns
    interactionData.missingModsSection = missingModsSection
    interactionData.dependedOnSection = dependedOnSection
    interactionData.uncategorizedSection = uncategorizedSection
    interactionData.windowContentScrollable = scrollableColumn
    interactionData.windowContent = columns

    return windowContent, columns
end

local function addEverestDependency(metadata)
    local dependencies = metadata[1].Dependencies or {}
    local everestVersion = mods.getEverestVersion()

    if not everestVersion then
        return false
    end

    local everestDependency
    local everestCoreDependency

    -- Look for Everest or EverestCore
    -- Update version if missing or add Everest if both are missing

    for _, dependency in ipairs(dependencies) do
        if dependency.Name == mods.everestModName then
            everestDependency = dependency
        end

        if dependency.Name == mods.everestCoreName then
            everestCoreDependency = dependency
        end
    end

    if everestDependency and not everestDependency.Version then
        everestDependency.Version = everestVersion

        return true, dependencies
    end

    if everestCoreDependency and not everestCoreDependency.Version then
        everestCoreDependency.Version = everestVersion

        return true, dependencies
    end

    if not everestDependency and not everestCoreDependency then
        -- Add Everest as dependency if missing
        table.insert(dependencies, {
            Name = mods.everestModName,
            Version = everestVersion
        })

        return true, dependencies
    end

    return false, dependencies
end

local function createStartingEverestYaml(side, metadata)
    local modName = metadata._folderName or side.map.package

    local newMetadata = utils.deepcopy(metadata)
    local dependencies = {}

    newMetadata[1] = {
        Name = modName,
        Version = "0.0.1"
    }

    addEverestDependency(newMetadata)

    updateMetadataFile(newMetadata, dependencies)
end

local function showMissingEverestYamlNotification(language, filename, side, metadata)
    notifications.notify(function(popup)
        return uiElements.column({
            uiElements.label(tostring(language.ui.dependency_window.no_everest_yaml)),
            uiElements.row({
                uiElements.button(tostring(language.ui.button.yes), function()
                    createStartingEverestYaml(side, metadata)
                    dependencyWindow.editDependencies(filename, side)
                    popup:close()
                end),
                uiElements.button(tostring(language.ui.button.cancel), function()
                    popup:close()
                end),
            })
        })
    end, -1)
end

function dependencyWindow.editDependencies(filename, side)
    local language = languageRegistry.getLanguage()
    local modPath = mods.getFilenameModPath(filename)

    if not side then
        notifications.notify(tostring(language.ui.dependency_window.no_map_loaded))

        return
    end

    if not modPath then
        notifications.notify(tostring(language.ui.dependency_window.requires_packaged_mod))

        return
    end

    local currentModMetadata = mods.getModMetadataFromPath(modPath)

    -- Naive check if the metadata contains Everest.yaml data
    if not currentModMetadata or not currentModMetadata[1] then
        showMissingEverestYamlNotification(language, filename, side, currentModMetadata)

        return
    end

    -- Make sure Everest is in the metadata and has a version
    local changedMetadata, newDependencies = addEverestDependency(currentModMetadata)

    if changedMetadata then
        updateMetadataFile(currentModMetadata, newDependencies)
    end

    local window
    local interactionData = {
        filename = filename,
        modPath = modPath,
        side = side,
    }

    local layout = dependencyWindow.getWindowContent(modPath, side, interactionData)
    local windowTitle = tostring(language.ui.dependency_window.window_title)

    window = uiElements.window(windowTitle, layout)
    interactionData.window = window

    local windowCloseCallback = windowPersister.getWindowCloseCallback(windowPersisterName)

    windowPersister.trackWindow(windowPersisterName, window)
    dependencyWindowGroup.parent:addChild(window)
    widgetUtils.addWindowCloseButton(window, windowCloseCallback)
    widgetUtils.preventOutOfBoundsMovement(window)
    widgetUtils.consumeKeyboardEvents(window)
    window:with(widgetUtils.fillHeightIfNeeded())

    return window
end

-- Group to get access to the main group and sanely inject windows in it
function dependencyWindow.getWindow()
    dependencyEditor.dependencyWindow = dependencyWindow
    return dependencyWindowGroup
end

return dependencyWindow