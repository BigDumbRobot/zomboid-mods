-- Test Console logging, traffic capture and window state; no game engine required.
require = function() end
UIFont = { Small = "small" }
getTextManager = function() return { getFontHeight = function() return 16 end,
    MeasureStringX = function(_, font, text) return #text * 8 end } end
getCore = function() return { getScreenWidth = function() return 1280 end, getScreenHeight = function() return 800 end } end
local clock = 1000
getTimestampMs = function() return clock end
local Base = {}
function Base:derive() local class = {}; class.__index = class; return setmetatable(class, { __index = self }) end
function Base:new(x, y, width, height) return setmetatable({ x=x, y=y, width=width, height=height, items={}, children={}, yScroll=0 }, self) end
Base.__index = Base
function Base:initialise() end
function Base:createChildren() end
function Base:addChild(child) self.children[#self.children + 1] = child end
function Base:addToUIManager() if not self.created then self.created = true; self:createChildren() end end
function Base:setVisible(value) self.visible = value end
function Base:bringToTop() end
function Base:titleBarHeight() return 24 end
function Base:resizeWidgetHeight() return 10 end
function Base:setX(value) self.x = value end
function Base:setY(value) self.y = value end
function Base:setWidth(value) assert(value > 0); self.width = value end
function Base:setHeight(value) assert(value > 0); self.height = value end
function Base:setEnable(value) self.enabled = value end
function Base:setTitle(value) self.title = value end
function Base:setText(value) self.text = value end
function Base:getText() return self.text or "" end
function Base:setPlaceholderText(value) self.placeholder = value end
function Base:paginate() end
function Base:getScrollHeight() local _, n = (self.text or ""):gsub("<LINE>", ""); return n * 16 end
function Base:getYScroll() return self.yScroll end
function Base:setYScroll(value) self.yScroll = value end
function Base:setMargins() end
function Base:addScrollBars() end
function Base:setOnMouseDownFunction(target, callback) self.target = target; self.callback = callback end
function Base:clear() self.items = {} end
function Base:addItem(text, data) self.items[#self.items + 1] = { text = text, item = data, index = #self.items + 1 } end
function Base:drawText(text) self.drawn = text end
function Base:drawRect() end
function Base:prerender() end
ISCollapsableWindow, ISScrollingListBox, ISRichTextPanel, ISButton = Base, Base, Base, Base
ISTextEntryBox = Base:derive()
function ISTextEntryBox:new(text, x, y, width, height)
    local o = Base.new(self, x, y, width, height); o.text = text; return o
end
local serverListeners = {}
Events = setmetatable({ OnServerCommand = { Add = function(fn) serverListeners[#serverListeners + 1] = fn end } },
    { __index = function(t, key) local event = { Add = function() end }; t[key] = event; return event end })
local sent = {}
sendClientCommand = function(...) sent[#sent + 1] = { ... } end
local clipboard
Clipboard = { setClipboard = function(text) clipboard = text end }
local player = { getPlayerNum = function() return 0 end, getOnlineID = function() return 7 end }
local other = { getPlayerNum = function() return 1 end, getOnlineID = function() return 9 end }
getSpecificPlayer = function(index) return index == 0 and player or index == 1 and other or nil end

local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
dofile(root .. "client/LilBubbyShowcase.lua")
local S = LilBubbyShowcase
dofile(root .. "client/LilBubbyConsoleUI.lua")
dofile(root .. "client/LilBubbyShowcaseUI.lua")

-- Reports split into levelled lines; blank lines dropped; markup escaped on display.
S.Report(player, "vehicle", "Header\n\nPASS: one\nFAIL: two\nBLOCKED | three\nDisarm ATTEMPT FAILED\nCould not start: <IMAGE:x>")
local lines = S.Console(0)
assert(#lines == 6, "blank lines are dropped")
local levels = {}
for i, line in ipairs(lines) do levels[i] = line.level end
assert(table.concat(levels, ",") == "INFO,PASS,FAIL,BLOCKED,FAIL,INFO", table.concat(levels, ","))
assert(#S.Console(1) == 0, "consoles are per local player")

-- Tester traffic both directions is logged; other mods' commands are not; the
-- original function still receives every argument, including nil holes.
clock = 3500
sendClientCommand(player, "LilBubbyVehSvcTest", "run", { id = "all_checks", vehicleId = 12, nested = {} })
sendClientCommand("KIPN", "RequestExcavationAreas", {})
sendClientCommand(other, "LilBubbyPostalTest", "run", nil)
assert(#sent == 3 and sent[1][2] == "LilBubbyVehSvcTest" and sent[2][1] == "KIPN" and sent[3][4] == nil)
local send = lines[#lines]
assert(send.level == "SEND" and send.id == "vehicle" and send.text:find("run", 1, true)
    and send.text:find("id=all_checks vehicleId=12", 1, true) and not send.text:find("nested", 1, true), send.text)
assert(send.time == 2500, "timestamps are relative to the first line")
assert(#S.Console(1) == 1 and S.Console(1)[1].id == "postal", "send goes to the sending player's console")
for _, listener in ipairs(serverListeners) do
    listener("LilBubbyVehSvcTest", "result", { playerID = 9, status = "PASS", text = "long report" })
    listener("SomeOtherMod", "sync", {})
end
local recv = S.Console(1)[2]
assert(recv and recv.level == "RECV" and recv.text:find("status=PASS", 1, true) and not recv.text:find("long report", 1, true))
assert(#S.Console(0) == 7, "unrelated modules ignored")

-- Bounded buffer.
for i = 1, 600 do S.Log(1, "spy", "PASS: " .. i) end
assert(#S.Console(1) == S.CONSOLE_LIMIT and S.Console(1)[S.CONSOLE_LIMIT].text == "PASS: 600")

-- Showcase button opens and closes the console; closing keeps collecting.
S.Open(player)
local showcase = S.windows[0]
assert(showcase.consoleButton, "showcase has a console button")
showcase:prerender()
assert(showcase.consoleButton.title == "Console")
showcase:toggleConsole()
local console = S.consoleWindows[0]
assert(console and console:isOpen() and console.visible)
showcase:prerender()
assert(showcase.consoleButton.title == "Hide console")
console:prerender()
assert(console.log.text:find("[IMAGE:x]", 1, true) and not console.log.text:find("<IMAGE", 1, true), "markup escaped")
assert(console.log.text:find("+00:02.5", 1, true), "elapsed time stamp")
assert(console.log.text:find("[Vehicle Claims]", 1, true), "mod name tag")
console:close()
assert(not console:isOpen() and console.visible == false)
S.Report(player, "dmm", "PASS: while hidden")
showcase:toggleConsole()
assert(console:isOpen())
console:prerender()
assert(console.log.text:find("while hidden", 1, true), "lines logged while hidden are shown on reopen")
assert(console.log.yScroll == math.min(0, console.log.height - console.log:getScrollHeight()), "reopen jumps to newest")

-- Filters: selected mod only, and traffic hidden.
for _, mod in ipairs(S.Mods) do if mod.id == "dmm" then showcase:selectMod(mod) end end
console:toggleScope(); console:prerender()
assert(console.scopeButton.title == "This mod" and not console.log.text:find("Vehicle Claims", 1, true)
    and console.log.text:find("while hidden", 1, true))
console:toggleScope(); console:toggleTraffic(); console:prerender()
assert(console.trafficButton.title == "Traffic: off" and not console.log.text:find("to server", 1, true))
console:toggleTraffic(); console:prerender()
assert(console.log.text:find("to server: run", 1, true) and console.log.text:find("[Postal Service]", 1, true) == nil)

-- Scrolled-back readers are not yanked to the bottom by new lines.
for i = 1, 40 do S.Report(player, "dmm", "PASS: filler " .. i) end
console:prerender()
assert(console.log.yScroll < 0, "follows newest while at the bottom")
console.log.yScroll = 0
S.Report(player, "dmm", "INFO: another line")
console:prerender()
assert(console.log.yScroll == 0, "keeps scroll position when reading history")

console:copy()
assert(clipboard and clipboard:find("filler 40", 1, true) and console.status:find("Copied", 1, true))
console:clear(); console:prerender()
assert(#S.Console(0) == 0 and console.log.text:find("No output yet", 1, true))
console.width, console.height = 480, 160; console:prerender()
showcase.width, showcase.height = 760, 540; showcase:prerender()
print("PASS: console levels, per-player buffers, traffic capture and passthrough, bounded log, open/close, escaping, filters, scroll follow, copy and clear")
