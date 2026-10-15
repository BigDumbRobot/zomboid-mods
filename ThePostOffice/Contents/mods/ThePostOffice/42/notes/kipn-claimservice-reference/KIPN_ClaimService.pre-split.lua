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
require "KIPN/KIPN_SafehouseBridge"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

KIPN.Server.ClaimService =
    KIPN.Server.ClaimService or {}

local ClaimService =
    KIPN.Server.ClaimService


------------------------------------------------------------
-- DEPENDENCIES
------------------------------------------------------------

local ArtifactService
local WorldRegistry


------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local function log(message)

    print(
        "[KIPN CLAIM SERVICE] " ..
        tostring(message)
    )

end


local function logError(message)

    print(
        "[KIPN CLAIM SERVICE] ERROR: " ..
        tostring(message)
    )

end


------------------------------------------------------------
-- DEPENDENCY: ARTIFACT SERVICE
------------------------------------------------------------

local function getArtifactService()

    if ArtifactService then

        return ArtifactService

    end

    if KIPN.Server.ArtifactService then

        ArtifactService =
            KIPN.Server.ArtifactService

        return ArtifactService

    end

    local ok, result =
        pcall(
            function()

                require "KIPN/KIPN_ArtifactService"

            end
        )

    if not ok then

        logError(
            "Failed to load ArtifactService: " ..
            tostring(result)
        )

        return nil

    end

    ArtifactService =
        KIPN.Server.ArtifactService

    if not ArtifactService then

        logError(
            "ArtifactService unavailable after require."
        )

        return nil

    end

    return ArtifactService

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
-- CLAIM TYPES
------------------------------------------------------------

ClaimService.Types = {

    VEHICLE =
        "vehicle",

    PROPERTY =
        "property",

    PO_BOX =
        "po_box",

    EXCAVATION =
        "excavation",

}


------------------------------------------------------------
-- SAFEHOUSE MUTATION GUARD
------------------------------------------------------------
--
-- SafeHouse add/remove operations emit OnSafehousesChanged while a
-- KIPN transaction is still being assembled. SafehouseService uses
-- this guard to avoid reconciling that intentionally intermediate
-- state as though an admin had removed or reassigned a safehouse.
------------------------------------------------------------

local safehouseMutationDepth = 0

local function runSafehouseMutation(callback)

    safehouseMutationDepth =
        safehouseMutationDepth + 1

    local ok, result =
        pcall(callback)

    safehouseMutationDepth =
        math.max(
            0,
            safehouseMutationDepth - 1
        )

    return ok,
        result

end

function ClaimService.IsSafehouseMutationInProgress()

    return safehouseMutationDepth > 0

end


------------------------------------------------------------
-- REQUIRED WORLD CAPABILITIES
------------------------------------------------------------

ClaimService.RequiredCapabilities = {

    [ClaimService.Types.VEHICLE] =
        "vehicle.claim",

    [ClaimService.Types.PROPERTY] =
        "property.claim",

    [ClaimService.Types.PO_BOX] =
        "po_box.claim",

    [ClaimService.Types.EXCAVATION] =
        "excavation.claim",

}


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
-- PLAYER STEAM ID
------------------------------------------------------------

local function getPlayerSteamId(player)

    if not player then

        return nil

    end

    if type(
        player.getSteamID
    ) == "function"
    then

        local ok, result =
            pcall(
                function()

                    return player:getSteamID()

                end
            )

        if ok
            and result ~= nil
        then

            return tostring(result)

        end

    end

    --------------------------------------------------------
    -- Single-player does not always expose a Steam ID. Shared's
    -- identity resolver supplies its deterministic SINGLEPLAYER
    -- fallback in that environment, allowing the same ownership
    -- flow to work outside multiplayer without changing the legacy
    -- Steam-ID representation used by existing MP claim records.
    --------------------------------------------------------

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
-- PLAYER STEAM ID (PUBLIC)
--
-- Exposes the identity resolution above so other KIPN modules
-- (KIPN_ClaimPermissions.lua's Claim.IsOwner()) compare against the
-- SAME scheme claim.ownerSteamId was actually written with, rather
-- than KIPN.Shared.GetPlayerId()'s separately-precision-corrected
-- string.format("%.0f", ...) form, which will not match this
-- plain tostring() form for large SteamID64 values.
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
-- IS SQUARE INSIDE A BUILDING
--
-- Used by ValidatePropertyTarget() -- a Safehouse Deed may only be
-- claimed while the player is standing inside a building.
------------------------------------------------------------

local function isSquareInsideBuilding(
    square
)

    if not square then

        return false

    end

    local inside =
        false

    pcall(
        function()

            inside =
                square:getBuilding() ~= nil

        end
    )

    return inside

end


------------------------------------------------------------
-- BUILDING RECTANGLE
------------------------------------------------------------
--
-- Property deeds claim the complete building definition, not an
-- arbitrary radius around the tile on which the player happened to
-- stand. SafeHouse itself is two-dimensional and protects every
-- floor inside these X/Y bounds.
------------------------------------------------------------

local function getBuildingRect(square)

    if not square then

        return nil

    end

    local rect

    local ok, errorMessage =
        pcall(
            function()

                local building =
                    square:getBuilding()

                local definition =
                    building
                    and building:getDef()

                if not definition then

                    return

                end

                local x1 =
                    tonumber(definition:getX())

                local y1 =
                    tonumber(definition:getY())

                local width =
                    type(definition.getW) == "function"
                    and tonumber(definition:getW())

                local height =
                    type(definition.getH) == "function"
                    and tonumber(definition:getH())

                local x2 =
                    x1
                    and width
                    and x1 + width - 1
                    or tonumber(definition:getX2())

                local y2 =
                    y1
                    and height
                    and y1 + height - 1
                    or tonumber(definition:getY2())

                if x1 and y1 and x2 and y2 then

                    rect = {

                        x1 = math.floor(x1),

                        y1 = math.floor(y1),

                        x2 = math.floor(x2),

                        y2 = math.floor(y2),

                        -- SafeHouse bounds apply to the complete
                        -- building on every floor.
                        z = nil,

                    }

                end

            end
        )

    if not ok then

        logError(
            "Building-bound lookup failed: " ..
            tostring(errorMessage)
        )

        return nil

    end

    return rect

end


------------------------------------------------------------
-- IS SQUARE VALID EXCAVATION LAND
--
-- Used by ValidateExcavationTarget() -- every square inside a
-- proposed excavation claim rectangle must not be part of a
-- building and must not be water.
------------------------------------------------------------

local function isSquareWater(
    square
)

    if not square then

        return false

    end

    local floor =
        type(square.getFloor) == "function"
        and square:getFloor()
        or nil

    if floor
        and type(floor.getSprite) == "function"
    then

        local sprite =
            floor:getSprite()

        local properties =
            sprite
            and type(sprite.getProperties) == "function"
            and sprite:getProperties()
            or nil

        if properties
            and type(properties.has) == "function"
            and properties:has(IsoFlagType.water)
        then

            return true

        end

    end

    local objects =
        type(square.getObjects) == "function"
        and square:getObjects()
        or nil

    if objects then

        for i = 0,
            objects:size() - 1
        do

            local object =
                objects:get(i)

            local sprite =
                object
                and type(object.getSprite) == "function"
                and object:getSprite()
                or nil

            local properties =
                sprite
                and type(sprite.getProperties) == "function"
                and sprite:getProperties()
                or nil

            if properties
                and type(properties.has) == "function"
                and (
                    properties:has(IsoFlagType.water)
                    or properties:has(IsoFlagType.taintedWater)
                )
            then

                return true

            end

        end

    end

    return false

end


local function isSquareValidExcavationLand(
    square
)

    if not square then

        return false,
            "square_unavailable"

    end

    local okOutside,
        outside =
        pcall(
            function()

                return square:isOutside()

            end
        )

    if not okOutside
        or outside ~= true
    then

        return false,
            "indoors"

    end

    local okWater,
        water =
        pcall(
            isSquareWater,
            square
        )

    if okWater
        and water == true
    then

        return false,
            "water"

    end

    return true,
        nil

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
-- NON-CUSTOM KIPN ZONE OVERLAP (shared by Property + Excavation)
------------------------------------------------------------
--
-- Custom zones are always permitted to overlap a Safehouse or
-- Excavation claim. Any OTHER active zone type (Government,
-- Dealership, Post Office, Event, or any future type) blocks the
-- claim. Checks the COMPLETE claim rectangle, not a single tile.
------------------------------------------------------------

local function findBlockingNonCustomZone(rect)

    local registry =
        getWorldRegistry()

    if not registry or
       type(registry.GetZonesOverlappingRectangle) ~= "function" then

        logError(
            "findBlockingNonCustomZone() FAILED: " ..
            "WorldRegistry rectangle-overlap service unavailable."
        )

        return nil,
            "unavailable"
    end

    local overlappingZones

    local ok, errorMessage =
        pcall(
            function()

                overlappingZones =
                    registry.GetZonesOverlappingRectangle(
                        rect,
                        {
                            ignoreZ = true,
                        }
                    )

            end
        )

    if not ok then

        logError(
            "findBlockingNonCustomZone() overlap lookup failed: " ..
            tostring(errorMessage)
        )

        return nil,
            "unavailable"
    end

    if type(overlappingZones) ~= "table" then

        return nil
    end

    for zoneId, zone in pairs(overlappingZones) do

        if type(zone) == "table" and
           zone.type ~= registry.ZoneTypes.CUSTOM then

            return zone,
                zoneId
        end

    end

    return nil
end


------------------------------------------------------------
-- DO NOT CLAIM ZONE OVERLAP (shared by Property + Excavation)
------------------------------------------------------------
--
-- Unlike every other non-custom zone type, a Do Not Claim zone
-- blocks Property claims UNCONDITIONALLY -- it is not subject to
-- the House service's AllowClaimsInKIPNZones override (that
-- toggle exists to let admins re-permit claims inside
-- Government/Dealership/Post Office/Event zones, not to defeat a
-- zone whose entire purpose is to forbid claiming). Excavation
-- already treats every non-custom zone type as an unconditional
-- block with no override toggle at all, so a plain (unbuffered)
-- Do Not Claim overlap was already covered there via
-- findBlockingNonCustomZone -- this dedicated check exists so
-- BOTH claim types also honor the tile buffer below, which
-- findBlockingNonCustomZone does not apply.
--
-- A claim is also rejected if it merely comes within
-- KIPN.DoNotClaimZoneBufferTiles tiles of the zone's drawn
-- boundary (default 5), not only when it overlaps the boundary
-- outright -- achieved by growing the claim's own rectangle
-- outward by the buffer before the overlap query, which is
-- equivalent to growing the zone itself for two axis-aligned
-- rectangles.
------------------------------------------------------------

local function getDoNotClaimZoneBufferTiles()

    local claimConfig =
        getClaimConfig()

    local buffer =
        claimConfig and
        tonumber(claimConfig.DoNotClaimZoneBufferTiles)

    if not buffer or
       buffer < 0 then

        return 0
    end

    return math.floor(buffer)
end

local function growRectByBuffer(rect, buffer)

    if buffer <= 0 or
       type(rect) ~= "table" then

        return rect
    end

    local x1 =
        tonumber(rect.x1)

    local y1 =
        tonumber(rect.y1)

    local x2 =
        tonumber(rect.x2)

    local y2 =
        tonumber(rect.y2)

    if not x1 or
       not y1 or
       not x2 or
       not y2 then

        return rect
    end

    x1, x2 =
        math.min(x1, x2),
        math.max(x1, x2)

    y1, y2 =
        math.min(y1, y2),
        math.max(y1, y2)

    return {
        x1 = x1 - buffer,
        y1 = y1 - buffer,
        x2 = x2 + buffer,
        y2 = y2 + buffer,
        z = rect.z,
        z1 = rect.z1,
        z2 = rect.z2,
    }
end

local function findDoNotClaimZone(rect)

    local registry =
        getWorldRegistry()

    if not registry or
       type(registry.GetZonesOverlappingRectangle) ~= "function" then

        logError(
            "findDoNotClaimZone() FAILED: " ..
            "WorldRegistry rectangle-overlap service unavailable."
        )

        return nil,
            "unavailable"
    end

    local bufferedRect =
        growRectByBuffer(
            rect,
            getDoNotClaimZoneBufferTiles()
        )

    local overlappingZones

    local ok, errorMessage =
        pcall(
            function()

                overlappingZones =
                    registry.GetZonesOverlappingRectangle(
                        bufferedRect,
                        {
                            ignoreZ = true,
                        }
                    )

            end
        )

    if not ok then

        logError(
            "findDoNotClaimZone() overlap lookup failed: " ..
            tostring(errorMessage)
        )

        return nil,
            "unavailable"
    end

    if type(overlappingZones) ~= "table" then

        return nil
    end

    for zoneId, zone in pairs(overlappingZones) do

        if type(zone) == "table" and
           zone.type == registry.ZoneTypes.DO_NOT_CLAIM then

            return zone,
                zoneId
        end

    end

    return nil
end


------------------------------------------------------------
-- PROPERTY CLAIMS INSIDE KIPN ZONES
------------------------------------------------------------
--
-- KIPN is the safehouse POLICY authority. Vanilla SafeHouse remains
-- the engine object, but KIPN decides whether a new property claim is
-- permitted. This policy intentionally checks the COMPLETE building
-- rectangle in X/Y, not merely the player's current tile.
--
-- Custom zones are exempt (see findBlockingNonCustomZone above) --
-- only Government/Dealership/Post Office/Event/other non-custom
-- zones block a property claim.
------------------------------------------------------------

