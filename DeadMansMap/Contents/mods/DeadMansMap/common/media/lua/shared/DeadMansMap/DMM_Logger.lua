DeadMansMap = DeadMansMap or {}

local Logger = {}

Logger.VERSION = "1.0.0"
Logger.MAX_HISTORY = 1000
Logger.MAX_RUN_ENTRIES = 50000
Logger.history = {}
Logger.runCounter = 0
Logger.currentRun = nil
Logger.lastMetaTimeRunLog = nil
Logger.debugConsoleEnabled = false

local function nowMilliseconds()
    if getTimestampMs then
        local ok, value = pcall(getTimestampMs)
        if ok and value then
            return tonumber(value) or 0
        end
    end

    return math.floor(os.clock() * 1000)
end

local function worldAgeHours()
    if getGameTime then
        local ok, gameTime = pcall(getGameTime)
        if ok and gameTime then
            local ageOk, age = pcall(function()
                return gameTime:getWorldAgeHours()
            end)
            if ageOk and age then
                return tonumber(age) or 0
            end
        end
    end

    return 0
end

local function stringify(value)
    if value == nil then
        return "nil"
    end

    if type(value) == "table" then
        local entries = {}
        for key in pairs(value) do
            table.insert(entries, {
                rawKey = key,
                displayKey = tostring(key),
            })
        end
        table.sort(entries, function(left, right)
            return left.displayKey < right.displayKey
        end)

        local parts = {}
        for _, entry in ipairs(entries) do
            local rawValue = value[entry.rawKey]
            table.insert(parts, entry.displayKey .. "=" .. tostring(rawValue))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end

    return tostring(value)
end

local function appendEntry(entry)
    table.insert(Logger.history, entry)
    while #Logger.history > Logger.MAX_HISTORY do
        table.remove(Logger.history, 1)
    end

    if Logger.currentRun then
        if #Logger.currentRun.entries < Logger.MAX_RUN_ENTRIES then
            table.insert(Logger.currentRun.entries, entry)
        else
            Logger.currentRun.droppedEntries = Logger.currentRun.droppedEntries + 1
        end
    end
end

local function printLine(line)
    print("[DeadMansMap] " .. line)
end

function Logger.setDebugConsoleEnabled(enabled)
    Logger.debugConsoleEnabled = enabled == true
    Logger.info("Logger.setDebugConsoleEnabled", "Debug console output changed", {
        enabled = Logger.debugConsoleEnabled,
    })
end

function Logger.write(level, eventName, message, data)
    local entry = {
        timestampMs = nowMilliseconds(),
        worldAgeHours = worldAgeHours(),
        level = level or "INFO",
        eventName = eventName or "Unknown",
        message = message or "",
        data = stringify(data),
        runId = Logger.currentRun and Logger.currentRun.id or "BOOT",
    }

    appendEntry(entry)

    if entry.level ~= "DEBUG" or Logger.debugConsoleEnabled then
        printLine(string.format(
            "[%s] [%s] %s | %s",
            entry.level,
            entry.eventName,
            entry.message,
            entry.data
        ))
    end

    return entry
end

function Logger.debug(eventName, message, data)
    return Logger.write("DEBUG", eventName, message, data)
end

function Logger.info(eventName, message, data)
    return Logger.write("INFO", eventName, message, data)
end

function Logger.warn(eventName, message, data)
    return Logger.write("WARN", eventName, message, data)
end

function Logger.error(eventName, message, data)
    return Logger.write("ERROR", eventName, message, data)
end

function Logger.beginRun(label, context)
    if Logger.currentRun then
        Logger.finishRun("superseded", {
            replacement = label,
        })
    end

    Logger.runCounter = Logger.runCounter + 1
    Logger.currentRun = {
        id = string.format("DMM-%06d", Logger.runCounter),
        label = label or "UnnamedRun",
        startedMs = nowMilliseconds(),
        context = stringify(context),
        entries = {},
        droppedEntries = 0,
    }

    Logger.info("MetaTimeRunLog.begin", "Run started", {
        id = Logger.currentRun.id,
        label = Logger.currentRun.label,
        context = Logger.currentRun.context,
    })

    return Logger.currentRun.id
