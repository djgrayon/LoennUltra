local utils = require("utils")
local version = require("utils.version_parser")

local meta = {}

meta.title = utils.readAll("assets/TITLE", "rb", true)

-- The real version of this build, shown in the about window, the error page and the updater.
meta.displayVersion = version(utils.readAll("assets/VERSION", "rb", true))

-- The version reported to plugins. Kept aligned with upstream Loenn so that plugins written
-- against 1.0.x still pass their own version gates. This is NOT the real version of this build.
meta.version = version("1.0.13")

return meta
