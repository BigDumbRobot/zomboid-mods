require "SVSBT_Logger"

SVSBT = SVSBT or {}

local Shared = SVSBT.Shared or {}
SVSBT.Shared = Shared

local Logger = SVSBT.Logger

Shared.Module = "SVSBoobyTraps"
Shared.SchemaVersion = 1
-- Build 42's Lua file API only permits approved extensions.  Keep this token
-- server-local, but use .txt so dedicated servers can actually persist it.
Shared.RegistryKeyFile = "SVSBoobyTraps.registry-key.txt"
Shared.LegacyRegistryKey = "SVSBoobyTraps.Registry"

Shared.Item = {
    SealedBiologicalSample = "SVSBoobyTraps.SealedBiologicalSample",
    WaterBucketTrap = "SVSBoobyTraps.WaterBucketTrap",
    NailBoard = "SVSBoobyTraps.NailBoard",
    BearTrap = "SVSBoobyTraps.BearTrap",
    -- World-only visual variant: never craftable, never handed to a player
    -- (Disarm/salvage always return Shared.Item.BearTrap), only ever used to
    -- swap the ground sprite between armed (jaws open) and not (jaws shut).
    BearTrapClosed = "SVSBoobyTraps.BearTrapClosed",
    ExplosiveParcel = "SVSBoobyTraps.ExplosiveParcel",
    AnthraxAgent = "SVSBoobyTraps.AnthraxAgent",
    IgnitionCharge = "SVSBoobyTraps.IgnitionCharge",
    DriverSeatDyeTrap = "SVSBoobyTraps.DriverSeatDyeTrap",
    VehicleTamperAlarm = "SVSBoobyTraps.VehicleTamperAlarm",
    RemoteImmobilizer = "SVSBoobyTraps.RemoteImmobilizer",
    Controller = "SVSBoobyTraps.BoobyTrapController",
    ShotgunDoorTrap = "SVSBoobyTraps.ShotgunDoorTrap",
    TripWireKit = "SVSBoobyTraps.TripWireKit",
    -- Leftover from a neutralized biological sample. Reuses the real vanilla
    -- item rather than a new custom one -- an empty jar is an empty jar.
    EmptyBiologicalJar = "Base.EmptyJar",
}

Shared.Magazine = {
    WaterBucket = "SVSBoobyTraps.MadMagazine1",
    NailBoard = "SVSBoobyTraps.MadMagazine2",
    BearTrap = "SVSBoobyTraps.MadMagazine3",
    ExplosiveParcel = "SVSBoobyTraps.MadMagazine4",
    BiologicalAgent = "SVSBoobyTraps.MadMagazine5",
    IgnitionCharge = "SVSBoobyTraps.MadMagazine6",
    DriverSeatDye = "SVSBoobyTraps.MadMagazine7",
    TamperAlarm = "SVSBoobyTraps.MadMagazine8",
    RemoteImmobilizer = "SVSBoobyTraps.MadMagazine9",
    ShotgunDoor = "SVSBoobyTraps.MadMagazine10",
    -- Trip wires are taught alongside water buckets, from the same issue.
    TripWire = "SVSBoobyTraps.MadMagazine1",
}

Shared.Kind = {
    WaterBucket = "water_bucket",
    NailBoard = "nail_board",
    BearTrap = "bear_trap",
    ExplosiveMailbox = "explosive_mailbox",
    AnthraxDocument = "anthrax_document",
    IgnitionCharge = "ignition_charge",
    DriverSeatDye = "driver_seat_dye",
    TamperAlarm = "tamper_alarm",
    RemoteImmobilizer = "remote_immobilizer",
    ShotgunDoor = "shotgun_door",
    TripWire = "trip_wire",
    -- A placed-but-unopened sealed sample is inert (state Placed); opening it
    -- arms a lingering proximity hazard (state Armed) rather than a one-shot
    -- trigger, distinct from AnthraxDocument's read-a-specific-page kind.
    BiologicalSample = "biological_sample",
}

Shared.State = {
    Placed = "placed",
    Armed = "armed",
    Triggered = "triggered",
    Sprung = "sprung",
    Spent = "spent",
    Disabled = "disabled",
    Destroyed = "destroyed",
}

Shared.VisibleKinds = {
    [Shared.Kind.WaterBucket] = true,
    [Shared.Kind.NailBoard] = true,
    [Shared.Kind.BearTrap] = true,
    [Shared.Kind.ShotgunDoor] = true,
    [Shared.Kind.TripWire] = true,
}

-- Per explicit instruction: water bucket and shotgun door traps are real
-- floor traps now, not attached to a door object -- placed on a tile,
-- triggered by tile contact (activateFloorTrap/processFloorTrap), and
-- rendered as their own real ground item, exactly like NailBoard/BearTrap.
-- The door-rig mechanism (RigDoor/DoorOpened, directional trappedSide/
-- trappedVector tracking, the rope world-icon) is gone -- it never reliably
-- worked and every floor trap here already did.
Shared.FloorKinds = {
    [Shared.Kind.NailBoard] = true,
    [Shared.Kind.BearTrap] = true,
    [Shared.Kind.WaterBucket] = true,
    [Shared.Kind.ShotgunDoor] = true,
}

