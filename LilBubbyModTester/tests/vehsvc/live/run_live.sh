#!/usr/bin/env bash
# Live COMPUTER Vehicle Claims test with the real Mac game client and the
# LOCAL mods (~/Zomboid/Workshop/KIPN, KIPNVehicleServices and this tester),
# in an isolated cache folder: ~/Zomboid and your saves are never touched.
# Reuses the Whisperers live start mod, clicker and probe
# (see tests/whisperers/live/README.md).
#
#   bash tests/vehsvc/live/run_live.sh ["feature" | none]   # default: "Vehicle claim lifecycle"
#
# "none" leaves the game running in a world, for probes:
#   WHISP_LIVE_WORK="${TMPDIR:-/tmp}/vehsvc-live" bash tests/whisperers/live/probe.sh <file>
# The game is closed when the report arrives.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
whisp="$here/../../whisperers/live"
workshop="$(cd "$here/../../../.." && pwd)"             # ~/Zomboid/Workshop
work="${VEHSVC_LIVE_WORK:-${TMPDIR:-/tmp}/vehsvc-live}"
export WHISP_LIVE_WORK="$work"                          # for probe.sh
app="$HOME/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents"
launcher="$app/MacOS/JavaAppLauncher"
feature="${1:-Vehicle claim lifecycle}"
timeout="${VEHSVC_LIVE_TIMEOUT:-900}"                   # seconds to wait for the report

rm -rf "$work"
mkdir -p "$work/mods" "$work/Lua" "$work/shots"
cp -R "$workshop/KIPN/Contents/mods/KIPN" "$work/mods/"
cp -R "$workshop/KIPNVehicleServices/Contents/mods/KIPNVehicleServices" "$work/mods/"
cp -R "$workshop/LilBubbyModTester/Contents/mods/LilBubbyModTester" "$work/mods/"
cp -R "$whisp/WhispLiveStart" "$work/mods/"
printf 'VERSION = 1,\n\nmods\n{\n    mod = KIPN,\n    mod = KIPNVehicleServices,\n    mod = LilBubbyModTester,\n    mod = WhispLiveStart,\n}\n\nmaps\n{\n}\n' > "$work/mods/default.txt"
touch "$work/mods/reset-mods-42_00.txt"
printf 'version=1\ntermsOfServiceVersion=1\nfullScreen=false\nwidth=1280\nheight=720\nsoundVolume=0\nmusicVolume=0\nambientVolume=0\nvoiceVolume=0\nvoiceEnable=false\nshowSurvivalGuide=false\ntutorialDone=true\n' > "$work/options.ini"

clicker="${TMPDIR:-/tmp}/pz-live-click"
[ -x "$clicker" ] || swiftc -O "$whisp/click.swift" -o "$clicker"

echo "--- launching (log: $work/console.txt)"
"$launcher" "-cachedir=$work" -nosteam -debug > "$work/launcher.out" 2>&1 &
pid=$!
echo "$pid" > "$work/game.pid"

# Bounds x,y,w,h of the game's largest window (tooltips and popups are windows too).
window() {
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid)
        set best to \"\"
        set bestArea to 0
        repeat with w in windows
            set {px, py} to position of w
            set {sw, sh} to size of w
            if sw * sh > bestArea then
                set bestArea to sw * sh
                set best to (px as text) & \",\" & (py as text) & \",\" & (sw as text) & \",\" & (sh as text)
            end if
        end repeat
        return best
    end tell" 2>/dev/null | tr -d ' ' || true
}
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 || true; }

for _ in $(seq 1 120); do
    kill -0 "$pid" 2>/dev/null || { echo "FAIL the game exited while loading"; exit 1; }
    grep -q 'game loading took' "$work/console.txt" 2>/dev/null && break
    sleep 3
done
for _ in $(seq 1 60); do
    grep -q '\[WhispLive\] game started' "$work/console.txt" 2>/dev/null && break
    bounds=$(window)
    if [ -n "$bounds" ]; then
        IFS=, read -r x y w h <<< "$bounds"
        front
        "$clicker" $((x + w / 2)) $((y + h * 93 / 100)) >/dev/null 2>&1 \
            || echo ">>> CLICK INSIDE THE GAME WINDOW to pass Click to Start"
    fi
    sleep 3
done
grep -q '\[WhispLive\] game started' "$work/console.txt" || { echo "FAIL the world never started"; exit 1; }
echo "--- in the world"
sleep 8
front

if [ "$feature" = "none" ]; then
    echo "--- left running (pid $pid). Probes: WHISP_LIVE_WORK=$work bash $whisp/probe.sh <file>"
    exit 0
fi

echo "only $feature" > "$work/Lua/LilBubbyAutoRun.txt"
echo "--- started: $feature"
for _ in $(seq 1 "$timeout"); do
    kill -0 "$pid" 2>/dev/null || { echo "FAIL the game exited during the test"; exit 1; }
    grep -q 'Run every test | ' "$work/console.txt" 2>/dev/null && break
    front
    sleep 1
done

echo "--- report"
grep '\[LilBubbyVehSvcTest\]' "$work/console.txt" | tr '|' '\n' | sed 's/^ //' || true
grep '\[LilBubbyAutoRun\]' "$work/console.txt" | tail -5 || true
bounds=$(window)
if [ -n "$bounds" ]; then
    IFS=, read -r x y w h <<< "$bounds"
    screencapture -x -R"$x,$y,$w,$h" "$work/shots/end.png" && echo "--- screenshot $work/shots/end.png"
fi
[ -n "${VEHSVC_LIVE_KEEP:-}" ] || kill "$pid" 2>/dev/null || true
