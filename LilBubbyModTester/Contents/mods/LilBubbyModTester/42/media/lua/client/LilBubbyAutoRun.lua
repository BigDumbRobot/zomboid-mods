require "LilBubbyShowcase"
require "LilBubbyPrep"
require "LilBubbyTeleport"
require "TimedActions/ISReadABook"

-- Run every test: prepares the character (skills, literature read with the
-- real read action), then starts every feature of every enabled suite one at
-- a time through the showcase's own Run path, waits for each result and ends
-- with a summary. Progress streams to the Test Console so it can be watched.
LilBubbyAutoRun = LilBubbyAutoRun or {}
local R = LilBubbyAutoRun
local S = LilBubbyShowcase
local P = LilBubbyPrep
local ID = "all"

-- Suites run in this order. The Satanic Temples and Dead Man's Map suites
-- kill the character (and respawn it), so they go last.
R.ORDER = { "compat", "spy", "government", "vehicle", "postal", "skylights", "whisperers", "events", "bonk", "satanic", "dmm" }
-- "Visit ": Dynamic Events' location visits can cross the whole map; run them by hand.
-- "Guided post office test": every step waits for the player to do it and click OK.
R.SKIP = { "Show last result", "How these tests work", "Cancel running test", "Run every automatic check", "Visit ",
    "Guided post office test" }
R.DEFAULT_MS = 180000
R.TIMEOUTS = {
    { "30 times per weapon", 600000 }, { "Every loaded ranged weapon", 600000 },
    { "Run full Whisperers test", 1200000 }, { "Test zombie mannerisms", 600000 }, { "Craft 10 head stakes", 6600000 }, { "death test", 1200000 },
    { "Periodic metadata resync", 150000 }, { "Seat ejection", 90000 }, { "Vehicle claim lifecycle", 900000 },
    { "Run the full Satanic Temples test", 900000 }, { "Die and recover at the altar", 900000 },
    { "Start with each loadout", 900000 }, { "Siege, alarm and ambush", 420000 }, { "race the full obstacle course", 300000 },
    { "hold out, then reach the evac", 240000 }, { "Run an event from draft", 240000 }, { "Open the Event Studio", 300000 },
}

local run -- the active run, if any
local prepReply

------------------------------------------------------------
-- WAITING
------------------------------------------------------------

local function now() return getTimestampMs() end
local function waitFor(ms, fn, what)
    local deadline = now() + ms
    -- what: shown in the status banner while this wait lasts.
    local previous = LilBubbyStatus and LilBubbyStatus.notes[0]
    if what and LilBubbyStatus then LilBubbyStatus.Note(0, what) end
    local value
    while true do
        value = fn()
        if value or now() > deadline or (run and run.stopped) then break end
        coroutine.yield()
    end
    if what and LilBubbyStatus then LilBubbyStatus.notes[0] = previous end -- a wait inside another keeps the outer note
    return value or nil
end

-- Kahlua cannot yield across pcall, so a step that waits is isolated in its
-- own coroutine instead: an error ends that coroutine, not the whole run.
local function protected(fn, ...)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co, ...)
    while ok and coroutine.status(co) ~= "dead" do
        coroutine.yield()
        ok, err = coroutine.resume(co)
    end
    if ok then return true end
    return false, err
end
local function me() return getSpecificPlayer(run.playerNum) end

local function say(text, progress)
    local player = me()
    print("[LilBubbyAutoRun] " .. text)
    if player then S.Report(player, ID, text, progress ~= false) else S.ReportIndex(run.playerNum, ID, text, progress ~= false) end
end

S.OnReport(function(index, id, text, progress)
    local wait = run and run.waiting
    if not wait or index ~= run.playerNum or id ~= wait.id then return end
    wait.any = wait.any or text
    if not progress and not wait.result then wait.result = text end
    if wait.onProgress and progress then pcall(wait.onProgress, text) end
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= P.MODULE or command ~= "reply" or type(args) ~= "table" then return end
    if run and me() and args.playerID == me():getOnlineID() then prepReply = args end
end)

------------------------------------------------------------
-- RESULTS
------------------------------------------------------------