Shared.AdvancedKinds = {
    [Shared.Kind.ExplosiveMailbox] = true,
    [Shared.Kind.AnthraxDocument] = true,
    [Shared.Kind.BiologicalSample] = true,
    [Shared.Kind.IgnitionCharge] = true,
    [Shared.Kind.DriverSeatDye] = true,
    [Shared.Kind.TamperAlarm] = true,
    [Shared.Kind.RemoteImmobilizer] = true,
}

Shared.VehicleKinds = {
    [Shared.Kind.IgnitionCharge] = true,
    [Shared.Kind.DriverSeatDye] = true,
    [Shared.Kind.TamperAlarm] = true,
    [Shared.Kind.RemoteImmobilizer] = true,
}

Shared.ItemToKind = {
    [Shared.Item.WaterBucketTrap] = Shared.Kind.WaterBucket,
    [Shared.Item.NailBoard] = Shared.Kind.NailBoard,
    [Shared.Item.BearTrap] = Shared.Kind.BearTrap,
    [Shared.Item.ExplosiveParcel] = Shared.Kind.ExplosiveMailbox,
    [Shared.Item.IgnitionCharge] = Shared.Kind.IgnitionCharge,
    [Shared.Item.DriverSeatDyeTrap] = Shared.Kind.DriverSeatDye,
    [Shared.Item.VehicleTamperAlarm] = Shared.Kind.TamperAlarm,
    [Shared.Item.RemoteImmobilizer] = Shared.Kind.RemoteImmobilizer,
    [Shared.Item.ShotgunDoorTrap] = Shared.Kind.ShotgunDoor,
    [Shared.Item.TripWireKit] = Shared.Kind.TripWire,
    [Shared.Item.SealedBiologicalSample] = Shared.Kind.BiologicalSample,
}

function Shared.SafeNumber(value, minimum, maximum, fallback)
    local run = Logger.Begin("Shared.SafeNumber")
    local number = tonumber(value)

    if number == nil or number ~= number then
        number = tonumber(fallback) or 0
    end

    if minimum ~= nil then
        number = math.max(tonumber(minimum) or number, number)
    end

    if maximum ~= nil then
        number = math.min(tonumber(maximum) or number, number)
    end

    Logger.Finish(run, true, tostring(number))
    return number
end

function Shared.WorldAgeHours()
    local run = Logger.Begin("Shared.WorldAgeHours")
    local hours = 0

    if type(getGameTime) == "function" and getGameTime() then
        hours = tonumber(getGameTime():getWorldAgeHours()) or 0
    end

    Logger.Finish(run, true, "hours=" .. tostring(hours))
    return hours
end

