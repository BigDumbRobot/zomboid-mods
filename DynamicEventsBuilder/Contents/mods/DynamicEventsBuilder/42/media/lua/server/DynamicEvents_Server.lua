-- DynamicEvents_Server.lua
--
-- Starts the event services. KIPN's own server start used to do this
-- (KIPN_Server.lua's initializeService list) until Dynamic Events was
-- split out; since then nothing called them, so no event command had
-- a handler and no event ever ticked.
--
-- Runs on the same two engine events KIPN initialises on
-- (OnInitGlobalModData, OnGameStart); KIPN is loaded first, so its
-- command router and data are ready. Guarded so it runs once.

if isClient() and not isServer() then return end

require "DynamicEvents_KIPNCompat"
require "KIPN_EventAccessService"
require "KIPN_EventMoveService"
require "KIPN_EventBanditService"
require "KIPN_EventObjectiveRegistry"
require "KIPN_EventModeRegistry"
require "KIPN_EventTeamService"
require "KIPN_EventEscrowService"
require "KIPN_EventTimerService"
require "KIPN_EventZombieThemeRegistry"
require "KIPN_EventHotspotService"
require "KIPN_EventScenarioRuntimeRegistry"
require "KIPN_ZombieDirector"
require "KIPN_EventTriggerService"
require "KIPN_EventCaptureService"
require "KIPN_EventKOTHService"
require "KIPN_EventChaseService"
require "KIPN_EventExtractionService"
require "KIPN_EventSurvivorRunService"
require "KIPN_EventAdventureService"
require "KIPN_EventScenarioService"
require "KIPN_EventParticipationService"
require "KIPN_EventRewardService"
require "KIPN_EventRuntimeService"
require "KIPN_EventDirector"
require "KIPN_EventGameLoopService"
require "KIPN_EventOlympicsService"
require "KIPN_EventThreatService"
require "KIPN_EventLoadoutService"
require "KIPN_EventHistoryService"
require "KIPN_EventControlService"
require "KIPN_EventSimulationService"

-- Same order as KIPN's original list: registries before the services
-- that read them, the runtime and Director last.
local SERVICES = {
    "EventObjectiveRegistry", "EventModeRegistry", "EventTeamService", "EventEscrowService",
    "EventTimerService", "EventZombieThemeRegistry", "EventHotspotService", "EventScenarioRuntimeRegistry",
    "ZombieDirector", "EventTriggerService", "EventCaptureService", "EventKOTHService", "EventChaseService",
    "EventExtractionService", "EventSurvivorRunService", "EventAdventureService", "EventScenarioService",
    "EventParticipationService", "EventRewardService", "EventRuntimeService", "EventDirector",
    "EventOlympicsService", "EventThreatService", "EventLoadoutService", "EventBanditService",
    "EventHistoryService", "EventControlService", "EventSimulationService",
}

local started = false

local function startEventServices()
    if started then return end
    if not (KIPN and KIPN.Server and KIPN.Server.RegisterCommandHandler) then
        print("[Dynamic Events] KIPN's server is not loaded; event services not started.")
        return
    end
    started = true
    for _, name in ipairs(SERVICES) do
        local service = KIPN.Server[name]
        if type(service) == "table" and type(service.Initialize) == "function" then
            local ok, err = pcall(service.Initialize)
            if not ok then print("[Dynamic Events] " .. name .. ".Initialize failed: " .. tostring(err)) end
        else
            print("[Dynamic Events] " .. name .. " is missing; skipped.")
        end
    end
    print("[Dynamic Events] event services started")
end

Events.OnInitGlobalModData.Add(startEventServices)
Events.OnGameStart.Add(startEventServices)
