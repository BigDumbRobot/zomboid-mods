# lilBubby's Big ol Mod Tester

A standalone Project Zomboid Build 42 mod for testing other mods in game, in single-player or multiplayer.

- Mod ID: `LilBubbyModTester`. It requires no other mod, helper program, RCON access or admin role.
- The mods under test are the normal Steam Workshop items. Subscribe to them and enable them alongside the tester.
- Right-click → **Open Mod Showcase**. The sidebar lists a suite only when the mods it tests are enabled:

| Suite | Enable (mod IDs) |
|---|---|
| Bonk Zone | `BonkZone` |
| Spy vs Spy | `SVSBoobyTraps` |
| Vehicle Claims | `KIPN` + `KIPNVehicleServices` |
| Safehouse & Land Claims | `KIPN` + `KIPNGovernmentServices` |
| Postal Service | `KIPN` + `ThePostOffice` |
| Dead Man's Map | `DeadMansMap` |
| Skylights | `SkylightsProbe` |
| The Whisperers | `TheWhisperers` |
| Satanic Temples | `SatanicTemples` |
| Mod Compatibility | any of `SVSBoobyTraps`, `SpyVsSpySignalTracker`, `SkylightsProbe`, `KIPN`, `BonkZone`, `SatanicTemples` |

With none of them enabled, the showcase says so and lists nothing.

Only actual gameplay test suites belong here. No automatic join checks or placeholder suites.

## Run every test

**Open Mod Showcase** → **Run every test** → **Run every test (prepares my character first)**.
The showcase closes and a small strip in the bottom-left corner shows each step and result while you watch.

1. **Preparation.** The server raises the skills that the enabled mods' recipes and actions use to
   level 10. For Booby Traps these are Electrical, Mechanics, Maintenance, First Aid, Carpentry,
   Aiming, Trapping and Metalworking; for Signal Tracker, Electrical and Mechanics; for The
   Whisperers, Butchering and Tailoring. It then gives
   you every magazine whose recipes you don't know yet, and your character reads each one with the
   normal read action. Recipes still unknown afterwards are taught directly on the server: this
   covers reading in the dark, the illiterate trait and interrupted reading, and only the mods'
   own recipes are accepted. The handed-out magazines are then removed.
2. **Every suite, every feature**, one at a time, in this order: compatibility, Spy vs Spy,
   Safehouse & Land Claims, Vehicle Claims, Postal, Skylights, The Whisperers, Bonk Zone, then Dead Man's Map
   (it kills the character, so it runs last). Each feature starts through the showcase's own
   Run path, and the next one starts only when its result arrives. Cleanup steps run at the end of
   each suite. The Bonk Zone suite starts by moving you to the designated test zone, and
   tests that need a zone move you to their test site. The seat-ejection test gets you into the nearest vehicle itself.
3. **Summary.** It lists every feature that did not pass, with its first failing line. Features
   that need a target you don't have (a set trap, a rented post box, a nearby vehicle) are SKIP,
   with the reason. A feature that sends no result within its time limit counts as a failure.

**Prepare my character only** does step 1. **Stop the run** ends it after the current feature.
Every feature runs for every player; none needs admin rights.

## Test sites

**There is one test site, and players only ever spawn inside it.** On the vanilla map it is the
field from 11944,6621 to 12062,6752 on the north-east edge of West Point, and new characters
start in its bare middle at 12001,6661, beside the supply crates. The server must be set to
spawn there: `SpawnPoint=12001,6661,0`. If it is not, the server log says so when it starts
(`[LilBubbySites] Players do not spawn in the test site. Set SpawnPoint=...`). The zones below
are patches of that one field, at most about 100 tiles from the spawn.

Players never create a zone. Every test that needs one uses a designated zone, and the showcase
moves the player into it before the test starts (**Moving you to the ... test zone**). The server
refuses to set anything up for a player who is not standing in the designated zone.

**The server makes the zones itself**, about a minute after it starts or the first time one is
needed, and remakes one that was removed. No admin step is needed on the vanilla map
(`Muldraugh, KY`). The places were chosen from the game's own tile data: open ground and one
building on the north-east edge of West Point, all inside the one test site.

| Site | Zone | Corners | Players arrive at | What is there |
| --- | --- | --- | --- | --- |
| Dynamic Events | KIPN `event`, 81 x 81 | 11961,6621 to 12041,6701 | 12001,6661 | the riverside meadow north of downtown; its middle 31 x 31 is bare grass |
| Satanic Temple | `LilBubby Test Temple`, 14 x 14 | 11944,6640 to 11957,6653 | 11950,6654 | bare grass on the meadow's west edge |
| Dealership | KIPN `dealership`, 21 x 21 | 12003,6705 to 12023,6725 | 12013,6715 | grass south of the meadow, clear middle for the test car |
| Government desk | KIPN `government`, 9 x 9 | 12007,6729 to 12015,6737 | 12011,6733 | the grass corridor south of the dealership site |
| Career Services | KIPN `career_services`, 9 x 9 | 12054,6713 to 12062,6721 | 12058,6717 | grass east of the dealership site |
| Bonk Zone | Bonk Zone `lilBubby test zone`, 21 x 21 | 12028,6705 to 12048,6725 | 12038,6715 | the ground between the dealership and career services sites |
| Post Office | KIPN `post_office`, 17 x 21 | 12029,6732 to 12045,6752 | 12039,6742 | the small walled business at 12032,6735 to 12042,6749 |

The defaults are the table `Sites.DEFAULTS` in `shared/LilBubbySites.lua`. A zone a mod's own
rules refuse (an overlap with a safehouse, say) is reported in the server log and tried again;
until it exists, a test that needs it ends BLOCKED with the reason.

**Moving them (admins).** Stand at the north-west corner of open, flat ground about 110 tiles wide
and 115 deep, with a building within 60 tiles for the post office, then right-click → **Open Mod
Showcase** → **Test sites** → **Move the test sites here (admins)**. The server lays one zone per
enabled mod out around you (government desk around you, Career Services 15 tiles east, dealership
36 east, Bonk Zone 68 east, temple 95 east, events 40 east and 60 south, post office in the
nearest usable building), switches the old ones off and remembers the new places across
restarts. A server on another map has no defaults and gets its sites this way. Only an admin sees
the entry; the server checks again. Everyone has **Show which test zones are set up** and, after
it, **Take me to the ... test zone**.

Tests that move you to a site: the Government desk and Renewal tests, the vehicle desk and claim
lifecycle tests, the business licence and Career Services zone tests, the guided post office test,
the Bonk Zone's **Take me to the designated test zone**, both Satanic Temples runs, and Dynamic
Events' lifecycle and Adventure tests. Cleanups remove what a test left in a zone, never the zone.
In the Career Services zone check, drawing, moving and removing a zone still runs only for admins.

Local checks: `lua tests/sites_checks.lua`.

## Supply depot

Players do not need to be moved or handed ingredients to craft anything the tested mods add.
Beside the spawn point the server keeps a row of eight wooden crates holding every ingredient
and tool those mods' recipes use: enough of each ingredient to craft every recipe five times
(at most 60 of one item), two of each tool, and three full containers of each fluid.

- **What is stocked** is read from the game: every craft recipe whose mod is enabled and listed
  in `Supply.MODS` (`shared/LilBubbySupply.lua`). A new recipe is covered without editing a list.
  Each item type always sits in the same crate.
