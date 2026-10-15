-- ServerM8 browser card.
--
-- A separate panel placed over the vanilla server browser's detail panel. It
-- reads the server the vanilla browser has selected and draws it its own way.
-- No vanilla file, function or table is replaced: the vanilla panel keeps
-- running underneath, and the "Classic view" button uncovers it.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISRichTextPanel"
require "ServerM8_Util"
require "ServerM8_Web"

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)
local BUTTON_HGT = FONT_HGT_SMALL + 10
local CHIP_HGT = FONT_HGT_SMALL + 6
local PAD = 12
local GAP = 8
local SETTINGS_FILE = "ServerM8_client.ini"
local T = ServerM8.Theme

ServerM8BrowserCard = ISPanel:derive("ServerM8BrowserCard")

local function str(value, fallback)
    if value == nil then return fallback or "-" end
    value = tostring(value)
    if value == "" then return fallback or "-" end
    return value
end

local function fit(text, font, maxWidth)
    local tm = getTextManager()
    if tm:MeasureStringX(font, text) <= maxWidth then return text end
    while #text > 1 and tm:MeasureStringX(font, text .. "...") > maxWidth do
        text = string.sub(text, 1, #text - 1)
    end
    return text .. "..."
end

local function loadClassic()
    local reader = getFileReader(SETTINGS_FILE, false)
    if not reader then return false end
    local line = reader:readLine()
    reader:close()
    return line == "classic=1"
end

local function saveClassic(classic)
    local writer = getFileWriter(SETTINGS_FILE, true, false)
    if not writer then return end
    writer:write(classic and "classic=1" or "classic=0")
    writer:close()
end

function ServerM8BrowserCard:makeButton(title, onclick, color)
    local button = ISButton:new(0, 0, 100, BUTTON_HGT, title, self, onclick)
    button:initialise()
    button:instantiate()
    button.borderColor = { r = T.border.r, g = T.border.g, b = T.border.b, a = 1 }
    if color then
        button.backgroundColor = { r = color.r * 0.55, g = color.g * 0.55, b = color.b * 0.55, a = 1 }
        button.backgroundColorMouseOver = { r = color.r * 0.8, g = color.g * 0.8, b = color.b * 0.8, a = 1 }
        button.borderColor = { r = color.r, g = color.g, b = color.b, a = 1 }
    else
        button.backgroundColor = { r = T.panel.r, g = T.panel.g, b = T.panel.b, a = 1 }
        button.backgroundColorMouseOver = { r = T.border.r, g = T.border.g, b = T.border.b, a = 1 }
    end
    self:addChild(button)
    return button
end

function ServerM8BrowserCard:createChildren()
    self.joinBtn = self:makeButton("Join", ServerM8BrowserCard.onJoin, T.accent)
    self.favBtn = self:makeButton("Add favourite", ServerM8BrowserCard.onFavourite)
    self.discordBtn = self:makeButton("Discord", ServerM8BrowserCard.onDiscord, T.discord)
    self.aboutBtn = self:makeButton("About", ServerM8BrowserCard.onTabAbout)
    self.modsBtn = self:makeButton("Mods", ServerM8BrowserCard.onTabMods)

    self.body = ISRichTextPanel:new(0, 0, 100, 100)
    self.body:initialise()
    self.body.background = false
    self.body.autosetheight = false
    self.body.clip = true
    self.body:addScrollBars()
    self.body.render = function(panel)
        panel:setStencilRect(0, 0, panel:getWidth(), panel:getHeight())
        ISRichTextPanel.render(panel)
        panel:clearStencilRect()
    end
    self:addChild(self.body)

    self.toggleBtn = self:makeButton("Classic view", ServerM8BrowserCard.onToggleClassic)
    self.toggleBtn:setWidthToTitle(0)
    self.toggleWidthFull = self.toggleBtn:getWidth()
    self.toggleWidthClassic = getTextManager():MeasureStringX(UIFont.Small, "ServerM8 view") + 20

    self:applyClassic()
end

function ServerM8BrowserCard:setContentVisible(visible)
    if self.contentVisible == visible then return end
    self.contentVisible = visible
    self.joinBtn:setVisible(visible)
    self.favBtn:setVisible(visible)
    self.discordBtn:setVisible(visible)
    self.aboutBtn:setVisible(visible)
    self.modsBtn:setVisible(visible)
    self.body:setVisible(visible)
end

function ServerM8BrowserCard:applyClassic()
    if self.classic then
        self.toggleBtn:setTitle("ServerM8 view")
        self.toggleBtn:setWidth(self.toggleWidthClassic)
        self:setContentVisible(false)
    else
        self.toggleBtn:setTitle("Classic view")
        self.toggleBtn:setWidth(self.toggleWidthFull)
    end
end

-- Follows the vanilla detail panel so the card always covers exactly that area.
function ServerM8BrowserCard:syncTo(browser)
    local panel = browser.rightPanel
    if self.classic then
        local w = self.toggleBtn:getWidth()
        self:setX(panel:getAbsoluteX() + panel:getWidth() - w - PAD - 2)
        self:setY(panel:getAbsoluteY() + PAD + 2)
        self:setWidth(w)
        self:setHeight(BUTTON_HGT)
        self.toggleBtn:setX(0)
        self.toggleBtn:setY(0)
    else
        self:setX(panel:getAbsoluteX())
        self:setY(panel:getAbsoluteY())
        self:setWidth(panel:getWidth())
        self:setHeight(panel:getHeight())
        self.toggleBtn:setX(self.width - self.toggleBtn:getWidth() - PAD)
        self.toggleBtn:setY(PAD)
    end
end

function ServerM8BrowserCard:refreshBody()
    local info = self.info
    if not info then return end
    local text
    if self.tab == "mods" then
        if #info.mods == 0 then
            text = ServerM8.rgb(T.muted) .. "This server does not list any mods."
        else
            local lines = {}
            for _, mod in ipairs(info.mods) do
                table.insert(lines, ServerM8.escape(mod))
            end
            text = ServerM8.rgb(T.muted) .. #info.mods .. " mods load when you join. <LINE> <LINE> "
                .. ServerM8.rgb(T.text) .. table.concat(lines, " <LINE> ")
        end
    else
        if info.description == "" then
            text = ServerM8.rgb(T.muted) .. "This server has not published a description."
        else
            -- Same as vanilla: the description is shown as the server wrote it.
            text = info.description
        end
    end
    self.body.text = text
    self.body:paginate()
    self.body:setYScroll(0)
end

-- Rebuilds the cached view of the selected server when its data changes.
-- Description, mods and version arrive from Steam a moment after selection.
function ServerM8BrowserCard:updateInfo(server)
    local name = str(server:getName(), "Unnamed server")
    local description = server:getDescription() or ""
    local modString = server:getMods() or ""
    local version = str(server:getVersion(), "")
    local open = server:isOpen()
    local password = server:isPasswordProtected()
    local old = self.info
    if old and old.server == server and old.name == name and old.description == description
        and old.modString == modString and old.version == version and old.open == open
        and old.password == password and old.width == self.width then
        return
    end

    local info = {
        server = server, name = name, description = description, modString = modString,
        version = version, open = open, password = password, width = self.width,
    }

    info.mods = {}
    for entry in string.gmatch(modString, "[^;,]+") do
        local mod = ServerM8.trim(entry)
        if mod ~= "" then table.insert(info.mods, mod) end
    end

    info.discord = ServerM8.findDiscordInvite(description)
    info.nameFit = fit(name, UIFont.Large, self.width - PAD * 2)

    info.chips = {}
    if version ~= "" then table.insert(info.chips, { text = "v" .. version, color = T.info }) end
    if open then
        table.insert(info.chips, { text = "Open", color = T.good })
    else
        table.insert(info.chips, { text = "Whitelist", color = T.warn })
    end
    if password then table.insert(info.chips, { text = "Password", color = T.warn }) end
    if #info.mods > 0 then
        table.insert(info.chips, { text = #info.mods .. " mods", color = T.muted })
    else
        table.insert(info.chips, { text = "Vanilla", color = T.muted })
    end
    for _, tag in ipairs(ServerM8.findHashtags(description)) do
        table.insert(info.chips, { text = tag, color = T.accent })
    end

    self.info = info
    self.modsBtn:setTitle("Mods (" .. #info.mods .. ")")
    self:refreshBody()
end

function ServerM8BrowserCard:drawChip(text, x, y, color)
    local w = getTextManager():MeasureStringX(UIFont.Small, text) + 14
    self:drawRect(x, y, w, CHIP_HGT, 0.18, color.r, color.g, color.b)
    self:drawRectBorder(x, y, w, CHIP_HGT, 0.7, color.r, color.g, color.b)
    self:drawText(text, x + 7, y + 3, color.r, color.g, color.b, 1, UIFont.Small)
    return w
end

function ServerM8BrowserCard:drawTile(x, y, w, h, label, value, color)
    self:drawRect(x, y, w, h, 1, T.panel.r, T.panel.g, T.panel.b)
    self:drawRectBorder(x, y, w, h, 1, T.border.r, T.border.g, T.border.b)
    self:drawText(label, x + 8, y + 5, T.muted.r, T.muted.g, T.muted.b, 1, UIFont.Small)
    self:drawText(fit(value, UIFont.Medium, w - 16), x + 8, y + 5 + FONT_HGT_SMALL, color.r, color.g, color.b, 1, UIFont.Medium)
end

function ServerM8BrowserCard:setTabStyle(button, active)
    if active then
        button.backgroundColor = { r = T.border.r, g = T.border.g, b = T.border.b, a = 1 }
        button.borderColor = { r = T.accent.r, g = T.accent.g, b = T.accent.b, a = 1 }
    else
        button.backgroundColor = { r = T.panel.r, g = T.panel.g, b = T.panel.b, a = 1 }
        button.borderColor = { r = T.border.r, g = T.border.g, b = T.border.b, a = 1 }
    end
end

function ServerM8BrowserCard:prerender()
    local browser = MultiplayerUI and MultiplayerUI.instance
    if not browser or not browser:isReallyVisible() then
        self:setVisible(false)
        return
    end
    if self.classic then return end

    local w, h = self.width, self.height
    self:drawRect(0, 0, w, h, 1, T.bg.r, T.bg.g, T.bg.b)
    self:drawRectBorder(0, 0, w, h, 1, T.border.r, T.border.g, T.border.b)

    -- Banner with the server name on a dark strip.
    local bannerH = math.floor(w * 0.24)
    if self.banner then
        self:drawTextureScaled(self.banner, 1, 1, w - 2, bannerH, 1, 0.55, 0.55, 0.55)
    else
        self:drawRect(1, 1, w - 2, bannerH, 1, T.panel.r, T.panel.g, T.panel.b)
    end
    local stripH = FONT_HGT_LARGE + PAD
    self:drawRect(1, 1 + bannerH - stripH, w - 2, stripH, 0.72, 0, 0, 0)
    self:drawRect(1, 1 + bannerH, w - 2, 2, 1, T.accent.r, T.accent.g, T.accent.b)

    local server = browser.selectedInternetServer
    if not server then
        self:setContentVisible(false)
        self:drawTextCentre("Select a server to see its details", w / 2, bannerH + PAD * 3, T.muted.r, T.muted.g, T.muted.b, 1, UIFont.Medium)
        return
    end

    self:updateInfo(server)
    self:setContentVisible(true)
    local info = self.info

    self:drawText(info.nameFit, PAD, 1 + bannerH - stripH + PAD / 2, T.text.r, T.text.g, T.text.b, 1, UIFont.Large)

    local innerW = w - PAD * 2
    local y = bannerH + 3 + PAD

    -- Chips: version, access, mods and any #hashtags from the description.
    local chipX = PAD
    for _, chip in ipairs(info.chips) do
        local chipW = getTextManager():MeasureStringX(UIFont.Small, chip.text) + 14
        if chipX + chipW > w - PAD and chipX > PAD then
            chipX = PAD
            y = y + CHIP_HGT + 6
        end
        self:drawChip(chip.text, chipX, y, chip.color)
        chipX = chipX + chipW + 6
    end
    y = y + CHIP_HGT + PAD

    -- Population bar.
    local players = tonumber(server:getPlayers()) or 0
    local maxPlayers = tonumber(server:getMaxPlayers()) or 0
    local ratio = 0
    if maxPlayers > 0 then ratio = math.min(1, players / maxPlayers) end
    local fill = T.good
    if ratio >= 0.9 then fill = T.bad elseif ratio >= 0.6 then fill = T.warn end
    self:drawText("Players", PAD, y, T.muted.r, T.muted.g, T.muted.b, 1, UIFont.Small)
    self:drawTextRight(players .. " / " .. maxPlayers, w - PAD, y, T.text.r, T.text.g, T.text.b, 1, UIFont.Small)
    y = y + FONT_HGT_SMALL + 4
    self:drawRect(PAD, y, innerW, 8, 1, T.panel.r, T.panel.g, T.panel.b)
    if ratio > 0 then
        self:drawRect(PAD, y, math.max(2, math.floor(innerW * ratio)), 8, 1, fill.r, fill.g, fill.b)
    end
    self:drawRectBorder(PAD, y, innerW, 8, 1, T.border.r, T.border.g, T.border.b)
    y = y + 8 + PAD

    -- Tiles: ping, map, last wipe.
    local tileW = math.floor((innerW - GAP * 2) / 3)
    local tileH = FONT_HGT_SMALL + FONT_HGT_MEDIUM + 12
    local ping = tonumber(server:getPing())
    local pingText, pingColor = "-", T.muted
    if ping and ping >= 0 then
        pingText = math.floor(ping) .. " ms"
        pingColor = T.good
        if ping >= 160 then pingColor = T.bad elseif ping >= 80 then pingColor = T.warn end
    end
    local wipe = tonumber(server:getLastWipe()) or 0
    local wipeText = "Unknown"
    if wipe > 0 then
        local days = math.floor((getTimestamp() - wipe) / 86400)
        if days <= 0 then wipeText = "Today" elseif days == 1 then wipeText = "1 day ago" else wipeText = days .. " days ago" end
    end
    self:drawTile(PAD, y, tileW, tileH, "Ping", pingText, pingColor)
    self:drawTile(PAD + tileW + GAP, y, tileW, tileH, "Map", str(server:getMapName()), T.text)
    self:drawTile(PAD + (tileW + GAP) * 2, y, innerW - (tileW + GAP) * 2, tileH, "Last wipe", wipeText, T.text)
    y = y + tileH + GAP

    -- Address. getDisplayIp/getDisplayPort respect the vanilla "show IP addresses" setting.
    self:drawText(str(server:getDisplayIp()) .. " : " .. str(server:getDisplayPort()), PAD, y, T.muted.r, T.muted.g, T.muted.b, 1, UIFont.Small)
    y = y + FONT_HGT_SMALL + PAD

    -- Actions.
    local onInternetTab = browser.tabs:getActiveViewIndex() == 2
    local btnW = math.floor((innerW - GAP * 2) / 3)
    self.joinBtn:setX(PAD); self.joinBtn:setY(y); self.joinBtn:setWidth(btnW)
    self.favBtn:setX(PAD + btnW + GAP); self.favBtn:setY(y); self.favBtn:setWidth(btnW)
    self.discordBtn:setX(PAD + (btnW + GAP) * 2); self.discordBtn:setY(y); self.discordBtn:setWidth(innerW - (btnW + GAP) * 2)

    if self.joinEnabled ~= onInternetTab then
        self.joinEnabled = onInternetTab
        self.joinBtn:setEnable(onInternetTab)
        self.joinBtn:setTooltip((not onInternetTab) and "Double-click an account in the list to join with it." or nil)
    end
    local featured = browser.selectedInternetServerFeatured and true or false
    if self.favState ~= featured then
        self.favState = featured
        self.favBtn:setTitle(featured and "Remove favourite" or "Add favourite")
    end
    local hasDiscord = info.discord ~= nil
    if self.discordState ~= hasDiscord then
        self.discordState = hasDiscord
        self.discordBtn:setEnable(hasDiscord)
        self.discordBtn:setTooltip(hasDiscord and "Opens this server's Discord inside the game."
            or "This server has no Discord invite link in its description.")
    end
    y = y + BUTTON_HGT + PAD

    -- About / Mods.
    local tabW = math.floor((innerW - GAP) / 2)
    self.aboutBtn:setX(PAD); self.aboutBtn:setY(y); self.aboutBtn:setWidth(tabW)
    self.modsBtn:setX(PAD + tabW + GAP); self.modsBtn:setY(y); self.modsBtn:setWidth(innerW - tabW - GAP)
    if self.tabStyled ~= self.tab then
        self.tabStyled = self.tab
        self:setTabStyle(self.aboutBtn, self.tab == "about")
        self:setTabStyle(self.modsBtn, self.tab == "mods")
    end
    y = y + BUTTON_HGT + 4

    local bodyH = math.max(40, h - y - 4)
    local bodyW = w - 4
    self.body:setX(2)
    self.body:setY(y)
    if self.body:getWidth() ~= bodyW or self.body:getHeight() ~= bodyH then
        self.body:setWidth(bodyW)
        self.body:setHeight(bodyH)
        self.body:paginate()
    end
end

function ServerM8BrowserCard:onJoin()
    local browser = MultiplayerUI.instance
    if browser and browser.selectedInternetServer then
        browser:connectFromBrowser()
    end
end

function ServerM8BrowserCard:onFavourite()
    local browser = MultiplayerUI.instance
    if browser and browser.selectedInternetServer then
        -- Hands off to the vanilla favourites handler.
        browser:onOptionMouseDown({ internal = "FAVOURITES" })
    end
end

function ServerM8BrowserCard:onDiscord()
    if self.info and self.info.discord then
        ServerM8.openWeb(ServerM8.inviteUrl(self.info.discord), "Discord: " .. self.info.name)
    end
end

function ServerM8BrowserCard:onTabAbout()
    self.tab = "about"
    self:refreshBody()
end

function ServerM8BrowserCard:onTabMods()
    self.tab = "mods"
    self:refreshBody()
end

function ServerM8BrowserCard:onToggleClassic()
    self.classic = not self.classic
    saveClassic(self.classic)
    self:applyClassic()
    local browser = MultiplayerUI and MultiplayerUI.instance
    if browser then self:syncTo(browser) end
end

function ServerM8BrowserCard:new()
    local o = ISPanel.new(self, 0, 0, 100, 100)
    o.background = false
    o.tab = "about"
    o.classic = loadClassic()
    o.banner = getTexture("media/ui/MP/mp_ui_default_banner.png")
    return o
end

-- Shows the card while the vanilla browser's detail panel is on screen.
local function onFETick()
    local browser = MultiplayerUI and MultiplayerUI.instance
    local card = ServerM8BrowserCard.instance
    local show = browser ~= nil and browser.rightPanel ~= nil and browser.tabs ~= nil
        and browser:isReallyVisible() and browser.rightPanel:isVisible()
        and not (browser.screenShading and browser.screenShading:isVisible())
    if not show then
        if card and card:isVisible() then card:setVisible(false) end
        return
    end
    if not card then
        card = ServerM8BrowserCard:new()
        card:initialise()
        card:addToUIManager()
        ServerM8BrowserCard.instance = card
        card:setVisible(false)
    end
    if not card:isVisible() then
        card:setVisible(true)
        card:bringToTop()
    end
    card:syncTo(browser)
end

local function removeCard()
    local card = ServerM8BrowserCard.instance
    if card then
        card:setVisible(false)
        card:removeFromUIManager()
        ServerM8BrowserCard.instance = nil
    end
end

Events.OnFETick.Add(onFETick)
Events.OnGameStart.Add(removeCard)
Events.OnResetLua.Add(removeCard)
