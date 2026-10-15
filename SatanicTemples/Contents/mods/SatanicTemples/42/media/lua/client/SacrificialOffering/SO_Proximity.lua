require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_ClientState"
require "SacrificialOffering/SO_Announce"

local SO = SacrificialOffering
SO.Proximity = SO.Proximity or {}
local Proximity = SO.Proximity

-- Distance (in tiles) from a temple's edge at which the prompt fires.
local RADIUS = 10
local CHECK_INTERVAL_MS = 750

-- zoneId -> true while the local player is currently within RADIUS of that temple.
-- Rebuilt every check so the prompt re-arms once the player walks away.
Proximity.near = Proximity.near or {}
local nextCheckMs = 0

local function distanceToZone(px, py, zone)
    local dx = math.max(zone.x1 - px, 0, px - zone.x2)
    local dy = math.max(zone.y1 - py, 0, py - zone.y2)
    return math.sqrt(dx * dx + dy * dy)
end

function Proximity.Update(player)
    if not player or not player.isLocalPlayer or not player:isLocalPlayer() then return end
    local now = SO.Util.NowMs()
    if now < nextCheckMs then return end
    nextCheckMs = now + CHECK_INTERVAL_MS

    local px, py = player:getX(), player:getY()
    local pz = math.floor(player:getZ())
    local seen = {}
    local prompted = false
    for _, zone in ipairs(SO.Client.Zones or {}) do
        local zoneId = tostring(zone.id)
        if (tonumber(zone.z) or 0) == pz and distanceToZone(px, py, zone) <= RADIUS then
            seen[zoneId] = true
            if not Proximity.near[zoneId] and not prompted then
                prompted = true
                SO.Announce.Show(getText("IGUI_SO_ProximityPrompt"), "bad")
            end
        end
    end
    Proximity.near = seen
end

Events.OnPlayerUpdate.Add(Proximity.Update)

SO.Logger.Debug("Temple proximity prompt installed")

return Proximity
