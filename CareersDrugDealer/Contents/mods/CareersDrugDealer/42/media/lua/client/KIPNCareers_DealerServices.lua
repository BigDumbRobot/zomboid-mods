require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "ISUI/ISScrollingListBox"
require "KIPNCareers_Shared"
require "KIPNCareers_DealerShared"

local Shared = KIPNCareers.Shared
local Dealer = KIPNCareers.Dealer
KIPNCareers.Client = KIPNCareers.Client or {}
local Client = KIPNCareers.Client

local function log(level, message)
    Shared.Log("CareerServicesUI", level, message)
end

local function send(command, arguments)
    log("Info", "send command=" .. tostring(command))
    arguments = type(arguments) == "table" and arguments or {}
    local requestStamp = type(getTimestampMs) == "function" and getTimestampMs()
        or (type(getTimestamp) == "function" and getTimestamp() or 0)
    arguments.requestId = arguments.requestId or tostring(requestStamp)
    sendClientCommand(Shared.MODULE, command, arguments)
end

local function addButton(screen, x, y, width, title, callback)
    log("Debug", "addButton title=" .. tostring(title))
    local button = ISButton:new(x, y, width, 28, title, screen, callback)
    button:initialise()
    button:instantiate()
    screen:addChild(button)
    return button
end

local function addLabel(screen, x, y, text, color)
    log("Debug", "addLabel text=" .. tostring(text))
    color = color or { r = 0.35, g = 0.9, b = 0.35 }
    local label = ISLabel:new(x, y, 22, tostring(text or ""), color.r, color.g, color.b, 1, UIFont.Small, true)
    label:initialise()
    screen:addChild(label)
    return label
end

local function addEntry(screen, x, y, width, text, multiple)
    log("Debug", "addEntry multiple=" .. tostring(multiple))
    local height = multiple and 54 or 26
    local entry = ISTextEntryBox:new(tostring(text or ""), x, y, width, height)
    entry:initialise()
    entry:instantiate()
    if multiple and type(entry.setMultipleLine) == "function" then entry:setMultipleLine(true) end
    screen:addChild(entry)
    return entry
end

local function addCombo(screen, x, y, width)
    log("Debug", "addCombo invoked")
    local combo = ISComboBox:new(x, y, width, 26, screen, nil)
    combo:initialise()
    combo:instantiate()
    screen:addChild(combo)
    return combo
end

local function addList(screen, x, y, width, height)
    log("Debug", "addList invoked")
    local list = ISScrollingListBox:new(x, y, width, height)
    list:initialise()
    list:instantiate()
    list.itemheight = 24
    list.font = UIFont.Small
    screen:addChild(list)
    return list
end

KIPN_CareerServices = KIPN.UI.CreateScreen("KIPN_CareerServices")

function KIPN_CareerServices:initialise()
    log("Info", "initialise invoked")
    ISPanel.initialise(self)
    KIPN.UI.SetupScreen(self)
    self.snapshot = Client.snapshot
    self.view = "home"
    self.statusText = "Loading Career Services..."
    self.dynamicWidgets = {}
    self:createNavigation()
    Client.activeScreen = self
    self:requestSnapshot()
end

function KIPN_CareerServices:createNavigation()
    log("Info", "createNavigation invoked")
    local labels = {
        { "HOME", "home" }, { "LICENSE", "license" }, { "BUSINESS", "business" },
        { "DEALER WORK", "work" }, { "PLACE ORDER", "order" }, { "MY ORDERS", "buyer" },
    }
    local x = 14
    for _, definition in ipairs(labels) do
        local button = ISButton:new(x, 48, 94, 26, definition[1], self, KIPN_CareerServices.onNavigation)
        button.internal = definition[2]
        button:initialise()
        button:instantiate()
        self:addChild(button)
        x = x + 98
    end
    self.adminButton = ISButton:new(x, 48, 80, 26, "ZONES", self, KIPN_CareerServices.onNavigation)
    self.adminButton.internal = "admin"
    self.adminButton:initialise()
    self.adminButton:instantiate()
    self:addChild(self.adminButton)
end

function KIPN_CareerServices:requestSnapshot()
    log("Info", "requestSnapshot invoked")
    send(Dealer.Commands.SNAPSHOT, {})
end

