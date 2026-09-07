-- harness.lua -- test scaffolding layered on top of ccmock.
-- Mounts the disk image, mirrors the real module loader, and gives tests
-- frame-accurate input scripting plus screenshot capture.

math.randomseed(1337)

do
  local mounted = {}
  for name in tostring(__diskList()):gmatch("[^\n]+") do
    mounted[name] = __diskRead(name)
  end
  MOCK.mount(mounted)
end

ARGS = {}
for a in tostring(__args or ""):gmatch("[^\n]+") do ARGS[#ARGS + 1] = a end

-- Identical in behaviour to the loader in /gameos/boot.lua
function makeLoader(base)
  local cache = {}
  local req
  req = function(name)
    local hit = cache[name]
    if hit ~= nil then return hit end
    local path = base .. "/" .. (name:gsub("%.", "/")) .. ".lua"
    local handle = fs.open(path, "r")
    if not handle then error("module not found: " .. name .. " (" .. path .. ")", 0) end
    local src = handle.readAll()
    handle.close()
    local chunk, err = load(src, "@" .. path, "t", _G)
    if not chunk then error("compile error in " .. path .. ": " .. tostring(err), 0) end
    local mod = chunk(req, name)
    if mod == nil then mod = true end
    cache[name] = mod
    return mod
  end
  return req
end

require_gameos = makeLoader("/gameos")

------------------------------------------------------------------ screenshots
local shotCount = 0
function SHOT(name)
  shotCount = shotCount + 1
  local s = MOCK.snapshot()
  local parts = { s.w .. " " .. s.h }
  local pal = {}
  for i = 1, 16 do pal[i] = string.format("%06x", s.palette[i]) end
  parts[#parts + 1] = table.concat(pal, " ")
  for y = 1, s.h do
    local hex = {}
    for x = 1, s.w do hex[x] = string.format("%02x", s.rows[y].ch[x]) end
    parts[#parts + 1] = table.concat(hex) .. " " .. s.rows[y].fg .. " " .. s.rows[y].bg
  end
  __shot(string.format("%02d-%s", shotCount, name), table.concat(parts, "\n"))
end

function LOG(...)
  local bits = {}
  for i = 1, select("#", ...) do bits[i] = tostring((select(i, ...))) end
  __log(table.concat(bits, " "))
end

------------------------------------------------------------------ input feed
function press(k, held) MOCK.push("key", k, held and true or false) end
function release(k) MOCK.push("key_up", k) end
function tap(k) press(k, false) release(k) end
function typed(c) MOCK.push("char", c) end
function click(btn, x, y)
  MOCK.push("mouse_click", btn, x, y)
  MOCK.push("mouse_up", btn, x, y)
end
function scroll(dir, x, y) MOCK.push("mouse_scroll", dir, x, y) end

local schedule = {}
function at(frame, fn)
  schedule[frame] = schedule[frame] or {}
  table.insert(schedule[frame], fn)
end
function hold(fromFrame, toFrame, k)
  at(fromFrame, function() press(k, false) end)
  for f = fromFrame + 1, toFrame do at(f, function() press(k, true) end) end
  at(toFrame + 1, function() release(k) end)
end

AUTO = nil
MOCK.hooks.onTimer = function(f)
  local list = schedule[f]
  if list then for _, fn in ipairs(list) do fn(f) end end
  if AUTO then AUTO(f) end
end

------------------------------------------------------------------ assertions
local failures = 0
function check(cond, msg)
  if not cond then
    failures = failures + 1
    LOG("  FAIL: " .. tostring(msg))
  end
  return cond
end
function eq(a, b, msg)
  return check(a == b, string.format("%s (got %s, want %s)", tostring(msg), tostring(a), tostring(b)))
end
function finish(label)
  if failures > 0 then
    LOG(string.format("[%s] %d check(s) FAILED", label, failures))
    error("test failures: " .. failures, 0)
  end
  LOG(string.format("[%s] ok", label))
end

------------------------------------------------------------------ run helper
-- Runs fn, treating the sentinel used to unwind the OS as a clean exit.
function protectedRun(fn)
  local ok, err = pcall(fn)
  if not ok then
    if type(err) == "string" and (err:find("HARNESS_DONE", 1, true) or err:find("MOCK_SHUTDOWN", 1, true)) then
      return "exited"
    end
    error(err, 0)
  end
  return "returned"
end