function R.Classify(text)
    local counts, issue, header = {}, nil, nil
    for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
        local status = line:match("^%s*(%u+):") or line:match("^%s*(%u+) |")
            or line:match(": (%u+) %(%d+ passed") -- "Skylights near me: PASS (3 passed, 0 failed)"
        local verdictLine = line:find("| FAILED", 1, true) ~= nil or line:find(": FAIL (", 1, true) ~= nil
        if line:find("ATTEMPT FAILED", 1, true) or verdictLine then status = "FAIL" end
        if line:find("| PASSED", 1, true) then status = status or "PASS" end
        if status then
            counts[status] = (counts[status] or 0) + 1
            if status == "FAIL" or status == "ERROR" or status == "BLOCKED" or status == "ABORTED" then
                -- Prefer the specific check line over the report's verdict header.
                if verdictLine then header = header or line else issue = issue or line end
            end
        end
    end
    issue = issue or header
    local verdict = "INFO"
    if (counts.FAIL or 0) + (counts.ERROR or 0) > 0 then verdict = "FAIL"
    elseif (counts.BLOCKED or 0) + (counts.ABORTED or 0) > 0 then verdict = "BLOCKED"
    elseif (counts.PASS or 0) + (counts.READY or 0) + (counts.CANCELLED or 0) > 0 then verdict = "PASS"
    elseif (counts.SKIP or 0) > 0 then verdict = "SKIP" end
    return verdict, issue
end

