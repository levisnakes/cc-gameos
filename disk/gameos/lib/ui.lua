--[[ ui -- modal dialogs and list pickers shared by the shell and the runtime.

  Dialogs are blocking: they draw on top of whatever is already in the frame
  buffer and run their own event loop until dismissed. The caller is expected
  to redraw its own screen afterwards.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")

local ui = {}

ui.terminated = false

local floor = math.floor

------------------------------------------------------------------- chrome
--- Dialog shell: shadow, body, title bar. Returns the inner content rect.
function ui.frame(x, y, w, h, title, accent)
  accent = accent or colors.blue
  gfx.fill(x + 1, y + 1, w, h, colors.black)
  gfx.fill(x, y, w, h, colors.gray)
  if title then
    gfx.fill(x, y, w, 1, accent)
    gfx.center(y, title, gfx.contrast(accent), accent, x, w)
    return x + 2, y + 2, w - 4, h - 3
  end
  return x + 2, y + 1, w - 4, h - 2
end

local function buttonRects(buttons, x0, w, y)
  local widths, total = {}, 0
  for i = 1, #buttons do
    widths[i] = #buttons[i] + 2
    total = total + widths[i]
  end
  total = total + 2 * (#buttons - 1)
  local x = x0 + floor((w - total) / 2)
  local rects = {}
  for i = 1, #buttons do
    rects[i] = { x = x, y = y, w = widths[i], label = buttons[i] }
    x = x + widths[i] + 2
  end
  return rects
end

local function drawButtons(rects, selected, accent)
  for i = 1, #rects do
    local r = rects[i]
    local on = (i == selected)
    local bg = on and accent or colors.lightGray
    gfx.fill(r.x, r.y, r.w, 1, bg)
    gfx.center(r.y, r.label, on and gfx.contrast(accent) or colors.gray, bg, r.x, r.w)
  end
end

local function hitTest(rects, x, y)
  for i = 1, #rects do
    local r = rects[i]
    if y == r.y and x >= r.x and x < r.x + r.w then return i end
  end
  return nil
end

--- Screen coordinates -> design-surface coordinates.
function ui.toLocal(x, y)
  return x - (gfx.offX or 0), y - (gfx.offY or 0)
end

-------------------------------------------------------------- generic loop
--- Runs draw/handle until handle returns non-nil. Pumps audio so queued
--- effects keep playing while a dialog is open.
function ui.loop(draw, handle)
  local pump = os.startTimer(0.1)
  while true do
    gfx.beginFrame()
    draw()
    gfx.endFrame()
    local ev = { os.pullEventRaw() }
    local name = ev[1]
    if name == "timer" and ev[2] == pump then
      pump = os.startTimer(0.1)
      audio.update(os.clock())
    elseif name == "terminate" then
      ui.terminated = true
      return 0
    else
      local result = handle(ev)
      if result ~= nil then
        os.cancelTimer(pump)
        return result
      end
    end
  end
end

------------------------------------------------------------------- dialogs
--- opts: title, body (list of strings), buttons (list), accent, default,
---       width, cancel (index returned on back / 0 to disallow)
function ui.dialog(opts)
  local title = opts.title
  local body = opts.body or {}
  local buttons = opts.buttons or { "OK" }
  local accent = opts.accent or colors.lightBlue
  local sel = opts.default or 1

  local w = opts.width or 0
  if w == 0 then
    if title then w = #title + 6 end
    for i = 1, #body do if #body[i] + 6 > w then w = #body[i] + 6 end end
    local btotal = 0
    for i = 1, #buttons do btotal = btotal + #buttons[i] + 4 end
    if btotal + 4 > w then w = btotal + 4 end
    if w < 22 then w = 22 end
    if w > 45 then w = 45 end
  end
  local h = 2 + #body + 2
  if h > gfx.H - 2 then h = gfx.H - 2 end
  local x = floor((gfx.W - w) / 2) + 1
  local y = floor((gfx.H - h) / 2) + 1

  local rects
  local function draw()
    local ix, iy, iw = ui.frame(x, y, w, h, title, accent)
    for i = 1, #body do
      gfx.center(iy + i - 1, gfx.clip(body[i], iw), colors.white, colors.gray, ix, iw)
    end
    rects = buttonRects(buttons, x, w, y + h - 2)
    drawButtons(rects, sel, accent)
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
      elseif k == keys.backspace or k == keys.q then
        if opts.cancel ~= 0 then
          audio.play("ui.back")
          return opts.cancel or 0
        end
      end
    elseif name == "mouse_click" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      local i = hitTest(rects, mx, my)
      if i then
        sel = i
        audio.play("ui.select")
        return i
      end
    end
    return nil
  end

  return ui.loop(draw, handle)
end

function ui.alert(title, body, accent)
  if type(body) == "string" then body = { body } end
  return ui.dialog({ title = title, body = body, buttons = { "OK" }, accent = accent })
end

function ui.confirm(title, body, yes, no, accent)
  if type(body) == "string" then body = { body } end
  local r = ui.dialog({
    title = title, body = body, accent = accent or colors.orange,
    buttons = { yes or "Yes", no or "No" }, default = 2, cancel = 2,
  })
  return r == 1
end

------------------------------------------------------------------- pickers
--- opts: title, items (list of {label, hint} or strings), accent, default,
---       width, rows, footer
function ui.picker(opts)
  local items = opts.items or {}
  local accent = opts.accent or colors.lightBlue
  local sel = opts.default or 1
  if sel > #items then sel = 1 end

  local function labelOf(i)
    local it = items[i]
    if type(it) == "string" then return it end
    return it.label or "?"
  end
  local function hintOf(i)
    local it = items[i]
    if type(it) == "table" then return it.hint end
    return nil
  end

  local w = opts.width or 0
  if w == 0 then
    if opts.title then w = #opts.title + 6 end
    for i = 1, #items do
      local n = #labelOf(i) + 6
      local hint = hintOf(i)
      if hint then n = n + #hint + 2 end
      if n > w then w = n end
    end
    if w < 24 then w = 24 end
    if w > 45 then w = 45 end
  end

  local rows = opts.rows or #items
  if rows > 11 then rows = 11 end
  if rows > #items then rows = #items end
  if rows < 1 then rows = 1 end
  local h = 3 + rows + (opts.footer and 1 or 0)
  local x = floor((gfx.W - w) / 2) + 1
  local y = floor((gfx.H - h) / 2) + 1
  local top = 1

  local function clampView()
    if sel < top then top = sel end
    if sel > top + rows - 1 then top = sel - rows + 1 end
    if top > #items - rows + 1 then top = #items - rows + 1 end
    if top < 1 then top = 1 end
  end

  local function draw()
    clampView()
    local ix, iy, iw = ui.frame(x, y, w, h, opts.title, accent)
    for r = 0, rows - 1 do
      local i = top + r
      local ry = iy + r
      if i <= #items then
        local on = (i == sel)
        local bg = on and accent or colors.gray
        local fg = on and gfx.contrast(accent) or colors.white
        gfx.fill(ix - 1, ry, iw + 2, 1, bg)
        gfx.text(ix, ry, gfx.clip(labelOf(i), iw), fg, bg)
        local hint = hintOf(i)
        if hint then
          gfx.right(ix + iw - 1, ry, gfx.clip(hint, 12), on and gfx.contrast(accent) or colors.lightGray, bg)
        end
      end
    end
    if #items > rows then
      local barY = iy + floor((sel - 1) / #items * rows)
      gfx.fill(x + w - 1, iy, 1, rows, colors.black)
      gfx.fill(x + w - 1, barY, 1, 1, accent)
    end
    if opts.footer then
      gfx.center(y + h - 1, gfx.clip(opts.footer, w - 2), colors.lightGray, colors.gray, x, w)
    end
  end

  local function handle(ev)
    local name = ev[1]
    if name == "key" then
      local k = ev[2]
      if k == keys.up or k == keys.w then
        sel = sel > 1 and sel - 1 or #items
        audio.play("ui.move")
      elseif k == keys.down or k == keys.s then
        sel = sel < #items and sel + 1 or 1
        audio.play("ui.move")
      elseif k == keys.pageUp then
        sel = math.max(1, sel - rows)
      elseif k == keys.pageDown then
        sel = math.min(#items, sel + rows)
      elseif k == keys.home then
        sel = 1
      elseif k == keys["end"] then
        sel = #items
      elseif k == keys.enter or k == keys.space or k == keys.numPadEnter then
        audio.play("ui.select")
        return sel
      elseif k == keys.backspace or k == keys.q then
        audio.play("ui.back")
        return 0
      end
    elseif name == "mouse_scroll" then
      local dir = ev[2]
      sel = math.min(#items, math.max(1, sel + dir))
    elseif name == "mouse_click" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      local row = my - (y + 2)
      if row >= 0 and row < rows and mx >= x and mx < x + w then
        local i = top + row
        if i <= #items then
          if i == sel then
            audio.play("ui.select")
            return i
          end
          sel = i
          audio.play("ui.move")
        end
      elseif mx < x or mx >= x + w or my < y or my >= y + h then
        audio.play("ui.back")
        return 0
      end
    end
    return nil
  end

  return ui.loop(draw, handle)
end

------------------------------------------------------------- transition
--- Bars sweep in from both edges, meet, and sweep out again. Used between
--- the launcher and a game so screens do not just snap.
function ui.transition(accent)
  accent = accent or colors.lightBlue
  local half = math.ceil(gfx.W / 2)
  local steps = 7
  local timer = os.startTimer(0.03)
  local step = 0
  local closing = true
  while true do
    local ev = { os.pullEventRaw() }
    if ev[1] == "terminate" then return end
    if ev[1] == "timer" and ev[2] == timer then
      timer = os.startTimer(0.03)
      step = step + 1
      local k = step / steps
      if k > 1 then
        if closing then
          closing = false
          step = 0
        else
          os.cancelTimer(timer)
          return
        end
        k = 1
      end
      local width = closing and floor(half * k) or floor(half * (1 - k))
      gfx.beginFrame()
      if closing then
        gfx.fill(1, 1, width, gfx.H, accent)
        gfx.fill(gfx.W - width + 1, 1, width, gfx.H, accent)
      else
        gfx.clear(colors.black)
        gfx.fill(1, 1, width, gfx.H, accent)
        gfx.fill(gfx.W - width + 1, 1, width, gfx.H, accent)
      end
      gfx.endFrame()
    end
  end
end

--------------------------------------------------------------- name entry
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .-!"

--- Arcade style three-letter entry for a new number one score.
function ui.initials(title, accent, previous)
  accent = accent or colors.yellow
  local letters = { 1, 1, 1 }
  if previous and #previous >= 3 then
    for i = 1, 3 do
      local at = ALPHABET:find(previous:sub(i, i), 1, true)
      letters[i] = at or 1
    end
  end
  local slot = 1
  local blink = 0

  local w, h = 30, 8
  local x = floor((gfx.W - w) / 2) + 1
  local y = floor((gfx.H - h) / 2) + 1

  local function text()
    local out = {}
    for i = 1, 3 do out[i] = ALPHABET:sub(letters[i], letters[i]) end
    return table.concat(out)
  end

  local function draw()
    local ix, iy, iw = ui.frame(x, y, w, h, title, accent)
    gfx.center(iy, "new record -- your initials", colors.lightGray, colors.gray, ix, iw)
    local slotW = 5
    local total = slotW * 3 + 4
    local bx = x + floor((w - total) / 2)
    for i = 1, 3 do
      local sx = bx + (i - 1) * (slotW + 2)
      local on = (i == slot)
      local bg = on and accent or colors.lightGray
      gfx.fill(sx, iy + 2, slotW, 3, bg)
      local ch = ALPHABET:sub(letters[i], letters[i])
      gfx.center(iy + 3, ch, on and gfx.contrast(accent) or colors.gray, bg, sx, slotW)
      if on and floor(blink * 3) % 2 == 0 then
        gfx.fill(sx, iy + 2, slotW, 1, colors.white)
      end
    end
    gfx.center(y + h - 1, "Up/Dn letter   Enter done", colors.lightGray, colors.gray, x, w)
  end

  local function handle(ev)
    if ev[1] ~= "key" and ev[1] ~= "char" then return nil end
    if ev[1] == "char" then
      local at = ALPHABET:find(ev[2]:upper(), 1, true)
      if at then
        letters[slot] = at
        if slot < 3 then slot = slot + 1 end
        audio.play("ui.move")
      end
      return nil
    end
    local k = ev[2]
    if k == keys.up or k == keys.w then
      letters[slot] = letters[slot] % #ALPHABET + 1
      audio.play("ui.move")
    elseif k == keys.down or k == keys.s then
      letters[slot] = (letters[slot] - 2) % #ALPHABET + 1
      audio.play("ui.move")
    elseif k == keys.left or k == keys.a then
      slot = slot > 1 and slot - 1 or 3
    elseif k == keys.right or k == keys.d or k == keys.tab then
      slot = slot < 3 and slot + 1 or 1
    elseif k == keys.backspace then
      letters[slot] = 1
    elseif k == keys.enter or k == keys.numPadEnter or k == keys.space then
      audio.play("ui.select")
      return text()
    end
    return nil
  end

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
      return text()
    else
      local result = handle(ev)
      if result then
        os.cancelTimer(pump)
        return result
      end
    end
  end
end

--------------------------------------------------------------- controls card
function ui.controls(def)
  local list = def.controls or {}
  local w = 40
  local h = 3 + #list + 2
  if h > gfx.H then h = gfx.H end
  local x = floor((gfx.W - w) / 2) + 1
  local y = floor((gfx.H - h) / 2) + 1
  local accent = def.accent or colors.lightBlue

  local function draw()
    local ix, iy, iw = ui.frame(x, y, w, h, " " .. def.name .. " -- Controls ", accent)
    for i = 1, #list do
      local row = list[i]
      local key, what = row[1], row[2]
      gfx.text(ix, iy + i - 1, gfx.clip(key, 15), accent, colors.gray)
      gfx.text(ix + 16, iy + i - 1, gfx.clip(what, iw - 16), colors.white, colors.gray)
    end
    gfx.center(y + h - 2, "press any key", colors.lightGray, colors.gray, x, w)
  end

  local function handle(ev)
    if ev[1] == "key" or ev[1] == "mouse_click" then return 1 end
    return nil
  end

  return ui.loop(draw, handle)
end

return ui
