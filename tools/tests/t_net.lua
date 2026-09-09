-- Console-to-console play: discovery, the handshake, and the delivery
-- guarantees a match depends on.
--
-- There is no second Lua state here. Instead the mock records everything this
-- console transmits (MOCK.ether) and lets the test hand back whatever the
-- other console would have replied (MOCK.deliver), so the test plays the part
-- of the far end. That is enough to exercise the whole protocol, including
-- the cases that only happen when something goes wrong: a lost message, one
-- that arrives twice, and two that arrive in the wrong order.

local req = require_gameos
local gfx = req("lib.gfx")
local Canvas = req("lib.canvas")
local font = req("lib.font")
local input = req("lib.input")
local audio = req("lib.audio")
local data = req("lib.data")
local net = req("lib.net")

gfx.init()
data.load()
audio.init()

local US = os.getComputerID()
local THEM = 42
local LOBBY = 6502

--- Pull the queued event straight back out, since these tests drive the
--- handlers directly rather than running an event loop.
local function eventFromThem(body, channel)
  body.gameos = 1
  body.from = body.from or THEM
  return { "modem_message", "back", channel or net.channel(US),
           net.channel(THEM), body, 8 }
end

------------------------------------------------------------------ the modem
do
  MOCK.modemPresent = false
  check(not net.available(), "no modem is reported honestly")
  local ok, err = net.open()
  check(not ok, "opening without a modem fails rather than throwing")
  check(type(err) == "string", "and says why: " .. tostring(err))

  MOCK.modemPresent = true
  check(net.available(), "a modem is found once attached")
  check(net.open(), "the modem opens")
  check(net.isOpen(), "and reports itself open")
  check(MOCK.openChannels[LOBBY], "the lobby channel is listening")
  check(MOCK.openChannels[net.channel(US)], "our own channel is listening")
end

---------------------------------------------------------------- ignoring junk
-- Everything arriving on a public channel is untrusted. Anything that is not
-- one of ours has to be dropped without a murmur.
do
  check(net.parse({ "key", 1 }) == nil, "a non-modem event is not ours")
  check(net.parse(eventFromThem({})) == nil, "a message with no type is dropped")
  check(net.parse({ "modem_message", "back", LOBBY, 1, "hello", 1 }) == nil,
    "a plain string payload is dropped")
  check(net.parse({ "modem_message", "back", LOBBY, 1, { t = "advert" }, 1 }) == nil,
    "a message without our marker is dropped")
  check(net.parse({ "modem_message", "back", LOBBY, 1,
    { gameos = 999, t = "advert", from = 1 }, 1 }) == nil,
    "a message from another protocol version is dropped")
  check(net.parse(eventFromThem({ t = "advert" })) ~= nil, "a well-formed message parses")
end

---------------------------------------------------------------- discovery
do
  MOCK.clearEther()
  local host = net.hosting("bombard")
  check(host ~= nil, "hosting starts")

  host:advertise(0)
  local sent = MOCK.lastSent("advert")
  check(sent ~= nil, "the host advertises")
  check(sent.channel == LOBBY, "on the lobby channel")
  check(sent.body.game == "bombard", "naming the game")
  check(type(sent.body.name) == "string", "and itself: " .. tostring(sent.body.name))

  -- it must rate-limit, or it would flood the network every frame
  MOCK.clearEther()
  host:advertise(0.01)
  check(MOCK.lastSent("advert") == nil, "adverts are rate limited")
  host:advertise(1.0)
  check(MOCK.lastSent("advert") ~= nil, "and resume on schedule")
end

