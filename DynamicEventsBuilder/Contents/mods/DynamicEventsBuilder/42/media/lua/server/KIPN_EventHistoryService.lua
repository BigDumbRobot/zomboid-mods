-- KIPN_EventHistoryService.lua
--
-- Past events: one record per run that ended, newest first, kept in
-- ModData ("DynamicEventsHistory", at most EventHistoryLimit records).
-- The Event Studio lists them (EVENT_LIST_HISTORY). Recorded from
-- KIPN_EventGameLoopService.Finish (a run that went live) and from
-- KIPN_EventControlService (a run cancelled before it began).

if isClient() and not isServer() then return end

require "KIPN_Shared"
require "DynamicEvents_Shared"
require "KIPN_EventAccessService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventHistoryService = KIPN.Server.EventHistoryService or {}

local History = KIPN.Server.EventHistoryService

History.DATA_KEY = "DynamicEventsHistory"

local function log(message)
    print("[DYNAMIC EVENTS HISTORY] " .. tostring(message))
end

local function records()
    local ok, data = pcall(function() return ModData.getOrCreate(History.DATA_KEY) end)
    if not ok or type(data) ~= "table" then return nil end
    data.records = type(data.records) == "table" and data.records or {}
    return data.records
end

local function worldDay()
    local ok, hours = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and math.floor((tonumber(hours) or 0) / 24) + 1 or nil
end

local function sortedKeys(set)
    local out = {}
    for key in pairs(set or {}) do out[#out + 1] = tostring(key) end
    table.sort(out)
    return out
end

-- entry: { definition, outcome, result, runtime? }
function History.Record(definition, outcome, result, runtime)
    local list = records()
    if not list or not definition then return nil end
    local nowMs = (type(getTimestampMs) == "function" and getTimestampMs()) or 0
    local deaths = 0
    for _ in pairs(runtime and runtime.deaths or {}) do deaths = deaths + 1 end
    local record = {
        id = tostring(definition.id) .. ":" .. tostring(nowMs),
        definitionId = definition.id,
        name = definition.name,
        mode = definition.mode,
        variant = definition.variant,
        outcome = outcome,
        result = result,
        startedAtMs = runtime and runtime.startedAtMs or nil,
        endedAtMs = nowMs,
        day = worldDay(),
        difficulty = runtime and runtime.difficulty or definition.difficulty,
        participants = sortedKeys(runtime and runtime.participants or definition.participants),
        winners = sortedKeys(runtime and runtime.winners),
        deaths = deaths,
    }
    table.insert(list, 1, record)
    while #list > (KIPN.Shared.EventHistoryLimit or 50) do table.remove(list) end
    log("recorded " .. tostring(record.name) .. " -> " .. tostring(outcome))
    return record
end

function History.List()
    return records() or {}
end

local function handleListHistory(player)
    if not KIPN.Server.EventAccessService.RequireStudio(player) then
        return false
    end
    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_HISTORY_DATA, { records = History.List() })
    return true
end

function History.Initialize()
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_LIST_HISTORY, handleListHistory)
    log("Initialize()")
    return true
end

return History
