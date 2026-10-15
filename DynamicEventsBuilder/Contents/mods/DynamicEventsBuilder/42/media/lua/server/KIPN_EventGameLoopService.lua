-- KIPN_EventGameLoopService.lua
--
-- What turns a running event into a game players can follow without
-- an admin clicking every step:
--
--   * ROUNDS RUN THEMSELVES. Round-based modes (Capture, King of the
--     Hill, Chase) get a short "get ready" countdown after the event
--     begins, then each round starts on its own and, once it is over,
--     the next one follows after a short intermission. The Director's
--     round buttons still work; they simply act sooner.
--   * EVERYONE KNOWS WHAT IS HAPPENING. Round starts, round results,
--     the chase target, the evac arriving and the final result are
--     announced to participants as big on-screen banners.
--   * EVERY PARTICIPANT HAS A HUD. Each tick the server sends each
--     participant their goal in one sentence, the clock, the score and
--     (when there is somewhere to go) where it is, rendered by
--     client/KIPN_EventPlayerHUD.lua.
--
-- Called from KIPN_EventRuntimeService.lua's tick (Tick) and stop
-- (Finish). Reads each mode engine's own state; changes none of it
-- except starting rounds through the round registry.

if isClient() then return end

require "KIPN_Shared"
require "DynamicEvents_Shared"
require "KIPN_EventHotspotService"
require "KIPN_EventTeamService"
require "KIPN_EventTimerService"
require "KIPN_EventScenarioRuntimeRegistry"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventGameLoopService = KIPN.Server.EventGameLoopService or {}

local Loop = KIPN.Server.EventGameLoopService

Loop.GET_READY_MS = 20000
Loop.INTERMISSION_MS = 15000
Loop.CHASE_PING_MS = 30000

local function log(message)
    print("[DYNAMIC EVENTS GAME LOOP] " .. tostring(message))
end

local function now()
    return (type(getTimestampMs) == "function" and getTimestampMs()) or 0
end

local function seconds(ms)
    local total = math.max(0, math.floor((ms or 0) / 1000))
    return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function modeLabel(definition)
    if definition.mode then return (KIPN.Shared.EventModeLabels or {})[definition.mode] or definition.mode end
    return "Event"
end

------------------------------------------------------------
-- PARTICIPANTS AND MESSAGES
------------------------------------------------------------

