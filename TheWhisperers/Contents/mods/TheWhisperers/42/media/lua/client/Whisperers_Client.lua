-- The Whisperers: per-local-player noise meter, gore tracking and networking.
require "Whisperers_Shared"
require "Whisperers_Gear"

local W = Whisperers
local G = W.Gear
W.Client = W.Client or {}
local C = W.Client

C.States = {}   -- [playerNum] = local state
C.Remote = {}   -- [onlineID] = { meter, strength, active, t } relayed from the server

local UPDATE_MS = 100
local GORE_MS = 250
local NEAR_MS = 500
local SEND_MS = 1000
local IMPULSE_MERGE_MS = 250
local REMOTE_TIMEOUT_MS = 5000

local lastUpdateMs = 0

local function nowMs()
    return getTimestampMs()
end

function C.getState(playerNum)
    local st = C.States[playerNum]
    if not st then
        st = {
            meter = 0, reservoir = 0, lastActivityMs = 0,
            gore = 0, anyGore = false, strength = 0, active = false, multiplier = 1, disguise = 0,
            zombieNear = false, lastNearMs = 0,
            lastGoreMs = 0, lastSendMs = 0, sentClean = true,
            lastImpulseMs = 0, lastImpulseAmt = 0,
        }
        C.States[playerNum] = st
    end
    return st
end

local function say(player, textKey, good)
    if not HaloTextHelper then return end
    if good then
        HaloTextHelper.addGoodText(player, getText(textKey))
    else
        HaloTextHelper.addBadText(player, getText(textKey))
    end
end

-- Noise impulses are fed into a reservoir that drains into the meter at the
-- capped rise rate, so a single loud act pushes the meter up over several
-- seconds instead of snapping it. Near-simultaneous impulses (the swing and
-- the world sound of the same gunshot) are merged by taking the larger one.
-- Gore muffles small noises; loud ones (gunshots, shouting) mostly get
-- through. Dead-skin cover muffles both, small ones more. Noise made with no
-- zombie close enough to hear it is ignored.
local LOUD_IMPULSE = 20

function C.addImpulse(player, amount)
    if not player or not player:isLocalPlayer() then return end
    local st = C.getState(player:getPlayerNum())
    if not st.active or not st.zombieNear then return end
    if amount < LOUD_IMPULSE then
        amount = amount * (1 - 0.4 * st.strength) * (1 - 0.6 * st.disguise)
    else
        amount = amount * (1 - 0.3 * st.disguise)
    end
    amount = amount * W.Get("NoiseMultiplier")
    if amount <= 0 then return end

    local now = nowMs()
    if now - st.lastImpulseMs < IMPULSE_MERGE_MS then
        if amount > st.lastImpulseAmt then
            st.reservoir = st.reservoir + (amount - st.lastImpulseAmt)
            st.lastImpulseAmt = amount
        end
    else
        st.reservoir = st.reservoir + amount
        st.lastImpulseAmt = amount
    end
    st.lastImpulseMs = now
    st.reservoir = math.min(st.reservoir, W.FullMeter)
end

-- An upright level eased toward its disguised counterpart as worn dead skin
-- completes the disguise. The disguised level never raises it.
local function disguisedLevel(st, upright, disguised)
    local base = W.Get(upright)
    local low = math.min(base, W.Get(disguised))
    return base + (low - base) * (st.disguise or 0)
end

-- The level the meter drifts toward from posture/movement alone. Engines
-- give anyone away; everything else is quieter the more complete the
-- disguise.
local function postureLevel(player, st)
    local vehicle = player:getVehicle()
    if vehicle then
        return vehicle:isEngineRunning() and W.Get("SprintLevel") or 0
    end
    local moving = player:isPlayerMoving()
    if player:isSneaking() then
        return moving and W.Get("SneakMoveLevel") or 0
    end
    if player:isSprinting() then return disguisedLevel(st, "SprintLevel", "DisguisedSprintLevel") end
    if player:isRunning() then return disguisedLevel(st, "RunLevel", "DisguisedRunLevel") end
    if moving then return disguisedLevel(st, "UprightWalkLevel", "DisguisedWalkLevel") end
    return disguisedLevel(st, "UprightStillLevel", "DisguisedStillLevel")
end

-- True while a living zombie is within MeterZombieRadius tiles (and a floor)
-- of the player. The meter only rises then.
local function zombieNear(player)
    local cell = getCell()
    local zombies = cell and cell:getZombieList()
    if not zombies then return false end
    local r = W.Get("MeterZombieRadius")
    local x, y, z = player:getX(), player:getY(), player:getZ()
    for i = 0, zombies:size() - 1 do
        local zombie = zombies:get(i)
        if zombie and not zombie:isDead() and math.abs(zombie:getZ() - z) <= 1 then
            local dx, dy = zombie:getX() - x, zombie:getY() - y
            if dx * dx + dy * dy <= r * r then return true end
        end
    end
    return false
end

local function sendState(player, st, now)
    st.lastSendMs = now
    local args = {
        m = math.floor(st.meter * 10 + 0.5) / 10,
        s = math.floor(st.strength * 100 + 0.5) / 100,
        l = math.floor(st.disguise * 100 + 0.5) / 100,
        a = st.active,
        g = math.floor(st.gore + 0.5),
        d = st.anyGore,
    }
    sendClientCommand(player, W.Module, "State", args)
end

