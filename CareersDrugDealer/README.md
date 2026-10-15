# Careers: Drug Dealer

Mod id `CareersDrugDealer`. Requires `KIPN` and `CareersFramework`; does not
require any other career. See the Careers Framework README for install order
and framework settings (currency, flyers, safehouse policy).

## Included

- Registered as a KIPN add-on the supported way: `RegisterZoneType`, `RegisterService`, and `ApplicationRegistry` menu programs (`CAREER SERVICES`, `BUSINESS PROFILE`).
- `Career Services` administration page with the `Career Services` zone type (authorizes license purchases). No delivery zone is needed.
- Physical, tokenized Drug Dealer Business Licenses purchased with the configured KIPN Careers currency.
- Right-click storefront establishment inside a building, with KIPN No Claim and safehouse checks.
- A `Business Profile` terminal page that appears only at a KIPN terminal inside your own storefront: business details, every work order the business is responsible for, and a per-order **Complete Work Order** button.
- Business profile form and server-created flyer items populated from the saved fields; new flyer revisions enter loot distribution only after the next server restart.
- Server-generated Mad-Libs purchase orders with reputation-scaled item tiers, quantities, deadlines, and payouts.
- Player-funded public or direct-to-business work orders with persistent escrow.
- **Map-wide delivery.** Deliver to any mailbox (one step, sealed instantly) or any other container (two steps: drop, then the owner completes the work order while the drop still holds the full quantity).
- Exact item/quantity validation, expiry, refunds, payment, and reputation changes.
- Physical sealed player-order parcels. The token is server-backed, redeemable once, and intentionally bearer property: another player can steal and open it.
- The Career Services home feed, and the framework's private career inbox inside the KIPN Announcements screen (MY BUSINESS tab).
- A decoupled currency shared by every profession: `KIPNCareers.CurrencyItemType` / `KIPNCareers.CurrencyItemValue`, fallback `Base.Money`.
- Server-side logging at function and transaction boundaries.

## Required and optional mods

| Component | Requirement |
|---|---|
| Project Zomboid | Build 42.20 or compatible Build 42 release |
| KIPN | Required |
| Careers Framework (`CareersFramework`) | Required; load before this mod |
| N&C's Narcotics | Required by default; [Workshop 3404956403](https://steamcommunity.com/sharedfiles/filedetails/?id=3404956403), Mod ID `N&CsNarcotics` |

The Narcotics adapter validates every configured full item type against the live script manager at server startup. Missing item IDs are logged and disabled instead of crashing order generation. `AdditionalDrugItemTypes` and `DisabledDrugItemTypes` accept comma-separated full item types.

Restart the server after installing or changing item scripts; flyer distribution and adapter validation are restart-sensitive.

## First-time administration

1. Log into a KIPN terminal with an administrator account.
2. Open `Career Services` → `Zones`.
3. Draw at least one `Career Services` zone around the terminal(s) allowed to issue licenses.
4. Confirm the server log reports validated `NnC.*` catalog items.

That is the only required setup. Deliveries do not need a zone — a dealer can deliver to any mailbox or container anywhere on the map.

## Player flow

### Open a business

1. Save enough physical KIPN currency for the configured license price.
2. Use a KIPN terminal inside a Career Services zone and purchase the license.
3. Carry the issued license into a building.
4. Right-click and choose `Start Your Drug Dealer Business`.
5. Open Career Services → Business and save the business/flyer form.
6. Restart the server. The new flyer revision then enters the configured loot-distribution queue.

The license is bearer property. Whoever physically carries a valid, unredeemed license token may establish the business. Storefronts cannot overlap active KIPN businesses or KIPN No Claim zones. By default, a player may use their own safehouse but not another player's; `BlockAnySafehouseStorefront` can prohibit all safehouse storefronts.

### Complete work

1. Open Dealer Work and accept an available system or player order. The server starts a randomized deadline; no mailbox is assigned.
2. Put the exact requested N&C item quantity into a container anywhere on the map.
3. **Mailbox (one step):** right-click the mailbox → `Seal Drug Delivery`. The delivery finalizes immediately — items consumed, dealer paid; player orders also seal a parcel in that mailbox, release escrow, and give the buyer the coordinates.
4. **Any other container (two steps):** right-click the container → `Drop Drug Delivery`. The order becomes `FULFILLED` and the business owner is notified. The owner opens **Business Profile** at a terminal inside the storefront and presses **Complete Work Order** — which is only offered while the drop container still holds the full requested quantity. Completion runs the same finalize actions (parcel placed back in the drop container for player orders).

Accepting alone does not increase reputation. Completing work increases it; declining system work applies a small loss; declining player work applies no loss; missing an accepted deadline applies the larger failure loss. A `FULFILLED` order does not expire on the delivery deadline and does not count against the accepted-order limit.

### Threats

Built on the framework's Threats layer (see the Careers Framework README for
pacing and sandbox options).

- **Rival crews** sometimes hit the storefront while you're nearby. They go
  for the drugs and cash in its containers, rough the place up and fight.
  Put them down to get the goods back.
