-- End-to-end: boot GameOS, browse the shell, play Snake, quit, power off.

local script = {
  function() tap(keys.space) end,                 -- skip splash
  function() SHOT("shell") end,
  function() tap(keys.down) end,
  function() tap(keys.down) end,
  function() SHOT("shell-scrolled") end,
  function() tap(keys.up) end,
  function() tap(keys.up) end,
  function() tap(keys.enter) end,                 -- launch first game
  function() end,
  function() SHOT("mode-picker") end,
  function() tap(keys.enter) end,                 -- Classic
  function() end,
  function() SHOT("controls-card") end,
  function() tap(keys.space) end,                 -- dismiss controls
  function() end,
  function() end,
  function() SHOT("snake-start") end,
  function() tap(keys.up) end,
  function() end,
  function() tap(keys.left) end,
  function() end,
  function() end,
  function() tap(keys.down) end,
  function() end,
  function() SHOT("snake-play") end,
  function() end,
  function() tap(keys.p) end,                     -- pause
  function() end,
  function() SHOT("pause") end,
  function() tap(keys.down) end,
  function() tap(keys.down) end,
  function() tap(keys.down) end,
  function() tap(keys.down) end,
  function() tap(keys.enter) end,                 -- quit to menu
  function() end,
  function() SHOT("back-in-shell") end,
  function() tap(keys["end"]) end,                -- Power Off
  function() end,
  function() SHOT("power-selected") end,
  function() tap(keys.enter) end,
  function() end,
  function() SHOT("power-confirm") end,
  function() tap(keys.left) end,
  function() tap(keys.enter) end,
  function() end,
  function() end,
  function() error("HARNESS_DONE", 0) end,
}

local idx = 1
AUTO = function(f)
  if f % 5 == 0 and idx <= #script then
    local fn = script[idx]
    idx = idx + 1
    fn()
  end
end

local handle = fs.open("/gameos/boot.lua", "r")
check(handle ~= nil, "boot.lua present")
local src = handle.readAll()
handle.close()

local chunk, err = load(src, "@/gameos/boot.lua", "t", _G)
check(chunk ~= nil, "boot.lua compiles: " .. tostring(err))

local how = protectedRun(chunk)
LOG("boot " .. how .. " after " .. MOCK.frame .. " frames, " .. #MOCK.notes .. " notes played")
check(idx > 40, "script ran to completion (got to step " .. idx .. ")")
SHOT("final")
finish("boot")
