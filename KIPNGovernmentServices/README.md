# COMPUTER Safehouse and Land Claims

A **service module** for [KIP Network Terminal](../KIPN) (`id=KIPN`). It attaches to the Terminal's host framework and adds Knox County's property office: **safehouse (property) and excavation ownership claims**.

- a `government` zone type (Zone Admin Tool)
- the **Government Services** BBS desk — craft Safehouse Deeds and Excavation Permits from Registration Forms
- managed safehouse claims (KIPN overrides vanilla safehouse claiming)
- excavation land claims in Small / Medium / Large permit sizes
- the **Property Records** BBS screen
- proximity claim overlays + a KIPN button in the vanilla safehouse menu
- the deed/permit/registration item + recipe scripts and the related sandbox options

**Without this mod, KIP Network Terminal has no property or excavation claims and no `government` zone type.**

---

## Table of Contents

1. [Requirements & Installation](#1-requirements--installation)
2. [How It Attaches to the Terminal](#2-how-it-attaches-to-the-terminal)
3. [Setup](#3-setup)
4. [The Claim Lifecycle](#4-the-claim-lifecycle)
5. [Safehouse (Property) Claims](#5-safehouse-property-claims)
6. [Excavation Claims](#6-excavation-claims)
7. [Sandbox Options Reference](#7-sandbox-options-reference)
8. [Item & Recipe Scripts](#8-item--recipe-scripts)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Requirements & Installation

- **Game version:** Project Zomboid Build 42.
- **Hard dependency:** **KIP Network Terminal** (`id=KIPN`). `mod.info` declares `require=KIPN`, so the game loads KIPN first and refuses to load this without it.

Add both mods to your server, dependency order first:

```
Mods=KIPN;KIPNGovernmentServices
WorkshopItems=3789107348;<this mod's id>
```

Restart the server. On boot you should see, in the console:

```
[KIPN] Government Services init module loaded
[KIPN GOV CLAIM CONFIG] Initialized.
[KIPN] Government Services ... loaded          (×4 service modules)
Government Services initialized.
```

---

## 2. How It Attaches to the Terminal

At server start the module registers a `"GovernmentServices"` add-on service via `KIPN.Server.RegisterService`. It runs **after every Terminal built-in** and:

- `WorldRegistry.RegisterZoneType("government", …)` — with the `property.*` / `excavation.*` capabilities
- `Permissions.RegisterPermission("property.lookup" / "property.claim" / "property.transfer" / "excavation.lookup" / "excavation.claim" / "safehouse.admin" / "safehouse.owner", …)` and grants them to the PLAYER / ADMIN roles
- `ClaimService.RegisterClaimType("property" / "excavation", …)` — validators, release hooks, and the `deferAccessToEngine` (property) / `enforceEntry` (excavation) permission flags
- `ArtifactService.RegisterArtifactType("Property" / "Excavation", …)`
- `ClaimConfig.RegisterService("House" / "Excavation", …)` — so the per-service claim policy gets the same `<Service><Field>` sandbox treatment as the Terminal's built-ins
- `KIPN.Server.RegisterCommandHandler(…)` for `CLAIM_PROPERTY`, `CLAIM_EXCAVATION`, `RELEASE_SAFEHOUSE`, `ISSUE_PROPERTY_CLAIM`, `ISSUE_EXCAVATION_CLAIM`, `RENEW_CLAIM`, `GET_EXCAVATION_SIZE_TIERS`, `GET_CRAFTING_REQUIREMENTS`, and the safehouse sync / overlay requests
- `ApplicationRegistry.Register("government_services" / "property_records" / "property_claim" / "excavation", …)` — the menu programs, which only appear when this mod is installed

See `../KIPN/Contents/mods/KIPN/README-SERVICE-API.md` for the full contract.

The Terminal keeps the generic claim-record store, artifact engine, and permission-query layer; this mod supplies all the property/excavation *policy* on top.

---

## 3. Setup

1. Have KIPN Terminal set up (admin access, computers placed).
2. **Draw at least one `government` zone** with the Zone Admin Tool (right-click a computer → the KIPN zone tool). Place a powered computer inside it — that's where players process Registration Forms.
3. Decide your claim policy in Sandbox Vars → **KIPN** page ([§7](#7-sandbox-options-reference)): claim limits, expiry windows, non-owner permissions, and the excavation permit dimensions/prices.
4. Decide the excavation permit currency (`KIPN.ClaimCurrencyItemType` / `KIPN.ClaimCurrencyItemValue`) if you don't want plain `Base.Money`.
5. Restart so every sandbox change takes effect.

> By default players **cannot** establish new safehouse or excavation claims whose footprint overlaps *any* KIPN zone (`KIPN.HouseAllowClaimsInKIPNZones` = false) — this keeps government buildings, dealerships, etc. from being claimed as personal property.

---

## 4. The Claim Lifecycle

Both claim types follow the same **Registration → authorized computer → Claim artifact → target** flow:

```
materials (paper, pen, stapler, staples, paperclip)
        │  craft
        ▼
Registration Form           (temporary, craftable, physical item)
        │  present at a computer inside a `government` zone
        ▼
Claim Artifact              (Safehouse Deed / Excavation Permit — issued
        │                    by the server, NOT crafted)
        │  carry to the target + right-click
        │  (server validates artifact + zone + target)
        ▼
Ownership established, artifact consumed
```

- Registration and Claim artifacts are **physical bearer items** — not account credentials, not bound to the account that made them. Anyone holding a valid artifact in the right place can use it. The server is authoritative for every step; duplicated / replayed / expired / consumed artifacts are always rejected.
- Each service has its own **quota**, **registration expiry**, **claim-token expiry**, and **ownership expiry** — all sandbox options.
- **Ownership expires in 120 in-game days by default** for both types, and must be renewed. Review your claims and expiry dates on the **Property Records** screen.
- **Renewal:** in Property Records at a powered computer inside a `government` zone, click **[ RENEW ]** then **[ CONFIRM RENEW? ]** on the claim. It costs one Registration Form of the matching type (Safehouse or Excavation), can be done any time while the claim is active, and restarts the full ownership period. Claims within 7 days of expiry show **RENEW SOON**. An expired claim is released and cannot be renewed.
- `ClaimCraftSeconds` (default 10) is a **client-side UX countdown only** shown while the computer "processes" the exchange — no bearing on server validation.

---

## 5. Safehouse (Property) Claims

- Craft a **Safehouse Registration Form**, take it to a computer inside a `government` zone, exchange it for a **Safehouse Deed**.
- Carry the Deed to the house/building and right-click to claim.
- The claim records the building's footprint. The vanilla safehouse KIPN creates covers the footprint plus a **2-tile no-entry buffer** on every side, and no other safehouse may overlap that buffered area.
- KIPN **overrides vanilla safehouse claiming** while `KIPN.SafehouseClaimsEnabled` is true — vanilla's own claim action is replaced by KIPN's. Set it false to restore vanilla safehouse claiming and disable KIPN's.
- Vanilla `SafeHouse` objects are still used under the hood as the engine-level protection/compatibility layer, but **KIPN owns the policy**: entry, looting, fire, and respawn rules are mirrored from KIPN's sandbox options into the vanilla `ServerOptions` fields (`SafehouseAllowTrepass`, `SafehouseAllowFire`, `SafehouseAllowLoot`, `SafehouseAllowRespawn`, `DisableSafehouseWhenPlayerConnected`). Each is a 3-way enum: **Unset** (leave the server's existing value alone — the default), **True**, or **False**.
- KIPN imposes no *additional* KIPN-side access restriction on property claims (`deferAccessToEngine`) — vanilla SafeHouse stays the sole protection authority.
- **Release quirk:** after releasing a KIPN-managed safehouse, a player may briefly still see "View Safehouse" in the vanilla right-click menu for that house until their next login. Cosmetic only — the record is cleared in KIPN and the house is available to others immediately.
- Max claims per player defaults to **1**.

---

## 6. Excavation Claims

- Craft an **Excavation Registration Form**, take it to a `government`-zone computer, exchange it for an **Excavation Permit**.
- Excavation Permits come in **exactly three fixed size classes — Small, Medium, Large.** You can retune each class's width, height (tiles), and price via Sandbox Vars, but cannot add a fourth or remove one:

  | Class | Size (default) | Price (default) |
  |---|---|---|
  | Small | 5×5 tiles | 200 |
  | Medium | 10×10 tiles | 500 |
  | Large | 20×20 tiles | 1000 |

- The permit fee is paid from the player's **physical inventory cash only** — `Base.Money` (value = `KIPN.ClaimCurrencyItemValue`, default 1) plus `Base.MoneyBundle` (always $100 when the currency item is `Base.Money`). No external economy provider is involved. The exact fee must be present as whole bills/bundles — **KIPN never makes change.**
- Placement is re-validated server-side against a max distance from the player's own position, so a forged/stale click coordinate can only ever select a spot the player is actually standing near.
- Non-owner permissions default to **allow entry, deny building/looting/excavating** inside a claimed plot: `ExcavationAllowNonOwnerEnter` (true), `ExcavationAllowNonOwnerBuild` (false), `ExcavationAllowNonOwnerLoot` (false), `ExcavationAllowNonOwnerExcavate` (false). All are enforced:
  - **Enter** — a non-owner is **pushed back out** on movement (reactive: fires after the engine moves you; you're teleported to your last allowed tile) with a throttled warning.
  - **Loot** — `ISInventoryTransferAction` is blocked for any container physically on a claimed tile (transfers within your own carried inventory are never gated).
  - **Build / Excavate** — the world-object right-click menu strips Disassemble / Dismantle / Sledgehammer / Pick-Up / Dig / Remove-Grass entries on a claimed tile.

  The build/loot/dig gates are **client-side** (the same layer PZ's own safehouse protection uses) — the server stays authoritative for ownership itself. New construction placed through the build menu (B) is not intercepted.
- Max claims per player defaults to **2**.

---

## 7. Sandbox Options Reference

All options live on the shared **KIPN** sandbox page. Defaults shown are what ships.

### Claims — Safehouse ("House")

| Option | Default | Description |
|---|---|---|
| `SafehouseClaimsEnabled` | true | True = KIPN claim system overrides vanilla; false = vanilla safehouse claiming restored. |
| `HouseMaxClaimsPerPlayer` | 1 | 0 = unlimited. |
| `HouseRegistrationExpiryDays` | 14 | 0 = never expires. |
| `HouseClaimTokenExpiryDays` | 14 | 0 = never expires. |
| `HouseOwnershipExpiryDays` | 120 | 0 = never lapses. |
| `HouseClaimCraftSeconds` | 10 | Client-side "processing" wait at the Government computer. |
| `HouseAllowClaimsInKIPNZones` | false | Allow new safehouse claims whose footprint overlaps a KIPN zone. |
| `SafehouseAllowTrepass` | Unset | Vanilla `SafehouseAllowTrepass` projection (Unset/True/False). |
| `SafehouseAllowFire` | Unset | Vanilla `SafehouseAllowFire` projection. |
| `SafehouseAllowLoot` | Unset | Vanilla `SafehouseAllowLoot` projection. |
| `SafehouseAllowRespawn` | Unset | Vanilla `SafehouseAllowRespawn` projection. |
| `DisableSafehouseWhenPlayerConnected` | Unset | Vanilla `DisableSafehouseWhenPlayerConnected` projection. |

"Unset" always means *leave the server's existing vanilla value alone*; only True/False actively overwrite it.

### Claims — Excavation

| Option | Default | Description |
|---|---|---|
| `ExcavationClaimsEnabled` | true | |
| `ExcavationMaxClaimsPerPlayer` | 2 | 0 = unlimited. |
| `ExcavationRegistrationExpiryDays` | 14 | 0 = never expires. |
| `ExcavationClaimTokenExpiryDays` | 14 | 0 = never expires. |
| `ExcavationOwnershipExpiryDays` | 120 | 0 = never lapses. |
| `ExcavationClaimCraftSeconds` | 10 | |
| `ExcavationAllowNonOwnerEnter` | true | When false, non-owners are pushed back out on movement. |
| `ExcavationAllowNonOwnerBuild` | false | When false, the world-object menu's Disassemble/Dismantle/Sledgehammer/Pick-Up/Dig entries are removed on a claimed tile (client-side). |
| `ExcavationAllowNonOwnerLoot` | false | When false, item transfers to/from containers on a claimed tile are blocked (client-side). |
| `ExcavationAllowNonOwnerExcavate` | false | Folded into the Build filter (Dig / Remove Grass entries). |
| `ExcavationSmallWidthTiles` / `HeightTiles` / `Price` | 5 / 5 / 200 | |
| `ExcavationMediumWidthTiles` / `HeightTiles` / `Price` | 10 / 10 / 500 | |
| `ExcavationLargeWidthTiles` / `HeightTiles` / `Price` | 20 / 20 / 1000 | |

### Claims — Payment

| Option | Default | Description |
|---|---|---|
| `ClaimCurrencyItemType` | `Base.Money` | Single-unit currency item consumed from inventory to pay the Excavation Permit fee. `Base.MoneyBundle` is always treated as 100 of it. |
| `ClaimCurrencyItemValue` | 1 | Value of each configured currency item. |

### Registration form master switches

| Option | Default |
|---|---|
| `PropertyRegistrationEnabled` | true |
| `ExcavationRegistrationEnabled` | true |

(The overall artifact engine also has `KIPN.ArtifactsEnabled` on the Terminal.)

---

## 8. Item & Recipe Scripts

Defined in this mod's `media/scripts/` and no longer runtime-editable (KIPN configuration is sandbox-only):

- `KIPN_GovArtifactItems.txt` — `Base.KIPNPropertyRegistration`, `Base.KIPNPropertyClaimArtifact` (Safehouse Deed), `Base.KIPNExcavationRegistration`, `Base.KIPNExcavationClaimArtifact` (+ `Small` / `Medium` / `Large`).
- `KIPN_GovArtifactRecipes.txt` — `KIPN.CreatePropertyRegistration`, `KIPN.CreateExcavationRegistration` (standard B42 `craftRecipe` blocks).

To change ingredients, times, icons, or add items: edit these files and restart the server (standard PZ script-file behavior). The "See Required Crafting Items" panel on the Government Services desk reads a fixed reference list served by `server/config/KIPN_GovCraftingReference.lua` — keep it in sync if you change the recipes.

---

## 9. Troubleshooting

**The Government Services / Property Records menu options aren't showing.**
Check: this mod is in your server's `Mods=` line (after `KIPN`); the computer is physically inside an enabled `government` zone; the console shows `[KIPN] Government Services init module loaded` on boot.

**A player can't claim a house inside what looks like a normal building.**
Its footprint probably overlaps a KIPN zone — safehouse claims are blocked inside KIPN zones by default (`HouseAllowClaimsInKIPNZones` = false), and always blocked by `do_not_claim` zones (plus the `DoNotClaimZoneBufferTiles` buffer).

**A player can't afford an Excavation Permit even though they have money.**
The fee must be present as whole `Base.Money` bills / `Base.MoneyBundle` bundles summing to the exact price — KIPN never makes change. Check `KIPN.ClaimCurrencyItemType` / `ClaimCurrencyItemValue` if you use a non-default currency.

**I changed an excavation tier size/price and nothing happened.**
Excavation dimensions/prices are sandbox-owned — restart the server.

**A released safehouse still shows "View Safehouse" in the vanilla menu.**
Cosmetic, clears on the player's next login. The KIPN record is already gone and the house is claimable by others.

## Layout

```
Contents/mods/KIPNGovernmentServices/42/
  media/lua/server/         KIPN_GovServicesInit, KIPN_SafehouseService,
                            KIPN_SafehouseBridge, KIPN_PropertyClaimService,
                            KIPN_GovArtifactService,
                            config/{KIPN_GovClaimConfig, KIPN_GovCraftingReference}
  media/lua/client/         KIPN_GovernmentServices, KIPN_PropertyRecords,
                            KIPN_Safehouse*, KIPN_Excavation*, KIPN_*ClaimMenu,
                            KIPN_ClientClaimConfig, TimedActions/KIPN_PropertyClaimAction
  media/lua/shared/         KIPN_GovShared (RENEW_CLAIM / CLAIM_RENEWED names)
  media/scripts/            KIPN_GovArtifactItems.txt, KIPN_GovArtifactRecipes.txt
  media/sandbox-options.txt Safehouse / Excavation / tier / payment options
  media/lua/shared/Translate/EN/Sandbox.json
```
