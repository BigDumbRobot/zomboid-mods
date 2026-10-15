-- KIPN_LeaderboardService.lua
--
-- Server-authoritative per-player leaderboard: longest alive,
-- most zombie kills, most PvP kills. Backs the Server Stats
-- terminal screen's leaderboard section.
--
-- DATA MODEL:
--
-- Persisted under KIPN.Server.GetData().playerStats, keyed by
-- steamId (falling back to "name:<username>" on non-Steam/LAN
-- servers where getSteamID() is unavailable/zero). Each row is
-- { username, zombieKills, longestAliveHours, pvpKills, deaths,
-- lastSeenMs }. No coordinates, safehouse data, or other
-- positional information is ever read or stored here.
--
-- zombieKills / longestAliveHours are stored as personal-best
-- high-water-marks (max-so-far), not raw overwrites: vanilla
-- getZombieKills()/getHoursSurvived() are per-life counters that
-- reset to 0 on respawn, so overwriting would erase a player's
-- record the moment they die and start a new life.
--
-- pvpKills / deaths only ever increment. There is no anti-grief
-- scoring (team-kill/repeat-victim penalties) -- that is a
-- database-backed feature in the reference mod this was modeled
-- after and is out of scope for KIPN's pure-Lua persistence.
--
-- PVP KILL ATTRIBUTION:
--
-- Vanilla Project Zomboid has no "on kill" event. Attribution is
-- derived the same way KIPN_CombatZoneService already listens for
-- combat: Events.OnWeaponHitCharacter fires server-side on every
-- landed hit, before damage math runs, so this service records the
-- most recent player-vs-player hit in a small transient (never
-- persisted) table keyed by the victim's identity. When
-- Events.OnCharacterDeath later fires for that same player, if a
-- recent-enough attacker is on file, the kill is credited to them.
-- This is a last-hit heuristic, not a verified damage-source query
-- (PZ does not expose one) -- adequate for a leaderboard, not for
-- anti-grief enforcement.
--
-- POLLING:
--
-- GET_LEADERBOARD (handleGetLeaderboard) re-polls every currently
-- online player's live zombieKills/hoursSurvived on every request,
-- exactly like KIPN_Server.lua's own handleGetOnlinePlayers
-- enumerates getOnlinePlayers(). This is what gives the Server
-- Stats page fresh numbers every time it's opened, per its stated
-- responsibility. Offline players simply keep their last-known
-- values.

if isClient() and not isServer() then
    return
end

require "KIPN_Shared"
require "KIPN_StatsCatalog"
require "KIPN_Server"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

KIPN.Server.LeaderboardService = KIPN.Server.LeaderboardService or {}

local LeaderboardService = KIPN.Server.LeaderboardService

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local logger =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("LeaderboardService")
    or nil

local function logError(message)
    if logger then
        logger:Error(message)
    else
        print("[KIPN LEADERBOARD] ERROR: " .. tostring(message))
    end
end

------------------------------------------------------------
-- CONSTANTS
------------------------------------------------------------

local TOP_N = 5

-- How long a recorded hit remains eligible to be credited as the
-- killing blow if the victim dies shortly after.
local ATTRIBUTION_WINDOW_MS = 20000

-- GET_LEADERBOARD is served from a short-lived cache. Rebuilding the
-- payload walks the entire (lifetime) playerStats table many times
-- over -- once per leaderboard field plus once per cumulative/peak
-- total -- so an uncached rebuild on every screen-open scales with
-- total players ever seen. Leaderboard numbers do not need to be
-- real-time; this bounds the work to at most once per interval
-- regardless of how many players request it.
local LEADERBOARD_CACHE_TTL_MS = 15000

local leaderboardCache = nil
local leaderboardCacheAtMs = nil

local function leaderboardNowMs()
    if type(getTimestampMs) ~= "function" then
        return 0
    end

    local ok, value = pcall(getTimestampMs)

    if ok and type(value) == "number" then
        return value
    end

    return 0
end

------------------------------------------------------------
-- TRANSIENT PVP ATTACKER TRACKING
--
-- Keyed by victim identity key. Never persisted -- this is only
-- meaningful for the few seconds between a hit and a death.
------------------------------------------------------------

local lastAttacker = {}

------------------------------------------------------------
-- IDENTITY RESOLUTION
--
-- Mirrors the defensive username/steamId resolution already used
-- in KIPN_Server.lua's handleGetOnlinePlayers.
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

------------------------------------------------------------
-- PERSISTED ROW ACCESS
------------------------------------------------------------

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
            zombieKills = 0,
            longestAliveHours = 0,
            pvpKills = 0,
            deaths = 0,
            lastSeenMs = 0,
        }

        data.playerStats[identity.key] = row
    end

    row.username = identity.username

    return row
end

------------------------------------------------------------
-- WEAPON HIT HANDLER
--
-- A second, independent listener from KIPN_CombatZoneService's own
-- OnWeaponHitCharacter hook -- PZ allows multiple listeners on the
-- same event.
------------------------------------------------------------

