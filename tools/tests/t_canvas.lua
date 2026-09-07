-- Verifies the sub-pixel canvas, the pixel font and the gfx primitives.
local req = require_gameos
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")

local ok, err = gfx.init()
check(ok, err or "gfx.init failed")

gfx.beginFrame()
gfx.clear(colors.black)

local c = Canvas.new(1, 1, 51, 19, colors.black)
c:clear(colors.black)

c:fill(2, 2, 22, 12, colors.blue)
c:box(2, 2, 22, 12, colors.lightBlue)
c:line(2, 2, 23, 13, colors.white)

c:circle(38, 8, 6, colors.lime, true)
c:circle(38, 8, 6, colors.white, false)

for i = 0, 15 do
  c:fill(52 + i * 3, 2, 3, 10, gfx.allColors[i + 1])
end

c:line(2, 20, 100, 20, colors.gray)
font.drawShadow(c, 3, 24, "GAMEOS", colors.yellow, colors.brown, 2, 2)
font.draw(c, 60, 24, "1234567890", colors.cyan, 1, 1)
font.draw(c, 60, 31, "ABCDEFGHIJ", colors.white, 1, 1)
font.center(c, 40, "THE QUICK BROWN FOX", colors.lightGray, 1, 1)
font.center(c, 47, "JUMPS OVER 13 LAZY DOGS!", colors.orange, 1, 1)

-- a checkerboard, the worst case for two-colour cells
for y = 0, 5 do
  for x = 0, 11 do
    c:fill(2 + x * 4, 52 + y, 2, 1, (x + y) % 2 == 0 and colors.magenta or colors.black)
  end
end
c:render()
gfx.endFrame()
SHOT("canvas")

-- Character-cell primitives on top
gfx.beginFrame()
gfx.clear(colors.black)
gfx.fill(1, 1, 51, 1, colors.blue)
gfx.text(2, 1, "GameOS", colors.white, colors.blue)
gfx.right(50, 1, "12:34", colors.lightBlue, colors.blue)
gfx.panel(2, 3, 24, 8, colors.gray, " PANEL ", colors.white, colors.purple)
gfx.text(4, 5, "Left aligned", colors.white, colors.gray)
gfx.center(6, "centred", colors.yellow, colors.gray, 2, 24)
gfx.rule(4, 8, 20, colors.cyan, colors.gray)
gfx.bar(4, 9, 20, 0.62, colors.lime, colors.black)
gfx.text(28, 3, gfx.commas(1234567), colors.orange, colors.black)
gfx.text(28, 5, gfx.clip("truncate me please", 12), colors.white, colors.black)
gfx.text(28, 7, "[" .. gfx.pad("mid", 11, "center") .. "]", colors.lightGray, colors.black)
for i = 1, 16 do
  gfx.fill(2 + (i - 1) * 3, 12, 3, 2, gfx.allColors[i])
end
gfx.center(15, "half bars", colors.white, colors.black)
gfx.bar(10, 16, 32, 0.5, colors.magenta, colors.gray)
gfx.bar(10, 17, 32, 0.515625, colors.magenta, colors.gray)
gfx.endFrame()
SHOT("cells")

eq(font.width("ABC", 1, 1), 14, "font.width scale 1")
eq(font.width("ABC", 2, 2), 28, "font.width scale 2")
eq(gfx.commas(1234567), "1,234,567", "commas")
eq(gfx.commas(-4321), "-4,321", "negative commas")
eq(gfx.commas(0), "0", "zero commas")
eq(gfx.clip("abcdef", 4), "abc.", "clip")
eq(#gfx.pad("x", 7), 7, "pad width")

gfx.shutdown()
finish("canvas")
