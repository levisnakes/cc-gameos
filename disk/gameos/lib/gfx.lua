--[[ gfx -- screen setup, palettes and flicker-free character drawing.

  GameOS always draws into a fixed 51x19 design surface. On a larger display
  (a monitor) that surface is centred and the surround is blanked, so every
  screen in the console can assume exact coordinates.
]]

local gfx = {}

gfx.W, gfx.H = 51, 19

--------------------------------------------------------------- blit lookup
local BLIT = {}
local FROMBLIT = {}
do
  local hex = "0123456789abcdef"
  local c = 1
  for i = 1, 16 do
    BLIT[c] = hex:sub(i, i)
    FROMBLIT[hex:sub(i, i)] = c
    c = c * 2
  end
end
gfx.blit = BLIT
gfx.unblit = FROMBLIT

--------------------------------------------------------- drawing characters
-- Sub-pixel cells: bit 1,2 = top row, 4,8 = middle row, 16,32 = bottom row.
gfx.TOP1 = string.char(128 + 3)    -- top third is foreground
gfx.TOP2 = string.char(128 + 15)   -- top two thirds are foreground
gfx.LEFT = string.char(128 + 21)   -- left half is foreground

----------------------------------------------------------------- palettes
gfx.themes = {
  {
    id = "midnight", name = "Midnight",
    [colors.white] = 0xE8EDF5, [colors.orange] = 0xF29C38, [colors.magenta] = 0xE05C9E,
    [colors.lightBlue] = 0x63B4F0, [colors.yellow] = 0xF2D544, [colors.lime] = 0x76D95E,
    [colors.pink] = 0xF294B4, [colors.gray] = 0x272D36, [colors.lightGray] = 0x76818F,
    [colors.cyan] = 0x35C4C4, [colors.purple] = 0x9C5CE6, [colors.blue] = 0x2E6BD9,
    [colors.brown] = 0x8A5C3C, [colors.green] = 0x2E9E52, [colors.red] = 0xE0413F,
    [colors.black] = 0x0B0E13,
  },
  {
    id = "neon", name = "Neon",
    [colors.white] = 0xF2E9FF, [colors.orange] = 0xFF8A3D, [colors.magenta] = 0xFF3FA4,
    [colors.lightBlue] = 0x4CC9F0, [colors.yellow] = 0xFFE45E, [colors.lime] = 0xB9F73E,
    [colors.pink] = 0xFF8AD0, [colors.gray] = 0x1E1436, [colors.lightGray] = 0x6B5CA5,
    [colors.cyan] = 0x4EF0D0, [colors.purple] = 0x9D4EDD, [colors.blue] = 0x3A2CA3,
    [colors.brown] = 0x6D3B2E, [colors.green] = 0x2DA84F, [colors.red] = 0xFF2E63,
    [colors.black] = 0x0A0714,
  },
  {
    id = "amber", name = "Amber CRT",
    [colors.black] = 0x0F0800, [colors.gray] = 0x2E1C04, [colors.brown] = 0x4A2E06,
    [colors.blue] = 0x5C3A08, [colors.purple] = 0x6E450A, [colors.red] = 0x80500C,
    [colors.green] = 0x925B0E, [colors.cyan] = 0xA46610, [colors.magenta] = 0xB67112,
    [colors.lightGray] = 0xC87C14, [colors.lime] = 0xD48A1E, [colors.orange] = 0xE09528,
    [colors.lightBlue] = 0xE8A238, [colors.yellow] = 0xF0B048, [colors.pink] = 0xF6C066,
    [colors.white] = 0xFFD98A,
  },
  {
    id = "dmg", name = "Game Boy",
    [colors.black] = 0x0F380F, [colors.gray] = 0x1A4A15, [colors.brown] = 0x24541C,
    [colors.blue] = 0x2A5C22, [colors.purple] = 0x306230, [colors.red] = 0x3A6E30,
    [colors.green] = 0x4A7A2E, [colors.cyan] = 0x5A862C, [colors.magenta] = 0x6A922A,
    [colors.lightGray] = 0x7A9E20, [colors.lime] = 0x8BAC0F, [colors.orange] = 0x93B20F,
    [colors.lightBlue] = 0x97B60F, [colors.yellow] = 0x9BBC0F, [colors.pink] = 0xA0C010,
    [colors.white] = 0xA5C40F,
  },
}

