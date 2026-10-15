require "SVSBT_Service"

if type(isClient) == "function" and isClient() and not isServer() then
    return
end

SVSBT.Server = SVSBT.Server or {}
local Server = SVSBT.Server
local Service = Server.Service
local Shared = SVSBT.Shared
local Logger = SVSBT.Logger

Server.Initialized = Server.Initialized == true

local function humanize(reason)
    local run = Logger.Begin("Server.humanize", reason)
    reason = tostring(reason or "UNKNOWN_ERROR")

    -- Reasons that are already a written sentence (spaces + lower-case) pass through.
    if reason:find(" ") and reason:find("%l") then
        Logger.Finish(run, true, reason)
        return reason
    end

    local value = string.lower(reason:gsub("_", " "))
    value = string.upper(string.sub(value, 1, 1)) .. string.sub(value, 2) .. "."
    Logger.Finish(run, true, value)
    return value
end

function Server.Send(player, response, data)
    local run = Logger.Begin("Server.Send", response)
    local result = false

    if type(isServer) == "function" and isServer() and type(sendServerCommand) == "function" then
        sendServerCommand(player, Shared.Module, response, data or {})
        result = true
    elseif type(triggerEvent) == "function" then
        triggerEvent("OnServerCommand", Shared.Module, response, data or {})
        result = true
    end

    Logger.Finish(run, result, "sent=" .. tostring(result))
    return result
end

local Handlers = {
    ACTION_BEGIN = Service.BeginTimedAction,
    PLACE_FLOOR = Service.PlaceFloorTrap,
    PLACE_TRIP_WIRE = Service.PlaceTripWire,
    RIG_MAILBOX = Service.RigMailbox,
    INSTALL_VEHICLE = Service.InstallVehicleDevice,
    CONTAMINATE_DOCUMENT = Service.ContaminateDocument,
    CONTROLLER_COMMAND = Service.ControllerCommand,
    SYNC_CONTROLLER = Service.SyncController,
    MAILBOX_ACCESSED = Service.MailboxAccessed,
    DOCUMENT_OPENED = Service.DocumentOpened,
    LEARN_RECIPES = Service.LearnRecipes,
    OPEN_BIOLOGICAL_AGENT = Service.OpenBiologicalAgent,
    NEUTRALIZE_BIOLOGICAL_AGENT = Service.NeutralizeBiologicalAgent,
    VEHICLE_CONTAINER_ACCESSED = Service.VehicleContainerAccessed,
    VEHICLE_MECHANICS_OPENED = Service.VehicleMechanicsOpened,
    INSPECT = Service.Inspect,
    DISARM = Service.Disarm,
    RESET_BEAR = Service.ResetBearTrap,
    REPAIR_BEAR = Service.RepairBearTrap,
    FREE_BEAR = Service.FreeBearTrap,
    BEAR_TRAP_ESCAPE_ATTEMPT = Service.BearTrapEscapeAttempt,
    RF_SCAN = Service.RFScan,
    REQUEST_VISIBLE = function(player, _args)
        if not Service.ClaimVisibleRequest(player) then return nil, "REQUEST_COOLDOWN_ACTIVE" end
        return Service.VisibleSnapshot(player)
    end,
    ADMIN_REMOVE_RADIUS = Service.AdminRemoveRadius,
    TRAP_GRABBED = Service.TrapGrabbed,
}

