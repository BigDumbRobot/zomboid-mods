-- KIPN_TokenServer.lua
--
-- KIPN server-authoritative token/artifact service.
--
-- Responsibilities:
--   * Create token records
--   * Retrieve token records
--   * Validate token records
--   * Handle expiration
--   * Consume tokens
--   * Invalidate tokens
--   * Generate unique token IDs
--
-- IMPORTANT:
--
-- Registration items and claim tokens are BEARER ARTIFACTS.
--
-- They are intentionally NOT owned by a player.
--
-- Ownership is established only when the final claim token
-- is successfully activated by the appropriate claim service.
--
-- Token lifecycle:
--
--   REGISTRATION ITEM
--          |
--          v
--   REGISTRATION PROCESS
--          |
--          v
--      CLAIM TOKEN
--          |
--          v
--      ACTIVATION
--          |
--          v
--     ACTIVE CLAIM
--
-- This service does NOT:
--   * determine whether a player is in a valid zone
--   * inspect player inventory directly
--   * create physical inventory items
--   * establish claim ownership
--   * process claim-specific rules
--
-- Those responsibilities belong to the appropriate services.
--
-- SERVER AUTHORITATIVE:
--
--   The client may possess a physical token item and request
--   operations involving its token ID.
--
--   The client is NEVER authoritative over:
--     * token state
--     * token expiration
--     * token metadata
--     * token ownership
--     * token consumption
--     * token invalidation
--
-- Persistence:
--
--   KIPN.Server.GetData()
--       -> data.tokens
--
-- Every state mutation is persisted through:
--
--   KIPN.Server.Save()
--
-- This file must be loaded on the SERVER only.

if isClient() and not isServer() then
    return
end

--------------------------------------------------------------------
-- NAMESPACE
--------------------------------------------------------------------

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Token = KIPN.Token or {}

--------------------------------------------------------------------
-- LOGGING
--------------------------------------------------------------------

-- FIX: KIPN.Logger.Create() returns an OBJECT, not a callable value.
-- The rest of this file calls log(message) directly, so log must be
-- a plain function delegating to the object's methods, with a print
-- fallback if the Logger isn't ready at load time. Matches the
-- pattern used in KIPN_Server.lua.
--
-- NOTE: As of the logging cleanup, the remaining call sites in this
-- file are limited to token-lifecycle transaction outcomes (create/
-- issue/consume/invalidate/expire, and their persistence failures) --
-- read-only lookups, per-check/per-retry noise, and administrative
-- init bookkeeping were judged to be noise and removed.
local tokenServerLoggerObj =
    KIPN.Logger
    and KIPN.Logger.Create
    and KIPN.Logger.Create("TokenServer")

local function log(message)

    if tokenServerLoggerObj then

        tokenServerLoggerObj:Info(message)

    else

        print(
            "[KIPN TOKEN SERVER] " ..
            tostring(message)
        )

    end
end

--------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------

KIPN.Token.STATES =
    KIPN.Token.STATES or
    {
        PENDING = "pending",
        ISSUED = "issued",
        CONSUMED = "consumed",
        INVALID = "invalid",
        EXPIRED = "expired",
    }

KIPN.Token.TYPES =
    KIPN.Token.TYPES or
    {
        REGISTRATION = "registration",
        CLAIM = "claim",
    }

--------------------------------------------------------------------
-- TIME
--------------------------------------------------------------------

local function getCurrentTime()

    local now =
        os.time()

    if not now then

        return nil
    end

    return tonumber(now)

end

--------------------------------------------------------------------
-- TOKEN REGISTRY
--------------------------------------------------------------------

local function getTokenRegistry()

    if not KIPN
        or not KIPN.Server
        or type(KIPN.Server.GetData) ~= "function" then

        return nil
    end

    local data =
        KIPN.Server.GetData()

    if not data then

        return nil
    end

    if type(data.tokens) ~= "table" then

        data.tokens = {}

    end

    return data.tokens

end

--------------------------------------------------------------------
-- SAVE HELPER
--
-- Centralizes persistence failure handling.
--------------------------------------------------------------------

