-- KIPN_EventDirectorControlUI.lua
--
-- Small, fully data-driven renderer for the "live control panel"
-- shown while an Event Scenario is RUNNING.
--
-- This file has ZERO knowledge of any objective type (Horde
-- Survival or otherwise). It only renders whatever `controls` array
-- the server sent (id/label/defaultParams -- see
-- KIPN_EventObjectiveRegistry.lua on the server) as a button per
-- control, and always sends the one generic EVENT_RUNTIME_CONTROL
-- command on click. A future objective type therefore needs zero
-- changes here -- its controls just start appearing.
--
-- BuildWidgets() is not an ISPanel of its own -- it builds widgets
-- directly onto KIPN_EventScenarioAdminUI.lua. Toggle() is the public
-- entry point used by the Event Zone right-click menu; it opens the
-- full floating KIPN_EventDirectorPanel, which also includes sliders
-- and tiered director commands in addition to objective controls.

require "ISUI/ISButton"
require "ISUI/ISLabel"
require "KIPN_EventDirectorPanel"

KIPN_EventDirectorControlUI = KIPN_EventDirectorControlUI or {}

local ROW_HEIGHT = 26
local BUTTON_WIDTH = 200
local BUTTON_HEIGHT = 24

------------------------------------------------------------
-- RIGHT-CLICK ENTRY POINT
------------------------------------------------------------

function KIPN_EventDirectorControlUI.Toggle()
    KIPN_EventDirectorPanel.Toggle()
end

------------------------------------------------------------
-- BUILD WIDGETS
------------------------------------------------------------
--
-- parentPanel: the ISPanel to attach widgets to (must implement
--              :addChild).
-- x, y, width: layout origin/width to render within.
-- controls:    array of { id, label, defaultParams } from the
--              server's EVENT_STATUS_DATA/EVENT_STARTED payload.
-- onControlClick: function(controlId, params) called when a
--                 control button is clicked.
--
-- Returns: { widgets = {...}, height = totalHeightUsed }
------------------------------------------------------------

function KIPN_EventDirectorControlUI.BuildWidgets(parentPanel, x, y, width, controls, onControlClick)
    local widgets = {}

    local header = ISLabel:new(x, y, ROW_HEIGHT, "Live Controls", 1, 1, 1, 1, UIFont.Small, true)
    header:initialise()
    parentPanel:addChild(header)
    widgets[#widgets + 1] = header

    local rowY = y + ROW_HEIGHT

    if not controls or #controls == 0 then
        local emptyLabel = ISLabel:new(x, rowY, ROW_HEIGHT, "No controls available for this objective type.", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
        emptyLabel:initialise()
        parentPanel:addChild(emptyLabel)
        widgets[#widgets + 1] = emptyLabel

        return { widgets = widgets, height = ROW_HEIGHT * 2 }
    end

    for _, control in ipairs(controls) do
        local button = ISButton:new(x, rowY, BUTTON_WIDTH, BUTTON_HEIGHT, control.label or control.id, parentPanel, function()
            onControlClick(control.id, control.defaultParams or {})
        end)

        button:initialise()
        button:instantiate()
        parentPanel:addChild(button)
        widgets[#widgets + 1] = button

        rowY = rowY + BUTTON_HEIGHT + 6
    end

    return { widgets = widgets, height = rowY - y }
end

print("[KIPN] Event Director Control UI loaded")
