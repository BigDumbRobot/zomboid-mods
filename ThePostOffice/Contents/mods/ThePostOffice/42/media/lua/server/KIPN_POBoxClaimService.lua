-- KIPN_POBoxClaimService.lua
--
-- PO Box ownership claim logic for The Post Office. Carved out of KIP
-- Network Terminal's KIPN_ClaimService.lua / KIPN_ArtifactService.lua.
--
-- Terminal keeps the authoritative claim-record store, the quota and
-- capability checks, and the generic release lifecycle. THIS file owns
-- the PO Box target validation, the purchase transaction (payment,
-- Blank Key, issued ownership key), key copying, and the Postal
-- Services commands.
--
-- Namespace: KIPN.Server.POBoxClaimService (never ClaimService).

if isClient() and not isServer() then return end

require "KIPN_Shared"
require "KIPN_PostOfficeShared"
require "KIPN_Server"
require "KIPN_ClaimService"
require "KIPN_ArtifactService"
require "KIPN_POBoxConfig"
require "KIPN_POBoxService"
require "KIPN_MarketplaceService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.POBoxClaimService = KIPN.Server.POBoxClaimService or {}

local POBoxClaimService = KIPN.Server.POBoxClaimService

-- Terminal's claim service -- authoritative store + generic API.
local ClaimService = KIPN.Server.ClaimService

local CLAIM_TYPE = "po_box"

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local function log(message)
    print("[KIPN PO BOX CLAIM SERVICE] " .. tostring(message))
end

local function logError(message)
    print("[KIPN PO BOX CLAIM SERVICE] ERROR: " .. tostring(message))
end

if type(ClaimService) ~= "table"
    or type(ClaimService.RegisterClaimType) ~= "function"
then
    logError(
        "KIPN.Server.ClaimService is unavailable; PO Box claims are " ..
        "disabled. The Post Office requires KIP Network Terminal."
    )
    return
end

------------------------------------------------------------
-- GENERIC STORE / HELPER ALIASES  (Terminal owns these)
------------------------------------------------------------

local createClaimRecord = ClaimService.CreateClaimRecord
local removeClaimRecord = ClaimService.RemoveClaimRecord
local checkMaxClaimsForType = ClaimService.CheckMaxClaimsForType
local getPlayerSteamId = ClaimService.GetPlayerSteamId
local getPlayerPosition = ClaimService.GetPlayerPosition
local hasClaimCapability = ClaimService.HasClaimCapability
local getClaimData = ClaimService.GetClaimData

local function save()
    if type(KIPN.Server.Save) == "function" then
        local ok, result = pcall(KIPN.Server.Save, "claims")
        if not ok then
            logError("KIPN.Server.Save('claims') failed: " .. tostring(result))
            return false
        end
        return result ~= false
    end
    logError("KIPN.Server.Save() is unavailable.")
    return false
end

local function getArtifactService()
    return KIPN.Server.ArtifactService
end

local function getCurrencySettings()

    local currencyType = "Base.Money"
    local currencyValue = 1

    if KIPN.Server.Settings
        and type(KIPN.Server.Settings.Get) == "function"
    then
        local settingType = KIPN.Server.Settings.Get(
            "Marketplace", "MarketplaceCurrencyItemType", "Base.Money"
        )
        if type(settingType) == "string" and settingType ~= "" then
            currencyType = settingType
        end

        local settingValue = tonumber(KIPN.Server.Settings.Get(
            "Marketplace", "MarketplaceCurrencyItemValue", 1
        ))
        if settingValue and settingValue > 0 then
            currencyValue = math.floor(settingValue)
        end
    end

    return currencyType, currencyValue
end

------------------------------------------------------------
-- PO BOX PRICE
------------------------------------------------------------

local function getPOBoxPrice(boxEntry)

    local poBoxService =
        KIPN.Server.POBoxService

    if boxEntry
        and poBoxService
        and type(poBoxService.GetPrice) == "function"
    then

        local entryPrice =
            tonumber(poBoxService.GetPrice(boxEntry))

        if entryPrice and entryPrice > 0 then
            return math.floor(entryPrice)
        end
    end

    return nil

end

------------------------------------------------------------
-- FIND PLAYER PO BOX CLAIM ITEM
------------------------------------------------------------
--
-- The PO Box claim token ("blank key") is a plain bearer item --
-- unlike Vehicle/Property/Excavation claim artifacts, it has no
-- registration prerequisite and no server-tracked artifactId (see
-- KIPN_POBoxConfig.lua). Physical possession + correct item type is
-- sufficient, exactly like a mundane crafting material.
------------------------------------------------------------

local function findPlayerPOBoxClaimItem(player)

    if not player then
        return nil
    end

    local claimItemType =
        KIPN.Server.POBoxConfig
        and KIPN.Server.POBoxConfig.ClaimItemType

    if not claimItemType then

        logError(
            "findPlayerPOBoxClaimItem() FAILED: " ..
            "POBoxConfig.ClaimItemType unavailable."
        )

        return nil
    end

    local inventory =
        type(player.getInventory) == "function"
        and player:getInventory()

    if not inventory then
        return nil
    end

    return inventory:getFirstTypeRecurse(
        claimItemType
    )

end

