# KIPN: Legend of the Red Dragon

A full **BBS door game** for the [KIP Network](../KIPN) terminal, in the style of
Seth Able Robinson's *Legend of the Red Dragon* (1989) — tuned for casual
multiplayer play.

It registers as its own Workshop mod (`require=KIPN`) and adds one main-menu
program, **Play LORD**, that appears on **every computer for any logged-in KIPN
account, in any zone or no zone**.

## The loop

Right-click a powered computer → *Access KIP Network* → log in → **Play LORD**.
You start at level 1 with a stick and no armour. From the **Town Square**:

| Place | What you do there |
|---|---|
| **The Forest** | Turn-limited random encounters: monsters scaled to your level, gold, gems, a healing spring, Jennie the fairy, the old man of the woods (trade 2 gems for a permanent boon), a cutpurse, and — rarely — **Death itself**. Fights are round-by-round: *Attack*, *Auto-Battle*, or *Flee* (normal monsters only). |
| **King Arthur's Weapons** | The 12 classic weapon tiers, Stick → Death Sword. Buy the next tier; your old weapon is traded in. |
| **Abdul's Armour** | The 12 armour tiers, Cloth Coat → Golden Armour. Same trade-in. |
| **Healer's Hut** | Buy HP back. Cost scales with level. |
| **Ye Olde Bank** | Deposit / withdraw (banked gold survives death) and a light gamble. |
| **The Red Dragon Inn** | Chat with Violet for Charm (raises crit chance and forest luck); *Rest Until Dawn*. |
| **Turgon's Warrior Training** | Each level has a named master (Halder, Barius, Aragorn…). Beat the master *and* have the experience, and Turgon advances you: more max HP, better everything, full heal. |
| **Slay the Red Dragon** | Level 12, weapon + armour tier 8, full health. Win → the **Hall of Honours**, a permanent bonus, and a fresh character that keeps its bank, gems and dragon-kill tally. |

**Rest Until Dawn** refills your forest turns and heals you — available on demand
by default, so a casual player can play a full session without waiting on the
in-game clock.

All state is server-authoritative and persisted per save (KIPN data domain
`lordDragon`). Characters are keyed to your Steam ID. Death costs a configurable
slice of your **on-hand** gold and a rest — nothing else.

When the mod is installed, KIPN's own **Server Statistics** screen grows a
**Legend of the Red Dragon** panel — Dragon Slayers (the Hall of Honours) and
Top Adventurers by level — so a server can see the standings without opening the
game.

## Combat, briefly

Damage is a fraction of each side's own max HP, scaled by a weapon/armour ratio,
so fights stay ~5–12 rounds at every level while the numbers still grow huge.
Show up to a master or the Dragon under-geared or wounded and you will die;
show up prepared and you will win with a scare. Reaching the Dragon takes a
casual player roughly **8–12 in-game days** of active play.

## Sandbox options (KIPN page)

| Option | Default | Effect |
|---|---|---|
| `LORDEnabled` | true | Master switch. Off = menu hidden, commands refused. |
| `LORDForestFightsPerDay` | 20 | Forest turns per adventurer per in-game day. |
| `LORDExpMultiplier` | 1.5 | Scales experience gained. 1.0 ≈ the classic slow grind. |
| `LORDGoldMultiplier` | 2.0 | Scales forest gold. |
| `LORDDeathGoldPenalty` | 25 | Percent of **on-hand** gold lost on death (bank/gems/gear are safe). |
| `LORDRestCooldownMinutes` | 0 | Real minutes between *Rest Until Dawn* uses. |
| `LORDPvPEnabled` | false | Reserved for a future release. No effect yet. |

## Requirements

- Project Zomboid Build 42
- **KIP Network Terminal** (`KIPN`) — loaded first via `require=KIPN`

## For module creators

This mod doubles as a worked example. See
[`docs/HOWTO-build-a-KIPN-module.md`](docs/HOWTO-build-a-KIPN-module.md) for a
full walkthrough of building your own KIP Network add-on, and
[`KIPN/docs/README-SERVICE-API.md`](../KIPN/docs/README-SERVICE-API.md) for the
complete registration contract. Every KIPN touch-point — the menu entry, the one
command + one response event, the data domain, the terminal screen — is the same
shape whether your feature is a door game or a bank.
