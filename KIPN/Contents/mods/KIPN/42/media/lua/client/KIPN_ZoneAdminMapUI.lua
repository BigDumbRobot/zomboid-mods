-- KIPN_ZoneAdminMapUI.lua
--
-- Standalone map-overlay corner picker for the KIPN Zone Admin tool.
--
-- This wraps the game's own UIWorldMap Java object and its mapAPI --
-- the exact renderer/coordinate transform behind Project Zomboid's
-- real World Map screen (see client/ISUI/Maps/ISWorldMap.lua in the
-- base game). It is NOT a hand-drawn reimplementation: it's the same
-- map textures and the same worldToUIX/Y <-> uiToWorldX/Y transform
-- the base game uses, just without the vanilla map's extra chrome
-- (symbols, print media, stash maps, forget-map) that this admin
-- tool has no use for. Panning, zooming, and the world coordinates
-- returned by a click are therefore 1:1 with the real map.
--
-- CONTROLS (mirrors the vanilla world map):
--   Left-click + drag    -> pan
--   Mouse wheel          -> zoom
--   +/- buttons           -> zoom
--   C                    -> center on player
--   Left-click (no drag) -> place next corner
--   Esc / Cancel button  -> close without picking corners
--
-- USAGE:
--   KIPN_ZoneAdminMapUI.Open({
--       onConfirm     = function(cornerA, cornerB) ... end, -- corners are {x,y,z} world coords
--       onUpdateExisting = function(zoneId, label, geometry) ... end, -- optional; enables editing
--       onClose       = function() ... end,                 -- always fires when the panel closes
--       existingZones = { {id=,type=,geometry=,metadata=,combatPolicy=,active=}, ... }, -- optional
--                                                                             -- as context while
--                                                                             -- picking a new zone
--                                                                             -- (permission zones);
--                                                                             -- or, for event hotspots,
--                                                                             -- entries tagged kind =
--                                                                             -- "hotspot" with a
--                                                                             -- roundNumber instead of
--                                                                             -- combatPolicy
--   })

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISComboBox"
require "ISUI/ISTextEntryBox"
require "ISUI/Maps/ISMapDefinitions"

KIPN = KIPN or {}
KIPN.Client = KIPN.Client or {}

KIPN_ZoneAdminMapUI = ISPanel:derive("KIPN_ZoneAdminMapUI")

local DRAG_THRESHOLD = 4
local DEFAULT_ZOOM = 18.0

------------------------------------------------------------
-- EXISTING-ZONE OVERLAY COLORS
--
-- Permission zone type gets a solid outline. A combat policy
-- (independent of zone type -- see KIPN_WorldRegistry.lua) gets
-- its own inset outline drawn on top, so an admin can see at a
-- glance where a PVE/Melee combat zone overlaps a permission
-- zone. The ambient default (no combat zone) is always full PvP
-- damage, so there's nothing to draw for that case.
------------------------------------------------------------

local ZONE_TYPE_COLORS = {
    government  = { r = 0.3, g = 0.55, b = 1.0 },
    dealership  = { r = 1.0, g = 0.6,  b = 0.2 },
    custom      = { r = 0.6, g = 0.6,  b = 0.6 },
    do_not_claim = { r = 0.5, g = 0.0,  b = 0.0 },
}

local COMBAT_POLICY_COLORS = {
    PVE       = { r = 0.4, g = 0.9,  b = 0.9 },
    MELEE_PVP = { r = 1.0, g = 0.85, b = 0.2 },
}

------------------------------------------------------------
-- EXISTING-HOTSPOT OVERLAY COLORS
--
-- Event Scenario hotspots (KIPN_EventScenarioAdminUI.lua) reuse this
-- same picker with existingZones entries tagged kind = "hotspot"
-- instead of a permission-zone type, so they're colored from this
-- separate table rather than ZONE_TYPE_COLORS. Hotspot type gets the
-- outer ring; if the hotspot also carries a roundNumber (KOTH's
-- HILL_LOCATION hotspots, one per round), that round gets its own
-- inset ring, exactly like COMBAT_POLICY_COLORS nests inside a
-- permission zone's outline above.
------------------------------------------------------------