-- Online participants: { username, player, dead }.
function Loop.OnlineParticipants(runtime)
    local out = {}
    local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    if not online then return out end
    for i = 0, online:size() - 1 do
        local p = online:get(i)
        local username = p and p:getUsername()
        if username and runtime.participants[username] then
            local deadOk, dead = pcall(function() return p:isDead() end)
            out[#out + 1] = { username = username, player = p, dead = (deadOk and dead) or (runtime.deaths and runtime.deaths[username]) or false }
        end
    end
    return out
end

local function sendHud(player, payload)
    local event = KIPN.Shared.ResponseEvents.EVENT_PLAYER_HUD
    if event and KIPN.Server.SendToPlayer then KIPN.Server.SendToPlayer(player, event, payload) end
end

-- A big banner for every participant, or only those in `usernames`,
-- optionally with a sound played on each player's end.
function Loop.Announce(runtime, text, color, usernames, sound)
    if not text or text == "" then return end
    for _, entry in ipairs(Loop.OnlineParticipants(runtime)) do
        if not usernames or usernames[entry.username] then
            sendHud(entry.player, { banner = text, bannerColor = color, bannerSound = sound })
        end
    end
    runtime.log = runtime.log or {}
    runtime.log[#runtime.log + 1] = tostring(text)
    while #runtime.log > 50 do table.remove(runtime.log, 1) end
end

function Loop.AnnounceTo(runtime, username, text, color)
    Loop.Announce(runtime, text, color, { [username] = true })
end

------------------------------------------------------------
-- CLUES
--
-- Narrative hotspots and private hints can carry clues a player needs
-- to read again. Each one a player receives is kept (runtime.clues,
-- per player, in the order found) and sent with every HUD update, so
-- the HUD shows a button per clue that replays it -- and a player who
-- reconnects gets their buttons back.
------------------------------------------------------------

local CLUE = { 0.95, 0.88, 0.6 }
Loop.MAX_CLUES = 12

local function cluesFor(runtime, username)
    local out = {}
    for _, clue in ipairs((runtime.clues or {})[username] or {}) do
        out[#out + 1] = { title = clue.title, text = clue.text }
    end
    return out
end

-- Records a clue for one player. False if they already had it.
function Loop.AddClue(runtime, username, id, title, text)
    runtime.clues = runtime.clues or {}
    local list = runtime.clues[username] or {}
    runtime.clues[username] = list
    for _, clue in ipairs(list) do
        if clue.id == id then return false end
    end
    if #list >= Loop.MAX_CLUES then table.remove(list, 1) end
    list[#list + 1] = { id = id, title = (title and title ~= "") and title or ("Clue " .. (#list + 1)), text = text }
    return true
end

-- Shows narrative text as a banner to the players in `usernames` (a
-- set; nil = every participant). Replayable text becomes a clue button.
function Loop.ShowClue(runtime, usernames, id, title, text, replayable)
    local shown = 0
    for _, entry in ipairs(Loop.OnlineParticipants(runtime)) do
        if not usernames or usernames[entry.username] then
            if replayable then Loop.AddClue(runtime, entry.username, id, title, text) end
            sendHud(entry.player, {
                banner = text, bannerColor = CLUE, bannerTitle = replayable and title or nil, bannerLong = true,
                clues = cluesFor(runtime, entry.username),
            })
            shown = shown + 1
        end
    end
    return shown
end

local function teamOf(definition, username)
    local teamId = KIPN.Server.EventTeamService.GetPlayerTeam(definition, username)
    for _, team in ipairs(definition.teams or {}) do
        if team.id == teamId then return team end
    end
end

local function teamName(definition, teamId)
    for _, team in ipairs(definition.teams or {}) do
        if team.id == teamId then return team.name or teamId, team.color end
    end
    return tostring(teamId), nil
end

local function colorList(color)
    return color and { color.r or 1, color.g or 1, color.b or 1 } or nil
end

local function center(hotspot)
    return hotspot and KIPN.Server.EventHotspotService.GetCenter(hotspot) or nil
end

------------------------------------------------------------
-- ROUNDS
------------------------------------------------------------

local GOLD = { 1.0, 0.82, 0.3 }
local GREEN = { 0.45, 0.9, 0.45 }
local RED = { 1.0, 0.42, 0.42 }

-- The one-line goal for the start of a round.
local function roundGoal(runtime, definition)
    if definition.mode == "KING_OF_THE_HILL" then return "Get your team onto the hill and keep the others off it." end
    if definition.mode == "CAPTURE" then
        return definition.variant == "TEAM_CTF" and "Steal the enemy flag and bring it back to your base."
            or "Grab the flag and carry it to the delivery point."
    end
    if definition.mode == "CHASE" or runtime.objectiveState.chaseTarget then
        local target = runtime.objectiveState and runtime.objectiveState.chaseTarget
        return target and (target .. " is the target. Hunt them down!") or "Hunt down the target."
    end
    return nil
end

local function roundResult(runtime, definition)
    local round = runtime.round
    if definition.mode == "CHASE" or (runtime.objectiveState and runtime.objectiveState.chaseTarget) then
        local target = runtime.objectiveState.chaseTarget or "The target"
        if runtime.objectiveState.chaseTargetKilled then
            local killer = runtime.chaseState and runtime.chaseState.lastRoundKillerUsername
            return target .. " was caught" .. (killer and (" by " .. killer) or "") .. ". Point to every hunter!", GREEN
        end
        return target .. " escaped! Point to " .. target .. ".", GOLD
    end
    if round.winnerTeamId then
        local name, color = teamName(definition, round.winnerTeamId)
        return name .. " wins round " .. round.current .. "!", colorList(color) or GOLD
    end
    if round.winner then return round.winner .. " wins round " .. round.current .. "!", GOLD end
    return "Round " .. round.current .. " is over: nobody scored.", RED
end

local function announceChanges(runtime, definition, state)
    local round = runtime.round
    if state.seenRound == round.current and state.seenState == round.state then return end
    if round.state == "ACTIVE" then
        local goal = roundGoal(runtime, definition)
        Loop.Announce(runtime, "Round " .. round.current .. " of " .. round.maximum .. ": GO!" .. (goal and ("  " .. goal) or ""), GOLD)
        local target = runtime.objectiveState and runtime.objectiveState.chaseTarget
        if target and definition.mode == "CHASE" then
            Loop.AnnounceTo(runtime, target, "You are the target! Survive until the round ends. Hunters see where you were every "
                .. math.floor(Loop.CHASE_PING_MS / 1000) .. " seconds.", RED)
        end
    elseif round.state == "COMPLETE" and state.seenState == "ACTIVE" then
        local text, color = roundResult(runtime, definition)
        Loop.Announce(runtime, text, color)
    end
    state.seenRound, state.seenState = round.current, round.state
end

local function tickRounds(runtime, definition, state)
    local Registry = KIPN.Server.EventScenarioRuntimeRegistry
    local round = runtime.round
    if not round or not Registry.UsesRounds(definition) then return end
    local t = now()

    -- Results of the round that just ended come before "next round in...".
    announceChanges(runtime, definition, state)

    if round.state == "ACTIVE" then
        state.nextRoundAtMs = nil
        return
    end

    local waiting = (round.state == "READY" and round.current == 0)
        or (round.state == "COMPLETE" and round.current < round.maximum)
    if not waiting then return end

    if not state.nextRoundAtMs then
        state.nextRoundAtMs = t + (round.current == 0 and Loop.GET_READY_MS or Loop.INTERMISSION_MS)
        Loop.Announce(runtime, "Round " .. (round.current + 1) .. " of " .. round.maximum .. " starts in "
            .. math.floor((state.nextRoundAtMs - t) / 1000) .. " seconds.", GOLD)
    elseif t >= state.nextRoundAtMs then
        state.nextRoundAtMs = nil
        local ok, reason = Registry.StartNextRound(runtime, definition)
        if not ok then log("auto-start round failed: " .. tostring(reason)) end
        -- "GO!" now, not on the next tick.
        announceChanges(runtime, definition, state)
    end
end

-- Hunters see where the target was, refreshed every CHASE_PING_MS.
local function tickChasePing(runtime, definition)
    local target = runtime.objectiveState and runtime.objectiveState.chaseTarget
    if not target or not runtime.round or runtime.round.state ~= "ACTIVE" then return end
    runtime.chaseState = runtime.chaseState or { playerRoundWins = {}, lastAttacker = {} }
    local ping = runtime.chaseState.targetPing
    if ping and now() - ping.atMs < Loop.CHASE_PING_MS then return end
    for _, entry in ipairs(Loop.OnlineParticipants(runtime)) do
        if entry.username == target and not entry.dead then
            runtime.chaseState.targetPing = { x = math.floor(entry.player:getX()), y = math.floor(entry.player:getY()), atMs = now() }
        end
    end
end

------------------------------------------------------------
-- HUD
------------------------------------------------------------

-- Builds one participant's HUD: { title, goal, lines, eventLeftMs,
-- roundLeftMs, round, maxRounds, target = {x, y, label}, color }.
function Loop.BuildHud(runtime, definition, username, dead)
    local Timer = KIPN.Server.EventTimerService
    local hud = {
        title = tostring(definition.name or "Event") .. "  |  " .. modeLabel(definition),
        lines = {},
        eventLeftMs = Timer.GetRemainingEventMs(runtime),
    }
    hud.clues = cluesFor(runtime, username)
    local round = runtime.round
    local usesRounds = KIPN.Server.EventScenarioRuntimeRegistry.UsesRounds(definition)
    if round and usesRounds then
        hud.round, hud.maxRounds = round.current, round.maximum
        if round.state == "ACTIVE" then
            hud.roundLeftMs = Timer.GetRemainingRoundMs(runtime)
        elseif runtime.gameLoop and runtime.gameLoop.nextRoundAtMs then
            hud.phase = "Round " .. (round.current + 1) .. " starts in"
            hud.phaseLeftMs = math.max(0, runtime.gameLoop.nextRoundAtMs - now())
        end
    end
    local function line(text) hud.lines[#hud.lines + 1] = text end

    local team = teamOf(definition, username)
    if team then
        hud.teamName, hud.color = team.name, colorList(team.color)
    end

    if dead then
        hud.goal = "You fell. You can still watch; you are out of this event."
        return hud
    end

    local mode = definition.mode
    local hotspots = KIPN.Server.EventHotspotService
    local activeRound = round and round.state == "ACTIVE"

    if mode == "KING_OF_THE_HILL" then
        local hill = activeRound and hotspots.FindById(definition, round.hotspotId)
        local state = runtime.kothState or {}
        hud.goal = activeRound and "Hold the hill. Only a team standing on it alone scores time." or "Get ready: the next hill is about to be revealed."
        if hill then hud.target = { x = center(hill).x, y = center(hill).y, label = "Hill" } end
        local holder = state.currentControllerTeamId
        if activeRound then
            line(holder == "CONTESTED" and "The hill is CONTESTED" or holder and ("Held by " .. teamName(definition, holder)) or "Nobody holds the hill")
        end
        for _, t in ipairs(definition.teams or {}) do
            line(t.name .. ": " .. (state.teamRoundWins and state.teamRoundWins[t.id] or 0) .. " rounds, "
                .. seconds(((state.roundControlSeconds or {})[t.id] or 0) * 1000) .. " on this hill")
        end
    elseif mode == "CAPTURE" then
        local capture = runtime.captureState or { items = {} }
        local carrying, enemyFlag, neutralFlag
        for _, entry in pairs(capture.items or {}) do
            if entry.state ~= "DELIVERED" then
                if entry.carrierUsername == username then carrying = entry end
                if capture.variant == "TEAM_CTF" and team and entry.teamId ~= team.id then enemyFlag = entry end
                if capture.variant ~= "TEAM_CTF" then neutralFlag = entry end
            end
        end
        local function flagTarget(entry, label)
            if not entry then return nil end
            if entry.state == "CARRIED" and entry.carrierUsername then
                for _, other in ipairs(Loop.OnlineParticipants(runtime)) do
                    if other.username == entry.carrierUsername then
                        return { x = math.floor(other.player:getX()), y = math.floor(other.player:getY()), label = label .. " (" .. entry.carrierUsername .. ")" }
                    end
                end
            end
            local point = entry.lastKnownPosition
            return point and { x = point.x, y = point.y, label = label } or nil
        end
        if capture.variant == "TEAM_CTF" then
            if carrying then
                hud.goal = "You have the enemy flag! Run it back to your base."
                local base = team and hotspots.FindHotspot(definition, "TEAM_BASE", round and round.current, team.id)
                if base then hud.target = { x = center(base).x, y = center(base).y, label = "Your base" } end
            else
                hud.goal = activeRound and "Steal the enemy flag and bring it to your base. Guard your own." or "Get ready: flags appear when the round starts."
                hud.target = activeRound and flagTarget(enemyFlag, "Enemy flag") or nil
            end
            for _, t in ipairs(definition.teams or {}) do line(t.name .. ": " .. (capture.teamRoundWins[t.id] or 0) .. " captures") end
        else
            if carrying then
                hud.goal = "You have the flag! Get it to the delivery point."
                local drop = hotspots.FindHotspot(definition, "DELIVERY_POINT", round and round.current, nil)
                if drop then hud.target = { x = center(drop).x, y = center(drop).y, label = "Delivery point" } end
            else
                hud.goal = activeRound and "Grab the flag and carry it to the delivery point. Take it off whoever has it." or "Get ready: the flag appears when the round starts."
                hud.target = activeRound and flagTarget(neutralFlag, "Flag") or nil
            end
            local best = {}
            for name, wins in pairs(capture.playerRoundWins or {}) do best[#best + 1] = { name = name, wins = wins } end
            table.sort(best, function(a, b) return a.wins > b.wins end)
            for index = 1, math.min(3, #best) do line(best[index].name .. ": " .. best[index].wins .. " captures") end
            if #best == 0 then line("No captures yet") end
        end
    elseif mode == "CHASE" then
        local target = runtime.objectiveState and runtime.objectiveState.chaseTarget
        local ping = runtime.chaseState and runtime.chaseState.targetPing
        if not activeRound then
            hud.goal = "Get ready: the next target is picked when the round starts."
        elseif target == username then
            hud.goal = "You are the TARGET. Stay alive until the round ends."
            hud.color = { 1.0, 0.42, 0.42 }
            line("Hunters see where you were every " .. math.floor(Loop.CHASE_PING_MS / 1000) .. " seconds. Keep moving.")
        else
            hud.goal = "Hunt down " .. tostring(target or "the target") .. " before the round ends."
            if ping then
                hud.target = { x = ping.x, y = ping.y, label = tostring(target) .. " seen " .. math.floor((now() - ping.atMs) / 1000) .. "s ago" }
            end
        end
        local wins = runtime.chaseState and runtime.chaseState.playerRoundWins or {}
        line("Your points: " .. (wins[username] or 0))
    elseif mode == "SURVIVOR_RUN" then
        hud.goal = "Stay alive until the timer runs out. Everyone still standing wins."
        local alive, total = 0, 0
        for name in pairs(runtime.participants or {}) do
            total = total + 1
            if not (runtime.deaths and runtime.deaths[name]) then alive = alive + 1 end
        end
        line(alive .. " of " .. total .. " survivors still standing")
    elseif mode == "OLYMPICS" then
        local olympics = KIPN.Server.EventOlympicsService
        if olympics and olympics.BuildHud then olympics.BuildHud(runtime, definition, username, hud) end
    elseif mode == "EXTRACTION" then
        local extraction = KIPN.Server.EventExtractionService
        if extraction and extraction.BuildHud then extraction.BuildHud(runtime, definition, username, hud) end
    else
        local notes = definition.objectiveNotes or {}
        hud.goal = (notes[1] and notes[1].text) or "Follow the event staff's instructions."
        for index = 2, math.min(4, #notes) do line(notes[index].text) end
    end

    -- An authored story stage adds its name as the current step.
    local story = runtime.storyState
    if story and story.activeObjectiveId then
        for _, stage in ipairs(definition.objectives or {}) do
            if stage.id == story.activeObjectiveId and stage.name and stage.name ~= "" then line("Now: " .. stage.name) end
        end
    end
    return hud
end

------------------------------------------------------------
-- ENTRY POINTS
------------------------------------------------------------

function Loop.Tick(runtime, definition)
    runtime.gameLoop = runtime.gameLoop or {}
    local state = runtime.gameLoop
    if not state.welcomed then
        state.welcomed = true
        Loop.Announce(runtime, tostring(definition.name or "The event") .. " has begun!", GOLD)
    end
    tickRounds(runtime, definition, state)
    tickChasePing(runtime, definition)
    for _, entry in ipairs(Loop.OnlineParticipants(runtime)) do
        local ok, hud = pcall(Loop.BuildHud, runtime, definition, entry.username, entry.dead)
        if ok and hud then sendHud(entry.player, hud) else log("BuildHud failed: " .. tostring(hud)) end
    end
end

-- Sends one participant their HUD now instead of on the next tick.
function Loop.RefreshHud(runtime, definition, username)
    for _, entry in ipairs(Loop.OnlineParticipants(runtime)) do
        if entry.username == username then
            local ok, hud = pcall(Loop.BuildHud, runtime, definition, username, entry.dead)
            if ok and hud then sendHud(entry.player, hud) end
        end
    end
end

-- Who won, in one sentence.
function Loop.ResultText(runtime, definition, outcome)
    if runtime.olympicsState and KIPN.Server.EventOlympicsService then
        return KIPN.Server.EventOlympicsService.ResultText(runtime)
    end
    local names = {}
    for username in pairs(runtime.winners or {}) do names[#names + 1] = username end
    table.sort(names)
    if outcome == "FAIL" or #names == 0 then
        if outcome == "MANUAL" or outcome == "LOST" then return "The event was ended by staff.", RED end
        return "Nobody won this time.", RED
    end
    -- All winners on one team: name the team.
    if #(definition.teams or {}) > 0 then
        local teamId = KIPN.Server.EventTeamService.GetPlayerTeam(definition, names[1])
        local sameTeam = teamId ~= nil
        for _, name in ipairs(names) do
            if KIPN.Server.EventTeamService.GetPlayerTeam(definition, name) ~= teamId then sameTeam = false end
        end
        if sameTeam then
            local name, color = teamName(definition, teamId)
            return name .. " wins!", colorList(color) or GOLD
        end
    end
    local shown = {}
    for index = 1, math.min(5, #names) do shown[index] = names[index] end
    local text = table.concat(shown, ", ") .. (#names > 5 and (" and " .. (#names - 5) .. " more") or "")
    return (#names == 1 and "Winner: " or "Winners: ") .. text, GOLD
end

-- Called by stopEvent before participants are released.
function Loop.Finish(runtime, definition, outcome)
    local text, color = Loop.ResultText(runtime, definition, outcome)
    for _, entry in ipairs(Loop.OnlineParticipants(runtime)) do
        local mine = runtime.winners and runtime.winners[entry.username]
        sendHud(entry.player, {
            ended = true,
            title = tostring(definition.name or "Event") .. "  |  " .. modeLabel(definition),
            banner = (mine and "You won! " or "") .. text,
            bannerColor = mine and GREEN or color,
            goal = text,
        })
    end
    -- Past events in the Studio (KIPN_EventHistoryService.lua).
    local history = KIPN.Server.EventHistoryService
    if history then pcall(history.Record, definition, outcome, text, runtime) end
    log("Finish() -> " .. tostring(outcome) .. ": " .. text)
end

log("module loaded")
