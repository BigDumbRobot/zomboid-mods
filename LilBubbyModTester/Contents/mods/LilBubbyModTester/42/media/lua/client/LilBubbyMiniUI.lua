require "ISUI/ISPanel"
require "ISUI/ISButton"
require "LilBubbyShowcase"

-- A small, see-through progress strip in the bottom-left corner. It replaces
-- the Mod Showcase while a test runs so the world stays visible: the current
-- activity on top, then the newest result lines (traffic left out), coloured
-- like the Test Console. Drag it to move it; Showcase brings the window back.
LilBubbyMiniUI = ISPanel:derive("LilBubbyMiniUI")
local M, S = LilBubbyMiniUI, LilBubbyShowcase

local COLORS = {
    PASS = { 0.45, 0.88, 0.45 }, FAIL = { 1.00, 0.42, 0.42 }, ERROR = { 1.00, 0.42, 0.42 },
    ABORTED = { 1.00, 0.42, 0.42 }, BLOCKED = { 0.98, 0.76, 0.30 }, SKIP = { 0.62, 0.62, 0.62 },
    READY = { 0.50, 0.80, 0.98 }, STARTED = { 0.78, 0.62, 0.98 }, INFO = { 0.86, 0.86, 0.86 },
}
M.LINES = 7
M.windows = M.windows or {}

local function lineHeight() return getTextManager():getFontHeight(UIFont.Small) + 2 end

local function fit(text, width)
    local manager = getTextManager()
    if manager:MeasureStringX(UIFont.Small, text) <= width then return text end
    while #text > 0 and manager:MeasureStringX(UIFont.Small, text .. "...") > width do text = text:sub(1, -2) end
    return text .. "..."
end

function M:new(index)
    local width = math.min(520, math.floor(getCore():getScreenWidth() * 0.42))
    local height = 30 + lineHeight() * (M.LINES + 1)
    local o = ISPanel.new(self, 12, getCore():getScreenHeight() - height - 12, width, height)
    o.playerNum = index
    o.moveWithMouse = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.55 }
    o.borderColor = { r = 0.45, g = 0.35, b = 0.60, a = 0.8 }
    return o
end

function M:createChildren()
    ISPanel.createChildren(self)
    self.hideButton = ISButton:new(self.width - 24, 4, 20, 18, "x", self, M.hide)
    self.hideButton:initialise()
    self.hideButton.tooltip = "Hide this strip; results keep collecting"
    self:addChild(self.hideButton)
    self.showcaseButton = ISButton:new(self.width - 108, 4, 80, 18, "Showcase", self, M.openShowcase)
    self.showcaseButton:initialise()
    self.showcaseButton.tooltip = "Open the Mod Showcase with the full reports"
    self:addChild(self.showcaseButton)
end

-- Newest result lines, oldest first, without command traffic.
function M:recentLines()
    local all, out = S.Console(self.playerNum), {}
    for i = #all, 1, -1 do
        local line = all[i]
        if line.level ~= "SEND" and line.level ~= "RECV" then
            table.insert(out, 1, line)
            if #out >= M.LINES then break end
        end
    end
    return out
end

function M:activity()
    if LilBubbyAutoRun and LilBubbyAutoRun.Running() then return "Run every test is running" end
    local lines = self:recentLines()
    local last = lines[#lines]
    if not last then return "Waiting for results" end
    return last.level == "STARTED" and "Test running" or "Latest results"
end

function M:prerender()
    ISPanel.prerender(self)
    local width = self.width - 16
    self:drawText(fit("lilBubby tests | " .. self:activity(), self.width - 124), 8, 6, 0.85, 0.75, 1, 1, UIFont.Small)
    local y = 28
    local lines = self:recentLines()
    if #lines == 0 then
        self:drawText("Results appear here as the test runs.", 8, y, 0.6, 0.6, 0.6, 1, UIFont.Small)
    end
    for _, line in ipairs(lines) do
        local color = COLORS[line.level] or COLORS.INFO
        self:drawText(fit(line.text, width), 8, y, color[1], color[2], color[3], 1, UIFont.Small)
        y = y + lineHeight()
    end
end

function M:hide()
    self:setVisible(false)
    self:removeFromUIManager()
end

function M:openShowcase()
    self:hide()
    local player = getSpecificPlayer(self.playerNum)
    if player then S.Open(player) end
end

function M.Show(index)
    local strip = M.windows[index]
    if not strip then
        strip = M:new(index)
        strip:initialise()
        M.windows[index] = strip
    end
    strip:setVisible(true)
    strip:addToUIManager()
    strip:bringToTop()
    return strip
end

function M.Hide(index)
    local strip = M.windows[index]
    if strip then strip:hide() end
end

return LilBubbyMiniUI
