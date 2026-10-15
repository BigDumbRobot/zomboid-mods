-- KIPN_EventEscrowService.lua
--
-- Phase 2 of the Event Scenarios architecture rewrite: the inventory
-- escrow foundation for the Naked and Afraid modifier (see
-- KIPN_EventModeRegistry.lua's compatibility matrix, added in Phase
-- 1). Strips a participant's full inventory to nothing at accept
-- time and restores it later -- at normal event end, cancellation, or
-- restart/reconnect recovery.
--
-- PERSISTENCE: escrow records live in their own top-level ModData
-- table (data.eventEscrows, keyed by username), completely
-- independent of Event Definitions -- so deleting, resetting, or
-- losing an Event Definition can never destroy a pending escrow, per
-- the Naked and Afraid modifier contract. This mirrors
-- KIPN_EventScenarioService.lua's getDefinitionCollection() lazy-init
-- idiom, just for a different top-level key.
--
-- TWO-TIER RESTORE: removed items are kept as live Lua object
-- references in a session-local table (liveItemRefs) for
-- perfect-fidelity restoration (condition/uses/etc. all intact,
-- because the original item object is handed straight back) as long
-- as the server hasn't restarted since CreateEscrow(). Live object
-- references cannot survive a restart, so the persisted record also
-- keeps a plain itemFullType list as a restart-safe fallback --
-- restoring from it recreates fresh items via
-- KIPN.Server.CreateItem(fullType), which does NOT preserve
-- condition/uses/wetness/etc. This lower-fidelity fallback path is a
-- known, documented limitation of this foundation phase, not an
-- oversight.
--
-- Removal/add/sync idiom (Remove + sendRemoveItemFromContainer,
-- AddItem + sendAddItemToContainer, ground-drop via
-- square:AddWorldInventoryItem as a last resort) is copied verbatim
-- from KIPN_ArtifactService.lua's proven consume-item/giveItemToPlayer
-- functions -- nothing here is a new/unverified PZ API.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventEscrowService = KIPN.Server.EventEscrowService or {}

local EscrowService = KIPN.Server.EventEscrowService

-- Session-local only -- see file header. Never persisted, never
-- read/written outside this file.
local liveItemRefs = {}

local function log(message)
    print("[KIPN EVENT ESCROW] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT ESCROW] ERROR: " .. tostring(message))
end

local function getEscrowCollection()
    if not KIPN.Server.GetData then
        logError("KIPN.Server.GetData() is unavailable.")
        return nil
    end

    local data = KIPN.Server.GetData()

    if not data then
        logError("KIPN data unavailable.")
        return nil
    end

    if type(data.eventEscrows) ~= "table" then
        data.eventEscrows = {}
    end

    return data.eventEscrows
end

------------------------------------------------------------
-- QUERIES
------------------------------------------------------------

function EscrowService.HasPendingEscrow(username)
    local collection = getEscrowCollection()
    return username ~= nil and collection ~= nil and collection[username] ~= nil
end

function EscrowService.GetPendingEscrow(username)
    local collection = getEscrowCollection()
    return username and collection and collection[username]
end