local function saveTokenState()

    if type(KIPN.Server.Save) ~= "function" then

        log(
            "saveTokenState failed: " ..
            "KIPN.Server.Save() unavailable."
        )

        return false
    end

    local saved =
        KIPN.Server.Save("tokens")

    if saved == false then

        log(
            "saveTokenState failed: " ..
            "KIPN.Server.Save() returned false."
        )

        return false
    end

    return true

end

--------------------------------------------------------------------
-- TOKEN ID GENERATION
--------------------------------------------------------------------

function KIPN.Server.TokenGenerateId(
    tokenType
)

    local tokens =
        getTokenRegistry()

    if not tokens then

        return nil
    end

    local prefix =
        string.upper(
            tostring(
                tokenType
                or "TOKEN"
            )
        )

    local attempts = 0
    local tokenId = nil

    while attempts < 20 do

        attempts =
            attempts + 1

        local timestamp =
            tostring(
                getTimestampMs
                and getTimestampMs()
                or os.time()
            )

        local randomA

        if ZombRand then

            randomA =
                ZombRand(
                    100000,
                    999999
                )

        else

            randomA =
                math.random(
                    100000,
                    999999
                )

        end

        local randomB

        if ZombRand then

            randomB =
                ZombRand(
                    100000,
                    999999
                )

        else

            randomB =
                math.random(
                    100000,
                    999999
                )

        end

        tokenId =
            prefix ..
            "-" ..
            timestamp ..
            "-" ..
            tostring(randomA) ..
            "-" ..
            tostring(randomB)

        if tokens[tokenId] == nil then
            break
        end

        tokenId = nil

    end

    if not tokenId then

        return nil
    end

    return tokenId

end

--------------------------------------------------------------------
-- TOKEN CREATION
--
-- PENDING -> ISSUED is intentionally separate.
--------------------------------------------------------------------

function KIPN.Server.TokenCreate(
    tokenType,
    tokenSubtype,
    lifetimeSeconds,
    metadata
)

    ------------------------------------------------------------
    -- TYPE
    ------------------------------------------------------------

    if type(tokenType) ~= "string"
        or tokenType == "" then

        return nil
    end

    ------------------------------------------------------------
    -- SUBTYPE
    ------------------------------------------------------------

    if type(tokenSubtype) ~= "string"
        or tokenSubtype == "" then

        return nil
    end

    ------------------------------------------------------------
    -- LIFETIME
    ------------------------------------------------------------

    local lifetime =
        tonumber(
            lifetimeSeconds
        )

    if not lifetime
        or lifetime <= 0 then

        return nil
    end

    ------------------------------------------------------------
    -- METADATA
    ------------------------------------------------------------

    if metadata ~= nil
        and type(metadata) ~= "table" then

        return nil
    end

    ------------------------------------------------------------
    -- REGISTRY
    ------------------------------------------------------------

    local tokens =
        getTokenRegistry()

    if not tokens then

        log(
            "TokenCreate failed: registry unavailable."
        )

        return nil
    end

    ------------------------------------------------------------
    -- TOKEN ID
    ------------------------------------------------------------

    local tokenId =
        KIPN.Server.TokenGenerateId(
            tokenSubtype
        )

    if not tokenId then

        log(
            "TokenCreate failed: unable to generate ID."
        )

        return nil
    end

    ------------------------------------------------------------
    -- TIME
    ------------------------------------------------------------

    local now =
        getCurrentTime()

    if not now then

        log(
            "TokenCreate failed: current time unavailable."
        )

        return nil
    end

    ------------------------------------------------------------
    -- TOKEN RECORD
    ------------------------------------------------------------

    local token = {

        id =
            tokenId,

        type =
            tokenType,

        subtype =
            tokenSubtype,

        state =
            KIPN.Token.STATES.PENDING,

        createdAt =
            now,

        expiresAt =
            now + lifetime,

        issuedAt =
            nil,

        consumedAt =
            nil,

        expiredAt =
            nil,

        invalidatedAt =
            nil,

        invalidReason =
            nil,

        metadata =
            metadata or {},
    }

    ------------------------------------------------------------
    -- DEFENSIVE BEARER CHECK
    ------------------------------------------------------------

    if KIPN.Token.IsBearerArtifact
        and not KIPN.Token.IsBearerArtifact(
            token
        ) then

        log(
            "TokenCreate failed: bearer artifact contract failed."
        )

        return nil
    end

    ------------------------------------------------------------
    -- STORE
    ------------------------------------------------------------

    tokens[tokenId] =
        token

    ------------------------------------------------------------
    -- PERSIST
    ------------------------------------------------------------

    if not saveTokenState() then

        tokens[tokenId] =
            nil

        log(
            "TokenCreate failed: persistence failed. " ..
            "Token record rolled back."
        )

        return nil
    end

    log(
        "Token created successfully: " ..
        tostring(tokenId) ..
        " type=" ..
        tostring(tokenType) ..
        " subtype=" ..
        tostring(tokenSubtype)
    )

    return token

