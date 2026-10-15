require "KIPNCareers_Shared"

-- KIPNCareers_Economy
--
-- Currency for every Careers Framework career. The admin designates the
-- currency item on the Careers Framework sandbox page
-- (KIPNCareers.CurrencyItemType / KIPNCareers.CurrencyItemValue); the
-- fallback is always Base.Money at value 1. the framework charges, refunds and
-- grants this item directly from player inventory -- it deliberately does NOT
-- route through KIPN's MarketplaceService, so a Careers currency that differs
-- from KIPN's own marketplace currency works correctly.

local Shared = KIPNCareers.Shared
local Economy = KIPNCareers.Economy or {}
KIPNCareers.Economy = Economy

local function log(level, message)
    Shared.Log("Economy", level, message)
end

local function scriptItemExists(fullType)
    local manager = type(getScriptManager) == "function" and getScriptManager() or nil
    if not manager and ScriptManager then manager = ScriptManager.instance end
    if not manager then return true end -- can't check; assume the admin knows
    if type(manager.FindItem) == "function" then
        local ok, item = pcall(manager.FindItem, manager, fullType)
        if ok and item then return true end
    end
    if type(manager.getItem) == "function" then
        local ok, item = pcall(manager.getItem, manager, fullType)
        if ok and item then return true end
    end
    return false
end

-- B42 keeps the surrounding quotes from a `type = string` sandbox option's
-- text, so SandboxVars.KIPNCareers.CurrencyItemType arrives as [["Base.Money"]]
-- (quotes included). Strip one balanced pair of single or double quotes.
local function unquote(text)
    text = tostring(text or "")
    local inner = text:match('^"(.*)"$') or text:match("^'(.*)'$")
    return inner or text
end

-- Resolved once per server session and cached.
function Economy.Settings()
    if Economy._cache then return Economy._cache.itemType, Economy._cache.itemValue end
    local raw = SandboxVars and SandboxVars.KIPNCareers or {}
    local itemType = Shared.Trim(unquote(raw.CurrencyItemType or Shared.Defaults.CURRENCY_ITEM_TYPE), 128)
    if itemType == "" then itemType = Shared.Defaults.CURRENCY_ITEM_TYPE end
    local itemValue = math.max(1, math.floor(tonumber(raw.CurrencyItemValue) or Shared.Defaults.CURRENCY_ITEM_VALUE))
    if itemType ~= Shared.Defaults.CURRENCY_ITEM_TYPE and not scriptItemExists(itemType) then
        log("Warn", "Configured currency item '" .. itemType .. "' not found; falling back to " .. Shared.Defaults.CURRENCY_ITEM_TYPE)
        itemType, itemValue = Shared.Defaults.CURRENCY_ITEM_TYPE, 1
    end
    Economy._cache = { itemType = itemType, itemValue = itemValue }
    log("Info", "Currency item=" .. itemType .. " value=" .. tostring(itemValue))
    return itemType, itemValue
end

function Economy.ItemType()
    local itemType = Economy.Settings()
    return itemType
end

function Economy.ItemValue()
    local _, itemValue = Economy.Settings()
    return itemValue
end

-- Amount must divide the configured item value exactly.
function Economy.IsValidAmount(amount)
    amount = math.floor(tonumber(amount) or 0)
    local _, itemValue = Economy.Settings()
    return amount >= 0 and amount % itemValue == 0
end

-- Round a raw monetary figure down to a valid multiple, with a one-item floor.
function Economy.RoundDown(amount)
    local _, itemValue = Economy.Settings()
    return math.max(itemValue, math.floor((tonumber(amount) or 0) / itemValue) * itemValue)
end

-- Vanilla stacks notes into bundles worth BUNDLE_NOTES notes each, and
-- GrantNow pays large sums in them, so the wallet counts and spends them too.
-- A custom currency item has no bundle: it is counted on its own.
local BUNDLE_TYPE, BUNDLE_NOTES = "Base.MoneyBundle", 100

-- The kinds of item this currency is held in, largest value first.
local function denominations()
    local itemType, itemValue = Economy.Settings()
    if itemType ~= Shared.Defaults.CURRENCY_ITEM_TYPE then
        return { { itemType = itemType, value = itemValue } }
    end
    return {
        { itemType = BUNDLE_TYPE, value = itemValue * BUNDLE_NOTES, bundle = true },
        { itemType = itemType, value = itemValue },
    }
end

local function valueOfType(fullType, kinds)
    for _, kind in ipairs(kinds) do
        if kind.itemType == fullType then return kind.value, kind.bundle == true end
    end
end

