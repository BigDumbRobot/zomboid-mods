-- KIPN_EventPlayerHUD.lua
--
-- What a participant sees while an event runs: a small strip at the
-- top of the screen with the event, their team or country, their goal
-- in one sentence, the clock, the score and which way to go, plus big
-- banners in the middle of the screen for announcements ("Round 2:
-- GO!", "The evac has arrived!", "Alice finishes in 2:31.4!").
--
-- Fed by the server's EVENT_PLAYER_HUD messages
-- (server/KIPN_EventGameLoopService.lua): a full HUD every few seconds
-- and banners as things happen. Clocks keep counting between updates.
-- The strip can be collapsed to one line; it hides itself a little
-- after the event ends.

if isServer() and not isClient() then return end

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "DynamicEvents_Shared"

KIPN_EventPlayerHUD = ISPanel:derive("KIPN_EventPlayerHUD")
local H = KIPN_EventPlayerHUD

H.BANNER_MS = 4500
H.HIDE_AFTER_END_MS = 25000
H.MAX_LINES = 5
-- Always-on screens fade to mostly see-through FADE_AFTER_MS after the
-- mouse leaves them, and come back when hovered (or when something new
-- arrives). FADED_ALPHA is how much of them still shows.
H.FADE_AFTER_MS = 5000
H.FADE_TIME_MS = 600
H.FADED_ALPHA = 0.2
local CLUE_COLOR = { 0.95, 0.88, 0.6 }

local function now()
    return getTimestampMs and getTimestampMs() or (os.time() * 1000)
end

local function clock(ms, tenths)
    ms = math.max(0, math.floor(ms or 0))
    if tenths then
        local t = math.floor(ms / 100)
        return string.format("%d:%02d.%d", math.floor(t / 600), math.floor(t / 10) % 60, t % 10)
    end
    local s = math.floor(ms / 1000)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function fit(text, width, font)
    local manager = getTextManager()
    text = tostring(text or "")
    if manager:MeasureStringX(font, text) <= width then return text end
    while #text > 0 and manager:MeasureStringX(font, text .. "...") > width do text = text:sub(1, -2) end
    return text .. "..."
end

-- Splits text into lines no wider than `width` in `font`.
local function wrap(text, width, font)
    local manager = getTextManager()
    local lines, current = {}, ""
    for word in tostring(text or ""):gmatch("%S+") do
        local candidate = current == "" and word or (current .. " " .. word)
        if current ~= "" and manager:MeasureStringX(font, candidate) > width then
            lines[#lines + 1] = current
            current = word
        else
            current = candidate
        end
    end
    if current ~= "" then lines[#lines + 1] = current end
    return lines
end

-- Mouse over a UI element's on-screen rectangle.
local function hovered(element)
    local ok, over = pcall(function()
        local mx, my = getMouseX(), getMouseY()
        local x, y = element:getAbsoluteX(), element:getAbsoluteY()
        return mx >= x and mx <= x + element.width and my >= y and my <= y + element.height
    end)
    return ok and over
end

-- Fade bookkeeping shared by the HUD and the live strip: returns the
-- alpha multiplier (1 = solid, FADED_ALPHA = faded).
function H.FadeAlpha(element)
    local t = now()
    if not element.lastWakeAt or hovered(element) then element.lastWakeAt = t end
    local idle = t - element.lastWakeAt - H.FADE_AFTER_MS
    if idle <= 0 then return 1 end
    local progress = math.min(1, idle / H.FADE_TIME_MS)
    return 1 - (1 - H.FADED_ALPHA) * progress
end

-- Applies an alpha multiplier to a button's colours.
function H.FadeButton(button, alpha)
    button.fadeBase = button.fadeBase or {
        bg = button.backgroundColor and button.backgroundColor.a or 1,
        border = button.borderColor and button.borderColor.a or 1,
        text = button.textColor and button.textColor.a or 1,
    }
    if button.backgroundColor then button.backgroundColor.a = button.fadeBase.bg * alpha end
    if button.borderColor then button.borderColor.a = button.fadeBase.border * alpha end
    if button.textColor then button.textColor.a = button.fadeBase.text * alpha end
end

local COMPASS = { "east", "south-east", "south", "south-west", "west", "north-west", "north", "north-east" }

-- atan2 without relying on math.atan2 being in this Lua build.
local function angleOf(dy, dx)
    if dx > 0 then return math.atan(dy / dx) end
    if dx < 0 then return math.atan(dy / dx) + (dy >= 0 and math.pi or -math.pi) end
    return dy > 0 and math.pi / 2 or -math.pi / 2
end

-- "42 m north-east" from the local player to a world point (north is -y).
local function direction(target)
    local player = getPlayer()
    if not player or not target then return nil end
    local dx, dy = target.x - player:getX(), target.y - player:getY()
    local distance = math.floor(math.sqrt(dx * dx + dy * dy))
    if distance < 3 then return "you are here" end
    local angle = angleOf(dy, dx)
    local index = (math.floor((angle / (2 * math.pi)) * 8 + 0.5) % 8) + 1
    return distance .. " m " .. COMPASS[index]
end

function H:new()
    local width = math.min(520, getCore():getScreenWidth() - 40)
    local o = ISPanel.new(self, math.floor((getCore():getScreenWidth() - width) / 2), 10, width, 120)
    o.moveWithMouse = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.55 }
    o.borderColor = { r = 0.80, g = 0.66, b = 0.25, a = 0.8 }
    o.hud = nil
    o.banners = {}
    o.clues = {}
    o.clueButtons = {}
    return o
end

function H:createChildren()
    ISPanel.createChildren(self)
    self.collapseButton = ISButton:new(self.width - 24, 4, 20, 18, "-", self, H.toggleCollapsed)
    self.collapseButton:initialise()
    self.collapseButton.tooltip = "Collapse or expand the event tracker"
    self:addChild(self.collapseButton)
end

function H:toggleCollapsed()
    self.collapsed = not self.collapsed
    self.collapseButton:setTitle(self.collapsed and "+" or "-")
end

-- Something new: show the strip in full for another FADE_AFTER_MS.
function H:wake()
    self.lastWakeAt = now()
end

function H:setHud(hud)
    if hud.clues then self:setClues(hud.clues) end
    if hud.banner then
        self.banners[#self.banners + 1] = { text = hud.banner, color = hud.bannerColor, title = hud.bannerTitle, long = hud.bannerLong }
        -- Pillow's stings: thunder for Dire, the death sound for Brutal.
        if hud.bannerSound then
            local player = getPlayer()
            if player then pcall(function() player:playSound(hud.bannerSound) end) end
        end
        while #self.banners > 6 do table.remove(self.banners, 1) end
    end
    -- A banner-only message leaves the strip as it was.
    if hud.goal or hud.title or hud.ended then
        if not self.hud or self.hud.goal ~= hud.goal or hud.ended then self:wake() end
        self.hud = hud
        self.receivedAt = now()
        if hud.ended then self.hideAt = now() + H.HIDE_AFTER_END_MS else self.hideAt = nil end
    end
end

------------------------------------------------------------
-- CLUES: one button per clue found; clicking replays it.
------------------------------------------------------------

function H:setClues(clues)
    local changed = #clues ~= #self.clues
    for index, clue in ipairs(clues) do
        local old = self.clues[index]
        if not old or old.title ~= clue.title or old.text ~= clue.text then changed = true end
    end
    if not changed then return end
    if #clues > #self.clues then self:wake() end
    self.clues = clues
    for _, button in ipairs(self.clueButtons) do self:removeChild(button) end
    self.clueButtons = {}
    for index, clue in ipairs(clues) do
        local title = tostring(clue.title or ("Clue " .. index))
        local width = getTextManager():MeasureStringX(UIFont.Small, title) + 16
        local button = ISButton:new(0, 0, width, 20, title, self, H.onClue)
        button.internal = index
        button:initialise()
        button.tooltip = "Show this again"
        button.borderColor = { r = CLUE_COLOR[1], g = CLUE_COLOR[2], b = CLUE_COLOR[3], a = 0.7 }
        self:addChild(button)
        self.clueButtons[#self.clueButtons + 1] = button
    end
end

function H:onClue(button)
    local clue = self.clues[button.internal]
    if not clue then return end
    -- Replace whatever banner is up with this clue, shown in full.
    if self.banners[1] and self.banners[1].replay then table.remove(self.banners, 1) end
    table.insert(self.banners, 1, { text = clue.text, color = CLUE_COLOR, title = clue.title, long = true, replay = true })
end

-- Lays the clue buttons out in rows from `y`; returns the y below them.
function H:layoutClues(y, alpha)
    if #self.clueButtons == 0 then return y end
    local x = 8
    for _, button in ipairs(self.clueButtons) do
        if x > 8 and x + button.width > self.width - 8 then
            x = 8
            y = y + 24
        end
        button:setX(x)
        button:setY(y)
        H.FadeButton(button, alpha)
        x = x + button.width + 6
    end
    return y + 24
end

-- Remaining time for a countdown field, counted down locally.
function H:left(ms)
    if not ms then return nil end
    return ms - (now() - (self.receivedAt or now()))
end

function H:prerender()
    local hud = self.hud
    local small, medium = UIFont.Small, UIFont.Medium
    local y = 6
    local width = self.width - 16
    local lines = {}

    if hud then
        local accent = hud.color or { 1.0, 0.82, 0.3 }
        local clockText
        if hud.stopwatchMs then
            clockText = "Time " .. clock(hud.stopwatchMs + (now() - self.receivedAt), true)
                .. (hud.limitLeftMs and ("   limit " .. clock(self:left(hud.limitLeftMs))) or "")
        elseif hud.phase and hud.phaseLeftMs then
            clockText = hud.phase .. " " .. clock(self:left(hud.phaseLeftMs))
        elseif hud.round and hud.round > 0 then
            clockText = "Round " .. hud.round .. " of " .. (hud.maxRounds or hud.round)
                .. (hud.roundLeftMs and ("   " .. clock(self:left(hud.roundLeftMs)) .. " left") or "")
        end
        if hud.eventLeftMs and not hud.stopwatchMs then
            clockText = (clockText and (clockText .. "   |   ") or "") .. "Event " .. clock(self:left(hud.eventLeftMs)) .. " left"
        end
        local head = tostring(hud.title or "Event") .. (hud.teamName and ("   |   " .. hud.teamName) or "")
        lines[#lines + 1] = { head, small, 0.75, 0.78, 0.85 }
        if not self.collapsed then
            if hud.goal then lines[#lines + 1] = { hud.goal, medium, accent[1], accent[2], accent[3] } end
            if clockText then lines[#lines + 1] = { clockText, small, 1, 1, 1 } end
            if hud.target then
                local where = direction(hud.target)
                if where then lines[#lines + 1] = { "> " .. tostring(hud.target.label or "Objective") .. ": " .. where, small, 0.55, 0.85, 1 } end
            end
            for index = 1, math.min(H.MAX_LINES, #(hud.lines or {})) do
                lines[#lines + 1] = { hud.lines[index], small, 0.82, 0.82, 0.82 }
            end
        end
    end

    -- Not in an event (a countdown or announcement to everyone): only
    -- the banner shows, with no empty strip; gone once it has played.
    local bare = not hud and #self.clueButtons == 0
    if bare and #self.banners == 0 then
        H.Hide()
        return
    end
    local alpha = bare and 0 or H.FadeAlpha(self)
    local textHeight = 0
    for _, entry in ipairs(lines) do textHeight = textHeight + getTextManager():getFontHeight(entry[2]) + 2 end
    local cluesBottom = self:layoutClues(6 + textHeight + 2, alpha)
    self:setHeight(math.max(28, cluesBottom + 4))
    self.backgroundColor.a = 0.55 * alpha
    self.borderColor.a = 0.8 * alpha
    self.collapseButton:setVisible(not bare)
    H.FadeButton(self.collapseButton, alpha)
    ISPanel.prerender(self)
    for _, entry in ipairs(lines) do
        self:drawText(fit(entry[1], width - (y == 6 and 24 or 0), entry[2]), 8, y, entry[3], entry[4], entry[5], alpha, entry[2])
        y = y + getTextManager():getFontHeight(entry[2]) + 2
    end
    self:drawBanner()
    if self.hideAt and now() >= self.hideAt then H.Hide() end
end

-- The oldest waiting banner, centred on screen, fading out.
function H:drawBanner()
    local banner = self.banners[1]
    if not banner then return end
    banner.shownAt = banner.shownAt or now()
    local age = now() - banner.shownAt
    -- Clues stay up long enough to read; several waiting move on faster.
    local duration = banner.long and math.min(16000, 4000 + 50 * #tostring(banner.text))
        or (#self.banners > 2 and 2500 or H.BANNER_MS)
    if age >= duration then
        table.remove(self.banners, 1)
        return
    end
    local alpha = age > duration - 800 and (duration - age) / 800 or 1
    local manager = getTextManager()
    local font = banner.long and UIFont.Medium or UIFont.Large
    local color = banner.color or { 1.0, 0.82, 0.3 }
    local screenWidth, screenHeight = getCore():getScreenWidth(), getCore():getScreenHeight()
    local maxWidth = banner.long and math.min(760, screenWidth - 80) or (screenWidth - 80)
    local lines = banner.long and wrap(banner.text, maxWidth, font) or { fit(banner.text, maxWidth, font) }
    local lineHeight = manager:getFontHeight(font) + 2
    local titleHeight = banner.title and (manager:getFontHeight(UIFont.Small) + 4) or 0
    local boxWidth = banner.title and manager:MeasureStringX(UIFont.Small, banner.title) or 0
    for _, line in ipairs(lines) do boxWidth = math.max(boxWidth, manager:MeasureStringX(font, line)) end
    local boxHeight = titleHeight + #lines * lineHeight
    local left = math.floor((screenWidth - boxWidth) / 2) - self:getAbsoluteX()
    local top = math.floor(screenHeight * 0.22) - self:getAbsoluteY()
    self:drawRect(left - 16, top - 8, boxWidth + 32, boxHeight + 16, 0.65 * alpha, 0, 0, 0)
    if banner.title then
        self:drawText(banner.title, left, top, 0.75, 0.72, 0.6, alpha, UIFont.Small)
    end
    for index, line in ipairs(lines) do
        local lineX = math.floor((screenWidth - manager:MeasureStringX(font, line)) / 2) - self:getAbsoluteX()
        self:drawText(line, banner.long and left or lineX, top + titleHeight + (index - 1) * lineHeight, color[1], color[2], color[3], alpha, font)
    end
end

function H.Show()
    if not H.instance then
        H.instance = H:new()
        H.instance:initialise()
    end
    H.instance:addToUIManager()
    H.instance:setVisible(true)
    return H.instance
end

function H.Hide()
    if H.instance then
        H.instance:setVisible(false)
        H.instance:removeFromUIManager()
        H.instance = nil
    end
end

local function onServerCommand(module, command, args)
    if module ~= "KIPN" or not args then return end
    local Shared = KIPN and KIPN.Shared
    if not Shared or command ~= Shared.Commands.SERVER_RESPONSE then return end
    if args.event ~= Shared.ResponseEvents.EVENT_PLAYER_HUD then return end
    H.Show():setHud(args.data or {})
end

Events.OnServerCommand.Add(onServerCommand)
