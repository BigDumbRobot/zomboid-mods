#!/usr/bin/env lua
-- Offline checks for the Dynamic Events suite. Loads Dynamic Events' REAL
-- server and client Lua and the suite's own files, with stand-ins for the
-- engine, then drives the suite's real flows tick by tick: every game mode,
-- the Olympics, loadouts, clues, threats, validation and cleanup.
--   cd ~/Zomboid/Workshop/LilBubbyModTester && lua -e "next=nil" tests/dynamicevents_checks.lua
-- Loads the Steam Workshop copy of Dynamic Events when subscribed, else
-- ~/Zomboid/Workshop/DynamicEvents. To test local edits:
--   mkdir -p /tmp/h && ln -sfn ~/Zomboid /tmp/h/Zomboid
--   HOME=/tmp/h lua -e "next=nil" tests/dynamicevents_checks.lua
local WORKSHOP_ID, MOD = "0000000000", "DynamicEvents"
local HOME = os.getenv("HOME") or ""
local function exists(p) local f = io.open(p, "r"); if f then f:close() return true end return false end
local de = HOME .. "/Library/Application Support/Steam/steamapps/workshop/content/108600/" .. WORKSHOP_ID
    .. "/mods/" .. MOD .. "/42/media/lua/"
if not exists(de .. "shared/DynamicEvents_Shared.lua") then
    de = HOME .. "/Zomboid/Workshop/" .. MOD .. "/Contents/mods/" .. MOD .. "/42/media/lua/"
end
if not exists(de .. "shared/DynamicEvents_Shared.lua") then
    print("dynamicevents_checks: SKIPPED (Dynamic Events not found at " .. de .. ")")
    return
end
local tester = "Contents/mods/LilBubbyModTester/42/media/lua/"

------------------------------------------------------------
-- Engine stand-ins
------------------------------------------------------------
local clock = 1000000
function getTimestampMs() return clock end
function isClient() return false end
function isServer() return false end
require = function() end
-- Real dice (seeded), so rolls like the difficulty spread properly.
math.randomseed(42)
function ZombRand(a, b) if b then return b > a and math.random(a, b - 1) or a end return a > 0 and math.random(0, a - 1) or 0 end
function instanceof(o, class) return type(o) == "table" and o.class == class end
function getText(k) return k end
local handlers = {}
Events = setmetatable({}, { __index = function(t, key)
    local e = { Add = function(fn) handlers[key] = handlers[key] or {}; table.insert(handlers[key], fn) end }
    rawset(t, key, e)
    return e
end })
local function fire(key, ...) for _, fn in ipairs(handlers[key] or {}) do fn(...) end end
local quiet = print
print = function(text)
    text = tostring(text)
    if text:find("ERROR") or text:find("STACK") then quiet(text) end
end
function getActivatedMods() return { contains = function() return true end } end
function getMouseX() return -1000 end
function getMouseY() return -1000 end

local function list(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end, items = items }
end

IsoFlagType = { burning = "burning", smoke = "smoke" }
local squares = {}
local function square(x, y, z)
    local key = x .. "," .. y .. "," .. (z or 0)
    if not squares[key] then
        local objects, props = {}, {}
        local sq = { objects = objects, props = props }
        function sq:getX() return x end
        function sq:getY() return y end
        function sq:getZ() return z or 0 end
        function sq:AddWorldInventoryItem(item) table.insert(objects, { getItem = function() return item end,
            removeFromWorld = function() end, removeFromSquare = function(o) for i, v in ipairs(objects) do if v == o then table.remove(objects, i) end end end }) end
        function sq:getWorldObjects() return list(objects) end
        function sq:getObjects() return list({}) end
        function sq:transmitRemoveItemFromSquare() end
        function sq:isOutside() return true end
        local floor = { lit = {} }
        function floor:setHighlighted(index, on) self.lit[index] = on end
        function floor:setHighlightColor() end
        function floor:isHighlighted(index) return self.lit[index] == true end
        function sq:getFloor() return floor end
        function sq:isFree() return true end
        function sq:isSolidTrans() return false end
        function sq:isSolid() return false end
        function sq:Is(flag) return props[flag] == true end
        function sq:stopFire() props.burning = nil end
        function sq:getProperties() return { unset = function(_, flag) props[flag] = nil end } end
        function sq:RecalcProperties() end
        function sq:getBuilding() return nil end
        squares[key] = sq
    end
    return squares[key]
