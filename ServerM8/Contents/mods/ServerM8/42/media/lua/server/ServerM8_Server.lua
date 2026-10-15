-- ServerM8 server side: answers dashboard requests with who is online, an
-- activity feed, and the rules and news the owner keeps in two text files.

if isClient() then return end

require "ServerM8_Util"

local RULES_FILE = "ServerM8_rules.txt"
local NEWS_FILE = "ServerM8_news.txt"
local FEED_LIMIT = 40
local TEXT_LIMIT = 6000
local FILE_CACHE_SECONDS = 30
local MIN_REQUEST_SECONDS = 2

local DEFAULT_RULES = "1. Be decent to each other.\n2. No cheating or exploiting.\n3. Staff decisions are final.\n\nEdit Zomboid/Lua/" .. RULES_FILE .. " on the server to change this text."
local DEFAULT_NEWS = ""

local startedAt = getTimestamp()
local feed = {}
local known = {}
local lastRequest = {}
local lastDeath = {}
local fileCache = { rules = nil, news = nil, readAt = 0 }

local function pushFeed(kind, name)
    table.insert(feed, { t = getTimestamp(), k = kind, n = name })
    while #feed > FEED_LIMIT do
        table.remove(feed, 1)
    end
end

local function onlineNames()
    local names = {}
    local players = getOnlinePlayers()
    if players then
        for i = 0, players:size() - 1 do
            local player = players:get(i)
            local name = player and player:getUsername()
            if name and name ~= "" then table.insert(names, name) end
        end
    end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    return names
end

-- Compares who is online now with the last check and records joins and leaves.
local function syncOnline()
    local names = onlineNames()
    local current = {}
    for _, name in ipairs(names) do
        current[name] = true
        if not known[name] then pushFeed("join", name) end
    end
    for name in pairs(known) do
        if not current[name] then
            pushFeed("leave", name)
            lastRequest[name] = nil
            lastDeath[name] = nil
        end
    end
    known = current
    return names
end

local function readTextFile(fileName, default)
    local reader = getFileReader(fileName, false)
    if not reader then
        local writer = getFileWriter(fileName, true, false)
        if writer then
            writer:write(default)
            writer:close()
        end
        return default
    end
    local lines = {}
    local line = reader:readLine()
    while line do
        table.insert(lines, line)
        line = reader:readLine()
    end
    reader:close()
    local text = table.concat(lines, "\n")
    if #text > TEXT_LIMIT then text = string.sub(text, 1, TEXT_LIMIT) end
    return text
end

-- Re-reads the files at most every 30 seconds, so edits show up without a restart.
local function ownerText()
    local now = getTimestamp()
    if not fileCache.rules or now - fileCache.readAt >= FILE_CACHE_SECONDS then
        fileCache.rules = readTextFile(RULES_FILE, DEFAULT_RULES)
        fileCache.news = readTextFile(NEWS_FILE, DEFAULT_NEWS)
        fileCache.readAt = now
    end
    return fileCache.rules, fileCache.news
end

local function maxPlayers()
    local ok, value = pcall(function() return getServerOptions():getInteger("MaxPlayers") end)
    if ok and value then return value end
    return 0
end

local function sendSnapshot(player)
    local now = getTimestamp()
    local names = syncOnline()
    local rules, news = ownerText()
    local entries = {}
    local showActivity = not (SandboxVars and SandboxVars.ServerM8 and SandboxVars.ServerM8.ShowActivity == false)
    if showActivity then
        for _, entry in ipairs(feed) do
            table.insert(entries, { a = now - entry.t, k = entry.k, n = entry.n })
        end
    end
    sendServerCommand(player, ServerM8.MODULE, "snapshot", {
        online = names,
        max = maxPlayers(),
        uptime = now - startedAt,
        feed = entries,
        rules = rules,
        news = news,
    })
end

local function onClientCommand(module, command, player, args)
    if module ~= ServerM8.MODULE or not player then return end
    local name = player:getUsername() or "?"
    local now = getTimestamp()

    if command == "death" then
        -- The name comes from the connection, never from the message.
        if not lastDeath[name] or now - lastDeath[name] >= 10 then
            lastDeath[name] = now
            pushFeed("death", name)
        end
        return
    end

    if command == "hello" or command == "refresh" then
        if lastRequest[name] and now - lastRequest[name] < MIN_REQUEST_SECONDS then return end
        lastRequest[name] = now
        sendSnapshot(player)
    end
end

Events.OnClientCommand.Add(onClientCommand)
Events.EveryOneMinute.Add(syncOnline)
