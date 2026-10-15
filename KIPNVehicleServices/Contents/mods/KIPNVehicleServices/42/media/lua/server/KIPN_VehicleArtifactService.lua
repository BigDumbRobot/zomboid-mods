-- KIPN_VehicleArtifactService.lua
--
-- Vehicle Registration + Title artifact flow for KIPN: Vehicle Services.
-- Carved from KIP Network Terminal's KIPN_ArtifactService.lua.
--
-- Terminal keeps the generic artifact-record store + engine. THIS file
-- owns the Vehicle registration-form tagging, the Title issuance command
-- handler, and the claim-artifact validate/consume/find helpers that
-- KIPN_VehicleClaimService.lua calls.
--
-- Namespace: KIPN.Server.VehArtifactService (never ArtifactService).

if isClient() then return end

require "KIPN/KIPN_Shared"
require "KIPN/KIPN_Server"
require "KIPN/KIPN_ArtifactService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.VehArtifactService = KIPN.Server.VehArtifactService or {}

local VehArtifactService = KIPN.Server.VehArtifactService
local ArtifactService = KIPN.Server.ArtifactService

local function log(message)
    print("[KIPN VEH ARTIFACT SERVICE] " .. tostring(message))
end

local SERVICE_VEHICLE = "vehicle"

------------------------------------------------------------
-- ARTIFACT TYPE REGISTRATION
------------------------------------------------------------

ArtifactService.RegisterArtifactType("Vehicle", {
    registrationItem = "Base.KIPNVehicleRegistration",
    claimItem        = "Base.KIPNVehicleClaimArtifact",
    zoneClassification = "DEALERSHIP",
})

------------------------------------------------------------
-- GENERIC ENGINE ALIASES  (Terminal owns these)
------------------------------------------------------------

local getArtifactConfig = ArtifactService.GetArtifactConfig
local getArtifactData = ArtifactService.GetArtifactData
local save = ArtifactService.SaveArtifactData
local getPlayerName = ArtifactService.GetPlayerName
local getItemFullType = ArtifactService.GetItemFullType
local getItemModData = ArtifactService.GetItemModData
local setItemArtifactId = ArtifactService.SetItemArtifactId
local getItemArtifactId = ArtifactService.GetItemArtifactId
local getPlayerInventory = ArtifactService.GetPlayerInventory
local findArtifactItem = ArtifactService.FindArtifactItem
local giveItemToPlayer = ArtifactService.GiveItemToPlayer

------------------------------------------------------------
-- CARVED: VEHICLE ARTIFACT LOGIC
------------------------------------------------------------


local function getVehicleRegistrationDefinition()

    local config =
        getArtifactConfig()

    if not config then

        return nil

    end

    if not config.RegistrationItems then

        log(
            "ERROR: ArtifactConfig.RegistrationItems " ..
            "is unavailable."
        )

        return nil

    end

    if not config.Types then

        log(
            "ERROR: ArtifactConfig.Types is unavailable."
        )

        return nil

    end

    local itemType =
        config.RegistrationItems.Vehicle

    if not itemType then

        log(
            "ERROR: ArtifactConfig.RegistrationItems.Vehicle " ..
            "is unavailable."
        )

        return nil

    end

    local artifactType =
        config.Types.Registration

    if not artifactType then

        log(
            "ERROR: ArtifactConfig.Types.Registration " ..
            "is unavailable."
        )

        return nil

    end

    return {

        ItemType =
            itemType,

        Type =
            artifactType,

        Service =
            SERVICE_VEHICLE,

    }

end


local function getVehicleClaimDefinition()

    local config =
        getArtifactConfig()

    if not config then

        return nil

    end

    if not config.ClaimItems then

        log(
            "ERROR: ArtifactConfig.ClaimItems " ..
            "is unavailable."
        )

        return nil

    end

    if not config.Types then

        log(
            "ERROR: ArtifactConfig.Types is unavailable."
        )

        return nil

    end

    local itemType =
        config.ClaimItems.Vehicle

    if not itemType then

        log(
            "ERROR: ArtifactConfig.ClaimItems.Vehicle " ..
            "is unavailable."
        )

        return nil

    end

    local artifactType =
        config.Types.Claim

    if not artifactType then

        log(
            "ERROR: ArtifactConfig.Types.Claim " ..
            "is unavailable."
        )

        return nil

    end

    return {

        ItemType =
            itemType,

        Type =
            artifactType,

        Service =
            SERVICE_VEHICLE,

    }

end


local function isVehicleRegistrationEnabled()

    local config =
        getArtifactConfig()

    if not config
        or not config.Registration
    then

        return false

    end

    if config.Registration.Enabled == false then

        return false

    end

    if config.Registration.VehicleEnabled == false then

        return false

    end

    return true