- **Where:** on free outdoor squares within 20 tiles of the server's `SpawnPoint`, nearest
  first, so in practice within a few steps of where players appear. With no `SpawnPoint` set
  (`0,0,0`), the vanilla map uses the test site's spawn, 12001,6661.
- **Restocking:** once a game minute the server replaces whatever was taken, puts back a crate
  that has gone missing, and logs `[LilBubbySupply] restocked N items`. An item the game cannot
  create is logged once as `not stocked`.

The crates are placed the first time a player is near the spawn point, since the ground has to
be loaded. Local check: `lua tests/supply_checks.lua`.

## Travel

Suites that move you (Bonk Zone, Dead Man's Map, Skylights) use the game's own
`IsoPlayer:teleportTo`. In multiplayer the server chooses and validates each
destination and tells only your client to move. It never accepts coordinates
from a client.

Build 42's speed anti-cheat samples player positions about once a second and
kicks anyone moving faster than 20 tiles a second. Only the admin teleport
command resets it, and Lua cannot reach that. So when the server's
`AntiCheatSpeed` is not Disabled (4), and you have no teleport permission, you
travel in hops of 8 tiles a second. Even when two hops land in one sample, that
is 16 tiles a second. The server tells the test how long to wait. With
`AntiCheatSpeed=4`, or for admins, the move is a single jump.

## Mod Showcase

Select a mod in the sidebar, search its
features, read the selected action and instructions, then press **Start selected**.
The existing test callbacks and server authentication are preserved. No tests
run automatically when you open, search, refresh, or switch mods.

- **Start selected** closes the window so it doesn't block your view. A small, see-through strip
  in the bottom-left corner shows what is running and the newest result lines, coloured like the
  console. Drag it to move it; **Showcase** reopens the window with the full reports, and **x**
  hides the strip while results keep collecting.
- The window moves, resizes and collapses using the normal game window controls.
  Closing it leaves running tests alone; reopen it to see their results.
- **Refresh targets** updates vehicles and discovered traps after you move or
  change the world. Start rechecks availability; changed target information
  requires reviewing the refreshed selection before running.
- Numbered instructions describe a suggested route through each mod, prerequisites,
  and effects such as teleporting, consumed traps, ownership changes or character death.
- Features marked **Tried** were invoked this session; this is not a pass verdict.
  Server reports distinguish PASS, FAIL, BLOCKED, SKIP and other outcomes.
- Results stay in the window instead of opening modal dialogs. **Older/Newer**
  browse the latest 40 messages per mod and local player. **Show full report**
  expands all details; summaries retain failure and blocking information.
- Search for **Clean up**, **Cancel**, or **Return** to find the suites' existing
  cleanup, cancellation and return actions. Availability depends on the suite.
- **Console** (next to Refresh targets) opens or hides the **Test Console**: a
  movable, resizable log of every result line and every tester command sent to
  or received from the server, with elapsed time, mod name and colors for
  PASS/FAIL/BLOCKED. Filter to **This mod** or hide **Traffic**; **Copy** puts
  the visible lines on the clipboard for bug reports; **Clear** empties it.
  Closing either window keeps the log collecting (last 500 lines per local player).
  It follows new lines while you're at the bottom and stays put if you scroll back.
- History and tried markers last for this client session, including closing and
  reopening the window. They are not saved across game restarts.

In game, check each suite, resize/collapse/reopen the window, search for cleanup,
change a target before starting, and verify two local players receive separate results.

## Offline checks

Plain Lua 5.4, run from this project directory. They load only this mod's own
files and replace every game and mod API with stand-ins, so they need no game,
server or other mod:

```sh
for f in tests/*.lua; do lua "$f" || echo "FAILED: $f"; done
```

They cover the showcase, window and console state, installed-mod filtering
(including `\ModID` entries), each suite's catalog, report and safety rules,
native travel (speed-limit safety at every sampler phase), the Bonk Zone server
suite with injected guard failures, and the Mod Compatibility checks against
well-behaved and broken hooks. They check the harness logic only. Only in-game
runs against the Workshop mods validate the mods themselves.

Some exceptions load a tested mod's real code. `tests/kipn_identity_checks.lua` loads
the local KIPN project (`~/Zomboid/Workshop/KIPN`), not the subscription, and is skipped
when it is absent. It checks that KIPN identifies a player by server account rather than
Steam ID, and runs the migration of claims, player stats and other saved records off
their old Steam-based keys against sample old-format data, including two players whose
Steam IDs round to the same value. The Careers checks use their
Steam Workshop subscriptions (`steamapps/workshop/content/108600/<Workshop ID>/mods/`), so
they test whatever version of those mods is published and subscribed. The Whisperers checks use
its subscription too, and fall back to the local project `~/Zomboid/Workshop/TheWhisperers`
until it is published:

- `tests/whisperers_meter_checks.lua` drives the noise meter through sneaking, standing,
  walking, crouching, a gunshot and silence, and checks that a zombie is fooled at a low meter,
  notices you above half, comes at a full meter and forgets you at zero.
- `tests/whisperers_gear_checks.lua` runs the real timed actions, recipe callbacks and
  per-minute tick: guts yield and rot, blows per blade, face damage, nail and needle masks,
  wear damage and repair, skin suits (materials, skeleton, clothing strip, tearing), smearing,
  corpse sickness, and 3D head stakes (looks, mannequin scripts, pick up and place, head gear only).
- `tests/whisperers_gait_checks.lua` checks zombie mannerisms: the mask-and-suit rule (either
  alone, torn, dead, in a car or switched off stays human), the flag tick in single player and
  multiplayer, and each `Whisp_Zombie*` animation node against the game install (a real player
  state, a higher priority than every vanilla node there, a real zombie clip, quiet footsteps
  when crouched, turning, timed actions and fidgets left to vanilla).

- `tests/careers_threats_checks.lua` runs the Careers Framework threats layer,
  its Economy helpers, the Mechanic walk-in completion and the Dealer
  shakedown and ambush against a mock game world.
- `tests/careers_blacksmith_checks.lua` covers Blacksmith pricing and
  validation.
- `tests/dynamicevents_checks.lua` loads Dynamic Events' real code and plays every
  Dynamic Events suite flow through (see "Dynamic Events tests"). It also fails if the three copies
  below differ from Dynamic Events' own.
- `tests/dynamicevents_studio_checks.lua`, `tests/dynamicevents_studio_ui_checks.lua` and
  `tests/dynamicevents_server_loop_checks.lua` are Dynamic Events' own offline harnesses (its
  `tests/studio_checks.lua`, `studio_ui_smoke.lua` and `server_loop_checks.lua`), kept here too: the
  Studio's checklist and templates; every Studio step, button and view, the HUD, the simulation panel,
  the invitation and the right-click entries; and every game mode, bandits, the Heist, moves, Start,
  Cancel, announcements, Past events, the simulation, invitations and sandbox access on the real server
  code. They load `~/Zomboid/Workshop/DynamicEvents`.

## Installing and publishing

This is a normal Workshop upload project: `Contents/mods/LilBubbyModTester`
holds everything the game loads. `workshop.txt` deliberately has no Workshop
ID. Do not reuse BonkZone's item ID. The initial visibility is unlisted.

