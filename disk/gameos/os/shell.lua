--[[ shell -- the game launcher.

  Left: a scrolling catalogue. Right: a live cover illustration for the
  highlighted entry plus its stats. Games draw their own covers, so the
  browser animates without the shell knowing anything about them.
]]

local req = ...
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local audio = req("lib.audio")
local data = req("lib.data")
local ui = req("lib.ui")

local shell = {}

local floor = math.floor

local LIST_X, LIST_W = 2, 19
local LIST_Y, LIST_ROWS = 3, 15
local PANEL_X, PANEL_W = 23, 28
local COVER_Y, COVER_H = 3, 7

local IDLE_LIMIT = 45

--------------------------------------------------------------- system art
local function coverScores(c, t)
  local heights = { 8, 13, 5, 10, 6 }
  local cols = { colors.orange, colors.yellow, colors.lightGray, colors.lime, colors.cyan }
  for i = 1, 5 do
    local h = heights[i] + floor(math.sin(t * 2 + i) * 1.5)
    c:fill(8 + (i - 1) * 9, c.h - 3 - h, 7, h, cols[i])
  end
  c:hline(1, c.h - 3, c.w, colors.lightGray)
end

local function coverSettings(c, t)
  for i = 1, 3 do
    local y = 5 + (i - 1) * 6
    c:hline(10, y + 1, 36, colors.gray)
    local k = (math.sin(t * 1.5 + i * 2) + 1) / 2
    local x = 10 + floor(k * 32)
    c:fill(x, y, 4, 3, i == 2 and colors.lime or colors.lightBlue)
  end
end

local function coverTrophies(c, t)
  local cup = { "..####..", "..####..", "...##...", "..####.." }
  local earned = data.trophyCount()
  for i = 1, 5 do
    local lit = i <= math.min(5, 1 + floor(earned / 3))
    local bob = (math.sin(t * 2 + i) > 0.6) and 1 or 0
    local x = 3 + (i - 1) * 11
    for row = 1, #cup do
      local line = cup[row]
      for col = 1, 8 do
        if line:sub(col, col) == "#" then
          c:set(x + col, 5 + row - bob, lit and colors.yellow or colors.gray)
        end
      end
    end
    c:fill(x + 1, 10 - bob, 6, 2, lit and colors.orange or colors.gray)
  end
  c:hline(1, 13, c.w, colors.lightGray)
end

local function coverAbout(c, t)
  font.centerShadow(c, 5, "GAMEOS", colors.white, colors.blue, 2, 2)
  local p = (t * 18) % (c.w + 24)
  c:hline(1, 14, c.w, colors.gray)
  c:fill(p - 24, 13, 24, 3, colors.lightBlue)
  font.center(c, 17, "V" .. (shell.version or "1"), colors.lightGray, 1, 1)
end

local function coverPower(c, t)
  local cx, cy = floor(c.w / 2), 10
  local blink = math.sin(t * 3) > 0
  c:circle(cx, cy, 7, blink and colors.red or colors.gray, false)
  c:circle(cx, cy, 6, blink and colors.red or colors.gray, false)
  c:fill(cx - 3, cy - 9, 7, 5, colors.black)
  c:fill(cx - 1, cy - 8, 2, 7, blink and colors.red or colors.gray)
end

local function coverFallback(def)
  return function(c, t)
    local accent = def.accent or colors.lightBlue
    for i = 0, 6 do
      c:hline(1, 1 + i * 3, c.w, i % 2 == 0 and colors.gray or colors.black)
    end
    font.centerShadow(c, 7, def.name, accent, colors.black, 2, 2)
  end
end

