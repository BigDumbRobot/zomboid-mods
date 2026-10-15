if isClient() then return end

require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_Sandbox"
require "SacrificialOffering/SO_Storage"

local SO = SacrificialOffering
SO.PlayerLedger = SO.PlayerLedger or {}
local Ledger = SO.PlayerLedger

Ledger.RecentDeaths = Ledger.RecentDeaths or {}
Ledger.RecentDeathCandidates = Ledger.RecentDeathCandidates or {}
Ledger.PendingDeathNotices = Ledger.PendingDeathNotices or {}
Ledger.PlayerAnchorsByOnlineId = Ledger.PlayerAnchorsByOnlineId or {}
Ledger.PendingPlayerCorpses = Ledger.PendingPlayerCorpses or {}
Ledger.LoggedPlayerCorpseTags = Ledger.LoggedPlayerCorpseTags or {}
Ledger.NextCorpseSweepAt = Ledger.NextCorpseSweepAt or 0

local CORPSE_RETRY_MS = 250
local CORPSE_AUDIT_MS = 10000
local CORPSE_WARNING_MS = 10000
local CORPSE_WARNING_REPEAT_MS = 60000
-- Anchors/identity stamps only need to be a few hundred ms fresh -- deaths are
-- caught by the corpse observers and audit regardless -- so refresh at 4 Hz
-- instead of once per server tick.
local ANCHOR_REFRESH_MS = 250
local PLAYER_ANCHOR_MAX_AGE_MS = 120000
local CORPSE_ANCHOR_DISTANCE_SQUARED = 9
-- Repeated bodies remain valuable for a long time. The first five corpses from
-- the same victim are full strength; only then does a gentle wipe-persistent
-- decay encourage the sacrificer to seek different players.
local REPEATED_VICTIM_FULL_STRENGTH_USES = 5
local REPEATED_VICTIM_MULTIPLIER = 0.99

