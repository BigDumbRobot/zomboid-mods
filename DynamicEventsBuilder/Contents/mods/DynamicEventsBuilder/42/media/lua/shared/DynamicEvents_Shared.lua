-- DynamicEvents_Shared.lua
--
-- Event-framework constants and preset tables copied verbatim out of
-- KIPN's shared/KIPN_Shared.lua when Dynamic Events was split out of KIPN.
-- Still written against the KIPN.Shared namespace; rename when this mod is
-- made standalone. See README.md.
--

KIPN = KIPN or {}
KIPN.Shared = KIPN.Shared or {}

--------------------------------------------------------------------
-- EVENT SCENARIOS: COMPOSABLE COMPONENTS
--
-- Small, independent building blocks an Event Definition selects
-- from, instead of one monolithic eventType owning everything.
-- Shared (not server-only) so the admin UI can render real picker
-- options and a Scenario Preset can auto-fill a selection --
-- both sides read the same canonical list, nothing is duplicated.
--
-- IMPORTANT -- IMPLEMENTATION STATUS:
--
-- These lists are captured, validated, and persisted on an Event
-- Definition (see KIPN_EventScenarioService.lua's sanitizeObjectiveTypes/
-- sanitizeTimerType/sanitizeOutcomeTypes). They do NOT yet have their
-- own mechanical evaluators/directors -- selecting "Retrieve" or
-- "Extraction" records the choice and shows it in the admin UI, but
-- nothing server-side currently acts on it. The only mechanically
-- live gameplay logic remains KIPN_ZombieDirector.lua's Horde
-- Survival spawnRules/winConditions/failConditions (registered
-- through KIPN_EventObjectiveRegistry.lua), which is unaffected by
-- this table. Building a director for each of these is future work.
--------------------------------------------------------------------

KIPN.Shared.EventObjectiveTypes = {
    RETRIEVE = "RETRIEVE",
    DELIVER = "DELIVER",
    HOLD_AREA = "HOLD_AREA",
    SURVIVE = "SURVIVE",
    LOCATE = "LOCATE",
    INTERACT = "INTERACT",
    ESCORT = "ESCORT",
    CHASE_TARGET = "CHASE_TARGET",
}

KIPN.Shared.EventObjectiveTypeLabels = {
    RETRIEVE = "Retrieve",
    DELIVER = "Deliver",
    HOLD_AREA = "Hold Area",
    SURVIVE = "Survive",
    LOCATE = "Locate",
    INTERACT = "Interact",
    ESCORT = "Escort",
    CHASE_TARGET = "Chase Target",
}

--------------------------------------------------------------------
-- EVENT SCENARIOS: SCOPE / HOTSPOTS / REWARD DELIVERY
--------------------------------------------------------------------

KIPN.Shared.EventScopeTypes = {
    ZONE = "ZONE",
    HOTSPOTS = "HOTSPOTS",
    OPEN_MAP = "OPEN_MAP",
}

KIPN.Shared.EventScopeTypeOrder = { "ZONE", "HOTSPOTS", "OPEN_MAP" }

KIPN.Shared.EventScopeTypeLabels = {
    ZONE = "Contained Event Zone",
    HOTSPOTS = "Independent Hotspots",
    OPEN_MAP = "Open Map",
}

KIPN.Shared.EventHotspotTypes = {
    ZOMBIE_SPAWN = "ZOMBIE_SPAWN",
    CAPTURE_ITEM = "CAPTURE_ITEM",
    DELIVERY_POINT = "DELIVERY_POINT",
    RESCUE_OBJECTIVE = "RESCUE_OBJECTIVE",
    OBJECTIVE_LOCATION = "OBJECTIVE_LOCATION",
    PLAYER_SPAWN = "PLAYER_SPAWN",
    TEAM_SPAWN = "TEAM_SPAWN",
    HILL_LOCATION = "HILL_LOCATION",
    NARRATIVE_LOCATION = "NARRATIVE_LOCATION",
    -- Phase 6: Team CTF's per-team base -- serves as BOTH that team's
    -- flag spawn area and its delivery target (see
    -- KIPN_EventCaptureService.lua). One per team per round, tagged
    -- with the hotspot's teamId field (see
    -- KIPN_EventHotspotService.lua's NormalizeHotspot()).
    TEAM_BASE = "TEAM_BASE",
    -- Phase 9: the evac/pickup zone a participant must reach to
    -- complete an Extraction-outcome scenario (Prison Break) -- see
    -- KIPN_EventExtractionService.lua. Authored as the PROXIMITY
    -- hotspot for that scenario's final ordered objective, same
    -- mechanism as any other proximity trigger.
    EXTRACTION_POINT = "EXTRACTION_POINT",
}

KIPN.Shared.EventHotspotTypeOrder = {
    "ZOMBIE_SPAWN", "CAPTURE_ITEM", "DELIVERY_POINT",
    "RESCUE_OBJECTIVE", "OBJECTIVE_LOCATION", "PLAYER_SPAWN",
    "TEAM_SPAWN", "HILL_LOCATION", "NARRATIVE_LOCATION", "TEAM_BASE",
    "EXTRACTION_POINT",
}

KIPN.Shared.EventHotspotTypeLabels = {
    ZOMBIE_SPAWN = "Zombie Spawn",
    CAPTURE_ITEM = "Capture Item",
    DELIVERY_POINT = "Delivery Point",
    RESCUE_OBJECTIVE = "Rescue / Lost Soldier",
    OBJECTIVE_LOCATION = "Objective Location",
    PLAYER_SPAWN = "Player Spawn",
    TEAM_SPAWN = "Team Spawn",
    HILL_LOCATION = "Hill Location",
    NARRATIVE_LOCATION = "Narrative Location",
    TEAM_BASE = "Team Base",
    EXTRACTION_POINT = "Extraction Point",
}

KIPN.Shared.EventRewardDeliveryMethods = {
    ADMIN_DELIVERY = "ADMIN_DELIVERY",
    PO_BOX_DELIVERY = "PO_BOX_DELIVERY",
}

KIPN.Shared.EventRewardDeliveryMethodOrder = { "ADMIN_DELIVERY", "PO_BOX_DELIVERY" }

KIPN.Shared.EventRewardDeliveryMethodLabels = {
    ADMIN_DELIVERY = "Admin Physical Delivery",
    PO_BOX_DELIVERY = "PO Box Delivery (Escrow if unavailable)",
}

KIPN.Shared.EventZombieThemes = {
    RANDOM = "RANDOM",
    MILITARY = "MILITARY",
    MEDICAL = "MEDICAL",
    MILITARY_HOSPITAL = "MILITARY_HOSPITAL",
    POLICE = "POLICE",
    FIRE_EMERGENCY = "FIRE_EMERGENCY",
    PRISON = "PRISON",
    CONSTRUCTION = "CONSTRUCTION",
    RURAL = "RURAL",
    INDUSTRIAL = "INDUSTRIAL",
    FORMAL = "FORMAL",
}

KIPN.Shared.EventZombieThemeOrder = {
    "RANDOM", "MILITARY", "MEDICAL", "MILITARY_HOSPITAL", "POLICE",
    "FIRE_EMERGENCY", "PRISON", "CONSTRUCTION", "RURAL", "INDUSTRIAL", "FORMAL",
}

KIPN.Shared.EventZombieThemeLabels = {
    RANDOM = "Random / Default",
    MILITARY = "Military",
    MEDICAL = "Medical",
    MILITARY_HOSPITAL = "Military Hospital",
    POLICE = "Police",
    FIRE_EMERGENCY = "Fire and Emergency",
    PRISON = "Prison",
    CONSTRUCTION = "Construction",
    RURAL = "Rural",
    INDUSTRIAL = "Industrial",
    FORMAL = "Formal",
}

KIPN.Shared.EventTimerTypes = {
    NONE = "NONE",
    COUNTDOWN = "COUNTDOWN",
    HOLD_TIMER = "HOLD_TIMER",
    ROUND_TIMER = "ROUND_TIMER",
    ESCALATION_TIMER = "ESCALATION_TIMER",
}

KIPN.Shared.EventTimerTypeLabels = {
    NONE = "None",
    COUNTDOWN = "Countdown",
    HOLD_TIMER = "Hold Timer",
    ROUND_TIMER = "Round Timer",
    ESCALATION_TIMER = "Escalation Timer",
}

KIPN.Shared.EventOutcomeTypes = {
    FIRST_TO_COMPLETE = "FIRST_TO_COMPLETE",
    LAST_ALIVE = "LAST_ALIVE",
    HOLD_DURATION = "HOLD_DURATION",
    EXTRACTION = "EXTRACTION",
    TIME_EXPIRED = "TIME_EXPIRED",
    MOST_ZOMBIE_KILLS = "MOST_ZOMBIE_KILLS",
    MOST_PLAYER_KILLS = "MOST_PLAYER_KILLS",
}

KIPN.Shared.EventOutcomeTypeLabels = {
    FIRST_TO_COMPLETE = "First To Complete",
    LAST_ALIVE = "Last Alive",
    HOLD_DURATION = "Hold Duration",
    EXTRACTION = "Extraction",
    TIME_EXPIRED = "Time Expired",
    MOST_ZOMBIE_KILLS = "Most Zombie Kills",
    MOST_PLAYER_KILLS = "Most Player Kills",
}