Publish it from the game's Workshop uploader (**lilBubby's Big ol Mod Tester**),
then add `<new-item-id>:LilBubbyModTester` to the server's `MOD_WORKSHOP_IDS`.
Joining players then download it like any other mod. No Workshop item has been
published yet.

Until then, the game on this machine already sees the project in
`~/Zomboid/Workshop`. Other testers can copy `Contents/mods/LilBubbyModTester`
into their `Zomboid/mods` folder. The development server loads a plain copy
from its `workshop/LilBubbyModTester` folder. Refresh that copy after editing,
then restart the server:

```sh
rsync -a --delete Contents/ ~/kipn-docker-dev-server/workshop/LilBubbyModTester/Contents/
```

## Spy vs Spy tests

Enable `SVSBoobyTraps` alongside this tester to use the Spy vs Spy suite.
Right-click → **Open Mod Showcase** → **Spy vs Spy**. It offers:

1. **See all recipes**: a read-only list of every trap's ingredients with their icons
   and how many you carry. Nothing is given or taken.
2. **Trap tests / <trap>**: one entry per trap, run in phases. The Contaminated Document
   (Prepare Anthrax, which uses up a sealed sample) and the Sealed Biological Sample (Culture
   Biological Sample, from fish guts and cleaning liquid) are separate entries.
   - **Phase 1**: the trap's ingredients, with the MAD Magazine that teaches it on the
     right (cover, description and the recipes it teaches). **OK** (green) continues;
     **Cancel** (red) ends the test.
   - **Phase 2**: the server checks what you carry and gives only what is missing. The water
     bucket comes full of water, the sample's cleaning liquid in a full bottle. If your character
     does not know the recipe, the magazine is given too; skills below the recipe's levels are raised to them. Traps used on something
     in the world get it beside you: the vehicle devices get a car with its key in your
     inventory and a full tank, the explosive parcel a mailbox, and anthrax a readable item
     to contaminate. A large message then says the items are in your inventory.
   - **Read the magazine** (only when it was given): read it, then click **OK**. The server
     checks your character now knows the recipe; if not, the message says so and waits.
   - **Phase 3**: craft the trap in your own time, then click **OK**. The server checks the
     trap is in your inventory; if it is not there yet, the message says so and waits.
   - **Set it**: a large message says where and how to set the trap (and to walk 2 tiles away
     so it arms). A sealed sample is harmless until opened: the message then says to open it
     and walk away. **Set it off**: once the server sees it armed, the message says how to
     detonate it, with *Warning - you may die*. When the server sees it go off (from the
     mod's own trap registry; for an open sample, when it exposes someone) the message says **Congrats! Your trap was detonated.** and the
     test PASSes. A trap picked back up instead is not counted; the message returns to setting it.
   - **Cleanup**: 600 ticks (about 10 seconds) later a screen covers the game with one button,
     **Clean up this test**; you cannot move until you click it.
   Cancel at any step cleans the test up at once and returns you to the showcase.
   Starting another trap replaces (and cleans up) the previous one. Every player can
   run every trap test: the server gives the items and places the car. Traps
   switched off in the sandbox settings are greyed out with that reason.
3. **Clean up this test**: removes every item the test gave you, the crafted trap if it is
   still in your inventory, any trap you set during the test (releasing whoever it holds), and
   the car or mailbox it placed. Raised skills are kept. If the trap killed you, items left on
   your body are not removed.

During **Run every test** the windows are skipped: each trap's ingredients are given and
the trap is crafted with the game's real craft action, then checked. Setting and detonating
are left to you.

## COMPUTER Vehicle Claims tests

Enable `KIPN` and `KIPNVehicleServices` alongside this tester.
Right-click → **Open Mod Showcase** → **Vehicle Claims**.
Every connected player can run every test, and none needs admin access. In the admin-exemption check a KIPN admin is checked as themselves; for anyone else the server checks a stand-in admin, without giving the player any rights.
The target vehicle is the one you sit in, otherwise the nearest within 12 tiles. It is shown at the top of the menu,
and the server refuses vehicles farther away.

Server tests drive the live mod: the real `CLAIM_VEHICLE`, `ISSUE_VEHICLE_CLAIM` and
`RELEASE_CLAIM` handlers, `VehArtifactService`, `VehClaimService`, `VehEnforcement`,
and the KIPN claim and artifact stores. Nothing in the production mod is patched.

- **Setup and configuration:** the `VehicleServices` service, the `dealership` zone type and its capabilities, the four
  vehicle permissions and role grants, the claim/artifact types, command handlers, both terminal apps, sandbox → server
  policy → client sandbox agreement, and the item/recipe scripts. The switch check turns vehicle registration and vehicle
  claims off for a moment, checks that forms, titles and title searches are refused, and turns them back on.
- **Registration forms:** gives recipe materials, creates a tracked form, registers a crafted (untracked) form, and lists your
  forms/titles with their artifact state. Expiry is checked against the sandbox day settings.
- **Vehicle Titles:** issues a title for the vehicle's dealership, processes a form at a nearby computer through the
  real desk command (or checks that a non-dealership computer refuses), and checks issuance and title-validation
  rejections: wrong zone, wrong item, untracked, consumed and expired titles.
- **Vehicle claims:** checks whether the vehicle can be claimed, claims it, runs the full form → title → claim → release flow
  (carrying a second title for another dealership, which must be left alone), checks claim rejections, your
  claims/quota/ownership expiry, and vehicle ownership metadata. The claim-limit test sets the limit to your current
  claims for a moment (a stand-in claim with no vehicle counts as one if you have none), checks that the next claim is
  refused and your title kept, then restores the limit. A periodic-resync test wipes the server metadata and waits up to
  90 seconds for the mod to repair it; if it never does, the tester writes it back itself.
- **Release:** the owner release through `RELEASE_CLAIM`, and refusal of a release for a claim you do not own.
- **Non-owner enforcement:** *Give this vehicle to the test owner* claims it for a stand-in identity
  (`LILBUBBY_TEST_OWNER`), so one player can test everything a non-owner sees. It covers the server access decision,
  interception of the 10 vanilla vehicle commands, seat ejection (get in within 30 seconds; the test then gives the
  vehicle to the test owner and waits for the ejection), and the README's admin exemption.
- **Client features:** the client runs these locally. They check the modules, screens and the 11 `ISVehicleMenu` overrides, the
  vehicle bridge, the claim timed action (title check at start, timing, the `CLAIM_VEHICLE` it sends), the right-click menu
  entries, and every enter, mechanics, door, hood and lock gate. Gate checks swap the mod's saved vanilla callbacks
  (`KIPN.o*`) for counters and restore them straight away, so nothing is actually entered or opened. The policy and radial
  menu checks run against a Lua-only claimed vehicle under the live sandbox and two forced policies, and restore the
  client's sandbox values afterwards. The dialog check opens the claim and release confirmations with a recorder in place
  of the dialog, and checks what Yes and No do. The Vehicle Registration and Vehicle Records checks run the two terminal
  screens' logic on stand-in screens with the clock, sends and inventory replaced: form check, craft wait, sending,
  answers, the claim list, expiry text and the two-click release. Nothing is sent to the server.

Every vehicle result ends with a **Client view** line, which shows whether your client sees the same claim as the server.
**Run every automatic check** runs only the server and client checks that change nothing, or put back what they change
straight away (setup, configuration, scripts, switches, forms, claims, and the client checks).
**Clean up** releases claims made by these tests, removes items they gave you, and deletes their artifact records.
Claims made through the normal right-click menu are left alone.

Local regression checks: run `lua tests/vehsvc_checks.lua` from this Workshop project directory.
It checks that every catalog entry has an implementation, the report counts and the expected-outcome rules. It runs the
command-interception test against a stand-in enforcement module: correct wrappers pass, a missing wrapper fails, and a
missing `ClientCommands` table fails every command. The in-game suite runs the same test against the Workshop mod.
It also runs the setup, configuration, switch, claim-limit and resync tests against a stand-in mod, a correct one and
broken ones, and checks each puts back what it changes.

`lua tests/vehsvc_mod_checks.lua` loads the real mod (the Workshop subscription, or `~/Zomboid/Workshop/KIPNVehicleServices`).
It checks the sandbox options, their defaults and translations, the policy defaults, item and recipe scripts, the
registrations in the init file, the wrapped commands and the menu overrides against what the suite expects. It then
runs the mod's client files under the suite's client checks, and checks two deliberately broken copies are caught.
It also checks the server-reply messages ("Vehicle claim successful.", "Vehicle ownership released." and the
refusals), which the in-game suite does not fake because a fake reply would reach KIPN's own terminal too.

The KIPNVehicleServices release project contains no tests.

## Postal functional tests (KIPN framework)

Enable **ThePostOffice** on the expected KIPN framework alongside this tester
to use the postal suite. Ordinary connected players can
right-click → **Open Mod Showcase** → **Postal Service**.
No admin privilege is required, and none is given. The shared launcher appears once regardless of suite load order; single-player execution is also supported.

Every postal test lives in this tester. The Post Office mod itself contains no test code.

### Guided post office test

The guided test walks the player through setting a post office up, renting a box and
collecting a delivery. It has five steps. Each step tells the player what to do and
ends when they click **OK**; the server then checks that everything the next step
needs is really there and passes or denies the step. A denied step says what is
missing and stays up for another try. **Cancel** at any step cleans up.

1. **Setup and overview.** The server moves the player into the designated test post
   office (see Test sites): on the vanilla map the small business at 12032,6735, with
   3 tiles around it as the Post Office zone. It places a desktop computer
   inside, switched off, and a running generator with a full tank outdoors, and puts
   10 money bundles and a Blank Key in the player's inventory; every PO Box purchase
   uses one Blank Key up. The window gives an overview of what a post office does. OK
   checks the zone, that the player is in it, the computer, the generator, the cash
   and the Blank Key.
2. **Place the boxes.** The window explains that placing PO Boxes is admin-only in the
   game. The player is not made an admin: while this step is up, the world right-click
   menu has **Post office test: place a Small / Medium / Large PO Box here**, and the
   server places the box on that tile. OK checks that at least one box of every size
   is registered to the zone and stands inside it. It then checks every box: registry
   and number lookups, a unique number and lock ID, price and capacity, the physical
   container's capacity, lock ID, permanent lock and movement protection, purchase
   resolution, and the zone's next box number.
3. **The computer and the key.** The window explains that Postal Services is only
   offered on a computer standing in a Post Office zone, that a purchase takes the
   price and a Blank Key, and that the box key is the rental. OK checks that a free
   box, enough cash, a Blank Key and room under the rental limit are there.
4. **Rent a box.** The player switches the computer on, opens Postal Services and
   rents a box; the window repeats why the key matters and explains delivery. OK
   checks that a rental at this post office was made during this step and that its key
   is carried. It then checks that delivery eligibility matches ownership, that the
   held key matches the box's lock and the rental's key serial, and that the game lets
   the character unlock the box.
5. **Collect a delivery.** Passing step 4 queues a parcel of two sheets of paper for
   the player through `QueueSystemParcel`, the call a server subsystem uses to award
   one, and checks that queuing the same order twice still leaves one parcel. The
   player collects it with **COLLECT PARCELS** in Postal Services. OK checks that the
   parcel left the queue and two new sheets arrived, then replays it: collecting the
   same parcel again must grant nothing, and queuing the fulfilled order again must
   not mint another parcel.

The checks behind steps 2, 4 and 5 do not deny a step, because the player cannot fix
them. Their lines go into the final report, and one FAIL makes the whole test FAIL.

**How the boxes are placed without an admin.** Creating and removing a PO Box are
admin commands of The Post Office. The tester's server code calls the mod's own
`POBoxService.CreateBox` and `DeleteBox` as an operator object that stands on the
player's square and carries a role with admin power, which is how KIPN recognises a
Build 42 admin. Nothing of the player's or the server's permissions changes, and
KIPN's admin list is not touched. The server only places a box during step 2, on a
tile inside the test zone, while the player stands in it; The Post Office itself
still applies its own rules (one box per tile, within 10 tiles). If a future KIPN
stops accepting the operator, the step says so and asks for an admin to place the
boxes with **KIPN: Spawn PO Box**; boxes placed that way count too.

The post office, the box, the key and the paper stay in place after the test.
**Clean up the post office test** releases the rentals the player made at the test
post office, removes their keys, the boxes, any test parcel still waiting, the money,
Blank Key and paper the test gave, the computer and the generator, and closes the
zone. Boxes are removed from within 10 tiles, so stand in the post office; a box
that cannot be removed (another player owns it, it holds items, it is too far) is
named and keeps the zone open. Money spent on a rental is not given back. Run every
test skips the guided test, because every step waits for the player.

The guided test is real play: the player buys a real box through the real Postal
Services screen with money the test gave, and any connected player can start it, get
that money and use the designated test post office. This remains a
development-server tester.

### Check invalid requests and command registration

This sends The Post Office requests it must refuse and checks each refusal. Every
request is refused before anything is changed; none is valid enough to create,
release, queue or grant anything.

- The GET_PO_BOXES, BUY_PO_BOX, GET_PARCELS and COLLECT_PARCEL handlers are registered.
- Purchase validation refuses box numbers 0, -1, 1.5, 1000000 and text.
- A player who is not an admin cannot create or remove a box. An admin running the
  check gets the argument checks behind that gate instead: no square, an unknown
  size, a tile 500 tiles away, and a box that does not exist.
- A key-removal report without a key identity is refused. With a rented box and its
  key carried, a report with the wrong serial is refused and the box must still be
  the player's afterwards. Without a box this part is BLOCKED. The check never sends
  a report carrying a real key serial.
- Malformed system parcels are refused: no recipient, a blank recipient, no order ID,
  no item, 0 or 101 items. External deliveries without a provider or from an unknown
  one are refused. A player without a PO Box gets PO_BOX_REQUIRED instead.
- Collecting a parcel that does not exist grants nothing, and the player's parcel
  queue and inventory are the same size afterwards.

**Show last result** redisplays that local player's report. Results are also written
to the client/server logs.

PASS records observed behavior; FAIL records an incorrect outcome; BLOCKED means
player setup is needed (for example, rent a box and carry its key); ERROR means a
framework/engine call failed. An all-PASS result only covers the checks that ran.
Requests are queued per player, never dropped. Only the requester gets the report.

### Offline checks

From `~/Zomboid/Workshop/LilBubbyModTester`:

```sh
lua tests/postal_menu_checks.lua
lua tests/postal_guided_checks.lua
```

The first checks menu creation/order, callback routing, single-player dispatch,
split-screen result isolation, authenticated targeting, queued requests and error
replies, and the guided test's windows: each step's text, the right-click box
entries of step 2, a denied and a passed OK, the verdict when a server check fails,
Cancel and the cleanup reports. The second runs the guided test's server half and
the invalid-requests check against a stand-in world and stand-in KIPN services: the
building picked, the zone, computer, outdoor generator, money and Blank Key, box
placing without admin rights, every step's check, the delivery and its replays, and
cleanup. Both use fixtures; the in-game suite exercises ThePostOffice's real services.

### In-game acceptance

Neither postal test has been run in the game yet. As an ordinary (non-admin) player:

1. Start the guided test outdoors near a building. Confirm you arrive inside, the
   computer is inside, the generator is outdoors and running, and you carry 10 money
   bundles and a Blank Key.
2. Click OK on step 2 before placing anything and confirm it is denied with the
   three missing sizes. Place the boxes from the right-click menu; confirm KIPN's own
   **KIPN: Spawn PO Box** entry is not offered to you, and that the step passes.
3. Rent a box on the computer and confirm step 4 passes only once you carry its key.
4. Collect the parcel and confirm step 5 passes and the final report lists every
   step and check.
5. Cancel a second run at each step and confirm the cleanup report.
6. Run **Check invalid requests** with and without a rented box, and as an admin.

## COMPUTER Safehouse and Land Claims tests

Enable `KIPN` and `KIPNGovernmentServices` alongside this tester. Any connected
player can run every test: right-click → **Open Mod Showcase** →
**Safehouse & Land Claims**. Results show on screen and in the
server log; **Show last result** reopens the last one.

Server tests run against the requesting player through the mod's real services
and registered command handlers, the same entry points the client uses. Replies
the handlers send are captured and still delivered, so the normal screens update
too. Some tests hand a check back to your client (size tiers, desk cash count,
your safehouse and excavation claims), so one report covers both sides.

Start with **Run every automatic check**. It changes nothing: setup, policy and
size tiers, crafting list, protection options, cash counting, the building and
land where you stand, placement rules, zone rules and sync.

Groups:

- **Setup and configuration:** zone type, permissions, apps, claim/artifact types,
  hooks, commands, sandbox policy, size tiers, crafting list, ServerOptions.
- **Crafting:** the server gives you every ingredient and checks the recipe can be
  crafted. Craft it yourself from the crafting menu, then run **Check my crafted forms**.
- **Documents:** registering forms, issuing deeds and each permit size, and
  finding/validating/consuming them, including forged and wrong items.
- **Government desk:** the full `ISSUE_*` command path at the computer within 3
  tiles. At a powered government computer they must succeed. Anywhere else they
  must refuse with the right reason (not government, no power). Permit tests hand
  you exactly the fee and take back anything left over.
- **Safehouse claims:** check or claim the building you stand in (a deed is given).
  Also: adopting your own plain vanilla safehouse (members and title kept), the
  footprint plus 2-tile buffer, migrating old claim records, repairing a deleted
  safehouse, expiry and expired release, release through the safehouse panel or
  Property Records, and zone rules where you stand.
- **Excavation claims:** check or claim land at each size (a permit is given),
  placement range/level/overlap rules, the claim limit (fills it east of you with
  Small claims, checks the next is refused, then releases them), release.
- **Renewal:** renewing your latest test claim through `RENEW_CLAIM` at a nearby
  computer (a matching form is given), plus refusals: unknown claim, someone else's
  claim, expired claim, no computer, wrong form.
- **Sync and engine:** the safehouse bridge on a temporary 7x7 safehouse around
  you, and safehouse/overlay/excavation-area sync.
- **Client features:** right-click menu entries, the blocked vanilla Claim
  Safehouse option, the claim timed action, excavation access enforcement (using a
  fake claim owned by someone else, then real areas are fetched back), the
  placement preview, safehouse panel and bounds viewer, projection sync (a
  temporary safehouse at 5,5), admin overlay preference, client size cache.

Claims the suite creates are kept so you can walk around them; **Verify** tests
re-check them. **Clean up my test items and claims** releases every test claim
and removes every item the suite handed out. Tests that change a claim's dates
(expiry, renewal, migration) only touch claims the suite created.

BLOCKED means the spot or your current claims don't allow the test (for example,
already at the claim limit). SKIP means the test needs a different place or state.
The report says which.

