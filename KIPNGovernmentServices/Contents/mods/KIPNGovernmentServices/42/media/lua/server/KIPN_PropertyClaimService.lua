-- KIPN_PropertyClaimService.lua
--
-- Property (Safehouse) + Excavation claim logic for COMPUTER Safehouse
-- and Land Claims.
--
-- Terminal (KIPN.Server.ClaimService) still owns the authoritative
-- claim-record store, the spatial enforcement index, and the generic
-- release lifecycle. THIS file owns the property/excavation policy:
-- target validation, building/terrain checks, safehouse engine
-- projection, the deed/permit claim flow, and the safehouse-release
-- command handlers. It calls Terminal's exported store API and never
-- touches ModData directly.
--
-- Namespace: KIPN.Server.GovClaimService (NOT ClaimService -- must not
-- collide with Terminal's).

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_ClaimService"
require "KIPN_SafehouseBridge"
require "KIPN_GovArtifactService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.GovClaimService = KIPN.Server.GovClaimService or {}

local GovClaimService = KIPN.Server.GovClaimService

-- Terminal's claim service -- the authoritative store + generic API.
local ClaimService = KIPN.Server.ClaimService

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
-- DEPENDENCY ACCESSORS
------------------------------------------------------------

-- Property / Excavation artifact issuance + claim-artifact validation
-- and consumption live in KIPN_GovArtifactService.lua. The generic
-- artifact engine it delegates to belongs to Terminal.
local function getGovArtifactService()

    return KIPN.Server.GovArtifactService

end
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

                require "KIPN_WorldRegistry"

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
-- SAFEHOUSE MUTATION GUARD
--
-- KIPN_SafehouseService checks GovClaimService.IsSafehouseMutation
-- InProgress() to avoid reconciling an intentionally intermediate
-- state mid-transaction.
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

function GovClaimService.IsSafehouseMutationInProgress()
    return safehouseMutationDepth > 0
end


------------------------------------------------------------
-- TERMINAL STORE DELEGATION
------------------------------------------------------------


local function getClaimData()
    return ClaimService.GetClaimData()
end

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

local function createClaimRecord(player, claimType, targetId, zoneId, artifactId, position, extraFields)
    return ClaimService.CreateClaimRecord(player, claimType, targetId, zoneId, artifactId, position, extraFields)
end

local function removeClaimRecord(claimId)
    return ClaimService.RemoveClaimRecord(claimId)
end

local function expireOverlappingAreaClaims(rect)
    return ClaimService.ExpireOverlappingAreaClaims(rect)
end

local function findOverlappingAreaClaim(rect, excludeClaimId)
    return ClaimService.FindOverlappingAreaClaim(rect, excludeClaimId)
end

-- Terminal owns the generic "here are your claims" handler; a
-- safehouse release re-sends it so Property Records refreshes.
local function handleGetMyClaimsCommand(player, args)
    if type(ClaimService.SendPlayerClaims) == "function" then
        return ClaimService.SendPlayerClaims(player, args or {})
    end
    return false
end


------------------------------------------------------------
-- PLAYER / WORLD HELPERS
------------------------------------------------------------
--
-- World-time / calendar stamping is done by Terminal's
-- ClaimService.CreateClaimRecord().

-- The claim owner key: the player's server account, the same key
-- Terminal's ClaimService writes into claim.ownerSteamId (see
-- KIPN.Shared.GetPlayerId). Never the Steam ID itself.
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
-- BUILDING / TERRAIN
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
-- ZONE POLICY
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
-- TARGET IDS / RECTANGLES
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

------------------------------------------------------------
-- SAFEHOUSE HELPERS
------------------------------------------------------------

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

local function findSafehouseForClaim(claim)

    if type(claim) ~= "table"
        or claim.type ~= ClaimService.Types.PROPERTY
    then

        return nil

    end

    local bridge =
        KIPN.Bridges
        and KIPN.Bridges.Safehouse

    local claimRect =
        bridge
        and bridge.GetClaimRect(claim)

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
-- VALIDATORS
------------------------------------------------------------

