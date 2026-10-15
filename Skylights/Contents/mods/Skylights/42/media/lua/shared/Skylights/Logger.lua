--- Console logger for Skylights.
---
--- `info` / `warn` / `error` print one prefixed line. `time` wraps a gameplay
--- entry point so a failure is logged once with its context before the engine
--- handles it; never wrap per-frame paths with it.

local Config = require("Skylights/Config")

local Logger = SkylightsLogger or {}

local function formatFields(fields)
    if type(fields) ~= "table" then
        return ""
    end

    local keys = {}
    for key in pairs(fields) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)

    if #keys == 0 then
        return ""
    end

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = key .. "=" .. tostring(fields[key])
    end
    return " | " .. table.concat(parts, ", ")
end

local function emit(level, context, message, fields)
    print(string.format(
        "%s [%s] %s%s%s",
        Config.LOG_PREFIX,
        level,
        tostring(context),
        message ~= nil and (": " .. tostring(message)) or "",
        formatFields(fields)
    ))
end

function Logger.info(context, message, fields)
    emit("INFO", context, message, fields)
end

function Logger.warn(context, message, fields)
    emit("WARN", context, message, fields)
end

function Logger.error(context, message, fields)
    emit("ERROR", context, message, fields)
end

local unpackValues = unpack or table.unpack

local function packValues(...)
    return select("#", ...), { ... }
end

--- Runs `callback(...)`; on failure logs the error with `context` and re-raises it.
function Logger.time(context, callback, ...)
    local count, results = packValues(pcall(callback, ...))
    if not results[1] then
        emit("ERROR", context, tostring(results[2]))
        error(results[2], 0)
    end
    return unpackValues(results, 2, count)
end

SkylightsLogger = Logger

return Logger
