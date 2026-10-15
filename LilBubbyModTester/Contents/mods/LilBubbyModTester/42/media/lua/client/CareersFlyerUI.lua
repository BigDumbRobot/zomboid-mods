require "ISUI/ISCollapsableWindow"
require "ISUI/ISTextEntryBox"
require "ISUI/ISButton"
require "CareersTest_Checks"

-- Fill in your business details and see the flyer as it would be printed
-- before you commit to it. Saving sends the details to the career's own save
-- command, which is what puts the new flyer revision into loot.
CareersFlyerUI = CareersFlyerUI or {}
local U = CareersFlyerUI

-- The flyer as text, in the order it is printed. Used by the preview and by
-- the report, so both say the same thing.
function U.Lines(career, values)
    local lines = { title = tostring(values.name ~= "" and values.name or "(your business name)") }
    lines.subtitle = career.name .. (values.proprietorAlias ~= "" and (" - " .. values.proprietorAlias) or "")
    lines.body = {}
    for _, field in ipairs(CareersTest.FieldsFor(career.id)) do
        if field.key ~= "name" and field.key ~= "proprietorAlias" and values[field.key] ~= "" then
            lines.body[#lines.body + 1] = field.label .. ": " .. values[field.key]
        end
    end
    return lines
end

function U.Missing(career, values)
    local missing = {}
    for _, field in ipairs(CareersTest.FieldsFor(career.id)) do
        if field.required and values[field.key] == "" then missing[#missing + 1] = field.label end
    end
    return missing
end

if not ISCollapsableWindow then return CareersFlyerUI end

U.Window = ISCollapsableWindow:derive("CareersFlyerWindow")
local W = U.Window
local ROW, LABEL = 46, 18

function W:new(player, career, onSave)
    local width, height = 620, math.min(720, getCore():getScreenHeight() - 60)
    local o = ISCollapsableWindow.new(self, math.floor((getCore():getScreenWidth() - width) / 2), 50, width, height)
    o.player, o.career, o.onSave = player, career, onSave
    o.title = career.name .. " flyer"
    o.fields = CareersTest.FieldsFor(career.id)
    o.entries = {}
    o:setResizable(false)
    return o
end

function W:values()
    local values = {}
    for _, field in ipairs(self.fields) do
        local entry = self.entries[field.key]
        values[field.key] = entry and entry:getInternalText() or ""
    end
    return values
end

function W:createChildren()
    ISCollapsableWindow.createChildren(self)
    local y = self:titleBarHeight() + 8
    for _, field in ipairs(self.fields) do
        local entry = ISTextEntryBox:new(field.sample or "", 12, y + LABEL, self.width - 24, 22)
        entry:initialise()
        entry:instantiate()
        entry.onTextChange = function() end
        self:addChild(entry)
        self.entries[field.key] = entry
        y = y + ROW
    end
    self.previewTop = y + 6
    self.saveButton = ISButton:new(self.width - 180, self.height - 34, 168, 24,
        "Save to my " .. self.career.shopWord, self, W.save)
    self.saveButton:initialise()
    self:addChild(self.saveButton)
end

function W:save()
    local values = self:values()
    local missing = CareersFlyerUI.Missing(self.career, values)
    if #missing > 0 then
        self.warning = "Fill in " .. table.concat(missing, " and ") .. " first."
        return
    end
    self.warning = nil
    if self.onSave then self.onSave(values) end
    self:setVisible(false)
    self:removeFromUIManager()
    CareersFlyerUI.window = nil
end

function W:prerender()
    ISCollapsableWindow.prerender(self)
    local y = self:titleBarHeight() + 8
    for _, field in ipairs(self.fields) do
        self:drawText(field.label .. (field.required and " (required)" or ""), 12, y, 0.85, 0.82, 1, 1, UIFont.Small)
        y = y + ROW
    end
    -- The flyer as it would be printed.
    local values = self:values()
    local lines = CareersFlyerUI.Lines(self.career, values)
    local top = self.previewTop
    local height = self.height - top - 46
    self:drawRect(12, top, self.width - 24, height, 0.35, 0.95, 0.92, 0.80)
    self:drawRectBorder(12, top, self.width - 24, height, 0.9, 0.5, 0.42, 0.30)
    local centre = self.width / 2
    self:drawTextCentre(lines.title, centre, top + 12, 0.15, 0.10, 0.05, 1, UIFont.Large)
    self:drawTextCentre(lines.subtitle, centre, top + 44, 0.25, 0.18, 0.10, 1, UIFont.Medium)
    local row = top + 76
    for _, line in ipairs(lines.body) do
        self:drawText(line, 28, row, 0.2, 0.15, 0.1, 1, UIFont.Small)
        row = row + 20
    end
    self:drawTextCentre("Printed flyers reach loot containers after the next server restart.",
        centre, top + height - 22, 0.35, 0.3, 0.25, 1, UIFont.Small)
    if self.warning then
        self:drawText(self.warning, 12, self.height - 30, 1, 0.42, 0.42, 1, UIFont.Small)
    end
end

function U.Show(player, career, onSave)
    if U.window then
        U.window:setVisible(false)
        U.window:removeFromUIManager()
    end
    local window = W:new(player, career, onSave)
    window:initialise()
    window:addToUIManager()
    window:bringToTop()
    U.window = window
    return window
end

return CareersFlyerUI
