require "ISUI/Maps/ISWorldMap"
require "ISUI/Maps/ISMiniMap"
require "BonkZone/BonkZone_Constants"
require "BonkZone/BonkZone_Logger"
require "BonkZone/BonkZone_Registry"

BonkZone = BonkZone or {}
BonkZone.MapOverlay = BonkZone.MapOverlay or {}

local MapOverlay = BonkZone.MapOverlay
local Constants = BonkZone.Constants
local Logger = BonkZone.Logger
local Registry = BonkZone.Registry

MapOverlay.Patched = MapOverlay.Patched or false

local function drawLine(mapUI, x1, y1, x2, y2, thickness, color)
    local uiX1 = mapUI.mapAPI:worldToUIX(x1, y1)
    local uiY1 = mapUI.mapAPI:worldToUIY(x1, y1)
    local uiX2 = mapUI.mapAPI:worldToUIX(x2, y2)
    local uiY2 = mapUI.mapAPI:worldToUIY(x2, y2)
    mapUI.javaObject:DrawLine(Texture:getWhite(), uiX1, uiY1, uiX2, uiY2, thickness, color.r, color.g, color.b, color.a)
end

local function drawZone(mapUI, zone, showLabel)
    local startedAt = Logger.Begin("MapOverlay.drawZone", { id = zone.id })
    local border = Constants.MAP_COLOR
    local fill = Constants.MAP_FILL_COLOR
    drawLine(mapUI, zone.x1, zone.y1, zone.x2, zone.y1, 3, border)
    drawLine(mapUI, zone.x2, zone.y1, zone.x2, zone.y2, 3, border)
    drawLine(mapUI, zone.x2, zone.y2, zone.x1, zone.y2, 3, border)
    drawLine(mapUI, zone.x1, zone.y2, zone.x1, zone.y1, 3, border)

    for index = 1, 5 do
        local fraction = index / 6
        local startX = zone.x1 + ((zone.x2 - zone.x1) * fraction)
        drawLine(mapUI, startX, zone.y1, zone.x1, zone.y1 + ((zone.y2 - zone.y1) * fraction), 1, fill)
        local startY = zone.y1 + ((zone.y2 - zone.y1) * fraction)
        drawLine(mapUI, zone.x2, startY, zone.x1 + ((zone.x2 - zone.x1) * fraction), zone.y2, 1, fill)
    end

    if showLabel and mapUI.drawText then
        local labelX = mapUI.mapAPI:worldToUIX(zone.x1, zone.y1)
        local labelY = mapUI.mapAPI:worldToUIY(zone.x1, zone.y1)
        mapUI:drawText("BONK: " .. tostring(zone.name), labelX + 5, labelY + 3, border.r, border.g, border.b, 1, UIFont.Small)
    end
    Logger.Finish("MapOverlay.drawZone", startedAt, true)
end

local function getViewportBounds(mapUI)
    local width = tonumber(mapUI.width) or 0
    local height = tonumber(mapUI.height) or 0
    local points = {
        { mapUI.mapAPI:uiToWorldX(0, 0), mapUI.mapAPI:uiToWorldY(0, 0) },
        { mapUI.mapAPI:uiToWorldX(width, 0), mapUI.mapAPI:uiToWorldY(width, 0) },
        { mapUI.mapAPI:uiToWorldX(width, height), mapUI.mapAPI:uiToWorldY(width, height) },
        { mapUI.mapAPI:uiToWorldX(0, height), mapUI.mapAPI:uiToWorldY(0, height) },
    }
    local minimumX, minimumY = points[1][1], points[1][2]
    local maximumX, maximumY = minimumX, minimumY
    for index = 2, #points do
        minimumX = math.min(minimumX, points[index][1])
        minimumY = math.min(minimumY, points[index][2])
        maximumX = math.max(maximumX, points[index][1])
        maximumY = math.max(maximumY, points[index][2])
    end
    Logger.RateLimited("TRACE", "MapOverlay.getViewportBounds", 5000, "MapOverlay.getViewportBounds", "calculated")
    return minimumX, minimumY, maximumX, maximumY
end

local function intersectsViewport(zone, minimumX, minimumY, maximumX, maximumY)
    local result = zone.x1 <= maximumX and zone.x2 >= minimumX and zone.y1 <= maximumY and zone.y2 >= minimumY
    Logger.RateLimited("TRACE", "MapOverlay.intersectsViewport", 5000, "MapOverlay.intersectsViewport", "checked")
    return result
end

function MapOverlay.Render(mapUI, showLabels)
    if not mapUI or not mapUI.mapAPI or not mapUI.javaObject then return end
    local minimumX, minimumY, maximumX, maximumY = getViewportBounds(mapUI)
    for _, zone in ipairs(Registry.GetZones()) do
        if intersectsViewport(zone, minimumX, minimumY, maximumX, maximumY) then
            drawZone(mapUI, zone, showLabels == true)
        end
    end
    Logger.RateLimited("TRACE", "MapOverlay.Render." .. tostring(showLabels), 5000, "MapOverlay.Render", "rendered", { count = #Registry.GetZones() })
end

function MapOverlay.Install()
    local startedAt = Logger.Begin("MapOverlay.Install")
    if MapOverlay.Patched then
        Logger.Finish("MapOverlay.Install", startedAt, true, "already patched")
        return
    end
    MapOverlay.Patched = true

    local originalWorldMapPrerender = ISWorldMap.prerender
    ISWorldMap.prerender = function(self)
        originalWorldMapPrerender(self)
        MapOverlay.Render(self, true)
    end

    local originalMiniMapPrerender = ISMiniMapInner.prerender
    ISMiniMapInner.prerender = function(self)
        originalMiniMapPrerender(self)
        MapOverlay.Render(self, false)
    end

    Logger.Info("MapOverlay", "world map and minimap overlays installed")
    Logger.Finish("MapOverlay.Install", startedAt, true)
end

MapOverlay.Install()

return MapOverlay
