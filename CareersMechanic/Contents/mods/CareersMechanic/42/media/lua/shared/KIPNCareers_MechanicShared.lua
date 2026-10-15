-- KIPNCareers_MechanicShared.lua
--
-- Shared contract for the Mechanic profession on the Careers Framework. Loads on
-- both realms after KIPNCareers_Shared. It adds its own wire names / enums under
-- KIPNCareers.Mechanic and reuses the mod's generic pieces (Economy currency,
-- the career_services zone + capability, the per-owner notification inbox, the
-- ZoneBridge no-claim check, the flyer queue).
--
-- The Mechanic profession is a parallel career: its own data slice
-- (GetData().careers.mechanic), its own command handlers, its own two menu
-- programs. It shares no order/business record with the Drug Dealer career.

require "KIPNCareers_Shared"

KIPNCareers = KIPNCareers or {}

local Mechanic = KIPNCareers.Mechanic or {}
KIPNCareers.Mechanic = Mechanic

local Shared = KIPNCareers.Shared

Mechanic.VERSION = "0.2.0"
Mechanic.SCHEMA_VERSION = 1
Mechanic.MODULE = Shared.MODULE          -- "KIPN" -- the host owns the router
Mechanic.CAREER_ID = "mechanic"

-- Buying a Mechanic license reuses the mod's Career Services zone + capability.
Mechanic.LicenseZoneCapability = Shared.Capabilities.CAREER_SERVICES

-- The storefront auto-zone carries this capability so the Mechanic Shop menu
-- program only appears at a terminal inside the owner's own shop.
Mechanic.Capabilities = {
    SHOP = "career.mechanic.shop",
}

Mechanic.Permissions = {
    OWNER = "careers.mechanic.owner",
}

Mechanic.Applications = {
    SERVICES = "career_mechanic_services",
    SHOP     = "career_mechanic_shop",
}

Mechanic.Items = {
    -- reuse the mod's generic flyer item
    FLYER      = Shared.Items.FLYER,
    LICENSE    = "KIPNCareers.MechanicBusinessLicense",
    WORK_ORDER = "KIPNCareers.MechanicWorkOrder",
}

Mechanic.Commands = {
    SNAPSHOT             = "mechanic.snapshot",
    SHOP_PROFILE         = "mechanic.shopProfile",
    BUY_LICENSE          = "mechanic.buyLicense",
    START_SHOP           = "mechanic.startShop",
    SAVE_SHOP            = "mechanic.saveShop",
    SET_CONTAINER_TYPE   = "mechanic.setContainerType",
    CLEAR_CONTAINER_TYPE = "mechanic.clearContainerType",
    QUOTE_ORDER          = "mechanic.quoteOrder",
    SUBMIT_ORDER         = "mechanic.submitOrder",
    CANCEL_ORDER         = "mechanic.cancelOrder",
    ACCEPT_ORDER         = "mechanic.acceptOrder",
    DECLINE_ORDER        = "mechanic.declineOrder",
    COMPLETE_ORDER       = "mechanic.completeOrder",
    APPROVE_ORDER        = "mechanic.approveOrder",
}

Mechanic.Events = {
    SNAPSHOT     = "kipnMechanic.snapshot",
    SHOP_PROFILE = "kipnMechanic.shopProfile",
    RESULT       = "kipnMechanic.result",
    NOTIFICATION = "kipnMechanic.notification",
    QUOTE        = "kipnMechanic.quote",
    MESSAGE      = "kipnMechanic.message",
}

Mechanic.Status = {
    SUBMITTED = "SUBMITTED",   -- client posted it, escrow held
    ACCEPTED  = "ACCEPTED",    -- shop accepted, work in progress
    COMPLETED = "COMPLETED",   -- shop pressed Work Order Complete, awaiting client approval
    CLOSED    = "CLOSED",      -- client approved & paid
    DECLINED  = "DECLINED",
    CANCELLED = "CANCELLED",
    EXPIRED   = "EXPIRED",
}

Mechanic.ContainerTypes = {
    PRIVATE = "PRIVATE",
    PUBLIC  = "PUBLIC",
    FORSALE = "FORSALE",
}

-- Where a work order came from. PLAYER orders are funded by a client's
-- escrow; SYSTEM orders are the server's own walk-in customers, so a shop
-- always has work in single player and on a quiet server.
Mechanic.OrderSources = { PLAYER = "PLAYER", SYSTEM = "SYSTEM" }

Mechanic.Tiers = { FAST = "fast", REGULAR = "regular", SLOW = "slow" }
Mechanic.TierOrder = { "fast", "regular", "slow" }

Mechanic.Defaults = {
    ENABLED = true,
    LICENSE_PRICE = 750,
    STARTING_REPUTATION = 50,
    FAILURE_REP_LOSS = 4,
    SUCCESS_REP_GAIN = 2,
    MAX_ACTIVE_CLIENT_ORDERS = 3,
    MAX_ACTIVE_SHOP_ORDERS = 6,
    ORDER_LISTING_HOURS = 120,
    BASE_PART_PRICE = 40,
    LOW_QUALITY_DISCOUNT_PERCENT = 20,
    FAST_PRICE_MULTIPLIER = 1.6,
    REGULAR_PRICE_MULTIPLIER = 1.0,
    SLOW_PRICE_MULTIPLIER = 0.7,
    FAST_HOURS = 12,
    REGULAR_HOURS = 36,
    SLOW_HOURS = 72,
    MAX_REPAIRS_PER_ORDER = 12,
    PUBLIC_FORM_REFILL_MINUTES = 10,
    CONTAINER_DISTANCE = 2,
    SHOP_NAME_MAX = 48,
    TEXT_MAX = 240,
    PART_NAME_MAX = 40,
    QUALITY_MIN = 10,
    QUALITY_MAX = 100,
    SYSTEM_ORDER_INTERVAL_HOURS = 6,
    MAX_SYSTEM_ORDERS_PER_SHOP = 2,
    SYSTEM_MIN_REPAIRS = 1,
    SYSTEM_MAX_REPAIRS = 4,
}

