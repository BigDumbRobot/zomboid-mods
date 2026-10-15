-- KIPN_SafehouseAreaUI.lua
-- Read-only, panel-bound safehouse boundary viewer.
-- Uses Build 42's area-highlight renderer, re-added every frame.

if isServer() then return end

require "ISUI/ISPanelJoypad"

KIPN_SafehouseAreaUI = ISPanelJoypad:derive("KIPN_SafehouseAreaUI")
KIPN_SafehouseAreaUI.instance = nil

local PAD = 10
local TITLEBAR_HGT = 16
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local BUTTON_HGT = FONT_HGT_SMALL + 6

local function rectOf(safehouse)
    if not safehouse then return nil end
    local ok, rect = pcall(function()
        return {
            x = tonumber(safehouse:getX()),
            y = tonumber(safehouse:getY()),
            w = tonumber(safehouse:getW()),
            h = tonumber(safehouse:getH()),
        }
    end)
    if not ok or not rect or not rect.x or not rect.y or not rect.w or not rect.h then return nil end
    return rect
end

function KIPN_SafehouseAreaUI.open(player, safehouse)
    if not player or not safehouse then return end
    local target = rectOf(safehouse)
    if not target then return end

    if KIPN_SafehouseAreaUI.instance then KIPN_SafehouseAreaUI.instance:close() end

    local owner = ""
    pcall(function() owner = tostring(safehouse:getOwner() or "") end)
    local ui = KIPN_SafehouseAreaUI:new(120, 220, 260, 100, player, target, owner)
    ui:initialise()
    ui:addToUIManager()
    KIPN_SafehouseAreaUI.instance = ui
end

function KIPN_SafehouseAreaUI:new(x, y, width, height, player, target, owner)
    local o = ISPanelJoypad:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.playerNum = player:getPlayerNum()
    o.target = target
    o.owner = owner
    o.titlebarbkg = getTexture("media/ui/Panel_TitleBar.png")
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.moveWithMouse = true
    return o
end

function KIPN_SafehouseAreaUI:initialise()
    ISPanelJoypad.initialise(self)
    local button = ISButton:new(PAD, TITLEBAR_HGT + PAD + FONT_HGT_SMALL + PAD,
        80, BUTTON_HGT, getText("UI_Ok"), self, KIPN_SafehouseAreaUI.onClick)
    button.internal = "CLOSE"
    button:initialise()
    button:instantiate()
    self:addChild(button)
    self:setHeight(button:getBottom() + PAD)
end

function KIPN_SafehouseAreaUI:onClick(button)
    if button.internal == "CLOSE" then self:close() end
end

function KIPN_SafehouseAreaUI:close()
    KIPN_SafehouseAreaUI.instance = nil
    self:setVisible(false)
    self:removeFromUIManager()
end

function KIPN_SafehouseAreaUI:prerender()
    self:drawRect(0, 0, self.width, self.height,
        self.backgroundColor.a, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b)
    if self.titlebarbkg then
        self:drawTextureScaled(self.titlebarbkg, 2, 1, self:getWidth() - 4, TITLEBAR_HGT - 2, 1, 1, 1, 1)
    end
    self:drawRectBorder(0, 0, self.width, self.height,
        self.borderColor.a, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    self:drawTextCentre("KIPN Safehouse Bounds", self.width / 2, 1, 1, 1, 1, 1, UIFont.Small)
    self:drawText("Owner: " .. tostring(self.owner), PAD, TITLEBAR_HGT + PAD, 0.7, 0.7, 0.9, 1, UIFont.Small)
end

function KIPN_SafehouseAreaUI:render()
    local r = self.target
    if not r or not self.player then return end
    addAreaHighlightForPlayer(
        self.playerNum,
        r.x, r.y,
        r.x + r.w, r.y + r.h,
        self.player:getZi(),
        0.25, 0.65, 1.0, 0.22
    )
end

Events.OnSafehousesChanged.Add(function()
    local ui = KIPN_SafehouseAreaUI.instance
    if not ui then return end
    if not SafeHouse then
        ui:close()
        return
    end
    local r = ui.target
    local ok, safehouse = pcall(function()
        return SafeHouse.getSafeHouse(r.x, r.y, r.w, r.h)
    end)
    if not ok or not safehouse then ui:close() end
end)

print("[KIPN] Safehouse boundary viewer loaded")
