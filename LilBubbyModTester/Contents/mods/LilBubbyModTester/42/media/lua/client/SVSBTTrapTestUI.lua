require "ISUI/ISPanel"
require "ISUI/ISButton"
require "SVSBTRecipeUI"
require "SVSBTTest_Traps"

-- The two windows of a Spy vs Spy trap test, each with a green OK and a red
-- Cancel button:
--   Recipe:  what the trap takes to craft, with the MAD Magazine that teaches
--            it on the right (cover, description, what it teaches), and a
--            synopsis of the test across the bottom of both.
--   Message: a large instruction ("Craft your trap then click OK") that stays
--            up, movable, while the player crafts.
SVSBTTrapTestUI = SVSBTTrapTestUI or {}
local UI = SVSBTTrapTestUI
local R = SVSBTRecipeUI
local T = SVSBTTest.Traps

local ROW, PAD, BUTTON_W, BUTTON_H = 40, 16, 130, 34
local GREEN = { bg = { r = 0.10, g = 0.42, b = 0.14, a = 0.95 }, over = { r = 0.16, g = 0.58, b = 0.20, a = 1 } }
local RED = { bg = { r = 0.50, g = 0.12, b = 0.12, a = 0.95 }, over = { r = 0.68, g = 0.16, b = 0.16, a = 1 } }

local function fontHeight(font) return getTextManager():getFontHeight(font) end

