require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISRichTextPanel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISButton"
require "LilBubbyShowcase"
require "LilBubbyConsoleUI"
require "LilBubbyMiniUI"

LilBubbyShowcaseUI = ISCollapsableWindow:derive("LilBubbyShowcaseUI")
local W, S = LilBubbyShowcaseUI, LilBubbyShowcase

-- Shown when none of the mods the tester covers is enabled.
W.NO_MODS = { id = "none", name = "No supported mods",
    description = "None of the mods this tester covers is enabled.",
    guide = "Subscribe to a supported mod on the Steam Workshop and enable it alongside lilBubby's Big ol Mod Tester. Its tests appear here automatically.\n\nSupported: Bonk Zone, Spy vs Spy Booby Traps, Spy vs Spy Signal Tracker, KIP Network Terminal with Vehicle Services, Government Services or The Post Office, Dead Man's Map, Skylights, The Whisperers and Satanic Temples." }

local function plain(text)
    -- Reports may contain names supplied by players. Do not interpret them as
    -- rich-text commands (images, colors, fonts, etc.).
    return tostring(text or ""):gsub("<", "["):gsub(">", "]"):gsub("\n", " <LINE> ")
end
local function content(panel, text)
    panel:setText(plain(text))
    panel:paginate()
    panel:setYScroll(0)
end
local function panel(self)
    local child = ISRichTextPanel:new(0, 0, 100, 100)
    child:initialise()
    child.autosetheight = false
    child.clip = true
    child:addScrollBars()
    child:setMargins(8, 8, 20, 8)
    self:addChild(child)
    return child
end
local function button(self, title, callback)
    local child = ISButton:new(0, 0, 100, 28, title, self, callback)
    child:initialise()
    self:addChild(child)
    return child
end
local function place(child, x, y, width, height)
    child:setX(x); child:setY(y)
    child:setWidth(width); child:setHeight(height)
end

function W:new(player)
    local width = math.min(1100, getCore():getScreenWidth() - 24)
    local height = math.min(760, getCore():getScreenHeight() - 40)
    local o = ISCollapsableWindow.new(self, 12, 24, width, height)
    o.player = player
    o.playerNum = player:getPlayerNum()
    o.title = "lilBubby's Mod Showcase"
    o.minimumWidth = math.min(760, width)
    o.minimumHeight = math.min(540, height)
    o.resizable = true
    o.mod = S.InstalledMods()[1] or W.NO_MODS
    o.historyIndex = 1
    o.backgroundColor = { r = 0.07, g = 0.08, b = 0.10, a = 0.97 }
    return o
end

function W:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.mods = ISScrollingListBox:new(0, 0, 180, 200)
    self.mods:initialise()
    self.mods.itemheight = getTextManager():getFontHeight(UIFont.Small) + 18
    self.mods:setOnMouseDownFunction(self, W.selectMod)
    self:addChild(self.mods)
    local installed = S.InstalledMods()
    for _, mod in ipairs(installed) do self.mods:addItem(mod.name, mod) end
    if #installed == 0 then self.mods:addItem(W.NO_MODS.name, W.NO_MODS) end
    self.mods.selected = 1

    self.search = ISTextEntryBox:new("", 0, 0, 200, 28)
    self.search:initialise()
    self.search:setPlaceholderText("Search features...")
    self.search.tooltip = "Search features in the selected mod"
    self.search.onTextChange = function() self:filter() end
    self:addChild(self.search)
    self.refreshButton = button(self, "Refresh targets", W.refresh)
    self.consoleButton = button(self, "Console", W.toggleConsole)
    self.consoleButton.tooltip = "Open or close the Test Console: live progress, results and server traffic"
    self.features = ISScrollingListBox:new(0, 0, 300, 300)
    self.features:initialise()
    self.features.itemheight = 2 * getTextManager():getFontHeight(UIFont.Small) + 14
    self.features:setOnMouseDownFunction(self, W.selectFeature)
    self.features.doDrawItem = W.drawFeature
    self.features.showcase = self
    self:addChild(self.features)
    self.instructions = panel(self)
    self.result = panel(self)
    self.startButton = button(self, "Start selected", W.start)
    self.detailsButton = button(self, "Show full report", W.toggleDetails)
    self.olderButton = button(self, "Older", W.older)
    self.newerButton = button(self, "Newer", W.newer)
    self:layout()
    self:refresh()
end

function W:layout()
    if not self.mods then return end
    local top = self:titleBarHeight() + 10
    local bottom = self.height - self:resizeWidgetHeight() - 10
    local side = math.floor(self.width * 0.21)
    local x = side + 20
    local listWidth = math.floor((self.width - x - 20) * 0.45)
    local detailX = x + listWidth + 10
    local detailWidth = self.width - detailX - 10
    local body = top + 38
    local split = body + math.floor((bottom - body - 40) * 0.50)
    place(self.mods, 10, top, side, bottom - top)
    place(self.search, x, top, self.width - x - 260, 28)
    place(self.consoleButton, self.width - 250, top, 104, 28)
    place(self.refreshButton, self.width - 140, top, 130, 28)
    place(self.features, x, body, listWidth, bottom - body - 26)
    place(self.instructions, detailX, body, detailWidth, split - body)
    place(self.startButton, detailX, split + 6, detailWidth, 28)
    place(self.result, detailX, split + 42, detailWidth, bottom - split - 78)
    place(self.detailsButton, detailX, bottom - 28, detailWidth - 140, 28)
    place(self.olderButton, self.width - 144, bottom - 28, 64, 28)
    place(self.newerButton, self.width - 74, bottom - 28, 64, 28)
    self.instructions:paginate()
    self.result:paginate()
end

