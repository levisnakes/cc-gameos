--[[ about -- version, lifetime stats and any modules that failed to load. ]]

local req = ...
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local audio = req("lib.audio")
local data = req("lib.data")
local ui = req("lib.ui")

local about = {}

function about.run(api)
  local logo = Canvas.new(1, 3, gfx.W, 5, colors.black)
  local t = 0

  local function draw()
    gfx.clear(colors.black)
    gfx.fill(1, 1, gfx.W, 1, colors.gray)
    gfx.text(2, 1, "ABOUT", colors.white, colors.gray)
    gfx.rule(1, 2, gfx.W, colors.purple, colors.black)

    logo:clear(colors.black)
    local hue = math.floor(t * 2) % 3
    local hues = { colors.lightBlue, colors.magenta, colors.lime }
    font.centerShadow(logo, 3, "GAMEOS", hues[hue + 1], colors.gray, 3, 3)
    logo:render()

    gfx.center(9, "a game console for ComputerCraft", colors.lightGray, colors.black)
    gfx.center(10, "version " .. api.version, colors.white, colors.black)

    local left = 6
    gfx.text(left, 12, "Games installed", colors.lightGray, colors.black)
    gfx.right(gfx.W - left, 12, tostring(#api.games), colors.white, colors.black)
    gfx.text(left, 13, "Games played", colors.lightGray, colors.black)
    gfx.right(gfx.W - left, 13, tostring(data.totalPlays()), colors.white, colors.black)
    gfx.text(left, 14, "Time played", colors.lightGray, colors.black)
    gfx.right(gfx.W - left, 14, data.formatDuration(data.totalSeconds()), colors.white, colors.black)
    gfx.text(left, 15, "Trophies", colors.lightGray, colors.black)
    gfx.right(gfx.W - left, 15, data.trophyCount() .. " earned", colors.yellow, colors.black)
    gfx.text(left, 16, "Speaker", colors.lightGray, colors.black)
    gfx.right(gfx.W - left, 16, audio.speaker and "connected" or "none", audio.speaker and colors.lime or colors.gray, colors.black)
    gfx.text(left, 17, "Save file", colors.lightGray, colors.black)
    gfx.right(gfx.W - left, 17, data.writable and "writable" or "READ ONLY", data.writable and colors.lime or colors.red, colors.black)

    gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
    if api.broken and #api.broken > 0 then
      gfx.center(19, #api.broken .. " game(s) failed to load -- press F", colors.red, colors.black)
    else
      gfx.center(19, "press Q to go back", colors.lightGray, colors.black)
    end
  end

  local function handle(ev)
    if ev[1] == "key" then
      local k = ev[2]
      if k == keys.f and api.broken and #api.broken > 0 then
        local body = {}
        for i = 1, math.min(4, #api.broken) do
          body[i] = gfx.clip(api.broken[i].id .. ": " .. api.broken[i].err, 40)
        end
        ui.alert(" Load errors ", body, colors.red)
      elseif k == keys.backspace or k == keys.q or k == keys.enter or k == keys.space then
        audio.play("ui.back")
        return 1
      end
    elseif ev[1] == "mouse_click" then
      audio.play("ui.back")
      return 1
    end
    return nil
  end

  -- keep the logo cycling colours while the page is open
  local pump = os.startTimer(0.25)
  while true do
    gfx.beginFrame()
    draw()
    gfx.endFrame()
    local ev = { os.pullEventRaw() }
    if ev[1] == "timer" and ev[2] == pump then
      pump = os.startTimer(0.25)
      t = t + 0.25
      audio.update(os.clock())
    elseif ev[1] == "terminate" then
      return
    else
      if handle(ev) then
        os.cancelTimer(pump)
        return
      end
    end
  end
end

return about
