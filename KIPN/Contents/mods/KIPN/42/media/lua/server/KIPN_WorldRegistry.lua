-- KIPN_WorldRegistry.lua
--
-- KIPN server-authoritative world registry.
--
-- Responsibilities:
--   * Define physical KIPN world zones.
--   * Persist zone definitions.
--   * Resolve world coordinates to zones.
--   * Resolve world locations to KIPN capabilities.
--   * Classify computers/objects by their CURRENT location.
--   * Provide safe zone data for administrative/client UI.
--   * Support future map-overlay administration tools.
--
-- IMPORTANT:
--
-- This service is SERVER AUTHORITATIVE.
--
-- The client may:
--   * request zone data
--   * display zones
--   * request map/editor state
--   * submit administrative requests
--
-- The client may NOT:
--   * define authoritative zones directly
--   * grant itself capabilities
--   * determine its own world classification
--   * bypass server-side zone validation
--
-- ARCHITECTURE:
--
--   COMPUTER
--       |
--       v
--   current physical location
--       |
--       v
--   WORLD REGISTRY
--       |
--       +--> zone classification
--       |
--       +--> world capabilities
--       |
--       v
--   APPLICATION AVAILABILITY
--
-- Account authorization remains the responsibility of:
--
--   KIPN_Permissions.lua
--
-- Therefore:
--
--   WORLD CAPABILITY
--          +
--   ACCOUNT PERMISSION
--          +
--   ACTIVE SESSION
--          +
--   TRANSACTION VALIDATION
--          =
--   AUTHORIZED OPERATION
--
-- ZONE ADMINISTRATION:
--
-- The intended future administrative interface is a
-- Starlit-backed map overlay.
--
-- The map editor will allow an authorized administrator to:
--
--   * inspect existing zones
--   * select a zone
--   * create a rectangle by selecting two map points
--   * edit zone geometry
--   * change zone type
--   * enable/disable zones
--   * configure zone capabilities
--   * eventually draw polygons
--
-- The map UI itself belongs on the CLIENT side.
--
-- This file provides the server API that the UI will consume.
--
-- CURRENT GEOMETRY:
--
--   RECTANGLE
--
-- FUTURE:
--
--   POLYGON
--   FREEHAND
--   BUILDING-DERIVED
--   IMPORTED MAP AREAS
--
-- CURRENT Z SUPPORT:
--
--   z1 / z2 are supported by the schema.
--   This allows a zone to cover one or more floors.
--
-- KIPN_Server owns:
--
--   * persistent data
--   * Save()
--   * GetData()
--
-- WorldRegistry owns:
--
--   * interpretation of world zone data
--   * zone creation/update/deactivation
--   * location classification
--   * capability resolution

if isClient() and not isServer() then
    return
end

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
require "KIPN_Shared"
require "KIPN_Server"

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local logger =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("WorldRegistry")
    or nil

local function log(message)
    if logger then
        logger:Info(message)
    else
        print("[KIPN WORLD REGISTRY] " .. tostring(message))
    end
end

local function logError(message)
    if logger then
        logger:Error(message)
    else
        print("[KIPN WORLD REGISTRY] ERROR: " .. tostring(message))
    end
end

------------------------------------------------------------
-- SERVICE
------------------------------------------------------------

KIPN.Server.WorldRegistry =
    KIPN.Server.WorldRegistry or {}

local WorldRegistry =
    KIPN.Server.WorldRegistry

------------------------------------------------------------
-- ZONE TYPES  (extensible registry)
------------------------------------------------------------
--
-- Zone types are no longer a fixed enum. Terminal ships only the
-- generic ones (custom, do_not_claim); a companion service mod
-- registers its own via WorldRegistry.RegisterZoneType() at module
-- load, before any zone is drawn.
--
-- Backwards compatibility: RegisterZoneType still populates
-- WorldRegistry.ZoneTypes.<UPPER> / ZoneTypeLabels[<id>] /
-- DefaultCapabilities[<id>] so existing `registry.ZoneTypes.GOVERNMENT`
-- style lookups keep working.
--
--   def = {
--       label               = "Government Building",
--       defaultCapabilities = { ["property.claim"] = true, ... },
--       classificationField = "government",   -- field set true on the
--                                             -- classification result
--                                             -- for a computer/location
--                                             -- inside a zone of this type
--   }
------------------------------------------------------------

WorldRegistry.ZoneTypes = {}
WorldRegistry.ZoneTypeLabels = {}
WorldRegistry.DefaultCapabilities = {}

-- typeId -> { label, defaultCapabilities, classificationField, key }
WorldRegistry.RegisteredZoneTypes = {}

-- UPPERCASE type-name -> classification result field name.
-- Consumed by KIPN_ApplicationRegistry.hasRequiredClassification.
WorldRegistry.ClassificationFieldByTypeName = {}

local validZoneTypes = {}

function WorldRegistry.RegisterZoneType(typeId, def)

    if type(typeId) ~= "string"
        or typeId == ""
    then

        logError(
            "RegisterZoneType rejected: invalid type id."
        )

        return false
    end

    def = def or {}

    local key = string.upper(typeId)

    if WorldRegistry.RegisteredZoneTypes[typeId] then

        -- Already registered (built-in, or a duplicate mod call).
        return true
    end

    local classificationField =
        (type(def.classificationField) == "string"
            and def.classificationField ~= "")
        and def.classificationField
        or nil

    local record = {
        id = typeId,
        key = key,
        label = def.label or typeId,
        defaultCapabilities =
            (type(def.defaultCapabilities) == "table")
            and def.defaultCapabilities
            or {},
        classificationField = classificationField,
    }

    WorldRegistry.RegisteredZoneTypes[typeId] = record
    WorldRegistry.ZoneTypes[key] = typeId
    WorldRegistry.ZoneTypeLabels[typeId] = record.label
    WorldRegistry.DefaultCapabilities[typeId] = record.defaultCapabilities
    validZoneTypes[typeId] = true

    if classificationField then
        WorldRegistry.ClassificationFieldByTypeName[key] =
            classificationField
    end

    log(
        "Registered zone type: " .. typeId ..
        (classificationField
            and (" (classification=" .. classificationField .. ")")
            or "")
    )

    return true
end

function WorldRegistry.GetRegisteredZoneTypes()

    local result = {}

    for typeId, record in pairs(WorldRegistry.RegisteredZoneTypes) do

        result[#result + 1] = {
            id = typeId,
            label = record.label,
            classificationField = record.classificationField,
        }
    end

    table.sort(
        result,
        function(a, b)
            return tostring(a.label) < tostring(b.label)
        end
    )

    return result
end

------------------------------------------------------------
-- SHAPE TYPES
------------------------------------------------------------

WorldRegistry.ShapeTypes = {

    RECTANGLE =
        "rectangle",

    POLYGON =
        "polygon",
}

------------------------------------------------------------
-- BUILT-IN ZONE TYPES
------------------------------------------------------------
--
-- Terminal owns only the two generic zone types. A service module
-- registers its own (KIPN: Government Services -> `government`,
-- KIPN: Vehicle Services -> `dealership`) at init.
------------------------------------------------------------

WorldRegistry.RegisterZoneType("custom", {
    label = "Custom",
    defaultCapabilities = {},
    classificationField = "custom",
})

