require "BonkZone/BonkZone_Constants"

BonkZone = BonkZone or {}
BonkZone.Logger = BonkZone.Logger or {}

local Logger = BonkZone.Logger
local Constants = BonkZone.Constants

Logger.Levels = { TRACE = 1, DEBUG = 2, INFO = 3, WARN = 4, ERROR = 5 }
Logger.MinimumLevel = Logger.MinimumLevel or Logger.Levels.INFO
Logger.MaximumEntries = 500
Logger.StoreVerboseEntries = Logger.StoreVerboseEntries or false
Logger.Entries = Logger.Entries or {}
Logger.FunctionMetrics = Logger.FunctionMetrics or {}
Logger.RateLimits = Logger.RateLimits or {}

local function stringify(value)
    if value == nil then return "nil" end
    if type(value) == "table" then
        local parts = {}
        for key, item in pairs(value) do
            parts[#parts + 1] = tostring(key) .. "=" .. tostring(item)
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return tostring(value)
end

local function emit(levelName, scope, message, fields)
    local level = Logger.Levels[levelName] or Logger.Levels.INFO
    local now = Constants.NowMs()
    local entry = {
        at = now,
        level = levelName,
        scope = tostring(scope or "General"),
        message = tostring(message or ""),
        fields = fields,
    }
    if level >= Logger.MinimumLevel or Logger.StoreVerboseEntries then
        Logger.Entries[#Logger.Entries + 1] = entry
        if #Logger.Entries > Logger.MaximumEntries then
            table.remove(Logger.Entries, 1)
        end
    end
    if level >= Logger.MinimumLevel then
        local suffix = fields and (" " .. stringify(fields)) or ""
        print(string.format("[BonkZone][%s][%s] %s%s", levelName, entry.scope, entry.message, suffix))
    end
end

function Logger.Trace(scope, message, fields)
    emit("TRACE", scope, message, fields)
end

function Logger.Debug(scope, message, fields)
    emit("DEBUG", scope, message, fields)
end

function Logger.Info(scope, message, fields)
    emit("INFO", scope, message, fields)
end

function Logger.Warn(scope, message, fields)
    emit("WARN", scope, message, fields)
end

function Logger.Error(scope, message, fields)
    emit("ERROR", scope, message, fields)
end

function Logger.RateLimited(levelName, key, intervalMs, scope, message, fields)
    local now = Constants.NowMs()
    local last = Logger.RateLimits[key] or 0
    if now - last < intervalMs then return false end
    Logger.RateLimits[key] = now
    emit(levelName, scope, message, fields)
    return true
end

function Logger.Begin(functionName, fields)
    Logger.Trace(functionName, "begin", fields)
    return Constants.NowMs()
end

function Logger.Finish(functionName, startedAt, success, fields)
    local elapsed = math.max(0, Constants.NowMs() - (tonumber(startedAt) or Constants.NowMs()))
    local metrics = Logger.FunctionMetrics[functionName]
    if not metrics then
        metrics = { calls = 0, failures = 0, totalMs = 0, maxMs = 0 }
        Logger.FunctionMetrics[functionName] = metrics
    end
    metrics.calls = metrics.calls + 1
    metrics.totalMs = metrics.totalMs + elapsed
    metrics.maxMs = math.max(metrics.maxMs, elapsed)
    if success == false then metrics.failures = metrics.failures + 1 end
    Logger.Trace(functionName, "end", { elapsedMs = elapsed, success = success ~= false, detail = fields })
    return elapsed
end

function Logger.DumpMetaTimeRunLog(context)
    local startedAt = Logger.Begin("Logger.DumpMetaTimeRunLog", { context = context })
    Logger.Info("MetaTimeRunLog", "BEGIN " .. tostring(context or "runtime"))
    local names = {}
    for name in pairs(Logger.FunctionMetrics) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local metric = Logger.FunctionMetrics[name]
        local average = metric.calls > 0 and (metric.totalMs / metric.calls) or 0
        Logger.Info("MetaTimeRunLog", name, {
            calls = metric.calls,
            failures = metric.failures,
            totalMs = metric.totalMs,
            averageMs = string.format("%.2f", average),
            maxMs = metric.maxMs,
        })
    end
    Logger.Info("MetaTimeRunLog", "END " .. tostring(context or "runtime"))
    Logger.Finish("Logger.DumpMetaTimeRunLog", startedAt, true)
end

return Logger