local function collectCurrency(container, kinds, output)
    output = output or {}
    if not container or type(container.getItems) ~= "function" then return output end
    local items = container:getItems()
    if not items then return output end
    for index = 0, items:size() - 1 do
        local item = items:get(index)
        if item then
            local value, bundle = valueOfType(item:getFullType(), kinds)
            if value then output[#output + 1] = { item = item, container = container, value = value, bundle = bundle } end
            local ok, nested = pcall(function() return type(item.getInventory) == "function" and item:getInventory() or nil end)
            if ok and nested then collectCurrency(nested, kinds, output) end
        end
    end
    return output
end

-- Count the monetary value the player is carrying in the configured currency,
-- bundles included.
function Economy.Balance(player)
    local inv = player and player:getInventory()
    if not inv then return 0 end
    local total = 0
    for _, entry in ipairs(collectCurrency(inv, denominations(), {})) do total = total + entry.value end
    return total
end

-- Charge `amount` (monetary value) from the player's inventory.
-- Returns ok, reason, receipt. A receipt with .free = true means nothing moved.
-- Single notes are spent first, so a bundle is only broken when the loose
-- notes will not cover the price; the change from a broken bundle goes back
-- into the inventory the bundle came from.
function Economy.Charge(player, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount == 0 then return true, nil, { free = true } end
    local itemType, itemValue = Economy.Settings()
    if amount % itemValue ~= 0 then return false, "AMOUNT_NOT_CURRENCY_MULTIPLE" end
    local inv = player and player:getInventory()
    if not inv then return false, "NO_INVENTORY" end
    local entries = collectCurrency(inv, denominations(), {})
    local available = 0
    for _, entry in ipairs(entries) do available = available + entry.value end
    if available < amount then return false, "INSUFFICIENT_FUNDS" end

    -- Smallest first, so change is only made when it has to be.
    table.sort(entries, function(a, b) return a.value < b.value end)
    local remaining, removed = amount, {}
    for _, entry in ipairs(entries) do
        if remaining <= 0 then break end
        if entry.value <= remaining then
            entry.container:Remove(entry.item)
            removed[#removed + 1] = entry
            remaining = remaining - entry.value
        end
    end
    local change = {}
    if remaining > 0 then
        -- Only a larger item is left: break it and put the change back.
        for _, entry in ipairs(entries) do
            if entry.value > remaining then
                entry.container:Remove(entry.item)
                removed[#removed + 1] = entry
                local owed = entry.value - remaining
                remaining = 0
                for _ = 1, owed / itemValue do
                    local ok, item = pcall(entry.container.AddItem, entry.container, itemType)
                    if ok and item then change[#change + 1] = { item = item, container = entry.container } end
                end
                break
            end
        end
    end
    if remaining > 0 then
        -- Could not make the exact price: put everything back, change included.
        for _, entry in ipairs(change) do pcall(entry.container.Remove, entry.container, entry.item) end
        for _, entry in ipairs(removed) do pcall(entry.container.AddItem, entry.container, entry.item) end
        return false, "INSUFFICIENT_FUNDS"
    end
    log("Info", "Charged player=" .. tostring(player and player:getUsername()) .. " amount=" .. tostring(amount)
        .. " items=" .. tostring(#removed) .. " change=" .. tostring(#change))
    return true, nil, { free = false, itemType = itemType, entries = removed, change = change, amount = amount }
end

-- Puts back exactly what Charge took, including removing the change it made.
function Economy.RefundReceipt(receipt)
    if not receipt or receipt.free then return true end
    local all = true
    for _, entry in ipairs(receipt.change or {}) do
        local ok = pcall(entry.container.Remove, entry.container, entry.item)
        if not ok then all = false end
    end
    for _, entry in ipairs(receipt.entries or {}) do
        local ok, item = pcall(entry.container.AddItem, entry.container, entry.item)
        if not ok or not item then all = false end
    end
    log("Warn", "Refunded amount=" .. tostring(receipt.amount))
    return all
end

-- Put `amount` of monetary value into the player's inventory as currency items.
function Economy.GrantNow(player, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true end
    local itemType, itemValue = Economy.Settings()
    if amount % itemValue ~= 0 then return false end
    local inventory = player and player:getInventory()
    if not inventory then return false end

    -- Bundles keep large payments to a few items; Balance and Charge count
    -- and spend them, so money paid this way is money the player can use.
    local plan = {}
    if itemType == Shared.Defaults.CURRENCY_ITEM_TYPE then
        local bundleValue = itemValue * BUNDLE_NOTES
        plan[#plan + 1] = { itemType = BUNDLE_TYPE, count = math.floor(amount / bundleValue) }
        plan[#plan + 1] = { itemType = itemType, count = (amount % bundleValue) / itemValue }
    else
        plan[#plan + 1] = { itemType = itemType, count = amount / itemValue }
    end

    local granted = {}
    for _, grant in ipairs(plan) do
        for _ = 1, grant.count do
            local ok, item = pcall(inventory.AddItem, inventory, grant.itemType)
            if not ok or not item then
                for _, rollbackItem in ipairs(granted) do pcall(inventory.Remove, inventory, rollbackItem) end
                return false
            end
            granted[#granted + 1] = item
        end
    end
    return true
end

-- Put `amount` of monetary value on the ground at `square` (a dead thief's
-- wallet, a dropped payment), largest denominations first. Returns true if
-- every item was placed.
function Economy.DropAt(square, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true end
    local _, itemValue = Economy.Settings()
    if amount % itemValue ~= 0 then return false end
    if not square or type(square.AddWorldInventoryItem) ~= "function" then return false end
    local all, remaining = true, amount
    for _, kind in ipairs(denominations()) do
        for _ = 1, math.floor(remaining / kind.value) do
            local x, y = ZombRand(20, 81) / 100, ZombRand(20, 81) / 100
            local ok, item = pcall(square.AddWorldInventoryItem, square, kind.itemType, x, y, 0)
            if not ok or not item then all = false end
        end
        remaining = remaining % kind.value
    end
    log("Info", "DropAt amount=" .. tostring(amount) .. " complete=" .. tostring(all))
    return all
end

-- Monetary value of the currency (bundles included) across a list of
-- containers ({ { container = ItemContainer }, ... }).
function Economy.CountIn(entries)
    local kinds, total = denominations(), 0
    for _, entry in ipairs(entries or {}) do
        for _, found in ipairs(collectCurrency(entry.container, kinds, {})) do total = total + found.value end
    end
    return total
end

-- Remove exactly `amount` from the containers (the Careers shakedown), the
-- same way Charge spends: notes first, breaking a bundle only when needed
-- and leaving the change where the bundle was. Every change is synced to
-- clients. Removes nothing if there isn't enough.
function Economy.TakeFrom(entries, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true end
    local itemType, itemValue = Economy.Settings()
    if amount % itemValue ~= 0 then return false, "AMOUNT_NOT_CURRENCY_MULTIPLE" end
    local found, available = {}, 0
    for _, entry in ipairs(entries or {}) do collectCurrency(entry.container, denominations(), found) end
    for _, entry in ipairs(found) do available = available + entry.value end
    if available < amount then return false, "INSUFFICIENT_FUNDS" end

    local sync = isServer()
    local function take(entry)
        entry.container:Remove(entry.item)
        if sync and type(sendRemoveItemFromContainer) == "function" then pcall(sendRemoveItemFromContainer, entry.container, entry.item) end
    end
    table.sort(found, function(a, b) return a.value < b.value end)
    local remaining, removed = amount, 0
    for _, entry in ipairs(found) do
        if remaining <= 0 then break end
        if entry.value <= remaining then
            take(entry)
            removed = removed + 1
            remaining = remaining - entry.value
        end
    end
    if remaining > 0 then
        for _, entry in ipairs(found) do
            if entry.value > remaining and entry.item:getContainer() == entry.container then
                take(entry)
                removed = removed + 1
                for _ = 1, (entry.value - remaining) / itemValue do
                    local ok, item = pcall(entry.container.AddItem, entry.container, itemType)
                    if ok and item and sync and type(sendAddItemToContainer) == "function" then
                        pcall(sendAddItemToContainer, entry.container, item)
                    end
                end
                remaining = 0
                break
            end
        end
    end
    log("Info", "TakeFrom amount=" .. tostring(amount) .. " items=" .. tostring(removed))
    return remaining == 0
end

-- True for an item this currency is held in (bundles included for the
-- default currency), so a career never has to name a money item itself.
function Economy.IsCurrency(fullType)
    return valueOfType(fullType, denominations()) ~= nil
end

-- A configured price as one the currency can pay: rounded up to the next
-- multiple of the item value. Zero stays zero, so a free license stays free.
function Economy.Price(amount)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    local _, itemValue = Economy.Settings()
    return math.ceil(amount / itemValue) * itemValue
end

------------------------------------------------------------
-- PENDING PAYMENTS
--
-- Money owed to someone who may be offline. A ledger is a plain
-- { [ownerKey] = amount } table the caller keeps in its own saved data;
-- Credit adds to it and Settle pays it into the player's inventory.
------------------------------------------------------------

function Economy.Pending(ledger, ownerKey)
    return math.floor(tonumber(type(ledger) == "table" and ledger[ownerKey]) or 0)
end

function Economy.Credit(ledger, ownerKey, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true end
    if type(ledger) ~= "table" or not ownerKey then return false end
    ledger[ownerKey] = Economy.Pending(ledger, ownerKey) + amount
    return true
end

-- Returns ok, amount paid. Nothing owed is a success that pays 0.
function Economy.Settle(ledger, ownerKey, player)
    local amount = Economy.Pending(ledger, ownerKey)
    if amount <= 0 then return true, 0 end
    if not Economy.GrantNow(player, amount) then return false, 0 end
    ledger[ownerKey] = nil
    return true, amount
end

return Economy
