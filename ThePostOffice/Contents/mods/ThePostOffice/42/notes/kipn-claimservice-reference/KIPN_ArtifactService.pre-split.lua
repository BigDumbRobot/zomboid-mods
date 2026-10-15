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
-- LOGGING
------------------------------------------------------------

local function log(message)

    print(
        "[KIPN ARTIFACT SERVICE] " ..
        tostring(message)
    )

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

local SERVICE_VEHICLE =
    "vehicle"

local SERVICE_PROPERTY =
    "property"

local SERVICE_EXCAVATION =
    "excavation"

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

        local ok,
            result =
            pcall(
                KIPN.Server.Save
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

------------------------------------------------------------
-- CHECK REGISTRATION POLICY
------------------------------------------------------------

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

------------------------------------------------------------
-- CHECK CLAIM POLICY
------------------------------------------------------------

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

------------------------------------------------------------
-- GET PROPERTY REGISTRATION / CLAIM DEFINITIONS
--
-- Mirrors getVehicleRegistrationDefinition() /
-- getVehicleClaimDefinition() against
-- ArtifactConfig.RegistrationItems.Property /
-- ArtifactConfig.ClaimItems.Property.
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

------------------------------------------------------------
-- CHECK PROPERTY REGISTRATION / CLAIM POLICY
------------------------------------------------------------

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

------------------------------------------------------------
-- GET EXCAVATION REGISTRATION / CLAIM DEFINITIONS
--
-- Mirrors getVehicleRegistrationDefinition() /
-- getVehicleClaimDefinition() against
-- ArtifactConfig.RegistrationItems.Excavation /
-- ArtifactConfig.ClaimItems.Excavation.
------------------------------------------------------------

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

------------------------------------------------------------
-- CHECK EXCAVATION REGISTRATION / CLAIM POLICY
------------------------------------------------------------

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

------------------------------------------------------------
-- CREATE VEHICLE REGISTRATION ARTIFACT
------------------------------------------------------------
--
-- Convenience wrapper for vehicle registration issuance.
--
-- The caller remains responsible for determining that the
-- player is authorized to receive the registration artifact.
------------------------------------------------------------

function ArtifactService.CreateVehicleRegistration(
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

function ArtifactService.RegisterVehicleRegistration(
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

------------------------------------------------------------
-- REGISTER (TAG) AN ALREADY-CRAFTED PROPERTY REGISTRATION ITEM
--
-- Mirrors ArtifactService.RegisterVehicleRegistration() for the
-- Property service (Safehouse Deed registration).
------------------------------------------------------------

function ArtifactService.RegisterPropertyRegistration(
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

------------------------------------------------------------
-- REGISTER (TAG) AN ALREADY-CRAFTED EXCAVATION REGISTRATION ITEM
--
-- Mirrors ArtifactService.RegisterVehicleRegistration() for the
-- Excavation service (Excavation Permit registration).
------------------------------------------------------------

function ArtifactService.RegisterExcavationRegistration(
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

function ArtifactService.IssueVehicleClaim(
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

------------------------------------------------------------
-- ISSUE PROPERTY CLAIM
--
-- Mirrors ArtifactService.IssueVehicleClaim() for the Property
-- service. This is the server-authoritative "Craft a Safehouse
-- Deed" operation.
------------------------------------------------------------

function ArtifactService.IssuePropertyClaim(
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

------------------------------------------------------------
-- EXCAVATION PERMIT CLASS NORMALIZATION
------------------------------------------------------------
--
-- Excavation permits carry one authoritative class identity only:
-- small / medium / large. Numeric dimensions belong to ClaimConfig
-- and are resolved by ClaimService when ownership is established.
--
-- The legacy physical item-type fallback below is safe because it is
-- used only after the item has been validated against its authoritative
-- artifact record. Client display name / ModData never establish class.
------------------------------------------------------------

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

------------------------------------------------------------
-- ISSUE EXCAVATION CLAIM
--
-- Mirrors ArtifactService.IssueVehicleClaim() for the
-- Excavation service. This is the server-authoritative "Craft
-- an Excavation Permit" operation.
------------------------------------------------------------

function ArtifactService.IssueExcavationClaim(
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

function ArtifactService.ValidateVehicleClaim(
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

------------------------------------------------------------
-- VALIDATE PROPERTY CLAIM
------------------------------------------------------------
--
-- Mirrors ArtifactService.ValidateVehicleClaim() for the Property
-- service.
------------------------------------------------------------

function ArtifactService.ValidatePropertyClaim(
    player,
    claimItem,
    targetScopeId
)

    if not player then

        return false,
            "Player unavailable."

    end

    --------------------------------------------------------
    -- NOTE -- targetScopeId is intentionally NOT required here.
    --
    -- Property claims are redeemable on any building (see
    -- KIPN_ClaimService.lua's ValidatePropertyTarget(), which no
    -- longer resolves a zone for property claims at all -- so
    -- targetScopeId is always nil for this claim type now).
    -- ValidateArtifact() below already treats a nil expectedScopeId
    -- as "don't enforce scope," which is exactly what property
    -- claims need. Vehicle claims still pass a real, required
    -- scope (the dealership lot) through their own equivalent path
    -- -- this relaxation is property-specific.
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

function ArtifactService.ConsumeVehicleClaim(
    player,
    claimItem,
    targetScopeId
)

    local valid,
        recordOrReason =
        ArtifactService.ValidateVehicleClaim(
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

------------------------------------------------------------
-- CONSUME PROPERTY CLAIM
------------------------------------------------------------
--
-- Mirrors ArtifactService.ConsumeVehicleClaim() for the Property
-- service.
------------------------------------------------------------

function ArtifactService.ConsumePropertyClaim(
    player,
    claimItem,
    targetScopeId
)

    local valid,
        recordOrReason =
        ArtifactService.ValidatePropertyClaim(
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

------------------------------------------------------------
-- FIND PLAYER'S VEHICLE CLAIM ARTIFACT
------------------------------------------------------------
--
-- Public wrapper used by ClaimService's "ClaimVehicle" command
-- handler to locate whichever valid, unconsumed vehicle claim
-- artifact the player is currently carrying, without ClaimService
-- needing to know the vehicle-claim item type/definition itself.
------------------------------------------------------------

function ArtifactService.FindPlayerVehicleClaimArtifact(
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

------------------------------------------------------------
-- FIND PLAYER'S PROPERTY CLAIM ARTIFACT
------------------------------------------------------------
--
-- Mirrors ArtifactService.FindPlayerVehicleClaimArtifact() for
-- the Property service.
------------------------------------------------------------

function ArtifactService.FindPlayerPropertyClaimArtifact(
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

------------------------------------------------------------
-- VALIDATE EXCAVATION CLAIM
------------------------------------------------------------
--
-- Mirrors ArtifactService.ValidatePropertyClaim() for the
-- Excavation service.
------------------------------------------------------------

function ArtifactService.ValidateExcavationClaim(
    player,
    claimItem,
    targetScopeId
)

    if not player then

        return false,
            "Player unavailable."

    end

    --------------------------------------------------------
    -- NOTE -- targetScopeId is intentionally NOT required here.
    --
    -- Excavation claims are redeemable on any open land square
    -- (see KIPN_ClaimService.lua's ValidateExcavationTarget(),
    -- which no longer resolves a zone for excavation claims at all
    -- -- so targetScopeId is always nil for this claim type now).
    -- ValidateArtifact() below already treats a nil expectedScopeId
    -- as "don't enforce scope," matching KIPN_ArtifactService.lua's
    -- ValidatePropertyClaim()'s identical relaxation.
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

------------------------------------------------------------
-- CONSUME EXCAVATION CLAIM
------------------------------------------------------------
--
-- Mirrors ArtifactService.ConsumePropertyClaim() for the
-- Excavation service.
--
-- This consumes the claim artifact only.
--
-- Ownership must be established by ClaimService AFTER this
-- validation/consumption succeeds.
------------------------------------------------------------

function ArtifactService.ConsumeExcavationClaim(
    player,
    claimItem,
    targetScopeId
)

    local valid,
        recordOrReason =
        ArtifactService.ValidateExcavationClaim(
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

------------------------------------------------------------
-- FIND PLAYER'S EXCAVATION CLAIM ARTIFACT
------------------------------------------------------------
--
-- Mirrors ArtifactService.FindPlayerPropertyClaimArtifact() for
-- the Excavation service.
------------------------------------------------------------

function ArtifactService.FindPlayerExcavationClaimArtifact(
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
-- FIND PLAYER'S PO BOX KEY ITEMS
------------------------------------------------------------
--
-- Unlike claim artifacts (which are singular/consumed), a player
-- may legitimately carry multiple PO Box keys for multiple boxes,
-- so this returns ALL matching items, not just the first.
--
-- This does NOT validate against ArtifactService's artifact-record
-- system (ArtifactService.CreateArtifact/ValidateArtifact) -- PO Box
-- keys are not consumable bearer artifacts with an expiry lifecycle,
-- they are simple physical possession tokens. See
-- KIPN_POBoxService.lua for the registry this feeds.
------------------------------------------------------------

function ArtifactService.FindPlayerPOBoxKeyItems(
    player
)

    local inventory =
        getPlayerInventory(
            player
        )

    if not inventory then

        return {}

    end

    local keyItemType =
        KIPN.Server.POBoxConfig
        and KIPN.Server.POBoxConfig.KeyItemType

    if not keyItemType then

        log(
            "FindPlayerPOBoxKeyItems() FAILED: " ..
            "POBoxConfig.KeyItemType unavailable."
        )

        return {}

    end

    local results = {}

    local function scanContainer(container)
        if not container or type(container.getItems) ~= "function" then
            return
        end

        local items = container:getItems()
        if not items then return end

        for i = 0, items:size() - 1 do
            local item = items:get(i)

            if item and getItemFullType(item) == keyItemType then
                local modData = getItemModData(item)
                local boxId = modData and modData.KIPNPOBoxId

                if boxId then
                    results[#results + 1] = {
                        item = item,
                        boxId = tostring(boxId),
                    }
                end
            end

            if item and type(item.getInventory) == "function" then
                local ok, nested = pcall(item.getInventory, item)
                if ok and nested then
                    scanContainer(nested)
                end
            end
        end
    end

    scanContainer(inventory)

    return results

end

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
            ArtifactService.RegisterVehicleRegistration(
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
        ArtifactService.IssueVehicleClaim(
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
-- HANDLE ISSUE PROPERTY CLAIM COMMAND
--
-- Mirrors handleIssueVehicleClaimCommand() for the Property
-- service ("Craft a Safehouse Deed"), gated on the computer's
-- GOVERNMENT zone classification and the "property_claim"
-- application instead of DEALERSHIP/"vehicle_registration".
------------------------------------------------------------

local function handleIssuePropertyClaimCommand(
    player,
    args
)

    args =
        args or {}

    local computerId =
        args.computerId

    if not computerId then

        return false,
            "Computer could not be identified."

    end

    --------------------------------------------------------
    -- APPLICATION AUTHORIZATION
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
            "property_claim",
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
        getPropertyRegistrationDefinition()

    if not definition then

        return false,
            "Property registration configuration is unavailable."

    end

    local rawItem =
        findArtifactItem(
            player,
            definition.ItemType
        )

    if not rawItem then

        return false,
            "Property registration item required."

    end

    --------------------------------------------------------
    -- TAG THE ITEM IF NOT ALREADY TRACKED
    --------------------------------------------------------

    if not getItemArtifactId(rawItem) then

        local tagged,
            tagReason =
            ArtifactService.RegisterPropertyRegistration(
                player,
                rawItem
            )

        if not tagged then

            return false,
                tagReason

        end

    end

    --------------------------------------------------------
    -- RESOLVE THE COMPUTER'S GOVERNMENT ZONE
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

    local classification =
        worldRegistry.GetComputerClassification(
            computerId
        )

    if not classification
        or classification.government ~= true
    then

        return false,
            "This computer is not inside an authorized " ..
            "government building zone."

    end

    local governmentZone

    for _, zone in pairs(
        classification.zones or {}
    ) do

        if zone.type ==
            worldRegistry.ZoneTypes.GOVERNMENT
        then

            governmentZone =
                zone

            break

        end

    end

    if not governmentZone then

        return false,
            "This computer is not inside an authorized " ..
            "government building zone."

    end

    --------------------------------------------------------
    -- ISSUE THE CLAIM ARTIFACT
    --------------------------------------------------------

    local issued,
        resultOrReason,
        _claimItem,
        claimItemDroppedOnGround =
        ArtifactService.IssuePropertyClaim(
            player,
            governmentZone.id
        )

    if not issued then

        return false,
            resultOrReason

    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.PROPERTY_CLAIM_ARTIFACT_ISSUED,
        {

            -- See handleIssueVehicleClaimCommand()'s identical
            -- comment above.
            droppedOnGround =
                claimItemDroppedOnGround == true,

        }
    )

    return true,
        "CLAIM_ARTIFACT_ISSUED"

end

------------------------------------------------------------
-- HANDLE ISSUE EXCAVATION CLAIM COMMAND
--
-- Mirrors handleIssueVehicleClaimCommand() for the Excavation
-- service ("Craft an Excavation Permit"), gated on the
-- computer's GOVERNMENT zone classification and the existing
-- "excavation" application.
------------------------------------------------------------

local function handleIssueExcavationClaimCommand(
    player,
    args
)

    args =
        args or {}

    local computerId =
        args.computerId

    if not computerId then

        return false,
            "Computer could not be identified."

    end

    --------------------------------------------------------
    -- APPLICATION AUTHORIZATION
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
            "excavation",
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
        getExcavationRegistrationDefinition()

    if not definition then

        return false,
            "Excavation registration configuration is unavailable."

    end

    local rawItem =
        findArtifactItem(
            player,
            definition.ItemType
        )

    if not rawItem then

        return false,
            "Excavation registration item required."

    end

    --------------------------------------------------------
    -- TAG THE ITEM IF NOT ALREADY TRACKED
    --------------------------------------------------------

    if not getItemArtifactId(rawItem) then

        local tagged,
            tagReason =
            ArtifactService.RegisterExcavationRegistration(
                player,
                rawItem
            )

        if not tagged then

            return false,
                tagReason

        end

    end

    --------------------------------------------------------
    -- RESOLVE THE COMPUTER'S GOVERNMENT ZONE
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

    local classification =
        worldRegistry.GetComputerClassification(
            computerId
        )

    if not classification
        or classification.government ~= true
    then

        return false,
            "This computer is not inside an authorized " ..
            "government building zone."

    end

    local governmentZone

    for _, zone in pairs(
        classification.zones or {}
    ) do

        if zone.type ==
            worldRegistry.ZoneTypes.GOVERNMENT
        then

            governmentZone =
                zone

            break

        end

    end

    if not governmentZone then

        return false,
            "This computer is not inside an authorized " ..
            "government building zone."

    end

    --------------------------------------------------------
    -- PLAYER MUST BE PHYSICALLY INSIDE THE GOVERNMENT ZONE
    --
    -- The checks above only confirm the COMPUTER's position is
    -- inside a government zone. This confirms the PLAYER's own
    -- live position is too, rather than trusting that proximity
    -- interaction with the computer implies it.
    --------------------------------------------------------

    local playerX
    local playerY
    local playerZ

    local playerPosOk, playerPosError =
        pcall(
            function()

                playerX =
                    player:getX()

                playerY =
                    player:getY()

                playerZ =
                    player:getZ()

            end
        )

    if not playerPosOk
        or playerX == nil
        or playerY == nil
    then

        log(
            "ERROR: Player position lookup failed: " ..
            tostring(playerPosError)
        )

        return false,
            "Player location is unavailable."

    end

    local playerClassification =
        worldRegistry.GetLocationClassification(
            math.floor(playerX),
            math.floor(playerY),
            math.floor(playerZ or 0)
        )

    if not playerClassification
        or playerClassification.government ~= true
    then

        return false,
            "You must be physically inside an authorized " ..
            "government building zone to do this."

    end

    --------------------------------------------------------
    -- LIVE POWER RE-CHECK
    --
    -- The client's terminal-open power gate is a one-time,
    -- client-side check. This re-verifies power at the computer's
    -- square at the moment of issuance, independent of the boot
    -- state machine.
    --------------------------------------------------------

    if type(KIPN.Server.CheckBuildingPower) ~= "function" then

        log(
            "ERROR: KIPN.Server.CheckBuildingPower() is unavailable."
        )

        return false,
            "Power check service unavailable."

    end

    local hasPower =
        KIPN.Server.CheckBuildingPower(
            computerId
        )

    if hasPower ~= true then

        return false,
            "This computer's square does not currently have power."

    end

    --------------------------------------------------------
    -- RESOLVE THE REQUESTED SIZE TIER
    --------------------------------------------------------

    local claimConfig =
        KIPN.Server.ClaimConfig

    if not claimConfig
        or type(
            claimConfig.GetExcavationSizeTierById
        ) ~= "function"
    then

        log(
            "ERROR: KIPN.Server.ClaimConfig is unavailable."
        )

        return false,
            "Claim configuration unavailable."

    end

    local sizeTier =
        claimConfig.GetExcavationSizeTierById(
            args.tierId
        )

    if not sizeTier then

        return false,
            "A valid excavation claim size must be selected."

    end

    --------------------------------------------------------
    -- CHARGE THE PURCHASE AMOUNT
    --
    -- Both conditions (Registration item AND purchase amount) must
    -- be satisfiable before anything is consumed. Nothing has been
    -- consumed yet at this point -- the registration item was only
    -- tagged above, not removed.
    --------------------------------------------------------

    local marketplace =
        KIPN.Server.MarketplaceService

    if not marketplace
        or type(marketplace.ChargePlayer) ~= "function"
    then

        log(
            "ERROR: KIPN.Server.MarketplaceService is unavailable."
        )

        return false,
            "Marketplace service unavailable."

    end

    -- allowVanillaCashFallback=true: if the player has no
    -- marketplace account linked, or their marketplace balance is
    -- zero/insufficient, vanilla physical cash (Base.Money /
    -- Base.MoneyBundle) may fulfil this purchase instead. See
    -- MarketplaceService.ChargePlayer()'s own comment for the
    -- fallback contract.
    local charged,
        chargeReason =
        marketplace.ChargePlayer(
            player,
            sizeTier.price,
            "KIPN Excavation Permit ("
                .. tostring(sizeTier.label)
                .. ")",
            true
        )

    if not charged then

        return false,
            chargeReason
                or "Unable to charge the purchase amount."

    end

    --------------------------------------------------------
    -- ISSUE THE CLAIM ARTIFACT
    --
    -- NOTE: the purchase amount above has already been charged.
    -- If artifact issuance fails past this point (e.g. inventory
    -- full), that charge is NOT automatically refunded -- this
    -- matches the codebase's existing precedent elsewhere (e.g.
    -- ClaimService.ClaimProperty's SafeHouse-creation failure path)
    -- of not reversing a prior successful side effect on a later
    -- failure.
    --------------------------------------------------------

    local issued,
        resultOrReason,
        _claimItem,
        claimItemDroppedOnGround =
        ArtifactService.IssueExcavationClaim(
            player,
            governmentZone.id,
            sizeTier
        )

    if not issued then

        log(
            "ERROR: Excavation claim artifact issuance failed " ..
            "after a successful purchase charge. player=" ..
            getPlayerName(player) ..
            " reason=" ..
            tostring(resultOrReason)
        )

        return false,
            resultOrReason

    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.EXCAVATION_CLAIM_ARTIFACT_ISSUED,
        {

            -- See handleIssueVehicleClaimCommand()'s identical
            -- comment above.
            droppedOnGround =
                claimItemDroppedOnGround == true,

        }
    )

    return true,
        "CLAIM_ARTIFACT_ISSUED"

end

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

        " | VehicleRegistrationEnabled=" ..
        tostring(
            config.Registration.VehicleEnabled
        ) ..

        " | ClaimEnabled=" ..
        tostring(
            config.Claim.Enabled
        ) ..

        " | VehicleClaimEnabled=" ..
        tostring(
            config.Claim.VehicleEnabled
        )
    )

    if KIPN.Server.ClaimConfig
        and type(
            KIPN.Server.ClaimConfig.GetServiceConfig
        ) == "function"
    then

        local vehicleServiceConfig =
            KIPN.Server.ClaimConfig.GetServiceConfig(
                SERVICE_VEHICLE
            )

        if vehicleServiceConfig then

            log(
                "Artifact expiration policy (Vehicle) | " ..

                "RegistrationExpiryDays=" ..
                tostring(
                    vehicleServiceConfig.RegistrationExpiryDays
                ) ..

                " | ClaimTokenExpiryDays=" ..
                tostring(
                    vehicleServiceConfig.ClaimTokenExpiryDays
                )
            )

        end

    end

    --------------------------------------------------------
    -- Register command handlers.
    --------------------------------------------------------

    if type(
        KIPN.Server.RegisterCommandHandler
    ) == "function"
    then

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.ISSUE_VEHICLE_CLAIM,
            handleIssueVehicleClaimCommand
        )

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.ISSUE_PROPERTY_CLAIM,
            handleIssuePropertyClaimCommand
        )

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.ISSUE_EXCAVATION_CLAIM,
            handleIssueExcavationClaimCommand
        )

    else

        log(
            "ERROR: KIPN.Server.RegisterCommandHandler() is " ..
            "unavailable; IssueVehicleClaim/IssuePropertyClaim/" ..
            "IssueExcavationClaim commands will not be reachable."
        )

    end

    save()

    log(
        "Initialized."
    )

    return true

end
