-- KIPNCareers_DealerThreats.lua
--
-- The Drug Dealer career's threats, on the framework's KIPNCareers.Threats
-- (server authoritative; see KIPNCareers_Threats.lua in Careers Framework).
--
--   * Rival crews (scheduled, random): hit the storefront, go for the drugs
--     and cash in its containers, rough the place up and fight whoever is
--     there. Put them down to get the goods back.
--   * Drop ambushes: when the dealer seals or drops a delivery, a rival crew
--     may be waiting and comes for the dealer. On a two-step drop they go for
--     the drop container too: kill them and put the goods back before
--     Complete Work Order.
--   * The Syndicate (scheduled, tier 2+): a demand for a cut arrives on the
--     business's KIPN page. Leave it in currency in any container inside the
--     storefront before the deadline and they collect it; refuse and enforcers
--     turn up at the storefront, unannounced, while the dealer is there.

if isClient() and not isServer() then return end

require "KIPNCareers_DealerServer"
require "KIPNCareers_NarcoticsAdapter"
require "KIPNCareers_Threats"

local Shared = KIPNCareers.Shared
local Dealer = KIPNCareers.Dealer
local Adapter = KIPNCareers.NarcoticsAdapter
local Economy = KIPNCareers.Economy
local Threats = KIPNCareers.Threats
local Service = KIPNCareers.DealerServer
local Bridge = Service and Service.Bridge

-- The server file's Bridge and the framework's threats layer can be absent
-- (an older copy of either, or a framework too old for the server file).
-- Leave threats off rather than fail the load: the server checks for this
-- module before every call into it.
local function bridgeReady()
    if type(Threats) ~= "table" or type(Threats.Register) ~= "function" or type(Bridge) ~= "table" or type(Bridge.career) ~= "table" then return false end
    for _, name in ipairs({ "state", "save", "notify", "nowHours", "reputationFor", "businessById" }) do
        if type(Bridge[name]) ~= "function" then return false end
    end
    return true
end
if not bridgeReady() then
    Shared.Log("DealerThreats", "Error", "Drug Dealer threats disabled: server bridge or framework threats layer missing")
    return
end

local DealerThreats = KIPNCareers.DealerThreats or {}
KIPNCareers.DealerThreats = DealerThreats

local CAREER_ID = Dealer.CAREER_ID
local DROP_AMBUSH_PERCENT = 30
local ENFORCER_PERCENT = 25 -- per 10-minute check once overdue and the dealer is there
local OVERDUE_GIVE_UP_HOURS = 72

local Demand = { DEMANDED = "DEMANDED", PAID = "PAID", OVERDUE = "OVERDUE", COLLECTED = "COLLECTED", CLOSED = "CLOSED" }

local LINES = {
    rivals = {
        arrive = { "This is our corner now!", "Hit the stash!", "Nobody sells here but us." },
        smash = { "Find the product!", "Wreck the place!", "Take the cash!" },
    },
    ambush = {
        arrive = { "There's the courier!", "Told you they'd show.", "Get the package!" },
        steal = { "Got the package!", "Grab it and go!" },
    },
    enforcers = {
        arrive = { "The Syndicate sends its regards.", "You should've paid.", "Time to collect." },
        smash = { "Take everything.", "Teach 'em a lesson.", "The Syndicate always collects." },
    },
}

local function log(level, message)
    Shared.Log("DealerThreats", level, message)
end

local function isDrugOrCash(item)
    local fullType = item:getFullType()
    if Adapter.Get(fullType) then return true end
    return Economy.IsCurrency(fullType)
end

local function protection()
    local data = Bridge.state()
    if not data then return nil end
    data.protection = type(data.protection) == "table" and data.protection or {}
    return data.protection
end

function DealerThreats.AddHeat(business)
    if business then Threats.AddHeat(CAREER_ID, business, 1) end
end

------------------------------------------------------------
-- RIVAL CREWS / ENFORCERS
------------------------------------------------------------

local function rivals(ctx)
    return Threats.Presets.Raiders(ctx, {
        lines = LINES.rivals, steal = true, filter = isDrugOrCash,
        damageStructures = true, damageItems = false, title = "Rival crew!",
    })
end

local function enforcers(ctx)
    local group = ctx.profile.group
    return Threats.Presets.Raiders(ctx, {
        lines = LINES.enforcers, steal = true, filter = isDrugOrCash,
        damageStructures = true, damageItems = false, title = "The Syndicate came to collect",
        outfits = Threats.Outfits.enforcers, count = ZombRand(group[1], group[2] + 1) + 1,
    })
end

------------------------------------------------------------
-- DROP AMBUSH
------------------------------------------------------------

