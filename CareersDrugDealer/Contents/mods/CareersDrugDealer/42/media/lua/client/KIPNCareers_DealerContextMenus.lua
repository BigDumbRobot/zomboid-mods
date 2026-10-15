require "ISUI/ISContextMenu"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "KIPNCareers_Shared"
require "KIPNCareers_DealerShared"

local Shared = KIPNCareers.Shared
local Dealer = KIPNCareers.Dealer
KIPNCareers.Client = KIPNCareers.Client or {}
local Client = KIPNCareers.Client

local function log(level, message)
    Shared.Log("ContextMenus", level, message)
end

KIPNCareers_FlyerViewer = ISPanel:derive("KIPNCareers_FlyerViewer")

function KIPNCareers_FlyerViewer:new(data)
    local width, height = 560, 480
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local panel = ISPanel.new(self, x, y, width, height)
    setmetatable(panel, self)
    self.__index = self
    panel.data = data or {}
    panel.backgroundColor = { r = 0.08, g = 0.07, b = 0.045, a = 0.98 }
    panel.borderColor = { r = 0.72, g = 0.60, b = 0.32, a = 1 }
    panel.moveWithMouse = true
    return panel
end

function KIPNCareers_FlyerViewer:initialise()
    ISPanel.initialise(self)
    local name = tostring(self.data.kipnCareersName or "BUSINESS FLYER")
    self.title = ISLabel:new(22, 20, 30, name, 0.95, 0.82, 0.42, 1, UIFont.Large, true)
    self.title:initialise()
    self:addChild(self.title)
    local text = "Proprietor: " .. tostring(self.data.kipnCareersProprietor or "")
        .. "\n\n" .. tostring(self.data.kipnCareersDescription or "")
        .. "\n\nPRODUCTS\n" .. tostring(self.data.kipnCareersProducts or "")
        .. "\n\nHOURS\n" .. tostring(self.data.kipnCareersHours or "")
        .. "\n\nCONTACT\n" .. tostring(self.data.kipnCareersMeeting or "")
        .. "\n\n" .. tostring(self.data.kipnCareersAdText or "")
    self.body = ISTextEntryBox:new(text, 22, 70, self.width - 44, self.height - 126)
    self.body:initialise()
    self.body:instantiate()
    self.body:setMultipleLine(true)
    self.body:setEditable(false)
    self:addChild(self.body)
    self.closeButton = ISButton:new(self.width - 122, self.height - 44, 100, 26, "CLOSE", self, KIPNCareers_FlyerViewer.close)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self:addChild(self.closeButton)
end

function KIPNCareers_FlyerViewer:close()
    self:removeFromUIManager()
end

function KIPNCareers_FlyerViewer.Open(data)
    if KIPNCareers_FlyerViewer.instance then KIPNCareers_FlyerViewer.instance:close() end
    local viewer = KIPNCareers_FlyerViewer:new(data)
    viewer:initialise()
    viewer:addToUIManager()
    KIPNCareers_FlyerViewer.instance = viewer
end

local function playerFor(index)
    return type(getSpecificPlayer) == "function" and getSpecificPlayer(index) or nil
end

local function send(command, arguments)
    log("Info", "send command=" .. tostring(command))
    sendClientCommand(Shared.MODULE, command, arguments or {})
end

