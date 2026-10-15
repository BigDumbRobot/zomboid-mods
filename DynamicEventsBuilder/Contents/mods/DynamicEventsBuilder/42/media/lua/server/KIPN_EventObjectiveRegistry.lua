-- KIPN_EventObjectiveRegistry.lua
--
-- Generic, objective-agnostic control/dispatch registry for the
-- Event Scenarios feature.
--
-- This file must NEVER contain logic specific to any one objective
-- type (Horde Survival, or any future type). It only stores what
-- each objective type registers about itself and dispatches control
-- clicks to it.
--
-- An objective type registers one entry:
--
--   {
--       displayName = "Horde Survival",
--       controls = {
--           { id = "spawn_burst", label = "Spawn Horde Burst", defaultParams = {...}, group = "ZOMBIES" },
--           ...
--       },
--       handlers = {
--           spawn_burst = function(runtime, definition, params) ... end,
--           ...
--       },
--       sliders = {
--           { id = "spawn_rate", label = "Spawn Rate", min = 0, max = 100, step = 1, defaultValue = 50, group = "ZOMBIES" },
--           ...
--       },
--       sliderHandlers = {
--           spawn_rate = function(runtime, definition, params) ... end,  -- params.value is the new slider value
--           ...
--       },
--       winConditions = {
--           { id = "zone_cleared", label = "Zone cleared of zombies", defaultParams = {} },
--           ...
--       },
--       failConditions = {
--           { id = "all_participants_down", label = "All participants down", defaultParams = {} },
--           ...
--       },
--       winConditionHandlers = {
--           zone_cleared = function(runtime, definition, params) return true/false end,
--           ...
--       },
--       failConditionHandlers = { ... },  -- same shape as winConditionHandlers
--       onTick = function(runtime, definition) ... end,  -- optional
--   }
--
-- `controls`/`sliders`/`winConditions`/`failConditions` are sent
-- verbatim to the client (id/label/defaultParams, or id/label/min/
-- max/step/defaultValue for sliders -- both also carry `group` as a
-- pure client-side layout hint) so the definition editor and live
-- control panels (KIPN_EventDirectorControlUI.lua, and the tiered
-- KIPN_EventDirectorPanel.lua) can render themselves without any
-- objective-specific client code. `handlers`/`sliderHandlers`/
-- `winConditionHandlers`/`failConditionHandlers`/`onTick` never leave
-- the server.
--
-- An Event Definition selects zero or more registered win/fail
-- conditions by id (KIPN_EventScenarioService.lua validates the
-- selection against this registry at save time). At runtime,
-- KIPN_EventRuntimeService.lua's tick loop evaluates only the
-- SELECTED conditions each tick via EvaluateWinConditions/
-- EvaluateFailConditions -- an unselected registered condition is
-- simply never checked for that event.
--
-- See KIPN_ZombieDirector.lua for the concrete Horde Survival
-- plug-in built on top of this file.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

KIPN.Server.EventObjectiveRegistry = KIPN.Server.EventObjectiveRegistry or {}

local Registry = KIPN.Server.EventObjectiveRegistry

Registry.Registry = Registry.Registry or {}

local function log(message)
    print("[KIPN EVENT OBJECTIVE REGISTRY] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT OBJECTIVE REGISTRY] ERROR: " .. tostring(message))
end

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

function Registry.Register(objectiveType, entry)
    if type(objectiveType) ~= "string" or objectiveType == "" then
        logError("Registration rejected: missing objective type.")
        return false
    end

    if type(entry) ~= "table" then
        logError("Registration rejected: entry is not a table.")
        return false
    end

    if Registry.Registry[objectiveType] then
        logError("Objective type already registered: " .. tostring(objectiveType))
        return false
    end

    entry.displayName = entry.displayName or objectiveType
    entry.controls = type(entry.controls) == "table" and entry.controls or {}
    entry.handlers = type(entry.handlers) == "table" and entry.handlers or {}
    entry.sliders = type(entry.sliders) == "table" and entry.sliders or {}
    entry.sliderHandlers = type(entry.sliderHandlers) == "table" and entry.sliderHandlers or {}
    entry.winConditions = type(entry.winConditions) == "table" and entry.winConditions or {}
    entry.failConditions = type(entry.failConditions) == "table" and entry.failConditions or {}
    entry.winConditionHandlers = type(entry.winConditionHandlers) == "table" and entry.winConditionHandlers or {}
    entry.failConditionHandlers = type(entry.failConditionHandlers) == "table" and entry.failConditionHandlers or {}

    Registry.Registry[objectiveType] = entry

    log("Registered objective type: " .. tostring(objectiveType))

    return true