------------------------------------------------------------
-- FIND PLAYER'S PO BOX KEY ITEMS
------------------------------------------------------------
--
-- Unlike claim artifacts (which are singular/consumed), a player may
-- legitimately carry multiple PO Box keys for multiple boxes, so this
-- returns ALL matching items, not just the first.
--
-- PO Box keys are not consumable bearer artifacts with an expiry
-- lifecycle, they are simple physical possession tokens. See
-- KIPN_POBoxService.lua for the registry this feeds.
------------------------------------------------------------

function POBoxClaimService.FindPlayerPOBoxKeyItems(player)

    local inventory =
        player
        and type(player.getInventory) == "function"
        and player:getInventory()

    if not inventory then
        return {}
    end

    local keyItemType =
        KIPN.Server.POBoxConfig
        and KIPN.Server.POBoxConfig.KeyItemType

    if not keyItemType then

        logError(
            "FindPlayerPOBoxKeyItems() FAILED: " ..
            "POBoxConfig.KeyItemType unavailable."
        )

        return {}
    end

    local results = {}

    local function scanContainer(container)
        if not container or type(container.getItems) ~= "function" then
            return
        end

        local items = container:getItems()
        if not items then return end

        for i = 0, items:size() - 1 do
            local item = items:get(i)

            if item
                and type(item.getFullType) == "function"
                and item:getFullType() == keyItemType
            then
                local modData = item.getModData and item:getModData()
                local boxId = modData and modData.KIPNPOBoxId

                if boxId then
                    results[#results + 1] = {
                        item = item,
                        boxId = tostring(boxId),
                    }
                end
            end

            if item and type(item.getInventory) == "function" then
                local ok, nested = pcall(item.getInventory, item)
                if ok and nested then
                    scanContainer(nested)
                end
            end
        end
    end

    scanContainer(inventory)

    return results

end

------------------------------------------------------------
-- EXACT INVENTORY ITEM MUTATION
--
-- PO Box checkout consumes and restores concrete item objects so a
-- nested Blank Key cannot be silently left behind. ItemContainer's
-- Remove() does not provide a useful success value, therefore the
-- authoritative contents are checked before and after mutation.
------------------------------------------------------------

local function containerHasExactItem(container, wantedItem)

    if not container
        or not wantedItem
        or type(container.getItems) ~= "function"
    then
        return nil
    end

    local ok, found = pcall(function()
        local items = container:getItems()
        if not items then
            return false
        end

        for i = 0, items:size() - 1 do
            if items:get(i) == wantedItem then
                return true
            end
        end

        return false
    end)

    -- found may legitimately be `false` (item confirmed absent), which
    -- `ok and found or nil` would collapse into `nil` -- indistinguishable
    -- from the pcall-failure case and fatal to callers that check for an
    -- explicit `false`. Return the real tri-state instead.
    if not ok then
        return nil
    end

    return found
end

local function getExactItemContainer(item, fallbackContainer)

    if item and type(item.getContainer) == "function" then
        local ok, container = pcall(item.getContainer, item)
        if ok and container then
            return container
        end
    end

    return fallbackContainer
end

local function removeExactInventoryItem(container, item)

    if containerHasExactItem(container, item) ~= true then
        return false
    end

    local ok = pcall(container.Remove, container, item)
    if not ok or containerHasExactItem(container, item) ~= false then
        return false
    end

    if type(sendRemoveItemFromContainer) == "function" then
        pcall(sendRemoveItemFromContainer, container, item)
    end

    return true
end

local function restoreExactInventoryItem(container, item)

    if not container or not item then
        return false
    end

    local ok, restored = pcall(container.AddItem, container, item)
    if not ok or not restored then
        return false
    end

    if type(sendAddItemToContainer) == "function" then
        pcall(sendAddItemToContainer, container, item)
    end

    return true
end

------------------------------------------------------------
-- VALIDATE PO BOX TARGET
------------------------------------------------------------
--
-- Resolves the player-chosen display number against the physical
-- PO Box registry for the Post Office Zone the player is currently
-- standing in. Ownership is indexed by the registry id, allowing
-- separate post offices to use their own human-friendly numbering.
------------------------------------------------------------

function POBoxClaimService.ValidatePOBoxTarget(
    player,
    boxNumber
)

    if not player then

        return false,
            "Player is required."

    end

    local boxNumberValue =
        tonumber(boxNumber)

    if not boxNumberValue
        or boxNumberValue ~= math.floor(boxNumberValue)
        or boxNumberValue < 1
        or boxNumberValue > 999999
    then

        return false,
            "Invalid PO Box number."

    end

    boxNumberValue =
        math.floor(boxNumberValue)

    --------------------------------------------------------
    -- Current physical location.
    --------------------------------------------------------

    local position =
        getPlayerPosition(
            player
        )

    if not position then

        return false,
            "Player location is unavailable."

    end

    --------------------------------------------------------
    -- Current world capability.
    --------------------------------------------------------

    local capable,
        capabilityReason =
        hasClaimCapability(
            position,
            CLAIM_TYPE
        )

    if not capable then

        return false,
            capabilityReason

    end

    local poBoxService = KIPN.Server.POBoxService

    if not poBoxService
        or type(poBoxService.ResolvePurchasableBox) ~= "function"
    then
        return false, "Physical PO Box service is unavailable."
    end

    local boxEntry,
        resolveReason,
        zone,
        zoneId =
        poBoxService.ResolvePurchasableBox(
            player,
            boxNumberValue
        )

    if not boxEntry then
        return false, resolveReason or "PO Box not found."
    end

    local existingClaim =
        ClaimService.GetClaimForTarget(
            CLAIM_TYPE,
            boxEntry.id
        )

    if existingClaim then
        return false, "This PO Box is already owned."
    end

    local price = getPOBoxPrice(boxEntry)

    if not price or price <= 0 then
        return false, "PO Box price is not configured."
    end

    return true,
        nil,
        {

            boxNumber =
                boxNumberValue,

            registryId =
                tostring(boxEntry.id),

            boxEntry =
                boxEntry,

            size =
                boxEntry.size,

            capacity =
                poBoxService.GetCapacity(boxEntry),

            price =
                price,

            position =
                position,

            zone =
                zone,

            zoneId =
                zoneId,

        }

