-- KIPN_SinglePlayerTransport.lua
--
-- Single-player delivery for KIPN's server -> client messages.
--
-- In single player the game routes sendClientCommand() to the local
-- OnClientCommand handlers (zombie.spnetwork.SinglePlayerClient), but
-- the Lua sendServerCommand() only does anything when
-- GameServer.server is true (LuaManager.GlobalObject, Build 42). In
-- single player it silently drops the message, so every KIPN reply
-- (power status, boot, terminal data, errors) was lost: "Power On
-- Computer" switched the computer on server-side and nothing opened.
--
-- This wraps the global sendServerCommand() so that, in single player
-- only, a message on a KIPN module (any module whose name starts with
-- "KIPN", or one added with KIPN.Shared.RegisterSinglePlayerModule)
-- is delivered to the local OnServerCommand handlers on the next tick,
-- as the network would. Other modules, multiplayer clients and
-- servers are passed to the original function unchanged.

KIPN = KIPN or {}
KIPN.Shared = KIPN.Shared or {}

local Transport = {}
KIPN.Shared.SinglePlayerTransport = Transport

Transport.extraModules = Transport.extraModules or {}

function KIPN.Shared.RegisterSinglePlayerModule(moduleName)
    if type(moduleName) == "string" and moduleName ~= "" then
        Transport.extraModules[moduleName] = true
    end
end

-- Mode is checked per call: Lua also loads at the main menu, before
-- the game knows whether this session is single player.
function Transport.IsSinglePlayer()
    if type(KIPN.Shared.IsSinglePlayer) == "function" then return KIPN.Shared.IsSinglePlayer() end
    local client = type(isClient) == "function" and isClient()
    local server = type(isServer) == "function" and isServer()
    return not client and not server
end

function Transport.IsKIPNModule(moduleName)
    if type(moduleName) ~= "string" then return false end
    return string.sub(moduleName, 1, 4) == "KIPN" or Transport.extraModules[moduleName] == true
end

-- Over the network the client gets its own copy of the arguments.
-- Copy them here too, so a client handler can never change server data.
local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for k, v in pairs(value) do result[copy(k, seen)] = copy(v, seen) end
    return result
end

local queue = {}

local function deliver()
    if #queue == 0 then return end
    local pending = queue
    queue = {}
    for _, message in ipairs(pending) do
        local ok, err = pcall(triggerEvent, "OnServerCommand", message.module, message.command, message.args)
        if not ok then
            print("[KIPN SP TRANSPORT] ERROR: delivering " .. tostring(message.module) .. "/" .. tostring(message.command)
                .. " failed: " .. tostring(err))
        end
    end
end

-- Returns true when the message was taken for local delivery.
function Transport.Enqueue(moduleName, command, args)
    if not Transport.IsSinglePlayer() or not Transport.IsKIPNModule(moduleName) then return false end
    queue[#queue + 1] = { module = moduleName, command = command, args = copy(args) }
    return true
end

if not Transport.installed and type(sendServerCommand) == "function" then
    Transport.installed = true
    local original = sendServerCommand
    Transport.original = original
    sendServerCommand = function(a, b, c, d)
        -- sendServerCommand(module, command, args) or
        -- sendServerCommand(player, module, command, args)
        -- The original is called with the same number of arguments, so
        -- the game picks the same Java overload.
        if type(a) == "string" then
            if Transport.Enqueue(a, b, c) then return end
            return original(a, b, c)
        end
        if Transport.Enqueue(b, c, d) then return end
        return original(a, b, c, d)
    end
end

if Events then
    if Events.OnTick then Events.OnTick.Add(deliver) end
    if Events.OnTickEvenPaused then Events.OnTickEvenPaused.Add(deliver) end
end
