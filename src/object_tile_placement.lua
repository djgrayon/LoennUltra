-- Brush layer for Celeste's objtiles ("Objects" in Ahorn). These are individual tiles taken
-- from the shared tilesets/scenery atlas, not autotiled terrain.
local scenery = require("scenery")
local objectTilesStruct = require("structs.object_tiles")
local matrix = require("utils.matrix")

local objectTilePlacement = {}

local function ensureObjectTiles(room)
    local tiles = room.sceneryObj

    if not tiles then
        tiles = objectTilesStruct.fromMatrix(matrix.filled(-1, math.ceil(room.width / 8), math.ceil(room.height / 8)))
        room.sceneryObj = tiles

    else
        local width, height = tiles.matrix:size()
        local targetWidth = math.ceil(room.width / 8)
        local targetHeight = math.ceil(room.height / 8)

        if width ~= targetWidth or height ~= targetHeight then
            tiles.matrix = objectTilesStruct.resize(tiles, targetWidth, targetHeight).matrix
        end
    end

    return tiles
end

function objectTilePlacement.ensureRoom(room)
    return ensureObjectTiles(room)
end

function objectTilePlacement.getMaterialLookup()
    local lookup = scenery.getMaterialLookup(false) or {}
    lookup["Air"] = -1

    return lookup
end

function objectTilePlacement.getValidTiles()
    local lookup = objectTilePlacement.getMaterialLookup()
    local valid = {}

    for _, tile in pairs(lookup) do
        valid[tostring(tile)] = true
    end

    return valid
end

function objectTilePlacement.getRoomItems(room)
    return room.sceneryObj
end

function objectTilePlacement.placeTile(room, x, y, material)
    return objectTilePlacement.placeItem(room, "sceneryObj", {
        tile = tonumber(material) or -1,
        x = (x - 1) * 8,
        y = (y - 1) * 8
    })
end

function objectTilePlacement.getTile(room, x, y)
    local tiles = room.sceneryObj

    if not tiles then
        return "-1"
    end

    return tostring(tiles.matrix:get(x, y, -1))
end

function objectTilePlacement.placeItem(room, layer, item)
    local tiles = ensureObjectTiles(room)
    local x = math.floor((item.x or 0) / 8) + 1
    local y = math.floor((item.y or 0) / 8) + 1

    if tiles.matrix:inbounds(x, y) then
        tiles.matrix:set(x, y, tonumber(item.tile) or -1)

        return true
    end

    return false
end

return objectTilePlacement
