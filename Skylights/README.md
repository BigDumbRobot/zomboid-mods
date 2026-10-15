# Skylights (Build 42)

Adds a buildable skylight for player-built roofs. It lets daylight into the room
below, keeps the rain out, and can be walked on a few times before the glass
breaks.

## Building

In the **Build** menu under **Carpentry**, pick **Skylight** and place it over a
roof floor tile (level 1 or higher). Build time 150. Requires:

- a screwdriver or any `base:screwdriver` tool (kept);
- 4 screws and 4 planks (consumed);
- 1 window (consumed): any of the six vanilla movable house windows or the
  twelve vanilla vehicle panes (door windows, windshields, rear windshields).

The skylight replaces the roof tile it is placed on.

## Behaviour

- **Indoors:** the room keeps counting as indoors under any number of intact
  skylights.
- **Light:** each skylight lights the room below with a share of the outdoor
  light on the roof (sandbox **Indoor Brightness**), spread over the
  surrounding tiles; it follows day, night and weather.
- **Rain:** blocked.
- **Glass:** every time a player or zombie steps onto a skylight it may break
  (sandbox **Break Chance**). If it holds, it makes a quiet glass thump; if it
  breaks, it smashes with the vanilla window-break sound and whoever is standing
  on it falls into the room.
- **Broken skylight:** the hole lets full daylight in, and the tile under it
  counts as outdoors until a floor is built over it.
- **Multiplayer:** the server decides crossings, breaking and holes; clients
  only draw the light.

## Sandbox options

Under **Skylights** in the sandbox settings:

| Option | Range | Default | Meaning |
| --- | --- | --- | --- |
| Indoor Brightness | 0-100 | 80 | Light under a skylight as a percentage of outdoors. 100 = as bright as outside, 0 = dark. The spread to nearby tiles scales with it. |
| Break Chance | 0-100 | 20 | Percent chance the glass breaks each time a player or zombie steps onto it. 100 = first step, 0 = never. |

## Removal

Remove it with the vanilla construction-removal path (sledgehammer). The roof
tile it replaced is not restored.

## Files outside the mod

`art-source/` holds the source artwork and the readable form of
`media/skylights.tiles`; neither is uploaded.