gfx.themeIndex = 1

local ALL = {
  colors.white, colors.orange, colors.magenta, colors.lightBlue, colors.yellow,
  colors.lime, colors.pink, colors.gray, colors.lightGray, colors.cyan,
  colors.purple, colors.blue, colors.brown, colors.green, colors.red, colors.black,
}
gfx.allColors = ALL

--------------------------------------------------------------------- setup
local originalPalette = nil

--- Attach to a terminal. Returns false plus a message when it is too small.
function gfx.init(target)
  local parent = target or term.current()
  local pw, ph = parent.getSize()
  if pw < gfx.W or ph < gfx.H then
    return false, string.format("Display is %dx%d, GameOS needs %dx%d", pw, ph, gfx.W, gfx.H)
  end
  gfx.parent = parent
  gfx.color = parent.isColor and parent.isColor() or false
  gfx.offX = math.floor((pw - gfx.W) / 2)
  gfx.offY = math.floor((ph - gfx.H) / 2)

  if gfx.color and not originalPalette then
    originalPalette = {}
    for _, c in ipairs(ALL) do
      local r, g, b = parent.getPaletteColour(c)
      originalPalette[c] = { r, g, b }
    end
  end

  -- blank the whole physical screen so the letterbox is clean
  parent.setBackgroundColour(colors.black)
  parent.setTextColour(colors.white)
  parent.clear()
  if parent.setCursorBlink then parent.setCursorBlink(false) end

  gfx.buf = window.create(parent, gfx.offX + 1, gfx.offY + 1, gfx.W, gfx.H, true)
  gfx.buf.setCursorBlink(false)
  gfx.prevTerm = term.redirect(gfx.buf)
  gfx.applyTheme(gfx.themeIndex)
  return true
end

--- Re-centre the design surface after the display changes size (a monitor
--- being extended, say). Returns false if it no longer fits.
function gfx.handleResize()
  if not gfx.parent or not gfx.buf then return true end
  local pw, ph = gfx.parent.getSize()
  if pw < gfx.W or ph < gfx.H then return false end
  gfx.offX = math.floor((pw - gfx.W) / 2)
  gfx.offY = math.floor((ph - gfx.H) / 2)
  gfx.parent.setBackgroundColour(colors.black)
  gfx.parent.clear()
  gfx.buf.reposition(gfx.offX + 1, gfx.offY + 1)
  return true
end

function gfx.shutdown()
  if gfx.prevTerm then
    term.redirect(gfx.prevTerm)
    gfx.prevTerm = nil
  end
  if originalPalette and gfx.parent and gfx.color then
    for c, rgb in pairs(originalPalette) do
      gfx.parent.setPaletteColour(c, rgb[1], rgb[2], rgb[3])
    end
  end
  if gfx.parent then
    gfx.parent.setBackgroundColour(colors.black)
    gfx.parent.setTextColour(colors.white)
    gfx.parent.clear()
    gfx.parent.setCursorPos(1, 1)
    if gfx.parent.setCursorBlink then gfx.parent.setCursorBlink(true) end
  end
  gfx.buf = nil
end

