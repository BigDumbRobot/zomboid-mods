-- Plays every game mode through on the real server code, in a small
-- fake world: a clock we move by hand, players we walk around, items,
-- squares and zombies. Checks each mode's loop does what the Studio
-- tells admins it does -- rounds start by themselves, scores count,
-- the right people win, and the event ends.
-- Run from this Workshop project directory: lua tests/server_loop_checks.lua
-- (or from LilBubbyModTester: lua -e "next=nil" tests/dynamicevents_server_loop_checks.lua)
-- Dynamic Events' Lua: this project's own copy when run from the Dynamic
-- Events folder; else ~/Zomboid/Workshop/DynamicEvents (the same file is
-- kept in LilBubbyModTester/tests and run from there).
local root = "Contents/mods/DynamicEvents/42/media/lua/"
do
    local function exists(path) local f = io.open(path, "r") if f then f:close() return true end return false end
    if not exists(root .. "shared/DynamicEvents_Shared.lua") then
        root = (os.getenv("HOME") or "") .. "/Zomboid/Workshop/DynamicEvents/" .. root
    end
    if not exists(root .. "shared/DynamicEvents_Shared.lua") then
        print((arg and arg[0] or "dynamic events check") .. ": SKIPPED (Dynamic Events not found)")
        return
    end
end

------------------------------------------------------------
-- Fake world
------------------------------------------------------------
local clock = 1000000
getTimestampMs = function() return clock end
isClient = function() return false end
isServer = function() return true end
require = function() end
ZombRand = function(a, b) if b then return a end return 0 end
instanceof = function(o, class) return type(o) == "table" and o.class == class end
local ticks = {}
Events = setmetatable({}, { __index = function(t, key)
    local e = { Add = function(fn) ticks[key] = ticks[key] or {}; table.insert(ticks[key], fn) end }
    t[key] = e
    return e
end })

local function list(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end, items = items }
end

local squares = {}
local function square(x, y, z)
    local key = x .. "," .. y .. "," .. (z or 0)
    if not squares[key] then
        local objects = {}
        squares[key] = {
            objects = objects,
            getX = function() return x end, getY = function() return y end, getZ = function() return z or 0 end,
            AddWorldInventoryItem = function(self, item) table.insert(objects, { getItem = function() return item end,
                removeFromWorld = function() end, removeFromSquare = function(o) for i, v in ipairs(objects) do if v == o then table.remove(objects, i) end end end }) end,
            getWorldObjects = function() return list(objects) end,
            isFree = function() return true end,
        }
    end
    return squares[key]
end
getCell = function() return { getGridSquare = function(_, x, y, z) return square(math.floor(x), math.floor(y), z) end } end

local container
local function newItem(fullType)
    local mod = {}
    local item = { class = "Item", fullType = fullType, getFullType = function() return fullType end,
        getModData = function() return mod end, getInventory = function() return nil end }
    if fullType:find("Bag_") or fullType:find("FirstAidKit") then
        local inner = container()
        item.getItemContainer = function() return inner end
        item.inner = inner
    end
    return item
end

container = function()
    local items = {}
    return {
        items = items,
        getItems = function() return list(items) end,
        AddItem = function(self, item) if type(item) == "string" then item = newItem(item) end table.insert(items, item) return item end,
        Remove = function(self, item) for i, v in ipairs(items) do if v == item then table.remove(items, i) return end end end,
    }
end

