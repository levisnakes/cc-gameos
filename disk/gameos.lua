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