local function validatePropertyKIPNZonePolicy(
    buildingRect
)
    local claimConfig =
        getClaimConfig()

    if not claimConfig then

        logError(
            "validatePropertyKIPNZonePolicy() FAILED: claim configuration unavailable."
        )

        return false,
            "Claim configuration unavailable."
    end

    local houseConfig =
        claimConfig.GetServiceConfig(
            ClaimService.Types.PROPERTY
        )

    if not houseConfig then

        logError(
            "validatePropertyKIPNZonePolicy() FAILED: House service configuration unavailable."
        )

        return false,
            "House claim configuration unavailable."
    end

    local doNotClaimZone, doNotClaimZoneId =
        findDoNotClaimZone(
            buildingRect
        )

    if doNotClaimZone then

        log(
            "Property KIPN-zone policy REJECTED (Do Not Claim) | zoneId=" ..
            tostring(doNotClaimZoneId) ..
            " | rect=" ..
            tostring(buildingRect.x1) .. "," ..
            tostring(buildingRect.y1) .. "," ..
            tostring(buildingRect.x2) .. "," ..
            tostring(buildingRect.y2)
        )

        return false,
            "This property overlaps a Do Not Claim zone."
    end

    if houseConfig.AllowClaimsInKIPNZones == true then

        log(
            "Property KIPN-zone policy PASSED: claims inside KIPN zones are enabled."
        )

        return true,
            nil
    end

    local blockingZone, blockingZoneId =
        findBlockingNonCustomZone(
            buildingRect
        )

    if blockingZone then

        log(
            "Property KIPN-zone policy REJECTED | zoneId=" ..
            tostring(blockingZoneId) ..
            " | zoneType=" ..
            tostring(blockingZone.type) ..
            " | rect=" ..
            tostring(buildingRect.x1) .. "," ..
            tostring(buildingRect.y1) .. "," ..
            tostring(buildingRect.x2) .. "," ..
            tostring(buildingRect.y2)
        )

        return false,
            "This property overlaps a restricted KIPN service zone."
    end

    log(
        "Property KIPN-zone policy PASSED: no active non-custom KIPN Zone overlaps the building."
    )

    return true,
        nil
end


------------------------------------------------------------
-- MAX CLAIMS PER PLAYER (PER SERVICE)
------------------------------------------------------------
--
-- Each claim service (Vehicle / House / Excavation / PO Box)
-- has its own MaxClaimsPerPlayer quota.
--
-- This is intentionally generic over claimType so future
-- claim services (House, Excavation, PO Box) reuse it exactly
-- as ClaimVehicle does today.
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
-- No player-facing command currently calls this; it exists so
-- a renewal action (computer visit, in-world interaction, etc.)
-- can be wired up later without touching ClaimService again.
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
-- EXCAVATION TARGET ID
------------------------------------------------------------
--
-- Mirrors getPropertyTargetId(): a excavation claim has no
-- engine-assigned ID, so the claim target identity is the anchor
-- tile itself.
------------------------------------------------------------

local function getExcavationTargetId(position)

    if not position then

        return nil

    end

    return tostring(position.x) ..
        "_" ..
        tostring(position.y) ..
        "_" ..
        tostring(position.z)

end


------------------------------------------------------------
-- EXCAVATION TARGET RECTANGLE
------------------------------------------------------------
--
-- The excavation rectangle size comes from the admin-configured
-- size tier the player
-- purchased at the KIPN computer (see KIPN_ClaimConfig.lua's
-- ExcavationSizeTiers), baked into the claim artifact at issuance
-- and passed in here as sizeTier.
------------------------------------------------------------

local function getExcavationTargetRect(position, sizeTier)

    if not position
        or not sizeTier
    then

        return nil

    end

    local width =
        math.floor(
            tonumber(sizeTier.widthTiles) or 0
        )

    local height =
        math.floor(
            tonumber(sizeTier.heightTiles) or 0
        )

    if width <= 0
        or height <= 0
    then

        return nil

    end

    local halfWidth =
        math.floor(width / 2)

    local halfHeight =
        math.floor(height / 2)

    return {

        x1 = position.x - halfWidth,

        y1 = position.y - halfHeight,

        x2 = position.x - halfWidth + width - 1,

        y2 = position.y - halfHeight + height - 1,

        z = position.z,

    }

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


local function rectanglesEqual(a, b)

    return a
        and b
        and tonumber(a.x1) == tonumber(b.x1)
        and tonumber(a.y1) == tonumber(b.y1)
        and tonumber(a.x2) == tonumber(b.x2)
        and tonumber(a.y2) == tonumber(b.y2)

end


local function rectangleContains(outer, inner)

    return outer
        and inner
        and tonumber(outer.x1) <= tonumber(inner.x1)
        and tonumber(outer.y1) <= tonumber(inner.y1)
        and tonumber(outer.x2) >= tonumber(inner.x2)
        and tonumber(outer.y2) >= tonumber(inner.y2)

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


local function safehouseContainsPosition(
    safehouse,
    position
)

    local rect =
        getSafehouseRect(safehouse)

    return rect
        and position
        and position.x >= rect.x1
        and position.x <= rect.x2
        and position.y >= rect.y1
        and position.y <= rect.y2

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


