SacrificialOffering = SacrificialOffering or {}

local SO = SacrificialOffering

SO.VERSION = "1.0.0"
SO.BUILD_TARGET = "42.20"
SO.MODULE = "SacrificialOffering"
SO.MOD_DATA_KEY = "SacrificialOffering"
SO.SCHEMA_VERSION = 1
SO.ZONE_MODE = "SO_SatanicTemples"
-- Build 42 only allows dragged human corpses to be thrown into a fixed set of
-- container types.  "dumpster" is the type matching this fixture and keeps the
-- native "Drop Corpse Into..." interaction available.
SO.ALTAR_CONTAINER_TYPE = "dumpster"
SO.ALTAR_NAME = "Sacrificial Altar"
SO.CAMPFIRE_NAME = "Campfire"
SO.MIN_ZONE_SIZE_DEFAULT = 7
SO.MAX_ZONE_SIZE_DEFAULT = 100
SO.MAX_INTERACTION_DISTANCE = 3.25
-- Length of the recovery ritual channel. The verdict of an offering is revealed
-- only when it ends (SO_OfferingService / SO_OfferingAction).
SO.RITUAL_SECONDS = 47.5

SO.MOD_DATA = {
    PROTECTED = "SO_Protected",
    FIXTURE_KIND = "SO_FixtureKind",
    ZONE_ID = "SO_ZoneId",
    ALTAR_ID = "SO_AltarId",
    CAMPFIRE_X = "SO_CampfireX",
    CAMPFIRE_Y = "SO_CampfireY",
    CAMPFIRE_Z = "SO_CampfireZ",
    CORPSE_OWNER = "SO_CorpseOwner",
    CORPSE_ONLINE_ID = "SO_CorpseOnlineId",
    CORPSE_PLAYER_NAME = "SO_CorpsePlayerName",
    CARRIED_CORPSE = "SO_CarriedCorpse",
}

SO.FIXTURE = {
    ALTAR = "altar",
    ALTAR_BACK = "altarBack",
    PENTAGRAM = "pentagram",
    CAMPFIRE = "campfire",
    MANNEQUIN = "mannequin",
    LANTERN = "lantern",
}

SO.COMMAND = {
    REQUEST_ZONES = "RequestZones",
    CREATE_ZONE = "CreateZone",
    RESIZE_ZONE = "ResizeZone",
    RENAME_ZONE = "RenameZone",
    DELETE_ZONE = "DeleteZone",
    BEGIN_OFFERING = "BeginOffering",
    MAKE_OFFERING = "MakeOffering",
    DEATH_NOTICE = "DeathNotice",
    PURGE_ZONES = "PurgeZones",
    RELIC_THEFT = "RelicTheft",
}

SO.SERVER_COMMAND = {
    SYNC_ZONES = "SyncZones",
    RESULT = "Result",
    EFFECT = "Effect",
    SOUND_CUE = "SoundCue",
}

SO.RESULT = {
    INFO = "info",
    ERROR = "error",
    INVALID = "invalid",
    SUCCESS_ITEM = "successItem",
    SUCCESS_CORPSE = "successCorpse",
    WRATH = "wrath",
    SELF_CORPSE = "selfCorpse",
}

SO.EFFECT = {
    FLAME = "flame",
    SMOKE = "smoke",
    WRATH_SMOKE = "wrathSmoke",
    TRANCE = "trance",
    LIGHTNING = "lightning",
}

SO.SOUND_OUTCOME = {
    -- Ritual start: identical for every offering, so it reveals nothing.
    PENDING = "pending",
    FAILURE = "failure",
    SUCCESS_ITEM = "successItem",
    PLAYER_CORPSE = "playerCorpse",
}

SO.TRANSLATION = {
    INVALID = "IGUI_SO_InvalidOffering",
    SUCCESS_ITEM = "IGUI_SO_SuccessItem",
    SUCCESS_CORPSE = "IGUI_SO_SuccessCorpse",
    SUCCESS_CORPSE_PRIZE = "IGUI_SO_SuccessCorpsePrize",
    WRATH = "IGUI_SO_Wrath",
    MINOR_WRATH = "IGUI_SO_MinorWrath",
    SELF_CORPSE = "IGUI_SO_SelfCorpse",
    ZONE_OVERLAP = "IGUI_SO_ZoneOverlap",
    ZONE_INVALID = "IGUI_SO_ZoneInvalid",
    NOT_AUTHORIZED = "IGUI_SO_NotAuthorized",
    NO_RECOVERY = "IGUI_SO_NoRecoveryAvailable",
    NO_UPGRADE = "IGUI_SO_NoRecoveryUpgrade",
    BUSY = "IGUI_SO_AltarBusy",
    RELIC_THEFT = "IGUI_SO_RelicTheft",
}

return SO
