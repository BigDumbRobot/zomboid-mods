-- KIPNCareers_BlacksmithShared.lua
--
-- Shared contract for the Blacksmith profession on the Careers Framework. Loads
-- on both realms after KIPNCareers_Shared. It adds its own wire names / enums
-- under KIPNCareers.Blacksmith and reuses the framework's generic pieces
-- (Economy currency, the career_services zone + capability, the per-owner
-- notification inbox, the ZoneBridge no-claim check, the flyer queue) --
-- same pattern as KIPNCareers_MechanicShared.lua.
--
-- The Blacksmith profession is a parallel career: its own data slice
-- (GetData().careers.blacksmith), its own command handlers, its own two menu
-- programs. It shares no order/business record with Drug Dealer or Mechanic.
--
-- Forge order line items are free-text (an item name + a target quality),
-- exactly like Mechanic's repair line items: the mod prices, escrows, and
-- tracks reputation for the job, but the actual forging is roleplayed
-- in-world by the shop owner using PZ's real blacksmithing skill. The one
-- deliberate behavior difference from Mechanic is the price direction: a
-- **higher** requested quality costs **more** (a quality premium), not a
-- discount -- a masterwork blade costs more material/time than a rough one.

require "KIPNCareers_Shared"

KIPNCareers = KIPNCareers or {}

local Blacksmith = KIPNCareers.Blacksmith or {}
KIPNCareers.Blacksmith = Blacksmith

local Shared = KIPNCareers.Shared

Blacksmith.VERSION = "1.1.0"
Blacksmith.SCHEMA_VERSION = 1
Blacksmith.MODULE = Shared.MODULE        -- "KIPN" -- the host owns the router
Blacksmith.CAREER_ID = "blacksmith"

-- Buying a Blacksmith license reuses the framework's Career Services zone + capability.
Blacksmith.LicenseZoneCapability = Shared.Capabilities.CAREER_SERVICES

-- The storefront auto-zone carries this capability so the Blacksmith Shop
-- menu program only appears at a terminal inside the owner's own shop.
Blacksmith.Capabilities = {
    SHOP = "career.blacksmith.shop",
}

Blacksmith.Permissions = {
    OWNER = "careers.blacksmith.owner",
}

Blacksmith.Applications = {
    SERVICES = "career_blacksmith_services",
    SHOP     = "career_blacksmith_shop",
}

Blacksmith.Items = {
    -- reuse the framework's generic flyer item
    FLYER      = Shared.Items.FLYER,
    LICENSE    = "KIPNCareers.BlacksmithBusinessLicense",
    WORK_ORDER = "KIPNCareers.ForgeOrder",
}

Blacksmith.Commands = {
    SNAPSHOT             = "blacksmith.snapshot",
    SHOP_PROFILE         = "blacksmith.shopProfile",
    BUY_LICENSE          = "blacksmith.buyLicense",
    START_SHOP           = "blacksmith.startShop",
    SAVE_SHOP            = "blacksmith.saveShop",
    SET_CONTAINER_TYPE   = "blacksmith.setContainerType",
    CLEAR_CONTAINER_TYPE = "blacksmith.clearContainerType",
    QUOTE_ORDER          = "blacksmith.quoteOrder",
    SUBMIT_ORDER         = "blacksmith.submitOrder",
    CANCEL_ORDER         = "blacksmith.cancelOrder",
    ACCEPT_ORDER         = "blacksmith.acceptOrder",
    DECLINE_ORDER        = "blacksmith.declineOrder",
    COMPLETE_ORDER       = "blacksmith.completeOrder",
    APPROVE_ORDER        = "blacksmith.approveOrder",
}

Blacksmith.Events = {
    SNAPSHOT     = "kipnBlacksmith.snapshot",
    SHOP_PROFILE = "kipnBlacksmith.shopProfile",
    RESULT       = "kipnBlacksmith.result",
    NOTIFICATION = "kipnBlacksmith.notification",
    QUOTE        = "kipnBlacksmith.quote",
    MESSAGE      = "kipnBlacksmith.message",
}

