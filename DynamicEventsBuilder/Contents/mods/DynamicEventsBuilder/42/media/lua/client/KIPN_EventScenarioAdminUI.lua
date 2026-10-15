-- KIPN_EventScenarioAdminUI.lua
--
-- Admin control panel for the Event Scenarios feature. Reachable
-- only from KIPN_AdminSettings.lua's "Event Scenarios" section,
-- mirroring how that panel's "Zones" section launches
-- KIPN_ZoneAdminUI.Toggle().
--
-- Server-authoritative: this panel is convenience UI only. Every
-- mutating action re-checks SYSOP_CONFIGURATION server-side (see
-- KIPN_EventScenarioService.lua / KIPN_EventRuntimeService.lua).
--
-- COMPOSABLE SCENARIOS: an Event Definition selects from small,
-- independent building blocks -- Objective Types (Retrieve/Deliver/
-- Hold Area/Survive/Locate/Interact/Escort), a Timer Type (None/
-- Countdown/Hold Timer/Round Timer/Escalation Timer), and Outcome
-- Types (First To Complete/Last Alive/Hold Duration/Extraction/Time
-- Expired/Most Zombie Kills/Most Player Kills). A "Scenario Preset"
-- picker (Capture/King of the Hill/Adventure) provides an optional
-- starting recipe; the admin can still edit every field afterward
-- and influence the running scenario through the Event Director.
-- See KIPN_Shared.lua's
-- "IMPLEMENTATION STATUS" comment: these selections are captured and
-- shown here, but only Horde Survival's existing spawnRules/
-- winConditions/failConditions (via KIPN_ZombieDirector.lua) are
-- mechanically wired to actual gameplay so far.
--
-- LIFECYCLE: DRAFT -> [Validate] -> READY -> [Announce] -> ANNOUNCED
-- -> [Open Joining] -> JOINING -> [Begin] -> ACTIVE -> [Stop / win /
-- fail / timer] -> COMPLETE -> [Reset] -> DRAFT. Each stage button
-- below is enabled only when the current status allows it.
--
-- DYNAMIC EVENT ZONES: the "Draw Zone For This Event" button opens
-- the map corner-picker directly (KIPN_ZoneAdminMapUI, the same
-- widget the classic Zone Admin tool uses) and, on confirm, sends
-- EVENT_CREATE_ZONE_FROM_CORNERS -- the server creates the
-- WorldRegistry zone (zoneType "event") AND links it to this
-- definition in one step.
--
-- NARRATIVE BROADCAST: onServerResponse below is loaded and
-- listening for EVERY connected player, not only admins who open
-- this panel (PZ auto-loads every client Lua file for every client).
-- The EVENT_NARRATIVE branch takes advantage of that to show
-- briefing/win/fail text to regular participants who never open this
-- admin UI at all.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "ISUI/ISTickBox"
require "ISUI/ISLabel"
require "ISUI/ISComboBox"
require "ISUI/ISRichTextPanel"
require "KIPN_Shared"
require "KIPN_UI"
require "KIPN_ItemTypeSuggestions"
require "KIPN_ZoneAdminMapUI"
require "KIPN_EventDirectorControlUI"

if not KIPN then
    error("[KIPN_EventScenarioAdminUI] KIPN core is not initialized.")
end

if not KIPN.Shared then
    error("[KIPN_EventScenarioAdminUI] KIPN_Shared is not initialized.")
end

KIPN_EventScenarioAdminUI = ISPanel:derive("KIPN_EventScenarioAdminUI")

-- Internal compatibility/runtime driver. This is deliberately not
-- exposed as an authoring choice: admins compose a scenario from the
-- fields below instead of first selecting a mutually exclusive event
-- engine. Existing definitions keep their stored eventType on save.
local INTERNAL_EVENT_TYPE = "HORDE_SURVIVAL"

local ENVIRONMENT_TIME_OF_DAY_OPTIONS = {
    { text = "(unchanged)", value = nil },
    { text = "Day", value = "DAY" },
    { text = "Night", value = "NIGHT" },
    { text = "Dusk", value = "DUSK" },
    { text = "Dawn", value = "DAWN" },
}

local ENVIRONMENT_WEATHER_OPTIONS = {
    { text = "Clear", value = "CLEAR" },
    { text = "Rain", value = "RAIN" },
    { text = "Storm", value = "STORM" },
    { text = "Fog", value = "FOG" },
}

-- Phase 5's Story/Objectives editor covers a deliberately narrow first
-- slice of KIPN_EventTriggerService.lua's full framework (9 action
-- types x 5 activation modes x scope/cooldown/probability/round/
-- target-filter). MANUAL and PROXIMITY are the two activation modes
-- authorable here; the TIME_SINCE_* modes and the remaining action
-- types (SPAWN_LOOT, NARRATIVE_MESSAGE, ACTIVATE_OBJECTIVE,
-- MODE_ACTION) are reachable only via direct EVENT_UPDATE_DEFINITION
-- payloads until a later pass extends this editor -- see the Phase 5
-- report's "known limitations."
local TRIGGER_ACTIVATION_MODE_OPTIONS = {
    { text = "Manual (Event Director)", value = "MANUAL" },
    { text = "Proximity", value = "PROXIMITY" },
}

local TRIGGER_ACTION_TYPE_OPTIONS = {
    { text = "Announcement (all online)", value = "ANNOUNCEMENT", paramLabel = "Text" },
    { text = "Private Hint", value = "PRIVATE_HINT", paramLabel = "Text" },
    { text = "Trigger Alarm", value = "ALARM", paramLabel = nil },
    { text = "Spawn Themed Zombies", value = "SPAWN_ZOMBIES", paramLabel = "Count" },
    { text = "Complete Objective", value = "COMPLETE_OBJECTIVE", paramLabel = nil },
}

-- Guarded rather than assumed present: this is the only top-level
-- (non-deferred) dereference of a specific KIPN.Shared.* field in the
-- client codebase. Every load-order path observed today populates it
-- before this file loads, but a missing/renamed field here must not
-- abort this whole file's load -- doing so would silently break
-- KIPN_AdminSettings.lua's "ADMIN SETTINGS" menu item entirely, since
-- KIPN_AdminSettings.lua requires this file at load time.
local SCENARIO_PRESET_OPTIONS = { { text = "(custom)", value = "CUSTOM" } }

if KIPN.Shared.EventScenarioPresetOrder
    and KIPN.Shared.EventScenarioPresets then

    for _, key in ipairs(KIPN.Shared.EventScenarioPresetOrder) do
        local preset = KIPN.Shared.EventScenarioPresets[key]

        if preset then
            SCENARIO_PRESET_OPTIONS[#SCENARIO_PRESET_OPTIONS + 1] = {
                text = preset.label,
                value = key,
            }
        end
    end

else

    print(
        "[KIPN_EventScenarioAdminUI] WARN: "
        .. "KIPN.Shared.EventScenarioPresetOrder/Presets "
        .. "unavailable at load time -- Scenario Preset picker "
        .. "will only offer (custom)."
    )

end

local REWARD_MAX_ROWS = 10
local OBJECTIVES_MAX_ROWS = 5
local REWARD_SUGGESTION_MAX_RESULTS = 6
local REWARD_SUGGESTION_ROW_HEIGHT = 22

local DEFAULT_WIDTH = 1180
local DEFAULT_HEIGHT = 900
local FORM_LABEL_WIDTH = 220
local ROW_HEIGHT = 24
local TICK_BOX_SIZE = 16
local DETAIL_PAD = 10
local FOOTER_HEIGHT = 30
local NARRATIVE_ENTRY_HEIGHT = 72
local PANE_GAP = 12

local function onPaneMouseWheel(pane, delta)
    pane:setYScroll(pane:getYScroll() - (delta * 40))
    return true
end

-- Maps a definition's hotspots into the existingZones shape
-- KIPN_ZoneAdminMapUI:drawExistingZones expects, tagged kind =
-- "hotspot" so it colors by KIPN.Shared.EventHotspotTypes (and, when
-- roundNumber is set, by round) instead of the permission-zone
-- ZONE_TYPE_COLORS/COMBAT_POLICY_COLORS the classic Zone Admin tool
-- feeds into the same picker.
local function buildHotspotMapEntries(definition)
    local entries = {}
    for _, hotspot in ipairs((definition and definition.hotspots) or {}) do
        entries[#entries + 1] = {
            id = hotspot.id,
            type = hotspot.type,
            label = hotspot.label,
            teamId = hotspot.teamId,
            geometry = hotspot.geometry,
            roundNumber = hotspot.roundNumber,
            active = hotspot.active,
            kind = "hotspot",
        }
    end
    return entries
end

------------------------------------------------------------
-- SINGLETON ACCESS
------------------------------------------------------------

function KIPN_EventScenarioAdminUI.Toggle()
    if KIPN_EventScenarioAdminUI.instance and KIPN_EventScenarioAdminUI.instance:getIsVisible() then
        KIPN_EventScenarioAdminUI.instance:onClose()
        return
    end

    if not KIPN_EventScenarioAdminUI.instance then
        local screenW = getCore():getScreenWidth()
        local screenH = getCore():getScreenHeight()

        local width = math.min(DEFAULT_WIDTH, screenW - 40)
        local height = math.min(DEFAULT_HEIGHT, screenH - 40)

        local panel = KIPN_EventScenarioAdminUI:new(
            (screenW / 2) - (width / 2),
            (screenH / 2) - (height / 2),
            width,
            height
        )

        panel:initialise()
        panel:instantiate()

        KIPN_EventScenarioAdminUI.instance = panel
    end

    KIPN_EventScenarioAdminUI.instance:addToUIManager()
    KIPN_EventScenarioAdminUI.instance:bringToTop()
    KIPN_EventScenarioAdminUI.instance:refreshDefinitions()
end

------------------------------------------------------------
-- CONSTRUCTION
------------------------------------------------------------

function KIPN_EventScenarioAdminUI:new(x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.9 }
    o.borderColor = { r = 1, g = 0.3, b = 0.3, a = 0.5 }
    o.moveWithMouse = true

    o.definitions = {}
    o.selectedDefinitionId = nil

    o.onlinePlayers = {}
    o.status = nil

    o.availableWinConditions = {}
    o.availableFailConditions = {}
    o.metadataEventType = nil

    o.fieldWidgets = {}
    o.editorDrafts = {}
    o.rewardRows = {}
    o.rewardAwards = {}
    o.rewardSuggestionButtons = {}
    o.infoText = "Requesting event definitions..."

    KIPN_EventScenarioAdminUI.instance = o

    return o
end

function KIPN_EventScenarioAdminUI:initialise()
    ISPanel.initialise(self)
end

