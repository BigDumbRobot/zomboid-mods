-- KIPN_ZoneMapRenderer.lua
--
-- Draws KIPN world zones (Government/Dealership/Custom
-- permission zones, plus PVE/Melee combat zones) directly onto the
-- vanilla World Map (F11) so every player sees them, not just an
-- admin with the Zone Admin panel open.
--
-- Zone data is pushed by KIPN_ZoneAdminServer.lua: once on load via
-- RequestZoneSync, and again automatically after any admin mutation
-- (CreateZone/DeactivateZone/SetZoneCombatPolicy) via broadcastZoneSync.
-- This file only caches whatever the server sends and renders it --
-- it never computes zone data itself.
--
-- Colors mirror KIPN_ZoneAdminMapUI.lua's ZONE_TYPE_COLORS /
-- COMBAT_POLICY_COLORS. Kept as a separate local copy rather than a
-- shared import, matching this codebase's existing convention of
-- duplicating small client-side display constants rather than reaching
-- across files for them (see the COMBAT_POLICY_OPTIONS comment in
-- KIPN_ZoneAdminUI.lua).

require "ISUI/Maps/ISWorldMap"

KIPN = KIPN or {}
KIPN.Client = KIPN.Client or {}

local MODULE_NAME = "KIPN_ZoneAdmin"

local ZONE_TYPE_COLORS = {
    government  = { r = 0.3, g = 0.55, b = 1.0 },
    dealership  = { r = 1.0, g = 0.6,  b = 0.2 },
    custom      = { r = 0.6, g = 0.6,  b = 0.6 },
}

local COMBAT_POLICY_COLORS = {
    PVE       = { r = 0.4, g = 0.9,  b = 0.9 },
    MELEE_PVP = { r = 1.0, g = 0.85, b = 0.2 },
}

local ZONE_TYPE_LABELS = {
    government  = "Government",
    dealership  = "Dealership",
    custom      = "Custom",
}

------------------------------------------------------------
-- CACHE (populated from server; preserved across file reloads)
------------------------------------------------------------

if not KIPN.Client.ZoneMapCache then
    KIPN.Client.ZoneMapCache = { zones = {} }
end

local function onServerCommand(module, command, args)
    if module ~= MODULE_NAME then
        return
    end

    if command == "ZoneSync" and args then
        KIPN.Client.ZoneMapCache.zones = args.zones or {}
    end
end

Events.OnServerCommand.Add(onServerCommand)

------------------------------------------------------------
-- INITIAL REQUEST
--
-- Fires once per session so the cache is populated even if no zone
-- has been mutated since this player last connected.
------------------------------------------------------------

local function requestZoneSync()
    local player = getSpecificPlayer(0)
    if not player then
        return
    end

    sendClientCommand(player, MODULE_NAME, "RequestZoneSync", {})
    Events.OnTick.Remove(requestZoneSync)
end

Events.OnTick.Add(requestZoneSync)

------------------------------------------------------------
-- MAP OPTIONS FILTER TOGGLE
--
-- Same shared-hook mechanism community zone-overlay mods use so
-- multiple mods can each add their own toggle to the map options
-- panel without stomping each other's patch.
------------------------------------------------------------

local zonesVisible = true

WorldMapOptions_visibleOptionsHooks = WorldMapOptions_visibleOptionsHooks or {}

table.insert(WorldMapOptions_visibleOptionsHooks, function(result)
    local opt = {}
    function opt:getName() return "KIPN Zones" end
    function opt:getType() return "boolean" end
    function opt:getValue() return zonesVisible end
    function opt:setValue(v) zonesVisible = v end
    table.insert(result, opt)
end)

if not WorldMapOptions._visibleOptionsHooksPatched then
    local originalGetVisibleOptions = WorldMapOptions.getVisibleOptions
    function WorldMapOptions:getVisibleOptions()
        local result = originalGetVisibleOptions(self)
        for _, hook in ipairs(WorldMapOptions_visibleOptionsHooks) do
            hook(result)
        end
        return result
    end

    local originalSynchUI = WorldMapOptions.synchUI
    function WorldMapOptions:synchUI()
        local visibleOptions = self:getVisibleOptions()
        local boolCount = 0
        for _, opt in ipairs(visibleOptions) do
            if opt:getType() == "boolean" then
                boolCount = boolCount + 1
            end
        end
        if boolCount ~= (self._lastBoolCount or -1) then
            local children = {}
            for _, v in pairs(self:getChildren()) do
                table.insert(children, v)
            end
            for _, child in ipairs(children) do
                self:removeChild(child)
            end
            self:createChildren()
            self._lastBoolCount = boolCount
        end
        originalSynchUI(self)
    end

    WorldMapOptions._visibleOptionsHooksPatched = true
