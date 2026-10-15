-- KIPN_MarketplaceAdapter_SellAndShop.lua
--
-- Marketplace display adapter for "Sell & Shop System" (mod.info id
-- `SellAndShop`, client namespace `SellAndShop`).
--
-- This mod has TWO catalogs, combined here with different
-- purchasability:
--
--   SellAndShop.ShopCatalog   - hardcoded static admin shop, always
--                               purchasable (no real seller to
--                               shortchange).
--   SellAndShop.MarketListings - dynamic, server-synced. Rows with
--                               `isSystem == true` are admin/system
--                               stock (purchasable); rows with
--                               `isSystem == false` carry a real
--                               `sellerName` player username and are
--                               marked purchasable = false, same
--                               reasoning as
--                               KIPN_MarketplaceAdapter_PZMarketplaceGES
--                               .lua - see the "NOT EVERY PROVIDER
--                               ... IS PURCHASABLE" note in
--                               KIPN_Shared.lua.
--
-- `SellAndShop` IS a real global table (declared without `local` in
-- every one of that mod's files), so its cached data is directly
-- readable. It does NOT fire any custom triggerEvent when new data
-- lands, though (verified: no triggerEvent/custom Events.<Name> in
-- that mod's client code), so - same fallback as
-- KIPN_MarketplaceAdapter_PZMarketplace.lua - this adapter installs
-- its own independent `Events.OnServerCommand` listener filtered to
-- module `"SellAndShop"` purely to know WHEN to re-normalize and
-- re-fire KIPN's own normalized events.

if isServer() then
    return
end

require "KIPN_MarketplaceAdapter"

if not KIPN
    or not KIPN.MarketplaceAdapters
then
    error(
        "[KIPN_MarketplaceAdapter_SellAndShop] "
        .. "KIPN_MarketplaceAdapter is not initialized."
    )
end

local PROVIDER_ID =
    KIPN.Shared.MarketplaceProviders.SELL_AND_SHOP

local NATIVE_MODULE =
    "SellAndShop"

--------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------

local function isInstalled()

    return _G.SellAndShop ~= nil
        and type(_G.SellAndShop.ShopCatalog) == "table"
end

local function normalizeCatalog()

    local items = {}

    local SAS =
        _G.SellAndShop
        or {}

    ----------------------------------------------------------------
    -- STATIC SHOP CATALOG (always purchasable - admin stock)
    ----------------------------------------------------------------

    for i, row in ipairs(SAS.ShopCatalog or {}) do

        if type(row) == "table"
            and row.id
        then

            items[#items + 1] = {

                id = "catalog:" .. tostring(i),

                displayName = row.name or row.id,

                unitPrice = tonumber(row.cost) or 0,

                currency = "pts",

                seller = "SellAndShop Catalog",

                description = row.description,

                purchasable = true,

                raw = {
                    kind = "catalog",
                    catalogIndex = i,
                    itemFullType = row.id,
                    count = row.count or 1,
                },
            }
        end
    end

    ----------------------------------------------------------------
    -- DYNAMIC MARKET LISTINGS
    ----------------------------------------------------------------

    for _, listing in ipairs(SAS.MarketListings or {}) do

        if type(listing) == "table"
            and listing.id
        then

            local isSystem =
                listing.isSystem == true

            items[#items + 1] = {

                id = "listing:" .. tostring(listing.id),

                displayName =
                    listing.displayName
                    or listing.fullType
                    or "Unknown Item",

                unitPrice = tonumber(listing.price) or 0,

                currency = "pts",

                seller =
                    isSystem
                        and "SellAndShop Market (System)"
                        or (listing.sellerName or "Unknown Seller"),

                description = listing.description,

                -- See header note: real player listings can't be
                -- settled correctly through KIPN's ledger-bypass
                -- purchase flow.
                purchasable = isSystem,

                raw = {
                    kind = "listing",
                    listingId = listing.id,
                    itemFullType = listing.fullType,
                    count = listing.count or 1,
                },
            }
        end
    end

    return items
end

--------------------------------------------------------------------
-- LIVE-UPDATE FORWARDING
--------------------------------------------------------------------

local forwarderInstalled = false

local function ensureForwarder()

    if forwarderInstalled then
        return
    end

    Events.OnServerCommand.Add(
        function(module, command, args)

            if module ~= NATIVE_MODULE then
                return
            end

            if command == "SyncMarketData" then

                triggerEvent(
                    "KIPN_Marketplace_OnCatalogUpdated",
                    normalizeCatalog()
                )

            elseif command == "GetPoints" then

                local points =
                    (args and tonumber(args.points))
                    or (_G.SellAndShop and _G.SellAndShop.Points)
                    or 0

                triggerEvent(
                    "KIPN_Marketplace_OnBalanceUpdated",
                    points,
                    "pts"
                )
            end
        end
    )

    forwarderInstalled = true
end

--------------------------------------------------------------------
-- ADAPTER
--------------------------------------------------------------------

local adapter = {

    id = PROVIDER_ID,

    label = "Sell & Shop System",
}

function adapter.isInstalled()
    return isInstalled()
end

function adapter.requestCatalog(player)

    if not isInstalled() then

        triggerEvent(
            "KIPN_Marketplace_OnProviderUnavailable",
            "PROVIDER_NOT_INSTALLED"
        )

        return
    end

    ensureForwarder()

    sendClientCommand(
        player,
        NATIVE_MODULE,
        "RequestMarketSync",
        {}
    )

    sendClientCommand(
        player,
        NATIVE_MODULE,
        "GetPoints",
        { requestId = 0 }
    )

    triggerEvent(
        "KIPN_Marketplace_OnCatalogUpdated",
        normalizeCatalog()
    )
end

function adapter.getCachedBalance(player)

    if not isInstalled() then
        return 0, "pts"
    end

    ensureForwarder()

    return (_G.SellAndShop.Points or 0), "pts"
end

KIPN.MarketplaceAdapters.Register(adapter)
