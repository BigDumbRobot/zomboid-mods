# Bass Masters

Relaxed, friendly fishing competition for Project Zomboid Build 42 servers. Bass Masters sits on
top of the vanilla fishing system: you cast, fight and land fish in the underwater view exactly as
normal, and Bass Masters adds trophy fish and keeps the server's score.

## What it adds

- **Trophy fish.** Every fish anyone lands has a rare chance (1 in 100 by default, sandbox) of
  being a trophy, whatever their Fishing level. The size is set when the fish is made, so a
  trophy looks and fights its size in the underwater view. Vanilla's "Legendary" fish (Fishing 8+)
  count as trophies too. When someone lands one, the whole server hears about it.
- **The server's book.** Server-wide and shared by everyone: the heaviest catch of each species
  and who holds it (taking a record is announced), every trophy fish landed, and the anglers ranked
  by trophies and then heaviest bass.
- **Catch and release.** Right-click a fish while standing by water: Fishing XP, less boredom,
  unhappiness and stress.
- **The logbook.** Right-click any fishing rod or fish > *Bass Masters logbook*. Logbook (every
  species: your catches and best, the server record, where it lives and what it bites on), The
  Server (trophies, anglers, records), and Bass Master (only with Adaptive Traits).
- **The Bass Master trait (optional, needs Adaptive Traits).** See below.

## Adaptive Traits

Bass Masters does not need Adaptive Traits. When Adaptive Traits is active, Bass Masters adds a
`BassMaster` entry to its registry, in the same shape as Adaptive Traits' own entries. Adaptive
Traits checks it every in-game minute and, once every requirement is met, grants the trait
through its own `Manager.addTrait`, which handles multiplayer and the "Gained" notification.

The requirements are a template in `BassMasters_Shared.lua` (`BM.MASTER`). Each one has a goal and
a `count(d)` that reads the player's Bass Masters record:

| Requirement        | Goal                                                    |
|--------------------|---------------------------------------------------------|
| The Full Bass Set  | Land all five kinds of bass                              |
| Ten Kinds of Fish  | Land ten different species                               |
| The Record Book    | Land a bass of 10 lb or more                             |
| A Classic Bag      | Land three bass in one day that weigh 15 lb together     |
| Ten Good Days      | Land three different kinds of fish in a day, on ten days |
| Catch and Release  | Let ten fish go                                          |
| Tall Tale          | Land a trophy fish                                       |

Progress is tracked whether or not Adaptive Traits is installed, so adding it later picks up
where each player already is. The trait is a profession trait, so it never appears in character
creation. It gives Fishing +3 and the Angler's recipes. Sandbox: *Bass Master trait can be earned*.

## Files

```
Contents/mods/BassMasters/42/
  mod.info, poster.png
  media/registries.lua                          registers the BassMasters:BassMaster trait
  media/scripts/BassMasters_Traits.txt          defines it
  media/sandbox-options.txt                     trophy odds, announcements, trait on/off
  media/lua/shared/BassMasters_Shared.lua       species notes, trophy roll, Bass Master template
  media/lua/client/BassMasters_Client.lua       catches, release, server news, menus
  media/lua/client/BassMasters_AdaptiveTraits.lua   the optional Adaptive Traits entry
  media/lua/client/BassMasters_UI.lua           the logbook window
  media/lua/server/BassMasters_Server.lua       the server's book (global ModData "BassMasters")
  media/lua/shared/Translate/EN/Sandbox.json, UI.json
```

## How it hooks in

- `Fishing.Fish:createFish` is wrapped: vanilla makes the fish, then Bass Masters may roll it up to
  trophy size (weight, length, food values, hand model, and the size of the fish on the line).
- `ISPickupFishAction:start` is wrapped: when a landed fish is lifted off the line, the player's
  own record is updated and the catch is reported to the server (`sendClientCommand`). The server
  checks the weight is possible for the species, updates the book, transmits it to everyone and
  announces trophies and new records.

Each player's record lives in `player:getModData().BassMasters`. The server's book lives in global
ModData `BassMasters`. In single player, the same code runs on one machine.

## Status

Needs Build 42.13 or later, for trait registries. The logic has been exercised outside the game
against stubs, including the real Adaptive Traits registry and manager. It has **not yet been
loaded in-game**. Check these first:

- Land a fish and open the logbook (single player).
- Set *Trophy fish* to 1 in 1 and make sure a trophy looks bigger underwater and lands with the
  right weight and name.
- On a dedicated server with two players: a trophy is announced to the other player, and the
  server records show up on both logbooks.
- With Adaptive Traits: the Bass Master page appears, and the trait is granted when every
  requirement is met.
