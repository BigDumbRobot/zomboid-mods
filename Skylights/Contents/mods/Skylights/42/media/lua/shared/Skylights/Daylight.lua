--- Daylight through skylights, and the open holes they leave when they break.
---
--- Intact skylight: the room below stays indoors. Renderers (clients and single
--- player) keep a light under it whose brightness follows the outdoor light on
--- the skylight's own roof square.
---
--- Broken skylight: the roof square keeps Config.HOLE_KEY in its modData. The
--- native lighting only gives sky light to a square whose whole column carries
--- the `exterior` flag (IsoGridSquare:getOpenAir()), and RecalcProperties()
--- clears that flag on room squares, so the square below the hole gets it
--- re-applied here: it is outdoors and receives real daylight until a floor is
--- built over the hole.

local Config = require("Skylights/Config")
local Log = require("Skylights/Logger")

local Daylight = SkylightsDaylight or {}

Daylight.tracked = Daylight.tracked or {}
Daylight.tick = Daylight.tick or 0
Daylight.announcements = Daylight.announcements or {}

local CHECK_INTERVAL_TICKS = 30

-- A client that hears "track" before the skylight object has reached it keeps
-- waiting this many checks before forgetting it (the server already delays
-- "track" a tick; this covers packets arriving out of order).
local ARRIVAL_WAIT_CHECKS = 20

local function key(x, y, z)
    return x .. "," .. y .. "," .. z
end

function Daylight.skylightOn(square)
    if square == nil then
        return nil
    end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local modData = object:getModData()
        if modData and modData[Config.MARKER_KEY] == true then
            return object
        end
    end
    return nil
end

local function isOpenHole(square)
    return square:getModData()[Config.HOLE_KEY] == true
        and not square:getProperties():has(IsoFlagType.solidfloor)
end

local function removeLight(entry)
    if entry.light ~= nil then
        getCell():removeLamppost(entry.light)
        entry.light = nil
    end
end

-- A light source lights its own tile at about twice its colour value. Colour
-- changes on a live light are not re-sent to the lighting engine, so a changed
-- level replaces the light (addLamppost triggers the refresh).
local function updateLight(entry, square)
    local target = Config.indoorBrightness() / 100 * square:getLightLevel(0)
    if target <= 0 then
        removeLight(entry)
        return
    end
    local share = target / 2
    if entry.light ~= nil and math.abs(share - entry.share) <= 0.005 then
        return
    end
    removeLight(entry)
    local color = Config.LIGHT_COLOR
    entry.light = IsoLightSource.new(entry.x, entry.y, entry.z - 1,
        color.r * share, color.g * share, color.b * share, Config.LIGHT_RADIUS)
    getCell():addLamppost(entry.light)
    entry.share = share
end

local function keepOutdoors(square)
    local properties = square:getProperties()
    if not properties:has(IsoFlagType.exterior) then
        properties:set(IsoFlagType.exterior)
        square:getChunk():checkLightingLater_AllPlayers_AllLevels()
    end
end

--- Refreshes one tracked roof square. Returns false when it should be forgotten.
local function refresh(entry)
    local cell = getCell()
    local square = cell and cell:getGridSquare(entry.x, entry.y, entry.z)
    if square == nil then
        removeLight(entry)
        return false -- unloaded; LoadGridsquare tracks it again
    end
    local below = cell:getGridSquare(entry.x, entry.y, entry.z - 1)

    if Daylight.skylightOn(square) ~= nil then
        entry.wait = nil
        if Config.isRenderer() then
            updateLight(entry, square)
        end
        return true
    end

    removeLight(entry)
    if isOpenHole(square) then
        if below ~= nil then
            keepOutdoors(below)
        end
        return true
    end

    if entry.wait ~= nil and entry.wait > 0 then
        entry.wait = entry.wait - 1
        return true -- announced, but the object has not reached this client yet
    end

    -- Skylight removed, or the hole floored over: the engine restores the room.
    if square:getModData()[Config.HOLE_KEY] ~= nil and Config.isAuthority() then
        square:getModData()[Config.HOLE_KEY] = nil
        square:transmitModdata()
    end
    if below ~= nil then
        below:RecalcProperties()
        below:getChunk():checkLightingLater_AllPlayers_AllLevels()
    end
    return false
end

--- waitChecks: keep the entry this many checks while its skylight hasn't arrived.
function Daylight.track(x, y, z, waitChecks)
    local k = key(x, y, z)
    if Daylight.tracked[k] == nil then
        Daylight.tracked[k] = { x = x, y = y, z = z }
    end
    if waitChecks ~= nil then
        Daylight.tracked[k].wait = waitChecks
    end
    if not refresh(Daylight.tracked[k]) then
        Daylight.tracked[k] = nil
    end
end

--- Authority only: records a skylight and tells clients about it. The build
--- sends the new object to clients only after OnCreate returns, so the "track"
--- command goes out on the next tick, once clients have the skylight.
function Daylight.announceSkylight(square)
    local x, y, z = square:getX(), square:getY(), square:getZ()
    Daylight.track(x, y, z)
    if isServer() then
        table.insert(Daylight.announcements, { x = x, y = y, z = z })
    end
end

local function sendAnnouncements()
    for i = 1, #Daylight.announcements do
        sendServerCommand(Config.COMMAND_MODULE, "track", Daylight.announcements[i])
    end
    Daylight.announcements = {}
end

--- Authority only: marks a roof square whose skylight broke and tells clients.
function Daylight.markHole(square)
    local x, y, z = square:getX(), square:getY(), square:getZ()
    square:getModData()[Config.HOLE_KEY] = true
    square:transmitModdata()
    if isServer() then
        sendServerCommand(Config.COMMAND_MODULE, "hole", { x = x, y = y, z = z })
    end
end

function Daylight.onServerCommand(module, command, args)
    if module ~= Config.COMMAND_MODULE or type(args) ~= "table" then
        return
    end
    if command == "hole" then
        local square = getCell():getGridSquare(args.x, args.y, args.z)
        if square ~= nil then
            square:getModData()[Config.HOLE_KEY] = true
        end
        Daylight.track(args.x, args.y, args.z)
    elseif command == "track" then
        Daylight.track(args.x, args.y, args.z, ARRIVAL_WAIT_CHECKS)
    end
end

function Daylight.onLoadGridsquare(square)
    if square:getZ() >= Config.MIN_Z and (Daylight.skylightOn(square) ~= nil or isOpenHole(square)) then
        Daylight.track(square:getX(), square:getY(), square:getZ())
    end
end

function Daylight.onTick()
    if #Daylight.announcements > 0 then
        sendAnnouncements()
    end
    Daylight.tick = Daylight.tick + 1
    if Daylight.tick % CHECK_INTERVAL_TICKS ~= 0 then
        return
    end
    for k, entry in pairs(Daylight.tracked) do
        local ok, keep = pcall(refresh, entry)
        if not ok then
            Log.error("Daylight.onTick", tostring(keep), { x = entry.x, y = entry.y, z = entry.z })
        elseif not keep then
            Daylight.tracked[k] = nil
        end
    end
end

if not SkylightsDaylightRegistered then
    SkylightsDaylightRegistered = true
    Events.LoadGridsquare.Add(Daylight.onLoadGridsquare)
    Events.OnTick.Add(Daylight.onTick)
    if isClient() then
        Events.OnServerCommand.Add(Daylight.onServerCommand)
    end
end

SkylightsDaylight = Daylight

return Daylight
