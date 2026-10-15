require "SVSBT_Combat"
require "SVSBT_Creatures"
require "SVSBT_Arming"

if type(isClient) == "function" and isClient() and not isServer() then
    return
end

SVSBT.Server = SVSBT.Server or {}
SVSBT.Server.Service = SVSBT.Server.Service or {}

local Service = SVSBT.Server.Service
local Registry = SVSBT.Server.Registry
local Effects = SVSBT.Server.Effects
local Combat = SVSBT.Server.Combat
local Creatures = SVSBT.Server.Creatures
local Arming = SVSBT.Server.Arming
local Shared = SVSBT.Shared
local Config = SVSBT.Config
local Logger = SVSBT.Logger

Service.PendingExplosions = Service.PendingExplosions or {}
Service.TargetCooldowns = Service.TargetCooldowns or {}
Service.VehicleRuntime = Service.VehicleRuntime or {}
Service.RequestCooldowns = Service.RequestCooldowns or {}
Service.ActiveActions = Service.ActiveActions or {}
Service.ActiveAlarms = Service.ActiveAlarms or {}
Service.BurningVehicles = Service.BurningVehicles or {}
Service.HeldPlayers = Service.HeldPlayers or {}
Service.LastTickMs = Service.LastTickMs or 0
Service.LastExposureTickMs = Service.LastExposureTickMs or 0
Service.LastVisibleSyncMs = Service.LastVisibleSyncMs or 0
Service.TrapCursor = Service.TrapCursor or 1
Service.Initialized = Service.Initialized == true

-- Forward-declared: defined later in the file (near updateWorldItemMetadata),
-- but PlaceFloorTrap/ResetBearTrap (defined earlier) need to call them too.
local swapBearTrapVisual
local updateWorldItemMetadata

local function nowMs()
    if type(getTimestampMs) == "function" then
        return getTimestampMs()
    end

    return math.floor(Shared.WorldAgeHours() * 3600000)
end

local function finishFailure(run, reason)
    Logger.Finish(run, false, reason)
    return nil, tostring(reason or "UNKNOWN_ERROR")
end

local function randomChance(chance)
    chance = math.max(0, math.min(1, tonumber(chance) or 0))
    local roll = type(ZombRandFloat) == "function" and ZombRandFloat(0, 1)
        or (type(ZombRand) == "function" and ZombRand(0, 100000) / 100000 or math.random())
    return roll < chance
end

local function collectPlayers()
    local run = Logger.Begin("Service.collectPlayers")
    local result = Shared.Players()
    Logger.Finish(run, true, "count=" .. tostring(#result))
    return result
end

local function findOnlinePlayer(username)
    local run = Logger.Begin("Service.findOnlinePlayer", username)
    local found = nil

    for _, player in ipairs(collectPlayers()) do
        if Shared.Username(player) == tostring(username) then
            found = player
            break
        end
    end

    Logger.Finish(run, true, "found=" .. tostring(found ~= nil))
    return found
end
Service.FindOnlinePlayer = findOnlinePlayer

local function send(player, command, data)
    local run = Logger.Begin("Service.send", command)
    local result = false

    if player and type(isServer) == "function" and isServer() and type(sendServerCommand) == "function" then
        sendServerCommand(player, Shared.Module, command, data or {})
        result = true
    elseif type(triggerEvent) == "function" then
        triggerEvent("OnServerCommand", Shared.Module, command, data or {})
        result = true
    end

    Logger.Finish(run, result, "sent=" .. tostring(result))
    return result
end

-- Frees a player held by a bear trap without the escape-attempt injury, e.g.
-- because the trap was successfully disarmed on their behalf.
local function releaseHeldPlayer(username, notify)
    local run = Logger.Begin("Service.releaseHeldPlayer", username)
    if not username or Service.HeldPlayers[username] == nil then
        Logger.Finish(run, true, "not held")
        return
    end

    Service.HeldPlayers[username] = nil
    local player = findOnlinePlayer(username)

    if player then
        if type(player.getModData) == "function" then
            player:getModData().SVSBT_BearTrapHeldId = nil
        end
        if type(player.transmitModData) == "function" then player:transmitModData() end
        if notify then
            send(player, "WARNING", { source = "bear_trap", message = notify })
        end
    end

    Logger.Finish(run, true, "released")
end

local function claimCooldown(player, action, milliseconds)
    local run = Logger.Begin("Service.claimCooldown", action)
    local name = Shared.Username(player)
    local bucket = Service.RequestCooldowns[name] or {}
    local readyAt = tonumber(bucket[action]) or 0

    if nowMs() < readyAt then
        return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE")
    end

    bucket[action] = nowMs() + math.max(0, tonumber(milliseconds) or 0)
    Service.RequestCooldowns[name] = bucket
    Logger.Finish(run, true, "readyAt=" .. tostring(bucket[action]))
    return true
end

function Service.ClaimVisibleRequest(player)
    return claimCooldown(player, "visible_snapshot", 1000) ~= nil
end

local TimedCommandSettings = {
    PLACE_FLOOR = "PlacementTimeSeconds",
    RIG_MAILBOX = "PlacementTimeSeconds",
    PLACE_TRIP_WIRE = "PlacementTimeSeconds",
    INSTALL_VEHICLE = "VehicleInstallTimeSeconds",
    CONTAMINATE_DOCUMENT = "PlacementTimeSeconds",
    INSPECT = "InspectionTimeSeconds",
    DISARM = "DisarmTimeSeconds",
    RESET_BEAR = "ResetTimeSeconds",
    FREE_BEAR = "FreeBearTrapTimeSeconds",
    REPAIR_BEAR = "RepairTimeSeconds",
    RF_SCAN = 5,
    NEUTRALIZE_BIOLOGICAL_AGENT = "NeutralizeBiologicalAgentSeconds",
}

local function actionSignature(command, args)
    local parts = { tostring(command or "") }
    local keys = {}

    for key, value in pairs(type(args) == "table" and args or {}) do
        if key ~= "actionId" and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
            keys[#keys + 1] = tostring(key)
        end
    end

    table.sort(keys)
    for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. tostring(args[key]) end
    return table.concat(parts, "|")
end

function Service.RequiresTimedAction(command)
    return TimedCommandSettings[tostring(command or "")] ~= nil
end

function Service.BeginTimedAction(player, args)
    local run = Logger.Begin("Service.BeginTimedAction", Shared.Username(player))
    local command = tostring(args and args.command or "")
    local actionId = tostring(args and args.actionId or "")
    local payload = type(args and args.payload) == "table" and args.payload or {}
    local durationSetting = TimedCommandSettings[command]

    if not durationSetting then return finishFailure(run, "TIMED_ACTION_NOT_ALLOWED") end
    if #actionId < 12 or #actionId > 96 or actionId:find("[^%w%-]") then
        return finishFailure(run, "INVALID_ACTION_ID")
    end
    if not claimCooldown(player, "action_begin", 200) then
        return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE")
    end

    local durationSeconds = type(durationSetting) == "string" and Config.Get(durationSetting) or durationSetting
    local current = nowMs()
    Service.ActiveActions[Shared.Username(player)] = {
        actionId = actionId,
        command = command,
        signature = actionSignature(command, payload),
        durationSeconds = math.max(1, tonumber(durationSeconds) or 5),
        beginWorldAgeHours = Shared.WorldAgeHours(),
        expiresAtMs = current + math.floor((math.max(1, durationSeconds) + 30) * 1000),
        x = player:getX(), y = player:getY(), z = player:getZ(),
    }

    -- Hunting for traps is audible work: the rummaging sounds from wherever
    -- the searcher is standing, for anyone -- or anything -- close enough.
    if command == "INSPECT" then Effects.PlayInspectionSound("search", player:getSquare()) end

    Logger.Finish(run, true, "command=" .. command)
    return { action = "ACTION_BEGIN", silent = true }
end

function Service.ConsumeTimedAction(player, command, args)
    local run = Logger.Begin("Service.ConsumeTimedAction", command)
    local name = Shared.Username(player)
    local active = Service.ActiveActions[name]
    Service.ActiveActions[name] = nil

    if not active or active.command ~= tostring(command)
        or active.actionId ~= tostring(args and args.actionId or "") then
        return finishFailure(run, "TIMED_ACTION_HANDSHAKE_REQUIRED")
    end
    local multiplayerServer = type(isServer) == "function" and isServer()
    -- Measure elapsed *game* time, which is independent of framerate, day length,
    -- and fast-forward. A generous fraction only blocks instant/scripted completion.
    local elapsedGameSeconds = (Shared.WorldAgeHours() - (tonumber(active.beginWorldAgeHours) or Shared.WorldAgeHours())) * 3600
    local minimumSeconds = math.max(0.75, (tonumber(active.durationSeconds) or 5) * 0.30)
    if multiplayerServer and not Shared.IsAdmin(player) and elapsedGameSeconds < minimumSeconds then
        return finishFailure(run, "TIMED_ACTION_COMPLETED_TOO_QUICKLY")
    end
    if nowMs() > (tonumber(active.expiresAtMs) or 0) then
        return finishFailure(run, "TIMED_ACTION_EXPIRED")
    end
    if actionSignature(command, args) ~= active.signature then
        return finishFailure(run, "TIMED_ACTION_PAYLOAD_CHANGED")
    end
    if math.floor(player:getZ()) ~= math.floor(tonumber(active.z) or -99)
        or Shared.Distance(player:getX(), player:getY(), active.x, active.y) > 1.75 then
        return finishFailure(run, "PLAYER_MOVED_DURING_ACTION")
    end

    Logger.Finish(run, true)
    return true
end

local function findItem(player, itemId)
    local run = Logger.Begin("Service.findItem", itemId)

    if not player or not player:getInventory() then
        return finishFailure(run, "PLAYER_INVENTORY_UNAVAILABLE")
    end

    local item = nil
    local numericId = tonumber(itemId)

    if numericId and type(player:getInventory().getItemWithIDRecursiv) == "function" then
        item = player:getInventory():getItemWithIDRecursiv(numericId)
    end

    if not item then
        item = Shared.GetItemById(player:getInventory(), numericId)
    end

    if not item then
        return finishFailure(run, "ITEM_NOT_FOUND")
    end

    Logger.Finish(run, true, item:getFullType())
    return item
end

local function validateItem(player, itemId, fullType)
    local run = Logger.Begin("Service.validateItem", fullType)
    local item, reason = findItem(player, itemId)

    if not item then
        return finishFailure(run, reason)
    end

    if item:getFullType() ~= fullType then
        return finishFailure(run, "INVALID_ITEM_TYPE")
    end

    Logger.Finish(run, true, "itemId=" .. tostring(item:getID()))
    return item
end

-- On a MP server, container mutations are not sent to the owning client
-- automatically; vanilla (e.g. TrapBO) pairs Remove/AddItem with these.
local function netRemoveItem(container, item)
    if container and item then
        container:Remove(item)
        if type(isServer) == "function" and isServer() and type(sendRemoveItemFromContainer) == "function" then
            pcall(sendRemoveItemFromContainer, container, item)
        end
    end
end

local function netAddSync(container, item)
    if container and item and type(isServer) == "function" and isServer()
        and type(sendAddItemToContainer) == "function" then
        pcall(sendAddItemToContainer, container, item)
    end
end

local function removeInventoryItem(item)
    local run = Logger.Begin("Service.removeInventoryItem")
    local container = item and item:getContainer() or nil

    if not container then
        return finishFailure(run, "ITEM_CONTAINER_UNAVAILABLE")
    end

    netRemoveItem(container, item)
    Logger.Finish(run, true, "removed")
    return true
end

local function addInventoryItem(player, fullType, modData)
    local run = Logger.Begin("Service.addInventoryItem", fullType)

    if not player or not player:getInventory() then
        return finishFailure(run, "PLAYER_INVENTORY_UNAVAILABLE")
    end

    local item = player:getInventory():AddItem(fullType)

    if not item then
        return finishFailure(run, "ITEM_CREATION_FAILED")
    end

    if type(modData) == "table" then
        local data = item:getModData()

        for key, value in pairs(modData) do
            data[key] = value
        end
    end
    Shared.NameController(item)

    -- InventoryItem has no transmitModData() -- netAddSync
    -- (sendAddItemToContainer) is what pushes this item to the
    -- owning client, and it must run AFTER modData is populated above, not
    -- before: there is no follow-up sync call, so whatever the client
    -- receives in this one transmission is what it's stuck with (e.g. a
    -- tamper alarm's controller, bound with SVSBT_DeviceId already set here,
    -- would otherwise arrive blank and never offer to toggle).
    netAddSync(player:getInventory(), item)

    Logger.Finish(run, true, "itemId=" .. tostring(item:getID()))
    return item
end

local function squareAt(args)
    local run = Logger.Begin("Service.squareAt")
    local x = math.floor(tonumber(args and args.x) or -999999)
    local y = math.floor(tonumber(args and args.y) or -999999)
    local z = math.floor(tonumber(args and args.z) or -999999)
    local square = getCell() and getCell():getGridSquare(x, y, z) or nil
    Logger.Finish(run, square ~= nil, square and (tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)) or "not loaded")
    return square
end

-- A trap going off sounds the same five clips as setting one, from the
-- trap's OWN tile rather than from whoever tripped it -- so the noise comes
-- from where the trap is, and the zombies it pulls in walk to the trap.
-- Vehicle devices keep record.x/y/z synced to their car (processVehicleRecord),
-- so this lands on the car for those too.
local function soundDetonation(record, square)
    square = square or squareAt(record)
    if not square then return false end
    return Effects.PlayTrapDetonationSound(square)
end

local function validateRange(player, x, y, maximum)
    local run = Logger.Begin("Service.validateRange")
    maximum = tonumber(maximum) or Config.Get("InteractionRangeTiles")
    local distance = Shared.PlayerDistanceTo(player, x, y)

    if distance > maximum then
        return finishFailure(run, "TARGET_TOO_FAR_AWAY")
    end

    Logger.Finish(run, true, "distance=" .. tostring(distance))
    return true
end

local function unauthorizedSafehouse(player, square)
    local run = Logger.Begin("Service.unauthorizedSafehouse")
    local blocked = false

    if Config.Get("RespectSafehouses") and SafeHouse and type(SafeHouse.isSafeHouse) == "function" then
        local ok, result = pcall(SafeHouse.isSafeHouse, square, Shared.Username(player), true)
        blocked = ok and result ~= nil and result ~= false
    end

    Logger.Finish(run, true, "blocked=" .. tostring(blocked))
    return blocked
end

local function safehouseAt(square)
    if not square or not SafeHouse or type(SafeHouse.getSafeHouse) ~= "function" then return nil end
    local ok, safehouse = pcall(SafeHouse.getSafeHouse, square)
    return ok and safehouse or nil
end

local function existingFeatureOperational(record)
    return Shared.FeatureEnabledForKind(record.kind)
        or (record ~= nil and Config.Get("DisableExistingWhenFeatureOff") == false)
end

local function validateOwnerEligibility(player)
    local run = Logger.Begin("Service.validateOwnerEligibility", Shared.Username(player))

    if not player then
        return finishFailure(run, "PLAYER_REQUIRED")
    end

    if not Config.Get("Enabled") then
        return finishFailure(run, "FEATURE_DISABLED")
    end

    if not Shared.IsAdmin(player)
        and tonumber(player:getHoursSurvived()) < Config.Get("MinimumOwnerSurvivalHours") then
        return finishFailure(run, "MINIMUM_SURVIVAL_TIME_REQUIRED")
    end

    Logger.Finish(run, true)
    return true
end

local function validateLimits(player, kind, x, y, z, vehicleUid)
    local run = Logger.Begin("Service.validateLimits", kind)
    local owner = Shared.Username(player)
    local activeStates = {
        [Shared.State.Armed] = true,
        [Shared.State.Placed] = true,
        [Shared.State.Triggered] = true,
        [Shared.State.Sprung] = true,
    }
    local total = Registry.CountTraps(function(record)
        return record.owner == owner and activeStates[record.state] == true
    end)

    if total >= Config.Get("MaxActiveTrapsPerPlayer") then
        return finishFailure(run, "PLAYER_TRAP_LIMIT_REACHED")
    end

    if Shared.AdvancedKinds[kind] then
        local advanced = Registry.CountTraps(function(record)
            return record.owner == owner and Shared.AdvancedKinds[record.kind] and activeStates[record.state] == true
        end)

        if advanced >= Config.Get("MaxAdvancedTrapsPerPlayer") then
            return finishFailure(run, "PLAYER_ADVANCED_TRAP_LIMIT_REACHED")
        end
    end

    if vehicleUid then
        local count = Registry.CountTraps(function(record)
            return record.vehicleUid == vehicleUid and activeStates[record.state] == true
        end)

        if count >= Config.Get("MaxDevicesPerVehicle") then
            return finishFailure(run, "VEHICLE_DEVICE_LIMIT_REACHED")
        end
    else
        local squareCount = Registry.CountTraps(function(record)
            return math.floor(tonumber(record.x) or -1) == math.floor(x)
                and math.floor(tonumber(record.y) or -1) == math.floor(y)
                and math.floor(tonumber(record.z) or -1) == math.floor(z)
                and activeStates[record.state] == true
        end)

        if squareCount >= Config.Get("MaxTrapsPerSquare") then
            return finishFailure(run, "SQUARE_TRAP_LIMIT_REACHED")
        end

        local spacing = Config.Get("MinimumTrapSpacingTiles")

        if spacing > 0 then
            local tooClose = Registry.CountTraps(function(record)
                return tonumber(record.z) == math.floor(z)
                    and activeStates[record.state] == true
                    and Shared.Distance(x, y, record.x, record.y) < spacing
            end)

            if tooClose > 0 then
                return finishFailure(run, "ANOTHER_TRAP_IS_TOO_CLOSE")
            end
        end


        local square = getCell() and getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z)) or nil
        local safehouse = safehouseAt(square)
        local safehouseLimit = Config.Get("MaxTrapsPerSafehouse")

        if safehouse and safehouseLimit > 0 then
            local safehouseCount = Registry.CountTraps(function(record)
                if activeStates[record.state] ~= true then return false end
                local ok, contained = pcall(function()
                    return safehouse:containsLocation(math.floor(record.x), math.floor(record.y))
                end)
                return ok and contained == true
            end)

            if safehouseCount >= safehouseLimit then
                return finishFailure(run, "SAFEHOUSE_TRAP_LIMIT_REACHED")
            end
        end
    end

    Logger.Finish(run, true, "ownerCount=" .. tostring(total))
    return true
end

-- Factions still control optional sharing of discovered traps, not immunity.
local function factionFor(value)
    if not Faction then return nil end
    if value and type(value) ~= "string" and type(Faction.getPlayerFaction) == "function" then
        local ok, faction = pcall(Faction.getPlayerFaction, value)
        if ok and faction then return faction end
    end
    local username = type(value) == "string" and value or (value and Shared.Username(value) or "")
    if username == "" or type(Faction.getFactions) ~= "function" then return nil end
    local ok, factions = pcall(Faction.getFactions)
    if not ok or not factions then return nil end
    for i = 0, factions:size() - 1 do
        local faction = factions:get(i)
        local owner = faction and type(faction.getOwner) == "function" and tostring(faction:getOwner() or "") or ""
        local members = faction and type(faction.getPlayers) == "function" and faction:getPlayers() or nil
        if owner == username or (members and members:contains(username)) then return faction end
    end
end

local function canTargetPlayer(record, player, harmful)
    -- Live traps affect every player, including their owner and players using
    -- PVE/safety protections. Placement permissions remain a separate check.
    if not player or player:isDead() or not Config.Get("TargetPlayers") then return false end
    if record and not Config.Get("OfflineTrapOperation") and not findOnlinePlayer(record.owner) then return false end
    return true
end

local function targetKey(target)
    local run = Logger.Begin("Service.targetKey")
    local value

    if instanceof(target, "IsoAnimal") then
        value = "A:" .. tostring(type(target.getOnlineID) == "function" and target:getOnlineID() or target)
    elseif instanceof(target, "IsoZombie") then
        value = "Z:" .. tostring(type(target.getOnlineID) == "function" and target:getOnlineID() or target)
    elseif instanceof(target, "IsoPlayer") then
        value = "P:" .. Shared.Username(target)
    elseif instanceof(target, "BaseVehicle") then
        -- Vehicles cross trip wires too, and need their own stable key so a
        -- car parked across a wire is claimed once rather than re-triggering
        -- it every tick until it drives off again.
        value = "V:" .. tostring(type(target.getId) == "function" and target:getId() or target)
    elseif type(target.getOnlineID) == "function" then
        value = "O:" .. tostring(target:getOnlineID())
    else
        value = "O:" .. tostring(target)
    end

    Logger.Finish(run, true, value)
    return value
end

-- Every trigger shares this distance gate; arming is permanent until the
-- device is reset/reversed or explicitly rearmed, even if the setter returns.
local function clearArmPending(record, players)
    if not record.armPending and not record.pendingArm then return false end
    if not Arming.TryArm(record, players or collectPlayers()) then return false end
    Registry.MarkDirty("trap armed")
    Logger.Audit("TRAP_ARMED", record.owner, "id=" .. record.id .. " | kind=" .. tostring(record.kind))

    -- The ground item's SVSBT_ArmPending modData tag (read by the client's
    -- pickup guard) would otherwise stay stuck true forever after this,
    -- making a now-genuinely-live trap look safe to just grab.
    if Shared.FloorKinds[record.kind] then
        updateWorldItemMetadata(record)
    end

    return true
end

