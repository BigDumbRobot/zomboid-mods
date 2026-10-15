require "BonkZone/BonkZone_Constants"
require "BonkZone/BonkZone_Logger"

BonkZone = BonkZone or {}
BonkZone.Audit = BonkZone.Audit or {}

local Audit = BonkZone.Audit
local Constants = BonkZone.Constants
local Logger = BonkZone.Logger

Audit.LastReport = Audit.LastReport or {}

-- Called directly by the server-side combat guard when a ranged PvP hit is suppressed.
function Audit.RecordBlockedRangedPvp(attacker, target, weapon, zone)
    local startedAt = Logger.Begin("Audit.RecordBlockedRangedPvp")
    if not attacker then
        Logger.Finish("Audit.RecordBlockedRangedPvp", startedAt, false, "missing attacker")
        return false
    end
    local attackerName = tostring(attacker.getUsername and attacker:getUsername() or "unknown")
    local targetName = Constants.NormalizeName(target and target.getUsername and target:getUsername() or "unknown")
    local weaponType = Constants.NormalizeName(weapon and weapon.getFullType and weapon:getFullType() or "unknown")
    local zoneId = tostring(zone and zone.id or "")
    local key = attackerName .. "|" .. targetName .. "|" .. weaponType
    local now = Constants.NowMs()
    if now - (Audit.LastReport[key] or 0) < Constants.AUDIT_RATE_LIMIT_MS then
        Logger.Finish("Audit.RecordBlockedRangedPvp", startedAt, true, "rate limited")
        return false
    end
    Audit.LastReport[key] = now
    Logger.Info("CombatAudit", "blocked ranged PvP", {
        attacker = attackerName,
        target = targetName,
        weapon = weaponType,
        zoneId = zoneId,
        attackerX = attacker.getX and math.floor(attacker:getX()) or 0,
        attackerY = attacker.getY and math.floor(attacker:getY()) or 0,
    })
    Logger.Finish("Audit.RecordBlockedRangedPvp", startedAt, true)
    return true
end

return Audit
