# Careers: Mechanic

Mod id `CareersMechanic`. Requires `KIPN` and `CareersFramework`; does not
require any other career. See the Careers Framework README for install order
and framework settings. Data lives in `careers.mechanic`; commands are
`mechanic.*`.

### Becoming a mechanic
1. At a KIPN terminal in a **Career Services** zone, open **Mechanic Services →
   LICENSE** and buy a Mechanic Business License (a bearer paper token).
2. Stand inside the building you want as your shop (No Claim / safehouse /
   existing-storefront checks apply), right-click, **Start Your Mechanic Shop**.
   This auto-draws a `career.mechanic.shop` capability zone over the building and
   grants you the `careers.mechanic.owner` permission — the same safehouse-like
   pattern the Drug Dealer storefront uses.
3. Open **Mechanic Shop** from a terminal inside the shop to fill in the profile
   (its flyer enters loot distribution after the next restart), assign containers,
   and work the queue.

### Business containers
All shop containers are **Private** by default. Right-click a container inside the
shop building → **Mechanic Business: Container** to set it:

| Type | Behaviour |
|---|---|
| **Private** | Default. (Non-owner visibility enforcement is a later phase.) |
| **Public** | Kept topped up to one self-refilling Mechanic Work Order form; also where an owner leaves promotional items. |
| **For Sale** | Later phase: price an item and let customers Buy Now. |

Containers are never generated — you assign the building's existing ones (or build
new ones and assign those).

### Requesting a repair (as a customer)
1. Get a **Mechanic Work Order** form — craft one (paper + pen + paperclip) or
   take one from a shop's Public container.
2. Right-click it → **Fill Out Mechanic Work Order**. Add one row per repair: the
   **Part** name and the **Quality %** to bring it to (default 100). Lower quality
   lowers the price slightly.
3. Pick the shop, **Get Quotes**, choose **Fast / Regular / Slow**, **Send**.
   Payment is held in escrow.
4. The shop accepts and messages you. When it presses **Work Order Complete**,
   you're notified — travel to the shop, inspect, then **Approve & Pay** in
   *Mechanic Services → MY ORDERS*.

An unaccepted order expires and refunds; a shop can also decline outright.

### Threats

Built on the framework's Threats layer (see the Careers Framework README for
pacing and sandbox options).

- **Thieves** sometimes sneak into the shop while you're nearby. They grab
  parts and tools from the building's containers and run. Stop them and
  whatever they carried drops where they fall.
- **Walk-in customers** are the server-created work orders on your shop's
  KIPN page. They never walk in. Each has a hidden mood that shows when you
  press **Work Order Complete**:
  - Most pay in full and sometimes tip.
  - Some complain and haggle the price down.
  - Some refuse to pay and send a crew to the shop. One of the crew carries
    the money owed, and it drops where they fall. This only happens while
    you're at the shop and outside the grace and calm windows.

### Deferred to later phases
For Sale "Buy Now"; real vehicle part condition reads/writes and client-side
inspection; server-generated vehicle work orders (restore a found unclaimed car to
100%, map marker until complete, deep-wound penalty for an incorrect completion);
private-container visibility enforcement; the PvP block and melee-only Dispute
Resolution inside shop zones.

Mechanic sandbox options are on this mod's own **Careers: Mechanic** sandbox
page. The "MY BUSINESS" tab in KIPN Announcements is provided by Careers: Drug
Dealer; a mechanic sees notifications in Mechanic Services → HOME.
