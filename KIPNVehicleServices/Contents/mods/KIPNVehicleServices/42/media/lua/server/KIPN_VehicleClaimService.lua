-- KIPN_VehicleClaimService.lua
--
-- Vehicle ownership claim logic for KIPN: Vehicle Services. Carved out
-- of KIP Network Terminal's KIPN_ClaimService.lua.
--
-- Terminal keeps the authoritative claim-record store, the spatial
-- index, the generic release lifecycle, and the vehicle-object /
-- ownership-metadata layer (KIPN_ClaimPermissions.lua still enforces
-- non-owner access from there). THIS file owns the vehicle target +
-- artifact validation and the CLAIM_VEHICLE flow.
--
-- Namespace: KIPN.Server.VehClaimService (never ClaimService).

if isClient() then return end

require "KIPN/KIPN_Shared"
require "KIPN/KIPN_Server"
require "KIPN_ClaimService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.VehClaimService = KIPN.Server.VehClaimService or {}

local VehClaimService = KIPN.Server.VehClaimService

-- getVehicleById() finds nothing in single player (it only asks the
-- multiplayer VehicleManager); KIPN.Shared.GetVehicleById falls back to
-- the vehicles loaded in the cell.
local function findVehicleById(id)
    if KIPN.Shared and type(KIPN.Shared.GetVehicleById) == "function" then
        return KIPN.Shared.GetVehicleById(id)
    end
    if type(getVehicleById) == "function" then
        return getVehicleById(tonumber(id) or id)
    end
    return nil
end

-- Terminal's claim service -- authoritative store + generic API.
local ClaimService = KIPN.Server.ClaimService

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local function log(message)
    print("[KIPN VEHICLE CLAIM SERVICE] " .. tostring(message))
end
local function logError(message)
    print("[KIPN VEHICLE CLAIM SERVICE] ERROR: " .. tostring(message))
end

------------------------------------------------------------
-- DEPENDENCY ACCESSORS
------------------------------------------------------------

-- Vehicle claim-artifact validation + consumption live in this mod's
-- own KIPN_VehicleArtifactService.lua (carved from Terminal's
-- ArtifactService). The generic artifact engine it delegates to still
-- belongs to Terminal.
local function getVehArtifactService()
    return KIPN.Server.VehArtifactService
end

local WorldRegistry
local function getWorldRegistry()
    if WorldRegistry then return WorldRegistry end
    WorldRegistry = KIPN.Server.WorldRegistry
    return WorldRegistry
end

------------------------------------------------------------
-- GENERIC STORE / HELPER ALIASES  (Terminal owns these)
------------------------------------------------------------

local createClaimRecord = ClaimService.CreateClaimRecord
local removeClaimRecord = ClaimService.RemoveClaimRecord
local function save()
    if type(KIPN.Server.Save) == "function" then
        local ok, result = pcall(KIPN.Server.Save, "claims")
        if not ok then
            logError("KIPN.Server.Save('claims') failed: " .. tostring(result))
            return false
        end
        return result ~= false
    end
    logError("KIPN.Server.Save() is unavailable.")
    return false
end
local checkMaxClaimsForType = ClaimService.CheckMaxClaimsForType
local generateClaimId = ClaimService.GenerateClaimId
local getPlayerSteamId = ClaimService.GetPlayerSteamId
local getPlayerName = ClaimService.GetPlayerName
local getPlayerPosition = ClaimService.GetPlayerPosition
local getClaimConfig = ClaimService.GetClaimConfig
local getClaimZone = ClaimService.GetClaimZone
local hasClaimCapability = ClaimService.HasClaimCapability
local getVehicleId = ClaimService.GetVehicleId
local isVehicleValid = ClaimService.IsVehicleValid
local getVehicleSquare = ClaimService.GetVehicleSquare
local getVehiclePosition = ClaimService.GetVehiclePosition
local setVehicleOwnershipMetadata = ClaimService.SyncVehicleOwnershipMetadata

