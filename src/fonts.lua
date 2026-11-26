-- Text fonts used by the editor: the vanilla pico8 style font and an optional
-- hi-res pixel font.
--
-- The hi-res font has larger glyphs, so every size designed for the vanilla
-- font is multiplied by `font.pixelFactor` to keep the same visual size.
-- `font.fontScale` is the scale used by UI text and already includes it.

local font = {}

local DEFAULT_UI_FONT_PATH = "assets/fonts/NotoSansCJKsc-Bold.otf"

local cjkFontPath = DEFAULT_UI_FONT_PATH
local cjkFonts = {}
local labelFonts = {}
local screenFonts = {}
local fontPaths = {}
local fontPathFailures = {}

local function resolveFontPath(path)
    if path:match("^%a:[/\\]") or path:sub(1, 1) == "/" then
        return path
    end

    local source = love.filesystem.getSource()
    local successBase, baseDirectory = pcall(love.filesystem.getSourceBaseDirectory)

    -- Bundled assets and Fonts folders inside the source directory are read through
    -- love.filesystem. Custom fonts can also sit in a Fonts folder next to the executable,
    -- which is only reachable through the normal filesystem.
    if source and (love.filesystem.getInfo(path, "file") or not successBase or not baseDirectory) then
        return source .. "/" .. path
    end

    if successBase and baseDirectory then
        return baseDirectory .. "/" .. path
    end

    return path
end

local function loadFontFromPath(path, size, hinting)
    path = path and path:match("^%s*(.-)%s*$") or ""

    if path == "" or fontPathFailures[path] then
        return nil
    end

    local resolvedPath = resolveFontPath(path)
    local cacheKey = resolvedPath .. "|" .. tostring(size) .. "|" .. tostring(hinting or "normal")
    local cached = labelFonts[cacheKey]

    if cached then
        return cached
    end

    local data

    if not path:match("^%a:[/\\]") and path:sub(1, 1) ~= "/"
        and love.filesystem.getInfo(path, "file") then
        data = love.filesystem.read(path)

    else
        local file = io.open(resolvedPath, "rb")

        if not file then
            fontPathFailures[path] = true

            return nil
        end

        data = file:read("*a")
        file:close()
    end

    if not data then
        fontPathFailures[path] = true

        return nil
    end

    local ok, fileData = pcall(love.filesystem.newFileData, data, "trigger-font.ttf")

    if not ok then
        fontPathFailures[path] = true

        return nil
    end

    local fontOk, loadedFont = pcall(love.graphics.newFont, fileData, size, hinting or "normal", 1)

    if not fontOk then
        fontPathFailures[path] = true

        return nil
    end

    font.addCJKFallback(loadedFont, size)
    loadedFont:setFilter("linear", "linear")

    labelFonts[cacheKey] = loadedFont
    fontPaths[loadedFont] = path

    return loadedFont
end

function font.getScreenFont(size, sourceFont)
    size = math.max(1, math.floor(size + 0.5))

    local path = sourceFont and fontPaths[sourceFont]

    if path then
        local loaded = loadFontFromPath(path, size)

        if loaded then
            return loaded
        end
    end

    if not screenFonts[size] then
        screenFonts[size] = love.graphics.newFont(size)
        screenFonts[size]:setFilter("linear", "linear")
        font.addCJKFallback(screenFonts[size], size)
    end

    return screenFonts[size]
end

-- Smooth font used by the dynamic trigger/entity labels.
function font.getTriggerFont()
    local configs = require("configs")
    local loaded = loadFontFromPath(configs.font.triggerFontPath, 8)

    if loaded then
        return loaded
    end

    if not labelFonts["builtin|8"] then
        labelFonts["builtin|8"] = love.graphics.newFont(8)
        font.addCJKFallback(labelFonts["builtin|8"], 8)
    end

    return labelFonts["builtin|8"]
end

-- Chinese glyphs are not part of the pixel image fonts. Keep the themed/pixel font for Latin text
-- and let LÖVE fall back to a CJK font for the missing glyphs.
function font.getCJKFont(size)
    size = math.max(1, math.floor((size or 12) + 0.5))

    if not cjkFonts[size] then
        cjkFonts[size] = love.graphics.newFont(cjkFontPath, size)
    end

    return cjkFonts[size]
