-- KIPN_ComputerConfig.lua
--
-- Server-authoritative KIPN computer / hardware configuration.
--
-- Responsibilities:
--   * Define default computer hardware parameters.
--   * Define boot timing policy.
--   * Define baud rate limits.
--   * Expose an Initialize() method so KIPN_Server's
--     initializeService() can load it cleanly.
--
-- This module intentionally contains configuration only.
-- Actual computer lifecycle logic lives in KIPN_Server.lua.

if isClient() then return end

require "KIPN/KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.ComputerConfig = KIPN.Server.ComputerConfig or {}

local ComputerConfig = KIPN.Server.ComputerConfig

------------------------------------------------------------
-- DEFAULT HARDWARE
------------------------------------------------------------

ComputerConfig.DefaultBaudRate = 9600
ComputerConfig.ReferenceBaudRate = 9600
ComputerConfig.ReferenceBootDurationMs = KIPN.Shared.DEFAULT_BOOT_DURATION_MS or 8000

------------------------------------------------------------
-- SAFETY LIMITS
------------------------------------------------------------

ComputerConfig.MinBaudRate = 300
ComputerConfig.MaxBaudRate = 1000000
ComputerConfig.MinBootDurationMs = 1000
ComputerConfig.MaxBootDurationMs = 60000

------------------------------------------------------------
-- COMPUTER CONDITION
------------------------------------------------------------
--
-- Field names below are required to match their sandbox option
-- suffix exactly (KIPN.<Name>), since KIPN.Server.Settings.
-- ApplyToConfig() copies SandboxVars.KIPN.<Name> onto
-- ComputerConfig.<Name> generically by name.
------------------------------------------------------------

-- 1 = Good, 2 = Normal (default), 3 = Bad -- see
-- KIPN.Shared.ComputerConditionPresetOrder.
ComputerConfig.ComputerConditionInitial = 2

-- Tier multipliers are integer "x10" fixed point: 0 = tier off,
-- 10 = 1.0x, 20 = 2.0x, etc.
ComputerConfig.ComputerConditionPowerOffTier1Multiplier = 0
ComputerConfig.ComputerConditionPowerOffTier2Multiplier = 0
ComputerConfig.ComputerConditionPowerOffTier3Multiplier = 0

-- 1 = 1 Month, 2 = 1 Year (default), 3 = 5 Years -- see
-- KIPN.Shared.ComputerConditionTimeFrameOrder.
ComputerConfig.ComputerConditionNaturalDegradationTimeFrame = 2

-- Plain percent-per-timeframe (NOT an x10 multiplier): 20 = 20%
-- Hardware Condition lost per timeframe elapsed. 0 = off.
ComputerConfig.ComputerConditionNaturalDegradationMultiplier = 20

-- Integer "x10" fixed point applied to the base 10%-per-100-uses
-- degradation. 0 = off.
ComputerConfig.ComputerConditionUseDegradationMultiplier = 10

-- Integer "x10" fixed point scaling Electrical-level disassemble
-- degradation. 10 = 1.0x = no scaling effect.
ComputerConfig.ComputerConditionElectricalLevelDisassembleMultiplier = 10

-- Base Disassemble Computer timed-action duration (action-time
-- units, at Electrical level 0). Not read server-side today -- the
-- client independently resolves the scaled duration from
-- SandboxVars -- kept here for consistency with every other
-- Computer Condition field and in case server-side use is ever
-- needed.
ComputerConfig.ComputerConditionDismantleTime = 200

------------------------------------------------------------
-- COMPUTER CONDITION: REPAIR
------------------------------------------------------------
--
-- Repairing a computer (crafting/applying a Computer Repair Kit to
-- it) restores Hardware Condition, mirroring the Disassemble
-- degradation formula in reverse -- see handleRepairComputer() in
-- KIPN_Server.lua.
------------------------------------------------------------

-- Integer "x10" fixed point overall scalar applied to the base
-- random(2-8)% Hardware Condition restored per repair. 0 = repair
-- disabled entirely. 10 = 1.0x = the literal 2-8% default.
ComputerConfig.ComputerConditionRepairPercentage = 10

-- Integer "x10" fixed point scaling how much the repairing player's
-- Electrical skill level increases the amount restored. Unlike
-- ComputerConditionElectricalLevelDisassembleMultiplier (which
-- defaults to a neutral 1.0x, since more skill causing more damage
-- is not something players should be penalized with by default),
-- Electrical XP is intended to matter for repair out of the box:
-- the default of 100 (10.0x) means a level-10 Electrical player's
-- best possible roll (8%) reaches the 75% hard cap below, while a
-- fresh level-0 player stays at the flat 2-8% base. 0 turns off XP
-- scaling entirely (repair stays flat 2-8% regardless of level).
ComputerConfig.ComputerConditionRepairElectricalXPMultiplier = 100

-- Base Repair Computer timed-action duration (action-time units, at
-- Electrical level 0). Not read server-side today -- the client
-- independently resolves the scaled duration from SandboxVars --
-- kept here for consistency with every other Computer Condition
-- field and in case server-side use is ever needed.
ComputerConfig.ComputerConditionRepairTime = 200

------------------------------------------------------------
-- SANDBOX OVERRIDES
------------------------------------------------------------
--
-- Admin-editable fields, defined in sandbox-options.txt under the
-- "KIPN" page. Safety limits are applied first, then defaults are
-- clamped into range so an admin can't set e.g. DefaultBaudRate
-- outside of Min/MaxBaudRate.
------------------------------------------------------------

