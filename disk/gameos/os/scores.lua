--[[ scores -- the high score browser.

  A game list on the left, that game's top five on the right, with the
  leader drawn large in the pixel font.
]]

local req = ...
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local audio = req("lib.audio")
local data = req("lib.data")
local ui = req("lib.ui")

local scores = {}

local floor = math.floor
local MEDALS = { colors.yellow, colors.lightGray, colors.orange, colors.lightBlue, colors.lightBlue }

function scores.run(api)
  local games = api.games
  if #games == 0 then
    ui.alert(" High Scores ", "No games installed.", colors.yellow)
    return
  end

  local sel = 1
  local top = 1
  local ROWS = 13
  local banner = Canvas.new(23, 3, 28, 4, colors.black)
  local t = 0

  local function clampView()
    if sel < top then top = sel end
    if sel > top + ROWS - 1 then top = sel - ROWS + 1 end
    local maxTop = math.max(1, #games - ROWS + 1)
    if top > maxTop then top = maxTop end
    if top < 1 then top = 1 end
  end

  local function draw()
    gfx.clear(colors.black)
    gfx.fill(1, 1, gfx.W, 1, colors.gray)
    gfx.text(2, 1, "HIGH SCORES", colors.white, colors.gray)
    gfx.right(gfx.W - 1, 1, data.totalPlays() .. " plays", colors.lightGray, colors.gray)
    gfx.rule(1, 2, gfx.W, colors.yellow, colors.black)

    clampView()
    for r = 0, ROWS - 1 do
      local i = top + r
      local y = 3 + r
      gfx.fill(2, y, 19, 1, colors.black)
      local def = games[i]
      if def then
        local on = (i == sel)
        local accent = def.accent or colors.lightBlue
        local bg = on and accent or colors.black
        local fg = on and gfx.contrast(accent) or colors.white
        gfx.fill(2, y, 19, 1, bg)
        if not on then gfx.fill(2, y, 1, 1, accent) end
        gfx.text(4, y, gfx.clip(def.name, 16), fg, bg)
      end
    end

    local def = games[sel]
    local accent = def.accent or colors.lightBlue
    local list = data.scores(def.id)

    banner:clear(colors.black)
    if list[1] then
      -- no drop shadow here: on a black ground it just smears the digits
      font.center(banner, 2, gfx.commas(list[1].score), accent, 2, 2)
    else
      font.center(banner, 4, "NO SCORES YET", colors.gray, 1, 1)
    end
    banner:render()

    gfx.rule(23, 7, 28, accent, colors.black)
    for i = 1, 5 do
      local y = 8 + i
      gfx.fill(23, y, 28, 1, colors.black)
      local entry = list[i]
      gfx.text(23, y, tostring(i) .. ".", entry and MEDALS[i] or colors.gray, colors.black)
      if entry then
        gfx.text(26, y, entry.who or "---", entry.who and accent or colors.gray, colors.black)
        gfx.text(30, y, gfx.commas(entry.score), colors.white, colors.black)
        gfx.right(50, y, "day " .. tostring(entry.day or 0), colors.lightGray, colors.black)
      else
        gfx.text(26, y, "---", colors.gray, colors.black)
        gfx.text(30, y, "-----", colors.gray, colors.black)
      end
    end

    local stats = data.stats(def.id)
    gfx.fill(23, 15, 28, 1, colors.black)
    gfx.text(23, 15, "PLAYED", colors.lightGray, colors.black)
    gfx.right(50, 15, stats.plays .. "x", colors.white, colors.black)
    gfx.fill(23, 16, 28, 1, colors.black)
    gfx.text(23, 16, "TIME", colors.lightGray, colors.black)
    gfx.right(50, 16, data.formatDuration(stats.seconds), colors.white, colors.black)

    gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
    gfx.text(2, 19, "Up/Dn", colors.yellow, colors.black)
    gfx.text(8, 19, "pick game", colors.lightGray, colors.black)
    gfx.text(20, 19, "Q", colors.yellow, colors.black)
    gfx.text(22, 19, "back", colors.lightGray, colors.black)
  end

  local function handle(ev)
    local name = ev[1]
    if name == "key" then
      local k = ev[2]
      if k == keys.up or k == keys.w then
        sel = sel > 1 and sel - 1 or #games
        audio.play("move")
      elseif k == keys.down or k == keys.s then
        sel = sel < #games and sel + 1 or 1
        audio.play("move")
      elseif k == keys.backspace or k == keys.q or k == keys.enter then
        audio.play("back")
        return 1
      end
    elseif name == "mouse_scroll" then
      sel = math.min(#games, math.max(1, sel + ev[2]))
    elseif name == "mouse_click" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      local i = top + (my - 3)
      if mx <= 21 and games[i] then
        sel = i
        audio.play("move")
      elseif my >= 18 then
        audio.play("back")
        return 1
      end
    end
    return nil
  end

  ui.loop(draw, handle)
end

return scores