-- Splits text into lines no wider than width.
function UI.Wrap(text, font, width)
    local lines, manager = {}, getTextManager()
    for paragraph in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in paragraph:gmatch("%S+") do
            local candidate = line == "" and word or (line .. " " .. word)
            if line ~= "" and manager:MeasureStringX(font, candidate) > width then
                lines[#lines + 1] = line
                line = word
            else
                line = candidate
            end
        end
        lines[#lines + 1] = line
    end
    return lines
end

local function button(parent, title, colors, onClick)
    local child = ISButton:new(0, 0, BUTTON_W, BUTTON_H, title, parent, onClick)
    child:initialise()
    child.backgroundColor = colors.bg
    child.backgroundColorMouseOver = colors.over
    child.borderColor = { r = 1, g = 1, b = 1, a = 0.5 }
    child.textColor = { r = 1, g = 1, b = 1, a = 1 }
    child:setFont(UIFont.Medium)
    parent:addChild(child)
    return child
end

local function base(width, height, y)
    local o = ISPanel:new(math.floor((getCore():getScreenWidth() - width) / 2), y, width, height)
    o.moveWithMouse = true
    o.backgroundColor = { r = 0.07, g = 0.08, b = 0.10, a = 0.96 }
    o.borderColor = { r = 0.65, g = 0.5, b = 0.95, a = 0.9 }
    return o
end

local function addButtons(o)
    o.okButton = button(o, "OK", GREEN, function() if o.onOk then o.onOk() end end)
    o.cancelButton = button(o, "Cancel", RED, function() if o.onCancel then o.onCancel() end end)
end

-- Centres the visible buttons along the bottom edge.
local function placeButtons(o)
    local shown = {}
    for _, b in ipairs({ o.okButton, o.cancelButton }) do
        if b and b:getIsVisible() then shown[#shown + 1] = b end
    end
    local gap = 24
    local x = math.floor((o.width - #shown * BUTTON_W - (#shown - 1) * gap) / 2)
    for _, b in ipairs(shown) do
        b:setX(x); b:setY(o.height - BUTTON_H - PAD)
        x = x + BUTTON_W + gap
    end
end

------------------------------------------------------------
-- The magazine
------------------------------------------------------------

function UI.MagazineInfo(fullType)
    if not fullType then return nil end
    local script = getScriptManager():FindItem(fullType)
    if not script then return nil end
    local info = { fullType = fullType, name = fullType, teaches = {} }
    local ok, name = pcall(function() return script:getDisplayName() end)
    if ok and name then info.name = name end
    local okTex, texture = pcall(function() return script:getNormalTexture() end)
    info.texture = okTex and texture or nil
    if not info.texture then
        local okIcon, icon = pcall(function() return getTexture("Item_" .. script:getIcon()) end)
        info.texture = okIcon and icon or nil
    end
    local key = "Tooltip_SVSBT_" .. (fullType:match("%.(.+)$") or fullType)
    local okText, description = pcall(getText, key)
    info.description = okText and description ~= key and description or nil
    for _, recipeName in ipairs(T.Teaches(fullType)) do
        local recipe = T.Recipe(recipeName)
        local okName, translated = pcall(function() return recipe:getTranslationName() end)
        info.teaches[#info.teaches + 1] = okName and translated or recipeName
    end
    return info
end

-- Without the game's UI (offline checks) only the helpers above load.
if not ISPanel then return SVSBTTrapTestUI end

------------------------------------------------------------
-- Phase 1: the recipe
------------------------------------------------------------

UI.Recipe = ISPanel:derive("SVSBTTrapRecipeWindow")
local RW = UI.Recipe

local LEFT_W, RIGHT_W = 500, 300
local SYNOPSIS_W = LEFT_W + PAD + RIGHT_W

-- Every line is wrapped to its own pane, and each ingredient row grows to
-- fit its name, so nothing runs into the next pane or the count.
function RW:new(player, trap)
    local o = base(PAD * 3 + LEFT_W + RIGHT_W, 200, 170)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.trap = trap
    o.data = R.Trap(player, trap.kind)
    o.magazine = UI.MagazineInfo(T.Magazine(trap.recipe))
    local small, medium, large = fontHeight(UIFont.Small), fontHeight(UIFont.Medium), fontHeight(UIFont.Large)
    local okOutput, output = pcall(T.Output, trap.recipe)
    local outputScript = okOutput and output and getScriptManager():FindItem(output)
    local okName, outputName = pcall(function() return outputScript and outputScript:getDisplayName() end)
    o.synopsis = {}
    for i, text in ipairs(T.Synopsis(trap, o.magazine and o.magazine.name, okName and outputName or nil)) do
        for j, line in ipairs(UI.Wrap(text, UIFont.Small, SYNOPSIS_W - 20 - (i > 1 and 16 or 0))) do
            o.synopsis[#o.synopsis + 1] = { text = line, step = i > 1, indent = i > 1 and j > 1 }
        end
    end
    local data = o.data
    o.titleLines = UI.Wrap(trap.name, UIFont.Large, LEFT_W)
    o.stateLines = UI.Wrap(data.problem or ("Recipe: " .. tostring(trap.recipe)), UIFont.Small, LEFT_W)
    o.rows = {}
    local left = 12 + #o.titleLines * large + 8 + #o.stateLines * small + 14
    for _, row in ipairs(data.inputs) do
        local count = "x " .. tostring(row.need)
        local countW = getTextManager():MeasureStringX(UIFont.Medium, count)
        local lines = UI.Wrap(R.RowLabel(row), UIFont.Small, LEFT_W - 42 - countW - 12)
        local height = math.max(ROW, #lines * small + 16)
        o.rows[#o.rows + 1] = { row = row, count = count, lines = lines, height = height }
        left = left + height
    end
    local info = o.magazine
    local right
    if info then
        o.magazineTitle = UI.Wrap(info.name, UIFont.Medium, RIGHT_W)
        o.magazineLines = UI.Wrap(info.description or "", UIFont.Small, RIGHT_W)
        o.teachLines = {}
        for _, name in ipairs(info.teaches) do
            for i, line in ipairs(UI.Wrap(name, UIFont.Small, RIGHT_W - 20)) do
                o.teachLines[#o.teachLines + 1] = { text = line, first = i == 1 }
            end
        end
        right = 12 + 128 + 10 + #o.magazineTitle * medium + 8 + #o.magazineLines * small + 12
            + (#o.teachLines + 1) * (small + 2)
    else
        o.noMagazine = UI.Wrap("No MAD Magazine teaches this recipe.", UIFont.Small, RIGHT_W)
        right = 12 + #o.noMagazine * small
    end
    o.panesH = math.max(left, right)
    o.synopsisH = 10 + medium + 6 + #o.synopsis * (small + 1) + 10
    o:setHeight(o.panesH + PAD + o.synopsisH + PAD + BUTTON_H + PAD)
    return o
end

function RW:createChildren()
    ISPanel.createChildren(self)
    addButtons(self)
    placeButtons(self)
end

function RW:prerender()
    ISPanel.prerender(self)
    local data = self.data
    local small, medium, large = fontHeight(UIFont.Small), fontHeight(UIFont.Medium), fontHeight(UIFont.Large)
    local x, y = PAD, 12
    for _, line in ipairs(self.titleLines) do
        self:drawText(line, x, y, 0.9, 0.85, 1, 1, UIFont.Large)
        y = y + large
    end
    y = y + 8
    local r, g, b = 0.7, 0.7, 0.7
    if data.problem then r, g, b = 1, 0.42, 0.42 end
    for _, line in ipairs(self.stateLines) do
        self:drawText(line, x, y, r, g, b, 1, UIFont.Small)
        y = y + small
    end
    y = y + 6
    self:drawRect(x, y, LEFT_W, 1, 0.3, 1, 1, 1)
    y = y + 8
    for _, entry in ipairs(self.rows) do
        R.DrawIcon(self, entry.row, x, y)
        local ty = y + math.floor((entry.height - #entry.lines * small) / 2)
        for _, line in ipairs(entry.lines) do
            self:drawText(line, x + 42, ty, 0.9, 0.9, 0.9, 1, UIFont.Small)
            ty = ty + small
        end
        self:drawTextRight(entry.count, x + LEFT_W, y + math.floor((entry.height - medium) / 2), 0.95, 0.95, 0.6, 1, UIFont.Medium)
        y = y + entry.height
    end
    -- The magazine, right of the ingredients.
    local mx = PAD * 2 + LEFT_W
    self:drawRect(mx - PAD / 2, 12, 1, self.panesH - 12, 0.3, 1, 1, 1)
    self:drawSynopsis()
    local info = self.magazine
    y = 12
    if not info then
        for _, line in ipairs(self.noMagazine) do
            self:drawText(line, mx, y, 0.7, 0.7, 0.7, 1, UIFont.Small)
            y = y + small
        end
        return
    end
    local cx = mx + (RIGHT_W - 128) / 2
    if info.texture then self:drawTextureScaled(info.texture, cx, y, 128, 128, 1, 1, 1, 1)
    else self:drawRectBorder(cx, y, 128, 128, 0.5, 0.7, 0.7, 0.7) end
    y = y + 128 + 10
    for _, line in ipairs(self.magazineTitle) do
        self:drawText(line, mx, y, 1, 0.95, 0.6, 1, UIFont.Medium)
        y = y + medium
    end
    y = y + 8
    for _, line in ipairs(self.magazineLines) do
        self:drawText(line, mx, y, 0.85, 0.85, 0.85, 1, UIFont.Small)
        y = y + small
    end
    y = y + 12
    self:drawText("Teaches:", mx, y, 0.6, 0.72, 0.8, 1, UIFont.Small)
    for _, line in ipairs(self.teachLines) do
        y = y + small + 2
        self:drawText((line.first and "- " or "  ") .. line.text, mx + 8, y, 0.9, 0.9, 0.9, 1, UIFont.Small)
    end
end

-- The third pane, across the bottom of both: what the test will do.
function RW:drawSynopsis()
    local small, medium = fontHeight(UIFont.Small), fontHeight(UIFont.Medium)
    local x, y = PAD, self.panesH + PAD
    self:drawRect(x, y, SYNOPSIS_W, self.synopsisH, 0.35, 0.16, 0.12, 0.24)
    self:drawRectBorder(x, y, SYNOPSIS_W, self.synopsisH, 0.6, 0.65, 0.5, 0.95)
    y = y + 10
    self:drawText("What this test does", x + 10, y, 0.9, 0.85, 1, 1, UIFont.Medium)
    y = y + medium + 6
    for _, line in ipairs(self.synopsis) do
        local r, g, b = 0.85, 0.85, 0.85
        if not line.step then r, g, b = 1, 0.95, 0.6 end
        self:drawText(line.text, x + 10 + (line.indent and 16 or 0), y, r, g, b, 1, UIFont.Small)
        y = y + small + 1
    end
end

------------------------------------------------------------
-- Phases 2 and 3: the instruction
------------------------------------------------------------

UI.Message = ISPanel:derive("SVSBTTrapMessageWindow")
local MW = UI.Message
local MESSAGE_W = 760

-- spec: { headline = {large lines}, warning = red line, details = {lines},
--         left = true sets the details against the left edge (long instructions),
--         status = { text, ready } a green (ready) or amber line under them,
--         problem = red line under that, ok = show OK (default true) }
function MW:new(spec)
    local o = base(MESSAGE_W, 200, 170)
    setmetatable(o, self)
    self.__index = self
    o.spec = spec
    return o
end

local function wrapAll(lines, font, width)
    local out = {}
    for _, line in ipairs(lines or {}) do
        for _, part in ipairs(UI.Wrap(line, font, width)) do out[#out + 1] = part end
    end
    return out
end

function MW:layout()
    local spec, inner = self.spec, MESSAGE_W - PAD * 2
    self.big = wrapAll(spec.headline, UIFont.Large, inner)
    self.warning = wrapAll(spec.warning and { spec.warning } or nil, UIFont.Large, inner)
    self.small = wrapAll(spec.details, UIFont.Medium, inner)
    self.status = wrapAll(spec.status and { spec.status.text } or nil, UIFont.Medium, inner)
    self.problem = wrapAll(spec.problem and { spec.problem } or nil, UIFont.Medium, inner)
    local buttons = (spec.ok ~= false or spec.cancel ~= false) and (BUTTON_H + PAD) or 0
    self:setHeight(16 + (#self.big + #self.warning) * (fontHeight(UIFont.Large) + 4) + 10
        + (#self.small + #self.status + #self.problem) * fontHeight(UIFont.Medium) + 20
        + (#self.status > 0 and 10 or 0) + buttons)
    if self.okButton then
        self.okButton:setVisible(spec.ok ~= false)
        self.cancelButton:setVisible(spec.cancel ~= false)
        placeButtons(self)
    end
end

-- Changes what the window says: any field of spec given here replaces it.
function MW:change(changes)
    for key, value in pairs(changes) do self.spec[key] = value end
    self:layout()
end

function MW:setProblem(problem) self:change({ problem = problem or false }) end

function MW:createChildren()
    ISPanel.createChildren(self)
    addButtons(self)
    self:layout()
end

function MW:prerender()
    ISPanel.prerender(self)
    local centre, y = self.width / 2, 16
    for _, line in ipairs(self.big) do
        self:drawTextCentre(line, centre, y, 1, 0.95, 0.6, 1, UIFont.Large)
        y = y + fontHeight(UIFont.Large) + 4
    end
    for _, line in ipairs(self.warning) do
        self:drawTextCentre(line, centre, y, 1, 0.3, 0.3, 1, UIFont.Large)
        y = y + fontHeight(UIFont.Large) + 4
    end
    y = y + 10
    for _, line in ipairs(self.small) do
        if self.spec.left then self:drawText(line, PAD, y, 0.9, 0.9, 0.9, 1, UIFont.Medium)
        else self:drawTextCentre(line, centre, y, 0.9, 0.9, 0.9, 1, UIFont.Medium) end
        y = y + fontHeight(UIFont.Medium)
    end
    y = y + 10
    if #self.status > 0 then
        local r, g, b = 1, 0.76, 0.30
        if self.spec.status.ready then r, g, b = 0.45, 0.95, 0.45 end
        for _, line in ipairs(self.status) do
            self:drawTextCentre(line, centre, y, r, g, b, 1, UIFont.Medium)
            y = y + fontHeight(UIFont.Medium)
        end
        y = y + 10
    end
    for _, line in ipairs(self.problem) do
        self:drawTextCentre(line, centre, y, 1, 0.42, 0.42, 1, UIFont.Medium)
        y = y + fontHeight(UIFont.Medium)
    end
end

------------------------------------------------------------
-- After the detonation: a screen that must be cleaned up
------------------------------------------------------------

-- Covers the whole screen and takes the mouse until its one button is
-- clicked, so play only continues once the test is cleaned up.
UI.Cleanup = ISPanel:derive("SVSBTTrapCleanupScreen")
local CW = UI.Cleanup

function CW:new()
    local o = ISPanel:new(0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
    setmetatable(o, self)
    self.__index = self
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.97 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    return o
end

function CW:createChildren()
    ISPanel.createChildren(self)
    self.okButton = button(self, "Clean up this test", GREEN, function() if self.onOk then self.onOk() end end)
    self.okButton:setWidth(300)
    self.okButton:setHeight(48)
    self.okButton:setFont(UIFont.Large)
    self.okButton:setX(math.floor((self.width - 300) / 2))
    self.okButton:setY(math.floor(self.height / 2) + 20)
end

function CW:prerender()
    ISPanel.prerender(self)
    self:drawTextCentre("Trap test finished", self.width / 2, self.height / 2 - 60, 1, 0.95, 0.6, 1, UIFont.Large)
    self:drawTextCentre("Clean up this test to continue playing. It removes everything the test gave you or placed.",
        self.width / 2, self.height / 2 - 20, 0.9, 0.9, 0.9, 1, UIFont.Medium)
end

function CW:onMouseDown() return true end
function CW:onMouseUp() return true end
function CW:onRightMouseDown() return true end
function CW:onMouseWheel() return true end

------------------------------------------------------------
-- Opening and closing
------------------------------------------------------------

local function open(window, onOk, onCancel)
    window.onOk, window.onCancel = onOk, onCancel
    window:initialise()
    window:addToUIManager()
    window:bringToTop()
    return window
end

function UI.ShowRecipe(player, trap, onOk, onCancel)
    return open(RW:new(player, trap), onOk, onCancel)
end

function UI.ShowMessage(spec, onOk, onCancel)
    return open(MW:new(spec), onOk, onCancel)
end

function UI.ShowCleanup(onClean)
    local window = open(CW:new(), onClean)
    pcall(function() window:setAlwaysOnTop(true) end)
    return window
end

function UI.Close(window)
    if window then pcall(function() window:setVisible(false); window:removeFromUIManager() end) end
end

return SVSBTTrapTestUI
