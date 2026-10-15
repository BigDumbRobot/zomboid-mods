-- KIPN_EventDirectorTrigger.lua
--
-- The world right-click entries for Dynamic Events.
--
--   "Dynamic Events"                    opens the Event Studio, the main
--       event window (saved, prepared and past events). Admins always
--       see it; other KIPN staff levels see it when the sandbox allows
--       them (DynamicEvents.Studio<Level>, see DynamicEvents_Shared.lua).
--   "Dynamic Events: Director Controls" the live controls for a running
--       event, for every KIPN staff level (Moderator, Staff, GM,
--       Observer and Admin). Each control keeps its own tier.
--
-- A context-menu entry is the established way in this codebase to gate
-- a Lua-side action without a custom keybind (see KIPN_ZoneAdminTrigger.lua).
-- The level comes from KIPN_AdminAccess (resolved by the server through
-- GET_PLAYER_DATA / Permissions.ResolveAccessLevel, including
-- KIPN.AdminSteamIDs). It only decides what is shown: the server
-- re-checks every command (KIPN_EventAccessService.lua and the
-- Director's own tiers).
--
-- There is no Event Zone position gate: staff must be able to open these
-- from anywhere.

require "ISUI/ISWorldObjectContextMenu"
require "KIPN_AdminAccess"
require "KIPN_EventStudioUI"
require "KIPN_EventDirectorControlUI"
require "DynamicEvents_Shared"

KIPN_EventDirectorTrigger = KIPN_EventDirectorTrigger or {}
local Trigger = KIPN_EventDirectorTrigger

Trigger.STAFF_LEVELS = { ADMIN = true, MODERATOR = true, STAFF = true, GM = true, OBSERVER = true }

function Trigger.CanUseStudio(level)
    return KIPN.Shared.EventAccessAllows("Studio", level)
end

function Trigger.CanDirect(level)
    return Trigger.STAFF_LEVELS[level or ""] == true
end

local function tooltip(option, text)
    option.toolTip = ISWorldObjectContextMenu.addToolTip()
    option.toolTip.description = text
end

function Trigger.Fill(playerNum, context, worldobjects, test)
    if test then return end
    local level = KIPN.Client.AdminAccess.GetAccessLevel(playerNum)
    if Trigger.CanUseStudio(level) then
        tooltip(context:addOption("Dynamic Events", nil, function() KIPN_EventStudioUI.Open() end),
            "Open the event window: build events, run prepared ones, and look back at past events.")
    end
    if Trigger.CanDirect(level) then
        tooltip(context:addOption("Dynamic Events: Director Controls", nil, function() KIPN_EventDirectorControlUI.Toggle() end),
            "The live controls for a running event.")
    end
end

Events.OnFillWorldObjectContextMenu.Add(Trigger.Fill)

print("[KIPN] Dynamic Events menu loaded")
