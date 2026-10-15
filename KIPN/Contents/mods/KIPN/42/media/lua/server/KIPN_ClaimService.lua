-- KIPN_ClaimService.lua
--
-- KIPN server-authoritative ownership/claim service.
--
-- Responsibilities:
--   * Validate claim transactions.
--   * Resolve claim targets.
--   * Validate target world location.
--   * Validate WorldRegistry capabilities.
--   * Validate claim artifacts through ArtifactService.
--   * Prevent duplicate ownership.
--   * Establish authoritative ownership.
--   * Persist ownership records.
--   * Provide ownership queries.
--   * Provide safe ownership data to other KIPN services.
--
-- IMPORTANT:
--
-- ArtifactService owns ARTIFACTS.
--
-- WorldRegistry owns WORLD CLASSIFICATION.
--
-- ClaimService owns CLAIM OWNERSHIP.
--
-- Therefore:
--
--   ArtifactService
--          |
--          v
--   "Does this player possess a valid claim artifact?"
--
--   WorldRegistry
--          |
--          v
--   "Is this target currently in a claim-capable location?"
--
--   ClaimService
--          |
--          v
--   "Does this target have an owner?"
--   "Can this player establish ownership?"
--
-- The physical vehicle/item itself is NEVER authoritative
-- for ownership.
--
-- Persistent claim records are authoritative for KIPN ownership
-- metadata and lifecycle. For properties, the paired vanilla SafeHouse is
-- the live engine projection used for protection, geometry, and compatibility.
--
-- Current targets include vehicles, properties, PO boxes, and
-- excavation sites.
--
-- Transaction:
--
--   PLAYER
--      |
--      v
--   CLAIM ARTIFACT
--      |
--      v
--   WORLD REGISTRY
--      |
--      +--> target location
--      +--> vehicle.claim capability
--      |
--      v
--   CLAIM SERVICE
--      |
--      +--> ownership check
--      +--> establish ownership
--      +--> consume artifact
--      |
--      v
--   PERSISTENT CLAIM
--

if isClient() and not isServer() then
    return
end

require "KIPN/KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

KIPN.Server.ClaimService =
    KIPN.Server.ClaimService or {}

local ClaimService =
    KIPN.Server.ClaimService


------------------------------------------------------------
-- DEPENDENCIES
------------------------------------------------------------

local WorldRegistry


------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local logger =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("ClaimService")
    or nil

local function log(message)

    if logger then
        logger:Info(message)
    else
        print(
            "[KIPN CLAIM SERVICE] " ..
            tostring(message)
        )
    end

end


local function logError(message)

    if logger then
        logger:Error(message)
    else
        print(
            "[KIPN CLAIM SERVICE] ERROR: " ..
            tostring(message)
        )
    end

end


------------------------------------------------------------
-- DEPENDENCY: WORLD REGISTRY
------------------------------------------------------------

local function getWorldRegistry()

    if WorldRegistry then

        return WorldRegistry

    end

    if KIPN.Server.WorldRegistry then

        WorldRegistry =
            KIPN.Server.WorldRegistry

        return WorldRegistry

    end

    local ok, result =
        pcall(
            function()

                require "KIPN/KIPN_WorldRegistry"

            end
        )

    if not ok then

        logError(
            "Failed to load WorldRegistry: " ..
            tostring(result)
        )

        return nil

    end

    WorldRegistry =
        KIPN.Server.WorldRegistry

    if not WorldRegistry then

        logError(
            "WorldRegistry unavailable after require."
        )

        return nil

    end

    return WorldRegistry

end


------------------------------------------------------------
-- DATA
------------------------------------------------------------

local DATA_KEY =
    "claims"

local CLAIM_DATA_VERSION =
    2


------------------------------------------------------------
-- CLAIM TYPES  (extensible registry)
------------------------------------------------------------
--
-- Claim types are no longer a fixed enum. Terminal owns the generic
-- claim-record store (create / expire / release / spatial index /
-- GetPlayerClaims); a companion service mod registers each type it
-- owns via ClaimService.RegisterClaimType() -- its target validation,
-- config key, artifact policy, and (optionally) release + enforcement
-- callbacks.
--
--   def = {
--       requiredCapability = "property.claim",  -- world capability
--       serviceConfigKey   = "House",           -- ClaimConfig.Services key
--       label              = "Safehouse",       -- shown in the Records screen
--       validateTarget       = fn(player, args) -> ok, targetData|reason,
--       validateClaimArtifact = fn(...),
--       claim                = fn(player, ...),  -- the Claim<Type>() entry point
--       onClaimReleased      = fn(record),       -- optional
--       enforcement = { canEnter = fn, canBuild = fn, ... },  -- optional
--   }
--
-- Terminal registers no claim types itself: KIPN: Government Services
-- registers `property` + `excavation`, KIPN: Vehicle Services registers
-- `vehicle`. Terminal keeps only the generic core.
------------------------------------------------------------

ClaimService.Types = {}
ClaimService.RequiredCapabilities = {}

-- typeId -> def (see above)
ClaimService.ClaimTypeDefs = {}

function ClaimService.RegisterClaimType(typeId, def)

    if type(typeId) ~= "string"
        or typeId == ""
    then

        logError(
            "RegisterClaimType rejected: invalid type id."
        )

        return false
    end

    def = def or {}

    if ClaimService.ClaimTypeDefs[typeId] then

        -- Already registered (built-in, or a duplicate mod call).
        return true
    end

    def.id = typeId

    ClaimService.ClaimTypeDefs[typeId] = def
    ClaimService.Types[string.upper(typeId)] = typeId

    if type(def.requiredCapability) == "string"
        and def.requiredCapability ~= ""
    then
        ClaimService.RequiredCapabilities[typeId] =
            def.requiredCapability
    end

    log(
        "Registered claim type: " .. typeId
    )

    return true
end

function ClaimService.GetClaimTypeDef(typeId)
    return ClaimService.ClaimTypeDefs[typeId]
end


------------------------------------------------------------
-- SERVER DATA
------------------------------------------------------------

local function getServerData()

    if KIPN.Server
        and type(
            KIPN.Server.GetData
        ) == "function"
    then

        return KIPN.Server.GetData()

    end

    logError(
        "KIPN.Server.GetData() is unavailable."
    )

    return nil

end


------------------------------------------------------------
-- CLAIM DATA
------------------------------------------------------------

local function getClaimData()

    local data =
        getServerData()

    if not data then

        return nil

    end

    if type(
        data[DATA_KEY]
    ) ~= "table"
    then

        data[DATA_KEY] = {}

    end

    local claimData =
        data[DATA_KEY]

    if type(
        claimData.version
    ) ~= "number"
    then

        claimData.version =
            CLAIM_DATA_VERSION

    end

    if type(
        claimData.records
    ) ~= "table"
    then

        claimData.records =
            {}

    end

    if type(
        claimData.byTarget
    ) ~= "table"
    then

        claimData.byTarget =
            {}

    end

    if type(
        claimData.byOwner
    ) ~= "table"
    then

        claimData.byOwner =
            {}

    end

    return claimData

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

        local ok, result =
            pcall(
                KIPN.Server.Save,
                "claims"
            )

        if not ok then

            logError(
                "KIPN.Server.Save() failed: " ..
                tostring(result)
            )

            return false

        end

        return result ~= false

    end

    logError(
        "KIPN.Server.Save() is unavailable."
    )

    return false

end


------------------------------------------------------------
-- WORLD TIME
------------------------------------------------------------

local function getWorldDays()

    local result

    local ok, errorMessage =
        pcall(
            function()

                local gameTime =
                    getGameTime()

                if gameTime
                    and type(
                        gameTime.getWorldAgeHours
                    ) == "function"
                then

                    result =
                        gameTime:getWorldAgeHours()
                        / 24

                end

            end
        )

    if not ok then

        logError(
            "Unable to retrieve world time: " ..
            tostring(errorMessage)
        )

    end

    return result

end


------------------------------------------------------------
-- CALENDAR SNAPSHOT
--
-- Captures a real in-game calendar date/time at claim creation,
-- distinct from getWorldDays()'s day-count. Used so claim
-- records can display a readable date instead of just a day
-- number.
------------------------------------------------------------

local function getCalendarSnapshot()

    local snapshot

    local ok, errorMessage =
        pcall(
            function()

                local gameTime =
                    getGameTime()

                if gameTime then

                    snapshot = {

                        year =
                            gameTime:getYear(),

                        month =
                            gameTime:getMonth(),

                        day =
                            gameTime:getDay(),

                        hour =
                            gameTime:getHour(),

                        minute =
                            gameTime:getMinutes(),

                    }

                end

            end
        )

    if not ok then

        logError(
            "Unable to retrieve calendar snapshot: " ..
            tostring(errorMessage)
        )

    end

    return snapshot

end


------------------------------------------------------------
-- PLAYER IDENTITY
--
-- The owner key of every claim. It is the player's server account
-- (KIPN.Shared.GetPlayerId: "user:<username>" in multiplayer), not
-- the Steam ID, which Lua can only read rounded and which two
-- players can therefore share.
--
-- The function and the claim field keep their historical names
-- (getPlayerSteamId, claim.ownerSteamId) because every claim service
-- and saved record uses them; what they hold is the account key.
-- Records written with the old Steam-based key are re-keyed from
-- their stored ownerUsername when the indexes are rebuilt (see
-- migrateOwnerKey), keeping the old key in legacyOwnerSteamId.
------------------------------------------------------------