end

------------------------------------------------------------
-- CLAIM PO BOX
------------------------------------------------------------
--
-- Primary authoritative PO Box purchase operation. PO Box has no
-- ArtifactService-tracked claim artifact and no vanilla-safehouse-
-- style world record to create: instead this charges the player
-- through MarketplaceService, consumes the plain claim item, and
-- issues a real KIPNPOBoxKey bound to the registered container's
-- lock ID. Its ModData carries the physical registry ID and display
-- number (read back later by FindPlayerPOBoxKeyItems()).
--
-- The client ultimately calls this through the KIPN command router.
-- The server independently revalidates EVERYTHING.
------------------------------------------------------------

function POBoxClaimService.ClaimPOBox(
    player,
    boxNumber
)

    --------------------------------------------------------
    -- PLAYER
    --------------------------------------------------------

    local playerSteamId =
        getPlayerSteamId(
            player
        )

    if not playerSteamId then

        return false,
            "Player identity unavailable."

    end

    --------------------------------------------------------
    -- TARGET
    --------------------------------------------------------

    local targetValid,
        targetReason,
        targetData =
        POBoxClaimService.ValidatePOBoxTarget(
            player,
            boxNumber
        )

    if not targetValid then

        return false,
            targetReason

    end

    --------------------------------------------------------
    -- CLAIM ITEM (bearer, not yet consumed)
    --------------------------------------------------------

    local claimItem =
        findPlayerPOBoxClaimItem(
            player
        )

    if not claimItem then

        return false,
            "A Blank Key is required to purchase a PO Box."

    end

    --------------------------------------------------------
    -- MAX CLAIMS PER PLAYER
    --------------------------------------------------------

    local withinQuota,
        quotaReason =
        checkMaxClaimsForType(
            player,
            CLAIM_TYPE
        )

    if not withinQuota then

        return false,
            quotaReason

    end

    --------------------------------------------------------
    -- FINAL OWNERSHIP CHECK
    --------------------------------------------------------
    --
    -- Repeat immediately before mutation.
    --------------------------------------------------------

    if ClaimService.IsTargetClaimed(
        CLAIM_TYPE,
        targetData.registryId
    )
    then

        log(
            "ClaimPOBox() FAILED: box became claimed " ..
            "before ownership creation."
        )

        return false,
            "This PO Box is already owned."

    end

    --------------------------------------------------------
    -- CREATE AUTHORITATIVE OWNERSHIP RECORD
    --------------------------------------------------------

    local price =
        targetData.price

    local claimRecord,
        createReason =
        createClaimRecord(
            player,
            CLAIM_TYPE,
            targetData.registryId,
            targetData.zoneId,
            nil,
            targetData.position,
            {

                boxNumber =
                    targetData.boxNumber,

                poBoxRegistryId =
                    targetData.registryId,

                size =
                    targetData.size,

                capacity =
                    targetData.capacity,

                containerX =
                    targetData.boxEntry.x,

                containerY =
                    targetData.boxEntry.y,

                containerZ =
                    targetData.boxEntry.z,

                price =
                    price,

                purchasedAtRealTime =
                    os.time(),

            }
        )

    if not claimRecord then

        log(
            "ClaimPOBox() ownership creation failed: " ..
            tostring(createReason)
        )

        return false,
            createReason

    end

    --------------------------------------------------------
    -- SPEND + ISSUE (crash-safe)
    --------------------------------------------------------
    --
    -- Everything past this point mutates persistent state: the
    -- rotated container lock, the player's currency, the Blank Key,
    -- the issued ownership key and the persisted claim record. Each
    -- step rolls itself back on a graceful failure, but an
    -- unexpected Lua error (e.g. a missing engine API) would
    -- otherwise unwind the command handler and leave the ownership
    -- record orphaned -- the box permanently "owned" with nothing
    -- charged and no key issued. Run the remainder under pcall so
    -- any raise triggers the same teardown as a graceful failure.
    --------------------------------------------------------

    local completeOk, purchaseOk, purchaseResult = pcall(function()

    --------------------------------------------------------
    -- START A NEW PHYSICAL KEY GENERATION
    --------------------------------------------------------
    --
    -- Every successful owner must receive a newly keyed lock.
    -- This is deliberately done even though normal release also
    -- rotates the lock: it makes acquisition authoritative and
    -- invalidates every original/copy key left by a previous owner,
    -- including keys from legacy or interrupted ownership records.
    -- Rotate before charging so a rekey failure cannot cost the
    -- player currency or their Blank Key.
    --------------------------------------------------------

    local poBoxService =
        KIPN.Server.POBoxService

    local rekeyed,
        rekeyReason

    if poBoxService
        and type(poBoxService.RotateKey) == "function"
    then
        rekeyed,
            rekeyReason =
            poBoxService.RotateKey(
                targetData.registryId
            )
    end

    if not rekeyed then

        removeClaimRecord(
            claimRecord.id
        )

        logError(
            "ClaimPOBox() could not invalidate the previous " ..
            "owner's keys for box " ..
            tostring(targetData.registryId) ..
            ": " .. tostring(rekeyReason)
        )

        return false,
            "PO Box ownership lock could not be changed."

    end

    -- RotateKey mutates the authoritative registry entry. Refresh
    -- the reference used below before assigning the new owner's key.
    if type(poBoxService.GetBox) == "function" then
        targetData.boxEntry =
            poBoxService.GetBox(
                targetData.registryId
            ) or targetData.boxEntry
    end

    --------------------------------------------------------
    -- PREPARE THE OWNERSHIP KEY BEFORE SPENDING ANYTHING
    --------------------------------------------------------
    --
    -- The item is created and keyed while detached. It is not added
    -- to the player until both inventory currency and the Blank Key
    -- have been authoritatively removed.
    --------------------------------------------------------

    local inventory =
        type(player.getInventory) == "function"
        and player:getInventory()

    local keyItemType =
        KIPN.Server.POBoxConfig
        and KIPN.Server.POBoxConfig.KeyItemType

    if not inventory or not keyItemType then
        removeClaimRecord(claimRecord.id)
        return false,
            not inventory
                and "Player inventory is unavailable."
                or "PO Box key configuration is unavailable."
    end

    local keyItem = KIPN.Server.CreateItem(keyItemType)

    if not keyItem then
        removeClaimRecord(claimRecord.id)
        logError(
            "Unable to prepare PO Box key item before payment " ..
            "(item type " .. tostring(keyItemType) .. ")."
        )
        return false, "PO Box key could not be issued."
    end

    local keyAssigned,
        keySerial

    if poBoxService
        and type(poBoxService.AssignKeyItem) == "function"
    then
        keyAssigned,
            keySerial =
            poBoxService.AssignKeyItem(
                keyItem,
                targetData.boxEntry
            )
    end

    if not keyAssigned or not keySerial then
        removeClaimRecord(claimRecord.id)
        logError(
            "Unable to assign the physical PO Box lock id to the " ..
            "prepared key."
        )
        return false, "PO Box key could not be assigned."
    end

    --------------------------------------------------------
    -- REMOVE INVENTORY CURRENCY
    --------------------------------------------------------
    --
    -- A PO Box is bought in person at the counter: the price leaves
    -- the player's physical inventory (matching the confirmation
    -- dialog's wording). ChargeInventoryPurchase() never reaches for
    -- an external provider balance -- so a server whose configured
    -- marketplace provider mod is absent cannot fail this with a
    -- phantom INSUFFICIENT_BALANCE -- and it returns a receipt that
    -- RefundInventoryPurchase() below can actually reverse.
    --------------------------------------------------------

    local marketplace =
        KIPN.Server.MarketplaceService

    if not marketplace
        or type(marketplace.ChargeInventoryPurchase) ~= "function"
    then
        removeClaimRecord(claimRecord.id)
        logError(
            "MarketplaceService inventory purchase transaction is " ..
            "unavailable."
        )
        return false, "Marketplace service unavailable."
    end

    local charged,
        chargeReason,
        paymentReceipt =
        marketplace.ChargeInventoryPurchase(
            player,
            price,
            {
                [claimItem] = true,
            }
        )

    if not charged then
        removeClaimRecord(claimRecord.id)
        return false,
            (chargeReason == "INSUFFICIENT_INVENTORY_CURRENCY"
                or chargeReason == "INSUFFICIENT_CURRENCY")
                and "Insufficient currency in your inventory."
                or (chargeReason or "Payment could not be processed.")
    end

    --------------------------------------------------------
    -- REMOVE THE BLANK KEY
    --------------------------------------------------------

    local claimItemContainer =
        getExactItemContainer(claimItem, inventory)

    if not removeExactInventoryItem(claimItemContainer, claimItem) then
        local paymentRefunded =
            marketplace.RefundInventoryPurchase(paymentReceipt)

        removeClaimRecord(claimRecord.id)
        logError(
            "ClaimPOBox() could not remove the required Blank Key; " ..
            "payment refunded=" .. tostring(paymentRefunded) ..
            ". box=" .. tostring(targetData.registryId)
        )
        return false, "Blank Key could not be consumed."
    end

    --------------------------------------------------------
    -- ADD THE PREPARED PO BOX KEY
    --------------------------------------------------------

    local addKeyOk, addedKey =
        pcall(inventory.AddItem, inventory, keyItem)

    if not addKeyOk or not addedKey then
        local blankRestored =
            restoreExactInventoryItem(claimItemContainer, claimItem)
        local paymentRefunded =
            marketplace.RefundInventoryPurchase(paymentReceipt)

        removeClaimRecord(claimRecord.id)
        logError(
            "ClaimPOBox() could not add the prepared PO Box key; " ..
            "Blank Key rollback=" .. tostring(blankRestored) ..
            ", payment refunded=" .. tostring(paymentRefunded) ..
            ". box=" .. tostring(targetData.registryId)
        )
        return false, "PO Box key could not be added to inventory."
    end

    if type(sendAddItemToContainer) == "function" then
        pcall(sendAddItemToContainer, inventory, keyItem)
    end

    claimRecord.poBoxKeySerial = tostring(keySerial)
    claimRecord.poBoxKeySerials = {
        [tostring(keySerial)] = true,
    }

    if type(keyItem.getID) == "function" then
        local idOk, itemId = pcall(keyItem.getID, keyItem)

        if idOk and itemId ~= nil then
            claimRecord.poBoxKeyItemId = tostring(itemId)
        end
    end

    if type(sendItemStats) == "function" then
        pcall(sendItemStats, keyItem)
    end

    --------------------------------------------------------
    -- PERSIST OWNERSHIP
    --------------------------------------------------------

    local saved =
        save()

    if not saved then

        local issuedKeyRemoved =
            removeExactInventoryItem(inventory, keyItem)
        local blankRestored =
            restoreExactInventoryItem(claimItemContainer, claimItem)
        local paymentRefunded =
            marketplace.RefundInventoryPurchase(paymentReceipt)

        removeClaimRecord(
            claimRecord.id
        )

        logError(
            "PO Box ownership could not be persisted; issued key " ..
            "removed=" .. tostring(issuedKeyRemoved) ..
            ", Blank Key restored=" .. tostring(blankRestored) ..
            ", inventory payment refunded=" ..
            tostring(paymentRefunded)
        )

        return false,
            "PO Box ownership could not be persisted."

    end

    --------------------------------------------------------
    -- SUCCESS
    --------------------------------------------------------

    log(
        "PO BOX CLAIM SUCCESS | " ..

        "claimId=" ..
        claimRecord.id ..

        " | box=" ..
        tostring(targetData.boxNumber) ..

        " | owner=" ..
        playerSteamId ..

        " | zone=" ..
        tostring(targetData.zoneId)
    )

    --------------------------------------------------------
    -- EVENT PRIZE ESCROW RELEASE HOOK
    --
    -- Best-effort and deliberately post-commit: failure to release an
    -- unrelated Event prize must never roll back a valid PO Box
    -- purchase. Only runs when an event-reward service is installed.
    --------------------------------------------------------

    local eventRewardService =
        KIPN.Server.EventRewardService

    if eventRewardService
        and type(eventRewardService.OnPOBoxClaimed) == "function"
    then
        local releaseOk,
            releaseResult,
            releaseCount =
            pcall(
                eventRewardService.OnPOBoxClaimed,
                player,
                claimRecord
            )

        if not releaseOk
            or releaseResult ~= true
        then
            logError(
                "ClaimPOBox() event-prize escrow release failed " ..
                "without affecting the successful PO Box claim | " ..
                "claimId=" .. tostring(claimRecord.id) ..
                " | reason=" .. tostring(
                    releaseOk and releaseCount or releaseResult
                )
            )
        else
            log(
                "ClaimPOBox() event-prize escrow release complete | " ..
                "claimId=" .. tostring(claimRecord.id) ..
                " | released=" .. tostring(releaseCount or 0)
            )
        end
    end

    return true,
        claimRecord

    end)

    --------------------------------------------------------
    -- CRASH-SAFE TEARDOWN
    --------------------------------------------------------
    --
    -- completeOk is false only when the block above raised rather
    -- than returning. Drop the orphaned ownership record and fail the
    -- command cleanly instead of surfacing a raw handler error.
    --------------------------------------------------------

    if not completeOk then

        removeClaimRecord(
            claimRecord.id
        )

        logError(
            "ClaimPOBox() aborted by an unexpected error after the " ..
            "ownership record was created; record rolled back. box=" ..
            tostring(targetData.registryId) ..
            " | err=" .. tostring(purchaseOk)
        )

        return false,
            "PO Box purchase failed."

    end

    return purchaseOk,
        purchaseResult

