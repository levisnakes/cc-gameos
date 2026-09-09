--[[ Meteors -- vector-style asteroids with inertia and wrap-around space.

  Rocks are irregular polygons drawn with the canvas line routine, so they
  really are vectors rather than sprites.
]]

local req = ...
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local audio = req("lib.audio")
local input = req("lib.input")

local floor = math.floor
local sin, cos, pi = math.sin, math.cos, math.pi
local sqrt, acos = math.sqrt, math.acos
local max, min = math.max, math.min

local W, H = 102, 57
local TWO_PI = pi * 2

local Game = {}
Game.__index = Game

local SIZE_RADIUS = { 4, 7, 11 }
local SIZE_SCORE = { 100, 50, 20 }
local SIZE_SPEED = { 26, 18, 12 }

------------------------------------------------------------------- helpers
local function wrap(v, limit)
  v = v % limit
  if v < 0 then v = v + limit end
  return v
end

local function makeRock(x, y, size)
  local points = 8
  local shape = {}
  for i = 1, points do
    shape[i] = 0.68 + math.random() * 0.5
  end
  local dir = math.random() * TWO_PI
  local speed = SIZE_SPEED[size] * (0.6 + math.random() * 0.7)
  return {
    x = x, y = y, size = size,
    vx = cos(dir) * speed, vy = sin(dir) * speed,
    angle = math.random() * TWO_PI,
    spin = (math.random() - 0.5) * 2.2,
    shape = shape,
    r = SIZE_RADIUS[size],
  }
end

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.c = Canvas.new(1, 1, gfx.W, gfx.H, colors.black)
  self.score = 0
  self.lives = 3
  self.wave = 0
  self.rocksShot = 0
  self.ufosShot = 0
  self.finished = false
  self.bullets = {}
  self.particles = {}
  self.rocks = {}
  self.ufo = nil
  self.ufoTimer = 26
  self.hyperCooldown = 0
  self.fireCooldown = 0
  self:respawn(true)
  self:nextWave()

  self.stars = {}
  for i = 1, 26 do
    self.stars[i] = { x = math.random(1, W), y = math.random(1, H), dim = math.random(1, 3) }
  end
  return self
end

function Game:respawn(instant)
  self.ship = {
    x = W / 2, y = H / 2, vx = 0, vy = 0,
    angle = -pi / 2, thrust = false,
  }
  self.invuln = instant and 1.5 or 2.5
  self.dead = false
end

