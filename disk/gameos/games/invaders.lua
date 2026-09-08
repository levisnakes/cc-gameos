--[[ Invaders -- a 40-strong formation, four destructible shields and a UFO.

  The formation steps rather than glides, and the step interval shrinks as the
  wave thins out, so the last few aliens really do come at you fast.
]]

local req = ...
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local audio = req("lib.audio")
local input = req("lib.input")

local floor = math.floor
local min, max = math.min, math.max

local FIELD_W, FIELD_H = 102, 54
local COLS, ROWS = 8, 5
local STEP_X, STEP_Y = 2, 4
local GAP_X, GAP_Y = 11, 7
local PLAYER_Y = 47
local SHIELD_Y = 39

local Game = {}
Game.__index = Game

------------------------------------------------------------------- sprites
local SPRITE_SRC = {
  a1 = { "..####..", ".######.", "##.##.##", "########", ".#.##.#." },
  a2 = { "..####..", ".######.", "##.##.##", "########", "#.#..#.#" },
  b1 = { "#..##..#", ".######.", "##.##.##", "########", ".#....#." },
  b2 = { "#..##..#", ".######.", "##.##.##", "########", "#.####.#" },
  c1 = { "..####..", ".######.", "########", "#.#..#.#", "..#..#.." },
  c2 = { "..####..", ".######.", "########", "#.#..#.#", ".#.##.#." },
  ship = { "....#....", "...###...", ".#######.", "#########", "#########" },
  ufo = { "..######..", ".########.", "##########", ".#.#..#.#." },
}

local SHIELD_SRC = {
  "..########..",
  ".##########.",
  "############",
  "############",
  "###......###",
  "##........##",
}

local ALIEN_KIND = {
  { frames = { "a1", "a2" }, colour = colors.magenta, value = 30 },
  { frames = { "b1", "b2" }, colour = colors.cyan, value = 20 },
  { frames = { "b1", "b2" }, colour = colors.lightBlue, value = 20 },
  { frames = { "c1", "c2" }, colour = colors.lime, value = 10 },
  { frames = { "c1", "c2" }, colour = colors.green, value = 10 },
}

-- Built at load time so the launcher can animate the cover before the game
-- has ever been started.
local sprites = {}
for name, rows in pairs(SPRITE_SRC) do
  sprites[name] = Canvas.sprite(rows, { ["#"] = colors.white })
end

--- Stamp a white-mask sprite in an arbitrary colour.
local function stamp(c, spr, px, py, colour)
  local w = spr.w
  for sy = 1, spr.h do
    local base = (sy - 1) * w
    for sx = 1, w do
      if spr.px[base + sx] then c:set(px + sx - 1, py + sy - 1, colour) end
    end
  end
end

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.c = Canvas.new(1, 2, gfx.W, 18, colors.black)
  self.hard = (mode and mode.hard) or false
  self.score = 0
  self.lives = 3
  self.wave = 1
  self.kills = 0
  self.finished = false
  self.playerX = floor(FIELD_W / 2) - 4
  self.shots = {}
  self.bombs = {}
  self.particles = {}
  self.ufo = nil
  self.ufoTimer = 14
  self.respawn = 0
  self:startWave()
  return self
end

function Game:startWave()
  self.aliens = {}
  self.alive = 0
  local baseY = 4 + min(4, (self.wave - 1)) * 2
  for r = 1, ROWS do
    for col = 1, COLS do
      self.aliens[(r - 1) * COLS + col] = {
        row = r, col = col, alive = true,
        x = 4 + (col - 1) * GAP_X,
        y = baseY + (r - 1) * GAP_Y,
      }
      self.alive = self.alive + 1
    end
  end
  self.dir = 1
  self.stepTimer = 0
  self.frame = 1
  self.dropped = false

  self.shields = {}
  for i = 1, 4 do
    local grid = {}
    for y = 1, #SHIELD_SRC do
      local line = SHIELD_SRC[y]
      for x = 1, #line do
        grid[(y - 1) * 12 + x] = (line:sub(x, x) == "#")
      end
    end
    self.shields[i] = { x = 8 + (i - 1) * 24, y = SHIELD_Y, px = grid }
  end
  self.waveMessage = 1.4
end

