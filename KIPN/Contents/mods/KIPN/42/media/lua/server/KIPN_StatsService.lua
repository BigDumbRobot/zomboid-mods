-- KIPN_StatsService.lua
--
-- Per-player stats: "my own stats" request + Tier B delta merging.
-- Backs the Server Stats terminal screen's PLAYER tab.
--
-- DATA MODEL:
--
-- Shares the exact same KIPN.Server.GetData().playerStats table
-- KIPN_LeaderboardService.lua already owns (keyed by steamId,
-- falling back to "name:<username>"). This service does not
-- duplicate that identity resolution or ownership -- it reads/writes
-- the same rows.
--
-- Every stat's shape/merge behavior is defined once in
-- KIPN.Shared.StatsCatalog (shared/KIPN_StatsCatalog.lua). This
-- service is intentionally generic over that catalog rather than
-- hand-listing fields, so a new catalog entry needs no service code
-- change.
--
-- TIER A vs TIER B:
--
-- Tier A catalog entries (recipesKnown, booksRead, magazinesRead,
-- highestSkill, totalSkillLevels, bodyWeight, carryWeight, plus the
-- pre-existing zombieKills/hoursSurvived) are read live off the
-- IsoPlayer object passed into handleGetMyStats -- no client
-- tracking, no persistence needed for these.
--
-- Tier B catalog entries (distanceTravelled, itemsCrafted, etc.) are
-- accumulated client-side by KIPN_StatsTracker.lua and flushed here
-- via SUBMIT_STATS_DELTA, merged into the persisted row using each
-- entry's declared mergeStrategy. pvpKills/deaths are also Tier B
-- (read from the persisted row) but are populated by
-- KIPN_LeaderboardService.lua's own OnWeaponHitCharacter/
-- OnCharacterDeath handlers, never by SUBMIT_STATS_DELTA -- this
-- service does not touch those two fields.

if isClient() and not isServer() then
    return
end

require "KIPN_Shared"
require "KIPN_StatsCatalog"
require "KIPN_Server"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

KIPN.Server.StatsService = KIPN.Server.StatsService or {}

local StatsService = KIPN.Server.StatsService

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local logger =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("StatsService")
    or nil

local function logError(message)
    if logger then
        logger:Error(message)
    else
        print("[KIPN STATS] ERROR: " .. tostring(message))
    end
end

------------------------------------------------------------
-- FIELDS THIS SERVICE NEVER TOUCHES
--
-- Owned exclusively by KIPN_LeaderboardService.lua's own event
-- handlers -- never accepted from a client-submitted delta.
------------------------------------------------------------

local SERVER_OWNED_FIELDS = {
    pvpKills = true,
    deaths = true,
}

------------------------------------------------------------
-- IDENTITY RESOLUTION
--
-- Deliberately duplicated from KIPN_LeaderboardService.lua rather
-- than imported -- both services independently depend only on the
-- shared data.playerStats row shape, not on each other's internals.
------------------------------------------------------------

local function resolvePlayerIdentity(player)
    if not player then
        return nil
    end

    local username = nil

    if type(player.getUsername) == "function" then
        local ok, result = pcall(function() return player:getUsername() end)

        if ok and result and result ~= "" then
            username = result
        end
    end

    if not username and type(player.getDisplayName) == "function" then
        local ok, result = pcall(function() return player:getDisplayName() end)

        if ok and result then
            username = result
        end
    end

    if not username then
        username = tostring(player)
    end

    local steamId = nil

    if type(player.getSteamID) == "function" then
        local ok, result = pcall(function() return player:getSteamID() end)

        if ok and result ~= nil then
            steamId = tostring(result)
        end
    end

    -- Rows are filed under the server account (KIPN.Shared.GetPlayerId).
    -- legacyKeys are the Steam-based keys this player's row may still be
    -- under from before; getOrCreatePlayerStat moves it across.
    local key = KIPN.Shared.GetPlayerId(player)

    if not key or key == "" then
        key = "name:" .. username
    end

    local legacyKeys = KIPN.Shared.GetLegacyPlayerIds(player)

    return {
        key = key,
        steamId = steamId,
        username = username,
        legacyKeys = legacyKeys,
    }
end

