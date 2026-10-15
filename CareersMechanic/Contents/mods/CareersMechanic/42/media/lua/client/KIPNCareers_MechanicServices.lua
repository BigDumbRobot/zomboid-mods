require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISScrollingListBox"
require "KIPN_UI"
require "KIPNCareers_Shared"
require "KIPNCareers_MechanicShared"

local Shared = KIPNCareers.Shared
local Mechanic = KIPNCareers.Mechanic
KIPNCareers.Client = KIPNCareers.Client or {}
local Client = KIPNCareers.Client

local function log(level, message)
    Mechanic.Log("ServicesUI", level, message)
end

local function send(command, arguments)
    arguments = type(arguments) == "table" and arguments or {}
    local stamp = type(getTimestampMs) == "function" and getTimestampMs() or 0
    arguments.requestId = arguments.requestId or tostring(stamp)
    sendClientCommand(Mechanic.MODULE, command, arguments)
end
Client.mechanicSend = send

local function repairSummary(order)
    local parts = {}
    for _, row in ipairs(order.repairs or {}) do
        parts[#parts + 1] = tostring(row.part) .. " " .. tostring(row.quality) .. "%"
    end
    return table.concat(parts, ", ")
end

local function orderLine(order)
    local timer = order.deadlineAt and (" | due " .. string.format("%.1f", order.deadlineAt)) or ""
    return tostring(order.status) .. " | " .. tostring(order.tier or "?") .. " | "
        .. tostring(order.payout or 0) .. " | " .. repairSummary(order) .. timer
end

KIPN_MechanicServices = KIPN.UI.CreateScreen("KIPN_MechanicServices")

function KIPN_MechanicServices:initialise()
    ISPanel.initialise(self)
    KIPN.UI.SetupScreen(self)
    self.snapshot = Client.mechanicSnapshot
    self.view = "home"
    self.statusText = "Loading Mechanic Services..."
    self.dynamic = {}
    self:createNav()
    Client.mechanicServicesScreen = self
    self:requestSnapshot()
end

function KIPN_MechanicServices:onShow()
    self:requestSnapshot()
end

function KIPN_MechanicServices:createNav()
    local labels = { { "HOME", "home" }, { "LICENSE", "license" }, { "MY ORDERS", "orders" }, { "MESSAGES", "messages" } }
    local x = 14
    for _, def in ipairs(labels) do
        local button = ISButton:new(x, 48, 110, 26, def[1], self, KIPN_MechanicServices.onNav)
        button.internal = def[2]
        button:initialise(); button:instantiate()
        self:addChild(button)
        x = x + 116
    end
end

function KIPN_MechanicServices:computerId()
    return self.terminal and self.terminal.GetComputerId and self.terminal:GetComputerId() or nil
end

function KIPN_MechanicServices:requestSnapshot()
    send(Mechanic.Commands.SNAPSHOT, {})
end

function KIPN_MechanicServices:onNav(button)
    self.view = button.internal or "home"
    self:render()
end

function KIPN_MechanicServices:track(w) self.dynamic[#self.dynamic + 1] = w return w end
function KIPN_MechanicServices:clearDynamic()
    for _, w in ipairs(self.dynamic) do if w and w.parent == self then self:removeChild(w) end end
    self.dynamic = {}
end

function KIPN_MechanicServices:label(x, y, text, color)
    color = color or { r = 0.4, g = 0.9, b = 0.45 }
    local w = ISLabel:new(x, y, 22, tostring(text or ""), color.r, color.g, color.b, 1, UIFont.Small, true)
    w:initialise(); self:addChild(w)
    return self:track(w)
end

function KIPN_MechanicServices:button(x, y, width, title, cb)
    local w = ISButton:new(x, y, width, 28, title, self, cb)
    w:initialise(); w:instantiate(); self:addChild(w)
    return self:track(w)
end

function KIPN_MechanicServices:list(x, y, width, height)
    local w = ISScrollingListBox:new(x, y, width, height)
    w:initialise(); w:instantiate()
    w.itemheight = 22; w.font = UIFont.Small
    self:addChild(w)
    return self:track(w)
end

function KIPN_MechanicServices:selected(list)
    local s = list and list.items and list.items[list.selected]
    return s and s.item or nil
end

function KIPN_MechanicServices:render()
    self:clearDynamic()
    if not self.snapshot then self:label(18, 96, "Waiting for the server...") return end
    if self.view == "license" then self:renderLicense()
    elseif self.view == "orders" then self:renderOrders()
    elseif self.view == "messages" then self:renderMessages()
    else self:renderHome() end
end

function KIPN_MechanicServices:renderHome()
    local d = self.snapshot
    self:label(18, 92, "MECHANIC PROFESSION")
    self:label(18, 118, "Reputation: " .. tostring(d.reputation or 0) .. " / 100")
    self:label(18, 142, "Your shop: " .. (d.shop and d.shop.name or "none -- claim a building with a license"))
    self:label(18, 166, "Active license items: " .. tostring(#(d.licenses or {})))
    self:label(18, 190, "Pending currency: " .. tostring(d.pendingCurrency or 0))
    self:label(18, 222, "To request a repair: right-click a Mechanic Work Order form in your inventory.")
    self:label(18, 246, "Shop owners: open MECHANIC SHOP from a terminal inside your shop.")
    self:label(18, 280, "RECENT NOTIFICATIONS")
    local notices = d.notifications or {}
    local y = 306
    for i = #notices, math.max(1, #notices - 5), -1 do
        local n = notices[i]
        if n then self:label(28, y, "* " .. tostring(n.title) .. ": " .. tostring(n.body)) y = y + 26 end
    end
    if #notices == 0 then self:label(28, y, "No notifications yet.") end
end

function KIPN_MechanicServices:renderLicense()
    self:label(18, 92, "MECHANIC BUSINESS LICENSE")
    self:label(18, 122, "Price: " .. tostring(self.snapshot.licensePrice or 0) .. " KIPN currency")
    self:label(18, 148, "Purchase from a terminal inside a Career Services zone.")
    self:label(18, 174, "The issued paper is a bearer token. Stand inside a building and right-click to claim your shop.")
    self:button(18, 214, 240, "PURCHASE & ISSUE LICENSE", KIPN_MechanicServices.onBuyLicense)
end

function KIPN_MechanicServices:onBuyLicense()
    send(Mechanic.Commands.BUY_LICENSE, { computerId = self:computerId() })
end

function KIPN_MechanicServices:renderOrders()
    self:label(18, 84, "MY WORK ORDERS")
    self.orderList = self:list(18, 112, self.width - 36, 250)
    for _, order in ipairs(self.snapshot.clientOrders or {}) do self.orderList:addItem(orderLine(order), order) end
    self:button(18, 374, 170, "CANCEL (unaccepted)", KIPN_MechanicServices.onCancel)
    self:button(198, 374, 210, "APPROVE & PAY (completed)", KIPN_MechanicServices.onApprove)
    self:label(18, 414, "Travel to the shop and inspect the repairs before approving payment.")
end

function KIPN_MechanicServices:onCancel()
    local o = self:selected(self.orderList)
    if o then send(Mechanic.Commands.CANCEL_ORDER, { orderId = o.id }) end
end

function KIPN_MechanicServices:onApprove()
    local o = self:selected(self.orderList)
    if o then send(Mechanic.Commands.APPROVE_ORDER, { orderId = o.id }) end
end

function KIPN_MechanicServices:renderMessages()
    self:label(18, 84, "MESSAGES FROM MECHANIC SHOPS")
    self.messageList = self:list(18, 112, self.width - 36, 300)
    local messages = self.snapshot.messages or {}
    for i = #messages, 1, -1 do
        local m = messages[i]
        self.messageList:addItem((m.unread and "* " or "  ") .. tostring(m.shopName or "Shop") .. " -- " .. tostring(m.subject or ""), m)
    end
    if #messages == 0 then self.messageList:addItem("No shop messages yet.", nil) end
    local m = self:selected(self.messageList)
    if m then self:label(18, 424, tostring(m.body or "")) end
end

function KIPN_MechanicServices:receiveResponse(event, data)
    if event == Mechanic.Events.SNAPSHOT then
        self.snapshot = data
        Client.mechanicSnapshot = data
        self.statusText = "Mechanic data synchronized."
        self:render()
    elseif event == Mechanic.Events.RESULT then
        self.statusText = tostring(data.message or data.code or "Request completed.")
        self:requestSnapshot()
    elseif event == Mechanic.Events.NOTIFICATION then
        self.statusText = tostring(data.title or "Notice") .. ": " .. tostring(data.body or "")
        self:requestSnapshot()
    elseif event == Mechanic.Events.MESSAGE then
        self.statusText = "Shop message: " .. tostring(data.subject or "")
        self:requestSnapshot()
    elseif event == Mechanic.Events.QUOTE then
        if KIPNCareers_MechanicWorkOrderUI and KIPNCareers_MechanicWorkOrderUI.instance then
            KIPNCareers_MechanicWorkOrderUI.instance:onQuote(data)
        end
    end
end

function KIPN_MechanicServices:prerender()
    ISPanel.prerender(self)
    KIPN.UI.DrawScanlines(self)
    KIPN.UI.DrawBanner(self, "KIPN MECHANIC SERVICES")
    self:drawText(tostring(self.statusText or ""), 18, self.height - 28, 0.4, 0.8, 0.4, 1, UIFont.Small)
end

function KIPN_MechanicServices:onKeyPress(key)
    if key == Keyboard.KEY_ESCAPE and KIPN_MainMenu then KIPN.UI.SetScreen(self, KIPN_MainMenu) end
end

-- Standalone router so mechanic notifications / messages / quote replies reach
-- the player even when no mechanic screen is the active terminal screen.
local function routeServerCommand(module, command, arguments)
    if module ~= Mechanic.MODULE then return end
    if command ~= KIPN.Shared.Commands.SERVER_RESPONSE or type(arguments) ~= "table" then return end
    local event = arguments.event
    local data = arguments.data or {}
    if event == Mechanic.Events.SNAPSHOT then
        Client.mechanicSnapshot = data
    elseif event == Mechanic.Events.RESULT then
        local player = type(getPlayer) == "function" and getPlayer() or nil
        if player and data.message then player:Say(tostring(data.message)) end
        send(Mechanic.Commands.SNAPSHOT, {})
    elseif event == Mechanic.Events.NOTIFICATION or event == Mechanic.Events.MESSAGE then
        local player = type(getPlayer) == "function" and getPlayer() or nil
        if player then player:Say(tostring(data.title or data.subject or "Mechanic notice") .. ": " .. tostring(data.body or "")) end
        send(Mechanic.Commands.SNAPSHOT, {})
    elseif event == Mechanic.Events.QUOTE then
        if KIPNCareers_MechanicWorkOrderUI and KIPNCareers_MechanicWorkOrderUI.instance then
            KIPNCareers_MechanicWorkOrderUI.instance:onQuote(data)
        end
    elseif event == Mechanic.Events.SHOP_PROFILE then
        if KIPN_MechanicShop and KIPNCareers.Client.mechanicShopScreen then
            KIPNCareers.Client.mechanicShopScreen:receiveResponse(event, data)
        end
    end
end

if Events.OnServerCommand then Events.OnServerCommand.Add(routeServerCommand) end

return KIPN_MechanicServices
