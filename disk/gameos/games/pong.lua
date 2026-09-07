--[[ Pong -- first to eleven, against the machine or a friend.

  The CPU predicts where the ball will arrive, then aims at that point plus a
  fresh random error chosen once per exchange and scaled by difficulty. Easy
  opponents therefore miss honestly rather than by being artificially slowed,
  and the error does not repeat identically rally after rally.

  A dead-centre return is nudged off flat, and the ball keeps accelerating, so
  two well-matched players cannot rally forever.
]]

local req = ...
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local audio = req("lib.audio")
local input = req("lib.input")

local floor = math.floor
local abs = math.abs
local max, min = math.max, math.min

local W, H = 102, 54
-- Walls occupy whole character rows (y = 3k+1, three pixels tall) so the
-- score digits above them never share a cell with the court.
local COURT_TOP, COURT_BOTTOM = 16, 51
local PADDLE_H, PADDLE_W = 13, 3
local LEFT_X, RIGHT_X = 6, 93
local TARGET = 11

local Game = {}
Game.__index = Game

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.c = Canvas.new(1, 2, gfx.W, 18, colors.black)
  self.twoPlayer = (mode and mode.twoPlayer) or false
  self.cpuSkill = (mode and mode.skill) or 0.6
  self.leftY = floor((COURT_TOP + COURT_BOTTOM - PADDLE_H) / 2)
  self.rightY = self.leftY
  self.leftScore = 0
  self.rightScore = 0
  self.rallies = 0
  self.longestRally = 0
  self.score = 0
  self.finished = false
  self.won = false
  self.serveTimer = 1.2
  self.flash = 0
  self:serve(math.random(1, 2) == 1 and 1 or -1)
  return self
end

function Game:serve(dir)
  self.ball = {
    x = W / 2 - 1,
    y = (COURT_TOP + COURT_BOTTOM) / 2,
    vx = dir * 42,
    vy = (math.random() - 0.5) * 34,
    speed = 42,
  }
  self.serveTimer = 1.0
  self.rallies = 0
  self.cpuTarget = (COURT_TOP + COURT_BOTTOM) / 2
  self:cpuAim()
end

--------------------------------------------------------------------- input
function Game:onKey(code, held) end

-------------------------------------------------------------------- update
function Game:movePaddle(y, dir, dt, speed)
  y = y + dir * speed * dt
  if y < COURT_TOP then y = COURT_TOP end
  if y + PADDLE_H - 1 > COURT_BOTTOM then y = COURT_BOTTOM - PADDLE_H + 1 end
  return y
end

--- Pick a fresh aiming error for the coming return. Doing this once per
--- exchange (rather than as a function of ball position) is what makes the
--- easy CPU genuinely miss and the hard CPU genuinely dangerous.
function Game:cpuAim()
  -- Even the hardest setting keeps a floor of error, and a fast ball is
  -- harder to read, so a long rally always ends in a point eventually.
  local speed = (self.ball and self.ball.speed) or 42
  local spread = (6 + (1 - self.cpuSkill) * 20) * (0.75 + speed / 220)
  self.cpuError = (math.random() - 0.5) * 2 * spread
  self.cpuWake = 8 + (1 - self.cpuSkill) * 40
end

function Game:cpuThink(dt)
  local b = self.ball
  -- only track once the ball is heading this way and has cleared the net
  if b.vx > 0 and b.x > (self.cpuWake or 0) then
    local travel = (RIGHT_X - b.x) / max(1, b.vx)
    local predicted = b.y + b.vy * travel
    -- fold the prediction back into the court to approximate wall bounces
    local span = COURT_BOTTOM - COURT_TOP
    local rel = (predicted - COURT_TOP) % (span * 2)
    if rel < 0 then rel = rel + span * 2 end
    if rel > span then rel = span * 2 - rel end
    predicted = COURT_TOP + rel
    self.cpuTarget = predicted + (self.cpuError or 0)
  else
    self.cpuTarget = (COURT_TOP + COURT_BOTTOM) / 2
  end
  local centre = self.rightY + PADDLE_H / 2
  local delta = self.cpuTarget - centre
  local speed = 34 + self.cpuSkill * 34
  if abs(delta) > 1.5 then
    self.rightY = self:movePaddle(self.rightY, delta > 0 and 1 or -1, dt, speed)
  end
