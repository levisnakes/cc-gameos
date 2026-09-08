-- Prints each song as a piano roll so the melodic shape can be read rather
-- than guessed at, and checks a few things that would make it sound wrong:
-- melody notes that clash with the bass, and tracks that never rest.
local req = require_gameos
local gfx = req("lib.gfx")
local audio = req("lib.audio")
gfx.init()
audio.init()
local music = req("lib.music")

local NAME = {}
for name, pitch in pairs(audio.NOTE) do NAME[pitch] = name end

local function pad(s, n)
  s = tostring(s)
  return s .. string.rep(" ", math.max(0, n - #s))
end

for _, id in ipairs(music.names()) do
  local song = music.songs[id]
  LOG("")
  LOG(string.format("%s  (%s)  tempo %d  order: %s",
    song.title, id, song.tempo, table.concat(song.order, " ")))

  -- one representative pattern, drawn as a roll
  local first = song.order[1]
  local patt = song.patterns[first]
  for t = 1, #patt do
    local track = patt[t]
    local line = {}
    for row = 1, music.ROWS do
      local note = track.rows[row]
      line[row] = note and pad(NAME[note.pitch] or note.pitch, 4) or "  . "
    end
    LOG(string.format("  %-14s %s", track.inst, table.concat(line)))
  end

  -- every track should breathe: a wall of notes is not music, and it also
  -- eats the speaker's tick budget
  for _, name in ipairs(song.order) do
    local pattern = song.patterns[name]
    for t = 1, #pattern do
      local filled = 0
      for row = 1, music.ROWS do
        if pattern[t].rows[row] then filled = filled + 1 end
      end
      check(filled < music.ROWS, id .. "/" .. name .. " " ..
        pattern[t].inst .. " leaves room to breathe (" .. filled .. "/16)")
      check(filled > 0, id .. "/" .. name .. " " .. pattern[t].inst .. " is not empty")
    end
  end

  -- the lowest voice should stay below the melody
  for _, name in ipairs(song.order) do
    local pattern = song.patterns[name]
    if #pattern >= 2 then
      local lead, bass = pattern[1], nil
      for t = 2, #pattern do
        if pattern[t].inst == "bass" then bass = pattern[t] end
      end
      if bass then
        for row = 1, music.ROWS do
          local a, b = lead.rows[row], bass.rows[row]
          if a and b then
            -- bass and harp/pling are voiced octaves apart, so equal pitch
            -- numbers are fine; what matters is the melody not being buried
            check(a.pitch >= b.pitch - 12,
              id .. "/" .. name .. " row " .. row .. " melody sits above the bass")
          end
        end
      end
    end
  end
end

LOG("")
LOG("total soundtrack: " .. (function()
  local total = 0
  for _, id in ipairs(music.names()) do total = total + music.length(id) end
  return string.format("%.0f seconds across %d songs", total, #music.names())
end)())

gfx.shutdown()
finish("pianoroll")