local function getPlayerSteamId(player)

    if not player then

        return nil

    end

    if KIPN.Shared
        and type(KIPN.Shared.GetPlayerId) == "function"
    then

        local ok, result =
            pcall(
                KIPN.Shared.GetPlayerId,
                player
            )

        if ok and result ~= nil then

            return tostring(result)

        end

    end

    return nil

end

------------------------------------------------------------
-- PLAYER IDENTITY (PUBLIC)
--
-- Exposes the identity resolution above so other KIPN modules
-- (KIPN_ClaimPermissions.lua's Claim.IsOwner(), the add-on claim
-- services) compare against the SAME key claim.ownerSteamId is
-- written with.
------------------------------------------------------------

function ClaimService.GetPlayerSteamId(player)

    return getPlayerSteamId(player)

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

        local ok, result =
            pcall(
                function()

                    return player:getUsername()

                end
            )

        if ok
            and result ~= nil
        then

            return tostring(result)

        end

    end

    return "unknown"

end


------------------------------------------------------------
-- VEHICLE ID
------------------------------------------------------------

local function getVehicleId(vehicle)

    if not vehicle then

        return nil

    end

    if type(
        vehicle.getId
    ) == "function"
    then

        local ok, result =
            pcall(
                function()

                    return vehicle:getId()

                end
            )

        if ok
            and result ~= nil
        then

            return tostring(result)

        end

    end

    return nil

end


------------------------------------------------------------
-- VEHICLE OWNERSHIP DISPLAY/CLIENT-GATE METADATA
--
-- Claim records remain authoritative. These fields are only a
-- synchronized projection onto the live vehicle so an unmodified
-- client can suppress every outside-vehicle interaction before an
-- unauthorized player starts it. Server-side ClaimPermissions
-- independently enforces the same ownership from the claim record.
------------------------------------------------------------

local VEHICLE_CLAIM_ID_KEY =
    "KIPNVehicleClaimId"

local VEHICLE_OWNER_ID_KEY =
    "KIPNVehicleOwnerSteamId"

local VEHICLE_OWNER_NAME_KEY =
    "KIPNVehicleOwnerUsername"

local function setVehicleOwnershipMetadata(
    vehicle,
    claim
)

    if not vehicle
        or type(vehicle.getModData) ~= "function"
    then

        return false

    end

    local ok, errorMessage =
        pcall(
            function()

                local modData =
                    vehicle:getModData()

                if type(modData) ~= "table" then

                    error("vehicle ModData unavailable")

                end

                local changed =
                    false

                if claim then

                    local claimId =
                        tostring(claim.id)

                    local ownerId =
                        tostring(claim.ownerSteamId)

                    local ownerName =
                        tostring(
                            claim.ownerUsername
                            or "Unknown"
                        )

                    changed =
                        modData[VEHICLE_CLAIM_ID_KEY]
                            ~= claimId
                        or modData[VEHICLE_OWNER_ID_KEY]
                            ~= ownerId
                        or modData[VEHICLE_OWNER_NAME_KEY]
                            ~= ownerName

                    modData[VEHICLE_CLAIM_ID_KEY] =
                        claimId

                    modData[VEHICLE_OWNER_ID_KEY] =
                        ownerId

                    modData[VEHICLE_OWNER_NAME_KEY] =
                        ownerName

                else

                    changed =
                        modData[VEHICLE_CLAIM_ID_KEY] ~= nil
                        or modData[VEHICLE_OWNER_ID_KEY] ~= nil
                        or modData[VEHICLE_OWNER_NAME_KEY] ~= nil

                    modData[VEHICLE_CLAIM_ID_KEY] =
                        nil

                    modData[VEHICLE_OWNER_ID_KEY] =
                        nil

                    modData[VEHICLE_OWNER_NAME_KEY] =
                        nil

                end

                if changed
                    and type(vehicle.transmitModData) == "function"
                then

                    vehicle:transmitModData()

                end

            end
        )

    if not ok then

        logError(
            "Unable to synchronize vehicle ownership metadata: " ..
            tostring(errorMessage)
        )

        return false

    end

    return true

end

function ClaimService.SyncVehicleOwnershipMetadata(
    vehicle,
    claim
)

    return setVehicleOwnershipMetadata(
        vehicle,
        claim
    )

end


------------------------------------------------------------
-- VEHICLE VALIDATION
------------------------------------------------------------

local function isVehicleValid(vehicle)

    if not vehicle then

        return false

    end

    local valid =
        true

    local ok, errorMessage =
        pcall(
            function()

                if type(
                    vehicle.isRemovedFromWorld
                ) == "function"
                and vehicle:isRemovedFromWorld()
                then

                    valid = false

                end

            end
        )

    if not ok then

        logError(
            "Vehicle validity check failed: " ..
            tostring(errorMessage)
        )

        return false

    end

    return valid

end


------------------------------------------------------------
-- VEHICLE SQUARE
------------------------------------------------------------

local function getVehicleSquare(vehicle)

    if not vehicle then

        return nil

    end

    local square

    local ok, errorMessage =
        pcall(
            function()

                if type(
                    vehicle.getSquare
                ) == "function"
                then

                    square =
                        vehicle:getSquare()

                end

            end
        )

    if not ok then

        logError(
            "Vehicle square lookup failed: " ..
            tostring(errorMessage)
        )

        return nil

    end

    return square

end


------------------------------------------------------------
-- VEHICLE POSITION
------------------------------------------------------------

local function getVehiclePosition(vehicle)

    local square =
        getVehicleSquare(
            vehicle
        )

    if not square then

        logError(
            "Vehicle square unavailable."
        )

        return nil

    end

    local x
    local y
    local z

    local ok, errorMessage =
        pcall(
            function()

                x =
                    square:getX()

                y =
                    square:getY()

                z =
                    square:getZ()

            end
        )

    if not ok then

        logError(
            "Vehicle position lookup failed: " ..
            tostring(errorMessage)
        )

        return nil

    end

    if x == nil
        or y == nil
    then

        logError(
            "Vehicle position unavailable."
        )

        return nil

    end

    return {

        x = x,

        y = y,

        z = z or 0,

    }

end


------------------------------------------------------------
-- PLAYER POSITION
------------------------------------------------------------
--
-- Properties have no discrete game object like a vehicle to
-- resolve a position from, so this reads the player's own
-- current tile position directly (player:getX()/getY()/getZ(),
-- the same accessors KIPN_Terminal.lua already uses for proximity
-- checks).
------------------------------------------------------------

local function getPlayerPosition(player)

    if not player then

        return nil

    end

    local x
    local y
    local z

    local ok, errorMessage =
        pcall(
            function()

                x =
                    player:getX()

                y =
                    player:getY()

                z =
                    player:getZ()

            end
        )

    if not ok then

        logError(
            "Player position lookup failed: " ..
            tostring(errorMessage)
        )

        return nil

    end

    if x == nil
        or y == nil
    then

        logError(
            "Player position unavailable."
        )

        return nil

    end

    return {

        x = math.floor(x),

        y = math.floor(y),

        z = math.floor(z or 0),

    }

end


------------------------------------------------------------
-- SQUARE LOOKUP
------------------------------------------------------------
--
-- Generic (x, y, z) -> IsoGridSquare resolver, shared by the
-- building-interior and excavation-terrain checks below.
------------------------------------------------------------

local function getSquare(
    x,
    y,
    z
)

    if x == nil
        or y == nil
    then

        return nil

    end

    local square

    local ok, errorMessage =
        pcall(
            function()

                local cell =
                    getCell()

                if cell then

                    square =
                        cell:getGridSquare(
                            math.floor(x),
                            math.floor(y),
                            math.floor(z or 0)
                        )

                end

            end
        )

    if not ok then

        logError(
            "Square lookup failed: " ..
            tostring(errorMessage)
        )

        return nil

    end

    return square

end


------------------------------------------------------------
-- CLAIM CONFIG
------------------------------------------------------------

local function getClaimConfig()

    if KIPN.Server
        and KIPN.Server.ClaimConfig
    then

        return KIPN.Server.ClaimConfig

    end

    logError(
        "KIPN.Server.ClaimConfig is unavailable."
    )

    return nil

end


------------------------------------------------------------
-- MAX CLAIMS PER PLAYER (PER SERVICE)
------------------------------------------------------------
--
-- Each claim service (Vehicle / House / Excavation) has its own
-- MaxClaimsPerPlayer quota.
--
-- This is intentionally generic over claimType so future
-- claim services reuse it exactly as ClaimVehicle does today.
------------------------------------------------------------

local function checkMaxClaimsForType(
    player,
    claimType
)

    local claimConfig =
        getClaimConfig()

    if not claimConfig then

        return false,
            "Claim configuration unavailable."

    end

    local serviceConfig =
        claimConfig.GetServiceConfig(
            claimType
        )

    if not serviceConfig then

        logError(
            "checkMaxClaimsForType() FAILED: " ..
            "no service config for claimType=" ..
            tostring(claimType)
        )

        return false,
            "Unsupported claim type."

    end

    local maxClaims =
        tonumber(
            serviceConfig.MaxClaimsPerPlayer
        )

    if not maxClaims
        or maxClaims <= 0
    then

        --------------------------------------------------------
        -- 0/invalid means unlimited.
        --------------------------------------------------------

        return true,
            nil

    end

    local existingClaims =
        ClaimService.GetPlayerClaims(
            player
        )

    local count =
        0

    for _, claim in pairs(
        existingClaims
    ) do

        if claim.type == claimType then

            count =
                count + 1

        end

    end

    if count >= maxClaims then

        log(
            "checkMaxClaimsForType() FAILED: " ..
            "player at/above quota | type=" ..
            tostring(claimType) ..
            " | count=" ..
            tostring(count) ..
            " | max=" ..
            tostring(maxClaims)
        )

        return false,
            "You have reached the maximum number of " ..
            "claims for this service."

    end

    return true,
        nil

