-- KIPN_MarketplaceAdapter_PlayerShops.lua
--
-- Read-only adapter for "Player Shops" (mod id `PlayerShops`).
-- Player Shops has no global marketplace database: listings live on
-- physical kiosk objects and are visible only while those squares are
-- loaded. KIPN therefore mirrors the provider's own Nearby Shops
-- radius and displays sell kiosks/vendors found within five tiles.
-- Buy stalls are excluded because they buy FROM the player.
--
-- Purchases remain in Player Shops' own interface. Its authoritative
-- Buy handler transfers real kiosk inventory (or mints vendor stock),
-- moves physical cash, updates listings/revenue, and then inserts the
-- item into the buyer's inventory. There is no pre-delivery hook, so
-- this adapter does not claim escrowCheckout support.

if isServer() then
    return
end

require "KIPN_MarketplaceAdapter"

if not KIPN
    or not KIPN.MarketplaceAdapters
then
    error(
        "[KIPN_MarketplaceAdapter_PlayerShops] "
        .. "KIPN_MarketplaceAdapter is not initialized."
    )
end

local PROVIDER_ID =
    KIPN.Shared.MarketplaceProviders.PLAYER_SHOPS

local NEARBY_RADIUS = 5

local function isInstalled()

    return type(_G.PlayerShops) == "table"
        and type(_G.PlayerShops.findNearbyKiosks) == "function"
        and type(_G.PlayerShops.getListings) == "function"
        and type(_G.PlayerShops.getShopDisplayName) == "function"
        and type(_G.PlayerShops.isBuyStall) == "function"
        and type(_G.PlayerShops.isVendor) == "function"
        and type(_G.PlayerShops.countMoney) == "function"
end

local function displayNameFor(fullType)

    local scriptItem =
        getScriptManager()
        and getScriptManager():FindItem(fullType)

    if scriptItem then
        return scriptItem:getDisplayName()
    end

    return fullType
end

local function shopLabel(kiosk)

    local ok, label =
        pcall(
            function()
                return _G.PlayerShops.getShopDisplayName(kiosk)
            end
        )

    if ok
        and type(label) == "string"
        and label ~= ""
    then
        return label
    end

    return "Nearby Player Shop"
end

local function addRow(items, kiosk, fullType, price, count, shopIndex)

    if type(fullType) ~= "string"
        or fullType == ""
        or tonumber(price) == nil
    then
        return
    end

    items[#items + 1] = {
        id =
            "nearby:"
            .. tostring(shopIndex)
            .. ":"
            .. fullType,
        displayName =
            count
            and count > 1
            and (displayNameFor(fullType) .. " x" .. tostring(count))
            or displayNameFor(fullType),
        unitPrice = tonumber(price) or 0,
        currency = "$",
        seller = shopLabel(kiosk),
        description =
            "Nearby physical kiosk; complete purchase in Player Shops.",
        purchasable = false,
        raw = {
            itemFullType = fullType,
            count = count,
            kiosk = kiosk,
        },
    }
end

local function normalizeCatalog(player)

    local items = {}

    if not player
        or not isInstalled()
    then
        return items
    end

    local ok, nearby =
        pcall(
            _G.PlayerShops.findNearbyKiosks,
            player,
            NEARBY_RADIUS
        )

    if not ok
        or type(nearby) ~= "table"
    then
        return items
    end

    for shopIndex, entry in ipairs(nearby) do

        local kiosk =
            type(entry) == "table"
            and entry.kiosk

        if kiosk
            and not _G.PlayerShops.isBuyStall(kiosk)
        then

            local listings =
                _G.PlayerShops.getListings(kiosk)
                or {}

            if _G.PlayerShops.isVendor(kiosk) then

                for fullType, price in pairs(listings) do
                    addRow(
                        items,
                        kiosk,
                        fullType,
                        price,
                        nil,
                        shopIndex
                    )
                end

            else

                local container =
                    kiosk:getContainer()

                if container then

                    for fullType, price in pairs(listings) do

                        local count =
                            container:getNumberOfItem(
                                fullType,
                                false,
                                true
                            )

                        if count
                            and count > 0
                        then
                            addRow(
                                items,
                                kiosk,
                                fullType,
                                price,
                                count,
                                shopIndex
                            )
                        end
                    end
                end
            end
        end
    end

    table.sort(
        items,
        function(a, b)
            return tostring(a.displayName)
                < tostring(b.displayName)
        end
    )

    return items
end

local adapter = {
    id = PROVIDER_ID,
    label = "Player Shops (Nearby, View Only)",
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

    triggerEvent(
        "KIPN_Marketplace_OnCatalogUpdated",
        normalizeCatalog(player)
    )
end

function adapter.getCachedBalance(player)

    if not player
        or not isInstalled()
    then
        return 0, "$"
    end

    local ok, amount =
        pcall(
            _G.PlayerShops.countMoney,
            player:getInventory()
        )

    if not ok then
        return 0, "$"
    end

    return tonumber(amount) or 0, "$"
end

KIPN.MarketplaceAdapters.Register(adapter)
