require "SVSBT_Shared"

SVSBT.Config = SVSBT.Config or {}
local Config = SVSBT.Config
local Logger = SVSBT.Logger

Config.Defaults = {
    Enabled = true, EntryTrapsEnabled = true, AdvancedTrapsEnabled = true, VehicleDevicesEnabled = true,
    WaterBucketEnabled = true, NailBoardEnabled = true, BearTrapEnabled = true, ShotgunDoorEnabled = true,
    TripWireEnabled = true,
    ExplosiveMailboxEnabled = true, AnthraxEnabled = true, IgnitionChargeEnabled = true,
    DriverSeatDyeEnabled = true, TamperAlarmEnabled = true, RemoteImmobilizerEnabled = true,
    RespectSafehouses = true,
    OfflineTrapOperation = true, DisableExistingWhenFeatureOff = true,
    RemoveTrapsOnOwnerDeath = false, MinimumOwnerSurvivalHours = 6,
    TrapExpirationDays = 60, SpentTrapCleanupHours = 24,
    TargetPlayers = true, TargetZombies = true, TargetAnimals = true, TargetVehicles = true,
    MaxActiveTrapsPerPlayer = 20, MaxAdvancedTrapsPerPlayer = 8, MaxTrapsPerSquare = 1,
    MaxDevicesPerVehicle = 2, MaxTrapsPerMailbox = 1, MaxTrapsPerSafehouse = 8,
    MinimumTrapSpacingTiles = 1, InteractionRangeTiles = 2.5,
    WaterBucketCarpentryLevel = 1, NailBoardCarpentryLevel = 4,
    BearTrapTrappingLevel = 3, BearTrapWeldingLevel = 5,
    ShotgunDoorCarpentryLevel = 3, ShotgunDoorAimingLevel = 3,
    AdvancedElectricalLevel = 3, AdvancedMechanicsLevel = 3, AdvancedMaintenanceLevel = 4,
    BiologicalFirstAidLevel = 5, InspectionElectricalLevel = 2,
    DisarmElectricalLevel = 3, DisarmMechanicsLevel = 3, DisarmMaintenanceLevel = 3,
    CraftingTimeMultiplier = 1.0, PlacementTimeSeconds = 8, VehicleInstallTimeSeconds = 16,
    InspectionTimeSeconds = 7, DisarmTimeSeconds = 12, ResetTimeSeconds = 10, RepairTimeSeconds = 15,
    FreeBearTrapTimeSeconds = 4,
    DamageMultiplier = 1.0, ConditionLossMultiplier = 1.0, DetectionChanceMultiplier = 1.0,
    DisarmSuccessMultiplier = 1.0, SalvageChance = 0.35, RarePartSalvageChance = 0.15,
    XPMultiplier = 1.0, DisarmFailureTriggersTrap = true, ReverseDisarmEnabled = true,
    TrapLootMultiplier = 1.0,
    -- Every SVSBT sound is played by the server and heard by everyone in
    -- range; the paired Radius/Volume settings feed the world sound each one
    -- also lays down, so nearby zombies come to investigate. Setting a trap,
    -- setting one off, and hunting for one are all audible acts.
    TrapSetSoundEnabled = true, TrapSetSoundRadiusTiles = 15, TrapSetSoundVolume = 30,
    -- The same five clips as a set, sounded from the trap's own tile when it
    -- goes off. Louder and further than setting one: a trap firing is not
    -- subtle, and whatever it just caught is making noise of its own.
    TrapDetonationSoundEnabled = true, TrapDetonationSoundRadiusTiles = 20, TrapDetonationSoundVolume = 40,
    -- Searching, then found/nothing-found. Quieter than the other two --
    -- rummaging over a suspicious tile, not detonating anything -- but still
    -- enough that standing around hunting for traps can be overheard.
    InspectionSoundsEnabled = true, InspectionSoundRadiusTiles = 10, InspectionSoundVolume = 15,
    VisibleFloorTrapIcons = true, FloorTrapIconRangeTiles = 12, FloorTrapIconScale = 1.0,
    VisibleIndicatorsRequireLOS = true, VisibleIndicatorsCurrentFloorOnly = true,
    TripWireVisible = true, PassiveAdvancedDetection = false,
    PassiveDetectionRangeTiles = 2, OwnerAlwaysKnowsTrap = true, ShareKnowledgeWithFaction = false,
    WaterBucketWetness = 100, WaterBucketClothingWetness = 100,
    WaterBucketDamage = 1.0,
    NailBoardBaseDamage = 18.0, NailBoardLacerationChance = 0.45,
    NailBoardFootwearProtection = 0.45, NailBoardFootwearDamage = 12,
    NailBoardDamagesTires = true, NailBoardTireDamage = 18,
    BearTrapBaseDamage = 42.0, BearTrapFractureChance = 0.30, BearTrapEscapeDamage = 35.0,
    BearTrapHoldDamagePerTick = 0.04,
    BearTrapConditionLossChance = 0.35, BearTrapActivationConditionLoss = 35,
    BearTrapFailedSetConditionLoss = 15, BearTrapSettingRiskMultiplier = 1.0,
    BearTrapRepairAmountPerRod = 20,
    BearTrapMaxConditionLossPerRepair = 5,
    -- A real close-range shotgun blast to the torso is typically lethal or
    -- near-lethal in PZ's own PVP combat -- 100 maxes out the torso's own
    -- health pool in one hit (BodyPart:ReduceHealth is a 0-100 scale),
    -- matching that intensity instead of a survivable, "just a wound" hit.
    ShotgunDoorDamage = 100.0, ShotgunDoorDeepWoundChance = 0.75, ShotgunDoorLacerationChance = 0.95,
    ExplosiveFuseSeconds = 0.9, ExplosiveInnerRadiusTiles = 1.25,
    ExplosiveMiddleRadiusTiles = 2.5, ExplosiveOuterRadiusTiles = 4.0,
    ExplosiveInnerDamage = 50.0, ExplosiveMiddleDamage = 24.0, ExplosiveOuterDamage = 10.0,
    ExplosiveDeepWoundChance = 0.80, ExplosiveLacerationChance = 0.90,
    ExplosiveDestroysMailboxContents = true, ExplosiveFireChance = 0.0,
    ExplosiveSoundRadiusTiles = 100,
    -- AnthraxInitialDamage lands immediately on exposure; the REMAINDER of
    -- AnthraxTotalDamage (i.e. AnthraxTotalDamage - AnthraxInitialDamage) is
    -- spread evenly across the rest of the illness, tick by tick. Neither
    -- ever pushes the victim below AnthraxNeverLethalFloor -- anthrax alone
    -- should make you sick, not kill you.
    AnthraxInitialDamage = 20.0, AnthraxTotalDamage = 50.0, AnthraxNeverLethalFloor = 5.0,
    AnthraxDurationHours = 12.0, AnthraxTickSeconds = 30,
    AnthraxSicknessPerTick = 0.035, AnthraxReminderSeconds = 600,
    AnthraxMaskProtection = 0.50, AnthraxGloveProtection = 0.25,
    AnthraxAntibioticProtection = 0.50,
    -- Owner must retreat this far before an opened sample goes live; it then
    -- stays a live hazard for BiologicalSampleDurationHours, gassing anyone
    -- who lingers within BiologicalSampleRadiusTiles (each exposure runs the
    -- same AnthraxDurationHours illness as a contaminated document).
    BiologicalSampleDurationHours = 72.0,
    BiologicalSampleRadiusTiles = 2, NeutralizeBiologicalAgentSeconds = 10,
    IgnitionFuseSeconds = 0.75, IgnitionDriverDamage = 42.0, IgnitionEngineDamage = 55,
    IgnitionBurnDurationSeconds = 45, IgnitionReigniteSeconds = 4,
    DyeDurationDays = 7, DyeClothingDirtiness = 100, DyeDamageMin = 15.0, DyeDamageMax = 30.0,
    TamperAlarmSoundRadiusTiles = 120, TamperAlarmDurationSeconds = 8,
    TripWireMaxLengthTiles = 8, TripWireSoundRadiusTiles = 60,
    TripWireCooldownHours = 2.0, TripWireMaxTriggers = 3,
    WirelessRangeTiles = 1000, WirelessHeartbeatEnabled = true, WirelessHeartbeatSeconds = 15,
    SignalsIntegrationEnabled = true, SignalsJammersBlockAlerts = true,
    SignalsJammersBlockCommands = true, SignalsDetectorFindsWirelessTraps = true,
    WirelessDetectionRangeTiles = 40,
    AdminOverlayEnabled = true, AdminRemovalRadiusTiles = 20,
    AuditLogging = true, VerboseLogging = false, MetaTimeRunLogEntries = 1000,
    VisibleSyncSeconds = 2, ServerTickMilliseconds = 500,
    MaxTrapsProcessedPerTick = 200, PersistenceIntervalSeconds = 10,
}

