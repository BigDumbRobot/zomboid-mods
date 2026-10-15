--- Skylight glass: walkable a few times, then it breaks.
---
--- The skylight tile has no `solidfloor` (media/skylights.tiles), which keeps
--- its image out of the floor-tile renderer. Every side marks the square as
--- walkable itself: `solidfloor` on the square's PropertyContainer and the
--- solid-floor cache that falling reads. RecalcProperties() drops both, so they
--- are re-applied every tick.
---
--- The authority (server, or single player) watches players and zombies
--- stepping onto the glass. Each step rolls the sandbox Break Chance: the glass
--- either cracks (a quiet thump) or breaks with the window-smash sound, and
--- whoever is standing on it falls.

local Config = require("Skylights/Config")
local Log = require("Skylights/Logger")
local Daylight = require("Skylights/Daylight")

local Glass = SkylightsGlass or {}

-- Characters seen on each skylight square last tick, keyed by square position.
Glass.occupants = Glass.occupants or {}

local function makeWalkable(square)
    local properties = square:getProperties()
    if not properties:has(IsoFlagType.solidfloor) then
        properties:set(IsoFlagType.solidfloor)
    end
    square:setSolidFloor(true)
    square:setSolidFloorCached(true)
end

-- playServerSound only broadcasts from a dedicated server; single player plays locally.
local function playSound(name, square)
    if isServer() then
        playServerSound(name, square)
    else
        getSoundManager():PlayWorldSound(name, square, 0, 20, 1, false)
    end
end

local function shatter(square, skylight)
    local x, y, z = square:getX(), square:getY(), square:getZ()
    playSound(Config.BREAK_SOUND, square)
    addSound(nil, x, y, z, 20, 20)
    Daylight.markHole(square)
    square:transmitRemoveItemFromSquare(skylight)
    square:getProperties():unset(IsoFlagType.solidfloor)
    square:RecalcAllWithNeighbours(true)
    Daylight.track(x, y, z)
    Log.info("Glass.shatter", "skylight broke", { x = x, y = y, z = z })
end

local function isCharacter(object)
    return instanceof(object, "IsoPlayer") or instanceof(object, "IsoZombie")
end

--- Authority only: rolls the break chance for each player or zombie that steps onto the glass.
local function checkCrossings(k, square, skylight)
    local previous = Glass.occupants[k] or {}
    local current = {}
    local arrivals = 0
    local objects = square:getMovingObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if isCharacter(object) then
            current[object] = true
            if not previous[object] then
                arrivals = arrivals + 1
            end
        end
    end
    Glass.occupants[k] = current
    if arrivals == 0 then
        return
    end

    local chance = Config.breakChance()
    for _ = 1, arrivals do
        if chance > 0 and ZombRand(100) < chance then
            Glass.occupants[k] = nil
            shatter(square, skylight)
            return
        end
    end
    playSound(Config.CRACK_SOUND, square)
end

function Glass.onTick()
    local cell = getCell()
    if cell == nil then
        return
    end
    local authority = Config.isAuthority()
    for k, entry in pairs(Daylight.tracked) do
        local square = cell:getGridSquare(entry.x, entry.y, entry.z)
        local skylight = Daylight.skylightOn(square)
        if skylight ~= nil then
            makeWalkable(square)
            if authority then
                checkCrossings(k, square, skylight)
            end
        else
            Glass.occupants[k] = nil
        end
    end
end

if not SkylightsGlassRegistered then
    SkylightsGlassRegistered = true
    Events.OnTick.Add(Glass.onTick)
end

SkylightsGlass = Glass

return Glass
