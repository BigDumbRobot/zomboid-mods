-- KIPN_MarketplaceAdapter_GlocServerEconomy.lua
--
-- Marketplace display adapter for "Gloc's Server Economy" (mod.info
-- id `GlocServerEconomy`, client namespace `GSEClient` / `GSE`).
--
-- BALANCE ONLY - NO CATALOG.
--
-- Unlike every other supported provider, GSE has no global,
-- already-synced catalog of sellable items. Every listing lives on a
-- specific in-world merchant object (GSEMerchantPanel) and is only
-- fetched from the server when the player right-clicks that
-- particular object (sendCommand("OpenMerchant", ...) in
-- GSE_Client.lua) - there is no client-side registry of every
-- merchant on the server for KIPN to enumerate remotely. Likewise,
-- the digital ATM account balance is only known once a specific ATM
-- object is opened (sendCommand("OpenATM", ...)) - it is never
-- proactively cached.
--
-- The one thing genuinely available client-side without inventing a
-- network round trip is the player's PHYSICAL CASH ON HAND (GSE's
-- own currency items, Base.Money / Base.MoneyBundle, already sitting
-- in the player's inventory). This is exactly what GSE's own
-- merchant "Buy" button checks against (see cashTotalLocal() in
-- GSE_Client.lua), so it is a faithful analog of "balance" for this
-- provider.
--
-- This adapter is declared `capabilities.catalog = false` in
-- KIPN.Shared.MarketplaceProviderCapabilities (shared/KIPN_Shared.lua)
-- - there genuinely is nothing global to list, so it implements no
-- requestCatalog() at all; KIPN_Marketplace.lua never calls one for a
-- catalog-less provider and instead shows a dedicated "no catalog"
-- message. It reports physical cash on hand as the balance. Nothing
-- is ever purchasable through this adapter (there are no rows to
-- buy), so it is also declared `capabilities.deduct = false` and no
-- server ledger adapter is registered for this provider id - see the
-- "NOT EVERY PROVIDER ... IS PURCHASABLE" note in KIPN_Shared.lua.

if isServer() then
    return
end

require "KIPN_MarketplaceAdapter"

if not KIPN
    or not KIPN.MarketplaceAdapters
then
    error(
        "[KIPN_MarketplaceAdapter_GlocServerEconomy] "
        .. "KIPN_MarketplaceAdapter is not initialized."
    )
end

local PROVIDER_ID =
    KIPN.Shared.MarketplaceProviders.GLOC_SERVER_ECONOMY

--------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------

local function isInstalled()

    return _G.GSEClient ~= nil
        and _G.GSE ~= nil
        and _G.GSE.NETWORK_MODULE == "GlocServerEconomy"
end

-- Mirrors GSE_Client.lua's own cashTotalLocal() / allInventoryItems()
-- - sums Base.Money / Base.MoneyBundle items anywhere in the
-- player's inventory (including nested containers), the same
-- physical cash total GSE's own merchant "Buy" button checks
-- against.
local function physicalCashOnHand(player)

    if not player then
        return 0
    end

    local singleType =
        _G.GSE.CURRENCY_SINGLE
        or "Base.Money"

    local bundleType =
        _G.GSE.CURRENCY_BUNDLE
        or "Base.MoneyBundle"

    local bundleValue =
        tonumber(_G.GSE.CURRENCY_BUNDLE_VALUE)
        or 100

    local total = 0

    local function scan(container, depth)

        if not container
            or depth > 16
        then
            return
        end

        local items =
            container:getItems()

        for i = 0, items:size() - 1 do

            local item =
                items:get(i)

            local fullType =
                item:getFullType()

            if fullType == singleType then

                total = total + 1

            elseif fullType == bundleType then

                total = total + bundleValue
            end

            local ok, inner =
                pcall(
                    function()

                        if item:IsInventoryContainer() then
                            return item:getInventory()
                        end

                        return nil
                    end
                )

            if ok and inner then
                scan(inner, depth + 1)
            end
        end
    end

    local ok, err =
        pcall(
            scan,
            player:getInventory(),
            0
        )

    if not ok then

        KIPN.Logger.Warn(
            "[KIPN_MarketplaceAdapter_GlocServerEconomy] "
            .. "physicalCashOnHand(): "
            .. tostring(err)
        )

        return 0
    end

    return total
end

--------------------------------------------------------------------
-- ADAPTER
--------------------------------------------------------------------

local adapter = {

    id = PROVIDER_ID,

    label = "Gloc's Server Economy (Balance Only)",
}

function adapter.isInstalled()
    return isInstalled()
end

-- No requestCatalog() - this provider is declared
-- `capabilities.catalog = false` (see header note and
-- KIPN.Shared.MarketplaceProviderCapabilities in shared/KIPN_Shared
-- .lua), so KIPN_Marketplace.lua never calls one.

function adapter.getCachedBalance(player)

    if not isInstalled() then
        return 0, "$"
    end

    return physicalCashOnHand(player), "$"
end

KIPN.MarketplaceAdapters.Register(adapter)
