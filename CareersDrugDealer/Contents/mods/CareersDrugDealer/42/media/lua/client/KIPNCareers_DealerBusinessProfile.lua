require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"
require "KIPN_UI"
require "KIPNCareers_Shared"
require "KIPNCareers_DealerShared"

local Shared = KIPNCareers.Shared
local Dealer = KIPNCareers.Dealer
KIPNCareers.Client = KIPNCareers.Client or {}

local function log(level, message)
    Shared.Log("BusinessProfileUI", level, message)
end

local function send(command, arguments)
    arguments = type(arguments) == "table" and arguments or {}
    local stamp = type(getTimestampMs) == "function" and getTimestampMs() or 0
    arguments.requestId = arguments.requestId or tostring(stamp)
    sendClientCommand(Shared.MODULE, command, arguments)
end

KIPN_CareersBusinessProfile = KIPN.UI.CreateScreen("KIPN_CareersBusinessProfile")

function KIPN_CareersBusinessProfile:initialise()
    ISPanel.initialise(self)
    KIPN.UI.SetupScreen(self)
    self.payload = nil
    self.statusText = "Loading Business Profile..."
    self.dynamic = {}
    KIPNCareers.Client.businessProfileScreen = self
    self:requestProfile()
end

function KIPN_CareersBusinessProfile:onShow()
    self:requestProfile()
end

function KIPN_CareersBusinessProfile:computerId()
    return self.terminal and self.terminal.GetComputerId and self.terminal:GetComputerId() or nil
end

function KIPN_CareersBusinessProfile:requestProfile()
    send(Dealer.Commands.BUSINESS_PROFILE, { computerId = self:computerId() })
end

function KIPN_CareersBusinessProfile:track(widget)
    self.dynamic[#self.dynamic + 1] = widget
    return widget
end

function KIPN_CareersBusinessProfile:clearDynamic()
    for _, widget in ipairs(self.dynamic) do
        if widget and widget.parent == self then self:removeChild(widget) end
    end
    self.dynamic = {}
end

function KIPN_CareersBusinessProfile:label(x, y, text, color)
    color = color or { r = 0.35, g = 0.9, b = 0.35 }
    local widget = ISLabel:new(x, y, 22, tostring(text or ""), color.r, color.g, color.b, 1, UIFont.Small, true)
    widget:initialise()
    self:addChild(widget)
    return self:track(widget)
end

function KIPN_CareersBusinessProfile:button(x, y, width, title, callback)
    local widget = ISButton:new(x, y, width, 28, title, self, callback)
    widget:initialise()
    widget:instantiate()
    self:addChild(widget)
    return self:track(widget)
end

local function orderRow(order)
    local who = order.isSystem and "SYSTEM" or ("BUYER " .. tostring(order.buyerName or "?"))
    local timer = ""
    if order.status == Dealer.Status.ACCEPTED and order.deadlineAt then
        timer = " | due " .. string.format("%.1f", order.deadlineAt)
    elseif order.status == Dealer.Status.FULFILLED then
        timer = order.canComplete and " | READY" or " | awaiting drug drop"
    end
    return who .. " | " .. tostring(order.status) .. " | " .. tostring(order.quantity) .. " x " .. tostring(order.itemLabel)
        .. " | " .. tostring(order.payout) .. timer
end

function KIPN_CareersBusinessProfile:render()
    self:clearDynamic()
    local payload = self.payload
    if not payload then
        self:label(18, 96, "Contacting KIPN...")
        return
    end
    if not payload.business then
        self:label(18, 96, "NO STOREFRONT AT THIS TERMINAL")
        if payload.atStorefront then
            self:label(18, 128, "This storefront belongs to another proprietor.")
        else
            self:label(18, 128, "Use a KIPN terminal inside your own storefront building.")
        end
        return
    end

    local business = payload.business
    local anchor = business.anchor or {}
    self:label(18, 88, "BUSINESS: " .. tostring(business.name or "Unnamed"))
    self:label(18, 112, "Proprietor: " .. tostring(business.proprietorAlias or business.name or "?"))
    self:label(18, 136, "Reputation: " .. tostring(payload.reputation or 0) .. " / 100")
    self:label(18, 160, "Pending currency: " .. tostring(payload.pendingCurrency or 0) .. " " .. tostring(payload.currencyItemType or ""))
    self:label(18, 184, "Storefront: " .. tostring(math.floor(tonumber(anchor.x) or 0)) .. ", " .. tostring(math.floor(tonumber(anchor.y) or 0)) .. ", " .. tostring(math.floor(tonumber(anchor.z) or 0)))
    self:label(18, 208, tostring(business.description or ""))

    self:label(18, 244, "WORK ORDERS")
    self.orderList = self:track(ISScrollingListBox:new(18, 268, self.width - 36, 200))
    self.orderList:initialise()
    self.orderList:instantiate()
    self.orderList.itemheight = 22
    self.orderList.font = UIFont.Small
    self:addChild(self.orderList)
    for _, order in ipairs(payload.orders or {}) do
        self.orderList:addItem(orderRow(order), order)
    end

    self.completeButton = self:button(18, 480, 220, "COMPLETE WORK ORDER", KIPN_CareersBusinessProfile.onComplete)
    self:label(250, 486, "Enabled once a dropped order has its full drug count in the drop container.")
end

function KIPN_CareersBusinessProfile:selectedOrder()
    local list = self.orderList
    local selected = list and list.items and list.items[list.selected]
    return selected and selected.item or nil
end

function KIPN_CareersBusinessProfile:onComplete()
    local order = self:selectedOrder()
    if not order then self.statusText = "Select a work order." return end
    if order.status ~= Dealer.Status.FULFILLED or not order.canComplete then
        self.statusText = "That work order is not ready to complete."
        return
    end
    send(Dealer.Commands.COMPLETE_WORK_ORDER, { orderId = order.id, computerId = self:computerId() })
end

function KIPN_CareersBusinessProfile:receiveResponse(event, data)
    if event == Dealer.Events.BUSINESS_PROFILE then
        self.payload = data
        self.statusText = data.business and "Profile synchronized." or "No storefront here."
        self:render()
    elseif event == Dealer.Events.RESULT then
        self.statusText = tostring(data.message or data.code or "Request completed.")
        self:requestProfile()
    elseif event == Dealer.Events.NOTIFICATION then
        self.statusText = tostring(data.title or "Career notice") .. ": " .. tostring(data.body or "")
        self:requestProfile()
    end
end

function KIPN_CareersBusinessProfile:prerender()
    ISPanel.prerender(self)
    KIPN.UI.DrawScanlines(self)
    KIPN.UI.DrawBanner(self, "KIPN BUSINESS PROFILE")
    self:drawText(tostring(self.statusText or ""), 18, self.height - 28, 0.4, 0.8, 0.4, 1, UIFont.Small)
end

function KIPN_CareersBusinessProfile:onKeyPress(key)
    if key == Keyboard.KEY_ESCAPE and KIPN_MainMenu then KIPN.UI.SetScreen(self, KIPN_MainMenu) end
end

return KIPN_CareersBusinessProfile
