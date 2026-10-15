-- Throwaway: with -debug, launches straight into a world with no zombies.
require "DebugUIs/DebugScenarios"

debugScenarios.STLiveStart = {
    name = "Satanic Temples live test",
    forceLaunch = true,
    startLoc = { x = 10645, y = 10437, z = 0 },
    setSandbox = function() SandboxVars.Zombies = 6 end,
    onStart = function() end,
}

-- Always-visible instructions for the person watching the game window.
require "ISUI/ISUIElement"
STStatus = STStatus or "AUTOMATED TEST - loading. Please don't touch the game and keep this window in front."
local Panel = ISUIElement:derive("STStatusPanel")
function Panel:render()
    local text = tostring(STStatus or "")
    local font = UIFont.Large
    local w = getTextManager():MeasureStringX(font, text) + 40
    local h = getTextManager():getFontHeight(font) + 20
    local x = math.floor((getCore():getScreenWidth() - w) / 2)
    self:drawRect(x, 10, w, h, 0.85, 0.05, 0.0, 0.0)
    self:drawRectBorder(x, 10, w, h, 1.0, 0.9, 0.2, 0.2)
    self:drawText(text, x + 20, 20, 1.0, 1.0, 1.0, 1.0, font)
end
local function showPanel()
    local panel = Panel:new(0, 0, getCore():getScreenWidth(), 80)
    panel:initialise()
    panel:instantiate()
    panel.javaObject:setConsumeMouseEvents(false)
    panel:setAlwaysOnTop(true)
    panel:addToUIManager()
end

Events.OnGameStart.Add(function()
    print("[STLive] game started")
    STStatus = "AUTOMATED TEST - starting shortly. Please don't touch the game and keep this window in front."
    showPanel()
end)

-- Keep zombies off the test character: invisible to them, and any zombie that
-- wanders within 60 tiles is removed. (Damage still applies, so wrath and
-- theft punishments are measured normally.)
local nextZombieSweep = 0
local function keepZombiesAway()
    local now = getTimestampMs()
    if now < nextZombieSweep then return end
    nextZombieSweep = now + 2000
    local player = getPlayer()
    if not player or player:isDead() then return end
    if not player:isInvisible() then player:setInvisible(true) end
    local list = getCell():getZombieList()
    for i = list:size() - 1, 0, -1 do
        local zombie = list:get(i)
        if zombie and math.abs(zombie:getX() - player:getX()) < 60 and math.abs(zombie:getY() - player:getY()) < 60 then
            pcall(function() zombie:removeFromWorld(); zombie:removeFromSquare() end)
        end
    end
end
Events.OnTick.Add(function() pcall(keepZombiesAway) end)

local nextPoll = 0
local function poll()
    -- Drive a running test suite from this boot-registered handler (an OnTick
    -- handler added from a reloaded probe file never fired).
    if STOffer and STOffer.tick then
        local ok, err = pcall(STOffer.tick)
        if not ok then print("[STOffer] RUNNER ERROR " .. tostring(err)) end
    end
    local now = getTimestampMs()
    if now < nextPoll then return end
    nextPoll = now + 500
    local reader = getFileReader("STLiveEval.txt", false)
    if not reader then return end
    local line = reader:readLine()
    reader:close()
    if line ~= "run" then return end
    local clear = getFileWriter("STLiveEval.txt", true, false); clear:write(""); clear:close()
    STProbeResult = "probe set no result"
    STProbeToken = now
    local dir = getModInfoByID("STLiveStart"):getDir()
    local ok, err = pcall(reloadLuaFile, dir .. "/42/media/lua/client/STProbe.lua")
    local out = ok and tostring(STProbeResult) or ("ERROR: " .. tostring(err))
    local w = getFileWriter("STLiveEval_out.txt", true, false); w:write(out .. "\n"); w:close()
end
Events.OnTick.Add(poll)
Events.OnFETick.Add(poll)
