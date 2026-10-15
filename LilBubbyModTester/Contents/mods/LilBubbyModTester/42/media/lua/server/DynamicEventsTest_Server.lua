require "LilBubbyPacer"
require "DynamicEventsTest_World"

-- Multiplayer half of the Dynamic Events suite: runs World ops for clients.
-- Open to every player. Dynamic Events itself only lets staff make and run
-- events, so the ops that do run with World.AsStaff: the server acts as staff
-- for the player, on the tester's own events only. Every argument is checked.
local T = DynamicEventsTest
local MODULE = T.MODULE
local World = T.World
local OPS = { setup = true, state = true, act = true, check = true, cleanup = true }
local STAFF_OPS = { setup = true, act = true, cleanup = true }
-- One-shot checks that make events need staff rights too.
local STAFF_CHECKS = { validation = true, adventure = true, fire = true, laststanding = true }
local KINDS = { survivor = true, capture = true, ctf = true, koth = true, chase = true, extraction = true,
    prison = true, firesale = true, olympics = true, clues = true, threats = true,
    bandits = true, raid = true, heist = true, prepared = true }
local ACTIONS = { call = true, takeFlag = true, give = true, takeLoad = true, killTargets = true, stop = true,
    raid = true, takeGold = true, simTrack = true, simLeftovers = true, move = true,
    hostSim = true, hostStep = true, hostEnd = true }
local CALLS = { EVENT_VALIDATE = true, EVENT_ANNOUNCE = true, EVENT_OPEN_JOINING = true, EVENT_START = true,
    EVENT_STOP = true, EVENT_RESET = true, EVENT_DELETE_DEFINITION = true, EVENT_GET_STATUS = true,
    EVENT_DIRECTOR_EXECUTE = true, EVENT_LIST_REWARDS = true, EVENT_MARK_REWARD_DELIVERED = true,
    EVENT_ACCEPT_PARTICIPATION = true,
    -- Prepared-event actions and the simulation.
    EVENT_QUICK_START = true, EVENT_CANCEL = true, EVENT_SEND_ANNOUNCEMENT = true, EVENT_SIMULATE = true,
    EVENT_SIMULATE_STEP = true, EVENT_UPDATE_DEFINITION = true, EVENT_UPSERT_HOTSPOT = true, EVENT_LIST_HISTORY = true }
-- Items the test may hand out.
local GIVABLE = { ["Base.Log"] = true, ["Base.Plank"] = true }

local function valid(command, args)
    if command == "setup" then
        return KINDS[args.kind] == true and (args.seconds == nil or (type(args.seconds) == "number" and args.seconds >= 10 and args.seconds <= 600))
            and (args.loadout == nil or type(args.loadout) == "string")
    elseif command == "state" then
        return type(args.id) == "string"
    elseif command == "act" then
        if type(args.id) ~= "string" or not ACTIONS[args.what] then return false end
        -- Only ever the tester's own events, never a real one.
        local def = KIPN.Server.EventScenarioService.GetDefinition(args.id)
        if not def or tostring(def.name):sub(1, #T.PREFIX) ~= T.PREFIX then return false end
        if args.what == "call" then return CALLS[args.command] == true end
        if args.what == "give" then return GIVABLE[args.item] == true end
        if args.what == "move" then return type(args.dx) == "number" and math.abs(args.dx) <= 60 end
        return true
    elseif command == "check" then
        return type(args.name) == "string" and World.checks[args.name] ~= nil
    end
    return true
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE or not player or not OPS[command] then return end
    args = type(args) == "table" and args or {}
    if T.available() then World.Staff() end
    local reply = { op = command, id = args.id, requestId = args.requestId }
    local staff = STAFF_OPS[command] or (command == "check" and STAFF_CHECKS[args.name])
    if not T.available() or not (KIPN.Server and KIPN.Server.EventRuntimeService) then
        reply.error = "Dynamic Events is not enabled on this server."
    elseif not valid(command, args) then
        reply.error = "Invalid " .. command .. " request."
    else
        -- Queued behind this player's previous request, never refused for speed.
        LilBubbyPacer.Run(player, MODULE, 50, function()
            local ok, result
            if staff then
                ok, result = World.AsStaff(player, World[command], player, args)
            else
                ok, result = pcall(World[command], player, args)
            end
            if ok then
                for key, value in pairs(result or {}) do reply[key] = value end
            else
                reply.error = tostring(result)
            end
            sendServerCommand(player, MODULE, "reply", reply)
        end)
        return
    end
    sendServerCommand(player, MODULE, "reply", reply)
end)

-- The mod's own windows send commands too (the simulation panel, the Studio),
-- so the stand-in is put up as soon as Dynamic Events' services exist.
local function staff()
    if T.available() and World.Staff() then Events.EveryOneMinute.Remove(staff) end
end
Events.EveryOneMinute.Add(staff)
