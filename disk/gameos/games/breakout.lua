--[[ Breakout -- 12x8 brick wall, multiball, lasers and falling power-ups.

  Bricks are three pixels tall and sit on the character grid, so each brick
  occupies exactly one character row and renders without colour bleeding.
]]

local req = ...
local gfx = req("lib.gfx")
local font = req("lib.font")
local audio = req("lib.audio")
local input = req("lib.input")

local floor = math.floor
local min, max = math.min, math.max

local COLS, ROWS = 12, 8
local BRICK_W, BRICK_H = 8, 3
-- The field starts on a character-cell boundary (odd x, y = 3k+1) so bricks
-- never share a cell with the wall, which would bleed colours together.
local FIELD_L, FIELD_R = 3, 98
local FIELD_T, FIELD_B = 4, 54
local BRICK_TOP = 10
local PADDLE_Y = 46
local PADDLE_H = 3

local Game = {}
Game.__index = Game

-- hoisted so the collision inner loop allocates nothing
local CORNERS = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }
local SPLIT_ANGLES = { 0.5, -0.5 }

------------------------------------------------------------------- levels
-- . empty  1-6 plain  A two hits  B three hits  X indestructible
local LEVELS = {
  {
    "............",
    "111111111111",
    "222222222222",
    "333333333333",
    "444444444444",
    "............",
    "............",
    "............",
  },
  {
    "..11111111..",
    ".22222222222",
    "333333333333",
    "44444AA44444",
    ".5555555555.",
    "..66666666..",
    "............",
    "............",
  },
  {
    "XX........XX",
    "11.222222.11",
    "11.2AAAA2.11",
    "11.2A44A2.11",
    "11.2AAAA2.11",
    "11.222222.11",
    "XX........XX",
    "............",
  },
  {
    "1.2.3.4.5.6.",
    ".2.3.4.5.6.1",
    "3.4.5.6.1.2.",
    ".4.5.6.1.2.3",
    "5.6.1.2.3.4.",
    ".6.1.2.3.4.5",
    "............",
    "............",
  },
  {
    "AAAAAAAAAAAA",
    "A..........A",
    "A.11111111.A",
    "A.1XXXXXX1.A",
    "A.11111111.A",
    "A..........A",
    "AAAAAAAAAAAA",
    "............",
  },
  {
    "......4.....",
    ".....444....",
    "....44444...",
    "...4444444..",
    "..BBBBBBBBB.",
    ".22222222222",
    "111111111111",
    "............",
  },
  {
    "1X1X1X1X1X1X",
    "222222222222",
    "3X3X3X3X3X3X",
    "AAAAAAAAAAAA",
    "5X5X5X5X5X5X",
    "666666666666",
    "............",
    "............",
  },
  {
    "....AAAA....",
    "...A6666A...",
    "..A655556A..",
    ".A65444456A.",
    "..A655556A..",
    "...A6666A...",
    "....AAAA....",
    "............",
  },
  {
    "BBBBBBBBBBBB",
    "B1B2B3B4B5B6",
    "BBBBBBBBBBBB",
    "6B5B4B3B2B1B",
    "BBBBBBBBBBBB",
    "B1B2B3B4B5B6",
    "BBBBBBBBBBBB",
    "............",
  },
  {
    "XBXBXBXBXBXB",
    "BBBBBBBBBBBB",
    "AAAAAAAAAAAA",
    "AA11AAAA11AA",
    "AAAAAAAAAAAA",
    "BBBBBBBBBBBB",
    "XBXBXBXBXBXB",
    "............",
  },
}

local BRICK_COLOUR = {
  ["1"] = colors.red, ["2"] = colors.orange, ["3"] = colors.yellow,
  ["4"] = colors.lime, ["5"] = colors.cyan, ["6"] = colors.magenta,
}
local TOUGH_COLOUR = { colors.lightGray, colors.white, colors.lightBlue }

------------------------------------------------------------------ powerups
local POWERS = {
  { id = "wide", letter = "W", colour = colors.lime, weight = 5 },
  { id = "multi", letter = "M", colour = colors.cyan, weight = 4 },
  { id = "laser", letter = "L", colour = colors.red, weight = 3 },
  { id = "slow", letter = "S", colour = colors.lightBlue, weight = 3 },
  { id = "catch", letter = "C", colour = colors.yellow, weight = 3 },
  { id = "life", letter = "+", colour = colors.magenta, weight = 1 },
  { id = "narrow", letter = "N", colour = colors.gray, weight = 2 },
}
local POWER_TOTAL = 0
for _, p in ipairs(POWERS) do POWER_TOTAL = POWER_TOTAL + p.weight end

