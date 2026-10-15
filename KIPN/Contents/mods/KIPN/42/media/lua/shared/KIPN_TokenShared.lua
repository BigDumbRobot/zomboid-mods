-- KIPN_TokenShared.lua
--
-- KIPN shared token/artifact contracts.
--
-- Loaded by KIPN.lua after KIPN_Shared.lua.
--
-- Responsibilities:
--   * Token state identifiers
--   * Token type identifiers
--   * Token lifecycle identifiers
--   * Token protocol identifiers
--   * Shared token constants
--   * Lightweight token contract validation
--
-- This file is safe to load on both client and server.
--
-- IMPORTANT:
--
-- Registration items and claim tokens are BEARER ARTIFACTS.
--
-- They are NOT owned by a player.
--
-- This file must NOT:
--   * access persistent server data
--   * access KIPN.Server
--   * create token records
--   * consume tokens
--   * issue tokens
--   * invalidate tokens
--   * inspect player inventory
--   * establish ownership
--   * process claims
--   * determine valid zones
--   * create physical inventory items
--
-- Those responsibilities belong to the appropriate services.
--
-- Server implementation:
--   KIPN_TokenServer.lua
--
-- Client implementation:
--   KIPN_Token.lua
--
-- KIPN_TokenShared.lua is a CONTRACT ONLY.

--------------------------------------------------------------------
-- CORE DEPENDENCY CHECK
--------------------------------------------------------------------

if not KIPN then

    error(
        "[KIPN_TOKEN_SHARED] " ..
        "KIPN core is not initialized."
    )

end

if not KIPN.Logger then

    error(
        "[KIPN_TOKEN_SHARED] " ..
        "KIPN.Logger is not initialized."
    )

end

if not KIPN.Shared then

    error(
        "[KIPN_TOKEN_SHARED] " ..
        "KIPN.Shared is not initialized."
    )

end

--------------------------------------------------------------------
-- TOKEN NAMESPACE
--------------------------------------------------------------------

KIPN.Token =
    KIPN.Token or {}

--------------------------------------------------------------------
-- LOCAL LOGGING HELPERS
--------------------------------------------------------------------

local function logError(message)

    KIPN.Logger.Error(
        "[KIPN.TokenShared] " ..
        tostring(message)
    )

end

--------------------------------------------------------------------
-- TOKEN STATES
--
-- These are protocol/domain identifiers.
--
-- They do NOT perform state transitions.
--
-- State transitions remain server authoritative.
--------------------------------------------------------------------

KIPN.Token.STATES = {

    PENDING =
        "pending",

    ISSUED =
        "issued",

    CONSUMED =
        "consumed",

    INVALID =
        "invalid",

    EXPIRED =
        "expired",
}

--------------------------------------------------------------------
-- TOKEN TYPES
--------------------------------------------------------------------

KIPN.Token.TYPES = {

    REGISTRATION =
        "registration",

    CLAIM =
        "claim",
}

--------------------------------------------------------------------
-- TOKEN PROTOCOL
--
-- IMPORTANT:
--
-- Token commands are centralized in KIPN.Shared.Commands.
--
-- KIPN.Token does not create a second network command registry.
--
-- This table only provides convenient aliases for token-specific
-- code.
--------------------------------------------------------------------

KIPN.Token.Commands = {

    GET =
        KIPN.Shared.Commands.TOKEN_GET,

    INSPECT =
        KIPN.Shared.Commands.TOKEN_INSPECT,

    VALIDATE =
        KIPN.Shared.Commands.TOKEN_VALIDATE,

    GET_STATE =
        KIPN.Shared.Commands.TOKEN_GET_STATE,

    GET_METADATA =
        KIPN.Shared.Commands.TOKEN_GET_METADATA,
}

--------------------------------------------------------------------
-- TOKEN RESPONSE IDENTIFIERS
--
-- These resolve to the centralized shared response contract.
--------------------------------------------------------------------

