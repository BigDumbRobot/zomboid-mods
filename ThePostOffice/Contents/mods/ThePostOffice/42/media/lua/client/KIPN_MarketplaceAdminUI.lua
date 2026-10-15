-- KIPN_MarketplaceAdminUI.lua
--
-- Admin-only editor for KIPN's server-owned internal marketplace.
-- Client access is only a presentation hint; SAVE/REMOVE are always
-- re-authorized and item types/quantities/prices revalidated by the server.

if isServer() then return end

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "KIPN_Shared"
require "KIPN_ItemTypeSuggestions"

KIPN_MarketplaceAdminUI = ISPanel:derive("KIPN_MarketplaceAdminUI")

local WIDTH = 700
local HEIGHT = 500
local ROW_HEIGHT = 24
local SUGGESTION_MAX_RESULTS = 6
local SUGGESTION_ROW_HEIGHT = 22

-- Vehicle script full types (e.g. "Base.CarNormal") live in a
-- separate ScriptManager registry from items and are NOT in the
-- baked-in KIPN.ItemTypeSuggestions.ITEMS list. This module scans
-- the loaded vehicle scripts itself -- guarded per script so one bad
-- modded entry cannot abort the scan -- rather than relying on the
-- shared RefreshFromLoadedScripts() helper. The set drives the
-- vehicle-vs-item decision; the sorted list feeds autocomplete.
local vehicleFullTypeSet = nil
local vehicleFullTypeList = nil

