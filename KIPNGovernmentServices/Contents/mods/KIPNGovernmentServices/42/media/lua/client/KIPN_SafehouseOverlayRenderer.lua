-- KIPN_SafehouseOverlayRenderer.lua
--
-- Administrator-only "see every claim" overlay for the vanilla World
-- Map (F11). Renders two layers from one admin snapshot: Safehouse
-- (property) claims and Excavation claims. Independent of
-- KIPN_ZoneMapRenderer.lua's zone overlay and of the player-facing
-- KIPN_ExcavationBoundaryOverlay.lua (owner-scoped in-world highlights)
-- -- this file never reads or writes their state.
--
-- Data flow: server pushes a full snapshot via the "SafehouseOverlaySync"
-- event (KIPN_SafehouseService.lua, admin-gated) whenever a Safehouse or
-- Excavation claim changes, and again on demand via
-- "RequestSafehouseOverlaySnapshot" when this admin enables the layer.
-- The client always replaces its cache wholesale from the latest
-- snapshot -- never a delta, never a local claim scan.
--
-- Vanilla's ISWorldMap:onRightMouseUp() builds its debug/admin menu
-- via ISContextMenu.get(), which CLEARS the menu on every call -- so
-- this file calls the original handler first, then appends to the SAME
-- live menu via the bare getPlayerContextMenu() global instead of
-- calling .get() again.

require "KIPN_Shared"
require "KIPN_AdminAccess"
require "KIPN_SafehouseOverlayPreference"
require "ISUI/Maps/ISWorldMap"

KIPN = KIPN or {}
KIPN.Client = KIPN.Client or {}

local MODULE_NAME = "KIPN"

local FILL_COLOR = { r = 0.95, g = 0.25, b = 0.35 }
local EXCAVATION_FILL_COLOR = { r = 0.20, g = 0.85, b = 0.95 }

local function log(message)
    print("[KIPN SAFEHOUSE OVERLAY] " .. tostring(message))
end

------------------------------------------------------------
-- CACHE (populated from server; preserved across file reloads)
------------------------------------------------------------

if not KIPN.Client.SafehouseOverlayCache then
    KIPN.Client.SafehouseOverlayCache = { safehouses = {}, excavations = {} }
end

KIPN.Client.SafehouseOverlayCache.excavations =
    KIPN.Client.SafehouseOverlayCache.excavations or {}

local safehouseOverlayVisible = false

local function isLocalPlayerMapAdmin()
    return KIPN.Client.AdminAccess and KIPN.Client.AdminAccess.IsAdmin(0) == true
end

local function requestOverlaySnapshot()
    local player = getSpecificPlayer(0)
    if not player then
        return
    end

    sendClientCommand(player, MODULE_NAME, "RequestSafehouseOverlaySnapshot", {})
end

------------------------------------------------------------
-- SERVER SYNC
------------------------------------------------------------

