--[[ runtime -- plays one game module.

  Owns the fixed-step loop, event routing, the pause menu, crash containment
  and the game-over card, so a game module only has to implement update(dt)
  and draw().

  Game module contract (see /gameos/games/*.lua):
    id, name, tagline, accent, art, controls, modes (optional)
    new(api, mode) -> instance
  Instance:
    :update(dt) :draw()               required
    :onKey(code, held) :onChar(c)     optional
    :onMouse(kind, btn, x, y)         optional
    :summary() -> { {label, value} }  optional
    .score .finished .quit .won .noScore
]]

local req = ...
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local input = req("lib.input")
local audio = req("lib.audio")
local data = req("lib.data")
local ui = req("lib.ui")

local runtime = {}

local TICK = 0.05
local floor = math.floor

------------------------------------------------------------------- crashes
local function crash(def, err)
  local msg = tostring(err)
  local lines = {}
  -- wrap the message to the dialog width
  local width = 36
  while #msg > 0 and #lines < 4 do
    lines[#lines + 1] = msg:sub(1, width)
    msg = msg:sub(width + 1)
  end
  audio.play("ui.deny")
  ui.alert(" " .. def.name .. " crashed ", lines, colors.red)
  return "menu"
end

--------------------------------------------------------------- pause screen
--- The guide, in the sense that the Xbox and the Switch use the word: the
--- things you want mid-game without leaving the game. Volume above all --
--- somebody walks into the room and you want it down now, not after four
--- menus -- so the three knobs are here as sliders you nudge in place, and
--- the trophy list is one keypress away.
---
--- This blocks the session loop while it is open, which is why a networked
--- game sets suppressPause and draws its own overlay instead.
local function pauseMenu(def, api)
  audio.play("ui.back")

  local KNOBS = {
    { label = "Master",  key = "volMaster", field = "master" },
    { label = "Music",   key = "volMusic",  field = "music" },
    { label = "Effects", key = "volSfx",    field = "sfx" },
  }

  -- rows: 1 Resume, 2 Restart, 3 Controls, 4 Trophies, 5..7 knobs, 8 Quit
  local ACTIONS = { "Resume", "Restart", "Controls", "Trophies" }
  local ROWS = #ACTIONS + #KNOBS + 1
  local QUIT = ROWS

  local X, Y, W, H = 10, 4, 32, 14
  local FIRST = Y + 2
  local BAR_X = X + W - 14      -- leaves room for the number after it
  local accent = def.accent or colors.lightBlue
  local sel = 1

  local function knobAt(row)
    local i = row - #ACTIONS
    if i >= 1 and i <= #KNOBS then return KNOBS[i] end
    return nil
  end

  local function setKnob(knob, value)
    if value < 0 then value = 0 elseif value > 10 then value = 10 end
    if value == data.get(knob.key) then return end
    data.set(knob.key, value)
    audio.volumes[knob.field] = value / 10
    audio.play("ui.move")
  end

  local function nudge(knob, dir)
    setKnob(knob, data.get(knob.key) + dir)
  end

  local function draw()
    gfx.panel(X, Y, W, H, colors.gray, " Paused ", colors.white, accent)
    for i = 1, #ACTIONS do
      local y = FIRST + i - 1
      local on = (sel == i)
      gfx.fill(X + 1, y, W - 2, 1, on and accent or colors.gray)
      gfx.text(X + 2, y, ACTIONS[i],
        on and gfx.contrast(accent) or colors.white, on and accent or colors.gray)
    end
    for i = 1, #KNOBS do
      local row = #ACTIONS + i
      local y = FIRST + row - 1
      local on = (sel == row)
      local bg = on and accent or colors.gray
      gfx.fill(X + 1, y, W - 2, 1, bg)
      gfx.text(X + 2, y, KNOBS[i].label, on and gfx.contrast(accent) or colors.white, bg)
      -- Three bars stacked with nothing between them read as one slab, so
      -- each carries its number: that is what makes a level legible at a
      -- glance rather than something you have to measure.
      local level = data.get(KNOBS[i].key)
      gfx.bar(BAR_X, y, 10, level / 10,
        on and gfx.contrast(accent) or colors.lime, on and accent or colors.black)
      gfx.right(X + W - 2, y, string.format("%2d", level),
        on and gfx.contrast(accent) or colors.white, bg)
    end
    local y = FIRST + QUIT - 1
    local on = (sel == QUIT)
    gfx.fill(X + 1, y, W - 2, 1, on and colors.red or colors.gray)
    gfx.text(X + 2, y, "Quit to menu",
      on and colors.white or colors.lightGray, on and colors.red or colors.gray)
    gfx.center(Y + H - 1, gfx.clip(def.name, W - 4), colors.lightGray, colors.gray, X, W)
  end

  --- Screens are opened by the loop below rather than from inside the event
  --- handler: ui.loop nested inside another ui.loop's handler would swallow
  --- the outer loop's pump timer, and the outer loop would quietly stop
  --- driving the music.
  local function activate()
    if sel == 1 then return "resume" end
    if sel == 2 then return "restart" end
    if sel == 3 then return "controls" end
    if sel == 4 then return "trophies" end
    if sel == QUIT then return "quit" end
    local knob = knobAt(sel)
    if knob then nudge(knob, 1) end
    return nil
  end

  local function handle(ev)
    local name = ev[1]
    if name == "key" then
      local k = ev[2]
      if k == keys.up or k == keys.w then
        sel = sel > 1 and sel - 1 or ROWS
        audio.play("ui.move")
      elseif k == keys.down or k == keys.s then
        sel = sel < ROWS and sel + 1 or 1
        audio.play("ui.move")
      elseif k == keys.left or k == keys.a then
        local knob = knobAt(sel)
        if knob then nudge(knob, -1) end
      elseif k == keys.right or k == keys.d then
        local knob = knobAt(sel)
        if knob then nudge(knob, 1) end
      elseif k == keys.enter or k == keys.space or k == keys.numPadEnter then
        return activate()
      elseif k == keys.p or k == keys.q or k == keys.backspace then
        return "resume"
      end

    elseif name == "mouse_scroll" then
      local _, my = ui.toLocal(ev[3], ev[4])
      local row = my - FIRST + 1
      local knob = knobAt(row)
      if knob then
        sel = row
        nudge(knob, ev[2] > 0 and 1 or -1)
      end

    elseif name == "mouse_click" or name == "mouse_drag" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      local row = my - FIRST + 1
      local knob = knobAt(row)
      -- clicking or dragging along a bar sets that level directly
      if knob and mx >= BAR_X - 1 and mx < BAR_X + 10 then
        sel = row
        setKnob(knob, mx - BAR_X + 1)
        return nil
      end
      if name == "mouse_drag" then return nil end
      if ev[2] == 2 then return "resume" end
      if row >= 1 and row <= ROWS and mx > X and mx < X + W - 1 then
        if row == sel then return activate() end
        sel = row
        audio.play("ui.move")
      elseif mx < X or mx >= X + W or my < Y or my >= Y + H then
        return "resume"
      end
    end
    return nil
  end

  while true do
    local result = ui.loop(draw, handle)
    if ui.terminated then return "quit" end
    if result == "controls" then
      ui.controls(def)
    elseif result == "trophies" then
      api.require("os.trophies").run(api)
    elseif result == "restart" or result == "quit" then
      data.flush()
      return result
    else
      data.flush()
      return "resume"          -- "resume", 0 from a cancel, or anything odd
    end
    if ui.terminated then return "quit" end
  end
end

-------------------------------------------------------------- trophies
--- Console-wide trophies, checked after every session.
local GLOBAL = {
  {
    id = "os_collector", name = "Collector", desc = "Play every game once",
    test = function(api)
      for _, g in ipairs(api.games) do
        if data.stats(g.id).plays < 1 then return false end
      end
      return #api.games > 0
    end,
  },
  {
    id = "os_hour", name = "Time Sink", desc = "One hour of total play",
    test = function() return data.totalSeconds() >= 3600 end,
  },
  {
    id = "os_century", name = "Century", desc = "Start a hundred games",
    test = function() return data.totalPlays() >= 100 end,
  },
}
runtime.globalTrophies = GLOBAL

--- Evaluate a game's trophies against a finished instance plus the
--- console-wide ones. Returns the list that was newly earned.
local function awardTrophies(def, inst, api)
  local won = {}
  local function consider(entry, arg)
    if data.hasTrophy(entry.id) then return end
    local ok, earned = pcall(entry.test, arg)
    if ok and earned and data.awardTrophy(entry.id) then
      won[#won + 1] = entry
    end
  end
  if def.trophies then
    for _, entry in ipairs(def.trophies) do consider(entry, inst) end
  end
  for _, entry in ipairs(GLOBAL) do consider(entry, api) end
  return won
end

---------------------------------------------------------------- trophy toast
--- Consoles announce an achievement the moment it happens, not in a summary
--- afterwards, because the announcement is the reward. GameOS used to list
--- them only on the game-over card, which meant a trophy earned in the first
--- minute went unmentioned until the run was over.
---
--- awardTrophies is already idempotent -- it skips anything held -- so it can
--- simply be run during play and whatever it returns is newly earned.
local TROPHY_ICON = gfx.makeGlyph({
  "..######..",
  "..######..",
  "#..####..#",
  "#..####..#",
  ".#.####.#.",
  "...####...",
  "..######..",
  ".########.",
})

local Toasts = {}
Toasts.__index = Toasts

local function newToasts()
  return setmetatable({ queue = {}, showing = nil, t = 0 }, Toasts)
end

function Toasts:add(entry) self.queue[#self.queue + 1] = entry end

function Toasts:update(dt)
  if not self.showing then
    if #self.queue == 0 then return end
    self.showing = table.remove(self.queue, 1)
    self.t = 0
    audio.play("ui.trophy")
    return
  end
  self.t = self.t + dt
  if self.t > 3.0 then
    self.showing = nil
    self.t = 0
  end
end

function Toasts:draw()
  local entry = self.showing
  if not entry then return end
  local w = 24
  -- slide in, hold, slide out, so it never simply blinks into existence
  local slide
  if self.t < 0.25 then
    slide = 1 - self.t / 0.25
  elseif self.t > 2.75 then
    slide = (self.t - 2.75) / 0.25
  else
    slide = 0
  end
  local x = gfx.W - w + floor(slide * (w + 1) + 0.5)
  if x > gfx.W then return end

  gfx.fill(x, 2, w, 4, colors.gray)
  gfx.blitGlyph(x + 1, 3, TROPHY_ICON, colors.yellow, colors.gray)
  gfx.text(x + 7, 3, gfx.clip("TROPHY", w - 8), colors.yellow, colors.gray)
  gfx.text(x + 7, 4, gfx.clip(entry.name, w - 8), colors.white, colors.gray)
end

------------------------------------------------------------ game over card
local function gameOverCard(def, inst, rank, best, trophies)
  local summary = {}
  if inst.summary then
    local ok, rows = pcall(inst.summary, inst)
    if ok and type(rows) == "table" then summary = rows end
  end
  if #summary > 4 then
    for i = #summary, 5, -1 do summary[i] = nil end
  end

  local won = inst.won and true or false
  local title = won and "YOU WIN" or "GAME OVER"
  local accent = won and colors.lime or (def.accent or colors.red)
  if rank == 1 then
    title = "RECORD!"
    accent = colors.yellow
  end

  trophies = trophies or {}
  -- 44 cells wide is what "GAME OVER" needs at double scale in the pixel font
  local w = 44
  local h = 10 + #summary + #trophies
  local x = floor((gfx.W - w) / 2) + 1
  local y = floor((gfx.H - h) / 2) + 1

  local titleCanvas = Canvas.new(x + 1, y, w - 2, 4, colors.gray)
  local buttons = { "Retry", "Menu" }
  local sel = 1
  local blink = 0
  local rects

  local function draw()
    gfx.fill(x + 1, y + 1, w, h, colors.black)
    gfx.fill(x, y, w, h, colors.gray)

    titleCanvas:clear(colors.gray)
    local flash = (rank == 1 and floor(blink * 3) % 2 == 1) and colors.white or accent
    font.centerShadow(titleCanvas, 2, title, flash, colors.black, 2, 1)
    titleCanvas:render()

    local iy = y + 5
    gfx.fill(x + 2, iy, w - 4, 1, colors.gray)
    if not inst.noScore then
      gfx.text(x + 3, iy, def.scoreLabel or "SCORE", colors.lightGray, colors.gray)
      gfx.right(x + w - 3, iy, gfx.commas(inst.score or 0), accent, colors.gray)
      gfx.text(x + 3, iy + 1, "BEST", colors.lightGray, colors.gray)
      gfx.right(x + w - 3, iy + 1, gfx.commas(best), colors.white, colors.gray)
    else
      gfx.center(iy, def.scoreLabel or "", colors.lightGray, colors.gray, x, w)
    end

    for i = 1, #summary do
      local row = summary[i]
      local ry = iy + 2 + (i - 1)
      gfx.text(x + 3, ry, gfx.clip(tostring(row[1]), 16), colors.lightGray, colors.gray)
      gfx.right(x + w - 3, ry, gfx.clip(tostring(row[2]), 12), colors.white, colors.gray)
    end

    local ry = iy + 2 + #summary
    for i = 1, #trophies do
      local flash = floor(blink * 3) % 2 == 0 and colors.yellow or colors.white
      gfx.fill(x + 2, ry, w - 4, 1, colors.gray)
      gfx.text(x + 3, ry, "TROPHY", flash, colors.gray)
      gfx.right(x + w - 3, ry, gfx.clip(trophies[i].name, 22), colors.white, colors.gray)
      ry = ry + 1
    end
    if rank and rank > 1 then
      gfx.center(ry, "ranked #" .. rank, colors.lightGray, colors.gray, x, w)
    end

    rects = {}
    local total = 0
    for i = 1, #buttons do total = total + #buttons[i] + 4 end
    total = total + 2
    local bx = x + floor((w - total) / 2)
    local by = y + h - 2
    for i = 1, #buttons do
      local bw = #buttons[i] + 4
      rects[i] = { x = bx, y = by, w = bw }
      local on = (i == sel)
      local bbg = on and accent or colors.lightGray
      gfx.fill(bx, by, bw, 1, bbg)
      gfx.center(by, buttons[i], on and gfx.contrast(accent) or colors.gray, bbg, bx, bw)
      bx = bx + bw + 2
    end
  end

  local function handle(ev)
    local name = ev[1]
    if name == "key" then
      local k = ev[2]
      if k == keys.left or k == keys.a then
        sel = sel > 1 and sel - 1 or #buttons
        audio.play("ui.move")
      elseif k == keys.right or k == keys.d or k == keys.tab then
        sel = sel < #buttons and sel + 1 or 1
        audio.play("ui.move")
      elseif k == keys.enter or k == keys.space or k == keys.numPadEnter then
        audio.play("ui.select")
        return sel
      elseif k == keys.r then
        audio.play("ui.select")
        return 1
      elseif k == keys.backspace or k == keys.q then
        audio.play("ui.back")
        return 2
      end
    elseif name == "mouse_click" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      for i = 1, #rects do
        local r = rects[i]
        if my == r.y and mx >= r.x and mx < r.x + r.w then
          audio.play("ui.select")
          return i
        end
      end
    end
    return nil
  end

  -- animate the record flash while waiting
  local pump = os.startTimer(0.12)
  while true do
    gfx.beginFrame()
    draw()
    gfx.endFrame()
    local ev = { os.pullEventRaw() }
    if ev[1] == "timer" and ev[2] == pump then
      pump = os.startTimer(0.12)
      blink = blink + 0.12
      audio.update(os.clock())
    elseif ev[1] == "terminate" then
      return 2
    else
      local r = handle(ev)
      if r then
        os.cancelTimer(pump)
        return r
      end
    end
  end
end

----------------------------------------------------------------- one session
--- Returns "retry" or "menu".
local function session(def, api, mode)
  local ok, inst = pcall(def.new, api, mode)
  if not ok or type(inst) ~= "table" then
    return crash(def, ok and "new() returned no instance" or inst)
  end

  input.reset()
  -- Simon asks you to listen, so it is the one game that runs in silence
  if def.music then audio.playMusic(def.music) else audio.stopMusic() end
  audio.play("ui.launch")

  local startClock = os.clock()
  local last = startClock
  local timer = os.startTimer(TICK)
  local showFps = data.get("showFps")
  local fpsAcc, fpsFrames, fps = 0, 0, 0
  local outcome = nil

  --- Every way out of the loop below has to release whatever the game took
  --- hold of. That matters most for a networked match: leaving without
  --- disposing keeps the modem channels open and, worse, denies the other
  --- console the goodbye that would end its match cleanly instead of after a
  --- five second timeout.
  local released = false
  local function release()
    if released then return end       -- disposing twice would be a surprise
    released = true
    if inst.dispose then pcall(inst.dispose, inst) end
  end
  local function bail(err)
    release()
    return crash(def, err)
  end

  local toasts = newToasts()
  local trophyTimer = 0
  local earned = {}          -- everything won this session, for the card

  while not outcome do
    local ev = { os.pullEventRaw() }
    local name = ev[1]

    if name == "timer" and ev[2] == timer then
      timer = os.startTimer(TICK)
      local nowClock = os.clock()
      local dt = nowClock - last
      last = nowClock
      if dt <= 0 then dt = TICK end
      if dt > 0.25 then dt = 0.25 end
      audio.update(nowClock)

      local uok, uerr = pcall(inst.update, inst, dt)
      if not uok then return bail(uerr) end

      -- Twice a second is often enough to feel immediate and rare enough
      -- that the predicates cost nothing.
      trophyTimer = trophyTimer + dt
      if trophyTimer >= 0.5 then
        trophyTimer = 0
        local fresh = awardTrophies(def, inst, api)
        for i = 1, #fresh do
          earned[#earned + 1] = fresh[i]
          toasts:add(fresh[i])
        end
      end
      toasts:update(dt)

      gfx.beginFrame()
      local dok, derr = pcall(inst.draw, inst)
      if not dok then
        gfx.endFrame()
        return bail(derr)
      end
      if showFps then
        fpsAcc = fpsAcc + dt
        fpsFrames = fpsFrames + 1
        if fpsAcc >= 0.5 then
          fps = floor(fpsFrames / fpsAcc + 0.5)
          fpsAcc, fpsFrames = 0, 0
        end
        gfx.right(gfx.W, 1, string.format("%2d", fps), colors.lime, colors.black)
      end
      toasts:draw()
      gfx.endFrame()
      input.endFrame()

      if inst.quit then
        outcome = "abandon"
      elseif inst.finished then
        outcome = "over"
      end

    elseif name == "key" then
      local k, held = ev[2], ev[3]
      -- A networked game cannot afford a blocking pause menu: the event loop
      -- stops, heartbeats stop with it, and the other console decides we
      -- dropped out. Such a game sets suppressPause and draws its own overlay
      -- instead, which keeps the link alive.
      if k == keys.p and not held and not inst.suppressPause then
        local choice = pauseMenu(def, api)
        input.reset()
        os.cancelTimer(timer)
        timer = os.startTimer(TICK)
        last = os.clock()
        if choice == "restart" then
          release()
          return "retry"
        elseif choice == "quit" then
          outcome = "abandon"
        end
      else
        input.onKey(k, held)
        if inst.onKey then
          local kok, kerr = pcall(inst.onKey, inst, k, held)
          if not kok then return bail(kerr) end
        end
      end

    elseif name == "key_up" then
      input.onKeyUp(ev[2])

    elseif name == "char" then
      input.onChar(ev[2])
      if inst.onChar then pcall(inst.onChar, inst, ev[2]) end

    elseif name == "mouse_click" or name == "mouse_up" or name == "mouse_drag" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      input.onMouse(name, ev[2], mx, my)
      if inst.onMouse then
        local mok, merr = pcall(inst.onMouse, inst, name, ev[2], mx, my)
        if not mok then return bail(merr) end
      end

    elseif name == "mouse_scroll" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      if inst.onMouse then pcall(inst.onMouse, inst, "mouse_scroll", ev[2], mx, my) end

    elseif name == "monitor_touch" then
      -- A touch has no press-and-release pair, so send both halves at once:
      -- games that wait for the release (2048's swipe) would otherwise never
      -- see the gesture finish on an advanced monitor.
      local mx, my = ui.toLocal(ev[3], ev[4])
      input.onMouse("mouse_click", 1, mx, my)
      if inst.onMouse then
        pcall(inst.onMouse, inst, "mouse_click", 1, mx, my)
        pcall(inst.onMouse, inst, "mouse_up", 1, mx, my)
      end

    elseif name == "term_resize" then
      if not gfx.handleResize() then outcome = "abandon" end

    elseif name == "terminate" then
      outcome = "abandon"

    elseif inst.onEvent then
      -- Anything the console itself does not consume -- modem traffic above
      -- all -- is offered to the game whole.
      local eok, eerr = pcall(inst.onEvent, inst, ev)
      if not eok then return bail(eerr) end
    end
  end

  os.cancelTimer(timer)
  -- Give the game a chance to let go of anything outside itself -- an open
  -- modem channel, above all -- before the session is torn down.
  release()
  audio.stopMusic()
  local elapsed = os.clock() - startClock
  data.recordPlay(def.id, elapsed)

  -- Anything the periodic check has not seen yet -- a trophy for finishing,
  -- above all -- plus everything already toasted, so the card is complete.
  local trophies = awardTrophies(def, inst, api)
  for i = 1, #earned do trophies[#trophies + 1] = earned[i] end

  if outcome == "abandon" then
    data.flush()
    return "menu"
  end

  local rank = nil
  if not inst.noScore then
    rank = data.submit(def.id, inst.score or 0, def.lowerIsBetter)
  end
  local best = data.best(def.id)

  audio.play(inst.won and "result.win" or "result.lose")
  if #trophies > 0 then audio.play("ui.trophy") end

  -- a new number one earns the arcade name entry
  if rank == 1 and (inst.score or 0) > 0 then
    local previous = data.scores(def.id)[2]
    local who = ui.initials(" " .. def.name .. " ", def.accent or colors.yellow,
      previous and previous.who)
    data.nameScore(def.id, 1, who)
  end
  data.flush()

  local choice = gameOverCard(def, inst, rank, best, trophies)
  return choice == 1 and "retry" or "menu"
end

--------------------------------------------------------------------- entry
function runtime.play(def, api)
  local mode = nil
  if def.modes and #def.modes > 0 then
    if #def.modes == 1 then
      mode = def.modes[1]
    else
      local items = {}
      for i = 1, #def.modes do
        items[i] = { label = def.modes[i].name, hint = def.modes[i].hint }
      end
      local prog = data.progress(def.id)
      local pick = ui.picker({
        title = " " .. def.name .. " ",
        items = items,
        accent = def.accent or colors.lightBlue,
        default = prog.lastMode or 1,
        width = 32,
        footer = "Enter to start, Q to go back",
      })
      if pick == 0 then return end
      mode = def.modes[pick]
      prog.lastMode = pick
      data.markDirty()
    end
  end

  -- A game may need to ask something extra before it starts (Sokoban's level
  -- select). That happens here rather than inside new(), so constructing an
  -- instance never blocks on a dialog.
  if def.configure then
    local ok, adjusted = pcall(def.configure, api, mode)
    if not ok then
      crash(def, adjusted)
      return
    end
    if adjusted == false then return end
    if type(adjusted) == "table" then mode = adjusted end
  end

  local prog = data.progress(def.id)
  if not prog.seenControls and def.controls and #def.controls > 0 then
    ui.controls(def)
    prog.seenControls = true
    data.markDirty()
  end

  while true do
    local again = session(def, api, mode)
    if again ~= "retry" then break end
    if ui.terminated then break end
  end
  data.flush()
end

return runtime
