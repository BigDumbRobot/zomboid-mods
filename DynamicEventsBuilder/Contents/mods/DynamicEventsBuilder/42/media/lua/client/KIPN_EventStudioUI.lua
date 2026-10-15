-- KIPN_EventStudioUI.lua
--
-- Event Studio: the admin window for building and running a Dynamic
-- Event one step at a time. Laid out like lilBubby's Mod Showcase:
-- events on the left; a numbered step bar across the top; the current
-- step's fields in the middle; on the right what to do on this step,
-- what is still missing, and a log of what the server said.
--
-- Opened from the world right-click menu (Dynamic Events > Event
-- Studio, admins). Checklist, defaults and wording live in
-- KIPN_EventStudio.lua. Every command is re-checked by the server
-- (SYSOP_CONFIGURATION); nothing here is trusted.
--
-- Editing model: each event has a draft. A step's widgets register
-- binders that copy their values into the draft on commit() (step
-- change, save, any button). Buttons that change the draft themselves
-- commit first, change it, then rebuild(true) so the stale widgets are
-- not committed over the change. Moving between steps saves, so an
-- admin never has to remember to.

require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "ISUI/ISTickBox"
require "ISUI/ISRichTextPanel"
require "ISUI/ISScrollingListBox"
require "KIPN_EventStudio"
require "KIPN_EventStudioLiveUI"
require "KIPN_ZoneAdminMapUI"
require "KIPN_EventDirectorPanel"
require "KIPN_EventDirectorControlUI"

KIPN_EventStudioUI = ISCollapsableWindow:derive("KIPN_EventStudioUI")
local W, S = KIPN_EventStudioUI, KIPN_EventStudio
local Shared = KIPN.Shared

local PAD = 10
local ROW = 24
local GAP = 6
local TICK = 16
local SEARCH_RESULTS = 6
local AREA_RADIUS = 40
local HOTSPOT_MARGIN = 6
local HOTSPOT_HALF = 3

local WHITE = { 0.92, 0.92, 0.92 }
local MUTED = { 0.62, 0.66, 0.72 }
local HEAD = { 0.80, 0.70, 1.00 }
local WARN = { 1.00, 0.72, 0.30 }
local GOOD = { 0.45, 0.88, 0.45 }
local BAD = { 1.00, 0.42, 0.42 }
local LEVEL_COLORS = { ok = GOOD, error = BAD, warn = WARN, info = WHITE }

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------

local function fontHeight() return getTextManager():getFontHeight(UIFont.Small) end

local function now()
    return getTimestampMs and getTimestampMs() or (os.time() * 1000)
end

-- Names and messages can come from players; never let them act as
-- rich-text commands.
local function plain(text)
    return (tostring(text or ""):gsub("<", "["):gsub(">", "]"))
end
local function rich(text) return (plain(text):gsub("\n", " <LINE> ")) end
local function rgb(color) return string.format(" <RGB:%.2f,%.2f,%.2f> ", color[1], color[2], color[3]) end

local function fit(text, width)
    local manager = getTextManager()
    text = tostring(text or "")
    if manager:MeasureStringX(UIFont.Small, text) <= width then return text end
    while #text > 0 and manager:MeasureStringX(UIFont.Small, text .. "...") > width do text = text:sub(1, -2) end
    return text .. "..."
end

local function place(child, x, y, width, height)
    child:setX(x); child:setY(y)
    child:setWidth(width); child:setHeight(height)
end

local function send(command, args)
    local name = Shared.Commands and Shared.Commands[command]
    if not name then
        print("[Dynamic Events] Event Studio: unknown command " .. tostring(command))
        return false
    end
    sendClientCommand("KIPN", name, args or {})
    return true
end

local function comboValue(combo)
    local option = combo and combo.options and combo.options[combo.selected]
    return option and option.data
end

