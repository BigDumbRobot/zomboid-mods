-- KIPN_EventTeamService.lua
--
-- Phase 2 of the Event Scenarios architecture rewrite: reusable team
-- infrastructure for Capture and team King of the Hill (Chase uses
-- temporary Target/Hunter roles, not this service -- see the Event
-- Scenarios architecture audit's mode contracts).
--
-- Teams are persisted directly on the Event Definition
-- (definition.teams), the same way Hotspots are (see
-- KIPN_EventHotspotService.lua, whose requireAdmin/getWorldDays/
-- respond/getEditableDefinition idiom this file mirrors exactly so
-- the Event Scenarios command surface stays consistent).
--
-- Team shape: { id, name, color = {r,g,b}, members = { [username] =
-- true, ... } }. Names/colors come from a fixed, stable palette --
-- team 1 is always "Red Team" with the same color, regardless of how
-- many times teams are regenerated -- so a reconnecting player or a
-- refreshed admin UI never sees a team's identity change out from
-- under it.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_AdminService"
require "KIPN_EventAccessService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventTeamService = KIPN.Server.EventTeamService or {}

local TeamService = KIPN.Server.EventTeamService

------------------------------------------------------------
-- TEAM COUNT LIMITS
--
-- MIN_TEAMS=2 because "a team mode requires at least two valid
-- teams" is a hard mode contract requirement. MAX_TEAMS is bounded by
-- the size of TEAM_PALETTE below, not an arbitrary guess -- raising
-- it means adding another stable name/color pair to the palette, and
-- nothing else.
------------------------------------------------------------

local MIN_TEAMS = 2
local MAX_TEAMS = 8

local TEAM_PALETTE = {
    { name = "Red Team",    color = { r = 0.9,  g = 0.2,  b = 0.2 } },
    { name = "Blue Team",   color = { r = 0.25, g = 0.45, b = 1.0 } },
    { name = "Green Team",  color = { r = 0.25, g = 0.8,  b = 0.3 } },
    { name = "Yellow Team", color = { r = 0.95, g = 0.85, b = 0.15 } },
    { name = "Orange Team", color = { r = 1.0,  g = 0.55, b = 0.15 } },
    { name = "Purple Team", color = { r = 0.65, g = 0.3,  b = 0.9 } },
    { name = "Teal Team",   color = { r = 0.2,  g = 0.8,  b = 0.75 } },
    { name = "Pink Team",   color = { r = 0.95, g = 0.45, b = 0.75 } },
}

local function log(message)
    print("[KIPN EVENT TEAM] " .. tostring(message))
end

local function getWorldDays()
    local ok, result = pcall(function() return getGameTime():getWorldAgeHours() / 24 end)
    return ok and result or 0
end

-- Admins, and staff levels the sandbox allows (KIPN_EventAccessService.lua).
local function requireAdmin(player)
    return KIPN.Server.EventAccessService.RequireStudio(player)
end

------------------------------------------------------------
-- TEAM CREATION / DETERMINISTIC BALANCING
------------------------------------------------------------

local function countMembers(team)
    local count = 0
    for _ in pairs(team.members or {}) do count = count + 1 end
    return count
end

function TeamService.GetMaxTeams()
    return MAX_TEAMS
end

function TeamService.GetMinTeams()
    return MIN_TEAMS
end

-- Regenerates definition.teams from scratch with `teamCount` stable
-- palette entries. All existing membership is cleared -- callers that
-- want to keep manual assignments should not call this again once
-- teams already exist at the desired count; the admin UI (a later
-- phase) is expected to confirm before regenerating a live roster.
function TeamService.CreateTeams(definition, teamCount)
    teamCount = tonumber(teamCount)

    if not teamCount or teamCount ~= math.floor(teamCount) or teamCount < MIN_TEAMS or teamCount > MAX_TEAMS then
        return false, "INVALID_TEAM_COUNT"
    end

    local teams = {}
    for index = 1, teamCount do
        local palette = TEAM_PALETTE[index]
        teams[index] = {
            id = "team_" .. tostring(index),
            name = palette.name,
            color = palette.color,
            members = {},
        }
    end

    definition.teams = teams
    log("CreateTeams() -> " .. tostring(teamCount) .. " team(s) for " .. tostring(definition.id))
    return true
end

-- Assigns every roster member (definition.participants) not already
-- on a team to whichever team currently has the fewest members,
-- ties broken by team order. Never moves an already-assigned player,
-- so this is safe to call every time the roster changes (a new
-- accept) without disturbing prior manual reassignment -- see
-- KIPN_EventParticipationService.lua's handleAcceptParticipation.
function TeamService.AssignParticipantsDeterministically(definition)
    if type(definition.teams) ~= "table" or #definition.teams < 1 then
        return false, "NO_TEAMS"
    end

    local assigned = {}
    for _, team in ipairs(definition.teams) do
        for username in pairs(team.members or {}) do
            assigned[username] = true
        end
    end

    local unassigned = {}
    for username in pairs(definition.participants or {}) do
        if not assigned[username] then
            unassigned[#unassigned + 1] = username
        end
    end

    -- Deterministic order: same roster always balances the same way.
    table.sort(unassigned)

    for _, username in ipairs(unassigned) do
        local target = definition.teams[1]
        local targetCount = countMembers(target)

        for _, team in ipairs(definition.teams) do
            local count = countMembers(team)
            if count < targetCount then
                target = team
                targetCount = count
            end
        end

        target.members = target.members or {}
        target.members[username] = true
    end

    if #unassigned > 0 then
        log("AssignParticipantsDeterministically() -> placed " .. tostring(#unassigned) .. " player(s)")
    end

    return true
end

-- Manual admin override. Removes username from whatever team it was
-- on (if any) and places it on teamId. Persists immediately as part
-- of the definition, so it survives a UI refresh or the player
-- reconnecting exactly like every other definition field.
function TeamService.AssignPlayerToTeam(definition, username, teamId)
    if type(definition.teams) ~= "table" then
        return false, "NO_TEAMS"
    end

    if not username or not definition.participants or not definition.participants[username] then
        return false, "NOT_A_PARTICIPANT"
    end

    local targetTeam = nil
    for _, team in ipairs(definition.teams) do
        if team.members then team.members[username] = nil end
        if tostring(team.id) == tostring(teamId) then targetTeam = team end
    end

    if not targetTeam then
        return false, "TEAM_NOT_FOUND"
    end

    targetTeam.members = targetTeam.members or {}
    targetTeam.members[username] = true

    log("AssignPlayerToTeam() -> " .. tostring(username) .. " -> " .. tostring(targetTeam.id))
    return true
end

function TeamService.GetTeam(definition, teamId)
    for _, team in ipairs((definition and definition.teams) or {}) do
        if tostring(team.id) == tostring(teamId) then return team end
    end
    return nil
end

-- Returns the team id a player is on, or nil if unassigned/definition
-- has no teams. Used by KIPN_EventRuntimeService.lua's friendly-fire
-- check.
function TeamService.GetPlayerTeam(definition, username)
    if not username then return nil end
    for _, team in ipairs((definition and definition.teams) or {}) do
        if team.members and team.members[username] then return team.id end
    end
    return nil
end

------------------------------------------------------------
-- VALIDATION (called from KIPN_EventScenarioService.lua's
-- handleValidate when the resolved mode requires teams -- see
-- KIPN_EventModeRegistry.lua's usesTeams metadata)
------------------------------------------------------------

function TeamService.ValidateTeams(definition)
    local failures = {}
    local teamCount = type(definition.teams) == "table" and #definition.teams or 0

    if teamCount < MIN_TEAMS then
        failures[#failures + 1] = "TEAM_COUNT_TOO_LOW"
    end

    local ok = #failures == 0
    log("ValidateTeams() -> " .. tostring(ok) .. " failures=" .. table.concat(failures, ","))
    return ok, failures
end

------------------------------------------------------------
-- COMMAND HANDLERS
------------------------------------------------------------

local function respond(player, success, definition, reason)
    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_TEAM_SAVED, {
        success = success,
        definition = success and definition or nil,
        reason = success and nil or reason,
    })
end

local function getEditableDefinition(player, args)
    if not requireAdmin(player) then return nil, "PERMISSION_DENIED" end
    local service = KIPN.Server.EventScenarioService
    local definition = service and service.GetDefinition and service.GetDefinition(args and args.id)
    if not definition then return nil, "DEFINITION_NOT_FOUND" end
    if definition.status ~= "DRAFT" and definition.status ~= "READY" then return nil, "NOT_EDITABLE" end
    return definition
end

local function handleSetTeamCount(player, args)
    local definition, reason = getEditableDefinition(player, args)
    if not definition then respond(player, false, nil, reason) return true end

    local ok, createReason = TeamService.CreateTeams(definition, args and args.teamCount)
    if not ok then respond(player, false, nil, createReason) return true end

    TeamService.AssignParticipantsDeterministically(definition)

    definition.updatedAtWorldDays = getWorldDays()
    KIPN.Server.Save()
    KIPN.Server.AdminService.WriteAudit(player, "EVENT_TEAM_COUNT_SET", "eventDefinition", definition.id, {
        teamCount = #definition.teams,
    })
    log("handleSetTeamCount() -> definition=" .. tostring(definition.id) .. " teamCount=" .. tostring(#definition.teams))
    respond(player, true, definition)
    return true
end

local function handleAssignPlayerTeam(player, args)
    local definition, reason = getEditableDefinition(player, args)
    if not definition then respond(player, false, nil, reason) return true end

    local ok, assignReason = TeamService.AssignPlayerToTeam(definition, args and args.username, args and args.teamId)
    if not ok then respond(player, false, nil, assignReason) return true end

    definition.updatedAtWorldDays = getWorldDays()
    KIPN.Server.Save()
    KIPN.Server.AdminService.WriteAudit(player, "EVENT_PLAYER_TEAM_ASSIGNED", "eventDefinition", definition.id, {
        username = args.username,
        teamId = args.teamId,
    })
    log("handleAssignPlayerTeam() -> definition=" .. tostring(definition.id) .. " username=" .. tostring(args.username))
    respond(player, true, definition)
    return true
end

function TeamService.Initialize()
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_SET_TEAM_COUNT, handleSetTeamCount)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_ASSIGN_PLAYER_TEAM, handleAssignPlayerTeam)
    log("Initialize() -> registered team commands")
    return true
end

log("module loaded")
