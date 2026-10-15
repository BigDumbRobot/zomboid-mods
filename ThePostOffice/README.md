# The Post Office

PO Box rentals, postal delivery, and marketplace / economy-adapter integration for
Project Zomboid Build 42.

## Status: KIPN add-on (requires KIP Network Terminal)

This mod was **extracted from the [KIP Network (KIPN)](../KIPN) mod**. KIPN has been
refocused on ownership claims (safehouse / excavation / vehicle); the PO Box system and
all marketplace / economy concepts now live here.

It loads as a KIPN add-on (`require=KIPN` in `mod.info`), the same way KIPN: Vehicle
Services and KIPN: Government Services do. Everything KIPN used to provide for it is
registered through KIPN's add-on API at module load:

- commands, response events and the marketplace provider tables
  (`shared/KIPN_PostOfficeShared.lua`),
- the `post_office` and `marketplace` zone types, the `po_box.*` / `marketplace.purchase`
  permissions, the `poBoxes` data domain, the Postal Services and Marketplace menu
  programs, and the `PostOffice` add-on service (`server/KIPN_PostOfficeInit.lua`),
- the `po_box` claim type and its purchase / key-copy flow
  (`server/KIPN_POBoxClaimService.lua`),
- PO Box sizes, prices and claim policy (`server/KIPN_POBoxConfig.lua`),
- the `KIPN.PoBox*` and `KIPN.Marketplace*` sandbox options (`media/sandbox-options.txt`).

The sources still carry the `KIPN_` prefix and the `KIPN.*` namespace. Renaming them is
only needed if this mod is ever made to run without KIPN.

### Files

- `media/lua/server/` — `KIPN_PostOfficeInit`, `KIPN_POBoxConfig`, `KIPN_POBoxService`,
  `KIPN_POBoxClaimService`, `KIPN_MarketplaceService`.
- `media/lua/client/` — `KIPN_PostalServices`, `KIPN_Marketplace`, `KIPN_MarketplaceAdminUI`,
  the `KIPN_POBox*` client bridges, and the `KIPN_MarketplaceAdapter*` provider adapters
  (Gloc Server Economy, MX Economy, PZ Marketplace, PZ Marketplace GES, Player Shops,
  Sell & Shop).
- `media/lua/shared/` — `KIPN_PostOfficeShared`, `KIPN_MarketplaceEvents`, and the
  sandbox option translations.
- `notes/` — the excerpts and pre-split reference files the add-on wiring was rebuilt
  from. Reference only; nothing in here is loaded by the game.