Blacksmith.Status = {
    SUBMITTED = "SUBMITTED",   -- client posted it, escrow held
    ACCEPTED  = "ACCEPTED",    -- shop accepted, forging in progress
    COMPLETED = "COMPLETED",   -- shop pressed Work Order Complete, awaiting client approval
    CLOSED    = "CLOSED",      -- client approved & paid
    DECLINED  = "DECLINED",
    CANCELLED = "CANCELLED",
    EXPIRED   = "EXPIRED",
}

Blacksmith.ContainerTypes = {
    PRIVATE = "PRIVATE",
    PUBLIC  = "PUBLIC",
    FORSALE = "FORSALE",
}

-- Where a forge order came from. PLAYER orders are funded by a client's
-- escrow; SYSTEM orders are the server's own walk-in customers, so a forge
-- always has work in single player and on a quiet server.
Blacksmith.OrderSources = { PLAYER = "PLAYER", SYSTEM = "SYSTEM" }

Blacksmith.Tiers = { FAST = "fast", REGULAR = "regular", SLOW = "slow" }
Blacksmith.TierOrder = { "fast", "regular", "slow" }

Blacksmith.Defaults = {
    ENABLED = true,
    LICENSE_PRICE = 900,
    STARTING_REPUTATION = 50,
    FAILURE_REP_LOSS = 4,
    SUCCESS_REP_GAIN = 2,
    MAX_ACTIVE_CLIENT_ORDERS = 3,
    MAX_ACTIVE_SHOP_ORDERS = 6,
    ORDER_LISTING_HOURS = 120,
    BASE_ITEM_PRICE = 60,
    QUALITY_PREMIUM_PERCENT = 40,
    FAST_PRICE_MULTIPLIER = 1.6,
    REGULAR_PRICE_MULTIPLIER = 1.0,
    SLOW_PRICE_MULTIPLIER = 0.7,
    FAST_HOURS = 12,
    REGULAR_HOURS = 36,
    SLOW_HOURS = 72,
    MAX_ITEMS_PER_ORDER = 8,
    PUBLIC_FORM_REFILL_MINUTES = 10,
    CONTAINER_DISTANCE = 2,
    SHOP_NAME_MAX = 48,
    TEXT_MAX = 240,
    ITEM_NAME_MAX = 40,
    QUALITY_MIN = 10,
    QUALITY_MAX = 100,
    QUANTITY_MIN = 1,
    QUANTITY_MAX = 8,
    SYSTEM_ORDER_INTERVAL_HOURS = 6,
    MAX_SYSTEM_ORDERS_PER_SHOP = 2,
    SYSTEM_MIN_ITEMS = 1,
    SYSTEM_MAX_ITEMS = 3,
}

-- The server's walk-in customers and what they ask the forge for.
Blacksmith.SystemClients = {
    "A farmer from the valley", "A scavenger with a broken blade", "A gate guard",
    "A traveller passing through", "A settlement cook", "A hunter short on tools",
}
Blacksmith.SystemItems = {
    "Hunting knife", "Axe head", "Nails", "Door hinges", "Cooking pot", "Horseshoes",
    "Machete", "Crowbar", "Hammer head", "Sheet metal", "Chain links", "Spear tip",
}

function Blacksmith.Log(scope, level, message)
    Shared.Log("Blacksmith." .. tostring(scope or "?"), level, message)
end

function Blacksmith.IsOrderActive(status)
    return status == Blacksmith.Status.SUBMITTED
        or status == Blacksmith.Status.ACCEPTED
        or status == Blacksmith.Status.COMPLETED
end

function Blacksmith.IsValidTier(tier)
    return tier == Blacksmith.Tiers.FAST or tier == Blacksmith.Tiers.REGULAR or tier == Blacksmith.Tiers.SLOW
end

function Blacksmith.IsValidContainerType(kind)
    return kind == Blacksmith.ContainerTypes.PRIVATE
        or kind == Blacksmith.ContainerTypes.PUBLIC
        or kind == Blacksmith.ContainerTypes.FORSALE
end