end

--------------------------------------------------------------------
-- TOKEN RETRIEVAL
--------------------------------------------------------------------

function KIPN.Server.TokenGet(
    tokenId
)

    if type(tokenId) ~= "string"
        or tokenId == "" then

        return nil
    end

    local tokens =
        getTokenRegistry()

    if not tokens then

        return nil
    end

    local token =
        tokens[tokenId]

    if not token then

        return nil
    end

    return token

end

--------------------------------------------------------------------
-- EXPIRATION CHECK
--
-- IMPORTANT:
--
-- This function does NOT mutate token state.
--------------------------------------------------------------------

function KIPN.Server.TokenIsExpired(
    token
)

    if type(token) ~= "table" then

        return true
    end

    if token.state ==
        KIPN.Token.STATES.EXPIRED then

        return true
    end

    local expiresAt =
        tonumber(
            token.expiresAt
        )

    if not expiresAt then

        return true
    end

    local now =
        getCurrentTime()

    if not now then

        return true
    end

    local expired =
        now >= expiresAt

    return expired

end

--------------------------------------------------------------------
-- TOKEN VALIDATION
--
-- Answers:
--
--   "Can this token currently be redeemed?"
--
-- Only ISSUED tokens can pass.
--------------------------------------------------------------------

function KIPN.Server.TokenValidate(
    tokenId
)

    if type(tokenId) ~= "string"
        or tokenId == "" then

        return false,
            "missing_token"
    end

    local token =
        KIPN.Server.TokenGet(
            tokenId
        )

    if not token then

        return false,
            "not_found"
    end

    if token.state ==
        KIPN.Token.STATES.CONSUMED then

        return false,
            "consumed"
    end

    if token.state ==
        KIPN.Token.STATES.INVALID then

        return false,
            "invalid"
    end

    if token.state ==
        KIPN.Token.STATES.EXPIRED then

        return false,
            "expired"
    end

    if token.state ==
        KIPN.Token.STATES.PENDING then

        return false,
            "not_issued"
    end

    if token.state ~=
        KIPN.Token.STATES.ISSUED then

        return false,
            "invalid_state"
    end

    ------------------------------------------------------------
    -- NATURAL EXPIRATION
    ------------------------------------------------------------

    if KIPN.Server.TokenIsExpired(
        token
    ) then

        log(
            "Token expired during validation: " ..
            tostring(tokenId)
        )

        local originalState =
            token.state

        local now =
            getCurrentTime()

        if not now then

            return false,
                "time_unavailable"
        end

        token.state =
            KIPN.Token.STATES.EXPIRED

        token.expiredAt =
            now

        if not saveTokenState() then

            token.state =
                originalState

            token.expiredAt =
                nil

            return false,
                "persistence_failed"
        end

        return false,
            "expired"
    end

    ------------------------------------------------------------
    -- STRUCTURAL VALIDATION
    ------------------------------------------------------------

    if KIPN.Token.IsValidRecord
        and not KIPN.Token.IsValidRecord(
            token
        ) then

        return false,
            "invalid_token"
    end

    return true,
        nil

end

--------------------------------------------------------------------
-- TOKEN ISSUE
--
-- Lifecycle:
--
--   PENDING -> ISSUED
--
-- This is an INTERNAL SERVER operation.
--
-- Client code must never be permitted to arbitrarily issue tokens.
--------------------------------------------------------------------

