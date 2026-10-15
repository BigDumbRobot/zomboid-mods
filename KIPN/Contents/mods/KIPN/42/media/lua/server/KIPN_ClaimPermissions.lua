-- KIPN_ClaimPermissions.lua
--
-- Generic, type-agnostic claim permission model for KIP Network
-- Terminal.
--
-- Responsibilities:
--   * Claim.IsOwner(claim, player) / Claim.IsAllowed(claim, player)
--   * Claim.CanEnter/CanBuild/CanLoot/CanExcavate(claim, player) --
--     pure QUERIES, reading the owning service's per-service
--     ClaimConfig AllowNonOwner* fields.
--   * Live land-claim entry enforcement via Events.OnPlayerMove: a
--     claim type opts in with `enforceEntry = true` on its
--     RegisterClaimType def (KIPN: Government Services does for
--     excavation); a type with `deferAccessToEngine = true` (property)
--     imposes no KIPN restriction so vanilla SafeHouse stays the sole
--     authority.
--
-- Enforcement that needs PZ action-pipeline hooks (client-side, the
-- layer PZ's own safehouse protection uses) lives in the owning
-- service:
--   * KIPN: Vehicle Services -- KIPN_VehicleEnforcement.lua: non-owner
--     ejection, the ClientCommands.vehicle mechanics/tow/door
--     interception, the stationary-occupant audit.
--   * KIPN: Government Services -- KIPN_ExcavationAccessEnforcement.lua:
--     the ISInventoryTransferAction loot block and the world-object
--     context-menu build/dig filter inside a non-owned excavation plot.
--
-- Claim.CanBuild/CanLoot/CanExcavate here stay as the shared server-side
-- query API those layers (and future interceptors) call. IsAllowed is a
-- synonym for IsOwner pending a future member/invite list.

if isClient() then return end

require "KIPN/KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.ClaimPermissions = KIPN.Server.ClaimPermissions or {}

local Claim = KIPN.Server.ClaimPermissions

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local logger =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("ClaimPermissions")
    or nil

local function log(message)
    if logger then
        logger:Info(message)
    else
        print("[KIPN CLAIM PERMISSIONS] " .. tostring(message))
    end
end

local function logError(message)
    if logger then
        logger:Error(message)
    else
        print("[KIPN CLAIM PERMISSIONS] ERROR: " .. tostring(message))
    end
end

------------------------------------------------------------
-- IS OWNER
------------------------------------------------------------

function Claim.IsOwner(claim, player)

    if type(claim) ~= "table" or not player then
        return false
    end

    if not KIPN.Server.ClaimService
        or type(KIPN.Server.ClaimService.GetPlayerSteamId) ~= "function"
    then
        logError("IsOwner(): ClaimService.GetPlayerSteamId() is unavailable.")
        return false
    end

    local steamId =
        KIPN.Server.ClaimService.GetPlayerSteamId(player)

    if not steamId then
        return false
    end

    return tostring(claim.ownerSteamId) == steamId

end

------------------------------------------------------------
-- IS ALLOWED
--
-- See the header comment above -- currently a synonym for
-- IsOwner() pending a future member/invite list.
------------------------------------------------------------

function Claim.IsAllowed(claim, player)

    return Claim.IsOwner(claim, player)

end

------------------------------------------------------------
-- SERVICE CONFIG FOR A CLAIM
------------------------------------------------------------

local function getServiceConfigForClaim(claim)

    if type(claim) ~= "table" then
        return nil
    end

    if not KIPN.Server.ClaimConfig
        or type(KIPN.Server.ClaimConfig.GetServiceConfig) ~= "function"
    then
        logError("getServiceConfigForClaim(): ClaimConfig is unavailable.")
        return nil
    end

    return KIPN.Server.ClaimConfig.GetServiceConfig(claim.type)

end

------------------------------------------------------------
-- GENERIC "CAN X" CHECK
--
-- A claim type whose RegisterClaimType def sets
-- `deferAccessToEngine = true` (KIPN: Government Services does for
-- property, so vanilla SafeHouse stays the sole protection authority)
-- always returns ALLOW here. Otherwise an owner/allowed player can
-- always act; non-owners fall back to the per-service AllowNonOwner*
-- setting, defaulting DENY when no field exists.
------------------------------------------------------------

local function canDo(claim, player, fieldName)

    if type(claim) ~= "table" then
        return false
    end

    local defs =
        KIPN.Server.ClaimService
        and KIPN.Server.ClaimService.ClaimTypeDefs
    local def = defs and defs[claim.type]

    if def and def.deferAccessToEngine == true then
        return true
    end

    if Claim.IsAllowed(claim, player) then
        return true
    end

    local serviceConfig =
        getServiceConfigForClaim(claim)

    if not serviceConfig then
        return false
    end

    return serviceConfig[fieldName] == true

end

------------------------------------------------------------
-- CAN ENTER / BUILD / LOOT / EXCAVATE
------------------------------------------------------------

function Claim.CanEnter(claim, player)
    return canDo(claim, player, "AllowNonOwnerEnter")
end

function Claim.CanBuild(claim, player)
    return canDo(claim, player, "AllowNonOwnerBuild")
end

function Claim.CanLoot(claim, player)
    return canDo(claim, player, "AllowNonOwnerLoot")
end

function Claim.CanExcavate(claim, player)
    return canDo(claim, player, "AllowNonOwnerExcavate")
end


------------------------------------------------------------
-- CAN ENTER ENFORCEMENT (Events.OnPlayerMove)
--
-- Reactive, not preventive: OnPlayerMove fires AFTER the engine has
-- already moved the player. A denied entry is handled by warning
-- the player and pushing them back to their last known allowed
-- tile, mirroring the "warn"/"remove" branch of the intended
-- enforcement flow. Warnings are throttled per player so bumping
-- repeatedly against a boundary does not spam chat.
------------------------------------------------------------

local WARN_THROTTLE_MS = 3000

local lastSafePosition = {}
local lastWarnAtMs = {}

local function getRuntimeMs()

    if type(_G.getTimestampMs) ~= "function" then
        return 0
    end

    local ok, result =
        pcall(_G.getTimestampMs)

    if ok and type(result) == "number" then
        return result
    end

    return 0
end


local function onPlayerMove(player)

    if not player then
        return
    end

    local ok, err =
        pcall(
            function()

                if not KIPN.Server.ClaimService
                    or type(KIPN.Server.ClaimService.GetClaimAt) ~= "function"
                then
                    return
                end

                local playerKey =
                    type(player.getOnlineID) == "function"
                    and player:getOnlineID()
                    or nil

                if not playerKey then
                    return
                end

                local x =
                    math.floor(player:getX())

                local y =
                    math.floor(player:getY())

                local z =
                    math.floor(player:getZ())

                local claim =
                    KIPN.Server.ClaimService.GetClaimAt(x, y, z)

                -- A claim type opts into active entry enforcement with
                -- `enforceEntry = true` on its RegisterClaimType def
                -- (KIPN: Government Services sets it for excavation).
                local enforceEntry = false
                if claim and KIPN.Server.ClaimService.ClaimTypeDefs then
                    local def =
                        KIPN.Server.ClaimService.ClaimTypeDefs[claim.type]
                    enforceEntry = def and def.enforceEntry == true
                end

                if not enforceEntry
                    or Claim.CanEnter(claim, player)
                then

                    lastSafePosition[playerKey] = {
                        x = x,
                        y = y,
                        z = z,
                    }

                    return
                end

                ------------------------------------------------
                -- Denied: warn (throttled) and push back.
                ------------------------------------------------

                local now =
                    getRuntimeMs()

                local lastWarn =
                    lastWarnAtMs[playerKey] or 0

                if now - lastWarn >= WARN_THROTTLE_MS then

                    lastWarnAtMs[playerKey] = now

                    if type(player.Say) == "function" then

                        player:Say(
                            "This land is claimed. You are not "
                            .. "authorized to enter."
                        )
                    end

                end

                local safe =
                    lastSafePosition[playerKey]

                if safe
                    and type(player.teleportTo) == "function"
                then

                    -- Verified against the shipped game's own
                    -- client/DebugUIs/DebugContextMenu.lua
                    -- (onTeleportValid's server-side branch:
                    -- getPlayer():teleportTo(x, y, z)).
                    player:teleportTo(
                        safe.x + 0.5,
                        safe.y + 0.5,
                        safe.z
                    )

                end

            end
        )

    if not ok then

        logError(
            "onPlayerMove() failed: " .. tostring(err)
        )
    end

end


------------------------------------------------------------
-- INITIALIZE
------------------------------------------------------------

function Claim.Initialize()

    -- Generic land-claim entry enforcement. A claim type opts in with
    -- `enforceEntry = true` on its RegisterClaimType def. (Vehicle
    -- access enforcement lives in KIPN: Vehicle Services'
    -- KIPN_VehicleEnforcement.lua.)
    if Events and Events.OnPlayerMove then

        Events.OnPlayerMove.Add(onPlayerMove)

    else

        logError(
            "Events.OnPlayerMove is unavailable; claim entry "
            .. "enforcement will not run."
        )
    end

    log("Initialized.")

    return true

end

print("[KIPN] Claim Permissions server module loaded")
