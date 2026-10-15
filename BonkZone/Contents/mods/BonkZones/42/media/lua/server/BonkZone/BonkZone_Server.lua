require "BonkZone/BonkZone_Constants"
require "BonkZone/BonkZone_Logger"
require "BonkZone/BonkZone_Registry"
require "BonkZone/Storage/BonkZone_Storage"

BonkZone = BonkZone or {}
BonkZone.Server = BonkZone.Server or {}

local Server = BonkZone.Server
local Constants = BonkZone.Constants
local Logger = BonkZone.Logger
local Storage = BonkZone.Storage

Server.Initialized = Server.Initialized or false

local function getUsername(player)
    local startedAt = Logger.Begin("Server.getUsername")
    local username = player and tostring(player:getUsername() or "") or ""
    Logger.Finish("Server.getUsername", startedAt, true, { username = username })
    return username
end

local function canManageZones(player)
    local startedAt = Logger.Begin("Server.canManageZones")
    if not player then
        Logger.Finish("Server.canManageZones", startedAt, false, "missing player")
        return false
    end
    -- Admin-only: the server account access level "admin", or a custom role explicitly
    -- granted the vanilla Non-PVP zone capability. No looser moderator/gm/observer bypass.
    local allowed = false
    if player.getAccessLevel then
        local level = string.lower(tostring(player:getAccessLevel() or ""))
        allowed = level == "admin"
    end
    if not allowed and player.getRole and Capability and Capability.CanSetupNonPVPZone then
        local ok, result = pcall(function()
            local role = player:getRole()
            return role and role:hasCapability(Capability.CanSetupNonPVPZone)
        end)
        allowed = ok and result == true
    end
    Logger.Finish("Server.canManageZones", startedAt, true, { allowed = allowed, player = getUsername(player) })
    return allowed
end

local function sendToPlayer(player, command, payload)
    local startedAt = Logger.Begin("Server.sendToPlayer", { command = command })
    if isServer() and player then
        sendServerCommand(player, Constants.MODULE, command, payload or {})
        Logger.Finish("Server.sendToPlayer", startedAt, true)
        return true
    end
    Logger.Finish("Server.sendToPlayer", startedAt, false, "not dedicated/client-server context")
    return false
end

function Server.SendSync(player)
    local startedAt = Logger.Begin("Server.SendSync", { player = getUsername(player) })
    local payload = { zones = Storage.GetPublicZones(), revision = Storage.GetRevision() }
    if isServer() then
        sendToPlayer(player, Constants.Commands.SYNC, payload)
    else
        BonkZone.Registry.ReplaceAll(payload.zones, payload.revision)
    end
    Logger.Finish("Server.SendSync", startedAt, true, { count = #payload.zones })
end

function Server.BroadcastSync()
    local startedAt = Logger.Begin("Server.BroadcastSync")
    local payload = { zones = Storage.GetPublicZones(), revision = Storage.GetRevision() }
    if isServer() then
        local players = getOnlinePlayers()
        for index = 0, players:size() - 1 do
            sendToPlayer(players:get(index), Constants.Commands.SYNC, payload)
        end
    else
        BonkZone.Registry.ReplaceAll(payload.zones, payload.revision)
    end
    Logger.Info("Server", "zone state broadcast", { count = #payload.zones, revision = payload.revision })
    Logger.Finish("Server.BroadcastSync", startedAt, true)
end

local function sendOperationResult(player, ok, operation, message)
    local startedAt = Logger.Begin("Server.sendOperationResult", { operation = operation, ok = ok })
    if isServer() then
        sendToPlayer(player, Constants.Commands.OPERATION_RESULT, {
            ok = ok == true,
            operation = tostring(operation or ""),
            message = tostring(message or ""),
        })
    end
    Logger.Finish("Server.sendOperationResult", startedAt, true)
end

local function mutate(player, operation, callback)
    local startedAt = Logger.Begin("Server.mutate", { operation = operation })
    if not canManageZones(player) then
        Logger.Warn("Server", "unauthorized zone mutation rejected", { operation = operation, player = getUsername(player) })
        sendOperationResult(player, false, operation, "Permission denied.")
        Logger.Finish("Server.mutate", startedAt, false, "permission denied")
        return
    end
    local ok, result, errorMessage = pcall(callback)
    if not ok then
        errorMessage = tostring(result)
        result = nil
    end
    local succeeded = ok and result ~= nil and result ~= false
    if succeeded then
        Storage.RefreshSharedRegistry()
        Server.BroadcastSync()
        sendOperationResult(player, true, operation, "")
    else
        Logger.Warn("Server", "zone mutation rejected", { operation = operation, error = errorMessage })
        sendOperationResult(player, false, operation, errorMessage or "Unknown error.")
    end
    Logger.Finish("Server.mutate", startedAt, succeeded, { error = errorMessage })
end

function Server.OnClientCommand(module, command, player, args)
    local startedAt = Logger.Begin("Server.OnClientCommand", { module = module, command = command })
    if module ~= Constants.MODULE then
        Logger.Finish("Server.OnClientCommand", startedAt, true, "ignored module")
        return
    end
    args = type(args) == "table" and args or {}
    if command == Constants.Commands.REQUEST_SYNC then
        Server.SendSync(player)
    elseif command == Constants.Commands.ADD_ZONE then
        mutate(player, command, function()
            return Storage.AddZone(args.name, args.x1, args.y1, args.x2, args.y2, getUsername(player))
        end)
    elseif command == Constants.Commands.UPDATE_ZONE then
        mutate(player, command, function()
            return Storage.UpdateBounds(args.id, args.x1, args.y1, args.x2, args.y2, getUsername(player))
        end)
    elseif command == Constants.Commands.RENAME_ZONE then
        mutate(player, command, function()
            return Storage.RenameZone(args.id, args.name, getUsername(player))
        end)
    elseif command == Constants.Commands.REMOVE_ZONE then
        mutate(player, command, function()
            return Storage.RemoveZone(args.id, getUsername(player))
        end)
    else
        Logger.Warn("Server", "unknown command rejected", { command = command, player = getUsername(player) })
    end
    Logger.Finish("Server.OnClientCommand", startedAt, true)
end

function Server.Initialize()
    local startedAt = Logger.Begin("Server.Initialize")
    if Server.Initialized then
        Logger.Finish("Server.Initialize", startedAt, true, "already initialized")
        return
    end
    Server.Initialized = true
    Storage.Initialize()
    Storage.RefreshSharedRegistry()
    Logger.Info("Server", "initialized", { zones = #Storage.GetPublicZones(), revision = Storage.GetRevision() })
    Logger.DumpMetaTimeRunLog("server initialization")
    Logger.Finish("Server.Initialize", startedAt, true)
end

function Server.OnSave()
    local startedAt = Logger.Begin("Server.OnSave")
    Logger.Info("Server", "world save observed", { revision = Storage.GetRevision(), zones = #Storage.GetPublicZones() })
    Logger.DumpMetaTimeRunLog("world save")
    Logger.Finish("Server.OnSave", startedAt, true)
end

Events.OnClientCommand.Add(Server.OnClientCommand)
Events.OnServerStarted.Add(Server.Initialize)
Events.OnSave.Add(Server.OnSave)

if not isClient() then
    Events.OnGameStart.Add(Server.Initialize)
end

return Server

