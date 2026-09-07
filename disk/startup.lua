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
