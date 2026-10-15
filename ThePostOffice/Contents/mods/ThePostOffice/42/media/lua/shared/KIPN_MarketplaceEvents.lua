-- KIPN_MarketplaceEvents.lua
--
-- The common translation layer between KIPN and whichever
-- economy/marketplace mod the admin has selected - the DISPLAY
-- half only. Purchase results, parcel listings, and parcel
-- collection are already provider-agnostic (they come from KIPN's
-- own server over KIPN.Shared.ResponseEvents), so they do not need
-- a parallel normalized-event path here. What genuinely differs
-- from provider to provider is how its catalog/balance are read and
-- kept live, which is exactly what these events decouple.
--
-- KIPN_Marketplace.lua (the display screen) never subscribes to a
-- provider mod's own events directly. It only ever listens for the
-- normalized events registered here. Each provider's client adapter
-- (media/lua/client/KIPN_MarketplaceAdapter_*.lua) is responsible
-- for translating that provider's own native events/state into
-- these calls:
--
--     triggerEvent("KIPN_Marketplace_OnCatalogUpdated", items)
--     triggerEvent("KIPN_Marketplace_OnBalanceUpdated", balance, currencyLabel)
--     triggerEvent("KIPN_Marketplace_OnProviderUnavailable", reason)
--
-- Normalized catalog item shape (see KIPN_MarketplaceAdapter.lua):
--
--     {
--         id = <adapter-local string/number>,
--         displayName = <string>,
--         quantity = <number, default 1 if omitted>,
--         unitPrice = <number>,
--         currency = <string>,
--         seller = <string>,
--         description = <string?>,
--         purchasable = <boolean, default true if omitted>,
--         raw = <the provider's own native row, unmodified>,
--     }
--
-- `purchasable = false` marks a row KIPN will DISPLAY but never let
-- the player buy through KIPN (e.g. a real player-to-player
-- listing KIPN's generic ledger-bypass purchase flow cannot settle
-- correctly - see the "NOT EVERY PROVIDER ... IS PURCHASABLE"
-- note in KIPN_Shared.lua's MARKETPLACE PROVIDERS section).
--
-- Loaded from media/lua/shared/ so PZ registers these events on
-- both JVMs before any subscriber code runs, mirroring the pattern
-- used by every economy mod inspected for this integration (see
-- another mod's shared event definitions). Only client code actually
-- triggers them
-- today - the marketplace display is entirely client-driven - but
-- registering on both realms costs nothing and keeps the door open
-- for a future server-side listener (logging, moderation, etc).

local EVENT_NAMES = {
    "KIPN_Marketplace_OnCatalogUpdated",
    "KIPN_Marketplace_OnBalanceUpdated",
    "KIPN_Marketplace_OnProviderUnavailable",
}

for i = 1, #EVENT_NAMES do
    LuaEventManager.AddEvent(EVENT_NAMES[i])
end