function KIPN.Server.TokenIssue(
    tokenId
)

    local token =
        KIPN.Server.TokenGet(
            tokenId
        )

    if not token then

        return false
    end

    if token.state ~=
        KIPN.Token.STATES.PENDING then

        log(
            "TokenIssue failed: token is not pending. " ..
            "state=" ..
            tostring(token.state)
        )

        return false
    end

    if KIPN.Server.TokenIsExpired(
        token
    ) then

        local now =
            getCurrentTime()

        if not now then

            return false
        end

        token.state =
            KIPN.Token.STATES.EXPIRED

        token.expiredAt =
            now

        if not saveTokenState() then

            token.state =
                KIPN.Token.STATES.PENDING

            token.expiredAt =
                nil

            return false
        end

        return false
    end

    local issuedAt =
        getCurrentTime()

    if not issuedAt then

        return false
    end

    token.state =
        KIPN.Token.STATES.ISSUED

    token.issuedAt =
        issuedAt

    if not saveTokenState() then

        token.state =
            KIPN.Token.STATES.PENDING

        token.issuedAt =
            nil

        return false
    end

    log(
        "Token issued successfully: " ..
        tostring(tokenId)
    )

    return true

end

--------------------------------------------------------------------
-- TOKEN CONSUMPTION
--
-- Lifecycle:
--
--   ISSUED -> CONSUMED
--
-- Claim-specific validation MUST occur before this function.
--------------------------------------------------------------------

function KIPN.Server.TokenConsume(
    tokenId
)

    local valid, reason =
        KIPN.Server.TokenValidate(
            tokenId
        )

    if not valid then

        log(
            "TokenConsume failed: " ..
            tostring(reason)
        )

        return false,
            reason
    end

    local token =
        KIPN.Server.TokenGet(
            tokenId
        )

    if not token then

        return false,
            "not_found"
    end

    if token.state ~=
        KIPN.Token.STATES.ISSUED then

        return false,
            "invalid_state"
    end

    local consumedAt =
        getCurrentTime()

    if not consumedAt then

        return false,
            "time_unavailable"
    end

    token.state =
        KIPN.Token.STATES.CONSUMED

    token.consumedAt =
        consumedAt

    if not saveTokenState() then

        token.state =
            KIPN.Token.STATES.ISSUED

        token.consumedAt =
            nil

        return false,
            "persistence_failed"
    end

    log(
        "Token consumed successfully: " ..
        tostring(tokenId)
    )

    return true,
        "consumed"

end

--------------------------------------------------------------------
-- TOKEN INVALIDATION
--
-- IMPORTANT:
--
-- This preserves the original state if persistence fails.
--------------------------------------------------------------------

function KIPN.Server.TokenInvalidate(
    tokenId,
    reason
)

    local token =
        KIPN.Server.TokenGet(
            tokenId
        )

    if not token then

        return false
    end

    if token.state ==
        KIPN.Token.STATES.CONSUMED then

        return false
    end

    if token.state ==
        KIPN.Token.STATES.EXPIRED then

        return false
    end

    if token.state ==
        KIPN.Token.STATES.INVALID then

        return true
    end

    local originalState =
        token.state

    local invalidatedAt =
        getCurrentTime()

    if not invalidatedAt then

        return false
    end

    token.state =
        KIPN.Token.STATES.INVALID

    token.invalidatedAt =
        invalidatedAt

    token.invalidReason =
        tostring(
            reason
            or "unspecified"
        )

    if not saveTokenState() then

        token.state =
            originalState

        token.invalidatedAt =
            nil

        token.invalidReason =
            nil

        return false
    end

    log(
        "Token invalidated successfully: " ..
        tostring(tokenId) ..
        " reason=" ..
        tostring(token.invalidReason)
    )

    return true

end

--------------------------------------------------------------------
-- TOKEN METADATA
--------------------------------------------------------------------

