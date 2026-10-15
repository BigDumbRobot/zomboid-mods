-- Smoke test for the Event Studio window (KIPN_EventStudioUI.lua) and
-- live strip. The vanilla UI classes below are minimal stand-ins, so
-- this only proves that every step builds in every mode and every
-- button and server reply runs without a Lua error -- not how it looks.
-- Run from this Workshop project directory: lua tests/studio_ui_smoke.lua
-- (or from LilBubbyModTester: lua -e "next=nil" tests/dynamicevents_studio_ui_checks.lua)
-- Dynamic Events' Lua: this project's own copy when run from the Dynamic
-- Events folder; else ~/Zomboid/Workshop/DynamicEvents (the same file is
-- kept in LilBubbyModTester/tests and run from there).
local root = "Contents/mods/DynamicEvents/42/media/lua/"
do
    local function exists(path) local f = io.open(path, "r") if f then f:close() return true end return false end
    if not exists(root .. "shared/DynamicEvents_Shared.lua") then
        root = (os.getenv("HOME") or "") .. "/Zomboid/Workshop/DynamicEvents/" .. root
    end
    if not exists(root .. "shared/DynamicEvents_Shared.lua") then
        print((arg and arg[0] or "dynamic events check") .. ": SKIPPED (Dynamic Events not found)")
        return
    end
end

