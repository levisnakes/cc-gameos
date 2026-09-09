--[[ music -- the console's soundtrack.

  Songs are written the way a tracker writes them: sixteen-row patterns, a few
  tracks each, and an order list that strings the patterns together. A row is
  `tempo` ticks long, so tempo 3 is 0.15s per row and a pattern is one bar of
  2.4 seconds.

  Note tokens:
    D4     play D above middle
    D4!    accented (louder)
    D4~    soft
    5      a raw pitch, used for drums where pitch is timbre
    .      rest

  Everything is written inside the speaker's two octaves, F#3 to F#5.
  Instruments are voiced at different octaves, so "bass" at D4 sounds far
  below "bell" at D4 -- that is what gives these any vertical range at all.

  All of this is original; nothing here is a transcription.
]]

local req = ...
local audio = req("lib.audio")

local music = {}

local ROWS = 16
local ACCENT, SOFT = 1.35, 0.6

music.badTokens = {}

--- Turn a row string into a sparse map of row -> { pitch, vol }.
local function parse(text, label)
  local rows = {}
  local count = 0
  for token in text:gmatch("%S+") do
    count = count + 1
    if token ~= "." then
      local body = token
      local vol = 1
      local tail = body:sub(-1)
      if tail == "!" then
        vol = ACCENT
        body = body:sub(1, -2)
      elseif tail == "~" then
        vol = SOFT
        body = body:sub(1, -2)
      end
      local pitch
      if body:match("^%d+$") then
        pitch = tonumber(body)
      else
        pitch = audio.NOTE[body]
      end
      if not pitch or pitch < 0 or pitch > 24 then
        music.badTokens[#music.badTokens + 1] = (label or "?") .. ":" .. token
      else
        rows[count] = { pitch = pitch, vol = vol }
      end
    end
  end
  if count ~= ROWS then
    music.badTokens[#music.badTokens + 1] =
      (label or "?") .. " has " .. count .. " rows, expected " .. ROWS
  end
  return rows
end

--- Build one pattern from { instrument, volume, rows } triples.
local function pattern(label, tracks)
  local out = {}
  for i = 1, #tracks do
    local track = tracks[i]
    if not audio.instruments[track[1]] then
      music.badTokens[#music.badTokens + 1] = label .. " bad instrument " .. tostring(track[1])
    end
    out[i] = { inst = track[1], vol = track[2], rows = parse(track[3], label) }
  end
  return out
end

local SONGS = {}

local function song(id, def)
  def.id = id
  def.rows = ROWS
  local built = {}
  for name, tracks in pairs(def.patterns) do
    built[name] = pattern(id .. "/" .. name, tracks)
  end
  def.patterns = built
  SONGS[id] = def
end

--============================================================== the launcher
-- Warm, unhurried, and happy to loop for a long time behind a menu.
song("standby", {
  title = "Standby",
  tempo = 3,
  loop = 1,
  order = { "am", "am", "f", "f", "c", "c", "g", "g" },
  patterns = {
    am = {
      { "pling", 0.42, "A3 .  C4 .  E4 .  A4 .  C5 .  A4 .  E4 .  C4 ." },
      { "bass",  0.50, "A3 .  .  .  .  .  .  .  E4 .  .  .  .  .  .  ." },
      { "hat",   0.16, "18 .  .  .  18 .  .  .  18 .  .  .  18 .  .  ." },
    },
    f = {
      { "pling", 0.42, "F4 .  A4 .  C5 .  F4 .  A4 .  C5 .  A4 .  F4 ." },
      { "bass",  0.50, "F4 .  .  .  .  .  .  .  C4 .  .  .  .  .  .  ." },
      { "hat",   0.16, "18 .  .  .  18 .  .  .  18 .  .  .  18 .  .  ." },
    },
    c = {
      { "pling", 0.42, "C4 .  E4 .  G4 .  C5 .  E5 .  C5 .  G4 .  E4 ." },
      { "bass",  0.50, "C4 .  .  .  .  .  .  .  G4 .  .  .  .  .  .  ." },
      { "hat",   0.16, "18 .  .  .  18 .  .  .  18 .  .  .  18 .  .  ." },
    },
    g = {
      { "pling", 0.42, "G3 .  B3 .  D4 .  G4 .  B4 .  G4 .  D4 .  B3 ." },
      { "bass",  0.50, "G3 .  .  .  .  .  .  .  D4 .  .  .  .  .  .  ." },
      { "hat",   0.16, "18 .  .  .  18 .  .  .  18 .  .  .  18 .  .  ." },
    },
  },
})

--============================================================== Tetris
-- Fast, minor, and relentless: a pumping bass under a falling melody.
song("cascade", {
  title = "Cascade",
  tempo = 2,
  loop = 1,
  order = { "a", "a", "b", "a", "c", "c", "d", "a" },
  patterns = {
    a = {
      { "pling", 0.40, "D5! .  A4 .  F4 .  A4 .  D5 .  A4 .  C5 .  A4 ." },
      { "bass",  0.55, "D4 .  .  .  D4 .  .  .  D4 .  .  .  D4 .  .  ." },
      { "basedrum", 0.45, "2 .  .  .  .  .  .  .  2 .  .  .  .  .  .  ." },
      { "snare", 0.30, ".  .  .  .  5 .  .  .  .  .  .  .  5 .  .  ." },
    },
    b = {
      { "pling", 0.40, "C5! .  G4 .  E4 .  G4 .  C5 .  G4 .  AS4 . G4 ." },
      { "bass",  0.55, "C4 .  .  .  C4 .  .  .  C4 .  .  .  C4 .  .  ." },
      { "basedrum", 0.45, "2 .  .  .  .  .  .  .  2 .  .  .  .  .  .  ." },
      { "snare", 0.30, ".  .  .  .  5 .  .  .  .  .  .  .  5 .  .  ." },
    },
    c = {
      { "pling", 0.40, "AS4! . F4 .  D4 .  F4 .  AS4 . F4 .  A4 .  F4 ." },
      { "bass",  0.55, "AS3 . .  .  AS3 . .  .  AS3 . .  .  AS3 . .  ." },
      { "basedrum", 0.45, "2 .  .  .  .  .  .  .  2 .  .  .  .  .  .  ." },
      { "snare", 0.30, ".  .  .  .  5 .  .  .  .  .  .  .  5 .  .  ." },
    },
    d = {
      { "pling", 0.40, "A4! .  E4 .  CS4 . E4 .  A4 .  CS5 . E5 .  CS5 ." },
      { "bass",  0.55, "A3 .  .  .  A3 .  .  .  A3 .  .  .  E4 .  .  ." },
      { "basedrum", 0.45, "2 .  .  .  .  .  .  .  2 .  .  .  2 .  .  ." },
      { "snare", 0.30, ".  .  .  .  5 .  .  .  .  .  .  .  5 .  .  ." },
    },
  },
})

--============================================================== Snake
-- Light and springy; a banjo line that hops the way the snake does.
song("serpentine", {
  title = "Serpentine",
  tempo = 3,
  loop = 1,
  order = { "a", "b", "a", "c" },
  patterns = {
    a = {
      { "banjo", 0.40, "D4 .  FS4 . A4 .  FS4 . D5 .  A4 .  FS4 . A4 ." },
      { "bass",  0.45, "D4 .  .  .  A3 .  .  .  D4 .  .  .  A3 .  .  ." },
      { "hat",   0.14, ".  .  16 . .  .  16 . .  .  16 . .  .  16 ." },
    },
    b = {
      { "banjo", 0.40, "G4 .  B4 .  D5 .  B4 .  G4 .  D5 .  B4 .  G4 ." },
      { "bass",  0.45, "G3 .  .  .  D4 .  .  .  G3 .  .  .  D4 .  .  ." },
      { "hat",   0.14, ".  .  16 . .  .  16 . .  .  16 . .  .  16 ." },
    },
    c = {
      { "banjo", 0.40, "A4 .  CS5 . E5 .  CS5 . A4 .  E4 .  CS4 . E4 ." },
      { "bass",  0.45, "A3 .  .  .  E4 .  .  .  A3 .  .  .  E4 .  .  ." },
      { "hat",   0.14, ".  .  16 . .  .  16 . .  .  16 . .  .  16 ." },
    },
  },
})

--============================================================== Breakout, Pong
-- Punchy and syncopated, so it sits behind fast paddle work.
song("ricochet", {
  title = "Ricochet",
  tempo = 3,
  loop = 1,
  order = { "a", "b", "a", "c" },
  patterns = {
    a = {
      { "bit",   0.34, "D4 .  .  D4 .  F4 .  .  A4 .  .  A4 .  G4 .  ." },
      { "bass",  0.50, "D4 .  .  .  .  .  .  .  A3 .  .  .  .  .  .  ." },
      { "hat",   0.15, "16 .  16 . 16 .  16 . 16 .  16 . 16 .  16 ." },
    },
    b = {
      { "bit",   0.34, "C4 .  .  C4 .  E4 .  .  G4 .  .  G4 .  F4 .  ." },
      { "bass",  0.50, "C4 .  .  .  .  .  .  .  G3 .  .  .  .  .  .  ." },
      { "hat",   0.15, "16 .  16 . 16 .  16 . 16 .  16 . 16 .  16 ." },
    },
    c = {
      { "bit",   0.34, "AS3 . .  AS3 . D4 .  .  F4 .  .  A4 .  F4 .  ." },
      { "bass",  0.50, "AS3 . .  .  .  .  .  .  F4 .  .  .  .  .  .  ." },
      { "hat",   0.15, "16 .  16 . 16 .  16 . 16 .  16 . 16 .  16 ." },
    },
  },
})

--============================================================== Bombard
-- A slow, heavy descent: a duel where each turn lands harder than the last.
-- The bass walks down under a held figure, so it builds without hurrying the
-- player, who is doing arithmetic in their head between shots.
song("descent", {
  title = "Descent",
  tempo = 4,
  loop = 1,
  order = { "a", "b", "c", "d" },
  patterns = {
    a = {
      { "bass",       0.55, "D4 .  .  .  C4 .  .  .  AS3 . .  .  A3 .  .  ." },
      { "didgeridoo", 0.28, "D4 .  .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
      { "snare",      0.22, ".  .  .  .  .  .  .  4 .  .  .  .  .  .  .  4" },
    },
    b = {
      { "bass",       0.55, "G3 .  .  .  A3 .  .  .  AS3 . .  .  C4 .  .  ." },
      { "didgeridoo", 0.28, "G3 .  .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
      { "snare",      0.22, ".  .  .  .  .  .  .  4 .  .  .  .  .  .  .  4" },
    },
    c = {
      { "bass",       0.55, "D4 .  .  .  D4 .  .  .  C4 .  .  .  AS3 . .  ." },
      { "flute",      0.24, ".  .  .  .  D5~ . .  .  .  .  .  .  C5~ . .  ." },
      { "snare",      0.22, ".  .  .  .  .  .  .  4 .  .  .  .  .  .  .  4" },
    },
    d = {
      { "bass",       0.55, "A3 .  .  .  A3 .  .  .  G3 .  .  .  FS3 . .  ." },
      { "flute",      0.24, ".  .  .  .  A4~ . .  .  .  .  .  .  G4~ . .  ." },
      { "snare",      0.22, ".  .  .  .  .  .  .  4 .  .  .  .  .  .  .  4" },
    },
  },
})

--============================================================== Meteors
-- Sparse and weightless. Long gaps are the point.
song("drift", {
  title = "Drift",
  tempo = 5,
  loop = 1,
  order = { "a", "b", "a", "c" },
  patterns = {
    a = {
      { "flute",      0.30, "D4 .  .  .  A4 .  .  .  .  .  F4 .  .  .  .  ." },
      { "didgeridoo", 0.26, "D4 .  .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
      { "chime",      0.18, ".  .  .  .  .  .  .  .  D5~ . .  .  .  .  .  ." },
    },
    b = {
      { "flute",      0.30, "C4 .  .  .  G4 .  .  .  .  .  E4 .  .  .  .  ." },
      { "didgeridoo", 0.26, "C4 .  .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
      { "chime",      0.18, ".  .  .  .  .  .  .  .  E5~ . .  .  .  .  .  ." },
    },
    c = {
      { "flute",      0.30, "AS3 . .  .  F4 .  .  .  .  .  D4 .  .  .  .  ." },
      { "didgeridoo", 0.26, "AS3 . .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
      { "chime",      0.18, ".  .  .  .  .  .  .  .  F5~ . .  .  .  .  .  ." },
    },
  },
})

--============================================================== the puzzles
-- Slow, soft and deliberately unmemorable: this has to survive being left
-- on while somebody stares at a board for ten minutes.
song("quiet", {
  title = "Quiet Hours",
  tempo = 6,
  loop = 1,
  order = { "a", "b", "c", "b" },
  patterns = {
    a = {
      { "harp", 0.26, "D4 .  .  .  A4 .  .  .  F4 .  .  .  A4 .  .  ." },
      { "bass", 0.30, "D4 .  .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
    },
    b = {
      { "harp", 0.26, "C4 .  .  .  G4 .  .  .  E4 .  .  .  G4 .  .  ." },
      { "bass", 0.30, "C4 .  .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
    },
    c = {
      { "harp", 0.26, "AS3 . .  .  F4 .  .  .  D4 .  .  .  F4 .  .  ." },
      { "bass", 0.30, "AS3 . .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
    },
  },
})

--============================================================== Flappy
-- Quick, airy and a little silly.
song("updraft", {
  title = "Updraft",
  tempo = 3,
  loop = 1,
  order = { "a", "b", "a", "c" },
  patterns = {
    a = {
      { "flute", 0.32, "D5 .  A4 .  D5 .  FS5 . E5 .  CS5 . A4 .  .  ." },
      { "bass",  0.42, "D4 .  .  .  A3 .  .  .  D4 .  .  .  A3 .  .  ." },
      { "hat",   0.13, "16 .  .  16 .  .  16 . .  16 .  .  16 .  .  ." },
    },
    b = {
      { "flute", 0.32, "G4 .  D5 .  E5 .  D5 .  B4 .  G4 .  D4 .  .  ." },
      { "bass",  0.42, "G3 .  .  .  D4 .  .  .  G3 .  .  .  D4 .  .  ." },
      { "hat",   0.13, "16 .  .  16 .  .  16 . .  16 .  .  16 .  .  ." },
    },
    c = {
      { "flute", 0.32, "A4 .  E5 .  FS5 . E5 .  CS5 . A4 .  E4 .  .  ." },
      { "bass",  0.42, "A3 .  .  .  E4 .  .  .  A3 .  .  .  E4 .  .  ." },
      { "hat",   0.13, "16 .  .  16 .  .  16 . .  16 .  .  16 .  .  ." },
    },
  },
})

--============================================================== Connect Four
-- Measured and a bit smug, for a game where you sit and think.
song("gambit", {
  title = "Gambit",
  tempo = 4,
  loop = 1,
  order = { "a", "b", "a", "c" },
  patterns = {
    a = {
      { "guitar", 0.34, "D4 .  .  F4 .  .  A4 .  .  .  G4 .  F4 .  .  ." },
      { "bass",   0.45, "D4 .  .  .  .  .  .  .  A3 .  .  .  .  .  .  ." },
      { "hat",    0.12, ".  .  .  .  16 . .  .  .  .  .  .  16 .  .  ." },
    },
    b = {
      { "guitar", 0.34, "C4 .  .  E4 .  .  G4 .  .  .  F4 .  E4 .  .  ." },
      { "bass",   0.45, "C4 .  .  .  .  .  .  .  G3 .  .  .  .  .  .  ." },
      { "hat",    0.12, ".  .  .  .  16 . .  .  .  .  .  .  16 .  .  ." },
    },
    c = {
      { "guitar", 0.34, "AS3 . .  D4 .  .  F4 .  .  .  E4 .  D4 .  .  ." },
      { "bass",   0.45, "AS3 . .  .  .  .  .  .  F4 .  .  .  .  .  .  ." },
      { "hat",    0.12, ".  .  .  .  16 . .  .  .  .  .  .  16 .  .  ." },
    },
  },
})

-------------------------------------------------------------------- lookup
function music.get(id) return SONGS[id] end

function music.names()
  local out = {}
  for id in pairs(SONGS) do out[#out + 1] = id end
  table.sort(out)
  return out
end

function music.title(id)
  local s = SONGS[id]
  return s and s.title or id
end

--- Seconds for one pass through the order list.
function music.length(id)
  local s = SONGS[id]
  if not s then return 0 end
  return #s.order * ROWS * s.tempo * 0.05
end

music.songs = SONGS
music.ROWS = ROWS

return music
