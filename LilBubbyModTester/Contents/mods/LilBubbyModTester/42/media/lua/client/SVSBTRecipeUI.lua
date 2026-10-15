require "ISUI/ISCollapsableWindow"

-- A read-only picture of what every Spy vs Spy trap costs: each trap's
-- ingredients with their item icons, how many you carry, and whether your
-- character knows the recipe and has the skills. Nothing is crafted, given
-- or taken: it only reads your inventory.
SVSBTRecipeUI = SVSBTRecipeUI or {}
local U = SVSBTRecipeUI

local function shared() return SVSBT and SVSBT.Shared end

local function recipeOf(recipeName)
    local ok, recipe = pcall(function()
        return ScriptManager.instance:getCraftRecipe(shared().Module .. "." .. recipeName)
    end)
    return ok and recipe or nil
end

local function countOf(player, fullType)
    local ok, n = pcall(function() return player:getInventory():getCountTypeRecurse(fullType) end)
    return ok and n or 0
end

local function scriptItem(fullType)
    local ok, script = pcall(function() return getScriptManager():FindItem(fullType) end)
    return ok and script or nil
end

-- One ingredient line: the item, what it looks like, how many are needed and
-- how many the player carries. Alternatives (nails or screws) are listed once
-- with the others named.
local function inputRow(player, input)
    local possible = input:getPossibleInputItems()
    if not possible or possible:size() == 0 then
        local fluids = input:getPossibleInputFluids()
        if fluids and fluids:size() > 0 then return { name = "a fluid", need = 1, have = 0 } end
        return nil
    end
    local need, have, names = math.max(1, input:getIntAmount()), 0, {}
    for i = 0, possible:size() - 1 do
        local fullType = possible:get(i):getFullName()
        have = have + countOf(player, fullType)
        names[#names + 1] = fullType
    end
    local first = possible:get(0)
    local script = scriptItem(first:getFullName())
    local ok, name = pcall(function() return script and script:getDisplayName() end)
    local row = { fullType = first:getFullName(), name = (ok and name) or first:getFullName(),
        need = need, have = have, script = script }
    local okFluid, fluid = pcall(function()
        if not input:hasConsumeFromItem() then return nil end
        return input:getConsumeFromItemScript():getPossibleInputFluids():get(0):getDisplayName()
    end)
    if okFluid and fluid then row.fluid = fluid end
    if #names > 1 then
        local others = {}
        for i = 2, #names do
            local other = scriptItem(names[i])
            local okOther, otherName = pcall(function() return other and other:getDisplayName() end)
            others[#others + 1] = (okOther and otherName) or names[i]
        end
        row.alternatives = others
    end
    return row
end

-- One trap: its ingredients and whether it can be crafted right now.
function U.Trap(player, kind)
    local S = shared()
    local recipeName = S.KindRecipe[kind]
    local nameOk, kindName = pcall(function() return SVSBT.Client and SVSBT.Client.KindName(kind) end)
    local trap = { kind = kind, name = (nameOk and kindName) or kind, recipeName = recipeName, inputs = {} }
    local recipe = recipeOf(recipeName)
    if not recipe then
        trap.problem = "This recipe is not registered in this build"
        return trap
    end
    local ok, known = pcall(function() return player:getKnownRecipes():contains(recipeName) end)
    trap.known = ok and known == true
    local skillsOk, skills = pcall(function() return recipe:characterHasRequiredSkills(player) end)
    trap.skills = skillsOk and skills == true
    local inputs = recipe:getInputs()
    local missing = false
    for i = 0, inputs:size() - 1 do
        local row = inputRow(player, inputs:get(i))
        if row then
            if row.have < row.need then missing = true end
            trap.inputs[#trap.inputs + 1] = row
        end
    end
    trap.hasItems = not missing
    trap.ready = trap.known and trap.skills and not missing
    return trap
end

-- Everything the panel draws, and the text report of the same thing.
function U.Data(player)
    local S = shared()
    if not S or not S.KindRecipe then return {} end
    local kinds = {}
    for kind in pairs(S.KindRecipe) do kinds[#kinds + 1] = kind end
    table.sort(kinds)
    local traps = {}
    for _, kind in ipairs(kinds) do traps[#traps + 1] = U.Trap(player, kind) end
    return traps
end

-- "Bucket (full of Water)", "Nails (or Screws)"
function U.RowLabel(row)
    return row.name .. (row.fluid and (" (full of " .. row.fluid .. ")") or "")
        .. (row.alternatives and (" (or " .. table.concat(row.alternatives, ", ") .. ")") or "")
end

-- The same information as text, for the report and the full run.
function U.Text(player)
    local lines = { "What every Spy vs Spy trap costs (your inventory is only read, never changed)." }
    for _, trap in ipairs(U.Data(player)) do
        if trap.problem then
            lines[#lines + 1] = "SKIP: " .. trap.name .. ": " .. trap.problem
        else
            local parts = {}
            for _, row in ipairs(trap.inputs) do
                parts[#parts + 1] = row.have .. "/" .. row.need .. " " .. row.name
            end
            lines[#lines + 1] = (trap.ready and "READY: " or "INFO: ") .. trap.name .. ": "
                .. table.concat(parts, ", ")
                .. " | recipe known=" .. tostring(trap.known) .. " skills=" .. tostring(trap.skills)
        end
    end
    lines[#lines + 1] = "READY means you could craft it right now. Nothing here crafts anything."
    return table.concat(lines, "\n")
end

if not ISCollapsableWindow then return SVSBTRecipeUI end

U.Window = ISCollapsableWindow:derive("SVSBTRecipeWindow")
local W = U.Window
local ROW, HEADER = 40, 34

function W:new(player)
    local width, height = 560, math.min(680, getCore():getScreenHeight() - 80)
    local o = ISCollapsableWindow.new(self, math.floor((getCore():getScreenWidth() - width) / 2), 60, width, height)
    o.player = player
    o.scroll = 0
    o.title = "Spy vs Spy: what each trap costs"
    o:setResizable(false)
    return o
end

function W:refresh()
    self.traps = SVSBTRecipeUI.Data(self.player)
end

function W:onMouseWheel(delta)
    self.scroll = math.max(0, self.scroll + delta * ROW)
    return true
end

function U.DrawIcon(self, row, x, y, size)
    size = size or 32
    local texture
    if row.script then
        local ok, found = pcall(function() return row.script:getNormalTexture() end)
        texture = ok and found or nil
        if not texture then
            local okIcon, icon = pcall(function() return row.script:getIcon() end)
            if okIcon and icon then
                local okTex, fromName = pcall(function() return getTexture("Item_" .. icon) end)
                texture = okTex and fromName or nil
            end
        end
    end
    if texture then self:drawTextureScaled(texture, x, y, size, size, 1, 1, 1, 1)
    else self:drawRectBorder(x, y, size, size, 0.5, 0.7, 0.7, 0.7) end
end

function W:prerender()
    ISCollapsableWindow.prerender(self)
    if not self.traps then self:refresh() end
    local y = self:titleBarHeight() + 8 - self.scroll
    local bottom = self.height - 8
    self:drawText("Read-only: this only looks at your inventory.", 12, self:titleBarHeight() + 8, 0.7, 0.7, 0.7, 1, UIFont.Small)
    y = y + 20
    for _, trap in ipairs(self.traps) do
        if y > self:titleBarHeight() and y < bottom then
            local state, r, g, b = "Ready to craft", 0.45, 0.88, 0.45
            if trap.problem then state, r, g, b = trap.problem, 0.62, 0.62, 0.62
            elseif not trap.known then state, r, g, b = "Recipe unknown: read the magazine", 0.98, 0.76, 0.30
            elseif not trap.skills then state, r, g, b = "Skills too low", 0.98, 0.76, 0.30
            elseif not trap.hasItems then state, r, g, b = "Missing items", 1, 0.42, 0.42 end
            self:drawText(trap.name, 12, y, 0.9, 0.85, 1, 1, UIFont.Medium)
            self:drawTextRight(state, self.width - 12, y, r, g, b, 1, UIFont.Small)
            self:drawRect(12, y + HEADER - 8, self.width - 24, 1, 0.3, 1, 1, 1)
        end
        y = y + HEADER
        for _, row in ipairs(trap.inputs) do
            if y > self:titleBarHeight() and y < bottom then
                U.DrawIcon(self, row, 24, y)
                local enough = row.have >= row.need
                self:drawText(U.RowLabel(row),
                    64, y + 8, 0.9, 0.9, 0.9, 1, UIFont.Small)
                self:drawTextRight(row.have .. " / " .. row.need, self.width - 12, y + 8,
                    enough and 0.45 or 1, enough and 0.88 or 0.42, enough and 0.45 or 0.42, 1, UIFont.Medium)
            end
            y = y + ROW
        end
        y = y + 8
    end
    self.contentHeight = y + self.scroll
end

function U.Show(player)
    local window = U.window
    if not window then
        window = W:new(player)
        window:initialise()
        window:addToUIManager()
        U.window = window
    end
    window.player = player
    window:refresh()
    window:setVisible(true)
    window:bringToTop()
    return window
end

return SVSBTRecipeUI
