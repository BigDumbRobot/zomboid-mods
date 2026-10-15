-- The Whisperers: zombie awareness control.
--
-- Runs on whichever machine simulates a zombie (every zombie in SP; in MP each
-- client handles the zombies it owns, using relayed meter values for other
-- players). Awareness of each camouflaged player is stored in the zombie's
-- mod data; it is local to the simulating machine, so a zombie handed to
-- another client re-decides from that client's view of the meter.
--
--   meter >= notice level  zombies inside a radius that grows with the meter
--                 notice and come for the player; at 100% every zombie
--                 within the full-alert radius does.
--   meter <  notice level  the player passes for one of the dead: no new
--                 zombie pursues them. Zombies already pursuing lose interest
--                 exponentially: each has the same chance per second to give
--                 up, set by a half-life that shortens as the meter falls.
--
-- The notice level is 50%, raised by dead-skin cover (W.noticeAt). Cover
-- also shrinks the notice radius and speeds the loss of interest, so a
-- skin suit gives far more leeway than a mask, and a mask more than guts.
--
-- Clearing a zombie's target from Lua does not hold: IsoZombie.updateInternal
-- fires OnZombieUpdate and then re-spots its last target, and the player's
-- own line-of-sight pass spots it again. So a zombie that targets a hidden
-- player is held "useless" -- the engine flag that makes IsoZombie.spotted
-- drop every target -- until the player walks off or gets loud. Useless
-- zombies stand idle and ignore sound, and they cannot see anyone, so one is
-- only held while no player who should be seen is nearby.
--
-- Zombies also close in without a target: walking to a sound the player
-- made (footsteps, a door) or to where they last saw them. OnZombieUpdate
-- never sees those, so each scan also holds any zombie walking to within
-- GOAL_RADIUS of a hidden player it isn't aware of.
require "Whisperers_Shared"
require "Whisperers_Client"

local W = Whisperers
local C = W.Client

local SCAN_MS = 500
local GOAL_RADIUS = 6
local lastScanMs = 0

-- Rebuilt every scan.
local hiddenByPlayer = {}   -- [IsoPlayer] = entry, meter below its notice level
local loudByPlayer = {}     -- [IsoPlayer] = entry, meter at its notice level or more
local hidden = {}           -- entries below their notice level
local loud = {}             -- entries at their notice level or more
local seen = {}             -- every other living player: { x, y, z }

local function whispData(zombie)
    local md = zombie:getModData()
    md.Whisp = md.Whisp or { aware = {} }
    return md.Whisp
end

local function alert(zombie, player)
    pcall(zombie.spotted, zombie, player, true)
    zombie:setTarget(player)
    pcall(zombie.pathToCharacter, zombie, player)
end

-- Clears the target and stops walking toward it, the way vanilla stops a
-- zombie whose sound path is blocked.
local function stopPursuit(zombie)
    zombie:setTarget(nil)
    pcall(zombie.setVariable, zombie, "bPathfind", false)
    pcall(zombie.setVariable, zombie, "bMoving", false)
    pcall(zombie.setPath2, zombie, nil)
end

local function within(zombie, x, y, z, radius)
    if math.abs(zombie:getZ() - z) > 1 then return false end
    local dx, dy = zombie:getX() - x, zombie:getY() - y
    return dx * dx + dy * dy <= radius * radius
end

local function nearHidden(zombie, radius)
    for _, e in ipairs(hidden) do
        local p = e.player
        if within(zombie, p:getX(), p:getY(), p:getZ(), radius) then return true end
    end
    return false
end

-- A held zombie is blind to everyone, so never hold one that should be able
-- to see a player close by.
local function canHold(zombie, radius)
    for _, s in ipairs(seen) do
        if within(zombie, s.x, s.y, s.z, radius) then return false end
    end
    return true
end

local function release(zombie, data)
    data.held = nil
    pcall(zombie.setUseless, zombie, false)
end

-- The zombie took a hidden player for prey; it now takes them for one of its own.
local function fool(zombie, data, key)
    data.aware[key] = nil
    if not data.held and canHold(zombie, W.Get("FullAlertRadius")) then
        data.held = true
        pcall(zombie.setUseless, zombie, true)
    end
    stopPursuit(zombie)
end

-- Catches zombies the moment vanilla AI targets a camouflaged player.
local function onZombieUpdate(zombie)
    if zombie:isRemoteZombie() then return end
    local target = zombie:getTarget()
    if not target then return end

    local entry = hiddenByPlayer[target]
    if entry then
        -- A zombie already on to the player keeps at it until it loses interest.
        local data = whispData(zombie)
        if not data.aware[entry.key] then fool(zombie, data, entry.key) end
        return
    end
    entry = loudByPlayer[target]
    if entry then whispData(zombie).aware[entry.key] = true end
end