--------------------------------------------------------------- entry list
local function buildEntries(api)
  local list = { { kind = "header", label = "GAMES" } }
  for i = 1, #api.games do
    list[#list + 1] = { kind = "game", def = api.games[i] }
  end
  list[#list + 1] = { kind = "header", label = "SYSTEM" }
  list[#list + 1] = { kind = "action", id = "scores", label = "High Scores",
    accent = colors.yellow, cover = coverScores,
    tagline = "Every personal best", desc = "Records for each game" }
  list[#list + 1] = { kind = "action", id = "trophies", label = "Trophies",
    accent = colors.orange, cover = coverTrophies,
    tagline = "Things to chase", desc = "Every trophy, earned or not" }
  list[#list + 1] = { kind = "action", id = "settings", label = "Settings",
    accent = colors.lightBlue, cover = coverSettings,
    tagline = "Theme, sound, data", desc = "Tune the console" }
  list[#list + 1] = { kind = "action", id = "about", label = "About",
    accent = colors.purple, cover = coverAbout,
    tagline = "Version and credits", desc = "What this thing is" }
  list[#list + 1] = { kind = "action", id = "power", label = "Power Off",
    accent = colors.red, cover = coverPower,
    tagline = "Back to CraftOS", desc = "Leave GameOS" }
  return list
end

local function selectable(entry) return entry.kind ~= "header" end

--------------------------------------------------------------------- draw
local function accentOf(entry)
  if entry.kind == "game" then return entry.def.accent or colors.lightBlue end
  return entry.accent or colors.lightBlue
end

local function labelOf(entry)
  if entry.kind == "game" then return entry.def.name end
  return entry.label
end

function shell.run(api)
  shell.version = api.version
  local entries = buildEntries(api)
  local sel = 2
  for i = 1, #entries do
    if selectable(entries[i]) then sel = i break end
  end

  local top = 1
  local cover = Canvas.new(PANEL_X, COVER_Y, PANEL_W, COVER_H, colors.black)
  local saver = Canvas.new(1, 1, gfx.W, gfx.H, colors.black)
  local t = 0
  local idle = 0
  local saverOn = false
  local saverX, saverY, saverVX, saverVY = 10, 10, 26, 15
  local saverHue = 1

  local function clampView()
    if sel < top then top = sel end
    if sel > top + LIST_ROWS - 1 then top = sel - LIST_ROWS + 1 end
    local maxTop = #entries - LIST_ROWS + 1
    if maxTop < 1 then maxTop = 1 end
    if top > maxTop then top = maxTop end
    if top < 1 then top = 1 end
  end

  local function move(dir)
    local i = sel
    for _ = 1, #entries do
      i = i + dir
      if i < 1 then i = #entries elseif i > #entries then i = 1 end
      if selectable(entries[i]) then
        if i ~= sel then audio.play("move") end
        sel = i
        return
      end
    end
  end

  --- Jump to the first selectable entry of the next section.
  local function jumpSection()
    local n = #entries
    local i = sel
    -- walk forward to the next header, then to the entry after it
    for _ = 1, n do
      i = i % n + 1
      if entries[i].kind == "header" then
        for _ = 1, n do
          i = i % n + 1
          if selectable(entries[i]) then
            sel = i
            audio.play("select")
            return
          end
        end
      end
    end
  end

  local function drawList()
    clampView()
    for r = 0, LIST_ROWS - 1 do
      local i = top + r
      local y = LIST_Y + r
      gfx.fill(LIST_X, y, LIST_W, 1, colors.black)
      local e = entries[i]
      if e then
        if e.kind == "header" then
          gfx.text(LIST_X, y, e.label, colors.lightGray, colors.black)
          gfx.rule(LIST_X + #e.label + 1, y, LIST_W - #e.label - 1, colors.gray, colors.black)
        else
          local on = (i == sel)
          local accent = accentOf(e)
          local bg = on and accent or colors.black
          local fg = on and gfx.contrast(accent) or colors.white
          gfx.fill(LIST_X, y, LIST_W, 1, bg)
          if not on then
            gfx.fill(LIST_X, y, 1, 1, accent)
          end
          gfx.text(LIST_X + 2, y, gfx.clip(labelOf(e), LIST_W - 3), fg, bg)
          if on then gfx.text(LIST_X + LIST_W - 1, y, ">", fg, bg) end
        end
      end
    end
    if #entries > LIST_ROWS then
      local barH = math.max(1, floor(LIST_ROWS * LIST_ROWS / #entries))
      local barY = LIST_Y + floor((top - 1) / #entries * LIST_ROWS)
      gfx.fill(LIST_X + LIST_W, LIST_Y, 1, LIST_ROWS, colors.black)
      gfx.fill(LIST_X + LIST_W, barY, 1, barH, colors.gray)
    end
  end

  local function drawPanel()
    local e = entries[sel]
    local accent = accentOf(e)

    cover:clear(colors.black)
    local drawCover = e.cover
    if e.kind == "game" then
      if not e.def.cover and not e.def._fallbackCover then
        e.def._fallbackCover = coverFallback(e.def)
      end
      drawCover = e.def.cover or e.def._fallbackCover
    end
    local okCover = pcall(drawCover, cover, t)
    if not okCover then
      cover:clear(colors.gray)
      font.center(cover, 8, "NO ART", colors.lightGray, 1, 1)
    end
    cover:render()

    gfx.rule(PANEL_X, COVER_Y + COVER_H, PANEL_W, accent, colors.black)

    local name = e.kind == "game" and e.def.name or e.label
    local tagline = e.kind == "game" and (e.def.tagline or "") or (e.tagline or "")
    gfx.fill(PANEL_X, 11, PANEL_W, 1, colors.black)
    gfx.text(PANEL_X, 11, gfx.clip(name:upper(), PANEL_W), colors.white, colors.black)
    gfx.fill(PANEL_X, 12, PANEL_W, 1, colors.black)
    gfx.text(PANEL_X, 12, gfx.clip(tagline, PANEL_W), colors.lightGray, colors.black)

    for y = 13, 17 do gfx.fill(PANEL_X, y, PANEL_W, 1, colors.black) end
    if e.kind == "game" then
      local def = e.def
      local stats = data.stats(def.id)
      local best = data.best(def.id)
      gfx.text(PANEL_X, 14, def.scoreLabel or "BEST", colors.lightGray, colors.black)
      gfx.right(PANEL_X + PANEL_W - 1, 14, best > 0 and gfx.commas(best) or "--", accent, colors.black)
      gfx.text(PANEL_X, 15, "PLAYS", colors.lightGray, colors.black)
      gfx.right(PANEL_X + PANEL_W - 1, 15, tostring(stats.plays), colors.white, colors.black)
      gfx.text(PANEL_X, 16, "TIME", colors.lightGray, colors.black)
      gfx.right(PANEL_X + PANEL_W - 1, 16, data.formatDuration(stats.seconds), colors.white, colors.black)
      if def.modes and #def.modes > 1 then
        gfx.text(PANEL_X, 17, #def.modes .. " modes", colors.lightGray, colors.black)
      end
    else
      gfx.text(PANEL_X, 14, gfx.clip(e.desc or "", PANEL_W), colors.lightGray, colors.black)
    end
  end

  local function draw()
    gfx.clear(colors.black)
    local accent = accentOf(entries[sel])
    gfx.fill(1, 1, gfx.W, 1, colors.gray)
    gfx.text(2, 1, "GAMEOS", colors.white, colors.gray)
    gfx.text(9, 1, "v" .. api.version, colors.lightGray, colors.gray)
    local clock = textutils.formatTime(os.time(), true)
    gfx.right(gfx.W - 1, 1, clock, colors.lightGray, colors.gray)
    gfx.rule(1, 2, gfx.W, accent, colors.black)

    drawList()
    gfx.fill(LIST_X + LIST_W + 1, LIST_Y, 1, LIST_ROWS, colors.black)
    drawPanel()

    gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
    gfx.fill(1, 19, gfx.W, 1, colors.black)
    gfx.text(2, 19, "Up/Dn", accent, colors.black)
    gfx.text(8, 19, "browse", colors.lightGray, colors.black)
    gfx.text(17, 19, "Enter", accent, colors.black)
    gfx.text(23, 19, "play", colors.lightGray, colors.black)
    gfx.text(29, 19, "Tab", accent, colors.black)
    gfx.text(33, 19, "jump", colors.lightGray, colors.black)
    gfx.text(39, 19, "Q", accent, colors.black)
    gfx.text(41, 19, "power", colors.lightGray, colors.black)
  end

  ----------------------------------------------------------- screensaver
  local function drawSaver(dt)
    saverX = saverX + saverVX * dt
    saverY = saverY + saverVY * dt
    local tw = font.width("GAMEOS", 2, 2)
    if saverX < 1 then saverX = 1 saverVX = -saverVX saverHue = saverHue % 6 + 1 end
    if saverX + tw > saver.w then saverX = saver.w - tw saverVX = -saverVX saverHue = saverHue % 6 + 1 end
    if saverY < 1 then saverY = 1 saverVY = -saverVY saverHue = saverHue % 6 + 1 end
    if saverY + 11 > saver.h then saverY = saver.h - 11 saverVY = -saverVY saverHue = saverHue % 6 + 1 end
    local hues = { colors.lime, colors.cyan, colors.magenta, colors.orange, colors.lightBlue, colors.yellow }
    saver:clear(colors.black)
    font.draw(saver, floor(saverX), floor(saverY), "GAMEOS", hues[saverHue], 2, 2)
    gfx.beginFrame()
    saver:render()
    gfx.endFrame()
  end

  ------------------------------------------------------------------ loop
  local FRAME = 0.08
  local timer = os.startTimer(FRAME)
  local running = true

  local function launch(e)
    if e.kind == "game" then
      audio.play("select")
      ui.transition(e.def.accent or colors.lightBlue)
      api.runtime.play(e.def, api)
      ui.transition(e.def.accent or colors.lightBlue)
    elseif e.id == "scores" then
      audio.play("select")
      req("os.scores").run(api)
    elseif e.id == "trophies" then
      audio.play("select")
      req("os.trophies").run(api)
    elseif e.id == "settings" then
      audio.play("select")
      req("os.settings").run(api)
    elseif e.id == "about" then
      audio.play("select")
      req("os.about").run(api)
    elseif e.id == "power" then
      if (not data.get("confirmExit")) or ui.confirm(" Power Off ", "Leave GameOS?", "Power off", "Stay") then
        running = false
        return
      end
    end
    ui.terminated = false
    -- the runtime stops the menu track while a game is running
    audio.playMusic("menu")
    os.cancelTimer(timer)
    timer = os.startTimer(FRAME)
    idle = 0
  end

  -- W/A/S/D/Q are navigation, so they never trigger a letter jump.
  local NAV_LETTERS = { w = true, a = true, s = true, d = true, q = true, p = true }

  local function jumpToLetter(ch)
    ch = ch:lower()
    if NAV_LETTERS[ch] then return false end
    for step = 1, #entries do
      local i = ((sel - 1 + step) % #entries) + 1
      local e = entries[i]
      if selectable(e) and labelOf(e):sub(1, 1):lower() == ch then
        sel = i
        audio.play("move")
        return true
      end
    end
    return false
  end

  audio.playMusic("menu")

  while running do
    local ev = { os.pullEventRaw() }
    local name = ev[1]

    if name == "timer" and ev[2] == timer then
      timer = os.startTimer(FRAME)
      t = t + FRAME
      idle = idle + FRAME
      audio.update(os.clock())
      if idle > IDLE_LIMIT then
        saverOn = true
        drawSaver(FRAME)
      else
        saverOn = false
        gfx.beginFrame()
        draw()
        gfx.endFrame()
      end

    elseif name == "terminate" then
      running = false

    elseif name == "key" then
      idle = 0
      if saverOn then
        saverOn = false
      else
        local k = ev[2]
        if k == keys.up or k == keys.w then
          move(-1)
        elseif k == keys.down or k == keys.s then
          move(1)
        elseif k == keys.home then
          sel = 1 move(1)
        elseif k == keys["end"] then
          sel = #entries
          if not selectable(entries[sel]) then move(1) end
        elseif k == keys.pageUp then
          for _ = 1, 5 do move(-1) end
        elseif k == keys.pageDown then
          for _ = 1, 5 do move(1) end
        elseif k == keys.tab then
          jumpSection()
        elseif k == keys.enter or k == keys.space or k == keys.numPadEnter then
          launch(entries[sel])
        elseif k == keys.q then
          if (not data.get("confirmExit")) or ui.confirm(" Power Off ", "Leave GameOS?", "Power off", "Stay") then
            running = false
          end
          os.cancelTimer(timer)
          timer = os.startTimer(FRAME)
        end
      end

    elseif name == "char" then
      idle = 0
      if not saverOn then
        local ch = ev[2]
        if ch:match("%a") then jumpToLetter(ch) end
      end
      saverOn = false

    elseif name == "mouse_click" then
      idle = 0
      if saverOn then
        saverOn = false
      else
        local mx, my = ui.toLocal(ev[3], ev[4])
        if mx >= LIST_X and mx < LIST_X + LIST_W and my >= LIST_Y and my < LIST_Y + LIST_ROWS then
          local i = top + (my - LIST_Y)
          local e = entries[i]
          if e and selectable(e) then
            if i == sel then
              launch(e)
            else
              sel = i
              audio.play("move")
            end
          end
        elseif mx >= PANEL_X then
          launch(entries[sel])
        end
      end

    elseif name == "mouse_scroll" then
      idle = 0
      move(ev[2] > 0 and 1 or -1)

    elseif name == "term_resize" then
      idle = 0
      if not gfx.handleResize() then running = false end
    end
  end

  os.cancelTimer(timer)
  audio.stopMusic()
  data.flush()
end

return shell