function GovClaimService.ValidatePropertyTarget(
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
    --
    -- The engine safehouse covers the building plus the bridge's
    -- no-entry buffer, so conflicts are checked against that area.
    -- A safehouse the player already owns around this building is
    -- adopted and rebuilt to the buffered footprint.
    --------------------------------------------------------

    local bridge =
        KIPN.Bridges
        and KIPN.Bridges.Safehouse

    local protectedRect =
        bridge
        and bridge.GetClaimRect({
            rectX1 = buildingRect.x1,
            rectY1 = buildingRect.y1,
            rectX2 = buildingRect.x2,
            rectY2 = buildingRect.y2,
        })
        or buildingRect

    local overlappingSafehouses =
        getSafehousesOverlapping(
            protectedRect
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

    -- The claim always records the building footprint; the target id
    -- is derived from it so it stays stable when the engine safehouse
    -- is rebuilt with a new id.
    local targetRect =
        buildingRect

    local safehouseId =
        getSafehouseId(adoptedSafehouse)

    local targetId =
        getPropertyTargetId(
            targetRect,
            nil
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

            -- Property claims have no zone/capability gate, so
            -- zone/zoneId are intentionally nil and the deed is
            -- validated without a scope.
            zone =
                nil,

            zoneId =
                nil,

        }

end

function GovClaimService.ValidateExcavationTarget(
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
    -- No capability gate: any open land may be claimed. The
    -- requirements are: not already claimed, not inside a building,
    -- not water, not overlapping another claim or safehouse, and
    -- not overlapping a Do Not Claim zone or an active non-custom
    -- KIPN zone.
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

            -- Excavation claims have no zone/capability gate, so
            -- zone/zoneId are intentionally nil and the permit is
            -- validated without a scope.
            zone =
                nil,

            zoneId =
                nil,

        }

end

function GovClaimService.ValidatePropertyClaimArtifact(
    player,
    claimItem,
    targetZoneId
)

    local artifacts =
        getGovArtifactService()

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

function GovClaimService.ValidateExcavationClaimArtifact(
    player,
    claimItem,
    targetZoneId
)

    local artifacts =
        getGovArtifactService()

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
-- CLAIM FLOWS
------------------------------------------------------------

function GovClaimService.ClaimProperty(
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
        GovClaimService.ValidatePropertyTarget(
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
        GovClaimService.ValidatePropertyClaimArtifact(
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
        GovClaimService.ValidatePropertyTarget(
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

                rectIsFootprint =
                    true,

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
        getGovArtifactService()

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
    -- but the artifact remains consumed -- it is not refunded.
    --------------------------------------------------------

    local bridge =
        KIPN.Bridges
        and KIPN.Bridges.Safehouse

    local adoptedSafehouse =
        targetData.existingSafehouse

    local adoptedSnapshot =
        adoptedSafehouse
        and bridge
        and bridge.Snapshot(adoptedSafehouse)
        or nil

    ----------------------------------------------------
    -- PROJECT THE CLAIM THROUGH THE BRIDGE
    --
    -- Creates the engine safehouse (or rebuilds an adopted one) as
    -- the building footprint plus the no-entry buffer. Deliberately
    -- bypasses vanilla hasSafehouse()/alreadyHaveSafehouse()/
    -- allowSafeHouse() policy gates. KIPN's MaxClaimsPerPlayer is the
    -- authoritative multi-property quota.
    ----------------------------------------------------

    local safehouseOk,
        safehouse =
        runSafehouseMutation(
            function()

                if not bridge
                    or type(bridge.EnsureClaimProjection) ~= "function"
                then
                    error("KIPN SafehouseBridge.EnsureClaimProjection unavailable")
                end

                local projected,
                    reason =
                    bridge.EnsureClaimProjection(
                        claimRecord
                    )

                if not projected then
                    error(tostring(reason))
                end

                return projected

            end
        )

    local createdSafehouse =
        safehouseOk
        and safehouse ~= nil

    if not safehouseOk
        or not safehouse
    then

        removeClaimRecord(
            claimRecord.id
        )

        if adoptedSnapshot
            and not bridge.FindExactRect(adoptedSnapshot.rect)
        then
            runSafehouseMutation(function()
                return bridge.RestoreSnapshot(adoptedSnapshot)
            end)
        end

        logError(
            "Safehouse projection failed: " ..
            tostring(safehouse) ..
            ". Artifact remains consumed."
        )

        return false,
            "Safehouse could not be established."

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

            local snapshot = bridge.Snapshot(safehouse)

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
                if adoptedSnapshot then
                    runSafehouseMutation(function()
                        return bridge.RestoreSnapshot(adoptedSnapshot)
                    end)
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

function GovClaimService.ClaimExcavation(
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
        GovClaimService.ValidateExcavationTarget(
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
        GovClaimService.ValidateExcavationClaimArtifact(
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
        GovClaimService.ValidateExcavationTarget(
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
        getGovArtifactService()

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
-- RECONCILE MANAGED SAFEHOUSES
------------------------------------------------------------

------------------------------------------------------------
-- FOOTPRINT MIGRATION
--
-- Property claims record the building footprint; the engine
-- safehouse adds the bridge buffer. Records written before
-- rectIsFootprint existed stored the engine rectangle instead.
-- Their targetId ("x1_y1_x2_y2") is the building footprint, so it
-- is restored from there. Adopted records ("safehouse_<id>") keep
-- their rectangle as the footprint.
------------------------------------------------------------

local function migrateClaimFootprint(claim)

    if type(claim) ~= "table"
        or claim.rectIsFootprint == true
    then
        return false
    end

    local x1, y1, x2, y2 =
        string.match(
            tostring(claim.targetId or ""),
            "^(-?%d+)_(-?%d+)_(-?%d+)_(-?%d+)$"
        )

    if x1 then
        claim.rectX1 = tonumber(x1)
        claim.rectY1 = tonumber(y1)
        claim.rectX2 = tonumber(x2)
        claim.rectY2 = tonumber(y2)
    end

    claim.rectIsFootprint = true

    log(
        "Property claim footprint migrated | claim=" ..
        tostring(claim.id)
    )

    return true

end

function GovClaimService.ReconcileManagedSafehouses()

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

        if migrateClaimFootprint(claim) then
            metadataChanged = true
        end

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
-- EXCAVATION PERMIT TIERS
------------------------------------------------------------

-- Server-side clamp on how far from the player a client-supplied
-- excavation placement coordinate may sit (see handleClaimExcavationCommand).
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
    -- SERVER-VALIDATED ITEM TYPE FALLBACK
    --------------------------------------------------------
    --
    -- ArtifactService already validated this physical item against
    -- its authoritative artifact record. This fallback covers
    -- permits whose record carries no class metadata. Display name
    -- and client ModData are intentionally NOT trusted here.
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


------------------------------------------------------------
-- COMMAND HANDLERS
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
        getGovArtifactService()

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
        GovClaimService.ClaimProperty(
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
        getGovArtifactService()

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
        GovClaimService.ClaimExcavation(
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

    -- Rect fallback compares against the buffered engine-projection rect
    -- (bridge.GetClaimRect): the claim stores the building footprint and
    -- the live safehouse is grown by the no-entry buffer.
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

    -- Vanilla SafeHouse with no KIPN ownership record (admin-created or
    -- pre-dating KIPN). KIPN still owns the panel interaction, but it does
    -- not manufacture a KIPN claim for it.
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
-- RELEASE HOOKS
------------------------------------------------------------

local function propertyOnBeforeRelease(claim, reason, ctx)

    if reason == "safehouse_owner_changed" then
        return true
    end

    local liveSafehouse = findSafehouseForClaim(claim)
    if not liveSafehouse then
        return true
    end

    local bridge = KIPN.Bridges and KIPN.Bridges.Safehouse
    if not bridge
        or type(bridge.Snapshot) ~= "function"
        or type(bridge.RemoveAuthoritative) ~= "function"
    then
        return false, "Safehouse engine bridge unavailable."
    end

    ctx.safehouseSnapshot = bridge.Snapshot(liveSafehouse)
    if not ctx.safehouseSnapshot then
        return false, "Safehouse state could not be captured for release."
    end

    local removalOk, removalResult = runSafehouseMutation(function()
        local removed, why = bridge.RemoveAuthoritative(liveSafehouse)
        if not removed then error(tostring(why)) end
        return true
    end)

    if not removalOk or removalResult ~= true then
        logError("Property engine release failed | claim=" .. tostring(claim.id)
            .. " | reason=" .. tostring(removalResult))
        return false, "Vanilla safehouse could not be removed."
    end

    return true
end

local function propertyOnReleaseRollback(claim, ctx)

    if not ctx.safehouseSnapshot then
        return
    end

    local bridge = KIPN.Bridges and KIPN.Bridges.Safehouse
    if not bridge then
        return
    end

    local restoreOk, restored = runSafehouseMutation(function()
        local safehouse, why = bridge.RestoreSnapshot(ctx.safehouseSnapshot)
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
            .. tostring(claim.id) .. " | reason=" .. tostring(restored))
    end
end

local function propertyOnAfterRelease(claim, ctx)

    local svc = KIPN.Server.SafehouseService
    if not svc then return end

    if ctx.safehouseSnapshot
        and type(svc.BroadcastProjectionRemoval) == "function"
    then
        pcall(svc.BroadcastProjectionRemoval, ctx.safehouseSnapshot)
    end

    if type(svc.BroadcastSafehouseSync) == "function" then
        pcall(svc.BroadcastSafehouseSync)
    end
end


------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

ClaimService.RegisterClaimType("property", {
    requiredCapability = "property.claim",
    serviceConfigKey = "House",
    label = "Safehouse",
    -- KIPN imposes no additional access restriction on property claims;
    -- vanilla SafeHouse stays the sole protection authority
    -- (KIPN_ClaimPermissions.canDo).
    deferAccessToEngine = true,
    validateTarget = GovClaimService.ValidatePropertyTarget,
    validateClaimArtifact = GovClaimService.ValidatePropertyClaimArtifact,
    claim = GovClaimService.ClaimProperty,
    onBeforeRelease = propertyOnBeforeRelease,
    onReleaseRollback = propertyOnReleaseRollback,
    onAfterRelease = propertyOnAfterRelease,
    -- Terminal's generic GET_MY_CLAIMS handler calls this before it
    -- composes the response, so the player's Property Records list
    -- reflects any vanilla/admin SafeHouse changes made outside KIPN.
    onListClaimsRefresh = function(_player)
        GovClaimService.ReconcileManagedSafehouses()
    end,
    -- Terminal's generic RELEASE_CLAIM handler calls this before it
    -- retires ownership: a managed safehouse whose live engine owner
    -- has drifted away from the KIPN record must not be released.
    validatePlayerRelease = validateManagedSafehouseForPlayerRelease,
})

ClaimService.RegisterClaimType("excavation", {
    requiredCapability = "excavation.claim",
    serviceConfigKey = "Excavation",
    label = "Excavation",
    -- KIPN_ClaimPermissions' OnPlayerMove hook actively pushes a
    -- non-owner back out of an excavation claim (unless
    -- Excavation.AllowNonOwnerEnter).
    enforceEntry = true,
    validateTarget = GovClaimService.ValidateExcavationTarget,
    validateClaimArtifact = GovClaimService.ValidateExcavationClaimArtifact,
    claim = GovClaimService.ClaimExcavation,
    onAfterRelease = function()
        local svc = KIPN.Server.SafehouseService
        if svc and type(svc.BroadcastAdminClaimOverlay) == "function" then
            pcall(svc.BroadcastAdminClaimOverlay)
        end
    end,
})

------------------------------------------------------------
-- INITIALIZATION  (driven by KIPN_GovServicesInit.lua's RegisterService)
------------------------------------------------------------

function GovClaimService.Initialize()

    if type(KIPN.Server.RegisterCommandHandler) ~= "function" then
        logError("RegisterCommandHandler unavailable; property/excavation commands unreachable.")
        return false
    end

    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.CLAIM_PROPERTY, handleClaimPropertyCommand)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.CLAIM_EXCAVATION, handleClaimExcavationCommand)
    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.RELEASE_SAFEHOUSE or "releaseSafehouse",
        handleReleaseSafehouseCommand
    )

    log("Government Services claim service initialized.")
    return true
end

print("[KIPN] Government Services Property Claim Service loaded")

