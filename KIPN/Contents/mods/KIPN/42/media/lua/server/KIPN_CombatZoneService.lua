-- KIPN_CombatZoneService.lua
--
-- Server-authoritative enforcement of zone combat policy
-- (WorldRegistry.CombatPolicies), i.e. the actual "damage zones"
-- feature described in the KIPN admin zone tool.
--
-- THE ACTUAL SERVER-SIDE DAMAGE HOOK:
--
-- Project Zomboid computes and applies melee/ranged weapon
-- damage inside IsoGameCharacter:Hit(...), which runs on the
-- SERVER for a dedicated/hosted game (guarded internally by
-- zombie.network.GameServer.server). Hit() does two relevant
-- things, in this order, before a single point of damage is
-- calculated or applied:
--
--   1. Fires Events.OnWeaponHitCharacter(attacker, victim,
--      weapon, damage) -- a plain notification, synchronously,
--      BEFORE any damage math runs.
--
--   2. Immediately after, checks victim.avoidDamage. If that
--      flag is true, Hit() returns 0 damage outright (no
--      knockback, no hitConsequences, nothing) and consumes
--      the flag (resets it to false).
--
-- Because (1) happens synchronously before (2), a listener on
-- Events.OnWeaponHitCharacter that calls victim:setAvoidDamage(true)
-- cancels THAT SPECIFIC hit deterministically -- no race, no
-- polling, no need to guess which hit is coming.
--
-- WHY NOT Hook.WeaponHitCharacter (LuaHookManager)?
--
-- PZ also exposes a boolean-returning "Hook" table
-- (Hook.WeaponHitCharacter.Add(fn)) via LuaHookManager, which
-- Hit() consults right before the avoidDamage check and can
-- skip vanilla damage entirely. It looks like the "correct"
-- cancellable hook, but zombie.Lua.Event:trigger() ignores each
-- callback's return value -- it returns true purely based on
-- whether ANY callback is registered, not what that callback
-- decided. Registering under Hook.WeaponHitCharacter therefore
-- disables ALL vanilla weapon damage, globally, for every hit
-- (player and zombie alike), for as long as the hook exists --
-- the registrant becomes fully responsible for reimplementing
-- damage math itself. That is not a targeted per-zone veto, so
-- this service deliberately does NOT use it.
--
-- setAvoidDamage() is a per-hit, per-victim, one-shot flag with
-- no such blast radius, which is why it is the correct tool for
-- a selective PvP/zone policy.
--
-- SCOPE:
--
-- This service only gates PLAYER damage. Zombie/animal-vs-zombie
-- interactions are untouched, and zombie/animal attacks on a
-- player are never blocked by either policy below -- the PVE
-- policy only blocks PLAYER-vs-PLAYER damage.
--
-- The ambient default (no zone, or no combatPolicy set) is always
-- full PvP damage. There are exactly two ways to deviate from
-- that, both defined in KIPN_WorldRegistry.lua's
-- WorldRegistry.CombatPolicies:
--
--   PVE       -> no PvP damage
--   MELEE_PVP -> PvP damage allowed, ranged weapons blocked

if isClient() then return end

require "KIPN/KIPN_Shared"
require "KIPN/KIPN_WorldRegistry"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

KIPN.Server.CombatZoneService = KIPN.Server.CombatZoneService or {}

local CombatZoneService = KIPN.Server.CombatZoneService

local logger =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("CombatZoneService")
    or nil

local function log(message)
    if logger then
        logger:Info(message)
    else
        print("[KIPN COMBAT ZONE] " .. tostring(message))
    end
end

local function logError(message)
    if logger then
        logger:Error(message)
    else
        print("[KIPN COMBAT ZONE] ERROR: " .. tostring(message))
    end
end

------------------------------------------------------------
-- POLICY PRIORITY
------------------------------------------------------------
--
-- When multiple zones overlap the same position, the MOST
-- restrictive matching policy wins. Lower number = wins. Only
-- two policies exist, so this just decides PVE-over-MELEE_PVP
-- when both are drawn over the same ground.
------------------------------------------------------------

local POLICY_PRIORITY