-- Presence-based, not time-based: a target stays "claimed" (can't re-trigger
-- the same trap) only for as long as it's continuously found on the trap's
-- square. The moment processFloorTrap no longer sees it there (releaseAbsentTargets,
-- called once per tick with everyone actually present), it's cleared -- so
-- stepping off and back on retriggers immediately, with no artificial wait.
local function claimTarget(record, target)
    local run = Logger.Begin("Service.claimTarget", record.id)
    local bucket = Service.TargetCooldowns[record.id] or {}
    local key = targetKey(target)

    if bucket[key] then
        Logger.Finish(run, true, "still on the square since last trigger")
        return false
    end

    bucket[key] = true
    Service.TargetCooldowns[record.id] = bucket
    Logger.Finish(run, true, "claimed")
    return true
end

local function releaseAbsentTargets(record, presentKeys)
    local bucket = Service.TargetCooldowns[record.id]
    if not bucket then return end

    for key in pairs(bucket) do
        if not presentKeys[key] then bucket[key] = nil end
    end
end

local function bearSettingRisk(player, condition)
    local run = Logger.Begin("Service.bearSettingRisk")
    local combined = Shared.PerkLevel(player, Perks.Trapping) + Shared.PerkLevel(player, Perks.MetalWelding)
    local chance

    if combined <= 9 then chance = 0.25
    elseif combined <= 12 then chance = 0.15
    elseif combined <= 15 then chance = 0.07
    else chance = 0.02 end

    condition = math.max(1, math.min(100, tonumber(condition) or 100))

    if condition < 25 then chance = chance + 0.40
    elseif condition < 50 then chance = chance + 0.25
    elseif condition < 75 then chance = chance + 0.10 end

    chance = math.min(0.70, chance * Config.Get("BearTrapSettingRiskMultiplier"))
    Logger.Finish(run, true, "combined=" .. tostring(combined) .. " | chance=" .. tostring(chance))
    return chance
end

local function placeWorldItem(player, item, square)
    local run = Logger.Begin("Service.placeWorldItem")
    local originalContainer = item and item:getContainer() or nil

    if not item or not square or not originalContainer then
        return finishFailure(run, "PLACEMENT_INPUT_INVALID")
    end

    -- Detach from hands first, like vanilla trap placement.
    if player then
        if player:getPrimaryHandItem() == item then player:setPrimaryHandItem(nil) end
        if player:getSecondaryHandItem() == item then player:setSecondaryHandItem(nil) end
    end

    originalContainer:Remove(item)
    local ok, worldObject = pcall(function()
        return square:AddWorldInventoryItem(item, 0.5, 0.5, 0)
    end)

    if not ok or not worldObject then
        originalContainer:AddItem(item)
        netAddSync(originalContainer, item)
        return finishFailure(run, "WORLD_ITEM_PLACEMENT_FAILED")
    end

    if type(isServer) == "function" and isServer() and type(sendRemoveItemFromContainer) == "function" then
        pcall(sendRemoveItemFromContainer, originalContainer, item)
    end

    Logger.Finish(run, true, "itemId=" .. tostring(item:getID()))
    return worldObject
end

local function removeWorldTrapItem(record)
    local run = Logger.Begin("Service.removeWorldTrapItem", record and record.id)
    local worldObject = record and Shared.WorldItemAt(record.x, record.y, record.z, record.worldItemId) or nil

    if not worldObject or not worldObject:getSquare() then
        Logger.Finish(run, true, "already absent")
        return false
    end

    if record.kind == Shared.Kind.BearTrap and record.occupant then
        Creatures.Release(record)
        if record.heldUsername then releaseHeldPlayer(record.heldUsername) end
    end
    local square = worldObject:getSquare()
    square:transmitRemoveItemFromSquare(worldObject)

    if type(square.removeWorldObject) == "function" then
        square:removeWorldObject(worldObject)
    end

    Logger.Finish(run, true, "removed")
    return true
end

function Service.Initialize()
    local run = Logger.Begin("Service.Initialize")

    if Service.Initialized then
        Logger.Finish(run, true, "already initialized")
        return true
    end

    Registry.Initialize()
    Config.RefreshLogging()

    -- Rebuild short fuses after a restart instead of leaving triggered traps
    -- permanently inert.  Overdue fuses complete on the next server tick.
    for _, record in ipairs(Registry.OrderedTraps()) do
        if record.state == Shared.State.Triggered
            and (record.kind == Shared.Kind.ExplosiveMailbox or record.kind == Shared.Kind.IgnitionCharge) then
            Service.PendingExplosions[record.id] = {
                trapId = record.id,
                dueAtHours = tonumber(record.explosionDueAtHours) or Shared.WorldAgeHours(),
                x = record.x, y = record.y, z = record.z,
                source = record.kind,
            }
        elseif record.kind == Shared.Kind.BearTrap then
            -- One-time self-heal on every restart: a BearTrapClosed ground
            -- item left over from before the single-state revert would
            -- otherwise sit stuck forever, since swapBearTrapVisual is
            -- normally only reached by touching the record again.
            swapBearTrapVisual(record)
        end
    end
    Service.Initialized = true
    Logger.Info("Service.Initialize", "authoritative booby-trap service initialized")
    Logger.Finish(run, true)
    return true
end

function Service.PlaceFloorTrap(player, args)
    local run = Logger.Begin("Service.PlaceFloorTrap", Shared.Username(player))
    Service.Initialize()
    local square = squareAt(args)
    if not square then return finishFailure(run, "SQUARE_NOT_LOADED") end

    -- The item may already be a loose ground item (dropped, or spotted lying
    -- around) rather than something the player is carrying -- setting it
    -- shouldn't require picking it up into inventory first.
    local item = findItem(player, args and args.itemId)
    local groundObject = nil

    if not item then
        groundObject = Shared.WorldItemAt(square:getX(), square:getY(), square:getZ(), args and args.itemId)
        item = groundObject and groundObject:getItem() or nil
    end

    if not item then return finishFailure(run, "ITEM_NOT_FOUND") end

    local kind = Shared.ItemToKind[item:getFullType()]
    if kind == Shared.Kind.BearTrap and groundObject then
        return finishFailure(run, "Pick up the bear trap before setting it.")
    end

    if not Shared.FloorKinds[kind] and kind ~= Shared.Kind.BiologicalSample then
        return finishFailure(run, "INVALID_FLOOR_TRAP_ITEM")
    end

    if not Shared.FeatureEnabledForKind(kind) then return finishFailure(run, "FEATURE_DISABLED") end
    local eligible, eligibleReason = validateOwnerEligibility(player)
    if not eligible then return finishFailure(run, eligibleReason) end
    if not Shared.IsAdmin(player) then
        local recipeGap = Shared.RecipeGap(player, kind)
        if recipeGap then return finishFailure(run, recipeGap) end
        local requirementGap = Shared.RequirementGap(player, kind)
        if requirementGap then return finishFailure(run, requirementGap) end
    end
    local inRange, rangeReason = validateRange(player, square:getX(), square:getY())
    if not inRange then return finishFailure(run, rangeReason) end
    if math.floor(player:getZ()) ~= square:getZ() then return finishFailure(run, "TARGET_ON_DIFFERENT_FLOOR") end
    if unauthorizedSafehouse(player, square) then return finishFailure(run, "SAFEHOUSE_PROTECTED") end
    local limits, limitReason = validateLimits(player, kind, square:getX(), square:getY(), square:getZ())
    if not limits then return finishFailure(run, limitReason) end

    local nailBoardUses = kind == Shared.Kind.NailBoard
        and math.max(0, math.floor(tonumber(item:getModData().SVSBT_TriggerCount) or 0)) or 0
    if nailBoardUses >= 4 then return finishFailure(run, "NAIL_BOARD_EXHAUSTED") end

    local worldObject, placementReason
    if groundObject then
        -- Already sitting on the target square; nothing to move.
        worldObject = groundObject
    else
        worldObject, placementReason = placeWorldItem(player, item, square)
        if not worldObject then return finishFailure(run, placementReason) end
    end

    -- A sealed sample is inert until explicitly opened (Service.OpenBiologicalAgent);
    -- everything else arms immediately like it always has.
    local state = kind == Shared.Kind.BiologicalSample and Shared.State.Placed or Shared.State.Armed
    local itemData = item:getModData()
    local maxCondition = kind == Shared.Kind.BearTrap
        and math.max(1, math.min(100, tonumber(itemData.SVSBT_MaxCondition) or 100)) or 100
    local condition = kind == Shared.Kind.BearTrap
        and math.max(1, math.min(maxCondition, tonumber(itemData.SVSBT_Condition) or maxCondition)) or 100
    local failedSet = false

    if kind == Shared.Kind.BearTrap and randomChance(bearSettingRisk(player, condition)) then
        failedSet = true
        state = Shared.State.Sprung
        condition = math.max(1, condition - (Config.Get("BearTrapFailedSetConditionLoss") * Config.Get("ConditionLossMultiplier")))
        Combat.Apply({ owner = Shared.Username(player), kind = Shared.Kind.BearTrap }, player, Effects.InjureSettingArm, 10)
    end

    local record = Registry.AddTrap({
        kind = kind,
        state = state,
        owner = Shared.Username(player),
        x = square:getX(), y = square:getY(), z = square:getZ(),
        worldItemId = item:getID(),
        condition = kind == Shared.Kind.NailBoard and (100 - nailBoardUses * 25) or condition,
        maxCondition = maxCondition,
        triggerCount = nailBoardUses,
        -- Inert until the owner (standing right on it) has moved
        -- two tiles away -- see clearArmPending/activateFloorTrap.
        armPending = state == Shared.State.Armed,
        armPendingSetBy = Shared.Username(player),
    })

    -- Tags the ground item with SVSBT_TrapId/State from the moment it's
    -- placed (not just after its first trigger) -- the pickup-guard hook
    -- (ISGrabItemAction, SVSBT_Hooks.lua) reads this to recognize a live
    -- armed trap and detonate it instead of letting it be silently grabbed.
    updateWorldItemMetadata(record)

    -- A bear trap that sprang shut on the setter's own arm was never set:
    -- that path already has its own snap and injury, so it stays silent here.
    if not failedSet then Effects.PlayTrapSetSound(square) end

    Logger.Audit("PLACE_FLOOR_TRAP", Shared.Username(player),
        "id=" .. tostring(record.id) .. " | kind=" .. tostring(kind) .. " | failedSet=" .. tostring(failedSet))
    Registry.Persist("floor placement")
    Logger.Finish(run, true, "id=" .. tostring(record.id))
    return { action = "PLACE_FLOOR_TRAP", trapId = record.id, kind = kind, state = state, failedSet = failedSet }
end


function Service.RigMailbox(player, args)
    local run = Logger.Begin("Service.RigMailbox", Shared.Username(player))
    Service.Initialize()
    local item, reason = validateItem(player, args and args.itemId, Shared.Item.ExplosiveParcel)
    if not item then return finishFailure(run, reason) end
    if not Shared.FeatureEnabledForKind(Shared.Kind.ExplosiveMailbox) then return finishFailure(run, "FEATURE_DISABLED") end
    local eligible, eligibleReason = validateOwnerEligibility(player)
    if not eligible then return finishFailure(run, eligibleReason) end
    if not Shared.IsAdmin(player) then
        local recipeGap = Shared.RecipeGap(player, Shared.Kind.ExplosiveMailbox)
        if recipeGap then return finishFailure(run, recipeGap) end
        local requirementGap = Shared.RequirementGap(player, Shared.Kind.ExplosiveMailbox)
        if requirementGap then return finishFailure(run, requirementGap) end
    end
    local square = squareAt(args)
    if not square then return finishFailure(run, "SQUARE_NOT_LOADED") end
    local object = Shared.ObjectAt(square:getX(), square:getY(), square:getZ(), args.objectIndex, Shared.IsMailbox)
    if not Shared.IsMailbox(object) then return finishFailure(run, "CONTAINER_REQUIRED") end
    local inRange, rangeReason = validateRange(player, square:getX(), square:getY())
    if not inRange then return finishFailure(run, rangeReason) end
    if unauthorizedSafehouse(player, square) then return finishFailure(run, "SAFEHOUSE_PROTECTED") end
    local mailboxCount = Registry.CountTraps(function(record)
        return record.kind == Shared.Kind.ExplosiveMailbox
            and record.x == square:getX() and record.y == square:getY() and record.z == square:getZ()
            and record.state == Shared.State.Armed
    end)
    if mailboxCount >= Config.Get("MaxTrapsPerMailbox") then return finishFailure(run, "MAILBOX_TRAP_LIMIT_REACHED") end
    local limits, limitReason = validateLimits(player, Shared.Kind.ExplosiveMailbox, square:getX(), square:getY(), square:getZ())
    if not limits then return finishFailure(run, limitReason) end

    removeInventoryItem(item)
    local record = Registry.AddTrap({
        kind = Shared.Kind.ExplosiveMailbox,
        state = Shared.State.Armed,
        owner = Shared.Username(player),
        x = square:getX(), y = square:getY(), z = square:getZ(),
        objectIndex = Shared.ObjectIndex(object),
        objectSprite = object:getSprite() and tostring(object:getSprite():getName() or "") or "",
        armPending = true, armPendingSetBy = Shared.Username(player),
    })
    Effects.PlayTrapSetSound(square)
    Logger.Audit("RIG_MAILBOX", Shared.Username(player), "id=" .. record.id)
    Registry.Persist("mailbox rigged")
    Logger.Finish(run, true, "id=" .. record.id)
    return { action = "RIG_MAILBOX", trapId = record.id, kind = record.kind }
end

-- Stake 1 is the player's own square (where they're standing); stake 2 is
-- wherever they right-click to connect the wire to, up to
-- TripWireMaxLengthTiles apart. Both endpoints are stored on the record
-- (x/y for stake 1, x2/y2 for stake 2); processTripWire walks the straight
-- line of tiles between them each tick.
function Service.PlaceTripWire(player, args)
    local run = Logger.Begin("Service.PlaceTripWire", Shared.Username(player))
    Service.Initialize()
    local item, reason = validateItem(player, args and args.itemId, Shared.Item.TripWireKit)
    if not item then return finishFailure(run, reason) end
    if not Shared.FeatureEnabledForKind(Shared.Kind.TripWire) then return finishFailure(run, "FEATURE_DISABLED") end
    local eligible, eligibleReason = validateOwnerEligibility(player)
    if not eligible then return finishFailure(run, eligibleReason) end
    if not Shared.IsAdmin(player) then
        local recipeGap = Shared.RecipeGap(player, Shared.Kind.TripWire)
        if recipeGap then return finishFailure(run, recipeGap) end
        local requirementGap = Shared.RequirementGap(player, Shared.Kind.TripWire)
        if requirementGap then return finishFailure(run, requirementGap) end
    end

    local square1 = args and args.x1 ~= nil
        and squareAt({ x = args.x1, y = args.y1, z = args.z1 }) or player:getSquare()
    if not square1 then return finishFailure(run, "SQUARE_NOT_LOADED") end
    local square2 = squareAt(args)
    if not square2 then return finishFailure(run, "SQUARE_NOT_LOADED") end
    if square1:getZ() ~= square2:getZ() or math.floor(player:getZ()) ~= square2:getZ() then
        return finishFailure(run, "TARGET_ON_DIFFERENT_FLOOR")
    end

    local maxLength = Config.Get("TripWireMaxLengthTiles")
    local length = Shared.Distance(square1:getX(), square1:getY(), square2:getX(), square2:getY())
    if length < 1 then return finishFailure(run, "TRIP_WIRE_TOO_SHORT") end
    if length > maxLength then return finishFailure(run, "TRIP_WIRE_TOO_LONG") end

    local inRange, rangeReason = validateRange(player, square2:getX(), square2:getY(), maxLength + 0.5)
    if not inRange then return finishFailure(run, rangeReason) end
    if unauthorizedSafehouse(player, square1) or unauthorizedSafehouse(player, square2) then
        return finishFailure(run, "SAFEHOUSE_PROTECTED")
    end
    local limits, limitReason = validateLimits(player, Shared.Kind.TripWire, square1:getX(), square1:getY(), square1:getZ())
    if not limits then return finishFailure(run, limitReason) end

    removeInventoryItem(item)
    local record = Registry.AddTrap({
        kind = Shared.Kind.TripWire,
        state = Shared.State.Armed,
        owner = Shared.Username(player),
        x = square1:getX(), y = square1:getY(), z = square1:getZ(),
        x2 = square2:getX(), y2 = square2:getY(),
        armPending = true, armPendingSetBy = Shared.Username(player),
    })

    Effects.PlayTrapSetSound(square1)
    Logger.Audit("PLACE_TRIP_WIRE", Shared.Username(player),
        "id=" .. record.id .. " | length=" .. tostring(length))
    Registry.Persist("trip wire placed")
    Logger.Finish(run, true, "id=" .. record.id)
    return { action = "PLACE_TRIP_WIRE", trapId = record.id, kind = record.kind }
end

local function vehicleFromArgs(args)
    local run = Logger.Begin("Service.vehicleFromArgs")
    local vehicle = nil

    if type(getVehicleById) == "function" and args and tonumber(args.vehicleId) then
        vehicle = getVehicleById(tonumber(args.vehicleId))
    end

    if not vehicle and args and args.vehicleUid then
        vehicle = Shared.FindVehicleByUID(tostring(args.vehicleUid))
    end

    if not vehicle then
        return finishFailure(run, "VEHICLE_NOT_FOUND")
    end

    Logger.Finish(run, true, "vehicleId=" .. tostring(vehicle:getId()))
    return vehicle
end

function Service.InstallVehicleDevice(player, args)
    local run = Logger.Begin("Service.InstallVehicleDevice", Shared.Username(player))
    Service.Initialize()
    local item, reason = findItem(player, args and args.itemId)
    if not item then return finishFailure(run, reason) end
    local kind = Shared.ItemToKind[item:getFullType()]
    if not Shared.VehicleKinds[kind] then return finishFailure(run, "INVALID_VEHICLE_DEVICE") end
    if not Shared.FeatureEnabledForKind(kind) then return finishFailure(run, "FEATURE_DISABLED") end
    local eligible, eligibleReason = validateOwnerEligibility(player)
    if not eligible then return finishFailure(run, eligibleReason) end

    -- Every other placement function exempts admins from these two gates;
    -- this one was missing that guard entirely, rejecting even an admin who
    -- lacked the skill/recipe -- inconsistent with the rest of the mod.
    if not Shared.IsAdmin(player) then
        local recipeGap = Shared.RecipeGap(player, kind)
        if recipeGap then return finishFailure(run, recipeGap) end
        local requirementGap = Shared.RequirementGap(player, kind)
        if requirementGap then return finishFailure(run, requirementGap) end
    end

    local vehicle, vehicleReason = vehicleFromArgs(args)
    if not vehicle then return finishFailure(run, vehicleReason) end
    local inRange, rangeReason = validateRange(player, vehicle:getX(), vehicle:getY())
    if not inRange then return finishFailure(run, rangeReason) end
    if vehicle:getCurrentSpeedKmHour() and math.abs(vehicle:getCurrentSpeedKmHour()) > 0.1 then
        return finishFailure(run, "VEHICLE_MUST_BE_STATIONARY")
    end
    -- Only the ignition charge cares about engine state at install time (it's
    -- literally what arms it); the dye trap, tamper alarm, and immobilizer
    -- can be fitted while the engine's running.
    if kind == Shared.Kind.IgnitionCharge and vehicle:isEngineRunning() then
        return finishFailure(run, "ENGINE_MUST_BE_OFF")
    end
    if unauthorizedSafehouse(player, vehicle:getSquare()) then return finishFailure(run, "SAFEHOUSE_PROTECTED") end

    local uid = Shared.VehicleUID(vehicle, true)
    local limits, limitReason = validateLimits(player, kind, vehicle:getX(), vehicle:getY(), vehicle:getZ(), uid)
    if not limits then return finishFailure(run, limitReason) end

    local sameKind = Registry.CountTraps(function(record)
        return record.vehicleUid == uid and record.kind == kind
            and record.state ~= Shared.State.Destroyed and record.state ~= Shared.State.Spent
    end)
    if sameKind > 0 then return finishFailure(run, "DEVICE_TYPE_ALREADY_INSTALLED") end

    removeInventoryItem(item)
    local record = Registry.AddTrap({
        kind = kind,
        state = Shared.State.Armed,
        owner = Shared.Username(player),
        vehicleUid = uid,
        x = vehicle:getX(), y = vehicle:getY(), z = vehicle:getZ(),
        lastEngineRunning = vehicle:isEngineRunning(),
        lastDriverName = vehicle:getDriver() and Shared.Username(vehicle:getDriver()) or nil,
        immobilized = false,
        -- Only the immobilizer needs a deliberate, separate sync step (see
        -- Service.SyncController); the tamper alarm's controller is still
        -- bound immediately below, exactly as before.
        controllerSynced = kind ~= Shared.Kind.RemoteImmobilizer,
        lastHeartbeatHours = Shared.WorldAgeHours(),
        armPending = true, armPendingSetBy = Shared.Username(player),
    })

    local controller = nil

    if kind == Shared.Kind.TamperAlarm then
        controller = addInventoryItem(player, Shared.Item.Controller, {
            SVSBT_DeviceId = record.id,
            SVSBT_DeviceKind = kind,
            SVSBT_VehicleUID = uid,
            SVSBT_Owner = record.owner,
        })
    elseif kind == Shared.Kind.RemoteImmobilizer then
        -- Handed over blank/unsynced -- it does nothing until the player
        -- pairs it to THIS specific immobilizer with Service.SyncController
        -- while within sync range of the vehicle. Exactly one controller
        -- can ever be bound to one immobilizer, and the pairing is
        -- permanent once made.
        controller = addInventoryItem(player, Shared.Item.Controller, { SVSBT_ForKind = kind })
    end

    Effects.PlayTrapSetSound(vehicle:getSquare() or player:getSquare())
    Logger.Audit("INSTALL_VEHICLE_DEVICE", Shared.Username(player),
        "id=" .. record.id .. " | kind=" .. kind .. " | vehicleUid=" .. uid)
    Registry.Persist("vehicle device installed")
    Logger.Finish(run, true, "id=" .. record.id)
    return {
        action = "INSTALL_VEHICLE_DEVICE",
        trapId = record.id,
        kind = kind,
        controllerItemId = controller and controller:getID() or nil,
        controllerSynced = record.controllerSynced == true,
    }
