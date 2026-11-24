local ui = require("ui")
local uiElements = require("ui.elements")
local uiUtils = require("ui.utils")

local utils = require("utils")
local widgetUtils = require("ui.widgets.utils")
local form = require("ui.forms.form")
local github = require("utils.github")
local meta = require("meta")

local aboutWindowWrapper = require("ui.about_window_wrapper")

local windowPersister = require("ui.window_position_persister")
local windowPersisterName = "about_window"

local aboutWindow = {}

local aboutWindowGroup = uiElements.group({})

-- The About content is intentionally fixed to Chinese. Edit this table to add credits without
-- changing every language file.
local aboutText = {
    title = "关于",
    readme = "打开 README",
    description = "Celeste 的关卡编辑器\n由 LÖVE 和 Lua 驱动。",
    credits = "作者：Cruor、Vexatos、Lucky_boy（Deepseek）\n特别鸣谢：所有的 Loenn 插件作者、Myn_Gen、格莱西亚、Black_Ice、zzm、rifs、BadwayBear、川蓝、OldmanG\n汉化支持：Myn_Gen、v_t恨\n背景预览图支持：Myn_Gen",
    version = "编辑器版本：%s"
}

local function openReadmeUrl()
    local url = github.getRepositoryReadmeUrl("djgrayon", "LoennUltra")

    love.system.openURL(url)
end

local noPaddingSpacing = {
    style = {
        spacing = 8,
        padding = 8
    }
}

function aboutWindow.showAboutWindow()
    local windowTitle = aboutText.title
    local readmeText = aboutText.readme
    local description = aboutText.description
    local credits = aboutText.credits
    local versionText = string.format(aboutText.version, meta.version)

    local logoScaleX = 0.5
    local logoScaleY = 0.5
    local logoImage = love.graphics.newImage("assets/logo-256.png")
    local logoElement = uiElements.image(logoImage):with({
        scaleX = logoScaleX,
        scaleY = logoScaleY
    })
    local logoWidth = logoImage:getWidth() * logoScaleX
    local logoContainer = uiElements.group({logoElement})

    local readmeButton = uiElements.button(readmeText, openReadmeUrl)

    local windowContent = uiElements.column({
        logoContainer,
        uiElements.label(versionText),
        uiElements.label(description),
        uiElements.label(credits),
        readmeButton
    }):with({
        style = {
            spacing = 8,
            padding = 8
        }
    })

    local window = uiElements.window(windowTitle, windowContent)
    local windowCloseCallback = windowPersister.getWindowCloseCallback(windowPersisterName)

    windowContent:layout()

    local logoOffsetX = math.floor((windowContent.innerWidth - logoWidth) / 2)

    logoContainer:with(uiUtils.fillWidth(false))
    readmeButton:with(uiUtils.fillWidth(false))
    logoElement:with(uiUtils.at(logoOffsetX, 0), logoContainer.style.padding)

    windowPersister.trackWindow(windowPersisterName, window)
    aboutWindowGroup.parent:addChild(window)
    widgetUtils.addWindowCloseButton(window, windowCloseCallback)
    widgetUtils.preventOutOfBoundsMovement(window)
    widgetUtils.consumeKeyboardEvents(window)
    form.prepareScrollableWindow(window)

    return window
end

-- Group to get access to the main group and sanely inject windows in it
function aboutWindow.getWindow()
    aboutWindowWrapper.aboutWindow = aboutWindow

    return aboutWindowGroup
end

return aboutWindow