local function getOrCreatePlayerStat(data, identity)
    if type(data.playerStats) ~= "table" then
        data.playerStats = {}
    end

    local row = data.playerStats[identity.key]

    if type(row) ~= "table" then
        -- This player's row from before identities became server
        -- accounts: the username it was written with must be theirs.
        for _, legacyKey in ipairs(identity.legacyKeys or {}) do
            local legacyRow = data.playerStats[legacyKey]

            if type(legacyRow) == "table"
                and (legacyRow.username == nil or legacyRow.username == identity.username)
            then
                data.playerStats[legacyKey] = nil
                data.playerStats[identity.key] = legacyRow
                legacyRow.legacyKey = legacyKey
                row = legacyRow
                print("[KIPN IDENTITY] player stats of " .. tostring(identity.username)
                    .. " moved from " .. tostring(legacyKey) .. " to " .. tostring(identity.key))
                break
            end
        end
    end

    if type(row) ~= "table" then
        row = {
            username = identity.username,
        }

        data.playerStats[identity.key] = row
    end

    row.username = identity.username

    return row
end

------------------------------------------------------------
-- TIER A -- LIVE READS OFF THE IsoPlayer OBJECT
------------------------------------------------------------

local function countLiterature(player)
    local books = 0
    local magazines = 0

    local ok, already = pcall(function() return player:getAlreadyReadBook() end)

    if not ok or not already then
        return books, magazines
    end

    local scripts = getScriptManager and getScriptManager() or nil
    local size = already:size()

    for i = 0, size - 1 do
        local fullType = tostring(already:get(i) or "")
        local script = scripts and scripts:getItem(fullType) or nil

        -- B42 recipe mags are named "*Mag1" etc. -- classify by the
        -- magazine tag, not by matching the item type string.
        if script and script:hasTag(ItemTag.MAGAZINE) then
            magazines = magazines + 1
        else
            books = books + 1
        end
    end

    return books, magazines
end

local function countKnownRecipes(player)
    local ok, list = pcall(function() return player:getKnownRecipes() end)

    if not ok or not list then
        return 0
    end

    if type(list.size) == "function" then
        return list:size() or 0
    end

    if type(list) == "table" then
        return #list
    end

    return 0
end

local function getSkills(player)
    local bestName = nil
    local bestLevel = -1
    local totalLevels = 0

    if not PerkFactory or not PerkFactory.PerkList then
        return nil, 0
    end

    local list = PerkFactory.PerkList

    for i = 0, list:size() - 1 do
        local perk = list:get(i)

        if perk and not perk:isPassiv() then
            local ok, level = pcall(function() return player:getPerkLevel(perk) end)

            if ok and type(level) == "number" then
                totalLevels = totalLevels + level

                if level > bestLevel then
                    bestLevel = level
                    bestName = perk:getName()
                elseif level == bestLevel and bestName and perk:getName() then
                    if tostring(perk:getName()) < tostring(bestName) then
                        bestName = perk:getName()
                    end
                end
            end
        end
    end

    return bestName, totalLevels
end

local function readTierAFields(player, row)
    if type(player.getZombieKills) == "function" then
        local ok, value = pcall(function() return player:getZombieKills() end)

        if ok and type(value) == "number" and value > (row.zombieKills or 0) then
            row.zombieKills = value
        end
    end

    if type(player.getHoursSurvived) == "function" then
        local ok, value = pcall(function() return player:getHoursSurvived() end)

        if ok and type(value) == "number" and value > (row.longestAliveHours or 0) then
            row.longestAliveHours = value
        end
    end

    local ok, recipes = pcall(countKnownRecipes, player)

    if ok and type(recipes) == "number" and recipes > (row.recipesKnown or 0) then
        row.recipesKnown = recipes
    end

    local okLit, books, magazines = pcall(countLiterature, player)

    if okLit then
        if type(books) == "number" and books > (row.booksRead or 0) then
            row.booksRead = books
        end

        if type(magazines) == "number" and magazines > (row.magazinesRead or 0) then
            row.magazinesRead = magazines
        end
    end

    local okSkills, highestSkill, totalLevels = pcall(getSkills, player)

    if okSkills then
        if highestSkill then
            row.highestSkill = tostring(highestSkill)
        end

        if type(totalLevels) == "number" and totalLevels > (row.totalSkillLevels or 0) then
            row.totalSkillLevels = totalLevels
        end
    end

    if type(player.getNutrition) == "function" then
        local okNut, nutrition = pcall(function() return player:getNutrition() end)

        if okNut and nutrition and type(nutrition.getWeight) == "function" then
            local okWeight, weight = pcall(function() return nutrition:getWeight() end)

            if okWeight and type(weight) == "number" then
                row.bodyWeight = weight
            end
        end
    end

    if type(player.getInventoryWeight) == "function" then
        local okCarry, carry = pcall(function() return player:getInventoryWeight() end)

        if okCarry and type(carry) == "number" then
            row.carryWeight = carry
        end
    end
end

-- Exported so KIPN_LeaderboardService.lua's syncOnlinePlayers() can
-- apply the same Tier A reads to every online player, not just the
-- one calling GET_MY_STATS.
StatsService.ReadTierAFields = readTierAFields

