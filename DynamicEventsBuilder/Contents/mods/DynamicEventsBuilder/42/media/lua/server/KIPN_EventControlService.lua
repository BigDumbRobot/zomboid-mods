-- KIPN_EventControlService.lua
--
-- The four actions on a prepared event in the Event Studio:
--
--   Start <event>          EVENT_QUICK_START { id, signupSeconds }
--       READY: announces it, opens sign-ups (everyone online is asked)
--       and begins it after `signupSeconds`, with a countdown banner.
--       ANNOUNCED: opens sign-ups, then the same countdown.
--       JOINING: begins it now.
--   Simulate <event>       KIPN_EventSimulationService.lua
--   Announcements for <event>  EVENT_SEND_ANNOUNCEMENT { id, text }
--       A banner to everyone online (the briefing if no text is given).
--   Cancel <event>         EVENT_CANCEL { id }
--       Ends whatever is under way and steps the event back one stage:
--       a simulation or pending start is called off; a live, announced
--       or joining event is stopped and put back to Ready (kept in
--       Prepared events); a Ready event goes back to Draft for editing.
--
-- Each reply is an EVENT_ACTION_RESULT { id, action, success, text,
-- definition }, in words the Studio shows as they are. Every action
-- needs Studio access (admins, and staff levels the sandbox allows).

if isClient() and not isServer() then return end

require "KIPN_Shared"
require "DynamicEvents_Shared"
require "KIPN_EventAccessService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventControlService = KIPN.Server.EventControlService or {}

local Control = KIPN.Server.EventControlService

Control.DEFAULT_SIGNUP_SECONDS = 60
Control.MIN_SIGNUP_SECONDS = 10
Control.MAX_SIGNUP_SECONDS = 600
Control.COUNTDOWN_AT = { 300, 120, 60, 30, 10, 5, 4, 3, 2, 1 }
Control.pending = Control.pending or {}

local GOLD = { 1.0, 0.82, 0.3 }
local RED = { 1.0, 0.42, 0.42 }

local function log(message)
    print("[DYNAMIC EVENTS CONTROL] " .. tostring(message))
end

local function now()
    return (type(getTimestampMs) == "function" and getTimestampMs()) or 0
end

local function scenario() return KIPN.Server.EventScenarioService end

-- Admins, and staff levels the sandbox allows (KIPN_EventAccessService.lua).
local function requireAdmin(player)
    return KIPN.Server.EventAccessService.RequireStudio(player)
end

local function reply(player, id, action, success, text, definition)
    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ACTION_RESULT, {
        id = id, action = action, success = success == true, text = text, definition = definition,
    })
end

-- Runs another event command as `player` (its own reply goes to them too).
local function run(player, commandKey, args)
    local handler = KIPN.Server.GetCommandHandler and KIPN.Server.GetCommandHandler(KIPN.Shared.Commands[commandKey])
    if type(handler) ~= "function" then return false end
    local ok, err = pcall(handler, player, args)
    if not ok then log(commandKey .. " failed: " .. tostring(err)) end
    return ok
end

local function eachOnline(visit)
    local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    for i = 0, (online and online:size() or 0) - 1 do
        local p = online:get(i)
        if p then visit(p) end
    end
end

-- A banner on everyone's screen (the HUD shows a banner on its own
-- when the player is not in an event).
function Control.Broadcast(text, color, sound)
    if not text or text == "" then return 0 end
    local count = 0
    eachOnline(function(p)
        KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_PLAYER_HUD, { banner = text, bannerColor = color, bannerSound = sound })
        count = count + 1
    end)
    return count
end

local function simulation() return KIPN.Server.EventSimulationService end

local function simulating(id)
    local sim = simulation()
    return sim and sim.IsRunning and sim.IsRunning(id)
end

------------------------------------------------------------
-- START
------------------------------------------------------------

local function begin(player, id)
    local pending = Control.pending[id]
    Control.pending[id] = nil
    local definition = scenario().GetDefinition(id)
    if not definition or definition.status ~= scenario().Status.JOINING then return end
    local ok, reason = KIPN.Server.EventRuntimeService.StartEvent(player, definition)
    if ok then
        Control.Broadcast(tostring(definition.name) .. " has begun!", GOLD)
        reply(player, id, "start", true, definition.name .. " is live.", definition)
    else
        reply(player, id, "start", false, "Could not begin " .. tostring(definition.name) .. ": " .. tostring(reason), definition)
    end
    return ok, pending
end

local function handleQuickStart(player, args)
    if not requireAdmin(player) then return false end
    args = args or {}
    local definition = scenario().GetDefinition(args.id)
    if not definition then
        reply(player, args.id, "start", false, "That event no longer exists.")
        return true
    end
    local Status = scenario().Status
    if simulating(definition.id) then
        reply(player, definition.id, "start", false, "A simulation of this event is running. Finish or cancel it first.", definition)
        return true
    end
    if Control.pending[definition.id] then
        reply(player, definition.id, "start", false, "It is already counting down to its start.", definition)
        return true
    end
    local seconds = math.floor(tonumber(args.signupSeconds) or Control.DEFAULT_SIGNUP_SECONDS)
    seconds = math.max(Control.MIN_SIGNUP_SECONDS, math.min(Control.MAX_SIGNUP_SECONDS, seconds))

    if definition.status == Status.JOINING then
        begin(player, definition.id)
        return true
    end
    if definition.status == Status.READY then run(player, "EVENT_ANNOUNCE", { id = definition.id }) end
    if definition.status == Status.ANNOUNCED then run(player, "EVENT_OPEN_JOINING", { id = definition.id }) end
    if definition.status ~= Status.JOINING then
        local why = definition.status == Status.DRAFT and "It is still a draft: check it on the Launch step first."
            or definition.status == Status.ACTIVE and "It is already running."
            or ("It is " .. tostring(definition.status) .. ".")
        reply(player, definition.id, "start", false, "Could not start " .. tostring(definition.name) .. ". " .. why, definition)
        return true
    end
    Control.pending[definition.id] = { player = player, startAt = now() + seconds * 1000, shown = {} }
    Control.Broadcast("Sign up now: " .. tostring(definition.name) .. " begins in " .. seconds .. " seconds.", GOLD)
    reply(player, definition.id, "start", true, "Sign-ups are open. " .. definition.name .. " begins in " .. seconds .. " seconds.", definition)
    return true