end


local function isVehicleClaimEnabled()

    local config =
        getArtifactConfig()

    if not config
        or not config.Claim
    then

        return false

    end

    if config.Claim.Enabled == false then

        return false

    end

    if config.Claim.VehicleEnabled == false then

        return false

    end

    return true

end


function VehArtifactService.CreateVehicleRegistration(
    player
)

    if not player then

        return false,
            "Player unavailable."

    end

    if not isVehicleRegistrationEnabled() then

        return false,
            "Vehicle registration is disabled."

    end

    local definition =
        getVehicleRegistrationDefinition()

    if not definition then

        return false,
            "Vehicle registration configuration is unavailable."

    end

    local record,
        item =
        ArtifactService.CreatePhysicalArtifact(
            player,
            definition.Type,
            definition.Service,
            definition.ItemType,
            nil
        )

    if not record
        or not item
    then

        return false,
            "Unable to create vehicle registration artifact."

    end

    log(
        "Vehicle registration artifact created | " ..
        "id=" ..
        tostring(record.id)
    )

    return true,
        record,
        item

end


function VehArtifactService.RegisterVehicleRegistration(
    player,
    item
)

    if not player then

        return false,
            "Player unavailable."

    end

    if not item then

        return false,
            "Registration item unavailable."

    end

    if not isVehicleRegistrationEnabled() then

        return false,
            "Vehicle registration is disabled."

    end

    local definition =
        getVehicleRegistrationDefinition()

    if not definition then

        return false,
            "Vehicle registration configuration is unavailable."

    end

    if getItemFullType(item) ~=
        definition.ItemType
    then

        return false,
            "Incorrect registration item."

    end

    if getItemArtifactId(item) then

        return false,
            "Registration item is already tracked."

    end

    local record =
        ArtifactService.CreateArtifact(
            player,
            definition.Type,
            definition.Service,
            definition.ItemType,
            nil
        )

    if not record then

        return false,
            "Unable to register vehicle registration item."

    end

    if not setItemArtifactId(
        item,
        record.id
    )
    then

        local data =
            getArtifactData()

        if data then

            data.records[
                record.id
            ] =
                nil

        end

        save()

        return false,
            "Unable to register vehicle registration item."

    end

    save()

    log(
        "Vehicle registration item registered | " ..
        "id=" ..
        tostring(record.id)
    )

    return true,
        record

end


