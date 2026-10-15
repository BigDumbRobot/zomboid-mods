-- KIPN_EventOlympicsService.lua
--
-- The Olympics: a timed race over a course the admin draws.
--
-- THE GAME LOOP
--   1. Athletes sign up for a town ("country") while joining is open.
--   2. Heats of two (olympicsConfig.heatSize) are called in sign-up
--      order: both are brought to the start line, a 3-2-1 countdown
--      runs (leave the line early and you are put back: false start),
--      then GO and the clock starts.
--   3. Each athlete clears the course's stations in order -- run to a
--      checkpoint, chop logs and bring them back, craft an item from a
--      kit, carry a heavy load to a drop zone, shoot every target --
--      then crosses the finish line. Every station cleared is called
--      out with a split time; the finish time is shown to everyone.
--   4. Dying, disconnecting or running out of heat time is a DNF.
--   5. When everyone has raced, the fastest three take gold, silver
--      and bronze (the event's winners, so they get its rewards), and
--      their towns' medals are added to a table that carries over from
--      one Olympics to the next.
--
-- THE COURSE is the definition's hotspots: one OLYMPIC_START, one
-- OLYMPIC_FINISH, and OLYMPIC_STATION hotspots numbered by round
-- number, each with its task in metadata (task, itemType, count,
-- kit). A CARRY station's drop zone is the OLYMPIC_DROP with the same
-- number; a SHOOT station's range is the OLYMPIC_TARGETS with it.
--
-- FAIRNESS: an item a station asks for only counts above what the
-- athlete already carried on arrival, and the station takes what it
-- counted -- logs brought from home do not help. Kits, loads and
-- targets are the event's own and are removed after each heat.
--
-- Timing runs on its own 250 ms tick (Events.OnTick), not the
-- runtime's 5-second one, so finish times are accurate to a fraction
-- of a second.

if isClient() then return end

require "KIPN_Shared"
require "DynamicEvents_Shared"
require "KIPN_EventHotspotService"
require "KIPN_EventGameLoopService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventOlympicsService = KIPN.Server.EventOlympicsService or {}

local Olympics = KIPN.Server.EventOlympicsService

Olympics.TICK_MS = 250
Olympics.CALL_MS = 10000
Olympics.BETWEEN_HEATS_MS = 8000
Olympics.DEFAULT_HEAT_SIZE = 2
Olympics.DEFAULT_HEAT_LIMIT_SECONDS = 600
Olympics.MEDAL_DATA_KEY = "DynamicEventsOlympicMedals"
Olympics.KIT_TAG = "DE_OlympicItem"

local GOLD = { 1.0, 0.82, 0.3 }
local GREEN = { 0.45, 0.9, 0.45 }
local RED = { 1.0, 0.42, 0.42 }
local WHITE = { 0.92, 0.92, 0.92 }

local function log(message)
    print("[DYNAMIC EVENTS OLYMPICS] " .. tostring(message))
end

local function now()
    return (type(getTimestampMs) == "function" and getTimestampMs()) or 0
end

-- 2:31.4
function Olympics.FormatTime(ms)
    ms = math.max(0, math.floor(ms or 0))
    local tenths = math.floor(ms / 100)
    return string.format("%d:%02d.%d", math.floor(tenths / 600), math.floor(tenths / 10) % 60, tenths % 10)
end
local formatTime = Olympics.FormatTime

local function announce(runtime, text, color, usernames)
    KIPN.Server.EventGameLoopService.Announce(runtime, text, color, usernames)
end

local function toOne(runtime, username, text, color)
    KIPN.Server.EventGameLoopService.AnnounceTo(runtime, username, text, color)
end

local function config(definition)
    local raw = definition.olympicsConfig or {}
    return {
        heatSize = math.max(1, math.min(4, math.floor(tonumber(raw.heatSize) or Olympics.DEFAULT_HEAT_SIZE))),
        heatLimitMs = math.max(60, math.floor(tonumber(raw.heatLimitSeconds) or Olympics.DEFAULT_HEAT_LIMIT_SECONDS)) * 1000,
    }
end

------------------------------------------------------------
-- COURSE
------------------------------------------------------------

local function findNumbered(definition, hotspotType, number)
    for _, hotspot in ipairs(definition.hotspots or {}) do
        if hotspot.active ~= false and hotspot.type == hotspotType and tonumber(hotspot.roundNumber) == number then
            return hotspot
        end
    end
end

-- { start, finish, stations = { { number, hotspot, task, itemType, count, kit, drop, targets } } }
function Olympics.BuildCourse(definition)
    local course = { stations = {} }
    for _, hotspot in ipairs(definition.hotspots or {}) do
        if hotspot.active ~= false then
            if hotspot.type == "OLYMPIC_START" and not course.start then course.start = hotspot end
            if hotspot.type == "OLYMPIC_FINISH" and not course.finish then course.finish = hotspot end
            if hotspot.type == "OLYMPIC_STATION" then
                local meta = hotspot.metadata or {}
                local task = meta.task or "CHECKPOINT"
                local defaults = (KIPN.Shared.EventOlympicTasks or {})[task] or {}
                local number = tonumber(hotspot.roundNumber) or 999
                course.stations[#course.stations + 1] = {
                    number = number,
                    hotspot = hotspot,
                    task = task,
                    itemType = meta.itemType or defaults.itemType,
                    count = math.max(1, math.floor(tonumber(meta.count) or defaults.count or 1)),
                    kit = meta.kit or defaults.kit or {},
                    drop = findNumbered(definition, "OLYMPIC_DROP", number),
                    targets = findNumbered(definition, "OLYMPIC_TARGETS", number),
                }
            end
        end
    end
    table.sort(course.stations, function(a, b) return a.number < b.number end)
    return course
end

-- Server validation failures for an OLYMPICS definition.
function Olympics.ValidateDefinition(definition)
    local failures = {}
    local course = Olympics.BuildCourse(definition)
    if not course.start then failures[#failures + 1] = "OLYMPICS_START_REQUIRED" end
    if not course.finish then failures[#failures + 1] = "OLYMPICS_FINISH_REQUIRED" end
    for _, station in ipairs(course.stations) do
        if station.task == "CARRY" and not station.drop then failures[#failures + 1] = "OLYMPICS_DROP_REQUIRED" end
        if station.task == "SHOOT" and not station.targets then failures[#failures + 1] = "OLYMPICS_TARGETS_REQUIRED" end
        if (station.task == "CHOP" or station.task == "CRAFT" or station.task == "CARRY")
            and (type(station.itemType) ~= "string" or station.itemType == "") then
            failures[#failures + 1] = "OLYMPICS_STATION_ITEM_REQUIRED"
        end
    end
    log("ValidateDefinition() -> " .. tostring(#failures == 0) .. " failures=" .. table.concat(failures, ","))
    return #failures == 0, failures
end

local function center(hotspot) return KIPN.Server.EventHotspotService.GetCenter(hotspot) end

local function inside(player, hotspot)
    if not hotspot then return false end
    return KIPN.Server.EventHotspotService.IsPositionInHotspot(player:getX(), player:getY(), player:getZ(), hotspot)
end

------------------------------------------------------------
-- ITEMS, LOADS AND TARGETS
------------------------------------------------------------

local function eachItem(inventory, fn)
    local ok, items = pcall(function() return inventory:getItems() end)
    if not ok or not items then return end
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        if item then
            fn(item, inventory)
            local nestedOk, nested = pcall(function() return item:getInventory() end)
            if nestedOk and nested then eachItem(nested, fn) end
        end
    end
end

local function countType(player, fullType)
    local count = 0
    eachItem(player:getInventory(), function(item)
        if item:getFullType() == fullType then count = count + 1 end
    end)
    return count
end

local function removeItem(player, item, container)
    pcall(function()
        if player:getPrimaryHandItem() == item or player:getSecondaryHandItem() == item then player:removeFromHands(item) end
        if player:isEquipped(item) then player:removeWornItem(item) end
    end)
    pcall(function()
        container:Remove(item)
        if type(sendRemoveItemFromContainer) == "function" then sendRemoveItemFromContainer(container, item) end
    end)
end

local function takeType(player, fullType, count)
    local taken = 0
    eachItem(player:getInventory(), function(item, container)
        if taken < count and item:getFullType() == fullType then
            removeItem(player, item, container)
            taken = taken + 1
        end
    end)
    return taken
end

local function tag(item, value)
    pcall(function() item:getModData()[Olympics.KIT_TAG] = value end)
end

local function tagOf(item)
    local ok, value = pcall(function() return item:getModData()[Olympics.KIT_TAG] end)
    return ok and value or nil
end

local function giveKit(runtime, player, kit)
    local inventory = player:getInventory()
    for _, fullType in ipairs(kit or {}) do
        local item = KIPN.Server.CreateItem(fullType)
        if item then
            tag(item, runtime.instanceId)
            inventory:AddItem(item)
            if type(sendAddItemToContainer) == "function" then pcall(sendAddItemToContainer, inventory, item) end
        else
            log("giveKit() -> unknown item " .. tostring(fullType))
        end
    end
end

-- Removes everything this event handed the athlete.
local function takeKit(runtime, player)
    eachItem(player:getInventory(), function(item, container)
        if tagOf(item) == runtime.instanceId then removeItem(player, item, container) end
    end)
end

local function carryingTagged(player, value)
    local found = false
    eachItem(player:getInventory(), function(item) if tagOf(item) == value then found = true end end)
    return found
end

local function squareIn(hotspot)
    local point = KIPN.Server.EventHotspotService.GetRandomPointInGeometry(hotspot.geometry) or center(hotspot)
    local ok, square = pcall(function() return getCell():getGridSquare(point.x, point.y, point.z or 0) end)
    return ok and square or nil, point
end

local function spawnLoad(runtime, station, username)
    local square, point = squareIn(station.hotspot)
    local item = square and KIPN.Server.CreateItem(station.itemType)
    if not item then return nil end
    local value = runtime.instanceId .. ":load:" .. username .. ":" .. station.number
    tag(item, value)
    pcall(function() square:AddWorldInventoryItem(item, 0.5, 0.5, 0) end)
    return { value = value, item = item, point = point }
end

-- Removes a load wherever it ended up: someone's inventory or the ground.
local function removeLoad(cargo)
    if not cargo then return end
    local online = getOnlinePlayers()
    for i = 0, (online and online:size() or 0) - 1 do
        local p = online:get(i)
        eachItem(p:getInventory(), function(item, container)
            if tagOf(item) == cargo.value then removeItem(p, item, container) end
        end)
    end
    pcall(function()
        local square = getCell():getGridSquare(cargo.point.x, cargo.point.y, cargo.point.z or 0)
        local objects = square and square:getWorldObjects()
        for i = (objects and objects:size() or 0) - 1, 0, -1 do
            local worldItem = objects:get(i)
            if worldItem and tagOf(worldItem:getItem()) == cargo.value then
                if square.transmitRemoveItemFromSquare then square:transmitRemoveItemFromSquare(worldItem) end
                worldItem:removeFromWorld()
                worldItem:removeFromSquare()
            end
        end
    end)
end

local function spawnTargets(station, count)
    local targets = {}
    for _ = 1, count do
        local _, point = squareIn(station.targets)
        local ok, list = pcall(function() return addZombiesInOutfit(point.x, point.y, point.z or 0, 1, nil, 50) end)
        if ok and list and list:size() > 0 then targets[#targets + 1] = list:get(0) end
    end
    return targets
end

local function targetsLeft(targets)
    local left = 0
    for _, zombie in ipairs(targets or {}) do
        local ok, dead = pcall(function() return zombie:isDead() or zombie:getCurrentSquare() == nil end)
        if ok and not dead then left = left + 1 end
    end
    return left
end

local function removeTargets(targets)
    for _, zombie in ipairs(targets or {}) do
        pcall(function()
            if not zombie:isDead() then
                zombie:removeFromWorld()
                zombie:removeFromSquare()
            end
        end)
    end
end

------------------------------------------------------------
-- RACERS
------------------------------------------------------------

function Olympics.InitializeRuntime(runtime, definition)
    runtime.olympicsState = {
        racers = {},
        order = {},
        heatNumber = 0,
        heat = nil,
        nextHeatAtMs = nil,
        course = Olympics.BuildCourse(definition),
    }
    log("InitializeRuntime() -> " .. #runtime.olympicsState.course.stations .. " stations")
end

-- Called when an athlete is brought into the event.
function Olympics.AddRacer(runtime, definition, username)
    local state = runtime.olympicsState
    if not state or state.racers[username] then return end
    local country = (definition.olympicsCountries or {})[username] or "Independent"
    state.racers[username] = { username = username, country = country, status = "WAITING" }
    state.order[#state.order + 1] = username
    toOne(runtime, username, "Welcome, " .. username .. " of " .. country .. "! Wait here until your heat is called.", GOLD)
end

local function onlinePlayer(username)
    local online = getOnlinePlayers()
    for i = 0, (online and online:size() or 0) - 1 do
        local p = online:get(i)
        if p and p:getUsername() == username then return p end
    end
end

local function alive(runtime, username)
    local p = onlinePlayer(username)
    if not p or (runtime.deaths and runtime.deaths[username]) then return nil end
    local ok, dead = pcall(function() return p:isDead() end)
    return (ok and not dead) and p or nil
end

local function teleport(p, point)
    pcall(KIPN.Server.EventMoveService.Player, p, point)
end

local function describe(racer)
    return racer.username .. " (" .. racer.country .. ")"
end

local function stationText(station, index, total)
    local task = (KIPN.Shared.EventOlympicTasks or {})[station.task] or {}
    local text = "Station " .. index .. " of " .. total .. ": " .. (task.label or station.task)
    if station.task == "CHOP" or station.task == "CRAFT" then
        text = text .. ". Bring " .. station.count .. " x " .. tostring(station.itemType) .. " back here."
    elseif station.task == "CARRY" then
        text = text .. ". Pick up the load and carry it to the drop zone."
    elseif station.task == "SHOOT" then
        text = text .. ". Take down all " .. station.count .. " targets."
    end
    return text
end

------------------------------------------------------------
-- HEATS
------------------------------------------------------------

local function callNextHeat(runtime, definition, state)
    local size = config(definition).heatSize
    local chosen = {}
    for _, username in ipairs(state.order) do
        local racer = state.racers[username]
        if racer.status == "WAITING" and #chosen < size and alive(runtime, username) then chosen[#chosen + 1] = racer end
    end
    if #chosen == 0 then return false end

    state.heatNumber = state.heatNumber + 1
    local heat = { number = state.heatNumber, racers = {}, phase = "CALLING", phaseAtMs = now() + Olympics.CALL_MS, progress = {} }
    local names = {}
    for _, racer in ipairs(chosen) do
        racer.status = "CALLED"
        racer.heat = heat.number
        heat.racers[#heat.racers + 1] = racer.username
        heat.progress[racer.username] = { index = 1 }
        names[#names + 1] = describe(racer)
        local p = alive(runtime, racer.username)
        local point = KIPN.Server.EventHotspotService.GetRandomPointInGeometry(state.course.start.geometry) or center(state.course.start)
        if p and point then teleport(p, point) end
        toOne(runtime, racer.username, "You're up! Stay on the start line.", GOLD)
    end
    state.heat = heat
    announce(runtime, "Heat " .. heat.number .. ": " .. table.concat(names, " vs "), GOLD)
    return true
end

local function finishRacer(runtime, state, racer, status, timeMs, reason)
    racer.status, racer.timeMs = status, timeMs
    local progress = state.heat and state.heat.progress[racer.username] or {}
    local p = onlinePlayer(racer.username)
    if p then takeKit(runtime, p) end
    removeLoad(progress.load)
    removeTargets(progress.targets)
    if status == "FINISHED" then
        local place = 1
        for _, other in pairs(state.racers) do
            if other.status == "FINISHED" and other ~= racer and other.timeMs < timeMs then place = place + 1 end
        end
        announce(runtime, describe(racer) .. " finishes in " .. formatTime(timeMs) .. "! (" .. place .. Olympics.Ordinal(place) .. " so far)", GREEN)
    else
        announce(runtime, describe(racer) .. " did not finish: " .. tostring(reason), RED)
    end
end

function Olympics.Ordinal(n)
    local last, lastTwo = n % 10, n % 100
    if lastTwo >= 11 and lastTwo <= 13 then return "th" end
    return last == 1 and "st" or last == 2 and "nd" or last == 3 and "rd" or "th"
end

-- One athlete's progress through the course while the clock runs.
local function runRacer(runtime, definition, state, heat, racer)
    local p = alive(runtime, racer.username)
    local elapsed = now() - heat.startedAtMs
    if not p then return finishRacer(runtime, state, racer, "DNF", nil, "out of the race") end
    if elapsed > config(definition).heatLimitMs then return finishRacer(runtime, state, racer, "DNF", nil, "ran out of time") end

    local course = state.course
    local progress = heat.progress[racer.username]
    local station = course.stations[progress.index]

    if not station then
        if inside(p, course.finish) then finishRacer(runtime, state, racer, "FINISHED", elapsed) end
        return
    end

    -- Arriving at a station hands out what it needs.
    if not progress.arrived and inside(p, station.hotspot) then
        progress.arrived = true
        if station.task == "CHOP" or station.task == "CRAFT" then
            progress.baseline = countType(p, station.itemType)
            giveKit(runtime, p, station.kit)
        elseif station.task == "CARRY" then
            progress.load = spawnLoad(runtime, station, racer.username)
        elseif station.task == "SHOOT" then
            giveKit(runtime, p, station.kit)
            progress.targets = spawnTargets(station, station.count)
        end
        if station.task ~= "CHECKPOINT" then
            toOne(runtime, racer.username, stationText(station, progress.index, #course.stations), WHITE)
        end
    end

    local done = false
    if station.task == "CHECKPOINT" then
        done = progress.arrived
    elseif (station.task == "CHOP" or station.task == "CRAFT") and progress.arrived and inside(p, station.hotspot) then
        if countType(p, station.itemType) - (progress.baseline or 0) >= station.count then
            takeType(p, station.itemType, station.count)
            done = true
        end
    elseif station.task == "CARRY" and progress.load then
        done = carryingTagged(p, progress.load.value) and inside(p, station.drop)
        if done then removeLoad(progress.load); progress.load = nil end
    elseif station.task == "SHOOT" and progress.targets then
        done = targetsLeft(progress.targets) == 0
    end

    if done then
        progress.index = progress.index + 1
        progress.arrived, progress.baseline, progress.targets = false, nil, nil
        local nextStation = course.stations[progress.index]
        announce(runtime, racer.username .. " clears station " .. (progress.index - 1) .. " in " .. formatTime(elapsed), WHITE)
        toOne(runtime, racer.username, nextStation and ("Next: " .. stationText(nextStation, progress.index, #course.stations))
            or "Last stretch: run for the finish line!", GOLD)
        KIPN.Server.EventGameLoopService.RefreshHud(runtime, definition, racer.username)
    end
end

function Olympics.FastTick(runtime, definition)
    local state = runtime.olympicsState
    if not state or state.done then return end
    local t = now()
    local heat = state.heat

    if not heat then
        if state.nextHeatAtMs and t < state.nextHeatAtMs then return end
        state.nextHeatAtMs = nil
        if not callNextHeat(runtime, definition, state) then
            -- Nobody left who can race (everyone ran, or the rest are
            -- offline or down): the Games are over.
            if state.heatNumber > 0 or #state.order > 0 then state.done = true end
        end
        return
    end

    if heat.phase == "CALLING" then
        -- Hold the line: anyone who steps off before GO is put back.
        for _, username in ipairs(heat.racers) do
            local p = alive(runtime, username)
            if p and not inside(p, state.course.start) and t > heat.phaseAtMs - Olympics.CALL_MS + 3000 then
                teleport(p, center(state.course.start))
                toOne(runtime, username, "False start! Back to the line.", RED)
            end
        end
        if t >= heat.phaseAtMs then
            heat.phase, heat.count, heat.phaseAtMs = "COUNTDOWN", 3, t
        end
    elseif heat.phase == "COUNTDOWN" then
        if t >= heat.phaseAtMs then
            local set = {}
            for _, username in ipairs(heat.racers) do set[username] = true end
            if heat.count > 0 then
                announce(runtime, tostring(heat.count) .. "...", GOLD, set)
                heat.count, heat.phaseAtMs = heat.count - 1, t + 1000
            else
                heat.phase, heat.startedAtMs = "RUNNING", t
                for _, username in ipairs(heat.racers) do state.racers[username].status = "RACING" end
                announce(runtime, "GO!", GREEN, set)
                announce(runtime, "Heat " .. heat.number .. " is off!", GOLD)
                local first = state.course.stations[1]
                for username in pairs(set) do
                    toOne(runtime, username, first and ("Go! " .. stationText(first, 1, #state.course.stations)) or "Go! Run for the finish line!", GREEN)
                end
            end
        end
    elseif heat.phase == "RUNNING" then
        local racing = false
        for _, username in ipairs(heat.racers) do
            local racer = state.racers[username]
            if racer.status == "RACING" then
                runRacer(runtime, definition, state, heat, racer)
                racing = racing or racer.status == "RACING"
            end
        end
        if not racing then
            state.heat = nil
            state.nextHeatAtMs = t + Olympics.BETWEEN_HEATS_MS
            local podium = Olympics.Standings(state)
            local lines = {}
            for index = 1, math.min(3, #podium) do
                lines[#lines + 1] = index .. ". " .. podium[index].username .. " " .. formatTime(podium[index].timeMs)
            end
            if #lines > 0 then announce(runtime, "Standings: " .. table.concat(lines, "   "), GOLD) end
        end
    end
end

-- Finished athletes, fastest first.
function Olympics.Standings(state)
    local list = {}
    for _, racer in pairs(state.racers) do
        if racer.status == "FINISHED" then list[#list + 1] = racer end
    end
    table.sort(list, function(a, b) return a.timeMs < b.timeMs end)
    return list
end

------------------------------------------------------------
-- MEDALS AND THE END
------------------------------------------------------------

local function medalTable()
    local ok, data = pcall(function() return ModData.getOrCreate(Olympics.MEDAL_DATA_KEY) end)
    return ok and data or {}
end

-- The Games end once nobody is left to race. Awards medals, sets the
-- podium as the event's winners, and adds the medals to the table.
function Olympics.CheckEnd(runtime, _definition)
    local state = runtime.olympicsState
    if not state or not state.done then return false end
    if state.medalsAwarded then return true end
    state.medalsAwarded = true

    local standings = Olympics.Standings(state)
    local medals = { "gold", "silver", "bronze" }
    local table_ = medalTable()
    runtime.winners = {}
    state.podium = {}
    local place = 0
    local lastTime
    for index, racer in ipairs(standings) do
        -- Equal times share a place.
        if racer.timeMs ~= lastTime then place = index end
        lastTime = racer.timeMs
        local medal = medals[place]
        if not medal then break end
        racer.medal = medal
        runtime.winners[racer.username] = runtime.participants[racer.username] or true
        state.podium[#state.podium + 1] = racer
        local row = table_[racer.country] or { gold = 0, silver = 0, bronze = 0 }
        row[medal] = (row[medal] or 0) + 1
        table_[racer.country] = row
    end
    return true
end

-- Towns by golds, then silvers, then bronzes.
function Olympics.MedalTable()
    local rows = {}
    for country, row in pairs(medalTable()) do
        rows[#rows + 1] = { country = country, gold = row.gold or 0, silver = row.silver or 0, bronze = row.bronze or 0 }
    end
    table.sort(rows, function(a, b)
        if a.gold ~= b.gold then return a.gold > b.gold end
        if a.silver ~= b.silver then return a.silver > b.silver end
        return a.bronze > b.bronze
    end)
    return rows
end

function Olympics.ResultText(runtime)
    local state = runtime.olympicsState
    if not state or not state.podium or #state.podium == 0 then return "Nobody finished the course.", RED end
    local parts = {}
    for _, racer in ipairs(state.podium) do
        parts[#parts + 1] = racer.medal:upper() .. " " .. describe(racer) .. " " .. formatTime(racer.timeMs)
    end
    return table.concat(parts, "   "), GOLD
end

function Olympics.CleanupRuntime(runtime)
    local state = runtime.olympicsState
    if not state or not state.heat then return end
    for _, username in ipairs(state.heat.racers) do
        local progress = state.heat.progress[username] or {}
        local p = onlinePlayer(username)
        if p then takeKit(runtime, p) end
        removeLoad(progress.load)
        removeTargets(progress.targets)
    end
    state.heat = nil
end

------------------------------------------------------------
-- HUD
------------------------------------------------------------

function Olympics.BuildHud(runtime, definition, username, hud)
    local state = runtime.olympicsState
    if not state then return end
    local racer = state.racers[username]
    local heat = state.heat
    local course = state.course
    local line = function(text) hud.lines[#hud.lines + 1] = text end
    if racer then hud.teamName = racer.country end

    if racer and heat and heat.progress[username] and (racer.status == "CALLED" or racer.status == "RACING") then
        if heat.phase ~= "RUNNING" then
            hud.goal = "Heat " .. heat.number .. ": stay on the start line. GO is coming!"
            local c = center(course.start)
            hud.target = { x = c.x, y = c.y, label = "Start line" }
        else
            local progress = heat.progress[username]
            local station = course.stations[progress.index]
            hud.stopwatchMs = now() - heat.startedAtMs
            hud.limitLeftMs = math.max(0, config(definition).heatLimitMs - hud.stopwatchMs)
            if station then
                hud.goal = stationText(station, progress.index, #course.stations)
                local where = station.hotspot
                if station.task == "CARRY" and progress.load and carryingTagged(onlinePlayer(username) or {}, progress.load.value) then where = station.drop end
                if station.task == "SHOOT" and progress.arrived then where = station.targets end
                local c = center(where)
                hud.target = { x = c.x, y = c.y, label = "Station " .. progress.index }
                if station.task == "SHOOT" and progress.targets then line(targetsLeft(progress.targets) .. " targets left") end
            else
                hud.goal = "Run for the finish line!"
                local c = center(course.finish)
                hud.target = { x = c.x, y = c.y, label = "Finish" }
            end
        end
        for _, other in ipairs(heat.racers) do
            if other ~= username then
                local otherProgress = heat.progress[other]
                line("vs " .. other .. ": " .. (state.racers[other].status == "RACING" and ("station " .. otherProgress.index) or state.racers[other].status:lower()))
            end
        end
    elseif racer and racer.status == "FINISHED" then
        hud.goal = "You finished in " .. formatTime(racer.timeMs) .. ". Cheer on the others!"
    elseif racer and racer.status == "DNF" then
        hud.goal = "You did not finish this time. Cheer on the others!"
    elseif racer then
        local ahead = 0
        for _, name in ipairs(state.order) do
            if name == username then break end
            if state.racers[name].status == "WAITING" then ahead = ahead + 1 end
        end
        hud.goal = "Wait for your heat. " .. (ahead == 0 and "You're up next!" or (ahead .. " athletes before you."))
    else
        hud.goal = "Watch the Games."
    end

    if heat and heat.phase == "RUNNING" then
        line("Now racing: heat " .. heat.number .. " (" .. table.concat(heat.racers, " vs ") .. ")")
    end
    local standings = Olympics.Standings(state)
    for index = 1, math.min(3, #standings) do
        line(index .. ". " .. standings[index].username .. " (" .. standings[index].country .. ") " .. formatTime(standings[index].timeMs))
    end
end

------------------------------------------------------------
-- TICK
------------------------------------------------------------

local lastTickMs = 0

local function onTick()
    local t = now()
    if t - lastTickMs < Olympics.TICK_MS then return end
    lastTickMs = t
    local runtimes = KIPN.Server.EventRuntimeService and KIPN.Server.EventRuntimeService.ActiveRuntimes or {}
    for definitionId, runtime in pairs(runtimes) do
        if runtime.olympicsState then
            local definition = KIPN.Server.EventScenarioService.GetDefinition(definitionId)
            if definition then
                local ok, err = pcall(Olympics.FastTick, runtime, definition)
                if not ok then log("FastTick failed: " .. tostring(err)) end
            end
        end
    end
end

function Olympics.Initialize()
    Events.OnTick.Add(onTick)
    log("Initialize()")
    return true
end

log("module loaded")
