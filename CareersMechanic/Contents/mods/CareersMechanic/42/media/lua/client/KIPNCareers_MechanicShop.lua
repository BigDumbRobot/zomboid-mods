require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISScrollingListBox"
require "KIPN_UI"
require "KIPNCareers_Shared"
require "KIPNCareers_MechanicShared"

local Shared = KIPNCareers.Shared
local Mechanic = KIPNCareers.Mechanic
KIPNCareers.Client = KIPNCareers.Client or {}
local Client = KIPNCareers.Client

local function send(command, arguments)
    arguments = type(arguments) == "table" and arguments or {}
    local stamp = type(getTimestampMs) == "function" and getTimestampMs() or 0
    arguments.requestId = arguments.requestId or tostring(stamp)
    sendClientCommand(Mechanic.MODULE, command, arguments)
end

local function repairSummary(order)
    local parts = {}
    for _, row in ipairs(order.repairs or {}) do
        parts[#parts + 1] = tostring(row.part) .. " " .. tostring(row.quality) .. "%"
    end
    return table.concat(parts, ", ")
end

local function orderRow(order)
    local timer = order.deadlineAt and (" | due " .. string.format("%.1f", order.deadlineAt)) or ""
    -- Walk-ins come from the server and pay the moment the work is complete.
    local walkIn = order.source == Mechanic.OrderSources.SYSTEM and " (walk-in)" or ""
    return tostring(order.status) .. " | " .. tostring(order.clientName or "?") .. walkIn .. " | " .. tostring(order.tier or "?")
        .. " | " .. tostring(order.payout or 0) .. timer
end

KIPN_MechanicShop = KIPN.UI.CreateScreen("KIPN_MechanicShop")

function KIPN_MechanicShop:initialise()
    ISPanel.initialise(self)
    KIPN.UI.SetupScreen(self)
    self.payload = nil
    self.view = "profile"
    self.statusText = "Loading Mechanic Shop..."
    self.dynamic = {}
    self:createNav()
    Client.mechanicShopScreen = self
    self:requestProfile()
end

function KIPN_MechanicShop:onShow() self:requestProfile() end

function KIPN_MechanicShop:createNav()
    local labels = { { "PROFILE", "profile" }, { "CONTAINERS", "containers" }, { "WORK QUEUE", "queue" } }
    local x = 14
    for _, def in ipairs(labels) do
        local button = ISButton:new(x, 48, 120, 26, def[1], self, KIPN_MechanicShop.onNav)
        button.internal = def[2]
        button:initialise(); button:instantiate()
        self:addChild(button)
        x = x + 126
    end
end

function KIPN_MechanicShop:computerId()
    return self.terminal and self.terminal.GetComputerId and self.terminal:GetComputerId() or nil
end

function KIPN_MechanicShop:requestProfile()
    send(Mechanic.Commands.SHOP_PROFILE, { computerId = self:computerId() })
end

function KIPN_MechanicShop:onNav(button)
    self.view = button.internal or "profile"
    self:render()
end

function KIPN_MechanicShop:track(w) self.dynamic[#self.dynamic + 1] = w return w end
function KIPN_MechanicShop:clearDynamic()
    for _, w in ipairs(self.dynamic) do if w and w.parent == self then self:removeChild(w) end end
    self.dynamic = {}
end

function KIPN_MechanicShop:label(x, y, text, color)
    color = color or { r = 0.4, g = 0.9, b = 0.45 }
    local w = ISLabel:new(x, y, 22, tostring(text or ""), color.r, color.g, color.b, 1, UIFont.Small, true)
    w:initialise(); self:addChild(w)
    return self:track(w)
end

function KIPN_MechanicShop:entry(x, y, width, text, multiple)
    local w = ISTextEntryBox:new(tostring(text or ""), x, y, width, multiple and 54 or 26)
    w:initialise(); w:instantiate()
    if multiple and w.setMultipleLine then w:setMultipleLine(true) end
    self:addChild(w)
    return self:track(w)
end

function KIPN_MechanicShop:button(x, y, width, title, cb)
    local w = ISButton:new(x, y, width, 28, title, self, cb)
    w:initialise(); w:instantiate(); self:addChild(w)
    return self:track(w)
end

function KIPN_MechanicShop:list(x, y, width, height)
    local w = ISScrollingListBox:new(x, y, width, height)
    w:initialise(); w:instantiate()
    w.itemheight = 22; w.font = UIFont.Small
    self:addChild(w)
    return self:track(w)
end

function KIPN_MechanicShop:selected(list)
    local s = list and list.items and list.items[list.selected]
    return s and s.item or nil
end

function KIPN_MechanicShop:render()
    self:clearDynamic()
    local p = self.payload
    if not p then self:label(18, 96, "Contacting KIPN...") return end
    if not p.shop then
        self:label(18, 96, "NO SHOP AT THIS TERMINAL")
        self:label(18, 128, p.atShop and "This shop belongs to another proprietor."
            or "Use a KIPN terminal inside your own mechanic shop building.")
        return
    end
    if self.view == "containers" then self:renderContainers()
    elseif self.view == "queue" then self:renderQueue()
    else self:renderProfile() end
end

function KIPN_MechanicShop:renderProfile()
    local shop = self.payload.shop
    self:label(18, 84, "SHOP PROFILE & NEXT-RESTART FLYER")
    self:label(18, 110, "Shop name"); self.fName = self:entry(160, 106, 430, shop.name, false)
    self:label(18, 140, "Proprietor alias"); self.fAlias = self:entry(160, 136, 430, shop.proprietorAlias, false)
    self:label(18, 170, "Description"); self.fDesc = self:entry(160, 166, 430, shop.description, true)
    self:label(18, 228, "Services"); self.fServices = self:entry(160, 224, 430, shop.services, true)
    self:label(18, 286, "Hours"); self.fHours = self:entry(160, 282, 430, shop.hours, false)
    self:label(18, 316, "Contact"); self.fContact = self:entry(160, 312, 430, shop.contact, true)
    self:label(18, 374, "Advertisement"); self.fAd = self:entry(160, 370, 430, shop.adText, true)
    self:button(160, 430, 190, "SAVE FLYER REVISION", KIPN_MechanicShop.onSave)
    self:label(18, 468, "Reputation: " .. tostring(self.payload.reputation or 0) .. " / 100   Pending currency: " .. tostring(self.payload.pendingCurrency or 0))
end

function KIPN_MechanicShop:onSave()
    send(Mechanic.Commands.SAVE_SHOP, { fields = {
        name = self.fName:getText(), proprietorAlias = self.fAlias:getText(),
        description = self.fDesc:getText(), services = self.fServices:getText(),
        hours = self.fHours:getText(), contact = self.fContact:getText(), adText = self.fAd:getText(),
    } })
end

function KIPN_MechanicShop:renderContainers()
    self:label(18, 84, "ASSIGNED BUSINESS CONTAINERS")
    self:label(18, 108, "All shop containers are Private by default. Assign Public / For Sale by")
    self:label(18, 128, "right-clicking a container inside your shop building.")
    self.containerList = self:list(18, 156, self.width - 36, 260)
    local containers = self.payload.shop.containers or {}
    local any = false
    for key, record in pairs(containers) do
        any = true
        self.containerList:addItem(
            tostring(record.type) .. " | " .. tostring(record.containerType or "?")
            .. " @ " .. tostring(record.x) .. "," .. tostring(record.y) .. "," .. tostring(record.z)
            .. (record.label and record.label ~= "" and (" (" .. tostring(record.label) .. ")") or ""),
            { key = key, record = record })
    end
    if not any then self.containerList:addItem("No containers assigned yet.", nil) end
    self:label(18, 428, "Public containers keep one self-refilling Mechanic Work Order form for customers.")
end

function KIPN_MechanicShop:renderQueue()
    self:label(18, 84, "WORK QUEUE")
    self.queueList = self:list(18, 112, self.width - 36, 250)
    for _, order in ipairs(self.payload.orders or {}) do self.queueList:addItem(orderRow(order), order) end
    self:button(18, 374, 110, "ACCEPT", KIPN_MechanicShop.onAccept)
    self:button(136, 374, 110, "DECLINE", KIPN_MechanicShop.onDecline)
    self:button(254, 374, 200, "WORK ORDER COMPLETE", KIPN_MechanicShop.onComplete)
    local o = self:selected(self.queueList)
    if o then
        self:label(18, 414, "Repairs: " .. repairSummary(o))
        if o.note and o.note ~= "" then self:label(18, 436, "Client note: " .. tostring(o.note)) end
    end
end

function KIPN_MechanicShop:onAccept()
    local o = self:selected(self.queueList)
    if o then send(Mechanic.Commands.ACCEPT_ORDER, { orderId = o.id }) end
end

function KIPN_MechanicShop:onDecline()
    local o = self:selected(self.queueList)
    if o then send(Mechanic.Commands.DECLINE_ORDER, { orderId = o.id }) end
end

function KIPN_MechanicShop:onComplete()
    local o = self:selected(self.queueList)
    if not o then self.statusText = "Select a work order." return end
    if o.status ~= Mechanic.Status.ACCEPTED then self.statusText = "That work order is not in progress." return end
    send(Mechanic.Commands.COMPLETE_ORDER, { orderId = o.id })
end

function KIPN_MechanicShop:receiveResponse(event, data)
    if event == Mechanic.Events.SHOP_PROFILE then
        self.payload = data
        self.statusText = data.shop and "Shop profile synchronized." or "No shop here."
        self:render()
    elseif event == Mechanic.Events.RESULT then
        self.statusText = tostring(data.message or data.code or "Request completed.")
        self:requestProfile()
    elseif event == Mechanic.Events.NOTIFICATION or event == Mechanic.Events.MESSAGE then
        self.statusText = tostring(data.title or data.subject or "Notice") .. ": " .. tostring(data.body or "")
        self:requestProfile()
    end
end

function KIPN_MechanicShop:prerender()
    ISPanel.prerender(self)
    KIPN.UI.DrawScanlines(self)
    KIPN.UI.DrawBanner(self, "KIPN MECHANIC SHOP")
    self:drawText(tostring(self.statusText or ""), 18, self.height - 28, 0.4, 0.8, 0.4, 1, UIFont.Small)
end

function KIPN_MechanicShop:onKeyPress(key)
    if key == Keyboard.KEY_ESCAPE and KIPN_MainMenu then KIPN.UI.SetScreen(self, KIPN_MainMenu) end
end

return KIPN_MechanicShop
