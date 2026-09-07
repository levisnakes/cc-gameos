--[[ Flappy -- one button, parallax scenery, medals at 10 / 20 / 30 / 40. ]]

local req = ...
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local audio = req("lib.audio")

local floor = math.floor
local max, min = math.max, math.min

local W, H = 102, 54
local GROUND_Y = 47
local BIRD_X = 24
local PIPE_W = 12
local PIPE_SPACING = 44

local Game = {}
Game.__index = Game

local BIRD_SPRITE = Canvas.sprite({
  ".YYYY..",
  "YWKYYYO",
  "YYYYYYO",
  ".YYYYY.",
  "..YYY..",
}, {
  Y = colors.yellow, W = colors.white, K = colors.black,
  O = colors.orange, ["."] = false,
})

local BIRD_UP = Canvas.sprite({
  ".YYYY..",
  "YWKYYYO",
  "YYYYYYO",
  ".YYYYY.",
  "...YY..",
}, {
  Y = colors.yellow, W = colors.white, K = colors.black,
  O = colors.orange, ["."] = false,
})

local MEDALS = {
  { at = 40, name = "PLATINUM", colour = colors.lightBlue },
  { at = 30, name = "GOLD", colour = colors.yellow },
  { at = 20, name = "SILVER", colour = colors.lightGray },
  { at = 10, name = "BRONZE", colour = colors.brown },
}

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.c = Canvas.new(1, 2, gfx.W, 18, colors.black)
  self.gap = (mode and mode.gap) or 18
  self.speed = (mode and mode.speed) or 30
  self.score = 0
  self.finished = false
  self.state = "ready"
  self.y = 22
  self.vy = 0
  self.wing = 0
  self.scroll = 0
  self.deathTimer = 0
  self.best = 0

  self.pipes = {}
  for i = 1, 4 do
    self.pipes[i] = {
      x = 70 + (i - 1) * PIPE_SPACING,
      gapY = math.random(10, GROUND_Y - self.gap - 8),
      passed = false,
    }
  end

  self.clouds = {}
  for i = 1, 5 do
    self.clouds[i] = { x = math.random(1, W), y = math.random(4, 22), w = math.random(8, 16) }
  end
  self.hills = {}
  for i = 1, 9 do
    self.hills[i] = { x = (i - 1) * 14, h = math.random(5, 11) }
  end
  return self
end

function Game:flap()
  if self.finished then return end
  if self.state == "ready" then
    self.state = "play"
  end
  if self.state == "play" then
    self.vy = -46
    self.wing = 0.18
    audio.play("flap")
  end
end

function Game:onKey(code, held)
  if held then return end
  if code == keys.space or code == keys.up or code == keys.w then self:flap() end
end

function Game:onMouse(kind)
  if kind == "mouse_click" then self:flap() end
end

-------------------------------------------------------------------- update
function Game:pipeRects(p)
  local topH = p.gapY - 1
  local botY = p.gapY + self.gap
  return topH, botY
end

function Game:collides()
  local bx1, by1 = BIRD_X + 1, self.y + 1
  local bx2, by2 = BIRD_X + 5, self.y + 3
  if by2 >= GROUND_Y then return true end
  if by1 < 1 then return true end
  for _, p in ipairs(self.pipes) do
    local px1, px2 = p.x, p.x + PIPE_W - 1
    if bx2 >= px1 and bx1 <= px2 then
      local topH, botY = self:pipeRects(p)
      if by1 <= topH or by2 >= botY then return true end
    end
  end
  return false
end

function Game:die()
  if self.state == "dead" then return end
  self.state = "dead"
  self.deathTimer = 1.1
  audio.play("hit")
  audio.play("gameover")
end

function Game:update(dt)
  if self.finished then return end
  self.wing = max(0, self.wing - dt)

  if self.state == "ready" then
    self.scroll = self.scroll + self.speed * dt * 0.4
    self.y = 22 + math.sin(self.scroll * 0.12) * 3
    return
  end

  if self.state == "dead" then
    self.deathTimer = self.deathTimer - dt
    self.vy = min(70, self.vy + 190 * dt)
    self.y = self.y + self.vy * dt
    if self.y + 5 > GROUND_Y then self.y = GROUND_Y - 5 end
    if self.deathTimer <= 0 then self.finished = true end
    return
  end

  self.vy = min(72, self.vy + 190 * dt)
  self.y = self.y + self.vy * dt
  if self.y < 1 then
    self.y = 1
    self.vy = 0
  end

  local dx = self.speed * dt
  self.scroll = self.scroll + dx
  for _, p in ipairs(self.pipes) do
    p.x = p.x - dx
    if not p.passed and p.x + PIPE_W < BIRD_X then
      p.passed = true
      self.score = self.score + 1
      audio.play("coin", min(10, self.score))
    end
    if p.x + PIPE_W < 0 then
      local rightmost = 0
      for _, q in ipairs(self.pipes) do
        if q.x > rightmost then rightmost = q.x end
      end
      p.x = rightmost + PIPE_SPACING
      p.gapY = math.random(8, GROUND_Y - self.gap - 6)
      p.passed = false
    end
  end

  for _, cl in ipairs(self.clouds) do
    cl.x = cl.x - dx * 0.25
    if cl.x + cl.w < 0 then
      cl.x = W + math.random(0, 20)
      cl.y = math.random(4, 22)
      cl.w = math.random(8, 16)
    end
  end
  for _, hl in ipairs(self.hills) do
    hl.x = hl.x - dx * 0.5
    if hl.x + 14 < 0 then
      hl.x = hl.x + 9 * 14
      hl.h = math.random(5, 11)
    end
  end

  if self:collides() then self:die() end
end

