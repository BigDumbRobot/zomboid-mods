require "LilBubbyPacer"
require "SatanicTemplesTest_World"

-- Multiplayer half of the Satanic Temples suite: the test temple, offerings,
-- corpses, carcasses, ledger changes and repairs are made here, for any
-- player; every argument is checked.
local MODULE = SatanicTemplesTest.MODULE
local World = SatanicTemplesTest.World
local OPS = { setup = true, prepare = true, offer = true, busy = true, state = true, repair = true,
    relicReady = true, heal = true, cleanup = true }
local STAGES = { begin = true, make = true, both = true, abandon = true }
local CORPSES = { zombie = true, victim = true, self = true }
-- Offerings the suite may put on the altar.
local ITEMS = { ["Base.Plank"] = true, ["Base.Nails"] = true, ["Base.Katana"] = true, ["Base.Sledgehammer"] = true,
    ["Base.AssaultRifle"] = true, ["Base.556Clip"] = true, ["Base.Cow_Head_Angus"] = true }

local function number(value, low, high)
    return value == nil or (type(value) == "number" and value >= low and value <= high)
end

local function valid(command, args)
    if command == "prepare" then
        if args.items ~= nil then
            if type(args.items) ~= "table" or #args.items > 6 then return false end
            for _, fullType in ipairs(args.items) do if not ITEMS[fullType] then return false end end
        end
        return (args.corpse == nil or CORPSES[args.corpse])
            and (args.animal == nil or type(args.animal) == "string")
            and (args.death == nil or args.death == "fake" or args.death == "none")
            and number(args.xp, 0, 100000) and number(args.xpBoost, 0, 100000)
            and number(args.redeemed, 0, 100) and number(args.reduceHealth, 0, 99)
    elseif command == "offer" then
        return STAGES[args.stage or "both"] ~= nil and (args.tx == nil or type(args.tx) == "string")
    elseif command == "state" then
        return number(args.since, 0, 100000) and (args.tx == nil or type(args.tx) == "string")
    end
    return true
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE or not player or not OPS[command] then return end
    args = type(args) == "table" and args or {}
    local reply = { op = command, id = args.id }
    if not SatanicTemplesTest.available() then
        reply.error = "Satanic Temples is not enabled on this server."
    elseif not valid(command, args) then
        reply.error = "Invalid " .. command .. " request."
    else
        -- Queued behind this player's previous request, never refused for speed.
        LilBubbyPacer.Run(player, MODULE, 50, function()
            local ok, result = pcall(World[command], player, args)
            if ok then
                for key, value in pairs(result or {}) do reply[key] = value end
            else
                reply.error = tostring(result)
            end
            print("[" .. MODULE .. "] " .. command .. " " .. player:getUsername() .. (reply.error and (" error: " .. reply.error) or ""))
            sendServerCommand(player, MODULE, "reply", reply)
        end)
        return
    end
    print("[" .. MODULE .. "] " .. command .. " " .. player:getUsername() .. " refused: " .. tostring(reply.error))
    sendServerCommand(player, MODULE, "reply", reply)
end)
