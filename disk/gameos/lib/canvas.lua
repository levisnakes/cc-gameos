--[[ canvas -- a square-pixel framebuffer on top of the terminal.

  Each character cell holds a 2x3 grid of sub-pixels, so a full 51x19 screen
  becomes 102x57 pixels that are square on screen (3x3 real pixels each).

  A cell can only carry two colours, so on render each cell picks its two most
  common sub-pixel colours; anything else in that cell is folded into the
  foreground. Blocky game art stays exact, gradients degrade gracefully.
]]

local Canvas = {}
Canvas.__index = Canvas

local floor = math.floor
local schar = string.char
local concat = table.concat

local BLIT = {}
do
  local hex = "0123456789abcdef"
  local c = 1
  for i = 1, 16 do BLIT[c] = hex:sub(i, i) c = c * 2 end
end

--- Create a canvas occupying a character rectangle of the 51x19 screen.
function Canvas.new(cx, cy, cw, ch, clearColour)
  local self = setmetatable({}, Canvas)
  self.cx, self.cy = cx, cy
  self.cw, self.ch = cw, ch
  self.w, self.h = cw * 2, ch * 3
  self.bg = clearColour or colors.black
  self.px = {}
  local px = self.px
  for i = 1, self.w * self.h do px[i] = self.bg end
  self._c, self._f, self._b, self._t = {}, {}, {}, {}
  return self
end

function Canvas:clear(col)
  col = col or self.bg
  local px = self.px
  for i = 1, self.w * self.h do px[i] = col end
end

function Canvas:set(x, y, col)
  x, y = floor(x), floor(y)
  if x < 1 or y < 1 or x > self.w or y > self.h then return end
  self.px[(y - 1) * self.w + x] = col
end

function Canvas:get(x, y)
  x, y = floor(x), floor(y)
  if x < 1 or y < 1 or x > self.w or y > self.h then return nil end
  return self.px[(y - 1) * self.w + x]
end

--- Filled rectangle: top-left (x,y), size w*h, clipped to the canvas.
function Canvas:fill(x, y, w, h, col)
  x, y, w, h = floor(x), floor(y), floor(w), floor(h)
  if w <= 0 or h <= 0 then return end
  local x2, y2 = x + w - 1, y + h - 1
  if x < 1 then x = 1 end
  if y < 1 then y = 1 end
  if x2 > self.w then x2 = self.w end
  if y2 > self.h then y2 = self.h end
  if x > x2 or y > y2 then return end
  local px, W = self.px, self.w
  for yy = y, y2 do
    local base = (yy - 1) * W
    for xx = x, x2 do px[base + xx] = col end
  end
end

function Canvas:box(x, y, w, h, col)
  if w <= 0 or h <= 0 then return end
  self:fill(x, y, w, 1, col)
  self:fill(x, y + h - 1, w, 1, col)
  self:fill(x, y, 1, h, col)
  self:fill(x + w - 1, y, 1, h, col)
end

function Canvas:hline(x, y, w, col) self:fill(x, y, w, 1, col) end
function Canvas:vline(x, y, h, col) self:fill(x, y, 1, h, col) end

function Canvas:line(x0, y0, x1, y1, col)
  x0, y0, x1, y1 = floor(x0), floor(y0), floor(x1), floor(y1)
  local dx = math.abs(x1 - x0)
  local dy = -math.abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx + dy
  local guard = dx - dy + 4
  while guard > 0 do
    guard = guard - 1
    self:set(x0, y0, col)
    if x0 == x1 and y0 == y1 then return end
    local e2 = err + err
    if e2 >= dy then err = err + dy x0 = x0 + sx end
    if e2 <= dx then err = err + dx y0 = y0 + sy end
  end
end

function Canvas:circle(cx, cy, r, col, filled)
  cx, cy, r = floor(cx), floor(cy), floor(r)
  if r < 0 then return end
  local x, y, d = r, 0, 1 - r
  while x >= y do
    if filled then
      self:fill(cx - x, cy + y, x + x + 1, 1, col)
      self:fill(cx - x, cy - y, x + x + 1, 1, col)
      self:fill(cx - y, cy + x, y + y + 1, 1, col)
      self:fill(cx - y, cy - x, y + y + 1, 1, col)
    else
      self:set(cx + x, cy + y, col) self:set(cx - x, cy + y, col)
      self:set(cx + x, cy - y, col) self:set(cx - x, cy - y, col)
      self:set(cx + y, cy + x, col) self:set(cx - y, cy + x, col)
      self:set(cx + y, cy - x, col) self:set(cx - y, cy - x, col)
    end
    y = y + 1
    if d < 0 then
      d = d + 2 * y + 1
    else
      x = x - 1
      d = d + 2 * (y - x) + 1
    end
  end
