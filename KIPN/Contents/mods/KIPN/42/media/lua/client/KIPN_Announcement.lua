-- KIPN_Announcement.lua
-- System announcements: ingested Discord feed + admin-posted notices.
--
-- This screen displays the merged, newest-first announcement list
-- maintained server-side by KIPN.Server.AnnouncementService (see
-- server/KIPN_AnnouncementService.lua). It does NOT talk to Discord
-- itself -- the server reads a plain-text feed file that the optional
-- external KIPN Discord poster writes into Zomboid/Lua/.
--
-- Data flow:
--
--   onShow() --> GET_ANNOUNCEMENTS --> server
--                                        |
--                                        v
--                            ANNOUNCEMENT_SYNC (response)
--                                        |
--                                        v
--                              receiveResponse()
--                                        |
--                                        v
--                        self.announcements + "last seen" marker
--
-- The server also BROADCASTS ANNOUNCEMENT_SYNC to every connected
-- player whenever the Discord bridge or an admin post changes the
-- list. If this screen happens to be the active KIPN_Terminal screen
-- when that arrives, it updates live. KIPN_MainMenu's unread badge
-- is what covers the "player isn't looking at this screen right
-- now" case -- see KIPN_MainMenu.lua's requestAnnouncements() /
-- hasUnreadAnnouncements.
--
-- "Last seen" is tracked client-side only, via a client-local
-- ModData table (KIPN_ClientState). This is presentation state, not
-- authoritative game data -- the server never needs to know what a
-- player has or hasn't read.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "KIPN_AdminAccess"

if not KIPN then
    error("[KIPN_Announcement] KIPN core is not initialized.")
end

if not KIPN.Shared then
    error("[KIPN_Announcement] KIPN_Shared is not initialized.")
end

require "KIPN_UI"

if not KIPN.UI then
    error("[KIPN_Announcement] KIPN_UI is not initialized.")
end

--------------------------------------------------------------------
-- CLIENT-LOCAL "LAST SEEN" STATE
--
-- Not server-authoritative. Purely local presentation state so the
-- Main Menu badge and this screen agree on what counts as "unread".
--------------------------------------------------------------------

KIPN.Client = KIPN.Client or {}

function KIPN.Client.GetAnnouncementLastSeenId()
    local ok, store = pcall(ModData.getOrCreate, "KIPN_ClientState")

    if not ok or type(store) ~= "table" then
        return nil
    end

    return store.announcementLastSeenId
end

function KIPN.Client.SetAnnouncementLastSeenId(id)
    if id == nil then
        return
    end

    local ok, store = pcall(ModData.getOrCreate, "KIPN_ClientState")

    if not ok or type(store) ~= "table" then
        return
    end

    store.announcementLastSeenId = id
end

--------------------------------------------------------------------
-- SCREEN
--------------------------------------------------------------------

KIPN_Announcement =
    KIPN.UI.CreateScreen("KIPN_Announcement")

local Theme = KIPN.UI.Theme

local SOURCE_COLORS = {
    discord = { r = 0.45, g = 0.55, b = 1.0, a = 1 },
    admin = Theme.accent,
}

local CARD_PADDING = 10
local CARD_SPACING = 10
local LINE_HEIGHT = 18

--------------------------------------------------------------------
-- TEXT WRAPPING
--
-- Same greedy word-wrap approach KIPN_ServerStats.lua uses inline
-- for its announcement preview, factored out here since this screen
-- needs the line count BEFORE drawing (to size each card and to
-- decide how many cards fit on screen).
--------------------------------------------------------------------

