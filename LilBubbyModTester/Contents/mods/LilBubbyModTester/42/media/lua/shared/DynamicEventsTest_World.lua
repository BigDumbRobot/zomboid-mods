require "DynamicEventsTest_Checks"
require "LilBubbySites"

-- World ops for the Dynamic Events suite. They run where events run: on the
-- server in multiplayer (DynamicEventsTest_Server.lua), directly in single
-- player. Every event is made through Dynamic Events' own command handlers,
-- called as the tester exactly as the Event Studio would; the ops only read
-- its state to report what happened. Events the test makes are named with
-- T.PREFIX, items it hands out carry T.MARKER, and cleanup removes both.
local T = DynamicEventsTest
T.World = T.World or {}
local World = T.World

local results = {}      -- definitionId -> { outcome, winners } recorded at the end
local originalFinish     -- the game loop's Finish, while the test wraps it
local medalSnapshot      -- the Olympics medal table before a test race

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------

local function server() return KIPN and KIPN.Server end
local function shared() return KIPN and KIPN.Shared end
local function now() return getTimestampMs() end

local function line(lines, status, name, detail) lines[#lines + 1] = { status, name, detail } end
local function check(lines, name, condition, detail)
    line(lines, condition and "PASS" or "FAIL", name, detail)
    return condition and true or false
end

------------------------------------------------------------
-- STAFF STAND-IN
--
-- Dynamic Events lets only staff make and run events, and every player may
-- run this suite. The player is never made staff: while the server runs a
-- tester op for them (World.AsStaff), Dynamic Events' own gates answer yes
-- for that player, and only until the op returns. KIPN's admin list, the
-- player's role and every other mod's permissions are untouched.
------------------------------------------------------------

local acting = {}        -- username -> how many tester ops are running for them
local gated = false

local function username(player)
    local ok, name = pcall(function() return player:getUsername() end)
    return ok and name or nil
end

local function isActing(player)
    local name = player and username(player)
    return name ~= nil and acting[name] ~= nil
end

local function testEvent(id)
    local def = id and server().EventScenarioService.GetDefinition(id)
    return def ~= nil and tostring(def.name):sub(1, #T.PREFIX) == T.PREFIX
end

-- Commands the mod's own windows send for the player during a test (the
-- simulation panel's buttons, the Studio opened by Edit). On one of the
-- tester's events they run as staff; on a real event they stay refused.
local PANEL_COMMANDS = { EVENT_SIMULATE_STEP = true, EVENT_SIMULATION_RESPOND = true, EVENT_GET_STATUS = true }
-- Read-only lists the Studio window asks for when it opens.
local LIST_COMMANDS = { EVENT_LIST_DEFINITIONS = true, EVENT_LIST_HISTORY = true }
local wrapped = {}

local function wrapHandlers()
    local handlers = server().CommandHandlers
    if type(handlers) ~= "table" then return end
    for key, name in pairs(shared().Commands or {}) do
        local handler = handlers[name]
        if (PANEL_COMMANDS[key] or LIST_COMMANDS[key]) and type(handler) == "function" and not wrapped[name] then
            wrapped[name] = true
            handlers[name] = function(player, args, ...)
                if not (LIST_COMMANDS[key] or testEvent(type(args) == "table" and args.id)) then return handler(player, args, ...) end
                local ok, result = World.AsStaff(player, handler, player, args, ...)
                if not ok then error(result, 0) end
                return result
            end
        end
    end
end

-- Puts the stand-in in front of Dynamic Events' gates, once its services exist.
function World.Staff()
    local S = server()
    if not (S and S.EventAccessService and S.Permissions and shared() and shared().Commands) then return false end
    wrapHandlers()
    if gated then return true end
    gated = true
    local Access, Permissions = S.EventAccessService, S.Permissions
    local level, studio, simulations, tier = Access.Level, Access.RequireStudio, Access.CanJoinSimulations, Permissions.AuthorizeEventTier
    Access.Level = function(player) if isActing(player) then return "ADMIN" end return level(player) end
    Access.RequireStudio = function(player) if isActing(player) then return true end return studio(player) end
    Access.CanJoinSimulations = function(player) if isActing(player) then return true end return simulations(player) end
    if tier then
        Permissions.AuthorizeEventTier = function(player, category)
            if isActing(player) then return true, "ADMIN" end
            return tier(player, category)
        end
    end
    return true
end

-- Runs fn(...) with the stand-in up for this player. Returns ok, result as pcall does.
function World.AsStaff(player, fn, ...)
    World.Staff()
    local name = username(player)
    if not name then return pcall(fn, ...) end
    acting[name] = (acting[name] or 0) + 1
    local ok, result = pcall(fn, ...)
    acting[name] = acting[name] > 1 and acting[name] - 1 or nil
    return ok, result
end

-- Calls one of Dynamic Events' command handlers as this player and returns
-- every reply it sent them: { { event, data }, ... }.
local function call(player, command, args)
    local name = shared().Commands[command]
    local handler = name and server().GetCommandHandler and server().GetCommandHandler(name)
    if not handler then return nil, command .. " has no handler" end
    local replies = {}
    local send = server().SendToPlayer
    server().SendToPlayer = function(target, event, data)
        if target == player then replies[#replies + 1] = { event = event, data = data } end
        return send(target, event, data)
    end
    local ok, err = pcall(handler, player, args or {})
    server().SendToPlayer = send
    if not ok then return nil, tostring(err) end
    return replies
end

local function reply(replies, eventKey)
    local event = shared().ResponseEvents[eventKey]
    for i = #(replies or {}), 1, -1 do
        if replies[i].event == event then return replies[i].data end
    end
end

local function definition(id) return server().EventScenarioService.GetDefinition(id) end
local function simulation(id) return server().EventSimulationService and server().EventSimulationService.sessions[id] end
local tracked = {}       -- definitionId -> what a simulation had made, to check it is gone after Cancel
local function runtime(id) return server().EventRuntimeService.ActiveRuntimes[id] end

local function box(x, y, z, half)
    return { x1 = x - half, y1 = y - half, x2 = x + half, y2 = y + half, z1 = z, z2 = z }
end

local function records(player)
    local out = {}
    local online = getOnlinePlayers()
    for i = 0, (online and online:size() or 0) - 1 do out[online:get(i)] = true end
    return out[player] == true
end

-- Wraps the game loop's Finish so each test event's result is kept.
local function recordResults()
    local Loop = server().EventGameLoopService
    if originalFinish or not Loop then return end
    originalFinish = Loop.Finish
    Loop.Finish = function(rt, def, outcome)
        local winners = {}
        for username in pairs(rt.winners or {}) do winners[#winners + 1] = username end
        table.sort(winners)
        if def and tostring(def.name):sub(1, #T.PREFIX) == T.PREFIX then
            results[def.id] = { outcome = outcome, winners = winners }
        end
        return originalFinish(rt, def, outcome)
    end
end

local function eachItem(container, fn)
    local items = container:getItems()
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        fn(item, container)
        local ok, inner = pcall(function() return item:getItemContainer() end)
        if ok and inner then eachItem(inner, fn) end
    end
end

local function give(player, fullType)
    local inventory = player:getInventory()
    local item = inventory:AddItem(fullType)
    if not item then return nil end
    item:getModData()[T.MARKER] = true
    if isServer() then sendAddItemToContainer(inventory, item) end
    return item
end

-- Moves an item lying in the world into the player's inventory.
local function pickUp(player, item, point)
    if not item then return false end
    pcall(function()
        local square = getCell():getGridSquare(point.x, point.y, point.z or 0)
        local objects = square:getWorldObjects()
        for i = objects:size() - 1, 0, -1 do
            local worldItem = objects:get(i)
            if worldItem:getItem() == item then
                square:transmitRemoveItemFromSquare(worldItem)
                worldItem:removeFromWorld()
                worldItem:removeFromSquare()
            end
        end
    end)
    local inventory = player:getInventory()
    inventory:AddItem(item)
    if isServer() then pcall(sendAddItemToContainer, inventory, item) end
    return true
end

------------------------------------------------------------
-- BUILDING A TEST EVENT
------------------------------------------------------------

-- Links the event to the designated event zone (LilBubbySites). The tester
-- never draws a zone: an admin lays the test sites out, and the showcase moves
-- the player into the zone before a test that needs one. Returns true or false, reason.
local function useZone(player, id)
    local problem = LilBubbySites.Problem(player, "event")
    if problem then return false, problem end
    local saved = reply(call(player, "EVENT_SET_ZONE", { id = id, zoneId = LilBubbySites.Get("event").id }), "EVENT_ZONE_SAVED")
    return saved ~= nil and saved.success == true, saved and saved.reason
end

-- A test event's zone is the designated one, which stays. A zone an earlier
-- version of the tester drew for the event is switched off.
local function releaseZone(def)
    local site = LilBubbySites.Get("event")
    if not def.zoneId or (site and tostring(site.id) == tostring(def.zoneId)) then return false end
    return pcall(server().WorldRegistry.DeactivateZone, def.zoneId)
end

-- Creates an event, saves `settings` onto it and adds `hotspots`.
-- Returns the definition id or nil, error.
local function create(player, name, settings, hotspots)
    local replies, err = call(player, "EVENT_CREATE_DEFINITION", { name = T.PREFIX .. name, eventType = "HORDE_SURVIVAL" })
    local saved = reply(replies, "EVENT_DEFINITION_SAVED")
    if not saved or not saved.success then return nil, err or (saved and saved.reason) or "not created" end
    local id = saved.definition.id
    local payload = T.BaseDefinition(name)
    for key, value in pairs(settings or {}) do payload[key] = value end
    payload.id = id
    replies, err = call(player, "EVENT_UPDATE_DEFINITION", payload)
    saved = reply(replies, "EVENT_DEFINITION_SAVED")
    if not saved or not saved.success then return nil, err or (saved and saved.reason) or "not saved" end
    for _, hotspot in ipairs(hotspots or {}) do
        replies = call(player, "EVENT_UPSERT_HOTSPOT", { id = id, hotspot = hotspot })
        local hotspotSaved = reply(replies, "EVENT_HOTSPOT_SAVED")
        if not hotspotSaved or not hotspotSaved.success then
            return nil, "hotspot " .. tostring(hotspot.type) .. ": " .. tostring(hotspotSaved and hotspotSaved.reason)
        end
    end
    return id
end

-- Validates, opens joining without broadcasting, puts the tester on the
-- roster and begins. Returns true or false, reason.
local function begin(player, id)
    local replies = call(player, "EVENT_VALIDATE", { id = id })
    local changed = reply(replies, "EVENT_STATUS_CHANGED")
    if not changed or not changed.success then return false, "not valid: " .. tostring(changed and changed.reason) end
    local def = definition(id)
    server().EventScenarioService.SetDefinitionStatus(id, "JOINING")
    def.participants[player:getUsername()] = true
    replies = call(player, "EVENT_START", { id = id })
    local started = reply(replies, "EVENT_STARTED")
    if not started or not started.success then return false, "not started: " .. tostring(started and started.reason) end
    return true
end

local function hotspot(hotspotType, x, y, z, half, round, extra)
    local h = { type = hotspotType, label = hotspotType, roundNumber = round, geometry = box(x, y, z, half) }
    for key, value in pairs(extra or {}) do h[key] = value end
    return h
end

-- Each kind of test event: settings, hotspots (offsets from the tester) and
-- the points the client flow walks to.
local KINDS = {}

KINDS.survivor = function(opts)
    return { mode = "SURVIVOR_RUN", timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = opts.seconds or 25, expiryBehavior = "WIN" },
        loadout = opts.loadout or "NONE", rewardItems = opts.rewardItems or {},
        threats = opts.threats or { SIEGE = false, FIRES = false, ALARM = false }, objectives = opts.objectives or {} }, opts.hotspots or {}
end
-- A narrative spot (a replayable clue) and a story stage whose trigger
-- gives a private hint; the stage is wired to its hotspot after both exist.
KINDS.clues = function()
    return { mode = "SURVIVOR_RUN", timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 180, expiryBehavior = "WIN" } },
        { { "NARRATIVE_LOCATION", 6, 0, 1, nil, "clue", nil, { narrativeText = "The code is 4-7-1. Remember it.", narrativeScope = "LOCAL", clueTitle = "Test clue" } },
          { "OBJECTIVE_LOCATION", -6, 0, 1, nil, "hint" } }
end
KINDS.threats = function()
    return { mode = "SURVIVOR_RUN", timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 240, expiryBehavior = "WIN" },
        threats = { SIEGE = true, FIRES = false, ALARM = true } },
        { { "ZOMBIE_AMBUSH", 15, 0, 2, nil, "ambush", nil, { count = 3 } } }
end
KINDS.capture = function()
    return { mode = "CAPTURE", variant = "FFA", objectiveTypes = { "RETRIEVE", "DELIVER" }, outcomeTypes = { "FIRST_TO_COMPLETE" },
        timerType = "ROUND_TIMER", roundDuration = { enabled = true, durationSeconds = 120 },
        captureConfig = { flagItemFullType = "Base.Hat_Beret", autoReturnSeconds = 90 } },
        { { "CAPTURE_ITEM", 4, 0, 1, 1, "flag" }, { "DELIVERY_POINT", 14, 0, 2, 1, "goal" } }
end
KINDS.ctf = function()
    return { mode = "CAPTURE", variant = "TEAM_CTF", objectiveTypes = { "RETRIEVE", "DELIVER" }, outcomeTypes = { "FIRST_TO_COMPLETE" },
        timerType = "ROUND_TIMER", roundDuration = { enabled = true, durationSeconds = 120 },
        captureConfig = { flagItemFullType = "Base.Hat_Beret", autoReturnSeconds = 90 } },
        { { "TEAM_BASE", 14, 0, 2, 1, "home", "team_1" }, { "TEAM_BASE", -14, 0, 2, 1, "enemy", "team_2" },
          { "CAPTURE_ITEM", 0, 14, 1, 1 }, { "DELIVERY_POINT", 0, -14, 1, 1 } }, 2
end
KINDS.koth = function()
    return { mode = "KING_OF_THE_HILL", objectiveTypes = { "HOLD_AREA" }, outcomeTypes = { "HOLD_DURATION" },
        timerType = "ROUND_TIMER", roundDuration = { enabled = true, durationSeconds = 40 } },
        { { "HILL_LOCATION", 6, 0, 2, 1, "hill" } }, 2
end
KINDS.chase = function()
    return { mode = "CHASE", objectiveTypes = { "CHASE_TARGET" }, outcomeTypes = { "LAST_ALIVE" },
        timerType = "ROUND_TIMER", roundDuration = { enabled = true, durationSeconds = 30 } }, {}
end
KINDS.extraction = function()
    return { mode = "EXTRACTION", variant = "ABANDONED_SOLDIER", outcomeTypes = { "EXTRACTION" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 60, expiryBehavior = "WIN" } },
        { { "EXTRACTION_POINT", 10, 0, 2, nil, "exit" } }
end
KINDS.prison = function()
    return { mode = "EXTRACTION", variant = "PRISON_BREAK", objectiveTypes = { "RETRIEVE" }, outcomeTypes = { "EXTRACTION" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 120, expiryBehavior = "WIN" } },
        { { "CAPTURE_ITEM", 6, 0, 1, nil, "search" }, { "EXTRACTION_POINT", 14, 0, 2, nil, "exit" } }
end
KINDS.firesale = function()
    return { mode = "EXTRACTION", variant = "FIRE_SALE", outcomeTypes = { "EXTRACTION" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 120, expiryBehavior = "WIN" } },
        { { "EXTRACTION_POINT", 25, 0, 2, nil, "exitA" }, { "EXTRACTION_POINT", -25, 0, 2, nil, "exitB" },
          { "EXTRACTION_POINT", 0, 25, 2, nil, "exitC" } }
end
KINDS.olympics = function()
    local function station(n, dx, task, meta)
        meta = meta or {}
        meta.task = task
        return { "OLYMPIC_STATION", dx, 0, 1, n, "station" .. n, nil, meta }
    end
    return { mode = "OLYMPICS", objectiveTypes = { "LOCATE" }, outcomeTypes = { "FIRST_TO_COMPLETE" },
        olympicsConfig = { heatSize = 1, heatLimitSeconds = 300, discipline = "OBSTACLE" } },
        { { "OLYMPIC_START", 2, 0, 1, nil, "start" },
          station(1, 6, "CHECKPOINT"),
          station(2, 10, "CHOP", { itemType = "Base.Log", count = 2, kit = { "Base.Axe" } }),
          station(3, 14, "CRAFT", { itemType = "Base.Plank", count = 2, kit = { "Base.Saw" } }),
          station(4, 18, "CARRY", { itemType = "Base.Log", count = 1 }),
          { "OLYMPIC_DROP", 18, 6, 1, 4, "drop" },
          station(5, 22, "SHOOT", { count = 2, kit = {} }),
          { "OLYMPIC_TARGETS", 22, 10, 2, 5, "targets" },
          { "OLYMPIC_FINISH", 26, 0, 1, nil, "finish" } }
end

-- Bandits: a crew waiting at a camp; a raid on demand; The Heist.
KINDS.bandits = function()
    return { mode = "SURVIVOR_RUN", timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 180, expiryBehavior = "WIN" } },
        { { "BANDIT_CAMP", 16, 0, 2, nil, "camp", nil, { count = 2 } } }
end
KINDS.raid = function()
    return { mode = "SURVIVOR_RUN", timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 180, expiryBehavior = "WIN" },
        threats = { SIEGE = false, FIRES = false, ALARM = false, BANDITS = true } }, {}
