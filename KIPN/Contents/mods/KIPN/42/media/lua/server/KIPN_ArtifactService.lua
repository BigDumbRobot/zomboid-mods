-- KIPN_ArtifactService.lua
--
-- Server-authoritative KIPN artifact lifecycle service.
--
-- Responsibilities:
--   * Create authoritative artifact records.
--   * Track artifact IDs.
--   * Validate physical artifact inventory items.
--   * Validate artifact type and service.
--   * Associate claim artifacts with an authorization scope.
--   * Consume registration artifacts.
--   * Consume claim artifacts.
--   * Issue claim artifacts after successful registration.
--   * Validate claim artifacts before consumption.
--   * Persist artifact state through KIPN server data.
--
-- IMPORTANT:
--
-- Physical inventory items are NOT authoritative.
--
-- The inventory item contains an artifact ID only so that the
-- server can associate the physical item with its authoritative
-- artifact record.
--
-- The server-side artifact record is authoritative for:
--
--     artifact type
--     service
--     scope
--     creation time
--     expiration
--     consumed state
--
-- Artifacts are BEARER ARTIFACTS.
--
-- They are intentionally NOT permanently bound to the Steam ID
-- of the player who created or currently possesses them.
--
-- Possession is established by:
--
--     physical artifact item
--         +
--     authoritative artifact record
--
-- WorldRegistry is authoritative for zone membership.
-- ClaimService is authoritative for ownership.
--
-- Lifecycle:
--
-- Registration Artifact
--     |
--     v
-- Player carries artifact
--     |
--     v
-- Authorized KIPN computer
--     |
--     v
-- WorldRegistry resolves registration zone
--     |
--     v
-- Registration artifact validated
--     |
--     v
-- Registration artifact consumed
--     |
--     v
-- Scoped Claim Artifact issued
--     |
--     v
-- Player approaches eligible target
--     |
--     v
-- WorldRegistry resolves target zone
--     |
--     v
-- Claim artifact validated against target scope
--     |
--     v
-- Claim artifact consumed
--     |
--     v
-- ClaimService establishes ownership
--

if isClient() and not isServer() then
    return
end

require "KIPN/KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

KIPN.Server.ArtifactService =
    KIPN.Server.ArtifactService or {}

local ArtifactService =
    KIPN.Server.ArtifactService

------------------------------------------------------------
-- ADD-ON ARTIFACT TYPE REGISTRATION
------------------------------------------------------------
--
-- Public entry point for a companion service mod to declare its
-- per-service registration + claim item types. Delegates to
-- ArtifactConfig (which owns the item-name tables); the generic
-- artifact engine below is unchanged.
--
--   KIPN.Server.ArtifactService.RegisterArtifactType("House", {
--       registrationItem   = "Base.MyRegistration",
--       claimItem          = "Base.MyDeed",
--       zoneClassification = "GOVERNMENT",
--   })
------------------------------------------------------------

function ArtifactService.RegisterArtifactType(serviceKey, def)

    if KIPN.Server.ArtifactConfig
        and type(KIPN.Server.ArtifactConfig.RegisterArtifactType) == "function"
    then
        return KIPN.Server.ArtifactConfig.RegisterArtifactType(serviceKey, def)
    end

    print(
        "[KIPN ARTIFACT SERVICE] RegisterArtifactType: " ..
        "ArtifactConfig not loaded yet."
    )

    return false
end

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local artifactLoggerObj =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("ArtifactService")
    or nil

local function log(message)

    if artifactLoggerObj then
        artifactLoggerObj:Info(message)
    else
        print(
            "[KIPN ARTIFACT SERVICE] " ..
            tostring(message)
        )
    end

end

------------------------------------------------------------
-- DEPENDENCIES
------------------------------------------------------------

local ArtifactConfig

local function getArtifactConfig()

    --------------------------------------------------------
    -- Cached reference.
    --------------------------------------------------------

    if ArtifactConfig then

        return ArtifactConfig

    end

    --------------------------------------------------------
    -- ArtifactConfig may already have been initialized by
    -- KIPN_Server.
    --------------------------------------------------------

    if KIPN.Server
        and KIPN.Server.ArtifactConfig
    then

        ArtifactConfig =
            KIPN.Server.ArtifactConfig

        return ArtifactConfig

    end

    --------------------------------------------------------
    -- Load the actual artifact configuration module.
    --
    -- IMPORTANT:
    --
    -- KIPN_ArtifactConfig.lua registers itself as:
    --
    --     KIPN.Server.ArtifactConfig
    --
    -- It does NOT need to return the configuration table.
    --------------------------------------------------------

    local ok,
        result =
        pcall(
            require,
            "KIPN/config/KIPN_ArtifactConfig"
        )

    if not ok then

        log(
            "ERROR: Failed to load " ..
            "KIPN_ArtifactConfig: " ..
            tostring(result)
        )

        return nil

    end

    --------------------------------------------------------
    -- Prefer the server registration.
    --------------------------------------------------------

    if KIPN.Server
        and KIPN.Server.ArtifactConfig
    then

        ArtifactConfig =
            KIPN.Server.ArtifactConfig

        return ArtifactConfig

    end

    --------------------------------------------------------
    -- Defensive support for a module that returns a table.
    --
    -- This does not alter the current architecture, but makes
    -- the dependency loader tolerant of a returned config table.
    --------------------------------------------------------

    if type(result) == "table" then

        ArtifactConfig =
            result

        KIPN.Server.ArtifactConfig =
            ArtifactConfig

        return ArtifactConfig

    end

    log(
        "ERROR: KIPN_ArtifactConfig loaded, " ..
        "but no ArtifactConfig was registered."
    )

    return nil

end