-- After a successful seal (object nil) or two-step drop (object = the drop
-- container) by `player`.
function DealerThreats.OnDrop(order, player, x, y, z, object)
    local business = Bridge.businessById(order.dealerBusinessId)
    local ctx = business and Threats.RollMoment(CAREER_ID, business, DROP_AMBUSH_PERCENT, player)
    if not ctx then return end
    local function tell(title, body) Bridge.notify(business.ownerKey, title, body, order.id) end
    local opts = {
        center = { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0) }, prey = player, lines = LINES.ambush,
        onResolve = function(incident, outcome)
            if #incident.stolen == 0 then
                if outcome == "defeated" then tell("Ambush beaten", "You put the rival crew down.") end
            elseif outcome == "defeated" then
                tell("Package recovered", "The rivals are down and the goods are where they fell. Put them back in the drop before you complete the work order.")
            else
                tell("Package lost", "The rivals got away with " .. Threats.Describe(incident.lost) .. ". Restock the drop before the deadline.")
            end
        end,
    }
    local container = object and type(object.getContainer) == "function" and object:getContainer() or nil
    if container then
        opts.container = { container = container }
        opts.filter = function(item) return item:getFullType() == order.itemType end
        opts.onStolen = function(_, items)
            tell("They took the drop!", "Rivals grabbed " .. Threats.Describe(items) .. " from the drop. Stop them before they get away.")
        end
    end
    if Threats.Presets.Ambush(ctx, opts) then
        Threats.MarkIncident(ctx)
        tell("Ambush!", "A rival crew was waiting for you at the drop.")
    end
end

------------------------------------------------------------
-- THE SYNDICATE  (protection racket)
------------------------------------------------------------

-- 10-20% of what the dealer delivered over the last week, with a floor that
-- rises with tier.
local function demandAmount(ctx)
    local data = Bridge.state()
    local since = Bridge.nowHours() - 168
    local earned = 0
    for _, order in pairs(data and data.orders or {}) do
        if order.dealerKey == ctx.business.ownerKey and order.status == Dealer.Status.DELIVERED
            and (tonumber(order.deliveredAt) or 0) >= since
        then
            earned = earned + (tonumber(order.payout) or 0)
        end
    end
    local amount = earned * ZombRand(10, 21) / 100
    return Economy.RoundDown(math.max(amount, 25 * ctx.tier))
end

local function shakedown(ctx)
    local demands = protection()
    if not demands then return nil end
    local existing = demands[ctx.business.id]
    if existing and (existing.status == Demand.DEMANDED or existing.status == Demand.OVERDUE) then return nil end
    local amount = demandAmount(ctx)
    local hours = ZombRand(12, 25)
    local demand = {
        businessId = ctx.business.id, ownerKey = ctx.business.ownerKey, amount = amount,
        createdAt = Bridge.nowHours(), dueAt = Bridge.nowHours() + hours, status = Demand.DEMANDED,
    }
    local where = (ctx.business.name and ctx.business.name ~= "") and ctx.business.name or "your storefront"
    demands[ctx.business.id] = demand
    Bridge.save()
    Bridge.notify(ctx.business.ownerKey, "Message from the Syndicate", "Nice business you have. The Syndicate wants "
        .. tostring(amount) .. " within " .. tostring(hours) .. " hours. Leave it in currency in any container inside "
        .. where .. " and we will collect. Don't make us come to you.")
    log("Info", "shakedown business=" .. tostring(ctx.business.id) .. " amount=" .. tostring(amount) .. " hours=" .. tostring(hours))
    return demand
end

local function tickProtection()
    local demands = protection()
    if not demands or not Threats.Settings().Enabled then return end
    local data = Bridge.state()
    local now = Bridge.nowHours()
    local changed = false
    for id, demand in pairs(demands) do
        local business = data.businesses[id]
        if not business or business.active == false then
            if demand.status == Demand.DEMANDED or demand.status == Demand.OVERDUE then demand.status = Demand.CLOSED changed = true end
        elseif demand.status == Demand.DEMANDED then
            local containers = Threats.ContainersIn(business.bounds)
            if #containers > 0 and Economy.CountIn(containers) >= demand.amount and Economy.TakeFrom(containers, demand.amount) then
                demand.status = Demand.PAID
                demand.paidAt = now
                changed = true
                local ctx = Threats.Context(CAREER_ID, business)
                if ctx then Threats.MarkIncident(ctx) end
                Bridge.notify(business.ownerKey, "Protection paid", "The Syndicate collected " .. tostring(demand.amount) .. ". They'll leave you alone for now.")
            elseif now >= demand.dueAt then
                demand.status = Demand.OVERDUE
                changed = true
                Bridge.notify(business.ownerKey, "Payment overdue", "You didn't pay the Syndicate. Watch your back at your storefront.")
            end
        elseif demand.status == Demand.OVERDUE then
            local ctx = Threats.Context(CAREER_ID, business)
            if now >= demand.dueAt + OVERDUE_GIVE_UP_HOURS then
                demand.status = Demand.CLOSED
                changed = true
            elseif ctx and ctx.owner and not Threats.IsBusy(ctx.key) and ZombRand(100) < ENFORCER_PERCENT and enforcers(ctx) then
                demand.status = Demand.COLLECTED
                changed = true
                Threats.MarkIncident(ctx)
            end
        end
    end
    if changed then Bridge.save() end
end

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

Bridge.career:RegisterThreats({
    { id = "rivals", weight = 3, run = rivals },
    { id = "shakedown", weight = 2, minTier = 2, run = shakedown },
})

if Events.EveryTenMinutes then Events.EveryTenMinutes.Add(tickProtection) end

return DealerThreats
