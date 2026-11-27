-- love.load() is not called again, put stuff here.

local launchArguments = require("launch_arguments")

-- Set up launch argument parsing
launchArguments.updateArguments(arg)

local meta = require("meta")
local utils = require("utils")
local logging = require("logging")

love.keyboard.setKeyRepeat(true)

love.graphics.setDefaultFilter("nearest", "nearest", 1)
love.graphics.setBackgroundColor(0.1, 0.1, 0.1)

local fonts = require("fonts")
love.graphics.setFont(fonts.font)

local sceneHandler = require("scene_handler")
local threadHandler = require("utils.threads")

local tasks = require("utils.tasks")

-- Restore the maximized state after the window exists. conf.lua restores the windowed size and
-- position, but LÖVE has no portable conf flag for "maximized".
local configs = require("configs")
local persistence = require("persistence")

if configs.general.persistWindowSize and persistence.windowMaximized and not love.window.getFullscreen() then
    pcall(love.window.maximize)
end

local function getInstallInformation()
    local major, minor, revision, codename = love.getVersion()
    local installInfoLines = {
        string.format("Editor version: %s", meta.displayVersion),
        string.format("Love2d version: %d.%d.%d - %s", major, minor, revision, codename),
        string.format("Operating system: %s", utils.getOS()),
        string.format("Runtime arch: %s (luajit %s, jit %s)", tostring(jit and jit.arch), tostring(jit and jit.version), tostring(jit and jit.status()))
    }

    local installInfo = table.concat(installInfoLines, "\n")

    return installInfo
end

-- Show install information in log to help debug user issues
logging.log(nil, getInstallInformation(), nil, true)

require("lib.love_filesystem_unsandboxing")
require("input_handler")

-- Resolve shared mod paths ("@ModsCommon@/...") through virtual_fs; has to be
-- installed before any plugin code is loaded
require("virtual_fs").install()

sceneHandler.loadInternalScenes()
sceneHandler.changeScene("Startup")

function love.draw()
    sceneHandler.draw()
end

function love.update(dt)
    tasks.processTasks(1 / 32)

    sceneHandler.update(dt)
    threadHandler.update(dt)
    logging.update(dt)
end

local originalErrorHandler = love.errorhandler or love.errhand

function love.errorhandler(message)
    local installInfo = getInstallInformation()
    local errorMessage = string.format("%s\n\n%s", installInfo, message)

    logging.error(debug.traceback(errorMessage))

    return originalErrorHandler(errorMessage)
end