end

-- A high-resolution CJK font for small pieces of interface text such as the loading tips.
-- Uses a system UI font when available and falls back to the bundled pixel CJK font.
local loadingTipFontPaths = {
    -- Bundled OFL font. Keeps the loading tips identical on every OS and avoids relying on
    -- whichever Chinese UI font the system happens to ship.
    "assets/fonts/NotoSansCJKsc-Bold.otf",
    "C:/Windows/Fonts/msyhbd.ttc",
    "C:/Windows/Fonts/Dengb.ttf",
    "C:/Windows/Fonts/simhei.ttf",
    "C:/Windows/Fonts/msyh.ttc",
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
}

function font.getLoadingTipFont(size)
    for _, path in ipairs(loadingTipFontPaths) do
        local loaded = loadFontFromPath(path, size, "normal")

        if loaded then
            return loaded
        end
    end

    return font.getCJKFont(size)
end

-- Load an arbitrary UI font, including absolute system-font paths. Returns nil when the file
-- cannot be loaded so callers can fall back to the default font.
function font.loadUIFont(path, size)
    return loadFontFromPath(path, size, "normal")
end

function font.getDefaultUIFontPath()
    return DEFAULT_UI_FONT_PATH
end

function font.addCJKFallback(target, size)
    if not target then
        return
    end

    local ok, cjk = pcall(font.getCJKFont, size or target:getHeight())

    if ok and cjk then
        pcall(target.setFallbacks, target, cjk)
    end
end

local vanilla = {
    path = "fonts/pico8_font.png",
    glyphs = [=[abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"'`-_/1234567890!?[](){}.,;:<>+=%#^*~ ]=]
}

local hires = {
    path = "assets/fonts/hi-res_pixel_font.png",
    glyphs = [=[abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,!?-+/():;%&`'*#=[]"_{}<>^~ ]=]
}

local vanillaFont = love.graphics.newImageFont(vanilla.path, vanilla.glyphs, 1)
local hiresFont = love.graphics.newImageFont(hires.path, hires.glyphs, 1)

font.vanillaFont = vanillaFont
font.hiresFont = hiresFont

font.font = vanillaFont
font.fontString = vanilla.glyphs
font.fontScale = 4
font.pixelFactor = 1
font.useHires = false

font.addCJKFallback(vanillaFont, vanillaFont:getHeight())
font.addCJKFallback(hiresFont, hiresFont:getHeight())

font.font:setLineHeight(1.25)
hiresFont:setLineHeight(1.25)

local listeners = {}

function font.addOnChanged(listener)
    table.insert(listeners, listener)
end

local function notifyChanged()
    for _, listener in ipairs(listeners) do
        listener()
    end
end

-- Sizes designed for the vanilla font multiplied by this give the same visual
-- size with the current font
function font.size(size)
    return (size or 1) * font.pixelFactor
end

function font.setUseHires(useHires)
    useHires = useHires and true or false

    if font.useHires == useHires then
        return
    end

    font.useHires = useHires
    font.font = useHires and hiresFont or vanillaFont
    font.fontString = useHires and hires.glyphs or vanilla.glyphs

    -- The hi-res glyphs are 11px tall against the vanilla 5px ones, so half the
    -- scale gives the same visual size. Keeping it at exactly 0.5 also means
    -- room canvases can be rendered at exactly 2x and downscaled without
    -- resampling artifacts
    font.pixelFactor = useHires and 0.5 or 1
    font.fontScale = 4 * font.pixelFactor

    font.addCJKFallback(font.font, font.font:getHeight())
    love.graphics.setFont(font.font)

    notifyChanged()
end

-- Applies the font settings, taking the automatic zoom based switching into
-- account
function font.applyConfig(fontConfig)
    if fontConfig.autoSwitchFont then
        local success, viewportHandler = pcall(require, "viewport_handler")
        local scale = success and viewportHandler.viewport and viewportHandler.viewport.scale or 1

        font.setUseHires(scale > 1)

    else
        font.setUseHires(fontConfig.useHiresPixelFont)
    end
end

return font