function VehArtifactService.IssueVehicleClaim(
    player,
    registrationScopeId
)

    if not player then

        return false,
            "Player unavailable."

    end

    if not registrationScopeId then

        return false,
            "Registration zone unavailable."

    end

    --------------------------------------------------------
    -- Registration policy.
    --------------------------------------------------------

    if not isVehicleRegistrationEnabled() then

        return false,
            "Vehicle registration is disabled."

    end

    --------------------------------------------------------
    -- Claim policy.
    --------------------------------------------------------

    if not isVehicleClaimEnabled() then

        return false,
            "Vehicle claims are disabled."

    end

    local config =
        getArtifactConfig()

    if not config then

        log(
            "IssueVehicleClaim() FAILED: " ..
            "ArtifactConfig unavailable."
        )

        return false,
            "Artifact configuration unavailable."

    end

    local registrationDefinition =
        getVehicleRegistrationDefinition()

    if not registrationDefinition then

        return false,
            "Vehicle registration is unavailable."

    end

    local claimDefinition =
        getVehicleClaimDefinition()

    if not claimDefinition then

        return false,
            "Vehicle claims are unavailable."

    end

    --------------------------------------------------------
    -- Find and validate registration artifact.
    --
    -- We intentionally do NOT pass registrationScopeId to
    -- ValidateArtifact here.
    --
    -- The registration artifact is a bearer prerequisite.
    -- The authorized computer/zone determines whether the
    -- player is allowed to use it.
    --------------------------------------------------------

    log("Server-side Registration Form validation started.")
    local item,
        record,
        reason =
        ArtifactService.FindValidArtifact(
            player,
            registrationDefinition.ItemType,
            registrationDefinition.Type,
            registrationDefinition.Service
        )

    if not item then

        log("Server-side Registration Form validation FAILED | reason=" .. tostring(reason))
        return false,
            reason

    end

    log("Server-side Registration Form validation PASSED | recordId=" .. tostring(record and record.id))

    --------------------------------------------------------
    -- Create claim artifact FIRST.
    --
    -- This prevents the player from losing the registration
    -- artifact if claim creation fails.
    --------------------------------------------------------

    log("Vehicle Title creation started | itemType=" .. tostring(claimDefinition.ItemType))
    local claimRecord,
        claimItem,
        claimItemDroppedOnGround =
        ArtifactService.CreatePhysicalArtifact(
            player,
            claimDefinition.Type,
            claimDefinition.Service,
            claimDefinition.ItemType,
            registrationScopeId
        )

    if not claimRecord
        or not claimItem
    then

        log("Vehicle Title creation FAILED")
        return false,
            "Unable to issue vehicle claim artifact."

    end

    log("Vehicle Title creation SUCCESS | id=" .. tostring(claimRecord.id))
    log("Vehicle Title inventory deposit | id=" .. tostring(claimRecord.id) .. " | droppedOnGround=" .. tostring(claimItemDroppedOnGround))

    --------------------------------------------------------
    -- Consume registration artifact.
    --------------------------------------------------------

    log("Registration Form consumption started | itemId=" .. tostring(item and item:getFullType()))
    if not ArtifactService.ConsumeArtifactItem(
        player,
        item
    )
    then

        log("Registration Form consumption FAILED")
        ------------------------------------------------
        -- Roll back newly created claim artifact.
        ------------------------------------------------

        log(
            "ERROR: Registration artifact could not " ..
            "be consumed after claim issuance. " ..
            "Rolling back claim artifact."
        )

        local claimData =
            getArtifactData()

        if claimData then

            claimData.records[
                claimRecord.id
            ] =
                nil

        end

        local inventory =
            getPlayerInventory(
                player
            )

        if claimItemDroppedOnGround then

            local square =
                type(player.getSquare) == "function"
                and player:getSquare()

            if square then

                local worldObjects = square:getWorldObjects()
                if worldObjects then
                    for i = 0, worldObjects:size() - 1 do
                        local worldObj = worldObjects:get(i)
                        if worldObj and worldObj:getItem() == claimItem then
                            if type(square.transmitRemoveItemFromSquare) == "function" then
                                square:transmitRemoveItemFromSquare(worldObj)
                            end
                            worldObj:removeFromWorld()
                            worldObj:removeFromSquare()
                            if type(claimItem.setWorldItem) == "function" then
                                claimItem:setWorldItem(nil)
                            end
                            break
                        end
                    end
                end

            end

        elseif inventory then

            inventory:Remove(
                claimItem
            )

        else

            log(
                "ERROR: Could not remove rolled-back " ..
                "claim item because inventory is unavailable."
            )

        end

        save()

        return false,
            "Registration artifact could not be consumed."

    end

    log(
        "Vehicle claim issued | " ..

        "player=" ..
        getPlayerName(player) ..

        " | registrationId=" ..
        tostring(record.id) ..

        " | claimId=" ..
        tostring(claimRecord.id) ..

        " | scope=" ..
        tostring(registrationScopeId)
    )

    log("Transaction SUCCESS | issued claimId=" .. tostring(claimRecord.id))

    return true,
        claimRecord,
        claimItem,
        claimItemDroppedOnGround

end


function VehArtifactService.ValidateVehicleClaim(
    player,
    claimItem,
    targetScopeId
)

    if not player then

        return false,
            "Player unavailable."

    end

    if not targetScopeId then

        return false,
            "Vehicle zone could not be determined."

    end

    if not isVehicleClaimEnabled() then

        return false,
            "Vehicle claims are disabled."

    end

    local config =
        getArtifactConfig()

    if not config then

        return false,
            "Artifact configuration unavailable."

    end

    local definition =
        getVehicleClaimDefinition()

    if not definition then

        return false,
            "Vehicle claims are unavailable."

    end

    if not claimItem then

        return false,
            "Vehicle claim artifact required."

    end

    --------------------------------------------------------
    -- Verify exact physical item type.
    --------------------------------------------------------

    local itemType =
        getItemFullType(
            claimItem
        )

    if itemType ~=
        definition.ItemType
    then

        log(
            "ValidateVehicleClaim() FAILED: " ..
            "incorrect item type."
        )

        return false,
            "Incorrect claim artifact."

    end

    --------------------------------------------------------
    -- Verify artifact ID.
    --------------------------------------------------------

    local artifactId =
        getItemArtifactId(
            claimItem
        )

    if not artifactId then

        log(
            "ValidateVehicleClaim() FAILED: " ..
            "artifact ID missing."
        )

        return false,
            "Invalid claim artifact."

    end

    --------------------------------------------------------
    -- Validate authoritative artifact and exact inventory
    -- possession.
    --------------------------------------------------------

    local valid,
        reason,
        record,
        physicalItem =
        ArtifactService.ValidateArtifact(
            player,
            artifactId,
            definition.Type,
            definition.Service,
            targetScopeId
        )

    if not valid then

        return false,
            reason

    end

    if physicalItem ~= claimItem then

        log(
            "ValidateVehicleClaim() FAILED: " ..
            "claim item is not the authoritative inventory item."
        )

        return false,
            "Invalid claim artifact."

    end

    log(
        "Vehicle claim validated | " ..

        "artifact=" ..
        tostring(artifactId) ..

        " | scope=" ..
        tostring(targetScopeId)
    )

    return true,
        record

