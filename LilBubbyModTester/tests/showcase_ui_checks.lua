-- Exercise window state transitions without a running game renderer.
require = function() end
getActivatedMods = function() return { contains = function() return true end } end -- every tested mod enabled
UIFont = { Small = "small" }
getTextManager = function() return { getFontHeight = function() return 16 end,
    MeasureStringX = function(_, font, text) return #text * 8 end } end
getCore = function() return { getScreenWidth = function() return 1280 end, getScreenHeight = function() return 800 end } end
local Base = {}
function Base:derive() local class = {}; class.__index = class; return setmetatable(class, { __index = self }) end
function Base:new(x, y, width, height) return setmetatable({ x=x, y=y, width=width, height=height, items={}, children={} }, self) end
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
function Base:setYScroll() end
function Base:setMargins() end
function Base:addScrollBars() end
function Base:setOnMouseDownFunction(target, callback) self.target = target; self.callback = callback end
function Base:clear() self.items = {} end
function Base:addItem(text, data) self.items[#self.items + 1] = { text = text, item = data, index = #self.items + 1 } end
function Base:drawText(text) if self.isStrip then drawn[#drawn + 1] = text end end
function Base:drawRect() end
function Base:prerender() end
ISCollapsableWindow, ISScrollingListBox, ISRichTextPanel, ISButton, ISPanel = Base, Base, Base, Base, Base
function Base:removeFromUIManager() self.removed = true end
drawn = {}
ISTextEntryBox = Base:derive()
function ISTextEntryBox:new(text, x, y, width, height)
    local o = Base.new(self, x, y, width, height); o.text = text; return o
end
Events = { OnFillWorldObjectContextMenu = { Add = function() end } }
local player = { getPlayerNum = function() return 0 end }
getSpecificPlayer = function() return player end
local root = "Contents/mods/LilBubbyModTester/42/media/lua/client/"
dofile(root .. "LilBubbyShowcase.lua")
local S = LilBubbyShowcase
local runs = 0
S.Register("dmm", function(index, menu)
    menu:addOption("Example feature", player, function(p) runs = runs + 1; S.Report(p, "dmm", "PASS: <IMAGE:bad> result") end)
end)
dofile(root .. "LilBubbyMiniUI.lua")
function LilBubbyMiniUI:initialise() self.isStrip = true end
dofile(root .. "LilBubbyShowcaseUI.lua")
S.Open(player)
local window = S.windows[0]
for _, mod in ipairs(S.Mods) do if mod.id == "dmm" then window:selectMod(mod) end end
assert(#window.features.items == 1 and window.startButton.enabled)
window:start()
assert(runs == 1 and window.result.text:find("[IMAGE:bad]", 1, true), "report markup is escaped")
-- Starting a test gets the window out of the way; the corner strip shows progress.
local strip = LilBubbyMiniUI.windows[0]
assert(window.visible == false, "starting a test hides the showcase")
assert(strip and strip.visible, "the corner strip appears")
assert(strip.x == 12 and strip.y + strip.height == 800 - 12 and strip.width <= 520, "small strip in the bottom-left corner")
S.LogTraffic("SEND", 0, "LilBubbyDMMTest", "kill", {})
drawn = {}
strip:prerender()
local text = table.concat(drawn, "\n")
assert(text:find("<IMAGE:bad> result", 1, true) and text:find("STARTED: Example feature", 1, true), "strip shows the newest results: " .. text)
assert(not text:find("to server", 1, true), "command traffic stays in the console")
for i = 1, 20 do S.Report(player, "dmm", "PASS: line " .. i) end
drawn = {}
strip:prerender()
assert(#drawn == 1 + LilBubbyMiniUI.LINES and drawn[#drawn] == "PASS: line 20", "only the newest lines fit")
S.Open(player)
assert(window.visible and not strip.visible, "reopening the showcase hides the strip")
LilBubbyMiniUI.Show(0)
strip:openShowcase()
assert(window.visible and not strip.visible, "the strip's Showcase button brings the window back")
window:toggleDetails()
assert(window.fullReport and window.detailsButton.title == "Show summary")
window:older(); assert(window.historyIndex == 2)
window:newer(); assert(window.historyIndex == 1)
window.search:setText("unmatched"); window:filter()
assert(#window.features.items == 0 and not window.startButton.enabled)
window.search:setText("example"); window:filter()
assert(#window.features.items == 1)
window.width = 760; window.height = 540; window:prerender()
window.features:doDrawItem(0, window.features.items[1], false)
window:setVisible(false)
S.Report(player, "dmm", "FAIL: while closed")
assert(window.visible == false, "results must not reopen a closed window")
S.Open(player)
assert(window.visible and window.result.text:find("while closed", 1, true), "reopening retains latest report")
window:selectMod(S.Mods[2])
assert(#window.features.items == 0 and not window.startButton.enabled)
assert(window.result.text:find("Results", 1, true), "another mod has separate history")
print("PASS: showcase window creation, dispatch, corner progress strip, search, resizing, report escaping, history navigation, reopen and mod switching")
