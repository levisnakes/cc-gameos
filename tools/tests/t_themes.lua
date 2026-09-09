-- Renders the launcher in every palette theme, and exercises the settings,
-- scores and about screens plus the game-over card.
local req = require_gameos
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local input = req("lib.input")
local audio = req("lib.audio")
local data = req("lib.data")
local ui = req("lib.ui")
local runtime = req("lib.runtime")

check(gfx.init(), "gfx.init")
data.load()
audio.init()

-- Discovered from the disk image the same way boot.lua does it, rather than
-- listed by hand: a hardcoded list goes stale the moment a game is added or
-- removed, and then fails here for a reason that has nothing to do with themes.
local games = {}
for _, file in ipairs(fs.list("/gameos/games")) do
  if file:sub(-4) == ".lua" then
    local id = file:sub(1, #file - 4)
    local def = req("games." .. id)
    def.id = def.id or id
    games[#games + 1] = def
  end
end
check(#games >= 10, "found the games on disk (" .. #games .. ")")
table.sort(games, function(a, b) return (a.order or 50) < (b.order or 50) end)

local api = {
  version = "1.0.0", gfx = gfx, canvas = Canvas, font = font,
  input = input, audio = audio, data = data, ui = ui, runtime = runtime,
  games = games, broken = {}, require = req,
}

-- give the score screen something to show
data.submit("tetris", 18400)
data.submit("tetris", 9200)
data.submit("snake", 640)
data.recordPlay("tetris", 812)
data.recordPlay("snake", 143)

--------------------------------------------------------------- launcher art
-- Drive the real shell for a few frames per theme, then screenshot.
local shell = req("os.shell")

for themeIndex = 1, #gfx.themes do
  gfx.applyTheme(themeIndex)
  local frames = 0
  local done = false
  AUTO = function()
    frames = frames + 1
    if frames == 3 then SHOT("shell-" .. gfx.themes[themeIndex].id) end
    if frames == 4 then MOCK.push("key", keys.down, false) end
    if frames == 7 then SHOT("shell-" .. gfx.themes[themeIndex].id .. "-2") end
    if frames >= 9 and not done then
      done = true
      MOCK.push("terminate")
    end
  end
  local ok, err = pcall(shell.run, api)
  check(ok, "shell ran under theme " .. gfx.themes[themeIndex].name .. ": " .. tostring(err))
  ui.terminated = false
end

gfx.applyTheme(1)
AUTO = nil

------------------------------------------------------------- system screens
local function screenshotScreen(name, fn)
  local frames = 0
  AUTO = function()
    frames = frames + 1
    if frames == 2 then SHOT(name) end
    if frames >= 4 then MOCK.push("key", keys.q, false) end
  end
  local ok, err = pcall(fn, api)
  AUTO = nil
  check(ok, name .. " screen: " .. tostring(err))
  ui.terminated = false
end

screenshotScreen("settings", function(a) req("os.settings").run(a) end)
screenshotScreen("soundtest", function(a) req("os.soundtest").run(a) end)
screenshotScreen("scores", function(a) req("os.scores").run(a) end)
screenshotScreen("about", function(a) req("os.about").run(a) end)

----------------------------------------------------------- game over card
do
  -- Play Snake for real: with no input it runs straight into the wall, so
  -- the runtime's death handling and game-over card get exercised end to end.
  local def = req("games.snake")
  data.progress("snake").seenControls = nil
  local frames = 0
  local shot = false
  AUTO = function()
    frames = frames + 1
    if frames == 3 then MOCK.push("key", keys.enter, false) end     -- Classic
    if frames == 6 then MOCK.push("key", keys.space, false) end     -- controls
    if frames == 130 then
      SHOT("game-over")
      shot = true
    end
    if frames == 136 then MOCK.push("key", keys.q, false) end       -- Menu
    if frames > 200 then error("HARNESS_DONE", 0) end
  end
  local ok = pcall(runtime.play, def, api)
  AUTO = nil
  check(ok, "runtime played a full snake session")
  check(shot, "captured the game-over card")
  ui.terminated = false
end

------------------------------------------------------------------ dialogs
do
  local frames = 0
  AUTO = function()
    frames = frames + 1
    if frames == 2 then SHOT("dialog") end
    if frames >= 4 then MOCK.push("key", keys.enter, false) end
  end
  gfx.beginFrame()
  gfx.clear(colors.black)
  gfx.endFrame()
  ui.confirm(" Power Off ", "Leave GameOS?", "Power off", "Stay")
  AUTO = nil
end

gfx.shutdown()
finish("themes")
