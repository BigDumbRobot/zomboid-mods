require "ISUI/AdminPanel/ZoneEditor/MultiplayerZoneEditorMode"
require "ISUI/Maps/Editor/WorldMapEditorResizer"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"
require "ISUI/ISTextBox"
require "ISUI/ISModalDialog"
require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_ClientState"
require "SacrificialOffering/SO_ClientZoneRules"

local SO = SacrificialOffering
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local UI_BORDER_SPACING = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6

MultiplayerZoneEditorMode_SO_SatanicTemples = MultiplayerZoneEditorMode:derive("MultiplayerZoneEditorMode_SO_SatanicTemples")
local Mode = MultiplayerZoneEditorMode_SO_SatanicTemples

function Mode:createChildren()
    self.listbox = ISScrollingListBox:new(UI_BORDER_SPACING, self.editor.modeCombo:getBottom() + UI_BORDER_SPACING,
        330, (FONT_HGT_SMALL + 6) * 7)
    self.listbox:setFont(UIFont.Small, 3)
    self:addChild(self.listbox)

    self.addButton = ISButton:new(UI_BORDER_SPACING, self.listbox:getBottom() + UI_BORDER_SPACING,
        80, BUTTON_HGT, getText("IGUI_MultiplayerZoneEditor_Button_AddZone"), self, self.onAddZone)
    self.addButton:setWidthToTitle()
    self:addChild(self.addButton)

    self.renameButton = ISButton:new(UI_BORDER_SPACING, self.addButton:getBottom() + UI_BORDER_SPACING,
        80, BUTTON_HGT, getText("IGUI_MultiplayerZoneEditor_Button_RenameZone"), self, self.onRenameZone)
    self.renameButton:setWidthToTitle()
    self:addChild(self.renameButton)

    self.removeButton = ISButton:new(UI_BORDER_SPACING, self.renameButton:getBottom() + UI_BORDER_SPACING,
        80, BUTTON_HGT, getText("IGUI_MultiplayerZoneEditor_Button_RemoveZone"), self, self.onRemoveZone)
    self.removeButton:setWidthToTitle()
    self:addChild(self.removeButton)

    self.removeAllButton = ISButton:new(UI_BORDER_SPACING, self.removeButton:getBottom() + UI_BORDER_SPACING,
        80, BUTTON_HGT, getText("IGUI_SO_RemoveAllTemples"), self, self.onRemoveAllZones)
    self.removeAllButton:setWidthToTitle()
    self:addChild(self.removeAllButton)
end

function Mode:display()
    MultiplayerZoneEditorMode.display(self)
    self.builtRevision = nil
    SO.Client.RequestZones()
end

function Mode:isDrawingNewZone()
    return self.mode == "StartDrawingBounds" or self.mode == "DrawBounds"
end

