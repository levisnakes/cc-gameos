"""Verify every Sokoban level in the game module and report its optimal
push count. Uses BFS over (player-reachable-region, box positions) states,
which is exact for the push metric.

usage: python solve_sokoban.py [path/to/sokoban.lua]
"""
import re
import sys
import time
from collections import deque

DIRS = [(0, -1), (0, 1), (-1, 0), (1, 0)]


def parse_levels(path):
    src = open(path, encoding="latin1").read()
    body = src[src.index("local LEVELS = {"):]
    levels = []
    for block in re.finditer(r"\{ par = \d+, rows = \{(.*?)\n  \} \}", body, re.S):
        rows = re.findall(r'"([^"]*)"', block.group(1))
        if rows:
            levels.append(rows)
    return levels


def build(rows):
    h = len(rows)
    w = max(len(r) for r in rows)
    walls, goals, boxes, player = set(), set(), set(), None
    for y, line in enumerate(rows):
        line = line.ljust(w)
        for x, ch in enumerate(line):
            if ch == "#":
                walls.add((x, y))
            if ch in ".*+":
                goals.add((x, y))
            if ch in "$*":
                boxes.add((x, y))
            if ch in "@+":
                player = (x, y)
    return w, h, walls, goals, frozenset(boxes), player


def reachable(start, walls, boxes, w, h):
    seen = {start}
    stack = [start]
    while stack:
        x, y = stack.pop()
        for dx, dy in DIRS:
            n = (x + dx, y + dy)
            if n in seen or n in walls or n in boxes:
                continue
            if not (0 <= n[0] < w and 0 <= n[1] < h):
                continue
            seen.add(n)
            stack.append(n)
    return seen


def solve(rows, limit=3_000_000, seconds=90):
    w, h, walls, goals, boxes, player = build(rows)
    if player is None:
        return None, "no player"
    if len(boxes) != len(goals):
        return None, f"{len(boxes)} boxes vs {len(goals)} goals"

    floors = {(x, y) for x in range(w) for y in range(h) if (x, y) not in walls}

    # squares a box can never be pushed out of
    dead = set()
    for (x, y) in floors:
        if (x, y) in goals:
            continue
        up = (x, y - 1) in walls
        down = (x, y + 1) in walls
        left = (x - 1, y) in walls
        right = (x + 1, y) in walls
        if (up or down) and (left or right):
            dead.add((x, y))

    # a box pinned against a straight wall can only slide along it; if that
    # whole run holds no goal the box is already lost
    def run_dead(x, y, along, side):
        ax, ay = along
        sx, sy = side
        cells = [(x, y)]
        for step in (1, -1):
            cx, cy = x + ax * step, y + ay * step
            while True:
                if (cx, cy) in walls:
                    break                       # this end of the run is closed
                if (cx + sx, cy + sy) not in walls:
                    return []                   # the box can slide off the wall
                cells.append((cx, cy))
                cx, cy = cx + ax * step, cy + ay * step
        if any(c in goals for c in cells):
            return []
        return cells

    for (x, y) in list(floors):
        if (x, y) in goals or (x, y) in dead:
            continue
        for along, side in (((1, 0), (0, -1)), ((1, 0), (0, 1)),
                            ((0, 1), (-1, 0)), ((0, 1), (1, 0))):
            if (x + side[0], y + side[1]) in walls:
                dead.update(run_dead(x, y, along, side))

    def norm(p, bx):
        return min(reachable(p, walls, bx, w, h))

    start = (norm(player, boxes), boxes)
    if boxes == goals:
        return 0, None
    q = deque([(start, 0)])
    seen = {start}
    explored = 0
    deadline = time.time() + seconds
    while q:
        (anchor, bx), pushes = q.popleft()
        explored += 1
        if explored > limit:
            return None, f"node limit ({explored} states)"
        if explored % 4096 == 0 and time.time() > deadline:
            return None, f"timed out ({explored} states)"
        region = reachable(anchor, walls, bx, w, h)
        for box in bx:
            for dx, dy in DIRS:
                stand = (box[0] - dx, box[1] - dy)
                dest = (box[0] + dx, box[1] + dy)
                if stand not in region:
                    continue
                if dest in walls or dest in bx or dest in dead:
                    continue
                if not (0 <= dest[0] < w and 0 <= dest[1] < h):
                    continue
                nb = frozenset((bx - {box}) | {dest})
                if nb == goals:
                    return pushes + 1, None
                state = (norm(box, nb), nb)
                if state not in seen:
                    seen.add(state)
                    q.append((state, pushes + 1))
    return None, "unsolvable"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "../disk/gameos/games/sokoban.lua"
    levels = parse_levels(path)
    print(f"parsed {len(levels)} levels", flush=True)
    pars = []
    bad = 0
    for i, rows in enumerate(levels, 1):
        pushes, err = solve(rows)
        if pushes is None:
            print(f"  level {i:2d}: FAILED -- {err}", flush=True)
            pars.append(0)
            bad += 1
        else:
            print(f"  level {i:2d}: solvable, optimal {pushes} pushes", flush=True)
            pars.append(pushes)
    print("pars =", pars)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