--------------------------------------------------------------------
-- EVENT SCENARIOS: RULES
--
-- Unlike Objective/Outcome Types (multi-select), a Rule is a single
-- choice -- an event is PvE, PvP, Team, Free-For-All, No-Combat, or
-- Custom, not several at once.
--
-- IMPLEMENTATION STATUS: PVE/PVP/FREE_FOR_ALL/CUSTOM all reduce to
-- the existing combatRules.pvpAllowedInZone toggle (already
-- mechanically enforced by KIPN_EventRuntimeService.lua's
-- Events.OnWeaponHitCharacter listener). NO_COMBAT is ALSO
-- mechanically enforced -- it blocks ALL damage inside the zone
-- (zombie included, not just PvP), not merely a label. TEAM is NOT
-- mechanically implemented -- there is no team roster/scoring system
-- yet, so selecting it currently behaves identically to PVP.
--------------------------------------------------------------------

KIPN.Shared.EventRuleTypes = {
    PVE = "PVE",
    PVP = "PVP",
    TEAM = "TEAM",
    FREE_FOR_ALL = "FREE_FOR_ALL",
    NO_COMBAT = "NO_COMBAT",
    CUSTOM = "CUSTOM",
}

KIPN.Shared.EventRuleTypeLabels = {
    PVE = "PvE",
    PVP = "PvP",
    TEAM = "Team",
    FREE_FOR_ALL = "Free For All",
    NO_COMBAT = "No Combat",
    CUSTOM = "Custom",
}

KIPN.Shared.EventRuleTypeOrder = { "PVE", "PVP", "TEAM", "FREE_FOR_ALL", "NO_COMBAT", "CUSTOM" }

--------------------------------------------------------------------
-- EVENT SCENARIOS: DIRECTORS
--
-- A single choice governing HOW the zombie director behaves when a
-- Definition's spawnRules.escalationEnabled is on (see
-- KIPN_ZombieDirector.lua's onTick). All four are mechanically
-- wired -- this is not a cosmetic label:
--
--   ZOMBIE_WAVES:      no passive automation at all -- the admin
--                       fires bursts/walk-ins manually via the live
--                       control panel, regardless of escalationEnabled.
--   ZOMBIE_ESCALATION: periodic tier-scaled bursts (the original
--                       passive-escalation behavior).
--   ZOMBIE_PERIMETER:  periodically re-triggers the zone's building
--                       alarm rather than spawning directly.
--   ZOMBIE_RANDOM:     fires a random control (burst/walk-in/alarm)
--                       at randomized intervals.
--------------------------------------------------------------------

KIPN.Shared.EventDirectorTypes = {
    ZOMBIE_WAVES = "ZOMBIE_WAVES",
    ZOMBIE_ESCALATION = "ZOMBIE_ESCALATION",
    ZOMBIE_PERIMETER = "ZOMBIE_PERIMETER",
    ZOMBIE_RANDOM = "ZOMBIE_RANDOM",
}

KIPN.Shared.EventDirectorTypeLabels = {
    ZOMBIE_WAVES = "Zombie Waves",
    ZOMBIE_ESCALATION = "Zombie Escalation",
    ZOMBIE_PERIMETER = "Zombie Perimeter",
    ZOMBIE_RANDOM = "Zombie Random",
}

KIPN.Shared.EventDirectorTypeOrder = { "ZOMBIE_WAVES", "ZOMBIE_ESCALATION", "ZOMBIE_PERIMETER", "ZOMBIE_RANDOM" }

--------------------------------------------------------------------
-- EVENT SCENARIOS: SCENARIO PRESETS
--
-- A Scenario Preset is an optional starting recipe composed from the
-- components above. It is applied client-side as an autofill recipe,
-- its recipe id is persisted for auditing/reopening, and every resulting
-- field remains editable afterward. See KIPN_EventScenarioAdminUI.lua's
-- onScenarioPresetChanged.
--------------------------------------------------------------------