-- Unconditionally blocks area claims from overlapping it. Unlike
-- every other zone type, this block is NOT subject to a service's
-- AllowClaimsInKIPNZones override.
WorldRegistry.RegisterZoneType("do_not_claim", {
    label = "Do Not Claim Zone",
    defaultCapabilities = {},
})

------------------------------------------------------------
-- COMBAT POLICIES
------------------------------------------------------------
--
-- A zone's combatPolicy is ORTHOGONAL to its zoneType.
--
-- zoneType   -> what a location IS (government/dealership/...)
-- combatPolicy -> what damage rules apply there
--
-- The ambient default -- no zone, or a zone with no combatPolicy
-- set (nil) -- is always FULL PvP damage; combatPolicy exists
-- purely to carve out an exception to that default, and there are
-- only two:
--
--   PVE       -> no PvP damage (zombies/animals still dangerous)
--   MELEE_PVP -> PvP damage allowed, but ranged weapons are
--                blocked (melee only)
--
-- Enforcement (Hit()-level, via Events.OnWeaponHitCharacter +
-- IsoGameCharacter:setAvoidDamage()) lives in
-- KIPN_CombatZoneService.lua. This registry only stores and
-- validates the policy value -- it has no combat logic of its
-- own.
------------------------------------------------------------

WorldRegistry.CombatPolicies = {

    MELEE_PVP =
        "MELEE_PVP",

    PVE =
        "PVE",
}

WorldRegistry.CombatPolicyLabels = {

    [WorldRegistry.CombatPolicies.MELEE_PVP] =
        "Melee Zone (melee only, no ranged)",

    [WorldRegistry.CombatPolicies.PVE] =
        "PvE Zone (no PvP damage)",
}

local validCombatPolicies = {

    [WorldRegistry.CombatPolicies.MELEE_PVP] = true,
    [WorldRegistry.CombatPolicies.PVE] = true,
}

------------------------------------------------------------
-- COMBAT POLICY VALIDATION
------------------------------------------------------------

local function isValidCombatPolicy(policy)
    local result =
        validCombatPolicies[policy] == true

    return result
end

------------------------------------------------------------
-- VALID SHAPES
------------------------------------------------------------

local validShapeTypes = {

    [WorldRegistry.ShapeTypes.RECTANGLE] = true,
}

------------------------------------------------------------
-- WORLD TIME
------------------------------------------------------------

local function getWorldDays()
    local result = nil

    pcall(function()

        local gameTime =
            getGameTime()

        if gameTime and
           gameTime.getWorldAgeHours then

            result =
                gameTime:getWorldAgeHours() / 24
        end

    end)

    return result
end

------------------------------------------------------------
-- ZONE COLLECTION
------------------------------------------------------------

local function getZoneCollection()
    if not KIPN.Server.GetData then

        logError(
            "KIPN.Server.GetData() is unavailable."
        )

        return nil
    end

    local data =
        KIPN.Server.GetData()

    if not data then

        logError(
            "KIPN data unavailable."
        )

        return nil
    end

    if type(data.configuration) ~= "table" then

        data.configuration = {}

    end

    if type(data.configuration.worldZones) ~= "table" then

        data.configuration.worldZones = {}

    end

    return data.configuration.worldZones
end

------------------------------------------------------------
-- ZONE TYPE VALIDATION
------------------------------------------------------------

local function isValidZoneType(zoneType)
    local result =
        validZoneTypes[zoneType] == true

    return result
end

------------------------------------------------------------
-- SHAPE VALIDATION
------------------------------------------------------------

local function isValidShapeType(shape)
    local result =
        validShapeTypes[shape] == true

    return result
end

------------------------------------------------------------
-- RECTANGLE VALIDATION
------------------------------------------------------------

local function validateRectangle(geometry)
    if type(geometry) ~= "table" then

        return false,
            "GEOMETRY_REQUIRED"
    end

    local x1 =
        tonumber(geometry.x1)

    local y1 =
        tonumber(geometry.y1)

    local x2 =
        tonumber(geometry.x2)

    local y2 =
        tonumber(geometry.y2)

    if not x1 or
       not y1 or
       not x2 or
       not y2 then

        return false,
            "RECTANGLE_COORDINATES_INVALID"
    end

    if x1 == x2 or
       y1 == y2 then

        return false,
            "RECTANGLE_HAS_NO_AREA"
    end

    return true, "VALID"
end

------------------------------------------------------------
-- NORMALIZE RECTANGLE
------------------------------------------------------------

local function normalizeRectangle(geometry)
    local x1 =
        tonumber(geometry.x1)

    local y1 =
        tonumber(geometry.y1)

    local x2 =
        tonumber(geometry.x2)

    local y2 =
        tonumber(geometry.y2)

    local z1 =
        tonumber(geometry.z1)

    local z2 =
        tonumber(geometry.z2)

    --------------------------------------------------------
    -- Current default:
    --
    -- If no floor is specified, use floor 0.
    --------------------------------------------------------

    if z1 == nil then
        z1 = 0
    end

    if z2 == nil then
        z2 = z1
    end

    local result = {

        x1 = math.min(x1, x2),
        y1 = math.min(y1, y2),

        x2 = math.max(x1, x2),
        y2 = math.max(y1, y2),

        z1 = math.min(z1, z2),
        z2 = math.max(z1, z2),
    }

    return result
end

------------------------------------------------------------
-- GEOMETRY VALIDATION
------------------------------------------------------------

local function validateGeometry(shape, geometry)
    if shape ==
       WorldRegistry.ShapeTypes.RECTANGLE then

        local valid, reason =
            validateRectangle(geometry)

        return valid, reason
    end

    return false,
        "UNSUPPORTED_SHAPE"
end

------------------------------------------------------------
-- ZONE ID GENERATION
------------------------------------------------------------

local function generateZoneId(zoneType)
    local zones =
        getZoneCollection()

    if not zones then

        return nil
    end

    local timestamp =
        tostring(
            getTimestampMs and
            getTimestampMs() or
            0
        )

    local function randomNumber()

        if ZombRand then

            return ZombRand(
                100000,
                999999
            )

        end

        return math.random(
            100000,
            999999
        )
    end

    local zoneId

    repeat

        zoneId =
            "ZONE-" ..
            tostring(
                zoneType or "custom"
            ) ..
            "-" ..
            timestamp ..
            "-" ..
            tostring(randomNumber()) ..
            "-" ..
            tostring(randomNumber())

    until not zones[zoneId]

    return zoneId
end

------------------------------------------------------------
-- CAPABILITY COPY
------------------------------------------------------------
--
-- Never expose the DefaultCapabilities table itself as a
-- mutable zone capability table.
------------------------------------------------------------

local function copyCapabilities(source)
    local result = {}

    if type(source) == "table" then

        for capability, enabled in pairs(source) do

            if enabled == true then

                result[capability] = true

            end
        end
    end

    return result
end

------------------------------------------------------------
-- RESOLVE ZONE CAPABILITIES
------------------------------------------------------------