end

function Control.Tick()
    local t = now()
    local due = {}
    for id, pending in pairs(Control.pending) do
        local left = math.ceil((pending.startAt - t) / 1000)
        if left <= 0 then
            due[#due + 1] = id
        else
            for _, mark in ipairs(Control.COUNTDOWN_AT) do
                if left <= mark and not pending.shown[mark] then
                    for _, other in ipairs(Control.COUNTDOWN_AT) do
                        if other >= mark then pending.shown[other] = true end
                    end
                    local definition = scenario().GetDefinition(id)
                    Control.Broadcast(tostring(definition and definition.name or "The event") .. " begins in " .. left .. "...", GOLD)
                    break
                end
            end
        end
    end
    for _, id in ipairs(due) do
        local pending = Control.pending[id]
        begin(pending.player, id)
    end
end

function Control.IsPending(id)
    return Control.pending[id] ~= nil
end

------------------------------------------------------------
-- CANCEL
------------------------------------------------------------

local function toReady(definition)
    definition.participants = {}
    definition.olympicsCountries = {}
    scenario().SetDefinitionStatus(definition.id, scenario().Status.READY)
end

-- Tells whoever signed up that it is off.
local function tellSignedUp(definition, text)
    eachOnline(function(p)
        if (definition.participants or {})[p:getUsername()] then
            KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_PLAYER_HUD, { banner = text, bannerColor = RED })
        end
    end)
end

local function handleCancel(player, args)
    if not requireAdmin(player) then return false end
    args = args or {}
    local definition = scenario().GetDefinition(args.id)
    if not definition then
        reply(player, args.id, "cancel", false, "That event no longer exists.")
        return true
    end
    local Status = scenario().Status
    local name = tostring(definition.name)
    local done = {}

    if simulating(definition.id) then
        simulation().Cancel(definition.id, "Cancelled by " .. tostring(player:getUsername()))
        done[#done + 1] = "simulation cancelled and cleaned up"
    end
    if Control.pending[definition.id] then
        Control.pending[definition.id] = nil
        done[#done + 1] = "start called off"
    end

    local status = definition.status
    if #done > 0 and (status == Status.READY or status == Status.DRAFT) then
        -- Only the simulation or countdown was under way.
    elseif status == Status.ACTIVE or status == Status.ENDING then
        KIPN.Server.EventRuntimeService.StopEvent(player, definition.id, "CANCELLED", "MANUAL")
        toReady(definition)
        done[#done + 1] = "stopped and put back to Ready"
    elseif status == Status.ANNOUNCED or status == Status.JOINING then
        tellSignedUp(definition, name .. " has been cancelled.")
        if KIPN.Server.EventHistoryService then
            KIPN.Server.EventHistoryService.Record(definition, "CANCELLED", "Cancelled before it began.", nil)
        end
        toReady(definition)
        done[#done + 1] = "sign-ups closed and put back to Ready"
    elseif status == Status.READY then
        scenario().SetDefinitionStatus(definition.id, Status.DRAFT)
        done[#done + 1] = "unlocked for editing (Draft)"
    elseif status == Status.COMPLETE then
        definition.participants = {}
        definition.olympicsCountries = {}
        scenario().SetDefinitionStatus(definition.id, Status.DRAFT)
        done[#done + 1] = "reset to Draft"
    end

    if #done == 0 then
        reply(player, definition.id, "cancel", false, name .. " is a draft with nothing under way.", definition)
    else
        KIPN.Server.AdminService.WriteAudit(player, "EVENT_CANCELLED", "eventDefinition", definition.id, { status = status })
        reply(player, definition.id, "cancel", true, name .. ": " .. table.concat(done, "; ") .. ".", definition)
    end
    return true
end

------------------------------------------------------------
-- ANNOUNCEMENTS
------------------------------------------------------------

local function handleSendAnnouncement(player, args)
    if not requireAdmin(player) then return false end
    args = args or {}
    local definition = scenario().GetDefinition(args.id)
    if not definition then
        reply(player, args.id, "announce", false, "That event no longer exists.")
        return true
    end
    if definition.status == scenario().Status.DRAFT then
        reply(player, definition.id, "announce", false, "Check the event on the Launch step first; drafts can't be announced.", definition)
        return true
    end
    local text = tostring(args.text or ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 500)
    if text == "" then
        text = (definition.narrative and definition.narrative.briefing ~= "" and definition.narrative.briefing)
            or (tostring(definition.name) .. " is coming soon.")
    end
    local count = Control.Broadcast(text, GOLD)
    KIPN.Server.AdminService.WriteAudit(player, "EVENT_ANNOUNCEMENT_SENT", "eventDefinition", definition.id, {})
    reply(player, definition.id, "announce", true, "Announced to " .. count .. " player" .. (count == 1 and "" or "s") .. ".", definition)
    return true
end

function Control.Initialize()
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_QUICK_START, handleQuickStart)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_CANCEL, handleCancel)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_SEND_ANNOUNCEMENT, handleSendAnnouncement)
    if Events.OnTick then Events.OnTick.Add(Control.Tick) end
    log("Initialize()")
    return true
end

return Control
