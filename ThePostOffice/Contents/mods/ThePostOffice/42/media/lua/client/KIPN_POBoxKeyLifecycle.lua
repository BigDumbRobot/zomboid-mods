-- KIPN_POBoxKeyLifecycle.lua
--
-- Detects when an issued PO Box key is deliberately deleted instead
-- of transferred, stored, or dropped. The server verifies the key's
-- private lifecycle serial before releasing ownership and rekeying the
-- physical container.

if isServer() then return end

require "ISUI/ISInventoryPane"

local MODULE_NAME = "KIPN_POBox"
local KEY_ITEM_TYPE = "Base.KIPNPOBoxKey"
local REMOVAL_SETTLE_MS = 1000
local INVENTORY_SCAN_MS = 2000
local pending = {}
local watched = {}
local nextInventoryScan = 0

local function getRuntimeMs()
    if type(getTimestampMs) ~= "function" then return 0 end

    local ok, value = pcall(getTimestampMs)
    return ok and tonumber(value) or 0
end

local function getKeyIdentity(item)
    if not item or type(item.getFullType) ~= "function" then
        return nil
    end

    local ok, fullType = pcall(function()
        return item:getFullType()
    end)

    if not ok or tostring(fullType) ~= KEY_ITEM_TYPE then
        return nil
    end

    local modDataOk, modData = pcall(function()
        return item:getModData()
    end)

    if not modDataOk or not modData then return nil end

    local boxId = modData.KIPNPOBoxId
    local keySerial = modData.KIPNPOBoxKeySerial
    if not boxId or not keySerial then return nil end

    local itemId
    if type(item.getID) == "function" then
        local idOk, value = pcall(function()
            return item:getID()
        end)
        if idOk and value ~= nil then itemId = tostring(value) end
    end

    return {
        boxId = tostring(boxId),
        keySerial = tostring(keySerial),
        itemId = itemId,
    }
end

local function reportRemovedKey(identity)
    if not identity then return end

    pending[identity.keySerial] = nil
    watched[identity.keySerial] = nil

    sendClientCommand(MODULE_NAME, "KeyRemoved", {
        boxId = identity.boxId,
        keySerial = identity.keySerial,
        itemId = identity.itemId,
    })
end

local function itemStillExists(item)
    if not item then return false end

    local containerOk, container = pcall(function()
        return item:getContainer()
    end)

    if containerOk and container then return true end

    local worldOk, worldItem = pcall(function()
        return item:getWorldItem()
    end)

    if worldOk and worldItem then
        local squareOk, square = pcall(function()
            return worldItem:getSquare()
        end)
        if squareOk and square then return true end
    end

    return false
end

local function scheduleRemovalCheck(item)
    local identity = getKeyIdentity(item)
    if not identity then return end

    pending[identity.keySerial] = {
        item = item,
        identity = identity,
        checkAt = getRuntimeMs() + REMOVAL_SETTLE_MS,
    }
end

-- Every normal inventory deletion/transfer path calls this network
-- helper. Waiting one second distinguishes deletion from a transfer:
-- transferred and dropped items have acquired a new container or
-- IsoWorldInventoryObject by then.
if type(sendRemoveItemFromContainer) == "function"
    and not _G.KIPN_POBoxOriginalSendRemoveItem
then
    _G.KIPN_POBoxOriginalSendRemoveItem = sendRemoveItemFromContainer

    function sendRemoveItemFromContainer(container, item)
        local result = _G.KIPN_POBoxOriginalSendRemoveItem(container, item)
        scheduleRemovalCheck(item)
        return result
    end
end

local function inspectContainer(container, callback)
    if not container or type(container.getItems) ~= "function" then return end

    local items = container:getItems()
    if not items then return end

    for index = 0, items:size() - 1 do
        local item = items:get(index)
        local identity = getKeyIdentity(item)
        if identity then callback(identity, item) end

        if item and type(item.getInventory) == "function" then
            local ok, nested = pcall(function()
                return item:getInventory()
            end)
            if ok and nested then inspectContainer(nested, callback) end
        end
    end
end

local function getItemLocation(item)
    local ok, square = pcall(function()
        local worldItem = item:getWorldItem()
        if worldItem and worldItem:getSquare() then
            return worldItem:getSquare()
        end

        local container = item:getContainer()
        local parent = container and container:getParent()

        if parent
            and type(parent.getInventory) == "function"
            and parent:getInventory() == container
        then
            -- Character inventories stay live independently of chunk
            -- streaming, so no square guard is needed for them.
            return nil
        end

        if container and container:getSourceGrid() then
            return container:getSourceGrid()
        end

        return parent and parent.getSquare and parent:getSquare() or nil
    end)

    if not ok or not square then return nil end

    return {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
    }
