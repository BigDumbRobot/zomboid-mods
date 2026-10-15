-- KIPN_LORDInit.lua
--
-- Entry point for the KIPN: Legend of the Red Dragon add-on. Attaches
-- to KIP Network Terminal's host framework:
--
--   * hard-guards against an incompatible KIPN (sec 0),
--   * registers the "Play LORD" main-menu program -- no permission,
--     no capability, no zone classification, so it shows on ANY
--     computer to any logged-in account,
--   * registers a "LegendOfTheRedDragon" add-on service whose
--     initialize() wires up the two command handlers.
--
-- The data domain is registered at module load by KIPN_LORDGame.lua.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_LORDShared"
require "KIPN_LORDGame"

local function log(msg)
    print("[KIPN LORD] " .. tostring(msg))
end

--------------------------------------------------------------------
-- API COMPATIBILITY GUARD  (sec 0 -- one clean line, no stack trace)
--------------------------------------------------------------------

local ok, why = KIPN.API.Require(KIPN.LORD.API_VERSION)
if not ok then
    log("disabled: " .. tostring(why))
    return
end

local Server  = KIPN.LORD.Server
local Commands = KIPN.Shared.Commands
local Events   = KIPN.Shared.ResponseEvents

--------------------------------------------------------------------
-- RESPONSE HELPER
--------------------------------------------------------------------

local function reply(player, snapshot, errCode)
    if snapshot then
        KIPN.Server.SendToPlayer(player, Events.LORD_STATE, snapshot)
        return true
    end
    KIPN.Server.SendToPlayer(player, Events.ERROR, {
        code = errCode or "LORD_ERROR",
        message = "Legend of the Red Dragon could not process that.",
    })
    return false
end

--------------------------------------------------------------------
-- COMMAND HANDLERS
--------------------------------------------------------------------

local function handleGetState(player)
    local snap, err = Server.GetSnapshot(player)
    return reply(player, snap, err)
end

local function handleAction(player, args)
    local action = args and args.action
    if type(action) ~= "string" or action == "" then
        return false, "NO_ACTION"
    end
    local snap, err = Server.HandleAction(player, action)
    return reply(player, snap, err)
end

-- Read-only: feeds the LORD panel on KIPN's Server Statistics screen.
-- Never creates a character, so it is safe for any viewer.
local function handleLeaderboard(player)
    KIPN.Server.SendToPlayer(player, Events.LORD_LEADERBOARD_DATA, Server.GetLeaderboard())
    return true
end

--------------------------------------------------------------------
-- MENU PROGRAM  (additive -- registered at module load)
--------------------------------------------------------------------

if KIPN.Server.ApplicationRegistry
    and type(KIPN.Server.ApplicationRegistry.Register) == "function"
then
    KIPN.Server.ApplicationRegistry.Register("play_lord", {
        name            = "Play LORD",
        description     = "Legend of the Red Dragon -- the classic BBS door game.",
        order           = 80,
        screen          = "KIPN_LORDScreen",
        requiresSession = true,   -- must be a logged-in KIPN account
        permissions     = {},     -- no permission gate
        capabilities    = {},     -- no computer-capability gate
        classifications = {},     -- no zone gate -> shown for every zone
    })
else
    log("ERROR: ApplicationRegistry unavailable; 'Play LORD' will not appear.")
end

--------------------------------------------------------------------
-- ADD-ON SERVICE REGISTRATION
--------------------------------------------------------------------

if type(KIPN.Server.RegisterService) == "function" then

    KIPN.Server.RegisterService("LegendOfTheRedDragon", {

        apiVersion = KIPN.LORD.API_VERSION,

        dependsOn = { "ApplicationRegistry" },

        order = 700,

        initialize = function()
            if type(KIPN.Server.RegisterCommandHandler) ~= "function" then
                log("ERROR: RegisterCommandHandler unavailable; LORD commands unreachable.")
                return false
            end

            KIPN.Server.RegisterCommandHandler(Commands.LORD_GET_STATE,  handleGetState)
            KIPN.Server.RegisterCommandHandler(Commands.LORD_ACTION,     handleAction)
            KIPN.Server.RegisterCommandHandler(Commands.LORD_LEADERBOARD, handleLeaderboard)

            log("Legend of the Red Dragon initialized.")
            return true
        end,
    })

else
    log("ERROR: KIPN.Server.RegisterService unavailable; LORD will not initialize.")
end

print("[KIPN] Legend of the Red Dragon init module loaded")