end
KINDS.heist = function()
    return { mode = "EXTRACTION", variant = "HEIST", objectiveTypes = { "RETRIEVE" }, outcomeTypes = { "EXTRACTION" },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 240, expiryBehavior = "WIN" } },
        { { "BANDIT_VEHICLE", 16, 0, 2, nil, "car", nil, { count = 1 } }, { "EXTRACTION_POINT", -12, 0, 2, nil, "exit" } }
end
-- A prepared event with one of everything a simulation walks through.
KINDS.prepared = function()
    return { mode = "SURVIVOR_RUN", timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 60, expiryBehavior = "WIN" },
        loadout = "DRIFTER", threats = { SIEGE = true, FIRES = true, ALARM = false, BANDITS = false },
        narrative = { briefing = "LilBubby test briefing: hold the line.", winText = "LilBubby test: you won.", failText = "LilBubby test: you lost." },
        rewardItems = { { itemFullType = "Base.Apple", count = 1 } } },
        { { "PLAYER_SPAWN", 6, 0, 1, nil, "spawn" },
          { "NARRATIVE_LOCATION", 12, 0, 1, nil, "clue", nil, { narrativeText = "LilBubby test clue.", narrativeScope = "LOCAL", clueTitle = "Test note" } },
          { "ZOMBIE_SPAWN", 20, 0, 2, nil, "horde" },
          { "BANDIT_CAMP", -14, 0, 2, nil, "camp", nil, { count = 1 } } }