------------------------------------------------------------
-- CARVED: VEHICLE CLAIM LOGIC
------------------------------------------------------------


function VehClaimService.ValidateVehicleTarget(
    player,
    vehicle
)

    if not player then

        return false,
            "Player is required."

    end

    if not isVehicleValid(
        vehicle
    )
    then

        return false,
            "Vehicle is unavailable."

    end

    local vehicleId =
        getVehicleId(
            vehicle
        )

    if not vehicleId then

        return false,
            "Vehicle ID is unavailable."

    end

    --------------------------------------------------------
    -- Current ownership.
    --------------------------------------------------------

    local existingClaim =
        ClaimService.GetClaimForTarget(
            ClaimService.Types.VEHICLE,
            vehicleId
        )

    if existingClaim then

        return false,
            "Vehicle is already claimed."

    end

    --------------------------------------------------------
    -- Current physical location.
    --------------------------------------------------------

    local position =
        getVehiclePosition(
            vehicle
        )

    if not position then

        return false,
            "Vehicle location is unavailable."

    end

    --------------------------------------------------------
    -- Current world capability.
    --------------------------------------------------------

    local capable,
        capabilityReason =
        hasClaimCapability(
            position,
            ClaimService.Types.VEHICLE
        )

    if not capable then

        return false,
            capabilityReason

    end

    --------------------------------------------------------
    -- Current authoritative zone.
    --------------------------------------------------------

    local zone,
        zoneId =
        getClaimZone(
            position,
            ClaimService.Types.VEHICLE
        )

    if not zone then

        return false,
            "Vehicle is not inside an authorized claim zone."

    end

    return true,
        nil,
        {

            vehicleId =
                vehicleId,

            position =
                position,

            zone =
                zone,

            zoneId =
                zoneId,

        }

end


function VehClaimService.ValidateVehicleClaimArtifact(
    player,
    claimItem,
    targetZoneId
)

    local artifacts =
        getVehArtifactService()

    if not artifacts then

        return false,
            "Artifact service unavailable."

    end

    if not claimItem then

        return false,
            "Vehicle claim artifact required."

    end

    if type(
        artifacts.ValidateVehicleClaim
    ) ~= "function"
    then

        logError(
            "ArtifactService.ValidateVehicleClaim() " ..
            "is unavailable."
        )

        return false,
            "Artifact validation service unavailable."

    end

    local valid,
        result

    local ok, errorMessage =
        pcall(
            function()

                valid,
                    result =
                    artifacts.ValidateVehicleClaim(
                        player,
                        claimItem,
                        targetZoneId
                    )

            end
        )

    if not ok then

        logError(
            "Artifact validation failed with error: " ..
            tostring(errorMessage)
        )

        return false,
            "Artifact validation failed."

    end

    if not valid then

        return false,
            result

    end

    return true,
        result

end