-- Every player the server should consider. Single player has an online-player
-- list too, but it is always empty, so fall back to the local (split-screen)
-- players.
function Shared.Players()
    local result = {}
    local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil

    if online then
        for i = 0, online:size() - 1 do
            local player = online:get(i)
            if player then result[#result + 1] = player end
        end
    end

    if #result == 0 and type(getSpecificPlayer) == "function" then
        local count = type(getNumActivePlayers) == "function" and getNumActivePlayers() or 1
        for i = 0, math.max(1, count) - 1 do
            local player = getSpecificPlayer(i)
            if player then result[#result + 1] = player end
        end
    end

    if #result == 0 and type(getPlayer) == "function" and getPlayer() then
        result[1] = getPlayer()
    end

    return result
end

function Shared.Username(player)
    local run = Logger.Begin("Shared.Username")
    local value = "unknown"

    if player then
        if type(player.getUsername) == "function" then
            value = tostring(player:getUsername() or "unknown")
        elseif type(player.getDescriptor) == "function" and player:getDescriptor() then
            value = tostring(player:getDescriptor():getForename() or "unknown")
        end
    end

    Logger.Finish(run, true, value)
    return value
end

local function accessLevelGrantsAdmin(access)
    access = string.lower(tostring(access or ""))
    return access ~= "" and access ~= "none" and access ~= "user" and access ~= "player"
end

-- Client-side, this almost always answers "is whoever is looking at THIS
-- screen an admin" (menu/render gating). Vanilla answers that with the
-- globals isAdmin()/getAccessLevel() (e.g. ISVehicleMechanics.lua), not
-- player:getAccessLevel(), which is meant for the SERVER to check an
-- arbitrary connected player and doesn't reliably reflect what the local
-- client was granted.
function Shared.IsAdmin(player)
    local run = Logger.Begin("Shared.IsAdmin")
    local result = false

    if type(isClient) == "function" and isClient() then
        local ok, viaGlobal = pcall(function()
            if type(isAdmin) == "function" and isAdmin() then return true end
            if type(getAccessLevel) == "function" then return accessLevelGrantsAdmin(getAccessLevel()) end
            return false
        end)
        result = ok and viaGlobal == true
    end

    if not result and player and type(player.getAccessLevel) == "function" then
        result = accessLevelGrantsAdmin(player:getAccessLevel())
    end

    Logger.Finish(run, true, "admin=" .. tostring(result))
    return result
end

function Shared.Distance(x1, y1, x2, y2)
    local run = Logger.Begin("Shared.Distance")
    local dx = (tonumber(x1) or 0) - (tonumber(x2) or 0)
    local dy = (tonumber(y1) or 0) - (tonumber(y2) or 0)
    local value = math.sqrt((dx * dx) + (dy * dy))
    Logger.Finish(run, true, tostring(value))
    return value
end

function Shared.PlayerDistanceTo(player, x, y)
    local run = Logger.Begin("Shared.PlayerDistanceTo")
    local value = math.huge

    if player then
        value = Shared.Distance(player:getX(), player:getY(), x, y)
    end

    Logger.Finish(run, true, tostring(value))
    return value
end

function Shared.PerkLevel(player, perk)
    local run = Logger.Begin("Shared.PerkLevel")
    local value = 0

    if player and perk and type(player.getPerkLevel) == "function" then
        value = tonumber(player:getPerkLevel(perk)) or 0
    end

    Logger.Finish(run, true, tostring(value))
    return value
end

-- Build 42's plain InventoryItem has no getInventory(); only InventoryContainer
-- (bag) items expose a nested container. Resolve it safely for the fallbacks.
local function nestedContainer(item)
    if item == nil then return nil end

    if type(item.getItemContainer) == "function" then
        local ok, container = pcall(function() return item:getItemContainer() end)
        if ok and container then return container end
    end

    if type(item.getInventory) == "function" then
        local ok, container = pcall(function() return item:getInventory() end)
        if ok and container then return container end
    end

    return nil
end

function Shared.GetItemById(container, itemId)
    local run = Logger.Begin("Shared.GetItemById", itemId)
    local found = nil
    itemId = tonumber(itemId)

    if container and itemId then
        if type(container.getItemWithIDRecursiv) == "function" then
            local ok, item = pcall(function() return container:getItemWithIDRecursiv(itemId) end)
            if ok then found = item end
        end

        if found == nil then
            local items = container:getItems()

            for i = 0, items:size() - 1 do
                local item = items:get(i)

                if tonumber(item:getID()) == itemId then
                    found = item
                    break
                end

                local sub = nestedContainer(item)
                if sub then
                    found = Shared.GetItemById(sub, itemId)
                    if found then break end
                end
            end
        end
    end

    Logger.Finish(run, true, "found=" .. tostring(found ~= nil))
    return found
end

function Shared.FindItemByFullType(container, fullType)
    local run = Logger.Begin("Shared.FindItemByFullType", fullType)
    local found = nil

    if container and fullType then
        if type(container.getItemFromTypeRecurse) == "function" then
            local ok, item = pcall(function() return container:getItemFromTypeRecurse(fullType) end)
            if ok then found = item end
        end

        if found == nil then
            local items = container:getItems()

            for i = 0, items:size() - 1 do
                local item = items:get(i)

                if item:getFullType() == fullType then
                    found = item
                    break
                end

                local sub = nestedContainer(item)
                if sub then
                    found = Shared.FindItemByFullType(sub, fullType)
                    if found then break end
                end
            end
        end
    end

    Logger.Finish(run, true, "found=" .. tostring(found ~= nil))
    return found
end

function Shared.CountItem(container, fullType)
    local run = Logger.Begin("Shared.CountItem", fullType)
    local count = 0

    if container and fullType then
        if type(container.getCountTypeRecurse) == "function" then
            -- getCountTypeRecurse takes the bare type name, WITHOUT the
            -- "Module." prefix (vanilla: getCountType("Stone2")). Only trust
            -- it when it finds something; otherwise fall through to the
            -- manual full-type scan below rather than a wrong zero.
            local shortType = tostring(fullType):match("%.([^.]+)$") or tostring(fullType)
            local ok, value = pcall(function() return container:getCountTypeRecurse(shortType) end)
            if ok and type(value) == "number" and value > 0 then
                Logger.Finish(run, true, "count=" .. tostring(value))
                return value
            end
        end

        local items = container:getItems()

        for i = 0, items:size() - 1 do
            local item = items:get(i)

            if item:getFullType() == fullType then
                count = count + 1
            end

            local sub = nestedContainer(item)
            if sub then
                count = count + Shared.CountItem(sub, fullType)
            end
        end
    end

    Logger.Finish(run, true, "count=" .. tostring(count))
    return count
end

function Shared.RemoveItem(container, item)
    local run = Logger.Begin("Shared.RemoveItem")
    local result = false

    if container and item and item:getContainer() == container then
        container:Remove(item)
        result = true
    elseif item and item:getContainer() then
        item:getContainer():Remove(item)
        result = true
    end

    Logger.Finish(run, result, "removed=" .. tostring(result))
    return result
end

function Shared.ConsumeFullType(container, fullType, count)
    local run = Logger.Begin("Shared.ConsumeFullType", fullType)
    local remaining = math.max(0, math.floor(tonumber(count) or 1))

    while remaining > 0 do
        local item = Shared.FindItemByFullType(container, fullType)

        if not item then
            break
        end

        Shared.RemoveItem(item:getContainer() or container, item)
        remaining = remaining - 1
    end

    local consumed = math.max(0, (math.floor(tonumber(count) or 1)) - remaining)
    Logger.Finish(run, remaining == 0, "consumed=" .. tostring(consumed))
    return remaining == 0, consumed
end

-- Matches the container TYPE string -- the same lookup vanilla's
-- ContainerButtonIcons.lua uses to pick a tab icon per container -- so it
-- only ever matches an actual mailbox ("postbox") or trash receptacle
-- ("bin"/"dumpster"), never an arbitrary crate, drawer, or fridge.
local MailboxContainerTypes = { postbox = true, bin = true, dumpster = true }

local function containerTypeOf(object)
    local container = object ~= nil and type(object.getContainer) == "function" and object:getContainer() or nil
    return container and type(container.getType) == "function"
        and string.lower(tostring(container:getType() or "")) or ""
end

function Shared.IsMailbox(object)
    local run = Logger.Begin("Shared.IsMailbox")
    local result = MailboxContainerTypes[containerTypeOf(object)] == true
    Logger.Finish(run, true, "mailbox=" .. tostring(result))
    return result
end

-- The parcel rigs three different container types, so naming all of them
-- "mailbox" in menus and messages reads as a bug to the player staring at a
-- dumpster. The container type IsMailbox already matches on is exactly what
-- names the thing, so reuse it. Anything unrecognized falls back to the
-- neutral "container" instead of guessing.
local MailboxNouns = {
    postbox = { "mailbox", "Mailbox" },
    bin = { "trash can", "Trash Can" },
    dumpster = { "dumpster", "Dumpster" },
}

function Shared.MailboxNoun(object, titleCase)
    local run = Logger.Begin("Shared.MailboxNoun")
    local noun = MailboxNouns[containerTypeOf(object)]
    local value = noun and noun[titleCase and 2 or 1] or (titleCase and "Container" or "container")
    Logger.Finish(run, true, "noun=" .. value)
    return value
end

function Shared.IsDoor(object)
    local run = Logger.Begin("Shared.IsDoor")
    local result = object ~= nil and (instanceof(object, "IsoDoor") or instanceof(object, "IsoThumpable"))

    if result and type(object.IsOpen) ~= "function" then
        result = false
    end

    if result and instanceof(object, "IsoThumpable") and type(object.isDoor) == "function" then
        result = object:isDoor()
    end

    Logger.Finish(run, true, "door=" .. tostring(result))
    return result
end

function Shared.IsReadableDocument(item)
    local run = Logger.Begin("Shared.IsReadableDocument")
    local result = false

    if item then
        result = instanceof(item, "Literature")

        if not result then
            local value = string.lower(tostring(item:getType() or ""))
            result = string.find(value, "book", 1, true) ~= nil
                or string.find(value, "magazine", 1, true) ~= nil
                or string.find(value, "newspaper", 1, true) ~= nil
                or string.find(value, "note", 1, true) ~= nil
                or string.find(value, "paperwork", 1, true) ~= nil
                or string.find(value, "paper", 1, true) ~= nil
                or string.find(value, "photo", 1, true) ~= nil
        end
    end

    Logger.Finish(run, true, "readable=" .. tostring(result))
    return result
end

function Shared.ObjectIndex(object)
    local run = Logger.Begin("Shared.ObjectIndex")
    local index = -1

    if object and object:getSquare() then
        local objects = object:getSquare():getObjects()

        for i = 0, objects:size() - 1 do
            if objects:get(i) == object then
                index = i
                break
            end
        end
    end

    Logger.Finish(run, true, "index=" .. tostring(index))
    return index
end

-- `objectIndex` is a position in the square's object list captured earlier
-- (often client-side); that list's order isn't guaranteed stable once other
-- objects on the square are added/removed in between, so a stale index can
-- silently resolve to the wrong object -- or the right slot but the wrong
-- object entirely. When `predicate` is given (e.g. Shared.IsDoor/IsMailbox)
-- and the indexed object doesn't satisfy it, re-scan the square for one that
-- does instead of failing outright.
function Shared.ObjectAt(x, y, z, objectIndex, predicate)
    local run = Logger.Begin("Shared.ObjectAt")
    local object = nil
    local square = getCell() and getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z)) or nil

    if square and tonumber(objectIndex) then
        local objects = square:getObjects()
        local index = math.floor(tonumber(objectIndex))

        if index >= 0 and index < objects:size() then
            object = objects:get(index)
        end
    end

    if square and predicate and not (object and predicate(object)) then
        local objects = square:getObjects()

        for i = 0, objects:size() - 1 do
            local candidate = objects:get(i)

            if candidate and predicate(candidate) then
                object = candidate
                break
            end
        end
    end

    Logger.Finish(run, true, "found=" .. tostring(object ~= nil))
    return object