end


function VehArtifactService.ConsumeVehicleClaim(
    player,
    claimItem,
    targetScopeId
)

    local valid,
        recordOrReason =
        VehArtifactService.ValidateVehicleClaim(
            player,
            claimItem,
            targetScopeId
        )

    if not valid then

        return false,
            recordOrReason

    end

    local record =
        recordOrReason

    local artifactId =
        record.id

    --------------------------------------------------------
    -- Exact configuration policy:
    --
    -- ArtifactConfig.Consumption.
    --     ConsumeClaimAfterSuccessfulClaim
    --
    -- This service method is explicitly the consumption point,
    -- so the caller should only invoke it after successful
    -- target validation.
    --------------------------------------------------------

    local config =
        getArtifactConfig()

    local consumeClaim =
        true

    if config
        and config.Consumption
        and config.Consumption
            .ConsumeClaimAfterSuccessfulClaim
            == false
    then

        consumeClaim =
            false

    end

    if consumeClaim then

        if not ArtifactService.ConsumeArtifactItem(
            player,
            claimItem
        )
        then

            return false,
                "Claim artifact could not be consumed."

        end

    else

    end

    log(
        "Vehicle claim artifact processed | " ..

        "id=" ..
        tostring(artifactId) ..

        " | scope=" ..
        tostring(targetScopeId) ..

        " | consumed=" ..
        tostring(consumeClaim)
    )

    if not consumeClaim then

        save()

    end

    return true,
        record

end


