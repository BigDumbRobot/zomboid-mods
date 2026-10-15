-- KIPN_GovArtifactService.lua
--
-- Property (Safehouse Deed) + Excavation (Permit) artifact issuance for
-- COMPUTER Safehouse and Land Claims.
--
-- Terminal keeps the authoritative artifact-record store and the generic
-- create / validate / consume / physical-item engine. THIS file owns the
-- Property/Excavation registration-form tagging, the deed/permit issuance
-- and claim renewal command handlers, and the claim-artifact validate/consume/find helpers
-- that KIPN_PropertyClaimService.lua calls. It reaches the store only
-- through Terminal's exported ArtifactService.* API.
--
-- Namespace: KIPN.Server.GovArtifactService (never ArtifactService).

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_ArtifactService"
require "KIPN_GovShared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.GovArtifactService = KIPN.Server.GovArtifactService or {}

local GovArtifactService = KIPN.Server.GovArtifactService

-- Terminal's artifact service -- authoritative store + generic engine.
local ArtifactService = KIPN.Server.ArtifactService

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local function log(message)
    print("[KIPN GOV ARTIFACT SERVICE] " .. tostring(message))
end

------------------------------------------------------------
-- SERVICE KEYS
------------------------------------------------------------

local SERVICE_PROPERTY = "property"
local SERVICE_EXCAVATION = "excavation"

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

------------------------------------------------------------
-- ARTIFACT TYPE REGISTRATION
------------------------------------------------------------
--
-- Populates ArtifactConfig.RegistrationItems / .ClaimItems for the
-- Property + Excavation services.

ArtifactService.RegisterArtifactType("Property", {
    registrationItem = "Base.KIPNPropertyRegistration",
    claimItem        = "Base.KIPNPropertyClaimArtifact",
    zoneClassification = "GOVERNMENT",
})

ArtifactService.RegisterArtifactType("Excavation", {
    registrationItem = "Base.KIPNExcavationRegistration",
    claimItem        = "Base.KIPNExcavationClaimArtifact",
    zoneClassification = "GOVERNMENT",
})

------------------------------------------------------------
-- PROPERTY / EXCAVATION ARTIFACT LOGIC
------------------------------------------------------------


local function getPropertyRegistrationDefinition()

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
        config.RegistrationItems.Property

    if not itemType then

        log(
            "ERROR: ArtifactConfig.RegistrationItems.Property " ..
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
            SERVICE_PROPERTY,

    }

end


local function getPropertyClaimDefinition()

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
        config.ClaimItems.Property

    if not itemType then

        log(
            "ERROR: ArtifactConfig.ClaimItems.Property " ..
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
            SERVICE_PROPERTY,

    }

end


local function isPropertyRegistrationEnabled()

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

    if config.Registration.PropertyEnabled == false then

        return false

    end

    return true

end


local function isPropertyClaimEnabled()

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

    if config.Claim.PropertyEnabled == false then

        return false

    end

    return true

end


local function getExcavationRegistrationDefinition()

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
        config.RegistrationItems.Excavation

    if not itemType then

        log(
            "ERROR: ArtifactConfig.RegistrationItems.Excavation " ..
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
            SERVICE_EXCAVATION,

    }

end


local function getExcavationClaimDefinition()

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
        config.ClaimItems.Excavation

    if not itemType then

        log(
            "ERROR: ArtifactConfig.ClaimItems.Excavation " ..
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
            SERVICE_EXCAVATION,

    }

end


local function isExcavationRegistrationEnabled()

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

    if config.Registration.ExcavationEnabled == false then

        return false

    end

    return true

end


local function isExcavationClaimEnabled()

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

    if config.Claim.ExcavationEnabled == false then

        return false

    end

    return true

end