function WorldRegistry.GetZoneCapabilities(zone)
    if type(zone) ~= "table" then

        return {}
    end

    --------------------------------------------------------
    -- Start with the zone type defaults.
    --------------------------------------------------------

    local capabilities =
        copyCapabilities(
            WorldRegistry.DefaultCapabilities[
                zone.type
            ]
        )

    --------------------------------------------------------
    -- Explicit zone capabilities override defaults.
    --
    -- true  = enabled
    -- false = disabled
    --------------------------------------------------------

    if type(zone.capabilities) == "table" then

        for capability, enabled in pairs(
            zone.capabilities
        ) do

            capabilities[capability] =
                enabled == true

        end
    end

    return capabilities
end

------------------------------------------------------------
-- GET ZONE
------------------------------------------------------------

function WorldRegistry.GetZone(zoneId)
    if not zoneId then

        return nil
    end

    local zones =
        getZoneCollection()

    if not zones then

        return nil
    end

    local zone =
        zones[tostring(zoneId)]

    return zone
end

------------------------------------------------------------
-- GET ALL ZONES
------------------------------------------------------------

function WorldRegistry.GetZones(zoneType, includeInactive)
    local zones =
        getZoneCollection()

    if not zones then

        return {}
    end

    local results = {}

    for zoneId, zone in pairs(zones) do

        if type(zone) == "table" then

            local active =
                zone.active ~= false

            local typeMatches =
                not zoneType or
                zone.type == zoneType

            if typeMatches and
               (active or includeInactive) then

                results[zoneId] = zone

            end
        end
    end

    return results
end

------------------------------------------------------------
-- SAFEHOUSE OVERLAP POLICY
------------------------------------------------------------
--
-- Non-custom KIPN zones (Government/Dealership/any future type)
-- may not overlap an existing active Safehouse
-- claim. Custom zones are exempt. Excavation claims are NOT part
-- of this policy -- only Safehouses (Property claims) block a
-- zone.
------------------------------------------------------------

local function zoneTypeExemptFromSafehouseOverlap(zoneType)
    return zoneType == WorldRegistry.ZoneTypes.CUSTOM
end

------------------------------------------------------------
-- TABLE HAS ANY ENTRIES
------------------------------------------------------------
--
-- Equivalent to `next(t) ~= nil`, but avoids calling the raw
-- `next` builtin directly -- on this Kahlua build, calling
-- `next()` on a table built here reliably throws "Object tried
-- to call nil" (observed crashing CreateZone/UpdateZone/
-- ActivateZone every time, blocking all KIPN zone drawing).
-- `pairs()` iteration is unaffected, so use that instead.
------------------------------------------------------------

local function tableHasEntries(t)
    for _ in pairs(t) do
        return true
    end

    return false
end

------------------------------------------------------------
-- GET SAFEHOUSES OVERLAPPING RECTANGLE
------------------------------------------------------------
--
-- KIPN's canonical Safehouse source of truth is the Property claim
-- table owned by KIPN.Server.ClaimService (KIPN.Server.ClaimService
-- is referenced lazily, at call time, to avoid a load-order/circular
-- require dependency between WorldRegistry and ClaimService -- the
-- same lazy cross-reference pattern ClaimService already uses in
-- the opposite direction for WorldRegistry).
--
-- Property claim rectangles (rectX1/rectY1/rectX2/rectY2) are
-- already inclusive x1/y1/x2/y2 tile bounds spanning all floors, so
-- no shape conversion or Z handling is required.
------------------------------------------------------------

function WorldRegistry.GetSafehousesOverlappingRectangle(rect)
    local results = {}

    if type(rect) ~= "table" then

        logError(
            "GetSafehousesOverlappingRectangle() rejected invalid rectangle."
        )

        return results
    end

    local qx1 = tonumber(rect.x1)
    local qy1 = tonumber(rect.y1)
    local qx2 = tonumber(rect.x2)
    local qy2 = tonumber(rect.y2)

    if not qx1 or
       not qy1 or
       not qx2 or
       not qy2 then

        logError(
            "GetSafehousesOverlappingRectangle() rectangle coordinates are invalid."
        )

        return results
    end

    qx1, qx2 = math.min(qx1, qx2), math.max(qx1, qx2)
    qy1, qy2 = math.min(qy1, qy2), math.max(qy1, qy2)

    local claimService =
        KIPN.Server.ClaimService

    if not claimService or
       type(claimService.GetClaims) ~= "function" or
       not claimService.Types then

        logError(
            "GetSafehousesOverlappingRectangle() FAILED: ClaimService unavailable."
        )

        return results
    end

    local safehouseClaims =
        claimService.GetClaims(
            claimService.Types.PROPERTY
        )

    for claimId, claim in pairs(safehouseClaims) do

        if type(claim) == "table" then

            local sx1 = tonumber(claim.rectX1)
            local sy1 = tonumber(claim.rectY1)
            local sx2 = tonumber(claim.rectX2)
            local sy2 = tonumber(claim.rectY2)

            if sx1 and sy1 and sx2 and sy2 then

                sx1, sx2 =
                    math.min(sx1, sx2),
                    math.max(sx1, sx2)

                sy1, sy2 =
                    math.min(sy1, sy2),
                    math.max(sy1, sy2)

                local overlaps =
                    qx1 <= sx2 and
                    qx2 >= sx1 and
                    qy1 <= sy2 and
                    qy2 >= sy1

                if overlaps then

                    results[claimId] =
                        claim
                end
            end
        end
    end

    local count = 0

    for _ in pairs(results) do
        count = count + 1
    end

    log(
        "GetSafehousesOverlappingRectangle() | matches=" ..
        tostring(count)
    )

    return results
end

------------------------------------------------------------
-- LEGACY SAFEHOUSE/ZONE CONFLICT SCAN (LOG-ONLY, NON-MUTATING)
------------------------------------------------------------
--
-- Runs once at server startup (see initWorldRegistry() below).
-- Reports any active non-custom zone that already overlaps an
-- active Safehouse claim from BEFORE this policy existed. Does
-- NOT alter, deactivate, resize, or otherwise mutate either the
-- zone or the claim -- purely diagnostic logging so an admin can
-- decide how to resolve the conflict manually.
------------------------------------------------------------

function WorldRegistry.ScanLegacySafehouseConflicts()

    if not KIPN.Server.ClaimService then

        logError(
            "ScanLegacySafehouseConflicts() deferred: " ..
            "ClaimService is not ready."
        )

        return
    end

    local zones =
        WorldRegistry.GetZones(
            nil,
            false
        )

    local conflictCount = 0

    for zoneId, zone in pairs(zones) do

        if type(zone) == "table" and
           type(zone.geometry) == "table" and
           not zoneTypeExemptFromSafehouseOverlap(zone.type) then

            local overlappingSafehouses =
                WorldRegistry.GetSafehousesOverlappingRectangle(
                    zone.geometry
                )

            for claimId, claim in pairs(overlappingSafehouses) do

                conflictCount =
                    conflictCount + 1

                log(
                    "LEGACY CONFLICT | zoneId=" ..
                    tostring(zoneId) ..
                    " | zoneType=" ..
                    tostring(zone.type) ..
                    " | safehouseClaimId=" ..
                    tostring(claimId) ..
                    " | owner=" ..
                    tostring(claim.ownerUsername or claim.ownerSteamId)
                )
            end
        end
    end

    log(
        "ScanLegacySafehouseConflicts() complete | conflicts=" ..
        tostring(conflictCount)
    )
end

------------------------------------------------------------
-- CREATE ZONE
------------------------------------------------------------