end

-- Builds and (unless opts.draft) starts a test event of `kind` around the
-- player. Returns { id, points = { name = {x, y, z} } }.
function World.setup(player, args)
    local lines = {}
    if not records(player) then
        return { error = "Dynamic Events finds participants with getOnlinePlayers(), which does not list you here. Use a multiplayer test server." }
    end
    for id, rt in pairs(server().EventRuntimeService.ActiveRuntimes) do
        local def = definition(id)
        if not (def and tostring(def.name):sub(1, #T.PREFIX) == T.PREFIX) then
            return { error = "A real event is running (" .. tostring(def and def.name) .. "). Only one event can run at a time." }
        end
        server().EventRuntimeService.StopEvent(player, id, "TESTER", "MANUAL")
    end
    recordResults()
    local builder = KINDS[args.kind]
    if not builder then return { error = "unknown kind " .. tostring(args.kind) } end
    local settings, spots, teams = builder(args)
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local hotspots, points = {}, { here = { x = px, y = py, z = pz } }
    for _, spot in ipairs(spots) do
        if spot.type then
            hotspots[#hotspots + 1] = spot
        else
            local x, y = px + spot[2], py + spot[3]
            hotspots[#hotspots + 1] = hotspot(spot[1], x, y, pz, spot[4], spot[5], { teamId = spot[7], metadata = spot[8] })
            if spot[6] then points[spot[6]] = { x = x, y = y, z = pz } end
        end
    end
    local id, err = create(player, args.kind, settings, {})
    if not id then return { error = err } end
    if teams then call(player, "EVENT_SET_TEAM_COUNT", { id = id, teamCount = teams }) end
    for _, h in ipairs(hotspots) do
        local replies = call(player, "EVENT_UPSERT_HOTSPOT", { id = id, hotspot = h })
        local saved = reply(replies, "EVENT_HOTSPOT_SAVED")
        if not saved or not saved.success then return { id = id, error = "hotspot " .. h.type .. ": " .. tostring(saved and saved.reason) } end
    end
    if args.kind == "clues" then
        local stageHotspot
        for _, h in ipairs(definition(id).hotspots or {}) do
            if h.type == "OBJECTIVE_LOCATION" then stageHotspot = h.id end
        end
        local replies = call(player, "EVENT_UPDATE_DEFINITION", { id = id, objectives = {
            { id = "test_stage", name = "Find the note", triggers = { { activationMode = "PROXIMITY", hotspotId = stageHotspot,
                actions = { { type = "PRIVATE_HINT", params = { text = "Look under the mat." } } } } } } } })
        local saved = reply(replies, "EVENT_DEFINITION_SAVED")
        check(lines, "Added a story stage with a hint trigger", saved and saved.success, saved and saved.reason)
    end
    if args.kind == "prepared" then
        local clue
        for _, h in ipairs(definition(id).hotspots or {}) do
            if h.type == "NARRATIVE_LOCATION" then clue = h.id end
        end
        local replies = call(player, "EVENT_UPDATE_DEFINITION", { id = id, objectives = {
            { id = "test_stage", name = "The line", triggers = { { activationMode = "PROXIMITY", hotspotId = clue,
                actions = { { type = "ANNOUNCEMENT", params = { text = "LilBubby test story line." } },
                    { type = "SPAWN_BANDITS", params = { count = 1 } } } } } } } })
        local saved = reply(replies, "EVENT_DEFINITION_SAVED")
        check(lines, "Added a story stage (announcement and bandits)", saved and saved.success, saved and saved.reason)
        if args.ready then
            local changed = reply(call(player, "EVENT_VALIDATE", { id = id }), "EVENT_STATUS_CHANGED")
            check(lines, "Checked it and marked it Ready", changed and changed.success, changed and changed.reason)
        end
    end
    if args.zone then
        local linked, reason = useZone(player, id)
        check(lines, "Linked the event to the designated event zone", linked, reason)
    end
    if args.kind == "olympics" then
        definition(id).olympicsCountries = { [player:getUsername()] = "Muldraugh" }
        local ok, data = pcall(function() return ModData.getOrCreate(server().EventOlympicsService.MEDAL_DATA_KEY) end)
        if ok and data and not medalSnapshot then
            medalSnapshot = {}
            for country, row in pairs(data) do medalSnapshot[country] = { gold = row.gold, silver = row.silver, bronze = row.bronze } end
        end
    end
    if args.draft then return { id = id, points = points, lines = lines } end
    local ok, reason = begin(player, id)
    if not ok then return { id = id, error = reason } end
    local p = player
    return { id = id, points = points, lines = lines,
        joinedAt = { x = math.floor(p:getX()), y = math.floor(p:getY()), z = math.floor(p:getZ()) } }
end

------------------------------------------------------------
-- READING AN EVENT
------------------------------------------------------------

-- Everything a flow checks, in one reply.
function World.state(player, args)
    local def = definition(args.id)
    local rt = runtime(args.id)
    local user = player:getUsername()
    local out = { exists = def ~= nil, status = def and def.status, active = rt ~= nil,
        x = player:getX(), y = player:getY(), z = player:getZ() }
    local result = results[args.id]
    if result then out.outcome, out.winners = result.outcome, result.winners end
    if def then out.participant = def.participants and def.participants[user] == true end
    if rt then
        out.round = rt.round and { current = rt.round.current, state = rt.round.state, maximum = rt.round.maximum }
        out.difficulty = rt.difficulty
        out.endsInMs = rt.endsAtMs and (rt.endsAtMs - now()) or nil
        out.spawned = #(rt.spawnedEventZombies or {})
        out.clues = #((rt.clues or {})[user] or {})
        out.dead = rt.deaths and rt.deaths[user] or false
        if rt.extractionState then
            local st = rt.extractionState
            out.evacOpen = st.evacOpen == true
            out.extracted = st.extracted[user] == true
            out.unlocked = st.unlocked[user] == true
            if st.safeExitId then
                local exit = server().EventHotspotService.FindById(def, st.safeExitId)
                out.safeExit = exit and server().EventHotspotService.GetCenter(exit)
            end
        end
        if rt.captureState then
            out.flags = {}
            for _, entry in pairs(rt.captureState.items) do
                out.flags[#out.flags + 1] = { state = entry.state, teamId = entry.teamId, carrier = entry.carrierUsername }
            end
            out.team = server().EventTeamService.GetPlayerTeam(def, user)
        end
        if rt.kothState then out.holder = rt.kothState.currentControllerTeamId end
        if rt.objectiveState then out.chaseTarget = rt.objectiveState.chaseTarget end
        if rt.olympicsState then
            local st = rt.olympicsState
            local racer = st.racers[user]
            out.racer = racer and { status = racer.status, timeMs = racer.timeMs, medal = racer.medal, country = racer.country }
            out.heatPhase = st.heat and st.heat.phase
            local progress = st.heat and st.heat.progress[user]
            out.station = progress and progress.index
            out.arrived = progress and progress.arrived
        end
        if rt.threatState then
            out.alarmed = rt.threatState.alarmed == true
            out.sieges = rt.threatState.sieges
            local ambushed = 0
            for _ in pairs(rt.threatState.ambushed or {}) do ambushed = ambushed + 1 end
            out.ambushed = ambushed
        end
    end
    local B = server().EventBanditService
    if rt and rt.banditState then
        local alive, calm, hostile, gold = 0, 0, 0, 0
        for _, crew in ipairs(rt.banditState.crews or {}) do
            for _, member in ipairs(crew.members) do
                if not member.state then
                    alive = alive + 1
                    if crew.calm then calm = calm + 1 else hostile = hostile + 1 end
                end
            end
        end
        for _, vehicle in ipairs(rt.banditState.vehicles or {}) do
            pcall(function()
                eachItem(vehicle:getPartById("TruckBed"):getItemContainer(), function(item)
                    if item:getModData()[B.GOLD_TAG] then gold = gold + 1 end
                end)
            end)
        end
        out.bandits = { crews = #(rt.banditState.crews or {}), alive = alive, calm = calm, hostile = hostile,
            vehicles = #(rt.banditState.vehicles or {}) }
        out.goldInTrunk = gold
    end
    if B then out.goldCarried = B.GoldCarried(player) end
    if rt and rt.extractionState then out.gold = rt.extractionState.gold end
    local session = simulation(args.id)
    out.simulating = session ~= nil
    if session then
        local crews = (session.runtime.banditState or {}).crews or {}
        local guests = 0
        for username in pairs(session.viewers) do if username ~= session.admin then guests = guests + 1 end end
        out.sim = { index = session.index, total = #session.steps, key = session.steps[session.index].key,
            editing = session.editing, items = #session.items, crews = #crews, guests = guests, host = session.admin,
            invited = session.invited and session.invited[user] == true }
    end
    local Control = server().EventControlService
    out.pending = Control and Control.IsPending(args.id) or false
    local History = server().EventHistoryService
    for _, record in ipairs(History and History.List() or {}) do
        if record.definitionId == args.id then
            out.lastRun = { outcome = record.outcome, result = record.result }
            break
        end
    end
    local loadoutItems, tagged = {}, 0
    eachItem(player:getInventory(), function(item)
        local ok, value = pcall(function() return item:getModData().DE_LoadoutItem end)
        if ok and value then
            tagged = tagged + 1
            loadoutItems[#loadoutItems + 1] = item:getFullType()
        end
    end)
    out.loadoutTagged, out.loadoutItems = tagged, loadoutItems
    out.inventoryCount = player:getInventory():getItems():size()
    return out
end

------------------------------------------------------------
-- ACTING IN AN EVENT
------------------------------------------------------------

function World.act(player, args)
    local what = args.what
    local rt = runtime(args.id)
    if what == "call" then
        local callArgs = type(args.args) == "table" and args.args or {}
        callArgs.id = callArgs.id or args.id
        local replies, err = call(player, args.command, callArgs)
        if not replies then return { error = err } end
        local out = { events = {} }
        for _, r in ipairs(replies) do
            out.events[#out.events + 1] = r.event
            if type(r.data) == "table" then
                out.success = out.success or r.data.success
                out.reason = out.reason or r.data.reason
                if r.data.status and type(r.data.status) == "table" then out.statusEndsAtMs = r.data.status.endsAtMs end
                if r.data.awards then out.awards = r.data.awards end
            end
        end
        local def = definition(args.id)
        out.status = def and def.status
        out.endsInMs = rt and rt.endsAtMs and (rt.endsAtMs - now()) or nil
        return out
    elseif what == "takeFlag" then
        if not (rt and rt.captureState) then return { error = "no flag in play" } end
        local team = server().EventTeamService.GetPlayerTeam(definition(args.id), player:getUsername())
        for _, entry in pairs(rt.captureState.items) do
            if entry.state ~= "DELIVERED" and (not team or entry.teamId ~= team) then
                return { taken = pickUp(player, entry.liveItemRef, entry.lastKnownPosition) }
            end
        end
        return { error = "no flag to take" }
    elseif what == "give" then
        local given = 0
        for _ = 1, math.max(1, math.min(10, tonumber(args.count) or 1)) do
            if give(player, tostring(args.item)) then given = given + 1 end
        end
        return { given = given }
    elseif what == "takeLoad" then
        local progress = rt and rt.olympicsState and rt.olympicsState.heat and rt.olympicsState.heat.progress[player:getUsername()]
        if not (progress and progress.load) then return { error = "no load to lift" } end
        return { taken = pickUp(player, progress.load.item, progress.load.point) }
    elseif what == "killTargets" then
        local progress = rt and rt.olympicsState and rt.olympicsState.heat and rt.olympicsState.heat.progress[player:getUsername()]
        if not (progress and progress.targets) then return { error = "no targets" } end
        local killed = 0
        for _, zombie in ipairs(progress.targets) do
            if pcall(function() zombie:setHealth(0); zombie:Kill(nil) end) then killed = killed + 1 end
        end
        return { killed = killed }
    elseif what == "raid" then
        if not rt then return { error = "not running" } end
        local crew = server().EventBanditService.Raid(rt, definition(args.id))
        return { members = crew and #crew.members or 0 }
    elseif what == "takeGold" then
        -- Opens the getaway car's trunk and takes the gold, as a player would.
        local taken = 0
        for _, vehicle in ipairs(rt and rt.banditState and rt.banditState.vehicles or {}) do
            pcall(function()
                local trunk = vehicle:getPartById("TruckBed"):getItemContainer()
                eachItem(trunk, function(item, container)
                    if item:getModData()[server().EventBanditService.GOLD_TAG] then
                        container:Remove(item)
                        if isServer() then sendRemoveItemFromContainer(container, item) end
                        item:getModData()[T.MARKER] = true
                        player:getInventory():AddItem(item)
                        if isServer() then sendAddItemToContainer(player:getInventory(), item) end
                        taken = taken + 1
                    end
                end)
            end)
        end
        return { taken = taken }
    elseif what == "simTrack" then
        -- Remembers everything the simulation has made, to check Cancel removes it.
        local session = simulation(args.id)
        if not session then return { error = "no simulation" } end
        local t = { zombies = {}, items = {}, vehicles = {} }
        for _, zombie in ipairs(session.runtime.spawnedEventZombies or {}) do t.zombies[#t.zombies + 1] = zombie end
        for _, crew in ipairs((session.runtime.banditState or {}).crews or {}) do
            for _, member in ipairs(crew.members) do t.zombies[#t.zombies + 1] = member.zombie end
        end
        for _, vehicle in ipairs((session.runtime.banditState or {}).vehicles or {}) do t.vehicles[#t.vehicles + 1] = vehicle end
        for _, entry in ipairs(session.items) do t.items[#t.items + 1] = entry end
        tracked[args.id] = t
        return { zombies = #t.zombies, items = #t.items, vehicles = #t.vehicles }
    elseif what == "simLeftovers" then
        local t = tracked[args.id] or { zombies = {}, items = {}, vehicles = {} }
        local zombies, items, vehicles = 0, 0, 0
        for _, zombie in ipairs(t.zombies) do
            local ok, there = pcall(function() return not zombie:isDead() and zombie:getCurrentSquare() ~= nil and zombie:isExistInTheWorld() end)
            if ok and there then zombies = zombies + 1 end
        end
        for _, entry in ipairs(t.items) do
            pcall(function()
                local objects = getCell():getGridSquare(entry.point.x, entry.point.y, entry.point.z or 0):getWorldObjects()
                for i = 0, objects:size() - 1 do
                    if objects:get(i):getItem() == entry.item then items = items + 1 end
                end
            end)
        end
        for _, vehicle in ipairs(t.vehicles) do
            local ok, gone = pcall(function() return vehicle:isRemovedFromWorld() end)
            if ok and not gone then vehicles = vehicles + 1 end
        end
        tracked[args.id] = nil
        return { zombies = zombies, items = items, vehicles = vehicles, tracked = #t.zombies + #t.items + #t.vehicles }
    elseif what == "hostSim" then
        -- Someone else hosts a simulation of the test event, so you are
        -- the invited staff member. The host is a stand-in that is never
        -- online (a simulation waits a minute for an absent host).
        local host = { hostName = T.PREFIX .. "host", x = player:getX(), y = player:getY(), z = player:getZ() }
        function host:getUsername() return self.hostName end
        function host:getX() return self.x end
        function host:getY() return self.y end
        function host:getZ() return self.z end
        local session, reason = server().EventSimulationService.Start(host, definition(args.id), true)
        if not session then return { error = tostring(reason) } end
        return { invited = session.invitedCount or 0, total = #session.steps }
    elseif what == "hostStep" then
        local session = simulation(args.id)
        if not session then return { error = "no simulation" } end
        server().EventSimulationService.Choose(session, "OK")
        return { index = session.index }
    elseif what == "hostEnd" then
        return { ended = server().EventSimulationService.Cancel(args.id, "Tester") }
    elseif what == "move" then
        -- The event moves you: the server asks your client (hops if far).
        local Move = server().EventMoveService
        local target = { x = math.floor(player:getX()) + (tonumber(args.dx) or 0) + 0.5, y = math.floor(player:getY()) + 0.5, z = math.floor(player:getZ()) }
        local far = math.abs(tonumber(args.dx) or 0) > Move.JUMP_TILES
        return { moved = Move.Player(player, target), target = target, hop = far and not Move.CanJump(player) and Move.HOP or nil }
    elseif what == "stop" then
        if rt then server().EventRuntimeService.StopEvent(player, args.id, "TESTER", args.outcome or "MANUAL") end
        return {}
    end
    return { error = "unknown action " .. tostring(what) }
end

------------------------------------------------------------
-- ONE-SHOT CHECKS
------------------------------------------------------------

World.checks = {}

World.checks.services = function(player, lines)
    local S = server()
    for _, name in ipairs({ "EventScenarioService", "EventRuntimeService", "EventGameLoopService", "EventHotspotService",
        "EventTeamService", "EventTimerService", "EventScenarioRuntimeRegistry", "EventCaptureService", "EventKOTHService",
        "EventChaseService", "EventExtractionService", "EventSurvivorRunService", "EventAdventureService",
        "EventOlympicsService", "EventThreatService", "EventLoadoutService", "EventParticipationService",
        "EventRewardService", "EventTriggerService", "EventEscrowService", "ZombieDirector", "EventDirector" }) do
        check(lines, name .. " is loaded", type(S[name]) == "table")
    end
    local missing = {}
    for key, command in pairs(shared().Commands) do
        if key:find("^EVENT_") and not (S.GetCommandHandler and S.GetCommandHandler(command)) then missing[#missing + 1] = key end
    end
    table.sort(missing)
    check(lines, "Every event command has a handler (services started)", #missing == 0, table.concat(missing, ", "))
    check(lines, "The event zone type is registered", S.WorldRegistry and S.WorldRegistry.ZoneTypes and S.WorldRegistry.ZoneTypes.EVENT == "event")
    check(lines, "Staff tiers can be checked (AuthorizeEventTier)", S.Permissions and type(S.Permissions.AuthorizeEventTier) == "function")
    local ok, tier = pcall(S.Permissions.AuthorizeEventTier, player, "VIEW")
    line(lines, "INFO", "Your event tier", tostring(tier) .. (ok and "" or " (check failed)"))
    check(lines, "The server sees you as an online player (events need this)", records(player))
end

local function itemExists(fullType)
    local ok, item = pcall(function() return getScriptManager():FindItem(fullType) end)
    return ok and item ~= nil
end

World.checks.items = function(_, lines)
    local missing, total = {}, 0
    local function look(fullType, where)
        if type(fullType) ~= "string" then return end
        total = total + 1
        if not itemExists(fullType) then missing[#missing + 1] = fullType .. " (" .. where .. ")" end
    end
    for id, loadout in pairs(shared().EventLoadouts or {}) do
        for _, key in ipairs({ "wear", "items", "bagItems", "randomBag", "handsOneOf", "oneOf" }) do
            for _, fullType in ipairs(loadout[key] or {}) do look(fullType, id) end
        end
        look(loadout.hands, id); look(loadout.bag, id); look(loadout.rareHands, id)
        for _, drop in ipairs(loadout.dropNearby or {}) do
            look(drop.item, id)
            for _, fullType in ipairs(drop.contents or {}) do look(fullType, id) end
        end
    end
    for task, spec in pairs(shared().EventOlympicTasks or {}) do
        look(spec.itemType, "Olympics " .. task)
        for _, fullType in ipairs(spec.kit or {}) do look(fullType, "Olympics " .. task) end
    end
    look("Base.Hat_Beret", "test flag")
    check(lines, "All " .. total .. " loadout, kit and course items exist in this game", #missing == 0, table.concat(missing, "; "))
end

-- Each case: settings, hotspots, the reasons validation must give.
local VALIDATION_CASES = {
    { "A zone event without a zone", { mode = "SURVIVOR_RUN", scopeType = "ZONE", timerType = "COUNTDOWN",
        duration = { enabled = true, durationSeconds = 60, expiryBehavior = "WIN" } }, {}, { "NO_ZONE" } },
    { "King of the Hill without Hold Area or teams", { mode = "KING_OF_THE_HILL", objectiveTypes = { "SURVIVE" } }, {},
        { "KOTH_REQUIRES_HOLD_AREA_OBJECTIVE", "TEAM_COUNT_TOO_LOW" } },
    { "Capture without a flag item", { mode = "CAPTURE", variant = "FFA", objectiveTypes = { "RETRIEVE" } }, {},
        { "CAPTURE_FLAG_ITEM_REQUIRED" } },
    { "Extraction without an exit or a length", { mode = "EXTRACTION", variant = "ABANDONED_SOLDIER" }, {},
        { "EXTRACTION_REQUIRES_EXTRACTION_POINT_HOTSPOT", "EXTRACTION_REQUIRES_DURATION" } },
    { "An Olympics with no course", { mode = "OLYMPICS", objectiveTypes = { "LOCATE" } }, {},
        { "OLYMPICS_START_REQUIRED", "OLYMPICS_FINISH_REQUIRED" } },
    { "A round timer with no round length", { mode = "CHASE", objectiveTypes = { "CHASE_TARGET" }, timerType = "ROUND_TIMER" }, {},
        { "ROUND_TIMER_DURATION_REQUIRED" } },
    { "A complete Survivor Run", { mode = "SURVIVOR_RUN", timerType = "COUNTDOWN",
        duration = { enabled = true, durationSeconds = 60, expiryBehavior = "WIN" } }, {}, {} },
}

World.checks.validation = function(player, lines)
    for _, case in ipairs(VALIDATION_CASES) do
        local id, err = create(player, "validation", case[2], case[3])
        if not id then
            check(lines, case[1] .. ": event made", false, err)
        else
            local replies = call(player, "EVENT_VALIDATE", { id = id })
            local changed = reply(replies, "EVENT_STATUS_CHANGED") or {}
            if #case[4] == 0 then
                check(lines, case[1] .. " passes and is Ready", changed.success == true and definition(id).status == "READY", changed.reason)
            else
                local reason = tostring(changed.reason)
                local missing = {}
                for _, code in ipairs(case[4]) do
                    if not reason:find(code, 1, true) then missing[#missing + 1] = code end
                end
                check(lines, case[1] .. " is refused with " .. table.concat(case[4], ", "), changed.success == false and #missing == 0, reason)
            end
            call(player, "EVENT_DELETE_DEFINITION", { id = id })
        end
    end
end

World.checks.laststanding = function(player, lines)
    local Run = server().EventSurvivorRunService
    local user = player:getUsername()
    local rt = { participants = { [user] = {}, ghostA = {}, ghostB = {} }, deaths = { ghostA = true, ghostB = true } }
    check(lines, "With the others down, you are the last one standing", Run.LastStanding(rt) == user, tostring(Run.LastStanding(rt)))
    rt = { participants = { [user] = {} }, deaths = {} }
    check(lines, "Alone, nobody wins by elimination", Run.LastStanding(rt) == nil)
    rt = { participants = { [user] = {}, ghostA = {} }, deaths = { [user] = true, ghostA = true } }
    check(lines, "Everyone down ends the run", Run.AllDown(rt) == true)
end

World.checks.adventure = function(player, lines)
    local id, err = create(player, "adventure", { mode = "ADVENTURE", scopeType = "ZONE",
        captureConfig = { flagItemFullType = "Base.Hat_Beret", autoReturnSeconds = 90 } }, {})
    if not check(lines, "Made an Adventure event", id ~= nil, err) then return end
    local linked, reason = useZone(player, id)
    if not check(lines, "Linked it to the designated event zone", linked, reason) then
        call(player, "EVENT_DELETE_DEFINITION", { id = id })
        return
    end
    local def = definition(id)
    local seen, restored = {}, true
    for _ = 1, 60 do
        local rt = { instanceId = "adventure-test", participants = {} }
        local ok, rollErr = server().EventAdventureService.RollAndGenerate(rt, def)
        if ok then
            seen[rt.adventureState.rolledId] = (seen[rt.adventureState.rolledId] or 0) + 1
            server().EventAdventureService.RestoreOriginal(rt, def)
            if def.mode ~= "ADVENTURE" or #(def.hotspots or {}) ~= 0 then restored = false end
        else
            check(lines, "Rolled a game", false, rollErr)
            break
        end
    end
    local names = {}
    for rolled, count in pairs(seen) do names[#names + 1] = rolled .. " x" .. count end
    table.sort(names)
    check(lines, "Rolls several different games (flag item set, so Capture is eligible)", #names >= 4, table.concat(names, ", "))
    check(lines, "Every roll is put back afterwards", restored)
    releaseZone(def)
    call(player, "EVENT_DELETE_DEFINITION", { id = id })
end

World.checks.difficulty = function(_, lines)
    local Threats = server().EventThreatService
    local counts = { NORMAL = 0, DIRE = 0, BRUTAL = 0 }
    for _ = 1, 2000 do
        local rolled = Threats.Roll("RANDOM")
        counts[rolled] = (counts[rolled] or 0) + 1
    end
    local hard = (counts.DIRE + counts.BRUTAL) / 2000
    check(lines, "About half the rolls are Dire or Brutal", hard > 0.44 and hard < 0.56, string.format("%.1f%%", hard * 100))
    check(lines, "About 1 in 8 is Brutal", counts.BRUTAL / 2000 > 0.09 and counts.BRUTAL / 2000 < 0.16, string.format("%.1f%%", counts.BRUTAL / 20))
    check(lines, "A fixed difficulty is kept", Threats.Roll("DIRE") == "DIRE" and Threats.Roll("BRUTAL") == "BRUTAL" and Threats.Roll("NORMAL") == "NORMAL")
    check(lines, "Anything else counts as Normal", Threats.Roll("nonsense") == "NORMAL")
end

World.checks.fire = function(player, lines)
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local square
    for _, offset in ipairs({ { 10, 0 }, { -10, 0 }, { 0, 10 }, { 0, -10 }, { 8, 8 } }) do
        local sq = getCell():getGridSquare(px + offset[1], py + offset[2], pz)
        if sq and sq:isOutside() and sq:getFloor() and not sq:isSolidTrans() and not square then square = sq end
    end
    if not square then line(lines, "SKIP", "No open outdoor square 10 tiles from you", "stand outdoors on open ground") return end
    local started = pcall(function() IsoFireManager.StartFire(getCell(), square, true, 100, 500) end)
    local burning = started and pcall(function() return square:Is(IsoFlagType.burning) end) and square:Is(IsoFlagType.burning)
    check(lines, "The fire Dynamic Events uses starts", burning, square:getX() .. "," .. square:getY())
    pcall(function() square:stopFire() end)
    pcall(function()
        local objects = square:getObjects()
        for i = objects:size() - 1, 0, -1 do
            local object = objects:get(i)
            if instanceof(object, "IsoFire") then square:transmitRemoveItemFromSquare(object) end
        end
        square:getProperties():unset(IsoFlagType.burning)
        square:getProperties():unset(IsoFlagType.smoke)
        square:RecalcProperties()
    end)
    local out = not (pcall(function() return square:Is(IsoFlagType.burning) end) and square:Is(IsoFlagType.burning))
    check(lines, "And the test puts it out again", out)
    check(lines, "Fire lines are ready for players", #(server().EventThreatService.FIRE_LINES or {}) > 0)
end

-- A simulation's steps for an event with one of everything, built
-- without running it: every part is covered, in the order players meet it.
World.checks.simsteps = function(_, lines)
    local Sim = server().EventSimulationService
    if not check(lines, "The simulation service is loaded", Sim ~= nil) then return end
    local function spot(id, hotspotType, x, meta)
        return { id = id, type = hotspotType, active = true, metadata = meta, geometry = box(x, 0, 0, 1) }
    end
    local def = { id = "lilbubby_sim_check", name = T.PREFIX .. "steps", mode = "EXTRACTION", variant = "HEIST", loadout = "SOLDIER",
        threats = { BANDITS = true, SIEGE = true }, narrative = { briefing = "B", winText = "W", failText = "F" }, rewards = { items = {} },
        timerType = "COUNTDOWN", duration = { enabled = true, durationSeconds = 600 },
        hotspots = { spot("x", "EXTRACTION_POINT", 50), spot("z", "ZOMBIE_SPAWN", 40), spot("car", "BANDIT_VEHICLE", 30, { count = 2 }),
            spot("n", "NARRATIVE_LOCATION", 20, { narrativeText = "clue" }), spot("s", "PLAYER_SPAWN", 10) },
        objectives = { { id = "o", name = "Stage", triggers = { { id = "t", activationMode = "PROXIMITY", hotspotId = "n",
            actions = { { type = "SPAWN_BANDITS", params = { count = 2 } } } } } } } }
    local steps = Sim.BuildSteps(def)
    local at = {}
    for index, step in ipairs(steps) do at[step.key] = index end
    check(lines, "It opens with the briefing", steps[1].key == "briefing")
    check(lines, "The loadout comes next", at.loadout == 2, at.loadout)
    check(lines, "Hotspots come in the order players meet them",
        at["hotspot:s"] < at["hotspot:n"] and at["hotspot:n"] < at["hotspot:car"] and at["hotspot:car"] < at["hotspot:z"] and at["hotspot:z"] < at["hotspot:x"])
    check(lines, "Story triggers follow the places", (at["trigger:o:t"] or 0) > at["hotspot:x"])
    check(lines, "Then threats, rounds and the clock, and the ending", at.threats and at.threats < at.rules and at.rules < at.ending)
    check(lines, "It ends with a last step to finish", steps[#steps].key == "done")
    local missing = {}
    for _, step in ipairs(steps) do if not step.studioStep or not step.title or not step.text then missing[#missing + 1] = step.key end end
    check(lines, "Every step has a title, a guide and a Studio step for Edit", #missing == 0, table.concat(missing, ", "))
    check(lines, "The Heist's car step mentions the gold", steps[at["hotspot:car"]].text:find("gold", 1, true) ~= nil)
    line(lines, "INFO", "Steps", tostring(#steps))
end

-- Who may use the Studio and be invited to simulations, by this server's
-- sandbox options; and that the server lets you, if your level is one of them.
World.checks.access = function(player, lines)
    local Access = server().EventAccessService
    if not check(lines, "The access service is loaded", Access ~= nil) then return end
    local level = Access.Level(player)
    line(lines, "INFO", "Your KIPN level", level)
    local options = SandboxVars and SandboxVars.DynamicEvents or {}
    for _, key in ipairs(shared().EventStaffLevelOrder or {}) do
        local suffix = shared().EventStaffLevels[key]
        line(lines, "INFO", key .. ": Event Studio " .. (options["Studio" .. suffix] and "allowed" or "not allowed")
            .. ", simulations " .. (options["Simulation" .. suffix] and "can be invited" or "not invited"))
        check(lines, key .. " follows the sandbox", shared().EventAccessAllows("Studio", key) == (options["Studio" .. suffix] == true)
            and shared().EventAccessAllows("Simulation", key) == (options["Simulation" .. suffix] == true))
    end
    check(lines, "Admins may always use the Studio and join simulations", shared().EventAccessAllows("Studio", "ADMIN")
        and shared().EventAccessAllows("Simulation", "ADMIN"))
    check(lines, "Players never may", not shared().EventAccessAllows("Studio", "USER") and not shared().EventAccessAllows("Simulation", "USER"))
    if level == "ADMIN" or shared().EventAccessAllows("Studio", level) then
        check(lines, "The server lets you use the Studio", Access.RequireStudio(player) == true)
    else
        line(lines, "INFO", "Your level may not use the Studio", "the tester acts as staff for you, on its own test events only")
    end
    if level == "ADMIN" or shared().EventAccessAllows("Simulation", level) then
        check(lines, "You can be invited to simulations", Access.CanJoinSimulations(player) == true)
    else
        check(lines, "Your level is not invited to simulations", Access.CanJoinSimulations(player) == false)
    end
end

function World.check(player, args)
    local fn = World.checks[args.name]
    if not fn then return { error = "unknown check " .. tostring(args.name) } end
    local lines = {}
    local ok, err = pcall(fn, player, lines)
    if not ok then line(lines, "FAIL", "Check crashed", tostring(err)) end
    return { lines = lines }
end

------------------------------------------------------------
-- CLEANUP
------------------------------------------------------------

-- Stops, resets and deletes every event the test made, retires their
-- zones, takes back the items it gave and restores the medal table.
function World.cleanup(player, args)
    local S = server()
    local removedEvents, zones = 0, 0
    local all = {}
    -- Simulations and pending starts of test events end first.
    for id in pairs(S.EventSimulationService and S.EventSimulationService.sessions or {}) do
        local def = definition(id)
        if def and tostring(def.name):sub(1, #T.PREFIX) == T.PREFIX then S.EventSimulationService.Cancel(id, "Tester cleanup") end
    end
    for id in pairs(S.EventControlService and S.EventControlService.pending or {}) do
        local def = definition(id)
        if def and tostring(def.name):sub(1, #T.PREFIX) == T.PREFIX then S.EventControlService.pending[id] = nil end
    end
    local ok, list = pcall(S.EventScenarioService.ListDefinitions)
    for _, def in pairs(ok and type(list) == "table" and list or {}) do all[#all + 1] = def end
    for _, def in ipairs(all) do
        if tostring(def.name):sub(1, #T.PREFIX) == T.PREFIX then
            if runtime(def.id) then S.EventRuntimeService.StopEvent(player, def.id, "TESTER", "MANUAL") end
            if def.status == "COMPLETE" then call(player, "EVENT_RESET", { id = def.id }) end
            if def.status ~= "DRAFT" and def.status ~= "READY" then S.EventScenarioService.SetDefinitionStatus(def.id, "DRAFT") end
            if releaseZone(def) then zones = zones + 1 end
            call(player, "EVENT_DELETE_DEFINITION", { id = def.id })
            removedEvents = removedEvents + 1
        end
    end
    local items = 0
    eachItem(player:getInventory(), function(item, container)
        if item:getModData()[T.MARKER] then
            if player:isEquipped(item) then player:removeWornItem(item) end
            container:Remove(item)
            if isServer() then sendRemoveItemFromContainer(container, item) end
            items = items + 1
        end
    end)
    if medalSnapshot then
        pcall(function()
            local data = ModData.getOrCreate(S.EventOlympicsService.MEDAL_DATA_KEY)
            for country in pairs(data) do data[country] = nil end
            for country, row in pairs(medalSnapshot) do data[country] = row end
        end)
        medalSnapshot = nil
    end
    if originalFinish then
        S.EventGameLoopService.Finish = originalFinish
        originalFinish = nil
    end
    -- Test runs leave no trace in Past events.
    local history = S.EventHistoryService and S.EventHistoryService.List() or {}
    for i = #history, 1, -1 do
        if tostring(history[i].name):sub(1, #T.PREFIX) == T.PREFIX then table.remove(history, i) end
    end
    results = {}
    return { events = removedEvents, zones = zones, items = items }
end

return T
