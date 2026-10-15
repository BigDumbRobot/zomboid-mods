require "ISUI/ISCollapsableWindow"
require "ISUI/ISRichTextPanel"
require "ISUI/ISButton"
require "LilBubbyShowcase"

-- A movable, resizable log of what each test is doing: report lines as they
-- arrive and the tester's commands to and from the server. Opened from the
-- Mod Showcase; closing it keeps the log, which lasts for this client session.
LilBubbyConsoleUI = ISCollapsableWindow:derive("LilBubbyConsoleUI")
local C, S = LilBubbyConsoleUI, LilBubbyShowcase

local COLORS = {
    PASS = { 0.45, 0.88, 0.45 }, FAIL = { 1.00, 0.42, 0.42 }, ERROR = { 1.00, 0.42, 0.42 },
    ABORTED = { 1.00, 0.42, 0.42 }, BLOCKED = { 0.98, 0.76, 0.30 }, SKIP = { 0.62, 0.62, 0.62 },
    READY = { 0.50, 0.80, 0.98 }, STARTED = { 0.78, 0.62, 0.98 }, INFO = { 0.86, 0.86, 0.86 },
    SEND = { 0.52, 0.58, 0.66 }, RECV = { 0.52, 0.58, 0.66 },
}

local function plain(text)
    -- Report text may contain player-supplied names; never interpret it as markup.
    return (tostring(text or ""):gsub("<", "["):gsub(">", "]"))
end
local function modName(id)
    for _, mod in ipairs(S.Mods) do if mod.id == id then return mod.name end end
    return tostring(id)
end
local function stamp(ms)
    local tenths = math.floor(ms / 100)
    return string.format("+%02d:%02d.%d", math.floor(tenths / 600), math.floor(tenths / 10) % 60, tenths % 10)
end
local function button(self, title, callback)
    local child = ISButton:new(0, 0, 100, 24, title, self, callback)
    child:initialise()
    self:addChild(child)
    return child
end

function C:new(index)
    local screenWidth, screenHeight = getCore():getScreenWidth(), getCore():getScreenHeight()
    local width = math.min(820, screenWidth - 24)
    local height = math.min(320, screenHeight - 80)
    local o = ISCollapsableWindow.new(self, 12, math.max(24, screenHeight - height - 60), width, height)
    o.playerNum = index
    o.title = "Test Console"
    o.minimumWidth = math.min(480, width)
    o.minimumHeight = math.min(160, height)
    o.resizable = true
    o.allMods = true
    o.showTraffic = true
    o.dirty = true
    o.backgroundColor = { r = 0.02, g = 0.03, b = 0.04, a = 0.94 }
    return o
end

function C:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.scopeButton = button(self, "All mods", C.toggleScope)
    self.scopeButton.tooltip = "Show every mod, or only the mod selected in the Mod Showcase"
    self.trafficButton = button(self, "Traffic: on", C.toggleTraffic)
    self.trafficButton.tooltip = "Show the tester's commands sent to and received from the server"
    self.copyButton = button(self, "Copy", C.copy)
    self.copyButton.tooltip = "Copy the visible lines to the clipboard"
    self.clearButton = button(self, "Clear", C.clear)
    self.log = ISRichTextPanel:new(0, 0, 100, 100)
    self.log:initialise()
    self.log.autosetheight = false
    self.log.clip = true
    self.log:addScrollBars()
    self.log:setMargins(8, 6, 20, 6)
    self.log.background = true
    self.log.backgroundColor = { r = 0, g = 0, b = 0, a = 0.55 }
    if UIFont.Code then self.log.font, self.log.defaultFont = UIFont.Code, UIFont.Code end
    self:addChild(self.log)
    self:layout()
end

function C:layout()
    if not self.log then return end
    local top = self:titleBarHeight() + 6
    local x = 10
    for _, child in ipairs({ self.scopeButton, self.trafficButton, self.copyButton, self.clearButton }) do
        child:setX(x); child:setY(top)
        x = x + child.width + 6
    end
    self.statusX = x + 6
    self.log:setX(10); self.log:setY(top + 30)
    self.log:setWidth(self.width - 20)
    self.log:setHeight(math.max(20, self.height - top - 30 - self:resizeWidgetHeight() - 8))
    self.dirty = true
end