end

------------------------------------------------------------
-- RECONCILE ORPHANED PO BOX CLAIMS
------------------------------------------------------------
--
-- A completed PO Box purchase always stamps the claim record with
-- poBoxKeySerial (and a poBoxKeySerials set) before it is persisted.
-- A record that survives with neither is the residue of a ClaimPOBox()
-- call that raised after createClaimRecord() but before payment/key
-- issuance -- the box would otherwise stay permanently "owned" with
-- nothing charged and no key in existence. Drop those on boot so the
-- box becomes purchasable again.
------------------------------------------------------------

local function reconcileOrphanedPOBoxClaims()

    local claimData =
        type(getClaimData) == "function"
        and getClaimData()

    if not claimData
        or type(claimData.records) ~= "table"
    then
        return 0
    end

    local orphanIds =
        {}

    for claimId, record in pairs(claimData.records) do

        if type(record) == "table"
            and record.type == CLAIM_TYPE
            and record.active ~= false
        then

            local hasSerial =
                type(record.poBoxKeySerial) == "string"
                and record.poBoxKeySerial ~= ""

            local hasSerialSet = false

            if type(record.poBoxKeySerials) == "table" then
                for _ in pairs(record.poBoxKeySerials) do
                    hasSerialSet = true
                    break
                end
            end

            if not hasSerial and not hasSerialSet then
                orphanIds[#orphanIds + 1] = record.id or tostring(claimId)
            end

        end

    end

    for _, orphanId in ipairs(orphanIds) do

        logError(
            "Dropping orphaned PO Box claim with no issued key | id=" ..
            tostring(orphanId) ..
            " (residue of an interrupted purchase)"
        )

        removeClaimRecord(orphanId)

    end

    return #orphanIds

end

------------------------------------------------------------
-- COMMAND: BUY PO BOX
------------------------------------------------------------
--
-- Client -> server entry point for the "PURCHASE" button on the
-- Postal Services terminal screen (client/KIPN_PostalServices.lua).
--
-- args.boxNumber is a client-chosen hint only; ClaimPOBox()
-- independently re-validates it, the player's own live position/zone,
-- ownership, quota, and payment.
------------------------------------------------------------

local function handleBuyPOBoxCommand(
    player,
    args
)

    args =
        args or {}

    local claimed,
        result =
        POBoxClaimService.ClaimPOBox(
            player,
            args.boxNumber
        )

    if not claimed then

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.PURCHASE_RESULT,
            {
                success = false,
                reason = result or "PO Box purchase failed.",
            }
        )

        return true

    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.PURCHASE_RESULT,
        {

            success =
                true,

            boxNumber =
                result.boxNumber,

            size =
                result.size,

        }
    )

    return true,
        "CLAIM_SUCCESSFUL"