end


------------------------------------------------------------
-- CLAIM ID
------------------------------------------------------------

local function generateClaimId(
    claimType,
    targetId
)

    local claimData =
        getClaimData()

    if not claimData then

        return nil

    end

    local timestamp =
        os.time()

    local randomPart

    if type(ZombRand) ==
        "function"
    then

        randomPart =
            ZombRand(
                100000,
                999999
            )

    else

        randomPart =
            math.random(
                100000,
                999999
            )

    end

    local claimId

    repeat

        claimId =
            "CLAIM-" ..
            tostring(claimType) ..
            "-" ..
            tostring(targetId) ..
            "-" ..
            tostring(timestamp) ..
            "-" ..
            tostring(randomPart)

        if claimData.records[
            claimId
        ]
        then

            if type(ZombRand) ==
                "function"
            then

                randomPart =
                    ZombRand(
                        100000,
                        999999
                    )

            else

                randomPart =
                    math.random(
                        100000,
                        999999
                    )

            end

        end

    until not claimData.records[
        claimId
    ]

    return claimId

end


------------------------------------------------------------
-- IS CLAIM EXPIRED (OWNERSHIP EXPIRY)
------------------------------------------------------------
--
-- Lazy expiry check, mirroring KIPN_TokenServer.lua's
-- TokenIsExpired() pattern: this does NOT mutate claim state.
-- Callers that need the mutation (release the claim) call
-- ClaimService.ReleaseClaim() separately.
--
-- OwnershipExpiryDays == 0 means the claim never expires
-- (the Vehicle service default, since cars decay on their own).
------------------------------------------------------------

function ClaimService.IsClaimExpired(
    claim
)

    if type(claim) ~= "table" then

        return false

    end

    if claim.active == false then

        return false

    end

    local claimConfig =
        getClaimConfig()

    if not claimConfig then

        return false

    end

    local serviceConfig =
        claimConfig.GetServiceConfig(
            claim.type
        )

    if not serviceConfig then

        return false

    end

    local ownershipExpiryDays =
        tonumber(
            serviceConfig.OwnershipExpiryDays
        )

    if not ownershipExpiryDays
        or ownershipExpiryDays <= 0
    then

        return false

    end

    local anchorDays =
        tonumber(
            claim.lastRenewedAtWorldDays
        )
        or tonumber(
            claim.createdAtWorldDays
        )

    if not anchorDays then

        return false

    end

    local nowDays =
        getWorldDays()

    if not nowDays then

        return false

    end

    return (nowDays - anchorDays)
        >= ownershipExpiryDays

end


------------------------------------------------------------
-- RENEW CLAIM
------------------------------------------------------------
--
-- Resets the ownership-expiry clock for a claim.
--
-- Called by service mods' renewal flows (COMPUTER Safehouse and
-- Land Claims: RENEW_CLAIM at a government computer).
------------------------------------------------------------

function ClaimService.RenewClaim(
    claimId
)

    local claim =
        ClaimService.GetClaim(
            claimId
        )

    if not claim then

        return false,
            "Claim not found."

    end

    if claim.active == false then

        return false,
            "Claim is not active."

    end

    local previousRenewedAt =
        claim.lastRenewedAtWorldDays

    claim.lastRenewedAtWorldDays =
        getWorldDays()

    local saved =
        save()

    if not saved then

        claim.lastRenewedAtWorldDays =
            previousRenewedAt

        return false,
            "Claim renewal could not be persisted."

    end

    log(
        "Claim renewed | id=" ..
        tostring(claimId)
    )

    return true,
        nil

end


------------------------------------------------------------
-- GET CLAIM
------------------------------------------------------------

function ClaimService.GetClaim(
    claimId
)

    if not claimId then

        return nil

    end

    local claimData =
        getClaimData()

    if not claimData then

        return nil

    end

    return claimData.records[
        tostring(claimId)
    ]

end


------------------------------------------------------------
-- GET CLAIM FOR TARGET
------------------------------------------------------------
--
-- Only ACTIVE claims represent current ownership.
--
-- This is important because released claims remain in the
-- historical records table.
------------------------------------------------------------

function ClaimService.GetClaimForTarget(
    claimType,
    targetId
)

    if not claimType
        or targetId == nil
    then

        return nil

    end

    local claimData =
        getClaimData()

    if not claimData then

        return nil

    end

    local key =
        tostring(claimType) ..
        ":" ..
        tostring(targetId)

    local claimId =
        claimData.byTarget[
            key
        ]

    if not claimId then

        return nil

    end

    local claim =
        claimData.records[
            claimId
        ]

    --------------------------------------------------------
    -- Repair stale target index.
    --------------------------------------------------------

    if not claim then

        claimData.byTarget[
            key
        ] =
            nil

        return nil

    end

    --------------------------------------------------------
    -- Inactive claims are historical records and do not
    -- represent current ownership.
    --------------------------------------------------------

    if claim.active == false then

        claimData.byTarget[
            key
        ] =
            nil

        return nil

    end

    --------------------------------------------------------
    -- Ownership expiry (lazy check).
    --------------------------------------------------------

    if ClaimService.IsClaimExpired(
        claim
    ) then

        log(
            "Claim ownership expired | key=" ..
            key ..
            " | claim=" ..
            tostring(claimId)
        )

        ClaimService.ReleaseClaim(
            claimId,
            "ownership_expired"
        )

        return nil

    end

    return claim

end


------------------------------------------------------------
-- CHECK TARGET OWNERSHIP
------------------------------------------------------------

function ClaimService.IsTargetClaimed(
    claimType,
    targetId
)

    return
        ClaimService.GetClaimForTarget(
            claimType,
            targetId
        ) ~= nil

end


------------------------------------------------------------
-- GET OWNER
------------------------------------------------------------

function ClaimService.GetTargetOwner(
    claimType,
    targetId
)

    local claim =
        ClaimService.GetClaimForTarget(
            claimType,
            targetId
        )

    if not claim then

        return nil

    end

    return claim.ownerSteamId

end


------------------------------------------------------------
-- CHECK WORLD CAPABILITY
------------------------------------------------------------

local function hasClaimCapability(
    position,
    claimType
)

    if not position then

        return false,
            "Target position unavailable."

    end

    local registry =
        getWorldRegistry()

    if not registry then

        return false,
            "World Registry unavailable."

    end

    local requiredCapability =
        ClaimService.RequiredCapabilities[
            claimType
        ]

    if not requiredCapability then

        return false,
            "Unsupported claim type."

    end

    if type(
        registry.GetLocationCapabilities
    ) ~= "function"
    then

        logError(
            "WorldRegistry.GetLocationCapabilities() " ..
            "is unavailable."
        )

        return false,
            "World Registry capability service unavailable."

    end

    local capabilities

    local ok, errorMessage =
        pcall(
            function()

                capabilities =
                    registry.GetLocationCapabilities(
                        position.x,
                        position.y,
                        position.z
                    )

            end
        )

    if not ok then

        logError(
            "WorldRegistry capability lookup failed: " ..
            tostring(errorMessage)
        )

        return false,
            "Unable to resolve world capabilities."

    end

    if type(capabilities) ~=
        "table"
    then

        return false,
            "World location capabilities unavailable."

    end

    if capabilities[
        requiredCapability
    ] ~= true
    then

        return false,
            "This location does not support this claim."

    end

    return true,
        nil

end


------------------------------------------------------------
-- GET CLAIM ZONE
------------------------------------------------------------

local function getClaimZone(
    position,
    claimType
)

    if not position then

        return nil

    end

    local registry =
        getWorldRegistry()

    if not registry then

        return nil

    end

    local requiredCapability =
        ClaimService.RequiredCapabilities[
            claimType
        ]

    if not requiredCapability then

        return nil

    end

    if type(
        registry.GetZonesAtPosition
    ) ~= "function"
    then

        logError(
            "WorldRegistry.GetZonesAtPosition() " ..
            "is unavailable."
        )

        return nil

    end

    local zones

    local ok, errorMessage =
        pcall(
            function()

                zones =
                    registry.GetZonesAtPosition(
                        position.x,
                        position.y,
                        position.z
                    )

            end
        )

    if not ok then

        logError(
            "WorldRegistry zone lookup failed: " ..
            tostring(errorMessage)
        )

        return nil

    end

    if type(zones) ~=
        "table"
    then

        return nil

    end

    if type(
        registry.GetZoneCapabilities
    ) ~= "function"
    then

        logError(
            "WorldRegistry.GetZoneCapabilities() " ..
            "is unavailable."
        )

        return nil

    end

    for zoneId, zone in pairs(
        zones
    ) do

        local capabilities

        local capabilityOk =
            pcall(
                function()

                    capabilities =
                        registry.GetZoneCapabilities(
                            zone
                        )

                end
            )

        if capabilityOk
            and type(capabilities) ==
                "table"
            and capabilities[
                requiredCapability
            ] == true
        then

            return zone,
                zoneId

        end

    end

    return nil

end


------------------------------------------------------------
-- PROPERTY TARGET ID
------------------------------------------------------------
--
-- New property records are keyed to the vanilla SafeHouse ID when
-- available, with the complete rectangle as a deterministic
-- fallback. This lets every tile in one building resolve to the
-- same target and allows an existing owner-matching vanilla
-- safehouse to be adopted without creating a duplicate.
------------------------------------------------------------

