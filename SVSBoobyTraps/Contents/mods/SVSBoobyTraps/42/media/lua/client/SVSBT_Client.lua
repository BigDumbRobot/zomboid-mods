require "SVSBT_Config"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISRichTextPanel"

SVSBT.Client = SVSBT.Client or {}
local Client = SVSBT.Client
local Shared = SVSBT.Shared
local Config = SVSBT.Config
local Logger = SVSBT.Logger

Client.Visible = Client.Visible or {}
Client.KnownTraps = Client.KnownTraps or {}
Client.PendingInspection = Client.PendingInspection or nil
Client.LastKnowledgePruneMs = Client.LastKnowledgePruneMs or 0

function Client.PruneKnowledge(force)
    local current = type(getTimestampMs) == "function" and getTimestampMs() or 0
    if force ~= true and current - Client.LastKnowledgePruneMs < 10000 then return 0 end
    Client.LastKnowledgePruneMs = current
    local removed = 0

    for trapId, record in pairs(Client.KnownTraps) do
        if current - (tonumber(record.seenAtMs) or 0) > 300000 then
            Client.KnownTraps[trapId] = nil
            removed = removed + 1
        end
    end

    return removed
end

function Client.Notify(message, bad)
    local run = Logger.Begin("Client.Notify")
    local text = tostring(message or "Booby-trap notification.")
    local player = type(getPlayer) == "function" and getPlayer() or nil

    if player and HaloTextHelper then
        if bad and type(HaloTextHelper.addBadText) == "function" then
            HaloTextHelper.addBadText(player, text)
        elseif type(HaloTextHelper.addText) == "function" then
            HaloTextHelper.addText(player, text)
        elseif type(player.Say) == "function" then
            player:Say(text)
        end
    elseif player and type(player.Say) == "function" then
        player:Say(text)
    end

    Logger.Info("Client.Notify", text)
    Logger.Finish(run, true)
    return text
end

-- A plain, NON-modal report window. ISModalDialog pauses/captures input and, in
-- co-op, was leaving the mouse wheel routed to the camera ("scroll zooms only").
SVSBTReportWindow = ISPanel:derive("SVSBTReportWindow")

function SVSBTReportWindow:createChildren()
    ISPanel.createChildren(self)
    local body = ISRichTextPanel:new(6, 30, self.width - 12, self.height - 66)
    body.autosetheight = false
    body.background = false
    body.marginLeft, body.marginRight, body.marginTop = 4, 4, 2
    body:initialise()
    body:instantiate()
    body:setText(self.bodyText or "")
    body:addScrollBars()
    body:paginate()
    self:addChild(body)

    local close = ISButton:new((self.width - 90) / 2, self.height - 30, 90, 22, "Close", self, SVSBTReportWindow.onClose)
    close:initialise()
    self:addChild(close)
end

function SVSBTReportWindow:onClose()
    self:setVisible(false)
    self:removeFromUIManager()
end

function SVSBTReportWindow:prerender()
    ISPanel.prerender(self)
    self:drawText(self.titleText or "", 12, 10, 1, 1, 1, 1, UIFont.Medium)
end

function SVSBTReportWindow:new(x, y, w, h, titleText, bodyText)
    local o = ISPanel.new(self, x, y, w, h)
    o.titleText = titleText
    o.bodyText = bodyText
    o.moveWithMouse = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.85 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    return o
end