function GovArtifactService.RegisterPropertyRegistration(
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

    if not isPropertyRegistrationEnabled() then

        return false,
            "Property registration is disabled."

    end

    local definition =
        getPropertyRegistrationDefinition()

    if not definition then

        return false,
            "Property registration configuration is unavailable."

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
            "Unable to register property registration item."

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
            "Unable to register property registration item."

    end

    save()

    log(
        "Property registration item registered | " ..
        "id=" ..
        tostring(record.id)
    )

    return true,
        record

end


function GovArtifactService.RegisterExcavationRegistration(
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

    if not isExcavationRegistrationEnabled() then

        return false,
            "Excavation registration is disabled."

    end

    local definition =
        getExcavationRegistrationDefinition()

    if not definition then

        return false,
            "Excavation registration configuration is unavailable."

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
            "Unable to register excavation registration item."

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
            "Unable to register excavation registration item."

    end

    save()

    log(
        "Excavation registration item registered | " ..
        "id=" ..
        tostring(record.id)
    )

    return true,
        record

end


function GovArtifactService.IssuePropertyClaim(
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

    if not isPropertyRegistrationEnabled() then

        return false,
            "Property registration is disabled."

    end

    --------------------------------------------------------
    -- Claim policy.
    --------------------------------------------------------

    if not isPropertyClaimEnabled() then

        return false,
            "Property claims are disabled."

    end

    local config =
        getArtifactConfig()

    if not config then

        log(
            "IssuePropertyClaim() FAILED: " ..
            "ArtifactConfig unavailable."
        )

        return false,
            "Artifact configuration unavailable."

    end

    local registrationDefinition =
        getPropertyRegistrationDefinition()

    if not registrationDefinition then

        return false,
            "Property registration is unavailable."

    end

    local claimDefinition =
        getPropertyClaimDefinition()

    if not claimDefinition then

        return false,
            "Property claims are unavailable."

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

        return false,
            reason

    end

    --------------------------------------------------------
    -- Create claim artifact FIRST.
    --
    -- This prevents the player from losing the registration
    -- artifact if claim creation fails.
    --------------------------------------------------------

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

        return false,
            "Unable to issue property claim artifact."

    end

    --------------------------------------------------------
    -- Consume registration artifact.
    --------------------------------------------------------

    if not ArtifactService.ConsumeArtifactItem(
        player,
        item
    )
    then

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
        "Property claim issued | " ..

        "player=" ..
        getPlayerName(player) ..

        " | registrationId=" ..
        tostring(record.id) ..

        " | claimId=" ..
        tostring(claimRecord.id) ..

        " | scope=" ..
        tostring(registrationScopeId)
    )

    return true,
        claimRecord,
        claimItem,
        claimItemDroppedOnGround

end


local VALID_EXCAVATION_PERMIT_CLASSES = {
    small = true,
    medium = true,
    large = true,
}


local function normalizeExcavationPermitClass(value)

    if value == nil then
        return nil
    end

    local classId =
        string.lower(
            tostring(value)
        )

    if VALID_EXCAVATION_PERMIT_CLASSES[classId] == true then
        return classId
    end

    return nil

end


local function getExcavationPermitClassFromItemType(itemType)

    if itemType == "Base.KIPNExcavationClaimArtifactSmall" then
        return "small"
    elseif itemType == "Base.KIPNExcavationClaimArtifactMedium" then
        return "medium"
    elseif itemType == "Base.KIPNExcavationClaimArtifactLarge" then
        return "large"
    end

    return nil

end


local function ensureExcavationPermitClassMetadata(
    record,
    claimItem
)

    if type(record) ~= "table" then
        return nil,
            false,
            "Excavation permit record unavailable."
    end

    local metadata =
        type(record.metadata) == "table"
        and record.metadata
        or nil

    local sizeTierData =
        metadata
        and metadata.sizeTier
        or nil

    local classId

    if type(sizeTierData) == "table" then
        classId =
            normalizeExcavationPermitClass(
                sizeTierData.id
                or sizeTierData.classSize
                or sizeTierData.sizeClass
            )
    elseif type(sizeTierData) == "string" then
        classId =
            normalizeExcavationPermitClass(
                sizeTierData
            )
    end

    if not classId and metadata then
        classId =
            normalizeExcavationPermitClass(
                metadata.classSize
                or metadata.sizeTierId
                or metadata.sizeClass
            )
    end

    if not classId then
        classId =
            getExcavationPermitClassFromItemType(
                record.itemType
            )
    end

    if not classId then
        classId =
            getExcavationPermitClassFromItemType(
                getItemFullType(claimItem)
            )
    end

    if not classId then
        return nil,
            false,
            "Excavation permit is missing a valid Small, Medium, or Large class."
    end

    local changed = false

    if type(record.metadata) ~= "table" then
        record.metadata = {}
        metadata = record.metadata
        changed = true
    else
        metadata = record.metadata
    end

    if metadata.classSize ~= classId then
        metadata.classSize = classId
        changed = true
    end

    if metadata.sizeTierId ~= classId then
        metadata.sizeTierId = classId
        changed = true
    end

    if type(metadata.sizeTier) ~= "table" then
        metadata.sizeTier = {
            id = classId,
        }
        changed = true
    elseif metadata.sizeTier.id ~= classId then
        metadata.sizeTier.id = classId
        changed = true
    end

    return classId,
        changed,
        nil

end


function GovArtifactService.IssueExcavationClaim(
    player,
    registrationScopeId,
    sizeTier
)

    if not player then

        return false,
            "Player unavailable."

    end

    if not registrationScopeId then

        return false,
            "Registration zone unavailable."

    end

    if type(sizeTier) ~= "table"
        or not tonumber(sizeTier.widthTiles)
        or not tonumber(sizeTier.heightTiles)
    then

        return false,
            "Excavation claim size unavailable."

    end

    -- The fee must be a real number. A nil / non-numeric price means
    -- ClaimConfig.GetExcavationSizeTierById() handed back a malformed
    -- tier -- issuing the permit anyway would give it away for free
    -- (KIPN_Wallet.Charge() treats amount <= 0 as a no-op success).
    -- A configured price of exactly 0 is allowed (admin "free permit").
    if not tonumber(sizeTier.price)
        or tonumber(sizeTier.price) < 0
    then

        log(
            "IssueExcavationClaim() FAILED: size tier '" ..
            tostring(sizeTier.id) ..
            "' has no valid price (" ..
            tostring(sizeTier.price) ..
            ")."
        )

        return false,
            "Excavation permit pricing is misconfigured on this server."

    end

    local permitClass =
        normalizeExcavationPermitClass(
            sizeTier.id
        )

    if not permitClass then

        log(
            "IssueExcavationClaim() FAILED: invalid permit class '" ..
            tostring(sizeTier.id) .. "'."
        )

        return false,
            "Excavation permit class must be Small, Medium, or Large."

    end

    local tierWidth =
        math.max(
            1,
            math.floor(tonumber(sizeTier.widthTiles))
        )

    local tierHeight =
        math.max(
            1,
            math.floor(tonumber(sizeTier.heightTiles))
        )

    -- Persist the authoritative CLASS identity only. ClaimService maps
    -- this class to the admin-assigned dimensions when land ownership
    -- is claimed. Keeping the class canonical avoids client/display
    -- metadata becoming authoritative.
    local permitSizeMetadata = {

        id = permitClass,

    }

    --------------------------------------------------------
    -- Registration policy.
    --------------------------------------------------------

    if not isExcavationRegistrationEnabled() then

        return false,
            "Excavation registration is disabled."

    end

    --------------------------------------------------------
    -- Claim policy.
    --------------------------------------------------------

    if not isExcavationClaimEnabled() then

        return false,
            "Excavation claims are disabled."

    end

    local config =
        getArtifactConfig()

    if not config then

        log(
            "IssueExcavationClaim() FAILED: " ..
            "ArtifactConfig unavailable."
        )

        return false,
            "Artifact configuration unavailable."

    end

    local registrationDefinition =
        getExcavationRegistrationDefinition()

    if not registrationDefinition then

        return false,
            "Excavation registration is unavailable."

    end

    local claimDefinition =
        getExcavationClaimDefinition()

    if not claimDefinition then

        return false,
            "Excavation claims are unavailable."

    end

    --------------------------------------------------------
    -- Find and validate registration artifact.
    --------------------------------------------------------

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

        return false,
            reason

    end

    --------------------------------------------------------
    -- Create claim artifact FIRST.
    --------------------------------------------------------

    local specificItemType = "Base.KIPNExcavationClaimArtifact"
    if permitClass == "small" then
        specificItemType = "Base.KIPNExcavationClaimArtifactSmall"
    elseif permitClass == "medium" then
        specificItemType = "Base.KIPNExcavationClaimArtifactMedium"
    elseif permitClass == "large" then
        specificItemType = "Base.KIPNExcavationClaimArtifactLarge"
    end

    local claimRecord,
        claimItem,
        claimItemDroppedOnGround =
        ArtifactService.CreatePhysicalArtifact(
            player,
            claimDefinition.Type,
            claimDefinition.Service,
            specificItemType,
            registrationScopeId,
            {
                classSize = permitClass,
                sizeTierId = permitClass,
                sizeTier = permitSizeMetadata,
            }
        )

    if not claimRecord
        or not claimItem
    then

        return false,
            "Unable to issue excavation claim artifact."

    end

    --------------------------------------------------------
    -- SIZE TIER IDENTITY on the physical item.
    --
    -- Tells the client which size class this permit represents
    -- (e.g. "small", "medium", "large"). The client will resolve
    -- the numeric footprint dynamically from its own synchronized
    -- copy of the server configuration for preview drawing.
    --------------------------------------------------------

    local claimItemModData =
        getItemModData(claimItem)

    if claimItemModData then

        claimItemModData.KIPNExcavationSize =
            permitClass

        claimItemModData.KIPNExcavationClassSize =
            permitClass

    end

    local permitDisplayName =
        "Excavation Permit - "
        .. tostring(sizeTier.label or string.upper(sizeTier.id))

    if type(claimItem.setName) == "function" then

        claimItem:setName(permitDisplayName)

    end

    if type(claimItem.setCustomName) == "function" then

        claimItem:setCustomName(true)

    end

    -- CreatePhysicalArtifact() adds the item before the
    -- excavation-specific ModData/name above is applied. Push the
    -- completed item state to the owning client so placement never
    -- falls back to a stale/default size in multiplayer.
    if type(sendItemStats) == "function" then

        sendItemStats(claimItem)

    end

    log(
        "Excavation permit issued | " ..
        "artifact=" .. tostring(claimRecord.id) ..
        " | class=" .. tostring(permitClass) ..
        " | currentAdminDimensions=" ..
        tostring(tierWidth) .. "x" .. tostring(tierHeight)
    )

    --------------------------------------------------------
    -- Consume registration artifact.
    --------------------------------------------------------

    if not ArtifactService.ConsumeArtifactItem(
        player,
        item
    )
    then

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
        "Excavation claim issued | " ..

        "player=" ..
        getPlayerName(player) ..

        " | registrationId=" ..
        tostring(record.id) ..

        " | claimId=" ..
        tostring(claimRecord.id) ..

        " | scope=" ..
        tostring(registrationScopeId)
    )

    return true,
        claimRecord,
        claimItem,
        claimItemDroppedOnGround

end


function GovArtifactService.ValidatePropertyClaim(
    player,
    claimItem,
    targetScopeId
)

    if not player then

        return false,
            "Player unavailable."

    end

    --------------------------------------------------------
    -- targetScopeId is intentionally NOT required here.
    --
    -- Property claims are redeemable on any building, so
    -- KIPN_PropertyClaimService.lua's ValidatePropertyTarget()
    -- resolves no zone and targetScopeId is nil.
    -- ValidateArtifact() treats a nil expectedScopeId as
    -- "don't enforce scope".
    --------------------------------------------------------

    if not isPropertyClaimEnabled() then

        return false,
            "Property claims are disabled."

    end

    local config =
        getArtifactConfig()

    if not config then

        return false,
            "Artifact configuration unavailable."

    end

    local definition =
        getPropertyClaimDefinition()

    if not definition then

        return false,
            "Property claims are unavailable."

    end

    if not claimItem then

        return false,
            "Property claim artifact required."

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
            "ValidatePropertyClaim() FAILED: " ..
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
            "ValidatePropertyClaim() FAILED: " ..
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
            "ValidatePropertyClaim() FAILED: " ..
            "claim item is not the authoritative inventory item."
        )

        return false,
            "Invalid claim artifact."

    end

    log(
        "Property claim validated | " ..

        "artifact=" ..
        tostring(artifactId) ..

        " | scope=" ..
        tostring(targetScopeId)
    )

    return true,
        record

