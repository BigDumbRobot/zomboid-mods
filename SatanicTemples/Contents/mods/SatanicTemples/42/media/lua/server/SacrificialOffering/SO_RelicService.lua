if isClient() then return end

require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_PlayerLedger"
require "SacrificialOffering/SO_FixtureService"
require "SacrificialOffering/SO_ZoneService"

-- The temple skeletons' katanas are a tease. A client whose transfer out of a
-- skeleton is refused reports the attempt; the server verifies it against its
-- own world state and delivers the punishment: a lightning strike on the thief,
-- half their current health, and deep wounds on random body parts. The client
-- decides nothing -- it only says "I tried", and the server checks the claim.

local SO = SacrificialOffering
SO.RelicService = SO.RelicService or {}
local Relics = SO.RelicService

-- Loot-window reach plus network slack; a report from farther away is forged.
local MAX_THEFT_DISTANCE = 4.0
-- One strike per attempt: a drag of several items (or a spammed report) inside
-- this window is a single offence.
local STRIKE_COOLDOWN_MS = 8000
local HEALTH_LOSS_FRACTION = 0.5
local MIN_DEEP_WOUNDS, MAX_DEEP_WOUNDS = 2, 4

Relics.lastStrikeAt = Relics.lastStrikeAt or {}

local function callLightning(player)
    -- Every client near the thief draws the visible flash (SO_Lightning.lua);
    -- the vanilla thunder event below supplies the sound.
    local effect = { effect = SO.EFFECT.LIGHTNING, x = player:getX(), y = player:getY(), z = player:getZ() }
    if isServer() then
        sendServerCommand(SO.MODULE, SO.SERVER_COMMAND.EFFECT, effect)
    elseif SO.Client and SO.Client.HandleEffect then
        SO.Client.HandleEffect(effect)
    end
    local ok, err = pcall(function()
        getClimateManager():getThunderStorm():triggerThunderEvent(
            math.floor(player:getX()), math.floor(player:getY()), true, true, true)
    end)
    if not ok then SO.Logger.Error("Relic lightning strike failed", { error = tostring(err) }) end
end

local function smite(player)
    local body = player and player:getBodyDamage()
    if not body then return false, 0 end
    local loss = 0
    local ok, err = pcall(function()
        local startHealth = tonumber(body:getOverallBodyHealth()) or 0
        local target = startHealth * (1 - HEALTH_LOSS_FRACTION)

        local parts = body:getBodyParts()
        local lastWounded
        if parts and parts:size() > 0 then
            local candidates = {}
            for index = 0, parts:size() - 1 do candidates[#candidates + 1] = index end
            local count = math.min(MIN_DEEP_WOUNDS + ZombRand(0, MAX_DEEP_WOUNDS - MIN_DEEP_WOUNDS + 1), #candidates)
            for _ = 1, count do
                lastWounded = table.remove(candidates, ZombRand(0, #candidates) + 1)
                local part = parts:get(lastWounded)
                part:generateDeepWound()
                part:setAdditionalPain(part:getAdditionalPain() + 30.0)
            end
        end
        body:calculateOverallHealth()

        -- Deep wounds carry their own damage, so the wounds go on first and the
        -- general-health cut only tops the loss up to exactly half.
        for _ = 1, 3 do
            local excess = (tonumber(body:getOverallBodyHealth()) or 0) - target
            if excess <= 0.5 then break end
            body:ReduceGeneralHealth(excess)
            body:calculateOverallHealth()
        end
        -- NetworkPlayerAI:syncDamage() is not exposed to Lua. applyDamageFromWeapon
        -- always ends by syncing every injury to the player's client; damageType
        -- 0 is outside its wound switch (1 deep, 2/4 cut, 3/5 scratch, 6 bullet),
        -- so with zero damage and pain this call only syncs.
        if lastWounded then body:applyDamageFromWeapon(lastWounded, 0.0, 0, 0.0) end
        loss = startHealth - (tonumber(body:getOverallBodyHealth()) or 0)
    end)
    if not ok then
        SO.Logger.Error("Failed to apply relic-theft injuries", { error = tostring(err) })
        return false, loss
    end
    return true, loss
end

function Relics.HandleTheftAttempt(player, args)
    if not player or (player.isDead and player:isDead()) then return end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not x or not y or not z then return end

    local mannequin = SO.Fixtures.FindTaggedObject(x, y, z, SO.FIXTURE.MANNEQUIN)
    if not mannequin then
        SO.Logger.Debug("Relic theft report ignored: no temple skeleton there", { x = x, y = y, z = z })
        return
    end
    local dx, dy = player:getX() - (x + 0.5), player:getY() - (y + 0.5)
    if math.floor(player:getZ()) ~= z or dx * dx + dy * dy > MAX_THEFT_DISTANCE * MAX_THEFT_DISTANCE then
        SO.Logger.Debug("Relic theft report ignored: player out of reach", { x = x, y = y, z = z })
        return
    end

    local identity = SO.PlayerLedger.GetIdentity(player) or tostring(player)
    local now = SO.Util.NowMs()
    if now - (Relics.lastStrikeAt[identity] or 0) < STRIKE_COOLDOWN_MS then return end
    Relics.lastStrikeAt[identity] = now

    callLightning(player)
    local applied, loss = smite(player)
    SO.ZoneService.SendResult(player, SO.RESULT.WRATH, SO.TRANSLATION.RELIC_THEFT, { damage = loss })
    SO.Logger.Info("Relic theft punished", {
        player = identity, x = x, y = y, z = z, loss = loss, applied = tostring(applied),
    })
end

return Relics
