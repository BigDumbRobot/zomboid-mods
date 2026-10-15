-- Throwaway: from the main menu, connects to the local -nosteam test server
-- started by run_mp.sh and clicks through spawn selection and character
-- creation, so LilBubbyAutoRun.txt can start the tester unattended.
-- Also loaded by the server's mod list, so it is still active after joining.
-- Joins as the server's admin account: the vehicle lifecycle test is admin-only.
local SERVER = { ip = "127.0.0.1", port = "16371", name = "vehsvctest", user = "admin", password = "vehsvcadmin" }
local connectAt = nil
local named = false

local function fe()
    if not MainScreen or not MainScreen.instance then return end
    local now = getTimestampMs()
    if not isClient() and not connectAt then connectAt = now + 3000 end
    if connectAt and now >= connectAt and not isClient() and not VehSvcMPConnecting then
        VehSvcMPConnecting = true
        print("[VehSvcMP] connecting to " .. SERVER.ip .. ":" .. SERVER.port)
        serverConnect(SERVER.user, SERVER.password, SERVER.ip, "", SERVER.port, "", SERVER.name, false, true, 1, "")
        return
    end
    if MapSpawnSelect and MapSpawnSelect.instance and MapSpawnSelect.instance:isVisible() then
        print("[VehSvcMP] spawn selection: next")
        MapSpawnSelect.instance:clickNext()
        return
    end
    local screen = MainScreen.instance
    if screen.charCreationProfession and screen.charCreationProfession:isVisible() then
        print("[VehSvcMP] profession: next")
        screen.charCreationProfession:onOptionMouseDown({ internal = "NEXT" }, 0, 0)
        return
    end
    if screen.charCreationMain and screen.charCreationMain:isVisible() then
        if not named then
            named = true
            screen.charCreationMain.forenameEntry:setText("VehSvc")
            screen.charCreationMain.surnameEntry:setText("Lifecycle Tester")
            return
        end
        print("[VehSvcMP] character: next")
        screen.charCreationMain:onOptionMouseDown({ internal = "NEXT" }, 0, 0)
    end
end
Events.OnFETick.Add(fe)

Events.OnConnectFailed.Add(function(message, detail)
    print("[VehSvcMP] connect failed: " .. tostring(message) .. " " .. tostring(detail))
    VehSvcMPConnecting = false
    connectAt = getTimestampMs() + 5000
end)

Events.OnGameStart.Add(function()
    print("[VehSvcMP] game started")
end)

-- Probe (probe_mp.sh): when Lua/VehSvcMPEval.txt says "run", reloads
-- VehSvcMPProbe.lua from this mod's folder and writes the VehSvcMPProbeResult it
-- sets to Lua/VehSvcMPEval_out.txt. B42's Lua has no loadstring.
local nextPoll = 0
local function poll()
    local now = getTimestampMs()
    if now < nextPoll then return end
    nextPoll = now + 1000
    local reader = getFileReader("VehSvcMPEval.txt", false)
    if not reader then return end
    local line = reader:readLine()
    reader:close()
    if line ~= "run" then return end
    local clear = getFileWriter("VehSvcMPEval.txt", true, false); clear:write(""); clear:close()
    VehSvcMPProbeResult = "probe set no result"
    local dir = getModInfoByID("VehSvcMPStart"):getDir()
    local ok, err = pcall(reloadLuaFile, dir .. "/42/media/lua/client/VehSvcMPProbe.lua")
    local out = ok and tostring(VehSvcMPProbeResult) or ("ERROR: " .. tostring(err))
    local w = getFileWriter("VehSvcMPEval_out.txt", true, false); w:write(out .. "\n"); w:close()
end
Events.OnTick.Add(poll)
