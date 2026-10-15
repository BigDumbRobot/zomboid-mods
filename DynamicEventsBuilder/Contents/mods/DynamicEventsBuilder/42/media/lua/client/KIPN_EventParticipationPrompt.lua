-- KIPN_EventParticipationPrompt.lua
--
-- On-screen accept/deny prompt for self-service Event Scenario
-- participation. Registers its own always-loaded
-- Events.OnServerCommand listener (PZ auto-loads every client Lua
-- file for every client, so this reaches every connected player
-- regardless of whether any KIPN admin panel is open -- same
-- approach KIPN_EventScenarioAdminUI.lua's EVENT_NARRATIVE branch
-- uses) rather than being folded into an admin-only UI file.
--
-- Accepting sends KIPN.Shared.Commands.EVENT_ACCEPT_PARTICIPATION to
-- server/KIPN_EventParticipationService.lua. Denying is purely a
-- client-local dialog dismissal -- no server round trip, and no
-- decline state is remembered, so a player who dismisses one
-- round's invite is simply re-prompted at the next one.

if isServer() then return end

require "KIPN_UI"
require "KIPN_Shared"
require "DynamicEvents_Shared"
require "ISUI/ISPanel"
require "ISUI/ISButton"

local activeModal = nil

local function closeActiveModal()
    if activeModal then
        activeModal:removeFromUIManager()
        activeModal = nil
    end
end

local function halo(text)
    local player = getPlayer()
    if player and HaloTextHelper and HaloTextHelper.addText then pcall(HaloTextHelper.addText, player, text) end
end

-- Why a join was refused, in words.
local REFUSALS = {
    PENDING_RETURN_UNRESOLVED = "you still have to be returned from a previous event",
    ESCROW_PENDING = "your gear from a previous event has not been returned yet",
    EVENT_NO_LONGER_ACTIVE = "the event is no longer running",
    EVENT_DESTINATION_UNAVAILABLE = "the event has no start point",
    TELEPORT_FAILED = "you could not be moved to the event",
    COUNTRY_REQUIRED = "pick a town to represent",
    DEFINITION_NOT_FOUND = "the event no longer exists",
}

------------------------------------------------------------
-- THE OLYMPICS: pick a town to represent
------------------------------------------------------------

local CountryPicker = ISPanel:derive("KIPN_EventCountryPicker")

function CountryPicker:new(data)
    local columns, buttonWidth, buttonHeight = 3, 150, 26
    local countries = data.countries or {}
    local rows = math.ceil(#countries / columns)
    local width = columns * (buttonWidth + 8) + 16
    local height = 70 + rows * (buttonHeight + 6) + 40
    local o = ISPanel.new(self, (getCore():getScreenWidth() - width) / 2, (getCore():getScreenHeight() - height) / 2, width, height)
    o.data, o.columns, o.buttonWidth, o.buttonHeight = data, columns, buttonWidth, buttonHeight
    o.moveWithMouse = true
    o.backgroundColor = { r = 0.05, g = 0.06, b = 0.08, a = 0.95 }
    o.borderColor = { r = 1.0, g = 0.82, b = 0.3, a = 0.9 }
    return o
end

function CountryPicker:createChildren()
    ISPanel.createChildren(self)
    for index, country in ipairs(self.data.countries or {}) do
        local column, row = (index - 1) % self.columns, math.floor((index - 1) / self.columns)
        local button = ISButton:new(8 + column * (self.buttonWidth + 8), 64 + row * (self.buttonHeight + 6),
            self.buttonWidth, self.buttonHeight, country, self, CountryPicker.onPick)
        button.internal = country
        button:initialise()
        self:addChild(button)
    end
    local notNow = ISButton:new(self.width - 108, self.height - 34, 100, 26, "Not now", self, CountryPicker.onClose)
    notNow:initialise()
    self:addChild(notNow)
end

function CountryPicker:prerender()
    ISPanel.prerender(self)
    self:drawTextCentre(tostring(self.data.eventName or "The Olympics"), self.width / 2, 10, 1, 0.82, 0.3, 1, UIFont.Medium)
    self:drawTextCentre("Pick the town you will compete for:", self.width / 2, 36, 0.9, 0.9, 0.9, 1, UIFont.Small)
end

function CountryPicker:onPick(button)
    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_ACCEPT_PARTICIPATION, { id = self.data.definitionId, country = button.internal })
    self:onClose()
end

function CountryPicker:onClose()
    self:removeFromUIManager()
    if activeModal == self then activeModal = nil end
end

local function onParticipationDialogResult(target, button)
    activeModal = nil

    if button.internal == "NO" then
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_ACCEPT_PARTICIPATION, { id = target.definitionId })
end

local function showInvitePrompt(data)
    closeActiveModal()

    if data.mode == "OLYMPICS" and type(data.countries) == "table" and #data.countries > 0 then
        local picker = CountryPicker:new(data)
        picker:initialise()
        picker:addToUIManager()
        picker:setAlwaysOnTop(true)
        activeModal = picker
        return
    end

    local message = (type(data.promptText) == "string" and data.promptText ~= "" and data.promptText)
        or (data.kind == "ROUND_START"
            and ("Round " .. tostring(data.roundNumber) .. " of " .. tostring(data.eventName) .. " has started. Join now?")
            or data.kind == "SIGN_UP" and ("Sign up for " .. tostring(data.eventName) .. "? You will be brought in when it begins.")
            or ("An event has started: " .. tostring(data.eventName) .. ". Join now?"))

    local width, height = 350, 150

    -- Non-modal -- see KIPN_UI.lua's "NON-MODAL CONFIRM DIALOG" header.
    local modal = KIPN.UI.CreateConfirmDialog(
        (getCore():getScreenWidth() / 2) - (width / 2),
        (getCore():getScreenHeight() / 2) - (height / 2),
        width,
        height,
        message,
        true,
        { definitionId = data.definitionId },
        onParticipationDialogResult
    )

    modal:setAlwaysOnTop(true)

    activeModal = modal
end

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

    if event == KIPN.Shared.ResponseEvents.EVENT_PARTICIPATION_INVITE then
        showInvitePrompt(data)
        return
    end

    if event == KIPN.Shared.ResponseEvents.EVENT_PARTICIPATION_RESULT then
        if data.success == false then
            halo("Could not join: " .. (REFUSALS[data.reason] or tostring(data.reason)))
        elseif data.reason == "SIGNED_UP" then
            halo("You're signed up! You'll be brought in when the event begins.")
        end
        return
    end
end

Events.OnServerCommand.Add(onServerResponse)
