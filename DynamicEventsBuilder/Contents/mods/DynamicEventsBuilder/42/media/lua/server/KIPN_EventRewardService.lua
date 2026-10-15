-- KIPN_EventRewardService.lua
--
-- Persistent Event prize awards. ADMIN_DELIVERY records an auditable handoff
-- for staff; PO_BOX_DELIVERY creates normal KIPN parcels when possible and
-- otherwise holds the award in escrow until a matching PO Box claim exists.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_AdminService"
require "KIPN_EventAccessService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventRewardService = KIPN.Server.EventRewardService or {}

local Service = KIPN.Server.EventRewardService
local DATA_TAG = "KIPN_EventRewardAwards"
local MAX_AWARD_ITEMS = 50

local function log(message)
    print("[KIPN EVENT REWARD] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT REWARD] ERROR: " .. tostring(message))
end

local function getData()
    local ok, data = pcall(ModData.getOrCreate, DATA_TAG)
    if not ok or type(data) ~= "table" then
        logError("getData() failed: " .. tostring(data))
        return nil
    end
    data.version = math.max(tonumber(data.version) or 1, 3)
    data.nextAwardId = tonumber(data.nextAwardId) or 1
    data.awards = type(data.awards) == "table" and data.awards or {}
    data.eventAwards = type(data.eventAwards) == "table" and data.eventAwards or {}
    data.awardKeys = type(data.awardKeys) == "table" and data.awardKeys or {}
    log("getData() -> awards available")
    return data
end

local function persist()
    -- Global ModData is saved by the server. Do not transmit this private
    -- fulfillment ledger (which contains recipient identity data) to clients;
    -- authorized views are sent through the narrow command response above.
    log("persist() -> server ModData updated")
    return true
end

local function getWorldDays()
    local ok, value = pcall(function() return getGameTime():getWorldAgeHours() / 24 end)
    local result = ok and value or 0
    log("getWorldDays() -> " .. tostring(result))
    return result
end

