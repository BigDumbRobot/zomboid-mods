require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_ClientState"
require "SacrificialOffering/SO_Protection"

-- Temple jack-o'-lanterns are plain world items placed by the server (see
-- SO_FixtureService). A carved pumpkin gives off no light on its own, so every
-- client adds an orange glow locally at each synced lantern position whose
-- pumpkin is actually on the ground. Nothing is sent over the wire.

local SO = SacrificialOffering
SO.JackOLanterns = SO.JackOLanterns or {}
local Lanterns = SO.JackOLanterns

local GLOW_R, GLOW_G, GLOW_B = 1.0, 0.45, 0.05   -- candle orange
local GLOW_RADIUS = 3
local SCAN_INTERVAL_MS = 1500
local MAX_RENDER_DISTANCE_SQ = 40 * 40

-- "x,y,z" -> IsoLightSource
local lights = {}
local nextScanAt = 0

local function makeLight(x, y, z)
    local ok, light = pcall(function()
        local l = IsoLightSource.new(x, y, z, GLOW_R, GLOW_G, GLOW_B, GLOW_RADIUS)
        if l.setLife then l:setLife(-1) end
        getCell():addLamppost(l)
        return l
    end)
    return ok and light or nil
end

local function dropLight(light)
    if not light then return end
    pcall(function() getCell():removeLamppost(light) end)
end

local function hasLantern(square)
    local objects = square:getWorldObjects()
    for index = 0, objects:size() - 1 do
        local worldItem = objects:get(index)
        if worldItem and SO.Protection.IsLanternItem(worldItem:getItem()) then return true end
    end
    return false
end

function Lanterns.Refresh()
    local player = getPlayer()
    local wanted = {}
    if player then
        local px, py = player:getX(), player:getY()
        for _, zone in ipairs(SO.Client.Zones) do
            for _, position in ipairs(zone.fixtures and zone.fixtures.lanterns or {}) do
                local dx, dy = position.x - px, position.y - py
                if dx * dx + dy * dy <= MAX_RENDER_DISTANCE_SQ then
                    local square = getCell():getGridSquare(position.x, position.y, position.z)
                    if square and hasLantern(square) then
                        wanted[position.x .. "," .. position.y .. "," .. position.z] = position
                    end
                end
            end
        end
    end
    for key, light in pairs(lights) do
        if not wanted[key] then
            dropLight(light)
            lights[key] = nil
        end
    end
    for key, position in pairs(wanted) do
        if not lights[key] then lights[key] = makeLight(position.x, position.y, position.z) end
    end
end

local function onTick()
    local now = SO.Util.NowMs()
    if now < nextScanAt then return end
    nextScanAt = now + SCAN_INTERVAL_MS
    local ok, err = pcall(Lanterns.Refresh)
    if not ok then SO.Logger.Error("Jack-o'-lantern glow refresh failed", { error = tostring(err) }) end
end

Events.OnTick.Add(onTick)

return Lanterns