end

function Shared.WorldItemAt(x, y, z, itemId)
    local run = Logger.Begin("Shared.WorldItemAt", itemId)
    local found = nil
    local square = getCell() and getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z)) or nil
    itemId = tonumber(itemId)

    if square and itemId then
        local objects = square:getWorldObjects()

        for i = 0, objects:size() - 1 do
            local worldObject = objects:get(i)
            local item = worldObject and worldObject:getItem() or nil

            if item and tonumber(item:getID()) == itemId then
                found = worldObject
                break
            end
        end
    end

    Logger.Finish(run, true, "found=" .. tostring(found ~= nil))
    return found
end

-- Finds the first loose item of a given full type lying on a square, e.g. a
-- NailBoard or BearTrap dropped or spotted on the ground rather than carried.
function Shared.GroundItemByType(square, fullType)
    local run = Logger.Begin("Shared.GroundItemByType", fullType)
    local found = nil

    if square and type(square.getWorldObjects) == "function" then
        local objects = square:getWorldObjects()

        for i = 0, objects:size() - 1 do
            local worldObject = objects:get(i)
            local item = worldObject and worldObject:getItem() or nil

            if item and item:getFullType() == fullType then
                found = item
                break
            end
        end
    end

    Logger.Finish(run, true, "found=" .. tostring(found ~= nil))
    return found