local function refreshVehicleFullTypeSet()
    vehicleFullTypeSet = {}
    vehicleFullTypeList = {}

    local ok, all = pcall(function()
        local manager = getScriptManager and getScriptManager()
        if not manager or type(manager.getAllVehicleScripts) ~= "function" then
            return nil
        end
        return manager:getAllVehicleScripts()
    end)

    if not ok or not all then
        print("[KIPN] Marketplace Admin UI: no vehicle scripts available for autocomplete")
        return
    end

    local total = all:size()
    for index = 0, total - 1 do
        local getOk, fullType = pcall(function()
            local vs = all:get(index)
            return vs and vs:getFullName()
        end)
        if getOk
            and type(fullType) == "string"
            and fullType ~= ""
            and not vehicleFullTypeSet[fullType]
        then
            vehicleFullTypeSet[fullType] = true
            vehicleFullTypeList[#vehicleFullTypeList + 1] = fullType
        end
    end

    table.sort(vehicleFullTypeList)
    print(string.format(
        "[KIPN] Marketplace Admin UI: %d vehicle type(s) loaded for autocomplete",
        #vehicleFullTypeList
    ))
end

local function getVehicleFullTypeList()
    if not vehicleFullTypeList then
        refreshVehicleFullTypeSet()
    end
    return vehicleFullTypeList or {}
end

local function isVehicleFullType(fullType)
    if type(fullType) ~= "string" or fullType == "" then
        return false
    end
    if not vehicleFullTypeSet then
        refreshVehicleFullTypeSet()
    end
    return vehicleFullTypeSet[fullType] == true
end

function KIPN_MarketplaceAdminUI.Open()
    -- Make sure autocomplete and the vehicle-type check see every
    -- item and vehicle script the running game has loaded, mods
    -- included -- not just the baked-in vanilla reference list.
    if KIPN.ItemTypeSuggestions
        and KIPN.ItemTypeSuggestions.RefreshFromLoadedScripts
    then
        pcall(KIPN.ItemTypeSuggestions.RefreshFromLoadedScripts)
    end
    refreshVehicleFullTypeSet()

    local instance = KIPN_MarketplaceAdminUI.instance

    if not instance then
        local screenW = getCore():getScreenWidth()
        local screenH = getCore():getScreenHeight()
        instance = KIPN_MarketplaceAdminUI:new(
            (screenW - WIDTH) / 2,
            (screenH - HEIGHT) / 2,
            WIDTH,
            HEIGHT
        )
        instance:initialise()
        instance:instantiate()
        KIPN_MarketplaceAdminUI.instance = instance
    end

    instance:setVisible(true)
    instance:addToUIManager()
    instance:bringToTop()
    instance:requestCatalog()
end

function KIPN_MarketplaceAdminUI:new(x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.moveWithMouse = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.94 }
    o.borderColor = { r = 0.2, g = 0.9, b = 0.45, a = 0.8 }
    o.listings = {}
    o.selectedListingId = nil
    o.rowHitRects = {}
    o.itemSuggestionButtons = {}
    o.status = "Requesting KIPN listings..."
    return o
end

function KIPN_MarketplaceAdminUI:initialise()
    ISPanel.initialise(self)
end

function KIPN_MarketplaceAdminUI:createChildren()
    ISPanel.createChildren(self)

    self.titleLabel = ISLabel:new(
        16, 12, 24, "KIPN MARKETPLACE ITEMS",
        0.2, 0.9, 0.45, 1, UIFont.Medium, true
    )
    self:addChild(self.titleLabel)

    self.closeButton = ISButton:new(
        self.width - 86, 10, 70, 26, "CLOSE",
        self, KIPN_MarketplaceAdminUI.onClose
    )
    self.closeButton:initialise()
    self:addChild(self.closeButton)

    self.itemLabel = ISLabel:new(
        16, 54, 20, "ITEM FULL TYPE", 1, 1, 1, 1, UIFont.Small, true
    )
    self:addChild(self.itemLabel)

    self.itemEntry = ISTextEntryBox:new("", 16, 74, 360, 26)
    self.itemEntry:initialise()
    self.itemEntry:instantiate()
    self.itemEntry:setMaxTextLength(200)
    self.itemEntry.target = self
    self.itemEntry.onTextChangeFunction =
        KIPN_MarketplaceAdminUI.onItemTypeChanged
    self:addChild(self.itemEntry)

    self.quantityLabel = ISLabel:new(
        392, 54, 20, "QUANTITY", 1, 1, 1, 1, UIFont.Small, true
    )
    self:addChild(self.quantityLabel)

    self.quantityEntry = ISTextEntryBox:new("1", 392, 74, 76, 26)
    self.quantityEntry:initialise()
    self.quantityEntry:instantiate()
    self.quantityEntry:setOnlyNumbers(true)
    self:addChild(self.quantityEntry)

    self.priceLabel = ISLabel:new(
        480, 54, 20, "PRICE", 1, 1, 1, 1, UIFont.Small, true
    )
    self:addChild(self.priceLabel)

    self.priceEntry = ISTextEntryBox:new("", 480, 74, 90, 26)
    self.priceEntry:initialise()
    self.priceEntry:instantiate()
    self.priceEntry:setOnlyNumbers(true)
    self:addChild(self.priceEntry)

    self.saveButton = ISButton:new(
        582, 74, 102, 26, "ADD / SAVE",
        self, KIPN_MarketplaceAdminUI.onSave
    )
    self.saveButton:initialise()
    self:addChild(self.saveButton)

    self.removeButton = ISButton:new(
        16, self.height - 42, 150, 26, "REMOVE SELECTED",
        self, KIPN_MarketplaceAdminUI.onRemove
    )
    self.removeButton:initialise()
    self.removeButton:setEnable(false)
    self:addChild(self.removeButton)

    self.clearButton = ISButton:new(
        176, self.height - 42, 120, 26, "NEW ITEM",
        self, KIPN_MarketplaceAdminUI.onClear
    )
    self.clearButton:initialise()
    self:addChild(self.clearButton)
end

function KIPN_MarketplaceAdminUI:requestCatalog()
    self.status = "Requesting KIPN listings..."
    sendClientCommand(
        "KIPN",
        KIPN.Shared.Commands.GET_KIPN_MARKETPLACE_ITEMS,
        {}
    )
end

function KIPN_MarketplaceAdminUI:onClose()
    self:clearItemSuggestions()
    self:setVisible(false)
    self:removeFromUIManager()
end

function KIPN_MarketplaceAdminUI:onClear()
    self:clearItemSuggestions()
    self.selectedListingId = nil
    self.itemEntry:setText("")
    self.quantityEntry:setText("1")
    self.quantityEntry:setEditable(true)
    self.pendingIsVehicle = false
    self.priceEntry:setText("")
    self.removeButton:setEnable(false)
    self.status = "Enter an item type, quantity, and price."
end

function KIPN_MarketplaceAdminUI:onSave()
    local itemFullType = self.itemEntry:getText()
    if type(itemFullType) == "string" then
        itemFullType = itemFullType:match("^%s*(.-)%s*$")
    end
    local unitPrice = tonumber(self.priceEntry:getText())
    local isVehicle = isVehicleFullType(itemFullType)

    -- A vehicle listing always sells exactly one vehicle; the server
    -- ignores the quantity field for vehicles, so mirror that here.
    local quantity = isVehicle and 1 or tonumber(self.quantityEntry:getText())

    if not itemFullType
        or itemFullType == ""
        or not quantity
        or quantity <= 0
        or quantity > 100
        or not unitPrice
        or unitPrice <= 0
    then
        self.status = "Enter an item type, quantity from 1 to 100, and positive price."
        return
    end

    self.status = isVehicle and "Saving vehicle listing..." or "Saving listing..."
    sendClientCommand(
        "KIPN",
        KIPN.Shared.Commands.SAVE_KIPN_MARKETPLACE_ITEM,
        {
            listingId = self.selectedListingId,
            itemFullType = itemFullType,
            quantity = math.floor(quantity),
            unitPrice = math.floor(unitPrice),
        }
    )
end

function KIPN_MarketplaceAdminUI:onRemove()
    if not self.selectedListingId then return end

    self.status = "Removing listing..."
    sendClientCommand(
        "KIPN",
        KIPN.Shared.Commands.REMOVE_KIPN_MARKETPLACE_ITEM,
        { listingId = self.selectedListingId }
    )
end

function KIPN_MarketplaceAdminUI:onMouseDown(x, y)
    for _, rect in ipairs(self.rowHitRects or {}) do
        if x >= rect.x1 and x <= rect.x2 and y >= rect.y1 and y < rect.y2 then
            local listing = self.listings[rect.index]
            if listing then
                self.selectedListingId = listing.id
                self.itemEntry:setText(tostring(listing.itemFullType or ""))
                self.quantityEntry:setText(tostring(listing.quantity or 1))
                self.priceEntry:setText(tostring(listing.unitPrice or ""))
                self:clearItemSuggestions()
                self:syncVehicleQuantityLock()
                self.removeButton:setEnable(true)
                self.status = "Editing " .. tostring(listing.displayName or listing.itemFullType)
            end
            return true
        end
    end

    return ISPanel.onMouseDown(self, x, y)
end

local function computeItemSuggestions(query)
    local source =
        KIPN.ItemTypeSuggestions
        and KIPN.ItemTypeSuggestions.ITEMS
        or {}
    local matches = {}
    local seen = {}

    -- Vehicle types are ranked slightly after items so an exact item
    -- prefix still wins, but they are always in the candidate pool.
    local function scan(candidates, rankBonus)
        for _, candidate in ipairs(candidates) do
            if type(candidate) == "string" and not seen[candidate] then
                local bareCandidate = candidate:gsub("^Base%.", "")
                local lowerCandidate = candidate:lower()
                local lowerBare = bareCandidate:lower()
                local isPrefix =
                    lowerCandidate:sub(1, #query) == query
                    or lowerBare:sub(1, #query) == query
                local isSubstring =
                    not isPrefix
                    and (
                        lowerCandidate:find(query, 1, true) ~= nil
                        or lowerBare:find(query, 1, true) ~= nil
                    )

                if isPrefix or isSubstring then
                    seen[candidate] = true
                    matches[#matches + 1] = {
                        value = candidate,
                        rank = (isPrefix and 0 or 1) + (rankBonus or 0),
                    }
                end
            end
        end
    end

    scan(source, 0)
    scan(getVehicleFullTypeList(), 0)

    table.sort(matches, function(a, b)
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        return a.value < b.value
    end)

    local capped = {}
    for index = 1, math.min(#matches, SUGGESTION_MAX_RESULTS) do
        capped[index] = matches[index].value
    end
    return capped
end

function KIPN_MarketplaceAdminUI:clearItemSuggestions()
    for _, button in ipairs(self.itemSuggestionButtons or {}) do
        self:removeChild(button)
    end
    self.itemSuggestionButtons = {}
end

function KIPN_MarketplaceAdminUI:updateItemSuggestions(textEntryBox)
    self:clearItemSuggestions()

    local query = textEntryBox
        and textEntryBox:getText():lower():match("^%s*(.-)%s*$")
        or ""

    if query == "" then return end

    for index, value in ipairs(computeItemSuggestions(query)) do
        local button = ISButton:new(
            16,
            104 + (index - 1) * SUGGESTION_ROW_HEIGHT,
            360,
            SUGGESTION_ROW_HEIGHT - 2,
            value,
            self,
            KIPN_MarketplaceAdminUI.onItemSuggestionClick
        )
        button.internal = value
        button:initialise()
        button:instantiate()
        self:addChild(button)
        self.itemSuggestionButtons[#self.itemSuggestionButtons + 1] = button
    end
end

-- Vehicle listings sell exactly one vehicle, so lock the quantity
-- field to 1 as soon as the entered type resolves to a vehicle.
function KIPN_MarketplaceAdminUI:syncVehicleQuantityLock()
    local fullType = self.itemEntry:getText()
    if type(fullType) == "string" then
        fullType = fullType:match("^%s*(.-)%s*$")
    end

    local isVehicle = isVehicleFullType(fullType)
    self.pendingIsVehicle = isVehicle

    if isVehicle then
        self.quantityEntry:setText("1")
        self.quantityEntry:setEditable(false)
    else
        self.quantityEntry:setEditable(true)
    end
end

function KIPN_MarketplaceAdminUI:onItemTypeChanged(textEntryBox)
    self:updateItemSuggestions(textEntryBox)
    self:syncVehicleQuantityLock()
end

function KIPN_MarketplaceAdminUI:onItemSuggestionClick(button)
    if button and button.internal then
        self.itemEntry:setText(button.internal)
    end
    self:clearItemSuggestions()
    self:syncVehicleQuantityLock()
end

function KIPN_MarketplaceAdminUI:prerender()
    ISPanel.prerender(self)

    self:drawRectBorder(14, 112, self.width - 28, self.height - 170, 0.7, 0.2, 0.9, 0.45)
    self:drawText("ITEM", 24, 120, 0.7, 0.9, 0.75, 1, UIFont.Small)
    self:drawText("FULL TYPE", 240, 120, 0.7, 0.9, 0.75, 1, UIFont.Small)
    self:drawTextRight("QUANTITY", self.width - 112, 120, 0.7, 0.9, 0.75, 1, UIFont.Small)
    self:drawTextRight("PRICE", self.width - 30, 120, 0.7, 0.9, 0.75, 1, UIFont.Small)

    self.rowHitRects = {}
    local y = 142
    local maxRows = math.floor((self.height - 210) / ROW_HEIGHT)

    for index = 1, math.min(#self.listings, maxRows) do
        local listing = self.listings[index]
        local selected = tostring(listing.id) == tostring(self.selectedListingId)

        if selected then
            self:drawRect(18, y - 2, self.width - 36, ROW_HEIGHT, 0.28, 0.2, 0.9, 0.45)
        elseif index % 2 == 0 then
            self:drawRect(18, y - 2, self.width - 36, ROW_HEIGHT, 0.13, 1, 1, 1)
        end

        local isVehicleRow = listing.kind == "vehicle"
        local rowName = tostring(listing.displayName or "Unknown")
        if isVehicleRow then
            rowName = rowName .. "  [vehicle]"
        end

        self:drawText(rowName, 24, y, 1, 1, 1, 1, UIFont.Small)
        self:drawText(tostring(listing.itemFullType or ""), 240, y, 0.75, 0.75, 0.75, 1, UIFont.Small)
        self:drawTextRight(
            isVehicleRow and "1" or tostring(listing.quantity or 1),
            self.width - 112, y, 1, 1, 1, 1, UIFont.Small
        )
        self:drawTextRight(tostring(listing.unitPrice or 0), self.width - 30, y, 1, 1, 1, 1, UIFont.Small)

        self.rowHitRects[#self.rowHitRects + 1] = {
            x1 = 18, x2 = self.width - 18,
            y1 = y - 2, y2 = y - 2 + ROW_HEIGHT,
            index = index,
        }
        y = y + ROW_HEIGHT
    end

    if #self.listings == 0 then
        self:drawTextCentre("No KIPN items are listed.", self.width / 2, 176, 0.7, 0.7, 0.7, 1, UIFont.Small)
    end

    self:drawText(
        tostring(self.status or ""), 310, self.height - 36,
        0.75, 0.85, 0.78, 1, UIFont.Small
    )
end

local function onServerCommand(module, command, args)
    if module ~= "KIPN"
        or command ~= KIPN.Shared.Commands.SERVER_RESPONSE
        or type(args) ~= "table"
    then
        return
    end

    local instance = KIPN_MarketplaceAdminUI.instance
    if not instance or not instance:getIsVisible() then return end

    if args.event == KIPN.Shared.ResponseEvents.KIPN_MARKETPLACE_ITEMS_DATA then
        local data = args.data or {}

        if data.isAdmin ~= true then
            instance.status = "The server denied marketplace administration access."
            instance.saveButton:setEnable(false)
            instance.removeButton:setEnable(false)
            return
        end

        instance.listings = type(data.items) == "table" and data.items or {}
        instance.status = string.format("%d KIPN item(s) listed.", #instance.listings)
    elseif args.event == KIPN.Shared.ResponseEvents.KIPN_MARKETPLACE_ADMIN_RESULT then
        local data = args.data or {}
        if data.success then
            instance.status = "Marketplace listing saved."
            instance:onClear()
            instance:requestCatalog()
        else
            local reason = tostring(data.reason or "UNKNOWN")
            local friendly = ({
                ITEM_TYPE_NOT_FOUND = "No item or vehicle script matches that full type.",
                VEHICLE_SALES_DISABLED = "Vehicle sales are disabled in the sandbox options.",
                ITEM_ALREADY_LISTED = "That type is already listed. Select its row to edit it.",
                ADMIN_REQUIRED = "The server denied marketplace administration access.",
            })[reason]
            instance.status = friendly or ("Marketplace change failed: " .. reason)
        end
    end
end

if not KIPN_MarketplaceAdminUI._listenerInstalled then
    KIPN_MarketplaceAdminUI._listenerInstalled = true
    Events.OnServerCommand.Add(onServerCommand)
end

print("[KIPN] Marketplace Admin UI loaded")