Local checks: `lua tests/govsvc_checks.lua` covers the report, the geometry and cash
rules the tests compare against, catalog coverage (every menu entry has an
implementation on its side, and every client follow-up the server requests exists)
and dispatch errors. Lua syntax and local checks pass; in-game validation is pending.

## Dead Man's Map tests

Enable `DeadMansMap` alongside this tester. Any player can run it, in single-player
or multiplayer: right-click → **Open Mod Showcase** → **Dead Man's Map**
→ **Run copy markings test** or **Run death test (kills this character)**. **Show last result** reopens the report.

The test runs the real mod with nothing patched:

1. **Write markings:** adds two text notes and two symbols around you to your personal map
   and reads them back. Markings you already have stay and are checked too, because the mod
   moves the whole map.
2. **Kill:** kills the current character (on the server in multiplayer) and waits for `OnPlayerDeath`.
3. **After death:** exactly one new `<Name>'s Annotated Map` is on the ground at the death site.
   It is a loose `Base.Map` and flagged as having wiped the personal map. Every marking matches
   what was written. The dead character's personal map is empty. In multiplayer the server
   checks its own copy too, including protection from world-item cleanup.
4. **New character:** clicks Respawn on the death screen and creates **DMM New Life** at the
   default spawn. If that automation fails, create a character yourself; the test waits up to
   10 minutes. The new character's personal map must be empty.
