-- KIPN_ZoneEditorIntegration.lua
--
-- Adds a "KIPN" mode to Project Zomboid's BUILT-IN admin Zone
-- Editor (Admin Panel -> Zone Editor), alongside the vanilla
-- Non-PVP and Safehouse modes. An admin opens the normal Zone
-- Editor, switches the mode dropdown to "KIPN", and draws a
-- rectangle directly on that map -- exactly like drawing a
-- Non-PVP zone -- then classifies it as a significant KIPN
-- interaction zone (Government Building / Car Dealership /
-- Custom).
--
-- This intentionally does NOT introduce a new floating panel or
-- map overlay. It is a thin client on top of the KIPN zone
-- storage/authorization that already exists:
--   KIPN_ZoneAdminServer.lua  (command handlers, admin check)
--   KIPN_WorldRegistry.lua    (persistence, zone types)
-- the same protocol KIPN_ZoneAdminUI.lua already talks to. Zones
-- created here show up identically to zones created from the
-- "KIPN: Zone Admin Tool" right-click panel, and vice versa --
-- both are just admins writing to the same WorldRegistry.
--
-- HOW THE HOOK WORKS:
-- ISMultiplayerZoneEditor has no native registration API for custom
-- modes. KIPN therefore wraps createChildren() and OnRolesReceived(),
-- always calling the previously installed implementation first and
-- then idempotently attaching only its own mode. The role-event
-- listener is transferred from the previous function to the wrapper.
-- Other zone mods can use the same contract, producing a cooperative
-- wrapper chain in any load order without clearing one another's modes.
--
-- kipnIsAdmin() uses KIPN_AdminAccess rather than native isAdmin() or
-- getAccessLevel() directly. This includes KIPN.AdminAccounts while
-- keeping Permissions.ResolveAccessLevel authoritative on the server.
--
-- Also gates ISAdminPanelUI:updateButtons() (also a full
-- replacement -- see that function below) the same way, since the
-- Admin Panel's "Zone Editor" button is itself only enabled via
-- those same two vanilla Capabilities; without also unlocking it
-- for kipnIsAdmin(), an admin whose role lacks both capabilities
-- could never open the editor to reach the 'KIPN' mode at all.
--
-- SCOPE NOTE: existing zones can be reclassified (Set Type) or
-- removed here, but not resized by dragging -- redraw a new zone
-- and remove the old one if the bounds are wrong. Combat-policy
-- zones (PvE / Melee) are a separate concern and stay on the
-- "KIPN: Zone Admin Tool" panel.

require "ISUI/AdminPanel/ISAdminPanelUI"
require "ISUI/AdminPanel/ZoneEditor/ISMultiplayerZoneEditor"
require "ISUI/AdminPanel/ZoneEditor/MultiplayerZoneEditorMode"
require "ISUI/Maps/Editor/WorldMapEditorResizer"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISComboBox"
require "ISUI/ISLabel"
require "ISUI/ISTextBox"
require "ISUI/ISModalDialog"
require "KIPN_AdminAccess"

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local UI_BORDER_SPACING = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6

local MODULE_NAME = "KIPN_ZoneAdmin"

-- Mirrors KIPN_WorldRegistry.ZoneTypes / ZoneTypeLabels. Kept as a
-- plain client-side list (same convention KIPN_ZoneAdminUI.lua
-- uses) since this panel only needs the string values to send to
-- the server, which validates them authoritatively regardless.
local ZONE_TYPE_OPTIONS = {
    { text = "Government Building", value = "government" },
    { text = "Car Dealership", value = "dealership" },
    { text = "Custom", value = "custom" },
    { text = "Do Not Claim Zone", value = "do_not_claim" },
}

local ZONE_TYPE_LABELS = {}
for _, option in ipairs(ZONE_TYPE_OPTIONS) do
    ZONE_TYPE_LABELS[option.value] = option.text
end

------------------------------------------------------------
-- ADMIN CHECK
--
-- Uses the shared server-resolved KIPN access level so native admins
-- and KIPN.AdminAccounts admins follow the same UI gate.
------------------------------------------------------------

