#!/usr/bin/env bash
# Runs a Lua file inside the live game started by run_live.sh and prints the
# STProbeResult it sets. B42's Lua has no loadstring, so the file is copied
# over the world-start mod's STProbe.lua and reloaded there.
#
#   bash tests/satanictemples/live/probe.sh probes/inspect_temple.lua
set -euo pipefail

work="${ST_LIVE_WORK:-${TMPDIR:-/tmp}/satanictemples-live}"
# Run-once guard: in -debug the game may reload a changed Lua file on its own;
# the body only runs when the poller has issued a new token.
{ echo 'if STProbeToken and STProbeToken ~= STProbeLastRan then STProbeLastRan = STProbeToken'; cat "$1"; echo; echo 'end'; } \
    > "$work/mods/STLiveStart/42/media/lua/client/STProbe.lua"
rm -f "$work/Lua/STLiveEval_out.txt"
echo run > "$work/Lua/STLiveEval.txt"
for _ in $(seq 1 60); do
    if [ -s "$work/Lua/STLiveEval_out.txt" ]; then cat "$work/Lua/STLiveEval_out.txt"; exit 0; fi
    sleep 0.5
done
echo "NO RESULT (is the game window in front? it pauses otherwise; see $work/console.txt)"
exit 1