local function rollPower()
  local r = math.random(1, POWER_TOTAL)
  for _, p in ipairs(POWERS) do
    r = r - p.weight
    if r <= 0 then return p end
  end
  return POWERS[1]
end

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.c = api.canvas.new(1, 2, gfx.W, 18, colors.black)
  self.startLevel = (mode and mode.level) or 1
  self.levelIndex = self.startLevel
  self.score = 0
  self.lives = 3
  self.bricksBroken = 0
  self.finished = false
  self.won = false
  self.message = nil
  self.messageTime = 0
  self:loadLevel()
  return self
end

function Game:loadLevel()
  local spec = LEVELS[((self.levelIndex - 1) % #LEVELS) + 1]
  self.bricks = {}
  self.remaining = 0
  for r = 1, ROWS do
    local row = {}
    local line = spec[r] or "............"
    for col = 1, COLS do
      local ch = line:sub(col, col)
      if ch == "." then
        row[col] = false
      elseif ch == "X" then
        row[col] = { hp = -1, colour = colors.gray, value = 0 }
      elseif ch == "A" then
        row[col] = { hp = 2, colour = TOUGH_COLOUR[2], value = 25 }
        self.remaining = self.remaining + 1
      elseif ch == "B" then
        row[col] = { hp = 3, colour = TOUGH_COLOUR[3], value = 40 }
        self.remaining = self.remaining + 1
      else
        row[col] = { hp = 1, colour = BRICK_COLOUR[ch] or colors.white, value = 10 }
        self.remaining = self.remaining + 1
      end
    end
    self.bricks[r] = row
  end

  self.paddleW = 16
  self.paddleX = floor((FIELD_L + FIELD_R - self.paddleW) / 2)
  self.balls = {}
  self.bolts = {}
  self.drops = {}
  self.laserShots = 0
  self.catchOn = false
  self.speedScale = 1
  self:launchBall()
  self:say("LEVEL " .. self.levelIndex)
end

function Game:say(text)
  self.message = text
  self.messageTime = 1.6
end

function Game:launchBall()
  self.balls = {
    {
      x = self.paddleX + self.paddleW / 2 - 1,
      y = PADDLE_Y - 2,
      vx = 0, vy = 0,
      stuck = true,
      speed = 46 + (self.levelIndex - 1) * 2,
    },
  }
end

function Game:release()
  for _, b in ipairs(self.balls) do
    if b.stuck then
      b.stuck = false
      local ang = -1.0
      b.vx = math.cos(ang) * b.speed
      b.vy = -math.abs(math.sin(ang)) * b.speed
      audio.play("bounce")
    end
  end
end

--------------------------------------------------------------------- input
function Game:onKey(code, held)
  if held then return end
  if code == keys.space or code == keys.up or code == keys.w then
    local anyStuck = false
    for _, b in ipairs(self.balls) do if b.stuck then anyStuck = true end end
    if anyStuck then
      self:release()
    elseif self.laserShots > 0 then
      self:fire()
    end
  end
end

function Game:onMouse(kind, btn, x, y)
  if kind == "mouse_click" or kind == "mouse_drag" then
    -- character column -> canvas pixel, centred on the paddle
    self.mouseTarget = (x - 1) * 2 + 1 - floor(self.paddleW / 2)
  end
end

function Game:fire()
  if self.laserShots <= 0 then return end
  self.laserShots = self.laserShots - 1
  self.bolts[#self.bolts + 1] = { x = self.paddleX + 1, y = PADDLE_Y - 3 }
  self.bolts[#self.bolts + 1] = { x = self.paddleX + self.paddleW - 2, y = PADDLE_Y - 3 }
  audio.play("laser")
end

------------------------------------------------------------------- bricks
function Game:brickAt(px, py)
  if py < BRICK_TOP or py >= BRICK_TOP + ROWS * BRICK_H then return nil end
  if px < FIELD_L or px > FIELD_R then return nil end
  local col = floor((px - FIELD_L) / BRICK_W) + 1
  local row = floor((py - BRICK_TOP) / BRICK_H) + 1
  if col < 1 or col > COLS or row < 1 or row > ROWS then return nil end
  if self.bricks[row][col] then return row, col end
  return nil
end

function Game:hitBrick(row, col)
  local brick = self.bricks[row][col]
  if not brick then return false end
  if brick.hp < 0 then
    audio.play("thud")
    return true
  end
  brick.hp = brick.hp - 1
  if brick.hp > 0 then
    brick.colour = TOUGH_COLOUR[min(#TOUGH_COLOUR, brick.hp)]
    audio.play("thud")
    return true
  end
  self.bricks[row][col] = false
  self.remaining = self.remaining - 1
  self.bricksBroken = self.bricksBroken + 1
  self.score = self.score + brick.value * self.levelIndex
  audio.play("hit")
  if math.random(1, 100) <= 14 then
    local p = rollPower()
    self.drops[#self.drops + 1] = {
      x = FIELD_L + (col - 1) * BRICK_W + 1,
      y = BRICK_TOP + (row - 1) * BRICK_H,
      power = p,
    }
  end
  return true
end

------------------------------------------------------------------ powerups
function Game:applyPower(p)
  audio.play("powerup")
  self:say(p.id:upper())
  if p.id == "wide" then
    self.paddleW = min(30, self.paddleW + 6)
  elseif p.id == "narrow" then
    self.paddleW = max(8, self.paddleW - 4)
  elseif p.id == "multi" then
    local seeds = {}
    for _, b in ipairs(self.balls) do seeds[#seeds + 1] = b end
    for _, b in ipairs(seeds) do
      local vx, vy = b.vx, b.vy
      if vx * vx + vy * vy < 1 then vx, vy = 0, -b.speed end
      -- rotate the parent velocity rather than going through atan, which
      -- differs between Lua 5.2 and later versions
      for _, ang in ipairs(SPLIT_ANGLES) do
        if #self.balls < 6 then
          local ca, sa = math.cos(ang), math.sin(ang)
          self.balls[#self.balls + 1] = {
            x = b.x, y = b.y, stuck = false, speed = b.speed,
            vx = vx * ca - vy * sa,
            vy = vx * sa + vy * ca,
          }
        end
      end
    end
  elseif p.id == "laser" then
    self.laserShots = self.laserShots + 12
  elseif p.id == "slow" then
    self.speedScale = max(0.65, self.speedScale - 0.18)
  elseif p.id == "catch" then
    self.catchOn = true
  elseif p.id == "life" then
    self.lives = self.lives + 1
  end
end

-------------------------------------------------------------------- update
function Game:movePaddle(dt)
  local speed = 62
  local dx = 0
  if input.down(keys.left, keys.a) then dx = dx - 1 end
  if input.down(keys.right, keys.d) then dx = dx + 1 end
  self.paddleVX = dx * speed
  self.paddleX = self.paddleX + dx * speed * dt
  if self.mouseTarget then
    self.paddleX = self.mouseTarget
    self.mouseTarget = nil
  end
  if self.paddleX < FIELD_L then self.paddleX = FIELD_L end
  if self.paddleX + self.paddleW - 1 > FIELD_R then
    self.paddleX = FIELD_R - self.paddleW + 1
  end
end

function Game:ballStep(b, dt)
  local steps = max(1, floor((math.abs(b.vx) + math.abs(b.vy)) * dt * self.speedScale) + 1)
  local sx = b.vx * dt * self.speedScale / steps
  local sy = b.vy * dt * self.speedScale / steps
  for _ = 1, steps do
    -- horizontal
    local nx = b.x + sx
    if nx < FIELD_L then
      nx = FIELD_L
      b.vx = math.abs(b.vx)
      sx = -sx
      audio.play("bounce")
    elseif nx + 1 > FIELD_R then
      nx = FIELD_R - 1
      b.vx = -math.abs(b.vx)
      sx = -sx
      audio.play("bounce")
    end
    local hitX = false
    for _, corner in ipairs(CORNERS) do
      local r, col = self:brickAt(floor(nx) + corner[1], floor(b.y) + corner[2])
      if r then
        self:hitBrick(r, col)
        hitX = true
        break
      end
    end
    if hitX then
      b.vx = -b.vx
      sx = -sx
    else
      b.x = nx
    end

    -- vertical
    local ny = b.y + sy
    if ny < FIELD_T then
      ny = FIELD_T
      b.vy = math.abs(b.vy)
      sy = -sy
      audio.play("bounce")
    end
    local hitY = false
    for _, corner in ipairs(CORNERS) do
      local r, col = self:brickAt(floor(b.x) + corner[1], floor(ny) + corner[2])
      if r then
        self:hitBrick(r, col)
        hitY = true
        break
      end
    end
    if hitY then
      b.vy = -b.vy
      sy = -sy
    else
      b.y = ny
    end

    -- paddle
    if b.vy > 0 and b.y + 1 >= PADDLE_Y and b.y <= PADDLE_Y + PADDLE_H then
      if b.x + 1 >= self.paddleX and b.x <= self.paddleX + self.paddleW - 1 then
        b.y = PADDLE_Y - 2
        local rel = ((b.x + 1) - self.paddleX) / self.paddleW
        rel = max(0, min(1, rel))
        local angle = (rel - 0.5) * 2.0
        -- Never return the ball perfectly vertically: it would bounce up and
        -- down the same column forever once that column is cleared.
        if math.abs(angle) < 0.26 then
          angle = angle >= 0 and 0.26 or -0.26
        end
        b.speed = min(96, b.speed + 0.6)
        b.vx = math.sin(angle * 1.05) * b.speed + (self.paddleVX or 0) * 0.18
        b.vy = -math.abs(math.cos(angle * 1.05)) * b.speed
        if math.abs(b.vy) < b.speed * 0.35 then
          b.vy = -b.speed * 0.35
        end
        if self.catchOn then
          b.stuck = true
          b.vx, b.vy = 0, 0
        end
        audio.play("bounce")
        return
      end
    end
  end
end

function Game:update(dt)
  if self.finished then return end
  if self.messageTime > 0 then
    self.messageTime = self.messageTime - dt
    if self.messageTime <= 0 then self.message = nil end
  end

  self:movePaddle(dt)

  for i = #self.balls, 1, -1 do
    local b = self.balls[i]
    if b.stuck then
      b.x = self.paddleX + self.paddleW / 2 - 1
      b.y = PADDLE_Y - 2
    else
      self:ballStep(b, dt)
      if b.y > FIELD_B then table.remove(self.balls, i) end
    end
  end

  if #self.balls == 0 then
    self.lives = self.lives - 1
    audio.play("gameover")
    if self.lives <= 0 then
      self.finished = true
      return
    end
    self.paddleW = 16
    self.catchOn = false
    self.speedScale = 1
    self.laserShots = 0
    self:launchBall()
    self:say("LIVES " .. self.lives)
  end

  for i = #self.bolts, 1, -1 do
    local bolt = self.bolts[i]
    bolt.y = bolt.y - 110 * dt
    local r, col = self:brickAt(floor(bolt.x), floor(bolt.y))
    if r then
      self:hitBrick(r, col)
      table.remove(self.bolts, i)
    elseif bolt.y < FIELD_T then
      table.remove(self.bolts, i)
    end
  end

  for i = #self.drops, 1, -1 do
    local d = self.drops[i]
    d.y = d.y + 24 * dt
    if d.y > FIELD_B then
      table.remove(self.drops, i)
    elseif d.y + 3 >= PADDLE_Y and d.y <= PADDLE_Y + PADDLE_H and
           d.x + 6 >= self.paddleX and d.x <= self.paddleX + self.paddleW then
      self.score = self.score + 40
      self:applyPower(d.power)
      table.remove(self.drops, i)
    end
  end

  if self.remaining <= 0 then
    self.score = self.score + 150 * self.levelIndex
    self.levelIndex = self.levelIndex + 1
    if self.levelIndex > #LEVELS then
      self.won = true
      self.finished = true
      audio.play("win")
      return
    end
    audio.play("levelup")
    self:loadLevel()
  end
end

---------------------------------------------------------------------- draw
function Game:draw()
  local c = self.c
  c:clear(colors.black)

  c:fill(1, 1, FIELD_L - 1, 54, colors.gray)
  c:fill(FIELD_R + 1, 1, 102 - FIELD_R, 54, colors.gray)
  c:fill(1, 1, 102, FIELD_T - 1, colors.gray)

  for r = 1, ROWS do
    local row = self.bricks[r]
    local y = BRICK_TOP + (r - 1) * BRICK_H
    for col = 1, COLS do
      local brick = row[col]
      if brick then
        local x = FIELD_L + (col - 1) * BRICK_W
        c:fill(x, y, BRICK_W, BRICK_H, brick.colour)
        c:fill(x + BRICK_W - 1, y, 1, BRICK_H, colors.black)
        c:fill(x, y + BRICK_H - 1, BRICK_W, 1, colors.black)
      end
    end
  end

  for _, d in ipairs(self.drops) do
    c:fill(d.x, floor(d.y), 6, 3, d.power.colour)
    c:set(d.x + 2, floor(d.y) + 1, colors.black)
  end

  for _, bolt in ipairs(self.bolts) do
    c:fill(floor(bolt.x), floor(bolt.y), 1, 3, colors.red)
  end

  local px = floor(self.paddleX)
  c:fill(px, PADDLE_Y, self.paddleW, PADDLE_H, colors.lightBlue)
  c:fill(px, PADDLE_Y, self.paddleW, 1, colors.white)
  if self.laserShots > 0 then
    c:fill(px, PADDLE_Y - 1, 2, 1, colors.red)
    c:fill(px + self.paddleW - 2, PADDLE_Y - 1, 2, 1, colors.red)
  end

  for _, b in ipairs(self.balls) do
    c:fill(floor(b.x), floor(b.y), 2, 2, colors.white)
  end

  if self.message then
    local w = font.width(self.message, 1, 1)
    local bx = floor((102 - w) / 2)
    c:fill(bx - 3, 37, w + 6, 9, colors.black)
    font.draw(c, bx, 39, self.message, colors.yellow, 1, 1)
  end

  c:render()

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  gfx.text(2, 1, "SCORE", colors.lightGray, colors.gray)
  gfx.text(8, 1, gfx.commas(self.score), colors.white, colors.gray)
  gfx.center(1, "LEVEL " .. self.levelIndex, colors.cyan, colors.gray)
  local hearts = string.rep("*", max(0, self.lives))
  gfx.right(gfx.W - 1, 1, hearts, colors.red, colors.gray)
  if self.laserShots > 0 then
    gfx.right(gfx.W - 6, 1, "L" .. self.laserShots, colors.orange, colors.gray)
  end
end

function Game:summary()
  return {
    { "Level reached", self.levelIndex },
    { "Bricks", self.bricksBroken },
    { "Lives left", max(0, self.lives) },
  }
end

---------------------------------------------------------------------- cover
local COVER_ROWS = {
  colors.red, colors.orange, colors.yellow, colors.lime,
}

local function cover(c, t)
  c:clear(colors.black)
  for r = 1, 4 do
    for col = 0, 6 do
      local x = 2 + col * 8
      local drop = math.sin(t * 1.5 + col + r) > 0.85
      if not drop then
        c:fill(x, 2 + (r - 1) * 3, 7, 2, COVER_ROWS[r])
      end
    end
  end
  local bx = 6 + (math.sin(t * 1.7) + 1) * 20
  c:fill(floor(bx), 17, 2, 2, colors.white)
  local paddle = 16 + (math.sin(t * 1.7 - 0.4) + 1) * 18
  c:fill(floor(paddle), c.h - 2, 14, 2, colors.lightBlue)
  c:fill(floor(paddle), c.h - 2, 14, 1, colors.white)
end

----------------------------------------------------------------- definition
return {
  id = "breakout",
  name = "Breakout",
  tagline = "Ten walls, three lives",
  accent = colors.orange,
  order = 30,
  cover = cover,
  controls = {
    { "Left / Right", "Move paddle" },
    { "Mouse", "Move paddle" },
    { "Space", "Launch / fire" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "start1", name = "Level 1", hint = "from the top", level = 1 },
    { id = "start4", name = "Level 4", hint = "skip ahead", level = 4 },
    { id = "start7", name = "Level 7", hint = "expert", level = 7 },
  },
  trophies = {
    { id = "brk_l3", name = "Wall Breaker", desc = "Reach level 3",
      test = function(g) return g.levelIndex >= 3 end },
    { id = "brk_200", name = "Demolition", desc = "Break 200 bricks in one run",
      test = function(g) return g.bricksBroken >= 200 end },
    { id = "brk_clear", name = "Clean Sweep", desc = "Clear every wall",
      test = function(g) return g.won end },
  },
  new = new,
}