-- Sanitize a client forge-item list into { {itemName=<string>, quantity=<int>, quality=<int>}, ... }.
function Blacksmith.SanitizeForgeItems(rawList, maxItems)
    maxItems = maxItems or Blacksmith.Defaults.MAX_ITEMS_PER_ORDER
    if type(rawList) ~= "table" then return nil, "NO_ITEMS" end
    local cleaned = {}
    for _, row in ipairs(rawList) do
        local itemName = Shared.Trim(row and row.itemName, Blacksmith.Defaults.ITEM_NAME_MAX)
        if itemName ~= "" then
            local quantity = math.floor(tonumber(row and row.quantity) or Blacksmith.Defaults.QUANTITY_MIN)
            quantity = Shared.Clamp(quantity, Blacksmith.Defaults.QUANTITY_MIN, Blacksmith.Defaults.QUANTITY_MAX)
            local quality = math.floor(tonumber(row and row.quality) or Blacksmith.Defaults.QUALITY_MAX)
            quality = Shared.Clamp(quality, Blacksmith.Defaults.QUALITY_MIN, Blacksmith.Defaults.QUALITY_MAX)
            cleaned[#cleaned + 1] = { itemName = itemName, quantity = quantity, quality = quality }
            if #cleaned >= maxItems then break end
        end
    end
    if #cleaned == 0 then return nil, "NO_ITEMS" end
    return cleaned
end

-- Deterministic quote math, shared by client preview and server authority.
-- config carries the resolved sandbox values plus CurrencyItemValue.
--
-- Unlike Mechanic's ComputeQuotes (higher requested quality -> a smaller
-- discount off the base price), Blacksmith's price rises with requested
-- quality: forging a masterwork item costs more material and time than a
-- rough one, so quality is a premium here, not a discount.
function Blacksmith.ComputeQuotes(items, config)
    local baseItem = math.max(1, math.floor(tonumber(config.BaseItemPrice) or Blacksmith.Defaults.BASE_ITEM_PRICE))
    local maxPremium = Shared.Clamp(config.QualityPremiumPercent or Blacksmith.Defaults.QUALITY_PREMIUM_PERCENT, 0, 200) / 100
    local span = Blacksmith.Defaults.QUALITY_MAX - Blacksmith.Defaults.QUALITY_MIN
    local subtotal = 0
    for _, row in ipairs(items or {}) do
        local aboveMinimum = (row.quality - Blacksmith.Defaults.QUALITY_MIN) / math.max(1, span)
        local quantity = math.max(1, math.floor(tonumber(row.quantity) or 1))
        subtotal = subtotal + (baseItem * quantity * (1 + (maxPremium * aboveMinimum)))
    end
    local currencyValue = math.max(1, math.floor(tonumber(config.CurrencyItemValue) or 1))
    local function tierPrice(multiplier)
        local raw = subtotal * (tonumber(multiplier) or 1)
        local rounded = math.floor((raw / currencyValue) + 0.5) * currencyValue
        return math.max(currencyValue, rounded)
    end
    return {
        fast    = tierPrice(config.FastPriceMultiplier or Blacksmith.Defaults.FAST_PRICE_MULTIPLIER),
        regular = tierPrice(config.RegularPriceMultiplier or Blacksmith.Defaults.REGULAR_PRICE_MULTIPLIER),
        slow    = tierPrice(config.SlowPriceMultiplier or Blacksmith.Defaults.SLOW_PRICE_MULTIPLIER),
    }
end

function Blacksmith.TierHours(tier, config)
    if tier == Blacksmith.Tiers.FAST then return math.floor(tonumber(config.FastCompletionHours) or Blacksmith.Defaults.FAST_HOURS) end
    if tier == Blacksmith.Tiers.SLOW then return math.floor(tonumber(config.SlowCompletionHours) or Blacksmith.Defaults.SLOW_HOURS) end
    return math.floor(tonumber(config.RegularCompletionHours) or Blacksmith.Defaults.REGULAR_HOURS)
end

function Blacksmith.TierPrice(quotes, tier)
    if tier == Blacksmith.Tiers.FAST then return quotes.fast end
    if tier == Blacksmith.Tiers.SLOW then return quotes.slow end
    return quotes.regular
end

return Blacksmith
