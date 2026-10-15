#!/usr/bin/env bash
# Multiplayer live Dead Man's Map test: a local -nosteam dedicated server and
# the real Mac client, both with the LOCAL mod (~/Zomboid/Workshop/DeadMansMap)
# and tester, in isolated cache folders. ~/Zomboid, your saves and the Docker
# dev server are never touched.
#
#   bash tests/deadmansmap/live/run_mp.sh ["feature"]   # default: "copy markings"
#   bash tests/deadmansmap/live/run_mp.sh none          # just join and leave it running for probe_mp.sh
#
# The client joins as a normal (non-admin) player. Screenshots of the map
# viewer land in $work/shots/. Server and client are stopped at the end.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
whisp="$here/../../whisperers/live"
workshop="$(cd "$here/../../../.." && pwd)"
work="${DMM_MP_WORK:-${TMPDIR:-/tmp}/dmm-live-mp}"
app="$HOME/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents"
java="$app/PlugIns/jre-aarch64/Contents/Home/bin/java"
[ "$(uname -m)" = "arm64" ] || java="$app/PlugIns/jre-x86_64/Contents/Home/bin/java"
feature="${1:-copy markings}"
srv="$work/server"; cli="$work/client"

cleanup() {
    [ -n "${cpid:-}" ] && kill "$cpid" 2>/dev/null || true
    # The server runs in a subshell; stop the java process itself.
    pkill -f "zombie.network.GameServer -cachedir=$srv" 2>/dev/null || true
    sleep 5
    pkill -9 -f "zombie.network.GameServer -cachedir=$srv" 2>/dev/null || true
}
trap cleanup EXIT

pkill -9 -f "zombie.network.GameServer -cachedir=$srv" 2>/dev/null && sleep 3 || true   # a server left by an earlier run
rm -rf "$work"
mkdir -p "$srv/mods" "$srv/Server" "$cli/mods" "$cli/Lua" "$work/shots"
for dir in "$srv/mods" "$cli/mods"; do
    cp -R "$workshop/DeadMansMap/Contents/mods/DeadMansMap" "$dir/"
    cp -R "$workshop/LilBubbyModTester/Contents/mods/LilBubbyModTester" "$dir/"
    cp -R "$here/DMMMPStart" "$dir/"
done
cat > "$srv/Server/dmmtest.ini" <<INI
Mods=DeadMansMap;LilBubbyModTester;DMMMPStart
WorkshopItems=
Map=Muldraugh, KY
DefaultPort=16361
UDPPort=16362
Public=false
Open=true
Password=
PauseEmpty=false
SpawnPoint=10645,10437,0
INI
# No zombies: an idle test character is otherwise killed at the spawn point.
cp "$here/server_SandboxVars.lua" "$srv/Server/dmmtest_SandboxVars.lua"
touch "$srv/mods/reset-mods-42_00.txt" "$cli/mods/reset-mods-42_00.txt"
printf 'VERSION = 1,\n\nmods\n{\n    mod = DMMMPStart,\n}\n\nmaps\n{\n}\n' > "$cli/mods/default.txt"
printf 'version=1\ntermsOfServiceVersion=1\nfullScreen=false\nwidth=1280\nheight=720\nsoundVolume=0\nmusicVolume=0\nambientVolume=0\nvoiceVolume=0\nvoiceEnable=false\nshowSurvivalGuide=false\ntutorialDone=true\n' > "$cli/options.ini"

echo "--- starting server (log: $srv/server-console.txt)"
(cd "$app/Java" && "$java" -Djava.library.path=. --enable-native-access=ALL-UNNAMED \
    --add-exports=java.base/jdk.internal.misc=ALL-UNNAMED -Dzomboid.steam=0 -Xms2g -Xmx4g \
    -cp .:projectzomboid.jar zombie.network.GameServer \
    "-cachedir=$srv" -servername dmmtest -adminusername admin -adminpassword dmmtestadmin \
    > "$work/server.out" 2>&1 < /dev/null) &
