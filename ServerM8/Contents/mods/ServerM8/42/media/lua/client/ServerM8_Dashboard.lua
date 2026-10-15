-- ServerM8 in-game dashboard: what the server is, who is on, what has been
-- happening, and its Discord, without leaving the game.

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISRichTextPanel"
require "ServerM8_Util"
require "ServerM8_Web"

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)
local BUTTON_HGT = FONT_HGT_SMALL + 10
local PAD = 14
local GAP = 8
local REFRESH_SECONDS = 15
local T = ServerM8.Theme

local TABS = {
    { id = "overview", title = "Overview" },
    { id = "rules", title = "Rules" },
    { id = "activity", title = "Activity" },
    { id = "players", title = "Players" },
    { id = "discord", title = "Discord" },
}

ServerM8Dashboard = ISCollapsableWindow:derive("ServerM8Dashboard")
ServerM8Dashboard.snapshot = nil
ServerM8Dashboard.snapshotAt = 0
ServerM8Dashboard.lastRequest = 0
ServerM8Dashboard.shownOnJoin = false

local function cfg(key, default)
    local vars = SandboxVars and SandboxVars.ServerM8
    local value = vars and vars[key]
    if value == nil or value == "" then return default end
    return value
end

local function serverOption(method, name)
    local ok, value = pcall(function()
        local options = getServerOptions()
        if method == "getBoolean" then return options:getBoolean(name) end
        return options:getOption(name)
    end)
    if ok then return value end
    return nil
end

local function serverName()
    local name = cfg("DisplayName", nil)
    if name then return name end
    if isClient() then
        name = serverOption("getOption", "PublicName")
        if name and name ~= "" then return tostring(name) end
        name = getServerName()
        if name and name ~= "" then return tostring(name) end
    end
    return "Server"
end

local function discordInvite()
    return ServerM8.normalizeInvite(cfg("DiscordInvite", ""))
end

local function discordGuild()
    return ServerM8.normalizeGuildID(cfg("DiscordServerID", ""))
end

local function website()
    return ServerM8.normalizeWebsite(cfg("Website", ""))
end

function ServerM8Dashboard.requestSnapshot(command)
    local player = getPlayer()
    if not player then return end
    ServerM8Dashboard.lastRequest = getTimestamp()
    sendClientCommand(player, ServerM8.MODULE, command or "refresh", {})
end

function ServerM8Dashboard:makeButton(title, onclick, color)
    local button = ISButton:new(0, 0, 100, BUTTON_HGT, title, self, onclick)
    button:initialise()
    button:instantiate()
    if color then
        button.backgroundColor = { r = color.r * 0.55, g = color.g * 0.55, b = color.b * 0.55, a = 1 }
        button.backgroundColorMouseOver = { r = color.r * 0.8, g = color.g * 0.8, b = color.b * 0.8, a = 1 }
        button.borderColor = { r = color.r, g = color.g, b = color.b, a = 1 }
    else
        button.backgroundColor = { r = T.panel.r, g = T.panel.g, b = T.panel.b, a = 1 }
        button.backgroundColorMouseOver = { r = T.border.r, g = T.border.g, b = T.border.b, a = 1 }
        button.borderColor = { r = T.border.r, g = T.border.g, b = T.border.b, a = 1 }
    end
    self:addChild(button)
    return button
end

