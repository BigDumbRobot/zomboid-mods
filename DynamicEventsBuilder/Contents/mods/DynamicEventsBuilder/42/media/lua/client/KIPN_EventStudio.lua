-- KIPN_EventStudio.lua
--
-- Step catalog, mode guides and the checklist behind the Event Studio
-- (KIPN_EventStudioUI.lua). Holds no UI, so the checklist can be run
-- offline (see tests/studio_checks.lua).
--
-- An event is built in nine steps. Every problem the checklist finds
-- names the step that fixes it, so the Studio can mark that step and
-- say what is still needed there. The checks mirror the server's own
-- EVENT_VALIDATE (KIPN_EventScenarioService.lua's handleValidate and
-- the per-mode ValidateDefinition functions) -- the server still has
-- the final say; this only tells the admin before they ask it.

require "KIPN_Shared"
require "DynamicEvents_Shared"

KIPN_EventStudio = KIPN_EventStudio or {}
local S = KIPN_EventStudio
local Shared = KIPN.Shared

S.MAX_REWARD_ROWS = 10
S.MAX_NOTE_ROWS = 5
S.MAX_ROUNDS = 10
S.CUSTOM = "CUSTOM"

------------------------------------------------------------
-- STEPS
------------------------------------------------------------

S.Steps = {
    { id = "mode", title = "Mode", heading = "Name it and pick a game mode",
      guide = "1. Type a name players will recognise.\n2. Pick a game mode on the left. Picking one fills in sensible rules, timers and goals for it; every later step can still change them.\n3. If the mode has variants, rounds or teams, set them here.\n\nNot sure? Survivor Run is the simplest: one area, a timer, and whoever is alive at the end wins." },
    { id = "area", title = "Area", heading = "Mark where it happens",
      guide = "1. Choose how big the event is: one zone, separate hotspots, or the whole map.\n2. For a zone, press Draw zone on map and click two opposite corners, or Use area around me.\n3. Place the hotspots listed under Still needed. Each is a small rectangle on the map (a hill, a flag spawn, a delivery point).\n\nPlace hotspots for me drops every required hotspot at random inside 40 tiles of you. Move any that land badly by deleting and redrawing them." },
    { id = "rules", title = "Rules & Time", heading = "Set combat rules and the clock",
      guide = "1. Choose who can hurt whom. No Combat blocks all damage inside the event, zombies included.\n2. Choose a timer. Countdown and the others end the event after the Event length; Round Timer ends each round after the Round length.\n3. Optionally force time of day or weather while the event runs." },
    { id = "zombies", title = "Zombies", heading = "Decide how zombies behave",
      guide = "1. Choose a director. It decides whether zombies come on their own (Escalation, Perimeter, Random) or only when you press buttons in the Director panel (Waves).\n2. Choose a theme to dress spawned zombies (Military, Prison...).\n3. Spawn radius is how far from players new zombies appear." },
    { id = "goals", title = "Goals", heading = "Say what players must do and how they win",
      guide = "The game mode already ticked what it needs. Only change these for a Custom event, or to add extra goals.\n\nObjective types are what players do. Ways to win decide who is credited at the end.\n\nAutomatic checks (optional) end the event by themselves, for example when every participant is dead." },
    { id = "story", title = "Story", heading = "Write what players read",
      guide = "1. Briefing is shown when you announce the event. Say where to go and what to do.\n2. Win and lose text are shown when it ends.\n3. Checklist lines appear to participants as their to-do list.\n4. Stages (optional) run the story in order: each stage waits for its triggers, such as a player reaching a hotspot, then runs actions like a hint, an alarm or zombies." },
    { id = "rewards", title = "Rewards", heading = "Choose prizes",
      guide = "1. Type an item name; suggestions appear under it. Set how many.\n2. Choose delivery. Admin Delivery puts the prize on your to-do list below; PO Box sends it by mail (held in escrow if the winner has no box).\n\nOnly winners are rewarded. Leave the list empty for no prizes." },
    { id = "players", title = "Players", heading = "Invite players (optional)",
      guide = "You do not have to pick anyone: Open joining (Launch step) asks every online player to sign up, and everyone signed up is brought in when you Begin. Players who miss it can still join from the prompt they get when it starts (and at each new round).\n\nTo hand-pick a roster instead, tick players and press Save roster. Teams are shared out automatically as players join; you can move people here." },
    { id = "launch", title = "Launch", heading = "Check it and run it",
      guide = "Press the big button to move to the next stage:\n1. Check and mark ready: saves and asks the server to verify everything.\n2. Announce: tells everyone online what is coming (your briefing).\n3. Open joining: every online player gets a Sign up prompt (for the Olympics, a town picker). Give people a minute.\n4. Begin: everyone signed up is brought in and the game runs itself: rounds start on their own, players get a HUD with their goal, the clock, the score and which way to go, and big announcements as things happen. This window steps aside; the corner strip tracks the event, and Director opens live controls if you want to step in.\n5. When it ends, everyone is told who won and sent back. Reset for reuse makes it editable again." },
}

function S.StepIndex(id)
    for index, step in ipairs(S.Steps) do
        if step.id == id then return index end
    end
    return 1
end

------------------------------------------------------------
-- GAME MODES
------------------------------------------------------------

-- Each guide is the game as players experience it: how a round goes,
-- how you win, what makes it tense. Shown on the Mode step.
S.ModeGuides = {
    CAPTURE = { summary = "Grab the flag, run it home, don't get caught.",
        guide = "How it plays: each round a flag appears. Grab it (it's a real item in your inventory) and carry it to the goal while everyone else tries to take it off you. Drop it, die or log off and it lies where it fell, or goes back to its spot after a while.\n\nFFA: one flag, one delivery point, every player for themselves.\nTeam CTF: each team's flag sits at its base. Steal the enemy's and bring it to yours, while guarding your own.\n\nThe HUD points at the flag, or at your goal while you carry it. Most captures after the last round wins. Rounds start by themselves." },
    KING_OF_THE_HILL = { summary = "Teams fight to hold a hill; it moves every round.",
        guide = "How it plays: each round reveals a new hill, and the HUD points everyone to it. A team scores time only while it is alone on the hill; two teams on it means contested, and nobody scores. When the round clock runs out, the team with the most time on the hill takes the round. Most rounds wins.\n\nNeeds 2 or more teams (players are shared out as they join) and one Hill Location per round. Rounds start by themselves after a short break." },
    CHASE = { summary = "One player is hunted each round; the hunters close in.",
        guide = "How it plays: every round a new player becomes the target (everyone gets a turn). The target must survive the round. The hunters see where the target was every 30 seconds, so the target has to keep moving.\n\nCatch the target and every hunter scores; the target escapes and scores. Most points wins.\n\nBeing caught is a real death in Project Zomboid. Turn on Naked and Afraid so nobody risks their gear, or ask players to bring throwaway characters." },
    EXTRACTION = { summary = "Hold out, then race to the evac before it leaves.",
        guide = "How it plays: survive while the zombies come. In the last few minutes the evac arrives; everyone is told and the HUD points to the Extraction Point. Reach it alive and you're flown out: you win and are safe. Nobody out when time runs out means everyone loses.\n\nVariants set the flavour: Abandoned Soldier (building alarms draw the horde), Hospital Ward (sudden random attacks), Last Ditch (defend your position; leaving the zone is blocked), Prison Break (no wait: search the marked spot to find the way out, then run for the exit), Fire Sale (escape the burning mall: one exit is clear, the rest are swarmed), The Test Subject (fight up through the secret base's rooms), The Last Flight (crash survivor: patch up and hold out for rescue), Road Trip (drive in from the county line to safety)." },
    SURVIVOR_RUN = { summary = "Stay alive until the clock runs out.",
        guide = "How it plays: one continuous fight for survival while the zombies ramp up. The HUD shows the clock and how many are still standing, and everyone hears when someone falls. Everyone alive at the end wins; if everyone falls, it ends early.\n\nThe simplest mode to run: a zone and an event length." },
    ADVENTURE = { summary = "The server picks a random game inside your zone.",
        guide = "How it plays: at the start the server rolls King of the Hill, Chase, Survivor Run, Last Ditch or (if you set a flag item) Capture the Flag, and builds its hills, teams and timers inside your zone. Players find out what they're playing when it begins. It resets itself afterwards.\n\nNeeds only an event zone. Cannot be combined with Naked and Afraid." },
    OLYMPICS = { summary = "Timed obstacle races for Knox County's towns. Go for gold!",
        guide = "How it plays: athletes sign up for a town. Two at a time, heats are called to the start line; after 3-2-1-GO they race your course's stations in order (chop wood, craft, lift a heavy load, shoot targets, reach checkpoints) and cross the finish. Every station cleared is called out with a split time, and the HUD always points to the next one. The fastest three take gold, silver and bronze, and their towns add the medals to a table that carries over between Olympics.\n\nPick a course template (Obstacle Course, Sprint, Biathlon, Lumberjack, Marathon), then draw its start, stations and finish on the Area step." },
    CUSTOM = { label = "Custom (build it yourself)", summary = "No mode engine: you choose every piece.",
        guide = "Runs on the classic horde engine: you tick the objectives, ways to win and automatic checks yourself, and you or the timer end it. Pick a Starting recipe to fill the steps from a classic scenario, then adjust. Make sure something ends it: a timer, an automatic check, or story stages." },
}