local function updatePlayer(player, st, dt, now)
    if player:isDead() then
        st.meter, st.reservoir, st.active, st.anyGore = 0, 0, false, false
        return
    end

    if now - st.lastGoreMs >= GORE_MS then
        st.lastGoreMs = now
        local wasActive, wasDirty = st.active, st.anyGore
        local _, cover
        st.gore, st.anyGore, _, st.multiplier, cover = W.measureGore(player)
        st.active = W.isCamouflaged(st.gore)
        st.strength = st.active and W.camoStrength(st.gore) or 0
        st.disguise = W.disguise(st.strength, cover)

        if st.active and not wasActive then
            say(player, "IGUI_Whisperers_Masked", true)
        elseif wasActive and not st.active and st.anyGore then
            say(player, "IGUI_Whisperers_Unmasked", false)
        elseif wasDirty and not st.anyGore then
            say(player, "IGUI_Whisperers_Clean", true)
        end

        if not W.isMultiplayer() then
            W.applyMisery(player, st.gore, st.anyGore)
        else
            -- The server owns the stats; holding the same floors here keeps
            -- the moodle steady between its syncs.
            W.setHold(player, "gore", st.anyGore and W.Get("DiscomfortLevel") or nil)
            G.holdGutsDiscomfort(player)
        end
    end

    if now - st.lastNearMs >= NEAR_MS then
        st.lastNearMs = now
        st.zombieNear = zombieNear(player)
    end

    -- Cover slows the rise, and speeds the fall with its square: a suit
    -- settles almost at once, a mask much less so, guts alone at the base rate.
    local disguise = st.disguise or 0
    local riseCap = W.Get("MeterRiseRate") * (1 - 0.4 * disguise) * dt
    local fall = W.Get("MeterFallRate") * (1 + (W.Get("CoverFallBoost") - 1) * disguise * disguise) * dt
    local fallDelayMs = W.Get("MeterFallDelay") * 1000 * (1 - disguise)

    if not st.active then
        st.reservoir = 0
        st.meter = math.max(0, st.meter - fall)
    else
        -- With no zombie close by there is no one to give yourself away to.
        local target = 0
        if st.zombieNear then
            target = postureLevel(player, st)
        else
            st.reservoir = 0
        end
        local rise = 0
        if st.reservoir > 0 then
            rise = math.min(st.reservoir, riseCap)
            st.reservoir = st.reservoir - rise
        end
        if st.meter + rise < target then
            rise = rise + math.min(riseCap - rise, target - st.meter - rise)
        end

        if rise > 0.0001 or (target > 0 and st.meter <= target) then
            st.meter = st.meter + rise
            st.lastActivityMs = now
        elseif st.meter > target and (now - st.lastActivityMs) >= fallDelayMs then
            st.meter = st.meter - math.min(fall, st.meter - target)
        end
        st.meter = W.clamp(st.meter, 0, W.FullMeter)
    end

    if isClient() then
        local interesting = st.active or st.anyGore or st.meter > 0
        if interesting and now - st.lastSendMs >= SEND_MS then
            sendState(player, st, now)
            st.sentClean = false
        elseif not interesting and not st.sentClean then
            sendState(player, st, now)
            st.sentClean = true
        end
    end
end

local function onTick()
    local now = nowMs()
    if now - lastUpdateMs < UPDATE_MS then return end
    local dt = lastUpdateMs == 0 and 0 or math.min((now - lastUpdateMs) / 1000, 1)
    lastUpdateMs = now

    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player then
            updatePlayer(player, C.getState(i), dt, now)
        end
    end

    for id, rs in pairs(C.Remote) do
        if now - rs.t > REMOTE_TIMEOUT_MS then C.Remote[id] = nil end
    end
end

-- Returns { player, key, meter, strength, disguise } for every camouflaged player this
-- client knows about (local players plus remote ones relayed by the server).
function C.activeEntries()
    local list = {}
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        local st = C.States[i]
        if player and st and st.active and not player:isDead() then
            list[#list + 1] = { player = player, key = W.playerKey(player), meter = st.meter,
                strength = st.strength, disguise = st.disguise or 0 }
        end
    end
    if isClient() then
        for id, rs in pairs(C.Remote) do
            if rs.active then
                local player = getPlayerByOnlineID(id)
                if player and not player:isLocalPlayer() and not player:isDead() then
                    list[#list + 1] = { player = player, key = "o" .. tostring(id), meter = rs.meter,
                        strength = rs.strength, disguise = rs.disguise }
                end
            end
        end
    end
    return list
end

-- Noise sources ----------------------------------------------------------

local function onWorldSound(x, y, z, radius, volume, source)
    if source and instanceof(source, "IsoPlayer") and source:isLocalPlayer() then
        C.addImpulse(source, math.min((radius or 0) * 1.2, W.FullMeter))
    end
end

local function onWeaponSwing(character, weapon)
    if not character or not instanceof(character, "IsoPlayer") or not character:isLocalPlayer() then return end
    if weapon and weapon:isRanged() then
        C.addImpulse(character, math.min((weapon:getSoundRadius() or 0) * 1.5, W.FullMeter))
    else
        -- Attacking is a giveaway however good the disguise.
        C.addImpulse(character, W.Get("MeleeNoise"))
    end
end

local function onHitZombie(zombie, character)
    if character and instanceof(character, "IsoPlayer") then
        C.addImpulse(character, 4)
    end
end

local function onServerCommand(module, command, args)
    if module ~= W.Module or command ~= "State" or type(args) ~= "table" then return end
    local id = tonumber(args.id)
    if not id then return end
    local p = getPlayerByOnlineID(id)
    if p and p:isLocalPlayer() then return end
    C.Remote[id] = {
        meter = tonumber(args.m) or 0,
        strength = tonumber(args.s) or 0,
        disguise = tonumber(args.l) or 0,
        active = args.a == true,
        t = nowMs(),
    }
end

Events.OnTick.Add(onTick)
Events.OnWorldSound.Add(onWorldSound)
Events.OnWeaponSwing.Add(onWeaponSwing)
Events.OnHitZombie.Add(onHitZombie)
Events.OnServerCommand.Add(onServerCommand)