local HOTSPOT_TYPE_COLORS = {
    ZOMBIE_SPAWN       = { r = 0.9,  g = 0.15, b = 0.15 },
    CAPTURE_ITEM       = { r = 1.0,  g = 0.75, b = 0.1  },
    DELIVERY_POINT     = { r = 0.2,  g = 0.9,  b = 0.45 },
    RESCUE_OBJECTIVE   = { r = 0.95, g = 0.5,  b = 0.85 },
    OBJECTIVE_LOCATION = { r = 0.3,  g = 0.55, b = 1.0  },
    PLAYER_SPAWN       = { r = 0.4,  g = 0.9,  b = 0.9  },
    TEAM_SPAWN         = { r = 0.6,  g = 0.4,  b = 1.0  },
    HILL_LOCATION      = { r = 1.0,  g = 0.6,  b = 0.2  },
    NARRATIVE_LOCATION = { r = 0.75, g = 0.75, b = 0.2  },
    EXTRACTION_POINT   = { r = 0.2,  g = 0.75, b = 1.0  },
}

local ROUND_COLORS = {
    { r = 1.0,  g = 1.0,  b = 1.0  },
    { r = 1.0,  g = 0.3,  b = 0.3  },
    { r = 0.3,  g = 1.0,  b = 0.3  },
    { r = 0.3,  g = 0.5,  b = 1.0  },
    { r = 1.0,  g = 0.8,  b = 0.2  },
    { r = 1.0,  g = 0.3,  b = 1.0  },
    { r = 0.2,  g = 1.0,  b = 1.0  },
    { r = 1.0,  g = 0.55, b = 0.15 },
    { r = 0.65, g = 0.4,  b = 1.0  },
    { r = 0.5,  g = 0.5,  b = 0.5  },
}

------------------------------------------------------------
-- SINGLETON ACCESS
------------------------------------------------------------

function KIPN_ZoneAdminMapUI.Open(callbacks)
    KIPN_ZoneAdminMapUI.Close()

    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()

    local panel = KIPN_ZoneAdminMapUI:new(0, 0, screenW, screenH)
    panel.callbacks = callbacks or {}
    panel.existingZones = panel.callbacks.existingZones or {}

    panel:initialise()
    panel:instantiate()
    panel:addToUIManager()
    panel:bringToTop()

    KIPN_ZoneAdminMapUI.instance = panel
end

function KIPN_ZoneAdminMapUI.Close()
    if KIPN_ZoneAdminMapUI.instance then
        KIPN_ZoneAdminMapUI.instance:close()
    end
end

------------------------------------------------------------
-- CONSTRUCTION
------------------------------------------------------------

