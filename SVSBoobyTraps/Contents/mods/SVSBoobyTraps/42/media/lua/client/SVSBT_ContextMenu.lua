require "ISUI/ISToolTip"
require "TimedActions/ISTimedActionQueue"
require "TimedActions/ISWalkToTimedAction"
require "luautils"
require "SVSBT_TimedActions"
require "Vehicles/ISUI/ISVehicleMenu"

local Client = SVSBT.Client
local Shared = SVSBT.Shared
local Config = SVSBT.Config
local Logger = SVSBT.Logger

local function unwrap(entry)
    local run = Logger.Begin("ContextMenu.unwrap")
    local item = entry

    if type(entry) == "table" and entry.items and entry.items[1] then
        item = entry.items[1]
    end

    Logger.Finish(run, true, "item=" .. tostring(item ~= nil))
    return item
end

local function entries(items)
    local run = Logger.Begin("ContextMenu.entries")
    local result = {}

    if items and type(items.size) == "function" and type(items.get) == "function" then
        for i = 0, items:size() - 1 do result[#result + 1] = items:get(i) end
    elseif items then
        for _, entry in ipairs(items) do result[#result + 1] = entry end
    end

    Logger.Finish(run, true, "count=" .. tostring(#result))
    return result
end

local function tip(option, description)
    if option and description and description ~= "" then
        local tooltip = ISToolTip:new()
        tooltip:initialise()
        tooltip.description = tostring(description)
        option.toolTip = tooltip
    end
    return option
end

local function addDisabled(context, text, description)
    local run = Logger.Begin("ContextMenu.addDisabled", text)
    local option = context:addOption(text, nil, nil)
    option.notAvailable = true
    tip(option, description or "Unavailable.")
    Logger.Finish(run, true)
    return option
end

-- Player-facing explanations for each interaction, shown on hover.
local Explain = {
    setFloor = "Places the trap on this tile. It stays visible in line of sight and triggers when a player, zombie, animal, or vehicle crosses it. Right-click it later to inspect, disarm, salvage, reset, or repair.",
    placeTripWire = "Stretches a wire between your current tile and this one. Anyone crossing the line between the two stakes sounds a real house alarm and alerts you -- no damage, just a warning. Good for 3 real detonations, 2 hours apart, before it burns out.",
    rigMailbox = "Hides the explosive parcel inside this container. Opening it without inspecting it first gives a very short fuse before it detonates. Requires a real mailbox, bin, or dumpster.",
    installVehicle = "Fits this device to the vehicle. The vehicle must be stationary with the engine off. Alarms and immobilizers also give you a paired controller.",
    contaminate = "Coats this book, magazine, newspaper, or note with the biological agent without changing its name. Whoever reads it next is exposed. One item per agent.",
    inspectArea = "Spends time searching this spot for hidden traps. Success depends on your Electrical, Mechanics, and Maintenance skill. Finding nothing is not proof it is safe.",
    inspectVehicle = "Spends time checking this vehicle for espionage devices. Inspect before starting the engine or opening its storage. Discovered devices can then be disarmed or reversed.",
    inspectDocument = "Checks this specific document for tampering before you read it.",
    disarm = "Attempts to safely remove a discovered trap. Failure may set it off. Needs the required skill levels.",
    reverse = "Attempts to take ownership of a discovered trap instead of removing it. Wireless devices hand you a fresh controller.",
    salvage = "Removes a discovered trap for parts instead of recovering the item. Chance of rare components.",
    freeBear = "Releases the trapped player, zombie, animal or corpse. The trap stays sprung; resetting it is a separate action. If you're the one caught, you need a weapon in hand to pry it open without injury; without one, sprinting is your only way out and it will hurt.",
    resetBear = "Re-arms an empty, sprung bear trap using a tool or weapon held in either hand. Nothing is consumed. Short items such as knives, screwdrivers and hammers are riskier; longer items keep your hands farther from the jaws.",
    repairBear = "Welds a damaged bear trap back toward working condition. Needs welding rods, a full blowtorch, and eye protection. Each repair lowers its maximum condition.",
    controllerStatus = "Pings the paired device for its state and whether a jammer is blocking the signal. For a paired alarm this also shows distance; a synced immobilizer never reveals the vehicle's location.",
    controllerToggle = "Arms or disarms the paired alarm. For a paired immobilizer, this is a plain on/off switch: ON lets the vehicle start and run, OFF stops it from starting and kills the engine if it is already running.",
    syncController = "Permanently pairs this blank controller to the immobilizer installed on this vehicle. Once synced, the controller can switch it on or off from anywhere and never reveals the vehicle's location. Only one controller can ever be paired to one immobilizer -- choose carefully.",
    rfScan = "Sweeps for the heartbeat of wireless trap devices in range using the RF signal detector.",
    setBiological = "Places the sealed sample on this tile, unopened and completely inert until you crack the seal.",
    openBiological = "Cracks the seal. Get at least a couple of squares clear -- once you do, it becomes a lingering hazard that sickens anyone who lingers nearby, for a long time. A gas mask or half-mask helps.",
    neutralizeBiological = "Carefully caps and empties the sample, whether it has been opened or not, leaving only an empty jar. Needs the same know-how as preparing the agent in the first place.",
}

local function interactionTarget(player, args)
    local target = args
    if args.trapId then
        target = Client.KnownTraps[tostring(args.trapId)]
        for _, record in ipairs(Client.Visible or {}) do
            if tostring(record.trapId) == tostring(args.trapId) then target = record; break end
        end
        target = target or args
    end
    local vehicleId = args.vehicleId or target.vehicleId
    local vehicle = vehicleId and getVehicleById(vehicleId)
        or (target.vehicleUid and Shared.FindVehicleByUID(target.vehicleUid))
    if vehicle then return vehicle:getSquare() end
    if target.documentItemId then return nil end
    local x, y, z = target.x, target.y, target.z
    if target.x2 and target.y2 and Shared.Distance(player:getX(), player:getY(), target.x2, target.y2)
        < Shared.Distance(player:getX(), player:getY(), x, y) then
        x, y = target.x2, target.y2
    end
    return x and y and z and getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z)) or nil
end

local function queue(player, command, args, seconds, animation, immediate)
    local run = Logger.Begin("ContextMenu.queue", command)

    if not SVSBTDeviceAction.CanStart(player, command, args, true) then
        Logger.Finish(run, false, "requirements unavailable")
        return false
    end

    local square = interactionTarget(player, args)
    if square then
        if command == "PLACE_FLOOR" or command == "PLACE_TRIP_WIRE" then
            if player:getSquare() ~= square then
                ISTimedActionQueue.add(ISWalkToTimedAction:new(player, square))
            end
        elseif not luautils.walkAdj(player, square, true) then
            Client.Notify("No reachable path to this trap.", true)
            return false
        end
    end
    local action = SVSBTDeviceAction:new(player, command, args, seconds, animation)
    action.immediateCommand = immediate == true
    ISTimedActionQueue.add(action)
    Logger.Finish(run, true)
    return true
end

local function isAdmin(player)
    local run = Logger.Begin("ContextMenu.isAdmin")
    local result = Shared.IsAdmin(player)
    Logger.Finish(run, true, "admin=" .. tostring(result))
    return result
end

local function nearbyVehicle(player)
    local run = Logger.Begin("ContextMenu.nearbyVehicle")
    -- Seated players interact with their own vehicle; everyone else with the
    -- nearest usable one. Covers "inside and outside the vehicle".
    local vehicle = player and type(player.getVehicle) == "function" and player:getVehicle() or nil

    if not vehicle and player and type(player.getNearVehicle) == "function" then
        vehicle = player:getNearVehicle()
    end

    if not vehicle and player and type(player.getUseableVehicle) == "function" then
        vehicle = player:getUseableVehicle()
    end

    Logger.Finish(run, true, vehicle and tostring(vehicle:getId()) or "none")
    return vehicle
end

-- A trap-related menu option should only ever appear for something the
-- player is actually standing next to (or holding) -- a 1-tile radius
-- (adjacent tiles, diagonals included), never wherever the mouse happens to
-- be pointed while zoomed out. Admins bypass this exactly like every other
-- gate in this file (meetsRequirements, knowsDevice) -- an admin testing or
-- moderating shouldn't have menu options vanish because of where they're
-- standing any more than because of a skill they haven't leveled.
local ADJACENT_TILE_DISTANCE = 1.5

local function nearbyObject(player, predicate)
    local run = Logger.Begin("ContextMenu.nearbyObject")
    local found = nil
    local cell = getCell()
    local radius = isAdmin(player) and 5 or 1

    if player and cell then
        for x = math.floor(player:getX()) - radius, math.floor(player:getX()) + radius do
            for y = math.floor(player:getY()) - radius, math.floor(player:getY()) + radius do
                local square = cell:getGridSquare(x, y, math.floor(player:getZ()))

                if square then
                    local objects = square:getObjects()

                    for i = 0, objects:size() - 1 do
                        local object = objects:get(i)

                        if predicate(object) then
                            found = object
                            break
                        end
                    end
                end

                if found then break end
            end

            if found then break end
        end
    end

    Logger.Finish(run, true, "found=" .. tostring(found ~= nil))
    return found
end

local function objectArgs(object)
    local run = Logger.Begin("ContextMenu.objectArgs")
    local square = object and object:getSquare() or nil
    local result = square and {
        x = square:getX(), y = square:getY(), z = square:getZ(),
        objectIndex = Shared.ObjectIndex(object),
    } or nil
    Logger.Finish(run, result ~= nil, "created=" .. tostring(result ~= nil))
    return result
end

-- Skill/recipe-knowledge gate shared by both menu construction (hide what
-- the player can't use yet) and the click-time safety net below (in case
-- something changed between building the menu and clicking it). Admins
-- bypass every gap, matching every server-side check of the same kind.
local function meetsRequirements(player, kind, mode)
    if isAdmin(player) then return true end
    return Shared.RequirementGap(player, kind, mode) == nil
end

local function knowsDevice(player, kind)
    return isAdmin(player) or Shared.KnowsRecipe(player, kind)
end

-- Stop hopeless attempts before the animation and say exactly what is missing.
local function blocked(player, item)
    local kind = item and Shared.ItemToKind[item:getFullType()] or nil
    if not kind then return false end
    local gap = not isAdmin(player) and (Shared.RecipeGap(player, kind) or Shared.RequirementGap(player, kind)) or nil
    if gap then
        Client.Notify(gap, true)
        return true
    end
    return false
end

local function placeFloor(player, item, square)
    local run = Logger.Begin("ContextMenu.placeFloor")
    if blocked(player, item) then return Logger.Finish(run, false, "requirement gap") end
    queue(player, "PLACE_FLOOR", {
        itemId = item:getID(), x = square:getX(), y = square:getY(), z = square:getZ(),
    }, Config.Get("PlacementTimeSeconds"), "Loot")
    Logger.Finish(run, true)
end

-- Remember stake 1 before walking to the clicked second stake.
local function placeTripWire(player, item, square)
    local run = Logger.Begin("ContextMenu.placeTripWire")
    if blocked(player, item) then return Logger.Finish(run, false, "requirement gap") end
    local start = player:getSquare()
    local length = Shared.Distance(start:getX(), start:getY(), square:getX(), square:getY())
    if length > Config.Get("TripWireMaxLengthTiles") then
        Client.Notify("The wire cannot span that many tiles. Choose a closer second stake.", true)
        return
    end
    queue(player, "PLACE_TRIP_WIRE", {
        x1 = start:getX(), y1 = start:getY(), z1 = start:getZ(),
        itemId = item:getID(), x = square:getX(), y = square:getY(), z = square:getZ(),
    }, Config.Get("PlacementTimeSeconds"), "Loot")
    Logger.Finish(run, true)
end

local function rigMailbox(player, item, mailbox)
    local run = Logger.Begin("ContextMenu.rigMailbox")
    if blocked(player, item) then return Logger.Finish(run, false, "requirement gap") end
    local args = objectArgs(mailbox)
    args.itemId = item:getID()
    queue(player, "RIG_MAILBOX", args, Config.Get("PlacementTimeSeconds"), "Loot")
    Logger.Finish(run, true)
end

local VehicleDeviceItems = {
    Shared.Item.IgnitionCharge, Shared.Item.DriverSeatDyeTrap,
    Shared.Item.VehicleTamperAlarm, Shared.Item.RemoteImmobilizer,
}

local function installVehicle(player, item, vehicle)
    local run = Logger.Begin("ContextMenu.installVehicle")
    if blocked(player, item) then return Logger.Finish(run, false, "requirement gap") end
    queue(player, "INSTALL_VEHICLE", {
        itemId = item:getID(), vehicleId = vehicle:getId(),
    }, Config.Get("VehicleInstallTimeSeconds"), "Loot")
    Logger.Finish(run, true)
end

local function openBiologicalAgent(player, square)
    local run = Logger.Begin("ContextMenu.openBiologicalAgent")
    queue(player, "OPEN_BIOLOGICAL_AGENT", { x = square:getX(), y = square:getY(), z = square:getZ() }, 0, "Loot", true)
    Logger.Finish(run, true)
end

local function neutralizeBiologicalAgent(player, square)
    local run = Logger.Begin("ContextMenu.neutralizeBiologicalAgent")
    queue(player, "NEUTRALIZE_BIOLOGICAL_AGENT", {
        x = square:getX(), y = square:getY(), z = square:getZ(),
    }, Config.Get("NeutralizeBiologicalAgentSeconds"), "Loot")
    Logger.Finish(run, true)
end

local function contaminate(player, agent, document)
    local run = Logger.Begin("ContextMenu.contaminate")
    -- AnthraxAgent isn't in Shared.ItemToKind (it's the ingredient, not the
    -- placed device), so blocked() can't resolve a kind from it -- check
    -- Shared.Kind.AnthraxDocument directly instead.
    if not isAdmin(player) then
        local gap = Shared.RecipeGap(player, Shared.Kind.AnthraxDocument) or Shared.RequirementGap(player, Shared.Kind.AnthraxDocument)
        if gap then
            Client.Notify(gap, true)
            return Logger.Finish(run, false, "requirement gap")
        end
    end
    queue(player, "CONTAMINATE_DOCUMENT", {
        agentItemId = agent:getID(), documentItemId = document:getID(),
    }, Config.Get("PlacementTimeSeconds"), "Loot")
    Logger.Finish(run, true)
end

local function controller(player, item, operation)
    local run = Logger.Begin("ContextMenu.controller", operation)
    Client.SendCommand("CONTROLLER_COMMAND", {
        controllerItemId = item:getID(), operation = operation,
    }, player)
    Logger.Finish(run, true)
end

-- A blank controller (handed out at immobilizer install, see
-- inventoryContext) carries no SVSBT_DeviceId until it is deliberately
-- synced to one specific, not-yet-paired immobilizer.
local function findUnboundController(player)
    local inventory = player and player:getInventory()
    local items = inventory and inventory:getItems()
    if not items then return nil end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:getFullType() == Shared.Item.Controller and not item:getModData().SVSBT_DeviceId then
            return item
        end
    end

    return nil
end

-- Shown speculatively to anyone within range who can see/know the record
-- (matching every other trap-action option in this file) -- the server is
-- the real authority and rejects a non-owner's sync attempt.
local function unsyncedImmobilizerFor(player, vehicle)
    if not vehicle then return nil end
    local uid = tostring(Shared.VehicleUID(vehicle, false) or "")
    if uid == "" then return nil end

    local function search(records)
        for _, record in pairs(records or {}) do
            if record.kind == Shared.Kind.RemoteImmobilizer and tostring(record.vehicleUid or "") == uid
                and record.controllerSynced ~= true and record.state == Shared.State.Armed then
                return record
            end
        end
        return nil
    end

    return search(Client.Visible) or search(Client.KnownTraps)
end

local function syncController(player, item, vehicle)
    local run = Logger.Begin("ContextMenu.syncController")
    queue(player, "SYNC_CONTROLLER", {
        controllerItemId = item:getID(), vehicleId = vehicle:getId(),
    }, 0, "Loot", true)
    Logger.Finish(run, true)
end

local function inspect(player, target)
    local run = Logger.Begin("ContextMenu.inspect")
    queue(player, "INSPECT", target, Config.Get("InspectionTimeSeconds"), "Loot")
    Logger.Finish(run, true)
end

local function disarm(player, record, operation)
    local run = Logger.Begin("ContextMenu.disarm", operation)
    local gap = record and record.kind and Shared.RequirementGap(player, record.kind, "disarm") or nil
    if gap and not Shared.IsAdmin(player) then
        Client.Notify(gap, true)
        return Logger.Finish(run, false, "disarm requirement gap")
    end
    if record and record.kind and not Shared.IsAdmin(player) and not Shared.KnowsRecipe(player, record.kind) then
        local magazine = Shared.KindMagazine[record.kind]
        Client.Notify("You don't know how this device is built, so you can't safely disarm it"
            .. (magazine and (" -- read " .. magazine .. " first.") or "."), true)
        return Logger.Finish(run, false, "recipe unknown")
    end
    queue(player, "DISARM", {
        trapId = record.trapId,
        operation = operation,
        documentItemId = record.documentItemId,
    }, Config.Get("DisarmTimeSeconds"), "Loot")
    Logger.Finish(run, true)
end

local function resetBear(player, record)
    local run = Logger.Begin("ContextMenu.resetBear")
    queue(player, "RESET_BEAR", { trapId = record.trapId }, Config.Get("ResetTimeSeconds"), "Loot")
    Logger.Finish(run, true)
end

local function repairBear(player, record)
    local run = Logger.Begin("ContextMenu.repairBear")
    queue(player, "REPAIR_BEAR", { trapId = record.trapId }, Config.Get("RepairTimeSeconds"), "BlowTorch")
    Logger.Finish(run, true)
end

local function freeBear(player, record)
    local run = Logger.Begin("ContextMenu.freeBear")
    queue(player, "FREE_BEAR", { trapId = record.trapId }, Config.Get("FreeBearTrapTimeSeconds"), "Loot")
    Logger.Finish(run, true)
end

local function rfScan(player, detector)
    local run = Logger.Begin("ContextMenu.rfScan")
    queue(player, "RF_SCAN", { detectorItemId = detector:getID() }, 5, "Loot")
    Logger.Finish(run, true)
end

local function adminRemove(player)
    local run = Logger.Begin("ContextMenu.adminRemove")
    Client.SendCommand("ADMIN_REMOVE_RADIUS", { radius = Config.Get("AdminRemovalRadiusTiles") }, player)
    Logger.Finish(run, true)
end

local function addTrapActions(context, player, record)
    local run = Logger.Begin("ContextMenu.addTrapActions", record.trapId)
    local label = Client.KindName(record.kind)
    -- Handling a discovered device (disarm/reverse/salvage) needs the same
    -- skill levels AND recipe knowledge Service.Disarm itself requires --
    -- showing the option only to fail with "you don't know how this is
    -- built" on click isn't contextual, it's a trap door.
    local canHandle = meetsRequirements(player, record.kind, "disarm") and knowsDevice(player, record.kind)

    if canHandle then
        -- Disarm/Reverse only make sense against a live, armed threat --
        -- a sprung/unarmed bear trap has nothing left to disarm or take
        -- over. Salvage stays available regardless of state: picking up
        -- a spent trap to reclaim or reset elsewhere is always sensible.
        if record.state == Shared.State.Armed then
            tip(context:addOption("Disarm " .. label, player, disarm, record, "disarm"), Explain.disarm)

            if Config.Get("ReverseDisarmEnabled") then
                tip(context:addOption("Reverse " .. label, player, disarm, record, "reverse"), Explain.reverse)
            end
        end

        tip(context:addOption("Salvage " .. label, player, disarm, record, "salvage"), Explain.salvage)
    end

    -- record.occupied (not just state==Sprung) -- the catch can already be
    -- freed/escaped while the trap sits sprung and empty, waiting on a reset.
    if record.kind == Shared.Kind.BearTrap and record.occupied then
        tip(context:addOption("Release Victim", player, freeBear, record), Explain.freeBear)
    end

    if record.kind == Shared.Kind.BearTrap and record.state == Shared.State.Sprung and not record.occupied
        and SVSBTDeviceAction.CanStart(player, "RESET_BEAR", {}, false) then
        tip(context:addOption("Reset Bear Trap", player, resetBear, record), Explain.resetBear)
    end

    if record.kind == Shared.Kind.BearTrap
        and tonumber(record.condition) and tonumber(record.condition) < tonumber(record.maxCondition or 100)
        and SVSBTDeviceAction.CanStart(player, "REPAIR_BEAR", {}, false) then
        tip(context:addOption("Repair Bear Trap", player, repairBear, record), Explain.repairBear)
    end

    Logger.Finish(run, true)
end

local function inventoryContext(playerIndex, context, items)
    local run = Logger.Begin("ContextMenu.inventoryContext")

    if not Config.Get("Enabled") then
        Logger.Finish(run, true, "disabled")
        return
    end

    local player = getSpecificPlayer(playerIndex)
    if not player then return Logger.Finish(run, false, "PLAYER_REQUIRED") end
    local seen = {}

    for _, entry in ipairs(entries(items)) do
        local item = unwrap(entry)

        if item and not seen[item:getID()] then
            seen[item:getID()] = true
            local fullType = item:getFullType()

            local placeKind = Shared.ItemToKind[fullType]

            if fullType == Shared.Item.NailBoard or (fullType == Shared.Item.BearTrap and Client.FindItemById(player, item:getID()))
                or fullType == Shared.Item.SealedBiologicalSample or fullType == Shared.Item.WaterBucketTrap
                or fullType == Shared.Item.ShotgunDoorTrap then
                local label = fullType == Shared.Item.BearTrap and "Set Bear Trap at Current Tile"
                    or ("Set " .. item:getName() .. " on Current Tile")
                local gap = not isAdmin(player) and (Shared.RecipeGap(player, placeKind) or Shared.RequirementGap(player, placeKind)) or nil
                if not gap then
                    tip(context:addOption(label, player, placeFloor, item, player:getSquare()), Explain.setFloor)
                else
                    addDisabled(context, label, gap)
                end
            elseif fullType == Shared.Item.TripWireKit then
                if meetsRequirements(player, placeKind) then
                    addDisabled(context, "Connect Trip Wire",
                        "Right-click the ground where you want the second stake instead -- trip wires stretch between your tile and a world tile, not from your inventory.")
                else
                    addDisabled(context, "Connect Trip Wire", Shared.RequirementGap(player, placeKind))
                end
            elseif fullType == Shared.Item.ExplosiveParcel then
                if meetsRequirements(player, placeKind) then
                    local mailbox = nearbyObject(player, Shared.IsMailbox)
                    -- Name the container the player is actually standing at
                    -- ("Arm Parcel in Dumpster"); only the disabled entries,
                    -- which have no target yet, stay generic.
                    if mailbox then tip(context:addOption("Arm Parcel in " .. Shared.MailboxNoun(mailbox, true), player, rigMailbox, item, mailbox), Explain.rigMailbox)
                    else addDisabled(context, "Arm Parcel in Container", "Stand beside a mailbox, bin, or dumpster to hide the parcel in.") end
                else
                    addDisabled(context, "Arm Parcel in Container", Shared.RequirementGap(player, placeKind))
                end
            elseif Shared.VehicleKinds[placeKind] then
                local label = "Install " .. item:getName()
                if meetsRequirements(player, placeKind) then
                    local vehicle = nearbyVehicle(player)
                    if vehicle then tip(context:addOption(label, player, installVehicle, item, vehicle), Explain.installVehicle)
                    else addDisabled(context, label, "Sit in or stand beside a stationary vehicle with its engine off.") end
                else
                    addDisabled(context, label, Shared.RequirementGap(player, placeKind))
                end
            elseif fullType == Shared.Item.Controller then
                Shared.NameController(item) -- controllers handed out before they were named
                if item:getModData().SVSBT_DeviceId then
                    tip(context:addOption("Query Covert Controller", player, controller, item, "status"), Explain.controllerStatus)
                    tip(context:addOption("Toggle Paired Device", player, controller, item, "toggle"), Explain.controllerToggle)
                else
                    local pendingVehicle = nearbyVehicle(player)
                    local pending = unsyncedImmobilizerFor(player, pendingVehicle)
                    if pending then
                        tip(context:addOption("Sync Controller to Immobilizer", player, syncController, item, pendingVehicle), Explain.syncController)
                    else
                        addDisabled(context, "Sync Controller to Immobilizer",
                            "Stand within " .. SYNC_RANGE_TILES .. " tiles of a vehicle with an unsynced immobilizer you installed.")
                    end
                end
            elseif fullType == "GPSMod.RF_SignalDetector" and Config.Get("SignalsIntegrationEnabled") then
                tip(context:addOption("Scan for Wireless Trap Signals", player, rfScan, item), Explain.rfScan)
            end

            -- Any real literature is a valid target -- including the mod's own
            -- MAD Magazines, which are genuine base:literature items too.
            -- (Only AnthraxAgent/SealedBiologicalSample would ever need
            -- excluding here, and neither one matches IsReadableDocument.)
            if Shared.IsReadableDocument(item) then
                local agent = Client.FindItem(player, Shared.Item.AnthraxAgent)
                if agent and Config.Get("AnthraxEnabled") then
                    tip(context:addOption("Apply Anthrax", player, contaminate, agent, item), Explain.contaminate)
                end

                tip(context:addOption("Inspect Document for Tampering", player, inspect, {
                    documentItemId = item:getID(), x = player:getX(), y = player:getY(), z = player:getZ(),
                }), Explain.inspectDocument)

                for _, record in pairs(Client.KnownTraps) do
                    if record.kind == Shared.Kind.AnthraxDocument
                        and tonumber(record.documentItemId) == tonumber(item:getID()) then
                        addTrapActions(context, player, record)
                    end
                end
            end
        end
    end

    Logger.Finish(run, true, "items=" .. tostring((function() local n = 0 for _ in pairs(seen) do n = n + 1 end return n end)()))
end

local function worldTarget(worldObjects)
    local run = Logger.Begin("ContextMenu.worldTarget")
    local square = nil
    local mailbox = nil
    local vehicle = nil

    for _, object in ipairs(worldObjects or {}) do
        if object and type(object.getSquare) == "function" and object:getSquare() then square = square or object:getSquare() end
        if object and Shared.IsMailbox(object) then mailbox = mailbox or object end
        if object and instanceof(object, "BaseVehicle") then vehicle = vehicle or object end
    end

    Logger.Finish(run, true, "square=" .. tostring(square ~= nil))
    return square, mailbox, vehicle
end

-- Match the clicked target, not the player's current position. Walking is
-- queued only after the player chooses an action on that target.
local function recordMatchesTarget(record, player, vehicle, square)
    if vehicle then
        return (record.vehicleId and tonumber(record.vehicleId) == tonumber(vehicle:getId()))
            or (record.vehicleUid and record.vehicleUid == Shared.VehicleUID(vehicle, false))
    end
    if record.vehicleId or record.vehicleUid or not square then return false end
    if tonumber(record.z) ~= square:getZ() then return false end
    local function matches(x, y)
        return x and y and math.floor(x) == square:getX() and math.floor(y) == square:getY()
    end
    return matches(record.x, record.y) or matches(record.x2, record.y2)
end

local function worldContext(playerIndex, context, worldObjects, test)
    local run = Logger.Begin("ContextMenu.worldContext")
    if test or not Config.Get("Enabled") then return Logger.Finish(run, true, "test or disabled") end
    local player = getSpecificPlayer(playerIndex)
    if not player then return Logger.Finish(run, false, "PLAYER_REQUIRED") end
    local square, mailbox, vehicle = worldTarget(worldObjects)
    if type(screenToIsoX) == "function" and context.x and context.y then
        square = getCell():getGridSquare(
            math.floor(screenToIsoX(playerIndex, context.x, context.y, player:getZ())),
            math.floor(screenToIsoY(playerIndex, context.x, context.y, player:getZ())), math.floor(player:getZ())) or square
    end
    square = square or player:getSquare()
    -- A nearby car must not replace a different, distant clicked trap.
    vehicle = vehicle or (square == player:getSquare() and nearbyVehicle(player))
    -- A trap already lying on the target square can be set directly --
    -- no need to pick it up into inventory first.
    local nailBoard = Client.FindItem(player, Shared.Item.NailBoard)
        or (square and Shared.GroundItemByType(square, Shared.Item.NailBoard))
    local bearTrap = Client.FindItem(player, Shared.Item.BearTrap)
    local waterTrap = Client.FindItem(player, Shared.Item.WaterBucketTrap)
    local shotgunTrap = Client.FindItem(player, Shared.Item.ShotgunDoorTrap)
    local tripWireKit = Client.FindItem(player, Shared.Item.TripWireKit)
    local parcel = Client.FindItem(player, Shared.Item.ExplosiveParcel)
    local groundSample = square and Shared.GroundItemByType(square, Shared.Item.SealedBiologicalSample)
    local sample = Client.FindItem(player, Shared.Item.SealedBiologicalSample) or groundSample

    if square and nailBoard and meetsRequirements(player, Shared.Kind.NailBoard) then
        tip(context:addOption("Set Nail Board Here", player, placeFloor, nailBoard, square), Explain.setFloor)
    end
    if square and bearTrap and meetsRequirements(player, Shared.Kind.BearTrap) then
        tip(context:addOption("Set Bear Trap Here", player, placeFloor, bearTrap, square), Explain.setFloor)
    end
    if square and waterTrap and meetsRequirements(player, Shared.Kind.WaterBucket) then
        tip(context:addOption("Set Water Bucket Trap Here", player, placeFloor, waterTrap, square), Explain.setFloor)
    end
    if square and shotgunTrap and meetsRequirements(player, Shared.Kind.ShotgunDoor) then
        tip(context:addOption("Set Shotgun Trap Here", player, placeFloor, shotgunTrap, square), Explain.setFloor)
    end
    if mailbox and parcel and meetsRequirements(player, Shared.Kind.ExplosiveMailbox) then
        tip(context:addOption("Arm Parcel in " .. Shared.MailboxNoun(mailbox, true), player, rigMailbox, parcel, mailbox), Explain.rigMailbox)
    end
    if square and tripWireKit and square ~= player:getSquare() and meetsRequirements(player, Shared.Kind.TripWire) then
        tip(context:addOption("Connect Trip Wire Here", player, placeTripWire, tripWireKit, square), Explain.placeTripWire)
    end
    if square and sample and meetsRequirements(player, Shared.Kind.BiologicalSample) then
        tip(context:addOption("Set Biological Sample Here", player, placeFloor, sample, square), Explain.setBiological)
    end
    if square and groundSample and Config.Get("AnthraxEnabled") then
        tip(context:addOption("Open Biological Sample", player, openBiologicalAgent, square), Explain.openBiological)
        if knowsDevice(player, Shared.Kind.BiologicalSample) then
            tip(context:addOption("Neutralize Biological Sample", player, neutralizeBiologicalAgent, square), Explain.neutralizeBiological)
        end
    end

    if vehicle then
        for _, fullType in ipairs(VehicleDeviceItems) do
            local item = Client.FindItem(player, fullType)
            if item and meetsRequirements(player, Shared.ItemToKind[fullType]) then
                tip(context:addOption("Install " .. item:getName(), player, installVehicle, item, vehicle), Explain.installVehicle)
            end
        end

        -- A controller paired to this vehicle can be operated from its menu too.
        local uid = tostring(Shared.VehicleUID(vehicle, false) or "")
        local carried = player:getInventory() and player:getInventory():getItems()
        if carried and uid ~= "" then
            for i = 0, carried:size() - 1 do
                local item = carried:get(i)
                if item:getFullType() == Shared.Item.Controller
                    and tostring(item:getModData().SVSBT_VehicleUID or "?") == uid then
                    tip(context:addOption("Query Covert Controller", player, controller, item, "status"), Explain.controllerStatus)
                    tip(context:addOption("Toggle Paired Device", player, controller, item, "toggle"), Explain.controllerToggle)
                    break
                end
            end
        end

        -- An unsynced immobilizer on THIS vehicle can be paired right here,
        -- as an alternative to right-clicking the blank controller itself.
        local pending = unsyncedImmobilizerFor(player, vehicle)
        if pending then
            local blank = findUnboundController(player)
            if blank then
                tip(context:addOption("Sync Controller to Immobilizer", player, syncController, blank, vehicle), Explain.syncController)
            end
        end
    end

    local target = vehicle and { vehicleId = vehicle:getId(), x = vehicle:getX(), y = vehicle:getY(), z = vehicle:getZ() }
        or { x = square:getX(), y = square:getY(), z = square:getZ() }
    tip(context:addOption(vehicle and "Inspect Vehicle for Espionage Devices" or "Inspect Area for Traps", player, inspect, target),
        vehicle and Explain.inspectVehicle or Explain.inspectArea)

    local added = {}

    for _, record in ipairs(Client.Visible or {}) do
        if recordMatchesTarget(record, player, vehicle, square) and not added[record.trapId] then
            added[record.trapId] = true
            addTrapActions(context, player, record)
        end
    end

    for _, record in pairs(Client.KnownTraps or {}) do
        if recordMatchesTarget(record, player, vehicle, square) and not added[record.trapId] then
            added[record.trapId] = true
            addTrapActions(context, player, record)
        end
    end

    if isAdmin(player) then
        context:addOption("Remove Booby Traps in Admin Radius", player, adminRemove)
    end
    Logger.Finish(run, true, "actions added")
end

-- The vehicle radial menu (keyboard toggle and gamepad alike) is a real,
-- separate UI from the right-click world/inventory context menus above --
-- ISVehicleMenu.showRadialMenu/showRadialMenuOutside build and show it
-- directly, with no OnFill*ContextMenu event involved at all, so carried
-- devices are added by wrapping those.
local function addVehicleDeviceSlices(menu, player, vehicle)
    if not menu or not player or not vehicle then return end

    for _, fullType in ipairs(VehicleDeviceItems) do
        local item = Client.FindItem(player, fullType)
        local kind = item and Shared.ItemToKind[fullType]

        if item and meetsRequirements(player, kind) then
            local texture = type(item.getTex) == "function" and item:getTex() or nil
            menu:addSlice("Install " .. item:getName(), texture, installVehicle, player, item, vehicle)
        end
    end
end

local function patchVehicleRadialMenu()
    local run = Logger.Begin("ContextMenu.patchVehicleRadialMenu")

    if not ISVehicleMenu or ISVehicleMenu.SVSBT_OriginalShowRadialMenu then
        Logger.Finish(run, true, "already patched or unavailable")
        return false
    end

    ISVehicleMenu.SVSBT_OriginalShowRadialMenu = ISVehicleMenu.showRadialMenu
    ISVehicleMenu.SVSBT_OriginalShowRadialMenuOutside = ISVehicleMenu.showRadialMenuOutside

    -- Both vanilla functions toggle the SAME persistent per-player radial
    -- menu: a second call while it's already showing just closes it. Only
    -- append slices on the call that actually opens it, never the one that
    -- closes it, or every other press would silently re-add duplicates.
    --
    -- showRadialMenu/showRadialMenuOutside end with menu:addToUIManager(),
    -- which only queues the menu for the NEXT UI tick, so
    -- menu:isReallyVisible() right after the original call is always false.
    -- wasVisible, read BEFORE the original call, is the reliable signal: if
    -- it wasn't showing, this call is the one opening it (vanilla is a
    -- plain toggle).
    --
    -- showRadialMenu calls the GLOBAL showRadialMenuOutside (this same
    -- patched function) when the player isn't seated, so both wrappers can
    -- fire for one keypress. A reentrancy flag makes sure only the outermost
    -- call adds slices.
    --
    -- The original vanilla call is NEVER inside a pcall -- any bug on our
    -- side must never be able to swallow a real engine error or otherwise
    -- interfere with vanilla vehicle behavior (door sounds, seat switching,
    -- etc.), so our own logic is pcall-isolated on both sides of it instead.
    local handlingVehicleRadialMenu = false

    function ISVehicleMenu.showRadialMenu(playerObj)
        local reentrant = handlingVehicleRadialMenu
        handlingVehicleRadialMenu = true

        local ok1, menu, wasVisible = pcall(function()
            local m = getPlayerRadialMenu(playerObj:getPlayerNum())
            return m, m and m:isReallyVisible()
        end)
        if not ok1 then menu, wasVisible = nil, nil end

        ISVehicleMenu.SVSBT_OriginalShowRadialMenu(playerObj)

        if not reentrant and not wasVisible then
            pcall(function()
                if menu then
                    addVehicleDeviceSlices(menu, playerObj, playerObj:getVehicle() or ISVehicleMenu.getVehicleToInteractWith(playerObj))
                end
            end)
        end

        if not reentrant then handlingVehicleRadialMenu = false end
    end

    function ISVehicleMenu.showRadialMenuOutside(playerObj)
        local reentrant = handlingVehicleRadialMenu
        handlingVehicleRadialMenu = true

        local ok1, menu, wasVisible = pcall(function()
            local m = getPlayerRadialMenu(playerObj:getPlayerNum())
            return m, m and m:isReallyVisible()
        end)
        if not ok1 then menu, wasVisible = nil, nil end

        ISVehicleMenu.SVSBT_OriginalShowRadialMenuOutside(playerObj)

        if not reentrant and not wasVisible then
            pcall(function()
                if menu then
                    addVehicleDeviceSlices(menu, playerObj, ISVehicleMenu.getVehicleToInteractWith(playerObj))
                end
            end)
        end

        if not reentrant then handlingVehicleRadialMenu = false end
    end

    Logger.Finish(run, true, "patched")
    return true
end

if Events and Events.OnGameStart then Events.OnGameStart.Add(patchVehicleRadialMenu) end
patchVehicleRadialMenu()

if Events and Events.OnFillInventoryObjectContextMenu then
    Events.OnFillInventoryObjectContextMenu.Add(inventoryContext)
else
    Logger.Error("SVSBT_ContextMenu.load", "inventory context event unavailable")
end

if Events and Events.OnFillWorldObjectContextMenu then
    Events.OnFillWorldObjectContextMenu.Add(worldContext)
else
    Logger.Error("SVSBT_ContextMenu.load", "world context event unavailable")
end

Logger.Info("SVSBT_ContextMenu.load", "inventory and world interactions initialized")

return true
