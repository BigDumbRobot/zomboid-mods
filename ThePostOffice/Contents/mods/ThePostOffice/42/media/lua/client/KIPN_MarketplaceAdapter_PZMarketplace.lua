-- KIPN_MarketplaceAdapter_PZMarketplace.lua
--
-- Marketplace display adapter for "PZ Marketplace" (workshop mod
-- "MyPZMarketplaceMod", mod.info id `PZMarketplace`, module name
-- `"PZMarketplace"`). Do not confuse with the DIFFERENT mod
-- "PZ Marketplace - Global Economic System" (mod id
-- `PZMarketplaceGES`, its own adapter file,
-- KIPN_MarketplaceAdapter_PZMarketplaceGES.lua).
--
-- This mod runs a daily-rotating ADMIN/SYSTEM stock (6 random items
-- picked from its own `PZMarketplace.ShopPool`, price-jittered, and
-- pushed to every client) - there is no player-to-player listing
-- concept. Rows describe native provider purchasability, but KIPN
-- still presents them read-only because this provider delivers by
-- telling the client to create the item and exposes no escrow hook.
--
-- WHY THIS ADAPTER DOES NOT READ THE PROVIDER'S OWN CLIENT CACHE:
--
-- This mod's client-side cache table (`marketData` in
-- PZMarketplace_Client.lua) is declared with
-- `local marketData = {...}` - genuinely private to that file, not
-- reachable from KIPN's Lua chunk. Project Zomboid still delivers
-- the underlying vanilla `Events.OnServerCommand` fan-out to EVERY
-- registered listener across every active mod, though, so this
-- adapter installs its own independent listener filtered to
-- module `"PZMarketplace"` and parses the same `SyncMarketData`
-- payload that mod's own client parses - it just keeps its own
-- copy instead of reaching into theirs. This is the fallback
-- pattern to reuse whenever a provider's cache turns out to be
-- `local`.

if isServer() then
    return
end

require "KIPN_MarketplaceAdapter"

if not KIPN
    or not KIPN.MarketplaceAdapters
then
    error(
        "[KIPN_MarketplaceAdapter_PZMarketplace] "
        .. "KIPN_MarketplaceAdapter is not initialized."
    )
end

local PROVIDER_ID =
    KIPN.Shared.MarketplaceProviders.PZ_MARKETPLACE

local NATIVE_MODULE =
    "PZMarketplace"

--------------------------------------------------------------------
-- OWN INDEPENDENT CACHE
--------------------------------------------------------------------

local cache = {

    forSale = {},

    balance = 0,
}

--------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------

local function isInstalled()

    return _G.PZMarketplace ~= nil
        and type(_G.PZMarketplace.ShopPool) == "table"
end

local function normalizeCatalog()

    local items = {}

    for i, row in ipairs(cache.forSale or {}) do

        if type(row) == "table"
            and row.type
        then

            items[#items + 1] = {

                id = i,

                displayName = row.name or row.type,

                unitPrice = tonumber(row.price) or 0,

                currency = "$",

                seller = "PZ Marketplace Daily Stock",

                purchasable = true,

                raw = row,
            }
        end
    end

    return items
end

--------------------------------------------------------------------
-- LIVE-UPDATE FORWARDING
--
-- Installed lazily, once. Filters the vanilla OnServerCommand
-- fan-out to this provider's module name so we never need to touch
-- its `local` client cache.
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

            if command ~= "SyncMarketData" then
                return
            end

            args = args or {}

            cache.forSale =
                args.forSale
                or cache.forSale

            cache.balance =
                tonumber(args.balance) or 0

            triggerEvent(
                "KIPN_Marketplace_OnCatalogUpdated",
                normalizeCatalog()
            )

            triggerEvent(
                "KIPN_Marketplace_OnBalanceUpdated",
                cache.balance,
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

    label = "PZ Marketplace",
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
        "RequestSync",
        {}
    )

    triggerEvent(
        "KIPN_Marketplace_OnCatalogUpdated",
        normalizeCatalog()
    )
end

function adapter.getCachedBalance(player)

    if not isInstalled() then
        return 0, "$"
    end

    ensureForwarder()

    return cache.balance or 0, "$"
end

KIPN.MarketplaceAdapters.Register(adapter)
