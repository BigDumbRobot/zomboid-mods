# Careers Framework

Build 42.20 server-authoritative framework for player-run careers on KIPN. It
adds no playable career by itself; each career ships as its own Workshop item
that depends on this one.

| Workshop folder | Mod id | Role |
|---|---|---|
| `KIPN_Careers` (this item, Workshop id 3795313541) | `CareersFramework` | **Framework.** Career registration and the services every career shares: currency, licenses, storefronts, reputation, the inbox, flyers, zone types and threats. Requires `KIPN`. |
| `CareersDrugDealer` | `CareersDrugDealer` | Drug Dealer career. Requires `KIPN`, `CareersFramework` (and N&C's Narcotics by default). |
| `CareersMechanic` | `CareersMechanic` | Mechanic career. Requires `KIPN`, `CareersFramework`. |
| `CareersBlacksmith` | `CareersBlacksmith` | Blacksmith career. Requires `KIPN`, `CareersFramework`. |

Dependency chain: `KIPN` -> `CareersFramework` -> any career mod. Careers do
not depend on each other.

## Installation

Server load order:

`Mods=KIPN;N&CsNarcotics;CareersFramework;CareersDrugDealer;CareersMechanic;CareersBlacksmith`

Drop any career you don't run (and `N&CsNarcotics` if you don't run Drug
Dealer). Add each Workshop ID you use to `WorkshopItems`.

### Migrating from the single "KIPN Careers" item

The old mod ids (`KIPNCareers`, `KIPNCareersDrugDealer`, `KIPNCareersMechanic`,
`KIPNCareersBlacksmith`) are replaced by the ids above. Update the server's
`Mods=` and `WorkshopItems=` lines. Nothing else changes: the Lua namespace,
item module (`KIPNCareers.*`), sandbox variables (`SandboxVars.KIPNCareers.*`)
and saved data (`KIPN.Server.GetData().careers`) are unchanged, so existing
licenses, shops, orders, items in the world and sandbox values carry over.
Each mod now has its own sandbox page instead of one shared "KIPN Careers" page.

### Upgrading to Framework 3.2 (careers built on `Careers.Register`)

Update the framework and every career you run **together**. The framework
carries `KIPNCareers.Shared.API_VERSION`; a career that needs a newer
framework than the one installed logs a line and stays off instead of
failing to load. An updated framework still runs older careers.

- **Drug Dealer sandbox options are renamed.** They now carry the career's
  name like every other career's: `KIPNCareers.LicensePrice` is
  `KIPNCareers.DrugDealerLicensePrice`, and so on for all 21. Re-enter any
  value you had changed from its default on the Careers: Drug Dealer page.
- **Drug Dealer saved data moves.** Its tables used to sit at the root of
  `GetData().careers`; they are now in `GetData().careers.drug_dealer`, moved
  once the first time 1.3 starts. Back up the server's KIPN data first: an
  older Drug Dealer does not read the new place.
- Mechanic and Blacksmith data, items, commands and sandbox options are
  unchanged.

## First-time administration

1. Log into a KIPN terminal with an administrator account.
2. Open `Career Services` -> `Zones`.
3. Draw at least one `Career Services` zone around the terminal(s) allowed to
   issue licenses. One zone serves every installed career.

> **Known gap / planned change:** the zone commands are the framework's own
> (any career or admin tool can send them), but the `Zones` editor screen
> still lives in the Drug Dealer mod's Career Services program, so a server
> running only Mechanic and/or Blacksmith has no screen to draw the zone
> with. The planned fix replaces admin-drawn business zones entirely: the
> framework registers a `business` claim type with KIPN's `ClaimService` (the
> way Government Services registers `property`) and a **Business Services**
> terminal program. A player carries a career's Business License to the
> property and claims it there, like a safehouse.

## Sandbox settings (Careers Framework page)