local function onServerCommand(module, command, args)
    if module ~= MODULE_NAME
        or command ~= KIPN.Shared.Commands.SERVER_RESPONSE
        or not args
        or args.event ~= "SafehouseOverlaySync" then
        return
    end

    local data = args.data
    local safehouses = (type(data) == "table" and data.safehouses) or {}
    local excavations = (type(data) == "table" and data.excavations) or {}

    KIPN.Client.SafehouseOverlayCache.safehouses = safehouses
    KIPN.Client.SafehouseOverlayCache.excavations = excavations

    log("Received snapshot | safehouses=" .. tostring(#safehouses) ..
        " | excavations=" .. tostring(#excavations))
end

Events.OnServerCommand.Add(onServerCommand)

------------------------------------------------------------
-- RESTORE PREFERENCE ON CONNECT/RECONNECT
------------------------------------------------------------

local function restorePreferenceIfAdmin(accessLevel)
    if accessLevel ~= "ADMIN" then
        return
    end

    if KIPN.Client.SafehouseOverlayPreference.Load() then
        safehouseOverlayVisible = true
        requestOverlaySnapshot()
        log("Restored enabled overlay preference after (re)connect.")
    end
end

if KIPN.Client.AdminAccess and KIPN.Client.AdminAccess.AddListener then
    KIPN.Client.AdminAccess.AddListener(restorePreferenceIfAdmin)
end

------------------------------------------------------------
-- RENDERING (mirrors KIPN_ZoneMapRenderer.lua's draw helpers so the
-- two overlays line up pixel-for-pixel)
------------------------------------------------------------

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)

local function drawSafehouseLabel(javaObject, api, worldX, worldY, text)
    local sx = PZMath.floor(api:worldToUIX(worldX, worldY))
    local sy = PZMath.floor(api:worldToUIY(worldX, worldY))
    local textW = getTextManager():MeasureStringX(UIFont.Small, text) + 16
    local boxH = math.ceil(FONT_HGT_SMALL * 1.25)
    javaObject:DrawTextureScaledColor(nil, sx - textW / 2, sy + 4, textW, boxH, 0.5, 0.5, 0.5, 0.5)
    javaObject:DrawTextCentre(text, sx, sy + 4 + (boxH - FONT_HGT_SMALL) / 2, 1, 1, 1, 1)
end

local function drawSafehouseRect(javaObject, api, x1, y1, x2, y2, r, g, b, outlineA, fillA)
    local ux1 = api:worldToUIX(x1, y1)
    local uy1 = api:worldToUIY(x1, y1)
    local ux2 = api:worldToUIX(x2, y1)
    local uy2 = api:worldToUIY(x2, y1)
    local ux3 = api:worldToUIX(x2, y2)
    local uy3 = api:worldToUIY(x2, y2)
    local ux4 = api:worldToUIX(x1, y2)
    local uy4 = api:worldToUIY(x1, y2)

    local minX = math.min(ux1, ux2, ux3, ux4)
    local maxX = math.max(ux1, ux2, ux3, ux4)
    local minY = math.min(uy1, uy2, uy3, uy4)
    local maxY = math.max(uy1, uy2, uy3, uy4)

    javaObject:DrawTextureScaledColor(nil, minX, minY, maxX - minX, maxY - minY, r, g, b, fillA)

    javaObject:DrawLine(nil, ux1, uy1, ux2, uy2, 2, r, g, b, outlineA)
    javaObject:DrawLine(nil, ux2, uy2, ux3, uy3, 2, r, g, b, outlineA)
    javaObject:DrawLine(nil, ux3, uy3, ux4, uy4, 2, r, g, b, outlineA)
    javaObject:DrawLine(nil, ux4, uy4, ux1, uy1, 2, r, g, b, outlineA)
end

local function renderClaimList(javaObject, api, claims, color, fallbackLabel)
    for _, claim in ipairs(claims or {}) do
        local x1 = tonumber(claim.x1)
        local y1 = tonumber(claim.y1)
        local x2 = tonumber(claim.x2)
        local y2 = tonumber(claim.y2)

        if x1 and y1 and x2 and y2 then
            drawSafehouseRect(
                javaObject, api, x1, y1, x2, y2,
                color.r, color.g, color.b, 0.9, 0.18
            )

            local midX = (x1 + x2) / 2
            local midY = (y1 + y2) / 2
            local label = claim.ownerUsername or claim.ownerSteamId or claim.id or fallbackLabel
            drawSafehouseLabel(javaObject, api, midX, midY, tostring(label))
        end
    end
end

local function renderSafehouses(mapUI)
    local api = mapUI.mapAPI
    local javaObject = mapUI.javaObject

    renderClaimList(
        javaObject, api,
        KIPN.Client.SafehouseOverlayCache.safehouses,
        FILL_COLOR, "Safehouse"
    )
    renderClaimList(
        javaObject, api,
        KIPN.Client.SafehouseOverlayCache.excavations,
        EXCAVATION_FILL_COLOR, "Excavation"
    )
end

local originalRender = ISWorldMap.render

function ISWorldMap:render()
    originalRender(self)

    if safehouseOverlayVisible and isLocalPlayerMapAdmin() then
        renderSafehouses(self)
    end
end

------------------------------------------------------------
-- RIGHT-CLICK CONTEXT MENU
--
-- ISContextMenu.get() clears the menu on every call, so the KIPN
-- option is appended to the SAME live menu via getPlayerContextMenu()
-- (no re-.get()) when the original handler already built one, and a
-- fresh menu is opened via .get() only when the original returned
-- nothing.
------------------------------------------------------------

local function toggleSafehouseOverlay()
    safehouseOverlayVisible = not safehouseOverlayVisible

    KIPN.Client.SafehouseOverlayPreference.Save(safehouseOverlayVisible)

    if safehouseOverlayVisible then
        requestOverlaySnapshot()
    else
        KIPN.Client.SafehouseOverlayCache.safehouses = {}
        KIPN.Client.SafehouseOverlayCache.excavations = {}
    end

    log("Toggled overlay | visible=" .. tostring(safehouseOverlayVisible))
end

local originalOnRightMouseUp = ISWorldMap.onRightMouseUp

function ISWorldMap:onRightMouseUp(x, y)
    local handled = originalOnRightMouseUp(self, x, y)

    if not isLocalPlayerMapAdmin() then
        return handled
    end

    -- "handled" alone isn't a reliable signal that a real ISContextMenu
    -- was opened -- self.symbolsUI:onRightMouseUpMap() can also return
    -- true (map symbol click) without ever touching ISContextMenu. Check
    -- the player's context-menu singleton's actual visibility instead:
    -- if vanilla's own onRightMouseUp built one, it's already visible;
    -- if not, open a fresh one via .get() so the option still appears
    -- on every right-click, matching "anywhere on the map".
    local playerNum = self.playerNum or 0
    local context = getPlayerContextMenu(playerNum)

    if not (context and context:isVisible()) then
        context = ISContextMenu.get(playerNum, x + self:getAbsoluteX(), y + self:getAbsoluteY())
    end

    if not context then
        return handled
    end

    local label = safehouseOverlayVisible
        and "Hide KIPN Claim Overlay"
        or "Show KIPN Claim Overlay"

    context:addOption(label, nil, toggleSafehouseOverlay)

    return true
end

print("[KIPN] Safehouse Overlay Renderer loaded")