local function sanitizeItems(rawItems)
    local result = {}
    for _, item in ipairs(type(rawItems) == "table" and rawItems or {}) do
        if #result >= MAX_AWARD_ITEMS then break end
        local fullType = type(item) == "table" and item.itemFullType or nil
        local count = type(item) == "table" and math.floor(tonumber(item.count or item.quantity) or 1) or 0
        if type(fullType) == "string" and fullType ~= "" and count > 0 then
            result[#result + 1] = {
                itemFullType = fullType,
                displayName = tostring(item.displayName or fullType),
                count = math.min(100, count),
            }
        end
    end
    log("sanitizeItems() -> " .. tostring(#result))
    return result
end

local function findOnlineIdentity(username)
    local identity = { username = tostring(username), steamId = nil }
    local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    if online then
        for index = 0, online:size() - 1 do
            local player = online:get(index)
            if player and tostring(player:getUsername()) == tostring(username) then
                identity.player = player
                local ok, steamId = pcall(function()
                    return KIPN.Shared.GetPlayerId and KIPN.Shared.GetPlayerId(player) or player:getSteamID()
                end)
                if ok and steamId then identity.steamId = tostring(steamId) end
                break
            end
        end
    end
    log("findOnlineIdentity(" .. tostring(username) .. ") -> steamId=" .. tostring(identity.steamId))
    return identity
end

local function normalizeIdentity(username, runtimeParticipant)
    local identity = {
        username = tostring(username),
        steamId = type(runtimeParticipant) == "table" and runtimeParticipant.steamId or nil,
        player = type(runtimeParticipant) == "table" and runtimeParticipant.player or nil,
    }
    if not identity.steamId or not identity.player then
        local onlineIdentity = findOnlineIdentity(username)
        identity.steamId = identity.steamId or onlineIdentity.steamId
        identity.player = identity.player or onlineIdentity.player
    end
    log("normalizeIdentity() -> " .. identity.username .. "/" .. tostring(identity.steamId))
    return identity
end

local function createAward(definition, runtime, identity, items, method)
    local data = getData()
    if not data then return nil, "AWARD_DATA_UNAVAILABLE" end

    local identityKey = identity.steamId and ("steam:" .. tostring(identity.steamId))
        or ("user:" .. tostring(identity.username):lower())
    local awardKey = tostring(runtime.instanceId or runtime.eventDefinitionId) .. ":" .. identityKey
    local existingId = data.awardKeys[awardKey]
    if existingId and data.awards[existingId] then
        log("createAward() -> existing " .. tostring(existingId))
        return data.awards[existingId], nil, true
    end

    local id = "event_award_" .. tostring(data.nextAwardId)
    data.nextAwardId = data.nextAwardId + 1

    local award = {
        id = id,
        eventDefinitionId = definition.id,
        eventInstanceId = runtime.instanceId or runtime.eventDefinitionId,
        eventName = definition.name,
        recipientUsername = identity.username,
        recipientSteamId = identity.steamId,
        items = items,
        deliveryMethod = method,
        status = "AWARDED",
        createdAtWorldDays = getWorldDays(),
        createdAtMs = type(getTimestampMs) == "function" and getTimestampMs() or 0,
        parcelIds = {},
        deliveryLog = {},
    }

    data.awards[id] = award
    data.awardKeys[awardKey] = id
    local eventKey = tostring(award.eventInstanceId)
    data.eventAwards[eventKey] = data.eventAwards[eventKey] or {}
    data.eventAwards[eventKey][#data.eventAwards[eventKey] + 1] = id
    persist()
    log("createAward() -> " .. id .. " recipient=" .. identity.username .. " method=" .. method)
    return award, nil, false
end

local function appendDeliveryLog(award, message)
    award.deliveryLog = type(award.deliveryLog) == "table" and award.deliveryLog or {}
    award.deliveryLog[#award.deliveryLog + 1] = {
        atWorldDays = getWorldDays(),
        message = tostring(message),
    }
    while #award.deliveryLog > 20 do table.remove(award.deliveryLog, 1) end
    log("appendDeliveryLog(" .. tostring(award.id) .. ") -> " .. tostring(message))
end

local function queueAwardParcels(award)
    local marketplace = KIPN.Server.MarketplaceService
    if not marketplace or type(marketplace.QueueSystemParcel) ~= "function" then
        log("queueAwardParcels() -> MARKETPLACE_DELIVERY_UNAVAILABLE")
        return false, "MARKETPLACE_DELIVERY_UNAVAILABLE"
    end

    if type(marketplace.HasPOBoxForIdentity) ~= "function"
        or not marketplace.HasPOBoxForIdentity(award.recipientUsername, award.recipientSteamId)
    then
        log("queueAwardParcels() -> PO_BOX_REQUIRED")
        return false, "PO_BOX_REQUIRED"
    end

    award.parcelIds = type(award.parcelIds) == "table" and award.parcelIds or {}
    for index, item in ipairs(award.items or {}) do
        local parcel, reason = marketplace.QueueSystemParcel(
            {
                username = award.recipientUsername,
                steamId = award.recipientSteamId,
            },
            {
                systemOrderId = award.id .. ":" .. tostring(index),
                itemFullType = item.itemFullType,
                displayName = "Event Prize: " .. tostring(item.displayName or item.itemFullType),
                quantity = item.count,
                sourceType = "EVENT_PRIZE",
                sourceData = {
                    awardId = award.id,
                    eventDefinitionId = award.eventDefinitionId,
                    eventInstanceId = award.eventInstanceId,
                    eventName = award.eventName,
                },
            }
        )
        if not parcel then
            appendDeliveryLog(award, "Parcel queue failed: " .. tostring(reason))
            persist()
            return false, reason or "PARCEL_QUEUE_FAILED"
        end
        local knownParcel = false
        for _, parcelId in ipairs(award.parcelIds) do
            if tostring(parcelId) == tostring(parcel.id) then knownParcel = true break end
        end
        if not knownParcel then award.parcelIds[#award.parcelIds + 1] = parcel.id end
    end

    award.status = "DELIVERED_TO_PO_BOX"
    award.deliveredAtWorldDays = getWorldDays()
    appendDeliveryLog(award, "Queued to PO Box parcel collection")
    persist()
    log("queueAwardParcels() -> award=" .. award.id .. " parcels=" .. tostring(#award.parcelIds))
    return true
end

function Service.ProcessAward(award)
    if type(award) ~= "table" then
        log("ProcessAward() -> INVALID_AWARD")
        return false, "INVALID_AWARD"
    end

    if award.deliveryMethod == KIPN.Shared.EventRewardDeliveryMethods.ADMIN_DELIVERY then
        award.status = "AWAITING_ADMIN_DELIVERY"
        appendDeliveryLog(award, "Awaiting physical admin delivery")
        persist()
        log("ProcessAward() -> AWAITING_ADMIN_DELIVERY")
        return true
    end

    local ok, reason = queueAwardParcels(award)
    if not ok and reason == "PO_BOX_REQUIRED" then
        award.status = "HELD_IN_ESCROW"
        award.escrowReason = "NO_PO_BOX"
        appendDeliveryLog(award, "Held in escrow until recipient owns a PO Box")
        persist()
        log("ProcessAward() -> HELD_IN_ESCROW")
        return true
    end

    if not ok then
        award.status = "DELIVERY_FAILED"
        award.failureReason = reason
        persist()
    end
    log("ProcessAward() -> " .. tostring(ok) .. "/" .. tostring(reason))
    return ok, reason
end

function Service.AwardEvent(definition, runtime, outcome)
    if outcome ~= "WIN" then
        log("AwardEvent() -> skipped outcome=" .. tostring(outcome))
        return true, {}
    end

    local items = sanitizeItems(definition and definition.rewards and definition.rewards.items)
    if #items == 0 then
        log("AwardEvent() -> no configured items")
        return true, {}
    end

    local method = definition.rewardDeliveryMethod
        or KIPN.Shared.EventRewardDeliveryMethods.ADMIN_DELIVERY
    local recipients = runtime.winners
    local recipientsEmpty = type(recipients) ~= "table"
    if not recipientsEmpty then
        recipientsEmpty = true
        for _ in pairs(recipients) do recipientsEmpty = false; break end
    end

    -- Phase 4: no more implicit "winners empty -> reward everyone"
    -- fallback. A mode that produces an intentional no-winner result
    -- (or has a bug that leaves winners unpopulated) now correctly
    -- gets zero awards rather than silently rewarding the whole
    -- roster. Every WIN path that genuinely means "everyone wins" now
    -- explicitly populates runtime.winners itself before calling here
    -- -- see KIPN_EventRuntimeService.lua's creditAllParticipantsAsWinners().
    if recipientsEmpty then
        log("AwardEvent() -> no winners recorded for " .. tostring(definition and definition.id) .. "; intentional no-winner result, skipping reward distribution.")
        return true, {}
    end

    local awards = {}

    for username, participant in pairs(recipients) do
        local identity = normalizeIdentity(username, participant)
        local award, reason, existing = createAward(definition, runtime, identity, items, method)
        if not award then
            logError("AwardEvent() create failed for " .. tostring(username) .. ": " .. tostring(reason))
            return false, reason
        end
        if not existing or award.status == "AWARDED" or award.status == "DELIVERY_FAILED" then
            Service.ProcessAward(award)
        end
        awards[#awards + 1] = award
    end

    log("AwardEvent() -> awards=" .. tostring(#awards))
    return true, awards
end

function Service.ReleaseEligibleEscrow(username, steamId)
    local data = getData()
    if not data then return false, "AWARD_DATA_UNAVAILABLE" end
    local released = 0
    for _, award in pairs(data.awards) do
        local identityMatches = tostring(award.recipientUsername) == tostring(username)
            or (steamId and award.recipientSteamId and tostring(award.recipientSteamId) == tostring(steamId))
        if identityMatches and award.status == "HELD_IN_ESCROW" then
            local ok = queueAwardParcels(award)
            if ok then released = released + 1 end
        end
    end
    log("ReleaseEligibleEscrow() -> released=" .. tostring(released))
    return true, released
end

function Service.ReconcileEscrow()
    local data = getData()
    if not data then return false, "AWARD_DATA_UNAVAILABLE" end
    local released = 0
    for _, award in pairs(data.awards) do
        if award.status == "HELD_IN_ESCROW" then
            local ok = queueAwardParcels(award)
            if ok then released = released + 1 end
        end
    end
    log("ReconcileEscrow() -> released=" .. tostring(released))
    return true, released
end

function Service.OnPOBoxClaimed(player, claim)
    local username = player and player:getUsername() or claim and claim.ownerUsername
    local steamId = claim and claim.ownerSteamId
    local ok, released = Service.ReleaseEligibleEscrow(username, steamId)
    log("OnPOBoxClaimed() -> " .. tostring(ok) .. " released=" .. tostring(released))
    return ok, released
end

function Service.GetAwardsForRecipient(username, steamId)
    local data = getData()
    local result = {}
    for _, award in pairs(data and data.awards or {}) do
        if tostring(award.recipientUsername) == tostring(username)
            or (steamId and award.recipientSteamId and tostring(award.recipientSteamId) == tostring(steamId))
        then
            result[#result + 1] = award
        end
    end
    table.sort(result, function(a, b)
        return (tonumber(a.createdAtMs) or 0) > (tonumber(b.createdAtMs) or 0)
    end)
    log("GetAwardsForRecipient() -> " .. tostring(#result))
    return result
end

local function handleListAwards(player, args)
    -- Admins, and staff levels the sandbox allows (KIPN_EventAccessService.lua).
    local allowed = KIPN.Server.EventAccessService.RequireStudio(player)
    if not allowed then return false end
    Service.ReconcileEscrow()
    local data = getData()
    local awards = {}
    for _, award in pairs(data and data.awards or {}) do
        if not args or not args.status or award.status == args.status then awards[#awards + 1] = award end
    end
    table.sort(awards, function(a, b)
        return (tonumber(a.createdAtMs) or 0) > (tonumber(b.createdAtMs) or 0)
    end)
    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_REWARDS_DATA, { awards = awards })
    log("handleListAwards() -> " .. tostring(#awards))
    return true
end

local function handleMarkDelivered(player, args)
    local allowed = KIPN.Server.EventAccessService.RequireStudio(player)
    if not allowed then return false end
    local data = getData()
    local award = data and data.awards[tostring(args and args.awardId)]
    if not award or award.status ~= "AWAITING_ADMIN_DELIVERY" then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_REWARD_RESULT, {
            success = false,
            reason = award and "AWARD_NOT_AWAITING_ADMIN" or "AWARD_NOT_FOUND",
        })
        log("handleMarkDelivered() -> rejected")
        return true
    end
    award.status = "ADMIN_DELIVERED"
    award.deliveredAtWorldDays = getWorldDays()
    award.deliveredBy = player and player:getUsername() or "Unknown"
    appendDeliveryLog(award, "Marked delivered by " .. tostring(award.deliveredBy))
    persist()
    KIPN.Server.AdminService.WriteAudit(player, "EVENT_REWARD_ADMIN_DELIVERED", "eventReward", award.id, {
        recipientUsername = award.recipientUsername,
        eventDefinitionId = award.eventDefinitionId,
    })
    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_REWARD_RESULT, {
        success = true,
        award = award,
    })
    log("handleMarkDelivered() -> " .. award.id)
    return true
end

function Service.Initialize()
    if not getData() then
        logError("Initialize() -> persistent award data unavailable")
        return false
    end
    Service.ReconcileEscrow()
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_LIST_REWARDS, handleListAwards)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_MARK_REWARD_DELIVERED, handleMarkDelivered)
    log("Initialize() -> commands registered")
    return true
end

log("module loaded")