local function getPropertyTargetId(rect, safehouseId)

    if safehouseId ~= nil
        and tostring(safehouseId) ~= ""
    then

        return "safehouse_" ..
            tostring(safehouseId)

    end

    if not rect then

        return nil

    end

    return tostring(rect.x1) ..
        "_" ..
        tostring(rect.y1) ..
        "_" ..
        tostring(rect.x2) ..
        "_" ..
        tostring(rect.y2)

end


------------------------------------------------------------
-- RECTANGLE OVERLAP
------------------------------------------------------------

local function rectanglesOverlap(a, b)

    if not a or not b then

        return false

    end

    if a.x1 == nil
        or a.y1 == nil
        or a.x2 == nil
        or a.y2 == nil
        or b.x1 == nil
        or b.y1 == nil
        or b.x2 == nil
        or b.y2 == nil
    then

        return false

    end

    if a.z ~= nil
        and b.z ~= nil
        and a.z ~= b.z
    then

        return false

    end

    return a.x1 <= b.x2
        and a.x2 >= b.x1
        and a.y1 <= b.y2
        and a.y2 >= b.y1

end


local function getSafehouseId(safehouse)

    if not safehouse then

        return nil

    end

    local ok, result =
        pcall(
            function()

                return safehouse:getId()

            end
        )

    if ok and result ~= nil
        and tostring(result) ~= ""
    then

        return tostring(result)

    end

    return nil

end


local function getSafehouseRect(safehouse)

    if not safehouse then
        return nil
    end

    local rect
    local ok = pcall(function()
        local x = tonumber(safehouse:getX())
        local y = tonumber(safehouse:getY())
        local w = tonumber(safehouse:getW())
        local h = tonumber(safehouse:getH())

        if not x or not y or not w or not h or w < 1 or h < 1 then
            return
        end

        -- SafeHouse geometry is x/y/width/height. KIPN stores inclusive
        -- x1/y1/x2/y2, so the far edge is x + w - 1 / y + h - 1.
        rect = {
            x1 = x,
            y1 = y,
            x2 = x + w - 1,
            y2 = y + h - 1,
            z = nil,
        }
    end)

    if not ok or not rect then
        return nil
    end

    return rect
end


local function isSafehouseOwner(
    safehouse,
    player
)

    if not safehouse or not player then

        return false

    end

    -- Java-exposed instance methods are called directly inside pcall.
    -- Do not rely on Lua type() reporting them as "function".
    local ownerCheckOk, ownerCheck =
        pcall(
            function()

                return safehouse:isOwner(player)

            end
        )

    if ownerCheckOk then

        return ownerCheck == true

    end

    local ok, owner =
        pcall(
            function()

                return safehouse:getOwner()

            end
        )

    return ok
        and owner ~= nil
        and tostring(owner) == getPlayerName(player)

end


local function getSafehouseOwner(safehouse)

    if not safehouse then

        return nil

    end

    local ok, owner =
        pcall(
            function()

                return safehouse:getOwner()

            end
        )

    if ok and owner ~= nil then

        return tostring(owner)

    end

    return nil

end


local function getClaimRect(claim)

    if type(claim) ~= "table"
        or claim.rectX1 == nil
        or claim.rectY1 == nil
        or claim.rectX2 == nil
        or claim.rectY2 == nil
    then

        return nil

    end

    return {

        x1 = tonumber(claim.rectX1),

        y1 = tonumber(claim.rectY1),

        x2 = tonumber(claim.rectX2),

        y2 = tonumber(claim.rectY2),

        z = claim.type == ClaimService.Types.PROPERTY
            and nil
            or tonumber(claim.locationZ),

    }

end


local function findOverlappingAreaClaim(
    rect,
    ignoredClaimId
)

    local claims =
        ClaimService.GetClaims()

    for _, claim in pairs(claims) do

        if claim.id ~= ignoredClaimId
            and (
                claim.type == ClaimService.Types.PROPERTY
                or claim.type == ClaimService.Types.EXCAVATION
            )
            and rectanglesOverlap(
                rect,
                getClaimRect(claim)
            )
        then

            return claim

        end

    end

    return nil

end


local function expireOverlappingAreaClaims(rect)

    local claims =
        ClaimService.GetClaims()

    for _, claim in pairs(claims) do

        if (
            claim.type == ClaimService.Types.PROPERTY
            or claim.type == ClaimService.Types.EXCAVATION
        )
            and rectanglesOverlap(
                rect,
                getClaimRect(claim)
            )
            and ClaimService.IsClaimExpired(claim)
        then

            ClaimService.ReleaseClaim(
                claim.id,
                "ownership_expired"
            )

        end

    end

end


------------------------------------------------------------
-- VALIDATE VEHICLE TARGET
------------------------------------------------------------


------------------------------------------------------------
-- VALIDATE PLAYER CLAIM ARTIFACT
------------------------------------------------------------
--
-- ArtifactService remains authoritative for the artifact.
--
-- ClaimService does NOT inspect or trust the artifact's
-- internal ModData directly.
------------------------------------------------------------


------------------------------------------------------------
-- CREATE CLAIM RECORD
------------------------------------------------------------

local function createClaimRecord(
    player,
    claimType,
    targetId,
    zoneId,
    artifactId,
    position,
    extraFields
)

    local claimData =
        getClaimData()

    if not claimData then

        return nil,
            "Claim data unavailable."

    end

    local ownerSteamId =
        getPlayerSteamId(
            player
        )

    if not ownerSteamId then

        return nil,
            "Player Steam ID unavailable."

    end

    local targetKey =
        tostring(claimType) ..
        ":" ..
        tostring(targetId)

    --------------------------------------------------------
    -- Final duplicate check immediately before creation.
    --------------------------------------------------------

    local existingClaimId =
        claimData.byTarget[
            targetKey
        ]

    if existingClaimId then

        local existingClaim =
            claimData.records[
                existingClaimId
            ]

        if existingClaim
            and existingClaim.active ~= false
        then

            return nil,
                "Target is already claimed."

        end

        ----------------------------------------------------
        -- Remove stale inactive index.
        ----------------------------------------------------

        claimData.byTarget[
            targetKey
        ] =
            nil

    end

    local claimId =
        generateClaimId(
            claimType,
            targetId
        )

    if not claimId then

        return nil,
            "Unable to generate claim ID."

    end

    local nowDays =
        getWorldDays()

    local record = {

        id =
            claimId,

        version =
            CLAIM_DATA_VERSION,

        type =
            claimType,

        targetId =
            tostring(targetId),

        ownerSteamId =
            tostring(ownerSteamId),

        ownerUsername =
            getPlayerName(player),

        zoneId =
            zoneId,

        artifactId =
            artifactId,

        createdAtWorldDays =
            nowDays,

        locationX =
            position and position.x
            or nil,

        locationY =
            position and position.y
            or nil,

        locationZ =
            position and position.z
            or nil,

        createdAtCalendar =
            getCalendarSnapshot(),

        active =
            true,

    }

    if type(extraFields) == "table" then

        for key, value in pairs(extraFields) do

            record[key] =
                value

        end

    end

    claimData.records[
        claimId
    ] =
        record

    claimData.byTarget[
        targetKey
    ] =
        claimId

    local ownerKey =
        tostring(ownerSteamId)

    if type(
        claimData.byOwner[
            ownerKey
        ]
    ) ~= "table"
    then

        claimData.byOwner[
            ownerKey
        ] =
            {}

    end

    table.insert(
        claimData.byOwner[
            ownerKey
        ],
        claimId
    )

    if ClaimService._MarkSpatialIndexDirty then
        ClaimService._MarkSpatialIndexDirty()
    end

    log(
        "Claim record created | " ..
        "id=" ..
        claimId ..
        " | owner=" ..
        ownerKey
    )

    return record,
        nil

end


------------------------------------------------------------
-- REMOVE CLAIM RECORD
------------------------------------------------------------
--
-- Used only for transaction rollback.
--
-- This removes the active ownership index but preserves no
-- historical record because this is specifically rollback.
------------------------------------------------------------

local function removeClaimRecord(
    claimId
)

    local claimData =
        getClaimData()

    if not claimData then

        return false

    end

    local record =
        claimData.records[
            claimId
        ]

    if not record then

        return false

    end

    local targetKey =
        tostring(record.type) ..
        ":" ..
        tostring(record.targetId)

    if claimData.byTarget[
        targetKey
    ] ==
        claimId
    then

        claimData.byTarget[
            targetKey
        ] =
            nil

    end

    local ownerKey =
        tostring(
            record.ownerSteamId
        )

    local ownerClaims =
        claimData.byOwner[
            ownerKey
        ]

    if type(ownerClaims) ==
        "table"
    then

        for i =
            #ownerClaims,
            1,
            -1
        do

            if ownerClaims[i] ==
                claimId
            then

                table.remove(
                    ownerClaims,
                    i
                )

            end

        end

        if #ownerClaims == 0 then

            claimData.byOwner[
                ownerKey
            ] =
                nil

        end

    end

    claimData.records[
        claimId
    ] =
        nil

    if ClaimService._MarkSpatialIndexDirty then
        ClaimService._MarkSpatialIndexDirty()
    end

    log(
        "Claim record removed | id=" ..
        tostring(claimId)
    )

    return true

end