function Mode:prerender()
    self:fillList()
    -- While the admin is placing a brand-new temple, the list selection must not
    -- drive anything: re-selecting an existing row here would fire
    -- selectedZoneChanged() -> cancelResize() and silently abort the draw, which
    -- is what limited the editor to a single temple.
    if self:isDrawingNewZone() then
        self.renameButton:setEnable(false)
        self.removeButton:setEnable(false)
        return
    end
    local zone = self:getSelectedZone()
    local zoneId = zone and zone.id or nil
    if zoneId ~= self.selectedZoneId then
        self:selectedZoneChanged()
        self.selectedZoneId = zoneId
        if zone then
            self.resizer:setBounds(zone.x1, zone.y1, zone.x2, zone.y2)
            self.mapAPI:centerOn(zone.x1, zone.y1)
        else
            self.resizer:setBounds(0, 0, 0, 0)
        end
    end
    self.renameButton:setEnable(zone ~= nil)
    self.removeButton:setEnable(zone ~= nil)
    self.removeAllButton:setEnable(#SO.Client.Zones > 0)
end

function Mode:renderRect(x1, y1, x2, y2, r, g, b, a)
    local uiX1, uiY1 = self.mapAPI:worldToUIX(x1, y1), self.mapAPI:worldToUIY(x1, y1)
    local uiX2, uiY2 = self.mapAPI:worldToUIX(x2, y1), self.mapAPI:worldToUIY(x2, y1)
    local uiX3, uiY3 = self.mapAPI:worldToUIX(x2, y2), self.mapAPI:worldToUIY(x2, y2)
    local uiX4, uiY4 = self.mapAPI:worldToUIX(x1, y2), self.mapAPI:worldToUIY(x1, y2)
    local texture, thickness = Texture:getWhite(), 2
    self.mapUI.javaObject:DrawLine(texture, uiX1, uiY1, uiX2, uiY2, thickness, r, g, b, a)
    self.mapUI.javaObject:DrawLine(texture, uiX2, uiY2, uiX3, uiY3, thickness, r, g, b, a)
    self.mapUI.javaObject:DrawLine(texture, uiX3, uiY3, uiX4, uiY4, thickness, r, g, b, a)
    self.mapUI.javaObject:DrawLine(texture, uiX4, uiY4, uiX1, uiY1, thickness, r, g, b, a)
end

function Mode:render()
    for _, zone in ipairs(SO.Client.Zones) do
        self:renderRect(zone.x1, zone.y1, zone.x2, zone.y2, 0.55, 0.0, 0.0, 0.85)
        local uiX, uiY = self.mapAPI:worldToUIX(zone.x1, zone.y1), self.mapAPI:worldToUIY(zone.x1, zone.y1)
        self:drawText(zone.name, uiX + 4, uiY + 2, 0.35, 0, 0, 1, UIFont.Small)
    end
    self:renderResizer()
    if self.mode == "StartDrawingBounds" then
        local worldX = self.resizer:snap(self.mapAPI:uiToWorldX(self.mapUI:getMouseX(), self.mapUI:getMouseY()))
        local worldY = self.resizer:snap(self.mapAPI:uiToWorldY(self.mapUI:getMouseX(), self.mapUI:getMouseY()))
        local mx, my = self.mapAPI:worldToUIX(worldX, worldY), self.mapAPI:worldToUIY(worldX, worldY)
        self.mapUI:drawRectBorder(mx - 10, my - 10, 20, 20, 1, 0.45, 0, 0)
    end
    if self.invalidReason then
        self:drawText(getText("IGUI_SO_ZoneOverlap"), UI_BORDER_SPACING, self.removeAllButton:getBottom() + 8,
            1, 0.25, 0.25, 1, UIFont.Small)
    end
end

function Mode:renderResizer()
    local r, g, b, a = 0.15, 0.15, 0.15, 1
    self.invalidReason = nil
    if self.mode == "DrawBounds" or self.mode == "Resize" then
        local rect = SO.Util.NormalizeRect(self.resizer.x1, self.resizer.y1, self.resizer.x2, self.resizer.y2)
        local valid, reason = false, "coordinates"
        if rect then valid, reason = SO.ClientZoneRules.CheckTemplePlacement(rect, self.mode == "Resize" and self.selectedZoneId or nil) end
        if not valid then r, g, b, self.invalidReason = 1, 0, 0, reason end
    end
    self.resizer:render(r, g, b, a)
end

function Mode:fillList()
    -- Rebuild only when the synced zone set actually changed. ISScrollingListBox:clear()
    -- forces selected = 1, so rebuilding every frame made an existing temple
    -- perpetually re-select itself; keeping the list stable lets a real click stick.
    if self.builtRevision == SO.Client.ZoneRevision and not self.delaySelectId then return end
    self.builtRevision = SO.Client.ZoneRevision
    local selectedId = self.delaySelectId or self.selectedZoneId
    self.delaySelectId = nil
    self.listbox:clear()
    for _, zone in ipairs(SO.Client.Zones) do
        self.listbox:addItem(zone.name, zone)
    end
    self.listbox:sort()
    self.listbox.selected = 0
    for index, entry in ipairs(self.listbox.items) do
        if tonumber(entry.item.id) == tonumber(selectedId) then self.listbox.selected = index end
    end
end

function Mode:getSelectedZone()
    local entry = self.listbox.items[self.listbox.selected]
    return entry and entry.item or nil
end

function Mode:onMouseDown(x, y)
    if self.mode == "StartDrawingBounds" then
        self.mode = "DrawBounds"
        local worldX = self.resizer:snap(self.mapAPI:uiToWorldX(x, y))
        local worldY = self.resizer:snap(self.mapAPI:uiToWorldY(x, y))
        self.resizer:setBounds(worldX, worldY, worldX, worldY)
        self.resizer:startResizing()
        return true
    end
    if self:getSelectedZone() then
        local resizeMode = self.resizer:hitTest(x, y)
        if not resizeMode then return false end
        self.resizer:startResizing()
        self.mode = "Resize"
        self.resizeMode = resizeMode
        return true
    end
    return false
end

function Mode:onMouseMove(dx, dy)
    if self.mode == "DrawBounds" then
        self.resizer:onMouseMove(self:getMouseX(), self:getMouseY(), "BottomRight")
        return true
    end
    if self.mode == "Resize" then
        self.resizer:onMouseMove(self:getMouseX(), self:getMouseY(), self.resizeMode)
        return true
    end
    return self.mode ~= nil
end

function Mode:onMouseUp(x, y)
    if self.mode == "DrawBounds" then
        self.mode = nil
        local rect = SO.Util.NormalizeRect(self.resizer.x1, self.resizer.y1, self.resizer.x2, self.resizer.y2)
        local valid = rect and SO.ClientZoneRules.CheckTemplePlacement(rect)
        self.resizer:endResizing()
        if valid then self:createNewZone(rect) else self.selectedZoneId = nil end
        return true
    end
    if self.mode == "Resize" then
        self.mode, self.resizeMode = nil, nil
        local zone = self:getSelectedZone()
        local rect = SO.Util.NormalizeRect(self.resizer.x1, self.resizer.y1, self.resizer.x2, self.resizer.y2)
        local valid = zone and rect and SO.ClientZoneRules.CheckTemplePlacement(rect, zone.id)
        self.resizer:endResizing()
        if valid then
            SO.Client.SendCommand(SO.COMMAND.RESIZE_ZONE, {
                tx = SO.Util.NewTransactionId("zone-resize", getPlayer()),
                zoneId = zone.id,
                x1 = rect.x1, y1 = rect.y1, x2 = rect.x2, y2 = rect.y2,
            })
            self.delaySelectId = zone.id
        else
            self.selectedZoneId = nil
        end
        return true
    end
    return false
end

function Mode:onMouseUpOutside(x, y) return self:onMouseUp(x, y) end
function Mode:onRightMouseDown(x, y) return self:cancelResize() end

function Mode:onKeyRelease(key)
    if key == Keyboard.KEY_ESCAPE then return self:cancelResize() end
    return false
end

function Mode:cancelResize()
    if self.mode == "DrawBounds" then
        self.mode = nil
        self.resizer:endResizing()
        self.selectedZoneId = nil
        return true
    end
    if self.mode == "Resize" then
        self.mode, self.resizeMode = nil, nil
        self.resizer:cancelResize()
        return true
    end
    if self.mode == "StartDrawingBounds" then
        self.mode = nil
        self.selectedZoneId = nil
        return true
    end
    return false
end

function Mode:selectedZoneChanged()
    if self.modalUI then
        self.modalUI:close()
        self.modalUI:setVisible(false)
        self.modalUI:removeFromUIManager()
        self.modalUI = nil
    end
    self:cancelResize()
end

function Mode:onAddZone()
    if self.mode == "StartDrawingBounds" then
        self.mode = nil
        self.selectedZoneId = nil
        return
    end
    self.listbox.selected = 0
    self.selectedZoneId = nil
    self.mode = "StartDrawingBounds"
    self.resizer:setBounds(0, 0, 0, 0)
end

function Mode:createNewZone(rect)
    self.pendingRect = rect
    local defaultName = "Satanic Temple " .. tostring(#SO.Client.Zones + 1)
    local modal = ISTextBox:new(0, 0, 300, 180, getText("IGUI_SO_TempleNamePrompt"), defaultName, self, self.onNewZoneNameEntered, nil)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    self.modalUI = modal
end

function Mode:onNewZoneNameEntered(button)
    local rect = self.pendingRect
    self.pendingRect = nil
    if button.internal ~= "OK" or not rect then return end
    SO.Client.SendCommand(SO.COMMAND.CREATE_ZONE, {
        tx = SO.Util.NewTransactionId("zone-create", getPlayer()),
        name = button.parent.entry:getText(),
        x1 = rect.x1, y1 = rect.y1, x2 = rect.x2, y2 = rect.y2,
    })
end

function Mode:onRenameZone()
    local zone = self:getSelectedZone()
    if not zone then return end
    local modal = ISTextBox:new(self.renameButton:getRight() + 20, self.renameButton:getY(), 300, 180,
        getText("IGUI_SO_TempleNamePrompt"), zone.name, self, self.onExistingZoneNameEntered, nil)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    modal.zoneId = zone.id
    self.modalUI = modal
end

function Mode:onExistingZoneNameEntered(button)
    if button.internal ~= "OK" then return end
    SO.Client.SendCommand(SO.COMMAND.RENAME_ZONE, {
        tx = SO.Util.NewTransactionId("zone-rename", getPlayer()),
        zoneId = button.parent.zoneId,
        name = button.parent.entry:getText(),
    })
    self.delaySelectId = button.parent.zoneId
end

function Mode:onRemoveZone()
    local zone = self:getSelectedZone()
    if not zone then return end
    local modal = ISModalDialog:new(self.removeButton:getRight() + 20, self.removeButton:getY(), 380, 160,
        getText("IGUI_SO_RemoveTempleConfirm", zone.name), true, self, self.onConfirmRemoveZone)
    modal:initialise()
    modal:addToUIManager()
    modal.zoneId = zone.id
    modal:setAlwaysOnTop(true)
    self.modalUI = modal
end

function Mode:onConfirmRemoveZone(button)
    if button.internal ~= "YES" then return end
    SO.Client.SendCommand(SO.COMMAND.DELETE_ZONE, {
        tx = SO.Util.NewTransactionId("zone-delete", getPlayer()),
        zoneId = button.parent.zoneId,
    })
    self.selectedZoneId = nil
end

function Mode:onRemoveAllZones()
    if #SO.Client.Zones == 0 then return end
    local modal = ISModalDialog:new(self.removeAllButton:getRight() + 20, self.removeAllButton:getY(), 420, 170,
        getText("IGUI_SO_RemoveAllTemplesConfirm", tostring(#SO.Client.Zones)), true, self, self.onConfirmRemoveAllZones)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    self.modalUI = modal
end

function Mode:onConfirmRemoveAllZones(button)
    if button.internal ~= "YES" then return end
    SO.Client.SendCommand(SO.COMMAND.PURGE_ZONES, {
        tx = SO.Util.NewTransactionId("zone-purge", getPlayer()),
    })
    self.selectedZoneId = nil
end

function Mode:undisplay()
    if self.modalUI then
        self.modalUI:close()
        self.modalUI:setVisible(false)
        self.modalUI:removeFromUIManager()
        self.modalUI = nil
    end
    self.selectedZoneId = nil
    self:cancelResize()
    MultiplayerZoneEditorMode.undisplay(self)
end

function Mode:new(editor)
    local object = MultiplayerZoneEditorMode.new(self, editor)
    object.resizer = WorldMapEditorResizer:new(editor)
    object.resizer.snapMode = "square"
    return object
end

return Mode
