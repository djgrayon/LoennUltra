-- Tileset import for the project panel: copies the picked image into the mod and keeps the tile
-- XML of the current map in sync (framework block, optional vanilla definitions, new tileset).
--
-- The XML layout follows the Celeste mod conventions: <Data> root, the "z" framework block first,
-- then the optional vanilla definitions, then the tilesets of the mod itself.

local utils = require("utils")
local filesystem = require("utils.filesystem")
local loadedState = require("loaded_state")

local projectTilesets = {}

local templateFolder = "assets/tileset_templates/"
local frameworkId = "z"
local indent = "  "

local function makeSet(list)
    local set = {}

    for _, value in ipairs(list) do
        set[value] = true
    end

    return set
end

local vanillaForegroundIds = makeSet({
    "1", "3", "4", "5", "6", "7", "8", "9",
    "a", "b", "c", "d", "e", "f", "g", "G",
    "h", "i", "j", "k", "l", "m", "n"
})

local vanillaBackgroundIds = makeSet({
    "1", "2", "3", "4", "5", "6", "7", "8", "9",
    "a", "b", "c", "d", "e"
})

local vanillaMarkers = {
    tilesFg = 'path="woodStoneEdges"',
    tilesBg = 'path="bgBrickRuined"'
}

local templateNames = {"vanilla", "better", "spooooky"}
local templateCache = {}

function projectTilesets.getTemplateNames()
    return templateNames
end

function projectTilesets.getTemplate(name)
    if templateCache[name] ~= nil then
        return templateCache[name] or nil
    end

    local text = utils.readAll(templateFolder .. name .. ".xml", "rb", true)

    templateCache[name] = text or false

    return text
end

local function getPair(project)
    if project.collabType == "standalone" then
        return project.authorName, project.modName
    end

    return project.modName, project.authorName
end

local function getXmlName(layer)
    return layer == "tilesBg" and "BackgroundTiles.xml" or "ForegroundTiles.xml"
end

local function getVanillaSet(layer)
    if layer == "tilesBg" then
        return vanillaBackgroundIds
    end

    return vanillaForegroundIds
end

-- Target XML of the current map: the metadata decides, the author/mod folder is the fallback
function projectTilesets.getXmlPath(project, layer)
    local meta = loadedState.side and loadedState.side.meta
    local configured = meta and meta[layer == "tilesBg" and "BackgroundTiles" or "ForegroundTiles"]

    if type(configured) == "string" then
        configured = string.gsub(configured, "%c", "")
        configured = string.match(configured, "^(.-%.xml)") or configured
    end

    if configured and configured ~= "" then
        return utils.joinpath(project.modFolder, filesystem.convertToUnixPath(configured))
    end

    local outer, inner = getPair(project)

    return utils.joinpath(project.modFolder, "Graphics", outer, inner, getXmlName(layer))
end

function projectTilesets.getImageFolder(project)
    local outer, inner = getPair(project)

    return utils.joinpath(project.modFolder, "Graphics", "Atlases", "Gameplay", "tilesets", outer, inner)
end

-- Value of the XML path attribute, relative to Graphics/Atlases/Gameplay/tilesets
function projectTilesets.getAssetPath(project, fileNameBase)
    local outer, inner = getPair(project)

    return string.format("%s/%s/%s", outer, inner, fileNameBase)
end

local function readXml(path)
    if not filesystem.pathAttributes(path) then
        return nil
    end

    local text = utils.readAll(path, "rb", false)

    if not text then
        return nil
    end

    -- Strip a UTF-8 BOM so the patterns below see the root element first
    if string.sub(text, 1, 3) == "\239\187\191" then
        text = string.sub(text, 4)
    end

    return text
end

local function writeXml(path, text, withBom)
    filesystem.mkpath(filesystem.dirname(path))

    local handle = utils.getFileHandle(path, "wb")

    if not handle then
        return false
    end

    if withBom then
        handle:write("\239\187\191")
    end

    handle:write(text)
    handle:close()

    return true
end

local function getIds(text)
    local ids = {}

    if not text then
        return ids
    end

    for tag in string.gmatch(text, "<[Tt][Ii][Ll][Ee][Ss][Ee][Tt]%s[^>]*>") do
        local id = string.match(tag, '[Ii][Dd]%s*=%s*"([^"]*)"')

        if id then
            ids[id] = true
        end
    end

    return ids
end