function WorldRegistry.CreateZone(
    zoneType,
    definition,
    metadata
)
    if not isValidZoneType(zoneType) then

        logError(
            "Unknown zone type: " ..
            tostring(zoneType)
        )

        return nil,
            "UNKNOWN_ZONE_TYPE"
    end

    if type(definition) ~= "table" then

        return nil,
            "DEFINITION_REQUIRED"
    end

    local shape =
        definition.shape or
        WorldRegistry.ShapeTypes.RECTANGLE

    if not isValidShapeType(shape) then

        return nil,
            "UNSUPPORTED_SHAPE"
    end

    local geometry =
        definition.geometry or
        definition

    local valid, reason =
        validateGeometry(
            shape,
            geometry
        )

    if not valid then

        return nil, reason
    end

    if definition.combatPolicy ~= nil and
       not isValidCombatPolicy(
           definition.combatPolicy
       ) then

        return nil,
            "UNKNOWN_COMBAT_POLICY"
    end

    local zones =
        getZoneCollection()

    if not zones then

        return nil,
            "ZONE_COLLECTION_UNAVAILABLE"
    end

    local zoneId =
        generateZoneId(zoneType)

    if not zoneId then

        return nil,
            "ZONE_ID_GENERATION_FAILED"
    end

    local normalizedGeometry

    if shape ==
       WorldRegistry.ShapeTypes.RECTANGLE then

        normalizedGeometry =
            normalizeRectangle(
                geometry
            )

    else

        return nil,
            "UNSUPPORTED_SHAPE"
    end

    if not zoneTypeExemptFromSafehouseOverlap(zoneType) then

        local overlappingSafehouses =
            WorldRegistry.GetSafehousesOverlappingRectangle(
                normalizedGeometry
            )

        if tableHasEntries(overlappingSafehouses) then

            logError(
                "CreateZone REJECTED | zoneType=" ..
                tostring(zoneType) ..
                " | overlaps an active Safehouse claim."
            )

            return nil,
                "Non-custom KIPN zones cannot overlap an existing Safehouse."
        end
    end

    local nowDays =
        getWorldDays()

    local zone = {

        id =
            zoneId,

        type =
            zoneType,

        shape =
            shape,

        active =
            true,

        createdAtWorldDays =
            nowDays,

        updatedAtWorldDays =
            nowDays,

        geometry =
            normalizedGeometry,

        capabilities =
            definition.capabilities or {},

        combatPolicy =
            definition.combatPolicy,

        metadata =
            type(metadata) == "table"
            and metadata
            or {},

    }

    zones[zoneId] =
        zone

    --------------------------------------------------------
    -- Persist.
    --------------------------------------------------------

    -- Zones persist under data.configuration.worldZones; scope the
    -- save so a zone edit doesn't re-transmit every KIPN subsystem
    -- tag to every connected client.
    local saved =
        KIPN.Server.Save("configuration")

    if not saved then

        zones[zoneId] =
            nil

        logError(
            "Failed to persist zone: " ..
            tostring(zoneId)
        )

        return nil,
            "PERSISTENCE_FAILED"
    end

    log(
        "Created zone " ..
        tostring(zoneId) ..
        " type=" ..
        tostring(zoneType)
    )

    return zone,
        "ZONE_CREATED"
end

------------------------------------------------------------
-- CREATE ZONE FROM CORNERS
------------------------------------------------------------
--
-- Designed specifically for the future map overlay.
--
-- The client can provide two selected world points and the
-- server converts them into a rectangle.
------------------------------------------------------------

function WorldRegistry.CreateZoneFromCorners(
    zoneType,
    cornerA,
    cornerB,
    metadata,
    capabilities,
    combatPolicy
)
    if type(cornerA) ~= "table" or
       type(cornerB) ~= "table" then

        return nil,
            "CORNERS_REQUIRED"
    end

    local definition = {

        shape =
            WorldRegistry.ShapeTypes.RECTANGLE,

        x1 =
            cornerA.x,

        y1 =
            cornerA.y,

        x2 =
            cornerB.x,

        y2 =
            cornerB.y,

        z1 =
            cornerA.z,

        z2 =
            cornerB.z,

        capabilities =
            capabilities,

        combatPolicy =
            combatPolicy,

    }

    local zone, reason =
        WorldRegistry.CreateZone(
            zoneType,
            definition,
            metadata
        )

    return zone, reason
end

------------------------------------------------------------
-- POSITION INSIDE RECTANGLE
------------------------------------------------------------

local function isPositionInsideRectangle(
    x,
    y,
    z,
    geometry
)
    if type(geometry) ~= "table" then

        return false
    end

    local px =
        tonumber(x)

    local py =
        tonumber(y)

    local pz =
        tonumber(z)

    if not px or
       not py then

        return false
    end

    if pz == nil then
        pz = 0
    end

    local x1 =
        tonumber(geometry.x1)

    local y1 =
        tonumber(geometry.y1)

    local x2 =
        tonumber(geometry.x2)

    local y2 =
        tonumber(geometry.y2)

    local z1 =
        tonumber(geometry.z1)

    local z2 =
        tonumber(geometry.z2)

    if not x1 or
       not y1 or
       not x2 or
       not y2 then

        return false
    end

    if z1 == nil then
        z1 = 0
    end

    if z2 == nil then
        z2 = z1
    end

    local inside =
        px >= math.min(x1, x2) and
        px <= math.max(x1, x2) and
        py >= math.min(y1, y2) and
        py <= math.max(y1, y2) and
        pz >= math.min(z1, z2) and
        pz <= math.max(z1, z2)

    return inside
end

------------------------------------------------------------
-- POSITION INSIDE ZONE
------------------------------------------------------------

function WorldRegistry.IsPositionInZone(
    x,
    y,
    z,
    zone
)
    if type(zone) ~= "table" then

        return false
    end

    if zone.active == false then

        return false
    end

    local shape =
        zone.shape or
        WorldRegistry.ShapeTypes.RECTANGLE

    if shape ==
       WorldRegistry.ShapeTypes.RECTANGLE then

        local result =
            isPositionInsideRectangle(
                x,
                y,
                z,
                zone.geometry
            )

        return result
    end

    logError(
        "Unsupported zone shape: " ..
        tostring(shape)
    )

    return false
end

------------------------------------------------------------
-- GET ZONES OVERLAPPING RECTANGLE
------------------------------------------------------------
--
-- Server-authoritative geometry query used by policy systems that
-- need to validate an AREA rather than a single tile.
--
-- `rect` accepts x1/y1/x2/y2 and optionally z1/z2 or z.
--
-- options.ignoreZ = true
--     Treats the query as a 2D X/Y parcel overlap. Property /
--     safehouse policy uses this because vanilla SafeHouse bounds
--     protect the complete building across floors.
--
-- Only ACTIVE KIPN zones are returned. The optional zoneType filter
-- mirrors GetZonesAtPosition().
------------------------------------------------------------

