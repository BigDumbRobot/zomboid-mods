-- Dynamic Events suite: helpers shared by the client and server halves.
-- Dynamic Events is optional for the tester, so its globals are read when
-- called, never at load.
DynamicEventsTest = DynamicEventsTest or {}
local T = DynamicEventsTest

T.MODULE = "LilBubbyDynamicEventsTest"   -- command module and log prefix
T.MARKER = "LilBubbyDynamicEventsTest"   -- modData tag on items the test gives
T.PREFIX = "[LilBubby Test] "            -- name prefix of every event the test makes

function T.available()
    return KIPN ~= nil and KIPN.Shared ~= nil and KIPN.Shared.EventModes ~= nil
        and KIPN.Shared.EventModes.OLYMPICS ~= nil
end

local Report = {}
Report.__index = Report

function T.newReport(title)
    return setmetatable({ title = title, lines = {}, passed = 0, failed = 0 }, Report)
end

function Report:add(status, name, detail)
    self.lines[#self.lines + 1] = status .. " | " .. name .. (detail ~= nil and (" | " .. tostring(detail)) or "")
    print("[" .. T.MODULE .. "] " .. self.lines[#self.lines])
end

function Report:check(name, condition, detail)
    condition = condition and true or false
    if condition then self.passed = self.passed + 1 else self.failed = self.failed + 1 end
    self:add(condition and "PASS" or "FAIL", name, detail)
    return condition
end

function Report:info(name, detail) self:add("INFO", name, detail) end
function Report:skip(name, detail) self:add("SKIP", name, detail) end
function Report:blocked(name, detail) self.failed = self.failed + 1; self:add("BLOCKED", name, detail) end

function Report:error(name, detail)
    self.failed = self.failed + 1
    self:add("ERROR", name, detail)
end

-- Lines a server op produced ({ status, name, detail }), folded in.
function Report:merge(lines)
    for _, line in ipairs(lines or {}) do
        if line[1] == "PASS" or line[1] == "FAIL" then self:check(line[2], line[1] == "PASS", line[3])
        elseif line[1] == "SKIP" then self:skip(line[2], line[3])
        elseif line[1] == "BLOCKED" then self:blocked(line[2], line[3])
        else self:info(line[2], line[3]) end
    end
end

function Report:text()
    return self.title .. ": " .. (self.failed == 0 and "PASS" or "FAIL") .. " (" .. self.passed .. " passed, "
        .. self.failed .. " failed)\n" .. table.concat(self.lines, "\n")
end

-- The event settings every test event starts from; each test changes a few.
function T.BaseDefinition(name)
    return {
        name = T.PREFIX .. name,
        eventType = "HORDE_SURVIVAL",
        mode = "NONE",
        scenarioPresetId = "CUSTOM",
        scopeType = "OPEN_MAP",
        maxRounds = 1,
        spawnRules = { baseSpawnRadius = 40, escalationEnabled = false },
        directorType = "ZOMBIE_WAVES",
        zombieTheme = { themeId = "RANDOM" },
        environment = {},
        ruleType = "PVE",
        combatRules = { allowLeaveZone = true, pvpAllowedInZone = false },
        timerType = "NONE",
        duration = { enabled = false, durationSeconds = 0, expiryBehavior = "WIN" },
        roundDuration = { enabled = false, durationSeconds = 0 },
        objectiveTypes = { "SURVIVE" },
        outcomeTypes = { "LAST_ALIVE" },
        objectives = {},
        objectiveNotes = {},
        winConditions = {},
        failConditions = {},
        rewardDeliveryMethod = "ADMIN_DELIVERY",
        rewardItems = {},
        narrative = { briefing = "", winText = "", failText = "" },
        modifiers = { NAKED_AND_AFRAID = false },
        captureConfig = { flagItemFullType = "", autoReturnSeconds = 90 },
        loadout = "NONE",
        difficulty = "NORMAL",
        threats = { SIEGE = false, FIRES = false, ALARM = false },
        survivorConfig = { lastStanding = false },
        olympicsConfig = { heatSize = 1, heatLimitSeconds = 300, discipline = "OBSTACLE" },
    }
end

-- Every feature, in the order the Showcase lists them. side: where it runs.
-- site = "event": the event uses the designated event zone, and the showcase
-- moves the player into it first.
T.Features = {
    { id = "services", group = "Setup", label = "Check the event services are running", side = "server" },
    { id = "items", group = "Setup", label = "Check every loadout, kit and course item exists", side = "server" },
    { id = "studio_logic", group = "Event Studio", label = "Check the Studio's checklist, defaults and templates", side = "client" },
    { id = "studio_window", group = "Event Studio", label = "Open the Event Studio and walk every step", side = "client" },
    { id = "lifecycle", group = "Running events", label = "Run an event from draft to finished (sign up, begin, stop, reset)", side = "flow", site = "event" },
    { id = "validation", group = "Running events", label = "Check validation says what is missing", side = "server" },
    { id = "director", group = "Running events", label = "Use the Director controls on a live event", side = "flow" },
    { id = "rewards", group = "Running events", label = "Win a prize and mark it delivered", side = "flow" },
    { id = "capture", group = "Game modes", label = "Capture the Flag: grab the flag and deliver it", side = "flow" },
    { id = "ctf", group = "Game modes", label = "Team Capture the Flag: steal the enemy flag", side = "flow" },
    { id = "koth", group = "Game modes", label = "King of the Hill: hold the hill for a round", side = "flow" },
    { id = "chase", group = "Game modes", label = "Chase: be the target and survive a round", side = "flow" },
    { id = "extraction", group = "Game modes", label = "Extraction: hold out, then reach the evac", side = "flow" },
    { id = "prison", group = "Game modes", label = "Prison Break: search the spot, then escape", side = "flow" },
    { id = "firesale", group = "Game modes", label = "Fire Sale: one exit is clear, the rest are swarmed", side = "flow" },
    { id = "survivor", group = "Game modes", label = "Survivor Run: stay alive until the clock runs out", side = "flow" },
    { id = "laststanding", group = "Game modes", label = "Dodgeball: last one standing wins", side = "server" },
    { id = "adventure", group = "Game modes", label = "Adventure: roll every game and put it back", side = "server", site = "event" },
    { id = "olympics", group = "Game modes", label = "The Olympics: race the full obstacle course", side = "flow" },
    { id = "loadouts", group = "Players", label = "Start with each loadout and get your gear back", side = "flow" },
    { id = "clues", group = "Players", label = "Find a clue and replay it from the HUD", side = "flow" },
    { id = "hud_fade", group = "Players", label = "Check the HUD fades and comes back", side = "client" },
    { id = "difficulty", group = "Threats", label = "Roll the difficulty 2000 times", side = "server" },
    { id = "threats", group = "Threats", label = "Siege, alarm and ambush on a live event", side = "flow" },
    { id = "fire", group = "Threats", label = "Start a test fire nearby and put it out", side = "server" },
    { id = "classics", group = "Classic scenarios", label = "Apply every classic scenario in the Studio", side = "client" },
    { id = "move", group = "Players", label = "Get moved by an event (a short jump and a long hop)", side = "flow" },
    { id = "bandits", group = "Bandits", label = "Bandit camp: calm until you come close, then they fight", side = "flow" },
    { id = "raid", group = "Bandits", label = "Bandit raid: a crew arrives and comes for you", side = "flow" },
    { id = "heist", group = "Bandits", label = "The Heist: take the gold from the getaway car to the pickup", side = "flow" },
    { id = "quickstart", group = "Prepared events", label = "Start <event>: sign-ups, countdown, begin", side = "flow" },
    { id = "cancel", group = "Prepared events", label = "Cancel <event> from every stage", side = "flow" },
    { id = "announce", group = "Prepared events", label = "Announcements for <event>", side = "flow" },
    { id = "simsteps", group = "Prepared events", label = "Check a simulation covers every part, in play order", side = "server" },
    { id = "simulate", group = "Prepared events", label = "Simulate <event>: every step with OK", side = "flow" },
    { id = "simulate_edit", group = "Prepared events", label = "Simulate: Edit, change the event, Resume", side = "flow" },
    { id = "simulate_cancel", group = "Prepared events", label = "Simulate: Cancel leaves nothing behind", side = "flow" },
    { id = "simulate_invite", group = "Prepared events", label = "Simulation invitation: OK joins, Cancel opts out, Leave", side = "flow" },
    { id = "access", group = "Prepared events", label = "Check who may use the Studio and join simulations (sandbox)", side = "server" },
}
-- One visit per classic scenario's original location.
T.VISIT_GROUP = "Classic scenario locations"

function T.Feature(id)
    for _, feature in ipairs(T.Features) do if feature.id == id then return feature end end
end

-- Distance in tiles.
function T.Distance(ax, ay, bx, by)
    return math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))
end

return DynamicEventsTest
