-- Offline checks for the Event Studio's logic (KIPN_EventStudio.lua):
-- mode defaults, the checklist (which mirrors the server's validation),
-- the save payload and draft bookkeeping. No game code is loaded.
-- Run from this Workshop project directory: lua tests/studio_checks.lua
-- (or from LilBubbyModTester: lua -e "next=nil" tests/dynamicevents_studio_checks.lua)
-- Dynamic Events' Lua: this project's own copy when run from the Dynamic
-- Events folder; else ~/Zomboid/Workshop/DynamicEvents (the same file is
-- kept in LilBubbyModTester/tests and run from there).
local root = "Contents/mods/DynamicEvents/42/media/lua/"
do
    local function exists(path) local f = io.open(path, "r") if f then f:close() return true end return false end
    if not exists(root .. "shared/DynamicEvents_Shared.lua") then
        root = (os.getenv("HOME") or "") .. "/Zomboid/Workshop/DynamicEvents/" .. root
    end
    if not exists(root .. "shared/DynamicEvents_Shared.lua") then
        print((arg and arg[0] or "dynamic events check") .. ": SKIPPED (Dynamic Events not found)")
        return
    end
end
require = function() end
dofile(root .. "shared/DynamicEvents_Shared.lua")
dofile(root .. "client/KIPN_EventStudio.lua")
local S = KIPN_EventStudio

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
    end
end

local function texts(issues, blockingOnly)
    local out = {}
    for _, issue in ipairs(issues) do
        if not blockingOnly or not issue.tip then out[#out + 1] = issue.step .. ": " .. issue.text end
    end
    return table.concat(out, " | ")
end

local function has(issues, step, fragment)
    for _, issue in ipairs(issues) do
        if issue.step == step and issue.text:find(fragment, 1, true) then return true end
    end
    return false
end

local function hotspot(hotspotType, round, teamId)
    return { id = hotspotType .. tostring(round) .. tostring(teamId), type = hotspotType, roundNumber = round, teamId = teamId, active = true }
end

------------------------------------------------------------
-- A blank event says what it needs, step by step.
------------------------------------------------------------
local blank = S.NewDraft({ id = "e1", name = "New Event", status = "DRAFT" })
blank.name = ""
local issues = S.Check(blank)
check("blank needs a name", has(issues, "mode", "name"), texts(issues))
check("blank needs a zone", has(issues, "area", "zone"), texts(issues))
check("blank needs objectives", has(issues, "goals", "objective type"), texts(issues))
check("blank needs a way to win", has(issues, "goals", "way to win"), texts(issues))
check("briefing tip is advice only", S.Blocking(S.IssuesForStep(issues, "story")) == 0)

------------------------------------------------------------
-- King of the Hill: picking the mode fills in what the server needs.
------------------------------------------------------------
local koth = S.NewDraft({ id = "k", name = "Hill", status = "DRAFT" })
S.ApplyMode(koth, "KING_OF_THE_HILL")
local kothObjectives = table.concat(koth.objectiveTypes, ",")
check("koth ticks Hold Area", kothObjectives:find("HOLD_AREA") ~= nil, kothObjectives)
check("koth uses a round timer", koth.timerType == "ROUND_TIMER", koth.timerType)
check("koth round length switched on", koth.roundDuration.enabled == true and koth.roundDuration.durationSeconds > 0)
check("koth defaults to 3 rounds", koth.maxRounds == 3, koth.maxRounds)
check("koth is open map, no zone needed", koth.scopeType == "OPEN_MAP" and not has(S.Check(koth), "area", "zone"))
issues = S.Check(koth)
check("koth wants teams", has(issues, "mode", "2 teams"), texts(issues))
check("koth wants a hill per round", has(issues, "area", "0 of 3"), texts(issues))
koth.teams = { { id = "team_1", name = "Red" }, { id = "team_2", name = "Blue" } }
koth.hotspots = { hotspot("HILL_LOCATION", 1), hotspot("HILL_LOCATION", 2) }
check("koth counts hills", has(S.Check(koth), "area", "2 of 3"))
local need = S.NextHotspotNeeded(koth)
check("koth next need is hill 3", need and need.type == "HILL_LOCATION" and need.round == 3, need and need.round)
koth.hotspots[3] = hotspot("HILL_LOCATION", 3)
check("complete koth has no blockers", S.Blocking(S.Check(koth)) == 0, texts(S.Check(koth), true))
koth.objectiveTypes = {}
check("unticking Hold Area is caught", has(S.Check(koth), "goals", "Hold Area"), texts(S.Check(koth)))

------------------------------------------------------------
-- Capture FFA: hotspots must match each round exactly, as the server's
-- FindHotspot does.
------------------------------------------------------------
local capture = S.NewDraft({ id = "c", name = "Flags", status = "DRAFT", zoneId = "z1" })
S.ApplyMode(capture, "CAPTURE")
capture.maxRounds = 2
check("capture defaults to FFA", capture.variant == "FFA", capture.variant)
check("capture wants a flag item", has(S.Check(capture), "mode", "flag item"))
capture.captureConfig.flagItemFullType = "Base.Hat_Beret"
local order = {}
local scratch = S.Copy(capture)
for _ = 1, 10 do
    local n = S.NextHotspotNeeded(scratch)
    if not n then break end
    order[#order + 1] = n.type .. n.round
    scratch.hotspots[#scratch.hotspots + 1] = hotspot(n.type, n.round)
end
check("capture needs each round's hotspots in order", table.concat(order, ",") == "CAPTURE_ITEM1,DELIVERY_POINT1,CAPTURE_ITEM2,DELIVERY_POINT2", table.concat(order, ","))
capture.hotspots = { hotspot("CAPTURE_ITEM", nil), hotspot("DELIVERY_POINT", nil) }
check("round-less hotspots do not count for round 1", has(S.Check(capture), "area", "round 1"), texts(S.Check(capture)))
capture.hotspots = scratch.hotspots
check("complete capture has no blockers", S.Blocking(S.Check(capture)) == 0, texts(S.Check(capture), true))

-- Team CTF needs teams first, then a base per team per round.
capture.variant = "TEAM_CTF"
check("team ctf wants teams", has(S.Check(capture), "mode", "2 teams"))
check("no base need until teams exist", S.NextHotspotNeeded(capture) == nil)
capture.teams = { { id = "team_1", name = "Red" }, { id = "team_2", name = "Blue" } }
need = S.NextHotspotNeeded(capture)
check("team ctf asks for Red's round 1 base", need and need.type == "TEAM_BASE" and need.teamId == "team_1" and need.round == 1)
check("need is described for people", S.DescribeHotspotNeed(need) == "Team Base for Red, round 1", S.DescribeHotspotNeed(need))
check("team ctf counts missing bases", has(S.Check(capture), "area", "4 missing"), texts(S.Check(capture)))
-- The server's hotspot check still wants the Retrieve/Deliver hotspots
-- the Capture recipe ticks, even for Team CTF.
capture.hotspots = {}
for round = 1, 2 do
    for _, team in ipairs(capture.teams) do capture.hotspots[#capture.hotspots + 1] = hotspot("TEAM_BASE", round, team.id) end
end
check("team ctf with bases still needs a grab spot", has(S.Check(capture), "area", "Capture Item or Rescue"), texts(S.Check(capture)))
need = S.NextHotspotNeeded(capture)
check("team ctf then asks for a capture item", need and need.type == "CAPTURE_ITEM", need and need.type)
capture.hotspots[#capture.hotspots + 1] = hotspot("CAPTURE_ITEM", 1)
capture.hotspots[#capture.hotspots + 1] = hotspot("DELIVERY_POINT", 1)
check("complete team ctf has no blockers", S.Blocking(S.Check(capture)) == 0, texts(S.Check(capture), true))

------------------------------------------------------------
-- Other modes.
------------------------------------------------------------
local run = S.NewDraft({ id = "r", name = "Run", status = "DRAFT", zoneId = "z" })
S.ApplyMode(run, "SURVIVOR_RUN")
check("survivor run has a 30 minute length", run.duration.enabled and run.duration.durationSeconds == 1800)
check("survivor run is ready at once", S.Blocking(S.Check(run)) == 0, texts(S.Check(run), true))
run.duration.enabled = false
check("survivor run without length is caught", has(S.Check(run), "rules", "Event length"))

local prison = S.NewDraft({ id = "p", name = "Break", status = "DRAFT", zoneId = "z" })
S.ApplyMode(prison, "EXTRACTION", "PRISON_BREAK")
check("prison break ticks Retrieve", table.concat(prison.objectiveTypes, ","):find("RETRIEVE") ~= nil)
issues = S.Check(prison)
check("prison break wants an extraction point", has(issues, "area", "Extraction Point"), texts(issues))
check("prison break wants something to grab", has(issues, "area", "Capture Item or Rescue"), texts(issues))
check("prison break suggests story stages", has(issues, "story", "Prison Break"))

local adventure = S.NewDraft({ id = "a", name = "Roll", status = "DRAFT", modifiers = { NAKED_AND_AFRAID = true } })
S.ApplyMode(adventure, "ADVENTURE")
check("adventure drops Naked and Afraid", adventure.modifiers.NAKED_AND_AFRAID == false)
adventure.scopeType = "OPEN_MAP"
check("adventure needs a zone scope", has(S.Check(adventure), "area", "Adventure"))

local soldier = S.NewDraft({ id = "s", name = "Soldier", status = "DRAFT", zoneId = "z" })
S.ApplyMode(soldier, "EXTRACTION", "ABANDONED_SOLDIER")
soldier.modifiers.NAKED_AND_AFRAID = true
check("blocked variant rejects Naked and Afraid", has(S.Check(soldier), "mode", "Naked and Afraid"))

------------------------------------------------------------
-- Timers never leave the event invalid.
------------------------------------------------------------
local timed = S.NewDraft({ id = "t", name = "T", status = "DRAFT" })
S.SetTimer(timed, "COUNTDOWN")
check("countdown switches the length on", timed.duration.enabled and timed.duration.durationSeconds > 0)
S.SetTimer(timed, "ROUND_TIMER")
check("round timer switches the round length on", timed.roundDuration.enabled and timed.roundDuration.durationSeconds > 0)
timed.roundDuration.durationSeconds = 0
check("zero round length is caught", has(S.Check(timed), "rules", "Round length"))

------------------------------------------------------------
-- Story stages.
------------------------------------------------------------
local story = S.NewDraft({ id = "st", name = "S", status = "DRAFT", zoneId = "z", objectiveTypes = { "SURVIVE" }, outcomeTypes = { "LAST_ALIVE" },
    objectives = { { id = "o1", name = "Find it", triggers = {} } } })
check("stage without triggers is caught", has(S.Check(story), "story", "no triggers"))
story.objectives[1].triggers = { { activationMode = "PROXIMITY", hotspotId = "gone", actions = {} } }
check("trigger at a deleted hotspot is caught", has(S.Check(story), "story", "deleted"))

------------------------------------------------------------
-- Payload and bookkeeping.
------------------------------------------------------------
local custom = S.NewDraft({ id = "x", name = "  Custom  ", status = "DRAFT", mode = "CHASE",
    rewards = { items = { { itemFullType = "Base.Axe", count = 2 }, { itemFullType = "  ", count = 1 } } } })
S.ApplyMode(custom, S.CUSTOM)
local payload = S.Payload(custom)
check("custom sends a mode the server clears", payload.mode == "NONE", payload.mode)
check("recipes never re-run the legacy migration", payload.scenarioPresetId == S.CUSTOM)
check("name is trimmed", payload.name == "Custom", payload.name)
check("blank reward rows are dropped", #payload.rewardItems == 1 and payload.rewardItems[1].count == 2)

local definition = { id = "d", name = "Same", status = "DRAFT", zombieTheme = "MILITARY" }
check("fresh drafts match their definition", S.Signature(S.NewDraft(definition)) == S.Signature(S.NewDraft(definition)))
local edited = S.NewDraft(definition)
edited.name = "Changed"
check("an edit changes the signature", S.Signature(edited) ~= S.Signature(S.NewDraft(definition)))
check("string zombie themes are read", edited.zombieTheme.themeId == "MILITARY")

S.MergeServerFields(edited, { id = "d", name = "Same", status = "READY", zoneId = "z9", hotspots = { hotspot("ZOMBIE_SPAWN") } })
check("server fields merge in", edited.zoneId == "z9" and edited.status == "READY" and #edited.hotspots == 1)
check("merge keeps unsaved edits", edited.name == "Changed")
check("missing lists become empty", type(edited.teams) == "table" and type(edited.participants) == "table")

check("server reasons are explained", S.Explain("NO_ZONE,KOTH_REQUIRES_HOLD_AREA_OBJECTIVE") == "draw the event zone (Area step); tick Hold Area (Goals step)",
    S.Explain("NO_ZONE,KOTH_REQUIRES_HOLD_AREA_OBJECTIVE"))
check("extraction reasons are explained", S.Explain("EXTRACTION_REQUIRES_RETRIEVE_OBJECTIVE"):find("Retrieve") ~= nil)
check("unknown reasons pass through", S.Explain("SOMETHING_NEW") == "SOMETHING_NEW")

for _, step in ipairs(S.Steps) do
    if step.id ~= "launch" then
        check("summary for " .. step.id, #S.Summary(koth, step.id) > 0)
    end
end
check("every lifecycle status has a next action", S.NextAction.DRAFT.id == "validate" and S.NextAction.COMPLETE.id == "reset")


------------------------------------------------------------
-- Game loops: every mode gets a clock that ends it.
------------------------------------------------------------
local cap = S.NewDraft({ id = "c2", name = "C", status = "DRAFT" })
S.ApplyMode(cap, "CAPTURE")
check("capture plays in timed rounds", cap.timerType == "ROUND_TIMER" and cap.roundDuration.durationSeconds == 480 and cap.maxRounds == 3)
local ex = S.NewDraft({ id = "x2", name = "X", status = "DRAFT", zoneId = "z" })
S.ApplyMode(ex, "EXTRACTION", "LAST_DITCH")
check("last ditch is a hold-out", table.concat(ex.objectiveTypes, ",") == "SURVIVE" and ex.combatRules.allowLeaveZone == false)
check("extraction has an event length", ex.duration.enabled and ex.duration.durationSeconds == 1200)
check("every extraction variant needs an extraction point", has(S.Check(ex), "area", "Extraction Point"))
ex.duration.enabled = false
check("extraction without a length is caught", has(S.Check(ex), "rules", "evac"))
local classic = S.NewDraft({ id = "cl", name = "Classic", status = "DRAFT", zoneId = "z", objectiveTypes = { "SURVIVE" }, outcomeTypes = { "LAST_ALIVE" } })
check("an event with no ending gets a tip", has(S.Check(classic), "rules", "Nothing ends this event"))
local pvp = S.NewDraft({ id = "pv", name = "P", status = "DRAFT" })
S.ApplyMode(pvp, "CHASE")
check("PvP modes suggest Naked and Afraid", has(S.Check(pvp), "mode", "Naked and Afraid"))

------------------------------------------------------------
-- The Olympics: the course is drawn piece by piece from its template.
------------------------------------------------------------
local games = S.NewDraft({ id = "g", name = "Games", status = "DRAFT" })
S.ApplyMode(games, "OLYMPICS")
check("olympics defaults to the obstacle course", games.olympicsConfig.discipline == "OBSTACLE" and games.scopeType == "OPEN_MAP")
check("olympics has no rounds", games.maxRounds == 1)
local pieces = {}
local course = S.Copy(games)
for _ = 1, 20 do
    local n = S.NextHotspotNeeded(course)
    if not n then break end
    pieces[#pieces + 1] = n.type:gsub("OLYMPIC_", "") .. (n.round and tostring(n.round) or "") .. (n.metadata and (":" .. n.metadata.task) or "")
    course.hotspots[#course.hotspots + 1] = { id = tostring(#course.hotspots), type = n.type, roundNumber = n.round, metadata = n.metadata, active = true }
end
check("the obstacle course is laid out in order", table.concat(pieces, ",")
    == "START,STATION1:CHECKPOINT,STATION2:CHOP,STATION3:CRAFT,STATION4:CARRY,DROP4,STATION5:SHOOT,TARGETS5,FINISH", table.concat(pieces, ","))
check("stations carry their task's defaults", course.hotspots[3].metadata.itemType == "Base.Log" and course.hotspots[3].metadata.kit[1] == "Base.Axe")
check("a finished course passes the checklist", S.Blocking(S.Check(course)) == 0, texts(S.Check(course), true))
check("an unfinished course is listed", has(S.Check(games), "area", "start line") and has(S.Check(games), "area", "finish line"))
games.olympicsConfig.discipline = "SPRINT"
check("a sprint is just start and finish", S.NextHotspotNeeded(games).type == "OLYMPIC_START")
local sprint = S.Copy(games)
sprint.hotspots = { { id = "a", type = "OLYMPIC_START", active = true } }
check("then the finish", S.NextHotspotNeeded(sprint).type == "OLYMPIC_FINISH")
local payloadGames = S.Payload(course)
check("olympics settings are saved", payloadGames.olympicsConfig.heatSize == 2 and payloadGames.olympicsConfig.discipline == "OBSTACLE")
check("olympics server reasons are explained", S.Explain("OLYMPICS_DROP_REQUIRED"):find("drop zone", 1, true) ~= nil)
check("olympics summary shows the course", table.concat(S.Summary(course, "area"), " "):find("Course: start > 1. Checkpoint", 1, true) ~= nil,
    table.concat(S.Summary(course, "area"), " "))

------------------------------------------------------------
-- Classic scenarios: every Pillow scenario applies, and those with a
-- full original location pass the checklist once set up there.
------------------------------------------------------------
for _, id in ipairs(KIPN.Shared.EventClassicScenarioOrder) do
    local template = KIPN.Shared.EventClassicScenarios[id]
    local d = S.NewDraft({ id = id, name = "New Event", status = "DRAFT" })
    local message = S.ApplyScenario(d, id)
    check(id .. " applies", d.classicScenario == id and d.mode == template.mode and d.loadout == template.loadout, message)
    check(id .. " takes its name and briefing", d.name == template.label and d.narrative.briefing == template.briefing)
    for _, hotspot in ipairs(S.VenueHotspots(template)) do
        hotspot.id = tostring(#d.hotspots + 1)
        hotspot.active = true
        d.hotspots[#d.hotspots + 1] = hotspot
    end
    if template.venue and template.venue.zone then d.zoneId = "z" end
    local blocking = S.Blocking(S.Check(d))
    if not template.venue then
        -- No original location (The Heist): the checklist asks for the
        -- places it needs, starting with the getaway car.
        check(id .. " asks for its places", blocking > 0 and has(S.Check(d), "area", "Getaway Car")
            and S.NextHotspotNeeded(d).type == "BANDIT_VEHICLE", texts(S.Check(d), true))
    elseif id == "ABANDONED_SOLDIER" or id == "HOSPITAL" or id == "LAST_FLIGHT" then
        check(id .. " only needs its evac point drawn", blocking == 1 and has(S.Check(d), "area", "Extraction Point"), texts(S.Check(d), true))
    else
        check(id .. " is ready at its original location", blocking == 0, texts(S.Check(d), true))
    end
    local payload = S.Payload(d)
    check(id .. " saves its loadout and threats", payload.loadout == template.loadout and payload.classicScenario == id)
end
local dodge = S.NewDraft({ id = "dg", name = "", status = "DRAFT" })
S.ApplyScenario(dodge, "DODGEBALL")
check("dodgeball is last one standing", dodge.survivorConfig.lastStanding and S.Payload(dodge).survivorConfig.lastStanding)
local fs = S.NewDraft({ id = "fs", name = "", status = "DRAFT", zoneId = "z" })
S.ApplyScenario(fs, "FIRE_SALE")
check("fire sale warns about real fire", has(S.Check(fs), "zombies", "Fires are real"))
check("fire sale wants several exits", has(S.Check(fs), "area", "several Extraction Points"))

------------------------------------------------------------
-- Bandits and The Heist.
------------------------------------------------------------
local heist = S.NewDraft({ id = "hz", name = "", status = "DRAFT" })
S.ApplyScenario(heist, "HEIST")
check("the heist is an Extraction with a Retrieve goal", heist.mode == "EXTRACTION" and heist.variant == "HEIST"
    and S.RequiredObjectives(heist).RETRIEVE)
check("the heist sends bandit raids", S.Payload(heist).threats.BANDITS == true)
check("every threat is saved, bandits included", S.Payload(heist).threats.SIEGE == false and S.Payload(heist).threats.BANDITS == true)
check("the heist first asks for the getaway car", S.NextHotspotNeeded(heist).type == "BANDIT_VEHICLE")
heist.hotspots = { { id = "1", type = "BANDIT_VEHICLE", active = true, geometry = { x1 = 0, y1 = 0, x2 = 4, y2 = 4, z1 = 0 } } }
check("with the car placed it asks for the pickup", S.NextHotspotNeeded(heist).type == "EXTRACTION_POINT")
check("the car counts as the thing to retrieve", not has(S.Check(heist), "area", "Capture Item or Rescue"))
check("the heist suggests a trail of clues", has(S.Check(heist), "area", "Leave a trail"))
heist.hotspots[#heist.hotspots + 1] = { id = "2", type = "EXTRACTION_POINT", active = true, geometry = { x1 = 9, y1 = 9, x2 = 12, y2 = 12, z1 = 0 } }
check("with a car and a pickup the area step is done", S.Blocking(S.IssuesForStep(S.Check(heist), "area")) == 0, texts(S.Check(heist), true))
check("a missing car is explained", S.Explain("HEIST_REQUIRES_BANDITS"):find("Getaway Car", 1, true) ~= nil)
check("bandit hotspots have help", S.HotspotHelp.BANDIT_CAMP ~= nil and S.HotspotHelp.BANDIT_VEHICLE ~= nil)

print(string.format("studio_checks: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