function WorldRegistry.GetZonesOverlappingRectangle(
    rect,
    options,
    zoneType
)
    local results = {}

    if type(rect) ~= "table" then

        logError(
            "GetZonesOverlappingRectangle() rejected invalid rectangle."
        )

        return results
    end

    local qx1 = tonumber(rect.x1)
    local qy1 = tonumber(rect.y1)
    local qx2 = tonumber(rect.x2)
    local qy2 = tonumber(rect.y2)

    if not qx1 or
       not qy1 or
       not qx2 or
       not qy2 then

        logError(
            "GetZonesOverlappingRectangle() rectangle coordinates are invalid."
        )

        return results
    end

    qx1, qx2 = math.min(qx1, qx2), math.max(qx1, qx2)
    qy1, qy2 = math.min(qy1, qy2), math.max(qy1, qy2)

    options =
        type(options) == "table"
        and options
        or {}

    local ignoreZ =
        options.ignoreZ == true

    local qz1 =
        tonumber(rect.z1)
        or tonumber(rect.z)

    local qz2 =
        tonumber(rect.z2)
        or qz1

    if qz1 ~= nil and qz2 ~= nil then

        qz1, qz2 =
            math.min(qz1, qz2),
            math.max(qz1, qz2)
    end

    local zones =
        WorldRegistry.GetZones(
            zoneType,
            false
        )

    for zoneId, zone in pairs(zones) do

        if type(zone) == "table" and
           zone.active ~= false and
           (zone.shape or WorldRegistry.ShapeTypes.RECTANGLE) ==
               WorldRegistry.ShapeTypes.RECTANGLE and
           type(zone.geometry) == "table" then

            local geometry =
                zone.geometry

            local zx1 =
                tonumber(geometry.x1)

            local zy1 =
                tonumber(geometry.y1)

            local zx2 =
                tonumber(geometry.x2)

            local zy2 =
                tonumber(geometry.y2)

            if zx1 and zy1 and zx2 and zy2 then

                zx1, zx2 =
                    math.min(zx1, zx2),
                    math.max(zx1, zx2)

                zy1, zy2 =
                    math.min(zy1, zy2),
                    math.max(zy1, zy2)

                local overlapsXY =
                    qx1 <= zx2 and
                    qx2 >= zx1 and
                    qy1 <= zy2 and
                    qy2 >= zy1

                local overlapsZ =
                    true

                if not ignoreZ and
                   qz1 ~= nil and
                   qz2 ~= nil then

                    local zz1 =
                        tonumber(geometry.z1)

                    local zz2 =
                        tonumber(geometry.z2)

                    if zz1 == nil then
                        zz1 = 0
                    end

                    if zz2 == nil then
                        zz2 = zz1
                    end

                    zz1, zz2 =
                        math.min(zz1, zz2),
                        math.max(zz1, zz2)

                    overlapsZ =
                        qz1 <= zz2 and
                        qz2 >= zz1
                end

                if overlapsXY and overlapsZ then

                    results[zoneId] =
                        zone
                end
            end
        end
    end

    local count = 0

    for _ in pairs(results) do
        count = count + 1
    end

    log(
        "GetZonesOverlappingRectangle() | matches=" ..
        tostring(count) ..
        " | ignoreZ=" ..
        tostring(ignoreZ) ..
        " | zoneType=" ..
        tostring(zoneType or "ANY")
    )

    return results
end


------------------------------------------------------------
-- ZONE SPATIAL INDEX
------------------------------------------------------------
--
-- WorldRegistry.GetZonesAtPosition() is called from combat-hit
-- policy checks (KIPN_CombatZoneService.lua onWeaponHitCharacter,
-- hooked to Events.OnWeaponHitCharacter) which can fire many times
-- per second during a large fight. A linear pairs() scan of every
-- registered zone on every hit does not hold up on a full server,
-- so RECTANGLE zones (the only shape IsPositionInZone() currently
-- supports -- see isPositionInsideRectangle() above) are bucketed
-- into a grid, same approach as ClaimService.GetClaimAt(). Any
-- non-rectangle zone falls back to a small linear list so nothing
-- is silently dropped if another shape becomes supported later.
--
-- Rebuilt at most once per SPATIAL_INDEX_TTL_MS rather than
-- incrementally maintained, since zones can be created/edited from
-- more than one admin/editor path -- a bounded ~1s staleness on a
-- policy check (not itself a security perimeter) is a safe trade
-- for not having to hook every current and future zone-write site.
------------------------------------------------------------

local ZONE_SPATIAL_CELL_SIZE =
    20

local ZONE_SPATIAL_INDEX_TTL_MS =
    1000

local zoneSpatialIndexCache =
    nil

local zoneSpatialNonRectCache =
    nil

local zoneSpatialIndexBuiltAtMs =
    nil

local function zoneSpatialCellKey(cellX, cellY)

    return cellX ..
        ":" ..
        cellY
end