function ServerM8Dashboard:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight()

    -- Link buttons, right-aligned in the header.
    local x = self.width - PAD
    local y = top + PAD
    if website() then
        self.websiteBtn = self:makeButton("Website", ServerM8Dashboard.onWebsite)
        self.websiteBtn:setWidthToTitle(90)
        x = x - self.websiteBtn:getWidth()
        self.websiteBtn:setX(x); self.websiteBtn:setY(y)
        x = x - GAP
    end
    if discordGuild() then
        self.previewBtn = self:makeButton("Who's on Discord", ServerM8Dashboard.onDiscordPreview, T.discord)
        self.previewBtn:setWidthToTitle(90)
        self.previewBtn:setTooltip("Live view of the Discord server: who is online and in voice.")
        x = x - self.previewBtn:getWidth()
        self.previewBtn:setX(x); self.previewBtn:setY(y)
        x = x - GAP
    end
    if discordInvite() then
        self.discordBtn = self:makeButton("Open Discord", ServerM8Dashboard.onDiscord, T.discord)
        self.discordBtn:setWidthToTitle(90)
        self.discordBtn:setTooltip("Opens the server's Discord inside the game.")
        x = x - self.discordBtn:getWidth()
        self.discordBtn:setX(x); self.discordBtn:setY(y)
        x = x - GAP
    end
    self.headerTextWidth = x - PAD

    self.headerHeight = PAD + FONT_HGT_LARGE + FONT_HGT_SMALL + PAD
    self.tileHeight = FONT_HGT_SMALL + FONT_HGT_MEDIUM + 12
    local tabsY = top + self.headerHeight + self.tileHeight + PAD

    self.tabButtons = {}
    local showActivity = cfg("ShowActivity", true)
    local tabX = PAD
    for _, tab in ipairs(TABS) do
        if tab.id ~= "activity" or showActivity then
            local button = self:makeButton(tab.title, ServerM8Dashboard.onTab)
            button.internal = tab.id
            button:setWidthToTitle(96)
            button:setX(tabX); button:setY(tabsY)
            tabX = tabX + button:getWidth() + GAP
            self.tabButtons[tab.id] = button
        end
    end

    local bodyY = tabsY + BUTTON_HGT + GAP
    self.body = ISRichTextPanel:new(PAD, bodyY, self.width - PAD * 2, self.height - bodyY - PAD)
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

    self:selectTab("overview")
end

function ServerM8Dashboard:selectTab(id)
    self.tab = id
    for tabID, button in pairs(self.tabButtons) do
        if tabID == id then
            button.backgroundColor = { r = T.border.r, g = T.border.g, b = T.border.b, a = 1 }
            button.borderColor = { r = T.accent.r, g = T.accent.g, b = T.accent.b, a = 1 }
        else
            button.backgroundColor = { r = T.panel.r, g = T.panel.g, b = T.panel.b, a = 1 }
            button.borderColor = { r = T.border.r, g = T.border.g, b = T.border.b, a = 1 }
        end
    end
    self:refreshBody(true)
end

local function heading(text)
    return " <SIZE:medium> " .. ServerM8.rgb(T.accent) .. text .. " <LINE> <SIZE:small> " .. ServerM8.rgb(T.text)
end

function ServerM8Dashboard:buildOverview(snap)
    local parts = {}
    table.insert(parts, heading("Welcome"))
    table.insert(parts, ServerM8.toRichText(cfg("Welcome", "Welcome to " .. ServerM8.escape(serverName()) .. ".")))
    if snap and snap.news and snap.news ~= "" then
        table.insert(parts, " <BR> " .. heading("News"))
        table.insert(parts, ServerM8.toRichText(snap.news))
    end
    local description = isClient() and serverOption("getOption", "PublicDescription") or nil
    if description and tostring(description) ~= "" then
        table.insert(parts, " <BR> " .. heading("About this server"))
        table.insert(parts, ServerM8.toRichText(string.gsub(tostring(description), "\\n", "\n")))
    end
    if not isClient() then
        table.insert(parts, " <BR> " .. ServerM8.rgb(T.muted) .. "You are not connected to a multiplayer server, so live server information is unavailable.")
    end
    return table.concat(parts)
end

function ServerM8Dashboard:buildRules(snap)
    if snap and snap.rules and snap.rules ~= "" then
        return heading("Server rules") .. ServerM8.toRichText(snap.rules)
    end
    return ServerM8.rgb(T.muted) .. "This server has not published any rules."
end

local FEED_TEXT = {
    join = { text = "joined the server", color = T.good },
    leave = { text = "left the server", color = T.muted },
    death = { text = "died", color = T.bad },
}

function ServerM8Dashboard:buildActivity(snap)
    if not snap or not snap.feed or #snap.feed == 0 then
        return ServerM8.rgb(T.muted) .. "Nothing has happened since the server started."
    end
    local elapsed = getTimestamp() - ServerM8Dashboard.snapshotAt
    local lines = { heading("Recent activity") }
    for i = #snap.feed, 1, -1 do
        local entry = snap.feed[i]
        local kind = FEED_TEXT[entry.k]
        if kind then
            table.insert(lines, ServerM8.rgb(T.muted) .. ServerM8.ago((entry.a or 0) + elapsed)
                .. ServerM8.rgb(T.text) .. ServerM8.escape(entry.n)
                .. ServerM8.rgb(kind.color) .. kind.text .. " <LINE> ")
        end
    end
    return table.concat(lines)
end

