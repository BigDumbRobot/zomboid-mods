-- KIPN_PostOfficeShared.lua
--
-- Shared (both realms) constants for The Post Office. These lived in
-- KIPN's shared/KIPN_Shared.lua until the postal and marketplace
-- systems were split out of KIPN; they are registered here through
-- KIPN's add-on API so every Post Office file can keep reading them
-- from KIPN.Shared.

require "KIPN_Shared"

KIPN = KIPN or {}
KIPN.Shared = KIPN.Shared or {}

if type(KIPN.Shared.RegisterCommand) ~= "function"
    or type(KIPN.Shared.RegisterResponseEvent) ~= "function"
then
    print(
        "[KIPN POST OFFICE] ERROR: KIPN.Shared add-on API unavailable; "
        .. "The Post Office requires KIP Network Terminal."
    )
    return
end

--------------------------------------------------------------------
-- COMMANDS  (client -> server)
--------------------------------------------------------------------

local COMMANDS = {
    GET_PO_BOXES = "getPOBoxes",
    BUY_PO_BOX = "buyPOBox",
    COPY_PO_BOX_KEY = "copyPOBoxKey",
    GET_MY_POBOX_KEYS = "getMyPOBoxKeys",
    PURCHASE_MARKETPLACE_ITEM = "purchaseMarketplaceItem",
    GET_KIPN_MARKETPLACE_ITEMS = "getKIPNMarketplaceItems",
    PURCHASE_KIPN_MARKETPLACE_ITEM = "purchaseKIPNMarketplaceItem",
    SAVE_KIPN_MARKETPLACE_ITEM = "saveKIPNMarketplaceItem",
    REMOVE_KIPN_MARKETPLACE_ITEM = "removeKIPNMarketplaceItem",
    GET_PARCELS = "getParcels",
    COLLECT_PARCEL = "collectParcel",
}

for key, wireName in pairs(COMMANDS) do
    KIPN.Shared.RegisterCommand(key, wireName)
end

--------------------------------------------------------------------
-- RESPONSE EVENTS  (server -> client)
--------------------------------------------------------------------

local RESPONSE_EVENTS = {
    PO_BOXES_DATA = "poBoxesData",
    MY_POBOX_KEYS_DATA = "myPOBoxKeysData",
    PO_BOX_KEY_COPY_RESULT = "poBoxKeyCopyResult",
    PURCHASE_RESULT = "purchaseResult",
    MARKETPLACE_PURCHASE_RESULT = "marketplacePurchaseResult",
    KIPN_MARKETPLACE_ITEMS_DATA = "kipnMarketplaceItemsData",
    KIPN_MARKETPLACE_ADMIN_RESULT = "kipnMarketplaceAdminResult",
    PARCELS_DATA = "parcelsData",
    PARCEL_COLLECTED = "parcelCollected",
}

for key, wireName in pairs(RESPONSE_EVENTS) do
    KIPN.Shared.RegisterResponseEvent(key, wireName)
end