function W:prerender()
    if self.lastWidth ~= self.width or self.lastHeight ~= self.height then
        self.lastWidth, self.lastHeight = self.width, self.height
        self:layout()
    end
    ISCollapsableWindow.prerender(self)
    if self.consoleButton then
        local console = S.consoleWindows[self.playerNum]
        self.consoleButton:setTitle(console and console:isOpen() and "Hide console" or "Console")
    end
    if self.features and not self.isCollapsed then
        local state = S.Session(self.player, self.mod.id)
        local count = 0
        for _ in pairs(state.tried) do count = count + 1 end
        self:drawText(tostring(#self.features.items) .. " features shown | " .. count .. " tried this session",
            self.features.x, self.features.y + self.features.height + 4, 0.75, 0.8, 0.85, 1, UIFont.Small)
    end
end

local function shorten(text, width)
    local manager = getTextManager()
    if manager:MeasureStringX(UIFont.Small, text) <= width then return text end
    while #text > 0 and manager:MeasureStringX(UIFont.Small, text .. "...") > width do
        text = text:sub(1, -2)
    end
    return text .. "..."
end
function W.drawFeature(list, y, item, alt)
    local option = item.item
    if list.selected == item.index then
        list:drawRect(0, y, list.width, list.itemheight, 0.65, 0.18, 0.30, 0.40)
    end
    local color = option.notAvailable and 0.5 or 0.95
    local tried = S.Session(list.showcase.player, list.showcase.mod.id).tried[option.key]
    local prefix = option.notAvailable and "[Unavailable] " or (tried and "[Tried] " or "")
    local fontHeight = getTextManager():getFontHeight(UIFont.Small)
    list:drawText(shorten(prefix .. option.name, list.width - 28), 6, y + 4, color, color, color, 1, UIFont.Small)
    list:drawText(shorten(option.path ~= "" and option.path or "Getting started", list.width - 28),
        6, y + fontHeight + 7, 0.60, 0.72, 0.80, 1, UIFont.Small)
    return y + list.itemheight
end

function W:selectMod(mod)
    self.mod = mod
    self.selectedFeature = nil
    self.historyIndex = 1
    self.search:setText("")
    self:refresh()
end
function W:refresh()
    self.player = getSpecificPlayer(self.playerNum) or self.player
    self.entries, self.notes = S.Build(self.player, self.mod.id)
    self:filter()
    self:showResult()
end
function W:filter()
    if not self.features then return end
    local key = self.selectedFeature and self.selectedFeature.key
    local query = string.lower(self.search:getText() or "")
    self.features:clear()
    local selected
    for _, entry in ipairs(self.entries or {}) do
        if string.find(string.lower(entry.key), query, 1, true) then
            self.features:addItem(entry.name, entry)
            if entry.key == key then selected = #self.features.items end
        end
    end
    self.features.selected = selected or (#self.features.items > 0 and 1 or -1)
    local row = self.features.items[self.features.selected]
    self:selectFeature(row and row.item)
end
function W:selectFeature(option)
    self.selectedFeature = option
    local lines = { self.mod.name, self.mod.description }
    if option then
        lines[#lines + 1] = "\nSelected feature:\n" .. option.name
        if option.path ~= "" then lines[#lines + 1] = option.path end
        if option.notAvailable then
            lines[#lines + 1] = "Unavailable in the current state. Check the target, skills and sandbox settings, then refresh."
        end
    else
        lines[#lines + 1] = "\nNo matching features. Clear the search or check that the required mod is enabled."
    end
    lines[#lines + 1] = "\nHow to try this mod:\n" .. self.mod.guide
    if self.notes and self.notes ~= "" then
        lines[#lines + 1] = "\nCurrent targets and availability:\n" .. self.notes
    end
    content(self.instructions, table.concat(lines, "\n"))
    self.startButton:setEnable(option ~= nil and not option.notAvailable)
end
function W:start()
    self.player = getSpecificPlayer(self.playerNum) or self.player
    if not self.selectedFeature then return end
    local ok, err = S.Run(self.player, self.mod.id, self.selectedFeature, self.notes)
    if not ok then S.Report(self.player, self.mod.id, "Could not start: " .. tostring(err)) end
    self:refresh()
    -- Get out of the way while the test runs; the corner strip shows progress.
    if ok then
        self:setVisible(false)
        if LilBubbyMiniUI then LilBubbyMiniUI.Show(self.playerNum) end
    end
end

function W:showResult()
    local history = S.Session(self.player, self.mod.id).history
    self.historyIndex = math.max(1, math.min(self.historyIndex or 1, #history))
    local text = history[self.historyIndex]
    if not text then
        content(self.result, "Results\n\nChoose a feature and start it. Results are kept separately for each mod and local player during this session.\n\nPASS: expected behavior observed. FAIL: unexpected behavior. BLOCKED: prerequisites unmet. SKIP: not applicable. READY: eligible to craft; no crafting performed.")
    else
        local display = text
        if not self.fullReport then
            display = S.Summarize(text)
        end
        content(self.result, "Result " .. self.historyIndex .. " of " .. #history .. " (newest first)\n\n" .. display)
    end
    self.olderButton:setEnable(self.historyIndex < #history)
    self.newerButton:setEnable(self.historyIndex > 1)
end
function W:toggleDetails()
    self.fullReport = not self.fullReport
    self.detailsButton:setTitle(self.fullReport and "Show summary" or "Show full report")
    self:showResult()
end
function W:toggleConsole() LilBubbyConsoleUI.Toggle(self.playerNum) end
function W:older() self.historyIndex = self.historyIndex + 1; self:showResult() end
function W:newer() self.historyIndex = self.historyIndex - 1; self:showResult() end
