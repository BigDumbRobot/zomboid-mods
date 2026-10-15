-- KIPN_Wallet.lua
--
-- Small, self-contained inventory-cash charge/refund helper for
-- KIPN claim purchases (currently the Excavation Permit fee).
--
-- KIPN used to route this fee through the optional Marketplace /
-- economy-adapter layer (KIPN_MarketplaceService.ChargePlayer).
-- That layer moved to a separate mod ("The Post Office") when KIPN
-- refocused on ownership claims, so claim fees now use ONLY the
-- player's physical inventory cash -- a server whose economy
-- provider mod is absent can never fail a claim purchase with a
-- phantom "insufficient balance".
--
-- CONTRACT:
--
--   KIPN.Server.Wallet.CountInventoryCurrency(player)
--       -> total, currencyItemType, currencyItemValue
--
--   KIPN.Server.Wallet.Charge(player, amount)
--       -> ok, reasonCode, receipt
--       Removes cash totalling EXACTLY `amount` (whole bills /
--       bundles only -- never a partial charge, never makes change).
--
--   KIPN.Server.Wallet.Refund(player, receipt)
--       -> ok
--       Best-effort: re-grants `receipt.amount` back to the player's
--       main inventory as bundles + singles.
--
-- Only the two vanilla money types are handled (Base.Money = $1,
-- Base.MoneyBundle = $100). The configurable currency item type is
-- read from sandbox (KIPN.ClaimCurrencyItemType / ...Value) but only
-- takes effect for a plain 1:1 single-item currency; bundles are
-- always Base.MoneyBundle at $100.

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

local Wallet = {}
KIPN.Server.Wallet = Wallet

local BUNDLE_TYPE = "Base.MoneyBundle"
local BUNDLE_VALUE = 100

local function log(message)
    if KIPN.Logger and type(KIPN.Logger.Log) == "function" then
        KIPN.Logger.Log("INFO", tostring(message), "Wallet")
    else
        print("[KIPN WALLET] " .. tostring(message))
    end
end

------------------------------------------------------------
-- CURRENCY SETTINGS
------------------------------------------------------------

local function getCurrencySettings()

    local itemType = "Base.Money"
    local itemValue = 1

    if KIPN.Server.Settings
        and type(KIPN.Server.Settings.Get) == "function"
    then
        local configuredType =
            KIPN.Server.Settings.Get("Claim", "ClaimCurrencyItemType", "Base.Money")

        if type(configuredType) == "string" and configuredType ~= "" then
            itemType = configuredType
        end

        local configuredValue =
            tonumber(KIPN.Server.Settings.Get("Claim", "ClaimCurrencyItemValue", 1))

        if configuredValue and configuredValue > 0 then
            itemValue = math.floor(configuredValue)
        end
    end

    return itemType, itemValue
end

------------------------------------------------------------
-- INVENTORY SCAN
------------------------------------------------------------
--
-- Collects every single-currency and bundle item found anywhere
-- under `container`, recursing into nested item containers (bags).
-- Entries are { item = item, container = container } so removal
-- calls Remove() on the container that actually holds each item.
------------------------------------------------------------

local function collectCashRecurse(container, singleType, singles, bundles)

    if not container or type(container.getItems) ~= "function" then
        return
    end

    local items = container:getItems()

    if not items then
        return
    end

    for i = 0, items:size() - 1 do

        local item = items:get(i)

        if item then

            local fullType = item:getFullType()

            if fullType == singleType then
                table.insert(singles, { item = item, container = container })
            elseif fullType == BUNDLE_TYPE then
                table.insert(bundles, { item = item, container = container })
            end

            local nestedOk, nested = pcall(function()
                if type(item.getInventory) == "function" then
                    return item:getInventory()
                end
                return nil
            end)

            if nestedOk and nested then
                collectCashRecurse(nested, singleType, singles, bundles)
            end
        end
    end
end

------------------------------------------------------------
-- COUNT
------------------------------------------------------------

