require "ISUI/ISContextMenu"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "KIPNCareers_Shared"
require "KIPNCareers_BlacksmithShared"

local Shared = KIPNCareers.Shared
local Blacksmith = KIPNCareers.Blacksmith
KIPNCareers.Client = KIPNCareers.Client or {}
local Client = KIPNCareers.Client

local function send(command, arguments)
    if Client.blacksmithSend then Client.blacksmithSend(command, arguments) return end
    sendClientCommand(Blacksmith.MODULE, command, arguments or {})
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

KIPNCareers_BlacksmithWorkOrderUI = ISPanel:derive("KIPNCareers_BlacksmithWorkOrderUI")

local ROW_HEIGHT = 30
local MAX_ROWS = Blacksmith.Defaults.MAX_ITEMS_PER_ORDER

function KIPNCareers_BlacksmithWorkOrderUI:new()
    local width, height = 560, 560
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local panel = ISPanel.new(self, x, y, width, height)
    setmetatable(panel, self)
    self.__index = self
    panel.backgroundColor = { r = 0.08, g = 0.06, b = 0.05, a = 0.98 }
    panel.borderColor = { r = 0.85, g = 0.5, b = 0.2, a = 1 }
    panel.moveWithMouse = true
    panel.rows = {}
    panel.quotes = nil
    panel.selectedTier = Blacksmith.Tiers.REGULAR
    panel.statusText = "Enter the items you need forged."
    return panel
end

function KIPNCareers_BlacksmithWorkOrderUI:initialise()
    ISPanel.initialise(self)
    self.title = ISLabel:new(20, 16, 26, "FORGE ORDER", 0.95, 0.6, 0.25, 1, UIFont.Large, true)
    self.title:initialise(); self:addChild(self.title)

    self.businessLabel = ISLabel:new(20, 52, 22, "Send to shop", 0.9, 0.75, 0.6, 1, UIFont.Small, true)
    self.businessLabel:initialise(); self:addChild(self.businessLabel)
    self.businessCombo = ISComboBox:new(150, 48, 380, 26, self, nil)
    self.businessCombo:initialise(); self.businessCombo:instantiate(); self:addChild(self.businessCombo)
    local snapshot = Client.blacksmithSnapshot or {}
    for _, shop in ipairs(snapshot.shops or {}) do self.businessCombo:addOptionWithData(shop.name, shop.id) end
    if Client.blacksmithPreferredShopId then
        for index, option in ipairs(self.businessCombo.options or {}) do
            if option.data == Client.blacksmithPreferredShopId then self.businessCombo.selected = index break end
        end
    end

    self.headerPart = ISLabel:new(20, 84, 22, "Item", 0.9, 0.75, 0.6, 1, UIFont.Small, true)
    self.headerPart:initialise(); self:addChild(self.headerPart)
    self.headerQuality = ISLabel:new(360, 84, 22, "Quality %", 0.9, 0.75, 0.6, 1, UIFont.Small, true)
    self.headerQuality:initialise(); self:addChild(self.headerQuality)

    self.addRowButton = ISButton:new(20, self.height - 190, 150, 26, "+ ADD ITEM", self, KIPNCareers_BlacksmithWorkOrderUI.onAddRow)
    self.addRowButton:initialise(); self.addRowButton:instantiate(); self:addChild(self.addRowButton)

    self.quoteButton = ISButton:new(180, self.height - 190, 150, 26, "GET QUOTES", self, KIPNCareers_BlacksmithWorkOrderUI.onGetQuotes)
    self.quoteButton:initialise(); self.quoteButton:instantiate(); self:addChild(self.quoteButton)

    self.tierButtons = {}
    local labels = { { Blacksmith.Tiers.FAST, "FAST" }, { Blacksmith.Tiers.REGULAR, "REGULAR" }, { Blacksmith.Tiers.SLOW, "SLOW" } }
    for index, def in ipairs(labels) do
        local button = ISButton:new(20 + (index - 1) * 180, self.height - 150, 170, 44, def[2] .. "\n--", self, KIPNCareers_BlacksmithWorkOrderUI.onPickTier)
        button.tier = def[1]
        button:initialise(); button:instantiate(); button:setEnable(false)
        self:addChild(button)
        self.tierButtons[def[1]] = button
    end

    self.sendButton = ISButton:new(20, self.height - 92, 250, 28, "SEND FORGE ORDER", self, KIPNCareers_BlacksmithWorkOrderUI.onSend)
    self.sendButton:initialise(); self.sendButton:instantiate(); self.sendButton:setEnable(false)
    self:addChild(self.sendButton)

    self.closeButton = ISButton:new(self.width - 120, self.height - 92, 100, 28, "CLOSE", self, KIPNCareers_BlacksmithWorkOrderUI.close)
    self.closeButton:initialise(); self.closeButton:instantiate(); self:addChild(self.closeButton)

    self:onAddRow()