| Option | Default | Notes |
|---|---|---|
| `CurrencyItemType` | `Base.Money` | Used by every career. Falls back to `Base.Money` if the item type doesn't exist. |
| `CurrencyItemValue` | 1 | Value of one currency item. License prices are rounded up to the next multiple; a player's own offer must be an exact multiple. |
| `FlyersPerRestart` | 4 | Flyers distributed per business after each restart. |
| `FlyerSpawnChancePercent` | 12 | Chance per eligible container. |
| `BlockAnySafehouseStorefront` | false | When true, no storefront may be established in any safehouse (by default, only other players' safehouses are blocked). |
| `ThreatsEnabled` | true | Thieves, raiders, difficult customers and ambushes for every installed career (see Threats). |
| `ThreatFrequencyPercent` | 100 | Scales how often incidents start. 0 = never, 300 = three times as often. |
| `ThreatMinCalmHours` / `ThreatMaxCalmHours` | 18 / 60 | After an incident a business is quiet for a random time in this range (shorter at higher tiers). |
| `ThreatNewBusinessGraceHours` | 24 | No unscripted incidents for this long after a business opens. |
| `ThreatMaxLossPercent` | 25 | Most of a building's eligible stock one theft can take. |
| `ThreatOwnerRadius` | 60 | Incidents at a business only start while its owner is within this many tiles. |

## Building a career on the framework

A career is an ordinary Build 42 mod with `require=KIPN;CareersFramework` in
its `mod.info`. The three bundled careers are the reference implementations;
Mechanic is the cleanest template.

**Rules that keep careers independent:**

- Give every Lua and script file a name unique to your career (PZ resolves
  same-path files across mods by override). The bundled careers use
  `KIPNCareers_<Career>*.lua` and `KIPNCareers_<Career>Items.txt`.
- Keep your wire names, enums and defaults in your own table
  (`KIPNCareers.Mechanic`, `KIPNCareers.Dealer`), never on
  `KIPNCareers.Shared`.
- Your data lives in your own slice, `KIPN.Server.GetData().careers.<id>`,
  which the framework creates for you. Never read another career's slice.
- Put your sandbox options on your own page (`page = <YourModId>`) and prefix
  their names with your career (`KIPNCareers.<Career>LicensePrice`).
- Register your own permissions and menu programs from your own server Init
  file, and namespace your commands (`mechanic.*`).
- Check the framework is new enough before using it:
  `if (KIPNCareers.Shared.API_VERSION or 1) < 2 then return end`.

### Registering a career

One call, in your server file. Fill in only what your career uses.

```lua
require "KIPNCareers_Careers"
local Careers = KIPNCareers.Careers

local Career = Careers.Register("mechanic", {
    label = "Mechanic",
    idPrefix = "mech-",                 -- in front of every id the career makes
    schemaVersion = 1,
    tables = { "orders", "messages" },  -- your own tables in the slice
    storefronts = "shops",              -- the slice table holding storefront records
    storefrontNoun = "shop",            -- as it reads in a message to the player
    events = { RESULT = "kipnMechanic.result", NOTIFICATION = "kipnMechanic.notification" },
    startingReputation = function() return settings().StartingReputation end,
    license = { item = "KIPNCareers.MechanicBusinessLicense", tokenField = "kipnMechToken",
                name = "Mechanic Business License -- " },
    storefront = { capability = "career.mechanic.shop", label = "Mechanic Shop",
                   permission = "careers.mechanic.owner" },
    flyer = { title = "Flyer -- ", fields = { "name", "adText" },
              write = function(modData, record, fields, revision)
                  modData.kipnMechName = fields.name or record.name
                  return modData.kipnMechName   -- shown in the item's name
              end },
    migrate = function(careersRoot, slice) end,  -- once per start, before the slice is used
    onClose = function(record) end,              -- before a storefront closes
})
```

The same id is used everywhere: the storefront registry, threats, the data
slice and the inbox. The returned object does what every career does the
same way:

| Method | What it does |
|---|---|
| `Career:State()` / `:Save()` / `:MakeId(prefix)` | The slice (always with `licenses`, `reputation`, `pendingCurrency`, `flyerQueue`, `meta`, your tables and the storefront table), saving, and ids. |
| `Career:Result(player, action, ok, code, message, extra)` | Answers a command on your `RESULT` event. |
| `Career:Notify(ownerKey, title, body, relatedId)` | Files a notice in the shared inbox and tells the owner if they are online. |
| `Career:ReputationFor(ownerKey)` / `:AdjustReputation(ownerKey, delta, reason)` | Reputation, 0-100. |
| `Career:Credit(ownerKey, amount, reason)` / `:SettlePending(player)` / `:Pending(ownerKey)` | Money owed to someone who may be offline, paid the next time they are around. |
| `Career:IssueLicense(player, price)` -> tokenId, or nil, code, message | Charges, creates the license item and its record; refunds on any failure. |
| `Career:FindLicense(player, tokenId)` -> license, entry | The unused license and the item carrying it. |
| `Career:CheckSite(player)` -> rect, or nil, code, message | Everything a new storefront must pass (see Storefronts). |
| `Career:OpenStorefront(player, license, entry, record)` | Spends the license, files the record, grants the owner permission and draws the capability zone. |
| `Career:CloseStorefront(id, closedBy)` | Marks it inactive, removes its zone and flyers, revokes the permission, tells the owner. |
| `Career:OwnedStorefront(ownerKey)` / `:StorefrontAt(x, y, z)` / `:StorefrontAtComputer(computerId, player)` / `:Storefronts()` | Lookups in your own storefronts. |
| `Career:ActivateFlyerQueue()` / `:DistributeFlyer(object)` | Flyers: queue new revisions at start-up; roll for one in a loot container. |
| `Career:RegisterCommands(handlers, sessionCommands, authMessage)` | Puts your handlers on the KIPN router; returns false until KIPN is ready. |
| `Career:RegisterThreats(events)` | Opts your storefronts in to Threats with your reputation and inbox. |

`Careers.Bootstrap(initialize)` calls your start-up function when the server
data is ready and retries until it returns true. `Careers.Get(id)` returns a
registered career. `Careers.HasServicesAccess(computerId, player)` is the
"at a terminal in a Career Services zone" check every license sale uses.

### Framework API (server side unless noted)

| Module | Use |
|---|---|
| `KIPNCareers.Shared` (shared) | `Log(scope, level, msg)`, `Trim`, `Clamp`, `API_VERSION`, the `career_services` zone type / capability constants, `Items.FLYER`, and the framework's own `Commands` / `Events`. |
| `KIPNCareers.Careers` | `Register`, `Get`, `All`, `Bootstrap`, `Settings`, `HasServicesAccess`, `Inbox(ownerKey)`, `FindTokenItem`, `CloseStorefront(careerId, id, closedBy)`, `SetNotificationPublisher(fn)`. |
| `KIPNCareers.Host` | What is the same in every career: `NowHours`, `RandomInteger`, `Identity`, `Username`, `KipnPlayerId`, `IsAdmin`, `OnlinePlayerByIdentity`, `Send`, `Root`, `Save`, `HasAuthenticatedSession`, `CollectItems`, `ComputerCoords`, `AtComputer`. |
| `KIPNCareers.Economy` | `Charge(player, amount)` -> ok, reason, receipt; `RefundReceipt`; `GrantNow`; `Balance`; `Price(amount)` (round a configured price up to what the currency can pay); `IsCurrency(fullType)`; `IsValidAmount`; `RoundDown`; `DropAt`; `CountIn` / `TakeFrom` for containers; and the pending ledger `Credit` / `Settle` / `Pending`. Always move money through this. |
| `KIPNCareers.ZoneBridge` | `RegisterZoneType(zoneType, { label, capabilities })` for a zone type of your own, `Create` / `Update` / `SetActive`, `OverlapsNoClaim(rect)`, `CreateBusinessZone(rect, id, capability, label)`, `RemoveBusinessZone`, `ComputerHasCapability`, `GetZones`, `GetZonesAt`. |
| `KIPNCareers.Storefronts` | `CheckSite(player)`, `At(x, y, z)`, `ForOwner(ownerKey)`, `Overlaps(rect, ignoreCareerId, ignoreId)`, `BuildingRectangle`, `SafehouseBlocked`, `Contains`, `Register(careerId, provider)`. |
| `KIPNCareers.Threats` | `Context`, `RollMoment`, `MarkIncident`, `AddHeat`, the `Presets` (`Thieves`, `Raiders`, `Ambush`), `RollTemperament` and the building blocks under them. See Threats below. |

**Commands the framework answers** (so they work whichever careers are
installed; answers go out on `Shared.Events.RESULT`):

| Command | Who | What |
|---|---|---|
| `careers.inbox` / `careers.markInboxRead` | anyone | The shared inbox. It appears as **MY BUSINESS** on the KIPN Announcements screen for the owner of a storefront in any career. |
| `careers.adminCreateZone` / `adminUpdateZone` / `adminToggleZone` | admins | Career Services zones, and any zone type a career registered. |
| `careers.closeStorefront` `{ careerId, storefrontId }` | the owner, or an admin | Closes a storefront. No bundled screen sends it yet. |

### Storefronts

A career registered with `storefronts = "<table>"` is in the cross-career
registry automatically. `rect` / `bounds` is `{ x1, y1, x2, y2 }` in world
tiles; a record needs `bounds`, `ownerKey` and `active`.

`Storefronts.CheckSite(player)` returns the building rectangle, or nil and a
code, checking in order: the player is inside a building
(`PLAYER_NOT_IN_BUILDING`, `BUILDING_DEFINITION_UNAVAILABLE`,
`BUILDING_BOUNDS_UNAVAILABLE`), it is clear of No Claim zones
(`NO_CLAIM_ZONE`), no career has a storefront there (`STOREFRONT_OCCUPIED`),
and it is not another player's safehouse (`SAFEHOUSE_OWNERSHIP_REQUIRED`).
A provider that throws makes `Overlaps` return true (fail closed) and logs
the career id.

Closing a storefront keeps its record, inactive. Orders in flight are left
to the career's `onClose`; with none, they run out and refund the way any
unattended order does.

## Threats

Server-authoritative incidents that make running a business risky: thieves,
raiders, difficult customers, ambushes. The server decides everything —
whether something happens, who shows up, what is stolen or damaged, what is
recovered. The hostile NPCs are server-spawned zombies in vanilla outfits
(thieves stay passive while they sneak in). No other NPC mod is used.
Customers are never bodies: they are the server-created work orders on the
business's KIPN page. `Threats.RollTemperament` gives each one a hidden mood
that the career applies when the order is completed. The only client file, `KIPNCareers_ThreatsClient.lua`, draws the speech
lines the server sends and decides nothing.

**Pacing (keeps it unpredictable, not punishing):**

- A new business has a grace period (`ThreatNewBusinessGraceHours`).
- After an incident a business stays calm for a random
  `ThreatMinCalmHours`–`ThreatMaxCalmHours` window.
- After that, each 10-minute check has a small chance, and only while the
  owner is online and within `ThreatOwnerRadius`. Nothing happens to an
  absent owner's business.
- Recent business activity (`AddHeat`) raises the chance for about a day.
- Theft is capped at `ThreatMaxLossPercent` of a building's eligible stock.
  Stolen goods drop where a thief dies, so a quick response gets everything
  back. Structures never drop below 25% health and goods never break
  outright. Licenses, forms, parcels (anything with `kipn*` ModData) and
  currency are never taken by ordinary thieves.

**Progression.** Tier comes from the career's own reputation: tier 1 below
25, 2 below 50, 3 below 75, 4 at 75 and above. Higher tiers mean more
frequent checks, bigger and tougher crews in rougher outfits, bolder
thefts, shorter calm windows and more difficult customers.

**Opting a career in** (in its own server file). A storefront record needs
`id`, `ownerKey`, `bounds`, `anchor`, `active` and `createdAt`:

```lua
require "KIPNCareers_Threats"
local Threats = KIPNCareers.Threats

Career:RegisterThreats({
    { id = "thieves", weight = 1, minTier = 1,
      run = function(ctx) return Threats.Presets.Thieves(ctx, { lines = MY_LINES }) end },
})
```

(`Threats.Register(careerId, { businesses, reputation, notify, events })` is
what that calls, and still works on its own.)

The scheduler rolls `events` by weight. For moments the career owns (a
completed work order, a drop), call `Threats.RollMoment(careerId, business, percent, player)`.
It returns a context or nil. Start an incident with a preset, then call
`Threats.MarkIncident(ctx)` so the calm window applies. The bundled careers
use a `Service.Bridge` table to hand their internals to a separate
`KIPNCareers_<Career>Threats.lua` file.

Incidents live in memory. A server restart ends them, and their bodies stay
in the world as ordinary zombies. Only pacing is saved, in
`KIPN.Server.GetData().careers.threats`.

## Testing

Two offline checks live in this project's `tests/` folder (outside
`Contents/`, so they are not uploaded). Run them from this folder; they load
the framework and the career projects beside it (`../CareersMechanic`, ...):