local function collectPlayers()
    hiddenByPlayer, loudByPlayer, hidden, loud, seen = {}, {}, {}, {}, {}
    for _, e in ipairs(C.activeEntries()) do
        e.disguise = e.disguise or 0
        e.notice = W.noticeAt(e.disguise)
        if e.meter < e.notice then
            hiddenByPlayer[e.player] = e
            hidden[#hidden + 1] = e
        else
            loudByPlayer[e.player] = e
            loud[#loud + 1] = e
        end
    end

    local function addSeen(p)
        if p and not hiddenByPlayer[p] and not p:isDead() then
            seen[#seen + 1] = { x = p:getX(), y = p:getY(), z = p:getZ() }
        end
    end
    for i = 0, getNumActivePlayers() - 1 do addSeen(getSpecificPlayer(i)) end
    if isClient() then
        local ok, online = pcall(getOnlinePlayers)
        if ok and online then
            for i = 0, online:size() - 1 do
                local p = online:get(i)
                if not p:isLocalPlayer() then addSeen(p) end
            end
        end
    end
end

-- The hidden player a target-less zombie is walking toward, if any.
local WALKING = { PathFindState = true, WalkTowardState = true }

local function headingFor(zombie)
    if zombie:getTarget() then return nil end
    local ok, state = pcall(zombie.getCurrentStateName, zombie)
    if not ok or not WALKING[state] then return nil end
    local tx, ty, tz = zombie:getPathTargetX(), zombie:getPathTargetY(), zombie:getPathTargetZ()
    for _, e in ipairs(hidden) do
        local p = e.player
        if math.abs(p:getZ() - tz) <= 1 then
            local dx, dy = p:getX() - tx, p:getY() - ty
            if dx * dx + dy * dy <= GOAL_RADIUS * GOAL_RADIUS then return e end
        end
    end
    return nil
end

-- Chance an aware zombie loses interest in a hidden player this scan. The
-- half-life is InterestHalfLife seconds just under the notice level,
-- shrinking to a quarter of that at 0%, and halved at most by cover.
local function loseInterestChance(e)
    local halfLife = W.Get("InterestHalfLife") * (0.25 + 0.75 * e.meter / e.notice) * (1 - 0.5 * e.disguise)
    return 1 - 0.5 ^ ((SCAN_MS / 1000) / math.max(0.1, halfLife))
end

local function scan()
    collectPlayers()

    local cell = getCell()
    if not cell then return end
    local zombies = cell:getZombieList()
    if not zombies then return end

    local activeKeys = {}
    for _, e in ipairs(loud) do activeKeys[e.key] = true end
    for _, e in ipairs(hidden) do activeKeys[e.key] = true end
    local rMin, rMax = W.Get("AttractRadiusMin"), W.Get("AttractRadiusMax")
    local rFull = W.Get("FullAlertRadius")

    for i = 0, zombies:size() - 1 do
        local zombie = zombies:get(i)
        if zombie and not zombie:isDead() and not zombie:isRemoteZombie() then
            local data = zombie:getModData().Whisp

            -- In MP the useless flag syncs with the zombie but mod data does
            -- not, so a zombie handed over mid-hold arrives unmarked.
            if isClient() and not (data and data.held) and zombie:isUseless() then
                data = data or whispData(zombie)
                data.held = true
            end

            if data then
                -- Clear awareness of players who have washed up or left.
                for key in pairs(data.aware) do
                    if not activeKeys[key] then data.aware[key] = nil end
                end
                if data.held and not (nearHidden(zombie, rFull) and canHold(zombie, rFull)) then
                    release(zombie, data)
                end
            end

            -- Zombies on to a player who has gone quiet lose interest over time.
            if data then
                for _, e in ipairs(hidden) do
                    if data.aware[e.key] and ZombRandFloat(0, 1) < loseInterestChance(e) then
                        data.aware[e.key] = nil
                        if zombie:getTarget() == e.player then fool(zombie, data, e.key) end
                    end
                end
            end

            -- Walking to a hidden player's sound or last-seen spot. Only
            -- held zombies stay stopped, so leave it be if it can't be held.
            local e = headingFor(zombie)
            if e and not (data and data.aware[e.key]) and canHold(zombie, rFull) then
                data = data or whispData(zombie)
                fool(zombie, data, e.key)
            end

            for _, e in ipairs(loud) do
                local p = e.player
                if within(zombie, p:getX(), p:getY(), p:getZ(), rFull) then
                    data = data or whispData(zombie)
                    local full = e.meter >= W.FullMeter - 0.5
                    local t = W.clamp((e.meter - e.notice) / (W.FullMeter - e.notice), 0, 1)
                    -- Cover halves the notice radius at most.
                    local radius = full and rFull or (rMin + (rMax - rMin) * t) * (1 - 0.5 * e.disguise)
                    if not data.aware[e.key] then
                        if within(zombie, p:getX(), p:getY(), p:getZ(), radius) then
                            local chance = full and 1 or (0.2 + 0.6 * t)
                            if ZombRandFloat(0, 1) < chance then
                                data.aware[e.key] = true
                                alert(zombie, p)
                            end
                        end
                    elseif zombie:getTarget() == nil then
                        alert(zombie, p)
                    end
                end
            end
        end
    end
end

local function onTick()
    local now = getTimestampMs()
    if now - lastScanMs < SCAN_MS then return end
    lastScanMs = now
    scan()
end

Events.OnTick.Add(onTick)
Events.OnZombieUpdate.Add(onZombieUpdate)
