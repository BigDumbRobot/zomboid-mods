-- KIPNCareers_BlacksmithThreats.lua
--
-- The Blacksmith career's threats, on the framework's KIPNCareers.Threats
-- (server authoritative; see KIPNCareers_Threats.lua in Careers Framework).
--
--   * Thieves (scheduled, random): sneak in and grab stock from the forge's
--     containers, then run. Kill them to get it back.
--   * Raiders (scheduled, random): a hostile crew damages the player-built
--     structures in the building (never below 25%, never destroyed), knocks
--     condition off forged goods, grabs some stock and fights whoever is there.
--   * Pickups: occasionally raiders show up when a customer picks up -- a
--     walk-in (a server-created work order; customers never walk in) when the
--     owner completes it at the forge, or a player approving inside the shop.

if isClient() and not isServer() then return end

require "KIPNCareers_BlacksmithServer"
require "KIPNCareers_Threats"

local Blacksmith = KIPNCareers.Blacksmith
local Threats = KIPNCareers.Threats
local Service = KIPNCareers.BlacksmithServer
local Bridge = Service and Service.Bridge

-- The server file's Bridge and the framework's threats layer can be absent
-- (an older copy of either, or a framework too old for the server file).
-- Leave threats off rather than fail the load: the server checks for this
-- module before every call into it.
local function bridgeReady()
    if type(Threats) ~= "table" or type(Threats.Register) ~= "function" or type(Bridge) ~= "table" or type(Bridge.career) ~= "table" then return false end
    for _, name in ipairs({ "state", "notify", "reputationFor" }) do
        if type(Bridge[name]) ~= "function" then return false end
    end
    return true
end
if not bridgeReady() then
    Blacksmith.Log("Threats", "Error", "Blacksmith threats disabled: server bridge or framework threats layer missing")
    return
end

local BlacksmithThreats = KIPNCareers.BlacksmithThreats or {}
KIPNCareers.BlacksmithThreats = BlacksmithThreats

local CAREER_ID = Bridge.career.id
local PICKUP_RAID_PERCENT = 20

local LINES = {
    thieves = {
        arrive = { "Smith's busy. Let's go.", "Quiet now." },
        steal = { "Take the blades!", "Grab the good steel!", "Fill the bag!" },
        flee = { "Go, go, go!", "Move it!" },
        caught = { "We've been made!", "Get off me!" },
        nothing = { "Nothing here but scrap." },
    },
    raiders = {
        arrive = { "That's the forge. Burn it down!", "Get in there!", "Take everything!" },
        smash = { "Smash the anvil!", "Wreck it all!", "Tear it down!", "Take the good stuff!" },
    },
}

function BlacksmithThreats.AddHeat(shop)
    Threats.AddHeat(CAREER_ID, shop, 1)
end

local function raid(ctx)
    return Threats.Presets.Raiders(ctx, { lines = LINES.raiders, steal = true, title = "Raiders at the forge!" })
end

-- Raiders crash a pickup (both walk-in and player pickups).
local function maybeRaidPickup(shop, order, player)
    local ctx = Threats.RollMoment(CAREER_ID, shop, PICKUP_RAID_PERCENT, player)
    if ctx and raid(ctx) then
        Threats.MarkIncident(ctx)
        Bridge.notify(shop.ownerKey, "Followed", "Raiders followed " .. tostring(order.clientName or "your customer")
            .. "'s pickup to the forge.", order.id)
        return true
    end
    return false
end

-- A walk-in order completed while the owner is at the forge.
function BlacksmithThreats.OnWalkInPickup(shop, order, player)
    if not Threats.OwnerNear(shop) then return end
    maybeRaidPickup(shop, order, player)
end

-- A player client approved (and so is collecting) inside the shop while the
-- owner is there.
function BlacksmithThreats.OnPlayerPickup(shop, order, client)
    if not client or not Threats.OwnerNear(shop) then return end
    local x, y, bounds = client:getX(), client:getY(), shop.bounds
    if type(bounds) ~= "table" or x < bounds.x1 or x > bounds.x2 or y < bounds.y1 or y > bounds.y2 then return end
    maybeRaidPickup(shop, order, Threats.OwnerNear(shop))
end

Bridge.career:RegisterThreats({
    {
        id = "thieves", weight = 2,
        run = function(ctx) return Threats.Presets.Thieves(ctx, { lines = LINES.thieves, title = "Forge break-in" }) end,
    },
    { id = "raiders", weight = 3, run = raid },
})

Blacksmith.Log("Threats", "Info", "Blacksmith threats registered")

return BlacksmithThreats