local function getSafehousesOverlapping(rect)

    local matches = {}

    if not rect
        or not SafeHouse
    then

        return matches

    end

    local ok, errorMessage =
        pcall(
            function()

                local list =
                    SafeHouse.getSafehouseList()

                if not list then
                    return
                end

                for i = 0,
                    list:size() - 1
                do

                    local safehouse =
                        list:get(i)

                    if rectanglesOverlap(
                        rect,
                        getSafehouseRect(safehouse)
                    )
                    then

                        matches[#matches + 1] =
                            safehouse

                    end

                end

            end
        )

    if not ok then

        logError(
            "Safehouse overlap lookup failed: " ..
            tostring(errorMessage)
        )

    end

    return matches

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

function ClaimService.ValidateVehicleTarget(
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


------------------------------------------------------------
-- VALIDATE PROPERTY TARGET
------------------------------------------------------------
--
-- A property target is the complete building containing the
-- player. Any existing vanilla safehouse overlapping that building
-- blocks the claim, except for the one containing the player when
-- that player is its vanilla owner; that special case adopts the
-- existing safehouse into KIPN instead of creating a duplicate.
------------------------------------------------------------

function ClaimService.ValidatePropertyTarget(
    player,
    position
)

    if not player then

        return false,
            "Player is required."

    end

    if not position
        or position.x == nil
        or position.y == nil
    then

        return false,
            "Player location is unavailable."

    end

    local square =
        getSquare(
            position.x,
            position.y,
            position.z
        )

    if not isSquareInsideBuilding(square)
    then

        return false,
            "You must be inside a building to claim it as a " ..
            "safehouse."

    end

    --------------------------------------------------------
    -- Complete building bounds.
    --------------------------------------------------------

    local buildingRect =
        getBuildingRect(square)

    if not buildingRect then

        return false,
            "Unable to determine the complete building area."

    end

    --------------------------------------------------------
    -- KIPN SAFEHOUSE POLICY: KIPN ZONE OVERLAP
    --------------------------------------------------------
    --
    -- KIPN owns safehouse policy. When HouseAllowClaimsInKIPNZones
    -- is false, ANY X/Y overlap between the complete building and an
    -- active KIPN Zone rejects this NEW claim. Existing safehouses are
    -- not altered by this validation.
    --------------------------------------------------------

    local zonePolicyValid,
        zonePolicyReason =
        validatePropertyKIPNZonePolicy(
            buildingRect
        )

    if not zonePolicyValid then

        return false,
            zonePolicyReason
    end

    expireOverlappingAreaClaims(
        buildingRect
    )

    --------------------------------------------------------
    -- Vanilla safehouse conflicts/adoption.
    --------------------------------------------------------

    local overlappingSafehouses =
        getSafehousesOverlapping(
            buildingRect
        )

    local adoptedSafehouse =
        nil

    for _, safehouse in ipairs(
        overlappingSafehouses
    )
    do

        if safehouseContainsPosition(
            safehouse,
            position
        )
            and rectangleContains(
                getSafehouseRect(safehouse),
                buildingRect
            )
            and isSafehouseOwner(
                safehouse,
                player
            )
            and not adoptedSafehouse
        then

            adoptedSafehouse =
                safehouse

        else

            return false,
                "This building overlaps an existing safehouse."

        end

    end

    local targetRect =
        adoptedSafehouse
        and getSafehouseRect(adoptedSafehouse)
        or buildingRect

    local safehouseId =
        getSafehouseId(adoptedSafehouse)

    local targetId =
        getPropertyTargetId(
            targetRect,
            safehouseId
        )

    if not targetId then

        return false,
            "Unable to identify this property."

    end

    expireOverlappingAreaClaims(
        targetRect
    )

    --------------------------------------------------------
    -- Every part of the building must be clear of active KIPN
    -- property/excavation ownership. This also catches older KIPN
    -- property records whose targetId was an anchor tile.
    --------------------------------------------------------

    if findOverlappingAreaClaim(
        targetRect
    )
    then

        return false,
            "This building overlaps an existing KIPN claim."

    end

    if ClaimService.IsTargetClaimed(
        ClaimService.Types.PROPERTY,
        targetId
    )
    then

        return false,
            "This property is already claimed."

    end

    return true,
        nil,
        {

            targetId =
                targetId,

            position =
                position,

            rect =
                targetRect,

            buildingRect =
                buildingRect,

            existingSafehouse =
                adoptedSafehouse,

            safehouseId =
                safehouseId,

            -- No zone/capability gate for property claims (see the
            -- note above) -- zone/zoneId are intentionally nil.
            -- ArtifactService.ValidatePropertyClaim() no longer
            -- requires a non-nil scope for this claim type either.
            zone =
                nil,

            zoneId =
                nil,

        }

end


------------------------------------------------------------
-- VALIDATE EXCAVATION TARGET
------------------------------------------------------------
--
-- Mirrors ClaimService.ValidatePropertyTarget(), but:
--
--   * The target rectangle size comes from the purchased size
--     tier rather than a building definition.
--
--   * Every square in the purchased rectangle is validated.
--
--   * The complete rectangle is checked against vanilla
--     safehouses and every active KIPN area claim.
------------------------------------------------------------

function ClaimService.ValidateExcavationTarget(
    player,
    position,
    sizeTier
)

    if not player then

        return false,
            "Player is required."

    end

    if not position
        or position.x == nil
        or position.y == nil
    then

        return false,
            "Player location is unavailable."

    end

    if type(sizeTier) ~= "table"
        or not tonumber(sizeTier.widthTiles)
        or not tonumber(sizeTier.heightTiles)
    then

        return false,
            "Excavation claim size is unavailable."

    end

    local targetId =
        getExcavationTargetId(
            position
        )

    --------------------------------------------------------
    -- Current ownership (exact anchor tile).
    --------------------------------------------------------

    local existingClaim =
        ClaimService.GetClaimForTarget(
            ClaimService.Types.EXCAVATION,
            targetId
        )

    if existingClaim then

        return false,
            "This location is already claimed."

    end

    --------------------------------------------------------
    -- NOTE -- NO CAPABILITY GATE HERE.
    --
    -- Excavation claims previously required the target land to
    -- also sit inside a WorldRegistry zone granting the
    -- "excavation.claim" capability -- in practice no zone type
    -- grants that by default (see KIPN_WorldRegistry.lua's
    -- DefaultCapabilities), so it could only ever work on manually
    -- admin-painted CUSTOM zones, blocking excavation everywhere
    -- else. Players should be able to claim any set of open land
    -- squares (same policy change already applied to
    -- ValidatePropertyTarget() above for Safehouse Deeds). The real
    -- requirements -- not already claimed, not inside a building,
    -- not water, not overlapping another excavation claim -- are
    -- enforced below and are unaffected by this change.
    --
    -- A NARROWER check (below, once rect is known) still blocks
    -- excavation on active NON-CUSTOM KIPN zones, mirroring
    -- ValidatePropertyTarget()'s Custom-zone-exempt policy.
    --------------------------------------------------------

    --------------------------------------------------------
    -- Rectangle overlap against other active excavation claims.
    --------------------------------------------------------

    local rect =
        getExcavationTargetRect(
            position,
            sizeTier
        )

    if not rect then

        return false,
            "Unable to calculate the excavation claim area."

    end

    local doNotClaimZone, doNotClaimZoneId =
        findDoNotClaimZone(
            rect
        )

    if doNotClaimZone then

        log(
            "Excavation KIPN-zone policy REJECTED (Do Not Claim) | zoneId=" ..
            tostring(doNotClaimZoneId) ..
            " | rect=" ..
            tostring(rect.x1) .. "," ..
            tostring(rect.y1) .. "," ..
            tostring(rect.x2) .. "," ..
            tostring(rect.y2)
        )

        return false,
            "This claim overlaps a Do Not Claim zone."
    end

    local blockingZone, blockingZoneId =
        findBlockingNonCustomZone(
            rect
        )

    if blockingZone then

        log(
            "Excavation KIPN-zone policy REJECTED | zoneId=" ..
            tostring(blockingZoneId) ..
            " | zoneType=" ..
            tostring(blockingZone.type) ..
            " | rect=" ..
            tostring(rect.x1) .. "," ..
            tostring(rect.y1) .. "," ..
            tostring(rect.x2) .. "," ..
            tostring(rect.y2)
        )

        return false,
            "This claim overlaps a restricted KIPN service zone."
    end

    expireOverlappingAreaClaims(
        rect
    )

    --------------------------------------------------------
    -- Every square in the claim area must not be part of a
    -- building and must not be water. This is the inverse of
    -- ValidatePropertyTarget()'s "must be inside a building"
    -- requirement above.
    --------------------------------------------------------

    for scanX = rect.x1,
        rect.x2
    do

        for scanY = rect.y1,
            rect.y2
        do

            local squareValid,
                squareReason =
                isSquareValidExcavationLand(
                    getSquare(
                        scanX,
                        scanY,
                        rect.z
                    )
                )

            if not squareValid then

                logError(
                    "ValidateExcavationTarget() rejected square | " ..
                    "x=" ..
                    tostring(scanX) ..
                    " | y=" ..
                    tostring(scanY) ..
                    " | z=" ..
                    tostring(rect.z) ..
                    " | reason=" ..
                    tostring(squareReason)
                )

                if squareReason == "indoors" then

                    return false,
                        "This area contains an indoor tile and cannot be excavated."

                elseif squareReason == "water" then

                    return false,
                        "This area contains water and cannot be excavated."

                else

                    return false,
                        "This area contains an unavailable tile and cannot be excavated."

                end

            end

        end

    end

    if #getSafehousesOverlapping(rect) > 0 then

        return false,
            "This area overlaps an existing safehouse."

    end

    if findOverlappingAreaClaim(rect) then

        return false,
            "This area overlaps an existing KIPN claim."

    end

    return true,
        nil,
        {

            targetId =
                targetId,

            position =
                position,

            rect =
                rect,

            -- No zone/capability gate for excavation claims (see
            -- the note above) -- zone/zoneId are intentionally nil.
            -- ArtifactService.ValidateExcavationClaim() no longer
            -- requires a non-nil scope for this claim type either.
            zone =
                nil,

            zoneId =
                nil,

        }

end


------------------------------------------------------------
-- VALIDATE PLAYER CLAIM ARTIFACT
------------------------------------------------------------
--
-- ArtifactService remains authoritative for the artifact.
--
-- ClaimService does NOT inspect or trust the artifact's
-- internal ModData directly.
------------------------------------------------------------

function ClaimService.ValidateVehicleClaimArtifact(
    player,
    claimItem,
    targetZoneId
)

    local artifacts =
        getArtifactService()

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


------------------------------------------------------------
-- VALIDATE PROPERTY CLAIM ARTIFACT
------------------------------------------------------------
--
-- Mirrors ClaimService.ValidateVehicleClaimArtifact() for the
-- Property service.
------------------------------------------------------------

function ClaimService.ValidatePropertyClaimArtifact(
    player,
    claimItem,
    targetZoneId
)

    local artifacts =
        getArtifactService()

    if not artifacts then

        return false,
            "Artifact service unavailable."

    end

    if not claimItem then

        return false,
            "Property claim artifact required."

    end

    if type(
        artifacts.ValidatePropertyClaim
    ) ~= "function"
    then

        logError(
            "ArtifactService.ValidatePropertyClaim() " ..
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
                    artifacts.ValidatePropertyClaim(
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


------------------------------------------------------------
-- VALIDATE EXCAVATION CLAIM ARTIFACT
------------------------------------------------------------
--
-- Mirrors ClaimService.ValidatePropertyClaimArtifact() for the
-- Excavation service.
------------------------------------------------------------

function ClaimService.ValidateExcavationClaimArtifact(
    player,
    claimItem,
    targetZoneId
)

    local artifacts =
        getArtifactService()

    if not artifacts then

        return false,
            "Artifact service unavailable."

    end

    if not claimItem then

        return false,
            "Excavation claim artifact required."

    end

    if type(
        artifacts.ValidateExcavationClaim
    ) ~= "function"
    then

        logError(
            "ArtifactService.ValidateExcavationClaim() " ..
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
                    artifacts.ValidateExcavationClaim(
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

function ClaimService.ClaimVehicle(
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
        ClaimService.ValidateVehicleTarget(
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
        ClaimService.ValidateVehicleClaimArtifact(
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
        getArtifactService()

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


------------------------------------------------------------
-- CLAIM PROPERTY
------------------------------------------------------------
--
-- Primary authoritative property claim operation. Mirrors
-- ClaimService.ClaimVehicle(), with one additional step after the
-- claim artifact is consumed: unlike a vehicle (which already
-- exists as a game object), a property claim must also CREATE the
-- actual vanilla SafeHouse record via SafeHouse.addSafeHouse(),
-- using the exact same API KIPN_SafehouseService.lua's
-- handleAdminAssignSafehouse() already calls for admin-assigned
-- safehouses.
--
-- The client ultimately calls this through the KIPN command
-- router. The server independently revalidates EVERYTHING.
------------------------------------------------------------

function ClaimService.ClaimProperty(
    player,
    position,
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
        ClaimService.ValidatePropertyTarget(
            player,
            position
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
        ClaimService.ValidatePropertyClaimArtifact(
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
            ClaimService.Types.PROPERTY
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

    local finalTargetValid,
        finalTargetReason,
        finalTargetData =
        ClaimService.ValidatePropertyTarget(
            player,
            position
        )

    if not finalTargetValid then

        log(
            "ClaimProperty() FAILED during final building validation: " ..
            tostring(finalTargetReason)
        )

        return false,
            finalTargetReason

    end

    targetData =
        finalTargetData

    --------------------------------------------------------
    -- CREATE AUTHORITATIVE OWNERSHIP RECORD
    --------------------------------------------------------

    local claimRecord,
        createReason =
        createClaimRecord(
            player,
            ClaimService.Types.PROPERTY,
            targetData.targetId,
            targetData.zoneId,
            artifactRecord.id,
            targetData.position,
            {

                -- Recorded so ClaimService.GetClaimAt() (used by
                -- KIPN_ClaimPermissions.lua's CanEnter enforcement)
                -- can spatially index Safehouse Deed claims the
                -- same way it does Excavation claims.
                rectX1 =
                    targetData.rect.x1,

                rectY1 =
                    targetData.rect.y1,

                rectX2 =
                    targetData.rect.x2,

                rectY2 =
                    targetData.rect.y2,

                safehouseManaged =
                    true,

                safehouseAdopted =
                    targetData.existingSafehouse ~= nil,

                safehouseId =
                    targetData.safehouseId,

            }
        )

    if not claimRecord then

        log(
            "ClaimProperty() ownership creation failed: " ..
            tostring(createReason)
        )

        return false,
            createReason

    end

    --------------------------------------------------------
    -- CONSUME CLAIM ARTIFACT
    --------------------------------------------------------

    local artifacts =
        getArtifactService()

    if not artifacts then

        removeClaimRecord(
            claimRecord.id
        )

        return false,
            "Artifact service unavailable."

    end

    if type(
        artifacts.ConsumePropertyClaim
    ) ~= "function"
    then

        removeClaimRecord(
            claimRecord.id
        )

        logError(
            "ArtifactService.ConsumePropertyClaim() " ..
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
                    artifacts.ConsumePropertyClaim(
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
            "ClaimProperty() artifact consumption failed: " ..
            tostring(consumeReason)
        )

        return false,
            consumeReason or
            "Claim artifact could not be consumed."

    end

    --------------------------------------------------------
    -- ADOPT OR CREATE THE VANILLA SAFEHOUSE
    --------------------------------------------------------
    --
    -- IMPORTANT:
    --
    -- The claim artifact is already consumed at this point. If
    -- this fails, ownership is rolled back from the claim index,
    -- but (matching ClaimVehicle's own documented behavior) the
    -- artifact remains consumed -- it is not refunded.
    --------------------------------------------------------

    local rect =
        targetData.rect

    local safehouse =
        targetData.existingSafehouse

    local createdSafehouse =
        false

    local safehouseOk =
        true

    local safehouseError =
        nil

    if not safehouse then

        ----------------------------------------------------
        -- CREATE ENGINE PROJECTION THROUGH THE BRIDGE
        --
        -- Deliberately bypasses vanilla hasSafehouse()/
        -- alreadyHaveSafehouse()/allowSafeHouse() policy gates. KIPN's
        -- MaxClaimsPerPlayer is the authoritative multi-property quota.
        ----------------------------------------------------

        local bridge =
            KIPN.Bridges
            and KIPN.Bridges.Safehouse

        safehouseOk,
            safehouseError =
            runSafehouseMutation(
                function()

                    if not bridge
                        or type(bridge.CreateProjection) ~= "function"
                    then
                        error("KIPN SafehouseBridge.CreateProjection unavailable")
                    end

                    local created,
                        reason =
                        bridge.CreateProjection(
                            claimRecord
                        )

                    if not created then
                        error(tostring(reason))
                    end

                    return created

                end
            )

        if safehouseOk then

            safehouse =
                safehouseError

            safehouseError =
                nil

            createdSafehouse =
                safehouse ~= nil

        end

    end

    if not safehouseOk
        or not safehouse
    then

        removeClaimRecord(
            claimRecord.id
        )

        logError(
            "SafeHouse.addSafeHouse() failed: " ..
            tostring(safehouseError) ..
            ". Artifact remains consumed."
        )

        return false,
            "Safehouse could not be established."

    end

    local liveRect =
        getSafehouseRect(safehouse)

    if liveRect then

        claimRecord.rectX1 =
            liveRect.x1

        claimRecord.rectY1 =
            liveRect.y1

        claimRecord.rectX2 =
            liveRect.x2

        claimRecord.rectY2 =
            liveRect.y2

    end

    claimRecord.safehouseId =
        getSafehouseId(safehouse)
        or claimRecord.safehouseId

    --------------------------------------------------------
    -- PERSIST OWNERSHIP
    --------------------------------------------------------

    local saved =
        save()

    if not saved then

        ----------------------------------------------------
        -- IMPORTANT:
        --
        -- ArtifactService has already consumed and saved the
        -- bearer artifact, and the vanilla SafeHouse has
        -- already been created.
        --
        -- Do NOT recreate/refund the artifact here.
        --
        -- The artifact remains consumed and ownership is
        -- removed from the in-memory claim index.
        ----------------------------------------------------

        removeClaimRecord(
            claimRecord.id
        )

        if createdSafehouse then

            ----------------------------------------------------
            -- AUTHORITATIVE ENGINE ROLLBACK
            --
            -- The KIPN record failed to persist, so the just-created
            -- vanilla projection must be removed immediately. Build 42
            -- exposes the static SafeHouse.removeSafeHouse(piece) path;
            -- no client release packet is involved.
            ----------------------------------------------------

            local bridge = KIPN.Bridges and KIPN.Bridges.Safehouse
            local snapshot = bridge and bridge.Snapshot
                and bridge.Snapshot(safehouse)
                or nil

            local removedOk, removedResult = runSafehouseMutation(function()
                if not bridge or type(bridge.RemoveAuthoritative) ~= "function" then
                    error("KIPN SafehouseBridge.RemoveAuthoritative unavailable")
                end
                local removed, why = bridge.RemoveAuthoritative(safehouse)
                if not removed then error(tostring(why)) end
                return true
            end)

            if removedOk and removedResult == true then
                if snapshot
                    and KIPN.Server.SafehouseService
                    and type(KIPN.Server.SafehouseService.BroadcastProjectionRemoval) == "function"
                then
                    pcall(KIPN.Server.SafehouseService.BroadcastProjectionRemoval, snapshot)
                end
                log("Removed vanilla SafeHouse after property persistence failure | claim=" .. tostring(claimRecord.id))
            else
                logError("Failed to remove vanilla SafeHouse after property persistence failure | claim="
                    .. tostring(claimRecord.id) .. " | reason=" .. tostring(removedResult))
            end

        end

        logError(
            "Claim ownership could not be persisted. " ..
            "Artifact remains consumed."
        )

        return false,
            "Claim could not be persisted."

    end

    --------------------------------------------------------
    -- BEST-EFFORT SAFEHOUSE LIST SYNC
    --------------------------------------------------------

    if KIPN.Server.SafehouseService
        and type(
            KIPN.Server.SafehouseService.BroadcastSafehouseSync
        ) == "function"
    then

        pcall(
            KIPN.Server.SafehouseService.BroadcastSafehouseSync
        )

    end

    --------------------------------------------------------
    -- SUCCESS
    --------------------------------------------------------

    log(
        "PROPERTY CLAIM SUCCESS | " ..

        "claimId=" ..
        claimRecord.id ..

        " | target=" ..
        targetData.targetId ..

        " | owner=" ..
        playerSteamId ..

        " | zone=" ..
        tostring(targetData.zoneId)
    )

    return true,
        claimRecord

end


------------------------------------------------------------
-- CLAIM EXCAVATION
------------------------------------------------------------
--
-- Mirrors ClaimService.ClaimProperty(), but:
--
--   * sizeTier is required (the target rectangle it produces
--     depends on it -- see ValidateExcavationTarget()).
--
--   * There is no SafeHouse.addSafeHouse() step -- an excavation
--     claim is not a vanilla safehouse.
--
-- This is the point where ownership (a claim record tied to the
-- player's Steam ID) is actually established. Everything before
-- this (Registration -> Claim artifact) deals only in anonymous,
-- bearer artifacts.
------------------------------------------------------------

function ClaimService.ClaimExcavation(
    player,
    position,
    claimItem,
    sizeTier
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
        ClaimService.ValidateExcavationTarget(
            player,
            position,
            sizeTier
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
        ClaimService.ValidateExcavationClaimArtifact(
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
            ClaimService.Types.EXCAVATION
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

    local finalTargetValid,
        finalTargetReason,
        finalTargetData =
        ClaimService.ValidateExcavationTarget(
            player,
            position,
            sizeTier
        )

    if not finalTargetValid then

        log(
            "ClaimExcavation() FAILED during final area validation: " ..
            tostring(finalTargetReason)
        )

        return false,
            finalTargetReason

    end

    targetData =
        finalTargetData

    --------------------------------------------------------
    -- CREATE AUTHORITATIVE OWNERSHIP RECORD
    --------------------------------------------------------

    local claimRecord,
        createReason =
        createClaimRecord(
            player,
            ClaimService.Types.EXCAVATION,
            targetData.targetId,
            targetData.zoneId,
            artifactRecord.id,
            targetData.position,
            {

                rectX1 =
                    targetData.rect.x1,

                rectY1 =
                    targetData.rect.y1,

                rectX2 =
                    targetData.rect.x2,

                rectY2 =
                    targetData.rect.y2,

                sizeTierId =
                    sizeTier.id,

                sizeTierLabel =
                    sizeTier.label,

                sizeWidthTiles =
                    tonumber(sizeTier.widthTiles),

                sizeHeightTiles =
                    tonumber(sizeTier.heightTiles),

            }
        )

    if not claimRecord then

        log(
            "ClaimExcavation() ownership creation failed: " ..
            tostring(createReason)
        )

        return false,
            createReason

    end

    --------------------------------------------------------
    -- CONSUME CLAIM ARTIFACT
    --------------------------------------------------------

    local artifacts =
        getArtifactService()

    if not artifacts then

        removeClaimRecord(
            claimRecord.id
        )

        return false,
            "Artifact service unavailable."

    end

    if type(
        artifacts.ConsumeExcavationClaim
    ) ~= "function"
    then

        removeClaimRecord(
            claimRecord.id
        )

        logError(
            "ArtifactService.ConsumeExcavationClaim() " ..
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
                    artifacts.ConsumeExcavationClaim(
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
            "ClaimExcavation() artifact consumption failed: " ..
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
        -- ArtifactService has already consumed and saved the
        -- bearer artifact.
        --
        -- Do NOT recreate/refund the artifact here.
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
    -- SUCCESS
    --------------------------------------------------------

    log(
        "EXCAVATION CLAIM SUCCESS | " ..

        "claimId=" ..
        claimRecord.id ..

        " | target=" ..
        targetData.targetId ..

        " | owner=" ..
        playerSteamId ..

        " | zone=" ..
        tostring(targetData.zoneId)
    )

    return true,
        claimRecord

end


------------------------------------------------------------
-- PO BOX PRICE
------------------------------------------------------------

local function getPOBoxPrice(boxEntry)

    local poBoxService =
        KIPN.Server.POBoxService

    if boxEntry
        and poBoxService
        and type(poBoxService.GetPrice) == "function"
    then

        local entryPrice =
            tonumber(poBoxService.GetPrice(boxEntry))

        if entryPrice and entryPrice > 0 then
            return math.floor(entryPrice)
        end
    end

    return nil

end


------------------------------------------------------------
-- FIND PLAYER PO BOX CLAIM ITEM
------------------------------------------------------------
--
-- The PO Box claim token ("blank key") is a plain bearer item --
-- unlike Vehicle/Property/Excavation claim artifacts, it has no
-- registration prerequisite and no server-tracked artifactId
-- (see KIPN_ArtifactConfig.lua's PO BOX CONFIGURATION section).
-- Physical possession + correct item type is sufficient, exactly
-- like the mundane crafting materials it was built from.
------------------------------------------------------------

local function findPlayerPOBoxClaimItem(player)

    if not player then

        return nil

    end

    local claimItemType =
        KIPN.Server.POBoxConfig
        and KIPN.Server.POBoxConfig.ClaimItemType

    if not claimItemType then

        logError(
            "findPlayerPOBoxClaimItem() FAILED: " ..
            "POBoxConfig.ClaimItemType unavailable."
        )

        return nil

    end

    local inventory =
        type(player.getInventory) == "function"
        and player:getInventory()

    if not inventory then

        return nil

    end

    return inventory:getFirstTypeRecurse(
        claimItemType
    )

end


------------------------------------------------------------
-- EXACT INVENTORY ITEM MUTATION
--
-- PO Box checkout consumes and restores concrete item objects so a
-- nested Blank Key cannot be silently left behind. ItemContainer's
-- Remove() does not provide a useful success value, therefore the
-- authoritative contents are checked before and after mutation.
------------------------------------------------------------

local function containerHasExactItem(container, wantedItem)

    if not container
        or not wantedItem
        or type(container.getItems) ~= "function"
    then
        return nil
    end

    local ok, found = pcall(function()
        local items = container:getItems()
        if not items then
            return false
        end

        for i = 0, items:size() - 1 do
            if items:get(i) == wantedItem then
                return true
            end
        end

        return false
    end)

    -- found may legitimately be `false` (item confirmed absent), which
    -- `ok and found or nil` would collapse into `nil` -- indistinguishable
    -- from the pcall-failure case and fatal to callers that check for an
    -- explicit `false`. Return the real tri-state instead.
    if not ok then
        return nil
    end

    return found
end

local function getExactItemContainer(item, fallbackContainer)

    if item and type(item.getContainer) == "function" then
        local ok, container = pcall(item.getContainer, item)
        if ok and container then
            return container
        end
    end

    return fallbackContainer
end

local function removeExactInventoryItem(container, item)

    if containerHasExactItem(container, item) ~= true then
        return false
    end

    local ok = pcall(container.Remove, container, item)
    if not ok or containerHasExactItem(container, item) ~= false then
        return false
    end

    if type(sendRemoveItemFromContainer) == "function" then
        pcall(sendRemoveItemFromContainer, container, item)
    end

    return true
end

local function restoreExactInventoryItem(container, item)

    if not container or not item then
        return false
    end

    local ok, restored = pcall(container.AddItem, container, item)
    if not ok or not restored then
        return false
    end

    if type(sendAddItemToContainer) == "function" then
        pcall(sendAddItemToContainer, container, item)
    end

    return true
end


------------------------------------------------------------
-- VALIDATE PO BOX TARGET
------------------------------------------------------------
--
-- Resolves the player-chosen display number against the physical
-- PO Box registry for the Post Office Zone the player is currently
-- standing in. Ownership is indexed by the registry id, allowing
-- separate post offices to use their own human-friendly numbering.
------------------------------------------------------------

function ClaimService.ValidatePOBoxTarget(
    player,
    boxNumber
)

    if not player then

        return false,
            "Player is required."

    end

    local boxNumberValue =
        tonumber(boxNumber)

    if not boxNumberValue
        or boxNumberValue ~= math.floor(boxNumberValue)
        or boxNumberValue < 1
        or boxNumberValue > 999999
    then

        return false,
            "Invalid PO Box number."

    end

    boxNumberValue =
        math.floor(boxNumberValue)

    --------------------------------------------------------
    -- Current physical location.
    --------------------------------------------------------

    local position =
        getPlayerPosition(
            player
        )

    if not position then

        return false,
            "Player location is unavailable."

    end

    --------------------------------------------------------
    -- Current world capability.
    --------------------------------------------------------

    local capable,
        capabilityReason =
        hasClaimCapability(
            position,
            ClaimService.Types.PO_BOX
        )

    if not capable then

        return false,
            capabilityReason

    end

    local poBoxService = KIPN.Server.POBoxService

    if not poBoxService
        or type(poBoxService.ResolvePurchasableBox) ~= "function"
    then
        return false, "Physical PO Box service is unavailable."
    end

    local boxEntry,
        resolveReason,
        zone,
        zoneId =
        poBoxService.ResolvePurchasableBox(
            player,
            boxNumberValue
        )

    if not boxEntry then
        return false, resolveReason or "PO Box not found."
    end

    local existingClaim =
        ClaimService.GetClaimForTarget(
            ClaimService.Types.PO_BOX,
            boxEntry.id
        )

    if existingClaim then
        return false, "This PO Box is already owned."
    end

    local price = getPOBoxPrice(boxEntry)

    if not price or price <= 0 then
        return false, "PO Box price is not configured."
    end

    return true,
        nil,
        {

            boxNumber =
                boxNumberValue,

            registryId =
                tostring(boxEntry.id),

            boxEntry =
                boxEntry,

            size =
                boxEntry.size,

            capacity =
                poBoxService.GetCapacity(boxEntry),

            price =
                price,

            position =
                position,

            zone =
                zone,

            zoneId =
                zoneId,

        }

end


------------------------------------------------------------
-- CLAIM PO BOX
------------------------------------------------------------
--
-- Primary authoritative PO Box purchase operation. Mirrors
-- ClaimService.ClaimProperty()'s validate -> quota -> mutate
-- shape, but PO Box has no ArtifactService-tracked claim
-- artifact and no vanilla-safehouse-style world record to
-- create: instead this charges the player through
-- MarketplaceService, consumes the plain claim item, and issues
-- a real KIPNPOBoxKey bound to the registered container's lock ID.
-- Its ModData carries the physical registry ID and display number
-- (read back later by
-- ArtifactService.FindPlayerPOBoxKeyItems()).
--
-- The client ultimately calls this through the KIPN command
-- router. The server independently revalidates EVERYTHING.
------------------------------------------------------------

function ClaimService.ClaimPOBox(
    player,
    boxNumber
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
        ClaimService.ValidatePOBoxTarget(
            player,
            boxNumber
        )

    if not targetValid then

        return false,
            targetReason

    end

    --------------------------------------------------------
    -- CLAIM ITEM (bearer, not yet consumed)
    --------------------------------------------------------

    local claimItem =
        findPlayerPOBoxClaimItem(
            player
        )

    if not claimItem then

        return false,
            "A Blank Key is required to purchase a PO Box."

    end

    --------------------------------------------------------
    -- MAX CLAIMS PER PLAYER
    --------------------------------------------------------

    local withinQuota,
        quotaReason =
        checkMaxClaimsForType(
            player,
            ClaimService.Types.PO_BOX
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
        ClaimService.Types.PO_BOX,
        targetData.registryId
    )
    then

        log(
            "ClaimPOBox() FAILED: box became claimed " ..
            "before ownership creation."
        )

        return false,
            "This PO Box is already owned."

    end

    --------------------------------------------------------
    -- CREATE AUTHORITATIVE OWNERSHIP RECORD
    --------------------------------------------------------

    local price =
        targetData.price

    local claimRecord,
        createReason =
        createClaimRecord(
            player,
            ClaimService.Types.PO_BOX,
            targetData.registryId,
            targetData.zoneId,
            nil,
            targetData.position,
            {

                boxNumber =
                    targetData.boxNumber,

                poBoxRegistryId =
                    targetData.registryId,

                size =
                    targetData.size,

                capacity =
                    targetData.capacity,

                containerX =
                    targetData.boxEntry.x,

                containerY =
                    targetData.boxEntry.y,

                containerZ =
                    targetData.boxEntry.z,

                price =
                    price,

                purchasedAtRealTime =
                    os.time(),

            }
        )

    if not claimRecord then

        log(
            "ClaimPOBox() ownership creation failed: " ..
            tostring(createReason)
        )

        return false,
            createReason

    end

    --------------------------------------------------------
    -- SPEND + ISSUE (crash-safe)
    --------------------------------------------------------
    --
    -- Everything past this point mutates persistent state: the
    -- rotated container lock, the player's currency, the Blank Key,
    -- the issued ownership key and the persisted claim record. Each
    -- step rolls itself back on a graceful failure, but an
    -- unexpected Lua error (e.g. a missing engine API) would
    -- otherwise unwind the command handler and leave the ownership
    -- record orphaned -- the box permanently "owned" with nothing
    -- charged and no key issued. Run the remainder under pcall so
    -- any raise triggers the same teardown as a graceful failure.
    --------------------------------------------------------

    local completeOk, purchaseOk, purchaseResult = pcall(function()

    --------------------------------------------------------
    -- START A NEW PHYSICAL KEY GENERATION
    --------------------------------------------------------
    --
    -- Every successful owner must receive a newly keyed lock.
    -- This is deliberately done even though normal release also
    -- rotates the lock: it makes acquisition authoritative and
    -- invalidates every original/copy key left by a previous owner,
    -- including keys from legacy or interrupted ownership records.
    -- Rotate before charging so a rekey failure cannot cost the
    -- player currency or their Blank Key.
    --------------------------------------------------------

    local poBoxService =
        KIPN.Server.POBoxService

    local rekeyed,
        rekeyReason

    if poBoxService
        and type(poBoxService.RotateKey) == "function"
    then
        rekeyed,
            rekeyReason =
            poBoxService.RotateKey(
                targetData.registryId
            )
    end

    if not rekeyed then

        removeClaimRecord(
            claimRecord.id
        )

        logError(
            "ClaimPOBox() could not invalidate the previous " ..
            "owner's keys for box " ..
            tostring(targetData.registryId) ..
            ": " .. tostring(rekeyReason)
        )

        return false,
            "PO Box ownership lock could not be changed."

    end

    -- RotateKey mutates the authoritative registry entry. Refresh
    -- the reference used below before assigning the new owner's key.
    if type(poBoxService.GetBox) == "function" then
        targetData.boxEntry =
            poBoxService.GetBox(
                targetData.registryId
            ) or targetData.boxEntry
    end

    --------------------------------------------------------
    -- PREPARE THE OWNERSHIP KEY BEFORE SPENDING ANYTHING
    --------------------------------------------------------
    --
    -- The item is created and keyed while detached. It is not added
    -- to the player until both inventory currency and the Blank Key
    -- have been authoritatively removed.
    --------------------------------------------------------

    local inventory =
        type(player.getInventory) == "function"
        and player:getInventory()

    local keyItemType =
        KIPN.Server.POBoxConfig
        and KIPN.Server.POBoxConfig.KeyItemType

    if not inventory or not keyItemType then
        removeClaimRecord(claimRecord.id)
        return false,
            not inventory
                and "Player inventory is unavailable."
                or "PO Box key configuration is unavailable."
    end

    local keyItem = KIPN.Server.CreateItem(keyItemType)

    if not keyItem then
        removeClaimRecord(claimRecord.id)
        logError(
            "Unable to prepare PO Box key item before payment " ..
            "(item type " .. tostring(keyItemType) .. ")."
        )
        return false, "PO Box key could not be issued."
    end

    local keyAssigned,
        keySerial

    if poBoxService
        and type(poBoxService.AssignKeyItem) == "function"
    then
        keyAssigned,
            keySerial =
            poBoxService.AssignKeyItem(
                keyItem,
                targetData.boxEntry
            )
    end

    if not keyAssigned or not keySerial then
        removeClaimRecord(claimRecord.id)
        logError(
            "Unable to assign the physical PO Box lock id to the " ..
            "prepared key."
        )
        return false, "PO Box key could not be assigned."
    end

    --------------------------------------------------------
    -- REMOVE INVENTORY CURRENCY
    --------------------------------------------------------
    --
    -- A PO Box is bought in person at the counter: the price leaves
    -- the player's physical inventory (matching the confirmation
    -- dialog's wording). ChargeInventoryPurchase() never reaches for
    -- an external provider balance -- so a server whose configured
    -- marketplace provider mod is absent cannot fail this with a
    -- phantom INSUFFICIENT_BALANCE -- and it returns a receipt that
    -- RefundInventoryPurchase() below can actually reverse.
    --------------------------------------------------------

    local marketplace =
        KIPN.Server.MarketplaceService

    if not marketplace
        or type(marketplace.ChargeInventoryPurchase) ~= "function"
    then
        removeClaimRecord(claimRecord.id)
        logError(
            "MarketplaceService inventory purchase transaction is " ..
            "unavailable."
        )
        return false, "Marketplace service unavailable."
    end

    local charged,
        chargeReason,
        paymentReceipt =
        marketplace.ChargeInventoryPurchase(
            player,
            price,
            {
                [claimItem] = true,
            }
        )

    if not charged then
        removeClaimRecord(claimRecord.id)
        return false,
            (chargeReason == "INSUFFICIENT_INVENTORY_CURRENCY"
                or chargeReason == "INSUFFICIENT_CURRENCY")
                and "Insufficient currency in your inventory."
                or (chargeReason or "Payment could not be processed.")
    end

    --------------------------------------------------------
    -- REMOVE THE BLANK KEY
    --------------------------------------------------------

    local claimItemContainer =
        getExactItemContainer(claimItem, inventory)

    if not removeExactInventoryItem(claimItemContainer, claimItem) then
        local paymentRefunded =
            marketplace.RefundInventoryPurchase(paymentReceipt)

        removeClaimRecord(claimRecord.id)
        logError(
            "ClaimPOBox() could not remove the required Blank Key; " ..
            "payment refunded=" .. tostring(paymentRefunded) ..
            ". box=" .. tostring(targetData.registryId)
        )
        return false, "Blank Key could not be consumed."
    end

    --------------------------------------------------------
    -- ADD THE PREPARED PO BOX KEY
    --------------------------------------------------------

    local addKeyOk, addedKey =
        pcall(inventory.AddItem, inventory, keyItem)

    if not addKeyOk or not addedKey then
        local blankRestored =
            restoreExactInventoryItem(claimItemContainer, claimItem)
        local paymentRefunded =
            marketplace.RefundInventoryPurchase(paymentReceipt)

        removeClaimRecord(claimRecord.id)
        logError(
            "ClaimPOBox() could not add the prepared PO Box key; " ..
            "Blank Key rollback=" .. tostring(blankRestored) ..
            ", payment refunded=" .. tostring(paymentRefunded) ..
            ". box=" .. tostring(targetData.registryId)
        )
        return false, "PO Box key could not be added to inventory."
    end

    if type(sendAddItemToContainer) == "function" then
        pcall(sendAddItemToContainer, inventory, keyItem)
    end

    claimRecord.poBoxKeySerial = tostring(keySerial)
    claimRecord.poBoxKeySerials = {
        [tostring(keySerial)] = true,
    }

    if type(keyItem.getID) == "function" then
        local idOk, itemId = pcall(keyItem.getID, keyItem)

        if idOk and itemId ~= nil then
            claimRecord.poBoxKeyItemId = tostring(itemId)
        end
    end

    if type(sendItemStats) == "function" then
        pcall(sendItemStats, keyItem)
    end

    --------------------------------------------------------
    -- PERSIST OWNERSHIP
    --------------------------------------------------------

    local saved =
        save()

    if not saved then

        local issuedKeyRemoved =
            removeExactInventoryItem(inventory, keyItem)
        local blankRestored =
            restoreExactInventoryItem(claimItemContainer, claimItem)
        local paymentRefunded =
            marketplace.RefundInventoryPurchase(paymentReceipt)

        removeClaimRecord(
            claimRecord.id
        )

        logError(
            "PO Box ownership could not be persisted; issued key " ..
            "removed=" .. tostring(issuedKeyRemoved) ..
            ", Blank Key restored=" .. tostring(blankRestored) ..
            ", inventory payment refunded=" ..
            tostring(paymentRefunded)
        )

        return false,
            "PO Box ownership could not be persisted."

    end

    --------------------------------------------------------
    -- SUCCESS
    --------------------------------------------------------

    log(
        "PO BOX CLAIM SUCCESS | " ..

        "claimId=" ..
        claimRecord.id ..

        " | box=" ..
        tostring(targetData.boxNumber) ..

        " | owner=" ..
        playerSteamId ..

        " | zone=" ..
        tostring(targetData.zoneId)
    )

    --------------------------------------------------------
    -- EVENT PRIZE ESCROW RELEASE HOOK
    --
    -- Best-effort and deliberately post-commit: failure to release an
    -- unrelated Event prize must never roll back a valid PO Box purchase.
    --------------------------------------------------------

    local eventRewardService =
        KIPN.Server.EventRewardService

    if eventRewardService
        and type(eventRewardService.OnPOBoxClaimed) == "function"
    then
        local releaseOk,
            releaseResult,
            releaseCount =
            pcall(
                eventRewardService.OnPOBoxClaimed,
                player,
                claimRecord
            )

        if not releaseOk
            or releaseResult ~= true
        then
            logError(
                "ClaimPOBox() event-prize escrow release failed " ..
                "without affecting the successful PO Box claim | " ..
                "claimId=" .. tostring(claimRecord.id) ..
                " | reason=" .. tostring(
                    releaseOk and releaseCount or releaseResult
                )
            )
        else
            log(
                "ClaimPOBox() event-prize escrow release complete | " ..
                "claimId=" .. tostring(claimRecord.id) ..
                " | released=" .. tostring(releaseCount or 0)
            )
        end
    else
        log(
            "ClaimPOBox() event-prize escrow hook unavailable; " ..
            "no event awards were evaluated."
        )
    end

    return true,
        claimRecord

    end)

    --------------------------------------------------------
    -- CRASH-SAFE TEARDOWN
    --------------------------------------------------------
    --
    -- completeOk is false only when the block above raised rather
    -- than returning. The individual steps already unwound their
    -- own partial work before re-raising is impossible here, so the
    -- best we can do is drop the orphaned ownership record and fail
    -- the command cleanly instead of surfacing a raw handler error.
    --------------------------------------------------------

    if not completeOk then

        removeClaimRecord(
            claimRecord.id
        )

        logError(
            "ClaimPOBox() aborted by an unexpected error after the " ..
            "ownership record was created; record rolled back. box=" ..
            tostring(targetData.registryId) ..
            " | err=" .. tostring(purchaseOk)
        )

        return false,
            "PO Box purchase failed."

    end

    return purchaseOk,
        purchaseResult

end


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
-- ClaimExcavation() above). Vehicle and PO Box claims have no
-- rectangle and are never returned here.
--
-- Used by KIPN_ClaimPermissions.lua's enforcement hooks to answer
-- "is (x,y,z) inside a claimed area, and if so, whose?" -- called
-- on every player's OnPlayerMove, so this stays cheap via a
-- bucketed spatial index (below) instead of scanning every claim
-- on every tile move.
------------------------------------------------------------

local SPATIAL_CELL_SIZE =
    20

local SPATIAL_INDEX_TTL_MS =
    1000

local spatialIndexCache =
    nil

local spatialIndexBuiltAtMs =
    nil

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
        or (now - spatialIndexBuiltAtMs) >= SPATIAL_INDEX_TTL_MS
    then

        spatialIndexCache =
            buildSpatialIndex(claimData)

        spatialIndexBuiltAtMs =
            now

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
-- MANAGED SAFEHOUSE LOOKUP / REMOVAL
------------------------------------------------------------

local function findSafehouseForClaim(claim)

    if type(claim) ~= "table"
        or claim.type ~= ClaimService.Types.PROPERTY
    then

        return nil

    end

    local claimRect =
        getClaimRect(claim)

    local list =
        SafeHouse.getSafehouseList()

    local rectFallback =
        nil

    for i = 0,
        list:size() - 1
    do

        local safehouse =
            list:get(i)

        local safehouseId =
            getSafehouseId(safehouse)

        if claim.safehouseId
            and safehouseId
            and tostring(claim.safehouseId)
                == tostring(safehouseId)
        then

            return safehouse

        end

        if not rectFallback
            and rectanglesEqual(
                claimRect,
                getSafehouseRect(safehouse)
            )
        then

            rectFallback =
                safehouse

        end

    end

    return rectFallback

end


local SAFEHOUSE_RELEASE_AUTHORIZED_COMMAND =
    KIPN.Shared
    and KIPN.Shared.Commands
    and KIPN.Shared.Commands.SAFEHOUSE_RELEASE_AUTHORIZED
    or "safehouseReleaseAuthorized"

local CONFIRM_SAFEHOUSE_RELEASE_COMMAND =
    KIPN.Shared
    and KIPN.Shared.Commands
    and KIPN.Shared.Commands.CONFIRM_SAFEHOUSE_RELEASE
    or "confirmSafehouseRelease"

local RECONCILE_SAFEHOUSE_CLAIMS_COMMAND =
    KIPN.Shared
    and KIPN.Shared.Commands
    and KIPN.Shared.Commands.RECONCILE_SAFEHOUSE_CLAIMS
    or "reconcileSafehouseClaims"


local function validateManagedSafehouseForPlayerRelease(
    claim,
    player
)

    local startedAt =
        type(getTimestampMs) == "function"
        and getTimestampMs()
        or 0

    if type(claim) ~= "table"
        or claim.type ~= ClaimService.Types.PROPERTY
    then
        logError(
            "validateManagedSafehouseForPlayerRelease() FAILED: " ..
            "property claim required."
        )
        return false,
            "Property claim is required.",
            nil
    end

    if not player then
        logError(
            "validateManagedSafehouseForPlayerRelease() FAILED: " ..
            "player unavailable."
        )
        return false,
            "Player unavailable.",
            nil
    end

    local safehouse =
        findSafehouseForClaim(claim)

    if not safehouse then
        log(
            "Safehouse release validation: vanilla SafeHouse already absent | " ..
            "claim=" .. tostring(claim.id)
        )
        return true,
            "SAFEHOUSE_ALREADY_MISSING",
            nil
    end

    local liveOwner =
        getSafehouseOwner(safehouse)

    if claim.ownerUsername
        and tostring(liveOwner or "")
            ~= tostring(claim.ownerUsername)
    then
        logError(
            "Safehouse release validation FAILED: vanilla owner mismatch | " ..
            "claim=" .. tostring(claim.id) ..
            " | kipnOwner=" .. tostring(claim.ownerUsername) ..
            " | vanillaOwner=" .. tostring(liveOwner)
        )
        return false,
            "The vanilla safehouse owner no longer matches the KIPN claim.",
            nil
    end

    if not isSafehouseOwner(safehouse, player) then
        logError(
            "Safehouse release validation FAILED: requesting player is not " ..
            "the live vanilla owner | claim=" .. tostring(claim.id)
        )
        return false,
            "You are not the live vanilla safehouse owner.",
            nil
    end

    local finishedAt =
        type(getTimestampMs) == "function"
        and getTimestampMs()
        or startedAt

    log(
        "Meta Time Run Log | validateManagedSafehouseForPlayerRelease ms=" ..
        tostring(finishedAt - startedAt) ..
        " | claim=" .. tostring(claim.id)
    )

    return true,
        "SAFEHOUSE_RELEASE_AUTHORIZED",
        safehouse
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
    -- PROPERTY: REMOVE THE VANILLA ENGINE PROJECTION FIRST.
    --
    -- KIPN is authoritative for property lifecycle. The vanilla
    -- SafeHouse is an engine projection, removed with the same static
    -- API used to create/manage SafeHouse rectangles server-side.
    -- owner_changed is the sole exception: reconciliation is detaching
    -- an old KIPN record from a SafeHouse that now belongs to somebody
    -- else, so that live object must be preserved.
    --------------------------------------------------------

    local removedSafehouseSnapshot = nil

    if claim.type == ClaimService.Types.PROPERTY
        and reason ~= "safehouse_owner_changed"
    then
        local liveSafehouse = findSafehouseForClaim(claim)
        if liveSafehouse then
            local bridge = KIPN.Bridges and KIPN.Bridges.Safehouse
            if not bridge
                or type(bridge.Snapshot) ~= "function"
                or type(bridge.RemoveAuthoritative) ~= "function"
            then
                return false, "Safehouse engine bridge unavailable."
            end

            removedSafehouseSnapshot = bridge.Snapshot(liveSafehouse)
            if not removedSafehouseSnapshot then
                return false, "Safehouse state could not be captured for release."
            end

            local removalOk, removalResult = runSafehouseMutation(function()
                local removed, why = bridge.RemoveAuthoritative(liveSafehouse)
                if not removed then error(tostring(why)) end
                return true
            end)

            if not removalOk or removalResult ~= true then
                logError("Property engine release failed | claim=" .. tostring(claimId)
                    .. " | reason=" .. tostring(removalResult))
                return false, "Vanilla safehouse could not be removed."
            end
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

        -- Transactional rollback: if the engine projection was already
        -- removed, recreate it from the server-side snapshot.
        if removedSafehouseSnapshot then
            local bridge = KIPN.Bridges and KIPN.Bridges.Safehouse
            local restoreOk, restored = runSafehouseMutation(function()
                local safehouse, why = bridge.RestoreSnapshot(removedSafehouseSnapshot)
                if not safehouse then error(tostring(why)) end
                return safehouse
            end)

            if restoreOk and restored then
                if KIPN.Server.SafehouseService
                    and type(KIPN.Server.SafehouseService.BroadcastProjectionForSafehouse) == "function"
                then
                    pcall(KIPN.Server.SafehouseService.BroadcastProjectionForSafehouse, restored)
                end
            else
                logError("CRITICAL: property release persistence failed and SafeHouse rollback failed | claim="
                    .. tostring(claimId) .. " | reason=" .. tostring(restored))
            end
        end

        logError("Claim release could not be persisted.")
        return false, "Claim could not be persisted."
    end

    --------------------------------------------------------
    -- PO BOX LOCK ROTATION -- existing behavior unchanged.
    --------------------------------------------------------

    if claim.type == ClaimService.Types.PO_BOX then
        local poBoxService = KIPN.Server.POBoxService
        local rekeyed, rekeyReason
        if poBoxService and type(poBoxService.RotateKey) == "function" then
            rekeyed, rekeyReason = poBoxService.RotateKey(claim.targetId)
        end
        if not rekeyed then
            claim.active = previousActive
            claim.releasedAtWorldDays = previousReleasedAt
            claim.releaseReason = previousReason
            claimData.byTarget[targetKey] = previousTargetIndex
            save()
            logError("PO Box release could not rotate its lock: " .. tostring(rekeyReason))
            return false, "PO Box lock could not be rotated."
        end
    end

    --------------------------------------------------------
    -- PROPERTY CLIENT PROJECTION.
    --------------------------------------------------------

    if claim.type == ClaimService.Types.PROPERTY then
        if removedSafehouseSnapshot
            and KIPN.Server.SafehouseService
            and type(KIPN.Server.SafehouseService.BroadcastProjectionRemoval) == "function"
        then
            pcall(KIPN.Server.SafehouseService.BroadcastProjectionRemoval, removedSafehouseSnapshot)
        end

        if KIPN.Server.SafehouseService
            and type(KIPN.Server.SafehouseService.BroadcastSafehouseSync) == "function"
        then
            pcall(KIPN.Server.SafehouseService.BroadcastSafehouseSync)
        end
    end

    --------------------------------------------------------
    -- EXCAVATION ADMIN MAP OVERLAY.
    --
    -- The admin-only world-map claim overlay caches excavation
    -- rectangles; refresh it on any excavation release (voluntary,
    -- lazy expiry, or admin). Property releases already refresh it
    -- via BroadcastSafehouseSync above.
    --------------------------------------------------------

    if claim.type == ClaimService.Types.EXCAVATION then
        if KIPN.Server.SafehouseService
            and type(KIPN.Server.SafehouseService.BroadcastAdminClaimOverlay) == "function"
        then
            pcall(KIPN.Server.SafehouseService.BroadcastAdminClaimOverlay)
        end
    end

    --------------------------------------------------------
    -- VEHICLE LIVE PROJECTION -- existing behavior unchanged.
    --------------------------------------------------------

    if claim.type == ClaimService.Types.VEHICLE
        and type(getVehicleById) == "function"
    then
        local vehicle = getVehicleById(tonumber(claim.targetId) or claim.targetId)
        if vehicle then setVehicleOwnershipMetadata(vehicle, nil) end
    end

    log("Claim released | id=" .. tostring(claimId) .. " | target=" .. targetKey)
    return true, "CLAIM_RELEASED"
end


------------------------------------------------------------
-- RECONCILE MANAGED SAFEHOUSES
------------------------------------------------------------
--
-- Reconciliation observes the live engine SafeHouse list and repairs
-- KIPN records if an external/admin mutation happened outside KIPN.
-- KIPN-owned release paths themselves remove the engine projection first
-- and then commit the KIPN ownership transaction.
------------------------------------------------------------

function ClaimService.ReconcileManagedSafehouses()

    --------------------------------------------------------
    -- KIPN IS AUTHORITATIVE.
    --
    -- Vanilla SafeHouse objects are engine projections only. External
    -- vanilla/admin deletion MUST NOT retire a KIPN property record or free
    -- its claim slot. Missing/changed KIPN projections are repaired from the
    -- persisted KIPN rectangle + owner instead.
    --------------------------------------------------------

    local bridge =
        KIPN.Bridges
        and KIPN.Bridges.Safehouse

    if not bridge
        or type(bridge.EnsureClaimProjection) ~= "function"
    then
        logError(
            "ReconcileManagedSafehouses(): KIPN SafehouseBridge unavailable."
        )
        return 0
    end

    local claims =
        ClaimService.GetClaims(
            ClaimService.Types.PROPERTY
        )

    local repaired = 0
    local metadataChanged = false

    for _, claim in pairs(claims) do

        local before =
            bridge.FindForClaim
            and bridge.FindForClaim(claim)
            or nil

        local beforeRect =
            before
            and bridge.GetRect
            and bridge.GetRect(before)
            or nil

        local beforeOwner =
            before
            and bridge.GetOwner
            and bridge.GetOwner(before)
            or nil

        local expectedRect =
            bridge.GetClaimRect
            and bridge.GetClaimRect(claim)
            or nil

        local expectedOwner =
            claim.ownerUsername
            and tostring(claim.ownerUsername)
            or nil

        local alreadyConformed =
            before
            and expectedRect
            and beforeOwner == expectedOwner
            and bridge.RectanglesEqual(beforeRect, expectedRect)

        local ensureOk,
            ensuredOrError =
            runSafehouseMutation(
                function()
                    local safehouse,
                        reason =
                        bridge.EnsureClaimProjection(
                            claim
                        )

                    if not safehouse then
                        error(tostring(reason))
                    end

                    return safehouse
                end
            )

        if not ensureOk
            or not ensuredOrError
        then
            logError(
                "KIPN safehouse projection repair failed | claim=" ..
                tostring(claim.id) ..
                " | reason=" ..
                tostring(ensuredOrError)
            )
        else
            local safehouse = ensuredOrError
            local liveId =
                bridge.GetId
                and bridge.GetId(safehouse)
                or getSafehouseId(safehouse)

            if liveId
                and tostring(claim.safehouseId or "")
                    ~= tostring(liveId)
            then
                claim.safehouseId = liveId
                metadataChanged = true
            end

            if not alreadyConformed then
                repaired = repaired + 1
                log(
                    "KIPN safehouse projection repaired | claim=" ..
                    tostring(claim.id) ..
                    " | owner=" ..
                    tostring(claim.ownerUsername)
                )

                if KIPN.Server.SafehouseService
                    and type(
                        KIPN.Server.SafehouseService.BroadcastProjectionForSafehouse
                    ) == "function"
                then
                    pcall(
                        KIPN.Server.SafehouseService.BroadcastProjectionForSafehouse,
                        safehouse
                    )
                end
            end
        end
    end

    if metadataChanged then
        save()
    end

    return repaired

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

local function rebuildIndexes()

    local claimData =
        getClaimData()

    if not claimData then

        return false

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
-- RECONCILE ORPHANED PO BOX CLAIMS
------------------------------------------------------------
--
-- A completed PO Box purchase always stamps the claim record with
-- poBoxKeySerial (and a poBoxKeySerials set) before it is
-- persisted. A record that survives with neither is the residue of
-- a ClaimPOBox() call that raised after createClaimRecord() but
-- before payment/key issuance -- the box would otherwise stay
-- permanently "owned" with nothing charged and no key in
-- existence. Drop those on boot so the box becomes purchasable
-- again. Runs after rebuildIndexes() so removeClaimRecord() can
-- unwind the derived indexes.
------------------------------------------------------------

local function reconcileOrphanedPOBoxClaims()

    local claimData =
        getClaimData()

    if not claimData
        or type(claimData.records) ~= "table"
    then
        return 0
    end

    local orphanIds =
        {}

    for claimId, record in pairs(claimData.records) do

        if type(record) == "table"
            and record.type == ClaimService.Types.PO_BOX
            and record.active ~= false
        then

            local hasSerial =
                type(record.poBoxKeySerial) == "string"
                and record.poBoxKeySerial ~= ""

            local hasSerialSet = false

            if type(record.poBoxKeySerials) == "table" then
                for _ in pairs(record.poBoxKeySerials) do
                    hasSerialSet = true
                    break
                end
            end

            if not hasSerial and not hasSerialSet then
                orphanIds[#orphanIds + 1] = record.id or tostring(claimId)
            end

        end

    end

    for _, orphanId in ipairs(orphanIds) do

        logError(
            "Dropping orphaned PO Box claim with no issued key | id=" ..
            tostring(orphanId) ..
            " (residue of an interrupted purchase)"
        )

        removeClaimRecord(orphanId)

    end

    return #orphanIds

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

local function handleClaimVehicleCommand(
    player,
    args
)

    args =
        args or {}

    local vehicleId =
        args.vehicleId

    if vehicleId == nil
        or type(getVehicleById) ~= "function"
    then

        return false,
            "Vehicle could not be resolved."

    end

    local vehicle =
        getVehicleById(
            vehicleId
        )

    if not vehicle then

        return false,
            "Vehicle could not be resolved."

    end

    local artifacts =
        getArtifactService()

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
        ClaimService.ClaimVehicle(
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
-- COMMAND: CLAIM PROPERTY
------------------------------------------------------------
--
-- Client -> server entry point for the right-click "Claim This
-- Location" context menu action (see
-- client/KIPN_PropertyClaimMenu.lua).
--
-- Unlike CLAIM_VEHICLE, there is no client-supplied target ID:
-- the target is wherever the player is CURRENTLY standing,
-- resolved server-side via getPlayerPosition(), so a stale or
-- forged position can never be submitted by the client.
------------------------------------------------------------

local function handleClaimPropertyCommand(
    player,
    _args
)

    local position =
        getPlayerPosition(
            player
        )

    if not position then

        return false,
            "Player location is unavailable."

    end

    local artifacts =
        getArtifactService()

    if not artifacts
        or type(
            artifacts.FindPlayerPropertyClaimArtifact
        ) ~= "function"
    then

        logError(
            "ArtifactService.FindPlayerPropertyClaimArtifact() " ..
            "is unavailable."
        )

        return false,
            "Artifact service unavailable."

    end

    local claimItem,
        _record,
        findReason =
        artifacts.FindPlayerPropertyClaimArtifact(
            player
        )

    if not claimItem then

        return false,
            findReason
                or "Property claim artifact required."

    end

    local claimed,
        result =
        ClaimService.ClaimProperty(
            player,
            position,
            claimItem
        )

    if not claimed then

        return false,
            result

    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.PROPERTY_CLAIM_SUCCESSFUL,
        {}
    )

    return true,
        "CLAIM_SUCCESSFUL"

end


------------------------------------------------------------
-- COMMAND: CLAIM EXCAVATION
------------------------------------------------------------
--
-- Client -> server entry point for the mouse-driven "Claim Land"
-- placement overlay (client/KIPN_ExcavationPlacementOverlay.lua).
--
-- UNLIKE Property (anchored to wherever the player is currently
-- standing), the excavation target is wherever the player clicked
-- during placement -- args.targetX/Y/Z, a hint from the client.
-- This is re-validated server-side against a maximum distance from
-- the player's OWN current position (EXCAVATION_PLACEMENT_RANGE_TILES)
-- so a forged/stale coordinate can only ever select a location the
-- player is actually standing near, never an arbitrary point on
-- the map.
--
-- The size tier is read from the claim artifact's own record
-- (baked in at issuance time by handleIssueExcavationClaimCommand
-- in KIPN_ArtifactService.lua), not from client-supplied args, so
-- a player cannot claim a larger area than they paid for.
------------------------------------------------------------

local EXCAVATION_PLACEMENT_RANGE_TILES = 15

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

local function resolveExcavationPermitTierFromAdminConfig(
    record,
    claimItem
)

    --------------------------------------------------------
    -- AUTHORITATIVE CLASS
    --------------------------------------------------------
    --
    -- ArtifactService owns the permit record. The permit carries
    -- ONLY its purchased class identity: small / medium / large.
    -- Numeric dimensions are resolved from ClaimConfig when the
    -- ownership claim is made, so admin-assigned dimensions remain
    -- authoritative for each class.
    --------------------------------------------------------

    local metadata =
        type(record) == "table"
        and type(record.metadata) == "table"
        and record.metadata
        or nil

    local sizeTierData =
        metadata
        and metadata.sizeTier
        or nil

    local sizeTierId

    if type(sizeTierData) == "table" then
        sizeTierId =
            normalizeExcavationPermitClass(
                sizeTierData.id
                or sizeTierData.classSize
                or sizeTierData.sizeClass
            )
    elseif type(sizeTierData) == "string" then
        sizeTierId =
            normalizeExcavationPermitClass(
                sizeTierData
            )
    end

    if not sizeTierId and metadata then
        sizeTierId =
            normalizeExcavationPermitClass(
                metadata.classSize
                or metadata.sizeTierId
                or metadata.sizeClass
            )
    end

    --------------------------------------------------------
    -- LEGACY SERVER-VALIDATED ITEM TYPE FALLBACK
    --------------------------------------------------------
    --
    -- ArtifactService already validated this physical item against
    -- its authoritative artifact record. This fallback exists only
    -- for permits issued by older builds before canonical class
    -- metadata was guaranteed. Display name and client ModData are
    -- intentionally NOT trusted here.
    --------------------------------------------------------

    if not sizeTierId then

        local fullType

        if claimItem
            and type(claimItem.getFullType) == "function"
        then

            local ok, result =
                pcall(
                    claimItem.getFullType,
                    claimItem
                )

            if ok then
                fullType = result
            end

        end

        sizeTierId =
            getExcavationPermitClassFromItemType(
                fullType
            )

    end

    if not sizeTierId then

        logError(
            "resolveExcavationPermitTierFromAdminConfig() FAILED: " ..
            "validated excavation permit has no Small/Medium/Large class | " ..
            "artifact=" .. tostring(record and record.id or "nil")
        )

        return nil,
            "Excavation permit is missing a valid Small, Medium, or Large class."

    end

    --------------------------------------------------------
    -- ADMIN-ASSIGNED DIMENSIONS
    --------------------------------------------------------

    local claimConfig =
        getClaimConfig()

    if not claimConfig
        or type(
            claimConfig.GetExcavationSizeTierById
        ) ~= "function"
    then

        logError(
            "resolveExcavationPermitTierFromAdminConfig() FAILED: " ..
            "ClaimConfig size-tier lookup unavailable."
        )

        return nil,
            "Excavation claim dimensions are unavailable."

    end

    local configuredTier =
        claimConfig.GetExcavationSizeTierById(
            sizeTierId
        )

    local widthTiles =
        configuredTier
        and tonumber(configuredTier.widthTiles)

    local heightTiles =
        configuredTier
        and tonumber(configuredTier.heightTiles)

    if type(configuredTier) ~= "table"
        or not widthTiles
        or not heightTiles
        or widthTiles <= 0
        or heightTiles <= 0
    then

        logError(
            "resolveExcavationPermitTierFromAdminConfig() FAILED: " ..
            "admin dimensions unavailable | class=" ..
            tostring(sizeTierId)
        )

        return nil,
            "Unable to resolve the admin-assigned dimensions for this excavation permit."

    end

    local resolvedTier = {
        id = sizeTierId,
        label = configuredTier.label or (
            string.upper(string.sub(sizeTierId, 1, 1)) ..
            string.sub(sizeTierId, 2)
        ),
        widthTiles = math.max(1, math.floor(widthTiles)),
        heightTiles = math.max(1, math.floor(heightTiles)),
        price = tonumber(configuredTier.price),
    }

    log(
        "Excavation permit class resolved from admin configuration | " ..
        "artifact=" .. tostring(record and record.id or "nil") ..
        " | class=" .. tostring(resolvedTier.id) ..
        " | dimensions=" ..
        tostring(resolvedTier.widthTiles) ..
        "x" ..
        tostring(resolvedTier.heightTiles)
    )

    return resolvedTier,
        nil

end

local function handleClaimExcavationCommand(
    player,
    args
)

    args =
        args or {}

    local playerPosition =
        getPlayerPosition(
            player
        )

    if not playerPosition then

        return false,
            "Player location is unavailable."

    end

    local targetX =
        tonumber(args.targetX)

    local targetY =
        tonumber(args.targetY)

    local targetZ =
        tonumber(args.targetZ)

    if not targetX
        or not targetY
        or not targetZ
    then

        return false,
            "A target location must be selected."

    end

    targetX =
        math.floor(targetX)

    targetY =
        math.floor(targetY)

    targetZ =
        math.floor(targetZ)

    if targetZ ~= playerPosition.z then

        return false,
            "The selected location must be on your current level."

    end

    local distance =
        math.max(
            math.abs(targetX - playerPosition.x),
            math.abs(targetY - playerPosition.y)
        )

    if distance > EXCAVATION_PLACEMENT_RANGE_TILES then

        return false,
            "The selected location is too far away."

    end

    local position = {

        x = targetX,

        y = targetY,

        z = targetZ,

    }

    local artifacts =
        getArtifactService()

    if not artifacts
        or type(
            artifacts.FindPlayerExcavationClaimArtifact
        ) ~= "function"
    then

        logError(
            "ArtifactService.FindPlayerExcavationClaimArtifact() " ..
            "is unavailable."
        )

        return false,
            "Artifact service unavailable."

    end

    local claimItem,
        record,
        findReason =
        artifacts.FindPlayerExcavationClaimArtifact(
            player
        )

    if not claimItem then

        return false,
            findReason
                or "Excavation claim artifact required."

    end

    local sizeTier,
        sizeReason =
        resolveExcavationPermitTierFromAdminConfig(
            record,
            claimItem
        )

    if not sizeTier then

        logError(
            "handleClaimExcavationCommand() FAILED: " ..
            tostring(sizeReason)
        )

        return false,
            sizeReason

    end

    local claimed,
        result =
        ClaimService.ClaimExcavation(
            player,
            position,
            claimItem,
            sizeTier
        )

    if not claimed then

        return false,
            result

    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.EXCAVATION_CLAIM_SUCCESSFUL,
        {}
    )

    -- Refresh the admin-only world-map claim overlay so a newly
    -- staked excavation rectangle appears without a re-toggle.
    if KIPN.Server.SafehouseService
        and type(KIPN.Server.SafehouseService.BroadcastAdminClaimOverlay) == "function"
    then
        pcall(KIPN.Server.SafehouseService.BroadcastAdminClaimOverlay)
    end

    return true,
        "CLAIM_SUCCESSFUL"

end


------------------------------------------------------------
-- COMMAND: BUY PO BOX
------------------------------------------------------------
--
-- Client -> server entry point for the "PURCHASE" button on the
-- Postal Services terminal screen (client/KIPN_PostalServices.lua).
--
-- args.boxNumber is a client-chosen hint only; ClaimService.
-- ClaimPOBox() independently re-validates it, the player's own
-- live position/zone, ownership, quota, and payment.
------------------------------------------------------------

local function handleBuyPOBoxCommand(
    player,
    args
)

    args =
        args or {}

    local claimed,
        result =
        ClaimService.ClaimPOBox(
            player,
            args.boxNumber
        )

    if not claimed then

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.PURCHASE_RESULT,
            {
                success = false,
                reason = result or "PO Box purchase failed.",
            }
        )

        return true

    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.PURCHASE_RESULT,
        {

            success =
                true,

            boxNumber =
                result.boxNumber,

            size =
                result.size,

        }
    )

    return true,
        "CLAIM_SUCCESSFUL"

end


------------------------------------------------------------
-- FORMAT PO BOX PURCHASE DATE
------------------------------------------------------------
--
-- Postal Services displays purchase dates for a numbered box
-- rental, unlike the rest of KIPN's ownership records, which are
-- expressed purely in world-day counts. os.time() (captured once,
-- at purchase, into the claim record's purchasedAtRealTime extra
-- field) is real/wall-clock time and is formatted here rather
-- than on the client so the client never needs its own os.date()
-- call against a value it did not create.
------------------------------------------------------------

local function formatPOBoxPurchaseDate(claim)

    local timestamp =
        claim
        and tonumber(
            claim.purchasedAtRealTime
        )

    if not timestamp then

        return nil

    end

    local ok, formatted =
        pcall(
            os.date,
            "%m/%d/%y",
            timestamp
        )

    if not ok then

        return nil

    end

    return formatted

end


------------------------------------------------------------
-- COMMAND: GET PO BOXES
------------------------------------------------------------
--
-- Public, read-only listing of every numbered PO Box and its
-- current ownership/status, for the Postal Services terminal
-- screen's table. Any authenticated player may view this.
------------------------------------------------------------

local function handleGetPOBoxesCommand(
    player,
    _args
)

    local boxes = {}
    local poBoxService = KIPN.Server.POBoxService
    local zone, zoneId

    if poBoxService
        and type(poBoxService.GetPlayerPostOffice) == "function"
    then
        zone, zoneId = poBoxService.GetPlayerPostOffice(player)
    end

    local entries =
        zoneId
        and poBoxService.GetBoxesForZone(zoneId)
        or {}

    for _, boxEntry in ipairs(entries) do

        local claim =
            ClaimService.GetClaimForTarget(
                ClaimService.Types.PO_BOX,
                boxEntry.id
            )

        boxes[#boxes + 1] = {

            number =
                boxEntry.number,

            id =
                boxEntry.id,

            size =
                poBoxService.GetLabel(boxEntry),

            sizeKey =
                boxEntry.size,

            capacity =
                poBoxService.GetCapacity(boxEntry),

            price =
                poBoxService.GetPrice(boxEntry),

            x =
                boxEntry.x,

            y =
                boxEntry.y,

            z =
                boxEntry.z,

            owner =
                claim and claim.ownerUsername
                or nil,

            purchased =
                claim
                and formatPOBoxPurchaseDate(claim)
                or nil,

        }

    end

    local currencyType = "Base.Money"
    local currencyValue = 1
    if KIPN.Server.Settings then
        local settingType = KIPN.Server.Settings.Get("Marketplace", "MarketplaceCurrencyItemType", "Base.Money")
        if type(settingType) == "string" and settingType ~= "" then
            currencyType = settingType
        end
        local settingValue = tonumber(KIPN.Server.Settings.Get("Marketplace", "MarketplaceCurrencyItemValue", 1))
        if settingValue and settingValue > 0 then
            currencyValue = math.floor(settingValue)
        end
    end

    local claimItemType = "Base.Key_Blank"
    if KIPN.Server.POBoxConfig and KIPN.Server.POBoxConfig.ClaimItemType then
        claimItemType = KIPN.Server.POBoxConfig.ClaimItemType
    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.PO_BOXES_DATA,
        {

            boxes =
                boxes,

            zoneId =
                zoneId,

            zoneLabel =
                zone
                and zone.metadata
                and zone.metadata.label
                or "Post Office",

            requiresPostOffice =
                zoneId == nil,

            currencyType = currencyType,
            currencyValue = currencyValue,
            claimItemType = claimItemType,

        }
    )

    return true

end


------------------------------------------------------------
-- VALID CARRIED PO BOX KEYS
------------------------------------------------------------

local function getPOBoxKeyCopyFee()
    local configured = KIPN.Server.POBoxConfig
        and tonumber(KIPN.Server.POBoxConfig.KeyCopyPrice)

    return configured and configured > 0
        and math.floor(configured)
        or nil
end

local function getValidCarriedPOBoxKeys(player)
    local artifacts = getArtifactService()
    local poBoxService = KIPN.Server.POBoxService
    local playerSteamId = getPlayerSteamId(player)
    local results = {}
    local seenBoxes = {}
    local lifecycleChanged = false

    if not artifacts
        or type(artifacts.FindPlayerPOBoxKeyItems) ~= "function"
        or not poBoxService
        or not playerSteamId
    then
        return results
    end

    local keys = artifacts.FindPlayerPOBoxKeyItems(player)

    for _, keyEntry in ipairs(keys) do
        local boxRecord = poBoxService.GetBox(keyEntry.boxId)
        local claim = boxRecord
            and ClaimService.GetClaimForTarget(
                ClaimService.Types.PO_BOX,
                boxRecord.id
            )

        if claim
            and tostring(claim.ownerSteamId) == tostring(playerSteamId)
            and keyEntry.item
        then
            local modData = keyEntry.item:getModData()
            local claimSerial = claim.poBoxKeySerial
            local itemSerial = modData and modData.KIPNPOBoxKeySerial
            local authorizedSerial = itemSerial
                and (
                    tostring(itemSerial) == tostring(claimSerial or "")
                    or (
                        type(claim.poBoxKeySerials) == "table"
                        and claim.poBoxKeySerials[tostring(itemSerial)] == true
                    )
                )

            -- Migrate keys issued before lifecycle serials existed and
            -- repair an owned key whose serial is not authorized.
            if not claimSerial or not authorizedSerial
            then
                local assigned,
                    assignedSerial =
                    poBoxService.AssignKeyItem(
                        keyEntry.item,
                        boxRecord,
                        claimSerial
                    )

                if assigned and assignedSerial then
                    if not claim.poBoxKeySerial then
                        claim.poBoxKeySerial = tostring(assignedSerial)
                    end

                    itemSerial = tostring(assignedSerial)
                    claim.poBoxKeySerials =
                        type(claim.poBoxKeySerials) == "table"
                        and claim.poBoxKeySerials
                        or {}
                    claim.poBoxKeySerials[itemSerial] = true
                    authorizedSerial = true
                    lifecycleChanged = true

                    if type(keyEntry.item.getID) == "function" then
                        claim.poBoxKeyItemId =
                            tostring(keyEntry.item:getID())
                    end

                    if type(sendItemStats) == "function" then
                        sendItemStats(keyEntry.item)
                    end
                end
            end

            if claim.poBoxKeySerial
                and (
                    type(claim.poBoxKeySerials) ~= "table"
                    or claim.poBoxKeySerials[
                        tostring(claim.poBoxKeySerial)
                    ] ~= true
                )
            then
                claim.poBoxKeySerials =
                    type(claim.poBoxKeySerials) == "table"
                    and claim.poBoxKeySerials
                    or {}
                claim.poBoxKeySerials[
                    tostring(claim.poBoxKeySerial)
                ] = true
                lifecycleChanged = true
            end

            local keyIdOk, itemKeyId = pcall(function()
                return keyEntry.item:getKeyId()
            end)

            local valid = authorizedSerial
                and keyIdOk
                and tonumber(itemKeyId) == tonumber(boxRecord.keyId)

            if valid and not seenBoxes[tostring(boxRecord.id)] then
                seenBoxes[tostring(boxRecord.id)] = true
                results[#results + 1] = {
                    item = keyEntry.item,
                    box = boxRecord,
                    claim = claim,
                }
            end
        end
    end

    if lifecycleChanged and not save() then
        logError(
            "PO Box key lifecycle migration could not be persisted."
        )
    end

    table.sort(results, function(a, b)
        return (tonumber(a.box.number) or 0)
            < (tonumber(b.box.number) or 0)
    end)

    return results
end


------------------------------------------------------------
-- COMMAND: COPY PO BOX KEY
------------------------------------------------------------

local function handleCopyPOBoxKeyCommand(player, args)
    args = type(args) == "table" and args or {}
    local wantedBoxId = args.boxId and tostring(args.boxId)
    local selected

    for _, entry in ipairs(getValidCarriedPOBoxKeys(player)) do
        if tostring(entry.box.id) == tostring(wantedBoxId) then
            selected = entry
            break
        end
    end

    local function sendResult(success, reason)
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.PO_BOX_KEY_COPY_RESULT,
            {
                success = success,
                reason = reason,
                boxId = selected and selected.box.id or wantedBoxId,
                boxNumber = selected and selected.box.number or nil,
                fee = getPOBoxKeyCopyFee(),
            }
        )
    end

    if not selected then
        sendResult(false, "VALID_PO_BOX_KEY_REQUIRED")
        return false, "A valid owned PO Box key is required."
    end

    local fee = getPOBoxKeyCopyFee()
    if not fee then
        sendResult(false, "COPY_FEE_UNAVAILABLE")
        return false, "PO Box key copy fee is unavailable."
    end

    local marketplace = KIPN.Server.MarketplaceService
    if not marketplace or type(marketplace.ChargeInventoryPurchase) ~= "function" then
        sendResult(false, "MARKETPLACE_UNAVAILABLE")
        return false, "Marketplace service unavailable."
    end

    -- Inventory-only, like the PO Box purchase itself: the fee leaves
    -- the player's inventory and the receipt lets every post-charge
    -- failure below refund it.
    local charged, chargeReason, paymentReceipt =
        marketplace.ChargeInventoryPurchase(
            player,
            fee
        )

    if not charged then
        local reason =
            (chargeReason == "INSUFFICIENT_INVENTORY_CURRENCY"
                or chargeReason == "INSUFFICIENT_CURRENCY")
                and "INSUFFICIENT_CURRENCY"
                or (chargeReason or "PAYMENT_FAILED")
        sendResult(false, reason)
        return false, reason
    end

    local artifacts = getArtifactService()
    local keyItem,
        droppedOnGround

    if artifacts
        and type(artifacts.GiveItemToPlayer) == "function"
    then
        keyItem,
            droppedOnGround =
            artifacts.GiveItemToPlayer(
            player,
            KIPN.Server.POBoxConfig.KeyItemType
        )
    end

    if not keyItem then
        local feeRefunded =
            marketplace.RefundInventoryPurchase(paymentReceipt)
        logError(
            "PO Box key copy failed after charge; fee refunded=" ..
            tostring(feeRefunded) .. ". box=" .. tostring(selected.box.id)
        )
        sendResult(false, "KEY_COPY_ISSUE_FAILED")
        return false, "PO Box key copy could not be issued."
    end

    local assigned,
        copiedSerial =
        KIPN.Server.POBoxService.AssignKeyItem(
        keyItem,
        selected.box
    )

    if not assigned or not copiedSerial then
        local removedKey =
            removeExactInventoryItem(
                getExactItemContainer(keyItem, player:getInventory()),
                keyItem
            )
        local feeRefunded =
            marketplace.RefundInventoryPurchase(paymentReceipt)
        logError(
            "PO Box copied key could not be bound after charge; " ..
            "key removed=" .. tostring(removedKey) ..
            ", fee refunded=" .. tostring(feeRefunded) ..
            ". box=" .. tostring(selected.box.id)
        )
        sendResult(false, "KEY_COPY_BIND_FAILED")
        return false, "PO Box key copy could not be bound."
    end

    if type(keyItem.setName) == "function" then
        keyItem:setName("Copy of PO Box " .. tostring(selected.box.keyId))
    end

    selected.claim.poBoxKeySerials =
        type(selected.claim.poBoxKeySerials) == "table"
        and selected.claim.poBoxKeySerials
        or {}
    selected.claim.poBoxKeySerials[tostring(copiedSerial)] = true

    if not save() then
        selected.claim.poBoxKeySerials[tostring(copiedSerial)] = nil

        local removedKey =
            removeExactInventoryItem(
                getExactItemContainer(keyItem, player:getInventory()),
                keyItem
            )
        local feeRefunded =
            marketplace.RefundInventoryPurchase(paymentReceipt)

        logError(
            "PO Box copied key authorization could not be persisted " ..
            "after charge; key removed=" .. tostring(removedKey) ..
            ", fee refunded=" .. tostring(feeRefunded) ..
            ". box=" .. tostring(selected.box.id)
        )
        sendResult(false, "KEY_COPY_SAVE_FAILED")
        return false, "PO Box key copy could not be persisted."
    end

    if droppedOnGround then
        local worldItem = keyItem:getWorldItem()
        if worldItem
            and type(worldItem.transmitCompleteItemToClients) == "function"
        then
            worldItem:transmitCompleteItemToClients()
        end
    elseif type(sendItemStats) == "function" then
        sendItemStats(keyItem)
    end

    sendResult(true)
    return true, "PO_BOX_KEY_COPIED"
end


------------------------------------------------------------
-- COMMAND: GET MY PO BOX KEYS
------------------------------------------------------------
--
-- Returns structured rows for valid owned KIPNPOBoxKey items the
-- requesting player is carrying, plus the configured copy fee.
------------------------------------------------------------

local function handleGetMyPOBoxKeysCommand(
    player,
    _args
)

    local keyRows = {}

    for _, entry in ipairs(getValidCarriedPOBoxKeys(player)) do
        keyRows[#keyRows + 1] = {
            boxId = entry.box.id,
            number = entry.box.number,
            size = entry.box.size,
        }
    end

    local currencyType = "Base.Money"
    local currencyValue = 1
    if KIPN.Server.Settings then
        local settingType = KIPN.Server.Settings.Get("Marketplace", "MarketplaceCurrencyItemType", "Base.Money")
        if type(settingType) == "string" and settingType ~= "" then
            currencyType = settingType
        end
        local settingValue = tonumber(KIPN.Server.Settings.Get("Marketplace", "MarketplaceCurrencyItemValue", 1))
        if settingValue and settingValue > 0 then
            currencyValue = math.floor(settingValue)
        end
    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.MY_POBOX_KEYS_DATA,
        {
            keys = keyRows,
            copyFee = getPOBoxKeyCopyFee(),
            currencyType = currencyType,
            currencyValue = currencyValue,
        }
    )

    return true

end


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

    ClaimService.ReconcileManagedSafehouses()

    local claims =
        ClaimService.GetPlayerClaims(
            player
        )

    local claimConfig =
        getClaimConfig()

    local nowDays =
        getWorldDays()

    ------------------------------------------------------------
    -- PO BOX KEYS CURRENTLY HELD
    --
    -- PO Box claims are only surfaced below when the player is
    -- physically carrying the matching key -- re-verified here
    -- against their live inventory, the same way
    -- handleGetMyPOBoxKeysCommand() does.
    ------------------------------------------------------------

    local heldPOBoxKeys = {}

    local artifacts =
        getArtifactService()

    if artifacts
        and type(
            artifacts.FindPlayerPOBoxKeyItems
        ) == "function"
    then

        local keys =
            artifacts.FindPlayerPOBoxKeyItems(
                player
            )

        for _, entry in ipairs(keys) do

            if entry.boxId then

                heldPOBoxKeys[
                    tostring(entry.boxId)
                ] = true

            end

        end

    end

    local results = {}

    local function appendManagedRecord(record, safehouse)

        local isUnkeyedPOBox =
            record.type
                == ClaimService.Types.PO_BOX
            and not heldPOBoxKeys[
                tostring(record.targetId)
            ]

        if isUnkeyedPOBox then

            return

        end

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
-- COMMAND: RECONCILE SAFEHOUSE CLAIMS
--
-- Vanilla SafeHouse changes are announced to clients through
-- Events.OnSafehousesChanged. There is no equivalent server event
-- carrying the changed SafeHouse into this service, so the client
-- bridge sends this command as a STATE-CHANGED HINT.
--
-- SECURITY:
--   * No client-provided ownership/safehouse data is trusted.
--   * The server independently walks its authoritative vanilla
--     SafeHouse list through ReconcileManagedSafehouses().
--   * This handles vanilla releases performed outside KIPN as well
--     as owner/admin changes.
------------------------------------------------------------

local function handleReconcileSafehouseClaimsCommand(
    player,
    _args
)

    local reconciled =
        ClaimService.ReconcileManagedSafehouses()

    log(
        "Safehouse reconciliation requested after vanilla state change | " ..
        "reconciled=" ..
        tostring(reconciled or 0) ..
        " | player=" ..
        tostring(
            player
            and getPlayerName(player)
            or "unknown"
        )
    )

    -- Return the caller's fresh projection after the authoritative
    -- reconciliation. handleGetMyClaimsCommand() performs another
    -- idempotent reconciliation before composing the response, which
    -- is intentional and safe.
    return handleGetMyClaimsCommand(
        player,
        {}
    )

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

    -- For managed properties, preserve the existing anti-drift check before
    -- KIPN removes the engine projection. A missing projection is still safe
    -- to retire; a projection whose owner changed is not.
    if claim.type == ClaimService.Types.PROPERTY then
        local valid, validationReason = validateManagedSafehouseForPlayerRelease(claim, player)
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
-- COMMAND: RELEASE SAFEHOUSE FROM THE VANILLA PANEL
--
-- The client supplies the exact x/y/w/h rectangle only as a NAME for the
-- SafeHouse it had open. The server resolves that rectangle against its own
-- live list, rechecks owner/admin authority, and then routes managed claims
-- through ClaimService.ReleaseClaim(). Nothing client-supplied is trusted as
-- proof of ownership.
------------------------------------------------------------

local function hasSafehouseAdminAccess(player)
    local service = KIPN.Server.SafehouseService
    if service and type(service.HasAdminAccess) == "function" then
        local ok, allowed = pcall(service.HasAdminAccess, player)
        if ok and allowed == true then return true end
    end

    if player and type(player.getRole) == "function" and Capability then
        local ok, allowed = pcall(function()
            local role = player:getRole()
            return role and role:hasCapability(Capability.CanSetupSafehouses)
        end)
        if ok and allowed == true then return true end
    end
    return false
end

local function findManagedClaimForSafehouse(safehouse)
    if not safehouse then return nil end
    local data = getClaimData()
    if not data or type(data.records) ~= "table" then return nil end

    -- Rect fallback must compare against the buffered engine-projection rect
    -- (bridge.GetClaimRect), not the raw claimed footprint (getClaimRect) --
    -- the live safehouse is grown by the no-entry buffer, so the two no
    -- longer match 1:1.
    local bridge = KIPN.Bridges and KIPN.Bridges.Safehouse

    for _, record in pairs(data.records) do
        if type(record) == "table"
            and record.active ~= false
            and record.type == ClaimService.Types.PROPERTY
            and (
                (record.safehouseId and getSafehouseId(safehouse)
                    and tostring(record.safehouseId) == tostring(getSafehouseId(safehouse)))
                or (bridge
                    and bridge.GetClaimRect
                    and rectanglesEqual(bridge.GetClaimRect(record), getSafehouseRect(safehouse)))
            )
        then
            return record
        end
    end
    return nil
end

local function handleReleaseSafehouseCommand(player, args)
    if not player or type(args) ~= "table" then return false, "INVALID_REQUEST" end

    local x, y = tonumber(args.x), tonumber(args.y)
    local w, h = tonumber(args.w), tonumber(args.h)
    if not x or not y or not w or not h or w < 1 or h < 1 then
        return false, "INVALID_SAFEHOUSE_RECT"
    end

    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    local safehouse
    if SafeHouse then
        local ok, result = pcall(function()
            return SafeHouse.getSafeHouse(x, y, w, h)
        end)
        if ok then safehouse = result end
    end

    if not safehouse then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
            code = "SAFEHOUSE_NOT_FOUND",
            message = "That safehouse no longer exists.",
        })
        return true
    end

    local admin = hasSafehouseAdminAccess(player)
    local managedClaim = findManagedClaimForSafehouse(safehouse)

    if managedClaim then
        local requesterSteamId = getPlayerSteamId(player)
        local ownsKIPNClaim = requesterSteamId
            and tostring(managedClaim.ownerSteamId) == tostring(requesterSteamId)

        if not admin and not ownsKIPNClaim then
            KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
                code = "NOT_CLAIM_OWNER",
                message = "You do not own that KIPN safehouse claim.",
            })
            return true
        end

        if not admin and not isSafehouseOwner(safehouse, player) then
            KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
                code = "SAFEHOUSE_OWNER_MISMATCH",
                message = "The live safehouse owner no longer matches this KIPN claim.",
            })
            return true
        end

        local released, why = ClaimService.ReleaseClaim(
            managedClaim.id,
            admin and "admin_released" or "player_released",
            player
        )
        if not released then
            KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
                code = "RELEASE_FAILED", message = tostring(why),
            })
            return true
        end

        handleGetMyClaimsCommand(player, {})
        return true
    end

    -- Legacy/admin vanilla SafeHouse with no KIPN ownership record. KIPN still
    -- owns the panel interaction, but it does not manufacture a KIPN claim for it.
    if not admin and not isSafehouseOwner(safehouse, player) then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
            code = "NOT_SAFEHOUSE_OWNER",
            message = "You do not own that safehouse.",
        })
        return true
    end

    local bridge = KIPN.Bridges and KIPN.Bridges.Safehouse
    if not bridge or type(bridge.Snapshot) ~= "function"
        or type(bridge.RemoveAuthoritative) ~= "function"
    then
        return false, "SAFEHOUSE_BRIDGE_UNAVAILABLE"
    end

    local snapshot = bridge.Snapshot(safehouse)
    local removalOk, removalResult = runSafehouseMutation(function()
        local removed, why = bridge.RemoveAuthoritative(safehouse)
        if not removed then error(tostring(why)) end
        return true
    end)

    if not removalOk or removalResult ~= true then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
            code = "RELEASE_FAILED", message = "Vanilla safehouse could not be removed.",
        })
        return true
    end

    if snapshot and KIPN.Server.SafehouseService
        and type(KIPN.Server.SafehouseService.BroadcastProjectionRemoval) == "function"
    then
        pcall(KIPN.Server.SafehouseService.BroadcastProjectionRemoval, snapshot)
    end
    if KIPN.Server.SafehouseService
        and type(KIPN.Server.SafehouseService.BroadcastSafehouseSync) == "function"
    then
        pcall(KIPN.Server.SafehouseService.BroadcastSafehouseSync)
    end

    handleGetMyClaimsCommand(player, {})
    return true
end


------------------------------------------------------------
-- COMMAND: LEGACY CONFIRM SAFEHOUSE RELEASE
--
-- Compatibility-only handler retained for older KIPN clients. Current KIPN
-- release paths are server-authoritative and do not use sendSafehouseRelease()
-- or a client confirmation handshake.
------------------------------------------------------------

local function handleConfirmSafehouseReleaseCommand(
    player,
    args
)

    local startedAt =
        type(getTimestampMs) == "function"
        and getTimestampMs()
        or 0

    local claimId =
        args and args.claimId

    if not claimId then
        logError(
            "confirmSafehouseRelease FAILED: claimId missing."
        )
        return false,
            "CLAIM_ID_REQUIRED"
    end

    local claim =
        ClaimService.GetClaim(claimId)

    if not claim
        or claim.type ~= ClaimService.Types.PROPERTY
    then
        logError(
            "confirmSafehouseRelease FAILED: property claim not found | " ..
            "claim=" .. tostring(claimId)
        )
        return false,
            "CLAIM_NOT_FOUND"
    end

    local requestingSteamId =
        getPlayerSteamId(player)

    if not requestingSteamId
        or tostring(claim.ownerSteamId)
            ~= tostring(requestingSteamId)
    then
        logError(
            "confirmSafehouseRelease FAILED: owner mismatch | " ..
            "claim=" .. tostring(claimId)
        )
        return false,
            "NOT_CLAIM_OWNER"
    end

    ------------------------------------------------------------
    -- IDEMPOTENT CONFIRMATION
    --
    -- SafehouseService can observe OnSafehousesChanged on the server
    -- and reconcile the KIPN record before this client's confirmation
    -- packet arrives. That is a successful release, not an error. The
    -- owner check above still applies, so a stale/forged confirmation
    -- cannot retire somebody else's claim.
    ------------------------------------------------------------

    if claim.active == false then

        log(
            "Safehouse release confirmation arrived after server reconciliation | " ..
            "claim=" .. tostring(claimId)
        )

        handleGetMyClaimsCommand(player, {})

        return true,
            "SAFEHOUSE_RELEASE_ALREADY_RECONCILED"

    end

    local safehouse =
        findSafehouseForClaim(claim)

    if safehouse then
        logError(
            "confirmSafehouseRelease refused: vanilla SafeHouse still present | " ..
            "claim=" .. tostring(claimId)
        )
        return false,
            "SAFEHOUSE_STILL_PRESENT"
    end

    local released, reason =
        ClaimService.ReleaseClaim(
            claimId,
            "vanilla_safehouse_removed",
            player
        )

    if not released then
        logError(
            "confirmSafehouseRelease FAILED during KIPN commit | " ..
            "claim=" .. tostring(claimId) ..
            " | reason=" .. tostring(reason)
        )
        return false,
            reason
    end

    handleGetMyClaimsCommand(player, {})

    local finishedAt =
        type(getTimestampMs) == "function"
        and getTimestampMs()
        or startedAt

    log(
        "Safehouse release confirmed and KIPN claim retired | claim=" ..
        tostring(claimId)
    )
    log(
        "Meta Time Run Log | confirmSafehouseRelease ms=" ..
        tostring(finishedAt - startedAt) ..
        " | claim=" .. tostring(claimId)
    )

    return true,
        "SAFEHOUSE_RELEASE_CONFIRMED"
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
    -- Drop PO Box claims left orphaned by an interrupted
    -- purchase (no key was ever issued, nothing was charged).
    --------------------------------------------------------

    local orphanedPOBoxClaims =
        reconcileOrphanedPOBoxClaims()

    if orphanedPOBoxClaims > 0 then

        log(
            "Reconciled orphaned PO Box claims | dropped=" ..
            tostring(orphanedPOBoxClaims)
        )

        rebuildIndexes()

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

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.CLAIM_VEHICLE,
            handleClaimVehicleCommand
        )

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.CLAIM_PROPERTY,
            handleClaimPropertyCommand
        )

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.CLAIM_EXCAVATION,
            handleClaimExcavationCommand
        )

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.BUY_PO_BOX,
            handleBuyPOBoxCommand
        )

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.COPY_PO_BOX_KEY,
            handleCopyPOBoxKeyCommand
        )

        -- GET_PO_BOXES is intentionally PUBLIC -- any
        -- authenticated player may view the box listing/status.
        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.GET_PO_BOXES,
            handleGetPOBoxesCommand
        )

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.GET_MY_POBOX_KEYS,
            handleGetMyPOBoxKeysCommand
        )

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.GET_MY_CLAIMS,
            handleGetMyClaimsCommand
        )

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.RELEASE_CLAIM,
            handleReleaseClaimCommand
        )

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.RELEASE_SAFEHOUSE
                or "releaseSafehouse",
            handleReleaseSafehouseCommand
        )

        -- Legacy rolling-update compatibility. Current KIPN releases are
        -- server-authoritative and do not require client confirmation.
        KIPN.Server.RegisterCommandHandler(
            CONFIRM_SAFEHOUSE_RELEASE_COMMAND,
            handleConfirmSafehouseReleaseCommand
        )

        -- Legacy rolling-update compatibility for older clients. Current
        -- vanilla-panel release is routed directly through RELEASE_SAFEHOUSE.
        KIPN.Server.RegisterCommandHandler(
            RECONCILE_SAFEHOUSE_CLAIMS_COMMAND,
            handleReconcileSafehouseClaimsCommand
        )

    else

        logError(
            "KIPN.Server.RegisterCommandHandler() is " ..
            "unavailable; ClaimVehicle/ClaimProperty/" ..
            "ClaimExcavation/BuyPOBox/CopyPOBoxKey/GetPOBoxes/" ..
            "GetMyPOBoxKeys/GetMyClaims/ReleaseClaim/" ..
            "ConfirmSafehouseRelease/ReconcileSafehouseClaims commands will not be reachable."
        )

    end

    log(
        "Claim Service initialized."
    )

    return true

end