local function kipnIsAdmin()
    return KIPN.Client.AdminAccess.IsAdmin(0)
end

------------------------------------------------------------
-- MultiplayerZoneEditorMode_KIPN
------------------------------------------------------------

MultiplayerZoneEditorMode_KIPN = MultiplayerZoneEditorMode:derive("MultiplayerZoneEditorMode_KIPN")

function MultiplayerZoneEditorMode_KIPN:createChildren()
    local ROWS = 6
    self.listbox = ISScrollingListBox:new(UI_BORDER_SPACING, self.editor.modeCombo:getBottom() + UI_BORDER_SPACING, 300, (FONT_HGT_SMALL + 3 * 2) * ROWS)
    self.listbox:setFont(UIFont.Small, 3)
    self.listbox:setOnMouseDownFunction(self, MultiplayerZoneEditorMode_KIPN.onListSelectionChanged)
    self:addChild(self.listbox)

    self.typeCombo = ISComboBox:new(UI_BORDER_SPACING, self.listbox:getBottom() + UI_BORDER_SPACING, 300, FONT_HGT_SMALL + 4, self, MultiplayerZoneEditorMode_KIPN.onTypeComboChange)
    for _, option in ipairs(ZONE_TYPE_OPTIONS) do
        self.typeCombo:addOptionWithData(option.text, option.value)
    end
    self.typeCombo:setSelected(1)
    self.selectedZoneType = ZONE_TYPE_OPTIONS[1].value
    self:addChild(self.typeCombo)

    local button = ISButton:new(UI_BORDER_SPACING, self.typeCombo:getBottom() + UI_BORDER_SPACING, 80, BUTTON_HGT, "Add Zone", self, function(self) self:onAddZone() end)
    button:setWidthToTitle()
    self:addChild(button)
    self.addButton = button

    button = ISButton:new(UI_BORDER_SPACING, button:getBottom() + UI_BORDER_SPACING, 80, BUTTON_HGT, "Set Type", self, function(self) self:onSetType() end)
    button:setWidthToTitle()
    self:addChild(button)
    self.setTypeButton = button

    button = ISButton:new(UI_BORDER_SPACING, button:getBottom() + UI_BORDER_SPACING, 80, BUTTON_HGT, "Remove Zone", self, function(self) self:onRemoveZone() end)
    button:setWidthToTitle()
    self:addChild(button)
    self.removeButton = button

    self.statusLabel = ISLabel:new(UI_BORDER_SPACING, button:getBottom() + UI_BORDER_SPACING, FONT_HGT_SMALL, "", 1, 0.85, 0.3, 1, UIFont.Small, true)
    self:addChild(self.statusLabel)

    self.zones = {}
end

function MultiplayerZoneEditorMode_KIPN:setStatus(text)
    if self.statusLabel then
        self.statusLabel:setName(text or "")
    end
end

function MultiplayerZoneEditorMode_KIPN:display()
    MultiplayerZoneEditorMode.display(self)
    self:refreshZones()
end

function MultiplayerZoneEditorMode_KIPN:undisplay()
    if self.modalUI then
        self.modalUI:close()
        self.modalUI:setVisible(false)
        self.modalUI:removeFromUIManager()
        self.modalUI = nil
    end
    self.selectedZoneId = nil
    self:cancelDraw()
    MultiplayerZoneEditorMode.undisplay(self)
end

function MultiplayerZoneEditorMode_KIPN:prerender()
    local hasSelection = self.selectedZoneId ~= nil
    self.setTypeButton:setEnable(hasSelection)
    self.removeButton:setEnable(hasSelection)
end

------------------------------------------------------------
-- SERVER SYNC
------------------------------------------------------------

function MultiplayerZoneEditorMode_KIPN:refreshZones()
    local player = getSpecificPlayer(0)
    if not player then return end

    sendClientCommand(player, MODULE_NAME, "ListZones", {})
end

