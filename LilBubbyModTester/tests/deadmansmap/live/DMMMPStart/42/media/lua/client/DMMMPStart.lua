-- Throwaway: from the main menu, connects to the local -nosteam test server
-- started by run_mp.sh and clicks through spawn selection and character
-- creation, so LilBubbyAutoRun.txt can start the tester unattended.
-- Also loaded by the server's mod list, so it is still active after joining.
local SERVER = { ip = "127.0.0.1", port = "16361", name = "dmmtest", user = "dmmtester", password = "dmmtest" }
local connectAt = nil
local named = false

local function fe()
    if not MainScreen or not MainScreen.instance then return end
    local now = getTimestampMs()
    if not isClient() and not connectAt then connectAt = now + 3000 end
    if connectAt and now >= connectAt and not isClient() and not DMMMPConnecting then
        DMMMPConnecting = true
        print("[DMMMP] connecting to " .. SERVER.ip .. ":" .. SERVER.port)
        serverConnect(SERVER.user, SERVER.password, SERVER.ip, "", SERVER.port, "", SERVER.name, false, true, 1, "")
        return
    end
    if MapSpawnSelect and MapSpawnSelect.instance and MapSpawnSelect.instance:isVisible() then
        print("[DMMMP] spawn selection: next")
        MapSpawnSelect.instance:clickNext()
        return
    end
    local screen = MainScreen.instance
    if screen.charCreationProfession and screen.charCreationProfession:isVisible() then
        print("[DMMMP] profession: next")
        screen.charCreationProfession:onOptionMouseDown({ internal = "NEXT" }, 0, 0)
        return
    end
    if screen.charCreationMain and screen.charCreationMain:isVisible() then
        if not named then
            named = true
            screen.charCreationMain.forenameEntry:setText("DMM")
            screen.charCreationMain.surnameEntry:setText("Copy Tester")
            return
        end
        print("[DMMMP] character: next")
        screen.charCreationMain:onOptionMouseDown({ internal = "NEXT" }, 0, 0)
    end
end
Events.OnFETick.Add(fe)

Events.OnConnectFailed.Add(function(message, detail)
    print("[DMMMP] connect failed: " .. tostring(message) .. " " .. tostring(detail))
    DMMMPConnecting = false
    connectAt = getTimestampMs() + 5000
end)

Events.OnGameStart.Add(function()
    print("[DMMMP] game started")
end)

-- Probe (probe_mp.sh): when Lua/DMMMPEval.txt says "run", reloads
-- DMMMPProbe.lua from this mod's folder and writes the DMMMPProbeResult it
-- sets to Lua/DMMMPEval_out.txt. B42's Lua has no loadstring.
local nextPoll = 0
local function poll()
    local now = getTimestampMs()
    if now < nextPoll then return end
    nextPoll = now + 1000
    local reader = getFileReader("DMMMPEval.txt", false)
    if not reader then return end
    local line = reader:readLine()
    reader:close()
    if line ~= "run" then return end
    local clear = getFileWriter("DMMMPEval.txt", true, false); clear:write(""); clear:close()
    DMMMPProbeResult = "probe set no result"
    local dir = getModInfoByID("DMMMPStart"):getDir()
    local ok, err = pcall(reloadLuaFile, dir .. "/42/media/lua/client/DMMMPProbe.lua")
    local out = ok and tostring(DMMMPProbeResult) or ("ERROR: " .. tostring(err))
    local w = getFileWriter("DMMMPEval_out.txt", true, false); w:write(out .. "\n"); w:close()
end
Events.OnTick.Add(poll)
