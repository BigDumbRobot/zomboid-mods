-- KIPNCareers_Careers.lua  (framework core)
--
-- One registration per career. A career describes itself once and gets back
-- an object that does everything every career does the same way: its saved
-- data slice, ids, the shared inbox, reputation, money owed to players,
-- licenses, opening and closing a storefront, flyers, and its commands on
-- the KIPN router. The same id is used everywhere -- the storefront
-- registry, the threats layer, the data slice and the inbox.
--
--   local Career = KIPNCareers.Careers.Register("mechanic", {
--       label = "Mechanic",
--       idPrefix = "mech-",                 -- in front of every id this career makes
--       schemaVersion = 1,
--       tables = { "orders", "messages" },  -- the career's own tables in its slice
--       storefronts = "shops",              -- the slice table holding storefront records
--       storefrontNoun = "shop",            -- as it reads in a message to the player
--       events = { RESULT = "kipnMechanic.result", NOTIFICATION = "kipnMechanic.notification" },
--       startingReputation = function() return settings().StartingReputation end,
--       license = { item = "KIPNCareers.MechanicBusinessLicense", tokenField = "kipnMechToken",
--                   name = "Mechanic Business License -- " },
--       storefront = { capability = "career.mechanic.shop", label = "Mechanic Shop",
--                      permission = "careers.mechanic.owner" },
--       flyer = { fields = { "name", "adText" }, title = "Flyer -- ",
--                 write = function(modData, record, fields, revision) ... return shownName end },
--   })
--
-- Every field but `label` is optional; a career only fills in what it uses.
-- The slice always has: sequence, schemaVersion, licenses, reputation,
-- pendingCurrency, flyerQueue, meta, and the storefront table.
--
-- Registering the same id again updates the definition and returns the same
-- object (safe on Lua reload).

if isClient() and not isServer() then return end

require "KIPNCareers_Shared"
require "KIPNCareers_Host"
require "KIPNCareers_Economy"
require "KIPNCareers_ZoneBridge"
require "KIPNCareers_Storefronts"

local Shared = KIPNCareers.Shared
local Host = KIPNCareers.Host
local Economy = KIPNCareers.Economy
local ZoneBridge = KIPNCareers.ZoneBridge
local Storefronts = KIPNCareers.Storefronts
local Careers = KIPNCareers.Careers or {}
KIPNCareers.Careers = Careers
Careers._careers = Careers._careers or {}

Careers.INBOX_LIMIT = 30

local SLICE_TABLES = { "licenses", "reputation", "pendingCurrency", "flyerQueue", "meta" }

local SITE_MESSAGES = {
    NO_CLAIM_ZONE = "This building overlaps a KIPN No Claim zone.",
    STOREFRONT_OCCUPIED = "This building overlaps an existing storefront.",
}

-- Loot containers a flyer may turn up in.
local flyerContainerTypes = {
    counter = true, shelves = true, shelf = true, crate = true,
    locker = true, filingcabinet = true, desk = true, magazine = true,
    grocery = true, postbox = true, mailbox = true,
}

local function log(level, message)
    Shared.Log("Careers", level, message)
end

-- The framework's own sandbox options that every career follows.
function Careers.Settings()
    local raw = SandboxVars and SandboxVars.KIPNCareers or {}
    return {
        FlyersPerRestart = math.max(0, math.floor(tonumber(raw.FlyersPerRestart) or Shared.Defaults.FLYERS_PER_RESTART)),
        FlyerSpawnChancePercent = Shared.Clamp(raw.FlyerSpawnChancePercent or Shared.Defaults.FLYER_CHANCE_PERCENT, 0, 100),
        BlockAnySafehouseStorefront = raw.BlockAnySafehouseStorefront == true,
    }
end

-- True when the player stands at a terminal inside a Career Services zone:
-- where every career sells its license.
function Careers.HasServicesAccess(computerId, player)
    if not computerId or not Host.AtComputer(computerId, player) then return false end
    return ZoneBridge.ComputerHasCapability(computerId, Shared.Capabilities.CAREER_SERVICES)
end

------------------------------------------------------------
-- REGISTRY
------------------------------------------------------------