------------------------------------------------------------
-- Game stand-ins
------------------------------------------------------------
local sent = {}
local handlers = {}
require = function() end
UIFont = { Small = 1, Medium = 2, Code = 3 }
local textManager = {
    MeasureStringX = function(_, _, text) return #tostring(text) * 7 end,
    getFontHeight = function() return 14 end,
    getFontFromEnum = function() return { getLineHeight = function() return 14 end } end,
}
getTextManager = function() return textManager end
getCore = function() return { getScreenWidth = function() return 1920 end, getScreenHeight = function() return 1080 end } end
getTimestampMs = function() return os.time() * 1000 end
ZombRand = function(a, b) if b then return a end return 0 end
sendClientCommand = function(module, command, args) sent[#sent + 1] = { command = command, args = args } end
getPlayer = function() return { getX = function() return 100 end, getY = function() return 200 end, getZ = function() return 0 end } end
getScriptManager = function()
    local items = { { "Base.Axe", "Axe" }, { "Base.Hat_Beret", "Beret" }, { "Base.Bandage", "Bandage" } }
    return { getAllItems = function()
        return { size = function() return #items end, get = function(_, i)
            local item = items[i + 1]
            return { getFullName = function() return item[1] end, getDisplayName = function() return item[2] end }
        end }
    end }
end
Events = setmetatable({}, { __index = function(t, key)
    -- Every handler runs, as in the game.
    local e = { Add = function(fn)
        local previous = handlers[key]
        handlers[key] = previous and function(...) previous(...) fn(...) end or fn
    end }
    t[key] = e
    return e
end })

local Base = {}
Base.__index = Base
function Base:derive() local d = setmetatable({}, { __index = self }); d.__index = d; return d end
function Base.new(self, x, y, w, h)
    return setmetatable({ x = x or 0, y = y or 0, width = w or 0, height = h or 0, children = {}, visible = true }, self)
end
for _, name in ipairs({ "initialise", "instantiate", "addScrollBars", "setScrollChildren", "setScrollWithParent",
    "setScrollHeight", "setStencilRect", "clearStencilRect", "addToUIManager", "removeFromUIManager", "bringToTop",
    "drawText", "drawRect", "drawTextRight", "setTooltip", "prerender", "render", "update", "setMargins", "paginate",
    "setOnlyNumbers", "setMultipleLine", "setMaxLines", "setPlaceholderText", "createChildren" }) do
    Base[name] = function() end
end
function Base:addChild(child) self.children[#self.children + 1] = child; child.parent = self end
function Base:removeChild(child)
    for i, c in ipairs(self.children) do if c == child then table.remove(self.children, i) return end end
end
function Base:setX(v) self.x = v end
function Base:setY(v) self.y = v end
function Base:setWidth(v) self.width = v end
function Base:setHeight(v) self.height = v end
function Base:getX() return self.x end
function Base:getY() return self.y end
function Base:getWidth() return self.width end
function Base:getHeight() return self.height end
function Base:setVisible(v) self.visible = v end
function Base:getIsVisible() return self.visible end
function Base:setYScroll(v) self.yscroll = v end
function Base:getYScroll() return self.yscroll or 0 end
function Base:setEnable(v) self.enabled = v end
function Base:setTitle(v) self.title = v end

ISPanel = Base:derive()
ISCollapsableWindow = Base:derive()
function ISCollapsableWindow:titleBarHeight() return 16 end
function ISCollapsableWindow:resizeWidgetHeight() return 8 end
ISLabel = Base:derive()
function ISLabel.new(self, x, y, h, name) local o = Base.new(self, x, y, 100, h); o.name = name; return o end
ISButton = Base:derive()
function ISButton.new(self, x, y, w, h, title, target, onclick)
    local o = Base.new(self, x, y, w, h); o.title, o.target, o.onclick = title, target, onclick; o.enabled = true; return o
end
ISTextEntryBox = Base:derive()
function ISTextEntryBox.new(self, text, x, y, w, h) local o = Base.new(self, x, y, w, h); o.text = text; return o end
function ISTextEntryBox:getText() return self.text end
function ISTextEntryBox:setText(v) self.text = v end
ISComboBox = Base:derive()
function ISComboBox.new(self, x, y, w, h, target, onChange)
    local o = Base.new(self, x, y, w, h); o.options, o.selected, o.target, o.onChange = {}, 1, target, onChange; return o
end
function ISComboBox:addOptionWithData(text, data) self.options[#self.options + 1] = { text = text, data = data } end
function ISComboBox:setSelected(i) self.selected = i end
ISTickBox = Base:derive()
function ISTickBox.new(self, x, y, w, h, name, target, method)
    local o = Base.new(self, x, y, w, h); o.options, o.selected, o.changeOptionTarget, o.changeOptionMethod = {}, {}, target, method
    o.changeOptionArgs = {}; return o
end
function ISTickBox:addOption(text) self.options[#self.options + 1] = text; self.height = #self.options * 18 end
ISRichTextPanel = Base:derive()
function ISRichTextPanel:setText(v) self.text = v end
ISScrollingListBox = Base:derive()
function ISScrollingListBox.new(self, x, y, w, h) local o = Base.new(self, x, y, w, h); o.items = {}; return o end
function ISScrollingListBox:addItem(name, item) self.items[#self.items + 1] = { text = name, item = item, index = #self.items + 1 } end
function ISScrollingListBox:clear() self.items = {} end
function ISScrollingListBox:setOnMouseDownFunction(target, fn) self.target, self.onmousedown = target, fn end
ISContextMenu = { getNew = function() return {} end }

KIPN = { Client = {} }
dofile(root .. "shared/DynamicEvents_Shared.lua")
KIPN.Shared.Commands = setmetatable({}, { __index = function(_, key) return key end })
KIPN.Shared.ResponseEvents = setmetatable({}, { __index = function(_, key) return key end })
KIPN_EventDirectorPanel = { Toggle = function() end }
KIPN_ZoneAdminMapUI = { Open = function(opts) opts.onConfirm({ x = 1, y = 2, z = 0 }, { x = 9, y = 9, z = 0 }); opts.onClose() end }

dofile(root .. "client/KIPN_EventStudio.lua")
dofile(root .. "client/KIPN_EventStudioLiveUI.lua")
dofile(root .. "client/KIPN_EventStudioUI.lua")
isServer = function() return false end
isClient = function() return true end
UIFont.Large = 4
math.pi = math.pi
dofile(root .. "client/KIPN_EventPlayerHUD.lua")
local W, S = KIPN_EventStudioUI, KIPN_EventStudio

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local failures = 0
local function try(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        failures = failures + 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end
local function reply(event, data) handlers.OnServerCommand("KIPN", "SERVER_RESPONSE", { event = event, data = data }) end
local function lastSent(command)
    for i = #sent, 1, -1 do if sent[i].command == command then return sent[i].args end end
end
local function buttons(studio)
    local out = {}
    for _, widget in ipairs(studio.formWidgets) do
        if widget.onclick then out[#out + 1] = widget end
    end
    return out
end
local function click(studio, title)
    for _, button in ipairs(buttons(studio)) do
        if button.title and button.title:find(title, 1, true) then button.onclick(button.target, button) return true end
    end
    error("no button " .. title)
end

local definitions = {
    { id = "e1", name = "Hill Fight", status = "DRAFT", eventType = "HORDE_SURVIVAL" },
    { id = "e2", name = "Live One", status = "ACTIVE", eventType = "HORDE_SURVIVAL", mode = "SURVIVOR_RUN" },
}

------------------------------------------------------------
-- Walk every step of every mode.
------------------------------------------------------------
local studio
try("open", function()
    studio = W.Open()
    studio:createChildren()
    studio:prerender()
    reply("EVENT_DEFINITIONS_DATA", { definitions = definitions })
    reply("EVENT_EVENTTYPE_METADATA_DATA", { success = true, eventType = "HORDE_SURVIVAL",
        winConditions = { { id = "all_dead", label = "All zombies dead", paramFields = { { key = "count", type = "integer", min = 1 } } } },
        failConditions = { { id = "wiped", label = "Everyone dead" } } })
    reply("EVENT_ONLINE_PLAYERS_DATA", { players = { { username = "alice" }, { username = "bob" } } })
end)

try("select", function() studio:onPickEvent(definitions[1]) end)
for _, mode in ipairs(S.ModeKeys()) do
    try("mode " .. mode, function()
        studio:goStep(1)
        for _, button in ipairs(buttons(studio)) do
            if button.internal == mode then button.onclick(button.target, button) end
        end
        studio:draft().teams = { { id = "team_1", name = "Red", members = { alice = true } }, { id = "team_2", name = "Blue", members = {} } }
        for index = 1, #S.Steps do
            studio:goStep(index)
            studio:prerender()
        end
    end)
end

------------------------------------------------------------
-- Buttons and inputs.
------------------------------------------------------------
try("name edit is dirty and saves on step change", function()
    studio:goStep(1)
    studio.formWidgets[3].text = "Renamed" -- heading, rule, then the name entry
    studio:goStep(2)
    local payload = lastSent("EVENT_UPDATE_DEFINITION")
    assert(payload and payload.name == "Renamed", "expected an auto-save with the new name")
end)
try("area actions", function()
    studio:goStep(1)
    for _, button in ipairs(buttons(studio)) do
        if button.internal == "CAPTURE" then button.onclick(button.target, button) end
    end
    studio:goStep(2)
    click(studio, "Use area around me")
    assert(lastSent("EVENT_CREATE_ZONE_FROM_CORNERS"), "zone around me")
    click(studio, "Draw it on the map")
    assert(lastSent("EVENT_UPSERT_HOTSPOT").hotspot.roundNumber == 1, "needed hotspot carries its round")
    local before = #sent
    click(studio, "Place all needed")
    assert(#sent > before, "placed hotspots")
    click(studio, "Draw on map")
    reply("EVENT_HOTSPOT_SAVED", { success = true, definition = { id = "e1", name = "Renamed", status = "DRAFT",
        hotspots = { { id = "h1", type = "CAPTURE_ITEM", roundNumber = 1, active = true } } } })
    click(studio, "Delete")
    assert(lastSent("EVENT_DELETE_HOTSPOT").hotspotId == "h1", "delete hotspot")
end)
try("item search picks the flag", function()
    studio:goStep(1)
    local search
    for _, widget in ipairs(studio.formWidgets) do
        if widget.onTextChange then search = widget end
    end
    search.text = "ber"
    search.onTextChange()
    click(studio, "Beret")
    assert(studio:draft().captureConfig.flagItemFullType == "Base.Hat_Beret", studio:draft().captureConfig.flagItemFullType)
end)
try("teams", function()
    studio:goStep(1)
    studio:change(function(d) d.variant = "TEAM_CTF" end)
    click(studio, "Set teams")
    assert(lastSent("EVENT_SET_TEAM_COUNT").teamCount == 2)
    reply("EVENT_TEAM_SAVED", { success = true, definition = { id = "e1", name = "Renamed", status = "DRAFT",
        teams = { { id = "team_1", name = "Red" }, { id = "team_2", name = "Blue" } } } })
end)
try("combo and tick callbacks", function()
    for index = 1, #S.Steps do
        studio:goStep(index)
        for _, widget in ipairs(studio.formWidgets) do
            if widget.options and widget.onChange and widget.parent then
                widget.selected = #widget.options
                widget.onChange(widget.target, widget)
                break
            end
        end
    end
    studio:goStep(5)
    for _, widget in ipairs(studio.formWidgets) do
        if widget.changeOptionMethod and widget.studioChange and widget.parent then
            widget.selected[1] = not widget.selected[1]
            widget.changeOptionMethod(widget.changeOptionTarget, 1, widget.selected[1], widget.changeOptionArgs[1])
            break
        end
    end
end)
try("story stages and triggers", function()
    studio:goStep(6)
    studio.newStageEntry.text = "Grab the goods"
    click(studio, "Add stage")
    assert(#studio:draft().objectives == 1)
    studio.triggerParamEntry.text = "Go!"
    click(studio, "Add trigger")
    assert(#studio:draft().objectives[1].triggers == 1)
    click(studio, "Remove")
    assert(#studio:draft().objectives == 0)
end)
try("rewards", function()
    studio:goStep(7)
    local search
    for _, widget in ipairs(studio.formWidgets) do
        if widget.onTextChange then search = widget end
    end
    search.text = "axe"
    search.onTextChange()
    click(studio, "Axe")
    assert(#studio:draft().rewards.items == 1)
    reply("EVENT_REWARDS_DATA", { awards = { { id = "a1", recipientUsername = "alice", status = "AWAITING_ADMIN_DELIVERY", items = { { count = 1, itemFullType = "Base.Axe" } } } } })
    click(studio, "Mark delivered")
    click(studio, "Remove")
    assert(#studio:draft().rewards.items == 0)
end)
try("players", function()
    studio:goStep(8)
    click(studio, "Save roster")
    click(studio, "Teleport roster")
    click(studio, "Refresh")
end)

------------------------------------------------------------
-- Lifecycle.
------------------------------------------------------------
try("launch walks the lifecycle", function()
    local d = studio:draft()
    d.name, d.mode, d.variant = "Run", nil, nil
    S.ApplyMode(d, "SURVIVOR_RUN")
    d.zoneId = "z1"
    studio:goStep(9)
    click(studio, "Check and mark ready")
    assert(studio.pendingValidate == "e1", "validate waits for the save")
    local saved = S.Payload(d)
    saved.status, saved.zoneId = "DRAFT", "z1"
    saved.rewards = { items = {} }
    reply("EVENT_DEFINITION_SAVED", { success = true, definition = saved })
    assert(lastSent("EVENT_VALIDATE").id == "e1", "validate sent after save")
    reply("EVENT_STATUS_CHANGED", { success = false, reason = "NO_ZONE,SURVIVOR_RUN_REQUIRES_DURATION" })
    assert(studio.log[1].text:find("draw the event zone", 1, true), studio.log[1].text)
    for _, status in ipairs({ "READY", "ANNOUNCED", "JOINING" }) do
        local def = S.Copy(saved)
        def.status = status
        reply("EVENT_STATUS_CHANGED", { success = true, definition = def })
        studio:goStep(9)
        click(studio, S.NextAction[status].label)
    end
    reply("EVENT_STARTED", { success = true, status = { eventDefinitionId = "e1", status = "ACTIVE" } })
    assert(not studio.isOpen, "studio closes when the event begins")
    assert(KIPN_EventStudioLiveUI.instance and KIPN_EventStudioLiveUI.instance.definitionId == "e1", "live strip shown")
    local strip = KIPN_EventStudioLiveUI.instance
    strip:createChildren()
    strip:update()
    reply("EVENT_STATUS_DATA", { eventDefinitionId = "e1", status = "ACTIVE", eventName = "Run", endsAtMs = getTimestampMs() + 60000,
        round = { current = 1, maximum = 2 }, participantUsernames = { "alice" }, log = { "started", "wave" } })
    strip:prerender()
    strip:openStudio()
    assert(studio.isOpen, "studio reopened from the strip")
    studio:goStep(9)
    click(studio, "Stop the event")
    click(studio, "Click again to stop")
    assert(lastSent("EVENT_STOP"), "stop needs two clicks")
end)
try("locked steps show a summary", function()
    studio:onPickEvent(definitions[2])
    assert(studio.step == 9, "locked events open on Launch")
    for index = 1, #S.Steps do studio:goStep(index) end
end)
try("errors and delete", function()
    reply("ERROR", { reason = "NOT_EDITABLE" })
    studio:onPickEvent(definitions[1])
    local d = studio:draft()
    d.status = "DRAFT"
    studio:goStep(9)
    click(studio, "Delete this event")
    click(studio, "Click again to delete")
    reply("EVENT_DEFINITION_DELETED", { success = true, id = "e1" })
    assert(studio.selectedId == nil)
    studio:rebuild()
    click(studio, "Create a new event")
    reply("EVENT_DEFINITION_SAVED", { success = true, definition = { id = "e3", name = "New Event", status = "DRAFT" } })
    assert(studio.selectedId == "e3" and studio.step == 1, "new events open on step 1")
    studio:close()
end)

try("classic scenarios", function()
    studio:onPickEvent(definitions[1])
    local d = studio:draft()
    d.status = "DRAFT"
    for _, id in ipairs(KIPN.Shared.EventClassicScenarioOrder) do
        studio:goStep(1)
        local found
        for _, button in ipairs(buttons(studio)) do
            if button.internal == id then found = button end
        end
        assert(found, "button for " .. id)
        found.onclick(found.target, found)
        assert(studio:draft().classicScenario == id, "applied " .. id)
        for index = 1, #S.Steps do studio:goStep(index) end
        studio:goStep(2)
        local before = #sent
        if KIPN.Shared.EventClassicScenarios[id].venue then
            click(studio, "Set up at")
            assert(#sent > before, "venue set-up sent for " .. id)
        end
    end
    studio:goStep(2)
    studio.newHotspotType = "ZOMBIE_AMBUSH"
    studio:rebuild()
    studio.hotspotCountEntry.text = "15"
    click(studio, "Draw on map")
    assert(lastSent("EVENT_UPSERT_HOTSPOT").hotspot.metadata.count == 15, "ambush count")
    studio:goStep(4)
    local toggled = false
    for _, widget in ipairs(studio.formWidgets) do
        if not toggled and widget.options and widget.options[1] and tostring(widget.options[1]):find("Horde siege", 1, true) then
            widget.selected[1] = not widget.selected[1]
            widget.changeOptionMethod(widget.changeOptionTarget, 1, widget.selected[1], widget.changeOptionArgs[1])
            toggled = true
        end
    end
    assert(toggled, "siege tick")
    assert(studio:draft().threats.SIEGE ~= nil, "siege stored")
end)

try("player HUD", function()
    function Base:getAbsoluteX() return self.x end
    function Base:getAbsoluteY() return self.y end
    local send = function(data) handlers.OnServerCommand("KIPN", "SERVER_RESPONSE", { event = KIPN.Shared.ResponseEvents.EVENT_PLAYER_HUD, data = data }) end
    send({ title = "Hill | King of the Hill", goal = "Hold the hill.", round = 2, maxRounds = 3, roundLeftMs = 90000,
        eventLeftMs = 600000, teamName = "Red Team", color = { 1, 0, 0 }, target = { x = 150, y = 150, label = "Hill" }, lines = { "Red: 1 rounds" } })
    send({ banner = "Round 2 of 3: GO!", bannerColor = { 1, 0.8, 0.3 } })
    local hud = KIPN_EventPlayerHUD.instance
    assert(hud and hud.hud.goal == "Hold the hill.", "hud stored")
    hud:createChildren()
    getMouseX = getMouseX or function() return 0 end
    getMouseY = getMouseY or function() return 0 end
    hud:prerender()
    assert(#hud.banners == 1, "banner queued")
    send({ title = "Games", goal = "Station 2", stopwatchMs = 12345, limitLeftMs = 500000, lines = {} })
    hud:prerender()
    hud:toggleCollapsed()
    hud:prerender()
    -- Clues: a button per clue; clicking replays it in full.
    send({ banner = "The code is 4-7-1. Don't forget it, whatever happens tonight.", bannerLong = true, bannerTitle = "Diary page",
        clues = { { title = "Diary page", text = "The code is 4-7-1. Don't forget it, whatever happens tonight." } } })
    assert(#hud.clueButtons == 1 and hud.clueButtons[1].title == "Diary page", "clue button")
    send({ title = "Games", goal = "Station 2", lines = {}, clues = { { title = "Diary page", text = "The code is 4-7-1. Don't forget it, whatever happens tonight." } } })
    assert(#hud.clueButtons == 1, "same clues keep the same buttons")
    hud.banners = {}
    hud.clueButtons[1].onclick(hud.clueButtons[1].target, hud.clueButtons[1])
    assert(hud.banners[1] and hud.banners[1].title == "Diary page" and hud.banners[1].long, "clue replayed")
    hud:prerender()
    -- Fades 5 s after the mouse leaves; comes back on hover.
    getMouseX = function() return -100 end
    getMouseY = function() return -100 end
    hud.lastWakeAt = getTimestampMs() - 10000
    hud:prerender()
    assert(hud.backgroundColor.a < 0.2, "faded when not hovered")
    assert(hud.clueButtons[1].textColor == nil or hud.clueButtons[1].textColor.a < 0.3, "buttons fade too")
    getMouseX = function() return hud.x + 5 end
    getMouseY = function() return hud.y + 5 end
    hud:prerender()
    assert(hud.backgroundColor.a > 0.5, "solid again on hover")
    send({ ended = true, banner = "You won!", goal = "Winner: alice" })
    hud:prerender()
    assert(hud.hideAt ~= nil, "hides after the end")
end)

------------------------------------------------------------
-- Saved / Prepared / Past, the four prepared-event actions,
-- opening at a step, and the Director Controls button.
------------------------------------------------------------
local function viewButton(id)
    for _, b in ipairs(studio.viewButtons) do if b.internal == id then return b end end
end
local function listed()
    local out = {}
    for _, row in ipairs(studio.events.items) do out[#out + 1] = row.item.id end
    return table.concat(out, ",")
end
try("views filter the list", function()
    studio = W.Open()
    definitions[#definitions + 1] = { id = "e7", name = "Church Siege", status = "READY", eventType = "HORDE_SURVIVAL", mode = "SURVIVOR_RUN",
        narrative = { briefing = "Hold the church till dawn." } }
    reply("EVENT_DEFINITIONS_DATA", { definitions = definitions })
    local b = viewButton("prepared")
    b.onclick(b.target, b)
    assert(listed() == "e7", "prepared shows only ready events: " .. listed())
    b = viewButton("saved")
    b.onclick(b.target, b)
    assert(#studio.events.items == 3, "saved shows all")
    studio.directorButton.onclick(studio.directorButton.target, studio.directorButton)
end)
try("prepared actions", function()
    studio:select("e7", S.StepIndex("launch"))
    studio:prerender()
    click(studio, "Start Church Siege")
    local args = lastSent("EVENT_QUICK_START")
    assert(args and args.id == "e7" and args.signupSeconds == 60, "quick start sent")
    click(studio, "Simulate Church Siege")
    args = lastSent("EVENT_SIMULATE")
    assert(args and args.id == "e7" and args.includeStaff == false, "simulate sent")
    studio.simulateWithStaff = true
    click(studio, "Simulate Church Siege")
    assert(lastSent("EVENT_SIMULATE").includeStaff == true, "with staff")
    assert(studio.announcementEntry:getText() == "Hold the church till dawn.", "announcement prefilled with the briefing")
    studio.announcementEntry.text = "Doors open at noon."
    click(studio, "Send announcement")
    assert(lastSent("EVENT_SEND_ANNOUNCEMENT").text == "Doors open at noon.", "announcement sent")
    local before = #sent
    click(studio, "Cancel Church Siege")
    assert(#sent == before, "cancel asks twice")
    click(studio, "Click again to cancel")
    assert(lastSent("EVENT_CANCEL").id == "e7", "cancel sent")
    reply("EVENT_ACTION_RESULT", { id = "e7", action = "cancel", success = true, text = "Church Siege: unlocked for editing (Draft).",
        definition = { id = "e7", name = "Church Siege", status = "DRAFT", eventType = "HORDE_SURVIVAL" } })
    assert(studio.info:find("unlocked", 1, true), "result shown")
    assert(studio:draft().status == "DRAFT", "status updated")
    -- A draft can still be simulated, but not started or announced.
    studio:goStep(S.StepIndex("launch"))
    click(studio, "Simulate Church Siege")
    assert(not pcall(click, studio, "Send announcement"), "no announcements for a draft")
    reply("EVENT_ACTION_RESULT", { id = "e7", action = "simulate", success = true, text = "Simulating." })
    assert(not studio.isOpen, "the Studio gets out of the way of a simulation")
end)
try("past events", function()
    studio = W.Open()
    reply("EVENT_HISTORY_DATA", { records = {
        { id = "r1", definitionId = "e7", name = "Church Siege", mode = "SURVIVOR_RUN", outcome = "WIN", result = "Winner: alice",
            day = 4, participants = { "alice", "bob" }, winners = { "alice" }, deaths = 1, startedAtMs = 0, endedAtMs = 900000 },
        { id = "r2", definitionId = "gone", name = "Old Event", outcome = "CANCELLED", participants = {}, winners = {} },
    } })
    local b = viewButton("past")
    b.onclick(b.target, b)
    assert(#studio.events.items == 2, "past runs listed")
    studio:prerender()
    studio:onPickEvent(studio.events.items[1].item)
    assert(studio.pastRecord and studio.pastRecord.id == "r1", "run picked")
    click(studio, "Open this event")
    assert(studio.selectedId == "e7" and studio.view == "saved", "opens the event")
    b.onclick(b.target, b)
    studio:onPickEvent(studio.events.items[2].item)
    assert(not pcall(click, studio, "Open this event"), "a deleted event can't be opened")
    W.drawEvent(studio.events, 0, studio.events.items[2], false)
end)
try("open at a step", function()
    W.OpenAt("e1", "area")
    assert(W.instance.selectedId == "e1" and W.instance.step == S.StepIndex("area"), "opened at the area step")
    W.OpenAt("e9", "story")
    assert(W.instance.pendingSelect and W.instance.pendingSelect.id == "e9", "waits for the list")
    definitions[#definitions + 1] = { id = "e9", name = "New One", status = "READY", eventType = "HORDE_SURVIVAL" }
    reply("EVENT_DEFINITIONS_DATA", { definitions = definitions })
    assert(W.instance.selectedId == "e9" and W.instance.step == S.StepIndex("story"), "then selects it")
end)
try("banner-only messages", function()
    KIPN_EventPlayerHUD.Hide()
    handlers.OnServerCommand("KIPN", "SERVER_RESPONSE", { event = KIPN.Shared.ResponseEvents.EVENT_PLAYER_HUD,
        data = { banner = "Church Siege begins in 10..." } })
    local hud = KIPN_EventPlayerHUD.instance
    hud:createChildren()
    hud:prerender()
    assert(hud.backgroundColor.a == 0 and not hud.collapseButton.visible, "no empty strip behind a lone banner")
    hud.banners = {}
    hud:prerender()
    assert(KIPN_EventPlayerHUD.instance == nil, "gone once the banner has played")
end)

------------------------------------------------------------
-- The simulation panel and its visual aids.
------------------------------------------------------------
try("simulation panel", function()
    local lit, removedLights = {}, 0
    local floors = {}
    local function floor(key)
        floors[key] = floors[key] or { highlighted = false,
            setHighlighted = function(self, _, on) self.highlighted = on end,
            setHighlightColor = function(self, _, r, g, b, a) self.color = { r, g, b, a } end }
        return floors[key]
    end
    local function zombie(x, y, id)
        return { x = x, y = y, id = id, getX = function(self) return self.x end, getY = function(self) return self.y end,
            getOnlineID = function(self) return self.id end,
            setOutlineHighlight = function(self, _, on) self.outlined = on end,
            setOutlineHighlightCol = function(self, _, r, g, b) self.outline = { r, g, b } end,
            unsetOutlineHighlight = function(self) self.outlined = false end }
    end
    local zombies = { zombie(12, 12, 7), zombie(14, 12, 8), zombie(400, 400, 9) }
    local cell = {
        getGridSquare = function(_, x, y, z) return { getFloor = function() return floor(x .. "," .. y .. "," .. z) end } end,
        addLamppost = function(_, light) lit[#lit + 1] = light end,
        removeLamppost = function() removedLights = removedLights + 1 end,
        getZombieList = function() return { size = function() return #zombies end, get = function(_, i) return zombies[i + 1] end } end,
    }
    getCell = function() return cell end
    IsoLightSource = { new = function(x, y, z, r, g, b, radius) return { x = x, y = y, r = r, g = g, b = b, radius = radius } end }
    local me = { invisible = false, god = false }
    function me:getPlayerNum() return 0 end
    function me:getUsername() return "admin" end
    function me:getX() return 10 end
    function me:getY() return 10 end
    function me:getZ() return 0 end
    function me:isInvisible() return self.invisible end
    function me:setInvisible(v) self.invisible = v end
    function me:isGodMod() return self.god end
    function me:setGodMod(v) self.god = v end
    getPlayer = function() return me end
    KIPN.Shared.Commands.SERVER_RESPONSE = "SERVER_RESPONSE"
    dofile(root .. "client/KIPN_EventSimulationUI.lua")
    local UI = KIPN_EventSimulationUI
    local function sim(data) handlers.OnServerCommand("KIPN", "SERVER_RESPONSE", { event = "EVENT_SIMULATION", data = data }) end
    local step = { id = "e1", name = "Hill Fight", index = 3, total = 9, key = "hotspot:h2", title = "Zombie Spawn", text = "Zombies come from here.",
        studioStep = "area", steps = { "Briefing", "The event zone", "Zombie Spawn", "Bandit Camp", "Threats", "Rounds and the clock", "The ending", "Done", "x" },
        hotspots = { { id = "h1", type = "PLAYER_SPAWN", x1 = 8, y1 = 8, x2 = 12, y2 = 12, z = 0 },
            { id = "h2", type = "ZOMBIE_SPAWN", x1 = 20, y1 = 20, x2 = 24, y2 = 24, z = 0, focus = true } },
        zone = { x1 = 0, y1 = 0, x2 = 40, y2 = 40, z1 = 0 }, fires = { { x = 16, y = 14, z = 0 } }, bandits = { 8 } }
    sim(step)
    local panel = UI.instance
    assert(panel and panel.visible, "panel shown")
    assert(me.invisible and me.god, "the admin is invisible and unhurt")
    assert(floors["10,10,0"].highlighted and floors["22,22,0"].highlighted, "hotspots glow")
    assert(floors["22,22,0"].color[1] == 1 and floors["22,22,0"].color[2] < 0.2, "zombie spawns glow red")
    assert(floors["0,17,0"] and floors["0,17,0"].highlighted, "the zone edge glows")
    assert(#lit >= 2, "a light on the focus hotspot and the demo fire")
    assert(zombies[1].outlined and zombies[1].outline[1] == 1 and zombies[1].outline[2] < 0.2, "zombies outlined red")
    assert(zombies[2].outlined and zombies[2].outline[3] > 0.5, "bandits outlined in their own colour")
    assert(not zombies[3].outlined, "far zombies left alone")
    handlers.OnTick()
    panel:prerender()
    panel.okButton.onclick(panel.okButton.target, panel.okButton)
    assert(lastSent("EVENT_SIMULATE_STEP").choice == "OK", "OK sent")
    panel.editButton.onclick(panel.editButton.target, panel.editButton)
    assert(lastSent("EVENT_SIMULATE_STEP").choice == "EDIT", "Edit sent")
    assert(W.instance and W.instance.isOpen and W.instance.selectedId == "e1" and W.instance.step == S.StepIndex("area"), "Edit opens the Studio at the step")
    step.editing = true
    sim(step)
    assert(panel.okButton.title == "Resume" and not panel.editButton.visible, "Resume while editing")
    panel:prerender()
    panel.okButton.onclick(panel.okButton.target, panel.okButton)
    assert(lastSent("EVENT_SIMULATE_STEP").choice == "RESUME", "Resume sent")
    panel.cancelButton.onclick(panel.cancelButton.target, panel.cancelButton)
    assert(lastSent("EVENT_SIMULATE_STEP").choice == "CANCEL", "Cancel sent")
    step.editing, step.index = false, 9
    sim(step)
    assert(panel.okButton.title == "Finish", "the last step finishes")
    sim({ id = "e1", ended = true })
    assert(UI.instance == nil, "panel closed")
    assert(not floors["22,22,0"].highlighted and not zombies[1].outlined, "glow and outlines removed")
    assert(removedLights >= 2, "lights removed")
    assert(not me.invisible and not me.god, "visibility restored")

    -- A guest in someone else's simulation sees only Leave.
    step.admin, step.index, step.editing = "host", 3, false
    sim(step)
    panel = UI.instance
    assert(panel.guest and not panel.okButton.visible and not panel.editButton.visible and panel.cancelButton.title == "Leave", "guest panel")
    panel:prerender()
    panel.cancelButton.onclick(panel.cancelButton.target, panel.cancelButton)
    assert(lastSent("EVENT_SIMULATE_STEP").choice == "CANCEL", "Leave sent")
    sim({ id = "e1", ended = true, left = true })
    assert(UI.instance == nil and not me.invisible, "leaving closes it and makes you visible")

    -- The host hears who joined.
    step.admin = "admin"
    sim(step)
    handlers.OnServerCommand("KIPN", "SERVER_RESPONSE", { event = "EVENT_ACTION_RESULT",
        data = { action = "simulationGuest", success = true, text = "staff joined the simulation." } })
    assert(UI.instance.guestNote == "staff joined the simulation.", "guest note")
    UI.instance:prerender()
    sim({ id = "e1", ended = true })

    -- The invitation: OK joins, Cancel opts out, a withdrawn one closes.
    local function invite(data) handlers.OnServerCommand("KIPN", "SERVER_RESPONSE", { event = "EVENT_SIMULATION_INVITE", data = data }) end
    invite({ id = "e1", name = "Hill Fight", host = "host", total = 9 })
    local prompt = UI.Invite.instance
    assert(prompt and prompt.visible and prompt.okButton.title == "OK" and prompt.cancelButton.title == "Cancel", "invitation shown")
    assert(UI.Invite.Text(prompt.data):find("host is running a simulation of Hill Fight", 1, true), "it says who and what")
    prompt:prerender()
    prompt.okButton.onclick(prompt.okButton.target, prompt.okButton)
    local answer = lastSent("EVENT_SIMULATION_RESPOND")
    assert(answer and answer.id == "e1" and answer.accept == true and UI.Invite.instance == nil, "OK accepts")
    invite({ id = "e1", name = "Hill Fight", host = "host", total = 9 })
    prompt = UI.Invite.instance
    prompt.cancelButton.onclick(prompt.cancelButton.target, prompt.cancelButton)
    answer = lastSent("EVENT_SIMULATION_RESPOND")
    assert(answer.accept == false and UI.Invite.instance == nil, "Cancel opts out")
    invite({ id = "e1", name = "Hill Fight", host = "host", total = 9 })
    invite({ id = "e1", withdrawn = true })
    assert(UI.Invite.instance == nil, "a withdrawn invitation closes")
end)

try("right-click entries follow the sandbox", function()
    local added
    local context = { addOption = function(_, label, _, fn) added[#added + 1] = label return {} end }
    ISWorldObjectContextMenu = { addToolTip = function() return {} end }
    local level = "ADMIN"
    KIPN.Client.AdminAccess = { GetAccessLevel = function() return level end }
    KIPN_EventDirectorControlUI = { Toggle = function() end }
    dofile(root .. "client/KIPN_EventDirectorTrigger.lua")
    local Trigger = KIPN_EventDirectorTrigger
    local function fill(lvl) level, added = lvl, {} Trigger.Fill(0, context, {}, false) return table.concat(added, "|") end
    SandboxVars = { DynamicEvents = {} }
    assert(fill("ADMIN") == "Dynamic Events|Dynamic Events: Director Controls", fill("ADMIN"))
    assert(fill("STAFF") == "Dynamic Events: Director Controls", "staff get Director Controls")
    assert(fill("USER") == "", "players get nothing")
    SandboxVars.DynamicEvents.StudioStaff = true
    assert(fill("STAFF") == "Dynamic Events|Dynamic Events: Director Controls", "allowed staff get the Studio")
    assert(fill("GM") == "Dynamic Events: Director Controls", "other levels still don't")
    level, added = "ADMIN", {}
    Trigger.Fill(0, context, {}, true)
    assert(#added == 0, "nothing on the test pass")
end)

print(failures == 0 and "studio_ui_smoke: ok" or ("studio_ui_smoke: " .. failures .. " failed"))
if failures > 0 then os.exit(1) end