function Game:nextWave()
  self.wave = self.wave + 1
  local count = min(9, 3 + self.wave)
  for _ = 1, count do
    local x, y
    repeat
      x = math.random(1, W)
      y = math.random(1, H)
    until (x - W / 2) ^ 2 + (y - H / 2) ^ 2 > 900
    self.rocks[#self.rocks + 1] = makeRock(x, y, 3)
  end
  self.waveBanner = 1.5
end

------------------------------------------------------------------- effects
function Game:boom(x, y, n, colour)
  for _ = 1, n do
    local dir = math.random() * TWO_PI
    local sp = 8 + math.random() * 34
    self.particles[#self.particles + 1] = {
      x = x, y = y, vx = cos(dir) * sp, vy = sin(dir) * sp,
      life = 0.25 + math.random() * 0.45, colour = colour or colors.orange,
    }
  end
end

--------------------------------------------------------------------- input
function Game:fire()
  if self.dead or self.fireCooldown > 0 then return end
  if #self.bullets >= 5 then return end
  self.fireCooldown = 0.16
  local s = self.ship
  self.bullets[#self.bullets + 1] = {
    x = s.x + cos(s.angle) * 6,
    y = s.y + sin(s.angle) * 6,
    vx = s.vx + cos(s.angle) * 78,
    vy = s.vy + sin(s.angle) * 78,
    life = 1.05,
  }
  audio.play("met.fire")
end

function Game:hyperspace()
  if self.dead or self.hyperCooldown > 0 then return end
  self.hyperCooldown = 3
  self:boom(self.ship.x, self.ship.y, 8, colors.purple)
  self.ship.x = math.random(6, W - 6)
  self.ship.y = math.random(6, H - 6)
  self.ship.vx, self.ship.vy = 0, 0
  self.invuln = max(self.invuln, 0.9)
  audio.play("met.hyper")
end

function Game:onKey(code, held)
  if held then return end
  if code == keys.space or code == keys.x then
    self:fire()
  elseif code == keys.h or code == keys.down or code == keys.s then
    self:hyperspace()
  end
end

--- The pointer is an aim target rather than a direct heading: the ship still
--- turns at its own rate toward the cursor, so it keeps feeling like a ship
--- with momentum instead of a turret that snaps. Left click fires, right
--- click burns the engine for a short burst.
function Game:onMouse(kind, btn, x, y)
  if self.finished or self.dead then return end
  if kind == "mouse_click" or kind == "mouse_drag" then
    self.aimX = (x - 1) * 2 + 1
    self.aimY = (y - 1) * 3 + 1
    if kind == "mouse_click" then
      if btn == 2 then
        self.thrustBurst = 0.4
      else
        self:fire()
      end
    end
  end
end

-------------------------------------------------------------------- update
function Game:hitShip()
  if self.invuln > 0 or self.dead then return end
  self.dead = true
  self.lives = self.lives - 1
  self:boom(self.ship.x, self.ship.y, 22, colors.cyan)
  audio.play("met.die")
  self.deadTimer = 1.5
end

function Game:splitRock(index)
  local rock = self.rocks[index]
  self.score = self.score + SIZE_SCORE[rock.size]
  self.rocksShot = self.rocksShot + 1
  self:boom(rock.x, rock.y, 6 + rock.size * 3, colors.lightGray)
  audio.play("met.rock" .. rock.size)
  table.remove(self.rocks, index)
  if rock.size > 1 then
    for _ = 1, 2 do
      local child = makeRock(rock.x, rock.y, rock.size - 1)
      child.vx = child.vx + rock.vx * 0.4
      child.vy = child.vy + rock.vy * 0.4
      self.rocks[#self.rocks + 1] = child
    end
  end
end

function Game:update(dt)
  if self.finished then return end
  self.fireCooldown = max(0, self.fireCooldown - dt)
  self.hyperCooldown = max(0, self.hyperCooldown - dt)
  if self.waveBanner then
    self.waveBanner = self.waveBanner - dt
    if self.waveBanner <= 0 then self.waveBanner = nil end
  end

  if self.dead then
    self.deadTimer = self.deadTimer - dt
    if self.deadTimer <= 0 then
      if self.lives <= 0 then
        self.finished = true
        return
      end
      self:respawn(false)
    end
  else
    self.invuln = max(0, self.invuln - dt)
    local s = self.ship
    local turning = false
    if input.down(keys.left, keys.a) then
      s.angle = s.angle - 3.4 * dt
      turning = true
    end
    if input.down(keys.right, keys.d) then
      s.angle = s.angle + 3.4 * dt
      turning = true
    end
    if turning then self.aimX = nil end     -- keys take the helm back
    if self.aimX then
      -- Shortest way round to the cursor, capped at the ship's turn rate.
      -- There is no portable atan2 here (5.2 has no two-argument atan, 5.4
      -- has no atan2), so the turn comes from the forward vector directly:
      -- the dot product gives how far round the target is, the cross product
      -- gives which way.
      local dx, dy = self.aimX - s.x, self.aimY - s.y
      local len = sqrt(dx * dx + dy * dy)
      if len > 1 then
        dx, dy = dx / len, dy / len
        local fx, fy = cos(s.angle), sin(s.angle)
        local dot = fx * dx + fy * dy
        if dot > 1 then dot = 1 elseif dot < -1 then dot = -1 end
        local diff = acos(dot)
        if fx * dy - fy * dx < 0 then diff = -diff end
        local step = 3.4 * dt
        if diff > step then diff = step elseif diff < -step then diff = -step end
        s.angle = s.angle + diff
      end
    end
    self.thrustBurst = max(0, (self.thrustBurst or 0) - dt)
    s.thrust = input.down(keys.up, keys.w) or self.thrustBurst > 0
    if s.thrust then
      s.vx = s.vx + cos(s.angle) * 62 * dt
      s.vy = s.vy + sin(s.angle) * 62 * dt
      if math.random(1, 3) == 1 then
        self.particles[#self.particles + 1] = {
          x = s.x - cos(s.angle) * 6, y = s.y - sin(s.angle) * 6,
          vx = -cos(s.angle) * 20, vy = -sin(s.angle) * 20,
          life = 0.18, colour = colors.orange,
        }
      end
    end
    local drag = 1 - 0.34 * dt
    s.vx = s.vx * drag
    s.vy = s.vy * drag
    local speed = sqrt(s.vx * s.vx + s.vy * s.vy)
    if speed > 62 then
      s.vx = s.vx / speed * 62
      s.vy = s.vy / speed * 62
    end
    s.x = wrap(s.x + s.vx * dt, W)
    s.y = wrap(s.y + s.vy * dt, H)
  end

  for i = #self.bullets, 1, -1 do
    local b = self.bullets[i]
    b.x = wrap(b.x + b.vx * dt, W)
    b.y = wrap(b.y + b.vy * dt, H)
    b.life = b.life - dt
    if b.life <= 0 then
      table.remove(self.bullets, i)
    else
      local hit = false
      for j = #self.rocks, 1, -1 do
        local r = self.rocks[j]
        local dx, dy = b.x - r.x, b.y - r.y
        if dx * dx + dy * dy <= r.r * r.r then
          self:splitRock(j)
          hit = true
          break
        end
      end
      if not hit and self.ufo then
        local dx, dy = b.x - self.ufo.x, b.y - self.ufo.y
        if dx * dx + dy * dy <= 36 then
          self.score = self.score + 200
          self.ufosShot = self.ufosShot + 1
          self:boom(self.ufo.x, self.ufo.y, 16, colors.magenta)
          self.ufo = nil
          hit = true
          audio.play("met.ufohit")
        end
      end
      if hit then table.remove(self.bullets, i) end
    end
  end

  for i = 1, #self.rocks do
    local r = self.rocks[i]
    r.x = wrap(r.x + r.vx * dt, W)
    r.y = wrap(r.y + r.vy * dt, H)
    r.angle = r.angle + r.spin * dt
    if not self.dead and self.invuln <= 0 then
      local dx, dy = self.ship.x - r.x, self.ship.y - r.y
      local reach = r.r + 3
      if dx * dx + dy * dy <= reach * reach then self:hitShip() end
    end
  end

  self.ufoTimer = self.ufoTimer - dt
  if not self.ufo and self.ufoTimer <= 0 then
    self.ufoTimer = 30 + math.random() * 20
    local left = math.random(1, 2) == 1
    self.ufo = {
      x = left and 1 or W, y = math.random(10, H - 10),
      vx = (left and 1 or -1) * 22, vy = 0, shoot = 1.6,
    }
  end
  if self.ufo then
    local u = self.ufo
    u.x = u.x + u.vx * dt
    u.y = u.y + sin(u.x * 0.09) * 16 * dt
    u.shoot = u.shoot - dt
    if u.shoot <= 0 and not self.dead then
      u.shoot = 1.7
      local dx, dy = self.ship.x - u.x, self.ship.y - u.y
      local d = max(1, sqrt(dx * dx + dy * dy))
      self.bullets[#self.bullets + 1] = {
        x = u.x, y = u.y, vx = dx / d * 52, vy = dy / d * 52,
        life = 1.4, hostile = true,
      }
      audio.play("met.ufo")
    end
    if u.x < -6 or u.x > W + 6 then self.ufo = nil end
    if not self.dead and self.invuln <= 0 then
      local dx, dy = self.ship.x - u.x, self.ship.y - u.y
      if dx * dx + dy * dy < 49 then self:hitShip() end
    end
  end

  -- hostile bullets can hit the player
  for i = #self.bullets, 1, -1 do
    local b = self.bullets[i]
    if b.hostile and not self.dead and self.invuln <= 0 then
      local dx, dy = self.ship.x - b.x, self.ship.y - b.y
      if dx * dx + dy * dy < 12 then
        table.remove(self.bullets, i)
        self:hitShip()
      end
    end
  end

  for i = #self.particles, 1, -1 do
    local p = self.particles[i]
    p.x = wrap(p.x + p.vx * dt, W)
    p.y = wrap(p.y + p.vy * dt, H)
    p.life = p.life - dt
    if p.life <= 0 then table.remove(self.particles, i) end
  end

  if #self.rocks == 0 then
    self.score = self.score + 250 * self.wave
    audio.play("result.newwave")
    self:nextWave()
  end
end

---------------------------------------------------------------------- draw
function Game:drawRock(c, r, colour)
  local n = #r.shape
  local px, py
  local fx, fy
  for i = 1, n do
    local a = r.angle + (i - 1) / n * TWO_PI
    local x = r.x + cos(a) * r.r * r.shape[i]
    local y = r.y + sin(a) * r.r * r.shape[i]
    if i == 1 then
      fx, fy = x, y
    else
      c:line(px, py, x, y, colour)
    end
    px, py = x, y
  end
  c:line(px, py, fx, fy, colour)
end

function Game:draw()
  local c = self.c
  c:clear(colors.black)

  local shades = { colors.gray, colors.lightGray, colors.white }
  for _, s in ipairs(self.stars) do
    c:set(s.x, s.y, shades[s.dim])
  end

  for i = 1, #self.rocks do
    self:drawRock(c, self.rocks[i], colors.lightGray)
  end

  for _, b in ipairs(self.bullets) do
    c:set(floor(b.x), floor(b.y), b.hostile and colors.red or colors.yellow)
    c:set(floor(b.x) + (b.hostile and 0 or 1), floor(b.y), b.hostile and colors.red or colors.yellow)
  end

  for _, p in ipairs(self.particles) do
    c:set(floor(p.x), floor(p.y), p.life > 0.2 and p.colour or colors.gray)
  end

  if self.ufo then
    local u = self.ufo
    local x, y = floor(u.x), floor(u.y)
    c:fill(x - 5, y, 11, 2, colors.magenta)
    c:fill(x - 3, y - 2, 7, 2, colors.magenta)
    c:fill(x - 2, y + 2, 5, 1, colors.magenta)
  end

  if not self.dead then
    local s = self.ship
    local blink = self.invuln > 0 and floor(self.invuln * 12) % 2 == 0
    if not blink then
      local col = colors.cyan
      local nx = s.x + cos(s.angle) * 6
      local ny = s.y + sin(s.angle) * 6
      local ax = s.x + cos(s.angle + 2.5) * 5
      local ay = s.y + sin(s.angle + 2.5) * 5
      local bx = s.x + cos(s.angle - 2.5) * 5
      local by = s.y + sin(s.angle - 2.5) * 5
      c:line(nx, ny, ax, ay, col)
      c:line(nx, ny, bx, by, col)
      c:line(ax, ay, s.x - cos(s.angle) * 2, s.y - sin(s.angle) * 2, col)
      c:line(bx, by, s.x - cos(s.angle) * 2, s.y - sin(s.angle) * 2, col)
      if s.thrust then
        local fx = s.x - cos(s.angle) * 8
        local fy = s.y - sin(s.angle) * 8
        c:line(s.x - cos(s.angle) * 3, s.y - sin(s.angle) * 3, fx, fy, colors.orange)
      end
    end
  end

  font.draw(c, 3, 2, tostring(self.score), colors.white, 2, 2)
  for i = 1, max(0, self.lives) do
    local x = W - 6 - (i - 1) * 8
    c:line(x, 3, x - 3, 9, colors.cyan)
    c:line(x, 3, x + 3, 9, colors.cyan)
    c:line(x - 3, 9, x + 3, 9, colors.cyan)
  end
  if self.hyperCooldown > 0 then
    c:fill(3, 13, floor(20 * (1 - self.hyperCooldown / 3)), 2, colors.purple)
  end

  if self.waveBanner then
    -- below the centre so it never sits on top of the freshly spawned ship
    font.center(c, 44, "WAVE " .. self.wave, colors.white, 2, 2)
  end

  c:render()
end

function Game:summary()
  return {
    { "Wave", self.wave },
    { "Rocks shot", self.rocksShot },
  }
end

---------------------------------------------------------------------- cover
local COVER_ROCKS = nil

local function cover(c, t)
  c:clear(colors.black)
  if not COVER_ROCKS then
    local saved = math.random
    COVER_ROCKS = {}
    for i = 1, 3 do
      COVER_ROCKS[i] = makeRock(0, 0, 4 - i)
    end
  end
  for i = 1, 14 do
    c:set((i * 23) % c.w + 1, (i * 11) % c.h + 1, colors.gray)
  end
  for i, r in ipairs(COVER_ROCKS) do
    r.x = ((t * (8 + i * 5) + i * 20) % (c.w + 20)) - 10
    r.y = 5 + i * 5 + sin(t + i) * 3
    r.angle = t * (0.4 + i * 0.25)
    local n = #r.shape
    local px, py, fx, fy
    for k = 1, n do
      local a = r.angle + (k - 1) / n * TWO_PI
      local x = r.x + cos(a) * r.r * r.shape[k]
      local y = r.y + sin(a) * r.r * r.shape[k]
      if k == 1 then fx, fy = x, y else c:line(px, py, x, y, colors.lightGray) end
      px, py = x, y
    end
    c:line(px, py, fx, fy, colors.lightGray)
  end
  local a = t * 1.3
  local sx, sy = c.w / 2, c.h - 5
  c:line(sx + cos(a) * 5, sy + sin(a) * 5, sx + cos(a + 2.5) * 4, sy + sin(a + 2.5) * 4, colors.cyan)
  c:line(sx + cos(a) * 5, sy + sin(a) * 5, sx + cos(a - 2.5) * 4, sy + sin(a - 2.5) * 4, colors.cyan)
  c:line(sx + cos(a + 2.5) * 4, sy + sin(a + 2.5) * 4, sx + cos(a - 2.5) * 4, sy + sin(a - 2.5) * 4, colors.cyan)
end

----------------------------------------------------------------- definition
return {
  id = "meteors",
  name = "Meteors",
  tagline = "Vector rocks and inertia",
  accent = colors.lightGray,
  order = 100,
  cover = cover,
  music = "drift",
  controls = {
    { "Left / Right", "Rotate" },
    { "Up", "Thrust" },
    { "Space", "Fire" },
    { "H or Down", "Hyperspace" },
    { "Mouse", "Aim, click to fire" },
    { "Right click", "Thrust burst" },
    { "P", "Pause menu" },
  },
  trophies = {
    { id = "met_w3", name = "Rock Hopper", desc = "Reach wave 3",
      test = function(g) return g.wave >= 3 end },
    { id = "met_ufo", name = "UFO Down", desc = "Shoot down a flying saucer",
      test = function(g) return g.ufosShot >= 1 end },
    { id = "met_100", name = "Field Cleared", desc = "Shoot 100 rocks in one run",
      test = function(g) return g.rocksShot >= 100 end },
  },
  new = new,
}