end

------------------------------------------------------------
-- FORMAT PO BOX PURCHASE DATE
------------------------------------------------------------
--
-- Postal Services displays purchase dates for a numbered box rental,
-- unlike the rest of KIPN's ownership records, which are expressed
-- purely in world-day counts. os.time() (captured once, at purchase,
-- into the claim record's purchasedAtRealTime extra field) is
-- real/wall-clock time and is formatted here rather than on the
-- client so the client never needs its own os.date() call against a
-- value it did not create.
------------------------------------------------------------

local function formatPOBoxPurchaseDate(claim)

    local timestamp =
        claim
        and tonumber(
            claim.purchasedAtRealTime
        )

    if not timestamp then
        return nil
    end

    local ok, formatted =
        pcall(
            os.date,
            "%m/%d/%y",
            timestamp
        )

    if not ok then
        return nil
    end

    return formatted

end

------------------------------------------------------------
-- COMMAND: GET PO BOXES
------------------------------------------------------------
--
-- Public, read-only listing of every numbered PO Box and its current
-- ownership/status, for the Postal Services terminal screen's table.
-- Any authenticated player may view this.
------------------------------------------------------------

local function handleGetPOBoxesCommand(
    player,
    _args
)

    local boxes = {}
    local poBoxService = KIPN.Server.POBoxService
    local zone, zoneId

    if poBoxService
        and type(poBoxService.GetPlayerPostOffice) == "function"
    then
        zone, zoneId = poBoxService.GetPlayerPostOffice(player)
    end

    local entries =
        zoneId
        and poBoxService.GetBoxesForZone(zoneId)
        or {}

    for _, boxEntry in ipairs(entries) do

        local claim =
            ClaimService.GetClaimForTarget(
                CLAIM_TYPE,
                boxEntry.id
            )

        boxes[#boxes + 1] = {

            number =
                boxEntry.number,

            id =
                boxEntry.id,

            size =
                poBoxService.GetLabel(boxEntry),

            sizeKey =
                boxEntry.size,

            capacity =
                poBoxService.GetCapacity(boxEntry),

            price =
                poBoxService.GetPrice(boxEntry),

            x =
                boxEntry.x,

            y =
                boxEntry.y,

            z =
                boxEntry.z,

            owner =
                claim and claim.ownerUsername
                or nil,

            purchased =
                claim
                and formatPOBoxPurchaseDate(claim)
                or nil,

        }

    end

    local currencyType, currencyValue = getCurrencySettings()

    local claimItemType = "Base.Key_Blank"
    if KIPN.Server.POBoxConfig and KIPN.Server.POBoxConfig.ClaimItemType then
        claimItemType = KIPN.Server.POBoxConfig.ClaimItemType
    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.PO_BOXES_DATA,
        {

            boxes =
                boxes,

            zoneId =
                zoneId,

            zoneLabel =
                zone
                and zone.metadata
                and zone.metadata.label
                or "Post Office",

            requiresPostOffice =
                zoneId == nil,

            currencyType = currencyType,
            currencyValue = currencyValue,
            claimItemType = claimItemType,

        }
    )

    return true

