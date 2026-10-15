require "BonkZone/BonkZone_Constants"
require "BonkZone/BonkZone_Logger"
require "BonkZone/BonkZone_Registry"

BonkZone = BonkZone or {}
BonkZone.Network = BonkZone.Network or {}

local Network = BonkZone.Network
local Constants = BonkZone.Constants
local Logger = BonkZone.Logger
local Registry = BonkZone.Registry

Network.LastSyncRequestMs = Network.LastSyncRequestMs or 0
Network.LastBlockedHaloMs = Network.LastBlockedHaloMs or 0

local function send(command, args)
    local startedAt = Logger.Begin("Network.send", { command = command })
    args = type(args) == "table" and args or {}
    if isClient() then
        sendClientCommand(Constants.MODULE, command, args)
        Logger.Finish("Network.send", startedAt, true, "sent to server")
        return true
    end
    if BonkZone.Server and BonkZone.Storage then
        local player = getPlayer and getPlayer() or nil
        local username = player and player.getUsername and player:getUsername() or "local"
        local result, errorMessage
        if command == Constants.Commands.ADD_ZONE then
            result, errorMessage = BonkZone.Storage.AddZone(args.name, args.x1, args.y1, args.x2, args.y2, username)
        elseif command == Constants.Commands.UPDATE_ZONE then
            result, errorMessage = BonkZone.Storage.UpdateBounds(args.id, args.x1, args.y1, args.x2, args.y2, username)
        elseif command == Constants.Commands.RENAME_ZONE then
            result, errorMessage = BonkZone.Storage.RenameZone(args.id, args.name, username)
        elseif command == Constants.Commands.REMOVE_ZONE then
            result, errorMessage = BonkZone.Storage.RemoveZone(args.id, username)
        end
        if result then
            BonkZone.Storage.RefreshSharedRegistry()
            BonkZone.Server.BroadcastSync()
        elseif errorMessage then
            Logger.Warn("Network", "local operation failed", { command = command, message = errorMessage })
        end
        Logger.Finish("Network.send", startedAt, result ~= nil and result ~= false, "local route")
        return result ~= nil and result ~= false
    end
    Logger.Warn("Network", "command unavailable outside multiplayer", { command = command })
    Logger.Finish("Network.send", startedAt, false, "no route")
    return false
end

function Network.RequestSync(force)
    local startedAt = Logger.Begin("Network.RequestSync", { force = force })
    local now = Constants.NowMs()
    if not force and now - Network.LastSyncRequestMs < 1000 then
        Logger.Finish("Network.RequestSync", startedAt, true, "throttled")
        return
    end
    Network.LastSyncRequestMs = now
    if isClient() then
        send(Constants.Commands.REQUEST_SYNC, {})
    elseif BonkZone.Storage then
        Registry.ReplaceAll(BonkZone.Storage.GetPublicZones(), BonkZone.Storage.GetRevision())
    end
    Logger.Finish("Network.RequestSync", startedAt, true)
end

function Network.AddZone(name, x1, y1, x2, y2)
    local startedAt = Logger.Begin("Network.AddZone", { name = name })
    local result = send(Constants.Commands.ADD_ZONE, { name = name, x1 = x1, y1 = y1, x2 = x2, y2 = y2 })
    Logger.Finish("Network.AddZone", startedAt, result)
    return result
end

function Network.UpdateZone(id, x1, y1, x2, y2)
    local startedAt = Logger.Begin("Network.UpdateZone", { id = id })
    local result = send(Constants.Commands.UPDATE_ZONE, { id = id, x1 = x1, y1 = y1, x2 = x2, y2 = y2 })
    Logger.Finish("Network.UpdateZone", startedAt, result)
    return result
end

function Network.RenameZone(id, name)
    local startedAt = Logger.Begin("Network.RenameZone", { id = id, name = name })
    local result = send(Constants.Commands.RENAME_ZONE, { id = id, name = name })
    Logger.Finish("Network.RenameZone", startedAt, result)
    return result
end

function Network.RemoveZone(id)
    local startedAt = Logger.Begin("Network.RemoveZone", { id = id })
    local result = send(Constants.Commands.REMOVE_ZONE, { id = id })
    Logger.Finish("Network.RemoveZone", startedAt, result)
    return result
end

local function showBlockedHalo()
    local player = getPlayer and getPlayer() or nil
    if not player or not HaloTextHelper then return end
    local now = Constants.NowMs()
    if now - Network.LastBlockedHaloMs < Constants.MESSAGE_COOLDOWN_MS then return end
    Network.LastBlockedHaloMs = now
    HaloTextHelper.addBadText(player, getText("IGUI_BonkZone_RangedBlocked"))
end

function Network.OnServerCommand(module, command, args)
    local startedAt = Logger.Begin("Network.OnServerCommand", { module = module, command = command })
    if module ~= Constants.MODULE then
        Logger.Finish("Network.OnServerCommand", startedAt, true, "ignored module")
        return
    end
    args = type(args) == "table" and args or {}
    if command == Constants.Commands.SYNC then
        Registry.ReplaceAll(args.zones or {}, args.revision)
    elseif command == Constants.Commands.SHOW_BLOCKED then
        showBlockedHalo()
    elseif command == Constants.Commands.OPERATION_RESULT and args.ok ~= true then
        local player = getPlayer and getPlayer() or nil
        if player and HaloTextHelper then
            HaloTextHelper.addBadText(player, getText("IGUI_BonkZone_OperationFailed", tostring(args.message or "Unknown error.")))
        end
        Logger.Warn("Network", "operation failed", { operation = args.operation, message = args.message })
    end
    Logger.Finish("Network.OnServerCommand", startedAt, true)
end

function Network.OnConnected()
    local startedAt = Logger.Begin("Network.OnConnected")
    Network.RequestSync(true)
    Logger.Finish("Network.OnConnected", startedAt, true)
end

function Network.OnCreatePlayer(playerIndex, player)
    local startedAt = Logger.Begin("Network.OnCreatePlayer", { playerIndex = playerIndex })
    if playerIndex == 0 then Network.RequestSync(true) end
    Logger.Finish("Network.OnCreatePlayer", startedAt, true)
end

Events.OnServerCommand.Add(Network.OnServerCommand)
Events.OnConnected.Add(Network.OnConnected)
Events.OnCreatePlayer.Add(Network.OnCreatePlayer)
Events.OnGameStart.Add(function()
    local startedAt = Logger.Begin("Network.OnGameStart")
    Network.RequestSync(true)
    Logger.DumpMetaTimeRunLog("client initialization")
    Logger.Finish("Network.OnGameStart", startedAt, true)
end)

return Network