-- The server's walk-in customers and the parts they bring in.
Mechanic.SystemClients = {
    "A stranded driver", "A farmhand from out of town", "A survivor with a limping truck",
    "A nervous first-timer", "A courier on a deadline", "A neighbour two streets over",
}
Mechanic.SystemParts = {
    "Engine", "Battery", "Radiator", "Muffler", "Suspension", "Brakes",
    "Front left tyre", "Rear right tyre", "Windshield", "Door hinge", "Gas tank", "Headlight",
}

function Mechanic.Log(scope, level, message)
    Shared.Log("Mechanic." .. tostring(scope or "?"), level, message)
end

function Mechanic.IsOrderActive(status)
    return status == Mechanic.Status.SUBMITTED
        or status == Mechanic.Status.ACCEPTED
        or status == Mechanic.Status.COMPLETED
end

function Mechanic.IsValidTier(tier)
    return tier == Mechanic.Tiers.FAST or tier == Mechanic.Tiers.REGULAR or tier == Mechanic.Tiers.SLOW
end

function Mechanic.IsValidContainerType(kind)
    return kind == Mechanic.ContainerTypes.PRIVATE
        or kind == Mechanic.ContainerTypes.PUBLIC
        or kind == Mechanic.ContainerTypes.FORSALE
end

-- Sanitize a client repair list into { {part=<string>, quality=<int>}, ... }.
function Mechanic.SanitizeRepairs(rawList, maxRepairs)
    maxRepairs = maxRepairs or Mechanic.Defaults.MAX_REPAIRS_PER_ORDER
    if type(rawList) ~= "table" then return nil, "NO_REPAIRS" end
    local cleaned = {}
    for _, row in ipairs(rawList) do
        local part = Shared.Trim(row and row.part, Mechanic.Defaults.PART_NAME_MAX)
        if part ~= "" then
            local quality = math.floor(tonumber(row and row.quality) or Mechanic.Defaults.QUALITY_MAX)
            quality = Shared.Clamp(quality, Mechanic.Defaults.QUALITY_MIN, Mechanic.Defaults.QUALITY_MAX)
            cleaned[#cleaned + 1] = { part = part, quality = quality }
            if #cleaned >= maxRepairs then break end
        end
    end
    if #cleaned == 0 then return nil, "NO_REPAIRS" end
    return cleaned
end

-- Deterministic quote math, shared by client preview and server authority.
-- config carries the resolved sandbox values plus CurrencyItemValue.
function Mechanic.ComputeQuotes(repairs, config)
    local basePart = math.max(1, math.floor(tonumber(config.BasePartPrice) or Mechanic.Defaults.BASE_PART_PRICE))
    local maxDiscount = Shared.Clamp(config.LowQualityDiscountPercent or Mechanic.Defaults.LOW_QUALITY_DISCOUNT_PERCENT, 0, 90) / 100
    local span = Mechanic.Defaults.QUALITY_MAX - Mechanic.Defaults.QUALITY_MIN
    local subtotal = 0
    for _, row in ipairs(repairs or {}) do
        local shortfall = (Mechanic.Defaults.QUALITY_MAX - row.quality) / math.max(1, span)
        subtotal = subtotal + (basePart * (1 - (maxDiscount * shortfall)))
    end
    local currencyValue = math.max(1, math.floor(tonumber(config.CurrencyItemValue) or 1))
    local function tierPrice(multiplier)
        local raw = subtotal * (tonumber(multiplier) or 1)
        local rounded = math.floor((raw / currencyValue) + 0.5) * currencyValue
        return math.max(currencyValue, rounded)
    end
    return {
        fast    = tierPrice(config.FastPriceMultiplier or Mechanic.Defaults.FAST_PRICE_MULTIPLIER),
        regular = tierPrice(config.RegularPriceMultiplier or Mechanic.Defaults.REGULAR_PRICE_MULTIPLIER),
        slow    = tierPrice(config.SlowPriceMultiplier or Mechanic.Defaults.SLOW_PRICE_MULTIPLIER),
    }
end

function Mechanic.TierHours(tier, config)
    if tier == Mechanic.Tiers.FAST then return math.floor(tonumber(config.FastCompletionHours) or Mechanic.Defaults.FAST_HOURS) end
    if tier == Mechanic.Tiers.SLOW then return math.floor(tonumber(config.SlowCompletionHours) or Mechanic.Defaults.SLOW_HOURS) end
    return math.floor(tonumber(config.RegularCompletionHours) or Mechanic.Defaults.REGULAR_HOURS)
end

function Mechanic.TierPrice(quotes, tier)
    if tier == Mechanic.Tiers.FAST then return quotes.fast end
    if tier == Mechanic.Tiers.SLOW then return quotes.slow end
    return quotes.regular
end

return Mechanic
