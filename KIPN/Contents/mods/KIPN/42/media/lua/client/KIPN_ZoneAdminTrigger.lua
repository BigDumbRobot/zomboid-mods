-- KIPN_ZoneAdminTrigger.lua
--
-- Adds a "KIPN: Zone Admin Tool" entry to the world right-click
-- context menu, visible only to admins, which opens/closes the
-- KIPN_ZoneAdminUI panel.
--
-- NOTE ON TRIGGER CHOICE:
-- This is a context-menu entry rather than a hotkey or slash
-- command because it's the most reliable, well-established way
-- to gate a Lua-side action behind admin status without needing
-- a custom keybinding registration. If you'd prefer a keybind or
-- a dedicated button elsewhere in your KIPN UI, this file is the
-- only one that needs to change — KIPN_ZoneAdminUI.Toggle() is
-- the entry point either way.
--
-- ADMIN CHECK: KIPN_AdminAccess uses the server-resolved KIPN level,
-- including KIPN.AdminAccounts, with native PZ admin state only as an
-- immediate presentation hint while that response is pending.

require "ISUI/ISWorldObjectContextMenu"
require "KIPN_AdminAccess"
require "KIPN_ZoneAdminUI"

local function hasZoneAdminAccess(playerNum)
    return KIPN.Client.AdminAccess.IsAdmin(playerNum)
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test then return end

    if not hasZoneAdminAccess(playerNum) then
        return
    end

    context:addOption("KIPN: Zone Admin Tool", nil, function()
        KIPN_ZoneAdminUI.Toggle()
    end)
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

print("[KIPN] Zone Admin trigger loaded")