end

function Game:point(side)
  if side == "left" then
    self.leftScore = self.leftScore + 1
  else
    self.rightScore = self.rightScore + 1
  end
  self.flash = 0.3
  audio.play(side == "left" and "coin" or "deny")
  if self.leftScore >= TARGET or self.rightScore >= TARGET then
    self.finished = true
    self.won = self.leftScore > self.rightScore
    self.score = self.leftScore * 100 + max(0, self.leftScore - self.rightScore) * 50 + self.longestRally * 10
    audio.play(self.won and "win" or "gameover")
    return
  end
  self:serve(side == "left" and 1 or -1)
end

function Game:update(dt)
  if self.finished then return end
  if self.flash > 0 then self.flash = self.flash - dt end

  local pspeed = 62
  local ldir = 0
  if input.down(keys.w, keys.up) then ldir = ldir - 1 end
  if input.down(keys.s, keys.down) then ldir = ldir + 1 end
  self.leftY = self:movePaddle(self.leftY, ldir, dt, pspeed)

  if self.twoPlayer then
    local rdir = 0
    if input.down(keys.i, keys.pageUp) then rdir = rdir - 1 end
    if input.down(keys.k, keys.pageDown) then rdir = rdir + 1 end
    self.rightY = self:movePaddle(self.rightY, rdir, dt, pspeed)
  else
    self:cpuThink(dt)
  end

  if self.serveTimer > 0 then
    self.serveTimer = self.serveTimer - dt
    return
  end

  local b = self.ball
  local steps = max(1, floor((abs(b.vx) + abs(b.vy)) * dt) + 1)
  local sx, sy = b.vx * dt / steps, b.vy * dt / steps
  for _ = 1, steps do
    b.x = b.x + sx
    b.y = b.y + sy

    if b.y < COURT_TOP then
      b.y = COURT_TOP
      b.vy = abs(b.vy)
      sy = -sy
      audio.play("bounce")
    elseif b.y + 2 > COURT_BOTTOM then
      b.y = COURT_BOTTOM - 2
      b.vy = -abs(b.vy)
      sy = -sy
      audio.play("bounce")
    end

    if b.vx < 0 and b.x <= LEFT_X + PADDLE_W and b.x >= LEFT_X - 3 then
      if b.y + 2 >= self.leftY and b.y <= self.leftY + PADDLE_H - 1 then
        self:bounce(b, self.leftY, 1)
        sx, sy = b.vx * dt / steps, b.vy * dt / steps
      end
    elseif b.vx > 0 and b.x + 2 >= RIGHT_X and b.x <= RIGHT_X + PADDLE_W + 3 then
      if b.y + 2 >= self.rightY and b.y <= self.rightY + PADDLE_H - 1 then
        self:bounce(b, self.rightY, -1)
        sx, sy = b.vx * dt / steps, b.vy * dt / steps
      end
    end

    if b.x < -4 then
      self:point("right")
      return
    elseif b.x > W + 4 then
      self:point("left")
      return
    end
  end
end

function Game:bounce(b, paddleY, dir)
  local rel = ((b.y + 1) - paddleY) / PADDLE_H
  rel = max(0, min(1, rel))
  local angle = (rel - 0.5) * 1.5
  -- A dead-centre hit would send the ball perfectly flat, and two paddles
  -- tracking a flat ball rally forever. Always keep some vertical drift.
  if math.abs(angle) < 0.2 then
    angle = angle >= 0 and 0.2 or -0.2
  end
  b.speed = min(124, b.speed + 4.2)
  b.vx = dir * math.cos(angle) * b.speed
  b.vy = math.sin(angle) * b.speed
  b.x = dir > 0 and (LEFT_X + PADDLE_W + 1) or (RIGHT_X - 3)
  if dir > 0 then self:cpuAim() end
  self.rallies = self.rallies + 1
  if self.rallies > self.longestRally then self.longestRally = self.rallies end
  audio.play("blip", min(10, self.rallies))