------------------------------------------------------------
-- CLAIM VEHICLE
------------------------------------------------------------
--
-- Primary authoritative vehicle claim operation.
--
-- The client ultimately calls this through the KIPN command
-- router.
--
-- The server independently revalidates EVERYTHING.
------------------------------------------------------------


------------------------------------------------------------
-- GET PLAYER CLAIMS
------------------------------------------------------------

function ClaimService.GetPlayerClaims(
    player
)

    local steamId =
        getPlayerSteamId(
            player
        )

    if not steamId then

        return {}

    end

    local claimData =
        getClaimData()

    if not claimData then

        return {}

    end

    local claimIds =
        claimData.byOwner[
            tostring(steamId)
        ]

    if type(claimIds) ~=
        "table"
    then

        return {}

    end

    local results = {}

    for _, claimId in ipairs(
        claimIds
    ) do

        local record =
            claimData.records[
                claimId
            ]

        if record
            and record.active ~= false
        then

            ------------------------------------------------------------
            -- LAZY OWNERSHIP EXPIRY
            --
            -- Mirrors GetClaimForTarget()'s lazy-expiry check. Without
            -- this, a claim whose OwnershipExpiryDays has elapsed stays
            -- "active" in this list forever unless someone happens to
            -- look up its exact target tile again -- which means it
            -- keeps counting against the owner's MaxClaimsPerPlayer
            -- quota (see checkMaxClaimsForType(), which is the only
            -- caller for quota purposes) and keeps showing as owned in
            -- KIPN_PropertyRecords, even after it has genuinely expired.
            ------------------------------------------------------------

            if ClaimService.IsClaimExpired(
                record
            ) then

                log(
                    "Claim ownership expired (lazy, via GetPlayerClaims) | id="
                    .. tostring(claimId)
                )

                ClaimService.ReleaseClaim(
                    claimId,
                    "ownership_expired"
                )

            else

                results[claimId] =
                    record

            end

        end

    end

    return results

end


------------------------------------------------------------
-- GET ALL CLAIMS
------------------------------------------------------------

function ClaimService.GetClaims(
    claimType,
    includeInactive
)

    local claimData =
        getClaimData()

    if not claimData then

        return {}

    end

    local results = {}

    for claimId, record in pairs(
        claimData.records
    ) do

        if type(record) ==
            "table"
        then

            local typeMatches =
                not claimType
                or record.type ==
                    claimType

            local active =
                record.active ~= false

            if typeMatches
                and (
                    active
                    or includeInactive == true
                )
            then

                results[claimId] =
                    record

            end

        end

    end

    return results

end


------------------------------------------------------------
-- GET CLAIM AT POSITION
------------------------------------------------------------
--
-- Spatial lookup for area-based claims (Property/Safehouse Deed
-- and Excavation both record rectX1/rectY1/rectX2/rectY2 on
-- creation -- see createClaimRecord() calls in ClaimProperty() and
-- ClaimExcavation() above). Vehicle claims have no rectangle and
-- are never returned here.
--
-- Used by KIPN_ClaimPermissions.lua's enforcement hooks to answer
-- "is (x,y,z) inside a claimed area, and if so, whose?" -- called
-- on every player's OnPlayerMove, so this stays cheap via a
-- bucketed spatial index (below) instead of scanning every claim
-- on every tile move.
------------------------------------------------------------

local SPATIAL_CELL_SIZE =
    20

-- The dirty flag (below) is the authoritative invalidation signal --
-- every claim create / release / remove marks the index dirty and the
-- next lookup rebuilds. This TTL is only a self-healing safety net in
-- case a future mutation path forgets to call markSpatialIndexDirty():
-- staleness is bounded to this interval even then.
local SPATIAL_INDEX_TTL_MS =
    5000

local spatialIndexCache =
    nil

local spatialIndexBuiltAtMs =
    nil

-- Set true whenever a claim record is created, released, or removed.
-- Starts true so the first lookup builds the index.
local spatialIndexDirty =
    true

local function markSpatialIndexDirty()

    spatialIndexDirty =
        true

end

ClaimService._MarkSpatialIndexDirty =
    markSpatialIndexDirty

local function spatialCellKey(
    cellX,
    cellY
)

    return cellX ..
        ":" ..
        cellY

end

------------------------------------------------------------
-- BUILD SPATIAL INDEX
------------------------------------------------------------
--
-- Buckets every active, rectangle-bearing claim into every grid
-- cell its rectangle overlaps. A point lookup then only needs to
-- check the single cell containing that point.
------------------------------------------------------------

local function buildSpatialIndex(
    claimData
)

    local index =
        {}

    for claimId, record in pairs(
        claimData.records
    ) do

        if type(record) == "table"
            and record.active ~= false
            and record.rectX1 ~= nil
            and record.rectY1 ~= nil
            and record.rectX2 ~= nil
            and record.rectY2 ~= nil
        then

            local cellX1 =
                math.floor(record.rectX1 / SPATIAL_CELL_SIZE)

            local cellX2 =
                math.floor(record.rectX2 / SPATIAL_CELL_SIZE)

            local cellY1 =
                math.floor(record.rectY1 / SPATIAL_CELL_SIZE)

            local cellY2 =
                math.floor(record.rectY2 / SPATIAL_CELL_SIZE)

            for cellX = cellX1, cellX2 do

                for cellY = cellY1, cellY2 do

                    local key =
                        spatialCellKey(cellX, cellY)

                    if not index[key] then

                        index[key] =
                            {}

                    end

                    index[key][#index[key] + 1] =
                        claimId

                end

            end

        end

    end

    return index

end

------------------------------------------------------------
-- GET SPATIAL INDEX (CACHED)
------------------------------------------------------------
--
-- Rebuilt at most once per SPATIAL_INDEX_TTL_MS. This bounds
-- staleness to about a second -- a claim created, released, or
-- resized in the last moment might not yet be reflected -- in
-- exchange for turning a full scan on every player tile move
-- into a full scan at most once per second, cached in memory.
------------------------------------------------------------

local function getSpatialIndex(
    claimData
)

    local now =
        type(getTimestampMs) == "function"
        and getTimestampMs()
        or 0

    if not spatialIndexCache
        or not spatialIndexBuiltAtMs
        or spatialIndexDirty
        or (now - spatialIndexBuiltAtMs) >= SPATIAL_INDEX_TTL_MS
    then

        spatialIndexCache =
            buildSpatialIndex(claimData)

        spatialIndexBuiltAtMs =
            now

        spatialIndexDirty =
            false

    end

    return spatialIndexCache

end

function ClaimService.GetClaimAt(
    x,
    y,
    z
)

    if x == nil
        or y == nil
    then

        return nil

    end

    z =
        z or 0

    local claimData =
        getClaimData()

    if not claimData then

        return nil

    end

    local index =
        getSpatialIndex(claimData)

    local candidates =
        index[
            spatialCellKey(
                math.floor(x / SPATIAL_CELL_SIZE),
                math.floor(y / SPATIAL_CELL_SIZE)
            )
        ]

    if not candidates then

        return nil

    end

    for _, claimId in ipairs(
        candidates
    ) do

        local record =
            claimData.records[claimId]

        if type(record) == "table"
            and record.active ~= false
            and record.rectX1 ~= nil
            and record.rectY1 ~= nil
            and record.rectX2 ~= nil
            and record.rectY2 ~= nil
            and (
                record.type == ClaimService.Types.PROPERTY
                or (record.locationZ or 0) == z
            )
            and x >= record.rectX1
            and x <= record.rectX2
            and y >= record.rectY1
            and y <= record.rectY2
        then

            if ClaimService.IsClaimExpired(record) then

                ClaimService.ReleaseClaim(
                    record.id,
                    "ownership_expired"
                )

            else

                return record

            end

        end

    end

    return nil

end


------------------------------------------------------------
-- RELEASE CLAIM
------------------------------------------------------------
--
-- This marks ownership inactive but preserves the historical
-- record.
--
-- IMPORTANT:
--
-- The active target index MUST be removed.
--
-- Otherwise a released target would remain permanently claimed.
------------------------------------------------------------

function ClaimService.ReleaseClaim(
    claimId,
    reason,
    player
)

    local claim = ClaimService.GetClaim(claimId)
    if not claim then return false, "Claim not found." end
    if claim.active == false then return false, "Claim is already inactive." end

    local claimData = getClaimData()
    if not claimData then return false, "Claim data unavailable." end

    local targetKey = tostring(claim.type) .. ":" .. tostring(claim.targetId)
    local previousTargetIndex = claimData.byTarget[targetKey]
    local previousActive = claim.active
    local previousReleasedAt = claim.releasedAtWorldDays
    local previousReason = claim.releaseReason

    --------------------------------------------------------
    -- TYPE-SPECIFIC PRE-RELEASE
    --
    -- The owning service's def.onBeforeRelease runs first (e.g.
    -- Government Services removes the vanilla SafeHouse engine
    -- projection and captures a snapshot into releaseCtx for
    -- transactional rollback). Returning false aborts the release.
    --------------------------------------------------------

    local def = ClaimService.ClaimTypeDefs[claim.type] or {}
    local releaseCtx = { reason = reason }

    if type(def.onBeforeRelease) == "function" then

        local ok, hookOk, hookReason =
            pcall(def.onBeforeRelease, claim, reason, releaseCtx)

        if not ok then

            logError(
                "Claim release onBeforeRelease errored | claim=" ..
                tostring(claimId) .. " | " .. tostring(hookOk)
            )

            return false, "Release pre-check failed."
        end

        if hookOk == false then
            return false, hookReason or "Release was not permitted."
        end
    end

    --------------------------------------------------------
    -- MUTATE KIPN OWNERSHIP.
    --------------------------------------------------------

    claim.active = false
    claim.releasedAtWorldDays = getWorldDays()
    claim.releaseReason = tostring(reason or "unspecified")

    if claimData.byTarget[targetKey] == claimId then
        claimData.byTarget[targetKey] = nil
    end

    local saved = save()

    if not saved then
        claim.active = previousActive
        claim.releasedAtWorldDays = previousReleasedAt
        claim.releaseReason = previousReason
        claimData.byTarget[targetKey] = previousTargetIndex

        -- Transactional rollback: give the owning service a chance to
        -- undo whatever onBeforeRelease did (e.g. re-create the engine
        -- SafeHouse projection from its snapshot).
        if type(def.onReleaseRollback) == "function" then
            pcall(def.onReleaseRollback, claim, releaseCtx)
        end

        logError("Claim release could not be persisted.")
        return false, "Claim could not be persisted."
    end

    --------------------------------------------------------
    -- TYPE-SPECIFIC POST-RELEASE
    --
    -- e.g. Government Services broadcasts the SafeHouse removal /
    -- refreshes the admin claim overlay; Vehicle Services clears the
    -- vehicle's ownership metadata.
    --------------------------------------------------------

    if type(def.onAfterRelease) == "function" then
        pcall(def.onAfterRelease, claim, releaseCtx)
    end

    if ClaimService._MarkSpatialIndexDirty then
        ClaimService._MarkSpatialIndexDirty()
    end

    log("Claim released | id=" .. tostring(claimId) .. " | target=" .. targetKey)
    return true, "CLAIM_RELEASED"
