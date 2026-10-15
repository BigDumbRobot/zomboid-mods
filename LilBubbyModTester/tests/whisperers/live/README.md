# Live Whisperers tests

Runs the real Mac game client with local copies of The Whisperers and the tester in an isolated `-cachedir` folder. The default folder is `$TMPDIR/whisperers-live`; set `WHISP_LIVE_WORK` to use another. `~/Zomboid`, your saves and the Docker dev server are never touched. Nothing here is uploaded: the Workshop upload takes only `Contents/`.

```sh
bash tests/whisperers/live/run_live.sh "Craft 10 head stakes"   # start a world, then that feature
bash tests/whisperers/live/run_live.sh                           # just a world, for probing
bash tests/whisperers/live/probe.sh tests/whisperers/live/probes/stakes_and_car.lua
```

## What happens

1. **A fresh cache folder.** It gets the three mods, `mods/default.txt` enabling them and `reset-mods-42_00.txt`, so the list isn't emptied. `options.ini` accepts the terms of service and runs windowed with the sound off.
2. **A world starts on its own.** The game launches with `-nosteam -debug`. The throwaway `WhispLiveStart` mod has a `forceLaunch` debug scenario, so a world starts with no zombies.
3. **Click to Start.** The script clicks it if this terminal has macOS Accessibility permission. Otherwise it asks you to click.
4. **Moving outdoors.** `probes/move_outdoors.lua` moves the character to open ground when there's some within 40 tiles.
5. **Starting the feature.** It writes `only <feature>` to `Lua/LilBubbyAutoRun.txt`, and the tester starts just that feature. Results print to `console.txt` with the `[LilBubbyWhisperersTest]` prefix.

**Craft 10 head stakes** hands you one head and one stick at a time, then waits up to 10 minutes for you to craft the stake. It checks the stake and places it (automatic placement happens only in this test), then hands you the next head.

## Probes

`probe.sh` runs a Lua file inside the running game and prints the `WhispProbeResult` it sets:

| Probe | What it does |
|---|---|
| `where_am_i.lua` | Your position, whether you're outdoors, your carry weight |
| `move_outdoors.lua` | Moves you to open ground |
| `stakes_and_car.lua` | Places three stakes (the last one faceless) and a car beside you, to drive into |
| `list_stakes.lua` | Lists nearby stakes: their script, worn items and hair |

**Screenshots:** get the window bounds from System Events, then `screencapture -x -R<x>,<y>,<w>,<h> out.png`.

## Results

**2026-09-25:** Whisperers 1.1.0 on B42.20.4, single player. Ten stakes were crafted by hand, and all ten passed after the naming fix. A car stopped against the stakes.
