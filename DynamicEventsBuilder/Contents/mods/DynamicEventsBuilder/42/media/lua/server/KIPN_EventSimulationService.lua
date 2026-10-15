-- KIPN_EventSimulationService.lua
--
-- Simulate <event>: a stepped walk-through of an event exactly as it is
-- designed, for the admin who runs it (the host) and any staff who
-- choose to join. No players are invited and the event's own status
-- never changes.
--
-- Joining is voluntary. With "Invite online staff" ticked, every online
-- player whose KIPN level the sandbox allows (DynamicEvents.Simulation<Level>;
-- admins always) gets a short invitation with OK and Cancel. OK takes
-- them to the simulation (its start, or wherever it has got to) and in;
-- Cancel opts them out and the simulation carries on without them. A
-- guest can Leave at any time; only the host moves the steps on.
--
-- Each step moves everyone watching to the right place, does what the
-- event will do there, and waits for the admin:
--   OK      next step
--   EDIT    stay on this step; the Event Studio opens on the related
--           step so anything can be changed or added
--   RESUME  (after EDIT) rebuild the steps from the saved event and
--           play this step again
--   CANCEL  remove everything the simulation made (zombies, bandits,
--           the getaway car, items, clues) and put everyone back
--
-- Steps, built from the definition: the briefing; the zone; the
-- starting loadout (laid out on the ground); every hotspot in the order
-- players meet them (spawns, bases, the course, items, hills, clues,
-- bandits, zombie spawns, ambushes, the way out), each doing its thing;
-- every story trigger, in order, with its actions shown only to those
-- watching; the threats, shown small; rounds and the clock; the
-- ending (win text, lose text, prizes); done.
--
-- Everything a step spawns is removed when the next step starts, so the
-- world never fills up. The client (client/KIPN_EventSimulationUI.lua)
-- draws the guide panel, makes every hotspot glow (the one this step is
-- about pulses), outlines zombies (bandits in their own colour) and
-- keeps the admin invisible and unhurt while it runs.
--
-- The simulation has its own runtime table, never an entry in
-- ActiveRuntimes, so no event tick, win check or reward can touch it.

if isClient() and not isServer() then return end

require "KIPN_Shared"
require "DynamicEvents_Shared"
require "KIPN_EventAccessService"
require "KIPN_EventHotspotService"
require "KIPN_EventMoveService"
require "KIPN_EventBanditService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventSimulationService = KIPN.Server.EventSimulationService or {}

local Sim = KIPN.Server.EventSimulationService

Sim.TAG = "DE_Simulation"
Sim.DEMO_ZOMBIES = 5
Sim.MAX_DEMO = 12
Sim.sessions = Sim.sessions or {}

-- The order players meet things in.
Sim.HOTSPOT_ORDER = { "PLAYER_SPAWN", "TEAM_SPAWN", "TEAM_BASE", "OLYMPIC_START", "OLYMPIC_STATION", "OLYMPIC_DROP",
    "OLYMPIC_TARGETS", "OLYMPIC_FINISH", "CAPTURE_ITEM", "DELIVERY_POINT", "HILL_LOCATION", "RESCUE_OBJECTIVE",
    "OBJECTIVE_LOCATION", "NARRATIVE_LOCATION", "BANDIT_VEHICLE", "BANDIT_CAMP", "ZOMBIE_SPAWN", "ZOMBIE_AMBUSH",
    "EXTRACTION_POINT" }

-- Which Event Studio step each part is edited on.
Sim.STUDIO_STEP = { briefing = "story", zone = "area", loadout = "mode", hotspot = "area", story = "story",
    threats = "zombies", rules = "rules", ending = "rewards", done = "launch" }

local HELP = {
    PLAYER_SPAWN = "Players arrive here when the event begins.",
    TEAM_SPAWN = "This team arrives here when the event begins.",
    TEAM_BASE = "A team's base: its flag starts here and stolen flags are brought here to score.",
    OLYMPIC_START = "The start line. Two athletes line up here for each heat; stepping off early is a false start.",
    OLYMPIC_STATION = "A course station. Athletes must complete its task before moving on.",
    OLYMPIC_DROP = "Where the heavy load has to be carried to.",
    OLYMPIC_TARGETS = "The shooting range: every target here must go down.",
    OLYMPIC_FINISH = "The finish line. The clock stops here.",
    CAPTURE_ITEM = "The item to grab appears here.",
    DELIVERY_POINT = "Carried items must be brought here.",
    HILL_LOCATION = "The hill. Standing on it alone scores; two sides on it is contested.",
    RESCUE_OBJECTIVE = "Someone or something to rescue.",
    OBJECTIVE_LOCATION = "A goal spot the story uses.",
    NARRATIVE_LOCATION = "Walking in shows this text. Clues stay on the player's screen as a button to read again.",
    BANDIT_VEHICLE = "The getaway car, guarded by its crew. They stay calm until someone gets close or opens fire.",
    BANDIT_CAMP = "A bandit crew waits here, calm until someone gets close or opens fire.",
    ZOMBIE_SPAWN = "Zombies come from here.",
    ZOMBIE_AMBUSH = "A room of zombies that wakes the first time someone comes near.",
    EXTRACTION_POINT = "The way out. Reaching it (when it is open) gets a player out and counts as a win.",
}

