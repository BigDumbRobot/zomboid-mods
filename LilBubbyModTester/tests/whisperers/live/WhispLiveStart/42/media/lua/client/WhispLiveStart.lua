-- Throwaway: with -debug, launches straight into an outdoor Muldraugh world
-- with no zombies, so LilBubbyAutoRun.txt can start the tester unattended.
require "DebugUIs/DebugScenarios"

-- forceLaunch scenarios start only while this debug option is on, and it can
-- be off (it's saved per cache folder), so switch it on before the menu opens.
pcall(function() getDebugOptions():setBoolean("DebugScenario.ForceLaunch", true) end)

debugScenarios.WhispLiveStart = {
    name = "Whisperers live test",
    forceLaunch = true,
    startLoc = { x = 10645, y = 10437, z = 0 },
    setSandbox = function()
        SandboxVars.Zombies = 6
    end,
    onStart = function() end,
}

Events.OnGameStart.Add(function()
    print("[WhispLive] game started")
end)

-- Probe: when Lua/WhispLiveEval.txt says "run", reloads WhispProbe.lua from
-- this mod's folder and writes the WhispProbeResult it sets to
-- Lua/WhispLiveEval_out.txt. B42's Lua has no loadstring.
local nextPoll = 0
local function poll()
    local now = getTimestampMs()
    if now < nextPoll then return end
    nextPoll = now + 1000
    local reader = getFileReader("WhispLiveEval.txt", false)
    if not reader then return end
    local line = reader:readLine()
    reader:close()
    if line ~= "run" then return end
    local clear = getFileWriter("WhispLiveEval.txt", true, false); clear:write(""); clear:close()
    WhispProbeResult = "probe set no result"
    local dir = getModInfoByID("WhispLiveStart"):getDir()
    local ok, err = pcall(reloadLuaFile, dir .. "/42/media/lua/client/WhispProbe.lua")
    local out = ok and tostring(WhispProbeResult) or ("ERROR: " .. tostring(err))
    local w = getFileWriter("WhispLiveEval_out.txt", true, false); w:write(out .. "\n"); w:close()
end
Events.OnTick.Add(poll)
Events.OnFETick.Add(poll)