local function buildZoneSpatialIndex(zones)

    local index =
        {}

    local nonRect =
        {}

    for zoneId, zone in pairs(zones) do

        if type(zone) == "table" and
           zone.active ~= false then

            local shape =
                zone.shape or
                WorldRegistry.ShapeTypes.RECTANGLE

            local geometry =
                type(zone.geometry) == "table" and
                zone.geometry or
                nil

            local nx1 =
                geometry and tonumber(geometry.x1)

            local ny1 =
                geometry and tonumber(geometry.y1)

            local nx2 =
                geometry and tonumber(geometry.x2)

            local ny2 =
                geometry and tonumber(geometry.y2)

            if shape == WorldRegistry.ShapeTypes.RECTANGLE and
               nx1 and ny1 and nx2 and ny2 then

                local gx1, gx2 =
                    math.min(nx1, nx2),
                    math.max(nx1, nx2)

                local gy1, gy2 =
                    math.min(ny1, ny2),
                    math.max(ny1, ny2)

                local cellX1 =
                    math.floor(gx1 / ZONE_SPATIAL_CELL_SIZE)

                local cellX2 =
                    math.floor(gx2 / ZONE_SPATIAL_CELL_SIZE)

                local cellY1 =
                    math.floor(gy1 / ZONE_SPATIAL_CELL_SIZE)

                local cellY2 =
                    math.floor(gy2 / ZONE_SPATIAL_CELL_SIZE)

                for cellX = cellX1, cellX2 do

                    for cellY = cellY1, cellY2 do

                        local key =
                            zoneSpatialCellKey(cellX, cellY)

                        if not index[key] then
                            index[key] = {}
                        end

                        index[key][#index[key] + 1] =
                            zoneId

                    end
                end

            else

                nonRect[#nonRect + 1] =
                    zoneId

            end
        end
    end

    return index,
        nonRect
end

local function getZoneSpatialIndex(zones)

    local now =
        type(getTimestampMs) == "function" and
        getTimestampMs() or
        0

    if not zoneSpatialIndexCache or
       not zoneSpatialIndexBuiltAtMs or
       (now - zoneSpatialIndexBuiltAtMs) >= ZONE_SPATIAL_INDEX_TTL_MS then

        zoneSpatialIndexCache,
            zoneSpatialNonRectCache =
            buildZoneSpatialIndex(zones)

        zoneSpatialIndexBuiltAtMs =
            now
    end

    return zoneSpatialIndexCache,
        zoneSpatialNonRectCache
end

------------------------------------------------------------
-- GET ZONES AT POSITION
------------------------------------------------------------

function WorldRegistry.GetZonesAtPosition(
    x,
    y,
    z,
    zoneType
)
    local zones =
        getZoneCollection()

    if not zones then

        return {}
    end

    local index,
        nonRect =
        getZoneSpatialIndex(zones)

    local results = {}

    local candidates =
        index[
            zoneSpatialCellKey(
                math.floor(tonumber(x) / ZONE_SPATIAL_CELL_SIZE),
                math.floor(tonumber(y) / ZONE_SPATIAL_CELL_SIZE)
            )
        ]

    local function evaluate(zoneId)

        local zone =
            zones[zoneId]

        if type(zone) == "table" and
           zone.active ~= false then

            if not zoneType or
               zone.type == zoneType then

                if WorldRegistry.IsPositionInZone(
                    x,
                    y,
                    z,
                    zone
                ) then

                    results[zoneId] =
                        zone

                end
            end
        end
    end

    if candidates then

        for _, zoneId in ipairs(candidates) do
            evaluate(zoneId)
        end
    end

    for _, zoneId in ipairs(nonRect) do
        evaluate(zoneId)
    end

    return results
end

------------------------------------------------------------
-- GET FIRST ZONE AT POSITION
------------------------------------------------------------

function WorldRegistry.GetZoneAtPosition(
    x,
    y,
    z,
    zoneType
)
    local zones =
        WorldRegistry.GetZonesAtPosition(
            x,
            y,
            z,
            zoneType
        )

    for zoneId, zone in pairs(zones) do

        return zone,
            zoneId
    end

    return nil,
        nil
end

------------------------------------------------------------
-- LOCATION CLASSIFICATION
------------------------------------------------------------

function WorldRegistry.GetLocationClassification(
    x,
    y,
    z
)
    local result = {
        zones = {},
    }

    -- Seed every registered classification field to false so callers
    -- can safely do `classification.<field> == true`.
    for _, record in pairs(WorldRegistry.RegisteredZoneTypes) do
        if record.classificationField then
            result[record.classificationField] = false
        end
    end

    local zones =
        WorldRegistry.GetZonesAtPosition(
            x,
            y,
            z
        )

    for zoneId, zone in pairs(zones) do

        result.zones[zoneId] =
            zone

        local record =
            zone.type
            and WorldRegistry.RegisteredZoneTypes[zone.type]

        if record and record.classificationField then
            result[record.classificationField] = true
        end
    end

    return result
end

------------------------------------------------------------
-- LOCATION CAPABILITIES
------------------------------------------------------------
--
-- Multiple overlapping zones may contribute capabilities.
--
-- Example:
--
--   Government zone
--       +
--   Custom zone
--
-- Capabilities are merged.
------------------------------------------------------------

function WorldRegistry.GetLocationCapabilities(
    x,
    y,
    z
)
    local capabilities = {}

    local zones =
        WorldRegistry.GetZonesAtPosition(
            x,
            y,
            z
        )

    for _, zone in pairs(zones) do

        local zoneCapabilities =
            WorldRegistry.GetZoneCapabilities(
                zone
            )

        for capability, enabled in pairs(
            zoneCapabilities
        ) do

            if enabled == true then

                capabilities[capability] =
                    true

            elseif enabled == false then

                capabilities[capability] =
                    nil

            end
        end
    end

    return capabilities
end

------------------------------------------------------------
-- OBJECT LOCATION
------------------------------------------------------------

local function getObjectSquare(obj)
    if not obj then

        return nil
    end

    local square = nil

    local ok =
        pcall(function()

            if obj.getSquare then

                square =
                    obj:getSquare()

            end
        end)

    if not ok or not square then

        return nil
    end

    return square
end

------------------------------------------------------------
-- OBJECT CLASSIFICATION
------------------------------------------------------------

function WorldRegistry.GetObjectClassification(obj)
    local square =
        getObjectSquare(obj)

    if not square then

        return nil
    end

    local x =
        square:getX()

    local y =
        square:getY()

    local z =
        square:getZ()

    local classification =
        WorldRegistry.GetLocationClassification(
            x,
            y,
            z
        )

    return classification
end

------------------------------------------------------------
-- OBJECT CAPABILITIES
------------------------------------------------------------

function WorldRegistry.GetObjectCapabilities(obj)
    local square =
        getObjectSquare(obj)

    if not square then

        return {}
    end

    local capabilities =
        WorldRegistry.GetLocationCapabilities(
            square:getX(),
            square:getY(),
            square:getZ()
        )

    return capabilities
end

------------------------------------------------------------
-- COMPUTER CLASSIFICATION
------------------------------------------------------------
--
-- The computer is resolved by CURRENT physical position.
--
-- Nothing is permanently written to the computer saying:
--
--     dealership = true
--
-- Therefore moving the computer automatically changes its
-- classification.
------------------------------------------------------------

function WorldRegistry.GetComputerClassification(
    computerId
)
    if not KIPN.Server.GetComputer then

        logError(
            "KIPN.Server.GetComputer() unavailable."
        )

        return nil
    end

    local computer =
        KIPN.Server.GetComputer(
            computerId
        )

    if not computer then

        return nil
    end

    --------------------------------------------------------
    -- Computer position must be available from its registry
    -- record.
    --
    -- Supported forms:
    --
    -- computer.x / y / z
    --
    -- computer.location.x / y / z
    --
    -- comp_X_Y_Z encoded in computer.locationKey (falling back
    -- to computerId itself) -- the actual convention used by
    -- KIPN.Server.GetOrCreateComputer(). See
    -- KIPN.Server.CheckBuildingPower() for the same fallback.
    --------------------------------------------------------

    local x
    local y
    local z

    if computer.x ~= nil then

        x = computer.x
        y = computer.y
        z = computer.z

    elseif type(computer.location) == "table" then

        x = computer.location.x
        y = computer.location.y
        z = computer.location.z

    elseif KIPN.Shared.ParseComputerIdCoords then

        x, y, z =
            KIPN.Shared.ParseComputerIdCoords(
                computer.locationKey or computerId
            )

    end

    if x == nil or
       y == nil then

        logError(
            "Computer has no usable world position: " ..
            tostring(computerId)
        )

        return nil
    end

    local result =
        WorldRegistry.GetLocationClassification(
            x,
            y,
            z
        )

    return result
end

------------------------------------------------------------
-- COMPUTER CAPABILITIES
------------------------------------------------------------

function WorldRegistry.GetComputerCapabilities(
    computerId
)
    if not KIPN.Server.GetComputer then

        return {}
    end

    local computer =
        KIPN.Server.GetComputer(
            computerId
        )

    if not computer then

        return {}
    end

    local x
    local y
    local z

    if computer.x ~= nil then

        x = computer.x
        y = computer.y
        z = computer.z

    elseif type(computer.location) == "table" then

        x = computer.location.x
        y = computer.location.y
        z = computer.location.z

    elseif KIPN.Shared.ParseComputerIdCoords then

        x, y, z =
            KIPN.Shared.ParseComputerIdCoords(
                computer.locationKey or computerId
            )

    end

    if x == nil or
       y == nil then

        return {}
    end

    local capabilities =
        WorldRegistry.GetLocationCapabilities(
            x,
            y,
            z
        )

    return capabilities
end

------------------------------------------------------------
-- UPDATE ZONE
------------------------------------------------------------

function WorldRegistry.UpdateZone(
    zoneId,
    changes
)
    if not zoneId then

        return false,
            "ZONE_ID_REQUIRED"
    end

    if type(changes) ~= "table" then

        return false,
            "CHANGES_REQUIRED"
    end

    local zone =
        WorldRegistry.GetZone(
            zoneId
        )

    if not zone then

        return false,
            "ZONE_NOT_FOUND"
    end

    --------------------------------------------------------
    -- Snapshot for safehouse-overlap rollback (see the unified
    -- check near the end of this function, after every field
    -- below has been tentatively applied).
    --------------------------------------------------------

    local originalType =
        zone.type

    local originalActive =
        zone.active

    local originalGeometry =
        zone.geometry

    --------------------------------------------------------
    -- TYPE
    --------------------------------------------------------

    if changes.type ~= nil then

        if not isValidZoneType(
            changes.type
        ) then

            return false,
                "UNKNOWN_ZONE_TYPE"
        end

        zone.type =
            changes.type
    end

    --------------------------------------------------------
    -- ACTIVE STATE
    --------------------------------------------------------

    if changes.active ~= nil then

        zone.active =
            changes.active == true
    end

    --------------------------------------------------------
    -- METADATA
    --------------------------------------------------------

    if changes.metadata ~= nil then

        if type(changes.metadata) ~= "table" then

            return false,
                "METADATA_INVALID"
        end

        zone.metadata =
            changes.metadata
    end

    --------------------------------------------------------
    -- CAPABILITIES
    --------------------------------------------------------

    if changes.capabilities ~= nil then

        if type(changes.capabilities) ~= "table" then

            return false,
                "CAPABILITIES_INVALID"
        end

        zone.capabilities =
            changes.capabilities
    end

    --------------------------------------------------------
    -- COMBAT POLICY
    --
    -- changes.combatPolicy == false clears the policy back
    -- to "unrestricted / vanilla passthrough" (nil).
    --
    -- changes.combatPolicy == nil means "leave unchanged"
    -- (the field was simply not part of this update), same
    -- convention as every other UpdateZone field.
    --------------------------------------------------------

    if changes.combatPolicy ~= nil then

        if changes.combatPolicy == false then

            zone.combatPolicy =
                nil

        elseif not isValidCombatPolicy(
            changes.combatPolicy
        ) then

            return false,
                "UNKNOWN_COMBAT_POLICY"

        else

            zone.combatPolicy =
                changes.combatPolicy

        end
    end

    --------------------------------------------------------
    -- GEOMETRY
    --------------------------------------------------------

    if changes.geometry ~= nil then

        local valid, reason =
            validateGeometry(
                zone.shape,
                changes.geometry
            )

        if not valid then

            return false,
                reason
        end

        zone.geometry =
            normalizeRectangle(
                changes.geometry
            )
    end

    --------------------------------------------------------
    -- SHAPE
    --------------------------------------------------------

    if changes.shape ~= nil then

        if not isValidShapeType(
            changes.shape
        ) then

            return false,
                "UNSUPPORTED_SHAPE"
        end

        if changes.shape ~=
           WorldRegistry.ShapeTypes.RECTANGLE then

            return false,
                "UNSUPPORTED_SHAPE"
        end

        zone.shape =
            changes.shape
    end

    --------------------------------------------------------
    -- SAFEHOUSE OVERLAP (unified gate)
    --
    -- Runs AFTER every field above has been tentatively applied,
    -- so zone.type/.active/.geometry reflect the RESULTANT state
    -- -- this single check correctly covers move, resize, retype
    -- to non-custom, and reactivate-while-non-custom. On a
    -- conflict, the mutated fields are rolled back to their
    -- pre-call values and nothing is persisted.
    --------------------------------------------------------

    if not zoneTypeExemptFromSafehouseOverlap(zone.type) and
       zone.active == true then

        local overlappingSafehouses =
            WorldRegistry.GetSafehousesOverlappingRectangle(
                zone.geometry
            )

        if tableHasEntries(overlappingSafehouses) then

            zone.type =
                originalType

            zone.active =
                originalActive

            zone.geometry =
                originalGeometry

            logError(
                "UpdateZone REJECTED | zoneId=" ..
                tostring(zoneId) ..
                " | resultant type/active would overlap an active Safehouse claim."
            )

            return false,
                "Non-custom KIPN zones cannot overlap an existing Safehouse."
        end
    end

    zone.updatedAtWorldDays =
        getWorldDays()

    -- Zones persist under data.configuration.worldZones; scope the
    -- save so a zone edit doesn't re-transmit every KIPN subsystem
    -- tag to every connected client.
    local saved =
        KIPN.Server.Save("configuration")

    if not saved then

        return false,
            "PERSISTENCE_FAILED"
    end

    log(
        "Updated zone: " ..
        tostring(zoneId)
    )

    return true,
        "ZONE_UPDATED"
end

------------------------------------------------------------
-- UPDATE ZONE GEOMETRY
------------------------------------------------------------
--
-- Convenience function for the future map editor.
--
-- This allows the UI to drag/edit an existing rectangle
-- without having to construct a complete zone update object.
------------------------------------------------------------

function WorldRegistry.UpdateZoneGeometry(
    zoneId,
    geometry
)
    local success, reason =
        WorldRegistry.UpdateZone(
            zoneId,
            {
                geometry = geometry,
            }
        )

    return success, reason
end

------------------------------------------------------------
-- SET ZONE CAPABILITIES
------------------------------------------------------------
--
-- Used by the future administration UI.
------------------------------------------------------------

function WorldRegistry.SetZoneCapabilities(
    zoneId,
    capabilities
)
    if type(capabilities) ~= "table" then

        return false,
            "CAPABILITIES_INVALID"
    end

    local success, reason =
        WorldRegistry.UpdateZone(
            zoneId,
            {
                capabilities =
                    capabilities,
            }
        )

    return success, reason
end

------------------------------------------------------------
-- SET ZONE COMBAT POLICY
------------------------------------------------------------
--
-- Used by the admin zone tool to attach/change/clear a
-- damage-zone policy on an existing zone.
--
-- Pass WorldRegistry.CombatPolicies.<X> to set a policy, or
-- `false` to clear it back to unrestricted (vanilla) combat.
------------------------------------------------------------

function WorldRegistry.SetZoneCombatPolicy(
    zoneId,
    combatPolicy
)
    local success, reason =
        WorldRegistry.UpdateZone(
            zoneId,
            {
                combatPolicy =
                    combatPolicy,
            }
        )

    return success, reason
end

------------------------------------------------------------
-- GET ZONE COMBAT POLICY
------------------------------------------------------------

function WorldRegistry.GetZoneCombatPolicy(zone)

    if type(zone) ~= "table" then

        return nil
    end

    if not isValidCombatPolicy(zone.combatPolicy) then

        return nil
    end

    return zone.combatPolicy
end

------------------------------------------------------------
-- DEACTIVATE ZONE
------------------------------------------------------------

function WorldRegistry.DeactivateZone(zoneId)
    local zone =
        WorldRegistry.GetZone(
            zoneId
        )

    if not zone then

        return false,
            "ZONE_NOT_FOUND"
    end

    local previousActive =
        zone.active

    zone.active =
        false

    zone.updatedAtWorldDays =
        getWorldDays()

    -- Zones persist under data.configuration.worldZones; scope the
    -- save so a zone edit doesn't re-transmit every KIPN subsystem
    -- tag to every connected client.
    local saved =
        KIPN.Server.Save("configuration")

    if not saved then

        zone.active =
            previousActive

        return false,
            "PERSISTENCE_FAILED"
    end

    log(
        "Deactivated zone: " ..
        tostring(zoneId)
    )

    return true,
        "ZONE_DEACTIVATED"
end

------------------------------------------------------------
-- REACTIVATE ZONE
------------------------------------------------------------

function WorldRegistry.ActivateZone(zoneId)
    local zone =
        WorldRegistry.GetZone(
            zoneId
        )

    if not zone then

        return false,
            "ZONE_NOT_FOUND"
    end

    zone.active =
        true

    if not zoneTypeExemptFromSafehouseOverlap(zone.type) then

        local overlappingSafehouses =
            WorldRegistry.GetSafehousesOverlappingRectangle(
                zone.geometry
            )

        if tableHasEntries(overlappingSafehouses) then

            zone.active =
                false

            logError(
                "ActivateZone REJECTED | zoneId=" ..
                tostring(zoneId) ..
                " | active non-custom geometry would overlap an active Safehouse claim."
            )

            return false,
                "Non-custom KIPN zones cannot overlap an existing Safehouse."
        end
    end

    zone.updatedAtWorldDays =
        getWorldDays()

    -- Zones persist under data.configuration.worldZones; scope the
    -- save so a zone edit doesn't re-transmit every KIPN subsystem
    -- tag to every connected client.
    local saved =
        KIPN.Server.Save("configuration")

    if not saved then

        zone.active =
            false

        return false,
            "PERSISTENCE_FAILED"
    end

    log(
        "Activated zone: " ..
        tostring(zoneId)
    )

    return true,
        "ZONE_ACTIVATED"
end

------------------------------------------------------------
-- ADMIN MAP SNAPSHOT
------------------------------------------------------------
--
-- This is intentionally a plain-data representation intended
-- for transmission to the client map editor.
--
-- IMPORTANT:
--
-- This function does NOT grant administrative authority.
--
-- The caller must separately verify:
--
--     admin.world
--
-- before sending this information to a player.
--
-- The future Starlit map overlay can consume this snapshot
-- without needing access to the server's internal data tables.
------------------------------------------------------------

function WorldRegistry.GetMapSnapshot(
    includeInactive
)
    local zones =
        WorldRegistry.GetZones(
            nil,
            includeInactive == true
        )

    local snapshot = {}

    for zoneId, zone in pairs(zones) do

        local capabilities =
            WorldRegistry.GetZoneCapabilities(
                zone
            )

        snapshot[zoneId] = {

            id =
                zone.id,

            type =
                zone.type,

            label =
                WorldRegistry.ZoneTypeLabels[
                    zone.type
                ] or
                zone.type,

            shape =
                zone.shape,

            active =
                zone.active ~= false,

            geometry =
                zone.geometry,

            capabilities =
                capabilities,

            combatPolicy =
                zone.combatPolicy,

            combatPolicyLabel =
                zone.combatPolicy and
                WorldRegistry.CombatPolicyLabels[
                    zone.combatPolicy
                ] or nil,

            metadata =
                zone.metadata,

        }
    end

    return snapshot
end

------------------------------------------------------------
-- CLIENT-SAFE LOCATION SNAPSHOT
------------------------------------------------------------
--
-- Intended for an authenticated terminal/client request.
--
-- Provides the client with the current server-authoritative
-- classification without exposing the complete registry.
------------------------------------------------------------

function WorldRegistry.GetClientLocationSnapshot(
    x,
    y,
    z
)
    local classification =
        WorldRegistry.GetLocationClassification(
            x,
            y,
            z
        )

    local capabilities =
        WorldRegistry.GetLocationCapabilities(
            x,
            y,
            z
        )

    local result = {

        x =
            tonumber(x),

        y =
            tonumber(y),

        z =
            tonumber(z) or 0,

        classification =
            classification,

        capabilities =
            capabilities,

    }

    return result
end

------------------------------------------------------------
-- COMMAND: GET COMPUTER INFO
--
-- Client-facing query used by terminal screens (e.g.
-- KIPN_MainMenu) to decide which menu items are relevant at the
-- computer's CURRENT position -- for example, only offering
-- Vehicle Registration inside a dealership zone.
--
-- Only the classification booleans are returned to the client,
-- never raw zone records, so a connected player never receives
-- zone geometry/metadata they have no other reason to see. See
-- WorldRegistry.GetClientLocationSnapshot() above for the same
-- pattern applied to a raw x/y/z location.
------------------------------------------------------------

local function handleGetComputerInfo(player, args)
    if not player then

        return false,
            "Player unavailable."
    end

    local computerId =
        args and args.computerId

    if not computerId then

        return false,
            "Computer could not be identified."
    end

    local classification =
        WorldRegistry.GetComputerClassification(
            computerId
        )

    if not classification then

        return false,
            "Computer is not registered."
    end

    -- Send every registered classification field so a companion
    -- service's zone type reaches the client menu with no edit here.
    local classificationPayload = {}

    for _, record in pairs(WorldRegistry.RegisteredZoneTypes) do
        if record.classificationField then
            classificationPayload[record.classificationField] =
                classification[record.classificationField] == true
        end
    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.COMPUTER_INFO,
        {
            computerId =
                computerId,

            classification =
                classificationPayload,
        }
    )

    return true
end

------------------------------------------------------------
-- SERVICE INITIALIZATION
--
-- Registers WorldRegistry's client-facing command handlers.
--
-- Called by the server bootstrap (KIPN_Server.lua) via:
--
--   initializeService(
--       "WorldRegistry",
--       KIPN.Server.WorldRegistry,
--       "Initialize"
--   )
------------------------------------------------------------

function WorldRegistry.Initialize()

    if type(KIPN.Server.RegisterCommandHandler) ~= "function" then

        logError(
            "WorldRegistry.Initialize deferred: " ..
            "server command router is not ready yet."
        )

        return false
    end

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.GET_COMPUTER_INFO,
        handleGetComputerInfo
    )

    return true
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

