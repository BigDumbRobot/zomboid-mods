-- KIPN_UserPreferences.lua
--
-- USER PREFERENCES terminal program: lets the player choose how
-- KIPN displays temperature, measurements, the clock and dates.
--
-- Entirely point-and-click: every choice is a button, the active
-- one is lit, and a click saves immediately (no SAVE step). The
-- terminal's HOME button returns to the main menu.
--
-- Storage, "auto" resolution and all formatting live in
-- KIPN_Preferences.lua; this file is only the screen.
--
-- Registered as a menu program in
-- server/KIPN_ApplicationRegistry.lua ("user_preferences").
--
-- File:
--   media/lua/client/KIPN_UserPreferences.lua

require "ISUI/ISPanel"
require "ISUI/ISButton"

if not KIPN then
    error("[KIPN_UserPreferences] KIPN core is not initialized.")
end

require "KIPN_UI"

if not KIPN.UI then
    error("[KIPN_UserPreferences] KIPN_UI is not initialized.")
end

local Prefs = KIPN.Client.Preferences
local Theme = KIPN.UI.Theme

KIPN_UserPreferences =
    KIPN.UI.CreateScreen("KIPN_UserPreferences")

--------------------------------------------------------------------
-- LAYOUT
--------------------------------------------------------------------

local ROWS = {
    { key = "temperature", label = "TEMPERATURE" },
    { key = "units", label = "MEASUREMENTS" },
    { key = "clock", label = "CLOCK" },
    { key = "date", label = "DATE FORMAT" },
}

local LABEL_X = 30
local BUTTONS_X = 200
local BUTTON_W = 170
local BUTTON_H = 26
local BUTTON_GAP = 10
local FIRST_ROW_Y = 118
local ROW_SPACING = 46

-- Fixed sample values for the preview line (20C, 5.2 km, 6.6 kg),
-- chosen so every unit system shows a non-trivial number.
local SAMPLE_CELSIUS = 20
local SAMPLE_METERS = 5150
local SAMPLE_KG = 6.6

local SELECTED_BG = { r = 0.1, g = 0.55, b = 0.2, a = 0.95 }
local SELECTED_BORDER = { r = 0.4, g = 1.0, b = 0.4, a = 1 }
local SELECTED_TEXT = { r = 0.85, g = 1.0, b = 0.85, a = 1 }

--------------------------------------------------------------------
-- INITIALISE / CREATE
--------------------------------------------------------------------

function KIPN_UserPreferences:initialise()
    ISPanel.initialise(self)
    self:create()
end

