#!/usr/bin/env bash
# Runs a Lua file inside the multiplayer client started by run_mp.sh (with
# no feature) and prints the VehSvcMPProbeResult it sets.
#   bash tests/vehsvc/live/probe_mp.sh probes/some_probe.lua
set -euo pipefail
work="${VEHSVC_MP_WORK:-${TMPDIR:-/tmp}/vehsvc-live-mp}"
cp "$1" "$work/client/mods/VehSvcMPStart/42/media/lua/client/VehSvcMPProbe.lua"
rm -f "$work/client/Lua/VehSvcMPEval_out.txt"
echo run > "$work/client/Lua/VehSvcMPEval.txt"
for _ in $(seq 1 60); do
    if [ -s "$work/client/Lua/VehSvcMPEval_out.txt" ]; then cat "$work/client/Lua/VehSvcMPEval_out.txt"; exit 0; fi
    sleep 0.5
done
echo "NO RESULT (is the client in the world? see $work/client/console.txt)"
exit 1