function VehClaimService.ClaimVehicle(
    player,
    vehicle,
    claimItem
)

    --------------------------------------------------------
    -- PLAYER
    --------------------------------------------------------

    local playerSteamId =
        getPlayerSteamId(
            player
        )

    if not playerSteamId then

        return false,
            "Player identity unavailable."

    end

    --------------------------------------------------------
    -- TARGET
    --------------------------------------------------------

    local targetValid,
        targetReason,
        targetData =
        VehClaimService.ValidateVehicleTarget(
            player,
            vehicle
        )

    if not targetValid then

        return false,
            targetReason

    end

    --------------------------------------------------------
    -- ARTIFACT
    --------------------------------------------------------

    local artifactValid,
        artifactResult =
        VehClaimService.ValidateVehicleClaimArtifact(
            player,
            claimItem,
            targetData.zoneId
        )

    if not artifactValid then

        return false,
            artifactResult

    end

    local artifactRecord =
        artifactResult

    if not artifactRecord then

        return false,
            "Claim artifact record unavailable."

    end

    --------------------------------------------------------
    -- MAX CLAIMS PER PLAYER
    --------------------------------------------------------

    local withinQuota,
        quotaReason =
        checkMaxClaimsForType(
            player,
            ClaimService.Types.VEHICLE
        )

    if not withinQuota then

        return false,
            quotaReason

    end

    --------------------------------------------------------
    -- FINAL OWNERSHIP CHECK
    --------------------------------------------------------
    --
    -- Repeat immediately before mutation.
    --------------------------------------------------------

    if ClaimService.IsTargetClaimed(
        ClaimService.Types.VEHICLE,
        targetData.vehicleId
    )
    then

        log(
            "ClaimVehicle() FAILED: vehicle became " ..
            "claimed before ownership creation."
        )

        return false,
            "Vehicle is already claimed."

    end

    --------------------------------------------------------
    -- CREATE AUTHORITATIVE OWNERSHIP RECORD
    --------------------------------------------------------

    local claimRecord,
        createReason =
        createClaimRecord(
            player,
            ClaimService.Types.VEHICLE,
            targetData.vehicleId,
            targetData.zoneId,
            artifactRecord.id,
            targetData.position
        )

    if not claimRecord then

        log(
            "ClaimVehicle() ownership creation failed: " ..
            tostring(createReason)
        )

        return false,
            createReason

    end

    --------------------------------------------------------
    -- CONSUME CLAIM ARTIFACT
    --------------------------------------------------------

    local artifacts =
        getVehArtifactService()

    if not artifacts then

        removeClaimRecord(
            claimRecord.id
        )

        return false,
            "Artifact service unavailable."

    end

    if type(
        artifacts.ConsumeVehicleClaim
    ) ~= "function"
    then

        removeClaimRecord(
            claimRecord.id
        )

        logError(
            "ArtifactService.ConsumeVehicleClaim() " ..
            "is unavailable."
        )

        return false,
            "Artifact consumption service unavailable."

    end

    local consumed
    local consumeReason

    local consumeOk,
        consumeError =
        pcall(
            function()

                consumed,
                    consumeReason =
                    artifacts.ConsumeVehicleClaim(
                        player,
                        claimItem,
                        targetData.zoneId
                    )

            end
        )

    if not consumeOk then

        removeClaimRecord(
            claimRecord.id
        )

        logError(
            "Claim artifact consumption threw an error: " ..
            tostring(consumeError)
        )

        return false,
            "Claim artifact could not be consumed."

    end

    if not consumed then

        removeClaimRecord(
            claimRecord.id
        )

        log(
            "ClaimVehicle() artifact consumption failed: " ..
            tostring(consumeReason)
        )

        return false,
            consumeReason or
            "Claim artifact could not be consumed."

    end

    --------------------------------------------------------
    -- PERSIST OWNERSHIP
    --------------------------------------------------------

    local saved =
        save()

    if not saved then

        ----------------------------------------------------
        -- IMPORTANT:
        --
        -- ArtifactService has already consumed and saved
        -- the bearer artifact.
        --
        -- Do NOT recreate/refund it here.
        --
        -- The artifact remains consumed and ownership is
        -- removed from the in-memory claim index.
        ----------------------------------------------------

        removeClaimRecord(
            claimRecord.id
        )

        logError(
            "Claim ownership could not be persisted. " ..
            "Artifact remains consumed."
        )

        return false,
            "Claim could not be persisted."

    end

    --------------------------------------------------------
    -- Publish the persisted ownership onto the live vehicle for
    -- client-side menu gating. Failure here does not undo the
    -- authoritative claim; server-side access enforcement uses the
    -- claim registry and remains effective.
    --------------------------------------------------------

    setVehicleOwnershipMetadata(
        vehicle,
        claimRecord
    )

    --------------------------------------------------------
    -- SUCCESS
    --------------------------------------------------------

    log(
        "VEHICLE CLAIM SUCCESS | " ..

        "claimId=" ..
        claimRecord.id ..

        " | vehicle=" ..
        targetData.vehicleId ..

        " | owner=" ..
        playerSteamId ..

        " | zone=" ..
        tostring(targetData.zoneId)
    )

    return true,
        claimRecord