function S.ModeKeys()
    local keys = {}
    for _, mode in ipairs(Shared.EventModeOrder or {}) do keys[#keys + 1] = mode end
    keys[#keys + 1] = S.CUSTOM
    return keys
end

function S.ModeLabel(mode)
    if not mode or mode == S.CUSTOM then return S.ModeGuides.CUSTOM.label end
    return (Shared.EventModeLabels or {})[mode] or tostring(mode)
end

-- The variant vocabulary a mode offers, or nil.
function S.Variants(mode)
    if mode == "EXTRACTION" then
        return Shared.EventExtractionVariantOrder, Shared.EventExtractionVariantLabels
    elseif mode == "CAPTURE" then
        return Shared.EventCaptureVariantOrder, Shared.EventCaptureVariantLabels
    end
end

-- Mirrors KIPN_EventModeRegistry.ModeUsesTeams (server only).
function S.UsesTeams(mode, variant)
    local metadata = mode and (Shared.EventModeMetadata or {})[mode]
    if not metadata or not metadata.usesTeams then return false end
    if mode == "CAPTURE" then return variant == "TEAM_CTF" end
    return true
end

function S.UsesRounds(mode)
    if not mode or mode == S.CUSTOM then return true end
    local metadata = (Shared.EventModeMetadata or {})[mode]
    return metadata ~= nil and metadata.usesRounds == true
end

-- Mirrors KIPN_EventModeRegistry.IsModifierCompatible for NAKED_AND_AFRAID.
local NAKED_BLOCKED_EXTRACTION = { ABANDONED_SOLDIER = true, LAST_DITCH = true, LAST_FLIGHT = true }
function S.NakedCompatible(mode, variant)
    if not mode or mode == S.CUSTOM then return false, "Pick a game mode first." end
    if mode == "ADVENTURE" then return false, "Adventure cannot use it: its mode is only rolled at start." end
    if mode == "EXTRACTION" and NAKED_BLOCKED_EXTRACTION[variant] then
        return false, "This variant hands out a required loadout."
    end
    return true
end

------------------------------------------------------------
-- DEFAULTS PER MODE
--
-- Picking a mode applies a recipe so the server's mode checks pass
-- without the admin knowing them (KOTH needs HOLD_AREA, Chase needs
-- CHASE_TARGET, each Extraction variant needs its objective type...).
-- Where a classic Scenario Preset already describes the mode it is
-- reused as-is.
------------------------------------------------------------

-- Each recipe gives its mode a clock that actually ends it: rounds
-- that run themselves, or an event length for hold-out modes.
local DEFAULT_EVENT_SECONDS = 30 * 60
local DEFAULT_ROUND_SECONDS = 10 * 60

local function recipe(objectiveTypes, outcomeTypes, ruleType, directorType, timerType, extra)
    local r = { objectiveTypes = objectiveTypes, outcomeTypes = outcomeTypes, ruleType = ruleType,
        directorType = directorType, timerType = timerType }
    for key, value in pairs(extra or {}) do r[key] = value end
    return r
end

local MODE_RECIPES = {
    CAPTURE = { variant = "FFA", recipe = recipe({ "RETRIEVE", "DELIVER" }, { "FIRST_TO_COMPLETE" }, "PVP", "ZOMBIE_WAVES", "ROUND_TIMER",
        { pvpAllowedInZone = true, maxRounds = 3, roundSeconds = 8 * 60 }) },
    KING_OF_THE_HILL = { recipe = recipe({ "HOLD_AREA" }, { "HOLD_DURATION" }, "PVP", "ZOMBIE_ESCALATION", "ROUND_TIMER",
        { pvpAllowedInZone = true, scopeType = "OPEN_MAP", maxRounds = 3, roundSeconds = 5 * 60 }) },
    CHASE = { recipe = recipe({ "CHASE_TARGET" }, { "LAST_ALIVE" }, "PVP", "ZOMBIE_WAVES", "ROUND_TIMER",
        { pvpAllowedInZone = true, scopeType = "OPEN_MAP", maxRounds = 3, roundSeconds = 5 * 60 }) },
    EXTRACTION = { variant = "ABANDONED_SOLDIER" },
    SURVIVOR_RUN = { recipe = recipe({ "SURVIVE" }, { "TIME_EXPIRED" }, "PVE", "ZOMBIE_ESCALATION", "COUNTDOWN",
        { eventSeconds = 30 * 60 }) },
    ADVENTURE = { recipe = recipe({ "SURVIVE" }, { "LAST_ALIVE" }, "PVE", "ZOMBIE_RANDOM", "NONE") },
    OLYMPICS = { recipe = recipe({ "LOCATE" }, { "FIRST_TO_COMPLETE" }, "PVE", "ZOMBIE_WAVES", "NONE",
        { scopeType = "OPEN_MAP" }) },
}

-- Extraction: every variant is a 20-minute hold-out ending in the evac.
local EXTRACTION_RECIPES = {
    ABANDONED_SOLDIER = recipe({ "SURVIVE" }, { "EXTRACTION" }, "PVE", "ZOMBIE_PERIMETER", "COUNTDOWN", { eventSeconds = 20 * 60 }),
    HOSPITAL_WARD = recipe({ "SURVIVE" }, { "EXTRACTION" }, "PVE", "ZOMBIE_RANDOM", "COUNTDOWN", { eventSeconds = 20 * 60 }),
    LAST_DITCH = recipe({ "SURVIVE" }, { "EXTRACTION" }, "PVE", "ZOMBIE_ESCALATION", "COUNTDOWN", { eventSeconds = 20 * 60, stayInZone = true }),
    PRISON_BREAK = recipe({ "RETRIEVE" }, { "EXTRACTION" }, "PVE", "ZOMBIE_ESCALATION", "COUNTDOWN", { eventSeconds = 15 * 60 }),
    FIRE_SALE = recipe({ "SURVIVE" }, { "EXTRACTION" }, "PVE", "ZOMBIE_PERIMETER", "COUNTDOWN", { eventSeconds = 15 * 60 }),
    TEST_SUBJECT = recipe({ "SURVIVE" }, { "EXTRACTION" }, "PVE", "ZOMBIE_WAVES", "COUNTDOWN", { eventSeconds = 25 * 60, scopeType = "OPEN_MAP" }),
    LAST_FLIGHT = recipe({ "SURVIVE" }, { "EXTRACTION" }, "PVE", "ZOMBIE_ESCALATION", "COUNTDOWN", { eventSeconds = 20 * 60 }),
    ROAD_TRIP = recipe({ "SURVIVE" }, { "EXTRACTION" }, "PVE", "ZOMBIE_RANDOM", "COUNTDOWN", { eventSeconds = 25 * 60, scopeType = "OPEN_MAP" }),
    HEIST = recipe({ "RETRIEVE" }, { "EXTRACTION" }, "PVE", "ZOMBIE_RANDOM", "COUNTDOWN", { eventSeconds = 25 * 60, scopeType = "OPEN_MAP" }),
}

local function copyList(list)
    local out = {}
    for index, value in ipairs(list or {}) do out[index] = value end
    return out
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, inner in pairs(value) do out[key] = copy(inner) end
    return out
end
S.Copy = copy

-- Sets the timer type and switches on the length that timer needs, so
-- choosing a timer can never leave the event failing validation.
function S.SetTimer(draft, timerType, eventSeconds, roundSeconds)
    draft.timerType = timerType or "NONE"
    if draft.timerType == "ROUND_TIMER" then
        draft.roundDuration.enabled = true
        if roundSeconds or (tonumber(draft.roundDuration.durationSeconds) or 0) <= 0 then
            draft.roundDuration.durationSeconds = roundSeconds or DEFAULT_ROUND_SECONDS
        end
    elseif draft.timerType ~= "NONE" then
        draft.duration.enabled = true
        if eventSeconds or (tonumber(draft.duration.durationSeconds) or 0) <= 0 then
            draft.duration.durationSeconds = eventSeconds or DEFAULT_EVENT_SECONDS
        end
    end
end

-- Applies a Scenario Preset-shaped recipe to a draft.
function S.ApplyRecipe(draft, recipe)
    if not recipe then return end
    draft.objectiveTypes = copyList(recipe.objectiveTypes)
    draft.outcomeTypes = copyList(recipe.outcomeTypes)
    draft.ruleType = recipe.ruleType or draft.ruleType
    draft.directorType = recipe.directorType or draft.directorType
    draft.scopeType = recipe.scopeType or "ZONE"
    draft.maxRounds = recipe.maxRounds or 1
    if recipe.zombieTheme then draft.zombieTheme = { themeId = recipe.zombieTheme } end
    draft.combatRules.pvpAllowedInZone = recipe.pvpAllowedInZone == true
    if recipe.stayInZone ~= nil then draft.combatRules.allowLeaveZone = not recipe.stayInZone end
    draft.spawnRules.escalationEnabled = draft.directorType ~= "ZOMBIE_WAVES"
    S.SetTimer(draft, recipe.timerType, recipe.eventSeconds, recipe.roundSeconds)
end

-- The objective types the chosen mode cannot work without.
function S.RequiredObjectives(d)
    local required = {}
    if d.mode == "KING_OF_THE_HILL" then required.HOLD_AREA = true end
    if d.mode == "CHASE" then required.CHASE_TARGET = true end
    if d.mode == "EXTRACTION" then
        local byVariant = { ABANDONED_SOLDIER = "SURVIVE", HOSPITAL_WARD = "SURVIVE", LAST_DITCH = "SURVIVE", PRISON_BREAK = "RETRIEVE",
            FIRE_SALE = "SURVIVE", TEST_SUBJECT = "SURVIVE", LAST_FLIGHT = "SURVIVE", ROAD_TRIP = "SURVIVE", HEIST = "RETRIEVE" }
        if byVariant[d.variant] then required[byVariant[d.variant]] = true end
    end
    return required
end

function S.ApplyPreset(draft, presetKey)
    S.ApplyRecipe(draft, (Shared.EventScenarioPresets or {})[presetKey])
end

-- Sets mode and variant and fills in that mode's defaults. Returns a
-- short sentence describing what changed.
-- Sets mode and variant and fills in that mode's defaults. Returns a
-- short sentence describing what changed.
function S.ApplyMode(draft, mode, variant)
    if mode == S.CUSTOM then
        draft.mode, draft.variant = nil, nil
        return "Custom event: choose a Starting recipe below, or set each step yourself."
    end

    local spec = MODE_RECIPES[mode] or {}
    local variants = S.Variants(mode)
    local chosen = variant
    if variants and not chosen then chosen = spec.variant or variants[1] end
    if not variants then chosen = nil end

    draft.mode, draft.variant = mode, chosen
    draft.migrationStatus = Shared.EventMigrationStatus and Shared.EventMigrationStatus.NATIVE or draft.migrationStatus

    if mode == "EXTRACTION" then
        S.ApplyRecipe(draft, EXTRACTION_RECIPES[chosen])
    else
        S.ApplyRecipe(draft, spec.recipe)
    end

    if mode == "SURVIVOR_RUN" or mode == "EXTRACTION" then draft.duration.expiryBehavior = "WIN" end
    if mode == "OLYMPICS" then
        draft.olympicsConfig.discipline = draft.olympicsConfig.discipline or "OBSTACLE"
    end
    if not S.UsesRounds(mode) then draft.maxRounds = 1 end
    if not S.NakedCompatible(mode, chosen) then draft.modifiers.NAKED_AND_AFRAID = false end

    return "Filled in the defaults for " .. S.ModeLabel(mode) .. ". Later steps show what it still needs."
end

------------------------------------------------------------
-- CLASSIC SCENARIOS (Pillow's Random Scenarios)
------------------------------------------------------------

-- Turns a draft into one of the classic scenarios: its mode, starting
-- loadout, difficulty, threats, zombies and briefing. Returns a sentence.
function S.ApplyScenario(d, id)
    local function trim(text) return (tostring(text or ""):match("^%s*(.-)%s*$")) end
    local template = (Shared.EventClassicScenarios or {})[id]
    if not template then return "Unknown scenario." end
    S.ApplyMode(d, template.mode, template.variant)
    d.classicScenario = id
    d.loadout = template.loadout or "NONE"
    d.difficulty = template.difficulty or "NORMAL"
    d.threats = copy(template.threats or {})
    d.survivorConfig.lastStanding = template.lastStanding == true
    if template.theme then d.zombieTheme = { themeId = template.theme } end
    if template.director then
        d.directorType = template.director
        d.spawnRules.escalationEnabled = template.director ~= "ZOMBIE_WAVES"
    end
    if template.scope then d.scopeType = template.scope end
    if trim(d.name) == "" or d.name == "New Event" then d.name = template.label end
    if trim(d.narrative.briefing) == "" then d.narrative.briefing = template.briefing end
    if d.loadout ~= "NONE" then d.modifiers.NAKED_AND_AFRAID = false end
    return "Set up as " .. template.label .. ". The Area step can place it at its original location."
end

-- A venue's hotspots in the shape EVENT_UPSERT_HOTSPOT takes.
function S.VenueHotspots(template)
    local out = {}
    for _, spot in ipairs((template and template.venue and template.venue.hotspots) or {}) do
        local hotspotType, x, y, z, half, round, metadata = spot[1], spot[2], spot[3], spot[4] or 0, spot[5] or 2, spot[6], spot[7]
        out[#out + 1] = {
            type = hotspotType, label = (Shared.EventHotspotTypeLabels or {})[hotspotType] or hotspotType, roundNumber = round, metadata = metadata,
            geometry = { x1 = x - half, y1 = y - half, x2 = x + half, y2 = y + half, z1 = z, z2 = z },
        }
    end
    return out
end

------------------------------------------------------------
-- DRAFTS
------------------------------------------------------------

-- A draft is the editable copy of a definition. Studio widgets write
-- into it; only Save sends it to the server.
function S.NewDraft(definition)
    local d = copy(definition or {})
    d.name = d.name or ""
    d.modifiers = type(d.modifiers) == "table" and d.modifiers or {}
    d.captureConfig = type(d.captureConfig) == "table" and d.captureConfig or {}
    d.captureConfig.flagItemFullType = d.captureConfig.flagItemFullType or ""
    d.captureConfig.autoReturnSeconds = tonumber(d.captureConfig.autoReturnSeconds) or 90
    d.scopeType = d.scopeType or "ZONE"
    d.maxRounds = tonumber(d.maxRounds) or 1
    d.spawnRules = type(d.spawnRules) == "table" and d.spawnRules or {}
    d.spawnRules.baseSpawnRadius = tonumber(d.spawnRules.baseSpawnRadius) or 40
    d.directorType = d.directorType or (Shared.EventDirectorTypeOrder or {})[1]
    if type(d.zombieTheme) ~= "table" then d.zombieTheme = { themeId = d.zombieTheme or "RANDOM" } end
    d.environment = type(d.environment) == "table" and d.environment or {}
    d.ruleType = d.ruleType or "PVE"
    d.combatRules = type(d.combatRules) == "table" and d.combatRules or {}
    d.timerType = d.timerType or "NONE"
    d.duration = type(d.duration) == "table" and d.duration or {}
    d.duration.durationSeconds = tonumber(d.duration.durationSeconds) or 0
    d.duration.expiryBehavior = d.duration.expiryBehavior or "WIN"
    d.roundDuration = type(d.roundDuration) == "table" and d.roundDuration or {}
    d.roundDuration.durationSeconds = tonumber(d.roundDuration.durationSeconds) or 0
    d.objectiveTypes = d.objectiveTypes or {}
    d.outcomeTypes = d.outcomeTypes or {}
    d.winConditions = d.winConditions or {}
    d.failConditions = d.failConditions or {}
    d.objectives = d.objectives or {}
    d.objectiveNotes = d.objectiveNotes or {}
    d.narrative = type(d.narrative) == "table" and d.narrative or {}
    d.rewards = type(d.rewards) == "table" and d.rewards or {}
    d.rewards.items = d.rewards.items or {}
    d.rewardDeliveryMethod = d.rewardDeliveryMethod or "ADMIN_DELIVERY"
    d.participants = type(d.participants) == "table" and d.participants or {}
    d.hotspots = d.hotspots or {}
    d.teams = d.teams or {}
    d.loadout = d.loadout or "NONE"
    d.difficulty = d.difficulty or "NORMAL"
    d.threats = type(d.threats) == "table" and d.threats or {}
    d.survivorConfig = type(d.survivorConfig) == "table" and d.survivorConfig or {}
    d.survivorConfig.lastStanding = d.survivorConfig.lastStanding == true
    d.olympicsConfig = type(d.olympicsConfig) == "table" and d.olympicsConfig or {}
    d.olympicsConfig.heatSize = tonumber(d.olympicsConfig.heatSize) or 2
    d.olympicsConfig.heatLimitSeconds = tonumber(d.olympicsConfig.heatLimitSeconds) or 600
    d.scenarioPresetId = S.CUSTOM
    return d
end

local function trim(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$"))
end
S.Trim = trim

-- The EVENT_UPDATE_DEFINITION payload for a draft. Zone, hotspots,
-- teams and roster have their own server commands and are not sent.
function S.Payload(d)
    local items = {}
    for _, row in ipairs(d.rewards.items or {}) do
        local itemFullType = trim(row.itemFullType)
        if itemFullType ~= "" then
            items[#items + 1] = { itemFullType = itemFullType, count = math.max(1, math.floor(tonumber(row.count) or 1)) }
        end
    end
    local notes = {}
    for _, note in ipairs(d.objectiveNotes or {}) do
        local text = trim(type(note) == "table" and note.text or note)
        if text ~= "" then notes[#notes + 1] = { text = text } end
    end

    return {
        id = d.id,
        name = trim(d.name),
        eventType = d.eventType or "HORDE_SURVIVAL",
        -- A nil mode is not sent by the transport, so an admin switching
        -- back to Custom would keep the old mode. "NONE" is not a mode,
        -- so the server's sanitizeModeAndVariant clears it.
        mode = d.mode or "NONE",
        variant = d.variant,
        modifiers = { NAKED_AND_AFRAID = d.modifiers.NAKED_AND_AFRAID == true },
        captureConfig = {
            flagItemFullType = trim(d.captureConfig.flagItemFullType),
            autoReturnSeconds = tonumber(d.captureConfig.autoReturnSeconds) or 90,
        },
        -- Recipes are only an autofill here. Sending a preset id would
        -- re-run the v1 migration and can flag the event for review.
        scenarioPresetId = S.CUSTOM,
        loadout = d.loadout or "NONE",
        difficulty = d.difficulty or "NORMAL",
        threats = (function()
            local out = {}
            for _, threat in ipairs(Shared.EventThreatOrder or {}) do out[threat] = d.threats[threat] == true end
            return out
        end)(),
        survivorConfig = { lastStanding = d.survivorConfig.lastStanding == true },
        classicScenario = d.classicScenario,
        olympicsConfig = {
            heatSize = math.max(1, math.min(4, math.floor(tonumber(d.olympicsConfig.heatSize) or 2))),
            heatLimitSeconds = math.max(60, math.floor(tonumber(d.olympicsConfig.heatLimitSeconds) or 600)),
            discipline = d.olympicsConfig.discipline,
        },
        scopeType = d.scopeType,
        maxRounds = math.max(1, math.min(S.MAX_ROUNDS, math.floor(tonumber(d.maxRounds) or 1))),
        spawnRules = {
            baseSpawnRadius = tonumber(d.spawnRules.baseSpawnRadius) or 40,
            escalationEnabled = d.spawnRules.escalationEnabled == true,
        },
        directorType = d.directorType,
        zombieTheme = { themeId = d.zombieTheme.themeId or "RANDOM" },
        environment = { timeOfDay = d.environment.timeOfDay, weatherPreset = d.environment.weatherPreset },
        ruleType = d.ruleType,
        combatRules = {
            allowLeaveZone = d.combatRules.allowLeaveZone == true,
            pvpAllowedInZone = d.combatRules.pvpAllowedInZone == true,
        },
        timerType = d.timerType,
        duration = {
            enabled = d.duration.enabled == true,
            durationSeconds = math.max(0, math.floor(tonumber(d.duration.durationSeconds) or 0)),
            expiryBehavior = d.duration.expiryBehavior or "WIN",
        },
        roundDuration = {
            enabled = d.roundDuration.enabled == true,
            durationSeconds = math.max(0, math.floor(tonumber(d.roundDuration.durationSeconds) or 0)),
        },
        objectiveTypes = copyList(d.objectiveTypes),
        objectives = copy(d.objectives),
        objectiveNotes = notes,
        outcomeTypes = copyList(d.outcomeTypes),
        winConditions = copy(d.winConditions),
        failConditions = copy(d.failConditions),
        rewardDeliveryMethod = d.rewardDeliveryMethod,
        rewardItems = items,
        narrative = {
            briefing = d.narrative.briefing or "",
            winText = d.narrative.winText or "",
            failText = d.narrative.failText or "",
        },
    }
end

------------------------------------------------------------
-- CHECKLIST
------------------------------------------------------------

local function toSet(list)
    local set = {}
    for _, value in ipairs(list or {}) do set[value] = true end
    return set
end

local function hotspotLabel(hotspotType)
    return (Shared.EventHotspotTypeLabels or {})[hotspotType] or tostring(hotspotType)
end

-- Same matching as the server's EventHotspotService.FindHotspot: a
-- round or team asked for must match exactly.
local function hasHotspot(d, hotspotType, round, teamId)
    for _, hotspot in ipairs(d.hotspots or {}) do
        if hotspot.active ~= false and hotspot.type == hotspotType
            and (round == nil or tonumber(hotspot.roundNumber) == round)
            and (teamId == nil or tostring(hotspot.teamId) == tostring(teamId)) then
            return true
        end
    end
    return false
end

local function countHotspots(d, hotspotType)
    local count = 0
    for _, hotspot in ipairs(d.hotspots or {}) do
        if hotspot.active ~= false and hotspot.type == hotspotType then count = count + 1 end
    end
    return count
end

------------------------------------------------------------
-- THE OLYMPICS COURSE
------------------------------------------------------------

-- The metadata a new station of `task` is drawn with.
function S.StationMetadata(task)
    local defaults = (Shared.EventOlympicTasks or {})[task] or {}
    return { task = task, itemType = defaults.itemType, count = defaults.count or 1, kit = copyList(defaults.kit) }
end

local function stationsOf(d)
    local stations = {}
    for _, hotspot in ipairs(d.hotspots or {}) do
        if hotspot.active ~= false and hotspot.type == "OLYMPIC_STATION" then stations[#stations + 1] = hotspot end
    end
    table.sort(stations, function(a, b) return (tonumber(a.roundNumber) or 0) < (tonumber(b.roundNumber) or 0) end)
    return stations
end
S.OlympicStations = stationsOf

-- The next piece of the course to draw: start line, the template's
-- stations in order (each with its drop zone or target range), then
-- the finish line.
local function nextCoursePiece(d)
    if not hasHotspot(d, "OLYMPIC_START") then return { type = "OLYMPIC_START" } end
    local discipline = (Shared.EventOlympicDisciplines or {})[d.olympicsConfig and d.olympicsConfig.discipline or "OBSTACLE"]
    local planned = discipline and discipline.stations or {}
    local byNumber = {}
    for _, station in ipairs(stationsOf(d)) do byNumber[tonumber(station.roundNumber)] = station end
    local last = math.max(#planned, #stationsOf(d))
    for number = 1, last do
        local station = byNumber[number]
        if not station and planned[number] then
            return { type = "OLYMPIC_STATION", round = number, metadata = S.StationMetadata(planned[number]) }
        end
        local task = station and station.metadata and station.metadata.task
        if task == "CARRY" and not hasHotspot(d, "OLYMPIC_DROP", number) then return { type = "OLYMPIC_DROP", round = number } end
        if task == "SHOOT" and not hasHotspot(d, "OLYMPIC_TARGETS", number) then return { type = "OLYMPIC_TARGETS", round = number } end
    end
    if not hasHotspot(d, "OLYMPIC_FINISH") then return { type = "OLYMPIC_FINISH" } end
    return nil
end

-- The first hotspot the mode still needs, as { type, round, teamId,
-- teamName, metadata }, or nil. Drives the Area step's "Draw next
-- needed" button.
function S.NextHotspotNeeded(d)
    if d.mode == "OLYMPICS" then return nextCoursePiece(d) end
    local objectives = toSet(d.objectiveTypes)
    local rounds = math.max(1, math.min(S.MAX_ROUNDS, math.floor(tonumber(d.maxRounds) or 1)))
    if d.mode == "CAPTURE" and d.variant == "TEAM_CTF" then
        for round = 1, rounds do
            for _, team in ipairs(d.teams or {}) do
                if not hasHotspot(d, "TEAM_BASE", round, team.id) then
                    return { type = "TEAM_BASE", round = round, teamId = team.id, teamName = team.name }
                end
            end
        end
    elseif d.mode == "CAPTURE" then
        for round = 1, rounds do
            if not hasHotspot(d, "CAPTURE_ITEM", round) then return { type = "CAPTURE_ITEM", round = round } end
            if not hasHotspot(d, "DELIVERY_POINT", round) then return { type = "DELIVERY_POINT", round = round } end
        end
    end
    -- The server checks these for every mode, Team CTF included; FFA
    -- Capture's per-round hotspots above already cover them.
    if not (d.mode == "CAPTURE" and d.variant ~= "TEAM_CTF") then
        if d.mode == "EXTRACTION" and d.variant == "HEIST" and not hasHotspot(d, "BANDIT_VEHICLE") and not hasHotspot(d, "BANDIT_CAMP") then
            return { type = "BANDIT_VEHICLE" }
        end
        if objectives.RETRIEVE and not hasHotspot(d, "CAPTURE_ITEM") and not hasHotspot(d, "RESCUE_OBJECTIVE")
            and not hasHotspot(d, "BANDIT_VEHICLE") and not hasHotspot(d, "BANDIT_CAMP") then
            return { type = "CAPTURE_ITEM" }
        end
        if objectives.DELIVER and not hasHotspot(d, "DELIVERY_POINT") then return { type = "DELIVERY_POINT" } end
    end
    if objectives.HOLD_AREA and countHotspots(d, "HILL_LOCATION") < rounds then
        return { type = "HILL_LOCATION", round = countHotspots(d, "HILL_LOCATION") + 1 }
    end
    if d.mode == "EXTRACTION" and not hasHotspot(d, "EXTRACTION_POINT") then
        return { type = "EXTRACTION_POINT" }
    end
    if d.scopeType == "HOTSPOTS" and countHotspots(d, "ZOMBIE_SPAWN") == 0 and #(d.hotspots or {}) == 0 then
        return { type = "ZOMBIE_SPAWN" }
    end
    return nil
end

function S.DescribeHotspotNeed(need)
    if not need then return nil end
    local text = hotspotLabel(need.type)
    if need.metadata and need.metadata.task then
        text = text .. " (" .. tostring(((Shared.EventOlympicTasks or {})[need.metadata.task] or {}).label or need.metadata.task) .. ")"
    end
    if need.teamName or need.teamId then text = text .. " for " .. tostring(need.teamName or need.teamId) end
    if need.round then text = text .. (need.type:find("^OLYMPIC") and ", station " or ", round ") .. need.round end
    return text
end

local function formatMinutes(seconds)
    return tostring(math.floor((tonumber(seconds) or 0) / 60)) .. " min"
end

-- Returns { { step = id, text = sentence, tip = true|nil }, ... }.
-- Entries without tip block validation; tips are advice only.
function S.Check(d)
    local issues = {}
    local function need(step, text) issues[#issues + 1] = { step = step, text = text } end
    local function tip(step, text) issues[#issues + 1] = { step = step, text = text, tip = true } end

    local mode, variant = d.mode, d.variant
    local objectives = toSet(d.objectiveTypes)
    local rounds = math.max(1, math.min(S.MAX_ROUNDS, math.floor(tonumber(d.maxRounds) or 1)))

    -- Mode
    if trim(d.name) == "" then need("mode", "Give the event a name.") end
    if d.migrationStatus == "LEGACY_REVIEW_REQUIRED" and not mode then
        need("mode", "This event came from an old preset that no longer maps to a mode. Pick a game mode (or Custom) and save.")
    end
    local variants = S.Variants(mode)
    if variants and not toSet(variants)[variant] then need("mode", "Choose a variant for " .. S.ModeLabel(mode) .. ".") end
    if S.UsesTeams(mode, variant) and #(d.teams or {}) < 2 then
        need("mode", "Create at least 2 teams (Teams: 2, then Set teams).")
    end
    if mode == "CAPTURE" and trim(d.captureConfig.flagItemFullType) == "" then
        need("mode", "Choose the flag item players carry, e.g. a full item type like Base.Hat_Beret.")
    end
    if d.modifiers.NAKED_AND_AFRAID then
        local ok, why = S.NakedCompatible(mode, variant)
        if not ok then need("mode", "Naked and Afraid cannot be used here: " .. why) end
    end

    -- Area
    if d.scopeType == "ZONE" and not d.zoneId then
        need("area", "Draw the event zone on the map (or Use area around me).")
    end
    if mode == "ADVENTURE" and d.scopeType ~= "ZONE" then
        need("area", "Adventure places everything inside a zone. Set the area to Contained Event Zone.")
    end
    local active = 0
    for _, hotspot in ipairs(d.hotspots or {}) do
        if hotspot.active ~= false then active = active + 1 end
    end
    if d.scopeType == "HOTSPOTS" and active == 0 then
        need("area", "Place at least one hotspot: the event only happens at its hotspots.")
    end
    if mode == "CAPTURE" and variant == "TEAM_CTF" then
        local missing = 0
        for _, team in ipairs(d.teams or {}) do
            for round = 1, rounds do
                if not hasHotspot(d, "TEAM_BASE", round, team.id) then missing = missing + 1 end
            end
        end
        if missing > 0 then
            need("area", "Place a Team Base for every team in every round (" .. missing .. " missing).")
        end
    elseif mode == "CAPTURE" then
        for round = 1, rounds do
            if not hasHotspot(d, "CAPTURE_ITEM", round) then
                need("area", "Place a Capture Item hotspot (flag spawn) for round " .. round .. ".")
                break
            end
        end
        for round = 1, rounds do
            if not hasHotspot(d, "DELIVERY_POINT", round) then
                need("area", "Place a Delivery Point hotspot for round " .. round .. ".")
                break
            end
        end
    end
    -- EventHotspotService.ValidateDefinition checks these for every
    -- mode, Team CTF included; FFA's per-round checks above cover them.
    if not (mode == "CAPTURE" and variant ~= "TEAM_CTF") then
        if objectives.RETRIEVE and not hasHotspot(d, "CAPTURE_ITEM") and not hasHotspot(d, "RESCUE_OBJECTIVE")
            and not hasHotspot(d, "BANDIT_VEHICLE") and not hasHotspot(d, "BANDIT_CAMP") and variant ~= "HEIST" then
            need("area", "Place a Capture Item or Rescue hotspot: the Retrieve goal needs something to grab.")
        end
        if objectives.DELIVER and not hasHotspot(d, "DELIVERY_POINT") then
            need("area", "Place a Delivery Point hotspot: the Deliver goal needs a destination.")
        end
    end
    if objectives.HOLD_AREA then
        local hills = countHotspots(d, "HILL_LOCATION")
        if hills < rounds then
            need("area", "Place one Hill Location per round (" .. hills .. " of " .. rounds .. " placed).")
        elseif hills > S.MAX_ROUNDS then
            need("area", "Remove Hill Locations: at most " .. S.MAX_ROUNDS .. " are allowed.")
        end
    end
    if mode == "EXTRACTION" and not hasHotspot(d, "EXTRACTION_POINT") then
        need("area", "Place an Extraction Point hotspot: players win by reaching it when the evac arrives.")
    end
    if mode == "OLYMPICS" then
        if not hasHotspot(d, "OLYMPIC_START") then need("area", "Draw the start line.") end
        for _, station in ipairs(stationsOf(d)) do
            local meta = station.metadata or {}
            local number = tonumber(station.roundNumber)
            if meta.task == "CARRY" and not hasHotspot(d, "OLYMPIC_DROP", number) then
                need("area", "Station " .. number .. " (heavy lift) needs its drop zone.")
            end
            if meta.task == "SHOOT" and not hasHotspot(d, "OLYMPIC_TARGETS", number) then
                need("area", "Station " .. number .. " (shooting) needs its target range.")
            end
        end
        local piece = nextCoursePiece(d)
        if piece and piece.type == "OLYMPIC_STATION" then
            need("area", "Draw the rest of the course: next is " .. S.DescribeHotspotNeed(piece) .. ".")
        end
        if not hasHotspot(d, "OLYMPIC_FINISH") then need("area", "Draw the finish line.") end
    end
    if d.scopeType ~= "ZONE" and mode ~= "OLYMPICS" and not hasHotspot(d, "PLAYER_SPAWN") and not hasHotspot(d, "TEAM_SPAWN") then
        tip("area", "Place a Player Spawn so people arrive somewhere sensible. Without one they arrive near the middle of your hotspots.")
    end
    if (d.scopeType == "OPEN_MAP" or d.scopeType == "HOTSPOTS") and not mode and not hasHotspot(d, "ZOMBIE_SPAWN") then
        tip("area", "Without a zone, zombies only spawn at Zombie Spawn hotspots. Consider placing one.")
    end

    -- Rules and time
    if d.timerType == "ROUND_TIMER" then
        if not d.roundDuration.enabled or (tonumber(d.roundDuration.durationSeconds) or 0) <= 0 then
            need("rules", "Set a Round length: the Round Timer ends each round after it.")
        end
    elseif d.timerType and d.timerType ~= "NONE" then
        if not d.duration.enabled or (tonumber(d.duration.durationSeconds) or 0) <= 0 then
            need("rules", "Set an Event length: the " .. tostring((Shared.EventTimerTypeLabels or {})[d.timerType] or d.timerType) .. " timer needs one.")
        end
    end
    if mode == "SURVIVOR_RUN" and not d.duration.enabled then
        need("rules", "Survivor Run needs an Event length: surviving until it runs out is how players win.")
    end
    if mode == "EXTRACTION" and not (d.duration.enabled and (tonumber(d.duration.durationSeconds) or 0) > 0) then
        need("rules", "Extraction needs an Event length: the evac arrives in its last minutes.")
    end
    -- A classic event must have some way to finish.
    if not mode and (d.timerType == "NONE" and not d.duration.enabled)
        and #(d.winConditions or {}) == 0 and #(d.failConditions or {}) == 0 and #(d.objectives or {}) == 0 then
        tip("rules", "Nothing ends this event on its own: set a timer, an automatic check (Goals) or story stages (Story), or end it yourself from the Director panel.")
    end
    if (mode == "CHASE" or mode == "CAPTURE" or mode == "KING_OF_THE_HILL") and not d.modifiers.NAKED_AND_AFRAID then
        tip("mode", "Players can kill each other here, and a death is permanent. Naked and Afraid keeps everyone's gear safe in escrow.")
    end
    if mode == "EXTRACTION" and variant == "FIRE_SALE" and countHotspots(d, "EXTRACTION_POINT") < 2 then
        tip("area", "Fire Sale plays best with several Extraction Points: one is clear, the rest get a horde.")
    end
    if mode == "EXTRACTION" and variant == "HEIST" and not hasHotspot(d, "BANDIT_VEHICLE") and not hasHotspot(d, "BANDIT_CAMP") then
        need("area", "The Heist needs a Getaway Car (or a Bandit Camp): that's where the crew and the gold are.")
    end
    if mode == "EXTRACTION" and variant == "HEIST" and not hasHotspot(d, "NARRATIVE_LOCATION") then
        tip("area", "Leave a trail: Narrative hotspots with clues (\"tyre tracks heading north\") lead players to the getaway car.")
    end
    if d.threats.FIRES then
        tip("zombies", "Fires are real: they spread and burn buildings down. Pick a place you don't mind losing.")
    end
    if d.loadout ~= "NONE" and d.modifiers.NAKED_AND_AFRAID then
        tip("mode", "The starting loadout already decides what players carry; Naked and Afraid only applies without one.")
    end
    if mode == "ADVENTURE" and trim(d.captureConfig.flagItemFullType) == "" then
        tip("mode", "Capture the Flag is only in Adventure's roll if you set a flag item. Pick Capture the Flag once to set one, then switch back.")
    end
    if d.ruleType == "CUSTOM" then
        tip("rules", "Custom rules: only the Allow PvP tick decides whether players can hurt each other.")
    end

    -- Goals
    if #(d.objectiveTypes or {}) == 0 then need("goals", "Tick at least one objective type.") end
    if #(d.outcomeTypes or {}) == 0 then need("goals", "Tick at least one way to win.") end
    for _, objectiveType in ipairs(Shared.EventObjectiveTypeOrder or {}) do
        if S.RequiredObjectives(d)[objectiveType] and not objectives[objectiveType] then
            need("goals", S.ModeLabel(mode) .. " needs the "
                .. tostring((Shared.EventObjectiveTypeLabels or {})[objectiveType] or objectiveType) .. " objective ticked.")
        end
    end

    -- Story
    local seen = {}
    for index, stage in ipairs(d.objectives or {}) do
        local name = (stage.name and stage.name ~= "") and stage.name or ("Stage " .. index)
        if seen[stage.id] then need("story", "Two stages share one id; remove and re-add \"" .. name .. "\".") end
        seen[stage.id] = true
        if #(stage.triggers or {}) == 0 then
            need("story", "Stage \"" .. name .. "\" has no triggers. Add one or remove the stage.")
        end
        for _, trigger in ipairs(stage.triggers or {}) do
            if trigger.activationMode == "PROXIMITY" then
                local found = false
                for _, hotspot in ipairs(d.hotspots or {}) do
                    if hotspot.id == trigger.hotspotId then found = true end
                end
                if not found then
                    need("story", "Stage \"" .. name .. "\" waits for a hotspot that was deleted. Remove that trigger.")
                end
            end
        end
    end
    if mode == "EXTRACTION" and variant == "PRISON_BREAK" and #(d.objectives or {}) < 2 then
        tip("story", "Prison Break: add a stage that completes at the item hotspot, then one that completes at the Extraction Point.")
    end
    if trim(d.narrative.briefing) == "" then
        tip("story", "Write a briefing so players know where to go and what to do.")
    end

    return issues
end

function S.Blocking(issues)
    local count = 0
    for _, issue in ipairs(issues or {}) do
        if not issue.tip then count = count + 1 end
    end
    return count
end

function S.IssuesForStep(issues, stepId)
    local out = {}
    for _, issue in ipairs(issues or {}) do
        if issue.step == stepId then out[#out + 1] = issue end
    end
    return out
end

------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------

S.Pipeline = {
    { status = "DRAFT", label = "Draft" },
    { status = "READY", label = "Ready" },
    { status = "ANNOUNCED", label = "Announced" },
    { status = "JOINING", label = "Joining" },
    { status = "ACTIVE", label = "Live" },
    { status = "COMPLETE", label = "Finished" },
}

-- Statuses whose configuration the server accepts edits for.
S.Editable = { DRAFT = true, READY = true }

-- The one next thing to do for a status: the Launch step's big button.
S.NextAction = {
    DRAFT = { id = "validate", label = "Check and mark ready",
        hint = "Saves your changes and asks the server to verify the event." },
    VALIDATING = { label = "Checking...", hint = "The server is verifying the event." },
    READY = { id = "announce", label = "Announce to the server",
        hint = "Shows the briefing to everyone online. Editing is locked from here until the event is reset." },
    ANNOUNCED = { id = "join", label = "Open joining",
        hint = "Every online player is asked to sign up. Give them a minute before you begin." },
    JOINING = { id = "start", label = "Begin the event",
        hint = "Brings everyone who signed up in and starts the game. It runs itself from here." },
    ACTIVE = { id = "director", label = "Open Director controls",
        hint = "The event is live. Director controls spawn waves, add time, send hints and end it." },
    ENDING = { label = "Ending...", hint = "Wrapping up and paying out." },
    CLEANUP = { label = "Cleaning up...", hint = "Wrapping up and paying out." },
    COMPLETE = { id = "reset", label = "Reset for reuse",
        hint = "Returns the event to Draft so it can be edited and run again." },
}

function S.StatusLabel(status)
    for _, stage in ipairs(S.Pipeline) do
        if stage.status == status then return stage.label end
    end
    return tostring(status or "?")
end

S.StatusColors = {
    DRAFT = { 0.72, 0.72, 0.72 }, VALIDATING = { 0.72, 0.72, 0.72 },
    READY = { 0.45, 0.88, 0.45 }, ANNOUNCED = { 0.50, 0.75, 1.00 }, JOINING = { 0.50, 0.75, 1.00 },
    ACTIVE = { 1.00, 0.82, 0.30 }, ENDING = { 1.00, 0.68, 0.40 }, CLEANUP = { 1.00, 0.68, 0.40 },
    COMPLETE = { 0.70, 0.66, 0.95 },
}

------------------------------------------------------------
-- SERVER REASONS
------------------------------------------------------------

S.Reasons = {
    NAME_REQUIRED = "the event needs a name (Mode step)",
    NO_OBJECTIVE_TYPE = "tick an objective type (Goals step)",
    NO_OUTCOME_TYPE = "tick a way to win (Goals step)",
    ROUND_TIMER_DURATION_REQUIRED = "set a Round length (Rules & Time step)",
    INVALID_ROUND_DURATION = "the Round length must be above zero (Rules & Time step)",
    TIMER_DURATION_REQUIRED = "set an Event length (Rules & Time step)",
    INVALID_DURATION = "the Event length must be above zero (Rules & Time step)",
    NO_ZONE = "draw the event zone (Area step)",
    ZONE_INACTIVE = "the event zone was removed; draw it again (Area step)",
    HOTSPOT_SCOPE_REQUIRES_HOTSPOT = "place at least one hotspot (Area step)",
    CAPTURE_OR_RESCUE_HOTSPOT_REQUIRED = "place a Capture Item or Rescue hotspot (Area step)",
    DELIVERY_HOTSPOT_REQUIRED = "place a Delivery Point hotspot (Area step)",
    HILL_HOTSPOT_REQUIRED = "place a Hill Location hotspot (Area step)",
    HILL_HOTSPOTS_REQUIRED_FOR_EACH_ROUND = "place one Hill Location per round (Area step)",
    TOO_MANY_HILL_HOTSPOTS = "too many Hill Locations (Area step)",
    LEGACY_DEFINITION_REQUIRES_REVIEW = "pick a game mode for this old event (Mode step)",
    UNKNOWN_MODE = "Naked and Afraid needs a game mode (Mode step)",
    ADVENTURE_ROLL_PENDING = "Adventure cannot use Naked and Afraid (Mode step)",
    INCOMPATIBLE_EXTRACTION_LOADOUT = "this Extraction variant cannot use Naked and Afraid (Mode step)",
    TEAM_COUNT_TOO_LOW = "create at least 2 teams (Mode step)",
    CAPTURE_VARIANT_REQUIRED = "choose a Capture variant (Mode step)",
    CAPTURE_FLAG_ITEM_REQUIRED = "choose the flag item (Mode step)",
    CAPTURE_TEAM_CTF_REQUIRES_TEAMS = "create at least 2 teams (Mode step)",
    CAPTURE_TEAM_BASE_MISSING = "place a Team Base for every team and round (Area step)",
    CAPTURE_FFA_FLAG_SPAWN_MISSING = "place a Capture Item for every round (Area step)",
    CAPTURE_FFA_DELIVERY_POINT_MISSING = "place a Delivery Point for every round (Area step)",
    KOTH_REQUIRES_HOLD_AREA_OBJECTIVE = "tick Hold Area (Goals step)",
    CHASE_REQUIRES_CHASE_TARGET_OBJECTIVE = "tick Chase Target (Goals step)",
    EXTRACTION_VARIANT_REQUIRED = "choose an Extraction variant (Mode step)",
    EXTRACTION_REQUIRES_EXTRACTION_POINT_HOTSPOT = "place an Extraction Point (Area step)",
    HEIST_REQUIRES_BANDITS = "place a Getaway Car or a Bandit Camp (Area step)",
    SURVIVOR_RUN_REQUIRES_DURATION = "set an Event length (Rules & Time step)",
    EXTRACTION_REQUIRES_DURATION = "set an Event length: the evac arrives near its end (Rules & Time step)",
    OLYMPICS_START_REQUIRED = "draw the start line (Area step)",
    OLYMPICS_FINISH_REQUIRED = "draw the finish line (Area step)",
    OLYMPICS_DROP_REQUIRED = "a heavy-lift station needs its drop zone (Area step)",
    OLYMPICS_TARGETS_REQUIRED = "a shooting station needs its target range (Area step)",
    OLYMPICS_STATION_ITEM_REQUIRED = "a course station has no item set (Area step)",
    ADVENTURE_REQUIRES_ZONE = "Adventure needs an event zone (Area step)",
    DUPLICATE_OBJECTIVE_ID = "two story stages share an id (Story step)",
    OBJECTIVE_HAS_NO_TRIGGERS = "a story stage has no triggers (Story step)",
    TRIGGER_HOTSPOT_NOT_FOUND = "a story trigger uses a deleted hotspot (Story step)",
    NOT_EDITABLE = "the event is announced or running; reset it before editing",
    NOT_DRAFT = "only a Draft can be checked",
    DEFINITION_NOT_FOUND = "the event no longer exists; refresh the list",
}

-- Turns a server reason (possibly a comma-separated list) into words.
function S.Explain(reason)
    local parts = {}
    for code in tostring(reason or "UNKNOWN"):gmatch("[^,]+") do
        local text = S.Reasons[code]
        if not text and code:match("^EXTRACTION_REQUIRES_(.+)_OBJECTIVE$") then
            local objectiveType = code:match("^EXTRACTION_REQUIRES_(.+)_OBJECTIVE$")
            text = "tick " .. tostring((Shared.EventObjectiveTypeLabels or {})[objectiveType] or objectiveType) .. " (Goals step)"
        end
        parts[#parts + 1] = text or code
    end
    return table.concat(parts, "; ")
end

------------------------------------------------------------
-- PLAIN-LANGUAGE HELP
------------------------------------------------------------

S.ScopeHelp = {
    ZONE = "One zone you draw. Everything happens inside it.",
    HOTSPOTS = "Only small separate hotspots, no big zone.",
    OPEN_MAP = "The whole map. Hotspots mark the key places.",
}

S.RuleHelp = {
    PVE = "Players cannot hurt each other. Zombies can hurt players.",
    PVP = "Players can hurt each other.",
    TEAM = "Players can hurt each other (team damage rules are not in yet, so this is the same as PvP).",
    FREE_FOR_ALL = "Everyone can hurt everyone.",
    NO_COMBAT = "Nobody takes damage inside the event, not even from zombies.",
    CUSTOM = "Only the Allow PvP tick below decides.",
}

S.TimerHelp = {
    NONE = "No clock. The event ends when a goal or automatic check is met, or when you end it.",
    COUNTDOWN = "The event ends when the Event length runs out.",
    HOLD_TIMER = "Uses the Event length, like Countdown.",
    ROUND_TIMER = "Each round ends when the Round length runs out; the event ends after the last round.",
    ESCALATION_TIMER = "Uses the Event length, like Countdown.",
}

S.DirectorHelp = {
    ZOMBIE_WAVES = "Zombies only come when you press buttons in the Director panel.",
    ZOMBIE_ESCALATION = "Bursts of zombies arrive on their own and grow bigger over time.",
    ZOMBIE_PERIMETER = "Building alarms go off around the area to draw zombies in.",
    ZOMBIE_RANDOM = "Random bursts, walk-ins and alarms at random times.",
}

S.HotspotHelp = {
    ZOMBIE_SPAWN = "Zombies spawn here when there is no zone to spawn around.",
    ZOMBIE_AMBUSH = "A room full of zombies that wakes the first time someone comes near.",
    CAPTURE_ITEM = "Where the item or flag to grab appears.",
    DELIVERY_POINT = "Where carried items must be brought.",
    RESCUE_OBJECTIVE = "Someone or something to rescue. Counts for the Retrieve goal.",
    OBJECTIVE_LOCATION = "A general goal spot for story triggers.",
    PLAYER_SPAWN = "A start position for participants.",
    TEAM_SPAWN = "A start position for one team.",
    HILL_LOCATION = "The hill for one round (Hold Area goal).",
    NARRATIVE_LOCATION = "Shows your text when a player walks in. Clues stay on the player's HUD as a button that shows them again.",
    TEAM_BASE = "A team's base: its flag spawns here and stolen flags are brought here.",
    EXTRACTION_POINT = "Reaching it ends Prison Break.",
    BANDIT_CAMP = "A bandit crew waits here, calm until someone comes close or opens fire. Set how many.",
    BANDIT_VEHICLE = "The bandits' getaway car is parked here with their loot in the trunk, and the crew guarding it.",
}

S.DeliveryHelp = {
    ADMIN_DELIVERY = "You hand prizes over yourself. They wait in the list below until you mark them delivered.",
    PO_BOX_DELIVERY = "Prizes are mailed to the winner's PO Box, or held in escrow until they have one.",
}

------------------------------------------------------------
-- SUMMARY (locked steps and the Launch overview)
------------------------------------------------------------

local function labelOf(labels, key, fallback)
    return (labels or {})[key] or tostring(key or fallback or "-")
end

local function labelList(list, labels)
    local out = {}
    for _, key in ipairs(list or {}) do out[#out + 1] = labelOf(labels, key) end
    return #out > 0 and table.concat(out, ", ") or "none"
end

function S.Summary(d, stepId)
    local lines = {}
    local function add(text) lines[#lines + 1] = text end

    if stepId == "mode" then
        add("Name: " .. (trim(d.name) ~= "" and trim(d.name) or "(none)"))
        local _, variantLabels = S.Variants(d.mode)
        add("Mode: " .. S.ModeLabel(d.mode) .. (d.variant and (" / " .. labelOf(variantLabels, d.variant)) or ""))
        if S.UsesRounds(d.mode) then add("Rounds: " .. tostring(d.maxRounds or 1)) end
        if S.UsesTeams(d.mode, d.variant) then add("Teams: " .. #(d.teams or {})) end
        if d.mode == "CAPTURE" then add("Flag item: " .. (trim(d.captureConfig.flagItemFullType) ~= "" and d.captureConfig.flagItemFullType or "(none)")) end
        if d.classicScenario then add("Classic scenario: " .. tostring(((Shared.EventClassicScenarios or {})[d.classicScenario] or {}).label)) end
        add("Players start with: " .. tostring(((Shared.EventLoadouts or {})[d.loadout or "NONE"] or {}).label))
        if d.survivorConfig.lastStanding then add("Last one standing wins") end
        if d.modifiers.NAKED_AND_AFRAID then add("Naked and Afraid: on") end
        if d.mode == "OLYMPICS" then
            local discipline = (Shared.EventOlympicDisciplines or {})[d.olympicsConfig.discipline or "OBSTACLE"]
            add("Course: " .. (discipline and discipline.label or "custom"))
            add("Heats of " .. tostring(d.olympicsConfig.heatSize) .. ", " .. formatMinutes(d.olympicsConfig.heatLimitSeconds) .. " limit")
        end
    elseif stepId == "area" then
        add("Area: " .. labelOf(Shared.EventScopeTypeLabels, d.scopeType))
        if d.scopeType == "ZONE" then add("Zone: " .. (d.zoneId and "drawn" or "not drawn")) end
        local counts, order = {}, {}
        for _, hotspot in ipairs(d.hotspots or {}) do
            if hotspot.active ~= false then
                if not counts[hotspot.type] then order[#order + 1] = hotspot.type end
                counts[hotspot.type] = (counts[hotspot.type] or 0) + 1
            end
        end
        local parts = {}
        for _, hotspotType in ipairs(order) do parts[#parts + 1] = counts[hotspotType] .. "x " .. hotspotLabel(hotspotType) end
        add("Hotspots: " .. (#parts > 0 and table.concat(parts, ", ") or "none"))
        if d.mode == "OLYMPICS" then
            local course = {}
            for _, station in ipairs(stationsOf(d)) do
                local task = station.metadata and station.metadata.task or "CHECKPOINT"
                course[#course + 1] = tostring(station.roundNumber) .. ". " .. tostring(((Shared.EventOlympicTasks or {})[task] or {}).label or task)
            end
            add("Course: start > " .. (#course > 0 and (table.concat(course, " > ") .. " > ") or "") .. "finish")
        end
    elseif stepId == "rules" then
        add("Combat: " .. labelOf(Shared.EventRuleTypeLabels, d.ruleType))
        add("Timer: " .. labelOf(Shared.EventTimerTypeLabels, d.timerType))
        if d.duration.enabled then add("Event length: " .. formatMinutes(d.duration.durationSeconds)) end
        if d.timerType == "ROUND_TIMER" then add("Round length: " .. formatMinutes(d.roundDuration.durationSeconds)) end
        if d.environment.timeOfDay then add("Time of day: " .. tostring(d.environment.timeOfDay)) end
        if d.environment.weatherPreset then add("Weather: " .. tostring(d.environment.weatherPreset)) end
    elseif stepId == "zombies" then
        add("Director: " .. labelOf(Shared.EventDirectorTypeLabels, d.directorType))
        add("Theme: " .. labelOf(Shared.EventZombieThemeLabels, d.zombieTheme.themeId, "RANDOM"))
        add("Spawn radius: " .. tostring(d.spawnRules.baseSpawnRadius) .. " tiles")
        add("Difficulty: " .. tostring(((Shared.EventDifficulties or {})[d.difficulty or "NORMAL"] or {}).label))
        local threats = {}
        for _, threat in ipairs(Shared.EventThreatOrder or {}) do
            if d.threats[threat] then threats[#threats + 1] = Shared.EventThreats[threat].label end
        end
        add("Threats: " .. (#threats > 0 and table.concat(threats, ", ") or "none"))
    elseif stepId == "goals" then
        add("Objectives: " .. labelList(d.objectiveTypes, Shared.EventObjectiveTypeLabels))
        add("Ways to win: " .. labelList(d.outcomeTypes, Shared.EventOutcomeTypeLabels))
        add("Automatic checks: " .. (#d.winConditions + #d.failConditions))
    elseif stepId == "story" then
        add("Briefing: " .. (trim(d.narrative.briefing) ~= "" and "written" or "empty"))
        add("Checklist lines: " .. #(d.objectiveNotes or {}))
        add("Story stages: " .. #(d.objectives or {}))
    elseif stepId == "rewards" then
        local parts = {}
        for _, row in ipairs(d.rewards.items or {}) do
            if trim(row.itemFullType) ~= "" then parts[#parts + 1] = tostring(row.count or 1) .. "x " .. row.itemFullType end
        end
        add("Prizes: " .. (#parts > 0 and table.concat(parts, ", ") or "none"))
        add("Delivery: " .. labelOf(Shared.EventRewardDeliveryMethodLabels, d.rewardDeliveryMethod))
    elseif stepId == "players" then
        local count = 0
        for _, selected in pairs(d.participants or {}) do
            if selected == true then count = count + 1 end
        end
        add("Hand-picked roster: " .. (count > 0 and tostring(count) or "none (everyone online is invited)"))
    end
    return lines
end

------------------------------------------------------------
-- DRAFT BOOKKEEPING
------------------------------------------------------------

local function serialize(value, out)
    if type(value) ~= "table" then
        out[#out + 1] = tostring(value)
        return
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    out[#out + 1] = "{"
    for _, key in ipairs(keys) do
        out[#out + 1] = tostring(key) .. "="
        serialize(value[key], out)
        out[#out + 1] = ","
    end
    out[#out + 1] = "}"
end

-- Equal signatures mean saving would change nothing.
function S.Signature(d)
    local out = {}
    serialize(S.Payload(d), out)
    return table.concat(out)
end

-- Fields the server changes through their own commands (zone,
-- hotspots, teams, roster, lifecycle). Copied into a draft whenever
-- the server sends a newer definition, without touching unsaved edits.
S.ServerFields = { "status", "zoneId", "hotspots", "teams", "participants", "migrationStatus", "legacyPresetId", "eventType" }

function S.MergeServerFields(draft, definition)
    for _, key in ipairs(S.ServerFields) do draft[key] = copy(definition[key]) end
    draft.hotspots = draft.hotspots or {}
    draft.teams = draft.teams or {}
    draft.participants = draft.participants or {}
end

S.FormatMinutes = formatMinutes
S.HotspotLabel = hotspotLabel

return S