- `lua tests/framework_checks.lua` loads the framework and the three careers'
  real server code together in a small fake world and drives the real
  commands: licenses and currency, one storefront per building across
  careers, No Claim zones, capability zones, lookups, the shared inbox, zone
  types and the admin editor, flyers, closing a storefront, and the Drug
  Dealer's old sandbox names and old save layout.
- `lua tests/version_checks.lua` checks a career switches itself off cleanly
  when its server Bridge, the threats layer or the framework version is
  missing or too old.

The threats harness lives in the LilBubbyModTester mod. Run
`lua tests/careers_threats_checks.lua` from its folder; it loads the Careers
mods from their Steam Workshop subscriptions. It runs the threats layer, the Economy
helpers, the Mechanic walk-in completion (through the real Mechanic server) and
the Dealer shakedown and ambush against a mock PZ world (68 assertions).

It can't show how real B42 zombies behave in multiplayer. Before production,
run a dedicated-server smoke test with `ThreatFrequencyPercent = 300` and
`ThreatNewBusinessGraceHours = 0`, and check:

1. Spawned bodies appear for every nearby client, in the right outfits.
2. `pathToLocationF` walks them to the shop, and passive (`setUseless`)
   bodies still walk but don't attack.
3. Hitting a passive thief turns its crew hostile.
4. Stolen items disappear from containers for clients and reappear on the
   ground where a thief dies. When a hostile customer's crew is killed, the
   member carrying the money drops it.
5. Damaged player-built structures show the new health after a relog.
6. Speech lines appear over the right heads.

## Compatibility surface

Uses these game APIs on the server: `addZombiesInOutfit`, `IsoZombie`
(`pathToLocationF`, `setUseless`, `setTarget`, `setHealth`, `removeFromWorld`),
`IsoThumpable` health, `sendRemoveItemFromContainer`,
`sendAddItemToContainer`, `sendItemStats` and `AddWorldInventoryItem`.

Uses these public KIPN interfaces: `KIPN.Server.WorldRegistry`
(`RegisterZoneType`, `CreateZoneFromCorners`, `GetZones*`, `UpdateZone`,
`SetZoneActive`, `GetComputerCapabilities`), `KIPN.Server.Permissions`
(`GrantPermission`, `RevokePermission`), `KIPN.Server.RegisterService`,
`RegisterCommandHandler`, `GetComputer`, `AuthService.GetPlayerSession`,
`GetData` / `Save`, `KIPN.Logger` and `KIPN.Server.SendToPlayer`. KIPN core's handcraft preflight allows
recipes in the `KIPNCareers.` script module. It does not edit KIPN core files.