--------------------------------------------------------------------
-- MARKETPLACE PROVIDERS
--
-- KIPN's internal admin shop is independent of external providers.
-- This section describes only the optional provider projection an
-- admin selects via KIPN.MarketplaceProvider. External catalogs stay
-- read-only unless the provider exposes an escrow-safe integration.
--
-- IMPORTANT: inventory insertion is not a marketplace API. Most of
-- the providers inspected ultimately call ItemContainer:AddItem()
-- (usually followed by sendAddItemToContainer()), but globally
-- replacing that primitive would also intercept crafting, loot,
-- admin grants, withdrawals, and unrelated mods. KIPN therefore
-- never monkeypatches ItemContainer. A provider must deliberately
-- hand an already-authorized purchase to KIPN's server escrow API.
--
-- KIPN.Shared.MarketplaceProviderOrder is the single ordered list
-- both realms use to translate the sandbox option's numeric enum
-- value into a stable provider id string:
--
--     index 1 -> MarketplaceProviderOrder[1] -> NONE
--     index 2 -> MarketplaceProviderOrder[2] -> PZ_MARKETPLACE
--     ...
--
-- This list's order MUST match:
--
--   * media/sandbox-options.txt   -> option KIPN.MarketplaceProvider
--   * media/lua/shared/Translate/EN/Sandbox.json
--        -> Sandbox_KIPN_MarketplaceProvider_option<N>
--
-- TO ADD A NEW COMPATIBLE PROVIDER:
--
--   1. Add its id constant + append it to MarketplaceProviderOrder
--      below.
--   2. Add a matching optionN value to sandbox-options.txt
--      (bump numValues) and Sandbox.json.
--   3. Ship a client display adapter that registers itself with
--      KIPN.MarketplaceAdapters (see
--      media/lua/client/KIPN_MarketplaceAdapter.lua for the
--      contract, and KIPN_MarketplaceAdapter_PZMarketplace.lua for
--      a worked example).
--   4. If other KIPN services may charge provider currency, ship a
--      server ledger adapter. This does not authorize marketplace
--      checkout.
--   5. For PO Box fulfillment, modify/cooperate with the provider's
--      authoritative purchase handler so it suppresses direct
--      delivery and calls MarketplaceService.QueueExternalDelivery.
--
-- KIPN_Marketplace.lua and KIPN_PostalServices.lua never need to
-- change - both talk only to the adapter registries, never to a
-- provider mod directly.
--
-- CHECKOUT IS FAIL-CLOSED:
--
-- Every supplied provider is currently read-only in the KIPN viewer.
-- Some perform client-side delivery, some insert items directly on
-- the server, one has a timed delivery queue, and several move real
-- serialized stock. None exposes one common cancellable pre-delivery
-- hook. `escrowCheckout` therefore remains false until a provider-
-- specific integration performs native settlement and explicitly
-- hands the resulting fulfillment to KIPN.
--------------------------------------------------------------------

KIPN.Shared.MarketplaceProviders = {

    NONE =
        "None",

    -- MyPZMarketplaceMod - daily-rotating admin/system stock only
    -- (no player-to-player listings), id from that mod's mod.info.
    PZ_MARKETPLACE =
        "PZMarketplace",

    -- "PZ Marketplace - Global Economic System" - every listing is
    -- player-to-player (real seller username, no system stock
    -- concept), so this provider is VIEW ONLY (see note above).
    PZ_MARKETPLACE_GES =
        "PZMarketplaceGES",

    MX_ECONOMY =
        "MX-Economy",

    SELL_AND_SHOP =
        "SellAndShop",

    -- "Gloc's Server Economy" - has no global catalog to read (every
    -- listing lives on a specific in-world merchant object, fetched
    -- only when the player interacts with it) so this provider is
    -- BALANCE ONLY: catalog is always empty, balance reports the
    -- player's physical cash on hand. See
    -- KIPN_MarketplaceAdapter_GlocServerEconomy.lua for the full
    -- rationale.
    GLOC_SERVER_ECONOMY =
        "GlocServerEconomy",

    -- Physical, location-bound kiosk/vendor shops. Only nearby,
    -- currently loaded kiosks can be enumerated by the client.
    PLAYER_SHOPS =
        "PlayerShops",
}

KIPN.Shared.MarketplaceProviderOrder = {

    [1] =
        KIPN.Shared.MarketplaceProviders.NONE,

    [2] =
        KIPN.Shared.MarketplaceProviders.PZ_MARKETPLACE,

    [3] =
        KIPN.Shared.MarketplaceProviders.PZ_MARKETPLACE_GES,

    [4] =
        KIPN.Shared.MarketplaceProviders.MX_ECONOMY,

    [5] =
        KIPN.Shared.MarketplaceProviders.SELL_AND_SHOP,

    [6] =
        KIPN.Shared.MarketplaceProviders.GLOC_SERVER_ECONOMY,

    [7] =
        KIPN.Shared.MarketplaceProviders.PLAYER_SHOPS,
}

--------------------------------------------------------------------
-- OBSERVED PROVIDER DELIVERY MODES
--
-- These describe how the supplied/reference versions fulfill a
-- successful purchase. They are diagnostics/documentation, not
-- hooks. Only EXPLICIT_KIPN_ESCROW is safe for a KIPN checkout.
--------------------------------------------------------------------

KIPN.Shared.MarketplaceDeliveryModes = {
    NONE = "NONE",
    SERVER_INVENTORY = "SERVER_INVENTORY",
    CLIENT_INVENTORY = "CLIENT_INVENTORY",
    SERVER_INVENTORY_OR_WORLD = "SERVER_INVENTORY_OR_WORLD",
    PROVIDER_DELIVERY_QUEUE = "PROVIDER_DELIVERY_QUEUE",
    SERVER_CONTAINER_TRANSFER = "SERVER_CONTAINER_TRANSFER",
    EXPLICIT_KIPN_ESCROW = "EXPLICIT_KIPN_ESCROW",
}

