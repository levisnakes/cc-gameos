--[[ settings -- console preferences.

  Left/Right cycles a value, Enter activates an action. Theme changes apply
  live so the palette strip at the bottom shows the result immediately.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")
local data = req("lib.data")
local ui = req("lib.ui")

local settings = {}

local floor = math.floor

local VOLUMES = { 0, 0.5, 1, 2, 3 }
local VOLUME_NAMES = { "Off", "Quiet", "Normal", "Loud", "Max" }

local function volumeIndex()
  local v = data.get("volume")
  for i = 1, #VOLUMES do if math.abs(VOLUMES[i] - v) < 0.01 then return i end end
  return 3
end

function settings.run(api)
  local rows = {}

  rows[#rows + 1] = {
    label = "Theme",
    get = function() return gfx.themes[gfx.themeIndex].name end,
    cycle = function(dir)
      gfx.applyTheme(gfx.themeIndex + dir)
      data.set("theme", gfx.themes[gfx.themeIndex].id)
    end,
  }
  rows[#rows + 1] = {
    label = "Sound effects",
    get = function() return audio.sfxOn and "On" or "Off" end,
    cycle = function()
      audio.sfxOn = not audio.sfxOn
      data.set("sfx", audio.sfxOn)
      if audio.sfxOn then audio.play("select") end
    end,
  }
  rows[#rows + 1] = {
    label = "Menu music",
    get = function() return audio.musicOn and "On" or "Off" end,
    cycle = function()
      audio.musicOn = not audio.musicOn
      data.set("music", audio.musicOn)
      if audio.musicOn then audio.playMusic("menu") else audio.stopMusic() end
    end,
  }
  rows[#rows + 1] = {
    label = "Volume",
    get = function() return VOLUME_NAMES[volumeIndex()] end,
    cycle = function(dir)
      local i = volumeIndex() + dir
      if i < 1 then i = #VOLUMES elseif i > #VOLUMES then i = 1 end
      audio.volume = VOLUMES[i]
      data.set("volume", VOLUMES[i])
      audio.play("select")
    end,
  }
  rows[#rows + 1] = {
    label = "Frame counter",
    get = function() return data.get("showFps") and "On" or "Off" end,
    cycle = function() data.set("showFps", not data.get("showFps")) end,
  }
  rows[#rows + 1] = {
    label = "Confirm power off",
    get = function() return data.get("confirmExit") and "On" or "Off" end,
    cycle = function() data.set("confirmExit", not data.get("confirmExit")) end,
  }
  rows[#rows + 1] = { spacer = true }
  rows[#rows + 1] = {
    label = "Clear high scores",
    action = function()
      if ui.confirm(" Clear scores ", "Erase every high score?", "Erase", "Keep", colors.red) then
        data.state.scores = {}
        data.markDirty()
        data.save()
        audio.play("deny")
      end
    end,
  }
  rows[#rows + 1] = {
    label = "Factory reset",
    action = function()
      if ui.confirm(" Factory reset ", { "Erase scores, progress", "and settings?" }, "Erase", "Cancel", colors.red) then
        data.wipe()
        audio.sfxOn = data.get("sfx")
        audio.musicOn = data.get("music")
        audio.volume = data.get("volume")
        gfx.applyTheme(gfx.themeByID(data.get("theme")))
        audio.play("deny")
      end
    end,
  }

  local sel = 1
  local FIRST_Y = 4

  local function step(dir)
    local i = sel
    for _ = 1, #rows do
      i = i + dir
      if i < 1 then i = #rows elseif i > #rows then i = 1 end
      if not rows[i].spacer then
        sel = i
        audio.play("move")
        return
      end
    end
  end

  local function draw()
    gfx.clear(colors.black)
    gfx.fill(1, 1, gfx.W, 1, colors.gray)
    gfx.text(2, 1, "SETTINGS", colors.white, colors.gray)
    gfx.right(gfx.W - 1, 1, "GameOS v" .. api.version, colors.lightGray, colors.gray)
    gfx.rule(1, 2, gfx.W, colors.lightBlue, colors.black)

    for i = 1, #rows do
      local row = rows[i]
      local y = FIRST_Y + i - 1
      if y <= 16 then
        if row.spacer then
          gfx.rule(4, y, gfx.W - 8, colors.gray, colors.black)
        else
          local on = (i == sel)
          local bg = on and colors.lightBlue or colors.black
          local fg = on and gfx.contrast(colors.lightBlue) or colors.white
          gfx.fill(3, y, gfx.W - 4, 1, bg)
          gfx.text(4, y, row.label, fg, bg)
          if row.get then
            local value = row.get()
            gfx.right(gfx.W - 4, y, value, on and fg or colors.lime, bg)
            if on then
              gfx.text(gfx.W - 5 - #value, y, "<", fg, bg)
              gfx.text(gfx.W - 3, y, ">", fg, bg)
            end
          elseif on then
            gfx.text(gfx.W - 4, y, "*", fg, bg)
          end
        end
      end
    end

    for i = 1, 16 do
      gfx.fill(4 + (i - 1) * 2, 17, 2, 1, gfx.allColors[i])
    end

    gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
    gfx.text(2, 19, "Left/Right", colors.lightBlue, colors.black)
    gfx.text(13, 19, "change", colors.lightGray, colors.black)
    gfx.text(21, 19, "Enter", colors.lightBlue, colors.black)
    gfx.text(27, 19, "activate", colors.lightGray, colors.black)
    gfx.text(37, 19, "Q", colors.lightBlue, colors.black)
    gfx.text(39, 19, "back", colors.lightGray, colors.black)
  end

  local function handle(ev)
    local name = ev[1]
    if name == "key" then
      local k = ev[2]
      if k == keys.up or k == keys.w then
        step(-1)
      elseif k == keys.down or k == keys.s then
        step(1)
      elseif k == keys.left or k == keys.a then
        local row = rows[sel]
        if row.cycle then row.cycle(-1) audio.play("move") end
      elseif k == keys.right or k == keys.d then
        local row = rows[sel]
        if row.cycle then row.cycle(1) audio.play("move") end
      elseif k == keys.enter or k == keys.space or k == keys.numPadEnter then
        local row = rows[sel]
        if row.action then
          row.action()
        elseif row.cycle then
          row.cycle(1)
          audio.play("select")
        end
      elseif k == keys.backspace or k == keys.q then
        audio.play("back")
        return 1
      end
    elseif name == "mouse_click" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      local i = my - FIRST_Y + 1
      if rows[i] and not rows[i].spacer then
        if i == sel then
          local row = rows[sel]
          if row.action then
            row.action()
          elseif row.cycle then
            -- clicking the left chevron steps back, anywhere else steps on
            row.cycle(mx == gfx.W - 5 - #row.get() and -1 or 1)
            audio.play("select")
          end
        else
          sel = i
          audio.play("move")
        end
      end
    end
    return nil
  end

  ui.loop(draw, handle)
  data.flush()
end

return settings
