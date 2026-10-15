require "ISUI/ISContextMenu"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "KIPNCareers_Shared"
require "KIPNCareers_MechanicShared"

local Shared = KIPNCareers.Shared
local Mechanic = KIPNCareers.Mechanic
KIPNCareers.Client = KIPNCareers.Client or {}
local Client = KIPNCareers.Client

local function send(command, arguments)
    if Client.mechanicSend then Client.mechanicSend(command, arguments) return end
    sendClientCommand(Mechanic.MODULE, command, arguments or {})
end

local function playerFor(index)
    return type(getSpecificPlayer) == "function" and getSpecificPlayer(index) or nil
end

local function collectItems(container, fullType, output)
    output = output or {}
    if not container then return output end
    local items = container:getItems()
    for index = 0, items:size() - 1 do
        local item = items:get(index)
        if item:getFullType() == fullType then output[#output + 1] = item end
        local ok, nested = pcall(function() return type(item.getInventory) == "function" and item:getInventory() or nil end)
        if ok and nested then collectItems(nested, fullType, output) end
    end
    return output
end

local function pointInBounds(bounds, x, y, z)
    if type(bounds) ~= "table" then return false end
    return x >= bounds.x1 and x <= bounds.x2 and y >= bounds.y1 and y <= bounds.y2
        and z >= (bounds.z1 or 0) and z <= (bounds.z2 or 8)
end

------------------------------------------------------------
-- Work Order UI
------------------------------------------------------------

KIPNCareers_MechanicWorkOrderUI = ISPanel:derive("KIPNCareers_MechanicWorkOrderUI")

local ROW_HEIGHT = 30
local MAX_ROWS = Mechanic.Defaults.MAX_REPAIRS_PER_ORDER

function KIPNCareers_MechanicWorkOrderUI:new()
    local width, height = 560, 560
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local panel = ISPanel.new(self, x, y, width, height)
    setmetatable(panel, self)
    self.__index = self
    panel.backgroundColor = { r = 0.06, g = 0.08, b = 0.06, a = 0.98 }
    panel.borderColor = { r = 0.35, g = 0.85, b = 0.4, a = 1 }
    panel.moveWithMouse = true
    panel.rows = {}
    panel.quotes = nil
    panel.selectedTier = Mechanic.Tiers.REGULAR
    panel.statusText = "Enter the parts you need repaired."
    return panel
end

function KIPNCareers_MechanicWorkOrderUI:initialise()
    ISPanel.initialise(self)
    self.title = ISLabel:new(20, 16, 26, "MECHANIC WORK ORDER", 0.5, 0.95, 0.5, 1, UIFont.Large, true)
    self.title:initialise(); self:addChild(self.title)

    self.businessLabel = ISLabel:new(20, 52, 22, "Send to shop", 0.7, 0.9, 0.7, 1, UIFont.Small, true)
    self.businessLabel:initialise(); self:addChild(self.businessLabel)
    self.businessCombo = ISComboBox:new(150, 48, 380, 26, self, nil)
    self.businessCombo:initialise(); self.businessCombo:instantiate(); self:addChild(self.businessCombo)
    local snapshot = Client.mechanicSnapshot or {}
    for _, shop in ipairs(snapshot.shops or {}) do self.businessCombo:addOptionWithData(shop.name, shop.id) end
    if Client.mechanicPreferredShopId then
        for index, option in ipairs(self.businessCombo.options or {}) do
            if option.data == Client.mechanicPreferredShopId then self.businessCombo.selected = index break end
        end
    end

    self.headerPart = ISLabel:new(20, 84, 22, "Part", 0.7, 0.9, 0.7, 1, UIFont.Small, true)
    self.headerPart:initialise(); self:addChild(self.headerPart)
    self.headerQuality = ISLabel:new(360, 84, 22, "Quality %", 0.7, 0.9, 0.7, 1, UIFont.Small, true)
    self.headerQuality:initialise(); self:addChild(self.headerQuality)

    self.addRowButton = ISButton:new(20, self.height - 190, 150, 26, "+ ADD REPAIR", self, KIPNCareers_MechanicWorkOrderUI.onAddRow)
    self.addRowButton:initialise(); self.addRowButton:instantiate(); self:addChild(self.addRowButton)

    self.quoteButton = ISButton:new(180, self.height - 190, 150, 26, "GET QUOTES", self, KIPNCareers_MechanicWorkOrderUI.onGetQuotes)
    self.quoteButton:initialise(); self.quoteButton:instantiate(); self:addChild(self.quoteButton)

    self.tierButtons = {}
    local labels = { { Mechanic.Tiers.FAST, "FAST" }, { Mechanic.Tiers.REGULAR, "REGULAR" }, { Mechanic.Tiers.SLOW, "SLOW" } }
    for index, def in ipairs(labels) do
        local button = ISButton:new(20 + (index - 1) * 180, self.height - 150, 170, 44, def[2] .. "\n--", self, KIPNCareers_MechanicWorkOrderUI.onPickTier)
        button.tier = def[1]
        button:initialise(); button:instantiate(); button:setEnable(false)
        self:addChild(button)
        self.tierButtons[def[1]] = button
    end

    self.sendButton = ISButton:new(20, self.height - 92, 250, 28, "SEND WORK ORDER", self, KIPNCareers_MechanicWorkOrderUI.onSend)
    self.sendButton:initialise(); self.sendButton:instantiate(); self.sendButton:setEnable(false)
    self:addChild(self.sendButton)

    self.closeButton = ISButton:new(self.width - 120, self.height - 92, 100, 28, "CLOSE", self, KIPNCareers_MechanicWorkOrderUI.close)
    self.closeButton:initialise(); self.closeButton:instantiate(); self:addChild(self.closeButton)

    self:onAddRow()
end

function KIPNCareers_MechanicWorkOrderUI:onAddRow()
    if #self.rows >= MAX_ROWS then self.statusText = "Repair line limit reached." return end
    local y = 106 + #self.rows * ROW_HEIGHT
    local part = ISTextEntryBox:new("", 20, y, 320, 26)
    part:initialise(); part:instantiate(); self:addChild(part)
    local quality = ISTextEntryBox:new("100", 360, y, 80, 26)
    quality:initialise(); quality:instantiate(); quality:setOnlyNumbers(true); self:addChild(quality)
    local removeButton = ISButton:new(452, y, 80, 26, "REMOVE", self, KIPNCareers_MechanicWorkOrderUI.onRemoveRow)
    removeButton:initialise(); removeButton:instantiate(); self:addChild(removeButton)
    local row = { part = part, quality = quality, removeButton = removeButton }
    removeButton.row = row
    self.rows[#self.rows + 1] = row
    self:invalidateQuotes()
end

function KIPNCareers_MechanicWorkOrderUI:onRemoveRow(button)
    for index, row in ipairs(self.rows) do
        if row == button.row then
            self:removeChild(row.part); self:removeChild(row.quality); self:removeChild(row.removeButton)
            table.remove(self.rows, index)
            break
        end
    end
    self:relayoutRows()
    self:invalidateQuotes()
end

function KIPNCareers_MechanicWorkOrderUI:relayoutRows()
    for index, row in ipairs(self.rows) do
        local y = 106 + (index - 1) * ROW_HEIGHT
        row.part:setY(y); row.quality:setY(y); row.removeButton:setY(y)
    end
end

function KIPNCareers_MechanicWorkOrderUI:collectRepairs()
    local raw = {}
    for _, row in ipairs(self.rows) do
        raw[#raw + 1] = { part = row.part:getText(), quality = tonumber(row.quality:getText()) or Mechanic.Defaults.QUALITY_MAX }
    end
    return Mechanic.SanitizeRepairs(raw, MAX_ROWS)
end

function KIPNCareers_MechanicWorkOrderUI:targetShopId()
    local option = self.businessCombo and self.businessCombo.options and self.businessCombo.options[self.businessCombo.selected]
    return option and option.data or nil
end

function KIPNCareers_MechanicWorkOrderUI:invalidateQuotes()
    self.quotes = nil
    self.sendButton:setEnable(false)
    for _, button in pairs(self.tierButtons) do
        button:setEnable(false)
        button.title = string.upper(button.tier) .. "\n--"
    end
end

function KIPNCareers_MechanicWorkOrderUI:onGetQuotes()
    local repairs = self:collectRepairs()
    if not repairs then self.statusText = "Add at least one part name." return end
    local shopId = self:targetShopId()
    if not shopId then self.statusText = "Pick a shop to send the order to." return end
    self.statusText = "Requesting quotes..."
    send(Mechanic.Commands.QUOTE_ORDER, { repairs = repairs, targetShopId = shopId })
end

function KIPNCareers_MechanicWorkOrderUI:onQuote(data)
    if not data or type(data.quotes) ~= "table" then return end
    self.quotes = data.quotes
    local hours = data.tierHours or {}
    local map = { fast = data.quotes.fast, regular = data.quotes.regular, slow = data.quotes.slow }
    for tier, button in pairs(self.tierButtons) do
        local hrs = hours[tier]
        button.title = string.upper(tier) .. "\n" .. tostring(map[tier] or "?") .. (hrs and ("  /  " .. tostring(hrs) .. "h") or "")
        button:setEnable(true)
    end
    self.selectedTier = Mechanic.Tiers.REGULAR
    self.sendButton:setEnable(true)
    self.statusText = "Pick a turnaround and send. Payment is held in escrow."
end

function KIPNCareers_MechanicWorkOrderUI:onPickTier(button)
    self.selectedTier = button.tier
    self.statusText = "Selected " .. string.upper(button.tier) .. " turnaround."
end

function KIPNCareers_MechanicWorkOrderUI:onSend()
    if not self.quotes then self.statusText = "Get quotes first." return end
    local repairs = self:collectRepairs()
    if not repairs then self.statusText = "Add at least one part name." return end
    local shopId = self:targetShopId()
    if not shopId then self.statusText = "Pick a shop." return end
    send(Mechanic.Commands.SUBMIT_ORDER, { repairs = repairs, targetShopId = shopId, tier = self.selectedTier })
    self.statusText = "Work order sent."
    self:close()
end

function KIPNCareers_MechanicWorkOrderUI:prerender()
    ISPanel.prerender(self)
    self:drawText(tostring(self.statusText or ""), 20, self.height - 56, 0.5, 0.85, 0.5, 1, UIFont.Small)
    self:drawText("Lower requested quality lowers the price slightly.", 20, self.height - 214, 0.5, 0.7, 0.5, 1, UIFont.Small)
end

function KIPNCareers_MechanicWorkOrderUI:close()
    KIPNCareers_MechanicWorkOrderUI.instance = nil
    self:removeFromUIManager()
end

function KIPNCareers_MechanicWorkOrderUI.Open()
    if KIPNCareers_MechanicWorkOrderUI.instance then KIPNCareers_MechanicWorkOrderUI.instance:close() end
    local panel = KIPNCareers_MechanicWorkOrderUI:new()
    panel:initialise()
    panel:addToUIManager()
    KIPNCareers_MechanicWorkOrderUI.instance = panel
    return panel
end

------------------------------------------------------------
-- Flyer viewer
------------------------------------------------------------

KIPNCareers_MechanicFlyerViewer = ISPanel:derive("KIPNCareers_MechanicFlyerViewer")

function KIPNCareers_MechanicFlyerViewer:new(data)
    local width, height = 560, 460
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local panel = ISPanel.new(self, x, y, width, height)
    setmetatable(panel, self)
    self.__index = self
    panel.data = data or {}
    panel.backgroundColor = { r = 0.08, g = 0.09, b = 0.06, a = 0.98 }
    panel.borderColor = { r = 0.4, g = 0.8, b = 0.4, a = 1 }
    panel.moveWithMouse = true
    return panel
end

function KIPNCareers_MechanicFlyerViewer:initialise()
    ISPanel.initialise(self)
    self.title = ISLabel:new(22, 20, 30, tostring(self.data.kipnMechName or "SHOP FLYER"), 0.6, 0.95, 0.5, 1, UIFont.Large, true)
    self.title:initialise(); self:addChild(self.title)
    local text = "Proprietor: " .. tostring(self.data.kipnMechProprietor or "")
        .. "\n\n" .. tostring(self.data.kipnMechDescription or "")
        .. "\n\nSERVICES\n" .. tostring(self.data.kipnMechServices or "")
        .. "\n\nHOURS\n" .. tostring(self.data.kipnMechHours or "")
        .. "\n\nCONTACT\n" .. tostring(self.data.kipnMechContact or "")
        .. "\n\n" .. tostring(self.data.kipnMechAdText or "")
    self.body = ISTextEntryBox:new(text, 22, 70, self.width - 44, self.height - 126)
    self.body:initialise(); self.body:instantiate()
    self.body:setMultipleLine(true); self.body:setEditable(false)
    self:addChild(self.body)
    self.closeButton = ISButton:new(self.width - 122, self.height - 44, 100, 26, "CLOSE", self, KIPNCareers_MechanicFlyerViewer.close)
    self.closeButton:initialise(); self.closeButton:instantiate(); self:addChild(self.closeButton)
end

function KIPNCareers_MechanicFlyerViewer:close() self:removeFromUIManager() end

function KIPNCareers_MechanicFlyerViewer.Open(data)
    if KIPNCareers_MechanicFlyerViewer.instance then KIPNCareers_MechanicFlyerViewer.instance:close() end
    local viewer = KIPNCareers_MechanicFlyerViewer:new(data)
    viewer:initialise(); viewer:addToUIManager()
    KIPNCareers_MechanicFlyerViewer.instance = viewer
end

------------------------------------------------------------
-- World context menu
------------------------------------------------------------

local function startShop(player, tokenId)
    send(Mechanic.Commands.START_SHOP, { tokenId = tokenId, x = player:getX(), y = player:getY(), z = player:getZ() })
end

local function containerDescriptorFor(object)
    local descriptor = {}
    local container = type(object.getContainer) == "function" and object:getContainer() or nil
    if container and type(container.getType) == "function" then descriptor.type = tostring(container:getType() or "") end
    local sprite = type(object.getSprite) == "function" and object:getSprite() or nil
    if sprite and type(sprite.getName) == "function" then descriptor.sprite = tostring(sprite:getName() or "") end
    return descriptor
end

local function assignContainer(_t, params)
    send(Mechanic.Commands.SET_CONTAINER_TYPE, { containerType = params.kind, x = params.x, y = params.y, z = params.z, descriptor = params.descriptor })
end

local function clearContainer(_t, params)
    send(Mechanic.Commands.CLEAR_CONTAINER_TYPE, { x = params.x, y = params.y, z = params.z, descriptor = params.descriptor })
end

local function fillWorldContext(playerIndex, context, worldObjects, test)
    if test then return end
    local player = playerFor(playerIndex)
    if not player then return end
    local snapshot = Client.mechanicSnapshot or {}

    if not snapshot.shop and player:getSquare() and player:getSquare():getBuilding() then
        for _, license in ipairs(collectItems(player:getInventory(), Mechanic.Items.LICENSE, {})) do
            local tokenId = license:getModData().kipnMechToken
            if tokenId then
                context:addOption("Start Your Mechanic Shop (" .. tostring(tokenId) .. ")", player, startShop, tokenId)
            end
        end
    end

    local shop = snapshot.shop
    if shop and shop.bounds then
        for _, object in ipairs(worldObjects or {}) do
            if object and type(object.getContainer) == "function" and object:getContainer() then
                local square = object:getSquare()
                if square then
                    local x, y, z = square:getX(), square:getY(), square:getZ()
                    if pointInBounds(shop.bounds, x, y, z) then
                        local descriptor = containerDescriptorFor(object)
                        local params = { x = x, y = y, z = z, descriptor = descriptor }
                        local sub = ISContextMenu:getNew(context)
                        context:addSubMenu(context:addOption("Mechanic Business: Container", nil, nil), sub)
                        for _, kind in ipairs({ Mechanic.ContainerTypes.PRIVATE, Mechanic.ContainerTypes.PUBLIC, Mechanic.ContainerTypes.FORSALE }) do
                            sub:addOption("Set to " .. kind, nil, assignContainer, { kind = kind, x = x, y = y, z = z, descriptor = descriptor })
                        end
                        sub:addOption("Clear assignment (back to Private)", nil, clearContainer, params)
                        break
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- Inventory context menu
------------------------------------------------------------

local function unwrapInventoryItem(entry)
    if not entry then return nil end
    if type(entry.getFullType) == "function" then return entry end
    if entry.items and entry.items[1] then return entry.items[1] end
    return nil
end

local function fillOutWorkOrder(player, item)
    if not Client.mechanicSnapshot and Client.mechanicSend then Client.mechanicSend(Mechanic.Commands.SNAPSHOT, {}) end
    local data = item:getModData()
    if data.kipnMechShopId then Client.mechanicPreferredShopId = data.kipnMechShopId end
    KIPNCareers_MechanicWorkOrderUI.Open()
end

local function readFlyer(player, item)
    local data = item:getModData()
    Client.mechanicPreferredShopId = data.kipnMechShopId
    KIPNCareers_MechanicFlyerViewer.Open(data)
    player:Say("Selected " .. tostring(data.kipnMechName or "shop") .. " for your next Mechanic work order.")
end

local function fillInventoryContext(playerIndex, context, items)
    local player = playerFor(playerIndex)
    if not player then return end
    for _, entry in ipairs(items or {}) do
        local item = unwrapInventoryItem(entry)
        if item and item:getFullType() == Mechanic.Items.WORK_ORDER then
            context:addOption("Fill Out Mechanic Work Order", player, fillOutWorkOrder, item)
        elseif item and item:getFullType() == Mechanic.Items.FLYER and item:getModData().kipnMechShopId then
            context:addOption("Read Shop Flyer / Select Shop", player, readFlyer, item)
        end
    end
end

if Events.OnFillWorldObjectContextMenu then Events.OnFillWorldObjectContextMenu.Add(fillWorldContext) end
if Events.OnFillInventoryObjectContextMenu then Events.OnFillInventoryObjectContextMenu.Add(fillInventoryContext) end