end

------------------------------------------------------------
-- LOOKUP
------------------------------------------------------------

function Registry.Get(objectiveType)
    if not objectiveType then
        return nil
    end

    return Registry.Registry[objectiveType]
end

function Registry.GetAll()
    local result = {}

    for objectiveType, entry in pairs(Registry.Registry) do
        result[objectiveType] = { id = objectiveType, displayName = entry.displayName }
    end

    return result
end

------------------------------------------------------------
-- CLIENT-SAFE CONTROL LIST
------------------------------------------------------------
--
-- Only id/label/defaultParams -- never handler functions.
------------------------------------------------------------

local function extractIdLabelParams(list)
    local result = {}

    for _, item in ipairs(list or {}) do
        result[#result + 1] = {
            id = item.id,
            label = item.label,
            defaultParams = item.defaultParams or {},
            paramFields = item.paramFields or {},
            objectiveTypes = item.objectiveTypes or {},
            -- Pure client-side layout hint (which section of the
            -- floating Event Director panel a button belongs in --
            -- ZOMBIES/EVENT/COMBAT/DIFFICULTY). Never branched on
            -- server-side. Defaults to ZOMBIES since every control
            -- registered so far is a spawn-director action.
            group = item.group or "ZOMBIES",
        }
    end

    return result
end

------------------------------------------------------------
-- CLIENT-SAFE SLIDER LIST
------------------------------------------------------------
--
-- Same id/label/group idiom as extractIdLabelParams above, plus the
-- numeric range a slider widget needs (min/max/step/defaultValue).
-- Never handler functions.
------------------------------------------------------------

local function extractSliderList(list)
    local result = {}

    for _, item in ipairs(list or {}) do
        result[#result + 1] = {
            id = item.id,
            label = item.label,
            min = item.min or 0,
            max = item.max or 100,
            step = item.step or 1,
            defaultValue = item.defaultValue or 0,
            group = item.group or "ZOMBIES",
        }
    end

    return result
end

function Registry.GetControls(objectiveType)
    local entry = Registry.Get(objectiveType)

    if not entry then
        return {}
    end

    return extractIdLabelParams(entry.controls)
end

function Registry.GetSliders(objectiveType)
    local entry = Registry.Get(objectiveType)

    if not entry then
        return {}
    end

    return extractSliderList(entry.sliders)
end

function Registry.GetWinConditions(objectiveType)
    local entry = Registry.Get(objectiveType)

    if not entry then
        return {}
    end

    return extractIdLabelParams(entry.winConditions)
end

function Registry.GetFailConditions(objectiveType)
    local entry = Registry.Get(objectiveType)

    if not entry then
        return {}
    end

    return extractIdLabelParams(entry.failConditions)
end

------------------------------------------------------------
-- CONDITION VALIDATION
------------------------------------------------------------
--
-- Used by KIPN_EventScenarioService.lua at save time to reject a
-- winCondition/failCondition id that isn't actually registered for
-- the definition's eventType.
------------------------------------------------------------

function Registry.IsValidWinCondition(objectiveType, conditionId)
    local entry = Registry.Get(objectiveType)
    return entry ~= nil and type(entry.winConditionHandlers[conditionId]) == "function"
end

function Registry.IsValidFailCondition(objectiveType, conditionId)
    local entry = Registry.Get(objectiveType)
    return entry ~= nil and type(entry.failConditionHandlers[conditionId]) == "function"
