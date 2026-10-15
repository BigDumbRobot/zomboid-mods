-- KIPN_Token.lua
--
-- KIPN client-side token interface.
--
-- DEPENDENCY:
--
--   KIPN_Logger.lua
--       ↓
--   KIPN_Shared.lua
--       ↓
--   KIPN_Token.lua
--
-- This module is CLIENT ONLY.
--
-- Responsibilities:
--   * Provide client-side token request helpers.
--   * Send token requests through the standard KIPN command channel.
--
-- This file does NOT:
--   * validate tokens
--   * create tokens
--   * consume tokens
--   * invalidate tokens
--   * persist token state
--   * listen for OnServerCommand
--   * route server responses
--
-- The server remains authoritative for all token state.
--
-- Server responses are routed through:
--
--     KIPN_Terminal
--         |
--         v
--     active child application's receiveResponse()
--
-- Registration items and claim tokens are bearer artifacts.
-- They are not owned by a player until final claim activation.

--------------------------------------------------------------------
-- EXECUTION SIDE
--------------------------------------------------------------------
--
-- This file must never execute on the server.
--
-- Keep this check before establishing any client-side API.
--------------------------------------------------------------------

if isServer() then
    return
end

--------------------------------------------------------------------
-- KIPN DEPENDENCY CHECK
--------------------------------------------------------------------

if not KIPN then

    error(
        "[KIPN_TOKEN] "
        .. "KIPN core is not initialized."
    )
end

if not KIPN.Logger then

    error(
        "[KIPN_TOKEN] "
        .. "KIPN.Logger is not initialized. "
        .. "KIPN_Logger.lua must be loaded before "
        .. "KIPN_Token.lua."
    )
end

if not KIPN.Shared then

    error(
        "[KIPN_TOKEN] "
        .. "KIPN.Shared is not initialized. "
        .. "KIPN_Shared.lua must be loaded before "
        .. "KIPN_Token.lua."
    )
end

--------------------------------------------------------------------
-- CLIENT NAMESPACE
--------------------------------------------------------------------

KIPN.Client =
    KIPN.Client or {}

KIPN.Token =
    KIPN.Token or {}

--------------------------------------------------------------------
-- SEND TOKEN COMMAND
--------------------------------------------------------------------

local function sendTokenCommand(
    command,
    args
)

    tokenClientLog(
        "sendTokenCommand(" ..
        tostring(command) ..
        ")"
    )

    if type(command) ~= "string"
        or command == "" then

        tokenClientLog(
            "sendTokenCommand failed: invalid command."
        )

        return false
    end

    if type(sendClientCommand) ~= "function" then

        tokenClientLog(
            "sendTokenCommand failed: " ..
            "sendClientCommand unavailable."
        )

        return false
    end

    sendClientCommand(
        "KIPN",
        command,
        args or {}
    )

    tokenClientLog(
        "Token command sent successfully: " ..
        tostring(command)
    )

    return true

end

--------------------------------------------------------------------
-- INSPECT TOKEN
--
-- This only asks the server to inspect the supplied token.
--
-- No local validation occurs.
--------------------------------------------------------------------

function KIPN.Client.TokenInspect(
    tokenId
)

    tokenClientLog(
        "TokenInspect(" ..
        tostring(tokenId) ..
        ")"
    )

    if type(tokenId) ~= "string"
        or tokenId == "" then

        tokenClientLog(
            "TokenInspect failed: invalid tokenId."
        )

        return false
    end

    if not KIPN.Shared
        or not KIPN.Shared.Commands then

        tokenClientLog(
            "TokenInspect failed: " ..
            "KIPN.Shared.Commands unavailable."
        )

        return false
    end

    local command =
        KIPN.Shared.Commands.TOKEN_INSPECT

    if type(command) ~= "string"
        or command == "" then

        tokenClientLog(
            "TokenInspect failed: " ..
            "TOKEN_INSPECT command unavailable."
        )

        return false
    end

    local sent =
        sendTokenCommand(
            command,
            {
                tokenId =
                    tokenId
            }
        )

    return sent

end

--------------------------------------------------------------------
-- REQUEST TOKEN DATA
--------------------------------------------------------------------

function KIPN.Client.TokenGet(
    tokenId
)

    tokenClientLog(
        "TokenGet(" ..
        tostring(tokenId) ..
        ")"
    )

    if type(tokenId) ~= "string"
        or tokenId == "" then

        return false
    end

    local command =
        KIPN.Shared
        and KIPN.Shared.Commands
        and KIPN.Shared.Commands.TOKEN_GET

    if not command then

        return false
    end

    local sent =
        sendTokenCommand(
            command,
            {
                tokenId =
                    tokenId
            }
        )

    return sent

end

--------------------------------------------------------------------
-- REQUEST TOKEN VALIDATION
--------------------------------------------------------------------

function KIPN.Client.TokenValidate(
    tokenId
)

    tokenClientLog(
        "TokenValidate(" ..
        tostring(tokenId) ..
        ")"
    )

    if type(tokenId) ~= "string"
        or tokenId == "" then

        return false
    end

    local command =
        KIPN.Shared
        and KIPN.Shared.Commands
        and KIPN.Shared.Commands.TOKEN_VALIDATE

    if not command then

        return false
    end

    local sent =
        sendTokenCommand(
            command,
            {
                tokenId =
                    tokenId
            }
        )

    return sent

end

--------------------------------------------------------------------
-- CLIENT INITIALIZATION
--------------------------------------------------------------------

function KIPN.Client.InitializeToken()

    tokenClientLog(
        "InitializeToken()"
    )

    if not KIPN.Shared then

        tokenClientLog(
            "InitializeToken failed: KIPN.Shared unavailable."
        )

        return false
    end

    if not KIPN.Shared.Commands then

        tokenClientLog(
            "InitializeToken failed: " ..
            "KIPN.Shared.Commands unavailable."
        )

        return false
    end

    if not KIPN.Shared.Commands.TOKEN_INSPECT then

        tokenClientLog(
            "InitializeToken failed: " ..
            "TOKEN_INSPECT command unavailable."
        )

        return false
    end

    tokenClientLog(
        "KIPN Token Client initialized."
    )

    return true

end

--------------------------------------------------------------------
-- META TIME RUN LOG
--------------------------------------------------------------------

function KIPN.Client.TokenMetaTimeRunLog()

    tokenClientLog(
        "TokenMetaTimeRunLog()"
    )

    local run =
        beginRun(
            "MetaTimeRunLog"
        )

    tokenClientLog(
        "KIPN Token Client Meta Time Run Log: " ..
        "client token operations use the standard " ..
        "KIPN messaging channel."
    )

    endRun(
        run,
        true
    )

    return true

end