end


------------------------------------------------------------
-- REBUILD INDEXES
------------------------------------------------------------
--
-- Persistent claim records are authoritative.
--
-- byTarget and byOwner are derived indexes and can therefore
-- be rebuilt safely.
--
-- This repairs:
--
--   * missing indexes
--   * stale indexes
--   * indexes pointing at deleted records
--   * indexes pointing at inactive claims
--   * duplicate owner references
------------------------------------------------------------

------------------------------------------------------------
-- OWNER KEY MIGRATION
--
-- Claims written before identities became server accounts carry a
-- rounded Steam ID in ownerSteamId. Each record also stored the
-- owner's username, so on a multiplayer server the key is rewritten
-- to that account. The previous key stays on the record in
-- legacyOwnerSteamId, which doubles as the soft Steam confirmation
-- and as the way back.
--
-- A record with no usable username is left as it is and logged: it
-- cannot be given to an account by guessing.
--
-- A single-player save has one player, "SINGLEPLAYER": a claim still
-- under that player's Steam ID is moved to it.
------------------------------------------------------------

local function migrateOwnerKey(record, summary, singlePlayer)

    if type(record.ownerSteamId) ~= "string"
        and type(record.ownerSteamId) ~= "number"
    then
        return false
    end

    local owner = tostring(record.ownerSteamId)

    if KIPN.Shared.IsAccountId(owner) or owner == "SINGLEPLAYER" then
        return false
    end

    if singlePlayer then
        record.legacyOwnerSteamId = owner
        record.ownerSteamId = "SINGLEPLAYER"
        summary.migrated = summary.migrated + 1
        return true
    end

    local username = record.ownerUsername

    if type(username) ~= "string"
        or username == ""
        or username == "unknown"
    then
        summary.skipped = summary.skipped + 1

        logError(
            "Claim owner NOT migrated to a server account (no username " ..
            "on record) | id=" .. tostring(record.id) ..
            " | owner=" .. owner
        )

        return false
    end

    record.legacyOwnerSteamId = owner
    record.ownerSteamId = KIPN.Shared.AccountId(username)
    summary.migrated = summary.migrated + 1

    log(
        "Claim owner migrated to server account | id=" ..
        tostring(record.id) ..
        " | " .. owner .. " -> " .. tostring(record.ownerSteamId)
    )

    return true

end

local function migrateOwnerKeys(claimData)

    local summary = { migrated = 0, skipped = 0 }

    local okSP, isSP = pcall(KIPN.Shared.IsSinglePlayer)
    local singlePlayer = okSP and isSP == true

    for _, record in pairs(claimData.records) do
        if type(record) == "table" then
            migrateOwnerKey(record, summary, singlePlayer)
        end
    end

    if summary.migrated > 0 or summary.skipped > 0 then

        log(
            "Claim owner migration: " .. summary.migrated ..
            " moved to " .. (singlePlayer and "the single player" or "server accounts") .. ", " .. summary.skipped ..
            " left on their old key."
        )

    end

    if summary.migrated > 0 and type(KIPN.Server.Save) == "function" then
        pcall(KIPN.Server.Save, "claims")
    end

    return summary

end

ClaimService._MigrateOwnerKeys = migrateOwnerKeys

local function rebuildIndexes()

    local claimData =
        getClaimData()

    if not claimData then

        return false

    end

    if type(claimData.records) == "table" then
        migrateOwnerKeys(claimData)
    end

    -- Records may have changed wholesale (e.g. a save reload). Force the
    -- spatial index to rebuild on its next lookup.
    if ClaimService._MarkSpatialIndexDirty then
        ClaimService._MarkSpatialIndexDirty()
    end

    claimData.byTarget =
        {}

    claimData.byOwner =
        {}

    local recordCount =
        0

    local activeCount =
        0

    for claimId, record in pairs(
        claimData.records
    ) do

        if type(record) ==
            "table"
        then

            recordCount =
                recordCount + 1

            ------------------------------------------------
            -- Normalize claim ID.
            ------------------------------------------------

            if not record.id then

                record.id =
                    tostring(claimId)

            end

            ------------------------------------------------
            -- Normalize active state.
            --
            -- Legacy records without an explicit active
            -- field are treated as active.
            ------------------------------------------------

            if record.active == nil then

                record.active =
                    true

            end

            ------------------------------------------------
            -- Only structurally valid records enter indexes.
            ------------------------------------------------

            if record.type
                and record.targetId
                and record.ownerSteamId
            then

                local targetKey =
                    tostring(record.type) ..
                    ":" ..
                    tostring(record.targetId)

                ------------------------------------------------
                -- Only active claims occupy byTarget.
                ------------------------------------------------

                if record.active ~= false then

                    local existing =
                        claimData.byTarget[
                            targetKey
                        ]

                    if existing then

                        logError(
                            "Duplicate active target claims detected | " ..
                            "target=" ..
                            targetKey ..
                            " | existing=" ..
                            tostring(existing) ..
                            " | duplicate=" ..
                            tostring(record.id)
                        )

                    else

                        claimData.byTarget[
                            targetKey
                        ] =
                            record.id

                        activeCount =
                            activeCount + 1

                    end

                end

                ------------------------------------------------
                -- Owner index contains both active and
                -- historical claims.
                ------------------------------------------------

                local ownerKey =
                    tostring(
                        record.ownerSteamId
                    )

                if type(
                    claimData.byOwner[
                        ownerKey
                    ]
                ) ~= "table"
                then

                    claimData.byOwner[
                        ownerKey
                    ] =
                        {}

                end

                table.insert(
                    claimData.byOwner[
                        ownerKey
                    ],
                    record.id
                )

            else

                logError(
                    "Invalid claim record skipped during " ..
                    "index rebuild | id=" ..
                    tostring(claimId)
                )

            end

        end

    end

    log(
        "Claim indexes rebuilt | " ..
        "records=" ..
        tostring(recordCount) ..
        " | active=" ..
        tostring(activeCount)
    )

    return true

end


------------------------------------------------------------
-- COMMAND: CLAIM VEHICLE
------------------------------------------------------------
--
-- Client -> server entry point for the right-click "Claim
-- Vehicle" context menu action.
--
-- args.vehicleId is the client-visible vehicle id
-- (vehicle:getId()), matching getVehicleId() above.
--
-- The server independently re-resolves and re-validates
-- everything; the client's context menu is a hint only.
------------------------------------------------------------


------------------------------------------------------------
-- COMMAND: GET MY CLAIMS
------------------------------------------------------------
--
-- Returns the requesting player's claims. Vanilla SafeHouse objects
-- are authoritative for live property ownership; KIPN property
-- records enrich matching objects with managed-expiry metadata.
-- Owner-matching vanilla safehouses with no KIPN record are exposed
-- as non-expiring, non-releasable legacy rows.
--
-- Identity is always resolved server-side from `player` via
-- ClaimService.GetPlayerClaims() -- never from client-supplied
-- args -- so a player can only ever see claims they themselves
-- own.
------------------------------------------------------------