spid=$!
for _ in $(seq 1 120); do
    kill -0 "$spid" 2>/dev/null || { echo "FAIL the server exited"; tail -30 "$work/server.out"; exit 1; }
    grep -q 'SERVER STARTED' "$work/server.out" 2>/dev/null && break
    sleep 3
done
grep -q 'SERVER STARTED' "$work/server.out" || { echo "FAIL the server never started"; tail -30 "$work/server.out"; exit 1; }
grep -E 'loading (DeadMansMap|LilBubbyModTester|DMMMPStart)' "$work/server.out" | sed 's/^/    /' || true
echo "--- server up"

clicker="${TMPDIR:-/tmp}/pz-live-click"
[ -x "$clicker" ] || swiftc -O "$whisp/click.swift" -o "$clicker"
echo "--- launching client (log: $cli/console.txt)"
"$app/MacOS/JavaAppLauncher" "-cachedir=$cli" -nosteam > "$work/client.out" 2>&1 &
cpid=$!

# Bounds x,y,w,h of the game's largest window.
window() {
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $cpid)
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

# Connect and character creation are automatic; "Click to Start" needs a real click.
for _ in $(seq 1 200); do
    kill -0 "$cpid" 2>/dev/null || { echo "FAIL the client exited"; exit 1; }
    grep -q '\[DMMMP\] game started' "$cli/console.txt" 2>/dev/null && break
    if grep -q 'game loading took' "$cli/console.txt" 2>/dev/null; then
        bounds=$(window)
        if [ -n "$bounds" ]; then
            IFS=, read -r x y w h <<< "$bounds"
            osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $cpid) to true" >/dev/null 2>&1 || true
            "$clicker" $((x + w / 2)) $((y + h * 93 / 100)) >/dev/null 2>&1 \
                || echo ">>> CLICK INSIDE THE GAME WINDOW to pass Click to Start"
        fi
    fi
    sleep 3
done
grep '\[DMMMP\]' "$cli/console.txt" | sed 's/^/    /' || true
grep -q '\[DMMMP\] game started' "$cli/console.txt" || { echo "FAIL the client never joined"; exit 1; }
echo "--- client in the world"
sleep 10

if [ "$feature" = "none" ]; then
    trap - EXIT
    echo "--- left running for probes (bash $here/probe_mp.sh <file>); stop with: kill $cpid; pkill -f 'GameServer -cachedir=$srv'"
    exit 0
fi
echo "only $feature" > "$cli/Lua/LilBubbyAutoRun.txt"
echo "--- started: $feature"
shot=0
for _ in $(seq 1 240); do
    kill -0 "$cpid" 2>/dev/null || { echo "FAIL the client exited during the test"; break; }
    snaps=$(grep -o '\[LilBubbyDMMTest\] SNAPSHOT .*' "$cli/console.txt" | awk '{print $3}' || true)
    count=$(printf '%s\n' "$snaps" | grep -c . || true)
    while [ "$shot" -lt "$count" ]; do
        shot=$((shot + 1))
        name=$(printf '%s\n' "$snaps" | sed -n "${shot}p")
        bounds=$(window)
        if [ -n "$bounds" ]; then
            IFS=, read -r x y w h <<< "$bounds"
            screencapture -x -R"$x,$y,$w,$h" "$work/shots/$name.png" && echo "--- screenshot $work/shots/$name.png"
        fi
    done
    grep -q 'LilBubbyAutoRun\] Run every test | ' "$cli/console.txt" 2>/dev/null && break
    sleep 1
done

echo "--- client report"
grep '\[LilBubbyDMMTest\]' "$cli/console.txt" | grep -v SNAPSHOT | sed 's/.*\[LilBubbyDMMTest\] //' || true
echo "--- server log (tester + mod)"
grep -E '\[LilBubbyDMMTest\]|\[DeadMansMap\].*(ERROR|WARN)|Exception' "$work/server.out" | tail -20 || true
