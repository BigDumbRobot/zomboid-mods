require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Effects"

-- The "ascension": while a player channels a recovery ritual they glow (a
-- coloured light) and a wisp of smoke rises from their tile. The raised-arms
-- pose is set by SO_OfferingRitualAction (a networked timed action, so other
-- clients already see the animation).
--
-- Visibility to other players: SO_OfferingRitualAction sets a replicated
-- character variable `SO_InRitual`; every client scans nearby players for it and
-- renders the FX locally for each one. Nothing new is sent over the wire.

local SO = SacrificialOffering
SO.Trance = SO.Trance or {}
local Trance = SO.Trance

local RITUAL_VARIABLE = "SO_InRitual"
local GLOW_R, GLOW_G, GLOW_B = 0.60, 0.08, 0.85   -- violet
local GLOW_RADIUS = 5
local PARTICLE_INTERVAL_MS = 2800
local SCAN_INTERVAL_MS = 400
local MAX_RENDER_DISTANCE_SQ = 24 * 24

-- key -> { player, light, gx, gy, gz, nextParticleAt }
local fx = {}
local nextScanAt = 0

local function playerKey(player)
    local id = player.getOnlineID and player:getOnlineID()
    if id and id >= 0 then return "id:" .. tostring(id) end
    return "local"
end

local function makeLight(x, y, z)
    local ok, light = pcall(function()
        local l = IsoLightSource.new(math.floor(x), math.floor(y), math.floor(z),
            GLOW_R, GLOW_G, GLOW_B, GLOW_RADIUS)
        if l.setLife then l:setLife(-1) end
        getCell():addLamppost(l)
        return l
    end)
    return ok and light or nil
end

local function dropLight(light)
    if not light then return end
    pcall(function() getCell():removeLamppost(light) end)
end

local function stopFx(key)
    local entry = fx[key]
    if not entry then return end
    dropLight(entry.light)
    fx[key] = nil
end

local function inRitual(player)
    if not player then return false end
    if player.getVariableString then
        local ok, value = pcall(function() return player:getVariableString(RITUAL_VARIABLE) end)
        if ok and value == "true" then return true end
    end
    -- Fallback: the networked timed action is mirrored onto every client.
    if SO_OfferingRitualAction and SO_OfferingRitualAction.IsActive then
        local ok, active = pcall(SO_OfferingRitualAction.IsActive, player)
        if ok and active then return true end
    end
    return false
end

local function candidatePlayers()
    local list = {}
    local seen = {}
    local function add(p)
        if not p then return end
        local k = playerKey(p)
        if not seen[k] then seen[k] = true; list[#list + 1] = p end
    end
    add(getPlayer())
    local online = getOnlinePlayers()
    if online then
        for i = 0, online:size() - 1 do add(online:get(i)) end
    end
    return list
end

local function refresh()
    local viewer = getPlayer()
    if not viewer then
        for key in pairs(fx) do stopFx(key) end
        return
    end
    local vx, vy = viewer:getX(), viewer:getY()

    local active = {}
    for _, player in ipairs(candidatePlayers()) do
        local key = playerKey(player)
        local square = player.getSquare and player:getSquare()
        local dx, dy = player:getX() - vx, player:getY() - vy
        local visible = square ~= nil and (dx * dx + dy * dy) <= MAX_RENDER_DISTANCE_SQ

        if visible and inRitual(player) then
            active[key] = true
            local entry = fx[key]
            local px, py = math.floor(player:getX()), math.floor(player:getY())
            local pz = math.floor(player:getZ())
            if not entry then
                fx[key] = {
                    player = player,
                    light = makeLight(player:getX(), player:getY(), pz),
                    gx = px, gy = py, gz = pz,
                    nextParticleAt = 0,
                }
            else
                entry.player = player
                if px ~= entry.gx or py ~= entry.gy or pz ~= entry.gz then
                    dropLight(entry.light)
                    entry.light = makeLight(player:getX(), player:getY(), pz)
                    entry.gx, entry.gy, entry.gz = px, py, pz
                end
            end
        end
    end

    for key in pairs(fx) do
        if not active[key] then stopFx(key) end
    end
end

local function onTick()
    local now = SO.Util.NowMs()

    -- Particle refresh runs every tick against whatever FX are live.
    for _, entry in pairs(fx) do
        if entry.player and now >= entry.nextParticleAt and SO.Effects and SO.Effects.Play then
            entry.nextParticleAt = now + PARTICLE_INTERVAL_MS
            SO.Effects.Play({
                effect = SO.EFFECT.TRANCE,
                x = entry.player:getX(),
                y = entry.player:getY(),
                z = math.floor(entry.player:getZ()),
            })
        end
    end

    if now >= nextScanAt then
        nextScanAt = now + SCAN_INTERVAL_MS
        pcall(refresh)
    end
end

local function onPlayerDeath(player)
    if player then stopFx(playerKey(player)) end
end

Events.OnTick.Add(onTick)
Events.OnPlayerDeath.Add(onPlayerDeath)

return Trance
