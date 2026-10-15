-- KIPN_MaintenanceService.lua
--
-- Periodic housekeeping so a long-lived server's save does not grow
-- without bound. Fully automatic -- there is no manual trigger. One
-- sweep runs:
--
--   * ~2 minutes after the server finishes initializing, and
--   * on the interval set by SandboxVars.KIPN.MaintenanceFrequency
--     (every 15 min / hour / 6 h / startup-only; default hourly),
--     re-read each tick so a sandbox edit + restart takes effect.
--
-- Each sweep step is independently pcall-guarded and only logs when it
-- actually changed something. Every mutation is persisted with a
-- domain-scoped Save() -- never a full re-broadcast. A sweep on an
-- already-tidy server does a handful of table scans and writes
-- nothing, so even the most frequent setting is cheap; the interval
-- really only controls how promptly trimmed space is reclaimed and
-- how soon an orphaned claim's grace clock starts.
--
-- Sweep steps:
--   1. Expired login sessions            (data.sessions)
--   2. Consumed / expired validation keys (data.validationKeys)
--   3. Player-stats retention             (data.playerStats)
--   4. Expired claims                     (delegated to ClaimService)
--   5. Orphaned claims                    (delegated to ClaimService)
--
-- All age thresholds use real wall-clock milliseconds (getTimestampMs)
-- so "180 days" means 180 real days regardless of the world clock.

if isClient() and not isServer() then
    return
end

require "KIPN_Shared"
require "KIPN_Server"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.MaintenanceService = KIPN.Server.MaintenanceService or {}

local MaintenanceService = KIPN.Server.MaintenanceService

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local logger =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("MaintenanceService")
    or nil

local function logInfo(message)
    if logger then
        logger:Info(message)
    else
        print("[KIPN MAINTENANCE] " .. tostring(message))
    end
end

local function logError(message)
    if logger then
        logger:Error(message)
    else
        print("[KIPN MAINTENANCE] ERROR: " .. tostring(message))
    end
end

------------------------------------------------------------
-- CONSTANTS
------------------------------------------------------------

local DAY_MS = 86400 * 1000
local MINUTE_MS = 60 * 1000

-- Grace after init before the first sweep, so every companion service
-- has registered its claim types / data domains first. Independent of
-- the frequency setting -- one sweep always runs shortly after boot.
local FIRST_SWEEP_DELAY_MS = 2 * MINUTE_MS

-- SandboxVars.KIPN.MaintenanceFrequency enum index -> repeat interval.
-- STARTUP_ONLY means: run the one post-boot sweep, then never again
-- until the next server restart.
local STARTUP_ONLY = "startup_only"

local FREQUENCY_BY_INDEX = {
    [1] = 15 * MINUTE_MS,        -- Every 15 minutes
    [2] = 60 * MINUTE_MS,        -- Every hour  (default)
    [3] = 6 * 60 * MINUTE_MS,    -- Every 6 hours
    [4] = STARTUP_ONLY,          -- Only at server startup
}

local DEFAULT_SWEEP_INTERVAL_MS = FREQUENCY_BY_INDEX[2]

local DEFAULT_STATS_RETENTION_DAYS = 180
local DEFAULT_ORPHAN_GRACE_DAYS = 14

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------

local function nowMs()
    if type(getTimestampMs) ~= "function" then
        return 0
    end

    local ok, value = pcall(getTimestampMs)

    if ok and type(value) == "number" then
        return value
    end

    return 0
end

local function sandboxNumber(name, default)
    local ok, value = pcall(function()
        if SandboxVars and SandboxVars.KIPN then
            return SandboxVars.KIPN[name]
        end
        return nil
    end)

    if ok and type(value) == "number" then
        return value
    end

    return default
end

-- Set of identity keys (server account, and the older steamId /
-- "name:<user>" forms) currently online, so
-- a player who is connected right now is never pruned.
local function onlineIdentityKeys()
    local keys = {}

    if type(getOnlinePlayers) ~= "function" then
        return keys
    end

    local ok, players = pcall(getOnlinePlayers)

    if not ok or not players or type(players.size) ~= "function" then
        return keys
    end

    for i = 0, players:size() - 1 do
        local p = players:get(i)

        if p then
            local okName, name = pcall(function()
                return p:getUsername()
            end)

            if okName and name then
                keys["name:" .. tostring(name)] = true
            end

            local okId, id = pcall(KIPN.Shared.GetPlayerId, p)

            if okId and id then
                keys[tostring(id)] = true
            end

            -- Rows not yet moved to the account key keep their old one.
            local okSteam, steam = pcall(function()
                return p:getSteamID()
            end)

            if okSteam and steam and tostring(steam) ~= "0" then
                keys[tostring(steam)] = true
            end
        end
    end

    return keys
end

