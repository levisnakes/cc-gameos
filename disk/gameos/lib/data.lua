--[[ data -- settings, high score tables, per-game progress and play stats.

  Everything lives in one serialised table at /gameos/data/save.dat. Writes
  are best-effort: a read-only or full disk degrades to an in-memory session
  rather than crashing the console.
]]

local data = {}

local DIR = "/gameos/data"
local PATH = DIR .. "/save.dat"
local MAX_SCORES = 5

local DEFAULT_SETTINGS = {
  theme = "midnight",
  -- three independent knobs, 0..10
  volMaster = 7,
  volMusic = 6,
  volSfx = 10,
  showFps = false,
  confirmExit = true,
}

data.state = nil
data.dirty = false
data.writable = true

local function freshState()
  local s = {
    version = 1, settings = {}, scores = {}, stats = {},
    progress = {}, trophies = {},
  }
  for k, v in pairs(DEFAULT_SETTINGS) do s.settings[k] = v end
  return s
end

function data.load()
  local state = freshState()
  if fs.exists(PATH) then
    local handle = fs.open(PATH, "r")
    if handle then
      local raw = handle.readAll()
      handle.close()
      local ok, parsed = pcall(textutils.unserialize, raw)
      if ok and type(parsed) == "table" then
        if type(parsed.settings) == "table" then
          for k, v in pairs(parsed.settings) do
            if DEFAULT_SETTINGS[k] ~= nil and type(v) == type(DEFAULT_SETTINGS[k]) then
              state.settings[k] = v
            end
          end
        end
        if type(parsed.scores) == "table" then state.scores = parsed.scores end
        if type(parsed.stats) == "table" then state.stats = parsed.stats end
        if type(parsed.progress) == "table" then state.progress = parsed.progress end
        if type(parsed.trophies) == "table" then state.trophies = parsed.trophies end
      end
    end
  end
  data.state = state
  return state
end

function data.save()
  if not data.state then return false end
  local ok = pcall(function()
    if not fs.exists(DIR) then fs.makeDir(DIR) end
    local handle = fs.open(PATH, "w")
    if not handle then error("cannot open", 0) end
    handle.write(textutils.serialize(data.state))
    handle.close()
  end)
  data.writable = ok
  if ok then data.dirty = false end
  return ok
end

--- Persist only if something asked for it, so menus can call this freely.
function data.flush()
  if data.dirty then return data.save() end
  return true
end

------------------------------------------------------------------- settings
function data.get(key)
  local v = data.state.settings[key]
  if v == nil then return DEFAULT_SETTINGS[key] end
  return v
end

function data.set(key, value)
  data.state.settings[key] = value
  data.dirty = true
end

function data.defaults() return DEFAULT_SETTINGS end

---------------------------------------------------------------- high scores
--- Ordered best-first list of { score = n, when = "d123" }.
function data.scores(gameId)
  local list = data.state.scores[gameId]
  if type(list) ~= "table" then
    list = {}
    data.state.scores[gameId] = list
  end
  return list
end

function data.best(gameId)
  local list = data.scores(gameId)
  return list[1] and list[1].score or 0
end

--- Attach initials to the score sitting at a rank (used after the arcade
--- style name entry that only a new number one triggers).
function data.nameScore(gameId, rank, who)
  local entry = data.scores(gameId)[rank]
  if entry then
    entry.who = who
    data.dirty = true
  end
end

--- Insert a score. Returns its 1-based rank, or nil if it did not place.
function data.submit(gameId, score, lowerIsBetter)
  if type(score) ~= "number" then return nil end
  score = math.floor(score)
  local list = data.scores(gameId)
  local pos = #list + 1
  for i = 1, #list do
    -- written out rather than "cond and a or b": when lowerIsBetter is true
    -- and the comparison is false, that idiom falls through to the wrong test
    local better
    if lowerIsBetter then
      better = score < list[i].score
    else
      better = score > list[i].score
    end
    if better then pos = i break end
  end
  if pos > MAX_SCORES then return nil end
  table.insert(list, pos, { score = score, day = os.day() })
  while #list > MAX_SCORES do table.remove(list) end
  data.dirty = true
  return pos
end

------------------------------------------------------------------- trophies
--- Trophies are stored as id -> the in-game day they were earned.
function data.hasTrophy(id)
  return data.state.trophies[id] ~= nil
end

--- Returns true only the first time a trophy is earned.
function data.awardTrophy(id)
  if data.state.trophies[id] ~= nil then return false end
  data.state.trophies[id] = os.day()
  data.dirty = true
  return true
end

function data.trophyCount()
  local n = 0
  for _ in pairs(data.state.trophies) do n = n + 1 end
  return n
end

------------------------------------------------------------------- progress
--- Free-form per-game persistent table (level unlocks, best move counts...).
function data.progress(gameId)
  local p = data.state.progress[gameId]
  if type(p) ~= "table" then
    p = {}
    data.state.progress[gameId] = p
  end
  return p
end

function data.markDirty() data.dirty = true end

---------------------------------------------------------------------- stats
function data.stats(gameId)
  local s = data.state.stats[gameId]
  if type(s) ~= "table" then
    s = { plays = 0, seconds = 0 }
    data.state.stats[gameId] = s
  end
  if type(s.plays) ~= "number" then s.plays = 0 end
  if type(s.seconds) ~= "number" then s.seconds = 0 end
  return s
end

function data.recordPlay(gameId, seconds)
  local s = data.stats(gameId)
  s.plays = s.plays + 1
  s.seconds = math.floor(s.seconds + (seconds or 0))
  data.dirty = true
end

function data.totalPlays()
  local n = 0
  for _, s in pairs(data.state.stats) do n = n + (s.plays or 0) end
  return n
end

function data.totalSeconds()
  local n = 0
  for _, s in pairs(data.state.stats) do n = n + (s.seconds or 0) end
  return n
end

--- "1h 04m" / "37s"
function data.formatDuration(seconds)
  seconds = math.floor(seconds or 0)
  if seconds < 60 then return seconds .. "s" end
  local m = math.floor(seconds / 60)
  if m < 60 then return m .. "m " .. string.format("%02ds", seconds % 60) end
  local h = math.floor(m / 60)
  return h .. "h " .. string.format("%02dm", m % 60)
end

function data.wipe()
  data.state = freshState()
  data.dirty = true
  data.save()
end

return data