local Career = {}
Career.__index = Career

function Careers.Register(id, definition)
    if type(id) ~= "string" or id == "" or type(definition) ~= "table" then
        log("Error", "Register ignored: id and definition are required")
        return nil
    end
    local career = Careers._careers[id] or setmetatable({ id = id }, Career)
    career.label = tostring(definition.label or id)
    career.slice = definition.slice or id
    career.idPrefix = tostring(definition.idPrefix or "")
    career.schemaVersion = tonumber(definition.schemaVersion) or 1
    career.tables = type(definition.tables) == "table" and definition.tables or {}
    career.storefrontTable = definition.storefronts
    career.storefrontNoun = tostring(definition.storefrontNoun or "storefront")
    career.events = type(definition.events) == "table" and definition.events or {}
    career.logScope = definition.logScope or career.label
    career.startingReputation = definition.startingReputation
    career.license = definition.license
    career.storefront = type(definition.storefront) == "table" and definition.storefront or {}
    career.flyer = definition.flyer
    career.migrate = definition.migrate
    career.onClose = definition.onClose
    Careers._careers[id] = career
    if career.storefrontTable then
        Storefronts.Register(id, function() return career:Storefronts() end)
    end
    log("Info", "Registered career=" .. id)
    return career
end

function Careers.Get(id)
    return Careers._careers[id]
end

-- { [id] = career }
function Careers.All()
    return Careers._careers
end

------------------------------------------------------------
-- DATA
------------------------------------------------------------

-- The career's slice of the saved data, with its tables in place.
function Career:State()
    local root = Host.Root()
    if not root then return nil end
    root[self.slice] = type(root[self.slice]) == "table" and root[self.slice] or {}
    local data = root[self.slice]
    if self.migrate and not self._migrated then
        self._migrated = true
        local ok, err = pcall(self.migrate, root, data)
        if not ok then self:Log("Error", "data migration failed error=" .. tostring(err)) end
    end
    data.schemaVersion = math.max(tonumber(data.schemaVersion) or 0, self.schemaVersion)
    data.sequence = tonumber(data.sequence) or 0
    for _, name in ipairs(SLICE_TABLES) do
        data[name] = type(data[name]) == "table" and data[name] or {}
    end
    for _, name in ipairs(self.tables) do
        data[name] = type(data[name]) == "table" and data[name] or {}
    end
    if self.storefrontTable then
        local name = self.storefrontTable
        data[name] = type(data[name]) == "table" and data[name] or {}
    end
    return data
end

function Career:Save()
    return Host.Save()
end

function Career:Log(level, message)
    Shared.Log(self.logScope, level, message)
end

function Career:MakeId(prefix)
    local data = self:State()
    if not data then return nil end
    data.sequence = data.sequence + 1
    return self.idPrefix .. tostring(prefix) .. "-" .. tostring(math.floor(Host.NowHours() * 1000))
        .. "-" .. tostring(data.sequence) .. "-" .. tostring(Host.RandomInteger(1000, 9999))
end

------------------------------------------------------------
-- TALKING TO PLAYERS
------------------------------------------------------------

-- The answer to a command, on the career's own RESULT event.
function Career:Result(player, action, ok, code, message, extra)
    self:Log(ok and "Info" or "Warn", "result action=" .. tostring(action) .. " code=" .. tostring(code) .. " player=" .. Host.Username(player))
    local payload = type(extra) == "table" and extra or {}
    payload.action = action
    payload.ok = ok == true
    payload.code = code
    payload.message = message
    return Host.Send(player, self.events.RESULT or Shared.Events.RESULT, payload)
end

-- Called with (ownerKey, notification, careerId) for every notice any career
-- files, so another mod can mirror the inbox somewhere else.
function Careers.SetNotificationPublisher(publisher)
    Careers.NotificationPublisher = type(publisher) == "function" and publisher or nil
    return Careers.NotificationPublisher ~= nil
end