end

function Service.ContaminateDocument(player, args)
    local run = Logger.Begin("Service.ContaminateDocument", Shared.Username(player))
    Service.Initialize()
    if not Shared.FeatureEnabledForKind(Shared.Kind.AnthraxDocument) then
        return finishFailure(run, "FEATURE_DISABLED")
    end
    local eligible, eligibleReason = validateOwnerEligibility(player)
    if not eligible then return finishFailure(run, eligibleReason) end
    if not Shared.IsAdmin(player) then
        local recipeGap = Shared.RecipeGap(player, Shared.Kind.AnthraxDocument)
        if recipeGap then return finishFailure(run, recipeGap) end
        local requirementGap = Shared.RequirementGap(player, Shared.Kind.AnthraxDocument)
        if requirementGap then return finishFailure(run, requirementGap) end
    end
    local agent, agentReason = validateItem(player, args and args.agentItemId, Shared.Item.AnthraxAgent)
    if not agent then return finishFailure(run, agentReason) end
    local document, documentReason = findItem(player, args and args.documentItemId)
    if not document then return finishFailure(run, documentReason) end
    if not Shared.IsReadableDocument(document) then return finishFailure(run, "READABLE_DOCUMENT_REQUIRED") end
    if Registry.GetDocument(document:getID()) then return finishFailure(run, "DOCUMENT_ALREADY_CONTAMINATED") end

    removeInventoryItem(agent)
    local record = Registry.AddDocument({
        itemId = document:getID(),
        fullType = document:getFullType(),
        originalName = document:getName(),
        owner = Shared.Username(player),
        state = Shared.State.Armed,
    })
    Arming.Begin(record, player)
    Arming.TrackDocument(record, document)
    local data = document:getModData()
    data.SVSBT_Contaminated = true
    data.SVSBT_DocumentRecord = record.id

    -- InventoryItem has no transmitModData() -- without a resync, the
    -- contaminated flag (which SVSBT_Render.lua's renderItemIcon hook reads
    -- client-side to draw the warning icon) never reaches the reader's own
    -- client in multiplayer.
    netAddSync(document:getContainer(), document)

    Logger.Audit("CONTAMINATE_DOCUMENT", Shared.Username(player),
        "documentId=" .. tostring(document:getID()) .. " | type=" .. tostring(document:getFullType()))
    Registry.Persist("document contaminated")
    Logger.Finish(run, true, "record=" .. record.id)
    return { action = "CONTAMINATE_DOCUMENT", documentId = document:getID(), recordId = record.id }
end

local function controllerRecord(player, args)
    local run = Logger.Begin("Service.controllerRecord")
    local controller, reason = validateItem(player, args and args.controllerItemId, Shared.Item.Controller)
    if not controller then return finishFailure(run, reason) end
    local trapId = tostring(controller:getModData().SVSBT_DeviceId or "")
    local record = Registry.GetTrap(trapId)

    if not record or (record.kind ~= Shared.Kind.TamperAlarm and record.kind ~= Shared.Kind.RemoteImmobilizer) then
        return finishFailure(run, "CONTROLLER_NOT_PAIRED")
    end

    if record.owner ~= Shared.Username(player) and not Shared.IsAdmin(player) then
        return finishFailure(run, "CONTROLLER_OWNER_MISMATCH")
    end

    Logger.Finish(run, true, "trap=" .. trapId)
    return record, nil, controller
end

-- Pairing an immobilizer's controller is a deliberate act, distinct from
-- every other proximity gate in this mod (which uses a 1-tile radius) --
-- the mod's design calls for exactly 2 tiles here, so this stays its own
-- constant rather than reusing ADJACENT_TILE_DISTANCE.
local SYNC_RANGE_TILES = 2

local function withinSyncRange(player, x, y)
    if Shared.IsAdmin(player) then return true end
    if not player then return false end
    return math.max(math.abs(player:getX() - x), math.abs(player:getY() - y)) <= SYNC_RANGE_TILES
end

-- Permanently binds one blank controller to one installed-but-unpaired
-- immobilizer. Exactly one pair can ever exist for a given immobilizer, and
-- a controller that is already bound (to this device or any other) can
-- never be re-synced -- losing a synced controller means the immobilizer
-- can only be recovered by disarming and reinstalling a fresh unit.
function Service.SyncController(player, args)
    local run = Logger.Begin("Service.SyncController", Shared.Username(player))
    Service.Initialize()
    if not Shared.FeatureEnabledForKind(Shared.Kind.RemoteImmobilizer) then
        return finishFailure(run, "FEATURE_DISABLED")
    end
    if not claimCooldown(player, "sync_controller", 400) then return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE") end

    local controller, controllerReason = validateItem(player, args and args.controllerItemId, Shared.Item.Controller)
    if not controller then return finishFailure(run, controllerReason) end
    if controller:getModData().SVSBT_DeviceId then
        return finishFailure(run, "CONTROLLER_ALREADY_SYNCED")
    end

    local vehicle, vehicleReason = vehicleFromArgs(args)
    if not vehicle then return finishFailure(run, vehicleReason) end
    if not withinSyncRange(player, vehicle:getX(), vehicle:getY()) then
        return finishFailure(run, "TARGET_TOO_FAR_AWAY")
    end

    local uid = Shared.VehicleUID(vehicle, false)
    local candidates = uid and Registry.FindTraps(function(candidate)
        return candidate.vehicleUid == uid and candidate.kind == Shared.Kind.RemoteImmobilizer
            and candidate.state ~= Shared.State.Destroyed and candidate.state ~= Shared.State.Spent
    end) or {}
    local record = candidates[1]

    if not record then return finishFailure(run, "IMMOBILIZER_NOT_INSTALLED") end
    if record.controllerSynced == true then return finishFailure(run, "IMMOBILIZER_ALREADY_SYNCED") end
    if record.owner ~= Shared.Username(player) and not Shared.IsAdmin(player) then
        return finishFailure(run, "CONTROLLER_OWNER_MISMATCH")
    end

    local data = controller:getModData()
    data.SVSBT_DeviceId = record.id
    data.SVSBT_DeviceKind = record.kind
    data.SVSBT_VehicleUID = uid
    data.SVSBT_Owner = record.owner

    -- InventoryItem has no transmitModData() (it only exists on
    -- IsoObject/world objects, like the vehicle above), so without this
    -- every client keeps a blank controller and never offers "Toggle Paired
    -- Device". netAddSync pushes the carried item's current state back down
    -- to its owner.
    netAddSync(player:getInventory(), controller)

    record.controllerSynced = true
    record.updatedAtHours = Shared.WorldAgeHours()
    Registry.MarkDirty("controller synced")

    Logger.Audit("SYNC_CONTROLLER", Shared.Username(player),
        "id=" .. record.id .. " | controllerItemId=" .. tostring(controller:getID()))
    Registry.Persist("controller synced")
    Logger.Finish(run, true, "id=" .. record.id)
    -- The resend above does not update an item the client already holds, so
    -- the reply carries the pairing for the client to write on its own copy.
    return { action = "SYNC_CONTROLLER", trapId = record.id, controllerItemId = controller:getID(),
        deviceKind = record.kind, vehicleUid = uid, owner = record.owner }
end

local function isSignalsJammedAt(x, y)
    local run = Logger.Begin("Service.isSignalsJammedAt")

    if not Config.Get("SignalsIntegrationEnabled") or not SVS or not SVS.Signals
        or not SVS.Signals.Server or not SVS.Signals.Server.SignalService then
        Logger.Finish(run, true, "signals unavailable")
        return false
    end

    local signalService = SVS.Signals.Server.SignalService
    local data = signalService.Data
    local runtime = signalService.PortableRuntime

    if type(data) ~= "table" or type(data.portables) ~= "table" or type(runtime) ~= "table" then
        Logger.Finish(run, true, "signal state unavailable")
        return false
    end

    local radius = 75

    if SVS.Signals.Config and type(SVS.Signals.Config.Get) == "function" then
        radius = tonumber(SVS.Signals.Config.Get("JammerRadiusTiles")) or radius
    end

    for key, portable in pairs(data.portables) do
        local holder = runtime[tostring(key)]

        if portable.kind == "JAMMER" and portable.active == true and (tonumber(portable.battery) or 0) > 0
            and holder and Shared.Distance(x, y, holder.x, holder.y) <= radius then
            Logger.Finish(run, true, "jammed")
            return true
        end
    end

    Logger.Finish(run, true, "clear")
    return false
end

function Service.ControllerCommand(player, args)
    local run = Logger.Begin("Service.ControllerCommand", Shared.Username(player))
    Service.Initialize()
    if not claimCooldown(player, "controller_command", 400) then return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE") end
    local record, reason = controllerRecord(player, args)
    if not record then return finishFailure(run, reason) end

    -- Once synced, an immobilizer's controller works from anywhere and never
    -- reveals the vehicle's location -- unlike every other wireless device
    -- here, it needs neither the vehicle to be currently loaded nor a
    -- WirelessRangeTiles check.
    local unlimitedRange = record.kind == Shared.Kind.RemoteImmobilizer
    local vehicle = Shared.FindVehicleByUID(record.vehicleUid)

    if not vehicle and not unlimitedRange then
        return finishFailure(run, "VEHICLE_NOT_LOADED")
    end

    local distance = nil

    if not unlimitedRange then
        distance = Shared.PlayerDistanceTo(player, vehicle:getX(), vehicle:getY())
        if distance > Config.Get("WirelessRangeTiles") then return finishFailure(run, "WIRELESS_OUT_OF_RANGE") end
    end

    local command = tostring(args and args.operation or "status")
    local blocked = isSignalsJammedAt(player:getX(), player:getY())
        or (vehicle ~= nil and isSignalsJammedAt(vehicle:getX(), vehicle:getY()))

    if blocked and command ~= "status" and Config.Get("SignalsJammersBlockCommands") then
        return finishFailure(run, "WIRELESS_COMMAND_JAMMED")
    end

    if record.armPending and command == "toggle" then
        return finishFailure(run, "DEVICE_NOT_ARMED_YET")
    end

    if record.kind == Shared.Kind.RemoteImmobilizer and command == "toggle" then
        record.immobilized = not (record.immobilized == true)
        record.updatedAtHours = Shared.WorldAgeHours()

        if record.immobilized and vehicle and vehicle:isEngineRunning() then
            vehicle:shutOff()
        end

        Registry.MarkDirty("immobilizer toggled")
        Logger.Audit("REMOTE_IMMOBILIZER", Shared.Username(player),
            "id=" .. record.id .. " | immobilized=" .. tostring(record.immobilized))
    elseif record.kind == Shared.Kind.TamperAlarm and command == "toggle" then
        record.state = record.state == Shared.State.Armed and Shared.State.Disabled or Shared.State.Armed
        if record.state == Shared.State.Armed then Arming.Begin(record, player); clearArmPending(record) end
        Registry.MarkDirty("alarm toggled")
        Logger.Audit("TOGGLE_TAMPER_ALARM", Shared.Username(player),
            "id=" .. record.id .. " | state=" .. tostring(record.state))
    elseif command ~= "status" then
        return finishFailure(run, "UNSUPPORTED_CONTROLLER_COMMAND")
    end

    Registry.Persist("controller command")
    Logger.Finish(run, true, "operation=" .. command)
    return {
        action = "CONTROLLER_COMMAND",
        operation = command,
        trapId = record.id,
        kind = record.kind,
        state = record.state,
        armPending = record.armPending == true,
        immobilized = record.immobilized == true,
        distance = distance and math.floor(distance) or nil,
        jammed = blocked,
    }
end

-- Only ExplosiveMailbox still uses a physical world OBJECT (the mailbox
-- itself) rather than a real world ITEM -- water bucket/shotgun are real
-- floor traps now, resolved via Shared.WorldItemAt like NailBoard/BearTrap.
local function recordObject(record)
    local run = Logger.Begin("Service.recordObject", record and record.id)
    local object = record and Shared.ObjectAt(record.x, record.y, record.z, record.objectIndex) or nil

    if object and record.objectSprite and record.objectSprite ~= "" then
        local spriteName = object:getSprite() and tostring(object:getSprite():getName() or "") or ""

        if spriteName ~= record.objectSprite then
            object = nil
        end
    end

    -- Object indices can change as a square is rebuilt. Recover the exact
    -- sprite, or the only mailbox on the square, instead of silently losing
    -- the rigged mailbox's contents/association.
    if not object and record then
        local square = getCell() and getCell():getGridSquare(
            math.floor(record.x), math.floor(record.y), math.floor(record.z)) or nil
        local objects = square and square:getObjects() or nil

        if objects then
            for i = 0, objects:size() - 1 do
                local candidate = objects:get(i)
                local spriteName = candidate and candidate:getSprite()
                    and tostring(candidate:getSprite():getName() or "") or ""
                local exactSprite = record.objectSprite and record.objectSprite ~= ""
                    and spriteName == record.objectSprite
                local compatible = record.kind == Shared.Kind.ExplosiveMailbox and Shared.IsMailbox(candidate)

                if exactSprite or compatible then
                    object = candidate
                    record.objectIndex = Shared.ObjectIndex(candidate)
                    Registry.MarkDirty("object index recovered")
                    break
                end
            end
        end
    end

    Logger.Finish(run, true, "found=" .. tostring(object ~= nil))
    return object
end

function Service.ScheduleExplosion(record, player, fuseSeconds, source)
    local run = Logger.Begin("Service.ScheduleExplosion", record and record.id)

    if not record then return finishFailure(run, "TRAP_RECORD_REQUIRED") end
    if record.armPending then return finishFailure(run, "DEVICE_NOT_ARMED_YET") end
    fuseSeconds = math.max(0.25, tonumber(fuseSeconds) or Config.Get("ExplosiveFuseSeconds"))
    record.state = Shared.State.Triggered
    record.triggeredAtHours = Shared.WorldAgeHours()
    record.triggeredBy = player and Shared.Username(player) or "environment"
    record.explosionDueAtHours = Shared.WorldAgeHours() + (fuseSeconds / 3600)
    Service.PendingExplosions[record.id] = {
        trapId = record.id,
        dueAtMs = nowMs() + math.floor(fuseSeconds * 1000),
        dueAtHours = record.explosionDueAtHours,
        x = record.x, y = record.y, z = record.z,
        source = source or record.kind,
    }
    Registry.MarkDirty("explosion scheduled")

    local square = getCell() and getCell():getGridSquare(math.floor(record.x), math.floor(record.y), math.floor(record.z)) or nil
    Effects.PlaySound("PZ_MetalSnap", square, 12, 20)

    if player then
        send(player, "WARNING", {
            trapId = record.id,
            source = source or record.kind,
            fuseSeconds = fuseSeconds,
            message = "A sharp metallic click comes from the trap!",
        })
    end

    Logger.Audit("TRAP_TRIGGERED", player and Shared.Username(player) or "environment",
        "id=" .. record.id .. " | kind=" .. tostring(record.kind) .. " | fuse=" .. tostring(fuseSeconds))
    Logger.Finish(run, true, "dueAt=" .. tostring(Service.PendingExplosions[record.id].dueAtMs))
    return true
end


function Service.MailboxAccessed(player, args)
    local run = Logger.Begin("Service.MailboxAccessed", Shared.Username(player))
    Service.Initialize()
    -- This exists only to stop a broken/malicious client from flooding the
    -- command itself -- a real repeat trigger of the SAME trap is already
    -- impossible regardless, since it only ever fires from Armed state and
    -- flips to Triggered/Destroyed the instant it does. 2000ms was long
    -- enough to also catch a real second attempt a moment later (opening
    -- the mailbox UI fires this more than once per genuine click), reading
    -- as "some other cooldown" blocking a legitimate detonation on top of
    -- the real arm-pending distance mechanic. 100ms is well past anything
    -- a human click pattern can produce but still blocks true spam.
    if not claimCooldown(player, "mailbox_accessed", 100) then return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE") end
    local square = squareAt(args)
    if not square then return finishFailure(run, "SQUARE_NOT_LOADED") end
    local inRange, rangeReason = validateRange(player, square:getX(), square:getY(), Config.Get("InteractionRangeTiles") + 0.5)
    if not inRange then return finishFailure(run, rangeReason) end
    local object = Shared.ObjectAt(square:getX(), square:getY(), square:getZ(), args.objectIndex, Shared.IsMailbox)
    if not Shared.IsMailbox(object) then return finishFailure(run, "CONTAINER_REQUIRED") end
    local matches = Registry.FindTraps(function(record)
        return record.kind == Shared.Kind.ExplosiveMailbox and record.state == Shared.State.Armed
            and not record.armPending and existingFeatureOperational(record)
            and record.x == square:getX() and record.y == square:getY() and record.z == square:getZ()
            and recordObject(record) == object
    end)
    local record = matches[1]

    if not record then
        Logger.Finish(run, true, "no trap")
        return { action = "MAILBOX_ACCESSED", triggered = false }
    end

    if Registry.HasKnowledge(Shared.Username(player), record.id) then
        Logger.Finish(run, true, "inspection knowledge prevented trigger")
        return {
            action = "MAILBOX_ACCESSED",
            triggered = false,
            trapKnown = true,
            message = "You stop before disturbing the inspected mechanism.",
        }
    end

    if not canTargetPlayer(record, player, true) then
        Logger.Finish(run, true, "target protected")
        return { action = "MAILBOX_ACCESSED", triggered = false, protected = true }
    end

    Service.ScheduleExplosion(record, player, Config.Get("ExplosiveFuseSeconds"), "mailbox")
    Registry.Persist("mailbox trigger scheduled")
    Logger.Finish(run, true, "triggered")
    return { action = "MAILBOX_ACCESSED", triggered = true, fuseSeconds = Config.Get("ExplosiveFuseSeconds") }
end

-- The client-side force-learn hook (SVSBT_Hooks.lua) only updates the
-- CLIENT's copy of the character; on a dedicated server the copy that
-- validates crafting lives here.
-- Grants exactly the recipes this player's read history entitles them
-- to, and nothing else. IsoPlayer:getAlreadyReadBook() (a persisted
-- per-player list of every book/magazine fulltype ever finished) is
-- authoritative server-side, unlike anything a client says about itself.
-- Shared by the instant
-- client-triggered path and the periodic self-heal pass so the two can
-- never drift on what counts as earned.
local function grantRecipesFromReadHistory(player, auditTag)
    if type(player.getAlreadyReadBook) ~= "function" or type(player.learnRecipe) ~= "function"
        or type(player.getKnownRecipes) ~= "function" then
        return false
    end

    local ok, readBooks = pcall(function() return player:getAlreadyReadBook() end)
    if not ok or not readBooks then return false end

    local grantedAny = false

    for magazineType, recipes in pairs(Shared.MagazineRecipe) do
        if readBooks:contains(magazineType) then
            for _, recipe in ipairs(recipes) do
                if not player:getKnownRecipes():contains(recipe) then
                    player:learnRecipe(recipe)
                    grantedAny = true
                    Logger.Audit(auditTag, Shared.Username(player),
                        "magazine=" .. magazineType .. " | recipe=" .. recipe)
                end
            end
        end
    end

    return grantedAny
end

-- A client asking to learn recipes is only ever a latency optimisation --
-- it makes a just-finished read feel instant instead of waiting for the
-- next syncReadMagazineRecipes() pass. It is NOT permission, and nothing it
-- sends is used: which recipes get granted is decided here from the
-- player's own server-side read history. A modified client asking for
-- recipes it never earned therefore gets none, and a legitimate reader
-- whose read history has not reached the server yet simply gets them from
-- the next lifecycle pass instead -- a short delay, never a lost recipe.
function Service.LearnRecipes(player, args)
    local run = Logger.Begin("Service.LearnRecipes", Shared.Username(player))
    local learnedAny = grantRecipesFromReadHistory(player, "LEARN_RECIPES")

    if learnedAny and type(sendSyncPlayerFields) == "function" then
        pcall(sendSyncPlayerFields, player, 0x00000007)
    end

    Logger.Finish(run, true, "learnedAny=" .. tostring(learnedAny))
    return { action = "LEARN_RECIPES", learnedAny = learnedAny }
end