end

function KIPNCareers_BlacksmithWorkOrderUI:onAddRow()
    if #self.rows >= MAX_ROWS then self.statusText = "Item line limit reached." return end
    local y = 106 + #self.rows * ROW_HEIGHT
    local part = ISTextEntryBox:new("", 20, y, 320, 26)
    part:initialise(); part:instantiate(); self:addChild(part)
    local quality = ISTextEntryBox:new("100", 360, y, 80, 26)
    quality:initialise(); quality:instantiate(); quality:setOnlyNumbers(true); self:addChild(quality)
    local removeButton = ISButton:new(452, y, 80, 26, "REMOVE", self, KIPNCareers_BlacksmithWorkOrderUI.onRemoveRow)
    removeButton:initialise(); removeButton:instantiate(); self:addChild(removeButton)
    local row = { part = part, quality = quality, removeButton = removeButton }
    removeButton.row = row
    self.rows[#self.rows + 1] = row
    self:invalidateQuotes()
end

function KIPNCareers_BlacksmithWorkOrderUI:onRemoveRow(button)
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

function KIPNCareers_BlacksmithWorkOrderUI:relayoutRows()
    for index, row in ipairs(self.rows) do
        local y = 106 + (index - 1) * ROW_HEIGHT
        row.part:setY(y); row.quality:setY(y); row.removeButton:setY(y)
    end
end

function KIPNCareers_BlacksmithWorkOrderUI:collectItems()
    local raw = {}
    for _, row in ipairs(self.rows) do
        raw[#raw + 1] = { itemName = row.part:getText(), quality = tonumber(row.quality:getText()) or Blacksmith.Defaults.QUALITY_MAX }
    end
    return Blacksmith.SanitizeForgeItems(raw, MAX_ROWS)
end

function KIPNCareers_BlacksmithWorkOrderUI:targetShopId()
    local option = self.businessCombo and self.businessCombo.options and self.businessCombo.options[self.businessCombo.selected]
    return option and option.data or nil
end

function KIPNCareers_BlacksmithWorkOrderUI:invalidateQuotes()
    self.quotes = nil
    self.sendButton:setEnable(false)
    for _, button in pairs(self.tierButtons) do
        button:setEnable(false)
        button.title = string.upper(button.tier) .. "\n--"
    end
end

function KIPNCareers_BlacksmithWorkOrderUI:onGetQuotes()
    local items = self:collectItems()
    if not items then self.statusText = "Add at least one item name." return end
    local shopId = self:targetShopId()
    if not shopId then self.statusText = "Pick a shop to send the order to." return end
    self.statusText = "Requesting quotes..."
    send(Blacksmith.Commands.QUOTE_ORDER, { items = items, targetShopId = shopId })
end

function KIPNCareers_BlacksmithWorkOrderUI:onQuote(data)
    if not data or type(data.quotes) ~= "table" then return end
    self.quotes = data.quotes
    local hours = data.tierHours or {}
    local map = { fast = data.quotes.fast, regular = data.quotes.regular, slow = data.quotes.slow }
    for tier, button in pairs(self.tierButtons) do
        local hrs = hours[tier]
        button.title = string.upper(tier) .. "\n" .. tostring(map[tier] or "?") .. (hrs and ("  /  " .. tostring(hrs) .. "h") or "")
        button:setEnable(true)
    end
    self.selectedTier = Blacksmith.Tiers.REGULAR
    self.sendButton:setEnable(true)
    self.statusText = "Pick a turnaround and send. Payment is held in escrow."
end

function KIPNCareers_BlacksmithWorkOrderUI:onPickTier(button)
    self.selectedTier = button.tier
    self.statusText = "Selected " .. string.upper(button.tier) .. " turnaround."
end

function KIPNCareers_BlacksmithWorkOrderUI:onSend()
    if not self.quotes then self.statusText = "Get quotes first." return end
    local items = self:collectItems()
    if not items then self.statusText = "Add at least one item name." return end
    local shopId = self:targetShopId()
    if not shopId then self.statusText = "Pick a shop." return end
    send(Blacksmith.Commands.SUBMIT_ORDER, { items = items, targetShopId = shopId, tier = self.selectedTier })
    self.statusText = "Forge order sent."
    self:close()
end

function KIPNCareers_BlacksmithWorkOrderUI:prerender()
    ISPanel.prerender(self)
    self:drawText(tostring(self.statusText or ""), 20, self.height - 56, 0.9, 0.7, 0.5, 1, UIFont.Small)
    self:drawText("Higher requested quality raises the price.", 20, self.height - 214, 0.8, 0.6, 0.45, 1, UIFont.Small)
end

function KIPNCareers_BlacksmithWorkOrderUI:close()
    KIPNCareers_BlacksmithWorkOrderUI.instance = nil
    self:removeFromUIManager()
end

function KIPNCareers_BlacksmithWorkOrderUI.Open()
    if KIPNCareers_BlacksmithWorkOrderUI.instance then KIPNCareers_BlacksmithWorkOrderUI.instance:close() end
    local panel = KIPNCareers_BlacksmithWorkOrderUI:new()
    panel:initialise()
    panel:addToUIManager()
    KIPNCareers_BlacksmithWorkOrderUI.instance = panel
    return panel
end

------------------------------------------------------------
-- Flyer viewer
------------------------------------------------------------

KIPNCareers_BlacksmithFlyerViewer = ISPanel:derive("KIPNCareers_BlacksmithFlyerViewer")

function KIPNCareers_BlacksmithFlyerViewer:new(data)
    local width, height = 560, 460
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local panel = ISPanel.new(self, x, y, width, height)
    setmetatable(panel, self)
    self.__index = self
    panel.data = data or {}
    panel.backgroundColor = { r = 0.09, g = 0.07, b = 0.05, a = 0.98 }
    panel.borderColor = { r = 0.8, g = 0.45, b = 0.2, a = 1 }
    panel.moveWithMouse = true
    return panel
end

function KIPNCareers_BlacksmithFlyerViewer:initialise()
    ISPanel.initialise(self)
    self.title = ISLabel:new(22, 20, 30, tostring(self.data.kipnBSmithName or "SHOP FLYER"), 0.95, 0.6, 0.25, 1, UIFont.Large, true)
    self.title:initialise(); self:addChild(self.title)
    local text = "Proprietor: " .. tostring(self.data.kipnBSmithProprietor or "")
        .. "\n\n" .. tostring(self.data.kipnBSmithDescription or "")
        .. "\n\nSERVICES\n" .. tostring(self.data.kipnBSmithServices or "")
        .. "\n\nHOURS\n" .. tostring(self.data.kipnBSmithHours or "")
        .. "\n\nCONTACT\n" .. tostring(self.data.kipnBSmithContact or "")
        .. "\n\n" .. tostring(self.data.kipnBSmithAdText or "")
    self.body = ISTextEntryBox:new(text, 22, 70, self.width - 44, self.height - 126)
    self.body:initialise(); self.body:instantiate()
    self.body:setMultipleLine(true); self.body:setEditable(false)
    self:addChild(self.body)
    self.closeButton = ISButton:new(self.width - 122, self.height - 44, 100, 26, "CLOSE", self, KIPNCareers_BlacksmithFlyerViewer.close)
    self.closeButton:initialise(); self.closeButton:instantiate(); self:addChild(self.closeButton)
end

function KIPNCareers_BlacksmithFlyerViewer:close() self:removeFromUIManager() end

function KIPNCareers_BlacksmithFlyerViewer.Open(data)
    if KIPNCareers_BlacksmithFlyerViewer.instance then KIPNCareers_BlacksmithFlyerViewer.instance:close() end
    local viewer = KIPNCareers_BlacksmithFlyerViewer:new(data)
    viewer:initialise(); viewer:addToUIManager()
    KIPNCareers_BlacksmithFlyerViewer.instance = viewer
end

------------------------------------------------------------
-- World context menu
------------------------------------------------------------

local function startShop(player, tokenId)
    send(Blacksmith.Commands.START_SHOP, { tokenId = tokenId, x = player:getX(), y = player:getY(), z = player:getZ() })
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
    send(Blacksmith.Commands.SET_CONTAINER_TYPE, { containerType = params.kind, x = params.x, y = params.y, z = params.z, descriptor = params.descriptor })
end

local function clearContainer(_t, params)
    send(Blacksmith.Commands.CLEAR_CONTAINER_TYPE, { x = params.x, y = params.y, z = params.z, descriptor = params.descriptor })
end

local function fillWorldContext(playerIndex, context, worldObjects, test)
    if test then return end
    local player = playerFor(playerIndex)
    if not player then return end
    local snapshot = Client.blacksmithSnapshot or {}

    if not snapshot.shop and player:getSquare() and player:getSquare():getBuilding() then
        for _, license in ipairs(collectItems(player:getInventory(), Blacksmith.Items.LICENSE, {})) do
            local tokenId = license:getModData().kipnBSmithToken
            if tokenId then
                context:addOption("Start Your Blacksmith Shop (" .. tostring(tokenId) .. ")", player, startShop, tokenId)
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
                        context:addSubMenu(context:addOption("Blacksmith Business: Container", nil, nil), sub)
                        for _, kind in ipairs({ Blacksmith.ContainerTypes.PRIVATE, Blacksmith.ContainerTypes.PUBLIC, Blacksmith.ContainerTypes.FORSALE }) do
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
    if not Client.blacksmithSnapshot and Client.blacksmithSend then Client.blacksmithSend(Blacksmith.Commands.SNAPSHOT, {}) end
    local data = item:getModData()
    if data.kipnBSmithShopId then Client.blacksmithPreferredShopId = data.kipnBSmithShopId end
    KIPNCareers_BlacksmithWorkOrderUI.Open()
end

local function readFlyer(player, item)
    local data = item:getModData()
    Client.blacksmithPreferredShopId = data.kipnBSmithShopId
    KIPNCareers_BlacksmithFlyerViewer.Open(data)
    player:Say("Selected " .. tostring(data.kipnBSmithName or "shop") .. " for your next Blacksmith work order.")
end

local function fillInventoryContext(playerIndex, context, items)
    local player = playerFor(playerIndex)
    if not player then return end
    for _, entry in ipairs(items or {}) do
        local item = unwrapInventoryItem(entry)
        if item and item:getFullType() == Blacksmith.Items.WORK_ORDER then
            context:addOption("Fill Out Forge Order", player, fillOutWorkOrder, item)
        elseif item and item:getFullType() == Blacksmith.Items.FLYER and item:getModData().kipnBSmithShopId then
            context:addOption("Read Shop Flyer / Select Shop", player, readFlyer, item)
        end
    end
end

if Events.OnFillWorldObjectContextMenu then Events.OnFillWorldObjectContextMenu.Add(fillWorldContext) end
if Events.OnFillInventoryObjectContextMenu then Events.OnFillInventoryObjectContextMenu.Add(fillInventoryContext) end