---------------------------------------------------------------------- draw
function Game:draw()
  local c = self.c
  c:clear(colors.lightBlue)

  for _, cl in ipairs(self.clouds) do
    local x = floor(cl.x)
    c:fill(x, cl.y, cl.w, 3, colors.white)
    c:fill(x + 2, cl.y - 1, cl.w - 4, 1, colors.white)
  end

  -- distant hills are blue so they never read as pipes
  for _, hl in ipairs(self.hills) do
    local x = floor(hl.x)
    c:fill(x, GROUND_Y - hl.h, 14, hl.h, colors.blue)
    c:fill(x + 1, GROUND_Y - hl.h - 1, 12, 1, colors.blue)
  end

  for _, p in ipairs(self.pipes) do
    local x = floor(p.x)
    local topH, botY = self:pipeRects(p)
    if topH > 0 then
      c:fill(x, 1, PIPE_W, topH, colors.lime)
      c:fill(x, 1, 2, topH, colors.green)
      c:fill(x - 1, topH - 3, PIPE_W + 2, 3, colors.lime)
      c:fill(x - 1, topH - 3, 2, 3, colors.green)
      c:fill(x - 1, topH - 1, PIPE_W + 2, 1, colors.green)
    end
    c:fill(x, botY, PIPE_W, GROUND_Y - botY, colors.lime)
    c:fill(x, botY, 2, GROUND_Y - botY, colors.green)
    c:fill(x - 1, botY, PIPE_W + 2, 3, colors.lime)
    c:fill(x - 1, botY, 2, 3, colors.green)
    c:fill(x - 1, botY + 2, PIPE_W + 2, 1, colors.green)
  end

  c:fill(1, GROUND_Y, W, H - GROUND_Y + 1, colors.brown)
  c:fill(1, GROUND_Y, W, 2, colors.orange)
  local offset = floor(self.scroll) % 6
  for x = -offset, W, 6 do
    c:fill(x, GROUND_Y + 2, 3, 1, colors.brown)
  end

  local spr = self.wing > 0 and BIRD_UP or BIRD_SPRITE
  local tilt = 0
  if self.state == "play" or self.state == "dead" then
    tilt = self.vy > 20 and 1 or 0
  end
  c:draw(BIRD_X, floor(self.y) + tilt, spr, false, self.state == "dead" and self.vy > 40)

  if self.state == "ready" then
    font.center(c, 8, "PRESS SPACE", colors.white, 1, 1)
    font.center(c, 15, "TO FLAP", colors.white, 1, 1)
  else
    font.centerShadow(c, 4, tostring(self.score), colors.white, colors.blue, 2, 2)
  end

  c:render()

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  gfx.text(2, 1, "FLAPPY", colors.yellow, colors.gray)
  gfx.center(1, "PIPES " .. self.score, colors.white, colors.gray)
  local medal = "none"
  for _, m in ipairs(MEDALS) do
    if self.score >= m.at then medal = m.name break end
  end
  gfx.right(gfx.W - 1, 1, medal, colors.lightGray, colors.gray)
end

function Game:summary()
  local medal, colour = "no medal", colors.lightGray
  for _, m in ipairs(MEDALS) do
    if self.score >= m.at then
      medal = m.name
      colour = m.colour
      break
    end
  end
  local nextUp = nil
  for i = #MEDALS, 1, -1 do
    if self.score < MEDALS[i].at then
      nextUp = MEDALS[i]
      break
    end
  end
  local rows = { { "Medal", medal } }
  if nextUp then
    rows[#rows + 1] = { "Next medal", nextUp.at .. " pipes" }
  end
  return rows
end

---------------------------------------------------------------------- cover
local function cover(c, t)
  c:clear(colors.lightBlue)
  local scroll = t * 16
  for i = 1, 3 do
    local x = floor((-scroll * 0.4 + i * 22) % (c.w + 18)) - 16
    c:fill(x, 3 + i, 12, 3, colors.white)
  end
  for i = 1, 3 do
    local x = floor((-scroll + i * 20) % (c.w + 24)) - 12
    local gapY = 5 + ((i * 7) % 6)
    c:fill(x, 1, 8, gapY, colors.lime)
    c:fill(x - 1, gapY - 2, 10, 2, colors.green)
    c:fill(x, gapY + 8, 8, c.h - gapY - 11, colors.lime)
    c:fill(x - 1, gapY + 8, 10, 2, colors.green)
  end
  c:fill(1, c.h - 3, c.w, 3, colors.brown)
  c:fill(1, c.h - 3, c.w, 1, colors.orange)
  local by = 8 + math.sin(t * 3) * 4
  c:draw(14, floor(by), (math.sin(t * 3) > 0) and BIRD_UP or BIRD_SPRITE)
end

----------------------------------------------------------------- definition
return {
  id = "flappy",
  name = "Flappy",
  tagline = "One button, no mercy",
  accent = colors.yellow,
  order = 80,
  cover = cover,
  scoreLabel = "PIPES",
  controls = {
    { "Space / Up", "Flap" },
    { "Click", "Flap" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "normal", name = "Normal", hint = "wide gap", gap = 19, speed = 29 },
    { id = "tight", name = "Tight", hint = "narrow gap", gap = 15, speed = 33 },
    { id = "insane", name = "Insane", hint = "good luck", gap = 13, speed = 40 },
  },
  trophies = {
    { id = "fl_10", name = "Bronze Wings", desc = "Clear 10 pipes",
      test = function(g) return g.score >= 10 end },
    { id = "fl_30", name = "Golden Wings", desc = "Clear 30 pipes",
      test = function(g) return g.score >= 30 end },
    { id = "fl_insane", name = "Threading It", desc = "Clear 10 pipes on Insane",
      test = function(g) return g.score >= 10 and g.gap <= 13 end },
  },
  new = new,
}