--------------------------------------------------------------------
-- MARKETPLACE PROVIDER CAPABILITIES
--
-- Single declared source of truth for what each provider id can do,
-- read by BOTH realms:
--
--   * client/KIPN_MarketplaceAdapter.lua's Register() uses `catalog`
--     / `balance` to decide which adapter fields are required, and
--     attaches this table to the adapter as `adapter.capabilities`.
--   * server/KIPN_MarketplaceService.lua's RegisterLedger() uses
--     `deduct` to refuse registering a ledger for a provider not
--     declared usable for generic KIPN service fees here.
--
-- `deduct = true` means "a server ledger MAY exist for generic KIPN
-- service fees". It does NOT authorize marketplace checkout.
-- `escrowCheckout = true` is the separate, fail-closed declaration
-- that a provider has an authoritative purchase path which hands
-- fulfillment to KIPN without direct delivery. No inspected provider
-- exposes that contract yet.
--
-- A row's `purchasable` flag is still useful to describe native
-- provider behavior, but KIPN also requires provider-level
-- `escrowCheckout = true` before presenting any checkout action.
--------------------------------------------------------------------

KIPN.Shared.MarketplaceProviderCapabilities = {

    [KIPN.Shared.MarketplaceProviders.NONE] = {
        catalog = false,
        balance = false,
        deduct = false,
        escrowCheckout = false,
        deliveryMode = KIPN.Shared.MarketplaceDeliveryModes.NONE,
        balanceIsPhysicalInventory = false,
    },

    [KIPN.Shared.MarketplaceProviders.PZ_MARKETPLACE] = {
        catalog = true,
        balance = true,
        deduct = true,
        escrowCheckout = false,
        deliveryMode = KIPN.Shared.MarketplaceDeliveryModes.CLIENT_INVENTORY,
        balanceIsPhysicalInventory = false,
    },

    [KIPN.Shared.MarketplaceProviders.PZ_MARKETPLACE_GES] = {
        catalog = true,
        balance = true,
        deduct = false,
        escrowCheckout = false,
        deliveryMode = KIPN.Shared.MarketplaceDeliveryModes.PROVIDER_DELIVERY_QUEUE,
        balanceIsPhysicalInventory = false,
    },

    [KIPN.Shared.MarketplaceProviders.MX_ECONOMY] = {
        catalog = true,
        balance = true,
        deduct = true,
        escrowCheckout = false,
        deliveryMode = KIPN.Shared.MarketplaceDeliveryModes.SERVER_INVENTORY_OR_WORLD,
        balanceIsPhysicalInventory = false,
    },

    [KIPN.Shared.MarketplaceProviders.SELL_AND_SHOP] = {
        catalog = true,
        balance = true,
        deduct = true,
        escrowCheckout = false,
        deliveryMode = KIPN.Shared.MarketplaceDeliveryModes.SERVER_INVENTORY,
        balanceIsPhysicalInventory = false,
    },

    -- getCachedBalance() for this provider already IS the player's
    -- physical inventory cash (see KIPN_MarketplaceAdapter_
    -- GlocServerEconomy.lua's physicalCashOnHand()) - flagged so
    -- display code never adds inventory currency a second time.
    [KIPN.Shared.MarketplaceProviders.GLOC_SERVER_ECONOMY] = {
        catalog = false,
        balance = true,
        deduct = false,
        escrowCheckout = false,
        deliveryMode = KIPN.Shared.MarketplaceDeliveryModes.SERVER_INVENTORY,
        balanceIsPhysicalInventory = true,
    },

    -- getCachedBalance() for this provider already IS the player's
    -- physical inventory cash (see KIPN_MarketplaceAdapter_
    -- PlayerShops.lua, which delegates to PlayerShops.countMoney()
    -- on the live inventory) - flagged so display code never adds
    -- inventory currency a second time.
    [KIPN.Shared.MarketplaceProviders.PLAYER_SHOPS] = {
        catalog = true,
        balance = true,
        deduct = false,
        escrowCheckout = false,
        deliveryMode = KIPN.Shared.MarketplaceDeliveryModes.SERVER_CONTAINER_TRANSFER,
        balanceIsPhysicalInventory = true,
    },
}

print("[KIPN] Post Office shared constants loaded")
