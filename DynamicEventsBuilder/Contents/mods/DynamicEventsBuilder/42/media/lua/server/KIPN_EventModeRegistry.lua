-- KIPN_EventModeRegistry.lua
--
-- Phase 1 of the Event Scenarios architecture rewrite: declarative
-- metadata for the six first-class Mode families (plus Extraction's
-- four Variants), and the Naked and Afraid modifier compatibility
-- matrix.
--
-- IMPLEMENTATION STATUS: each mode's actual gameplay implementation
-- landed in its own later phase (Phases 6-11) as a dedicated file
-- (KIPN_EventCaptureService.lua, KIPN_EventKOTHService.lua, etc.)
-- hooked directly into KIPN_EventRuntimeService.lua's lifecycle via
-- definition.mode == "<MODE>" checks -- not through a registry
-- lookup here. (Phase 1 originally sketched a
-- RegisterMechanicalEngine/HasMechanicalEngine extension point for
-- this; it was never used by any of the six mode phases and was
-- removed in Phase 12 as dead code once the direct-hook pattern had
-- proven out six times over.) Every event still also runs on the
-- existing eventType/HORDE_SURVIVAL engine
-- (KIPN_EventObjectiveRegistry.lua), completely unaffected by this
-- file.
--
-- Responsibilities:
--   * Mode/Variant existence + structural metadata lookup, used by
--     KIPN_EventScenarioService.lua's sanitizers/migration and by
--     every mode phase's own validator/service.
--   * The Naked and Afraid modifier compatibility matrix (the
--     approved interpretation from the Event Scenarios architecture
--     audit, encoded explicitly rather than guessed from labels).

if isClient() then return end

require "KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventModeRegistry = KIPN.Server.EventModeRegistry or {}

local ModeRegistry = KIPN.Server.EventModeRegistry

local function log(message)
    print("[KIPN EVENT MODE REGISTRY] " .. tostring(message))
end

------------------------------------------------------------
-- MODE / VARIANT METADATA
------------------------------------------------------------

-- Phase 5: moved into KIPN.Shared.EventModeMetadata so the client
-- admin UI can read the same table (e.g. to show/hide Teams/Roles)
-- without duplicating it or needing a round trip. Same values, same
-- shape -- this is a pure relocation, not a behavior change.
local MODES = KIPN.Shared.EventModeMetadata

function ModeRegistry.IsValidMode(mode)
    return type(mode) == "string" and MODES[mode] ~= nil
end

function ModeRegistry.GetModeMetadata(mode)
    return MODES[mode]
end

-- A mode with hasVariants=false must have a nil variant; a mode with
-- hasVariants=true requires a recognized variant from its own
-- vocabulary (Phase 6 adds Capture's TEAM_CTF/FFA alongside
-- Extraction's four variants -- each mode owns a distinct Shared
-- enum, matched here explicitly rather than guessed).
local VARIANT_VOCABULARY_BY_MODE = {
    EXTRACTION = "EventExtractionVariants",
    CAPTURE = "EventCaptureVariants",
}

function ModeRegistry.IsValidVariant(mode, variant)
    local metadata = MODES[mode]

    if not metadata or not metadata.hasVariants then
        return variant == nil
    end

    local vocabularyName = VARIANT_VOCABULARY_BY_MODE[mode]
    local vocabulary = vocabularyName and KIPN.Shared[vocabularyName]

    return type(variant) == "string" and vocabulary ~= nil and vocabulary[variant] ~= nil
end

-- Phase 6: precise, variant-aware "does this definition actually use
-- teams" answer -- EventModeMetadata.usesTeams alone only says
-- whether the MODE can, not whether the current VARIANT does.
-- Capture's FFA variant explicitly does not ("do not create one base
-- per player" in its mode contract). Every other team-capable mode
-- today (King of the Hill) has no variants, so its usesTeams flag
-- alone is still the right answer for it.
function ModeRegistry.ModeUsesTeams(mode, variant)
    local metadata = MODES[mode]

    if not metadata or not metadata.usesTeams then
        return false
    end

    if mode == KIPN.Shared.EventModes.CAPTURE then
        return variant == KIPN.Shared.EventCaptureVariants.TEAM_CTF
    end

    return true