------------------------------------------------------------
-- DATA
------------------------------------------------------------

local DATA_KEY =
    "artifacts"

local ARTIFACT_DATA_VERSION =
    1

------------------------------------------------------------
-- SERVICE IDENTIFIERS
------------------------------------------------------------
--
-- KIPN_ArtifactConfig intentionally defines artifact item
-- identifiers and artifact types, but does not define service
-- identifiers.
--
-- Services are therefore represented by stable internal
-- service identifiers.
--
-- These are NOT account credentials.
-- They are NOT Steam IDs.
-- They simply identify which KIPN service the artifact is
-- intended for.
------------------------------------------------------------

------------------------------------------------------------
-- SERVER DATA ACCESS
------------------------------------------------------------

local function getServerData()

    if KIPN.Server
        and type(
            KIPN.Server.GetData
        ) == "function"
    then

        return KIPN.Server.GetData()

    end

    log(
        "ERROR: KIPN.Server.GetData() " ..
        "is unavailable."
    )

    return nil

end

------------------------------------------------------------
-- ARTIFACT DATA INITIALIZATION
------------------------------------------------------------

local function getArtifactData()

    local data =
        getServerData()

    if not data then

        log(
            "ERROR: Server data unavailable."
        )

        return nil

    end

    data[DATA_KEY] =
        data[DATA_KEY] or {}

    local artifactData =
        data[DATA_KEY]

    artifactData.version =
        artifactData.version
        or ARTIFACT_DATA_VERSION

    artifactData.nextId =
        artifactData.nextId
        or 1

    artifactData.records =
        artifactData.records
        or {}

    return artifactData

end

------------------------------------------------------------
-- SAVE
------------------------------------------------------------

local function save()

    if KIPN.Server
        and type(
            KIPN.Server.Save
        ) == "function"
    then

        -- Domain-scoped: only the artifacts tag is persisted +
        -- transmitted. A bare Save() re-broadcasts every KIPN
        -- subsystem tag (claims, computers, accounts, stats, ...)
        -- to every client on an unrelated artifact mutation.
        local ok,
            result =
            pcall(
                KIPN.Server.Save,
                "artifacts"
            )

        if not ok then

            log(
                "ERROR: KIPN.Server.Save() failed: " ..
                tostring(result)
            )

            return false

        end

        return result ~= false

    end

    log(
        "WARNING: KIPN.Server.Save() " ..
        "is unavailable."
    )

    return false

end

------------------------------------------------------------
-- ID GENERATION
------------------------------------------------------------

local function generateArtifactId()

    local data =
        getArtifactData()

    if not data then

        log(
            "ERROR: Unable to access artifact data."
        )

        return nil

    end

    local id =
        tonumber(
            data.nextId
        ) or 1

    data.nextId =
        id + 1

    local artifactId =
        "KIPN-A-" ..
        tostring(id)

    return artifactId

end

------------------------------------------------------------
-- TIME
------------------------------------------------------------

local function getCurrentTimestamp()

    return os.time()

end

------------------------------------------------------------
-- EXPIRATION
------------------------------------------------------------
--
-- Expiration is per-service policy, defined in
-- KIPN_ClaimConfig.lua (ClaimConfig.Services.<Service>), since
-- "service" here ("vehicle"/"property") is the exact same
-- identifier ClaimConfig.ServiceKeyByClaimType maps from.
--
-- A value of 0 means no expiration.
------------------------------------------------------------

local function calculateExpiration(
    artifactType,
    service
)

    local config =
        getArtifactConfig()

    if not config
        or not config.Types
    then

        log(
            "WARNING: ArtifactConfig unavailable. " ..
            "Expiration disabled."
        )

        return 0

    end

    local claimConfig =
        KIPN.Server.ClaimConfig

    if not claimConfig
        or type(
            claimConfig.GetServiceConfig
        ) ~= "function"
    then

        log(
            "WARNING: ClaimConfig unavailable. " ..
            "Expiration disabled."
        )

        return 0

    end

    local serviceConfig =
        claimConfig.GetServiceConfig(
            service
        )

    if not serviceConfig then

        log(
            "WARNING: No service config for service=" ..
            tostring(service) ..
            ". Expiration disabled."
        )

        return 0

    end

    local days = 0

    if artifactType ==
        config.Types.Registration
    then

        days =
            tonumber(
                serviceConfig.RegistrationExpiryDays
            ) or 0

    elseif artifactType ==
        config.Types.Claim
    then

        days =
            tonumber(
                serviceConfig.ClaimTokenExpiryDays
            ) or 0

    end

    if days <= 0 then

        return 0

    end

    local expiration =
        getCurrentTimestamp() +
        (
            days *
            24 *
            60 *
            60
        )

    return expiration

end

------------------------------------------------------------
-- PLAYER NAME
------------------------------------------------------------

local function getPlayerName(player)

    if not player then

        return "unknown"

    end

    if type(
        player.getUsername
    ) == "function"
    then

        return tostring(
            player:getUsername()
        )

    end

    return "unknown"

end

------------------------------------------------------------
-- ITEM TYPE
------------------------------------------------------------

local function getItemFullType(item)

    if not item then

        return nil

    end

    if type(
        item.getFullType
    ) == "function"
    then

        return tostring(
            item:getFullType()
        )

    end

    return nil

end

------------------------------------------------------------
-- ITEM MOD DATA
------------------------------------------------------------

local function getItemModData(item)

    if not item then

        return nil

    end

    if type(
        item.getModData
    ) == "function"
    then

        return item:getModData()

    end

    return nil

end

------------------------------------------------------------
-- WRITE ARTIFACT ID TO ITEM
------------------------------------------------------------

