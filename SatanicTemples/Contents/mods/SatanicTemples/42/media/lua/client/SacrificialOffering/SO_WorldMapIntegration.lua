require "ISUI/Maps/ISWorldMap"
require "ISUI/ISContextMenu"
require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_ClientState"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_Sandbox"

local SO = SacrificialOffering
SO.WorldMapIntegration = SO.WorldMapIntegration or {}
local Integration = SO.WorldMapIntegration

local function isAuthorized(player)
    player = player or getPlayer()
    -- Single-player owns its world, exactly as the server's IsAuthorized treats
    -- it; a respawned character need not carry an admin-style role.
    if not isClient() then return true end
    if SO.Sandbox.Boolean("AllowAllPlayersToViewTemples") then
        return true
    end
    local role = player and player:getRole()
    return role and (
        role:hasCapability(Capability.CanSetupNonPVPZone) or
        role:hasCapability(Capability.CanSetupSafehouses))
end

local function drawTemple(map, zone)
    if not zone or not zone.x1 or not zone.y1 or not zone.x2 or not zone.y2 then
        return
    end

    local api = map.mapAPI
    local x1, y1 = api:worldToUIX(zone.x1, zone.y1), api:worldToUIY(zone.x1, zone.y1)
    local x2, y2 = api:worldToUIX(zone.x2, zone.y1), api:worldToUIY(zone.x2, zone.y1)
    local x3, y3 = api:worldToUIX(zone.x2, zone.y2), api:worldToUIY(zone.x2, zone.y2)
    local x4, y4 = api:worldToUIX(zone.x1, zone.y2), api:worldToUIY(zone.x1, zone.y2)
    local texture = Texture:getWhite()
    local thickness = 3
    local r, g, b, a = 0.62, 0.02, 0.02, 0.95

    map.javaObject:DrawLine(texture, x1, y1, x2, y2, thickness, r, g, b, a)
    map.javaObject:DrawLine(texture, x2, y2, x3, y3, thickness, r, g, b, a)
    map.javaObject:DrawLine(texture, x3, y3, x4, y4, thickness, r, g, b, a)
    map.javaObject:DrawLine(texture, x4, y4, x1, y1, thickness, r, g, b, a)

    local centerX = api:worldToUIX((zone.x1 + zone.x2) / 2, (zone.y1 + zone.y2) / 2)
    local centerY = api:worldToUIY((zone.x1 + zone.x2) / 2, (zone.y1 + zone.y2) / 2)
    map:drawRect(centerX - 4, centerY - 4, 9, 9, 0.95, r, g, b)
    map:drawRectBorder(centerX - 5, centerY - 5, 11, 11, 1.0, 0.12, 0.0, 0.0)

    local name = tostring(zone.name or ("Satanic Temple " .. tostring(zone.id or "")))
    map:drawText(name, centerX + 9, centerY - 7, 0.45, 0.0, 0.0, 1.0, UIFont.Small)
end

-- Kept on the module rather than the map: the world map is rebuilt when a
-- player respawns, which would silently switch the overlay back off.
Integration.Showing = Integration.Showing or false

function Integration.Toggle(map)
    Integration.Showing = not Integration.Showing
    if Integration.Showing then
        SO.Client.RequestZones()
    end
end

function Integration.Render(map)
    if not Integration.Showing or not isAuthorized(map.character) then
        return
    end
    for _, zone in ipairs(SO.Client.Zones or {}) do
        drawTemple(map, zone)
    end
end

if not Integration.Patched then
    Integration.Patched = true

    local oldPrerender = ISWorldMap.prerender
    function ISWorldMap:prerender()
        oldPrerender(self)
        Integration.Render(self)
    end

    local oldOnRightMouseUp = ISWorldMap.onRightMouseUp
    function ISWorldMap:onRightMouseUp(x, y)
        -- Vanilla builds a context menu here but neither returns it nor stores it
        -- on a reachable field. Briefly shadow the factory to capture it, and
        -- always restore the factory afterward -- even if the wrapped handler
        -- raises -- so a failure can never leave the global swapped.
        local capturedMenu
        local realGet = ISContextMenu.get
        local shadowing = type(realGet) == "function"
        if shadowing then
            ISContextMenu.get = function(...)
                capturedMenu = realGet(...)
                return capturedMenu
            end
        end
        local ok, err = pcall(oldOnRightMouseUp, self, x, y)
        if shadowing then ISContextMenu.get = realGet end
        if not ok then error(err) end

        if not isAuthorized(self.character) then return end
        -- Vanilla returns early for non-admin clients without building a menu, so
        -- create one when the sandbox flag authorizes this player.
        local context = capturedMenu
        if not context then
            context = ISContextMenu.get(self.playerNum or 0,
                x + self:getAbsoluteX(), y + self:getAbsoluteY())
        end
        if context then
            context:addOption(getText("IGUI_SO_ViewSatanicTemples"), self, Integration.Toggle)
        end
    end
end