end
local zombies = {}
local lights = {}
local cell = {
    getGridSquare = function(_, x, y, z) return square(math.floor(x), math.floor(y), z) end,
    getZombieList = function() return list(zombies) end,
    addLamppost = function(_, light) lights[light] = true end,
    removeLamppost = function(_, light) lights[light] = nil end,
}
function getCell() return cell end
IsoLightSource = { new = function(x, y, z) return { x = x, y = y, z = z } end }
IsoDirections = { S = "S" }
IsoFireManager = { StartFire = function(_, sq) sq.props.burning = true end }

local container
local function newItem(fullType)
    local mod = {}
    local item = { class = "Item", fullType = fullType }
    function item:getFullType() return fullType end
    function item:getModData() return mod end
    function item:hasModData() for _ in pairs(mod) do return true end return false end
    function item:getInventory() return nil end
    function item:getBodyLocation() return "loc" end
    if fullType:find("Bag_") or fullType:find("FirstAidKit") then
        local inner = container()
        function item:getItemContainer() return inner end
    else
        function item:getItemContainer() return nil end
    end
    return item
end
container = function()
    local items = {}
    return {
        items = items,
        getItems = function() return list(items) end,
        AddItem = function(_, item) if type(item) == "string" then item = newItem(item) end table.insert(items, item) return item end,
        Remove = function(_, item) for i, v in ipairs(items) do if v == item then table.remove(items, i) return end end end,
    }
end
function sendAddItemToContainer() end
function sendRemoveItemFromContainer() end
function getScriptManager() return { FindItem = function(_, fullType) return fullType:find("^Base%.") and {} or nil end } end