------------------------------------------------------------
-- SWEEP STEP 1 -- EXPIRED SESSIONS
------------------------------------------------------------
--
-- Defensive: the session store is currently a schema slot with no
-- writer, but if a session system is (re)introduced this already
-- keeps it tidy. Any entry with an `expiresAtMs` / `expiresAt` in the
-- past, or explicitly `{ revoked = true }`, is dropped.

local function sweepSessions(data)
    if type(data.sessions) ~= "table" then
        return 0
    end

    local now = nowMs()
    local removed = 0

    for id, session in pairs(data.sessions) do
        local drop = false

        if type(session) ~= "table" then
            drop = true
        elseif session.revoked == true then
            drop = true
        else
            local expiry =
                tonumber(session.expiresAtMs)
                or tonumber(session.expiresAt)

            if expiry and now > 0 and expiry < now then
                drop = true
            end
        end

        if drop then
            data.sessions[id] = nil
            removed = removed + 1
        end
    end

    return removed
end

------------------------------------------------------------
-- SWEEP STEP 2 -- STALE VALIDATION KEYS
------------------------------------------------------------
--
-- Drops keys flagged `consumed == true` or past an `expiresAtMs` /
-- `expiresAt`.

local function sweepValidationKeys(data)
    if type(data.validationKeys) ~= "table" then
        return 0
    end

    local now = nowMs()
    local removed = 0

    for id, key in pairs(data.validationKeys) do
        local drop = false

        if type(key) ~= "table" then
            drop = true
        elseif key.consumed == true then
            drop = true
        else
            local expiry =
                tonumber(key.expiresAtMs)
                or tonumber(key.expiresAt)

            if expiry and now > 0 and expiry < now then
                drop = true
            end
        end

        if drop then
            data.validationKeys[id] = nil
            removed = removed + 1
        end
    end

    return removed
end

------------------------------------------------------------
-- SWEEP STEP 3 -- PLAYER-STATS RETENTION
------------------------------------------------------------
--
-- Drops playerStats rows for identities not seen in
-- SandboxVars.KIPN.PlayerStatsRetentionDays real days. 0 disables.
-- A row with no usable lastSeenMs is stamped (not deleted) so it gets
-- a full retention window from the moment this first runs.

local function sweepPlayerStats(data)
    local retentionDays =
        sandboxNumber("PlayerStatsRetentionDays", DEFAULT_STATS_RETENTION_DAYS)

    if type(data.playerStats) ~= "table"
        or type(retentionDays) ~= "number"
        or retentionDays <= 0
    then
        return 0, 0
    end

    local now = nowMs()

    if now <= 0 then
        return 0, 0
    end

    local cutoff = now - (retentionDays * DAY_MS)
    local online = onlineIdentityKeys()

    local removed = 0
    local stamped = 0

    for key, row in pairs(data.playerStats) do
        if type(row) ~= "table" then
            data.playerStats[key] = nil
            removed = removed + 1
        elseif not online[tostring(key)] then

            local lastSeen = tonumber(row.lastSeenMs)

            if not lastSeen or lastSeen <= 0 then
                -- Unknown age -- give it a fair chance.
                row.lastSeenMs = now
                stamped = stamped + 1
            elseif lastSeen < cutoff then
                data.playerStats[key] = nil
                removed = removed + 1
            end
        end
    end

    return removed, stamped
end

------------------------------------------------------------
-- SWEEP
------------------------------------------------------------

local lastSweepMs = nil