end


function GovArtifactService.ConsumePropertyClaim(
    player,
    claimItem,
    targetScopeId
)

    local valid,
        recordOrReason =
        GovArtifactService.ValidatePropertyClaim(
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
        "Property claim artifact processed | " ..

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


function GovArtifactService.FindPlayerPropertyClaimArtifact(
    player
)

    if not isPropertyClaimEnabled() then

        return nil,
            nil,
            "Property claims are disabled."

    end

    local definition =
        getPropertyClaimDefinition()

    if not definition then

        return nil,
            nil,
            "Property claims are unavailable."

    end

    return ArtifactService.FindValidArtifact(
        player,
        definition.ItemType,
        definition.Type,
        definition.Service
    )

end


function GovArtifactService.ValidateExcavationClaim(
    player,
    claimItem,
    targetScopeId
)

    if not player then

        return false,
            "Player unavailable."

    end

    --------------------------------------------------------
    -- targetScopeId is intentionally NOT required here.
    --
    -- Excavation claims are redeemable on any open land square,
    -- so KIPN_PropertyClaimService.lua's ValidateExcavationTarget()
    -- resolves no zone and targetScopeId is nil (see
    -- ValidatePropertyClaim() above).
    --------------------------------------------------------

    if not isExcavationClaimEnabled() then

        return false,
            "Excavation claims are disabled."

    end

    local config =
        getArtifactConfig()

    if not config then

        return false,
            "Artifact configuration unavailable."

    end

    local definition =
        getExcavationClaimDefinition()

    if not definition then

        return false,
            "Excavation claims are unavailable."

    end

    if not claimItem then

        return false,
            "Excavation claim artifact required."

    end

    --------------------------------------------------------
    -- Verify exact physical item type.
    --------------------------------------------------------

    local itemType =
        getItemFullType(
            claimItem
        )

    local allowedTypes = {
        ["Base.KIPNExcavationClaimArtifactSmall"] = true,
        ["Base.KIPNExcavationClaimArtifactMedium"] = true,
        ["Base.KIPNExcavationClaimArtifactLarge"] = true,
        [definition.ItemType] = true,
    }

    if not allowedTypes[itemType] then

        log(
            "ValidateExcavationClaim() FAILED: " ..
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
            "ValidateExcavationClaim() FAILED: " ..
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
            "ValidateExcavationClaim() FAILED: " ..
            "claim item is not the authoritative inventory item."
        )

        return false,
            "Invalid claim artifact."

    end

    local permitClass,
        metadataChanged,
        classReason =
        ensureExcavationPermitClassMetadata(
            record,
            claimItem
        )

    if not permitClass then

        log(
            "ValidateExcavationClaim() FAILED: " ..
            tostring(classReason)
        )

        return false,
            classReason

    end

    if metadataChanged then

        if not save() then

            log(
                "ValidateExcavationClaim() FAILED: " ..
                "could not persist canonical excavation permit class."
            )

            return false,
                "Excavation permit class could not be persisted."

        end

        log(
            "Excavation permit metadata migrated | " ..
            "artifact=" .. tostring(artifactId) ..
            " | class=" .. tostring(permitClass)
        )

    end

    log(
        "Excavation claim validated | " ..

        "artifact=" ..
        tostring(artifactId) ..

        " | class=" ..
        tostring(permitClass) ..

        " | scope=" ..
        tostring(targetScopeId)
    )

    return true,
        record

end


function GovArtifactService.ConsumeExcavationClaim(
    player,
    claimItem,
    targetScopeId
)

    local valid,
        recordOrReason =
        GovArtifactService.ValidateExcavationClaim(
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
        "Excavation claim artifact processed | " ..

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


function GovArtifactService.FindPlayerExcavationClaimArtifact(
    player
)

    if not isExcavationClaimEnabled() then

        return nil,
            nil,
            "Excavation claims are disabled."

    end

    local definition =
        getExcavationClaimDefinition()

    if not definition then

        return nil,
            nil,
            "Excavation claims are unavailable."

    end

    local allowedTypes = {
        ["Base.KIPNExcavationClaimArtifactSmall"] = true,
        ["Base.KIPNExcavationClaimArtifactMedium"] = true,
        ["Base.KIPNExcavationClaimArtifactLarge"] = true,
        [definition.ItemType] = true,
    }

    local item,
        record,
        reason =
        ArtifactService.FindValidArtifact(
            player,
            allowedTypes,
            definition.Type,
            definition.Service
        )

    if not item then
        return nil,
            nil,
            reason
    end

    local permitClass,
        metadataChanged,
        classReason =
        ensureExcavationPermitClassMetadata(
            record,
            item
        )

    if not permitClass then

        log(
            "FindPlayerExcavationClaimArtifact() FAILED: " ..
            tostring(classReason)
        )

        return nil,
            nil,
            classReason

    end

    if metadataChanged then

        if not save() then

            return nil,
                nil,
                "Excavation permit class could not be persisted."

        end

        log(
            "Excavation permit metadata migrated during lookup | " ..
            "artifact=" .. tostring(record and record.id or "nil") ..
            " | class=" .. tostring(permitClass)
        )

    end

    return item,
        record,
        nil

end


------------------------------------------------------------
-- GOVERNMENT DESK
--
-- Every document exchange (deed, permit, renewal) happens at a
-- powered computer inside a government zone. The application
-- check mirrors what the terminal menu shows; the zone and power
-- checks are re-done here because the client's view is not trusted.
------------------------------------------------------------

local function resolveGovernmentDesk(player, computerId, applicationId, requirePlayerInZone)

    if not computerId then
        return nil, "Computer could not be identified."
    end

    local registry = KIPN.Server.ApplicationRegistry
    if not registry or type(registry.IsAvailable) ~= "function" then
        log("ERROR: ApplicationRegistry is unavailable.")
        return nil, "Application registry unavailable."
    end

    local available, availableReason = registry.IsAvailable(applicationId, {
        steamId = KIPN.Shared.GetPlayerId(player),
        computerId = computerId,
    })
    if not available then
        return nil, tostring(availableReason)
    end

    local worldRegistry = KIPN.Server.WorldRegistry
    if not worldRegistry or type(worldRegistry.GetComputerClassification) ~= "function" then
        log("ERROR: WorldRegistry is unavailable.")
        return nil, "World registry unavailable."
    end

    local classification = worldRegistry.GetComputerClassification(computerId)
    local governmentZone
    if classification and classification.government == true then
        for _, zone in pairs(classification.zones or {}) do
            if zone.type == worldRegistry.ZoneTypes.GOVERNMENT then
                governmentZone = zone
                break
            end
        end
    end
    if not governmentZone then
        return nil, "This computer is not inside an authorized government building zone."
    end

    if requirePlayerInZone then
        local ok, x, y, z = pcall(function()
            return player:getX(), player:getY(), player:getZ()
        end)
        if not ok or x == nil or y == nil then
            log("ERROR: Player position lookup failed: " .. tostring(x))
            return nil, "Player location is unavailable."
        end
        local playerClassification = worldRegistry.GetLocationClassification(
            math.floor(x), math.floor(y), math.floor(z or 0)
        )
        if not playerClassification or playerClassification.government ~= true then
            return nil, "You must be physically inside an authorized government building zone to do this."
        end
    end

    if type(KIPN.Server.CheckBuildingPower) ~= "function" then
        log("ERROR: KIPN.Server.CheckBuildingPower() is unavailable.")
        return nil, "Power check service unavailable."
    end
    if KIPN.Server.CheckBuildingPower(computerId) ~= true then
        return nil, "This computer's square does not currently have power."
    end

    return governmentZone
end

-- Finds the player's registration form of a service and makes sure it
-- is tracked by the artifact engine. Returns the validated item.
local function takeRegistrationForm(player, definition, register, label)

    local rawItem = findArtifactItem(player, definition.ItemType)
    if not rawItem then
        return nil, label .. " required."
    end

    if not getItemArtifactId(rawItem) then
        local tagged, tagReason = register(player, rawItem)
        if not tagged then
            return nil, tagReason
        end
    end

    return rawItem
end

------------------------------------------------------------
-- ISSUE SAFEHOUSE DEED
------------------------------------------------------------

local function handleIssuePropertyClaimCommand(player, args)

    args = args or {}

    local governmentZone, deskReason =
        resolveGovernmentDesk(player, args.computerId, "property_claim", false)
    if not governmentZone then
        return false, deskReason
    end

    local definition = getPropertyRegistrationDefinition()
    if not definition then
        return false, "Property registration configuration is unavailable."
    end

    local form, formReason = takeRegistrationForm(
        player, definition, GovArtifactService.RegisterPropertyRegistration,
        "Property registration item"
    )
    if not form then
        return false, formReason
    end

    local issued, resultOrReason, _claimItem, claimItemDroppedOnGround =
        GovArtifactService.IssuePropertyClaim(player, governmentZone.id)
    if not issued then
        return false, resultOrReason
    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.PROPERTY_CLAIM_ARTIFACT_ISSUED,
        {
            -- The item drops on the ground when the inventory is
            -- full. The terminal covers the player's chat bubble,
            -- so the client shows its own notice for this flag.
            droppedOnGround = claimItemDroppedOnGround == true,
        }
    )

    return true, "CLAIM_ARTIFACT_ISSUED"
end

------------------------------------------------------------
-- BUY EXCAVATION PERMIT
------------------------------------------------------------

local function handleIssueExcavationClaimCommand(player, args)

    args = args or {}

    local governmentZone, deskReason =
        resolveGovernmentDesk(player, args.computerId, "excavation", true)
    if not governmentZone then
        return false, deskReason
    end

    local definition = getExcavationRegistrationDefinition()
    if not definition then
        return false, "Excavation registration configuration is unavailable."
    end

    local form, formReason = takeRegistrationForm(
        player, definition, GovArtifactService.RegisterExcavationRegistration,
        "Excavation registration item"
    )
    if not form then
        return false, formReason
    end

    local claimConfig = KIPN.Server.ClaimConfig
    if not claimConfig or type(claimConfig.GetExcavationSizeTierById) ~= "function" then
        log("ERROR: KIPN.Server.ClaimConfig is unavailable.")
        return false, "Claim configuration unavailable."
    end

    local sizeTier = claimConfig.GetExcavationSizeTierById(args.tierId)
    if not sizeTier then
        return false, "A valid excavation claim size must be selected."
    end

    --------------------------------------------------------
    -- CHARGE THE PURCHASE AMOUNT
    --
    -- Nothing has been consumed yet at this point -- the
    -- registration item was only tagged above, not removed.
    --------------------------------------------------------

    local wallet = KIPN.Server.Wallet
    if not wallet or type(wallet.Charge) ~= "function" then
        log("ERROR: KIPN.Server.Wallet is unavailable.")
        return false, "Claim payment service unavailable."
    end

    -- The fee must resolve to a real number before anything is
    -- charged: KIPN_Wallet.Charge() treats amount <= 0 as a no-op
    -- success, so a nil price would hand out a free permit. A
    -- configured price of exactly 0 is a legitimate free permit.
    local price = tonumber(sizeTier.price)
    if not price or price < 0 then
        log(
            "ERROR: Excavation size tier '" .. tostring(sizeTier.id) ..
            "' has no valid price (" .. tostring(sizeTier.price) ..
            "); refusing to issue a permit."
        )
        return false, "Excavation permit pricing is misconfigured on this server."
    end

    -- Inventory cash only; claim fees never use an external economy
    -- provider balance. See KIPN_Wallet.lua.
    local charged, chargeReason, chargeReceipt = wallet.Charge(player, price)
    if not charged then
        return false,
            (chargeReason == "INSUFFICIENT_CURRENCY" and "Insufficient currency in your inventory.")
            or (chargeReason or "Unable to charge the purchase amount.")
    end

    --------------------------------------------------------
    -- ISSUE THE CLAIM ARTIFACT
    --
    -- The fee is already charged. If issuance fails (e.g.
    -- inventory full) the charge is refunded so the player never
    -- pays for a permit they did not get.
    --------------------------------------------------------

    local issued, resultOrReason, _claimItem, claimItemDroppedOnGround =
        GovArtifactService.IssueExcavationClaim(player, governmentZone.id, sizeTier)

    if not issued then
        log(
            "ERROR: Excavation claim artifact issuance failed after a successful " ..
            "purchase charge. player=" .. getPlayerName(player) ..
            " reason=" .. tostring(resultOrReason)
        )
        if chargeReceipt and type(wallet.Refund) == "function"
            and not wallet.Refund(player, chargeReceipt)
        then
            log(
                "ERROR: refund after failed excavation permit issuance did not " ..
                "complete. player=" .. getPlayerName(player) ..
                " amount=" .. tostring(price)
            )
        end
        return false, resultOrReason
    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.EXCAVATION_CLAIM_ARTIFACT_ISSUED,
        {
            -- See the deed handler's droppedOnGround note.
            droppedOnGround = claimItemDroppedOnGround == true,
        }
    )

    return true, "CLAIM_ARTIFACT_ISSUED"
