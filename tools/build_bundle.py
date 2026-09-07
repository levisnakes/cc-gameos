"""Build install.lua: a single self-extracting file containing the whole
console, so it can be installed with one pastebin or wget command.

usage: python build_bundle.py
"""
import io
import os
import sys

BS = chr(92)
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DISK = os.path.join(ROOT, "disk")
OUT = os.path.join(ROOT, "install.lua")


def collect():
    files = []
    for root, _dirs, names in os.walk(DISK):
        for name in sorted(names):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, DISK).replace(BS, "/")
            files.append((rel, io.open(full, encoding="latin1").read()))
    files.sort()
    return files


def bracket_level(text):
    """Smallest long-bracket level whose closer does not appear in `text`."""
    level = 0
    while ("]" + "=" * level + "]") in text:
        level += 1
        if level > 12:
            raise SystemExit("could not find a safe long-bracket level")
    return level


HEADER = '''--[[ GameOS installer -- the whole console in one file.

  This writes {count} files and then you are done. Nothing is downloaded, so
  it works on a computer with HTTP disabled.

    install            unpack into this computer
    install <folder>   unpack somewhere else

  After it finishes, reboot the computer or run: gameos
]]

local target = ({{ ... }})[1] or ""
if target ~= "" then
  target = "/" .. target:gsub("^/+", ""):gsub("/+$", "")
end

local FILES = {{}}
local ORDER = {{}}

local function file(path, body)
  FILES[path] = body
  ORDER[#ORDER + 1] = path
end

'''

FOOTER = '''
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
'''


def main():
    files = collect()
    parts = [HEADER.format(count=len(files))]
    for path, body in files:
        level = bracket_level(body)
        eq = "=" * level
        parts.append('file("%s", [%s[\n%s]%s])\n' % (path, eq, body, eq))
    parts.append(FOOTER)
    bundle = "".join(parts)
    io.open(OUT, "w", encoding="latin1", newline="\n").write(bundle)

    size = len(bundle)
    print("wrote install.lua: %d files, %d bytes (%.0f KB)"
          % (len(files), size, size / 1024.0))
    if size > 480 * 1024:
        print("WARNING: over 480 KB, close to the pastebin limit", file=sys.stderr)


if __name__ == "__main__":
    main()