local function options(order, labels, first)
    local list = {}
    if first then list[1] = first end
    for _, key in ipairs(order or {}) do list[#list + 1] = { text = (labels or {})[key] or tostring(key), value = key } end
    return list
end

local function minutesOf(seconds) return tostring(math.floor((tonumber(seconds) or 0) / 60)) end

local function wrappedHeight(text, width)
    local manager = getTextManager()
    local lineHeight = manager:getFontFromEnum(UIFont.Small):getLineHeight()
    local space = manager:MeasureStringX(UIFont.Small, " ")
    local lines, lineWidth = 0, 0
    for paragraph in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        lines, lineWidth = lines + 1, 0
        for word in paragraph:gmatch("%S+") do
            local wordWidth = manager:MeasureStringX(UIFont.Small, word)
            local added = lineWidth == 0 and wordWidth or (lineWidth + space + wordWidth)
            if added > width and lineWidth > 0 then
                lines, lineWidth = lines + 1, wordWidth
            else
                lineWidth = added
            end
        end
    end
    return math.max(1, lines) * lineHeight
end

-- Item names for the reward and flag search: every loaded item script,
-- or KIPN's list if scripts cannot be read.
local itemCache
local function allItems()
    if itemCache then return itemCache end
    itemCache = {}
    pcall(function()
        local items = getScriptManager():getAllItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            local fullType = item:getFullName()
            if fullType then
                itemCache[#itemCache + 1] = { fullType = fullType, name = item:getDisplayName() or fullType }
            end
        end
    end)
    if #itemCache == 0 and KIPN.ItemTypeSuggestions and KIPN.ItemTypeSuggestions.ITEMS then
        for _, fullType in ipairs(KIPN.ItemTypeSuggestions.ITEMS) do
            itemCache[#itemCache + 1] = { fullType = fullType, name = fullType }
        end
    end
    return itemCache
end

local function searchItems(query)
    query = S.Trim(query):lower()
    if #query < 2 then return {} end
    local matches = {}
    for _, item in ipairs(allItems()) do
        local fullType, name = item.fullType:lower(), tostring(item.name):lower()
        local rank = (name:sub(1, #query) == query or fullType:find("." .. query, 1, true)) and 0
            or ((name:find(query, 1, true) or fullType:find(query, 1, true)) and 1)
        if rank then matches[#matches + 1] = { item = item, rank = rank } end
    end
    table.sort(matches, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return tostring(a.item.name) < tostring(b.item.name)
    end)
    local out = {}
    for index = 1, math.min(SEARCH_RESULTS, #matches) do out[index] = matches[index].item end
    return out
end

-- Hotspots in the shape KIPN_ZoneAdminMapUI draws them.
local function mapEntries(d)
    local entries = {}
    for _, hotspot in ipairs((d and d.hotspots) or {}) do
        entries[#entries + 1] = {
            id = hotspot.id, type = hotspot.type, label = hotspot.label, teamId = hotspot.teamId,
            geometry = hotspot.geometry, roundNumber = hotspot.roundNumber, active = hotspot.active, kind = "hotspot",
        }
    end
    return entries
end

local function teamName(d, teamId)
    for _, team in ipairs(d.teams or {}) do
        if team.id == teamId then return team.name or teamId end
    end
    return teamId
end

local function taskLabel(task)
    return tostring(((Shared.EventOlympicTasks or {})[task] or {}).label or task)
end

local function describeHotspot(d, hotspot)
    local text = S.HotspotLabel(hotspot.type)
    if hotspot.type:find("^OLYMPIC_") and hotspot.roundNumber then
        text = text .. " " .. tostring(hotspot.roundNumber)
        local meta = hotspot.metadata or {}
        if meta.task then
            text = text .. ": " .. taskLabel(meta.task)
            if meta.itemType and meta.task ~= "SHOOT" then text = text .. ", " .. tostring(meta.count or 1) .. " x " .. meta.itemType end
            if meta.task == "SHOOT" then text = text .. ", " .. tostring(meta.count or 1) .. " targets" end
        end
        return text
    end
    if hotspot.teamId then text = text .. ", " .. tostring(teamName(d, hotspot.teamId)) end
    if hotspot.roundNumber then text = text .. ", round " .. tostring(hotspot.roundNumber) end
    local narrative = hotspot.metadata and hotspot.metadata.narrativeText
    if narrative and narrative ~= "" then
        if hotspot.metadata.replayable ~= false then
            text = text .. " (clue" .. (hotspot.metadata.clueTitle and (": " .. hotspot.metadata.clueTitle) or "") .. ")"
        end
        text = text .. ": \"" .. narrative .. "\""
    end
    return text
end

local TRIGGER_WHEN = {
    { text = "When I press it in the Director panel", value = "MANUAL" },
    { text = "When a player reaches a hotspot", value = "PROXIMITY" },
}

local TRIGGER_ACTIONS = {
    { text = "Announce to everyone online (text)", value = "ANNOUNCEMENT", param = "text" },
    { text = "Private hint to the player (text; they can replay it)", value = "PRIVATE_HINT", param = "text" },
    { text = "Sound an alarm", value = "ALARM" },
    { text = "Spawn zombies (count)", value = "SPAWN_ZOMBIES", param = "count" },
    { text = "Bandits arrive and attack (crew size)", value = "SPAWN_BANDITS", param = "count" },
    { text = "Complete this stage (story moves on)", value = "COMPLETE_OBJECTIVE" },
}

local function describeTrigger(d, trigger)
    local when = "when you press it"
    if trigger.activationMode == "PROXIMITY" then
        local where = "a deleted hotspot"
        for _, hotspot in ipairs(d.hotspots or {}) do
            if hotspot.id == trigger.hotspotId then where = describeHotspot(d, hotspot) end
        end
        when = "when a player reaches " .. where
    end
    local doing = {}
    for _, action in ipairs(trigger.actions or {}) do
        local label = action.type
        for _, option in ipairs(TRIGGER_ACTIONS) do
            if option.value == action.type then label = option.text:gsub(" %(.*%)$", "") end
        end
        local params = action.params or {}
        if params.text and params.text ~= "" then label = label .. " \"" .. params.text .. "\"" end
        if params.count then label = label .. " x" .. tostring(params.count) end
        doing[#doing + 1] = label
    end
    return when .. ": " .. table.concat(doing, ", ")
end

------------------------------------------------------------
-- WINDOW
------------------------------------------------------------

function W:new()
    local screenWidth, screenHeight = getCore():getScreenWidth(), getCore():getScreenHeight()
    local width = math.min(1220, screenWidth - 24)
    local height = math.min(820, screenHeight - 40)
    local o = ISCollapsableWindow.new(self, math.floor((screenWidth - width) / 2), math.max(24, math.floor((screenHeight - height) / 2)), width, height)
    o.title = "Dynamic Events - Event Studio"
    o.minimumWidth = math.min(940, width)
    o.minimumHeight = math.min(600, height)
    o.resizable = true
    o.backgroundColor = { r = 0.07, g = 0.08, b = 0.10, a = 0.97 }
    o.definitions = {}
    o.drafts = {}
    o.dirty = {}
    o.sentSignature = {}
    o.stepByEvent = {}
    o.step = 1
    o.issues = {}
    o.log = {}
    o.metadata = {}
    o.awards = {}
    o.formWidgets = {}
    o.binders = {}
    -- Left list: "saved" (every event), "prepared" (ready to run or on
    -- its way) or "past" (runs that ended).
    o.view = "saved"
    o.history = {}
    return o
end

local function staticButton(self, title, callback)
    local button = ISButton:new(0, 0, 100, 28, title, self, callback)
    button:initialise()
    self:addChild(button)
    return button
end

local function richPanel(self)
    local panel = ISRichTextPanel:new(0, 0, 100, 100)
    panel:initialise()
    panel.autosetheight = false
    panel.clip = true
    panel:addScrollBars()
    panel:setMargins(10, 8, 20, 8)
    panel.background = true
    panel.backgroundColor = { r = 0, g = 0, b = 0, a = 0.35 }
    panel.borderColor = { r = 0.40, g = 0.40, b = 0.45, a = 0.6 }
    self:addChild(panel)
    return panel
end

-- A scrolling panel whose children are clipped to it.
local function scrollPane(self)
    local pane = ISPanel:new(0, 0, 100, 100)
    pane:initialise()
    pane.backgroundColor = { r = 0, g = 0, b = 0, a = 0.35 }
    pane.borderColor = { r = 0.40, g = 0.40, b = 0.45, a = 0.6 }
    self:addChild(pane)
    pane:addScrollBars()
    pane:setScrollChildren(true)
    pane:setScrollWithParent(false)
    pane.onMouseWheel = function(panel, delta)
        panel:setYScroll(panel:getYScroll() - delta * 40)
        return true
    end
    pane.prerender = function(panel)
        panel:setStencilRect(0, 0, panel.width, panel.height)
        ISPanel.prerender(panel)
    end
    pane.render = function(panel)
        ISPanel.render(panel)
        panel:clearStencilRect()
    end
    return pane
end

function W:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.newButton = staticButton(self, "+ New event", W.onNew)
    self.newButton.tooltip = "Create a blank event and start at step 1"
    self.refreshButton = staticButton(self, "Refresh list", W.refresh)
    self.directorButton = staticButton(self, "Director Controls", W.onDirectorControls)
    self.directorButton.tooltip = "The live controls for a running event"
    self.viewButtons = {}
    for _, view in ipairs(W.VIEWS) do
        local b = staticButton(self, view.title, W.onViewButton)
        b.internal = view.id
        b.tooltip = view.tooltip
        self.viewButtons[#self.viewButtons + 1] = b
    end
    self.events = ISScrollingListBox:new(0, 0, 100, 100)
    self.events:initialise()
    self.events.itemheight = 2 * fontHeight() + 14
    self.events:setOnMouseDownFunction(self, W.onPickEvent)
    self.events.doDrawItem = W.drawEvent
    self.events.studio = self
    self:addChild(self.events)

    self.stepButtons = {}
    for index, step in ipairs(S.Steps) do
        local button = staticButton(self, index .. " " .. step.title, W.onStepButton)
        button.internal = index
        button.tooltip = step.heading
        self.stepButtons[index] = button
    end

    self.form = scrollPane(self)
    self.guide = richPanel(self)
    self.activity = richPanel(self)
    self.backButton = staticButton(self, "< Back", W.onBack)
    self.saveButton = staticButton(self, "Save", W.onSave)
    self.saveButton.tooltip = "Moving to another step also saves"
    self.nextButton = staticButton(self, "Next >", W.onNext)
    self:layout()
    self:rebuild(true)
end

function W:layout()
    if not self.form then return end
    local top = self:titleBarHeight() + PAD
    local bottom = self.height - self:resizeWidgetHeight() - PAD
    local side = math.max(200, math.floor(self.width * 0.18))
    place(self.newButton, PAD, top, side, 28)
    local viewWidth = math.floor((side - 2 * 4) / 3)
    for index, b in ipairs(self.viewButtons) do
        place(b, PAD + (index - 1) * (viewWidth + 4), top + 32, viewWidth, 24)
    end
    place(self.events, PAD, top + 60, side, bottom - top - 60 - 64)
    place(self.refreshButton, PAD, bottom - 62, side, 28)
    place(self.directorButton, PAD, bottom - 28, side, 28)

    local x = PAD * 2 + side
    local right = self.width - PAD
    self.bodyX, self.bodyRight, self.headerY = x, right, top
    local stepY = top + 28
    local count = #self.stepButtons
    local stepWidth = math.floor((right - x - (count - 1) * 4) / count)
    for index, button in ipairs(self.stepButtons) do
        place(button, x + (index - 1) * (stepWidth + 4), stepY, stepWidth, 26)
    end

    local bodyY = stepY + 34
    local footerY = bottom - 28
    local bodyHeight = footerY - bodyY - 8
    local formWidth = math.floor((right - x) * 0.58)
    place(self.form, x, bodyY, formWidth, bodyHeight)
    local guideX = x + formWidth + PAD
    local guideHeight = math.floor(bodyHeight * 0.66)
    place(self.guide, guideX, bodyY, right - guideX, guideHeight)
    place(self.activity, guideX, bodyY + guideHeight + 6, right - guideX, bodyHeight - guideHeight - 6)
    place(self.backButton, x, footerY, 90, 28)
    place(self.nextButton, x + formWidth - 150, footerY, 150, 28)
    place(self.saveButton, x + formWidth - 150 - 6 - 80, footerY, 80, 28)
    self.statusX, self.statusY = x + 100, footerY + 6
    self.statusWidth = formWidth - 100 - 150 - 6 - 80 - 10
    self.guide:paginate()
    self.activity:paginate()
end

function W:prerender()
    if self.lastWidth ~= self.width or self.lastHeight ~= self.height then
        self.lastWidth, self.lastHeight = self.width, self.height
        self:layout()
        self.relayoutAt = now() + 250
    end
    -- Rebuild the form once resizing has settled, not every frame.
    if self.relayoutAt and now() >= self.relayoutAt then
        self.relayoutAt = nil
        if self.formWidth ~= self.form.width then self:rebuild() end
    end
    ISCollapsableWindow.prerender(self)
    if self.isCollapsed or not self.bodyX then return end

    local d = self:draft()
    local width = self.bodyRight - self.bodyX
    if d then
        local color = S.StatusColors[d.status] or MUTED
        local action = S.NextAction[d.status]
        local status = S.StatusLabel(d.status) .. (action and action.id and ("  |  next: " .. action.label) or "")
        local statusWidth = getTextManager():MeasureStringX(UIFont.Small, status)
        local name = S.Trim(d.name) ~= "" and d.name or "(unnamed event)"
        self:drawText(fit(name, width - statusWidth - 20), self.bodyX, self.headerY, 1, 1, 1, 1, UIFont.Medium)
        self:drawText(status, self.bodyRight - statusWidth, self.headerY + 4, color[1], color[2], color[3], 1, UIFont.Small)
    else
        self:drawText("Dynamic Events", self.bodyX, self.headerY, 1, 1, 1, 1, UIFont.Medium)
    end
    if self.info then
        local color = LEVEL_COLORS[self.infoLevel] or WHITE
        self:drawText(fit(self.info, self.statusWidth), self.statusX, self.statusY, color[1], color[2], color[3], 1, UIFont.Small)
    end
end

function W.drawEvent(list, y, item, alt)
    local studio, definition = list.studio, item.item
    if list.selected == item.index then
        list:drawRect(0, y, list.width, list.itemheight, 0.65, 0.30, 0.20, 0.45)
    end
    if definition.isPast then
        local color = W.OUTCOME_COLORS[definition.outcome] or MUTED
        list:drawText(fit(tostring(definition.name or "(unnamed)"), list.width - 16), 6, y + 4, 0.95, 0.95, 0.95, 1, UIFont.Small)
        list:drawText(fit(W.PastLine(definition), list.width - 16), 6, y + fontHeight() + 7, color[1], color[2], color[3], 1, UIFont.Small)
        return y + list.itemheight
    end
    local draft = studio.drafts[definition.id]
    local name = draft and S.Trim(draft.name) ~= "" and draft.name or definition.name or "(unnamed)"
    if studio.dirty[definition.id] then name = name .. " *" end
    local color = S.StatusColors[definition.status] or MUTED
    list:drawText(fit(name, list.width - 16), 6, y + 4, 0.95, 0.95, 0.95, 1, UIFont.Small)
    list:drawText(fit(S.StatusLabel(definition.status) .. "  |  " .. S.ModeLabel(definition.mode), list.width - 16),
        6, y + fontHeight() + 7, color[1], color[2], color[3], 1, UIFont.Small)
    return y + list.itemheight
end

------------------------------------------------------------
-- STATE
------------------------------------------------------------

function W:definition(id)
    for _, definition in ipairs(self.definitions) do
        if definition.id == (id or self.selectedId) then return definition end
    end
end

function W:draft() return self.selectedId and self.drafts[self.selectedId] end

function W:editable()
    local d = self:draft()
    return d ~= nil and S.Editable[d.status] == true
end

function W:storeDefinition(definition)
    local found = false
    for index, existing in ipairs(self.definitions) do
        if existing.id == definition.id then
            self.definitions[index] = definition
            found = true
        end
    end
    if not found then self.definitions[#self.definitions + 1] = definition end
    local draft = self.drafts[definition.id]
    if draft then S.MergeServerFields(draft, definition) end
end

function W:updateDirty()
    self.dirty = {}
    for id, draft in pairs(self.drafts) do
        local definition = self:definition(id)
        if definition then
            self.dirty[id] = S.Signature(draft) ~= S.Signature(S.NewDraft(definition))
        end
    end
end

function W:note(text, level)
    self.info, self.infoLevel = text, level or "info"
    table.insert(self.log, 1, { text = text, level = self.infoLevel })
    while #self.log > 40 do table.remove(self.log) end
    self:refreshActivity()
end

-- Copies every widget on the current step into the draft.
function W:commit()
    local d = self:draft()
    if not d then return end
    for _, binder in ipairs(self.binders) do binder(d) end
end

-- Commit, change the draft, rebuild without re-committing stale widgets.
function W:change(fn)
    self:commit()
    local d = self:draft()
    if not d then return end
    fn(d)
    self:rebuild(true)
end

function W:saveIfDirty()
    local d = self:draft()
    if not d or not self:editable() then return false end
    local definition = self:definition()
    if not definition or S.Signature(d) == S.Signature(S.NewDraft(definition)) then return false end
    self.sentSignature[d.id] = S.Signature(d)
    send("EVENT_UPDATE_DEFINITION", S.Payload(d))
    self:note("Saving...")
    return true
end

------------------------------------------------------------
-- REBUILD
------------------------------------------------------------

function W:rebuild(skipCommit)
    if not self.form then return end
    if not skipCommit then self:commit() end
    local d = self:draft()
    self.issues = d and S.Check(d) or {}
    self:updateDirty()
    self:refreshList()
    self:buildForm()
    self:refreshSteps()
    self:refreshGuide()
    self:refreshFooter()
end

function W:refreshList()
    for _, b in ipairs(self.viewButtons or {}) do
        b.backgroundColor = b.internal == self.view and { r = 0.32, g = 0.20, b = 0.48, a = 1 } or { r = 0, g = 0, b = 0, a = 0.8 }
    end
    self.events:clear()
    if self.view == "past" then
        local selectedPast = -1
        for _, record in ipairs(self.history) do
            record.isPast = true
            self.events:addItem(record.name or record.id, record)
            if self.pastRecord and record.id == self.pastRecord.id then selectedPast = #self.events.items end
        end
        self.events.selected = selectedPast
        return
    end
    local sorted = {}
    for _, definition in ipairs(self.definitions) do
        if self.view ~= "prepared" or (Shared.EventPreparedStatuses or {})[definition.status] then sorted[#sorted + 1] = definition end
    end
    table.sort(sorted, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
    local selected = -1
    for _, definition in ipairs(sorted) do
        self.events:addItem(definition.name or definition.id, definition)
        if definition.id == self.selectedId then selected = #self.events.items end
    end
    self.events.selected = selected
end

function W:refreshSteps()
    local d = self:draft()
    local total = S.Blocking(self.issues)
    for index, button in ipairs(self.stepButtons) do
        local step = S.Steps[index]
        local blocking = S.Blocking(S.IssuesForStep(self.issues, step.id))
        local title = index .. " " .. step.title
        if d and step.id ~= "launch" and blocking > 0 then title = title .. " (" .. blocking .. ")" end
        button:setTitle(title)
        button:setEnable(d ~= nil)
        button.backgroundColor = index == self.step and d and { r = 0.32, g = 0.20, b = 0.48, a = 1 } or { r = 0, g = 0, b = 0, a = 0.8 }
        local border = { r = 0.40, g = 0.40, b = 0.45, a = 0.8 }
        if d and step.id == "launch" then
            border = total == 0 and { r = 0.45, g = 0.88, b = 0.45, a = 1 } or border
        elseif d and blocking > 0 then
            border = { r = 1.00, g = 0.72, b = 0.30, a = 1 }
        elseif d then
            border = { r = 0.45, g = 0.88, b = 0.45, a = 0.9 }
        end
        button.borderColor = border
    end
end

function W:refreshFooter()
    local d = self:draft()
    local last = #S.Steps
    self.backButton:setEnable(d ~= nil and self.step > 1)
    self.nextButton:setVisible(d ~= nil and self.step < last)
    if d and self.step < last then self.nextButton:setTitle("Next: " .. S.Steps[self.step + 1].title .. " >") end
    self.saveButton:setVisible(d ~= nil)
    local canSave = self:editable() and self.dirty[self.selectedId] == true
    self.saveButton:setEnable(canSave)
    self.saveButton:setTitle(canSave and "Save" or "Saved")
end

function W:refreshGuide()
    local d = self:draft()
    local parts = {}
    local function line(text, color) parts[#parts + 1] = rgb(color or WHITE) .. rich(text) .. " <LINE> " end

    if not d and self.view == "past" then
        line("Past events", HEAD)
        line("Every run that has ended, newest first: won, lost, stopped by staff, or cancelled before it began. Pick one to see who played and who won, or open the event to run it again.")
    elseif not d and self.view == "prepared" then
        line("Prepared events", HEAD)
        line("Events that are ready to run or already announced. Pick one to Start it, Simulate it, send Announcements for it, or Cancel it.")
    elseif not d then
        line("What is this?", HEAD)
        line("Dynamic Events lets staff build server events, such as a King of the Hill match, a capture the flag or a timed survival run, and run them live with zombies, rewards and a story.")
        line("")
        line("How it works", HEAD)
        for index, step in ipairs(S.Steps) do line(index .. ". " .. step.title .. ": " .. step.heading) end
        line("")
        line("Press + New event to start, or pick an event on the left to continue it.", GOOD)
    else
        local step = S.Steps[self.step]
        line("Step " .. self.step .. " of " .. #S.Steps .. ": " .. step.heading, HEAD)
        line("")
        line(step.guide)
        if step.id == "mode" then
            local guide = S.ModeGuides[d.mode or S.CUSTOM]
            if guide then
                line("")
                line("About " .. S.ModeLabel(d.mode), HEAD)
                line(guide.guide)
            end
        end
        if not self:editable() then
            line("")
            line("This event is " .. S.StatusLabel(d.status) .. ". Its settings are locked until it finishes and is reset on the Launch step.", WARN)
        end

        local here = step.id == "launch" and self.issues or S.IssuesForStep(self.issues, step.id)
        local blocking, tips = {}, {}
        for _, issue in ipairs(here) do
            if issue.tip then tips[#tips + 1] = issue else blocking[#blocking + 1] = issue end
        end
        line("")
        if #blocking > 0 then
            line(step.id == "launch" and "Still needed before it can run:" or "Still needed on this step:", WARN)
            for _, issue in ipairs(blocking) do
                local where = step.id == "launch" and (S.Steps[S.StepIndex(issue.step)].title .. ": ") or ""
                line("- " .. where .. issue.text, WARN)
            end
        elseif step.id ~= "launch" then
            line("Nothing missing on this step.", GOOD)
        end
        if #tips > 0 then
            line("")
            line("Tips:", MUTED)
            for _, issue in ipairs(tips) do line("- " .. issue.text, MUTED) end
        end
        if step.id ~= "launch" then
            local elsewhere = {}
            for index, other in ipairs(S.Steps) do
                local count = S.Blocking(S.IssuesForStep(self.issues, other.id))
                if other.id ~= step.id and count > 0 then elsewhere[#elsewhere + 1] = index .. " " .. other.title .. " (" .. count .. ")" end
            end
            if #elsewhere > 0 then
                line("")
                line("Other steps still need attention: " .. table.concat(elsewhere, ", ") .. ".", MUTED)
            end
        end
    end
    self.guide:setText(table.concat(parts))
    self.guide:paginate()
    self.guide:setYScroll(0)
end

function W:refreshActivity()
    if not self.activity then return end
    local parts = { rgb(HEAD) .. " Activity (newest first) <LINE> " }
    if #self.log == 0 then
        parts[#parts + 1] = rgb(MUTED) .. " What the server says about your changes appears here. <LINE> "
    end
    for _, entry in ipairs(self.log) do
        parts[#parts + 1] = rgb(LEVEL_COLORS[entry.level] or WHITE) .. rich(entry.text) .. " <LINE> "
    end
    self.activity:setText(table.concat(parts))
    self.activity:paginate()
    self.activity:setYScroll(0)
end

------------------------------------------------------------
-- FORM BUILDING
--
-- A cursor (fx, fy, fw) walks down the form pane. Every widget added
-- is removed on the next rebuild.
------------------------------------------------------------

function W:clearForm()
    for _, widget in ipairs(self.formWidgets) do self.form:removeChild(widget) end
    self.formWidgets, self.binders = {}, {}
end

function W:add(widget)
    self.form:addChild(widget)
    self.formWidgets[#self.formWidgets + 1] = widget
    return widget
end

function W:bind(fn) self.binders[#self.binders + 1] = fn end

function W:labelWidth() return math.min(170, math.floor(self.fw * 0.36)) end

function W:heading(text)
    self.fy = self.fy + (self.fy > PAD and 8 or 0)
    local label = ISLabel:new(self.fx, self.fy, ROW, text, HEAD[1], HEAD[2], HEAD[3], 1, UIFont.Medium, true)
    label:initialise()
    self:add(label)
    local rule = ISPanel:new(self.fx, self.fy + ROW + 2, self.fw, 1)
    rule:initialise()
    rule.backgroundColor = { r = HEAD[1], g = HEAD[2], b = HEAD[3], a = 0.35 }
    rule.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    self:add(rule)
    self.fy = self.fy + ROW + 10
end

-- Wrapped, non-interactive text.
function W:text(text, color, x, width)
    x, width = x or self.fx, width or self.fw
    local panel = ISRichTextPanel:new(x, self.fy, width, ROW)
    panel:initialise()
    panel.background = false
    panel.autosetheight = false
    panel:setMargins(0, 0, 0, 0)
    panel:setText(rgb(color or WHITE) .. rich(text))
    panel:paginate()
    local height = math.max(panel:getHeight(), wrappedHeight(text, width))
    panel:setHeight(height)
    panel.onMouseWheel = function() return false end
    self:add(panel)
    self.fy = self.fy + height + GAP
    return panel
end

function W:rowLabel(text)
    local label = ISLabel:new(self.fx, self.fy + 2, ROW - 4, text, 0.85, 0.85, 0.85, 1, UIFont.Small, true)
    label:initialise()
    self:add(label)
end

-- Where a field goes: after its label on the same row, or full width.
function W:slot(label, width)
    if label then
        self:rowLabel(label)
        local x = self.fx + self:labelWidth()
        return x, math.min(width or 9999, self.fx + self.fw - x)
    end
    return self.fx, math.min(width or 9999, self.fw)
end

function W:entry(label, value, opts)
    opts = opts or {}
    local x, width = self:slot(label, opts.width)
    local height = opts.height or (ROW - 2)
    local entry = ISTextEntryBox:new(tostring(value or ""), x, self.fy, width, height)
    entry:initialise()
    entry:instantiate()
    if opts.numbers and entry.setOnlyNumbers then entry:setOnlyNumbers(true) end
    if opts.multiline then
        entry:setMultipleLine(true)
        entry:setMaxLines(64)
        entry:addScrollBars()
    end
    if opts.tooltip then entry.tooltip = opts.tooltip end
    self:add(entry)
    if not opts.sameRow then self.fy = self.fy + height + GAP end
    return entry, x + width
end

-- Binds an entry, but only writes when its text actually changed, so
-- merely visiting a step never makes the event look edited.
function W:bindEntry(entry, write)
    local initial = entry:getText()
    self:bind(function(d)
        local text = entry:getText()
        if text ~= initial then write(d, text) end
    end)
end

function W:combo(label, list, selected, onChange, opts)
    opts = opts or {}
    local x, width = self:slot(label, opts.width)
    local combo = ISComboBox:new(x, self.fy, width, ROW, self, W.onComboChanged)
    local selectedIndex = 1
    for index, option in ipairs(list) do
        combo:addOptionWithData(option.text, option.value)
        if option.value == selected then selectedIndex = index end
    end
    combo:setSelected(selectedIndex)
    combo:initialise()
    combo:instantiate()
    combo.studioChange = onChange
    self:add(combo)
    self.fy = self.fy + ROW + GAP
    return combo
end

function W:onComboChanged(combo)
    if combo.studioChange then combo.studioChange(self, comboValue(combo)) end
end

-- A tick box with one option per text; onChange(self, tick) runs when
-- any of them is clicked.
function W:ticks(texts, selected, onChange, x)
    x = x or self.fx
    local tick = ISTickBox:new(x, self.fy, TICK, TICK, "", self, W.onTickChanged)
    tick:initialise()
    tick:instantiate()
    for index, text in ipairs(texts) do
        tick:addOption(text)
        tick.selected[index] = selected[index] == true
    end
    tick:setWidth(self.fx + self.fw - x)
    tick.changeOptionArgs = { tick }
    tick.studioChange = onChange
    self:add(tick)
    self.fy = self.fy + math.max(ROW, tick:getHeight()) + GAP
    return tick
end

function W:tick(text, selected, onChange)
    return self:ticks({ text }, { selected == true }, onChange)
end

function W:onTickChanged(index, selected, tick)
    if tick and tick.studioChange then tick.studioChange(self, tick, index, selected) end
end

function W:button(title, callback, opts)
    opts = opts or {}
    local x = opts.x or self.fx
    local width = opts.width or self.fw
    local height = opts.height or ROW + 2
    local button = ISButton:new(x, self.fy, width, height, title, self, callback)
    button:initialise()
    button:instantiate()
    button.internal = opts.internal
    if opts.tooltip then button.tooltip = opts.tooltip end
    if opts.selected then
        button.backgroundColor = { r = 0.32, g = 0.20, b = 0.48, a = 1 }
        button.borderColor = { r = HEAD[1], g = HEAD[2], b = HEAD[3], a = 1 }
    end
    if opts.enabled == false then button:setEnable(false) end
    self:add(button)
    if not opts.sameRow then self.fy = self.fy + height + GAP end
    return button
end

-- Buttons side by side: { { title, callback, opts }, ... }.
function W:buttonRow(list)
    local width = math.floor((self.fw - GAP * (#list - 1)) / #list)
    local y = self.fy
    for index, entry in ipairs(list) do
        self.fy = y
        local opts = entry[3] or {}
        opts.x, opts.width, opts.sameRow = self.fx + (index - 1) * (width + GAP), width, true
        self:button(entry[1], entry[2], opts)
    end
    self.fy = y + ROW + 2 + GAP
end

-- A search box listing matching items; clicking one calls onPick(self, fullType).
function W:itemSearch(placeholder, onPick)
    local entry = self:entry(nil, "", { tooltip = placeholder })
    if entry.setPlaceholderText then entry:setPlaceholderText(placeholder) end
    local results = {}
    for index = 1, SEARCH_RESULTS do
        local button = self:button("", W.onSearchPick, { height = ROW - 2 })
        button:setVisible(false)
        button.studioPick = onPick
        results[index] = button
    end
    entry.onTextChange = function()
        local found = searchItems(entry:getText())
        for index, button in ipairs(results) do
            local item = found[index]
            button:setVisible(item ~= nil)
            if item then
                button.internal = item.fullType
                button:setTitle(fit(tostring(item.name) .. "   (" .. item.fullType .. ")", button.width - 12))
            end
        end
    end
end

function W:onSearchPick(button)
    if button.studioPick and button.internal then button.studioPick(self, button.internal) end
end

function W:buildForm()
    self:clearForm()
    self.fx, self.fy = PAD, PAD
    self.fw = self.form.width - PAD * 2 - 14
    self.formWidth = self.form.width
    local d = self:draft()
    if self.view == "past" and not d then
        self:buildPast()
    elseif not d then
        self:buildWelcome()
    else
        local step = S.Steps[self.step]
        local lockedStep = not self:editable() and step.id ~= "launch" and step.id ~= "players"
        if lockedStep then
            self:heading(step.heading)
            self:text("This event is " .. S.StatusLabel(d.status) .. ", so its settings are locked. Reset it on the Launch step when it has finished to edit it again.", WARN)
            self:text(table.concat(S.Summary(d, step.id), "\n"))
            if step.id == "rewards" then self:buildAwards() end
        else
            W.Builders[step.id](self, d)
        end
    end
    self.form:setScrollHeight(math.max(self.fy + PAD, self.form.height))
end

------------------------------------------------------------
-- STEP BUILDERS
------------------------------------------------------------

W.Builders = {}

function W:buildPast()
    local record = self.pastRecord
    if not record then
        self:heading("Past events")
        self:text(#self.history == 0 and "Nothing has run yet. Events appear here when they end, however they end."
            or "Pick a run on the left to see how it went.", MUTED)
        return
    end
    self:heading(tostring(record.name))
    local color = W.OUTCOME_COLORS[record.outcome] or WHITE
    self:text((W.OUTCOME_LABELS[record.outcome] or tostring(record.outcome)) .. (record.result and (": " .. record.result) or ""), color)
    local lines = {}
    lines[#lines + 1] = "Mode: " .. S.ModeLabel(record.mode) .. (record.variant and (" (" .. tostring(record.variant) .. ")") or "")
    if record.day then lines[#lines + 1] = "Ended on day " .. record.day end
    if record.startedAtMs and record.endedAtMs then
        lines[#lines + 1] = "Ran for " .. math.max(0, math.floor((record.endedAtMs - record.startedAtMs) / 60000)) .. " minutes"
    end
    if record.difficulty then lines[#lines + 1] = "Difficulty: " .. tostring(record.difficulty) end
    lines[#lines + 1] = "Players (" .. #(record.participants or {}) .. "): " .. (#(record.participants or {}) > 0 and table.concat(record.participants, ", ") or "none")
    lines[#lines + 1] = "Winners: " .. (#(record.winners or {}) > 0 and table.concat(record.winners, ", ") or "none")
    lines[#lines + 1] = "Deaths: " .. tostring(record.deaths or 0)
    self:text(table.concat(lines, "\n"))
    if self:definition(record.definitionId) then
        self:button("Open this event", W.onOpenPast, { height = 30, internal = record.definitionId,
            tooltip = "Edit it or run it again" })
    else
        self:text("The event itself has since been deleted.", MUTED)
    end
end

function W:onOpenPast(button)
    self.view = "saved"
    self.pastRecord = nil
    self:select(button.internal)
end

function W:buildWelcome()
    self:heading("Welcome")
    self:text("Build an event in nine short steps. Each step says what to do on the right, and the step bar turns green once a step has everything it needs.")
    self:button("+ Create a new event", W.onNew, { height = 36 })
    if #self.definitions > 0 then
        self:text("Or pick one of your " .. #self.definitions .. " events on the left to carry on.", MUTED)
    else
        self:text("No events yet.", MUTED)
    end
end

W.Builders.mode = function(self, d)
    self:heading("Event name")
    local name = self:entry(nil, d.name, { tooltip = "Shown to players in announcements and prompts" })
    self:bindEntry(name, function(dd, text) dd.name = text end)

    self:heading("Classic scenarios")
    self:text("Pillow's Random Scenarios, ready to run: each sets the mode, how players start, the difficulty roll, the threats and the briefing. Or build your own from a game mode below.", MUTED)
    for _, id in ipairs(Shared.EventClassicScenarioOrder or {}) do
        local template = Shared.EventClassicScenarios[id]
        self:button(template.label .. ":  " .. template.summary, W.onPickScenario, { internal = id, selected = d.classicScenario == id, height = 28 })
    end

    self:heading("Game mode")
    local current = d.mode or S.CUSTOM
    for _, key in ipairs(S.ModeKeys()) do
        local guide = S.ModeGuides[key] or {}
        self:button(S.ModeLabel(key) .. ":  " .. (guide.summary or ""), W.onPickMode,
            { internal = key, selected = key == current, height = 28 })
    end

    if not d.mode then
        local recipes = { { text = "(choose one to fill in the steps)", value = nil } }
        for _, key in ipairs(Shared.EventScenarioPresetOrder or {}) do
            local preset = (Shared.EventScenarioPresets or {})[key]
            if preset and not preset.random then recipes[#recipes + 1] = { text = preset.label, value = key } end
        end
        self:combo("Starting recipe", recipes, nil, function(studio, value)
            if not value then return end
            studio:change(function(dd) S.ApplyPreset(dd, value) end)
            studio:note("Filled the steps from the " .. tostring(Shared.EventScenarioPresets[value].label) .. " recipe.")
        end)
    end

    local order, labels = S.Variants(d.mode)
    if order then
        self:combo("Variant", options(order, labels), d.variant, function(studio, value)
            studio:change(function(dd)
                if dd.mode == "EXTRACTION" then S.ApplyMode(dd, dd.mode, value) else dd.variant = value end
            end)
        end)
    end

    self:heading("How players start")
    local loadouts = {}
    for _, key in ipairs(Shared.EventLoadoutOrder or {}) do loadouts[#loadouts + 1] = { text = Shared.EventLoadouts[key].label, value = key } end
    self:combo("Starting loadout", loadouts, d.loadout or "NONE",
        function(studio, value) studio:change(function(dd) dd.loadout = value or "NONE" end) end)
    local loadout = Shared.EventLoadouts[d.loadout or "NONE"]
    local stripped = not loadout.keepGear and (d.loadout or "NONE") ~= "NONE"
    self:text(loadout.summary .. (stripped and " Their own gear is held safe and returned at the end." or ""), MUTED)
    if d.mode == "SURVIVOR_RUN" then
        self:tick("Last one standing wins (elimination, like Dodgeball of the Dead)", d.survivorConfig.lastStanding,
            function(studio, tick) studio:change(function(dd) dd.survivorConfig.lastStanding = tick.selected[1] == true end) end)
    end

    if S.UsesRounds(d.mode) then
        local rounds = self:entry("Rounds (1-" .. S.MAX_ROUNDS .. ")", tostring(d.maxRounds or 1), { numbers = true, width = 60 })
        self:bindEntry(rounds, function(dd, text)
            dd.maxRounds = math.max(1, math.min(S.MAX_ROUNDS, math.floor(tonumber(text) or 1)))
        end)
    end

    if S.UsesTeams(d.mode, d.variant) then
        self:heading("Teams")
        local y = self.fy
        local count, afterX = self:entry("Number of teams", tostring(math.max(2, #d.teams)), { numbers = true, width = 60, sameRow = true })
        self.teamCountEntry = count
        self:button("Set teams", W.onSetTeams, { x = afterX + GAP, width = 110, sameRow = true,
            tooltip = "Rebuilds the teams and spreads the current roster across them" })
        self.fy = y + ROW + GAP
        if #d.teams == 0 then
            self:text("No teams yet. Set the number and press Set teams.", WARN)
        end
        for _, team in ipairs(d.teams) do
            local members = {}
            for username in pairs(team.members or {}) do members[#members + 1] = username end
            table.sort(members)
            local color = team.color and { team.color.r or 1, team.color.g or 1, team.color.b or 1 } or WHITE
            self:text(tostring(team.name) .. ": " .. (#members > 0 and table.concat(members, ", ") or "no players yet"), color)
        end
    end

    if d.mode == "CAPTURE" then
        self:heading("Flag")
        local flag = self:entry("Flag item", d.captureConfig.flagItemFullType, { tooltip = "Full item type, e.g. Base.Hat_Beret" })
        self:bindEntry(flag, function(dd, text) dd.captureConfig.flagItemFullType = text end)
        self:itemSearch("Search items to use as the flag...", function(studio, fullType)
            studio:change(function(dd) dd.captureConfig.flagItemFullType = fullType end)
        end)
        local seconds = self:entry("Lost flag returns after (s)", tostring(d.captureConfig.autoReturnSeconds), { numbers = true, width = 80 })
        self:bindEntry(seconds, function(dd, text) dd.captureConfig.autoReturnSeconds = tonumber(text) or 90 end)
    end

    if d.mode == "OLYMPICS" then
        self:heading("The Games")
        local disciplines = options(Shared.EventOlympicDisciplineOrder, {})
        for _, option in ipairs(disciplines) do option.text = Shared.EventOlympicDisciplines[option.value].label end
        self:combo("Course", disciplines, d.olympicsConfig.discipline or "OBSTACLE",
            function(studio, value) studio:change(function(dd) dd.olympicsConfig.discipline = value end) end)
        local discipline = Shared.EventOlympicDisciplines[d.olympicsConfig.discipline or "OBSTACLE"]
        if discipline then
            local plan = {}
            for index, task in ipairs(discipline.stations) do plan[index] = taskLabel(task) end
            self:text(discipline.summary .. "  Course: start > " .. (#plan > 0 and (table.concat(plan, " > ") .. " > ") or "") .. "finish.", MUTED)
        end
        local heat = self:entry("Racers per heat (1-4)", tostring(d.olympicsConfig.heatSize), { numbers = true, width = 60 })
        self:bindEntry(heat, function(dd, text) dd.olympicsConfig.heatSize = math.max(1, math.min(4, math.floor(tonumber(text) or 2))) end)
        local limit = self:entry("Heat time limit (minutes)", minutesOf(d.olympicsConfig.heatLimitSeconds), { numbers = true, width = 60,
            tooltip = "An athlete still on the course after this is a DNF" })
        self:bindEntry(limit, function(dd, text) dd.olympicsConfig.heatLimitSeconds = math.max(1, math.floor(tonumber(text) or 10)) * 60 end)
    end

    self:heading("Modifier")
    local compatible, why = S.NakedCompatible(d.mode, d.variant)
    if compatible then
        self:tick("Naked and Afraid: joining strips all gear into escrow", d.modifiers.NAKED_AND_AFRAID == true,
            function(studio, tick) studio:change(function(dd) dd.modifiers.NAKED_AND_AFRAID = tick.selected[1] == true end) end)
    else
        self:text("Naked and Afraid is not available: " .. why, MUTED)
    end
end

W.Builders.area = function(self, d)
    self:heading("How big is it?")
    for _, scope in ipairs(Shared.EventScopeTypeOrder or { "ZONE" }) do
        self:button(tostring((Shared.EventScopeTypeLabels or {})[scope] or scope) .. ":  " .. (S.ScopeHelp[scope] or ""),
            W.onPickScope, { internal = scope, selected = d.scopeType == scope, height = 28 })
    end

    local template = d.classicScenario and (Shared.EventClassicScenarios or {})[d.classicScenario]
    if template and template.venue then
        self:heading("Original location")
        self:text(template.label .. " happened at " .. template.venue.label .. ". One click sets it up there: "
            .. (template.venue.zone and "the zone, " or "") .. "the start point and any exits and ambushes. Move anything afterwards if you like.", MUTED)
        self:button("Set up at " .. template.venue.label, W.onSetUpVenue, { height = 30 })
    end

    if d.scopeType == "ZONE" then
        self:heading("Event zone")
        self:text(d.zoneId and "Zone drawn. Draw again to replace it." or "No zone yet.", d.zoneId and GOOD or WARN)
        self:buttonRow({
            { "Draw zone on map", W.onDrawZone, { tooltip = "Click two opposite corners on the map" } },
            { "Use area around me", W.onZoneAroundMe, { tooltip = "An " .. (AREA_RADIUS * 2) .. " x " .. (AREA_RADIUS * 2) .. " square centred on you" } },
        })
    end

    self:heading("Hotspots")
    local need = S.NextHotspotNeeded(d)
    if need then
        self:text("Next needed: " .. S.DescribeHotspotNeed(need), WARN)
        self:buttonRow({
            { "Draw it on the map", W.onDrawNeeded },
            { "Place all needed around me", W.onPlaceAllNeeded, { tooltip = "Drops every missing hotspot at random within " .. (AREA_RADIUS - HOTSPOT_MARGIN) .. " tiles of you" } },
        })
    elseif S.UsesTeams(d.mode, d.variant) and #d.teams < 2 then
        self:text("Create the teams on the Mode step first; each team needs its own base.", WARN)
    else
        self:text("Every hotspot this mode needs is placed.", GOOD)
    end

    local active = 0
    for _, hotspot in ipairs(d.hotspots) do
        if hotspot.active ~= false then
            active = active + 1
            local y = self.fy
            self:button("Delete", W.onDeleteHotspot, { internal = hotspot.id, x = self.fx + self.fw - 70, width = 70, sameRow = true, height = ROW - 2 })
            self:text(describeHotspot(d, hotspot), WHITE, self.fx, self.fw - 80)
            self.fy = math.max(self.fy, y + ROW + 2)
        end
    end
    if active == 0 then self:text("No hotspots placed yet.", MUTED) end

    if d.mode == "OLYMPICS" then
        self:buildCourseEditor(d)
        return
    end

    self:heading("Add another hotspot")
    local types = options(Shared.EventHotspotTypeOrder, Shared.EventHotspotTypeLabels)
    self.newHotspotType = self.newHotspotType or (types[1] and types[1].value)
    self:combo("Type", types, self.newHotspotType, function(studio, value)
        studio.newHotspotType = value
        studio:rebuild()
    end)
    self:text(S.HotspotHelp[self.newHotspotType] or "", MUTED)
    self.hotspotCountEntry = nil
    if self.newHotspotType == "ZOMBIE_AMBUSH" then
        self.hotspotCountEntry = self:entry("Zombies waiting", "8", { numbers = true, width = 60, tooltip = "Doubled on Dire, tripled on Brutal" })
    elseif self.newHotspotType == "BANDIT_CAMP" then
        self.hotspotCountEntry = self:entry("Bandits in the crew", "4", { numbers = true, width = 60, tooltip = "1 to 12. Tougher on Dire and Brutal" })
    end
    self.hotspotRoundEntry = self:entry("Round (optional)", "", { numbers = true, width = 60 })
    self.hotspotTeamCombo = nil
    if #d.teams > 0 then
        self.hotspotTeamCombo = self:combo("Team", options({}, {}, { text = "(none)", value = nil }), nil, nil)
        for _, team in ipairs(d.teams) do self.hotspotTeamCombo:addOptionWithData(team.name or team.id, team.id) end
    end
    self.hotspotTextEntry, self.hotspotScopeCombo = nil, nil
    if self.newHotspotType == "NARRATIVE_LOCATION" then
        self.hotspotTextEntry = self:entry("Text shown", "")
        self.hotspotScopeCombo = self:combo("Shown to", {
            { text = "Each player, when they arrive", value = "LOCAL" },
            { text = "Everyone, the first time anyone arrives", value = "GLOBAL" },
        }, "LOCAL", nil)
        if self.hotspotReplayable == nil then self.hotspotReplayable = true end
        self:tick("Players can replay it later (a clue button on their HUD)", self.hotspotReplayable,
            function(studio, tick) studio.hotspotReplayable = tick.selected[1] == true end)
        self.hotspotClueTitleEntry = self:entry("Button label", "", { tooltip = "Optional, e.g. Diary page. Defaults to Clue 1, Clue 2..." })
    end
    self:button("Draw on map", W.onDrawHotspot)
end

-- The Olympics: add an extra station of any task to the course.
function W:buildCourseEditor(d)
    self:heading("Add a station")
    self:text("Stations are raced in number order. The template's stations are offered above one by one; add more here.", MUTED)
    local tasks = {}
    for _, task in ipairs(Shared.EventOlympicTaskOrder or {}) do tasks[#tasks + 1] = { text = taskLabel(task), value = task } end
    self.newStationTask = self.newStationTask or "CHECKPOINT"
    self:combo("Task", tasks, self.newStationTask, function(studio, value)
        studio.newStationTask = value
        studio:rebuild()
    end)
    local defaults = S.StationMetadata(self.newStationTask)
    self:text(tostring(((Shared.EventOlympicTasks or {})[self.newStationTask] or {}).verb or ""), MUTED)
    local highest = 0
    for _, station in ipairs(S.OlympicStations(d)) do highest = math.max(highest, tonumber(station.roundNumber) or 0) end
    self.stationNumberEntry = self:entry("Station number", tostring(highest + 1), { numbers = true, width = 60 })
    self.stationItemEntry, self.stationCountEntry, self.stationKitEntry = nil, nil, nil
    if self.newStationTask == "CHOP" or self.newStationTask == "CRAFT" or self.newStationTask == "CARRY" then
        self.stationItemEntry = self:entry(self.newStationTask == "CARRY" and "Heavy load item" or "Item to bring back", defaults.itemType or "")
    end
    if self.newStationTask ~= "CHECKPOINT" then
        self.stationCountEntry = self:entry(self.newStationTask == "SHOOT" and "Targets" or "How many", tostring(defaults.count or 1), { numbers = true, width = 60 })
    end
    if self.newStationTask == "CHOP" or self.newStationTask == "CRAFT" or self.newStationTask == "SHOOT" then
        self.stationKitEntry = self:entry("Kit handed out", table.concat(defaults.kit or {}, ", "),
            { tooltip = "Full item types, separated by commas. Taken back after the heat." })
    end
    self:button("Draw this station on the map", W.onDrawStation)
    self:heading("Drop zones, target ranges and lines")
    self:text("A heavy-lift station needs a drop zone and a shooting station a target range with the same number. The start and finish lines are one each.", MUTED)
    self:buttonRow({
        { "Draw start line", W.onDrawCoursePart, { internal = "OLYMPIC_START" } },
        { "Draw finish line", W.onDrawCoursePart, { internal = "OLYMPIC_FINISH" } },
    })
    self:buttonRow({
        { "Drop zone for station #", W.onDrawCoursePart, { internal = "OLYMPIC_DROP" } },
        { "Targets for station #", W.onDrawCoursePart, { internal = "OLYMPIC_TARGETS" } },
    })
end

function W:onDrawStation()
    local task = self.newStationTask or "CHECKPOINT"
    local metadata = S.StationMetadata(task)
    local number = math.max(1, math.floor(tonumber(self.stationNumberEntry and self.stationNumberEntry:getText()) or 1))
    if self.stationItemEntry then metadata.itemType = S.Trim(self.stationItemEntry:getText()) end
    if self.stationCountEntry then metadata.count = math.max(1, math.floor(tonumber(self.stationCountEntry:getText()) or 1)) end
    if self.stationKitEntry then
        metadata.kit = {}
        for fullType in tostring(self.stationKitEntry:getText()):gmatch("[^,]+") do
            if S.Trim(fullType) ~= "" then metadata.kit[#metadata.kit + 1] = S.Trim(fullType) end
        end
    end
    if (task == "CHOP" or task == "CRAFT" or task == "CARRY") and (metadata.itemType or "") == "" then
        self:note("Set the item this station asks for.", "warn")
        return
    end
    self:drawHotspot("OLYMPIC_STATION", number, nil, metadata)
end

-- Start/finish lines, or a drop zone / target range for the station
-- number typed above.
function W:onDrawCoursePart(button)
    local number = nil
    if button.internal == "OLYMPIC_DROP" or button.internal == "OLYMPIC_TARGETS" then
        number = math.max(1, math.floor(tonumber(self.stationNumberEntry and self.stationNumberEntry:getText()) or 1))
    end
    self:drawHotspot(button.internal, number, nil, nil)
end

W.Builders.rules = function(self, d)
    self:heading("Combat")
    self:combo("Who can hurt whom", options(Shared.EventRuleTypeOrder, Shared.EventRuleTypeLabels), d.ruleType,
        function(studio, value) studio:change(function(dd) dd.ruleType = value end) end)
    self:text(S.RuleHelp[d.ruleType] or "", MUTED)
    self:tick("Players may leave the event area", d.combatRules.allowLeaveZone == true,
        function(studio, tick) studio:change(function(dd) dd.combatRules.allowLeaveZone = tick.selected[1] == true end) end)
    if d.ruleType == "CUSTOM" then
        self:tick("Allow PvP damage", d.combatRules.pvpAllowedInZone == true,
            function(studio, tick) studio:change(function(dd) dd.combatRules.pvpAllowedInZone = tick.selected[1] == true end) end)
    end

    self:heading("Clock")
    self:combo("Timer", options(Shared.EventTimerTypeOrder, Shared.EventTimerTypeLabels), d.timerType,
        function(studio, value) studio:change(function(dd) S.SetTimer(dd, value) end) end)
    self:text(S.TimerHelp[d.timerType] or "", MUTED)

    local required = (d.timerType ~= "NONE" and d.timerType ~= "ROUND_TIMER") or d.mode == "SURVIVOR_RUN"
    if not required then
        self:tick("End the event after a set time anyway", d.duration.enabled == true,
            function(studio, tick) studio:change(function(dd) dd.duration.enabled = tick.selected[1] == true end) end)
    end
    if required or d.duration.enabled then
        local minutes = self:entry("Event length (minutes)", minutesOf(d.duration.durationSeconds), { numbers = true, width = 70 })
        self:bindEntry(minutes, function(dd, text)
            dd.duration.durationSeconds = math.max(0, math.floor(tonumber(text) or 0)) * 60
        end)
        if required then self:bind(function(dd) dd.duration.enabled = true end) end
        self:combo("When time runs out", options(Shared.EventTimerExpiryBehaviorOrder, Shared.EventTimerExpiryBehaviorLabels),
            d.duration.expiryBehavior, function(studio, value) studio:change(function(dd) dd.duration.expiryBehavior = value end) end)
    end
    if d.timerType == "ROUND_TIMER" then
        local minutes = self:entry("Round length (minutes)", minutesOf(d.roundDuration.durationSeconds), { numbers = true, width = 70 })
        self:bindEntry(minutes, function(dd, text)
            dd.roundDuration.enabled = true
            dd.roundDuration.durationSeconds = math.max(0, math.floor(tonumber(text) or 0)) * 60
        end)
    end

    self:heading("Weather and light (optional)")
    local unchanged = { text = "(leave as it is)", value = nil }
    self:combo("Time of day", {
        unchanged, { text = "Day", value = "DAY" }, { text = "Night", value = "NIGHT" },
        { text = "Dusk", value = "DUSK" }, { text = "Dawn", value = "DAWN" },
    }, d.environment.timeOfDay, function(studio, value) studio:change(function(dd) dd.environment.timeOfDay = value end) end)
    self:combo("Weather", {
        unchanged, { text = "Clear", value = "CLEAR" }, { text = "Rain", value = "RAIN" },
        { text = "Storm", value = "STORM" }, { text = "Fog", value = "FOG" },
    }, d.environment.weatherPreset, function(studio, value) studio:change(function(dd) dd.environment.weatherPreset = value end) end)
end

W.Builders.zombies = function(self, d)
    self:heading("How zombies arrive")
    for _, directorType in ipairs(Shared.EventDirectorTypeOrder or {}) do
        self:button(tostring((Shared.EventDirectorTypeLabels or {})[directorType] or directorType) .. ":  " .. (S.DirectorHelp[directorType] or ""),
            W.onPickDirector, { internal = directorType, selected = d.directorType == directorType, height = 28 })
    end
    if d.directorType ~= "ZOMBIE_WAVES" then
        self:tick("Let the director act on its own (off: only your Director buttons spawn zombies)", d.spawnRules.escalationEnabled == true,
            function(studio, tick) studio:change(function(dd) dd.spawnRules.escalationEnabled = tick.selected[1] == true end) end)
    end

    self:heading("Difficulty")
    local difficulties = {}
    for _, key in ipairs(Shared.EventDifficultyOrder or {}) do difficulties[#difficulties + 1] = { text = Shared.EventDifficulties[key].label, value = key } end
    self:combo("Difficulty", difficulties, d.difficulty or "NORMAL",
        function(studio, value) studio:change(function(dd) dd.difficulty = value end) end)
    self:text("Dire doubles and Brutal triples zombie numbers, sieges and ambushes, and makes starting injuries worse. Random rolls it at the start as Pillow does (half the time Dire, a quarter of those Brutal) and announces it.", MUTED)

    self:heading("Threats")
    for _, threat in ipairs(Shared.EventThreatOrder or {}) do
        local info = Shared.EventThreats[threat]
        self:tick(info.label .. ": " .. info.help, d.threats[threat] == true,
            function(studio, tick) studio:change(function(dd) dd.threats[threat] = tick.selected[1] == true end) end)
    end
    self:text("Rooms full of waiting zombies are Zombie Ambush hotspots, placed on the Area step.", MUTED)

    self:heading("Look and range")
    self:combo("Zombie theme", options(Shared.EventZombieThemeOrder, Shared.EventZombieThemeLabels), d.zombieTheme.themeId or "RANDOM",
        function(studio, value) studio:change(function(dd) dd.zombieTheme = { themeId = value or "RANDOM" } end) end)
    local radius = self:entry("Spawn radius (tiles)", tostring(d.spawnRules.baseSpawnRadius), { numbers = true, width = 70,
        tooltip = "How far from players new zombies appear" })
    self:bindEntry(radius, function(dd, text) dd.spawnRules.baseSpawnRadius = tonumber(text) or 40 end)
end

local function conditionFits(condition, objectiveTypes)
    local supported = condition.objectiveTypes or {}
    if #supported == 0 or #objectiveTypes == 0 then return true end
    for _, wanted in ipairs(supported) do
        for _, chosen in ipairs(objectiveTypes) do
            if wanted == chosen then return true end
        end
    end
    return false
end

local function readParam(field, text)
    local value = text
    if field.type == "integer" then value = math.floor(tonumber(text) or 0) end
    if field.type == "number" then value = tonumber(text) or 0 end
    if type(value) == "number" and field.min ~= nil then value = math.max(tonumber(field.min) or value, value) end
    if type(value) == "number" and field.max ~= nil then value = math.min(tonumber(field.max) or value, value) end
    return value
end

W.Builders.goals = function(self, d)
    local required = S.RequiredObjectives(d)
    local function enumTicks(order, labels, chosen, suffixFor, write)
        local texts, selected, set = {}, {}, {}
        for _, value in ipairs(chosen) do set[value] = true end
        for index, value in ipairs(order or {}) do
            texts[index] = tostring((labels or {})[value] or value) .. (suffixFor and suffixFor(value) or "")
            selected[index] = set[value] == true
        end
        self:ticks(texts, selected, function(studio, tick)
            studio:change(function(dd)
                local list = {}
                for index, value in ipairs(order) do
                    if tick.selected[index] then list[#list + 1] = value end
                end
                write(dd, list)
            end)
        end)
    end

    self:heading("What players do")
    enumTicks(Shared.EventObjectiveTypeOrder, Shared.EventObjectiveTypeLabels, d.objectiveTypes,
        function(value) return required[value] and "   (needed by " .. S.ModeLabel(d.mode) .. ")" or "" end,
        function(dd, list) dd.objectiveTypes = list end)

    self:heading("How the winner is decided")
    enumTicks(Shared.EventOutcomeTypeOrder, Shared.EventOutcomeTypeLabels, d.outcomeTypes, nil,
        function(dd, list) dd.outcomeTypes = list end)

    self:heading("Automatic end checks (optional)")
    local metadata = self.metadata[d.eventType or "HORDE_SURVIVAL"]
    if not metadata then
        self:text("Loading the checks this event type supports...", MUTED)
        return
    end
    self:text("These end the event on their own. Leave them all off to end it with the timer or from the Director panel.", MUTED)
    local rows = {}
    local function addConditions(kind, available, saved, prefix)
        local savedById = {}
        for _, condition in ipairs(saved) do savedById[condition.conditionId] = condition end
        for _, condition in ipairs(available or {}) do
            if conditionFits(condition, d.objectiveTypes) then
                local chosen = savedById[condition.id]
                local tick = self:tick(prefix .. (condition.label or condition.id), chosen ~= nil, nil)
                local row = { kind = kind, id = condition.id, tick = tick, params = {} }
                for _, field in ipairs(condition.paramFields or {}) do
                    local value = chosen and chosen.params and chosen.params[field.key]
                    if value == nil then value = (condition.defaultParams or {})[field.key] end
                    self.fx = self.fx + 24
                    self.fw = self.fw - 24
                    local entry = self:entry((field.label or field.key), value ~= nil and tostring(value) or "",
                        { numbers = field.type == "integer" or field.type == "number", width = 90 })
                    self.fx = self.fx - 24
                    self.fw = self.fw + 24
                    row.params[#row.params + 1] = { field = field, entry = entry }
                end
                rows[#rows + 1] = row
            end
        end
    end
    addConditions("win", metadata.win, d.winConditions, "Win when: ")
    addConditions("fail", metadata.fail, d.failConditions, "Lose when: ")
    if #rows == 0 then self:text("No automatic checks fit the objectives you ticked.", MUTED) end
    self:bind(function(dd)
        local win, fail = {}, {}
        for _, row in ipairs(rows) do
            if row.tick.selected[1] then
                local params = {}
                for _, param in ipairs(row.params) do params[param.field.key] = readParam(param.field, param.entry:getText()) end
                local list = row.kind == "win" and win or fail
                list[#list + 1] = { conditionId = row.id, params = params }
            end
        end
        dd.winConditions, dd.failConditions = win, fail
    end)
end

W.Builders.story = function(self, d)
    self:heading("Briefing (shown when you announce)")
    local briefing = self:entry(nil, d.narrative.briefing, { multiline = true, height = 70 })
    self:bindEntry(briefing, function(dd, text) dd.narrative.briefing = text end)
    self:heading("Ending text")
    self:rowLabel("If players win")
    self.fy = self.fy + ROW
    local win = self:entry(nil, d.narrative.winText, { multiline = true, height = 48 })
    self:bindEntry(win, function(dd, text) dd.narrative.winText = text end)
    self:rowLabel("If players lose")
    self.fy = self.fy + ROW
    local fail = self:entry(nil, d.narrative.failText, { multiline = true, height = 48 })
    self:bindEntry(fail, function(dd, text) dd.narrative.failText = text end)

    self:heading("Player checklist")
    self:text("Each line is shown to participants as a goal.", MUTED)
    local notes = {}
    for index = 1, S.MAX_NOTE_ROWS do
        local note = d.objectiveNotes[index]
        notes[index] = self:entry(index .. ".", type(note) == "table" and note.text or note or "")
    end
    local initial = {}
    for index, entry in ipairs(notes) do initial[index] = entry:getText() end
    self:bind(function(dd)
        local changed, list = false, {}
        for index, entry in ipairs(notes) do
            local text = entry:getText()
            if text ~= initial[index] then changed = true end
            if S.Trim(text) ~= "" then list[#list + 1] = { text = text } end
        end
        if changed then dd.objectiveNotes = list end
    end)

    self:heading("Story stages (optional)")
    if #d.objectives == 0 then
        self:text("No stages. Without stages the event is driven only by its mode, timer and automatic checks.", MUTED)
    end
    for index, stage in ipairs(d.objectives) do
        local y = self.fy
        self:button("Remove", W.onRemoveStage, { internal = index, x = self.fx + self.fw - 80, width = 80, sameRow = true, height = ROW - 2 })
        self:text(index .. ". " .. (S.Trim(stage.name) ~= "" and stage.name or "Stage " .. index), WHITE, self.fx, self.fw - 90)
        self.fy = math.max(self.fy, y + ROW + 2)
        if #(stage.triggers or {}) == 0 then self:text("   no triggers yet", WARN) end
        for _, trigger in ipairs(stage.triggers or {}) do self:text("   " .. describeTrigger(d, trigger), MUTED) end
    end
    local y = self.fy
    local stageName, afterX = self:entry("New stage", "", { sameRow = true, width = math.floor(self.fw * 0.4) })
    self.newStageEntry = stageName
    self:button("Add stage", W.onAddStage, { x = afterX + GAP, width = 100, sameRow = true })
    self.fy = y + ROW + GAP

    if #d.objectives > 0 then
        self:heading("Add a trigger to a stage")
        local stages = {}
        for index, stage in ipairs(d.objectives) do
            stages[#stages + 1] = { text = index .. ". " .. (S.Trim(stage.name) ~= "" and stage.name or "Stage " .. index), value = index }
        end
        self.triggerStageCombo = self:combo("Stage", stages, math.min(self.triggerStage or 1, #stages), function(studio, value) studio.triggerStage = value end)
        self.triggerWhen = self.triggerWhen or "MANUAL"
        self:combo("Runs", TRIGGER_WHEN, self.triggerWhen, function(studio, value)
            studio.triggerWhen = value
            studio:rebuild()
        end)
        self.triggerHotspotCombo = nil
        if self.triggerWhen == "PROXIMITY" then
            local hotspots = {}
            for _, hotspot in ipairs(d.hotspots) do
                if hotspot.active ~= false then hotspots[#hotspots + 1] = { text = describeHotspot(d, hotspot), value = hotspot.id } end
            end
            if #hotspots == 0 then hotspots[1] = { text = "(place a hotspot on the Area step first)", value = nil } end
            self.triggerHotspotCombo = self:combo("Hotspot", hotspots, nil, nil)
        end
        self.triggerActionCombo = self:combo("Then", TRIGGER_ACTIONS, nil, nil)
        self.triggerParamEntry = self:entry("Text or count", "")
        self:button("Add trigger", W.onAddTrigger)
    end
end

W.Builders.rewards = function(self, d)
    self:heading("Prizes for the winner")
    local rows = {}
    for index, row in ipairs(d.rewards.items) do
        local y = self.fy
        local item = self:entry(nil, row.itemFullType or "", { sameRow = true, width = self.fw - 70 - 90 - GAP * 2 })
        local countX = self.fx + self.fw - 70 - 90 - GAP
        local count = ISTextEntryBox:new(tostring(row.count or 1), countX, y, 70, ROW - 2)
        count:initialise()
        count:instantiate()
        if count.setOnlyNumbers then count:setOnlyNumbers(true) end
        count.tooltip = "How many"
        self:add(count)
        self:button("Remove", W.onRemoveReward, { internal = index, x = self.fx + self.fw - 90, width = 90, sameRow = true, height = ROW - 2 })
        self.fy = y + ROW + GAP
        rows[index] = { item = item, count = count, initialItem = item:getText(), initialCount = count:getText() }
    end
    self:bind(function(dd)
        for index, row in ipairs(rows) do
            local target = dd.rewards.items[index]
            if target and (row.item:getText() ~= row.initialItem or row.count:getText() ~= row.initialCount) then
                target.itemFullType = row.item:getText()
                target.count = math.max(1, math.floor(tonumber(row.count:getText()) or 1))
            end
        end
    end)
    if #d.rewards.items == 0 then self:text("No prizes. Search below to add one.", MUTED) end
    if #d.rewards.items < S.MAX_REWARD_ROWS then
        self:text("Add a prize:", WHITE)
        self:itemSearch("Search items (e.g. axe, bandage)...", function(studio, fullType)
            studio:change(function(dd) dd.rewards.items[#dd.rewards.items + 1] = { itemFullType = fullType, count = 1 } end)
            studio:note("Added " .. fullType .. " to the prizes.")
        end)
    end

    self:heading("Delivery")
    self:combo("How winners get them", options(Shared.EventRewardDeliveryMethodOrder, Shared.EventRewardDeliveryMethodLabels),
        d.rewardDeliveryMethod, function(studio, value) studio:change(function(dd) dd.rewardDeliveryMethod = value end) end)
    self:text(S.DeliveryHelp[d.rewardDeliveryMethod] or "", MUTED)
    self:buildAwards()
end

function W:buildAwards()
    self:heading("Prizes waiting to be handed out")
    if not self.awardsRequested then
        self.awardsRequested = true
        send("EVENT_LIST_REWARDS", {})
    end
    local shown = 0
    for _, award in ipairs(self.awards) do
        if award.status ~= "ADMIN_DELIVERED" and shown < 8 then
            shown = shown + 1
            local items = {}
            for index, item in ipairs(award.items or {}) do
                if index > 3 then items[#items + 1] = "..." break end
                items[#items + 1] = tostring(item.count or 1) .. "x " .. tostring(item.displayName or item.itemFullType or "item")
            end
            local line = tostring(award.recipientUsername or "?") .. ": " .. table.concat(items, ", ")
                .. "  (" .. tostring(award.status or "?"):lower():gsub("_", " ") .. ")"
            local y = self.fy
            if award.status == "AWAITING_ADMIN_DELIVERY" then
                self:button("Mark delivered", W.onMarkDelivered, { internal = award.id, x = self.fx + self.fw - 120, width = 120, sameRow = true, height = ROW - 2 })
            end
            self:text(line, WHITE, self.fx, self.fw - 130)
            self.fy = math.max(self.fy, y + ROW + 2)
        end
    end
    if shown == 0 then self:text("Nothing waiting.", MUTED) end
    self:button("Refresh prize list", W.onRefreshAwards, { width = 160 })
end

W.Builders.players = function(self, d)
    self:heading("Roster (optional)")
    self:text("Leave this empty to invite everyone online when joining opens. Tick players and press Save roster to hand-pick instead.", MUTED)
    if self.onlinePlayers == nil then
        if not self.playersRequested then
            self.playersRequested = true
            send("EVENT_LIST_ONLINE_PLAYERS", {})
        end
        self:text("Loading online players...", MUTED)
    elseif #self.onlinePlayers == 0 then
        self:text("Nobody else is online.", MUTED)
    else
        local texts, selected = {}, {}
        for index, player in ipairs(self.onlinePlayers) do
            texts[index] = player.username
            selected[index] = d.participants[player.username] == true
        end
        local tick = self:ticks(texts, selected, nil)
        self:bind(function(dd)
            for index, player in ipairs(self.onlinePlayers) do dd.participants[player.username] = tick.selected[index] == true end
        end)
    end
    self:buttonRow({
        { "Refresh", W.onRefreshPlayers },
        { "Save roster", W.onSaveRoster },
        { "Teleport roster", W.onTeleport, { tooltip = "Sends every rostered player to the event start" } },
    })

    if S.UsesTeams(d.mode, d.variant) then
        self:heading("Teams")
        if #d.teams == 0 then self:text("No teams yet. Set them on the Mode step.", WARN) end
        for _, team in ipairs(d.teams) do
            local members = {}
            for username in pairs(team.members or {}) do members[#members + 1] = username end
            table.sort(members)
            local color = team.color and { team.color.r or 1, team.color.g or 1, team.color.b or 1 } or WHITE
            self:text(tostring(team.name) .. ": " .. (#members > 0 and table.concat(members, ", ") or "no players yet"), color)
        end
        if #d.teams > 0 then
            local rostered = {}
            for username, on in pairs(d.participants) do
                if on == true then rostered[#rostered + 1] = { text = username, value = username } end
            end
            table.sort(rostered, function(a, b) return a.text < b.text end)
            if #rostered == 0 then rostered[1] = { text = "(save a roster first)", value = nil } end
            self.teamPlayerCombo = self:combo("Move player", rostered, nil, nil)
            local teams = {}
            for _, team in ipairs(d.teams) do teams[#teams + 1] = { text = team.name or team.id, value = team.id } end
            self.teamTargetCombo = self:combo("To team", teams, nil, nil)
            self:button("Move to team", W.onAssignTeam, { width = 160 })
        end
    end
end

W.Builders.launch = function(self, d)
    self:heading("Where it is")
    local parts = {}
    local reached = true
    for _, stage in ipairs(S.Pipeline) do
        local color = stage.status == d.status and (S.StatusColors[stage.status] or WHITE) or (reached and MUTED or { 0.40, 0.40, 0.45 })
        parts[#parts + 1] = rgb(color) .. (stage.status == d.status and ("[" .. stage.label .. "]") or stage.label)
        if stage.status == d.status then reached = false end
    end
    local pipeline = ISRichTextPanel:new(self.fx, self.fy, self.fw, ROW)
    pipeline:initialise()
    pipeline.background = false
    pipeline:setMargins(0, 0, 0, 0)
    pipeline:setText(table.concat(parts, rgb(MUTED) .. "  >  "))
    pipeline:paginate()
    self:add(pipeline)
    self.fy = self.fy + ROW + GAP

    local action = S.NextAction[d.status] or { label = "Refresh", hint = "" }
    local blocking = S.Blocking(self.issues)
    local blocked = d.status == "DRAFT" and blocking > 0
    if blocked then
        self:text("Fix these first. Press a step to go there:", WARN)
        for _, issue in ipairs(self.issues) do
            if not issue.tip then
                local y = self.fy
                local stepIndex = S.StepIndex(issue.step)
                self:button(stepIndex .. " " .. S.Steps[stepIndex].title, W.onStepButton, { internal = stepIndex, width = 100, sameRow = true, height = ROW - 2 })
                self:text(issue.text, WHITE, self.fx + 110, self.fw - 110)
                self.fy = math.max(self.fy, y + ROW + 2)
            end
        end
    elseif d.status == "DRAFT" then
        self:text("Everything the server checks looks right.", GOOD)
    end

    if (Shared.EventPreparedStatuses or {})[d.status] or d.status == "DRAFT" then self:buildPrepared(d) end

    self.fy = self.fy + 4
    self:button(action.label, W.onPrimary, { height = 38, enabled = action.id ~= nil and not blocked, internal = action.id })
    self:text(action.hint or "", MUTED)

    local secondary = {}
    if d.status == "ANNOUNCED" or d.status == "JOINING" or d.status == "ACTIVE" then
        secondary[#secondary + 1] = { self.confirm == "stop" and "Click again to stop" or "Stop the event", W.onStop,
            { tooltip = "Ends the event now with no winner" } }
    end
    if d.status == "ACTIVE" then
        secondary[#secondary + 1] = { "Show live tracker", W.onShowLive }
    end
    if d.status == "DRAFT" or d.status == "READY" then
        secondary[#secondary + 1] = { self.confirm == "delete" and "Click again to delete" or "Delete this event", W.onDelete }
    end
    if #secondary > 0 then self:buttonRow(secondary) end

    self:heading("Summary")
    for index = 1, #S.Steps - 1 do
        local step = S.Steps[index]
        local lines = S.Summary(d, step.id)
        local y = self.fy
        self:button(index .. " " .. step.title, W.onStepButton, { internal = index, width = 100, sameRow = true, height = ROW - 2 })
        self:text(table.concat(lines, "\n"), WHITE, self.fx + 110, self.fw - 110)
        self.fy = math.max(self.fy, y + ROW + 2) + 2
    end

    if d.status == "COMPLETE" or #self.awards > 0 then self:buildAwards() end
end

-- Start / Simulate / Announcements / Cancel for a prepared event.
function W:buildPrepared(d)
    local name = S.Trim(d.name) ~= "" and d.name or "this event"
    local prepared = (Shared.EventPreparedStatuses or {})[d.status] == true
    self:heading(prepared and ("Prepared: " .. name) or ("Try it: " .. name))

    if prepared then
        local y = self.fy
        self:button("Start " .. name, W.onQuickStart, { width = math.floor(self.fw * 0.6), sameRow = true, height = 32,
            tooltip = d.status == "JOINING" and "Begin it now with everyone signed up"
                or "Announce it, ask everyone online to sign up, and begin when the sign-up time is over" })
        self.fy = y + 4
        self.fx = self.fx + math.floor(self.fw * 0.6) + GAP
        local fw = self.fw
        self.fw = fw - math.floor(fw * 0.6) - GAP
        if d.status ~= "JOINING" then
            self.signupEntry = self:entry("Sign-up secs", tostring(self.signupSeconds or 60), { numbers = true, width = 60,
                tooltip = "How long players have to sign up before it begins (10 to 600)" })
        else
            self.signupEntry = nil
        end
        self.fx = self.fx - math.floor(fw * 0.6) - GAP
        self.fw = fw
        self.fy = y + 32 + GAP
    end

    local y = self.fy
    self:button("Simulate " .. name, W.onSimulate, { width = math.floor(self.fw * 0.6), sameRow = true, height = 32,
        tooltip = "Walk through the event step by step: it takes you to each place, shows what happens there and waits for OK, Edit or Cancel. Staff you invite can join or opt out." })
    self.fy = y + 4
    self:ticks({ "Invite online staff (their choice)" }, { self.simulateWithStaff == true }, function(studio, tick)
        studio.simulateWithStaff = tick.selected[1] == true
    end, self.fx + math.floor(self.fw * 0.6) + GAP)
    self.fy = y + 32 + GAP

    if prepared then
        self:rowLabel("Announcements for " .. name)
        self.fy = self.fy + ROW
        local briefing = S.Trim(d.narrative and d.narrative.briefing or "")
        self.announcementEntry = self:entry(nil, self.announcementText or (briefing ~= "" and briefing or (name .. " is coming soon. Watch for the sign-up!")),
            { tooltip = "Shown as a banner to everyone online" })
        self:buttonRow({ { "Send announcement", W.onSendAnnouncement } })
        self:button(self.confirm == "cancelEvent" and ("Click again to cancel " .. name) or ("Cancel " .. name), W.onCancelEvent,
            { height = 30, tooltip = d.status == "READY" and "Unlock it for editing (back to Draft)"
                or "Call off the sign-ups and put it back to Ready" })
    end
    self.fy = self.fy + 6
end

function W:onQuickStart()
    local d = self:draft()
    if not d then return end
    local seconds = self.signupEntry and tonumber(self.signupEntry:getText()) or nil
    if seconds then self.signupSeconds = seconds end
    send("EVENT_QUICK_START", { id = d.id, signupSeconds = seconds })
    self:note("Starting " .. tostring(d.name) .. "...")
end

function W:onSimulate()
    local d = self:draft()
    if not d then return end
    self:commit()
    self:saveIfDirty()
    send("EVENT_SIMULATE", { id = d.id, includeStaff = self.simulateWithStaff == true })
    self:note("Starting the simulation...")
end

function W:onSendAnnouncement()
    local d = self:draft()
    if not d or not self.announcementEntry then return end
    self.announcementText = self.announcementEntry:getText()
    send("EVENT_SEND_ANNOUNCEMENT", { id = d.id, text = self.announcementText })
    self:note("Sending the announcement...")
end

function W:onCancelEvent()
    if not self:confirmed("cancelEvent") then return end
    send("EVENT_CANCEL", { id = self.selectedId })
    self:note("Cancelling...")
end

------------------------------------------------------------
-- NAVIGATION
------------------------------------------------------------

function W:goStep(index)
    if not self:draft() then return end
    self:commit()
    self:saveIfDirty()
    self.step = math.max(1, math.min(#S.Steps, index))
    self.stepByEvent[self.selectedId] = self.step
    self.confirm = nil
    self.form:setYScroll(0)
    self:rebuild(true)
end

function W:onStepButton(button) self:goStep(button.internal) end
function W:onBack() self:goStep(self.step - 1) end
function W:onNext() self:goStep(self.step + 1) end

function W:onSave()
    self:commit()
    if not self:saveIfDirty() then self:note("Nothing to save.") end
    self:rebuild(true)
end

function W:select(id, step)
    if self.selectedId and self.selectedId ~= id then
        self:commit()
        self:saveIfDirty()
    end
    self.selectedId = id
    self.confirm = nil
    local definition = self:definition(id)
    if definition then
        if not self.drafts[id] then self.drafts[id] = S.NewDraft(definition) end
        local locked = not S.Editable[definition.status]
        self.step = step or self.stepByEvent[id] or (locked and S.StepIndex("launch")) or 1
        self.stepByEvent[id] = self.step
        local eventType = definition.eventType or "HORDE_SURVIVAL"
        if not self.metadata[eventType] then send("EVENT_GET_EVENTTYPE_METADATA", { eventType = eventType }) end
        send("EVENT_GET_STATUS", { id = id })
    end
    self.form:setYScroll(0)
    self:rebuild(true)
end

function W:onPickEvent(definition)
    if definition and definition.isPast then
        self.pastRecord = definition
        self:rebuild()
        return
    end
    if definition and definition.id ~= self.selectedId then self:select(definition.id) end
end

function W:refresh()
    send("EVENT_LIST_DEFINITIONS", {})
    send("EVENT_LIST_HISTORY", {})
end

W.VIEWS = {
    { id = "saved", title = "Saved", tooltip = "Every event you have made" },
    { id = "prepared", title = "Prepared", tooltip = "Events ready to run: start, simulate, announce or cancel them" },
    { id = "past", title = "Past", tooltip = "Events that have run, and how they ended" },
}
W.OUTCOME_COLORS = { WIN = GOOD, FAIL = BAD, LOST = BAD, MANUAL = WARN, CANCELLED = MUTED }
W.OUTCOME_LABELS = { WIN = "Won", FAIL = "Lost", LOST = "Lost", MANUAL = "Stopped by staff", CANCELLED = "Cancelled" }

function W.PastLine(record)
    local parts = { W.OUTCOME_LABELS[record.outcome] or tostring(record.outcome) }
    if record.day then parts[#parts + 1] = "day " .. record.day end
    parts[#parts + 1] = #(record.participants or {}) .. " played"
    return table.concat(parts, "  |  ")
end

function W:onViewButton(button)
    if self.view == button.internal then return end
    self:commit()
    self:saveIfDirty()
    self.view = button.internal
    if self.view == "past" then
        self.selectedId = nil
    else
        self.pastRecord = nil
    end
    self:rebuild(true)
end

function W:onDirectorControls()
    if KIPN_EventDirectorControlUI then KIPN_EventDirectorControlUI.Toggle() end
end

function W:onNew()
    self:commit()
    self:saveIfDirty()
    self.pendingCreate = true
    send("EVENT_CREATE_DEFINITION", { name = "New Event", eventType = "HORDE_SURVIVAL" })
    self:note("Creating a new event...")
end

------------------------------------------------------------
-- STEP ACTIONS
------------------------------------------------------------

function W:onPickMode(button)
    local key = button.internal
    local d = self:draft()
    if not d or (d.mode or S.CUSTOM) == key then return end
    local message
    self:change(function(dd) message = S.ApplyMode(dd, key) end)
    self:note(message)
end

function W:onPickScenario(button)
    local message
    self:change(function(dd) message = S.ApplyScenario(dd, button.internal) end)
    self:note(message, "ok")
end

-- Builds the classic scenario at its original location: zone, start
-- point, exits and ambushes at Pillow's coordinates.
function W:onSetUpVenue()
    local d = self:draft()
    local template = d and d.classicScenario and Shared.EventClassicScenarios[d.classicScenario]
    if not template or not template.venue then return end
    self:commit()
    local zone = template.venue.zone
    if zone and d.scopeType == "ZONE" then
        send("EVENT_CREATE_ZONE_FROM_CORNERS", { id = d.id,
            cornerA = { x = zone[1], y = zone[2], z = 0 }, cornerB = { x = zone[3], y = zone[4], z = 0 } })
    end
    local placed = 0
    for _, hotspot in ipairs(S.VenueHotspots(template)) do
        send("EVENT_UPSERT_HOTSPOT", { id = d.id, hotspot = hotspot })
        placed = placed + 1
    end
    self:note("Setting up at " .. template.venue.label .. ": " .. placed .. " hotspots" .. (zone and " and the zone" or "") .. "...")
end

function W:onPickScope(button)
    self:change(function(dd) dd.scopeType = button.internal end)
end

function W:onPickDirector(button)
    self:change(function(dd)
        dd.directorType = button.internal
        dd.spawnRules.escalationEnabled = button.internal ~= "ZOMBIE_WAVES"
    end)
end

function W:onSetTeams()
    local d = self:draft()
    local count = math.floor(tonumber(self.teamCountEntry and self.teamCountEntry:getText()) or 0)
    if count < 2 then
        self:note("An event with teams needs at least 2.", "warn")
        return
    end
    send("EVENT_SET_TEAM_COUNT", { id = d.id, teamCount = count })
    self:note("Setting up " .. count .. " teams...")
end

-- Hides the Studio while the map picker is open, then brings it back.
function W:openMap(onConfirm)
    local d = self:draft()
    if not d then return end
    self:commit()
    local studio = self
    self:removeFromUIManager()
    KIPN_ZoneAdminMapUI.Open({
        existingZones = mapEntries(d),
        onClose = function()
            studio:setVisible(true)
            studio:addToUIManager()
            studio:bringToTop()
        end,
        onConfirm = onConfirm,
    })
end

function W:onDrawZone()
    local id = self.selectedId
    self:openMap(function(cornerA, cornerB)
        send("EVENT_CREATE_ZONE_FROM_CORNERS", { id = id, cornerA = cornerA, cornerB = cornerB })
        self:note("Saving the event zone...")
    end)
end

local function playerSquare()
    local player = getPlayer()
    if not player then return nil end
    return math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
end

function W:zoneAroundMe()
    local x, y, z = playerSquare()
    if not x then
        self:note("You need to be in the world to use your position.", "warn")
        return false
    end
    send("EVENT_CREATE_ZONE_FROM_CORNERS", {
        id = self.selectedId,
        cornerA = { x = x - AREA_RADIUS, y = y - AREA_RADIUS, z = z },
        cornerB = { x = x + AREA_RADIUS, y = y + AREA_RADIUS, z = z },
    })
    return true
end

function W:onZoneAroundMe()
    if self:zoneAroundMe() then self:note("Saving an event zone around you...") end
end

function W:upsertHotspot(hotspotType, round, teamId, metadata, geometry)
    send("EVENT_UPSERT_HOTSPOT", {
        id = self.selectedId,
        hotspot = {
            type = hotspotType,
            label = S.HotspotLabel(hotspotType),
            roundNumber = round,
            teamId = teamId,
            metadata = metadata,
            geometry = geometry,
        },
    })
end

function W:drawHotspot(hotspotType, round, teamId, metadata)
    self:openMap(function(cornerA, cornerB)
        local zA = tonumber(cornerA and cornerA.z) or 0
        local zB = tonumber(cornerB and cornerB.z) or zA
        self:upsertHotspot(hotspotType, round, teamId, metadata, {
            x1 = cornerA and cornerA.x, y1 = cornerA and cornerA.y, z1 = zA,
            x2 = cornerB and cornerB.x, y2 = cornerB and cornerB.y, z2 = zB,
        })
        self:note("Saving " .. S.HotspotLabel(hotspotType) .. "...")
    end)
end

function W:onDrawNeeded()
    local need = S.NextHotspotNeeded(self:draft())
    if need then self:drawHotspot(need.type, need.round, need.teamId, need.metadata) end
end

-- Places every missing hotspot at random around the admin, working out
-- the next need on a scratch copy so each is placed exactly once.
function W:onPlaceAllNeeded()
    local d = self:draft()
    local x, y, z = playerSquare()
    if not d or not x then
        self:note("You need to be in the world to use your position.", "warn")
        return
    end
    self:commit()
    if d.scopeType == "ZONE" and not d.zoneId then self:zoneAroundMe() end
    local scratch = S.Copy(d)
    local range = AREA_RADIUS - HOTSPOT_MARGIN
    local placed = 0
    while placed < 40 do
        local need = S.NextHotspotNeeded(scratch)
        if not need then break end
        scratch.hotspots[#scratch.hotspots + 1] = { type = need.type, roundNumber = need.round, teamId = need.teamId, metadata = need.metadata, active = true }
        local cx = x + ZombRand(0, range * 2 + 1) - range
        local cy = y + ZombRand(0, range * 2 + 1) - range
        self:upsertHotspot(need.type, need.round, need.teamId, need.metadata, {
            x1 = cx - HOTSPOT_HALF, y1 = cy - HOTSPOT_HALF, z1 = z,
            x2 = cx + HOTSPOT_HALF, y2 = cy + HOTSPOT_HALF, z2 = z,
        })
        placed = placed + 1
    end
    self:note(placed > 0 and ("Placing " .. placed .. " hotspots around you...") or "Nothing to place.")
end

function W:onDrawHotspot()
    local d = self:draft()
    local hotspotType = self.newHotspotType
    local round = tonumber(self.hotspotRoundEntry and self.hotspotRoundEntry:getText())
    local teamId = self.hotspotTeamCombo and comboValue(self.hotspotTeamCombo)
    local metadata
    if not hotspotType then return end
    if hotspotType == "TEAM_BASE" and not teamId then
        self:note("Pick which team this base belongs to.", "warn")
        return
    end
    if hotspotType == "NARRATIVE_LOCATION" then
        local text = S.Trim(self.hotspotTextEntry and self.hotspotTextEntry:getText())
        if text == "" then
            self:note("Type the text players will see first.", "warn")
            return
        end
        metadata = {
            narrativeText = text,
            narrativeScope = comboValue(self.hotspotScopeCombo) or "LOCAL",
            replayable = self.hotspotReplayable ~= false,
            clueTitle = S.Trim(self.hotspotClueTitleEntry and self.hotspotClueTitleEntry:getText()),
        }
    end
    if hotspotType == "ZOMBIE_AMBUSH" then
        metadata = { count = math.max(1, math.floor(tonumber(self.hotspotCountEntry and self.hotspotCountEntry:getText()) or 8)) }
    elseif hotspotType == "BANDIT_CAMP" then
        metadata = { count = math.max(1, math.min(12, math.floor(tonumber(self.hotspotCountEntry and self.hotspotCountEntry:getText()) or 4))) }
    end
    if hotspotType == "HILL_LOCATION" and not round then
        local hills = 0
        for _, hotspot in ipairs(d.hotspots) do
            if hotspot.type == "HILL_LOCATION" and hotspot.active ~= false then hills = hills + 1 end
        end
        round = math.min(S.MAX_ROUNDS, hills + 1)
    end
    self:drawHotspot(hotspotType, round, teamId, metadata)
end

function W:onDeleteHotspot(button)
    send("EVENT_DELETE_HOTSPOT", { id = self.selectedId, hotspotId = button.internal })
    self:note("Deleting hotspot...")
end

function W:onAddStage()
    local name = S.Trim(self.newStageEntry and self.newStageEntry:getText())
    self:change(function(dd)
        dd.objectives[#dd.objectives + 1] = {
            id = "objective_" .. tostring(#dd.objectives + 1) .. "_" .. tostring(ZombRand(100000)),
            name = name,
            triggers = {},
        }
    end)
    self:note("Added a stage. Give it a trigger below.")
end

function W:onRemoveStage(button)
    self:change(function(dd) table.remove(dd.objectives, button.internal) end)
end

function W:onAddTrigger()
    local stageIndex = comboValue(self.triggerStageCombo)
    local actionType = comboValue(self.triggerActionCombo)
    local hotspotId = self.triggerHotspotCombo and comboValue(self.triggerHotspotCombo)
    local param = S.Trim(self.triggerParamEntry and self.triggerParamEntry:getText())
    if self.triggerWhen == "PROXIMITY" and not hotspotId then
        self:note("Pick the hotspot players must reach.", "warn")
        return
    end
    local params = {}
    for _, option in ipairs(TRIGGER_ACTIONS) do
        if option.value == actionType and option.param == "text" then params.text = param end
        if option.value == actionType and option.param == "count" then params.count = tonumber(param) or 5 end
    end
    self:change(function(dd)
        local stage = dd.objectives[stageIndex]
        if not stage then return end
        stage.triggers = stage.triggers or {}
        stage.triggers[#stage.triggers + 1] = {
            activationMode = self.triggerWhen,
            hotspotId = self.triggerWhen == "PROXIMITY" and hotspotId or nil,
            actions = { { type = actionType, params = params } },
        }
    end)
    self:note("Trigger added.")
end

function W:onRemoveReward(button)
    self:change(function(dd) table.remove(dd.rewards.items, button.internal) end)
end

function W:onRefreshAwards()
    send("EVENT_LIST_REWARDS", {})
    self:note("Refreshing the prize list...")
end

function W:onMarkDelivered(button)
    send("EVENT_MARK_REWARD_DELIVERED", { awardId = button.internal })
    self:note("Marking the prize delivered...")
end

function W:onRefreshPlayers()
    self:commit()
    send("EVENT_LIST_ONLINE_PLAYERS", {})
    self:note("Refreshing online players...")
end

function W:onSaveRoster()
    self:commit()
    local d = self:draft()
    local usernames = {}
    for username, selected in pairs(d.participants) do
        if selected == true then usernames[#usernames + 1] = username end
    end
    table.sort(usernames)
    send("EVENT_SET_PARTICIPANTS", { id = d.id, usernames = usernames })
    self:note("Saving the roster (" .. #usernames .. " players)...")
end

function W:onTeleport()
    send("EVENT_TELEPORT_PARTICIPANTS", { id = self.selectedId })
    self:note("Teleporting the roster...")
end

function W:onAssignTeam()
    local username = comboValue(self.teamPlayerCombo)
    local teamId = comboValue(self.teamTargetCombo)
    if not username or not teamId then
        self:note("Pick a rostered player and a team.", "warn")
        return
    end
    send("EVENT_ASSIGN_PLAYER_TEAM", { id = self.selectedId, username = username, teamId = teamId })
    self:note("Moving " .. username .. "...")
end

------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------

function W:onPrimary(button)
    local d = self:draft()
    if not d then return end
    local id = button.internal
    if id == "validate" then
        self:commit()
        if S.Blocking(S.Check(d)) > 0 then
            self:note("Some steps still need attention; they are listed above.", "warn")
            self:rebuild(true)
            return
        end
        -- The server checks what it has stored, so save first and
        -- validate once the save is acknowledged.
        self.pendingValidate = d.id
        self.sentSignature[d.id] = S.Signature(d)
        send("EVENT_UPDATE_DEFINITION", S.Payload(d))
        self:note("Saving and checking...")
    elseif id == "announce" then
        send("EVENT_ANNOUNCE", { id = d.id })
        self:note("Announcing...")
    elseif id == "join" then
        send("EVENT_OPEN_JOINING", { id = d.id })
        self:note("Opening joining...")
    elseif id == "start" then
        self.pendingLive = d.id
        send("EVENT_START", { id = d.id })
        self:note("Starting the event...")
    elseif id == "director" then
        KIPN_EventDirectorPanel.Toggle()
    elseif id == "reset" then
        send("EVENT_RESET", { id = d.id })
        self:note("Resetting for reuse...")
    end
end

-- Destructive buttons need a second click.
function W:confirmed(what)
    if self.confirm == what then
        self.confirm = nil
        return true
    end
    self.confirm = what
    self:rebuild()
    return false
end

function W:onStop()
    if not self:confirmed("stop") then return end
    send("EVENT_STOP", { id = self.selectedId })
    self:note("Stopping the event...")
end

function W:onDelete()
    if not self:confirmed("delete") then return end
    send("EVENT_DELETE_DEFINITION", { id = self.selectedId })
    self:note("Deleting the event...")
end

function W:showLive(id)
    local definition = self:definition(id)
    if KIPN_EventStudioLiveUI then KIPN_EventStudioLiveUI.Show(id, definition and definition.name) end
end

function W:onShowLive()
    self:showLive(self.selectedId)
    self:close()
end

------------------------------------------------------------
-- SERVER RESPONSES
------------------------------------------------------------

local function eventIs(event, name)
    return Shared.ResponseEvents and Shared.ResponseEvents[name] ~= nil and event == Shared.ResponseEvents[name]
end

function W:onSaved(data)
    local definition = data.definition
    if not data.success or not definition then
        self.pendingCreate, self.pendingValidate = nil, nil
        self:note("Could not save: " .. S.Explain(data.reason), "error")
        self:rebuild()
        return
    end
    self:commit()
    self:storeDefinition(definition)
    if self.pendingCreate then
        self.pendingCreate = nil
        self:note("Created. Start by naming it and picking a game mode.", "ok")
        self:select(definition.id, 1)
        return
    end
    -- Take the server's copy (it may have tidied values) unless the
    -- admin changed something while the save was on its way.
    local draft = self.drafts[definition.id]
    if draft and S.Signature(draft) == self.sentSignature[definition.id] then
        self.drafts[definition.id] = S.NewDraft(definition)
    end
    if self.pendingValidate == definition.id then
        self.pendingValidate = nil
        send("EVENT_VALIDATE", { id = definition.id })
        self:note("Saved. The server is checking the event...")
    else
        self:note("Saved.", "ok")
    end
    self:rebuild(true)
end

function W:onStatusChanged(data)
    if data.success and data.definition then
        self:storeDefinition(data.definition)
        local action = S.NextAction[data.definition.status]
        self:note("Now " .. S.StatusLabel(data.definition.status) .. "."
            .. (action and action.id and (" Next: " .. action.label .. ".") or ""), "ok")
    else
        self:note("Not ready yet: " .. S.Explain(data.reason), "error")
    end
    self:refresh()
    if self.selectedId then send("EVENT_GET_STATUS", { id = self.selectedId }) end
    self:rebuild()
end

function W:onResponse(event, data)
    if eventIs(event, "EVENT_ACTION_RESULT") then
        if data.definition then self:storeDefinition(data.definition) end
        self:note(tostring(data.text or (data.success and "Done." or "That didn't work.")), data.success and "ok" or "error")
        -- The simulation took over the screen: get out of the way.
        if data.action == "simulate" and data.success then self:close() return end
        self:refresh()
        self:rebuild()
    elseif eventIs(event, "EVENT_HISTORY_DATA") then
        self.history = data.records or {}
        if self.pastRecord then
            local found
            for _, record in ipairs(self.history) do if record.id == self.pastRecord.id then found = record end end
            self.pastRecord = found
        end
        if self.view == "past" then self:rebuild() end
    elseif eventIs(event, "EVENT_DEFINITIONS_DATA") then
        self.definitions = {}
        for _, definition in ipairs(data.definitions or {}) do self:storeDefinition(definition) end
        if self.selectedId and not self:definition(self.selectedId) then self.selectedId = nil end
        if self.pendingSelect and self:definition(self.pendingSelect.id) then
            local pending = self.pendingSelect
            self.pendingSelect = nil
            self.view = "saved"
            self:select(pending.id, pending.step)
        end
        if not self.loadedOnce then
            self.loadedOnce = true
            self:note(#self.definitions == 0 and "No events yet. Press + New event to make one." or ("Loaded " .. #self.definitions .. " events."))
        end
        self:rebuild()
    elseif eventIs(event, "EVENT_DEFINITION_SAVED") then
        self:onSaved(data)
    elseif eventIs(event, "EVENT_DEFINITION_DELETED") then
        if data.success then
            self.drafts[data.id or self.selectedId] = nil
            self.selectedId = nil
            self:note("Event deleted.", "ok")
            self:refresh()
            self:rebuild(true)
        else
            self:note("Could not delete: " .. S.Explain(data.reason), "error")
        end
    elseif eventIs(event, "EVENT_ZONE_SAVED") then
        self:note(data.success and "Event zone saved." or ("Zone not saved: " .. S.Explain(data.reason)), data.success and "ok" or "error")
        self:refresh()
    elseif eventIs(event, "EVENT_HOTSPOT_SAVED") then
        if data.success and data.definition then
            self:storeDefinition(data.definition)
            self:note("Hotspots updated.", "ok")
            self:rebuild()
        else
            self:note("Hotspot not saved: " .. S.Explain(data.reason), "error")
        end
    elseif eventIs(event, "EVENT_EVENTTYPE_METADATA_DATA") then
        if data.success then
            self.metadata[data.eventType or "HORDE_SURVIVAL"] = { win = data.winConditions or {}, fail = data.failConditions or {} }
            if self:draft() and S.Steps[self.step].id == "goals" then self:rebuild() end
        end
    elseif eventIs(event, "EVENT_ONLINE_PLAYERS_DATA") then
        self.onlinePlayers = data.players or {}
        self:rebuild()
    elseif eventIs(event, "EVENT_PARTICIPANTS_SAVED") then
        self:note(data.success and "Roster saved." or ("Roster not saved: " .. S.Explain(data.reason)), data.success and "ok" or "error")
        self:refresh()
    elseif eventIs(event, "EVENT_TEAM_SAVED") then
        if data.success and data.definition then
            self:storeDefinition(data.definition)
            self:note("Teams updated.", "ok")
            self:rebuild()
        else
            self:note("Teams not changed: " .. S.Explain(data.reason), "error")
        end
    elseif eventIs(event, "EVENT_STATUS_CHANGED") then
        self:onStatusChanged(data)
    elseif eventIs(event, "EVENT_TELEPORT_RESULT") then
        self:note(data.success and ("Teleported " .. tostring(data.results and #data.results or 0) .. " players.")
            or ("Teleport failed: " .. S.Explain(data.reason)), data.success and "ok" or "error")
    elseif eventIs(event, "EVENT_STARTED") then
        if data.success then
            local id = (data.status and data.status.eventDefinitionId) or self.pendingLive or self.selectedId
            local definition = self:definition(id)
            if definition then
                definition.status = "ACTIVE"
                if self.drafts[id] then self.drafts[id].status = "ACTIVE" end
            end
            self:note("The event is live.", "ok")
            self:refresh()
            if self.pendingLive then
                self.pendingLive = nil
                self:showLive(id)
                self:close()
            end
        else
            self.pendingLive = nil
            self:note("Could not start: " .. S.Explain(data.reason), "error")
        end
        self:rebuild()
    elseif eventIs(event, "EVENT_STOPPED") then
        self:note(data.success and "The event has ended." or ("Could not stop: " .. S.Explain(data.reason)), data.success and "ok" or "error")
        self:refresh()
    elseif eventIs(event, "EVENT_STATUS_DATA") then
        local definition = self:definition(data.eventDefinitionId)
        if definition and data.status and data.status ~= definition.status and data.status ~= "NOT_FOUND" then
            definition.status = data.status
            if self.drafts[definition.id] then self.drafts[definition.id].status = data.status end
            self:rebuild()
        end
    elseif eventIs(event, "EVENT_REWARDS_DATA") then
        self.awards = data.awards or {}
        local stepId = self:draft() and S.Steps[self.step].id
        if stepId == "rewards" or stepId == "launch" then self:rebuild() end
    elseif eventIs(event, "EVENT_REWARD_RESULT") then
        self:note(data.success and "Prize marked delivered." or ("Prize not updated: " .. S.Explain(data.reason)), data.success and "ok" or "error")
        if data.success then send("EVENT_LIST_REWARDS", {}) end
    elseif eventIs(event, "ERROR") then
        if self.pendingCreate or self.pendingValidate or self.pendingLive then
            self.pendingCreate, self.pendingValidate, self.pendingLive = nil, nil, nil
        end
        self:note("Server said no: " .. S.Explain(data.reason or data.message), "error")
    end
end

local function onServerCommand(module, command, args)
    if module ~= "KIPN" or not args or not Shared.Commands or command ~= Shared.Commands.SERVER_RESPONSE then return end
    local data = args.data or {}
    if eventIs(args.event, "EVENT_STATUS_DATA") and KIPN_EventStudioLiveUI then KIPN_EventStudioLiveUI.OnStatus(data) end
    if W.instance then W.instance:onResponse(args.event, data) end
end

------------------------------------------------------------
-- OPEN / CLOSE
------------------------------------------------------------

function W.Open()
    local studio = W.instance
    if not studio then
        studio = W:new()
        studio:initialise()
        W.instance = studio
    end
    studio.isOpen = true
    studio:setVisible(true)
    studio:addToUIManager()
    studio:bringToTop()
    studio:refresh()
    return studio
end

-- Opens the Studio on one event at one step (by id), e.g. from a
-- simulation's Edit.
function W.OpenAt(id, stepId)
    local studio = W.Open()
    local step = stepId and S.StepIndex(stepId) or nil
    if studio:definition(id) then
        studio.view = "saved"
        studio.pastRecord = nil
        studio:select(id, step)
    else
        studio.pendingSelect = { id = id, step = step }
    end
    return studio
end

function W.Toggle()
    if W.instance and W.instance.isOpen then
        W.instance:close()
    else
        W.Open()
    end
end

-- Closing keeps unsaved drafts; they are there when it reopens.
function W:close()
    self:commit()
    self.isOpen = false
    self:setVisible(false)
    self:removeFromUIManager()
end

Events.OnServerCommand.Add(onServerCommand)

print("[Dynamic Events] Event Studio loaded")
