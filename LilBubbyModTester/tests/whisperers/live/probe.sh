#!/usr/bin/env bash
# Runs a Lua file inside the live game started by run_live.sh and prints the
# WhispProbeResult it sets. B42's Lua has no loadstring, so the file is copied
# over the world-start mod's WhispProbe.lua and reloaded there.
#
#   bash tests/whisperers/live/probe.sh probes/where_am_i.lua
set -euo pipefail

work="${WHISP_LIVE_WORK:-${TMPDIR:-/tmp}/whisperers-live}"
cp "$1" "$work/mods/WhispLiveStart/42/media/lua/client/WhispProbe.lua"
rm -f "$work/Lua/WhispLiveEval_out.txt"
echo run > "$work/Lua/WhispLiveEval.txt"
for _ in $(seq 1 60); do
    if [ -s "$work/Lua/WhispLiveEval_out.txt" ]; then cat "$work/Lua/WhispLiveEval_out.txt"; exit 0; fi
    sleep 0.5
done
echo "NO RESULT (is the game in a world? see $work/console.txt)"
exit 1