--------------------------------------------------------------------
-- IMPORTANT -- MUST BE createChildren(), NOT called manually.
--
-- This used to be a plain :create() method invoked from
-- :initialise(). That was broken: :initialise() runs BEFORE the
-- panel's real Java UI object exists, so self:addChild() below
-- (called for titleLabel/closeButton/newButton) implicitly
-- triggered an early self:instantiate() to create one. Toggle()
-- then called panel:instantiate() a SECOND time (vanilla
-- ISUIElement:instantiate() is not idempotent -- it unconditionally
-- replaces self.javaObject with a brand new one), discarding that
-- first object and every child just attached to it. The panel would
-- still open and eventually populate (its list/detail widgets are
-- built later, after createChildren()'s single legitimate
-- instantiate() call, so they attach fine) -- but titleLabel,
-- closeButton, and newButton were permanently orphaned on the
-- discarded object, which is why the close button (and "+ New
-- Event") never responded to clicks.
--
-- createChildren() is the correct vanilla hook for this: PZ's own
-- ISUIElement:instantiate() calls it automatically, exactly once,
-- immediately after creating the real javaObject -- see
-- ISUI/ISUIElement.lua. No manual call is needed or wanted.
--------------------------------------------------------------------

function KIPN_EventScenarioAdminUI:createChildren()
    if KIPN.ItemTypeSuggestions
        and KIPN.ItemTypeSuggestions.RefreshFromLoadedScripts then
        KIPN.ItemTypeSuggestions.RefreshFromLoadedScripts()
    end

    self.titleLabel = ISLabel:new(10, 10, ROW_HEIGHT, "KIPN Event Scenarios", 1, 1, 1, 1, UIFont.Medium, true)
    self.titleLabel:initialise()
    self:addChild(self.titleLabel)

    self.closeButton = ISButton:new(self:getWidth() - 30, 6, 20, 20, "X", self, KIPN_EventScenarioAdminUI.onClose)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self:addChild(self.closeButton)

    local toolbarY = 40

    ----------------------------------------------------------------
    -- THREE-PANE EDITOR (Phase 5 of the Event Scenarios architecture
    -- rewrite -- replaces the old toolbar-combo + two-pane layout).
    --
    -- LEFT (listPane): definition list + lifecycle actions.
    -- CENTRE (detailPane): structured, mechanically interpreted
    --   configuration -- name/mode/rules/rounds/timer/story/hotspots.
    -- RIGHT (textPane): contextual inspector -- narrative/reward
    --   authoring, participant/team roster, prize fulfillment, and
    --   (while ACTIVE) the live control panel.
    --
    -- Each pane scrolls independently, same onPaneMouseWheel/
    -- addScrollBars/setScrollChildren idiom as before -- only the pane
    -- count and width split changed.
    ----------------------------------------------------------------

    local paneLabelY = toolbarY + ROW_HEIGHT + 8
    local paneTop = paneLabelY + ROW_HEIGHT
    local paneHeight = self:getHeight() - paneTop - FOOTER_HEIGHT

    local listPaneWidth = math.max(200, math.floor(self:getWidth() * 0.2))
    local remainingWidth = self:getWidth() - 20 - (PANE_GAP * 2) - listPaneWidth
    local paneWidth = math.floor(remainingWidth / 2)

    local listPaneX = 10
    local detailPaneX = listPaneX + listPaneWidth + PANE_GAP
    local textPaneX = detailPaneX + paneWidth + PANE_GAP

    self.listPaneLabel = ISLabel:new(listPaneX, paneLabelY, ROW_HEIGHT, "Events", 0.9, 0.85, 0.6, 1, UIFont.Small, true)
    self.listPaneLabel:initialise()
    self:addChild(self.listPaneLabel)

    self.settingsPaneLabel = ISLabel:new(detailPaneX, paneLabelY, ROW_HEIGHT, "Configuration", 0.7, 0.9, 0.7, 1, UIFont.Small, true)
    self.settingsPaneLabel:initialise()
    self:addChild(self.settingsPaneLabel)

    self.textPaneLabel = ISLabel:new(textPaneX, paneLabelY, ROW_HEIGHT, "Inspector", 0.7, 0.8, 1, 1, UIFont.Small, true)
    self.textPaneLabel:initialise()
    self:addChild(self.textPaneLabel)

    self.listPane = ISPanel:new(listPaneX, paneTop, listPaneWidth, paneHeight)
    self.listPane:initialise()
    self.listPane:instantiate()
    self.listPane.backgroundColor = { r = 0.05, g = 0.05, b = 0.03, a = 0.35 }
    self.listPane.borderColor = { r = 0.55, g = 0.5, b = 0.3, a = 0.65 }
    self.listPane:addScrollBars()
    self.listPane:setScrollChildren(true)
    self.listPane:setScrollWithParent(false)
    self.listPane:setScrollHeight(self.listPane:getHeight())
    self.listPane.onMouseWheel = onPaneMouseWheel
    KIPN.UI.EnableClipping(self.listPane)
    self:addChild(self.listPane)

    self.detailPane = ISPanel:new(detailPaneX, paneTop, paneWidth, paneHeight)
    self.detailPane:initialise()
    self.detailPane:instantiate()
    self.detailPane.backgroundColor = { r = 0.03, g = 0.05, b = 0.03, a = 0.35 }
    self.detailPane.borderColor = { r = 0.3, g = 0.55, b = 0.3, a = 0.65 }
    self.detailPane:addScrollBars()
    self.detailPane:setScrollChildren(true)
    self.detailPane:setScrollWithParent(false)
    self.detailPane:setScrollHeight(self.detailPane:getHeight())
    self.detailPane.onMouseWheel = onPaneMouseWheel
    KIPN.UI.EnableClipping(self.detailPane)
    self:addChild(self.detailPane)

    self.textPane = ISPanel:new(textPaneX, paneTop, paneWidth, paneHeight)
    self.textPane:initialise()
    self.textPane:instantiate()
    self.textPane.backgroundColor = { r = 0.03, g = 0.04, b = 0.07, a = 0.35 }
    self.textPane.borderColor = { r = 0.3, g = 0.4, b = 0.65, a = 0.65 }
    self.textPane:addScrollBars()
    self.textPane:setScrollChildren(true)
    self.textPane:setScrollWithParent(false)
    self.textPane:setScrollHeight(self.textPane:getHeight())
    self.textPane.onMouseWheel = onPaneMouseWheel
    KIPN.UI.EnableClipping(self.textPane)
    self:addChild(self.textPane)

    self:rebuildRightPanel()
end

function KIPN_EventScenarioAdminUI:onClose()
    self:setVisible(false)
    self:removeFromUIManager()

    -- removeFromUIManager() can leave getIsVisible() true. Clear the
    -- detached singleton so a later launch creates a fresh panel
    -- instead of repeatedly taking the close branch in Toggle().
    if KIPN_EventScenarioAdminUI.instance == self then
        KIPN_EventScenarioAdminUI.instance = nil
    end
end

------------------------------------------------------------
-- DEFINITION SELECTOR
--
-- rebuildDefinitionsList() (LEFT pane content) is defined further
-- down, right before rebuildRightPanel() -- it needs
-- trackWidget()/addLabel()/addSectionHeader()/addWrappedText(), which
-- aren't declared as locals until below this point in the file.
------------------------------------------------------------

function KIPN_EventScenarioAdminUI:selectDefinition(definitionId)
    if self.renderedDefinitionId and self.captureCurrentDraft then
        self:captureCurrentDraft()
    end

    self.selectedDefinitionId = definitionId
    self.status = nil

    if self.detailPane then
        self.detailPane:setYScroll(0)
    end

    if self.textPane then
        self.textPane:setYScroll(0)
    end

    local definition = self:getSelectedDefinition()

    if definition then
        self:refreshEventTypeMetadata(definition.eventType)
    end

    if definitionId then
        self:refreshStatus()
    end

    self:rebuildRightPanel()
end

-- Phase 5: the primary selection entry point -- one row button per
-- definition in the LEFT (listPane) pane, each with .internal set to
-- its definition id (see rebuildDefinitionsList() below).
function KIPN_EventScenarioAdminUI:onSelectDefinition(button)
    self:selectDefinition(button and button.internal)
end

function KIPN_EventScenarioAdminUI:getSelectedDefinition()
    for _, definition in ipairs(self.definitions) do
        if definition.id == self.selectedDefinitionId then
            return definition
        end
    end

    return nil
end

-- THREE-PANE FORM HELPERS
------------------------------------------------------------

function KIPN_EventScenarioAdminUI:clearFieldWidgets()
    for _, widget in ipairs(self.fieldWidgets) do
        local pane = widget.kipnContainerPane or self.detailPane
        pane:removeChild(widget)
    end

    self.fieldWidgets = {}
    self.objectiveNoteEntries = {}
    self.objectiveNotesFollowingY = nil
    self.rewardRows = {}
    self.rewardSuggestionButtons = {}
    self.rewardFollowingY = nil
    self.textPaneContentHeight = nil
end

local function trackWidget(panel, pane, widget)
    widget.kipnContainerPane = pane
    pane:addChild(widget)
    panel.fieldWidgets[#panel.fieldWidgets + 1] = widget
    return widget
end

function KIPN_EventScenarioAdminUI:addObjectiveNoteEntry(rowIndex, text, x, y, width)
    local entry = ISTextEntryBox:new(text or "", x, y, width, ROW_HEIGHT - 4)
    entry:initialise()
    entry:instantiate()
    entry.kipnObjectiveNoteRow = rowIndex
    entry.target = self
    entry.onTextChangeFunction = KIPN_EventScenarioAdminUI.onObjectiveNoteChanged

    trackWidget(self, self.textPane, entry)

    self.objectiveNoteEntries = self.objectiveNoteEntries or {}
    self.objectiveNoteEntries[#self.objectiveNoteEntries + 1] = entry

    return entry
end

function KIPN_EventScenarioAdminUI:onObjectiveNoteChanged(textEntryBox)
    local entries = self.objectiveNoteEntries or {}

    if not textEntryBox
        or textEntryBox ~= entries[#entries]
        or #entries >= OBJECTIVES_MAX_ROWS
        or not tostring(textEntryBox:getText() or ""):match("%S") then
        return
    end

    local rowSpacing = ROW_HEIGHT + 2
    local nextY = textEntryBox:getY() + rowSpacing
    local followingY = self.objectiveNotesFollowingY

    -- Make room for the new row without rebuilding the form. A full
    -- rebuild here would discard other unsaved edits and steal focus
    -- from the note currently being typed.
    if followingY then
        for _, widget in ipairs(self.fieldWidgets) do
            if widget.kipnContainerPane == self.textPane
                and not widget.kipnObjectiveNoteRow
                and widget:getY() >= followingY then
                widget:setY(widget:getY() + rowSpacing)
            end
        end

        self.objectiveNotesFollowingY = followingY + rowSpacing

        if self.rewardFollowingY and self.rewardFollowingY >= followingY then
            self.rewardFollowingY = self.rewardFollowingY + rowSpacing
        end
    end

    self:addObjectiveNoteEntry(#entries + 1, "", textEntryBox:getX(), nextY, textEntryBox:getWidth())

    self.textPaneContentHeight = (self.textPaneContentHeight or self.textPane:getHeight()) + rowSpacing
    self.textPane:setScrollHeight(math.max(self.textPaneContentHeight, self.textPane:getHeight()))
end

local function computeRewardItemSuggestions(query)
    local matches = {}
    local source = KIPN.ItemTypeSuggestions
        and KIPN.ItemTypeSuggestions.ITEMS
        or {}

    for _, candidate in ipairs(source) do
        local bareCandidate = candidate:match("^[^.]+%.(.+)$") or candidate
        local lowerCandidate = candidate:lower()
        local lowerBare = bareCandidate:lower()
        local isPrefix = lowerCandidate:sub(1, #query) == query
            or lowerBare:sub(1, #query) == query
        local isSubstring = not isPrefix
            and (lowerCandidate:find(query, 1, true) ~= nil
                or lowerBare:find(query, 1, true) ~= nil)

        if isPrefix or isSubstring then
            matches[#matches + 1] = {
                value = candidate,
                rank = isPrefix and 0 or 1,
            }
        end
    end

    table.sort(matches, function(a, b)
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        return a.value < b.value
    end)

    local result = {}
    for index = 1, math.min(#matches, REWARD_SUGGESTION_MAX_RESULTS) do
        result[index] = matches[index].value
    end
    return result
end

function KIPN_EventScenarioAdminUI:clearRewardSuggestions()
    if not self.rewardSuggestionButtons or #self.rewardSuggestionButtons == 0 then
        return
    end

    local removed = {}
    for _, button in ipairs(self.rewardSuggestionButtons) do
        self.textPane:removeChild(button)
        removed[button] = true
    end

    local remaining = {}
    for _, widget in ipairs(self.fieldWidgets) do
        if not removed[widget] then
            remaining[#remaining + 1] = widget
        end
    end

    self.fieldWidgets = remaining
    self.rewardSuggestionButtons = {}
end

function KIPN_EventScenarioAdminUI:addRewardRow(rowIndex, row, x, y, width)
    local itemWidth = math.max(100, width - 90)
    local itemEntry = ISTextEntryBox:new(
        row and tostring(row.itemFullType or "") or "",
        x,
        y,
        itemWidth,
        ROW_HEIGHT - 4
    )
    itemEntry:initialise()
    itemEntry:instantiate()
    itemEntry.kipnRewardField = "itemFullType"
    itemEntry.kipnRewardRow = rowIndex
    itemEntry.target = self
    itemEntry.onTextChangeFunction = KIPN_EventScenarioAdminUI.onRewardItemChanged
    trackWidget(self, self.textPane, itemEntry)

    local countEntry = ISTextEntryBox:new(
        row and tostring(row.count or "") or "",
        x + width - 84,
        y,
        84,
        ROW_HEIGHT - 4
    )
    countEntry:initialise()
    countEntry:instantiate()
    if countEntry.setOnlyNumbers then countEntry:setOnlyNumbers(true) end
    countEntry.kipnRewardField = "count"
    countEntry.kipnRewardRow = rowIndex
    trackWidget(self, self.textPane, countEntry)

    self.rewardRows = self.rewardRows or {}
    self.rewardRows[#self.rewardRows + 1] = {
        itemEntry = itemEntry,
        countEntry = countEntry,
    }

    return itemEntry, countEntry
end

function KIPN_EventScenarioAdminUI:updateRewardSuggestions(textEntryBox)
    self:clearRewardSuggestions()

    local query = textEntryBox
        and tostring(textEntryBox:getText() or ""):lower():match("^%s*(.-)%s*$")
        or ""

    if query == "" then return end

    local suggestionX = textEntryBox:getX()
    local suggestionY = textEntryBox:getY() + ROW_HEIGHT

    for index, value in ipairs(computeRewardItemSuggestions(query)) do
        local button = ISButton:new(
            suggestionX,
            suggestionY + (index - 1) * REWARD_SUGGESTION_ROW_HEIGHT,
            textEntryBox:getWidth(),
            REWARD_SUGGESTION_ROW_HEIGHT - 2,
            value,
            self,
            KIPN_EventScenarioAdminUI.onRewardSuggestionClick
        )
        button.internal = value
        button.kipnRewardTarget = textEntryBox
        button:initialise()
        button:instantiate()
        button.kipnContainerPane = self.textPane
        self.textPane:addChild(button)
        self.fieldWidgets[#self.fieldWidgets + 1] = button
        self.rewardSuggestionButtons[#self.rewardSuggestionButtons + 1] = button
        button:bringToTop()
    end
end

function KIPN_EventScenarioAdminUI:onRewardItemChanged(textEntryBox)
    local rows = self.rewardRows or {}
    local lastRow = rows[#rows]

    if textEntryBox
        and lastRow
        and textEntryBox == lastRow.itemEntry
        and #rows < REWARD_MAX_ROWS
        and tostring(textEntryBox:getText() or ""):match("%S") then
        local rowSpacing = ROW_HEIGHT + 2
        local followingY = self.rewardFollowingY

        self:clearRewardSuggestions()

        if followingY then
            for _, widget in ipairs(self.fieldWidgets) do
                if widget.kipnContainerPane == self.textPane
                    and not widget.kipnRewardRow
                    and widget:getY() >= followingY then
                    widget:setY(widget:getY() + rowSpacing)
                end
            end
            self.rewardFollowingY = followingY + rowSpacing
        end

        self:addRewardRow(
            #rows + 1,
            nil,
            textEntryBox:getX(),
            textEntryBox:getY() + rowSpacing,
            textEntryBox:getWidth() + 90
        )

        self.textPaneContentHeight = (self.textPaneContentHeight or self.textPane:getHeight()) + rowSpacing
        self.textPane:setScrollHeight(math.max(self.textPaneContentHeight, self.textPane:getHeight()))
    end

    self:updateRewardSuggestions(textEntryBox)
end

function KIPN_EventScenarioAdminUI:onRewardSuggestionClick(button)
    if button and button.kipnRewardTarget and button.internal then
        button.kipnRewardTarget:setText(button.internal)
    end
    self:clearRewardSuggestions()
end

-- `pane` is optional because the majority of controls belong to the
-- structured settings pane (`detailPane`). Free-form controls pass
-- `textPane` explicitly.
local function addLabel(panel, x, y, text, r, g, b, pane)
    pane = pane or panel.detailPane
    local label = ISLabel:new(x, y, ROW_HEIGHT, text, r or 1, g or 1, b or 1, 1, UIFont.Small, true)
    label:initialise()
    return trackWidget(panel, pane, label)
end

-- Compact hint row for supplementary help copy that doesn't need to
-- permanently occupy vertical space -- hover to read it, via the
-- same ISToolTip/setTooltip() vanilla ISLabel already wires up.
local function addHelpTooltip(panel, x, y, labelText, tooltipText, pane)
    local label = addLabel(panel, x, y, labelText, 0.65, 0.75, 0.65, pane)
    label:setTooltip(tooltipText)
    return label
end

local function addSectionHeader(panel, pane, x, y, width, text, r, g, b)
    addLabel(panel, x, y, text, r or 0.75, g or 0.9, b or 0.75, pane)

    local line = ISPanel:new(x, y + ROW_HEIGHT - 3, width, 1)
    line:initialise()
    line:instantiate()
    line.backgroundColor = {
        r = r or 0.75,
        g = g or 0.9,
        b = b or 0.75,
        a = 0.8,
    }
    line.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    trackWidget(panel, pane, line)

    return y + ROW_HEIGHT + 5
end

-- ISRichTextPanel:getHeight() after paginate() has been observed to
-- under-report for longer, multi-line copy (autosetheight's height
-- doesn't reliably reach the widget's javaObject before the caller
-- reads it back), which left long paragraphs (e.g. the Hotspots help
-- text) overlapping whatever was laid out below them. Simulate the
-- same greedy word-wrap paginate() does, purely in Lua, and use it as
-- a floor so the reported height can never come back too small.
local function estimateWrappedTextHeight(font, text, width)
    local lineHeight = getTextManager():getFontFromEnum(font):getLineHeight()
    local spaceWidth = getTextManager():MeasureStringX(font, " ")
    local lines = 1
    local lineWidth = 0
    for word in tostring(text or ""):gmatch("%S+") do
        local wordWidth = getTextManager():MeasureStringX(font, word)
        local addedWidth = (lineWidth == 0) and wordWidth or (lineWidth + spaceWidth + wordWidth)
        if addedWidth > width and lineWidth > 0 then
            lines = lines + 1
            lineWidth = wordWidth
        else
            lineWidth = addedWidth
        end
    end
    return lines * lineHeight
end

-- Vanilla ISLabel and ISTickBox option text do not wrap. Use the
-- vanilla rich-text panel for explanatory copy that may exceed the
-- detail column, and let it report the height consumed after
-- pagination so following controls never overlap it.
local function addWrappedText(panel, x, y, width, text, pane)
    pane = pane or panel.detailPane
    local richText = ISRichTextPanel:new(x, y, width, ROW_HEIGHT)
    richText:initialise()
    richText:instantiate()
    richText.background = false
    richText.blockMouseWheel = true
    richText:setMargins(0, 0, 0, 0)
    richText:setText(tostring(text or ""))
    richText:paginate()
    local estimatedHeight = estimateWrappedTextHeight(richText.font, text, width)
    if estimatedHeight > richText:getHeight() then
        richText:setHeight(estimatedHeight)
    end
    return trackWidget(panel, pane, richText)
end

local function addMultilineEntry(panel, text, x, y, width, pane)
    pane = pane or panel.detailPane
    local entry = ISTextEntryBox:new(
        text or "",
        x,
        y,
        width,
        NARRATIVE_ENTRY_HEIGHT
    )
    entry:initialise()
    entry:instantiate()
    entry:setMultipleLine(true)
    entry:setMaxLines(64)
    entry:addScrollBars()
    return trackWidget(panel, pane, entry)
end

-- ISTickBox:new() uses its initial *height* as the square checkbox
-- size. Passing an entire multi-row control height therefore creates
-- the giant grey hover square/checkmark seen in game. Always create
-- a compact vanilla checkbox, then let addOption() grow the control.
function KIPN_EventScenarioAdminUI:buildBooleanTickBox(x, y, width, text, selected)
    local tick = ISTickBox:new(x, y, TICK_BOX_SIZE, TICK_BOX_SIZE, "")
    tick:initialise()
    tick:instantiate()
    tick:addOption("")
    tick.selected[1] = selected == true
    self.detailPane:addChild(tick)
    self.fieldWidgets[#self.fieldWidgets + 1] = tick

    local label = addWrappedText(
        self,
        x + TICK_BOX_SIZE + 8,
        y,
        math.max(40, width - TICK_BOX_SIZE - 8),
        text
    )

    return tick, y + math.max(tick:getHeight(), label:getHeight()) + 4
end

------------------------------------------------------------
-- ENUM MULTI-SELECT TICKBOX HELPER
------------------------------------------------------------
--
-- Builds one compact ISTickBox + wrapped ISRichTextPanel label PER
-- option from a KIPN.Shared enum (order/labels tables) -- used for
-- Objective Types and Outcome Types. Distinct from
-- buildConditionTickBox below, which renders a server-fetched
-- per-eventType list rather than a fixed shared enum.
--
-- Deliberately NOT a single ISTickBox with one addOption() call per
-- option: vanilla ISTickBox:render() never wraps or reserves extra
-- height for option text (see ISUI/ISTickBox.lua), so any option
-- whose label needed more than one line ate into the row below it --
-- visible as later options in the list overlapping each other. Each
-- option gets its own row here, sized by buildBooleanTickBox's
-- already-proven wrap-safe max(tick height, label height) pattern.
------------------------------------------------------------

function KIPN_EventScenarioAdminUI:buildEnumTickBox(x, y, width, order, labels, selectedValues, changeMethod)
    local selectedSet = {}

    for _, value in ipairs(selectedValues or {}) do
        selectedSet[value] = true
    end

    local rowTicks = {}

    for _, value in ipairs(order) do
        local tick = ISTickBox:new(x, y, TICK_BOX_SIZE, TICK_BOX_SIZE, "", self, changeMethod)
        tick:initialise()
        tick:instantiate()
        tick:addOption("")
        tick.selected[1] = selectedSet[value] == true
        tick.kipnEnumValue = value
        self.detailPane:addChild(tick)
        self.fieldWidgets[#self.fieldWidgets + 1] = tick
        rowTicks[#rowTicks + 1] = tick

        local label = addWrappedText(
            self,
            x + TICK_BOX_SIZE + 8,
            y,
            math.max(40, width - TICK_BOX_SIZE - 8),
            labels[value] or value
        )

        y = y + math.max(tick:getHeight(), label:getHeight()) + 4
    end

    return rowTicks, y
end

local function collectEnumSelection(ticks)
    local result = {}

    if not ticks then
        return result
    end

    for _, tick in ipairs(ticks) do
        if tick.selected[1] then
            result[#result + 1] = tick.kipnEnumValue
        end
    end

    return result
end

------------------------------------------------------------
-- LEFT PANE: definition list + lifecycle actions (Phase 5)
--
-- Called from rebuildRightPanel() right after clearFieldWidgets(), so
-- list-pane rows share the exact same track/clear cycle as the
-- centre/right panes -- see trackWidget()'s kipnContainerPane, which
-- already supports any pane, not just detailPane. Do NOT call this
-- standalone without a preceding clearFieldWidgets(): it only ADDS
-- widgets, it never clears the pane itself.
------------------------------------------------------------

local STATUS_ROW_COLOR = {
    DRAFT = { r = 0.7, g = 0.7, b = 0.7 },
    VALIDATING = { r = 0.7, g = 0.7, b = 0.7 },
    READY = { r = 0.5, g = 0.9, b = 0.5 },
    ANNOUNCED = { r = 0.55, g = 0.75, b = 1 },
    JOINING = { r = 0.55, g = 0.75, b = 1 },
    ACTIVE = { r = 1, g = 0.85, b = 0.3 },
    ENDING = { r = 1, g = 0.7, b = 0.4 },
    COMPLETE = { r = 0.65, g = 0.65, b = 0.9 },
    CLEANUP = { r = 0.65, g = 0.65, b = 0.9 },
}

function KIPN_EventScenarioAdminUI:rebuildDefinitionsList()
    local x = DETAIL_PAD
    local width = self.listPane:getWidth() - (DETAIL_PAD * 2) - 12
    local y = DETAIL_PAD

    local newButton = ISButton:new(x, y, width, ROW_HEIGHT + 2, "+ New Event", self, KIPN_EventScenarioAdminUI.onCreateDefinition)
    newButton:initialise()
    newButton:instantiate()
    trackWidget(self, self.listPane, newButton)
    y = y + ROW_HEIGHT + 2 + 4

    local refreshButton = ISButton:new(x, y, width, ROW_HEIGHT, "Refresh List", self, KIPN_EventScenarioAdminUI.refreshDefinitions)
    refreshButton:initialise()
    refreshButton:instantiate()
    trackWidget(self, self.listPane, refreshButton)
    y = y + ROW_HEIGHT + 10

    y = addSectionHeader(self, self.listPane, x, y, width, "All Events", 0.9, 0.85, 0.6)

    local sortedDefinitions = {}
    for _, definition in ipairs(self.definitions) do
        sortedDefinitions[#sortedDefinitions + 1] = definition
    end
    table.sort(sortedDefinitions, function(a, b) return tostring(a.name) < tostring(b.name) end)

    local stillExists = false

    if #sortedDefinitions == 0 then
        addLabel(self, x, y, "(no events yet)", 0.6, 0.6, 0.6, self.listPane)
        y = y + ROW_HEIGHT
    end

    for _, definition in ipairs(sortedDefinitions) do
        if definition.id == self.selectedDefinitionId then
            stillExists = true
        end

        local isSelected = definition.id == self.selectedDefinitionId
        local color = STATUS_ROW_COLOR[definition.status] or { r = 0.8, g = 0.8, b = 0.8 }
        local legacyTag = definition.migrationStatus == "LEGACY_REVIEW_REQUIRED" and " [LEGACY]" or ""
        local rowLabel = tostring(definition.name) .. legacyTag .. "  [" .. tostring(definition.status) .. "]"

        local rowButton = ISButton:new(x, y, width, ROW_HEIGHT + 4, rowLabel, self, KIPN_EventScenarioAdminUI.onSelectDefinition)
        rowButton.internal = definition.id
        rowButton:initialise()
        rowButton:instantiate()

        if isSelected then
            rowButton.backgroundColor = { r = color.r * 0.35, g = color.g * 0.35, b = color.b * 0.35, a = 0.9 }
        end
        rowButton.borderColor = { r = color.r, g = color.g, b = color.b, a = isSelected and 1 or 0.5 }

        trackWidget(self, self.listPane, rowButton)
        y = y + ROW_HEIGHT + 4 + 4
    end

    if not stillExists and self.selectedDefinitionId then
        self.selectedDefinitionId = nil
        self.status = nil
    end

    y = y + 8

    ------------------------------------------------------------
    -- LIFECYCLE ACTIONS (contextual to current selection) --
    -- New/Delete/Validate/Announce/Open Joining/Start/Stop/Reset,
    -- as permitted by lifecycle state. Save Definition lives at the
    -- bottom of the centre (Configuration) pane instead, next to the
    -- fields it commits.
    ------------------------------------------------------------

    local definition = self:getSelectedDefinition()

    if definition then
        local currentStatus = definition.status or (self.status and self.status.status)

        y = addSectionHeader(self, self.listPane, x, y, width, "Lifecycle Actions")
        addLabel(self, x, y, "Status: " .. tostring(currentStatus), 0.85, 0.85, 0.85, self.listPane)
        y = y + ROW_HEIGHT + 4

        local buttonGap = 6
        local buttonWidth = math.floor((width - buttonGap) / 2)

        local validateButton = ISButton:new(x, y, buttonWidth, ROW_HEIGHT + 2, "Validate", self, KIPN_EventScenarioAdminUI.onValidate)
        validateButton:initialise()
        validateButton:instantiate()
        validateButton:setEnable(currentStatus == "DRAFT")
        trackWidget(self, self.listPane, validateButton)

        local announceButton = ISButton:new(x + buttonWidth + buttonGap, y, buttonWidth, ROW_HEIGHT + 2, "Announce", self, KIPN_EventScenarioAdminUI.onAnnounce)
        announceButton:initialise()
        announceButton:instantiate()
        announceButton:setEnable(currentStatus == "READY")
        trackWidget(self, self.listPane, announceButton)
        y = y + ROW_HEIGHT + 2 + 4

        local openJoiningButton = ISButton:new(x, y, buttonWidth, ROW_HEIGHT + 2, "Open Joining", self, KIPN_EventScenarioAdminUI.onOpenJoining)
        openJoiningButton:initialise()
        openJoiningButton:instantiate()
        openJoiningButton:setEnable(currentStatus == "ANNOUNCED")
        trackWidget(self, self.listPane, openJoiningButton)

        local beginButton = ISButton:new(x + buttonWidth + buttonGap, y, buttonWidth, ROW_HEIGHT + 2, "Begin Event", self, KIPN_EventScenarioAdminUI.onStartEvent)
        beginButton:initialise()
        beginButton:instantiate()
        beginButton:setEnable(currentStatus == "JOINING")
        trackWidget(self, self.listPane, beginButton)
        y = y + ROW_HEIGHT + 2 + 4

        local stopButton = ISButton:new(x, y, buttonWidth, ROW_HEIGHT + 2, "Stop Event", self, KIPN_EventScenarioAdminUI.onStopEvent)
        stopButton:initialise()
        stopButton:instantiate()
        stopButton:setEnable(currentStatus == "ANNOUNCED" or currentStatus == "JOINING" or currentStatus == "ACTIVE")
        trackWidget(self, self.listPane, stopButton)

        local resetButton = ISButton:new(x + buttonWidth + buttonGap, y, buttonWidth, ROW_HEIGHT + 2, "Reset For Reuse", self, KIPN_EventScenarioAdminUI.onResetForReuse)
        resetButton:initialise()
        resetButton:instantiate()
        resetButton:setEnable(currentStatus == "COMPLETE")
        trackWidget(self, self.listPane, resetButton)
        y = y + ROW_HEIGHT + 2 + 8

        local deleteButton = ISButton:new(x, y, width, ROW_HEIGHT + 2, "Delete Event", self, KIPN_EventScenarioAdminUI.onDeleteDefinition)
        deleteButton:initialise()
        deleteButton:instantiate()
        deleteButton:setEnable(currentStatus == "DRAFT" or currentStatus == "READY")
        trackWidget(self, self.listPane, deleteButton)
        y = y + ROW_HEIGHT + 2

        if definition.migrationStatus == "LEGACY_REVIEW_REQUIRED" then
            y = y + 8
            local legacyLabel = addWrappedText(
                self, x, y, width,
                "Legacy definition: its original preset could not be safely mapped onto a Mode. Assign a Mode below before it can validate.",
                self.listPane
            )
            y = y + legacyLabel:getHeight()
        end
    end

    self.listPane:setScrollHeight(math.max(y + DETAIL_PAD, self.listPane:getHeight()))
end

function KIPN_EventScenarioAdminUI:rebuildRightPanel()
    if self.renderedDefinitionId and self.captureCurrentDraft then
        self:captureCurrentDraft()
    end

    self:clearFieldWidgets()
    self._buildingForm = true

    -- Phase 5: LEFT pane content shares this same clear/rebuild cycle
    -- -- see rebuildDefinitionsList()'s header comment.
    self:rebuildDefinitionsList()

    local definition = self:getSelectedDefinition()

    local x = DETAIL_PAD
    local width = self.detailPane:getWidth() - (DETAIL_PAD * 2) - 12
    local formLabelWidth = math.min(FORM_LABEL_WIDTH, math.floor(width * 0.46))
    local fieldX = x + formLabelWidth
    local fieldWidth = math.max(80, width - formLabelWidth)
    local y = 0
    local textX = DETAIL_PAD
    local textWidth = self.textPane:getWidth() - (DETAIL_PAD * 2) - 12
    local textY = 0

    if not definition then
        addLabel(self, x, y, "Select or create an event to edit it.", 0.8, 0.8, 0.8)
        addLabel(self, textX, textY, "Free-form fields appear here after selecting an event.", 0.8, 0.8, 0.8, self.textPane)
        self.detailPane:setScrollHeight(self.detailPane:getHeight())
        self.textPane:setScrollHeight(self.textPane:getHeight())
        self.renderedDefinitionId = nil
        self._buildingForm = false
        return
    end

    local formDefinition = self.editorDrafts[definition.id] or definition

    y = addSectionHeader(self, self.detailPane, x, y, width, "Event Definition")

    addLabel(self, x, y, "Event Name")
    y = y + ROW_HEIGHT

    self.nameEntry = ISTextEntryBox:new(formDefinition.name or "", x, y, width, ROW_HEIGHT - 4)
    self.nameEntry:initialise()
    self.nameEntry:instantiate()
    trackWidget(self, self.detailPane, self.nameEntry)
    y = y + ROW_HEIGHT + 10

    ------------------------------------------------------------
    -- SCENARIO PRESET
    --
    -- Autofills the component fields below and records which recipe was
    -- selected. Every resulting field remains independently editable.
    ------------------------------------------------------------

    addLabel(self, x, y, "Scenario Preset")
    y = y + ROW_HEIGHT

    self.scenarioPresetCombo = ISComboBox:new(x, y, width, ROW_HEIGHT, self, KIPN_EventScenarioAdminUI.onScenarioPresetChanged)
    local presetSelectedIndex = 1
    for _, option in ipairs(SCENARIO_PRESET_OPTIONS) do
        self.scenarioPresetCombo:addOptionWithData(option.text, option.value)
        if option.value == (formDefinition.scenarioPresetId or "CUSTOM") then
            presetSelectedIndex = #self.scenarioPresetCombo.options
        end
    end
    self.scenarioPresetCombo:setSelected(presetSelectedIndex)
    self.scenarioPresetCombo:initialise()
    self.scenarioPresetCombo:instantiate()
    self.detailPane:addChild(self.scenarioPresetCombo)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.scenarioPresetCombo
    y = y + ROW_HEIGHT + 8

    ------------------------------------------------------------
    -- MODE AND VARIANT (Phase 5) -- schema v2's first-class
    -- Mode/Variant/Modifiers, alongside (not yet replacing) the
    -- legacy eventType/Scenario Preset above. See
    -- KIPN_EventModeRegistry.lua's header for what mode/variant
    -- currently is (persisted metadata) versus isn't (a mechanical
    -- engine) yet.
    ------------------------------------------------------------

    y = addSectionHeader(self, self.detailPane, x, y, width, "Mode and Variant")

    if formDefinition.migrationStatus == "LEGACY_REVIEW_REQUIRED" then
        local legacyNote = addWrappedText(
            self, x, y, width,
            "This definition's original preset (" .. tostring(formDefinition.legacyPresetId or "unknown")
                .. ") could not be safely mapped onto a Mode. Choose one explicitly to continue.",
            self.detailPane
        )
        y = y + legacyNote:getHeight() + 4
    end

    addLabel(self, x, y, "Mode")
    self.modeCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, KIPN_EventScenarioAdminUI.onModeChanged)
    self.modeCombo:addOptionWithData("(unassigned)", nil)
    local modeSelectedIndex = 1
    for index, mode in ipairs(KIPN.Shared.EventModeOrder or {}) do
        self.modeCombo:addOptionWithData((KIPN.Shared.EventModeLabels or {})[mode] or mode, mode)
        if formDefinition.mode == mode then modeSelectedIndex = index + 1 end
    end
    self.modeCombo:setSelected(modeSelectedIndex)
    self.modeCombo:initialise()
    self.modeCombo:instantiate()
    self.detailPane:addChild(self.modeCombo)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.modeCombo
    y = y + ROW_HEIGHT + 4

    -- Phase 6: Capture gained its own TEAM_CTF/FFA variant split
    -- alongside Extraction's four variants -- same combo, sourced
    -- from whichever mode's own Shared vocabulary applies.
    local variantLabel, variantOrder, variantLabels = nil, nil, nil
    if formDefinition.mode == "EXTRACTION" then
        variantLabel, variantOrder, variantLabels = "Extraction Variant", KIPN.Shared.EventExtractionVariantOrder, KIPN.Shared.EventExtractionVariantLabels
    elseif formDefinition.mode == "CAPTURE" then
        variantLabel, variantOrder, variantLabels = "Capture Variant", KIPN.Shared.EventCaptureVariantOrder, KIPN.Shared.EventCaptureVariantLabels
    end

    if variantOrder then
        addLabel(self, x, y, variantLabel)
        self.variantCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, KIPN_EventScenarioAdminUI.onModeChanged)
        local variantSelectedIndex = 1
        for index, variant in ipairs(variantOrder) do
            self.variantCombo:addOptionWithData((variantLabels or {})[variant] or variant, variant)
            if formDefinition.variant == variant then variantSelectedIndex = index end
        end
        self.variantCombo:setSelected(variantSelectedIndex)
        self.variantCombo:initialise()
        self.variantCombo:instantiate()
        self.detailPane:addChild(self.variantCombo)
        self.fieldWidgets[#self.fieldWidgets + 1] = self.variantCombo
        y = y + ROW_HEIGHT + 4
    else
        self.variantCombo = nil
    end

    -- Phase 6: Capture-specific config. flagItemFullType is free-text
    -- (see KIPN_EventScenarioService.lua's sanitizeCaptureConfig --
    -- no vanilla item ID is guessed here either).
    if formDefinition.mode == "CAPTURE" then
        local captureConfig = formDefinition.captureConfig or {}

        -- Stacked (label on its own row, field below at x rather than
        -- fieldX): these labels are long enough to run into a
        -- same-row field at fieldX, especially at larger UI font
        -- scales -- see the Environment section's weatherEnabledTick
        -- for the same reasoning.
        addLabel(self, x, y, "Flag Item Full Type (e.g. Base.Flag)")
        y = y + ROW_HEIGHT
        self.captureFlagItemEntry = ISTextEntryBox:new(tostring(captureConfig.flagItemFullType or ""), x, y, fieldWidth, ROW_HEIGHT - 4)
        self.captureFlagItemEntry:initialise()
        self.captureFlagItemEntry:instantiate()
        self.detailPane:addChild(self.captureFlagItemEntry)
        self.fieldWidgets[#self.fieldWidgets + 1] = self.captureFlagItemEntry
        y = y + ROW_HEIGHT + 4

        addLabel(self, x, y, "Auto-Return Seconds (lost/unreachable flag)")
        y = y + ROW_HEIGHT
        self.captureAutoReturnEntry = ISTextEntryBox:new(tostring(captureConfig.autoReturnSeconds or 90), x, y, math.min(100, fieldWidth), ROW_HEIGHT - 4)
        self.captureAutoReturnEntry:initialise()
        self.captureAutoReturnEntry:instantiate()
        if self.captureAutoReturnEntry.setOnlyNumbers then self.captureAutoReturnEntry:setOnlyNumbers(true) end
        self.detailPane:addChild(self.captureAutoReturnEntry)
        self.fieldWidgets[#self.fieldWidgets + 1] = self.captureAutoReturnEntry
        y = y + ROW_HEIGHT + 4
    else
        self.captureFlagItemEntry = nil
        self.captureAutoReturnEntry = nil
    end

    y = y + 4

    ------------------------------------------------------------
    -- MODIFIERS (Naked and Afraid -- see
    -- KIPN_EventModeRegistry.lua's IsModifierCompatible() for the
    -- compatibility matrix. This checkbox doesn't pre-emptively grey
    -- itself out -- Validate surfaces the exact incompatibility
    -- reason instead, the same way every other validation failure
    -- does, rather than duplicating the server's compatibility matrix
    -- client-side.)
    ------------------------------------------------------------

    local modifiers = formDefinition.modifiers or {}
    self.nakedAndAfraidTick, y = self:buildBooleanTickBox(
        x, y, width, "Naked and Afraid (escrows and strips all carried/worn items on join)",
        modifiers.NAKED_AND_AFRAID == true
    )
    y = y + 4

    ------------------------------------------------------------
    -- ZOMBIE DIRECTOR (the current internal runtime driver; unlike a
    -- Scenario Preset, these fields are persisted and mechanically
    -- affect the live event).
    ------------------------------------------------------------

    y = addSectionHeader(self, self.detailPane, x, y, width, "Zombie Director")

    local spawnRules = formDefinition.spawnRules or {}

    addLabel(self, x, y, "Base Spawn Radius (tiles)")

    self.spawnRadiusEntry = ISTextEntryBox:new(tostring(spawnRules.baseSpawnRadius or 40), fieldX, y, math.min(100, fieldWidth), ROW_HEIGHT - 4)
    self.spawnRadiusEntry:initialise()
    self.spawnRadiusEntry:instantiate()
    if self.spawnRadiusEntry.setOnlyNumbers then self.spawnRadiusEntry:setOnlyNumbers(true) end
    self.detailPane:addChild(self.spawnRadiusEntry)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.spawnRadiusEntry
    y = y + ROW_HEIGHT + 4

    addLabel(self, x, y, "Director Type")

    self.directorTypeCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, nil)
    local directorTypeSelectedIndex = 1
    for index, directorType in ipairs(KIPN.Shared.EventDirectorTypeOrder) do
        self.directorTypeCombo:addOptionWithData(KIPN.Shared.EventDirectorTypeLabels[directorType], directorType)
        if formDefinition.directorType == directorType then
            directorTypeSelectedIndex = index
        end
    end
    self.directorTypeCombo:setSelected(directorTypeSelectedIndex)
    self.directorTypeCombo:initialise()
    self.directorTypeCombo:instantiate()
    self.detailPane:addChild(self.directorTypeCombo)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.directorTypeCombo
    y = y + ROW_HEIGHT + 4

    addLabel(self, x, y, "Zombie Theme")

    self.zombieThemeCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, nil)
    local storedZombieTheme = type(formDefinition.zombieTheme) == "table"
        and formDefinition.zombieTheme.themeId or formDefinition.zombieTheme
    local zombieThemeSelectedIndex = 1
    for index, themeId in ipairs(KIPN.Shared.EventZombieThemeOrder or { "RANDOM" }) do
        self.zombieThemeCombo:addOptionWithData(
            (KIPN.Shared.EventZombieThemeLabels or {})[themeId] or themeId,
            themeId
        )
        if storedZombieTheme == themeId then zombieThemeSelectedIndex = index end
    end
    self.zombieThemeCombo:setSelected(zombieThemeSelectedIndex)
    self.zombieThemeCombo:initialise()
    self.zombieThemeCombo:instantiate()
    self.detailPane:addChild(self.zombieThemeCombo)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.zombieThemeCombo
    y = y + ROW_HEIGHT + 4

    self.escalationTick, y = self:buildBooleanTickBox(
        x,
        y,
        width,
        "Passive escalation enabled (governed by Director Type above; Zombie Waves stays manual-only)",
        spawnRules.escalationEnabled
    )
    y = y + 4

    ------------------------------------------------------------
    -- EVENT AREA (zone, targeted hotspots, or open-map scope)
    ------------------------------------------------------------

    local zoneStatusText = definition.zoneId and ("Zone: " .. definition.zoneId) or "Zone: not set"

    y = addSectionHeader(self, self.detailPane, x, y, width, "Event Area and Hotspots")

    addLabel(self, x, y, "Scope")
    self.scopeTypeCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, nil)
    local scopeSelectedIndex = 1
    for index, scopeType in ipairs(KIPN.Shared.EventScopeTypeOrder or { "ZONE" }) do
        self.scopeTypeCombo:addOptionWithData(
            (KIPN.Shared.EventScopeTypeLabels or {})[scopeType] or scopeType,
            scopeType
        )
        if (formDefinition.scopeType or "ZONE") == scopeType then scopeSelectedIndex = index end
    end
    self.scopeTypeCombo:setSelected(scopeSelectedIndex)
    self.scopeTypeCombo:initialise()
    self.scopeTypeCombo:instantiate()
    self.detailPane:addChild(self.scopeTypeCombo)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.scopeTypeCombo
    y = y + ROW_HEIGHT + 4

    addLabel(self, x, y, "Maximum Rounds")
    self.maxRoundsEntry = ISTextEntryBox:new(tostring(formDefinition.maxRounds or 1), fieldX, y, math.min(100, fieldWidth), ROW_HEIGHT - 4)
    self.maxRoundsEntry:initialise()
    self.maxRoundsEntry:instantiate()
    if self.maxRoundsEntry.setOnlyNumbers then self.maxRoundsEntry:setOnlyNumbers(true) end
    self.detailPane:addChild(self.maxRoundsEntry)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.maxRoundsEntry
    y = y + ROW_HEIGHT + 4

    addLabel(self, x, y, zoneStatusText, 0.8, 0.8, 0.8)
    y = y + ROW_HEIGHT

    local drawZoneButtonWidth = math.min(240, width)
    local drawZoneButton = ISButton:new(x, y, drawZoneButtonWidth, ROW_HEIGHT + 2, "Draw Zone For This Event", self, KIPN_EventScenarioAdminUI.onDrawEventZone)
    drawZoneButton:initialise()
    drawZoneButton:instantiate()
    self.detailPane:addChild(drawZoneButton)
    self.fieldWidgets[#self.fieldWidgets + 1] = drawZoneButton

    -- Quick-playtest helper: builds a zone + whatever hotspots the
    -- chosen Mode requires around the admin's own position, so a
    -- scenario can be tried out without hand-drawing every hotspot
    -- first. Still just a starting point -- nothing stops the admin
    -- from redrawing/deleting individual hotspots afterward.
    local randomizeButtonX = x + drawZoneButtonWidth + 8
    local randomizeButtonWidth = math.max(80, width - drawZoneButtonWidth - 8)
    local randomizeButton = ISButton:new(randomizeButtonX, y, randomizeButtonWidth, ROW_HEIGHT + 2, "Randomize Zone + Hotspots", self, KIPN_EventScenarioAdminUI.onRandomizeZoneAndHotspots)
    randomizeButton:initialise()
    randomizeButton:instantiate()
    self.detailPane:addChild(randomizeButton)
    self.fieldWidgets[#self.fieldWidgets + 1] = randomizeButton
    y = y + ROW_HEIGHT + 2 + 8

    local hotspots = formDefinition.hotspots or definition.hotspots or {}
    addLabel(self, x, y, "Hotspots: " .. tostring(#hotspots), 0.8, 0.8, 0.8)
    y = y + ROW_HEIGHT

    -- Preserved across rebuilds (unlike hotspotRoundEntry, which
    -- resets each time) so picking Narrative Location doesn't lose
    -- its own selection the instant onHotspotTypeChanged rebuilds the
    -- panel to reveal that type's extra fields below.
    local pendingHotspotType = self.hotspotTypeCombo and getComboData(self.hotspotTypeCombo)

    addLabel(self, x, y, "New Hotspot Type")
    self.hotspotTypeCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, KIPN_EventScenarioAdminUI.onHotspotTypeChanged)
    local hotspotTypeSelectedIndex = 1
    for index, hotspotType in ipairs(KIPN.Shared.EventHotspotTypeOrder or {}) do
        self.hotspotTypeCombo:addOptionWithData(
            (KIPN.Shared.EventHotspotTypeLabels or {})[hotspotType] or hotspotType,
            hotspotType
        )
        if hotspotType == pendingHotspotType then
            hotspotTypeSelectedIndex = index
        end
    end
    self.hotspotTypeCombo:setSelected(hotspotTypeSelectedIndex)
    self.hotspotTypeCombo:initialise()
    self.hotspotTypeCombo:instantiate()
    self.detailPane:addChild(self.hotspotTypeCombo)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.hotspotTypeCombo
    y = y + ROW_HEIGHT + 4

    -- Narrative Location hotspots carry their own flavor text and an
    -- announce scope -- fired on proximity by
    -- KIPN_EventTriggerService.lua's TickNarrativeHotspots(),
    -- independent of the Objectives/Triggers system below (no
    -- Objective needs to exist first).
    if getComboData(self.hotspotTypeCombo) == "NARRATIVE_LOCATION" then
        addLabel(self, x, y, "Narrative Text")
        self.hotspotNarrativeTextEntry = ISTextEntryBox:new("", fieldX, y - 2, fieldWidth, ROW_HEIGHT - 4)
        self.hotspotNarrativeTextEntry:initialise()
        self.hotspotNarrativeTextEntry:instantiate()
        self.detailPane:addChild(self.hotspotNarrativeTextEntry)
        self.fieldWidgets[#self.fieldWidgets + 1] = self.hotspotNarrativeTextEntry
        y = y + ROW_HEIGHT + 4

        addLabel(self, x, y, "Announce")
        self.hotspotNarrativeScopeCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, nil)
        self.hotspotNarrativeScopeCombo:addOptionWithData("Local (each player, on their own approach)", "LOCAL")
        self.hotspotNarrativeScopeCombo:addOptionWithData("Global (whole event, first to reach it)", "GLOBAL")
        self.hotspotNarrativeScopeCombo:setSelected(1)
        self.hotspotNarrativeScopeCombo:initialise()
        self.hotspotNarrativeScopeCombo:instantiate()
        self.detailPane:addChild(self.hotspotNarrativeScopeCombo)
        self.fieldWidgets[#self.fieldWidgets + 1] = self.hotspotNarrativeScopeCombo
        y = y + ROW_HEIGHT + 4
    else
        self.hotspotNarrativeTextEntry = nil
        self.hotspotNarrativeScopeCombo = nil
    end

    addLabel(self, x, y, "Round Number (optional)")
    self.hotspotRoundEntry = ISTextEntryBox:new("", fieldX, y, math.min(100, fieldWidth), ROW_HEIGHT - 4)
    self.hotspotRoundEntry:initialise()
    self.hotspotRoundEntry:instantiate()
    if self.hotspotRoundEntry.setOnlyNumbers then self.hotspotRoundEntry:setOnlyNumbers(true) end
    self.detailPane:addChild(self.hotspotRoundEntry)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.hotspotRoundEntry
    y = y + ROW_HEIGHT + 4

    -- Phase 6: only meaningful for TEAM_BASE hotspots (Team CTF's
    -- one-base-per-team-per-round) -- see
    -- KIPN_EventHotspotService.lua's teamId field.
    if formDefinition.teams and #formDefinition.teams > 0 then
        addLabel(self, x, y, "Team (for Team Base hotspots)")
        self.hotspotTeamCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, nil)
        self.hotspotTeamCombo:addOptionWithData("(none)", nil)
        for _, team in ipairs(formDefinition.teams) do
            self.hotspotTeamCombo:addOptionWithData(team.name, team.id)
        end
        self.hotspotTeamCombo:setSelected(1)
        self.hotspotTeamCombo:initialise()
        self.hotspotTeamCombo:instantiate()
        self.detailPane:addChild(self.hotspotTeamCombo)
        self.fieldWidgets[#self.fieldWidgets + 1] = self.hotspotTeamCombo
        y = y + ROW_HEIGHT + 4
    else
        self.hotspotTeamCombo = nil
    end

    addLabel(self, x, y, "Existing Hotspot")
    self.hotspotSelectCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, nil)
    if #hotspots == 0 then
        self.hotspotSelectCombo:addOptionWithData("(none)", nil)
    else
        for _, hotspot in ipairs(hotspots) do
            local label = tostring(hotspot.type or "HOTSPOT")
            if hotspot.roundNumber then label = label .. " / round " .. tostring(hotspot.roundNumber) end
            if hotspot.teamId then label = label .. " / team " .. tostring(hotspot.teamId) end
            if hotspot.label and hotspot.label ~= "" then label = label .. " / " .. tostring(hotspot.label) end
            self.hotspotSelectCombo:addOptionWithData(label, hotspot.id)
        end
    end
    self.hotspotSelectCombo:setSelected(1)
    self.hotspotSelectCombo:initialise()
    self.hotspotSelectCombo:instantiate()
    self.detailPane:addChild(self.hotspotSelectCombo)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.hotspotSelectCombo
    y = y + ROW_HEIGHT + 4

    local hotspotButtonWidth = math.floor((width - 8) / 2)
    local drawHotspotButton = ISButton:new(x, y, hotspotButtonWidth, ROW_HEIGHT + 2, "Draw Hotspot", self, KIPN_EventScenarioAdminUI.onDrawEventHotspot)
    drawHotspotButton:initialise()
    drawHotspotButton:instantiate()
    self.detailPane:addChild(drawHotspotButton)
    self.fieldWidgets[#self.fieldWidgets + 1] = drawHotspotButton

    local deleteHotspotButton = ISButton:new(x + hotspotButtonWidth + 8, y, hotspotButtonWidth, ROW_HEIGHT + 2, "Delete Selected", self, KIPN_EventScenarioAdminUI.onDeleteEventHotspot)
    deleteHotspotButton:initialise()
    deleteHotspotButton:instantiate()
    deleteHotspotButton.enable = #hotspots > 0
    self.detailPane:addChild(deleteHotspotButton)
    self.fieldWidgets[#self.fieldWidgets + 1] = deleteHotspotButton
    y = y + ROW_HEIGHT + 10

    addHelpTooltip(
        self, x, y, "Hotspot requirements by mode (hover for details)",
        "KOTH uses one HILL_LOCATION per round (up to 10) and requires the HOLD_AREA objective type below to be ticked. Chase requires the CHASE_TARGET objective type below to be ticked. Extraction's Prison Break variant requires RETRIEVE plus an EXTRACTION_POINT hotspot, authored as a second ordered objective's proximity trigger (see Objectives below). OPEN_MAP/HOTSPOTS zombie events should also define one or more ZOMBIE_SPAWN hotspots."
    )
    y = y + ROW_HEIGHT + 8

    ------------------------------------------------------------
    -- ENVIRONMENT
    ------------------------------------------------------------

    local environment = formDefinition.environment or {}

    y = addSectionHeader(self, self.detailPane, x, y, width, "Environment")

    addLabel(self, x, y, "Time of Day")

    self.timeOfDayCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, nil)
    local timeSelectedIndex = 1
    for index, option in ipairs(ENVIRONMENT_TIME_OF_DAY_OPTIONS) do
        self.timeOfDayCombo:addOptionWithData(option.text, option.value)
        if environment.timeOfDay == option.value then
            timeSelectedIndex = index
        end
    end
    self.timeOfDayCombo:setSelected(timeSelectedIndex)
    self.timeOfDayCombo:initialise()
    self.timeOfDayCombo:instantiate()
    self.detailPane:addChild(self.timeOfDayCombo)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.timeOfDayCombo
    y = y + ROW_HEIGHT + 4

    -- Full-width row of its own: ISTickBox option text neither wraps
    -- nor clips to its declared width (see ISUI/ISTickBox.lua's
    -- render()), so sharing a row with weatherCombo at a fixed fieldX
    -- let the label run straight into the combo under larger UI font
    -- scales. Stacking avoids that regardless of font size/language.
    self.weatherEnabledTick = ISTickBox:new(x, y, width, TICK_BOX_SIZE, "")
    self.weatherEnabledTick:initialise()
    self.weatherEnabledTick:instantiate()
    self.weatherEnabledTick:addOption("Set weather preset")
    self.weatherEnabledTick.selected[1] = environment.weatherPreset ~= nil
    self.detailPane:addChild(self.weatherEnabledTick)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.weatherEnabledTick
    y = y + self.weatherEnabledTick:getHeight() + 6

    addLabel(self, x, y, "Weather Preset")

    self.weatherCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, nil)
    local weatherSelectedIndex = 1
    for index, option in ipairs(ENVIRONMENT_WEATHER_OPTIONS) do
        self.weatherCombo:addOptionWithData(option.text, option.value)
        if environment.weatherPreset == option.value then
            weatherSelectedIndex = index
        end
    end
    self.weatherCombo:setSelected(weatherSelectedIndex)
    self.weatherCombo:initialise()
    self.weatherCombo:instantiate()
    self.detailPane:addChild(self.weatherCombo)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.weatherCombo
    y = y + ROW_HEIGHT + 8

    ------------------------------------------------------------
    -- RULES / COMBAT RULES
    --
    -- Rule Type is the single authoritative choice -- it drives the
    -- "Allow PvP damage" tick below server-side (see
    -- KIPN_EventScenarioService.lua's applyRuleTypeToCombatRules)
    -- UNLESS Rule Type is Custom, in which case the tick is used
    -- as-submitted. No Combat is mechanically enforced as a true
    -- pacifism zone (blocks ALL damage, not just PvP) -- see
    -- KIPN_EventRuntimeService.lua. Team currently behaves like PvP;
    -- there is no team roster/scoring system implemented yet.
    ------------------------------------------------------------

    y = addSectionHeader(self, self.detailPane, x, y, width, "Rules and Combat")
    addLabel(self, x, y, "Rule Type")

    self.ruleTypeCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, nil)
    local ruleTypeSelectedIndex = 1
    for index, ruleType in ipairs(KIPN.Shared.EventRuleTypeOrder) do
        self.ruleTypeCombo:addOptionWithData(KIPN.Shared.EventRuleTypeLabels[ruleType], ruleType)
        if formDefinition.ruleType == ruleType then
            ruleTypeSelectedIndex = index
        end
    end
    self.ruleTypeCombo:setSelected(ruleTypeSelectedIndex)
    self.ruleTypeCombo:initialise()
    self.ruleTypeCombo:instantiate()
    self.detailPane:addChild(self.ruleTypeCombo)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.ruleTypeCombo
    y = y + ROW_HEIGHT + 4

    local combatRules = formDefinition.combatRules or {}

    self.allowLeaveTick, y = self:buildBooleanTickBox(
        x, y, width, "Allow participants to leave the zone", combatRules.allowLeaveZone
    )

    self.pvpAllowedTick, y = self:buildBooleanTickBox(
        x,
        y,
        width,
        "Allow PvP damage inside the zone (only respected when Rule Type = Custom)",
        combatRules.pvpAllowedInZone
    )
    y = y + 4

    ------------------------------------------------------------
    -- TIMER
    ------------------------------------------------------------

    y = addSectionHeader(self, self.detailPane, x, y, width, "Timer")
    addLabel(self, x, y, "Timer Type")

    self.timerTypeCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, nil)
    local timerTypeSelectedIndex = 1
    for index, timerType in ipairs(KIPN.Shared.EventTimerTypeOrder) do
        self.timerTypeCombo:addOptionWithData(KIPN.Shared.EventTimerTypeLabels[timerType], timerType)
        if formDefinition.timerType == timerType then
            timerTypeSelectedIndex = index
        end
    end
    self.timerTypeCombo:setSelected(timerTypeSelectedIndex)
    self.timerTypeCombo:initialise()
    self.timerTypeCombo:instantiate()
    self.detailPane:addChild(self.timerTypeCombo)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.timerTypeCombo
    y = y + ROW_HEIGHT + 4

    local duration = formDefinition.duration or {}

    -- Full-width row of its own -- see the weatherEnabledTick comment
    -- above; sharing a row with durationHoursEntry at a fixed fieldX
    -- had the same overlap risk.
    self.durationEnabledTick = ISTickBox:new(x, y, width, TICK_BOX_SIZE, "")
    self.durationEnabledTick:initialise()
    self.durationEnabledTick:instantiate()
    self.durationEnabledTick:addOption("Duration enabled")
    self.durationEnabledTick.selected[1] = duration.enabled == true
    self.detailPane:addChild(self.durationEnabledTick)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.durationEnabledTick
    y = y + self.durationEnabledTick:getHeight() + 6

    local durationSeconds = tonumber(duration.durationSeconds) or 0
    local durationHours = math.floor(durationSeconds / 3600)
    local durationMinutes = math.floor((durationSeconds % 3600) / 60)

    -- "hours"/"minutes" are measured rather than offset by fixed
    -- pixel counts: a hardcoded gap (e.g. the previous "+ 5") only
    -- clears the label text at the default UI font scale. Project
    -- Zomboid's accessibility text-size option can render these
    -- words wide enough to reach into the next entry box, which is
    -- exactly the "pushed together" overlap being fixed here.
    local unitFont = UIFont.Small
    local hoursLabelWidth = getTextManager():MeasureStringX(unitFont, "hours")
    local minutesLabelWidth = getTextManager():MeasureStringX(unitFont, "minutes")
    local unitGap = 6
    local fieldGap = 14
    local reservedWidth = (unitGap * 2) + hoursLabelWidth + fieldGap + minutesLabelWidth
    local durationEntryWidth = math.min(64, math.max(44, math.floor((fieldWidth - reservedWidth) / 2)))

    addLabel(self, x, y + 2, "Duration")

    self.durationHoursEntry = ISTextEntryBox:new(tostring(durationHours), fieldX, y, durationEntryWidth, ROW_HEIGHT - 4)
    self.durationHoursEntry:initialise()
    self.durationHoursEntry:instantiate()
    if self.durationHoursEntry.setOnlyNumbers then self.durationHoursEntry:setOnlyNumbers(true) end
    self.detailPane:addChild(self.durationHoursEntry)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.durationHoursEntry

    local hoursLabelX = fieldX + durationEntryWidth + unitGap
    addLabel(self, hoursLabelX, y + 2, "hours", 0.7, 0.7, 0.7)

    local minutesX = hoursLabelX + hoursLabelWidth + fieldGap
    self.durationMinutesEntry = ISTextEntryBox:new(tostring(durationMinutes), minutesX, y, durationEntryWidth, ROW_HEIGHT - 4)
    self.durationMinutesEntry:initialise()
    self.durationMinutesEntry:instantiate()
    if self.durationMinutesEntry.setOnlyNumbers then self.durationMinutesEntry:setOnlyNumbers(true) end
    self.detailPane:addChild(self.durationMinutesEntry)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.durationMinutesEntry
    addLabel(self, minutesX + durationEntryWidth + unitGap, y + 2, "minutes", 0.7, 0.7, 0.7)
    y = y + ROW_HEIGHT + 8

    ------------------------------------------------------------
    -- EXPIRY BEHAVIOR (Phase 4/5) -- what the event-wide duration
    -- above means when it runs out. WIN is the default -- every
    -- definition that predates this field behaves exactly as before.
    ------------------------------------------------------------

    addLabel(self, x, y, "On Duration Expiry")
    self.expiryBehaviorCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, nil)
    local expiryBehaviorSelectedIndex = 1
    for index, behavior in ipairs(KIPN.Shared.EventTimerExpiryBehaviorOrder or { "WIN" }) do
        self.expiryBehaviorCombo:addOptionWithData((KIPN.Shared.EventTimerExpiryBehaviorLabels or {})[behavior] or behavior, behavior)
        if (duration.expiryBehavior or "WIN") == behavior then expiryBehaviorSelectedIndex = index end
    end
    self.expiryBehaviorCombo:setSelected(expiryBehaviorSelectedIndex)
    self.expiryBehaviorCombo:initialise()
    self.expiryBehaviorCombo:instantiate()
    self.detailPane:addChild(self.expiryBehaviorCombo)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.expiryBehaviorCombo
    y = y + ROW_HEIGHT + 8

    ------------------------------------------------------------
    -- ROUND DURATION (Phase 4/5) -- a genuinely separate, round-
    -- scoped timer. NOT the same field as the event-wide Duration
    -- above -- a Round Timer definition (e.g. King of the Hill) needs
    -- this set, not the event-wide one, or its round will never
    -- expire on its own. See KIPN_EventTimerService.lua's header.
    ------------------------------------------------------------

    local roundDuration = formDefinition.roundDuration or {}

    self.roundDurationEnabledTick = ISTickBox:new(x, y, width, TICK_BOX_SIZE, "")
    self.roundDurationEnabledTick:initialise()
    self.roundDurationEnabledTick:instantiate()
    self.roundDurationEnabledTick:addOption("Round Duration enabled (required for Round Timer)")
    self.roundDurationEnabledTick.selected[1] = roundDuration.enabled == true
    self.detailPane:addChild(self.roundDurationEnabledTick)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.roundDurationEnabledTick
    y = y + self.roundDurationEnabledTick:getHeight() + 6

    local roundDurationSeconds = tonumber(roundDuration.durationSeconds) or 0
    local roundDurationHoursValue = math.floor(roundDurationSeconds / 3600)
    local roundDurationMinutesValue = math.floor((roundDurationSeconds % 3600) / 60)

    addLabel(self, x, y + 2, "Round Duration")

    self.roundDurationHoursEntry = ISTextEntryBox:new(tostring(roundDurationHoursValue), fieldX, y, durationEntryWidth, ROW_HEIGHT - 4)
    self.roundDurationHoursEntry:initialise()
    self.roundDurationHoursEntry:instantiate()
    if self.roundDurationHoursEntry.setOnlyNumbers then self.roundDurationHoursEntry:setOnlyNumbers(true) end
    self.detailPane:addChild(self.roundDurationHoursEntry)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.roundDurationHoursEntry

    addLabel(self, hoursLabelX, y + 2, "hours", 0.7, 0.7, 0.7)

    self.roundDurationMinutesEntry = ISTextEntryBox:new(tostring(roundDurationMinutesValue), minutesX, y, durationEntryWidth, ROW_HEIGHT - 4)
    self.roundDurationMinutesEntry:initialise()
    self.roundDurationMinutesEntry:instantiate()
    if self.roundDurationMinutesEntry.setOnlyNumbers then self.roundDurationMinutesEntry:setOnlyNumbers(true) end
    self.detailPane:addChild(self.roundDurationMinutesEntry)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.roundDurationMinutesEntry
    addLabel(self, minutesX + durationEntryWidth + unitGap, y + 2, "minutes", 0.7, 0.7, 0.7)
    y = y + ROW_HEIGHT + 8

    ------------------------------------------------------------
    -- OBJECTIVE TYPES (composable, fixed enum -- see file header)
    ------------------------------------------------------------

    y = addSectionHeader(self, self.detailPane, x, y, width, "Objectives")
    addLabel(self, x, y, "Objective Types")
    y = y + ROW_HEIGHT

    self.objectiveTypesTick, y = self:buildEnumTickBox(
        x, y, width, KIPN.Shared.EventObjectiveTypeOrder, KIPN.Shared.EventObjectiveTypeLabels, formDefinition.objectiveTypes,
        KIPN_EventScenarioAdminUI.onObjectiveTypesChanged
    )

    y = y + 6

    ------------------------------------------------------------
    -- STORY AND OBJECTIVES (Phase 5) -- authors
    -- KIPN_EventTriggerService.lua's ordered objectives/triggers. See
    -- TRIGGER_ACTIVATION_MODE_OPTIONS/TRIGGER_ACTION_TYPE_OPTIONS
    -- above for this pass's scope.
    ------------------------------------------------------------

    y = addSectionHeader(self, self.detailPane, x, y, width, "Story and Objectives")

    local objectives = formDefinition.objectives or {}

    if #objectives == 0 then
        addLabel(self, x, y, "(no objectives authored)", 0.7, 0.7, 0.7)
        y = y + ROW_HEIGHT
    else
        for objectiveIndex, objective in ipairs(objectives) do
            local objectiveLabel = tostring(objectiveIndex) .. ". " .. tostring(objective.name ~= "" and objective.name or objective.id)
                .. "  (" .. tostring(#(objective.triggers or {})) .. " trigger(s))"
            addLabel(self, x, y, objectiveLabel, 0.85, 0.9, 0.85)

            local removeObjectiveButton = ISButton:new(x + width - 80, y - 2, 80, ROW_HEIGHT, "Remove", self, KIPN_EventScenarioAdminUI.onRemoveObjective)
            removeObjectiveButton.internal = objectiveIndex
            removeObjectiveButton:initialise()
            removeObjectiveButton:instantiate()
            self.detailPane:addChild(removeObjectiveButton)
            self.fieldWidgets[#self.fieldWidgets + 1] = removeObjectiveButton
            y = y + ROW_HEIGHT + 2
        end
    end

    y = y + 4

    self.newObjectiveNameEntry = ISTextEntryBox:new("", x, y, width - 130, ROW_HEIGHT - 4)
    self.newObjectiveNameEntry:initialise()
    self.newObjectiveNameEntry:instantiate()
    self.detailPane:addChild(self.newObjectiveNameEntry)
    self.fieldWidgets[#self.fieldWidgets + 1] = self.newObjectiveNameEntry

    local addObjectiveButton = ISButton:new(x + width - 120, y, 120, ROW_HEIGHT, "Add Objective", self, KIPN_EventScenarioAdminUI.onAddObjective)
    addObjectiveButton:initialise()
    addObjectiveButton:instantiate()
    self.detailPane:addChild(addObjectiveButton)
    self.fieldWidgets[#self.fieldWidgets + 1] = addObjectiveButton
    y = y + ROW_HEIGHT + 10

    if #objectives > 0 then
        addLabel(self, x, y, "Add trigger to objective", 0.8, 0.85, 1)
        y = y + ROW_HEIGHT

        self.triggerObjectiveCombo = ISComboBox:new(x, y, width, ROW_HEIGHT, self, nil)
        for objectiveIndex, objective in ipairs(objectives) do
            self.triggerObjectiveCombo:addOptionWithData(
                tostring(objectiveIndex) .. ". " .. tostring(objective.name ~= "" and objective.name or objective.id),
                objectiveIndex
            )
        end
        self.triggerObjectiveCombo:setSelected(1)
        self.triggerObjectiveCombo:initialise()
        self.triggerObjectiveCombo:instantiate()
        self.detailPane:addChild(self.triggerObjectiveCombo)
        self.fieldWidgets[#self.fieldWidgets + 1] = self.triggerObjectiveCombo
        y = y + ROW_HEIGHT + 4

        local halfWidth = math.floor((width - 8) / 2)

        addLabel(self, x, y, "Activation")
        self.triggerActivationModeCombo = ISComboBox:new(x, y + ROW_HEIGHT - 2, halfWidth, ROW_HEIGHT, self, KIPN_EventScenarioAdminUI.onTriggerActivationModeChanged)
        for _, option in ipairs(TRIGGER_ACTIVATION_MODE_OPTIONS) do
            self.triggerActivationModeCombo:addOptionWithData(option.text, option.value)
        end
        self.triggerActivationModeCombo:setSelected(1)
        self.triggerActivationModeCombo:initialise()
        self.triggerActivationModeCombo:instantiate()
        self.detailPane:addChild(self.triggerActivationModeCombo)
        self.fieldWidgets[#self.fieldWidgets + 1] = self.triggerActivationModeCombo

        addLabel(self, x + halfWidth + 8, y, "Action")
        self.triggerActionTypeCombo = ISComboBox:new(x + halfWidth + 8, y + ROW_HEIGHT - 2, halfWidth, ROW_HEIGHT, self, nil)
        for _, option in ipairs(TRIGGER_ACTION_TYPE_OPTIONS) do
            self.triggerActionTypeCombo:addOptionWithData(option.text, option.value)
        end
        self.triggerActionTypeCombo:setSelected(1)
        self.triggerActionTypeCombo:initialise()
        self.triggerActionTypeCombo:instantiate()
        self.detailPane:addChild(self.triggerActionTypeCombo)
        self.fieldWidgets[#self.fieldWidgets + 1] = self.triggerActionTypeCombo
        y = y + ROW_HEIGHT + ROW_HEIGHT

        local selectedActivationMode = getComboData(self.triggerActivationModeCombo)

        if selectedActivationMode == "PROXIMITY" then
            addLabel(self, x, y, "Hotspot")
            self.triggerHotspotCombo = ISComboBox:new(fieldX, y - 2, fieldWidth, ROW_HEIGHT, self, nil)
            local definitionHotspots = formDefinition.hotspots or definition.hotspots or {}
            if #definitionHotspots == 0 then
                self.triggerHotspotCombo:addOptionWithData("(no hotspots drawn)", nil)
            else
                for _, hotspot in ipairs(definitionHotspots) do
                    local label = tostring(hotspot.type or "HOTSPOT")
                    if hotspot.label and hotspot.label ~= "" then label = label .. " / " .. tostring(hotspot.label) end
                    self.triggerHotspotCombo:addOptionWithData(label, hotspot.id)
                end
            end
            self.triggerHotspotCombo:setSelected(1)
            self.triggerHotspotCombo:initialise()
            self.triggerHotspotCombo:instantiate()
            self.detailPane:addChild(self.triggerHotspotCombo)
            self.fieldWidgets[#self.fieldWidgets + 1] = self.triggerHotspotCombo
            y = y + ROW_HEIGHT + 4
        end

        addLabel(self, x, y, "Action Param (text, or a count for zombies)")
        self.triggerActionParamEntry = ISTextEntryBox:new("", fieldX, y - 2, fieldWidth, ROW_HEIGHT - 4)
        self.triggerActionParamEntry:initialise()
        self.triggerActionParamEntry:instantiate()
        self.detailPane:addChild(self.triggerActionParamEntry)
        self.fieldWidgets[#self.fieldWidgets + 1] = self.triggerActionParamEntry
        y = y + ROW_HEIGHT + 4

        local addTriggerButton = ISButton:new(x, y, width, ROW_HEIGHT + 2, "Add Trigger", self, KIPN_EventScenarioAdminUI.onAddTrigger)
        addTriggerButton:initialise()
        addTriggerButton:instantiate()
        self.detailPane:addChild(addTriggerButton)
        self.fieldWidgets[#self.fieldWidgets + 1] = addTriggerButton
        y = y + ROW_HEIGHT + 2 + 8
    end

    y = y + 4

    ------------------------------------------------------------
    -- OBJECTIVE NOTES (free-text goal checklist shown to
    -- participants -- distinct from Objective Types above)
    ------------------------------------------------------------

    textY = addSectionHeader(self, self.textPane, textX, textY, textWidth, "Objective Notes", 0.7, 0.8, 1)
    addLabel(self, textX, textY, "Shown to participants", 0.8, 0.8, 0.8, self.textPane)
    textY = textY + ROW_HEIGHT

    local objectiveNotes = formDefinition.objectiveNotes or {}
    local objectiveNoteRowCount = math.min(
        OBJECTIVES_MAX_ROWS,
        math.max(1, #objectiveNotes + 1)
    )

    for rowIndex = 1, objectiveNoteRowCount do
        local note = objectiveNotes[rowIndex]

        self:addObjectiveNoteEntry(
            rowIndex,
            note and tostring(note.text or "") or "",
            textX,
            textY,
            textWidth
        )

        textY = textY + ROW_HEIGHT + 2
    end

    textY = textY + 10
    self.objectiveNotesFollowingY = textY

    ------------------------------------------------------------
    -- OUTCOME TYPES (composable, fixed enum -- see file header)
    ------------------------------------------------------------

    y = addSectionHeader(self, self.detailPane, x, y, width, "Outcomes and Conditions")
    addLabel(self, x, y, "Outcome Types")
    y = y + ROW_HEIGHT

    self.outcomeTypesTick, y = self:buildEnumTickBox(
        x, y, width, KIPN.Shared.EventOutcomeTypeOrder, KIPN.Shared.EventOutcomeTypeLabels, formDefinition.outcomeTypes
    )

    y = y + 6

    ------------------------------------------------------------
    -- WIN / FAIL CONDITIONS (extensible per-eventType registry --
    -- the one part of this schema that IS mechanically evaluated,
    -- via KIPN_EventObjectiveRegistry.lua/KIPN_ZombieDirector.lua)
    ------------------------------------------------------------

    self.winConditionsEnabledTick, y = self:buildBooleanTickBox(
        x, y, width, "Enable automatic win conditions", #(formDefinition.winConditions or {}) > 0
    )

    self.winConditionTick, y = self:buildConditionTickBox(x, y, width, self.availableWinConditions, formDefinition.winConditions, "win")

    y = y + 6

    self.failConditionsEnabledTick, y = self:buildBooleanTickBox(
        x, y, width, "Enable automatic fail conditions", #(formDefinition.failConditions or {}) > 0
    )

    self.failConditionTick, y = self:buildConditionTickBox(x, y, width, self.availableFailConditions, formDefinition.failConditions, "fail")

    y = y + 8

    ------------------------------------------------------------
    -- NARRATIVE
    ------------------------------------------------------------

    local narrative = formDefinition.narrative or {}

    textY = addSectionHeader(self, self.textPane, textX, textY, textWidth, "Narrative", 0.7, 0.8, 1)

    addLabel(self, textX, textY, "Briefing (shown on Announce)", nil, nil, nil, self.textPane)
    textY = textY + ROW_HEIGHT
    self.narrativeBriefingEntry = addMultilineEntry(
        self, narrative.briefing, textX, textY, textWidth, self.textPane
    )
    textY = textY + NARRATIVE_ENTRY_HEIGHT + 4

    addLabel(self, textX, textY, "Win text", nil, nil, nil, self.textPane)
    textY = textY + ROW_HEIGHT
    self.narrativeWinEntry = addMultilineEntry(
        self, narrative.winText, textX, textY, textWidth, self.textPane
    )
    textY = textY + NARRATIVE_ENTRY_HEIGHT + 4

    addLabel(self, textX, textY, "Fail text", nil, nil, nil, self.textPane)
    textY = textY + ROW_HEIGHT
    self.narrativeFailEntry = addMultilineEntry(
        self, narrative.failText, textX, textY, textWidth, self.textPane
    )
    textY = textY + NARRATIVE_ENTRY_HEIGHT + 12

    ------------------------------------------------------------
    -- REWARDS
    ------------------------------------------------------------

    textY = addSectionHeader(self, self.textPane, textX, textY, textWidth, "Reward Items Granted", 0.7, 0.8, 1)

    addLabel(self, textX, textY, "Delivery Method", nil, nil, nil, self.textPane)
    textY = textY + ROW_HEIGHT
    self.rewardDeliveryCombo = ISComboBox:new(textX, textY, textWidth, ROW_HEIGHT, self, nil)
    local rewardDeliverySelectedIndex = 1
    for index, deliveryMethod in ipairs(KIPN.Shared.EventRewardDeliveryMethodOrder or { "ADMIN_DELIVERY" }) do
        self.rewardDeliveryCombo:addOptionWithData(
            (KIPN.Shared.EventRewardDeliveryMethodLabels or {})[deliveryMethod] or deliveryMethod,
            deliveryMethod
        )
        if (formDefinition.rewardDeliveryMethod or "ADMIN_DELIVERY") == deliveryMethod then
            rewardDeliverySelectedIndex = index
        end
    end
    self.rewardDeliveryCombo:setSelected(rewardDeliverySelectedIndex)
    self.rewardDeliveryCombo:initialise()
    self.rewardDeliveryCombo:instantiate()
    trackWidget(self, self.textPane, self.rewardDeliveryCombo)
    textY = textY + ROW_HEIGHT + 4

    local rewardsLabel = addWrappedText(
        self,
        textX,
        textY,
        textWidth,
        "Only a WIN awards prizes. Admin Delivery records a fulfillment task; PO Box Delivery queues a parcel, or holds it in escrow until the winner claims a PO Box.",
        self.textPane
    )
    textY = textY + math.max(ROW_HEIGHT, rewardsLabel:getHeight())

    local rewardItems = (formDefinition.rewards and formDefinition.rewards.items) or {}

    local rewardRowCount = math.min(REWARD_MAX_ROWS, math.max(1, #rewardItems + 1))
    for rowIndex = 1, rewardRowCount do
        local row = rewardItems[rowIndex]

        self:addRewardRow(rowIndex, row, textX, textY, textWidth)

        textY = textY + ROW_HEIGHT + 2
    end

    textY = textY + 8
    self.rewardFollowingY = textY

    textY = addSectionHeader(self, self.textPane, textX, textY, textWidth, "Prize Fulfillment", 0.7, 0.8, 1)
    local refreshAwardsButton = ISButton:new(
        textX, textY, textWidth, ROW_HEIGHT + 2,
        "Refresh Prize Delivery Queue", self, KIPN_EventScenarioAdminUI.onRefreshRewardAwards
    )
    refreshAwardsButton:initialise()
    refreshAwardsButton:instantiate()
    trackWidget(self, self.textPane, refreshAwardsButton)
    textY = textY + ROW_HEIGHT + 6

    local visibleAwards = 0
    for _, award in ipairs(self.rewardAwards or {}) do
        if award.status ~= "ADMIN_DELIVERED" and visibleAwards < 8 then
            visibleAwards = visibleAwards + 1
            local itemParts = {}
            for index, item in ipairs(award.items or {}) do
                if index > 3 then itemParts[#itemParts + 1] = "..." break end
                itemParts[#itemParts + 1] = tostring(item.count or 1) .. "x "
                    .. tostring(item.displayName or item.itemFullType or "item")
            end
            local line = tostring(award.recipientUsername or "Unknown")
                .. " | " .. tostring(award.status or "UNKNOWN")
                .. " | " .. table.concat(itemParts, ", ")
            addLabel(self, textX, textY, line, 0.8, 0.85, 1, self.textPane)

            if award.status == "AWAITING_ADMIN_DELIVERY" then
                local markButton = ISButton:new(
                    textX + textWidth - 130, textY, 130, ROW_HEIGHT,
                    "Mark Delivered", self, KIPN_EventScenarioAdminUI.onMarkRewardDelivered
                )
                markButton.internal = award.id
                markButton:initialise()
                markButton:instantiate()
                trackWidget(self, self.textPane, markButton)
            end
            textY = textY + ROW_HEIGHT + 2
        end
    end

    if visibleAwards == 0 then
        addLabel(self, textX, textY, "No outstanding prize records loaded.", 0.7, 0.7, 0.7, self.textPane)
        textY = textY + ROW_HEIGHT + 2
    end

    textY = textY + 6

    -- Phase 5: Delete Event moved to the LEFT (list) pane's Lifecycle
    -- Actions section, alongside Validate/Announce/etc. -- see
    -- rebuildDefinitionsList(). Save Definition stays here, next to
    -- everything else this Inspector pane already surfaces about the
    -- selected definition.
    textY = addSectionHeader(self, self.textPane, textX, textY, textWidth, "Definition Actions", 0.7, 0.8, 1)

    local saveButton = ISButton:new(textX, textY, 160, ROW_HEIGHT + 2, "Save Definition", self, KIPN_EventScenarioAdminUI.onSaveDefinition)
    saveButton:initialise()
    saveButton:instantiate()
    trackWidget(self, self.textPane, saveButton)
    textY = textY + ROW_HEIGHT + 14

    ------------------------------------------------------------
    -- PARTICIPANTS AND TEAMS (Phase 5: moved to the RIGHT
    -- (Inspector) pane -- roster/team assignment is contextual state
    -- about the selected definition, not mechanical configuration)
    ------------------------------------------------------------

    textY = addSectionHeader(self, self.textPane, textX, textY, textWidth, "Participants and Teams", 0.7, 0.8, 1)
    addLabel(self, textX, textY, "Online players", nil, nil, nil, self.textPane)

    local refreshPlayersButton = ISButton:new(textX + textWidth - 84, textY - 2, 84, ROW_HEIGHT, "Refresh", self, KIPN_EventScenarioAdminUI.onRefreshOnlinePlayers)
    refreshPlayersButton:initialise()
    refreshPlayersButton:instantiate()
    trackWidget(self, self.textPane, refreshPlayersButton)
    textY = textY + ROW_HEIGHT

    self.participantsTick = ISTickBox:new(textX, textY, textWidth, TICK_BOX_SIZE, "")
    self.participantsTick:initialise()
    self.participantsTick:instantiate()

    if #self.onlinePlayers == 0 then
        self.participantsTick:addOption("(no players online -- click Refresh)")
    else
        for index, onlinePlayer in ipairs(self.onlinePlayers) do
            self.participantsTick:addOption(onlinePlayer.username)
            self.participantsTick.selected[index] = formDefinition.participants and formDefinition.participants[onlinePlayer.username] == true
        end
    end

    trackWidget(self, self.textPane, self.participantsTick)
    textY = textY + self.participantsTick:getHeight() + 6

    local saveRosterWidth = math.min(160, math.floor((textWidth - 10) * 0.4))
    local saveRosterButton = ISButton:new(textX, textY, saveRosterWidth, ROW_HEIGHT, "Save Roster", self, KIPN_EventScenarioAdminUI.onSaveParticipants)
    saveRosterButton:initialise()
    saveRosterButton:instantiate()
    trackWidget(self, self.textPane, saveRosterButton)

    local teleportButton = ISButton:new(textX + saveRosterWidth + 10, textY, textWidth - saveRosterWidth - 10, ROW_HEIGHT, "Teleport To Event Start", self, KIPN_EventScenarioAdminUI.onTeleportParticipants)
    teleportButton:initialise()
    teleportButton:instantiate()
    trackWidget(self, self.textPane, teleportButton)
    textY = textY + ROW_HEIGHT + 10

    -- Team roster: only meaningful for modes that use teams (see
    -- KIPN.Shared.EventModeMetadata) -- a no-op section for anything
    -- else, matching "only show settings relevant to the selected
    -- mode."
    local modeMetadata = formDefinition.mode and (KIPN.Shared.EventModeMetadata or {})[formDefinition.mode]

    if modeMetadata and modeMetadata.usesTeams then
        addLabel(self, textX, textY, "Team Count", nil, nil, nil, self.textPane)
        self.teamCountEntry = ISTextEntryBox:new(tostring(#(formDefinition.teams or {}) > 0 and #formDefinition.teams or 2), textX + 100, textY - 2, 60, ROW_HEIGHT - 4)
        self.teamCountEntry:initialise()
        self.teamCountEntry:instantiate()
        if self.teamCountEntry.setOnlyNumbers then self.teamCountEntry:setOnlyNumbers(true) end
        trackWidget(self, self.textPane, self.teamCountEntry)

        local setTeamsButton = ISButton:new(textX + 170, textY - 2, textWidth - 170, ROW_HEIGHT, "Set Teams (rebalances roster)", self, KIPN_EventScenarioAdminUI.onSetTeamCount)
        setTeamsButton:initialise()
        setTeamsButton:instantiate()
        trackWidget(self, self.textPane, setTeamsButton)
        textY = textY + ROW_HEIGHT + 6

        local teams = definition.teams or {}

        if #teams == 0 then
            addLabel(self, textX, textY, "No teams created yet.", 0.7, 0.7, 0.7, self.textPane)
            textY = textY + ROW_HEIGHT
        else
            for _, team in ipairs(teams) do
                local color = team.color or { r = 0.8, g = 0.8, b = 0.8 }
                local memberNames = {}
                for username in pairs(team.members or {}) do memberNames[#memberNames + 1] = username end
                table.sort(memberNames)
                local memberList = #memberNames > 0 and table.concat(memberNames, ", ") or "(no members)"

                addLabel(self, textX, textY, tostring(team.name) .. ": " .. memberList, color.r, color.g, color.b, self.textPane)
                textY = textY + ROW_HEIGHT
            end
        end

        addLabel(self, textX, textY, "Reassign player to team", nil, nil, nil, self.textPane)
        textY = textY + ROW_HEIGHT

        self.teamReassignPlayerCombo = ISComboBox:new(textX, textY, math.floor(textWidth * 0.5) - 4, ROW_HEIGHT, self, nil)
        local rosterUsernames = {}
        for username in pairs(definition.participants or {}) do rosterUsernames[#rosterUsernames + 1] = username end
        table.sort(rosterUsernames)
        if #rosterUsernames == 0 then
            self.teamReassignPlayerCombo:addOptionWithData("(no participants)", nil)
        else
            for _, username in ipairs(rosterUsernames) do
                self.teamReassignPlayerCombo:addOptionWithData(username, username)
            end
        end
        self.teamReassignPlayerCombo:setSelected(1)
        self.teamReassignPlayerCombo:initialise()
        self.teamReassignPlayerCombo:instantiate()
        trackWidget(self, self.textPane, self.teamReassignPlayerCombo)

        self.teamReassignTeamCombo = ISComboBox:new(textX + math.floor(textWidth * 0.5), textY, math.ceil(textWidth * 0.5) - 4, ROW_HEIGHT, self, nil)
        if #teams == 0 then
            self.teamReassignTeamCombo:addOptionWithData("(no teams)", nil)
        else
            for _, team in ipairs(teams) do
                self.teamReassignTeamCombo:addOptionWithData(team.name, team.id)
            end
        end
        self.teamReassignTeamCombo:setSelected(1)
        self.teamReassignTeamCombo:initialise()
        self.teamReassignTeamCombo:instantiate()
        trackWidget(self, self.textPane, self.teamReassignTeamCombo)
        textY = textY + ROW_HEIGHT + 4

        local reassignButton = ISButton:new(textX, textY, textWidth, ROW_HEIGHT, "Assign Player To Team", self, KIPN_EventScenarioAdminUI.onAssignPlayerTeam)
        reassignButton:initialise()
        reassignButton:instantiate()
        trackWidget(self, self.textPane, reassignButton)
        textY = textY + ROW_HEIGHT + 6
    end

    textY = textY + 8

    ------------------------------------------------------------
    -- LIVE EVENT SUMMARY (Phase 5: moved to the RIGHT (Inspector)
    -- pane -- this is runtime/Director state, not editable
    -- configuration. Per-mode live control buttons/sliders (Zombie
    -- Director's spawn/difficulty controls, etc.) still render here
    -- too -- see KIPN_EventDirectorControlUI.lua. The persistent,
    -- mode-independent Trigger Alarm control lives in the separate
    -- KIPN_EventDirectorPanel.lua floating panel, not here -- see
    -- that file's ALARM section.
    ------------------------------------------------------------

    local currentStatus = definition.status or (self.status and self.status.status)

    if currentStatus == "ACTIVE" and self.status then
        textY = addSectionHeader(self, self.textPane, textX, textY, textWidth, "Live Event", 0.7, 0.8, 1)

        if self.status.round then
            addLabel(
                self, textX, textY,
                "Round " .. tostring(self.status.round.current or 1) .. "/" .. tostring(self.status.round.maximum or 1)
                    .. " (" .. tostring(self.status.round.state or "ACTIVE") .. ")",
                0.8, 0.85, 1, self.textPane
            )
            textY = textY + ROW_HEIGHT
        end

        if self.status.controls then
            local built = KIPN_EventDirectorControlUI.BuildWidgets(self.textPane, textX, textY, textWidth, self.status.controls, function(controlId, params)
                self:onFireControl(controlId, params)
            end)

            for _, widget in ipairs(built.widgets) do
                widget.kipnContainerPane = self.textPane
                self.fieldWidgets[#self.fieldWidgets + 1] = widget
            end

            textY = textY + built.height
        end

        textY = textY + 8
    end

    self.detailPane:setScrollHeight(math.max(y + DETAIL_PAD, self.detailPane:getHeight()))
    self.textPaneContentHeight = textY + DETAIL_PAD
    self.textPane:setScrollHeight(math.max(self.textPaneContentHeight, self.textPane:getHeight()))
    self.renderedDefinitionId = definition.id
    self._buildingForm = false
end

------------------------------------------------------------
-- CONDITION TICKBOX HELPER (server-fetched per-eventType list)
------------------------------------------------------------

local function conditionMatchesObjectives(condition, selectedObjectives)
    local supported = condition.objectiveTypes or {}

    if #supported == 0 or #selectedObjectives == 0 then
        return true
    end

    local selectedSet = {}
    for _, objectiveType in ipairs(selectedObjectives) do
        selectedSet[objectiveType] = true
    end

    for _, objectiveType in ipairs(supported) do
        if selectedSet[objectiveType] then
            return true
        end
    end

    return false
end

-- One compact ISTickBox + wrapped label per condition, same rationale
-- as buildEnumTickBox above: vanilla ISTickBox never wraps or clips
-- option text, so a single tickbox with one addOption() per condition
-- let long server-fetched condition labels bleed into the row below.
function KIPN_EventScenarioAdminUI:buildConditionTickBox(x, y, width, available, selectedConditions, conditionKind)
    local selectedById = {}

    for _, selected in ipairs(selectedConditions or {}) do
        selectedById[selected.conditionId] = selected
    end

    local selectedObjectives = collectEnumSelection(self.objectiveTypesTick)
    local filtered = {}

    for _, condition in ipairs(available or {}) do
        if conditionMatchesObjectives(condition, selectedObjectives) then
            filtered[#filtered + 1] = condition
        end
    end

    -- Metadata arrives asynchronously. Keep already-saved conditions
    -- visible until it does so that the metadata response cannot erase
    -- them from the editor draft during its repaint.
    if #(available or {}) == 0 then
        for _, selected in ipairs(selectedConditions or {}) do
            filtered[#filtered + 1] = {
                id = selected.conditionId,
                label = selected.conditionId,
                defaultParams = selected.params or {},
                paramFields = {},
            }
        end
    end

    local paramsById = {}
    for conditionId, selected in pairs(selectedById) do
        paramsById[conditionId] = selected.params or {}
    end

    local rowTicks = {}

    if #filtered == 0 then
        local label = addWrappedText(
            self, x + TICK_BOX_SIZE + 8, y, math.max(40, width - TICK_BOX_SIZE - 8),
            "(no suggested conditions for the selected objectives)"
        )
        y = y + label:getHeight() + 4
    else
        for _, condition in ipairs(filtered) do
            local tick = ISTickBox:new(x, y, TICK_BOX_SIZE, TICK_BOX_SIZE, "")
            tick:initialise()
            tick:instantiate()
            tick:addOption("")
            tick.selected[1] = selectedById[condition.id] ~= nil
            tick.kipnConditionId = condition.id
            self.detailPane:addChild(tick)
            self.fieldWidgets[#self.fieldWidgets + 1] = tick
            rowTicks[#rowTicks + 1] = tick

            local label = addWrappedText(
                self,
                x + TICK_BOX_SIZE + 8,
                y,
                math.max(40, width - TICK_BOX_SIZE - 8),
                condition.label or condition.id
            )

            y = y + math.max(tick:getHeight(), label:getHeight()) + 4

            local selected = selectedById[condition.id]
            local selectedParams = selected and selected.params or {}

            for _, field in ipairs(condition.paramFields or {}) do
                local defaultValue = selectedParams[field.key]
                if defaultValue == nil then
                    defaultValue = (condition.defaultParams or {})[field.key]
                end

                addLabel(self, x + 18, y, (field.label or field.key) .. ":", 0.75, 0.75, 0.75)

                local entryWidth = math.min(100, math.max(60, math.floor(width * 0.28)))
                local entry = ISTextEntryBox:new(
                    defaultValue ~= nil and tostring(defaultValue) or "",
                    x + width - entryWidth,
                    y,
                    entryWidth,
                    ROW_HEIGHT - 4
                )
                entry:initialise()
                entry:instantiate()
                if (field.type == "integer" or field.type == "number") and entry.setOnlyNumbers then
                    entry:setOnlyNumbers(true)
                end
                entry.kipnConditionKind = conditionKind
                entry.kipnConditionId = condition.id
                entry.kipnConditionParam = field.key
                entry.kipnConditionParamType = field.type
                entry.kipnConditionParamMin = field.min
                entry.kipnConditionParamMax = field.max
                trackWidget(self, self.detailPane, entry)
                y = y + ROW_HEIGHT + 2
            end
        end
    end

    local conditionList = {
        kind = conditionKind,
        ticks = rowTicks,
        paramsById = paramsById,
    }

    return conditionList, y + 4
end

local function collectSelectedConditions(conditionList, fieldWidgets)
    local result = {}

    if not conditionList or not conditionList.ticks then
        return result
    end

    for _, tick in ipairs(conditionList.ticks) do
        if tick.selected[1] then
            local conditionId = tick.kipnConditionId
            local params = {}

            for key, value in pairs(
                (conditionList.paramsById and conditionList.paramsById[conditionId]) or {}
            ) do
                params[key] = value
            end

            for _, widget in ipairs(fieldWidgets or {}) do
                if widget.kipnConditionKind == conditionList.kind
                    and widget.kipnConditionId == conditionId
                    and widget.kipnConditionParam then
                    local rawValue = widget:getText()
                    local value = rawValue

                    if widget.kipnConditionParamType == "integer" then
                        value = math.floor(tonumber(rawValue) or 0)
                    elseif widget.kipnConditionParamType == "number" then
                        value = tonumber(rawValue) or 0
                    end

                    if type(value) == "number" and widget.kipnConditionParamMin ~= nil then
                        value = math.max(tonumber(widget.kipnConditionParamMin) or value, value)
                    end
                    if type(value) == "number" and widget.kipnConditionParamMax ~= nil then
                        value = math.min(tonumber(widget.kipnConditionParamMax) or value, value)
                    end

                    params[widget.kipnConditionParam] = value
                end
            end

            result[#result + 1] = { conditionId = conditionId, params = params }
        end
    end

    return result
end

------------------------------------------------------------
-- ACTIONS
------------------------------------------------------------

function KIPN_EventScenarioAdminUI:onCreateDefinition()
    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_CREATE_DEFINITION, {
        name = "New Event",
        eventType = INTERNAL_EVENT_TYPE,
    })

    self.infoText = "Creating event..."
end

local function collectRewardItems(fieldWidgets)
    local rows = {}

    for _, widget in ipairs(fieldWidgets) do
        if widget.kipnRewardField and widget.kipnRewardRow then
            rows[widget.kipnRewardRow] = rows[widget.kipnRewardRow] or {}
            rows[widget.kipnRewardRow][widget.kipnRewardField] = widget:getText()
        end
    end

    local items = {}

    for rowIndex = 1, REWARD_MAX_ROWS do
        local row = rows[rowIndex]
        local itemFullType = row and row.itemFullType and row.itemFullType:match("^%s*(.-)%s*$") or ""

        if itemFullType ~= "" then
            items[#items + 1] = {
                itemFullType = itemFullType,
                count = tonumber(row.count) or 1,
            }
        end
    end

    return items
end

local function collectObjectiveNotes(fieldWidgets)
    local rows = {}

    for _, widget in ipairs(fieldWidgets) do
        if widget.kipnObjectiveNoteRow then
            rows[widget.kipnObjectiveNoteRow] = widget:getText()
        end
    end

    local notes = {}

    for rowIndex = 1, OBJECTIVES_MAX_ROWS do
        local text = rows[rowIndex] and rows[rowIndex]:match("^%s*(.-)%s*$") or ""

        if text ~= "" then
            notes[#notes + 1] = { text = text }
        end
    end

    return notes
end

local function getComboData(combo)
    local option = combo and combo.options and combo.options[combo.selected]
    return option and option.data
end

local function findDefinitionById(panel, definitionId)
    for _, definition in ipairs(panel.definitions or {}) do
        if definition.id == definitionId then
            return definition
        end
    end

    return nil
end

local function collectParticipantMap(panel, existingParticipants)
    local participants = {}

    for username, selected in pairs(existingParticipants or {}) do
        if selected == true then
            participants[username] = true
        end
    end

    if panel.participantsTick then
        for index, onlinePlayer in ipairs(panel.onlinePlayers or {}) do
            participants[onlinePlayer.username] = panel.participantsTick.selected[index] == true
        end
    end

    return participants
end

function KIPN_EventScenarioAdminUI:collectCurrentDefinitionPayload(definition)
    if not definition or not self.nameEntry or not self.timerTypeCombo then
        return nil
    end

    local eventType = definition.eventType or INTERNAL_EVENT_TYPE

    local weatherPreset = nil
    if self.weatherEnabledTick.selected[1] then
        weatherPreset = getComboData(self.weatherCombo)
    end

    local durationHours = math.max(0, math.floor(tonumber(self.durationHoursEntry:getText()) or 0))
    local durationMinutes = math.max(0, math.floor(tonumber(self.durationMinutesEntry:getText()) or 0))
    local winConditions = {}
    local failConditions = {}

    if self.winConditionsEnabledTick and self.winConditionsEnabledTick.selected[1] then
        winConditions = collectSelectedConditions(self.winConditionTick, self.fieldWidgets)
    end
    if self.failConditionsEnabledTick and self.failConditionsEnabledTick.selected[1] then
        failConditions = collectSelectedConditions(self.failConditionTick, self.fieldWidgets)
    end

    local roundDurationHours = math.max(0, math.floor(tonumber(self.roundDurationHoursEntry and self.roundDurationHoursEntry:getText()) or 0))
    local roundDurationMinutes = math.max(0, math.floor(tonumber(self.roundDurationMinutesEntry and self.roundDurationMinutesEntry:getText()) or 0))

    return {
        id = definition.id,
        name = self.nameEntry:getText(),
        eventType = eventType,
        mode = getComboData(self.modeCombo),
        variant = self.variantCombo and getComboData(self.variantCombo) or nil,
        modifiers = { NAKED_AND_AFRAID = self.nakedAndAfraidTick and self.nakedAndAfraidTick.selected[1] == true or false },
        captureConfig = {
            flagItemFullType = self.captureFlagItemEntry and self.captureFlagItemEntry:getText() or "",
            autoReturnSeconds = self.captureAutoReturnEntry and tonumber(self.captureAutoReturnEntry:getText()) or 90,
        },
        scenarioPresetId = getComboData(self.scenarioPresetCombo),
        scopeType = getComboData(self.scopeTypeCombo),
        maxRounds = math.max(1, math.min(10, math.floor(tonumber(self.maxRoundsEntry:getText()) or 1))),
        spawnRules = {
            baseSpawnRadius = tonumber(self.spawnRadiusEntry:getText()) or 40,
            escalationEnabled = self.escalationTick.selected[1] and true or false,
        },
        directorType = getComboData(self.directorTypeCombo),
        zombieTheme = { themeId = getComboData(self.zombieThemeCombo) or "RANDOM" },
        environment = {
            timeOfDay = getComboData(self.timeOfDayCombo),
            weatherPreset = weatherPreset,
        },
        ruleType = getComboData(self.ruleTypeCombo),
        combatRules = {
            allowLeaveZone = self.allowLeaveTick.selected[1] and true or false,
            pvpAllowedInZone = self.pvpAllowedTick.selected[1] and true or false,
        },
        timerType = getComboData(self.timerTypeCombo),
        duration = {
            enabled = self.durationEnabledTick.selected[1] and true or false,
            durationSeconds = (durationHours * 3600) + (durationMinutes * 60),
            expiryBehavior = getComboData(self.expiryBehaviorCombo) or "WIN",
        },
        roundDuration = {
            enabled = self.roundDurationEnabledTick and self.roundDurationEnabledTick.selected[1] == true or false,
            durationSeconds = (roundDurationHours * 3600) + (roundDurationMinutes * 60),
        },
        objectiveTypes = collectEnumSelection(self.objectiveTypesTick),
        -- Phase 5: the ordered Story/Objectives array is edited
        -- structurally (Add/Remove Objective, Add Trigger), not
        -- through per-keystroke widgets like the fields above -- see
        -- onAddObjective()/onRemoveObjective()/onAddTrigger(), which
        -- mutate the draft directly. Read whatever the draft already
        -- holds rather than the last-saved server copy.
        objectives = (self.editorDrafts[definition.id] and self.editorDrafts[definition.id].objectives) or definition.objectives or {},
        objectiveNotes = collectObjectiveNotes(self.fieldWidgets),
        outcomeTypes = collectEnumSelection(self.outcomeTypesTick),
        winConditions = winConditions,
        failConditions = failConditions,
        rewardDeliveryMethod = getComboData(self.rewardDeliveryCombo) or "ADMIN_DELIVERY",
        rewardItems = collectRewardItems(self.fieldWidgets),
        narrative = {
            briefing = self.narrativeBriefingEntry:getText(),
            winText = self.narrativeWinEntry:getText(),
            failText = self.narrativeFailEntry:getText(),
        },
    }
end

function KIPN_EventScenarioAdminUI:captureCurrentDraft()
    local definitionId = self.renderedDefinitionId
    local definition = definitionId and findDefinitionById(self, definitionId)
    local payload = definition and self:collectCurrentDefinitionPayload(definition)

    if not payload then
        return nil
    end

    local previousDraft = self.editorDrafts[definitionId]
    local participants = collectParticipantMap(
        self,
        (previousDraft and previousDraft.participants) or definition.participants
    )

    local draft = {
        id = definition.id,
        name = payload.name,
        status = definition.status,
        eventType = payload.eventType,
        mode = payload.mode,
        variant = payload.variant,
        modifiers = payload.modifiers,
        captureConfig = payload.captureConfig,
        migrationStatus = definition.migrationStatus,
        legacyPresetId = definition.legacyPresetId,
        teams = definition.teams,
        scenarioPresetId = payload.scenarioPresetId,
        scopeType = payload.scopeType,
        maxRounds = payload.maxRounds,
        hotspots = definition.hotspots or {},
        zoneId = definition.zoneId,
        spawnRules = payload.spawnRules,
        directorType = payload.directorType,
        zombieTheme = payload.zombieTheme,
        environment = payload.environment,
        ruleType = payload.ruleType,
        combatRules = payload.combatRules,
        timerType = payload.timerType,
        duration = payload.duration,
        roundDuration = payload.roundDuration,
        objectiveTypes = payload.objectiveTypes,
        objectives = payload.objectives,
        objectiveNotes = payload.objectiveNotes,
        outcomeTypes = payload.outcomeTypes,
        winConditions = payload.winConditions,
        failConditions = payload.failConditions,
        rewards = { items = payload.rewardItems },
        rewardDeliveryMethod = payload.rewardDeliveryMethod,
        narrative = payload.narrative,
        participants = participants,
    }

    self.editorDrafts[definitionId] = draft
    return draft, payload
end

function KIPN_EventScenarioAdminUI:onObjectiveTypesChanged()
    self:captureCurrentDraft()
    self:rebuildRightPanel()
end

-- Rebuilds so mode-conditional sections (Extraction Variant, the
-- Teams/Roles roster in the Inspector pane) show/hide immediately --
-- same captureCurrentDraft()+rebuildRightPanel() pattern as
-- onObjectiveTypesChanged() above.
function KIPN_EventScenarioAdminUI:onModeChanged()
    self:captureCurrentDraft()
    self:rebuildRightPanel()
end

------------------------------------------------------------
-- STORY AND OBJECTIVES (Phase 5) -- structural edits (add/remove an
-- objective, add a trigger) mutate the draft directly rather than
-- going through per-keystroke widget state, then rebuild. See
-- collectCurrentDefinitionPayload()'s objectives field for how this
-- reaches the server on Save.
------------------------------------------------------------

function KIPN_EventScenarioAdminUI:onAddObjective()
    local definition = self:getSelectedDefinition()

    if not definition or not self.newObjectiveNameEntry then
        return
    end

    local name = tostring(self.newObjectiveNameEntry:getText() or ""):match("^%s*(.-)%s*$")
    local draft = self:captureCurrentDraft()

    if not draft then
        return
    end

    draft.objectives = draft.objectives or {}
    draft.objectives[#draft.objectives + 1] = {
        id = "objective_" .. tostring(#draft.objectives + 1) .. "_" .. tostring(ZombRand(100000)),
        name = name,
        triggers = {},
    }

    self:rebuildRightPanel()
end

function KIPN_EventScenarioAdminUI:onRemoveObjective(button)
    local definition = self:getSelectedDefinition()
    local index = button and button.internal

    if not definition or not index then
        return
    end

    local draft = self:captureCurrentDraft()

    if not draft or not draft.objectives then
        return
    end

    table.remove(draft.objectives, index)

    self:rebuildRightPanel()
end

-- Rebuilds so the hotspot picker only appears for PROXIMITY --
-- captureCurrentDraft() happens inside rebuildRightPanel() itself, so
-- in-progress typing elsewhere in the form (e.g. the new-objective
-- name entry) is preserved, same as onTriggerActivationModeChanged's
-- sibling handlers above.
function KIPN_EventScenarioAdminUI:onTriggerActivationModeChanged()
    self:rebuildRightPanel()
end

function KIPN_EventScenarioAdminUI:onAddTrigger()
    local definition = self:getSelectedDefinition()

    if not definition or not self.triggerObjectiveCombo then
        return
    end

    local objectiveIndex = getComboData(self.triggerObjectiveCombo)
    local activationMode = getComboData(self.triggerActivationModeCombo)
    local actionType = getComboData(self.triggerActionTypeCombo)
    local hotspotId = self.triggerHotspotCombo and getComboData(self.triggerHotspotCombo)
    local paramText = self.triggerActionParamEntry
        and tostring(self.triggerActionParamEntry:getText() or ""):match("^%s*(.-)%s*$")
        or ""

    if not objectiveIndex or not activationMode or not actionType then
        self.infoText = "Select an objective, activation mode, and action first."
        return
    end

    if activationMode == "PROXIMITY" and not hotspotId then
        self.infoText = "Proximity triggers need a hotspot -- draw one first."
        return
    end

    local params = {}
    if actionType == "ANNOUNCEMENT" or actionType == "PRIVATE_HINT" then
        params.text = paramText
    elseif actionType == "SPAWN_ZOMBIES" then
        params.count = tonumber(paramText) or 5
    end

    local draft = self:captureCurrentDraft()
    local objective = draft and draft.objectives and draft.objectives[objectiveIndex]

    if not objective then
        return
    end

    objective.triggers = objective.triggers or {}
    objective.triggers[#objective.triggers + 1] = {
        activationMode = activationMode,
        hotspotId = activationMode == "PROXIMITY" and hotspotId or nil,
        actions = { { type = actionType, params = params } },
    }

    if self.triggerActionParamEntry then
        self.triggerActionParamEntry:setText("")
    end

    self:rebuildRightPanel()
end

function KIPN_EventScenarioAdminUI:onSaveDefinition()
    local definition = self:getSelectedDefinition()

    if not definition then
        return
    end

    local _, payload = self:captureCurrentDraft()
    if not payload then
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_UPDATE_DEFINITION, payload)

    self.infoText = "Saving event..."
end

function KIPN_EventScenarioAdminUI:onDeleteDefinition()
    local definition = self:getSelectedDefinition()

    if not definition then
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_DELETE_DEFINITION, { id = definition.id })

    self.infoText = "Deleting event..."
end

------------------------------------------------------------
-- SCENARIO PRESET AUTOFILL
------------------------------------------------------------
--
-- Applies a preset combination of Objective Types/Timer Type/Outcome
-- Types/PvP to the already-built sibling widgets. Pure client-side
-- convenience -- nothing is sent to the server until Save Definition
-- is clicked, and the admin can still edit anything afterward.
--
-- ADVENTURE is randomized client-side (math.random -- cosmetic form
-- defaults only, not authoritative/security-sensitive) rather than
-- a fixed list, per "Random Objective + Random Threat + Random
-- Environment + Random Modifier". "Threat" maps to spawnRules
-- (the only live threat mechanic), "Modifier" maps to combat rules
-- -- both approximations, not a real modifier system.
------------------------------------------------------------

local function setEnumTickSelection(ticks, values)
    if not ticks then
        return
    end

    local selectedSet = {}
    for _, value in ipairs(values or {}) do
        selectedSet[value] = true
    end

    for _, tick in ipairs(ticks) do
        tick.selected[1] = selectedSet[tick.kipnEnumValue] == true
    end
end

local function setComboSelection(combo, value)
    if not combo then
        return
    end

    for index, option in ipairs(combo.options) do
        if option.data == value then
            combo:setSelected(index)
            return
        end
    end
end

function KIPN_EventScenarioAdminUI:onScenarioPresetChanged()
    if self._buildingForm
        or not self.objectiveTypesTick
        or not self.timerTypeCombo
        or not self.scopeTypeCombo
    then
        return
    end

    local selected = self.scenarioPresetCombo.options[self.scenarioPresetCombo.selected]
    local presetKey = selected and selected.data

    if not presetKey or presetKey == "CUSTOM" then
        return
    end

    local preset = KIPN.Shared.EventScenarioPresets[presetKey]

    if not preset then
        return
    end

    if preset.random then
        -- ADVENTURE: randomize rather than apply a fixed list.
        local objectiveTypes = KIPN.Shared.EventObjectiveTypeOrder
        local outcomeTypes = KIPN.Shared.EventOutcomeTypeOrder
        local timerTypes = KIPN.Shared.EventTimerTypeOrder
        local ruleTypes = KIPN.Shared.EventRuleTypeOrder
        local directorTypes = KIPN.Shared.EventDirectorTypeOrder
        local scopeTypes = KIPN.Shared.EventScopeTypeOrder or { "ZONE" }
        local zombieThemes = KIPN.Shared.EventZombieThemeOrder or { "RANDOM" }
        local timeOfDayOptions = ENVIRONMENT_TIME_OF_DAY_OPTIONS
        local weatherOptions = ENVIRONMENT_WEATHER_OPTIONS

        setEnumTickSelection(self.objectiveTypesTick, { objectiveTypes[ZombRand(1, #objectiveTypes + 1)] })
        setEnumTickSelection(self.outcomeTypesTick, { outcomeTypes[ZombRand(1, #outcomeTypes + 1)] })
        setComboSelection(self.timerTypeCombo, timerTypes[ZombRand(1, #timerTypes + 1)])
        -- "Random Threat": directorType is the "threat" dimension.
        setComboSelection(self.directorTypeCombo, directorTypes[ZombRand(1, #directorTypes + 1)])
        setComboSelection(self.scopeTypeCombo, scopeTypes[ZombRand(1, #scopeTypes + 1)])
        setComboSelection(self.zombieThemeCombo, zombieThemes[ZombRand(1, #zombieThemes + 1)])
        self.maxRoundsEntry:setText(tostring(ZombRand(1, 11)))
        setComboSelection(self.timeOfDayCombo, timeOfDayOptions[ZombRand(1, #timeOfDayOptions + 1)].value)

        self.weatherEnabledTick.selected[1] = true
        setComboSelection(self.weatherCombo, weatherOptions[ZombRand(1, #weatherOptions + 1)].value)

        -- "Random Modifier" approximation: randomize rules too.
        setComboSelection(self.ruleTypeCombo, ruleTypes[ZombRand(1, #ruleTypes + 1)])
        self.escalationTick.selected[1] = ZombRand(2) == 1
        self.allowLeaveTick.selected[1] = ZombRand(2) == 1
        self.pvpAllowedTick.selected[1] = ZombRand(2) == 1

        self.infoText = "Adventure preset: randomized selections applied."

        return
    end

    setEnumTickSelection(self.objectiveTypesTick, preset.objectiveTypes)
    setEnumTickSelection(self.outcomeTypesTick, preset.outcomeTypes)
    setComboSelection(self.timerTypeCombo, preset.timerType)
    setComboSelection(self.directorTypeCombo, preset.directorType)
    setComboSelection(self.ruleTypeCombo, preset.ruleType)
    setComboSelection(self.scopeTypeCombo, preset.scopeType or "ZONE")
    if preset.zombieTheme then setComboSelection(self.zombieThemeCombo, preset.zombieTheme) end
    self.maxRoundsEntry:setText(tostring(preset.maxRounds or 1))

    if preset.timerType and preset.timerType ~= "NONE" then
        self.durationEnabledTick.selected[1] = true
    end

    if preset.directorType and preset.directorType ~= "ZOMBIE_WAVES" then
        self.escalationTick.selected[1] = true
    end

    if preset.pvpAllowedInZone ~= nil then
        self.pvpAllowedTick.selected[1] = preset.pvpAllowedInZone
    end

    self.infoText = "Applied preset: " .. tostring(preset.label)
end

-- Quick playtest helper: builds a zone centered on the admin's own
-- position plus whatever hotspots the chosen Mode/objective types
-- need, so a scenario can be tried out without hand-drawing every
-- hotspot on the map first. Mirrors KIPN_EventHotspotService.lua's
-- ValidateDefinition() and KIPN_EventCaptureService.lua's
-- ValidateDefinition() requirements -- not every mode/objective
-- combination is covered, just the common validation gaps a fresh
-- definition hits. No terrain/collision awareness: a hotspot can land
-- inside a building or water, same as any other random point on the
-- map -- redraw individual hotspots afterward if one lands badly.
local RANDOMIZE_ZONE_RADIUS = 40
local RANDOMIZE_HOTSPOT_MARGIN = 6
local RANDOMIZE_HOTSPOT_HALF_SIZE = 3

function KIPN_EventScenarioAdminUI:onRandomizeZoneAndHotspots()
    local definition = self:getSelectedDefinition()
    if not definition then
        return
    end

    local draft = self:captureCurrentDraft()
    if not draft then
        return
    end

    local player = getPlayer()
    if not player then
        self.infoText = "Randomize needs a live player position -- try again in-game."
        return
    end

    local anchorX = math.floor(player:getX())
    local anchorY = math.floor(player:getY())
    local anchorZ = math.floor(player:getZ())
    local placementRange = RANDOMIZE_ZONE_RADIUS - RANDOMIZE_HOTSPOT_MARGIN

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_CREATE_ZONE_FROM_CORNERS, {
        id = definition.id,
        cornerA = { x = anchorX - RANDOMIZE_ZONE_RADIUS, y = anchorY - RANDOMIZE_ZONE_RADIUS, z = anchorZ },
        cornerB = { x = anchorX + RANDOMIZE_ZONE_RADIUS, y = anchorY + RANDOMIZE_ZONE_RADIUS, z = anchorZ },
    })

    local function upsertHotspot(hotspotType, roundNumber, teamId)
        local cx = anchorX + ZombRand(0, placementRange * 2 + 1) - placementRange
        local cy = anchorY + ZombRand(0, placementRange * 2 + 1) - placementRange

        sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_UPSERT_HOTSPOT, {
            id = definition.id,
            hotspot = {
                type = hotspotType,
                label = (KIPN.Shared.EventHotspotTypeLabels or {})[hotspotType] or hotspotType,
                roundNumber = roundNumber,
                teamId = teamId,
                geometry = {
                    x1 = cx - RANDOMIZE_HOTSPOT_HALF_SIZE, y1 = cy - RANDOMIZE_HOTSPOT_HALF_SIZE, z1 = anchorZ,
                    x2 = cx + RANDOMIZE_HOTSPOT_HALF_SIZE, y2 = cy + RANDOMIZE_HOTSPOT_HALF_SIZE, z2 = anchorZ,
                },
            },
        })
    end

    local mode = draft.mode
    local maxRounds = math.max(1, math.min(10, math.floor(tonumber(draft.maxRounds) or 1)))

    local objectiveTypes = {}
    for _, objectiveType in ipairs(draft.objectiveTypes or {}) do
        objectiveTypes[objectiveType] = true
    end

    if mode == "CAPTURE" and draft.variant == "TEAM_CTF" then
        local teams = draft.teams or {}

        if #teams < 2 then
            sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_SET_TEAM_COUNT, {
                id = definition.id,
                teamCount = 2,
            })

            -- KIPN_EventTeamService.lua's CreateTeams() always assigns
            -- ids "team_1".."team_N" from its fixed palette, so this
            -- click can place both teams' base hotspots against the
            -- team count just requested above without waiting on that
            -- command's own round trip.
            teams = { { id = "team_1" }, { id = "team_2" } }
        end

        for _, team in ipairs(teams) do
            for round = 1, maxRounds do
                upsertHotspot("TEAM_BASE", round, team.id)
            end
        end
    elseif mode == "CAPTURE" then
        for round = 1, maxRounds do
            upsertHotspot("CAPTURE_ITEM", round)
            upsertHotspot("DELIVERY_POINT", round)
        end
    else
        if objectiveTypes.HOLD_AREA then
            for round = 1, maxRounds do
                upsertHotspot("HILL_LOCATION", round)
            end
        end

        if objectiveTypes.RETRIEVE then
            upsertHotspot("CAPTURE_ITEM")
        end

        if objectiveTypes.DELIVER then
            upsertHotspot("DELIVERY_POINT")
        end
    end

    if mode == "EXTRACTION" and draft.variant == "PRISON_BREAK" then
        upsertHotspot("EXTRACTION_POINT")
    end

    if draft.scopeType == "HOTSPOTS" then
        upsertHotspot("ZOMBIE_SPAWN")
    end

    self.infoText = "Randomizing zone and hotspots around your current position..."
end

function KIPN_EventScenarioAdminUI:onDrawEventZone()
    local definition = self:getSelectedDefinition()

    if not definition then
        return
    end

    local panel = self

    panel:removeFromUIManager()

    KIPN_ZoneAdminMapUI.Open({
        existingZones = buildHotspotMapEntries(definition),
        onClose = function()
            panel:addToUIManager()
            panel:bringToTop()
        end,
        onConfirm = function(cornerA, cornerB)
            sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_CREATE_ZONE_FROM_CORNERS, {
                id = definition.id,
                cornerA = cornerA,
                cornerB = cornerB,
            })

            panel.infoText = "Creating event zone..."
        end,
    })
end

-- Rebuilds so the Narrative Text/Announce fields only appear for
-- NARRATIVE_LOCATION -- same idiom as onTriggerActivationModeChanged.
function KIPN_EventScenarioAdminUI:onHotspotTypeChanged()
    self:rebuildRightPanel()
end

function KIPN_EventScenarioAdminUI:onDrawEventHotspot()
    local definition = self:getSelectedDefinition()
    if not definition then return end

    self:captureCurrentDraft()
    local hotspotType = getComboData(self.hotspotTypeCombo)
    local roundNumber = tonumber(self.hotspotRoundEntry and self.hotspotRoundEntry:getText())
    local teamId = self.hotspotTeamCombo and getComboData(self.hotspotTeamCombo) or nil
    local narrativeText = self.hotspotNarrativeTextEntry
        and tostring(self.hotspotNarrativeTextEntry:getText() or ""):match("^%s*(.-)%s*$")
        or ""
    local narrativeScope = self.hotspotNarrativeScopeCombo and getComboData(self.hotspotNarrativeScopeCombo) or "LOCAL"

    if not hotspotType then
        self.infoText = "Select a hotspot type first."
        return
    end

    if hotspotType == "TEAM_BASE" and not teamId then
        self.infoText = "Select a team for this Team Base hotspot first."
        return
    end

    if hotspotType == "NARRATIVE_LOCATION" and narrativeText == "" then
        self.infoText = "Enter narrative text for this hotspot first."
        return
    end

    if hotspotType == "HILL_LOCATION" and not roundNumber then
        local hillCount = 0
        for _, hotspot in ipairs(definition.hotspots or {}) do
            if hotspot.type == "HILL_LOCATION" and hotspot.active ~= false then hillCount = hillCount + 1 end
        end
        roundNumber = math.min(10, hillCount + 1)
    end

    local panel = self
    panel:removeFromUIManager()

    KIPN_ZoneAdminMapUI.Open({
        existingZones = buildHotspotMapEntries(definition),
        onClose = function()
            panel:setVisible(true)
            panel:addToUIManager()
            panel:bringToTop()
        end,
        onConfirm = function(cornerA, cornerB)
            local zA = tonumber(cornerA and cornerA.z) or 0
            local zB = tonumber(cornerB and cornerB.z) or zA
            sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_UPSERT_HOTSPOT, {
                id = definition.id,
                hotspot = {
                    type = hotspotType,
                    label = (KIPN.Shared.EventHotspotTypeLabels or {})[hotspotType] or hotspotType,
                    roundNumber = roundNumber,
                    teamId = teamId,
                    metadata = hotspotType == "NARRATIVE_LOCATION" and {
                        narrativeText = narrativeText,
                        narrativeScope = narrativeScope,
                    } or nil,
                    geometry = {
                        x1 = cornerA and cornerA.x,
                        y1 = cornerA and cornerA.y,
                        z1 = zA,
                        x2 = cornerB and cornerB.x,
                        y2 = cornerB and cornerB.y,
                        z2 = zB,
                    },
                },
            })
            panel.infoText = "Saving hotspot..."
        end,
    })
end

function KIPN_EventScenarioAdminUI:onDeleteEventHotspot()
    local definition = self:getSelectedDefinition()
    local hotspotId = getComboData(self.hotspotSelectCombo)
    if not definition or not hotspotId then
        self.infoText = "Select an existing hotspot first."
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_DELETE_HOTSPOT, {
        id = definition.id,
        hotspotId = hotspotId,
    })
    self.infoText = "Deleting hotspot..."
end

function KIPN_EventScenarioAdminUI:onRefreshOnlinePlayers()
    self:captureCurrentDraft()
    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_LIST_ONLINE_PLAYERS, {})
    self.infoText = "Refreshing online players..."
end

function KIPN_EventScenarioAdminUI:onRefreshRewardAwards()
    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_LIST_REWARDS, {})
    self.infoText = "Refreshing prize delivery queue..."
end

function KIPN_EventScenarioAdminUI:onMarkRewardDelivered(button)
    local awardId = button and button.internal
    if not awardId then return end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_MARK_REWARD_DELIVERED, {
        awardId = awardId,
    })
    self.infoText = "Marking prize delivered..."
end

function KIPN_EventScenarioAdminUI:onSaveParticipants()
    local definition = self:getSelectedDefinition()

    if not definition then
        return
    end

    local draft = self:captureCurrentDraft()
    local usernames = {}
    local participants = draft and draft.participants or {}

    for username, selected in pairs(participants) do
        if selected == true then
            usernames[#usernames + 1] = username
        end
    end

    table.sort(usernames)

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_SET_PARTICIPANTS, {
        id = definition.id,
        usernames = usernames,
    })

    self.infoText = "Saving participant roster..."
end

function KIPN_EventScenarioAdminUI:onTeleportParticipants()
    local definition = self:getSelectedDefinition()

    if not definition then
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_TELEPORT_PARTICIPANTS, { id = definition.id })

    self.infoText = "Teleporting participants..."
end

------------------------------------------------------------
-- TEAMS (Phase 5)
------------------------------------------------------------

function KIPN_EventScenarioAdminUI:onSetTeamCount()
    local definition = self:getSelectedDefinition()

    if not definition or not self.teamCountEntry then
        return
    end

    local teamCount = math.floor(tonumber(self.teamCountEntry:getText()) or 0)

    if teamCount < 2 then
        self.infoText = "Team count must be at least 2."
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_SET_TEAM_COUNT, {
        id = definition.id,
        teamCount = teamCount,
    })

    self.infoText = "Setting team count..."
end

function KIPN_EventScenarioAdminUI:onAssignPlayerTeam()
    local definition = self:getSelectedDefinition()

    if not definition or not self.teamReassignPlayerCombo or not self.teamReassignTeamCombo then
        return
    end

    local username = getComboData(self.teamReassignPlayerCombo)
    local teamId = getComboData(self.teamReassignTeamCombo)

    if not username or not teamId then
        self.infoText = "Select both a player and a team first."
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_ASSIGN_PLAYER_TEAM, {
        id = definition.id,
        username = username,
        teamId = teamId,
    })

    self.infoText = "Reassigning player to team..."
end

------------------------------------------------------------
-- LIFECYCLE STAGE ACTIONS
------------------------------------------------------------

local function validateDefinitionPayload(definition, payload)
    local failures = {}
    local name = type(payload.name) == "string" and payload.name:match("^%s*(.-)%s*$") or ""

    if name == "" then
        failures[#failures + 1] = "Event Name is required"
    end
    if payload.scopeType == "ZONE" and not definition.zoneId then
        failures[#failures + 1] = "an Event Zone is required"
    end
    if #(payload.objectiveTypes or {}) == 0 then
        failures[#failures + 1] = "select at least one Objective Type"
    end
    if #(payload.outcomeTypes or {}) == 0 then
        failures[#failures + 1] = "select at least one Outcome Type"
    end

    local hotspotCounts = {}
    local activeHotspotCount = 0
    for _, hotspot in ipairs(definition.hotspots or {}) do
        if hotspot.active ~= false then
            activeHotspotCount = activeHotspotCount + 1
            hotspotCounts[hotspot.type] = (hotspotCounts[hotspot.type] or 0) + 1
        end
    end
    if payload.scopeType == "HOTSPOTS" and activeHotspotCount < 1 then
        failures[#failures + 1] = "draw at least one hotspot for Hotspots scope"
    end
    local selectedObjectives = {}
    for _, objectiveType in ipairs(payload.objectiveTypes or {}) do selectedObjectives[objectiveType] = true end
    if selectedObjectives.HOLD_AREA and (hotspotCounts.HILL_LOCATION or 0) < 1 then
        failures[#failures + 1] = "draw at least one Hill Location hotspot"
    elseif selectedObjectives.HOLD_AREA
        and (hotspotCounts.HILL_LOCATION or 0) < (tonumber(payload.maxRounds) or 1)
    then
        failures[#failures + 1] = "draw one Hill Location hotspot for each configured round"
    end
    if selectedObjectives.DELIVER and (hotspotCounts.DELIVERY_POINT or 0) < 1 then
        failures[#failures + 1] = "draw a Delivery Point hotspot"
    end
    if selectedObjectives.RETRIEVE
        and (hotspotCounts.CAPTURE_ITEM or 0) < 1
        and (hotspotCounts.RESCUE_OBJECTIVE or 0) < 1
    then
        failures[#failures + 1] = "draw a Capture Item or Rescue Objective hotspot"
    end

    local timerEnabled = payload.timerType and payload.timerType ~= "NONE"
    local durationEnabled = payload.duration and payload.duration.enabled == true
    local durationSeconds = tonumber(payload.duration and payload.duration.durationSeconds) or 0

    if timerEnabled and not durationEnabled then
        failures[#failures + 1] = "enable a Duration for the selected Timer Type"
    end
    if durationEnabled and durationSeconds <= 0 then
        failures[#failures + 1] = "Duration must be greater than zero"
    end

    return failures
end

function KIPN_EventScenarioAdminUI:onValidate()
    local definition = self:getSelectedDefinition()

    if not definition then
        return
    end

    local _, payload = self:captureCurrentDraft()
    if not payload then
        return
    end

    local failures = validateDefinitionPayload(definition, payload)

    if #failures > 0 then
        self.infoText = "Validation failed: " .. table.concat(failures, "; ") .. "."
        return
    end

    -- Validation must run against what is currently visible in the
    -- editor, not the last server copy. Save first, then issue
    -- EVENT_VALIDATE after EVENT_DEFINITION_SAVED acknowledges it.
    self.pendingValidateDefinitionId = definition.id
    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_UPDATE_DEFINITION, payload)

    self.infoText = "Saving and validating..."
end

function KIPN_EventScenarioAdminUI:onAnnounce()
    local definition = self:getSelectedDefinition()

    if not definition then
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_ANNOUNCE, { id = definition.id })

    self.infoText = "Announcing..."
end

function KIPN_EventScenarioAdminUI:onOpenJoining()
    local definition = self:getSelectedDefinition()

    if not definition then
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_OPEN_JOINING, { id = definition.id })

    self.infoText = "Opening joining..."
end

function KIPN_EventScenarioAdminUI:onStartEvent()
    local definition = self:getSelectedDefinition()

    if not definition then
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_START, { id = definition.id })

    self.infoText = "Starting event..."
end

function KIPN_EventScenarioAdminUI:onStopEvent()
    local definition = self:getSelectedDefinition()

    if not definition then
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_STOP, { id = definition.id })

    self.infoText = "Stopping event..."
end

function KIPN_EventScenarioAdminUI:onResetForReuse()
    local definition = self:getSelectedDefinition()

    if not definition then
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_RESET, { id = definition.id })

    self.infoText = "Resetting for reuse..."
end

function KIPN_EventScenarioAdminUI:onFireControl(controlId, params)
    local definition = self:getSelectedDefinition()

    if not definition then
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_RUNTIME_CONTROL, {
        id = definition.id,
        controlId = controlId,
        params = params,
    })

    self.infoText = "Sent control: " .. tostring(controlId)
end

------------------------------------------------------------
-- SERVER REQUESTS
------------------------------------------------------------

function KIPN_EventScenarioAdminUI:refreshDefinitions()
    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_LIST_DEFINITIONS, {})
end

function KIPN_EventScenarioAdminUI:refreshStatus()
    if not self.selectedDefinitionId then
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_GET_STATUS, { id = self.selectedDefinitionId })
end

function KIPN_EventScenarioAdminUI:refreshEventTypeMetadata(eventType)
    sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_GET_EVENTTYPE_METADATA, { eventType = eventType })
end

------------------------------------------------------------
-- SERVER RESPONSE HANDLERS
------------------------------------------------------------

local function replaceCachedDefinition(panel, updatedDefinition)
    if not panel or not updatedDefinition or not updatedDefinition.id then
        return false
    end

    for index, definition in ipairs(panel.definitions or {}) do
        if definition.id == updatedDefinition.id then
            panel.definitions[index] = updatedDefinition
            return true
        end
    end

    return false
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

    ------------------------------------------------------------
    -- NARRATIVE BROADCAST -- handled for EVERY player, not just an
    -- admin with this panel open. Build 42's HaloTextHelper.addText
    -- overload accepts (player, text); passing separate RGB values
    -- raises a Java overload-resolution exception.
    ------------------------------------------------------------

    if event == KIPN.Shared.ResponseEvents.EVENT_NARRATIVE then
        local text = data.text

        if type(text) == "string" and text ~= "" then
            local player = getPlayer()
            local canDisplay = player
                and HaloTextHelper
                and HaloTextHelper.addText

            if canDisplay then
                local ok, err = pcall(HaloTextHelper.addText, player, text)

                if not ok then
                    print("[KIPN Event Scenarios] Failed to display narrative text: " .. tostring(err))
                end
            end
        end

        return
    end

    local panel = KIPN_EventScenarioAdminUI.instance

    if not panel then
        return
    end

    if event == KIPN.Shared.ResponseEvents.EVENT_DEFINITIONS_DATA then
        panel.definitions = data.definitions or {}
        panel:rebuildRightPanel()

    elseif event == KIPN.Shared.ResponseEvents.EVENT_DEFINITION_SAVED then
        if data.success then
            if data.definition then
                replaceCachedDefinition(panel, data.definition)
            end

            if data.definition and not panel.selectedDefinitionId then
                panel.selectedDefinitionId = data.definition.id
                panel:refreshEventTypeMetadata(data.definition.eventType)
            end

            if data.definition
                and panel.pendingValidateDefinitionId == data.definition.id then
                panel.pendingValidateDefinitionId = nil
                panel.infoText = "Validating..."
                sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_VALIDATE, {
                    id = data.definition.id,
                })
            else
                panel.infoText = "Event saved."
                panel:refreshDefinitions()
            end
        else
            panel.pendingValidateDefinitionId = nil
            panel.infoText = "Save failed: " .. tostring(data.reason)
        end

    elseif event == KIPN.Shared.ResponseEvents.EVENT_DEFINITION_DELETED then
        if data.success then
            panel.infoText = "Event deleted."
            panel.editorDrafts[data.id] = nil
            panel.selectedDefinitionId = nil
            panel.renderedDefinitionId = nil
            panel.status = nil
            panel:refreshDefinitions()
            panel:rebuildRightPanel()
        else
            panel.infoText = "Delete failed: " .. tostring(data.reason)
        end

    elseif event == KIPN.Shared.ResponseEvents.EVENT_ZONE_SAVED then
        if data.success then
            panel.infoText = "Event zone linked."
            panel:refreshDefinitions()
        else
            panel.infoText = "Zone failed: " .. tostring(data.reason)
        end

    elseif event == KIPN.Shared.ResponseEvents.EVENT_HOTSPOT_SAVED then
        if data.success and data.definition then
            replaceCachedDefinition(panel, data.definition)
            local draft = panel.editorDrafts[data.definition.id]
            if draft then draft.hotspots = data.definition.hotspots or {} end
            panel.infoText = "Event hotspot saved."
            panel:rebuildRightPanel()
        else
            panel.infoText = "Hotspot failed: " .. tostring(data.reason)
        end

    elseif event == KIPN.Shared.ResponseEvents.EVENT_EVENTTYPE_METADATA_DATA then
        if data.success then
            panel.availableWinConditions = data.winConditions or {}
            panel.availableFailConditions = data.failConditions or {}
            panel.metadataEventType = data.eventType

            if panel.selectedDefinitionId then
                panel:rebuildRightPanel()
            end
        end

    elseif event == KIPN.Shared.ResponseEvents.EVENT_ONLINE_PLAYERS_DATA then
        panel:captureCurrentDraft()
        panel.onlinePlayers = data.players or {}
        panel:rebuildRightPanel()

    elseif event == KIPN.Shared.ResponseEvents.EVENT_PARTICIPANTS_SAVED then
        if data.success then
            panel.infoText = "Participant roster saved."
            panel:refreshDefinitions()
        else
            panel.infoText = "Roster save failed: " .. tostring(data.reason)
        end

    elseif event == KIPN.Shared.ResponseEvents.EVENT_TEAM_SAVED then
        if data.success and data.definition then
            replaceCachedDefinition(panel, data.definition)
            panel.infoText = "Team change saved."
            panel:rebuildRightPanel()
        else
            panel.infoText = "Team change failed: " .. tostring(data.reason)
        end

    elseif event == KIPN.Shared.ResponseEvents.EVENT_STATUS_CHANGED then
        panel.infoText = data.success and "Status updated." or ("Failed: " .. tostring(data.reason))

        if data.success and data.definition then
            replaceCachedDefinition(panel, data.definition)

            -- Keep the runtime snapshot aligned until the fresh
            -- EVENT_GET_STATUS response arrives. This makes the next
            -- stage button usable immediately after the acknowledgement.
            panel.status = { status = data.definition.status }
        end

        panel:refreshDefinitions()
        panel:refreshStatus()
        panel:rebuildRightPanel()

    elseif event == KIPN.Shared.ResponseEvents.EVENT_TELEPORT_RESULT then
        if data.success then
            panel.infoText = "Teleport complete (" .. tostring(data.results and #data.results or 0) .. " player(s))."
        else
            panel.infoText = "Teleport failed: " .. tostring(data.reason)
        end

    elseif event == KIPN.Shared.ResponseEvents.EVENT_STARTED then
        if data.success then
            panel.infoText = "Event started."
            panel.status = data.status

            local definition = panel:getSelectedDefinition()
            if definition and data.status and data.status.status then
                definition.status = data.status.status
            end

            panel:refreshDefinitions()
            panel:rebuildRightPanel()
        else
            panel.infoText = "Start failed: " .. tostring(data.reason)
        end

    elseif event == KIPN.Shared.ResponseEvents.EVENT_STOPPED then
        panel.infoText = data.success and "Event stopped." or ("Stop failed: " .. tostring(data.reason))
        panel.status = nil

        local definition = panel:getSelectedDefinition()
        if data.success and definition then
            definition.status = "COMPLETE"
        end

        panel:refreshDefinitions()
        panel:rebuildRightPanel()

    elseif event == KIPN.Shared.ResponseEvents.EVENT_STATUS_DATA then
        panel.status = data
        panel:rebuildRightPanel()

    elseif event == KIPN.Shared.ResponseEvents.EVENT_CONTROL_RESULT then
        panel.infoText = data.success and "Control fired." or ("Control failed: " .. tostring(data.reason))
        panel.status = data.status
        panel:rebuildRightPanel()

    elseif event == KIPN.Shared.ResponseEvents.EVENT_REWARDS_DATA then
        panel.rewardAwards = data.awards or {}
        panel.infoText = "Prize delivery queue refreshed."
        panel:rebuildRightPanel()

    elseif event == KIPN.Shared.ResponseEvents.EVENT_REWARD_RESULT then
        panel.infoText = data.success and "Prize marked delivered."
            or ("Prize update failed: " .. tostring(data.reason))
        if data.success then
            sendClientCommand("KIPN", KIPN.Shared.Commands.EVENT_LIST_REWARDS, {})
        end

    elseif event == KIPN.Shared.ResponseEvents.ERROR then
        -- Without this branch, ANY declined/errored command for
        -- this panel (a permission denial, a handler exception,
        -- SYSOP_CONFIGURATION failing server-side, etc.) was
        -- silently dropped -- infoText stayed frozen on
        -- "Requesting event definitions..." forever, indistinguishable
        -- from the server never having responded at all.
        panel.pendingValidateDefinitionId = nil
        panel.infoText = "Server error: " .. tostring(data.reason or data.message or "Unknown error.")
    end
end

------------------------------------------------------------
-- RENDER
------------------------------------------------------------

function KIPN_EventScenarioAdminUI:prerender()
    ISPanel.prerender(self)

    self:drawText(self.infoText or "", 10, self:getHeight() - 20, 0.8, 0.8, 0.8, 1, UIFont.Small)
end

--------------------------------------------------------------------
-- SERVER RESPONSE HOOKS
--------------------------------------------------------------------

Events.OnServerCommand.Add(onServerResponse)

print("[KIPN] Event Scenario Admin UI loaded")
