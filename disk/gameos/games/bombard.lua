--[[ Bombard -- two guns, one hill, and whatever is left of it.

  Replaces Invaders as the console's shooter, and is built the other way
  round: for two people rather than one. It plays against the computer, across
  one keyboard, or between two ComputerCraft consoles over a modem.

  Why a turn-based artillery duel is the right shape for network play. A
  real-time game across rednet needs the two consoles to agree on the world
  twenty times a second, and any hiccup shows as a rubber-banding tank. Here
  the entire turn is two numbers -- angle and power -- so the only thing that
  ever crosses the wire is a handful of bytes, and a shot that arrives late is
  simply a shot that arrives late.

  That works because both consoles run the same simulation and get the same
  answer. Three things make that true:

    * the terrain comes from a seed the host sends, grown by a small
      hand-rolled generator rather than math.random, so nothing else drawing
      random numbers can shift it;
    * each turn's wind comes from a shared stream advanced in lockstep;
    * a shot is simulated to completion the moment it is fired, producing a
      fixed path, and the flight animation merely walks that path. Two
      consoles running at different frame rates therefore still agree on
      exactly where the shell landed.

  The host also sends a checksum after each shot. If the two worlds have
  drifted at all, the guest asks for the whole state and takes the host's
  word for it, so a desync is a half-second hiccup rather than two people
  playing different games.
]]

local req = ...
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local audio = req("lib.audio")
local input = req("lib.input")
local net = req("lib.net")

local floor, ceil = math.floor, math.ceil
local min, max, abs = math.min, math.max, math.abs
local sin, cos, sqrt, pi = math.sin, math.cos, math.sqrt, math.pi

-- The play area is its own canvas sitting under the one-row header, so all
-- world coordinates below are canvas pixels: 102 wide, 54 tall, y growing
-- downward. Nothing here has to know where the header is.
local FIELD_W = 102
local SKY_TOP = 1
local GROUND_BOTTOM = 54

local GRAVITY = 46
local MAX_WIND = 10
local BLAST_R = 10                -- damage radius
local CRATER_R = 8
local MAX_DAMAGE = 40
local START_HEALTH = 100

local P1, P2 = 1, 2

local Game = {}
Game.__index = Game

--------------------------------------------------------------- shared random
--- A Lehmer generator, written out rather than borrowed from math.random so
--- that both consoles produce identical terrain and identical wind. The
--- multiply stays exact in a double (2147483646 * 16807 is far below 2^53).
local function stream(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 16807) % 2147483647
    return s / 2147483647
  end
end

------------------------------------------------------------------- terrain
--- Solid ground is a bitmap rather than a heightline, so a shell can bite
--- into the side of a hill and leave an overhang instead of politely
--- lowering the surface.
local function key(x, y) return (y - 1) * FIELD_W + x end

local function makeTerrain(seed)
  local rnd = stream(seed)
  local a1, p1 = 4 + rnd() * 5, rnd() * pi * 2
  local a2, p2 = 2 + rnd() * 3, rnd() * pi * 2
  local a3, p3 = 1 + rnd() * 2, rnd() * pi * 2
  local base = 33 + rnd() * 7

  local surface = {}
  for x = 1, FIELD_W do
    local t = (x - 1) / FIELD_W * pi * 2
    local y = base
      - a1 * sin(t * 1.0 + p1)
      - a2 * sin(t * 2.3 + p2)
      - a3 * sin(t * 4.7 + p3)
    y = floor(y + 0.5)
    if y < SKY_TOP + 12 then y = SKY_TOP + 12 end
    if y > GROUND_BOTTOM - 5 then y = GROUND_BOTTOM - 5 end
    surface[x] = y
  end

  local solid = {}
  for x = 1, FIELD_W do
    for y = surface[x], GROUND_BOTTOM do solid[key(x, y)] = true end
  end
  return solid, surface
end

