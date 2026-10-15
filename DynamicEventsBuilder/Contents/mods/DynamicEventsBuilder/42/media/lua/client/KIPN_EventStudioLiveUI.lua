-- KIPN_EventStudioLiveUI.lua
--
-- A small see-through strip in the bottom-left corner that replaces the
-- Event Studio once an event begins, so the world stays visible: the
-- event's name and state, round, time left and head count on top, then
-- the newest lines of its log. Drag it to move it. Director opens the
-- live controls; Studio brings the full window back.
--
-- Asks the server for the event's status every few seconds while shown
-- (EVENT_GET_STATUS); KIPN_EventStudioUI.lua forwards the replies here.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "KIPN_EventStudio"
require "KIPN_EventPlayerHUD"

KIPN_EventStudioLiveUI = ISPanel:derive("KIPN_EventStudioLiveUI")
local L, S = KIPN_EventStudioLiveUI, KIPN_EventStudio

L.LINES = 5
L.POLL_MS = 5000

local function lineHeight() return getTextManager():getFontHeight(UIFont.Small) + 2 end

local function now()
    return getTimestampMs and getTimestampMs() or (os.time() * 1000)
end

local function fit(text, width)
    local manager = getTextManager()
    text = tostring(text or "")
    if manager:MeasureStringX(UIFont.Small, text) <= width then return text end
    while #text > 0 and manager:MeasureStringX(UIFont.Small, text .. "...") > width do text = text:sub(1, -2) end
    return text .. "..."
end

local function clock(ms)
    local seconds = math.max(0, math.floor(ms / 1000))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

function L:new(definitionId, name)
    local width = math.min(480, math.floor(getCore():getScreenWidth() * 0.42))
    local height = 30 + lineHeight() * (L.LINES + 1)
    local o = ISPanel.new(self, 12, getCore():getScreenHeight() - height - 12, width, height)
    o.definitionId = definitionId
    o.name = name
    o.moveWithMouse = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.55 }
    o.borderColor = { r = 0.60, g = 0.48, b = 0.20, a = 0.8 }
    return o
end

function L:createChildren()
    ISPanel.createChildren(self)
    self.buttons = {}
    local function button(x, width, title, callback, tooltip)
        local child = ISButton:new(x, 4, width, 18, title, self, callback)
        child:initialise()
        child.tooltip = tooltip
        self:addChild(child)
        self.buttons[#self.buttons + 1] = child
    end
    button(self.width - 24, 20, "x", L.hide, "Hide this strip; the event keeps running")
    button(self.width - 96, 68, "Studio", L.openStudio, "Open the Event Studio")
    button(self.width - 168, 68, "Director", L.openDirector, "Live controls: waves, time, hints, end the event")
end

function L:update()
    ISPanel.update(self)
    if not self.nextPollAt or now() >= self.nextPollAt then
        self.nextPollAt = now() + L.POLL_MS
        local command = KIPN.Shared.Commands and KIPN.Shared.Commands.EVENT_GET_STATUS
        if command then sendClientCommand("KIPN", command, { id = self.definitionId }) end
    end
end

function L:prerender()
    -- Fades like the player HUD: see-through 5 s after the mouse leaves.
    local alpha = KIPN_EventPlayerHUD.FadeAlpha(self)
    self.backgroundColor.a = 0.55 * alpha
    self.borderColor.a = 0.8 * alpha
    for _, button in ipairs(self.buttons or {}) do KIPN_EventPlayerHUD.FadeButton(button, alpha) end
    ISPanel.prerender(self)
    local status = self.status or {}
    local state = status.status or "ACTIVE"
    local color = S.StatusColors[state] or { 0.86, 0.86, 0.86 }
    local name = status.eventName or self.name or "Event"
    self:drawText(fit(name .. "  |  " .. S.StatusLabel(state), self.width - 184), 8, 6, color[1], color[2], color[3], alpha, UIFont.Small)

    local facts = {}
    if status.round then
        facts[#facts + 1] = "Round " .. tostring(status.round.current or 1) .. "/" .. tostring(status.round.maximum or 1)
        if status.round.timerEndsAtMs then facts[#facts + 1] = "round " .. clock(status.round.timerEndsAtMs - now()) .. " left" end
    end
    if status.endsAtMs then facts[#facts + 1] = clock(status.endsAtMs - now()) .. " left" end
    if status.participantUsernames then facts[#facts + 1] = #status.participantUsernames .. " players" end
    if #facts == 0 then facts[1] = self.status and "Running" or "Waiting for the server..." end
    local y = 28
    self:drawText(fit(table.concat(facts, "  |  "), self.width - 16), 8, y, 0.86, 0.86, 0.86, alpha, UIFont.Small)

    local lines = status.log or {}
    for index = math.max(1, #lines - L.LINES + 1), #lines do
        y = y + lineHeight()
        self:drawText(fit(lines[index], self.width - 16), 8, y, 0.62, 0.66, 0.72, alpha, UIFont.Small)
    end
end

function L:hide()
    self:setVisible(false)
    self:removeFromUIManager()
    if L.instance == self then L.instance = nil end
end

function L:openStudio()
    self:hide()
    KIPN_EventStudioUI.Open()
end

function L:openDirector()
    KIPN_EventDirectorPanel.Toggle()
end

function L.Show(definitionId, name)
    if L.instance then L.instance:hide() end
    local strip = L:new(definitionId, name)
    strip:initialise()
    strip:addToUIManager()
    strip:setVisible(true)
    strip:bringToTop()
    L.instance = strip
    return strip
end

function L.OnStatus(data)
    local strip = L.instance
    if strip and data and data.eventDefinitionId == strip.definitionId then strip.status = data end
end

return KIPN_EventStudioLiveUI