local function hasVanilla(text, layer)
    if not text then
        return false
    end

    return string.find(text, vanillaMarkers[layer] or vanillaMarkers.tilesFg, 1, true) ~= nil
end

function projectTilesets.hasVanilla(text, layer)
    return hasVanilla(text, layer)
end

-- "empty", "template", "vanilla", "used", "other" or "free"
function projectTilesets.getState(project, layer, id, useVanilla)
    id = string.gsub(tostring(id or ""), "^%s+", "")
    id = string.gsub(id, "%s+$", "")

    if id == "" then
        return "empty"
    end

    if id == frameworkId then
        return "template"
    end

    local targetText = readXml(projectTilesets.getXmlPath(project, layer))
    local vanilla = getVanillaSet(layer)

    if vanilla[id] and (useVanilla or hasVanilla(targetText, layer)) then
        return "vanilla"
    end

    if getIds(targetText)[id] then
        return "used"
    end

    local otherLayer = layer == "tilesBg" and "tilesFg" or "tilesBg"

    if getIds(readXml(projectTilesets.getXmlPath(project, otherLayer)))[id] then
        return "other"
    end

    return "free"
end

local function escapeAttribute(value)
    return (string.gsub(tostring(value), "[&<\">]", {
        ["&"] = "&amp;",
        ["<"] = "&lt;",
        [">"] = "&gt;",
        ['"'] = "&quot;"
    }))
end

local function buildBlock(templateName, id, assetPath)
    local template = projectTilesets.getTemplate(templateName)

    if not template then
        return nil
    end

    local escapedPath = escapeAttribute(assetPath)

    template = string.gsub(template, "{ID}", function() return escapeAttribute(id) end)
    template = string.gsub(template, 'path="{PATH}"', function()
        return string.format('path="%s"', escapedPath)
    end)

    return string.gsub(template, "{PATH}", function() return escapedPath end)
end

local function getNewLine(text)
    if string.find(text, "\r\n", 1, true) then
        return "\r\n"
    end

    return "\n"
end

-- Inserts the framework block right below <Data> when the file does not have it yet
local function ensureFramework(text, newLine)
    if string.find(text, frameworkId, 1, true)
        and string.find(string.lower(text), 'id%s*=%s*"' .. frameworkId .. '"') then
        return text
    end

    local openStart, openEnd = string.find(text, "<[Dd][Aa][Tt][Aa]%s*>")

    if not openStart then
        return text
    end

    local framework = projectTilesets.getTemplate("framework")

    if not framework then
        return text
    end

    local body = framework:gsub("\r\n", "\n"):gsub("%s+$", "")

    local block = {}

    for line in string.gmatch(body .. "\n", "([^\n]*)\n") do
        table.insert(block, indent .. line .. newLine)
    end

    return string.sub(text, 1, openEnd) .. newLine .. table.concat(block) .. string.sub(text, openEnd + 1)
end

-- Inserts the vanilla definitions right after the framework block
local function ensureVanilla(text, layer, newLine)
    if hasVanilla(text, layer) then
        return text
    end

    local vanilla = projectTilesets.getTemplate(layer == "tilesBg" and "vanilla_background" or "vanilla_foreground")

    if not vanilla then
        return text
    end

    local body = vanilla:gsub("\r\n", "\n"):gsub("%s+$", "")
    local block = {}

    for line in string.gmatch(body .. "\n", "([^\n]*)\n") do
        table.insert(block, indent .. line .. newLine)
    end

    -- Right after the closing tag of the framework block
    local startIndex = string.find(text, 'id%s*=%s*"' .. frameworkId .. '"')

    if not startIndex then
        return text
    end

    local closeIndex = string.find(text, "</Tileset>", startIndex, true)

    if not closeIndex then
        return text
    end

    local insertAt = closeIndex + #"</Tileset>"

    return string.sub(text, 1, insertAt) .. newLine .. table.concat(block) .. string.sub(text, insertAt + 1)
end

-- Position of the last </Data>, indented by the surrounding whitespace
local function getInsertPosition(text)
    local lowered = string.lower(text)
    local closeIndex = string.find(lowered, "</data>", 1, true)

    if not closeIndex then
        return nil
    end

    -- Last occurrence
    local searchFrom = closeIndex

    while true do
        local nextIndex = string.find(lowered, "</data>", searchFrom + 1, true)

        if not nextIndex then
            break
        end

        closeIndex = nextIndex
        searchFrom = nextIndex
    end

    local lineStart = closeIndex

    while lineStart > 1 and string.sub(text, lineStart - 1, lineStart - 1) ~= "\n" do
        lineStart = lineStart - 1
    end

    local before = string.sub(text, lineStart, closeIndex - 1)

    if string.gsub(before, "%s", "") ~= "" then
        return closeIndex, ""
    end

    return lineStart, before .. indent