function Server.HandleCommand(moduleName, command, player, args)
    local run = Logger.Begin("Server.HandleCommand", command)

    if moduleName ~= Shared.Module then
        Logger.Finish(run, true, "foreign module ignored")
        return false
    end

    if not player then
        Logger.Finish(run, false, "PLAYER_REQUIRED")
        return false
    end

    Server.Initialize()
    local handler = Handlers[tostring(command)]

    if type(handler) ~= "function" then
        Server.Send(player, "ERROR", {
            command = command,
            reason = "UNKNOWN_COMMAND",
            message = "Unknown booby-trap command.",
        })
        Logger.Finish(run, false, "UNKNOWN_COMMAND")
        return false
    end

    if Service.RequiresTimedAction(command) then
        local verified, verifyReason = Service.ConsumeTimedAction(player, command, args or {})
        if not verified then
            local failure = tostring(verifyReason or "TIMED_ACTION_HANDSHAKE_REQUIRED")
            Server.Send(player, "ERROR", { command = command, reason = failure, message = humanize(failure) })
            Logger.Finish(run, false, failure)
            return false
        end
    end

    local ok, result, reason = pcall(handler, player, args or {})

    if not ok then
        Logger.Error("Server.HandleCommand", "unhandled error | command=" .. tostring(command) .. " | error=" .. tostring(result))
        Server.Send(player, "ERROR", {
            command = command,
            reason = "SERVER_HANDLER_ERROR",
            message = "The authoritative trap handler failed safely.",
        })
        Logger.Finish(run, false, "SERVER_HANDLER_ERROR")
        return false
    end

    if result == nil then
        local failure = tostring(reason or "REQUEST_DENIED")
        Server.Send(player, "ERROR", {
            command = command,
            reason = failure,
            message = humanize(failure),
        })
        Logger.Finish(run, false, failure)
        return false
    end

    local response = command == "REQUEST_VISIBLE" and "VISIBLE" or "ACTION_RESULT"
    Server.Send(player, response, result)
    Logger.Finish(run, true, "response=" .. response)
    return true
end

local function safeCommand(moduleName, command, player, args)
    local run = Logger.Begin("Server.safeCommand", command)
    local ok, result = pcall(Server.HandleCommand, moduleName, command, player, args)

    if not ok then
        Logger.Error("Server.safeCommand", tostring(result))
        Logger.Finish(run, false, result)
        return
    end

    Logger.Finish(run, true, "handled=" .. tostring(result))
end

local tickBackoffUntilMs = 0
local tickFailureCount = 0

local function safeTick()
    local nowMs = type(getTimestampMs) == "function" and getTimestampMs() or 0

    -- A failing tick must never turn into a per-frame exception + log storm.
    if nowMs < tickBackoffUntilMs then
        return
    end

    local run = Logger.Begin("Server.safeTick")
    local ok, result = pcall(Service.Tick, false)

    if not ok then
        tickFailureCount = tickFailureCount + 1
        tickBackoffUntilMs = nowMs + 30000
        if tickFailureCount <= 3 then
            Logger.Error("Server.safeTick", tostring(result) .. " | backing off 30s")
        end
        Logger.Finish(run, false, result)
        return
    end

    if tickFailureCount > 0 then
        Logger.Info("Server.safeTick", "recovered after " .. tostring(tickFailureCount) .. " failure(s)")
        tickFailureCount = 0
    end
    Logger.Finish(run, true, "changed=" .. tostring(result))
end

local function safePlayerDeath(player)
    local run = Logger.Begin("Server.safePlayerDeath", Shared.Username(player))
    local ok, result = pcall(Service.OwnerDied, player)

    if not ok then
        Logger.Error("Server.safePlayerDeath", tostring(result))
        Logger.Finish(run, false, result)
        return
    end

    Logger.Finish(run, true, "removed=" .. tostring(result))
end

function Server.Initialize()
    local run = Logger.Begin("Server.Initialize")

    if Server.Initialized then
        Logger.Finish(run, true, "already initialized")
        return true
    end

    Service.Initialize()
    Server.Initialized = true
    Logger.Info("Server.Initialize", "Spy vs Spy: Booby Traps server router initialized")
    Logger.Finish(run, true)
    return true
end

if Events and Events.OnClientCommand then Events.OnClientCommand.Add(safeCommand) end
if Events and Events.OnTick then Events.OnTick.Add(safeTick) end
if Events and Events.OnInitGlobalModData then Events.OnInitGlobalModData.Add(Server.Initialize) end
if Events and Events.OnServerStarted then Events.OnServerStarted.Add(Server.Initialize) end
if Events and Events.OnGameStart then Events.OnGameStart.Add(Server.Initialize) end
if Events and Events.OnPlayerDeath then Events.OnPlayerDeath.Add(safePlayerDeath) end

Logger.Info("SVSBT_Server.load", "server command boundaries registered")

return Server