function Service.DocumentOpened(player, args)
    local run = Logger.Begin("Service.DocumentOpened", Shared.Username(player))
    Service.Initialize()
    if not claimCooldown(player, "document_opened", 500) then return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE") end
    local document, reason = findItem(player, args and args.itemId)
    if not document then return finishFailure(run, reason) end
    local record = Registry.GetDocument(document:getID())

    if record and record.armPending then
        Arming.TrackDocument(record, document)
        clearArmPending(record)
    end

    if not record or record.state ~= Shared.State.Armed or record.armPending or not existingFeatureOperational(record) then
        Logger.Finish(run, true, "clean or spent")
        return { action = "DOCUMENT_OPENED", exposed = false }
    end

    if not canTargetPlayer(record, player, true) then
        Logger.Finish(run, true, "target protected")
        return { action = "DOCUMENT_OPENED", exposed = false, protected = true }
    end

    record.state = Shared.State.Spent
    record.exposedAtHours = Shared.WorldAgeHours()
    record.spentAtHours = Shared.WorldAgeHours()
    record.exposedPlayer = Shared.Username(player)
    local data = document:getModData()
    data.SVSBT_Contaminated = nil
    data.SVSBT_PowderStained = true

    if type(document.setName) == "function" then
        local original = tostring(record.originalName or document:getName() or "Document")
        document:setName(original .. " (Powder-Stained)")
    end

    -- InventoryItem has no transmitModData() -- netAddSync pushes both the
    -- cleared SVSBT_Contaminated flag (read client-side by SVSBT_Render.lua's
    -- warning-icon hook) and the renamed title to the reader's own client,
    -- which would otherwise keep showing the stale icon/name.
    netAddSync(document:getContainer(), document)
    local factor = Combat.Apply(record, player, Effects.BeginBiologicalExposure)
    local currentHours = Shared.WorldAgeHours()
    Registry.AddExposure(Shared.Username(player), {
        sourceDocumentId = record.id, owner = record.owner, kind = record.kind,
        startedAtHours = currentHours,
        endsAtHours = currentHours + Config.Get("AnthraxDurationHours"),
        factor = factor,
        lastTickAtMs = nowMs(),
    })
    -- Fully spent: the item itself now permanently carries the real,
    -- visible "(Powder-Stained)" name and cleared contamination flag, so
    -- the registry record has nothing left to do -- remove it instead of
    -- leaving a lingering spent document that would keep blocking this same
    -- physical item from ever being re-contaminated later.
    Registry.RemoveDocument(record.itemId, "document exposed")
    Registry.Persist("biological exposure")
    -- The contaminated page is the trap, and it is in the reader's hands:
    -- it goes off where they are standing, not where it was doctored.
    soundDetonation(record, player:getSquare())
    Logger.Audit("BIOLOGICAL_EXPOSURE", Shared.Username(player),
        "document=" .. record.id .. " | factor=" .. tostring(factor))
    send(player, "WARNING", {
        source = "document",
        message = "A fine powder lifts from the page. You feel violently ill.",
    })
    Logger.Finish(run, true, "factor=" .. tostring(factor))
    return { action = "DOCUMENT_OPENED", exposed = true, protectionFactor = factor }
end

local function findPlacedBiologicalSample(square)
    return Registry.FindTraps(function(candidate)
        return candidate.kind == Shared.Kind.BiologicalSample
            and math.floor(tonumber(candidate.x) or -999999) == square:getX()
            and math.floor(tonumber(candidate.y) or -999999) == square:getY()
            and math.floor(tonumber(candidate.z) or -999999) == square:getZ()
    end)[1]
end

function Service.OpenBiologicalAgent(player, args)
    local run = Logger.Begin("Service.OpenBiologicalAgent", Shared.Username(player))
    Service.Initialize()
    if not claimCooldown(player, "open_biological_agent", 1000) then return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE") end
    local square = squareAt(args)
    if not square then return finishFailure(run, "SQUARE_NOT_LOADED") end
    local record = findPlacedBiologicalSample(square)
    if not record or record.state ~= Shared.State.Placed then return finishFailure(run, "TRAP_NOT_FOUND") end
    if not Shared.FeatureEnabledForKind(record.kind) then return finishFailure(run, "FEATURE_DISABLED") end
    local inRange, rangeReason = validateRange(player, record.x, record.y)
    if not inRange then return finishFailure(run, rangeReason) end

    record.state = Shared.State.Armed
    Arming.Begin(record, player)
    record.pendingArm = nil
    record.openedAtHours = Shared.WorldAgeHours()
    Registry.MarkDirty("biological agent opened")
    Registry.Persist("biological agent opened")
    Logger.Audit("BIOLOGICAL_AGENT_OPENED", Shared.Username(player), "id=" .. record.id)
    send(player, "WARNING", {
        source = "biological_agent",
        message = "You crack the seal. Move at least two tiles away to arm it.",
    })
    Logger.Finish(run, true, "id=" .. record.id)
    return { action = "OPEN_BIOLOGICAL_AGENT", trapId = record.id }
end

function Service.NeutralizeBiologicalAgent(player, args)
    local run = Logger.Begin("Service.NeutralizeBiologicalAgent", Shared.Username(player))
    Service.Initialize()
    if not claimCooldown(player, "neutralize_biological_agent", 1000) then return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE") end
    local square = squareAt(args)
    if not square then return finishFailure(run, "SQUARE_NOT_LOADED") end
    local record = findPlacedBiologicalSample(square)
    if not record then return finishFailure(run, "TRAP_NOT_FOUND") end

    if not Shared.IsAdmin(player) and not Shared.KnowsRecipe(player, record.kind) then
        local magazine = Shared.KindMagazine[record.kind]
        return finishFailure(run, "You don't know how to safely neutralize this"
            .. (magazine and (" -- read " .. magazine .. " first.") or "."))
    end

    local inRange, rangeReason = validateRange(player, record.x, record.y, Config.Get("InteractionRangeTiles") + 1)
    if not inRange then return finishFailure(run, rangeReason) end

    removeWorldTrapItem(record)
    Registry.RemoveTrap(record.id, "neutralized")
    addInventoryItem(player, Shared.Item.EmptyBiologicalJar)
    Registry.Persist("biological agent neutralized")
    Logger.Audit("BIOLOGICAL_AGENT_NEUTRALIZED", Shared.Username(player), "id=" .. record.id)
    Logger.Finish(run, true, "id=" .. record.id)
    return { action = "NEUTRALIZE_BIOLOGICAL_AGENT", trapId = record.id }
end

-- vehicle is optional: a trip wire has no vehicle, just a fixed position
-- (record.x/y/z), and skips the vehicle-specific alarm state entirely --
-- it's a one-off alert + sound, not a lingering "alarm sounding" visual.
-- Same key check as vanilla ISStartVehicleEngine.lua (haveThisKeyId walks
-- bags and key rings too):
-- a legitimate key holder isn't a car thief, so the tamper alarm shouldn't
-- treat them like one.
local function vehicleKeyHeldBy(player, vehicle)
    if not player or not vehicle then return false end
    local ok, held = pcall(function()
        return player:getInventory():haveThisKeyId(vehicle:getKeyId()) ~= nil
    end)
    return ok and held == true
end

function Service.TripWireAlarmSnapshot(player)
    local alarms = {}
    for id, alarm in pairs(Service.ActiveAlarms) do
        if alarm.kind == Shared.Kind.TripWire and Shared.WorldAgeHours() < alarm.endHours
            and Shared.Distance(player:getX(), player:getY(), alarm.x, alarm.y) <= Config.Get("TripWireSoundRadiusTiles") then
            alarms[id] = { x = alarm.x, y = alarm.y, z = alarm.z, endHours = alarm.endHours }
        end
    end
    return alarms
end

local function syncTripWireAlarms()
    for _, player in ipairs(collectPlayers()) do
        send(player, "TRIP_WIRE_ALARMS", { alarms = Service.TripWireAlarmSnapshot(player) })
    end
end

-- Silences a sounding trip wire house alarm immediately, rather than waiting
-- for its endHours to run out.
function Service.StopTripWireAlarm(trapId)
    local id = tostring(trapId)
    local alarm = Service.ActiveAlarms[id]
    if not alarm or alarm.kind ~= Shared.Kind.TripWire then return end

    Service.ActiveAlarms[id] = nil
    syncTripWireAlarms()
end

-- Silences a sounding vehicle tamper alarm immediately, rather than waiting
-- for its dueAtMs to expire: the same vehicle:setAlarmed(false)/
-- transmitAlarmed() pair the natural-timeout path uses.
function Service.StopVehicleAlarm(trapId)
    local id = tostring(trapId)
    local alarm = Service.ActiveAlarms[id]
    if not alarm or alarm.kind == Shared.Kind.TripWire then return end

    local vehicle = alarm.vehicleUid and Shared.FindVehicleByUID(alarm.vehicleUid) or nil
    if vehicle then
        pcall(function()
            vehicle:setAlarmed(false)
            if type(vehicle.transmitAlarmed) == "function" then vehicle:transmitAlarmed() end
        end)
    end
    Service.ActiveAlarms[id] = nil
end

-- Notifies the trap's owner that one of their devices just went off. Shared
-- by both alarm kinds purely as a messaging detail -- it decides nothing
-- about whether either alarm fires.
local function alertOwner(record, originX, originY, reason, actor, jammed)
    local owner = findOnlinePlayer(record.owner)
    if not owner or (jammed and Config.Get("SignalsJammersBlockAlerts")) then return end

    if Shared.Distance(owner:getX(), owner:getY(), originX, originY) <= Config.Get("WirelessRangeTiles") then
        send(owner, "ALERT", {
            trapId = record.id,
            kind = record.kind,
            reason = reason,
            vehicleUid = record.vehicleUid,
            x = math.floor(record.x), y = math.floor(record.y), z = math.floor(record.z),
            actor = actor and Shared.Username(actor) or "unknown",
        })
    end
end

-- CARS ONLY. The vehicle tamper alarm is a car's own alarm: it sounds that
-- vehicle's real horn/alarm and exists to tell its owner someone else is
-- messing with their car.
local function triggerVehicleTamperAlarm(record, vehicle, actor, reason)
    local run = Logger.Begin("Service.triggerVehicleTamperAlarm", record.id)

    if not vehicle then
        Logger.Finish(run, false, "NO_VEHICLE")
        return false
    end

    if record.state ~= Shared.State.Armed or record.armPending then
        Logger.Finish(run, true, "not armed")
        return false
    end

    -- The owner installed this alarm to warn them about someone ELSE
    -- touching their car -- it must never go off in their own hands.
    if actor and record.owner == Shared.Username(actor) then
        Logger.Finish(run, true, "owner immune")
        return false
    end

    if actor and not canTargetPlayer(record, actor, false) then
        Logger.Finish(run, true, "actor protected")
        return false
    end

    if actor and vehicleKeyHeldBy(actor, vehicle) then
        Logger.Finish(run, true, "actor holds a real key")
        return false
    end

    pcall(function()
        vehicle:setAlarmed(true)
        vehicle:triggerAlarm()
    end)
    Service.ActiveAlarms[tostring(record.id)] = {
        vehicleUid = record.vehicleUid,
        dueAtMs = nowMs() + (Config.Get("TamperAlarmDurationSeconds") * 1000),
    }
    Effects.PlaySound("VehicleAlarm", vehicle:getSquare(), Config.Get("TamperAlarmSoundRadiusTiles"), 100)
    soundDetonation(record, vehicle:getSquare())

    record.lastAlarmAtHours = Shared.WorldAgeHours()
    record.alarmCount = (tonumber(record.alarmCount) or 0) + 1
    Registry.MarkDirty("vehicle tamper alarm")

    local jammed = isSignalsJammedAt(vehicle:getX(), vehicle:getY())
    alertOwner(record, vehicle:getX(), vehicle:getY(), reason, actor, jammed)

    Logger.Audit("VEHICLE_TAMPER_ALARM", actor and Shared.Username(actor) or "environment",
        "id=" .. record.id .. " | reason=" .. tostring(reason) .. " | jammed=" .. tostring(jammed))
    Logger.Finish(run, true, "jammed=" .. tostring(jammed))
    return true
end

-- A trip wire is a plain burglar alarm strung between two stakes: ANYTHING
-- that crosses it sets off a house alarm right there on the wire -- player,
-- zombie, animal or vehicle alike. It deliberately has no target filtering
-- of any kind, because "something just went through my wire" is the entire
-- point of the device.
local function triggerTripWireAlarm(record, x, y, z, reason, actor)
    local run = Logger.Begin("Service.triggerTripWireAlarm", record.id)

    if record.state ~= Shared.State.Armed or record.armPending then
        Logger.Finish(run, true, "not armed")
        return false
    end

    -- Match zombie.iso.Alarm: 49 seconds at normal speed, expressed in world
    -- hours using the configured day length so time acceleration matches.
    local minutesPerDay = getGameTime():getMinutesPerDay()
    Service.ActiveAlarms[tostring(record.id)] = {
        kind = Shared.Kind.TripWire,
        -- The spot on the wire that was actually crossed, not whichever
        -- stake happens to be stake one.
        x = math.floor(x), y = math.floor(y), z = math.floor(z),
        endHours = Shared.WorldAgeHours() + (49 / 3600) * (1440 / minutesPerDay),
    }
    syncTripWireAlarms()

    record.lastAlarmAtHours = Shared.WorldAgeHours()
    record.alarmCount = (tonumber(record.alarmCount) or 0) + 1
    Registry.MarkDirty("trip wire alarm")

    alertOwner(record, x, y, reason, actor, false)

    soundDetonation(record, squareAt({ x = x, y = y, z = z }))
    Logger.Audit("TRIP_WIRE_ALARM", actor and Shared.Username(actor) or "environment",
        "id=" .. record.id .. " | reason=" .. tostring(reason)
            .. " | at=" .. tostring(math.floor(x)) .. "," .. tostring(math.floor(y)))
    Logger.Finish(run, true, "sounded")
    return true
end

local function vehicleHasContainer(vehicle, containerType)
    if not vehicle or type(containerType) ~= "string" or #containerType < 1 or #containerType > 64 then return false end
    if type(vehicle.getPartCount) ~= "function" or type(vehicle.getPartByIndex) ~= "function" then return false end

    for index = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(index)
        local container = part and type(part.getItemContainer) == "function" and part:getItemContainer() or nil
        if container and tostring(container:getType() or "") == containerType then return true end
    end

    return false
end

function Service.VehicleContainerAccessed(player, args)
    local run = Logger.Begin("Service.VehicleContainerAccessed", Shared.Username(player))
    Service.Initialize()
    if not claimCooldown(player, "vehicle_container", 2000) then return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE") end
    local vehicle, reason = vehicleFromArgs(args)
    if not vehicle then return finishFailure(run, reason) end
    local inRange, rangeReason = validateRange(player, vehicle:getX(), vehicle:getY(), Config.Get("InteractionRangeTiles") + 1)
    if not inRange then return finishFailure(run, rangeReason) end
    if not vehicleHasContainer(vehicle, tostring(args and args.containerType or "")) then
        return finishFailure(run, "VEHICLE_CONTAINER_NOT_FOUND")
    end
    local uid = Shared.VehicleUID(vehicle, false)
    if not uid then
        Logger.Finish(run, true, "untracked vehicle")
        return { action = "VEHICLE_CONTAINER_ACCESSED", alarmed = false }
    end
    local alarms = Registry.FindTraps(function(record)
        return record.kind == Shared.Kind.TamperAlarm and record.vehicleUid == uid
            and record.state == Shared.State.Armed and not record.armPending and existingFeatureOperational(record)
    end)
    local alarmed = false

    for _, record in ipairs(alarms) do
        alarmed = triggerVehicleTamperAlarm(record, vehicle, player, tostring(args.containerType or "vehicle storage")) or alarmed
    end

    if alarmed then Registry.Persist("vehicle container alarm") end
    Logger.Finish(run, true, "alarmed=" .. tostring(alarmed))
    return { action = "VEHICLE_CONTAINER_ACCESSED", alarmed = alarmed }
end

-- Popping the hood (opening the Vehicle Mechanics window) is tampering with
-- the whole car too, same as a door/window/seat/trunk -- mirrors
-- Service.VehicleContainerAccessed exactly, just for a different real event.
function Service.VehicleMechanicsOpened(player, args)
    local run = Logger.Begin("Service.VehicleMechanicsOpened", Shared.Username(player))
    Service.Initialize()
    if not claimCooldown(player, "vehicle_mechanics", 2000) then return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE") end
    local vehicle, reason = vehicleFromArgs(args)
    if not vehicle then return finishFailure(run, reason) end
    local inRange, rangeReason = validateRange(player, vehicle:getX(), vehicle:getY(), Config.Get("InteractionRangeTiles") + 1)
    if not inRange then return finishFailure(run, rangeReason) end
    local uid = Shared.VehicleUID(vehicle, false)
    if not uid then
        Logger.Finish(run, true, "untracked vehicle")
        return { action = "VEHICLE_MECHANICS_OPENED", alarmed = false }
    end
    local alarms = Registry.FindTraps(function(record)
        return record.kind == Shared.Kind.TamperAlarm and record.vehicleUid == uid
            and record.state == Shared.State.Armed and not record.armPending and existingFeatureOperational(record)
    end)
    local alarmed = false

    for _, record in ipairs(alarms) do
        alarmed = triggerVehicleTamperAlarm(record, vehicle, player, "mechanics menu opened") or alarmed
    end

    if alarmed then Registry.Persist("vehicle mechanics alarm") end
    Logger.Finish(run, true, "alarmed=" .. tostring(alarmed))
    return { action = "VEHICLE_MECHANICS_OPENED", alarmed = alarmed }
end

local function detectionChance(player, record)
    local run = Logger.Begin("Service.detectionChance", record.kind)
    local electrical = Shared.PerkLevel(player, Perks.Electricity)
    local mechanics = Shared.PerkLevel(player, Perks.Mechanics)
    local maintenance = Shared.PerkLevel(player, Perks.Maintenance)
    local base = Shared.VisibleKinds[record.kind] and 1 or 0.20
    local chance = base + (electrical * 0.055) + (mechanics * 0.035) + (maintenance * 0.025)
    chance = math.max(0.02, math.min(0.98, chance * Config.Get("DetectionChanceMultiplier")))
    Logger.Finish(run, true, "chance=" .. tostring(chance))
    return chance
end

local function grantKnowledge(player, record, durationSeconds)
    local name = Shared.Username(player)
    Registry.GrantKnowledge(name, record.id, durationSeconds)

    if not Config.Get("ShareKnowledgeWithFaction") then return end
    local faction = factionFor(player)
    if not faction then return end

    if type(faction.getOwner) == "function" then
        local owner = tostring(faction:getOwner() or "")
        if owner ~= "" then Registry.GrantKnowledge(owner, record.id, durationSeconds) end
    end

    local players = type(faction.getPlayers) == "function" and faction:getPlayers() or nil
    if players then
        for index = 0, players:size() - 1 do
            Registry.GrantKnowledge(tostring(players:get(index)), record.id, durationSeconds)
        end
    end
end

local function grantXP(player, perk, amount)
    local multiplier = math.max(0, Config.Get("XPMultiplier"))
    if multiplier <= 0 or not player or not perk or type(player.getXp) ~= "function" then return false end
    local ok = pcall(function() player:getXp():AddXP(perk, math.max(0, amount) * multiplier) end)
    return ok
end