local function buildPolicyPriority()
    local Policies = KIPN.Server.WorldRegistry.CombatPolicies

    POLICY_PRIORITY = {
        [Policies.PVE] = 1,
        [Policies.MELEE_PVP] = 2,
    }
end

------------------------------------------------------------
-- POSITION RESOLUTION
------------------------------------------------------------

local function getCharacterSquarePosition(character)
    if not character then
        return nil
    end

    local ok, square = pcall(function() return character:getSquare() end)

    if not ok or not square then
        return nil
    end

    return square:getX(), square:getY(), square:getZ()
end

------------------------------------------------------------
-- RESOLVE EFFECTIVE POLICY AT POSITION
------------------------------------------------------------

local function resolvePolicyAtPosition(x, y, z)
    local zones = KIPN.Server.WorldRegistry.GetZonesAtPosition(x, y, z)

    local bestPolicy = nil
    local bestZone = nil
    local bestPriority = math.huge

    for _, zone in pairs(zones) do
        local policy = KIPN.Server.WorldRegistry.GetZoneCombatPolicy(zone)

        if policy then
            local priority = POLICY_PRIORITY[policy] or math.huge

            if priority < bestPriority then
                bestPriority = priority
                bestPolicy = policy
                bestZone = zone
            end
        end
    end

    return bestPolicy, bestZone
end

------------------------------------------------------------
-- DECISION
------------------------------------------------------------
--
-- Returns true if the hit should be BLOCKED.
------------------------------------------------------------

local function isRangedWeapon(weapon)
    if not weapon then
        return false
    end

    local ok, ranged = pcall(function() return weapon:isRanged() end)

    return ok and ranged == true
end

local function decideBlock(policy, weapon, isAttackerPlayer)
    local Policies = KIPN.Server.WorldRegistry.CombatPolicies

    if policy == Policies.PVE then
        -- Zombies/animals allowed; players blocked (no PvP damage).
        return isAttackerPlayer
    end

    if policy == Policies.MELEE_PVP then
        if not isAttackerPlayer then
            -- Zombie/animal damage is untouched by a combat zone.
            return false
        end

        return isRangedWeapon(weapon)
    end

    -- No zone, or an unrecognized policy: the ambient default is
    -- always full PvP damage, unblocked.
    return false
end

------------------------------------------------------------
-- WEAPON HIT HANDLER
------------------------------------------------------------

local function onWeaponHitCharacter(attacker, victim, weapon, _damage)
    if not victim or not instanceof(victim, "IsoPlayer") then
        -- This service only protects players. Zombie/animal
        -- victims are never gated.
        return
    end

    local x, y, z = getCharacterSquarePosition(victim)

    if not x then
        return
    end

    local policy, zone = resolvePolicyAtPosition(x, y, z)

    if not policy then
        -- No PVE/MELEE_PVP zone here: ambient default is full PvP
        -- damage, so nothing to block.
        return
    end

    local isAttackerPlayer = attacker ~= nil and instanceof(attacker, "IsoPlayer")

    local blocked = decideBlock(policy, weapon, isAttackerPlayer)

    if blocked then
        local ok = pcall(function() victim:setAvoidDamage(true) end)

        if ok then
            log(
                "Blocked hit: policy=" .. tostring(policy) ..
                " zone=" .. tostring(zone and zone.id) ..
                " victim=" .. tostring(victim.getUsername and victim:getUsername() or "?") ..
                " attacker=" .. tostring(
                    attacker and attacker.getUsername and attacker:getUsername()
                    or (attacker and tostring(attacker)) or "?"
                )
            )
        else
            logError("Failed to call setAvoidDamage on victim.")
        end
    end
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

function CombatZoneService.Initialize()
    if not KIPN.Server.WorldRegistry or not KIPN.Server.WorldRegistry.CombatPolicies then
        logError("KIPN.Server.WorldRegistry is not ready; combat zone enforcement disabled.")
        return false
    end

    buildPolicyPriority()

    Events.OnWeaponHitCharacter.Add(onWeaponHitCharacter)

    return true
end

print("[KIPN] Combat Zone Service loaded")
