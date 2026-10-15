# Dead Man's Map

Dead Man's Map is a Project Zomboid Build 42 multiplayer mod. When a local player dies, the mod snapshots every annotation on that character's personal world map, links the snapshot to that player's `IsoDeadBody`, drops it as a physical `Base.Map` world object on the square where the player died, and then wipes those markings from the dead character's personal map.

A player may reanimate after death, so the Annotated Map is placed directly on the ground rather than in the corpse inventory. The drop happens immediately; when the player's `IsoDeadBody` is available, the map and corpse receive reciprocal persistent tags containing the death-map ID and corpse identity.

The dropped item is named exactly:

`<Player Name>'s Annotated Map`

Anyone who reaches the death site can pick up the map and open it with Project Zomboid's normal map UI. Its paper view loads the active world (including map mods) and is bounded around the copied markings, or around the death location when the map was empty. The item contains the annotations, but not the dead player's explored-map/fog-of-war data.

Right-clicking an Annotated Map (in inventory or the floor/loot panel) also offers **Copy Markings to My Map**, and the map viewer shows a matching **Copy markings to my map** button beside its other buttons when the open map is an Annotated Map. Copying needs a writing tool (any item the game tags as one, such as a pen or pencil, the same rule as vanilla's Edit Markings); without one, the option and the button are drawn in red and cannot be used. Either one merges that map's annotations onto the finder's own personal map. Markings already on the personal map at the same position with the same text/symbol are skipped, so copying the same map twice (or copying overlapping maps from several victims) doesn't create duplicates, and the merge never grows the personal map past the same 5000-annotation safety cap used for death maps. The Annotated Map itself is not consumed, so it can still be read normally or handed off to someone else afterward.

## What happens on death

1. Every text note and symbol on the dying character's personal map is copied onto a fresh `Base.Map` named exactly `<Player Name>'s Annotated Map`. A map is created even when there are no annotations. The Annotated Map always carries the complete set of markings (up to a non-configurable 5000-entry safety cap that protects the save file from drawing mods that generate tens of thousands of symbols).
2. The named Annotated Map is dropped as a world object on the death square, or the nearest usable square within a few tiles if that square cannot hold an item.
3. When the dead player's `IsoDeadBody` is available, it is matched by player identity (or by character name and death time in single-player), and both objects are cross-tagged. A delayed or missing corpse never blocks the map drop.
4. The dead character's personal map is wiped of all annotations. This is a hard rule of the mod and cannot be disabled, so every new character starts without the previous character's markings.

The snapshot and mandatory wipe happen immediately at death, while the dying character's personal map is still available. Corpse linking is best-effort and never prevents the Annotated Map from being dropped. Once the personal-map API is available, the wipe is still enforced if physical map creation, annotation copying, or item tagging fails.

## Installation

The archive already uses the Workshop layout.

For a local install, copy this folder:

`Contents/mods/DeadMansMap`

to:

`C:\Users\<you>\Zomboid\mods\DeadMansMap`

For a multiplayer server, install and enable `DeadMansMap` as both a server mod and a client mod. Restart the server after changing sandbox settings.

## Sandbox settings

| Setting | Default | Purpose |
|---|---:|---|
| Verbose console logging | Off | Print DEBUG function traces as they happen |

Every death transaction compiles all of its structured entries into a Meta Time Run Log. Normal mode prints the important entries and a DEBUG-entry count; verbose logging prints the complete trace. The full latest run is also available at `DeadMansMap.Logger.lastMetaTimeRunLog.lines`. For a manual snapshot in the Lua debugger/console, call:

```lua
DeadMansMap.DumpMetaTimeRunLog()
```

## Multiplayer trust model

Personal map annotations live on each player's client. The mod therefore snapshots and wipes the dying player's map there, sends the annotation data to the server in bounded batches, and waits for acknowledgment. The server verifies that player is dead, reconstructs the native `MapItem`, and performs the authoritative world drop. Corpse metadata is linked afterward when the matching `IsoDeadBody` becomes available.

As with any client-originated Project Zomboid behavior, a deliberately modified or noncompliant client can suppress its own death-map creation. Server-side Lua cannot reconstruct annotations that the client never sent.

## Compatibility notes

- Target: Project Zomboid Build 42.15 or newer.
- No other mods are required.
- Text, symbol type, location, color, anchor, scale, rotation, visibility, and zoom behavior are copied through the installed Build 42 APIs.
- The capture path does not call Project Zomboid's default-annotation initializer, so it does not add vanilla map labels to the snapshot itself.
- Drawing mods can generate thousands of tiny symbols. The 5000-entry safety cap keeps player/item saves from becoming oversized.

## Source layout

- `DMM_Logger.lua`: structured logging and Meta Time Run Log compiler.
- `DMM_Core.lua`: settings, naming, IDs, metadata, and guarded API calls.
- `DMM_MapSnapshot.lua`: reads annotations through the `UIWorldMapV2` symbols view, writes and clears through `MapItem`/`WorldMapSymbols`, and persists the personal-map wipe.
- `DMM_DeathDrop.lua`: client death handling, `IsoDeadBody` matching, direct single-player drops, retries, and multiplayer batching/acknowledgment.
- `DMM_ServerDrop.lua`: server-side annotation reconstruction, authoritative multiplayer drop, and corpse-link updates.
- `DMM_MapMerge.lua`: client "Copy Markings to My Map" context-menu option and map-viewer button (both gated on a writing tool), merging a found Annotated Map's symbols onto the finder's personal map.

## Version

1.5.0

- Copy Markings to My Map now needs a pen or pencil. Without one, the option and the button are red and can't be used.
- New **Copy markings to my map** button in the map viewer when an Annotated Map is open.
- Fixed (multiplayer): Copy Markings to My Map on a map lying on the ground picked the map up but copied nothing, and left a transfer stuck in the action queue. It now copies after the pick-up.
- Fixed: the "could not read", "no new markings" and "map is full" messages after copying threw an error instead of showing.
