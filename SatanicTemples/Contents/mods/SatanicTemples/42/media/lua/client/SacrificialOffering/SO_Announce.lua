require "ISUI/ISUIElement"
require "SacrificialOffering/SO_Util"

-- Big, centred, slow-fading on-screen banner for player-facing announcements.
-- Ritual results and other important notices are routed through this.

local SO = SacrificialOffering
SO.Announce = SO.Announce or {}
local Announce = SO.Announce
Announce.Pending = Announce.Pending or {}

-- ---------------------------------------------------------------------------
-- Tunables - bump these to make announcements bigger or linger longer.
-- ---------------------------------------------------------------------------
local FONT = UIFont.Large     -- text size (UIFont.Medium < Large < Massive)
local HOLD_MS = 10000         -- fully-opaque time before the fade starts
local FADE_MS = 2000          -- fade-out duration
local WIDTH_FRAC = 0.6        -- max banner width as a fraction of the screen
local TOP_FRAC = 0.14         -- vertical position of the banner (0 = top)
local LINE_SPACING = 6        -- extra pixels between wrapped lines
local PAD = 16                -- padding inside the backdrop box

local GOOD_COLOR = { r = 0.45, g = 0.92, b = 0.45 }
local BAD_COLOR = { r = 0.94, g = 0.32, b = 0.30 }

-- ---------------------------------------------------------------------------

local Panel = ISUIElement:derive("SO_AnnouncePanel")

local function wrapText(text, maxWidth)
    local manager = getTextManager()
    local lines = {}
    local current = nil
    for word in string.gmatch(text or "", "%S+") do
        local candidate = current and (current .. " " .. word) or word
        if current and manager:MeasureStringX(FONT, candidate) > maxWidth then
            lines[#lines + 1] = current
            current = word
        else
            current = candidate
        end
    end
    if current then lines[#lines + 1] = current end
    if #lines == 0 then lines[1] = "" end
    return lines
end

function Panel:setMessage(text, color)
    local maxWidth = math.floor(getCore():getScreenWidth() * WIDTH_FRAC)
    self.lines = wrapText(text, maxWidth)
    self.color = color or GOOD_COLOR
    self.shownAt = SO.Util.NowMs()

    local manager = getTextManager()
    local lineHeight = manager:getFontHeight(FONT) + LINE_SPACING
    local widest = 0
    for _, line in ipairs(self.lines) do
        widest = math.max(widest, manager:MeasureStringX(FONT, line))
    end

    self:setWidth(widest + PAD * 2)
    self:setHeight(#self.lines * lineHeight - LINE_SPACING + PAD * 2)
    self:setX(math.floor((getCore():getScreenWidth() - self:getWidth()) / 2))
    self:setY(math.floor(getCore():getScreenHeight() * TOP_FRAC))
    self:setVisible(true)
end

function Panel:render()
    if not self.lines or not self.shownAt then return end

    local age = SO.Util.NowMs() - self.shownAt
    if age >= HOLD_MS + FADE_MS then
        self:setVisible(false)
        self.lines = nil
        local pending = table.remove(Announce.Pending, 1)
        if pending then self:setMessage(pending.text, pending.color) end
        return
    end

    local alpha = 1.0
    if age > HOLD_MS then
        alpha = 1.0 - (age - HOLD_MS) / FADE_MS
    end

    self:drawRect(0, 0, self:getWidth(), self:getHeight(), 0.55 * alpha, 0, 0, 0)
    self:drawRectBorder(0, 0, self:getWidth(), self:getHeight(), 0.7 * alpha,
        self.color.r, self.color.g, self.color.b)

    local manager = getTextManager()
    local lineHeight = manager:getFontHeight(FONT) + LINE_SPACING
    local y = PAD
    for _, line in ipairs(self.lines) do
        self:drawTextCentre(line, self:getWidth() / 2, y, self.color.r, self.color.g, self.color.b, alpha, FONT)
        y = y + lineHeight
    end
end

local function ensurePanel()
    if Announce.Panel then return Announce.Panel end
    local panel = Panel:new(0, 0, 10, 10)
    panel:initialise()
    panel:instantiate()
    panel:setVisible(false)
    panel:addToUIManager()
    Announce.Panel = panel
    return panel
end

-- Show a banner. tone is "good" (default) or "bad".
function Announce.Show(text, tone)
    if not text or text == "" then return end
    local color = tone == "bad" and BAD_COLOR or GOOD_COLOR
    ensurePanel():setMessage(text, color)
end

-- Preserve the current announcement and show this one as soon as it finishes.
-- Ritual over-budget judgments use this for Satan's additional spoken rebuke.
function Announce.Enqueue(text, tone)
    if not text or text == "" then return end
    local color = tone == "bad" and BAD_COLOR or GOOD_COLOR
    local panel = ensurePanel()
    if panel:isVisible() and panel.lines then
        Announce.Pending[#Announce.Pending + 1] = { text = text, color = color }
    else
        panel:setMessage(text, color)
    end
end

return Announce