5. **Teleport to the corpse:** moves the new character to the death square. It checks that the
   corpse is there and tagged with its map, that the map (client and server) and the Ground
   loot panel are there, and that the new personal map is still empty.

The move uses the tester's native [travel](#travel). The server records the death site when it
kills you, and it verifies and sends you only there. It never uses coordinates sent by the client. In multiplayer,
a corpse tag the client cannot see is reported as INFO, because the mod only tries to tag the corpse and does not guarantee it.

Only death maps with the dead character's name, stamped at or after the test start, are
counted. Maps and corpses from earlier runs at the same spot are ignored.

**Run copy markings test** doesn't kill anyone. The server (or the game, in single player) drops a test
Annotated Map with three markings beside you and sets your pens and pencils aside. The test then checks the following:
- **Without a writing tool:** Copy Markings to My Map is red and unclickable on the map on the ground. It grabs
  the map from the Ground panel and opens it. The viewer's **Copy markings to my map** button is red and disabled,
  and neither it nor a direct call copies anything. An ordinary map has no such button.
- **With a pen:** it drops the map back, chooses Copy Markings to My Map on it, and checks the map is picked up,
  every marking is copied, and no action is left stuck in the queue. The viewer button then copies once, with no
  duplicates on a second click.

Finally it removes the copies from your map, takes the test map and pen away, and puts your own writing tools back.

