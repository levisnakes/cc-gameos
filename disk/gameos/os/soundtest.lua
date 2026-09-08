--[[ soundtest -- audition every sound the console makes.

  Useful for setting the volume knobs, and for hearing what a game is about
  to throw at you before it does.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")
local sfx = req("lib.sfx")
local data = req("lib.data")
local music = req("lib.music")
local ui = req("lib.ui")

local soundtest = {}

local floor = math.floor
local ROWS = 13
local LIST_Y = 5

--- Effects grouped by their name prefix, with songs on the end.
local function build()
  local GROUPS = {
    ui = "Console", boot = "Console", result = "Outcomes",
    snake = "Snake", tet = "Tetris", brk = "Breakout", inv = "Invaders",
    ms = "Minesweeper", g2048 = "2048", sok = "Sokoban", fly = "Flappy",
    png = "Pong", met = "Meteors", lo = "Lights Out", sim = "Simon",
    c4 = "Connect Four",
  }
  local order = {
    "Console", "Outcomes", "Snake", "Tetris", "Breakout", "Invaders",
    "Minesweeper", "2048", "Sokoban", "Flappy", "Pong", "Meteors",
    "Lights Out", "Simon", "Connect Four",
  }
  local buckets = {}
  for _, name in ipairs(sfx.names()) do
    local prefix = name:match("^([^.]+)")
    local group = GROUPS[prefix] or "Other"
    buckets[group] = buckets[group] or {}
    table.insert(buckets[group], name)
  end

  local rows = {}
  for _, group in ipairs(order) do
    if buckets[group] then
      rows[#rows + 1] = { header = group }
      for _, name in ipairs(buckets[group]) do
        rows[#rows + 1] = { sound = name }
      end
    end
  end
  rows[#rows + 1] = { header = "Music" }
  for _, id in ipairs(music.names()) do
    rows[#rows + 1] = { song = id }
  end
  return rows
end

function soundtest.run(api)
  local rows = build()
  local sel = 1
  while rows[sel] and rows[sel].header do sel = sel + 1 end
  local top = 1
  local playing = nil

  local function clampView()
    if sel < top then top = sel end
    if sel > top + ROWS - 1 then top = sel - ROWS + 1 end
    local maxTop = math.max(1, #rows - ROWS + 1)
    if top > maxTop then top = maxTop end
    if top < 1 then top = 1 end
  end

  local function move(dir)
    local i = sel
    for _ = 1, #rows do
      i = i + dir
      if i < 1 then i = #rows elseif i > #rows then i = 1 end
      if not rows[i].header then
        sel = i
        return
      end
    end
  end

  local function activate()
    local row = rows[sel]
    if not row then return end
    if row.sound then
      audio.play(row.sound)
    elseif row.song then
      if audio.musicName() == row.song then
        audio.stopMusic()
        playing = nil
      else
        audio.playMusic(row.song)
        playing = row.song
      end
    end
  end

  local function draw()
    gfx.clear(colors.black)
    gfx.fill(1, 1, gfx.W, 1, colors.gray)
    gfx.text(2, 1, "SOUND TEST", colors.white, colors.gray)
    gfx.right(gfx.W - 1, 1, #sfx.names() .. " effects", colors.lightGray, colors.gray)
    gfx.rule(1, 2, gfx.W, colors.magenta, colors.black)

    -- the three knobs, so you can hear what you are setting
    gfx.text(2, 3, "MASTER", colors.lightGray, colors.black)
    gfx.bar(9, 3, 10, audio.volumes.master, colors.lime, colors.gray)
    gfx.text(21, 3, "MUSIC", colors.lightGray, colors.black)
    gfx.bar(27, 3, 10, audio.volumes.music, colors.cyan, colors.gray)
    gfx.text(39, 3, "FX", colors.lightGray, colors.black)
    gfx.bar(42, 3, 8, audio.volumes.sfx, colors.orange, colors.black)

    clampView()
    for i = 0, ROWS - 1 do
      local row = rows[top + i]
      local y = LIST_Y + i
      gfx.fill(1, y, gfx.W, 1, colors.black)
      if row then
        if row.header then
          gfx.text(2, y, row.header, colors.magenta, colors.black)
          gfx.rule(3 + #row.header, y, gfx.W - 4 - #row.header, colors.gray, colors.black)
        else
          local on = (top + i == sel)
          local bg = on and colors.magenta or colors.black
          local fg = on and gfx.contrast(colors.magenta) or colors.white
          gfx.fill(2, y, gfx.W - 2, 1, bg)
          if row.sound then
            gfx.text(4, y, gfx.clip(row.sound, 26), fg, bg)
            gfx.right(gfx.W - 2, y,
              string.format("%.2fs", sfx.duration(row.sound)),
              on and fg or colors.lightGray, bg)
          else
            gfx.text(4, y, gfx.clip(music.title(row.song), 26), fg, bg)
            local tag = (audio.musicName() == row.song) and "playing" or
              string.format("%.0fs", music.length(row.song))
            gfx.right(gfx.W - 2, y, tag, on and fg or colors.lightGray, bg)
          end
        end
      end
    end

    gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
    gfx.text(2, 19, "Enter", colors.magenta, colors.black)
    gfx.text(8, 19, "play", colors.lightGray, colors.black)
    gfx.text(14, 19, "Left/Right", colors.magenta, colors.black)
    gfx.text(25, 19, "master", colors.lightGray, colors.black)
    gfx.text(33, 19, "Q", colors.magenta, colors.black)
    gfx.text(35, 19, "back", colors.lightGray, colors.black)
  end

  local function handle(ev)
    if ev[1] == "key" then
      local k = ev[2]
      if k == keys.up or k == keys.w then
        move(-1)
      elseif k == keys.down or k == keys.s then
        move(1)
      elseif k == keys.left or k == keys.a or k == keys.right or k == keys.d then
        local step = (k == keys.left or k == keys.a) and -1 or 1
        local v = math.floor(audio.volumes.master * 10 + 0.5) + step
        v = math.max(0, math.min(10, v))
        audio.volumes.master = v / 10
        data.set("volMaster", v)
      elseif k == keys.enter or k == keys.space then
        activate()
      elseif k == keys.pageUp then
        for _ = 1, ROWS do move(-1) end
      elseif k == keys.pageDown then
        for _ = 1, ROWS do move(1) end
      elseif k == keys.backspace or k == keys.q then
        audio.stopMusic()
        audio.play("ui.back")
        return 1
      end
    elseif ev[1] == "mouse_scroll" then
      move(ev[2] > 0 and 1 or -1)
    elseif ev[1] == "mouse_click" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      local i = top + (my - LIST_Y)
      if rows[i] and not rows[i].header then
        sel = i
        activate()
      elseif my >= 18 then
        audio.stopMusic()
        audio.play("ui.back")
        return 1
      end
    end
    return nil
  end

  ui.loop(draw, handle)
end

return soundtest