KIPN.Shared.EventScenarioPresets = {

    CAPTURE = {
        label = "Capture",
        objectiveTypes = { "RETRIEVE", "DELIVER" },
        ruleType = "PVP",
        directorType = "ZOMBIE_WAVES",
        timerType = "COUNTDOWN",
        outcomeTypes = { "EXTRACTION" },
        pvpAllowedInZone = true,
    },

    KING_OF_THE_HILL = {
        label = "King of the Hill",
        objectiveTypes = { "HOLD_AREA" },
        ruleType = "PVP",
        directorType = "ZOMBIE_ESCALATION",
        timerType = "ROUND_TIMER",
        outcomeTypes = { "HOLD_DURATION" },
        pvpAllowedInZone = true,
        -- OPEN_MAP gives KOTH map-wide event rules without requiring a
        -- fragile giant rectangle; individual hills remain HILL_LOCATION
        -- hotspots selected round by round.
        scopeType = "OPEN_MAP",
        maxRounds = 10,
    },

    CHASE = {
        label = "Chase",
        objectiveTypes = { "CHASE_TARGET" },
        ruleType = "PVP",
        directorType = "ZOMBIE_WAVES",
        timerType = "ROUND_TIMER",
        outcomeTypes = { "LAST_ALIVE" },
        pvpAllowedInZone = true,
        scopeType = "OPEN_MAP",
        maxRounds = 3,
    },

    ADVENTURE = {
        label = "Adventure (randomized)",
        -- Randomized client-side at selection time rather than a
        -- fixed list -- see onScenarioPresetChanged's ADVENTURE
        -- branch. Held here only for the label/order.
        random = true,
    },

    --------------------------------------------------------------
    -- DERIVED FROM Contents/EXAMPLE/Pillow's Random Scenarios
    --
    -- 9 unique presets mapped from that mod's 10 single-player
    -- scenario files (HospitalChallenge and TheLastFlight reduce to
    -- the identical tuple below -- see HOSPITAL_WARD's comment).
    --------------------------------------------------------------

    ABANDONED_SOLDIER = {
        label = "Abandoned Soldier",
        objectiveTypes = { "SURVIVE" },
        ruleType = "PVE",
        directorType = "ZOMBIE_PERIMETER",
        timerType = "NONE",
        outcomeTypes = { "LAST_ALIVE" },
        pvpAllowedInZone = false,
    },

    DODGEBALL = {
        label = "Dodgeball of the Dead",
        objectiveTypes = { "SURVIVE" },
        ruleType = "NO_COMBAT",
        directorType = "ZOMBIE_RANDOM",
        timerType = "NONE",
        outcomeTypes = { "LAST_ALIVE" },
        pvpAllowedInZone = false,
    },

    ENTER_THE_AREA = {
        label = "Enter The Area",
        objectiveTypes = { "LOCATE" },
        ruleType = "NO_COMBAT",
        directorType = "ZOMBIE_RANDOM",
        timerType = "NONE",
        outcomeTypes = { "EXTRACTION" },
        pvpAllowedInZone = false,
    },

    FIRE_SALE = {
        label = "Fire Sale",
        objectiveTypes = { "LOCATE" },
        ruleType = "PVE",
        directorType = "ZOMBIE_PERIMETER",
        timerType = "ESCALATION_TIMER",
        outcomeTypes = { "EXTRACTION" },
        pvpAllowedInZone = false,
    },

    -- Covers both HospitalChallenge (rare one-shot "spicy" trigger +
    -- injury/drunk debuffs) and TheLastFlight (zero scripted spawns
    -- + heavy starting injuries) -- both reduce to the same tuple.
    HOSPITAL_WARD = {
        label = "Hospital Ward",
        objectiveTypes = { "SURVIVE" },
        ruleType = "PVE",
        directorType = "ZOMBIE_RANDOM",
        timerType = "NONE",
        outcomeTypes = { "LAST_ALIVE" },
        pvpAllowedInZone = false,
    },

    LAST_DITCH_SECURITY = {
        label = "Last Ditch Security",
        objectiveTypes = { "HOLD_AREA" },
        ruleType = "PVE",
        directorType = "ZOMBIE_WAVES",
        timerType = "NONE",
        outcomeTypes = { "HOLD_DURATION" },
        pvpAllowedInZone = false,
    },

    NAKED_AND_AFRAID = {
        label = "Naked and Afraid",
        objectiveTypes = { "SURVIVE" },
        ruleType = "NO_COMBAT",
        directorType = "ZOMBIE_PERIMETER",
        timerType = "ESCALATION_TIMER",
        outcomeTypes = { "LAST_ALIVE" },
        pvpAllowedInZone = false,
    },

    PRISON_BREAK = {
        label = "Prison Break",
        objectiveTypes = { "RETRIEVE" },
        ruleType = "PVE",
        directorType = "ZOMBIE_ESCALATION",
        timerType = "COUNTDOWN",
        outcomeTypes = { "EXTRACTION" },
        pvpAllowedInZone = false,
    },

    THE_TEST_SUBJECT = {
        label = "The Test Subject",
        objectiveTypes = { "LOCATE" },
        ruleType = "PVE",
        directorType = "ZOMBIE_WAVES",
        timerType = "NONE",
        outcomeTypes = { "EXTRACTION" },
        pvpAllowedInZone = false,
    },
}

KIPN.Shared.EventScenarioPresetOrder = {
    "CAPTURE", "KING_OF_THE_HILL", "CHASE", "ADVENTURE",
    "ABANDONED_SOLDIER", "DODGEBALL", "ENTER_THE_AREA", "FIRE_SALE",
    "HOSPITAL_WARD", "LAST_DITCH_SECURITY", "NAKED_AND_AFRAID",
    "PRISON_BREAK", "THE_TEST_SUBJECT",
}

-- Compatibility aliases for integrations written against the
-- earlier "Game Mode Template" terminology. New code should use the
-- Scenario Preset names above.
KIPN.Shared.EventGameModeTemplates = KIPN.Shared.EventScenarioPresets
KIPN.Shared.EventGameModeTemplateOrder = KIPN.Shared.EventScenarioPresetOrder

-- Plain Lua tables don't preserve iteration order -- these are the
-- single source of truth for display order, used by the admin UI's
-- picker widgets (and by anything else that needs a stable list).
KIPN.Shared.EventObjectiveTypeOrder = { "RETRIEVE", "DELIVER", "HOLD_AREA", "SURVIVE", "LOCATE", "INTERACT", "ESCORT", "CHASE_TARGET" }
KIPN.Shared.EventTimerTypeOrder = { "NONE", "COUNTDOWN", "HOLD_TIMER", "ROUND_TIMER", "ESCALATION_TIMER" }
KIPN.Shared.EventOutcomeTypeOrder = { "FIRST_TO_COMPLETE", "LAST_ALIVE", "HOLD_DURATION", "EXTRACTION", "TIME_EXPIRED", "MOST_ZOMBIE_KILLS", "MOST_PLAYER_KILLS" }

--------------------------------------------------------------------
-- EVENT SCENARIOS: MODE FAMILIES (schema v2)
--
-- Phase 1 of the Event Scenarios architecture rewrite. A Mode is the
-- first-class replacement for the old flat Scenario Preset list --
-- see KIPN_EventModeRegistry.lua for the metadata/compatibility
-- registry built on top of these vocabularies, and
-- KIPN_EventScenarioService.lua's migrateDefinitionToV2() for how
-- existing Scenario Presets map onto Mode/Variant.
--
-- IMPLEMENTATION STATUS: as of Phase 11, all six Modes have their own
-- mechanical engine (KIPN_EventCaptureService.lua,
-- KIPN_EventKOTHService.lua, KIPN_EventChaseService.lua,
-- KIPN_EventExtractionService.lua, KIPN_EventSurvivorRunService.lua,
-- KIPN_EventAdventureService.lua), each hooked directly into
-- KIPN_EventRuntimeService.lua's lifecycle via definition.mode ==
-- "<MODE>" checks. The existing eventType/objectiveTypes/Scenario
-- Preset machinery still drives every definition that has no mode
-- assigned (nil mode), completely unaffected by any mode engine.
--------------------------------------------------------------------

KIPN.Shared.EventModes = {
    CAPTURE = "CAPTURE",
    KING_OF_THE_HILL = "KING_OF_THE_HILL",
    CHASE = "CHASE",
    EXTRACTION = "EXTRACTION",
    SURVIVOR_RUN = "SURVIVOR_RUN",
    ADVENTURE = "ADVENTURE",
}

KIPN.Shared.EventModeOrder = {
    "CAPTURE", "KING_OF_THE_HILL", "CHASE", "EXTRACTION", "SURVIVOR_RUN", "ADVENTURE",
}

KIPN.Shared.EventModeLabels = {
    CAPTURE = "Capture the Flag",
    KING_OF_THE_HILL = "King of the Hill",
    CHASE = "Chase",
    EXTRACTION = "Extraction",
    SURVIVOR_RUN = "Survivor Run",
    ADVENTURE = "Adventure",
}

-- Structural metadata (Phase 5, moved here from
-- KIPN_EventModeRegistry.lua so the client admin UI can show/hide
-- mode-specific sections -- e.g. Teams/Roles -- without duplicating
-- server logic or needing a round trip. KIPN_EventModeRegistry.lua's
-- GetModeMetadata() reads from this same table; nothing about how the
-- server validates/uses it changed.
KIPN.Shared.EventModeMetadata = {
    -- usesTeams=true here means "CAN use teams" -- Capture's FFA
    -- variant does not, per its mode contract ("do not create one
    -- base per player"). See KIPN_EventModeRegistry.lua's
    -- ModeUsesTeams(mode, variant) for the precise, variant-aware
    -- answer consumers (validation, the admin UI) should actually use.
    CAPTURE = { usesTeams = true, usesRounds = true, hasVariants = true },
    KING_OF_THE_HILL = { usesTeams = true, usesRounds = true, hasVariants = false },
    CHASE = { usesTeams = false, usesRounds = true, hasVariants = false },
    EXTRACTION = { usesTeams = false, usesRounds = false, hasVariants = true },
    SURVIVOR_RUN = { usesTeams = false, usesRounds = false, hasVariants = false },
    ADVENTURE = { usesTeams = false, usesRounds = false, hasVariants = false, isGenerated = true },
}

-- NAKED_AND_AFRAID is intentionally absent from EventModes -- it is a
-- modifier (see EventModifiers below), not a mode.
KIPN.Shared.EventExtractionVariants = {
    ABANDONED_SOLDIER = "ABANDONED_SOLDIER",
    HOSPITAL_WARD = "HOSPITAL_WARD",
    LAST_DITCH = "LAST_DITCH",
    PRISON_BREAK = "PRISON_BREAK",
}

KIPN.Shared.EventExtractionVariantOrder = {
    "ABANDONED_SOLDIER", "HOSPITAL_WARD", "LAST_DITCH", "PRISON_BREAK",
}

KIPN.Shared.EventExtractionVariantLabels = {
    ABANDONED_SOLDIER = "Abandoned Soldier",
    HOSPITAL_WARD = "Hospital Ward",
    LAST_DITCH = "Last Ditch",
    PRISON_BREAK = "Prison Break",
}

-- Phase 6: Capture's two rule variants -- Team CTF (per-team bases,
-- one flag per team) and FFA Capture (one neutral flag, one common
-- delivery point, no per-player bases). Only meaningful when
-- mode == CAPTURE, the same way EventExtractionVariants above is only
-- meaningful when mode == EXTRACTION -- see
-- KIPN_EventModeRegistry.lua's IsValidVariant().
KIPN.Shared.EventCaptureVariants = {
    TEAM_CTF = "TEAM_CTF",
    FFA = "FFA",
}

KIPN.Shared.EventCaptureVariantOrder = { "TEAM_CTF", "FFA" }

KIPN.Shared.EventCaptureVariantLabels = {
    TEAM_CTF = "Team Capture the Flag",
    FFA = "FFA Capture",
}

KIPN.Shared.EventModifiers = {
    NAKED_AND_AFRAID = "NAKED_AND_AFRAID",
}

KIPN.Shared.EventModifierOrder = { "NAKED_AND_AFRAID" }

KIPN.Shared.EventModifierLabels = {
    NAKED_AND_AFRAID = "Naked and Afraid",
}

-- Where a legacy Scenario Preset ends up after migration. See
-- KIPN_EventScenarioService.lua's migrateDefinitionToV2().
KIPN.Shared.EventMigrationStatus = {
    NATIVE = "NATIVE",                                 -- never had a legacy preset; not blocked
    MIGRATED = "MIGRATED",                             -- legacy preset cleanly mapped onto a Mode/Variant
    LEGACY_REVIEW_REQUIRED = "LEGACY_REVIEW_REQUIRED",  -- could not be safely mapped; needs admin review
}

-- Current schema contract version for a persisted Event Definition.
-- Unrelated to KIPN.Shared.SCHEMA_VERSION above, which versions
-- KIPN's overall persistence file, not this one record type.
-- Definitions missing a schemaVersion field are implicitly v1 (the
-- pre-rewrite shape) -- see KIPN_EventScenarioService.lua's
-- migrateDefinitionSchema().
KIPN.Shared.EventDefinitionSchemaVersion = 2

-- Legacy Scenario Preset ID -> { mode, variant } mapping used by the
-- v1 -> v2 migration. Presets intentionally absent from this table
-- (DODGEBALL, ENTER_THE_AREA, FIRE_SALE, THE_TEST_SUBJECT,
-- NAKED_AND_AFRAID, ADVENTURE) cannot be safely inferred and are left
-- as LEGACY_REVIEW_REQUIRED instead of guessed at -- see the Event
-- Scenarios architecture audit's Phase 1 migration plan.
KIPN.Shared.EventPresetModeMap = {
    CAPTURE = { mode = "CAPTURE" },
    KING_OF_THE_HILL = { mode = "KING_OF_THE_HILL" },
    CHASE = { mode = "CHASE" },
    ABANDONED_SOLDIER = { mode = "EXTRACTION", variant = "ABANDONED_SOLDIER" },
    HOSPITAL_WARD = { mode = "EXTRACTION", variant = "HOSPITAL_WARD" },
    LAST_DITCH_SECURITY = { mode = "EXTRACTION", variant = "LAST_DITCH" },
    PRISON_BREAK = { mode = "EXTRACTION", variant = "PRISON_BREAK" },
}

--------------------------------------------------------------------
-- EVENT SCENARIOS: ORDERED OBJECTIVES/STAGES AND THE PROXIMITY/TIMED
-- TRIGGER-AND-ACTION FRAMEWORK (schema v2, Phase 3)
--
-- One reusable trigger-and-action engine shared by every zombie/loot/
-- narrative/timer use case -- see KIPN_EventTriggerService.lua. An
-- Event Definition's `objectives` field (see
-- KIPN_EventScenarioService.lua's header) is an ORDERED array of
-- stages, each owning an ordered array of triggers; only the active
-- stage's triggers evaluate unless a trigger sets `background = true`.
--------------------------------------------------------------------

KIPN.Shared.EventTriggerActivationModes = {
    PROXIMITY = "PROXIMITY",
    TIME_SINCE_EVENT = "TIME_SINCE_EVENT",
    TIME_SINCE_ROUND = "TIME_SINCE_ROUND",
    TIME_SINCE_OBJECTIVE = "TIME_SINCE_OBJECTIVE",
    MANUAL = "MANUAL",
}

KIPN.Shared.EventTriggerActivationModeOrder = {
    "PROXIMITY", "TIME_SINCE_EVENT", "TIME_SINCE_ROUND", "TIME_SINCE_OBJECTIVE", "MANUAL",
}

KIPN.Shared.EventTriggerActivationModeLabels = {
    PROXIMITY = "Proximity",
    TIME_SINCE_EVENT = "Time Since Event Start",
    TIME_SINCE_ROUND = "Time Since Round Start",
    TIME_SINCE_OBJECTIVE = "Time Since Objective Activation",
    MANUAL = "Manual (Event Director)",
}

KIPN.Shared.EventTriggerScopes = {
    GLOBAL = "GLOBAL",
    PER_PLAYER = "PER_PLAYER",
}

KIPN.Shared.EventTriggerScopeOrder = { "GLOBAL", "PER_PLAYER" }

-- Every action a trigger can execute, in the order the requirements
-- list them. SPAWN_ZOMBIES/SPAWN_LOOT/ALARM default to GLOBAL scope
-- (fire once per round); PRIVATE_HINT/NARRATIVE_MESSAGE default to
-- PER_PLAYER (fire once per participant) -- see
-- KIPN_EventTriggerService.lua's sanitizeTrigger().
KIPN.Shared.EventTriggerActionTypes = {
    SPAWN_ZOMBIES = "SPAWN_ZOMBIES",
    SPAWN_LOOT = "SPAWN_LOOT",
    PRIVATE_HINT = "PRIVATE_HINT",
    NARRATIVE_MESSAGE = "NARRATIVE_MESSAGE",
    ANNOUNCEMENT = "ANNOUNCEMENT",
    ALARM = "ALARM",
    ACTIVATE_OBJECTIVE = "ACTIVATE_OBJECTIVE",
    COMPLETE_OBJECTIVE = "COMPLETE_OBJECTIVE",
    MODE_ACTION = "MODE_ACTION",
}

KIPN.Shared.EventTriggerActionTypeOrder = {
    "SPAWN_ZOMBIES", "SPAWN_LOOT", "PRIVATE_HINT", "NARRATIVE_MESSAGE",
    "ANNOUNCEMENT", "ALARM", "ACTIVATE_OBJECTIVE", "COMPLETE_OBJECTIVE", "MODE_ACTION",
}

KIPN.Shared.EventTriggerActionTypeLabels = {
    SPAWN_ZOMBIES = "Spawn Themed Zombies",
    SPAWN_LOOT = "Spawn Loot",
    PRIVATE_HINT = "Private Hint",
    NARRATIVE_MESSAGE = "Participant Narrative Message",
    ANNOUNCEMENT = "Event Announcement",
    ALARM = "Trigger Alarm",
    ACTIVATE_OBJECTIVE = "Activate Objective",
    COMPLETE_OBJECTIVE = "Complete Objective / Advance Story",
    MODE_ACTION = "Mode-Specific Action",
}

--------------------------------------------------------------------
-- EVENT SCENARIOS: SCOPED TIMER EXPIRY BEHAVIOR (schema v2, Phase 4)
--
-- Removes the old shortcut where any enabled event-wide duration
-- always meant "expiry = WIN". See KIPN_EventTimerService.lua and
-- KIPN_EventScenarioService.lua's sanitizeDuration()/
-- sanitizeRoundDuration(). WIN remains the default -- every existing
-- Event Definition (none of which have ever set expiryBehavior) keeps
-- behaving exactly as before.
--------------------------------------------------------------------

KIPN.Shared.EventTimerExpiryBehaviors = {
    WIN = "WIN",
    FAIL = "FAIL",
}

KIPN.Shared.EventTimerExpiryBehaviorOrder = { "WIN", "FAIL" }

KIPN.Shared.EventTimerExpiryBehaviorLabels = {
    WIN = "Surviving The Duration Wins",
    FAIL = "Expiry Fails Unresolved Participants",
}

--------------------------------------------------------------------
-- EVENT COMMANDS AND RESPONSE EVENTS
--
-- These names lived in KIPN's KIPN_Shared.lua and were not carried
-- over when Dynamic Events was split out, which left every client and
-- server call sending a nil command. Values are the originals, so a
-- KIPN that still defines them agrees; `or` keeps whichever loaded
-- first.
--------------------------------------------------------------------

KIPN.Shared.Commands = KIPN.Shared.Commands or {}
KIPN.Shared.ResponseEvents = KIPN.Shared.ResponseEvents or {}

local EVENT_COMMANDS = {
    EVENT_LIST_DEFINITIONS = "eventListDefinitions",
    EVENT_CREATE_DEFINITION = "eventCreateDefinition",
    EVENT_UPDATE_DEFINITION = "eventUpdateDefinition",
    EVENT_DELETE_DEFINITION = "eventDeleteDefinition",
    EVENT_SET_ZONE = "eventSetZone",
    EVENT_CREATE_ZONE_FROM_CORNERS = "eventCreateZoneFromCorners",
    EVENT_GET_EVENTTYPE_METADATA = "eventGetEventTypeMetadata",
    EVENT_LIST_ONLINE_PLAYERS = "eventListOnlinePlayers",
    EVENT_SET_PARTICIPANTS = "eventSetParticipants",
    EVENT_TELEPORT_PARTICIPANTS = "eventTeleportParticipants",
    EVENT_ACCEPT_PARTICIPATION = "eventAcceptParticipation",
    EVENT_VALIDATE = "eventValidate",
    EVENT_ANNOUNCE = "eventAnnounce",
    EVENT_OPEN_JOINING = "eventOpenJoining",
    EVENT_START = "eventStart",
    EVENT_STOP = "eventStop",
    EVENT_RESET = "eventReset",
    EVENT_GET_STATUS = "eventGetStatus",
    EVENT_RUNTIME_CONTROL = "eventRuntimeControl",
    EVENT_UPSERT_HOTSPOT = "eventUpsertHotspot",
    EVENT_DELETE_HOTSPOT = "eventDeleteHotspot",
    EVENT_SET_TEAM_COUNT = "eventSetTeamCount",
    EVENT_ASSIGN_PLAYER_TEAM = "eventAssignPlayerTeam",
    EVENT_LIST_REWARDS = "eventListRewards",
    EVENT_MARK_REWARD_DELIVERED = "eventMarkRewardDelivered",
    EVENT_DIRECTOR_EXECUTE = "eventDirectorExecute",
}

local EVENT_RESPONSES = {
    EVENT_DEFINITIONS_DATA = "eventDefinitionsData",
    EVENT_DEFINITION_SAVED = "eventDefinitionSaved",
    EVENT_DEFINITION_DELETED = "eventDefinitionDeleted",
    EVENT_STATUS_CHANGED = "eventStatusChanged",
    EVENT_ZONE_SAVED = "eventZoneSaved",
    EVENT_ONLINE_PLAYERS_DATA = "eventOnlinePlayersData",
    EVENT_PARTICIPANTS_SAVED = "eventParticipantsSaved",
    EVENT_TELEPORT_RESULT = "eventTeleportResult",
    EVENT_PARTICIPATION_INVITE = "eventParticipationInvite",
    EVENT_PARTICIPATION_RESULT = "eventParticipationResult",
    EVENT_STARTED = "eventStarted",
    EVENT_STOPPED = "eventStopped",
    EVENT_STATUS_DATA = "eventStatusData",
    EVENT_CONTROL_RESULT = "eventControlResult",
    EVENT_EVENTTYPE_METADATA_DATA = "eventEventTypeMetadataData",
    EVENT_DIRECTOR_RESULT = "eventDirectorResult",
    EVENT_NARRATIVE = "eventNarrative",
    EVENT_QUEUE_SYNC = "eventQueueSync",
    EVENT_HOTSPOT_SAVED = "eventHotspotSaved",
    EVENT_TEAM_SAVED = "eventTeamSaved",
    EVENT_REWARDS_DATA = "eventRewardsData",
    EVENT_REWARD_RESULT = "eventRewardResult",
    -- New with the player HUD (KIPN_EventGameLoopService.lua ->
    -- client/KIPN_EventPlayerHUD.lua): what a participant needs to
    -- play -- goal, clock, score, where to go -- plus big announcements.
    EVENT_PLAYER_HUD = "eventPlayerHud",
}

for key, value in pairs(EVENT_COMMANDS) do
    KIPN.Shared.Commands[key] = KIPN.Shared.Commands[key] or value
end
for key, value in pairs(EVENT_RESPONSES) do
    KIPN.Shared.ResponseEvents[key] = KIPN.Shared.ResponseEvents[key] or value
end

--------------------------------------------------------------------
-- THE OLYMPICS (mode OLYMPICS -- see server/KIPN_EventOlympicsService.lua)
--
-- A timed race over a course the admin draws: a start line, numbered
-- stations, a finish line. Athletes sign up for a town ("country"),
-- race two at a time in heats, and the fastest three take gold,
-- silver and bronze for their town. The medal table by town carries
-- over from one Olympics to the next.
--------------------------------------------------------------------

KIPN.Shared.EventModes.OLYMPICS = "OLYMPICS"
KIPN.Shared.EventModeOrder[#KIPN.Shared.EventModeOrder + 1] = "OLYMPICS"
KIPN.Shared.EventModeLabels.OLYMPICS = "The Olympics"
KIPN.Shared.EventModeMetadata.OLYMPICS = { usesTeams = false, usesRounds = false, hasVariants = false }

KIPN.Shared.EventOlympicCountries = {
    "Muldraugh", "West Point", "Riverside", "Rosewood", "March Ridge",
    "Louisville", "Ekron", "Irvington", "Brandenburg", "Echo Creek",
    "Fallas Lake", "Valley Station",
}

-- Hotspots that make up a course. Stations are numbered with the
-- hotspot's round number (1, 2, 3...) and carry their task in
-- metadata; a Carry station's drop zone and a Shooting station's
-- target range share the station's number.
KIPN.Shared.EventHotspotTypes.OLYMPIC_START = "OLYMPIC_START"
KIPN.Shared.EventHotspotTypes.OLYMPIC_STATION = "OLYMPIC_STATION"
KIPN.Shared.EventHotspotTypes.OLYMPIC_DROP = "OLYMPIC_DROP"
KIPN.Shared.EventHotspotTypes.OLYMPIC_TARGETS = "OLYMPIC_TARGETS"
KIPN.Shared.EventHotspotTypes.OLYMPIC_FINISH = "OLYMPIC_FINISH"
for _, hotspotType in ipairs({ "OLYMPIC_START", "OLYMPIC_STATION", "OLYMPIC_DROP", "OLYMPIC_TARGETS", "OLYMPIC_FINISH" }) do
    KIPN.Shared.EventHotspotTypeOrder[#KIPN.Shared.EventHotspotTypeOrder + 1] = hotspotType
end
KIPN.Shared.EventHotspotTypeLabels.OLYMPIC_START = "Start Line"
KIPN.Shared.EventHotspotTypeLabels.OLYMPIC_STATION = "Course Station"
KIPN.Shared.EventHotspotTypeLabels.OLYMPIC_DROP = "Carry Drop Zone"
KIPN.Shared.EventHotspotTypeLabels.OLYMPIC_TARGETS = "Shooting Targets"
KIPN.Shared.EventHotspotTypeLabels.OLYMPIC_FINISH = "Finish Line"

-- What a station asks of an athlete. itemType/count/kit are the
-- defaults the Studio fills in; the admin can change them per station.
KIPN.Shared.EventOlympicTaskOrder = { "CHECKPOINT", "CHOP", "CRAFT", "CARRY", "SHOOT" }
KIPN.Shared.EventOlympicTasks = {
    CHECKPOINT = { label = "Checkpoint", verb = "Run to the checkpoint" },
    CHOP = { label = "Chop wood", verb = "Chop a tree and bring logs back here",
        itemType = "Base.Log", count = 2, kit = { "Base.Axe" } },
    CRAFT = { label = "Craft", verb = "Craft the item and bring it back here",
        itemType = "Base.Plank", count = 2, kit = { "Base.Saw", "Base.Log" } },
    CARRY = { label = "Heavy lift", verb = "Carry the heavy load to the drop zone",
        itemType = "Base.Generator", count = 1 },
    SHOOT = { label = "Shooting", verb = "Take down every target",
        count = 5, kit = { "Base.Pistol", "Base.9mmClip", "Base.Bullets9mmBox" } },
}

-- Course templates the Studio offers: other Olympic disciplines built
-- from the same stations.
KIPN.Shared.EventOlympicDisciplineOrder = { "OBSTACLE", "SPRINT", "BIATHLON", "LUMBERJACK", "MARATHON" }
KIPN.Shared.EventOlympicDisciplines = {
    OBSTACLE = { label = "Obstacle Course", summary = "Run, chop, craft, lift and shoot, against the clock.",
        stations = { "CHECKPOINT", "CHOP", "CRAFT", "CARRY", "SHOOT" } },
    SPRINT = { label = "Sprint", summary = "Start line to finish line, nothing in between. Pure speed.",
        stations = {} },
    BIATHLON = { label = "Biathlon", summary = "Run a loop, shoot, run again, shoot again.",
        stations = { "CHECKPOINT", "SHOOT", "CHECKPOINT", "SHOOT" } },
    LUMBERJACK = { label = "Lumberjack", summary = "Fell a tree, saw planks, haul the load.",
        stations = { "CHOP", "CRAFT", "CARRY" } },
    MARATHON = { label = "Marathon", summary = "A long run through town past every checkpoint.",
        stations = { "CHECKPOINT", "CHECKPOINT", "CHECKPOINT", "CHECKPOINT", "CHECKPOINT" } },
}

KIPN.Shared.EventScenarioPresets.OLYMPICS = {
    label = "The Olympics",
    objectiveTypes = { "LOCATE" },
    ruleType = "PVE",
    directorType = "ZOMBIE_WAVES",
    timerType = "NONE",
    outcomeTypes = { "FIRST_TO_COMPLETE" },
    pvpAllowedInZone = false,
    scopeType = "OPEN_MAP",
}

--------------------------------------------------------------------
-- CLASSIC SCENARIOS (from Pillow's Random Scenarios, EXAMPLE folder)
--
-- Every Pillow scenario is built from the same few parts, provided
-- here as reusable pieces an event can pick:
--   * a starting LOADOUT (what you wake up wearing and holding, your
--     condition, injuries), with each player's own gear held in escrow;
--   * a DIFFICULTY roll (Normal / Dire / Brutal) that scales the threat;
--   * THREATS: a horde siege from every side, fires, a building alarm,
--     and ZOMBIE_AMBUSH hotspots (a room full of zombies that wakes when
--     someone walks in);
--   * a real LOCATION, offered by the Studio as one-click set-up.
-- KIPN.Shared.EventClassicScenarios combines them into one template
-- per scenario.
--------------------------------------------------------------------

KIPN.Shared.ResponseEvents.EVENT_APPLY_LOADOUT = KIPN.Shared.ResponseEvents.EVENT_APPLY_LOADOUT or "eventApplyLoadout"

-- New Extraction variants for the scenarios that end in an escape.
for _, variant in ipairs({ "FIRE_SALE", "TEST_SUBJECT", "LAST_FLIGHT", "ROAD_TRIP" }) do
    KIPN.Shared.EventExtractionVariants[variant] = variant
    KIPN.Shared.EventExtractionVariantOrder[#KIPN.Shared.EventExtractionVariantOrder + 1] = variant
end
KIPN.Shared.EventExtractionVariantLabels.FIRE_SALE = "Fire Sale"
KIPN.Shared.EventExtractionVariantLabels.TEST_SUBJECT = "The Test Subject"
KIPN.Shared.EventExtractionVariantLabels.LAST_FLIGHT = "The Last Flight"
KIPN.Shared.EventExtractionVariantLabels.ROAD_TRIP = "Road Trip (Enter the Area)"

-- Escape variants: the way out is open from the start.
KIPN.Shared.EventEscapeVariants = { PRISON_BREAK = true, FIRE_SALE = true, TEST_SUBJECT = true, ROAD_TRIP = true }

-- A room full of zombies that wakes when a participant comes close.
KIPN.Shared.EventHotspotTypes.ZOMBIE_AMBUSH = "ZOMBIE_AMBUSH"
table.insert(KIPN.Shared.EventHotspotTypeOrder, 2, "ZOMBIE_AMBUSH")
KIPN.Shared.EventHotspotTypeLabels.ZOMBIE_AMBUSH = "Zombie Ambush"

KIPN.Shared.EventDifficultyOrder = { "NORMAL", "DIRE", "BRUTAL", "RANDOM" }
KIPN.Shared.EventDifficulties = {
    NORMAL = { label = "Normal", multiplier = 1, injuries = 1 },
    DIRE = { label = "Dire", multiplier = 2, injuries = 2, sound = "Thunder" },
    BRUTAL = { label = "Brutal", multiplier = 3, injuries = 3, sound = "PlayerDied" },
    -- Rolled at start the way Pillow does: 1 in 2 Dire, 1 in 4 of those Brutal.
    RANDOM = { label = "Random (Pillow's roll)" },
}

KIPN.Shared.EventThreatOrder = { "SIEGE", "FIRES", "ALARM" }
KIPN.Shared.EventThreats = {
    SIEGE = { label = "Horde siege", help = "Hordes gather on every side and walk in on the players, again every few minutes (sooner on Dire and Brutal)." },
    FIRES = { label = "Fires", help = "Fires break out near players every few minutes. Real fire: it spreads and burns buildings." },
    ALARM = { label = "Building alarm", help = "An alarm goes off in the building a player is in, drawing every zombie nearby." },
}

local function range(from, to)
    local out = {}
    for _, value in ipairs(from) do out[#out + 1] = value end
    for _, value in ipairs(to or {}) do out[#out + 1] = value end
    return out
end
local FOOD = { "Base.CannedTomato2", "Base.CannedPotato2", "Base.CannedChili", "Base.TinnedSoup", "Base.TunaTin", "Base.WaterBottle", "Base.PopBottle" }

-- What players start with. keepGear = players keep what they brought
-- and get these on top; otherwise their gear goes into escrow first.
-- wear: put on; hands: held; bag: worn on the back, filled with
-- bagItems plus `randomPicks` from randomBag; oneOf: one random item;
-- dropNearby: left on the ground beside the player (containers
-- filled with their `contents`). stats and injuries are applied by
-- the player's own game (client/KIPN_EventLoadoutClient.lua).
KIPN.Shared.EventLoadoutOrder = { "NONE", "SOLDIER", "PRISONER", "PATIENT", "PILOT", "MALL_RAT", "SECURITY", "TEST_SUBJECT", "DRIFTER", "NAKED" }
KIPN.Shared.EventLoadouts = {
    NONE = { label = "Their own gear", summary = "Players keep whatever they bring." },
    SOLDIER = { label = "Abandoned soldier", summary = "Army fatigues, a loaded rifle, a holstered pistol, a knife and a pack of supplies.",
        wear = { "Base.Shoes_ArmyBoots", "Base.Trousers_CamoGreen", "Base.Shirt_CamoGreen", "Base.Hat_Army", "Base.Jacket_ArmyCamoGreen", "Base.HolsterSimple", "Base.Belt2" },
        hands = "Base.AssaultRifle", twoHanded = true,
        items = { "Base.Pistol", "Base.HuntingKnife", "Base.WaterBottle", "Base.Lighter", "Base.556Clip", "Base.9mmClip" },
        bag = "Base.Bag_ALICEpack_Army", bagItems = { "Base.TinOpener", "Base.HandAxe", "Base.556Box", "Base.Bullets9mmBox" },
        randomBag = range(FOOD, { "Base.Bandage", "Base.AlcoholWipes" }), randomPicks = 4,
        stats = { THIRST = 0.15, HUNGER = 0.35 } },
    PRISONER = { label = "Prisoner", summary = "A prison jumpsuit, slippers and one random tool to break out with (a sledgehammer, if you're very lucky).",
        wear = { "Base.Boilersuit_Prisoner", "Base.Shoes_Slippers", "Base.Socks_Long", "Base.Belt2" },
        handsOneOf = { "Base.BallPeenHammer", "Base.Broom", "Base.ClubHammer", "Base.Crowbar", "Base.Hammer", "Base.HandAxe", "Base.LeadPipe",
            "Base.Nightstick", "Base.PickAxe", "Base.PipeWrench", "Base.Rake", "Base.Shovel", "Base.Shovel2", "Base.SnowShovel", "Base.WoodAxe", "Base.WoodenMallet" },
        rareHands = "Base.Sledgehammer", rareChance = 100 },
    PATIENT = { label = "Hospital patient", summary = "A hospital gown, drunk, with a splinted broken bone. Worse on Dire and Brutal.",
        wear = { "Base.HospitalGown" },
        stats = { INTOXICATION = 50, THIRST = 0.25, HUNGER = 0.25, FATIGUE = 0.25 }, injuries = { fracture = 1 } },
    PILOT = { label = "Crashed pilot", summary = "A flight suit and helmet, a pistol and knife, cuts and burns from the crash, and your pack and a first-aid kit thrown clear nearby.",
        wear = { "Base.Shoes_ArmyBoots", "Base.Tshirt_ArmyGreen", "Base.Hat_SPHhelmet", "Base.Boilersuit_Flying", "Base.Gloves_LeatherGlovesBlack", "Base.HolsterSimple", "Base.Belt2" },
        items = { "Base.Pistol", "Base.HuntingKnife", "Base.WaterBottle", "Base.Lighter", "Base.Torch", "Base.9mmClip" },
        dropNearby = {
            { item = "Base.Bag_ALICEpack_Army", contents = { "Base.TinOpener", "Base.HandAxe", "Base.Saw", "Base.RippedSheets", "Base.RippedSheets", "Base.RippedSheets", "Base.Bullets9mmBox" } },
            { item = "Base.FirstAidKit", contents = { "Base.AlcoholBandage", "Base.Disinfectant", "Base.Bandaid", "Base.Pills", "Base.SutureNeedle", "Base.Tweezers" } },
        },
        stats = { THIRST = 0.15, HUNGER = 0.35, FATIGUE = 0.35 }, injuries = { wounds = 3 } },
    MALL_RAT = { label = "Mall rat", summary = "Your own gear plus a crowbar and a duffel bag of snacks and odds and ends.",
        keepGear = true, hands = "Base.Crowbar", twoHanded = true, items = { "Base.WaterBottle" },
        bag = "Base.Bag_DuffelBag",
        randomBag = { "Base.Crisps", "Base.BeefJerky", "Base.JuiceBox", "Base.PopBottle", "Base.Peanuts", "Base.Lighter", "Base.HandAxe",
            "Base.TinOpener", "Base.Saw", "Base.Screwdriver", "Base.Hammer", "Base.Torch", "Base.Gloves_WhiteTINT" }, randomPicks = 5,
        stats = { THIRST = 0.15, HUNGER = 0.15, FATIGUE = 0.25 } },
    SECURITY = { label = "Night security", summary = "Your own gear plus a knife, and a duffel with a hammer, nails and sheet ropes to barricade and escape.",
        keepGear = true, items = { "Base.HuntingKnife", "Base.WaterBottle", "Base.Lighter" },
        bag = "Base.Bag_DuffelBag", bagItems = { "Base.TinOpener", "Base.Hammer", "Base.NailsBox", "Base.SheetRope", "Base.SheetRope", "Base.SheetRope", "Base.SheetRope" },
        randomBag = range(FOOD, { "Base.Bandage" }), randomPicks = 2 },
    TEST_SUBJECT = { label = "Test subject", summary = "A hospital gown, an electric lantern with a battery, and a stone in your hand. Nothing else.",
        wear = { "Base.HospitalGown" }, hands = "Base.Stone2", items = { "Base.Lantern_CraftedElectric", "Base.Battery" } },
    DRIFTER = { label = "Drifter", summary = "A hoodie, jeans, boots and a hiking bag with a few days of food.",
        wear = { "Base.HoodieDOWN_WhiteTINT", "Base.Hat_Beany", "Base.TrousersMesh_DenimLight", "Base.Shoes_ArmyBoots", "Base.Socks_Long", "Base.Belt2" },
        bag = "Base.Bag_NormalHikingBag", bagItems = { "Base.TinOpener" }, randomBag = FOOD, randomPicks = 4 },
    NAKED = { label = "Naked and afraid", summary = "Nothing at all except one random, useless item. Maximum panic.",
        oneOf = { "Base.Spiffo", "Base.Banana", "Base.Hat_SantaHatGreen", "Base.Scalpel", "Base.Ham", "Base.Glasses_Aviators", "Base.Bleach" },
        stats = { PANIC = 100, STRESS = 1 } },
}

-- One template per Pillow scenario: the event settings it becomes,
-- and (venue) where it happened, for one-click set-up. Coordinates
-- are Pillow's own (cell x 300 + offset). Hotspots use the same
-- shape as the Studio draws: { type, x, y, z, half, round, metadata }.
KIPN.Shared.EventClassicScenarioOrder = { "ABANDONED_SOLDIER", "HOSPITAL", "LAST_DITCH", "PRISON", "FIRE_SALE", "TEST_SUBJECT",
    "LAST_FLIGHT", "ENTER_THE_AREA", "NAKED_AND_AFRAID", "DODGEBALL" }
KIPN.Shared.EventClassicScenarios = {
    ABANDONED_SOLDIER = { label = "Abandoned Soldier", summary = "Left behind with a rifle; hordes close in from every side until the evac comes.",
        mode = "EXTRACTION", variant = "ABANDONED_SOLDIER", loadout = "SOLDIER", difficulty = "RANDOM", threats = { SIEGE = true },
        theme = "MILITARY", director = "ZOMBIE_PERIMETER",
        briefing = "Your unit pulled out without you. You have a rifle, a pack and not much time: they're coming from every side. Hold out until the evac arrives, then get to it.",
        venue = { label = "Muldraugh factory lunchroom", zone = { 10039, 10860, 10119, 10940 },
            hotspots = { { "PLAYER_SPAWN", 10079, 10900, 0, 1 } } } },
    HOSPITAL = { label = "Hospital Ward", summary = "Wake in a gown, drunk, with a broken bone. Stay alive until help arrives.",
        mode = "EXTRACTION", variant = "HOSPITAL_WARD", loadout = "PATIENT", difficulty = "RANDOM", threats = { ALARM = true },
        theme = "MEDICAL", director = "ZOMBIE_RANDOM",
        briefing = "You come round in an exam room, still drunk, one limb in a splint. The building is not empty. Survive until the evac, then limp to it.",
        venue = { label = "Cortman Medical, Muldraugh", zone = { 10847, 9999, 10907, 10059 },
            hotspots = { { "PLAYER_SPAWN", 10877, 10029, 0, 1 } } } },
    LAST_DITCH = { label = "Last Ditch Security", summary = "The stairs are gone. Barricade the dorm and hold out against a siege.",
        mode = "EXTRACTION", variant = "LAST_DITCH", loadout = "SECURITY", difficulty = "RANDOM", threats = { SIEGE = true },
        theme = "RANDOM", director = "ZOMBIE_ESCALATION",
        briefing = "You're the last guard on the March Ridge dorm and the stairs are gone. Barricade, hold out, and when the evac lands out front, fight your way to it.",
        venue = { label = "March Ridge dorm", zone = { 10030, 12590, 10140, 12690 },
            hotspots = { { "PLAYER_SPAWN", 10052, 12654, 1, 1 }, { "EXTRACTION_POINT", 10081, 12641, 0, 3 } } } },
    PRISON = { label = "Prison Break", summary = "Locked in a Rosewood cell with one tool. The inmates are loose. Find the way out.",
        mode = "EXTRACTION", variant = "PRISON_BREAK", loadout = "PRISONER", difficulty = "RANDOM", threats = { ALARM = true },
        theme = "PRISON", director = "ZOMBIE_ESCALATION",
        briefing = "Lockdown failed. You're in a cell with a jumpsuit and whatever you could grab. Get to the main desk to find a way out, then make for the car park.",
        venue = { label = "Rosewood prison", zone = { 7600, 11770, 7730, 11950 },
            hotspots = { { "PLAYER_SPAWN", 7679, 11830, 0, 1 }, { "CAPTURE_ITEM", 7708, 11878, 0, 2 }, { "EXTRACTION_POINT", 7615, 11782, 0, 4 },
                { "ZOMBIE_AMBUSH", 7647, 11877, 0, 4, nil, { count = 12 } }, { "ZOMBIE_AMBUSH", 7659, 11847, 0, 4, nil, { count = 8 } },
                { "ZOMBIE_AMBUSH", 7640, 11918, 0, 5, nil, { count = 12 } }, { "ZOMBIE_AMBUSH", 7722, 11884, 0, 4, nil, { count = 15 } } } } },
    FIRE_SALE = { label = "Fire Sale", summary = "The mall is burning and the alarm is screaming. One exit is clear; the rest are swarmed.",
        mode = "EXTRACTION", variant = "FIRE_SALE", loadout = "MALL_RAT", difficulty = "RANDOM", threats = { FIRES = true, ALARM = true },
        theme = "RANDOM", director = "ZOMBIE_PERIMETER",
        briefing = "You hid in the mall overnight. Now something's burning, the alarm won't stop, and every door has company. One service exit is clear. Find it.",
        venue = { label = "Louisville mall", zone = { 13850, 5720, 14020, 5930 },
            hotspots = { { "PLAYER_SPAWN", 13971, 5857, 2, 1 },
                { "EXTRACTION_POINT", 13870, 5789, 0, 2 }, { "EXTRACTION_POINT", 13867, 5889, 0, 2 }, { "EXTRACTION_POINT", 13888, 5894, 0, 2 },
                { "EXTRACTION_POINT", 14003, 5832, 0, 2 }, { "EXTRACTION_POINT", 14002, 5805, 0, 2 }, { "EXTRACTION_POINT", 13960, 5755, 0, 2 } } } },
    TEST_SUBJECT = { label = "The Test Subject", summary = "Wake in the caves under the secret base. Every room on the way up is waiting for you.",
        mode = "EXTRACTION", variant = "TEST_SUBJECT", loadout = "TEST_SUBJECT", difficulty = "NORMAL", threats = {},
        theme = "MILITARY_HOSPITAL", director = "ZOMBIE_WAVES", scope = "OPEN_MAP",
        briefing = "You wake in the dark among the bodies of the other subjects, a lantern and a stone to your name. The only way out is up, through the base.",
        venue = { label = "Secret base, under the caves", hotspots = {
            { "PLAYER_SPAWN", 5686, 12434, -17, 1 },
            { "ZOMBIE_AMBUSH", 5671, 12445, -17, 3, nil, { count = 4 } }, { "ZOMBIE_AMBUSH", 5628, 12462, -17, 3, nil, { count = 5 } },
            { "ZOMBIE_AMBUSH", 5581, 12470, -17, 4, nil, { count = 12 } }, { "ZOMBIE_AMBUSH", 5569, 12438, -17, 4, nil, { count = 20 } },
            { "ZOMBIE_AMBUSH", 5563, 12421, -16, 4, nil, { count = 12 } }, { "ZOMBIE_AMBUSH", 5562, 12448, -16, 4, nil, { count = 10 } },
            { "ZOMBIE_AMBUSH", 5568, 12474, -15, 4, nil, { count = 8 } }, { "ZOMBIE_AMBUSH", 5543, 12476, -15, 4, nil, { count = 16 } },
            { "ZOMBIE_AMBUSH", 5543, 12466, -13, 4, nil, { count = 16 } }, { "ZOMBIE_AMBUSH", 5579, 12482, 0, 6, nil, { count = 30 } },
            { "EXTRACTION_POINT", 5579, 12500, 0, 3 } } } },
    LAST_FLIGHT = { label = "The Last Flight", summary = "Your helicopter went down. Patch yourself up, find your pack and survive to the rescue.",
        mode = "EXTRACTION", variant = "LAST_FLIGHT", loadout = "PILOT", difficulty = "RANDOM", threats = { SIEGE = true },
        theme = "RANDOM", director = "ZOMBIE_ESCALATION",
        briefing = "The chopper is wreckage and you're bleeding. Your pack and the first-aid kit were thrown clear. Patch up, hold out, and reach the rescue when it comes.",
        venue = { label = "Fields east of Muldraugh's industrial site", zone = { 9465, 11148, 9545, 11228 },
            hotspots = { { "PLAYER_SPAWN", 9505, 11188, 0, 2 } } } },
    ENTER_THE_AREA = { label = "Enter the Area (Road Trip)", summary = "Arrive at the edge of Knox County and make it to safety in town.",
        mode = "EXTRACTION", variant = "ROAD_TRIP", loadout = "DRIFTER", difficulty = "NORMAL", threats = {},
        theme = "RURAL", director = "ZOMBIE_RANDOM", scope = "OPEN_MAP",
        briefing = "You made it to the county line with a bag of food. Get into March Ridge before dark. Grab a car if you can find one.",
        venue = { label = "South of March Ridge to the town centre", hotspots = {
            { "PLAYER_SPAWN", 10595, 13488, 0, 3 }, { "EXTRACTION_POINT", 10150, 12760, 0, 5 } } } },
    NAKED_AND_AFRAID = { label = "Naked and Afraid", summary = "Nothing but one silly item. Survive until the clock runs out.",
        mode = "SURVIVOR_RUN", loadout = "NAKED", difficulty = "RANDOM", threats = { ALARM = true },
        theme = "RANDOM", director = "ZOMBIE_PERIMETER",
        briefing = "You wake up in an empty building with nothing on and, for some reason, whatever that is in your hand. Stay alive.",
        venue = { label = "Vacant house, Muldraugh", zone = { 10881, 9990, 10941, 10050 },
            hotspots = { { "PLAYER_SPAWN", 10911, 10020, 0, 1 } } } },
    DODGEBALL = { label = "Dodgeball of the Dead", summary = "Unarmed in a school as the dead pour in. Last one standing wins.",
        mode = "SURVIVOR_RUN", loadout = "NAKED", difficulty = "RANDOM", threats = { SIEGE = true }, lastStanding = true,
        theme = "RANDOM", director = "ZOMBIE_ESCALATION",
        briefing = "No weapons, no clothes, a school full of doors and the dead coming through all of them. Dodge. Last one standing wins.",
        venue = { label = "Muldraugh elementary school", zone = { 10592, 9944, 10652, 10004 },
            hotspots = { { "PLAYER_SPAWN", 10622, 9974, 0, 2 } } } },
}

--------------------------------------------------------------------
-- PREPARED EVENTS AND SIMULATION
--
-- A prepared event (validated and ready) offers four things: Start it
-- (a sign-up window, then it begins), Simulate it (a stepped rehearsal
-- for the admin and staff only), Announcements (tell the server), and
-- Cancel it. See server/KIPN_EventControlService.lua and
-- server/KIPN_EventSimulationService.lua.
--------------------------------------------------------------------

for key, value in pairs({
    EVENT_QUICK_START = "eventQuickStart",
    EVENT_CANCEL = "eventCancel",
    EVENT_SEND_ANNOUNCEMENT = "eventSendAnnouncement",
    EVENT_SIMULATE = "eventSimulate",
    EVENT_SIMULATE_STEP = "eventSimulateStep",
}) do KIPN.Shared.Commands[key] = KIPN.Shared.Commands[key] or value end

for key, value in pairs({
    -- A simulation's current step, highlights and guide.
    EVENT_SIMULATION = "eventSimulation",
    -- The server asks a client to move its player (clients own their
    -- position in multiplayer); hop = tiles per second-hop, or nil to jump.
    EVENT_MOVE_PLAYER = "eventMovePlayer",
    -- The result of a prepared-event action, in words.
    EVENT_ACTION_RESULT = "eventActionResult",
}) do KIPN.Shared.ResponseEvents[key] = KIPN.Shared.ResponseEvents[key] or value end

-- Events that are ready to run or already on their way.
KIPN.Shared.EventPreparedStatuses = { READY = true, ANNOUNCED = true, JOINING = true }

-- Simulation glow colours by hotspot kind. Zombie spawns and ambushes
-- glow red, apart from every other kind.
KIPN.Shared.EventHotspotColors = {
    ZOMBIE_SPAWN = { 1.0, 0.15, 0.15 }, ZOMBIE_AMBUSH = { 1.0, 0.15, 0.15 },
    PLAYER_SPAWN = { 0.9, 0.9, 0.9 }, TEAM_SPAWN = { 0.9, 0.9, 0.9 },
    CAPTURE_ITEM = { 1.0, 0.82, 0.3 }, DELIVERY_POINT = { 1.0, 0.82, 0.3 }, RESCUE_OBJECTIVE = { 1.0, 0.82, 0.3 },
    OBJECTIVE_LOCATION = { 1.0, 0.82, 0.3 }, HILL_LOCATION = { 1.0, 0.6, 0.2 }, TEAM_BASE = { 0.35, 0.55, 1.0 },
    NARRATIVE_LOCATION = { 0.75, 0.45, 1.0 }, EXTRACTION_POINT = { 0.35, 0.95, 0.45 },
    OLYMPIC_START = { 0.3, 0.9, 1.0 }, OLYMPIC_STATION = { 0.3, 0.9, 1.0 }, OLYMPIC_DROP = { 0.3, 0.9, 1.0 },
    OLYMPIC_TARGETS = { 1.0, 0.15, 0.15 }, OLYMPIC_FINISH = { 0.3, 0.9, 1.0 },
    ZONE = { 1.0, 0.55, 0.15 }, FIRE = { 1.0, 0.45, 0.1 },
}

--------------------------------------------------------------------
-- PAST EVENTS
--
-- Every run that ends (won, lost, stopped or cancelled after it was
-- announced) is kept in a short history the Event Studio lists.
--------------------------------------------------------------------

KIPN.Shared.Commands.EVENT_LIST_HISTORY = KIPN.Shared.Commands.EVENT_LIST_HISTORY or "eventListHistory"
KIPN.Shared.ResponseEvents.EVENT_HISTORY_DATA = KIPN.Shared.ResponseEvents.EVENT_HISTORY_DATA or "eventHistoryData"
KIPN.Shared.EventHistoryLimit = 50

--------------------------------------------------------------------
-- BANDITS
--
-- Raider crews: server-spawned zombies in raider outfits, as the
-- careers threats use (KIPNCareers_Threats.lua in Careers Framework).
-- They talk, carry loot and drop it where they fall.
--
--   BANDIT_CAMP     a crew waits here, calm until someone comes close
--                   or shoots, then fights. metadata.count = crew size.
--   BANDIT_VEHICLE  the crew's getaway car, parked here at the start,
--                   with the loot in its trunk (The Heist's gold).
--   Threat BANDITS  raiding crews arrive every few minutes and hunt
--                   the players; their leader carries supplies.
--   Story action SPAWN_BANDITS  a crew arrives when a story step fires.
--   Extraction variant HEIST  bandits stole the gold: find their car,
--                   stop them, take the gold to the extraction point.
--------------------------------------------------------------------

KIPN.Shared.EventHotspotTypes.BANDIT_CAMP = "BANDIT_CAMP"
KIPN.Shared.EventHotspotTypes.BANDIT_VEHICLE = "BANDIT_VEHICLE"
for _, hotspotType in ipairs({ "BANDIT_CAMP", "BANDIT_VEHICLE" }) do
    KIPN.Shared.EventHotspotTypeOrder[#KIPN.Shared.EventHotspotTypeOrder + 1] = hotspotType
end
KIPN.Shared.EventHotspotTypeLabels.BANDIT_CAMP = "Bandit Camp"
KIPN.Shared.EventHotspotTypeLabels.BANDIT_VEHICLE = "Getaway Car"
KIPN.Shared.EventHotspotColors.BANDIT_CAMP = { 1.0, 0.3, 0.75 }
KIPN.Shared.EventHotspotColors.BANDIT_VEHICLE = { 1.0, 0.3, 0.75 }
-- Bandits are outlined in magenta during a simulation, apart from
-- ordinary zombies (red).
KIPN.Shared.EventBanditColor = { 1.0, 0.3, 0.75 }

KIPN.Shared.EventThreatOrder[#KIPN.Shared.EventThreatOrder + 1] = "BANDITS"
KIPN.Shared.EventThreats.BANDITS = { label = "Bandit raids",
    help = "Raider crews arrive every few minutes and hunt the players. Their leader carries supplies worth taking." }

KIPN.Shared.EventTriggerActionTypes.SPAWN_BANDITS = "SPAWN_BANDITS"
KIPN.Shared.EventTriggerActionTypeOrder[#KIPN.Shared.EventTriggerActionTypeOrder + 1] = "SPAWN_BANDITS"
KIPN.Shared.EventTriggerActionTypeLabels.SPAWN_BANDITS = "Bandits Arrive"

KIPN.Shared.EventExtractionVariants.HEIST = "HEIST"
KIPN.Shared.EventExtractionVariantOrder[#KIPN.Shared.EventExtractionVariantOrder + 1] = "HEIST"
KIPN.Shared.EventExtractionVariantLabels.HEIST = "The Heist (bandits stole the gold)"
KIPN.Shared.EventEscapeVariants.HEIST = true

-- The gold the crew stole, and what their car is.
KIPN.Shared.EventHeist = { item = "Base.GoldBar", count = 5, vehicle = "Base.CarNormal" }

KIPN.Shared.ResponseEvents.EVENT_BANDIT_SAY = KIPN.Shared.ResponseEvents.EVENT_BANDIT_SAY or "eventBanditSay"

KIPN.Shared.EventClassicScenarioOrder[#KIPN.Shared.EventClassicScenarioOrder + 1] = "HEIST"
KIPN.Shared.EventClassicScenarios.HEIST = { label = "The Heist",
    summary = "Bandits robbed the bank. Follow the trail to their getaway car, stop the crew and bring the gold to the pickup.",
    mode = "EXTRACTION", variant = "HEIST", loadout = "NONE", difficulty = "NORMAL", threats = { BANDITS = true },
    theme = "RANDOM", director = "ZOMBIE_RANDOM",
    briefing = "A crew hit the bank and got away with the gold. Their car was seen heading out of town. Find it, deal with them, and get the gold to the pickup before they move it on." }

--------------------------------------------------------------------
-- STAFF ACCESS (sandbox options, page "Dynamic Events")
--
-- Admins can always use the Event Studio and join simulations. Each
-- other KIPN staff level can be allowed separately:
--   DynamicEvents.Studio<Level>      use the Event Studio (build, run,
--                                    announce, cancel, simulate events)
--   DynamicEvents.Simulation<Level>  be invited to join simulations
-- <Level> is Moderator, Staff, GM or Observer. Every elevated level gets
-- Director Controls from the right-click menu, as before (its commands
-- keep their own tiers).
--------------------------------------------------------------------

KIPN.Shared.EventStaffLevels = { MODERATOR = "Moderator", STAFF = "Staff", GM = "GM", OBSERVER = "Observer" }
KIPN.Shared.EventStaffLevelOrder = { "MODERATOR", "STAFF", "GM", "OBSERVER" }

-- True if a player of KIPN access `level` may do `what` ("Studio" or
-- "Simulation") under this server's sandbox options.
function KIPN.Shared.EventAccessAllows(what, level)
    if level == "ADMIN" then return true end
    local suffix = KIPN.Shared.EventStaffLevels[level or ""]
    if not suffix then return false end
    local options = SandboxVars and SandboxVars.DynamicEvents
    return type(options) == "table" and options[what .. suffix] == true
end

for key, value in pairs({ EVENT_SIMULATION_RESPOND = "eventSimulationRespond" }) do
    KIPN.Shared.Commands[key] = KIPN.Shared.Commands[key] or value
end
-- A voluntary invitation into someone's simulation ({ withdrawn } when it ends).
KIPN.Shared.ResponseEvents.EVENT_SIMULATION_INVITE = KIPN.Shared.ResponseEvents.EVENT_SIMULATION_INVITE or "eventSimulationInvite"