function KIPN_CareerServices:onNavigation(button)
    log("Info", "onNavigation view=" .. tostring(button and button.internal))
    self.view = button.internal or "home"
    self:renderView()
end

function KIPN_CareerServices:track(widget)
    log("Debug", "track invoked")
    self.dynamicWidgets[#self.dynamicWidgets + 1] = widget
    return widget
end

function KIPN_CareerServices:clearDynamic()
    log("Debug", "clearDynamic count=" .. tostring(#self.dynamicWidgets))
    for _, widget in ipairs(self.dynamicWidgets) do
        if widget and widget.parent == self then self:removeChild(widget) end
    end
    self.dynamicWidgets = {}
end

function KIPN_CareerServices:label(x, y, text, color)
    log("Debug", "label invoked")
    return self:track(addLabel(self, x, y, text, color))
end

function KIPN_CareerServices:entry(x, y, width, text, multiple)
    log("Debug", "entry invoked")
    return self:track(addEntry(self, x, y, width, text, multiple))
end

function KIPN_CareerServices:button(x, y, width, title, callback)
    log("Debug", "button invoked")
    return self:track(addButton(self, x, y, width, title, callback))
end

function KIPN_CareerServices:combo(x, y, width)
    log("Debug", "combo invoked")
    return self:track(addCombo(self, x, y, width))
end

function KIPN_CareerServices:list(x, y, width, height)
    log("Debug", "list invoked")
    return self:track(addList(self, x, y, width, height))
end

function KIPN_CareerServices:renderView()
    log("Info", "renderView view=" .. tostring(self.view))
    self:clearDynamic()
    if not self.snapshot then self:label(18, 96, "Waiting for the server...") return end
    if self.view == "license" then self:renderLicense()
    elseif self.view == "business" then self:renderBusiness()
    elseif self.view == "work" then self:renderWork()
    elseif self.view == "order" then self:renderOrderForm()
    elseif self.view == "buyer" then self:renderBuyerOrders()
    elseif self.view == "admin" then self:renderAdmin()
    else self:renderHome() end
end

function KIPN_CareerServices:renderHome()
    log("Info", "renderHome invoked")
    local data = self.snapshot
    self:label(18, 92, "DRUG DEALER CAREER")
    self:label(18, 118, "Reputation: " .. tostring(data.reputation or 0) .. " / 100")
    self:label(18, 142, "N&C catalog: " .. (data.narcoticsAvailable and (tostring(#(data.catalog or {})) .. " validated items") or "UNAVAILABLE"), data.narcoticsAvailable and nil or { r = 1, g = 0.3, b = 0.3 })
    self:label(18, 166, "Business: " .. (data.business and data.business.name or "none"))
    self:label(18, 190, "Active license items: " .. tostring(#(data.licenses or {})))
    self:label(18, 224, "LATEST PRIVATE CAREER ANNOUNCEMENTS")
    local notices = data.notifications or {}
    local y = 250
    for index = #notices, math.max(1, #notices - 5), -1 do
        local notice = notices[index]
        if notice then
            self:label(28, y, "• " .. tostring(notice.title) .. ": " .. tostring(notice.body))
            y = y + 28
        end
    end
    if #notices == 0 then self:label(28, y, "No career announcements yet.") end
end

function KIPN_CareerServices:renderLicense()
    log("Info", "renderLicense invoked")
    self:label(18, 92, "DRUG DEALER BUSINESS LICENSE")
    self:label(18, 122, "Price: " .. tostring(self.snapshot.licensePrice or 0) .. " " .. tostring(self.snapshot.currencyItemType or "currency")
        .. "  (you hold " .. tostring(self.snapshot.balance or 0) .. ")")
    self:label(18, 148, "Purchase must be made from a terminal inside a Career Services zone.")
    self:label(18, 174, "The issued paper is a bearer token. Keep it until you claim a storefront.")
    self:button(18, 214, 220, "PURCHASE & ISSUE LICENSE", KIPN_CareerServices.onBuyLicense)
end

function KIPN_CareerServices:onBuyLicense()
    log("Info", "onBuyLicense invoked")
    local computerId = self.terminal and self.terminal.GetComputerId and self.terminal:GetComputerId() or nil
    send(Dealer.Commands.BUY_LICENSE, { computerId = computerId })
end

function KIPN_CareerServices:renderBusiness()
    log("Info", "renderBusiness invoked")
    local business = self.snapshot.business
    if not business then
        self:label(18, 92, "NO ACTIVE STOREFRONT")
        self:label(18, 124, "Carry an issued license, walk inside a valid building, right-click, and choose:")
        self:label(28, 150, "Start Your Drug Dealer Business")
        return
    end
    self:label(18, 88, "BUSINESS PROFILE & NEXT-RESTART FLYER")
    self:label(18, 116, "Business name")
    self.businessName = self:entry(180, 112, 430, business.name, false)
    self:label(18, 148, "Proprietor alias")
    self.businessAlias = self:entry(180, 144, 430, business.proprietorAlias, false)
    self:label(18, 180, "Description")
    self.businessDescription = self:entry(180, 176, 430, business.description, true)
    self:label(18, 242, "Products")
    self.businessProducts = self:entry(180, 238, 430, business.products, true)
    self:label(18, 304, "Hours")
    self.businessHours = self:entry(180, 300, 430, business.hours, false)
    self:label(18, 336, "Meeting method")
    self.businessMeeting = self:entry(180, 332, 430, business.meetingMethod, true)
    self:label(18, 398, "Advertisement")
    self.businessAd = self:entry(180, 394, 430, business.adText, true)
    self:button(180, 462, 180, "SAVE FLYER REVISION", KIPN_CareerServices.onSaveBusiness)
end

function KIPN_CareerServices:onSaveBusiness()
    log("Info", "onSaveBusiness invoked")
    send(Dealer.Commands.SAVE_BUSINESS, { fields = {
        name = self.businessName:getText(), proprietorAlias = self.businessAlias:getText(),
        description = self.businessDescription:getText(), products = self.businessProducts:getText(),
        hours = self.businessHours:getText(), meetingMethod = self.businessMeeting:getText(),
        adText = self.businessAd:getText(),
    } })
end

local function orderLine(order)
    log("Debug", "orderLine id=" .. tostring(order and order.id))
    local timer = order.deadlineAt and (" | due " .. string.format("%.1f", order.deadlineAt)) or ""
    return tostring(order.status) .. " | " .. tostring(order.quantity) .. " x " .. tostring(order.itemLabel) .. " | " .. tostring(order.payout) .. timer
end

function KIPN_CareerServices:renderWork()
    log("Info", "renderWork invoked")
    if not self.snapshot.business then self:label(18, 92, "Establish a Drug Dealer storefront before accepting work.") return end
    self:label(18, 88, "AVAILABLE & ACCEPTED DEALER WORK")
    self.workList = self:list(18, 116, self.width - 36, 260)
    for _, order in ipairs(self.snapshot.dealerOrders or {}) do self.workList:addItem(orderLine(order), order) end
    self:button(18, 392, 120, "ACCEPT", KIPN_CareerServices.onAcceptOrder)
    self:button(148, 392, 120, "DECLINE", KIPN_CareerServices.onDeclineOrder)
    self:label(18, 434, "Deliver the exact items to ANY mailbox (right-click, Seal - instant) or ANY other")
    self:label(18, 456, "container (right-click, Drop - then Complete Work Order in Business Profile).")
end

function KIPN_CareerServices:selectedOrder(list)
    log("Debug", "selectedOrder invoked")
    local selected = list and list.items and list.items[list.selected]
    return selected and selected.item or nil
end

function KIPN_CareerServices:onAcceptOrder()
    log("Info", "onAcceptOrder invoked")
    local order = self:selectedOrder(self.workList)
    if order then send(Dealer.Commands.ACCEPT_ORDER, { orderId = order.id }) end
end

function KIPN_CareerServices:onDeclineOrder()
    log("Info", "onDeclineOrder invoked")
    local order = self:selectedOrder(self.workList)
    if order then send(Dealer.Commands.DECLINE_ORDER, { orderId = order.id }) end
end

function KIPN_CareerServices:renderOrderForm()
    log("Info", "renderOrderForm invoked")
    self:label(18, 88, "SUBMIT A PLAYER-FUNDED DRUG WORK ORDER")
    self:label(18, 122, "Drug")
    self.orderDrug = self:combo(170, 116, 440)
    for _, item in ipairs(self.snapshot.catalog or {}) do self.orderDrug:addOptionWithData(item.label .. " (" .. item.type .. ")", item) end
    self:label(18, 158, "Quantity")
    self.orderQuantity = self:entry(170, 152, 120, "1", false)
    self:label(318, 158, "Offer")
    self.orderPayout = self:entry(388, 152, 120, "100", false)
    self:label(18, 194, "Urgency")
    self.orderUrgency = self:combo(170, 188, 220)
    self.orderUrgency:addOptionWithData("Standard", Dealer.Urgencies.STANDARD)
    self.orderUrgency:addOptionWithData("Urgent", Dealer.Urgencies.URGENT)
    self:label(18, 230, "Business")
    self.orderBusiness = self:combo(170, 224, 440)
    self.orderBusiness:addOptionWithData("Public board — any dealer", "PUBLIC")
    for _, business in ipairs(self.snapshot.businesses or {}) do self.orderBusiness:addOptionWithData(business.name, business.id) end
    if Client.preferredBusinessId then
        for index, option in ipairs(self.orderBusiness.options or {}) do
            if option.data == Client.preferredBusinessId then self.orderBusiness.selected = index break end
        end
    end
    self:label(18, 266, "Buyer note")
    self.orderNote = self:entry(170, 260, 440, "", true)
    self:button(170, 332, 200, "FUND ESCROW & POST", KIPN_CareerServices.onSubmitOrder)
    self:label(18, 374, "Your whole offer is escrowed now. You get the parcel's location only after delivery.")
end

local function comboData(combo)
    log("Debug", "comboData invoked")
    local option = combo and combo.options and combo.options[combo.selected]
    return option and option.data or nil
end

function KIPN_CareerServices:onSubmitOrder()
    log("Info", "onSubmitOrder invoked")
    local drug = comboData(self.orderDrug)
    if not drug then self.statusText = "Select a drug item." return end
    send(Dealer.Commands.SUBMIT_ORDER, {
        itemType = drug.type, quantity = self.orderQuantity:getText(), payout = self.orderPayout:getText(),
        urgency = comboData(self.orderUrgency), targetBusinessId = comboData(self.orderBusiness),
        note = self.orderNote:getText(),
    })
end

function KIPN_CareerServices:renderBuyerOrders()
    log("Info", "renderBuyerOrders invoked")
    self:label(18, 88, "MY PLAYER-FUNDED ORDERS")
    self.buyerList = self:list(18, 116, self.width - 36, 280)
    for _, order in ipairs(self.snapshot.buyerOrders or {}) do self.buyerList:addItem(orderLine(order), order) end
    self:button(18, 412, 170, "CANCEL OPEN ORDER", KIPN_CareerServices.onCancelOrder)
    self:label(18, 452, "A delivered parcel is physical bearer property. Whoever carries it can open it.")
end

function KIPN_CareerServices:onCancelOrder()
    log("Info", "onCancelOrder invoked")
    local order = self:selectedOrder(self.buyerList)
    if order then send(Dealer.Commands.CANCEL_ORDER, { orderId = order.id }) end
end

function KIPN_CareerServices:renderAdmin()
    log("Info", "renderAdmin invoked")
    if not self.snapshot.isAdmin then self:label(18, 92, "Administrator access is required.") return end
    self:label(18, 88, "CAREERS ZONE EDITOR")
    self:label(18, 120, "New zone name")
    self.zoneName = self:entry(160, 114, 340, "", false)
    self.zoneList = self:list(18, 154, self.width - 36, 220)
    for _, zone in ipairs(self.snapshot.careerZones or {}) do
        self.zoneList:addItem((zone.active and "ACTIVE" or "INACTIVE") .. " | " .. zone.type .. " | " .. zone.name, zone)
    end
    self:button(18, 390, 185, "DRAW CAREER SERVICES", KIPN_CareerServices.onDrawCareerServices)
    self:button(213, 390, 165, "EDIT ON MAP", KIPN_CareerServices.onEditZones)
    self:button(388, 390, 185, "TOGGLE SELECTED", KIPN_CareerServices.onToggleZone)
    self:label(18, 430, "Career Services zones authorize license purchases. Deliveries need no zone.")
end

function KIPN_CareerServices:openZoneMap(zoneType, editExisting)
    log("Info", "openZoneMap type=" .. tostring(zoneType) .. " edit=" .. tostring(editExisting))
    require "KIPN_ZoneAdminMapUI"
    local screen = self
    local existing = {}
    for _, zone in ipairs(self.snapshot.careerZones or {}) do
        existing[#existing + 1] = { id = zone.id, type = zone.type, geometry = zone.geometry, metadata = { name = zone.name, label = zone.name }, active = zone.active }
    end
    KIPN_ZoneAdminMapUI.Open({
        existingZones = editExisting and existing or {},
        onConfirm = not editExisting and function(cornerA, cornerB)
            log("Info", "zone map onConfirm invoked")
            send(Shared.Commands.ADMIN_CREATE_ZONE, { zoneType = zoneType, name = screen.zoneName and screen.zoneName:getText() or "Career Zone", cornerA = cornerA, cornerB = cornerB })
        end or nil,
        onUpdateExisting = editExisting and function(zoneId, label, geometry)
            log("Info", "zone map onUpdateExisting zoneId=" .. tostring(zoneId))
            send(Shared.Commands.ADMIN_UPDATE_ZONE, { zoneId = zoneId, changes = { geometry = geometry, metadata = { name = label } } })
        end or nil,
    })
end

function KIPN_CareerServices:onDrawCareerServices()
    log("Info", "onDrawCareerServices invoked")
    self:openZoneMap(Shared.ZoneTypes.CAREER_SERVICES, false)
end

function KIPN_CareerServices:onEditZones()
    log("Info", "onEditZones invoked")
    self:openZoneMap(nil, true)
end

function KIPN_CareerServices:onToggleZone()
    log("Info", "onToggleZone invoked")
    local zone = self:selectedOrder(self.zoneList)
    if zone then send(Shared.Commands.ADMIN_TOGGLE_ZONE, { zoneId = zone.id, active = not zone.active }) end
end

function KIPN_CareerServices:receiveResponse(event, data)
    log("Info", "receiveResponse event=" .. tostring(event))
    if event == Dealer.Events.SNAPSHOT then
        self.snapshot = data
        Client.snapshot = data
        if self.adminButton then self.adminButton:setVisible(data.isAdmin == true) end
        self.statusText = "Career data synchronized."
        self:renderView()
    elseif event == Dealer.Events.RESULT then
        self.statusText = tostring(data.message or data.code or "Request completed.")
        self:requestSnapshot()
    elseif event == Dealer.Events.NOTIFICATION then
        self.statusText = tostring(data.title or "Career notice") .. ": " .. tostring(data.body or "")
        self:requestSnapshot()
    end
end

function KIPN_CareerServices:prerender()
    log("Debug", "prerender invoked")
    ISPanel.prerender(self)
    KIPN.UI.DrawScanlines(self)
    KIPN.UI.DrawBanner(self, "KIPN CAREER SERVICES")
    self:drawText(tostring(self.statusText or ""), 18, self.height - 28, 0.4, 0.8, 0.4, 1, UIFont.Small)
end

function KIPN_CareerServices:onKeyPress(key)
    log("Debug", "onKeyPress key=" .. tostring(key))
    if key == Keyboard.KEY_ESCAPE and KIPN_MainMenu then KIPN.UI.SetScreen(self, KIPN_MainMenu) end
end

local function routeServerCommand(module, command, arguments)
    log("Debug", "routeServerCommand module=" .. tostring(module) .. " command=" .. tostring(command))
    if module ~= Shared.MODULE then return end
    if command == KIPN.Shared.Commands.SERVER_RESPONSE and type(arguments) == "table" then
        local event = arguments.event
        local data = arguments.data or {}
        if event == Dealer.Events.SNAPSHOT then
            Client.snapshot = data
        elseif event == Dealer.Events.RESULT then
            local player = type(getPlayer) == "function" and getPlayer() or nil
            if player and data.message then player:Say(tostring(data.message)) end
            send(Dealer.Commands.SNAPSHOT, {})
        elseif event == Dealer.Events.NOTIFICATION then
            local player = type(getPlayer) == "function" and getPlayer() or nil
            if player then player:Say(tostring(data.title or "Career notice") .. ": " .. tostring(data.body or "")) end
            send(Dealer.Commands.SNAPSHOT, {})
        end
    end
end

if Events.OnServerCommand then Events.OnServerCommand.Add(routeServerCommand) end

return KIPN_CareerServices
