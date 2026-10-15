require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"

local SO = SacrificialOffering
SO.Logger = SO.Logger or {}
local Logger = SO.Logger

local LEVELS = { TRACE = 1, DEBUG = 2, INFO = 3, WARN = 4, ERROR = 5 }

local function traceEnabled()
    return SandboxVars and SandboxVars.SacrificialOffering and SandboxVars.SacrificialOffering.TraceLogging == true
end

local function enabled(level)
    if level == "TRACE" then return traceEnabled() end
    if level == "DEBUG" then return traceEnabled() end
    return LEVELS[level] ~= nil
end

local function fieldsToString(fields)
    if type(fields) ~= "table" then return "" end
    local keys = {}
    for key in pairs(fields) do table.insert(keys, tostring(key)) end
    table.sort(keys)
    local values = {}
    for _, key in ipairs(keys) do
        local value = fields[key]
        if value ~= nil then table.insert(values, key .. "=" .. tostring(value)) end
    end
    if #values == 0 then return "" end
    return " [" .. table.concat(values, " ") .. "]"
end

function Logger.Write(level, message, fields)
    level = LEVELS[level] and level or "INFO"
    if not enabled(level) then return end
    print(string.format("[SacrificialOffering][%s] %s%s", level, tostring(message), fieldsToString(fields)))
end

function Logger.Trace(message, fields) Logger.Write("TRACE", message, fields) end
function Logger.Debug(message, fields) Logger.Write("DEBUG", message, fields) end
function Logger.Info(message, fields) Logger.Write("INFO", message, fields) end
function Logger.Warn(message, fields) Logger.Write("WARN", message, fields) end
function Logger.Error(message, fields) Logger.Write("ERROR", message, fields) end

-- Outcomes worth one line on a normal (non-trace) server: real recovery/wrath
-- events, failures, and admin zone mutations. Everything else -- ignored clicks,
-- "no recovery", busy, pending -- only shows when TraceLogging is on.
local NOTABLE_OUTCOMES = {
    success = true, wrath = true, ["minor-wrath"] = true, ["self-corpse"] = true,
    error = true, created = true, resized = true, deleted = true,
    rejected = true, denied = true, purged = true,
}

function Logger.BeginRun(kind, transactionId, fields)
    local run = {
        kind = kind or "run",
        transactionId = transactionId or SO.Util.NewTransactionId(kind),
        startedAt = SO.Util.NowMs(),
        steps = 0,
    }
    fields = SO.Util.ShallowCopy(fields)
    fields.tx = run.transactionId
    Logger.Debug("META RUN BEGIN " .. run.kind, fields)
    return run
end

function Logger.Step(run, step, fields)
    if not run then return end
    run.steps = run.steps + 1
    fields = SO.Util.ShallowCopy(fields)
    fields.tx = run.transactionId
    fields.step = run.steps
    fields.elapsedMs = SO.Util.NowMs() - run.startedAt
    Logger.Debug("META RUN STEP " .. tostring(step), fields)
end

function Logger.EndRun(run, outcome, fields)
    if not run then return end
    outcome = outcome or "unknown"
    fields = SO.Util.ShallowCopy(fields)
    fields.tx = run.transactionId
    fields.outcome = outcome
    fields.steps = run.steps
    fields.elapsedMs = SO.Util.NowMs() - run.startedAt
    if NOTABLE_OUTCOMES[outcome] or fields.error ~= nil then
        Logger.Info("META RUN END " .. run.kind, fields)
    else
        Logger.Debug("META RUN END " .. run.kind, fields)
    end
end

return Logger