function Wallet.CountInventoryCurrency(player)

    local currencyType, currencyValue = getCurrencySettings()

    local inventory = player and type(player.getInventory) == "function"
        and player:getInventory()

    if not inventory then
        return 0, currencyType, currencyValue
    end

    local singles = {}
    local bundles = {}

    collectCashRecurse(inventory, currencyType, singles, bundles)

    local total = (#singles * currencyValue) + (#bundles * BUNDLE_VALUE)

    return total, currencyType, currencyValue
end

------------------------------------------------------------
-- CHARGE
------------------------------------------------------------

function Wallet.Charge(player, amount)

    amount = math.floor(tonumber(amount) or 0)

    if amount <= 0 then
        return true, nil, { amount = 0 }
    end

    local currencyType, currencyValue = getCurrencySettings()

    local inventory = player and type(player.getInventory) == "function"
        and player:getInventory()

    if not inventory then
        return false, "INVENTORY_UNAVAILABLE"
    end

    local singles = {}
    local bundles = {}

    collectCashRecurse(inventory, currencyType, singles, bundles)

    -- Bundles are worth BUNDLE_VALUE; singles are worth currencyValue.
    -- Use as many bundles as fit without overshooting, then cover the
    -- remainder with singles. Requires an exact fit -- no change.
    local bundleCount = math.min(
        #bundles,
        math.floor(amount / BUNDLE_VALUE)
    )

    local remainder = amount - (bundleCount * BUNDLE_VALUE)

    if remainder % currencyValue ~= 0 then
        return false, "INSUFFICIENT_CURRENCY"
    end

    local singleCount = remainder / currencyValue

    if singleCount > #singles then
        -- Try spending one fewer bundle in case singles can cover more.
        if bundleCount > 0 then
            bundleCount = bundleCount - 1
            remainder = amount - (bundleCount * BUNDLE_VALUE)
            if remainder % currencyValue ~= 0 then
                return false, "INSUFFICIENT_CURRENCY"
            end
            singleCount = remainder / currencyValue
        end

        if singleCount > #singles then
            return false, "INSUFFICIENT_CURRENCY"
        end
    end

    -- ItemContainer:Remove() only updates the server-side container,
    -- so each removal must also be pushed with
    -- sendRemoveItemFromContainer() or the spent cash stays visible
    -- in the player's inventory UI despite being gone server-side.
    for i = 1, bundleCount do
        bundles[i].container:Remove(bundles[i].item)
        if type(sendRemoveItemFromContainer) == "function" then
            pcall(sendRemoveItemFromContainer, bundles[i].container, bundles[i].item)
        end
    end

    for i = 1, singleCount do
        singles[i].container:Remove(singles[i].item)
        if type(sendRemoveItemFromContainer) == "function" then
            pcall(sendRemoveItemFromContainer, singles[i].container, singles[i].item)
        end
    end

    return true, nil, {
        amount = amount,
        currencyType = currencyType,
        currencyValue = currencyValue,
    }
end

------------------------------------------------------------
-- REFUND (best effort)
------------------------------------------------------------

function Wallet.Refund(player, receipt)

    if type(receipt) ~= "table" then
        return false
    end

    local amount = math.floor(tonumber(receipt.amount) or 0)

    if amount <= 0 then
        return true
    end

    local inventory = player and type(player.getInventory) == "function"
        and player:getInventory()

    if not inventory then
        return false
    end

    local currencyType = receipt.currencyType or "Base.Money"
    local currencyValue = tonumber(receipt.currencyValue) or 1

    local bundleCount = math.floor(amount / BUNDLE_VALUE)
    local remainder = amount - (bundleCount * BUNDLE_VALUE)
    local singleCount = 0

    if currencyValue > 0 and remainder % currencyValue == 0 then
        singleCount = remainder / currencyValue
    else
        -- Can't represent the remainder in the configured single
        -- denomination; hand it all back as $1 bills instead.
        bundleCount = 0
        currencyType = "Base.Money"
        singleCount = amount
    end

    local function addItems(itemType, count)
        for _ = 1, count do
            local added = inventory:AddItem(itemType)
            if added and type(sendAddItemToContainer) == "function" then
                pcall(sendAddItemToContainer, inventory, added)
            end
        end
    end

    addItems(BUNDLE_TYPE, bundleCount)
    addItems(currencyType, singleCount)

    return true
end

log("KIPN Wallet loaded.")