local players = {}
local function player(name)
    local p = { class = "IsoPlayer", name = name, x = 0, y = 0, z = 0, dead = false, inventory = container() }
    function p:getUsername() return self.name end
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return self.z end
    function p:setX(v) self.x = v end
    function p:setY(v) self.y = v end
    function p:setZ(v) self.z = v end
    function p:setLx() end
    function p:setLy() end
    function p:setLz() end
    function p:isDead() return self.dead end
    function p:getInventory() return self.inventory end
    function p:getSquare() return square(math.floor(self.x), math.floor(self.y), self.z) end
    function p:getVehicle() return nil end
    function p:getPrimaryHandItem() return nil end
    function p:getSecondaryHandItem() return nil end
    function p:isEquipped() return false end
    function p:getSteamID() return name end
    function p:setAvoidDamage() end
    players[#players + 1] = p
    return p
end
getOnlinePlayers = function() return list(players) end
getPlayer = function() return players[1] end

local zombies = {}
addZombiesInOutfit = function(x, y, z)
    local zombie = { dead = false }
    function zombie:isDead() return self.dead end
    function zombie:getCurrentSquare() return square(x, y, z) end
    function zombie:removeFromWorld() self.removed = true end
    function zombie:removeFromSquare() end
    zombies[#zombies + 1] = zombie
    return list({ zombie })
end

local modData = {}
ModData = { getOrCreate = function(key) modData[key] = modData[key] or {}; return modData[key] end }
getGameTime = function() return { getTimeOfDay = function() return 12 end, setTimeOfDay = function() end } end
getWorld = function() return {} end
getClimateManager = function() return nil end

------------------------------------------------------------
-- KIPN stand-ins
------------------------------------------------------------
KIPN = { Server = {}, Shared = {} }
local sentHud = {}
local serverData = {}
local definitions = {}
local commandHandlers = {}
KIPN.Server.RegisterCommandHandler = function(name, fn) commandHandlers[name] = fn end
KIPN.Server.Save = function() end
KIPN.Server.GetData = function() return serverData end
KIPN.Server.CreateItem = function(fullType) return newItem(fullType) end
local moves = {}
KIPN.Server.SendToPlayer = function(p, event, data)
    -- The player's client moves itself (client/KIPN_EventMoveClient.lua);
    -- here it arrives at once, however many hops it took.
    if event == "eventMovePlayer" then
        moves[p.name] = data
        p.x, p.y, p.z = data.x, data.y, data.z
    end
    if event == "eventPlayerHud" then
        sentHud[p.name] = sentHud[p.name] or {}
        table.insert(sentHud[p.name], data)
    end
end
KIPN.Server.AdminService = { WriteAudit = function() end }
KIPN.Server.WorldRegistry = {
    ZoneTypes = { EVENT = "event" },
    GetZone = function(id) return { id = id, type = "event", active = true, geometry = { x1 = 0, y1 = 0, x2 = 200, y2 = 200, z1 = 0, z2 = 0 } } end,
    IsPositionInZone = function(x, y) return x >= 0 and y >= 0 and x <= 200 and y <= 200 end,
}
-- KIPN access level by player name; anyone not listed is an admin.
local levels = {}
KIPN.Server.Permissions = { AuthorizeEventTier = function() return true, "ADMIN" end,
    ResolveAccessLevel = function(p) return levels[p and p.name] or "ADMIN" end }
KIPN.Server.EventObjectiveRegistry = {
    Get = function() return { onTick = function() end } end,
    GetControls = function() return {} end, GetSliders = function() return {} end,
    EvaluateWinConditions = function() return false end, EvaluateFailConditions = function() return false end,
}
local spawns, alarms, fires = {}, 0, {}
KIPN.Server.ZombieDirector = {
    CleanupRuntime = function() end,
    SpawnThemedZombies = function(_, _, origin, count, radius, walkTarget)
        spawns[#spawns + 1] = { x = origin.x, y = origin.y, z = origin.z, count = count, walk = walkTarget }
        return count
    end,
    TriggerAlarm = function() alarms = alarms + 1 return true end,
}
IsoFireManager = { StartFire = function(_, sq) fires[#fires + 1] = sq end }
local rewarded = {}
KIPN.Server.EventRewardService = { AwardEvent = function(_, runtime)
    rewarded = {}
    for name in pairs(runtime.winners or {}) do rewarded[#rewarded + 1] = name end
    table.sort(rewarded)
    return true
end }
local escrowed, restored = {}, {}
KIPN.Server.EventEscrowService = { HasPendingEscrow = function() return false end,
    CreateEscrow = function(p)
        escrowed[p.name] = true
        for i = #p.inventory.items, 1, -1 do table.remove(p.inventory.items, i) end
        return true
    end,
    RestoreEscrow = function(p) restored[p.name] = true return true end }
KIPN.Server.EventScenarioService = {
    Status = { DRAFT = "DRAFT", READY = "READY", ANNOUNCED = "ANNOUNCED", JOINING = "JOINING", ACTIVE = "ACTIVE", ENDING = "ENDING", COMPLETE = "COMPLETE" },
    GetDefinition = function(id) return definitions[id] end,
    SetDefinitionStatus = function(id, status) definitions[id].status = status end,
}
KIPN.Server.EventModeRegistry = { GetModeMetadata = function(mode) return KIPN.Shared.EventModeMetadata[mode] end }

dofile(root .. "shared/DynamicEvents_Shared.lua")
KIPN.Shared.Commands.SERVER_RESPONSE = "serverResponse"
for _, file in ipairs({ "KIPN_EventAccessService", "KIPN_EventMoveService", "KIPN_EventBanditService", "KIPN_EventHotspotService", "KIPN_EventTeamService", "KIPN_EventTimerService",
    "KIPN_EventChaseService", "KIPN_EventScenarioRuntimeRegistry", "KIPN_EventCaptureService", "KIPN_EventKOTHService",
    "KIPN_EventSurvivorRunService", "KIPN_EventExtractionService", "KIPN_EventGameLoopService", "KIPN_EventOlympicsService",
    "KIPN_EventParticipationService", "KIPN_EventAdventureService", "KIPN_EventThreatService", "KIPN_EventLoadoutService",
    "KIPN_EventTriggerService",
    "KIPN_EventRuntimeService", "KIPN_EventHistoryService", "KIPN_EventControlService", "KIPN_EventSimulationService" }) do
    dofile(root .. "server/" .. file .. ".lua")
end
print = (function(original) return function(text)
    text = tostring(text)
    if text:find("ERROR") or text:find("failed") then original(text) end
end end)(print)
KIPN.Server.EventScenarioRuntimeRegistry.Initialize()
KIPN.Server.EventRuntimeService.Initialize()
KIPN.Server.EventOlympicsService.Initialize()
KIPN.Server.EventParticipationService.Initialize()
local participationResults, loadoutSent = {}, {}
local sendOriginal = KIPN.Server.SendToPlayer
KIPN.Server.SendToPlayer = function(p, event, data)
    if event == "eventParticipationResult" then participationResults[p.name] = data end
    if event == "eventApplyLoadout" then loadoutSent[p.name] = data end
    sendOriginal(p, event, data)
end
local Runtime = KIPN.Server.EventRuntimeService

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1 else
        failed = failed + 1
        io.write("FAIL " .. name .. (detail ~= nil and (": " .. tostring(detail)) or "") .. "\n")
    end
end

-- Moves the clock forward, running the server's ticks as it goes.
local function advance(ms, step)
    step = step or 250
    local target = clock + ms
    while clock < target do
        clock = clock + step
        for _, fn in ipairs(ticks.OnTick or {}) do fn() end
    end
end

local function banners(name)
    local out = {}
    for _, hud in ipairs(sentHud[name] or {}) do if hud.banner then out[#out + 1] = hud.banner end end
    return table.concat(out, " | ")
end

local function lastHud(name)
    local all = sentHud[name] or {}
    for i = #all, 1, -1 do if all[i].goal and not all[i].banner then return all[i] end end
end

local function hotspot(id, hotspotType, x, y, round, teamId, metadata)
    return { id = id, type = hotspotType, roundNumber = round, teamId = teamId, active = true, metadata = metadata,
        geometry = { x1 = x - 2, y1 = y - 2, x2 = x + 2, y2 = y + 2, z1 = 0, z2 = 0 } }
end

local function reset()
    players, zombies, sentHud, squares, rewarded = {}, {}, {}, {}, {}
    spawns, alarms, fires, escrowed, restored, loadoutSent = {}, 0, {}, {}, {}, {}
    serverData = {}
    for id in pairs(Runtime.ActiveRuntimes) do Runtime.ActiveRuntimes[id] = nil end
end

local function start(definition, names)
    reset()
    definition.status = "JOINING"
    definition.participants = {}
    definition.eventType = "HORDE_SURVIVAL"
    definition.combatRules = definition.combatRules or { allowLeaveZone = true }
    definition.duration = definition.duration or {}
    definition.roundDuration = definition.roundDuration or {}
    definition.objectiveTypes = definition.objectiveTypes or {}
    definition.scopeType = definition.scopeType or "OPEN_MAP"
    definitions[definition.id] = definition
    local made = {}
    for _, name in ipairs(names) do
        definition.participants[name] = true
        made[name] = player(name)
    end
    local ok, err = Runtime.StartEvent(nil, definition)
    return ok, err, made, Runtime.ActiveRuntimes[definition.id]
end

local function walk(p, x, y) p.x, p.y = x, y end

------------------------------------------------------------
-- Capture the Flag (FFA): the flag spawns, a delivery scores, rounds
-- run by themselves, most captures wins.
------------------------------------------------------------
do
    local def = { id = "capture", name = "Flags", mode = "CAPTURE", variant = "FFA", objectiveTypes = { "RETRIEVE", "DELIVER" },
        maxRounds = 2, timerType = "ROUND_TIMER", roundDuration = { enabled = true, durationSeconds = 300 },
        captureConfig = { flagItemFullType = "Base.Hat_Beret", autoReturnSeconds = 90 },
        hotspots = { hotspot("f1", "CAPTURE_ITEM", 50, 50, 1), hotspot("d1", "DELIVERY_POINT", 90, 50, 1),
            hotspot("f2", "CAPTURE_ITEM", 50, 90, 2), hotspot("d2", "DELIVERY_POINT", 90, 90, 2) } }
    local ok, err, p, runtime = start(def, { "alice", "bob" })
    check("capture starts", ok, err)
    advance(6000, 1000)
    check("capture announces round 1 is coming", banners("alice"):find("Round 1 of 2 starts in", 1, true), banners("alice"))
    check("capture round waits for players", runtime.round.state == "READY")
    advance(20000, 1000)
    check("capture round 1 starts by itself", runtime.round.state == "ACTIVE" and runtime.round.current == 1, runtime.round.state)
    advance(5000, 1000)
    local flag
    for _, entry in pairs(runtime.captureState.items) do flag = entry end
    check("capture flag spawns", flag ~= nil and flag.state == "AT_BASE")
    local hud = lastHud("alice")
    check("capture HUD points at the flag", hud and hud.target and hud.target.label == "Flag", hud and hud.goal)
    -- Alice picks it up and runs it in.
    table.insert(p.alice.inventory.items, flag.liveItemRef)
    advance(5000, 1000)
    check("capture sees the carrier", flag.state == "CARRIED" and flag.carrierUsername == "alice", flag.state)
    advance(5000, 1000)
    hud = lastHud("alice")
    check("carrier HUD points at the delivery point", hud and hud.target and hud.target.label == "Delivery point", hud and hud.goal)
    walk(p.alice, 90, 50)
    advance(5000, 1000)
    check("delivery completes the round", runtime.round.state == "COMPLETE", runtime.round.state)
    check("round winner announced", banners("bob"):find("alice wins round 1", 1, true), banners("bob"))
    advance(25000, 1000)
    check("round 2 starts by itself", runtime.round.current == 2 and runtime.round.state == "ACTIVE", runtime.round.current)
    -- Nobody delivers round 2: the round clock ends it, alice still leads.
    advance(305000, 5000)
    check("capture ends after the last round", Runtime.ActiveRuntimes.capture == nil)
    check("most captures wins", table.concat(rewarded, ",") == "alice", table.concat(rewarded, ","))
    check("final result told to players", banners("bob"):find("Winner: alice", 1, true), banners("bob"))
end

------------------------------------------------------------
-- King of the Hill: exclusive presence scores, contested does not.
------------------------------------------------------------
do
    local def = { id = "koth", name = "Hill", mode = "KING_OF_THE_HILL", objectiveTypes = { "HOLD_AREA" }, maxRounds = 1,
        timerType = "ROUND_TIMER", roundDuration = { enabled = true, durationSeconds = 60 },
        teams = { { id = "team_1", name = "Red Team", members = {} }, { id = "team_2", name = "Blue Team", members = {} } },
        hotspots = { hotspot("h1", "HILL_LOCATION", 100, 100, 1) } }
    local ok, err, p, runtime = start(def, { "alice", "bob", "carol" })
    check("koth starts", ok, err)
    check("players are put on teams", KIPN.Server.EventTeamService.GetPlayerTeam(def, "alice") ~= nil)
    local red = KIPN.Server.EventTeamService.GetPlayerTeam(def, "alice")
    local sameTeam, otherTeam
    for _, name in ipairs({ "bob", "carol" }) do
        if KIPN.Server.EventTeamService.GetPlayerTeam(def, name) == red then sameTeam = name else otherTeam = name end
    end
    advance(26000, 1000)
    check("koth round starts by itself", runtime.round.state == "ACTIVE")
    local hud = lastHud("alice")
    advance(5000, 1000)
    hud = lastHud("alice")
    check("koth HUD points to the hill", hud and hud.target and hud.target.label == "Hill", hud and hud.goal)
    walk(p.alice, 100, 100)
    advance(30000, 1000)
    walk(p[otherTeam], 100, 100)
    advance(10000, 1000)
    check("two teams on the hill is contested", runtime.kothState.currentControllerTeamId == "CONTESTED", runtime.kothState.currentControllerTeamId)
    advance(30000, 1000)
    check("koth ends after the last round", Runtime.ActiveRuntimes.koth == nil)
    local expected = { "alice" }
    if sameTeam then expected[#expected + 1] = sameTeam end
    table.sort(expected)
    check("the team that held the hill wins", table.concat(rewarded, ",") == table.concat(expected, ","), table.concat(rewarded, ","))
end

------------------------------------------------------------
-- Chase: a target is picked each round, everyone gets a turn,
-- hunters are pinged the target's position.
------------------------------------------------------------
do
    local def = { id = "chase", name = "Hunt", mode = "CHASE", objectiveTypes = { "CHASE_TARGET" }, maxRounds = 2,
        timerType = "ROUND_TIMER", roundDuration = { enabled = true, durationSeconds = 60 }, hotspots = {} }
    local ok, err, p, runtime = start(def, { "alice", "bob" })
    check("chase starts", ok, err)
    advance(26000, 1000)
    local first = runtime.objectiveState.chaseTarget
    check("chase picks a target by itself", first ~= nil)
    check("target is told", banners(first):find("You are the target", 1, true), banners(first))
    local hunter = first == "alice" and "bob" or "alice"
    walk(p[first], 30, 40)
    advance(31000, 1000)
    local hud = lastHud(hunter)
    check("hunter sees where the target was (pinged every 30 s)", hud and hud.target and hud.target.x == 30, hud and hud.goal)
    -- Target survives round 1.
    advance(30000, 1000)
    check("surviving target scores", (runtime.chaseState.playerRoundWins[first] or 0) == 1)
    advance(20000, 1000)
    check("the other player is the next target", runtime.objectiveState.chaseTarget == hunter, runtime.objectiveState.chaseTarget)
    -- Round 2 target is caught.
    p[hunter].dead = true
    for _, fn in ipairs(ticks.OnPlayerDeath or {}) do fn(p[hunter]) end
    advance(6000, 1000)
    check("chase ends", Runtime.ActiveRuntimes.chase == nil)
    -- first escaped in round 1 (1 point); caught the other in round 2 (1 more).
    check("catching the target scores for the hunters", table.concat(rewarded, ",") == first, table.concat(rewarded, ","))
end

------------------------------------------------------------
-- Extraction: hold out, the evac arrives, reaching it wins.
------------------------------------------------------------
do
    local def = { id = "evac", name = "Evac", mode = "EXTRACTION", variant = "ABANDONED_SOLDIER", objectiveTypes = { "SURVIVE" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 600, expiryBehavior = "WIN" },
        hotspots = { hotspot("x1", "EXTRACTION_POINT", 150, 150) } }
    serverData = {}
    local ok, err, p, runtime = start(def, { "alice", "bob" })
    serverData.eventReturnPositions = { alice = { x = 5, y = 5, z = 0 } }
    check("extraction starts", ok, err)
    advance(10000, 1000)
    local hud = lastHud("alice")
    check("before the evac: hold out", hud and hud.goal:find("Stay alive", 1, true) and hud.phase == "Evac arrives in", hud and hud.goal)
    walk(p.alice, 150, 150)
    advance(10000, 1000)
    check("the extraction point does nothing before the evac", not runtime.extractionState.extracted.alice)
    advance(440000, 5000)
    check("the evac arrives with 3 minutes left", runtime.extractionState.evacOpen and banners("bob"):find("evac has arrived", 1, true))
    advance(5000, 1000)
    check("reaching the evac extracts", runtime.extractionState.extracted.alice, "")
    check("extracted player is flown out", p.alice.x == 5, p.alice.x)
    advance(200000, 5000)
    check("extraction ends at the deadline", Runtime.ActiveRuntimes.evac == nil)
    check("only the extracted win", table.concat(rewarded, ",") == "alice", table.concat(rewarded, ","))
end

------------------------------------------------------------
-- Survivor Run: everyone down ends it early as a loss.
------------------------------------------------------------
do
    local def = { id = "run", name = "Run", mode = "SURVIVOR_RUN", objectiveTypes = { "SURVIVE" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 600, expiryBehavior = "WIN" }, hotspots = {} }
    local ok, err, p = start(def, { "alice", "bob" })
    check("survivor run starts", ok, err)
    advance(5000, 1000)
    check("survivor HUD counts survivors", lastHud("alice") and lastHud("alice").lines[1] == "2 of 2 survivors still standing")
    for _, name in ipairs({ "alice", "bob" }) do
        p[name].dead = true
        for _, fn in ipairs(ticks.OnPlayerDeath or {}) do fn(p[name]) end
    end
    check("falls are announced", banners("bob"):find("alice has fallen. 1 left standing", 1, true), banners("bob"))
    advance(6000, 1000)
    check("everyone down ends the run", Runtime.ActiveRuntimes.run == nil)
    check("nobody wins", #rewarded == 0)
end


------------------------------------------------------------
-- Prison Break: the exit only opens once you have searched the spot.
------------------------------------------------------------
do
    local def = { id = "prison", name = "Break", mode = "EXTRACTION", variant = "PRISON_BREAK", objectiveTypes = { "RETRIEVE" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 600, expiryBehavior = "WIN" },
        hotspots = { hotspot("key", "CAPTURE_ITEM", 40, 40), hotspot("exit", "EXTRACTION_POINT", 150, 150) } }
    local ok, err, p, runtime = start(def, { "alice", "bob" })
    check("prison break starts", ok, err)
    advance(5000, 1000)
    check("prison break HUD points to the way out", lastHud("alice").target and lastHud("alice").target.label == "Way out")
    walk(p.bob, 150, 150)
    advance(5000, 1000)
    check("the exit is locked until you search", not runtime.extractionState.extracted.bob)
    walk(p.alice, 40, 40)
    advance(5000, 1000)
    check("searching unlocks the exit", runtime.extractionState.unlocked.alice and banners("alice"):find("found the way out", 1, true))
    walk(p.alice, 150, 150)
    advance(5000, 1000)
    check("unlocked prisoner escapes", runtime.extractionState.extracted.alice)
    p.bob.dead = true
    for _, fn in ipairs(ticks.OnPlayerDeath or {}) do fn(p.bob) end
    advance(6000, 1000)
    check("everyone out or down ends it", Runtime.ActiveRuntimes.prison == nil)
    check("the escaped prisoner wins", table.concat(rewarded, ",") == "alice", table.concat(rewarded, ","))
end

------------------------------------------------------------
-- Team Capture the Flag: steal the enemy flag, bring it home.
------------------------------------------------------------
do
    local def = { id = "ctf", name = "CTF", mode = "CAPTURE", variant = "TEAM_CTF", objectiveTypes = { "RETRIEVE", "DELIVER" },
        maxRounds = 1, timerType = "ROUND_TIMER", roundDuration = { enabled = true, durationSeconds = 300 },
        captureConfig = { flagItemFullType = "Base.Hat_Beret" },
        teams = { { id = "team_1", name = "Red Team", members = {} }, { id = "team_2", name = "Blue Team", members = {} } },
        hotspots = { hotspot("b1", "TEAM_BASE", 20, 20, 1, "team_1"), hotspot("b2", "TEAM_BASE", 180, 180, 1, "team_2"),
            hotspot("c", "CAPTURE_ITEM", 100, 30, 1), hotspot("dp", "DELIVERY_POINT", 100, 170, 1) } }
    local ok, err, p, runtime = start(def, { "alice", "bob" })
    check("team ctf starts", ok, err)
    local aliceTeam = KIPN.Server.EventTeamService.GetPlayerTeam(def, "alice")
    advance(26000, 1000)
    advance(5000, 1000)
    local enemyFlag
    for _, entry in pairs(runtime.captureState.items) do if entry.teamId ~= aliceTeam then enemyFlag = entry end end
    check("each team has a flag", enemyFlag ~= nil)
    check("HUD points at the enemy flag", lastHud("alice").target and lastHud("alice").target.label == "Enemy flag", lastHud("alice").goal)
    table.insert(p.alice.inventory.items, enemyFlag.liveItemRef)
    advance(5000, 1000)
    local home = aliceTeam == "team_1" and { 20, 20 } or { 180, 180 }
    walk(p.alice, home[1], home[2])
    advance(11000, 1000)
    check("bringing the enemy flag home wins", Runtime.ActiveRuntimes.ctf == nil and table.concat(rewarded, ",") == "alice", table.concat(rewarded, ","))
    check("the team is named in the result", banners("bob"):find(aliceTeam == "team_1" and "Red Team wins" or "Blue Team wins", 1, true), banners("bob"))
end

------------------------------------------------------------
-- The Olympics.
------------------------------------------------------------
do
    local station = function(id, x, number, task, extra)
        local meta = { task = task }
        for k, v in pairs(extra or {}) do meta[k] = v end
        return hotspot(id, "OLYMPIC_STATION", x, 10, number, nil, meta)
    end
    local def = { id = "games", name = "Knox Games", mode = "OLYMPICS", objectiveTypes = { "LOCATE" },
        olympicsConfig = { heatSize = 2, heatLimitSeconds = 600 },
        hotspots = {
            hotspot("start", "OLYMPIC_START", 10, 10),
            station("s1", 30, 1, "CHECKPOINT"),
            station("s2", 50, 2, "CHOP", { itemType = "Base.Log", count = 2, kit = { "Base.Axe" } }),
            station("s3", 70, 3, "CARRY", { itemType = "Base.Generator", count = 1 }),
            hotspot("drop", "OLYMPIC_DROP", 70, 30, 3),
            station("s4", 90, 4, "SHOOT", { count = 2, kit = { "Base.Pistol" } }),
            hotspot("range", "OLYMPIC_TARGETS", 90, 40, 4),
            hotspot("finish", "OLYMPIC_FINISH", 110, 10),
        } }
    -- Sign-ups while joining is open.
    reset()
    definitions.games = def
    def.status, def.participants, def.eventType = "JOINING", {}, "HORDE_SURVIVAL"
    def.combatRules, def.duration, def.roundDuration, def.scopeType = { allowLeaveZone = true }, {}, {}, "OPEN_MAP"
    local p = { ann = player("ann"), ben = player("ben"), cal = player("cal") }
    local accept = commandHandlers[KIPN.Shared.Commands.EVENT_ACCEPT_PARTICIPATION]
    accept(p.ann, { id = "games" })
    check("a town is required", participationResults.ann and participationResults.ann.reason == "COUNTRY_REQUIRED")
    accept(p.ann, { id = "games", country = "Muldraugh" })
    accept(p.ben, { id = "games", country = "Riverside" })
    accept(p.cal, { id = "games", country = "Rosewood" })
    check("signing up puts you on the roster", def.participants.ann and participationResults.ann.reason == "SIGNED_UP")
    local ok, err = Runtime.StartEvent(nil, def)
    local runtime = Runtime.ActiveRuntimes.games
    check("games start", ok, err)
    check("athletes gather at the start line", p.ann.x == 10 and p.cal.x == 10, p.ann.x)
    check("athletes race for their town", runtime.olympicsState.racers.ann.country == "Muldraugh")

    advance(1000)
    check("heat 1 is called", banners("cal"):find("Heat 1: ann (Muldraugh) vs ben (Riverside)", 1, true), banners("cal"))
    advance(4000)
    walk(p.ben, 60, 60)
    advance(1000)
    check("stepping off the line is a false start", p.ben.x == 10 and banners("ben"):find("False start", 1, true))
    advance(9000)
    check("3-2-1-GO", banners("ann"):find("3...", 1, true) and banners("ann"):find("GO!", 1, true), banners("ann"))
    check("the race is on", runtime.olympicsState.heat.phase == "RUNNING")
    local heatStart = runtime.olympicsState.heat.startedAtMs

    walk(p.ann, 30, 10); advance(500)
    check("checkpoint cleared", runtime.olympicsState.heat.progress.ann.index == 2)
    walk(p.ann, 50, 10); advance(500)
    local hasAxe = false
    for _, item in ipairs(p.ann.inventory.items) do if item.fullType == "Base.Axe" then hasAxe = true end end
    check("the chop station hands out an axe", hasAxe)
    table.insert(p.ann.inventory.items, newItem("Base.Log")); advance(500)
    check("one log is not enough", runtime.olympicsState.heat.progress.ann.index == 2)
    table.insert(p.ann.inventory.items, newItem("Base.Log")); advance(500)
    check("two logs clear the chop station", runtime.olympicsState.heat.progress.ann.index == 3)
    local logsLeft = 0
    for _, item in ipairs(p.ann.inventory.items) do if item.fullType == "Base.Log" then logsLeft = logsLeft + 1 end end
    check("the station takes the logs", logsLeft == 0, logsLeft)
    walk(p.ann, 70, 10); advance(500)
    local load = runtime.olympicsState.heat.progress.ann.load
    check("the heavy load appears", load ~= nil)
    walk(p.ann, 70, 30); advance(500)
    check("the drop zone needs the load", runtime.olympicsState.heat.progress.ann.index == 3)
    table.insert(p.ann.inventory.items, load.item); advance(500)
    check("carrying the load to the drop zone clears it", runtime.olympicsState.heat.progress.ann.index == 4)
    walk(p.ann, 90, 10); advance(500)
    local targets = runtime.olympicsState.heat.progress.ann.targets
    check("targets appear", targets and #targets == 2)
    targets[1].dead = true; advance(500)
    check("every target must go down", runtime.olympicsState.heat.progress.ann.index == 4)
    targets[2].dead = true; advance(500)
    check("shooting cleared", runtime.olympicsState.heat.progress.ann.index == 5)
    local hud = KIPN.Server.EventGameLoopService.BuildHud(runtime, def, "ann", false)
    check("HUD points to the finish", hud.target and hud.target.label == "Finish" and hud.stopwatchMs ~= nil, hud.goal)
    advance(20000)
    walk(p.ann, 110, 10); advance(250)
    check("ann finishes", runtime.olympicsState.racers.ann.status == "FINISHED")
    local annTime = runtime.olympicsState.racers.ann.timeMs
    check("time is measured precisely", math.abs(annTime - (clock - heatStart)) <= 250, annTime)
    check("finish time is announced", banners("cal"):find("ann (Muldraugh) finishes in", 1, true), banners("cal"))
    hasAxe = false
    for _, item in ipairs(p.ann.inventory.items) do if item.fullType == "Base.Axe" or item.fullType == "Base.Pistol" then hasAxe = true end end
    check("kit is taken back", not hasAxe)

    p.ben.dead = true
    for _, fn in ipairs(ticks.OnPlayerDeath or {}) do fn(p.ben) end
    advance(500)
    check("dying is a DNF", runtime.olympicsState.racers.ben.status == "DNF")
    advance(9000)
    check("heat 2 is called", runtime.olympicsState.heat and runtime.olympicsState.heat.number == 2)
    advance(15000)
    local stations = { { 30, 10 }, { 50, 10 } }
    for _, pos in ipairs(stations) do walk(p.cal, pos[1], pos[2]); advance(500) end
    table.insert(p.cal.inventory.items, newItem("Base.Log")); table.insert(p.cal.inventory.items, newItem("Base.Log")); advance(500)
    walk(p.cal, 70, 10); advance(500)
    table.insert(p.cal.inventory.items, runtime.olympicsState.heat.progress.cal.load.item)
    walk(p.cal, 70, 30); advance(500)
    walk(p.cal, 90, 10); advance(500)
    for _, z in ipairs(runtime.olympicsState.heat.progress.cal.targets) do z.dead = true end
    advance(60000)
    walk(p.cal, 110, 10); advance(250)
    check("cal finishes", runtime.olympicsState.racers.cal.status == "FINISHED")
    advance(15000, 1000)
    check("the games end when everyone has raced", Runtime.ActiveRuntimes.games == nil)
    check("the podium wins", table.concat(rewarded, ",") == "ann,cal", table.concat(rewarded, ","))
    check("medals are announced", banners("cal"):find("GOLD ann (Muldraugh)", 1, true) and banners("cal"):find("SILVER cal (Rosewood)", 1, true), banners("cal"))
    local medals = KIPN.Server.EventOlympicsService.MedalTable()
    check("the medal table counts towns", medals[1].country == "Muldraugh" and medals[1].gold == 1, medals[1] and medals[1].country)
end

------------------------------------------------------------
-- Classic scenarios: loadouts, difficulty, threats, ambushes.
------------------------------------------------------------
local function has(p, fullType)
    for _, item in ipairs(p.inventory.items) do if item.fullType == fullType then return item end end
end

do
    -- Prison Break as Pillow wrote it: prisoner loadout, Brutal roll (the
    -- test's dice always come up), an alarm, and an ambush in the dining hall.
    local def = { id = "prison2", name = "Prison", mode = "EXTRACTION", variant = "PRISON_BREAK", objectiveTypes = { "RETRIEVE" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 900, expiryBehavior = "WIN" },
        loadout = "PRISONER", difficulty = "RANDOM", threats = { ALARM = true, SIEGE = true, FIRES = true },
        hotspots = { hotspot("cell", "PLAYER_SPAWN", 10, 10), hotspot("desk", "CAPTURE_ITEM", 40, 40), hotspot("lot", "EXTRACTION_POINT", 150, 150),
            hotspot("dining", "ZOMBIE_AMBUSH", 90, 90, nil, nil, { count = 12 }) } }
    local ok, err, p, runtime = start(def, { "alice", "bob" })
    check("classic prison starts", ok, err)
    check("own gear goes to escrow", escrowed.alice and escrowed.bob)
    check("prisoner wears the jumpsuit", has(p.alice, "Base.Boilersuit_Prisoner") and has(p.alice, "Base.Shoes_Slippers"))
    local sent = loadoutSent.alice
    check("the player's game is told what to wear", sent and sent.loadout == "PRISONER" and #sent.wear == 4, sent and sent.loadout)
    check("one breakout tool in hand", sent.hands and has(p.alice, sent.hands), sent.hands)
    check("the difficulty is rolled", runtime.difficulty == "BRUTAL", runtime.difficulty)
    check("brutal triples the director", runtime.directorState.maxZombies == 300)
    advance(6000, 1000)
    check("the roll is announced with a sting", banners("alice"):find("Difficulty: BRUTAL", 1, true))
    local stung = false
    for _, hud in ipairs(sentHud.alice) do if hud.bannerSound == "PlayerDied" then stung = true end end
    check("brutal plays the death sound", stung)
    advance(25000, 1000)
    check("the alarm goes off early on brutal", alarms == 1 and banners("alice"):find("alarm is going off", 1, true))
    advance(10000, 1000)
    local sides = 0
    for _, sp in ipairs(spawns) do if sp.walk then sides = sides + 1 end end
    check("a siege comes from four sides", sides == 4 and spawns[1].count == 30, sides)
    check("hordes walk in on the players", spawns[1].walk and spawns[1].walk.x ~= nil)
    advance(30000, 1000)
    check("fires break out", #fires >= 1, #fires)
    local before = #spawns
    walk(p.bob, 88, 88)
    advance(5000, 1000)
    check("walking into the dining hall wakes the ambush", #spawns == before + 1 and spawns[#spawns].count == 36 and spawns[#spawns].x == 90)
    advance(5000, 1000)
    check("an ambush only wakes once", #spawns == before + 1)
    Runtime.StopEvent(nil, "prison2", "TEST", "MANUAL")
    check("loadout items are taken back", not has(p.alice, "Base.Boilersuit_Prisoner"))
    check("own gear is returned", restored.alice and restored.bob)
end

do
    -- The Last Flight: the pack and first-aid kit are thrown clear, filled.
    local def = { id = "flight", name = "Flight", mode = "EXTRACTION", variant = "LAST_FLIGHT", objectiveTypes = { "SURVIVE" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 600, expiryBehavior = "WIN" }, loadout = "PILOT",
        difficulty = "NORMAL", hotspots = { hotspot("x", "EXTRACTION_POINT", 150, 150) } }
    local ok, err, p = start(def, { "alice" })
    check("last flight starts", ok, err)
    local kit
    for _, sq in pairs(squares) do
        for _, object in ipairs(sq.objects) do
            if object.getItem().fullType == "Base.FirstAidKit" then kit = object.getItem() end
        end
    end
    check("the first-aid kit lands nearby, stocked", kit and #kit.inner.items >= 5)
    check("the pilot's injuries go to the player's game", loadoutSent.alice.injuries and loadoutSent.alice.injuries.wounds == 3)
    Runtime.StopEvent(nil, "flight", "TEST", "MANUAL")
end

do
    -- Mall rat keeps their own gear (Fire Sale): no escrow, crowbar added.
    local def = { id = "sale", name = "Sale", mode = "EXTRACTION", variant = "FIRE_SALE", objectiveTypes = { "SURVIVE" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 900, expiryBehavior = "WIN" }, loadout = "MALL_RAT",
        difficulty = "NORMAL", hotspots = { hotspot("e1", "EXTRACTION_POINT", 20, 20), hotspot("e2", "EXTRACTION_POINT", 180, 20),
            hotspot("e3", "EXTRACTION_POINT", 20, 180) } }
    local ok, err, p, runtime = start(def, { "alice", "bob" })
    check("fire sale starts", ok, err)
    check("mall rats keep their gear", not escrowed.alice and has(p.alice, "Base.Crowbar"))
    check("the way out is open from the start", runtime.extractionState.evacOpen)
    local swarmed = 0
    for _, sp in ipairs(spawns) do if not sp.walk then swarmed = swarmed + 1 end end
    check("every exit but one is swarmed", swarmed == 2, swarmed)
    local safe = KIPN.Server.EventHotspotService.FindById(def, runtime.extractionState.safeExitId)
    local c = KIPN.Server.EventHotspotService.GetCenter(safe)
    advance(5000, 1000)
    check("players are told one exit is clear", banners("alice"):find("One way out is clear", 1, true))
    check("the HUD says get out", lastHud("alice").goal:find("Get out of the mall", 1, true), lastHud("alice").goal)
    walk(p.alice, c.x, c.y)
    advance(5000, 1000)
    check("reaching an exit escapes", runtime.extractionState.extracted.alice)
    Runtime.StopEvent(nil, "sale", "TEST", "MANUAL")
end

do
    -- Dodgeball of the Dead: last one standing wins.
    local def = { id = "dodge", name = "Dodge", mode = "SURVIVOR_RUN", objectiveTypes = { "SURVIVE" }, loadout = "NAKED",
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 900, expiryBehavior = "WIN" },
        survivorConfig = { lastStanding = true }, hotspots = {} }
    local ok, err, p = start(def, { "alice", "bob", "cal" })
    check("dodgeball starts", ok, err)
    check("naked players get one silly item", #p.alice.inventory.items == 1)
    for _, name in ipairs({ "alice", "cal" }) do
        p[name].dead = true
        for _, fn in ipairs(ticks.OnPlayerDeath or {}) do fn(p[name]) end
    end
    advance(6000, 1000)
    check("the last one standing wins at once", Runtime.ActiveRuntimes.dodge == nil and table.concat(rewarded, ",") == "bob", table.concat(rewarded, ","))
end

------------------------------------------------------------
-- Clues: narrative hotspots and hints can be replayed from the HUD.
------------------------------------------------------------
do
    local def = { id = "story", name = "Story", mode = "SURVIVOR_RUN", objectiveTypes = { "SURVIVE" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 900, expiryBehavior = "WIN" },
        hotspots = {
            hotspot("spawn", "PLAYER_SPAWN", 10, 10),
            hotspot("diary", "NARRATIVE_LOCATION", 40, 40, nil, nil, { narrativeText = "The code is 4-7-1. Don't forget it.", narrativeScope = "LOCAL", clueTitle = "Diary page" }),
            hotspot("siren", "NARRATIVE_LOCATION", 80, 80, nil, nil, { narrativeText = "A siren wails to the north.", narrativeScope = "GLOBAL" }),
            hotspot("flavour", "NARRATIVE_LOCATION", 120, 120, nil, nil, { narrativeText = "It smells of smoke.", narrativeScope = "LOCAL", replayable = false }),
        } }
    local ok, err, p, runtime = start(def, { "alice", "bob" })
    check("story event starts", ok, err)
    walk(p.alice, 40, 40)
    advance(5000, 1000)
    local shown
    for _, hud in ipairs(sentHud.alice) do if hud.banner and hud.banner:find("4-7-1", 1, true) then shown = hud end end
    check("reaching a clue shows it in full", shown and shown.bannerLong and shown.bannerTitle == "Diary page")
    check("the clue becomes a button", shown and shown.clues and #shown.clues == 1 and shown.clues[1].title == "Diary page")
    check("only the finder gets a private clue", not (runtime.clues.bob and #runtime.clues.bob > 0))
    advance(5000, 1000)
    check("the clue rides along in every HUD update", lastHud("alice").clues and lastHud("alice").clues[1].text:find("4-7-1", 1, true))
    walk(p.alice, 10, 10); advance(5000, 1000); walk(p.alice, 40, 40); advance(5000, 1000)
    check("revisiting does not duplicate it", #runtime.clues.alice == 1)
    walk(p.bob, 80, 80)
    advance(5000, 1000)
    check("a global clue goes to everyone", #runtime.clues.alice == 2 and #runtime.clues.bob == 1 and runtime.clues.bob[1].title == "Clue 1")
    walk(p.bob, 120, 120)
    advance(5000, 1000)
    check("non-replayable text shows but leaves no button", banners("bob"):find("smells of smoke", 1, true) and #runtime.clues.bob == 1)
    Runtime.StopEvent(nil, "story", "TEST", "MANUAL")
end

do
    -- A story trigger's private hint is a clue too.
    local def = { id = "hint", name = "Hint", mode = "SURVIVOR_RUN", objectiveTypes = { "SURVIVE" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 900, expiryBehavior = "WIN" },
        hotspots = { hotspot("spawn", "PLAYER_SPAWN", 10, 10), hotspot("gate", "OBJECTIVE_LOCATION", 60, 60) } }
    def.objectives = KIPN.Server.EventTriggerService.SanitizeObjectives({
        { id = "o1", name = "Find the gate", triggers = { { activationMode = "PROXIMITY", hotspotId = "gate",
            actions = { { type = "PRIVATE_HINT", params = { text = "The key is under the mat." } } } } } } })
    local ok, err, p, runtime = start(def, { "alice" })
    check("hint event starts", ok, err)
    walk(p.alice, 60, 60)
    advance(10000, 1000)
    check("a private hint becomes a replayable clue", runtime.clues and runtime.clues.alice and runtime.clues.alice[1]
        and runtime.clues.alice[1].title == "Hint" and runtime.clues.alice[1].text:find("under the mat", 1, true),
        runtime.clues and runtime.clues.alice and #runtime.clues.alice)
    Runtime.StopEvent(nil, "hint", "TEST", "MANUAL")

    local normalized = KIPN.Server.EventHotspotService.NormalizeHotspot({ type = "NARRATIVE_LOCATION",
        geometry = { x1 = 0, y1 = 0, x2 = 4, y2 = 4, z1 = 0, z2 = 0 },
        metadata = { narrativeText = "Look up.", clueTitle = "  Graffiti  " } }, "def")
    check("narrative hotspots are clues by default", normalized and normalized.metadata.replayable == true and normalized.metadata.clueTitle == "Graffiti")
    normalized = KIPN.Server.EventHotspotService.NormalizeHotspot({ type = "NARRATIVE_LOCATION",
        geometry = { x1 = 0, y1 = 0, x2 = 4, y2 = 4, z1 = 0, z2 = 0 },
        metadata = { narrativeText = "Flavour.", replayable = false } }, "def")
    check("clues can be turned off", normalized and normalized.metadata.replayable == false)
end

------------------------------------------------------------
-- Bandits, the Heist, past events, the prepared-event actions
-- (Start, Announcements, Cancel) and Simulate.
------------------------------------------------------------
local Bandits = KIPN.Server.EventBanditService
local Control = KIPN.Server.EventControlService
local Sim = KIPN.Server.EventSimulationService
local History = KIPN.Server.EventHistoryService

-- Bodies that behave enough like zombies for the bandit code.
local nextZombieId = 100
local function body(x, y, z)
    nextZombieId = nextZombieId + 1
    local zombie = { class = "IsoZombie", id = nextZombieId, dead = false, x = x, y = y, z = z or 0, mod = {}, health = 1, useless = false }
    function zombie:isDead() return self.dead end
    function zombie:getCurrentSquare() if self.removed then return nil end return square(math.floor(self.x), math.floor(self.y), self.z) end
    function zombie:removeFromWorld() self.removed = true end
    function zombie:removeFromSquare() end
    function zombie:getModData() return self.mod end
    function zombie:setUseless(v) self.useless = v end
    function zombie:getHealth() return self.health end
    function zombie:setHealth(v) self.health = v end
    function zombie:pathToLocationF(px, py) self.walkTo = { px, py } end
    function zombie:setTarget(t) self.target = t end
    function zombie:getTarget() return self.target end
    function zombie:getAttackedBy() return self.attacker end
    function zombie:getOnlineID() return self.id end
    zombies[#zombies + 1] = zombie
    return zombie
end
addZombiesInOutfit = function(x, y, z) return list({ body(x, y, z) }) end
instanceItem = function(fullType) return newItem(fullType) end
IsoDirections = { S = "S" }
local vehicles = {}
addVehicleDebug = function(script)
    local trunk = container()
    local vehicle = { script = script, trunk = trunk }
    function vehicle:getPartById(id) if id == "TruckBed" then return { getItemContainer = function() return trunk end } end end
    function vehicle:repair() end
    function vehicle:createVehicleKey() return newItem("Base.CarKey") end
    function vehicle:permanentlyRemove() self.removed = true end
    vehicles[#vehicles + 1] = vehicle
    return vehicle
end

local actionResults, simPayloads = {}, {}
local sendBefore = KIPN.Server.SendToPlayer
KIPN.Server.SendToPlayer = function(p, event, data)
    if event == "eventActionResult" then actionResults[p.name] = data end
    if event == "eventSimulation" then
        simPayloads[p.name] = simPayloads[p.name] or {}
        table.insert(simPayloads[p.name], data)
    end
    sendBefore(p, event, data)
end
KIPN.Server.GetCommandHandler = function(name) return commandHandlers[name] end
KIPN.Server.AdminService.RequirePermission = function() return true end
KIPN.Shared.Permissions = { SYSOP_CONFIGURATION = "SYSOP_CONFIGURATION" }
History.Initialize()
Bandits.Initialize()
Control.Initialize()
Sim.Initialize()

local function crews(runtime) return (runtime.banditState or {}).crews or {} end
local function living(crew)
    local out = {}
    for _, member in ipairs(crew.members) do if not member.state then out[#out + 1] = member end end
    return out
end
local function groundItems(x, y)
    local sq = squares[x .. "," .. y .. ",0"]
    return sq and #sq.objects or 0
end

do
    -- Raiding crews: arrive after a while, hunt a player, drop their loot.
    local def = { id = "raid", name = "Raid", mode = "SURVIVOR_RUN", objectiveTypes = { "SURVIVE" }, threats = { BANDITS = true },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 1800, expiryBehavior = "WIN" },
        hotspots = { hotspot("spawn", "PLAYER_SPAWN", 50, 50) } }
    local ok, err, p, runtime = start(def, { "alice" })
    check("bandit raid event starts", ok, err)
    advance(Bandits.FIRST_RAID_MS - 5000, 1000)
    check("no raid straight away", #crews(runtime) == 0)
    advance(8000, 1000)
    local crew = crews(runtime)[1]
    check("a raiding crew arrives", crew ~= nil and #crew.members >= 2, crew and #crew.members)
    check("raiders are hostile and head for a player", crew and not crew.calm and crew.members[1].zombie.walkTo ~= nil
        and crew.members[1].zombie.useless == false)
    check("everyone is warned", banners("alice"):find("Bandits!", 1, true), banners("alice"))
    check("the leader carries supplies", crew and #crew.leader.carrying >= 1)
    local leader = crew.leader.zombie
    leader.dead = true
    advance(2000, 1000)
    check("the leader's loot drops where they fell", groundItems(math.floor(leader.x), math.floor(leader.y)) >= 1)
    for _, member in ipairs(crew.members) do member.zombie.dead = true end
    advance(2000, 1000)
    check("a wiped-out crew is announced", banners("alice"):find("wiped out", 1, true), banners("alice"))
    local remaining = 0
    for _, zombie in ipairs(zombies) do if not zombie.dead and not zombie.removed then remaining = remaining + 1 end end
    Runtime.StopEvent(nil, "raid", "TEST", "MANUAL")
    local left = 0
    for _, zombie in ipairs(zombies) do if not zombie.dead and not zombie.removed then left = left + 1 end end
    check("bandits still standing are removed at the end", left == 0, left .. " of " .. remaining)
end

do
    -- A bandit camp stays calm until someone comes close.
    local def = { id = "camp", name = "Camp", mode = "SURVIVOR_RUN", objectiveTypes = { "SURVIVE" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 1800, expiryBehavior = "WIN" },
        hotspots = { hotspot("spawn", "PLAYER_SPAWN", 10, 10), hotspot("camp", "BANDIT_CAMP", 100, 100, nil, nil, { count = 3 }) } }
    local ok, err, p, runtime = start(def, { "alice" })
    check("bandit camp event starts", ok, err)
    walk(p.alice, 10, 10)
    advance(3000, 1000)
    local crew = crews(runtime)[1]
    check("the camp's crew is placed", crew ~= nil and #crew.members == 3, crew and #crew.members)
    check("the crew waits calmly", crew and crew.calm and crew.members[1].zombie.useless == true)
    walk(p.alice, 96, 100)
    advance(2000, 1000)
    check("coming close provokes them", crew and not crew.calm and crew.members[1].zombie.useless == false
        and crew.members[1].zombie.target == p.alice)
    check("the player is told", banners("alice"):find("spotted you", 1, true), banners("alice"))
    Runtime.StopEvent(nil, "camp", "TEST", "MANUAL")

    -- Shooting one provokes the whole crew even from afar.
    ok, err, p, runtime = start(def, { "alice" })
    walk(p.alice, 10, 10)
    advance(3000, 1000)
    crew = crews(runtime)[1]
    crew.members[2].zombie.attacker = p.alice
    advance(2000, 1000)
    check("an attack provokes the crew", crew and not crew.calm and crew.members[1].zombie.useless == false)
    Runtime.StopEvent(nil, "camp", "TEST", "MANUAL")

    -- A story step can send a crew.
    ok, err, p, runtime = start(def, { "alice" })
    local arrived = Bandits.Arrive(runtime, def, { x = 60, y = 60, z = 0 }, 3)
    check("a story crew arrives near its spot and heads there", arrived ~= nil and #arrived.members == 3
        and arrived.members[1].zombie.walkTo and arrived.members[1].zombie.walkTo[1] == 60.5)
    Runtime.StopEvent(nil, "camp", "TEST", "MANUAL")
end

do
    -- The Heist: gold in the getaway car; only gold gets you out.
    local def = { id = "heist", name = "Heist", mode = "EXTRACTION", variant = "HEIST", objectiveTypes = { "RETRIEVE" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 600, expiryBehavior = "WIN" },
        hotspots = { hotspot("spawn", "PLAYER_SPAWN", 10, 10), hotspot("car", "BANDIT_VEHICLE", 100, 100, nil, nil, { count = 2 }),
            hotspot("exit", "EXTRACTION_POINT", 150, 150) } }
    vehicles = {}
    local ok, err, p, runtime = start(def, { "alice" })
    check("heist starts", ok, err)
    walk(p.alice, 10, 10)
    advance(6000, 1000)
    local car = vehicles[1]
    local gold = 0
    for _, item in ipairs(car and car.trunk.items or {}) do if item:getModData().DE_HeistGold then gold = gold + 1 end end
    check("the getaway car is parked with the gold in its trunk", car ~= nil and gold == KIPN.Shared.EventHeist.count, gold)
    local crew = crews(runtime)[1]
    local hasKey = false
    for _, item in ipairs(crew and crew.leader.carrying or {}) do if item.fullType == "Base.CarKey" then hasKey = true end end
    check("the crew guards it calmly, the leader has the key", crew and crew.calm and hasKey)
    check("players are told to find the car", (lastHud("alice") or {}).goal and lastHud("alice").goal:find("getaway car", 1, true))
    check("no hint where it is at first", lastHud("alice") and lastHud("alice").target == nil)
    advance(301000, 1000)
    check("halfway, a witness points the way", lastHud("alice") and lastHud("alice").target
        and lastHud("alice").target.label:find("Witness", 1, true), lastHud("alice") and lastHud("alice").target and lastHud("alice").target.label)
    walk(p.alice, 150, 150)
    advance(6000, 1000)
    check("without gold the pickup won't take you", runtime.extractionState.extracted.alice == nil)
    for _, item in ipairs(car.trunk.items) do p.alice.inventory:AddItem(item) end
    car.trunk.items = {}
    walk(p.alice, 120, 120)
    advance(6000, 1000)
    check("carrying the gold changes the goal", lastHud("alice").goal:find("gold bar", 1, true), lastHud("alice").goal)
    walk(p.alice, 150, 150)
    advance(11000, 1000)
    check("delivering the gold wins", Runtime.ActiveRuntimes.heist == nil and table.concat(rewarded, ",") == "alice", table.concat(rewarded, ","))
    check("the gold is banked", Bandits.GoldCarried(p.alice) == 0)
    check("the car is removed afterwards", car.removed == true)
    local record = History.List()[1]
    check("the run is in past events", record and record.definitionId == "heist" and record.outcome == "WIN"
        and record.winners[1] == "alice", record and record.outcome)
end

------------------------------------------------------------
-- Moves: the client moves itself; long moves hop past anti-cheat.
------------------------------------------------------------
do
    reset()
    local p = player("mover")
    local Move = KIPN.Server.EventMoveService
    Move.Player(p, { x = 5, y = 5, z = 0 })
    check("a short move jumps", moves.mover and moves.mover.hop == nil and p.x == 5)
    Move.Player(p, { x = 400, y = 5, z = 0 })
    check("a long move hops under the speed check", moves.mover.hop == Move.HOP and p.x == 400, moves.mover.hop)
    getServerOptions = function() return { getOption = function() return "4" end } end
    Move.Player(p, { x = 900, y = 5, z = 0 })
    check("with the speed check off it jumps", moves.mover.hop == nil)
    getServerOptions = nil
    Move.Player(p, { x = 12.25, y = 30.75, z = 1 })
    check("positions stay exact", p.x == 12.25 and p.y == 30.75 and p.z == 1)
end

------------------------------------------------------------
-- Start / Announcements / Cancel
------------------------------------------------------------
local function prepared(id, status)
    local def = { id = id, name = "Prepared " .. id, mode = "SURVIVOR_RUN", objectiveTypes = { "SURVIVE" }, status = status,
        eventType = "HORDE_SURVIVAL", combatRules = { allowLeaveZone = true }, scopeType = "OPEN_MAP", participants = {},
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 900, expiryBehavior = "WIN" }, roundDuration = {},
        narrative = { briefing = "Hold the church till dawn.", winText = "You made it.", failText = "The church fell." },
        hotspots = { hotspot("spawn", "PLAYER_SPAWN", 20, 20) } }
    definitions[id] = def
    return def
end
-- The real announce / open-joining handlers live in the scenario
-- service (tested by the tester's harness); here they just move on.
commandHandlers.eventAnnounce = function(_, args)
    if definitions[args.id].status == "READY" then definitions[args.id].status = "ANNOUNCED" end
end
commandHandlers.eventOpenJoining = function(_, args)
    if definitions[args.id].status == "ANNOUNCED" then definitions[args.id].status = "JOINING" end
end
KIPN.Shared.Commands.EVENT_ANNOUNCE = "eventAnnounce"
KIPN.Shared.Commands.EVENT_OPEN_JOINING = "eventOpenJoining"

do
    reset()
    local admin, alice, bob = player("admin"), player("alice"), player("bob")
    local def = prepared("qs", "READY")
    commandHandlers.eventQuickStart(admin, { id = "qs", signupSeconds = 12 })
    check("Start announces and opens sign-ups", def.status == "JOINING" and Control.IsPending("qs"), def.status)
    check("everyone is asked to sign up", banners("bob"):find("Sign up now", 1, true), banners("bob"))
    check("the admin is told when it begins", actionResults.admin and actionResults.admin.success
        and actionResults.admin.text:find("12 seconds", 1, true), actionResults.admin and actionResults.admin.text)
    def.participants.alice = true
    advance(7000, 500)
    check("a countdown is shown", banners("bob"):find("begins in 5", 1, true), banners("bob"))
    check("it has not begun yet", Runtime.ActiveRuntimes.qs == nil)
    advance(6000, 500)
    check("it begins when sign-ups close", Runtime.ActiveRuntimes.qs ~= nil and def.status == "ACTIVE", def.status)
    check("everyone hears it has begun", banners("bob"):find("has begun", 1, true))
    check("sign-ups are brought in", Runtime.ActiveRuntimes.qs and Runtime.ActiveRuntimes.qs.participants.alice ~= nil)

    commandHandlers.eventQuickStart(admin, { id = "qs" })
    check("Start on a running event is refused", actionResults.admin.success == false)

    -- Cancel a live event: stopped, back to Ready, recorded.
    commandHandlers.eventCancel(admin, { id = "qs" })
    check("Cancel stops a live event and keeps it prepared", Runtime.ActiveRuntimes.qs == nil and def.status == "READY"
        and (function() for _ in pairs(def.participants) do return false end return true end)(), def.status)
    check("a cancelled run is in past events", History.List()[1].definitionId == "qs" and History.List()[1].outcome == "MANUAL",
        History.List()[1].outcome)

    -- From Joining: sign-ups told, back to Ready.
    def.status = "JOINING"
    def.participants = { alice = true }
    commandHandlers.eventCancel(admin, { id = "qs" })
    check("Cancel during sign-ups puts it back to Ready", def.status == "READY")
    check("those who signed up are told", banners("alice"):find("has been cancelled", 1, true))
    check("recorded as cancelled", History.List()[1].outcome == "CANCELLED")

    -- A pending start is called off.
    commandHandlers.eventQuickStart(admin, { id = "qs", signupSeconds = 30 })
    commandHandlers.eventCancel(admin, { id = "qs" })
    check("Cancel calls off a pending start", not Control.IsPending("qs") and def.status == "READY", def.status)
    advance(31000, 1000)
    check("and it never begins", Runtime.ActiveRuntimes.qs == nil)

    -- Ready goes back to Draft; a Draft has nothing to cancel.
    commandHandlers.eventCancel(admin, { id = "qs" })
    check("Cancel on Ready unlocks it for editing", def.status == "DRAFT")
    commandHandlers.eventCancel(admin, { id = "qs" })
    check("a draft has nothing to cancel", actionResults.admin.success == false)
    commandHandlers.eventQuickStart(admin, { id = "qs" })
    check("a draft can't be started from here", actionResults.admin.success == false
        and actionResults.admin.text:find("draft", 1, true), actionResults.admin.text)

    -- Announcements.
    commandHandlers.eventSendAnnouncement(admin, { id = "qs", text = "Soon!" })
    check("drafts can't be announced", actionResults.admin.success == false)
    def.status = "READY"
    commandHandlers.eventSendAnnouncement(admin, { id = "qs", text = "Doors open at noon." })
    check("an announcement reaches everyone online", banners("bob"):find("Doors open at noon.", 1, true)
        and actionResults.admin.text:find("3 players", 1, true), actionResults.admin.text)
    commandHandlers.eventSendAnnouncement(admin, { id = "qs", text = "   " })
    check("an empty announcement sends the briefing", banners("bob"):find("Hold the church till dawn.", 1, true))
    local listed
    KIPN.Server.SendToPlayer = (function(before) return function(p, event, data)
        if event == "eventHistoryData" then listed = data.records end
        before(p, event, data)
    end end)(KIPN.Server.SendToPlayer)
    commandHandlers.eventListHistory(admin, {})
    check("past events are listed for the Studio, newest first", listed and #listed >= 3 and listed[1].outcome == "CANCELLED")
end

------------------------------------------------------------
-- Simulate
------------------------------------------------------------
do
    reset()
    vehicles = {}
    simPayloads, actionResults = {}, {}
    for name in pairs(moves) do moves[name] = nil end
    local admin, staff, alice = player("admin"), player("staff"), player("alice")
    local gm, watcher = player("gm"), player("watcher")
    walk(admin, 500, 500); walk(staff, 510, 510); walk(alice, 700, 700); walk(gm, 520, 520); walk(watcher, 530, 530)
    levels.staff, levels.alice, levels.gm, levels.watcher = "STAFF", "USER", "GM", "OBSERVER"
    -- The sandbox defaults: moderators, staff and GMs may be invited; observers not.
    SandboxVars = { DynamicEvents = { SimulationModerator = true, SimulationStaff = true, SimulationGM = true, SimulationObserver = false } }
    local invites = {}
    KIPN.Server.SendToPlayer = (function(before) return function(p, event, data)
        if event == "eventSimulationInvite" then invites[p.name] = data end
        before(p, event, data)
    end end)(KIPN.Server.SendToPlayer)
    local authorize = KIPN.Server.Permissions.AuthorizeEventTier
    local def = prepared("sim", "READY")
    def.mode, def.variant, def.objectiveTypes = "EXTRACTION", "ABANDONED_SOLDIER", { "SURVIVE" }
    def.zoneId, def.loadout = "z", "SOLDIER"
    def.threats = { SIEGE = true, FIRES = true }
    def.rewards = { items = { { itemFullType = "Base.Axe", count = 1 } } }
    def.hotspots = { hotspot("spawn", "PLAYER_SPAWN", 10, 10),
        hotspot("note", "NARRATIVE_LOCATION", 30, 30, nil, nil, { narrativeText = "The key is under the mat.", replayable = true, clueTitle = "Note" }),
        hotspot("horde", "ZOMBIE_SPAWN", 60, 60), hotspot("camp", "BANDIT_CAMP", 90, 90, nil, nil, { count = 2 }),
        hotspot("exit", "EXTRACTION_POINT", 150, 150) }
    def.objectives = KIPN.Server.EventTriggerService.SanitizeObjectives({
        { id = "o1", name = "The gate", triggers = { { activationMode = "PROXIMITY", hotspotId = "note",
            actions = { { type = "SPAWN_BANDITS", params = { count = 2 } }, { type = "ANNOUNCEMENT", params = { text = "Hold the gate!" } } } } } } })

    commandHandlers.eventSimulate(admin, { id = "sim", includeStaff = true })
    local session = Sim.sessions.sim
    check("Simulate starts a session", session ~= nil and actionResults.admin and actionResults.admin.success, actionResults.admin and actionResults.admin.text)
    check("the event itself is untouched", def.status == "READY" and Runtime.ActiveRuntimes.sim == nil)
    local function last(name) local all = simPayloads[name] or {} return all[#all] end
    -- Voluntary: allowed staff are invited, nobody is pulled in.
    check("allowed staff are invited", invites.staff and invites.gm and invites.staff.host == "admin" and invites.staff.name == def.name)
    check("players and levels the sandbox leaves out are not", invites.alice == nil and invites.watcher == nil and invites.admin == nil)
    check("the host is told how many were invited", actionResults.admin.text:find("2 staff invited", 1, true), actionResults.admin.text)
    check("nobody joins until they say OK", session.viewers.staff == nil and moves.staff == nil and last("staff") == nil)
    commandHandlers.eventSimulationRespond(staff, { id = "sim", accept = true })
    check("OK joins and takes them to the start", session.viewers.staff and moves.staff and moves.staff.x == 10.5, moves.staff and moves.staff.x)
    check("the guest sees the current step", last("staff") and last("staff").index == 1 and last("staff").admin == "admin")
    check("the host hears who joined", actionResults.admin.text:find("staff joined", 1, true), actionResults.admin.text)
    commandHandlers.eventSimulationRespond(gm, { id = "sim", accept = false })
    check("Cancel opts out and stays put", not session.viewers.gm and moves.gm == nil and last("gm") == nil)
    check("the host hears who opted out", actionResults.admin.text:find("gm opted out", 1, true), actionResults.admin.text)
    check("the simulation carries on", Sim.sessions.sim == session)
    commandHandlers.eventSimulationRespond(gm, { id = "sim", accept = true })
    commandHandlers.eventSimulationRespond(alice, { id = "sim", accept = true })
    check("only an open invitation lets someone in", not session.viewers.gm and not session.viewers.alice)
    check("only the admin and staff who said OK take part", session.viewers.admin and session.viewers.staff and not session.viewers.alice)
    local first = last("admin")
    check("step 1 is the briefing", first and first.index == 1 and first.title == "Briefing", first and first.title)
    check("every hotspot glows, the zone too", first and #first.hotspots == 5 and first.zone ~= nil)
    check("the guide lists every step", first and #first.steps == first.total and first.total >= 12, first and first.total)
    check("staff see the same step", last("staff") and last("staff").index == 1)
    check("nobody else sees it", last("alice") == nil)
    check("the admin is taken to the start", moves.admin and moves.admin.x == 10.5, moves.admin and moves.admin.x)
    check("others are not moved", moves.alice == nil and moves.watcher == nil)
    check("the briefing plays", banners("admin"):find("Hold the church", 1, true) and not banners("alice"):find("Hold the church", 1, true))

    local seen = {}
    local function ok() commandHandlers.eventSimulateStep(admin, { id = "sim", choice = "OK" }) return last("admin") end
    local step = first
    seen[step.title] = step
    while step and not step.ended do
        step = ok()
        if step and step.title then seen[step.title] = step end
        if step and step.title == "Starting loadout: Abandoned soldier" then
            check("the loadout is laid out", #session.items >= 5, #session.items)
        elseif step and step.key == "hotspot:note" then
            local hud = sentHud.admin[#sentHud.admin]
            check("a clue plays and becomes a button", hud.clues and hud.clues[1] and hud.clues[1].title == "Note")
            check("the focused hotspot is marked", (function()
                for _, h in ipairs(step.hotspots) do if h.focus then return h.id == "note" end end end)())
            check("the loadout items went at the next step", #session.items == 0)
        elseif step and step.key == "hotspot:horde" then
            check("zombies spawn at a zombie spawn", spawns[#spawns] and spawns[#spawns].x == 60)
        elseif step and step.key == "hotspot:camp" then
            local crew = crews(session.runtime)[1]
            check("the camp's crew shows, calm", crew and #crew.members == 2 and crew.calm)
            check("bandits are marked for their own outline", #step.bandits == 2)
            session.campBodies = crew.members
        elseif step and step.key and step.key:find("^trigger:") then
            check("the previous step's bandits are gone", session.campBodies and session.campBodies[1].zombie.removed == true)
            check("story actions play for those watching only", banners("admin"):find("Hold the gate!", 1, true)
                and not banners("alice"):find("Hold the gate!", 1, true))
            check("a story crew arrives", #crews(session.runtime) == 1 and #crews(session.runtime)[1].members == 2)
            check("the admin goes to the trigger's hotspot", moves.admin.x == 30.5)
        elseif step and step.key == "threats" then
            check("a small siege comes from four sides", #spawns >= 4)
            check("the fire is only light", #step.fires == 1 and #fires == 0)
        elseif step and step.key == "ending" then
            check("win and lose text play", banners("admin"):find("You made it.", 1, true) and banners("admin"):find("The church fell.", 1, true))
            check("prizes are listed", step.text:find("Base.Axe", 1, true))
        end
    end
    check("every part was shown", seen.Briefing and seen["The event zone"] and seen["Rounds and the clock"]
        and seen["That's the whole event"] ~= nil)
    check("OK on the last step finishes", step and step.ended and step.finished and Sim.sessions.sim == nil)
    check("everyone is taken back", moves.admin.x == 500 and moves.staff.x == 510)
    check("the simulation's clues are cleared", sentHud.admin[#sentHud.admin].clues and #sentHud.admin[#sentHud.admin].clues == 0)
    local standing = 0
    for _, zombie in ipairs(zombies) do if not zombie.dead and not zombie.removed then standing = standing + 1 end end
    check("no bandit is left standing", standing == 0, standing)

    -- Edit pauses; Resume replays the step with the changes.
    commandHandlers.eventSimulateStep(admin, { id = "sim", choice = "OK" })
    check("steps need a running simulation", actionResults.admin.success == false)
    commandHandlers.eventSimulate(admin, { id = "sim" })
    session = Sim.sessions.sim
    check("without staff it is just the admin", session and session.viewers.staff == nil)
    ok(); ok()
    local before = last("admin")
    commandHandlers.eventSimulateStep(admin, { id = "sim", choice = "EDIT" })
    check("Edit pauses on the step", last("admin").editing == true and last("admin").index == before.index)
    check("Edit points the Studio at the right step", last("admin").studioStep ~= nil, last("admin").studioStep)
    commandHandlers.eventSimulateStep(admin, { id = "sim", choice = "OK" })
    check("OK waits while editing", actionResults.admin.success == false and last("admin").index == before.index)
    table.insert(def.hotspots, hotspot("gate", "OBJECTIVE_LOCATION", 40, 40))
    commandHandlers.eventSimulateStep(admin, { id = "sim", choice = "RESUME" })
    check("Resume picks up the changes", last("admin").editing == false and last("admin").total == before.total + 1
        and last("admin").key == before.key, last("admin").total)

    -- Cancel cleans up everything and goes back.
    ok(); ok(); ok(); ok()
    commandHandlers.eventSimulateStep(admin, { id = "sim", choice = "CANCEL" })
    check("Cancel ends it", Sim.sessions.sim == nil and last("admin").ended and not last("admin").finished)
    check("Cancel takes the admin back", moves.admin.x == 500)
    check("Cancel leaves no items behind", #session.items == 0)
    standing = 0
    for _, zombie in ipairs(zombies) do if not zombie.dead and not zombie.removed then standing = standing + 1 end end
    check("Cancel leaves no bandits behind", standing == 0, standing)

    -- Rules.
    commandHandlers.eventSimulate(admin, { id = "sim" })
    commandHandlers.eventSimulate(admin, { id = "sim" })
    check("one simulation at a time", actionResults.admin.success == false)
    commandHandlers.eventQuickStart(admin, { id = "sim" })
    check("no Start while simulating", actionResults.admin.success == false and def.status == "READY")
    commandHandlers.eventCancel(admin, { id = "sim" })
    check("Cancel <event> also ends its simulation", Sim.sessions.sim == nil and def.status == "READY")
    def.status = "DRAFT"
    commandHandlers.eventSimulate(admin, { id = "sim" })
    check("drafts can be simulated", Sim.sessions.sim ~= nil)
    for i, p in ipairs(players) do if p == admin then table.remove(players, i) end end
    Sim.Tick()
    check("the host dropping out gets a minute's grace", Sim.sessions.sim ~= nil)
    advance(61000, 5000)
    Sim.Tick()
    check("after it, the simulation cleans up", Sim.sessions.sim == nil)
    players[#players + 1] = admin
    def.status = "ACTIVE"
    commandHandlers.eventSimulate(admin, { id = "sim" })
    check("a live event can't be simulated", Sim.sessions.sim == nil and actionResults.admin.success == false)
    KIPN.Server.Permissions.AuthorizeEventTier = authorize

    -- A guest can only leave; the simulation carries on without them.
    def.status = "READY"
    for name in pairs(invites) do invites[name] = nil end
    commandHandlers.eventSimulate(admin, { id = "sim", includeStaff = true })
    session = Sim.sessions.sim
    commandHandlers.eventSimulationRespond(staff, { id = "sim", accept = true })
    local at = session.index
    commandHandlers.eventSimulateStep(staff, { id = "sim", choice = "OK" })
    check("a guest can't move the steps on", session.index == at and actionResults.staff.text:find("Leave", 1, true), actionResults.staff and actionResults.staff.text)
    commandHandlers.eventSimulateStep(staff, { id = "sim", choice = "CANCEL" })
    check("a guest's Cancel means Leave", not session.viewers.staff and last("staff").ended and last("staff").left and moves.staff.x == 510)
    check("and the simulation carries on for the host", Sim.sessions.sim == session and actionResults.admin.text:find("staff left", 1, true))
    commandHandlers.eventSimulateStep(admin, { id = "sim", choice = "OK" })
    check("the host keeps going", session.index == at + 1)
    commandHandlers.eventSimulateStep(admin, { id = "sim", choice = "CANCEL" })
    check("ending it withdraws open invitations", invites.gm and invites.gm.withdrawn == true)

    -- Studio access follows the sandbox.
    local S = KIPN.Server.EventAccessService
    local moderator = player("moderator")
    levels.moderator = "MODERATOR"
    SandboxVars.DynamicEvents.StudioModerator = false
    -- Non-admins fail KIPN's admin check.
    KIPN.Server.AdminService.RequirePermission = function() return false end
    check("staff levels are refused the Studio by default", S.RequireStudio(moderator) == false)
    SandboxVars.DynamicEvents.StudioModerator = true
    check("an allowed level may use it", S.RequireStudio(moderator) == true)
    check("other levels still may not", S.RequireStudio(watcher) == false)
    check("admins always may", KIPN.Shared.EventAccessAllows("Studio", "ADMIN") and KIPN.Shared.EventAccessAllows("Simulation", "ADMIN"))
    commandHandlers.eventListHistory(watcher, {})
    commandHandlers.eventSimulate(watcher, { id = "sim" })
    check("a refused level can't simulate", Sim.sessions.sim == nil)
    commandHandlers.eventSimulate(moderator, { id = "sim" })
    check("an allowed level can", Sim.sessions.sim ~= nil and Sim.sessions.sim.admin == "moderator")
    Sim.Cancel("sim", "test")
    KIPN.Server.AdminService.RequirePermission = function() return true end
    SandboxVars.DynamicEvents.StudioModerator = false
end

print(string.format("server_loop_checks: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
