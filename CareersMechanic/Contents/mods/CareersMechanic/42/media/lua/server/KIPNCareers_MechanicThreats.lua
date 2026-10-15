-- KIPNCareers_MechanicThreats.lua
--
-- The Mechanic career's threats, on the framework's KIPNCareers.Threats
-- (server authoritative; see KIPNCareers_Threats.lua in Careers Framework).
--
--   * Thieves (scheduled, random): sneak into the shop, grab parts and tools
--     from the building's containers and run. Kill them to get it back.
--   * Walk-in customers are the server-created work orders on the shop's
--     KIPN page; they never walk in. Each one has a hidden mood, rolled when
--     the owner presses Work Order Complete and reported with the payment:
--       calm    -- pays in full, sometimes tips;
--       grumble -- complains and haggles the price down;
--       hostile -- refuses to pay and sends a crew to the shop. One of them
--                  carries the money owed; it drops where they fall.
--     A hostile customer only happens while the owner is at the shop and the
--     business is out of its grace / calm window.

if isClient() and not isServer() then return end

require "KIPNCareers_MechanicServer"
require "KIPNCareers_Threats"

local Mechanic = KIPNCareers.Mechanic
local Economy = KIPNCareers.Economy
local Threats = KIPNCareers.Threats
local Service = KIPNCareers.MechanicServer
local Bridge = Service and Service.Bridge

-- The server file's Bridge and the framework's threats layer can be absent
-- (an older copy of either, or a framework too old for the server file).
-- Leave threats off rather than fail the load: the server checks for this
-- module before every call into it.
local function bridgeReady()
    if type(Threats) ~= "table" or type(Threats.Register) ~= "function" or type(Bridge) ~= "table" or type(Bridge.career) ~= "table" then return false end
    for _, name in ipairs({ "state", "save", "notify", "reputationFor", "credit", "settlePending", "onlinePlayerByIdentity" }) do
        if type(Bridge[name]) ~= "function" then return false end
    end
    return true
end
if not bridgeReady() then
    Mechanic.Log("Threats", "Error", "Mechanic threats disabled: server bridge or framework threats layer missing")
    return
end

local MechanicThreats = KIPNCareers.MechanicThreats or {}
KIPNCareers.MechanicThreats = MechanicThreats

local CAREER_ID = Bridge.career.id

local LINES = {
    thieves = {
        arrive = { "Shop's quiet. Let's go.", "In and out, nice and quick." },
        steal = { "Grab the tools!", "Parts sell good. Take 'em!", "Fill the bag!" },
        flee = { "Go, go, go!", "Somebody's coming, move!" },
        caught = { "We've been made!", "Get off me!" },
        nothing = { "Place is picked clean." },
    },
    calm = { "Runs like new.", "Good work, appreciate it.", "Knew I could count on you." },
    grumble = {
        "Took you long enough.", "That's it? I expected better for the price.",
        "Still hear a rattle. I'm not paying full price.", "You scratched the paint. I'm knocking some off.",
    },
    hostile = {
        "You call this a repair? I'm not paying for this junk.",
        "You broke more than you fixed. My boys will be over to discuss it.",
        "Ripped me off. Expect company.",
    },
    crew = {
        arrive = { "That's the grease monkey!", "Boss says you owe him an apology.", "Get 'em!" },
    },
}

local function log(level, message)
    Mechanic.Log("Threats", level, message)
end

local function pick(list)
    return list[ZombRand(#list) + 1]
end

function MechanicThreats.AddHeat(shop)
    Threats.AddHeat(CAREER_ID, shop, 1)
end

-- The customer's crew comes for the owner, carrying the unpaid money.
local function sendCrew(ctx, order, player)
    local client = tostring(order.clientName or "The customer")
    local function tell(title, body) Bridge.notify(order.shopKey, title, body, order.id) end
    local incident = Threats.Presets.Ambush(ctx, {
        prey = player, wallet = order.payout, lines = LINES.crew,
        onResolve = function(incident)
            if (incident.walletDropped or 0) > 0 then
                order.escrowState = "RECOVERED"
                tell("Payment recovered", "You dealt with " .. client .. "'s crew. The " .. tostring(order.payout)
                    .. " they owed is on the ground where the carrier fell.")
            else
                order.escrowState = "UNPAID"
                tell("Never paid", client .. "'s crew got away with the money.")
            end
            Bridge.save()
        end,
    })
    if incident then
        Threats.MarkIncident(ctx)
        return true
    end
    -- Nobody could be sent: the customer grudgingly pays after all.
    if Bridge.credit(order.shopKey, order.payout, "walk-in work order paid late") then
        order.escrowState = "RELEASED"
        order.paidAmount = order.payout
        Bridge.save()
        local owner = Bridge.onlinePlayerByIdentity(order.shopKey)
        if owner then Bridge.settlePending(owner) end
        tell("Customer paid", client .. " cooled off and paid " .. tostring(order.payout) .. ".")
    end
    return false
end

-- Called by handleCompleteOrder for a walk-in order before anything is
-- committed. Returns { amount, escrowState, message, after } or nil for the
-- plain full payment. `after` runs once the completion has been saved.
function MechanicThreats.PlanCompletion(shop, order, player)
    local ctx = Threats.Settings().Enabled and Threats.Context(CAREER_ID, shop, player) or nil
    if not ctx then return nil end
    local payout = math.floor(tonumber(order.payout) or 0)
    local client = tostring(order.clientName or "The customer")
    local allowHostile = Threats.OwnerNear(shop) ~= nil and Threats.CanEscalate(ctx)
    local temperament = Threats.RollTemperament(ctx, allowHostile)
    log("Info", "completion order=" .. tostring(order.id) .. " temperament=" .. temperament)

    if temperament == "hostile" then
        return {
            amount = 0, escrowState = "WITHHELD",
            message = client .. " refused to pay: \"" .. pick(LINES.hostile) .. "\" Their crew is on the way. "
                .. "One of them is carrying the " .. tostring(payout) .. " they owe.",
            after = function() sendCrew(ctx, order, player) end,
        }
    elseif temperament == "grumble" then
        local paid = Economy.RoundDown(payout * ZombRand(70, 91) / 100)
        return {
            amount = paid, escrowState = "RELEASED",
            message = client .. " complained: \"" .. pick(LINES.grumble) .. "\" They only paid "
                .. tostring(paid) .. " of " .. tostring(payout) .. ".",
        }
    end
    local tip = ZombRand(100) < 30 and Economy.RoundDown(payout * ZombRand(10, 21) / 100) or 0
    return {
        amount = payout + tip, escrowState = "RELEASED",
        message = client .. ": \"" .. pick(LINES.calm) .. "\" They paid " .. tostring(payout)
            .. (tip > 0 and (" and tipped " .. tostring(tip)) or "") .. ".",
    }
end

Bridge.career:RegisterThreats({
    {
        id = "thieves", weight = 1,
        run = function(ctx) return Threats.Presets.Thieves(ctx, { lines = LINES.thieves, title = "Shop break-in" }) end,
    },
})

return MechanicThreats