local function log(message)
    print("[DYNAMIC EVENTS SIMULATION] " .. tostring(message))
end

local function now()
    return (type(getTimestampMs) == "function" and getTimestampMs()) or 0
end

local function scenario() return KIPN.Server.EventScenarioService end
local function hotspots() return KIPN.Server.EventHotspotService end
local function loop() return KIPN.Server.EventGameLoopService end

local function label(labels, key, fallback)
    return (labels or {})[key] or fallback or tostring(key)
end

local function modeText(definition)
    local mode = definition.mode and label(KIPN.Shared.EventModeLabels, definition.mode) or "Classic event"
    local variant = definition.variant and (label(KIPN.Shared.EventExtractionVariantLabels, definition.variant, nil)
        or label(KIPN.Shared.EventCaptureVariantLabels, definition.variant, nil))
    return mode .. (variant and (": " .. variant) or "")
end

local function minutes(seconds)
    local m = math.floor((tonumber(seconds) or 0) / 60)
    return m .. " minute" .. (m == 1 and "" or "s")
end

local function onlinePlayer(username)
    local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    for i = 0, (online and online:size() or 0) - 1 do
        local p = online:get(i)
        if p and p:getUsername() == username then return p end
    end
    return nil
end

local function square(point)
    local ok, sq = pcall(function() return getCell():getGridSquare(math.floor(point.x), math.floor(point.y), math.floor(point.z or 0)) end)
    return ok and sq or nil
end

local function zoneGeometry(definition)
    if not definition.zoneId or not KIPN.Server.WorldRegistry then return nil end
    local ok, zone = pcall(KIPN.Server.WorldRegistry.GetZone, definition.zoneId)
    return ok and zone and zone.geometry or nil
end

------------------------------------------------------------
-- SPAWNS (everything is tracked and removed)
------------------------------------------------------------

local function newRuntime(session, definition)
    local difficulty = definition.difficulty
    if difficulty ~= "DIRE" and difficulty ~= "BRUTAL" then difficulty = "NORMAL" end
    local participants = {}
    for username in pairs(session.viewers) do participants[username] = { username = username } end
    return {
        eventDefinitionId = definition.id,
        instanceId = "sim:" .. tostring(definition.id) .. ":" .. tostring(now()),
        simulation = true,
        participants = participants,
        difficulty = difficulty,
        directorState = { maxZombies = 60 },
        spawnedEventZombies = {},
        log = {},
    }
end

-- Lays an item on the ground at `point`, tagged so it can be found again.
function Sim.PlaceItem(session, point, fullType)
    local sq = square(point)
    if not sq or not fullType then return nil end
    local ok, item = pcall(function() return instanceItem(fullType) end)
    if not ok or not item then return nil end
    pcall(function() item:getModData()[Sim.TAG] = session.tag end)
    local placed = pcall(function() sq:AddWorldInventoryItem(item, 0.3 + ZombRand(5) / 10, 0.3 + ZombRand(5) / 10, 0) end)
    if not placed then return nil end
    session.items[#session.items + 1] = { item = item, point = { x = point.x, y = point.y, z = point.z or 0 } }
    return item
end

local function removeItems(session)
    for _, entry in ipairs(session.items) do
        pcall(function()
            local sq = square(entry.point)
            local objects = sq and sq:getWorldObjects()
            for i = (objects and objects:size() or 0) - 1, 0, -1 do
                local worldItem = objects:get(i)
                if worldItem and worldItem:getItem() == entry.item then
                    if sq.transmitRemoveItemFromSquare then sq:transmitRemoveItemFromSquare(worldItem) end
                    worldItem:removeFromWorld()
                    worldItem:removeFromSquare()
                end
            end
        end)
    end
    session.items = {}
    -- Anything a viewer picked up goes too.
    for username in pairs(session.viewers) do
        local p = onlinePlayer(username)
        local inventory = p and p:getInventory()
        local ok, items = pcall(function() return inventory:getItems() end)
        for i = (ok and items and items:size() or 0) - 1, 0, -1 do
            local item = items:get(i)
            local okTag, tag = pcall(function() return item:getModData()[Sim.TAG] end)
            if okTag and tag == session.tag then
                pcall(function()
                    inventory:Remove(item)
                    if type(sendRemoveItemFromContainer) == "function" then sendRemoveItemFromContainer(inventory, item) end
                end)
            end
        end
    end
end

function Sim.SpawnZombies(session, point, count, radius, walkTarget)
    local director = KIPN.Server.ZombieDirector
    if not director or not director.SpawnThemedZombies then return 0 end
    local ok, spawned = pcall(director.SpawnThemedZombies, session.runtime, session.definition, point,
        math.min(Sim.MAX_DEMO, count), radius or 3, walkTarget)
    return ok and tonumber(spawned) or 0
end

-- Removes everything the current step made.
function Sim.ClearStep(session)
    local runtime = session.runtime
    if KIPN.Server.ZombieDirector and KIPN.Server.ZombieDirector.CleanupRuntime then
        pcall(KIPN.Server.ZombieDirector.CleanupRuntime, runtime)
    end
    if runtime.banditState then pcall(KIPN.Server.EventBanditService.CleanupRuntime, runtime) end
    removeItems(session)
    -- Clues stay: players keep theirs for the whole event too.
    session.fires = {}
end

------------------------------------------------------------
-- MESSAGES TO THOSE WATCHING
------------------------------------------------------------

local function eachViewer(session, visit)
    for username in pairs(session.viewers) do
        local p = onlinePlayer(username)
        if p then visit(p, username) end
    end
end

local function banner(session, text, color, title)
    if not text or text == "" then return end
    eachViewer(session, function(p)
        KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_PLAYER_HUD, {
            banner = text, bannerColor = color, bannerTitle = title, bannerLong = #text > 60,
        })
    end)