-- For future admin-facing surfacing (per the modifier contract's
-- "clearly surface pending restoration to admins and logs" -- logging
-- is covered by this file's log()/logError() calls; a dedicated UI
-- surface is Phase 5's concern, this is its data source).
function EscrowService.ListPendingEscrows()
    local result = {}
    local collection = getEscrowCollection()

    if not collection then
        return result
    end

    for username, record in pairs(collection) do
        result[#result + 1] = {
            username = username,
            definitionId = record.definitionId,
            instanceId = record.instanceId,
            capturedAtMs = record.capturedAtMs,
            itemCount = #(record.itemFullTypes or {}),
        }
    end

    return result
end

------------------------------------------------------------
-- CREATE ESCROW (strip)
------------------------------------------------------------

function EscrowService.CreateEscrow(player, definitionId, instanceId)
    local username = player and player:getUsername()

    if not username then
        return false, "NO_PLAYER"
    end

    if EscrowService.HasPendingEscrow(username) then
        return false, "ESCROW_ALREADY_PENDING"
    end

    local inventory = player:getInventory()

    if not inventory then
        return false, "NO_INVENTORY"
    end

    -- Snapshot into a plain Lua array first -- removing items while
    -- iterating the live Java ArrayList getItems() returns is unsafe.
    local snapshot = {}
    local itemsOk, items = pcall(function() return inventory:getItems() end)

    if itemsOk and items then
        for i = 0, items:size() - 1 do
            snapshot[#snapshot + 1] = items:get(i)
        end
    end

    local itemFullTypes = {}
    local liveRefs = {}

    for _, item in ipairs(snapshot) do
        local fullTypeOk, fullType = pcall(function() return item:getFullType() end)

        local removedOk = pcall(function()
            if type(player.removeFromHands) == "function" then
                player:removeFromHands(item)
            end
            inventory:Remove(item)
            if type(sendRemoveItemFromContainer) == "function" then
                sendRemoveItemFromContainer(inventory, item)
            end
        end)

        if removedOk then
            liveRefs[#liveRefs + 1] = item
            if fullTypeOk and fullType then
                itemFullTypes[#itemFullTypes + 1] = fullType
            end
        else
            logError("CreateEscrow(): failed to remove an item from " .. username .. "'s inventory; leaving it in place.")
        end
    end

    liveItemRefs[username] = liveRefs

    local collection = getEscrowCollection()

    if not collection then
        return false, "STORAGE_UNAVAILABLE"
    end

    collection[username] = {
        definitionId = definitionId,
        instanceId = instanceId,
        capturedAtMs = (type(getTimestampMs) == "function" and getTimestampMs()) or 0,
        itemFullTypes = itemFullTypes,
    }

    KIPN.Server.Save()

    log("CreateEscrow() -> escrowed " .. tostring(#liveRefs) .. " item(s) for " .. username .. " (event " .. tostring(definitionId) .. ")")

    return true
end

------------------------------------------------------------
-- RESTORE ESCROW
------------------------------------------------------------
--
-- Idempotent: no pending record -> true (nothing to do, no
-- duplication risk). A dead player defers without clearing anything.
-- A partial failure (an item that can neither return to inventory nor
-- be dropped on the ground -- no valid square, most likely) keeps
-- only the still-pending items in the persisted record rather than
-- either losing them or replaying the ones that already succeeded.
------------------------------------------------------------

function EscrowService.RestoreEscrow(player)
    local username = player and player:getUsername()

    if not username then
        return false, "NO_PLAYER"
    end

    local collection = getEscrowCollection()
    local record = collection and collection[username]

    if not record then
        return true
    end

    local isDeadOk, isDead = pcall(function() return player:isDead() end)

    if isDeadOk and isDead then
        log("RestoreEscrow() deferred for " .. username .. ": character is dead. Will retry at the next lifecycle point.")
        return false, "PLAYER_DEAD"
    end

    local inventory = player:getInventory()
    local square = type(player.getSquare) == "function" and player:getSquare()
    local liveRefs = liveItemRefs[username]
    local remainingFullTypes = {}
    local restoredCount = 0

    local function restoreOneItem(item)
        if not item then
            return false
        end

        local addedOk, added = pcall(function() return inventory:AddItem(item) end)

        if addedOk and added then
            if type(sendAddItemToContainer) == "function" then
                pcall(sendAddItemToContainer, inventory, added)
            end
            return true
        end

        if square then
            local droppedOk = pcall(function() square:AddWorldInventoryItem(item, 0, 0, 0) end)
            if droppedOk then
                return true
            end
        end

        return false
    end

    if liveRefs then
        -- Fast path: same server session as CreateEscrow(). Perfect
        -- fidelity -- the exact original item objects are handed back.
        for _, item in ipairs(liveRefs) do
            if restoreOneItem(item) then
                restoredCount = restoredCount + 1
            else
                local fullTypeOk, fullType = pcall(function() return item:getFullType() end)
                if fullTypeOk and fullType then
                    remainingFullTypes[#remainingFullTypes + 1] = fullType
                end
            end
        end
    else
        -- Restart-safe fallback: recreate fresh items from the
        -- persisted fullType list. See file header -- condition/uses
        -- are NOT preserved on this path.
        for _, fullType in ipairs(record.itemFullTypes or {}) do
            local item = KIPN.Server.CreateItem(fullType)

            if item and restoreOneItem(item) then
                restoredCount = restoredCount + 1
            else
                remainingFullTypes[#remainingFullTypes + 1] = fullType
            end
        end
    end

    -- Whatever path was taken, any live references for this username
    -- are now stale (restored items were handed off; failed ones will
    -- be recreated fresh from itemFullTypes on the next attempt).
    liveItemRefs[username] = nil

    if #remainingFullTypes > 0 then
        record.itemFullTypes = remainingFullTypes
        KIPN.Server.Save()
        logError("RestoreEscrow() partially failed for " .. username .. ": " .. tostring(#remainingFullTypes) .. " item(s) still pending (restored " .. tostring(restoredCount) .. ").")
        return false, "PARTIAL_RESTORE"
    end

    collection[username] = nil
    KIPN.Server.Save()

    log("RestoreEscrow() -> fully restored " .. tostring(restoredCount) .. " item(s) for " .. username)

    return true
end

function EscrowService.Initialize()
    local pending = EscrowService.ListPendingEscrows()

    if #pending > 0 then
        log("Initialize() -> " .. tostring(#pending) .. " pending escrow(s) survived restart; will restore each as its player is next seen online and alive.")
    end

    return true
end

log("module loaded")