function MultiplayerZoneEditorMode_KIPN:onZonesReceived(zones)
    local selectedId = self.selectedZoneId

    self.zones = {}
    for _, zone in ipairs(zones or {}) do
        if zone.active ~= false then
            self.zones[#self.zones + 1] = zone
        end
    end

    self:fillList()

    self.selectedZoneId = nil
    for _, zone in ipairs(self.zones) do
        if zone.id == selectedId then
            self.selectedZoneId = selectedId
        end
    end

    if self.selectedZoneId then
        for i, item in ipairs(self.listbox.items) do
            if item.item.id == self.selectedZoneId then
                self.listbox.selected = i
            end
        end
    end
end

function MultiplayerZoneEditorMode_KIPN:fillList()
    self.listbox:clear()
    for _, zone in ipairs(self.zones) do
        local typeLabel = ZONE_TYPE_LABELS[zone.type] or tostring(zone.type)
        local label = zone.metadata and zone.metadata.label
        local text = label and (typeLabel .. " -- " .. label) or typeLabel
        self.listbox:addItem(text, zone)
    end
    self.listbox:sort()
end

function MultiplayerZoneEditorMode_KIPN:getSelectedZone()
    local selected = self.listbox.selected
    local item = self.listbox.items[selected]
    return item and item.item or nil
end

function MultiplayerZoneEditorMode_KIPN:onListSelectionChanged(zone)
    self.selectedZoneId = zone and zone.id or nil
end

------------------------------------------------------------
-- RENDER
------------------------------------------------------------

function MultiplayerZoneEditorMode_KIPN:render()
    local r, g, b, a = 1.0, 0.65, 0.0, 0.6
    for _, zone in ipairs(self.zones) do
        local geometry = zone.geometry
        if geometry then
            local highlight = zone.id == self.selectedZoneId
            self:renderRect(geometry.x1, geometry.y1, geometry.x2, geometry.y2, r, g, b, highlight and 1.0 or a)

            local uiX = self.mapAPI:worldToUIX(geometry.x1, geometry.y1)
            local uiY = self.mapAPI:worldToUIY(geometry.x1, geometry.y1)
            local typeLabel = ZONE_TYPE_LABELS[zone.type] or tostring(zone.type)
            self:drawText(typeLabel, uiX + 4, uiY + 2, 0, 0, 0, 1, UIFont.Small)
        end
    end

    self:renderResizer()

    if self.mode == "StartDrawingBounds" then
        local mx = self.mapUI:getMouseX()
        local my = self.mapUI:getMouseY()
        local worldX = self.mapAPI:uiToWorldX(mx, my)
        local worldY = self.mapAPI:uiToWorldY(mx, my)
        worldX = self.resizer:snap(worldX)
        worldY = self.resizer:snap(worldY)
        mx = self.mapAPI:worldToUIX(worldX, worldY)
        my = self.mapAPI:worldToUIY(worldX, worldY)
        self.mapUI:drawRectBorder(mx - 10, my - 10, 20, 20, 1, 0, 0, 1)
        self.mapUI:drawRectBorder(mx - 10 - 1, my - 10 - 1, 20 + 2, 20 + 2, 1, 0, 0, 1)
    end
end

function MultiplayerZoneEditorMode_KIPN:renderResizer()
    local r, g, b, a = 0, 0, 0, 1
    if self.mode == "DrawBounds" then
        local x1, y1, x2, y2 = self.resizer.x1, self.resizer.y1, self.resizer.x2, self.resizer.y2
        if not self:isNewZoneValid(x1, y1, x2, y2) then
            r = 1
        end
    end
    self.resizer:render(r, g, b, a)
end

function MultiplayerZoneEditorMode_KIPN:renderRect(x1, y1, x2, y2, r, g, b, a)
    local uiX1 = self.mapAPI:worldToUIX(x1, y1)
    local uiY1 = self.mapAPI:worldToUIY(x1, y1)
    local uiX2 = self.mapAPI:worldToUIX(x2, y1)
    local uiY2 = self.mapAPI:worldToUIY(x2, y1)
    local uiX3 = self.mapAPI:worldToUIX(x2, y2)
    local uiY3 = self.mapAPI:worldToUIY(x2, y2)
    local uiX4 = self.mapAPI:worldToUIX(x1, y2)
    local uiY4 = self.mapAPI:worldToUIY(x1, y2)
    local THICK = 1
    self.mapUI.javaObject:DrawLine(Texture:getWhite(), uiX1, uiY1, uiX2, uiY2, THICK, r, g, b, a)
    self.mapUI.javaObject:DrawLine(Texture:getWhite(), uiX2, uiY2, uiX3, uiY3, THICK, r, g, b, a)
    self.mapUI.javaObject:DrawLine(Texture:getWhite(), uiX3, uiY3, uiX4, uiY4, THICK, r, g, b, a)
    self.mapUI.javaObject:DrawLine(Texture:getWhite(), uiX4, uiY4, uiX1, uiY1, THICK, r, g, b, a)
end

------------------------------------------------------------
-- DRAWING A NEW ZONE
------------------------------------------------------------

function MultiplayerZoneEditorMode_KIPN:isNewZoneValid(x1, y1, x2, y2)
    return x1 < x2 and y1 < y2
end

function MultiplayerZoneEditorMode_KIPN:onAddZone()
    if self.mode == "StartDrawingBounds" then
        self.mode = nil
        return
    end
    self.mode = "StartDrawingBounds"
    self.resizer:setBounds(0, 0, 0, 0)
end

function MultiplayerZoneEditorMode_KIPN:onMouseDown(x, y)
    if self.mode == "StartDrawingBounds" then
        self.mode = "DrawBounds"
        local worldX = self.mapAPI:uiToWorldX(x, y)
        local worldY = self.mapAPI:uiToWorldY(x, y)
        worldX = self.resizer:snap(worldX)
        worldY = self.resizer:snap(worldY)
        self.resizer:setBounds(worldX, worldY, worldX, worldY)
        self.resizer:startResizing()
        return true
    end
    return false -- allow clicks in the map
end

function MultiplayerZoneEditorMode_KIPN:onMouseMove(dx, dy)
    if self.mode == "DrawBounds" then
        local mx = self:getMouseX()
        local my = self:getMouseY()
        self.resizer:onMouseMove(mx, my, "BottomRight")
        return true
    end
    if self.mode then
        return true
    end
    return false -- allow clicks in the map
end

function MultiplayerZoneEditorMode_KIPN:onMouseUp(x, y)
    if self.mode == "DrawBounds" then
        self.mode = nil
        local x1, y1, x2, y2 = self.resizer.x1, self.resizer.y1, self.resizer.x2, self.resizer.y2
        self.resizer:endResizing()

        if self:isNewZoneValid(x1, y1, x2, y2) then
            self:promptNewZoneLabel(x1, y1, x2, y2)
        end

        return true
    end
    return false -- allow clicks in the map
end

function MultiplayerZoneEditorMode_KIPN:onMouseUpOutside(x, y)
    return self:onMouseUp(x, y)
end

function MultiplayerZoneEditorMode_KIPN:onRightMouseDown(x, y)
    return self:cancelDraw()
end

function MultiplayerZoneEditorMode_KIPN:onKeyRelease(key)
    if key == Keyboard.KEY_ESCAPE then
        return self:cancelDraw()
    end
    return false
end

function MultiplayerZoneEditorMode_KIPN:cancelDraw()
    if self.mode == "DrawBounds" then
        self.mode = nil
        self.resizer:endResizing()
        return true
    end
    if self.mode == "StartDrawingBounds" then
        self.mode = nil
        return true
    end
    return false
end

function MultiplayerZoneEditorMode_KIPN:promptNewZoneLabel(x1, y1, x2, y2)
    self.pendingBounds = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }

    local modal = ISTextBox:new(0, 0, 280, 180, "Optional label for this KIPN zone (leave blank for none):", "", self, self.onNewZoneLabelEntered, nil)
    modal:initialise()
    modal:addToUIManager()
    self.modalUI = modal
