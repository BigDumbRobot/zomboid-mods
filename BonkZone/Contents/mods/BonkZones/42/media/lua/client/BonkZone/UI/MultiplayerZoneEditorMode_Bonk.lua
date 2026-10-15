require "ISUI/AdminPanel/ZoneEditor/MultiplayerZoneEditorMode"
require "ISUI/Maps/Editor/WorldMapEditorResizer"
require "ISUI/ISTextBox"
require "ISUI/ISModalDialog"
require "BonkZone/BonkZone_Constants"
require "BonkZone/BonkZone_Logger"
require "BonkZone/BonkZone_Registry"
require "BonkZone/BonkZone_Network"

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local UI_BORDER_SPACING = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6

MultiplayerZoneEditorMode_Bonk = MultiplayerZoneEditorMode:derive("MultiplayerZoneEditorMode_Bonk")

local Logger = BonkZone.Logger
local Registry = BonkZone.Registry
local Network = BonkZone.Network

function MultiplayerZoneEditorMode_Bonk:createChildren()
    local startedAt = Logger.Begin("EditorMode.createChildren")
    local rows = 7
    self.listbox = ISScrollingListBox:new(UI_BORDER_SPACING, self.editor.modeCombo:getBottom() + UI_BORDER_SPACING, 320, (FONT_HGT_SMALL + 3 * 2) * rows)
    self.listbox:setFont(UIFont.Small, 3)
    self:addChild(self.listbox)

    self.addButton = ISButton:new(UI_BORDER_SPACING, self.listbox:getBottom() + UI_BORDER_SPACING, 80, BUTTON_HGT, getText("IGUI_BonkZone_Add"), self, MultiplayerZoneEditorMode_Bonk.onAddZone)
    self.addButton:setWidthToTitle()
    self:addChild(self.addButton)

    self.renameButton = ISButton:new(UI_BORDER_SPACING, self.addButton:getBottom() + UI_BORDER_SPACING, 80, BUTTON_HGT, getText("IGUI_BonkZone_Rename"), self, MultiplayerZoneEditorMode_Bonk.onRenameZone)
    self.renameButton:setWidthToTitle()
    self:addChild(self.renameButton)

    self.removeButton = ISButton:new(UI_BORDER_SPACING, self.renameButton:getBottom() + UI_BORDER_SPACING, 80, BUTTON_HGT, getText("IGUI_BonkZone_Remove"), self, MultiplayerZoneEditorMode_Bonk.onRemoveZone)
    self.removeButton:setWidthToTitle()
    self:addChild(self.removeButton)
    Logger.Finish("EditorMode.createChildren", startedAt, true)
end

function MultiplayerZoneEditorMode_Bonk:prerender()
    self:fillList()
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
    Logger.RateLimited("TRACE", "EditorMode.prerender", 5000, "EditorMode.prerender", "render preparation", { selected = zoneId or "" })
end