function MaintenanceService.RunSweep(reason)

    local data = KIPN.Server.GetData and KIPN.Server.GetData() or nil

    if type(data) ~= "table" then
        logError("Sweep skipped: server data unavailable.")
        return nil
    end

    lastSweepMs = nowMs()

    local summary = {
        reason = tostring(reason or "scheduled"),
        sessionsRemoved = 0,
        validationKeysRemoved = 0,
        playerStatsRemoved = 0,
        playerStatsStamped = 0,
        claimsExpired = 0,
        claimsExpireFailed = 0,
        claimsFlagged = 0,
        claimsCleared = 0,
        claimsPurged = 0,
    }

    ----------------------------------------------------------
    -- 1 + 2: sessions and validation keys (same domain cost
    -- profile; persist each only if it changed)
    ----------------------------------------------------------

    local okS, s = pcall(sweepSessions, data)
    if okS and type(s) == "number" then
        summary.sessionsRemoved = s
        if s > 0 and type(KIPN.Server.Save) == "function" then
            pcall(KIPN.Server.Save, "sessions")
        end
    elseif not okS then
        logError("sweepSessions failed: " .. tostring(s))
    end

    local okV, v = pcall(sweepValidationKeys, data)
    if okV and type(v) == "number" then
        summary.validationKeysRemoved = v
        if v > 0 and type(KIPN.Server.Save) == "function" then
            pcall(KIPN.Server.Save, "validationKeys")
        end
    elseif not okV then
        logError("sweepValidationKeys failed: " .. tostring(v))
    end

    ----------------------------------------------------------
    -- 3: player-stats retention
    ----------------------------------------------------------

    local okP, removed, stamped = pcall(sweepPlayerStats, data)
    if okP then
        summary.playerStatsRemoved = tonumber(removed) or 0
        summary.playerStatsStamped = tonumber(stamped) or 0

        if (summary.playerStatsRemoved > 0 or summary.playerStatsStamped > 0)
            and type(KIPN.Server.Save) == "function"
        then
            pcall(KIPN.Server.Save, "playerStats")
        end
    else
        logError("sweepPlayerStats failed: " .. tostring(removed))
    end

    ----------------------------------------------------------
    -- 4: expired claims (ClaimService owns claim data + its own
    -- domain-scoped save inside ReleaseClaim). Proactively frees a
    -- safehouse / excavation / vehicle whose ownership window has
    -- elapsed, so it does not linger until its owner next logs in.
    ----------------------------------------------------------

    if KIPN.Server.ClaimService
        and type(KIPN.Server.ClaimService.RunExpirySweep) == "function"
    then
        local okE, expirySummary =
            pcall(KIPN.Server.ClaimService.RunExpirySweep)

        if okE and type(expirySummary) == "table" then
            summary.claimsExpired = expirySummary.released or 0
            summary.claimsExpireFailed = expirySummary.failed or 0
        elseif not okE then
            logError("ClaimService.RunExpirySweep failed: " .. tostring(expirySummary))
        end
    end

    ----------------------------------------------------------
    -- 5: orphaned claims (ClaimService owns claim data + its
    -- own domain-scoped save)
    ----------------------------------------------------------

    if KIPN.Server.ClaimService
        and type(KIPN.Server.ClaimService.RunOrphanSweep) == "function"
    then
        local graceDays =
            sandboxNumber("OrphanClaimGraceDays", DEFAULT_ORPHAN_GRACE_DAYS)

        local okC, claimSummary =
            pcall(KIPN.Server.ClaimService.RunOrphanSweep, graceDays)

        if okC and type(claimSummary) == "table" then
            summary.claimsFlagged = claimSummary.flagged or 0
            summary.claimsCleared = claimSummary.cleared or 0
            summary.claimsPurged = claimSummary.purged or 0
        elseif not okC then
            logError("ClaimService.RunOrphanSweep failed: " .. tostring(claimSummary))
        end
    end

    ----------------------------------------------------------
    -- Report only if something actually happened.
    ----------------------------------------------------------

    if summary.sessionsRemoved > 0
        or summary.validationKeysRemoved > 0
        or summary.playerStatsRemoved > 0
        or summary.claimsExpired > 0
        or summary.claimsExpireFailed > 0
        or summary.claimsFlagged > 0
        or summary.claimsCleared > 0
        or summary.claimsPurged > 0
    then
        logInfo(
            "Sweep (" .. summary.reason .. "): "
            .. "sessions -" .. summary.sessionsRemoved
            .. ", keys -" .. summary.validationKeysRemoved
            .. ", playerStats -" .. summary.playerStatsRemoved
            .. ", claims expired " .. summary.claimsExpired
            .. " / flagged " .. summary.claimsFlagged
            .. " / cleared " .. summary.claimsCleared
            .. " / purged " .. summary.claimsPurged
        )
    end

    MaintenanceService._lastSummary = summary
    MaintenanceService._lastSweepMs = lastSweepMs

    return summary
end

------------------------------------------------------------
-- SCHEDULE
------------------------------------------------------------

local initCompleteMs = nil
local didFirstSweep = false

-- Resolved each tick so an operator editing the sandbox value and
-- restarting is honoured without touching this file. Returns a number
-- of milliseconds, or STARTUP_ONLY.
local function resolveSweepInterval()
    local idx = sandboxNumber("MaintenanceFrequency", 2)

    local resolved = FREQUENCY_BY_INDEX[idx]

    if resolved == nil then
        return DEFAULT_SWEEP_INTERVAL_MS
    end

    return resolved
end

local function onTick()

    if not KIPN.Server._initialized then
        return
    end

    local now = nowMs()

    if now <= 0 then
        return
    end

    if not initCompleteMs then
        initCompleteMs = now
        return
    end

    if not didFirstSweep then
        if (now - initCompleteMs) >= FIRST_SWEEP_DELAY_MS then
            didFirstSweep = true
            pcall(MaintenanceService.RunSweep, "startup")
        end
        return
    end

    local interval = resolveSweepInterval()

    if interval == STARTUP_ONLY then
        return
    end

    if not lastSweepMs
        or (now - lastSweepMs) >= interval
    then
        pcall(MaintenanceService.RunSweep, "scheduled")
    end
end

function MaintenanceService.Initialize()
    if MaintenanceService._initialized then
        return true
    end

    if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
        Events.OnTick.Add(onTick)
    else
        logError("Events.OnTick unavailable; maintenance sweeps will not run.")
        return false
    end

    MaintenanceService._initialized = true
    logInfo("Maintenance service initialized.")

    return true
end

print("[KIPN] Maintenance Service loaded")
