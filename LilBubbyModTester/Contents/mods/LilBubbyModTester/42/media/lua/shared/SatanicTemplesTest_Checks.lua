-- Helpers shared by the Satanic Temples suite's client and server halves.
-- Satanic Temples is optional for this tester, so its globals are read at call time.
SatanicTemplesTest = SatanicTemplesTest or {}

SatanicTemplesTest.MODULE = "LilBubbySatanicTemplesTest"
SatanicTemplesTest.MARKER = "LilBubbySatanicTemplesTest"   -- modData tag on every corpse the test creates
SatanicTemplesTest.TEMPLE_NAME = "LilBubby Test Temple"     -- the only temple the suite creates or deletes
SatanicTemplesTest.PERK = "Woodwork"                         -- the skill used to measure lost and restored XP
SatanicTemplesTest.VICTIM = "user:lilbubbytestvictim"        -- stand-in owner for "another player's corpse"

-- The server half (SO.ZoneService) exists on servers and in single player; the
-- client half (SO.Client, the ritual action) on clients and in single player.
function SatanicTemplesTest.available()
    local SO = SacrificialOffering
    if not SO then return false end
    if isServer() then return SO.ZoneService ~= nil and SO.OfferingService ~= nil end
    return SO.Client ~= nil and SO_OfferingRitualAction ~= nil
end

local Report = {}
Report.__index = Report

function SatanicTemplesTest.newReport(title)
    return setmetatable({ title = title, lines = {}, passed = 0, failed = 0 }, Report)
end

function Report:add(status, name, detail)
    self.lines[#self.lines + 1] = status .. " | " .. name .. (detail ~= nil and (" | " .. tostring(detail)) or "")
    print("[" .. SatanicTemplesTest.MODULE .. "] " .. self.lines[#self.lines])
end

function Report:check(name, condition, detail)
    condition = condition and true or false
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

return SatanicTemplesTest
