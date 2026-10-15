-- KIPN_EventDirectorPanel.lua
--
-- The floating, tiered live-control panel for the currently ACTIVE
-- Event Scenario. Opened via the world right-click context menu
-- (KIPN_EventDirectorTrigger.lua) -- a genuine floating ISPanel, not
-- one of KIPN_MainMenu.lua's terminal-embedded "screens" (those get
-- wrapped inside a KIPN_Terminal frame via KIPN.UI.SetScreen, which
-- is the wrong lifecycle for a panel meant to stay usable while
-- moving around during a live event).
--
-- Server-authoritative, same as every other admin panel in this
-- codebase: every button here sends the SAME generic
-- EVENT_DIRECTOR_EXECUTE command (eventId/command/parameters) to
-- KIPN.Server.EventDirector.ExecuteCommand, which re-validates the
-- caller's tier from scratch. `self.status.allowedCategories` (sent
-- by the server on every response) only controls which sections THIS
-- panel renders -- it is never trusted as the actual authorization.
--
-- ZERO OBJECTIVE-TYPE KNOWLEDGE: the ZOMBIES/DIFFICULTY sections are
-- built entirely from whatever `controls`/`sliders` arrays the
-- server sends (see KIPN_EventObjectiveRegistry.lua's `group` field
-- on each entry) -- this file has never heard of Horde Survival and
-- doesn't need to change when a second objective type ships.
--
-- No eventId is ever chosen by the player: v1 only ever allows one
-- ACTIVE event globally, so GET_STATUS with no eventId resolves it
-- server-side (KIPN.Server.EventRuntimeService.GetActiveDefinitionId).

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "RadioCom/ISUIRadio/ISSliderPanel"

KIPN_EventDirectorPanel = ISPanel:derive("KIPN_EventDirectorPanel")

local PANEL_WIDTH = 460
local PAD = 10
local ROW_HEIGHT = 24
local ROW_GAP = 6
local BUTTON_HEIGHT = 24

-- Maps a registered slider's id to the runtime.directorState field
-- it reads its current value from (see KIPN_ZombieDirector.lua's
-- setSpawnRate/setWaveSize/setMaxZombies/setAggression). Falls back
-- to the slider's own defaultValue if the field isn't set yet --
-- same "or DEFAULT" idiom the server itself uses.
local SLIDER_STATE_FIELD = {
    spawn_rate = "spawnRate",
    wave_size = "waveSize",
    max_zombies = "maxZombies",
    aggression = "aggression",
}

local SECTION_ORDER = { "ZOMBIES", "EVENT", "COMBAT", "DIFFICULTY" }

-- Phase 5: the ALARM section below is deliberately NOT part of
-- SECTION_ORDER/groupControls -- Trigger Alarm is a fixed Event
-- Director command (KIPN_EventDirector.lua's TRIGGER_ALARM, GM_CONTROLS
-- tier), not an objective-type-registered control, so it must render
-- for every ACTIVE event regardless of which objective type/mode is
-- running -- see KIPN_EventDirector.lua's handleTriggerAlarm() header.
local ALARM_TARGET_MODE_OPTIONS = {
    { text = "Current Round Zone", value = "ROUND_ZONE" },
    { text = "Selected Hotspot", value = "HOTSPOT" },
    { text = "Every Alarm-Enabled Hotspot", value = "ALL_ALARM_ENABLED" },
}

local LOG_DISPLAY_LINES = 6

------------------------------------------------------------
-- SINGLETON ACCESS
------------------------------------------------------------

function KIPN_EventDirectorPanel.Toggle()
    if KIPN_EventDirectorPanel.instance and KIPN_EventDirectorPanel.instance:getIsVisible() then
        KIPN_EventDirectorPanel.instance:setVisible(false)
        KIPN_EventDirectorPanel.instance:removeFromUIManager()
        return
    end

    if not KIPN_EventDirectorPanel.instance then
        local screenW = getCore():getScreenWidth()
        local screenH = getCore():getScreenHeight()

        local panel = KIPN_EventDirectorPanel:new(
            screenW - PANEL_WIDTH - 40,
            60,
            PANEL_WIDTH,
            math.min(700, screenH - 100)
        )

        panel:initialise()
        panel:instantiate()

        KIPN_EventDirectorPanel.instance = panel
    end

    KIPN_EventDirectorPanel.instance:setVisible(true)
    KIPN_EventDirectorPanel.instance:addToUIManager()
    KIPN_EventDirectorPanel.instance:bringToTop()
    KIPN_EventDirectorPanel.instance:requestStatus()