end

------------------------------------------------------------
-- VALID CARRIED PO BOX KEYS
------------------------------------------------------------

local function getPOBoxKeyCopyFee()
    local configured = KIPN.Server.POBoxConfig
        and tonumber(KIPN.Server.POBoxConfig.KeyCopyPrice)

    return configured and configured > 0
        and math.floor(configured)
        or nil
end

local function getValidCarriedPOBoxKeys(player)
    local poBoxService = KIPN.Server.POBoxService
    local playerSteamId = getPlayerSteamId(player)
    local results = {}
    local seenBoxes = {}
    local lifecycleChanged = false

    if not poBoxService
        or not playerSteamId
    then
        return results
    end

    local keys = POBoxClaimService.FindPlayerPOBoxKeyItems(player)

    for _, keyEntry in ipairs(keys) do
        local boxRecord = poBoxService.GetBox(keyEntry.boxId)
        local claim = boxRecord
            and ClaimService.GetClaimForTarget(
                CLAIM_TYPE,
                boxRecord.id
            )

        if claim
            and tostring(claim.ownerSteamId) == tostring(playerSteamId)
            and keyEntry.item
        then
            local modData = keyEntry.item:getModData()
            local claimSerial = claim.poBoxKeySerial
            local itemSerial = modData and modData.KIPNPOBoxKeySerial
            local authorizedSerial = itemSerial
                and (
                    tostring(itemSerial) == tostring(claimSerial or "")
                    or (
                        type(claim.poBoxKeySerials) == "table"
                        and claim.poBoxKeySerials[tostring(itemSerial)] == true
                    )
                )

            -- Migrate keys issued before lifecycle serials existed and
            -- repair an owned key whose serial is not authorized.
            if not claimSerial or not authorizedSerial
            then
                local assigned,
                    assignedSerial =
                    poBoxService.AssignKeyItem(
                        keyEntry.item,
                        boxRecord,
                        claimSerial
                    )

                if assigned and assignedSerial then
                    if not claim.poBoxKeySerial then
                        claim.poBoxKeySerial = tostring(assignedSerial)
                    end

                    itemSerial = tostring(assignedSerial)
                    claim.poBoxKeySerials =
                        type(claim.poBoxKeySerials) == "table"
                        and claim.poBoxKeySerials
                        or {}
                    claim.poBoxKeySerials[itemSerial] = true
                    authorizedSerial = true
                    lifecycleChanged = true

                    if type(keyEntry.item.getID) == "function" then
                        claim.poBoxKeyItemId =
                            tostring(keyEntry.item:getID())
                    end

                    if type(sendItemStats) == "function" then
                        sendItemStats(keyEntry.item)
                    end
                end
            end

            if claim.poBoxKeySerial
                and (
                    type(claim.poBoxKeySerials) ~= "table"
                    or claim.poBoxKeySerials[
                        tostring(claim.poBoxKeySerial)
                    ] ~= true
                )
            then
                claim.poBoxKeySerials =
                    type(claim.poBoxKeySerials) == "table"
                    and claim.poBoxKeySerials
                    or {}
                claim.poBoxKeySerials[
                    tostring(claim.poBoxKeySerial)
                ] = true
                lifecycleChanged = true
            end

            local keyIdOk, itemKeyId = pcall(function()
                return keyEntry.item:getKeyId()
            end)

            local valid = authorizedSerial
                and keyIdOk
                and tonumber(itemKeyId) == tonumber(boxRecord.keyId)

            if valid and not seenBoxes[tostring(boxRecord.id)] then
                seenBoxes[tostring(boxRecord.id)] = true
                results[#results + 1] = {
                    item = keyEntry.item,
                    box = boxRecord,
                    claim = claim,
                }
            end
        end
    end

    if lifecycleChanged and not save() then
        logError(
            "PO Box key lifecycle migration could not be persisted."
        )
    end

    table.sort(results, function(a, b)
        return (tonumber(a.box.number) or 0)
            < (tonumber(b.box.number) or 0)
    end)

    return results