local function candidateTraps(player, args)
    local run = Logger.Begin("Service.candidateTraps")
    local results = {}
    local vehicle = nil
    local vehicleUid = nil

    if args and tonumber(args.vehicleId) then
        vehicle = vehicleFromArgs(args)
        vehicleUid = vehicle and Shared.VehicleUID(vehicle, false) or nil
    end

    local x = vehicle and vehicle:getX() or tonumber(args and args.x) or player:getX()
    local y = vehicle and vehicle:getY() or tonumber(args and args.y) or player:getY()
    local z = vehicle and vehicle:getZ() or tonumber(args and args.z) or player:getZ()

    local function inspectable(record)
        return record.state ~= Shared.State.Destroyed and record.state ~= Shared.State.Spent
    end

    if vehicleUid then
        -- Vehicle-device coordinates track the vehicle and are only reindexed as
        -- each record is processed, so a spatial lookup can miss them. Match by UID.
        for _, record in ipairs(Registry.FindTraps()) do
            if record.vehicleUid == vehicleUid and inspectable(record) then
                results[#results + 1] = record
            end
        end
    else
        for _, record in ipairs(Registry.FindNearby(x, y, z, Config.Get("InteractionRangeTiles") + 0.5, function(record)
            return not record.vehicleUid and inspectable(record)
        end)) do
            results[#results + 1] = record
        end
    end

    Logger.Finish(run, true, "count=" .. tostring(#results))
    return results, x, y, z, vehicle
end

function Service.Inspect(player, args)
    local run = Logger.Begin("Service.Inspect", Shared.Username(player))
    Service.Initialize()
    if not claimCooldown(player, "inspect", 1000) then return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE") end
    local candidates, x, y = candidateTraps(player, args)
    local inRange, rangeReason = validateRange(player, x, y, Config.Get("InteractionRangeTiles") + 1)
    if not inRange then return finishFailure(run, rangeReason) end

    local discovered = {}
    local name = Shared.Username(player)

    for _, record in ipairs(candidates) do
        local automaticallyKnown = Shared.VisibleKinds[record.kind]
            or (Config.Get("OwnerAlwaysKnowsTrap") and record.owner == name)
            or Shared.IsAdmin(player)
        local hasInspectionSkill = not Shared.AdvancedKinds[record.kind]
            or Shared.PerkLevel(player, Perks.Electricity) >= Config.Get("InspectionElectricalLevel")
        local found = automaticallyKnown or (hasInspectionSkill and randomChance(detectionChance(player, record)))

        if found then
            grantKnowledge(player, record, 300)
            discovered[#discovered + 1] = {
                trapId = record.id,
                kind = record.kind,
                state = record.state,
                condition = math.floor(tonumber(record.condition) or 0),
                maxCondition = math.floor(tonumber(record.maxCondition) or 100),
                owner = Shared.IsAdmin(player) and record.owner or nil,
                vehicleUid = record.vehicleUid,
            }
        end
    end

    if args and args.documentItemId then
        local document = findItem(player, args.documentItemId)
        local record = document and Registry.GetDocument(document:getID()) or nil

        if record and record.state == Shared.State.Armed then
            local pseudo = { id = record.id, kind = Shared.Kind.AnthraxDocument, owner = record.owner }
            local qualified = Shared.PerkLevel(player, Perks.Electricity) >= Config.Get("InspectionElectricalLevel")
            local found = Shared.IsAdmin(player) or record.owner == name
                or (qualified and randomChance(detectionChance(player, pseudo)))

            if found then
                grantKnowledge(player, record, 300)
                discovered[#discovered + 1] = {
                    trapId = record.id,
                    kind = Shared.Kind.AnthraxDocument,
                    state = record.state,
                    documentItemId = document:getID(),
                }
            end
        end
    end

    Logger.Audit("INSPECT", name, "candidates=" .. tostring(#candidates) .. " | discovered=" .. tostring(#discovered))
    Effects.PlayInspectionSound(#discovered > 0 and "found" or "notFound", player:getSquare())
    if #discovered > 0 then grantXP(player, Perks.Electricity, 2) end
    Logger.Finish(run, true, "discovered=" .. tostring(#discovered))
    return { action = "INSPECT", discovered = discovered, nothingFound = #discovered == 0 }
end

local KindToItem = {
    [Shared.Kind.WaterBucket] = Shared.Item.WaterBucketTrap,
    [Shared.Kind.NailBoard] = Shared.Item.NailBoard,
    [Shared.Kind.BearTrap] = Shared.Item.BearTrap,
    [Shared.Kind.ExplosiveMailbox] = Shared.Item.ExplosiveParcel,
    [Shared.Kind.IgnitionCharge] = Shared.Item.IgnitionCharge,
    [Shared.Kind.DriverSeatDye] = Shared.Item.DriverSeatDyeTrap,
    [Shared.Kind.TamperAlarm] = Shared.Item.VehicleTamperAlarm,
    [Shared.Kind.RemoteImmobilizer] = Shared.Item.RemoteImmobilizer,
    [Shared.Kind.ShotgunDoor] = Shared.Item.ShotgunDoorTrap,
    [Shared.Kind.TripWire] = Shared.Item.TripWireKit,
}

local function findDocumentByRecordId(recordId)
    local run = Logger.Begin("Service.findDocumentByRecordId", recordId)
    local found = nil

    for _, record in pairs(Registry.Data.documents) do
        if tostring(record.id) == tostring(recordId) then
            found = record
            break
        end
    end

    Logger.Finish(run, true, "found=" .. tostring(found ~= nil))
    return found
end

local function disarmChance(player, record)
    local run = Logger.Begin("Service.disarmChance", record.kind)
    local electrical = Shared.PerkLevel(player, Perks.Electricity)
    local mechanics = Shared.PerkLevel(player, Perks.Mechanics)
    local maintenance = Shared.PerkLevel(player, Perks.Maintenance)
    local trapping = Shared.PerkLevel(player, Perks.Trapping)
    local welding = Shared.PerkLevel(player, Perks.MetalWelding)
    local base = Shared.VisibleKinds[record.kind] and 0.55 or 0.20

    if record.kind == Shared.Kind.BearTrap then
        base = base + (trapping * 0.04) + (welding * 0.035) + (maintenance * 0.025)
    else
        base = base + (electrical * 0.045) + (mechanics * 0.035) + (maintenance * 0.03)
    end

    local conditionFactor = 0.75 + ((tonumber(record.condition) or 100) / 400)
    local chance = math.max(0.05, math.min(0.98,
        base * conditionFactor * Config.Get("DisarmSuccessMultiplier")))
    Logger.Finish(run, true, "chance=" .. tostring(chance))
    return chance
end

local function removeTrapPhysical(record)
    Service.StopTripWireAlarm(record.id)
    Service.StopVehicleAlarm(record.id)
    local run = Logger.Begin("Service.removeTrapPhysical", record.id)
    local removed = true

    if record.worldItemId then
        removed = removeWorldTrapItem(record)
    end

    Logger.Finish(run, true, "physicalRemoved=" .. tostring(removed))
    return removed
end

-- The water is spent and the hammer was only a crafting tool. Always return
-- the bucket; lose exactly one of the two remaining consumed ingredients.
local function spillWaterBucket(record)
    record.condition = 0
    record.state = Shared.State.Destroyed
    record.destroyedAtHours = Shared.WorldAgeHours()
    removeWorldTrapItem(record)
    local square = squareAt(record)
    if square then
        square:AddWorldInventoryItem("Base.Bucket", 0.5, 0.5, 0)
        local remaining = randomChance(0.5) and "Base.Rope" or "Base.Nails"
        square:AddWorldInventoryItem(remaining, 0.5, 0.5, 0)
    end
end

local function salvage(player, record)
    local run = Logger.Begin("Service.salvage", record.id)
    local count = 0

    if randomChance(Config.Get("SalvageChance")) then
        addInventoryItem(player, "Base.ElectronicsScrap")
        count = count + 1
    end

    if randomChance(Config.Get("SalvageChance") * 0.75) then
        addInventoryItem(player, "Base.ElectricWire")
        count = count + 1
    end

    if Shared.AdvancedKinds[record.kind] and randomChance(Config.Get("RarePartSalvageChance")) then
        addInventoryItem(player, "Base.ElectronicsScrap")
        count = count + 1
    end

    Logger.Finish(run, true, "items=" .. tostring(count))
    return count
end

local function useNailBoard(record)
    local run = Logger.Begin("Service.useNailBoard", record.id)
    record.triggerCount = (tonumber(record.triggerCount) or 0) + 1
    record.lastTriggeredAtHours = Shared.WorldAgeHours()
    -- Four activations per board, independent of general condition settings.
    record.condition = math.max(0, 100 - record.triggerCount * 25)
    Registry.MarkDirty("nail board activation")

    if record.triggerCount >= 4 then
        record.state = Shared.State.Destroyed
        record.destroyedAtHours = Shared.WorldAgeHours()
        removeWorldTrapItem(record)
        Registry.RemoveTrap(record.id, "nail board exhausted")
        local square = squareAt(record)
        if square then
            -- Pick one missing physical item from one plank and eight nails.
            -- Crafting tools are retained by the recipe and never returned here.
            local missing = type(ZombRand) == "function" and ZombRand(9) or math.random(0, 8)
            if missing ~= 0 then square:AddWorldInventoryItem("Base.Plank", 0.5, 0.5, 0) end
            for i = 1, (missing == 0 and 8 or 7) do
                square:AddWorldInventoryItem("Base.Nails", 0.5, 0.5, 0)
            end
        end
    else
        updateWorldItemMetadata(record)
    end

    Logger.Finish(run, true, "activations=" .. tostring(record.triggerCount))
end

-- The kinds whose failed-disarm branch below fires the trap RIGHT HERE, and so
-- must sound its detonation here too. Every other kind either delegates to a
-- path that already sounds its own (Service.ScheduleExplosion,
-- triggerTripWireAlarm, triggerVehicleTamperAlarm) or does not detonate at all
-- (the immobilizer just latches on) -- sounding those here would double up.
local DisarmFailureFiresDirectly = {
    [Shared.Kind.NailBoard] = true,
    [Shared.Kind.BearTrap] = true,
    [Shared.Kind.WaterBucket] = true,
    [Shared.Kind.ShotgunDoor] = true,
    [Shared.Kind.DriverSeatDye] = true,
}

local function triggerDisarmFailure(player, record)
    local run = Logger.Begin("Service.triggerDisarmFailure", record.id)

    if DisarmFailureFiresDirectly[record.kind] then
        -- A vehicle device sounds from its car; a floor trap from its own tile.
        local vehicle = record.vehicleUid and Shared.FindVehicleByUID(record.vehicleUid) or nil
        soundDetonation(record, vehicle and vehicle:getSquare() or nil)
    end

    -- A single-use kind that goes off HERE is exactly as consumed as it
    -- would be going off normally -- it must not survive in the registry
    -- as a lingering spent record just because this was a failed disarm
    -- instead of a real trigger.
    if record.kind == Shared.Kind.NailBoard then
        Combat.Apply(record, player, Effects.TriggerNailBoard)
        useNailBoard(record)
    elseif record.kind == Shared.Kind.BearTrap then
        Combat.Apply(record, player, Effects.TriggerBearTrap)
        record.state = Shared.State.Sprung
    elseif record.kind == Shared.Kind.WaterBucket then
        Combat.Apply(record, player, Effects.WetPlayer)
        spillWaterBucket(record)
        Registry.RemoveTrap(record.id, "floor trap triggered during failed disarm")
    elseif record.kind == Shared.Kind.ShotgunDoor then
        Combat.Apply(record, player, Effects.TriggerShotgun)
        Registry.RemoveTrap(record.id, "floor trap triggered during failed disarm")
    elseif record.kind == Shared.Kind.TripWire then
        local changed = triggerTripWireAlarm(record, record.x, record.y, record.z, "failed disarm", player)

        -- A failed disarm attempt still crosses the wire -- it must count
        -- toward the same trigger budget as a normal proximity crossing
        -- (mirrors processTripWire's exhaustion check), otherwise a wire
        -- disarmed-and-failed enough times never breaks/removes.
        if changed and (tonumber(record.alarmCount) or 0) >= Config.Get("TripWireMaxTriggers") then
            record.state = Shared.State.Spent
            record.spentAtHours = Shared.WorldAgeHours()
            Logger.Audit("TRIP_WIRE_BROKEN", record.owner, "id=" .. record.id .. " | triggers=" .. tostring(record.alarmCount))
            Registry.RemoveTrap(record.id, "trip wire exhausted during failed disarm")
        end
    elseif record.kind == Shared.Kind.ExplosiveMailbox then
        Service.ScheduleExplosion(record, player, Config.Get("ExplosiveFuseSeconds"), "failed disarm")
    elseif record.kind == Shared.Kind.IgnitionCharge then
        Service.ScheduleExplosion(record, player, Config.Get("IgnitionFuseSeconds"), "failed vehicle disarm")
    elseif record.kind == Shared.Kind.TamperAlarm then
        triggerVehicleTamperAlarm(record, Shared.FindVehicleByUID(record.vehicleUid), player, "failed disarm")
    elseif record.kind == Shared.Kind.DriverSeatDye then
        Combat.Apply(record, player, Effects.ApplyDye)
        Registry.RemoveTrap(record.id, "driver dye triggered during failed disarm")
    elseif record.kind == Shared.Kind.RemoteImmobilizer then
        record.immobilized = true
    end

    record.updatedAtHours = Shared.WorldAgeHours()
    Registry.MarkDirty("disarm failure")
    Logger.Finish(run, true, "kind=" .. record.kind)
    return true
end

-- A bear trap holding a live/dead zombie, animal, corpse, or player blocks
-- disarm/reset/repair until a player explicitly frees it (Service.FreeBearTrap).
local function occupantBlockReason(record)
    if not record or record.kind ~= Shared.Kind.BearTrap or not record.occupant then
        return nil
    end

    local labels = {
        zombie = "A zombie is still caught in the trap.",
        animal = "An animal is still caught in the trap.",
        corpse = "A body is caught in the trap.",
        player = "Someone is currently caught in this trap.",
    }
    return (labels[record.occupant.kind] or "The trap is occupied.") .. " Free it first."
end

function Service.Disarm(player, args)
    local run = Logger.Begin("Service.Disarm", Shared.Username(player))
    Service.Initialize()
    if not claimCooldown(player, "disarm", 1000) then return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE") end
    local trapId = tostring(args and args.trapId or "")
    local record = Registry.GetTrap(trapId)
    local documentRecord = nil

    if not record then
        documentRecord = findDocumentByRecordId(trapId)
        record = documentRecord and {
            id = documentRecord.id,
            kind = Shared.Kind.AnthraxDocument,
            owner = documentRecord.owner,
            state = documentRecord.state,
            condition = 100,
        } or nil
    end

    if not record then return finishFailure(run, "TRAP_NOT_FOUND") end
    local occupantReason = occupantBlockReason(record)
    if occupantReason then return finishFailure(run, occupantReason) end
    local name = Shared.Username(player)
    local known = Shared.VisibleKinds[record.kind]
        or Registry.HasKnowledge(name, record.id)
        or (Config.Get("OwnerAlwaysKnowsTrap") and record.owner == name)
        or Shared.IsAdmin(player)
    if not known then return finishFailure(run, "You have not discovered this trap yet. Inspect it first.") end

    if not Shared.IsAdmin(player) then
        local disarmGap = Shared.RequirementGap(player, record.kind, "disarm")
        if disarmGap then return finishFailure(run, disarmGap) end

        if not Shared.KnowsRecipe(player, record.kind) then
            local magazine = Shared.KindMagazine[record.kind]
            return finishFailure(run, "You don't know how this device is built, so you can't safely disarm it"
                .. (magazine and (" -- read " .. magazine .. " first.") or "."))
        end
    end

    if not documentRecord then
        local x = record.x
        local y = record.y
        local vehicle = record.vehicleUid and Shared.FindVehicleByUID(record.vehicleUid) or nil
        if vehicle then
            x, y = vehicle:getX(), vehicle:getY()
        elseif record.kind == Shared.Kind.TripWire and record.x2 and record.y2 then
            -- Either endpoint is valid, even when the wire is much longer
            -- than the interaction radius.
            if Shared.Distance(player:getX(), player:getY(), record.x2, record.y2)
                < Shared.Distance(player:getX(), player:getY(), x, y) then
                x, y = record.x2, record.y2
            end
        end
        local inRange, rangeReason = validateRange(player, x, y, Config.Get("InteractionRangeTiles") + 1)
        if not inRange then return finishFailure(run, rangeReason) end
    else
        local document = findItem(player, args and args.documentItemId)
        if not document or tonumber(document:getID()) ~= tonumber(documentRecord.itemId) then
            return finishFailure(run, "DOCUMENT_MUST_BE_HELD")
        end
    end

    local operation = tostring(args and args.operation or "disarm")
    if operation == "reverse" and not Config.Get("ReverseDisarmEnabled") then
        return finishFailure(run, "REVERSING_DISABLED")
    end
    -- Disarm/reverse only make sense against a live, armed device -- a
    -- sprung/spent trap has nothing left to disarm or take over. Server-side
    -- guard against a modified client sending the command directly (the
    -- context menu already hides these for a non-armed trap); salvage stays
    -- allowed in any state, same as the menu.
    if operation ~= "salvage" and not Shared.IsAdmin(player) and record.state ~= Shared.State.Armed then
        return finishFailure(run, "TRAP_NOT_ARMED")
    end
    local success = Shared.IsAdmin(player) or randomChance(disarmChance(player, record))

    if not success then
        local pending = (documentRecord or record).armPending == true
        if not pending and Config.Get("DisarmFailureTriggersTrap") and not documentRecord then
            triggerDisarmFailure(player, record)
        elseif not pending and documentRecord then
            local factor = Combat.Apply(record, player, Effects.BeginBiologicalExposure)
            local currentHours = Shared.WorldAgeHours()
            Registry.AddExposure(name, {
                sourceDocumentId = documentRecord.id, owner = record.owner, kind = record.kind,
                startedAtHours = currentHours,
                endsAtHours = currentHours + Config.Get("AnthraxDurationHours"),
                factor = factor,
                lastTickAtMs = nowMs(),
            })
            soundDetonation(record, player:getSquare())
            -- Fully spent, same as a successful read exposure: remove
            -- outright instead of leaving a lingering spent document record.
            Registry.RemoveDocument(documentRecord.itemId, "document exposed during failed disarm")
        end

        Registry.Persist("failed disarm")
        Logger.Audit("DISARM_FAILURE", name, "id=" .. record.id .. " | kind=" .. record.kind)
        Logger.Finish(run, true, "failed safelyHandled=true")
        return { action = "DISARM", success = false, triggered = not pending and (documentRecord ~= nil or Config.Get("DisarmFailureTriggersTrap")) }
    end

    if record.kind == Shared.Kind.BearTrap and record.heldUsername then
        releaseHeldPlayer(record.heldUsername,
            "The trap is disarmed. You carefully pull your leg free.")
        record.heldUsername = nil
    end

    Service.StopTripWireAlarm(record.id)
    Service.StopVehicleAlarm(record.id)

    if operation == "reverse" then
        local reversedRecord = documentRecord or record
        reversedRecord.owner = name
        reversedRecord.state = Shared.State.Armed
        reversedRecord.reversedAtHours = Shared.WorldAgeHours()
        -- Transfer credit without restoring durability or uses, and give the
        -- reverser the same retreat requirement as a fresh placement.
        Arming.Begin(reversedRecord, player)
        if documentRecord then Arming.TrackDocument(reversedRecord, findItem(player, args.documentItemId)) end
        if not documentRecord and Shared.FloorKinds[record.kind] then updateWorldItemMetadata(record) end
        Registry.MarkDirty("trap reversed")
        if not documentRecord
            and (record.kind == Shared.Kind.TamperAlarm or record.kind == Shared.Kind.RemoteImmobilizer) then
            local controller = addInventoryItem(player, Shared.Item.Controller, {
                SVSBT_DeviceId = record.id,
                SVSBT_DeviceKind = record.kind,
                SVSBT_VehicleUID = record.vehicleUid,
                SVSBT_Owner = name,
            })
            record.reversedControllerItemId = controller and controller:getID() or nil
        end
    elseif documentRecord then
        local document = findItem(player, args.documentItemId)
        if document then
            document:getModData().SVSBT_Contaminated = nil
            document:getModData().SVSBT_Decontaminated = true
            -- InventoryItem has no transmitModData() --
            -- without this, the disarmer's own client keeps showing the
            -- contaminated warning icon on a document that is genuinely
            -- clean now.
            netAddSync(document:getContainer(), document)
        end
        -- Successfully cleaned: the same "fully spent, remove outright"
        -- treatment as a successful disarm on any other kind (below) --
        -- otherwise DOCUMENT_ALREADY_CONTAMINATED would permanently block
        -- this exact physical document from ever being re-contaminated,
        -- even though it's now genuinely clean.
        Registry.RemoveDocument(documentRecord.itemId, "document decontaminated")
    else
        removeTrapPhysical(record)
        Registry.RemoveTrap(record.id, "successful disarm")

        if operation == "salvage" then
            salvage(player, record)
        else
            local itemType = KindToItem[record.kind]
            if itemType then
                local data
                if record.kind == Shared.Kind.NailBoard then
                    data = { SVSBT_TriggerCount = record.triggerCount, SVSBT_Condition = record.condition }
                elseif record.kind == Shared.Kind.BearTrap then
                    data = { SVSBT_Condition = record.condition, SVSBT_MaxCondition = record.maxCondition }
                end
                addInventoryItem(player, itemType, data)
            end
        end
    end

    Registry.Persist("successful disarm")
    grantXP(player, Shared.VehicleKinds[record.kind] and Perks.Mechanics or Perks.Maintenance, 5)
    Logger.Audit("DISARM_SUCCESS", name,
        "id=" .. record.id .. " | kind=" .. record.kind .. " | operation=" .. operation)
    Logger.Finish(run, true, "operation=" .. operation)
    return {
        action = "DISARM", success = true, operation = operation, kind = record.kind,
        controllerItemId = record.reversedControllerItemId,
    }
end

-- A player held by a bear trap yanking against it (attempting to sprint) is
-- the escape attempt: freed clean if the trap was already disarmed/removed by
-- then, otherwise the jaws tear the wound open on the way out.
function Service.BearTrapEscapeAttempt(player, args)
    local run = Logger.Begin("Service.BearTrapEscapeAttempt", Shared.Username(player))
    Service.Initialize()
    local username = Shared.Username(player)
    local trapId = Service.HeldPlayers[username]

    if not trapId then
        -- The hold was already released server-side (trap removed, disarmed
        -- or cleaned up) but the player's own tag survived: clear it, or the
        -- client keeps snapping them back to the tile with no way out.
        if type(player.getModData) == "function" and player:getModData().SVSBT_BearTrapHeldId then
            player:getModData().SVSBT_BearTrapHeldId = nil
            if type(player.transmitModData) == "function" then player:transmitModData() end
            send(player, "WARNING", { source = "bear_trap", message = "You pull free of the trap." })
        end
        Logger.Finish(run, true, "not held")
        return { action = "BEAR_TRAP_ESCAPE_ATTEMPT", held = false }
    end

    Service.HeldPlayers[username] = nil
    if type(player.getModData) == "function" then
        player:getModData().SVSBT_BearTrapHeldId = nil
    end
    if type(player.transmitModData) == "function" then player:transmitModData() end

    local record = Registry.GetTrap(trapId)
    local stillSprung = record ~= nil and record.state == Shared.State.Sprung

    if record and record.heldUsername == username then
        record.heldUsername = nil
    end

    if not stillSprung then
        if record and record.occupant and record.occupant.username == username then
            record.occupant = nil
        end
        send(player, "WARNING", { source = "bear_trap", message = "You pull free of the trap." })
        Logger.Finish(run, true, "escaped clean")
        return { action = "BEAR_TRAP_ESCAPE_ATTEMPT", held = false, injured = false }
    end

    local damage = Combat.Apply(record, player, Effects.BearTrapEscapeInjury)
    Logger.Audit("BEAR_TRAP_ESCAPE_INJURY", username, "id=" .. trapId .. " | damage=" .. tostring(damage))

    if Combat.IsDead(player) then
        record.occupant = { kind = "corpse", username = username }
    else
        record.occupant = nil
        send(player, "WARNING", {
            source = "bear_trap",
            message = "You tear free without disarming the trap -- the jaws rip a deep wound into your leg!",
        })
    end

    Logger.Finish(run, true, "escaped injured | damage=" .. tostring(damage))
    return { action = "BEAR_TRAP_ESCAPE_ATTEMPT", held = false, injured = true, damage = damage }
end

local function hasAnyItem(player, fullTypes)
    local run = Logger.Begin("Service.hasAnyItem")
    local item = nil

    for _, fullType in ipairs(fullTypes) do
        item = Shared.FindItemByFullType(player:getInventory(), fullType)
        if item then break end
    end

    Logger.Finish(run, true, "found=" .. tostring(item ~= nil))
    return item
end

local function consumeOneUse(item)
    local run = Logger.Begin("Service.consumeOneUse")

    if not item then return finishFailure(run, "ITEM_REQUIRED") end
    local ok = false

    if type(item.Use) == "function" then
        item:Use()
        ok = true
    elseif type(item.getUsedDelta) == "function" and type(item.setUsedDelta) == "function" then
        local useDelta = type(item.getUseDelta) == "function" and item:getUseDelta() or 0.1
        item:setUsedDelta(math.max(0, item:getUsedDelta() - useDelta))
        ok = true
    end

    Logger.Finish(run, ok, "consumed=" .. tostring(ok))
    return ok
end

-- Releases whatever is caught in a bear trap (live zombie/animal, a corpse, or
-- a held player) so the trap can be disarmed/reset/repaired again. A live
-- zombie or animal simply gets to walk away with whatever damage it already
-- took; it is not killed by freeing it.
function Service.FreeBearTrap(player, args)
    local run = Logger.Begin("Service.FreeBearTrap", Shared.Username(player))
    Service.Initialize()
    local record = Registry.GetTrap(args and args.trapId)
    if not record or record.kind ~= Shared.Kind.BearTrap then return finishFailure(run, "BEAR_TRAP_NOT_FOUND") end
    if not record.occupant then return finishFailure(run, "BEAR_TRAP_NOT_OCCUPIED") end
    local inRange, rangeReason = validateRange(player, record.x, record.y, Config.Get("InteractionRangeTiles") + 0.5)
    if not inRange then return finishFailure(run, rangeReason) end

    local occupantKind = record.occupant.kind
    local heldUsername = record.occupant.username
    local freeingSelf = heldUsername ~= nil and heldUsername == Shared.Username(player)

    if freeingSelf then
        if not Shared.HeldWeapon(player) then return finishFailure(run, "WEAPON_REQUIRED_TO_OPEN_TRAP") end
    end

    Creatures.Release(record)
    if heldUsername then
        releaseHeldPlayer(heldUsername, freeingSelf and "You pry the jaws open and step free."
            or "Someone frees you from the trap.")
    end

    record.occupant = nil
    record.heldUsername = nil
    record.updatedAtHours = Shared.WorldAgeHours()
    Registry.MarkDirty("bear trap freed")
    Registry.Persist("bear trap freed")
    Logger.Audit("FREE_BEAR_TRAP", Shared.Username(player), "id=" .. record.id .. " | occupant=" .. tostring(occupantKind))
    Logger.Finish(run, true, "occupant=" .. tostring(occupantKind))
    return { action = "FREE_BEAR_TRAP", success = true, occupant = occupantKind }
end

function Service.ResetBearTrap(player, args)
    local run = Logger.Begin("Service.ResetBearTrap", Shared.Username(player))
    Service.Initialize()
    local record = Registry.GetTrap(args and args.trapId)
    if not record or record.kind ~= Shared.Kind.BearTrap then return finishFailure(run, "BEAR_TRAP_NOT_FOUND") end
    if record.state ~= Shared.State.Sprung then return finishFailure(run, "BEAR_TRAP_NOT_SPRUNG") end
    local occupantReason = occupantBlockReason(record)
    if occupantReason then return finishFailure(run, occupantReason) end
    local inRange, rangeReason = validateRange(player, record.x, record.y)
    if not inRange then return finishFailure(run, rangeReason) end
    if not Shared.WorldItemAt(record.x, record.y, record.z, record.worldItemId) then
        return finishFailure(run, "BEAR_TRAP_WORLD_ITEM_MISSING")
    end
    local tool, toolRiskMultiplier = Shared.BearTrapResetTool(player)
    if not tool then return finishFailure(run, "Hold a usable tool or weapon to reset the bear trap.") end
    local injuryRisk = math.min(0.95, bearSettingRisk(player, record.condition) * toolRiskMultiplier)
    local failed = randomChance(injuryRisk)

    if failed then
        record.condition = math.max(0, record.condition - (Config.Get("BearTrapFailedSetConditionLoss") * Config.Get("ConditionLossMultiplier")))
        Combat.Apply(record, player, Effects.InjureSettingArm, 8 + ((100 - record.condition) / 10))
        record.state = record.condition <= 0 and Shared.State.Destroyed or Shared.State.Sprung
    else
        record.state = Shared.State.Armed
        -- Resetting is re-arming: whoever just did it (not necessarily
        -- record.owner) needs to clear out before it can catch anything again.
        Arming.Begin(record, player)
    end

    local wasDestroyed = record.state == Shared.State.Destroyed

    if wasDestroyed then
        -- Broken beyond repair during the reset attempt itself: the exact
        -- same real completion as breaking from repeated triggers
        -- (destroyFloorTrap, further down this file) -- remove the
        -- physical wreck and the registry record outright, not a lingering
        -- "destroyed" record nobody can do anything with again.
        record.destroyedAtHours = Shared.WorldAgeHours()
        removeWorldTrapItem(record)
    else
        updateWorldItemMetadata(record)
    end

    record.updatedAtHours = Shared.WorldAgeHours()

    if wasDestroyed then
        Registry.RemoveTrap(record.id, "bear trap destroyed during reset")
    else
        Registry.MarkDirty("bear trap reset")
    end

    Registry.Persist("bear trap reset")

    if not failed then
        -- Resetting a sprung bear trap is setting it again: same sound, and
        -- the same noise for anything close enough to hear it.
        Effects.PlayTrapSetSound(squareAt(record))
        grantXP(player, Perks.Trapping, 3)
    end
    Logger.Audit("RESET_BEAR_TRAP", Shared.Username(player),
        "id=" .. record.id .. " | failed=" .. tostring(failed) .. " | tool=" .. tool:getFullType() .. " | injuryRisk=" .. tostring(injuryRisk))
    Logger.Finish(run, true, "failed=" .. tostring(failed))
    return {
        action = "RESET_BEAR_TRAP", success = not failed, state = record.state,
        condition = record.condition, injuryRisk = injuryRisk,
    }
end

function Service.RepairBearTrap(player, args)
    local run = Logger.Begin("Service.RepairBearTrap", Shared.Username(player))
    Service.Initialize()
    local record = Registry.GetTrap(args and args.trapId)
    if not record or record.kind ~= Shared.Kind.BearTrap then return finishFailure(run, "BEAR_TRAP_NOT_FOUND") end
    local occupantReason = occupantBlockReason(record)
    if occupantReason then return finishFailure(run, occupantReason) end
    local inRange, rangeReason = validateRange(player, record.x, record.y)
    if not inRange then return finishFailure(run, rangeReason) end
    if record.condition >= record.maxCondition then return finishFailure(run, "BEAR_TRAP_ALREADY_AT_MAXIMUM") end
    local rods = Shared.FindItemByFullType(player:getInventory(), "Base.WeldingRods")
    if not rods then return finishFailure(run, "WELDING_RODS_REQUIRED") end
    local mask = hasAnyItem(player, { "Base.WeldingMask", "Base.Glasses_OldWeldingGoggles" })
    if not mask then return finishFailure(run, "WELDING_MASK_OR_GOGGLES_REQUIRED") end
    local torch = Shared.FindItemByFullType(player:getInventory(), "Base.BlowTorch")
    local torchEmpty = torch and (
        (type(torch.isEmptyUses) == "function" and torch:isEmptyUses())
        or (type(torch.getCurrentUsesFloat) == "function" and torch:getCurrentUsesFloat() <= 0))
    if not torch or torchEmpty then
        return finishFailure(run, "WELDING_TORCH_WITH_FUEL_REQUIRED")
    end
    consumeOneUse(rods)
    consumeOneUse(torch)
    record.maxCondition = math.max(20, record.maxCondition - Config.Get("BearTrapMaxConditionLossPerRepair"))
    record.condition = math.min(record.maxCondition,
        record.condition + Config.Get("BearTrapRepairAmountPerRod"))
    record.updatedAtHours = Shared.WorldAgeHours()
    Registry.MarkDirty("bear trap repair")
    Registry.Persist("bear trap repair")
    grantXP(player, Perks.MetalWelding, 4)
    Logger.Audit("REPAIR_BEAR_TRAP", Shared.Username(player),
        "id=" .. record.id .. " | condition=" .. tostring(record.condition)
            .. " | maxCondition=" .. tostring(record.maxCondition))
    Logger.Finish(run, true, "condition=" .. tostring(record.condition))
    return {
        action = "REPAIR_BEAR_TRAP", success = true,
        condition = record.condition, maxCondition = record.maxCondition,
    }
end

function Service.RFScan(player, args)
    local run = Logger.Begin("Service.RFScan", Shared.Username(player))
    Service.Initialize()
    if not Config.Get("SignalsIntegrationEnabled") or not Config.Get("SignalsDetectorFindsWirelessTraps") then
        return finishFailure(run, "SIGNALS_INTEGRATION_DISABLED")
    end
    if not claimCooldown(player, "rf_scan", 5000) then return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE") end
    local detector, reason = findItem(player, args and args.detectorItemId)
    if not detector then return finishFailure(run, reason) end
    if detector:getFullType() ~= "GPSMod.RF_SignalDetector" then return finishFailure(run, "RF_DETECTOR_REQUIRED") end
    local range = Config.Get("WirelessDetectionRangeTiles")
    local results = {}
    local electrical = Shared.PerkLevel(player, Perks.Electricity)

    for _, record in ipairs(Registry.FindNearby(player:getX(), player:getY(), player:getZ(), range, function(candidate)
        return (candidate.kind == Shared.Kind.TamperAlarm or candidate.kind == Shared.Kind.RemoteImmobilizer)
            and candidate.state == Shared.State.Armed
    end)) do
        local vehicle = Shared.FindVehicleByUID(record.vehicleUid)
        local x = vehicle and vehicle:getX() or record.x
        local y = vehicle and vehicle:getY() or record.y
        local distance = Shared.Distance(player:getX(), player:getY(), x, y)

        if distance <= range and not isSignalsJammedAt(player:getX(), player:getY()) then
            local strength = "WEAK"
            if distance <= range * 0.15 then strength = "VERY STRONG"
            elseif distance <= range * 0.35 then strength = "STRONG"
            elseif distance <= range * 0.65 then strength = "MODERATE" end
            results[#results + 1] = {
                strength = strength,
                source = electrical >= 5 and record.kind or "wireless trap signal",
                approximateDistance = math.max(1, math.floor(distance / 5) * 5),
            }
        end
    end

    Logger.Audit("RF_TRAP_SCAN", Shared.Username(player), "results=" .. tostring(#results))
    Logger.Finish(run, true, "results=" .. tostring(#results))
    return { action = "RF_SCAN", results = results, nothingFound = #results == 0 }
end

function Service.AdminRemoveRadius(player, args)
    local run = Logger.Begin("Service.AdminRemoveRadius", Shared.Username(player))
    Service.Initialize()
    if not Shared.IsAdmin(player) then return finishFailure(run, "ADMIN_REQUIRED") end
    local radius = math.min(Config.Get("AdminRemovalRadiusTiles"), math.max(1, tonumber(args and args.radius) or Config.Get("AdminRemovalRadiusTiles")))
    local removed = 0
    local matches = Registry.FindTraps(function(record)
        return math.floor(tonumber(record.z) or -99) == math.floor(player:getZ())
            and Shared.Distance(player:getX(), player:getY(), record.x, record.y) <= radius
    end)

    for _, record in ipairs(matches) do
        removeTrapPhysical(record)
        Registry.RemoveTrap(record.id, "admin radius removal")
        Service.PendingExplosions[record.id] = nil
        removed = removed + 1
    end

    Registry.Persist("admin radius removal")
    Logger.Audit("ADMIN_REMOVE_RADIUS", Shared.Username(player),
        "radius=" .. tostring(radius) .. " | removed=" .. tostring(removed))
    Logger.Finish(run, true, "removed=" .. tostring(removed))
    return { action = "ADMIN_REMOVE_RADIUS", removed = removed, radius = radius }
end

-- Per explicit instruction: one single bear trap state, period. A second
-- BearTrapClosed item type existed only for the sprung/unarmed visual, but
-- it was never wired into every OTHER system that assumes "BearTrap" is the
-- only bear trap item -- disarm/reverse/free-trapped-bear context menu
-- options, admin remove radius, and pickup all only recognized
-- Shared.Item.BearTrap, so a live BearTrapClosed ground item fell through
-- every one of them. Rather than chase down and fix every integration
-- point for a second item type, this always resolves to the one real
-- item. Still called from the same sites (place-failed, reset,
-- trigger) and from Service.Initialize's startup pass below, so any
-- BearTrapClosed item already sitting in the world from before this
-- revert self-heals back to BearTrap the next time its record is touched
-- or the server restarts, instead of staying stuck forever.
function swapBearTrapVisual(record)
    if record.kind ~= Shared.Kind.BearTrap then return end
    local desiredType = Shared.Item.BearTrap
    local worldObject = Shared.WorldItemAt(record.x, record.y, record.z, record.worldItemId)
    local oldItem = worldObject and worldObject:getItem()

    if oldItem and oldItem:getFullType() == desiredType then
        return
    end

    local square = worldObject and worldObject:getSquare()
        or (type(getCell) == "function" and getCell() and getCell():getGridSquare(
            math.floor(record.x), math.floor(record.y), math.floor(record.z))) or nil

    if not square then return end

    if worldObject then
        square:transmitRemoveItemFromSquare(worldObject)
        if type(square.removeWorldObject) == "function" then square:removeWorldObject(worldObject) end
    end

    -- IsoGridSquare.AddWorldInventoryItem returns the bare InventoryItem,
    -- NOT an IsoWorldInventoryObject. InventoryItem.getWorldItem() leads back
    -- to the IsoWorldInventoryObject wrapper that owns
    -- transmitCompleteItemToClients() (inherited from IsoObject).
    -- Defer the one spawn packet until the replacement metadata is ready.
    local newItem = square:AddWorldInventoryItem(desiredType, 0.5, 0.5, 0, false)
    if not newItem then return end

    local data = newItem:getModData()
    data.SVSBT_TrapId = record.id
    data.SVSBT_Condition = record.condition
    data.SVSBT_MaxCondition = record.maxCondition
    data.SVSBT_State = record.state

    -- InventoryItem.transmitModData() doesn't exist (see the comment above);
    -- getWorldItem() -> transmitCompleteItemToClients() below is the one
    -- real, working sync for this data, so no separate call is needed here.
    local newWorldObject = type(newItem.getWorldItem) == "function" and newItem:getWorldItem() or nil
    if newWorldObject and type(newWorldObject.transmitCompleteItemToClients) == "function" then
        newWorldObject:transmitCompleteItemToClients()
    end

    record.worldItemId = newItem:getID()
end

function updateWorldItemMetadata(record)
    local run = Logger.Begin("Service.updateWorldItemMetadata", record.id)
    swapBearTrapVisual(record)
    local worldObject = Shared.WorldItemAt(record.x, record.y, record.z, record.worldItemId)

    if not worldObject or not worldObject:getItem() then
        Logger.Finish(run, true, "world item absent")
        return false
    end

    local data = worldObject:getItem():getModData()
    data.SVSBT_TrapId = record.id
    data.SVSBT_Condition = record.condition
    data.SVSBT_MaxCondition = record.maxCondition
    data.SVSBT_State = record.state
    -- Still-arming (setter hasn't moved two tiles away yet) reads
    -- as state=armed too, but the client's pickup guard must not treat the
    -- owner's own freshly-placed, not-yet-live trap as tamper-worthy.
    data.SVSBT_ArmPending = record.armPending == true
    data.SVSBT_TriggerCount = record.triggerCount

    -- A complete-item transmission is AddItemToMap, not an update. Placement
    -- already sends that packet; sending it again creates duplicate client
    -- world objects with the same inventory ID and stalls pickup transactions.
    -- Keep item data for persistence/recovery, and publish live state through
    -- the existing world object's independently synchronized ModData.
    local worldData = worldObject:getModData()
    worldData.SVSBT_TrapId = data.SVSBT_TrapId
    worldData.SVSBT_Condition = data.SVSBT_Condition
    worldData.SVSBT_MaxCondition = data.SVSBT_MaxCondition
    worldData.SVSBT_State = data.SVSBT_State
    worldData.SVSBT_ArmPending = data.SVSBT_ArmPending
    worldData.SVSBT_TriggerCount = data.SVSBT_TriggerCount
    worldObject:transmitModData()

    Logger.Finish(run, true, "updated")
    return true
end

local function targetAllowed(record, target)
    local run = Logger.Begin("Service.targetAllowed", record.id)
    local result = false

    if instanceof(target, "IsoAnimal") then
        result = Config.Get("TargetAnimals")
    elseif instanceof(target, "IsoZombie") then
        result = Config.Get("TargetZombies")
    elseif instanceof(target, "IsoPlayer") then
        result = canTargetPlayer(record, target, true)
    end

    Logger.Finish(run, true, "allowed=" .. tostring(result))
    return result
end

local function destroyFloorTrap(record, reason)
    local run = Logger.Begin("Service.destroyFloorTrap", record.id)
    record.state = Shared.State.Destroyed
    record.destroyedAtHours = Shared.WorldAgeHours()
    removeWorldTrapItem(record)
    Registry.RemoveTrap(record.id, reason or "destroyed")
    Logger.Finish(run, true, tostring(reason or "destroyed"))
    return true
end

-- The shells are spent firing the trap, not salvageable -- only the shotgun
-- itself (blast-damaged, half condition), the rope, and the plank can ever
-- come back, and even then only two of the three: one is picked at random
-- and left out entirely, so it must be rebuilt from scratch.
local function dropShotgunMaterials(square)
    if not square then return end
    local materials = { "Base.Shotgun", "Base.Rope", "Base.Plank" }
    local skip = 1 + (type(ZombRand) == "function" and ZombRand(#materials) or math.random(0, #materials - 1))

    for i, fullType in ipairs(materials) do
        if i ~= skip then
            local dropped = square:AddWorldInventoryItem(fullType, 0.5, 0.5, 0)

            if fullType == "Base.Shotgun" and dropped
                and type(dropped.getConditionMax) == "function"
                and type(dropped.setCondition) == "function" then
                dropped:setCondition(math.floor(dropped:getConditionMax() / 2))
            end
        end
    end
end

local function activateFloorTrap(record, target)
    local run = Logger.Begin("Service.activateFloorTrap", record.id)

    if not targetAllowed(record, target) or not claimTarget(record, target) then
        Logger.Finish(run, true, "target ignored")
        return false
    end

    local activated = false

    if record.kind == Shared.Kind.NailBoard then
        activated = Combat.Apply(record, target, Effects.TriggerNailBoard)

    elseif record.kind == Shared.Kind.BearTrap then
        activated = Combat.Apply(record, target, Effects.TriggerBearTrap)

        if activated then
            record.state = Shared.State.Sprung

            if randomChance(Config.Get("BearTrapConditionLossChance")) then
                record.condition = math.max(0, record.condition
                    - (Config.Get("BearTrapActivationConditionLoss") * Config.Get("ConditionLossMultiplier")))
            end

            if instanceof(target, "IsoPlayer") and not instanceof(target, "IsoAnimal") then
                local username = Shared.Username(target)

                if Combat.IsDead(target) then
                    record.occupant = { kind = "corpse", username = username }
                else
                    Service.HeldPlayers[username] = record.id
                    record.heldUsername = username
                    record.occupant = { kind = "player", username = username }
                    if type(target.getModData) == "function" then
                        target:getModData().SVSBT_BearTrapHeldId = record.id
                    end
                    if type(target.transmitModData) == "function" then target:transmitModData() end
                    send(target, "WARNING", {
                        source = "bear_trap",
                        message = "The jaws snap shut on your leg! You're caught -- "
                            .. "sprinting free without disarming it first will tear the wound open.",
                    })
                end
            elseif instanceof(target, "IsoZombie") then
                Creatures.Capture(record, target, "zombie")
            elseif instanceof(target, "IsoAnimal") then
                Creatures.Capture(record, target, "animal")
            end
        end
    elseif record.kind == Shared.Kind.WaterBucket then
        -- Real floor trap now: triggers on tile contact like every other
        -- floor trap, no door involved. WetPlayer is player-only by design
        -- (matches the original "soaks whoever's there" intent) -- a
        -- zombie/animal crossing it harmlessly does nothing.
        activated = Combat.Apply(record, target, Effects.WetPlayer)

        if activated then
            spillWaterBucket(record)
        end
    elseif record.kind == Shared.Kind.ShotgunDoor then
        activated = Combat.Apply(record, target, Effects.TriggerShotgun)

        if activated then
            record.condition = 0
            dropShotgunMaterials(target:getSquare())
        end
    end

    if activated then
        if record.kind == Shared.Kind.NailBoard then
            useNailBoard(record)
        else
            record.triggerCount = (tonumber(record.triggerCount) or 0) + 1
        end
        record.lastTriggeredAtHours = Shared.WorldAgeHours()
        soundDetonation(record)
        Registry.MarkDirty("floor trap activation")
        Logger.Audit("FLOOR_TRAP_TRIGGER", targetKey(target),
            "id=" .. record.id .. " | kind=" .. record.kind .. " | condition=" .. tostring(record.condition))

        if record.kind ~= Shared.Kind.NailBoard then
            if record.condition <= 0 then
                destroyFloorTrap(record, "condition depleted")
            else
                updateWorldItemMetadata(record)
            end
        end
    end

    Logger.Finish(run, true, "activated=" .. tostring(activated))
    return activated
end

local function activateFloorTrapOnVehicle(record, vehicle)
    local run = Logger.Begin("Service.activateFloorTrapOnVehicle", record.id)

    if not Config.Get("TargetVehicles") or not claimTarget(record, vehicle) then
        Logger.Finish(run, true, "vehicle ignored")
        return false
    end

    local activated = false

    if record.kind == Shared.Kind.NailBoard then
        activated = Effects.DamageVehicleTire(vehicle)

    elseif record.kind == Shared.Kind.BearTrap then
        Effects.DamageVehicleTire(vehicle)
        activated = true
        record.condition = 0

    elseif record.kind == Shared.Kind.ShotgunDoor then
        activated = Effects.ShotgunVehicle(vehicle)
        if activated then
            record.condition = 0
            dropShotgunMaterials(type(getCell) == "function" and getCell():getGridSquare(record.x, record.y, record.z) or nil)
        end
    end

    if activated then
        if record.kind == Shared.Kind.NailBoard then
            useNailBoard(record)
        else
            record.triggerCount = (tonumber(record.triggerCount) or 0) + 1
        end
        soundDetonation(record)
        Registry.MarkDirty("vehicle crossed floor trap")
        Logger.Audit("VEHICLE_FLOOR_TRAP", tostring(vehicle:getId()),
            "id=" .. record.id .. " | kind=" .. record.kind)

        if record.kind ~= Shared.Kind.NailBoard then
            if record.condition <= 0 then
                destroyFloorTrap(record, "vehicle destroyed trap")
            else
                updateWorldItemMetadata(record)
            end
        end
    end

    Logger.Finish(run, true, "activated=" .. tostring(activated))
    return activated
end

-- The whole premise of a booby trap: attempting to just pick it up off the
-- ground is tampering, not a free disarm. The client-side pickup guard
-- (ISGrabItemAction, SVSBT_Hooks.lua) blocks the vanilla grab the instant it
-- starts and reports it here instead -- everything is re-validated
-- server-side since a modified client could send this without the guard
-- ever having fired for real.
function Service.TrapGrabbed(player, args)
    local run = Logger.Begin("Service.TrapGrabbed", Shared.Username(player))
    Service.Initialize()
    if not claimCooldown(player, "trap_grabbed", 500) then return finishFailure(run, "REQUEST_COOLDOWN_ACTIVE") end
    local record = Registry.GetTrap(args and args.trapId)

    if not record or not Shared.FloorKinds[record.kind] then
        Logger.Finish(run, true, "not a floor trap")
        return { action = "TRAP_GRABBED", triggered = false }
    end

    if record.state ~= Shared.State.Armed and record.state ~= Shared.State.Sprung then
        Logger.Finish(run, true, "not live")
        return { action = "TRAP_GRABBED", triggered = false }
    end

    if record.armPending then
        Logger.Finish(run, true, "still arm-pending")
        return { action = "TRAP_GRABBED", triggered = false }
    end

    local inRange = Shared.Distance(player:getX(), player:getY(), record.x, record.y) <= Config.Get("InteractionRangeTiles") + 1
    if not inRange then
        Logger.Finish(run, true, "out of range")
        return { action = "TRAP_GRABBED", triggered = false }
    end

    if not Shared.WorldItemAt(record.x, record.y, record.z, record.worldItemId) then
        Logger.Finish(run, true, "world item absent")
        return { action = "TRAP_GRABBED", triggered = false }
    end

    if record.kind == Shared.Kind.NailBoard then
        Combat.Apply(record, player, Effects.TriggerNailBoard)
    elseif record.kind == Shared.Kind.BearTrap then
        Combat.Apply(record, player, Effects.TriggerBearTrap)
    elseif record.kind == Shared.Kind.WaterBucket then
        Combat.Apply(record, player, Effects.WetPlayer)
        spillWaterBucket(record)
    elseif record.kind == Shared.Kind.ShotgunDoor then
        Combat.Apply(record, player, Effects.TriggerShotgun)
    end

    soundDetonation(record)
    send(player, "WARNING", {
        trapId = record.id,
        source = record.kind,
        message = "You reach for it without thinking -- it goes off in your hands!",
    })

    Logger.Audit("TRAP_GRABBED", Shared.Username(player), "id=" .. record.id .. " | kind=" .. record.kind)
    if record.kind == Shared.Kind.NailBoard then
        useNailBoard(record)
    else
        destroyFloorTrap(record, "grabbed off the ground")
    end
    Registry.Persist("trap grabbed")
    Logger.Finish(run, true, "triggered")
    return { action = "TRAP_GRABBED", triggered = true }
end

local function processFloorTrap(record)
    local run = Logger.Begin("Service.processFloorTrap", record.id)

    if not Shared.FloorKinds[record.kind] then
        Logger.Finish(run, true, "not a floor trap")
        return false
    end

    if record.kind == Shared.Kind.BearTrap then Creatures.ReconcileLegacy(record) end
    local ticking = record.state == Shared.State.Armed and not record.armPending
    local holding = record.kind == Shared.Kind.BearTrap and record.state == Shared.State.Sprung
        and record.occupant and (record.occupant.kind == "zombie" or record.occupant.kind == "animal")

    if not ticking and not holding then
        Logger.Finish(run, true, "inactive")
        return false
    end

    if not existingFeatureOperational(record) then
        Logger.Finish(run, true, "feature disabled")
        return false
    end

    local worldObject = Shared.WorldItemAt(record.x, record.y, record.z, record.worldItemId)

    if not worldObject then
        Registry.RemoveTrap(record.id, "world item removed or picked up")
        Logger.Finish(run, true, "registry cleaned")
        return true
    end

    local square = worldObject:getSquare()
    local changed = false
    local presentKeys = {}

    if ticking and square and square:getMovingObjects() then
        local movers = square:getMovingObjects()

        for i = 0, movers:size() - 1 do
            local mover = movers:get(i)

            if mover and (instanceof(mover, "IsoPlayer") or instanceof(mover, "IsoZombie") or instanceof(mover, "IsoAnimal")) then
                presentKeys[targetKey(mover)] = true
                changed = activateFloorTrap(record, mover) or changed

                if record.state ~= Shared.State.Armed or not Registry.GetTrap(record.id) then
                    break
                end
            end
        end
    elseif holding and square then
        changed = Creatures.TickHeld(record, square) or changed
    end

    if Registry.GetTrap(record.id) and record.state == Shared.State.Armed and not record.armPending then
        local vehicles = Shared.FindVehiclesNear(record.x + 0.5, record.y + 0.5, record.z, 1.25)

        for _, vehicle in ipairs(vehicles) do

            if vehicle and math.floor(vehicle:getZ()) == math.floor(record.z)
                and Shared.Distance(vehicle:getX(), vehicle:getY(), record.x + 0.5, record.y + 0.5) <= 0.85 then
                presentKeys[targetKey(vehicle)] = true
                changed = activateFloorTrapOnVehicle(record, vehicle) or changed
                break
            end
        end
    end

    if ticking then releaseAbsentTargets(record, presentKeys) end
    Logger.Finish(run, true, "changed=" .. tostring(changed))
    return changed
end

-- Integer walk of the straight line between the two stakes (inclusive),
-- rounding to the nearest tile each step -- good enough for a short wire
-- (capped at TripWireMaxLengthTiles) without needing real line-of-sight math.
local function tripWireTiles(record)
    local tiles = {}
    local x1, y1 = math.floor(record.x), math.floor(record.y)
    local x2, y2 = math.floor(record.x2), math.floor(record.y2)
    local dx, dy = x2 - x1, y2 - y1
    local steps = math.max(math.abs(dx), math.abs(dy))

    if steps <= 0 then
        tiles[1] = { x = x1, y = y1 }
        return tiles
    end

    for i = 0, steps do
        tiles[#tiles + 1] = {
            x = x1 + math.floor((dx * i / steps) + 0.5),
            y = y1 + math.floor((dy * i / steps) + 0.5),
        }
    end

    return tiles
end

local function processTripWire(record)
    local run = Logger.Begin("Service.processTripWire", record.id)

    if record.kind ~= Shared.Kind.TripWire or record.state ~= Shared.State.Armed or record.armPending then
        Logger.Finish(run, true, "inactive")
        return false
    end

    if not existingFeatureOperational(record) then
        Logger.Finish(run, true, "feature disabled")
        return false
    end

    if type(getCell) ~= "function" or not getCell() then
        Logger.Finish(run, true, "no cell")
        return false
    end

    local cell = getCell()
    local wireZ = math.floor(record.z)
    local tiles = tripWireTiles(record)
    local onWire = {}
    for _, tile in ipairs(tiles) do onWire[tile.x .. ":" .. tile.y] = true end

    local presentKeys = {}
    local triggeredBy, triggerX, triggerY = nil, nil, nil

    -- Anything on foot: player, zombie or animal. No target filtering of any
    -- kind -- a trip wire is a burglar alarm, and whatever just walked
    -- through it is exactly what the owner wants to be told about.
    for _, tile in ipairs(tiles) do
        local square = cell:getGridSquare(tile.x, tile.y, wireZ)
        local movers = square and square:getMovingObjects() or nil

        if movers then
            for i = 0, movers:size() - 1 do
                local mover = movers:get(i)

                if mover and (instanceof(mover, "IsoPlayer") or instanceof(mover, "IsoZombie")
                    or instanceof(mover, "IsoAnimal")) then
                    presentKeys[targetKey(mover)] = true

                    if not triggeredBy and claimTarget(record, mover) then
                        triggeredBy, triggerX, triggerY = mover, tile.x, tile.y
                    end
                end
            end
        end
    end

    -- A car driving through snaps the wire exactly like a boot does. Vehicles
    -- are not moving objects on a square, so they need their own sweep.
    Shared.ForEachVehicle(function(vehicle)
        if math.floor(vehicle:getZ()) ~= wireZ then return false end

        local vx, vy = math.floor(vehicle:getX()), math.floor(vehicle:getY())
        if not onWire[vx .. ":" .. vy] then return false end

        presentKeys[targetKey(vehicle)] = true

        if not triggeredBy and claimTarget(record, vehicle) then
            triggeredBy, triggerX, triggerY = vehicle, vx, vy
        end

        return false
    end)

    releaseAbsentTargets(record, presentKeys)

    if not triggeredBy then
        Logger.Finish(run, true, "no trigger")
        return false
    end

    local currentHours = Shared.WorldAgeHours()
    local alarmCount = tonumber(record.alarmCount) or 0

    if alarmCount > 0 and currentHours - (tonumber(record.lastAlarmAtHours) or 0) < Config.Get("TripWireCooldownHours") then
        Logger.Finish(run, true, "cooldown active")
        return false
    end

    local actor = instanceof(triggeredBy, "IsoPlayer") and triggeredBy or nil
    local crosser = instanceof(triggeredBy, "BaseVehicle") and "vehicle"
        or (actor and "player"
            or (instanceof(triggeredBy, "IsoZombie") and "zombie" or "animal"))
    local changed = triggerTripWireAlarm(record, triggerX, triggerY, wireZ,
        "trip wire crossed by " .. crosser, actor)

    -- Each wire only has so many real detonations in it before it snaps --
    -- the LAST one still sounds the alarm, then the trap breaks for good.
    if changed and (tonumber(record.alarmCount) or 0) >= Config.Get("TripWireMaxTriggers") then
        record.state = Shared.State.Spent
        record.spentAtHours = currentHours
        Logger.Audit("TRIP_WIRE_BROKEN", record.owner, "id=" .. record.id .. " | triggers=" .. tostring(record.alarmCount))
        -- Broken for good: no world item to leave behind (just two stakes
        -- and a wire, gone), so remove outright instead of leaving a
        -- lingering spent record.
        Registry.RemoveTrap(record.id, "trip wire exhausted")
    end

    Logger.Finish(run, true, "changed=" .. tostring(changed))
    return changed
end

-- A lingering proximity hazard, not a one-shot trigger: while armed it stays
-- dangerous to anyone who lingers nearby for its whole active window, not
-- just once. The shared arming gate starts its active window after retreat.
local function processBiologicalAgent(record)
    local run = Logger.Begin("Service.processBiologicalAgent", record.id)

    if record.kind ~= Shared.Kind.BiologicalSample or record.state ~= Shared.State.Armed or record.armPending then
        Logger.Finish(run, true, "inactive")
        return false
    end

    if not existingFeatureOperational(record) then
        Logger.Finish(run, true, "feature disabled")
        return false
    end

    local currentHours = Shared.WorldAgeHours()

    if currentHours >= (tonumber(record.expiresAtHours) or currentHours) then
        record.state = Shared.State.Spent
        record.spentAtHours = currentHours
        Logger.Audit("BIOLOGICAL_AGENT_EXPIRED", record.owner, "id=" .. record.id)
        -- Fully spent, same real completion as a deliberate neutralize: an
        -- empty jar left behind, not a stale sealed-sample/gassing prop
        -- that no longer does anything, and no lingering registry record.
        removeWorldTrapItem(record)
        local expiredSquare = type(getCell) == "function" and getCell()
            and getCell():getGridSquare(math.floor(record.x), math.floor(record.y), math.floor(record.z)) or nil
        if expiredSquare then
            expiredSquare:AddWorldInventoryItem(Shared.Item.EmptyBiologicalJar, 0.5, 0.5, 0)
        end
        Registry.RemoveTrap(record.id, "biological agent expired")
        Logger.Finish(run, true, "expired")
        return true
    end

    local radius = Config.Get("BiologicalSampleRadiusTiles")
    local presentKeys = {}
    local changed = false

    for _, candidate in ipairs(collectPlayers()) do
        if math.floor(candidate:getZ()) == math.floor(record.z)
            and Shared.PlayerDistanceTo(candidate, record.x + 0.5, record.y + 0.5) <= radius then
            presentKeys[targetKey(candidate)] = true

            if canTargetPlayer(record, candidate, true) and claimTarget(record, candidate) then
                local factor = Combat.Apply(record, candidate, Effects.BeginBiologicalExposure)
                Registry.AddExposure(Shared.Username(candidate), {
                    sourceRecordId = record.id, owner = record.owner, kind = record.kind,
                    startedAtHours = currentHours,
                    endsAtHours = currentHours + Config.Get("AnthraxDurationHours"),
                    factor = factor,
                    lastTickAtMs = nowMs(),
                })
                -- An exposure IS this trap going off -- it has no single bang,
                -- so each person it catches sounds one, from the jar's own tile.
                soundDetonation(record)
                Logger.Audit("BIOLOGICAL_EXPOSURE", Shared.Username(candidate),
                    "sample=" .. record.id .. " | factor=" .. tostring(factor))
                send(candidate, "WARNING", {
                    source = "biological_agent",
                    message = "The air here feels wrong. You feel violently ill.",
                })
                changed = true
            end
        end
    end

    releaseAbsentTargets(record, presentKeys)
    Logger.Finish(run, true, "changed=" .. tostring(changed))
    return changed
end

-- BaseVehicle.getCharacter(int) and
-- getMaxPassengers() enumerate every seat, not just the driver's. A
-- comma-joined signature of currently-occupied seat indices is enough to
-- detect "someone new just got in" without needing full per-seat identity
-- tracking across ticks.
local function vehicleOccupantSeats(vehicle)
    local seats = {}
    local total = type(vehicle.getMaxPassengers) == "function" and vehicle:getMaxPassengers() or 0

    for i = 0, total - 1 do
        local ok, occupant = pcall(function() return vehicle:getCharacter(i) end)
        if ok and occupant then seats[#seats + 1] = tostring(i) end
    end

    return table.concat(seats, ",")
end

local function newSeatEntered(currentSeats, lastSeats)
    if currentSeats == "" then return false end
    local wrapped = "," .. tostring(lastSeats or "") .. ","

    for seat in string.gmatch(currentSeats, "[^,]+") do
        if not string.find(wrapped, "," .. seat .. ",", 1, true) then return true end
    end

    return false
end

-- VehiclePart.getDoor()/getWindow() with VehicleDoor.isOpen() and
-- VehicleWindow.isOpen()/isDestroyed() cover
-- every door and window on the car, not just whichever seat the driver used.
local function vehicleOpenDoorCount(vehicle)
    local count = 0
    local total = type(vehicle.getPartCount) == "function" and vehicle:getPartCount() or 0

    for i = 0, total - 1 do
        local ok, part = pcall(function() return vehicle:getPartByIndex(i) end)
        local door = ok and part and type(part.getDoor) == "function" and part:getDoor() or nil
        if door and door:isOpen() then count = count + 1 end
    end

    return count
end

local function vehicleBrokenWindowCount(vehicle)
    local count = 0
    local total = type(vehicle.getPartCount) == "function" and vehicle:getPartCount() or 0

    for i = 0, total - 1 do
        local ok, part = pcall(function() return vehicle:getPartByIndex(i) end)
        local window = ok and part and type(part.getWindow) == "function" and part:getWindow() or nil
        if window and (window:isOpen() or window:isDestroyed()) then count = count + 1 end
    end

    return count
end

local function processVehicleRecord(record)
    local run = Logger.Begin("Service.processVehicleRecord", record.id)

    if not Shared.VehicleKinds[record.kind]
        or record.state == Shared.State.Spent or record.state == Shared.State.Destroyed then
        Logger.Finish(run, true, "inactive")
        return false
    end

    if not existingFeatureOperational(record) then
        Logger.Finish(run, true, "feature disabled")
        return false
    end

    local vehicle = Shared.FindVehicleByUID(record.vehicleUid)

    if not vehicle then
        Logger.Finish(run, true, "vehicle unloaded")
        return false
    end

    local changed = false
    record.x, record.y, record.z = vehicle:getX(), vehicle:getY(), vehicle:getZ()
    Registry.ReindexTrap(record)
    local driver = vehicle:getDriver()
    local driverName = driver and Shared.Username(driver) or nil
    local engineRunning = vehicle:isEngineRunning()
    local driverEntered = driverName ~= nil and driverName ~= record.lastDriverName
    local engineStarted = engineRunning and record.lastEngineRunning ~= true

    -- Tamper coverage isn't just the driver's seat: any passenger seat, any
    -- door, any window counts as tampering with the whole car.
    local currentSeats = vehicleOccupantSeats(vehicle)
    local seatEntered = newSeatEntered(currentSeats, record.lastOccupantSeats)
    local openDoors = vehicleOpenDoorCount(vehicle)
    local doorOpened = openDoors > (tonumber(record.lastOpenDoors) or 0)
    local brokenWindows = vehicleBrokenWindowCount(vehicle)
    local windowBroken = brokenWindows > (tonumber(record.lastBrokenWindows) or 0)

    if record.armPending then
        -- Not live yet: still tracks driver/engine state below (so it
        -- doesn't misread the current occupant as "just entered" the moment
        -- it does arm), but nothing can trigger off of it yet.
    elseif record.kind == Shared.Kind.DriverSeatDye and record.state == Shared.State.Armed and driverEntered
        and canTargetPlayer(record, driver, false) then
        Combat.Apply(record, driver, Effects.ApplyDye)
        soundDetonation(record, vehicle:getSquare())
        Logger.Audit("DRIVER_DYE_TRIGGER", driverName, "id=" .. record.id)
        -- Single-use per device, not per player: fully consumed and gone,
        -- exactly like the ignition charge, so a fresh one can be installed
        -- and used again -- no lingering spent record, no stale mechanics
        -- warning icon left behind on the vehicle.
        Registry.RemoveTrap(record.id, "driver dye triggered")
        changed = true
    elseif record.kind == Shared.Kind.TamperAlarm and record.state == Shared.State.Armed
        and (seatEntered or doorOpened or windowBroken) then
        local reason = seatEntered and "seat entered" or (doorOpened and "door opened" or "window broken")
        changed = triggerVehicleTamperAlarm(record, vehicle, driver, reason) or changed
    elseif record.kind == Shared.Kind.IgnitionCharge and record.state == Shared.State.Armed and engineStarted
        and (not driver or canTargetPlayer(record, driver, true)) then
        Service.ScheduleExplosion(record, driver, Config.Get("IgnitionFuseSeconds"), "ignition")
        changed = true
    elseif record.kind == Shared.Kind.RemoteImmobilizer and record.state == Shared.State.Armed
        and record.immobilized == true and engineRunning then
        vehicle:shutOff()
        changed = true
    end

    record.lastDriverName = driverName
    record.lastEngineRunning = vehicle:isEngineRunning()
    record.lastOccupantSeats = currentSeats
    record.lastOpenDoors = openDoors
    record.lastBrokenWindows = brokenWindows
    record.updatedAtHours = Shared.WorldAgeHours()

    if Config.Get("WirelessHeartbeatEnabled")
        and (record.kind == Shared.Kind.TamperAlarm or record.kind == Shared.Kind.RemoteImmobilizer) then
        local intervalHours = Config.Get("WirelessHeartbeatSeconds") / 3600

        if Shared.WorldAgeHours() - (tonumber(record.lastHeartbeatHours) or 0) >= intervalHours then
            record.lastHeartbeatHours = Shared.WorldAgeHours()
            changed = true
        end
    end

    if changed then Registry.MarkDirty("vehicle runtime update") end
    Logger.Finish(run, true, "changed=" .. tostring(changed))
    return changed
end

local function randomIndex(n)
    if n <= 1 then return n end
    local roll = type(ZombRandFloat) == "function" and ZombRandFloat(0, 1)
        or (type(ZombRand) == "function" and ZombRand(0, 100000) / 100000 or math.random())
    return math.min(n, 1 + math.floor(roll * n))
end

-- Damages a real majority of the vehicle's parts beyond the engine (excluded
-- via excludeId) so an ignition-charge detonation reads as a real car bomb
-- wrecking most of the vehicle, not just "the engine took damage".
--
-- Independent chance per part alone is a coin flip, not a guarantee -- a
-- small vehicle could roll under 50% damaged. Instead, shuffle the
-- eligible parts and GUARANTEE enough of them are damaged that, counting the
-- engine (already damaged by the caller before this runs), strictly more
-- than half of every real part on the vehicle ends up hit -- every time.
-- `fraction` still gives any parts beyond that guaranteed set an independent
-- chance too, so a detonation can wreck more than the bare minimum.
local function damageAdditionalVehicleParts(vehicle, excludeId, amount, fraction)
    local total = type(vehicle.getPartCount) == "function" and vehicle:getPartCount() or 0
    if total <= 0 then return end

    local eligible = {}
    for index = 0, total - 1 do
        local part = vehicle:getPartByIndex(index)

        if part and type(part.getId) == "function" and part:getId() ~= excludeId
            and type(part.getCondition) == "function" and type(part.setCondition) == "function" then
            eligible[#eligible + 1] = part
        end
    end

    -- Fisher-Yates shuffle so *which* parts take the guaranteed hits varies
    -- run to run, even though the guaranteed count itself never does.
    for i = #eligible, 2, -1 do
        local j = randomIndex(i)
        eligible[i], eligible[j] = eligible[j], eligible[i]
    end

    local majorityTarget = math.floor(total / 2) + 1
    local guaranteed = math.min(#eligible, math.max(0, majorityTarget - 1))

    for index, part in ipairs(eligible) do
        if index <= guaranteed or randomChance(fraction) then
            part:setCondition(math.max(0, part:getCondition() - amount))
            if type(vehicle.transmitPartCondition) == "function" then vehicle:transmitPartCondition(part) end
        end
    end
end

local function processPendingExplosions()
    local run = Logger.Begin("Service.processPendingExplosions")
    local changed = false
    local current = nowMs()

    for trapId, pending in pairs(Service.PendingExplosions) do
        local due = current >= (tonumber(pending.dueAtMs) or math.huge)
            or Shared.WorldAgeHours() >= (tonumber(pending.dueAtHours) or math.huge)
        if due then
            local record = Registry.GetTrap(trapId)

            if record and record.state == Shared.State.Triggered then
                local sourceObject = record.kind == Shared.Kind.ExplosiveMailbox and recordObject(record) or nil
                local ignitionVehicle = record.kind == Shared.Kind.IgnitionCharge
                    and Shared.FindVehicleByUID(record.vehicleUid) or nil
                local ignitionDriver = ignitionVehicle and ignitionVehicle:getDriver() or nil
                -- A car bomb should reliably catch fire, same as a rigged mailbox.
                local forceFire = record.kind == Shared.Kind.ExplosiveMailbox or record.kind == Shared.Kind.IgnitionCharge
                Effects.TriggerExplosion(record.x, record.y, record.z, sourceObject, function(target)
                    return target ~= ignitionDriver and canTargetPlayer(record, target, true)
                end, forceFire, record)

                if record.kind == Shared.Kind.IgnitionCharge then
                    local vehicle = ignitionVehicle

                    if vehicle then
                        local driver = vehicle:getDriver()

                        if driver and canTargetPlayer(record, driver, true) then
                            Combat.Apply(record, driver, Effects.ExplosionWounds, Config.Get("IgnitionDriverDamage"), "inner")
                        end

                        Effects.DamageVehicleEngine(vehicle, Config.Get("IgnitionEngineDamage"))
                        damageAdditionalVehicleParts(vehicle, "Engine", Config.Get("IgnitionEngineDamage") * 0.6, 0.7)
                        vehicle:shutOff()
                        Service.BurningVehicles[record.id] = {
                            vehicleUid = record.vehicleUid,
                            owner = record.owner, id = record.id, kind = record.kind,
                            dueAtMs = nowMs() + (Config.Get("IgnitionBurnDurationSeconds") * 1000),
                            nextIgniteAtMs = 0,
                        }
                    end
                end

                record.state = Shared.State.Spent
                record.explosionDueAtHours = nil
                record.spentAtHours = Shared.WorldAgeHours()
                record.triggerCount = (tonumber(record.triggerCount) or 0) + 1
                soundDetonation(record)
                Logger.Audit("EXPLOSION", record.triggeredBy,
                    "id=" .. record.id .. " | kind=" .. tostring(record.kind))

                -- A one-shot ignition charge or exploded parcel is consumed
                -- the instant it detonates -- the ordinary
                -- Spent-then-delayed-cleanup path left a lingering record
                -- that the world-container-icon check (and
                -- VisibleSnapshot/MechanicsUI for vehicle devices) don't
                -- filter by state, so a stale warning kept showing on the
                -- container/vehicle long after the item itself was gone.
                -- Remove it for real, right away, instead of waiting for
                -- lifecycle cleanup.
                if record.kind == Shared.Kind.IgnitionCharge or record.kind == Shared.Kind.ExplosiveMailbox then
                    Registry.RemoveTrap(record.id, tostring(record.kind) .. " detonated")
                else
                    Registry.MarkDirty("explosion completed")
                end

                changed = true
            end

            Service.PendingExplosions[trapId] = nil
        end
    end

    Logger.Finish(run, true, "changed=" .. tostring(changed))
    return changed
end

local function processActiveAlarms()
    local current = nowMs()

    for trapId, alarm in pairs(Service.ActiveAlarms) do
        if alarm.kind == Shared.Kind.TripWire then
            if Shared.WorldAgeHours() >= alarm.endHours then
                Service.StopTripWireAlarm(trapId)
            elseif type(addSound) == "function" then
                addSound(nil, alarm.x, alarm.y, alarm.z, Config.Get("TripWireSoundRadiusTiles"), 100)
            end
        elseif current >= (tonumber(alarm.dueAtMs) or 0) then
            Service.StopVehicleAlarm(trapId)
        end
    end
end

-- A one-shot IsoFireManager.StartFire at the detonation site stays there even
-- if the car keeps rolling. Re-ignite at the vehicle's real, current square
-- every few seconds for a while instead, so the fire actually stays with the
-- car (StartFire(cell, square, bool, int) is safe to repeat -- it's the
-- same call the mailbox/ignition explosion already uses once).
local function processBurningVehicles()
    local current = nowMs()

    for trapId, burning in pairs(Service.BurningVehicles) do
        if current >= (tonumber(burning.dueAtMs) or 0) then
            Service.BurningVehicles[trapId] = nil
        else
            local vehicle = Shared.FindVehicleByUID(burning.vehicleUid)

            if not vehicle then
                Service.BurningVehicles[trapId] = nil
            elseif current >= (tonumber(burning.nextIgniteAtMs) or 0) then
                local square = vehicle:getSquare()
                if square and type(getCell) == "function" and getCell()
                    and IsoFireManager and type(IsoFireManager.StartFire) == "function" then
                    pcall(IsoFireManager.StartFire, getCell(), square, true, 100)
                    Combat.TrackFire(burning, square)
                end
                burning.nextIgniteAtMs = current + (Config.Get("IgnitionReigniteSeconds") * 1000)
            end
        end
    end
end

local function processExposures()
    local run = Logger.Begin("Service.processExposures")
    local changed = false
    local currentHours = Shared.WorldAgeHours()
    local currentMs = nowMs()
    local intervalMs = Config.Get("AnthraxTickSeconds") * 1000

    for username, exposure in pairs(Registry.Data.exposures) do
        if currentHours >= (tonumber(exposure.endsAtHours) or 0) then
            Registry.RemoveExposure(username)
            changed = true
        elseif currentMs - (tonumber(exposure.lastTickAtMs) or 0) >= intervalMs then
            local player = findOnlinePlayer(username)

            if player then
                Combat.Apply(exposure, player, Effects.TickBiologicalExposure, exposure.factor)
                exposure.lastTickAtMs = currentMs
                changed = true

                local reminderMs = Config.Get("AnthraxReminderSeconds") * 1000
                if currentMs - (tonumber(exposure.lastNoticeAtMs) or 0) >= reminderMs then
                    exposure.lastNoticeAtMs = currentMs
                    local hoursLeft = math.max(0, (tonumber(exposure.endsAtHours) or currentHours) - currentHours)
                    send(player, "WARNING", {
                        source = "anthrax",
                        message = "You're still suffering from biological exposure -- roughly "
                            .. string.format("%.1f", hoursLeft) .. " hours of sickness remain.",
                    })
                end
            end
        end
    end

    if changed then Registry.MarkDirty("exposure tick") end
    Logger.Finish(run, true, "changed=" .. tostring(changed))
    return changed
end

-- Self-heals recipe knowledge independently of any client-side read-event
-- hook ever firing correctly. IsoPlayer:getAlreadyReadBook() is a
-- persisted, per-player list of every book/magazine fulltype they have ever
-- finished reading --
-- unlike anything the client tells us about itself, this is authoritative
-- server-side truth. Anyone whose read history includes one of our
-- magazines gets its recipes granted here, every lifecycle pass, forever --
-- so a recipe that never stuck (whatever the reason, then or in the
-- future) repairs itself within a minute without requiring a re-read.
local function syncReadMagazineRecipes()
    local run = Logger.Begin("Service.syncReadMagazineRecipes")
    local grantedAny = false

    for _, player in ipairs(collectPlayers()) do
        if grantRecipesFromReadHistory(player, "RECIPE_SELF_HEAL") then
            grantedAny = true
        end
    end

    Logger.Finish(run, true, "grantedAny=" .. tostring(grantedAny))
    return grantedAny
end

local function processLifecycle()
    local run = Logger.Begin("Service.processLifecycle")
    local currentHours = Shared.WorldAgeHours()
    local expirationHours = Config.Get("TrapExpirationDays") * 24
    local spentHours = Config.Get("SpentTrapCleanupHours")
    local removed = 0
    local matches = Registry.FindTraps(function(record)
        local expired = expirationHours > 0
            and currentHours - (tonumber(record.createdAtHours) or currentHours) >= expirationHours
        local spentExpired = (record.state == Shared.State.Spent or record.state == Shared.State.Destroyed)
            and spentHours >= 0
            and currentHours - (tonumber(record.spentAtHours) or tonumber(record.destroyedAtHours) or currentHours) >= spentHours
        return expired or spentExpired
    end)

    for _, record in ipairs(matches) do
        removeTrapPhysical(record)
        Registry.RemoveTrap(record.id, "lifecycle cleanup")
        Service.PendingExplosions[record.id] = nil
        removed = removed + 1
    end

    for itemId, record in pairs(Registry.Data.documents) do
        local expired = expirationHours > 0
            and currentHours - (tonumber(record.createdAtHours) or currentHours) >= expirationHours
        local inactive = record.state == Shared.State.Spent or record.state == Shared.State.Disabled
        local inactiveExpired = inactive and spentHours >= 0
            and currentHours - (tonumber(record.spentAtHours) or tonumber(record.exposedAtHours) or currentHours) >= spentHours

        if expired or inactiveExpired then
            Registry.RemoveDocument(itemId, "document lifecycle cleanup")
            removed = removed + 1
        end
    end

    Logger.Finish(run, true, "removed=" .. tostring(removed))
    return removed > 0
end

function Service.VisibleSnapshot(player)
    local run = Logger.Begin("Service.VisibleSnapshot", Shared.Username(player))
    Service.Initialize()
    local visible = {}
    local admin = Shared.IsAdmin(player) and Config.Get("AdminOverlayEnabled")
    local floorRange = Config.Get("FloorTrapIconRangeTiles")
    local passiveRange = Config.Get("PassiveDetectionRangeTiles")
    local queryRange = math.max(floorRange, passiveRange, Config.Get("InteractionRangeTiles") + 2)
    local currentFloorOnly = Config.Get("VisibleIndicatorsCurrentFloorOnly")
    local candidates = admin and Registry.OrderedTraps()
        or (currentFloorOnly and Registry.FindNearby(player:getX(), player:getY(), player:getZ(), queryRange)
            or Registry.FindTraps(function(record)
                return Shared.Distance(player:getX(), player:getY(), record.x, record.y) <= queryRange
            end))
    local username = Shared.Username(player)

    for _, record in ipairs(candidates) do
        local entryVisible = false
        local distance = Shared.Distance(player:getX(), player:getY(), record.x, record.y)
        local known = Registry.HasKnowledge(username, record.id)
            or (Config.Get("OwnerAlwaysKnowsTrap") and record.owner == username)
        local passive = Config.Get("PassiveAdvancedDetection") and Shared.AdvancedKinds[record.kind]
            and not known
            and distance <= passiveRange
            and Shared.PerkLevel(player, Perks.Electricity) >= Config.Get("InspectionElectricalLevel")

        if passive then
            grantKnowledge(player, record, 300)
            known = true
        end

        -- A spent/destroyed vehicle device (most are consumed outright on
        -- trigger and never reach here at all, but this is the real,
        -- general fix rather than relying on every kind remembering to
        -- self-remove) must never keep showing a mechanics warning icon or
        -- "already installed" signal once it's no longer a real device.
        if Shared.VehicleKinds[record.kind]
            and (record.state == Shared.State.Spent or record.state == Shared.State.Destroyed) then
            -- entryVisible stays false
        elseif Shared.FloorKinds[record.kind]
            and Config.Get("VisibleFloorTrapIcons") and distance <= floorRange then
            entryVisible = true
        elseif Shared.VehicleKinds[record.kind] and distance <= queryRange
            and Shared.KnowsRecipe(player, record.kind) then
            -- Someone who knows how to build the device recognizes tampering
            -- signs (a rigged battery, seat, etc.) while working on the car,
            -- without needing to have separately Inspected it first.
            entryVisible = true
        elseif record.kind == Shared.Kind.BiologicalSample and record.state == Shared.State.Armed and not record.armPending
            and distance <= Config.Get("BiologicalSampleRadiusTiles") + 1 then
            -- A live sample is a real gas cloud filling the air, not a
            -- concealed trap -- anyone close enough to be gassed (plus one
            -- tile of approach warning) sees it whether or not they've ever
            -- inspected/learned about this specific trap.
            entryVisible = true
        elseif known and distance <= queryRange then
            entryVisible = true
        elseif admin then
            entryVisible = true
        end


        if entryVisible and Config.Get("VisibleIndicatorsRequireLOS") and not admin
            and type(player.CanSee) == "function" then
            -- IsoGameCharacter:CanSee only accepts an IsoObject, never an IsoGridSquare.
            -- Resolve the trap's physical object so the line-of-sight test is real.
            local object = nil
            if Shared.FloorKinds[record.kind] then
                object = Shared.WorldItemAt(record.x, record.y, record.z, record.worldItemId)
            elseif record.kind == Shared.Kind.ExplosiveMailbox then
                object = recordObject(record)
            end
            if object then
                local ok, canSee = pcall(function() return player:CanSee(object) end)
                if ok and canSee == false then entryVisible = false end
            end
        end

        if entryVisible then
            visible[#visible + 1] = {
                trapId = record.id,
                kind = record.kind,
                state = record.state,
                armPending = record.armPending == true,
                x = record.x, y = record.y, z = record.z,
                condition = record.condition,
                vehicleUid = record.vehicleUid,
                owner = admin and record.owner or nil,
                controllerSynced = record.kind == Shared.Kind.RemoteImmobilizer and record.controllerSynced == true or nil,
                x2 = record.kind == Shared.Kind.TripWire and record.x2 or nil,
                y2 = record.kind == Shared.Kind.TripWire and record.y2 or nil,
                -- Sprung is not the same thing as occupied -- the catch can
                -- already be freed/escaped while the trap sits sprung and
                -- empty, waiting on a reset. "Release Victim" needs to
                -- know there is actually something to free, not just that
                -- the trap went off at some point.
                occupied = record.kind == Shared.Kind.BearTrap and record.occupant ~= nil or nil,
                holdsYou = record.kind == Shared.Kind.BearTrap and record.heldUsername == username or nil,
                radius = record.kind == Shared.Kind.BiologicalSample and Config.Get("BiologicalSampleRadiusTiles") or nil,
                admin = admin and Shared.AdvancedKinds[record.kind] == true or false,
            }
        end
    end

    Logger.Finish(run, true, "count=" .. tostring(#visible))
    return { traps = visible, tripWireAlarms = Service.TripWireAlarmSnapshot(player), serverHours = Shared.WorldAgeHours(), admin = admin }
end

local function cleanupRuntimeState()
    local activeNames = {}
    for _, player in ipairs(collectPlayers()) do activeNames[Shared.Username(player)] = true end

    for username in pairs(Service.RequestCooldowns) do
        if not activeNames[username] then Service.RequestCooldowns[username] = nil end
    end
    for username, action in pairs(Service.ActiveActions) do
        if not activeNames[username] or nowMs() > (tonumber(action.expiresAtMs) or 0) then
            Service.ActiveActions[username] = nil
        end
    end
    for trapId in pairs(Service.TargetCooldowns) do
        if not Registry.GetTrap(trapId) then Service.TargetCooldowns[trapId] = nil end
    end
    Registry.PruneKnowledge(activeNames)
end

local function syncVisibleSnapshots()
    local run = Logger.Begin("Service.syncVisibleSnapshots")
    local count = 0

    for _, player in ipairs(collectPlayers()) do
        send(player, "VISIBLE", Service.VisibleSnapshot(player))
        count = count + 1
    end

    Logger.Finish(run, true, "players=" .. tostring(count))
    return count
end

function Service.OwnerDied(player)
    local run = Logger.Begin("Service.OwnerDied", Shared.Username(player))

    Combat.PlayerDied(player)
    Combat.Tick()
    if not Config.Get("RemoveTrapsOnOwnerDeath") then
        Logger.Finish(run, true, "setting disabled")
        return false
    end

    local username = Shared.Username(player)
    local matches = Registry.FindTraps(function(record) return record.owner == username end)

    for _, record in ipairs(matches) do
        removeTrapPhysical(record)
        Registry.RemoveTrap(record.id, "owner death")
        Service.PendingExplosions[record.id] = nil
    end

    Registry.Persist("owner death")
    Logger.Audit("OWNER_DEATH_CLEANUP", username, "removed=" .. tostring(#matches))
    Logger.Finish(run, true, "removed=" .. tostring(#matches))
    return #matches
end

function Service.Tick(force)
    local currentMs = nowMs()
    local interval = Config.Get("ServerTickMilliseconds")

    if force ~= true and currentMs - Service.LastTickMs < interval then
        return false
    end

    Service.LastTickMs = currentMs
    local run = Logger.Begin("Service.Tick")
    Service.Initialize()
    local changed = processPendingExplosions()
    processActiveAlarms()
    processBurningVehicles()
    changed = processExposures() or changed
    local traps = Registry.OrderedTraps()
    local maximum = math.max(1, Config.Get("MaxTrapsProcessedPerTick"))
    local players = collectPlayers()

    -- Observe retreat for every pending trap this tick, even when simulation
    -- work is spread across ticks by the server's trap-processing budget.
    for _, record in ipairs(traps) do
        changed = clearArmPending(record, players) or changed
    end

    if #traps > 0 then
        if Service.TrapCursor > #traps then Service.TrapCursor = 1 end
        local processed = 0

        while processed < maximum and processed < #traps do
            local index = ((Service.TrapCursor + processed - 1) % #traps) + 1
            local record = traps[index]

            if Shared.FloorKinds[record.kind] then
                changed = processFloorTrap(record) or changed
            elseif Shared.VehicleKinds[record.kind] then
                changed = processVehicleRecord(record) or changed
            elseif record.kind == Shared.Kind.TripWire then
                changed = processTripWire(record) or changed
            elseif record.kind == Shared.Kind.BiologicalSample then
                changed = processBiologicalAgent(record) or changed
            end

            processed = processed + 1
        end

        Service.TrapCursor = ((Service.TrapCursor + processed - 1) % #traps) + 1
    end

    for _, record in pairs(Registry.Data.documents) do
        changed = clearArmPending(record, players) or changed
    end
    Arming.PruneDocuments()

    Creatures.TickEscaped()
    Combat.Tick()

    if currentMs - Service.LastVisibleSyncMs >= Config.Get("VisibleSyncSeconds") * 1000 then
        syncVisibleSnapshots()
        Service.LastVisibleSyncMs = currentMs
    end

    if currentMs - (Service.LastLifecycleMs or 0) >= 60000 then
        changed = processLifecycle() or changed
        syncReadMagazineRecipes()
        cleanupRuntimeState()
        Service.LastLifecycleMs = currentMs
    end

    if Registry.Dirty
        and currentMs - Registry.LastPersistMs >= Config.Get("PersistenceIntervalSeconds") * 1000 then
        Registry.Persist("periodic tick")
    end

    Logger.Finish(run, true, "changed=" .. tostring(changed) .. " | traps=" .. tostring(#traps))
    return changed
end

Logger.Info("SVSBT_Service.load", "trap operations and autonomous simulation initialized")

return Service
