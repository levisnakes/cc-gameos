--[[ trophies -- every trophy in the console, earned or not.

  Locked entries still show their description so there is something to chase.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")
local data = req("lib.data")
local ui = req("lib.ui")
local runtime = req("lib.runtime")

local trophies = {}

local floor = math.floor
local ROWS = 14
local LIST_Y = 4

local CUP = gfx.makeGlyph({
  "####",
  ".##.",
  ".##.",
})
local LOCK = gfx.makeGlyph({
  ".##.",
  "####",
  "####",
})

--- Flatten every game's trophies, plus the console-wide ones, into one list
--- with headers.
local function build(api)
  local rows = {}
  for _, def in ipairs(api.games) do
    if def.trophies and #def.trophies > 0 then
      rows[#rows + 1] = { header = def.name, accent = def.accent or colors.lightBlue }
      for _, t in ipairs(def.trophies) do
        rows[#rows + 1] = { trophy = t, accent = def.accent or colors.lightBlue }
      end
    end
  end
  local global = runtime.globalTrophies or {}
  if #global > 0 then
    rows[#rows + 1] = { header = "Console", accent = colors.yellow }
    for _, t in ipairs(global) do
      rows[#rows + 1] = { trophy = t, accent = colors.yellow }
    end
  end
  return rows
end

function trophies.run(api)
  local rows = build(api)
  local total, earned = 0, 0
  for _, row in ipairs(rows) do
    if row.trophy then
      total = total + 1
      if data.hasTrophy(row.trophy.id) then earned = earned + 1 end
    end
  end

  local top = 1
  local maxTop = math.max(1, #rows - ROWS + 1)

  local function draw()
    gfx.clear(colors.black)
    gfx.fill(1, 1, gfx.W, 1, colors.gray)
    gfx.text(2, 1, "TROPHIES", colors.white, colors.gray)
    gfx.right(gfx.W - 1, 1, earned .. " / " .. total, colors.yellow, colors.gray)
    gfx.rule(1, 2, gfx.W, colors.yellow, colors.black)

    gfx.bar(2, 3, gfx.W - 2, total > 0 and earned / total or 0, colors.yellow, colors.gray)

    for i = 0, ROWS - 1 do
      local row = rows[top + i]
      local y = LIST_Y + i
      gfx.fill(1, y, gfx.W, 1, colors.black)
      if row then
        if row.header then
          gfx.text(2, y, row.header, row.accent, colors.black)
          local used = #row.header + 3
          gfx.rule(used, y, gfx.W - used, colors.gray, colors.black)
        else
          local got = data.hasTrophy(row.trophy.id)
          gfx.blitGlyph(3, y, got and CUP or LOCK,
            got and colors.yellow or colors.gray, colors.black)
          gfx.text(6, y, gfx.clip(row.trophy.name, 15),
            got and colors.white or colors.lightGray, colors.black)
          gfx.text(22, y, gfx.clip(row.trophy.desc, gfx.W - 23),
            got and colors.lightGray or colors.gray, colors.black)
        end
      end
    end

    if #rows > ROWS then
      local barH = math.max(1, floor(ROWS * ROWS / #rows))
      local barY = LIST_Y + floor((top - 1) / #rows * ROWS)
      gfx.fill(gfx.W, LIST_Y, 1, ROWS, colors.black)
      gfx.fill(gfx.W, barY, 1, barH, colors.gray)
    end

    gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
    gfx.text(2, 19, "Up/Dn", colors.yellow, colors.black)
    gfx.text(8, 19, "scroll", colors.lightGray, colors.black)
    gfx.text(16, 19, "Q", colors.yellow, colors.black)
    gfx.text(18, 19, "back", colors.lightGray, colors.black)
  end

  local function scroll(delta)
    top = math.max(1, math.min(maxTop, top + delta))
  end

  local function handle(ev)
    if ev[1] == "key" then
      local k = ev[2]
      if k == keys.up or k == keys.w then
        scroll(-1)
      elseif k == keys.down or k == keys.s then
        scroll(1)
      elseif k == keys.pageUp then
        scroll(-ROWS)
      elseif k == keys.pageDown then
        scroll(ROWS)
      elseif k == keys.home then
        top = 1
      elseif k == keys["end"] then
        top = maxTop
      elseif k == keys.backspace or k == keys.q or k == keys.enter then
        audio.play("back")
        return 1
      end
    elseif ev[1] == "mouse_scroll" then
      scroll(ev[2])
    elseif ev[1] == "mouse_click" then
      local _, my = ui.toLocal(ev[3], ev[4])
      if my >= 18 then
        audio.play("back")
        return 1
      end
    end
    return nil
  end

  ui.loop(draw, handle)
end

return trophies