end

------------------------------------------------------------
-- RENEW CLAIM
--
-- An owner renews a safehouse or excavation claim at a powered
-- government computer by turning in a Registration Form of the
-- matching type. Renewal is allowed at any time while the claim is
-- active and restarts the full ownership period
-- (<Service>OwnershipExpiryDays).
------------------------------------------------------------

local RENEWALS = {
    property = {
        definition = getPropertyRegistrationDefinition,
        enabled = isPropertyRegistrationEnabled,
        register = function(...) return GovArtifactService.RegisterPropertyRegistration(...) end,
        application = "property_claim",
        label = "Safehouse Registration Form",
        required = "A Safehouse Registration Form is required to renew this claim.",
    },
    excavation = {
        definition = getExcavationRegistrationDefinition,
        enabled = isExcavationRegistrationEnabled,
        register = function(...) return GovArtifactService.RegisterExcavationRegistration(...) end,
        application = "excavation",
        label = "Excavation Registration Form",
        required = "An Excavation Registration Form is required to renew this claim.",
    },
}

function GovArtifactService.RenewClaim(player, claimId, computerId)

    local ClaimService = KIPN.Server.ClaimService
    if not ClaimService then
        return false, "Claim service unavailable."
    end

    local claim = ClaimService.GetClaim(claimId)
    if not claim or claim.active == false then
        return false, "That claim no longer exists."
    end

    local steamId = ClaimService.GetPlayerSteamId(player)
    if not steamId or tostring(claim.ownerSteamId) ~= tostring(steamId) then
        return false, "You do not own that claim."
    end

    local renewal = RENEWALS[claim.type]
    if not renewal then
        return false, "This claim cannot be renewed at a government desk."
    end

    if ClaimService.IsClaimExpired(claim) then
        return false, "This claim has already expired."
    end

    local _, deskReason = resolveGovernmentDesk(player, computerId, renewal.application, false)
    if deskReason then
        return false, deskReason
    end

    if not renewal.enabled() then
        return false, "Registration is disabled on this server."
    end

    local definition = renewal.definition()
    if not definition then
        return false, "Registration configuration is unavailable."
    end

    local form, formReason = takeRegistrationForm(
        player, definition, renewal.register, renewal.label
    )
    if not form then
        return false, formReason == renewal.label .. " required." and renewal.required or formReason
    end

    local item, _record, findReason = ArtifactService.FindValidArtifact(
        player, definition.ItemType, definition.Type, definition.Service
    )
    if not item then
        return false, findReason or formReason
    end

    local previousRenewal = claim.lastRenewedAtWorldDays

    local renewed, renewReason = ClaimService.RenewClaim(claim.id)
    if not renewed then
        return false, renewReason
    end

    if not ArtifactService.ConsumeArtifactItem(player, item) then
        claim.lastRenewedAtWorldDays = previousRenewal
        if type(KIPN.Server.Save) == "function" then
            pcall(KIPN.Server.Save, "claims")
        end
        return false, "The registration form could not be processed."
    end

    log(
        "Claim renewed | claim=" .. tostring(claim.id) ..
        " | type=" .. tostring(claim.type) ..
        " | player=" .. getPlayerName(player)
    )

    return true, claim
