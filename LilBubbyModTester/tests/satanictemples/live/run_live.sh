#!/usr/bin/env bash
# Live Satanic Temples test with the real Mac game client, in an isolated cache
# folder: ~/Zomboid and your saves are never touched. See README.md.
#
#   bash tests/satanictemples/live/run_live.sh [suite]
#
# suite: pass "suite" to start probes/offerings_suite.lua once the world is up.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
workshop="$(cd "$here/../../../.." && pwd)"             # ~/Zomboid/Workshop
work="${ST_LIVE_WORK:-${TMPDIR:-/tmp}/satanictemples-live}"
app="$HOME/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents"
launcher="$app/MacOS/JavaAppLauncher"

# A fresh cache folder: local copies of the mod and the world-start mod, terms
# of service accepted, windowed and silent, no old saves.
rm -rf "$work"
mkdir -p "$work/mods" "$work/Lua"
cp -R "$workshop/SatanicTemples/Contents/mods/SatanicTemples" "$work/mods/"
cp -R "$here/STLiveStart" "$work/mods/"
printf 'VERSION = 1,\n\nmods\n{\n    mod = SatanicTemples,\n    mod = STLiveStart,\n}\n\nmaps\n{\n}\n' > "$work/mods/default.txt"
touch "$work/mods/reset-mods-42_00.txt"
# Silent by default; ST_LIVE_SOUND=1 turns game sounds on (to hear the ritual).
volume=0; [ "${ST_LIVE_SOUND:-0}" = "1" ] && volume=8
printf 'version=1\ntermsOfServiceVersion=1\nfullScreen=false\nwidth=1280\nheight=720\nsoundVolume=%s\nmusicVolume=0\nambientVolume=0\nvoiceVolume=0\nvoiceEnable=false\n' "$volume" > "$work/options.ini"

echo "--- launching (log: $work/console.txt)"
"$launcher" "-cachedir=$work" -nosteam -debug > "$work/launcher.out" 2>&1 &
pid=$!
echo "$pid" > "$work/game.pid"

# The world loads, then waits on "Click to Start". Click the window when this
# terminal has Accessibility permission; otherwise ask for a click.
for _ in $(seq 1 120); do
    kill -0 "$pid" 2>/dev/null || { echo "FAIL the game exited while loading"; exit 1; }
    grep -q 'game loading took' "$work/console.txt" 2>/dev/null && break
    sleep 3
done
for _ in $(seq 1 60); do
    grep -q '\[STLive\] game started' "$work/console.txt" 2>/dev/null && break
    bounds=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to get {position, size} of window 1" 2>/dev/null | tr -d ' ' || true)
    if [ -n "$bounds" ]; then
        IFS=, read -r x y w h <<< "$bounds"
        osascript -e "tell application \"System Events\" to click at {$((x + w / 2)), $((y + h * 3 / 4))}" >/dev/null 2>&1 \
            || echo ">>> CLICK INSIDE THE GAME WINDOW to pass Click to Start"
    fi
    sleep 3
done
grep -q '\[STLive\] game started' "$work/console.txt" || { echo "FAIL the world never started"; exit 1; }
echo "--- in the world"

# The game pauses whenever its window is not in front: bring it forward.
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 || true
sleep 5
if [ "${1:-}" = "suite" ]; then
    bash "$here/probe.sh" "$here/probes/offerings_suite.lua"
    echo "--- suite started: results stream to $work/console.txt as [STOffer] lines"
fi
echo "--- game pid $pid; stop it with: kill $pid"
