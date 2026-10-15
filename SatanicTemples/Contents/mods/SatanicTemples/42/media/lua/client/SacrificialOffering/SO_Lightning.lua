require "ISUI/ISUIElement"
require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"

-- The relic-theft strike. The server also triggers a vanilla thunder event for
-- the sound, but its flash is not reliably visible, so every nearby client
-- draws its own: a bluish-white world light at the thief's tile and, close to
-- the strike, a short full-screen flash that reads even in daylight. Two
-- pulses, like a real bolt. Purely local; nothing is sent back.

local SO = SacrificialOffering
SO.Lightning = SO.Lightning or {}
local Lightning = SO.Lightning

local LIGHT_R, LIGHT_G, LIGHT_B = 0.85, 0.9, 1.0
local LIGHT_RADIUS = 20
local WORLD_RANGE_SQ = 60 * 60
local SCREEN_RANGE_SQ = 30 * 30
-- { start ms after the strike, length ms, peak screen alpha }
local PULSES = { { 0, 140, 0.8 }, { 260, 110, 0.55 } }

local Overlay = ISUIElement:derive("SO_LightningOverlay")

function Overlay:render()
    if self.alpha > 0 then
        self:drawRect(0, 0, self.width, self.height, self.alpha, LIGHT_R, LIGHT_G, LIGHT_B)
    end
end

local active = nil   -- { startedAt, x, y, z, screen, light, overlay }

local function dropLight()
    if active and active.light then
        pcall(function() getCell():removeLamppost(active.light) end)
        active.light = nil
    end
end

local function finish()
    dropLight()
    if active and active.overlay then pcall(function() active.overlay:removeFromUIManager() end) end
    active = nil
end

local function makeOverlay()
    local overlay = Overlay:new(0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
    overlay.alpha = 0
    overlay:initialise()
    overlay:instantiate()
    overlay.javaObject:setConsumeMouseEvents(false)
    overlay:setAlwaysOnTop(true)
    overlay:addToUIManager()
    return overlay
end

function Lightning.Play(args)
    local player = getPlayer()
    if not args or not player then return end
    local dx, dy = player:getX() - args.x, player:getY() - args.y
    local distanceSq = dx * dx + dy * dy
    if distanceSq > WORLD_RANGE_SQ then return end
    finish()
    active = {
        startedAt = SO.Util.NowMs(),
        x = math.floor(args.x), y = math.floor(args.y), z = math.floor(args.z or 0),
        screen = distanceSq <= SCREEN_RANGE_SQ,
    }
    if active.screen then
        local ok, overlay = pcall(makeOverlay)
        if ok then active.overlay = overlay end
    end
end

local function onTick()
    if not active then return end
    local elapsed = SO.Util.NowMs() - active.startedAt
    local pulse
    for _, candidate in ipairs(PULSES) do
        if elapsed >= candidate[1] and elapsed < candidate[1] + candidate[2] then pulse = candidate end
    end
    if pulse then
        if not active.light then
            local ok, light = pcall(function()
                local l = IsoLightSource.new(active.x, active.y, active.z, LIGHT_R, LIGHT_G, LIGHT_B, LIGHT_RADIUS)
                if l.setLife then l:setLife(-1) end
                getCell():addLamppost(l)
                return l
            end)
            if ok then active.light = light end
        end
        if active.overlay then
            -- Peak at the pulse start, fading to nothing by its end.
            active.overlay.alpha = pulse[3] * (1 - (elapsed - pulse[1]) / pulse[2])
        end
    else
        dropLight()
        if active.overlay then active.overlay.alpha = 0 end
        local last = PULSES[#PULSES]
        if elapsed >= last[1] + last[2] then finish() end
    end
end

Events.OnTick.Add(function()
    local ok, err = pcall(onTick)
    if not ok then
        SO.Logger.Error("Lightning flash failed", { error = tostring(err) })
        finish()
    end
end)

return Lightning