Live runs with the local mod (`~/Zomboid/Workshop/DeadMansMap`), in isolated cache folders:
- `bash tests/deadmansmap/live/run_live.sh ["feature"]`: single player. It reuses the Whisperers live start mod
  and clicker. Screenshots go to `$TMPDIR/dmm-live/shots/`.
- `bash tests/deadmansmap/live/run_mp.sh ["feature" | none]`: multiplayer. It starts a local `-nosteam` dedicated
  server (port 16361, no zombies, from `server_SandboxVars.lua`) and the real client. The client joins as a
  normal player; `DMMMPStart` connects and makes the character. `none` leaves both running, for
  `probe_mp.sh <file>` (probes in `live/probes/`). Screenshots go to `$TMPDIR/dmm-live-mp/shots/`.

**2026-09-26 (B42.20.4, DeadMansMap 1.5.0 local):** copy markings test passed 35 of 35 in single player
and 35 of 35 in multiplayer. With the 1.5.0 multiplayer fix removed, multiplayer fails as it should: copying
from the ground copies 0 of 3 and leaves a transfer stuck.

Local regression checks: run `lua tests/dmm_checks.lua` from this Workshop project directory.
It covers symbol counting, seed matching, the death-map owner and age filter, the corpse filter,
symbol comparison and report verdicts. These checks pass. In-game validation is still pending.

## Skylights tests

Enable Skylights (mod ID `SkylightsProbe`) alongside this tester. Any player can run it, in
single-player or multiplayer: right-click → **Open Mod Showcase** → **Skylights**.

- **Skylight Test**: open to every player. The server builds in the world and gives the items.
  1. **Structure:** builds a 5x5 room on clear, flat outdoor ground within 40 tiles. The room
     has vanilla wooden walls, a wooden floor roof, a wooden door in the middle of its west wall,
     and wooden stairs on its south side that climb north onto the roof.
  2. **Materials:** the server deposits a skylight's materials in your inventory: 4 planks, 4
     screws, a screwdriver and a wooden window. It then tells you: *Items deposited to your
     inventory. Go up the stairs to the roof to build your skylight.* The test ends there with
     PASS.
  3. **Your part:** go up the stairs, build a **Skylight** anywhere on the roof from the build
     menu, then come down and go in through the door to see the light under it.
- **Clean up my test room:** removes the room, door, stairs, skylights and holes this suite
  created for you. Running the test again also replaces your earlier room.

In multiplayer every world change (structure, materials, cleanup) is made by the server.

Local regression checks: `lua tests/skylights_checks.lua` covers availability, report
verdicts, the deposited materials and the player prompt, queued requests
and the server command guards. Multiplayer acceptance on the dev server is still pending.

## The Whisperers tests

Listed when `TheWhisperers` is enabled. Right-click → **Open Mod Showcase** → **The Whisperers**.

