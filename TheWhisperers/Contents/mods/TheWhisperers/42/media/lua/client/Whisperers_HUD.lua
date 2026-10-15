-- The Whisperers: noise meter HUD. Shown while the player is camouflaged (or
-- while the meter is still draining afterwards). Drag to reposition.
require "ISUI/ISUIElement"
require "Whisperers_Client"

local W = Whisperers

WhisperersHUD = ISUIElement:derive("WhisperersHUD")

local WIDTH, HEIGHT = 240, 50
local PAD = 6
local BAR_H = 10

local function lerp(a, b, t) return a + (b - a) * t end

-- Green -> amber at the notice mark -> red at full.
local function meterColor(m, notice)
    if m < notice then
        local t = m / notice
        return lerp(0.35, 0.95, t), lerp(0.75, 0.75, t), lerp(0.35, 0.2, t)
    end
    local t = (m - notice) / (W.FullMeter - notice)
    return lerp(0.95, 0.85, t), lerp(0.75, 0.1, t), lerp(0.2, 0.08, t)
end

local function statusKey(st, notice)
    if st.meter >= W.FullMeter - 0.5 then return "IGUI_Whisperers_StatusHerd" end
    if st.meter >= notice then return "IGUI_Whisperers_StatusNoticed" end
    if st.meter > 0.5 then return "IGUI_Whisperers_StatusUneasy" end
    return "IGUI_Whisperers_StatusHidden"
end

function WhisperersHUD:new(x, y, playerNum)
    local o = ISUIElement.new(self, x, y, WIDTH, HEIGHT)
    o.playerNum = playerNum
    o.dragging = false
    return o
end

function WhisperersHUD:render()
    local st = W.Client.States[self.playerNum]
    if not st then return end

    self:drawRect(0, 0, self.width, self.height, 0.7, 0.05, 0.04, 0.04)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.35, 0.3, 0.28)

    local font = UIFont.Small
    local title = getText("IGUI_Whisperers_Title")
    self:drawText(title, PAD, 2, 0.85, 0.8, 0.75, 1, font)
    local goreText = getText("IGUI_Whisperers_Gore", math.floor(st.gore + 0.5))
    if (st.multiplier or 1) > 1 then
        goreText = goreText .. "  x" .. math.floor(st.multiplier + 0.5)
    end
    local gw = getTextManager():MeasureStringX(font, goreText)
    self:drawText(goreText, self.width - PAD - gw, 2, 0.75, 0.2, 0.2, 1, font)

    local barY = 20
    local barW = self.width - PAD * 2
    self:drawRect(PAD, barY, barW, BAR_H, 0.9, 0.12, 0.1, 0.1)
    local notice = W.noticeAt(st.disguise)
    local r, g, b = meterColor(st.meter, notice)
    local alpha = 1
    if st.meter >= W.FullMeter - 0.5 then
        alpha = 0.6 + 0.4 * math.abs(math.sin(getTimestampMs() / 200))
    end
    self:drawRect(PAD, barY, barW * st.meter / W.FullMeter, BAR_H, alpha, r, g, b)
    self:drawRect(PAD + math.floor(barW * notice / W.FullMeter), barY - 2, 1, BAR_H + 4, 0.9, 0.9, 0.9, 0.9)
    self:drawRectBorder(PAD, barY, barW, BAR_H, 0.8, 0.4, 0.35, 0.3)

    local status = getText(statusKey(st, notice))
    if not st.active then status = getText("IGUI_Whisperers_StatusExposed") end
    local sw = getTextManager():MeasureStringX(font, status)
    self:drawText(status, (self.width - sw) / 2, barY + BAR_H + 3, r, g, b, 1, font)
end

function WhisperersHUD:onMouseDown(x, y)
    self.dragging = true
    return true
end

function WhisperersHUD:onMouseMove(dx, dy)
    if self.dragging then
        self:setX(self:getX() + dx)
        self:setY(self:getY() + dy)
    end
    return self.dragging
end

function WhisperersHUD:onMouseMoveOutside(dx, dy)
    return self:onMouseMove(dx, dy)
end

function WhisperersHUD:onMouseUp()
    if self.dragging then
        self.dragging = false
        local player = getSpecificPlayer(self.playerNum)
        if player then
            local md = player:getModData()
            md.WhisperersHudX, md.WhisperersHudY = self:getX(), self:getY()
        end
    end
    return true
end

function WhisperersHUD:onMouseUpOutside()
    return self:onMouseUp()
end

local huds = {}
W.HUD = huds -- read by lilBubby's Big ol Mod Tester

local function createHud(playerNum, player)
    if huds[playerNum] then
        huds[playerNum]:removeFromUIManager()
    end
    local md = player:getModData()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local x = md.WhisperersHudX or math.floor((sw - WIDTH) / 2)
    local y = md.WhisperersHudY or (sh - 190)
    x = W.clamp(x, 0, sw - WIDTH)
    y = W.clamp(y, 0, sh - HEIGHT)

    local hud = WhisperersHUD:new(x, y, playerNum)
    hud:initialise()
    hud:addToUIManager()
    hud:setVisible(false)
    huds[playerNum] = hud
end

local function onCreatePlayer(playerNum, player)
    if playerNum == 0 then createHud(playerNum, player) end
end

-- Only the split-screen primary player gets a HUD.
local function onTick()
    local hud = huds[0]
    if not hud then return end
    local st = W.Client.States[0]
    local show = st ~= nil and W.Get("Enabled") and (st.active or st.meter > 0.5)
    if hud:isVisible() ~= show then hud:setVisible(show) end
end

Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnTick.Add(onTick)
