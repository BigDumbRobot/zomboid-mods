-- Helpers shared by the Skylights suite's client and server halves.
-- Skylights is optional for this tester, so its globals are read at call time.
SkylightsTest = SkylightsTest or {}

SkylightsTest.MODULE = "LilBubbySkylightsTest"
SkylightsTest.ROOM = 5              -- room is ROOM x ROOM tiles, roofed at z=1
SkylightsTest.DEPTH = 9             -- the stairs south of the room reach y0 + DEPTH
SkylightsTest.SEARCH_RADIUS = 40    -- tiles searched around the player for a clear site
SkylightsTest.MARKER = "LilBubbySkylightsTestRoom"

function SkylightsTest.available()
    return SkylightsConfig ~= nil and SkylightsDaylight ~= nil and SkylightsGlass ~= nil
        and SkylightsConfig.indoorBrightness ~= nil
end

local Report = {}
Report.__index = Report

function SkylightsTest.newReport(title)
    return setmetatable({ title = title, lines = {}, passed = 0, failed = 0 }, Report)
end

function Report:add(status, name, detail)
    self.lines[#self.lines + 1] = status .. " | " .. name .. (detail and (" | " .. tostring(detail)) or "")
    print("[" .. SkylightsTest.MODULE .. "] " .. self.lines[#self.lines])
end

function Report:check(name, condition, detail)
    if condition then self.passed = self.passed + 1 else self.failed = self.failed + 1 end
    self:add(condition and "PASS" or "FAIL", name, detail)
    return condition
end

function Report:info(name, detail)
    self:add("INFO", name, detail)
end

function Report:error(name, detail)
    self.failed = self.failed + 1
    self:add("ERROR", name, detail)
end

function Report:text()
    local verdict = self.failed == 0 and "PASS" or "FAIL"
    return self.title .. ": " .. verdict .. " (" .. self.passed .. " passed, " .. self.failed .. " failed)\n"
        .. table.concat(self.lines, "\n")
end
