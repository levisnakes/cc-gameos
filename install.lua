--[[ GameOS installer -- the whole console in one file.

  This writes 34 files and then you are done. Nothing is downloaded, so
  it works on a computer with HTTP disabled.

    install            unpack into this computer
    install <folder>   unpack somewhere else

  After it finishes, reboot the computer or run: gameos
]]

local target = ({ ... })[1] or ""
if target ~= "" then
  target = "/" .. target:gsub("^/+", ""):gsub("/+$", "")
end

local FILES = {}
local ORDER = {}

local function file(path, body)
  FILES[path] = body
  ORDER[#ORDER + 1] = path
end

file("gameos.lua", [=[
--[[ gameos -- launcher.

  usage:
    gameos                 run on this computer's screen
    gameos monitor <side>  run on an attached monitor (needs 3x3 or larger)
]]

local args = { ... }

local function loadChunk(path)
  local handle = fs.open(path, "r")
  if not handle then return nil, "missing " .. path end
  local src = handle.readAll()
  handle.close()
  return load(src, "@" .. path, "t", _ENV)
end

local BOOT = "/gameos/boot.lua"
if not fs.exists(BOOT) then
  print("GameOS is not installed.")
  print("Expected to find " .. BOOT)
  return
end

local target, previous = nil, nil

if args[1] == "monitor" then
  local side = args[2]
  if not side then
    print("usage: gameos monitor <side>")
    return
  end
  if peripheral.getType(side) ~= "monitor" then
    print("No monitor on side '" .. tostring(side) .. "'.")
    print("Sides: " .. table.concat(peripheral.getNames(), ", "))
    return
  end
  target = peripheral.wrap(side)
  target.setTextScale(0.5)
  local w, h = target.getSize()
  if w < 51 or h < 19 then
    print(string.format("That monitor is %dx%d characters.", w, h))
    print("GameOS needs 51x19 -- use a 3x3 monitor or bigger.")
    return
  end
  previous = term.redirect(target)
end

local chunk, err = loadChunk(BOOT)
if not chunk then
  print(err)
  if previous then term.redirect(previous) end
  return
end

local ok, runErr = pcall(chunk)

if previous then
  term.redirect(previous)
  if target then
    target.setBackgroundColour(colors.black)
    target.setTextColour(colors.white)
    target.clear()
    target.setCursorPos(1, 1)
  end
end

if not ok then
  printError(tostring(runErr))
end
]=])
file("gameos/boot.lua", [=[
--[[ GameOS -- boot loader.

  Sets up the module loader, brings up the display, loads settings and the
  game catalogue, then hands control to the shell. Restores the terminal on
  the way out no matter how we got there.
]]

local BASE = "/gameos"
local VERSION = "1.0.0"

------------------------------------------------------------- module loader
local function makeLoader(base)
  local cache = {}
  local loading = {}
  local req
  req = function(name)
    local hit = cache[name]
    if hit ~= nil then return hit end
    if loading[name] then error("circular require: " .. name, 0) end
    local path = base .. "/" .. (name:gsub("%.", "/")) .. ".lua"
    local handle = fs.open(path, "r")
    if not handle then error("module not found: " .. name .. " (" .. path .. ")", 0) end
    local src = handle.readAll()
    handle.close()
    local chunk, err = load(src, "@" .. path, "t", _ENV)
    if not chunk then error("compile error in " .. path .. ": " .. tostring(err), 0) end
    loading[name] = true
    local mod = chunk(req, name)
    loading[name] = nil
    if mod == nil then mod = true end
    cache[name] = mod
    return mod
  end
  return req
end

local req = makeLoader(BASE)

--------------------------------------------------------------- bring-up
local gfx = req("lib.gfx")

local ok, why = gfx.init(term.current())
if not ok then
  term.setBackgroundColour(colors.black)
  term.setTextColour(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("GameOS could not start.")
  print("")
  print(why)
  print("")
  print("Use an Advanced Computer, or attach a")
  print("monitor at least 4 blocks wide and 3 tall")
  print("and run:  gameos monitor <side>")
  return
end

local finished, bootErr = pcall(function()
  local Canvas = req("lib.canvas")
  local font = req("lib.font")
  local input = req("lib.input")
  local audio = req("lib.audio")
  local data = req("lib.data")
  local ui = req("lib.ui")
  local runtime = req("lib.runtime")

  data.load()
  gfx.applyTheme(gfx.themeByID(data.get("theme")))
  audio.init()
  audio.volumes.master = data.get("volMaster") / 10
  audio.volumes.music = data.get("volMusic") / 10
  audio.volumes.sfx = data.get("volSfx") / 10

  -------------------------------------------------------- game catalogue
  local games, broken = {}, {}
  local dir = BASE .. "/games"
  if fs.exists(dir) then
    local files = fs.list(dir)
    for i = 1, #files do
      local file = files[i]
      if file:sub(-4) == ".lua" then
        local id = file:sub(1, #file - 4)
        local loaded, def = pcall(req, "games." .. id)
        if loaded and type(def) == "table" and type(def.new) == "function" then
          def.id = def.id or id
          def.name = def.name or id
          games[#games + 1] = def
        else
          broken[#broken + 1] = { id = id, err = tostring(def) }
        end
      end
    end
  end
  table.sort(games, function(a, b)
    local ao, bo = a.order or 50, b.order or 50
    if ao ~= bo then return ao < bo end
    return a.name < b.name
  end)

  local api = {
    version = VERSION,
    base = BASE,
    require = req,
    gfx = gfx, canvas = Canvas, font = font,
    input = input, audio = audio, data = data,
    ui = ui, runtime = runtime,
    games = games, broken = broken,
  }

  req("os.splash").run(api)
  req("os.shell").run(api)
  data.flush()
end)

gfx.shutdown()

if not finished then
  term.setBackgroundColour(colors.black)
  term.setTextColour(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("GameOS stopped unexpectedly:")
  print("")
  print(tostring(bootErr))
else
  term.setTextColour(colors.white)
  print("GameOS " .. VERSION .. " -- thanks for playing.")
end
]=])
file("gameos/games/bombard.lua", [=[
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
]=])
file("gameos/games/breakout.lua", [=[
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
      audio.play("brk.launch")
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
  audio.play("brk.laser")
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
    audio.play("brk.steel")
    return true
  end
  brick.hp = brick.hp - 1
  if brick.hp > 0 then
    brick.colour = TOUGH_COLOUR[min(#TOUGH_COLOUR, brick.hp)]
    audio.play("brk.tough")
    return true
  end
  self.bricks[row][col] = false
  self.remaining = self.remaining - 1
  self.bricksBroken = self.bricksBroken + 1
  self.score = self.score + brick.value * self.levelIndex
  -- higher rows ring higher, so the wall plays a scale as it comes down
  audio.play("brk.brick", (ROWS - row) * 2)
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
  audio.play(p.id == "narrow" and "brk.penalty" or "brk.powerup")
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
      audio.play("brk.wall")
    elseif nx + 1 > FIELD_R then
      nx = FIELD_R - 1
      b.vx = -math.abs(b.vx)
      sx = -sx
      audio.play("brk.wall")
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
      audio.play("brk.wall")
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
        audio.play("brk.paddle")
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
    audio.play("brk.life")
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
      audio.play("result.win")
      return
    end
    audio.play("result.levelup")
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
--- Attract-mode bot: keep the paddle under the lowest ball, and let anything
--- stuck go. Deliberately a little late, so the demo has near misses in it.
local function demo(self, frame)
  if self.finished then return end
  local target = nil
  local stuck = false
  for _, b in ipairs(self.balls) do
    if b.stuck then stuck = true end
    if not target or b.y > target.y then target = b end
  end
  if stuck then self:release() end
  if target then
    self.mouseTarget = target.x - self.paddleW / 2 +
      (frame % 60 < 30 and 2 or -2)
  end
  if frame % 25 == 0 then self:fire() end
end

return {
  id = "breakout",
  name = "Breakout",
  tagline = "Ten walls, three lives",
  accent = colors.orange,
  order = 30,
  cover = cover,
  music = "ricochet",
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
  demo = demo,
  new = new,
}
]=])
file("gameos/games/connect4.lua", [=[
--[[ Connect Four -- drop discs, make a line of four.

  The computer runs a real alpha-beta search over the standard four-in-a-row
  window heuristic. Difficulty is search depth plus a chance of picking the
  second best move, so an easy opponent plays plausibly rather than randomly.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")

local floor = math.floor
local max, min = math.max, math.min

local COLS, ROWS = 7, 6
local CELL_W, CELL_H = 6, 2
local STRIDE = 7
local BOARD_X, BOARD_Y = 2, 4

local HUMAN, CPU = 1, 2

local Game = {}
Game.__index = Game

-- Inset top and bottom: a cell is only six sub-pixels tall, so without the
-- margin vertically adjacent discs merge into one solid column of colour.
local DISC = gfx.makeGlyph({
  "............",
  "...######...",
  ".##########.",
  ".##########.",
  "...######...",
  "............",
})

local DISC_COLOUR = { [HUMAN] = colors.red, [CPU] = colors.yellow }

------------------------------------------------------------------ board maths
local function idx(col, row) return (row - 1) * COLS + col end

--- Every line of four on the board, precomputed once.
local LINES = {}
do
  local DIRS = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, -1 } }
  for row = 1, ROWS do
    for col = 1, COLS do
      for _, d in ipairs(DIRS) do
        local cells = {}
        local ok = true
        for step = 0, 3 do
          local cx = col + d[1] * step
          local cy = row + d[2] * step
          if cx < 1 or cx > COLS or cy < 1 or cy > ROWS then
            ok = false
            break
          end
          cells[step + 1] = idx(cx, cy)
        end
        if ok then LINES[#LINES + 1] = cells end
      end
    end
  end
end

--- Lines grouped by the cells they pass through, so a move can be checked
--- against ~13 lines instead of all 69. That is the difference between the
--- search being comfortable and being far too slow on a real computer.
local LINES_AT = {}
for i = 1, COLS * ROWS do LINES_AT[i] = {} end
for i = 1, #LINES do
  local line = LINES[i]
  for j = 1, 4 do
    local at = LINES_AT[line[j]]
    at[#at + 1] = line
  end
end

local function winnerAt(board)
  for i = 1, #LINES do
    local line = LINES[i]
    local first = board[line[1]]
    if first ~= 0 and board[line[2]] == first
       and board[line[3]] == first and board[line[4]] == first then
      return first, line
    end
  end
  return nil
end

--- Did the disc just played at `cell` complete a four?
local function wonFrom(board, cell)
  local at = LINES_AT[cell]
  local who = board[cell]
  for i = 1, #at do
    local line = at[i]
    if board[line[1]] == who and board[line[2]] == who
       and board[line[3]] == who and board[line[4]] == who then
      return true
    end
  end
  return false
end

-- hoisted: evaluate() runs at every leaf, so it must not allocate
local MINE_WORTH = { 1, 12, 90, 100000 }
local THEIRS_WORTH = { 1, 14, 120, 100000 }

--- Positive favours `me`.
local function evaluate(board, me)
  local them = (me == HUMAN) and CPU or HUMAN
  local total = 0
  for i = 1, #LINES do
    local line = LINES[i]
    local mine, theirs = 0, 0
    for j = 1, 4 do
      local v = board[line[j]]
      if v == me then mine = mine + 1
      elseif v == them then theirs = theirs + 1 end
    end
    if mine > 0 and theirs == 0 then
      total = total + MINE_WORTH[mine]
    elseif theirs > 0 and mine == 0 then
      total = total - THEIRS_WORTH[theirs]
    end
  end
  -- the middle column is worth more than the edges
  for row = 1, ROWS do
    local v = board[idx(4, row)]
    if v == me then total = total + 6 elseif v ~= 0 then total = total - 6 end
  end
  return total
end

------------------------------------------------------------------- instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.twoPlayer = (mode and mode.twoPlayer) or false
  self.depth = (mode and mode.depth) or 4
  self.slack = (mode and mode.slack) or 0
  self.modeName = (mode and mode.name) or "Normal"

  self.board = {}
  for i = 1, COLS * ROWS do self.board[i] = 0 end
  self.heights = {}
  for c = 1, COLS do self.heights[c] = 0 end

  self.turn = HUMAN
  self.cursor = 4
  self.score = 0
  self.moves = 0
  self.finished = false
  self.won = false
  self.winLine = nil
  self.message = nil
  self.thinkTimer = 0
  self.dropAnim = nil
  self.flash = 0
  return self
end

function Game:openRow(col)
  if self.heights[col] >= ROWS then return nil end
  return ROWS - self.heights[col]
end

function Game:place(col, player)
  local row = self:openRow(col)
  if not row then
    audio.play("c4.full")
    return false
  end
  self.board[idx(col, row)] = player
  self.heights[col] = self.heights[col] + 1
  self.moves = self.moves + 1
  self.dropAnim = { col = col, row = row, t = 0.18 }
  audio.play("c4.drop")

  local winner, line = winnerAt(self.board)
  if winner then
    self.winLine = line
    self.finished = true
    self.won = (winner == HUMAN) or self.twoPlayer
    self.message = self.twoPlayer
      and ((winner == HUMAN) and "RED WINS" or "YELLOW WINS")
      or ((winner == HUMAN) and "YOU WIN" or "CPU WINS")
    local speed = max(0, 42 - self.moves) * 20
    if self.twoPlayer then
      self.score = 400 + speed
    elseif winner == HUMAN then
      -- beating a deeper search is worth more
      self.score = 1000 + speed + self.depth * 50
    else
      self.score = 0
    end
    audio.play(self.won and "c4.win" or "c4.lose")
    return true
  end

  if self.moves >= COLS * ROWS then
    self.finished = true
    self.won = false
    self.message = "A DRAW"
    self.score = 250
    audio.play("c4.draw")
    return true
  end

  self.turn = (player == HUMAN) and CPU or HUMAN
  if not self.twoPlayer and self.turn == CPU then
    self.thinkTimer = 0.45
  end
  return true
end

--------------------------------------------------------------------- search
-- searching the middle first prunes far more
local ORDER = { 4, 3, 5, 2, 6, 1, 7 }

--- Alpha-beta over drop columns. The caller has already made a move, so the
--- terminal test only has to look at lines through that cell.
---
--- `budget` is a safety net, not a working limit: measured node counts are
--- about 600 at depth 4 and 3,800 at depth 5 in the worst mid-game case, well
--- under the ceiling, because a search that runs out of budget returns static
--- evaluations and plays worse the deeper it goes.
function Game:search(board, heights, depth, alpha, beta, player, budget, lastCell)
  budget.n = budget.n - 1
  if wonFrom(board, lastCell) then
    -- whoever is NOT to move just won
    if player == CPU then return -100000 - depth end
    return 100000 + depth
  end
  if depth <= 0 or budget.n <= 0 then return evaluate(board, CPU) end

  local full = true
  for c = 1, COLS do
    if heights[c] < ROWS then full = false break end
  end
  if full then return 0 end

  local maximising = (player == CPU)
  local best = maximising and -1e9 or 1e9
  for i = 1, COLS do
    local c = ORDER[i]
    if heights[c] < ROWS then
      local row = ROWS - heights[c]
      local cell = idx(c, row)
      board[cell] = player
      heights[c] = heights[c] + 1
      local value = self:search(board, heights, depth - 1, alpha, beta,
        maximising and HUMAN or CPU, budget, cell)
      board[cell] = 0
      heights[c] = heights[c] - 1
      if maximising then
        if value > best then best = value end
        if best > alpha then alpha = best end
      else
        if value < best then best = value end
        if best < beta then beta = best end
      end
      if alpha >= beta then break end
    end
  end
  return best
end

function Game:chooseColumn()
  local budget = { n = 20000 }
  local scored = {}
  for c = 1, COLS do
    if self.heights[c] < ROWS then
      local row = ROWS - self.heights[c]
      local cell = idx(c, row)
      self.board[cell] = CPU
      self.heights[c] = self.heights[c] + 1
      local value = self:search(self.board, self.heights, self.depth - 1,
        -1e9, 1e9, HUMAN, budget, cell)
      self.board[cell] = 0
      self.heights[c] = self.heights[c] - 1
      scored[#scored + 1] = { col = c, value = value }
    end
  end
  self.lastNodes = 20000 - budget.n
  if #scored == 0 then return nil end
  table.sort(scored, function(a, b) return a.value > b.value end)

  -- An easy opponent sometimes settles for the second best line, but it must
  -- never hand over the game: skip the slack when the best move is forced, or
  -- when the alternative loses outright.
  if self.slack > 0 and #scored > 1
     and math.abs(scored[1].value) < 90000
     and scored[2].value > -90000
     and math.random() < self.slack then
    return scored[2].col
  end
  return scored[1].col
end

--------------------------------------------------------------------- input
function Game:onKey(code, held)
  if self.finished then return end
  if code == keys.left or code == keys.a then
    self.cursor = self.cursor > 1 and self.cursor - 1 or COLS
    audio.play("c4.move")
  elseif code == keys.right or code == keys.d then
    self.cursor = self.cursor < COLS and self.cursor + 1 or 1
    audio.play("c4.move")
  elseif not held and (code == keys.space or code == keys.enter
      or code == keys.down or code == keys.s) then
    if self.twoPlayer or self.turn == HUMAN then
      self:place(self.cursor, self.turn)
    end
  elseif code >= keys.one and code <= keys.seven then
    self.cursor = code - keys.one + 1
  end
end

function Game:onMouse(kind, btn, x, y)
  if kind ~= "mouse_click" or self.finished then return end
  local col = floor((x - BOARD_X) / STRIDE) + 1
  if col < 1 or col > COLS then return end
  self.cursor = col
  if self.twoPlayer or self.turn == HUMAN then
    self:place(col, self.turn)
  end
end

-------------------------------------------------------------------- update
function Game:update(dt)
  if self.dropAnim then
    self.dropAnim.t = self.dropAnim.t - dt
    if self.dropAnim.t <= 0 then self.dropAnim = nil end
  end
  if self.flash > 0 then self.flash = self.flash - dt end
  if self.finished then
    self.flash = (self.flash > 0) and self.flash or 0.5
    return
  end

  if not self.twoPlayer and self.turn == CPU then
    if self.thinkTimer > 0 then
      self.thinkTimer = self.thinkTimer - dt
      if self.thinkTimer <= 0 then
        local col = self:chooseColumn()
        if col then self:place(col, CPU) end
      end
    end
  end
end

---------------------------------------------------------------------- draw
function Game:draw()
  gfx.clear(colors.black)

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  if self.twoPlayer then
    gfx.text(2, 1, "RED", colors.red, colors.gray)
    gfx.text(6, 1, "vs", colors.lightGray, colors.gray)
    gfx.text(9, 1, "YELLOW", colors.yellow, colors.gray)
  else
    gfx.text(2, 1, "YOU", colors.red, colors.gray)
    gfx.text(6, 1, "vs", colors.lightGray, colors.gray)
    gfx.text(9, 1, "CPU " .. self.modeName, colors.yellow, colors.gray)
  end
  if self.finished then
    gfx.right(gfx.W - 1, 1, self.message or "", colors.white, colors.gray)
  else
    local who = self.turn == HUMAN and "RED" or "YELLOW"
    if not self.twoPlayer then who = self.turn == HUMAN and "YOUR TURN" or "THINKING" end
    gfx.right(gfx.W - 1, 1, who, DISC_COLOUR[self.turn], colors.gray)
  end

  -- drop marker above the board
  gfx.fill(1, BOARD_Y - 1, gfx.W, 1, colors.black)
  if not self.finished and (self.twoPlayer or self.turn == HUMAN) then
    local mx = BOARD_X + (self.cursor - 1) * STRIDE
    gfx.fill(mx, BOARD_Y - 1, CELL_W, 1, DISC_COLOUR[self.turn])
  end

  gfx.fill(1, BOARD_Y, gfx.W, ROWS * CELL_H, colors.blue)

  local winSet = {}
  if self.winLine then
    for _, cell in ipairs(self.winLine) do winSet[cell] = true end
  end

  for row = 1, ROWS do
    for col = 1, COLS do
      local sx = BOARD_X + (col - 1) * STRIDE
      local sy = BOARD_Y + (row - 1) * CELL_H
      local v = self.board[idx(col, row)]
      local colour = colors.black
      if v ~= 0 then colour = DISC_COLOUR[v] end
      if winSet[idx(col, row)] and floor(self.flash * 6) % 2 == 0 then
        colour = colors.white
      end
      gfx.blitGlyph(sx, sy, DISC, colour, colors.blue)
    end
  end

  gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
  if self.finished then
    gfx.center(19, (self.message or "") .. " -- " .. self.moves .. " discs",
      colors.white, colors.black)
  else
    gfx.center(19, "Left/Right choose   Space drop", colors.lightGray, colors.black)
  end
end

function Game:summary()
  return {
    { "Result", self.message or "unfinished" },
    { "Discs played", self.moves },
    { "Opponent", self.twoPlayer and "human" or self.modeName },
  }
end

---------------------------------------------------------------------- cover
local function cover(c, t)
  c:clear(colors.blue)
  local cell = 9
  local ox = floor((c.w - 5 * cell) / 2)
  local oy = 1
  local drop = floor(t * 3) % 8
  for row = 1, 2 do
    for col = 1, 5 do
      local x = ox + (col - 1) * cell
      local y = oy + (row - 1) * cell
      local v = 0
      if row == 2 and col <= 4 then v = (col % 2 == 1) and 1 or 2 end
      if row == 1 and col == 3 and drop > 3 then v = 1 end
      local colour = colors.black
      if v == 1 then colour = colors.red elseif v == 2 then colour = colors.yellow end
      c:circle(x + 3, y + 3, 3, colour, true)
    end
  end
  if drop <= 3 then
    c:circle(ox + 2 * cell + 3, 1 + drop * 2, 3, colors.red, true)
  end
end

----------------------------------------------------------------- definition
return {
  id = "connect4",
  name = "Connect Four",
  tagline = "Four in a row, and a real opponent",
  accent = colors.blue,
  order = 130,
  cover = cover,
  music = "gambit",
  controls = {
    { "Left / Right", "Choose a column" },
    { "1 - 7", "Jump to a column" },
    { "Space / Down", "Drop a disc" },
    { "Click", "Drop in that column" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "easy", name = "Easy", hint = "shallow, forgiving", depth = 2, slack = 0.5 },
    { id = "normal", name = "Normal", hint = "thinks ahead", depth = 4, slack = 0.15 },
    { id = "hard", name = "Hard", hint = "does not blunder", depth = 5, slack = 0 },
    { id = "two", name = "Two players", hint = "share the keyboard", twoPlayer = true },
  },
  trophies = {
    { id = "c4_win", name = "Four In A Row", desc = "Beat the computer",
      test = function(g) return g.won and not g.twoPlayer end },
    { id = "c4_hard", name = "Out-Thought It", desc = "Beat the hard computer",
      test = function(g) return g.won and not g.twoPlayer and g.depth >= 5 end },
    { id = "c4_quick", name = "Quick Work", desc = "Win in 12 discs or fewer",
      test = function(g) return g.won and not g.twoPlayer and g.moves <= 12 end },
  },
  new = new,
}
]=])
file("gameos/games/flappy.lua", [=[
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
    audio.play("fly.flap")
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
  audio.play("fly.hit")
  audio.play("fly.fall")
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
      audio.play("fly.score", min(10, self.score))
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
--- Attract-mode bot: aim for the middle of the next gap and flap when below
--- it. The lookahead is deliberately short, so it clips a pipe eventually.
local function demo(self, frame)
  if self.finished then return end
  if self.state == "ready" then
    self:flap()
    return
  end
  local target = 22
  local nearest
  for _, p in ipairs(self.pipes) do
    if p.x + 8 > 20 and (not nearest or p.x < nearest.x) then nearest = p end
  end
  if nearest then target = nearest.gapY + self.gap / 2 end
  if self.y > target + 1 and self.vy > -8 then self:flap() end
end

return {
  id = "flappy",
  name = "Flappy",
  tagline = "One button, no mercy",
  accent = colors.yellow,
  order = 80,
  cover = cover,
  music = "updraft",
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
  demo = demo,
  new = new,
}
]=])
file("gameos/games/g2048.lua", [=[
--[[ 2048 -- slide, merge, repeat.

  Big character-cell tiles with a one-step undo. Tile text colour comes from
  gfx.contrast so every palette theme stays readable.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")

local floor = math.floor
local min, max = math.min, math.max

local Game = {}
Game.__index = Game

local N = 4
local TILE_W, TILE_H = 10, 3
-- three frames at 20 FPS: enough to read as a slide, short enough to stay snappy
local SLIDE_TIME = 0.15
local BOARD_X, BOARD_Y = 4, 2

local TILE_BG = {
  [2] = colors.lightGray, [4] = colors.white, [8] = colors.orange,
  [16] = colors.red, [32] = colors.magenta, [64] = colors.purple,
  [128] = colors.yellow, [256] = colors.lime, [512] = colors.cyan,
  [1024] = colors.lightBlue, [2048] = colors.pink, [4096] = colors.green,
  [8192] = colors.blue,
}

local function tileColour(v)
  return TILE_BG[v] or colors.white
end

local function tilePos(col, row)
  return BOARD_X + 1 + (col - 1) * (TILE_W + 1), BOARD_Y + 1 + (row - 1) * (TILE_H + 1)
end

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.grid = {}
  for i = 1, N * N do self.grid[i] = 0 end
  self.score = 0
  self.moves = 0
  self.biggest = 0
  self.finished = false
  self.won = false
  self.reached2048 = false
  self.undoGrid = nil
  self.pop = {}
  self.slides = nil
  self.slideTime = 0
  self.message = nil
  self.messageTime = 0
  self:spawn()
  self:spawn()
  return self
end

function Game:get(col, row) return self.grid[(row - 1) * N + col] end
function Game:set(col, row, v) self.grid[(row - 1) * N + col] = v end

function Game:spawn()
  local free = {}
  for i = 1, N * N do
    if self.grid[i] == 0 then free[#free + 1] = i end
  end
  if #free == 0 then return false end
  local idx = free[math.random(1, #free)]
  self.grid[idx] = (math.random(1, 10) == 1) and 4 or 2
  self.pop[idx] = 0.18
  return true
end

function Game:say(text)
  self.message = text
  self.messageTime = 1.8
end

------------------------------------------------------------------ movement
--- Collapse one line towards index 1. Returns the new line, points scored,
--- which output slots ended up merged, and where every tile travelled so the
--- move can be animated.
local function slideLine(line)
  local out, merged, moves = {}, {}, {}
  local gained = 0
  local pending = nil
  for i = 1, N do
    local v = line[i]
    if v ~= 0 then
      if pending == v then
        out[#out] = v * 2
        merged[#out] = true
        gained = gained + v * 2
        moves[#moves + 1] = { from = i, to = #out, value = v }
        pending = nil
      else
        out[#out + 1] = v
        moves[#moves + 1] = { from = i, to = #out, value = v }
        pending = v
      end
    end
  end
  for i = #out + 1, N do out[i] = 0 end
  return out, gained, merged, moves
end

local READ = {
  left = function(i, j) return j, i end,
  right = function(i, j) return N + 1 - j, i end,
  up = function(i, j) return i, j end,
  down = function(i, j) return i, N + 1 - j end,
}

function Game:move(dir)
  if self.finished then return false end
  -- a press during the slide is remembered rather than dropped, so quick
  -- play never feels like it is eating inputs
  if self.slideTime > 0 then
    if READ[dir] then self.queued = dir end
    return false
  end
  local map = READ[dir]
  if not map then return false end

  local snapshot = {}
  for i = 1, N * N do snapshot[i] = self.grid[i] end

  local line = {}
  local changed = false
  local gained = 0
  local popped = {}
  local slides = {}

  for i = 1, N do
    for j = 1, N do
      local col, row = map(i, j)
      line[j] = self:get(col, row)
    end
    local out, points, merged, moves = slideLine(line)
    gained = gained + points
    for _, mv in ipairs(moves) do
      local fx, fy = map(i, mv.from)
      local tx, ty = map(i, mv.to)
      if fx ~= tx or fy ~= ty then changed = true end
      slides[#slides + 1] = { value = mv.value, fx = fx, fy = fy, tx = tx, ty = ty }
    end
    for j = 1, N do
      local col, row = map(i, j)
      if self:get(col, row) ~= out[j] then changed = true end
      self:set(col, row, out[j])
      if merged[j] then popped[(row - 1) * N + col] = true end
    end
  end

  if not changed then
    audio.play("g2048.deny")
    return false
  end

  self.undoGrid = snapshot
  self.undoScore = self.score
  self.score = self.score + gained
  self.moves = self.moves + 1
  self.pendingPop = popped
  self.slides = slides
  self.slideTime = SLIDE_TIME
  if gained > 0 then
    -- bigger merges ring higher
    audio.play("g2048.merge", min(10, floor(gained / 32)))
  else
    audio.play("g2048.slide")
  end
  return true
end

--- Called once the slide animation has played out.
function Game:settle()
  self.slides = nil
  for idx in pairs(self.pendingPop or {}) do self.pop[idx] = 0.2 end
  self.pendingPop = nil
  self:spawn()
  self:afterMove()
  local queued = self.queued
  self.queued = nil
  if queued and not self.finished then self:move(queued) end
end

function Game:afterMove()
  self.biggest = 0
  for i = 1, N * N do
    if self.grid[i] > self.biggest then self.biggest = self.grid[i] end
  end
  if self.biggest >= 2048 and not self.reached2048 then
    self.reached2048 = true
    self.won = true
    self:say("2048! KEEP GOING")
    audio.play("result.win")
  end
  if not self:hasMove() then
    self.finished = true
    audio.play("result.lose")
  end
end

function Game:hasMove()
  for i = 1, N * N do
    if self.grid[i] == 0 then return true end
  end
  for row = 1, N do
    for col = 1, N do
      local v = self:get(col, row)
      if col < N and self:get(col + 1, row) == v then return true end
      if row < N and self:get(col, row + 1) == v then return true end
    end
  end
  return false
end

function Game:undo()
  if self.slideTime > 0 then return end
  if not self.undoGrid then
    audio.play("g2048.deny")
    return
  end
  for i = 1, N * N do self.grid[i] = self.undoGrid[i] end
  self.score = self.undoScore or self.score
  self.undoGrid = nil
  self.finished = false
  self.moves = math.max(0, self.moves - 1)
  audio.play("g2048.undo")
  self:say("UNDO")
end

--------------------------------------------------------------------- input
function Game:onKey(code, held)
  if code == keys.left or code == keys.a then
    self:move("left")
  elseif code == keys.right or code == keys.d then
    self:move("right")
  elseif code == keys.up or code == keys.w then
    self:move("up")
  elseif code == keys.down or code == keys.s then
    self:move("down")
  elseif code == keys.u and not held then
    self:undo()
  end
end

--- Two ways to play with a pointer: swipe across the board, or click toward
--- an edge. The swipe is the natural gesture and takes priority; a click that
--- goes nowhere falls back to the edge rule so a single tap still moves.
function Game:onMouse(kind, btn, x, y)
  if kind == "mouse_click" then
    self.dragFrom = { x, y }
    self.dragged = false
    return
  end

  if kind == "mouse_drag" and self.dragFrom then
    local dx = x - self.dragFrom[1]
    local dy = y - self.dragFrom[2]
    -- characters are about twice as wide as they are tall, so horizontal
    -- distance has to be scaled up before the two axes can be compared
    local hx, hy = dx * 2, dy * 3
    if not self.dragged and (hx * hx + hy * hy) >= 36 then
      self.dragged = true
      if math.abs(hx) > math.abs(hy) then
        self:move(dx > 0 and "right" or "left")
      else
        self:move(dy > 0 and "down" or "up")
      end
    end
    return
  end

  if kind == "mouse_up" then
    local from = self.dragFrom
    self.dragFrom = nil
    if self.dragged or not from then return end
    -- no swipe happened, so treat it as a click toward a screen edge
    local dx, dy = from[1] - gfx.W / 2, from[2] - gfx.H / 2
    if math.abs(dx) * 0.4 > math.abs(dy) then
      self:move(dx > 0 and "right" or "left")
    else
      self:move(dy > 0 and "down" or "up")
    end
  end
end

-------------------------------------------------------------------- update
function Game:update(dt)
  if self.slideTime > 0 then
    self.slideTime = self.slideTime - dt
    if self.slideTime <= 0 then
      self.slideTime = 0
      self:settle()
    end
  end
  for idx, t in pairs(self.pop) do
    local left = t - dt
    if left <= 0 then self.pop[idx] = nil else self.pop[idx] = left end
  end
  if self.messageTime > 0 then
    self.messageTime = self.messageTime - dt
    if self.messageTime <= 0 then self.message = nil end
  end
end

---------------------------------------------------------------------- draw
function Game:draw()
  gfx.clear(colors.black)

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  gfx.text(2, 1, "SCORE", colors.lightGray, colors.gray)
  gfx.text(8, 1, gfx.commas(self.score), colors.white, colors.gray)
  gfx.center(1, "MOVES " .. self.moves, colors.lightGray, colors.gray)
  gfx.right(gfx.W - 1, 1, "MAX " .. gfx.commas(self.biggest), colors.yellow, colors.gray)

  gfx.fill(BOARD_X, BOARD_Y, N * (TILE_W + 1) + 1, N * (TILE_H + 1) + 1, colors.gray)

  -- empty slots first, then either the sliding tiles or the settled board
  for row = 1, N do
    for col = 1, N do
      local x, y = tilePos(col, row)
      gfx.fill(x, y, TILE_W, TILE_H, colors.black)
    end
  end

  local function drawTile(x, y, v, lit)
    local bg = tileColour(v)
    gfx.fill(x, y, TILE_W, TILE_H, bg)
    if lit then
      gfx.fill(x, y, TILE_W, 1, colors.white)
      gfx.fill(x, y + TILE_H - 1, TILE_W, 1, colors.white)
    end
    gfx.center(y + 1, tostring(v), gfx.contrast(bg), bg, x, TILE_W)
  end

  if self.slides then
    local k = 1 - (self.slideTime / SLIDE_TIME)
    if k < 0 then k = 0 elseif k > 1 then k = 1 end
    for _, s in ipairs(self.slides) do
      local fx, fy = tilePos(s.fx, s.fy)
      local tx, ty = tilePos(s.tx, s.ty)
      drawTile(floor(fx + (tx - fx) * k + 0.5), floor(fy + (ty - fy) * k + 0.5), s.value)
    end
  else
    for row = 1, N do
      for col = 1, N do
        local v = self:get(col, row)
        if v ~= 0 then
          local x, y = tilePos(col, row)
          drawTile(x, y, v, self.pop[(row - 1) * N + col])
        end
      end
    end
  end

  if self.message then
    local text = self.message
    local w = #text + 4
    local x = floor((gfx.W - w) / 2) + 1
    gfx.fill(x, 10, w, 1, colors.yellow)
    gfx.center(10, text, gfx.contrast(colors.yellow), colors.yellow, x, w)
  end

  gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
  gfx.center(19, "Arrows slide   U undo   P pause", colors.lightGray, colors.black)
end

function Game:summary()
  return {
    { "Biggest tile", self.biggest },
    { "Moves", self.moves },
  }
end

---------------------------------------------------------------------- cover
local COVER_VALUES = { 2, 4, 8, 16, 32, 64, 128, 256, 512 }

local function cover(c, t)
  c:clear(colors.gray)
  local cell = 6
  local ox = floor((c.w - 3 * cell - 2) / 2)
  local oy = floor((c.h - 3 * cell - 2) / 2)
  for row = 1, 3 do
    for col = 1, 3 do
      local i = (row - 1) * 3 + col
      local shift = floor(t * 1.4) % #COVER_VALUES
      local v = COVER_VALUES[((i + shift - 1) % #COVER_VALUES) + 1]
      local x = ox + (col - 1) * (cell + 1)
      local y = oy + (row - 1) * (cell + 1)
      c:fill(x, y, cell, cell, tileColour(v))
    end
  end
end

----------------------------------------------------------------- definition
return {
  id = "2048",
  name = "2048",
  tagline = "Powers of two, one grid",
  accent = colors.yellow,
  order = 60,
  cover = cover,
  music = "quiet",
  controls = {
    { "Arrows / WASD", "Slide tiles" },
    { "U", "Undo one move" },
    { "Click", "Slide that way" },
    { "Mouse", "Swipe or click an edge" },
    { "P", "Pause menu" },
  },
  trophies = {
    { id = "g2048_512", name = "Halfway", desc = "Build a 512 tile",
      test = function(g) return g.biggest >= 512 end },
    { id = "g2048_win", name = "2048!", desc = "Build the 2048 tile",
      test = function(g) return g.biggest >= 2048 end },
    { id = "g2048_10k", name = "Five Figures", desc = "Score ten thousand",
      test = function(g) return g.score >= 10000 end },
  },
  new = new,
}
]=])
file("gameos/games/lightsout.lua", [=[
--[[ Lights Out -- switch every light off.

  Pressing a cell flips it and its four neighbours. Puzzles are generated by
  starting from a solved board and applying random presses, so every board is
  guaranteed solvable, and the number of presses used to scramble it is a
  genuine upper bound on the solution length.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")

local floor = math.floor
local max, min = math.max, math.min

local N = 5
local CELL_W, CELL_H = 7, 2
local GAP = 1
local ORIGIN_X = floor((gfx.W - (N * (CELL_W + GAP) - GAP)) / 2) + 1
local ORIGIN_Y = 3

local Game = {}
Game.__index = Game

local BULB_ON = gfx.makeGlyph({
  "............",
  "..########..",
  ".##########.",
  ".##########.",
  "..########..",
  "............",
})
local BULB_OFF = gfx.makeGlyph({
  "..........",
  "...####...",
  "..######..",
  "..######..",
  "...####...",
  "..........",
})

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.scramble = (mode and mode.scramble) or 4
  self.growth = (mode and mode.growth) or 1
  self.board = {}
  self.round = 0
  self.moves = 0
  self.totalMoves = 0
  self.score = 0
  self.finished = false
  self.won = false
  self.cursorX, self.cursorY = 3, 3
  self.time = 0
  self.parCleared = false
  self.limit = (mode and mode.limit) or 120
  self.flash = 0
  self:deal()
  return self
end

function Game:index(x, y) return (y - 1) * N + x end

function Game:press(x, y, silent)
  local function flip(cx, cy)
    if cx < 1 or cx > N or cy < 1 or cy > N then return end
    local i = self:index(cx, cy)
    self.board[i] = not self.board[i]
  end
  flip(x, y)
  flip(x - 1, y)
  flip(x + 1, y)
  flip(x, y - 1)
  flip(x, y + 1)
  if not silent then
    self.moves = self.moves + 1
    self.totalMoves = self.totalMoves + 1
    audio.play(self.board[self:index(x, y)] and "lo.on" or "lo.off")
  end
end

function Game:lit()
  local n = 0
  for i = 1, N * N do
    if self.board[i] then n = n + 1 end
  end
  return n
end

--- Build a fresh board that is solvable by construction.
function Game:deal()
  self.round = self.round + 1
  self.moves = 0
  self.par = self.scramble + (self.round - 1) * self.growth
  if self.par > 14 then self.par = 14 end
  for i = 1, N * N do self.board[i] = false end
  local guard = 0
  repeat
    guard = guard + 1
    for i = 1, N * N do self.board[i] = false end
    for _ = 1, self.par do
      self:press(math.random(1, N), math.random(1, N), true)
    end
  until self:lit() > 0 or guard > 20
  self.moves = 0
end

--------------------------------------------------------------------- input
function Game:activate()
  if self.finished then return end
  self:press(self.cursorX, self.cursorY)
  if self:lit() == 0 then
    -- efficiency bonus: solving in no more presses than the scramble took
    if self.moves <= self.par then self.parCleared = true end
    local bonus = max(0, self.par * 2 - self.moves) * 15
    self.score = self.score + 200 + self.round * 50 + bonus
    self.flash = 0.6
    audio.play("lo.solved")
    self:deal()
  end
end

function Game:onKey(code, held)
  if self.finished then return end
  if code == keys.left or code == keys.a then
    self.cursorX = max(1, self.cursorX - 1)
  elseif code == keys.right or code == keys.d then
    self.cursorX = min(N, self.cursorX + 1)
  elseif code == keys.up or code == keys.w then
    self.cursorY = max(1, self.cursorY - 1)
  elseif code == keys.down or code == keys.s then
    self.cursorY = min(N, self.cursorY + 1)
  elseif not held and (code == keys.space or code == keys.enter) then
    self:activate()
  end
end

function Game:onMouse(kind, btn, x, y)
  if kind ~= "mouse_click" or self.finished then return end
  local gx = floor((x - ORIGIN_X) / (CELL_W + GAP)) + 1
  local gy = floor((y - ORIGIN_Y) / (CELL_H + GAP)) + 1
  if gx < 1 or gx > N or gy < 1 or gy > N then return end
  self.cursorX, self.cursorY = gx, gy
  self:activate()
end

-------------------------------------------------------------------- update
function Game:update(dt)
  if self.finished then return end
  if self.flash > 0 then self.flash = self.flash - dt end
  self.time = self.time + dt
  if self.time >= self.limit then
    self.finished = true
    self.won = self.round > 3
    audio.play("result.lose")
  end
end

---------------------------------------------------------------------- draw
function Game:draw()
  gfx.clear(colors.black)

  local hudBg = self.flash > 0 and colors.green or colors.gray
  gfx.fill(1, 1, gfx.W, 1, hudBg)
  gfx.text(2, 1, "SCORE", colors.lightGray, hudBg)
  gfx.text(8, 1, gfx.commas(self.score), colors.white, hudBg)
  gfx.center(1, "BOARD " .. self.round, colors.yellow, hudBg)
  local left = max(0, floor(self.limit - self.time))
  gfx.right(gfx.W - 1, 1, left .. "s", left <= 15 and colors.red or colors.lightGray, hudBg)
  gfx.right(gfx.W - 8, 1, self.moves .. "/" .. self.par, colors.lightGray, hudBg)

  for y = 1, N do
    for x = 1, N do
      local sx = ORIGIN_X + (x - 1) * (CELL_W + GAP)
      local sy = ORIGIN_Y + (y - 1) * (CELL_H + GAP)
      local on = self.board[self:index(x, y)]
      local cursor = (x == self.cursorX and y == self.cursorY)
      local bg
      if on then
        bg = cursor and colors.white or colors.yellow
      else
        bg = cursor and colors.lightGray or colors.gray
      end
      gfx.fill(sx, sy, CELL_W, CELL_H, bg)
      gfx.blitGlyph(sx + 1, sy, on and BULB_ON or BULB_OFF,
        on and colors.orange or colors.black, bg)
    end
  end

  gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
  gfx.center(19, "Arrows move   Space press   " .. self:lit() .. " lit",
    colors.lightGray, colors.black)
end

function Game:summary()
  return {
    { "Boards cleared", self.round - 1 },
    { "Presses", self.totalMoves },
  }
end

---------------------------------------------------------------------- cover
local function cover(c, t)
  c:clear(colors.black)
  local cell = 9
  local ox = floor((c.w - 5 * cell) / 2)
  local oy = floor((c.h - 3 * cell) / 2)
  local phase = floor(t * 2)
  for row = 1, 3 do
    for col = 1, 5 do
      local on = ((col * 3 + row * 5 + phase) % 4) < 2
      local x = ox + (col - 1) * cell
      local y = oy + (row - 1) * cell
      c:fill(x, y, cell - 2, cell - 2, on and colors.yellow or colors.gray)
      if on then
        c:fill(x + 2, y + 2, cell - 6, cell - 6, colors.orange)
      end
    end
  end
end

----------------------------------------------------------------- definition
return {
  id = "lightsout",
  name = "Lights Out",
  tagline = "Switch them all off",
  accent = colors.yellow,
  order = 110,
  cover = cover,
  music = "quiet",
  controls = {
    { "Arrows / WASD", "Move cursor" },
    { "Space", "Press a light" },
    { "Click", "Press a light" },
    { "", "Flips it and its neighbours" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "gentle", name = "Gentle", hint = "4 min, easy", scramble = 3, growth = 1, limit = 240 },
    { id = "standard", name = "Standard", hint = "2 min", scramble = 4, growth = 1, limit = 120 },
    { id = "tangled", name = "Tangled", hint = "3 min, messy", scramble = 7, growth = 1, limit = 180 },
  },
  trophies = {
    { id = "lo_5", name = "Sparks Out", desc = "Clear five boards in a run",
      test = function(g) return g.round - 1 >= 5 end },
    { id = "lo_perfect", name = "No Wasted Moves", desc = "Clear a board in par",
      test = function(g) return g.parCleared end },
    { id = "lo_10", name = "Blackout", desc = "Clear ten boards in a run",
      test = function(g) return g.round - 1 >= 10 end },
  },
  new = new,
}
]=])
file("gameos/games/meteors.lua", [=[
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
]=])
file("gameos/games/minesweeper.lua", [=[
--[[ Minesweeper -- character-cell grid, two cells per square.

  Mines are laid after the first click so the opening move is always safe and
  always opens a region. Supports chording: activating a satisfied number
  clears its remaining neighbours.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")

local floor = math.floor
local max, min = math.max, math.min

local Game = {}
Game.__index = Game

local NUMBER_COLOUR = {
  colors.lightBlue, colors.lime, colors.red, colors.purple,
  colors.orange, colors.cyan, colors.white, colors.lightGray,
}

local GRID_TOP = 3
local GRID_ROWS = 16

-- 4x3 sub-pixel sprites, one per two-character cell
local MINE = gfx.makeGlyph({
  ".##.",
  "####",
  ".##.",
})
local FLAG = gfx.makeGlyph({
  ".###",
  ".##.",
  ".#..",
})
local WRONG = gfx.makeGlyph({
  "#..#",
  ".##.",
  "#..#",
})

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.cols = (mode and mode.cols) or 9
  self.rows = (mode and mode.rows) or 9
  self.mines = (mode and mode.mines) or 10
  self.levelName = (mode and mode.name) or "Beginner"
  self.bonus = (mode and mode.bonus) or 500

  self.ox = floor((gfx.W - self.cols * 2) / 2) + 1
  self.oy = GRID_TOP + floor((GRID_ROWS - self.rows) / 2)

  self.cells = {}
  for i = 1, self.cols * self.rows do
    self.cells[i] = { mine = false, adj = 0, shown = false, flag = false }
  end

  self.cursorX, self.cursorY = floor(self.cols / 2) + 1, floor(self.rows / 2) + 1
  self.started = false
  self.time = 0
  self.flags = 0
  self.revealed = 0
  self.score = 0
  self.finished = false
  self.won = false
  self.blast = nil
  self.hint = "Space reveal   F flag   C chord"
  return self
end

function Game:at(x, y)
  if x < 1 or x > self.cols or y < 1 or y > self.rows then return nil end
  return self.cells[(y - 1) * self.cols + x]
end

function Game:neighbours(x, y, fn)
  for dy = -1, 1 do
    for dx = -1, 1 do
      if dx ~= 0 or dy ~= 0 then
        local cell = self:at(x + dx, y + dy)
        if cell then fn(cell, x + dx, y + dy) end
      end
    end
  end
end

--- Lay mines, keeping the first click and its neighbours clear.
function Game:layMines(safeX, safeY)
  local spots = {}
  for y = 1, self.rows do
    for x = 1, self.cols do
      if math.abs(x - safeX) > 1 or math.abs(y - safeY) > 1 then
        spots[#spots + 1] = (y - 1) * self.cols + x
      end
    end
  end
  for i = #spots, 2, -1 do
    local j = math.random(1, i)
    spots[i], spots[j] = spots[j], spots[i]
  end
  local placed = min(self.mines, #spots)
  for i = 1, placed do
    self.cells[spots[i]].mine = true
  end
  self.mines = placed

  for y = 1, self.rows do
    for x = 1, self.cols do
      local cell = self:at(x, y)
      local n = 0
      self:neighbours(x, y, function(other) if other.mine then n = n + 1 end end)
      cell.adj = n
    end
  end
  self.started = true
end

--------------------------------------------------------------------- moves
function Game:flood(x, y)
  -- iterative so a large board cannot blow the Lua stack
  local stack = { { x, y } }
  while #stack > 0 do
    local pos = table.remove(stack)
    local cx, cy = pos[1], pos[2]
    local cell = self:at(cx, cy)
    if cell and not cell.shown and not cell.flag then
      cell.shown = true
      self.revealed = self.revealed + 1
      if cell.adj == 0 and not cell.mine then
        for dy = -1, 1 do
          for dx = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
              stack[#stack + 1] = { cx + dx, cy + dy }
            end
          end
        end
      end
    end
  end
end

function Game:reveal(x, y)
  if self.finished then return end
  local cell = self:at(x, y)
  if not cell or cell.shown or cell.flag then return end
  if not self.started then self:layMines(x, y) end
  if cell.mine then
    cell.shown = true
    self.blast = { x, y }
    self:lose()
    return
  end
  self:flood(x, y)
  audio.play("ms.reveal")
  self:checkWin()
end

function Game:toggleFlag(x, y)
  if self.finished then return end
  local cell = self:at(x, y)
  if not cell or cell.shown then return end
  cell.flag = not cell.flag
  self.flags = self.flags + (cell.flag and 1 or -1)
  audio.play(cell.flag and "ms.flag" or "ms.unflag")
end

function Game:chord(x, y)
  if self.finished then return end
  local cell = self:at(x, y)
  if not cell or not cell.shown or cell.adj == 0 then return end
  local flags = 0
  self:neighbours(x, y, function(other) if other.flag then flags = flags + 1 end end)
  if flags ~= cell.adj then
    audio.play("ui.deny")
    return
  end
  local blown = false
  self:neighbours(x, y, function(other, nx, ny)
    if not other.flag and not other.shown then
      if other.mine then
        other.shown = true
        self.blast = { nx, ny }
        blown = true
      else
        self:flood(nx, ny)
      end
    end
  end)
  if blown then
    self:lose()
  else
    audio.play("ms.chord")
    self:checkWin()
  end
end

function Game:checkWin()
  local safe = self.cols * self.rows - self.mines
  if self.revealed >= safe then
    self.won = true
    self.finished = true
    for i = 1, #self.cells do
      local cell = self.cells[i]
      if cell.mine and not cell.flag then
        cell.flag = true
        self.flags = self.flags + 1
      end
    end
    local speed = max(0, 600 - floor(self.time)) * 5
    self.score = self.revealed * 10 + self.bonus + speed
    audio.play("ms.clear")
  else
    self.score = self.revealed * 10
  end
end

function Game:lose()
  self.finished = true
  self.won = false
  self.score = self.revealed * 10
  for i = 1, #self.cells do
    local cell = self.cells[i]
    if cell.mine then cell.shown = true end
  end
  audio.play("ms.boom")
end

--------------------------------------------------------------------- input
function Game:onKey(code, held)
  if self.finished then return end
  if code == keys.left or code == keys.a then
    self.cursorX = max(1, self.cursorX - 1)
  elseif code == keys.right or code == keys.d then
    self.cursorX = min(self.cols, self.cursorX + 1)
  elseif code == keys.up or code == keys.w then
    self.cursorY = max(1, self.cursorY - 1)
  elseif code == keys.down or code == keys.s then
    self.cursorY = min(self.rows, self.cursorY + 1)
  elseif code == keys.space or code == keys.enter then
    local cell = self:at(self.cursorX, self.cursorY)
    if cell and cell.shown then
      self:chord(self.cursorX, self.cursorY)
    else
      self:reveal(self.cursorX, self.cursorY)
    end
  elseif code == keys.f then
    self:toggleFlag(self.cursorX, self.cursorY)
  elseif code == keys.c then
    self:chord(self.cursorX, self.cursorY)
  end
  if held then return end
end

function Game:onMouse(kind, btn, x, y)
  if kind ~= "mouse_click" or self.finished then return end
  local gx = floor((x - self.ox) / 2) + 1
  local gy = y - self.oy + 1
  if gx < 1 or gx > self.cols or gy < 1 or gy > self.rows then return end
  self.cursorX, self.cursorY = gx, gy
  local cell = self:at(gx, gy)
  if btn == 2 then
    self:toggleFlag(gx, gy)
  elseif btn == 3 then
    self:chord(gx, gy)
  elseif cell and cell.shown then
    self:chord(gx, gy)
  else
    self:reveal(gx, gy)
  end
end

-------------------------------------------------------------------- update
function Game:update(dt)
  if self.finished then return end
  if self.started then self.time = self.time + dt end
end

---------------------------------------------------------------------- draw
function Game:draw()
  gfx.clear(colors.black)

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  gfx.text(2, 1, "MINES", colors.lightGray, colors.gray)
  local left = self.mines - self.flags
  gfx.text(8, 1, string.format("%3d", left), left < 0 and colors.red or colors.white, colors.gray)
  gfx.center(1, self.levelName, colors.lightBlue, colors.gray)
  gfx.right(gfx.W - 1, 1, string.format("%3d s", floor(self.time)), colors.yellow, colors.gray)

  local BEVEL = gfx.TOP1 .. gfx.TOP2
  for y = 1, self.rows do
    local sy = self.oy + y - 1
    for x = 1, self.cols do
      local sx = self.ox + (x - 1) * 2
      local cell = self:at(x, y)
      local isCursor = (x == self.cursorX and y == self.cursorY) and not self.finished

      if cell.shown then
        if cell.mine then
          local blasted = self.blast and self.blast[1] == x and self.blast[2] == y
          local bg = blasted and colors.red or colors.gray
          gfx.blitGlyph(sx, sy, MINE, blasted and colors.white or colors.red, bg)
        else
          local bg = isCursor and colors.blue or colors.gray
          if cell.adj > 0 then
            gfx.text(sx, sy, " " .. cell.adj, NUMBER_COLOUR[cell.adj], bg)
          else
            gfx.fill(sx, sy, 2, 1, bg)
          end
        end
      elseif cell.flag then
        local bg = isCursor and colors.lightBlue or colors.lightGray
        -- after a loss, a flag on a safe square is marked as a mistake
        local wrong = self.finished and not self.won and not cell.mine
        gfx.blitGlyph(sx, sy, wrong and WRONG or FLAG, wrong and colors.black or colors.red, bg)
      else
        -- Unrevealed tiles are drawn as a bevel: the left cell carries a lit
        -- top edge, the right cell a shaded bottom edge, so the grid reads as
        -- individual raised tiles rather than one slab.
        local face = isCursor and colors.lightBlue or colors.lightGray
        local shade = isCursor and colors.blue or colors.gray
        gfx.blitStr(sx, sy, BEVEL,
          gfx.blit[colors.white] .. gfx.blit[face],
          gfx.blit[face] .. gfx.blit[shade])
      end
    end
  end

  if self.finished then
    gfx.center(19, self.won and "Cleared!" or "Boom.", self.won and colors.lime or colors.red, colors.black)
  else
    gfx.center(19, self.hint, colors.lightGray, colors.black)
  end
end

function Game:summary()
  return {
    { "Difficulty", self.levelName },
    { "Time", floor(self.time) .. "s" },
    { "Cleared", self.revealed .. "/" .. (self.cols * self.rows - self.mines) },
  }
end

---------------------------------------------------------------------- cover
local COVER_GRID = {
  "11111111111111",
  "1..21...1*1..1",
  "1.2..1F.11...1",
  "11..2..1..3..1",
  "1.1...11..1..1",
  "111111111111 1",
}

local function cover(c, t)
  c:clear(colors.black)
  local cell = 4
  local sweep = (t * 9) % 20
  for row = 1, 6 do
    local line = COVER_GRID[row]
    for col = 1, 14 do
      local ch = line:sub(col, col)
      local x = (col - 1) * cell + 1
      local y = (row - 1) * cell + 1
      local hidden = (ch == "1")
      if col > sweep then hidden = true end
      if hidden then
        c:fill(x, y, cell - 1, cell - 1, colors.lightGray)
        c:fill(x, y, cell - 1, 1, colors.white)
      else
        c:fill(x, y, cell - 1, cell - 1, colors.gray)
        if ch == "*" then
          c:fill(x + 1, y + 1, 1, 1, colors.red)
        elseif ch == "F" then
          c:fill(x + 1, y, 1, 3, colors.red)
        elseif ch ~= "." and ch ~= " " then
          local n = tonumber(ch)
          if n then c:fill(x + 1, y + 1, 1, 1, NUMBER_COLOUR[n] or colors.white) end
        end
      end
    end
  end
end

----------------------------------------------------------------- definition
return {
  id = "minesweeper",
  name = "Minesweeper",
  tagline = "Numbers, not luck",
  accent = colors.lightBlue,
  order = 50,
  cover = cover,
  music = "quiet",
  controls = {
    { "Arrows / WASD", "Move cursor" },
    { "Space", "Reveal / chord" },
    { "F", "Toggle flag" },
    { "Left click", "Reveal" },
    { "Right click", "Flag" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "beginner", name = "Beginner", hint = "9x9, 10", cols = 9, rows = 9, mines = 10, bonus = 400 },
    { id = "medium", name = "Intermediate", hint = "16x16, 40", cols = 16, rows = 16, mines = 40, bonus = 1200 },
    { id = "expert", name = "Expert", hint = "24x16, 99", cols = 24, rows = 16, mines = 99, bonus = 3000 },
  },
  trophies = {
    { id = "ms_win", name = "All Clear", desc = "Clear any board",
      test = function(g) return g.won end },
    { id = "ms_fast", name = "Quick Sweep", desc = "Clear a board in under 40s",
      test = function(g) return g.won and g.time < 40 end },
    { id = "ms_expert", name = "Bomb Disposal", desc = "Clear the expert board",
      test = function(g) return g.won and g.cols >= 24 end },
  },
  new = new,
}
]=])
file("gameos/games/pong.lua", [=[
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
  audio.play("png.serve")
end

--------------------------------------------------------------------- input
function Game:onKey(code, held) end

--- Mouse aims the left paddle: its centre follows the pointer, which is a far
--- more natural way to play Pong than tapping a direction key.
function Game:onMouse(kind, btn, x, y)
  if kind ~= "mouse_click" and kind ~= "mouse_drag" then return end
  self.mouseY = (y - 1) * 3 + 1 - floor(PADDLE_H / 2)
end

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
  audio.play(side == "left" and "png.point" or "png.against")
  if self.leftScore >= TARGET or self.rightScore >= TARGET then
    self.finished = true
    self.won = self.leftScore > self.rightScore
    self.score = self.leftScore * 100 + max(0, self.leftScore - self.rightScore) * 50 + self.longestRally * 10
    audio.play(self.won and "result.win" or "result.lose")
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
  if ldir ~= 0 then self.mouseY = nil end   -- a key press takes the paddle back
  if self.mouseY then
    -- ease toward the pointer rather than teleporting, so the paddle keeps a
    -- speed limit and the ball can still be beaten past it
    local delta = self.mouseY - self.leftY
    local step = pspeed * 1.8 * dt
    if delta > step then delta = step elseif delta < -step then delta = -step end
    self.leftY = self:movePaddle(self.leftY + delta, 0, dt, pspeed)
  else
    self.leftY = self:movePaddle(self.leftY, ldir, dt, pspeed)
  end

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
      audio.play("png.wall")
    elseif b.y + 2 > COURT_BOTTOM then
      b.y = COURT_BOTTOM - 2
      b.vy = -abs(b.vy)
      sy = -sy
      audio.play("png.wall")
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
  -- the rally climbs in pitch, so a long exchange audibly tightens
  audio.play("png.paddle", min(10, self.rallies))
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
  music = "ricochet",
  controls = {
    { "W / S", "Left paddle" },
    { "Up / Down", "Left paddle" },
    { "I / K", "Right paddle (2P)" },
    { "Mouse", "Move left paddle" },
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
]=])
file("gameos/games/simon.lua", [=[
--[[ Simon -- watch the sequence, then repeat it.

  Each panel has its own note, so the speaker carries as much of the puzzle
  as the screen does. Playback speeds up as the sequence grows.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")

local floor = math.floor
local max = math.max

local Game = {}
Game.__index = Game

-- top-left, top-right, bottom-left, bottom-right: the Q/W/A/S block
local PANELS = {
  { x = 2,  y = 3,  key = "Q", lit = colors.lime,      idle = colors.green, pitch = 4 },
  { x = 27, y = 3,  key = "W", lit = colors.red,       idle = colors.brown, pitch = 9 },
  { x = 2,  y = 11, key = "A", lit = colors.yellow,    idle = colors.orange, pitch = 13 },
  { x = 27, y = 11, key = "S", lit = colors.lightBlue, idle = colors.blue,  pitch = 18 },
}
local PANEL_W, PANEL_H = 24, 7

local KEYMAP = {
  [keys.q] = 1, [keys.w] = 2, [keys.a] = 3, [keys.s] = 4,
  [keys.one] = 1, [keys.two] = 2, [keys.three] = 3, [keys.four] = 4,
  [keys.numPad1] = 1, [keys.numPad2] = 2, [keys.numPad3] = 3, [keys.numPad4] = 4,
}

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.strict = (mode and mode.strict) or false
  self.baseStep = (mode and mode.step) or 0.5
  self.sequence = {}
  self.round = 0
  self.score = 0
  self.lives = self.strict and 1 or 3
  self.finished = false
  self.won = false
  self.litPanel = nil
  self.litTimer = 0
  self.message = "watch"
  self:nextRound()
  return self
end

function Game:stepTime()
  -- playback tightens as the sequence grows, with a floor
  return max(0.22, self.baseStep - (self.round - 1) * 0.012)
end

function Game:nextRound()
  self.round = self.round + 1
  self.sequence[#self.sequence + 1] = math.random(1, 4)
  self.state = "wait"
  self.waitTimer = 0.7
  self.playIndex = 0
  self.playTimer = 0
  self.inputIndex = 0
  self.message = "watch"
end

function Game:flash(index, duration)
  self.litPanel = index
  self.litTimer = duration or 0.3
  audio.play("sim.pad" .. index)
end

--------------------------------------------------------------------- input
function Game:pressPanel(index)
  if self.state ~= "repeat" or self.finished then return end
  self:flash(index, 0.22)
  self.inputIndex = self.inputIndex + 1

  if self.sequence[self.inputIndex] ~= index then
    self.lives = self.lives - 1
    self.state = "wrong"
    self.wrongTimer = 0.9
    self.message = "wrong"
    audio.play("sim.wrong")
    return
  end

  if self.inputIndex >= #self.sequence then
    self.score = self.score + self.round * 25
    self.state = "clear"
    self.clearTimer = 0.5
    self.message = "good"
    audio.play("sim.round")
  end
end

function Game:onKey(code, held)
  if held then return end
  local index = KEYMAP[code]
  if index then self:pressPanel(index) end
end

function Game:onMouse(kind, btn, x, y)
  if kind ~= "mouse_click" then return end
  for i, panel in ipairs(PANELS) do
    if x >= panel.x and x < panel.x + PANEL_W
       and y >= panel.y and y < panel.y + PANEL_H then
      self:pressPanel(i)
      return
    end
  end
end

-------------------------------------------------------------------- update
function Game:update(dt)
  if self.finished then return end
  if self.litTimer > 0 then
    self.litTimer = self.litTimer - dt
    if self.litTimer <= 0 then self.litPanel = nil end
  end

  if self.state == "wait" then
    self.waitTimer = self.waitTimer - dt
    if self.waitTimer <= 0 then
      self.state = "play"
      self.playIndex = 0
      self.playTimer = 0
    end

  elseif self.state == "play" then
    self.playTimer = self.playTimer - dt
    if self.playTimer <= 0 then
      self.playIndex = self.playIndex + 1
      if self.playIndex > #self.sequence then
        self.state = "repeat"
        self.message = "your turn"
      else
        local step = self:stepTime()
        self:flash(self.sequence[self.playIndex], step * 0.62)
        self.playTimer = step
      end
    end

  elseif self.state == "clear" then
    self.clearTimer = self.clearTimer - dt
    if self.clearTimer <= 0 then self:nextRound() end

  elseif self.state == "wrong" then
    self.wrongTimer = self.wrongTimer - dt
    if self.wrongTimer <= 0 then
      if self.lives <= 0 then
        self.finished = true
        self.won = self.round > 8
        audio.play("result.lose")
      else
        -- replay the same sequence from the top
        self.state = "wait"
        self.waitTimer = 0.6
        self.inputIndex = 0
        self.message = "watch"
      end
    end
  end
end

---------------------------------------------------------------------- draw
function Game:draw()
  gfx.clear(colors.black)

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  gfx.text(2, 1, "SCORE", colors.lightGray, colors.gray)
  gfx.text(8, 1, gfx.commas(self.score), colors.white, colors.gray)
  gfx.center(1, "ROUND " .. self.round, colors.white, colors.gray)
  if self.strict then
    gfx.right(gfx.W - 1, 1, "STRICT", colors.red, colors.gray)
  else
    gfx.right(gfx.W - 1, 1, string.rep("*", max(0, self.lives)), colors.red, colors.gray)
  end

  for i, panel in ipairs(PANELS) do
    local on = (self.litPanel == i)
    local bg = on and panel.lit or panel.idle
    gfx.fill(panel.x, panel.y, PANEL_W, PANEL_H, bg)
    if on then
      -- a lit panel gets a bright inner border so it reads even in the
      -- monochrome themes
      gfx.fill(panel.x, panel.y, PANEL_W, 1, colors.white)
      gfx.fill(panel.x, panel.y + PANEL_H - 1, PANEL_W, 1, colors.white)
    end
    gfx.center(panel.y + 3, panel.key, gfx.contrast(bg), bg, panel.x, PANEL_W)
  end

  gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
  local hint = "Q W A S or click"
  if self.state == "repeat" then
    hint = "your turn -- " .. self.inputIndex .. " / " .. #self.sequence
  elseif self.state == "play" or self.state == "wait" then
    hint = "watch the sequence"
  elseif self.state == "wrong" then
    hint = self.lives > 0 and "wrong -- try again" or "wrong"
  elseif self.state == "clear" then
    hint = "correct"
  end
  gfx.center(19, hint, colors.lightGray, colors.black)
end

function Game:summary()
  return {
    { "Sequence length", #self.sequence - (self.finished and 1 or 0) },
    { "Rounds", max(0, self.round - 1) },
  }
end

---------------------------------------------------------------------- cover
local COVER_COLOURS = {
  { colors.lime, colors.green }, { colors.red, colors.brown },
  { colors.yellow, colors.orange }, { colors.lightBlue, colors.blue },
}

local function cover(c, t)
  c:clear(colors.black)
  local w, h = floor(c.w / 2) - 2, floor(c.h / 2) - 1
  local active = (floor(t * 2) % 4) + 1
  for i = 1, 4 do
    local col = ((i - 1) % 2)
    local row = floor((i - 1) / 2)
    local x = 2 + col * (w + 2)
    local y = 1 + row * (h + 2)
    local pair = COVER_COLOURS[i]
    c:fill(x, y, w, h, i == active and pair[1] or pair[2])
    if i == active then
      c:box(x, y, w, h, colors.white)
    end
  end
end

----------------------------------------------------------------- definition
return {
  id = "simon",
  name = "Simon",
  tagline = "Watch, listen, repeat",
  accent = colors.lime,
  order = 120,
  cover = cover,
  -- no soundtrack: the sequence is the point
  music = false,
  scoreLabel = "SCORE",
  controls = {
    { "Q / W", "Top panels" },
    { "A / S", "Bottom panels" },
    { "1 2 3 4", "Same panels" },
    { "Click", "Press a panel" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "normal", name = "Normal", hint = "three lives", step = 0.55 },
    { id = "fast", name = "Fast", hint = "quicker playback", step = 0.38 },
    { id = "strict", name = "Strict", hint = "one mistake ends it", step = 0.5, strict = true },
  },
  trophies = {
    { id = "simon_8", name = "Good Ear", desc = "Repeat a sequence of eight",
      test = function(g) return g.round - 1 >= 8 end },
    { id = "simon_15", name = "Photographic", desc = "Repeat a sequence of fifteen",
      test = function(g) return g.round - 1 >= 15 end },
    { id = "simon_strict", name = "One Life", desc = "Reach round 6 in Strict",
      test = function(g) return g.strict and g.round - 1 >= 6 end },
  },
  new = new,
}
]=])
file("gameos/games/snake.lua", [=[
--[[ Snake -- 32x16 board of 3px cells on the pixel canvas.

  Turns are buffered two deep so a quick left-then-up around a corner never
  gets eaten by the movement tick.
]]

local req = ...
local gfx = req("lib.gfx")
local font = req("lib.font")
local audio = req("lib.audio")

local COLS, ROWS = 32, 16
local CELL = 3
local OX, OY = 4, 4

local Game = {}
Game.__index = Game

local floor, abs = math.floor, math.abs

------------------------------------------------------------------ helpers
local function key(x, y) return (y - 1) * COLS + x end

local DIRS = {
  up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 },
}

local MAZES = {
  -- {x, y, w, h} blocks in cell coordinates
  { { 8, 4, 2, 9 }, { 24, 4, 2, 9 }, { 13, 7, 7, 2 } },
}

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.mode = (mode and mode.id) or "classic"
  self.c = api.canvas.new(1, 2, gfx.W, 18, colors.black)

  self.walls = {}
  if self.mode == "maze" then
    for _, block in ipairs(MAZES[1]) do
      for y = block[2], block[2] + block[4] - 1 do
        for x = block[1], block[1] + block[3] - 1 do
          self.walls[key(x, y)] = true
        end
      end
    end
  end

  self.occ = {}
  self.body = {}
  self.head = 0
  self.tail = 1
  local sy = floor(ROWS / 2)
  for i = 1, 4 do
    self.head = self.head + 1
    self.body[self.head] = { x = 6 + i, y = sy }
    self.occ[key(6 + i, sy)] = true
  end

  self.dir = DIRS.right
  self.queue = {}
  self.grow = 0
  self.score = 0
  self.apples = 0
  self.level = 1
  self.tick = 0
  self.interval = 0.135
  self.finished = false
  self.dying = 0
  self.flash = 0
  self.bonus = nil
  self.bonusIn = 5
  self.food = nil
  self:spawnFood()
  return self
end

function Game:length() return self.head - self.tail + 1 end

function Game:freeCell()
  for _ = 1, 400 do
    local x = math.random(1, COLS)
    local y = math.random(1, ROWS)
    local k = key(x, y)
    if not self.occ[k] and not self.walls[k] and
       not (self.food and self.food.x == x and self.food.y == y) and
       not (self.bonus and self.bonus.x == x and self.bonus.y == y) then
      return x, y
    end
  end
  -- board is nearly full: fall back to a linear scan
  for y = 1, ROWS do
    for x = 1, COLS do
      local k = key(x, y)
      if not self.occ[k] and not self.walls[k] then return x, y end
    end
  end
  return nil
end

function Game:spawnFood()
  local x, y = self:freeCell()
  if x then self.food = { x = x, y = y } else self.food = nil end
end

function Game:spawnBonus()
  local x, y = self:freeCell()
  if x then self.bonus = { x = x, y = y, life = 7, max = 7 } end
end

------------------------------------------------------------------- control
local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }

function Game:turn(name)
  if self.dying > 0 then return end
  -- compare against the last queued turn, not the current heading, so a
  -- two-key corner registers correctly
  local last = self.lastQueued
  if not last then
    for n, d in pairs(DIRS) do
      if d == self.dir then last = n break end
    end
  end
  if name == last or OPPOSITE[name] == last then return end
  if #self.queue >= 2 then return end
  self.queue[#self.queue + 1] = name
  self.lastQueued = name
end

function Game:onKey(code, held)
  if held then return end
  if code == keys.up or code == keys.w then self:turn("up")
  elseif code == keys.down or code == keys.s then self:turn("down")
  elseif code == keys.left or code == keys.a then self:turn("left")
  elseif code == keys.right or code == keys.d then self:turn("right")
  end
end

--- Steering by pointer: a click turns the snake toward wherever you clicked,
--- along whichever axis it is furthest away on. It cannot be as precise as
--- the keys on a tight lattice, but it makes the game playable with a mouse.
function Game:onMouse(kind, btn, x, y)
  if kind ~= "mouse_click" and kind ~= "mouse_drag" then return end
  local h = self.body[self.head]
  if not h then return end
  local gx = floor(((x - 1) * 2 + 1 - OX) / CELL) + 1
  local gy = floor(((y - 1) * 3 + 1 - OY) / CELL) + 1
  local dx, dy = gx - h.x, gy - h.y
  if dx == 0 and dy == 0 then return end
  -- turn along the axis with the greater gap; ties keep the current heading's
  -- perpendicular so a click never asks for an impossible reversal
  if abs(dx) > abs(dy) then
    self:turn(dx > 0 and "right" or "left")
  else
    self:turn(dy > 0 and "down" or "up")
  end
end

-------------------------------------------------------------------- update
function Game:die()
  if self.dying > 0 then return end
  self.dying = 0.9
  audio.play("snake.die")
end

function Game:step()
  local name = table.remove(self.queue, 1)
  if name then
    self.dir = DIRS[name]
    if #self.queue == 0 then self.lastQueued = name end
  end

  local h = self.body[self.head]
  local nx = h.x + self.dir[1]
  local ny = h.y + self.dir[2]

  if self.mode == "wrap" then
    if nx < 1 then nx = COLS elseif nx > COLS then nx = 1 end
    if ny < 1 then ny = ROWS elseif ny > ROWS then ny = 1 end
  elseif nx < 1 or nx > COLS or ny < 1 or ny > ROWS then
    return self:die()
  end

  local k = key(nx, ny)
  if self.walls[k] then return self:die() end

  -- the tail cell is about to move away, so running into it is legal
  local tailCell = self.body[self.tail]
  local movingTail = (self.grow == 0 and tailCell.x == nx and tailCell.y == ny)
  if self.occ[k] and not movingTail then return self:die() end

  if self.grow > 0 then
    self.grow = self.grow - 1
  else
    self.occ[key(tailCell.x, tailCell.y)] = nil
    self.body[self.tail] = nil
    self.tail = self.tail + 1
  end

  self.head = self.head + 1
  self.body[self.head] = { x = nx, y = ny }
  self.occ[k] = true

  if self.food and self.food.x == nx and self.food.y == ny then
    self.apples = self.apples + 1
    self.grow = self.grow + 2
    self.level = floor(self.apples / 5) + 1
    self.score = self.score + 10 * self.level
    self.interval = math.max(0.055, 0.135 - self.apples * 0.0022)
    self.flash = 0.12
    -- the chirp climbs as the snake grows
    audio.play("snake.eat", math.min(8, floor(self.apples / 2)))
    self:spawnFood()
    self.bonusIn = self.bonusIn - 1
    if self.bonusIn <= 0 and not self.bonus then
      self.bonusIn = 6
      self:spawnBonus()
    end
  elseif self.bonus and self.bonus.x == nx and self.bonus.y == ny then
    local worth = 50 + floor(self.bonus.life * 12)
    self.score = self.score + worth
    self.grow = self.grow + 3
    self.bonus = nil
    self.flash = 0.2
    audio.play("snake.bonus")
  end
end

function Game:update(dt)
  if self.flash > 0 then self.flash = self.flash - dt end

  if self.dying > 0 then
    self.dying = self.dying - dt
    if self.dying <= 0 then self.finished = true end
    return
  end

  if self.bonus then
    self.bonus.life = self.bonus.life - dt
    if self.bonus.life <= 0 then self.bonus = nil end
  end

  self.tick = self.tick + dt
  local guard = 0
  while self.tick >= self.interval and self.dying <= 0 and guard < 4 do
    self.tick = self.tick - self.interval
    guard = guard + 1
    self:step()
  end
end

---------------------------------------------------------------------- draw
local function cellRect(x, y)
  return OX + (x - 1) * CELL, OY + (y - 1) * CELL
end

function Game:draw()
  local c = self.c
  c:clear(colors.black)

  local border = self.dying > 0 and colors.red or colors.gray
  c:box(3, 3, 98, 50, border)
  if self.mode == "wrap" then
    -- dashed border reads as "open"
    for x = 3, 100, 6 do
      c:fill(x, 3, 3, 1, colors.black)
      c:fill(x, 52, 3, 1, colors.black)
    end
  end

  for k in pairs(self.walls) do
    local x = (k - 1) % COLS + 1
    local y = floor((k - 1) / COLS) + 1
    local px, py = cellRect(x, y)
    c:fill(px, py, CELL, CELL, colors.gray)
    c:fill(px, py, CELL, 1, colors.lightGray)
  end

  if self.food then
    local px, py = cellRect(self.food.x, self.food.y)
    c:fill(px, py, 3, 3, colors.red)
    c:set(px, py, colors.black)
    c:set(px + 2, py, colors.lime)
    c:set(px + 1, py + 1, colors.orange)
  end

  if self.bonus then
    local px, py = cellRect(self.bonus.x, self.bonus.y)
    local on = (self.bonus.life > 2) or (floor(self.bonus.life * 8) % 2 == 0)
    if on then
      c:fill(px, py, 3, 3, colors.yellow)
      c:set(px + 1, py + 1, colors.orange)
    end
  end

  local dyingBlink = self.dying > 0 and floor(self.dying * 12) % 2 == 0
  local i = self.tail
  while i <= self.head do
    local seg = self.body[i]
    local px, py = cellRect(seg.x, seg.y)
    local isHead = (i == self.head)
    local col
    if dyingBlink then
      col = colors.red
    elseif isHead then
      col = colors.white
    else
      col = ((self.head - i) % 6 < 3) and colors.lime or colors.green
    end
    c:fill(px, py, CELL, CELL, col)
    if isHead and not dyingBlink then
      local dx = self.dir[1]
      if dx ~= 0 then
        c:set(px + 1, py, colors.black)
        c:set(px + 1, py + 2, colors.black)
      else
        c:set(px, py + 1, colors.black)
        c:set(px + 2, py + 1, colors.black)
      end
    end
    i = i + 1
  end

  c:render()

  local hudBg = self.flash > 0 and colors.green or colors.gray
  gfx.fill(1, 1, gfx.W, 1, hudBg)
  gfx.text(2, 1, "SCORE", colors.lightGray, hudBg)
  gfx.text(8, 1, gfx.commas(self.score), colors.white, hudBg)
  gfx.center(1, "LEN " .. self:length(), colors.lime, hudBg)
  gfx.right(gfx.W - 1, 1, "LV " .. self.level, colors.yellow, hudBg)
end

function Game:summary()
  return {
    { "Length", self:length() },
    { "Apples", self.apples },
    { "Level", self.level },
  }
end

---------------------------------------------------------------------- cover
local function cover(c, t)
  c:clear(colors.black)
  for y = 3, c.h - 2, 5 do
    for x = 3, c.w - 2, 5 do c:set(x, y, colors.gray) end
  end

  -- an apple the head is always just about to reach
  local hp = t * 20
  local hx = 4 + (hp % (c.w + 30))
  local ax = hx + 14
  if ax <= c.w - 3 then
    c:fill(ax, 9, 3, 3, colors.red)
    c:set(ax + 2, 9, colors.lime)
  end

  for i = 20, 1, -1 do
    local p = hp - i * 3
    local x = 4 + (p % (c.w + 30))
    local y = 11 + math.sin(p * 0.10) * 6
    if x <= c.w - 2 then
      local col = (i % 6 < 3) and colors.lime or colors.green
      if i == 1 then col = colors.white end
      c:fill(x, floor(y), 3, 3, col)
      if i == 1 then
        c:set(x + 1, floor(y), colors.black)
        c:set(x + 1, floor(y) + 2, colors.black)
      end
    end
  end
end

----------------------------------------------------------------- definition
--- Attract-mode bot. Steers toward the food on whichever axis is free,
--- preferring a turn that does not immediately run into its own body. It is
--- not a solver -- it will eventually trap itself, which is fine, because a
--- demo that dies now and then looks like someone playing.
local function demo(self, frame)
  if self.finished or self.dying > 0 or not self.food then return end
  if frame % 2 ~= 0 then return end
  local h = self.body[self.head]
  if not h then return end

  local function blocked(dx, dy)
    local nx, ny = h.x + dx, h.y + dy
    if self.mode ~= "wrap" and (nx < 1 or nx > COLS or ny < 1 or ny > ROWS) then
      return true
    end
    for i = 1, #self.body do
      local seg = self.body[i]
      if seg and seg.x == nx and seg.y == ny then return true end
    end
    return false
  end

  local wants = {}
  if self.food.x < h.x then wants[#wants + 1] = { "left", -1, 0 }
  elseif self.food.x > h.x then wants[#wants + 1] = { "right", 1, 0 } end
  if self.food.y < h.y then wants[#wants + 1] = { "up", 0, -1 }
  elseif self.food.y > h.y then wants[#wants + 1] = { "down", 0, 1 } end
  -- anything at all, if the preferred ways are walled off
  wants[#wants + 1] = { "left", -1, 0 }
  wants[#wants + 1] = { "right", 1, 0 }
  wants[#wants + 1] = { "up", 0, -1 }
  wants[#wants + 1] = { "down", 0, 1 }

  for i = 1, #wants do
    local w = wants[i]
    if not blocked(w[2], w[3]) then
      self:turn(w[1])
      return
    end
  end
end

return {
  id = "snake",
  name = "Snake",
  tagline = "Eat. Grow. Mind the tail.",
  accent = colors.lime,
  order = 10,
  cover = cover,
  music = "serpentine",
  controls = {
    { "Arrows/WASD", "Turn" },
    { "Mouse", "Click to steer" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "classic", name = "Classic", hint = "walls kill" },
    { id = "wrap", name = "Wrap-around", hint = "no walls" },
    { id = "maze", name = "Maze", hint = "obstacles" },
  },
  trophies = {
    { id = "snake_25", name = "Snack Time", desc = "Eat 25 apples in one run",
      test = function(g) return g.apples >= 25 end },
    { id = "snake_50", name = "Orchard Raid", desc = "Eat 50 apples in one run",
      test = function(g) return g.apples >= 50 end },
    { id = "snake_long", name = "Long Boy", desc = "Grow to 40 segments",
      test = function(g) return g:length() >= 40 end },
  },
  demo = demo,
  new = new,
}
]=])
file("gameos/games/sokoban.lua", [=[
--[[ Sokoban -- one level per run, with unlimited undo.

  Levels use the standard notation: # wall, space floor, . goal, $ box,
  * box on goal, @ player, + player on goal. Every level here has been
  machine-checked for solvability and its `par` is the optimal push count.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")
local data = req("lib.data")

local floor, abs = math.floor, math.abs

local Game = {}
Game.__index = Game

-- Sprites in two sizes: fat cells (4x2 characters) for small levels, thin
-- cells (2x1) for the wide ones.
local ART = {
  big = {
    crate = gfx.makeGlyph({
      "########",
      "#......#",
      "#.####.#",
      "#.####.#",
      "#......#",
      "########",
    }),
    -- the ink is the face, not the figure, so the cell stays a solid block
    player = gfx.makeGlyph({
      "........",
      "..#..#..",
      "..#..#..",
      "........",
      "..####..",
      "........",
    }),
    goal = gfx.makeGlyph({
      "........",
      "..####..",
      "..#..#..",
      "..#..#..",
      "..####..",
      "........",
    }),
  },
  small = {
    crate = gfx.makeGlyph({
      "####",
      "#..#",
      "####",
    }),
    player = gfx.makeGlyph({
      "....",
      "#..#",
      ".##.",
    }),
    goal = gfx.makeGlyph({
      "....",
      ".##.",
      "....",
    }),
  },
}

local LEVELS = {
  { par = 2, rows = {
    "########",
    "#      #",
    "# $$   #",
    "# ..@  #",
    "#      #",
    "########",
  } },
  { par = 3, rows = {
    "#######",
    "#.    #",
    "#  $  #",
    "#   @ #",
    "#     #",
    "#######",
  } },
  { par = 6, rows = {
    "###########",
    "#         #",
    "# ##   ## #",
    "# #  $  # #",
    "# # $.$ # #",
    "# #  .  # #",
    "# ## . ## #",
    "#    @    #",
    "###########",
  } },
  { par = 8, rows = {
    "##########",
    "#        #",
    "#  ####  #",
    "#  #..#  #",
    "#  #  #  #",
    "# $    $ #",
    "#   @    #",
    "##########",
  } },
  { par = 8, rows = {
    "##########",
    "#        #",
    "#  $  $  #",
    "#   ..   #",
    "#   ..   #",
    "#  $  $  #",
    "#    @   #",
    "##########",
  } },
  { par = 9, rows = {
    "#########",
    "#       #",
    "# $ $ $ #",
    "#       #",
    "#  @    #",
    "# . . . #",
    "#########",
  } },
  { par = 10, rows = {
    "#############",
    "#           #",
    "# ######### #",
    "# #   @   # #",
    "# # $$$$$ # #",
    "# #       # #",
    "# ##.....## #",
    "#           #",
    "#############",
  } },
  { par = 12, rows = {
    "############",
    "#          #",
    "#   $$$$   #",
    "#  ##  ##  #",
    "#   ....   #",
    "#     @    #",
    "############",
  } },
  { par = 14, rows = {
    "###########",
    "#         #",
    "#  $   .  #",
    "#  $ # .  #",
    "#  $   .  #",
    "#    @    #",
    "###########",
  } },
  { par = 16, rows = {
    "##############",
    "#            #",
    "#   ......   #",
    "#  ##    ##  #",
    "#   $$$$$$   #",
    "#     @      #",
    "##############",
  } },
  { par = 18, rows = {
    "############",
    "#          #",
    "#   ....   #",
    "#   ####   #",
    "#  $ $ $ $ #",
    "#          #",
    "#    @     #",
    "############",
  } },
  { par = 24, rows = {
    "############",
    "#          #",
    "#..   $    #",
    "#..        #",
    "#     $    #",
    "#   $   $  #",
    "#     @    #",
    "############",
  } },
}

------------------------------------------------------------------ instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  local prog = data.progress("sokoban")
  if mode and mode.restart then
    prog.level = 1
    data.markDirty()
  end
  local index = (mode and mode.level) or prog.level or 1
  if index > #LEVELS then index = #LEVELS end
  if index < 1 then index = 1 end
  self.index = index
  self.def = LEVELS[index]
  self:load()
  self.score = 0
  self.finished = false
  self.won = false
  self.flash = 0
  return self
end

function Game:load()
  local rows = self.def.rows
  self.h = #rows
  self.w = 0
  for i = 1, self.h do
    if #rows[i] > self.w then self.w = #rows[i] end
  end
  self.walls = {}
  self.goals = {}
  self.boxes = {}
  self.goalCount = 0
  for y = 1, self.h do
    local line = rows[y]
    for x = 1, self.w do
      local ch = line:sub(x, x)
      local k = (y - 1) * self.w + x
      if ch == "#" then
        self.walls[k] = true
      elseif ch == "." or ch == "*" or ch == "+" then
        self.goals[k] = true
        self.goalCount = self.goalCount + 1
      end
      if ch == "$" or ch == "*" then self.boxes[k] = true end
      if ch == "@" or ch == "+" then self.px, self.py = x, y end
    end
  end
  self.moves = 0
  self.pushes = 0
  self.history = {}
  -- Small levels get fat cells so they fill the screen instead of huddling
  -- in the middle of it.
  self.cw = (self.w * 4 <= 50) and 4 or 2
  self.ch = (self.h * 2 <= 15) and 2 or 1
  self.ox = floor((gfx.W - self.w * self.cw) / 2) + 1
  self.oy = 3 + floor((15 - self.h * self.ch) / 2)
end

function Game:key(x, y) return (y - 1) * self.w + x end

function Game:solved()
  for k in pairs(self.goals) do
    if not self.boxes[k] then return false end
  end
  return true
end

function Game:onGoalCount()
  local n = 0
  for k in pairs(self.goals) do
    if self.boxes[k] then n = n + 1 end
  end
  return n
end

-------------------------------------------------------------------- moving
function Game:snapshot()
  local boxes = {}
  for k in pairs(self.boxes) do boxes[k] = true end
  self.history[#self.history + 1] = {
    px = self.px, py = self.py, boxes = boxes,
    moves = self.moves, pushes = self.pushes,
  }
  if #self.history > 400 then table.remove(self.history, 1) end
end

function Game:step(dx, dy)
  if self.finished then return end
  local nx, ny = self.px + dx, self.py + dy
  if nx < 1 or nx > self.w or ny < 1 or ny > self.h then return end
  local nk = self:key(nx, ny)
  if self.walls[nk] then
    audio.play("sok.blocked")
    return
  end

  if self.boxes[nk] then
    local bx, by = nx + dx, ny + dy
    if bx < 1 or bx > self.w or by < 1 or by > self.h then
      audio.play("sok.blocked")
      return
    end
    local bk = self:key(bx, by)
    if self.walls[bk] or self.boxes[bk] then
      audio.play("sok.blocked")
      return
    end
    self:snapshot()
    self.boxes[nk] = nil
    self.boxes[bk] = true
    self.pushes = self.pushes + 1
    audio.play(self.goals[bk] and "sok.ongoal" or "sok.push")
  else
    self:snapshot()
    audio.play("sok.step")
  end

  self.px, self.py = nx, ny
  self.moves = self.moves + 1

  if self:solved() then
    self.finished = true
    self.won = true
    self.flash = 1
    local par = self.def.par > 0 and self.def.par or self.pushes
    local efficiency = math.max(0, par * 2 - self.pushes) * 20
    self.score = 500 + self.index * 100 + efficiency
    local prog = data.progress("sokoban")
    local best = prog.best or {}
    if not best[self.index] or self.moves < best[self.index] then
      best[self.index] = self.moves
    end
    prog.best = best
    prog.level = math.min(#LEVELS, self.index + 1)
    if self.index >= #LEVELS then prog.completed = true end
    data.markDirty()
    audio.play("sok.solved")
  end
end

function Game:undo()
  local prev = table.remove(self.history)
  if not prev then
    audio.play("sok.blocked")
    return
  end
  self.px, self.py = prev.px, prev.py
  self.boxes = prev.boxes
  self.moves = prev.moves
  self.pushes = prev.pushes
  audio.play("sok.undo")
end

function Game:restart()
  self:load()
  audio.play("sok.reset")
end

--------------------------------------------------------------------- input
function Game:onKey(code, held)
  if code == keys.left or code == keys.a then
    self:step(-1, 0)
  elseif code == keys.right or code == keys.d then
    self:step(1, 0)
  elseif code == keys.up or code == keys.w then
    self:step(0, -1)
  elseif code == keys.down or code == keys.s then
    self:step(0, 1)
  elseif code == keys.u and not held then
    self:undo()
  elseif code == keys.r and not held then
    self:restart()
  end
  self.path = nil          -- any key press cancels a queued walk
end

--- Click a square to walk there. A neighbouring square is just a step, so
--- pushing still works by clicking the box you want to shove; anywhere else
--- is a shortest path through free squares, which is how every Sokoban with
--- a mouse has worked and saves a great deal of tapping.
function Game:walkTo(tx, ty)
  local startK = self:key(self.px, self.py)
  local goalK = self:key(tx, ty)
  if startK == goalK then return end
  if self.walls[goalK] or self.boxes[goalK] then return end

  local came, queue, head = { [startK] = false }, { { self.px, self.py } }, 1
  while head <= #queue do
    local node = queue[head]; head = head + 1
    local cx, cy = node[1], node[2]
    if cx == tx and cy == ty then break end
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      local nx, ny = cx + d[1], cy + d[2]
      if nx >= 1 and nx <= self.w and ny >= 1 and ny <= self.h then
        local k = self:key(nx, ny)
        if came[k] == nil and not self.walls[k] and not self.boxes[k] then
          came[k] = { cx, cy, d[1], d[2] }
          queue[#queue + 1] = { nx, ny }
        end
      end
    end
  end

  if came[goalK] == nil then return end            -- walled off
  local path, cx, cy = {}, tx, ty
  while true do
    local from = came[self:key(cx, cy)]
    if not from then break end
    table.insert(path, 1, { from[3], from[4] })
    cx, cy = from[1], from[2]
  end
  self.path = path
  self.pathAt = 0
end

function Game:onMouse(kind, btn, x, y)
  if self.finished or kind ~= "mouse_click" then return end
  local gx = floor((x - self.ox) / self.cw) + 1
  local gy = floor((y - self.oy) / self.ch) + 1
  if gx < 1 or gx > self.w or gy < 1 or gy > self.h then return end

  local dx, dy = gx - self.px, gy - self.py
  if (dx == 0 and abs(dy) == 1) or (dy == 0 and abs(dx) == 1) then
    self.path = nil
    self:step(dx, dy)
  else
    self:walkTo(gx, gy)
  end
end

function Game:update(dt)
  if self.flash > 0 then self.flash = self.flash - dt end

  -- drain a queued walk one square at a time, so it reads as walking rather
  -- than teleporting and each footstep still gets its sound
  if self.path then
    self.pathAt = self.pathAt + dt
    while self.path and self.pathAt > 0.055 do
      self.pathAt = self.pathAt - 0.055
      local move = table.remove(self.path, 1)
      if not move then
        self.path = nil
      else
        self:step(move[1], move[2])
        if #self.path == 0 then self.path = nil end
      end
    end
  end
end

---------------------------------------------------------------------- draw
function Game:draw()
  gfx.clear(colors.black)

  gfx.fill(1, 1, gfx.W, 1, colors.gray)
  gfx.text(2, 1, "LEVEL", colors.lightGray, colors.gray)
  gfx.text(8, 1, self.index .. "/" .. #LEVELS, colors.white, colors.gray)
  gfx.center(1, "MOVES " .. self.moves .. "   PUSH " .. self.pushes, colors.lightGray, colors.gray)
  gfx.right(gfx.W - 1, 1, self:onGoalCount() .. "/" .. self.goalCount, colors.lime, colors.gray)

  local cw, ch = self.cw, self.ch
  local art = (cw >= 4) and ART.big or ART.small
  for y = 1, self.h do
    local sy = self.oy + (y - 1) * ch
    for x = 1, self.w do
      local sx = self.ox + (x - 1) * cw
      local k = self:key(x, y)

      if self.walls[k] then
        gfx.fill(sx, sy, cw, ch, colors.lightGray)
        -- light only the exposed top of a wall run, not every wall cell
        if ch > 1 and not self.walls[self:key(x, y - 1)] then
          gfx.fill(sx, sy, cw, 1, colors.white)
        end
      elseif self.boxes[k] then
        local onGoal = self.goals[k]
        gfx.blitGlyph(sx, sy, art.crate,
          onGoal and colors.green or colors.brown,
          onGoal and colors.lime or colors.orange)
      elseif self.px == x and self.py == y then
        gfx.blitGlyph(sx, sy, art.player, colors.black,
          self.goals[k] and colors.lightBlue or colors.cyan)
      elseif self.goals[k] then
        gfx.blitGlyph(sx, sy, art.goal, colors.magenta, colors.gray)
      else
        gfx.fill(sx, sy, cw, ch, colors.black)
      end
    end
  end

  gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
  if self.won then
    gfx.center(19, "Solved in " .. self.moves .. " moves!", colors.lime, colors.black)
  else
    local par = self.def.par > 0 and ("   par " .. self.def.par .. " pushes") or ""
    gfx.center(19, "U undo   R restart" .. par, colors.lightGray, colors.black)
  end
end

function Game:summary()
  local prog = data.progress("sokoban")
  local best = (prog.best or {})[self.index]
  return {
    { "Level", self.index .. " of " .. #LEVELS },
    { "Moves", self.moves },
    { "Pushes", self.pushes .. (self.def.par > 0 and (" / " .. self.def.par) or "") },
    { "Your best", best and (best .. " moves") or "--" },
  }
end

------------------------------------------------------------------ configure
--- Asked by the runtime before a session starts, so the level picker never
--- runs inside new().
local function configure(api, mode)
  if not (mode and mode.select) then return mode end
  local prog = data.progress("sokoban")
  local best = prog.best or {}
  local items = {}
  for i, level in ipairs(LEVELS) do
    items[i] = {
      label = "Level " .. i,
      hint = best[i] and (best[i] .. " moves") or ("par " .. level.par),
    }
  end
  local pick = api.ui.picker({
    title = " Choose a level ",
    items = items,
    accent = colors.orange,
    default = math.min(#LEVELS, prog.level or 1),
    rows = 10,
    width = 30,
    footer = "hint shows your best, or par",
  })
  if pick == 0 then return false end
  return { id = "select", name = "Level " .. pick, level = pick }
end

---------------------------------------------------------------------- cover
local COVER = {
  "########",
  "#  .   #",
  "# $ #  #",
  "#  @   #",
  "########",
}

local function cover(c, t)
  c:clear(colors.black)
  local cell = 4
  local ox = floor((c.w - 8 * cell) / 2)
  local oy = floor((c.h - 5 * cell) / 2)
  local bob = (floor(t * 2) % 2)
  for y = 1, 5 do
    for x = 1, 8 do
      local ch = COVER[y]:sub(x, x)
      local px = ox + (x - 1) * cell
      local py = oy + (y - 1) * cell
      if ch == "#" then
        c:fill(px, py, cell, cell, colors.lightGray)
        c:fill(px, py, cell, 1, colors.white)
      elseif ch == "." then
        c:fill(px + 1, py + 1, cell - 2, cell - 2, colors.magenta)
      elseif ch == "$" then
        c:fill(px + bob, py, cell, cell, colors.orange)
        c:box(px + bob, py, cell, cell, colors.brown)
      elseif ch == "@" then
        c:fill(px + bob, py, cell, cell, colors.cyan)
        c:set(px + bob + 1, py + 1, colors.black)
        c:set(px + bob + 2, py + 1, colors.black)
      end
    end
  end
end

----------------------------------------------------------------- definition
return {
  id = "sokoban",
  name = "Sokoban",
  tagline = "Push every crate home",
  accent = colors.orange,
  order = 70,
  cover = cover,
  music = "quiet",
  scoreLabel = "BEST",
  controls = {
    { "Arrows / WASD", "Walk / push" },
    { "U", "Undo" },
    { "R", "Restart level" },
    { "Mouse", "Click a square to walk there" },
    { "P", "Pause menu" },
  },
  configure = configure,
  modes = {
    { id = "continue", name = "Continue", hint = "next level" },
    { id = "select", name = "Level select", hint = "pick one", select = true },
    { id = "restart", name = "Start over", hint = "level 1", restart = true },
  },
  trophies = {
    { id = "sok_par", name = "Efficient", desc = "Solve a level in par pushes",
      test = function(g) return g.won and g.def.par > 0 and g.pushes <= g.def.par end },
    { id = "sok_l7", name = "Warehouse Hand", desc = "Reach level 7",
      test = function(g) return g.index >= 7 end },
    { id = "sok_all", name = "All Packed Away", desc = "Finish all twelve levels",
      test = function() return data.progress("sokoban").completed == true end },
  },
  new = new,
}
]=])
file("gameos/games/tetris.lua", [=[
--[[ Tetris -- 10 wide, 18 visible rows plus 2 hidden spawn rows.

  Blocks are 4x3 canvas pixels, which is exactly two character cells wide and
  one tall, so the well renders pixel-perfect with no colour bleeding.

  Implements the modern ruleset: 7-bag randomiser, SRS rotation with the full
  wall-kick tables, hold, ghost piece, lock delay with move resets, soft/hard
  drop scoring, T-spins, back-to-back and combos.
]]

local req = ...
local gfx = req("lib.gfx")
local font = req("lib.font")
local audio = req("lib.audio")
local input = req("lib.input")

local floor = math.floor

local COLS = 10
local HIDDEN = 2
local VISIBLE = 18
local ROWS = HIDDEN + VISIBLE

local BW, BH = 4, 3
local WELL_X, WELL_Y = 33, 1

local Game = {}
Game.__index = Game

----------------------------------------------------------------- tetrominoes
-- Cells are {x, y} offsets inside the piece box, 0-based, for rotations
-- 0 (spawn), 1 (clockwise), 2 (180), 3 (counter-clockwise).
local SHAPES = {
  I = {
    { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 3, 1 } },
    { { 2, 0 }, { 2, 1 }, { 2, 2 }, { 2, 3 } },
    { { 0, 2 }, { 1, 2 }, { 2, 2 }, { 3, 2 } },
    { { 1, 0 }, { 1, 1 }, { 1, 2 }, { 1, 3 } },
  },
  O = {
    { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } },
    { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } },
    { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } },
    { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } },
  },
  T = {
    { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
    { { 1, 0 }, { 1, 1 }, { 2, 1 }, { 1, 2 } },
    { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 1, 2 } },
    { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, 2 } },
  },
  S = {
    { { 1, 0 }, { 2, 0 }, { 0, 1 }, { 1, 1 } },
    { { 1, 0 }, { 1, 1 }, { 2, 1 }, { 2, 2 } },
    { { 1, 1 }, { 2, 1 }, { 0, 2 }, { 1, 2 } },
    { { 0, 0 }, { 0, 1 }, { 1, 1 }, { 1, 2 } },
  },
  Z = {
    { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 2, 1 } },
    { { 2, 0 }, { 1, 1 }, { 2, 1 }, { 1, 2 } },
    { { 0, 1 }, { 1, 1 }, { 1, 2 }, { 2, 2 } },
    { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 0, 2 } },
  },
  J = {
    { { 0, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
    { { 1, 0 }, { 2, 0 }, { 1, 1 }, { 1, 2 } },
    { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 2, 2 } },
    { { 1, 0 }, { 1, 1 }, { 0, 2 }, { 1, 2 } },
  },
  L = {
    { { 2, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
    { { 1, 0 }, { 1, 1 }, { 1, 2 }, { 2, 2 } },
    { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 0, 2 } },
    { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 1, 2 } },
  },
}

local ORDER = { "I", "O", "T", "S", "Z", "J", "L" }
local SPAWN_X = { I = 4, O = 5, T = 4, S = 4, Z = 4, J = 4, L = 4 }

local TINT = {
  I = { colors.cyan, colors.lightBlue },
  O = { colors.yellow, colors.white },
  T = { colors.purple, colors.magenta },
  S = { colors.green, colors.lime },
  Z = { colors.red, colors.orange },
  J = { colors.blue, colors.lightBlue },
  L = { colors.orange, colors.yellow },
}

-- SRS wall kicks, converted to a y-down grid (positive dy moves down).
local KICKS = {
  ["0>1"] = { { 0, 0 }, { -1, 0 }, { -1, -1 }, { 0, 2 }, { -1, 2 } },
  ["1>0"] = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, -2 }, { 1, -2 } },
  ["1>2"] = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, -2 }, { 1, -2 } },
  ["2>1"] = { { 0, 0 }, { -1, 0 }, { -1, -1 }, { 0, 2 }, { -1, 2 } },
  ["2>3"] = { { 0, 0 }, { 1, 0 }, { 1, -1 }, { 0, 2 }, { 1, 2 } },
  ["3>2"] = { { 0, 0 }, { -1, 0 }, { -1, 1 }, { 0, -2 }, { -1, -2 } },
  ["3>0"] = { { 0, 0 }, { -1, 0 }, { -1, 1 }, { 0, -2 }, { -1, -2 } },
  ["0>3"] = { { 0, 0 }, { 1, 0 }, { 1, -1 }, { 0, 2 }, { 1, 2 } },
}

local KICKS_I = {
  ["0>1"] = { { 0, 0 }, { -2, 0 }, { 1, 0 }, { -2, 1 }, { 1, -2 } },
  ["1>0"] = { { 0, 0 }, { 2, 0 }, { -1, 0 }, { 2, -1 }, { -1, 2 } },
  ["1>2"] = { { 0, 0 }, { -1, 0 }, { 2, 0 }, { -1, -2 }, { 2, 1 } },
  ["2>1"] = { { 0, 0 }, { 1, 0 }, { -2, 0 }, { 1, 2 }, { -2, -1 } },
  ["2>3"] = { { 0, 0 }, { 2, 0 }, { -1, 0 }, { 2, -1 }, { -1, 2 } },
  ["3>2"] = { { 0, 0 }, { -2, 0 }, { 1, 0 }, { -2, 1 }, { 1, -2 } },
  ["3>0"] = { { 0, 0 }, { 1, 0 }, { -2, 0 }, { 1, 2 }, { -2, -1 } },
  ["0>3"] = { { 0, 0 }, { -1, 0 }, { 2, 0 }, { -1, -2 }, { 2, 1 } },
}

local GRAVITY = {
  0.800, 0.717, 0.633, 0.550, 0.467, 0.383, 0.283, 0.183, 0.133, 0.100,
  0.083, 0.083, 0.083, 0.067, 0.067, 0.067, 0.050, 0.050, 0.050, 0.033,
}

local LOCK_DELAY = 0.5
local MAX_RESETS = 15

------------------------------------------------------------------- instance
local function new(api, mode)
  local self = setmetatable({}, Game)
  self.api = api
  self.c = api.canvas.new(1, 1, gfx.W, gfx.H, colors.black)

  self.grid = {}
  for r = 1, ROWS do
    local row = {}
    for col = 1, COLS do row[col] = false end
    self.grid[r] = row
  end

  self.bag = {}
  self.queue = {}
  for _ = 1, 4 do self:pushQueue() end

  self.startLevel = (mode and mode.level) or 1
  self.level = self.startLevel
  self.score = 0
  self.lines = 0
  self.pieces = 0
  self.combo = -1
  self.backToBack = false
  self.hold = nil
  self.holdUsed = false
  self.finished = false
  self.clearRows = nil
  self.clearTimer = 0
  self.lastClear = nil
  self.tspins = 0
  self.tetrises = 0

  self.dasLeft = input.repeater(0.16, 0.04)
  self.dasRight = input.repeater(0.16, 0.04)
  self.softTimer = 0

  self:spawn()
  return self
end

------------------------------------------------------------------ 7-bag
function Game:pushQueue()
  if #self.bag == 0 then
    for i = 1, #ORDER do self.bag[i] = ORDER[i] end
    for i = #self.bag, 2, -1 do
      local j = math.random(1, i)
      self.bag[i], self.bag[j] = self.bag[j], self.bag[i]
    end
  end
  self.queue[#self.queue + 1] = table.remove(self.bag)
end

------------------------------------------------------------------ geometry
--- Compact score so it always fits the 29px side panel.
local function shortNumber(n)
  n = floor(n)
  if n < 100000 then return tostring(n) end
  return floor(n / 1000) .. "K"
end

--- The four {x, y} cell offsets of a piece in a given rotation.
function Game:shape(kind, rot)
  return SHAPES[kind][rot + 1]
end

function Game:fits(kind, rot, px, py)
  local shape = SHAPES[kind][rot + 1]
  for i = 1, 4 do
    local x = px + shape[i][1]
    local y = py + shape[i][2]
    if x < 1 or x > COLS or y > ROWS then return false end
    if y >= 1 and self.grid[y][x] then return false end
  end
  return true
end

function Game:spawn(kind)
  self.kind = kind or table.remove(self.queue, 1)
  if not kind then self:pushQueue() end
  self.rot = 0
  self.px = SPAWN_X[self.kind]
  self.py = 1
  self.gravity = 0
  self.lockTimer = 0
  self.lockResets = 0
  self.lowest = self.py
  self.lastMoveWasRotation = false
  self.pieces = self.pieces + 1

  if not self:fits(self.kind, 0, self.px, self.py) then
    -- try nudging up into the hidden rows before declaring topout
    if self:fits(self.kind, 0, self.px, self.py - 1) then
      self.py = self.py - 1
    else
      self.finished = true
      audio.play("tet.topout")
    end
  end
end

------------------------------------------------------------------- actions
function Game:tryMove(dx, dy)
  if self.finished or self.clearRows then return false end
  if self:fits(self.kind, self.rot, self.px + dx, self.py + dy) then
    self.px = self.px + dx
    self.py = self.py + dy
    self.lastMoveWasRotation = false
    if self.py > self.lowest then
      self.lowest = self.py
      self.lockResets = 0
      self.lockTimer = 0
    elseif dx ~= 0 and self:grounded() and self.lockResets < MAX_RESETS then
      self.lockResets = self.lockResets + 1
      self.lockTimer = 0
    end
    return true
  end
  return false
end

function Game:rotate(dir)
  if self.finished or self.clearRows then return false end
  local from = self.rot
  local to = (from + dir) % 4
  if self.kind == "O" then
    self.rot = to
    return true
  end
  local table_ = (self.kind == "I") and KICKS_I or KICKS
  local kicks = table_[from .. ">" .. to]
  if not kicks then return false end
  for i = 1, #kicks do
    local dx, dy = kicks[i][1], kicks[i][2]
    if self:fits(self.kind, to, self.px + dx, self.py + dy) then
      self.rot = to
      self.px = self.px + dx
      self.py = self.py + dy
      self.lastMoveWasRotation = true
      self.lastKick = i
      if self.py > self.lowest then
        self.lowest = self.py
        self.lockResets = 0
        self.lockTimer = 0
      elseif self:grounded() and self.lockResets < MAX_RESETS then
        self.lockResets = self.lockResets + 1
        self.lockTimer = 0
      end
      audio.play(i > 1 and "tet.wallkick" or "tet.rotate")
      return true
    end
  end
  audio.play("tet.deny")
  return false
end

function Game:grounded()
  return not self:fits(self.kind, self.rot, self.px, self.py + 1)
end

function Game:ghostY()
  local y = self.py
  while self:fits(self.kind, self.rot, self.px, y + 1) do y = y + 1 end
  return y
end

function Game:swapHold()
  if self.holdUsed or self.finished or self.clearRows then
    audio.play("tet.deny")
    return
  end
  local previous = self.hold
  self.hold = self.kind
  self.holdUsed = true
  if previous then
    self:spawn(previous)
  else
    self:spawn()
  end
  audio.play("tet.hold")
end

function Game:hardDrop()
  if self.finished or self.clearRows then return end
  local target = self:ghostY()
  local dist = target - self.py
  self.py = target
  self.score = self.score + dist * 2
  self.lastMoveWasRotation = false
  audio.play("tet.harddrop")
  self:lock()
end

--------------------------------------------------------------------- t-spin
local CORNERS = { { 0, 0 }, { 2, 0 }, { 0, 2 }, { 2, 2 } }

function Game:detectTSpin()
  if self.kind ~= "T" or not self.lastMoveWasRotation then return false, false end
  local filled = 0
  for i = 1, 4 do
    local x = self.px + CORNERS[i][1]
    local y = self.py + CORNERS[i][2]
    if x < 1 or x > COLS or y > ROWS then
      filled = filled + 1
    elseif y >= 1 and self.grid[y][x] then
      filled = filled + 1
    end
  end
  if filled < 3 then return false, false end
  -- the two corners in front of the T face depend on its rotation
  local FRONT = {
    [0] = { { 0, 0 }, { 2, 0 } },
    [1] = { { 2, 0 }, { 2, 2 } },
    [2] = { { 0, 2 }, { 2, 2 } },
    [3] = { { 0, 0 }, { 0, 2 } },
  }
  local front = 0
  for _, off in ipairs(FRONT[self.rot]) do
    local x, y = self.px + off[1], self.py + off[2]
    if x < 1 or x > COLS or y > ROWS then
      front = front + 1
    elseif y >= 1 and self.grid[y][x] then
      front = front + 1
    end
  end
  local mini = (front < 2) and (self.lastKick ~= 5)
  return true, mini
end

---------------------------------------------------------------------- lock
function Game:lock()
  local tspin, mini = self:detectTSpin()
  local shape = SHAPES[self.kind][self.rot + 1]
  local topOut = true
  for i = 1, 4 do
    local x = self.px + shape[i][1]
    local y = self.py + shape[i][2]
    if y >= 1 and y <= ROWS and x >= 1 and x <= COLS then
      self.grid[y][x] = self.kind
      if y > HIDDEN then topOut = false end
    end
  end

  local full = {}
  for y = 1, ROWS do
    local complete = true
    for x = 1, COLS do
      if not self.grid[y][x] then complete = false break end
    end
    if complete then full[#full + 1] = y end
  end

  local n = #full
  local gained = 0
  local label = nil

  if tspin then
    self.tspins = self.tspins + 1
    if mini then
      gained = (n == 0 and 100) or (n == 1 and 200) or 400
      label = n > 0 and "T-SPIN MINI" or "T-SPIN"
    else
      gained = (n == 0 and 400) or (n == 1 and 800) or (n == 2 and 1200) or 1600
      label = "T-SPIN"
    end
  elseif n > 0 then
    gained = ({ 100, 300, 500, 800 })[n]
    if n == 4 then
      label = "TETRIS"
      self.tetrises = self.tetrises + 1
    end
  end

  local difficult = (n == 4) or (tspin and n > 0)
  if difficult and self.backToBack and gained > 0 then
    gained = floor(gained * 1.5)
    if label then label = "B2B " .. label end
  end
  if n > 0 or tspin then
    self.backToBack = difficult
  end

  if n > 0 then
    self.combo = self.combo + 1
    if self.combo > 0 then gained = gained + 50 * self.combo end
  else
    self.combo = -1
  end

  self.score = self.score + gained * self.level

  if n > 0 then
    self.clearRows = full
    self.clearTimer = 0.24
    self.lastClear = label or (n .. (n == 1 and " LINE" or " LINES"))
    -- the clear fanfare grows with the number of rows
    local voice = "tet.line" .. n
    if tspin then voice = "tet.tspin" elseif n >= 4 then voice = "tet.tetris" end
    audio.play(voice)
    if difficult and self.backToBack then audio.play("tet.b2b") end
  else
    audio.play("tet.lock")
    if topOut then
      self.finished = true
      audio.play("tet.topout")
      return
    end
    self.holdUsed = false
    self:spawn()
  end
end

function Game:collapse()
  local rows = self.clearRows
  self.clearRows = nil
  for i = #rows, 1, -1 do
    table.remove(self.grid, rows[i])
  end
  for _ = 1, #rows do
    local row = {}
    for x = 1, COLS do row[x] = false end
    table.insert(self.grid, 1, row)
  end

  self.lines = self.lines + #rows
  local newLevel = self.startLevel + floor(self.lines / 10)
  if newLevel > self.level then
    self.level = newLevel
    audio.play("result.levelup")
  end
  self.holdUsed = false
  self:spawn()
end

-------------------------------------------------------------------- update
function Game:gravityInterval()
  local i = self.level
  if i < 1 then i = 1 end
  if i > #GRAVITY then
    return math.max(0.017, 0.033 - (i - #GRAVITY) * 0.002)
  end
  return GRAVITY[i]
end

function Game:onKey(code, held)
  if held then return end
  if code == keys.up or code == keys.x or code == keys.w then
    self:rotate(1)
  elseif code == keys.z then
    self:rotate(-1)
  elseif code == keys.space then
    self:hardDrop()
  elseif code == keys.c or code == keys.leftShift or code == keys.rightShift then
    self:swapHold()
  end
end

--- Where the piece's cells actually sit, which is what the pointer should
--- line up with -- the bounding-box origin is off-centre for most shapes.
function Game:pieceSpan()
  local shape = SHAPES[self.kind][self.rot + 1]
  local lo, hi = 99, -99
  for i = 1, 4 do
    local x = self.px + shape[i][1]
    if x < lo then lo = x end
    if x > hi then hi = x end
  end
  return lo, hi
end

--- Mouse play: click a column in the well to slide the piece there, scroll to
--- rotate, and click below the well to hard drop. The slide is a target
--- rather than a teleport so the piece still has to travel past obstacles.
function Game:onMouse(kind, btn, x, y)
  if self.finished or self.clearRows or not self.kind then return end
  local px = (x - 1) * 2 + 1
  local py = (y - 1) * 3 + 1

  if kind == "mouse_scroll" then
    self:rotate(btn > 0 and 1 or -1)
    return
  end
  if kind ~= "mouse_click" and kind ~= "mouse_drag" then return end

  if btn == 2 then
    self:swapHold()
    return
  end
  -- below the floor of the well: drop it
  if kind == "mouse_click" and py >= WELL_Y + VISIBLE * BH then
    self:hardDrop()
    return
  end

  local col = floor((px - WELL_X) / BW) + 1
  if col < 1 then col = 1 elseif col > COLS then col = COLS end
  local lo, hi = self:pieceSpan()
  self.mouseCol = col - floor((hi - lo) / 2)
end

function Game:update(dt)
  if self.finished then return end

  if self.clearRows then
    self.clearTimer = self.clearTimer - dt
    if self.clearTimer <= 0 then self:collapse() end
    return
  end

  -- walk toward a clicked column, one cell per gravity-independent tick, and
  -- give up the moment the piece cannot get any closer (a wall or a stack)
  if self.mouseCol then
    self.mouseTimer = (self.mouseTimer or 0) + dt
    while self.mouseTimer > 0.03 do
      self.mouseTimer = self.mouseTimer - 0.03
      local lo = self:pieceSpan()
      local d = self.mouseCol - lo
      if d == 0 then
        self.mouseCol = nil
        break
      end
      if not self:tryMove(d > 0 and 1 or -1, 0) then
        self.mouseCol = nil
        break
      end
      audio.play("tet.move")
    end
  end
  if input.down(keys.left, keys.a) or input.down(keys.right, keys.d) then
    self.mouseCol = nil
  end

  local steps = self.dasLeft:update(input.down(keys.left, keys.a), dt)
  for _ = 1, steps do
    if self:tryMove(-1, 0) then audio.play("tet.move") end
  end
  steps = self.dasRight:update(input.down(keys.right, keys.d), dt)
  for _ = 1, steps do
    if self:tryMove(1, 0) then audio.play("tet.move") end
  end

  local soft = input.down(keys.down, keys.s)
  local interval = self:gravityInterval()
  if soft then
    local fast = 0.033
    if fast < interval then interval = fast end
  end

  self.gravity = self.gravity + dt
  local guard = 0
  while self.gravity >= interval and guard < 24 do
    self.gravity = self.gravity - interval
    guard = guard + 1
    if self:tryMove(0, 1) then
      if soft then self.score = self.score + 1 end
    else
      break
    end
  end

  if self:grounded() then
    self.lockTimer = self.lockTimer + dt
    if self.lockTimer >= LOCK_DELAY then
      self:lock()
    end
  else
    self.lockTimer = 0
  end
end

---------------------------------------------------------------------- draw
local function drawBlock(c, px, py, kind, style)
  local tint = TINT[kind]
  if style == "ghost" then
    c:fill(px, py, BW, BH, tint[1])
    c:fill(px + 1, py + 1, BW - 2, 1, colors.black)
  elseif style == "flash" then
    c:fill(px, py, BW, BH, colors.white)
  else
    c:fill(px, py, BW, BH, tint[1])
    c:fill(px, py, BW, 1, tint[2])
  end
end

local function wellPos(col, row)
  return WELL_X + (col - 1) * BW, WELL_Y + (row - HIDDEN - 1) * BH
end

--- Draw a piece into a preview box, centred.
local function drawPreview(c, kind, boxX, boxY, boxW, boxH)
  local shape = SHAPES[kind][1]
  local minX, maxX, minY, maxY = 9, -9, 9, -9
  for i = 1, 4 do
    local x, y = shape[i][1], shape[i][2]
    if x < minX then minX = x end
    if x > maxX then maxX = x end
    if y < minY then minY = y end
    if y > maxY then maxY = y end
  end
  local w = (maxX - minX + 1) * BW
  local h = (maxY - minY + 1) * BH
  local ox = boxX + floor((boxW - w) / 2)
  local oy = boxY + floor((boxH - h) / 2)
  for i = 1, 4 do
    drawBlock(c, ox + (shape[i][1] - minX) * BW, oy + (shape[i][2] - minY) * BH, kind)
  end
end

function Game:draw()
  local c = self.c
  c:clear(colors.black)

  -- well chrome
  c:fill(WELL_X - 2, WELL_Y, 2, VISIBLE * BH + 3, colors.gray)
  c:fill(WELL_X + COLS * BW, WELL_Y, 2, VISIBLE * BH + 3, colors.gray)
  c:fill(WELL_X - 2, WELL_Y + VISIBLE * BH, COLS * BW + 4, 3, colors.gray)

  -- settled blocks
  local flashing = nil
  if self.clearRows then
    flashing = {}
    for _, r in ipairs(self.clearRows) do flashing[r] = true end
  end
  for r = HIDDEN + 1, ROWS do
    local row = self.grid[r]
    for col = 1, COLS do
      local kind = row[col]
      if kind then
        local px, py = wellPos(col, r)
        drawBlock(c, px, py, kind, flashing and flashing[r] and "flash" or nil)
      end
    end
  end

  if not self.clearRows and not self.finished then
    -- ghost
    local gy = self:ghostY()
    local shape = SHAPES[self.kind][self.rot + 1]
    if gy ~= self.py then
      for i = 1, 4 do
        local x = self.px + shape[i][1]
        local y = gy + shape[i][2]
        if y > HIDDEN then
          local px, py = wellPos(x, y)
          drawBlock(c, px, py, self.kind, "ghost")
        end
      end
    end
    -- active piece
    for i = 1, 4 do
      local x = self.px + shape[i][1]
      local y = self.py + shape[i][2]
      if y > HIDDEN then
        local px, py = wellPos(x, y)
        drawBlock(c, px, py, self.kind)
      end
    end
  end

  -- Panel text sits on the 3-pixel character grid (y = 3k+1) with six
  -- pixels between baselines, so no two lines share a character cell.
  -- left panel
  font.draw(c, 2, 1, "HOLD", colors.lightGray, 1, 1)
  c:box(2, 7, 27, 11, self.holdUsed and colors.gray or colors.lightGray)
  if self.hold then
    drawPreview(c, self.hold, 3, 8, 25, 9)
  end
  font.draw(c, 2, 22, "SCORE", colors.lightGray, 1, 1)
  font.draw(c, 2, 28, shortNumber(self.score), colors.white, 1, 1)
  font.draw(c, 2, 37, "LEVEL", colors.lightGray, 1, 1)
  font.draw(c, 2, 43, tostring(self.level), colors.yellow, 1, 1)
  -- progress towards the next level
  local into = self.lines % 10
  c:box(2, 52, 27, 5, colors.gray)
  if into > 0 then c:fill(3, 53, floor(into * 25 / 10), 3, colors.lime) end

  -- right panel
  font.draw(c, 76, 1, "NEXT", colors.lightGray, 1, 1)
  for i = 1, 3 do
    local kind = self.queue[i]
    local boxY = 7 + (i - 1) * 12
    c:box(75, boxY, 27, 11, colors.gray)
    if kind then drawPreview(c, kind, 76, boxY + 1, 25, 9) end
  end
  font.draw(c, 76, 43, "LINES", colors.lightGray, 1, 1)
  font.draw(c, 76, 49, tostring(self.lines), colors.lime, 1, 1)

  -- clear banner
  if self.lastClear and self.clearRows then
    local text = self.lastClear
    local w = font.width(text, 1, 1)
    local bx = WELL_X + floor((COLS * BW - w) / 2)
    c:fill(bx - 3, 24, w + 6, 9, colors.black)
    font.draw(c, bx, 26, text, colors.yellow, 1, 1)
  end

  c:render()
end

function Game:summary()
  return {
    { "Lines", self.lines },
    { "Level", self.level },
    { "Tetrises", self.tetrises },
    { "T-spins", self.tspins },
  }
end

---------------------------------------------------------------------- cover
local COVER_ORDER = { "T", "L", "S", "I", "Z", "J", "O" }

local function cover(c, t)
  c:clear(colors.black)
  c:fill(1, 1, c.w, c.h, colors.black)
  for i = 1, 7 do
    local kind = COVER_ORDER[i]
    local speed = 9 + i * 1.7
    local y = ((t * speed + i * 9) % (c.h + 14)) - 12
    local x = 2 + (i - 1) * 8
    local shape = SHAPES[kind][((floor(t * 0.9) + i) % 4) + 1]
    for j = 1, 4 do
      local bx = x + shape[j][1] * 3
      local by = floor(y) + shape[j][2] * 3
      c:fill(bx, by, 3, 3, TINT[kind][1])
      c:fill(bx, by, 3, 1, TINT[kind][2])
    end
  end
  c:fill(1, c.h - 1, c.w, 2, colors.gray)
end

----------------------------------------------------------------- definition
return {
  id = "tetris",
  name = "Tetris",
  tagline = "Stack, clear, survive",
  accent = colors.cyan,
  order = 20,
  cover = cover,
  music = "cascade",
  controls = {
    { "Left / Right", "Move" },
    { "Down", "Soft drop" },
    { "Up or X", "Rotate right" },
    { "Z", "Rotate left" },
    { "Space", "Hard drop" },
    { "C or Shift", "Hold piece" },
    { "Mouse", "Click a column, scroll to spin" },
    { "Click below well", "Hard drop" },
    { "P", "Pause menu" },
  },
  modes = {
    { id = "l1", name = "Level 1", hint = "marathon", level = 1 },
    { id = "l5", name = "Level 5", hint = "brisk", level = 5 },
    { id = "l10", name = "Level 10", hint = "fast", level = 10 },
    { id = "l15", name = "Level 15", hint = "brutal", level = 15 },
  },
  trophies = {
    { id = "tetris_four", name = "Four At Once", desc = "Clear four rows at once",
      test = function(g) return g.tetrises >= 1 end },
    { id = "tetris_spin", name = "Spin Doctor", desc = "Land a T-spin",
      test = function(g) return g.tspins >= 1 end },
    { id = "tetris_l10", name = "Speed Freak", desc = "Reach level 10",
      test = function(g) return g.level >= 10 end },
    { id = "tetris_100", name = "Century Stack", desc = "Clear 100 lines in one game",
      test = function(g) return g.lines >= 100 end },
  },
  new = new,
}
]=])
file("gameos/lib/audio.lua", [=[
--[[ audio -- the console's sound engine.

  A ComputerCraft speaker can play at most eight notes per tick, so this is
  built as a budgeted mixer rather than a pile of playNote calls:

    * effects are scheduled ahead of time and cost no frame time when they
      fire, so a nine-note explosion is as cheap as a click;
    * music runs a small tracker (patterns, an order list, real tempo in
      seconds) and is the first thing dropped when the tick budget is tight,
      so gameplay feedback is never masked by the soundtrack;
    * three independent volumes -- master, music, effects -- scale into the
      speaker's 0..3 range.

  With no speaker attached every call is a silent no-op.
]]

local req = ...

local audio = {}

local floor = math.floor
local min, max = math.min, math.max

-- a speaker accepts eight notes per tick; leave one spare for a late effect
local NOTES_PER_TICK = 8
local RESERVED_FOR_SFX = 3

audio.speaker = nil
audio.volumes = { master = 0.7, music = 0.6, sfx = 1.0 }

local pending = {}
local music = nil
local now = 0
local budget = NOTES_PER_TICK

--------------------------------------------------------------------- notes
-- CC pitch 0..24 spans F#3 to F#5. Instruments are voiced at different
-- octaves, so "bass" at pitch 0 sounds far below "bell" at pitch 0.
local NAMES = { "FS", "G", "GS", "A", "AS", "B", "C", "CS", "D", "DS", "E", "F" }
local NOTE = {}
do
  local octave = 3
  for i = 0, 24 do
    local name = NAMES[(i % 12) + 1]
    if name == "C" and i > 0 then octave = octave + 1 end
    NOTE[name .. octave] = i
  end
end
audio.NOTE = NOTE
audio.badNotes = {}

--- Accept a pitch as a number or a note name.
function audio.pitch(value)
  if type(value) == "number" then return value end
  local p = NOTE[value]
  if not p then
    audio.badNotes[#audio.badNotes + 1] = tostring(value)
    return 12
  end
  return p
end

local VALID_INSTRUMENTS = {
  harp = true, basedrum = true, snare = true, hat = true, bass = true,
  flute = true, bell = true, guitar = true, chime = true, xylophone = true,
  iron_xylophone = true, cow_bell = true, didgeridoo = true, bit = true,
  banjo = true, pling = true,
}
audio.instruments = VALID_INSTRUMENTS

------------------------------------------------------------------- lifecycle
function audio.init()
  local ok, found = pcall(peripheral.find, "speaker")
  audio.speaker = (ok and found) or nil
  audio.sfx = req("lib.sfx")
  audio.songs = req("lib.music")
  return audio.speaker ~= nil
end

function audio.setVolume(kind, value)
  audio.volumes[kind] = max(0, min(1, value))
end

--- True when anything would actually be audible.
function audio.audible(kind)
  if not audio.speaker then return false end
  return audio.volumes.master > 0 and audio.volumes[kind] > 0
end

---------------------------------------------------------------------- mixer
--- Push one note at the speaker, respecting the per-tick budget.
local function emit(instrument, pitch, volume, kind)
  local sp = audio.speaker
  if not sp then return false end
  if budget <= 0 then return false end
  -- music yields the last few notes of the tick to effects
  if kind == "music" and budget <= RESERVED_FOR_SFX then return false end

  local level = volume * audio.volumes[kind] * audio.volumes.master * 3
  if level <= 0.02 then return false end
  if level > 3 then level = 3 end

  local p = floor(pitch + 0.5)
  if p < 0 then p = 0 elseif p > 24 then p = 24 end

  budget = budget - 1
  pcall(sp.playNote, instrument, level, p)
  return true
end
audio.emit = emit

--------------------------------------------------------------------- effects
--- Play a named effect. `opts` may be a semitone shift, or a table with
--- `shift` and `vol` (a multiplier on the effect's own levels).
function audio.play(name, opts)
  if not audio.audible("sfx") then return end
  local def = audio.sfx and audio.sfx.get(name)
  if not def then return end

  local shift, scale = 0, 1
  if type(opts) == "number" then
    shift = opts
  elseif type(opts) == "table" then
    shift = opts.shift or 0
    scale = opts.vol or 1
  end

  if #pending > 96 then return end
  for i = 1, #def do
    local event = def[i]
    if event[1] <= 0 then
      emit(event[2], event[3] + shift, event[4] * scale, "sfx")
    else
      pending[#pending + 1] = {
        t = now + event[1],
        inst = event[2],
        pitch = event[3] + shift,
        vol = event[4] * scale,
      }
    end
  end
end

--- One note, right now. Used where a game owns the pitch (Simon's panels).
function audio.note(instrument, pitch, volume)
  if not audio.audible("sfx") then return end
  emit(instrument, audio.pitch(pitch), volume or 0.5, "sfx")
end

function audio.stopEffects()
  for i = #pending, 1, -1 do pending[i] = nil end
end

----------------------------------------------------------------------- music
--- Start a song by name. Restarting the song that is already playing is a
--- no-op, so screens can call this freely.
function audio.playMusic(name)
  if not name then return audio.stopMusic() end
  if music and music.name == name then return end
  local song = audio.songs and audio.songs.get(name)
  if not song then
    music = nil
    return
  end
  music = {
    name = name,
    song = song,
    orderIndex = 1,
    row = 0,
    acc = 0,
    rowTime = song.tempo * 0.05,
  }
end

function audio.stopMusic()
  music = nil
end

function audio.musicName()
  return music and music.name or nil
end

function audio.stopAll()
  audio.stopEffects()
  audio.stopMusic()
end

--- Play one row of the current pattern.
local function playRow()
  local song = music.song
  local patternName = song.order[music.orderIndex]
  local pattern = song.patterns[patternName]
  if not pattern then return end

  for i = 1, #pattern do
    local track = pattern[i]
    local note = track.rows[music.row]
    if note then
      emit(track.inst, note.pitch, note.vol * track.vol, "music")
    end
  end

  music.row = music.row + 1
  if music.row > song.rows then
    music.row = 1
    music.orderIndex = music.orderIndex + 1
    if music.orderIndex > #song.order then
      music.orderIndex = song.loop or 1
    end
  end
end

--------------------------------------------------------------------- update
--- Called once per frame with the current clock reading.
function audio.update(clock)
  local dt = clock - now
  if dt < 0 or dt > 1 then dt = 0.05 end
  now = clock
  budget = NOTES_PER_TICK

  if not audio.speaker then
    if #pending > 0 then audio.stopEffects() end
    return
  end

  -- effects first: they are feedback, music is decoration
  local i = 1
  while i <= #pending do
    local event = pending[i]
    if event.t <= now then
      emit(event.inst, event.pitch, event.vol, "sfx")
      table.remove(pending, i)
    else
      i = i + 1
    end
  end

  if music and audio.audible("music") then
    if music.row == 0 then music.row = 1 end
    music.acc = music.acc + dt
    local guard = 0
    while music.acc >= music.rowTime and guard < 4 do
      music.acc = music.acc - music.rowTime
      guard = guard + 1
      playRow()
    end
    if music.acc > music.rowTime * 4 then music.acc = 0 end
  end
end

return audio
]=])
file("gameos/lib/canvas.lua", [=[
--[[ canvas -- a square-pixel framebuffer on top of the terminal.

  Each character cell holds a 2x3 grid of sub-pixels, so a full 51x19 screen
  becomes 102x57 pixels that are square on screen (3x3 real pixels each).

  A cell can only carry two colours, so on render each cell picks its two most
  common sub-pixel colours; anything else in that cell is folded into the
  foreground. Blocky game art stays exact, gradients degrade gracefully.
]]

local Canvas = {}
Canvas.__index = Canvas

local floor = math.floor
local schar = string.char
local concat = table.concat

local BLIT = {}
do
  local hex = "0123456789abcdef"
  local c = 1
  for i = 1, 16 do BLIT[c] = hex:sub(i, i) c = c * 2 end
end

--- Create a canvas occupying a character rectangle of the 51x19 screen.
function Canvas.new(cx, cy, cw, ch, clearColour)
  local self = setmetatable({}, Canvas)
  self.cx, self.cy = cx, cy
  self.cw, self.ch = cw, ch
  self.w, self.h = cw * 2, ch * 3
  self.bg = clearColour or colors.black
  self.px = {}
  local px = self.px
  for i = 1, self.w * self.h do px[i] = self.bg end
  self._c, self._f, self._b, self._t = {}, {}, {}, {}
  return self
end

function Canvas:clear(col)
  col = col or self.bg
  local px = self.px
  for i = 1, self.w * self.h do px[i] = col end
end

function Canvas:set(x, y, col)
  x, y = floor(x), floor(y)
  if x < 1 or y < 1 or x > self.w or y > self.h then return end
  self.px[(y - 1) * self.w + x] = col
end

function Canvas:get(x, y)
  x, y = floor(x), floor(y)
  if x < 1 or y < 1 or x > self.w or y > self.h then return nil end
  return self.px[(y - 1) * self.w + x]
end

--- Filled rectangle: top-left (x,y), size w*h, clipped to the canvas.
function Canvas:fill(x, y, w, h, col)
  x, y, w, h = floor(x), floor(y), floor(w), floor(h)
  if w <= 0 or h <= 0 then return end
  local x2, y2 = x + w - 1, y + h - 1
  if x < 1 then x = 1 end
  if y < 1 then y = 1 end
  if x2 > self.w then x2 = self.w end
  if y2 > self.h then y2 = self.h end
  if x > x2 or y > y2 then return end
  local px, W = self.px, self.w
  for yy = y, y2 do
    local base = (yy - 1) * W
    for xx = x, x2 do px[base + xx] = col end
  end
end

function Canvas:box(x, y, w, h, col)
  if w <= 0 or h <= 0 then return end
  self:fill(x, y, w, 1, col)
  self:fill(x, y + h - 1, w, 1, col)
  self:fill(x, y, 1, h, col)
  self:fill(x + w - 1, y, 1, h, col)
end

function Canvas:hline(x, y, w, col) self:fill(x, y, w, 1, col) end
function Canvas:vline(x, y, h, col) self:fill(x, y, 1, h, col) end

function Canvas:line(x0, y0, x1, y1, col)
  x0, y0, x1, y1 = floor(x0), floor(y0), floor(x1), floor(y1)
  local dx = math.abs(x1 - x0)
  local dy = -math.abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx + dy
  local guard = dx - dy + 4
  while guard > 0 do
    guard = guard - 1
    self:set(x0, y0, col)
    if x0 == x1 and y0 == y1 then return end
    local e2 = err + err
    if e2 >= dy then err = err + dy x0 = x0 + sx end
    if e2 <= dx then err = err + dx y0 = y0 + sy end
  end
end

function Canvas:circle(cx, cy, r, col, filled)
  cx, cy, r = floor(cx), floor(cy), floor(r)
  if r < 0 then return end
  local x, y, d = r, 0, 1 - r
  while x >= y do
    if filled then
      self:fill(cx - x, cy + y, x + x + 1, 1, col)
      self:fill(cx - x, cy - y, x + x + 1, 1, col)
      self:fill(cx - y, cy + x, y + y + 1, 1, col)
      self:fill(cx - y, cy - x, y + y + 1, 1, col)
    else
      self:set(cx + x, cy + y, col) self:set(cx - x, cy + y, col)
      self:set(cx + x, cy - y, col) self:set(cx - x, cy - y, col)
      self:set(cx + y, cy + x, col) self:set(cx - y, cy + x, col)
      self:set(cx + y, cy - x, col) self:set(cx - y, cy - x, col)
    end
    y = y + 1
    if d < 0 then
      d = d + 2 * y + 1
    else
      x = x - 1
      d = d + 2 * (y - x) + 1
    end
  end
end

------------------------------------------------------------------- sprites
--- Build a sprite from rows of characters. Characters absent from `map`
--- (or mapped to false) are transparent.
function Canvas.sprite(rows, map)
  local h = #rows
  local w = 0
  for i = 1, h do if #rows[i] > w then w = #rows[i] end end
  local s = { w = w, h = h, px = {} }
  for y = 1, h do
    local row = rows[y]
    for x = 1, w do
      local ch = row:sub(x, x)
      local v = map[ch]
      s.px[(y - 1) * w + x] = v or false
    end
  end
  return s
end

function Canvas:draw(x, y, spr, flipH, flipV)
  x, y = floor(x), floor(y)
  local w, h, sp = spr.w, spr.h, spr.px
  for sy = 1, h do
    local ry = flipV and (h - sy + 1) or sy
    local base = (ry - 1) * w
    local py = y + sy - 1
    if py >= 1 and py <= self.h then
      local rowBase = (py - 1) * self.w
      for sx = 1, w do
        local rx = flipH and (w - sx + 1) or sx
        local col = sp[base + rx]
        if col then
          local pxx = x + sx - 1
          if pxx >= 1 and pxx <= self.w then self.px[rowBase + pxx] = col end
        end
      end
    end
  end
end

--- Draw a sprite scaled up by an integer factor.
function Canvas:drawScaled(x, y, spr, scale)
  if scale == 1 then return self:draw(x, y, spr) end
  local w, h, sp = spr.w, spr.h, spr.px
  for sy = 1, h do
    local base = (sy - 1) * w
    for sx = 1, w do
      local col = sp[base + sx]
      if col then
        self:fill(x + (sx - 1) * scale, y + (sy - 1) * scale, scale, scale, col)
      end
    end
  end
end

-------------------------------------------------------------------- render
--- Convert the pixel buffer into drawing characters and blit it out.
function Canvas:render()
  local px, W = self.px, self.w
  local cw, ch = self.cw, self.ch
  local C, F, B, T = self._c, self._f, self._b, self._t
  local W2 = W + W
  for row = 0, ch - 1 do
    local base = row * 3 * W
    for col = 1, cw do
      local o = base + (col - 1) * 2
      local a, b = px[o + 1], px[o + 2]
      local c, d = px[o + W + 1], px[o + W + 2]
      local e, f = px[o + W2 + 1], px[o + W2 + 2]
      if a == b and a == c and a == d and a == e and a == f then
        C[col] = " "
        F[col] = "0"
        B[col] = BLIT[a]
      else
        local bgc, fgc
        -- Fast path: almost every non-uniform cell holds exactly two colours.
        local na = 1
        if b == a then na = na + 1 end
        if c == a then na = na + 1 end
        if d == a then na = na + 1 end
        if e == a then na = na + 1 end
        if f == a then na = na + 1 end
        local z
        if b ~= a then z = b
        elseif c ~= a then z = c
        elseif d ~= a then z = d
        elseif e ~= a then z = e
        else z = f end
        local nz = 0
        if b == z then nz = nz + 1 end
        if c == z then nz = nz + 1 end
        if d == z then nz = nz + 1 end
        if e == z then nz = nz + 1 end
        if f == z then nz = nz + 1 end

        if na + nz == 6 then
          if na >= nz then bgc, fgc = a, z else bgc, fgc = z, a end
        else
          -- three or more colours: keep the two most common, fold the rest in
          T[1], T[2], T[3], T[4], T[5], T[6] = a, b, c, d, e, f
          local bc, bn, sc, sn = nil, 0, nil, 0
          for i = 1, 6 do
            local v = T[i]
            if v ~= bc and v ~= sc then
              local n = 0
              for j = 1, 6 do if T[j] == v then n = n + 1 end end
              if n > bn then
                sc, sn = bc, bn
                bc, bn = v, n
              elseif n > sn then
                sc, sn = v, n
              end
            end
          end
          bgc = bc
          fgc = sc or bc
        end
        local bits = 0
        if a ~= bgc then bits = bits + 1 end
        if b ~= bgc then bits = bits + 2 end
        if c ~= bgc then bits = bits + 4 end
        if d ~= bgc then bits = bits + 8 end
        if e ~= bgc then bits = bits + 16 end
        if f ~= bgc then bits = bits + 32 end
        if bits >= 32 then
          bits = 63 - bits
          fgc, bgc = bgc, fgc
        end
        C[col] = schar(128 + bits)
        F[col] = BLIT[fgc]
        B[col] = BLIT[bgc]
      end
    end
    term.setCursorPos(self.cx, self.cy + row)
    term.blit(concat(C, "", 1, cw), concat(F, "", 1, cw), concat(B, "", 1, cw))
  end
end

return Canvas
]=])
file("gameos/lib/data.lua", [=[
--[[ data -- settings, high score tables, per-game progress and play stats.

  Everything lives in one serialised table at /gameos/data/save.dat. Writes
  are best-effort: a read-only or full disk degrades to an in-memory session
  rather than crashing the console.
]]

local data = {}

local DIR = "/gameos/data"
local PATH = DIR .. "/save.dat"
local MAX_SCORES = 5

local DEFAULT_SETTINGS = {
  theme = "midnight",
  -- three independent knobs, 0..10
  volMaster = 7,
  volMusic = 6,
  volSfx = 10,
  showFps = false,
  confirmExit = true,
}

data.state = nil
data.dirty = false
data.writable = true

local function freshState()
  local s = {
    version = 1, settings = {}, scores = {}, stats = {},
    progress = {}, trophies = {},
  }
  for k, v in pairs(DEFAULT_SETTINGS) do s.settings[k] = v end
  return s
end

function data.load()
  local state = freshState()
  if fs.exists(PATH) then
    local handle = fs.open(PATH, "r")
    if handle then
      local raw = handle.readAll()
      handle.close()
      local ok, parsed = pcall(textutils.unserialize, raw)
      if ok and type(parsed) == "table" then
        if type(parsed.settings) == "table" then
          for k, v in pairs(parsed.settings) do
            if DEFAULT_SETTINGS[k] ~= nil and type(v) == type(DEFAULT_SETTINGS[k]) then
              state.settings[k] = v
            end
          end
        end
        if type(parsed.scores) == "table" then state.scores = parsed.scores end
        if type(parsed.stats) == "table" then state.stats = parsed.stats end
        if type(parsed.progress) == "table" then state.progress = parsed.progress end
        if type(parsed.trophies) == "table" then state.trophies = parsed.trophies end
      end
    end
  end
  data.state = state
  return state
end

function data.save()
  if not data.state then return false end
  local ok = pcall(function()
    if not fs.exists(DIR) then fs.makeDir(DIR) end
    local handle = fs.open(PATH, "w")
    if not handle then error("cannot open", 0) end
    handle.write(textutils.serialize(data.state))
    handle.close()
  end)
  data.writable = ok
  if ok then data.dirty = false end
  return ok
end

--- Persist only if something asked for it, so menus can call this freely.
function data.flush()
  if data.dirty then return data.save() end
  return true
end

------------------------------------------------------------------- settings
function data.get(key)
  local v = data.state.settings[key]
  if v == nil then return DEFAULT_SETTINGS[key] end
  return v
end

function data.set(key, value)
  data.state.settings[key] = value
  data.dirty = true
end

function data.defaults() return DEFAULT_SETTINGS end

---------------------------------------------------------------- high scores
--- Ordered best-first list of { score = n, when = "d123" }.
function data.scores(gameId)
  local list = data.state.scores[gameId]
  if type(list) ~= "table" then
    list = {}
    data.state.scores[gameId] = list
  end
  return list
end

function data.best(gameId)
  local list = data.scores(gameId)
  return list[1] and list[1].score or 0
end

--- Attach initials to the score sitting at a rank (used after the arcade
--- style name entry that only a new number one triggers).
function data.nameScore(gameId, rank, who)
  local entry = data.scores(gameId)[rank]
  if entry then
    entry.who = who
    data.dirty = true
  end
end

--- Insert a score. Returns its 1-based rank, or nil if it did not place.
function data.submit(gameId, score, lowerIsBetter)
  if type(score) ~= "number" then return nil end
  score = math.floor(score)
  local list = data.scores(gameId)
  local pos = #list + 1
  for i = 1, #list do
    -- written out rather than "cond and a or b": when lowerIsBetter is true
    -- and the comparison is false, that idiom falls through to the wrong test
    local better
    if lowerIsBetter then
      better = score < list[i].score
    else
      better = score > list[i].score
    end
    if better then pos = i break end
  end
  if pos > MAX_SCORES then return nil end
  table.insert(list, pos, { score = score, day = os.day() })
  while #list > MAX_SCORES do table.remove(list) end
  data.dirty = true
  return pos
end

------------------------------------------------------------------- trophies
--- Trophies are stored as id -> the in-game day they were earned.
function data.hasTrophy(id)
  return data.state.trophies[id] ~= nil
end

--- Returns true only the first time a trophy is earned.
function data.awardTrophy(id)
  if data.state.trophies[id] ~= nil then return false end
  data.state.trophies[id] = os.day()
  data.dirty = true
  return true
end

function data.trophyCount()
  local n = 0
  for _ in pairs(data.state.trophies) do n = n + 1 end
  return n
end

------------------------------------------------------------------- progress
--- Free-form per-game persistent table (level unlocks, best move counts...).
function data.progress(gameId)
  local p = data.state.progress[gameId]
  if type(p) ~= "table" then
    p = {}
    data.state.progress[gameId] = p
  end
  return p
end

function data.markDirty() data.dirty = true end

---------------------------------------------------------------------- stats
function data.stats(gameId)
  local s = data.state.stats[gameId]
  if type(s) ~= "table" then
    s = { plays = 0, seconds = 0 }
    data.state.stats[gameId] = s
  end
  if type(s.plays) ~= "number" then s.plays = 0 end
  if type(s.seconds) ~= "number" then s.seconds = 0 end
  return s
end

function data.recordPlay(gameId, seconds)
  local s = data.stats(gameId)
  s.plays = s.plays + 1
  s.seconds = math.floor(s.seconds + (seconds or 0))
  data.dirty = true
end

function data.totalPlays()
  local n = 0
  for _, s in pairs(data.state.stats) do n = n + (s.plays or 0) end
  return n
end

function data.totalSeconds()
  local n = 0
  for _, s in pairs(data.state.stats) do n = n + (s.seconds or 0) end
  return n
end

--- "1h 04m" / "37s"
function data.formatDuration(seconds)
  seconds = math.floor(seconds or 0)
  if seconds < 60 then return seconds .. "s" end
  local m = math.floor(seconds / 60)
  if m < 60 then return m .. "m " .. string.format("%02ds", seconds % 60) end
  local h = math.floor(m / 60)
  return h .. "h " .. string.format("%02dm", m % 60)
end

function data.wipe()
  data.state = freshState()
  data.dirty = true
  data.save()
end

return data
]=])
file("gameos/lib/font.lua", [=[
--[[ font -- a 5-row pixel font drawn onto a canvas.

  Glyphs are 4 pixels wide apart from M, N and W, which need 5 to stay
  readable. Rows are listed top to bottom, "1" is an inked pixel. Lower case
  is folded to upper case; unknown characters render as a blank.

  Layout rule: a character cell holds three pixel rows and only two colours,
  so put text baselines on y = 3k + 1 and leave at least six pixels between
  lines of different colours. Lines that share a cell lose a colour.
]]

local font = { W = 4, H = 5 }

local RAW = {
  ["0"] = "0110 1001 1001 1001 0110",
  ["1"] = "0010 0110 0010 0010 0111",
  ["2"] = "1110 0001 0110 1000 1111",
  ["3"] = "1110 0001 0110 0001 1110",
  ["4"] = "1001 1001 1111 0001 0001",
  ["5"] = "1111 1000 1110 0001 1110",
  ["6"] = "0110 1000 1110 1001 0110",
  ["7"] = "1111 0001 0010 0100 0100",
  ["8"] = "0110 1001 0110 1001 0110",
  ["9"] = "0110 1001 0111 0001 0110",
  ["A"] = "0110 1001 1111 1001 1001",
  ["B"] = "1110 1001 1110 1001 1110",
  ["C"] = "0111 1000 1000 1000 0111",
  ["D"] = "1110 1001 1001 1001 1110",
  ["E"] = "1111 1000 1110 1000 1111",
  ["F"] = "1111 1000 1110 1000 1000",
  ["G"] = "0111 1000 1011 1001 0111",
  ["H"] = "1001 1001 1111 1001 1001",
  ["I"] = "1110 0100 0100 0100 1110",
  ["J"] = "0011 0001 0001 1001 0110",
  ["K"] = "1001 1010 1100 1010 1001",
  ["L"] = "1000 1000 1000 1000 1111",
  ["M"] = "10001 11011 10101 10001 10001",
  ["N"] = "10001 11001 10101 10011 10001",
  ["O"] = "0110 1001 1001 1001 0110",
  ["P"] = "1110 1001 1110 1000 1000",
  ["Q"] = "0110 1001 1001 1011 0111",
  ["R"] = "1110 1001 1110 1010 1001",
  ["S"] = "0111 1000 0110 0001 1110",
  ["T"] = "1111 0100 0100 0100 0100",
  ["U"] = "1001 1001 1001 1001 0110",
  ["V"] = "1001 1001 1001 1010 0100",
  ["W"] = "10001 10001 10101 11011 10001",
  ["X"] = "1001 1001 0110 1001 1001",
  ["Y"] = "1001 1001 0110 0100 0100",
  ["Z"] = "1111 0001 0110 1000 1111",
  [" "] = "0000 0000 0000 0000 0000",
  ["."] = "0000 0000 0000 0000 0100",
  [","] = "0000 0000 0000 0100 1000",
  [":"] = "0000 0100 0000 0100 0000",
  [";"] = "0000 0100 0000 0100 1000",
  ["-"] = "0000 0000 1110 0000 0000",
  ["+"] = "0000 0100 1110 0100 0000",
  ["="] = "0000 1110 0000 1110 0000",
  ["!"] = "0100 0100 0100 0000 0100",
  ["?"] = "1110 0001 0110 0000 0100",
  ["'"] = "0100 0100 0000 0000 0000",
  ["\""] = "1010 1010 0000 0000 0000",
  ["/"] = "0001 0010 0010 0100 1000",
  ["\\"] = "1000 0100 0100 0010 0001",
  ["("] = "0010 0100 0100 0100 0010",
  [")"] = "0100 0010 0010 0010 0100",
  ["["] = "0110 0100 0100 0100 0110",
  ["]"] = "0110 0010 0010 0010 0110",
  ["<"] = "0010 0100 1000 0100 0010",
  [">"] = "0100 0010 0001 0010 0100",
  ["*"] = "0000 1010 0100 1010 0000",
  ["%"] = "1001 0010 0100 1000 1001",
  ["#"] = "0101 1111 0101 1111 0101",
  ["_"] = "0000 0000 0000 0000 1111",
}

-- Compile to lists of {x, y} offsets so drawing is a flat loop.
font.glyphs = {}
for ch, spec in pairs(RAW) do
  local pts, y, w = {}, 0, 0
  for row in spec:gmatch("%S+") do
    if #row > w then w = #row end
    for x = 1, #row do
      if row:sub(x, x) == "1" then pts[#pts + 1] = { x - 1, y } end
    end
    y = y + 1
  end
  font.glyphs[ch] = { pts = pts, w = w }
end

local BLANK = font.glyphs[" "]

function font.width(text, scale, spacing)
  scale = scale or 1
  spacing = spacing or 1
  text = tostring(text):upper()
  local n = #text
  if n == 0 then return 0 end
  local total = 0
  for i = 1, n do
    local g = font.glyphs[text:sub(i, i)] or BLANK
    total = total + g.w * scale + spacing
  end
  return total - spacing
end

--- Draw text at pixel (x, y). Returns the x just past the last glyph.
function font.draw(canvas, x, y, text, col, scale, spacing)
  scale = scale or 1
  spacing = spacing or 1
  text = tostring(text):upper()
  local gx = x
  for i = 1, #text do
    local g = font.glyphs[text:sub(i, i)] or BLANK
    local pts = g.pts
    for j = 1, #pts do
      local p = pts[j]
      if scale == 1 then
        canvas:set(gx + p[1], y + p[2], col)
      else
        canvas:fill(gx + p[1] * scale, y + p[2] * scale, scale, scale, col)
      end
    end
    gx = gx + g.w * scale + spacing
  end
  return gx - spacing
end

--- Draw with a one-pixel drop shadow underneath.
function font.drawShadow(canvas, x, y, text, col, shadow, scale, spacing)
  font.draw(canvas, x + 1, y + 1, text, shadow, scale, spacing)
  return font.draw(canvas, x, y, text, col, scale, spacing)
end

--- Centre text horizontally across the whole canvas (or a given span).
function font.center(canvas, y, text, col, scale, spacing, x0, w)
  x0 = x0 or 1
  w = w or canvas.w
  local tw = font.width(text, scale, spacing)
  return font.draw(canvas, x0 + math.floor((w - tw) / 2), y, text, col, scale, spacing)
end

function font.centerShadow(canvas, y, text, col, shadow, scale, spacing, x0, w)
  x0 = x0 or 1
  w = w or canvas.w
  local tw = font.width(text, scale, spacing)
  local x = x0 + math.floor((w - tw) / 2)
  font.draw(canvas, x + 1, y + 1, text, shadow, scale, spacing)
  return font.draw(canvas, x, y, text, col, scale, spacing)
end

return font
]=])
file("gameos/lib/gfx.lua", [=[
--[[ gfx -- screen setup, palettes and flicker-free character drawing.

  GameOS always draws into a fixed 51x19 design surface. On a larger display
  (a monitor) that surface is centred and the surround is blanked, so every
  screen in the console can assume exact coordinates.
]]

local gfx = {}

gfx.W, gfx.H = 51, 19

--------------------------------------------------------------- blit lookup
local BLIT = {}
local FROMBLIT = {}
do
  local hex = "0123456789abcdef"
  local c = 1
  for i = 1, 16 do
    BLIT[c] = hex:sub(i, i)
    FROMBLIT[hex:sub(i, i)] = c
    c = c * 2
  end
end
gfx.blit = BLIT
gfx.unblit = FROMBLIT

--------------------------------------------------------- drawing characters
-- Sub-pixel cells: bit 1,2 = top row, 4,8 = middle row, 16,32 = bottom row.
gfx.TOP1 = string.char(128 + 3)    -- top third is foreground
gfx.TOP2 = string.char(128 + 15)   -- top two thirds are foreground
gfx.LEFT = string.char(128 + 21)   -- left half is foreground

----------------------------------------------------------------- palettes
gfx.themes = {
  {
    id = "midnight", name = "Midnight",
    [colors.white] = 0xE8EDF5, [colors.orange] = 0xF29C38, [colors.magenta] = 0xE05C9E,
    [colors.lightBlue] = 0x63B4F0, [colors.yellow] = 0xF2D544, [colors.lime] = 0x76D95E,
    [colors.pink] = 0xF294B4, [colors.gray] = 0x272D36, [colors.lightGray] = 0x76818F,
    [colors.cyan] = 0x35C4C4, [colors.purple] = 0x9C5CE6, [colors.blue] = 0x2E6BD9,
    [colors.brown] = 0x8A5C3C, [colors.green] = 0x2E9E52, [colors.red] = 0xE0413F,
    [colors.black] = 0x0B0E13,
  },
  {
    id = "neon", name = "Neon",
    [colors.white] = 0xF2E9FF, [colors.orange] = 0xFF8A3D, [colors.magenta] = 0xFF3FA4,
    [colors.lightBlue] = 0x4CC9F0, [colors.yellow] = 0xFFE45E, [colors.lime] = 0xB9F73E,
    [colors.pink] = 0xFF8AD0, [colors.gray] = 0x1E1436, [colors.lightGray] = 0x6B5CA5,
    [colors.cyan] = 0x4EF0D0, [colors.purple] = 0x9D4EDD, [colors.blue] = 0x3A2CA3,
    [colors.brown] = 0x6D3B2E, [colors.green] = 0x2DA84F, [colors.red] = 0xFF2E63,
    [colors.black] = 0x0A0714,
  },
  {
    id = "amber", name = "Amber CRT",
    [colors.black] = 0x0F0800, [colors.gray] = 0x2E1C04, [colors.brown] = 0x4A2E06,
    [colors.blue] = 0x5C3A08, [colors.purple] = 0x6E450A, [colors.red] = 0x80500C,
    [colors.green] = 0x925B0E, [colors.cyan] = 0xA46610, [colors.magenta] = 0xB67112,
    [colors.lightGray] = 0xC87C14, [colors.lime] = 0xD48A1E, [colors.orange] = 0xE09528,
    [colors.lightBlue] = 0xE8A238, [colors.yellow] = 0xF0B048, [colors.pink] = 0xF6C066,
    [colors.white] = 0xFFD98A,
  },
  {
    id = "dmg", name = "Game Boy",
    [colors.black] = 0x0F380F, [colors.gray] = 0x1A4A15, [colors.brown] = 0x24541C,
    [colors.blue] = 0x2A5C22, [colors.purple] = 0x306230, [colors.red] = 0x3A6E30,
    [colors.green] = 0x4A7A2E, [colors.cyan] = 0x5A862C, [colors.magenta] = 0x6A922A,
    [colors.lightGray] = 0x7A9E20, [colors.lime] = 0x8BAC0F, [colors.orange] = 0x93B20F,
    [colors.lightBlue] = 0x97B60F, [colors.yellow] = 0x9BBC0F, [colors.pink] = 0xA0C010,
    [colors.white] = 0xA5C40F,
  },
}

gfx.themeIndex = 1

local ALL = {
  colors.white, colors.orange, colors.magenta, colors.lightBlue, colors.yellow,
  colors.lime, colors.pink, colors.gray, colors.lightGray, colors.cyan,
  colors.purple, colors.blue, colors.brown, colors.green, colors.red, colors.black,
}
gfx.allColors = ALL

--------------------------------------------------------------------- setup
local originalPalette = nil

--- Attach to a terminal. Returns false plus a message when it is too small.
function gfx.init(target)
  local parent = target or term.current()
  local pw, ph = parent.getSize()
  if pw < gfx.W or ph < gfx.H then
    return false, string.format("Display is %dx%d, GameOS needs %dx%d", pw, ph, gfx.W, gfx.H)
  end
  gfx.parent = parent
  gfx.color = parent.isColor and parent.isColor() or false
  gfx.offX = math.floor((pw - gfx.W) / 2)
  gfx.offY = math.floor((ph - gfx.H) / 2)

  if gfx.color and not originalPalette then
    originalPalette = {}
    for _, c in ipairs(ALL) do
      local r, g, b = parent.getPaletteColour(c)
      originalPalette[c] = { r, g, b }
    end
  end

  -- blank the whole physical screen so the letterbox is clean
  parent.setBackgroundColour(colors.black)
  parent.setTextColour(colors.white)
  parent.clear()
  if parent.setCursorBlink then parent.setCursorBlink(false) end

  gfx.buf = window.create(parent, gfx.offX + 1, gfx.offY + 1, gfx.W, gfx.H, true)
  gfx.buf.setCursorBlink(false)
  gfx.prevTerm = term.redirect(gfx.buf)
  gfx.applyTheme(gfx.themeIndex)
  return true
end

--- Re-centre the design surface after the display changes size (a monitor
--- being extended, say). Returns false if it no longer fits.
function gfx.handleResize()
  if not gfx.parent or not gfx.buf then return true end
  local pw, ph = gfx.parent.getSize()
  if pw < gfx.W or ph < gfx.H then return false end
  gfx.offX = math.floor((pw - gfx.W) / 2)
  gfx.offY = math.floor((ph - gfx.H) / 2)
  gfx.parent.setBackgroundColour(colors.black)
  gfx.parent.clear()
  gfx.buf.reposition(gfx.offX + 1, gfx.offY + 1)
  return true
end

function gfx.shutdown()
  if gfx.prevTerm then
    term.redirect(gfx.prevTerm)
    gfx.prevTerm = nil
  end
  if originalPalette and gfx.parent and gfx.color then
    for c, rgb in pairs(originalPalette) do
      gfx.parent.setPaletteColour(c, rgb[1], rgb[2], rgb[3])
    end
  end
  if gfx.parent then
    gfx.parent.setBackgroundColour(colors.black)
    gfx.parent.setTextColour(colors.white)
    gfx.parent.clear()
    gfx.parent.setCursorPos(1, 1)
    if gfx.parent.setCursorBlink then gfx.parent.setCursorBlink(true) end
  end
  gfx.buf = nil
end

function gfx.applyTheme(index)
  index = ((index - 1) % #gfx.themes) + 1
  gfx.themeIndex = index
  local theme = gfx.themes[index]
  gfx.theme = theme
  if not gfx.color then return end
  for _, c in ipairs(ALL) do
    local v = theme[c]
    if v then
      local r = math.floor(v / 65536) % 256 / 255
      local g = math.floor(v / 256) % 256 / 255
      local b = v % 256 / 255
      gfx.parent.setPaletteColour(c, r, g, b)
      if gfx.buf then gfx.buf.setPaletteColour(c, r, g, b) end
    end
  end
end

function gfx.themeByID(id)
  for i, t in ipairs(gfx.themes) do if t.id == id then return i end end
  return 1
end

------------------------------------------------------------------- frames
function gfx.beginFrame()
  if gfx.buf then gfx.buf.setVisible(false) end
end

function gfx.endFrame()
  if gfx.buf then gfx.buf.setVisible(true) end
end

--------------------------------------------------------------- primitives
local floor = math.floor

function gfx.clear(bg)
  term.setBackgroundColour(bg or colors.black)
  term.clear()
end

--- Solid rectangle. x,y are 1-based, w,h are sizes in cells.
function gfx.fill(x, y, w, h, bg)
  x, y, w, h = floor(x), floor(y), floor(w), floor(h)
  if w <= 0 or h <= 0 then return end
  if x < 1 then w = w + x - 1 x = 1 end
  if y < 1 then h = h + y - 1 y = 1 end
  if x + w - 1 > gfx.W then w = gfx.W - x + 1 end
  if y + h - 1 > gfx.H then h = gfx.H - y + 1 end
  if w <= 0 or h <= 0 then return end
  term.setBackgroundColour(bg)
  local line = string.rep(" ", w)
  for i = 0, h - 1 do
    term.setCursorPos(x, y + i)
    term.write(line)
  end
end

function gfx.text(x, y, s, fg, bg)
  y = floor(y)
  if y < 1 or y > gfx.H then return end
  s = tostring(s)
  x = floor(x)
  if x < 1 then
    s = s:sub(2 - x)
    x = 1
  end
  if #s == 0 then return end
  if x > gfx.W then return end
  if x + #s - 1 > gfx.W then s = s:sub(1, gfx.W - x + 1) end
  if fg then term.setTextColour(fg) end
  if bg then term.setBackgroundColour(bg) end
  term.setCursorPos(x, y)
  term.write(s)
end

function gfx.blitStr(x, y, s, fgs, bgs)
  if y < 1 or y > gfx.H or x > gfx.W then return end
  if x < 1 then
    local cut = 2 - x
    s, fgs, bgs = s:sub(cut), fgs:sub(cut), bgs:sub(cut)
    x = 1
  end
  if #s == 0 then return end
  if x + #s - 1 > gfx.W then
    local keep = gfx.W - x + 1
    s, fgs, bgs = s:sub(1, keep), fgs:sub(1, keep), bgs:sub(1, keep)
  end
  term.setCursorPos(x, y)
  term.blit(s, fgs, bgs)
end

--- Centre text within [x0, x0+w-1]; defaults to the whole screen width.
function gfx.center(y, s, fg, bg, x0, w)
  x0 = x0 or 1
  w = w or gfx.W
  s = tostring(s)
  gfx.text(x0 + floor((w - #s) / 2), y, s, fg, bg)
end

--- Text whose last character lands on column x.
function gfx.right(x, y, s, fg, bg)
  s = tostring(s)
  gfx.text(x - #s + 1, y, s, fg, bg)
end

function gfx.hline(x, y, w, bg) gfx.fill(x, y, w, 1, bg) end
function gfx.vline(x, y, h, bg) gfx.fill(x, y, 1, h, bg) end

--- A thin accent rule: one third of a cell tall, sitting at the top of row y.
function gfx.rule(x, y, w, fg, bg)
  if w <= 0 then return end
  gfx.blitStr(x, y, string.rep(gfx.TOP1, w), string.rep(BLIT[fg], w), string.rep(BLIT[bg], w))
end

--- Panel with an optional title bar. Returns the inner content rect.
function gfx.panel(x, y, w, h, bg, title, titleFg, titleBg)
  gfx.fill(x, y, w, h, bg)
  if title then
    titleBg = titleBg or bg
    gfx.fill(x, y, w, 1, titleBg)
    gfx.text(x + 1, y, title, titleFg or colors.white, titleBg)
    return x + 1, y + 2, w - 2, h - 3
  end
  return x + 1, y + 1, w - 2, h - 2
end

--- Horizontal progress bar with half-cell precision.
function gfx.bar(x, y, w, frac, fg, bg)
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  local halves = floor(frac * w * 2 + 0.5)
  local full = floor(halves / 2)
  local half = halves - full * 2
  if full > 0 then gfx.fill(x, y, full, 1, fg) end
  if half == 1 and full < w then
    gfx.blitStr(x + full, y, gfx.LEFT, BLIT[fg], BLIT[bg])
  end
  local rest = w - full - half
  if rest > 0 then gfx.fill(x + full + half, y, rest, 1, bg) end
end

--- Pick black or white text for a background colour in the current theme,
--- so accents stay readable in every palette.
function gfx.contrast(bg)
  local rgb = gfx.theme and gfx.theme[bg]
  if not rgb then return colors.white end
  local r = math.floor(rgb / 65536) % 256
  local g = math.floor(rgb / 256) % 256
  local b = rgb % 256
  -- rough perceptual luminance, integer maths only
  local lum = (r * 299 + g * 587 + b * 114) / 1000
  if lum > 140 then return colors.black end
  return colors.white
end

--- A dimmer companion colour for the given accent, used for shadows.
function gfx.shade(bg)
  if bg == colors.black then return colors.black end
  return gfx.contrast(bg) == colors.black and colors.gray or colors.black
end

-------------------------------------------------------------- glyph sprites
--[[ Two-colour sprites drawn straight onto the character grid.

  Pass rows of "#" and "." with a width that is a multiple of two and a
  height that is a multiple of three; each 2x3 block becomes one cell. This
  gives real artwork inside games that are laid out in character cells,
  without standing up a whole canvas.
]]
local BITVAL = { 1, 2, 4, 8, 16, 32 }

function gfx.makeGlyph(rows)
  local ph = #rows
  local pw = #rows[1]
  local glyph = { w = floor(pw / 2), h = floor(ph / 3), text = {}, swap = {}, cache = {} }
  for cy = 1, glyph.h do
    local chars, swaps = {}, {}
    for cx = 1, glyph.w do
      local bits = 0
      for sy = 0, 2 do
        local row = rows[(cy - 1) * 3 + sy + 1]
        for sx = 0, 1 do
          local i = (cx - 1) * 2 + sx + 1
          if row:sub(i, i) == "#" then bits = bits + BITVAL[sy * 2 + sx + 1] end
        end
      end
      local swapped = false
      if bits >= 32 then
        bits = 63 - bits
        swapped = true
      end
      chars[cx] = string.char(128 + bits)
      swaps[cx] = swapped
    end
    glyph.text[cy] = table.concat(chars)
    glyph.swap[cy] = swaps
  end
  return glyph
end

--- Colour strings are cached per glyph and colour pair, so repeatedly
--- stamping the same sprite costs no allocation.
local function glyphColours(glyph, fg, bg)
  local key = fg * 65536 + bg
  local hit = glyph.cache[key]
  if hit then return hit end
  local F, B = BLIT[fg], BLIT[bg]
  local entry = { fgs = {}, bgs = {} }
  for cy = 1, glyph.h do
    local swaps = glyph.swap[cy]
    local fgs, bgs = {}, {}
    for cx = 1, glyph.w do
      if swaps[cx] then
        fgs[cx], bgs[cx] = B, F
      else
        fgs[cx], bgs[cx] = F, B
      end
    end
    entry.fgs[cy] = table.concat(fgs)
    entry.bgs[cy] = table.concat(bgs)
  end
  glyph.cache[key] = entry
  return entry
end

function gfx.blitGlyph(x, y, glyph, fg, bg)
  local colours = glyphColours(glyph, fg, bg)
  for cy = 1, glyph.h do
    gfx.blitStr(x, y + cy - 1, glyph.text[cy], colours.fgs[cy], colours.bgs[cy])
  end
end

--- Truncate to width, adding a trailing dot when clipped.
function gfx.clip(s, w)
  s = tostring(s)
  if #s <= w then return s end
  if w <= 1 then return s:sub(1, w) end
  return s:sub(1, w - 1) .. "."
end

function gfx.pad(s, w, align)
  s = gfx.clip(s, w)
  local gap = w - #s
  if align == "right" then return string.rep(" ", gap) .. s end
  if align == "center" then
    local l = floor(gap / 2)
    return string.rep(" ", l) .. s .. string.rep(" ", gap - l)
  end
  return s .. string.rep(" ", gap)
end

--- Format a number with thousands separators.
function gfx.commas(n)
  local s = tostring(math.floor(n))
  local sign = ""
  if s:sub(1, 1) == "-" then sign = "-" s = s:sub(2) end
  local out = s
  while true do
    local rep
    out, rep = out:gsub("^(%d+)(%d%d%d)", "%1,%2")
    if rep == 0 then break end
  end
  return sign .. out
end

return gfx
]=])
file("gameos/lib/input.lua", [=[
--[[ input -- key and mouse state for a frame-based game loop.

  The runtime feeds raw CC events in and calls endFrame() after each update.
  Games ask three questions:
    input.down(...)     is the key held right now
    input.pressed(...)  was it pressed fresh this frame
    input.repeated(...) pressed, or auto-repeating because it is held
]]

local input = {}

input.held = {}
input.hit = {}
input.rep = {}
input.chars = {}
input.mouseEvents = {}
input.mouseX, input.mouseY = 0, 0

function input.reset()
  for k in pairs(input.held) do input.held[k] = nil end
  input.clearFrame()
end

function input.clearFrame()
  for k in pairs(input.hit) do input.hit[k] = nil end
  for k in pairs(input.rep) do input.rep[k] = nil end
  for i = #input.chars, 1, -1 do input.chars[i] = nil end
  for i = #input.mouseEvents, 1, -1 do input.mouseEvents[i] = nil end
end

input.endFrame = input.clearFrame

function input.onKey(code, held)
  if not held then input.hit[code] = true end
  input.rep[code] = true
  input.held[code] = true
end

function input.onKeyUp(code)
  input.held[code] = nil
end

function input.onChar(ch)
  input.chars[#input.chars + 1] = ch
end

function input.onMouse(kind, btn, x, y)
  input.mouseEvents[#input.mouseEvents + 1] = { kind = kind, btn = btn, x = x, y = y }
  input.mouseX, input.mouseY = x, y
end

local function anyOf(set, ...)
  for i = 1, select("#", ...) do
    if set[(select(i, ...))] then return true end
  end
  return false
end

function input.down(...) return anyOf(input.held, ...) end
function input.pressed(...) return anyOf(input.hit, ...) end
function input.repeated(...) return anyOf(input.rep, ...) end

function input.anyPressed()
  for _ in pairs(input.hit) do return true end
  return false
end

--- -1 / 0 / +1 from a pair of key groups. Each argument is a list of codes.
function input.axis(negKeys, posKeys)
  local n = anyOf(input.held, table.unpack(negKeys))
  local p = anyOf(input.held, table.unpack(posKeys))
  if n and not p then return -1 end
  if p and not n then return 1 end
  return 0
end

---------------------------------------------------------------- key groups
input.LEFT = { keys.left, keys.a }
input.RIGHT = { keys.right, keys.d }
input.UP = { keys.up, keys.w }
input.DOWN = { keys.down, keys.s }
input.CONFIRM = { keys.enter, keys.space, keys.numPadEnter }
input.BACK = { keys.backspace, keys.q }
input.PAUSE = { keys.p }

--- Convenience wrappers over the standard groups.
function input.leftDown() return input.down(table.unpack(input.LEFT)) end
function input.rightDown() return input.down(table.unpack(input.RIGHT)) end
function input.upDown() return input.down(table.unpack(input.UP)) end
function input.downDown() return input.down(table.unpack(input.DOWN)) end
function input.leftHit() return input.pressed(table.unpack(input.LEFT)) end
function input.rightHit() return input.pressed(table.unpack(input.RIGHT)) end
function input.upHit() return input.pressed(table.unpack(input.UP)) end
function input.downHit() return input.pressed(table.unpack(input.DOWN)) end
function input.confirmHit() return input.pressed(table.unpack(input.CONFIRM)) end
function input.backHit() return input.pressed(table.unpack(input.BACK)) end

--- Horizontal / vertical axis using the standard groups.
function input.dx() return input.axis(input.LEFT, input.RIGHT) end
function input.dy() return input.axis(input.UP, input.DOWN) end

--[[ A key that auto-repeats on a timer of our own, so games get arcade-style
     "delayed auto shift" instead of the terminal's typing repeat. ]]
local Repeater = {}
Repeater.__index = Repeater

function input.repeater(delay, rate)
  return setmetatable({ delay = delay or 0.17, rate = rate or 0.045, t = 0, armed = false }, Repeater)
end

--- Call once per frame with whether the key is held; returns how many
--- discrete steps to apply this frame.
function Repeater:update(isDown, dt)
  if not isDown then
    self.armed = false
    self.t = 0
    return 0
  end
  if not self.armed then
    self.armed = true
    self.t = self.delay
    return 1
  end
  self.t = self.t - dt
  local steps = 0
  while self.t <= 0 do
    steps = steps + 1
    self.t = self.t + self.rate
    if steps > 12 then break end
  end
  return steps
end

return input
]=])
file("gameos/lib/music.lua", [=[
--[[ music -- the console's soundtrack.

  Songs are written the way a tracker writes them: sixteen-row patterns, a few
  tracks each, and an order list that strings the patterns together. A row is
  `tempo` ticks long, so tempo 3 is 0.15s per row and a pattern is one bar of
  2.4 seconds.

  Note tokens:
    D4     play D above middle
    D4!    accented (louder)
    D4~    soft
    5      a raw pitch, used for drums where pitch is timbre
    .      rest

  Everything is written inside the speaker's two octaves, F#3 to F#5.
  Instruments are voiced at different octaves, so "bass" at D4 sounds far
  below "bell" at D4 -- that is what gives these any vertical range at all.

  All of this is original; nothing here is a transcription.
]]

local req = ...
local audio = req("lib.audio")

local music = {}

local ROWS = 16
local ACCENT, SOFT = 1.35, 0.6

music.badTokens = {}

--- Turn a row string into a sparse map of row -> { pitch, vol }.
local function parse(text, label)
  local rows = {}
  local count = 0
  for token in text:gmatch("%S+") do
    count = count + 1
    if token ~= "." then
      local body = token
      local vol = 1
      local tail = body:sub(-1)
      if tail == "!" then
        vol = ACCENT
        body = body:sub(1, -2)
      elseif tail == "~" then
        vol = SOFT
        body = body:sub(1, -2)
      end
      local pitch
      if body:match("^%d+$") then
        pitch = tonumber(body)
      else
        pitch = audio.NOTE[body]
      end
      if not pitch or pitch < 0 or pitch > 24 then
        music.badTokens[#music.badTokens + 1] = (label or "?") .. ":" .. token
      else
        rows[count] = { pitch = pitch, vol = vol }
      end
    end
  end
  if count ~= ROWS then
    music.badTokens[#music.badTokens + 1] =
      (label or "?") .. " has " .. count .. " rows, expected " .. ROWS
  end
  return rows
end

--- Build one pattern from { instrument, volume, rows } triples.
local function pattern(label, tracks)
  local out = {}
  for i = 1, #tracks do
    local track = tracks[i]
    if not audio.instruments[track[1]] then
      music.badTokens[#music.badTokens + 1] = label .. " bad instrument " .. tostring(track[1])
    end
    out[i] = { inst = track[1], vol = track[2], rows = parse(track[3], label) }
  end
  return out
end

local SONGS = {}

local function song(id, def)
  def.id = id
  def.rows = ROWS
  local built = {}
  for name, tracks in pairs(def.patterns) do
    built[name] = pattern(id .. "/" .. name, tracks)
  end
  def.patterns = built
  SONGS[id] = def
end

--============================================================== the launcher
-- Warm, unhurried, and happy to loop for a long time behind a menu.
song("standby", {
  title = "Standby",
  tempo = 3,
  loop = 1,
  order = { "am", "am", "f", "f", "c", "c", "g", "g" },
  patterns = {
    am = {
      { "pling", 0.42, "A3 .  C4 .  E4 .  A4 .  C5 .  A4 .  E4 .  C4 ." },
      { "bass",  0.50, "A3 .  .  .  .  .  .  .  E4 .  .  .  .  .  .  ." },
      { "hat",   0.16, "18 .  .  .  18 .  .  .  18 .  .  .  18 .  .  ." },
    },
    f = {
      { "pling", 0.42, "F4 .  A4 .  C5 .  F4 .  A4 .  C5 .  A4 .  F4 ." },
      { "bass",  0.50, "F4 .  .  .  .  .  .  .  C4 .  .  .  .  .  .  ." },
      { "hat",   0.16, "18 .  .  .  18 .  .  .  18 .  .  .  18 .  .  ." },
    },
    c = {
      { "pling", 0.42, "C4 .  E4 .  G4 .  C5 .  E5 .  C5 .  G4 .  E4 ." },
      { "bass",  0.50, "C4 .  .  .  .  .  .  .  G4 .  .  .  .  .  .  ." },
      { "hat",   0.16, "18 .  .  .  18 .  .  .  18 .  .  .  18 .  .  ." },
    },
    g = {
      { "pling", 0.42, "G3 .  B3 .  D4 .  G4 .  B4 .  G4 .  D4 .  B3 ." },
      { "bass",  0.50, "G3 .  .  .  .  .  .  .  D4 .  .  .  .  .  .  ." },
      { "hat",   0.16, "18 .  .  .  18 .  .  .  18 .  .  .  18 .  .  ." },
    },
  },
})

--============================================================== Tetris
-- Fast, minor, and relentless: a pumping bass under a falling melody.
song("cascade", {
  title = "Cascade",
  tempo = 2,
  loop = 1,
  order = { "a", "a", "b", "a", "c", "c", "d", "a" },
  patterns = {
    a = {
      { "pling", 0.40, "D5! .  A4 .  F4 .  A4 .  D5 .  A4 .  C5 .  A4 ." },
      { "bass",  0.55, "D4 .  .  .  D4 .  .  .  D4 .  .  .  D4 .  .  ." },
      { "basedrum", 0.45, "2 .  .  .  .  .  .  .  2 .  .  .  .  .  .  ." },
      { "snare", 0.30, ".  .  .  .  5 .  .  .  .  .  .  .  5 .  .  ." },
    },
    b = {
      { "pling", 0.40, "C5! .  G4 .  E4 .  G4 .  C5 .  G4 .  AS4 . G4 ." },
      { "bass",  0.55, "C4 .  .  .  C4 .  .  .  C4 .  .  .  C4 .  .  ." },
      { "basedrum", 0.45, "2 .  .  .  .  .  .  .  2 .  .  .  .  .  .  ." },
      { "snare", 0.30, ".  .  .  .  5 .  .  .  .  .  .  .  5 .  .  ." },
    },
    c = {
      { "pling", 0.40, "AS4! . F4 .  D4 .  F4 .  AS4 . F4 .  A4 .  F4 ." },
      { "bass",  0.55, "AS3 . .  .  AS3 . .  .  AS3 . .  .  AS3 . .  ." },
      { "basedrum", 0.45, "2 .  .  .  .  .  .  .  2 .  .  .  .  .  .  ." },
      { "snare", 0.30, ".  .  .  .  5 .  .  .  .  .  .  .  5 .  .  ." },
    },
    d = {
      { "pling", 0.40, "A4! .  E4 .  CS4 . E4 .  A4 .  CS5 . E5 .  CS5 ." },
      { "bass",  0.55, "A3 .  .  .  A3 .  .  .  A3 .  .  .  E4 .  .  ." },
      { "basedrum", 0.45, "2 .  .  .  .  .  .  .  2 .  .  .  2 .  .  ." },
      { "snare", 0.30, ".  .  .  .  5 .  .  .  .  .  .  .  5 .  .  ." },
    },
  },
})

--============================================================== Snake
-- Light and springy; a banjo line that hops the way the snake does.
song("serpentine", {
  title = "Serpentine",
  tempo = 3,
  loop = 1,
  order = { "a", "b", "a", "c" },
  patterns = {
    a = {
      { "banjo", 0.40, "D4 .  FS4 . A4 .  FS4 . D5 .  A4 .  FS4 . A4 ." },
      { "bass",  0.45, "D4 .  .  .  A3 .  .  .  D4 .  .  .  A3 .  .  ." },
      { "hat",   0.14, ".  .  16 . .  .  16 . .  .  16 . .  .  16 ." },
    },
    b = {
      { "banjo", 0.40, "G4 .  B4 .  D5 .  B4 .  G4 .  D5 .  B4 .  G4 ." },
      { "bass",  0.45, "G3 .  .  .  D4 .  .  .  G3 .  .  .  D4 .  .  ." },
      { "hat",   0.14, ".  .  16 . .  .  16 . .  .  16 . .  .  16 ." },
    },
    c = {
      { "banjo", 0.40, "A4 .  CS5 . E5 .  CS5 . A4 .  E4 .  CS4 . E4 ." },
      { "bass",  0.45, "A3 .  .  .  E4 .  .  .  A3 .  .  .  E4 .  .  ." },
      { "hat",   0.14, ".  .  16 . .  .  16 . .  .  16 . .  .  16 ." },
    },
  },
})

--============================================================== Breakout, Pong
-- Punchy and syncopated, so it sits behind fast paddle work.
song("ricochet", {
  title = "Ricochet",
  tempo = 3,
  loop = 1,
  order = { "a", "b", "a", "c" },
  patterns = {
    a = {
      { "bit",   0.34, "D4 .  .  D4 .  F4 .  .  A4 .  .  A4 .  G4 .  ." },
      { "bass",  0.50, "D4 .  .  .  .  .  .  .  A3 .  .  .  .  .  .  ." },
      { "hat",   0.15, "16 .  16 . 16 .  16 . 16 .  16 . 16 .  16 ." },
    },
    b = {
      { "bit",   0.34, "C4 .  .  C4 .  E4 .  .  G4 .  .  G4 .  F4 .  ." },
      { "bass",  0.50, "C4 .  .  .  .  .  .  .  G3 .  .  .  .  .  .  ." },
      { "hat",   0.15, "16 .  16 . 16 .  16 . 16 .  16 . 16 .  16 ." },
    },
    c = {
      { "bit",   0.34, "AS3 . .  AS3 . D4 .  .  F4 .  .  A4 .  F4 .  ." },
      { "bass",  0.50, "AS3 . .  .  .  .  .  .  F4 .  .  .  .  .  .  ." },
      { "hat",   0.15, "16 .  16 . 16 .  16 . 16 .  16 . 16 .  16 ." },
    },
  },
})

--============================================================== Bombard
-- A slow, heavy descent: a duel where each turn lands harder than the last.
-- The bass walks down under a held figure, so it builds without hurrying the
-- player, who is doing arithmetic in their head between shots.
song("descent", {
  title = "Descent",
  tempo = 4,
  loop = 1,
  order = { "a", "b", "c", "d" },
  patterns = {
    a = {
      { "bass",       0.55, "D4 .  .  .  C4 .  .  .  AS3 . .  .  A3 .  .  ." },
      { "didgeridoo", 0.28, "D4 .  .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
      { "snare",      0.22, ".  .  .  .  .  .  .  4 .  .  .  .  .  .  .  4" },
    },
    b = {
      { "bass",       0.55, "G3 .  .  .  A3 .  .  .  AS3 . .  .  C4 .  .  ." },
      { "didgeridoo", 0.28, "G3 .  .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
      { "snare",      0.22, ".  .  .  .  .  .  .  4 .  .  .  .  .  .  .  4" },
    },
    c = {
      { "bass",       0.55, "D4 .  .  .  D4 .  .  .  C4 .  .  .  AS3 . .  ." },
      { "flute",      0.24, ".  .  .  .  D5~ . .  .  .  .  .  .  C5~ . .  ." },
      { "snare",      0.22, ".  .  .  .  .  .  .  4 .  .  .  .  .  .  .  4" },
    },
    d = {
      { "bass",       0.55, "A3 .  .  .  A3 .  .  .  G3 .  .  .  FS3 . .  ." },
      { "flute",      0.24, ".  .  .  .  A4~ . .  .  .  .  .  .  G4~ . .  ." },
      { "snare",      0.22, ".  .  .  .  .  .  .  4 .  .  .  .  .  .  .  4" },
    },
  },
})

--============================================================== Meteors
-- Sparse and weightless. Long gaps are the point.
song("drift", {
  title = "Drift",
  tempo = 5,
  loop = 1,
  order = { "a", "b", "a", "c" },
  patterns = {
    a = {
      { "flute",      0.30, "D4 .  .  .  A4 .  .  .  .  .  F4 .  .  .  .  ." },
      { "didgeridoo", 0.26, "D4 .  .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
      { "chime",      0.18, ".  .  .  .  .  .  .  .  D5~ . .  .  .  .  .  ." },
    },
    b = {
      { "flute",      0.30, "C4 .  .  .  G4 .  .  .  .  .  E4 .  .  .  .  ." },
      { "didgeridoo", 0.26, "C4 .  .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
      { "chime",      0.18, ".  .  .  .  .  .  .  .  E5~ . .  .  .  .  .  ." },
    },
    c = {
      { "flute",      0.30, "AS3 . .  .  F4 .  .  .  .  .  D4 .  .  .  .  ." },
      { "didgeridoo", 0.26, "AS3 . .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
      { "chime",      0.18, ".  .  .  .  .  .  .  .  F5~ . .  .  .  .  .  ." },
    },
  },
})

--============================================================== the puzzles
-- Slow, soft and deliberately unmemorable: this has to survive being left
-- on while somebody stares at a board for ten minutes.
song("quiet", {
  title = "Quiet Hours",
  tempo = 6,
  loop = 1,
  order = { "a", "b", "c", "b" },
  patterns = {
    a = {
      { "harp", 0.26, "D4 .  .  .  A4 .  .  .  F4 .  .  .  A4 .  .  ." },
      { "bass", 0.30, "D4 .  .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
    },
    b = {
      { "harp", 0.26, "C4 .  .  .  G4 .  .  .  E4 .  .  .  G4 .  .  ." },
      { "bass", 0.30, "C4 .  .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
    },
    c = {
      { "harp", 0.26, "AS3 . .  .  F4 .  .  .  D4 .  .  .  F4 .  .  ." },
      { "bass", 0.30, "AS3 . .  .  .  .  .  .  .  .  .  .  .  .  .  ." },
    },
  },
})

--============================================================== Flappy
-- Quick, airy and a little silly.
song("updraft", {
  title = "Updraft",
  tempo = 3,
  loop = 1,
  order = { "a", "b", "a", "c" },
  patterns = {
    a = {
      { "flute", 0.32, "D5 .  A4 .  D5 .  FS5 . E5 .  CS5 . A4 .  .  ." },
      { "bass",  0.42, "D4 .  .  .  A3 .  .  .  D4 .  .  .  A3 .  .  ." },
      { "hat",   0.13, "16 .  .  16 .  .  16 . .  16 .  .  16 .  .  ." },
    },
    b = {
      { "flute", 0.32, "G4 .  D5 .  E5 .  D5 .  B4 .  G4 .  D4 .  .  ." },
      { "bass",  0.42, "G3 .  .  .  D4 .  .  .  G3 .  .  .  D4 .  .  ." },
      { "hat",   0.13, "16 .  .  16 .  .  16 . .  16 .  .  16 .  .  ." },
    },
    c = {
      { "flute", 0.32, "A4 .  E5 .  FS5 . E5 .  CS5 . A4 .  E4 .  .  ." },
      { "bass",  0.42, "A3 .  .  .  E4 .  .  .  A3 .  .  .  E4 .  .  ." },
      { "hat",   0.13, "16 .  .  16 .  .  16 . .  16 .  .  16 .  .  ." },
    },
  },
})

--============================================================== Connect Four
-- Measured and a bit smug, for a game where you sit and think.
song("gambit", {
  title = "Gambit",
  tempo = 4,
  loop = 1,
  order = { "a", "b", "a", "c" },
  patterns = {
    a = {
      { "guitar", 0.34, "D4 .  .  F4 .  .  A4 .  .  .  G4 .  F4 .  .  ." },
      { "bass",   0.45, "D4 .  .  .  .  .  .  .  A3 .  .  .  .  .  .  ." },
      { "hat",    0.12, ".  .  .  .  16 . .  .  .  .  .  .  16 .  .  ." },
    },
    b = {
      { "guitar", 0.34, "C4 .  .  E4 .  .  G4 .  .  .  F4 .  E4 .  .  ." },
      { "bass",   0.45, "C4 .  .  .  .  .  .  .  G3 .  .  .  .  .  .  ." },
      { "hat",    0.12, ".  .  .  .  16 . .  .  .  .  .  .  16 .  .  ." },
    },
    c = {
      { "guitar", 0.34, "AS3 . .  D4 .  .  F4 .  .  .  E4 .  D4 .  .  ." },
      { "bass",   0.45, "AS3 . .  .  .  .  .  .  F4 .  .  .  .  .  .  ." },
      { "hat",    0.12, ".  .  .  .  16 . .  .  .  .  .  .  16 .  .  ." },
    },
  },
})

-------------------------------------------------------------------- lookup
function music.get(id) return SONGS[id] end

function music.names()
  local out = {}
  for id in pairs(SONGS) do out[#out + 1] = id end
  table.sort(out)
  return out
end

function music.title(id)
  local s = SONGS[id]
  return s and s.title or id
end

--- Seconds for one pass through the order list.
function music.length(id)
  local s = SONGS[id]
  if not s then return 0 end
  return #s.order * ROWS * s.tempo * 0.05
end

music.songs = SONGS
music.ROWS = ROWS

return music
]=])
file("gameos/lib/net.lua", [=[
--[[ net -- console-to-console play over a modem.

  The whole design goal is that nobody ever types a computer ID. One console
  says "host", the other says "join", and they find each other. That is what
  the advert/announce pair below is for: a host shouts on a well-known channel
  a few times a second, every console listening builds a live list, and stale
  entries fall off on their own. Nothing is configured and nothing is
  remembered between sessions.

  Raw modem traffic rather than rednet, deliberately:
    * no dependency on the rednet daemon being alive under whatever shell the
      console was launched from,
    * wired and wireless modems behave identically,
    * and the event we care about, modem_message, arrives through the normal
      event loop, so a game stays responsive while it waits.

  Delivery. Modems inside range do not drop packets, but a computer can leave
  range, be unloaded with its chunk, or simply be turned off, and none of
  those announce themselves. So every link carries:
    * a heartbeat, and a timeout that decides the peer is gone,
    * sequence numbers with acknowledgements and resends for messages that
      matter, because one lost turn deadlocks a turn-based match forever.

  Nothing here trusts what arrives. A message is a table, carries our marker,
  and comes from the computer we are actually linked to, or it is dropped.
]]

local net = {}

local LOBBY = 6502              -- where hosts advertise and joins arrive
local MARKER = "gameos"
local PROTOCOL = 1

net.ADVERT_EVERY = 0.5          -- how often a host shouts
net.ADVERT_STALE = 2.5          -- a host unheard this long drops off the list
net.HEARTBEAT_EVERY = 0.5
net.LINK_TIMEOUT = 5.0          -- silence this long means the peer is gone
net.RESEND_AFTER = 0.6

local modem = nil
local modemSide = nil

------------------------------------------------------------------ the modem
--- Any modem will do, wired or wireless. Wireless is preferred when both are
--- attached, since two consoles side by side on a wired network is the rarer
--- setup and a wired modem with no cable simply never hears anything.
local function findModem()
  local best, bestSide
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      local m = peripheral.wrap(side)
      local wireless = m.isWireless and m.isWireless()
      if wireless then return m, side end
      if not best then best, bestSide = m, side end
    end
  end
  return best, bestSide
end

function net.available()
  local m = findModem()
  return m ~= nil
end

function net.id() return os.getComputerID() end

--- A label arrives from another computer, and somebody there chose it. Trim
--- it to something that can safely be drawn: printable ASCII only, bounded
--- length, and never empty. This is the only text from off this machine that
--- the console ever puts on screen.
function net.cleanName(value, fallback)
  if type(value) ~= "string" then return fallback end
  local out = {}
  for i = 1, #value do
    local b = value:byte(i)
    if b >= 32 and b <= 126 then
      out[#out + 1] = string.char(b)
      if #out >= 24 then break end
    end
  end
  if #out == 0 then return fallback end
  return table.concat(out)
end

function net.label()
  local label = os.getComputerLabel()
  if label and #label > 0 then return label end
  return "Console " .. net.id()
end

--- Our own inbox channel. Computer IDs are small and stable, so they double
--- as channel numbers; the modulo only guards against a silly-large ID on a
--- long-lived world.
function net.channel(id) return (id or net.id()) % 60000 + 1000 end

function net.open()
  if modem then return true end
  local m, side = findModem()
  if not m then return false, "No modem attached" end
  modem, modemSide = m, side
  local ok, err = pcall(function()
    modem.open(LOBBY)
    modem.open(net.channel())
  end)
  if not ok then
    modem = nil
    return false, tostring(err)
  end
  return true
end

function net.close()
  if not modem then return end
  pcall(function()
    modem.close(LOBBY)
    modem.close(net.channel())
  end)
  modem, modemSide = nil, nil
end

function net.isOpen() return modem ~= nil end

------------------------------------------------------------------- sending
local function transmit(channel, body)
  if not modem then return false end
  body[MARKER] = PROTOCOL
  body.from = net.id()
  return pcall(modem.transmit, channel, net.channel(), body)
end

function net.broadcast(body) return transmit(LOBBY, body) end
function net.sendTo(id, body) return transmit(net.channel(id), body) end

--- Pull our kind of message out of a raw event, or nil. Everything that is
--- not a well-formed message from this protocol is simply not ours.
function net.parse(ev)
  if ev[1] ~= "modem_message" then return nil end
  local body = ev[5]
  if type(body) ~= "table" then return nil end
  if body[MARKER] ~= PROTOCOL then return nil end
  if type(body.t) ~= "string" then return nil end
  if type(body.from) ~= "number" then return nil end
  return body
end

--------------------------------------------------------------------- lobby
--- A host shouting into the dark. Call it every frame; it rate-limits itself.
local Host = {}
Host.__index = Host

function net.hosting(game, extra)
  local ok, err = net.open()
  if not ok then return nil, err end
  return setmetatable({
    game = game,
    extra = extra or {},
    last = -1,
    seen = {},
  }, Host)
end

function Host:advertise(now)
  if now - self.last < net.ADVERT_EVERY then return end
  self.last = now
  local body = { t = "advert", game = self.game, name = net.label() }
  for k, v in pairs(self.extra) do body[k] = v end
  net.broadcast(body)
end

--- A join request arrives here. Returns the joiner's id once, so the caller
--- can decide; answering is net.accept / net.refuse.
function Host:handle(ev)
  local msg = net.parse(ev)
  if not msg then return nil end
  if msg.t == "join" and msg.game == self.game then return msg end
  return nil
end

function net.accept(id, payload)
  local body = { t = "accept" }
  for k, v in pairs(payload or {}) do body[k] = v end
  net.sendTo(id, body)
end

function net.refuse(id, why)
  net.sendTo(id, { t = "refuse", why = why })
end

function net.unhost(game)
  if net.isOpen() then net.broadcast({ t = "unhost", game = game }) end
end

--- The other side of the lobby: a live list of hosts, kept fresh by adverts
--- and pruned when they stop arriving.
local Browser = {}
Browser.__index = Browser

function net.browsing(game)
  local ok, err = net.open()
  if not ok then return nil, err end
  return setmetatable({ game = game, hosts = {} }, Browser)
end

function Browser:handle(ev, now)
  local msg = net.parse(ev)
  if not msg then return end
  if msg.game ~= self.game then return end
  if msg.t == "advert" then
    local entry = self.hosts[msg.from]
    if not entry then
      -- Somewhere to stop, so a misbehaving network cannot grow this without
      -- limit. Nobody has thirty consoles hosting the same game.
      local n = 0
      for _ in pairs(self.hosts) do n = n + 1 end
      if n >= 24 then return end
      entry = { id = msg.from }
      self.hosts[msg.from] = entry
    end
    entry.name = net.cleanName(msg.name, "Console " .. msg.from)
    entry.seen = now
  elseif msg.t == "unhost" then
    self.hosts[msg.from] = nil
  end
end

--- Sorted by id so the list does not shuffle under the cursor while adverts
--- arrive in whatever order they happen to.
function Browser:list(now)
  local out = {}
  for id, entry in pairs(self.hosts) do
    if now - entry.seen <= net.ADVERT_STALE then
      out[#out + 1] = entry
    else
      self.hosts[id] = nil
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function net.requestJoin(id, game)
  net.sendTo(id, { t = "join", game = game, name = net.label() })
end

---------------------------------------------------------------------- link
--- An established connection to one peer.
local Link = {}
Link.__index = Link

function net.link(peerId, peerName)
  return setmetatable({
    peer = peerId,
    name = peerName or ("Console " .. peerId),
    outSeq = 0,
    inSeq = 0,
    pending = {},         -- seq -> { body, sentAt }
    inbox = {},
    lastHeard = os.clock(),
    lastBeat = 0,
    closed = false,
  }, Link)
end

--- Fire and forget: heartbeats and anything else where a lost copy does no
--- harm because a fresher one is right behind it.
function Link:sendLoose(t, payload)
  local body = { t = t }
  for k, v in pairs(payload or {}) do body[k] = v end
  net.sendTo(self.peer, body)
end

--- Guaranteed and in order. Used for the messages a match cannot lose.
function Link:send(t, payload)
  self.outSeq = self.outSeq + 1
  local body = { t = t, seq = self.outSeq }
  for k, v in pairs(payload or {}) do body[k] = v end
  self.pending[self.outSeq] = { body = body, sentAt = os.clock() }
  net.sendTo(self.peer, body)
  return self.outSeq
end

function Link:handle(ev, now)
  local msg = net.parse(ev)
  if not msg then return end
  if msg.from ~= self.peer then return end        -- not our conversation
  self.lastHeard = now

  if msg.t == "ack" then
    self.pending[msg.seq] = nil
    return
  end
  if msg.t == "bye" then
    self.closed = true
    self.byeReason = msg.why
    return
  end
  if msg.t == "beat" then return end

  if msg.seq then
    -- Acknowledge every time, including duplicates: a resend means our last
    -- acknowledgement is what went missing.
    self:sendLoose("ack", { seq = msg.seq })
    if msg.seq <= self.inSeq then return end      -- already delivered
    if msg.seq > self.inSeq + 1 then
      -- Out of order. Hold it rather than delivering a gap; the missing one
      -- is being resent and will arrive.
      self.held = self.held or {}
      self.held[msg.seq] = msg
      return
    end
    self.inSeq = msg.seq
    self.inbox[#self.inbox + 1] = msg
    -- drain anything that was waiting on this one
    while self.held and self.held[self.inSeq + 1] do
      self.inSeq = self.inSeq + 1
      self.inbox[#self.inbox + 1] = self.held[self.inSeq]
      self.held[self.inSeq] = nil
    end
  else
    self.inbox[#self.inbox + 1] = msg
  end
end

--- Heartbeats out, resends for anything unacknowledged. Call every frame.
function Link:update(now)
  if self.closed then return end
  if now - self.lastBeat >= net.HEARTBEAT_EVERY then
    self.lastBeat = now
    self:sendLoose("beat")
  end
  for seq, item in pairs(self.pending) do
    if now - item.sentAt >= net.RESEND_AFTER then
      item.sentAt = now
      net.sendTo(self.peer, item.body)
    end
  end
end

function Link:poll()
  if #self.inbox == 0 then return nil end
  return table.remove(self.inbox, 1)
end

function Link:alive(now)
  if self.closed then return false end
  return (now - self.lastHeard) < net.LINK_TIMEOUT
end

--- Seconds of silence, for showing a warning before the link is declared dead.
function Link:silence(now) return now - self.lastHeard end

function Link:close(why)
  if not self.closed then
    self:sendLoose("bye", { why = why })
    self.closed = true
  end
end

return net
]=])
file("gameos/lib/runtime.lua", [=[
--[[ runtime -- plays one game module.

  Owns the fixed-step loop, event routing, the pause menu, crash containment
  and the game-over card, so a game module only has to implement update(dt)
  and draw().

  Game module contract (see /gameos/games/*.lua):
    id, name, tagline, accent, art, controls, modes (optional)
    new(api, mode) -> instance
  Instance:
    :update(dt) :draw()               required
    :onKey(code, held) :onChar(c)     optional
    :onMouse(kind, btn, x, y)         optional
    :summary() -> { {label, value} }  optional
    .score .finished .quit .won .noScore
]]

local req = ...
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local input = req("lib.input")
local audio = req("lib.audio")
local data = req("lib.data")
local ui = req("lib.ui")

local runtime = {}

local TICK = 0.05
local floor = math.floor

------------------------------------------------------------------- crashes
local function crash(def, err)
  local msg = tostring(err)
  local lines = {}
  -- wrap the message to the dialog width
  local width = 36
  while #msg > 0 and #lines < 4 do
    lines[#lines + 1] = msg:sub(1, width)
    msg = msg:sub(width + 1)
  end
  audio.play("ui.deny")
  ui.alert(" " .. def.name .. " crashed ", lines, colors.red)
  return "menu"
end

--------------------------------------------------------------- pause screen
--- The guide, in the sense that the Xbox and the Switch use the word: the
--- things you want mid-game without leaving the game. Volume above all --
--- somebody walks into the room and you want it down now, not after four
--- menus -- so the three knobs are here as sliders you nudge in place, and
--- the trophy list is one keypress away.
---
--- This blocks the session loop while it is open, which is why a networked
--- game sets suppressPause and draws its own overlay instead.
local function pauseMenu(def, api)
  audio.play("ui.back")

  local KNOBS = {
    { label = "Master",  key = "volMaster", field = "master" },
    { label = "Music",   key = "volMusic",  field = "music" },
    { label = "Effects", key = "volSfx",    field = "sfx" },
  }

  -- rows: 1 Resume, 2 Restart, 3 Controls, 4 Trophies, 5..7 knobs, 8 Quit
  local ACTIONS = { "Resume", "Restart", "Controls", "Trophies" }
  local ROWS = #ACTIONS + #KNOBS + 1
  local QUIT = ROWS

  local X, Y, W, H = 10, 4, 32, 14
  local FIRST = Y + 2
  local BAR_X = X + W - 14      -- leaves room for the number after it
  local accent = def.accent or colors.lightBlue
  local sel = 1

  local function knobAt(row)
    local i = row - #ACTIONS
    if i >= 1 and i <= #KNOBS then return KNOBS[i] end
    return nil
  end

  local function setKnob(knob, value)
    if value < 0 then value = 0 elseif value > 10 then value = 10 end
    if value == data.get(knob.key) then return end
    data.set(knob.key, value)
    audio.volumes[knob.field] = value / 10
    audio.play("ui.move")
  end

  local function nudge(knob, dir)
    setKnob(knob, data.get(knob.key) + dir)
  end

  local function draw()
    gfx.panel(X, Y, W, H, colors.gray, " Paused ", colors.white, accent)
    for i = 1, #ACTIONS do
      local y = FIRST + i - 1
      local on = (sel == i)
      gfx.fill(X + 1, y, W - 2, 1, on and accent or colors.gray)
      gfx.text(X + 2, y, ACTIONS[i],
        on and gfx.contrast(accent) or colors.white, on and accent or colors.gray)
    end
    for i = 1, #KNOBS do
      local row = #ACTIONS + i
      local y = FIRST + row - 1
      local on = (sel == row)
      local bg = on and accent or colors.gray
      gfx.fill(X + 1, y, W - 2, 1, bg)
      gfx.text(X + 2, y, KNOBS[i].label, on and gfx.contrast(accent) or colors.white, bg)
      -- Three bars stacked with nothing between them read as one slab, so
      -- each carries its number: that is what makes a level legible at a
      -- glance rather than something you have to measure.
      local level = data.get(KNOBS[i].key)
      gfx.bar(BAR_X, y, 10, level / 10,
        on and gfx.contrast(accent) or colors.lime, on and accent or colors.black)
      gfx.right(X + W - 2, y, string.format("%2d", level),
        on and gfx.contrast(accent) or colors.white, bg)
    end
    local y = FIRST + QUIT - 1
    local on = (sel == QUIT)
    gfx.fill(X + 1, y, W - 2, 1, on and colors.red or colors.gray)
    gfx.text(X + 2, y, "Quit to menu",
      on and colors.white or colors.lightGray, on and colors.red or colors.gray)
    gfx.center(Y + H - 1, gfx.clip(def.name, W - 4), colors.lightGray, colors.gray, X, W)
  end

  --- Screens are opened by the loop below rather than from inside the event
  --- handler: ui.loop nested inside another ui.loop's handler would swallow
  --- the outer loop's pump timer, and the outer loop would quietly stop
  --- driving the music.
  local function activate()
    if sel == 1 then return "resume" end
    if sel == 2 then return "restart" end
    if sel == 3 then return "controls" end
    if sel == 4 then return "trophies" end
    if sel == QUIT then return "quit" end
    local knob = knobAt(sel)
    if knob then nudge(knob, 1) end
    return nil
  end

  local function handle(ev)
    local name = ev[1]
    if name == "key" then
      local k = ev[2]
      if k == keys.up or k == keys.w then
        sel = sel > 1 and sel - 1 or ROWS
        audio.play("ui.move")
      elseif k == keys.down or k == keys.s then
        sel = sel < ROWS and sel + 1 or 1
        audio.play("ui.move")
      elseif k == keys.left or k == keys.a then
        local knob = knobAt(sel)
        if knob then nudge(knob, -1) end
      elseif k == keys.right or k == keys.d then
        local knob = knobAt(sel)
        if knob then nudge(knob, 1) end
      elseif k == keys.enter or k == keys.space or k == keys.numPadEnter then
        return activate()
      elseif k == keys.p or k == keys.q or k == keys.backspace then
        return "resume"
      end

    elseif name == "mouse_scroll" then
      local _, my = ui.toLocal(ev[3], ev[4])
      local row = my - FIRST + 1
      local knob = knobAt(row)
      if knob then
        sel = row
        nudge(knob, ev[2] > 0 and 1 or -1)
      end

    elseif name == "mouse_click" or name == "mouse_drag" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      local row = my - FIRST + 1
      local knob = knobAt(row)
      -- clicking or dragging along a bar sets that level directly
      if knob and mx >= BAR_X - 1 and mx < BAR_X + 10 then
        sel = row
        setKnob(knob, mx - BAR_X + 1)
        return nil
      end
      if name == "mouse_drag" then return nil end
      if ev[2] == 2 then return "resume" end
      if row >= 1 and row <= ROWS and mx > X and mx < X + W - 1 then
        if row == sel then return activate() end
        sel = row
        audio.play("ui.move")
      elseif mx < X or mx >= X + W or my < Y or my >= Y + H then
        return "resume"
      end
    end
    return nil
  end

  while true do
    local result = ui.loop(draw, handle)
    if ui.terminated then return "quit" end
    if result == "controls" then
      ui.controls(def)
    elseif result == "trophies" then
      api.require("os.trophies").run(api)
    elseif result == "restart" or result == "quit" then
      data.flush()
      return result
    else
      data.flush()
      return "resume"          -- "resume", 0 from a cancel, or anything odd
    end
    if ui.terminated then return "quit" end
  end
end

-------------------------------------------------------------- trophies
--- Console-wide trophies, checked after every session.
local GLOBAL = {
  {
    id = "os_collector", name = "Collector", desc = "Play every game once",
    test = function(api)
      for _, g in ipairs(api.games) do
        if data.stats(g.id).plays < 1 then return false end
      end
      return #api.games > 0
    end,
  },
  {
    id = "os_hour", name = "Time Sink", desc = "One hour of total play",
    test = function() return data.totalSeconds() >= 3600 end,
  },
  {
    id = "os_century", name = "Century", desc = "Start a hundred games",
    test = function() return data.totalPlays() >= 100 end,
  },
}
runtime.globalTrophies = GLOBAL

--- Evaluate a game's trophies against a finished instance plus the
--- console-wide ones. Returns the list that was newly earned.
local function awardTrophies(def, inst, api)
  local won = {}
  local function consider(entry, arg)
    if data.hasTrophy(entry.id) then return end
    local ok, earned = pcall(entry.test, arg)
    if ok and earned and data.awardTrophy(entry.id) then
      won[#won + 1] = entry
    end
  end
  if def.trophies then
    for _, entry in ipairs(def.trophies) do consider(entry, inst) end
  end
  for _, entry in ipairs(GLOBAL) do consider(entry, api) end
  return won
end

---------------------------------------------------------------- trophy toast
--- Consoles announce an achievement the moment it happens, not in a summary
--- afterwards, because the announcement is the reward. GameOS used to list
--- them only on the game-over card, which meant a trophy earned in the first
--- minute went unmentioned until the run was over.
---
--- awardTrophies is already idempotent -- it skips anything held -- so it can
--- simply be run during play and whatever it returns is newly earned.
local TROPHY_ICON = gfx.makeGlyph({
  "..######..",
  "..######..",
  "#..####..#",
  "#..####..#",
  ".#.####.#.",
  "...####...",
  "..######..",
  ".########.",
})

local Toasts = {}
Toasts.__index = Toasts

local function newToasts()
  return setmetatable({ queue = {}, showing = nil, t = 0 }, Toasts)
end

function Toasts:add(entry) self.queue[#self.queue + 1] = entry end

function Toasts:update(dt)
  if not self.showing then
    if #self.queue == 0 then return end
    self.showing = table.remove(self.queue, 1)
    self.t = 0
    audio.play("ui.trophy")
    return
  end
  self.t = self.t + dt
  if self.t > 3.0 then
    self.showing = nil
    self.t = 0
  end
end

function Toasts:draw()
  local entry = self.showing
  if not entry then return end
  local w = 24
  -- slide in, hold, slide out, so it never simply blinks into existence
  local slide
  if self.t < 0.25 then
    slide = 1 - self.t / 0.25
  elseif self.t > 2.75 then
    slide = (self.t - 2.75) / 0.25
  else
    slide = 0
  end
  local x = gfx.W - w + floor(slide * (w + 1) + 0.5)
  if x > gfx.W then return end

  gfx.fill(x, 2, w, 4, colors.gray)
  gfx.blitGlyph(x + 1, 3, TROPHY_ICON, colors.yellow, colors.gray)
  gfx.text(x + 7, 3, gfx.clip("TROPHY", w - 8), colors.yellow, colors.gray)
  gfx.text(x + 7, 4, gfx.clip(entry.name, w - 8), colors.white, colors.gray)
end

------------------------------------------------------------ game over card
local function gameOverCard(def, inst, rank, best, trophies)
  local summary = {}
  if inst.summary then
    local ok, rows = pcall(inst.summary, inst)
    if ok and type(rows) == "table" then summary = rows end
  end
  if #summary > 4 then
    for i = #summary, 5, -1 do summary[i] = nil end
  end

  local won = inst.won and true or false
  local title = won and "YOU WIN" or "GAME OVER"
  local accent = won and colors.lime or (def.accent or colors.red)
  if rank == 1 then
    title = "RECORD!"
    accent = colors.yellow
  end

  trophies = trophies or {}
  -- 44 cells wide is what "GAME OVER" needs at double scale in the pixel font
  local w = 44
  local h = 10 + #summary + #trophies
  local x = floor((gfx.W - w) / 2) + 1
  local y = floor((gfx.H - h) / 2) + 1

  local titleCanvas = Canvas.new(x + 1, y, w - 2, 4, colors.gray)
  local buttons = { "Retry", "Menu" }
  local sel = 1
  local blink = 0
  local rects

  local function draw()
    gfx.fill(x + 1, y + 1, w, h, colors.black)
    gfx.fill(x, y, w, h, colors.gray)

    titleCanvas:clear(colors.gray)
    local flash = (rank == 1 and floor(blink * 3) % 2 == 1) and colors.white or accent
    font.centerShadow(titleCanvas, 2, title, flash, colors.black, 2, 1)
    titleCanvas:render()

    local iy = y + 5
    gfx.fill(x + 2, iy, w - 4, 1, colors.gray)
    if not inst.noScore then
      gfx.text(x + 3, iy, def.scoreLabel or "SCORE", colors.lightGray, colors.gray)
      gfx.right(x + w - 3, iy, gfx.commas(inst.score or 0), accent, colors.gray)
      gfx.text(x + 3, iy + 1, "BEST", colors.lightGray, colors.gray)
      gfx.right(x + w - 3, iy + 1, gfx.commas(best), colors.white, colors.gray)
    else
      gfx.center(iy, def.scoreLabel or "", colors.lightGray, colors.gray, x, w)
    end

    for i = 1, #summary do
      local row = summary[i]
      local ry = iy + 2 + (i - 1)
      gfx.text(x + 3, ry, gfx.clip(tostring(row[1]), 16), colors.lightGray, colors.gray)
      gfx.right(x + w - 3, ry, gfx.clip(tostring(row[2]), 12), colors.white, colors.gray)
    end

    local ry = iy + 2 + #summary
    for i = 1, #trophies do
      local flash = floor(blink * 3) % 2 == 0 and colors.yellow or colors.white
      gfx.fill(x + 2, ry, w - 4, 1, colors.gray)
      gfx.text(x + 3, ry, "TROPHY", flash, colors.gray)
      gfx.right(x + w - 3, ry, gfx.clip(trophies[i].name, 22), colors.white, colors.gray)
      ry = ry + 1
    end
    if rank and rank > 1 then
      gfx.center(ry, "ranked #" .. rank, colors.lightGray, colors.gray, x, w)
    end

    rects = {}
    local total = 0
    for i = 1, #buttons do total = total + #buttons[i] + 4 end
    total = total + 2
    local bx = x + floor((w - total) / 2)
    local by = y + h - 2
    for i = 1, #buttons do
      local bw = #buttons[i] + 4
      rects[i] = { x = bx, y = by, w = bw }
      local on = (i == sel)
      local bbg = on and accent or colors.lightGray
      gfx.fill(bx, by, bw, 1, bbg)
      gfx.center(by, buttons[i], on and gfx.contrast(accent) or colors.gray, bbg, bx, bw)
      bx = bx + bw + 2
    end
  end

  local function handle(ev)
    local name = ev[1]
    if name == "key" then
      local k = ev[2]
      if k == keys.left or k == keys.a then
        sel = sel > 1 and sel - 1 or #buttons
        audio.play("ui.move")
      elseif k == keys.right or k == keys.d or k == keys.tab then
        sel = sel < #buttons and sel + 1 or 1
        audio.play("ui.move")
      elseif k == keys.enter or k == keys.space or k == keys.numPadEnter then
        audio.play("ui.select")
        return sel
      elseif k == keys.r then
        audio.play("ui.select")
        return 1
      elseif k == keys.backspace or k == keys.q then
        audio.play("ui.back")
        return 2
      end
    elseif name == "mouse_click" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      for i = 1, #rects do
        local r = rects[i]
        if my == r.y and mx >= r.x and mx < r.x + r.w then
          audio.play("ui.select")
          return i
        end
      end
    end
    return nil
  end

  -- animate the record flash while waiting
  local pump = os.startTimer(0.12)
  while true do
    gfx.beginFrame()
    draw()
    gfx.endFrame()
    local ev = { os.pullEventRaw() }
    if ev[1] == "timer" and ev[2] == pump then
      pump = os.startTimer(0.12)
      blink = blink + 0.12
      audio.update(os.clock())
    elseif ev[1] == "terminate" then
      return 2
    else
      local r = handle(ev)
      if r then
        os.cancelTimer(pump)
        return r
      end
    end
  end
end

----------------------------------------------------------------- one session
--- Returns "retry" or "menu".
local function session(def, api, mode)
  local ok, inst = pcall(def.new, api, mode)
  if not ok or type(inst) ~= "table" then
    return crash(def, ok and "new() returned no instance" or inst)
  end

  input.reset()
  -- Simon asks you to listen, so it is the one game that runs in silence
  if def.music then audio.playMusic(def.music) else audio.stopMusic() end
  audio.play("ui.launch")

  local startClock = os.clock()
  local last = startClock
  local timer = os.startTimer(TICK)
  local showFps = data.get("showFps")
  local fpsAcc, fpsFrames, fps = 0, 0, 0
  local outcome = nil

  --- Every way out of the loop below has to release whatever the game took
  --- hold of. That matters most for a networked match: leaving without
  --- disposing keeps the modem channels open and, worse, denies the other
  --- console the goodbye that would end its match cleanly instead of after a
  --- five second timeout.
  local released = false
  local function release()
    if released then return end       -- disposing twice would be a surprise
    released = true
    if inst.dispose then pcall(inst.dispose, inst) end
  end
  local function bail(err)
    release()
    return crash(def, err)
  end

  local toasts = newToasts()
  local trophyTimer = 0
  local earned = {}          -- everything won this session, for the card

  while not outcome do
    local ev = { os.pullEventRaw() }
    local name = ev[1]

    if name == "timer" and ev[2] == timer then
      timer = os.startTimer(TICK)
      local nowClock = os.clock()
      local dt = nowClock - last
      last = nowClock
      if dt <= 0 then dt = TICK end
      if dt > 0.25 then dt = 0.25 end
      audio.update(nowClock)

      local uok, uerr = pcall(inst.update, inst, dt)
      if not uok then return bail(uerr) end

      -- Twice a second is often enough to feel immediate and rare enough
      -- that the predicates cost nothing.
      trophyTimer = trophyTimer + dt
      if trophyTimer >= 0.5 then
        trophyTimer = 0
        local fresh = awardTrophies(def, inst, api)
        for i = 1, #fresh do
          earned[#earned + 1] = fresh[i]
          toasts:add(fresh[i])
        end
      end
      toasts:update(dt)

      gfx.beginFrame()
      local dok, derr = pcall(inst.draw, inst)
      if not dok then
        gfx.endFrame()
        return bail(derr)
      end
      if showFps then
        fpsAcc = fpsAcc + dt
        fpsFrames = fpsFrames + 1
        if fpsAcc >= 0.5 then
          fps = floor(fpsFrames / fpsAcc + 0.5)
          fpsAcc, fpsFrames = 0, 0
        end
        gfx.right(gfx.W, 1, string.format("%2d", fps), colors.lime, colors.black)
      end
      toasts:draw()
      gfx.endFrame()
      input.endFrame()

      if inst.quit then
        outcome = "abandon"
      elseif inst.finished then
        outcome = "over"
      end

    elseif name == "key" then
      local k, held = ev[2], ev[3]
      -- A networked game cannot afford a blocking pause menu: the event loop
      -- stops, heartbeats stop with it, and the other console decides we
      -- dropped out. Such a game sets suppressPause and draws its own overlay
      -- instead, which keeps the link alive.
      if k == keys.p and not held and not inst.suppressPause then
        local choice = pauseMenu(def, api)
        input.reset()
        os.cancelTimer(timer)
        timer = os.startTimer(TICK)
        last = os.clock()
        if choice == "restart" then
          release()
          return "retry"
        elseif choice == "quit" then
          outcome = "abandon"
        end
      else
        input.onKey(k, held)
        if inst.onKey then
          local kok, kerr = pcall(inst.onKey, inst, k, held)
          if not kok then return bail(kerr) end
        end
      end

    elseif name == "key_up" then
      input.onKeyUp(ev[2])

    elseif name == "char" then
      input.onChar(ev[2])
      if inst.onChar then pcall(inst.onChar, inst, ev[2]) end

    elseif name == "mouse_click" or name == "mouse_up" or name == "mouse_drag" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      input.onMouse(name, ev[2], mx, my)
      if inst.onMouse then
        local mok, merr = pcall(inst.onMouse, inst, name, ev[2], mx, my)
        if not mok then return bail(merr) end
      end

    elseif name == "mouse_scroll" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      if inst.onMouse then pcall(inst.onMouse, inst, "mouse_scroll", ev[2], mx, my) end

    elseif name == "monitor_touch" then
      -- A touch has no press-and-release pair, so send both halves at once:
      -- games that wait for the release (2048's swipe) would otherwise never
      -- see the gesture finish on an advanced monitor.
      local mx, my = ui.toLocal(ev[3], ev[4])
      input.onMouse("mouse_click", 1, mx, my)
      if inst.onMouse then
        pcall(inst.onMouse, inst, "mouse_click", 1, mx, my)
        pcall(inst.onMouse, inst, "mouse_up", 1, mx, my)
      end

    elseif name == "term_resize" then
      if not gfx.handleResize() then outcome = "abandon" end

    elseif name == "terminate" then
      outcome = "abandon"

    elseif inst.onEvent then
      -- Anything the console itself does not consume -- modem traffic above
      -- all -- is offered to the game whole.
      local eok, eerr = pcall(inst.onEvent, inst, ev)
      if not eok then return bail(eerr) end
    end
  end

  os.cancelTimer(timer)
  -- Give the game a chance to let go of anything outside itself -- an open
  -- modem channel, above all -- before the session is torn down.
  release()
  audio.stopMusic()
  local elapsed = os.clock() - startClock
  data.recordPlay(def.id, elapsed)

  -- Anything the periodic check has not seen yet -- a trophy for finishing,
  -- above all -- plus everything already toasted, so the card is complete.
  local trophies = awardTrophies(def, inst, api)
  for i = 1, #earned do trophies[#trophies + 1] = earned[i] end

  if outcome == "abandon" then
    data.flush()
    return "menu"
  end

  local rank = nil
  if not inst.noScore then
    rank = data.submit(def.id, inst.score or 0, def.lowerIsBetter)
  end
  local best = data.best(def.id)

  audio.play(inst.won and "result.win" or "result.lose")
  if #trophies > 0 then audio.play("ui.trophy") end

  -- a new number one earns the arcade name entry
  if rank == 1 and (inst.score or 0) > 0 then
    local previous = data.scores(def.id)[2]
    local who = ui.initials(" " .. def.name .. " ", def.accent or colors.yellow,
      previous and previous.who)
    data.nameScore(def.id, 1, who)
  end
  data.flush()

  local choice = gameOverCard(def, inst, rank, best, trophies)
  return choice == 1 and "retry" or "menu"
end

--------------------------------------------------------------------- entry
function runtime.play(def, api)
  local mode = nil
  if def.modes and #def.modes > 0 then
    if #def.modes == 1 then
      mode = def.modes[1]
    else
      local items = {}
      for i = 1, #def.modes do
        items[i] = { label = def.modes[i].name, hint = def.modes[i].hint }
      end
      local prog = data.progress(def.id)
      local pick = ui.picker({
        title = " " .. def.name .. " ",
        items = items,
        accent = def.accent or colors.lightBlue,
        default = prog.lastMode or 1,
        width = 32,
        footer = "Enter to start, Q to go back",
      })
      if pick == 0 then return end
      mode = def.modes[pick]
      prog.lastMode = pick
      data.markDirty()
    end
  end

  -- A game may need to ask something extra before it starts (Sokoban's level
  -- select). That happens here rather than inside new(), so constructing an
  -- instance never blocks on a dialog.
  if def.configure then
    local ok, adjusted = pcall(def.configure, api, mode)
    if not ok then
      crash(def, adjusted)
      return
    end
    if adjusted == false then return end
    if type(adjusted) == "table" then mode = adjusted end
  end

  local prog = data.progress(def.id)
  if not prog.seenControls and def.controls and #def.controls > 0 then
    ui.controls(def)
    prog.seenControls = true
    data.markDirty()
  end

  while true do
    local again = session(def, api, mode)
    if again ~= "retry" then break end
    if ui.terminated then break end
  end
  data.flush()
end

return runtime
]=])
file("gameos/lib/sfx.lua", [=[
--[[ sfx -- every sound the console makes.

  An effect is a list of { delay, instrument, pitch, volume } events. Delays
  are in seconds from the moment the effect is triggered; the engine schedules
  them, so a long sound costs nothing extra at the point it is played.

  The shapes below are the vocabulary everything is built from:

    blip    one note
    rise    pitch climbing, gaining volume     -- something good happened
    fall    pitch dropping, losing volume      -- something was lost
    stab    several instruments on one beat    -- impact
    chord   notes struck together, lightly spread
    roll    a note repeating and fading        -- decay tail
    thump   drum layered under a pitched note  -- weight
]]

local req = ...
local audio = req("lib.audio")

local sfx = {}
local M = {}

local P = audio.pitch
local floor = math.floor

------------------------------------------------------------------- shapes
local function blip(inst, pitch, vol, at)
  return { { at or 0, inst, P(pitch), vol } }
end

local function rise(inst, from, to, count, step, vol, gain)
  local out = {}
  local a, b = P(from), P(to)
  for i = 0, count - 1 do
    local k = count > 1 and i / (count - 1) or 0
    out[#out + 1] = { i * step, inst, a + (b - a) * k, vol * (1 + (gain or 0.3) * k) }
  end
  return out
end

local function fall(inst, from, to, count, step, vol)
  local out = {}
  local a, b = P(from), P(to)
  for i = 0, count - 1 do
    local k = count > 1 and i / (count - 1) or 0
    out[#out + 1] = { i * step, inst, a + (b - a) * k, vol * (1 - 0.55 * k) }
  end
  return out
end

local function roll(inst, pitch, count, step, vol, falloff)
  local out = {}
  local p = P(pitch)
  for i = 0, count - 1 do
    out[#out + 1] = { i * step, inst, p, vol * ((falloff or 0.6) ^ i) }
  end
  return out
end

local function chord(inst, pitches, vol, spread)
  local out = {}
  for i = 1, #pitches do
    out[#out + 1] = { (i - 1) * (spread or 0.02), inst, P(pitches[i]), vol }
  end
  return out
end

--- Merge several shapes, optionally offsetting the later ones in time.
local function mix(...)
  local out = {}
  for i = 1, select("#", ...) do
    local part = select(i, ...)
    for j = 1, #part do
      out[#out + 1] = part[j]
    end
  end
  return out
end

local function shift(part, seconds)
  local out = {}
  for i = 1, #part do
    local e = part[i]
    out[i] = { e[1] + seconds, e[2], e[3], e[4] }
  end
  return out
end

local function stab(pitch, vol)
  return {
    { 0, "basedrum", P(pitch), vol },
    { 0, "bit", P(pitch) + 12, vol * 0.55 },
  }
end

local function thump(inst, pitch, vol)
  return {
    { 0, "basedrum", 2, vol * 0.9 },
    { 0, inst, P(pitch), vol },
  }
end

sfx.blip, sfx.rise, sfx.fall, sfx.roll = blip, rise, fall, roll
sfx.chord, sfx.mix, sfx.shift, sfx.stab, sfx.thump = chord, mix, shift, stab, thump

--============================================================== the console
-- Navigation is deliberately quiet and dry: it happens constantly.
M["ui.move"]     = blip("hat", "D5", 0.20)
M["ui.select"]   = { { 0, "pling", P("D4"), 0.42 }, { 0.05, "pling", P("A4"), 0.46 } }
M["ui.back"]     = { { 0, "pling", P("A4"), 0.36 }, { 0.05, "pling", P("D4"), 0.32 } }
M["ui.deny"]     = { { 0, "bass", P("AS3"), 0.5 }, { 0.07, "bass", P("G3"), 0.45 } }
M["ui.open"]     = rise("bell", "D4", "A4", 3, 0.045, 0.34)
M["ui.close"]    = fall("bell", "A4", "D4", 3, 0.045, 0.32)
M["ui.page"]     = blip("hat", "A4", 0.24)
M["ui.type"]     = blip("bit", "A4", 0.28)
M["ui.launch"]   = mix(
  rise("bit", "D4", "D5", 5, 0.035, 0.3),
  shift(chord("pling", { "D4", "FS4", "A4" }, 0.4), 0.18))
M["ui.trophy"]   = mix(
  chord("bell", { "D4", "FS4", "A4" }, 0.5, 0.05),
  shift(chord("bell", { "A4", "CS5", "E5" }, 0.55, 0.05), 0.22),
  shift(blip("chime", "D5", 0.6), 0.44))
M["ui.record"]   = mix(
  rise("chime", "D4", "D5", 6, 0.06, 0.4),
  shift(chord("bell", { "D5", "FS5" }, 0.6), 0.4))

M["boot.chime"]  = mix(
  { { 0.00, "bit", P("D4"), 0.35 }, { 0.10, "bit", P("A4"), 0.40 },
    { 0.20, "bit", P("D5"), 0.45 } },
  shift(chord("bell", { "D4", "FS4", "A4", "D5" }, 0.5, 0.04), 0.34))
M["boot.shutdown"] = mix(
  fall("bit", "D5", "D4", 4, 0.07, 0.4),
  shift(blip("bass", "D4", 0.5), 0.3))

--============================================================== outcomes
M["result.win"] = mix(
  chord("bell", { "D4", "FS4", "A4" }, 0.5, 0.03),
  shift(chord("bell", { "E4", "GS4", "B4" }, 0.5, 0.03), 0.16),
  shift(chord("bell", { "FS4", "AS4", "CS5" }, 0.55, 0.03), 0.32),
  shift(chord("chime", { "FS4", "AS4", "CS5", "FS5" }, 0.6, 0.03), 0.52))
M["result.lose"] = mix(
  { { 0.00, "harp", P("D4"), 0.5 }, { 0.16, "harp", P("B3"), 0.5 },
    { 0.32, "harp", P("G3"), 0.5 } },
  shift(thump("bass", "FS3", 0.6), 0.5))
M["result.levelup"] = rise("bell", "D4", "D5", 5, 0.06, 0.45)
M["result.newwave"] = mix(
  chord("iron_xylophone", { "D4", "A4" }, 0.45, 0.03),
  shift(chord("iron_xylophone", { "E4", "B4" }, 0.5, 0.03), 0.14))

--============================================================== snake
M["snake.eat"]   = { { 0, "bit", P("A4"), 0.40 }, { 0.045, "bit", P("D5"), 0.44 } }
M["snake.bonus"] = mix(
  rise("chime", "D4", "D5", 4, 0.05, 0.45),
  shift(blip("bell", "FS5", 0.5), 0.22))
M["snake.grow"]  = blip("bass", "D4", 0.3)
M["snake.die"]   = mix(
  stab("FS3", 0.8),
  shift(fall("didgeridoo", "D4", "FS3", 5, 0.06, 0.5), 0.06))

--============================================================== tetris
M["tet.move"]    = blip("hat", "B4", 0.18)
M["tet.rotate"]  = { { 0, "bit", P("E4"), 0.26 }, { 0.03, "bit", P("B4"), 0.24 } }
M["tet.wallkick"] = { { 0, "bit", P("G4"), 0.24 }, { 0.035, "bit", P("D5"), 0.26 } }
M["tet.softdrop"] = blip("hat", "FS4", 0.14)
M["tet.harddrop"] = mix(
  fall("bit", "D5", "D4", 3, 0.025, 0.32),
  shift(thump("bass", "D4", 0.5), 0.07))
M["tet.lock"]    = thump("bass", "A3", 0.42)
M["tet.hold"]    = { { 0, "iron_xylophone", P("A4"), 0.4 }, { 0.05, "iron_xylophone", P("E4"), 0.36 } }
M["tet.deny"]    = blip("bass", "G3", 0.4)
M["tet.line1"]   = rise("xylophone", "D4", "A4", 3, 0.045, 0.42)
M["tet.line2"]   = rise("xylophone", "D4", "D5", 4, 0.045, 0.46)
M["tet.line3"]   = rise("xylophone", "D4", "FS5", 5, 0.045, 0.5)
M["tet.tetris"]  = mix(
  rise("xylophone", "D4", "FS5", 6, 0.04, 0.5),
  shift(chord("bell", { "D5", "FS5", "A4" }, 0.6, 0.03), 0.26),
  shift(blip("chime", "FS5", 0.55), 0.42))
M["tet.tspin"]   = mix(
  chord("iron_xylophone", { "D4", "GS4" }, 0.5, 0.03),
  shift(chord("iron_xylophone", { "E4", "AS4" }, 0.55, 0.03), 0.12),
  shift(blip("chime", "E5", 0.5), 0.26))
M["tet.b2b"]     = shift(blip("cow_bell", "D5", 0.45), 0)
M["tet.topout"]  = mix(
  stab("FS3", 0.9),
  shift(fall("bass", "D4", "FS3", 6, 0.07, 0.55), 0.05))

--============================================================== breakout
M["brk.paddle"]  = blip("bit", "A4", 0.38)
M["brk.wall"]    = blip("bit", "D4", 0.30)
-- pitch is shifted by the game to match the brick row
M["brk.brick"]   = { { 0, "xylophone", P("D4"), 0.42 } }
M["brk.tough"]   = { { 0, "iron_xylophone", P("A3"), 0.4 }, { 0.03, "hat", P("D5"), 0.2 } }
M["brk.steel"]   = blip("basedrum", 8, 0.45)
M["brk.laser"]   = fall("bit", "FS5", "D4", 4, 0.025, 0.32)
M["brk.powerup"] = rise("iron_xylophone", "D4", "D5", 4, 0.05, 0.45)
M["brk.penalty"] = fall("didgeridoo", "A4", "D4", 4, 0.05, 0.4)
M["brk.launch"]  = { { 0, "bit", P("D4"), 0.35 }, { 0.05, "bit", P("A4"), 0.38 } }
M["brk.life"]    = mix(
  stab("FS3", 0.75),
  shift(fall("bass", "A3", "FS3", 4, 0.08, 0.5), 0.08))

--============================================================== bombard
-- Artillery wants weight rather than zap: a hollow thump leaving the barrel,
-- a whistle in the air, and a real crump when it lands.
M["bmb.aim"]     = blip("hat", "D4", 0.10)
M["bmb.fire"]    = mix(
  thump("basedrum", "FS3", 0.8),
  shift(fall("didgeridoo", "D4", "FS3", 3, 0.045, 0.45), 0.03))
M["bmb.thud"]    = mix(
  blip("basedrum", 4, 0.5),
  shift(fall("bass", "A3", "FS3", 2, 0.06, 0.35), 0.03))
M["bmb.hit"]     = mix(
  stab("FS3", 0.8),
  shift(roll("snare", 5, 3, 0.06, 0.45), 0.03))
M["bmb.direct"]  = mix(
  stab("FS3", 0.95),
  shift(roll("snare", 6, 4, 0.055, 0.5), 0.02),
  shift(fall("didgeridoo", "D4", "FS3", 4, 0.07, 0.55), 0.06))
M["bmb.miss"]    = fall("flute", "D5", "D4", 5, 0.05, 0.3)
M["bmb.turn"]    = blip("pling", "D5", 0.3)
M["bmb.connect"] = rise("bell", "D4", "D5", 4, 0.07, 0.5)
M["bmb.win"]     = mix(
  rise("bell", "D4", "FS5", 5, 0.08, 0.6),
  shift(chord("harp", { "D4", "FS4", "A4" }, 0.5, 0.02), 0.24))
M["bmb.lose"]    = mix(
  fall("bass", "D4", "FS3", 5, 0.1, 0.55),
  shift(blip("snare", 2, 0.35), 0.12))

--============================================================== minesweeper
M["ms.reveal"]   = blip("hat", "A4", 0.18)
M["ms.open"]     = mix(blip("hat", "A4", 0.2), shift(blip("hat", "D5", 0.16), 0.05))
M["ms.flag"]     = { { 0, "cow_bell", P("D5"), 0.34 } }
M["ms.unflag"]   = { { 0, "cow_bell", P("A4"), 0.28 } }
M["ms.chord"]    = mix(blip("hat", "A4", 0.2), shift(blip("hat", "D5", 0.2), 0.04),
  shift(blip("hat", "FS5", 0.18), 0.08))
M["ms.boom"]     = mix(
  stab("FS3", 1.0),
  shift(roll("snare", 5, 5, 0.07, 0.55), 0.04),
  shift(fall("didgeridoo", "D4", "FS3", 6, 0.07, 0.5), 0.1))
M["ms.clear"]    = M["result.win"]

--============================================================== 2048
M["g2048.slide"] = blip("hat", "G4", 0.18)
-- shifted by the game: bigger tiles merge higher
M["g2048.merge"] = { { 0, "xylophone", P("D4"), 0.4 }, { 0.04, "xylophone", P("A4"), 0.36 } }
M["g2048.spawn"] = blip("bit", "D4", 0.2)
M["g2048.undo"]  = fall("didgeridoo", "A4", "D4", 3, 0.05, 0.35)
M["g2048.deny"]  = blip("bass", "G3", 0.34)

--============================================================== sokoban
M["sok.step"]    = blip("hat", "D4", 0.16)
M["sok.push"]    = { { 0, "bass", P("A3"), 0.34 }, { 0.04, "hat", P("D4"), 0.14 } }
M["sok.ongoal"]  = { { 0, "bell", P("D5"), 0.42 }, { 0.05, "bell", P("FS5"), 0.4 } }
M["sok.offgoal"] = { { 0, "bell", P("FS4"), 0.3 }, { 0.05, "bell", P("D4"), 0.28 } }
M["sok.blocked"] = blip("bass", "FS3", 0.34)
M["sok.undo"]    = fall("didgeridoo", "G4", "D4", 3, 0.05, 0.34)
M["sok.reset"]   = fall("bit", "D5", "D4", 4, 0.04, 0.3)
M["sok.solved"]  = M["result.win"]

--============================================================== flappy
M["fly.flap"]    = { { 0, "hat", P("D5"), 0.26 }, { 0.03, "hat", P("A4"), 0.18 } }
M["fly.score"]   = { { 0, "bit", P("A4"), 0.36 }, { 0.045, "bit", P("E5"), 0.4 } }
M["fly.hit"]     = mix(stab("A3", 0.8), shift(blip("snare", 5, 0.45), 0.02))
M["fly.fall"]    = fall("didgeridoo", "A4", "FS3", 7, 0.07, 0.45)
M["fly.medal"]   = mix(
  chord("bell", { "D4", "FS4", "A4" }, 0.5, 0.04),
  shift(blip("chime", "D5", 0.55), 0.26))

--============================================================== pong
M["png.paddle"]  = blip("bit", "A4", 0.4)
M["png.wall"]    = blip("bit", "D4", 0.32)
M["png.point"]   = rise("bit", "D4", "A4", 3, 0.05, 0.42)
M["png.against"] = fall("bit", "A4", "D4", 3, 0.05, 0.38)
M["png.serve"]   = blip("hat", "D5", 0.22)

--============================================================== meteors
M["met.fire"]    = fall("bit", "FS5", "D5", 3, 0.02, 0.3)
M["met.thrust"]  = blip("hat", "FS3", 0.12)
M["met.rock1"]   = mix(blip("snare", 10, 0.34), blip("bit", "FS4", 0.24))
M["met.rock2"]   = mix(blip("snare", 6, 0.4), blip("bit", "D4", 0.26))
M["met.rock3"]   = mix(blip("basedrum", 4, 0.5), blip("snare", 3, 0.36))
M["met.ufo"]     = { { 0, "didgeridoo", P("D4"), 0.3 }, { 0.12, "didgeridoo", P("A3"), 0.3 } }
M["met.ufohit"]  = mix(rise("chime", "D4", "FS5", 4, 0.04, 0.5), blip("snare", 8, 0.4))
M["met.hyper"]   = mix(
  rise("bit", "D4", "FS5", 6, 0.03, 0.3),
  shift(fall("bit", "FS5", "D4", 6, 0.03, 0.3), 0.18))
M["met.die"]     = mix(
  stab("FS3", 1.0),
  shift(roll("snare", 6, 5, 0.08, 0.5), 0.05),
  shift(fall("didgeridoo", "A4", "FS3", 6, 0.09, 0.5), 0.12))
M["met.extra"]   = rise("chime", "D4", "D5", 5, 0.05, 0.5)

--============================================================== lights out
M["lo.on"]       = { { 0, "bell", P("A4"), 0.36 }, { 0.04, "bell", P("E5"), 0.34 } }
M["lo.off"]      = { { 0, "bell", P("E4"), 0.3 }, { 0.04, "bell", P("A3"), 0.28 } }
M["lo.solved"]   = mix(
  rise("chime", "D4", "D5", 5, 0.05, 0.45),
  shift(chord("bell", { "D5", "FS5" }, 0.55, 0.03), 0.28))

--============================================================== simon
-- the four panels; the game plays these directly by index
M["sim.pad1"]    = blip("harp", "D4", 0.7)
M["sim.pad2"]    = blip("harp", "G4", 0.7)
M["sim.pad3"]    = blip("harp", "B4", 0.7)
M["sim.pad4"]    = blip("harp", "D5", 0.7)
M["sim.wrong"]   = mix(
  { { 0, "didgeridoo", P("G3"), 0.6 }, { 0.1, "didgeridoo", P("FS3"), 0.55 } },
  blip("snare", 2, 0.4))
M["sim.round"]   = { { 0, "bit", P("D5"), 0.34 }, { 0.05, "bit", P("A4"), 0.3 } }

--============================================================== connect four
M["c4.move"]     = blip("hat", "A4", 0.18)
M["c4.drop"]     = mix(
  fall("bit", "A4", "D4", 3, 0.03, 0.28),
  shift(thump("bass", "D4", 0.42), 0.08))
M["c4.think"]    = blip("hat", "D4", 0.1)
M["c4.full"]     = blip("bass", "G3", 0.34)
M["c4.win"]      = M["result.win"]
M["c4.lose"]     = M["result.lose"]
M["c4.draw"]     = { { 0, "iron_xylophone", P("D4"), 0.4 }, { 0.14, "iron_xylophone", P("D4"), 0.35 } }

------------------------------------------------------------------- lookup
sfx.table = M

function sfx.get(name) return M[name] end

function sfx.names()
  local out = {}
  for name in pairs(M) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- Longest effect, in seconds: used by the sound test to pace auditions.
function sfx.duration(name)
  local def = M[name]
  if not def then return 0 end
  local last = 0
  for i = 1, #def do
    if def[i][1] > last then last = def[i][1] end
  end
  return last
end

return sfx
]=])
file("gameos/lib/ui.lua", [=[
--[[ ui -- modal dialogs and list pickers shared by the shell and the runtime.

  Dialogs are blocking: they draw on top of whatever is already in the frame
  buffer and run their own event loop until dismissed. The caller is expected
  to redraw its own screen afterwards.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")

local ui = {}

ui.terminated = false

local floor = math.floor

------------------------------------------------------------------- chrome
--- Dialog shell: shadow, body, title bar. Returns the inner content rect.
function ui.frame(x, y, w, h, title, accent)
  accent = accent or colors.blue
  gfx.fill(x + 1, y + 1, w, h, colors.black)
  gfx.fill(x, y, w, h, colors.gray)
  if title then
    gfx.fill(x, y, w, 1, accent)
    gfx.center(y, title, gfx.contrast(accent), accent, x, w)
    return x + 2, y + 2, w - 4, h - 3
  end
  return x + 2, y + 1, w - 4, h - 2
end

local function buttonRects(buttons, x0, w, y)
  local widths, total = {}, 0
  for i = 1, #buttons do
    widths[i] = #buttons[i] + 2
    total = total + widths[i]
  end
  total = total + 2 * (#buttons - 1)
  local x = x0 + floor((w - total) / 2)
  local rects = {}
  for i = 1, #buttons do
    rects[i] = { x = x, y = y, w = widths[i], label = buttons[i] }
    x = x + widths[i] + 2
  end
  return rects
end

local function drawButtons(rects, selected, accent)
  for i = 1, #rects do
    local r = rects[i]
    local on = (i == selected)
    local bg = on and accent or colors.lightGray
    gfx.fill(r.x, r.y, r.w, 1, bg)
    gfx.center(r.y, r.label, on and gfx.contrast(accent) or colors.gray, bg, r.x, r.w)
  end
end

local function hitTest(rects, x, y)
  for i = 1, #rects do
    local r = rects[i]
    if y == r.y and x >= r.x and x < r.x + r.w then return i end
  end
  return nil
end

--- Screen coordinates -> design-surface coordinates.
function ui.toLocal(x, y)
  return x - (gfx.offX or 0), y - (gfx.offY or 0)
end

-------------------------------------------------------------- generic loop
--- Runs draw/handle until handle returns non-nil. Pumps audio so queued
--- effects keep playing while a dialog is open.
function ui.loop(draw, handle)
  local pump = os.startTimer(0.1)
  while true do
    gfx.beginFrame()
    draw()
    gfx.endFrame()
    local ev = { os.pullEventRaw() }
    local name = ev[1]
    if name == "timer" and ev[2] == pump then
      pump = os.startTimer(0.1)
      audio.update(os.clock())
    elseif name == "terminate" then
      ui.terminated = true
      return 0
    else
      local result = handle(ev)
      if result ~= nil then
        os.cancelTimer(pump)
        return result
      end
    end
  end
end

------------------------------------------------------------------- dialogs
--- opts: title, body (list of strings), buttons (list), accent, default,
---       width, cancel (index returned on back / 0 to disallow)
function ui.dialog(opts)
  local title = opts.title
  local body = opts.body or {}
  local buttons = opts.buttons or { "OK" }
  local accent = opts.accent or colors.lightBlue
  local sel = opts.default or 1

  local w = opts.width or 0
  if w == 0 then
    if title then w = #title + 6 end
    for i = 1, #body do if #body[i] + 6 > w then w = #body[i] + 6 end end
    local btotal = 0
    for i = 1, #buttons do btotal = btotal + #buttons[i] + 4 end
    if btotal + 4 > w then w = btotal + 4 end
    if w < 22 then w = 22 end
    if w > 45 then w = 45 end
  end
  local h = 2 + #body + 2
  if h > gfx.H - 2 then h = gfx.H - 2 end
  local x = floor((gfx.W - w) / 2) + 1
  local y = floor((gfx.H - h) / 2) + 1

  local rects
  local function draw()
    local ix, iy, iw = ui.frame(x, y, w, h, title, accent)
    for i = 1, #body do
      gfx.center(iy + i - 1, gfx.clip(body[i], iw), colors.white, colors.gray, ix, iw)
    end
    rects = buttonRects(buttons, x, w, y + h - 2)
    drawButtons(rects, sel, accent)
  end

  local function handle(ev)
    local name = ev[1]
    if name == "key" then
      local k = ev[2]
      if k == keys.left or k == keys.a then
        sel = sel > 1 and sel - 1 or #buttons
        audio.play("ui.move")
      elseif k == keys.right or k == keys.d or k == keys.tab then
        sel = sel < #buttons and sel + 1 or 1
        audio.play("ui.move")
      elseif k == keys.enter or k == keys.space or k == keys.numPadEnter then
        audio.play("ui.select")
        return sel
      elseif k == keys.backspace or k == keys.q then
        if opts.cancel ~= 0 then
          audio.play("ui.back")
          return opts.cancel or 0
        end
      end
    elseif name == "mouse_scroll" then
      local dir = ev[2]
      local n = sel + dir
      if n >= 1 and n <= #buttons then
        sel = n
        audio.play("ui.move")
      end
    elseif name == "mouse_click" then
      -- right-click reads as "back" everywhere in the interface
      if ev[2] == 2 and opts.cancel ~= 0 then
        audio.play("ui.back")
        return opts.cancel or 0
      end
      local mx, my = ui.toLocal(ev[3], ev[4])
      local i = hitTest(rects, mx, my)
      if i then
        sel = i
        audio.play("ui.select")
        return i
      end
    end
    return nil
  end

  return ui.loop(draw, handle)
end

function ui.alert(title, body, accent)
  if type(body) == "string" then body = { body } end
  return ui.dialog({ title = title, body = body, buttons = { "OK" }, accent = accent })
end

function ui.confirm(title, body, yes, no, accent)
  if type(body) == "string" then body = { body } end
  local r = ui.dialog({
    title = title, body = body, accent = accent or colors.orange,
    buttons = { yes or "Yes", no or "No" }, default = 2, cancel = 2,
  })
  return r == 1
end

------------------------------------------------------------------- pickers
--- opts: title, items (list of {label, hint} or strings), accent, default,
---       width, rows, footer
function ui.picker(opts)
  local items = opts.items or {}
  local accent = opts.accent or colors.lightBlue
  local sel = opts.default or 1
  if sel > #items then sel = 1 end

  local function labelOf(i)
    local it = items[i]
    if type(it) == "string" then return it end
    return it.label or "?"
  end
  local function hintOf(i)
    local it = items[i]
    if type(it) == "table" then return it.hint end
    return nil
  end

  local w = opts.width or 0
  if w == 0 then
    if opts.title then w = #opts.title + 6 end
    for i = 1, #items do
      local n = #labelOf(i) + 6
      local hint = hintOf(i)
      if hint then n = n + #hint + 2 end
      if n > w then w = n end
    end
    if w < 24 then w = 24 end
    if w > 45 then w = 45 end
  end

  local rows = opts.rows or #items
  if rows > 11 then rows = 11 end
  if rows > #items then rows = #items end
  if rows < 1 then rows = 1 end
  local h = 3 + rows + (opts.footer and 1 or 0)
  local x = floor((gfx.W - w) / 2) + 1
  local y = floor((gfx.H - h) / 2) + 1
  local top = 1

  local function clampView()
    if sel < top then top = sel end
    if sel > top + rows - 1 then top = sel - rows + 1 end
    if top > #items - rows + 1 then top = #items - rows + 1 end
    if top < 1 then top = 1 end
  end

  local function draw()
    clampView()
    local ix, iy, iw = ui.frame(x, y, w, h, opts.title, accent)
    for r = 0, rows - 1 do
      local i = top + r
      local ry = iy + r
      if i <= #items then
        local on = (i == sel)
        local bg = on and accent or colors.gray
        local fg = on and gfx.contrast(accent) or colors.white
        gfx.fill(ix - 1, ry, iw + 2, 1, bg)
        gfx.text(ix, ry, gfx.clip(labelOf(i), iw), fg, bg)
        local hint = hintOf(i)
        if hint then
          gfx.right(ix + iw - 1, ry, gfx.clip(hint, 12), on and gfx.contrast(accent) or colors.lightGray, bg)
        end
      end
    end
    if #items > rows then
      local barY = iy + floor((sel - 1) / #items * rows)
      gfx.fill(x + w - 1, iy, 1, rows, colors.black)
      gfx.fill(x + w - 1, barY, 1, 1, accent)
    end
    if opts.footer then
      gfx.center(y + h - 1, gfx.clip(opts.footer, w - 2), colors.lightGray, colors.gray, x, w)
    end
  end

  local function handle(ev)
    local name = ev[1]
    if name == "key" then
      local k = ev[2]
      if k == keys.up or k == keys.w then
        sel = sel > 1 and sel - 1 or #items
        audio.play("ui.move")
      elseif k == keys.down or k == keys.s then
        sel = sel < #items and sel + 1 or 1
        audio.play("ui.move")
      elseif k == keys.pageUp then
        sel = math.max(1, sel - rows)
      elseif k == keys.pageDown then
        sel = math.min(#items, sel + rows)
      elseif k == keys.home then
        sel = 1
      elseif k == keys["end"] then
        sel = #items
      elseif k == keys.enter or k == keys.space or k == keys.numPadEnter then
        audio.play("ui.select")
        return sel
      elseif k == keys.backspace or k == keys.q then
        audio.play("ui.back")
        return 0
      end
    elseif name == "mouse_scroll" then
      local dir = ev[2]
      sel = math.min(#items, math.max(1, sel + dir))
    elseif name == "mouse_click" then
      if ev[2] == 2 then
        audio.play("ui.back")
        return 0
      end
      local mx, my = ui.toLocal(ev[3], ev[4])
      local row = my - (y + 2)
      if row >= 0 and row < rows and mx >= x and mx < x + w then
        local i = top + row
        if i <= #items then
          if i == sel then
            audio.play("ui.select")
            return i
          end
          sel = i
          audio.play("ui.move")
        end
      elseif mx < x or mx >= x + w or my < y or my >= y + h then
        audio.play("ui.back")
        return 0
      end
    end
    return nil
  end

  return ui.loop(draw, handle)
end

------------------------------------------------------------- transition
--- Bars sweep in from both edges, meet, and sweep out again. Used between
--- the launcher and a game so screens do not just snap.
function ui.transition(accent)
  accent = accent or colors.lightBlue
  local half = math.ceil(gfx.W / 2)
  local steps = 7
  local timer = os.startTimer(0.03)
  local step = 0
  local closing = true
  while true do
    local ev = { os.pullEventRaw() }
    if ev[1] == "terminate" then return end
    if ev[1] == "timer" and ev[2] == timer then
      timer = os.startTimer(0.03)
      step = step + 1
      local k = step / steps
      if k > 1 then
        if closing then
          closing = false
          step = 0
        else
          os.cancelTimer(timer)
          return
        end
        k = 1
      end
      local width = closing and floor(half * k) or floor(half * (1 - k))
      gfx.beginFrame()
      if closing then
        gfx.fill(1, 1, width, gfx.H, accent)
        gfx.fill(gfx.W - width + 1, 1, width, gfx.H, accent)
      else
        gfx.clear(colors.black)
        gfx.fill(1, 1, width, gfx.H, accent)
        gfx.fill(gfx.W - width + 1, 1, width, gfx.H, accent)
      end
      gfx.endFrame()
    end
  end
end

--------------------------------------------------------------- name entry
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .-!"

--- Arcade style three-letter entry for a new number one score.
function ui.initials(title, accent, previous)
  accent = accent or colors.yellow
  local letters = { 1, 1, 1 }
  if previous and #previous >= 3 then
    for i = 1, 3 do
      local at = ALPHABET:find(previous:sub(i, i), 1, true)
      letters[i] = at or 1
    end
  end
  local slot = 1
  local blink = 0

  local w, h = 30, 8
  local x = floor((gfx.W - w) / 2) + 1
  local y = floor((gfx.H - h) / 2) + 1

  local function text()
    local out = {}
    for i = 1, 3 do out[i] = ALPHABET:sub(letters[i], letters[i]) end
    return table.concat(out)
  end

  local function draw()
    local ix, iy, iw = ui.frame(x, y, w, h, title, accent)
    gfx.center(iy, "new record -- your initials", colors.lightGray, colors.gray, ix, iw)
    local slotW = 5
    local total = slotW * 3 + 4
    local bx = x + floor((w - total) / 2)
    for i = 1, 3 do
      local sx = bx + (i - 1) * (slotW + 2)
      local on = (i == slot)
      local bg = on and accent or colors.lightGray
      gfx.fill(sx, iy + 2, slotW, 3, bg)
      local ch = ALPHABET:sub(letters[i], letters[i])
      gfx.center(iy + 3, ch, on and gfx.contrast(accent) or colors.gray, bg, sx, slotW)
      if on and floor(blink * 3) % 2 == 0 then
        gfx.fill(sx, iy + 2, slotW, 1, colors.white)
      end
    end
    gfx.center(y + h - 1, "Up/Dn letter   Enter done", colors.lightGray, colors.gray, x, w)
  end

  local function handle(ev)
    if ev[1] ~= "key" and ev[1] ~= "char" then return nil end
    if ev[1] == "char" then
      local at = ALPHABET:find(ev[2]:upper(), 1, true)
      if at then
        letters[slot] = at
        if slot < 3 then slot = slot + 1 end
        audio.play("ui.move")
      end
      return nil
    end
    local k = ev[2]
    if k == keys.up or k == keys.w then
      letters[slot] = letters[slot] % #ALPHABET + 1
      audio.play("ui.move")
    elseif k == keys.down or k == keys.s then
      letters[slot] = (letters[slot] - 2) % #ALPHABET + 1
      audio.play("ui.move")
    elseif k == keys.left or k == keys.a then
      slot = slot > 1 and slot - 1 or 3
    elseif k == keys.right or k == keys.d or k == keys.tab then
      slot = slot < 3 and slot + 1 or 1
    elseif k == keys.backspace then
      letters[slot] = 1
    elseif k == keys.enter or k == keys.numPadEnter or k == keys.space then
      audio.play("ui.select")
      return text()
    end
    return nil
  end

  local pump = os.startTimer(0.12)
  while true do
    gfx.beginFrame()
    draw()
    gfx.endFrame()
    local ev = { os.pullEventRaw() }
    if ev[1] == "timer" and ev[2] == pump then
      pump = os.startTimer(0.12)
      blink = blink + 0.12
      audio.update(os.clock())
    elseif ev[1] == "terminate" then
      return text()
    else
      local result = handle(ev)
      if result then
        os.cancelTimer(pump)
        return result
      end
    end
  end
end

--------------------------------------------------------------- controls card
function ui.controls(def)
  local list = def.controls or {}
  local w = 40
  local h = 3 + #list + 2
  if h > gfx.H then h = gfx.H end
  local x = floor((gfx.W - w) / 2) + 1
  local y = floor((gfx.H - h) / 2) + 1
  local accent = def.accent or colors.lightBlue

  local function draw()
    local ix, iy, iw = ui.frame(x, y, w, h, " " .. def.name .. " -- Controls ", accent)
    for i = 1, #list do
      local row = list[i]
      local key, what = row[1], row[2]
      gfx.text(ix, iy + i - 1, gfx.clip(key, 15), accent, colors.gray)
      gfx.text(ix + 16, iy + i - 1, gfx.clip(what, iw - 16), colors.white, colors.gray)
    end
    gfx.center(y + h - 2, "press any key", colors.lightGray, colors.gray, x, w)
  end

  local function handle(ev)
    if ev[1] == "key" or ev[1] == "mouse_click" then return 1 end
    return nil
  end

  return ui.loop(draw, handle)
end

return ui
]=])
file("gameos/os/about.lua", [=[
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
]=])
file("gameos/os/scores.lua", [=[
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
        audio.play("ui.move")
      elseif k == keys.down or k == keys.s then
        sel = sel < #games and sel + 1 or 1
        audio.play("ui.move")
      elseif k == keys.backspace or k == keys.q or k == keys.enter then
        audio.play("ui.back")
        return 1
      end
    elseif name == "mouse_scroll" then
      sel = math.min(#games, math.max(1, sel + ev[2]))
    elseif name == "mouse_click" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      local i = top + (my - 3)
      if mx <= 21 and games[i] then
        sel = i
        audio.play("ui.move")
      elseif my >= 18 then
        audio.play("ui.back")
        return 1
      end
    end
    return nil
  end

  ui.loop(draw, handle)
end

return scores
]=])
file("gameos/os/settings.lua", [=[
--[[ settings -- console preferences.

  Left/Right cycles a value, Enter activates an action. Theme changes apply
  live so the palette strip at the bottom shows the result immediately.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")
local data = req("lib.data")
local ui = req("lib.ui")

local settings = {}

local floor = math.floor

--- A knob renders as a ten-segment bar plus a number, so a glance tells you
--- where it sits without reading the value.
local function knob(label, key, field, preview)
  return {
    label = label,
    value = function() return data.get(key) end,
    get = function() return data.get(key) .. "/10" end,
    bar = function() return data.get(key) / 10 end,
    -- dragging the bar jumps straight to a level, which is how a volume
    -- slider is expected to behave
    setTo = function(v)
      if v < 0 then v = 0 elseif v > 10 then v = 10 end
      if v == data.get(key) then return end
      data.set(key, v)
      audio.volumes[field] = v / 10
      if preview then preview(v) end
    end,
    cycle = function(dir)
      local v = data.get(key) + dir
      if v < 0 then v = 10 elseif v > 10 then v = 0 end
      data.set(key, v)
      audio.volumes[field] = v / 10
      if preview then preview(v) end
    end,
  }
end

function settings.run(api)
  local rows = {}

  rows[#rows + 1] = {
    label = "Theme",
    get = function() return gfx.themes[gfx.themeIndex].name end,
    cycle = function(dir)
      gfx.applyTheme(gfx.themeIndex + dir)
      data.set("theme", gfx.themes[gfx.themeIndex].id)
    end,
  }
  rows[#rows + 1] = { spacer = true }
  rows[#rows + 1] = knob("Master volume", "volMaster", "master", function(v)
    if v > 0 then audio.play("ui.select") end
  end)
  rows[#rows + 1] = knob("Music volume", "volMusic", "music", function(v)
    if v > 0 then audio.playMusic("standby") end
  end)
  rows[#rows + 1] = knob("Effect volume", "volSfx", "sfx", function(v)
    if v > 0 then audio.play("result.levelup") end
  end)
  rows[#rows + 1] = {
    label = "Sound test",
    action = function() req("os.soundtest").run(api) end,
  }
  rows[#rows + 1] = { spacer = true }
  rows[#rows + 1] = {
    label = "Frame counter",
    get = function() return data.get("showFps") and "On" or "Off" end,
    cycle = function() data.set("showFps", not data.get("showFps")) end,
  }
  rows[#rows + 1] = {
    label = "Confirm power off",
    get = function() return data.get("confirmExit") and "On" or "Off" end,
    cycle = function() data.set("confirmExit", not data.get("confirmExit")) end,
  }
  rows[#rows + 1] = { spacer = true }
  rows[#rows + 1] = {
    label = "Clear high scores",
    action = function()
      if ui.confirm(" Clear scores ", "Erase every high score?", "Erase", "Keep", colors.red) then
        data.state.scores = {}
        data.markDirty()
        data.save()
        audio.play("ui.deny")
      end
    end,
  }
  rows[#rows + 1] = {
    label = "Factory reset",
    action = function()
      if ui.confirm(" Factory reset ", { "Erase scores, progress", "and settings?" }, "Erase", "Cancel", colors.red) then
        data.wipe()
        audio.volumes.master = data.get("volMaster") / 10
        audio.volumes.music = data.get("volMusic") / 10
        audio.volumes.sfx = data.get("volSfx") / 10
        gfx.applyTheme(gfx.themeByID(data.get("theme")))
        audio.play("ui.deny")
      end
    end,
  }

  local sel = 1
  local FIRST_Y = 4
  local BAR_X = gfx.W - 20        -- must match the bar drawn below

  local function step(dir)
    local i = sel
    for _ = 1, #rows do
      i = i + dir
      if i < 1 then i = #rows elseif i > #rows then i = 1 end
      if not rows[i].spacer then
        sel = i
        audio.play("ui.move")
        return
      end
    end
  end

  local function draw()
    gfx.clear(colors.black)
    gfx.fill(1, 1, gfx.W, 1, colors.gray)
    gfx.text(2, 1, "SETTINGS", colors.white, colors.gray)
    gfx.right(gfx.W - 1, 1, "GameOS v" .. api.version, colors.lightGray, colors.gray)
    gfx.rule(1, 2, gfx.W, colors.lightBlue, colors.black)

    for i = 1, #rows do
      local row = rows[i]
      local y = FIRST_Y + i - 1
      if y <= 16 then
        if row.spacer then
          gfx.rule(4, y, gfx.W - 8, colors.gray, colors.black)
        else
          local on = (i == sel)
          local bg = on and colors.lightBlue or colors.black
          local fg = on and gfx.contrast(colors.lightBlue) or colors.white
          gfx.fill(3, y, gfx.W - 4, 1, bg)
          gfx.text(4, y, row.label, fg, bg)
          if row.bar then
            -- the knob's own level, drawn behind the label
            gfx.bar(BAR_X, y, 10, row.bar(), on and gfx.contrast(colors.lightBlue) or colors.lime,
              on and colors.lightBlue or colors.gray)
          end
          if row.get then
            local value = row.get()
            gfx.right(gfx.W - 4, y, value, on and fg or colors.lime, bg)
            if on then
              gfx.text(gfx.W - 5 - #value, y, "<", fg, bg)
              gfx.text(gfx.W - 3, y, ">", fg, bg)
            end
          elseif on then
            gfx.text(gfx.W - 4, y, "*", fg, bg)
          end
        end
      end
    end

    for i = 1, 16 do
      gfx.fill(4 + (i - 1) * 2, 17, 2, 1, gfx.allColors[i])
    end

    gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
    gfx.text(2, 19, "Left/Right", colors.lightBlue, colors.black)
    gfx.text(13, 19, "change", colors.lightGray, colors.black)
    gfx.text(21, 19, "Enter", colors.lightBlue, colors.black)
    gfx.text(27, 19, "activate", colors.lightGray, colors.black)
    gfx.text(37, 19, "Q", colors.lightBlue, colors.black)
    gfx.text(39, 19, "back", colors.lightGray, colors.black)
  end

  local function handle(ev)
    local name = ev[1]
    if name == "key" then
      local k = ev[2]
      if k == keys.up or k == keys.w then
        step(-1)
      elseif k == keys.down or k == keys.s then
        step(1)
      elseif k == keys.left or k == keys.a then
        local row = rows[sel]
        if row.cycle then row.cycle(-1) audio.play("ui.move") end
      elseif k == keys.right or k == keys.d then
        local row = rows[sel]
        if row.cycle then row.cycle(1) audio.play("ui.move") end
      elseif k == keys.enter or k == keys.space or k == keys.numPadEnter then
        local row = rows[sel]
        if row.action then
          row.action()
        elseif row.cycle then
          row.cycle(1)
          audio.play("ui.select")
        end
      elseif k == keys.backspace or k == keys.q then
        audio.play("ui.back")
        return 1
      end
    elseif name == "mouse_scroll" then
      -- the wheel adjusts whatever row the pointer is over
      local _, my = ui.toLocal(ev[3], ev[4])
      local i = my - FIRST_Y + 1
      if rows[i] and not rows[i].spacer then
        sel = i
        if rows[i].cycle then
          rows[i].cycle(ev[2] > 0 and 1 or -1)
          audio.play("ui.move")
        end
      end
    elseif name == "mouse_click" or name == "mouse_drag" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      local i = my - FIRST_Y + 1

      -- a click or drag anywhere along a knob's bar sets that level directly
      if rows[i] and rows[i].setTo and mx >= BAR_X - 1 and mx < BAR_X + 10 then
        sel = i
        rows[i].setTo(mx - BAR_X + 1)
        return nil
      end
      if name == "mouse_drag" then return nil end
      if ev[2] == 2 then
        audio.play("ui.back")
        return 1
      end
      if rows[i] and not rows[i].spacer then
        if i == sel then
          local row = rows[sel]
          if row.action then
            row.action()
          elseif row.cycle then
            -- clicking the left chevron steps back, anywhere else steps on
            row.cycle(mx == gfx.W - 5 - #row.get() and -1 or 1)
            audio.play("ui.select")
          end
        else
          sel = i
          audio.play("ui.move")
        end
      end
    end
    return nil
  end

  ui.loop(draw, handle)
  data.flush()
end

return settings
]=])
file("gameos/os/shell.lua", [=[
--[[ shell -- the game launcher.

  Left: a scrolling catalogue. Right: a live cover illustration for the
  highlighted entry plus its stats. Games draw their own covers, so the
  browser animates without the shell knowing anything about them.
]]

local req = ...
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local audio = req("lib.audio")
local data = req("lib.data")
local ui = req("lib.ui")
local input = req("lib.input")   -- attract mode drives real game frames

local shell = {}

local floor = math.floor

local LIST_X, LIST_W = 2, 19
local LIST_Y, LIST_ROWS = 3, 15
local PANEL_X, PANEL_W = 23, 28
local COVER_Y, COVER_H = 3, 7

local IDLE_LIMIT = 45

--------------------------------------------------------------- system art
local function coverScores(c, t)
  local heights = { 8, 13, 5, 10, 6 }
  local cols = { colors.orange, colors.yellow, colors.lightGray, colors.lime, colors.cyan }
  for i = 1, 5 do
    local h = heights[i] + floor(math.sin(t * 2 + i) * 1.5)
    c:fill(8 + (i - 1) * 9, c.h - 3 - h, 7, h, cols[i])
  end
  c:hline(1, c.h - 3, c.w, colors.lightGray)
end

local function coverSettings(c, t)
  for i = 1, 3 do
    local y = 5 + (i - 1) * 6
    c:hline(10, y + 1, 36, colors.gray)
    local k = (math.sin(t * 1.5 + i * 2) + 1) / 2
    local x = 10 + floor(k * 32)
    c:fill(x, y, 4, 3, i == 2 and colors.lime or colors.lightBlue)
  end
end

local function coverTrophies(c, t)
  local cup = { "..####..", "..####..", "...##...", "..####.." }
  local earned = data.trophyCount()
  for i = 1, 5 do
    local lit = i <= math.min(5, 1 + floor(earned / 3))
    local bob = (math.sin(t * 2 + i) > 0.6) and 1 or 0
    local x = 3 + (i - 1) * 11
    for row = 1, #cup do
      local line = cup[row]
      for col = 1, 8 do
        if line:sub(col, col) == "#" then
          c:set(x + col, 5 + row - bob, lit and colors.yellow or colors.gray)
        end
      end
    end
    c:fill(x + 1, 10 - bob, 6, 2, lit and colors.orange or colors.gray)
  end
  c:hline(1, 13, c.w, colors.lightGray)
end

local function coverAbout(c, t)
  font.centerShadow(c, 5, "GAMEOS", colors.white, colors.blue, 2, 2)
  local p = (t * 18) % (c.w + 24)
  c:hline(1, 14, c.w, colors.gray)
  c:fill(p - 24, 13, 24, 3, colors.lightBlue)
  font.center(c, 17, "V" .. (shell.version or "1"), colors.lightGray, 1, 1)
end

local function coverPower(c, t)
  local cx, cy = floor(c.w / 2), 10
  local blink = math.sin(t * 3) > 0
  c:circle(cx, cy, 7, blink and colors.red or colors.gray, false)
  c:circle(cx, cy, 6, blink and colors.red or colors.gray, false)
  c:fill(cx - 3, cy - 9, 7, 5, colors.black)
  c:fill(cx - 1, cy - 8, 2, 7, blink and colors.red or colors.gray)
end

local function coverFallback(def)
  return function(c, t)
    local accent = def.accent or colors.lightBlue
    for i = 0, 6 do
      c:hline(1, 1 + i * 3, c.w, i % 2 == 0 and colors.gray or colors.black)
    end
    font.centerShadow(c, 7, def.name, accent, colors.black, 2, 2)
  end
end

--------------------------------------------------------------- entry list
local function buildEntries(api)
  local list = { { kind = "header", label = "GAMES" } }
  for i = 1, #api.games do
    list[#list + 1] = { kind = "game", def = api.games[i] }
  end
  list[#list + 1] = { kind = "header", label = "SYSTEM" }
  list[#list + 1] = { kind = "action", id = "scores", label = "High Scores",
    accent = colors.yellow, cover = coverScores,
    tagline = "Every personal best", desc = "Records for each game" }
  list[#list + 1] = { kind = "action", id = "trophies", label = "Trophies",
    accent = colors.orange, cover = coverTrophies,
    tagline = "Things to chase", desc = "Every trophy, earned or not" }
  list[#list + 1] = { kind = "action", id = "settings", label = "Settings",
    accent = colors.lightBlue, cover = coverSettings,
    tagline = "Theme, sound, data", desc = "Tune the console" }
  list[#list + 1] = { kind = "action", id = "about", label = "About",
    accent = colors.purple, cover = coverAbout,
    tagline = "Version and credits", desc = "What this thing is" }
  list[#list + 1] = { kind = "action", id = "power", label = "Power Off",
    accent = colors.red, cover = coverPower,
    tagline = "Back to CraftOS", desc = "Leave GameOS" }
  return list
end

local function selectable(entry) return entry.kind ~= "header" end

--------------------------------------------------------------------- draw
local function accentOf(entry)
  if entry.kind == "game" then return entry.def.accent or colors.lightBlue end
  return entry.accent or colors.lightBlue
end

local function labelOf(entry)
  if entry.kind == "game" then return entry.def.name end
  return entry.label
end

function shell.run(api)
  shell.version = api.version
  local entries = buildEntries(api)
  local sel = 2
  for i = 1, #entries do
    if selectable(entries[i]) then sel = i break end
  end

  local top = 1
  local cover = Canvas.new(PANEL_X, COVER_Y, PANEL_W, COVER_H, colors.black)
  local saver = Canvas.new(1, 1, gfx.W, gfx.H, colors.black)
  local t = 0
  local idle = 0
  local saverOn = false
  local saverX, saverY, saverVX, saverVY = 10, 10, 26, 15
  local saverHue = 1
  local attract = nil          -- the demo currently playing itself
  local attractPick = 0

  local function clampView()
    if sel < top then top = sel end
    if sel > top + LIST_ROWS - 1 then top = sel - LIST_ROWS + 1 end
    local maxTop = #entries - LIST_ROWS + 1
    if maxTop < 1 then maxTop = 1 end
    if top > maxTop then top = maxTop end
    if top < 1 then top = 1 end
  end

  local function move(dir)
    local i = sel
    for _ = 1, #entries do
      i = i + dir
      if i < 1 then i = #entries elseif i > #entries then i = 1 end
      if selectable(entries[i]) then
        if i ~= sel then audio.play("ui.move") end
        sel = i
        return
      end
    end
  end

  --- Jump to the first selectable entry of the next section.
  local function jumpSection()
    local n = #entries
    local i = sel
    -- walk forward to the next header, then to the entry after it
    for _ = 1, n do
      i = i % n + 1
      if entries[i].kind == "header" then
        for _ = 1, n do
          i = i % n + 1
          if selectable(entries[i]) then
            sel = i
            audio.play("ui.select")
            return
          end
        end
      end
    end
  end

  local function drawList()
    clampView()
    for r = 0, LIST_ROWS - 1 do
      local i = top + r
      local y = LIST_Y + r
      gfx.fill(LIST_X, y, LIST_W, 1, colors.black)
      local e = entries[i]
      if e then
        if e.kind == "header" then
          gfx.text(LIST_X, y, e.label, colors.lightGray, colors.black)
          gfx.rule(LIST_X + #e.label + 1, y, LIST_W - #e.label - 1, colors.gray, colors.black)
        else
          local on = (i == sel)
          local accent = accentOf(e)
          local bg = on and accent or colors.black
          local fg = on and gfx.contrast(accent) or colors.white
          gfx.fill(LIST_X, y, LIST_W, 1, bg)
          if not on then
            gfx.fill(LIST_X, y, 1, 1, accent)
          end
          gfx.text(LIST_X + 2, y, gfx.clip(labelOf(e), LIST_W - 3), fg, bg)
          if on then gfx.text(LIST_X + LIST_W - 1, y, ">", fg, bg) end
        end
      end
    end
    if #entries > LIST_ROWS then
      local barH = math.max(1, floor(LIST_ROWS * LIST_ROWS / #entries))
      local barY = LIST_Y + floor((top - 1) / #entries * LIST_ROWS)
      gfx.fill(LIST_X + LIST_W, LIST_Y, 1, LIST_ROWS, colors.black)
      gfx.fill(LIST_X + LIST_W, barY, 1, barH, colors.gray)
    end
  end

  local function drawPanel()
    local e = entries[sel]
    local accent = accentOf(e)

    cover:clear(colors.black)
    local drawCover = e.cover
    if e.kind == "game" then
      if not e.def.cover and not e.def._fallbackCover then
        e.def._fallbackCover = coverFallback(e.def)
      end
      drawCover = e.def.cover or e.def._fallbackCover
    end
    local okCover = pcall(drawCover, cover, t)
    if not okCover then
      cover:clear(colors.gray)
      font.center(cover, 8, "NO ART", colors.lightGray, 1, 1)
    end
    cover:render()

    gfx.rule(PANEL_X, COVER_Y + COVER_H, PANEL_W, accent, colors.black)

    local name = e.kind == "game" and e.def.name or e.label
    local tagline = e.kind == "game" and (e.def.tagline or "") or (e.tagline or "")
    gfx.fill(PANEL_X, 11, PANEL_W, 1, colors.black)
    gfx.text(PANEL_X, 11, gfx.clip(name:upper(), PANEL_W), colors.white, colors.black)
    gfx.fill(PANEL_X, 12, PANEL_W, 1, colors.black)
    gfx.text(PANEL_X, 12, gfx.clip(tagline, PANEL_W), colors.lightGray, colors.black)

    for y = 13, 17 do gfx.fill(PANEL_X, y, PANEL_W, 1, colors.black) end
    if e.kind == "game" then
      local def = e.def
      local stats = data.stats(def.id)
      local best = data.best(def.id)
      gfx.text(PANEL_X, 14, def.scoreLabel or "BEST", colors.lightGray, colors.black)
      gfx.right(PANEL_X + PANEL_W - 1, 14, best > 0 and gfx.commas(best) or "--", accent, colors.black)
      gfx.text(PANEL_X, 15, "PLAYS", colors.lightGray, colors.black)
      gfx.right(PANEL_X + PANEL_W - 1, 15, tostring(stats.plays), colors.white, colors.black)
      gfx.text(PANEL_X, 16, "TIME", colors.lightGray, colors.black)
      gfx.right(PANEL_X + PANEL_W - 1, 16, data.formatDuration(stats.seconds), colors.white, colors.black)
      if def.modes and #def.modes > 1 then
        gfx.text(PANEL_X, 17, #def.modes .. " modes", colors.lightGray, colors.black)
      end
    else
      gfx.text(PANEL_X, 14, gfx.clip(e.desc or "", PANEL_W), colors.lightGray, colors.black)
    end
  end

  local function draw()
    gfx.clear(colors.black)
    local accent = accentOf(entries[sel])
    gfx.fill(1, 1, gfx.W, 1, colors.gray)
    gfx.text(2, 1, "GAMEOS", colors.white, colors.gray)
    gfx.text(9, 1, "v" .. api.version, colors.lightGray, colors.gray)
    local clock = textutils.formatTime(os.time(), true)
    gfx.right(gfx.W - 1, 1, clock, colors.lightGray, colors.gray)
    gfx.rule(1, 2, gfx.W, accent, colors.black)

    drawList()
    gfx.fill(LIST_X + LIST_W + 1, LIST_Y, 1, LIST_ROWS, colors.black)
    drawPanel()

    gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
    gfx.fill(1, 19, gfx.W, 1, colors.black)
    gfx.text(2, 19, "Up/Dn", accent, colors.black)
    gfx.text(8, 19, "browse", colors.lightGray, colors.black)
    gfx.text(17, 19, "Enter", accent, colors.black)
    gfx.text(23, 19, "play", colors.lightGray, colors.black)
    gfx.text(29, 19, "Tab", accent, colors.black)
    gfx.text(33, 19, "jump", colors.lightGray, colors.black)
    gfx.text(39, 19, "Q", accent, colors.black)
    gfx.text(41, 19, "power", colors.lightGray, colors.black)
  end

  ----------------------------------------------------------- screensaver
  local function drawSaver(dt)
    saverX = saverX + saverVX * dt
    saverY = saverY + saverVY * dt
    local tw = font.width("GAMEOS", 2, 2)
    if saverX < 1 then saverX = 1 saverVX = -saverVX saverHue = saverHue % 6 + 1 end
    if saverX + tw > saver.w then saverX = saver.w - tw saverVX = -saverVX saverHue = saverHue % 6 + 1 end
    if saverY < 1 then saverY = 1 saverVY = -saverVY saverHue = saverHue % 6 + 1 end
    if saverY + 11 > saver.h then saverY = saver.h - 11 saverVY = -saverVY saverHue = saverHue % 6 + 1 end
    local hues = { colors.lime, colors.cyan, colors.magenta, colors.orange, colors.lightBlue, colors.yellow }
    saver:clear(colors.black)
    font.draw(saver, floor(saverX), floor(saverY), "GAMEOS", hues[saverHue], 2, 2)
    gfx.beginFrame()
    saver:render()
    gfx.endFrame()
  end

  -------------------------------------------------------------- attract mode
  --- What an arcade cabinet does when nobody is standing at it: play itself.
  --- A game opts in by exporting a `demo(inst, frame)` bot; anything without
  --- one is simply never chosen, and if no game has one the old bouncing
  --- logo takes over instead.
  ---
  --- The instance is built directly rather than through runtime.play, so no
  --- score is recorded, no trophy is awarded and nothing is saved: a demo is
  --- a picture of a game, not a session.
  local DEMO_SECONDS = 22

  local function demoPool()
    local pool = {}
    for i = 1, #entries do
      local e = entries[i]
      if e.kind == "game" and type(e.def.demo) == "function" then
        pool[#pool + 1] = e.def
      end
    end
    return pool
  end

  local function startAttract()
    local pool = demoPool()
    if #pool == 0 then return false end
    attractPick = attractPick % #pool + 1
    local def = pool[attractPick]
    local mode = def.modes and def.modes[1] or nil
    local ok, inst = pcall(def.new, api, mode)
    if not ok or type(inst) ~= "table" then return false end
    attract = { def = def, inst = inst, frame = 0, t = 0 }
    return true
  end

  --- One frame of the demo. Everything is wrapped, because a game that throws
  --- while nobody is watching must not take the launcher down with it -- it
  --- just ends that demo and the next one starts.
  local function attractFrame(dt)
    local a = attract
    a.frame = a.frame + 1
    a.t = a.t + dt
    local ok = pcall(a.def.demo, a.inst, a.frame)
    if ok then ok = pcall(a.inst.update, a.inst, dt) end
    if ok then
      gfx.beginFrame()
      ok = pcall(a.inst.draw, a.inst)
      if ok then
        gfx.center(gfx.H, " DEMO -- PRESS ANY KEY ", colors.black, colors.yellow)
      end
      gfx.endFrame()
    end
    input.endFrame()      -- keep the per-frame input state from going stale
    if (not ok) or a.inst.finished or a.t > DEMO_SECONDS then
      attract = nil
    end
  end

  ------------------------------------------------------------------ loop
  local FRAME = 0.08
  local timer = os.startTimer(FRAME)
  local running = true

  local function launch(e)
    if e.kind == "game" then
      audio.play("ui.select")
      ui.transition(e.def.accent or colors.lightBlue)
      api.runtime.play(e.def, api)
      ui.transition(e.def.accent or colors.lightBlue)
    elseif e.id == "scores" then
      audio.play("ui.select")
      req("os.scores").run(api)
    elseif e.id == "trophies" then
      audio.play("ui.select")
      req("os.trophies").run(api)
    elseif e.id == "settings" then
      audio.play("ui.select")
      req("os.settings").run(api)
    elseif e.id == "about" then
      audio.play("ui.select")
      req("os.about").run(api)
    elseif e.id == "power" then
      if (not data.get("confirmExit")) or ui.confirm(" Power Off ", "Leave GameOS?", "Power off", "Stay") then
        running = false
        return
      end
    end
    ui.terminated = false
    -- the runtime stops the menu track while a game is running
    audio.playMusic("standby")
    os.cancelTimer(timer)
    timer = os.startTimer(FRAME)
    idle = 0
  end

  -- W/A/S/D/Q are navigation, so they never trigger a letter jump.
  local NAV_LETTERS = { w = true, a = true, s = true, d = true, q = true, p = true }

  local function jumpToLetter(ch)
    ch = ch:lower()
    if NAV_LETTERS[ch] then return false end
    for step = 1, #entries do
      local i = ((sel - 1 + step) % #entries) + 1
      local e = entries[i]
      if selectable(e) and labelOf(e):sub(1, 1):lower() == ch then
        sel = i
        audio.play("ui.move")
        return true
      end
    end
    return false
  end

  audio.playMusic("standby")

  while running do
    local ev = { os.pullEventRaw() }
    local name = ev[1]

    if name == "timer" and ev[2] == timer then
      timer = os.startTimer(FRAME)
      t = t + FRAME
      idle = idle + FRAME
      audio.update(os.clock())
      if idle > IDLE_LIMIT then
        saverOn = true
        if not attract then startAttract() end
        if attract then
          attractFrame(FRAME)
        else
          drawSaver(FRAME)
        end
      else
        saverOn = false
        attract = nil
        gfx.beginFrame()
        draw()
        gfx.endFrame()
      end

    elseif name == "terminate" then
      running = false

    elseif name == "key" then
      idle = 0
      if saverOn then
        saverOn = false
      else
        local k = ev[2]
        if k == keys.up or k == keys.w then
          move(-1)
        elseif k == keys.down or k == keys.s then
          move(1)
        elseif k == keys.home then
          sel = 1 move(1)
        elseif k == keys["end"] then
          sel = #entries
          if not selectable(entries[sel]) then move(1) end
        elseif k == keys.pageUp then
          for _ = 1, 5 do move(-1) end
        elseif k == keys.pageDown then
          for _ = 1, 5 do move(1) end
        elseif k == keys.tab then
          jumpSection()
        elseif k == keys.enter or k == keys.space or k == keys.numPadEnter then
          launch(entries[sel])
        elseif k == keys.q then
          if (not data.get("confirmExit")) or ui.confirm(" Power Off ", "Leave GameOS?", "Power off", "Stay") then
            running = false
          end
          os.cancelTimer(timer)
          timer = os.startTimer(FRAME)
        end
      end

    elseif name == "char" then
      idle = 0
      if not saverOn then
        local ch = ev[2]
        if ch:match("%a") then jumpToLetter(ch) end
      end
      saverOn = false

    elseif name == "mouse_click" then
      idle = 0
      if saverOn then
        saverOn = false
      else
        local mx, my = ui.toLocal(ev[3], ev[4])
        if mx >= LIST_X and mx < LIST_X + LIST_W and my >= LIST_Y and my < LIST_Y + LIST_ROWS then
          local i = top + (my - LIST_Y)
          local e = entries[i]
          if e and selectable(e) then
            if i == sel then
              launch(e)
            else
              sel = i
              audio.play("ui.move")
            end
          end
        elseif mx >= PANEL_X then
          launch(entries[sel])
        end
      end

    elseif name == "mouse_scroll" then
      idle = 0
      move(ev[2] > 0 and 1 or -1)

    elseif name == "term_resize" then
      idle = 0
      if not gfx.handleResize() then running = false end
    end
  end

  os.cancelTimer(timer)
  audio.stopMusic()
  data.flush()
end

return shell
]=])
file("gameos/os/soundtest.lua", [=[
--[[ soundtest -- audition every sound the console makes.

  Useful for setting the volume knobs, and for hearing what a game is about
  to throw at you before it does.
]]

local req = ...
local gfx = req("lib.gfx")
local audio = req("lib.audio")
local sfx = req("lib.sfx")
local data = req("lib.data")
local music = req("lib.music")
local ui = req("lib.ui")

local soundtest = {}

local floor = math.floor
local ROWS = 13
local LIST_Y = 5

--- Effects grouped by their name prefix, with songs on the end.
local function build()
  local GROUPS = {
    ui = "Console", boot = "Console", result = "Outcomes",
    snake = "Snake", tet = "Tetris", brk = "Breakout", bmb = "Bombard",
    ms = "Minesweeper", g2048 = "2048", sok = "Sokoban", fly = "Flappy",
    png = "Pong", met = "Meteors", lo = "Lights Out", sim = "Simon",
    c4 = "Connect Four",
  }
  local order = {
    "Console", "Outcomes", "Snake", "Tetris", "Breakout", "Bombard",
    "Minesweeper", "2048", "Sokoban", "Flappy", "Pong", "Meteors",
    "Lights Out", "Simon", "Connect Four",
  }
  local buckets = {}
  for _, name in ipairs(sfx.names()) do
    local prefix = name:match("^([^.]+)")
    local group = GROUPS[prefix] or "Other"
    buckets[group] = buckets[group] or {}
    table.insert(buckets[group], name)
  end

  local rows = {}
  for _, group in ipairs(order) do
    if buckets[group] then
      rows[#rows + 1] = { header = group }
      for _, name in ipairs(buckets[group]) do
        rows[#rows + 1] = { sound = name }
      end
    end
  end
  rows[#rows + 1] = { header = "Music" }
  for _, id in ipairs(music.names()) do
    rows[#rows + 1] = { song = id }
  end
  return rows
end

function soundtest.run(api)
  local rows = build()
  local sel = 1
  while rows[sel] and rows[sel].header do sel = sel + 1 end
  local top = 1
  local playing = nil

  local function clampView()
    if sel < top then top = sel end
    if sel > top + ROWS - 1 then top = sel - ROWS + 1 end
    local maxTop = math.max(1, #rows - ROWS + 1)
    if top > maxTop then top = maxTop end
    if top < 1 then top = 1 end
  end

  local function move(dir)
    local i = sel
    for _ = 1, #rows do
      i = i + dir
      if i < 1 then i = #rows elseif i > #rows then i = 1 end
      if not rows[i].header then
        sel = i
        return
      end
    end
  end

  local function activate()
    local row = rows[sel]
    if not row then return end
    if row.sound then
      audio.play(row.sound)
    elseif row.song then
      if audio.musicName() == row.song then
        audio.stopMusic()
        playing = nil
      else
        audio.playMusic(row.song)
        playing = row.song
      end
    end
  end

  local function draw()
    gfx.clear(colors.black)
    gfx.fill(1, 1, gfx.W, 1, colors.gray)
    gfx.text(2, 1, "SOUND TEST", colors.white, colors.gray)
    gfx.right(gfx.W - 1, 1, #sfx.names() .. " effects", colors.lightGray, colors.gray)
    gfx.rule(1, 2, gfx.W, colors.magenta, colors.black)

    -- the three knobs, so you can hear what you are setting
    gfx.text(2, 3, "MASTER", colors.lightGray, colors.black)
    gfx.bar(9, 3, 10, audio.volumes.master, colors.lime, colors.gray)
    gfx.text(21, 3, "MUSIC", colors.lightGray, colors.black)
    gfx.bar(27, 3, 10, audio.volumes.music, colors.cyan, colors.gray)
    gfx.text(39, 3, "FX", colors.lightGray, colors.black)
    gfx.bar(42, 3, 8, audio.volumes.sfx, colors.orange, colors.black)

    clampView()
    for i = 0, ROWS - 1 do
      local row = rows[top + i]
      local y = LIST_Y + i
      gfx.fill(1, y, gfx.W, 1, colors.black)
      if row then
        if row.header then
          gfx.text(2, y, row.header, colors.magenta, colors.black)
          gfx.rule(3 + #row.header, y, gfx.W - 4 - #row.header, colors.gray, colors.black)
        else
          local on = (top + i == sel)
          local bg = on and colors.magenta or colors.black
          local fg = on and gfx.contrast(colors.magenta) or colors.white
          gfx.fill(2, y, gfx.W - 2, 1, bg)
          if row.sound then
            gfx.text(4, y, gfx.clip(row.sound, 26), fg, bg)
            gfx.right(gfx.W - 2, y,
              string.format("%.2fs", sfx.duration(row.sound)),
              on and fg or colors.lightGray, bg)
          else
            gfx.text(4, y, gfx.clip(music.title(row.song), 26), fg, bg)
            local tag = (audio.musicName() == row.song) and "playing" or
              string.format("%.0fs", music.length(row.song))
            gfx.right(gfx.W - 2, y, tag, on and fg or colors.lightGray, bg)
          end
        end
      end
    end

    gfx.rule(1, 18, gfx.W, colors.gray, colors.black)
    gfx.text(2, 19, "Enter", colors.magenta, colors.black)
    gfx.text(8, 19, "play", colors.lightGray, colors.black)
    gfx.text(14, 19, "Left/Right", colors.magenta, colors.black)
    gfx.text(25, 19, "master", colors.lightGray, colors.black)
    gfx.text(33, 19, "Q", colors.magenta, colors.black)
    gfx.text(35, 19, "back", colors.lightGray, colors.black)
  end

  local function handle(ev)
    if ev[1] == "key" then
      local k = ev[2]
      if k == keys.up or k == keys.w then
        move(-1)
      elseif k == keys.down or k == keys.s then
        move(1)
      elseif k == keys.left or k == keys.a or k == keys.right or k == keys.d then
        local step = (k == keys.left or k == keys.a) and -1 or 1
        local v = math.floor(audio.volumes.master * 10 + 0.5) + step
        v = math.max(0, math.min(10, v))
        audio.volumes.master = v / 10
        data.set("volMaster", v)
      elseif k == keys.enter or k == keys.space then
        activate()
      elseif k == keys.pageUp then
        for _ = 1, ROWS do move(-1) end
      elseif k == keys.pageDown then
        for _ = 1, ROWS do move(1) end
      elseif k == keys.backspace or k == keys.q then
        audio.stopMusic()
        audio.play("ui.back")
        return 1
      end
    elseif ev[1] == "mouse_scroll" then
      move(ev[2] > 0 and 1 or -1)
    elseif ev[1] == "mouse_click" then
      local mx, my = ui.toLocal(ev[3], ev[4])
      local i = top + (my - LIST_Y)
      if rows[i] and not rows[i].header then
        sel = i
        activate()
      elseif my >= 18 then
        audio.stopMusic()
        audio.play("ui.back")
        return 1
      end
    end
    return nil
  end

  ui.loop(draw, handle)
end

return soundtest
]=])
file("gameos/os/splash.lua", [=[
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
]=])
file("gameos/os/trophies.lua", [=[
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
        audio.play("ui.back")
        return 1
      end
    elseif ev[1] == "mouse_scroll" then
      scroll(ev[2])
    elseif ev[1] == "mouse_click" then
      local _, my = ui.toLocal(ev[3], ev[4])
      if my >= 18 then
        audio.play("ui.back")
        return 1
      end
    end
    return nil
  end

  ui.loop(draw, handle)
end

return trophies
]=])
file("startup.lua", [[
-- Boot straight into GameOS. Delete this file if you would rather land in
-- the CraftOS shell and type "gameos" yourself.

if not fs.exists("/gameos/boot.lua") then return end

local handle = fs.open("/gameos.lua", "r")
if not handle then return end
local src = handle.readAll()
handle.close()

local chunk, err = load(src, "@/gameos.lua", "t", _ENV)
if not chunk then
  printError(tostring(err))
  return
end

local ok, runErr = pcall(chunk)
if not ok then printError(tostring(runErr)) end
]])

--------------------------------------------------------------------- unpack
local total = #ORDER
local written, failed = 0, 0

term.setTextColour(colours.white)
print("GameOS installer")
print(total .. " files" .. (target ~= "" and (" -> " .. target) or ""))
print("")

for i = 1, total do
  local path = ORDER[i]
  local full = target .. "/" .. path
  local dir = fs.getDir(full)
  local ok, err = pcall(function()
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local handle = fs.open(full, "w")
    if not handle then error("cannot open for writing", 0) end
    handle.write(FILES[path])
    handle.close()
  end)
  if ok then
    written = written + 1
  else
    failed = failed + 1
    term.setTextColour(colours.red)
    print("failed: " .. path .. " (" .. tostring(err) .. ")")
    term.setTextColour(colours.white)
  end
  -- one tidy progress line rather than a wall of filenames
  local w = term.getSize()
  local done = math.floor((i / total) * (w - 8))
  term.setCursorPos(1, select(2, term.getCursorPos()))
  term.clearLine()
  term.write(string.format("%3d%% [", math.floor(i / total * 100)))
  term.setTextColour(colours.lime)
  term.write(string.rep("=", done))
  term.setTextColour(colours.white)
  term.write(string.rep(" ", math.max(0, w - 8 - done)) .. "]")
  if i % 4 == 0 then sleep(0) end
end

print("")
print("")
if failed > 0 then
  term.setTextColour(colours.red)
  print(failed .. " file(s) failed -- GameOS is not installed.")
  term.setTextColour(colours.white)
  return
end

term.setTextColour(colours.lime)
print("Installed " .. written .. " files.")
term.setTextColour(colours.white)
if target == "" then
  print("Reboot the computer, or run: gameos")
else
  print("Run: " .. target .. "/gameos")
end