end


local function handleClaimVehicleCommand(
    player,
    args
)

    args =
        args or {}

    local vehicleId =
        args.vehicleId

    if vehicleId == nil
    then

        return false,
            "Vehicle could not be resolved."

    end

    local vehicle =
        findVehicleById(
            vehicleId
        )

    if not vehicle then

        return false,
            "Vehicle could not be resolved."

    end

    local artifacts =
        getVehArtifactService()

    if not artifacts
        or type(
            artifacts.FindPlayerVehicleClaimArtifact
        ) ~= "function"
    then

        logError(
            "ArtifactService.FindPlayerVehicleClaimArtifact() " ..
            "is unavailable."
        )

        return false,
            "Artifact service unavailable."

    end

    --------------------------------------------------------
    -- Resolve the vehicle's own dealership zone BEFORE picking a
    -- claim item. A player may legitimately carry more than one
    -- Vehicle Title at once (MaxClaimsPerPlayer for Vehicle
    -- defaults to 10 -- see KIPN_ClaimConfig.lua), each scoped to
    -- whichever dealership lot issued it. Without this, the
    -- artifact search below would return whichever unconsumed
    -- Title happens to be found FIRST in inventory, regardless of
    -- scope -- if that's a title from a DIFFERENT lot, the claim
    -- would be rejected as "not valid for this zone" even though
    -- the player genuinely holds a valid title for THIS vehicle.
    -- A nil zoneId here (vehicle not currently in any authorized
    -- zone at all) falls back to the prior, unscoped search --
    -- ClaimVehicle()/ValidateVehicleTarget() below still correctly
    -- rejects that case regardless of which title was picked.
    --------------------------------------------------------

    local vehiclePosition =
        getVehiclePosition(
            vehicle
        )

    local targetZoneId =
        nil

    if vehiclePosition then

        local _targetZone,
            resolvedZoneId =
            getClaimZone(
                vehiclePosition,
                ClaimService.Types.VEHICLE
            )

        targetZoneId =
            resolvedZoneId
    end

    local claimItem,
        _record,
        findReason =
        artifacts.FindPlayerVehicleClaimArtifact(
            player,
            targetZoneId
        )

    if not claimItem then

        return false,
            findReason
                or "Vehicle claim artifact required."

    end

    local claimed,
        result =
        VehClaimService.ClaimVehicle(
            player,
            vehicle,
            claimItem
        )

    if not claimed then

        return false,
            result

    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.VEHICLE_CLAIM_SUCCESSFUL,
        {}
    )

    return true,
        "CLAIM_SUCCESSFUL"

end


------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

ClaimService.RegisterClaimType("vehicle", {
    requiredCapability = "vehicle.claim",
    serviceConfigKey = "Vehicle",
    label = "Vehicle",
    validateTarget = VehClaimService.ValidateVehicleTarget,
    validateClaimArtifact = VehClaimService.ValidateVehicleClaimArtifact,
    claim = VehClaimService.ClaimVehicle,
    onAfterRelease = function(claim)
        local vehicle = findVehicleById(claim.targetId)
        if vehicle then
            setVehicleOwnershipMetadata(vehicle, nil)
        end
    end,
})

------------------------------------------------------------
-- INITIALIZATION  (driven by KIPN_VehicleServicesInit.lua's RegisterService)
------------------------------------------------------------

function VehClaimService.Initialize()

    if type(KIPN.Server.RegisterCommandHandler) ~= "function" then
        logError("RegisterCommandHandler unavailable; CLAIM_VEHICLE unreachable.")
        return false
    end

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.CLAIM_VEHICLE,
        handleClaimVehicleCommand
    )

    log("Vehicle Services claim service initialized.")
    return true
end

print("[KIPN] Vehicle Services Claim Service loaded")