local function handleGetMyClaimsCommand(
    player,
    _args
)

    -- A companion service that projects claims onto an external engine
    -- object (KIPN: Government Services -> vanilla SafeHouses) reconciles
    -- its records against the live world here, before we compose the
    -- response. No-op when no such service is installed.
    for _, def in pairs(ClaimService.ClaimTypeDefs) do
        if type(def.onListClaimsRefresh) == "function" then
            pcall(def.onListClaimsRefresh, player)
        end
    end

    local claims =
        ClaimService.GetPlayerClaims(
            player
        )

    local claimConfig =
        getClaimConfig()

    local nowDays =
        getWorldDays()

    local results = {}

    local function appendManagedRecord(record, safehouse)

            --------------------------------------------------------
            -- OWNERSHIP EXPIRY
            --
            -- Mirrors ClaimService.IsClaimExpired()'s arithmetic:
            -- expiryDaysRemaining = OwnershipExpiryDays - (now -
            -- anchor). OwnershipExpiryDays <= 0 means the claim
            -- never expires (e.g. vehicles).
            --------------------------------------------------------

            local ownershipNeverExpires = true

            local expiryDaysRemaining = nil

            local serviceConfig =
                claimConfig
                and claimConfig.GetServiceConfig(
                    record.type
                )

            if serviceConfig then

                local ownershipExpiryDays =
                    tonumber(
                        serviceConfig.OwnershipExpiryDays
                    )

                if ownershipExpiryDays
                    and ownershipExpiryDays > 0
                then

                    ownershipNeverExpires = false

                    local anchorDays =
                        tonumber(
                            record.lastRenewedAtWorldDays
                        )
                        or tonumber(
                            record.createdAtWorldDays
                        )

                    if anchorDays and nowDays then

                        expiryDaysRemaining =
                            math.max(
                                0,
                                ownershipExpiryDays
                                    - (nowDays - anchorDays)
                            )

                    end

                end

            end

        local liveRect =
            safehouse
            and getSafehouseRect(safehouse)

        results[#results + 1] = {

                id =
                    record.id,

                type =
                    record.type,

                targetId =
                    record.targetId,

                owner =
                    record.ownerUsername,

                zoneId =
                    record.zoneId,

                locationX =
                    liveRect
                    and liveRect.x1
                    or record.locationX,

                locationY =
                    liveRect
                    and liveRect.y1
                    or record.locationY,

                locationZ =
                    record.locationZ,

                createdAtWorldDays =
                    record.createdAtWorldDays,

                createdAtCalendar =
                    record.createdAtCalendar,

                boxNumber =
                    record.boxNumber,

                sizeTierLabel =
                    record.sizeTierLabel,

                sizeWidthTiles =
                    tonumber(record.sizeWidthTiles)
                    or (
                        record.rectX1 ~= nil
                        and record.rectX2 ~= nil
                        and record.rectX2 - record.rectX1 + 1
                    )
                    or nil,

                sizeHeightTiles =
                    tonumber(record.sizeHeightTiles)
                    or (
                        record.rectY1 ~= nil
                        and record.rectY2 ~= nil
                        and record.rectY2 - record.rectY1 + 1
                    )
                    or nil,

                rectX1 =
                    liveRect
                    and liveRect.x1
                    or record.rectX1,

                rectY1 =
                    liveRect
                    and liveRect.y1
                    or record.rectY1,

                rectX2 =
                    liveRect
                    and liveRect.x2
                    or record.rectX2,

                rectY2 =
                    liveRect
                    and liveRect.y2
                    or record.rectY2,

                ownershipNeverExpires =
                    ownershipNeverExpires,

                expiryDaysRemaining =
                    expiryDaysRemaining,

                source =
                    "kipn",

                managedByKIPN =
                    true,

                releasable =
                    true,

                safehouseId =
                    safehouse
                    and getSafehouseId(safehouse)
                    or record.safehouseId,

            }

    end

    ------------------------------------------------------------
    -- Non-property records still come directly from KIPN.
    ------------------------------------------------------------

    local propertyClaimsById = {}

    local propertyClaimsByRect = {}

    local function rectKey(rect)

        if not rect then

            return nil

        end

        return tostring(rect.x1) .. ":" ..
            tostring(rect.y1) .. ":" ..
            tostring(rect.x2) .. ":" ..
            tostring(rect.y2)

    end

    for _, record in pairs(claims) do

        if record.type == ClaimService.Types.PROPERTY then

            if record.safehouseId then

                propertyClaimsById[
                    tostring(record.safehouseId)
                ] =
                    record

            end

            local key =
                rectKey(
                    getClaimRect(record)
                )

            if key then

                propertyClaimsByRect[key] =
                    record

            end

        else

            appendManagedRecord(record)

        end

    end

    ------------------------------------------------------------
    -- Live vanilla safehouses owned by this player. isOwner(player)
    -- is used instead of trusting a client username or assuming the
    -- vanilla object contains a Steam ID (it does not).
    ------------------------------------------------------------

    local list =
        SafeHouse.getSafehouseList()

    for i = 0,
        list:size() - 1
    do

        local safehouse =
            list:get(i)

        if isSafehouseOwner(
            safehouse,
            player
        )
        then

            local liveRect =
                getSafehouseRect(safehouse)

            local safehouseId =
                getSafehouseId(safehouse)

            local managedRecord =
                safehouseId
                and propertyClaimsById[
                    tostring(safehouseId)
                ]
                or nil

            if not managedRecord then

                managedRecord =
                    propertyClaimsByRect[
                        rectKey(liveRect)
                    ]

            end

            if managedRecord then

                appendManagedRecord(
                    managedRecord,
                    safehouse
                )

            elseif liveRect then

                local legacyTargetId =
                    getPropertyTargetId(
                        liveRect,
                        safehouseId
                    )

                results[#results + 1] = {

                    id =
                        "legacy_" ..
                        tostring(legacyTargetId),

                    type =
                        ClaimService.Types.PROPERTY,

                    targetId =
                        legacyTargetId,

                    owner =
                        getSafehouseOwner(safehouse),

                    locationX =
                        liveRect.x1,

                    locationY =
                        liveRect.y1,

                    locationZ =
                        0,

                    rectX1 =
                        liveRect.x1,

                    rectY1 =
                        liveRect.y1,

                    rectX2 =
                        liveRect.x2,

                    rectY2 =
                        liveRect.y2,

                    ownershipNeverExpires =
                        true,

                    expiryDaysRemaining =
                        nil,

                    source =
                        "vanilla",

                    managedByKIPN =
                        false,

                    releasable =
                        false,

                    safehouseId =
                        safehouseId,

                }

            end

        end

    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.MY_CLAIMS_DATA,
        results
    )

    return true

end


------------------------------------------------------------
-- COMMAND: RELEASE CLAIM
--
-- Self-service release (see KIPN.Shared.Commands.RELEASE_CLAIM).
-- A player may only release a claim they themselves currently own
-- -- ownership is always re-verified server-side via
-- claim.ownerSteamId, never trusted from the client args. Before
-- this handler existed, ClaimService.ReleaseClaim() was only ever
-- reachable via the lazy ownership-expiry checks in
-- GetClaimForTarget()/GetPlayerClaims() -- there was no way for a
-- player to voluntarily free up a claim slot early.
------------------------------------------------------------

local function handleReleaseClaimCommand(
    player,
    args
)
    local claimId = args and args.claimId
    if not claimId then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
            code = "CLAIM_ID_REQUIRED",
            message = "No claim specified.",
        })
        return true
    end

    local claim = ClaimService.GetClaim(claimId)
    if not claim or claim.active == false then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
            code = "CLAIM_NOT_FOUND",
            message = "That claim no longer exists.",
        })
        return true
    end

    local requestingSteamId = getPlayerSteamId(player)
    if not requestingSteamId
        or tostring(claim.ownerSteamId) ~= tostring(requestingSteamId)
    then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
            code = "NOT_CLAIM_OWNER",
            message = "You do not own that claim.",
        })
        return true
    end

    -- The owning service may veto a player-initiated release. KIPN:
    -- Government Services uses this for its managed-safehouse anti-drift
    -- check (the live engine owner must still match) before the engine
    -- projection is removed. No hook -> release proceeds.
    local releaseDef = ClaimService.ClaimTypeDefs[claim.type]
    if releaseDef and type(releaseDef.validatePlayerRelease) == "function" then
        local valid, validationReason =
            releaseDef.validatePlayerRelease(claim, player)
        if not valid then
            KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
                code = "RELEASE_FAILED",
                message = tostring(validationReason),
            })
            return true
        end
    end

    local released, releaseReason = ClaimService.ReleaseClaim(
        claimId,
        "player_released",
        player
    )

    if not released then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
            code = "RELEASE_FAILED",
            message = tostring(releaseReason or "Unable to release claim."),
        })
        return true
    end

    log("Claim released by owner | id=" .. tostring(claimId)
        .. " | player=" .. tostring(requestingSteamId))
    handleGetMyClaimsCommand(player, {})
    return true
end


------------------------------------------------------------
-- GENERIC CLAIM-STORE API  (for companion service mods)
------------------------------------------------------------
--
-- Terminal owns the authoritative claim-record store, the spatial
-- enforcement index, and the release lifecycle. A companion service
-- mod (Government Services, Vehicle Services) registers its claim
-- type(s) via RegisterClaimType() and drives its own validation /
-- policy, calling these to touch the store. It never touches ModData.
------------------------------------------------------------

ClaimService.CreateClaimRecord = createClaimRecord
ClaimService.RemoveClaimRecord = removeClaimRecord
ClaimService.ExpireOverlappingAreaClaims = expireOverlappingAreaClaims
ClaimService.FindOverlappingAreaClaim = findOverlappingAreaClaim

-- Live claim data table { records, byTarget, byOwner }. Read freely;
-- write only through Create/Remove/Release (they keep the indexes and
-- persistence consistent). Persist an in-place field change with
-- KIPN.Server.Save("claims").
ClaimService.GetClaimData = getClaimData

ClaimService.GetWorldDays = getWorldDays
ClaimService.GetCalendarSnapshot = getCalendarSnapshot
ClaimService.GenerateClaimId = generateClaimId
ClaimService.CheckMaxClaimsForType = checkMaxClaimsForType
ClaimService.GetPlayerName = getPlayerName
ClaimService.GetPlayerPosition = getPlayerPosition
ClaimService.GetClaimConfig = getClaimConfig
ClaimService.GetClaimZone = getClaimZone
ClaimService.HasClaimCapability = hasClaimCapability