local function onWeaponHitCharacter(attacker, victim, _weapon, _damage)
    if not victim or not instanceof(victim, "IsoPlayer") then
        return
    end

    if not attacker or not instanceof(attacker, "IsoPlayer") then
        return
    end

    local victimIdentity = resolvePlayerIdentity(victim)
    local attackerIdentity = resolvePlayerIdentity(attacker)

    if not victimIdentity or not attackerIdentity then
        return
    end

    if victimIdentity.key == attackerIdentity.key then
        -- Self-damage is never a PvP kill.
        return
    end

    lastAttacker[victimIdentity.key] = {
        key = attackerIdentity.key,
        steamId = attackerIdentity.steamId,
        username = attackerIdentity.username,
        atMs = getTimestampMs and getTimestampMs() or 0,
    }
end

------------------------------------------------------------
-- DEATH HANDLER
------------------------------------------------------------

local function onCharacterDeath(character)
    if not character or not instanceof(character, "IsoPlayer") then
        return
    end

    local victimIdentity = resolvePlayerIdentity(character)

    if not victimIdentity then
        return
    end

    local data = KIPN.Server.GetData()

    if type(data) ~= "table" then
        logError("onCharacterDeath: server data unavailable.")
        return
    end

    local victimRow = getOrCreatePlayerStat(data, victimIdentity)

    local hoursSurvived = nil

    if type(character.getHoursSurvived) == "function" then
        local ok, result = pcall(function() return character:getHoursSurvived() end)

        if ok and type(result) == "number" then
            hoursSurvived = result
        end
    end

    if hoursSurvived and hoursSurvived > (victimRow.longestAliveHours or 0) then
        victimRow.longestAliveHours = hoursSurvived
    end

    victimRow.deaths = (victimRow.deaths or 0) + 1

    local attribution = lastAttacker[victimIdentity.key]

    lastAttacker[victimIdentity.key] = nil

    if attribution then
        local now = getTimestampMs and getTimestampMs() or 0

        if now - (attribution.atMs or 0) <= ATTRIBUTION_WINDOW_MS then
            local attackerRow = getOrCreatePlayerStat(data, {
                key = attribution.key,
                steamId = attribution.steamId,
                username = attribution.username,
            })

            attackerRow.pvpKills = (attackerRow.pvpKills or 0) + 1
        end
    end

    -- Only playerStats changed here -- persist/transmit that slice, not
    -- a full re-broadcast of every subsystem on every death.
    if type(KIPN.Server.Save) == "function" then
        pcall(KIPN.Server.Save, "playerStats")
    end

    leaderboardCache = nil
end

------------------------------------------------------------
-- LIVE SYNC OF ONLINE PLAYERS
--
-- Reuses the same defensive getOnlinePlayers() enumeration style
-- as KIPN_Server.lua's handleGetOnlinePlayers -- name/steamId only,
-- never position.
------------------------------------------------------------

local function syncOnlinePlayers(data)
    if type(getOnlinePlayers) ~= "function" then
        logError("syncOnlinePlayers: getOnlinePlayers() unavailable.")
        return
    end

    local okPlayers, onlinePlayers = pcall(getOnlinePlayers)

    if not okPlayers or not onlinePlayers or type(onlinePlayers.size) ~= "function" then
        logError("syncOnlinePlayers: failed to resolve online players.")
        return
    end

    local count = onlinePlayers:size()

    for i = 0, count - 1 do
        local okPlayer, p = pcall(function() return onlinePlayers:get(i) end)

        if okPlayer and p then
            local identity = resolvePlayerIdentity(p)

            if identity then
                local row = getOrCreatePlayerStat(data, identity)

                row.lastSeenMs = getTimestampMs and getTimestampMs() or 0

                if type(p.getZombieKills) == "function" then
                    local okZ, zombieKills = pcall(function() return p:getZombieKills() end)

                    if okZ and type(zombieKills) == "number"
                        and zombieKills > (row.zombieKills or 0) then
                        row.zombieKills = zombieKills
                    end
                end

                if type(p.getHoursSurvived) == "function" then
                    local okH, hoursSurvived = pcall(function() return p:getHoursSurvived() end)

                    if okH and type(hoursSurvived) == "number"
                        and hoursSurvived > (row.longestAliveHours or 0) then
                        row.longestAliveHours = hoursSurvived
                    end
                end

                -- Tier A fields (see shared/KIPN_StatsCatalog.lua) --
                -- read live off every online player here too, so
                -- server-wide totals/leaderboards reflect them even
                -- for players who never opened the Player tab
                -- themselves. KIPN_StatsService.lua does the same
                -- read for the specific calling player on GET_MY_STATS;
                -- this is the "everyone currently online" counterpart.
                if type(KIPN.Server.StatsService) == "table"
                    and type(KIPN.Server.StatsService.ReadTierAFields) == "function" then

                    pcall(KIPN.Server.StatsService.ReadTierAFields, p, row)
                end
            end
        elseif not okPlayer then
            logError("syncOnlinePlayers: failed to resolve player index " .. tostring(i) .. ".")
        end
    end
end

------------------------------------------------------------
-- TOP-N RANKING
------------------------------------------------------------