end

local function handleRenewClaimCommand(player, args)

    args = args or {}

    local renewed, claimOrReason =
        GovArtifactService.RenewClaim(player, args.claimId, args.computerId)
    if not renewed then
        return false, claimOrReason
    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.CLAIM_RENEWED,
        { claimId = claimOrReason.id, type = claimOrReason.type }
    )

    local ClaimService = KIPN.Server.ClaimService
    if type(ClaimService.SendPlayerClaims) == "function" then
        ClaimService.SendPlayerClaims(player, {})
    end

    return true, "CLAIM_RENEWED"
end

------------------------------------------------------------
-- INITIALIZATION  (driven by KIPN_GovServicesInit.lua's RegisterService)
------------------------------------------------------------

function GovArtifactService.Initialize()

    if type(KIPN.Server.RegisterCommandHandler) ~= "function" then
        log("ERROR: RegisterCommandHandler unavailable; " ..
            "IssuePropertyClaim / IssueExcavationClaim commands unreachable.")
        return false
    end

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.ISSUE_PROPERTY_CLAIM,
        handleIssuePropertyClaimCommand
    )

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.ISSUE_EXCAVATION_CLAIM,
        handleIssueExcavationClaimCommand
    )

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.RENEW_CLAIM,
        handleRenewClaimCommand
    )

    log("Government Services artifact service initialized.")
    return true
end

print("[KIPN] Government Services Artifact Service loaded")

