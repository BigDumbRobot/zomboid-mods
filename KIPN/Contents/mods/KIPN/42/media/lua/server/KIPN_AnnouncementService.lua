-- KIPN_AnnouncementService.lua
-- Server-side announcement service: Discord feed ingest + admin
-- announcements + broadcast to connected clients.
--
-- RESPONSIBILITY:
--   * Ingest new Discord messages from a plain-text feed file written
--     by the external KIPN Discord poster (see DISCORD FEED below).
--   * Maintain admin-posted announcements (KIPN's manual path).
--   * Merge both sources into a single, newest-first list.
--   * Persist the merged state through KIPN.Server.Save().
--   * Broadcast the merged list to every connected player when it
--     changes.
--   * Serve GET_ANNOUNCEMENTS on demand (read-only, any player).
--   * Serve ANNOUNCEMENT_SYNC admin mutations (post/clear).
--
-- DISCORD FEED CONTRACT:
--
-- Project Zomboid's Lua sandbox cannot make outbound HTTP calls and
-- cannot parse JSON on this build (no cjson), so this service never
-- talks to Discord and never touches JSON. Instead, two small admin
-- helper programs -- distributed on their own, outside this Workshop
-- mod, from the KIPN GitHub page -- do the Discord side:
--
--   1. "KIPN Discord config tool" (a single self-contained .html
--      file): the admin lists the Discord channels they want mirrored
--      in-game and exports  KIPN_DiscordChannels.txt  into the
--      server's  Zomboid/Lua/  folder. KIPN reads it on every restart
--      so the aggregated channel list is always in step with the tool.
--
--   2. "KIPN Discord poster" (an optional Python script the admin runs
--      on the host): reads that same channel list, polls Discord for
--      new messages, and appends them to  Zomboid/Lua/KIPN_DiscordFeed.txt .
--
-- This service only ever READS those two files, both plain text, both
-- in  Zomboid/Lua/  (getFileReader). Without the helper running, only
-- admin-posted announcements appear -- everything still works.
--
--   KIPN_DiscordChannels.txt  -- one channel per line, tab-separated:
--       <label> <TAB> <channelId>
--     '#' comment lines and blank lines are ignored.
--
--   KIPN_DiscordFeed.txt  -- one message per line, tab-separated:
--       <messageId> <TAB> <epochMillis> <TAB> <channelLabel> <TAB> <author> <TAB> <text>
--     text has newlines written as the two characters "\n" and tabs
--     as "\t"; this service restores them. '#'/blank lines ignored.
--     Messages are de-duplicated by <messageId>, so the poster may
--     re-append or rewrite the whole file freely.
--
-- "REAL-TIME":
--
-- The feed is ingested at boot (the "each restart" path the admin
-- tool targets) and then re-checked every POLL_INTERVAL_MS via
-- Events.OnTick for operators who keep the poster running live. A
-- change is broadcast to every currently connected player the moment
-- it is detected. A broadcast that arrives while a player has no KIPN
-- terminal open is not queued; that player picks up the current state
-- next time they open the terminal (KIPN_MainMenu requests
-- GET_ANNOUNCEMENTS on every show).

if isClient() and not isServer() then
    return
end

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_AnnouncementConfig"

KIPN.Server.AnnouncementService = KIPN.Server.AnnouncementService or {}

local AnnouncementService = KIPN.Server.AnnouncementService

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local logger =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("AnnouncementService")
    or nil

local function log(message)
    if logger then
        logger:Info(message)
    else
        print("[KIPN ANNOUNCEMENT] " .. tostring(message))
    end
end

local function logError(message)
    if logger then
        logger:Error(message)
    else
        print("[KIPN ANNOUNCEMENT] ERROR: " .. tostring(message))
    end
end

------------------------------------------------------------
-- CONSTANTS
------------------------------------------------------------

-- Both live in Zomboid/Lua/ (getFileReader's fixed root). Filenames
-- must end in .txt or getFileReader returns nil silently on B42.
local FEED_FILE = "KIPN_DiscordFeed.txt"
local CHANNELS_FILE = "KIPN_DiscordChannels.txt"

local POLL_INTERVAL_MS = 30000

local MAX_DISCORD_ENTRIES = 20
local MAX_ADMIN_ENTRIES = 10
local MAX_MERGED_ENTRIES = 25

-- How many recently-seen Discord message ids to remember so a feed
-- file that keeps (or re-appends) old lines never re-ingests them.
-- Comfortably larger than MAX_DISCORD_ENTRIES.
local MAX_SEEN_IDS = 250

local MAX_TEXT_LENGTH = 500
local MAX_AUTHOR_LENGTH = 60
local MAX_LABEL_LENGTH = 40
local MAX_FEED_LINES = 2000

------------------------------------------------------------
-- REAL-WORLD EPOCH
--
-- Announcement timestamps must interleave correctly against Discord
-- message timestamps (real calendar time), so this uses os.time()
-- rather than getTimestampMs() (engine runtime elapsed time).
------------------------------------------------------------

local function epochMsNow()
    local ok, result = pcall(function()
        return os.time() * 1000
    end)

    if ok and type(result) == "number" then
        return result
    end

    return 0
end

------------------------------------------------------------
-- PERSISTED CACHE
--
-- Lives inside KIPN.Server.GetData() -- the same authoritative
-- ModData structure everything else in KIPN persists through.
------------------------------------------------------------

local function getCache()
    if type(KIPN.Server.GetData) ~= "function" then
        logError("getCache failed: KIPN.Server.GetData() unavailable.")
        return nil
    end

    local data = KIPN.Server.GetData()

    if type(data) ~= "table" then
        logError("getCache failed: server data unavailable.")
        return nil
    end

    if type(data.announcements) ~= "table" then
        data.announcements = {}
        log("Created announcement cache.")
    end

    local cache = data.announcements

    if type(cache.discordList) ~= "table" then cache.discordList = {} end
    if type(cache.discordSeenIds) ~= "table" then cache.discordSeenIds = {} end
    if type(cache.discordSeenOrder) ~= "table" then cache.discordSeenOrder = {} end
    if type(cache.adminList) ~= "table" then cache.adminList = {} end
    if type(cache.channels) ~= "table" then cache.channels = {} end
    if cache.lastSignature == nil then cache.lastSignature = "" end

    return cache
end

------------------------------------------------------------
-- NORMALIZATION
------------------------------------------------------------

local function truncate(text, maxLength)
    text = tostring(text or "")

    if #text > maxLength then
        return string.sub(text, 1, maxLength)
    end

    return text
end

local function unescapeFeedText(text)
    text = tostring(text or "")
    text = text:gsub("\\n", "\n")
    text = text:gsub("\\t", "\t")
    return text
end

local function sortByTimestampDesc(list)
    table.sort(list, function(a, b)
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)
end

------------------------------------------------------------
-- PLAIN-TEXT FILE READERS
------------------------------------------------------------

-- Returns an array of non-blank, non-comment lines, or nil if the
-- file does not exist / cannot be read. A missing file is the normal
-- "helper not set up yet" state, not an error.
local function readTextFileLines(fileName, maxLines)
    if type(getFileReader) ~= "function" then
        return nil
    end

    local ok, lines = pcall(function()
        local reader = getFileReader(fileName, false)

        if not reader then
            return nil
        end

        local out = {}
        local count = 0

        while true do
            local line = reader:readLine()

            if line == nil then
                break
            end

            count = count + 1

            if count > (maxLines or MAX_FEED_LINES) then
                break
            end

            local trimmed = tostring(line):gsub("^%s+", ""):gsub("%s+$", "")

            if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
                out[#out + 1] = trimmed
            end
        end

        reader:close()

        return out
    end)

    if not ok then
        logError("Failed reading " .. fileName .. ": " .. tostring(lines))
        return nil
    end

    return lines
end

local function splitTabs(line)
    local fields = {}

    for field in string.gmatch(tostring(line) .. "\t", "([^\t]*)\t") do
        fields[#fields + 1] = field
    end

    return fields
end

------------------------------------------------------------
-- CHANNEL LIST  (KIPN_DiscordChannels.txt, from the config tool)
------------------------------------------------------------

local function readChannelLabels()
    local lines = readTextFileLines(CHANNELS_FILE, 200)

    if not lines then
        return nil
    end

    local labels = {}

    for _, line in ipairs(lines) do
        local fields = splitTabs(line)
        local label = truncate(fields[1] or "", MAX_LABEL_LENGTH)

        if label ~= "" then
            labels[#labels + 1] = label
        end
    end

    return labels
end

------------------------------------------------------------
-- DISCORD FEED  (KIPN_DiscordFeed.txt, from the poster)
------------------------------------------------------------

-- Parses the feed into normalized entries, newest-first. Does NOT
-- filter by "already seen" -- ingestFeed() does that.
local function readFeedEntries()
    local lines = readTextFileLines(FEED_FILE, MAX_FEED_LINES)

    if not lines then
        return nil
    end

    local list = {}

    for _, line in ipairs(lines) do
        local fields = splitTabs(line)

        local id = tostring(fields[1] or ""):gsub("%s+", "")
        local timestamp = tonumber(fields[2]) or 0
        local channelLabel = truncate(fields[3] or "", MAX_LABEL_LENGTH)
        local author = truncate(fields[4] or "Discord", MAX_AUTHOR_LENGTH)
        local text = truncate(unescapeFeedText(fields[5] or ""), MAX_TEXT_LENGTH)

        if id ~= "" and text ~= "" then
            list[#list + 1] = {
                id = "discord_" .. id,
                rawId = id,
                author = author,
                text = text,
                timestamp = timestamp,
                channel = channelLabel,
                source = "discord",
            }
        end
    end

    sortByTimestampDesc(list)

    return list
end

------------------------------------------------------------
-- MERGE
------------------------------------------------------------

local function mergeLists(discordList, adminList)
    local merged = {}

    for _, entry in ipairs(discordList or {}) do
        merged[#merged + 1] = entry
    end

    for _, entry in ipairs(adminList or {}) do
        merged[#merged + 1] = entry
    end

    sortByTimestampDesc(merged)

    if #merged > MAX_MERGED_ENTRIES then
        local capped = {}

        for i = 1, MAX_MERGED_ENTRIES do
            capped[i] = merged[i]
        end

        merged = capped
    end

    return merged
end

local function computeSignature(list)
    local parts = {}

    for _, entry in ipairs(list) do
        parts[#parts + 1] = tostring(entry.id) .. ":" .. tostring(entry.timestamp)
    end

    return table.concat(parts, "|")
end

------------------------------------------------------------
-- BROADCAST
------------------------------------------------------------

local function buildPayload(merged, cache)
    local latest = merged[1]

    cache = cache or getCache()

    local channelCount = 0

    if cache and type(cache.channels) == "table" then
        channelCount = #cache.channels
    end

    local discordActive =
        channelCount > 0
        or (cache and type(cache.discordList) == "table" and #cache.discordList > 0)

    return {
        announcements = merged,
        updatedAt = latest and latest.timestamp or 0,
        latestId = latest and latest.id or nil,
        -- Retained for older clients; the menu row itself is now
        -- gated entirely by the server-side ApplicationRegistry.
        discordConfigured = discordActive == true,
        discordChannelCount = channelCount,
    }
end

local function broadcastAnnouncements(merged, cache)
    if type(getOnlinePlayers) ~= "function" then
        return
    end

    local okPlayers, onlinePlayers = pcall(getOnlinePlayers)

    if not okPlayers or not onlinePlayers or type(onlinePlayers.size) ~= "function" then
        logError("broadcastAnnouncements failed to resolve online players.")
        return
    end

    local payload = buildPayload(merged, cache)

    local sentCount = 0

    for i = 0, onlinePlayers:size() - 1 do
        local okPlayer, player = pcall(function()
            return onlinePlayers:get(i)
        end)

        if okPlayer and player then
            local sent = KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ANNOUNCEMENT_SYNC,
                payload
            )

            if sent then
                sentCount = sentCount + 1
            end
        end
    end

    log("Broadcast announcements to " .. tostring(sentCount) .. " player(s).")
end

------------------------------------------------------------
-- PERSIST + BROADCAST IF CHANGED
------------------------------------------------------------

local function persistAndBroadcastIfChanged(cache)
    if not cache then
        return nil, false
    end

    local merged = mergeLists(cache.discordList, cache.adminList)
    local signature = computeSignature(merged)
    local changed = signature ~= cache.lastSignature

    if changed then
        cache.lastSignature = signature

        if type(KIPN.Server.Save) == "function" then
            local ok, result = pcall(KIPN.Server.Save, "announcements")

            if not ok or result == false then
                logError("Failed to persist announcement state: " .. tostring(result))
            end
        else
            logError("KIPN.Server.Save() unavailable; announcement state not persisted.")
        end

        broadcastAnnouncements(merged, cache)
    end

    return merged, changed
end

------------------------------------------------------------
-- PUBLIC: CURRENT STATE
------------------------------------------------------------

function AnnouncementService.GetMergedAnnouncements()
    local cache = getCache()

    if not cache then
        return {}
    end

    return mergeLists(cache.discordList, cache.adminList)
end

function AnnouncementService.GetConfiguredChannels()
    local cache = getCache()

    if not cache then
        return {}
    end

    local out = {}

    for _, label in ipairs(cache.channels or {}) do
        out[#out + 1] = label
    end

    return out
end

------------------------------------------------------------
-- REFRESH CONFIGURED CHANNEL LIST
------------------------------------------------------------

function AnnouncementService.RefreshChannels()
    local cache = getCache()

    if not cache then
        return false
    end

    local labels = readChannelLabels()

    if labels == nil then
        -- No config file: keep whatever we last knew, but note it.
        return false
    end

    local before = table.concat(cache.channels or {}, "|")
    local after = table.concat(labels, "|")

    if before == after then
        return false
    end

    cache.channels = labels

    if type(KIPN.Server.Save) == "function" then
        pcall(KIPN.Server.Save, "announcements")
    end

    log(
        "Discord channel list refreshed: " ..
        tostring(#labels) .. " channel(s) [" .. after .. "]"
    )

    -- The channel count is part of the ANNOUNCEMENT_SYNC payload, so
    -- push the current state to anyone connected.
    broadcastAnnouncements(
        mergeLists(cache.discordList, cache.adminList),
        cache
    )

    return true
end

------------------------------------------------------------
-- PUBLIC: INGEST DISCORD FEED
------------------------------------------------------------

local function rememberSeen(cache, rawId)
    if cache.discordSeenIds[rawId] then
        return
    end

    cache.discordSeenIds[rawId] = true
    cache.discordSeenOrder[#cache.discordSeenOrder + 1] = rawId

    while #cache.discordSeenOrder > MAX_SEEN_IDS do
        local evicted = table.remove(cache.discordSeenOrder, 1)

        if evicted ~= nil then
            cache.discordSeenIds[evicted] = nil
        end
    end
end

function AnnouncementService.IngestFeed()
    local cache = getCache()

    if not cache then
        return false
    end

    local entries = readFeedEntries()

    if entries == nil then
        return false
    end

    local newCount = 0

    -- entries is newest-first; walk oldest-first so the kept slice
    -- ends up newest-first after the sort below and eviction drops
    -- the oldest.
    for i = #entries, 1, -1 do
        local entry = entries[i]

        if entry.rawId ~= "" and not cache.discordSeenIds[entry.rawId] then
            rememberSeen(cache, entry.rawId)

            -- Backfill a timestamp so a feed line with a bad/missing
            -- epoch still sorts sensibly (just-arrived == now).
            if (entry.timestamp or 0) <= 0 then
                entry.timestamp = epochMsNow()
            end

            entry.rawId = nil

            table.insert(cache.discordList, 1, entry)
            newCount = newCount + 1
        end
    end

    if newCount == 0 then
        return false
    end

    sortByTimestampDesc(cache.discordList)

    while #cache.discordList > MAX_DISCORD_ENTRIES do
        table.remove(cache.discordList)
    end

    local _, changed = persistAndBroadcastIfChanged(cache)

    log(
        "Discord feed ingest complete. new=" .. tostring(newCount) ..
        " total=" .. tostring(#cache.discordList) ..
        " changed=" .. tostring(changed)
    )

    return changed
end

-- Back-compat alias: older callers / docs referenced PollDiscordBridge.
AnnouncementService.PollDiscordBridge = AnnouncementService.IngestFeed

------------------------------------------------------------
-- PUBLIC: ADMIN POST / CLEAR
------------------------------------------------------------

local function requireAnnouncementAdmin(player)
    if not KIPN.Server.AdminService
        or type(KIPN.Server.AdminService.RequirePermission) ~= "function"
    then
        logError("AdminService.RequirePermission unavailable; failing closed.")
        return false
    end

    return KIPN.Server.AdminService.RequirePermission(
        player,
        KIPN.Shared.Permissions.ANNOUNCEMENT_ADMIN
    )
end

function AnnouncementService.PostAdmin(player, text)
    if not requireAnnouncementAdmin(player) then
        return false, "PERMISSION_DENIED"
    end

    text = truncate(text, MAX_TEXT_LENGTH)

    if text == "" then
        return false, "EMPTY_TEXT"
    end

    local cache = getCache()

    if not cache then
        return false, "DATA_UNAVAILABLE"
    end

    local author = "Unknown"

    if KIPN.Shared and type(KIPN.Shared.GetPlayerName) == "function" then
        author = KIPN.Shared.GetPlayerName(player)
    end

    local now = epochMsNow()

    local entry = {
        id = "admin_" .. tostring(now) .. "_" .. tostring(ZombRand(1000, 10000)),
        author = author,
        text = text,
        timestamp = now,
        source = "admin",
    }

    table.insert(cache.adminList, 1, entry)

    while #cache.adminList > MAX_ADMIN_ENTRIES do
        table.remove(cache.adminList)
    end

    persistAndBroadcastIfChanged(cache)

    if KIPN.Server.AdminService and type(KIPN.Server.AdminService.WriteAudit) == "function" then
        pcall(
            KIPN.Server.AdminService.WriteAudit,
            player,
            "POST_ANNOUNCEMENT",
            "ANNOUNCEMENT",
            entry.id,
            { text = text }
        )
    end

    log("Admin announcement posted by " .. tostring(author))

    return true
end

function AnnouncementService.ClearAdmin(player)
    if not requireAnnouncementAdmin(player) then
        return false, "PERMISSION_DENIED"
    end

    local cache = getCache()

    if not cache then
        return false, "DATA_UNAVAILABLE"
    end

    cache.adminList = {}

    persistAndBroadcastIfChanged(cache)

    if KIPN.Server.AdminService and type(KIPN.Server.AdminService.WriteAudit) == "function" then
        pcall(
            KIPN.Server.AdminService.WriteAudit,
            player,
            "CLEAR_ANNOUNCEMENTS",
            "ANNOUNCEMENT",
            nil,
            {}
        )
    end

    log("Admin announcements cleared by " .. tostring(player))

    return true
end

------------------------------------------------------------
-- COMMAND HANDLERS
------------------------------------------------------------

local function handleGetAnnouncements(player, args)
    log("handleGetAnnouncements()")

    local cache = getCache()
    local merged = cache and mergeLists(cache.discordList, cache.adminList) or {}

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.ANNOUNCEMENT_SYNC,
        buildPayload(merged, cache)
    )

    return true
end

local function handleAnnouncementSync(player, args)
    log("handleAnnouncementSync()")

    local action = args and args.action

    if action == "post" then
        local ok, reason = AnnouncementService.PostAdmin(player, args and args.text)

        if not ok then
            KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
                code = reason or "POST_FAILED",
                message = "Unable to post announcement.",
            })
        end

        return true
    end

    if action == "clear" then
        local ok, reason = AnnouncementService.ClearAdmin(player)

        if not ok then
            KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
                code = reason or "CLEAR_FAILED",
                message = "Unable to clear announcements.",
            })
        end

        return true
    end

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR, {
        code = "INVALID_ACTION",
        message = "Unknown announcement action.",
    })

    return true
end

------------------------------------------------------------
-- TICK-DRIVEN POLLING
------------------------------------------------------------

local lastPollMs = 0
local pollTickCounter = 0

local function onTick()
    if not _G.getTimestampMs then
        return
    end

    local now = getTimestampMs()

    if now - lastPollMs < POLL_INTERVAL_MS then
        return
    end

    lastPollMs = now

    pcall(AnnouncementService.IngestFeed)

    -- The channel-list file changes far less often than the feed, so
    -- only re-scan it every 10th poll (~5 min at the default interval).
    pollTickCounter = pollTickCounter + 1

    if pollTickCounter % 10 == 0 then
        pcall(AnnouncementService.RefreshChannels)
    end
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

function AnnouncementService.Initialize()
    if AnnouncementService._initialized then
        return true
    end

    log("AnnouncementService.Initialize()")

    if KIPN.Server.AnnouncementConfig
        and type(KIPN.Server.AnnouncementConfig.Initialize) == "function"
    then
        KIPN.Server.AnnouncementConfig.Initialize()
    end

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.GET_ANNOUNCEMENTS,
        handleGetAnnouncements
    )

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.ANNOUNCEMENT_SYNC,
        handleAnnouncementSync
    )

    if KIPN.Server.Permissions and type(KIPN.Server.Permissions.RegisterPermission) == "function" then
        KIPN.Server.Permissions.RegisterPermission(
            KIPN.Shared.Permissions.ANNOUNCEMENT_ADMIN,
            "Post/clear KIPN announcements"
        )
    end

    -- The "aggregate and send to the server with each server restart"
    -- path: pick up the current channel list and any feed the poster
    -- has already written, before any player connects.
    pcall(AnnouncementService.RefreshChannels)
    pcall(AnnouncementService.IngestFeed)

    lastPollMs = getTimestampMs and getTimestampMs() or 0

    if Events and Events.OnTick then
        Events.OnTick.Add(onTick)
    else
        logError("Events.OnTick unavailable; Discord feed will not be polled live.")
    end

    AnnouncementService._initialized = true

    log("AnnouncementService initialized.")

    return true
end