function KIPN_ZoneAdminMapUI:new(x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o:noBackground()
    o.moveWithMouse = false

    o.cornerA = nil
    o.cornerB = nil
    o.previewWorldX = nil
    o.previewWorldY = nil

    -- "draw" creates new bounds. "edit" displays an existing zone
    -- without consuming map clicks, and "editResize" redraws that
    -- zone's two XY corners while preserving its original Z range.
    o.mode = "draw"
    o.selectedExistingZone = nil

    o.dragging = false
    o.dragMoved = false

    return o
end

------------------------------------------------------------
-- MAP SETUP (mirrors ISWorldMap:instantiate / initDataAndStyle)
------------------------------------------------------------

function KIPN_ZoneAdminMapUI:instantiate()
    self.javaObject = UIWorldMap.new(self)
    self.javaObject:setX(self.x)
    self.javaObject:setY(self.y)
    self.javaObject:setWidth(self.width)
    self.javaObject:setHeight(self.height)
    self.javaObject:setAnchorLeft(true)
    self.javaObject:setAnchorRight(true)
    self.javaObject:setAnchorTop(true)
    self.javaObject:setAnchorBottom(true)
    self.javaObject:setWantKeyEvents(true)

    self.mapAPI = self.javaObject:getAPIv3()
    self.mapAPI:setMapItem(MapItem.getSingleton())
    self.mapAPI:setMaxZoom(24.0)
    self.mapAPI:setBoolean("WorldBounds", false)

    -- Mirrors ISWorldMap.ShowWorldMap()'s setShowPlayers/setShowRemotePlayers/
    -- setShowPlayerNames -- this standalone UIWorldMap instance doesn't get
    -- those defaults for free, so without these the admin's red dot + name
    -- never appears while drawing a zone/hotspot.
    self.mapAPI:setBoolean("Players", true)
    self.mapAPI:setBoolean("RemotePlayers", true)
    self.mapAPI:setBoolean("PlayerNames", true)

    self:createChildren()

    MapUtils.initDefaultMapData(self)
    self.mapAPI:setBoundsFromWorld()
    MapUtils.initDefaultStreetData(self)
    MapUtils.initDefaultStyleV3(self)
    MapUtils.overlayPaper(self)

    -- Admins need to see the whole map to zone areas they may not
    -- have personally explored, so ignore fog-of-war visited state.
    self.mapAPI:setBoolean("HideUnvisited", false)
    self.mapAPI:setBoolean("Isometric", true)

    self.mapAPI:resetView()

    local player = getSpecificPlayer(0)
    if player then
        self.mapAPI:centerOn(player:getX(), player:getY())
    end
    self.mapAPI:setZoom(DEFAULT_ZOOM)
end

------------------------------------------------------------
-- CHILDREN
------------------------------------------------------------

function KIPN_ZoneAdminMapUI:createChildren()
    local pad = 10
    local btnSize = 32

    self.zoomInButton = ISButton:new(pad, pad, btnSize, btnSize, "+", self, KIPN_ZoneAdminMapUI.onZoomIn)
    self:addChild(self.zoomInButton)

    self.zoomOutButton = ISButton:new(pad, pad + btnSize + 6, btnSize, btnSize, "-", self, KIPN_ZoneAdminMapUI.onZoomOut)
    self:addChild(self.zoomOutButton)

    self.centerButton = ISButton:new(pad, pad + (btnSize + 6) * 2, btnSize, btnSize, "C", self, KIPN_ZoneAdminMapUI.onCenterOnPlayer)
    self:addChild(self.centerButton)

    local panelWidth = 280
    local panelX = self.width - panelWidth - pad

    self.titleLabel = ISLabel:new(panelX, pad, 24, "KIPN Zone Admin: Draw Zone", 1, 1, 1, 1, UIFont.Medium, true)
    self:addChild(self.titleLabel)

    self.cornerALabel = ISLabel:new(panelX, pad + 28, 24, "Corner A: not set", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.cornerALabel)

    self.cornerBLabel = ISLabel:new(panelX, pad + 52, 24, "Corner B: not set", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.cornerBLabel)

    self.hintLabel = ISLabel:new(panelX, pad + 76, 24, "Click the map to place Corner A", 0.7, 0.9, 1, 1, UIFont.Small, true)
    self:addChild(self.hintLabel)

    local btnW, btnH = 134, 28

    self.resetButton = ISButton:new(panelX, pad + 108, btnW, btnH, "Reset Points", self, KIPN_ZoneAdminMapUI.onResetPoints)
    self:addChild(self.resetButton)

    self.confirmButton = ISButton:new(panelX + btnW + 12, pad + 108, btnW, btnH, "Use Corners", self, KIPN_ZoneAdminMapUI.onConfirm)
    self.confirmButton:setEnable(false)
    self:addChild(self.confirmButton)

    self.cancelButton = ISButton:new(panelX, pad + 108 + btnH + 8, (btnW * 2) + 12, btnH, "Cancel", self, KIPN_ZoneAdminMapUI.onCancel)
    self:addChild(self.cancelButton)

    --------------------------------------------------------
    -- EXISTING-ZONE EDITOR
    --
    -- Only callers that provide onUpdateExisting can mutate zones.
    -- EventScenarioAdminUI also uses this map picker, but deliberately
    -- remains a draw-only workflow because it doesn't provide that
    -- callback.
    --------------------------------------------------------

    if type(self.callbacks.onUpdateExisting) == "function" then
        local editY = pad + 108 + btnH + 8 + btnH + 8

        self.editModeButton = ISButton:new(panelX, editY, (btnW * 2) + 12, btnH, "Edit Existing Zone", self, KIPN_ZoneAdminMapUI.onToggleEditMode)
        self:addChild(self.editModeButton)

        self.existingZoneCombo = ISComboBox:new(panelX, editY + btnH + 8, (btnW * 2) + 12, btnH, self, KIPN_ZoneAdminMapUI.onExistingZoneChanged)
        self:addChild(self.existingZoneCombo)

        for _, zone in ipairs(self.existingZones) do
            if zone.active ~= false and type(zone.geometry) == "table" then
                local metadataLabel = zone.metadata and zone.metadata.label
                local displayLabel = metadataLabel or zone.label or zone.type or "Zone"
                self.existingZoneCombo:addOptionWithData(
                    string.format("%s [%s]", tostring(displayLabel), tostring(zone.id)),
                    zone
                )
            end
        end

        self.zoneNameLabel = ISLabel:new(panelX, editY + btnH + 8 + btnH + 6, 20, "Zone Name:", 1, 1, 1, 1, UIFont.Small, true)
        self:addChild(self.zoneNameLabel)

        self.zoneNameEntry = ISTextEntryBox:new("", panelX, editY + btnH + 8 + btnH + 26, (btnW * 2) + 12, btnH)
        self.zoneNameEntry:initialise()
        self.zoneNameEntry:instantiate()
        self.zoneNameEntry:setMaxTextLength(128)
        self:addChild(self.zoneNameEntry)

        self.resizeExistingButton = ISButton:new(panelX, editY + btnH + 8 + btnH + 26 + btnH + 8, btnW, btnH, "Redraw Bounds", self, KIPN_ZoneAdminMapUI.onResizeExisting)
        self:addChild(self.resizeExistingButton)

        self.saveExistingButton = ISButton:new(panelX + btnW + 12, editY + btnH + 8 + btnH + 26 + btnH + 8, btnW, btnH, "Save Changes", self, KIPN_ZoneAdminMapUI.onSaveExisting)
        self:addChild(self.saveExistingButton)

        self:setEditControlsVisible(false)
        self.editModeButton:setEnable(#self.existingZoneCombo.options > 0)
    end
end

function KIPN_ZoneAdminMapUI:setEditControlsVisible(visible)
    if self.existingZoneCombo then self.existingZoneCombo:setVisible(visible) end
    if self.zoneNameLabel then self.zoneNameLabel:setVisible(visible) end
    if self.zoneNameEntry then self.zoneNameEntry:setVisible(visible) end
    if self.resizeExistingButton then self.resizeExistingButton:setVisible(visible) end
    if self.saveExistingButton then self.saveExistingButton:setVisible(visible) end
end

function KIPN_ZoneAdminMapUI:setDrawControlsVisible(visible)
    self.resetButton:setVisible(visible)
    self.confirmButton:setVisible(visible)
end

function KIPN_ZoneAdminMapUI:loadSelectedExistingZone(zone)
    self.selectedExistingZone = zone

    if not zone or type(zone.geometry) ~= "table" then
        self.cornerA = nil
        self.cornerB = nil
        self.saveExistingButton:setEnable(false)
        self.resizeExistingButton:setEnable(false)
        return
    end

    local geometry = zone.geometry
    self.cornerA = { x = geometry.x1, y = geometry.y1, z = geometry.z1 or 0 }
    self.cornerB = { x = geometry.x2, y = geometry.y2, z = geometry.z2 or geometry.z1 or 0 }
    self.previewWorldX = nil
    self.previewWorldY = nil

    local label = (zone.metadata and zone.metadata.label) or zone.label or ""
    self.zoneNameEntry:setText(tostring(label))
    self.cornerALabel:setName(string.format("Corner A: (%d, %d, %d)", self.cornerA.x, self.cornerA.y, self.cornerA.z))
    self.cornerBLabel:setName(string.format("Corner B: (%d, %d, %d)", self.cornerB.x, self.cornerB.y, self.cornerB.z))
    self.hintLabel:setName("Rename, redraw bounds, or save this zone")
    self.saveExistingButton:setEnable(true)
    self.resizeExistingButton:setEnable(true)
end

------------------------------------------------------------
-- POINT PLACEMENT
------------------------------------------------------------

function KIPN_ZoneAdminMapUI:placePoint(x, y)
    if self.mode == "edit" then
        return
    end

    local worldX = self.mapAPI:uiToWorldX(x, y)
    local worldY = self.mapAPI:uiToWorldY(x, y)

    local player = getSpecificPlayer(0)
    local z = (player and player:getZ()) or 0

    if self.mode == "editResize" and self.selectedExistingZone then
        local geometry = self.selectedExistingZone.geometry or {}
        z = self.cornerA and (geometry.z2 or geometry.z1 or 0) or (geometry.z1 or 0)
    end

    local point = {
        x = math.floor(worldX),
        y = math.floor(worldY),
        z = z,
    }

    if not self.cornerA then
        self.cornerA = point
        self.cornerALabel:setName(string.format("Corner A: (%d, %d, %d)", point.x, point.y, point.z))
        self.hintLabel:setName("Click the map to place Corner B")
    elseif not self.cornerB then
        self.cornerB = point
        self.cornerBLabel:setName(string.format("Corner B: (%d, %d, %d)", point.x, point.y, point.z))
        self.hintLabel:setName("Corners set -- confirm or reset")
        self.confirmButton:setEnable(true)

        if self.mode == "editResize" then
            self.hintLabel:setName("New bounds set -- save changes or redraw")
            self.saveExistingButton:setEnable(true)
        end
    else
        -- Both corners already set; start a fresh rectangle.
        self.cornerA = point
        self.cornerB = nil
        self.previewWorldX = nil
        self.previewWorldY = nil
        self.cornerALabel:setName(string.format("Corner A: (%d, %d, %d)", point.x, point.y, point.z))
        self.cornerBLabel:setName("Corner B: not set")
        self.hintLabel:setName("Click the map to place Corner B")
        self.confirmButton:setEnable(false)

        if self.mode == "editResize" then
            self.saveExistingButton:setEnable(false)
        end
    end
end

------------------------------------------------------------
-- MOUSE / KEY HANDLING (mirrors ISWorldMap's pan/zoom exactly)
------------------------------------------------------------

function KIPN_ZoneAdminMapUI:onMouseDown(x, y)
    self.dragging = true
    self.dragMoved = false
    self.dragStartX = x
    self.dragStartY = y
    self.dragStartCX = self.mapAPI:getCenterWorldX()
    self.dragStartCY = self.mapAPI:getCenterWorldY()
    self.dragStartZoomF = self.mapAPI:getZoomF()
    self.dragStartWorldX = self.mapAPI:uiToWorldX(x, y)
    self.dragStartWorldY = self.mapAPI:uiToWorldY(x, y)
    return true
end

function KIPN_ZoneAdminMapUI:onMouseMove(dx, dy)
    local mouseX = self:getMouseX()
    local mouseY = self:getMouseY()

    if self.dragging then
        if not self.dragMoved and math.abs(mouseX - self.dragStartX) <= DRAG_THRESHOLD and math.abs(mouseY - self.dragStartY) <= DRAG_THRESHOLD then
            return true
        end
        self.dragMoved = true
        local worldX = self.mapAPI:uiToWorldX(mouseX, mouseY, self.dragStartZoomF, self.dragStartCX, self.dragStartCY)
        local worldY = self.mapAPI:uiToWorldY(mouseX, mouseY, self.dragStartZoomF, self.dragStartCX, self.dragStartCY)
        self.mapAPI:centerOn(self.dragStartCX + self.dragStartWorldX - worldX, self.dragStartCY + self.dragStartWorldY - worldY)
    elseif self.cornerA and not self.cornerB then
        self.previewWorldX = self.mapAPI:uiToWorldX(mouseX, mouseY)
        self.previewWorldY = self.mapAPI:uiToWorldY(mouseX, mouseY)
    end

    return true
end

function KIPN_ZoneAdminMapUI:onMouseMoveOutside(dx, dy)
    return self:onMouseMove(dx, dy)
end

function KIPN_ZoneAdminMapUI:onMouseUp(x, y)
    local wasDragging = self.dragging
    local moved = self.dragMoved
    self.dragging = false
    self.dragMoved = false

    if wasDragging and not moved then
        self:placePoint(x, y)
    end

    return true
end

function KIPN_ZoneAdminMapUI:onMouseUpOutside(x, y)
    self.dragging = false
    self.dragMoved = false
    return true
end

function KIPN_ZoneAdminMapUI:onMouseWheel(del)
    self.mapAPI:zoomAt(self:getMouseX(), self:getMouseY(), del)
    return true
end

function KIPN_ZoneAdminMapUI:isKeyConsumed(key)
    return key == Keyboard.KEY_ESCAPE or key == Keyboard.KEY_C
end

function KIPN_ZoneAdminMapUI:onKeyRelease(key)
    if key == Keyboard.KEY_ESCAPE then
        self:onCancel()
    elseif key == Keyboard.KEY_C then
        self:onCenterOnPlayer()
    end
end

------------------------------------------------------------
-- BUTTON HANDLERS
------------------------------------------------------------

function KIPN_ZoneAdminMapUI:onZoomIn()
    self.mapAPI:zoomAt(self.width / 2, self.height / 2, 2)
end

function KIPN_ZoneAdminMapUI:onZoomOut()
    self.mapAPI:zoomAt(self.width / 2, self.height / 2, -2)
end

function KIPN_ZoneAdminMapUI:onCenterOnPlayer()
    local player = getSpecificPlayer(0)
    if player then
        self.mapAPI:centerOn(player:getX(), player:getY())
    end
end

function KIPN_ZoneAdminMapUI:onResetPoints()
    if self.mode == "edit" or self.mode == "editResize" then
        self.mode = "edit"
        self:loadSelectedExistingZone(self.selectedExistingZone)
        return
    end

    self.cornerA = nil
    self.cornerB = nil
    self.previewWorldX = nil
    self.previewWorldY = nil
    self.cornerALabel:setName("Corner A: not set")
    self.cornerBLabel:setName("Corner B: not set")
    self.hintLabel:setName("Click the map to place Corner A")
    self.confirmButton:setEnable(false)
end

function KIPN_ZoneAdminMapUI:onConfirm()
    if not self.cornerA or not self.cornerB then
        return
    end

    local onConfirm = self.callbacks.onConfirm
    local cornerA, cornerB = self.cornerA, self.cornerB

    self:close()

    if onConfirm then
        onConfirm(cornerA, cornerB)
    end
end

function KIPN_ZoneAdminMapUI:onToggleEditMode()
    if self.mode == "edit" or self.mode == "editResize" then
        self.mode = "draw"
        self.selectedExistingZone = nil
        self.editModeButton:setTitle("Edit Existing Zone")
        self.titleLabel:setName("KIPN Zone Admin: Draw Zone")
        self:setEditControlsVisible(false)
        self:setDrawControlsVisible(true)
        self:onResetPoints()
        return
    end

    if not self.existingZoneCombo or #self.existingZoneCombo.options == 0 then
        return
    end

    self.mode = "edit"
    self.editModeButton:setTitle("Draw New Zone")
    self.titleLabel:setName("KIPN Zone Admin: Edit Zone")
    self:setDrawControlsVisible(false)
    self:setEditControlsVisible(true)
    self.existingZoneCombo:setSelected(1)
    self:onExistingZoneChanged()
end

function KIPN_ZoneAdminMapUI:onExistingZoneChanged()
    local selected = self.existingZoneCombo.options[self.existingZoneCombo.selected]
    self.mode = "edit"
    self:loadSelectedExistingZone(selected and selected.data or nil)
end

function KIPN_ZoneAdminMapUI:onResizeExisting()
    if not self.selectedExistingZone then
        return
    end

    self.mode = "editResize"
    self.cornerA = nil
    self.cornerB = nil
    self.previewWorldX = nil
    self.previewWorldY = nil
    self.cornerALabel:setName("Corner A: not set")
    self.cornerBLabel:setName("Corner B: not set")
    self.hintLabel:setName("Click the map to place the new Corner A")
    self.saveExistingButton:setEnable(false)
end

function KIPN_ZoneAdminMapUI:onSaveExisting()
    if not self.selectedExistingZone or not self.cornerA or not self.cornerB then
        return
    end

    local callback = self.callbacks.onUpdateExisting
    local zoneId = self.selectedExistingZone.id
    local label = self.zoneNameEntry:getText() or ""
    local geometry = {
        x1 = self.cornerA.x,
        y1 = self.cornerA.y,
        z1 = self.cornerA.z,
        x2 = self.cornerB.x,
        y2 = self.cornerB.y,
        z2 = self.cornerB.z,
    }

    self:close()
    callback(zoneId, label, geometry)
end

function KIPN_ZoneAdminMapUI:onCancel()
    self:close()
end

------------------------------------------------------------
-- RENDER (rectangle overlay uses the same worldToUIX/Y transform
-- ISWorldMap:drawMapRect uses, so it lines up with the real map
-- pixel-for-pixel at any zoom/pan)
------------------------------------------------------------

function KIPN_ZoneAdminMapUI:drawZoneRect(a, b, r, g, blue, alpha, insetPx, thickness)
    local x1 = self.mapAPI:worldToUIX(a.x, a.y)
    local y1 = self.mapAPI:worldToUIY(a.x, a.y)
    local x2 = self.mapAPI:worldToUIX(b.x, a.y)
    local y2 = self.mapAPI:worldToUIY(b.x, a.y)
    local x3 = self.mapAPI:worldToUIX(b.x, b.y)
    local y3 = self.mapAPI:worldToUIY(b.x, b.y)
    local x4 = self.mapAPI:worldToUIX(a.x, b.y)
    local y4 = self.mapAPI:worldToUIY(a.x, b.y)

    if insetPx and insetPx ~= 0 then
        -- Nudge each corner toward the rectangle's UI-space center so
        -- a second (e.g. combat-policy) outline nests visibly inside
        -- the first (zone-type) outline instead of drawing exactly
        -- on top of it.
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

    thickness = thickness or 2
    self.javaObject:DrawLine(nil, x1, y1, x2, y2, thickness, r, g, blue, alpha)
    self.javaObject:DrawLine(nil, x2, y2, x3, y3, thickness, r, g, blue, alpha)
    self.javaObject:DrawLine(nil, x3, y3, x4, y4, thickness, r, g, blue, alpha)
    self.javaObject:DrawLine(nil, x4, y4, x1, y1, thickness, r, g, blue, alpha)
end

------------------------------------------------------------
-- EXISTING ZONE OVERLAY
------------------------------------------------------------

-- "TYPE / round N / team X / custom label" -- whichever parts apply,
-- same ordering as the admin panel's own hotspot picker
-- (KIPN_EventScenarioAdminUI.lua's hotspotSelectCombo) so a label
-- read here matches what's typed there.
local function hotspotMapLabel(zone)
    local parts = { (KIPN.Shared.EventHotspotTypeLabels or {})[zone.type] or zone.type or "Hotspot" }
    if zone.roundNumber then parts[#parts + 1] = "round " .. tostring(zone.roundNumber) end
    if zone.teamId then parts[#parts + 1] = "team " .. tostring(zone.teamId) end
    if zone.label and zone.label ~= "" then parts[#parts + 1] = tostring(zone.label) end
    return table.concat(parts, " / ")
end

function KIPN_ZoneAdminMapUI:drawExistingZones()
    for _, zone in ipairs(self.existingZones) do
        if zone.active ~= false and type(zone.geometry) == "table" then
            local a = { x = zone.geometry.x1, y = zone.geometry.y1 }
            local b = { x = zone.geometry.x2, y = zone.geometry.y2 }

            if self.selectedExistingZone and zone.id == self.selectedExistingZone.id then
                self:drawZoneRect(a, b, 1.0, 1.0, 1.0, 1.0, 0, 5)
            end

            if zone.kind == "hotspot" then
                local typeColor = HOTSPOT_TYPE_COLORS[zone.type] or HOTSPOT_TYPE_COLORS.OBJECTIVE_LOCATION
                self:drawZoneRect(a, b, typeColor.r, typeColor.g, typeColor.b, 0.85, 0, 2)

                local roundColor = zone.roundNumber and ROUND_COLORS[zone.roundNumber]
                if roundColor then
                    self:drawZoneRect(a, b, roundColor.r, roundColor.g, roundColor.b, 0.85, 5, 2)
                end

                local labelX = self.mapAPI:worldToUIX(a.x, a.y)
                local labelY = self.mapAPI:worldToUIY(a.x, a.y)
                local label = hotspotMapLabel(zone)
                self:drawText(label, labelX + 2, labelY - 16, 0, 0, 0, 0.9, UIFont.Small)
                self:drawText(label, labelX + 1, labelY - 17, typeColor.r, typeColor.g, typeColor.b, 1, UIFont.Small)
            else
                local typeColor = ZONE_TYPE_COLORS[zone.type] or ZONE_TYPE_COLORS.custom
                self:drawZoneRect(a, b, typeColor.r, typeColor.g, typeColor.b, 0.85, 0, 2)

                local policyColor = zone.combatPolicy and COMBAT_POLICY_COLORS[zone.combatPolicy]
                if policyColor then
                    self:drawZoneRect(a, b, policyColor.r, policyColor.g, policyColor.b, 0.85, 5, 2)
                end
            end
        end
    end
end

------------------------------------------------------------
-- LEGEND (fixed screen-space, unaffected by map pan/zoom)
------------------------------------------------------------

function KIPN_ZoneAdminMapUI:renderLegend()
    local x = 10
    local y = self.height - 34
    local swatch = 12
    local entryWidth = 92

    local function drawEntry(label, color)
        self:drawRect(x, y, swatch, swatch, 0.9, color.r, color.g, color.b)
        self:drawRectBorder(x, y, swatch, swatch, 1, 0, 0, 0)
        self:drawText(label, x + swatch + 4, y - 2, 1, 1, 1, 1, UIFont.Small)
        x = x + entryWidth
    end

    local hasHotspots = false
    local roundsUsed = {}
    for _, zone in ipairs(self.existingZones) do
        if zone.kind == "hotspot" then
            hasHotspots = true
            if zone.roundNumber then roundsUsed[zone.roundNumber] = true end
        end
    end

    if hasHotspots then
        self:drawText("Outer ring = hotspot type:", x, y - 2, 0.8, 0.8, 0.8, 1, UIFont.Small)
        x = x + 165
        entryWidth = 118
        for _, hotspotType in ipairs(KIPN.Shared.EventHotspotTypeOrder or {}) do
            drawEntry(
                (KIPN.Shared.EventHotspotTypeLabels or {})[hotspotType] or hotspotType,
                HOTSPOT_TYPE_COLORS[hotspotType] or HOTSPOT_TYPE_COLORS.OBJECTIVE_LOCATION
            )
        end

        local sortedRounds = {}
        for roundNumber in pairs(roundsUsed) do sortedRounds[#sortedRounds + 1] = roundNumber end
        table.sort(sortedRounds)

        if #sortedRounds > 0 then
            entryWidth = 80
            x = x + 20
            self:drawText("Inner ring = round:", x, y - 2, 0.8, 0.8, 0.8, 1, UIFont.Small)
            x = x + 110
            for _, roundNumber in ipairs(sortedRounds) do
                drawEntry("Round " .. tostring(roundNumber), ROUND_COLORS[roundNumber] or ROUND_COLORS[#ROUND_COLORS])
            end
        end
        return
    end

    self:drawText("Outer ring = zone type:", x, y - 2, 0.8, 0.8, 0.8, 1, UIFont.Small)
    x = x + 150
    drawEntry("Government", ZONE_TYPE_COLORS.government)
    drawEntry("Dealership", ZONE_TYPE_COLORS.dealership)
    drawEntry("Custom", ZONE_TYPE_COLORS.custom)
    drawEntry("Do Not Claim", ZONE_TYPE_COLORS.do_not_claim)

    x = x + 20
    self:drawText("Inner ring = combat zone (default is full PvP):", x, y - 2, 0.8, 0.8, 0.8, 1, UIFont.Small)
    x = x + 260
    drawEntry("PvE", COMBAT_POLICY_COLORS.PVE)
    drawEntry("Melee", COMBAT_POLICY_COLORS.MELEE_PVP)
end

function KIPN_ZoneAdminMapUI:render()
    getWorld():setDrawWorld(false)

    self:drawExistingZones()

    if self.cornerA and self.cornerB then
        if self.mode == "edit" or self.mode == "editResize" then
            self:drawZoneRect(self.cornerA, self.cornerB, 1.0, 1.0, 1.0, 1.0, 0, 3)
        else
            self:drawZoneRect(self.cornerA, self.cornerB, 0.3, 1.0, 0.3, 1.0)
        end
    elseif self.cornerA and self.previewWorldX then
        self:drawZoneRect(self.cornerA, { x = self.previewWorldX, y = self.previewWorldY }, 1.0, 1.0, 0.3, 0.6)
    end

    ISPanel.render(self)

    if #self.existingZones > 0 then
        self:renderLegend()
    end
end

------------------------------------------------------------
-- CLOSE (mirrors ISWorldMap:close's world-draw restoration)
------------------------------------------------------------

function KIPN_ZoneAdminMapUI:close()
    self:setVisible(false)
    self:removeFromUIManager()

    if getSpecificPlayer(0) then
        getWorld():setDrawWorld(true)
    end

    if KIPN_ZoneAdminMapUI.instance == self then
        KIPN_ZoneAdminMapUI.instance = nil
    end

    if self.callbacks.onClose then
        self.callbacks.onClose()
    end
end

print("[KIPN] Zone Admin Map UI loaded")
