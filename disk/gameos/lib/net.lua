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
