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