end

------------------------------------------------------------
-- DISPATCH
------------------------------------------------------------
--
-- Runs the registered handler for controlId under the given
-- objective type. Always pcall-wrapped -- a broken/erroring
-- objective handler must never crash the caller (the command
-- handler in KIPN_EventRuntimeService.lua).
------------------------------------------------------------

function Registry.Dispatch(objectiveType, controlId, runtime, definition, params)
    local entry = Registry.Get(objectiveType)

    if not entry then
        return false, "UNKNOWN_OBJECTIVE_TYPE"
    end

    local handler = entry.handlers[controlId]

    if type(handler) ~= "function" then
        return false, "UNKNOWN_CONTROL"
    end

    local ok, result = pcall(handler, runtime, definition, params or {})

    if not ok then
        logError(
            "Control handler failed: objectiveType=" .. tostring(objectiveType)
            .. " controlId=" .. tostring(controlId)
            .. " error=" .. tostring(result)
        )

        return false, "HANDLER_ERROR"
    end

    return true, result
end

------------------------------------------------------------
-- DISPATCH SLIDER
------------------------------------------------------------
--
-- Same shape as Dispatch, for the parallel sliders/sliderHandlers
-- registration. `params` is expected to carry `value`, the slider's
-- new numeric position.
------------------------------------------------------------

function Registry.DispatchSlider(objectiveType, sliderId, runtime, definition, params)
    local entry = Registry.Get(objectiveType)

    if not entry then
        return false, "UNKNOWN_OBJECTIVE_TYPE"
    end

    local handler = entry.sliderHandlers[sliderId]

    if type(handler) ~= "function" then
        return false, "UNKNOWN_SLIDER"
    end

    local ok, result = pcall(handler, runtime, definition, params or {})

    if not ok then
        logError(
            "Slider handler failed: objectiveType=" .. tostring(objectiveType)
            .. " sliderId=" .. tostring(sliderId)
            .. " error=" .. tostring(result)
        )

        return false, "HANDLER_ERROR"
    end

    return true, result
end

------------------------------------------------------------
-- CONDITION EVALUATION
------------------------------------------------------------
--
-- selectedConditions is the definition's own list of
-- { conditionId, params } entries (definition.winConditions /
-- definition.failConditions). Returns true, matchedConditionId on
-- the first selected condition whose handler returns true; false,
-- nil if none matched. Each handler call is pcall-wrapped -- a
-- broken condition handler must never crash the runtime tick loop.
------------------------------------------------------------

local function evaluateConditions(objectiveType, handlerBag, selectedConditions, runtime, definition)
    local entry = Registry.Get(objectiveType)

    if not entry or not selectedConditions then
        return false, nil
    end

    for _, selected in ipairs(selectedConditions) do
        local handler = entry[handlerBag][selected.conditionId]

        if type(handler) == "function" then
            local ok, result = pcall(handler, runtime, definition, selected.params or {})

            if not ok then
                logError(
                    "Condition handler failed: objectiveType=" .. tostring(objectiveType)
                    .. " conditionId=" .. tostring(selected.conditionId)
                    .. " error=" .. tostring(result)
                )
            elseif result == true then
                return true, selected.conditionId
            end
        end
    end

    return false, nil
end

function Registry.EvaluateWinConditions(objectiveType, selectedConditions, runtime, definition)
    return evaluateConditions(objectiveType, "winConditionHandlers", selectedConditions, runtime, definition)
end

function Registry.EvaluateFailConditions(objectiveType, selectedConditions, runtime, definition)
    return evaluateConditions(objectiveType, "failConditionHandlers", selectedConditions, runtime, definition)
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------
--
-- No dependencies of its own -- pure infrastructure. Objective
-- types register themselves at their own file's load time (see
-- KIPN_ZombieDirector.lua), which is guaranteed to run after this
-- file per the require order in KIPN_Server.lua.
------------------------------------------------------------

function Registry.Initialize()
    return true
end

print("[KIPN] Event Objective Registry loaded")
