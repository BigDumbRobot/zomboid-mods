require "LilBubbyShowcase"
require "LilBubbyTeleport"
require "DynamicEventsTest_World"

-- Dynamic Events suite, client half: the test flows (coroutines), the menu,
-- and what your own game receives from Dynamic Events (the sign-up prompt,
-- the HUD, the loadout). Events are made and read by the server ops in
-- DynamicEventsTest_World.lua; this file walks you where each test needs you
-- (the client owns its position) and checks what you see.
local T = DynamicEventsTest
local MODULE = T.MODULE
local ID = "events"
local results, replies = {}, {}
local runner, nextRequest = nil, 0
local seen = { invites = {}, joins = {}, loadouts = {}, banners = {}, says = {}, moves = {} }

local function show(playerNum, text)
    results[playerNum] = text
    LilBubbyShowcase.ReportIndex(playerNum, ID, text)
end

local function progress(player, text)
    LilBubbyShowcase.Report(player, ID, text, true)
end

local function waitFor(ms, fn, what)
    local deadline = getTimestampMs() + ms
    local previous = LilBubbyStatus and LilBubbyStatus.notes[0]
    if what and LilBubbyStatus then LilBubbyStatus.Note(0, what) end
    local value
    while true do
        value = fn()
        if value or getTimestampMs() > deadline then break end
        coroutine.yield()
    end
    if what and LilBubbyStatus then LilBubbyStatus.notes[0] = previous end
    return value or nil
end

local function pause(ms, what) waitFor(ms, function() return nil end, what) end

-- Runs a World op where events run and returns its reply.
local function op(player, name, args)
    args = args or {}
    if not isClient() then
        local ok, result = pcall(T.World[name], player, args)
        return ok and (result or {}) or { error = tostring(result) }
    end
    nextRequest = nextRequest + 1
    args.requestId = nextRequest
    local request = nextRequest
    sendClientCommand(player, MODULE, name, args)
    local reply = waitFor(30000, function() return replies[request] end, "Waiting for the server")
    replies[request] = nil
    return reply or { error = "no reply from the server in 30 s" }
end

local function state(player, id) return op(player, "state", { id = id }) end

-- Polls the event's state until fn(state) is true.
local function waitState(player, id, ms, fn, what)
    local last
    local value = waitFor(ms, function()
        last = state(player, id)
        return fn(last) and last or nil
    end, what)
    return value, last
end

local function here(player)
    return { x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()) }
end

-- Walks you there with the tester's own travel (hops on servers with the
-- speed anti-cheat), then waits to arrive.
local function travel(player, point)
    if not point then return false end
    LilBubbyTeleport.Travel(player, { x = point.x, y = point.y, z = point.z or 0, hop = isClient() and LilBubbyTeleport.HOP or nil })
    local tiles = T.Distance(player:getX(), player:getY(), point.x, point.y)
    return waitFor(math.ceil(tiles / LilBubbyTeleport.HOP) * LilBubbyTeleport.HOP_MS + LilBubbyTeleport.SETTLE_MS,
        function() return LilBubbyTeleport.Arrived(player, point.x, point.y, point.z or 0) end, "Moving you") ~= nil
end

local function hud()
    return KIPN_EventPlayerHUD and KIPN_EventPlayerHUD.instance
end

local function hudGoal()
    local h = hud()
    return h and h.hud and h.hud.goal or ""
end

local function has(list, value)
    for _, v in ipairs(list or {}) do if v == value then return true end end
    return false
end

-- Runs fn in its own coroutine so an error ends the step, not the flow
-- (Kahlua cannot yield inside pcall).
local function protected(fn, ...)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co, ...)
    while ok and coroutine.status(co) ~= "dead" do
        coroutine.yield()
        ok, err = coroutine.resume(co)
    end
    return ok, err
end

-- Builds a test event around you, runs `body(report, setup)`, then stops it,
-- cleans up and brings you back.
local function eventFlow(player, title, kind, opts, body, keepVisible)
    local report = T.newReport(title)
    local origin = here(player)
    local invisible = player:isInvisible()
    if not keepVisible then player:setInvisible(true) end
    local args = { kind = kind }
    for key, value in pairs(opts or {}) do args[key] = value end
    progress(player, title .. ": setting up a test event around you")
    local setup = op(player, "setup", args)
    report:merge(setup.lines)
    if setup.error then
        report:blocked("Test event made and started", setup.error)
    else
        report:check("Test event made" .. (opts and opts.draft and "" or " and started"), setup.id ~= nil, setup.id)
        if setup.joinedAt and not (opts and opts.draft) then
            -- The client owns its position in multiplayer: Dynamic Events asks
            -- your client to move you, so check it arrived.
            local moved = waitFor(4000, function()
                return T.Distance(player:getX(), player:getY(), setup.joinedAt.x, setup.joinedAt.y) < 3 or nil
            end)
            report:check("Joining moved you to the event", moved ~= nil or T.Distance(origin.x, origin.y, setup.joinedAt.x, setup.joinedAt.y) < 3,
                string.format("server says %d,%d; you are at %d,%d", setup.joinedAt.x, setup.joinedAt.y,
                    math.floor(player:getX()), math.floor(player:getY())))
        end
        local ok, err = protected(body, report, setup)
        if not ok then report:error("Test step crashed", err) end
    end
    local cleaned = op(player, "cleanup")
    report:info("Cleaned up", (cleaned.events or 0) .. " test event(s), " .. (cleaned.items or 0) .. " item(s)")
    travel(player, origin)
    player:setInvisible(invisible)
    return report
end

local function won(report, s, player)
    report:check("The event ended in a win", s and s.outcome == "WIN", s and s.outcome)
    report:check("You are the winner", s and has(s.winners, player:getUsername()), s and table.concat(s.winners or {}, ", "))
end

------------------------------------------------------------
-- SETUP AND ONE-SHOT CHECKS
------------------------------------------------------------

local function checkFlow(name, title)
    return function(player)
        local report = T.newReport(title)
        local reply = op(player, "check", { name = name })
        if reply.error then report:blocked(title, reply.error) else report:merge(reply.lines) end
        return report
    end
end

------------------------------------------------------------
-- EVENT STUDIO
------------------------------------------------------------