- **Drop ambushes.** When you seal or drop a delivery, a rival crew may be
  waiting for you. On a two-step drop they also go for the drop container.
  Kill them, then put the goods back before **Complete Work Order**.
- **The Syndicate** (reputation 25+). A demand for a cut of the last week's
  deliveries arrives on your business's KIPN page.
  - To pay, leave the amount in currency in any container inside the
    storefront before the deadline, and they collect it.
  - If you refuse, enforcers turn up at the storefront without warning while
    you're there.

### Submit a player work order

Any authenticated KIPN user can open Career Services → Place Order, then choose:

- drug and quantity;
- standard or urgent timing;
- offered payment;
- public board or a specific business;
- buyer note.

The entire offer leaves the buyer's physical inventory and enters persistent escrow when posted. An unaccepted cancellation/expiry or dealer failure returns it through the pending-currency queue. The buyer learns the delivery location only after the delivery is completed.

## Security and persistence rules

- Clients submit intent; the server resolves identity, building bounds, zones, items, prices, status transitions, time, reputation, and payouts.
- License, parcel, order, business, escrow, notification, and reputation records live under `KIPN.Server.GetData().careers.drug_dealer` and save through `KIPN.Server.Save()`. Notifications are in the framework's shared inbox, `careers.notifications`. Before 1.3 these tables sat at the root of `careers`; they are moved into the slice the first time 1.3 starts (back up the server's KIPN data before updating).
- License and parcel items contain token IDs, but item ModData is never sufficient without the matching live server record.
- Payouts are queued in persistent pending currency before currency items are issued.
- A parcel token changes from `SEALED` to `REDEEMED` exactly once. A copied item with the same token fails validation after redemption.
- License and escrow charges remove the configured `KIPNCareers.CurrencyItemType` directly from inventory (`KIPNCareers_Economy`); the mod does not use KIPN's MarketplaceService.
- Terminal actions require an authenticated KIPN server session. License issuance also verifies that the player is near the claimed KIPN computer inside a Career Services zone.
- World actions validate the accepted dealer identity, range to the container, deadline, and exact contents. Complete Work Order additionally re-checks storefront ownership and that the drop container still holds the goods.

## Career announcement adapter

Career notifications are persisted privately and displayed in the Career Services home feed and the KIPN Announcements screen's MY BUSINESS tab. They are also emitted live through KIPN's server-response transport. If the installed KIPN Announcements service exposes a private-message publisher, bind it without modifying this add-on:

```lua
KIPNCareers.Careers.SetNotificationPublisher(function(ownerKey, notice, careerId)
    -- Call the server's private KIPN Announcements publisher here.
    -- ownerKey is steam:<id> or user:<name>.
    -- notice contains id, title, body, relatedId, createdAt, unread and source.
    -- careerId is the career that filed it ("drug_dealer", "mechanic", ...).
end)
```

The hook is intentionally explicit because the supplied KIPN public service surface includes command routing but does not declare a stable private-announcement publish API. Career Services remains fully functional without the hook.

## Sandbox settings

Every option on the Careers: Drug Dealer page is named `KIPNCareers.DrugDealer<Name>` (`DrugDealerLicensePrice`, `DrugDealerEnabled`, ...). Before 1.3 they had no prefix; re-enter any value you had changed from its default after updating.

The main balance controls are the currency item type and value, license cost, starting reputation, success/failure/decline reputation changes, buyer/dealer order caps, listing lifetime, standard and urgent deadline ranges, system-offer interval, open system offers per business, payout multiplier, container interaction distance, flyer count/chance, safehouse policy, and narcotics item allow/deny additions.

`KIPNCareers.CurrencyItemType` (default `Base.Money`) and `KIPNCareers.CurrencyItemValue` (default 1) apply to every KIPN Careers profession. If the configured item type is missing from the script manager the mod falls back to `Base.Money`. When the item value is greater than one, license prices are rounded up to the next multiple and player offers must be exact multiples of it; generated system payouts round down to a valid multiple with a one-unit-value minimum.

## Compatibility surface

This add-on uses these public KIPN interfaces:

- `KIPN.Server.RegisterCommandHandler`, `GetCommandHandler`, `GetData`, `Save`, `SendToPlayer`, `GetComputer`, and `RegisterService`;
- `KIPN.Server.AuthService.GetPlayerSession`;
- `KIPN.Server.Permissions.RegisterPermission` / `GrantPermission` / `HasPermission`;
- `KIPN.Server.ApplicationRegistry.Register`;
- `KIPN.Server.WorldRegistry.RegisterZoneType`, `CreateZoneFromCorners`, `GetZones*`, `GetComputerCapabilities`, `SetZoneActive`, `UpdateZone`;
- `KIPN.UI.CreateScreen`, `SetupScreen`, `SetScreen`, `CreateButton`, `DrawBanner`, `DrawScanlines`, `DrawDivider`, `Theme`;
- `KIPN_ZoneAdminMapUI.Open`;

It does not edit KIPN core files.

## Validation status

The package has passed Lua parse checks, JSON parsing, structure checks, command/handler consistency checks, dependency checks, forbidden-dependency checks, and archive inspection. A Project Zomboid runtime was not present in the build environment, so run a dedicated-server smoke test before production deployment.
