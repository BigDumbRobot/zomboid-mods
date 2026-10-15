-- KIPN_MarketplaceAdapter_MXEconomy.lua
--
-- Marketplace display adapter for "MX - Economy" (mod.info id
-- `MX-Economy`, client namespace `ShopUI`).
--
-- This mod's catalog (`ShopUI.items`) is a hardcoded, static list
-- authored directly in that mod's Lua file - not synced from the
-- server, so there is no request/response round trip to drive here;
-- reading it is a synchronous local read. It also mixes real
-- purchasable items with special non-item action rows (ATM
-- deposit/withdraw, skill-training purchases) identified by id
-- substrings `"atm"`/`"train"` (see that mod's server file,
-- MX-Economy.lua lines ~375-447) - those are filtered out below
-- since they don't correspond to a spawnable item and have no
-- meaning as a KIPN Marketplace/PO Box purchase.
--
-- Balance lives on `player:getModData().cash` - standard vanilla
-- per-player ModData, not a mod-private cache, so it's read directly
-- with no adapter-side caching needed; it is always current.

if isServer() then
    return
end

require "KIPN_MarketplaceAdapter"

if not KIPN
    or not KIPN.MarketplaceAdapters
then
    error(
        "[KIPN_MarketplaceAdapter_MXEconomy] "
        .. "KIPN_MarketplaceAdapter is not initialized."
    )
end

local PROVIDER_ID =
    KIPN.Shared.MarketplaceProviders.MX_ECONOMY

--------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------

local function isInstalled()

    return _G.ShopUI ~= nil
        and type(_G.ShopUI.items) == "table"
end

---Special action rows (ATM ops, skill training) aren't spawnable
---items - see header note.
local function isPurchasableItemRow(row)

    if type(row) ~= "table"
        or type(row.id) ~= "string"
        or row.id == ""
    then
        return false
    end

    local id = string.lower(row.id)

    if string.find(id, "atm", 1, true) then
        return false
    end

    if string.find(id, "train", 1, true) then
        return false
    end

    return true
end

local function normalizeCatalog()

    local items = {}

    local source =
        (_G.ShopUI and _G.ShopUI.items)
        or {}

    for i, row in ipairs(source) do

        if isPurchasableItemRow(row) then

            items[#items + 1] = {

                id = i,

                displayName = row.name or row.id,

                unitPrice = tonumber(row.price) or 0,

                currency = "$",

                seller = "MX Economy Shop",

                purchasable = true,

                raw = row,
            }
        end
    end

    return items
end

--------------------------------------------------------------------
-- ADAPTER
--------------------------------------------------------------------

local adapter = {

    id = PROVIDER_ID,

    label = "MX - Economy",
}

function adapter.isInstalled()
    return isInstalled()
end

function adapter.requestCatalog(_player)

    if not isInstalled() then

        triggerEvent(
            "KIPN_Marketplace_OnProviderUnavailable",
            "PROVIDER_NOT_INSTALLED"
        )

        return
    end

    -- Static hardcoded catalog - no server round trip to wait on.
    triggerEvent(
        "KIPN_Marketplace_OnCatalogUpdated",
        normalizeCatalog()
    )
end

function adapter.getCachedBalance(player)

    if not player then
        return 0, "$"
    end

    local ok, modData =
        pcall(player.getModData, player)

    if not ok
        or type(modData) ~= "table"
    then
        return 0, "$"
    end

    return tonumber(modData.cash) or 0, "$"
end

KIPN.MarketplaceAdapters.Register(adapter)