function gfx.applyTheme(index)
  index = ((index - 1) % #gfx.themes) + 1
  gfx.themeIndex = index
  local theme = gfx.themes[index]
  gfx.theme = theme
  if not gfx.color then return end
  for _, c in ipairs(ALL) do
    local v = theme[c]
    if v then
      local r = math.floor(v / 65536) % 256 / 255
      local g = math.floor(v / 256) % 256 / 255
      local b = v % 256 / 255
      gfx.parent.setPaletteColour(c, r, g, b)
      if gfx.buf then gfx.buf.setPaletteColour(c, r, g, b) end
    end
  end
end

function gfx.themeByID(id)
  for i, t in ipairs(gfx.themes) do if t.id == id then return i end end
  return 1
end

------------------------------------------------------------------- frames
function gfx.beginFrame()
  if gfx.buf then gfx.buf.setVisible(false) end
end

function gfx.endFrame()
  if gfx.buf then gfx.buf.setVisible(true) end
end

--------------------------------------------------------------- primitives
local floor = math.floor

function gfx.clear(bg)
  term.setBackgroundColour(bg or colors.black)
  term.clear()
end

--- Solid rectangle. x,y are 1-based, w,h are sizes in cells.
function gfx.fill(x, y, w, h, bg)
  x, y, w, h = floor(x), floor(y), floor(w), floor(h)
  if w <= 0 or h <= 0 then return end
  if x < 1 then w = w + x - 1 x = 1 end
  if y < 1 then h = h + y - 1 y = 1 end
  if x + w - 1 > gfx.W then w = gfx.W - x + 1 end
  if y + h - 1 > gfx.H then h = gfx.H - y + 1 end
  if w <= 0 or h <= 0 then return end
  term.setBackgroundColour(bg)
  local line = string.rep(" ", w)
  for i = 0, h - 1 do
    term.setCursorPos(x, y + i)
    term.write(line)
  end
end

function gfx.text(x, y, s, fg, bg)
  y = floor(y)
  if y < 1 or y > gfx.H then return end
  s = tostring(s)
  x = floor(x)
  if x < 1 then
    s = s:sub(2 - x)
    x = 1
  end
  if #s == 0 then return end
  if x > gfx.W then return end
  if x + #s - 1 > gfx.W then s = s:sub(1, gfx.W - x + 1) end
  if fg then term.setTextColour(fg) end
  if bg then term.setBackgroundColour(bg) end
  term.setCursorPos(x, y)
  term.write(s)
end

function gfx.blitStr(x, y, s, fgs, bgs)
  if y < 1 or y > gfx.H or x > gfx.W then return end
  if x < 1 then
    local cut = 2 - x
    s, fgs, bgs = s:sub(cut), fgs:sub(cut), bgs:sub(cut)
    x = 1
  end
  if #s == 0 then return end
  if x + #s - 1 > gfx.W then
    local keep = gfx.W - x + 1
    s, fgs, bgs = s:sub(1, keep), fgs:sub(1, keep), bgs:sub(1, keep)
  end
  term.setCursorPos(x, y)
  term.blit(s, fgs, bgs)
end

--- Centre text within [x0, x0+w-1]; defaults to the whole screen width.
function gfx.center(y, s, fg, bg, x0, w)
  x0 = x0 or 1
  w = w or gfx.W
  s = tostring(s)
  gfx.text(x0 + floor((w - #s) / 2), y, s, fg, bg)
end

--- Text whose last character lands on column x.
function gfx.right(x, y, s, fg, bg)
  s = tostring(s)
  gfx.text(x - #s + 1, y, s, fg, bg)
end

function gfx.hline(x, y, w, bg) gfx.fill(x, y, w, 1, bg) end
function gfx.vline(x, y, h, bg) gfx.fill(x, y, 1, h, bg) end

--- A thin accent rule: one third of a cell tall, sitting at the top of row y.
function gfx.rule(x, y, w, fg, bg)
  if w <= 0 then return end
  gfx.blitStr(x, y, string.rep(gfx.TOP1, w), string.rep(BLIT[fg], w), string.rep(BLIT[bg], w))
end

--- Panel with an optional title bar. Returns the inner content rect.
function gfx.panel(x, y, w, h, bg, title, titleFg, titleBg)
  gfx.fill(x, y, w, h, bg)
  if title then
    titleBg = titleBg or bg
    gfx.fill(x, y, w, 1, titleBg)
    gfx.text(x + 1, y, title, titleFg or colors.white, titleBg)
    return x + 1, y + 2, w - 2, h - 3
  end
  return x + 1, y + 1, w - 2, h - 2
end

--- Horizontal progress bar with half-cell precision.
function gfx.bar(x, y, w, frac, fg, bg)
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  local halves = floor(frac * w * 2 + 0.5)
  local full = floor(halves / 2)
  local half = halves - full * 2
  if full > 0 then gfx.fill(x, y, full, 1, fg) end
  if half == 1 and full < w then
    gfx.blitStr(x + full, y, gfx.LEFT, BLIT[fg], BLIT[bg])
  end
  local rest = w - full - half
  if rest > 0 then gfx.fill(x + full + half, y, rest, 1, bg) end
end

--- Pick black or white text for a background colour in the current theme,
--- so accents stay readable in every palette.
function gfx.contrast(bg)
  local rgb = gfx.theme and gfx.theme[bg]
  if not rgb then return colors.white end
  local r = math.floor(rgb / 65536) % 256
  local g = math.floor(rgb / 256) % 256
  local b = rgb % 256
  -- rough perceptual luminance, integer maths only
  local lum = (r * 299 + g * 587 + b * 114) / 1000
  if lum > 140 then return colors.black end
  return colors.white
end

--- A dimmer companion colour for the given accent, used for shadows.
function gfx.shade(bg)
  if bg == colors.black then return colors.black end
  return gfx.contrast(bg) == colors.black and colors.gray or colors.black
end

-------------------------------------------------------------- glyph sprites
--[[ Two-colour sprites drawn straight onto the character grid.

  Pass rows of "#" and "." with a width that is a multiple of two and a
  height that is a multiple of three; each 2x3 block becomes one cell. This
  gives real artwork inside games that are laid out in character cells,
  without standing up a whole canvas.
]]
local BITVAL = { 1, 2, 4, 8, 16, 32 }

function gfx.makeGlyph(rows)
  local ph = #rows
  local pw = #rows[1]
  local glyph = { w = floor(pw / 2), h = floor(ph / 3), text = {}, swap = {}, cache = {} }
  for cy = 1, glyph.h do
    local chars, swaps = {}, {}
    for cx = 1, glyph.w do
      local bits = 0
      for sy = 0, 2 do
        local row = rows[(cy - 1) * 3 + sy + 1]
        for sx = 0, 1 do
          local i = (cx - 1) * 2 + sx + 1
          if row:sub(i, i) == "#" then bits = bits + BITVAL[sy * 2 + sx + 1] end
        end
      end
      local swapped = false
      if bits >= 32 then
        bits = 63 - bits
        swapped = true
      end
      chars[cx] = string.char(128 + bits)
      swaps[cx] = swapped
    end
    glyph.text[cy] = table.concat(chars)
    glyph.swap[cy] = swaps
  end
  return glyph
end

--- Colour strings are cached per glyph and colour pair, so repeatedly
--- stamping the same sprite costs no allocation.
local function glyphColours(glyph, fg, bg)
  local key = fg * 65536 + bg
  local hit = glyph.cache[key]
  if hit then return hit end
  local F, B = BLIT[fg], BLIT[bg]
  local entry = { fgs = {}, bgs = {} }
  for cy = 1, glyph.h do
    local swaps = glyph.swap[cy]
    local fgs, bgs = {}, {}
    for cx = 1, glyph.w do
      if swaps[cx] then
        fgs[cx], bgs[cx] = B, F
      else
        fgs[cx], bgs[cx] = F, B
      end
    end
    entry.fgs[cy] = table.concat(fgs)
    entry.bgs[cy] = table.concat(bgs)
  end
  glyph.cache[key] = entry
  return entry
end

function gfx.blitGlyph(x, y, glyph, fg, bg)
  local colours = glyphColours(glyph, fg, bg)
  for cy = 1, glyph.h do
    gfx.blitStr(x, y + cy - 1, glyph.text[cy], colours.fgs[cy], colours.bgs[cy])
  end
end

--- Truncate to width, adding a trailing dot when clipped.
function gfx.clip(s, w)
  s = tostring(s)
  if #s <= w then return s end
  if w <= 1 then return s:sub(1, w) end
  return s:sub(1, w - 1) .. "."
end

function gfx.pad(s, w, align)
  s = gfx.clip(s, w)
  local gap = w - #s
  if align == "right" then return string.rep(" ", gap) .. s end
  if align == "center" then
    local l = floor(gap / 2)
    return string.rep(" ", l) .. s .. string.rep(" ", gap - l)
  end
  return s .. string.rep(" ", gap)
end

--- Format a number with thousands separators.
function gfx.commas(n)
  local s = tostring(math.floor(n))
  local sign = ""
  if s:sub(1, 1) == "-" then sign = "-" s = s:sub(2) end
  local out = s
  while true do
    local rep
    out, rep = out:gsub("^(%d+)(%d%d%d)", "%1,%2")
    if rep == 0 then break end
  end
  return sign .. out
end

return gfx
