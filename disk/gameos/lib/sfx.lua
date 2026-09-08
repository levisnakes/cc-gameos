--[[ sfx -- every sound the console makes.

  An effect is a list of { delay, instrument, pitch, volume } events. Delays
  are in seconds from the moment the effect is triggered; the engine schedules
  them, so a long sound costs nothing extra at the point it is played.

  The shapes below are the vocabulary everything is built from:

    blip    one note
    rise    pitch climbing, gaining volume     -- something good happened
    fall    pitch dropping, losing volume      -- something was lost
    stab    several instruments on one beat    -- impact
    chord   notes struck together, lightly spread
    roll    a note repeating and fading        -- decay tail
    thump   drum layered under a pitched note  -- weight
]]

local req = ...
local audio = req("lib.audio")

local sfx = {}
local M = {}

local P = audio.pitch
local floor = math.floor

------------------------------------------------------------------- shapes
local function blip(inst, pitch, vol, at)
  return { { at or 0, inst, P(pitch), vol } }
end

local function rise(inst, from, to, count, step, vol, gain)
  local out = {}
  local a, b = P(from), P(to)
  for i = 0, count - 1 do
    local k = count > 1 and i / (count - 1) or 0
    out[#out + 1] = { i * step, inst, a + (b - a) * k, vol * (1 + (gain or 0.3) * k) }
  end
  return out
end

local function fall(inst, from, to, count, step, vol)
  local out = {}
  local a, b = P(from), P(to)
  for i = 0, count - 1 do
    local k = count > 1 and i / (count - 1) or 0
    out[#out + 1] = { i * step, inst, a + (b - a) * k, vol * (1 - 0.55 * k) }
  end
  return out
end

local function roll(inst, pitch, count, step, vol, falloff)
  local out = {}
  local p = P(pitch)
  for i = 0, count - 1 do
    out[#out + 1] = { i * step, inst, p, vol * ((falloff or 0.6) ^ i) }
  end
  return out
end

local function chord(inst, pitches, vol, spread)
  local out = {}
  for i = 1, #pitches do
    out[#out + 1] = { (i - 1) * (spread or 0.02), inst, P(pitches[i]), vol }
  end
  return out
end

--- Merge several shapes, optionally offsetting the later ones in time.
local function mix(...)
  local out = {}
  for i = 1, select("#", ...) do
    local part = select(i, ...)
    for j = 1, #part do
      out[#out + 1] = part[j]
    end
  end
  return out
end

local function shift(part, seconds)
  local out = {}
  for i = 1, #part do
    local e = part[i]
    out[i] = { e[1] + seconds, e[2], e[3], e[4] }
  end
  return out
end

local function stab(pitch, vol)
  return {
    { 0, "basedrum", P(pitch), vol },
    { 0, "bit", P(pitch) + 12, vol * 0.55 },
  }
end

local function thump(inst, pitch, vol)
  return {
    { 0, "basedrum", 2, vol * 0.9 },
    { 0, inst, P(pitch), vol },
  }
end

sfx.blip, sfx.rise, sfx.fall, sfx.roll = blip, rise, fall, roll
sfx.chord, sfx.mix, sfx.shift, sfx.stab, sfx.thump = chord, mix, shift, stab, thump

--============================================================== the console
-- Navigation is deliberately quiet and dry: it happens constantly.
M["ui.move"]     = blip("hat", "D5", 0.20)
M["ui.select"]   = { { 0, "pling", P("D4"), 0.42 }, { 0.05, "pling", P("A4"), 0.46 } }
M["ui.back"]     = { { 0, "pling", P("A4"), 0.36 }, { 0.05, "pling", P("D4"), 0.32 } }
M["ui.deny"]     = { { 0, "bass", P("AS3"), 0.5 }, { 0.07, "bass", P("G3"), 0.45 } }
M["ui.open"]     = rise("bell", "D4", "A4", 3, 0.045, 0.34)
M["ui.close"]    = fall("bell", "A4", "D4", 3, 0.045, 0.32)
M["ui.page"]     = blip("hat", "A4", 0.24)
M["ui.type"]     = blip("bit", "A4", 0.28)
M["ui.launch"]   = mix(
  rise("bit", "D4", "D5", 5, 0.035, 0.3),
  shift(chord("pling", { "D4", "FS4", "A4" }, 0.4), 0.18))
M["ui.trophy"]   = mix(
  chord("bell", { "D4", "FS4", "A4" }, 0.5, 0.05),
  shift(chord("bell", { "A4", "CS5", "E5" }, 0.55, 0.05), 0.22),
  shift(blip("chime", "D5", 0.6), 0.44))
M["ui.record"]   = mix(
  rise("chime", "D4", "D5", 6, 0.06, 0.4),
  shift(chord("bell", { "D5", "FS5" }, 0.6), 0.4))

M["boot.chime"]  = mix(
  { { 0.00, "bit", P("D4"), 0.35 }, { 0.10, "bit", P("A4"), 0.40 },
    { 0.20, "bit", P("D5"), 0.45 } },
  shift(chord("bell", { "D4", "FS4", "A4", "D5" }, 0.5, 0.04), 0.34))
M["boot.shutdown"] = mix(
  fall("bit", "D5", "D4", 4, 0.07, 0.4),
  shift(blip("bass", "D4", 0.5), 0.3))

--============================================================== outcomes
M["result.win"] = mix(
  chord("bell", { "D4", "FS4", "A4" }, 0.5, 0.03),
  shift(chord("bell", { "E4", "GS4", "B4" }, 0.5, 0.03), 0.16),
  shift(chord("bell", { "FS4", "AS4", "CS5" }, 0.55, 0.03), 0.32),
  shift(chord("chime", { "FS4", "AS4", "CS5", "FS5" }, 0.6, 0.03), 0.52))
M["result.lose"] = mix(
  { { 0.00, "harp", P("D4"), 0.5 }, { 0.16, "harp", P("B3"), 0.5 },
    { 0.32, "harp", P("G3"), 0.5 } },
  shift(thump("bass", "FS3", 0.6), 0.5))
M["result.levelup"] = rise("bell", "D4", "D5", 5, 0.06, 0.45)
M["result.newwave"] = mix(
  chord("iron_xylophone", { "D4", "A4" }, 0.45, 0.03),
  shift(chord("iron_xylophone", { "E4", "B4" }, 0.5, 0.03), 0.14))

--============================================================== snake
M["snake.eat"]   = { { 0, "bit", P("A4"), 0.40 }, { 0.045, "bit", P("D5"), 0.44 } }
M["snake.bonus"] = mix(
  rise("chime", "D4", "D5", 4, 0.05, 0.45),
  shift(blip("bell", "FS5", 0.5), 0.22))
M["snake.grow"]  = blip("bass", "D4", 0.3)
M["snake.die"]   = mix(
  stab("FS3", 0.8),
  shift(fall("didgeridoo", "D4", "FS3", 5, 0.06, 0.5), 0.06))

--============================================================== tetris
M["tet.move"]    = blip("hat", "B4", 0.18)
M["tet.rotate"]  = { { 0, "bit", P("E4"), 0.26 }, { 0.03, "bit", P("B4"), 0.24 } }
M["tet.wallkick"] = { { 0, "bit", P("G4"), 0.24 }, { 0.035, "bit", P("D5"), 0.26 } }
M["tet.softdrop"] = blip("hat", "FS4", 0.14)
M["tet.harddrop"] = mix(
  fall("bit", "D5", "D4", 3, 0.025, 0.32),
  shift(thump("bass", "D4", 0.5), 0.07))
M["tet.lock"]    = thump("bass", "A3", 0.42)
M["tet.hold"]    = { { 0, "iron_xylophone", P("A4"), 0.4 }, { 0.05, "iron_xylophone", P("E4"), 0.36 } }
M["tet.deny"]    = blip("bass", "G3", 0.4)
M["tet.line1"]   = rise("xylophone", "D4", "A4", 3, 0.045, 0.42)
M["tet.line2"]   = rise("xylophone", "D4", "D5", 4, 0.045, 0.46)
M["tet.line3"]   = rise("xylophone", "D4", "FS5", 5, 0.045, 0.5)
M["tet.tetris"]  = mix(
  rise("xylophone", "D4", "FS5", 6, 0.04, 0.5),
  shift(chord("bell", { "D5", "FS5", "A4" }, 0.6, 0.03), 0.26),
  shift(blip("chime", "FS5", 0.55), 0.42))
M["tet.tspin"]   = mix(
  chord("iron_xylophone", { "D4", "GS4" }, 0.5, 0.03),
  shift(chord("iron_xylophone", { "E4", "AS4" }, 0.55, 0.03), 0.12),
  shift(blip("chime", "E5", 0.5), 0.26))
M["tet.b2b"]     = shift(blip("cow_bell", "D5", 0.45), 0)
M["tet.topout"]  = mix(
  stab("FS3", 0.9),
  shift(fall("bass", "D4", "FS3", 6, 0.07, 0.55), 0.05))

--============================================================== breakout
M["brk.paddle"]  = blip("bit", "A4", 0.38)
M["brk.wall"]    = blip("bit", "D4", 0.30)
-- pitch is shifted by the game to match the brick row
M["brk.brick"]   = { { 0, "xylophone", P("D4"), 0.42 } }
M["brk.tough"]   = { { 0, "iron_xylophone", P("A3"), 0.4 }, { 0.03, "hat", P("D5"), 0.2 } }
M["brk.steel"]   = blip("basedrum", 8, 0.45)
M["brk.laser"]   = fall("bit", "FS5", "D4", 4, 0.025, 0.32)
M["brk.powerup"] = rise("iron_xylophone", "D4", "D5", 4, 0.05, 0.45)
M["brk.penalty"] = fall("didgeridoo", "A4", "D4", 4, 0.05, 0.4)
M["brk.launch"]  = { { 0, "bit", P("D4"), 0.35 }, { 0.05, "bit", P("A4"), 0.38 } }
M["brk.life"]    = mix(
  stab("FS3", 0.75),
  shift(fall("bass", "A3", "FS3", 4, 0.08, 0.5), 0.08))

--============================================================== invaders
-- the march is four notes cycled by the game, so it walks down a fifth
M["inv.march1"]  = blip("bass", "D4", 0.34)
M["inv.march2"]  = blip("bass", "C4", 0.34)
M["inv.march3"]  = blip("bass", "AS3", 0.34)
M["inv.march4"]  = blip("bass", "A3", 0.34)
M["inv.shoot"]   = mix(fall("bit", "FS5", "A4", 4, 0.022, 0.34), blip("hat", "FS5", 0.16))
M["inv.hit"]     = mix(
  blip("snare", 6, 0.42),
  shift(fall("bit", "A4", "D4", 3, 0.03, 0.3), 0.02))
M["inv.ufo"]     = { { 0, "flute", P("A4"), 0.3 }, { 0.09, "flute", P("D5"), 0.3 } }
M["inv.ufohit"]  = mix(
  rise("chime", "D4", "FS5", 5, 0.04, 0.5),
  shift(blip("snare", 8, 0.4), 0))
M["inv.bomb"]    = blip("hat", "D4", 0.16)
M["inv.shield"]  = blip("snare", 2, 0.3)
M["inv.die"]     = mix(
  stab("FS3", 0.9),
  shift(roll("snare", 4, 4, 0.08, 0.5), 0.05),
  shift(fall("didgeridoo", "D4", "FS3", 5, 0.08, 0.5), 0.1))

--============================================================== minesweeper
M["ms.reveal"]   = blip("hat", "A4", 0.18)
M["ms.open"]     = mix(blip("hat", "A4", 0.2), shift(blip("hat", "D5", 0.16), 0.05))
M["ms.flag"]     = { { 0, "cow_bell", P("D5"), 0.34 } }
M["ms.unflag"]   = { { 0, "cow_bell", P("A4"), 0.28 } }
M["ms.chord"]    = mix(blip("hat", "A4", 0.2), shift(blip("hat", "D5", 0.2), 0.04),
  shift(blip("hat", "FS5", 0.18), 0.08))
M["ms.boom"]     = mix(
  stab("FS3", 1.0),
  shift(roll("snare", 5, 5, 0.07, 0.55), 0.04),
  shift(fall("didgeridoo", "D4", "FS3", 6, 0.07, 0.5), 0.1))
M["ms.clear"]    = M["result.win"]

--============================================================== 2048
M["g2048.slide"] = blip("hat", "G4", 0.18)
-- shifted by the game: bigger tiles merge higher
M["g2048.merge"] = { { 0, "xylophone", P("D4"), 0.4 }, { 0.04, "xylophone", P("A4"), 0.36 } }
M["g2048.spawn"] = blip("bit", "D4", 0.2)
M["g2048.undo"]  = fall("didgeridoo", "A4", "D4", 3, 0.05, 0.35)
M["g2048.deny"]  = blip("bass", "G3", 0.34)

--============================================================== sokoban
M["sok.step"]    = blip("hat", "D4", 0.16)
M["sok.push"]    = { { 0, "bass", P("A3"), 0.34 }, { 0.04, "hat", P("D4"), 0.14 } }
M["sok.ongoal"]  = { { 0, "bell", P("D5"), 0.42 }, { 0.05, "bell", P("FS5"), 0.4 } }
M["sok.offgoal"] = { { 0, "bell", P("FS4"), 0.3 }, { 0.05, "bell", P("D4"), 0.28 } }
M["sok.blocked"] = blip("bass", "FS3", 0.34)
M["sok.undo"]    = fall("didgeridoo", "G4", "D4", 3, 0.05, 0.34)
M["sok.reset"]   = fall("bit", "D5", "D4", 4, 0.04, 0.3)
M["sok.solved"]  = M["result.win"]

--============================================================== flappy
M["fly.flap"]    = { { 0, "hat", P("D5"), 0.26 }, { 0.03, "hat", P("A4"), 0.18 } }
M["fly.score"]   = { { 0, "bit", P("A4"), 0.36 }, { 0.045, "bit", P("E5"), 0.4 } }
M["fly.hit"]     = mix(stab("A3", 0.8), shift(blip("snare", 5, 0.45), 0.02))
M["fly.fall"]    = fall("didgeridoo", "A4", "FS3", 7, 0.07, 0.45)
M["fly.medal"]   = mix(
  chord("bell", { "D4", "FS4", "A4" }, 0.5, 0.04),
  shift(blip("chime", "D5", 0.55), 0.26))

--============================================================== pong
M["png.paddle"]  = blip("bit", "A4", 0.4)
M["png.wall"]    = blip("bit", "D4", 0.32)
M["png.point"]   = rise("bit", "D4", "A4", 3, 0.05, 0.42)
M["png.against"] = fall("bit", "A4", "D4", 3, 0.05, 0.38)
M["png.serve"]   = blip("hat", "D5", 0.22)

--============================================================== meteors
M["met.fire"]    = fall("bit", "FS5", "D5", 3, 0.02, 0.3)
M["met.thrust"]  = blip("hat", "FS3", 0.12)
M["met.rock1"]   = mix(blip("snare", 10, 0.34), blip("bit", "FS4", 0.24))
M["met.rock2"]   = mix(blip("snare", 6, 0.4), blip("bit", "D4", 0.26))
M["met.rock3"]   = mix(blip("basedrum", 4, 0.5), blip("snare", 3, 0.36))
M["met.ufo"]     = { { 0, "didgeridoo", P("D4"), 0.3 }, { 0.12, "didgeridoo", P("A3"), 0.3 } }
M["met.ufohit"]  = mix(rise("chime", "D4", "FS5", 4, 0.04, 0.5), blip("snare", 8, 0.4))
M["met.hyper"]   = mix(
  rise("bit", "D4", "FS5", 6, 0.03, 0.3),
  shift(fall("bit", "FS5", "D4", 6, 0.03, 0.3), 0.18))
M["met.die"]     = mix(
  stab("FS3", 1.0),
  shift(roll("snare", 6, 5, 0.08, 0.5), 0.05),
  shift(fall("didgeridoo", "A4", "FS3", 6, 0.09, 0.5), 0.12))
M["met.extra"]   = rise("chime", "D4", "D5", 5, 0.05, 0.5)

--============================================================== lights out
M["lo.on"]       = { { 0, "bell", P("A4"), 0.36 }, { 0.04, "bell", P("E5"), 0.34 } }
M["lo.off"]      = { { 0, "bell", P("E4"), 0.3 }, { 0.04, "bell", P("A3"), 0.28 } }
M["lo.solved"]   = mix(
  rise("chime", "D4", "D5", 5, 0.05, 0.45),
  shift(chord("bell", { "D5", "FS5" }, 0.55, 0.03), 0.28))

--============================================================== simon
-- the four panels; the game plays these directly by index
M["sim.pad1"]    = blip("harp", "D4", 0.7)
M["sim.pad2"]    = blip("harp", "G4", 0.7)
M["sim.pad3"]    = blip("harp", "B4", 0.7)
M["sim.pad4"]    = blip("harp", "D5", 0.7)
M["sim.wrong"]   = mix(
  { { 0, "didgeridoo", P("G3"), 0.6 }, { 0.1, "didgeridoo", P("FS3"), 0.55 } },
  blip("snare", 2, 0.4))
M["sim.round"]   = { { 0, "bit", P("D5"), 0.34 }, { 0.05, "bit", P("A4"), 0.3 } }

--============================================================== connect four
M["c4.move"]     = blip("hat", "A4", 0.18)
M["c4.drop"]     = mix(
  fall("bit", "A4", "D4", 3, 0.03, 0.28),
  shift(thump("bass", "D4", 0.42), 0.08))
M["c4.think"]    = blip("hat", "D4", 0.1)
M["c4.full"]     = blip("bass", "G3", 0.34)
M["c4.win"]      = M["result.win"]
M["c4.lose"]     = M["result.lose"]
M["c4.draw"]     = { { 0, "iron_xylophone", P("D4"), 0.4 }, { 0.14, "iron_xylophone", P("D4"), 0.35 } }

------------------------------------------------------------------- lookup
sfx.table = M

function sfx.get(name) return M[name] end

function sfx.names()
  local out = {}
  for name in pairs(M) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- Longest effect, in seconds: used by the sound test to pace auditions.
function sfx.duration(name)
  local def = M[name]
  if not def then return 0 end
  local last = 0
  for i = 1, #def do
    if def[i][1] > last then last = def[i][1] end
  end
  return last
end

return sfx
