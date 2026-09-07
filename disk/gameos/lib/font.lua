--[[ font -- a 5-row pixel font drawn onto a canvas.

  Glyphs are 4 pixels wide apart from M, N and W, which need 5 to stay
  readable. Rows are listed top to bottom, "1" is an inked pixel. Lower case
  is folded to upper case; unknown characters render as a blank.

  Layout rule: a character cell holds three pixel rows and only two colours,
  so put text baselines on y = 3k + 1 and leave at least six pixels between
  lines of different colours. Lines that share a cell lose a colour.
]]

local font = { W = 4, H = 5 }

local RAW = {
  ["0"] = "0110 1001 1001 1001 0110",
  ["1"] = "0010 0110 0010 0010 0111",
  ["2"] = "1110 0001 0110 1000 1111",
  ["3"] = "1110 0001 0110 0001 1110",
  ["4"] = "1001 1001 1111 0001 0001",
  ["5"] = "1111 1000 1110 0001 1110",
  ["6"] = "0110 1000 1110 1001 0110",
  ["7"] = "1111 0001 0010 0100 0100",
  ["8"] = "0110 1001 0110 1001 0110",
  ["9"] = "0110 1001 0111 0001 0110",
  ["A"] = "0110 1001 1111 1001 1001",
  ["B"] = "1110 1001 1110 1001 1110",
  ["C"] = "0111 1000 1000 1000 0111",
  ["D"] = "1110 1001 1001 1001 1110",
  ["E"] = "1111 1000 1110 1000 1111",
  ["F"] = "1111 1000 1110 1000 1000",
  ["G"] = "0111 1000 1011 1001 0111",
  ["H"] = "1001 1001 1111 1001 1001",
  ["I"] = "1110 0100 0100 0100 1110",
  ["J"] = "0011 0001 0001 1001 0110",
  ["K"] = "1001 1010 1100 1010 1001",
  ["L"] = "1000 1000 1000 1000 1111",
  ["M"] = "10001 11011 10101 10001 10001",
  ["N"] = "10001 11001 10101 10011 10001",
  ["O"] = "0110 1001 1001 1001 0110",
  ["P"] = "1110 1001 1110 1000 1000",
  ["Q"] = "0110 1001 1001 1011 0111",
  ["R"] = "1110 1001 1110 1010 1001",
  ["S"] = "0111 1000 0110 0001 1110",
  ["T"] = "1111 0100 0100 0100 0100",
  ["U"] = "1001 1001 1001 1001 0110",
  ["V"] = "1001 1001 1001 1010 0100",
  ["W"] = "10001 10001 10101 11011 10001",
  ["X"] = "1001 1001 0110 1001 1001",
  ["Y"] = "1001 1001 0110 0100 0100",
  ["Z"] = "1111 0001 0110 1000 1111",
  [" "] = "0000 0000 0000 0000 0000",
  ["."] = "0000 0000 0000 0000 0100",
  [","] = "0000 0000 0000 0100 1000",
  [":"] = "0000 0100 0000 0100 0000",
  [";"] = "0000 0100 0000 0100 1000",
  ["-"] = "0000 0000 1110 0000 0000",
  ["+"] = "0000 0100 1110 0100 0000",
  ["="] = "0000 1110 0000 1110 0000",
  ["!"] = "0100 0100 0100 0000 0100",
  ["?"] = "1110 0001 0110 0000 0100",
  ["'"] = "0100 0100 0000 0000 0000",
  ["\""] = "1010 1010 0000 0000 0000",
  ["/"] = "0001 0010 0010 0100 1000",
  ["\\"] = "1000 0100 0100 0010 0001",
  ["("] = "0010 0100 0100 0100 0010",
  [")"] = "0100 0010 0010 0010 0100",
  ["["] = "0110 0100 0100 0100 0110",
  ["]"] = "0110 0010 0010 0010 0110",
  ["<"] = "0010 0100 1000 0100 0010",
  [">"] = "0100 0010 0001 0010 0100",
  ["*"] = "0000 1010 0100 1010 0000",
  ["%"] = "1001 0010 0100 1000 1001",
  ["#"] = "0101 1111 0101 1111 0101",
  ["_"] = "0000 0000 0000 0000 1111",
}

-- Compile to lists of {x, y} offsets so drawing is a flat loop.
font.glyphs = {}
for ch, spec in pairs(RAW) do
  local pts, y, w = {}, 0, 0
  for row in spec:gmatch("%S+") do
    if #row > w then w = #row end
    for x = 1, #row do
      if row:sub(x, x) == "1" then pts[#pts + 1] = { x - 1, y } end
    end
    y = y + 1
  end
  font.glyphs[ch] = { pts = pts, w = w }
end

local BLANK = font.glyphs[" "]

function font.width(text, scale, spacing)
  scale = scale or 1
  spacing = spacing or 1
  text = tostring(text):upper()
  local n = #text
  if n == 0 then return 0 end
  local total = 0
  for i = 1, n do
    local g = font.glyphs[text:sub(i, i)] or BLANK
    total = total + g.w * scale + spacing
  end
  return total - spacing
end

--- Draw text at pixel (x, y). Returns the x just past the last glyph.
function font.draw(canvas, x, y, text, col, scale, spacing)
  scale = scale or 1
  spacing = spacing or 1
  text = tostring(text):upper()
  local gx = x
  for i = 1, #text do
    local g = font.glyphs[text:sub(i, i)] or BLANK
    local pts = g.pts
    for j = 1, #pts do
      local p = pts[j]
      if scale == 1 then
        canvas:set(gx + p[1], y + p[2], col)
      else
        canvas:fill(gx + p[1] * scale, y + p[2] * scale, scale, scale, col)
      end
    end
    gx = gx + g.w * scale + spacing
  end
  return gx - spacing
end

--- Draw with a one-pixel drop shadow underneath.
function font.drawShadow(canvas, x, y, text, col, shadow, scale, spacing)
  font.draw(canvas, x + 1, y + 1, text, shadow, scale, spacing)
  return font.draw(canvas, x, y, text, col, scale, spacing)
end

--- Centre text horizontally across the whole canvas (or a given span).
function font.center(canvas, y, text, col, scale, spacing, x0, w)
  x0 = x0 or 1
  w = w or canvas.w
  local tw = font.width(text, scale, spacing)
  return font.draw(canvas, x0 + math.floor((w - tw) / 2), y, text, col, scale, spacing)
end

function font.centerShadow(canvas, y, text, col, shadow, scale, spacing, x0, w)
  x0 = x0 or 1
  w = w or canvas.w
  local tw = font.width(text, scale, spacing)
  local x = x0 + math.floor((w - tw) / 2)
  font.draw(canvas, x + 1, y + 1, text, shadow, scale, spacing)
  return font.draw(canvas, x, y, text, col, scale, spacing)
end

return font
