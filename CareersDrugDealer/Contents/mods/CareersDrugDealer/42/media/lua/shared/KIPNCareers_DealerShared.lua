-- KIPNCareers_DealerShared.lua
--
-- Shared contract for the Drug Dealer profession on the Careers Framework.
-- Loads on both realms after KIPNCareers_Shared. Its wire names and enums
-- live under KIPNCareers.Dealer, the same way the Mechanic keeps its own
-- under KIPNCareers.Mechanic; the framework's KIPNCareers.Shared holds only
-- what every career shares.
--
-- The Drug Dealer's data slice is GetData().careers.drug_dealer. Up to 1.2
-- its tables sat at the root of GetData().careers; KIPNCareers_DealerServer
-- moves them into the slice the first time 1.3 runs.

require "KIPNCareers_Shared"

KIPNCareers = KIPNCareers or {}

local Dealer = KIPNCareers.Dealer or {}
KIPNCareers.Dealer = Dealer

local Shared = KIPNCareers.Shared

Dealer.VERSION = "1.3.0"
Dealer.SCHEMA_VERSION = 3
Dealer.MODULE = Shared.MODULE            -- "KIPN" -- the host owns the router
Dealer.CAREER_ID = "drug_dealer"

-- Present on the auto-created per-business zone that covers a storefront
-- building. Gates the Business Profile menu program to that location.
Dealer.Capabilities = {
    BUSINESS = "career.business",
}

-- Per-identity KIPN permission granted when a storefront is established.
Dealer.Permissions = {
    DEALER = "careers.dealer",
    BUSINESS_OWNER = "careers.business.owner",
}

Dealer.Applications = {
    CAREER_SERVICES = "career_services",
    BUSINESS_PROFILE = "career_business_profile",
}

Dealer.Items = {
    -- reuse the framework's generic flyer item
    FLYER = Shared.Items.FLYER,
    LICENSE = "KIPNCareers.DrugDealerBusinessLicense",
    PARCEL = "KIPNCareers.SealedDrugParcel",
}

-- The inbox and the Career Services zone editor are the framework's own
-- commands (KIPNCareers.Shared.Commands).
Dealer.Commands = {
    SNAPSHOT = "careers.snapshot",
    BUY_LICENSE = "careers.buyLicense",
    START_BUSINESS = "careers.startBusiness",
    SAVE_BUSINESS = "careers.saveBusiness",
    ACCEPT_ORDER = "careers.acceptOrder",
    DECLINE_ORDER = "careers.declineOrder",
    SEAL_DELIVERY = "careers.sealDelivery",
    DROP_DELIVERY = "careers.dropDelivery",
    COMPLETE_WORK_ORDER = "careers.completeWorkOrder",
    BUSINESS_PROFILE = "careers.businessProfile",
    SUBMIT_ORDER = "careers.submitOrder",
    CANCEL_ORDER = "careers.cancelOrder",
    OPEN_PARCEL = "careers.openParcel",
}

Dealer.Events = {
    SNAPSHOT = "kipnCareers.snapshot",
    RESULT = "kipnCareers.result",
    NOTIFICATION = "kipnCareers.notification",
    BUSINESS_PROFILE = "kipnCareers.businessProfile",
}

Dealer.Status = {
    OPEN = "OPEN",
    ACCEPTED = "ACCEPTED",
    -- Items are sitting in a drop container the dealer reported; the business
    -- owner still has to press Complete Work Order.
    FULFILLED = "FULFILLED",
    DELIVERED = "DELIVERED",
    COLLECTED = "COLLECTED",
    DECLINED = "DECLINED",
    EXPIRED = "EXPIRED",
    CANCELLED = "CANCELLED",
}

Dealer.OrderSources = {
    SYSTEM = "system",
    PLAYER = "player",
}

Dealer.Urgencies = {
    STANDARD = "standard",
    URGENT = "urgent",
}

Dealer.Defaults = {
    LICENSE_PRICE = 500,
    STARTING_REPUTATION = 50,
    SYSTEM_DECLINE_REP_LOSS = 1,
    FAILURE_REP_LOSS = 5,
    SUCCESS_REP_GAIN = 2,
    MAX_ACTIVE_BUYER_ORDERS = 3,
    MAX_ACTIVE_DEALER_ORDERS = 3,
    PLAYER_ORDER_LISTING_HOURS = 72,
    STANDARD_MIN_HOURS = 24,
    STANDARD_MAX_HOURS = 72,
    URGENT_MIN_HOURS = 6,
    URGENT_MAX_HOURS = 24,
    SYSTEM_OFFER_INTERVAL_HOURS = 12,
    MAX_SYSTEM_OFFERS = 2,
    PAYOUT_MULTIPLIER = 1.0,
    CONTAINER_INTERACTION_DISTANCE = 3,
    BUSINESS_NAME_MAX = 48,
    TEXT_MAX = 240,
}

-- OPEN and ACCEPTED tie up a dealer/buyer slot. FULFILLED does not: the dealer
-- has already delivered and only the owner's Complete Work Order press is
-- outstanding, so it must not block a new order and must not deadline-expire.
function Dealer.IsDrugOrderStatusActive(status)
    return status == Dealer.Status.OPEN or status == Dealer.Status.ACCEPTED
end

function Dealer.IsWorkOrderComplete(status)
    return status == Dealer.Status.DELIVERED or status == Dealer.Status.COLLECTED
end

return Dealer
