#!/usr/bin/env bash
# Full GameOS test suite: lint, libraries, game rules, input fuzz, and a
# scripted end-to-end boot. Run from the tools/ directory.
set -u
cd "$(dirname "$0")"

fail=0
run() {
  local label="$1"; shift
  local out
  if out=$(node run.mjs "$@" 2>&1); then
    echo "  PASS  $label"
  else
    echo "  FAIL  $label"
    echo "$out" | sed 's/^/        /' | tail -20
    fail=1
  fi
}

echo "== single-file bundle =="
if python build_bundle.py > out/bundle.txt 2>&1; then
  echo "  PASS  $(tail -1 out/bundle.txt)"
else
  echo "  FAIL  building install.lua"
  sed 's/^/        /' out/bundle.txt
  fail=1
fi
run "installer unpacks and boots" tests/t_install.lua

echo "== libraries and rendering =="
run "canvas + gfx" tests/t_canvas.lua
run "boot animation" tests/t_splash.lua

echo "== game rules =="
run "logic" tests/t_logic.lua
run "connect four opponent" tests/t_ai.lua
run "trophies and initials" tests/t_trophy.lua
run "sound system" tests/t_sound.lua
run "mouse controls" tests/t_mouse.lua
run "bombard rules" tests/t_bombard.lua
run "console to console" tests/t_net.lua
run "pause guide and toasts" tests/t_pause.lua
run "attract mode" tests/t_attract.lua
run "soundtrack" tests/t_pianoroll.lua

echo "== rendering cost =="
run "per-frame budget" tests/t_bench.lua

echo "== input fuzz (every game, every mode) =="
for spec in "snake 3" "tetris 4" "breakout 3" "bombard 4" "minesweeper 3" \
            "g2048 1" "sokoban 3" "flappy 3" "pong 4" "meteors 1" \
            "lightsout 3" "simon 3" "connect4 4"; do
  set -- $spec
  game=$1
  modes=$2
  for m in $(seq 1 "$modes"); do
    run "$game mode $m" tests/t_game.lua "$game" "$m" 600 99999
  done
done

echo "== long sessions (bot-driven) =="
run "deep play" tests/t_deep.lua

echo "== end to end =="
run "boot, browse, play, quit" tests/t_boot.lua
run "themes" tests/t_themes.lua

echo "== sokoban level verification =="
if python solve_sokoban.py ../disk/gameos/games/sokoban.lua > out/sok.txt 2>&1; then
  echo "  PASS  all 12 levels solvable"
else
  echo "  FAIL  sokoban levels"
  cat out/sok.txt | sed 's/^/        /'
  fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi
exit $fail