KIPN.Token.Responses = {

    DATA =
        KIPN.Shared.ResponseEvents.TOKEN_DATA,

    VALID =
        KIPN.Shared.ResponseEvents.TOKEN_VALID,

    INVALID =
        KIPN.Shared.ResponseEvents.TOKEN_INVALID,

    ISSUED =
        KIPN.Shared.ResponseEvents.TOKEN_ISSUED,

    CONSUMED =
        KIPN.Shared.ResponseEvents.TOKEN_CONSUMED,

    INVALIDATED =
        KIPN.Shared.ResponseEvents.TOKEN_INVALIDATED,

    EXPIRED =
        KIPN.Shared.ResponseEvents.TOKEN_EXPIRED,

    ERROR =
        KIPN.Shared.ResponseEvents.TOKEN_ERROR,

    INSPECTION =
        KIPN.Shared.ResponseEvents.TOKEN_INSPECTION,
}

--------------------------------------------------------------------
-- TOKEN VALIDATION REASONS
--------------------------------------------------------------------

KIPN.Token.REASONS = {

    MISSING_TOKEN =
        "missing_token",

    NOT_FOUND =
        "not_found",

    NOT_ISSUED =
        "not_issued",

    CONSUMED =
        "consumed",

    INVALID =
        "invalid",

    EXPIRED =
        "expired",

    INVALID_STATE =
        "invalid_state",

    INVALID_TYPE =
        "invalid_type",

    INVALID_SUBTYPE =
        "invalid_subtype",

    INVALID_METADATA =
        "invalid_metadata",

    INVALID_TOKEN =
        "invalid_token",

    TIME_UNAVAILABLE =
        "time_unavailable",

    SAVE_UNAVAILABLE =
        "save_unavailable",

    PERSISTENCE_FAILED =
        "persistence_failed",

    ALREADY_INVALID =
        "already_invalid",
}

--------------------------------------------------------------------
-- TOKEN LIFECYCLE
--
-- Descriptive only.
--
-- This table does NOT authorize transitions.
--------------------------------------------------------------------

KIPN.Token.LIFECYCLE = {

    CREATED =
        KIPN.Token.STATES.PENDING,

    ISSUED =
        KIPN.Token.STATES.ISSUED,

    CONSUMED =
        KIPN.Token.STATES.CONSUMED,

    INVALID =
        KIPN.Token.STATES.INVALID,

    EXPIRED =
        KIPN.Token.STATES.EXPIRED,
}

--------------------------------------------------------------------
-- TERMINAL STATES
--------------------------------------------------------------------

KIPN.Token.TERMINAL_STATES = {

    [KIPN.Token.STATES.CONSUMED] =
        true,

    [KIPN.Token.STATES.INVALID] =
        true,

    [KIPN.Token.STATES.EXPIRED] =
        true,
}

--------------------------------------------------------------------
-- BEARER ARTIFACT FLAG
--------------------------------------------------------------------

KIPN.Token.IS_BEARER_ARTIFACT =
    true

--------------------------------------------------------------------
-- OWNERSHIP MODEL
--------------------------------------------------------------------

KIPN.Token.OWNERSHIP = {

    PLAYER_OWNED =
        false,

    OWNERSHIP_ESTABLISHED_ON_CLAIM =
        true,
}

--------------------------------------------------------------------
-- TOKEN ID PREFIXES
--------------------------------------------------------------------

KIPN.Token.PREFIXES = {

    REGISTRATION =
        "REGISTRATION",

    CLAIM =
        "CLAIM",

    TOKEN =
        "TOKEN",
}

--------------------------------------------------------------------
-- VALIDATE TOKEN TYPE
--------------------------------------------------------------------

function KIPN.Token.IsValidType(
    tokenType
)

    if type(tokenType) ~= "string"
        or tokenType == "" then

        return false
    end

    for _, value in pairs(
        KIPN.Token.TYPES
    ) do

        if value == tokenType then

            return true
        end

    end

    return false
end

--------------------------------------------------------------------
-- VALIDATE TOKEN STATE
--------------------------------------------------------------------

