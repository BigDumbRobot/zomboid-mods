# Live Satanic Temples tests

Runs the real Mac game client with a local copy of Satanic Temples in an isolated `-cachedir` folder. The default folder is `$TMPDIR/satanictemples-live`; set `ST_LIVE_WORK` to use another. `~/Zomboid`, your saves and the Docker dev server are never touched. Nothing here is uploaded: the Workshop upload takes only `Contents/`.

```sh
bash tests/satanictemples/live/run_live.sh suite    # start a world, then the full offering suite
ST_LIVE_SOUND=1 bash tests/satanictemples/live/run_live.sh suite   # same, with game sounds on
bash tests/satanictemples/live/run_live.sh          # just a world, for probing
bash tests/satanictemples/live/probe.sh tests/satanictemples/live/probes/inspect_temple.lua
```

## What the person at the keyboard does

- **Nothing, except keep the game window in front.** The game pauses whenever another window is in front, and the suite stops with it.
- **A red panel at the top of the game** always says what is happening: loading, `AUTOMATED TEST 5 of 28 ... Now: <test>`, a death notice, and finally `TESTS FINISHED`.
- **One death is planned**, near the end. The panel says so: click through the death screen and create any character. The suite teleports the new character back to the temple and carries on. Any other death is a finding; the suite retries that test once.

## What happens

1. **A fresh cache folder** with the mod and the throwaway `STLiveStart` mod, `mods/default.txt`, `reset-mods-42_00.txt` and an `options.ini` that accepts the terms of service and turns the sound off.
2. **A world starts on its own** through `STLiveStart`'s `forceLaunch` debug scenario. The script clicks past Click to Start (macOS Accessibility permission) and brings the window to the front.
3. **Zombies are kept away.** `STLiveStart` makes the character invisible to zombies and removes any zombie within 60 tiles every 2 seconds. Damage still applies, so punishments are measured normally.
4. **The suite** (`probes/offerings_suite.lua`) builds a temple beside you and runs its cases one at a time, printing `[STOffer] PASS|FAIL|DIED|RETRY | <case> | <detail>` to `console.txt`, then `[STOffer] DONE pass=N fail=M deaths=D`. The temple stays up with its campfire lit.

The suite is ticked by `STLiveStart`'s boot-time poll handler: an `Events.OnTick` handler added from a reloaded probe file never fired.

## Probes

`probe.sh` runs a Lua file inside the running game and prints the `STProbeResult` it sets. Each probe runs once per request (a token guard stops the game's own file-reload from running it a second time).

| Probe | What it does |
|---|---|
| `setup_temple.lua` | Moves you to open ground and creates a 13 x 13 temple north of you |
| `inspect_temple.lua` | Skeleton scripts and katanas, pumpkins, their lights, and what the client knows |
| `protection_and_theft.lua` | Every protection guard, plus one katana theft from full health |
| `repair_pass.lua` | Steals a katana, reverts a skeleton to an old clothed mannequin and removes a pumpkin, then runs the integrity pass twice |
| `night_view.lua` | Sets 23:00 and stands you south of the altar, for a screenshot of the glow |
| `remove_temple.lua` | Deletes the temple and checks nothing is left behind |
| `player_health.lua` | Health, each injured body part, and zombies within 30 tiles |
| `count_lights.lua` | Counts the jack-o'-lantern lights |
| `offerings_suite.lua` | The full suite (see above) |

**Screenshots:** get the window bounds from System Events, then `screencapture -x -R<x>,<y>,<w>,<h> out.png`. Capture only while the game is in front, or you get whatever window covers it.