local function studioLogicFlow(player)
    local report = T.newReport("Event Studio logic")
    local S = KIPN_EventStudio
    if not report:check("The Studio is loaded", S ~= nil) then return report end
    for _, mode in ipairs(S.ModeKeys()) do
        local d = S.NewDraft({ id = "t", name = "Test", status = "DRAFT", zoneId = "z" })
        local message = S.ApplyMode(d, mode)
        local issues = S.Check(d)
        local payload = S.Payload(d)
        report:check(S.ModeLabel(mode) .. ": defaults apply and save", message ~= nil and payload.name == "Test"
            and (mode == S.CUSTOM and payload.mode == "NONE" or payload.mode == mode), #issues .. " checklist item(s)")
        -- Adventure's rolled game brings its own clock; the Olympics ends when every heat has run.
        local ends = d.timerType ~= "NONE" or d.duration.enabled or S.UsesRounds(mode) or mode == "OLYMPICS"
            or mode == "ADVENTURE" or mode == S.CUSTOM
        report:check(S.ModeLabel(mode) .. ": has a way to end", ends, d.timerType)
    end
    local a, b = S.NewDraft({ id = "x", name = "Same", status = "DRAFT" }), S.NewDraft({ id = "x", name = "Same", status = "DRAFT" })
    report:check("Unchanged drafts are not 'unsaved'", S.Signature(a) == S.Signature(b))
    report:check("Server reasons are explained in words", S.Explain("NO_ZONE"):find("zone", 1, true) ~= nil, S.Explain("NO_ZONE"))
    local games = S.NewDraft({ id = "g", name = "G", status = "DRAFT" })
    S.ApplyMode(games, "OLYMPICS")
    local need = S.NextHotspotNeeded(games)
    report:check("The Olympics course starts with the start line", need and need.type == "OLYMPIC_START", need and need.type)
    return report
end

local function studioWindowFlow(player)
    local report = T.newReport("Event Studio window")
    local W, S = KIPN_EventStudioUI, KIPN_EventStudio
    if not report:check("The Studio window is loaded", W ~= nil and S ~= nil) then return report end
    local studio = W.Open()
    report:check("It opens", studio ~= nil and studio.isOpen)
    pause(1500)
    -- A preview event that exists only in this window: stepping through it
    -- never saves (it rebuilds directly rather than changing step).
    local fake = { id = "lilbubby_preview", name = T.PREFIX .. "preview", status = "DRAFT", eventType = "HORDE_SURVIVAL", hotspots = {}, teams = {}, participants = {} }
    table.insert(studio.definitions, fake)
    studio.selectedId = fake.id
    studio.drafts[fake.id] = S.NewDraft(fake)
    for _, mode in ipairs(S.ModeKeys()) do
        S.ApplyMode(studio.drafts[fake.id], mode)
        for index, step in ipairs(S.Steps) do
            studio.step = index
            local ok, err = pcall(function() studio:rebuild(true) end)
            if not ok or #studio.formWidgets == 0 then
                report:check(S.ModeLabel(mode) .. " / " .. step.title .. " builds", false, err or "empty")
            end
            coroutine.yield()
        end
        report:check(S.ModeLabel(mode) .. ": all " .. #S.Steps .. " steps build", true)
    end
    for index, def in ipairs(studio.definitions) do
        if def == fake then table.remove(studio.definitions, index) end
    end
    studio.drafts[fake.id], studio.selectedId = nil, nil
    studio:rebuild(true)
    studio:close()
    report:check("It closes", not studio.isOpen)
    return report
end

local function classicsFlow(player)
    local report = T.newReport("Classic scenarios in the Studio")
    local S = KIPN_EventStudio
    local Shared = KIPN.Shared
    if not report:check("The Studio is loaded", S ~= nil) then return report end
    for _, id in ipairs(Shared.EventClassicScenarioOrder or {}) do
        local template = Shared.EventClassicScenarios[id]
        local d = S.NewDraft({ id = id, name = "New Event", status = "DRAFT" })
        S.ApplyScenario(d, id)
        local spots = S.VenueHotspots(template)
        report:check(template.label .. ": mode, loadout and briefing applied", d.mode == template.mode and d.loadout == template.loadout
            and d.narrative.briefing == template.briefing, d.mode .. " / " .. d.loadout)
        if template.venue then
            report:check(template.label .. ": original location has hotspots", #spots > 0, #spots .. " hotspot(s)")
        else
            -- No original location: the checklist asks for its places.
            local need = S.NextHotspotNeeded(d)
            report:check(template.label .. ": asks for the places it needs", need ~= nil, need and need.type or "nothing")
        end
    end
    return report
end

------------------------------------------------------------
-- RUNNING EVENTS
------------------------------------------------------------

local function lifecycleFlow(player)
    return eventFlow(player, "Event lifecycle", "survivor", { draft = true, zone = true, seconds = 60 }, function(report, setup)
        local id = setup.id
        local function step(command, expected, label)
            local r = op(player, "act", { id = id, what = "call", command = command })
            report:check(label, r.status == expected, (r.status or "?") .. (r.reason and (" | " .. r.reason) or ""))
            return r
        end
        step("EVENT_VALIDATE", "READY", "Check and mark ready: Ready")
        step("EVENT_ANNOUNCE", "ANNOUNCED", "Announce: Announced (everyone online saw the briefing)")
        local invitesBefore = #seen.invites
        step("EVENT_OPEN_JOINING", "JOINING", "Open joining: Joining")
        local invite = waitFor(8000, function() return #seen.invites > invitesBefore and seen.invites[#seen.invites] or nil end)
        report:check("You were asked to sign up", invite and invite.kind == "SIGN_UP", invite and invite.kind)
        report:info("A join prompt window opened", "the test answers it for you; close the window afterwards")
        local joinsBefore = #seen.joins
        sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_ACCEPT_PARTICIPATION, { id = id })
        local join = waitFor(8000, function() return #seen.joins > joinsBefore and seen.joins[#seen.joins] or nil end)
        report:check("Signing up puts you on the roster", join and join.success and join.reason == "SIGNED_UP", join and join.reason)
        local started = step("EVENT_START", "ACTIVE", "Begin: Live")
        local s = state(player, id)
        report:check("You were brought in", s.participant == true)
        local h = waitFor(8000, function() local x = hud() return x and x.hud and x.hud.title and x.hud.title:find(T.PREFIX, 1, true) and x or nil end)
        report:check("Your HUD shows the event", h ~= nil, hudGoal())
        step("EVENT_STOP", "COMPLETE", "Stop: Finished")
        step("EVENT_RESET", "DRAFT", "Reset for reuse: Draft")
        local deleted = op(player, "act", { id = id, what = "call", command = "EVENT_DELETE_DEFINITION" })
        report:check("Delete removes it", deleted.success == true, deleted.reason)
        return started
    end, true)
end

local function directorFlow(player)
    return eventFlow(player, "Director controls", "survivor", { seconds = 120 }, function(report, setup)
        local function director(command, parameters)
            return op(player, "act", { id = setup.id, what = "call", command = "EVENT_DIRECTOR_EXECUTE",
                args = { eventId = setup.id, command = command, parameters = parameters or {} } })
        end
        local status = director("GET_STATUS")
        report:check("Director reads the live event", status.success == true, status.reason)
        local before = state(player, setup.id).endsInMs or 0
        local added = director("ADD_TIME", { seconds = 60 })
        local after = state(player, setup.id).endsInMs or 0
        report:check("Add time adds a minute", added.success == true and after - before > 50000, math.floor((after - before) / 1000) .. " s more")
        local said = director("ANNOUNCE_MESSAGE", { text = "LilBubby test announcement" })
        report:check("Announce reaches the event", said.success == true, said.reason)
    end)
end

local function rewardsFlow(player)
    return eventFlow(player, "Prizes", "survivor", { seconds = 15, rewardItems = { { itemFullType = "Base.Apple", count = 1 } } }, function(report, setup)
        local s = waitState(player, setup.id, 40000, function(x) return x.outcome ~= nil end, "Surviving 15 seconds for a prize")
        won(report, s, player)
        local listed = op(player, "act", { id = setup.id, what = "call", command = "EVENT_LIST_REWARDS" })
        local mine
        for _, award in ipairs(listed.awards or {}) do
            if award.recipientUsername == player:getUsername() and award.status == "AWAITING_ADMIN_DELIVERY" then mine = award end
        end
        report:check("Your prize waits for an admin to hand it over", mine ~= nil, #(listed.awards or {}) .. " award(s) listed")
        if mine then
            local marked = op(player, "act", { id = setup.id, what = "call", command = "EVENT_MARK_REWARD_DELIVERED", args = { awardId = mine.id } })
            report:check("Mark delivered", marked.success == true, marked.reason)
        end
    end)
end

------------------------------------------------------------
-- GAME MODES
------------------------------------------------------------

local function roundStarts(player, report, id)
    local s = waitState(player, id, 45000, function(x) return x.round and x.round.state == "ACTIVE" end, "Waiting for round 1 to start by itself")
    report:check("Round 1 started by itself", s ~= nil)
    return s
end

local function captureFlow(player)
    return eventFlow(player, "Capture the Flag", "capture", nil, function(report, setup)
        if not roundStarts(player, report, setup.id) then return end
        local s = waitState(player, setup.id, 10000, function(x) return x.flags and #x.flags == 1 end, "Waiting for the flag")
        report:check("The flag spawned", s ~= nil)
        report:check("Your HUD says grab the flag", hudGoal():find("flag", 1, true) ~= nil, hudGoal())
        op(player, "act", { id = setup.id, what = "takeFlag" })
        s = waitState(player, setup.id, 12000, function(x) return x.flags and x.flags[1] and x.flags[1].carrier == player:getUsername() end, "Picking up the flag")
        report:check("You are carrying the flag", s ~= nil)
        local target = waitFor(10000, function() local h = hud() return h and h.hud and h.hud.target and h.hud.target.label == "Delivery point" or nil end)
        report:check("Your HUD points at the delivery point", target ~= nil)
        travel(player, setup.points.goal)
        s = waitState(player, setup.id, 20000, function(x) return x.outcome ~= nil end, "Delivering the flag")
        won(report, s, player)
    end)
end

local function ctfFlow(player)
    return eventFlow(player, "Team Capture the Flag", "ctf", nil, function(report, setup)
        local s = state(player, setup.id)
        report:check("You were put on a team", s.team ~= nil, s.team)
        if not roundStarts(player, report, setup.id) then return end
        waitState(player, setup.id, 10000, function(x) return x.flags and #x.flags == 2 end, "Waiting for both flags")
        op(player, "act", { id = setup.id, what = "takeFlag" })
        s = waitState(player, setup.id, 12000, function(x)
            for _, flag in ipairs(x.flags or {}) do if flag.carrier == player:getUsername() and flag.teamId ~= x.team then return true end end
        end, "Stealing the enemy flag")
        report:check("You are carrying the enemy flag", s ~= nil)
        travel(player, s and s.team == "team_2" and setup.points.enemy or setup.points.home)
        s = waitState(player, setup.id, 20000, function(x) return x.outcome ~= nil end, "Bringing it home")
        won(report, s, player)
    end)
end

local function kothFlow(player)
    return eventFlow(player, "King of the Hill", "koth", nil, function(report, setup)
        if not roundStarts(player, report, setup.id) then return end
        travel(player, setup.points.hill)
        local s = waitState(player, setup.id, 15000, function(x) return x.holder ~= nil and x.holder ~= "CONTESTED" end, "Holding the hill")
        report:check("Your team holds the hill", s ~= nil, s and s.holder)
        s = waitState(player, setup.id, 60000, function(x) return x.outcome ~= nil end, "Holding until the round ends")
        won(report, s, player)
    end)
end

local function chaseFlow(player)
    return eventFlow(player, "Chase", "chase", nil, function(report, setup)
        local s = roundStarts(player, report, setup.id)
        report:check("You were picked as the target", s and s.chaseTarget == player:getUsername(), s and s.chaseTarget)
        local told = waitFor(8000, function() return hudGoal():find("TARGET", 1, true) and true or nil end)
        report:check("Your HUD says you are the target", told ~= nil, hudGoal())
        s = waitState(player, setup.id, 50000, function(x) return x.outcome ~= nil end, "Surviving the round")
        won(report, s, player)
    end)
end

local function extractionFlow(player)
    return eventFlow(player, "Extraction", "extraction", nil, function(report, setup)
        local phase = waitFor(8000, function() local h = hud() return h and h.hud and h.hud.phase or nil end)
        report:check("Your HUD counts down to the evac", phase == "Evac arrives in", phase)
        travel(player, setup.points.exit)
        pause(8000, "Standing at the exit before the evac")
        local s = state(player, setup.id)
        report:check("The exit does nothing before the evac", not s.extracted)
        s = waitState(player, setup.id, 60000, function(x) return x.evacOpen end, "Waiting for the evac")
        report:check("The evac arrives near the end", s ~= nil)
        s = waitState(player, setup.id, 15000, function(x) return x.extracted or x.outcome ~= nil end, "Being extracted")
        report:check("Standing at the exit gets you out", s ~= nil)
        s = waitState(player, setup.id, 15000, function(x) return x.outcome ~= nil end, "Waiting for the event to end")
        won(report, s, player)
    end)
end

local function prisonFlow(player)
    return eventFlow(player, "Prison Break", "prison", nil, function(report, setup)
        travel(player, setup.points.exit)
        pause(7000, "Trying the exit before finding the way out")
        report:check("The exit is locked until you search", not state(player, setup.id).extracted)
        travel(player, setup.points.search)
        local s = waitState(player, setup.id, 12000, function(x) return x.unlocked end, "Searching the spot")
        report:check("Searching unlocks the way out", s ~= nil)
        travel(player, setup.points.exit)
        s = waitState(player, setup.id, 15000, function(x) return x.outcome ~= nil end, "Escaping")
        won(report, s, player)
    end)
end

local function fireSaleFlow(player)
    return eventFlow(player, "Fire Sale", "firesale", nil, function(report, setup)
        local s = state(player, setup.id)
        report:check("The way out is open from the start", s.evacOpen)
        report:check("Every exit but one is swarmed", (s.spawned or 0) > 0 and s.safeExit ~= nil, (s.spawned or 0) .. " zombies")
        travel(player, s.safeExit)
        s = waitState(player, setup.id, 15000, function(x) return x.outcome ~= nil end, "Leaving by the clear exit")
        won(report, s, player)
    end)
end

local function survivorFlow(player)
    return eventFlow(player, "Survivor Run", "survivor", { seconds = 25 }, function(report, setup)
        local told = waitFor(8000, function() return hudGoal():find("alive", 1, true) and true or nil end)
        report:check("Your HUD says stay alive", told ~= nil, hudGoal())
        local s = waitState(player, setup.id, 40000, function(x) return x.outcome ~= nil end, "Surviving 25 seconds")
        won(report, s, player)
    end)
end

local function olympicsFlow(player)
    return eventFlow(player, "The Olympics", "olympics", nil, function(report, setup)
        local p = setup.points
        travel(player, p.start)
        local s = waitState(player, setup.id, 30000, function(x) return x.heatPhase == "RUNNING" end, "Waiting for 3-2-1-GO")
        if not report:check("Your heat was called and started", s ~= nil) then return end
        report:check("You race for your town", s.racer and s.racer.country == "Muldraugh", s.racer and s.racer.country)
        local function reach(point, index, what)
            travel(player, point)
            return waitState(player, setup.id, 15000, function(x) return x.station and x.station > index end, what)
        end
        report:check("Station 1: checkpoint", reach(p.station1, 1, "Running to the checkpoint") ~= nil)
        travel(player, p.station2)
        waitState(player, setup.id, 8000, function(x) return x.arrived end, "Getting the axe")
        op(player, "act", { id = setup.id, what = "give", item = "Base.Log", count = 2 })
        report:check("Station 2: chop wood (the test hands you 2 logs)", waitState(player, setup.id, 10000, function(x) return x.station and x.station > 2 end) ~= nil)
        travel(player, p.station3)
        waitState(player, setup.id, 8000, function(x) return x.arrived end, "Getting the saw")
        op(player, "act", { id = setup.id, what = "give", item = "Base.Plank", count = 2 })
        report:check("Station 3: craft (the test hands you 2 planks)", waitState(player, setup.id, 10000, function(x) return x.station and x.station > 3 end) ~= nil)
        travel(player, p.station4)
        waitState(player, setup.id, 8000, function(x) return x.arrived end, "Finding the load")
        op(player, "act", { id = setup.id, what = "takeLoad" })
        report:check("Station 4: carry the load to the drop zone", reach(p.drop, 4, "Carrying the load") ~= nil)
        travel(player, p.station5)
        waitState(player, setup.id, 8000, function(x) return x.arrived end, "Waking the targets")
        op(player, "act", { id = setup.id, what = "killTargets" })
        report:check("Station 5: every target down", waitState(player, setup.id, 10000, function(x) return x.station and x.station > 5 end) ~= nil)
        local h = hud()
        report:check("Your HUD shows a running stopwatch", h and h.hud and h.hud.stopwatchMs ~= nil)
        travel(player, p.finish)
        s = waitState(player, setup.id, 10000, function(x) return x.racer and x.racer.status == "FINISHED" end, "Crossing the finish")
        report:check("You finished with a time", s and (s.racer.timeMs or 0) > 0, s and s.racer.timeMs)
        s = waitState(player, setup.id, 25000, function(x) return x.outcome ~= nil end, "Waiting for the medals")
        won(report, s, player)
        report:info("Your medal was not kept", "the test puts the medal table back as it was")
    end)
end

------------------------------------------------------------
-- PLAYERS AND THREATS
------------------------------------------------------------

local function wornTypes(player)
    local out = {}
    pcall(function()
        local worn = player:getWornItems()
        for i = 0, worn:size() - 1 do out[#out + 1] = worn:get(i):getItem():getFullType() end
    end)
    return out
end

local function loadoutsFlow(player)
    local report = T.newReport("Starting loadouts")
    local Shared = KIPN.Shared
    for _, id in ipairs(Shared.EventLoadoutOrder or {}) do
        if id ~= "NONE" then
            local spec = Shared.EventLoadouts[id]
            local before = player:getInventory():getItems():size()
            local sub = eventFlow(player, spec.label, "survivor", { loadout = id, seconds = 120 }, function(r, setup)
                local s = waitState(player, setup.id, 8000, function(x) return x.loadoutTagged > 0 end, "Handing out the loadout")
                r:check("Loadout handed out", s ~= nil, s and table.concat(s.loadoutItems, ", "))
                local sent = waitFor(5000, function() return seen.loadouts[#seen.loadouts] end)
                r:check("Your game was told what to wear", sent and sent.loadout == id, sent and sent.loadout)
                if spec.wear and spec.wear[1] then
                    local worn = waitFor(6000, function() return has(wornTypes(player), spec.wear[1]) or nil end, "Putting it on")
                    r:check("You are wearing " .. spec.wear[1], worn ~= nil, table.concat(wornTypes(player), ", "))
                end
                if not spec.keepGear then
                    r:check("Your own gear went into escrow", player:getInventory():getItems():size() <= (s and s.loadoutTagged or 0) + 2,
                        player:getInventory():getItems():size() .. " item(s) on you")
                end
                op(player, "act", { id = setup.id, what = "stop" })
                s = waitState(player, setup.id, 8000, function(x) return x.loadoutTagged == 0 end, "Taking the loadout back")
                r:check("Loadout taken back", s ~= nil)
                local back = waitFor(8000, function() return player:getInventory():getItems():size() >= before or nil end, "Returning your gear")
                r:check("Your own gear is back", back ~= nil, player:getInventory():getItems():size() .. " of " .. before .. " item(s)")
            end, false)
            report:merge({ { sub.failed == 0 and "PASS" or "FAIL", spec.label, sub.passed .. " passed, " .. sub.failed .. " failed" } })
            for _, text in ipairs(sub.lines) do report.lines[#report.lines + 1] = "  " .. text end
        end
    end
    return report
end

local function cluesFlow(player)
    return eventFlow(player, "Clues", "clues", nil, function(report, setup)
        travel(player, setup.points.clue)
        local buttons = waitFor(12000, function() local h = hud() return h and #h.clueButtons >= 1 and h.clueButtons or nil end, "Reading the clue")
        report:check("Reaching the spot shows a clue and keeps a button", buttons ~= nil and buttons[1].title == "Test clue", buttons and buttons[1].title)
        if buttons then
            local h = hud()
            h.banners = {}
            buttons[1].onclick(buttons[1].target, buttons[1])
            report:check("Clicking the button shows it again", h.banners[1] and h.banners[1].text:find("4-7-1", 1, true) ~= nil)
        end
        travel(player, setup.points.hint)
        local hint = waitFor(12000, function() local h = hud() return h and #h.clueButtons >= 2 and h.clueButtons[2] or nil end, "Waiting for the hint")
        report:check("A story hint becomes a clue button too", hint ~= nil and hint.title == "Hint", hint and hint.title)
        report:check("The server remembers both clues for you", state(player, setup.id).clues == 2)
    end, true)
end

local function hudFadeFlow(player)
    local report = T.newReport("HUD fade")
    local H = KIPN_EventPlayerHUD
    if not report:check("The HUD is loaded", H ~= nil) then return report end
    local existed = H.instance ~= nil
    local h = H.Show()
    h:setHud({ title = T.PREFIX .. "HUD", goal = "Testing the fade", lines = {}, clues = { { title = "Note", text = "A test clue." } } })
    report:check("Clue buttons appear", #h.clueButtons == 1)
    h.lastWakeAt = getTimestampMs() - 10000
    coroutine.yield()
    local mouseOver = getMouseX() >= h:getAbsoluteX() and getMouseX() <= h:getAbsoluteX() + h.width
        and getMouseY() >= h:getAbsoluteY() and getMouseY() <= h:getAbsoluteY() + h.height
    if mouseOver then
        report:skip("Fade after 5 s", "your mouse is over the HUD; move it away and run again")
    else
        report:check("Faded 5 s after the mouse left", H.FadeAlpha(h) < 0.3, string.format("%.2f", H.FadeAlpha(h)))
    end
    h:wake()
    report:check("Something new brings it back", H.FadeAlpha(h) == 1)
    if not existed then H.Hide() end
    return report
end

local function threatsFlow(player)
    return eventFlow(player, "Threats", "threats", { seconds = 240 }, function(report, setup)
        local s = waitState(player, setup.id, 45000, function(x) return (x.sieges or 0) >= 1 end, "Waiting for the siege")
        report:check("A horde siege comes from every side", s ~= nil and (s.spawned or 0) >= 4, s and ((s.spawned or 0) .. " zombies"))
        if player:isOutside() then
            report:skip("The alarm goes off", "stand inside a building to test the alarm (it needs one)")
        else
            s = waitState(player, setup.id, 200000, function(x) return x.alarmed end, "Waiting for the alarm (3 minutes on Normal)")
            report:check("The alarm goes off", s ~= nil)
        end
        local before = state(player, setup.id).spawned or 0
        travel(player, setup.points.ambush)
        s = waitState(player, setup.id, 12000, function(x) return (x.ambushed or 0) >= 1 end, "Walking into the ambush")
        report:check("Walking in wakes the ambush", s ~= nil and (s.spawned or 0) > before, s and ((s.spawned or 0) - before) .. " more zombies")
    end)
end

------------------------------------------------------------
-- CLASSIC SCENARIO LOCATIONS
------------------------------------------------------------

local function squareCheck(x, y, z)
    local square = getCell():getGridSquare(x, y, z)
    if not square then return false, "not loaded" end
    if not square:getFloor() then return false, "no floor" end
    if square:isSolidTrans() or square:isSolid() then return false, "blocked" end
    return true, "open"
end

local function visitFlow(id)
    return function(player)
        local template = KIPN.Shared.EventClassicScenarios[id]
        local report = T.newReport("Visit " .. template.label)
        local S = KIPN_EventStudio
        local spots = S and S.VenueHotspots(template) or {}
        local start
        for _, spot in ipairs(spots) do
            if spot.type == "PLAYER_SPAWN" then start = spot end
        end
        if not report:check("The location has a start point", start ~= nil) then return report end
        local origin = here(player)
        local invisible = player:isInvisible()
        player:setInvisible(true)
        local g = start.geometry
        local point = { x = math.floor((g.x1 + g.x2) / 2), y = math.floor((g.y1 + g.y2) / 2), z = g.z1 }
        progress(player, "Travelling to " .. template.venue.label .. " (" .. point.x .. "," .. point.y .. "," .. point.z .. ")")
        report:check("You arrive at the start point", travel(player, point), point.x .. "," .. point.y .. "," .. point.z)
        pause(3000, "Letting the area load")
        local ok, why = squareCheck(point.x, point.y, point.z)
        report:check("The start point is open floor", ok, why)
        for _, spot in ipairs(spots) do
            if spot ~= start then
                local gg = spot.geometry
                local cx, cy = math.floor((gg.x1 + gg.x2) / 2), math.floor((gg.y1 + gg.y2) / 2)
                if T.Distance(point.x, point.y, cx, cy) <= 60 then
                    local spotOk, spotWhy = squareCheck(cx, cy, gg.z1)
                    report:check(spot.label .. " at " .. cx .. "," .. cy .. "," .. gg.z1 .. " is open floor", spotOk, spotWhy)
                else
                    report:info(spot.label .. " is too far to check from here", cx .. "," .. cy .. "," .. gg.z1)
                end
            end
        end
        if template.venue.zone then
            local z = template.venue.zone
            report:check("The zone surrounds the start point", point.x >= z[1] and point.x <= z[3] and point.y >= z[2] and point.y <= z[4])
        end
        travel(player, origin)
        player:setInvisible(invisible)
        return report
    end
end

------------------------------------------------------------
-- CLEANUP
------------------------------------------------------------

------------------------------------------------------------
-- MOVES, BANDITS, PREPARED EVENTS AND SIMULATION
------------------------------------------------------------

local function bannerSince(count, text)
    for index = count + 1, #seen.banners do
        if seen.banners[index]:find(text, 1, true) then return seen.banners[index] end
    end
end

local function call(player, id, command, args)
    return op(player, "act", { id = id, what = "call", command = command, args = args })
end

local function moveFlow(player)
    return eventFlow(player, "Moves", "survivor", { seconds = 120 }, function(report, setup)
        local movesBefore = #seen.moves
        local r = op(player, "act", { id = setup.id, what = "move", dx = 5 })
        report:check("The server asks your client to move you", r.moved == true and (not isClient() or waitFor(4000, function()
            return #seen.moves > movesBefore or nil end)), r.error)
        local arrived = waitFor(5000, function() return T.Distance(player:getX(), player:getY(), r.target.x, r.target.y) < 1.5 or nil end, "Moving 5 tiles")
        report:check("A short move arrives at once", arrived ~= nil, string.format("%d,%d", math.floor(player:getX()), math.floor(player:getY())))
        r = op(player, "act", { id = setup.id, what = "move", dx = 40 })
        report:info("A long move", r.hop and ("hops " .. r.hop .. " tiles a second (speed anti-cheat on)") or "jumps (anti-cheat off or you may teleport)")
        arrived = waitFor(12000, function() return T.Distance(player:getX(), player:getY(), r.target.x, r.target.y) < 1.5 or nil end, "Moving 40 tiles")
        report:check("A long move arrives", arrived ~= nil, string.format("%d,%d", math.floor(player:getX()), math.floor(player:getY())))
    end, true)
end

local function banditsFlow(player)
    return eventFlow(player, "Bandit camp", "bandits", nil, function(report, setup)
        local s = waitState(player, setup.id, 15000, function(x) return x.bandits and x.bandits.alive == 2 end, "Waiting for the crew")
        report:check("The camp's crew is there", s ~= nil, s and s.bandits and s.bandits.alive)
        report:check("They wait calmly", s and s.bandits.calm == 2)
        local banners = #seen.banners
        travel(player, { x = setup.points.camp.x - 5, y = setup.points.camp.y, z = setup.points.camp.z })
        s = waitState(player, setup.id, 10000, function(x) return x.bandits and x.bandits.hostile > 0 end, "Walking up to the camp")
        report:check("Coming close starts the fight", s ~= nil)
        report:check("You are warned", waitFor(5000, function() return bannerSince(banners, "spotted you") end) ~= nil)
        if isClient() then
            report:check("They shout", #seen.says > 0, #seen.says .. " line(s)")
        else
            report:skip("They shout", "single player draws their lines directly; checked on a server")
        end
    end, true)
end

local function raidFlow(player)
    return eventFlow(player, "Bandit raid", "raid", nil, function(report, setup)
        local banners = #seen.banners
        local r = op(player, "act", { id = setup.id, what = "raid" })
        report:check("A raiding crew arrives", (r.members or 0) >= 2, r.members or r.error)
        local s = state(player, setup.id)
        report:check("Raiders come straight for you", s.bandits and s.bandits.hostile >= 2, s.bandits and s.bandits.hostile)
        report:check("Everyone is warned", waitFor(5000, function() return bannerSince(banners, "Bandits!") end) ~= nil)
    end, true)
end

local function heistFlow(player)
    return eventFlow(player, "The Heist", "heist", nil, function(report, setup)
        local s = waitState(player, setup.id, 15000, function(x) return (x.goldInTrunk or 0) > 0 end, "Waiting for the getaway car")
        report:check("The getaway car is parked with the gold in the trunk", s and s.goldInTrunk == KIPN.Shared.EventHeist.count,
            s and s.goldInTrunk)
        report:check("Its crew guards it calmly", s and s.bandits and s.bandits.calm >= 1 and s.bandits.vehicles == 1)
        report:check("Your HUD says find the car", waitFor(8000, function() return hudGoal():find("getaway car", 1, true) and true or nil end) ~= nil, hudGoal())
        travel(player, setup.points.exit)
        pause(7000, "Trying the pickup without the gold")
        report:check("The pickup won't take you without the gold", not state(player, setup.id).extracted)
        local taken = op(player, "act", { id = setup.id, what = "takeGold" })
        report:check("You take the gold from the trunk", taken.taken == KIPN.Shared.EventHeist.count, taken.taken)
        s = waitState(player, setup.id, 20000, function(x) return x.outcome ~= nil end, "Handing over the gold")
        won(report, s, player)
        report:check("The gold was banked", s and s.goldCarried == 0 and (s.gold or KIPN.Shared.EventHeist.count) >= 0, s and s.goldCarried)
        report:check("The run is in Past events", s and s.lastRun and s.lastRun.outcome == "WIN", s and s.lastRun and s.lastRun.outcome)
    end, true)
end

local PREPARED = { draft = true, ready = true }

local function quickStartFlow(player)
    return eventFlow(player, "Start <event>", "prepared", PREPARED, function(report, setup)
        local id = setup.id
        local invites, banners = #seen.invites, #seen.banners
        local r = call(player, id, "EVENT_QUICK_START", { signupSeconds = 15 })
        report:check("Start opens sign-ups", r.status == "JOINING" and state(player, id).pending, r.status)
        report:check("Everyone is asked to sign up", waitFor(8000, function() return bannerSince(banners, "Sign up now") end) ~= nil)
        local invite = waitFor(8000, function() return #seen.invites > invites and seen.invites[#seen.invites] or nil end)
        report:check("You get the sign-up prompt", invite and invite.kind == "SIGN_UP", invite and invite.kind)
        sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_ACCEPT_PARTICIPATION, { id = id })
        report:check("A countdown is shown", waitFor(16000, function() return bannerSince(banners, "begins in") end) ~= nil)
        local s = waitState(player, id, 20000, function(x) return x.active end, "Waiting for sign-ups to close")
        report:check("It begins by itself", s ~= nil and s.status == "ACTIVE", s and s.status)
        report:check("You were brought in", s and s.participant)
        report:check("Everyone hears it has begun", waitFor(5000, function() return bannerSince(banners, "has begun") end) ~= nil)
        r = call(player, id, "EVENT_CANCEL")
        s = state(player, id)
        report:check("Cancel stops it and keeps it prepared", not s.active and s.status == "READY", s.status)
        report:check("The run is in Past events", s.lastRun and s.lastRun.outcome == "MANUAL", s.lastRun and s.lastRun.outcome)
    end, true)
end

local function cancelFlow(player)
    return eventFlow(player, "Cancel <event>", "prepared", PREPARED, function(report, setup)
        local id = setup.id
        call(player, id, "EVENT_ANNOUNCE")
        local r = call(player, id, "EVENT_CANCEL")
        local s = state(player, id)
        report:check("Announced: back to Ready", s.status == "READY", s.status)
        report:check("Recorded as cancelled", s.lastRun and s.lastRun.outcome == "CANCELLED")
        call(player, id, "EVENT_QUICK_START", { signupSeconds = 60 })
        call(player, id, "EVENT_CANCEL")
        s = state(player, id)
        report:check("A pending start is called off", not s.pending and s.status == "READY", s.status)
        call(player, id, "EVENT_ANNOUNCE")
        call(player, id, "EVENT_OPEN_JOINING")
        call(player, id, "EVENT_CANCEL")
        report:check("Joining: back to Ready", state(player, id).status == "READY")
        call(player, id, "EVENT_CANCEL")
        report:check("Ready: unlocked for editing (Draft)", state(player, id).status == "DRAFT")
        r = call(player, id, "EVENT_CANCEL")
        report:check("A draft has nothing to cancel", r.success == false and state(player, id).status == "DRAFT")
    end, true)
end

local function announceFlow(player)
    return eventFlow(player, "Announcements", "prepared", PREPARED, function(report, setup)
        local id = setup.id
        local banners = #seen.banners
        local r = call(player, id, "EVENT_SEND_ANNOUNCEMENT", { text = "LilBubby test announcement." })
        report:check("Sent", r.success == true)
        report:check("It shows as a banner", waitFor(8000, function() return bannerSince(banners, "LilBubby test announcement.") end) ~= nil)
        call(player, id, "EVENT_SEND_ANNOUNCEMENT", { text = "" })
        report:check("With no text, the briefing goes out", waitFor(8000, function() return bannerSince(banners, "hold the line") end) ~= nil)
        call(player, id, "EVENT_CANCEL")
        r = call(player, id, "EVENT_SEND_ANNOUNCEMENT", { text = "x" })
        report:check("Drafts can't be announced", r.success == false)
    end, true)
end

local function simPanel() return KIPN_EventSimulationUI and KIPN_EventSimulationUI.instance end
local function simData() local p = simPanel() return p and p.data end

local function press(which)
    local p = simPanel()
    local b = p and p[which .. "Button"]
    if b then b.onclick(b.target, b) end
    return b ~= nil
end

-- Waits for the panel to show step `index` (or to close, index nil).
local function simAt(index)
    return waitFor(15000, function()
        local d = simData()
        if index == nil then return simPanel() == nil or nil end
        return d and d.index == index and not d.editing and d or nil
    end, "Waiting for the simulation")
end

local function startSim(player, report, id)
    local r = call(player, id, "EVENT_SIMULATE")
    report:check("Simulate starts", r.success == true, r.reason)
    local d = simAt(1)
    report:check("The guide panel shows step 1", d ~= nil and d.title == "Briefing", d and d.title)
    return d
end

local function focusOf(d)
    for _, h in ipairs(d and d.hotspots or {}) do
        if h.focus then return { x = math.floor((h.x1 + h.x2) / 2), y = math.floor((h.y1 + h.y2) / 2), z = h.z or 0 } end
    end
end

local function simulateFlow(player)
    return eventFlow(player, "Simulate <event>", "prepared", PREPARED, function(report, setup)
        local id = setup.id
        local banners = #seen.banners
        local d = startSim(player, report, id)
        if not d then return end
        local index = player:getPlayerNum()
        report:check("You are invisible and unhurt", player:isInvisible() and player:isGodMod())
        report:check("The guide lists every step", #(d.steps or {}) == d.total, d.total)
        report:check("The briefing plays", waitFor(5000, function() return bannerSince(banners, "hold the line") end) ~= nil)
        local shown = {}
        while d and d.index < d.total do
            local nextIndex = d.index + 1
            press("ok")
            d = simAt(nextIndex)
            if not d then report:check("Step " .. nextIndex .. " plays", false) break end
            shown[#shown + 1] = d.title
            local focus = focusOf(d)
            if focus then
                local there = waitFor(12000, function() return T.Distance(player:getX(), player:getY(), focus.x, focus.y) < 4 or nil end, "Going to " .. d.title)
                report:check("Taken to " .. d.title, there ~= nil)
                local glowing = waitFor(5000, function()
                    local sq = getCell():getGridSquare(focus.x, focus.y, focus.z)
                    local floor = sq and sq:getFloor()
                    return floor and floor:isHighlighted(index) or nil
                end)
                report:check(d.title .. " glows", glowing ~= nil)
            end
            if d.key and d.key:find("^hotspot:") and d.title:find("Zombie Spawn", 1, true) then
                local outlined = waitFor(8000, function()
                    local zombies = getCell():getZombieList()
                    for i = 0, zombies:size() - 1 do
                        if zombies:get(i):isOutlineHighlight(index) then return true end
                    end
                end)
                report:check("Zombies are outlined", outlined ~= nil)
            elseif d.title:find("Bandit Camp", 1, true) then
                report:check("The camp's bandit is marked for its own outline", #(d.bandits or {}) >= 1)
            elseif d.title:find("Narrative", 1, true) then
                report:check("The clue plays and gets a HUD button", waitFor(5000, function()
                    local h = hud()
                    return h and #h.clues > 0 and h.clues[#h.clues].title == "Test note" or nil
                end) ~= nil)
            elseif d.key and d.key:find("^trigger:") then
                report:check("The story line plays", waitFor(5000, function() return bannerSince(banners, "LilBubby test story line.") end) ~= nil)
            elseif d.key == "threats" then
                report:check("The demo fire is only light", #(d.fires or {}) == 1)
            elseif d.key == "ending" then
                report:check("Win and lose text play", waitFor(8000, function()
                    return bannerSince(banners, "you won.") and bannerSince(banners, "you lost.") end) ~= nil)
            end
        end
        report:info("Steps shown", table.concat(shown, " > "))
        press("ok")
        report:check("Finish closes the simulation", simAt(nil) ~= nil)
        report:check("You are visible again", not player:isInvisible())
        local back = waitFor(15000, function() return T.Distance(player:getX(), player:getY(), setup.points.here.x, setup.points.here.y) < 3 or nil end, "Going back")
        report:check("You are taken back", back ~= nil)
        local s = state(player, id)
        report:check("The event is untouched", s.status == "READY" and not s.simulating and not s.active, s.status)
    end, true)
end

local function simulateEditFlow(player)
    return eventFlow(player, "Simulate: Edit and Resume", "prepared", PREPARED, function(report, setup)
        local id = setup.id
        local d = startSim(player, report, id)
        if not d then return end
        press("ok")
        d = simAt(2)
        local before = d and { total = d.total, key = d.key, index = d.index }
        press("edit")
        local editing = waitFor(8000, function() local x = simData() return x and x.editing and x or nil end)
        report:check("Edit pauses on the step", editing ~= nil and editing.index == before.index)
        local studio = KIPN_EventStudioUI and KIPN_EventStudioUI.instance
        report:check("The Event Studio opens on this event", waitFor(8000, function()
            studio = KIPN_EventStudioUI and KIPN_EventStudioUI.instance
            return studio and studio.isOpen and studio.selectedId == id or nil end) ~= nil)
        report:check("Resume replaces OK while editing", simPanel() and simPanel().okButton.title == "Resume")
        local here = { x = math.floor(player:getX()) + 3, y = math.floor(player:getY()), z = math.floor(player:getZ()) }
        local added = call(player, id, "EVENT_UPSERT_HOTSPOT", { hotspot = { type = "OBJECTIVE_LOCATION", label = "added in edit",
            geometry = { x1 = here.x - 1, y1 = here.y - 1, x2 = here.x + 1, y2 = here.y + 1, z1 = here.z, z2 = here.z } } })
        report:check("An element is added while paused", added.success == true, added.reason)
        press("ok")
        d = simAt(before.index)
        report:check("Resume plays the step again with the change", d and d.total == before.total + 1 and d.key == before.key,
            d and (d.total .. " steps"))
        press("cancel")
        report:check("Cancel closes it", simAt(nil) ~= nil)
        if studio and studio.isOpen then studio:close() end
    end, true)
end

local function simulateCancelFlow(player)
    return eventFlow(player, "Simulate: Cancel cleans up", "prepared", PREPARED, function(report, setup)
        local id = setup.id
        local d = startSim(player, report, id)
        if not d then return end
        local spawned = false
        while d and d.index < d.total do
            local s = state(player, id)
            if s.sim and (s.sim.crews > 0 or s.sim.items > 0) and d.key ~= "loadout" then spawned = true break end
            local nextIndex = d.index + 1
            press("ok")
            d = simAt(nextIndex)
        end
        report:check("Reached a step that spawns things", spawned, d and d.title)
        pause(2000, "Letting it spawn")
        local t = op(player, "act", { id = id, what = "simTrack" })
        report:info("The simulation had made", (t.zombies or 0) .. " zombie(s)/bandit(s), " .. (t.items or 0) .. " item(s), " .. (t.vehicles or 0) .. " car(s)")
        local floorSpot = focusOf(simData())
        press("cancel")
        report:check("Cancel closes the simulation", simAt(nil) ~= nil)
        local left = op(player, "act", { id = id, what = "simLeftovers" })
        report:check("No zombies or bandits are left", left.zombies == 0, left.zombies)
        report:check("No items are left", left.items == 0, left.items)
        report:check("No cars are left", left.vehicles == 0, left.vehicles)
        report:check("Clues from the simulation are gone", waitFor(5000, function() local h = hud() return (not h or #h.clues == 0) or nil end) ~= nil)
        if floorSpot then
            local sq = getCell():getGridSquare(floorSpot.x, floorSpot.y, floorSpot.z)
            local floor = sq and sq:getFloor()
            report:check("The glow is gone", not (floor and floor:isHighlighted(player:getPlayerNum())))
        end
        report:check("You are visible again", not player:isInvisible())
        local back = waitFor(15000, function() return T.Distance(player:getX(), player:getY(), setup.points.here.x, setup.points.here.y) < 3 or nil end, "Going back")
        report:check("You are taken back", back ~= nil)
    end, true)
end

local function invitation() return KIPN_EventSimulationUI and KIPN_EventSimulationUI.Invite and KIPN_EventSimulationUI.Invite.instance end

local function simulateInviteFlow(player)
    return eventFlow(player, "Simulation invitation", "prepared", PREPARED, function(report, setup)
        local id = setup.id
        local origin = here(player)
        -- OK: taken to the start, a guest, then Leave.
        local hosted = op(player, "act", { id = id, what = "hostSim" })
        report:check("Someone else's simulation invites you", (hosted.invited or 0) >= 1, hosted.error or hosted.invited)
        local prompt = waitFor(8000, function() return invitation() end, "Waiting for the invitation")
        report:check("An invitation with OK and Cancel appears", prompt ~= nil and prompt.okButton.title == "OK" and prompt.cancelButton.title == "Cancel")
        report:check("It says who is running what", prompt ~= nil and KIPN_EventSimulationUI.Invite.Text(prompt.data):find(T.PREFIX, 1, true) ~= nil)
        local s = state(player, id)
        report:check("Nothing happens until you answer", s.sim and s.sim.guests == 0 and s.sim.invited and T.Distance(player:getX(), player:getY(), origin.x, origin.y) < 2)
        if prompt then prompt.okButton.onclick(prompt.okButton.target, prompt.okButton) end
        local spawn = setup.points.spawn
        local there = waitFor(12000, function() return T.Distance(player:getX(), player:getY(), spawn.x, spawn.y) < 3 or nil end, "Joining")
        report:check("OK takes you to the start", there ~= nil, string.format("%d,%d", math.floor(player:getX()), math.floor(player:getY())))
        local panel = waitFor(8000, function() return simPanel() end)
        report:check("You get the guide panel as a guest: only Leave", panel ~= nil and panel.guest and panel.cancelButton.title == "Leave"
            and not panel.okButton:getIsVisible())
        report:check("You are invisible and unhurt", player:isInvisible() and player:isGodMod())
        op(player, "act", { id = id, what = "hostStep" })
        report:check("You follow the host's steps", simAt(2) ~= nil)
        press("cancel")
        report:check("Leave closes your panel", simAt(nil) ~= nil)
        local back = waitFor(15000, function() return T.Distance(player:getX(), player:getY(), origin.x, origin.y) < 3 or nil end, "Going back")
        report:check("Leaving takes you back", back ~= nil)
        report:check("You are visible again", not player:isInvisible())
        s = state(player, id)
        report:check("The simulation carries on without you", s.simulating and s.sim.guests == 0)
        op(player, "act", { id = id, what = "hostEnd" })
        -- Cancel: you opt out and stay where you are.
        op(player, "act", { id = id, what = "hostSim" })
        prompt = waitFor(8000, function() return invitation() end, "Waiting for the invitation")
        if prompt then prompt.cancelButton.onclick(prompt.cancelButton.target, prompt.cancelButton) end
        pause(3000, "Opting out")
        s = state(player, id)
        report:check("Cancel opts you out", invitation() == nil and s.simulating and s.sim.guests == 0 and not s.sim.invited)
        report:check("and you stay where you are", T.Distance(player:getX(), player:getY(), origin.x, origin.y) < 2 and simPanel() == nil)
        op(player, "act", { id = id, what = "hostEnd" })
        -- An unanswered invitation goes away when the simulation ends.
        op(player, "act", { id = id, what = "hostSim" })
        waitFor(8000, function() return invitation() end, "Waiting for the invitation")
        op(player, "act", { id = id, what = "hostEnd" })
        report:check("It is withdrawn when the simulation ends", waitFor(8000, function() return invitation() == nil or nil end) ~= nil)
    end, true)
end

local function cleanupFlow(player)
    local report = T.newReport("Dynamic Events cleanup")
    local reply = op(player, "cleanup")
    if report:check("Cleanup", reply.error == nil, reply.error) then
        report:info("Removed", (reply.events or 0) .. " test event(s), " .. (reply.zones or 0) .. " zone(s), " .. (reply.items or 0) .. " item(s)")
    end
    return report
end

------------------------------------------------------------
-- RUNNER AND MENU
------------------------------------------------------------

local function stepRunner()
    if not runner then return end
    local ok, result = coroutine.resume(runner.co)
    if not ok or coroutine.status(runner.co) == "dead" then
        local playerNum = runner.playerNum
        runner = nil
        show(playerNum, ok and result and result:text() or ("ERROR: " .. tostring(result)))
    end
end

local function start(player, fn)
    if runner then show(player:getPlayerNum(), "A Dynamic Events test is already running.") return end
    runner = { co = coroutine.create(fn), playerNum = player:getPlayerNum() }
    local ok, result = coroutine.resume(runner.co, player)
    if not ok or coroutine.status(runner.co) == "dead" then
        runner = nil
        show(player:getPlayerNum(), ok and result:text() or ("ERROR: " .. tostring(result)))
    end
end

T.Flows = {
    services = checkFlow("services", "Event services"),
    items = checkFlow("items", "Loadout, kit and course items"),
    studio_logic = studioLogicFlow,
    studio_window = studioWindowFlow,
    lifecycle = lifecycleFlow,
    validation = checkFlow("validation", "Validation"),
    director = directorFlow,
    rewards = rewardsFlow,
    capture = captureFlow,
    ctf = ctfFlow,
    koth = kothFlow,
    chase = chaseFlow,
    extraction = extractionFlow,
    prison = prisonFlow,
    firesale = fireSaleFlow,
    survivor = survivorFlow,
    laststanding = checkFlow("laststanding", "Last one standing"),
    adventure = checkFlow("adventure", "Adventure"),
    olympics = olympicsFlow,
    loadouts = loadoutsFlow,
    clues = cluesFlow,
    hud_fade = hudFadeFlow,
    difficulty = checkFlow("difficulty", "Difficulty roll"),
    threats = threatsFlow,
    fire = checkFlow("fire", "Test fire"),
    classics = classicsFlow,
    move = moveFlow,
    bandits = banditsFlow,
    raid = raidFlow,
    heist = heistFlow,
    quickstart = quickStartFlow,
    cancel = cancelFlow,
    announce = announceFlow,
    simsteps = checkFlow("simsteps", "Simulation steps"),
    simulate = simulateFlow,
    simulate_edit = simulateEditFlow,
    simulate_cancel = simulateCancelFlow,
    simulate_invite = simulateInviteFlow,
    access = checkFlow("access", "Studio and simulation access"),
}

local function submenu(context, label)
    local option = context:getOptionFromName(label)
    if option and option.subOption then return context:getSubMenu(option.subOption) end
    option = option or context:addOption(label)
    local menu = LilBubbyShowcase.NewMenu()
    context:addSubMenu(option, menu)
    return menu
end

LilBubbyShowcase.Register(ID, function(index, context, objects, test)
    if test or not T.available() then return end
    local player = getSpecificPlayer(index)
    if not player or player:isDead() then return end
    local suite = submenu(submenu(context, "lilBubby's Big ol Mod Tester"), "Dynamic Events tests")
    local groups = {}
    for _, feature in ipairs(T.Features) do
        groups[feature.group] = groups[feature.group] or submenu(suite, feature.group)
        local flow = T.Flows[feature.id]
        groups[feature.group]:addOption(feature.label, player, function(p) start(p, flow) end).site = feature.site
    end
    local visits = submenu(suite, T.VISIT_GROUP)
    for _, id in ipairs(KIPN.Shared.EventClassicScenarioOrder or {}) do
        local template = KIPN.Shared.EventClassicScenarios[id]
        if template.venue then
            visits:addOption("Visit " .. template.label .. " (" .. template.venue.label .. ")", player,
                function(p) start(p, visitFlow(id)) end)
        end
    end
    suite:addOption("Clean up my test events", player, function(p) start(p, cleanupFlow) end)
    suite:addOption("Show last result", player, function(p)
        show(p:getPlayerNum(), results[p:getPlayerNum()] or "No result yet.")
    end)
end)

Events.OnServerCommand.Add(function(module, command, args)
    if type(args) ~= "table" then return end
    if module == MODULE and command == "reply" and args.requestId then
        replies[args.requestId] = args
        return
    end
    -- What Dynamic Events itself sends you, for the checks above.
    local Shared = KIPN and KIPN.Shared
    if module ~= "KIPN" or not Shared or command ~= Shared.Commands.SERVER_RESPONSE then return end
    local event, data = args.event, args.data or {}
    if event == Shared.ResponseEvents.EVENT_PARTICIPATION_INVITE then seen.invites[#seen.invites + 1] = data
    elseif event == Shared.ResponseEvents.EVENT_PARTICIPATION_RESULT then seen.joins[#seen.joins + 1] = data
    elseif event == Shared.ResponseEvents.EVENT_APPLY_LOADOUT then seen.loadouts[#seen.loadouts + 1] = data
    elseif event == Shared.ResponseEvents.EVENT_PLAYER_HUD and data.banner then seen.banners[#seen.banners + 1] = tostring(data.banner)
    elseif event == Shared.ResponseEvents.EVENT_BANDIT_SAY then seen.says[#seen.says + 1] = data
    elseif event == Shared.ResponseEvents.EVENT_MOVE_PLAYER then seen.moves[#seen.moves + 1] = data end
end)
Events.OnTickEvenPaused.Add(stepRunner)
Events.OnFETick.Add(stepRunner)

return DynamicEventsTest