end

------------------------------------------------------------------- sprites
--- Build a sprite from rows of characters. Characters absent from `map`
--- (or mapped to false) are transparent.
function Canvas.sprite(rows, map)
  local h = #rows
  local w = 0
  for i = 1, h do if #rows[i] > w then w = #rows[i] end end
  local s = { w = w, h = h, px = {} }
  for y = 1, h do
    local row = rows[y]
    for x = 1, w do
      local ch = row:sub(x, x)
      local v = map[ch]
      s.px[(y - 1) * w + x] = v or false
    end
  end
  return s
end

function Canvas:draw(x, y, spr, flipH, flipV)
  x, y = floor(x), floor(y)
  local w, h, sp = spr.w, spr.h, spr.px
  for sy = 1, h do
    local ry = flipV and (h - sy + 1) or sy
    local base = (ry - 1) * w
    local py = y + sy - 1
    if py >= 1 and py <= self.h then
      local rowBase = (py - 1) * self.w
      for sx = 1, w do
        local rx = flipH and (w - sx + 1) or sx
        local col = sp[base + rx]
        if col then
          local pxx = x + sx - 1
          if pxx >= 1 and pxx <= self.w then self.px[rowBase + pxx] = col end
        end
      end
    end
  end
end

--- Draw a sprite scaled up by an integer factor.
function Canvas:drawScaled(x, y, spr, scale)
  if scale == 1 then return self:draw(x, y, spr) end
  local w, h, sp = spr.w, spr.h, spr.px
  for sy = 1, h do
    local base = (sy - 1) * w
    for sx = 1, w do
      local col = sp[base + sx]
      if col then
        self:fill(x + (sx - 1) * scale, y + (sy - 1) * scale, scale, scale, col)
      end
    end
  end
end

-------------------------------------------------------------------- render
--- Convert the pixel buffer into drawing characters and blit it out.
function Canvas:render()
  local px, W = self.px, self.w
  local cw, ch = self.cw, self.ch
  local C, F, B, T = self._c, self._f, self._b, self._t
  local W2 = W + W
  for row = 0, ch - 1 do
    local base = row * 3 * W
    for col = 1, cw do
      local o = base + (col - 1) * 2
      local a, b = px[o + 1], px[o + 2]
      local c, d = px[o + W + 1], px[o + W + 2]
      local e, f = px[o + W2 + 1], px[o + W2 + 2]
      if a == b and a == c and a == d and a == e and a == f then
        C[col] = " "
        F[col] = "0"
        B[col] = BLIT[a]
      else
        local bgc, fgc
        -- Fast path: almost every non-uniform cell holds exactly two colours.
        local na = 1
        if b == a then na = na + 1 end
        if c == a then na = na + 1 end
        if d == a then na = na + 1 end
        if e == a then na = na + 1 end
        if f == a then na = na + 1 end
        local z
        if b ~= a then z = b
        elseif c ~= a then z = c
        elseif d ~= a then z = d
        elseif e ~= a then z = e
        else z = f end
        local nz = 0
        if b == z then nz = nz + 1 end
        if c == z then nz = nz + 1 end
        if d == z then nz = nz + 1 end
        if e == z then nz = nz + 1 end
        if f == z then nz = nz + 1 end

        if na + nz == 6 then
          if na >= nz then bgc, fgc = a, z else bgc, fgc = z, a end
        else
          -- three or more colours: keep the two most common, fold the rest in
          T[1], T[2], T[3], T[4], T[5], T[6] = a, b, c, d, e, f
          local bc, bn, sc, sn = nil, 0, nil, 0
          for i = 1, 6 do
            local v = T[i]
            if v ~= bc and v ~= sc then
              local n = 0
              for j = 1, 6 do if T[j] == v then n = n + 1 end end
              if n > bn then
                sc, sn = bc, bn
                bc, bn = v, n
              elseif n > sn then
                sc, sn = v, n
              end
            end
          end
          bgc = bc
          fgc = sc or bc
        end
        local bits = 0
        if a ~= bgc then bits = bits + 1 end
        if b ~= bgc then bits = bits + 2 end
        if c ~= bgc then bits = bits + 4 end
        if d ~= bgc then bits = bits + 8 end
        if e ~= bgc then bits = bits + 16 end
        if f ~= bgc then bits = bits + 32 end
        if bits >= 32 then
          bits = 63 - bits
          fgc, bgc = bgc, fgc
        end
        C[col] = schar(128 + bits)
        F[col] = BLIT[fgc]
        B[col] = BLIT[bgc]
      end
    end
    term.setCursorPos(self.cx, self.cy + row)
    term.blit(concat(C, "", 1, cw), concat(F, "", 1, cw), concat(B, "", 1, cw))
  end
end

return Canvas