end

local function moveViewers(session, point)
    if not point then return end
    eachViewer(session, function(p) KIPN.Server.EventMoveService.Player(p, { x = point.x + 0.5, y = point.y + 0.5, z = point.z or 0 }) end)
end

------------------------------------------------------------
-- STEPS
------------------------------------------------------------

local function describeHotspot(definition, hotspot)
    local text = label(KIPN.Shared.EventHotspotTypeLabels, hotspot.type)
    if hotspot.label and hotspot.label ~= "" then text = text .. " \"" .. hotspot.label .. "\"" end
    if hotspot.teamId then
        for _, team in ipairs(definition.teams or {}) do
            if team.id == hotspot.teamId then text = text .. " (" .. tostring(team.name) .. ")" end
        end
    end
    if hotspot.roundNumber then
        text = text .. (hotspot.type:find("^OLYMPIC") and (" " .. hotspot.roundNumber) or (", round " .. hotspot.roundNumber))
    end
    return text
end

local function stationFor(definition, hotspot)
    if hotspot.type ~= "OLYMPIC_STATION" then return nil end
    for _, station in ipairs(KIPN.Server.EventOlympicsService.BuildCourse(definition).stations) do
        if station.hotspot == hotspot then return station end
    end
end

-- What a hotspot step says and does.
local function hotspotStep(definition, hotspot)
    local c = hotspots().GetCenter(hotspot)
    local meta = hotspot.metadata or {}
    local lines = { HELP[hotspot.type] or "" }
    local act

    if hotspot.type == "CAPTURE_ITEM" then
        local item = (definition.captureConfig or {}).flagItemFullType
        if item and item ~= "" then
            lines[#lines + 1] = "The item (" .. item .. ") is on the ground in front of you."
            act = function(session) Sim.PlaceItem(session, c, item) end
        end
        if definition.variant == "PRISON_BREAK" then lines[#lines + 1] = "Prison Break: searching here unlocks the way out." end
    elseif hotspot.type == "NARRATIVE_LOCATION" then
        local text = meta.narrativeText or ""
        if text == "" then
            lines[#lines + 1] = "It has no text yet. Press Edit to write some."
        else
            lines[#lines + 1] = (meta.replayable ~= false) and "It's a clue: the button it adds to the screen shows it again." or "It shows once."
            act = function(session)
                local l = loop()
                if l and meta.replayable ~= false then
                    l.ShowClue(session.runtime, nil, "sim:" .. tostring(hotspot.id), meta.clueTitle or "Clue", text, true)
                else
                    banner(session, text, { 0.75, 0.6, 1.0 })
                end
            end
        end
    elseif hotspot.type == "ZOMBIE_SPAWN" then
        lines[#lines + 1] = "Here are a few of them (outlined in red), walking in the way they will."
        act = function(session) Sim.SpawnZombies(session, c, Sim.DEMO_ZOMBIES, 6, c) end
    elseif hotspot.type == "ZOMBIE_AMBUSH" then
        local count = tonumber(meta.count) or 6
        lines[#lines + 1] = count .. " zombies wait here (more on Dire and Brutal). They are shown awake now, outlined in red."
        act = function(session)
            local g = hotspot.geometry
            local radius = math.max(1, math.floor(math.min(math.abs(g.x2 - g.x1), math.abs(g.y2 - g.y1)) / 2))
            Sim.SpawnZombies(session, c, count, radius, nil)
        end
    elseif hotspot.type == "BANDIT_CAMP" or hotspot.type == "BANDIT_VEHICLE" then
        local count = tonumber(meta.count) or 4
        if hotspot.type == "BANDIT_VEHICLE" then
            lines[#lines + 1] = "The car is parked here with the crew around it."
                .. (definition.variant == "HEIST" and (" The gold (" .. KIPN.Shared.EventHeist.count .. " bars) is in the trunk; the leader carries the key.") or "")
        end
        lines[#lines + 1] = "The crew is outlined in magenta. You're invisible, so they won't start a fight."
        act = function(session)
            local B = KIPN.Server.EventBanditService
            B.InitializeRuntime(session.runtime, definition)
            -- Place just this hotspot's crew (and car), as the event will.
            B.PlaceHotspots(session.runtime, { hotspots = { hotspot }, mode = definition.mode, variant = definition.variant })
        end
    elseif hotspot.type == "OLYMPIC_STATION" then
        local station = stationFor(definition, hotspot)
        if station then
            local task = (KIPN.Shared.EventOlympicTasks or {})[station.task] or {}
            lines[#lines + 1] = "Task: " .. tostring(task.verb or station.task)
                .. (station.itemType and station.task ~= "SHOOT" and (" (" .. station.count .. " x " .. station.itemType .. ")") or "") .. "."
            if #station.kit > 0 then lines[#lines + 1] = "The kit it hands out is laid out here: " .. table.concat(station.kit, ", ") .. "." end
            act = function(session)
                for _, fullType in ipairs(station.kit) do Sim.PlaceItem(session, c, fullType) end
                if station.task == "CARRY" and station.itemType then Sim.PlaceItem(session, c, station.itemType) end
            end
        end
    elseif hotspot.type == "OLYMPIC_TARGETS" then
        act = function(session)
            local count = 3
            for _ = 1, count do
                local point = hotspots().GetRandomPointInGeometry and hotspots().GetRandomPointInGeometry(hotspot.geometry) or c
                local ok, list = pcall(function() return addZombiesInOutfit(point.x, point.y, point.z or 0, 1, nil, 50) end)
                if ok and list and list:size() > 0 then
                    local zombie = list:get(0)
                    pcall(function() zombie:setUseless(true) end)
                    table.insert(session.runtime.spawnedEventZombies, zombie)
                end
            end
        end
        lines[#lines + 1] = "A few targets stand here (outlined in red)."
    elseif hotspot.type == "EXTRACTION_POINT" then
        if definition.variant == "HEIST" then
            lines[#lines + 1] = "Only a player carrying the gold can leave here; the gold is banked as they do."
        elseif (KIPN.Shared.EventEscapeVariants or {})[definition.variant] then
            lines[#lines + 1] = "It is open from the start."
        else
            lines[#lines + 1] = "It opens when the evac arrives, near the end of the clock."
        end
    elseif hotspot.type == "HILL_LOCATION" then
        lines[#lines + 1] = "Used in round " .. tostring(hotspot.roundNumber or 1) .. "."
    end

    return {
        key = "hotspot:" .. tostring(hotspot.id), kind = "hotspot", focusId = hotspot.id, point = c,
        title = describeHotspot(definition, hotspot), text = table.concat(lines, " "), act = act,
    }
end

local ACTION_TEXT = {
    SPAWN_ZOMBIES = "zombies arrive", SPAWN_LOOT = "loot appears", PRIVATE_HINT = "a private hint",
    NARRATIVE_MESSAGE = "a message to the players", ANNOUNCEMENT = "an announcement to everyone online",
    ALARM = "an alarm sounds (not sounded here, it would draw real zombies)", ACTIVATE_OBJECTIVE = "a stage starts",
    COMPLETE_OBJECTIVE = "the story moves to the next stage", MODE_ACTION = "a game-mode action", SPAWN_BANDITS = "bandits arrive",
}

local function triggerStep(definition, stage, stageIndex, trigger, triggerIndex)
    local where
    if trigger.activationMode == "PROXIMITY" then
        for _, hotspot in ipairs(definition.hotspots or {}) do
            if hotspot.id == trigger.hotspotId then where = hotspot end
        end
    end
    local does = {}
    for _, action in ipairs(trigger.actions or {}) do
        local text = ACTION_TEXT[action.type] or tostring(action.type)
        local params = action.params or {}
        if params.text and params.text ~= "" then text = text .. ": \"" .. params.text .. "\"" end
        if params.count then text = text .. " (" .. tostring(params.count) .. ")" end
        does[#does + 1] = text
    end
    local name = (stage.name and stage.name ~= "") and stage.name or ("Stage " .. stageIndex)
    local when = where and ("When a player reaches " .. describeHotspot(definition, where)) or "When you press it in the Director panel"
    local point = where and hotspots().GetCenter(where) or nil
    return {
        key = "trigger:" .. tostring(stage.id) .. ":" .. tostring(trigger.id or triggerIndex), kind = "story",
        focusId = where and where.id or nil, point = point,
        title = "Story " .. stageIndex .. ": " .. name,
        text = when .. ": " .. table.concat(does, "; ") .. ". Playing it now, for you only.",
        act = function(session)
            local origin = point or session.origin
            for _, action in ipairs(trigger.actions or {}) do
                local params = action.params or {}
                if action.type == "SPAWN_ZOMBIES" then
                    Sim.SpawnZombies(session, origin, math.floor(tonumber(params.count) or 5), 3, origin)
                elseif action.type == "SPAWN_BANDITS" then
                    KIPN.Server.EventBanditService.Arrive(session.runtime, definition, origin, math.floor(tonumber(params.count) or 3))
                elseif action.type == "SPAWN_LOOT" then
                    for _, entry in ipairs(params.items or {}) do
                        Sim.PlaceItem(session, origin, type(entry) == "table" and (entry.itemFullType or entry.fullType) or entry)
                    end
                elseif action.type == "PRIVATE_HINT" and params.text then
                    local l = loop()
                    if l then l.ShowClue(session.runtime, nil, "sim:hint:" .. params.text, "Hint", params.text, true) end
                elseif (action.type == "NARRATIVE_MESSAGE" or action.type == "ANNOUNCEMENT") and params.text then
                    banner(session, params.text, { 1.0, 0.82, 0.3 })
                end
            end
        end,
    }
end

local function threatsStep(definition)
    local threats = definition.threats or {}
    local lines, any = {}, false
    local difficulty = definition.difficulty or "NORMAL"
    lines[#lines + 1] = "Difficulty: " .. label({ NORMAL = "Normal", DIRE = "Dire", BRUTAL = "Brutal", RANDOM = "rolled at the start (1 in 2 Dire, 1 in 4 of those Brutal)" }, difficulty) .. "."
    for _, key in ipairs(KIPN.Shared.EventThreatOrder or {}) do
        if threats[key] then
            any = true
            lines[#lines + 1] = KIPN.Shared.EventThreats[key].label .. ": " .. KIPN.Shared.EventThreats[key].help
        end
    end
    if not any then return nil end
    return {
        key = "threats", kind = "threats", title = "Threats",
        text = table.concat(lines, " ") .. " A small version plays around you now: the fire is only light, nothing burns.",
        act = function(session)
            local at = session.here or session.origin
            if threats.SIEGE then
                for _, side in ipairs({ { 0, -18 }, { 0, 18 }, { 18, 0 }, { -18, 0 } }) do
                    Sim.SpawnZombies(session, { x = at.x + side[1], y = at.y + side[2], z = at.z }, 2, 2, at)
                end
            end
            if threats.FIRES then
                session.fires[#session.fires + 1] = { x = at.x + 6, y = at.y + 4, z = at.z or 0 }
            end
            if threats.BANDITS then
                KIPN.Server.EventBanditService.Arrive(session.runtime, definition, at, 3)
            end
        end,
    }
end

local function rulesStep(definition)
    local lines = {}
    local timer = definition.timerType or "NONE"
    lines[#lines + 1] = "Clock: " .. label(KIPN.Shared.EventTimerTypeLabels, timer) .. "."
    if definition.duration and definition.duration.enabled then
        lines[#lines + 1] = "The event lasts " .. minutes(definition.duration.durationSeconds) .. "."
    end
    local rounds = tonumber(definition.maxRounds) or 1
    if rounds > 1 then
        lines[#lines + 1] = rounds .. " rounds"
            .. (definition.roundDuration and definition.roundDuration.enabled and (" of " .. minutes(definition.roundDuration.durationSeconds)) or "")
            .. ", started automatically with a short break between them."
    end
    lines[#lines + 1] = "Rules: " .. tostring(definition.ruleType or "PVE") .. "."
    if definition.mode == "EXTRACTION" and definition.variant ~= "HEIST" and not (KIPN.Shared.EventEscapeVariants or {})[definition.variant] then
        lines[#lines + 1] = "The evac arrives in the last few minutes."
    end
    return { key = "rules", kind = "rules", title = "Rounds and the clock", text = table.concat(lines, " ") }
end

local function endingStep(definition)
    local narrative = definition.narrative or {}
    local prizes = {}
    for _, row in ipairs(((definition.rewards or {}).items) or {}) do
        prizes[#prizes + 1] = tostring(row.count or 1) .. " x " .. tostring(row.itemFullType)
    end
    local text = "Winners see: \"" .. ((narrative.winText ~= nil and narrative.winText ~= "") and narrative.winText or "(no win text)")
        .. "\". Everyone else sees: \"" .. ((narrative.failText ~= nil and narrative.failText ~= "") and narrative.failText or "(no lose text)")
        .. "\". Prizes: " .. (#prizes > 0 and table.concat(prizes, ", ") or "none") .. "."
    return {
        key = "ending", kind = "ending", title = "The ending", text = text,
        act = function(session)
            if narrative.winText and narrative.winText ~= "" then banner(session, narrative.winText, { 0.45, 0.9, 0.45 }, "If they win") end
            if narrative.failText and narrative.failText ~= "" then banner(session, narrative.failText, { 1.0, 0.42, 0.42 }, "If they lose") end
        end,
    }
end

function Sim.BuildSteps(definition)
    local steps = {}
    local narrative = definition.narrative or {}
    local start
    for _, hotspotType in ipairs({ "PLAYER_SPAWN", "TEAM_SPAWN", "OLYMPIC_START" }) do
        local found = hotspots().GetHotspots(definition, hotspotType)[1]
        if found and not start then start = hotspots().GetCenter(found) end
    end
    local zone = zoneGeometry(definition)
    local zoneCenter = zone and { x = math.floor((zone.x1 + zone.x2) / 2), y = math.floor((zone.y1 + zone.y2) / 2), z = zone.z1 or 0 }

    steps[#steps + 1] = {
        key = "briefing", kind = "briefing", title = "Briefing", point = start or zoneCenter,
        text = modeText(definition) .. ". " .. ((narrative.briefing and narrative.briefing ~= "") and ("Players are told: \"" .. narrative.briefing .. "\"")
            or "There is no briefing yet, so players aren't told what to do. Press Edit to write one."),
        act = function(session)
            if narrative.briefing and narrative.briefing ~= "" then banner(session, narrative.briefing, { 1.0, 0.82, 0.3 }, definition.name) end
        end,
    }
    if zone then
        steps[#steps + 1] = {
            key = "zone", kind = "zone", title = "The event zone", point = zoneCenter,
            text = "The zone (glowing orange at its edges) is " .. (zone.x2 - zone.x1 + 1) .. " by " .. (zone.y2 - zone.y1 + 1) .. " tiles."
                .. ((definition.combatRules or {}).stayInZone and " Players who leave it are brought back." or ""),
        }
    end
    local loadout = (KIPN.Shared.EventLoadouts or {})[definition.loadout or "NONE"]
    if loadout and definition.loadout ~= "NONE" then
        steps[#steps + 1] = {
            key = "loadout", kind = "loadout", title = "Starting loadout: " .. loadout.label,
            text = loadout.summary .. (loadout.keepGear and " Players keep their own gear too." or " Their own gear is held safe until the end.")
                .. " What they get is laid out at your feet.",
            act = function(session)
                local at = session.here or session.origin
                for _, list in ipairs({ loadout.wear or {}, loadout.items or {}, { loadout.hands }, { loadout.bag } }) do
                    for _, fullType in ipairs(list) do Sim.PlaceItem(session, at, fullType) end
                end
            end,
        }
    end
    for _, hotspotType in ipairs(Sim.HOTSPOT_ORDER) do
        for _, hotspot in ipairs(hotspots().GetHotspots(definition, hotspotType)) do
            steps[#steps + 1] = hotspotStep(definition, hotspot)
        end
    end
    for stageIndex, stage in ipairs(definition.objectives or {}) do
        for triggerIndex, trigger in ipairs(stage.triggers or {}) do
            steps[#steps + 1] = triggerStep(definition, stage, stageIndex, trigger, triggerIndex)
        end
    end
    local threats = threatsStep(definition)
    if threats then steps[#steps + 1] = threats end
    steps[#steps + 1] = rulesStep(definition)
    steps[#steps + 1] = endingStep(definition)
    steps[#steps + 1] = { key = "done", kind = "done", title = "That's the whole event",
        text = "OK ends the simulation, cleans up and takes you back. Edit lets you change anything first." }
    for _, step in ipairs(steps) do step.studioStep = Sim.STUDIO_STEP[step.kind] end
    return steps
end

------------------------------------------------------------
-- PAYLOAD
------------------------------------------------------------

local function payload(session, extra)
    local step = session.steps[session.index] or {}
    local list = {}
    for _, hotspot in ipairs(hotspots().GetHotspots(session.definition, nil)) do
        local g = hotspot.geometry or {}
        list[#list + 1] = { id = hotspot.id, type = hotspot.type, x1 = g.x1, y1 = g.y1, x2 = g.x2, y2 = g.y2, z = g.z1 or 0,
            focus = hotspot.id == step.focusId }
    end
    local titles = {}
    for index, s in ipairs(session.steps) do titles[index] = s.title end
    local bandits = {}
    for _, entry in ipairs(KIPN.Server.EventBanditService.Positions(session.runtime)) do
        if entry.id then bandits[#bandits + 1] = entry.id end
    end
    local data = {
        id = session.id, name = session.definition.name, index = session.index, total = #session.steps,
        key = step.key, title = step.title, text = step.text, studioStep = step.studioStep,
        editing = session.editing, admin = session.admin, steps = titles, hotspots = list,
        zone = zoneGeometry(session.definition), fires = session.fires, bandits = bandits,
    }
    for key, value in pairs(extra or {}) do data[key] = value end
    return data
end

function Sim.Send(session, extra)
    local data = payload(session, extra)
    eachViewer(session, function(p) KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_SIMULATION, data) end)
    return data
end

------------------------------------------------------------
-- PLAYING
------------------------------------------------------------

function Sim.Play(session)
    Sim.ClearStep(session)
    local step = session.steps[session.index]
    if not step then return end
    if step.point then
        session.here = step.point
        moveViewers(session, step.point)
    end
    if step.act then
        local ok, err = pcall(step.act, session)
        if not ok then log("step " .. tostring(step.key) .. " failed: " .. tostring(err)) end
    end
    session.playedAt = now()
    Sim.Send(session)
end

function Sim.IsRunning(id)
    return Sim.sessions[id] ~= nil
end

function Sim.SessionFor(username)
    for _, session in pairs(Sim.sessions) do
        if session.viewers[username] then return session end
    end
end

-- Starts a simulation. Returns the session, or nil and a reason.
function Sim.Start(player, definition, includeStaff)
    local Status = scenario().Status
    if definition.status ~= Status.DRAFT and definition.status ~= Status.READY then return nil, "EVENT_IS_LIVE" end
    if Sim.sessions[definition.id] then return nil, "ALREADY_SIMULATING" end
    if KIPN.Server.EventControlService and KIPN.Server.EventControlService.IsPending(definition.id) then return nil, "START_PENDING" end
    local admin = player:getUsername()
    if Sim.SessionFor(admin) then return nil, "ALREADY_IN_A_SIMULATION" end
    local session = { id = definition.id, definition = definition, admin = admin, viewers = { [admin] = true }, origins = {},
        items = {}, fires = {}, index = 1, editing = false, tag = "sim:" .. tostring(definition.id) .. ":" .. tostring(now()) }
    session.invited = {}
    session.origins[admin] = { x = player:getX(), y = player:getY(), z = player:getZ() }
    session.origin = { x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()) }
    session.runtime = newRuntime(session, definition)
    session.steps = Sim.BuildSteps(definition)
    session.start = session.steps[1] and session.steps[1].point or session.origin
    Sim.sessions[definition.id] = session
    log("started " .. tostring(definition.name) .. " for " .. admin .. " (" .. #session.steps .. " steps)")
    Sim.Play(session)
    if includeStaff then Sim.InviteStaff(session) end
    return session
end

-- Asks every eligible online staff member to join. Returns how many.
function Sim.InviteStaff(session)
    local count = 0
    local online = getOnlinePlayers()
    for i = 0, (online and online:size() or 0) - 1 do
        local p = online:get(i)
        local username = p and p:getUsername()
        if username and not session.viewers[username] and not Sim.SessionFor(username)
            and KIPN.Server.EventAccessService.CanJoinSimulations(p) then
            session.invited[username] = true
            KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_SIMULATION_INVITE, {
                id = session.id, name = session.definition.name, host = session.admin, total = #session.steps,
            })
            count = count + 1
        end
    end
    session.invitedCount = count
    return count
end

local function tellHost(session, text)
    local host = onlinePlayer(session.admin)
    if host then
        KIPN.Server.SendToPlayer(host, KIPN.Shared.ResponseEvents.EVENT_ACTION_RESULT, {
            id = session.id, action = "simulationGuest", success = true, text = text,
        })
    end
end

-- An invited player's answer: OK joins (taken to the simulation), Cancel
-- opts out. Returns true if they are now in it.
function Sim.Respond(session, player, accept)
    local username = player:getUsername()
    if not session.invited[username] then return false, "NOT_INVITED" end
    session.invited[username] = nil
    if not accept then
        tellHost(session, username .. " opted out of the simulation.")
        return false, "OPTED_OUT"
    end
    if not KIPN.Server.EventAccessService.CanJoinSimulations(player) or Sim.SessionFor(username) then return false, "NOT_ALLOWED" end
    session.origins[username] = { x = player:getX(), y = player:getY(), z = player:getZ() }
    session.viewers[username] = true
    session.runtime.participants[username] = { username = username }
    local point = session.here or session.start
    if point then KIPN.Server.EventMoveService.Player(player, { x = point.x + 0.5, y = point.y + 0.5, z = point.z or 0 }) end
    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_SIMULATION, payload(session))
    tellHost(session, username .. " joined the simulation.")
    return true
end

-- A guest leaves; the simulation carries on without them.
function Sim.Leave(session, username)
    if username == session.admin or not session.viewers[username] then return false end
    local p = onlinePlayer(username)
    session.viewers[username] = nil
    session.runtime.participants[username] = nil
    if p then
        KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_SIMULATION, payload(session, { ended = true, left = true }))
        KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_PLAYER_HUD, {
            ended = true, title = tostring(session.definition.name) .. "  |  Simulation", goal = "You left the simulation.", clues = {},
        })
        local origin = session.origins[username]
        if origin then KIPN.Server.EventMoveService.Player(p, origin) end
    end
    session.origins[username] = nil
    tellHost(session, username .. " left the simulation.")
    return true
end

-- Removes everything and puts everyone back.
function Sim.Cancel(id, reason, finished)
    local session = Sim.sessions[id]
    if not session then return false end
    Sim.ClearStep(session)
    Sim.Send(session, { ended = true, finished = finished == true, reason = reason })
    eachViewer(session, function(p, username)
        local origin = session.origins[username]
        if origin then KIPN.Server.EventMoveService.Player(p, origin) end
        -- Clear the simulation's clues off the HUD.
        KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_PLAYER_HUD, {
            ended = true, title = tostring(session.definition.name) .. "  |  Simulation", goal = finished and "Simulation complete." or "Simulation cancelled.",
            clues = {},
        })
    end)
    -- Anyone still deciding: the invitation is gone.
    for username in pairs(session.invited or {}) do
        local p = onlinePlayer(username)
        if p then KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_SIMULATION_INVITE, { id = id, withdrawn = true }) end
    end
    Sim.sessions[id] = nil
    log("ended " .. tostring(id) .. ": " .. tostring(reason))
    return true
end

function Sim.Choose(session, choice)
    if choice == "OK" then
        if session.editing then return false, "EDITING" end
        if session.index >= #session.steps then
            Sim.Cancel(session.id, "Finished", true)
            return true
        end
        session.index = session.index + 1
        Sim.Play(session)
    elseif choice == "EDIT" then
        session.editing = true
        Sim.Send(session)
    elseif choice == "RESUME" then
        -- The event may have changed: rebuild and replay this step (or
        -- the nearest one if it was removed).
        local key = session.steps[session.index] and session.steps[session.index].key
        local definition = scenario().GetDefinition(session.id)
        if not definition then
            Sim.Cancel(session.id, "The event was deleted.")
            return true
        end
        session.definition = definition
        session.steps = Sim.BuildSteps(definition)
        local found
        for index, step in ipairs(session.steps) do
            if step.key == key then found = index end
        end
        session.index = math.max(1, math.min(#session.steps, found or session.index))
        session.editing = false
        Sim.Play(session)
    elseif choice == "CANCEL" then
        Sim.Cancel(session.id, "Cancelled")
    else
        return false, "UNKNOWN_CHOICE"
    end
    return true
end

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

-- Admins, and staff levels the sandbox allows (KIPN_EventAccessService.lua).
local function requireAdmin(player)
    return KIPN.Server.EventAccessService.RequireStudio(player)
end

local REASONS = {
    EVENT_IS_LIVE = "It is announced or running; cancel it first to simulate it.",
    ALREADY_SIMULATING = "A simulation of it is already running.",
    START_PENDING = "It is counting down to its start.",
    ALREADY_IN_A_SIMULATION = "You are already in a simulation.",
}

local function reply(player, id, success, text)
    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ACTION_RESULT, {
        id = id, action = "simulate", success = success == true, text = text,
    })
end

local function handleSimulate(player, args)
    if not requireAdmin(player) then return false end
    args = args or {}
    local definition = scenario().GetDefinition(args.id)
    if not definition then
        reply(player, args.id, false, "That event no longer exists.")
        return true
    end
    local session, reason = Sim.Start(player, definition, args.includeStaff == true)
    if session then
        local invited = session.invitedCount or 0
        reply(player, definition.id, true, "Simulating " .. tostring(definition.name) .. ": " .. #session.steps .. " steps"
            .. (invited > 0 and (". " .. invited .. " staff invited; they can join or opt out") or "") .. ".")
    else
        reply(player, definition.id, false, "Could not simulate: " .. (REASONS[reason] or tostring(reason)))
    end
    return true
end

local function handleSimulateStep(player, args)
    args = args or {}
    local session = Sim.sessions[args.id]
    -- A guest may only leave; the host runs the steps.
    if session and session.admin ~= player:getUsername() and session.viewers[player:getUsername()] then
        local choice = tostring(args.choice or ""):upper()
        if choice == "CANCEL" or choice == "LEAVE" then Sim.Leave(session, player:getUsername()) return true end
        reply(player, args.id, false, "Only " .. tostring(session.admin) .. " moves the simulation on. You can Leave.")
        return true
    end
    if not requireAdmin(player) then return false end
    if not session or session.admin ~= player:getUsername() then
        reply(player, args.id, false, "No simulation of yours is running for that event.")
        return true
    end
    local ok, reason = Sim.Choose(session, tostring(args.choice or ""):upper())
    if not ok then reply(player, args.id, false, reason == "EDITING" and "Press Resume when your changes are saved." or tostring(reason)) end
    return true
end

-- An invited player's OK or Cancel. Only the invitation lets them in.
local function handleRespond(player, args)
    args = args or {}
    local session = Sim.sessions[args.id]
    if not session then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_SIMULATION_INVITE, { id = args.id, withdrawn = true })
        return true
    end
    Sim.Respond(session, player, args.accept == true)
    return true
end

Sim.HOST_GRACE_MS = 60000

-- The host left: guests go back and everything is cleaned up, after a
-- minute's grace in case they reconnect. Guests who left are dropped.
function Sim.Tick()
    local t = now()
    for id, session in pairs(Sim.sessions) do
        if onlinePlayer(session.admin) then
            session.hostMissingSince = nil
        else
            session.hostMissingSince = session.hostMissingSince or t
            if t - session.hostMissingSince >= Sim.HOST_GRACE_MS then Sim.Cancel(id, "The host left.") end
        end
        if Sim.sessions[id] then
            for username in pairs(session.viewers) do
                if username ~= session.admin and not onlinePlayer(username) then
                    session.viewers[username] = nil
                    session.runtime.participants[username] = nil
                end
            end
        end
    end
end

function Sim.Initialize()
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_SIMULATE, handleSimulate)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_SIMULATE_STEP, handleSimulateStep)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_SIMULATION_RESPOND, handleRespond)
    if Events.EveryOneMinute then Events.EveryOneMinute.Add(Sim.Tick) end
    log("Initialize()")
    return true
end

return Sim