end

------------------------------------------------------------
-- COMMAND: COPY PO BOX KEY
------------------------------------------------------------

local function handleCopyPOBoxKeyCommand(player, args)
    args = type(args) == "table" and args or {}
    local wantedBoxId = args.boxId and tostring(args.boxId)
    local selected

    for _, entry in ipairs(getValidCarriedPOBoxKeys(player)) do
        if tostring(entry.box.id) == tostring(wantedBoxId) then
            selected = entry
            break
        end
    end

    local function sendResult(success, reason)
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.PO_BOX_KEY_COPY_RESULT,
            {
                success = success,
                reason = reason,
                boxId = selected and selected.box.id or wantedBoxId,
                boxNumber = selected and selected.box.number or nil,
                fee = getPOBoxKeyCopyFee(),
            }
        )
    end

    if not selected then
        sendResult(false, "VALID_PO_BOX_KEY_REQUIRED")
        return false, "A valid owned PO Box key is required."
    end

    local fee = getPOBoxKeyCopyFee()
    if not fee then
        sendResult(false, "COPY_FEE_UNAVAILABLE")
        return false, "PO Box key copy fee is unavailable."
    end

    local marketplace = KIPN.Server.MarketplaceService
    if not marketplace or type(marketplace.ChargeInventoryPurchase) ~= "function" then
        sendResult(false, "MARKETPLACE_UNAVAILABLE")
        return false, "Marketplace service unavailable."
    end

    -- Inventory-only, like the PO Box purchase itself: the fee leaves
    -- the player's inventory and the receipt lets every post-charge
    -- failure below refund it.
    local charged, chargeReason, paymentReceipt =
        marketplace.ChargeInventoryPurchase(
            player,
            fee
        )

    if not charged then
        local reason =
            (chargeReason == "INSUFFICIENT_INVENTORY_CURRENCY"
                or chargeReason == "INSUFFICIENT_CURRENCY")
                and "INSUFFICIENT_CURRENCY"
                or (chargeReason or "PAYMENT_FAILED")
        sendResult(false, reason)
        return false, reason
    end

    local artifacts = getArtifactService()
    local keyItem,
        droppedOnGround

    if artifacts
        and type(artifacts.GiveItemToPlayer) == "function"
    then
        keyItem,
            droppedOnGround =
            artifacts.GiveItemToPlayer(
            player,
            KIPN.Server.POBoxConfig.KeyItemType
        )
    end

    if not keyItem then
        local feeRefunded =
            marketplace.RefundInventoryPurchase(paymentReceipt)
        logError(
            "PO Box key copy failed after charge; fee refunded=" ..
            tostring(feeRefunded) .. ". box=" .. tostring(selected.box.id)
        )
        sendResult(false, "KEY_COPY_ISSUE_FAILED")
        return false, "PO Box key copy could not be issued."
    end

    local assigned,
        copiedSerial =
        KIPN.Server.POBoxService.AssignKeyItem(
        keyItem,
        selected.box
    )

    if not assigned or not copiedSerial then
        local removedKey =
            removeExactInventoryItem(
                getExactItemContainer(keyItem, player:getInventory()),
                keyItem
            )
        local feeRefunded =
            marketplace.RefundInventoryPurchase(paymentReceipt)
        logError(
            "PO Box copied key could not be bound after charge; " ..
            "key removed=" .. tostring(removedKey) ..
            ", fee refunded=" .. tostring(feeRefunded) ..
            ". box=" .. tostring(selected.box.id)
        )
        sendResult(false, "KEY_COPY_BIND_FAILED")
        return false, "PO Box key copy could not be bound."
    end

    if type(keyItem.setName) == "function" then
        keyItem:setName("Copy of PO Box " .. tostring(selected.box.keyId))
    end

    selected.claim.poBoxKeySerials =
        type(selected.claim.poBoxKeySerials) == "table"
        and selected.claim.poBoxKeySerials
        or {}
    selected.claim.poBoxKeySerials[tostring(copiedSerial)] = true

    if not save() then
        selected.claim.poBoxKeySerials[tostring(copiedSerial)] = nil

        local removedKey =
            removeExactInventoryItem(
                getExactItemContainer(keyItem, player:getInventory()),
                keyItem
            )
        local feeRefunded =
            marketplace.RefundInventoryPurchase(paymentReceipt)

        logError(
            "PO Box copied key authorization could not be persisted " ..
            "after charge; key removed=" .. tostring(removedKey) ..
            ", fee refunded=" .. tostring(feeRefunded) ..
            ". box=" .. tostring(selected.box.id)
        )
        sendResult(false, "KEY_COPY_SAVE_FAILED")
        return false, "PO Box key copy could not be persisted."
    end

    if droppedOnGround then
        local worldItem = keyItem:getWorldItem()
        if worldItem
            and type(worldItem.transmitCompleteItemToClients) == "function"
        then
            worldItem:transmitCompleteItemToClients()
        end
    elseif type(sendItemStats) == "function" then
        sendItemStats(keyItem)
    end

    sendResult(true)
    return true, "PO_BOX_KEY_COPIED"