local function collectItems(container, fullType, output)
    output = output or {}
    if not container or type(container.getItems) ~= "function" then return output end
    local items = container:getItems()
    if not items then return output end
    for index = 0, items:size() - 1 do
        local item = items:get(index)
        if item then
            if item:getFullType() == fullType then output[#output + 1] = item end
            local ok, nested = pcall(function() return type(item.getInventory) == "function" and item:getInventory() or nil end)
            if ok and nested then collectItems(nested, fullType, output) end
        end
    end
    return output
end

local function isMailbox(object)
    if not object or type(object.getContainer) ~= "function" or not object:getContainer() then return false end
    local container = object:getContainer()
    local sprite = type(object.getSprite) == "function" and object:getSprite() or nil
    local text = string.lower(tostring(type(container.getType) == "function" and container:getType() or "")
        .. " " .. tostring(sprite and sprite:getName() or "")
        .. " " .. tostring(type(object.getName) == "function" and object:getName() or ""))
    return string.find(text, "mailbox", 1, true) ~= nil
        or string.find(text, "postbox", 1, true) ~= nil
        or string.find(text, "mail_box", 1, true) ~= nil
end

local function startBusiness(player, tokenId)
    send(Dealer.Commands.START_BUSINESS, { tokenId = tokenId, x = player:getX(), y = player:getY(), z = player:getZ() })
end

local function sealDelivery(_target, payload)
    send(Dealer.Commands.SEAL_DELIVERY, payload)
end

local function dropDelivery(_target, payload)
    send(Dealer.Commands.DROP_DELIVERY, payload)
end

-- Accepted work orders the local player is the dealer for.
local function acceptedOrders()
    local snapshot = Client.snapshot or {}
    local out = {}
    for _, order in ipairs(snapshot.dealerOrders or {}) do
        if order.status == Dealer.Status.ACCEPTED then out[#out + 1] = order end
    end
    return out
end

local function fillWorldContext(playerIndex, context, worldObjects, test)
    if test then return end
    local player = playerFor(playerIndex)
    if not player then return end
    local snapshot = Client.snapshot

    -- The context menu can be the first Careers surface a session touches;
    -- pull a snapshot so a second right-click has the data.
    if not snapshot then send(Dealer.Commands.SNAPSHOT, {}) end

    if snapshot and not snapshot.business and player:getSquare() and player:getSquare():getBuilding() then
        for _, license in ipairs(collectItems(player:getInventory(), Dealer.Items.LICENSE, {})) do
            local tokenId = license:getModData().kipnCareersTokenId
            if tokenId then context:addOption("Start Your Drug Dealer Business (" .. tostring(tokenId) .. ")", player, startBusiness, tokenId) end
        end
    end

    local orders = acceptedOrders()
    if #orders == 0 then return end

    local seen = {}
    for _, object in ipairs(worldObjects or {}) do
        if object and type(object.getContainer) == "function" and object:getContainer() then
            local square = type(object.getSquare) == "function" and object:getSquare() or nil
            local key = square and (square:getX() .. ":" .. square:getY() .. ":" .. square:getZ()) or tostring(object)
            if square and not seen[key] then
                seen[key] = true
                local mailbox = isMailbox(object)
                local container = object:getContainer()
                for _, order in ipairs(orders) do
                    local have = #collectItems(container, order.itemType, {})
                    if have >= (order.quantity or 0) then
                        local payload = { orderId = order.id, x = square:getX(), y = square:getY(), z = square:getZ() }
                        if mailbox then
                            context:addOption("Seal Drug Delivery: " .. tostring(order.quantity) .. " x " .. tostring(order.itemLabel), nil, sealDelivery, payload)
                        else
                            context:addOption("Drop Drug Delivery: " .. tostring(order.quantity) .. " x " .. tostring(order.itemLabel), nil, dropDelivery, payload)
                        end
                    end
                end
            end
        end
    end
end

local function unwrapInventoryItem(entry)
    if not entry then return nil end
    if type(entry.getFullType) == "function" then return entry end
    if entry.items and entry.items[1] then return entry.items[1] end
    return nil
end

local function openParcel(item)
    send(Dealer.Commands.OPEN_PARCEL, { tokenId = item:getModData().kipnCareersTokenId })
end

local function readFlyer(player, item)
    local data = item:getModData()
    Client.preferredBusinessId = data.kipnCareersBusinessId
    KIPNCareers_FlyerViewer.Open(data)
    player:Say("Selected " .. tostring(data.kipnCareersName or "business") .. " for your next direct KIPN work order.")
end

local function fillInventoryContext(playerIndex, context, items)
    local player = playerFor(playerIndex)
    if not player then return end
    for _, entry in ipairs(items or {}) do
        local item = unwrapInventoryItem(entry)
        if item and item:getFullType() == Dealer.Items.PARCEL and item:getModData().kipnCareersTokenId then
            context:addOption("Open Sealed Drug Parcel", item, openParcel)
        elseif item and item:getFullType() == Shared.Items.FLYER then
            context:addOption("Read Business Flyer / Select Business", player, readFlyer, item)
        end
    end
end

if Events.OnFillWorldObjectContextMenu then Events.OnFillWorldObjectContextMenu.Add(fillWorldContext) end
if Events.OnFillInventoryObjectContextMenu then Events.OnFillInventoryObjectContextMenu.Add(fillInventoryContext) end