end

function Shared.VehicleUID(vehicle, create)
    local run = Logger.Begin("Shared.VehicleUID")
    local uid = nil

    if vehicle and vehicle:getModData() then
        local data = vehicle:getModData()
        uid = data.SVSBT_VehicleUID

        if (uid == nil or uid == "") and create == true then
            local serial = tostring(type(getTimestampMs) == "function" and getTimestampMs() or math.floor(Shared.WorldAgeHours() * 3600000))
            local random = tostring(type(ZombRand) == "function" and ZombRand(100000, 999999) or math.random(100000, 999999))
            uid = "SVSBT-V-" .. serial .. "-" .. random
            data.SVSBT_VehicleUID = uid

            if type(vehicle.transmitModData) == "function" then
                vehicle:transmitModData()
            end
        end
    end

    Logger.Finish(run, true, tostring(uid))
    return uid
end

-- IsoCell:getVehicles() returns a java HashSet with no indexed access, so
-- vehicles:get(i) raises "Object tried to call nil". Iterate the java iterator.
function Shared.ForEachVehicle(callback)
    local cell = type(getCell) == "function" and getCell() or nil
    local vehicles = cell and cell:getVehicles() or nil
    if not vehicles or type(vehicles.iterator) ~= "function" then return 0 end

    local ok, iterator = pcall(function() return vehicles:iterator() end)
    if not ok or not iterator then return 0 end

    local count = 0
    while iterator:hasNext() do
        local vehicle = iterator:next()
        if vehicle then
            count = count + 1
            if callback(vehicle) == true then break end
        end
    end
    return count
end