end

------------------------------------------------------------
-- NAKED AND AFRAID COMPATIBILITY MATRIX
------------------------------------------------------------
--
-- Mirrors the approved interpretation from the Event Scenarios
-- architecture audit: an explicit table rather than guessing from
-- labels. Extraction's per-variant entries encode the mandatory-
-- loadout conflicts (knife-only Abandoned Soldier, handgun/ammo Last
-- Ditch); Hospital Ward/Prison Break are allowed pending their own
-- phase's loadout audit. Adventure cannot be evaluated until it has
-- actually rolled an underlying mode/variant, so it is conservatively
-- reported incompatible here rather than guessed compatible.
--
-- Phase 11 update: Adventure now genuinely rolls a mode/variant at
-- event start (see KIPN_EventAdventureService.lua), but this table's
-- bare ADVENTURE = false entry (below, via the not-present-here
-- fallback) is deliberately left as the conservative block rather
-- than re-checked against the rolled mode -- escrow-stripping for
-- Naked and Afraid already happens at JOIN time
-- (KIPN_EventParticipationService.lua's handleAcceptParticipation()),
-- before any roll exists to check against, and reordering that would
-- mean reworking an already-approved, working Phase 2 flow. Adventure
-- + Naked and Afraid simply can never both be enabled on the same
-- definition today -- safe, just not the more permissive "re-check
-- after rolling" behavior this comment used to describe as pending.
------------------------------------------------------------

local MODIFIER_COMPATIBILITY = {
    CAPTURE = true,
    KING_OF_THE_HILL = true,
    CHASE = true,
    SURVIVOR_RUN = true,
    -- Everyone races with only what the stations hand out: fair.
    OLYMPICS = true,
    EXTRACTION = {
        ABANDONED_SOLDIER = false,
        HOSPITAL_WARD = true,
        LAST_DITCH = false,
        PRISON_BREAK = true,
        FIRE_SALE = true,
        TEST_SUBJECT = true,
        LAST_FLIGHT = false,
        ROAD_TRIP = true,
        HEIST = true,
    },
}

-- Only NAKED_AND_AFRAID exists today; the (modifierId, mode, variant)
-- shape supports future modifiers without changing callers.
function ModeRegistry.IsModifierCompatible(modifierId, mode, variant)
    if modifierId ~= KIPN.Shared.EventModifiers.NAKED_AND_AFRAID then
        return false, "UNKNOWN_MODIFIER"
    end

    if not ModeRegistry.IsValidMode(mode) then
        return false, "UNKNOWN_MODE"
    end

    if mode == KIPN.Shared.EventModes.ADVENTURE then
        return false, "ADVENTURE_ROLL_PENDING"
    end

    if mode == KIPN.Shared.EventModes.EXTRACTION then
        local variantCompatibility = MODIFIER_COMPATIBILITY.EXTRACTION

        if not ModeRegistry.IsValidVariant(mode, variant) then
            return false, "UNKNOWN_VARIANT"
        end

        if variantCompatibility[variant] then
            return true
        end

        return false, "INCOMPATIBLE_EXTRACTION_LOADOUT"
    end

    if MODIFIER_COMPATIBILITY[mode] then
        return true
    end

    return false, "INCOMPATIBLE_MODE"
end

function ModeRegistry.Initialize()
    log(
        "Initialize() -> " .. tostring(#KIPN.Shared.EventModeOrder) .. " mode(s), " ..
        tostring(#KIPN.Shared.EventExtractionVariantOrder) .. " extraction variant(s) registered"
    )
    return true
end

log("module loaded")