end

------------------------------------------------------------
-- CONSTRUCTION
------------------------------------------------------------

function KIPN_EventDirectorPanel:new(x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.moveWithMouse = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.85 }
    o.borderColor = { r = 1, g = 1, b = 1, a = 0.4 }

    o.status = nil
    o.dynamicWidgets = {}
    o.pendingMessageText = ""
    o.pendingSliderUpdate = nil
    o.lastResultMessage = nil
    o.selectedParticipantUsername = nil
    o.alarmTargetMode = "ROUND_ZONE"
    o.alarmTargetHotspotId = nil

    return o
end

------------------------------------------------------------
-- CHILDREN
------------------------------------------------------------

function KIPN_EventDirectorPanel:createChildren()
    self.titleLabel = ISLabel:new(PAD, PAD, ROW_HEIGHT, "KIPN Event Director", 1, 1, 1, 1, UIFont.Medium, true)
    self:addChild(self.titleLabel)

    self.closeButton = ISButton:new(self.width - 30, 6, 20, 20, "X", self, KIPN_EventDirectorPanel.onClose)
    self:addChild(self.closeButton)

    self.subtitleLabel = ISLabel:new(PAD, PAD + ROW_HEIGHT, ROW_HEIGHT, "", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self:addChild(self.subtitleLabel)
end

------------------------------------------------------------
-- CLOSE
------------------------------------------------------------

function KIPN_EventDirectorPanel:onClose()
    self:setVisible(false)
    self:removeFromUIManager()
end

------------------------------------------------------------
-- COMMAND TRANSPORT
------------------------------------------------------------

function KIPN_EventDirectorPanel:sendCommand(command, parameters)
    local eventId = self.status and self.status.eventDefinitionId or nil

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_DIRECTOR_EXECUTE, {
        eventId = eventId,
        command = command,
        parameters = parameters or {},
    })
end

-- Status is fetched once when the panel opens, when the operator
-- presses Refresh, and after a setting/action command through the
-- command's server response. There is deliberately no :update()
-- poll: rebuilding dynamic controls on a timer interrupts slider
-- interaction and creates traffic while the operator does nothing.
function KIPN_EventDirectorPanel:requestStatus()
    self:sendCommand("GET_STATUS", {})
end

------------------------------------------------------------
-- DYNAMIC CONTENT
------------------------------------------------------------

function KIPN_EventDirectorPanel:clearDynamicWidgets()
    for _, widget in ipairs(self.dynamicWidgets) do
        self:removeChild(widget)
    end

    self.dynamicWidgets = {}
end