local function setItemArtifactId(
    item,
    artifactId
)

    local modData =
        getItemModData(item)

    if not modData then

        log(
            "ERROR: Unable to access item ModData."
        )

        return false

    end

    modData.KIPNArtifactId =
        tostring(artifactId)

    return true

end

------------------------------------------------------------
-- READ ARTIFACT ID FROM ITEM
------------------------------------------------------------

local function getItemArtifactId(item)

    local modData =
        getItemModData(item)

    if not modData then

        return nil

    end

    if not modData.KIPNArtifactId then

        return nil

    end

    return tostring(
        modData.KIPNArtifactId
    )

end

------------------------------------------------------------
-- PLAYER INVENTORY
------------------------------------------------------------

local function getPlayerInventory(player)

    if not player then

        return nil

    end

    if type(
        player.getInventory
    ) == "function"
    then

        return player:getInventory()

    end

    return nil

end

------------------------------------------------------------
-- FIND FIRST ITEM RECURSE
--
-- Both findArtifactItem() and findArtifactItemById() below need to
-- search inside nested containers (a backpack, a bag) as well as
-- the player's root inventory -- ItemContainer:getItems() only
-- returns a container's own DIRECT contents; PZ's inventory API is
-- intentionally non-recursive at that level (it exposes separate
-- "*Recurse" methods for exactly this reason). A player carrying
-- their crafted Registration/Claim item inside a bag rather than
-- loose on their person would otherwise fail every server-side
-- lookup here even though the client-side button-gating checks
-- (which DO use PZ's recursive helpers, e.g.
-- KIPN_GovernmentServices.lua's containsTypeRecurse()) already told
-- them the action was available -- exactly the "it says I need the
-- item, which I have" symptom reported for vehicle/excavation
-- claims.
--
-- findArtifactItemById() matches on a custom mod-data field, not a
-- plain item type, so it can't use PZ's own type-based
-- getFirstTypeRecurse(); this generic predicate-based walk covers
-- both callers.
------------------------------------------------------------

local function findFirstItemRecurse(
    container,
    matches
)

    if not container then

        return nil

    end

    if type(
        container.getItems
    ) ~= "function"
    then

        return nil

    end

    local items =
        container:getItems()

    if not items then

        return nil

    end

    for i = 0,
        items:size() - 1
    do

        local item =
            items:get(i)

        if item then

            if matches(item) then

                -- Return the container that DIRECTLY holds this
                -- item too (not just the item) -- callers that need
                -- to remove it must call .Remove() on THIS
                -- container, not necessarily the top-level one this
                -- search started from (the item may be nested
                -- inside a bag). See ConsumeArtifactItem() below for
                -- why this matters.
                return item, container

            end

            ----------------------------------------------------
            -- RECURSE INTO NESTED CONTAINER
            --
            -- Not every item exposes getInventory() (only
            -- container-type items like bags do), so this is
            -- pcall-guarded rather than type-checked up front.
            ----------------------------------------------------

            local nestedOk, nestedInventory =
                pcall(
                    function()

                        if type(
                            item.getInventory
                        ) == "function"
                        then

                            return item:getInventory()

                        end

                        return nil

                    end
                )

            if nestedOk
                and nestedInventory
            then

                local found, foundContainer =
                    findFirstItemRecurse(
                        nestedInventory,
                        matches
                    )

                if found then

                    return found, foundContainer

                end

            end

        end

    end

    return nil

end

------------------------------------------------------------
-- FIND ARTIFACT ITEM
------------------------------------------------------------

local function findArtifactItem(
    player,
    expectedItemType,
    extraMatch
)

    local inventory =
        getPlayerInventory(player)

    if not inventory then

        log(
            "ERROR: Player inventory unavailable for " ..
            getPlayerName(player)
        )

        return nil

    end

    return findFirstItemRecurse(
        inventory,
        function(item)

            if getItemFullType(item)
                ~= expectedItemType
            then

                return false
            end

            if extraMatch then

                return extraMatch(item) == true
            end

            return true

        end
    )

end

------------------------------------------------------------
-- FIND ARTIFACT ITEM BY ID
------------------------------------------------------------

local function findArtifactItemById(
    player,
    artifactId
)

    local inventory =
        getPlayerInventory(player)

    if not inventory then

        return nil

    end

    local wantedId =
        tostring(artifactId)

    return findFirstItemRecurse(
        inventory,
        function(item)

            return getItemArtifactId(item)
                == wantedId

        end
    )

end

------------------------------------------------------------
-- CREATE RECORD
------------------------------------------------------------
--
-- Creates ONLY the authoritative artifact record.
--
-- Artifacts are bearer artifacts and therefore are NOT assigned
-- to a Steam ID.
------------------------------------------------------------

function ArtifactService.CreateArtifact(
    player,
    artifactType,
    service,
    itemType,
    scopeId,
    metadata
)

    if not artifactType then

        log(
            "CreateArtifact() FAILED: " ..
            "artifact type missing."
        )

        return nil

    end

    if not service then

        log(
            "CreateArtifact() FAILED: " ..
            "service missing."
        )

        return nil

    end

    if not itemType then

        log(
            "CreateArtifact() FAILED: " ..
            "item type missing."
        )

        return nil

    end

    local data =
        getArtifactData()

    if not data then

        return nil

    end

    local artifactId =
        generateArtifactId()

    if not artifactId then

        return nil

    end

    local now =
        getCurrentTimestamp()

    local record = {

        id =
            artifactId,

        version =
            ARTIFACT_DATA_VERSION,

        type =
            artifactType,

        service =
            service,

        itemType =
            itemType,

        scopeId =
            scopeId,

        createdAt =
            now,

        expiresAt =
            calculateExpiration(
                artifactType,
                service
            ),

        consumed =
            false,

        consumedAt =
            nil,

        metadata =
            metadata,

    }

    data.records[
        artifactId
    ] =
        record

    log(
        "Artifact created | " ..

        "id=" ..
        artifactId ..

        " | type=" ..
        tostring(artifactType) ..

        " | service=" ..
        tostring(service) ..

        " | scope=" ..
        tostring(scopeId)
    )

    return record

end

------------------------------------------------------------
-- GET RECORD
------------------------------------------------------------

function ArtifactService.GetArtifact(
    artifactId
)

    if not artifactId then

        return nil

    end

    local data =
        getArtifactData()

    if not data then

        return nil

    end

    return data.records[
        tostring(artifactId)
    ]

end

------------------------------------------------------------
-- CHECK EXPIRATION
------------------------------------------------------------

function ArtifactService.IsExpired(
    record
)

    if not record then

        return true

    end

    if not record.expiresAt
        or tonumber(
            record.expiresAt
        ) <= 0
    then

        return false

    end

    return
        getCurrentTimestamp() >=
        tonumber(
            record.expiresAt
        )

end

------------------------------------------------------------
-- VALIDATE RECORD
------------------------------------------------------------
--
-- There is intentionally NO Steam ID ownership check.
--
-- Artifacts are bearer credentials.
--
-- Physical possession + authoritative record establish
-- possession.
------------------------------------------------------------

function ArtifactService.ValidateArtifact(
    player,
    artifactId,
    expectedType,
    expectedService,
    expectedScopeId
)

    if not player then

        return false,
            "Player unavailable."

    end

    if not artifactId then

        return false,
            "Artifact ID is missing."

    end

    --------------------------------------------------------
    -- Verify physical possession.
    --------------------------------------------------------

    local physicalItem =
        findArtifactItemById(
            player,
            artifactId
        )

    if not physicalItem then

        log(
            "Validation FAILED: physical artifact " ..
            "is not present in player's inventory."
        )

        return false,
            "Artifact is not in the player's inventory."

    end

    --------------------------------------------------------
    -- Get authoritative record.
    --------------------------------------------------------

    local record =
        ArtifactService.GetArtifact(
            artifactId
        )

    if not record then

        log(
            "Validation FAILED: artifact record " ..
            "not found."
        )

        return false,
            "Artifact record not found."

    end

    --------------------------------------------------------
    -- Verify physical item type.
    --------------------------------------------------------

    if record.itemType then

        local physicalItemType =
            getItemFullType(
                physicalItem
            )

        if physicalItemType ~=
            tostring(
                record.itemType
            )
        then

            log(
                "Validation FAILED: physical item " ..
                "type does not match artifact record."
            )

            return false,
                "Physical artifact does not match its record."

        end

    end

    --------------------------------------------------------
    -- Consumed.
    --------------------------------------------------------

    if record.consumed then

        log(
            "Validation FAILED: artifact already consumed."
        )

        return false,
            "Artifact has already been consumed."

    end

    --------------------------------------------------------
    -- Expiration.
    --------------------------------------------------------

    if ArtifactService.IsExpired(
        record
    )
    then

        log(
            "Validation FAILED: artifact expired."
        )

        return false,
            "Artifact has expired."

    end

    --------------------------------------------------------
    -- Artifact type.
    --------------------------------------------------------

    if expectedType
        and record.type ~=
            expectedType
    then

        log(
            "Validation FAILED: artifact type mismatch."
        )

        return false,
            "Incorrect artifact type."

    end

    --------------------------------------------------------
    -- Service.
    --------------------------------------------------------

    if expectedService
        and record.service ~=
            expectedService
    then

        log(
            "Validation FAILED: service mismatch."
        )

        return false,
            "Artifact is not valid for this service."

    end

    --------------------------------------------------------
    -- Scope.
    --
    -- A claim artifact's scope is the zone in which it can
    -- authorize a claim.
    --------------------------------------------------------

    if expectedScopeId
        and tostring(
            record.scopeId
        ) ~=
            tostring(
                expectedScopeId
            )
    then

        log(
            "Validation FAILED: scope mismatch | " ..

            "artifactScope=" ..
            tostring(
                record.scopeId
            ) ..

            " | expectedScope=" ..
            tostring(
                expectedScopeId
            )
        )

        return false,
            "Artifact is not valid for this zone."

    end

    return true,
        nil,
        record,
        physicalItem

end

------------------------------------------------------------
-- CONSUME RECORD
------------------------------------------------------------

function ArtifactService.ConsumeArtifact(
    artifactId
)

    local record =
        ArtifactService.GetArtifact(
            artifactId
        )

    if not record then

        log(
            "ConsumeArtifact() FAILED: " ..
            "artifact not found."
        )

        return false

    end

    if record.consumed then

        log(
            "ConsumeArtifact() FAILED: " ..
            "artifact already consumed."
        )

        return false

    end

    record.consumed =
        true

    record.consumedAt =
        getCurrentTimestamp()

    log(
        "Artifact consumed | id=" ..
        tostring(artifactId)
    )

    return true

end

------------------------------------------------------------
-- CONSUME INVENTORY ITEM
------------------------------------------------------------

function ArtifactService.ConsumeArtifactItem(
    player,
    item
)

    if not player or not item then

        return false

    end

    local artifactId =
        getItemArtifactId(item)

    if not artifactId then

        log(
            "ConsumeArtifactItem() FAILED: " ..
            "item has no artifact ID."
        )

        return false

    end

    local inventory =
        getPlayerInventory(player)

    if not inventory then

        log(
            "ConsumeArtifactItem() FAILED: " ..
            "player inventory unavailable."
        )

        return false

    end

    --------------------------------------------------------
    -- Verify exact physical inventory item.
    --
    -- inventoryItemContainer is the ItemContainer that DIRECTLY
    -- holds this exact item right now (may be a bag, not the
    -- player's root inventory) -- captured here, from the same
    -- successful search, rather than via a separate
    -- item:getContainer() call further down. That avoids any
    -- chance of the two disagreeing.
    --------------------------------------------------------

    local inventoryItem,
        inventoryItemContainer =
        findArtifactItemById(
            player,
            artifactId
        )

    if not inventoryItem then

        log(
            "ConsumeArtifactItem() FAILED: " ..
            "artifact item is no longer in inventory."
        )

        return false

    end

    if inventoryItem ~= item then

        log(
            "ConsumeArtifactItem() FAILED: " ..
            "supplied item does not match inventory artifact."
        )

        return false

    end

    --------------------------------------------------------
    -- Consume authoritative record.
    --------------------------------------------------------

    if not ArtifactService.ConsumeArtifact(
        artifactId
    )
    then

        return false

    end

    --------------------------------------------------------
    -- Remove physical artifact.
    --
    -- `item` may live inside a bag rather than directly in
    -- `inventory` (the player's root container).
    -- inventory:Remove(item) only removes items that are DIRECT
    -- members of that specific container -- calling it on the
    -- wrong container silently fails to remove a nested item.
    -- inventoryItemContainer (captured above, from the same
    -- successful findArtifactItemById() search that just verified
    -- this exact item) is whichever ItemContainer actually holds it
    -- right now, so removal targets the correct one directly --
    -- falling back to a fresh item:getContainer() lookup, then
    -- finally the player's root inventory, only if that's somehow
    -- unavailable.
    --------------------------------------------------------

    local removalContainer =
        inventoryItemContainer

    if not removalContainer then

        local getContainerOk, resolvedContainer =
            pcall(
                function()

                    if type(item.getContainer) == "function" then

                        return item:getContainer()

                    end

                    return nil

                end
            )

        if getContainerOk and resolvedContainer then

            removalContainer =
                resolvedContainer
        end
    end

    if type(player.removeFromHands) == "function" then

        player:removeFromHands(item)

    end

    removalContainer =
        removalContainer or inventory

    removalContainer:Remove(item)

    --------------------------------------------------------
    -- SYNCHRONIZE THE REMOVAL TO MULTIPLAYER CLIENTS.
    --
    -- ItemContainer:Remove() updates the server-side container,
    -- but it does not by itself send the inventory-removal packet
    -- to the owning client. Without this explicit sync the server
    -- correctly rejects the now-consumed artifact while the stale
    -- physical Registration Form remains visible in the player's
    -- inventory. This is the same Remove() +
    -- sendRemoveItemFromContainer() sequence used by the vanilla
    -- server when it consumes player inventory items.
    --------------------------------------------------------

    sendRemoveItemFromContainer(
        removalContainer,
        item
    )

    --------------------------------------------------------
    -- VERIFY REMOVAL ACTUALLY SUCCEEDED.
    --
    -- Bookkeeping consumption (ArtifactService.ConsumeArtifact()
    -- above) is already committed by this point regardless -- that
    -- is correct: it is the security-relevant half (blocks reuse of
    -- this artifact) and must not be undone just because the
    -- cosmetic physical item failed to disappear. But previously
    -- nothing checked whether the physical removal actually
    -- happened, so a silent failure here (e.g. a stale container
    -- reference) would report "consumed" in the log with the item
    -- still sitting in the player's inventory and no trace of the
    -- problem anywhere. Re-searching for the same artifactId
    -- confirms it either genuinely no longer exists in the player's
    -- inventory, or flags loudly that it does.
    --------------------------------------------------------

    local stillPresent =
        findArtifactItemById(
            player,
            artifactId
        )

    if stillPresent then

        log(
            "ERROR: ConsumeArtifactItem(): physical item " ..
            "removal FAILED -- artifact id=" ..
            tostring(artifactId) ..
            " is marked consumed but still physically present " ..
            "in " ..
            getPlayerName(player) ..
            "'s inventory."
        )

    else

        log(
            "Physical artifact item consumed | " ..
            "id=" ..
            artifactId
        )
    end

    save()

    return true

end

------------------------------------------------------------
-- GIVE ITEM TO PLAYER (INVENTORY, FALLING BACK TO GROUND)
--
-- Adds itemType to the player's inventory. If that fails for
-- any reason (AddItem() errors or returns nil), the item is
-- instead spawned on the ground at the player's current
-- square, so a successful claim transaction never silently
-- produces nothing the player can find.
------------------------------------------------------------

local function giveItemToPlayer(
    player,
    itemType
)

    local inventory =
        getPlayerInventory(player)

    if inventory then

        local ok,
            result =
            pcall(
                function()

                    return inventory:AddItem(
                        itemType
                    )

                end
            )

        if ok and result then

            ------------------------------------------------
            -- MULTIPLAYER INVENTORY SYNC
            --
            -- inventory:AddItem() mutates the authoritative
            -- server container, but clients are not guaranteed to
            -- receive that mutation unless the matching add packet
            -- is sent. Without it, registration can succeed while
            -- the newly-issued Vehicle Title is invisible to the
            -- player until a later inventory resync/reconnect.
            ------------------------------------------------

            if type(sendAddItemToContainer) == "function" then

                sendAddItemToContainer(
                    inventory,
                    result
                )

            end

            return result, false

        end

        if not ok then

            log(
                "giveItemToPlayer(): inventory:AddItem() " ..
                "failed, falling back to ground drop: " ..
                tostring(result)
            )

        end

    end

    --------------------------------------------------------
    -- FALLBACK: DROP ON THE GROUND
    --------------------------------------------------------

    local square =
        type(player.getSquare) == "function"
        and player:getSquare()

    if not square then

        log(
            "giveItemToPlayer(): FAILED - no inventory and " ..
            "no square to drop " ..
            tostring(itemType) ..
            " on."
        )

        return nil

    end

    local item =
        KIPN.Server.CreateItem(itemType)

    if not item then

        log(
            "giveItemToPlayer(): FAILED to create " ..
            tostring(itemType) ..
            " for ground drop."
        )

        return nil

    end

    local droppedOk,
        droppedErr =
        pcall(
            function()

                square:AddWorldInventoryItem(
                    item,
                    0,
                    0,
                    0
                )

            end
        )

    if not droppedOk then

        log(
            "giveItemToPlayer(): FAILED to drop " ..
            tostring(itemType) ..
            " on the ground: " ..
            tostring(droppedErr)
        )

        return nil

    end

    log(
        "giveItemToPlayer(): inventory unavailable/full - " ..
        "dropped " ..
        tostring(itemType) ..
        " on the ground for " ..
        getPlayerName(player)
    )

    --------------------------------------------------------
    -- PLAYER-FACING NOTICE
    --
    -- Previously this fallback was silent to the player -- only a
    -- server log line -- so a successful claim transaction could
    -- report success while the actual item landed on the ground
    -- with no on-screen indication of where to look for it.
    --------------------------------------------------------

    pcall(
        function()

            if player.Say then

                player:Say(
                    "Item could not be added to your "
                    .. "inventory - dropped on the ground "
                    .. "instead."
                )
            end
        end
    )

    return item, true

end

ArtifactService.GiveItemToPlayer =
    giveItemToPlayer


------------------------------------------------------------
-- GENERIC ENGINE API  (for companion service mods)
------------------------------------------------------------
--
-- Terminal owns the authoritative artifact-record store and the
-- generic create / validate / consume / physical-item engine. A
-- companion service that owns an artifact type (KIPN: Government
-- Services -> Property / Excavation) drives its own issuance and
-- claim-consumption flow by calling these. It never touches ModData.

ArtifactService.GetArtifactConfig = getArtifactConfig
ArtifactService.GetArtifactData = getArtifactData
ArtifactService.SaveArtifactData = save
ArtifactService.GetPlayerName = getPlayerName
ArtifactService.GetItemFullType = getItemFullType
ArtifactService.GetItemModData = getItemModData
ArtifactService.SetItemArtifactId = setItemArtifactId
ArtifactService.GetItemArtifactId = getItemArtifactId
ArtifactService.GetPlayerInventory = getPlayerInventory
ArtifactService.FindArtifactItem = findArtifactItem


------------------------------------------------------------
-- CREATE PHYSICAL ARTIFACT
------------------------------------------------------------
--
-- Creates the authoritative record AND adds the corresponding
-- physical item to the player's inventory, falling back to a
-- ground drop (see giveItemToPlayer() above) if the inventory
-- add fails.
--
-- The artifact is NOT assigned to the player.
--
-- The player simply receives the physical bearer artifact.
------------------------------------------------------------

function ArtifactService.CreatePhysicalArtifact(
    player,
    artifactType,
    service,
    itemType,
    scopeId,
    metadata
)

    local inventory =
        getPlayerInventory(player)

    if not inventory then

        log(
            "CreatePhysicalArtifact() FAILED: " ..
            "inventory unavailable."
        )

        return nil

    end

    local record =
        ArtifactService.CreateArtifact(
            player,
            artifactType,
            service,
            itemType,
            scopeId,
            metadata
        )

    if not record then

        return nil

    end

    --------------------------------------------------------
    -- Create physical item (inventory, falling back to a
    -- ground drop -- see giveItemToPlayer() above).
    --------------------------------------------------------

    local item,
        droppedOnGround =
        giveItemToPlayer(
            player,
            itemType
        )

    if not item then

        log(
            "ERROR: Physical artifact item could not " ..
            "be created. Rolling back record."
        )

        local data =
            getArtifactData()

        if data then

            data.records[
                record.id
            ] =
                nil

        end

        save()

        return nil

    end

    --------------------------------------------------------
    -- Associate physical item with authoritative record.
    --------------------------------------------------------

    if not setItemArtifactId(
        item,
        record.id
    )
    then

        log(
            "ERROR: Unable to associate physical item " ..
            "with artifact record."
        )

        --------------------------------------------------
        -- The item may have been given via inventory or
        -- via a ground drop (see giveItemToPlayer() above)
        -- -- only the former is a container Remove().
        --------------------------------------------------

        pcall(
            function()

                if inventory then

                    inventory:Remove(
                        item
                    )

                end

            end
        )

        local data =
            getArtifactData()

        if data then

            data.records[
                record.id
            ] =
                nil

        end

        save()

        return nil

    end

    --------------------------------------------------------
    -- The inventory-add packet above may have been emitted before
    -- the authoritative artifact ID was attached. Push the final
    -- item state as well so the client receives a usable title,
    -- rather than a visually-present but metadata-less item.
    --------------------------------------------------------

    if not droppedOnGround
        and type(sendItemStats) == "function"
    then

        sendItemStats(item)

    end

    log(
        "Physical artifact issued | " ..

        "id=" ..
        record.id ..

        " | item=" ..
        tostring(itemType) ..

        " | scope=" ..
        tostring(scopeId)
    )

    save()

    return record,
        item,
        droppedOnGround

end

------------------------------------------------------------
-- FIND VALID ARTIFACT IN INVENTORY
------------------------------------------------------------

function ArtifactService.FindValidArtifact(
    player,
    expectedItemType,
    expectedType,
    expectedService,
    expectedScopeId
)

    --------------------------------------------------------
    -- When a scope is required, filter candidate items by scope
    -- DURING the search itself, not after picking whichever
    -- matching-type item happens to be found first. A player may
    -- legitimately carry several artifacts of the identical item
    -- type scoped to different zones (e.g. Vehicle Titles from
    -- different dealership lots) -- searching by type alone and
    -- validating scope only afterward would incorrectly reject the
    -- whole search if a WRONG-scope item merely happened to be
    -- found before the correct one.
    --------------------------------------------------------

    local inventory =
        getPlayerInventory(player)

    if not inventory then

        return nil,
            nil,
            "Player inventory is unavailable."

    end

    local matchedRecord =
        nil

    local matchedPhysicalItem =
        nil

    local lastInvalidReason =
        nil

    local sawExpectedType =
        false

    --------------------------------------------------------
    -- Validate every matching physical item until a genuinely
    -- usable one is found. A stale consumed/expired item left by an
    -- older build must not shadow a newly-crafted registration or
    -- a second valid Vehicle Title later in a bag.
    --------------------------------------------------------

    local item =
        findFirstItemRecurse(
            inventory,
            function(candidate)

                local isTypeMatch = false
                local candType = getItemFullType(candidate)
                if type(expectedItemType) == "table" then
                    if expectedItemType[candType] then
                        isTypeMatch = true
                    else
                        for _, t in ipairs(expectedItemType) do
                            if candType == t then
                                isTypeMatch = true
                                break
                            end
                        end
                    end
                elseif candType == expectedItemType then
                    isTypeMatch = true
                end

                if not isTypeMatch then

                    return false

                end

                sawExpectedType =
                    true

                local candidateArtifactId =
                    getItemArtifactId(candidate)

                if not candidateArtifactId then

                    lastInvalidReason =
                        "Artifact is invalid."

                    return false

                end

                local valid,
                    reason,
                    record,
                    physicalItem =
                    ArtifactService.ValidateArtifact(
                        player,
                        candidateArtifactId,
                        expectedType,
                        expectedService,
                        expectedScopeId
                    )

                if not valid then

                    lastInvalidReason =
                        reason

                    return false

                end

                matchedRecord =
                    record

                matchedPhysicalItem =
                    physicalItem

                return true

            end
        )

    if not item then

        return nil,
            nil,
            sawExpectedType
                and (
                    lastInvalidReason
                    or "Artifact is invalid."
                )
                or "Required artifact is not in inventory."

    end

    return
        matchedPhysicalItem or item,
        matchedRecord,
        nil

end

------------------------------------------------------------
-- GET VEHICLE REGISTRATION DEFINITION
------------------------------------------------------------
--
-- Uses the EXACT KIPN_ArtifactConfig schema:
--
--     ArtifactConfig.RegistrationItems.Vehicle
--
-- The artifact type comes from:
--
--     ArtifactConfig.Types.Registration
--
-- The service identifier is defined locally because the
-- configuration schema intentionally does not contain a
-- Service field.
------------------------------------------------------------


------------------------------------------------------------
-- GET VEHICLE CLAIM DEFINITION
------------------------------------------------------------
--
-- Uses the EXACT KIPN_ArtifactConfig schema:
--
--     ArtifactConfig.ClaimItems.Vehicle
--
-- The artifact type comes from:
--
--     ArtifactConfig.Types.Claim
------------------------------------------------------------


------------------------------------------------------------
-- CHECK REGISTRATION POLICY
------------------------------------------------------------


------------------------------------------------------------
-- CHECK CLAIM POLICY
------------------------------------------------------------


------------------------------------------------------------
-- CREATE VEHICLE REGISTRATION ARTIFACT
------------------------------------------------------------
--
-- Convenience wrapper for vehicle registration issuance.
--
-- The caller remains responsible for determining that the
-- player is authorized to receive the registration artifact.
------------------------------------------------------------


------------------------------------------------------------
-- REGISTER (TAG) AN ALREADY-CRAFTED VEHICLE REGISTRATION ITEM
------------------------------------------------------------
--
-- The crafting recipe (KIPN.CreateVehicleRegistration, in
-- KIPN_ArtifactRecipes.txt) produces a plain, untracked
-- Base.KIPNVehicleRegistration item with no artifact ID.
--
-- This is the missing link between "plain crafted item" and
-- "artifact the rest of ArtifactService/ClaimService
-- understands": it creates the authoritative artifact record
-- and tags the EXISTING physical item with it (unlike
-- CreateVehicleRegistration/CreatePhysicalArtifact, which
-- spawns a brand new item).
--
-- Called by the "IssueVehicleClaim" command handler when a
-- player presents a freshly-crafted registration item at an
-- authorized KIPN computer.
------------------------------------------------------------


------------------------------------------------------------
-- ISSUE VEHICLE CLAIM
------------------------------------------------------------
--
-- Server-side operation called after a player successfully
-- presents a Vehicle Registration Artifact at an authorized
-- KIPN computer.
--
-- registrationScopeId is supplied by the caller after
-- WorldRegistry has resolved the authorized computer/zone.
--
-- IMPORTANT:
--
-- The registration artifact is a bearer artifact.
-- It is NOT tied to the player who originally created it.
--
-- The resulting claim artifact is scoped to the registration
-- zone.
------------------------------------------------------------


------------------------------------------------------------
-- VALIDATE VEHICLE CLAIM
------------------------------------------------------------
--
-- Called by the vehicle claim operation.
--
-- targetScopeId MUST be resolved by WorldRegistry from the
-- vehicle being claimed.
--
-- The artifact's stored scope must match the vehicle's current
-- authoritative zone.
------------------------------------------------------------


------------------------------------------------------------
-- CONSUME VEHICLE CLAIM
------------------------------------------------------------
--
-- This consumes the claim artifact only.
--
-- Ownership must be established by ClaimService AFTER this
-- validation/consumption succeeds.
--
-- The caller should perform vehicle-specific validation
-- BEFORE consuming the artifact.
------------------------------------------------------------


------------------------------------------------------------
-- FIND PLAYER'S VEHICLE CLAIM ARTIFACT
------------------------------------------------------------
--
-- Public wrapper used by ClaimService's "ClaimVehicle" command
-- handler to locate whichever valid, unconsumed vehicle claim
-- artifact the player is currently carrying, without ClaimService
-- needing to know the vehicle-claim item type/definition itself.
------------------------------------------------------------


------------------------------------------------------------
-- COMMAND: ISSUE VEHICLE CLAIM
------------------------------------------------------------
--
-- Client -> server entry point for "process registration" at a
-- KIPN computer. Wires together, in one atomic player-facing
-- action:
--
--   1. Authorization: is this computer a Car Dealership with
--      the vehicle.claim capability, and is the player's
--      account/session allowed to use "vehicle_registration"?
--   2. RegisterVehicleRegistration: tag the raw crafted
--      registration item with an authoritative artifact record.
--   3. IssueVehicleClaim: consume the (now-tracked) registration
--      artifact and issue a claim artifact scoped to this
--      computer's dealership zone.
--
-- args.computerId identifies the KIPN computer the player is
-- using; the server resolves everything else (inventory, zone,
-- authorization) itself.
------------------------------------------------------------


------------------------------------------------------------
-- INITIALIZE
------------------------------------------------------------

function ArtifactService.Initialize()

    --------------------------------------------------------
    -- Ensure ArtifactConfig is available.
    --------------------------------------------------------

    local config =
        getArtifactConfig()

    if not config then

        log(
            "ERROR: ArtifactConfig could not " ..
            "be loaded."
        )

        return false

    end

    --------------------------------------------------------
    -- Ensure required configuration tables exist.
    --------------------------------------------------------

    local requiredTables = {

        "RegistrationItems",

        "ClaimItems",

        "Types",

        "Registration",

        "Claim",

        "ZoneValidation",

        "ComputerValidation",

        "TargetValidation",

        "Bearer",

        "Consumption",

        "Duplication",

    }

    for i = 1,
        #requiredTables
    do

        local key =
            requiredTables[i]

        if type(
            config[key]
        ) ~= "table"
        then

            log(
                "ERROR: ArtifactConfig." ..
                key ..
                " is unavailable."
            )

            return false

        end

    end

    --------------------------------------------------------
    -- Validate required vehicle identifiers.
    --------------------------------------------------------

    if not config.RegistrationItems.Vehicle then

        log(
            "ERROR: ArtifactConfig.RegistrationItems.Vehicle " ..
            "is unavailable."
        )

        return false

    end

    if not config.ClaimItems.Vehicle then

        log(
            "ERROR: ArtifactConfig.ClaimItems.Vehicle " ..
            "is unavailable."
        )

        return false

    end

    if not config.Types.Registration then

        log(
            "ERROR: ArtifactConfig.Types.Registration " ..
            "is unavailable."
        )

        return false

    end

    if not config.Types.Claim then

        log(
            "ERROR: ArtifactConfig.Types.Claim " ..
            "is unavailable."
        )

        return false

    end

    --------------------------------------------------------
    -- Initialize artifact data.
    --------------------------------------------------------

    local data =
        getArtifactData()

    if not data then

        log(
            "ERROR: Artifact data could not " ..
            "be initialized."
        )

        return false

    end

    --------------------------------------------------------
    -- Normalize persisted data.
    --------------------------------------------------------

    if type(
        data.version
    ) ~= "number"
    then

        data.version =
            ARTIFACT_DATA_VERSION

    end

    if type(
        data.nextId
    ) ~= "number"
        or data.nextId < 1
    then

        data.nextId =
            1

    end

    if type(
        data.records
    ) ~= "table"
    then

        data.records =
            {}

    end

    --------------------------------------------------------
    -- Future migration point.
    --------------------------------------------------------

    if data.version <
        ARTIFACT_DATA_VERSION
    then

        log(
            "Artifact data migration required | " ..

            "current=" ..
            tostring(data.version) ..

            " | target=" ..
            tostring(ARTIFACT_DATA_VERSION)
        )

        data.version =
            ARTIFACT_DATA_VERSION

    end

    --------------------------------------------------------
    -- Count persisted records.
    --
    -- Do not use #data.records because artifact IDs are
    -- string keys.
    --------------------------------------------------------

    local recordCount =
        0

    for _ in pairs(
        data.records
    ) do

        recordCount =
            recordCount + 1

    end

    log(
        "Artifact data initialized | " ..

        "version=" ..
        tostring(data.version) ..

        " | nextId=" ..
        tostring(data.nextId) ..

        " | records=" ..
        tostring(recordCount)
    )

    --------------------------------------------------------
    -- Report active policy.
    --------------------------------------------------------

    log(
        "Artifact policy | " ..

        "RegistrationEnabled=" ..
        tostring(
            config.Registration.Enabled
        ) ..

        " | ClaimEnabled=" ..
        tostring(
            config.Claim.Enabled
        )
    )

    --------------------------------------------------------
    -- Register command handlers.
    --------------------------------------------------------

    -- No command handlers here any more: every artifact-issuance
    -- command belongs to the service module that owns the type
    -- (KIPN: Government Services / KIPN: Vehicle Services).

    save()

    log(
        "Initialized."
    )

    return true

end