function KIPN.Token.IsValidState(
    state
)

    if type(state) ~= "string"
        or state == "" then

        return false
    end

    for _, value in pairs(
        KIPN.Token.STATES
    ) do

        if value == state then

            return true
        end

    end

    return false
end

--------------------------------------------------------------------
-- IS TERMINAL STATE
--------------------------------------------------------------------

function KIPN.Token.IsTerminalState(
    state
)

    if state == nil then

        return false
    end

    local terminal =
        KIPN.Token.TERMINAL_STATES[state] == true

    return terminal
end

--------------------------------------------------------------------
-- IS BEARER ARTIFACT
--------------------------------------------------------------------

function KIPN.Token.IsBearerArtifact(
    token
)

    if type(token) ~= "table" then

        return false
    end

    ------------------------------------------------------------
    -- Explicitly reject player ownership fields.
    --
    -- A token must never acquire ownership semantics merely
    -- because another module accidentally adds one of these
    -- fields.
    ------------------------------------------------------------

    if token.playerId ~= nil
        or token.steamId ~= nil
        or token.username ~= nil
        or token.accountId ~= nil then

        logError(
            "IsBearerArtifact failed: token contains " ..
            "player ownership data."
        )

        return false
    end

    return true
end

--------------------------------------------------------------------
-- BASIC TOKEN CONTRACT VALIDATION
--------------------------------------------------------------------

function KIPN.Token.IsValidRecord(
    token
)

    if type(token) ~= "table" then

        return false
    end

    ------------------------------------------------------------
    -- TOKEN ID
    ------------------------------------------------------------

    if type(token.id) ~= "string"
        or token.id == "" then

        return false
    end

    ------------------------------------------------------------
    -- TYPE
    ------------------------------------------------------------

    if not KIPN.Token.IsValidType(
        token.type
    ) then

        return false
    end

    ------------------------------------------------------------
    -- SUBTYPE
    ------------------------------------------------------------

    if type(token.subtype) ~= "string"
        or token.subtype == "" then

        return false
    end

    ------------------------------------------------------------
    -- STATE
    ------------------------------------------------------------

    if not KIPN.Token.IsValidState(
        token.state
    ) then

        return false
    end

    ------------------------------------------------------------
    -- CREATED AT
    ------------------------------------------------------------

    if tonumber(
        token.createdAt
    ) == nil then

        return false
    end

    ------------------------------------------------------------
    -- EXPIRES AT
    ------------------------------------------------------------

    if tonumber(
        token.expiresAt
    ) == nil then

        return false
    end

    ------------------------------------------------------------
    -- EXPIRATION CONSISTENCY
    ------------------------------------------------------------

    if tonumber(token.expiresAt)
        < tonumber(token.createdAt) then

        return false
    end

    ------------------------------------------------------------
    -- METADATA
    ------------------------------------------------------------

    if token.metadata ~= nil
        and type(token.metadata) ~= "table" then

        return false
    end

    ------------------------------------------------------------
    -- OWNERSHIP
    ------------------------------------------------------------

    if not KIPN.Token.IsBearerArtifact(
        token
    ) then

        return false
    end

    ------------------------------------------------------------
    -- VALID
    ------------------------------------------------------------

    return true
end

--------------------------------------------------------------------
-- TOKEN STATE HELPERS
--------------------------------------------------------------------

function KIPN.Token.IsPending(
    state
)

    return state ==
        KIPN.Token.STATES.PENDING
end

------------------------------------------------------------

function KIPN.Token.IsIssued(
    state
)

    return state ==
        KIPN.Token.STATES.ISSUED
end

------------------------------------------------------------

function KIPN.Token.IsConsumed(
    state
)

    return state ==
        KIPN.Token.STATES.CONSUMED
end

------------------------------------------------------------

function KIPN.Token.IsInvalid(
    state
)

    return state ==
        KIPN.Token.STATES.INVALID
end

------------------------------------------------------------

function KIPN.Token.IsExpired(
    state
)

    return state ==
        KIPN.Token.STATES.EXPIRED
end

--------------------------------------------------------------------
-- SHARED INITIALIZATION
--------------------------------------------------------------------

return KIPN.Token