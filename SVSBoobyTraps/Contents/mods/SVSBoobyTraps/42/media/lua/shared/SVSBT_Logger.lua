SVSBT = SVSBT or {}

local Logger = SVSBT.Logger or {}
SVSBT.Logger = Logger

Logger.Prefix = "[Spy vs Spy: Booby Traps]"
Logger.LogName = "SVSBoobyTraps"
Logger.MaxMetaEntries = Logger.MaxMetaEntries or 1000
Logger.MetaTimeRunLog = Logger.MetaTimeRunLog or {}
Logger.Verbose = Logger.Verbose == true
Logger.AuditEnabled = Logger.AuditEnabled ~= false
Logger.Aggregates = Logger.Aggregates or {}
Logger.AggregateIntervalMs = 5000

local function nowMilliseconds()
    if type(getTimestampMs) == "function" then
        return getTimestampMs()
    end

    if os and type(os.clock) == "function" then
        return math.floor(os.clock() * 1000)
    end

    return 0
end

local function executionSide()
    if type(isServer) == "function" and isServer() then
        return "SERVER"
    end

    if type(isClient) == "function" and isClient() then
        return "CLIENT"
    end

    return "SINGLEPLAYER"
end

local function appendMeta(level, functionName, elapsedMs, message)
    local entry = {
        timestampMs = nowMilliseconds(),
        side = executionSide(),
        level = tostring(level or "TRACE"),
        functionName = tostring(functionName or "unknown"),
        elapsedMs = tonumber(elapsedMs) or 0,
        message = tostring(message or ""),
    }

    local log = Logger.MetaTimeRunLog
    log[#log + 1] = entry

    while #log > Logger.MaxMetaEntries do
        table.remove(log, 1)
    end

    return entry
end

local function formatEntry(entry)
    return Logger.Prefix
        .. " [" .. tostring(entry.side) .. "]"
        .. " [" .. tostring(entry.level) .. "]"
        .. " Meta Time Run Log | function=" .. tostring(entry.functionName)
        .. " | ms=" .. tostring(entry.elapsedMs)
        .. (entry.message ~= "" and (" | " .. entry.message) or "")
end

local function writeLine(entry)
    local line = formatEntry(entry)
    print(line)

    if type(writeLog) == "function" then
        pcall(writeLog, Logger.LogName, line)
    end
end

local function emit(level, functionName, elapsedMs, message, force)
    if force ~= true and Logger.Verbose ~= true then
        return nil
    end

    local entry = appendMeta(level, functionName, elapsedMs, message)
    writeLine(entry)
    return entry
end

local function aggregateFinish(functionName, elapsedMs, success, detail)
    local key = tostring(functionName or "unknown")
    local stats = Logger.Aggregates[key] or {
        calls = 0,
        failures = 0,
        totalMs = 0,
        maxMs = 0,
        lastEmitMs = 0,
    }
    stats.calls = stats.calls + 1
    stats.totalMs = stats.totalMs + elapsedMs
    stats.maxMs = math.max(stats.maxMs, elapsedMs)
    if success == false then stats.failures = stats.failures + 1 end
    Logger.Aggregates[key] = stats

    local current = nowMilliseconds()

    if Logger.Verbose ~= true and success ~= false
        and current - stats.lastEmitMs >= Logger.AggregateIntervalMs then
        appendMeta("TRACE", key, elapsedMs,
            "AGGREGATE | calls=" .. tostring(stats.calls)
                .. " | failures=" .. tostring(stats.failures)
                .. " | totalMs=" .. tostring(stats.totalMs)
                .. " | maxMs=" .. tostring(stats.maxMs)
                .. (detail ~= nil and (" | last=" .. tostring(detail)) or ""))
        stats.calls = 0
        stats.failures = 0
        stats.totalMs = 0
        stats.maxMs = 0
        stats.lastEmitMs = current
    end
end

function Logger.SetOptions(verbose, auditEnabled, maxEntries)
    local run = Logger.Begin("Logger.SetOptions")
    Logger.Verbose = verbose == true
    Logger.AuditEnabled = auditEnabled ~= false
    Logger.MaxMetaEntries = math.max(100, math.min(10000, tonumber(maxEntries) or 1000))
    Logger.Finish(run, true, "verbose=" .. tostring(Logger.Verbose)
        .. " | audit=" .. tostring(Logger.AuditEnabled)
        .. " | max=" .. tostring(Logger.MaxMetaEntries))
    return true
end

function Logger.Begin(functionName, detail)
    if Logger.Verbose ~= true then
        return { functionName = tostring(functionName or "unknown"), quiet = true }
    end

    local run = {
        functionName = tostring(functionName or "unknown"),
        startedAtMs = nowMilliseconds(),
    }

    emit("TRACE", run.functionName, 0, "BEGIN" .. (detail and (" | " .. tostring(detail)) or ""), false)
    return run
end

function Logger.Finish(run, success, detail)
    run = run or {
        functionName = "unknown",
        startedAtMs = nowMilliseconds(),
    }

    if run.quiet and success ~= false then
        return true, 0
    end

    local elapsed = run.quiet and 0
        or math.max(0, nowMilliseconds() - (tonumber(run.startedAtMs) or 0))
    local outcome = success == false and "FAILED" or "OK"
    local message = "END | status=" .. outcome

    if detail ~= nil then
        message = message .. " | " .. tostring(detail)
    end

    if not run.quiet then
        aggregateFinish(run.functionName, elapsed, success, detail)
    end
    emit(success == false and "WARN" or "TRACE", run.functionName, elapsed, message, success == false)
    return success ~= false, elapsed
end

function Logger.Info(functionName, message)
    local run = Logger.Begin("Logger.Info", functionName)
    local entry = emit("INFO", functionName, 0, message, true)
    Logger.Finish(run, true)
    return entry
end

function Logger.Warn(functionName, message)
    local run = Logger.Begin("Logger.Warn", functionName)
    local entry = emit("WARN", functionName, 0, message, true)
    Logger.Finish(run, true)
    return entry
end

function Logger.Error(functionName, message)
    local run = Logger.Begin("Logger.Error", functionName)
    local entry = emit("ERROR", functionName, 0, message, true)
    Logger.Finish(run, true)
    return entry
end

function Logger.Audit(action, playerName, detail)
    local run = Logger.Begin("Logger.Audit", action)

    if Logger.AuditEnabled then
        emit("AUDIT", "Audit." .. tostring(action or "unknown"), 0,
            "player=" .. tostring(playerName or "unknown")
                .. (detail and (" | " .. tostring(detail)) or ""), true)
    end

    Logger.Finish(run, true)
    return Logger.AuditEnabled
end

function Logger.DumpMetaTimeRunLog(label)
    local run = Logger.Begin("Logger.DumpMetaTimeRunLog", label)
    local header = Logger.Prefix .. " Meta Time Run Log dump"
        .. (label and (" | " .. tostring(label)) or "")
        .. " | entries=" .. tostring(#Logger.MetaTimeRunLog)
    print(header)

    if type(writeLog) == "function" then
        pcall(writeLog, Logger.LogName, header)
    end

    for _, entry in ipairs(Logger.MetaTimeRunLog) do
        writeLine(entry)
    end

    Logger.Finish(run, true, "entries=" .. tostring(#Logger.MetaTimeRunLog))
    return #Logger.MetaTimeRunLog
end

Logger.Info("SVSBT_Logger.load", "bounded Meta Time Run Log initialized")

return Logger
