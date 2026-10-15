# Careers: Blacksmith

Mod id `CareersBlacksmith`. Requires `KIPN` and `CareersFramework`; does not
require any other career. See the Careers Framework README for install order
and framework settings. Data lives in `careers.blacksmith`; commands are
`blacksmith.*`.

Like Mechanic's repair line items, a forge order's item lines are **free
text** (an item name + a target quality), not validated against any real
crafting recipe or item catalog -- the mod prices, escrows, and tracks
reputation for the job, while the actual forging is roleplayed in-world by
the shop owner using PZ's real blacksmithing skill. The one deliberate
difference from Mechanic: price direction is inverted. A **higher** requested
quality costs **more** (a quality premium, `BlacksmithQualityPremiumPercent`),
not a discount -- forging a masterwork item costs more material and time than
a rough one.

### Becoming a blacksmith
1. At a KIPN terminal in a **Career Services** zone, open **Blacksmith
   Services → LICENSE** and buy a Blacksmith Business License (a bearer
   paper token).
2. Stand inside the building you want as your shop (No Claim / safehouse /
   existing-storefront checks apply, including against Drug Dealer
   businesses and Mechanic shops), right-click, **Start Your Blacksmith
   Shop**. This auto-draws a `career.blacksmith.shop` capability zone over
   the building and grants you the `careers.blacksmith.owner` permission.
3. Open **Blacksmith Shop** from a terminal inside the shop to fill in the
   profile (its flyer enters loot distribution after the next restart),
   assign containers, and work the queue.

### Business containers
Same three types as Mechanic, same default and same deferred phase:
**Private** (default), **Public** (self-refilling Forge Order form), **For
Sale** (later phase).

### Requesting forged goods (as a customer)
1. Get a **Forge Order** form -- craft one (paper + pen + paperclip) or take
   one from a shop's Public container.
2. Right-click it → **Fill Out Forge Order**. Add one row per item: the
   **Item** name and the **Quality %** to forge it to (default 100). Higher
   quality raises the price.
3. Pick the shop, **Get Quotes**, choose **Fast / Regular / Slow**, **Send**.
   Payment is held in escrow.
4. The shop accepts and messages you. When it presses **Work Order
   Complete**, you're notified -- travel to the shop, inspect the finished
   piece, then **Approve & Pay** in *Blacksmith Services → MY ORDERS*.

An unaccepted order expires and refunds; a shop can also decline outright.

### Threats

Built on the framework's Threats layer (see the Careers Framework README for
pacing and sandbox options).

- **Thieves** sometimes sneak into the forge while you're nearby, grab stock
  and run. Stop them and whatever they carried drops where they fall.
- **Raiders** damage the player-built structures in the building and knock
  condition off the goods in its containers. They also grab some stock and
  fight whoever is there. Structures never drop below 25% health, and goods
  never break outright.
- **Pickups.** Occasionally raiders follow a customer's pickup. That happens
  either when you complete a walk-in order (a server-created work order, so
  no one walks in) at the forge, or when a player approves their order
  inside the shop.

Blacksmith sandbox options are on this mod's own **Careers: Blacksmith** sandbox
page.

## Harness

The offline harness lives in the LilBubbyModTester Workshop folder. Run
`lua tests/careers_blacksmith_checks.lua` from there. It covers the
pricing, sanitization and validation logic in `KIPNCareers_BlacksmithShared.lua`
(60 assertions, no PZ runtime required), and loads the framework and this mod
from their Steam Workshop subscriptions.