local function record(suite, name, verdict, detail)
    run.results[#run.results + 1] = { suite = suite, name = name, verdict = verdict, detail = detail }
    run.counts[verdict] = (run.counts[verdict] or 0) + 1
    say(verdict .. ": " .. suite .. " / " .. name .. (detail and (" -- " .. detail) or ""), false)
end

local function summary(r)
    r = r or run
    local order = { "PASS", "FAIL", "BLOCKED", "SKIP", "TIMEOUT", "INFO" }
    local totals = {}
    for _, verdict in ipairs(order) do
        if r.counts[verdict] then totals[#totals + 1] = verdict .. " " .. r.counts[verdict] end
    end
    local lines = { "Run every test | " .. (r.stopped and "STOPPED" or "FINISHED") .. " | " .. table.concat(totals, ", ") }
    for _, result in ipairs(r.results) do
        if result.verdict ~= "PASS" then
            local status = result.verdict == "TIMEOUT" and "FAIL" or result.verdict
            lines[#lines + 1] = status .. ": " .. result.suite .. " / " .. result.name .. (result.detail and (" -- " .. result.detail) or "")
        end
    end
    lines[#lines + 1] = "Passed: " .. (r.counts.PASS or 0) .. " features. Open each suite for its full reports."
    return table.concat(lines, "\n")
end

------------------------------------------------------------
-- PREPARATION
------------------------------------------------------------

local function ask(command, args)
    if not isClient() then
        local fn = command == "grant" and P.Grant or command == "tidy" and P.Tidy
            or function(player) return P.Teach(player, args.recipes) end
        return fn(me())
    end
    prepReply = nil
    sendClientCommand(me(), P.MODULE, command, args or {})
    return waitFor(20000, function() return prepReply and prepReply.op == command and prepReply end,
        "Waiting for the server to " .. (command == "grant" and "raise your skills and hand out literature"
            or command == "teach" and "teach the remaining recipes" or "take back the literature"))
end

local function unknownRecipes()
    local unknown = {}
    for _, recipe in ipairs(P.Recipes()) do
        if not P.Knows(me(), recipe) then unknown[#unknown + 1] = recipe end
    end
    return unknown
end

local function queueEmpty()
    local queue = ISTimedActionQueue.getTimedActionQueue(me())
    return not queue or not queue.queue or #queue.queue == 0
end

function R.Prepare()
    local needs = P.Needs()
    if #needs == 0 then say("Preparation: no enabled mod needs extra skills or literature.", false); return end
    say("Preparing your character: raising skills and handing out literature")
    local grant = ask("grant", {})
    if not grant or grant.error then
        record("Preparation", "Skills and literature", "FAIL", grant and grant.error or "no reply from the server in 20 s")
        return
    end
    for _, change in ipairs(grant.perks or {}) do
        say("Skill " .. change.perk .. ": " .. tostring(change.from) .. " -> " .. tostring(change.to))
    end
    local items = grant.items or {}
    local reading = 0
    if #items > 0 then
        if me():tooDarkToRead() then
            say("Too dark to read here; the recipes will be taught directly instead.")
        else
            for _, entry in ipairs(items) do
                local item = waitFor(10000, function() return me():getInventory():getItemWithID(entry.id) end,
                    "Waiting for the literature to reach your inventory")
                if item then
                    ISTimedActionQueue.add(ISReadABook:new(me(), item))
                    reading = reading + 1
                end
            end
            say("Reading " .. reading .. " item(s) of literature: watch your character read each one")
            waitFor(900000, queueEmpty)
        end
    end
    local unknown = unknownRecipes()
    if #unknown > 0 then
        say(#unknown .. " recipe(s) still unknown after reading; teaching them directly")
        local taught = ask("teach", { recipes = unknown })
        waitFor(5000, function() return #unknownRecipes() == 0 end, "Waiting for the taught recipes to reach your character")
        unknown = unknownRecipes()
        if taught and taught.error then say("Teaching failed: " .. taught.error, false) end
    end
    ask("tidy", {})
    local recipes = #P.Recipes()
    if #unknown == 0 then
        record("Preparation", "Skills level " .. P.LEVEL .. ", " .. recipes .. " recipes known (" .. reading .. " read)", "PASS")
    else
        record("Preparation", "Recipe knowledge", "FAIL", "still unknown: " .. table.concat(unknown, ", "))
    end
end

------------------------------------------------------------
-- RUNNING SUITES
------------------------------------------------------------

local function skipped(entry)
    if run.only then return entry.name:find(run.only, 1, true) == nil end
    for _, text in ipairs(R.SKIP) do
        if entry.name:find(text, 1, true) then return true end
    end
    return entry.path:find("Choose a Bonk Zone", 1, true) ~= nil
end

local function timeoutFor(entry)
    for _, pair in ipairs(R.TIMEOUTS) do
        if entry.key:find(pair[1], 1, true) then return pair[2] end
    end
    return R.DEFAULT_MS
end

local function nearestVehicle(player)
    if player:getVehicle() then return player:getVehicle() end
    local best, bestDistance = nil, 12
    -- A HashSet in Build 42: walk it with an iterator (get(i) is unavailable).
    local iterator = getCell():getVehicles():iterator()
    while iterator:hasNext() do
        local vehicle = iterator:next()
        local distance = vehicle:DistTo(player)
        if distance < bestDistance then best, bestDistance = vehicle, distance end
    end
    return best
end

-- Tests that ask the player to do something are done for them.
local ASSISTS = {
    ["Seat ejection"] = function(text)
        if not text:find("get into", 1, true) then return end
        local player = me()
        local vehicle = nearestVehicle(player)
        if vehicle and not player:getVehicle() then
            require "Vehicles/TimedActions/ISEnterVehicle"
            ISTimedActionQueue.add(ISEnterVehicle:new(player, vehicle, 0))
            say("Getting into the vehicle for you")
        end
    end,
}

-- Features whose first reply (even a notice) ends them.
local function firstReplyEnds(entry)
    return entry.name:find("Teleport me", 1, true) or entry.name:find("Return to where", 1, true)
        or entry.name:find("test zone", 1, true)
end

local function runEntry(mod, entry)
    local entries, notes = S.Build(me(), mod.id)
    local current
    for _, candidate in ipairs(entries) do if candidate.key == entry.key then current = candidate end end
    if not current then record(mod.name, entry.name, "SKIP", "no longer offered"); return end
    if current.notAvailable then
        record(mod.name, entry.name, "SKIP", current.unavailableReason or "needs a target nearby (see the suite's instructions)")
        return
    end
    say("Running " .. mod.name .. " / " .. entry.name)
    local wait = { id = mod.id }
    for pattern, assist in pairs(ASSISTS) do
        if entry.name:find(pattern, 1, true) then wait.onProgress = assist end
    end
    run.waiting = wait
    local ok, err = S.Run(me(), mod.id, current, notes)
    if not ok then
        run.waiting = nil
        record(mod.name, entry.name, "FAIL", "could not start: " .. tostring(err))
        return
    end
    -- The move to a designated zone is not part of the feature's time limit.
    waitFor(600000, function() return not (LilBubbySites and LilBubbySites.Moving(me())) end, "Travelling to the test zone")
    local quick = firstReplyEnds(entry)
    local text = waitFor(timeoutFor(entry), function()
        return wait.result or (quick and wait.any) or nil
    end)
    run.waiting = nil
    if quick and text then
        waitFor(600000, function() return not LilBubbyTeleport.Travelling(me()) end, "Finishing the move back")
    end
    if not text then
        record(mod.name, entry.name, run.stopped and "SKIP" or "TIMEOUT", run.stopped and "run stopped" or "no result in " .. math.floor(timeoutFor(entry) / 1000) .. " s")
        return
    end
    local verdict, issue = R.Classify(text)
    if quick and verdict == "INFO" then verdict = "PASS" end
    record(mod.name, entry.name, verdict, verdict ~= "PASS" and (issue or text:match("^[^\n]*")) or nil)
end

local function bonkZones()
    return BonkZone and BonkZone.Registry and BonkZone.Registry.GetZones and BonkZone.Registry.GetZones() or {}
end

function R.RunSuite(mod)
    say("== " .. mod.name .. " ==")
    local entries = S.Build(me(), mod.id)
    local main, cleanup = {}, {}
    for _, entry in ipairs(entries) do
        if not skipped(entry) then
            local isCleanup = entry.name:find("Clean up", 1, true) == 1 or entry.name:find("Return to where", 1, true) == 1
            if mod.id == "bonk" and entry.name:find("designated test zone", 1, true) then
                -- First, so the shot tests run inside the designated zone.
                table.insert(main, 1, entry)
            elseif isCleanup then
                table.insert(cleanup, 1, entry)
            else
                main[#main + 1] = entry
            end
        end
    end
    if #main + #cleanup == 0 then record(mod.name, "Suite", "SKIP", "no features offered here") return end
    for _, list in ipairs({ main, cleanup }) do
        for _, entry in ipairs(list) do
            if run.stopped then return end
            local ok, err = protected(runEntry, mod, entry)
            if not ok then record(mod.name, entry.name, "FAIL", "runner error: " .. tostring(err)) end
            coroutine.yield() -- one tick between tests; the server queues requests itself
        end
    end
end

local function flow(options)
    say("Run every test: started. Follow along in the Test Console.")
    if options.prepare ~= false then
        local ok, err = protected(R.Prepare)
        if not ok then record("Preparation", "Skills and literature", "FAIL", tostring(err)) end
    end
    if not options.prepareOnly then
        for _, id in ipairs(R.ORDER) do
            local mod = S.ModById(id)
            if run.stopped then break end
            if mod and S.Installed(mod) then R.RunSuite(mod) end
        end
    end
    return summary()
end

------------------------------------------------------------
-- DRIVER
------------------------------------------------------------

local function step()
    if not run then return end
    local ok, result = coroutine.resume(run.co)
    if not ok or coroutine.status(run.co) == "dead" then
        local finished = run
        run = nil
        local text = ok and result or ("Run every test | ERROR\nERROR: " .. tostring(result) .. "\n" .. summary(finished))
        print("[LilBubbyAutoRun] " .. text:gsub("\n", " | "))
        S.ReportIndex(finished.playerNum, ID, text, false)
    end
end

function R.Running() return run ~= nil end

function R.Start(player, options)
    if run then S.Report(player, ID, "A run is already in progress. Use Stop the run first.", false); return end
    -- Progress goes to the small corner strip, not a window over the world.
    pcall(function()
        require "LilBubbyMiniUI"
        LilBubbyMiniUI.Show(player:getPlayerNum())
        local showcase = S.windows[player:getPlayerNum()]
        if showcase then showcase:setVisible(false) end
    end)
    run = { co = coroutine.create(flow), playerNum = player:getPlayerNum(), results = {}, counts = {},
        only = options and options.only or nil }
    local ok, result = coroutine.resume(run.co, options or {})
    if not ok or coroutine.status(run.co) == "dead" then
        local finished = run
        run = nil
        S.ReportIndex(finished.playerNum, ID, ok and result or ("ERROR: " .. tostring(result)), false)
    end
end

function R.Stop(player)
    if not run then S.Report(player, ID, "No run is in progress.", false); return end
    run.stopped = true
    say("Stopping after the current test.")
end

-- Unattended start: write "run", "prepare" or "noprep" into Zomboid/Lua/
-- LilBubbyAutoRun.txt and the first local player starts that run. "only
-- <text>" runs just the features whose name contains <text>, unprepared.
-- The file is emptied once read.
R.TRIGGER = "LilBubbyAutoRun.txt"
local nextPoll = 0
Events.OnTick.Add(function()
    if run then return end
    local clock = getTimestampMs()
    if clock < nextPoll then return end
    nextPoll = clock + 3000
    local reader = getFileReader(R.TRIGGER, false)
    if not reader then return end
    local line = reader:readLine()
    reader:close()
    local only = line and line:match("^%s*only%s+(.-)%s*$") or nil
    line = line and line:match("^%s*(%a+)") or nil
    if not line then return end
    local writer = getFileWriter(R.TRIGGER, true, false)
    writer:write("")
    writer:close()
    local player = getSpecificPlayer(0)
    if not player or player:isDead() then return end
    if only and only ~= "" then
        R.Start(player, { prepare = false, only = only })
    else
        R.Start(player, { prepare = line ~= "noprep", prepareOnly = line == "prepare" })
    end
end)

-- Like the Dead Man's Map runner: keeps stepping on the death screen too.
Events.OnTickEvenPaused.Add(step)
Events.OnFETick.Add(step)

S.Register(ID, function(index, context, objects, test)
    if test then return end
    local player = getSpecificPlayer(index)
    if not player then return end
    context:addOption("Run every test (prepares my character first)", player, R.Start, { prepare = true })
    context:addOption("Prepare my character only (skills and literature)", player, R.Start, { prepareOnly = true })
    context:addOption("Run every test without preparing", player, R.Start, { prepare = false })
    context:addOption("Stop the run", player, R.Stop)
end)

return LilBubbyAutoRun