function MultiplayerZoneEditorMode_Bonk:render()
    local color = BonkZone.Constants.MAP_COLOR
    for _, zone in ipairs(Registry.GetZones()) do
        self:renderRect(zone.x1, zone.y1, zone.x2, zone.y2, color.r, color.g, color.b, color.a)
        local uiX = self.mapAPI:worldToUIX(zone.x1, zone.y1)
        local uiY = self.mapAPI:worldToUIY(zone.x1, zone.y1)
        self:drawText("BONK: " .. zone.name, uiX + 4, uiY + 2, color.r, color.g, color.b, 1, UIFont.Small)
    end
    self:renderResizer()
    if self.mode == "StartDrawingBounds" then
        local mouseX = self.mapUI:getMouseX()
        local mouseY = self.mapUI:getMouseY()
        local worldX = self.resizer:snap(self.mapAPI:uiToWorldX(mouseX, mouseY))
        local worldY = self.resizer:snap(self.mapAPI:uiToWorldY(mouseX, mouseY))
        mouseX = self.mapAPI:worldToUIX(worldX, worldY)
        mouseY = self.mapAPI:worldToUIY(worldX, worldY)
        self.mapUI:drawRectBorder(mouseX - 10, mouseY - 10, 20, 20, 1, color.r, color.g, color.b)
        self.mapUI:drawRectBorder(mouseX - 11, mouseY - 11, 22, 22, 1, color.r, color.g, color.b)
    end
    Logger.RateLimited("TRACE", "EditorMode.render", 5000, "EditorMode.render", "rendered", { zones = #Registry.GetZones() })
end

function MultiplayerZoneEditorMode_Bonk:renderResizer()
    local red, green, blue, alpha = 0, 0, 0, 1
    if self.mode == "DrawBounds" or self.mode == "Resize" then
        if not self:isZoneSizeValid(self.resizer.x1, self.resizer.y1, self.resizer.x2, self.resizer.y2) then red = 1 end
    end
    self.resizer:render(red, green, blue, alpha)
    Logger.RateLimited("TRACE", "EditorMode.renderResizer", 5000, "EditorMode.renderResizer", "rendered", { mode = self.mode or "none" })
end

function MultiplayerZoneEditorMode_Bonk:renderRect(x1, y1, x2, y2, red, green, blue, alpha)
    local uiX1 = self.mapAPI:worldToUIX(x1, y1)
    local uiY1 = self.mapAPI:worldToUIY(x1, y1)
    local uiX2 = self.mapAPI:worldToUIX(x2, y1)
    local uiY2 = self.mapAPI:worldToUIY(x2, y1)
    local uiX3 = self.mapAPI:worldToUIX(x2, y2)
    local uiY3 = self.mapAPI:worldToUIY(x2, y2)
    local uiX4 = self.mapAPI:worldToUIX(x1, y2)
    local uiY4 = self.mapAPI:worldToUIY(x1, y2)
    local thickness = 2
    self.mapUI.javaObject:DrawLine(Texture:getWhite(), uiX1, uiY1, uiX2, uiY2, thickness, red, green, blue, alpha)
    self.mapUI.javaObject:DrawLine(Texture:getWhite(), uiX2, uiY2, uiX3, uiY3, thickness, red, green, blue, alpha)
    self.mapUI.javaObject:DrawLine(Texture:getWhite(), uiX3, uiY3, uiX4, uiY4, thickness, red, green, blue, alpha)
    self.mapUI.javaObject:DrawLine(Texture:getWhite(), uiX4, uiY4, uiX1, uiY1, thickness, red, green, blue, alpha)
    Logger.RateLimited("TRACE", "EditorMode.renderRect", 5000, "EditorMode.renderRect", "rectangle rendered")
end

function MultiplayerZoneEditorMode_Bonk:fillList()
    local selected = self:getSelectedZone()
    local selectedId = selected and selected.id or self.pendingSelectId
    local pendingName = self.pendingSelectName
    self.listbox:clear()
    for _, zone in ipairs(Registry.GetZones()) do self.listbox:addItem(zone.name, zone) end
    self.listbox:sort()
    for index, row in ipairs(self.listbox.items) do
        local zone = row.item
        if (selectedId and zone.id == selectedId) or (not selectedId and pendingName and zone.name == pendingName) then
            self.listbox.selected = index
            self.pendingSelectId = nil
            self.pendingSelectName = nil
            break
        end
    end
    Logger.RateLimited("TRACE", "EditorMode.fillList", 2000, "EditorMode.fillList", "list refreshed", { count = #Registry.GetZones() })
end

function MultiplayerZoneEditorMode_Bonk:getSelectedZone()
    local item = self.listbox.items[self.listbox.selected]
    local zone = item and item.item or nil
    Logger.RateLimited("TRACE", "EditorMode.getSelectedZone", 2000, "EditorMode.getSelectedZone", "selection read", { id = zone and zone.id or "" })
    return zone
end

function MultiplayerZoneEditorMode_Bonk:display()
    local startedAt = Logger.Begin("EditorMode.display")
    MultiplayerZoneEditorMode.display(self)
    Network.RequestSync(true)
    Logger.Finish("EditorMode.display", startedAt, true)
end

function MultiplayerZoneEditorMode_Bonk:undisplay()
    local startedAt = Logger.Begin("EditorMode.undisplay")
    if self.modalUI then
        self.modalUI:close()
        self.modalUI:setVisible(false)
        self.modalUI:removeFromUIManager()
        self.modalUI = nil
    end
    self.selectedZoneId = nil
    self:cancelResize()
    MultiplayerZoneEditorMode.undisplay(self)
    Logger.Finish("EditorMode.undisplay", startedAt, true)
end

function MultiplayerZoneEditorMode_Bonk:onMouseDown(x, y)
    local startedAt = Logger.Begin("EditorMode.onMouseDown", { mode = self.mode })
    if self.mode == "StartDrawingBounds" then
        self.mode = "DrawBounds"
        local worldX = self.resizer:snap(self.mapAPI:uiToWorldX(x, y))
        local worldY = self.resizer:snap(self.mapAPI:uiToWorldY(x, y))
        self.resizer:setBounds(worldX, worldY, worldX, worldY)
        self.resizer:startResizing()
        Logger.Finish("EditorMode.onMouseDown", startedAt, true, "drawing")
        return true
    end
    if self:getSelectedZone() then
        local resizeMode = self.resizer:hitTest(x, y)
        if not resizeMode then
            Logger.Finish("EditorMode.onMouseDown", startedAt, true, "map click")
            return false
        end
        self.resizer:startResizing()
        self.mode = "Resize"
        self.resizeMode = resizeMode
        Logger.Finish("EditorMode.onMouseDown", startedAt, true, "resize")
        return true
    end
    Logger.Finish("EditorMode.onMouseDown", startedAt, true, "unhandled")
    return false
end

function MultiplayerZoneEditorMode_Bonk:onMouseUp(x, y)
    local startedAt = Logger.Begin("EditorMode.onMouseUp", { mode = self.mode })
    if self.mode == "DrawBounds" then
        self.mode = nil
        local x1, y1, x2, y2 = self.resizer.x1, self.resizer.y1, self.resizer.x2, self.resizer.y2
        if self:isZoneSizeValid(x1, y1, x2, y2) then
            self:createNewZone(x1, y1, x2, y2)
        else
            self.selectedZoneId = nil
        end
        self.resizer:endResizing()
        Logger.Finish("EditorMode.onMouseUp", startedAt, true, "draw complete")
        return true
    end
    if self.mode == "Resize" then
        self.mode = nil
        self.resizeMode = nil
        local x1, y1, x2, y2 = self.resizer.x1, self.resizer.y1, self.resizer.x2, self.resizer.y2
        if self:isZoneSizeValid(x1, y1, x2, y2) then self:setZoneBounds(x1, y1, x2, y2) end
        self.resizer:endResizing()
        Logger.Finish("EditorMode.onMouseUp", startedAt, true, "resize complete")
        return true
    end
    Logger.Finish("EditorMode.onMouseUp", startedAt, true, "unhandled")
    return false
end

function MultiplayerZoneEditorMode_Bonk:onMouseUpOutside(x, y)
    local result = self:onMouseUp(x, y)
    Logger.Trace("EditorMode.onMouseUpOutside", "delegated", { result = result })
    return result
end

function MultiplayerZoneEditorMode_Bonk:onMouseMove(dx, dy)
    if self.mode == "DrawBounds" then
        self.resizer:onMouseMove(self:getMouseX(), self:getMouseY(), "BottomRight")
        Logger.RateLimited("TRACE", "EditorMode.onMouseMove.draw", 1000, "EditorMode.onMouseMove", "drawing")
        return true
    end
    if self.mode == "Resize" then
        self.resizer:onMouseMove(self:getMouseX(), self:getMouseY(), self.resizeMode)
        Logger.RateLimited("TRACE", "EditorMode.onMouseMove.resize", 1000, "EditorMode.onMouseMove", "resizing")
        return true
    end
    Logger.RateLimited("TRACE", "EditorMode.onMouseMove.idle", 5000, "EditorMode.onMouseMove", "idle")
    return self.mode ~= nil
end

function MultiplayerZoneEditorMode_Bonk:onRightMouseDown(x, y)
    local result = self:cancelResize()
    Logger.Trace("EditorMode.onRightMouseDown", "cancel requested", { result = result })
    return result
end

function MultiplayerZoneEditorMode_Bonk:onKeyRelease(key)
    local result = key == Keyboard.KEY_ESCAPE and self:cancelResize() or false
    Logger.Trace("EditorMode.onKeyRelease", "key released", { key = key, consumed = result })
    return result
end

function MultiplayerZoneEditorMode_Bonk:selectedZoneChanged()
    local startedAt = Logger.Begin("EditorMode.selectedZoneChanged")
    if self.modalUI then
        self.modalUI:close()
        self.modalUI:setVisible(false)
        self.modalUI:removeFromUIManager()
        self.modalUI = nil
    end
    self:cancelResize()
    Logger.Finish("EditorMode.selectedZoneChanged", startedAt, true)
end

function MultiplayerZoneEditorMode_Bonk:cancelResize()
    local startedAt = Logger.Begin("EditorMode.cancelResize", { mode = self.mode })
    if self.mode == "DrawBounds" then
        self.mode = nil
        self.resizer:endResizing()
        self.selectedZoneId = nil
        Logger.Finish("EditorMode.cancelResize", startedAt, true, "drawing")
        return true
    end
    if self.mode == "Resize" then
        self.mode = nil
        self.resizeMode = nil
        self.resizer:cancelResize()
        Logger.Finish("EditorMode.cancelResize", startedAt, true, "resize")
        return true
    end
    if self.mode == "StartDrawingBounds" then
        self.mode = nil
        self.selectedZoneId = nil
        Logger.Finish("EditorMode.cancelResize", startedAt, true, "start")
        return true
    end
    Logger.Finish("EditorMode.cancelResize", startedAt, true, "nothing")
    return false
end

function MultiplayerZoneEditorMode_Bonk:isZoneSizeValid(x1, y1, x2, y2)
    local result = BonkZone.Constants.IsBoundsValid(x1, y1, x2, y2)
    Logger.Trace("EditorMode.isZoneSizeValid", "validated", { result = result })
    return result
end

function MultiplayerZoneEditorMode_Bonk:createNewZone(x1, y1, x2, y2)
    local startedAt = Logger.Begin("EditorMode.createNewZone")
    self.pendingBounds = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
    local modal = ISTextBox:new(0, 0, 300, 180, getText("IGUI_BonkZone_NamePrompt"), BonkZone.Constants.DEFAULT_ZONE_NAME, self, MultiplayerZoneEditorMode_Bonk.onNewZoneNameEntered, nil)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    self.modalUI = modal
    Logger.Finish("EditorMode.createNewZone", startedAt, true)
end

function MultiplayerZoneEditorMode_Bonk:onNewZoneNameEntered(button)
    local startedAt = Logger.Begin("EditorMode.onNewZoneNameEntered")
    self.selectedZoneId = nil
    if button.internal == "OK" and self.pendingBounds then
        local name = button.parent.entry:getText()
        local bounds = self.pendingBounds
        self.pendingSelectName = BonkZone.Constants.NormalizeName(name)
        Network.AddZone(name, bounds.x1, bounds.y1, bounds.x2, bounds.y2)
    end
    self.pendingBounds = nil
    self.modalUI = nil
    Logger.Finish("EditorMode.onNewZoneNameEntered", startedAt, true, { button = button.internal })
end

function MultiplayerZoneEditorMode_Bonk:setZoneBounds(x1, y1, x2, y2)
    local startedAt = Logger.Begin("EditorMode.setZoneBounds")
    local zone = self:getSelectedZone()
    if zone then
        self.pendingSelectId = zone.id
        Network.UpdateZone(zone.id, x1, y1, x2, y2)
    end
    Logger.Finish("EditorMode.setZoneBounds", startedAt, zone ~= nil)
end

function MultiplayerZoneEditorMode_Bonk:onAddZone()
    local startedAt = Logger.Begin("EditorMode.onAddZone", { mode = self.mode })
    if self.mode == "StartDrawingBounds" then
        self.mode = nil
        self.selectedZoneId = nil
    else
        self.mode = "StartDrawingBounds"
        self.resizer:setBounds(0, 0, 0, 0)
    end
    Logger.Finish("EditorMode.onAddZone", startedAt, true, { mode = self.mode })
end

function MultiplayerZoneEditorMode_Bonk:onRenameZone()
    local startedAt = Logger.Begin("EditorMode.onRenameZone")
    local zone = self:getSelectedZone()
    if not zone then
        Logger.Finish("EditorMode.onRenameZone", startedAt, false, "no selection")
        return
    end
    local modal = ISTextBox:new(self.renameButton:getRight() + 20, self.renameButton:getY(), 300, 180, getText("IGUI_BonkZone_NamePrompt"), zone.name, self, MultiplayerZoneEditorMode_Bonk.onExistingZoneNameEntered, nil)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    modal.zoneId = zone.id
    self.modalUI = modal
    Logger.Finish("EditorMode.onRenameZone", startedAt, true)
end

function MultiplayerZoneEditorMode_Bonk:onExistingZoneNameEntered(button)
    local startedAt = Logger.Begin("EditorMode.onExistingZoneNameEntered")
    local modal = button.parent
    if button.internal == "OK" and modal.zoneId then
        self.pendingSelectId = modal.zoneId
        Network.RenameZone(modal.zoneId, modal.entry:getText())
    end
    self.modalUI = nil
    Logger.Finish("EditorMode.onExistingZoneNameEntered", startedAt, true, { button = button.internal })
end

function MultiplayerZoneEditorMode_Bonk:onRemoveZone()
    local startedAt = Logger.Begin("EditorMode.onRemoveZone")
    local zone = self:getSelectedZone()
    if not zone then
        Logger.Finish("EditorMode.onRemoveZone", startedAt, false, "no selection")
        return
    end
    local modal = ISModalDialog:new(self.removeButton:getRight() + 20, self.removeButton:getY(), 360, 150, getText("IGUI_BonkZone_RemoveConfirm", zone.name), true, self, MultiplayerZoneEditorMode_Bonk.onConfirmRemoveZone)
    modal:initialise()
    modal:addToUIManager()
    modal.zoneId = zone.id
    modal.moveWithMouse = true
    modal:setAlwaysOnTop(true)
    self.modalUI = modal
    Logger.Finish("EditorMode.onRemoveZone", startedAt, true)
end

function MultiplayerZoneEditorMode_Bonk:onConfirmRemoveZone(button)
    local startedAt = Logger.Begin("EditorMode.onConfirmRemoveZone")
    local modal = button.parent
    if button.internal == "YES" and modal.zoneId then Network.RemoveZone(modal.zoneId) end
    self.selectedZoneId = nil
    self.modalUI = nil
    Logger.Finish("EditorMode.onConfirmRemoveZone", startedAt, true, { button = button.internal })
end

function MultiplayerZoneEditorMode_Bonk:new(editor)
    local startedAt = Logger.Begin("EditorMode.new")
    local object = MultiplayerZoneEditorMode.new(self, editor)
    object.snapMode = "square"
    object.resizer = WorldMapEditorResizer:new(editor)
    object.resizer.snapMode = object.snapMode
    Logger.Finish("EditorMode.new", startedAt, true)
    return object
end

return MultiplayerZoneEditorMode_Bonk
