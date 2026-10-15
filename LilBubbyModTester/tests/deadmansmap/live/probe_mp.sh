#!/usr/bin/env bash
# Runs a Lua file inside the multiplayer client started by run_mp.sh (with
# no feature) and prints the DMMMPProbeResult it sets.
#   bash tests/deadmansmap/live/probe_mp.sh probes/some_probe.lua
set -euo pipefail
work="${DMM_MP_WORK:-${TMPDIR:-/tmp}/dmm-live-mp}"
cp "$1" "$work/client/mods/DMMMPStart/42/media/lua/client/DMMMPProbe.lua"
rm -f "$work/client/Lua/DMMMPEval_out.txt"
echo run > "$work/client/Lua/DMMMPEval.txt"
for _ in $(seq 1 60); do
    if [ -s "$work/client/Lua/DMMMPEval_out.txt" ]; then cat "$work/client/Lua/DMMMPEval_out.txt"; exit 0; fi
    sleep 0.5
done
echo "NO RESULT (is the client in the world? see $work/client/console.txt)"
exit 1