function KIPN.Server.TokenGetMetadata(
    tokenId
)

    local token =
        KIPN.Server.TokenGet(
            tokenId
        )

    if not token then

        return nil
    end

    local metadata =
        token.metadata

    if type(metadata) ~= "table" then

        metadata = {}
    end

    return metadata

end

--------------------------------------------------------------------
-- TOKEN STATE
--------------------------------------------------------------------

function KIPN.Server.TokenGetState(
    tokenId
)

    local token =
        KIPN.Server.TokenGet(
            tokenId
        )

    if not token then

        return nil
    end

    return token.state

end

--------------------------------------------------------------------
-- EXPIRE TOKEN
--------------------------------------------------------------------

function KIPN.Server.TokenExpire(
    tokenId
)

    local token =
        KIPN.Server.TokenGet(
            tokenId
        )

    if not token then

        return false
    end

    if token.state ==
        KIPN.Token.STATES.CONSUMED
        or
        token.state ==
        KIPN.Token.STATES.INVALID then

        return false
    end

    if token.state ==
        KIPN.Token.STATES.EXPIRED then

        return true
    end

    local originalState =
        token.state

    local expiredAt =
        getCurrentTime()

    if not expiredAt then

        return false
    end

    token.state =
        KIPN.Token.STATES.EXPIRED

    token.expiredAt =
        expiredAt

    if not saveTokenState() then

        token.state =
            originalState

        token.expiredAt =
            nil

        return false
    end

    log(
        "Token expired successfully: " ..
        tostring(tokenId)
    )

    return true

end

--------------------------------------------------------------------
-- TOKEN STATUS
--------------------------------------------------------------------

function KIPN.Server.TokenGetStatus(
    tokenId
)

    local token =
        KIPN.Server.TokenGet(
            tokenId
        )

    if not token then

        return nil
    end

    if token.state ==
        KIPN.Token.STATES.ISSUED
        and
        KIPN.Server.TokenIsExpired(
            token
        ) then

        KIPN.Server.TokenExpire(
            tokenId
        )
    end

    return token.state

end

--------------------------------------------------------------------
-- TOKEN EXISTS
--------------------------------------------------------------------

function KIPN.Server.TokenExists(
    tokenId
)

    local token =
        KIPN.Server.TokenGet(
            tokenId
        )

    local exists =
        token ~= nil

    return exists

end

--------------------------------------------------------------------
-- TOKEN TYPE CHECK
--------------------------------------------------------------------

function KIPN.Server.TokenIsType(
    tokenId,
    tokenType,
    tokenSubtype
)

    local token =
        KIPN.Server.TokenGet(
            tokenId
        )

    if not token then

        return false
    end

    if token.type ~= tokenType then

        return false
    end

    if tokenSubtype ~= nil
        and token.subtype ~= tokenSubtype then

        return false
    end

    return true

end

--------------------------------------------------------------------
-- TOKEN METADATA VALUE
--------------------------------------------------------------------

function KIPN.Server.TokenGetMetadataValue(
    tokenId,
    key
)

    if key == nil then

        return nil
    end

    local token =
        KIPN.Server.TokenGet(
            tokenId
        )

    if not token then

        return nil
    end

    if type(token.metadata) ~= "table" then

        return nil
    end

    local value =
        token.metadata[key]

    return value

end

--------------------------------------------------------------------
-- TOKEN META TIME RUN LOG
--------------------------------------------------------------------

function KIPN.Server.TokenMetaTimeRunLog()

    return true

end

--------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------

function KIPN.Server.InitializeTokenService()

    if not KIPN
        or not KIPN.Server
        or type(KIPN.Server.GetData) ~= "function" then

        return false
    end

    if type(KIPN.Server.Save) ~= "function" then

        return false
    end

    local data =
        KIPN.Server.GetData()

    if not data then

        return false
    end

    local createdRegistry =
        false

    if type(data.tokens) ~= "table" then

        data.tokens = {}

        createdRegistry =
            true
    end

    if createdRegistry
        and not KIPN.Server.Save("tokens") then

        return false
    end

    return true

end

--------------------------------------------------------------------
-- MODULE LOAD MESSAGE
--------------------------------------------------------------------

print(
    "[KIPN] Token Server loaded"
)