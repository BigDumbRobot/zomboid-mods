# Dynamic Events

Staff-directed dynamic multiplayer event framework for Project Zomboid Build 42.

## Status: work in progress — not yet independently loadable

This mod was **extracted from the [KIP Network (KIPN)](../KIPN) mod**, where the event
framework was originally developed as one of several bundled systems. KIPN has been
refocused on ownership claims (safehouse / excavation / vehicle), and the event framework
now lives here as its own mod.

The Lua sources under `Contents/mods/DynamicEvents/42/media/lua/` were moved verbatim and
still carry the `KIPN_` file/table prefix and expect several `KIPN.*` shared globals and
server-infrastructure services (data persistence, network command router, permissions,
world registry / zones, escrow) that were provided by KIPN. Making this mod load and run
on its own still requires:

- Renaming the `KIPN_` prefix / namespace to a `DE_` (Dynamic Events) namespace.
- Providing the shared symbols captured in
  `Contents/mods/DynamicEvents/42/media/lua/shared/DynamicEvents_Shared.lua`
  (copied out of KIPN's `KIPN_Shared.lua`).
- Re-implementing or depending on: server ModData persistence, the client-command router
  (`KIPN.Server.RegisterCommandHandler` / `GetCommandHandler`), the permissions layer,
  the world registry / zone system (Event Zones), and event escrow / reward delivery.

## Running an event: the Event Studio

Right-click anywhere in the world:

- **Dynamic Events** opens the Event Studio. Admins always see it; other KIPN staff levels see it when the
  server allows them (sandbox options below).
- **Dynamic Events: Director Controls** opens the live controls for a running event, for every KIPN staff level
  (Moderator, Staff, GM, Observer, Admin). Each control keeps its own tier.

Sandbox options, page **Dynamic Events** (the server enforces both; the menu only follows them):

| Option | Default | Allows |
|---|---|---|
| Event Studio: Moderators / Staff / Game Masters / Observers | off | that level to use the whole Studio: build, start, announce, cancel, simulate, prizes, past events |
| Simulations: invite Moderators / Staff / Game Masters / Observers | on, on, on, off | that level to be invited into simulations |

The Studio's left column has three lists: **Saved** (every event),
**Prepared** (ready to run or already announced) and **Past** (every run that ended: won, lost, stopped by staff
or cancelled before it began, with who played and who won; kept in ModData `DynamicEventsHistory`, newest
50). Below the list, **Director Controls** opens the live controls for a running event.

The Studio builds an event in nine steps, shown as a bar across the top:

1. **Mode**: name, game mode (picking one fills in rules, timers and goals it needs), variant, rounds, teams, flag item.
2. **Area**: zone, or separate hotspots, or the whole map; "Draw it on the map" / "Place all needed around me" for required hotspots.
3. **Rules**: combat rules, timer and lengths, time of day and weather.
4. **Zombies**: director, theme, spawn radius.
5. **Goals**: objective types, ways to win, optional automatic end checks.
6. **Story**: briefing, win/lose text, player checklist, optional story stages and triggers.
7. **Rewards**: prizes (with item search) and delivery; prizes waiting to be handed out.
8. **Players**: optional hand-picked roster, teleport, team moves.
9. **Launch**: one button that always shows the next stage (Check and mark ready > Announce > Open joining > Begin > Director > Reset), a list of anything still missing, and a summary.

On the Launch step, a prepared event has four actions, each named after the event (for example "Start Church Siege"):

- **Start**: announces it, asks everyone online to sign up, shows a countdown banner and begins
  it when the sign-up time (10 to 600 seconds, default 60) is over. From Joining it begins at once.
- **Simulate**: see below. Drafts can be simulated too.
- **Announcements for**: a banner to everyone online. The box starts with the briefing.
- **Cancel** (asks twice): calls off a simulation or a pending start; stops a live, announced or
  joining event and puts it back to Ready (it stays in Prepared, and the run goes in Past); a Ready event goes
  back to Draft for editing.

### Simulate

A stepped walk-through of the event exactly as designed, run by the admin who starts it (the host). No
players are invited and the event's status never changes.

Tick **Invite online staff (their choice)** to invite every online staff member the sandbox allows. Joining is
voluntary: each gets a short invitation with **OK** and **Cancel**. OK takes them to the simulation (its start,
or wherever it has got to) and in; Cancel opts them out and the simulation carries on without them. Guests see
the same guide panel with only **Leave**, which takes them back; the host moves the steps on and sees who
joined, opted out or left. Unanswered invitations close when the simulation ends. If the host disconnects, the
simulation waits a minute for them, then cleans up.

Steps, in order: the briefing; the zone; the starting loadout, laid out at your feet; every hotspot in the
order players meet it (spawns, bases, the Olympics course, items, hills, clues, bandits, zombie spawns,
ambushes, the way out); every story trigger, its actions played for those watching only; the threats, shown
small (the fire is only light); rounds and the clock; the ending (win and lose text, prizes); done.

At each step you are moved there and the step plays: clues appear (with their HUD button), zombies walk in,
the bandit camp or getaway car appears, and so on. A panel along the bottom lists every step, explains this one
and waits for you:

- **OK**: the next step (the last one says **Finish**).
- **Edit**: pauses here and opens the Studio on the matching step, with every option available. Change or add
  anything and save, then press **Resume**: the steps are rebuilt from the saved event and this step plays again.
- **Cancel**: removes everything the simulation made (zombies, bandits, the car, items, clues) and takes
  everyone back where they started. (For a guest this button is **Leave**.)

While it runs every hotspot glows on the floor in its kind's colour, the one this step is about pulses under a
light, zombie spawns and ambushes glow red, bandit places magenta, and the zone's edge orange. Zombies nearby
are outlined as in combat (red; bandits magenta). You are invisible and cannot be hurt. Everything a step spawns
is removed when the next step starts.

A step shows `(n)` and an orange border while it is missing something, and turns green when it is complete.
The panel on the right explains the current step and lists what is still needed. The checklist mirrors the
server's own validation. Moving between steps saves. Once an event begins, the Studio closes and a small strip
in the bottom-left corner shows its round, time left and log, with buttons for Director and Studio.

## The game modes, as players play them

Every mode runs itself once it begins: rounds start after a 20-second "get ready" and follow each other
after a 15-second break, and players are told what is happening with big on-screen banners. Each
participant has a HUD at the top of the screen with their goal in one sentence, the clock, the score and
which way (and how far) to go. Staff can still step in from Director Controls.

| Mode | Loop | Winner |
|---|---|---|
| Capture the Flag | Each round a flag spawns; carry it to the delivery point (FFA) or steal the enemy flag and bring it to your base (Team CTF). 3 rounds of 8 min. | Most captures |
| King of the Hill | Each round reveals a new hill; a team scores time only while alone on it. 3 rounds of 5 min. | Most rounds held |
| Chase | Each round a new player is the target (everyone gets a turn); hunters see the target's position every 30 s. 3 rounds of 5 min. | Most points (escape = target scores, catch = every hunter scores) |
| Extraction | Hold out; the evac arrives for the last 3 minutes; reach the Extraction Point to be flown out. Prison Break: search the marked spot first, then run for the exit. | Everyone extracted |
| Survivor Run | Survive until the clock runs out; falls are announced; ends early if everyone is down. | Everyone still alive |
| Adventure | Rolls one of the above inside your zone. | As rolled |
| **The Olympics** | Athletes sign up for a Knox County town. Heats of two race the course (start line, stations, finish line) after a 3-2-1-GO; leaving the line early is a false start. Stations: checkpoint, chop wood (bring logs back), craft (from a kit), heavy lift (carry a load to the drop zone), shooting (down every target). Timed to a tenth of a second, split times called out. Dying, disconnecting or the heat time limit is a DNF. Course templates: Obstacle Course, Sprint, Biathlon, Lumberjack, Marathon. | Gold, silver, bronze; a medal table by town carries over between Olympics |

## Classic scenarios (from `EXAMPLE/`)

Every scenario in Pillow's Random Scenarios is a one-click template on the Mode step. Each sets the mode, how
players start (their own gear goes into escrow and comes back afterwards), a Normal / Dire / Brutal difficulty
roll, the threats and the briefing. The Area step can build it at its original location.

| Pillow scenario | Becomes | Players start as | Threats |
|---|---|---|---|
| Abandoned Soldier | Extraction: hold out, then evac | Soldier (rifle, pistol, knife, pack) | Siege from every side |
| Hospital Challenge | Extraction: Hospital Ward | Patient (gown, drunk, splinted fracture) | Alarm |
| Last Ditch Security | Extraction: Last Ditch, March Ridge dorm | Night security (hammer, nails, sheet ropes) | Siege |
| Prison Challenge | Extraction: Prison Break, Rosewood prison | Prisoner (jumpsuit, one random tool) | Alarm; ambushes in dining hall, break room, yard, entrance |
| Fire Sale | Extraction: Fire Sale, Louisville mall; six service exits, one clear | Mall rat (own gear + crowbar, duffel) | Fires, alarm |
| The Test Subject | Extraction: fight up through the secret base | Test subject (gown, lantern, stone) | Ten room ambushes from the caves to the lobby |
| The Last Flight | Extraction: crash survivor awaiting rescue | Pilot (flight suit, pistol, injuries; pack and first-aid kit thrown clear) | Siege |
| Enter the Area | Extraction: Road Trip, county line to March Ridge | Drifter (hoodie, hiking bag of food) | none |
| Naked and Afraid | Survivor Run | Naked with one silly item, max panic | Alarm |
| Dodgeball of the Dead | Survivor Run, last one standing wins | Naked | Siege |
| The Heist (new) | Extraction: bandits stole the gold; find their car, stop them, bring the gold to the pickup | Own gear | Bandit raids |

Abandoned Soldier, Hospital and The Last Flight have no evac spot in the original scenarios, so after setting
them up at their location, draw the Extraction Point ("Draw it on the map" offers it next).

Not ported, as they are not gameplay: `EXAMPLE/Scenarios` (the game's own developer debug starts: a location
and empty setup code) and the three `JusblazmScenario.lua` copies (one developer's test start for a banking mod).
Not ported from Pillow: permanent skill boosts (they would change players' real characters) and Last Ditch's
destroyed stairs (map edits that would outlast the event).

## Bandits

Raider crews, built the way the careers threats are (`KIPNCareers_Threats.lua` in Careers Framework): each
bandit is a server-spawned zombie in a raider outfit (rougher on Dire and Brutal), kept calm until provoked.
They shout, carry loot and drop it where they fall. They fight as zombies do (no guns), so their hits can infect. They can disrupt any story or be the story:

- **Bandit Camp** hotspot: a crew (1 to 12) waits there, calm until a participant comes within 10 tiles or
  hits one of them; then the whole crew fights.
- **Getaway Car** hotspot: the crew's car, parked with its crew around it. In The Heist the gold is in its
  trunk and the leader carries the key, so players can drive it to the pickup.
- **Bandit raids** threat: a crew arrives every few minutes (7 on Normal, 5 on Dire, 3.5 on Brutal), comes for a
  player, and its leader carries supplies worth taking.
- **Bandits arrive** story action: a crew turns up at the trigger's hotspot when a story step fires.
- **The Heist** (Extraction variant and classic template): only a player carrying the gold can leave by the
  pickup, and the gold is banked as they do. Halfway through, a witness points the HUD at the car. Leave a trail
  of Narrative clues to it.

Camps and the car appear the first time their square is loaded, so a far-off hideout works. Bandits think every
second, on their own tick. Bodies still standing, the car and any gold are removed when the event ends.

Clues: text from a Narrative Location hotspot, or from a story trigger's private hint, appears as a large
banner and is kept as a button on the player's HUD ("Diary page", "Clue 2", "Hint"). Clicking it shows the clue
again. Clues are replayable by default (a tick on the hotspot turns it off), survive reconnecting, and last until
the event ends.

Always-on screens (the player HUD and the admin's live tracker) fade to mostly see-through 5 seconds after the
mouse leaves them, and return when hovered or when something new arrives (a new goal, a new clue, the result).
Banners are unaffected.

Joining: **Open joining** asks every online player to sign up (the Olympics asks for a town), and **Begin**
brings everyone signed up in. Anyone who missed it gets a prompt when the event starts and at each new round.
Players arrive at a Player Spawn if there is one, otherwise somewhere clear of every objective.

Moving players: in multiplayer each client owns its position, so a server-side `setX` does not move anyone.
Every move (joining, being returned to the zone, the Olympics start line, flying out, a simulation step) goes
through `server/KIPN_EventMoveService.lua`, which asks the player's client to move itself
(`client/KIPN_EventMoveClient.lua`). Long moves hop 8 tiles a second unless the server has the speed
anti-cheat off or the player may teleport, the same rule as the tester's travel.

Banners sent to someone who is not in an event (a countdown, an announcement) show on their own, with no
empty HUD strip behind them.

Offline checks, run from this folder:

- `lua tests/studio_checks.lua`: Studio checklist, mode defaults, Olympics course plan, save payload, the Heist.
- `lua tests/studio_ui_smoke.lua`: every Studio step and button, the Saved / Prepared / Past lists, the four
  prepared-event actions, opening at a step, the player HUD (banner-only messages too) and the simulation panel
  (glow, outlines, lights, invisibility, OK / Edit / Resume / Cancel), against stand-in UI classes.
- `lua tests/server_loop_checks.lua`: plays every mode through on the real server code in a fake world
  (clock, players, items, zombies) and checks rounds, scoring, winners and endings, plus loadouts,
  difficulty, sieges, fires, alarms, ambushes, Fire Sale's safe exit and last one standing; bandit camps,
  raids and story crews; The Heist from car to pickup; moves (jump, hop, exact positions); Start with its
  countdown; Cancel from every stage; announcements; Past events; a whole simulation (every step, Edit and
  Resume, Cancel leaving nothing behind); voluntary invitations (OK joins, Cancel opts out, guests can only
  Leave, withdrawn at the end, the host's minute of grace); and Studio access by sandbox option.

The same three files are kept in LilBubbyModTester's `tests/` as `dynamicevents_studio_checks.lua`,
`dynamicevents_studio_ui_checks.lua` and `dynamicevents_server_loop_checks.lua` (they find this mod's code from
either folder). The tester's `dynamicevents_checks.lua` fails if a copy differs from the one here, so change
them here and copy them across.

## Split repairs

These were lost when Dynamic Events left KIPN and have been restored here:

- The event command and response names (`DynamicEvents_Shared.lua`); every call was sending a nil command.
- Starting the event services (`server/DynamicEvents_Server.lua`); nothing called their `Initialize()`,
  so no command had a handler and nothing ticked.
- The "event" zone type and `Permissions.AuthorizeEventTier` (`server/DynamicEvents_KIPNCompat.lua`),
  each added only if KIPN lacks it.
- `mod.info` now declares `require=\KIPN`.

### Files

- `media/lua/server/` — the event services (scenario, runtime, director, participation,
  reward, escrow, timer, hotspot, team, trigger, capture, KOTH, chase, extraction,
  survivor-run, adventure, Olympics, objective/mode registries, zombie-theme registry,
  scenario-runtime registry), `KIPN_ZombieDirector`, the game loop that runs rounds and feeds the
  player HUD (`KIPN_EventGameLoopService.lua`), Studio and simulation access (`KIPN_EventAccessService.lua`),
  bandits (`KIPN_EventBanditService.lua`), moving players
  (`KIPN_EventMoveService.lua`), the prepared-event actions (`KIPN_EventControlService.lua`), the simulation
  (`KIPN_EventSimulationService.lua`), past events (`KIPN_EventHistoryService.lua`), and the start-up and
  KIPN compatibility files.
- `media/lua/client/` — the Event Studio (`KIPN_EventStudio.lua` logic, `KIPN_EventStudioUI.lua`
  window, `KIPN_EventStudioLiveUI.lua` corner strip), the player HUD (`KIPN_EventPlayerHUD.lua`),
  the simulation panel and visual aids (`KIPN_EventSimulationUI.lua`), the client side of moves
  (`KIPN_EventMoveClient.lua`) and bandit speech (`KIPN_EventBanditClient.lua`),
  event director control UI, panel, trigger
  (the right-click entries), participation prompt, and the older single-page scenario admin UI
  (`KIPN_EventScenarioAdminUI.lua`, no longer opened from anywhere; still loaded because it shows
  briefing/win/fail narrative text to every player).
- `media/lua/shared/DynamicEvents_Shared.lua` — event-related constants and preset tables
  copied out of KIPN's `KIPN_Shared.lua`.
- `media/sandbox-options.txt` and `media/lua/shared/Translate/EN/Sandbox.json` — the staff access options.
