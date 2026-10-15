# COMPUTER Vehicle Claims

A **service module** for [KIP Network Terminal](../KIPN) (`id=KIPN`). It attaches to the Terminal's host framework and adds Knox County's DMV: **vehicle registration and title-based ownership**.

- a `dealership` zone type (Zone Admin Tool)
- the **Vehicle Registration** BBS desk — craft Vehicle Titles from Registration Forms
- vehicle ownership claims with server-authoritative non-owner access enforcement
- the **Vehicle Records** BBS screen
- the registration/title item + recipe scripts and the related sandbox options

**Without this mod, KIP Network Terminal has no vehicle claims and no `dealership` zone type.**

---

## Table of Contents

1. [Requirements & Installation](#1-requirements--installation)
2. [How It Attaches to the Terminal](#2-how-it-attaches-to-the-terminal)
3. [Setup](#3-setup)
4. [Vehicle Claims](#4-vehicle-claims)
5. [Non-Owner Access Enforcement](#5-non-owner-access-enforcement)
6. [Sandbox Options Reference](#6-sandbox-options-reference)
7. [Item & Recipe Scripts](#7-item--recipe-scripts)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Requirements & Installation

- **Game version:** Project Zomboid Build 42.
- **Hard dependency:** **KIP Network Terminal** (`id=KIPN`). `mod.info` declares `require=KIPN`, so the game loads KIPN first and refuses to load this without it.

Add both mods to your server, dependency order first:

```
Mods=KIPN;KIPNVehicleServices
WorkshopItems=3789107348;<this mod's id>
```

Restart the server. On boot you should see, in the console:

```
[KIPN] Vehicle Services init module loaded
[KIPN] Vehicle Services Claim Config loaded
[KIPN] Vehicle Services ... loaded            (claim / artifact / enforcement)
Vehicle Services initialized.
```

---

## 2. How It Attaches to the Terminal

At server start the module registers a `"VehicleServices"` add-on service via `KIPN.Server.RegisterService`. It runs **after every Terminal built-in** and:

- `WorldRegistry.RegisterZoneType("dealership", …)` — with the `vehicle.*` capabilities
- `Permissions.RegisterPermission("vehicle.lookup" / "vehicle.claim" / "vehicle.transfer" / "vehicle.revoke", …)` and grants them to the PLAYER / ADMIN roles
- `ClaimService.RegisterClaimType("vehicle", …)` — the target + artifact validators, and the `onAfterRelease` hook that clears the vehicle's ownership metadata
- `ArtifactService.RegisterArtifactType("Vehicle", …)`
- `ClaimConfig.RegisterService("Vehicle", …)` — so the per-service policy gets the same `<Service><Field>` sandbox treatment as the Terminal's built-ins
- `KIPN.Server.RegisterCommandHandler(…)` for `CLAIM_VEHICLE` and `ISSUE_VEHICLE_CLAIM`
- `ApplicationRegistry.Register("vehicle_registration" / "vehicle_records", …)` — the menu programs, which only appear when this mod is installed
- installs the non-owner access enforcement (movement ejection, the vanilla `ClientCommands.vehicle` mechanics/tow/door interception, and a periodic stationary-occupant audit)

See `../KIPN/Contents/mods/KIPN/README-SERVICE-API.md` for the full contract.

The Terminal keeps the generic claim-record store, artifact engine, the vehicle-object helper layer, and the permission-query layer; this mod supplies all the vehicle *policy* on top.

---

## 3. Setup

1. Have KIPN Terminal set up (admin access, computers placed).
2. **Draw at least one `dealership` zone** with the Zone Admin Tool (right-click a computer → the KIPN zone tool). Place a powered computer inside it — that's where players process Vehicle Registration Forms.
3. Decide your policy in Sandbox Vars → **KIPN** page ([§6](#6-sandbox-options-reference)): claim limit, expiry windows, and the non-owner access toggles.
4. Restart so every sandbox change takes effect.

---

## 4. Vehicle Claims

Vehicle claims follow the shared KIPN **Registration → authorized computer → Claim artifact → target** flow:

```
materials (paper, pen, tape, glue, paperclips)
        │  craft
        ▼
Vehicle Registration Form   (temporary, craftable, physical item)
        │  present at a computer inside a `dealership` zone
        ▼
Vehicle Title               (issued by the server, NOT crafted)
        │  carry to the vehicle + right-click
        │  (server validates artifact + zone + vehicle)
        ▼
Ownership established, Title consumed
```

- Registration Forms and Titles are **physical bearer items** — not account credentials, not bound to the account that made them. The server is authoritative for every step.
- Max claims per player defaults to **5**.
- **Vehicle ownership does not expire by default** (`VehicleOwnershipExpiryDays` = 0) — a vehicle is already a depreciating asset. The registration form and the Title itself still have their own 14-day expiry windows.
- Review your vehicle claims on the **Vehicle Records** screen.
- Releasing a vehicle claim clears its ownership metadata so anyone can use it again immediately.

---

## 5. Non-Owner Access Enforcement

Once a live KIPN vehicle claim exists, only the owner, an authorized player, or an admin may use the vehicle. This is enforced server-side — client menu gating is just immediate feedback.

- **Seating:** on movement (and via a periodic audit for stationary occupants and alternate entry paths) a non-owner in a claimed vehicle is **ejected** and set down outside, with a throttled warning.
- **Vanilla `ClientCommands.vehicle` interception:** mechanics (install/uninstall/repair parts), towing (add/remove), and opening doors are gated for non-owners by the sandbox toggles below. Lock/unlock, window control, and vandalism (`smashWindow`) always deny for non-owners regardless of settings.
- `VehicleNonOwnerNoAccess` is a **master denial switch** — when true it overrides every individual permission below.

---

## 6. Sandbox Options Reference

All options live on the shared **KIPN** sandbox page. Defaults shown are what ships.

### Claims — Vehicle

| Option | Default | Description |
|---|---|---|
| `VehicleClaimsEnabled` | true | Allows Vehicle Titles to be redeemed. |
| `VehicleRegistrationEnabled` | true | Allows Vehicle Registration Forms to be crafted and processed. |
| `VehicleMaxClaimsPerPlayer` | 5 | 0 = unlimited. |
| `VehicleRegistrationExpiryDays` | 14 | 0 = never expires. |
| `VehicleClaimTokenExpiryDays` | 14 | 0 = never expires. |
| `VehicleOwnershipExpiryDays` | 0 | 0 = ownership never lapses (default — vehicles already decay). |
| `VehicleClaimCraftSeconds` | 10 | Client-side "processing" wait at the dealership computer. |
| `VehicleNonOwnerNoAccess` | false | Master denial — overrides the three toggles below when true. |
| `VehicleAllowNonOwnerOpenUnlockedDoors` | false | Non-owners may open an *unlocked* door only. |
| `VehicleAllowNonOwnerTow` | false | Non-owners may add/remove towing. |
| `VehicleAllowNonOwnerMechanics` | false | Non-owners may install/uninstall/repair parts. |

Owners, authorized players, and admins are always unaffected by these.

---

## 7. Item & Recipe Scripts

Defined in this mod's `media/scripts/` and no longer runtime-editable (KIPN configuration is sandbox-only):

- `KIPN_VehicleArtifactItems.txt` — `Base.KIPNVehicleRegistration`, `Base.KIPNVehicleClaimArtifact` (Vehicle Title).
- `KIPN_VehicleArtifactRecipes.txt` — `KIPN.CreateVehicleRegistration` (a standard B42 `craftRecipe` block).

To change ingredients, time, icon, or add items: edit these files and restart the server (standard PZ script-file behavior).

---

## 8. Troubleshooting

**The Vehicle Registration / Vehicle Records menu options aren't showing.**
Check: this mod is in your server's `Mods=` line (after `KIPN`); the computer is physically inside an enabled `dealership` zone; the console shows `[KIPN] Vehicle Services init module loaded` on boot.

**A non-owner can still get into a claimed vehicle for a moment.**
Enforcement is reactive — it fires on the next movement tick / audit pass and ejects them. There is no pre-emptive seat lock.

**A player owns too many / too few vehicles.**
`VehicleMaxClaimsPerPlayer` (default 5). Restart after changing it.

**I set a non-owner toggle but it didn't apply.**
Sandbox options are read at server boot only — restart.

## Layout

```
Contents/mods/KIPNVehicleServices/42/
  media/lua/server/         KIPN_VehicleServicesInit, KIPN_VehicleClaimService,
                            KIPN_VehicleArtifactService, KIPN_VehicleEnforcement,
                            config/KIPN_VehClaimConfig
  media/lua/client/         KIPN_VehicleRegistration, KIPN_VehicleRecords,
                            KIPN_VehicleBridge, KIPN_VehicleClaimMenu,
                            TimedActions/KIPN_VehicleClaimAction
  media/scripts/            KIPN_VehicleArtifactItems.txt, KIPN_VehicleArtifactRecipes.txt
  media/sandbox-options.txt Vehicle claim / non-owner-access options
  media/lua/shared/Translate/EN/Sandbox.json
```