function KIPN_EventDirectorPanel:addDynamic(widget)
    self:addChild(widget)
    self.dynamicWidgets[#self.dynamicWidgets + 1] = widget
    return widget
end

local function sectionAllowed(allowedCategories, category)
    if not allowedCategories then
        return false
    end

    for _, allowed in ipairs(allowedCategories) do
        if allowed == category then
            return true
        end
    end

    return false
end

local function groupControls(controls, group)
    local result = {}

    for _, control in ipairs(controls or {}) do
        if (control.group or "ZOMBIES") == group then
            result[#result + 1] = control
        end
    end

    return result
end

------------------------------------------------------------
-- BUTTON ROW HELPER
--
-- Renders a horizontal pair of buttons at the given y, returns the
-- y for the next row. `buttons` is { { label, onclick }, ... },
-- 1 or 2 entries -- matches the mockup's two-buttons-per-row layout.
------------------------------------------------------------

function KIPN_EventDirectorPanel:addButtonRow(x, y, width, buttons)
    local gap = 6
    local count = #buttons
    local buttonWidth = count > 1 and ((width - gap * (count - 1)) / count) or width

    for i, entry in ipairs(buttons) do
        local bx = x + (i - 1) * (buttonWidth + gap)
        local button = ISButton:new(bx, y, buttonWidth, BUTTON_HEIGHT, entry.label, self, entry.onclick)
        button:initialise()
        button:instantiate()
        self:addDynamic(button)
    end

    return y + BUTTON_HEIGHT + ROW_GAP
end

------------------------------------------------------------
-- SLIDER ROW HELPER
------------------------------------------------------------

function KIPN_EventDirectorPanel:addSliderRow(x, y, width, sliderDef, currentValue)
    local label = ISLabel:new(x, y, ROW_HEIGHT, sliderDef.label .. ": " .. tostring(currentValue), 1, 1, 1, 1, UIFont.Small, true)
    self:addDynamic(label)
    y = y + ROW_HEIGHT

    local slider = ISSliderPanel:new(x, y, width, BUTTON_HEIGHT, self, KIPN_EventDirectorPanel.onSliderChanged)
    slider.kipnSliderId = sliderDef.id
    slider.kipnLabelWidget = label
    slider.kipnLabelText = sliderDef.label
    slider:initialise()
    slider:instantiate()
    slider:setValues(sliderDef.min, sliderDef.max, sliderDef.step, sliderDef.step)
    slider:setCurrentValue(currentValue, true)
    self:addDynamic(slider)

    return y + BUTTON_HEIGHT + ROW_GAP
end

function KIPN_EventDirectorPanel:onSliderChanged(value, sliderInstance)
    local sliderId = sliderInstance.kipnSliderId

    if sliderInstance.kipnLabelWidget then
        sliderInstance.kipnLabelWidget:setName(sliderInstance.kipnLabelText .. ": " .. tostring(math.floor(value)))
    end

    self.pendingSliderUpdate = {
        sliderId = sliderId,
        value = value,
        changedAtMs = getTimestampMs and getTimestampMs() or 0,
    }
end

-- Slider callbacks can fire for every pixel of a drag. Debouncing avoids a
-- server response rebuilding the panel while the operator is still dragging.
function KIPN_EventDirectorPanel:update()
    ISPanel.update(self)

    local pending = self.pendingSliderUpdate
    if not pending then return end

    local now = getTimestampMs and getTimestampMs() or pending.changedAtMs + 350
    if now - pending.changedAtMs < 350 then return end

    self.pendingSliderUpdate = nil
    self:sendCommand("SET_SLIDER", {
        sliderId = pending.sliderId,
        value = pending.value,
    })
end

------------------------------------------------------------
-- OBJECTIVE CONTROL CLICK
------------------------------------------------------------

function KIPN_EventDirectorPanel:onFireControl(controlId, defaultParams)
    local params = {}
    for key, value in pairs(defaultParams or {}) do params[key] = value end

    -- Generic participant context: scenario components may interpret this as
    -- a target, round winner, or objective completer; unrelated controls
    -- simply ignore the extra fields.
    if self.selectedParticipantUsername then
        params.username = self.selectedParticipantUsername
        params.winnerUsername = self.selectedParticipantUsername
    end

    self:sendCommand("RUNTIME_CONTROL", { controlId = controlId, params = params })
end

function KIPN_EventDirectorPanel:onParticipantSelectionChanged(combo)
    combo = combo or self.participantCombo
    local option = combo and combo.options[combo.selected]
    self.selectedParticipantUsername = option and option.data or nil
end

function KIPN_EventDirectorPanel:onAlarmTargetModeChanged(combo)
    combo = combo or self.alarmModeCombo
    local option = combo and combo.options[combo.selected]
    self.alarmTargetMode = (option and option.data) or "ROUND_ZONE"
    self:rebuildContent()
end

function KIPN_EventDirectorPanel:onAlarmHotspotSelectionChanged(combo)
    combo = combo or self.alarmHotspotCombo
    local option = combo and combo.options[combo.selected]
    self.alarmTargetHotspotId = option and option.data or nil
end

------------------------------------------------------------
-- REBUILD
--
-- Rebuilds every dynamic widget from self.status. Called after
-- every server response. Resizes the panel to fit its content
-- (clamped to the screen), since section count varies by tier and
-- objective type.
------------------------------------------------------------

function KIPN_EventDirectorPanel:rebuildContent()
    -- Preserve in-progress typing when a command response or manual
    -- refresh rebuilds the panel.
    if self.messageEntry then
        self.pendingMessageText = self.messageEntry:getText() or ""
    end

    self:clearDynamicWidgets()

    local x = PAD
    local width = self.width - (PAD * 2)
    local y = PAD + ROW_HEIGHT + ROW_HEIGHT + ROW_GAP

    local status = self.status

    if not status or status.status == "NO_ACTIVE_EVENT" or status.status == "NOT_FOUND" then
        self.subtitleLabel:setName("No active event.")

        if self.lastResultMessage then
            local resultLabel = ISLabel:new(x, y, ROW_HEIGHT, self.lastResultMessage, 1, 0.65, 0.35, 1, UIFont.Small, true)
            self:addDynamic(resultLabel)
            y = y + ROW_HEIGHT
        end

        local refreshButton = ISButton:new(x, y, width, BUTTON_HEIGHT, "Refresh", self, KIPN_EventDirectorPanel.requestStatus)
        refreshButton:initialise()
        refreshButton:instantiate()
        self:addDynamic(refreshButton)
        y = y + BUTTON_HEIGHT + ROW_GAP

        self:setHeight(math.min(y + PAD, getCore():getScreenHeight() - 100))
        return
    end

    local allowedCategories = status.allowedCategories or {}

    ------------------------------------------------------------
    -- HEADER
    ------------------------------------------------------------

    local subtitle = tostring(status.eventName or status.eventDefinitionId or "Event")
        .. " -- " .. tostring(status.status)
        .. " -- tier: " .. tostring(status.tier)

    if status.round then
        subtitle = subtitle .. " -- round " .. tostring(status.round.current or 1)
            .. "/" .. tostring(status.round.maximum or 1)
            .. " (" .. tostring(status.round.state or "ACTIVE") .. ")"
    end

    if status.endsAtMs and getTimestampMs then
        local remainingMs = status.endsAtMs - getTimestampMs()

        if remainingMs > 0 then
            subtitle = subtitle .. string.format(" -- %ds left", math.floor(remainingMs / 1000))
        end
    end

    self.subtitleLabel:setName(subtitle)

    if self.lastResultMessage then
        local resultColor = self.lastResultMessage:sub(1, 5) == "ERROR" and { 1, 0.45, 0.35 } or { 0.45, 1, 0.55 }
        local resultLabel = ISLabel:new(
            x, y, ROW_HEIGHT, self.lastResultMessage,
            resultColor[1], resultColor[2], resultColor[3], 1, UIFont.Small, true
        )
        self:addDynamic(resultLabel)
        y = y + ROW_HEIGHT
    end

    ------------------------------------------------------------
    -- SECTIONS
    ------------------------------------------------------------

    local controls = status.controls or {}
    local sliders = status.sliders or {}
    local directorState = status.directorState or {}

    for _, group in ipairs(SECTION_ORDER) do
        local groupControlList = groupControls(controls, group)
        local groupSliders = groupControls(sliders, group)

        local hasFixedButtons = (group == "EVENT" and sectionAllowed(allowedCategories, "LIFECYCLE_BASIC"))
            or (group == "COMBAT" and sectionAllowed(allowedCategories, "GM_CONTROLS"))

        local hasObjectiveContent = (#groupControlList > 0 or #groupSliders > 0)
            and sectionAllowed(allowedCategories, "GM_CONTROLS")

        if hasFixedButtons or hasObjectiveContent then
            local header = ISLabel:new(x, y, ROW_HEIGHT, group, 0.9, 0.9, 1, 1, UIFont.Small, true)
            self:addDynamic(header)
            y = y + ROW_HEIGHT

            if group == "EVENT"
                and hasObjectiveContent
                and #(status.participantUsernames or {}) > 0
            then
                local participantLabel = ISLabel:new(
                    x, y, ROW_HEIGHT, "Selected participant / winner", 0.8, 0.85, 1, 1, UIFont.Small, true
                )
                self:addDynamic(participantLabel)
                y = y + ROW_HEIGHT

                self.participantCombo = ISComboBox:new(
                    x, y, width, BUTTON_HEIGHT, self, KIPN_EventDirectorPanel.onParticipantSelectionChanged
                )
                local participantSelectedIndex = 1
                for index, username in ipairs(status.participantUsernames) do
                    self.participantCombo:addOptionWithData(username, username)
                    if username == self.selectedParticipantUsername then participantSelectedIndex = index end
                end
                self.participantCombo:setSelected(participantSelectedIndex)
                self.participantCombo:initialise()
                self.participantCombo:instantiate()
                self:addDynamic(self.participantCombo)
                self:onParticipantSelectionChanged(self.participantCombo)
                y = y + BUTTON_HEIGHT + ROW_GAP
            end

            if hasObjectiveContent then
                for _, sliderDef in ipairs(groupSliders) do
                    local fieldName = SLIDER_STATE_FIELD[sliderDef.id]
                    local currentValue = (fieldName and directorState[fieldName]) or sliderDef.defaultValue
                    y = self:addSliderRow(x, y, width, sliderDef, currentValue)
                end

                local i = 1
                while i <= #groupControlList do
                    local pair = {}

                    local first = groupControlList[i]
                    pair[#pair + 1] = { label = first.label, onclick = function() self:onFireControl(first.id, first.defaultParams) end }

                    if groupControlList[i + 1] then
                        local second = groupControlList[i + 1]
                        pair[#pair + 1] = { label = second.label, onclick = function() self:onFireControl(second.id, second.defaultParams) end }
                    end

                    y = self:addButtonRow(x, y, width, pair)
                    i = i + 2
                end
            end

            if group == "EVENT" and hasFixedButtons then
                y = self:addButtonRow(x, y, width, {
                    { label = "Add 2 Minutes", onclick = function() self:sendCommand("ADD_TIME", { seconds = 120 }) end },
                    { label = "End (No Prize)", onclick = function() self:sendCommand("END_EVENT", {}) end },
                    {
                        label = "Award + End",
                        onclick = function()
                            self:sendCommand("END_EVENT_WIN", {
                                winnerUsername = self.selectedParticipantUsername,
                            })
                        end,
                    },
                })
            end

            if group == "COMBAT" and hasFixedButtons then
                y = self:addButtonRow(x, y, width, {
                    { label = "Enable PvP", onclick = function() self:sendCommand("SET_PVP", { enabled = true }) end },
                    { label = "Disable PvP", onclick = function() self:sendCommand("SET_PVP", { enabled = false }) end },
                })
            end

            y = y + ROW_GAP
        end
    end

    ------------------------------------------------------------
    -- ALARM (Phase 5) -- always rendered for any ACTIVE event the
    -- caller's tier can reach, independent of objective type/mode.
    ------------------------------------------------------------

    if sectionAllowed(allowedCategories, "GM_CONTROLS") then
        local header = ISLabel:new(x, y, ROW_HEIGHT, "ALARM", 0.9, 0.9, 1, 1, UIFont.Small, true)
        self:addDynamic(header)
        y = y + ROW_HEIGHT

        self.alarmModeCombo = ISComboBox:new(x, y, width, BUTTON_HEIGHT, self, KIPN_EventDirectorPanel.onAlarmTargetModeChanged)
        local alarmModeSelectedIndex = 1
        for index, option in ipairs(ALARM_TARGET_MODE_OPTIONS) do
            self.alarmModeCombo:addOptionWithData(option.text, option.value)
            if self.alarmTargetMode == option.value then alarmModeSelectedIndex = index end
        end
        self.alarmModeCombo:setSelected(alarmModeSelectedIndex)
        self.alarmModeCombo:initialise()
        self.alarmModeCombo:instantiate()
        self:addDynamic(self.alarmModeCombo)
        y = y + BUTTON_HEIGHT + ROW_GAP

        if self.alarmTargetMode == "HOTSPOT" then
            local hotspots = status.hotspots or {}

            self.alarmHotspotCombo = ISComboBox:new(x, y, width, BUTTON_HEIGHT, self, KIPN_EventDirectorPanel.onAlarmHotspotSelectionChanged)

            if #hotspots == 0 then
                self.alarmHotspotCombo:addOptionWithData("(no hotspots on this event)", nil)
            else
                local hotspotSelectedIndex = 1
                for index, hotspot in ipairs(hotspots) do
                    local label = tostring(hotspot.label ~= "" and hotspot.label or hotspot.type or hotspot.id)
                    if hotspot.alarmEnabled then label = label .. " *" end
                    self.alarmHotspotCombo:addOptionWithData(label, hotspot.id)
                    if hotspot.id == self.alarmTargetHotspotId then hotspotSelectedIndex = index end
                end
                self.alarmHotspotCombo:setSelected(hotspotSelectedIndex)
                if not self.alarmTargetHotspotId then
                    self.alarmTargetHotspotId = hotspots[1] and hotspots[1].id
                end
            end

            self.alarmHotspotCombo:initialise()
            self.alarmHotspotCombo:instantiate()
            self:addDynamic(self.alarmHotspotCombo)
            y = y + BUTTON_HEIGHT + ROW_GAP
        end

        y = self:addButtonRow(x, y, width, {
            {
                label = "Trigger Alarm",
                onclick = function()
                    self:sendCommand("TRIGGER_ALARM", {
                        mode = self.alarmTargetMode,
                        hotspotId = self.alarmTargetHotspotId,
                    })
                end,
            },
        })

        y = y + ROW_GAP
    end

    ------------------------------------------------------------
    -- STAFF TOOLS
    ------------------------------------------------------------

    if sectionAllowed(allowedCategories, "STAFF_TOOLS") then
        local header = ISLabel:new(x, y, ROW_HEIGHT, "STAFF TOOLS", 0.9, 0.9, 1, 1, UIFont.Small, true)
        self:addDynamic(header)
        y = y + ROW_HEIGHT

        self.messageEntry = ISTextEntryBox:new(self.pendingMessageText or "", x, y, width, ROW_HEIGHT)
        self.messageEntry:initialise()
        self.messageEntry:instantiate()
        self:addDynamic(self.messageEntry)
        y = y + ROW_HEIGHT + ROW_GAP

        y = self:addButtonRow(x, y, width, {
            { label = "Send Announcement", onclick = function() self:onSendMessage("ANNOUNCE_MESSAGE") end },
            { label = "Send Hint", onclick = function() self:onSendMessage("REVEAL_HINT") end },
        })

        y = self:addButtonRow(x, y, width, {
            { label = "Spectate Enter", onclick = function() self:sendCommand("SPECTATE_ENTER", {}) end },
            { label = "Spectate Exit", onclick = function() self:sendCommand("SPECTATE_EXIT", {}) end },
        })

        y = y + ROW_GAP
    end

    ------------------------------------------------------------
    -- LOG
    ------------------------------------------------------------

    local log = status.log or {}
    local logHeader = ISLabel:new(x, y, ROW_HEIGHT, "LOG", 0.9, 0.9, 1, 1, UIFont.Small, true)
    self:addDynamic(logHeader)
    y = y + ROW_HEIGHT

    local startIndex = math.max(1, #log - LOG_DISPLAY_LINES + 1)

    for i = startIndex, #log do
        local line = ISLabel:new(x, y, ROW_HEIGHT, tostring(log[i]), 0.6, 0.6, 0.6, 1, UIFont.Small, true)
        self:addDynamic(line)
        y = y + ROW_HEIGHT - 4
    end

    y = y + PAD

    self:setHeight(math.min(y, getCore():getScreenHeight() - 100))
end

function KIPN_EventDirectorPanel:onSendMessage(command)
    local text = self.messageEntry and self.messageEntry:getText() or ""

    if not text or text:match("^%s*$") then
        return
    end

    self.pendingMessageText = ""

    if self.messageEntry then
        self.messageEntry:setText("")
    end

    self:sendCommand(command, { text = text })
end

------------------------------------------------------------
-- SERVER RESPONSE
------------------------------------------------------------

local function onServerResponse(module, command, args)
    if module ~= "KIPN" then
        return
    end

    if command ~= KIPN.Shared.Commands.SERVER_RESPONSE then
        return
    end

    if not args then
        return
    end

    local event = args.event
    local data = args.data or {}

    if event ~= KIPN.Shared.ResponseEvents.EVENT_DIRECTOR_RESULT then
        return
    end

    local panel = KIPN_EventDirectorPanel.instance

    if not panel then
        return
    end

    if data.success == false then
        panel.lastResultMessage = "ERROR: " .. tostring(data.reason or "COMMAND_FAILED")
        print("[KIPN EVENT DIRECTOR PANEL] " .. panel.lastResultMessage)
    else
        panel.lastResultMessage = "Command completed."
    end

    panel.status = data.status
    panel:rebuildContent()
end

Events.OnServerCommand.Add(onServerResponse)

print("[KIPN] Event Director panel loaded")
