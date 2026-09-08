--[[ splash -- the boot animation.

  A starfield settles, the logo wipes in, a loader bar fills, then the whole
  thing irises out. Any key skips straight to the shell.
]]

local req = ...
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local audio = req("lib.audio")

local splash = {}

local DURATION = 2.1

function splash.run(api)
  local c = Canvas.new(1, 1, gfx.W, gfx.H, colors.black)

  local stars = {}
  for i = 1, 46 do
    stars[i] = {
      x = math.random(1, c.w),
      y = math.random(1, c.h),
      v = 8 + math.random(0, 22),
      shade = math.random(1, 3),
    }
  end
  local shades = { colors.gray, colors.lightGray, colors.white }

  audio.play("boot.chime")

  local t = 0
  local timer = os.startTimer(0.05)
  local skipped = false

  while t < DURATION and not skipped do
    local ev = { os.pullEventRaw() }
    if ev[1] == "timer" and ev[2] == timer then
      timer = os.startTimer(0.05)
      local dt = 0.05
      t = t + dt
      audio.update(os.clock())

      c:clear(colors.black)

      -- warp stars, slowing to a stop as the logo lands
      local speed = 1 - math.min(1, t / 1.2)
      for i = 1, #stars do
        local s = stars[i]
        s.x = s.x - s.v * dt * speed * 3
        if s.x < 1 then
          s.x = c.w
          s.y = math.random(1, c.h)
        end
        local trail = math.floor(s.v * dt * speed * 3)
        if trail > 0 then
          c:hline(s.x, s.y, trail + 1, shades[s.shade])
        else
          c:set(s.x, s.y, shades[s.shade])
        end
      end

      -- logo wipes in from the left
      local logoY = 18
      local title = "GAMEOS"
      local tw = font.width(title, 3, 3)
      local tx = math.floor((c.w - tw) / 2) + 1
      font.drawShadow(c, tx, logoY, title, colors.white, colors.blue, 3, 3)
      local reveal = math.min(1, t / 0.9)
      local hide = tw + 4 - math.floor((tw + 4) * reveal)
      if hide > 0 then
        c:fill(tx + tw + 2 - hide, logoY - 2, hide + 2, 20, colors.black)
      end
      if reveal < 1 then
        c:fill(tx + tw + 1 - hide, logoY - 2, 1, 19, colors.lightBlue)
      end

      if t > 0.95 then
        local sub = "GAME CONSOLE"
        font.center(c, logoY + 20, sub, colors.lightBlue, 1, 2)
      end

      -- loader bar
      if t > 1.15 then
        local p = math.min(1, (t - 1.15) / 0.7)
        local bw = 60
        local bx = math.floor((c.w - bw) / 2) + 1
        c:box(bx - 2, logoY + 30, bw + 4, 5, colors.gray)
        c:fill(bx, logoY + 31, math.floor(bw * p), 3, colors.lime)
      end

      -- iris out
      if t > DURATION - 0.25 then
        local k = (t - (DURATION - 0.25)) / 0.25
        local cut = math.floor(k * c.h / 2) + 1
        c:fill(1, 1, c.w, cut, colors.black)
        c:fill(1, c.h - cut + 1, c.w, cut, colors.black)
      end

      gfx.beginFrame()
      c:render()
      gfx.endFrame()
    elseif ev[1] == "key" or ev[1] == "mouse_click" or ev[1] == "terminate" then
      skipped = true
    end
  end

  os.cancelTimer(timer)
  gfx.beginFrame()
  gfx.clear(colors.black)
  gfx.endFrame()
end

return splash
