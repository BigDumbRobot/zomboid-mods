-- Bass Masters: the logbook. Every species (and how to find the ones you haven't caught), the
-- server's book of trophy fish and records, and, with Adaptive Traits, the road to Bass Master.

require "ISUI/ISCollapsableWindow"
require "ISUI/ISRichTextPanel"
require "ISUI/ISButton"
require "BassMasters_Shared"

local BM = BassMasters

BassMastersWindow = ISCollapsableWindow:derive("BassMastersWindow")

local function tabs()
    local list = { { "species", "Logbook" }, { "server", "The Server" } }
    if BM.adaptiveTraits then table.insert(list, { "master", "Bass Master" }) end
    return list
end

function BassMastersWindow:new(player)
    local w, h = 560, 520
    local o = ISCollapsableWindow:new(getCore():getScreenWidth() / 2 - w / 2, getCore():getScreenHeight() / 2 - h / 2, w, h)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.title = "Bass Masters"
    o.tab = "species"
    o.resizable = false
    return o
end

function BassMastersWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local x = 10
    self.tabButtons = {}
    for _, t in ipairs(tabs()) do
        local b = ISButton:new(x, th + 8, 110, 24, t[2], self, BassMastersWindow.onTab)
        b.internal = t[1]
        b:initialise()
        self:addChild(b)
        self.tabButtons[t[1]] = b
        x = x + 116
    end
    self.text = ISRichTextPanel:new(10, th + 40, self.width - 20, self.height - th - 50)
    self.text:initialise()
    self.text.autosetheight = false
    self.text.clip = true
    self:addChild(self.text)
    self.text:addScrollBars()
    self.text.background = false
    self:refresh()
end

function BassMastersWindow:onTab(button)
    self.tab = button.internal
    self:refresh()
end

local function line(t, s) table.insert(t, s) end
-- One colour per line: Zomboid's rich text drops the space where a colour changes.
local GOLD, GREY, GREEN, WHITE = " <RGB:1,0.85,0.3> ", " <RGB:0.6,0.6,0.6> ", " <RGB:0.6,0.95,0.6> ", " <RGB:1,1,1> "

local function speciesPage(out, d, book)
    local caught, total = 0, 0
    for _, f in ipairs(Fishing.fishes) do
        if f.itemType ~= "Base.BaitFish" then
            total = total + 1
            if d.species[f.itemType] then caught = caught + 1 end
        end
    end
    line(out, GOLD .. "FISH YOU'VE MET: " .. caught .. " OF " .. total .. " <LINE> ")
    line(out, GREY .. "Trophy fish landed: " .. d.trophyFish .. ".  Fish released: " .. d.releases .. ". <LINE> <LINE> ")
    for _, f in ipairs(Fishing.fishes) do
        local t = f.itemType
        if t ~= "Base.BaitFish" then
            local s = d.species[t]
            local rec = book.records[t]
            if s then
                line(out, GREEN .. BM.displayName(t) .. string.format(":  caught %d, best %.2f lb", s.count, s.best) .. " <LINE> ")
                line(out, GREY .. (BM.NOTES[t] or "") .. " <LINE> ")
            else
                local where = (f.isRiver and f.isLake) and "rivers and lakes" or (f.isRiver and "rivers" or "lakes")
                line(out, GREY .. "?  " .. BM.displayName(t) .. "   not caught yet. Try " .. where .. ", with " .. table.concat(BM.bestLures(t, 3), ", ") .. ". <LINE> ")
            end
            if rec then
                line(out, WHITE .. string.format("   Server record: %.2f lb, %s", rec.lb, rec.name) .. " <LINE> ")
            end
            line(out, " <LINE> ")
        end
    end
end

local function serverPage(out, book)
    line(out, GOLD .. "TROPHY FISH <LINE> " .. GREY .. "Any fish can be a trophy, for anyone. They don't come often. <LINE> <LINE> ")
    if #book.trophies == 0 then line(out, GREY .. "   Nobody's landed one yet. <LINE> ") end
    for _, tr in ipairs(book.trophies) do
        line(out, WHITE .. string.format("   Day %d:  %s, %s %.2f lb", tr.day or 0, tr.name, BM.displayName(tr.type), tr.lb) .. " <LINE> ")
    end

    line(out, " <LINE> " .. GOLD .. "THE ANGLERS <LINE> ")
    local anglers = {}
    for _, a in pairs(book.anglers) do table.insert(anglers, a) end
    table.sort(anglers, function(a, b)
        if (a.trophies or 0) ~= (b.trophies or 0) then return (a.trophies or 0) > (b.trophies or 0) end
        return (a.bestBass or 0) > (b.bestBass or 0)
    end)
    if #anglers == 0 then line(out, GREY .. "   No catches yet. <LINE> ") end
    for i, a in ipairs(anglers) do
        line(out, (a.master and GREEN or WHITE) .. string.format("   %d.  %s%s:  %d trophies, best bass %.2f lb", i, a.name,
            a.master and " (Bass Master)" or "", a.trophies or 0, a.bestBass or 0) .. " <LINE> ")
    end

    line(out, " <LINE> " .. GOLD .. "SERVER RECORDS <LINE> ")
    local any = false
    for _, f in ipairs(Fishing.fishes) do
        local rec = book.records[f.itemType]
        if rec then
            any = true
            line(out, WHITE .. string.format("   %s:  %.2f lb, %s", BM.displayName(f.itemType), rec.lb, rec.name) .. " <LINE> ")
        end
    end
    if not any then line(out, GREY .. "   Nothing on the books yet. <LINE> ") end
end

local function masterPage(out, player, d)
    line(out, GOLD .. "THE ROAD TO BASS MASTER <LINE> ")
    if BM.TRAIT and player:hasTrait(BM.TRAIT) then
        line(out, GREEN .. "You're a Bass Master. <LINE> <LINE> ")
    elseif not BM.sandbox("BassMasterCanGain", true) then
        line(out, GREY .. "This server has turned the Bass Master trait off. <LINE> <LINE> ")
    else
        line(out, GREY .. "Meet all of these and you'll earn the Bass Master trait (Fishing +3). <LINE> <LINE> ")
    end
    local rows = BM.masterProgress(d)
    for _, r in ipairs(rows) do
        local req = r.req
        local n = req.unit and string.format("%.2f / %d %s", math.min(r.count, req.goal), req.goal, req.unit)
            or string.format("%d / %d", math.min(r.count, req.goal), req.goal)
        line(out, (r.done and GREEN .. "[x] " or WHITE .. "[ ] ") .. req.name .. ":  " .. req.text .. "  (" .. n .. ") <LINE> ")
    end
end

function BassMastersWindow:refresh()
    for id, b in pairs(self.tabButtons) do
        b.backgroundColor = id == self.tab and { r = 0.35, g = 0.3, b = 0.1, a = 1 } or { r = 0, g = 0, b = 0, a = 1 }
    end
    local d = BM.data(self.player)
    local book = BM.serverBook()
    local out = {}
    if self.tab == "server" then
        serverPage(out, book)
    elseif self.tab == "master" then
        masterPage(out, self.player, d)
    else
        speciesPage(out, d, book)
    end
    self.text.text = table.concat(out)
    self.text:paginate()
end

function BM.openLogbook(player)
    if BM.window and BM.window:isVisible() then
        BM.window:setVisible(false)
        BM.window:removeFromUIManager()
        BM.window = nil
        return
    end
    if isClient() then ModData.request("BassMasters") end
    BM.window = BassMastersWindow:new(player or getPlayer())
    BM.window:initialise()
    BM.window:addToUIManager()
    BM.window:setVisible(true)
end