function Shared.FindVehicleByUID(uid)
    local run = Logger.Begin("Shared.FindVehicleByUID", uid)
    uid = uid and tostring(uid) or nil
    local current = type(getTimestampMs) == "function" and getTimestampMs() or 0
    local stale = current - (tonumber(Shared.VehicleCacheBuiltAtMs) or 0) >= 500

    if stale or type(Shared.VehicleCacheByUID) ~= "table" then
        Shared.VehicleCacheByUID = {}
        Shared.VehicleCacheBuckets = {}
        Shared.VehicleCacheBuiltAtMs = current

        Shared.ForEachVehicle(function(vehicle)
            local vehicleUid = Shared.VehicleUID(vehicle, false)

            if vehicleUid then
                Shared.VehicleCacheByUID[tostring(vehicleUid)] = vehicle
            end

            local key = tostring(math.floor(vehicle:getZ())) .. ":"
                .. tostring(math.floor(vehicle:getX() / 10)) .. ":"
                .. tostring(math.floor(vehicle:getY() / 10))
            local bucket = Shared.VehicleCacheBuckets[key] or {}
            bucket[#bucket + 1] = vehicle
            Shared.VehicleCacheBuckets[key] = bucket
        end)
    end

    local found = uid and Shared.VehicleCacheByUID[uid] or nil

    -- A UID may have been assigned after this frame's cache was built.
    if uid and not found then
        Shared.ForEachVehicle(function(vehicle)
            if Shared.VehicleUID(vehicle, false) == uid then
                found = vehicle
                Shared.VehicleCacheByUID[uid] = vehicle
                return true
            end
        end)
    end

    Logger.Finish(run, true, "found=" .. tostring(found ~= nil))
    return found
end

function Shared.FindVehiclesNear(x, y, z, radius)
    local run = Logger.Begin("Shared.FindVehiclesNear")
    -- Refresh the shared cache without adding a second full vehicle scan.
    Shared.FindVehicleByUID(nil)
    local results = {}
    local seen = {}
    radius = math.max(0, tonumber(radius) or 1)
    local minimumX = math.floor((tonumber(x) - radius) / 10)
    local maximumX = math.floor((tonumber(x) + radius) / 10)
    local minimumY = math.floor((tonumber(y) - radius) / 10)
    local maximumY = math.floor((tonumber(y) + radius) / 10)
    local floorZ = math.floor(tonumber(z) or 0)

    for bucketX = minimumX, maximumX do
        for bucketY = minimumY, maximumY do
            local key = tostring(floorZ) .. ":" .. tostring(bucketX) .. ":" .. tostring(bucketY)
            for _, vehicle in ipairs(Shared.VehicleCacheBuckets[key] or {}) do
                if not seen[vehicle] and Shared.Distance(x, y, vehicle:getX(), vehicle:getY()) <= radius then
                    seen[vehicle] = true
                    results[#results + 1] = vehicle
                end
            end
        end
    end

    Logger.Finish(run, true, "count=" .. tostring(#results))
    return results
end

-- Which MAD Magazine issue teaches each trap, and the skills a placement/install
-- needs. Advanced levels are read from Sandbox so this text always matches.
-- Magazine item -> the craftRecipe(s) it teaches (a list -- Magazine No. 1
-- teaches both the water bucket and the trip wire from the same issue). The
-- mod force-learns these on read so it works even if the script
-- LearnedRecipes linkage misbehaves.
Shared.MagazineRecipe = {
    ["SVSBoobyTraps.MadMagazine1"] = { "SVSBT_CraftWaterBucketTrap", "SVSBT_CraftTripWire" },
    ["SVSBoobyTraps.MadMagazine2"] = { "SVSBT_CraftNailBoard", "SVSBT_ForgeBearTrap" },
    ["SVSBoobyTraps.MadMagazine3"] = { "SVSBT_ForgeBearTrap" },
    ["SVSBoobyTraps.MadMagazine4"] = { "SVSBT_AssembleExplosiveParcel" },
    ["SVSBoobyTraps.MadMagazine5"] = { "SVSBT_PrepareBiologicalAgent", "SVSBT_CultureBiologicalSample" },
    ["SVSBoobyTraps.MadMagazine6"] = { "SVSBT_AssembleIgnitionCharge" },
    ["SVSBoobyTraps.MadMagazine7"] = { "SVSBT_AssembleDriverSeatDyeTrap" },
    ["SVSBoobyTraps.MadMagazine8"] = { "SVSBT_AssembleVehicleTamperAlarm" },
    ["SVSBoobyTraps.MadMagazine9"] = { "SVSBT_AssembleRemoteImmobilizer" },
    ["SVSBoobyTraps.MadMagazine10"] = { "SVSBT_RigShotgunTrap" },
}

Shared.KindMagazine = {
    [Shared.Kind.WaterBucket] = "MAD Magazine No. 1 - Improvised Door Pranks",
    [Shared.Kind.NailBoard] = "MAD Magazine No. 2 - Boards That Bite",
    -- Taught by either issue -- No. 2 covers it alongside the nail board too.
    [Shared.Kind.BearTrap] = "MAD Magazine No. 2 or No. 3",
    [Shared.Kind.ExplosiveMailbox] = "MAD Magazine No. 4 - Special Delivery",
    [Shared.Kind.AnthraxDocument] = "MAD Magazine No. 5 - Contaminated Correspondence",
    [Shared.Kind.IgnitionCharge] = "MAD Magazine No. 6 - Starting with a Bang",
    [Shared.Kind.DriverSeatDye] = "MAD Magazine No. 7 - The Scarlet Driver",
    [Shared.Kind.TamperAlarm] = "MAD Magazine No. 8 - Sounding the Alarm",
    [Shared.Kind.RemoteImmobilizer] = "MAD Magazine No. 9 - Remote Roadblocks",
    [Shared.Kind.ShotgunDoor] = "MAD Magazine No. 10 - Both Barrels",
    -- Taught by the very same issue as the water bucket -- no separate magazine.
    [Shared.Kind.TripWire] = "MAD Magazine No. 1 - Improvised Door Pranks",
    -- Whoever knows how to prepare a biological agent also knows how to
    -- safely neutralize a sample -- same issue, same underlying knowledge.
    [Shared.Kind.BiologicalSample] = "MAD Magazine No. 5 - Contaminated Correspondence",
}

-- A controller is named for the device it runs, since two devices use one:
-- SVSBT_DeviceKind once paired, SVSBT_ForKind on a blank immobilizer's.
Shared.ControllerName = {
    tamper_alarm = "Vehicle Tamper Alarm Controller",
    remote_immobilizer = "Immobilizer Controller",
}

function Shared.NameController(item)
    if not item or item:getFullType() ~= Shared.Item.Controller then return end
    local data = item:getModData()
    local name = Shared.ControllerName[tostring(data.SVSBT_DeviceKind or data.SVSBT_ForKind or "")]
    if name and item:getName() ~= name then
        item:setName(name)
        pcall(function() item:setCustomName(true) end)
    end
end

-- Trap kind -> the craftRecipe that teaches it, so counter-espionage (disarm)
-- and the rigged-trap warning icon can both be limited to players who
-- actually know how to build the device in question.
Shared.KindRecipe = {
    [Shared.Kind.WaterBucket] = "SVSBT_CraftWaterBucketTrap",
    [Shared.Kind.NailBoard] = "SVSBT_CraftNailBoard",
    [Shared.Kind.BearTrap] = "SVSBT_ForgeBearTrap",
    [Shared.Kind.ExplosiveMailbox] = "SVSBT_AssembleExplosiveParcel",
    [Shared.Kind.AnthraxDocument] = "SVSBT_PrepareBiologicalAgent",
    [Shared.Kind.BiologicalSample] = "SVSBT_PrepareBiologicalAgent",
    [Shared.Kind.IgnitionCharge] = "SVSBT_AssembleIgnitionCharge",
    [Shared.Kind.DriverSeatDye] = "SVSBT_AssembleDriverSeatDyeTrap",
    [Shared.Kind.TamperAlarm] = "SVSBT_AssembleVehicleTamperAlarm",
    [Shared.Kind.RemoteImmobilizer] = "SVSBT_AssembleRemoteImmobilizer",
    [Shared.Kind.ShotgunDoor] = "SVSBT_RigShotgunTrap",
    [Shared.Kind.TripWire] = "SVSBT_CraftTripWire",
}

-- True if the player has learned the recipe for this trap kind (i.e. read the
-- matching MAD Magazine). Kinds with no mapped recipe are never gated.
function Shared.KnowsRecipe(player, kind)
    local recipe = Shared.KindRecipe[kind]
    if not recipe then return true end
    if not player or type(player.getKnownRecipes) ~= "function" then return false end
    -- player:isRecipeKnown(name) is not reliable here: the single-arg
    -- overload passes ignoreSandbox=false, so with the SeeNotLearntRecipe
    -- sandbox option on it returns true for any craftRecipe name whether or
    -- not the player knows it. getKnownRecipes():contains(name) is the list
    -- the NeedToBeLearn gate itself checks, and matches vanilla usage in
    -- ISLiteratureUI.lua.
    local ok, list = pcall(function() return player:getKnownRecipes() end)
    if not ok or not list then return false end
    return list:contains(recipe) == true
end

-- Whether this player may SEE the warning indicator for a trap kind (the
-- orange SVSBT_TrapIndicator icons: the contaminated-document overlay, the
-- rigged-mailbox container tab, the vehicle mechanics rows, the admin world
-- overlay). Recognizing the tell-tale signs of a rigged device is knowledge
-- taught by the MAD Magazine that teaches the device itself -- a player who
-- has never read the issue sees nothing at all, even standing on top of it
-- and even after the server has otherwise marked the trap visible to them
-- (an Inspect result, ownership, passive detection). Admins keep every
-- indicator, matching Shared.RecipeGap and every server-side check here.
--
-- Deliberately NOT applied to the biological agent's mist: a live sample is
-- a real gas cloud hanging in the air, not a concealed mechanism, so it
-- stays visible to everyone it can reach. See SVSBT_Render.drawBiologicalMist.
function Shared.ShowsWarningIndicator(player, kind)
    if player == nil then return false end
    if Shared.IsAdmin(player) then return true end
    return Shared.KnowsRecipe(player, kind) == true
end

local PerkLabel = {
    Woodwork = "Carpentry", Trapping = "Trapping", MetalWelding = "Welding",
    Electricity = "Electrical", Mechanics = "Mechanics", Maintenance = "Maintenance",
    Doctor = "First Aid", Aiming = "Aiming",
}

-- Returns nil when the player may act on this kind, or a player-facing sentence
-- explaining exactly what is missing. `mode` is "place" (default) or "disarm".
function Shared.RequirementGap(player, kind, mode)
    local Config = SVSBT.Config
    if player == nil or Config == nil then return nil end

    local requirements
    if mode == "disarm" then
        requirements = { { "Maintenance", Config.Get("DisarmMaintenanceLevel") } }
        if Shared.AdvancedKinds[kind] then
            requirements[#requirements + 1] = { "Electricity", Config.Get("DisarmElectricalLevel") }
        end
        if Shared.VehicleKinds[kind] or kind == Shared.Kind.BearTrap then
            requirements[#requirements + 1] = { "Mechanics", Config.Get("DisarmMechanicsLevel") }
        end
    elseif kind == Shared.Kind.WaterBucket or kind == Shared.Kind.TripWire then
        -- Same skill tier as the water bucket -- learned from the same issue.
        requirements = { { "Woodwork", Config.Get("WaterBucketCarpentryLevel") } }
    elseif kind == Shared.Kind.NailBoard then
        requirements = { { "Woodwork", Config.Get("NailBoardCarpentryLevel") } }
    elseif kind == Shared.Kind.BearTrap then
        requirements = { { "Trapping", Config.Get("BearTrapTrappingLevel") }, { "MetalWelding", Config.Get("BearTrapWeldingLevel") } }
    elseif kind == Shared.Kind.ShotgunDoor then
        requirements = { { "Woodwork", Config.Get("ShotgunDoorCarpentryLevel") }, { "Aiming", Config.Get("ShotgunDoorAimingLevel") } }
    elseif kind == Shared.Kind.BiologicalSample then
        -- Placing and opening a found sample is a simple physical act, not a
        -- skilled build -- no skill gate, unlike crafting the agent itself.
        requirements = {}
    else
        requirements = {
            { "Electricity", Config.Get("AdvancedElectricalLevel") },
            { "Mechanics", Config.Get("AdvancedMechanicsLevel") },
            { "Maintenance", Config.Get("AdvancedMaintenanceLevel") },
        }
        if kind == Shared.Kind.AnthraxDocument then
            requirements[#requirements + 1] = { "Doctor", Config.Get("BiologicalFirstAidLevel") }
        end
    end

    local missing = {}
    for _, req in ipairs(requirements) do
        local perk = Perks and Perks[req[1]]
        local level = math.floor(tonumber(req[2]) or 0)
        if level > 0 and Shared.PerkLevel(player, perk) < level then
            missing[#missing + 1] = (PerkLabel[req[1]] or req[1]) .. " " .. tostring(level)
        end
    end

    if #missing == 0 then return nil end

    if mode == "disarm" then
        return "You lack the skill to safely disarm this. Requires " .. table.concat(missing, ", ") .. "."
    end

    -- This is a skill-level gate, independent of having read the magazine --
    -- say so explicitly, since "Requires Trapping 3" reads to a player who
    -- already knows the recipe as "but I have the magazine!".
    local magazine = Shared.KindMagazine[kind]
    local text = "Requires skill levels " .. table.concat(missing, ", ") .. " to place safely (reading the magazine only unlocks the recipe, not the skill)."
    if magazine then
        text = text .. " The recipe itself is taught by " .. magazine .. "."
    end
    return text
end

-- Returns nil when the player may place/build this kind, or a player-facing
-- sentence naming the MAD Magazine they need to read first. This is the
-- placement-side counterpart to the KnowsRecipe check Service.Disarm already
-- makes before letting someone handle an existing one -- crafting the
-- item itself requires the recipe too, but an admin-spawned, found, or
-- traded item bypasses that, so placement needs its own independent gate.
function Shared.RecipeGap(player, kind)
    if Shared.IsAdmin(player) then return nil end
    if Shared.KnowsRecipe(player, kind) then return nil end
    local magazine = Shared.KindMagazine[kind]
    return "You don't know how this is built, so you can't safely set it up"
        .. (magazine and (" -- read " .. magazine .. " first.") or ".")
end

function Shared.FeatureEnabledForKind(kind)
    local run = Logger.Begin("Shared.FeatureEnabledForKind", kind)
    local Config = SVSBT.Config
    local result = Config ~= nil and Config.Get("Enabled")

    if result and kind == Shared.Kind.WaterBucket then result = Config.Get("EntryTrapsEnabled") and Config.Get("WaterBucketEnabled") end
    if result and kind == Shared.Kind.NailBoard then result = Config.Get("EntryTrapsEnabled") and Config.Get("NailBoardEnabled") end
    if result and kind == Shared.Kind.BearTrap then result = Config.Get("EntryTrapsEnabled") and Config.Get("BearTrapEnabled") end
    if result and kind == Shared.Kind.ShotgunDoor then result = Config.Get("EntryTrapsEnabled") and Config.Get("ShotgunDoorEnabled") end
    if result and kind == Shared.Kind.TripWire then result = Config.Get("EntryTrapsEnabled") and Config.Get("TripWireEnabled") end
    if result and kind == Shared.Kind.ExplosiveMailbox then result = Config.Get("AdvancedTrapsEnabled") and Config.Get("ExplosiveMailboxEnabled") end
    if result and kind == Shared.Kind.AnthraxDocument then result = Config.Get("AdvancedTrapsEnabled") and Config.Get("AnthraxEnabled") end
    if result and kind == Shared.Kind.BiologicalSample then result = Config.Get("AdvancedTrapsEnabled") and Config.Get("AnthraxEnabled") end
    if result and kind == Shared.Kind.IgnitionCharge then result = Config.Get("AdvancedTrapsEnabled") and Config.Get("VehicleDevicesEnabled") and Config.Get("IgnitionChargeEnabled") end
    if result and kind == Shared.Kind.DriverSeatDye then result = Config.Get("AdvancedTrapsEnabled") and Config.Get("VehicleDevicesEnabled") and Config.Get("DriverSeatDyeEnabled") end
    if result and kind == Shared.Kind.TamperAlarm then result = Config.Get("AdvancedTrapsEnabled") and Config.Get("VehicleDevicesEnabled") and Config.Get("TamperAlarmEnabled") end
    if result and kind == Shared.Kind.RemoteImmobilizer then result = Config.Get("AdvancedTrapsEnabled") and Config.Get("VehicleDevicesEnabled") and Config.Get("RemoteImmobilizerEnabled") end

    Logger.Finish(run, true, "enabled=" .. tostring(result == true))
    return result == true
end

function Shared.HeldWeapon(character)
    local function usable(item)
        return item and type(item.IsWeapon) == "function" and item:IsWeapon()
            and not (type(item.isBareHands) == "function" and item:isBareHands())
            and not (type(item.getCondition) == "function" and item:getCondition() <= 0)
    end
    if not character then return nil end
    local primary = character:getPrimaryHandItem()
    if usable(primary) then return primary end
    local secondary = character:getSecondaryHandItem()
    if usable(secondary) then return secondary end
end

-- Pick the safest usable tool actually held in either hand. Inventory contents
-- alone do not qualify. Melee reach comes from the weapon's own B42 definition;
-- firearm range is projectile range, so use its one/two-handed size instead.
function Shared.BearTrapResetTool(character)
    local bestItem, bestMultiplier
    local function consider(item)
        if not item or (type(item.getCondition) == "function" and item:getCondition() <= 0)
            or (type(item.isBareHands) == "function" and item:isBareHands()) then return end
        local weapon = type(item.IsWeapon) == "function" and item:IsWeapon()
        local tool = type(item.getDisplayCategory) == "function" and item:getDisplayCategory() == "Tool"
        if not weapon and not tool then return end

        local reach = 1.1 -- Short hand tool when there is no melee-reach definition.
        if weapon and type(item.isRanged) == "function" and item:isRanged() then
            reach = type(item.isTwoHandWeapon) == "function" and item:isTwoHandWeapon() and 1.5 or 0.85
        elseif type(item.getMaxRange) == "function" then
            reach = tonumber(item:getMaxRange()) or reach
        end
        local multiplier = math.max(0.5, math.min(2.0, 3.5 - 2.0 * reach))
        if not bestMultiplier or multiplier < bestMultiplier then
            bestItem, bestMultiplier = item, multiplier
        end
    end
    if character then
        if type(character.getPrimaryHandItem) == "function" then consider(character:getPrimaryHandItem()) end
        if type(character.getSecondaryHandItem) == "function" then consider(character:getSecondaryHandItem()) end
    end
    return bestItem, bestMultiplier
end

Logger.Info("SVSBT_Shared.load", "shared constants and validation helpers initialized")

return Shared