--- Terrain is redrawn every frame but only changes when something explodes,
--- so it is kept as a list of vertical runs and rebuilt on damage instead.
function Game:rebuildRuns()
  local runs = {}
  local solid = self.solid
  for x = 1, FIELD_W do
    local y = SKY_TOP
    while y <= GROUND_BOTTOM do
      if solid[key(x, y)] then
        local start = y
        while y <= GROUND_BOTTOM and solid[key(x, y)] do y = y + 1 end
        runs[#runs + 1] = { x, start, y - start }
      else
        y = y + 1
      end
    end
  end
  self.runs = runs
end

function Game:surfaceAt(x)
  if x < 1 or x > FIELD_W then return GROUND_BOTTOM end
  for y = SKY_TOP, GROUND_BOTTOM do
    if self.solid[key(x, y)] then return y end
  end
  return GROUND_BOTTOM + 1
end

function Game:carve(cx, cy, r)
  local r2 = r * r
  for y = max(SKY_TOP, floor(cy - r)), min(GROUND_BOTTOM, ceil(cy + r)) do
    for x = max(1, floor(cx - r)), min(FIELD_W, ceil(cx + r)) do
      local dx, dy = x - cx, y - cy
      if dx * dx + dy * dy <= r2 then self.solid[key(x, y)] = nil end
    end
  end
  self:rebuildRuns()
end

------------------------------------------------------------------- ballistics
--- A shot is simulated to the end the instant it is fired. The result is a
--- fixed path, which is what makes two consoles agree; the flight you watch
--- is just a marker walking along it.
function Game:simulate(fromX, fromY, angleDeg, power, wind)
  local a = angleDeg * pi / 180
  local speed = 18 + power * 0.52
  local vx, vy = cos(a) * speed, -sin(a) * speed
  local x, y = fromX, fromY
  local dt = 0.02
  local path = { { x, y } }

  for _ = 1, 900 do
    vx = vx + wind * dt
    vy = vy + GRAVITY * dt
    x = x + vx * dt
    y = y + vy * dt
    path[#path + 1] = { x, y }

    if y >= SKY_TOP then
      local ix, iy = floor(x + 0.5), floor(y + 0.5)
      -- a tank is hit before the ground under it is
      for p = P1, P2 do
        local t = self.tanks[p]
        if t.health > 0 and abs(ix - t.x) <= 3 and abs(iy - t.y) <= 3 then
          return path, { x = x, y = y, hit = p }
        end
      end
      if ix >= 1 and ix <= FIELD_W and iy >= SKY_TOP and self.solid[key(ix, iy)] then
        return path, { x = x, y = y, ground = true }
      end
      if iy > GROUND_BOTTOM then
        return path, { x = x, y = y, ground = true }
      end
    end
    -- Off the sides is a miss, but only once it is also falling: a high shot
    -- into the wind can leave the field and be blown back in.
    if (x < -40 or x > FIELD_W + 40) and vy > 0 then
      return path, { x = x, y = y, off = true }
    end
  end
  return path, { x = x, y = y, off = true }
end

--------------------------------------------------------------------- damage
function Game:applyBlast(ix, iy)
  local dealt = 0
  for p = P1, P2 do
    local t = self.tanks[p]
    if t.health > 0 then
      local dx, dy = t.x - ix, t.y - iy
      local d = sqrt(dx * dx + dy * dy)
      if d <= BLAST_R then
        local hurt = floor(MAX_DAMAGE * (1 - d / BLAST_R) + 0.5)
        if hurt > 0 then
          t.health = max(0, t.health - hurt)
          dealt = dealt + hurt
          t.flash = 0.5
        end
      end
    end
  end
  self:carve(ix, iy, CRATER_R)

  -- A tank whose ground was blown out drops onto whatever is left, and takes
  -- damage for the drop. It does not die outright: an earlier version treated
  -- reaching the floor as fatal, which meant a shell landing on the far side
  -- of the map could kill you several turns after it had dug you a hole. Fall
  -- damage keeps digging someone out a real tactic without that unfairness.
  for p = P1, P2 do
    local t = self.tanks[p]
    if t.health > 0 then
      local ground = min(self:surfaceAt(floor(t.x + 0.5)) - 1, GROUND_BOTTOM - 1)
      if ground > t.y then
        local fell = ground - t.y
        t.y = ground
        if fell > 3 then
          local hurt = min(25, floor((fell - 3) * 2))
          t.health = max(0, t.health - hurt)
          t.flash = 0.5
          dealt = dealt + hurt
        end
      end
    end
  end
  return dealt
end

function Game:boom(x, y, big)
  local n = big and 22 or 12
  for _ = 1, n do
    local a = math.random() * pi * 2
    local sp = 8 + math.random() * (big and 34 or 20)
    self.particles[#self.particles + 1] = {
      x = x, y = y,
      vx = cos(a) * sp, vy = sin(a) * sp - 8,
      life = 0.3 + math.random() * 0.45,
      colour = (math.random(1, 3) == 1) and colors.yellow or colors.orange,
    }
  end
end

---------------------------------------------------------------------- setup
local function placeTanks(self)
  -- far enough apart that neither can simply lob one straight over
  local x1 = 9 + floor(stream(self.seed + 77)() * 8)
  local x2 = FIELD_W - 8 - floor(stream(self.seed + 991)() * 8)
  self.tanks = {
    [P1] = { x = x1, y = self:surfaceAt(x1) - 1, health = START_HEALTH,
             angle = 45, power = 55, colour = colors.lightBlue, side = 1, flash = 0 },
    [P2] = { x = x2, y = self:surfaceAt(x2) - 1, health = START_HEALTH,
             angle = 135, power = 55, colour = colors.red, side = -1, flash = 0 },
  }
end

local function new(api, mode)
  local self = setmetatable({}, Game)
  mode = mode or {}

  -- rows 2..19 of the terminal, which is exactly 102 x 54 pixels
  self.c = Canvas.new(1, 2, gfx.W, gfx.H - 1, colors.black)
  self.seed = mode.seed or math.random(1, 1000000)
  self.solid, self.surface = makeTerrain(self.seed)
  self:rebuildRuns()
  placeTanks(self)

  self.windStream = stream(self.seed + 5150)
  self.particles = {}
  self.tracer = nil
  self.shot = nil
  self.turn = P1
  self.phase = "aim"                -- aim | flight | settle | over
  self.settle = 0
  self.score = 0
  self.finished = false
  self.shots = { [P1] = 0, [P2] = 0 }
  self.hits = { [P1] = 0, [P2] = 0 }        -- any damage dealt
  self.direct = { [P1] = 0, [P2] = 0 }      -- shell actually struck the tank
  self.round = 1
  self.message = nil
  self.messageTime = 0

  -- who is who
  self.link = mode.link
  self.role = mode.role                          -- "host" | "guest" | nil
  self.twoPlayer = mode.twoPlayer or self.link ~= nil
  if self.twoPlayer then
    self.cpu = nil
  else
    self.cpu = mode.cpu or "normal"
  end
  self.cpuTries = mode.tries or 40
  self.cpuError = mode.error or 6

  if self.link then
    -- The host is player one and moves first; that is the only thing the two
    -- consoles have to agree on beyond the seed.
    self.me = (self.role == "host") and P1 or P2
    self.suppressPause = true                    -- see runtime: keeps the link alive
    self.peerName = mode.peerName or self.link.name
  else
    self.me = nil                                -- local play: both are ours
  end

  self:newWind()
  self.overlay = false
  self.desyncs = 0
  return self
end

function Game:newWind()
  self.wind = floor((self.windStream() * 2 - 1) * MAX_WIND + 0.5)
end

------------------------------------------------------------------ whose turn
--- True when this console drives the gun right now. Locally that is always
--- so; on a network it is only our own half of the match.
function Game:myTurn()
  if self.phase ~= "aim" or self.finished then return false end
  if not self.link then return true end
  return self.turn == self.me
end

function Game:current() return self.tanks[self.turn] end

----------------------------------------------------------------------- fire
function Game:fire(angle, power, remote)
  if self.phase ~= "aim" or self.finished then return end
  local t = self:current()
  t.angle, t.power = angle, power
  self.shots[self.turn] = self.shots[self.turn] + 1

  local path, impact = self:simulate(t.x + t.side * 4, t.y - 3, angle, power, self.wind)
  self.shot = { path = path, impact = impact, at = 1, by = self.turn }
  self.phase = "flight"
  audio.play("bmb.fire")

  -- our own shots go out to the other console; a shot that arrived from
  -- there must not be echoed back
  if self.link and not remote then
    self.link:send("shot", { a = angle, p = power })
  end
end

function Game:resolveImpact()
  local imp = self.shot.impact
  local ix, iy = floor(imp.x + 0.5), floor(imp.y + 0.5)
  self.tracer = self.shot.path
  -- Where the last shell went. Kept per player as well as overall, because
  -- by the time your turn comes round again the most recent impact is your
  -- opponent's, and it is your own last shot you want to correct from.
  local where = { x = imp.x, y = imp.y, by = self.shot.by }
  self.lastImpact = where
  self.lastShot = self.lastShot or {}
  self.lastShot[self.shot.by] = where

  if imp.off then
    audio.play("bmb.miss")
    self:flash("OFF THE FIELD")
  else
    local dealt = self:applyBlast(ix, iy)
    self:boom(imp.x, imp.y, dealt > 0)
    if dealt > 0 then
      self.hits[self.shot.by] = self.hits[self.shot.by] + 1
      if imp.hit then
        self.direct[self.shot.by] = self.direct[self.shot.by] + 1
      end
      audio.play(imp.hit and "bmb.direct" or "bmb.hit")
      self:flash(imp.hit and "DIRECT HIT" or (dealt .. " DAMAGE"))
    else
      audio.play("bmb.thud")
    end
  end
  self.phase = "settle"
  self.settle = 0.9
end

function Game:flash(text)
  self.message = text
  self.messageTime = 1.4
end

--------------------------------------------------------------------- turn end
function Game:endTurn()
  local dead1 = self.tanks[P1].health <= 0
  local dead2 = self.tanks[P2].health <= 0
  if dead1 or dead2 then
    self:finish(dead1 and dead2 and 0 or (dead1 and P2 or P1))
    return
  end
  self.turn = (self.turn == P1) and P2 or P1
  if self.turn == P1 then self.round = self.round + 1 end
  self:newWind()
  self.phase = "aim"
  self.cpuPlan = nil
  self.cpuThink = 0
  audio.play("bmb.turn")

  -- The host is the authority. After every shot it publishes a fingerprint of
  -- the world; a guest that disagrees asks for the truth rather than playing
  -- on in a different game.
  if self.link and self.role == "host" then
    self.link:send("sync", { h = self:fingerprint() })
  end
end

function Game:finish(winner)
  self.phase = "over"
  self.finished = true
  self.winner = winner
  local me = self.me or P1
  local won = (winner == me)

  if self.link then
    if won and not self.byDisconnect then self.score = 750 else self.score = 0 end
    self.link:close("match over")
  elseif self.twoPlayer then
    self.score = 250
  elseif won then
    local left = self.tanks[me].health
    local acc = self.shots[me] > 0 and (self.hits[me] / self.shots[me]) or 0
    self.score = 500 + left * 5 + floor(acc * 400)
    if self.cpu == "hard" then self.score = self.score + 400 end
  else
    self.score = 0
  end
  audio.play(won and "bmb.win" or "bmb.lose")
end

--------------------------------------------------------------------- desync
--- A cheap fingerprint of everything that must match: both tanks and the
--- shape of the ground. Not cryptographic, just enough that a real
--- divergence shows up.
function Game:fingerprint()
  local h = 17
  for p = P1, P2 do
    local t = self.tanks[p]
    h = (h * 31 + t.health + floor(t.x) * 7 + floor(t.y) * 13) % 1000000007
  end
  for x = 1, FIELD_W, 3 do
    h = (h * 31 + self:surfaceAt(x)) % 1000000007
  end
  return h
end

function Game:snapshot()
  local ground = {}
  for x = 1, FIELD_W do ground[x] = self:surfaceAt(x) end
  return {
    g = ground,
    t = {
      { self.tanks[P1].health, floor(self.tanks[P1].x), floor(self.tanks[P1].y) },
      { self.tanks[P2].health, floor(self.tanks[P2].x), floor(self.tanks[P2].y) },
    },
    turn = self.turn, wind = self.wind,
  }
end

--- Rebuilding from a surface line loses overhangs, which is a fair trade: it
--- is a rare correction and a consistent world matters more than a ledge.
function Game:restore(snap)
  if type(snap) ~= "table" or type(snap.g) ~= "table" then return end
  local solid = {}
  for x = 1, FIELD_W do
    local top = snap.g[x] or GROUND_BOTTOM
    if type(top) ~= "number" then top = GROUND_BOTTOM end
    for y = max(SKY_TOP, floor(top)), GROUND_BOTTOM do solid[key(x, y)] = true end
  end
  self.solid = solid
  self:rebuildRuns()
  for p = P1, P2 do
    local row = snap.t and snap.t[p]
    if type(row) == "table" then
      self.tanks[p].health = row[1] or self.tanks[p].health
      self.tanks[p].x = row[2] or self.tanks[p].x
      self.tanks[p].y = row[3] or self.tanks[p].y
    end
  end
  if type(snap.turn) == "number" then self.turn = snap.turn end
  if type(snap.wind) == "number" then self.wind = snap.wind end
  self.desyncs = self.desyncs + 1
  self:flash("RESYNCED")
end

------------------------------------------------------------------ networking
function Game:onEvent(ev)
  if not self.link then return end
  local now = os.clock()

  -- Answer stray lobby traffic before the link filters it away. A join from
  -- our own opponent means our acceptance never arrived and they are still
  -- sitting on a "joining..." screen, so say it again; a join from anyone
  -- else deserves a refusal rather than silence, which would leave *them*
  -- waiting instead.
  local raw = net.parse(ev)
  if raw and raw.t == "join" and raw.game == "bombard" then
    if raw.from == self.link.peer and self.role == "host" then
      net.accept(raw.from, { seed = self.seed })
    elseif raw.from ~= self.link.peer then
      net.refuse(raw.from, "already in a match")
    end
  end

  self.link:handle(ev, now)
  while true do
    local msg = self.link:poll()
    if not msg then break end
    self:onNetMessage(msg)
  end
end

function Game:onNetMessage(msg)
  if msg.t == "shot" then
    if type(msg.a) ~= "number" or type(msg.p) ~= "number" then return end
    if self.phase ~= "aim" or self.turn == self.me then return end
    self:fire(msg.a, msg.p, true)

  elseif msg.t == "sync" then
    if self.role == "host" then return end
    if msg.h ~= self:fingerprint() then
      self.link:send("resync", {})
    end

  elseif msg.t == "resync" then
    if self.role ~= "host" then return end
    self.link:send("state", { s = self:snapshot() })

  elseif msg.t == "state" then
    if self.role == "host" then return end
    self:restore(msg.s)

  elseif msg.t == "forfeit" then
    if not self.finished then
      self:flash("OPPONENT FORFEITED")
      self:finish(self.me)
    end
  end
end

-------------------------------------------------------------------- CPU play
--- The opponent aims by trying shots and keeping the one that lands nearest,
--- then throws that answer off by an amount the difficulty decides. Searching
--- and then deliberately missing gives an easy opponent that still plays
--- plausible artillery, rather than one that fires at random.
--- `who` defaults to the computer's own side. Taking it as an argument is
--- what lets the attract-mode demo run both guns.
function Game:planCpuShot(who)
  who = who or P2
  local me = self.tanks[who]
  local foe = self.tanks[who == P1 and P2 or P1]
  local bestA, bestP, bestD = (who == P1) and 45 or 135, 55, 1e9

  self.lastPlan = self.lastPlan or {}
  for i = 1, self.cpuTries do
    local a, p
    if i == 1 and self.lastPlan[who] then
      a, p = self.lastPlan[who].a, self.lastPlan[who].p   -- start from what worked
    elseif who == P1 then
      a = 5 + math.random() * 80                 -- rightward, 5..85
      p = 30 + math.random() * 65
    else
      a = 95 + math.random() * 80                -- leftward, 95..175
      p = 30 + math.random() * 65
    end
    local _, imp = self:simulate(me.x + me.side * 4, me.y - 3, a, p, self.wind)
    local dx, dy = imp.x - foe.x, imp.y - foe.y
    local d = sqrt(dx * dx + dy * dy)
    if d < bestD then bestA, bestP, bestD = a, p, d end
  end

  self.lastPlan[who] = { a = bestA, p = bestP }
  local err = self.cpuError
  return bestA + (math.random() * 2 - 1) * err,
         max(5, min(100, bestP + (math.random() * 2 - 1) * err))
end

--------------------------------------------------------------------- update
function Game:update(dt)
  local now = os.clock()

  if self.link then
    self.link:update(now)
    if not self.link:alive(now) and not self.finished then
      -- The opponent vanished. Both consoles reach this point believing they
      -- are the one still standing, so neither can honestly be called the
      -- winner: the match is recorded as ended, not as won.
      self.byDisconnect = true
      self:flash("OPPONENT LOST")
      self:finish(self.me)
    end
  end

  if self.messageTime > 0 then
    self.messageTime = self.messageTime - dt
    if self.messageTime <= 0 then self.message = nil end
  end
  for p = P1, P2 do
    local t = self.tanks[p]
    if t.flash > 0 then t.flash = t.flash - dt end
  end

  -- particles
  for i = #self.particles, 1, -1 do
    local q = self.particles[i]
    q.life = q.life - dt
    if q.life <= 0 then
      table.remove(self.particles, i)
    else
      q.x = q.x + q.vx * dt
      q.y = q.y + q.vy * dt
      q.vy = q.vy + 34 * dt
    end
  end

  if self.finished then return end
  if self.overlay then return end

  if self.phase == "flight" then
    -- Walking a precomputed path: the speed here is presentation only and
    -- cannot change where the shell lands.
    local s = self.shot
    s.at = s.at + max(1, floor(dt * 90))
    if s.at >= #s.path then
      s.at = #s.path
      self:resolveImpact()
    end

  elseif self.phase == "settle" then
    self.settle = self.settle - dt
    if self.settle <= 0 then self:endTurn() end

  elseif self.phase == "aim" then
    if self.cpu and self.turn == P2 then
      self.cpuThink = (self.cpuThink or 0) + dt
      if not self.cpuPlan and self.cpuThink > 0.45 then
        local a, p = self:planCpuShot(P2)
        self.cpuPlan = { a = a, p = p }
      end
      if self.cpuPlan and self.cpuThink > 1.1 then
        self:fire(self.cpuPlan.a, self.cpuPlan.p)
        self.cpuPlan = nil
      end
      return
    end

    if self:myTurn() then
      local t = self:current()
      local step = 34 * dt
      local moved = false
      if input.down(keys.left, keys.a) then t.angle = t.angle + step moved = true end
      if input.down(keys.right, keys.d) then t.angle = t.angle - step moved = true end
      if input.down(keys.up, keys.w) then t.power = t.power + step moved = true end
      if input.down(keys.down, keys.s) then t.power = t.power - step moved = true end
      if moved then
        t.angle = max(0, min(180, t.angle))
        t.power = max(5, min(100, t.power))
        self.aimTick = (self.aimTick or 0) + dt
        if self.aimTick > 0.12 then
          self.aimTick = 0
          audio.play("bmb.aim")
        end
      end
    end
  end
end

---------------------------------------------------------------------- input
function Game:onKey(code, held)
  if self.finished then return end

  if code == keys.p and not held and self.suppressPause then
    self.overlay = not self.overlay
    return
  end
  if self.overlay then
    if code == keys.q and not held then
      if self.link then self.link:sendLoose("forfeit") end
      self:finish(self.link and ((self.me == P1) and P2 or P1) or nil)
    end
    return
  end

  if held then return end
  if code == keys.space or code == keys.enter or code == keys.numPadEnter then
    if self:myTurn() then
      local t = self:current()
      self:fire(t.angle, t.power)
    end
  end
end

--- Aiming with the pointer: drag away from your gun and it aims the other
--- way, like pulling back a catapult. The length of the pull is the power, so
--- one gesture sets both numbers -- much quicker than nudging two dials.
function Game:onMouse(kind, btn, x, y)
  if self.finished or self.overlay then return end
  if not self:myTurn() then return end
  if kind ~= "mouse_click" and kind ~= "mouse_drag" and kind ~= "mouse_up" then return end

  local px = (x - 1) * 2 + 1
  local py = (y - 2) * 3 + 1        -- the canvas starts on terminal row 2
  local t = self:current()
  local dx, dy = px - t.x, py - (t.y - 3)
  local len = sqrt(dx * dx + dy * dy)
  if len < 2 then return end

  -- pull back: the barrel points opposite the drag
  local ax, ay = -dx, -dy
  local angle
  if ax == 0 and ay == 0 then
    angle = t.angle
  else
    -- no portable two-argument atan, so take the angle from the unit vector
    local ux = ax / len
    local a = math.acos(max(-1, min(1, ux))) * 180 / pi
    angle = (ay > 0) and (360 - a) or a
  end
  if angle > 180 then angle = (angle > 270) and 0 or 180 end

  t.angle = max(0, min(180, angle))
  -- The field is about a hundred pixels across, so a pull scaled near 1:1
  -- lets the whole range of power be reached without leaving the screen --
  -- at 2.4 a short drag already pinned it at maximum.
  t.power = max(5, min(100, len * 1.15))

  if kind == "mouse_up" then
    self:fire(t.angle, t.power)
  else
    self.aimTick = (self.aimTick or 0) + 1
    if self.aimTick % 3 == 0 then audio.play("bmb.aim") end
  end
end

----------------------------------------------------------------------- draw
--- Drawn from primitives rather than a sprite so the hull can take the
--- player's colour and flash white when hit. A narrow turret over a wide
--- hull is what makes it read as a gun rather than a brick at this size, and
--- y is the pixel it stands on, so nothing sinks into the ground.
local function drawTank(c, x, y, angle, col)
  local a = angle * pi / 180
  c:line(x, y - 3, floor(x + cos(a) * 7), floor(y - 3 - sin(a) * 7), col)
  c:fill(x - 3, y - 1, 7, 2, col)          -- hull, bottom row sits on y
  c:fill(x - 1, y - 3, 3, 2, col)          -- turret
end

local function healthBar(x, y, w, frac, col)
  gfx.fill(x, y, w, 1, colors.gray)
  local n = floor(w * frac + 0.5)
  if n > 0 then gfx.fill(x, y, n, 1, col) end
end

function Game:draw()
  local c = self.c
  gfx.clear(colors.black)

  ----------------------------------------------------------------- world
  c:clear(colors.black)

  -- The ground is one flat colour on purpose. A cell holds two colours, so a
  -- highlight along the surface would win in some cells and lose in others
  -- and read as noise; a single colour makes every crater legible.
  for i = 1, #self.runs do
    local r = self.runs[i]
    c:fill(r[1], r[2], 1, r[3], colors.green)
  end

  -- where the last shot went
  if self.tracer then
    for i = 1, #self.tracer, 6 do
      local pt = self.tracer[i]
      local px, py = floor(pt[1] + 0.5), floor(pt[2] + 0.5)
      if px >= 1 and px <= FIELD_W and py >= SKY_TOP and py <= GROUND_BOTTOM then
        c:set(px, py, colors.gray)
      end
    end
  end

  -- tanks
  for p = P1, P2 do
    local t = self.tanks[p]
    if t.health > 0 then
      local col = (t.flash > 0 and floor(t.flash * 12) % 2 == 0) and colors.white or t.colour
      drawTank(c, floor(t.x), floor(t.y), t.angle, col)
    end
  end

  -- the shell in flight
  if self.phase == "flight" and self.shot then
    local pt = self.shot.path[min(self.shot.at, #self.shot.path)]
    local px, py = floor(pt[1] + 0.5), floor(pt[2] + 0.5)
    if px >= 1 and px <= FIELD_W and py >= SKY_TOP and py <= GROUND_BOTTOM then
      c:set(px, py, colors.white)
      c:set(px, py - 1, colors.lightGray)
    end
  end

  for i = 1, #self.particles do
    local q = self.particles[i]
    local px, py = floor(q.x + 0.5), floor(q.y + 0.5)
    if px >= 1 and px <= FIELD_W and py >= SKY_TOP and py <= GROUND_BOTTOM then
      c:set(px, py, q.colour)
    end
  end

  c:render()

  ---------------------------------------------------------------- header
  -- painted after the canvas, which covers everything below row one
  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  local t1, t2 = self.tanks[P1], self.tanks[P2]
  gfx.text(2, 1, "P1", colors.lightBlue, colors.gray)
  healthBar(5, 1, 8, t1.health / START_HEALTH, colors.lightBlue)
  gfx.right(gfx.W - 1, 1, "P2", colors.red, colors.gray)
  healthBar(gfx.W - 12, 1, 8, t2.health / START_HEALTH, colors.red)

  local arrow = self.wind == 0 and "--" or
    (self.wind > 0 and ("> " .. abs(self.wind)) or ("< " .. abs(self.wind)))
  gfx.center(1, "WIND " .. arrow, colors.white, colors.gray)

  ------------------------------------------------------------------- HUD
  if self.phase == "aim" and not self.finished then
    local t = self:current()
    local mine = self:myTurn() or not self.link
    local label
    if self.cpu and self.turn == P2 then
      label = "OPPONENT AIMING"
    elseif self.link then
      label = mine and "YOUR SHOT" or "WAITING FOR OPPONENT"
    else
      label = (self.turn == P1 and "PLAYER ONE" or "PLAYER TWO")
    end
    gfx.text(2, 19, label, self.tanks[self.turn].colour, colors.black)
    if mine and not (self.cpu and self.turn == P2) then
      gfx.right(gfx.W - 1, 19,
        string.format("ANG %3d  PWR %3d", floor(t.angle + 0.5), floor(t.power + 0.5)),
        colors.white, colors.black)
    end
  end

  if self.message then
    gfx.center(17, " " .. self.message .. " ", colors.black, colors.yellow)
  end

  if self.overlay then
    gfx.panel(12, 7, 28, 6, colors.gray, " Paused ", colors.white, colors.blue)
    gfx.center(9, "P to resume", colors.white, colors.gray)
    gfx.center(11, "Q to forfeit", colors.lightGray, colors.gray)
  end

  if self.finished then
    local me = self.me or P1
    local text
    if self.winner == 0 then
      text = "BOTH DESTROYED"
    elseif self.link then
      text = (self.winner == me) and "YOU WIN" or "YOU LOSE"
    elseif self.twoPlayer then
      text = (self.winner == P1) and "PLAYER ONE WINS" or "PLAYER TWO WINS"
    else
      text = (self.winner == P1) and "YOU WIN" or "YOU LOSE"
    end
    -- Written out rather than as `cond and a or b`: when the middle term is
    -- false that idiom quietly falls through to the wrong branch, which is
    -- exactly what it did here and painted a loss in winner's green.
    local banner
    if self.winner == 0 then
      banner = colors.orange
    elseif self.twoPlayer and not self.link then
      banner = self.tanks[self.winner].colour
    elseif self.winner == me then
      banner = colors.lime
    else
      banner = colors.red
    end
    gfx.center(10, " " .. text .. " ", colors.black, banner)
  end
end

--- Shown on the game-over card. Accuracy is the interesting number in an
--- artillery game -- it is the one that improves as you learn to range.
function Game:summary()
  local me = self.me or P1
  local shots = self.shots[me] or 0
  local hits = self.hits[me] or 0
  local pct = shots > 0 and floor(hits / shots * 100 + 0.5) or 0
  local rows = {
    { "Rounds", tostring(self.round) },
    { "Shots fired", tostring(shots) },
    { "On target", hits .. "  (" .. pct .. "%)" },
    { "Direct hits", tostring(self.direct[me] or 0) },
  }
  if self.byDisconnect then
    rows[#rows] = { "Result", "opponent lost" }
  end
  return rows
end

function Game:dispose()
  if self.link then self.link:close("left") end
  net.close()
end

--- Attract mode: the console plays itself, both guns driven by the same
--- planner the opponent uses. An artillery duel is a good thing to show on an
--- idle screen -- the arcs read from across a room, and the hill visibly
--- falls apart as it goes.
local function demo(self, frame)
  -- Attract mode gets the good gunners regardless of which mode built the
  -- instance: a duel between two poor shots is a poor advert for the game.
  if not self.demoTuned then
    self.demoTuned = true
    self.cpuTries, self.cpuError = 40, 5
  end
  if self.finished or self.phase ~= "aim" or self.turn ~= P1 then return end
  self.demoThink = (self.demoThink or 0) + 1
  if self.demoThink < 14 then return end
  self.demoThink = 0
  local a, p = self:planCpuShot(P1)
  self:fire(a, p)
end

------------------------------------------------------------------ configure
--- The lobby. Runs before new() so nothing here blocks construction, and it
--- is the whole of the "seamless" promise: hosts announce themselves and
--- guests see them appear, so no one types an ID.
local function lobby(api, mode)
  local ui = api.ui
  if not net.available() then
    ui.alert(" No modem ", {
      "This console has no modem.",
      "Attach one to either console",
      "and both will find each other.",
    }, colors.orange)
    return false
  end

  if mode.net == "host" then
    local host, err = net.hosting("bombard")
    if not host then
      ui.alert(" Modem problem ", { tostring(err) }, colors.red)
      return false
    end
    local seed = math.random(1, 1000000)
    local result = nil
    local dots = 0

    local function draw()
      gfx.clear(colors.black)
      gfx.panel(6, 5, 40, 10, colors.gray, " Hosting ", colors.white, colors.blue)
      gfx.center(7, "Waiting for a challenger" .. string.rep(".", dots), colors.white, colors.gray)
      gfx.center(9, net.label(), colors.yellow, colors.gray)
      gfx.center(11, "Anyone on this network can join", colors.lightGray, colors.gray)
      gfx.center(13, "Q to cancel", colors.lightGray, colors.gray)
    end

    local function handle(ev)
      local now = os.clock()
      host:advertise(now)
      dots = floor(now * 2) % 4
      if ev[1] == "key" and (ev[2] == keys.q or ev[2] == keys.backspace) then
        net.unhost("bombard")
        net.close()
        return 0
      end
      local join = host:handle(ev)
      if join then
        net.accept(join.from, { seed = seed })
        net.unhost("bombard")
        result = {
          id = "host", name = "Host", seed = seed, role = "host",
          link = net.link(join.from, net.cleanName(join.name, "Console " .. join.from)),
          peerName = net.cleanName(join.name, "Console " .. join.from),
        }
        audio.play("bmb.connect")
        return 1
      end
      return nil
    end

    -- a timer keeps the loop turning so adverts keep going out
    local pump = os.startTimer(0.2)
    local wrapped = function(ev)
      if ev[1] == "timer" and ev[2] == pump then pump = os.startTimer(0.2) end
      return handle(ev)
    end
    local r = ui.loop(draw, wrapped)
    os.cancelTimer(pump)
    if r ~= 1 then return false end
    return result
  end

  ------------------------------------------------------------------- guest
  local browser, err = net.browsing("bombard")
  if not browser then
    api.ui.alert(" Modem problem ", { tostring(err) }, colors.red)
    return false
  end

  local sel = 1
  local hosts = {}
  local waiting = nil
  local notice = nil          -- why the last attempt did not work
  local result = nil

  -- How long to keep asking before giving up. Long enough to ride out a few
  -- lost messages, short enough that nobody sits looking at a frozen screen
  -- wondering whether it is working.
  local JOIN_TIMEOUT = 8

  local function draw()
    gfx.clear(colors.black)
    gfx.panel(6, 3, 40, 15, colors.gray, " Join a match ", colors.white, colors.blue)
    if waiting then
      gfx.center(8, "Joining " .. waiting.name .. "...", colors.yellow, colors.gray)
      gfx.center(10, "waiting for an answer", colors.lightGray, colors.gray)
      gfx.center(17, "Q to cancel", colors.lightGray, colors.gray)
      return
    end
    if notice then
      gfx.center(16, gfx.clip(notice, 36), colors.orange, colors.gray)
    end
    if #hosts == 0 then
      gfx.center(8, "Looking for hosts...", colors.lightGray, colors.gray)
      gfx.center(10, "Start a host on the other", colors.lightGray, colors.gray)
      gfx.center(11, "console and it appears here", colors.lightGray, colors.gray)
    else
      for i = 1, math.min(#hosts, 9) do
        local on = (i == sel)
        gfx.fill(8, 4 + i, 36, 1, on and colors.blue or colors.gray)
        gfx.text(9, 4 + i, gfx.clip(hosts[i].name, 24),
          on and colors.white or colors.lightGray, on and colors.blue or colors.gray)
        gfx.right(43, 4 + i, "#" .. hosts[i].id,
          on and colors.white or colors.lightGray, on and colors.blue or colors.gray)
      end
    end
    gfx.center(17, "Enter to join    Q to cancel", colors.lightGray, colors.gray)
  end

  local function handle(ev)
    local now = os.clock()
    browser:handle(ev, now)
    hosts = browser:list(now)
    if sel > #hosts then sel = math.max(1, #hosts) end

    if waiting then
      local msg = net.parse(ev)
      if msg and msg.from == waiting.id and msg.t == "accept" then
        result = {
          id = "join", name = "Guest", seed = msg.seed, role = "guest",
          link = net.link(waiting.id, waiting.name), peerName = waiting.name,
        }
        audio.play("bmb.connect")
        return 1
      end
      if msg and msg.from == waiting.id and msg.t == "refuse" then
        notice = waiting.name .. " is " .. (msg.why or "not available")
        waiting = nil
        audio.play("ui.deny")
        return nil
      end
      -- the host packed up while we were asking
      if msg and msg.from == waiting.id and msg.t == "unhost" then
        notice = waiting.name .. " stopped hosting"
        waiting = nil
        audio.play("ui.deny")
        return nil
      end
      if ev[1] == "key" and (ev[2] == keys.q or ev[2] == keys.backspace) then
        waiting = nil
        return nil
      end
      -- Keep asking rather than assuming the first attempt landed, but do not
      -- ask forever: without a limit a lost acceptance leaves the guest on
      -- this screen indefinitely.
      if now - waiting.started > JOIN_TIMEOUT then
        notice = "No answer from " .. waiting.name
        waiting = nil
        audio.play("ui.deny")
        return nil
      end
      if now - waiting.asked > 0.7 then
        waiting.asked = now
        net.requestJoin(waiting.id, "bombard")
      end
      return nil
    end

    if ev[1] == "key" then
      local k = ev[2]
      if k == keys.q or k == keys.backspace then
        net.close()
        return 0
      elseif k == keys.up or k == keys.w then
        sel = sel > 1 and sel - 1 or math.max(1, #hosts)
      elseif k == keys.down or k == keys.s then
        sel = sel < #hosts and sel + 1 or 1
      elseif (k == keys.enter or k == keys.space) and hosts[sel] then
        waiting = { id = hosts[sel].id, name = hosts[sel].name, asked = now, started = now }
        notice = nil
        net.requestJoin(waiting.id, "bombard")
      end
    elseif ev[1] == "mouse_click" then
      local mx, my = api.ui.toLocal(ev[3], ev[4])
      local row = my - 4
      if row >= 1 and row <= #hosts and mx >= 8 and mx <= 43 then
        if row == sel then
          waiting = { id = hosts[sel].id, name = hosts[sel].name, asked = now, started = now }
        notice = nil
          net.requestJoin(waiting.id, "bombard")
        else
          sel = row
        end
      end
    end
    return nil
  end

  local pump = os.startTimer(0.2)
  local wrapped = function(ev)
    if ev[1] == "timer" and ev[2] == pump then pump = os.startTimer(0.2) end
    return handle(ev)
  end
  local r = api.ui.loop(draw, wrapped)
  os.cancelTimer(pump)
  if r ~= 1 then
    net.close()
    return false
  end
  return result
end

local function configure(api, mode)
  if not (mode and mode.net) then return mode end
  return lobby(api, mode)
end

------------------------------------------------------------------- cover art
--- The launcher gives this 56 x 21 pixels, which is small enough that the
--- first attempt fell apart on it: the ground was drawn with a height of
--- `c.h - y`, and wherever the hills dipped to the very bottom that height
--- came out zero and left holes straight through the terrain.
local function cover(c, t)
  c:clear(colors.black)

  local base = c.h - 3
  local surf = {}
  for x = 1, c.w do
    local hill = 2.4 * sin(x / 6.5) + 1.4 * sin(x / 3.1 + 1.2)
    local y = floor(base - hill + 0.5)
    if y < 6 then y = 6 end
    if y > c.h - 1 then y = c.h - 1 end
    surf[x] = y
    c:fill(x, y, 1, c.h - y + 1, colors.green)
  end

  --- A gun standing on the ground where it actually is, barrel included, so
  --- it reads as artillery rather than a coloured brick.
  local function gun(x, colour, facing)
    local y = surf[x] - 1
    c:fill(x - 2, y - 1, 5, 2, colour)
    c:fill(x - 1, y - 3, 3, 2, colour)
    c:line(x, y - 4, x + facing * 4, y - 7, colour)
  end
  gun(7, colors.lightBlue, 1)
  gun(c.w - 6, colors.red, -1)

  -- A shell crossing between them, with a pause at each end of the loop so
  -- the arc reads as a shot rather than a permanent rainbow.
  local n = 30
  local span = (t * 0.45) % 1.5
  local shown = floor(n * span)
  if shown > n then shown = n end
  for i = 1, shown do
    local u = i / n
    local x = floor(8 + u * (c.w - 16))
    local y = floor(surf[7] - 6 - sin(u * pi) * 8)
    if x >= 1 and x <= c.w and y >= 1 and y <= c.h then
      c:set(x, y, colors.white)
    end
  end
end

return {
  id = "bombard",
  name = "Bombard",
  tagline = "Two guns, one hill, and a modem",
  accent = colors.orange,
  order = 45,
  cover = cover,
  music = "descent",
  controls = {
    { "Left / Right", "Aim" },
    { "Up / Down", "Power" },
    { "Space", "Fire" },
    { "Mouse", "Drag back and release" },
    { "P", "Pause menu" },
  },
  modes = {
    -- Calibrated against a reference player -- a bot that searches for a shot
    -- and then misses by a human-sized margin -- rather than by eye. The
    -- first cut had hard at tries 90 / error 2, which is a gun that never
    -- misses: unbeatable, and exactly the mistake that made Invaders no fun.
    -- These give that reference player roughly 88% / 66% / 32% of matches.
    { id = "easy", name = "CPU: Easy", hint = "wild aim", cpu = "easy", tries = 8, error = 18 },
    { id = "normal", name = "CPU: Normal", hint = "ranges you in", cpu = "normal", tries = 20, error = 12 },
    { id = "hard", name = "CPU: Hard", hint = "rarely misses twice", cpu = "hard", tries = 48, error = 7 },
    { id = "hotseat", name = "Same console", hint = "take turns", twoPlayer = true },
    { id = "host", name = "Host a match", hint = "wait for a challenger", net = "host" },
    { id = "join", name = "Join a match", hint = "find a host nearby", net = "join" },
  },
  trophies = {
    { id = "bmb_win", name = "Ranged In", desc = "Win a duel",
      test = function(g) return g.winner and g.winner == (g.me or 1) end },
    { id = "bmb_hard", name = "Counter-Battery", desc = "Beat the hard opponent",
      test = function(g) return g.cpu == "hard" and g.winner == 1 end },
    { id = "bmb_direct", name = "Down The Barrel", desc = "Land a direct hit",
      test = function(g) return (g.direct[g.me or 1] or 0) > 0 end },
    { id = "bmb_net", name = "Across The Wire", desc = "Win a match over a modem",
      test = function(g)
        return g.link ~= nil and g.winner == g.me and not g.byDisconnect
      end },
  },
  configure = configure,
  demo = demo,
  new = new,
}