-- A private notice in the shared Careers inbox (careers.notifications).
function Career:Notify(ownerKey, title, body, relatedId)
    local root = Host.Root()
    if not root or not ownerKey then return false end
    root.notifications[ownerKey] = root.notifications[ownerKey] or {}
    local notification = {
        id = self:MakeId("notice"), title = Shared.Trim(title, 80), body = Shared.Trim(body, 500),
        relatedId = relatedId, createdAt = Host.NowHours(), unread = true, source = self.id,
    }
    local list = root.notifications[ownerKey]
    list[#list + 1] = notification
    while #list > Careers.INBOX_LIMIT do table.remove(list, 1) end
    local player = Host.OnlinePlayerByIdentity(ownerKey)
    if player then
        if self.events.NOTIFICATION then Host.Send(player, self.events.NOTIFICATION, notification) end
        Host.Send(player, Shared.Events.INBOX_CHANGED, { id = notification.id, source = self.id })
    end
    if Careers.NotificationPublisher then
        local ok, err = pcall(Careers.NotificationPublisher, ownerKey, notification, self.id)
        if not ok then self:Log("Warn", "NotificationPublisher failed=" .. tostring(err)) end
    end
    return true
end

-- The owner's notices from every career, oldest first.
function Careers.Inbox(ownerKey)
    local root = Host.Root()
    return root and ownerKey and root.notifications[ownerKey] or {}
end

------------------------------------------------------------
-- REPUTATION  (0-100 per owner, per career)
------------------------------------------------------------

function Career:StartingReputation()
    local value = self.startingReputation
    if type(value) == "function" then value = value() end
    return Shared.Clamp(value or 50, 0, 100)
end

function Career:ReputationFor(ownerKey)
    local starting = self:StartingReputation()
    local data = self:State()
    if not data then return starting end
    if data.reputation[ownerKey] == nil then data.reputation[ownerKey] = starting end
    return tonumber(data.reputation[ownerKey]) or starting
end

function Career:AdjustReputation(ownerKey, delta, reason)
    local data = self:State()
    if not data then return nil end
    local value = Shared.Clamp(self:ReputationFor(ownerKey) + (tonumber(delta) or 0), 0, 100)
    data.reputation[ownerKey] = value
    self:Log("Info", "reputation owner=" .. tostring(ownerKey) .. " -> " .. tostring(value) .. " (" .. tostring(reason) .. ")")
    return value
end

------------------------------------------------------------
-- MONEY OWED  (payouts and refunds wait here until the payee is around)
------------------------------------------------------------

function Career:Pending(ownerKey)
    local data = self:State()
    return data and Economy.Pending(data.pendingCurrency, ownerKey) or 0
end

function Career:Credit(ownerKey, amount, reason)
    local data = self:State()
    if not data then return false end
    self:Log("Info", "credit owner=" .. tostring(ownerKey) .. " amount=" .. tostring(amount) .. " (" .. tostring(reason) .. ")")
    return Economy.Credit(data.pendingCurrency, ownerKey, amount)
end

function Career:SettlePending(player)
    local data = self:State()
    local ownerKey = Host.Identity(player)
    if not data or not ownerKey then return false end
    local ok, amount = Economy.Settle(data.pendingCurrency, ownerKey, player)
    if not ok then return false end
    if amount > 0 then
        self:Notify(ownerKey, "Currency delivered", tostring(amount) .. " in pending KIPN currency was placed in your inventory.")
        self:Save()
    end
    return true
end

------------------------------------------------------------
-- LICENSES  (a bearer item whose token matches a saved record)
------------------------------------------------------------

-- Charges `price`, puts the license item in the player's inventory and files
-- its record. Returns the token id, or nil, a code and a message; on any
-- failure the player gets their money back.
function Career:IssueLicense(player, price)
    local spec = self.license
    local ownerKey = Host.Identity(player)
    local data = self:State()
    if not spec or not ownerKey or not data then return nil, "STATE_UNAVAILABLE", "Career state is unavailable." end
    local paid, reason, receipt = Economy.Charge(player, price)
    if not paid then return nil, reason, "Payment failed: " .. tostring(reason) end
    local tokenId = self:MakeId("license")
    local inventory = player:getInventory()
    local item = inventory:AddItem(spec.item)
    if not item then
        Economy.RefundReceipt(receipt)
        return nil, "LICENSE_CREATION_FAILED", "The license could not be issued; payment was refunded."
    end
    local modData = item:getModData()
    modData[spec.tokenField] = tokenId
    for key, value in pairs(type(spec.modData) == "table" and spec.modData or {}) do modData[key] = value end
    if type(item.setName) == "function" then item:setName(tostring(spec.name or (self.label .. " License - ")) .. Host.Username(player)) end
    data.licenses[tokenId] = {
        id = tokenId, careerId = self.id, ownerKey = ownerKey, issuedTo = Host.Username(player),
        issuedAt = Host.NowHours(), price = price, status = "ACTIVE",
    }
    if not self:Save() then
        inventory:Remove(item)
        data.licenses[tokenId] = nil
        Economy.RefundReceipt(receipt)
        return nil, "PERSISTENCE_FAILED", "License issuance could not be saved; payment was refunded."
    end
    return tokenId
end

-- An item of `fullType` in the player's inventory whose `tokenField` holds
-- this token: { item = , container = }, or nil.
function Careers.FindTokenItem(player, fullType, tokenField, tokenId)
    local inventory = player and player:getInventory()
    for _, entry in ipairs(Host.CollectItems(inventory, fullType, {})) do
        if tostring(entry.item:getModData()[tokenField] or "") == tostring(tokenId or "") then return entry end
    end
    return nil
end

-- The unused license record for this token and the item carrying it, or nil
-- when either is missing.
function Career:FindLicense(player, tokenId)
    local spec = self.license
    local data = self:State()
    if not spec or not data then return nil end
    local license = data.licenses[tostring(tokenId or "")]
    if not license or license.status ~= "ACTIVE" then return nil end
    local entry = Careers.FindTokenItem(player, spec.item, spec.tokenField, tokenId)
    if not entry then return nil end
    return license, entry
end

------------------------------------------------------------
-- STOREFRONTS
------------------------------------------------------------

-- { [id] = record }. A record carries at least id, ownerKey, bounds, anchor,
-- active and createdAt; everything else is the career's own.
function Career:Storefronts()
    local data = self:State()
    return data and self.storefrontTable and data[self.storefrontTable] or {}
end

function Career:OwnedStorefront(ownerKey)
    for _, record in pairs(self:Storefronts()) do
        if record.ownerKey == ownerKey and record.active ~= false then return record end
    end
    return nil
end

function Career:StorefrontAt(x, y, z)
    for _, record in pairs(self:Storefronts()) do
        if record.active ~= false and Storefronts.Contains(record.bounds, x, y, z) then return record end
    end
    return nil
end

-- The storefront this terminal stands in. With `player`, only when they are
-- at the terminal.
function Career:StorefrontAtComputer(computerId, player)
    local x, y, z = Host.ComputerCoords(computerId)
    if not x then return nil end
    if player and not Host.AtComputer(computerId, player) then return nil end
    return self:StorefrontAt(x, y, z)
end

-- Storefronts.CheckSite with the sentence to show the player. Returns the
-- building rectangle, or nil, a code and a message.
function Career:CheckSite(player)
    if not self:State() then return nil, "STOREFRONT_OCCUPIED", SITE_MESSAGES.STOREFRONT_OCCUPIED end
    local rect, code = Storefronts.CheckSite(player)
    if rect then return rect end
    local message = SITE_MESSAGES[code]
    if code == "SAFEHOUSE_OWNERSHIP_REQUIRED" then
        message = "You cannot establish a " .. self.storefrontNoun .. " in another player's safehouse."
    end
    return nil, code, message or "Stand inside a valid building."
end

local function grantPermission(accountId, permission)
    local permissions = KIPN and KIPN.Server and KIPN.Server.Permissions
    if accountId and permission and permissions and type(permissions.GrantPermission) == "function" then
        pcall(permissions.GrantPermission, accountId, permission)
    end
end

local function revokePermission(accountId, permission)
    local permissions = KIPN and KIPN.Server and KIPN.Server.Permissions
    if accountId and permission and permissions and type(permissions.RevokePermission) == "function" then
        pcall(permissions.RevokePermission, accountId, permission)
    end
end

-- Spends the license and opens `record` (already checked with CheckSite):
-- files it, grants the owner permission and draws the capability zone that
-- makes the career's storefront menu program appear there. Returns true, or
-- false, a code and a message with the license restored.
function Career:OpenStorefront(player, license, entry, record)
    local records = self:Storefronts()
    local ownerKey = Host.Identity(player)
    entry.container:Remove(entry.item)
    license.status = "REDEEMED"
    license.redeemedAt = Host.NowHours()
    license.redeemedBy = ownerKey
    record.ownerAccountId = Host.KipnPlayerId(player)
    records[record.id] = record
    self:ReputationFor(ownerKey)
    if not self:Save() then
        records[record.id] = nil
        license.status = "ACTIVE"
        license.redeemedAt = nil
        license.redeemedBy = nil
        entry.container:AddItem(entry.item)
        return false, "PERSISTENCE_FAILED", "The " .. self.storefrontNoun .. " could not be saved; your license was restored."
    end
    -- Non-fatal from here: the storefront is already valid.
    grantPermission(record.ownerAccountId, self.storefront.permission)
    if self.storefront.capability then
        local zoneId = ZoneBridge.CreateBusinessZone(record.bounds, record.id, self.storefront.capability, self.storefront.label)
        if zoneId then
            record.capabilityZoneId = zoneId
            self:Save()
        else
            self:Log("Warn", "capability zone not created for " .. tostring(record.id))
        end
    end
    return true
end

-- Closes a storefront for good: it stops blocking the building, loses its
-- zone and flyers, and the owner loses the storefront permission. Orders in
-- flight are left to the career (its `onClose(record)` runs first; with none,
-- they run out and refund the way any unattended order does). The record is
-- kept, inactive. Returns true, or false and a code.
function Career:CloseStorefront(id, closedBy)
    local data = self:State()
    local record = data and self:Storefronts()[id]
    if not record or record.active == false then return false, "STOREFRONT_NOT_FOUND" end
    if self.onClose then
        local ok, err = pcall(self.onClose, record)
        if not ok then self:Log("Error", "onClose failed storefront=" .. tostring(id) .. " error=" .. tostring(err)) end
    end
    local queued = data.flyerQueue[id]
    record.active = false
    record.closedAt = Host.NowHours()
    record.closedBy = closedBy
    data.flyerQueue[id] = nil
    if not self:Save() then
        record.active = true
        record.closedAt = nil
        record.closedBy = nil
        data.flyerQueue[id] = queued
        return false, "PERSISTENCE_FAILED"
    end
    ZoneBridge.RemoveBusinessZone(record.capabilityZoneId)
    if not self:OwnedStorefront(record.ownerKey) then
        local accountId = record.ownerAccountId
            or tostring(record.ownerKey or ""):gsub("^steam:", ""):gsub("^user:", "")
        revokePermission(accountId, self.storefront.permission)
    end
    self:Notify(record.ownerKey, "Storefront closed",
        "Your " .. self.storefrontNoun .. " \"" .. tostring(record.name or id) .. "\" was closed.", id)
    self:Save()
    self:Log("Info", "closed storefront=" .. tostring(id) .. " by=" .. tostring(closedBy))
    return true
end

function Careers.CloseStorefront(careerId, id, closedBy)
    local career = Careers._careers[careerId]
    if not career then return false, "UNKNOWN_CAREER" end
    return career:CloseStorefront(id, closedBy)
end

------------------------------------------------------------
-- FLYERS  (restart-gated; the shared BusinessFlyer item)
--
-- Saving a storefront's details raises its flyerRevision. At the next server
-- start the new revision is queued, and FlyersPerRestart copies of it turn
-- up in loot containers as the world loads.
------------------------------------------------------------

function Career:ActivateFlyerQueue()
    local data = self:State()
    if not data or not self.flyer then return false end
    local count = Careers.Settings().FlyersPerRestart
    for id, record in pairs(self:Storefronts()) do
        local revision = tonumber(record.flyerRevision) or 0
        if record.active ~= false and revision > (tonumber(record.distributedFlyerRevision) or 0) then
            local fields = {}
            for _, name in ipairs(self.flyer.fields or {}) do fields[name] = record[name] end
            data.flyerQueue[id] = { revision = revision, remaining = count, fields = fields }
            record.distributedFlyerRevision = revision
        end
    end
    return self:Save()
end

-- Rolls for a flyer in this world object's container. True when one was left.
function Career:DistributeFlyer(object)
    if not self.flyer or not object or type(object.getContainer) ~= "function" then return false end
    local container = object:getContainer()
    if not container then return false end
    local containerType = type(container.getType) == "function" and string.lower(tostring(container:getType() or "")) or ""
    if not flyerContainerTypes[containerType] then return false end
    if Host.RandomInteger(1, 100) > Careers.Settings().FlyerSpawnChancePercent then return false end
    local data = self:State()
    if not data then return false end
    local records = self:Storefronts()
    local candidates = {}
    for id, queue in pairs(data.flyerQueue) do
        if (tonumber(queue.remaining) or 0) > 0 and records[id] and records[id].active ~= false then
            candidates[#candidates + 1] = { record = records[id], queue = queue }
        end
    end
    if #candidates == 0 then return false end
    local selected = candidates[Host.RandomInteger(1, #candidates)]
    local item = container:AddItem(Shared.Items.FLYER)
    if not item then return false end
    local queue = selected.queue
    local name = self.flyer.write(item:getModData(), selected.record, queue.fields or {}, queue.revision)
    if type(item.setName) == "function" then item:setName(tostring(self.flyer.title or "Flyer - ") .. tostring(name)) end
    queue.remaining = math.max(0, (tonumber(queue.remaining) or 0) - 1)
    self:Save()
    return true
end

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

-- Puts the career's handlers on the KIPN router. A command named in
-- `sessionCommands` is refused with `authMessage` until the player has
-- logged in to KIPN. Returns false while the KIPN server is not ready, so
-- the caller can try again.
function Career:RegisterCommands(handlers, sessionCommands, authMessage)
    if not KIPN or not KIPN.Server or type(KIPN.Server.RegisterCommandHandler) ~= "function" or not self:State() then
        return false
    end
    sessionCommands = sessionCommands or {}
    for command, handler in pairs(handlers) do
        if not KIPN.Server.GetCommandHandler or not KIPN.Server.GetCommandHandler(command) then
            local guarded = function(player, args)
                if sessionCommands[command] and not Host.HasAuthenticatedSession(player) then
                    self:Result(player, command, false, "AUTHENTICATION_REQUIRED", authMessage or "Log in to KIPN first.")
                    return true
                end
                return handler(player, args)
            end
            if not KIPN.Server.RegisterCommandHandler(command, guarded) then
                self:Log("Error", "Failed to register command " .. tostring(command))
                return false
            end
        end
    end
    return true
end

-- Runs `initialize` when the server data is ready and keeps trying, every 30
-- ticks, until it returns true. For a career not started by a KIPN service.
function Careers.Bootstrap(initialize)
    local done, ticks = false, 0
    local function attempt()
        if not done and initialize() == true then done = true end
        return done
    end
    local function tick()
        if done then
            if Events.OnTick then Events.OnTick.Remove(tick) end
            return
        end
        ticks = ticks + 1
        if ticks % 30 == 0 then attempt() end
    end
    if Events.OnInitGlobalModData then Events.OnInitGlobalModData.Add(attempt) end
    if Events.OnServerStarted then Events.OnServerStarted.Add(attempt) end
    if Events.OnTick then Events.OnTick.Add(tick) end
end

------------------------------------------------------------
-- THREATS
------------------------------------------------------------

-- Opts the career's storefronts in to KIPNCareers.Threats with its own
-- reputation and inbox. `events` is the list Threats.Register takes.
function Career:RegisterThreats(events)
    local Threats = KIPNCareers.Threats
    if type(Threats) ~= "table" or type(Threats.Register) ~= "function" then return false end
    return Threats.Register(self.id, {
        businesses = function() return self:Storefronts() end,
        reputation = function(ownerKey) return self:ReputationFor(ownerKey) end,
        notify = function(ownerKey, title, body) self:Notify(ownerKey, title, body) end,
        events = events,
    })
end

return Careers