local players = {}
local function newPlayer(name)
    local p = { class = "IsoPlayer", name = name, x = 500, y = 500, z = 0, dead = false, inventory = container(), worn = {}, invisible = false }
    function p:getUsername() return self.name end
    function p:getPlayerNum() return 0 end
    function p:getOnlineID() return 1 end
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return self.z end
    function p:setX(v) self.x = v end
    function p:setY(v) self.y = v end
    function p:setZ(v) self.z = v end
    function p:setLx() end
    function p:setLy() end
    function p:setLz() end
    function p:teleportTo(x, y, z) self.x, self.y, self.z = x, y, z end
    function p:getCurrentSquare() return square(math.floor(self.x), math.floor(self.y), self.z) end
    function p:getSquare() return self:getCurrentSquare() end
    function p:isDead() return self.dead end
    function p:getInventory() return self.inventory end
    function p:getVehicle() return nil end
    function p:getPrimaryHandItem() return nil end
    function p:getSecondaryHandItem() return nil end
    function p:setPrimaryHandItem() end
    function p:setSecondaryHandItem() end
    function p:isEquipped(item) for _, w in ipairs(self.worn) do if w == item then return true end end return false end
    function p:removeWornItem(item) for i, w in ipairs(self.worn) do if w == item then table.remove(self.worn, i) end end end
    function p:setWornItem(_, item) table.insert(self.worn, item) end
    function p:setClothingItem_Back() end
    function p:getWornItems() local out = {} for _, w in ipairs(self.worn) do out[#out + 1] = { getItem = function() return w end } end return list(out) end
    function p:removeFromHands() end
    function p:isInvisible() return self.invisible end
    function p:isGodMod() return self.god == true end
    function p:setGodMod(v) self.god = v end
    function p:setInvisible(v) self.invisible = v end
    function p:isOutside() return true end
    function p:getSteamID() return self.name end
    function p:setAvoidDamage() end
    function p:getStats() return { set = function() end } end
    function p:getBodyDamage() return { getBodyPart = function() return nil end } end
    function p:resetModelNextFrame() end
    function p:playSound() end
    players[#players + 1] = p
    return p
end
function getOnlinePlayers() return list(players) end
function getPlayer() return players[1] end
function getSpecificPlayer() return players[1] end
function getNumActivePlayers() return 1 end
function getCore() return { getScreenWidth = function() return 1920 end, getScreenHeight = function() return 1080 end } end

local nextZombieId = 100
function addZombiesInOutfit(x, y, z)
    nextZombieId = nextZombieId + 1
    local zombie = { dead = false, x = x, y = y, z = z or 0, id = nextZombieId, mod = {}, health = 1, outline = {} }
    function zombie:isDead() return self.dead end
    function zombie:getCurrentSquare() if self.removed then return nil end return square(math.floor(self.x), math.floor(self.y), self.z) end
    function zombie:isExistInTheWorld() return not self.removed end
    function zombie:getX() return self.x end
    function zombie:getY() return self.y end
    function zombie:getOnlineID() return self.id end
    function zombie:getModData() return self.mod end
    function zombie:getHealth() return self.health end
    function zombie:setHealth(h) self.health = h if h <= 0 then self.dead = true end end
    function zombie:Kill() self.dead = true end
    function zombie:removeFromWorld() self.removed = true end
    function zombie:removeFromSquare() end
    function zombie:pathToLocationF() end
    function zombie:setUseless(v) self.useless = v end
    function zombie:setTarget(t) self.target = t end
    function zombie:getTarget() return self.target end
    function zombie:getAttackedBy() return nil end
    function zombie:addLineChatElement(text) self.said = text end
    function zombie:setOutlineHighlight(index, on) self.outline[index] = on end
    function zombie:setOutlineHighlightCol() end
    function zombie:isOutlineHighlight(index) return self.outline[index] == true end
    function zombie:unsetOutlineHighlight() self.outline = {} end
    zombies[#zombies + 1] = zombie
    return list({ zombie })
end
function instanceItem(fullType) return newItem(fullType) end
local vehicles = {}
function addVehicleDebug(script)
    local trunk = container()
    local vehicle = { script = script }
    function vehicle:getPartById(id) if id == "TruckBed" then return { getItemContainer = function() return trunk end } end end
    function vehicle:repair() end
    function vehicle:createVehicleKey() return newItem("Base.CarKey") end
    function vehicle:permanentlyRemove() self.removed = true end
    function vehicle:isRemovedFromWorld() return self.removed == true end
    vehicles[#vehicles + 1] = vehicle
    return vehicle
end
local modData = {}
ModData = { getOrCreate = function(key) modData[key] = modData[key] or {}; return modData[key] end }
function getGameTime() return { getTimeOfDay = function() return 12 end, setTimeOfDay = function() end } end
function getClimateManager() return nil end

-- Minimal vanilla UI for the HUD and Showcase.
local Base = {}
Base.__index = Base
function Base:derive() local d = setmetatable({}, { __index = self }); d.__index = d; return d end
function Base.new(self, x, y, w, h)
    return setmetatable({ x = x or 0, y = y or 0, width = w or 0, height = h or 0, children = {},
        backgroundColor = { r = 0, g = 0, b = 0, a = 1 }, borderColor = { r = 1, g = 1, b = 1, a = 1 } }, self)
end
for _, name in ipairs({ "initialise", "instantiate", "addToUIManager", "removeFromUIManager", "bringToTop", "drawText",
    "drawRect", "prerender", "render", "update", "createChildren", "setAlwaysOnTop", "drawTextCentre" }) do
    Base[name] = function() end
end
function Base:addChild(c) self.children[#self.children + 1] = c end
function Base:removeChild(c) for i, v in ipairs(self.children) do if v == c then table.remove(self.children, i) end end end
function Base:setVisible(v) self.visible = v end
function Base:getIsVisible() return self.visible ~= false end
function Base:setX(v) self.x = v end
function Base:setY(v) self.y = v end
function Base:setHeight(v) self.height = v end
function Base:setTitle(v) self.title = v end
function Base:getAbsoluteX() return self.x end
function Base:getAbsoluteY() return self.y end
ISPanel = Base:derive()
ISButton = Base:derive()
function ISButton.new(self, x, y, w, h, title, target, onclick)
    local o = Base.new(self, x, y, w, h); o.title, o.target, o.onclick = title, target, onclick; return o
end
UIFont = { Small = 1, Medium = 2, Large = 3 }
local tm = { MeasureStringX = function(_, _, t) return #tostring(t) * 7 end, getFontHeight = function() return 14 end }
function getTextManager() return tm end

------------------------------------------------------------
-- KIPN stand-ins
------------------------------------------------------------
KIPN = { Server = {}, Shared = {}, Client = {} }
local serverData, commandHandlers, definitions = {}, {}, {}
KIPN.Server.RegisterCommandHandler = function(name, fn) commandHandlers[name] = fn end
KIPN.Server.GetCommandHandler = function(name) return commandHandlers[name] end
KIPN.Server.Save = function() end
KIPN.Server.GetData = function() return serverData end
KIPN.Server.CreateItem = function(fullType) return newItem(fullType) end
-- Server replies reach the client's OnServerCommand, as in the game.
-- The client's commands reach KIPN's router, as in single player.
function sendClientCommand(module, command, args)
    if module == "KIPN" and commandHandlers[command] then commandHandlers[command](players[1], args) end
end
KIPN.Server.SendToPlayer = function(_, event, data)
    fire("OnServerCommand", "KIPN", "serverResponse", { event = event, data = data })
    return true
end
function sendServerCommand() end
KIPN.Server.AdminService = { WriteAudit = function() end, RequirePermission = function() return true end }
local zones = {}
KIPN.Server.WorldRegistry = {
    ZoneTypes = { EVENT = "event" },
    GetZone = function(id) return zones[id] end,
    IsPositionInZone = function(x, y, _, zone) local g = zone.geometry return x >= g.x1 and x <= g.x2 and y >= g.y1 and y <= g.y2 end,
    CreateZoneFromCorners = function(_, a, b)
        local id = "zone" .. (#zones + 1)
        zones[id] = { id = id, type = "event", active = true, geometry = { x1 = math.min(a.x, b.x), y1 = math.min(a.y, b.y),
            x2 = math.max(a.x, b.x), y2 = math.max(a.y, b.y), z1 = 0, z2 = 0 } }
        return zones[id]
    end,
    GetZones = function() return zones end,
    DeactivateZone = function(id) if zones[id] then zones[id].active = false end return true end,
}
KIPN.Server.Permissions = { AuthorizeEventTier = function() return true, "ADMIN" end,
    GetEventTierCategories = function() return { "VIEW", "LIFECYCLE_BASIC", "STAFF_TOOLS", "GM_CONTROLS" } end,
    ResolveAccessLevel = function() return "ADMIN" end }
KIPN.Server.EventObjectiveRegistry = {
    Get = function() return { onTick = function() end } end,
    GetControls = function() return {} end, GetSliders = function() return {} end,
    EvaluateWinConditions = function() return false end, EvaluateFailConditions = function() return false end,
    Initialize = function() end,
}
local escrow = {}
KIPN.Server.EventEscrowService = {
    HasPendingEscrow = function(name) return escrow[name] ~= nil end,
    CreateEscrow = function(p)
        escrow[p.name] = {}
        for i = #p.inventory.items, 1, -1 do table.insert(escrow[p.name], table.remove(p.inventory.items, i)) end
        return true
    end,
    RestoreEscrow = function(p)
        for _, item in ipairs(escrow[p.name] or {}) do table.insert(p.inventory.items, item) end
        escrow[p.name] = nil
        return true
    end,
    Initialize = function() end,
}
local awards = {}
KIPN.Server.EventRewardService = {
    AwardEvent = function(_, rt)
        for name in pairs(rt.winners or {}) do awards[#awards + 1] = { id = "award" .. (#awards + 1), recipientUsername = name, status = "AWAITING_ADMIN_DELIVERY", items = {} } end
        return true
    end,
    Initialize = function()
        KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_LIST_REWARDS, function(p)
            KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_REWARDS_DATA, { awards = awards })
        end)
        KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_MARK_REWARD_DELIVERED, function(p, args)
            for _, a in ipairs(awards) do if a.id == args.awardId then a.status = "ADMIN_DELIVERED" end end
            KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_REWARD_RESULT, { success = true })
        end)
    end,
}
KIPN.Server.ZombieDirector = {
    SpawnThemedZombies = function(rt, _, origin, count)
        rt.spawnedEventZombies = rt.spawnedEventZombies or {}
        for _ = 1, count do rt.spawnedEventZombies[#rt.spawnedEventZombies + 1] = addZombiesInOutfit(origin.x, origin.y, origin.z):get(0) end
        return count
    end,
    TriggerAlarm = function() return false end,
    CleanupRuntime = function() end,
    GetSpawnOrigin = function() return nil end,
    Initialize = function() end,
}
KIPN.Server.EventZombieThemeRegistry = { Initialize = function() end, ResolveOutfit = function() return nil, 50, "RANDOM" end }

dofile(de .. "shared/DynamicEvents_Shared.lua")
KIPN.Shared.Commands.SERVER_RESPONSE = "serverResponse"
KIPN.Shared.Permissions = { SYSOP_CONFIGURATION = "SYSOP_CONFIGURATION" }
KIPN.Shared.AccessLevels = {}
for _, file in ipairs({ "KIPN_EventMoveService", "KIPN_EventModeRegistry", "KIPN_EventHotspotService", "KIPN_EventBanditService", "KIPN_EventTeamService", "KIPN_EventTimerService",
    "KIPN_EventChaseService", "KIPN_EventScenarioRuntimeRegistry", "KIPN_EventTriggerService", "KIPN_EventCaptureService",
    "KIPN_EventKOTHService", "KIPN_EventSurvivorRunService", "KIPN_EventExtractionService", "KIPN_EventGameLoopService",
    "KIPN_EventOlympicsService", "KIPN_EventParticipationService", "KIPN_EventAdventureService", "KIPN_EventThreatService",
    "KIPN_EventLoadoutService", "KIPN_EventScenarioService", "KIPN_EventRuntimeService", "KIPN_EventDirector",
    "KIPN_EventHistoryService", "KIPN_EventControlService", "KIPN_EventSimulationService", "KIPN_EventAccessService" }) do
    dofile(de .. "server/" .. file .. ".lua")
end
for _, name in ipairs({ "EventModeRegistry", "EventHotspotService", "EventTeamService", "EventTimerService", "EventScenarioRuntimeRegistry",
    "EventTriggerService", "EventCaptureService", "EventKOTHService", "EventChaseService", "EventExtractionService",
    "EventSurvivorRunService", "EventAdventureService", "EventScenarioService", "EventParticipationService", "EventRewardService",
    "EventRuntimeService", "EventDirector", "EventOlympicsService", "EventThreatService", "EventLoadoutService",
    "EventBanditService", "EventHistoryService", "EventControlService", "EventSimulationService" }) do
    local service = KIPN.Server[name]
    if service and service.Initialize then service.Initialize() end
end
dofile(de .. "client/KIPN_EventStudio.lua")
dofile(de .. "client/KIPN_EventPlayerHUD.lua")
dofile(de .. "client/KIPN_EventLoadoutClient.lua")
dofile(de .. "client/KIPN_EventSimulationUI.lua")
-- The Studio window itself is covered by Dynamic Events' own smoke test;
-- here a stand-in records that Edit opened it on the right event.
KIPN_EventStudioUI = { OpenAt = function(id, step)
    KIPN_EventStudioUI.instance = { isOpen = true, selectedId = id, step = step, close = function(self) self.isOpen = false end }
end }

-- The tester's own files.
dofile(tester .. "shared/LilBubbyTeleport.lua")
dofile(tester .. "shared/LilBubbySites.lua")
-- The designated event zone an admin laid out, around where the tester stands.
do
    local zone = KIPN.Server.WorldRegistry.CreateZoneFromCorners("event", { x = 460, y = 460 }, { x = 540, y = 540 })
    ModData.getOrCreate("LilBubbySites").sites = { event = { id = zone.id, x1 = 460, y1 = 460, x2 = 540, y2 = 540, z = 0,
        spot = { x = 500, y = 500, z = 0 } } }
end
dofile(tester .. "client/LilBubbyShowcase.lua")
dofile(tester .. "shared/DynamicEventsTest_Checks.lua")
dofile(tester .. "shared/DynamicEventsTest_World.lua")
dofile(tester .. "client/DynamicEventsTest_Client.lua")
local T = DynamicEventsTest

------------------------------------------------------------
-- Driving flows
------------------------------------------------------------
local failed = false
local function check(label, cond, detail)
    if not cond then quiet("FAIL " .. label .. (detail and (": " .. tostring(detail)) or "")); failed = true end
end

-- Runs a flow as the tester would: resumed every tick while the clock moves
-- and the server ticks. Returns its report.
local function run(id, player)
    local co = coroutine.create(T.Flows[id])
    local ok, result = coroutine.resume(co, player)
    local guard = 0
    while ok and coroutine.status(co) ~= "dead" and guard < 20000 do
        -- The game ticks many times a second; four ticks per 250 ms here.
        for _ = 1, 4 do
            clock = clock + 62
            fire("OnTick")
        end
        clock = clock + 2
        ok, result = coroutine.resume(co)
        guard = guard + 1
    end
    if not ok then return nil, result end
    return result
end

local me = newPlayer("tester")

-- Catalog and registration.
local S = LilBubbyShowcase
local suite
for _, mod in ipairs(S.Mods) do if mod.id == "events" then suite = mod end end
check("the suite is in the Showcase", suite ~= nil and suite.requires[2] == "DynamicEvents")
check("its log prefix is registered", S.ModuleSuites[T.MODULE] == "events")
local entries = S.Build(me, "events")
local visits = 0
for _, entry in ipairs(entries) do if entry.name:find("^Visit ") then visits = visits + 1 end end
check("every feature is listed", #entries == #T.Features + visits + 2, #entries)
local venues = 0
for _, id in ipairs(KIPN.Shared.EventClassicScenarioOrder) do
    if KIPN.Shared.EventClassicScenarios[id].venue then venues = venues + 1 end
end
check("every classic location can be visited", visits == venues, visits)
for _, feature in ipairs(T.Features) do check("feature " .. feature.id .. " has a flow", T.Flows[feature.id] ~= nil) end

-- Every flow, one after another, as "Run every test" would.
local order = { "services", "items", "studio_logic", "classics", "validation", "laststanding", "adventure", "difficulty", "fire",
    "lifecycle", "director", "rewards", "survivor", "capture", "ctf", "koth", "chase", "extraction", "prison", "firesale",
    "olympics", "loadouts", "clues", "threats", "hud_fade",
    "move", "bandits", "raid", "heist", "quickstart", "cancel", "announce", "simsteps", "simulate", "simulate_edit", "simulate_cancel",
    "simulate_invite", "access" }
for _, id in ipairs(order) do
    local report, err = run(id, me)
    check(id .. " runs to the end", report ~= nil, err)
    if report then
        check(id .. " passes", report.failed == 0, "\n    " .. table.concat(report.lines, "\n    "))
        check(id .. " checks something", report.passed > 0)
    end
end
check("no test event is left behind", #KIPN.Server.EventScenarioService.ListDefinitions() == 0, #KIPN.Server.EventScenarioService.ListDefinitions())
check("no event is left running", (function() for _ in pairs(KIPN.Server.EventRuntimeService.ActiveRuntimes) do return false end return true end)())
check("the medal table is put back", (function() for _ in pairs(modData[KIPN.Server.EventOlympicsService.MEDAL_DATA_KEY] or {}) do return false end return true end)())
check("your own gear is back", escrow.tester == nil)
check("you are visible again", not me.invisible)
local function empty(t) for _ in pairs(t) do return false end return true end
check("no simulation is left running", empty(KIPN.Server.EventSimulationService.sessions))
check("no start is left counting down", empty(KIPN.Server.EventControlService.pending))
check("test runs are not in Past events", (function()
    for _, record in ipairs(KIPN.Server.EventHistoryService.List()) do
        if tostring(record.name):find(T.PREFIX, 1, true) == 1 then return false end
    end
    return true
end)())
local standing = 0
for _, zombie in ipairs(zombies) do if zombie.useless ~= nil and not zombie.dead and not zombie.removed then standing = standing + 1 end end
check("no bandit is left standing", standing == 0, standing)
local parked = 0
for _, vehicle in ipairs(vehicles) do if not vehicle.removed then parked = parked + 1 end end
check("no getaway car is left behind", parked == 0, parked)
check("every glow and outline is gone", (function()
    for _, zombie in ipairs(zombies) do if zombie.outline[0] then return false end end
    for _ in pairs(lights) do return false end
    return true
end)())

-- The server half refuses what it should.
local sent = {}
function sendServerCommand(_, _, _, reply) sent[#sent + 1] = reply end
LilBubbyPacer = { Run = function(_, _, _, fn) fn() end }
dofile(tester .. "server/DynamicEventsTest_Server.lua")
local serverHandler = handlers.OnClientCommand[#handlers.OnClientCommand]
-- Every player may run every test: a player Dynamic Events refuses is let
-- through its gates only while the server runs a tester op for them.
do
    local Access, Permissions = KIPN.Server.EventAccessService, KIPN.Server.Permissions
    local studio, simulations, tier = Access.RequireStudio, Access.CanJoinSimulations, Permissions.AuthorizeEventTier
    Access.RequireStudio = function() return false end
    Access.CanJoinSimulations = function() return false end
    Permissions.AuthorizeEventTier = function() return false, "USER" end
    check("the stand-in goes up", T.World.Staff() == true)
    check("a player is refused outside a tester op", Access.RequireStudio(me) == false and Access.CanJoinSimulations(me) == false
        and Permissions.AuthorizeEventTier(me, "VIEW") == false)
    local inside
    local ok = T.World.AsStaff(me, function()
        inside = Access.RequireStudio(me) == true and Access.CanJoinSimulations(me) == true
            and Permissions.AuthorizeEventTier(me, "GM_CONTROLS") == true and Access.Level(me) == "ADMIN"
        error("the op failed")
    end)
    check("the server acts as staff for them during a tester op", inside == true)
    check("and stops when the op ends, even if it failed", ok == false and Access.RequireStudio(me) == false
        and Permissions.AuthorizeEventTier(me, "VIEW") == false)
    local other = setmetatable({ getUsername = function() return "someone else" end }, { __index = me })
    T.World.AsStaff(me, function() inside = Access.RequireStudio(other) end)
    check("nobody else is let through meanwhile", inside == false)
    serverHandler(T.MODULE, "setup", me, { kind = "capture", requestId = 1 })
    check("a player the mod refuses can still make a test event", sent[#sent].error == nil and sent[#sent].id ~= nil, sent[#sent].error)
    serverHandler(T.MODULE, "cleanup", me, { requestId = 2 })
    check("and clean it up", sent[#sent].error == nil and (sent[#sent].events or 0) >= 1, sent[#sent].error)
    Access.RequireStudio, Access.CanJoinSimulations, Permissions.AuthorizeEventTier = studio, simulations, tier
end
serverHandler(T.MODULE, "check", me, { name = "difficulty", requestId = 3 })
check("anyone can run read-only checks", sent[#sent].lines ~= nil and sent[#sent].requestId == 3)
KIPN.Server.EventScenarioService.GetDefinition = (function(get) return function(id)
    if id == "real" then return { id = "real", name = "Saturday Night Siege", status = "READY" } end
    if id == "mine" then return { id = "mine", name = T.PREFIX .. "mine", status = "READY" } end
    return get(id)
end end)(KIPN.Server.EventScenarioService.GetDefinition)
serverHandler(T.MODULE, "act", me, { id = "mine", what = "call", command = "EVENT_SET_ZONE", requestId = 4 })
check("only whitelisted commands can be called", sent[#sent].error ~= nil)
serverHandler(T.MODULE, "act", me, { id = "real", what = "call", command = "EVENT_CANCEL", requestId = 7 })
check("the tester never acts on a real event", sent[#sent].error ~= nil)
serverHandler(T.MODULE, "act", me, { id = "mine", what = "move", dx = 500, requestId = 8 })
check("moves are kept short", sent[#sent].error ~= nil)
serverHandler(T.MODULE, "act", me, { id = "mine", what = "give", item = "Base.Sledgehammer", requestId = 5 })
check("only whitelisted items can be given", sent[#sent].error ~= nil)
serverHandler(T.MODULE, "setup", me, { kind = "nuke", requestId = 6 })
check("unknown event kinds are refused", sent[#sent].error ~= nil)

-- The copies of Dynamic Events' own harnesses kept here must match its.
local deTests = HOME .. "/Zomboid/Workshop/DynamicEvents/tests/"
for mine, theirs in pairs({ dynamicevents_studio_checks = "studio_checks", dynamicevents_studio_ui_checks = "studio_ui_smoke",
    dynamicevents_server_loop_checks = "server_loop_checks" }) do
    local a, b = io.open("tests/" .. mine .. ".lua"), io.open(deTests .. theirs .. ".lua")
    check("tests/" .. mine .. ".lua is here", a ~= nil)
    if a and b then
        check("tests/" .. mine .. ".lua matches Dynamic Events' tests/" .. theirs .. ".lua", a:read("a") == b:read("a"))
    end
    if a then a:close() end
    if b then b:close() end
end

if failed then quiet("dynamicevents_checks: FAILED") os.exit(1) end
quiet("dynamicevents_checks: all passed")