do
  local browser = net.browsing("bombard")
  check(browser ~= nil, "browsing starts")
  check(#browser:list(0) == 0, "no hosts to begin with")

  browser:handle(eventFromThem({ t = "advert", game = "bombard", name = "Shed" }, LOBBY), 1.0)
  local list = browser:list(1.0)
  check(#list == 1, "an advertising host appears")
  check(list[1].id == THEM and list[1].name == "Shed", "with its name and id")

  -- a host for a different game must not show up in this list
  browser:handle(eventFromThem({ t = "advert", game = "chess", name = "Nope", from = 51 }, LOBBY), 1.0)
  check(#browser:list(1.0) == 1, "a host for another game is ignored")

  -- and one that stops shouting drops off by itself
  check(#browser:list(1.0 + net.ADVERT_STALE + 0.1) == 0, "a silent host expires")

  -- an explicit withdrawal is immediate
  browser:handle(eventFromThem({ t = "advert", game = "bombard", name = "Shed" }, LOBBY), 10)
  check(#browser:list(10) == 1, "host back")
  browser:handle(eventFromThem({ t = "unhost", game = "bombard" }, LOBBY), 10)
  check(#browser:list(10) == 0, "a host that withdraws disappears at once")
end

---------------------------------------------------------------- the handshake
do
  MOCK.clearEther()
  local host = net.hosting("bombard")
  local join = host:handle(eventFromThem({ t = "join", game = "bombard", name = "Shed" }, LOBBY))
  check(join ~= nil, "the host sees a join request")
  check(join.from == THEM, "from the right console")

  net.accept(THEM, { seed = 1234 })
  local acc = MOCK.lastSent("accept")
  check(acc ~= nil, "the host accepts")
  check(acc.channel == net.channel(THEM), "addressed to the joiner")
  check(acc.body.seed == 1234, "carrying the seed that builds the world")

  -- a join for a different game must not be answered
  check(host:handle(eventFromThem({ t = "join", game = "chess" }, LOBBY)) == nil,
    "a join for another game is ignored")
end

--------------------------------------------------------------------- the link
do
  MOCK.clearEther()
  local link = net.link(THEM, "Shed")

  -- ordered, acknowledged delivery
  link:send("shot", { a = 45, p = 60 })
  local sent = MOCK.lastSent("shot")
  check(sent ~= nil, "a shot goes out")
  check(sent.body.seq == 1, "carrying a sequence number")
  check(sent.body.a == 45 and sent.body.p == 60, "and its payload")

  -- unacknowledged, it must be resent rather than lost forever
  MOCK.clearEther()
  link:update(0.1)
  check(MOCK.lastSent("shot") == nil, "no resend before the timer")
  link:update(net.RESEND_AFTER + 0.1)
  check(MOCK.lastSent("shot") ~= nil, "an unacknowledged shot is resent")

  -- once acknowledged it stops
  link:handle(eventFromThem({ t = "ack", seq = 1 }), 1.0)
  MOCK.clearEther()
  link:update(10)
  check(MOCK.lastSent("shot") == nil, "an acknowledged shot stops being resent")
end

do
  local link = net.link(THEM, "Shed")

  -- an inbound message is acknowledged and delivered
  MOCK.clearEther()
  link:handle(eventFromThem({ t = "shot", seq = 1, a = 30, p = 50 }), 1.0)
  check(MOCK.lastSent("ack") ~= nil, "an inbound message is acknowledged")
  local got = link:poll()
  check(got ~= nil and got.a == 30, "and delivered")
  check(link:poll() == nil, "exactly once")

  -- a duplicate must be acknowledged again but not delivered twice
  MOCK.clearEther()
  link:handle(eventFromThem({ t = "shot", seq = 1, a = 30, p = 50 }), 1.1)
  check(MOCK.lastSent("ack") ~= nil, "a duplicate is acknowledged again")
  check(link:poll() == nil, "but not delivered twice")

  -- out of order: hold the later one until the gap is filled
  link:handle(eventFromThem({ t = "shot", seq = 3, a = 3 }), 1.2)
  check(link:poll() == nil, "a message that skips ahead is held back")
  link:handle(eventFromThem({ t = "shot", seq = 2, a = 2 }), 1.3)
  local a = link:poll()
  local b = link:poll()
  check(a and a.a == 2, "the missing one is delivered first")
  check(b and b.a == 3, "then the one that was waiting")
  check(link:poll() == nil, "and nothing else")

  -- traffic from a console we are not talking to is ignored entirely
  link:handle(eventFromThem({ t = "shot", seq = 9, a = 99, from = 77 }), 1.4)
  check(link:poll() == nil, "a stranger cannot inject moves into our match")
end

-------------------------------------------------------------- staying alive
do
  local link = net.link(THEM, "Shed")
  check(link:alive(0), "a fresh link is alive")
  check(link:alive(net.LINK_TIMEOUT - 0.1), "and stays alive inside the timeout")
  check(not link:alive(net.LINK_TIMEOUT + 0.1), "silence past the timeout kills it")

  -- anything heard resets the clock
  link:handle(eventFromThem({ t = "beat" }), net.LINK_TIMEOUT - 0.1)
  check(link:alive(net.LINK_TIMEOUT + 0.1), "a heartbeat keeps it alive")

  MOCK.clearEther()
  link:update(100)
  check(MOCK.lastSent("beat") ~= nil, "we send heartbeats of our own")

  -- a clean goodbye is immediate, not a five second wait
  link:handle(eventFromThem({ t = "bye", why = "quit" }), 100)
  check(not link:alive(100), "a goodbye ends the link at once")
end

------------------------------------------------------- a match over the wire
-- The protocol is only worth anything if the game on top of it behaves. This
-- drives a real Bombard instance as the guest and plays the host by hand.
do
  local def = req("games.bombard")
  local api = {
    version = "test", gfx = gfx, canvas = Canvas, font = font,
    input = input, audio = audio, data = data, ui = req("lib.ui"), require = req,
  }
  local link = net.link(THEM, "Shed")
  local g = def.new(api, {
    id = "join", seed = 4242, role = "guest", link = link, peerName = "Shed",
  })

  check(g.me == 2, "the guest is player two")
  check(g.turn == 1, "the host shoots first")
  check(not g:myTurn(), "so the guest waits")
  check(g.suppressPause, "a networked game refuses the blocking pause menu")

  -- the host's shot arrives and must be played out here
  MOCK.clearEther()
  g:onEvent(eventFromThem({ t = "shot", seq = 1, a = 44, p = 61 }))
  check(g.phase == "flight", "the opponent's shot is fired locally")
  check(MOCK.lastSent("shot") == nil, "and is not echoed back to them")

  -- run it out to the end of the turn
  for _ = 1, 400 do
    g:update(0.05)
    if g:myTurn() then break end
  end
  check(g:myTurn(), "the turn comes round to the guest")

  -- now our own shot must go out
  MOCK.clearEther()
  g:fire(120, 50)
  local out = MOCK.lastSent("shot")
  check(out ~= nil, "our shot is sent to the opponent")
  check(out.body.a == 120 and out.body.p == 50, "with the angle and power we used")

  -- a fingerprint that disagrees has to trigger a resync request
  MOCK.clearEther()
  g:onEvent(eventFromThem({ t = "sync", seq = 2, h = 123456 }))
  check(MOCK.lastSent("resync") ~= nil, "a mismatched world asks for the truth")

  -- and the host's answer has to be taken
  local snap = {
    g = {}, t = { { 55, 10, 30 }, { 88, 90, 30 } }, turn = 1, wind = 3,
  }
  for x = 1, 102 do snap.g[x] = 40 end
  g:onEvent(eventFromThem({ t = "state", seq = 3, s = snap }))
  check(g.tanks[1].health == 55 and g.tanks[2].health == 88,
    "the host's state is adopted")
  check(g.desyncs == 1, "and the correction is counted")

  -- A guest whose acceptance went missing keeps asking. The host is in the
  -- match by then and no longer in the lobby loop, so the match itself has to
  -- answer, or that guest sits on "joining..." until it gives up.
  do
    local hostSide = def.new(api, {
      id = "host", seed = 4242, role = "host",
      link = net.link(THEM, "Shed"), peerName = "Shed",
    })
    MOCK.clearEther()
    hostSide:onEvent(eventFromThem({ t = "join", game = "bombard", name = "Shed" }))
    local again = MOCK.lastSent("accept")
    check(again ~= nil, "a mid-match host re-accepts its own opponent")
    check(again ~= nil and again.body.seed == 4242,
      "with the same seed, so the world still matches")

    -- and a third console must be told, not ignored
    MOCK.clearEther()
    hostSide:onEvent(eventFromThem({ t = "join", game = "bombard", from = 77 }))
    local no = MOCK.lastSent("refuse")
    check(no ~= nil, "a stranger's join is refused rather than ignored")
    check(MOCK.lastSent("accept") == nil, "and certainly not accepted")

    -- a guest must never hand out acceptances
    MOCK.clearEther()
    g:onEvent(eventFromThem({ t = "join", game = "bombard", name = "X" }))
    check(MOCK.lastSent("accept") == nil, "a guest never accepts anyone")
  end

  -- a malformed state must not crash the match
  local ok = pcall(g.restore, g, { g = "nonsense" })
  check(ok, "a malformed state is survived")
  ok = pcall(g.restore, g, nil)
  check(ok, "so is no state at all")

  -- losing the opponent ends the match rather than hanging
  local g2 = def.new(api, {
    id = "join", seed = 1, role = "guest", link = net.link(THEM, "Shed"),
  })
  MOCK.advance(net.LINK_TIMEOUT + 1)
  g2:update(0.05)
  check(g2.finished, "a vanished opponent ends the match")
  check(g2.winner == g2.me, "and the console still standing takes the win")
end

net.close()
check(not net.isOpen(), "the modem is released")

gfx.shutdown()
finish("net")