local function buildTopList(data, field)
    local rows = {}

    for _, row in pairs(data.playerStats or {}) do
        if type(row) == "table" then
            rows[#rows + 1] = row
        end
    end

    table.sort(rows, function(a, b)
        local av = tonumber(a[field]) or 0
        local bv = tonumber(b[field]) or 0

        if av == bv then
            return tostring(a.username or "") < tostring(b.username or "")
        end

        return av > bv
    end)

    local top = {}

    for i = 1, math.min(TOP_N, #rows) do
        local row = rows[i]
        local value = tonumber(row[field]) or 0

        if value > 0 then
            top[#top + 1] = {
                username = row.username,
                value = value,
            }
        end
    end

    return top
end

------------------------------------------------------------
-- STATS CATALOG AGGREGATION
--
-- Generalizes the top-5 lists and the totals table over
-- KIPN.Shared.StatsCatalog instead of hand-listing fields, so a new
-- catalog entry needs no change here. See shared/KIPN_StatsCatalog.lua.
--
-- "totals" covers every enabled cumulative/peak field: cumulative
-- fields are summed, peak fields report the server-wide record
-- (max), matching KIPN_ServerStats.lua's rendering of that table.
-- "live"/"peakPerKey" fields (bodyWeight, favoriteWeapon, etc.) are
-- Player-tab-only and are skipped here.
------------------------------------------------------------

local function buildTotals(data)
    local totals = {}
    local trackedPlayers = 0

    for _, row in pairs(data.playerStats or {}) do
        if type(row) == "table" then
            trackedPlayers = trackedPlayers + 1
        end
    end

    for _, entry in ipairs(KIPN.Shared.StatsCatalog) do
        if entry.mergeStrategy == "cumulative" then
            local sum = 0

            for _, row in pairs(data.playerStats or {}) do
                if type(row) == "table" then
                    sum = sum + (tonumber(row[entry.dataKey]) or 0)
                end
            end

            totals[entry.id] = sum

        elseif entry.mergeStrategy == "peak" then
            local best = 0

            for _, row in pairs(data.playerStats or {}) do
                if type(row) == "table" then
                    local value = tonumber(row[entry.dataKey]) or 0

                    if value > best then
                        best = value
                    end
                end
            end

            totals[entry.id] = best
        end
    end

    totals.trackedPlayers = trackedPlayers

    return totals
end

------------------------------------------------------------
-- GET LEADERBOARD
------------------------------------------------------------

local function handleGetLeaderboard(player, _args)
    local data = KIPN.Server.GetData()

    if type(data) ~= "table" then
        local sent = KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.ERROR,
            {
                code = "SERVER_DATA_UNAVAILABLE",
                message = "Server data is unavailable.",
            }
        )

        return sent
    end

    if type(data.playerStats) ~= "table" then
        data.playerStats = {}
    end

    --------------------------------------------------------
    -- SERVE FROM CACHE
    --------------------------------------------------------

    local now = leaderboardNowMs()

    if leaderboardCache
        and leaderboardCacheAtMs
        and (now - leaderboardCacheAtMs) < LEADERBOARD_CACHE_TTL_MS
    then
        return KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.LEADERBOARD_DATA,
            leaderboardCache
        )
    end

    --------------------------------------------------------
    -- REBUILD
    --------------------------------------------------------

    syncOnlinePlayers(data)

    -- Domain-scoped: syncOnlinePlayers only touched playerStats, so
    -- only that slice needs persisting/transmitting -- not a full
    -- re-broadcast of every subsystem on every leaderboard open.
    if type(KIPN.Server.Save) == "function" then
        pcall(KIPN.Server.Save, "playerStats")
    end

    local boards = {}

    for _, entry in ipairs(KIPN.Shared.StatsCatalog) do
        if entry.leaderboard then
            boards[entry.id] = buildTopList(data, entry.dataKey)
        end
    end

    local payload = {
        boards = boards,
        totals = buildTotals(data),

        -- Kept alongside `boards`/`totals` for backward compatibility
        -- with any older client build still reading these directly.
        longestAlive = boards.hoursSurvived,
        zombieKills = boards.zombieKills,
        pvpKills = boards.pvpKills,
    }

    leaderboardCache = payload
    leaderboardCacheAtMs = now

    local sent = KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.LEADERBOARD_DATA,
        payload
    )

    return sent
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

function LeaderboardService.Initialize()
    if LeaderboardService._initialized then
        return true
    end

    if Events and Events.OnWeaponHitCharacter then
        Events.OnWeaponHitCharacter.Add(onWeaponHitCharacter)
    else
        logError("Events.OnWeaponHitCharacter unavailable; PvP kills will not be tracked.")
    end

    if Events and Events.OnCharacterDeath then
        Events.OnCharacterDeath.Add(onCharacterDeath)
    else
        logError("Events.OnCharacterDeath unavailable; deaths/PvP kills will not be tracked.")
    end

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.GET_LEADERBOARD,
        handleGetLeaderboard
    )

    LeaderboardService._initialized = true

    return true
end

print("[KIPN] Leaderboard Service loaded")
