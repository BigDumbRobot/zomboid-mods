-- KIPNCareers_AnnouncementsBridge  (framework core)
--
-- Gives the owner of a storefront in any career "limited access to the KIPN
-- Announcements system": a MY BUSINESS tab inside the stock KIPN Announcements
-- screen that shows their private career inbox (the per-owner notices every
-- career files through the framework). The KIPN host mod is not modified --
-- this wraps the KIPN_Announcement screen lifecycle, and fails safe (the base
-- screen keeps working) if a future KIPN build changes it.

require "KIPN_Announcement"
require "KIPNCareers_Shared"

local Shared = KIPNCareers.Shared

if not KIPN_Announcement or KIPN_Announcement.__kipnCareersInboxWrapped then return end
KIPN_Announcement.__kipnCareersInboxWrapped = true

local function send(command)
    if type(sendClientCommand) == "function" then
        sendClientCommand(Shared.MODULE, command, {})
    end
end

local originalCreate = KIPN_Announcement.create
function KIPN_Announcement:create()
    originalCreate(self)
    self.kipnCareersInbox = false
    self.kipnCareersNotifications = {}
    self.kipnCareersHasBusiness = false
    self.kipnCareersToggle = KIPN.UI.CreateButton(
        self, self.width - 170, 44, 150, 22, "MY BUSINESS >",
        function()
            self.kipnCareersInbox = not self.kipnCareersInbox
            if self.kipnCareersToggle then
                self.kipnCareersToggle:setTitle(self.kipnCareersInbox and "< SYSTEM FEED" or "MY BUSINESS >")
            end
            if self.kipnCareersInbox then send(Shared.Commands.INBOX) end
        end
    )
    if self.kipnCareersToggle then self.kipnCareersToggle:setVisible(false) end
end

local originalOnShow = KIPN_Announcement.onShow
function KIPN_Announcement:onShow()
    originalOnShow(self)
    send(Shared.Commands.INBOX)
end

local originalReceive = KIPN_Announcement.receiveResponse
function KIPN_Announcement:receiveResponse(event, data)
    if event == Shared.Events.INBOX then
        self.kipnCareersNotifications = (data and data.notifications) or {}
        self.kipnCareersHasBusiness = data and data.hasBusiness == true
        if self.kipnCareersToggle then self.kipnCareersToggle:setVisible(self.kipnCareersHasBusiness) end
        if not self.kipnCareersHasBusiness then self.kipnCareersInbox = false end
        -- Everything shown is now considered read.
        local ids = {}
        for _, note in ipairs(self.kipnCareersNotifications) do
            if note.unread then ids[#ids + 1] = note.id end
        end
        if #ids > 0 and type(sendClientCommand) == "function" then
            sendClientCommand(Shared.MODULE, Shared.Commands.MARK_INBOX_READ, { ids = ids })
        end
        return
    end
    if event == Shared.Events.INBOX_CHANGED then
        send(Shared.Commands.INBOX)
        return
    end
    return originalReceive(self, event, data)
end

local Theme = KIPN.UI.Theme

local originalPrerender = KIPN_Announcement.prerender
function KIPN_Announcement:prerender()
    if not self.kipnCareersInbox then
        originalPrerender(self)
        return
    end

    self:refreshAdminMode()
    ISPanel.prerender(self)
    KIPN.UI.DrawScanlines(self)

    local y = KIPN.UI.DrawBanner(self, "MY BUSINESS - CAREER INBOX")
    y = KIPN.UI.DrawDivider(self, y) + 16

    local notes = self.kipnCareersNotifications or {}
    if #notes == 0 then
        self:drawText("No career notices yet.", 22, y,
            Theme.dimText.r, Theme.dimText.g, Theme.dimText.b, Theme.dimText.a, Theme.fontBody)
        return
    end

    local bottom = self.height - 36
    for index = #notes, 1, -1 do
        local note = notes[index]
        if not note or y > bottom then break end
        self:drawText("* " .. tostring(note.title or ""), 22, y,
            Theme.accent.r, Theme.accent.g, Theme.accent.b, Theme.accent.a, Theme.fontHeader)
        y = y + 18
        self:drawText(tostring(note.body or ""), 30, y,
            Theme.text.r, Theme.text.g, Theme.text.b, Theme.text.a, Theme.fontBody)
        y = y + 24
    end
end
