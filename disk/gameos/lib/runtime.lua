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
local function pauseMenu(def, api)
  audio.play("ui.back")
  while true do
    local items = {
      { label = "Resume" },
      { label = "Restart" },
      { label = "Controls" },
      { label = "Volume", hint = math.floor(audio.volumes.master * 10) .. "/10" },
      { label = "Quit to menu" },
    }
    local pick = ui.picker({
      title = " Paused ",
      items = items,
      accent = def.accent or colors.lightBlue,
      width = 28,
      footer = def.name,
    })
    if pick == 0 or pick == 1 then return "resume" end
    if pick == 2 then return "restart" end
    if pick == 3 then
      ui.controls(def)
    elseif pick == 4 then
      -- step the master knob down and wrap, so it is adjustable mid-game
      local step = math.floor(audio.volumes.master * 10 + 0.5) - 2
      if step < 0 then step = 10 end
      audio.volumes.master = step / 10
      data.set("volMaster", step)
      audio.play("ui.select")
    elseif pick == 5 then
      return "quit"
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
      if not uok then return crash(def, uerr) end

      gfx.beginFrame()
      local dok, derr = pcall(inst.draw, inst)
      if not dok then
        gfx.endFrame()
        return crash(def, derr)
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
      gfx.endFrame()
      input.endFrame()

      if inst.quit then
        outcome = "abandon"
      elseif inst.finished then
        outcome = "over"
      end

    elseif name == "key" then
      local k, held = ev[2], ev[3]
      if k == keys.p and not held then
        local choice = pauseMenu(def, api)
        input.reset()
        os.cancelTimer(timer)
        timer = os.startTimer(TICK)
        last = os.clock()
        if choice == "restart" then
          return "retry"
        elseif choice == "quit" then
          outcome = "abandon"
        end
      else
        input.onKey(k, held)
        if inst.onKey then
          local kok, kerr = pcall(inst.onKey, inst, k, held)
          if not kok then return crash(def, kerr) end
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
        if not mok then return crash(def, merr) end
      end

    elseif name == "mouse_scroll" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      if inst.onMouse then pcall(inst.onMouse, inst, "mouse_scroll", ev[2], mx, my) end

    elseif name == "monitor_touch" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      input.onMouse("mouse_click", 1, mx, my)
      if inst.onMouse then pcall(inst.onMouse, inst, "mouse_click", 1, mx, my) end

    elseif name == "term_resize" then
      if not gfx.handleResize() then outcome = "abandon" end

    elseif name == "terminate" then
      outcome = "abandon"
    end
  end

  os.cancelTimer(timer)
  audio.stopMusic()
  local elapsed = os.clock() - startClock
  data.recordPlay(def.id, elapsed)

  local trophies = awardTrophies(def, inst, api)

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
