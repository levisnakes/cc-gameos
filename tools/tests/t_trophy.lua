-- Covers the two paths a normal session does not reach: the trophies screen
-- and the arcade initials entry that only a new number one triggers.
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

-- Discovered from disk rather than listed here, so adding or removing a game
-- cannot leave this test referring to something that no longer exists.
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

------------------------------------------------------------- trophy storage
do
  data.state.trophies = {}
  check(not data.hasTrophy("snake_25"), "unearned trophy reads as missing")
  check(data.awardTrophy("snake_25"), "first award succeeds")
  check(not data.awardTrophy("snake_25"), "the same trophy is not awarded twice")
  check(data.hasTrophy("snake_25"), "an awarded trophy sticks")
  eq(data.trophyCount(), 1, "trophy count tracks awards")
end

------------------------------------------------- every trophy id is unique
do
  local seen = {}
  local dupes = 0
  local total = 0
  for _, def in ipairs(games) do
    for _, t in ipairs(def.trophies or {}) do
      total = total + 1
      if seen[t.id] then
        dupes = dupes + 1
        LOG("  duplicate trophy id: " .. t.id)
      end
      seen[t.id] = true
      check(type(t.name) == "string" and #t.name > 0, "trophy has a name: " .. t.id)
      check(type(t.desc) == "string" and #t.desc > 0, "trophy has a description: " .. t.id)
      check(type(t.test) == "function", "trophy has a test: " .. t.id)
      -- the trophies screen gives names 15 cells and descriptions 28
      check(#t.name <= 15, "trophy name fits the screen: " .. t.name)
      check(#t.desc <= 28, "trophy description fits the screen: " .. t.desc)
    end
  end
  for _, t in ipairs(runtime.globalTrophies) do
    total = total + 1
    check(not seen[t.id], "global trophy id is unique: " .. t.id)
    seen[t.id] = true
  end
  eq(dupes, 0, "no duplicate trophy ids")
  LOG("  " .. total .. " trophies defined across " .. #games .. " games")
  check(total >= 40, "a decent number of trophies")
end

------------------------------------- every trophy test survives a fresh game
do
  local failures = 0
  for _, def in ipairs(games) do
    local inst = def.new(api, def.modes and def.modes[1])
    for _, t in ipairs(def.trophies or {}) do
      local ok, err = pcall(t.test, inst)
      if not ok then
        failures = failures + 1
        LOG("  " .. t.id .. " errored: " .. tostring(err))
      end
    end
  end
  eq(failures, 0, "no trophy test errors on a freshly started game")
end

--------------------------------------------------------------- trophy screen
do
  -- award a scattering so the screen shows both states
  data.state.trophies = {}
  data.awardTrophy("snake_25")
  data.awardTrophy("tetris_four")
  data.awardTrophy("ms_win")
  data.awardTrophy("os_collector")

  local frames = 0
  AUTO = function()
    frames = frames + 1
    if frames == 2 then SHOT("trophies-top") end
    if frames == 4 then MOCK.push("key", keys.pageDown, false) end
    if frames == 7 then SHOT("trophies-scrolled") end
    if frames >= 9 then MOCK.push("key", keys.q, false) end
  end
  local ok, err = pcall(req("os.trophies").run, api)
  AUTO = nil
  check(ok, "trophies screen ran: " .. tostring(err))
end

------------------------------------------------------------ initials entry
do
  local frames = 0
  AUTO = function()
    frames = frames + 1
    if frames == 2 then SHOT("initials") end
    if frames == 3 then MOCK.push("char", "a") end
    if frames == 4 then MOCK.push("char", "c") end
    if frames == 5 then MOCK.push("key", keys.up, false) end
    if frames >= 7 then MOCK.push("key", keys.enter, false) end
  end
  gfx.beginFrame()
  gfx.clear(colors.black)
  gfx.endFrame()
  local ok, who = pcall(ui.initials, " Tetris ", colors.cyan, nil)
  AUTO = nil
  check(ok, "initials dialog ran: " .. tostring(who))
  if ok then
    eq(#who, 3, "initials are three characters")
    eq(who:sub(1, 2), "AC", "typed letters land in the right slots")
    LOG("  initials entered: " .. who)
  end
end

--------------------------------------------------- initials reach the table
do
  data.state.scores["_init"] = nil
  data.submit("_init", 500)
  data.nameScore("_init", 1, "ZZZ")
  eq(data.scores("_init")[1].who, "ZZZ", "initials are stored with the score")
  data.state.scores["_init"] = nil
end

gfx.shutdown()
finish("trophy")
