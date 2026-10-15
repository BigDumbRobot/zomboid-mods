require "BonkZone/BonkZone_Constants"
require "BonkZone/BonkZone_Logger"
require "BonkZone/BonkZone_Registry"

-- Single shared combat-blocking rule for Bonk Zone.
--
-- The rule is evaluated from the TARGET's square, never the attacker's:
--
--     blockHit = target is a protected type
--            AND target is inside an active Bonk Zone
--            AND the attack is ranged
--
-- "Protected type" means a player; zombies and everything else are never blocked.
--
-- See docs/engine-notes.md for the decompiled B42 hit path this relies on.

BonkZone = BonkZone or {}
BonkZone.CombatRules = BonkZone.CombatRules or {}

local CombatRules = BonkZone.CombatRules
local Constants = BonkZone.Constants
local Logger = BonkZone.Logger
local Registry = BonkZone.Registry

-- True only for a HandWeapon that reports isRanged(). Guards every access so a
-- nil / malformed weapon can never raise a Lua error here.
function CombatRules.IsRangedWeapon(weapon)
    if not weapon or not weapon.isRanged then return false end
    local ok, ranged = pcall(function() return weapon:isRanged() end)
    if not ok then
        Logger.Warn("CombatRules", "weapon:isRanged() raised", { error = tostring(ranged) })
        return false
    end
    return ranged == true
end

-- Classify the TARGET of a weapon hit. Returns protected(boolean), label(string).
function CombatRules.ClassifyTarget(target)
    if target == nil then return false, "nil" end
    if Constants.IsPlayerObject(target) then
        return true, "player"
    end
    if Constants.IsZombieObject(target) then
        return false, "zombie"
    end
    return false, "other"
end

-- The one shared rule. Evaluated from the target's location.
-- Returns blocked(boolean), zone(table|nil), info(table).
-- info always carries: targetType, ranged, targetInside, zoneId,
-- targetX, targetY, targetZ, reason.
function CombatRules.ShouldBlockHit(attacker, target, weapon)
    local startedAt = Logger.Begin("CombatRules.ShouldBlockHit")
    local info = {
        targetType = "unknown",
        ranged = false,
        targetInside = false,
        zoneId = "",
        targetX = 0, targetY = 0, targetZ = 0,
        reason = "",
    }

    if target and target.getX then
        local ok = pcall(function()
            info.targetX = math.floor(target:getX())
            info.targetY = math.floor(target:getY())
            info.targetZ = math.floor(target:getZ())
        end)
        if not ok then info.targetX, info.targetY, info.targetZ = 0, 0, 0 end
    end

    local protected, label = CombatRules.ClassifyTarget(target)
    info.targetType = label
    if not protected then
        info.reason = "target is not a protected type (" .. label .. ")"
        Logger.Finish("CombatRules.ShouldBlockHit", startedAt, true, info.reason)
        return false, nil, info
    end

    info.ranged = CombatRules.IsRangedWeapon(weapon)
    if not info.ranged then
        info.reason = "attack is not ranged (melee/shove allowed inside zones)"
        Logger.Finish("CombatRules.ShouldBlockHit", startedAt, true, info.reason)
        return false, nil, info
    end

    if attacker and attacker.isDoShove and attacker:isDoShove() then
        info.reason = "attacker is shoving, not firing"
        Logger.Finish("CombatRules.ShouldBlockHit", startedAt, true, info.reason)
        return false, nil, info
    end

    local ok, inside, zone = pcall(Registry.IsCharacterInside, target)
    if not ok then
        info.reason = "zone lookup raised (" .. tostring(inside) .. ") -- treating as outside"
        Logger.Warn("CombatRules", "IsCharacterInside raised", { error = tostring(inside) })
        Logger.Finish("CombatRules.ShouldBlockHit", startedAt, false, info.reason)
        return false, nil, info
    end

    info.targetInside = inside == true
    info.zoneId = zone and zone.id or ""
    if not inside then
        info.reason = "target is outside every active Bonk Zone"
        Logger.Finish("CombatRules.ShouldBlockHit", startedAt, true, info.reason)
        return false, nil, info
    end

    info.reason = "BLOCK: protected target inside Bonk Zone " .. info.zoneId .. ", ranged attack"
    Logger.Finish("CombatRules.ShouldBlockHit", startedAt, true, info.reason)
    return true, zone, info
end

return CombatRules