-- Vehicle-object helpers. Terminal keeps the vehicle-object /
-- ownership-metadata layer (KIPN_ClaimPermissions.lua's OnPlayerMove
-- enforcement still uses SyncVehicleOwnershipMetadata); KIPN: Vehicle
-- Services drives the claim/validate flow through these.
ClaimService.GetVehicleId = getVehicleId
ClaimService.IsVehicleValid = isVehicleValid
ClaimService.GetVehicleSquare = getVehicleSquare
ClaimService.GetVehiclePosition = getVehiclePosition
-- ClaimService.SyncVehicleOwnershipMetadata is already public above.

-- Re-send the caller's full claim list (MY_CLAIMS_DATA). A companion
-- service calls this after it mutates a claim (e.g. a safehouse
-- release) so the player's Property Records screen refreshes.
ClaimService.SendPlayerClaims = handleGetMyClaimsCommand


------------------------------------------------------------
-- EXPIRY SWEEP
------------------------------------------------------------
--
-- Proactively releases every active claim whose OwnershipExpiryDays
-- window has elapsed, so an expired safehouse / excavation / vehicle
-- is freed for the next player even if its owner never logs in again
-- to trigger the lazy on-read expiry in GetPlayerClaims / GetClaimAt.
--
-- Runs from KIPN_MaintenanceService's sweep (periodic + one pass
-- shortly after boot). ReleaseClaim() dispatches the owning type's
-- onBeforeRelease/onAfterRelease hooks, so a Government Services
-- safehouse claim also has its vanilla SafeHouse projection removed
-- here, exactly as it would on a manual release.
------------------------------------------------------------

function ClaimService.RunExpirySweep()

    local summary = { checked = 0, released = 0, failed = 0 }

    local claimData = getClaimData()

    if not claimData
        or type(claimData.records) ~= "table"
    then
        return summary
    end

    -- Collect first; ReleaseClaim mutates claimData.records.
    local toRelease = {}

    for claimId, record in pairs(claimData.records) do

        if type(record) == "table"
            and record.active ~= false
        then

            summary.checked = summary.checked + 1

            if ClaimService.IsClaimExpired(record) then
                toRelease[#toRelease + 1] = claimId
            end
        end
    end

    for _, claimId in ipairs(toRelease) do

        local ok, err =
            ClaimService.ReleaseClaim(claimId, "ownership_expired")

        if ok then
            summary.released = summary.released + 1
            log(
                "Expiry sweep: released claim " .. tostring(claimId)
                .. " (ownership window elapsed)."
            )
        else
            summary.failed = summary.failed + 1
            logError(
                "Expiry sweep: could not release expired claim "
                .. tostring(claimId) .. ": " .. tostring(err)
            )
        end
    end

    return summary
end


------------------------------------------------------------
-- ORPHANED-CLAIM SWEEP
------------------------------------------------------------
--
-- An "orphaned" claim is an active claim whose `type` has no
-- registered ClaimTypeDef -- i.e. the companion service mod that
-- owned it is no longer installed.
--
-- Cautious two-phase handling (see KIPN_MaintenanceService.lua for
-- the schedule):
--
--   1. First sweep a type goes missing: every claim of that type is
--      stamped `_orphanedSinceMs` and logged. Nothing is deleted.
--   2. If the type is still missing `graceDays` later, those claims
--      are released (soft -- history is kept, the target is freed).
--   3. If the type registers again in the meantime (mod reinstalled),
--      the stamp is cleared and the claim is untouched.
--
-- Safety: if NO claim types are registered at all, this is far more
-- likely a broken load order than "every companion mod was removed",
-- so the sweep does nothing.
------------------------------------------------------------

function ClaimService.RunOrphanSweep(graceDays)

    local summary = {
        flagged = 0,
        cleared = 0,
        purged = 0,
        pendingGrace = 0,
    }

    local claimData = getClaimData()

    if not claimData
        or type(claimData.records) ~= "table"
    then
        return summary
    end

    -- No types registered at all -> assume broken load, do nothing.
    -- (pairs(), not the raw `next` builtin -- `next` throws "Object
    -- tried to call nil" on this Kahlua build. Same reason
    -- KIPN_WorldRegistry.lua carries its own tableHasEntries().)
    local anyTypeRegistered = false

    for _ in pairs(ClaimService.ClaimTypeDefs or {}) do
        anyTypeRegistered = true
        break
    end

    if not anyTypeRegistered then
        return summary
    end

    graceDays = tonumber(graceDays)
    if graceDays == nil or graceDays < 0 then
        graceDays = 14
    end

    local now =
        (type(getTimestampMs) == "function") and getTimestampMs() or 0

    local graceMs = graceDays * 86400 * 1000

    -- Collect first; ReleaseClaim mutates claimData.records.
    local toRelease = {}

    for claimId, record in pairs(claimData.records) do

        if type(record) == "table"
            and record.active ~= false
        then

            local registered =
                ClaimService.ClaimTypeDefs[record.type] ~= nil

            if registered then

                if record._orphanedSinceMs ~= nil then
                    record._orphanedSinceMs = nil
                    summary.cleared = summary.cleared + 1
                    log(
                        "Orphan sweep: claim type '"
                        .. tostring(record.type)
                        .. "' is registered again; cleared orphan flag on "
                        .. tostring(claimId)
                    )
                end

            else

                if record._orphanedSinceMs == nil then

                    record._orphanedSinceMs = now
                    summary.flagged = summary.flagged + 1
                    logError(
                        "Orphan sweep: claim "
                        .. tostring(claimId)
                        .. " has unregistered type '"
                        .. tostring(record.type)
                        .. "' (owning mod not installed). Flagged; "
                        .. "will be released in "
                        .. tostring(graceDays) .. " day(s) if still missing."
                    )

                elseif now > 0
                    and (now - record._orphanedSinceMs) >= graceMs
                then
                    toRelease[#toRelease + 1] = claimId
                else
                    summary.pendingGrace = summary.pendingGrace + 1
                end
            end
        end
    end

    for _, claimId in ipairs(toRelease) do
        local ok = ClaimService.ReleaseClaim(claimId, "orphaned_type")
        if ok then
            summary.purged = summary.purged + 1
            logError(
                "Orphan sweep: released claim "
                .. tostring(claimId)
                .. " (owning mod still not installed after grace period)."
            )
        end
    end

    if summary.flagged > 0 or summary.cleared > 0 then
        if type(KIPN.Server.Save) == "function" then
            pcall(KIPN.Server.Save, "claims")
        end
    end

    return summary
end


------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

function ClaimService.Initialize()

    local claimData =
        getClaimData()

    if not claimData then

        logError(
            "Claim data could not be initialized."
        )

        return false

    end

    --------------------------------------------------------
    -- Normalize version.
    --------------------------------------------------------

    if type(
        claimData.version
    ) ~= "number"
    then

        claimData.version =
            CLAIM_DATA_VERSION

    end

    --------------------------------------------------------
    -- Future migration point.
    --------------------------------------------------------

    if claimData.version <
        CLAIM_DATA_VERSION
    then

        log(
            "Claim data migration required | " ..
            "current=" ..
            tostring(
                claimData.version
            ) ..
            " | target=" ..
            tostring(
                CLAIM_DATA_VERSION
            )
        )

        claimData.version =
            CLAIM_DATA_VERSION

    end

    --------------------------------------------------------
    -- Normalize records.
    --------------------------------------------------------

    if type(
        claimData.records
    ) ~= "table"
    then

        claimData.records =
            {}

    end

    --------------------------------------------------------
    -- Rebuild all derived indexes.
    --------------------------------------------------------

    local indexesRebuilt =
        rebuildIndexes()

    if not indexesRebuilt then

        logError(
            "Claim indexes could not be rebuilt."
        )

        return false

    end

    --------------------------------------------------------
    -- Count persisted records.
    --------------------------------------------------------

    local recordCount =
        0

    local activeCount =
        0

    for _, record in pairs(
        claimData.records
    ) do

        if type(record) ==
            "table"
        then

            recordCount =
                recordCount + 1

            if record.active ~= false then

                activeCount =
                    activeCount + 1

            end

        end

    end

    log(
        "Claim data initialized | " ..

        "version=" ..
        tostring(
            claimData.version
        ) ..

        " | records=" ..
        tostring(recordCount) ..

        " | active=" ..
        tostring(activeCount)
    )

    --------------------------------------------------------
    -- Persist repaired indexes.
    --------------------------------------------------------

    local saved =
        save()

    if not saved then

        logError(
            "Claim data initialization could not " ..
            "persist repaired indexes."
        )

        return false

    end

    --------------------------------------------------------
    -- Register command handlers.
    --------------------------------------------------------

    if type(
        KIPN.Server.RegisterCommandHandler
    ) == "function"
    then

        -- Generic, type-agnostic handlers only. Per-type claim handlers
        -- (CLAIM_VEHICLE / CLAIM_PROPERTY / CLAIM_EXCAVATION / the
        -- safehouse-release handshake) are registered by the service
        -- module that owns the type.
        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.GET_MY_CLAIMS,
            handleGetMyClaimsCommand
        )

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.RELEASE_CLAIM,
            handleReleaseClaimCommand
        )

    else

        logError(
            "KIPN.Server.RegisterCommandHandler() is " ..
            "unavailable; GetMyClaims / ReleaseClaim commands " ..
            "will not be reachable."
        )

    end

    log(
        "Claim Service initialized."
    )

    return true

end
