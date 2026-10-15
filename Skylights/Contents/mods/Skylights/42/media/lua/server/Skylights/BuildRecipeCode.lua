--- Build hooks for the Skylight entity (media/scripts/entities/skylights.txt).
---
--- Both wrap the vanilla floor hooks: OnIsValid adds a minimum build level,
--- OnCreate marks the placed skylight and starts its daylight and glass tracking.

local Config = require("Skylights/Config")
local Log = require("Skylights/Logger")
local Daylight = require("Skylights/Daylight")

BuildRecipeCode = BuildRecipeCode or {}
BuildRecipeCode.skylights = BuildRecipeCode.skylights or {}

function BuildRecipeCode.skylights.OnIsValid(params)
    if not params or not params.square then
        return false
    end

    if BuildRecipeCode.floor and BuildRecipeCode.floor.OnIsValid then
        if not BuildRecipeCode.floor.OnIsValid(params) then
            return false
        end
    end

    return params.square:getZ() >= Config.MIN_Z
end

function BuildRecipeCode.skylights.OnCreate(params)
    if BuildRecipeCode.floor and BuildRecipeCode.floor.OnCreate then
        BuildRecipeCode.floor.OnCreate(params)
    end

    local thumpable = params and params.thumpable
    if thumpable == nil then
        return
    end

    -- No transmitModData: the object isn't on clients yet. The build sends the
    -- whole object, modData included, after OnCreate returns.
    thumpable:getModData()[Config.MARKER_KEY] = true

    local square = thumpable:getSquare()
    if square == nil then
        return
    end
    square:RecalcAllWithNeighbours(true)
    Daylight.announceSkylight(square)

    Log.info("BuildRecipeCode.skylights.OnCreate", "skylight placed", {
        x = square:getX(), y = square:getY(), z = square:getZ(),
    })
end