------------------------------------------------------------
-- GET MY STATS
------------------------------------------------------------

local function handleGetMyStats(player, _args)
    local data = KIPN.Server.GetData()

    if type(data) ~= "table" then
        return KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.ERROR,
            {
                code = "SERVER_DATA_UNAVAILABLE",
                message = "Server data is unavailable.",
            }
        )
    end

    local identity = resolvePlayerIdentity(player)

    if not identity then
        logError("handleGetMyStats: failed to resolve caller identity.")

        return KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.ERROR,
            {
                code = "IDENTITY_UNAVAILABLE",
                message = "Could not resolve player identity.",
            }
        )
    end

    local row = getOrCreatePlayerStat(data, identity)

    readTierAFields(player, row)

    if type(KIPN.Server.Save) == "function" then
        pcall(KIPN.Server.Save, "playerStats")
    end

    -- Send back a flat copy keyed by catalog dataKey rather than the
    -- raw row, so the client never needs to know about legacy
    -- storage field names (e.g. "longestAliveHours" -> "hoursSurvived").
    local payload = {
        username = row.username,
    }

    for _, entry in ipairs(KIPN.Shared.StatsCatalog) do
        payload[entry.id] = row[entry.dataKey]
    end

    return KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.MY_STATS_DATA,
        payload
    )
end

------------------------------------------------------------
-- SUBMIT STATS DELTA
--
-- Merges a client-flushed Tier B delta table into the persisted
-- row, applying each field's declared mergeStrategy.
------------------------------------------------------------

local function applyDelta(row, entry, incoming)
    if incoming == nil then
        return
    end

    if entry.mergeStrategy == "cumulative" then
        local delta = tonumber(incoming)

        if delta and delta > 0 then
            row[entry.dataKey] = (tonumber(row[entry.dataKey]) or 0) + delta
        end

        return
    end

    if entry.mergeStrategy == "peak" then
        local candidate = tonumber(incoming)

        if candidate and candidate > (tonumber(row[entry.dataKey]) or 0) then
            row[entry.dataKey] = candidate
        end

        return
    end

    if entry.mergeStrategy == "peakPerKey" then
        -- `incoming` may be a single weapon name, or an array of
        -- names -- KIPN_StatsTracker.lua batches every zombie kill
        -- credited since the last flush rather than only sending the
        -- most recent one, so a multi-kill flush interval doesn't
        -- undercount the other weapons used in it.
        local keys = incoming

        if type(keys) == "string" then
            keys = { keys }
        end

        if type(keys) ~= "table" then
            return
        end

        if type(row.weaponHitCounts) ~= "table" then
            row.weaponHitCounts = {}
        end

        for _, key in ipairs(keys) do
            if type(key) == "string" and key ~= "" then

                row.weaponHitCounts[key] =
                    (tonumber(row.weaponHitCounts[key]) or 0) + 1

                local bestName = row[entry.dataKey]
                local bestCount = bestName and row.weaponHitCounts[bestName] or -1

                if row.weaponHitCounts[key] > bestCount then
                    row[entry.dataKey] = key
                end
            end
        end

        return
    end

    -- "live" -- straight overwrite.
    row[entry.dataKey] = incoming
end

local function handleSubmitStatsDelta(player, args)
    if type(args) ~= "table" then
        return false
    end

    local data = KIPN.Server.GetData()

    if type(data) ~= "table" then
        logError("handleSubmitStatsDelta: server data unavailable.")
        return false
    end

    local identity = resolvePlayerIdentity(player)

    if not identity then
        logError("handleSubmitStatsDelta: failed to resolve caller identity.")
        return false
    end

    local row = getOrCreatePlayerStat(data, identity)

    for _, entry in ipairs(KIPN.Shared.StatsCatalog) do
        if entry.tier == "B" and not SERVER_OWNED_FIELDS[entry.id] then
            applyDelta(row, entry, args[entry.id])
        end
    end

    -- Keep the "last seen" stamp fresh for every active player so the
    -- retention sweep (KIPN_MaintenanceService.lua) can tell a genuinely
    -- abandoned row from a returning regular's. This handler fires every
    -- few seconds per online player.
    row.lastSeenMs = (getTimestampMs and getTimestampMs()) or row.lastSeenMs or 0

    if type(KIPN.Server.Save) == "function" then
        pcall(KIPN.Server.Save, "playerStats")
    end

    return true
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

function StatsService.Initialize()
    if StatsService._initialized then
        return true
    end

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.GET_MY_STATS,
        handleGetMyStats
    )

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.SUBMIT_STATS_DELTA,
        handleSubmitStatsDelta
    )

    StatsService._initialized = true

    return true
end

print("[KIPN] Stats Service loaded")