local function initWorldRegistry()
    --------------------------------------------------------
    -- KIPN_Server must already own the persistent data layer.
    --------------------------------------------------------

    if not KIPN
        or not KIPN.Server
        or not KIPN.Server.GetData then

        logError(
            "World Registry initialization deferred: " ..
            "KIPN.Server is not ready."
        )

        return
    end

    local data =
        KIPN.Server.GetData()

    if not data then

        logError(
            "World Registry initialization failed: " ..
            "KIPN data unavailable."
        )

        return
    end

    if type(data.configuration) ~= "table" then

        data.configuration = {}

    end

    if type(data.configuration.worldZones) ~= "table" then

        data.configuration.worldZones = {}

    end

    --------------------------------------------------------
    -- One-time, non-mutating scan for zones that already
    -- overlapped a Safehouse before this policy existed.
    --------------------------------------------------------

    local ok, err =
        pcall(
            WorldRegistry.ScanLegacySafehouseConflicts
        )

    if not ok then

        logError(
            "ScanLegacySafehouseConflicts() failed: " ..
            tostring(err)
        )
    end

end

Events.OnGameStart.Add(
    initWorldRegistry
)

------------------------------------------------------------
-- COMPLETE
------------------------------------------------------------

print(
    "[KIPN] World Registry service loaded"
)