function Config.Get(name)
    local run = Logger.Begin("Config.Get", name)
    local default = Config.Defaults[name]
    local value = default

    if SandboxVars and type(SandboxVars.SVSBoobyTraps) == "table" then
        local sandboxValue = SandboxVars.SVSBoobyTraps[name]

        if sandboxValue ~= nil then
            value = sandboxValue
        end
    end

    if type(default) == "boolean" then
        -- A synced sandbox boolean doesn't always arrive as a real Lua
        -- boolean -- some client-side reconstructions of SandboxVars hand
        -- back a number (0/1) or string for what the server itself sees as
        -- a literal true/false. `value == true` silently reads that as
        -- false regardless of the actual configured value, which is
        -- serious: it's the same coercion every boolean setting in this mod
        -- goes through, so a busted read here can silently disable Audit
        -- logging, feature toggles, or any other switch on affected clients
        -- with zero visible error. Accept the common truthy encodings too.
        if type(value) == "number" then
            value = value ~= 0
        elseif type(value) == "string" then
            local lowered = string.lower(value)
            value = lowered == "true" or lowered == "1" or lowered == "yes"
        else
            value = value == true
        end
    elseif type(default) == "number" then
        value = tonumber(value) or default
    elseif default == nil then
        Logger.Warn("Config.Get", "unknown setting=" .. tostring(name))
    end

    Logger.Finish(run, true, tostring(name) .. "=" .. tostring(value))
    return value
end

function Config.RefreshLogging()
    local run = Logger.Begin("Config.RefreshLogging")
    Logger.SetOptions(Config.Get("VerboseLogging"), Config.Get("AuditLogging"), Config.Get("MetaTimeRunLogEntries"))
    Logger.Finish(run, true)
    return true
end

function Config.Snapshot()
    local run = Logger.Begin("Config.Snapshot")
    local result = {}

    for name, _ in pairs(Config.Defaults) do
        result[name] = Config.Get(name)
    end

    Logger.Finish(run, true, "counted settings")
    return result
end

Logger.Info("SVSBT_Config.load", "configuration defaults initialized")

return Config