local function copyNumberMap(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = tonumber(value) or 0 end
    return result
end

local function resetRecoveryProgress(record)
    record.recoveryStrengthGeneration = record.deathGeneration
    record.recoveryStrengthRedeemed = 0
    record.recoveryBaselineXP = {}
    record.recoveryCeilingXP = {}
end

local function ensureRecoveryGeneration(record)
    if tonumber(record.recoveryStrengthGeneration) == tonumber(record.deathGeneration) then return end
    record.recoveryStrengthGeneration = record.deathGeneration
    -- Migration: a save from before the per-life tier ledger cannot prove which
    -- strength it redeemed this life, only that it already recovered. Treat that
    -- as fully redeemed so it cannot double-dip; the next death starts the
    -- cumulative ledger cleanly.
    local priorLifeWasRedeemed = record.deathGeneration > 0
        and record.recoveredGeneration >= record.deathGeneration
    record.recoveryStrengthRedeemed = priorLifeWasRedeemed and 100 or 0
    record.recoveryBaselineXP = {}
    record.recoveryCeilingXP = {}
end

local function callString(object, methodName)
    if not object or type(object[methodName]) ~= "function" then return nil end
    local ok, value = pcall(function() return object[methodName](object) end)
    if not ok or value == nil then return nil end
    value = SO.Util.Trim(value)
    if value == "" then return nil end
    return value
end

-- Before this version records were keyed by "steam:" .. getSteamID(). Lua
-- receives the Steam ID as a double, so the key was a rounded number in
-- exponent form ("steam:7.656119951162512E16") shared by neighbouring IDs.
local function legacySteamIdentity(player)
    local steamId = callString(player, "getSteamID")
    if steamId and steamId ~= "0" and steamId ~= "-1" then return "steam:" .. steamId end
    return nil
end

-- The first time a player is seen under their current key, their record from
-- the retired Steam key is copied (never moved, so an older mod version still
-- finds it), and the old key is remembered so corpses tagged with it stay theirs.
local function adoptLegacyRecord(player, identity)
    local root = SO.Storage.Get()
    if root.players[identity] then return end
    local legacy = legacySteamIdentity(player)
    if not legacy or legacy == identity or not root.players[legacy] then return end
    root.players[identity] = SO.Util.DeepCopy(root.players[legacy])
    root.identityAliases[legacy] = root.identityAliases[legacy] or identity
    SO.Logger.Info("Copied a player's recovery record to their login name", { from = legacy, to = identity })
end

-- A player is keyed by what the server itself knows exactly: the login name in
-- multiplayer, and the local player slot in single player (where the username is
-- the character's own name and changes with every new character).
function Ledger.GetIdentity(player)
    if not player then return nil end
    local identity
    if not isClient() and not isServer() then
        identity = "local:" .. (callString(player, "getPlayerNum") or "0")
    else
        local username = callString(player, "getUsername") or callString(player, "getDisplayName")
        if username then
            identity = "user:" .. string.lower(username)
        else
            local onlineId = callString(player, "getOnlineID")
            if onlineId then return "online:" .. onlineId end
            return nil
        end
    end
    adoptLegacyRecord(player, identity)
    return identity
end

-- Maps a stored identity (for example a corpse's owner tag written before the
-- key change) to the identity its record lives under now.
function Ledger.CanonicalIdentity(identity)
    if not identity then return nil end
    return SO.Storage.Get().identityAliases[identity] or identity
end

function Ledger.GetPlayerName(player)
    local name = callString(player, "getUsername") or callString(player, "getDisplayName")
    if not name then return nil end
    return SO.Util.Trim(name):gsub("[%c]", ""):sub(1, 64)
end

local function rememberPlayerIdentity(player, now)
    local identity = Ledger.GetIdentity(player)
    local playerName = Ledger.GetPlayerName(player)
    local onlineId = player and tonumber(player:getOnlineID()) or -1
    -- B42's IsoDeadBody(IsoGameCharacter) constructor copies the character's
    -- entire modData table into the new corpse. Stamp the authoritative server
    -- player continuously, so ownership crosses into the corpse atomically at
    -- creation and does not depend on a later death event or connection-id join.
    if identity and player then
        local ok, md = pcall(function() return player:getModData() end)
        -- Only write when a field actually changed: the values are stable for the
        -- life of the connection, so an unconditional write every refresh would
        -- dirty the player for re-sync/save for nothing.
        if ok and md and (md[SO.MOD_DATA.CORPSE_OWNER] ~= identity
                or md[SO.MOD_DATA.CORPSE_ONLINE_ID] ~= onlineId
                or md[SO.MOD_DATA.CORPSE_PLAYER_NAME] ~= playerName) then
            md[SO.MOD_DATA.CORPSE_OWNER] = identity
            md[SO.MOD_DATA.CORPSE_ONLINE_ID] = onlineId
            md[SO.MOD_DATA.CORPSE_PLAYER_NAME] = playerName
        end
    end

    -- Retain an independent server-side ID/location join as a repair path for
    -- bodies created before the live-player stamp was present.
    if identity and onlineId >= 0 then
        local ok, x, y, z = pcall(function() return player:getX(), player:getY(), player:getZ() end)
        if ok then
            local anchor = Ledger.PlayerAnchorsByOnlineId[onlineId] or {}
            anchor.identity = identity
            anchor.playerName = playerName
            anchor.onlineId = onlineId
            anchor.x, anchor.y, anchor.z = x, y, z
            anchor.at = now or SO.Util.NowMs()
            Ledger.PlayerAnchorsByOnlineId[onlineId] = anchor
        end
    end
    return identity, onlineId, playerName
end

function Ledger.CaptureOnlinePlayerAnchors()
    if not isServer() then return end
    local players = getOnlinePlayers()
    if not players then return end
    local now = SO.Util.NowMs()
    for index = 0, players:size() - 1 do rememberPlayerIdentity(players:get(index), now) end
end

local function eachPerk(callback)
    for index = 0, Perks.getMaxIndex() - 1 do
        local perkType = Perks.fromIndex(index)
        local perk = PerkFactory.getPerk(perkType)
        if perk and perk:getParent() ~= Perks.None then callback(perkType, perk) end
    end
end

function Ledger.ReadXP(player)
    local xp = {}
    local total = 0
    if not player or not player:getXp() then return xp, total end
    eachPerk(function(perkType)
        local value = tonumber(player:getXp():getXP(perkType)) or 0
        if value < 0 then value = 0 end
        xp[tostring(perkType)] = value
        total = total + value
    end)
    return xp, total
end

function Ledger.UpdateBest(player)
    local identity = Ledger.GetIdentity(player)
    if not identity then return nil end
    local record = SO.Storage.GetPlayer(identity)
    local current, total = Ledger.ReadXP(player)
    local changed = 0
    for perkName, value in pairs(current) do
        if value > (tonumber(record.bestXP[perkName]) or 0) then
            record.bestXP[perkName] = value
            changed = changed + 1
        end
    end
    record.lastTotalXP = total
    record.lastHours = tonumber(player:getHoursSurvived()) or record.lastHours or 0
    if changed > 0 then
        SO.Logger.Debug("Updated per-skill personal-best XP envelope", {
            player = identity,
            changed = changed,
        })
    end
    return record
end

function Ledger.RecordDeath(player, source)
    local identity, onlineId, playerName = rememberPlayerIdentity(player)
    if not identity then return false end
    local record = SO.Storage.GetPlayer(identity)
    local now = SO.Util.NowMs()
    if now - (tonumber(record.lastDeathMs) or 0) < 5000 then return false end

    Ledger.UpdateBest(player)
    record.deathGeneration = record.deathGeneration + 1
    resetRecoveryProgress(record)
    record.lastDeathMs = now
    record.awaitingRespawn = true

    local recent = {
        identity = identity,
        playerName = playerName,
        onlineId = onlineId,
        x = player:getX(),
        y = player:getY(),
        z = player:getZ(),
        at = now,
    }
    if onlineId >= 0 then Ledger.RecentDeaths[onlineId] = recent end
    Ledger.RecentDeathCandidates[#Ledger.RecentDeathCandidates + 1] = recent
    SO.Logger.Debug("Recorded player death", {
        player = identity,
        generation = record.deathGeneration,
        source = source or "event",
        onlineId = onlineId,
    })
    return true, recent
end

function Ledger.HandleDeathNotice(player, args)
    if not player then return false end
    rememberPlayerIdentity(player)
    if args and tonumber(args.onlineId) and tonumber(args.onlineId) ~= tonumber(player:getOnlineID()) then return false end
    local isDead = false
    local ok, result = pcall(function() return player:isDead() end)
    if ok then isDead = result == true end
    if not isDead and player:getBodyDamage() then
        isDead = player:getBodyDamage():getOverallBodyHealth() <= 0
    end
    if not isDead then
        local identity = Ledger.GetIdentity(player)
        if not identity then return false end
        Ledger.PendingDeathNotices[identity] = {
            player = player,
            onlineId = player:getOnlineID(),
            at = SO.Util.NowMs(),
        }
        SO.Logger.Debug("Queued client death notice for authoritative verification", { player = identity })
        return false
    end
    return Ledger.RecordDeath(player, "client-verified")
end

local function scanRecentCorpse(recent)
    if not recent then return end
    pcall(function()
        for x = math.floor(recent.x) - 2, math.floor(recent.x) + 2 do
            for y = math.floor(recent.y) - 2, math.floor(recent.y) + 2 do
                local square = getCell():getGridSquare(x, y, math.floor(recent.z))
                if square then
                    local bodies = square:getStaticMovingObjects()
                    for index = 0, bodies:size() - 1 do
                        Ledger.TagPlayerCorpse(bodies:get(index), "death-area-scan")
                    end
                end
            end
        end
    end)
end

local function verifyPendingDeath(pending)
    local player = pending.player
    if not player then return false end
    local ok, result = pcall(function()
        if player:isDead() then return true end
        local damage = player:getBodyDamage()
        return damage ~= nil and damage:getOverallBodyHealth() <= 0
    end)
    return ok and result == true
end

function Ledger.ProcessPendingDeaths()
    -- Note: `next` is not available in the server Lua environment; iterate instead.
    if SO.Util.TableCount(Ledger.PendingDeathNotices) == 0 then return end
    local now = SO.Util.NowMs()
    for identity, pending in pairs(Ledger.PendingDeathNotices) do
        local ok, verified = pcall(verifyPendingDeath, pending)
        if ok and verified then
            pcall(function()
                local _, recent = Ledger.RecordDeath(pending.player, "client-deferred")
                scanRecentCorpse(recent)
            end)
            Ledger.PendingDeathNotices[identity] = nil
        elseif not ok or now - pending.at > 10000 then
            if not ok then
                SO.Logger.Warn("Dropped client death notice after verification error", { player = identity, error = tostring(verified) })
            else
                SO.Logger.Warn("Discarded unverified client death notice", { player = identity })
            end
            Ledger.PendingDeathNotices[identity] = nil
        end
    end
end

local function isPlayerCorpse(body)
    if not body or not instanceof(body, "IsoDeadBody") then return false end
    local animalOk, animal = pcall(function() return body:isAnimal() end)
    if animalOk and animal == true then return false end

    -- isPlayer() is definitive while B42 still retains the dead IsoPlayer.
    -- That Java reference is not serialized, so the server-owned identity tag
    -- is the definitive proof after the corpse or its item has been reloaded.
    local ok, playerCorpse = pcall(function() return body:isPlayer() end)
    if ok and playerCorpse == true then return true end
    local md = body:getModData()
    local owner = md and md[SO.MOD_DATA.CORPSE_OWNER]
    return owner ~= nil and SO.Util.Trim(tostring(owner)) ~= ""
end

Ledger.IsPlayerCorpse = isPlayerCorpse

-- Broadcasting a corpse's modData is only meaningful when remote clients can
-- resolve that corpse. A body still mid-spawn, one rebuilt from its draggable
-- corpse item, or one whose square has streamed out has no resolvable network
-- reference, so every transmitModData() for it makes each in-range client log
-- "ObjectModDataPacket.parse: object is null" once per tile. Skipping the
-- broadcast loses nothing: the tag is persisted in modData and reaches clients
-- through normal object streaming when the chunk next loads for them.
local function transmitBodyModData(body)
    if not body or not body.transmitModData then return false end
    local ok, resolvable = pcall(function()
        local square = body.getSquare and body:getSquare()
        if not square then return false end
        -- Square present but its chunk not instantiated: clients cannot have it.
        if square.getChunk and not square:getChunk() then return false end
        -- A real world object has a positive id; 0/-1/nil means "not registered
        -- in the world yet" -- defer, the 10s audit re-broadcasts once it is.
        local id = body.getObjectIDAsLong and body:getObjectIDAsLong()
        if id ~= nil and id <= 0 then return false end
        return true
    end)
    if not ok or not resolvable then return false end
    pcall(function() body:transmitModData() end)
    return true
end

local function setCorpseOwner(body, identity, onlineId, playerName)
    if not body or not identity or not isPlayerCorpse(body) then return false end
    local md = body:getModData()
    playerName = playerName or md[SO.MOD_DATA.CORPSE_PLAYER_NAME]
    local bodyChanged = md[SO.MOD_DATA.CORPSE_OWNER] ~= identity
        or tonumber(md[SO.MOD_DATA.CORPSE_ONLINE_ID]) ~= tonumber(onlineId)
        or md[SO.MOD_DATA.CORPSE_PLAYER_NAME] ~= playerName
    md[SO.MOD_DATA.CORPSE_OWNER] = identity
    md[SO.MOD_DATA.CORPSE_ONLINE_ID] = onlineId
    md[SO.MOD_DATA.CORPSE_PLAYER_NAME] = playerName
    local displayName = playerName and (playerName .. "'s corpse") or nil
    if displayName and body.setName then
        local ok, currentName = pcall(function() return body:getName() end)
        if not ok or currentName ~= displayName then
            bodyChanged = true
            pcall(function() body:setName(displayName) end)
        end
    end
    local ok, item = pcall(function() return body:getItem() end)
    if ok and item then
        local itemData = item:getModData()
        local itemChanged = itemData[SO.MOD_DATA.CORPSE_OWNER] ~= identity
            or tonumber(itemData[SO.MOD_DATA.CORPSE_ONLINE_ID]) ~= tonumber(onlineId)
            or itemData[SO.MOD_DATA.CORPSE_PLAYER_NAME] ~= playerName
        itemData[SO.MOD_DATA.CORPSE_OWNER] = identity
        itemData[SO.MOD_DATA.CORPSE_ONLINE_ID] = onlineId
        itemData[SO.MOD_DATA.CORPSE_PLAYER_NAME] = playerName
        if displayName and item.setName then
            local nameOk, itemName = pcall(function() return item:getName() end)
            local customOk, customName = pcall(function() return item:isCustomName() end)
            if not nameOk or itemName ~= displayName or not customOk or customName ~= true then
                itemChanged = true
                pcall(function()
                    item:setName(displayName)
                    item:setCustomName(true)
                end)
            end
        end
        -- getItem() serializes the IsoDeadBody into the draggable item's
        -- byteData. Rewrite it after tagging so reloading that item restores a
        -- tagged body as well as retaining the item's own persistent modData.
        if (bodyChanged or itemChanged) and item.storeInByteData then
            pcall(function() item:storeInByteData(body) end)
        end
    end
    -- Only broadcast when the tag actually changed, and only for a corpse remote
    -- clients can resolve -- see transmitBodyModData. The periodic audit runs
    -- every ten seconds, so an unguarded transmit here spammed the server log.
    if bodyChanged then transmitBodyModData(body) end
    return true
end

-- A normal world corpse must never inherit a partial player label. This only
-- removes this mod's incomplete identity data; ordinary vanilla names and data
-- owned by other mods are left untouched.
local function clearUnverifiedPlayerLabel(body)
    if not body or not instanceof(body, "IsoDeadBody") then return false end
    local md = body:getModData()
    if not md or md[SO.MOD_DATA.CORPSE_OWNER] ~= nil then return false end
    if md[SO.MOD_DATA.CORPSE_PLAYER_NAME] == nil and md[SO.MOD_DATA.CORPSE_ONLINE_ID] == nil then return false end

    md[SO.MOD_DATA.CORPSE_PLAYER_NAME] = nil
    md[SO.MOD_DATA.CORPSE_ONLINE_ID] = nil
    if body.setName then pcall(function() body:setName(nil) end) end

    local ok, item = pcall(function() return body:getItem() end)
    if ok and item then
        local itemData = item:getModData()
        itemData[SO.MOD_DATA.CORPSE_OWNER] = nil
        itemData[SO.MOD_DATA.CORPSE_ONLINE_ID] = nil
        itemData[SO.MOD_DATA.CORPSE_PLAYER_NAME] = nil
        pcall(function()
            item:setName(item:getScriptItem():getDisplayName())
            item:setCustomName(false)
        end)
        if item.storeInByteData then pcall(function() item:storeInByteData(body) end) end
    end
    transmitBodyModData(body)
    return true
end

local function corpseKey(body)
    local ok, objectId = pcall(function() return body:getObjectIDAsLong() end)
    if ok and objectId ~= nil then return "id:" .. tostring(objectId) end
    return "object:" .. tostring(body)
end

local function anchorMatchesBody(anchor, body, now)
    if not anchor or not anchor.identity or not anchor.at then return false end
    if now - anchor.at > PLAYER_ANCHOR_MAX_AGE_MS then return false end
    if math.floor(tonumber(anchor.z) or -999) ~= math.floor(body:getZ()) then return false end
    local dx, dy = body:getX() - anchor.x, body:getY() - anchor.y
    return dx * dx + dy * dy <= CORPSE_ANCHOR_DISTANCE_SQUARED
end

local function findLiveIdentity(body, onlineId, now)
    if onlineId < 0 then return nil end
    if isServer() then
        local players = getOnlinePlayers()
        if players then
            for index = 0, players:size() - 1 do
                local player = players:get(index)
                local playerIdentity, playerOnlineId = rememberPlayerIdentity(player, now)
                if playerOnlineId == onlineId then
                    local anchor = Ledger.PlayerAnchorsByOnlineId[onlineId]
                    if anchorMatchesBody(anchor, body, now) then return playerIdentity, anchor.playerName end
                end
            end
        end
    end
    local anchor = Ledger.PlayerAnchorsByOnlineId[onlineId]
    if anchorMatchesBody(anchor, body, now) then return anchor.identity, anchor.playerName end
    return nil
end

local function resolveCorpseOwner(body, onlineId)
    local now = SO.Util.NowMs()
    if onlineId >= 0 then
        local recent = Ledger.RecentDeaths[onlineId]
        if anchorMatchesBody(recent, body, now) then return recent.identity, recent.onlineId, recent.playerName end
        local liveIdentity, liveName = findLiveIdentity(body, onlineId, now)
        if liveIdentity then return liveIdentity, onlineId, liveName end
    end

    -- Single-player/local IDs may be -1. Resolve those only by a fresh nearby
    -- authoritative death, avoiding a shared -1 map entry that could identify
    -- one local player's corpse as another's.
    local bestDistance, best = 9, nil
    for _, candidate in ipairs(Ledger.RecentDeathCandidates) do
        if now - candidate.at < 120000 and math.floor(candidate.z) == math.floor(body:getZ()) then
            local dx, dy = body:getX() - candidate.x, body:getY() - candidate.y
            local distance = dx * dx + dy * dy
            if distance < bestDistance then bestDistance, best = distance, candidate end
        end
    end
    if best then return best.identity, best.onlineId, best.playerName end
    return nil, onlineId
end

local function tryTagPlayerCorpse(body)
    local existingOwner = body:getModData()[SO.MOD_DATA.CORPSE_OWNER]
    local onlineId = tonumber(body:getCharacterOnlineID()) or -1
    if existingOwner then
        local taggedOnlineId = tonumber(body:getModData()[SO.MOD_DATA.CORPSE_ONLINE_ID]) or onlineId
        -- Also repairs the draggable corpse item's metadata after loading an
        -- older corpse that only had the IsoDeadBody tag.
        local playerName = body:getModData()[SO.MOD_DATA.CORPSE_PLAYER_NAME]
        if not playerName then
            local anchor = Ledger.PlayerAnchorsByOnlineId[taggedOnlineId]
            local now = SO.Util.NowMs()
            if anchorMatchesBody(anchor, body, now) then playerName = anchor.playerName end
        end
        -- Migrate corpses tagged by the previous version: the stable owner is
        -- already proven, so any current anchor for that same identity can
        -- safely supply the missing visible username regardless of location.
        if not playerName then
            for _, anchor in pairs(Ledger.PlayerAnchorsByOnlineId) do
                if anchor.identity == existingOwner and anchor.playerName then
                    playerName = anchor.playerName
                    break
                end
            end
        end
        return setCorpseOwner(body, existingOwner, taggedOnlineId, playerName), existingOwner, taggedOnlineId,
            "copied-player-mod-data", playerName
    end
    local identity, resolvedOnlineId, playerName = resolveCorpseOwner(body, onlineId)
    if not identity then return false, nil, onlineId end
    setCorpseOwner(body, identity, resolvedOnlineId, playerName)
    return true, identity, resolvedOnlineId, "id-location-repair", playerName
end

function Ledger.TagPlayerCorpse(body, source)
    if not isPlayerCorpse(body) then
        clearUnverifiedPlayerLabel(body)
        return false
    end
    local key = corpseKey(body)
    local ok, tagged, owner, onlineId, ownerSource, playerName = pcall(tryTagPlayerCorpse, body)
    if ok and tagged then
        Ledger.PendingPlayerCorpses[key] = nil
        if not Ledger.LoggedPlayerCorpseTags[key] then
            Ledger.LoggedPlayerCorpseTags[key] = true
            SO.Logger.Debug("Verified server player corpse owner", {
                player = owner,
                playerName = playerName,
                onlineId = onlineId,
                corpseId = key,
                ownerSource = ownerSource,
                observedBy = source or "observed",
            })
        end
        return true
    end

    local now = SO.Util.NowMs()
    local pending = Ledger.PendingPlayerCorpses[key]
    if not pending then
        pending = {
            body = body,
            firstSeenAt = now,
            lastAttemptAt = now,
            lastWarningAt = 0,
            attempts = 1,
            source = source or "observed",
            onlineId = tonumber(body:getCharacterOnlineID()) or -1,
        }
        Ledger.PendingPlayerCorpses[key] = pending
        SO.Logger.Debug("Queued untagged server player corpse", {
            corpseId = key,
            onlineId = pending.onlineId,
            source = pending.source,
        })
    else
        pending.body = body
        pending.lastAttemptAt = now
        pending.attempts = pending.attempts + 1
    end
    if not ok then pending.lastError = tostring(tagged) end
    return false
end

function Ledger.ProcessPendingPlayerCorpses()
    local now = SO.Util.NowMs()
    for key, pending in pairs(Ledger.PendingPlayerCorpses) do
        if now - pending.lastAttemptAt >= CORPSE_RETRY_MS then
            if not Ledger.TagPlayerCorpse(pending.body, pending.source) then
                pending = Ledger.PendingPlayerCorpses[key]
                if pending and now - pending.firstSeenAt >= CORPSE_WARNING_MS
                    and (pending.lastWarningAt == 0
                        or now - pending.lastWarningAt >= CORPSE_WARNING_REPEAT_MS) then
                    pending.lastWarningAt = now
                    SO.Logger.Warn("Server player corpse remains untagged; retrying", {
                        corpseId = key,
                        onlineId = pending.onlineId,
                        attempts = pending.attempts,
                        error = pending.lastError,
                        source = pending.source,
                    })
                end
            end
        end
    end
end

function Ledger.AuditLoadedPlayerCorpses(source)
    local cell = getCell()
    local objects = cell and cell:getObjectListForLua()
    local observed, tagged = 0, 0
    SO.Util.ForEachJavaOrLuaList(objects, function(object)
        if object and instanceof(object, "IsoDeadBody") then
            if isPlayerCorpse(object) then observed = observed + 1 end
            -- Tag verified player bodies and strip incomplete player labels from
            -- ordinary bodies left behind by an older or interrupted tagging pass.
            if Ledger.TagPlayerCorpse(object, source or "loaded-audit") then tagged = tagged + 1 end
        end
    end)
    SO.Logger.Debug("Audited loaded server player corpses", {
        observed = observed,
        tagged = tagged,
        pending = SO.Util.TableCount(Ledger.PendingPlayerCorpses),
        source = source or "loaded-audit",
    })
    return observed, tagged
end

function Ledger.GetCorpseOwner(item)
    if not item then return nil end
    local ok, body = pcall(function() return item:getDeadBodyObject() end)
    if not ok or not isPlayerCorpse(body) then return nil end
    local itemData = item:getModData()
    local owner = itemData and itemData[SO.MOD_DATA.CORPSE_OWNER]
    if owner then return Ledger.CanonicalIdentity(owner) end
    Ledger.TagPlayerCorpse(body, "owner-lookup")
    local bodyData = body:getModData()
    owner = bodyData and bodyData[SO.MOD_DATA.CORPSE_OWNER]
    if owner then return Ledger.CanonicalIdentity(owner) end
    return nil
end

function Ledger.GetPlayerCorpseRecoveryStrength(player, victimIdentity)
    local identity = Ledger.GetIdentity(player)
    if not identity or not victimIdentity then return 0, 0 end
    local record = SO.Storage.GetPlayer(identity)
    local uses = math.max(0, math.floor(tonumber(record.playerCorpseSacrifices[victimIdentity]) or 0))
    local decaySteps = math.max(0, uses - REPEATED_VICTIM_FULL_STRENGTH_USES + 1)
    local strength = 100 * (REPEATED_VICTIM_MULTIPLIER ^ decaySteps)
    strength = math.floor(strength * 10 + 0.5) / 10
    return strength, uses
end

local function hasTargetGap(record, current, requestedStrength)
    local hasSnapshot = SO.Util.TableCount(record.recoveryCeilingXP) > 0
    if hasSnapshot then
        for perkName, ceilingValue in pairs(record.recoveryCeilingXP) do
            local baseline = tonumber(record.recoveryBaselineXP[perkName]) or 0
            local ceiling = tonumber(ceilingValue) or baseline
            local desired = baseline + math.max(0, ceiling - baseline) * requestedStrength / 100
            if desired > (tonumber(current[perkName]) or 0) + 0.0001 then return true end
        end
        return false
    end
    for perkName, best in pairs(record.bestXP) do
        if (tonumber(best) or 0) > (tonumber(current[perkName]) or 0) + 0.0001 then return true end
    end
    return false
end

-- Plans an offering without changing the ledger. Additive animal and rare-item
-- sacrifices advance the life total by their contribution up to a tier cap.
-- Player corpses instead establish an absolute target so combining a small
-- offering with a repeated corpse cannot erase that corpse's decay.
function Ledger.PlanRecovery(player, recoveryStrength, recoveryCap, additive)
    local identity = Ledger.GetIdentity(player)
    if not identity then return false, "identity", 0, 0 end
    local record = SO.Storage.GetPlayer(identity)
    local current = Ledger.ReadXP(player)
    recoveryStrength = SO.Util.Clamp(tonumber(recoveryStrength) or 0, 0, 100)
    recoveryCap = SO.Util.Clamp(tonumber(recoveryCap) or 100, 0, 100)

    -- Per-life cumulative tiers are the only progression: each life a player
    -- climbs from animal offerings (to the rare-item ceiling) to rare items (to
    -- full recovery), and further attempts past a redeemed tier draw wrath.
    -- Death resets the redeemed total.
    ensureRecoveryGeneration(record)
    local redeemed = SO.Util.Clamp(tonumber(record.recoveryStrengthRedeemed) or 0, 0, 100)
    local target
    if additive then
        if recoveryStrength <= 0 then return false, "gap", redeemed, 0 end
        if redeemed >= recoveryCap - 0.0001 then return false, "cap", redeemed, 0 end
        target = math.min(recoveryCap, redeemed + recoveryStrength)
    else
        target = math.min(recoveryCap, math.max(redeemed, recoveryStrength))
        if target <= redeemed + 0.0001 then return false, "strength", redeemed, 0 end
    end
    if target <= redeemed + 0.0001 then return false, "cap", redeemed, 0 end
    if not hasTargetGap(record, current, target) then return false, "gap", redeemed, 0 end
    return true, nil, target, target - redeemed
end

function Ledger.RecordPlayerCorpseSacrifices(player, victims)
    local identity = Ledger.GetIdentity(player)
    if not identity then return false end
    local record = SO.Storage.GetPlayer(identity)
    local recorded = 0
    for _, victimIdentity in ipairs(victims or {}) do
        if victimIdentity and victimIdentity ~= identity then
            local uses = math.max(0, math.floor(tonumber(record.playerCorpseSacrifices[victimIdentity]) or 0))
            record.playerCorpseSacrifices[victimIdentity] = uses + 1
            recorded = recorded + 1
        end
    end
    return recorded > 0
end

function Ledger.HasRecoverableGap(player, requestedStrength)
    local recoverable, reason = Ledger.PlanRecovery(player, requestedStrength, 100, false)
    return recoverable, reason
end

function Ledger.Recover(player, recoveryStrength)
    local identity = Ledger.GetIdentity(player)
    if not identity then return false, 0 end
    local canRecover = Ledger.HasRecoverableGap(player, recoveryStrength)
    if not canRecover then return false, 0 end

    local record = SO.Storage.GetPlayer(identity)
    local current = Ledger.ReadXP(player)
    recoveryStrength = SO.Util.Clamp(tonumber(recoveryStrength) or 0, 0, 100)
    local totalAdded = 0

    ensureRecoveryGeneration(record)
    -- Snapshot the life's floor (XP now) and ceiling (personal best) on the first
    -- redemption; later tiers this life fill from that same fixed pair, so
    -- naturally earned XP between rituals is never clawed back or double-paid.
    if SO.Util.TableCount(record.recoveryCeilingXP) == 0 then
        record.recoveryBaselineXP = copyNumberMap(current)
        record.recoveryCeilingXP = copyNumberMap(record.bestXP)
    end

    for perkName, ceilingValue in pairs(record.recoveryCeilingXP) do
        local currentValue = tonumber(current[perkName]) or 0
        local baseline = tonumber(record.recoveryBaselineXP[perkName]) or 0
        local ceiling = tonumber(ceilingValue) or baseline
        local desired = baseline + math.max(0, ceiling - baseline) * recoveryStrength / 100
        local amount = math.max(0, desired - currentValue)
        if amount > 0 then
            local perkType = Perks.FromString(perkName)
            if perkType and perkType ~= Perks.None then
                player:getXp():AddXP(perkType, amount, false, false, false, false)
                totalAdded = totalAdded + amount
            end
        end
    end
    record.recoveryStrengthRedeemed = math.max(record.recoveryStrengthRedeemed, recoveryStrength)

    record.recoveredGeneration = record.deathGeneration
    local _, total = Ledger.ReadXP(player)
    record.lastTotalXP = total
    -- The offering run's "success" EndRun already carries the player-facing
    -- summary at INFO; keep this detailed breakdown at DEBUG.
    SO.Logger.Debug("Applied skill recovery", {
        player = identity,
        recoveryStrength = recoveryStrength,
        xpAdded = string.format("%.2f", totalAdded),
        generation = record.deathGeneration,
    })
    return true, totalAdded
end

local function samplePlayer(player)
    if not player then return end
    local identity = rememberPlayerIdentity(player)
    if not identity then return end
    local record = SO.Storage.GetPlayer(identity)
    local currentXP, total = Ledger.ReadXP(player)
    local hours = tonumber(player:getHoursSurvived()) or 0
    local lifeReset = record.lastHours and hours + 0.01 < record.lastHours and
        record.lastTotalXP and total + 0.01 < record.lastTotalXP

    if lifeReset then
        if record.awaitingRespawn then
            record.awaitingRespawn = false
        else
            record.deathGeneration = record.deathGeneration + 1
            resetRecoveryProgress(record)
            record.lastDeathMs = SO.Util.NowMs()
            SO.Logger.Warn("Inferred a missed death from authoritative life reset", {
                player = identity,
                generation = record.deathGeneration,
            })
        end
    end

    for perkName, value in pairs(currentXP) do
        if value > (tonumber(record.bestXP[perkName]) or 0) then record.bestXP[perkName] = value end
    end
    record.lastHours = hours
    record.lastTotalXP = total
end

function Ledger.SampleOnlinePlayers()
    if isServer() then
        local players = getOnlinePlayers()
        for index = 0, players:size() - 1 do samplePlayer(players:get(index)) end
    else
        samplePlayer(getPlayer())
    end
    local now = SO.Util.NowMs()
    for onlineId, recent in pairs(Ledger.RecentDeaths) do
        scanRecentCorpse(recent)
        if now - recent.at > 600000 then Ledger.RecentDeaths[onlineId] = nil end
    end
    for index = #Ledger.RecentDeathCandidates, 1, -1 do
        if now - Ledger.RecentDeathCandidates[index].at > 600000 then
            table.remove(Ledger.RecentDeathCandidates, index)
        end
    end
    Ledger.AuditLoadedPlayerCorpses("minute-audit")
end

local function onPlayerDeath(player)
    local _, recent = Ledger.RecordDeath(player, "server-event")
    scanRecentCorpse(recent)
end
local function onObjectAdded(object) Ledger.TagPlayerCorpse(object, "object-added") end

local nextAnchorRefreshAt = 0

local function onTick()
    local now = SO.Util.NowMs()
    -- B42's IsoPlayer.OnDeath() returns before emitting the Lua OnPlayerDeath
    -- event on a dedicated server. Stamp every authoritative IsoPlayer before
    -- corpse construction, and keep position anchors for repairing legacy or
    -- unusually ordered bodies -- but at 4 Hz, not once per tick.
    if now >= nextAnchorRefreshAt then
        nextAnchorRefreshAt = now + ANCHOR_REFRESH_MS
        Ledger.CaptureOnlinePlayerAnchors()
    end
    Ledger.ProcessPendingDeaths()
    Ledger.ProcessPendingPlayerCorpses()
    if now >= Ledger.NextCorpseSweepAt then
        Ledger.NextCorpseSweepAt = now + CORPSE_AUDIT_MS
        Ledger.AuditLoadedPlayerCorpses("periodic-audit")
    end
end

local function onServerStarted()
    Ledger.CaptureOnlinePlayerAnchors()
    Ledger.NextCorpseSweepAt = SO.Util.NowMs() + CORPSE_AUDIT_MS
    Ledger.AuditLoadedPlayerCorpses("server-start")
end

-- Supplemental only (single-player and alternate engine paths). This is not
-- the dedicated-server guarantee; CaptureOnlinePlayerAnchors plus corpse
-- observation is.
if Events.OnPlayerDeath then Events.OnPlayerDeath.Add(onPlayerDeath) end
if Events.OnObjectAdded then Events.OnObjectAdded.Add(onObjectAdded) end
if Events.OnDeadBodySpawn then Events.OnDeadBodySpawn.Add(onObjectAdded) end
if Events.OnServerStarted then Events.OnServerStarted.Add(onServerStarted) end
Events.OnTick.Add(onTick)
Events.EveryOneMinute.Add(Ledger.SampleOnlinePlayers)

return Ledger
