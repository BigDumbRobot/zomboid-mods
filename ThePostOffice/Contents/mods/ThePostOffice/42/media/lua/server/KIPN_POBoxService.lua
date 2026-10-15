-- KIPN_POBoxService.lua
--
-- Server-authoritative registry and world-object lifecycle for
-- physical PO Box containers. Admins create boxes inside Post Office
-- zones; ClaimService purchases the registered entries and issues a
-- real key whose keyId matches exactly one locked container.

if isClient() and not isServer() then return end

require "KIPN_Shared"
require "KIPN_WorldRegistry"
require "KIPN_Permissions"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.POBoxService = KIPN.Server.POBoxService or {}

local Service = KIPN.Server.POBoxService
local ADMIN_MODULE_NAME = "KIPN_POBoxAdmin"
local KEY_MODULE_NAME = "KIPN_POBox"
local REGISTRY_VERSION = 2
local MAX_ADMIN_DISTANCE = 10

local VALID_SIZES = {
    small = true,
    medium = true,
    large = true,
}

local function log(message)
    print("[KIPN PO BOX SERVICE] " .. tostring(message))
end

local function logError(message)
    print("[KIPN PO BOX SERVICE] ERROR: " .. tostring(message))
end

local function save()
    return KIPN.Server.Save
        and KIPN.Server.Save("poBoxes")
        or false
end

local function getRegistry()
    local data = KIPN.Server.GetData
        and KIPN.Server.GetData()

    if type(data) ~= "table" then
        return nil
    end

    if type(data.poBoxes) ~= "table" then
        data.poBoxes = {}
    end

    local registry = data.poBoxes
    registry.version = REGISTRY_VERSION

    if type(registry.entries) ~= "table" then
        registry.entries = {}
    end

    if type(registry.nextNumberByZone) ~= "table" then
        registry.nextNumberByZone = {}
    end

    -- Migrate old registries and repair stale counters without ever
    -- moving a zone's sequence backwards. Once persisted, removing a
    -- box does not make its number available for reuse.
    for _, entry in pairs(registry.entries) do
        if type(entry) == "table" and entry.zoneId ~= nil then
            local zoneKey = tostring(entry.zoneId)
            local number = tonumber(entry.number)
            local nextNumber = tonumber(registry.nextNumberByZone[zoneKey])
                or 1

            if number and number >= nextNumber then
                registry.nextNumberByZone[zoneKey] = math.floor(number) + 1
            elseif registry.nextNumberByZone[zoneKey] == nil then
                registry.nextNumberByZone[zoneKey] = nextNumber
            end
        end
    end

    return registry
end

local function getSizeConfig(sizeKey)
    local sizes = KIPN.Server.POBoxConfig
        and KIPN.Server.POBoxConfig.Sizes
    local config = sizes and sizes[sizeKey]

    if type(config) ~= "table" then
        return nil
    end

    return config
end

function Service.GetSizeConfig(sizeKey)
    return getSizeConfig(sizeKey)
end

function Service.GetBox(boxId)
    local registry = getRegistry()

    if not registry or boxId == nil then
        return nil
    end

    return registry.entries[tostring(boxId)]
end