end

local function createDocument(block, vanillaBlock, newLine)
    local parts = {"<Data>", newLine}

    local function addBlock(text)
        local body = text:gsub("\r\n", "\n"):gsub("%s+$", "")

        for line in string.gmatch(body .. "\n", "([^\n]*)\n") do
            table.insert(parts, indent .. line .. newLine)
        end
    end

    addBlock(projectTilesets.getTemplate("framework") or "")

    if vanillaBlock then
        addBlock(vanillaBlock)
    end

    addBlock(block)

    table.insert(parts, "</Data>" .. newLine)

    return table.concat(parts)
end

-- Copies the picked image into the tileset folder, converting it to PNG when needed
local function copyImage(source, target)
    local extension = string.lower(filesystem.fileExtension(source))
    local bytes

    if extension == "png" then
        bytes = utils.readAll(source, "rb", false)

    else
        local success, fileData = pcall(function()
            local raw = utils.readAll(source, "rb", false)

            if not raw then
                return nil
            end

            return love.filesystem.newFileData(raw, "import." .. extension)
        end)

        if not success or not fileData then
            return false, "image"
        end

        local decoded, imageData = pcall(love.image.newImageData, fileData)

        if not decoded or not imageData then
            return false, "image"
        end

        local encoded, encodedData = pcall(function()
            return imageData:encode("png")
        end)

        if not encoded or not encodedData then
            return false, "encode"
        end

        bytes = encodedData:getString()
    end

    if not bytes then
        return false, "read"
    end

    filesystem.mkpath(filesystem.dirname(target))

    local handle = utils.getFileHandle(target, "wb")

    if not handle then
        return false, "write"
    end

    handle:write(bytes)
    handle:close()

    return true
end

-- opts: sourceImage, fileName (no extension), id, template, layer, useVanilla
function projectTilesets.import(project, opts)
    local layer = opts.layer or "tilesFg"
    local id = utils.trim(tostring(opts.id or ""))
    local fileName = utils.trim(tostring(opts.fileName or ""))
    local templateName = opts.template or "vanilla"

    if fileName == "" or string.find(fileName, "[/\\]") then
        return false, "fileName"
    end

    local state = projectTilesets.getState(project, layer, id, opts.useVanilla)

    if state ~= "free" and state ~= "other" then
        return false, state
    end

    local assetPath = projectTilesets.getAssetPath(project, fileName)
    local targetImage = utils.joinpath(projectTilesets.getImageFolder(project), fileName .. ".png")
    local copied, copyReason = copyImage(opts.sourceImage, targetImage)

    if not copied then
        return false, copyReason or "image"
    end

    local block = buildBlock(templateName, id, assetPath)

    if not block then
        return false, "template"
    end

    local xmlPath = projectTilesets.getXmlPath(project, layer)
    local existing = readXml(xmlPath)
    local withBom = false
    local text

    if existing then
        local newLine = getNewLine(existing)
        text = ensureFramework(existing, newLine)

        if opts.useVanilla then
            text = ensureVanilla(text, layer, newLine)
        end

        local insertAt, blockIndent = getInsertPosition(text)

        if not insertAt then
            return false, "root"
        end

        local parts = {}

        for line in string.gmatch(block:gsub("\r\n", "\n"):gsub("%s+$", "") .. "\n", "([^\n]*)\n") do
            table.insert(parts, blockIndent .. line .. newLine)
        end

        text = string.sub(text, 1, insertAt - 1) .. table.concat(parts) .. string.sub(text, insertAt)

        -- Keep the BOM state of the existing file
        local raw = utils.readAll(xmlPath, "rb", false)
        withBom = raw ~= nil and string.sub(raw, 1, 3) == "\239\187\191"

    else
        local vanillaBlock = opts.useVanilla
            and projectTilesets.getTemplate(layer == "tilesBg" and "vanilla_background" or "vanilla_foreground")
            or nil

        text = '<?xml version="1.0" encoding="utf-8"?>' .. "\n" .. createDocument(block, vanillaBlock, "\n")
    end

    if not writeXml(xmlPath, text, withBom) then
        return false, "write"
    end

    return true, xmlPath
end

return projectTilesets