end

function MultiplayerZoneEditorMode_KIPN:onNewZoneLabelEntered(button)
    self.modalUI = nil

    local bounds = self.pendingBounds
    self.pendingBounds = nil

    if button.internal ~= "OK" or not bounds then
        return
    end

    local label = button.parent.entry:getText()

    local player = getSpecificPlayer(0)
    if not player then
        self:setStatus("No local player found.")
        return
    end

    self:setStatus("Creating zone...")

    sendClientCommand(player, MODULE_NAME, "CreateZone", {
        zoneType = self.selectedZoneType,
        cornerA = { x = bounds.x1, y = bounds.y1 },
        cornerB = { x = bounds.x2, y = bounds.y2 },
        label = (label ~= "" and label) or nil,
    })
end

------------------------------------------------------------
-- RECLASSIFY / REMOVE AN EXISTING ZONE
------------------------------------------------------------

function MultiplayerZoneEditorMode_KIPN:onTypeComboChange()
    local selected = self.typeCombo.options[self.typeCombo.selected]
    if selected then
        self.selectedZoneType = selected.data
    end
end

function MultiplayerZoneEditorMode_KIPN:onSetType()
    if not self.selectedZoneId then
        self:setStatus("Select a zone first.")
        return
    end

    local player = getSpecificPlayer(0)
    if not player then
        self:setStatus("No local player found.")
        return
    end

    self:setStatus("Updating classification...")

    sendClientCommand(player, MODULE_NAME, "SetZoneType", {
        zoneId = self.selectedZoneId,
        zoneType = self.selectedZoneType,
    })
