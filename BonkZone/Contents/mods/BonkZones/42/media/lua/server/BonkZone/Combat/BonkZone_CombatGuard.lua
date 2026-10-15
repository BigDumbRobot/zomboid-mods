require "BonkZone/BonkZone_Constants"
require "BonkZone/BonkZone_Logger"
require "BonkZone/BonkZone_Registry"
require "BonkZone/BonkZone_CombatRules"
require "BonkZone/Combat/BonkZone_Audit"

-- Server-side ranged suppression.
--
-- B42 applies player-vs-player weapon damage only on the server: IsoPlayer.hitConsequences
-- does DamageFromWeapon() in the server branch, while every client just splatBloodFloorBig().
-- IsoGameCharacter.Hit() fires OnWeaponHitCharacter (server included) and then, one line
-- later, honours the one-shot AvoidDamage flag before any damage is applied. So setting
-- AvoidDamage on a player target here, on the server, suppresses the authoritative PvP hit.
--
-- The block/allow decision lives in BonkZone.CombatRules.ShouldBlockHit (shared), evaluated
-- from the target's location.

BonkZone = BonkZone or {}
BonkZone.CombatGuard = BonkZone.CombatGuard or {}

local CombatGuard = BonkZone.CombatGuard
local Constants = BonkZone.Constants
local Logger = BonkZone.Logger
local CombatRules = BonkZone.CombatRules
local Audit = BonkZone.Audit

CombatGuard.BlockedCount = CombatGuard.BlockedCount or 0
CombatGuard.LastNotifyMs = CombatGuard.LastNotifyMs or {}
CombatGuard.Wired = CombatGuard.Wired or false

-- One audit line + one attacker halo per attacker/weapon per cooldown, so a shotgun
-- blast or a burst does not spam either.
local function notifyBlocked(attacker, target, weapon, zone)
    local startedAt = Logger.Begin("CombatGuard.notifyBlocked")
    local username = attacker and attacker.getUsername and attacker:getUsername() or "unknown"
    local weaponType = weapon and weapon.getFullType and weapon:getFullType() or "unknown"
    local key = tostring(username) .. "|" .. tostring(weaponType)
    local now = Constants.NowMs()
    if now - (CombatGuard.LastNotifyMs[key] or 0) < Constants.REPORT_COOLDOWN_MS then
        Logger.Finish("CombatGuard.notifyBlocked", startedAt, true, "cooldown")
        return
    end
    CombatGuard.LastNotifyMs[key] = now
    Audit.RecordBlockedRangedPvp(attacker, target, weapon, zone)
    if isServer() and attacker then
        sendServerCommand(attacker, Constants.MODULE, Constants.Commands.SHOW_BLOCKED, {})
    end
    Logger.Finish("CombatGuard.notifyBlocked", startedAt, true)
end

function CombatGuard.OnWeaponHitCharacter(attacker, target, weapon, damage)
    local startedAt = Logger.Begin("CombatGuard.OnWeaponHitCharacter", { damage = damage })
    if isClient() and not isServer() then
        -- This file loads only under media/lua/server, but guard anyway: PvP damage is
        -- applied on the server, so a pure client has nothing to suppress here.
        Logger.Finish("CombatGuard.OnWeaponHitCharacter", startedAt, true, "not server")
        return
    end

    local ok, blocked, zone, info = pcall(CombatRules.ShouldBlockHit, attacker, target, weapon)
    if not ok then
        Logger.Error("CombatGuard", "rule evaluation raised", { error = tostring(blocked) })
        Logger.Finish("CombatGuard.OnWeaponHitCharacter", startedAt, false, "rule error")
        return
    end

    if not blocked then
        Logger.Finish("CombatGuard.OnWeaponHitCharacter", startedAt, true, "allowed -- " .. (info and info.reason or "n/a"))
        return
    end

    local applied = pcall(function()
        target:setAvoidDamage(true)
        if attacker and attacker.getLastHitCount and attacker.setLastHitCount then
            attacker:setLastHitCount(math.max(0, attacker:getLastHitCount() - 1))
        end
    end)
    if not applied then
        Logger.Error("CombatGuard", "setAvoidDamage path raised", { target = info and info.targetType or "?" })
    end

    CombatGuard.BlockedCount = CombatGuard.BlockedCount + 1
    notifyBlocked(attacker, target, weapon, zone)
    Logger.RateLimited("INFO", "CombatGuard.suppressed." .. tostring(zone and zone.id or ""), Constants.REPORT_COOLDOWN_MS,
        "CombatGuard", "ranged damage suppressed", {
            zoneId = zone and zone.id or "",
            targetType = info and info.targetType or "?",
            weapon = weapon and weapon.getFullType and weapon:getFullType() or "unknown",
            blockedCount = CombatGuard.BlockedCount,
        })
    Logger.Finish("CombatGuard.OnWeaponHitCharacter", startedAt, true, { blocked = true, applied = applied })
end

if not CombatGuard.Wired then
    Events.OnWeaponHitCharacter.Add(CombatGuard.OnWeaponHitCharacter)
    CombatGuard.Wired = true
    Logger.Info("CombatGuard", "OnWeaponHitCharacter handler registered")
end

return CombatGuard