end

------------------------------------------------------------
-- RENDERING (worldToUIX/Y is the same transform KIPN_ZoneAdminMapUI.lua
-- uses, so this lines up pixel-for-pixel with the admin tool's overlay)
------------------------------------------------------------

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)

local function drawZoneLabel(javaObject, api, worldX, worldY, name)
    local sx = PZMath.floor(api:worldToUIX(worldX, worldY))
    local sy = PZMath.floor(api:worldToUIY(worldX, worldY))
    local textW = getTextManager():MeasureStringX(UIFont.Small, name) + 16
    local boxH = math.ceil(FONT_HGT_SMALL * 1.25)
    javaObject:DrawTextureScaledColor(nil, sx - textW / 2, sy + 4, textW, boxH, 0.5, 0.5, 0.5, 0.5)
    javaObject:DrawTextCentre(name, sx, sy + 4 + (boxH - FONT_HGT_SMALL) / 2, 0, 0, 0, 1)
end

-- insetPx nudges every corner toward the rectangle's UI-space center,
-- so a combat-policy outline nests visibly inside the zone-type
-- outline instead of drawing exactly on top of it (mirrors
-- KIPN_ZoneAdminMapUI:drawZoneRect).
local function drawZoneOutline(javaObject, api, geometry, r, g, b, a, insetPx)
    local x1 = api:worldToUIX(geometry.x1, geometry.y1)
    local y1 = api:worldToUIY(geometry.x1, geometry.y1)
    local x2 = api:worldToUIX(geometry.x2, geometry.y1)
    local y2 = api:worldToUIY(geometry.x2, geometry.y1)
    local x3 = api:worldToUIX(geometry.x2, geometry.y2)
    local y3 = api:worldToUIY(geometry.x2, geometry.y2)
    local x4 = api:worldToUIX(geometry.x1, geometry.y2)
    local y4 = api:worldToUIY(geometry.x1, geometry.y2)

    if insetPx and insetPx ~= 0 then
        local cx = (x1 + x2 + x3 + x4) / 4
        local cy = (y1 + y2 + y3 + y4) / 4

        local function nudge(x, y)
            local dx, dy = cx - x, cy - y
            local len = math.sqrt(dx * dx + dy * dy)
            if len < 0.001 then
                return x, y
            end
            return x + (dx / len) * insetPx, y + (dy / len) * insetPx
        end

        x1, y1 = nudge(x1, y1)
        x2, y2 = nudge(x2, y2)
        x3, y3 = nudge(x3, y3)
        x4, y4 = nudge(x4, y4)
    end

    javaObject:DrawLine(nil, x1, y1, x2, y2, 2, r, g, b, a)
    javaObject:DrawLine(nil, x2, y2, x3, y3, 2, r, g, b, a)
    javaObject:DrawLine(nil, x3, y3, x4, y4, 2, r, g, b, a)
    javaObject:DrawLine(nil, x4, y4, x1, y1, 2, r, g, b, a)
end

local function renderZones(mapUI)
    local api = mapUI.mapAPI
    local javaObject = mapUI.javaObject

    for _, zone in ipairs(KIPN.Client.ZoneMapCache.zones) do
        local geometry = zone.geometry
        if type(geometry) == "table" then
            local typeColor = ZONE_TYPE_COLORS[zone.type] or ZONE_TYPE_COLORS.custom
            drawZoneOutline(javaObject, api, geometry, typeColor.r, typeColor.g, typeColor.b, 0.85, 0)

            local midX = (geometry.x1 + geometry.x2) / 2
            local midY = (geometry.y1 + geometry.y2) / 2
            local label = zone.label or ZONE_TYPE_LABELS[zone.type] or zone.type
            drawZoneLabel(javaObject, api, midX, midY, label)

            local policyColor = zone.combatPolicy and COMBAT_POLICY_COLORS[zone.combatPolicy]
            if policyColor then
                drawZoneOutline(javaObject, api, geometry, policyColor.r, policyColor.g, policyColor.b, 0.85, 5)
            end
        end
    end
end

local originalRender = ISWorldMap.render

function ISWorldMap:render()
    originalRender(self)

    if zonesVisible then
        renderZones(self)
    end
end

print("[KIPN] Zone Map Renderer loaded")