function VehArtifactService.FindPlayerVehicleClaimArtifact(
    player,
    expectedScopeId
)

    if not isVehicleClaimEnabled() then

        return nil,
            nil,
            "Vehicle claims are disabled."

    end

    local definition =
        getVehicleClaimDefinition()

    if not definition then

        return nil,
            nil,
            "Vehicle claims are unavailable."

    end

    --------------------------------------------------------
    -- expectedScopeId (the target vehicle's dealership zone,
    -- resolved by the caller -- see
    -- KIPN_ClaimService.lua's handleClaimVehicleCommand) lets a
    -- player carrying multiple Vehicle Titles from different lots
    -- be matched against the one actually valid for THIS claim,
    -- instead of whichever unconsumed title is found first.
    -- FindValidArtifact()/ValidateArtifact() already treat a nil
    -- expectedScopeId as "don't filter by scope" -- unchanged
    -- behavior for any caller that omits it.
    --------------------------------------------------------

    return ArtifactService.FindValidArtifact(
        player,
        definition.ItemType,
        definition.Type,
        definition.Service,
        expectedScopeId
    )

end


local function handleIssueVehicleClaimCommand(
    player,
    args
)

    args =
        args or {}

    local computerId =
        args.computerId

    log("Craft Vehicle Title request received | player=" .. getPlayerName(player) .. " | computerId=" .. tostring(computerId))

    if not computerId then

        log("Craft Vehicle Title request FAILED | Computer could not be identified.")
        return false,
            "Computer could not be identified."

    end

    --------------------------------------------------------
    -- APPLICATION AUTHORIZATION
    --
    -- Reuses the ApplicationRegistry discovery/authorization
    -- gate: the computer must carry the DEALERSHIP
    -- classification and vehicle.claim capability.
    --------------------------------------------------------

    local registry =
        KIPN.Server.ApplicationRegistry

    if not registry
        or type(
            registry.IsAvailable
        ) ~= "function"
    then

        log(
            "ERROR: ApplicationRegistry is unavailable."
        )

        return false,
            "Application registry unavailable."

    end

    local steamId =
        KIPN.Shared.GetPlayerId(
            player
        )

    local available,
        availableReason =
        registry.IsAvailable(
            "vehicle_registration",
            {
                steamId = steamId,
                computerId = computerId,
            }
        )

    if not available then

        return false,
            tostring(availableReason)

    end

    --------------------------------------------------------
    -- LOCATE RAW REGISTRATION ITEM
    --------------------------------------------------------

    local definition =
        getVehicleRegistrationDefinition()

    if not definition then

        return false,
            "Vehicle registration configuration is unavailable."

    end

    local rawItem =
        findArtifactItem(
            player,
            definition.ItemType,
            function(item)

                -- Prefer an actual freshly-crafted form. Old
                -- consumed/invalid forms may still exist in saves
                -- created before physical-removal synchronization
                -- was fixed; they must never shadow this item.
                return getItemArtifactId(item) == nil

            end
        )

    if not rawItem then

        ----------------------------------------------------
        -- A previous attempt can legitimately have tagged the
        -- form before a later step failed. Reuse that form only if
        -- its authoritative record remains valid and unconsumed.
        ----------------------------------------------------

        local trackedItem,
            _trackedRecord,
            trackedReason =
            ArtifactService.FindValidArtifact(
                player,
                definition.ItemType,
                definition.Type,
                definition.Service
            )

        if not trackedItem then

            return false,
                trackedReason
                    or "Vehicle registration item required."

        end

        rawItem =
            trackedItem

    end

    --------------------------------------------------------
    -- TAG THE ITEM IF NOT ALREADY TRACKED
    --------------------------------------------------------

    if not getItemArtifactId(rawItem) then

        local tagged,
            tagReason =
            VehArtifactService.RegisterVehicleRegistration(
                player,
                rawItem
            )

        if not tagged then

            return false,
                tagReason

        end

    end

    --------------------------------------------------------
    -- RESOLVE THE COMPUTER'S DEALERSHIP ZONE
    --
    -- GetComputerClassification() already resolves the
    -- computer's current position (supporting both
    -- computer.x/y/z and computer.location.x/y/z) and returns
    -- every zone overlapping it, so this reuses that instead
    -- of re-deriving the computer's position here.
    --------------------------------------------------------

    local worldRegistry =
        KIPN.Server.WorldRegistry

    if not worldRegistry
        or type(
            worldRegistry.GetComputerClassification
        ) ~= "function"
    then

        log(
            "ERROR: WorldRegistry is unavailable."
        )

        return false,
            "World registry unavailable."

    end

    log("Server-side dealership validation started.")
    local classification =
        worldRegistry.GetComputerClassification(
            computerId
        )

    if not classification
        or classification.dealership ~= true
    then

        log("Server-side dealership validation FAILED | classification.dealership is not true")
        return false,
            "This computer is not inside an authorized " ..
            "vehicle dealership zone."

    end

    local dealershipZone

    for _, zone in pairs(
        classification.zones or {}
    ) do

        if zone.type ==
            worldRegistry.ZoneTypes.DEALERSHIP
        then

            dealershipZone =
                zone

            break

        end

    end

    if not dealershipZone then

        log("Server-side dealership validation FAILED | dealershipZone not found in classification zones")
        return false,
            "This computer is not inside an authorized " ..
            "vehicle dealership zone."

    end

    log("Server-side dealership validation PASSED | zoneId=" .. tostring(dealershipZone.id))

    --------------------------------------------------------
    -- ISSUE THE CLAIM ARTIFACT
    --------------------------------------------------------

    local issued,
        resultOrReason,
        _claimItem,
        claimItemDroppedOnGround =
        VehArtifactService.IssueVehicleClaim(
            player,
            dealershipZone.id
        )

    if not issued then

        log("Transaction FAILED | reason=" .. tostring(resultOrReason))
        return false,
            resultOrReason

    end

    log("Transaction SUCCESS | claim artifact issued")

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.VEHICLE_CLAIM_ARTIFACT_ISSUED,
        {

            -- See KIPN_ArtifactService.lua's giveItemToPlayer():
            -- true only if the claim item couldn't fit in the
            -- player's inventory and was dropped on the ground
            -- instead. The client is showing a full-screen terminal
            -- at this exact moment, so the server-side player:Say()
            -- ground-drop notice is invisible -- this lets the
            -- client surface an in-terminal warning instead.
            droppedOnGround =
                claimItemDroppedOnGround == true,

        }
    )

    return true,
        "CLAIM_ARTIFACT_ISSUED"

end


------------------------------------------------------------
-- INITIALIZATION  (driven by KIPN_VehicleServicesInit.lua's RegisterService)
------------------------------------------------------------

function VehArtifactService.Initialize()

    if type(KIPN.Server.RegisterCommandHandler) ~= "function" then
        log("ERROR: RegisterCommandHandler unavailable; " ..
            "IssueVehicleClaim command unreachable.")
        return false
    end

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.ISSUE_VEHICLE_CLAIM,
        handleIssueVehicleClaimCommand
    )

    log("Vehicle Services artifact service initialized.")
    return true
end

print("[KIPN] Vehicle Services Artifact Service loaded")