function Game:stepInterval()
  local frac = self.alive / (COLS * ROWS)
  local base = self.hard and 0.42 or 0.55
  local fastest = self.hard and 0.045 or 0.07
  local t = fastest + (base - fastest) * frac
  return max(fastest, t - (self.wave - 1) * 0.02)
end

---------------------------------------------------------------- collisions
function Game:shieldHit(px, py, erase)
  for i = 1, 4 do
    local s = self.shields[i]
    local lx = px - s.x + 1
    local ly = py - s.y + 1
    if lx >= 1 and lx <= 12 and ly >= 1 and ly <= #SHIELD_SRC then
      local idx = (ly - 1) * 12 + lx
      if s.px[idx] then
        if erase then
          -- blast a small crater
          for dy = -1, 1 do
            for dx = -2, 2 do
              local nx, ny = lx + dx, ly + dy
              if nx >= 1 and nx <= 12 and ny >= 1 and ny <= #SHIELD_SRC then
                if math.random(1, 100) > 25 then
                  s.px[(ny - 1) * 12 + nx] = false
                end
              end
            end
          end
        end
        return true
      end
    end
  end
  return false
end

function Game:boom(x, y, colour, count)
  for _ = 1, (count or 8) do
    self.particles[#self.particles + 1] = {
      x = x, y = y,
      vx = (math.random() - 0.5) * 40,
      vy = (math.random() - 0.5) * 40,
      life = 0.3 + math.random() * 0.3,
      colour = colour,
    }
  end
end

--------------------------------------------------------------------- input
function Game:onKey(code, held)
  if held then return end
  if code == keys.space or code == keys.up or code == keys.w then
    self:fire()
  end
end

