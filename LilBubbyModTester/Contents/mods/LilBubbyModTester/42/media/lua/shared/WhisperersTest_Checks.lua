-- Helpers shared by The Whisperers suite's client and server halves.
-- The Whisperers is optional for this tester, so its globals are read at call time.
WhisperersTest = WhisperersTest or {}

WhisperersTest.MODULE = "LilBubbyWhisperersTest"
WhisperersTest.MARKER = "LilBubbyWhisperersTest"   -- modData tag on every item and corpse the test creates
WhisperersTest.MIN_BUTCHERING = 3                  -- skin suits need 3
WhisperersTest.MIN_TAILORING = 5                   -- mask repair needs 5

-- Whisperers.Client comes from the mod's client folder, which a dedicated
-- server never loads, so only clients (and single player) look for it.
function WhisperersTest.available()
    return Whisperers ~= nil and Whisperers.Gear ~= nil
        and (isServer() or Whisperers.Client ~= nil)
        and Whisp_RemoveHeadAction ~= nil and Whisp_SkinCorpseAction ~= nil
end

-- Guts from one corpse: floor(base + skill * perLevel + luck), luck in [0, 1).
function WhisperersTest.gutsRange(skill, base, perLevel)
    local yield = base + skill * perLevel
    return math.max(1, math.floor(yield)), math.max(1, math.floor(yield + 0.999))
end

-- Condition a mask should have: face quality, less the nail's share.
function WhisperersTest.maskCondition(quality, nail, nailDamage)
    local cond = 100 * quality
    if nail then cond = cond * (1 - nailDamage / 100) end
    return math.max(1, math.floor(cond + 0.5))
end

-- What a placed head stake looks like from where this runs: the server's view
-- and each client's view must match in multiplayer.
function WhisperersTest.describeStake(obj)
    local hv = obj:getHumanVisual()
    local worn, list = {}, obj:getWornItems()
    for i = 0, list:size() - 1 do
        local item = list:getItemByIndex(i)
        if item then worn[#worn + 1] = item:getFullType() end
    end
    table.sort(worn)
    local sq = obj:getSquare()
    return {
        script = obj:getMannequinScriptName(),
        hair = hv and hv:getHairModel() or nil,
        beard = hv and hv:getBeardModel() or nil,
        worn = table.concat(worn, ","),
        solid = sq ~= nil and (sq:isSolidTrans() or sq:isSolid()),
    }
end

-- "" when two stake descriptions match, else which fields differ.
function WhisperersTest.stakeDiff(a, b)
    local diff = {}
    for _, key in ipairs({ "script", "hair", "beard", "worn", "solid" }) do
        if tostring(a[key]) ~= tostring(b[key]) then
            diff[#diff + 1] = key .. " " .. tostring(a[key]) .. " vs " .. tostring(b[key])
        end
    end
    return table.concat(diff, "; ")
end

-- Zombie mannerisms: the clip each movement should play in a full disguise
-- (media/AnimSets/player/*/Whisp_Zombie*.xml in The Whisperers).
WhisperersTest.GAIT_CLIPS = {
    idle = "Zombie_Idle", walk = "Zombie_Walk", sneakWalk = "Zombie_Walk", run = "Zombie_Lunge",
    sneakRun = "Zombie_Walk4", sprint = "Zombie_Sprint", sit = "Zombie_IdleAgainstWall",
}

function WhisperersTest.isZombieClip(name)
    return type(name) == "string" and name:sub(1, 7) == "Zombie_"
end

-- The name counted most often in a tally of { [name] = count }, and its share.
function WhisperersTest.dominant(tally)
    local best, most, total = nil, 0, 0
    for name, n in pairs(tally) do
        total = total + n
        if n > most or (n == most and best and name < best) then best, most = name, n end
    end
    return best, total > 0 and most / total or 0
end

local Report = {}
Report.__index = Report

function WhisperersTest.newReport(title)
    return setmetatable({ title = title, lines = {}, passed = 0, failed = 0 }, Report)
end

function Report:add(status, name, detail)
    self.lines[#self.lines + 1] = status .. " | " .. name .. (detail ~= nil and (" | " .. tostring(detail)) or "")
    print("[" .. WhisperersTest.MODULE .. "] " .. self.lines[#self.lines])
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

return WhisperersTest