function Client.Report(title, lines)
    local run = Logger.Begin("Client.Report", title)
    lines = type(lines) == "table" and lines or { tostring(lines or "") }
    local width = 460
    local height = math.max(150, math.min(560, 90 + (#lines * 26)))
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2

    if Client.ReportWindow then
        pcall(function() Client.ReportWindow:removeFromUIManager() end)
    end

    local window = SVSBTReportWindow:new(x, y, width, height,
        tostring(title or "Spy vs Spy: Booby Traps"), table.concat(lines, " <LINE> <LINE> "))
    window:initialise()
    window:addToUIManager()
    Client.ReportWindow = window

    Logger.Finish(run, true, "lines=" .. tostring(#lines))
    return window
end

function Client.FindItemById(player, itemId)
    local run = Logger.Begin("Client.FindItemById", itemId)
    local item = player and Shared.GetItemById(player:getInventory(), itemId) or nil
    Logger.Finish(run, true, "found=" .. tostring(item ~= nil))
    return item
end

function Client.FindItem(player, fullType)
    local run = Logger.Begin("Client.FindItem", fullType)
    local item = player and Shared.FindItemByFullType(player:getInventory(), fullType) or nil
    Logger.Finish(run, true, "found=" .. tostring(item ~= nil))
    return item
end

function Client.SendCommand(command, args, player)
    local run = Logger.Begin("Client.SendCommand", command)
    player = player or (type(getPlayer) == "function" and getPlayer() or nil)

    if not player then
        Client.Notify("Unable to identify the local player.", true)
        Logger.Finish(run, false, "PLAYER_REQUIRED")
        return false
    end

    if command == "INSPECT" then
        Client.PendingInspection = args or {}
    end

    if type(isClient) == "function" and isClient() then
        sendClientCommand(player, Shared.Module, command, args or {})
        Logger.Finish(run, true, "multiplayer transport")
        return true
    end

    if SVSBT.Server and type(SVSBT.Server.HandleCommand) == "function" then
        SVSBT.Server.HandleCommand(Shared.Module, command, player, args or {})
        Logger.Finish(run, true, "singleplayer direct transport")
        return true
    end

    Client.Notify("The booby-trap server service is unavailable.", true)
    Logger.Finish(run, false, "SERVER_ROUTER_UNAVAILABLE")
    return false
end

local FriendlyKind = {
    water_bucket = "Water Bucket Trap",
    nail_board = "Nail Board",
    bear_trap = "Bear Trap",
    explosive_mailbox = "Explosive Parcel",
    anthrax_document = "Contaminated Document",
    ignition_charge = "Ignition Charge",
    driver_seat_dye = "Rectal Reorganizer",
    tamper_alarm = "Vehicle Tamper Alarm",
    remote_immobilizer = "Remote Immobilizer",
    shotgun_door = "Shotgun Door Trap",
    trip_wire = "Trip Wire",
    biological_sample = "Sealed Biological Sample",
}

function Client.KindName(kind)
    local run = Logger.Begin("Client.KindName", kind)
    local value = FriendlyKind[tostring(kind)] or tostring(kind or "Unknown Trap")
    Logger.Finish(run, true, value)
    return value
end

local function storeInspection(data)
    local run = Logger.Begin("Client.storeInspection")
    local lines = {}
    local pending = Client.PendingInspection or {}

    for _, record in ipairs(data.discovered or {}) do
        record.seenAtMs = type(getTimestampMs) == "function" and getTimestampMs() or 0
        record.x = pending.x
        record.y = pending.y
        record.z = pending.z
        record.vehicleId = pending.vehicleId
        record.documentItemId = record.documentItemId or pending.documentItemId
        Client.KnownTraps[tostring(record.trapId)] = record
        local condition = record.condition and (" | condition " .. tostring(record.condition) .. "/" .. tostring(record.maxCondition or 100)) or ""
        lines[#lines + 1] = Client.KindName(record.kind) .. " | " .. tostring(record.state or "unknown") .. condition
    end

    if #lines == 0 then
        lines[1] = "Nothing suspicious was found. This is not proof that the target is safe."
    else
        lines[#lines + 1] = "Right-click the target again to disarm, reverse, or salvage a discovered device."
    end

    Client.Report("Trap Inspection", lines)
    Client.PendingInspection = nil
    Logger.Finish(run, true, "stored=" .. tostring(#(data.discovered or {})))
end

local function showRFResults(data)
    local run = Logger.Begin("Client.showRFResults")
    local lines = {}

    for _, result in ipairs(data.results or {}) do
        lines[#lines + 1] = tostring(result.strength or "UNKNOWN")
            .. " | " .. tostring(result.source or "wireless signal")
            .. " | approximately " .. tostring(result.approximateDistance or "?") .. " tiles"
    end

    if #lines == 0 then lines[1] = "No wireless trap heartbeat was detected." end
    Client.Report("Wireless Trap Sweep", lines)
    Logger.Finish(run, true, "results=" .. tostring(#(data.results or {})))
end

-- The Remote Immobilizer's controller is a plain on/off switch: ON means the
-- vehicle starts and runs normally, OFF means it cannot start (and the
-- engine is killed immediately if it is already running). Say so in plain
-- terms every time, whether this is a fresh toggle or just a status query.
local function controllerMessage(data)
    if data.armPending then return "Device awaiting arming. Move at least two tiles away." end
    if data.kind == Shared.Kind.RemoteImmobilizer then
        local verb = data.operation == "toggle" and "switched" or "is"
        if data.immobilized then
            return "Remote immobilizer " .. verb
                .. " OFF. This vehicle cannot start, and its engine will be killed if it is running."
        end
        return "Remote immobilizer " .. verb .. " ON. This vehicle can start and run normally."
    elseif data.kind == Shared.Kind.TamperAlarm then
        local armed = data.state == Shared.State.Armed
        if data.operation == "toggle" then
            return armed and "Vehicle tamper alarm armed." or "Vehicle tamper alarm disarmed."
        end
        return armed and "Vehicle tamper alarm is currently armed." or "Vehicle tamper alarm is currently disarmed."
    end
    return "Controller command completed."
end

local function actionMessage(data)
    local action = tostring(data.action or "ACTION")
    local messages = {
        PLACE_FLOOR_TRAP = data.failedSet and "The bear trap snapped during setting and injured you."
            or (data.kind == Shared.Kind.BiologicalSample and "Sealed sample placed. Open it to begin arming."
                or "Trap set. Move at least two tiles away to arm it."),
        PLACE_TRIP_WIRE = "Trip wire set. Move at least two tiles away from the wire to arm it.",
        RIG_MAILBOX = "Explosive parcel concealed. Move at least two tiles away to arm it.",
        INSTALL_VEHICLE_DEVICE = (data.kind == Shared.Kind.RemoteImmobilizer and not data.controllerSynced)
            and "Immobilizer installed. Move at least two tiles away to arm it. Sync the blank controller to this vehicle before using it."
            or "Vehicle device installed. Move at least two tiles away to arm it.",
        CONTAMINATE_DOCUMENT = "Document contaminated. Leave it behind and move at least two tiles away to arm it.",
        CONTROLLER_COMMAND = controllerMessage(data),
        SYNC_CONTROLLER = "Controller synced. It can now switch this immobilizer on or off from anywhere.",
        RESET_BEAR_TRAP = data.success and "Bear trap reset. Move at least two tiles away to arm it." or "The reset failed and the trap injured you.",
        FREE_BEAR_TRAP = "Occupant freed. The bear trap remains sprung until reset.",
        REPAIR_BEAR_TRAP = "Bear trap repaired.",
        DISARM = data.success and (data.operation == "reverse"
            and "Trap reversed. Move at least two tiles away to arm it."
            or ("Trap " .. tostring(data.operation or "disarm") .. " succeeded.")) or "Disarm failed.",
        ADMIN_REMOVE_RADIUS = tostring(data.removed or 0) .. " traps removed.",
    }
    return messages[action] or data.message or "Booby-trap action completed."
end

Client.TripWireAlarms = Client.TripWireAlarms or {}

local function stopTripWireSound(id)
    local alarm = Client.TripWireAlarms[id]
    if alarm then
        alarm.emitter:stopSound(alarm.sound)
        getWorld():returnOwnershipOfEmitter(alarm.emitter)
        Client.TripWireAlarms[id] = nil
    end
end

function Client.SyncTripWireAlarms(alarms)
    for id in pairs(Client.TripWireAlarms) do
        if not alarms[id] then stopTripWireSound(id) end
    end
    for id, data in pairs(alarms) do
        if Client.TripWireAlarms[id] and Client.TripWireAlarms[id].endHours ~= data.endHours then
            stopTripWireSound(id)
        end
        if not Client.TripWireAlarms[id] and data.endHours > Shared.WorldAgeHours() then
            local world = getWorld()
            local emitter = world:getFreeEmitter(data.x + 0.5, data.y + 0.5, data.z)
            world:takeOwnershipOfEmitter(emitter)
            -- Local playback: the server already sends this state to each listener.
            local sound = emitter:playSoundImpl("HouseAlarm", nil)
            Client.TripWireAlarms[id] = { emitter = emitter, sound = sound, endHours = data.endHours }
        end
    end
end

local function stopAllTripWireSounds()
    for id in pairs(Client.TripWireAlarms) do stopTripWireSound(id) end
end

-- Writes a sync's pairing onto the local copy of the controller, so it
-- offers Toggle Paired Device straight away (see Service.SyncController).
function Client.PairController(data)
    local count = type(getNumActivePlayers) == "function" and getNumActivePlayers() or 1
    for i = 0, count - 1 do
        local item = Client.FindItemById(getSpecificPlayer(i), data.controllerItemId)
        if item then
            local modData = item:getModData()
            modData.SVSBT_DeviceId = data.trapId
            modData.SVSBT_DeviceKind = data.deviceKind
            modData.SVSBT_VehicleUID = data.vehicleUid
            modData.SVSBT_Owner = data.owner
            Shared.NameController(item)
            return true
        end
    end
    return false
end

local function onServerCommand(moduleName, command, data)
    local run = Logger.Begin("Client.onServerCommand", command)

    if moduleName ~= Shared.Module then
        Logger.Finish(run, true, "foreign module ignored")
        return
    end

    data = data or {}
    Client.PruneKnowledge(false)

    if command == "TRAP_KILL_CREDIT" then
        local count = type(getNumActivePlayers) == "function" and getNumActivePlayers() or 1
        for i = 0, count - 1 do
            local player = getSpecificPlayer(i)
            if player and Shared.Username(player) == data.username and tonumber(data.total) then
                player:setSurvivorKills(math.max(player:getSurvivorKills(), math.floor(data.total)))
            end
        end
    elseif command == "TRIP_WIRE_ALARMS" then
        Client.SyncTripWireAlarms(data.alarms or {})
    elseif command == "VISIBLE" then
        Client.Visible = data.traps or {}
        Client.SyncTripWireAlarms(data.tripWireAlarms or {})
    elseif command == "WARNING" then
        Client.Notify(data.message or "A trap has triggered!", true)
    elseif command == "ALERT" then
        Client.Report("Covert Vehicle Alert", {
            "Reason: " .. tostring(data.reason or "tampering"),
            "Vehicle signal: " .. tostring(data.vehicleUid or "unknown"),
            "Approximate location: " .. tostring(data.x or "?") .. ", " .. tostring(data.y or "?"),
        })
    elseif command == "ERROR" then
        Client.Notify(data.message or data.reason or "Trap request rejected.", true)
        Logger.Warn("Client.onServerCommand", "reason=" .. tostring(data.reason))
    elseif command == "ACTION_RESULT" then
        if data.action == "SYNC_CONTROLLER" then Client.PairController(data) end
        if data.action == "INSPECT" then
            storeInspection(data)
        elseif data.action == "RF_SCAN" then
            showRFResults(data)
        elseif data.action == "MAILBOX_ACCESSED" and data.trapKnown then
            Client.Notify(data.message or "You avoid disturbing the inspected trap.")
        elseif data.triggered == true then
            Client.Notify(data.message or "A trap has triggered!", true)
        elseif data.action and data.action ~= "ACTION_BEGIN"
            and data.action ~= "DOCUMENT_OPENED"
            and data.action ~= "VEHICLE_CONTAINER_ACCESSED" then
            Client.Notify(actionMessage(data), data.success == false or data.failedSet == true)
        end
    end

    Logger.Finish(run, true, "response processed")
end

local function onGameStart()
    local run = Logger.Begin("Client.onGameStart")
    Config.RefreshLogging()
    Client.SendCommand("REQUEST_VISIBLE", {})
    Logger.Info("Client.onGameStart", "Spy vs Spy: Booby Traps client initialized")
    Logger.Finish(run, true)
end

local function onClientTick()
    for id, alarm in pairs(Client.TripWireAlarms) do
        if Shared.WorldAgeHours() >= alarm.endHours then stopTripWireSound(id)
        else alarm.emitter:tick() end
    end
    Client.PruneKnowledge(false)
end

if Events and Events.OnServerCommand then Events.OnServerCommand.Add(onServerCommand) end
if Events and Events.OnGameStart then Events.OnGameStart.Add(onGameStart) end
if Events and Events.OnTick then Events.OnTick.Add(onClientTick) end
if Events and Events.OnDisconnect then Events.OnDisconnect.Add(stopAllTripWireSounds) end
if Events and Events.OnMainMenuEnter then Events.OnMainMenuEnter.Add(stopAllTripWireSounds) end

Logger.Info("SVSBT_Client.load", "client command and response router initialized")

return Client
