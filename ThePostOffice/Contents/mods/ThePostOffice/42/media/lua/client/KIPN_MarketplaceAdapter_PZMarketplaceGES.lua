-- KIPN_MarketplaceAdapter_PZMarketplaceGES.lua
--
-- Marketplace display adapter for "PZ Marketplace - Global Economic
-- System" (mod.info id `PZMarketplaceGES`, client namespace
-- `MarketplaceSystem`). Do not confuse with the DIFFERENT mod
-- "MyPZMarketplaceMod" (mod id `PZMarketplace`, its own adapter
-- file, KIPN_MarketplaceAdapter_PZMarketplace.lua).
--
-- VIEW ONLY - EVERY ROW IS purchasable = false.
--
-- Every listing in this mod carries a real player username as
-- `seller` - there is no admin/system stock concept (verified: no
-- "isSystem"/"System seller" path exists anywhere in
-- MarketplaceCommands.lua). Buying through KIPN's generic
-- ledger-bypass flow (charge the buyer, spawn a fresh item, queue a
-- KIPN parcel) would never pay that seller and would never remove
-- their listing or release their escrowed item - a real fairness
-- bug, not a hypothetical one. So this adapter still displays the
-- full live catalog and balance (useful for price-checking from a
-- KIPN terminal) but marks every row unpurchasable; KIPN_Marketplace
-- .lua refuses to send a purchase for such rows, and no server
-- ledger adapter is registered for this provider id at all - see
-- the "NOT EVERY PROVIDER ... IS PURCHASABLE" note in
-- KIPN_Shared.lua.
--
-- This mod's own client already keeps `MarketplaceSystem.listings`
-- / `.balances` / `.settings` in sync (both fields live on a real
-- GLOBAL table, not `local`), fed by `Events.OnReceiveGlobalModData`
-- for ModData key `"Marketplace"`. This adapter reads that table
-- directly and additionally installs its OWN listener on the same
-- vanilla event (PZ dispatches to every registered listener, so
-- this does not interfere with the provider's own handler) purely
-- to re-fire KIPN's normalized events when new data lands.

if isServer() then
    return
end

require "KIPN_MarketplaceAdapter"

if not KIPN
    or not KIPN.MarketplaceAdapters
then
    error(
        "[KIPN_MarketplaceAdapter_PZMarketplaceGES] "
        .. "KIPN_MarketplaceAdapter is not initialized."
    )
end

local PROVIDER_ID =
    KIPN.Shared.MarketplaceProviders.PZ_MARKETPLACE_GES

local MOD_DATA_KEY =
    "Marketplace"

--------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------

local function isInstalled()

    return _G.MarketplaceSystem ~= nil
        and type(_G.MarketplaceSystem.listings) == "table"
end

local function normalizeCatalog()

    local items = {}

    local source =
        (_G.MarketplaceSystem and _G.MarketplaceSystem.listings)
        or {}

    for _, row in ipairs(source) do

        if type(row) == "table"
            and row.id
        then

            items[#items + 1] = {

                id = row.id,

                displayName =
                    row.name
                    or row.itemType
                    or "Unknown Item",

                unitPrice = tonumber(row.price) or 0,

                currency = "$",

                seller = row.seller or "Unknown Seller",

                -- See header note: real player-to-player listings,
                -- KIPN cannot settle a purchase correctly.
                purchasable = false,

                raw = row,
            }
        end
    end

    return items
end

local function getBalance(player)

    if not isInstalled() then
        return 0
    end

    local ok, balance =
        pcall(_G.MarketplaceSystem.getMyBalance)

    if ok and type(balance) == "number" then
        return balance
    end

    local username =
        player and player:getUsername()

    local balances =
        _G.MarketplaceSystem.balances

    if username
        and type(balances) == "table"
    then
        return balances[username] or 0
    end

    return 0
end

--------------------------------------------------------------------
-- LIVE-UPDATE FORWARDING
--------------------------------------------------------------------

local forwarderInstalled = false

local function ensureForwarder()

    if forwarderInstalled then
        return
    end

    if type(Events) ~= "table"
        or not Events.OnReceiveGlobalModData
    then
        return
    end

    Events.OnReceiveGlobalModData.Add(
        function(key, _modData)

            if key ~= MOD_DATA_KEY then
                return
            end

            triggerEvent(
                "KIPN_Marketplace_OnCatalogUpdated",
                normalizeCatalog()
            )

            triggerEvent(
                "KIPN_Marketplace_OnBalanceUpdated",
                getBalance(getPlayer()),
                "$"
            )
        end
    )

    forwarderInstalled = true
end

--------------------------------------------------------------------
-- ADAPTER
--------------------------------------------------------------------

local adapter = {

    id = PROVIDER_ID,

    label = "PZ Marketplace: Global Economic System (View Only)",
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

    -- Vanilla client API: asks the server to re-broadcast this
    -- ModData key, the same call this mod's own client makes on
    -- OnGameStart.
    if type(ModData) == "table"
        and type(ModData.request) == "function"
    then

        local ok, err =
            pcall(ModData.request, MOD_DATA_KEY)

        if not ok then

            KIPN.Logger.Warn(
                "[KIPN_MarketplaceAdapter_PZMarketplaceGES] "
                .. "ModData.request() failed: "
                .. tostring(err)
            )
        end
    end

    triggerEvent(
        "KIPN_Marketplace_OnCatalogUpdated",
        normalizeCatalog()
    )
end

function adapter.getCachedBalance(player)

    ensureForwarder()

    return getBalance(player), "$"
end

KIPN.MarketplaceAdapters.Register(adapter)
