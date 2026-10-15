# Spy vs Spy: Booby Traps

A standalone, server-authoritative Project Zomboid Build 42.20+ mod about noticing danger, inspecting carefully, and accepting the cost of sophisticated espionage.

## Feature set

| System | Trigger | Default counterplay |
|---|---|---|
| Water Bucket Door Trap | A closed standard door opens | Its rope is visible from the trapped side; opening from the other side spills it harmlessly |
| Nail Board | A player, zombie, animal, or vehicle crosses its tile | The world item and espionage warning icon are always visible in line of sight |
| Bear Trap | A player, zombie, or animal crosses its tile | The world item and icon are visible; a sprung trap must be reset with a held tool or weapon |
| Explosive Parcel | A player opens a rigged vanilla mailbox, trash can, or dumpster without inspecting | Inspecting reveals it and temporarily prevents accidental opening while the player disarms it |
| Contaminated Document | Reading or viewing the exact contaminated item begins | Inspect the individual document; masks, gloves, and active antibiotics reduce severity |
| Ignition Charge | The rigged vehicle's engine changes from off to running | Inspect and disarm the stationary vehicle before starting it |
| Driver-Seat Dye Trap | A new driver occupies the vehicle's driver seat | Inspect the vehicle; the one-use dye mark persists for the configured duration |
| Vehicle Tamper Alarm | Driver entry or access to vehicle storage | Inspect/disarm, or toggle it with its paired controller |
| Remote Immobilizer | The paired controller engages it | Find/disarm the device or jam the remote command path with Spy vs Spy: Signals |

Entry-level floor traps are deliberately obvious. Advanced traps are never sent to an unrelated client: a player receives a hidden trap's identity only after a server-validated inspection, ownership check, or admin overlay request.

Trap interactions queue walking before the action begins. A tripwire alarm lasts the same duration as a vanilla house alarm (49 seconds at normal speed), and a successful disarm immediately silences it. Biological samples use **Open Biological Sample** and **Neutralize Biological Sample**; anthrax document traps remain separate.

## Crafting requirements

Each trap has its own MAD Magazine recipe issue. A character must read the matching issue before the recipe becomes available; all skill and ingredient requirements still apply. The nine issues spawn in bookstores, libraries, magazine crates, schools, and—very rarely—living-room shelves.

Ingredient counts are fixed. Server owners may adjust skill gates, time, rarity, damage, visibility, equipment protection, and lifecycle values through Sandbox settings.

### Water Bucket Door Trap

Single-use: detonation removes the trap and leaves an empty bucket plus either one Rope or one Nail on its tile. The other ingredient is randomly lost; the bucket is always recoverable. This also applies when a failed disarm or pickup attempt triggers it.

- Carpentry 1
- One completely full vanilla Bucket of water
- Rope or Twine
- One Nail
- Hammer

### Nail Board

A nail board breaks on its fourth activation, leaving its crafting materials on the trap tile with one random item missing: either one Plank and seven Nails, or eight Nails without the Plank. Failed disarms, pickup attempts, and vehicle crossings count toward the same limit. Recovering and placing a used board again preserves its activation count.

- Carpentry 4
- Plank
- Eight Nails
- Hammer
- Saw
- Screwdriver or Handiknife

### Bear Trap

To set a carried bear trap, right-click the destination square and choose **Set Bear Trap Here**, or right-click it in your inventory and choose **Set Bear Trap at Current Tile**. The player walks to the chosen square before setting it. Loose ground bear traps must be picked up first.

- Trapping 3 and Welding 5
- Steel Bar or Iron Bar
- Heavy Chain
- Three Screws
- Plank
- Screwdriver or Handiknife
- Three Welding Rod units
- Welding Mask or old Welding Goggles
- One completely full Welding Torch

The Bear Trap recipe rejects partial torches and consumes the selected full torch's entire capacity. Setting risk at full condition is 25% at combined Trapping/Welding 8–9, 15% at 10–12, 7% at 13–15, and 2% at 16–20. Poor condition adds up to 40 percentage points, capped at 70%.

Freeing a trapped player, animal, zombie, or corpse and resetting the Bear Trap are separate actions. Use **Release Victim** to free the occupant first; the trap remains sprung. Releasing yourself requires a usable weapon in either hand; a rescuer can release someone else without one. Missing equipment and other locally known requirements are reported before walking or playing the interaction animation. Resetting requires a usable tool or weapon equipped in either hand and consumes no materials or tools. Short items (knives, screwdrivers, hammers) increase reset injury risk; longer items reduce it. The safest equipped item is used, with skill and trap condition still affecting the risk. Repair consumes one Welding Rod unit and torch fuel while a Welding Mask or Goggles is held. Each default repair restores up to 20 condition and permanently reduces maximum condition by 5.

A caught animal takes a severe injury (at least 70% of its current health at default damage settings). Sprinting or escaping the tile clears the trap's victim state and causes fatal bleeding over roughly three seconds while the animal is loaded. Deliberately releasing it avoids this escape injury. Caught zombies have their movement and AI restrained until released; their injuries continue while held.

An armed, empty bear trap can be **Reversed** to transfer ownership without restoring durability. Once armed, it can catch the original setter, reverser, or any other player.

### Advanced espionage devices

Every advanced recipe requires Electrical 3, Mechanics 3, Maintenance 4, one very rare **Precision Microswitch**, and one very rare **Covert Control Board**. These parts are loot-only in restricted electronics, engineering, military, police-evidence, and security containers.