end

------------------------------------------------------------
-- COMMAND: GET MY PO BOX KEYS
------------------------------------------------------------
--
-- Returns structured rows for valid owned KIPNPOBoxKey items the
-- requesting player is carrying, plus the configured copy fee.
------------------------------------------------------------

local function handleGetMyPOBoxKeysCommand(
    player,
    _args
)

    local keyRows = {}

    for _, entry in ipairs(getValidCarriedPOBoxKeys(player)) do
        keyRows[#keyRows + 1] = {
            boxId = entry.box.id,
            number = entry.box.number,
            size = entry.box.size,
        }
    end

    local currencyType, currencyValue = getCurrencySettings()

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.MY_POBOX_KEYS_DATA,
        {
            keys = keyRows,
            copyFee = getPOBoxKeyCopyFee(),
            currencyType = currencyType,
            currencyValue = currencyValue,
        }
    )

    return true

end

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

ClaimService.RegisterClaimType(CLAIM_TYPE, {
    requiredCapability = "po_box.claim",
    serviceConfigKey = "PoBox",
    label = "PO Box",
    validateTarget = POBoxClaimService.ValidatePOBoxTarget,
    claim = POBoxClaimService.ClaimPOBox,

    -- A released box must stop accepting the previous owner's keys.
    -- Post-commit and best effort: ClaimPOBox() rotates the lock again
    -- before the next owner is charged, so a failure here can never
    -- hand a new owner a lock the old keys still open.
    onAfterRelease = function(claim)
        local poBoxService = KIPN.Server.POBoxService
        local rekeyed, rekeyReason

        if poBoxService and type(poBoxService.RotateKey) == "function" then
            rekeyed, rekeyReason = poBoxService.RotateKey(claim.targetId)
        end

        if not rekeyed then
            logError(
                "PO Box release could not rotate its lock | box=" ..
                tostring(claim.targetId) ..
                " | reason=" .. tostring(rekeyReason)
            )
        end
    end,
})

------------------------------------------------------------
-- INITIALIZATION  (driven by KIPN_PostOfficeInit.lua's RegisterService)
------------------------------------------------------------

function POBoxClaimService.Initialize()

    if type(KIPN.Server.RegisterCommandHandler) ~= "function" then
        logError("RegisterCommandHandler unavailable; PO Box commands unreachable.")
        return false
    end

    local orphaned = reconcileOrphanedPOBoxClaims()

    if orphaned > 0 then
        log(
            "Dropped " .. tostring(orphaned) ..
            " orphaned PO Box claim(s) left by interrupted purchases."
        )
        save()
    end

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.BUY_PO_BOX,
        handleBuyPOBoxCommand
    )

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.COPY_PO_BOX_KEY,
        handleCopyPOBoxKeyCommand
    )

    -- GET_PO_BOXES is intentionally PUBLIC -- any player may view the
    -- listing for the post office they are standing in.
    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.GET_PO_BOXES,
        handleGetPOBoxesCommand
    )

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.GET_MY_POBOX_KEYS,
        handleGetMyPOBoxKeysCommand
    )

    log("PO Box claim service initialized.")
    return true
end

print("[KIPN] Post Office PO Box Claim Service loaded")
