-- Captures the boot animation at several points.
local req = require_gameos
local gfx = req("lib.gfx")
local audio = req("lib.audio")
local data = req("lib.data")

check(gfx.init(), "gfx.init")
data.load()
audio.init()

local frames = 0
AUTO = function()
  frames = frames + 1
  if frames == 8 then SHOT("splash-wipe") end
  if frames == 22 then SHOT("splash-logo") end
  if frames == 36 then SHOT("splash-loading") end
end

local ok, err = pcall(req("os.splash").run, { version = "1.0.0" })
check(ok, "splash ran: " .. tostring(err))
LOG("  splash ran for " .. frames .. " frames")
check(frames > 30, "splash animated for its full duration")

gfx.shutdown()
finish("splash")
