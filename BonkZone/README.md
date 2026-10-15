# Bonk Zone

Bonk Zone is a standalone Project Zomboid Build 42 multiplayer mod. It adds a **Bonk Zones** mode to the vanilla Multiplayer Zone Editor, displays every zone on every player's world map and minimap, and suppresses ranged player-versus-player damage when the target is inside a Bonk Zone.

## Behavior

- Administrators with the vanilla `CanSetupNonPVPZone` capability can add, resize, rename, and remove Bonk Zones.
- There is no artificial zone-count limit.
- Zones cover every floor from z=-32 through z=31.
- Zones may overlap one another.
- The server owns and persists all zone definitions.
- Zone changes are permission-checked, synchronized to every connected player, and logged.
- Bonk Zones are rendered independently of player exploration and map-symbol visibility.
- Melee attacks, shoves, and stomps are unaffected.
- Ranged attacks against zombies and animals are unaffected.
- A ranged player hit is suppressed when the target is inside any Bonk Zone.
- A blocked shot still fires normally, consumes ammunition, makes noise, and can attract zombies.
- Conventional firearms and modded `HandWeapon` weapons reporting `weapon:isRanged()` are covered.

## Install

### Local or hosted game

Copy `Contents/mods/BonkZone` into your Project Zomboid Workshop staging directory, or install the Workshop item after it has been uploaded. Enable mod ID:

```text
BonkZone
```

### Dedicated server

Add the Workshop ID after the first upload to `WorkshopItems=` and add this to `Mods=`:

```text
BonkZone
```

The server owns zone definitions, persistence, permission checks, and the ranged-PvP damage suppression. Clients need the mod for the map/minimap overlays, the zone editor, enter/exit notices, and the blocked-shot notice; a client without it still cannot deal ranged PvP damage inside a zone, because the server enforces it.

## Admin use

1. Join as a server administrator, or with a custom role granted the vanilla `CanSetupNonPVPZone` capability. No other access level (moderator, gm, observer) can edit zones.
2. Open the vanilla Multiplayer Zone Editor.
3. Select **Bonk Zones** from the mode dropdown.
4. Choose **Add Bonk Zone**.
5. Click and drag the rectangle on the map.
6. Name the zone and confirm.
7. Select an existing zone to resize, rename, or remove it.

## Border rule

Ranged PvP is blocked whenever the target is inside the zone:

| Attacker | Target | Result |
| --- | --- | --- |
| Inside | Inside | Blocked |
| Outside | Inside | Blocked |
| Inside | Outside | Allowed |
| Outside | Outside | Allowed |

## Logging

Runtime messages use the `[BonkZone]` prefix. The shared logger records function timings and bounded recent entries. A compiled `MetaTimeRunLog` is printed during initialization and each world-save event. Blocked ranged PvP audit lines include the attacker's username, target, weapon type, zone ID, and attacker coordinates, rate-limited per attacker/weapon.

## Technical combat note

Build 42 applies player-versus-player weapon damage only on the server: `IsoPlayer.hitConsequences` calls `DamageFromWeapon()` in the server branch while every client only splats blood. `IsoGameCharacter.Hit()` fires `OnWeaponHitCharacter` (server included) and then honours the one-shot `AvoidDamage` flag before any damage is applied.

Bonk Zone hooks `OnWeaponHitCharacter` **on the server**. For a ranged hit where the target is inside a Bonk Zone, it sets the target's `AvoidDamage` flag and decrements the attacker's hit count, so `Hit()` returns before `hitConsequences` and no damage, bleeding, or knockback is applied. The engine clears `AvoidDamage` each hit; the handler re-arms it for every pellet and shot. The server then sends the attacker's client a throttled blocked-shot notice.

This is server-authoritative, so a client without the mod still cannot deal ranged PvP damage in a zone. It is not an anti-cheat system: the server trusts that a hit packet arrived, and does not reconstruct trajectories. See `docs/engine-notes.md` for the decompiled call path.

## Out of scope

Bonk Zone does not currently classify indirect damage such as fire, vehicle impacts, traps, or explosions as ranged PvP. Those systems do not consistently pass through the standard ranged `HandWeapon` hit callback.