end

local function watchKey(identity, item)
    watched[identity.keySerial] = {
        item = item,
        identity = identity,
        location = getItemLocation(item),
    }
end

local function lastLocationIsLoaded(record)
    local location = record and record.location
    if not location then return true end
    if type(getCell) ~= "function" then return false end

    local cell = getCell()
    return cell
        and cell:getGridSquare(location.x, location.y, location.z) ~= nil
end

local function watchWorldObject(object)
    if not object then return end

    if type(object.getItem) == "function" then
        local ok, item = pcall(function()
            return object:getItem()
        end)
        local identity = ok and getKeyIdentity(item)
        if identity then watchKey(identity, item) end
    end

    if type(object.getContainerCount) == "function"
        and type(object.getContainerByIndex) == "function"
    then
        for index = 0, object:getContainerCount() - 1 do
            inspectContainer(object:getContainerByIndex(index), watchKey)
        end
    elseif type(object.getContainer) == "function" then
        local ok, container = pcall(function()
            return object:getContainer()
        end)
        if ok and container then inspectContainer(container, watchKey) end
    end
end

local function onLoadGridSquare(square)
    if not square or type(square.getObjects) ~= "function" then return end

    local objects = square:getObjects()
    if not objects then return end

    for index = 0, objects:size() - 1 do
        watchWorldObject(objects:get(index))
    end
end

-- Empty Trash is a server command that bypasses the normal per-item
-- client removal helper. Notify KIPN first while the selected trash
-- container and every nested key are still available for inspection.
if ISInventoryPane
    and type(ISInventoryPane.onConfirmDelete) == "function"
    and not ISInventoryPane._KIPNPOBoxDeleteWrapped
then
    ISInventoryPane._KIPNPOBoxDeleteWrapped = true
    local originalConfirmDelete = ISInventoryPane.onConfirmDelete

    function ISInventoryPane:onConfirmDelete(button)
        if button and button.internal == "YES" then
            inspectContainer(self.inventory, reportRemovedKey)
        end

        return originalConfirmDelete(self, button)
    end
end

local function onTick()
    local now = getRuntimeMs()

    if now >= nextInventoryScan then
        nextInventoryScan = now + INVENTORY_SCAN_MS

        local player = getSpecificPlayer(0)
        local inventory = player and player:getInventory()
        inspectContainer(inventory, watchKey)
    end

    for serial, record in pairs(pending) do
        if now >= record.checkAt then
            pending[serial] = nil

            if not itemStillExists(record.item) then
                watched[serial] = nil
                reportRemovedKey(record.identity)
            end
        end
    end

    -- Also catches removals initiated entirely by the server, such as
    -- the remote admin inventory manager, which never invokes the
    -- local sendRemoveItemFromContainer helper.
    for serial, record in pairs(watched) do
        if not itemStillExists(record.item) then
            if not lastLocationIsLoaded(record) then
                record.missingSince = nil
            elseif not record.missingSince then
                record.missingSince = now
            elseif now >= record.missingSince + REMOVAL_SETTLE_MS then
                watched[serial] = nil
                pending[serial] = nil
                reportRemovedKey(record.identity)
            end
        else
            record.missingSince = nil
        end
    end
end

local function onServerCommand(module, command, args)
    if module ~= MODULE_NAME or command ~= "KeyRemovedResult" then return end

    local player = getSpecificPlayer(0)
    if not player or not args then return end

    if args.success and args.reason ~= "ALREADY_AVAILABLE" then
        player:setHaloNote("PO Box key removed; the box is available again.")
    elseif not args.success and args.reason ~= "KEY_STILL_EXISTS" then
        player:setHaloNote(
            "PO Box key removal could not be recorded: " ..
            tostring(args.reason or "UNKNOWN")
        )
    end
end

Events.OnTick.Add(onTick)
Events.OnServerCommand.Add(onServerCommand)

if Events.LoadGridsquare then
    Events.LoadGridsquare.Add(onLoadGridSquare)
end

if Events.OnContainerUpdate then
    Events.OnContainerUpdate.Add(watchWorldObject)
end

print("[KIPN] PO Box key lifecycle loaded")