local function applySandboxOverrides()
    local sv = SandboxVars and SandboxVars.KIPN

    if not sv then
        print(
            "[KIPN COMPUTER CONFIG] SandboxVars.KIPN not available " ..
            "yet; keeping hardcoded defaults."
        )
        return
    end

    if sv.MinBaudRate ~= nil then
        ComputerConfig.MinBaudRate = sv.MinBaudRate
    end

    if sv.MaxBaudRate ~= nil then
        ComputerConfig.MaxBaudRate = sv.MaxBaudRate
    end

    if sv.MinBootDurationMs ~= nil then
        ComputerConfig.MinBootDurationMs = sv.MinBootDurationMs
    end

    if sv.MaxBootDurationMs ~= nil then
        ComputerConfig.MaxBootDurationMs = sv.MaxBootDurationMs
    end

    if ComputerConfig.MinBaudRate > ComputerConfig.MaxBaudRate then
        print(
            "[KIPN COMPUTER CONFIG] WARNING: MinBaudRate > MaxBaudRate " ..
            "in Sandbox Settings; clamping."
        )
        ComputerConfig.MinBaudRate = ComputerConfig.MaxBaudRate
    end

    if ComputerConfig.MinBootDurationMs > ComputerConfig.MaxBootDurationMs then
        print(
            "[KIPN COMPUTER CONFIG] WARNING: MinBootDurationMs > " ..
            "MaxBootDurationMs in Sandbox Settings; clamping."
        )
        ComputerConfig.MinBootDurationMs = ComputerConfig.MaxBootDurationMs
    end

    local function clamp(value, minValue, maxValue)
        if value < minValue then return minValue end
        if value > maxValue then return maxValue end
        return value
    end

    if sv.DefaultBaudRate ~= nil then
        ComputerConfig.DefaultBaudRate = clamp(
            sv.DefaultBaudRate,
            ComputerConfig.MinBaudRate,
            ComputerConfig.MaxBaudRate
        )
    end

    if sv.ReferenceBaudRate ~= nil then
        ComputerConfig.ReferenceBaudRate = clamp(
            sv.ReferenceBaudRate,
            ComputerConfig.MinBaudRate,
            ComputerConfig.MaxBaudRate
        )
    end

    if sv.ReferenceBootDurationMs ~= nil then
        ComputerConfig.ReferenceBootDurationMs = clamp(
            sv.ReferenceBootDurationMs,
            ComputerConfig.MinBootDurationMs,
            ComputerConfig.MaxBootDurationMs
        )
    end

    ----------------------------------------------------------------
    -- COMPUTER CONDITION
    ----------------------------------------------------------------

    if sv.ComputerConditionInitial ~= nil then
        ComputerConfig.ComputerConditionInitial = clamp(
            sv.ComputerConditionInitial, 1, 3
        )
    end

    if sv.ComputerConditionPowerOffTier1Multiplier ~= nil then
        ComputerConfig.ComputerConditionPowerOffTier1Multiplier = clamp(
            sv.ComputerConditionPowerOffTier1Multiplier, 0, 200
        )
    end

    if sv.ComputerConditionPowerOffTier2Multiplier ~= nil then
        ComputerConfig.ComputerConditionPowerOffTier2Multiplier = clamp(
            sv.ComputerConditionPowerOffTier2Multiplier, 0, 200
        )
    end

    if sv.ComputerConditionPowerOffTier3Multiplier ~= nil then
        ComputerConfig.ComputerConditionPowerOffTier3Multiplier = clamp(
            sv.ComputerConditionPowerOffTier3Multiplier, 0, 200
        )
    end

    if sv.ComputerConditionNaturalDegradationTimeFrame ~= nil then
        ComputerConfig.ComputerConditionNaturalDegradationTimeFrame = clamp(
            sv.ComputerConditionNaturalDegradationTimeFrame, 1, 3
        )
    end

    if sv.ComputerConditionNaturalDegradationMultiplier ~= nil then
        ComputerConfig.ComputerConditionNaturalDegradationMultiplier = clamp(
            sv.ComputerConditionNaturalDegradationMultiplier, 0, 100
        )
    end

    if sv.ComputerConditionUseDegradationMultiplier ~= nil then
        ComputerConfig.ComputerConditionUseDegradationMultiplier = clamp(
            sv.ComputerConditionUseDegradationMultiplier, 0, 100
        )
    end

    if sv.ComputerConditionElectricalLevelDisassembleMultiplier ~= nil then
        ComputerConfig.ComputerConditionElectricalLevelDisassembleMultiplier = clamp(
            sv.ComputerConditionElectricalLevelDisassembleMultiplier, 0, 100
        )
    end

    if sv.ComputerConditionDismantleTime ~= nil then
        ComputerConfig.ComputerConditionDismantleTime = clamp(
            sv.ComputerConditionDismantleTime, 20, 2000
        )
    end

    if sv.ComputerConditionRepairPercentage ~= nil then
        ComputerConfig.ComputerConditionRepairPercentage = clamp(
            sv.ComputerConditionRepairPercentage, 0, 100
        )
    end

    if sv.ComputerConditionRepairElectricalXPMultiplier ~= nil then
        ComputerConfig.ComputerConditionRepairElectricalXPMultiplier = clamp(
            sv.ComputerConditionRepairElectricalXPMultiplier, 0, 200
        )
    end

    if sv.ComputerConditionRepairTime ~= nil then
        ComputerConfig.ComputerConditionRepairTime = clamp(
            sv.ComputerConditionRepairTime, 20, 2000
        )
    end
end

------------------------------------------------------------
-- INITIALIZE
------------------------------------------------------------

function ComputerConfig.Initialize()
    applySandboxOverrides()
    print("[KIPN COMPUTER CONFIG] Initialized.")
    return true
end