end

---------------------------------------------------------------------- draw
function Game:draw()
  local c = self.c
  c:clear(colors.black)

  for y = COURT_TOP, COURT_BOTTOM, 6 do
    c:fill(floor(W / 2), y, 2, 3, colors.gray)
  end
  c:fill(1, COURT_TOP - 3, W, 3, colors.gray)
  c:fill(1, COURT_BOTTOM + 1, W, 3, colors.gray)

  local leftCol = self.flash > 0 and self.leftScore > self.rightScore and colors.white or colors.cyan
  c:fill(LEFT_X, floor(self.leftY), PADDLE_W, PADDLE_H, leftCol)
  c:fill(RIGHT_X, floor(self.rightY), PADDLE_W, PADDLE_H, colors.magenta)

  if self.serveTimer <= 0 then
    c:fill(floor(self.ball.x), floor(self.ball.y), 3, 3, colors.white)
  elseif floor(self.serveTimer * 6) % 2 == 0 then
    c:fill(floor(self.ball.x), floor(self.ball.y), 3, 3, colors.lightGray)
  end

  local ls = tostring(self.leftScore)
  local rs = tostring(self.rightScore)
  font.draw(c, floor(W / 2) - 8 - font.width(ls, 2, 2), 1, ls, colors.cyan, 2, 2)
  font.draw(c, floor(W / 2) + 9, 1, rs, colors.magenta, 2, 2)

  c:render()

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  gfx.text(2, 1, self.twoPlayer and "P1  W/S" or "YOU  W/S", colors.cyan, colors.gray)
  gfx.center(1, "FIRST TO " .. TARGET, colors.lightGray, colors.gray)
  gfx.right(gfx.W - 1, 1, self.twoPlayer and "P2  I/K" or "CPU", colors.magenta, colors.gray)
end

function Game:summary()
  return {
    { "Final score", self.leftScore .. " - " .. self.rightScore },
    { "Longest rally", self.longestRally },
  }
end

---------------------------------------------------------------------- cover
local function cover(c, t)
  c:clear(colors.black)
  for y = 1, c.h, 5 do
    c:fill(floor(c.w / 2), y, 2, 3, colors.gray)
  end
  local bx = floor((math.sin(t * 1.6) * 0.5 + 0.5) * (c.w - 12)) + 5
  local by = floor((math.sin(t * 2.7) * 0.5 + 0.5) * (c.h - 8)) + 3
  c:fill(bx, by, 3, 3, colors.white)
  local ly = min(c.h - 10, max(2, by - 4))
  c:fill(3, ly, 3, 9, colors.cyan)
  local ry = min(c.h - 10, max(2, floor(by - 4 + math.sin(t * 2) * 3)))
  c:fill(c.w - 5, ry, 3, 9, colors.magenta)
end

----------------------------------------------------------------- definition
return {
  id = "pong",
  name = "Pong",
  tagline = "The original, first to 11",
  accent = colors.cyan,
  order = 90,
  cover = cover,
  controls = {
    { "W / S", "Left paddle" },
    { "Up / Down", "Left paddle" },
    { "I / K", "Right paddle (2P)" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "easy", name = "CPU: Easy", hint = "forgiving", skill = 0.35 },
    { id = "normal", name = "CPU: Normal", hint = "fair", skill = 0.62 },
    { id = "hard", name = "CPU: Hard", hint = "ruthless", skill = 0.92 },
    { id = "two", name = "Two players", hint = "W/S vs I/K", twoPlayer = true },
  },
  trophies = {
    { id = "pong_win", name = "Match Point", desc = "Win a match",
      test = function(g) return g.won end },
    { id = "pong_shutout", name = "Shutout", desc = "Win eleven to nothing",
      test = function(g) return g.won and g.rightScore == 0 end },
    { id = "pong_hard", name = "Machine Beater", desc = "Beat the hard CPU",
      test = function(g) return g.won and not g.twoPlayer and g.cpuSkill >= 0.9 end },
  },
  new = new,
}
