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