function Service.GetBoxesForZone(zoneId)
    local registry = getRegistry()
    local results = {}

    if not registry or zoneId == nil then
        return results
    end

    for _, entry in pairs(registry.entries) do
        if type(entry) == "table"
            and entry.active ~= false
            and tostring(entry.zoneId) == tostring(zoneId)
        then
            results[#results + 1] = entry
        end
    end

    table.sort(results, function(a, b)
        local an = tonumber(a.number) or 0
        local bn = tonumber(b.number) or 0
        if an == bn then
            return tostring(a.id) < tostring(b.id)
        end
        return an < bn
    end)

    return results
end

function Service.GetBoxAtZoneNumber(zoneId, boxNumber)
    local wantedNumber = tonumber(boxNumber)

    if not wantedNumber then
        return nil
    end

    for _, entry in ipairs(Service.GetBoxesForZone(zoneId)) do
        if tonumber(entry.number) == wantedNumber then
            return entry
        end
    end

    return nil
end

function Service.GetNextBoxNumber(zoneId)
    local registry = getRegistry()

    if not registry or zoneId == nil then
        return nil
    end

    local nextNumber = tonumber(
        registry.nextNumberByZone[tostring(zoneId)]
    ) or 1

    nextNumber = math.floor(nextNumber)

    if nextNumber < 1 or nextNumber > 999999 then
        return nil
    end

    return nextNumber
end

local function getPlayerPosition(player)
    if not player then return nil end

    local square = player.getSquare and player:getSquare()
    if not square then return nil end

    return {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
    }
end

function Service.GetPlayerPostOffice(player)
    local position = getPlayerPosition(player)
    local worldRegistry = KIPN.Server.WorldRegistry

    if not position
        or not worldRegistry
        or type(worldRegistry.GetZoneAtPosition) ~= "function"
    then
        return nil, nil
    end

    return worldRegistry.GetZoneAtPosition(
        position.x,
        position.y,
        position.z,
        worldRegistry.ZoneTypes.POST_OFFICE
    )
end

function Service.ResolvePurchasableBox(player, boxNumber)
    local zone, zoneId = Service.GetPlayerPostOffice(player)

    if not zone then
        return nil,
            "You must be inside an authorized post office to purchase a PO Box."
    end

    local entry = Service.GetBoxAtZoneNumber(zoneId, boxNumber)

    if not entry then
        return nil, "That PO Box is not registered at this post office."
    end

    if type(Service.FindWorldObject) == "function"
        and not Service.FindWorldObject(entry)
    then
        return nil, "That PO Box container is currently unavailable."
    end

    return entry, nil, zone, zoneId
end

function Service.GetPrice(entry)
    local config = entry and getSizeConfig(entry.size)
    local price = config and tonumber(config.Price)
    return price and math.floor(price) or nil
end

function Service.GetCapacity(entry)
    local config = entry and getSizeConfig(entry.size)
    local capacity = config and tonumber(config.Capacity)
    return capacity and math.floor(capacity) or nil
end

function Service.GetLabel(entry)
    local config = entry and getSizeConfig(entry.size)
    return config and config.Label or tostring(entry and entry.size or "Unknown")
end

local function isAdmin(player)
    local permissions = KIPN.Server.Permissions

    return player ~= nil
        and permissions ~= nil
        and type(permissions.ResolveAccessLevel) == "function"
        and permissions.ResolveAccessLevel(player) == "ADMIN"
end

local function getObjectModData(object)
    if not object or type(object.getModData) ~= "function" then
        return nil
    end

    local ok, modData = pcall(function()
        return object:getModData()
    end)

    return ok and modData or nil
end

local function findObjectOnSquare(square, boxId)
    if not square or type(square.getObjects) ~= "function" then
        return nil
    end

    local objects = square:getObjects()
    if not objects then return nil end

    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local modData = getObjectModData(object)

        if modData
            and tostring(modData.KIPNPOBoxRegistryId) == tostring(boxId)
        then
            return object
        end
    end

    return nil
end

function Service.FindWorldObject(entry)
    if type(entry) ~= "table" or type(getCell) ~= "function" then
        return nil
    end

    local square = getCell():getGridSquare(
        tonumber(entry.x),
        tonumber(entry.y),
        tonumber(entry.z)
    )

    return findObjectOnSquare(square, entry.id)
end

local function applyObjectPolicy(object, entry)
    if not object or not entry then return false end

    local capacity = Service.GetCapacity(entry)
    local container = object.getContainer and object:getContainer()

    if not container and type(object.setIsContainer) == "function" then
        object:setIsContainer(true)
        container = object:getContainer()
    end

    if not container then
        return false
    end

    container:setType("postbox")
    container:setExplored(true)

    if capacity then
        container:setCapacity(capacity)
    end

    local displayName = "PO Box #" .. tostring(entry.number)
        .. " (" .. Service.GetLabel(entry) .. ")"

    if type(object.setName) == "function" then
        object:setName(displayName)
    end

    if type(object.setIsDismantable) == "function" then
        object:setIsDismantable(false)
    end

    if type(object.setIsThumpable) == "function" then
        object:setIsThumpable(false)
    end

    if type(object.setCanBeLockByPadlock) == "function" then
        object:setCanBeLockByPadlock(true)
    end

    if type(object.setKeyId) == "function" then
        object:setKeyId(tonumber(entry.keyId))
    end

    -- Container access checks use IsoThumpable:isLockedToCharacter(),
    -- whose standard keyed-container path is the padlock state.
    if type(object.setLockedByPadlock) == "function" then
        object:setLockedByPadlock(true)
    end

    if type(object.setLockedByKey) == "function" then
        object:setLockedByKey(true)
    end

    if type(object.setCanBeLockByPadlock) == "function" then
        -- The service owns this permanent lock; players may use its
        -- key but may not replace/remove it with the padlock action.
        object:setCanBeLockByPadlock(false)
    end

    local modData = getObjectModData(object)
    if modData then
        modData.KIPNPOBoxRegistryId = tostring(entry.id)
        modData.KIPNPOBoxNumber = tonumber(entry.number)
        modData.KIPNPOBoxSize = tostring(entry.size)
        modData.KIPNPOBoxZoneId = tostring(entry.zoneId)
        modData.KIPNProtectedMoveable = true
        modData.postbox_customContainerName = displayName
    end

    return true
end

function Service.ApplyObjectPolicy(entry, transmit)
    local object = Service.FindWorldObject(entry)

    if not object or not applyObjectPolicy(object, entry) then
        return false
    end

    if transmit and type(object.transmitCompleteItemToClients) == "function" then
        object:transmitCompleteItemToClients()
    end

    return true
end

local function keyIdInUse(registry, keyId, exceptId)
    for id, entry in pairs(registry.entries) do
        if tostring(id) ~= tostring(exceptId)
            and tonumber(entry.keyId) == tonumber(keyId)
        then
            return true
        end
    end
    return false
end

local function generateKeyId(registry, exceptId, forbiddenKeyId)
    local keyId

    repeat
        if type(ZombRand) == "function" then
            keyId = ZombRand(100000, 2000000000)
        else
            keyId = math.random(100000, 2000000000)
        end
    until tonumber(keyId) ~= tonumber(forbiddenKeyId)
        and not keyIdInUse(registry, keyId, exceptId)

    return keyId
end

local function makeBoxId(zoneId, boxNumber)
    local base = "pobox_" .. tostring(zoneId) .. "_" .. tostring(boxNumber)
    return base:gsub("[^%w_%-]", "_")
end

local function createWorldObject(square, entry)
    local config = getSizeConfig(entry.size)
    local sprite = config and config.Sprite

    if not sprite or not IsoThumpable then
        return nil, "PO Box sprite or IsoThumpable API is unavailable."
    end

    local object = IsoThumpable.new(
        getCell(),
        square,
        sprite,
        false,
        {}
    )

    if not object or not applyObjectPolicy(object, entry) then
        return nil, "Unable to initialize PO Box container."
    end

    square:AddSpecialObject(object)

    if type(object.transmitCompleteItemToClients) == "function" then
        object:transmitCompleteItemToClients()
    end

    triggerEvent("OnObjectAdded", object)
    return object
end

function Service.CreateBox(player, args)
    if not isAdmin(player) then
        return nil, "NOT_AUTHORIZED"
    end

    args = type(args) == "table" and args or {}

    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local z = tonumber(args.z)
    local sizeKey = tostring(args.size or ""):lower()

    if not x or not y or not z
        or x ~= math.floor(x)
        or y ~= math.floor(y)
        or z ~= math.floor(z)
    then
        return nil, "INVALID_SQUARE"
    end

    if not VALID_SIZES[sizeKey] or not getSizeConfig(sizeKey) then
        return nil, "INVALID_SIZE"
    end

    local playerPosition = getPlayerPosition(player)
    if not playerPosition
        or playerPosition.z ~= z
        or math.abs(playerPosition.x - x) > MAX_ADMIN_DISTANCE
        or math.abs(playerPosition.y - y) > MAX_ADMIN_DISTANCE
    then
        return nil, "TARGET_TOO_FAR"
    end

    local playerZone, playerZoneId = Service.GetPlayerPostOffice(player)
    if not playerZone then
        return nil, "POST_OFFICE_ZONE_REQUIRED"
    end

    local worldRegistry = KIPN.Server.WorldRegistry
    local zone, zoneId = worldRegistry.GetZoneAtPosition(
        x, y, z, worldRegistry.ZoneTypes.POST_OFFICE
    )

    if not zone or tostring(zoneId) ~= tostring(playerZoneId) then
        return nil, "POST_OFFICE_ZONE_REQUIRED"
    end

    local registry = getRegistry()
    if not registry then
        return nil, "REGISTRY_UNAVAILABLE"
    end

    local boxNumber = Service.GetNextBoxNumber(zoneId)
    if not boxNumber then
        return nil, "BOX_NUMBER_LIMIT_REACHED"
    end

    if Service.GetBoxAtZoneNumber(zoneId, boxNumber) then
        return nil, "BOX_NUMBER_ALREADY_REGISTERED"
    end

    local square = getCell():getGridSquare(x, y, z)
    if not square then
        return nil, "SQUARE_NOT_LOADED"
    end

    local boxId = makeBoxId(zoneId, boxNumber)
    if registry.entries[boxId] then
        return nil, "BOX_ID_ALREADY_REGISTERED"
    end

    if findObjectOnSquare(square, boxId) then
        return nil, "BOX_ALREADY_EXISTS_ON_SQUARE"
    end

    for _, existing in pairs(registry.entries) do
        if existing.active ~= false
            and tonumber(existing.x) == x
            and tonumber(existing.y) == y
            and tonumber(existing.z) == z
        then
            return nil, "SQUARE_ALREADY_HAS_PO_BOX"
        end
    end

    local entry = {
        id = boxId,
        number = math.floor(boxNumber),
        size = sizeKey,
        zoneId = tostring(zoneId),
        x = math.floor(x),
        y = math.floor(y),
        z = math.floor(z),
        keyId = generateKeyId(registry),
        active = true,
        createdBy = player.getUsername and player:getUsername() or "admin",
        createdAt = os.time(),
    }

    local object, objectReason = createWorldObject(square, entry)
    if not object then
        return nil, objectReason
    end

    local zoneKey = tostring(zoneId)
    local previousNextNumber = registry.nextNumberByZone[zoneKey]

    registry.entries[entry.id] = entry
    registry.nextNumberByZone[zoneKey] = boxNumber + 1

    if not save() then
        registry.entries[entry.id] = nil
        registry.nextNumberByZone[zoneKey] = previousNextNumber

        if type(square.transmitRemoveItemFromSquareOnClients) == "function" then
            square:transmitRemoveItemFromSquareOnClients(object)
        end
        square:RemoveTileObject(object)

        return nil, "REGISTRY_SAVE_FAILED"
    end

    log("Created " .. sizeKey .. " PO Box #" .. tostring(entry.number)
        .. " at " .. x .. "," .. y .. "," .. z)

    return entry
end

function Service.RotateKey(boxId)
    local registry = getRegistry()
    local entry = registry and registry.entries[tostring(boxId)]

    if not entry then
        return false, "PO_BOX_NOT_FOUND"
    end

    local previousKeyId = entry.keyId
    entry.keyId = generateKeyId(
        registry,
        entry.id,
        previousKeyId
    )

    if not save() then
        entry.keyId = previousKeyId
        return false, "PO_BOX_REKEY_SAVE_FAILED"
    end

    -- A loaded box must accept the new lock immediately. Unloaded
    -- boxes are updated by LoadGridsquare when their square streams in.
    local object = Service.FindWorldObject(entry)
    if object and not Service.ApplyObjectPolicy(entry, true) then
        entry.keyId = previousKeyId
        save()
        Service.ApplyObjectPolicy(entry, true)
        return false, "PO_BOX_REKEY_APPLY_FAILED"
    end

    return true
end

local function generateKeySerial(entry)
    local randomA
    local randomB

    if type(ZombRand) == "function" then
        randomA = ZombRand(100000, 2000000000)
        randomB = ZombRand(100000, 2000000000)
    else
        randomA = math.random(100000, 2000000000)
        randomB = math.random(100000, 2000000000)
    end

    return table.concat({
        tostring(entry.id),
        tostring(entry.keyId),
        tostring(os.time()),
        tostring(randomA),
        tostring(randomB),
    }, ":")
end

function Service.AssignKeyItem(keyItem, entry, keySerial)
    if not keyItem or not entry then return false end

    if type(keyItem.setKeyId) == "function" then
        keyItem:setKeyId(tonumber(entry.keyId))
    else
        return false
    end

    local modData = keyItem.getModData and keyItem:getModData()
    if not modData then return false end

    modData.KIPNPOBoxId = tostring(entry.id)
    modData.KIPNPOBoxNumber = tonumber(entry.number)
    modData.KIPNPOBoxSize = tostring(entry.size)
    modData.KIPNPOBoxZoneId = tostring(entry.zoneId)
    modData.KIPNPOBoxKeySerial = tostring(
        keySerial or generateKeySerial(entry)
    )

    if type(keyItem.setName) == "function" then
        keyItem:setName("PO Box #" .. tostring(entry.number) .. " Key")
    end

    if type(keyItem.setCustomName) == "function" then
        keyItem:setCustomName(true)
    end

    return true, modData.KIPNPOBoxKeySerial
end

local function containerHasKeySerial(container, wantedSerial)
    if not container or type(container.getItems) ~= "function" then
        return false
    end

    local items = container:getItems()
    if not items then return false end

    for index = 0, items:size() - 1 do
        local item = items:get(index)
        local modData = item
            and item.getModData
            and item:getModData()

        if modData
            and tostring(modData.KIPNPOBoxKeySerial or "")
                == tostring(wantedSerial)
        then
            return true
        end

        if item and type(item.getInventory) == "function" then
            local ok, nested = pcall(function()
                return item:getInventory()
            end)

            if ok and nested
                and containerHasKeySerial(nested, wantedSerial)
            then
                return true
            end
        end
    end

    return false
end

local function keyExistsInOnlineInventory(keySerial)
    if type(getOnlinePlayers) ~= "function" then return false end

    local players = getOnlinePlayers()
    if not players then return false end

    for index = 0, players:size() - 1 do
        local player = players:get(index)
        local inventory = player
            and player.getInventory
            and player:getInventory()

        if containerHasKeySerial(inventory, keySerial) then
            return true
        end
    end

    return false
end

function Service.ReleaseForRemovedKey(player, args)
    args = type(args) == "table" and args or {}

    local boxId = args.boxId and tostring(args.boxId)
    local keySerial = args.keySerial and tostring(args.keySerial)

    if not boxId or boxId == "" or not keySerial or keySerial == "" then
        return false, "INVALID_KEY_IDENTITY"
    end

    local claims = KIPN.Server.ClaimService
    if not claims
        or type(claims.GetClaimForTarget) ~= "function"
        or type(claims.ReleaseClaim) ~= "function"
    then
        return false, "CLAIM_SERVICE_UNAVAILABLE"
    end

    local claimType = claims.Types
        and claims.Types.PO_BOX
        or "po_box"
    local claim = claims.GetClaimForTarget(claimType, boxId)

    if not claim or claim.active == false then
        -- Duplicate removal reports are harmless after the first one
        -- has already made the box available.
        return true, "ALREADY_AVAILABLE"
    end

    local authorizedSerial =
        tostring(claim.poBoxKeySerial or "") == keySerial
        or (
            type(claim.poBoxKeySerials) == "table"
            and claim.poBoxKeySerials[keySerial] == true
        )

    if not authorizedSerial then
        return false, "KEY_IDENTITY_MISMATCH"
    end

    -- A transfer to another online player is not deletion. This
    -- authoritative scan prevents the reporting client from releasing
    -- a box while the tracked key still exists in any live inventory.
    if keyExistsInOnlineInventory(keySerial) then
        return false, "KEY_STILL_EXISTS"
    end

    local released, releaseReason = claims.ReleaseClaim(
        claim.id,
        "po_box_key_removed"
    )

    if not released then
        return false, releaseReason or "CLAIM_RELEASE_FAILED"
    end

    log(
        "Released PO Box #" .. tostring(claim.boxNumber or boxId) ..
        " after its ownership key left the world" ..
        (player and player.getUsername
            and " (reported by " .. tostring(player:getUsername()) .. ")"
            or "")
    )

    return true
end

function Service.DeleteBox(player, args)
    if not isAdmin(player) then
        return false, "NOT_AUTHORIZED"
    end

    local boxId = type(args) == "table" and args.boxId
    local registry = getRegistry()
    local entry = registry and registry.entries[tostring(boxId)]

    if not entry then
        return false, "PO_BOX_NOT_FOUND"
    end

    local playerPosition = getPlayerPosition(player)
    if not playerPosition
        or playerPosition.z ~= tonumber(entry.z)
        or math.abs(playerPosition.x - tonumber(entry.x)) > MAX_ADMIN_DISTANCE
        or math.abs(playerPosition.y - tonumber(entry.y)) > MAX_ADMIN_DISTANCE
    then
        return false, "TARGET_TOO_FAR"
    end

    local claims = KIPN.Server.ClaimService
    if claims and type(claims.GetClaimForTarget) == "function"
        and claims.GetClaimForTarget("po_box", entry.id)
    then
        return false, "PO_BOX_IS_OWNED"
    end

    local object = Service.FindWorldObject(entry)
    local container = object and object.getContainer and object:getContainer()
    if container and container:getItems() and container:getItems():size() > 0 then
        return false, "PO_BOX_NOT_EMPTY"
    end

    registry.entries[entry.id] = nil
    if not save() then
        registry.entries[entry.id] = entry
        return false, "REGISTRY_SAVE_FAILED"
    end

    if object then
        local square = object:getSquare()
        if square then
            if type(square.transmitRemoveItemFromSquareOnClients) == "function" then
                square:transmitRemoveItemFromSquareOnClients(object)
            end
            square:RemoveTileObject(object)
        end
    end

    return true
end

local function sendResult(player, command, success, reason, entry)
    sendServerCommand(player, ADMIN_MODULE_NAME, command, {
        success = success,
        reason = reason,
        boxId = entry and entry.id or nil,
        boxNumber = entry and entry.number or nil,
        size = entry and entry.size or nil,
    })
end

local function onClientCommand(module, command, player, args)
    if module == KEY_MODULE_NAME and command == "KeyRemoved" then
        local success, reason = Service.ReleaseForRemovedKey(player, args)
        sendServerCommand(player, KEY_MODULE_NAME, "KeyRemovedResult", {
            success = success,
            reason = reason,
            boxId = type(args) == "table" and args.boxId or nil,
        })
        return
    end

    if module ~= ADMIN_MODULE_NAME then return end

    if command == "CreateBox" then
        local entry, reason = Service.CreateBox(player, args)
        sendResult(player, "CreateBoxResult", entry ~= nil, reason, entry)
    elseif command == "DeleteBox" then
        local entry = type(args) == "table" and Service.GetBox(args.boxId)
        local success, reason = Service.DeleteBox(player, args)
        sendResult(player, "DeleteBoxResult", success, reason, entry)
    end
end

local function onLoadGridSquare(square)
    if not square or type(square.getObjects) ~= "function" then return end

    local objects = square:getObjects()
    if not objects then return end

    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local modData = getObjectModData(object)
        local boxId = modData and modData.KIPNPOBoxRegistryId
        local entry = boxId and Service.GetBox(boxId)

        if entry and entry.active ~= false then
            applyObjectPolicy(object, entry)
        end
    end
end

function Service.Initialize()
    if Service._initialized then return true end

    if not getRegistry() then
        logError("Persistent registry is unavailable.")
        return false
    end

    Events.OnClientCommand.Add(onClientCommand)

    if Events.LoadGridsquare then
        Events.LoadGridsquare.Add(onLoadGridSquare)
    end

    Service._initialized = true
    log("Initialized.")
    return true
end

log("Module loaded.")
