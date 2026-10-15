require "SVSBT_Registry"

if type(isClient) == "function" and isClient() and not isServer() then return end

SVSBT.Server.Arming = SVSBT.Server.Arming or {}
local Arming = SVSBT.Server.Arming
local Shared, Registry = SVSBT.Shared, SVSBT.Server.Registry
local documentItems = {}
local ARMING_DISTANCE = 2

function Arming.Begin(record, player)
    record.armPending = true
    record.armPendingSetBy = Shared.Username(player)
    record.armedAtHours = nil
    if record.kind == Shared.Kind.AnthraxDocument then
        record.x, record.y, record.z = player:getX(), player:getY(), player:getZ()
    end
end

function Arming.TrackDocument(record, item)
    documentItems[record.id] = item
end

local function worldPosition(object)
    local square = object and object:getSquare()
    if square and getCell():getGridSquare(square:getX(), square:getY(), square:getZ()) == square
        and square:getWorldObjects():contains(object) then
        return square:getX() + 0.5, square:getY() + 0.5, square:getZ()
    end
end

local function itemPosition(item)
    if not item then return end
    local x, y, z = worldPosition(item:getWorldItem())
    if x then return x, y, z end
    local container = item:getContainer()
    if not container or Shared.GetItemById(container, item:getID()) ~= item then return end
    if type(container.getOutermostContainer) == "function" then
        container = container:getOutermostContainer()
    end
    if not container then return end
    if type(container.getWorldItem) == "function" then
        x, y, z = worldPosition(container:getWorldItem())
        if x then return x, y, z end
    end
    local parent = container:getParent()
    -- Player inventories are resolved from the current online players below;
    -- a cached inventory from a disconnected player is not a live position.
    if not parent or instanceof(parent, "IsoPlayer") then return end
    local square = parent:getSquare()
    if not square or getCell():getGridSquare(square:getX(), square:getY(), square:getZ()) ~= square then return end
    if instanceof(parent, "BaseVehicle") then return parent:getX(), parent:getY(), parent:getZ() end
    return square:getX() + 0.5, square:getY() + 0.5, square:getZ()
end

local function documentOnSquare(square, itemId)
    if not square then return end
    local world = square:getWorldObjects()
    for i = 0, world:size() - 1 do
        local item = world:get(i):getItem()
        if item:getID() == itemId then return item end
        if type(item.getItemContainer) == "function" then
            local found = Shared.GetItemById(item:getItemContainer(), itemId)
            if found then return found end
        end
    end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local count = type(object.getContainerCount) == "function" and object:getContainerCount() or 1
        for index = 0, count - 1 do
            local container = type(object.getContainerByIndex) == "function"
                and object:getContainerByIndex(index) or object:getContainer()
            local found = Shared.GetItemById(container, itemId)
            if found then return found end
        end
    end
end

local function documentPosition(record, players)
    local item, x, y, z
    for _, player in ipairs(players) do
        item = Shared.GetItemById(player:getInventory(), record.itemId)
        if item then
            x, y, z = player:getX(), player:getY(), player:getZ()
            break
        end
    end
    if not item then
        item = documentItems[record.id]
        x, y, z = itemPosition(item)
    end
    if not x and record.x and record.y and record.z then
        -- Recover a dropped/stored document after loading a save or receiving
        -- a newly deserialized item. Search only around its last known location.
        for dx = -2, 2 do
            for dy = -2, 2 do
                item = documentOnSquare(getCell():getGridSquare(math.floor(record.x) + dx,
                    math.floor(record.y) + dy, math.floor(record.z)), tonumber(record.itemId))
                if item then x, y, z = itemPosition(item); break end
            end
            if x then break end
        end
    end
    if x then
        documentItems[record.id] = item
        if record.x ~= x or record.y ~= y or record.z ~= z then
            record.x, record.y, record.z = x, y, z
            Registry.MarkDirty("pending document moved")
        end
    end
    return x, y
end

local function distance(record, setter, players)
    if Shared.VehicleKinds[record.kind] then
        local vehicle = Shared.FindVehicleByUID(record.vehicleUid)
        if not vehicle or setter:getVehicle() == vehicle then return 0 end
        return Shared.PlayerDistanceTo(setter, vehicle:getX(), vehicle:getY())
    end
    if record.kind == Shared.Kind.AnthraxDocument then
        local x, y = documentPosition(record, players)
        return x and Shared.PlayerDistanceTo(setter, x, y) or 0
    end
    local x, y = record.x + 0.5, record.y + 0.5
    if record.kind == Shared.Kind.TripWire and record.x2 and record.y2 then
        -- Distance to the whole wire, including its middle and both endpoints.
        local dx, dy = record.x2 - record.x, record.y2 - record.y
        local lengthSquared = dx * dx + dy * dy
        local t = lengthSquared > 0 and math.max(0, math.min(1,
            ((setter:getX() - x) * dx + (setter:getY() - y) * dy) / lengthSquared)) or 0
        x, y = x + t * dx, y + t * dy
    end
    return Shared.PlayerDistanceTo(setter, x, y)
end

function Arming.TryArm(record, players)
    -- Older unopened grace periods used a separate biological-sample flag.
    if record.pendingArm then
        record.armPending = true
        record.pendingArm = nil
        Registry.MarkDirty("migrate biological arming")
    end
    if not record.armPending or record.state ~= Shared.State.Armed then return false end
    local setter
    for _, player in ipairs(players) do
        if Shared.Username(player) == (record.armPendingSetBy or record.owner) then setter = player; break end
    end
    -- A logout or an unloaded target never substitutes for observing retreat.
    if not setter or distance(record, setter, players) < ARMING_DISTANCE then return false end
    record.armPending = false
    record.armedAtHours = Shared.WorldAgeHours()
    if record.kind == Shared.Kind.BiologicalSample then
        record.expiresAtHours = record.armedAtHours + SVSBT.Config.Get("BiologicalSampleDurationHours")
    end
    documentItems[record.id] = nil
    return true
end

function Arming.PruneDocuments()
    for id, item in pairs(documentItems) do
        local record = Registry.GetDocument(item:getID())
        if not record or record.id ~= id or not record.armPending then documentItems[id] = nil end
    end
end

return Arming