end

function Logger.traceStart(functionName, context)
    local token = {
        name = functionName or "UnknownFunction",
        startedMs = nowMilliseconds(),
    }

    Logger.debug(token.name, "Function started", context)
    return token
end

function Logger.traceEnd(token, outcome, context)
    local elapsedMs = 0
    local functionName = "UnknownFunction"

    if token then
        functionName = token.name or functionName
        elapsedMs = nowMilliseconds() - (token.startedMs or nowMilliseconds())
    end

    Logger.debug(functionName, "Function finished", {
        outcome = outcome or "ok",
        elapsedMs = elapsedMs,
        context = stringify(context),
    })

    return elapsedMs
end

function Logger.dumpMetaTimeRunLog(runId, status, summary)
    local selectedRunId = runId or (Logger.currentRun and Logger.currentRun.id) or "BOOT"
    local lines = {}
    local selectedEntries = {}

    if Logger.currentRun and Logger.currentRun.id == selectedRunId then
        selectedEntries = Logger.currentRun.entries
    else
        for _, entry in ipairs(Logger.history) do
            if entry.runId == selectedRunId then
                table.insert(selectedEntries, entry)
            end
        end
    end

    for _, entry in ipairs(selectedEntries) do
        table.insert(lines, string.format(
            "%dms | %.5fh | %-5s | %-32s | %s | %s",
            entry.timestampMs,
            entry.worldAgeHours,
            entry.level,
            entry.eventName,
            entry.message,
            entry.data
        ))
    end

    local droppedEntries = Logger.currentRun
        and Logger.currentRun.id == selectedRunId
        and Logger.currentRun.droppedEntries
        or 0

    Logger.lastMetaTimeRunLog = {
        runId = selectedRunId,
        status = status or "snapshot",
        summary = stringify(summary),
        lines = lines,
        droppedEntries = droppedEntries,
    }

    printLine(string.format(
        "===== META TIME RUN LOG %s | status=%s | entries=%d | dropped=%d | %s =====",
        selectedRunId,
        status or "snapshot",
        #lines,
        droppedEntries,
        stringify(summary)
    ))

    local printedCount = 0
    for index, entry in ipairs(selectedEntries) do
        if Logger.debugConsoleEnabled or entry.level ~= "DEBUG" then
            printLine(lines[index])
            printedCount = printedCount + 1
        end
    end

    if not Logger.debugConsoleEnabled and printedCount < #lines then
        printLine(string.format(
            "%d DEBUG entries compiled but hidden; enable DebugLogging or inspect DeadMansMap.Logger.lastMetaTimeRunLog.lines",
            #lines - printedCount
        ))
    end

    if droppedEntries > 0 then
        printLine(string.format(
            "WARNING: %d entries exceeded the per-run safety limit",
            droppedEntries
        ))
    end

    printLine("===== END META TIME RUN LOG " .. selectedRunId .. " =====")

    return Logger.lastMetaTimeRunLog
end

function Logger.finishRun(status, summary)
    if not Logger.currentRun then
        Logger.warn("MetaTimeRunLog.finish", "No active run to finish", {
            status = status,
        })
        return nil
    end

    local run = Logger.currentRun
    local elapsedMs = nowMilliseconds() - run.startedMs

    Logger.info("MetaTimeRunLog.finish", "Run finished", {
        id = run.id,
        status = status or "complete",
        elapsedMs = elapsedMs,
        summary = stringify(summary),
    })

    local compiled = Logger.dumpMetaTimeRunLog(run.id, status, {
        elapsedMs = elapsedMs,
        summary = stringify(summary),
    })
    Logger.currentRun = nil
    return compiled
end

DeadMansMap.Logger = Logger

Logger.info("DMM_Logger", "Logger loaded", {
    version = Logger.VERSION,
    maxHistory = Logger.MAX_HISTORY,
})

return Logger