The biological-agent recipe additionally requires First Aid 5 and an ultra-rare **Sealed Biological Sample**, found only in a few laboratory, hospital, medical-drug, and bunker-medical distributions. Its gameplay effect is intentionally fictionalized: exposure removes 25 maximum-health points by default and then applies corpse/generator-like sickness over time. It has no secondary transmission in this release.

## Interactions

- Right-click a trap item to deploy it on the current tile or an appropriate nearby target.
- Right-click a world tile, door, mailbox, trash can, dumpster, or vehicle to place, inspect, disarm, reverse, salvage, reset, or repair as appropriate.
- A successful inspection grants five minutes of server-side knowledge, enough to reopen a rigged container safely and choose a countermeasure.
- Searching is audible work. One of three sounds plays as you start, and one of three more when you finish -- a different set depending on whether anything turned up. Anyone nearby hears all of it, including how your search went, and so do the zombies.
- Disarming returns the device. Salvaging trades recovery for common materials and a small chance of one of the rare parts. Reversing transfers ownership and rearms the device when enabled.
- Tamper alarms and immobilizers create a controller during installation. Right-click that exact controller to query or toggle its paired device.
- Every successful set -- a floor trap, a rigged container, a trip wire, a vehicle device, or a bear trap reset -- plays one of five sounds, chosen by the server so everyone in earshot hears the same one. It is also a real world noise: zombies close enough to hear it will come looking, so where and when you set a trap matters. A bear trap that springs shut on your own arm makes no such sound; it was never set.
- Those same five sounds play again when a trap goes off, louder and from the trap's own tile -- so the noise, and the zombies it pulls in, arrive where the trap is rather than where the victim ran to. Anthrax counts: an opened jar sounds once for each new person it gasses, and a contaminated page goes off in the reader's hands.

## Optional Spy vs Spy: Signals integration

There is no hard dependency. When `GPSMod` / Spy vs Spy: Signals is present and integration is enabled:

- Its RF Signal Detector gains **Scan for Wireless Trap Signals**.
- The scan reports only strength, approximate distance, and—at high Electrical skill—device class.
- Active Signals jammers may block remote immobilizer commands and tamper-alarm alerts.
- Jamming never disables a mechanical/local trigger, an ignition transition, or an already-running fuse.

## Multiplayer and persistence

Every trap stays inactive until the player setting it moves at least **two tiles away**. This fixed distance applies to floor traps, rigged containers, trip wires, vehicle devices, contaminated documents, and opened biological samples, including resets and reversals. Vehicle devices measure from the vehicle's current position; exiting alone does not arm them. Trip wires measure from the nearest point along the wire. Documents must be left behind or transferred before the setter can move clear. Logging out does not arm a pending trap. Once armed, returning does not make it safe again.

Live traps affect all players, regardless of PVE/safety status, faction, administrator status, or survival time. Safehouse placement permissions and the global trap/target switches remain configurable.

Player deaths from trap damage credit the owner at the time of injury (the setter or most recent reverser) with one PVP kill. Attribution is retained for ongoing injuries and tracked trap fires after the device is removed; healing or a different attacker clears stale attribution. Offline owners receive their queued kill counts when they return. Animals and zombies never award PVP kills.

- Placement ingredients, item IDs, range, skills, safehouses, limits, targets, condition, triggers, injuries, exposure, vehicle state, and disarm results are validated on the server.
- The persistent registry is stored under a randomized server-local ModData tag whose token is never sent to clients.
- A legacy public registry is migrated automatically if one is found.
- Timed placements, inspections, scans, repairs, and disarms require a server-observed start and minimum duration.
- Visible snapshots expose only nail boards, bear traps, door ropes, and optional admin-overlay entries.
- Every material action is audit logged. Every instrumented function contributes to a bounded, aggregated **Meta Time Run Log**; verbose mode prints individual traces.

## Server configuration

The mod defines Sandbox options under **Spy vs Spy: Booby Traps**, including:

- Master, tier, and per-device switches
- Safehouse placement permissions, offline operation, and equipment protection
- Per-player, per-square, per-container, per-vehicle, and safehouse limits
- Every skill gate and all action durations
- Rare-loot weights, salvage chances, damage, condition, wounds, wetness, and illness
- Visible icon, rope, LOS, floor, passive-detection, and inspection behavior
- Every mod sound -- setting a trap, a trap detonating, and searching for one -- each with its own on/off switch, zombie-attraction radius, and volume
- Parcel fuse/radii, fire policy, and content destruction
- Vehicle alarms, dye duration, engine damage, wireless range, and heartbeats
- Signals detector/jammer interoperability
- Audit, verbose, Meta Time Run Log, sync, persistence, and tick budgets

Exact ingredient counts are intentionally not configurable.

## Admin tools

Admins receive context-menu actions to:

- Open registry and Meta Time Run Log diagnostics
- View concealed devices through the admin overlay
- Remove all trap records and physical floor devices inside the configured radius

## Installation

For local installation, copy `Contents/mods/SVSBoobyTraps` into the Project Zomboid Workshop/content structure used by Build 42 and enable **Spy vs Spy: Booby Traps**. For Workshop upload, select the extracted folder that directly contains `Contents`, `preview.png`, and `workshop.txt`.