end

function MultiplayerZoneEditorMode_KIPN:onRemoveZone()
    if not self.selectedZoneId then
        self:setStatus("Select a zone first.")
        return
    end

    local zone = self:getSelectedZone()
    local typeLabel = zone and (ZONE_TYPE_LABELS[zone.type] or tostring(zone.type)) or "this zone"

    local modal = ISModalDialog:new(self.removeButton:getRight() + 20, self.removeButton:getY(), 350, 150, "Remove " .. typeLabel .. "?", true, self, self.onConfirmRemoveZone)
    modal:initialise()
    modal:addToUIManager()
    modal.zoneId = self.selectedZoneId
    modal.moveWithMouse = true
    modal:setAlwaysOnTop(true)
    self.modalUI = modal
end

function MultiplayerZoneEditorMode_KIPN:onConfirmRemoveZone(button)
    self.modalUI = nil

    if button.internal ~= "YES" then
        return
    end

    local player = getSpecificPlayer(0)
    if not player then
        self:setStatus("No local player found.")
        return
    end

    self:setStatus("Removing zone...")

    sendClientCommand(player, MODULE_NAME, "DeactivateZone", {
        zoneId = button.parent.zoneId,
    })
end

------------------------------------------------------------
-- SERVER RESPONSES
------------------------------------------------------------

local function onServerCommand(module, command, args)
    if module ~= MODULE_NAME then
        return
    end

    local instance = ISMultiplayerZoneEditor_instance
    local mode = instance and instance.mode and instance.mode['KIPN']
    if not mode then
        return
    end

    if command == "ListZonesResult" then
        if args.success then
            mode:onZonesReceived(args.zones)
        end

    elseif command == "CreateZoneResult" then
        if args.success then
            mode:setStatus("Zone created: " .. tostring(args.zoneId))
        else
            mode:setStatus("Failed: " .. tostring(args.reason))
        end
        mode:refreshZones()

    elseif command == "SetZoneTypeResult" then
        if args.success then
            mode:setStatus("Classification updated.")
        else
            mode:setStatus("Failed: " .. tostring(args.reason))
        end
        mode:refreshZones()

    elseif command == "DeactivateZoneResult" then
        if args.success then
            mode:setStatus("Zone removed.")
            mode.selectedZoneId = nil
        else
            mode:setStatus("Failed: " .. tostring(args.reason))
        end
        mode:refreshZones()
    end
end

Events.OnServerCommand.Add(onServerCommand)

function MultiplayerZoneEditorMode_KIPN:new(editor)
    local o = MultiplayerZoneEditorMode.new(self, editor)
    o.snapMode = "square"
    o.resizer = WorldMapEditorResizer:new(editor)
    o.resizer.snapMode = o.snapMode
    o.zones = {}
    return o
end