function ServerM8Dashboard:buildPlayers(snap)
    if not snap or not snap.online then
        return ServerM8.rgb(T.muted) .. "Waiting for the server..."
    end
    local lines = { heading(#snap.online .. " online") }
    for _, name in ipairs(snap.online) do
        table.insert(lines, ServerM8.rgb(T.good) .. "* " .. ServerM8.rgb(T.text) .. ServerM8.escape(name) .. " <LINE> ")
    end
    return table.concat(lines)
end

function ServerM8Dashboard:buildDiscord()
    local invite = discordInvite()
    if not invite then
        return ServerM8.rgb(T.muted) .. "This server has not linked a Discord."
    end
    local parts = { heading("Discord") }
    table.insert(parts, "Press " .. ServerM8.rgb(T.discord) .. "Open Discord" .. ServerM8.rgb(T.text)
        .. "at the top of this window. It opens in the Steam overlay, on top of the game, so you never leave. <LINE> ")
    table.insert(parts, "Log in there once and Steam remembers you. Shift+Tab closes the overlay and returns you to the game. <BR> ")
    if discordGuild() then
        table.insert(parts, ServerM8.rgb(T.discord) .. "Who's on Discord" .. ServerM8.rgb(T.text)
            .. "shows who is online and in voice right now, with no login needed. <BR> ")
    end
    table.insert(parts, ServerM8.rgb(T.muted) .. "Invite link: " .. ServerM8.rgb(T.info) .. ServerM8.inviteUrl(invite))
    return table.concat(parts)
end

function ServerM8Dashboard:refreshBody(resetScroll)
    if not self.body then return end
    local snap = ServerM8Dashboard.snapshot
    local text
    if self.tab == "rules" then text = self:buildRules(snap)
    elseif self.tab == "activity" then text = self:buildActivity(snap)
    elseif self.tab == "players" then text = self:buildPlayers(snap)
    elseif self.tab == "discord" then text = self:buildDiscord()
    else text = self:buildOverview(snap) end
    if text == self.body.text and not resetScroll then return end
    self.body.text = text
    self.body:paginate()
    if resetScroll then self.body:setYScroll(0) end
end

function ServerM8Dashboard:drawTile(x, y, w, h, label, value, color)
    self:drawRect(x, y, w, h, 1, T.panel.r, T.panel.g, T.panel.b)
    self:drawRectBorder(x, y, w, h, 1, T.border.r, T.border.g, T.border.b)
    self:drawText(label, x + 8, y + 5, T.muted.r, T.muted.g, T.muted.b, 1, UIFont.Small)
    self:drawText(value, x + 8, y + 5 + FONT_HGT_SMALL, color.r, color.g, color.b, 1, UIFont.Medium)
end

function ServerM8Dashboard:prerender()
    ISCollapsableWindow.prerender(self)

    local now = getTimestamp()
    if now - ServerM8Dashboard.lastRequest >= REFRESH_SECONDS then
        ServerM8Dashboard.requestSnapshot("refresh")
    end

    local top = self:titleBarHeight()
    local w = self.width
    self:drawRect(1, top, w - 2, self.height - top - 1, 0.6, T.bg.r, T.bg.g, T.bg.b)
    self:drawRect(1, top, w - 2, 2, 1, T.accent.r, T.accent.g, T.accent.b)

    -- Header.
    local y = top + PAD
    self:drawText(self.nameText, PAD, y, T.text.r, T.text.g, T.text.b, 1, UIFont.Large)
    self:drawText(self.taglineText, PAD, y + FONT_HGT_LARGE, T.muted.r, T.muted.g, T.muted.b, 1, UIFont.Small)

    -- Tiles.
    local snap = ServerM8Dashboard.snapshot
    local tileY = top + self.headerHeight
    local tileW = math.floor((w - PAD * 2 - GAP * 3) / 4)
    local onlineText, uptimeText = "-", "-"
    if snap then
        local online = snap.online and #snap.online or 0
        onlineText = tostring(online)
        if snap.max and snap.max > 0 then onlineText = online .. " / " .. snap.max end
        uptimeText = ServerM8.duration((snap.uptime or 0) + (now - ServerM8Dashboard.snapshotAt))
    end
    local pvpText, pvpColor = "-", T.muted
    if isClient() then
        local pvp = serverOption("getBoolean", "PVP")
        if pvp == true then pvpText, pvpColor = "On", T.bad
        elseif pvp == false then pvpText, pvpColor = "Off", T.good end
    end
    local dayText = "Day " .. (math.floor(getGameTime():getWorldAgeHours() / 24) + 1)

    self:drawTile(PAD, tileY, tileW, self.tileHeight, "Players online", onlineText, T.text)
    self:drawTile(PAD + (tileW + GAP), tileY, tileW, self.tileHeight, "PvP", pvpText, pvpColor)
    self:drawTile(PAD + (tileW + GAP) * 2, tileY, tileW, self.tileHeight, "World age", dayText, T.text)
    self:drawTile(PAD + (tileW + GAP) * 3, tileY, w - PAD * 2 - (tileW + GAP) * 3, self.tileHeight, "Server uptime", uptimeText, T.text)
end

function ServerM8Dashboard:onTab(button)
    self:selectTab(button.internal)
end

function ServerM8Dashboard:onDiscord()
    local invite = discordInvite()
    if invite then ServerM8.openWeb(ServerM8.inviteUrl(invite), "Discord: " .. serverName()) end
end

function ServerM8Dashboard:onDiscordPreview()
    local guild = discordGuild()
    if guild then ServerM8.openWeb(ServerM8.widgetUrl(guild), "Discord: " .. serverName()) end
end

function ServerM8Dashboard:onWebsite()
    local url = website()
    if url then ServerM8.openWeb(url, serverName()) end
end

function ServerM8Dashboard:close()
    self:setVisible(false)
    self:removeFromUIManager()
    if ServerM8Dashboard.instance == self then
        ServerM8Dashboard.instance = nil
    end
end

function ServerM8Dashboard:new()
    local screenW, screenH = getCore():getScreenWidth(), getCore():getScreenHeight()
    local width = math.min(780, screenW - 40)
    local height = math.min(560, screenH - 40)
    local o = ISCollapsableWindow.new(self, (screenW - width) / 2, (screenH - height) / 2, width, height)
    o.title = "ServerM8"
    o.resizable = false
    o.tab = "overview"
    o.nameText = serverName()
    o.taglineText = cfg("Tagline", "")
    return o
end

function ServerM8Dashboard.open()
    if ServerM8Dashboard.instance then
        ServerM8Dashboard.instance:bringToTop()
        return
    end
    local window = ServerM8Dashboard:new()
    window:initialise()
    window:addToUIManager()
    window:bringToTop()
    ServerM8Dashboard.instance = window
    ServerM8Dashboard.requestSnapshot("refresh")
end

function ServerM8Dashboard.toggle()
    if ServerM8Dashboard.instance then
        ServerM8Dashboard.instance:close()
    else
        ServerM8Dashboard.open()
    end
end

-- Server -> client --------------------------------------------------------

local function onServerCommand(module, command, args)
    if module ~= ServerM8.MODULE or command ~= "snapshot" or not args then return end
    ServerM8Dashboard.snapshot = args
    ServerM8Dashboard.snapshotAt = getTimestamp()
    if ServerM8Dashboard.instance then
        ServerM8Dashboard.instance:refreshBody(false)
    elseif isClient() and not ServerM8Dashboard.shownOnJoin then
        ServerM8Dashboard.shownOnJoin = true
        if cfg("ShowOnJoin", true) then ServerM8Dashboard.open() end
    end
end

-- Say hello a moment after the world has loaded, so the player object exists.
local helloTicks = 0
local function helloTick()
    helloTicks = helloTicks + 1
    if helloTicks < 90 then return end
    Events.OnTick.Remove(helloTick)
    if isClient() then ServerM8Dashboard.requestSnapshot("hello") end
end

local function onGameStart()
    ServerM8Dashboard.snapshot = nil
    ServerM8Dashboard.shownOnJoin = false
    helloTicks = 0
    Events.OnTick.Add(helloTick)
end

local function onPlayerDeath(player)
    if isClient() and player and player:isLocalPlayer() then
        sendClientCommand(player, ServerM8.MODULE, "death", {})
    end
end

-- Ways to open it ----------------------------------------------------------

local keyOption = nil
if PZAPI and PZAPI.ModOptions then
    local options = PZAPI.ModOptions:create("ServerM8", "ServerM8")
    keyOption = options:addKeyBind("dashboard", "Open server dashboard", Keyboard.KEY_INSERT, "Shows the ServerM8 dashboard for the server you are on.")
end

local function onKeyPressed(key)
    if not keyOption or key ~= keyOption:getValue() then return end
    if not getPlayer() then return end
    ServerM8Dashboard.toggle()
end

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if test or not isClient() then return end
    context:addOption("Server dashboard", nil, ServerM8Dashboard.open)
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnGameStart.Add(onGameStart)
Events.OnPlayerDeath.Add(onPlayerDeath)
Events.OnKeyPressed.Add(onKeyPressed)
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
