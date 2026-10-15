#!/usr/bin/env bash
# Live Whisperers test with the real Mac game client, in an isolated cache
# folder: ~/Zomboid and your saves are never touched. See README.md.
#
#   bash tests/whisperers/live/run_live.sh [feature]
#
# feature: a tester feature name (or part of one) to start once the world is
# up, e.g. "Craft 10 head stakes". Leave it out to just get a world to probe.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
workshop="$(cd "$here/../../../.." && pwd)"             # ~/Zomboid/Workshop
work="${WHISP_LIVE_WORK:-${TMPDIR:-/tmp}/whisperers-live}"
app="$HOME/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents"
launcher="$app/MacOS/JavaAppLauncher"
feature="${1:-}"

# A fresh cache folder: local copies of the mod, the tester and the world-start
# mod, terms of service accepted, windowed and silent, no old saves.
rm -rf "$work"
mkdir -p "$work/mods" "$work/Lua"
cp -R "$workshop/TheWhisperers/Contents/mods/TheWhisperers" "$work/mods/"
cp -R "$workshop/LilBubbyModTester/Contents/mods/LilBubbyModTester" "$work/mods/"
cp -R "$here/WhispLiveStart" "$work/mods/"
printf 'VERSION = 1,\n\nmods\n{\n    mod = TheWhisperers,\n    mod = LilBubbyModTester,\n    mod = WhispLiveStart,\n}\n\nmaps\n{\n}\n' > "$work/mods/default.txt"
touch "$work/mods/reset-mods-42_00.txt"
printf 'version=1\ntermsOfServiceVersion=1\nfullScreen=false\nwidth=1280\nheight=720\nsoundVolume=0\nmusicVolume=0\nambientVolume=0\nvoiceVolume=0\nvoiceEnable=false\nshowSurvivalGuide=false\ntutorialDone=true\n' > "$work/options.ini"

clicker="${TMPDIR:-/tmp}/pz-live-click"
[ -x "$clicker" ] || swiftc -O "$here/click.swift" -o "$clicker"

echo "--- launching (log: $work/console.txt)"
"$launcher" "-cachedir=$work" -nosteam -debug > "$work/launcher.out" 2>&1 &
pid=$!
echo "$pid" > "$work/game.pid"

# The world loads, then waits on "Click to Start". Click the window's centre
# when this terminal has Accessibility permission; otherwise ask for a click.
for _ in $(seq 1 120); do
    kill -0 "$pid" 2>/dev/null || { echo "FAIL the game exited while loading"; exit 1; }
    grep -q 'game loading took' "$work/console.txt" 2>/dev/null && break
    sleep 3
done
for _ in $(seq 1 60); do
    grep -q '\[WhispLive\] game started' "$work/console.txt" 2>/dev/null && break
    bounds=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to get {position, size} of window 1" 2>/dev/null | tr -d ' ' || true)
    if [ -n "$bounds" ]; then
        IFS=, read -r x y w h <<< "$bounds"
        osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 || true
        # A real mouse click on the "Click to Start" text (System Events' own click often doesn't reach the game).
        "$clicker" $((x + w / 2)) $((y + h * 93 / 100)) >/dev/null 2>&1 \
            || echo ">>> CLICK INSIDE THE GAME WINDOW to pass Click to Start"
    fi
    sleep 3
done
grep -q '\[WhispLive\] game started' "$work/console.txt" || { echo "FAIL the world never started"; exit 1; }
echo "--- in the world"

sleep 8
bash "$here/probe.sh" "$here/probes/move_outdoors.lua" || true

if [ -n "$feature" ]; then
    echo "only $feature" > "$work/Lua/LilBubbyAutoRun.txt"
    echo "--- started: $feature (results stream to $work/console.txt)"
fi
echo "--- game pid $pid; stop it with: kill $pid"