------------------------------------------------------------
-- ADMIN PANEL "ZONE EDITOR" BUTTON GATE
--
-- Getting 'KIPN' into the editor's mode dropdown (below) is not
-- enough on its own: the vanilla Admin Panel only enables its
-- "Zone Editor" button (ISAdminPanelUI:updateButtons, see
-- media/lua/client/ISUI/AdminPanel/ISAdminPanelUI.lua in the game
-- install) via
--   Capability.CanSetupNonPVPZone or Capability.CanSetupSafehouses
-- A disabled ISButton never fires its click handler at all, so on
-- any server where the admin's role doesn't happen to have one of
-- those two specific capabilities checked (they're easy to leave
-- off since KIPN doesn't otherwise need them), the button simply
-- never opens the editor -- the 'KIPN' mode below is never even
-- reached, no matter what it's gated on internally. This is the
-- cause of the editor "sometimes" being reachable: it tracks
-- whether that role capability happened to be granted/synced, not
-- anything KIPN does.
--
-- Fix: also unlock the button for kipnIsAdmin(), the same shared
-- server-resolved bar every other KIPN admin entry point uses. Full
-- replacement, not a wrap, because the vanilla function calls
-- self:close() itself when nothing ended up enabled -- a wrap that
-- only patches self.zoneEditor.enable afterward would be too late to
-- stop that close() on a role with no other capabilities either.
-- Diff against media/lua/client/ISUI/AdminPanel/ISAdminPanelUI.lua in
-- the game install if this stops working after a game update -- the
-- only intentional difference is the kipnIsAdmin() addition on the
-- self.zoneEditor.enable line.
------------------------------------------------------------

function ISAdminPanelUI:updateButtons()
    local enabled = false;

    if getPlayer() == nil or getPlayer():getRole() == nil then
        self:close()
        return
    end

    self.checkStatsBtn.enable = getPlayer():getRole():hasCapability(Capability.CanSeePlayersStats);
    enabled = enabled or self.checkStatsBtn.enable
    self.adminPowerBtn.enable = getPlayer():getRole():hasAdminPower();
    enabled = enabled or self.adminPowerBtn.enable
    self.itemListBtn.enable = getPlayer():getRole():hasCapability(Capability.AddItem);
    enabled = enabled or self.itemListBtn.enable
    self.seeOptionsBtn.enable = getPlayer():getRole():hasCapability(Capability.SeePublicServerOptions);
    enabled = enabled or self.seeOptionsBtn.enable
    self.nonpvpzoneBtn.enable = getPlayer():getRole():hasCapability(Capability.CanSetupNonPVPZone);
    enabled = enabled or self.nonpvpzoneBtn.enable
    self.seeFactionBtn.enable = getPlayer():getRole():hasCapability(Capability.FactionCheat);
    enabled = enabled or self.seeFactionBtn.enable
    self.seeRolesBtn.enable = getPlayer():getRole():hasCapability(Capability.RolesRead);
    enabled = enabled or self.seeRolesBtn.enable
    self.seeUsersBtn.enable = getPlayer():getRole():hasCapability(Capability.SeeNetworkUsers);
    enabled = enabled or self.seeUsersBtn.enable
    self.seeSafehousesBtn.enable = getPlayer():getRole():hasCapability(Capability.CanSetupSafehouses);
    enabled = enabled or self.seeSafehousesBtn.enable
    self.safezoneBtn.enable = getPlayer():getRole():hasCapability(Capability.CanSetupSafehouses);
    enabled = enabled or self.safezoneBtn.enable
    self.seeTicketsBtn.enable = getPlayer():getRole():hasCapability(Capability.AnswerTickets);
    enabled = enabled or self.seeTicketsBtn.enable
    self.miniScoreboardBtn.enable = getPlayer():getRole():hasCapability(Capability.SeePlayersConnected);
    enabled = enabled or self.miniScoreboardBtn.enable
    self.sandboxOptionsBtn.enable = getPlayer():getRole():hasCapability(Capability.SandboxOptions);
    enabled = enabled or self.sandboxOptionsBtn.enable
    self.climateOptionsBtn.enable = getPlayer():getRole():hasCapability(Capability.ClimateManager);
    enabled = enabled or self.climateOptionsBtn.enable
    self.showStatisticsBtn.enable = getPlayer():getRole():hasCapability(Capability.GetStatistic);
    enabled = enabled or self.showStatisticsBtn.enable
    self.pvpLogTool.enable = getPlayer():getRole():hasCapability(Capability.PVPLogTool);
    enabled = enabled or self.pvpLogTool.enable
    self.zoneEditor.enable = getPlayer():getRole():hasCapability(Capability.CanSetupSafehouses)
        or getPlayer():getRole():hasCapability(Capability.CanSetupNonPVPZone)
        or kipnIsAdmin();
    enabled = enabled or self.zoneEditor.enable

    if not enabled then
        self:close()
    end
end

------------------------------------------------------------
-- ADD "KIPN" TO ISMultiplayerZoneEditor
--
-- Never rebuild the shared mode table or dropdown here. Every zone mod
-- owns only its own mode and cooperatively wraps the function that was
-- installed before it. This is intentionally load-order independent.
------------------------------------------------------------

local KIPN_ZONE_MODE = "KIPN"

local function comboHasMode(combo, modeId)
    if not combo then return false end
    for index = 1, combo:getOptionCount() do
        if combo:getOptionData(index) == modeId then return true end
    end
    return false
end

local function ensureKipnMode(editor)
    if not editor or not editor.mode or not editor.modeCombo then return false end
    if not editor.mode[KIPN_ZONE_MODE] then
        local mode = MultiplayerZoneEditorMode_KIPN:new(editor)
        editor.mode[KIPN_ZONE_MODE] = mode
        editor:addChild(mode)
        mode:setVisible(false)
    end
    local authorized = kipnIsAdmin()
    if authorized and not comboHasMode(editor.modeCombo, KIPN_ZONE_MODE) then
        editor.modeCombo:addOptionWithData("KIPN", KIPN_ZONE_MODE)
    end
    if editor.buttonPanel and editor.buttonPanel.bringToTop then editor.buttonPanel:bringToTop() end
    if editor.modeCombo.bringToTop then editor.modeCombo:bringToTop() end
    return authorized
end

local kipnCreateChildren = ISMultiplayerZoneEditor.createChildren
function ISMultiplayerZoneEditor:createChildren()
    kipnCreateChildren(self)
    ensureKipnMode(self)
end

local kipnOnRolesReceived = ISMultiplayerZoneEditor.OnRolesReceived
function ISMultiplayerZoneEditor.OnRolesReceived()
    local instance = ISMultiplayerZoneEditor_instance
    local restoreKipn = instance and instance.currentMode == KIPN_ZONE_MODE
    kipnOnRolesReceived()
    instance = ISMultiplayerZoneEditor_instance
    local authorized = ensureKipnMode(instance)
    if restoreKipn and authorized then
        instance.modeCombo:selectData(KIPN_ZONE_MODE)
        instance:onSwitchMode(KIPN_ZONE_MODE)
    end
end

-- Keep exactly one role-event entry for the cooperative wrapper chain.
Events.OnRolesReceived.Remove(kipnOnRolesReceived)
Events.OnRolesReceived.Add(ISMultiplayerZoneEditor.OnRolesReceived)

-- GET_PLAYER_DATA may arrive after the editor singleton has already
-- populated its dropdown. Refresh immediately when the shared access
-- cache changes so KIPN appears without requiring the editor or client
-- to be restarted.
if KIPN.Client.AdminAccess.AddListener then
    KIPN.Client.AdminAccess.AddListener(function()
        ISMultiplayerZoneEditor.OnRolesReceived()
    end)
end

------------------------------------------------------------
-- Re-run the complete wrapper chain on every open so late role/admin
-- synchronization self-heals all cooperating custom modes together.
------------------------------------------------------------

local kipnShowEditor = ISMultiplayerZoneEditor.ShowEditor
function ISMultiplayerZoneEditor.ShowEditor()
    kipnShowEditor()
    ISMultiplayerZoneEditor.OnRolesReceived()
end

print("[KIPN] Zone Editor integration loaded")