function Game:fire()
  if self.respawn > 0 then return end
  local limit = self.wave >= 3 and 2 or 1
  if #self.shots >= limit then return end
  self.shots[#self.shots + 1] = { x = self.playerX + 4, y = PLAYER_Y - 1 }
  audio.play("inv.shoot")
end

-------------------------------------------------------------------- update
function Game:lowestInColumn(col)
  local found = nil
  for r = 1, ROWS do
    local a = self.aliens[(r - 1) * COLS + col]
    if a and a.alive then found = a end
  end
  return found
end

function Game:dropBomb()
  local candidates = {}
  for col = 1, COLS do
    local a = self:lowestInColumn(col)
    if a then candidates[#candidates + 1] = a end
  end
  if #candidates == 0 then return end
  local a = candidates[math.random(1, #candidates)]
  self.bombs[#self.bombs + 1] = { x = a.x + 4, y = a.y + 5, t = 0 }
end

function Game:advanceFormation()
  local minX, maxX, maxY = 999, -999, -999
  for i = 1, #self.aliens do
    local a = self.aliens[i]
    if a.alive then
      if a.x < minX then minX = a.x end
      if a.x + 8 > maxX then maxX = a.x + 8 end
      if a.y + 5 > maxY then maxY = a.y + 5 end
    end
  end
  if minX == 999 then return end

  local drop = false
  if self.dir > 0 and maxX + STEP_X > FIELD_W - 2 then drop = true end
  if self.dir < 0 and minX - STEP_X < 3 then drop = true end

  for i = 1, #self.aliens do
    local a = self.aliens[i]
    if a.alive then
      if drop then
        a.y = a.y + STEP_Y
      else
        a.x = a.x + self.dir * STEP_X
      end
    end
  end
  if drop then self.dir = -self.dir end
  self.frame = 3 - self.frame
  -- the march walks down four steps, the way the original does
  self.marchStep = (self.marchStep or 0) % 4 + 1
  audio.play("inv.march" .. self.marchStep)

  if maxY + (drop and STEP_Y or 0) >= PLAYER_Y then
    self.lives = 0
    self.finished = true
    audio.play("inv.die")
  end
end

function Game:update(dt)
  if self.finished then return end
  if self.waveMessage > 0 then self.waveMessage = self.waveMessage - dt end

  if self.respawn > 0 then
    self.respawn = self.respawn - dt
    if self.respawn <= 0 and self.lives <= 0 then
      self.finished = true
    end
  end

  -- player
  if self.respawn <= 0 then
    local dx = 0
    if input.down(keys.left, keys.a) then dx = dx - 1 end
    if input.down(keys.right, keys.d) then dx = dx + 1 end
    self.playerX = self.playerX + dx * 52 * dt
    if self.playerX < 3 then self.playerX = 3 end
    if self.playerX + 9 > FIELD_W - 2 then self.playerX = FIELD_W - 2 - 9 end
  end

  -- formation
  self.stepTimer = self.stepTimer + dt
  local interval = self:stepInterval()
  local guard = 0
  while self.stepTimer >= interval and guard < 3 do
    self.stepTimer = self.stepTimer - interval
    guard = guard + 1
    self:advanceFormation()
  end

  -- ufo
  self.ufoTimer = self.ufoTimer - dt
  if not self.ufo and self.ufoTimer <= 0 then
    self.ufoTimer = 16 + math.random() * 12
    local fromLeft = math.random(1, 2) == 1
    self.ufo = {
      x = fromLeft and -10 or FIELD_W,
      dir = fromLeft and 1 or -1,
      value = ({ 50, 100, 150, 200 })[math.random(1, 4)],
    }
  end
  if self.ufo then
    self.ufo.x = self.ufo.x + self.ufo.dir * 26 * dt
    if self.ufo.x < -12 or self.ufo.x > FIELD_W + 2 then self.ufo = nil end
  end

  -- bombs
  local rate = 0.55 - min(0.35, self.wave * 0.05)
  self.bombTimer = (self.bombTimer or 0) + dt
  if self.bombTimer > rate and #self.bombs < 4 + self.wave then
    self.bombTimer = 0
    if math.random(1, 100) <= 55 then self:dropBomb() end
  end

  for i = #self.bombs, 1, -1 do
    local b = self.bombs[i]
    b.y = b.y + 30 * dt
    b.t = b.t + dt
    local hit = false
    if self:shieldHit(floor(b.x), floor(b.y), true) then
      hit = true
      audio.play("inv.shield")
    elseif b.y >= PLAYER_Y and b.y <= PLAYER_Y + 5 and self.respawn <= 0 and
           b.x >= self.playerX and b.x <= self.playerX + 9 then
      hit = true
      self.lives = self.lives - 1
      self.respawn = 1.4
      self:boom(self.playerX + 4, PLAYER_Y + 2, colors.orange, 16)
      audio.play("inv.die")
      for j = #self.bombs, 1, -1 do table.remove(self.bombs, j) end
      break
    elseif b.y > FIELD_H then
      hit = true
    end
    if hit then table.remove(self.bombs, i) end
  end

  -- shots
  for i = #self.shots, 1, -1 do
    local s = self.shots[i]
    s.y = s.y - 84 * dt
    local gone = false
    if s.y < 1 then
      gone = true
    elseif self.ufo and s.y <= 6 and s.x >= self.ufo.x and s.x <= self.ufo.x + 10 then
      self.score = self.score + self.ufo.value
      self:boom(self.ufo.x + 5, 3, colors.magenta, 14)
      self.ufo = nil
      gone = true
      audio.play("inv.ufohit")
    elseif self:shieldHit(floor(s.x), floor(s.y), true) then
      gone = true
      audio.play("inv.shield")
    else
      for k = 1, #self.aliens do
        local a = self.aliens[k]
        if a.alive and s.x >= a.x and s.x < a.x + 8 and s.y >= a.y and s.y < a.y + 5 then
          a.alive = false
          self.alive = self.alive - 1
          self.kills = self.kills + 1
          local kind = ALIEN_KIND[a.row]
          self.score = self.score + kind.value * (1 + floor((self.wave - 1) / 2))
          self:boom(a.x + 4, a.y + 2, kind.colour, 10)
          -- the front rows are the low, fat ones
          audio.play("inv.hit", (ROWS - a.row) * 2)
          gone = true
          break
        end
      end
    end
    if gone then table.remove(self.shots, i) end
  end

  -- particles
  for i = #self.particles, 1, -1 do
    local p = self.particles[i]
    p.x = p.x + p.vx * dt
    p.y = p.y + p.vy * dt
    p.vy = p.vy + 40 * dt
    p.life = p.life - dt
    if p.life <= 0 then table.remove(self.particles, i) end
  end

  if self.alive <= 0 then
    self.score = self.score + 200 * self.wave
    self.wave = self.wave + 1
    audio.play("result.newwave")
    self.shots = {}
    self.bombs = {}
    self:startWave()
  end
end

---------------------------------------------------------------------- draw
function Game:draw()
  local c = self.c
  c:clear(colors.black)

  for i = 1, #self.aliens do
    local a = self.aliens[i]
    if a.alive then
      local kind = ALIEN_KIND[a.row]
      stamp(c, sprites[kind.frames[self.frame]], floor(a.x), floor(a.y), kind.colour)
    end
  end

  if self.ufo then
    stamp(c, sprites.ufo, floor(self.ufo.x), 1, colors.red)
  end

  for i = 1, 4 do
    local s = self.shields[i]
    for y = 1, #SHIELD_SRC do
      for x = 1, 12 do
        if s.px[(y - 1) * 12 + x] then
          c:set(s.x + x - 1, s.y + y - 1, colors.lime)
        end
      end
    end
  end

  if self.respawn <= 0 then
    stamp(c, sprites.ship, floor(self.playerX), PLAYER_Y, colors.white)
  end

  for _, s in ipairs(self.shots) do
    c:fill(floor(s.x), floor(s.y), 1, 3, colors.yellow)
  end
  for _, b in ipairs(self.bombs) do
    local wig = floor(b.t * 14) % 2
    c:fill(floor(b.x) - wig, floor(b.y), 1, 2, colors.red)
    c:fill(floor(b.x) + wig - 1, floor(b.y) + 2, 1, 1, colors.orange)
  end
  for _, p in ipairs(self.particles) do
    c:set(floor(p.x), floor(p.y), p.life > 0.2 and p.colour or colors.orange)
  end

  c:fill(1, FIELD_H - 1, FIELD_W, 1, colors.green)

  if self.waveMessage > 0 then
    local text = "WAVE " .. self.wave
    local w = font.width(text, 2, 2)
    font.draw(c, floor((FIELD_W - w) / 2), 25, text, colors.white, 2, 2)
  end

  c:render()

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  gfx.text(2, 1, "SCORE", colors.lightGray, colors.gray)
  gfx.text(8, 1, gfx.commas(self.score), colors.white, colors.gray)
  gfx.center(1, "WAVE " .. self.wave, colors.lime, colors.gray)
  gfx.right(gfx.W - 1, 1, string.rep("^", max(0, self.lives)), colors.cyan, colors.gray)
end

function Game:summary()
  return {
    { "Wave", self.wave },
    { "Aliens shot", self.kills },
  }
end

---------------------------------------------------------------------- cover
local function cover(c, t)
  c:clear(colors.black)
  for i = 1, 18 do
    local x = (i * 37) % c.w
    local y = (i * 13) % c.h
    c:set(x, y, colors.gray)
  end
  local sway = floor(math.sin(t * 1.2) * 6)
  local frame = (floor(t * 2) % 2) + 1
  for r = 1, 3 do
    local kind = ALIEN_KIND[r * 2 - 1]
    local spr = sprites[kind.frames[frame]]
    for col = 1, 5 do
      stamp(c, spr, 5 + (col - 1) * 10 + sway, 2 + (r - 1) * 6, kind.colour)
    end
  end
  local sx0 = floor(c.w / 2 - 4 + math.sin(t * 2.1) * 14)
  stamp(c, sprites.ship, sx0, c.h - 5, colors.white)
  c:fill(sx0 + 4, c.h - 12, 1, 4, colors.yellow)
end

----------------------------------------------------------------- definition
return {
  id = "invaders",
  name = "Invaders",
  tagline = "They come down in rows",
  accent = colors.lime,
  order = 40,
  cover = cover,
  music = "descent",
  controls = {
    { "Left / Right", "Move" },
    { "Space", "Fire" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "normal", name = "Normal", hint = "3 lives" },
    { id = "hard", name = "Hard", hint = "faster", hard = true },
  },
  trophies = {
    { id = "inv_w3", name = "Hold The Line", desc = "Reach wave 3",
      test = function(g) return g.wave >= 3 end },
    { id = "inv_100", name = "Sharpshooter", desc = "Shoot 100 aliens in one run",
      test = function(g) return g.kills >= 100 end },
    { id = "inv_w5", name = "Last Stand", desc = "Reach wave 5",
      test = function(g) return g.wave >= 5 end },
  },
  new = new,
}
