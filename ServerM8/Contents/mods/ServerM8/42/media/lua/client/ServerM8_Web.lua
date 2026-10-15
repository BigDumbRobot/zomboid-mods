-- Opens web pages inside the game through the Steam overlay.
-- When the overlay is unavailable, shows a small panel with the link instead.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ServerM8_Util"

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local BUTTON_HGT = FONT_HGT_SMALL + 10
local PAD = 14
local T = ServerM8.Theme

ServerM8LinkPanel = ISPanel:derive("ServerM8LinkPanel")

function ServerM8LinkPanel:createChildren()
    local btnW = 150
    local y = self.height - BUTTON_HGT - PAD

    self.copyBtn = ISButton:new(PAD, y, btnW, BUTTON_HGT, "Copy link", self, ServerM8LinkPanel.onCopy)
    self.copyBtn:initialise()
    self.copyBtn:instantiate()
    self.copyBtn.borderColor = { r = T.border.r, g = T.border.g, b = T.border.b, a = 1 }
    self:addChild(self.copyBtn)

    self.browserBtn = ISButton:new(PAD + btnW + 8, y, btnW, BUTTON_HGT, "Open in web browser", self, ServerM8LinkPanel.onBrowser)
    self.browserBtn:initialise()
    self.browserBtn:instantiate()
    self.browserBtn.borderColor = { r = T.border.r, g = T.border.g, b = T.border.b, a = 1 }
    self:addChild(self.browserBtn)

    self.closeBtn = ISButton:new(self.width - PAD - 90, y, 90, BUTTON_HGT, "Close", self, ServerM8LinkPanel.onClose)
    self.closeBtn:initialise()
    self.closeBtn:instantiate()
    self.closeBtn.borderColor = { r = T.border.r, g = T.border.g, b = T.border.b, a = 1 }
    self:addChild(self.closeBtn)
end

function ServerM8LinkPanel:prerender()
    self:drawRect(0, 0, self.width, self.height, 0.97, T.bg.r, T.bg.g, T.bg.b)
    self:drawRectBorder(0, 0, self.width, self.height, 1, T.border.r, T.border.g, T.border.b)
    self:drawRect(1, 1, self.width - 2, 3, 1, T.discord.r, T.discord.g, T.discord.b)

    local y = PAD
    self:drawText(self.label, PAD, y, T.text.r, T.text.g, T.text.b, 1, UIFont.Medium)
    y = y + FONT_HGT_MEDIUM + 6
    self:drawText("The Steam overlay is turned off, so this page cannot open inside the game.", PAD, y, T.muted.r, T.muted.g, T.muted.b, 1, UIFont.Small)
    y = y + FONT_HGT_SMALL + 2
    self:drawText("Turn it on in Steam > Settings > In Game to stay in the game next time.", PAD, y, T.muted.r, T.muted.g, T.muted.b, 1, UIFont.Small)
    y = y + FONT_HGT_SMALL + 10
    self:drawText(self.url, PAD, y, T.info.r, T.info.g, T.info.b, 1, UIFont.Small)
    if self.copied then
        y = y + FONT_HGT_SMALL + 4
        self:drawText("Link copied.", PAD, y, T.good.r, T.good.g, T.good.b, 1, UIFont.Small)
    end
end

function ServerM8LinkPanel:onCopy()
    Clipboard.setClipboard(self.url)
    self.copied = true
end

function ServerM8LinkPanel:onBrowser()
    openUrl(self.url)
    self:onClose()
end

function ServerM8LinkPanel:onClose()
    self:setVisible(false)
    self:removeFromUIManager()
    if ServerM8LinkPanel.instance == self then
        ServerM8LinkPanel.instance = nil
    end
end

function ServerM8LinkPanel:new(url, label)
    local width = math.max(520, getTextManager():MeasureStringX(UIFont.Small, url) + PAD * 2)
    width = math.min(width, getCore():getScreenWidth() - 40)
    local height = PAD * 2 + FONT_HGT_MEDIUM + FONT_HGT_SMALL * 4 + 30 + BUTTON_HGT
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local o = ISPanel.new(self, x, y, width, height)
    o.url = url
    o.label = label or "Link"
    o.background = false
    o.moveWithMouse = true
    return o
end

-- Opens url in the Steam overlay. Only ever called with links built by ServerM8_Util.
function ServerM8.openWeb(url, label)
    if not url or url == "" then return end
    if isSteamOverlayEnabled() then
        activateSteamOverlayToWebPage(url)
        return
    end
    if ServerM8LinkPanel.instance then
        ServerM8LinkPanel.instance:onClose()
    end
    local panel = ServerM8LinkPanel:new(url, label)
    panel:initialise()
    panel:addToUIManager()
    panel:setAlwaysOnTop(true)
    panel:bringToTop()
    ServerM8LinkPanel.instance = panel
end