- **Run full Whisperers test** (it spawns corpses and a zombie and raises skills).
  Stand outdoors with a few clear tiles around you.
  1. **Setup:** gives you a hunting knife, a katana, a machete, thread, nails and a long stick,
     and raises Butchering to at least 3 and Tailoring to at least 5. It then checks the mod's
     registration: sandbox options, item scripts, recipes, translations, blade classes, the
     stat-sync API and the noise-meter HUD.
  2. **Corpses:** places four corpses beside you, one carrying a player's name as a real player
     corpse would, and checks the corpse context menu.
  3. **Guts:** butchers a corpse through the real action and checks the yield for your
     Butchering level, the time taken, and the name and weight of fresh guts.
  4. **Heads:** takes one head each with the katana (one blow), the machete and the knife,
     checking the blows for your skill, the head's name (`Zombie Head` or `<Player>'s Head`),
     the headless flag and wound on the corpse, and that knife stabs cost endurance.
  5. **Faces and masks:** cuts two faces, sews one through the crafting logic with a nail
     (the needle is handed out only afterwards) and checks the 30% nail damage, then sews the
     player's face with a needle and checks the mask keeps the player's name and the face's
     condition.
  6. **Smearing:** smears guts on you and checks that blood spreads over the body, the
     camouflage turns on and the meter appears.
  7. **Gear:** wears the mask (10% damage, gore x5), skins a corpse into a suit (six thread
     uses, full condition, the corpse becomes a skeleton), wears it (other clothing stripped,
     gore x50, nothing else can go on), has the server hit you hard enough to tear it, takes
     the mask off (10% more) and repairs it with a needle.
  8. **Time:** ages your guts one half-life (half weight, "Guts (50%)"), then waits 20 s for
     corpse sickness, unhappiness and discomfort.
  9. **Zombie:** places a zombie 7 tiles away, holds the meter at 100% until it targets you,
     then at 0% until it forgets you, and removes it.
  10. **Head stake and washing:** crafts a head stake, then washes you.
- **Craft 10 head stakes and set them up beside you** (it gives heads and sticks
  and places objects). Stand with ten clear tiles in a row two squares south of you.
  1. For each stake the server gives one head and one long stick, and the stake is crafted
     through the real recipe: four zombie heads, two faceless zombie heads, two of your own head
     and one faceless (carrying your look, as beheading a player records it), and one old player
     head with no look recorded.
  2. Each stake is checked: it carries its 3D head (mannequin byte data), its look has a real
     mannequin script, faceless heads stay faceless, your heads are named for you and show your
     own skin, hair and beard, the old player head gets a human face, and strangers' heads get
     at least two different skins.
  3. Test only: each stake is placed as soon as it is crafted (ten in the bag would pin you),
     in a row through the moveables code the Place menu uses. In play, the player always chooses
     where a stake goes. Each is checked to stand on its square on a stick, flayed only if its
     head was faceless. They stay up so you can look at them; cleanup removes them.
- **Test zombie mannerisms** (it gives a face mask and skin suit). Stand on open,
  flat ground with a clear 8-tile line beside you, wearing no mask or suit of your own (a torn
  one is taken off for you).
  1. **As a human:** checks the flag is off and you stand and walk with human clips, and
     measures your walking speed.
  2. **One piece at a time:** the mask alone, then the suit alone: the flag stays off and you
     stand like a human.
  3. **Both:** the flag comes on and you stand with `Zombie_Idle`. The test walks you
     (`Zombie_Walk`, checked slower than your human walk) and crouch-walks you (still crouched,
     `Zombie_Walk`).
  4. **By hand, 2 minutes each or skipped:** crouch and run (`Zombie_Walk4`), stand and run
     (`Zombie_Lunge`, faster than the shamble), sprint (`Zombie_Sprint`, faster than the run).
     A speed from running into a wall is reported, not compared.
  5. **Sitting:** sits you down; once the sit-down is over you are slumped in
     `Zombie_IdleAgainstWall`. Then it stands you up.
  6. **Taking it off:** mask off (human), mask back on (zombie), suit off (human), a walk with
     human clips, mask off. Your own clothes go back on; the test gear stays until cleanup.
  Dead skin tears at random and a torn piece falls off; if that happens mid-test the test
  stops with an error and asks you to run it again.
- **Check my Whisperer state:** only reads your character: gore, multiplier, camouflage, meter,
  carried guts and worn dead-skin gear.
- **Clean up my test items and corpses:** removes the items the test gave or made (by their
  IDs, so your own guts, heads and masks are never touched), the test corpses and skeletons
  within 3 tiles, and the test head stakes within 6 tiles.
- **Show last result** reopens the report.

In multiplayer every world change is made by the server, for any player. The
server accepts corpses and zombies within 10 tiles, hits up to 100 damage, and gives only a
needle and a test shirt mid-test. Blow counts are checked in single player only: in multiplayer
the server counts the blows.

Live runs with the real game client: `bash tests/whisperers/live/run_live.sh "Craft 10 head stakes"`
(see `tests/whisperers/live/README.md`). It uses an isolated cache folder and never touches ~/Zomboid.

Local regression checks: `lua tests/whisperers_suite_checks.lua` covers the report format,
expected values, the server's argument guards, the give whitelist and a cleanup that
leaves the player's own gear alone. `tests/whisperers_meter_checks.lua` and
`tests/whisperers_gear_checks.lua` and `tests/whisperers_gait_checks.lua` run the mod itself
(see [Offline checks](#offline-checks)). `tests/whisperers/live/keys.swift` holds keys down in
the game window (`keys <seconds> <mac key codes>`, e.g. `keys 4 56 13` for Shift+W), for the
run and sprint steps in a live run.

**2026-09-26, single player (live harness, B42.20.4):** Test zombie mannerisms passed 32 of 32,
with run and sprint driven by `keys.swift`; crouch-running was checked by probe. One earlier run
failed when the mask tore at random mid-walk and fell off, which led to the torn-gear stop.
Multiplayer is still pending.

## Satanic Temples tests

Listed when `SatanicTemples` is enabled. Right-click → **Open Mod Showcase** → **Satanic Temples**.

- **Run the full Satanic Temples test** (it spawns corpses and a
  carcass, hurts you and changes your recovery ledger). It moves you to the designated test
  temple (see Test sites). You are hidden from zombies while it runs and healed
  between cases.
  1. **Temple:** builds `LilBubby Test Temple` beside you (or reuses it) and checks three bare
     skeleton mannequins with two katanas each, the jack-o'-lanterns and their glow.
  2. **Smoke:** stands you in the altar smoke and your own ritual wisp for 6 s: no damage, not
     on fire, the square not left burning.
  3. **Hidden verdicts:** a junk offering at ritual start reveals nothing (no result, the plank
     still there, a neutral sound cue, the verdict committed) and the wrath lands only when the
     ritual completes; a good offering likewise; walking away from junk still brings the wrath.
  4. **Refusals:** empty altar, unlit campfire and standing too far away are refused with the
     offering kept; a rare item with nothing to recover is refused and kept.
  5. **Rewards:** a katana, the assault rifle + 3 magazines recipe, a cow carcass beside the
     altar, an animal head, another player's corpse, and the same victim's corpse in a later
     life all restore Carpentry XP.
  6. **Punishments:** greed past full recovery, minor greed past the animal cap, a head mixed
     with junk, a plank, a zombie corpse and your own corpse (broken bones). Each checks the
     rolled damage is inside the sandbox range and that the loss never exceeds it by more than
     the wounds' own bleeding; nobody dies from full health.
  7. **Busy altar:** a second offering while a verdict is due is refused.
  8. **Katana theft:** trying to take a skeleton's katana is refused, flashes lightning, takes
     exactly half your health with at least two deep wounds, and the katanas stay.
  9. **Map** toggle; **repair pass:** a stolen katana is restocked, an old clothed mannequin
     becomes a skeleton, a missing pumpkin returns, and a second pass changes nothing.
  10. **Real ritual:** the Make a Sacrifice button is offered, and the full ritual (about a
      minute: stay put) restores XP at its end; a ritual broken by walking away takes and gives
      nothing.
- **Die and recover at the altar** (kills your character). Offers junk while badly
  hurt so the wrath kills you, respawns a new character automatically (or waits for you to make
  one), brings it back and checks it recovers the lost Carpentry XP with a katana.
- **Check my test temple:** only reads it: skeletons, pumpkins and what is on the altar.
- **Clean up my test temple:** clears the altar and test corpses of `LilBubby Test Temple`. The
  temple itself is the designated one and stays for the next player. No other temple is ever touched.
- **Show last result** reopens the report.

In multiplayer every world change is made by the server, for any player. The
server accepts only whitelisted offering items, the three corpse kinds, health cuts below 100 and
a temple rectangle of at most 30 x 30. Health changes it makes are synced to your client.

Live runs with the real game client: `bash tests/satanictemples/live/run_live.sh suite`
(see `tests/satanictemples/live/README.md`). It uses an isolated cache folder and never touches
~/Zomboid. On 2026-09-25, in single player, the live suite passed all 28 cases with one planned
death (earlier runs found the altar smoke burning players and a single-player identity bug; both
fixed). The in-game Showcase suite and multiplayer acceptance are still pending.

## Dynamic Events tests

Enable KIP Network Terminal (`KIPN`) and Dynamic Events (`DynamicEvents`) alongside this tester, then
right-click → **Open Mod Showcase** → **Dynamic Events**. Run it on a **multiplayer test server**; every
player can run every test. Dynamic Events finds participants through the server's online-player list, so events need a
server. Stand outdoors on open ground with about 30 tiles clear around you.

**How players who are not staff run it.** Dynamic Events only lets staff make and run events. The tester
never makes the player staff: while its server code runs one of the suite's operations for a player, Dynamic
Events' own gates answer yes for that player, and stop when the operation returns. The simulation panel's
buttons and the status request get the same treatment, on the tester's own events only (names starting with
the test prefix); the Studio's two read-only lists (events and past events) are open to everyone, so the
Studio window can fill. Real events stay refused, and KIPN's admin list and the player's role are untouched.

Every event the suite makes is built through Dynamic Events' own command handlers, called as you, exactly
as the Event Studio would. Each is named `[LilBubby Test] ...`, has you as its only participant and is
removed afterwards. The suite refuses to start while a real (non-test) event is running, because only one
event can run at a time. You are hidden from zombies during event tests, and moved where each test needs
you with the tester's own travel. The suite only ever acts on its own `[LilBubby Test]` events: the server
refuses any action on a real one.

- **Setup**
  - *Check the event services are running*: every Dynamic Events service is loaded, every event command
    has a handler (the services started), the event zone type and staff-tier check exist, and the server
    lists you as an online player.
  - *Check every loadout, kit and course item exists*: every item named by a starting loadout, an Olympic
    station default or the test flag is in this game's item scripts.
- **Event Studio**
  - *Check the Studio's checklist, defaults and templates*: every game mode's defaults apply, save and
    have a way to end; unchanged drafts are not "unsaved"; server reasons are explained in words.
  - *Open the Event Studio and walk every step*: opens the window and builds all nine steps for
    every game mode on a preview event that is never saved.
- **Running events**
  - *Run an event from draft to finished*: validate, announce (everyone online sees the test briefing),
    open joining (you get the sign-up prompt; the test answers it, close the window afterwards), begin (you
    are brought in and your HUD shows the event), stop, reset, delete. It links the event to the designated event zone (see Test sites).
  - *Check validation says what is missing*: seven events with something missing are refused with the
    right reasons; a complete one becomes Ready.
  - *Use the Director controls on a live event*: reads status, adds a minute, sends an announcement.
  - *Win a prize and mark it delivered*: a 15-second run with an apple as the prize; the award waits for an
    admin and is marked delivered.
- **Game modes**: each builds a small event around you and plays it through: Capture the Flag
  (the flag is put in your hands; you carry it to the goal), Team Capture the Flag (steal the enemy flag),
  King of the Hill (hold the hill for a 40-second round), Chase (you are the target; survive 30 seconds),
  Extraction (wait for the evac, then reach it; you are flown back), Prison Break (the exit stays locked
  until you search the spot), Fire Sale (two of three exits get a horde; leave by the clear one), Survivor
  Run (25 seconds), and The Olympics (a heat of one through all five stations: the test hands you the logs
  and planks and downs the targets; your medal is taken back off the medal table). *Dodgeball* and
  *Adventure* check last-one-standing and Adventure's roll-and-restore on the server.
- **Players**
  - *Start with each loadout and get your gear back*: for each of the nine loadouts your own gear goes into
    escrow, the loadout is handed out and put on, then it is taken back and your gear returned.
  - *Find a clue and replay it from the HUD*: walks you onto a narrative spot and a story hint; each leaves
    a clue button that shows it again.
  - *Check the HUD fades and comes back* (anyone): keep the mouse away from the top of the screen.
  - *Get moved by an event*: the event moves you 5 tiles (at once), then 40 tiles (in hops of 8 a second
    when the speed anti-cheat is on). In multiplayer this checks the server asked your client to move you.
- **Threats**
  - *Roll the difficulty 2000 times* (anyone): about half Dire or Brutal, about 1 in 8 Brutal.
  - *Siege, alarm and ambush on a live event*: waits for a siege (40 zombies), then walks you into
    an ambush. The alarm part needs you inside a building (3 minutes on Normal) and is skipped outdoors.
  - *Start a test fire nearby and put it out*: starts a real fire 10 tiles away on open ground,
    checks it burns, then puts it out.
- **Bandits**
  - *Bandit camp*: a crew of two waits 16 tiles away. They are calm until the test walks you up to them;
    then they fight, you are warned, and (on a server) you hear them shout.
  - *Bandit raid*: a raiding crew is sent at once and comes straight for you; everyone is warned.
  - *The Heist*: the getaway car appears with the gold in its trunk and a calm crew; your HUD says find the car;
    the pickup refuses you without the gold; the test takes the gold from the trunk for you, you hand it over
    at the pickup and win, the gold is banked and the run is in Past events.
- **Prepared events**
  - *Start (event)*: a Ready event gets Start with 15 seconds of sign-ups: you get the prompt (the test
    answers it), see the countdown, and the event begins by itself with you in it. Cancel then stops it and
    puts it back to Ready, and the run is in Past events.
  - *Cancel (event) from every stage*: Announced, a pending start, Joining (each back to Ready), Ready
    (back to Draft), and a Draft (nothing to cancel).
  - *Announcements for (event)*: your text as a banner; with no text, the briefing; drafts are refused.
  - *Check a simulation covers every part, in play order* (anyone): builds the steps for an event with one of
    everything without running it.
  - *Simulate (event)*: presses OK through every step. Checks you are invisible and unhurt, the guide lists
    every step, you are taken to each hotspot and it glows, zombies are outlined, the bandit is marked, the
    clue gets its HUD button, the story line, the demo fire (light only) and the win and lose text play;
    Finish takes you back and the event is untouched.
  - *Simulate: Edit, change the event, Resume*: Edit pauses and opens the Studio on the event; the test adds a
    hotspot; Resume plays the step again with one more step in the list. A Studio window stays open; close it.
  - *Simulation invitation: OK joins, Cancel opts out, Leave*: a stand-in host (never online) simulates
    the test event with staff invited, so you are the invited staff member. You get the invitation with OK and
    Cancel; the test presses OK (you are taken to the start and get the panel with only Leave), follows one
    of the host's steps, then Leave (you go back and it carries on). A second invitation is answered Cancel (you
    stay put and are not in it), and a third, unanswered, closes when the simulation ends.
  - *Check who may use the Studio and join simulations* (anyone): lists what the sandbox allows each KIPN
    staff level, checks the rules follow it, and that the server lets you in if your level is one of them.
  - *Simulate: Cancel leaves nothing behind*: runs to a step that has spawned things, cancels, and checks no
    zombie, bandit, item or car is left, the clues and glow are gone and you are back where you started.
- **Classic scenario locations**: one entry per Pillow scenario. Travels you to its original start
  point (a long trip on servers with the speed anti-cheat), checks it and the nearby exits and ambush rooms
  are open floor, then brings you back. "Run every test" skips these.
- **Clean up my test events**: stops, resets and deletes every `[LilBubby Test]` event, retires their
  zones, takes back items the suite gave you and restores the Olympics medal table. It also ends any test
  simulation or pending start and removes test runs from Past events.

Local regression checks: `lua -e "next=nil" tests/dynamicevents_checks.lua` loads Dynamic Events' real
server and client code (the Workshop copy when subscribed, else `~/Zomboid/Workshop/DynamicEvents`) with
the suite's own files, and drives every flow above tick by tick in a stand-in world, plus the server
half's staff stand-in and whitelist guards. Multiplayer acceptance on the dev server is still pending.

## Mod Compatibility tests

Listed when any of `SVSBoobyTraps`, `SpyVsSpySignalTracker`, `SkylightsProbe`, `KIPN`,
`BonkZone` or `SatanicTemples` is enabled. Only checks for enabled mods are offered.
Right-click → **Open Mod Showcase** → **Mod Compatibility** → **Run every automatic check**.

Several mods wrap the same vanilla entry points. These checks call the live Workshop mods'
hooks through the real outermost entry point, with stand-in recipes, actions and characters.
Each mod's hook calls the next one down through a named field, such as
`ISEntityUI.KIPN_OriginalHandcraftStart`. For one call, the check swaps that mod's field for a
counter and restores it straight away. Nothing below it runs, in particular vanilla crafting,
so nothing is crafted, queued, sent or spent.

- **Crafting hooks** (Booby Traps, KIPN, Signal Tracker, Skylights): the mod's own recipe
  without materials is refused, never reaches the next hook, and tells the player once. With
  materials it is passed on unchanged. Vanilla recipes and every other enabled mod's recipes
  pass through it untouched. The multi-craft and queued-action rechecks behave the same way.
  For Booby Traps, crafting time follows `CraftingTimeMultiplier` and vanilla time is unchanged.
- **Timed actions** (KIPN repair and disassembly, property and vehicle claims): refused without
  the required items, accepted with them, and rechecked at start before any animation. Booby
  Traps' rig-mailbox and Signal Tracker's RF-scan actions stop at start when their item has
  vanished, and send nothing to the server.
- **Claim fees** (KIPN + Government Services): cash counting with the default currency and a
  configured one, including money inside bags and exact-payment rules. The sandbox currency
  values are restored afterwards.
- **Zone Editor** (KIPN, Bonk Zone or Satanic Temples, multiplayer): each enabled
  mod's mode is listed exactly once, and survives role refreshes without duplicating. It opens
  the zone editor if it is closed and closes it again.

`lua tests/compat_checks.lua` runs these checks against well-behaved stand-in hooks and against
broken ones: a hook that swallows vanilla recipes, one that refuses silently, a missing hook, a
timed action without a start recheck, and duplicated zone editor modes.