local function wrapLines(font, text, maxWidth)
    local lines = {}
    local line = ""

    for word in string.gmatch(tostring(text or ""), "%S+") do

        local testLine =
            line == ""
            and word
            or (line .. " " .. word)

        local measuredWidth =
            getTextManager():MeasureStringX(font, testLine)

        if measuredWidth <= maxWidth then
            line = testLine
        else
            if line ~= "" then
                lines[#lines + 1] = line
            end

            line = word
        end
    end

    if line ~= "" then
        lines[#lines + 1] = line
    end

    if #lines == 0 then
        lines[1] = ""
    end

    return lines
end

--------------------------------------------------------------------
-- RELATIVE TIME
--------------------------------------------------------------------

local function formatTimestamp(timestampMs)
    local seconds = math.floor((tonumber(timestampMs) or 0) / 1000)

    if seconds <= 0 then
        return "--"
    end

    local ok, now = pcall(os.time)

    if not ok then
        return os.date("%Y-%m-%d %H:%M", seconds)
    end

    local diff = now - seconds

    if diff < 60 then
        return "just now"
    elseif diff < 3600 then
        return math.floor(diff / 60) .. "m ago"
    elseif diff < 86400 then
        return math.floor(diff / 3600) .. "h ago"
    end

    local okDate, t = pcall(os.date, "*t", seconds)

    if okDate and type(t) == "table" then
        return KIPN.Client.Preferences.FormatDateTime(
            t.year, t.month, t.day, t.hour, t.min
        )
    end

    return os.date("%Y-%m-%d %H:%M", seconds)
end

--------------------------------------------------------------------
-- INITIALISE / CREATE
--------------------------------------------------------------------

function KIPN_Announcement:initialise()
    ISPanel.initialise(self)
    self:create()
end

function KIPN_Announcement:create()
    KIPN.UI.SetupScreen(self)

    self.announcements = {}
    self.loading = true
    self.scrollOffset = 0

    self.adminMode = false

    self.inputText = ""

    -- Create the composer once and toggle its visibility when the
    -- server-resolved access level arrives. This avoids permanently
    -- hiding it when a Steam-ID-only admin opens the screen before the
    -- asynchronous GET_PLAYER_DATA response has been received.
    self.announcementEntry =
        ISTextEntryBox:new("", 20, self.height - 88, self.width - 150, 24)

    self.announcementEntry:initialise()
    self.announcementEntry:instantiate()
    self.announcementEntry:setMaxTextLength(500)
    self.announcementEntry.onCommandEntered =
        function() self:postAnnouncement() end
    self:addChild(self.announcementEntry)

    self.postButton =
        KIPN.UI.CreateButton(
            self,
            self.width - 122,
            self.height - 88,
            50,
            24,
            "POST",
            KIPN_Announcement.onPostClick
        )

    self.clearButton =
        KIPN.UI.CreateButton(
            self,
            self.width - 64,
            self.height - 88,
            44,
            24,
            "CLR",
            KIPN_Announcement.onClearClick,
            { danger = true }
        )

    self:refreshAdminMode()
end

function KIPN_Announcement:refreshAdminMode()
    local adminMode = KIPN.Client.AdminAccess.IsAdmin(0)

    self.adminMode = adminMode

    if self.announcementEntry then
        self.announcementEntry:setVisible(adminMode)
    end

    if self.postButton then
        self.postButton:setVisible(adminMode)
    end

    if self.clearButton then
        self.clearButton:setVisible(adminMode)
    end
end

--------------------------------------------------------------------
-- SHOW
--------------------------------------------------------------------

function KIPN_Announcement:onShow()
    self:refreshAdminMode()
    self:requestAnnouncements()
end

--------------------------------------------------------------------
-- REQUEST
--------------------------------------------------------------------

function KIPN_Announcement:requestAnnouncements()
    if not KIPN.Shared.Commands.GET_ANNOUNCEMENTS then
        KIPN.Logger.Warn(
            "KIPN_Announcement:requestAnnouncements(): "
            .. "GET_ANNOUNCEMENTS command unavailable"
        )
        return
    end

    self.loading = #self.announcements == 0

    sendClientCommand(
        "KIPN",
        KIPN.Shared.Commands.GET_ANNOUNCEMENTS,
        {}
    )
end

--------------------------------------------------------------------
-- ADMIN ACTIONS
--------------------------------------------------------------------

function KIPN_Announcement:onPostClick()
    self:postAnnouncement()
end

function KIPN_Announcement:postAnnouncement()
    if not KIPN.Client.AdminAccess.IsAdmin(0) then
        return
    end

    local text = self.announcementEntry and self.announcementEntry:getText() or ""

    if text and text:find("%S") then
        sendClientCommand("KIPN", KIPN.Shared.Commands.ANNOUNCEMENT_SYNC, {
            action = "post",
            text = text,
        })

        if self.announcementEntry then
            self.announcementEntry:setText("")
        end
    end
end

function KIPN_Announcement:onClearClick()
    if not KIPN.Client.AdminAccess.IsAdmin(0) then
        return
    end

    sendClientCommand("KIPN", KIPN.Shared.Commands.ANNOUNCEMENT_SYNC, {
        action = "clear",
    })
end

--------------------------------------------------------------------
-- MARK READ
--------------------------------------------------------------------

function KIPN_Announcement:markRead(latestId)
    if latestId == nil then
        return
    end

    KIPN.Client.SetAnnouncementLastSeenId(latestId)
end

--------------------------------------------------------------------
-- SERVER RESPONSE
--------------------------------------------------------------------

function KIPN_Announcement:receiveResponse(event, data)
    if event == KIPN.Shared.ResponseEvents.ANNOUNCEMENT_SYNC then

        self.loading = false

        self.announcements =
            (data and data.announcements) or {}

        local maxOffset =
            math.max(0, #self.announcements - 1)

        self.scrollOffset =
            math.max(0, math.min(self.scrollOffset, maxOffset))

        -- The player is actively looking at this screen right now,
        -- so whatever just arrived counts as read.
        self:markRead(data and data.latestId)

        return
    end

    if event == KIPN.Shared.ResponseEvents.ERROR then
        self.loading = false
        return
    end
end

--------------------------------------------------------------------
-- PRERENDER
--------------------------------------------------------------------

function KIPN_Announcement:prerender()
    self:refreshAdminMode()
    ISPanel.prerender(self)
    KIPN.UI.DrawScanlines(self)

    local y = KIPN.UI.DrawBanner(self, "SYSTEM ANNOUNCEMENTS")

    y = KIPN.UI.DrawDivider(self, y) + 12

    ----------------------------------------------------------------
    -- ADMIN COMPOSER
    ----------------------------------------------------------------

    local listBottom = self.height - 30

    if self.adminMode then

        -- The composer block below occupies roughly
        -- [height - 108, height - 36]. Leave a clean gap above it
        -- so the card list can never overdraw the label/entry/hint.
        listBottom = self.height - 118

        self:drawText(
            "POST ANNOUNCEMENT TO ALL PLAYERS:",
            20,
            self.height - 108,
            Theme.warning.r,
            Theme.warning.g,
            Theme.warning.b,
            Theme.warning.a,
            Theme.fontHeader
        )

        self:drawRect(
            20,
            self.height - 88,
            self.width - 150,
            24,
            0.8, 0, 0.2, 0
        )

        self:drawRectBorder(
            20,
            self.height - 88,
            self.width - 150,
            24,
            0.5, 0, 0.5, 0
        )

        KIPN.UI.DrawDivider(self, self.height - 60)

        self:drawText(
            "Type or paste up to 500 characters. Enter or POST sends to all players. "
            .. "CLR removes admin posts.",
            20,
            self.height - 50,
            Theme.dimText.r,
            Theme.dimText.g,
            Theme.dimText.b,
            Theme.dimText.a,
            Theme.fontBody
        )
    end

    ----------------------------------------------------------------
    -- LIST STATE
    ----------------------------------------------------------------

    if self.loading then

        KIPN.UI.DrawStatusMessage(
            self, "loading", "LOADING ANNOUNCEMENTS...", nil
        )

        return
    end

    if #self.announcements == 0 then

        KIPN.UI.DrawStatusMessage(
            self, "empty", "NO ANNOUNCEMENTS",
            "Nothing posted yet. Check back later."
        )

        return
    end

    ----------------------------------------------------------------
    -- CARD LIST
    ----------------------------------------------------------------

    local cardX = 18
    local cardWidth = self.width - 36
    local textWidth = cardWidth - (CARD_PADDING * 2)

    local index = self.scrollOffset + 1

    while index <= #self.announcements
        and y < listBottom do

        local entry = self.announcements[index]

        local lines =
            wrapLines(Theme.fontBody, entry.text, textWidth)

        local cardHeight =
            CARD_PADDING * 2
            + 18
            + (#lines * LINE_HEIGHT)

        -- Clip: if this card doesn't fully fit, stop (don't draw a
        -- half card). Always draw at least one card so a very tall
        -- first entry isn't skipped entirely.
        if y + cardHeight > listBottom
            and index > self.scrollOffset + 1 then
            break
        end

        local sourceColor =
            SOURCE_COLORS[entry.source] or Theme.text

        self:drawRect(
            cardX, y, cardWidth, cardHeight,
            0.03, 0.1, 0.03, 0.2
        )

        self:drawRectBorder(
            cardX, y, cardWidth, cardHeight,
            1, sourceColor.r, sourceColor.g, sourceColor.b
        )

        local headerY = y + CARD_PADDING

        self:drawText(
            "[" .. string.upper(tostring(entry.source or "?")) .. "]",
            cardX + CARD_PADDING,
            headerY,
            sourceColor.r, sourceColor.g, sourceColor.b, sourceColor.a,
            Theme.fontHeader
        )

        self:drawText(
            tostring(entry.author or "Unknown"),
            cardX + CARD_PADDING + 78,
            headerY,
            Theme.text.r, Theme.text.g, Theme.text.b, Theme.text.a,
            Theme.fontHeader
        )

        local timeText = formatTimestamp(entry.timestamp)
        local timeWidth =
            getTextManager():MeasureStringX(Theme.fontHeader, timeText)

        self:drawText(
            timeText,
            cardX + cardWidth - CARD_PADDING - timeWidth,
            headerY,
            Theme.dimText.r, Theme.dimText.g, Theme.dimText.b, Theme.dimText.a,
            Theme.fontHeader
        )

        local bodyY = headerY + 20

        for _, line in ipairs(lines) do

            self:drawText(
                line,
                cardX + CARD_PADDING,
                bodyY,
                Theme.text.r, Theme.text.g, Theme.text.b, Theme.text.a,
                Theme.fontBody
            )

            bodyY = bodyY + LINE_HEIGHT
        end

        y = y + cardHeight + CARD_SPACING

        index = index + 1
    end

    if index <= #self.announcements then

        self:drawText(
            string.format(
                "+ %d more (scroll for older)",
                #self.announcements - index + 1
            ),
            cardX,
            math.min(y, listBottom - 2),
            Theme.dimText.r, Theme.dimText.g, Theme.dimText.b, Theme.dimText.a,
            Theme.fontBody
        )
    end
end

--------------------------------------------------------------------
-- MOUSE WHEEL
--------------------------------------------------------------------

function KIPN_Announcement:onMouseWheel(delta)

    local maxOffset =
        math.max(0, #self.announcements - 1)

    self.scrollOffset =
        math.max(0, math.min(self.scrollOffset - delta, maxOffset))

    return true
end

--------------------------------------------------------------------
-- KEY PRESS
--
-- ESC is owned by KIPN_Terminal. Text entry is handled by the
-- ISTextEntryBox itself when it has focus.
--------------------------------------------------------------------

function KIPN_Announcement:onKeyPress(key)
    return false
end

print("[KIPN] Announcement screen loaded")