-- The Showcase's selected mod decides the "This mod" filter.
function C:currentModId()
    local showcase = S.windows[self.playerNum]
    return showcase and showcase.mod and showcase.mod.id
end

function C:visibleLines()
    local modId = not self.allMods and self:currentModId()
    local lines = {}
    for _, line in ipairs(S.Console(self.playerNum)) do
        local traffic = line.level == "SEND" or line.level == "RECV"
        if (not modId or line.id == modId) and (self.showTraffic or not traffic) then
            lines[#lines + 1] = line
        end
    end
    return lines
end

local function format(line)
    return stamp(line.time) .. "  [" .. modName(line.id) .. "]  " .. line.text
end

-- Rebuild once per frame at most; keep following the newest line only while
-- the reader is already at the bottom, so scrolling back is not interrupted.
function C:rebuild()
    self.dirty = false
    self.lastModId = self:currentModId()
    local lines = self:visibleLines()
    self.shown = #lines
    local parts = {}
    for _, line in ipairs(lines) do
        local color = COLORS[line.level] or COLORS.INFO
        parts[#parts + 1] = string.format(" <RGB:%.2f,%.2f,%.2f> %s <LINE> ", color[1], color[2], color[3], plain(format(line)))
    end
    if #parts == 0 then
        parts[1] = " <RGB:0.55,0.55,0.55> No output yet. Start a feature in the Mod Showcase; its progress, results and server traffic appear here. "
    end
    local log = self.log
    local bottom = math.min(0, log.height - log:getScrollHeight())
    local follow = self.forceBottom or log:getYScroll() <= bottom + 4
    local keep = log:getYScroll()
    log:setText(table.concat(parts))
    log:paginate()
    if follow then
        log:setYScroll(math.min(0, log.height - log:getScrollHeight()))
    else
        log:setYScroll(keep)
    end
    self.forceBottom = false
end

function C:prerender()
    if self.lastWidth ~= self.width or self.lastHeight ~= self.height then
        self.lastWidth, self.lastHeight = self.width, self.height
        self:layout()
    end
    if not self.allMods and self.lastModId ~= self:currentModId() then self.dirty = true end
    if self.dirty and self.log and not self.isCollapsed then self:rebuild() end
    ISCollapsableWindow.prerender(self)
    if self.status and os.time() > (self.statusUntil or 0) then self.status = nil end
    if self.log and not self.isCollapsed then
        local total = #S.Console(self.playerNum)
        local scope = self.allMods and "all mods" or modName(self:currentModId() or "none")
        local text = (self.status or (tostring(self.shown or 0) .. " of " .. total .. " lines | " .. scope))
        self:drawText(text, self.statusX or 10, self:titleBarHeight() + 10, 0.65, 0.72, 0.80, 1, UIFont.Small)
    end
end

function C:toggleScope()
    self.allMods = not self.allMods
    self.scopeButton:setTitle(self.allMods and "All mods" or "This mod")
    self.status, self.dirty, self.forceBottom = nil, true, true
end
function C:toggleTraffic()
    self.showTraffic = not self.showTraffic
    self.trafficButton:setTitle(self.showTraffic and "Traffic: on" or "Traffic: off")
    self.status, self.dirty, self.forceBottom = nil, true, true
end
function C:clear()
    local lines = S.Console(self.playerNum)
    for i = #lines, 1, -1 do lines[i] = nil end
    self.status, self.dirty = nil, true
end
function C:copy()
    local out = {}
    for _, line in ipairs(self:visibleLines()) do out[#out + 1] = format(line) end
    local ok = pcall(function() Clipboard.setClipboard(table.concat(out, "\n")) end)
    self.status = ok and ("Copied " .. #out .. " lines to the clipboard.") or "Clipboard is unavailable."
    self.statusUntil = os.time() + 3
end

function C:isOpen() return self.open == true end
function C:setOpen(open)
    self.open = open
    self:setVisible(open)
    if open then
        self.dirty, self.forceBottom = true, true
        self:bringToTop()
    end
end
-- The title-bar close button hides the window; the log keeps collecting.
function C:close() self:setOpen(false) end

function C.Toggle(index)
    local console = S.consoleWindows[index]
    if not console then
        console = C:new(index)
        console:initialise()
        S.consoleWindows[index] = console
        console:addToUIManager()
        console:setOpen(true)
    else
        console:setOpen(not console:isOpen())
    end
    return console
end