function KIPN_UserPreferences:create()

    KIPN.UI.SetupScreen(self)

    self.choiceButtons = {}

    for rowIndex, row in ipairs(ROWS) do

        local y = FIRST_ROW_Y + (rowIndex - 1) * ROW_SPACING

        for choiceIndex, choice in ipairs(Prefs.Choices[row.key]) do

            local btn =
                KIPN.UI.CreateButton(
                    self,
                    BUTTONS_X + (choiceIndex - 1) * (BUTTON_W + BUTTON_GAP),
                    y,
                    BUTTON_W,
                    BUTTON_H,
                    Prefs.ChoiceLabel(row.key, choice),
                    KIPN_UserPreferences.onChoiceClick
                )

            btn.prefKey = row.key
            btn.prefChoice = choice

            self.choiceButtons[#self.choiceButtons + 1] = btn
        end
    end

    self:refreshButtons()
end

--------------------------------------------------------------------
-- BUTTON STATE
--
-- Lights the active choice in each row, and keeps each AUTO
-- button's label showing what it currently resolves to.
--------------------------------------------------------------------

function KIPN_UserPreferences:refreshButtons()

    for _, btn in ipairs(self.choiceButtons or {}) do

        local selected =
            Prefs.Get(btn.prefKey) == btn.prefChoice

        if selected then
            btn.backgroundColor = SELECTED_BG
            btn.backgroundColorMouseOver = SELECTED_BG
            btn.borderColor = SELECTED_BORDER
            btn.textColor = SELECTED_TEXT
        else
            btn.backgroundColor = Theme.button.background
            btn.backgroundColorMouseOver = Theme.button.backgroundHover
            btn.borderColor = Theme.button.border
            btn.textColor = Theme.button.text
        end

        local label =
            Prefs.ChoiceLabel(btn.prefKey, btn.prefChoice)

        if btn.title ~= label then
            btn:setTitle(label)
        end
    end

    self.lastSignature = Prefs.Signature()
    self.lastVersion = Prefs.version
end

function KIPN_UserPreferences:onChoiceClick(button)

    if not button or not button.prefKey then
        return
    end

    Prefs.Set(button.prefKey, button.prefChoice)

    self:refreshButtons()
end

function KIPN_UserPreferences:onShow()
    self:refreshButtons()
end

--------------------------------------------------------------------
-- PRERENDER
--------------------------------------------------------------------

local function gameDateTimeText()

    local gameTime = getGameTime and getGameTime()

    if not gameTime then
        return "--"
    end

    return Prefs.FormatDateTime(
        gameTime:getYear(),
        gameTime:getMonth() + 1,
        gameTime:getDay() + 1,
        gameTime:getHour(),
        gameTime:getMinutes()
    )
end

function KIPN_UserPreferences:prerender()

    -- A vanilla option changing under an AUTO choice (or another
    -- screen setting a preference) must update the lit buttons and
    -- AUTO labels without a click here.
    if self.lastVersion ~= Prefs.version
        or self.lastSignature ~= Prefs.Signature() then

        self:refreshButtons()
    end

    ISPanel.prerender(self)
    KIPN.UI.DrawScanlines(self)

    local y = KIPN.UI.DrawBanner(self, "USER PREFERENCES")

    y = KIPN.UI.DrawDivider(self, y) + 8

    self:drawText(
        "CHOOSE HOW THIS TERMINAL DISPLAYS UNITS, TIME AND DATES.",
        LABEL_X,
        y,
        Theme.dimText.r,
        Theme.dimText.g,
        Theme.dimText.b,
        Theme.dimText.a,
        Theme.fontBody
    )

    ----------------------------------------------------------------
    -- ROW LABELS (buttons are real child widgets)
    ----------------------------------------------------------------

    for rowIndex, row in ipairs(ROWS) do

        local rowY = FIRST_ROW_Y + (rowIndex - 1) * ROW_SPACING

        self:drawText(
            row.label,
            LABEL_X,
            rowY + 5,
            Theme.text.r,
            Theme.text.g,
            Theme.text.b,
            Theme.text.a,
            Theme.fontHeader
        )
    end

    ----------------------------------------------------------------
    -- LIVE PREVIEW
    ----------------------------------------------------------------

    local previewY = FIRST_ROW_Y + #ROWS * ROW_SPACING + 14

    KIPN.UI.DrawDivider(self, previewY)

    local preview =
        "PREVIEW:   "
        .. gameDateTimeText()
        .. "   |   "
        .. Prefs.FormatTemperature(SAMPLE_CELSIUS, true)
        .. "   |   "
        .. Prefs.FormatDistance(SAMPLE_METERS)
        .. "   |   "
        .. Prefs.FormatWeight(SAMPLE_KG)

    self:drawText(
        preview,
        LABEL_X,
        previewY + 14,
        Theme.accent.r,
        Theme.accent.g,
        Theme.accent.b,
        Theme.accent.a,
        Theme.fontBody
    )

    KIPN.UI.DrawDivider(self, previewY + 42)

    self:drawText(
        "AUTO FOLLOWS YOUR GAME OPTIONS (OPTIONS > DISPLAY).",
        LABEL_X,
        previewY + 58,
        Theme.dimText.r,
        Theme.dimText.g,
        Theme.dimText.b,
        Theme.dimText.a,
        Theme.fontBody
    )

    self:drawText(
        "CHANGES SAVE IMMEDIATELY AND APPLY ACROSS ALL SERVERS.",
        LABEL_X,
        previewY + 78,
        Theme.dimText.r,
        Theme.dimText.g,
        Theme.dimText.b,
        Theme.dimText.a,
        Theme.fontBody
    )
end

--------------------------------------------------------------------
-- KEY PRESS
--
-- ESC is owned by KIPN_Terminal. Nothing on this screen is
-- keyboard-driven.
--------------------------------------------------------------------

function KIPN_UserPreferences:onKeyPress(key)
    return false
end

print("[KIPN] User Preferences screen loaded")
