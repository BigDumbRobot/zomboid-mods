-- KIPN_ClaimCraftSound.lua
--
-- CLAIM-ARTIFACT CRAFTING AUDIO CUE
--
-- Shared client helper for the KIPN claim-artifact crafting flows:
--   * Safehouse Deed     -- KIPN: Government Services
--   * Excavation Permit  -- KIPN: Government Services
--   * Vehicle Title      -- KIPN: Vehicle Services
--   * PO Box Key         -- The Post Office
--
-- Three clips play in sequence for the duration of a claim craft,
-- all as positional world sounds from the square the player started
-- the operation on, so anyone at the terminal hears them:
--
--   KIPN_ClaimStart  -- one-shot, fired the instant the player
--                       clicks "Craft a Safehouse Deed" / "Craft an
--                       Excavation Permit" / "Craft a Vehicle Title".
--   KIPN_ClaimLOOP   -- loop = true, started on the same tick and
--                       kept running underneath for the whole craft
--                       wait, however long it lasts.
--   KIPN_ClaimEnd    -- one-shot, played once the wait finishes and
--                       the loop is stopped.
--
-- The start + loop are a matched pair -- Start() fires both. On a
-- clean finish Complete() stops the loop and plays KIPN_ClaimEnd as
-- the tail. On a declined request Fail() stops the loop and plays
-- KIPN_Error in place of the tail.
--
-- The loop is cut with NO tail (Stop(), or the watchdog below) when
-- the craft is abandoned or interrupted:
--   * the screen is closed / navigated away mid-craft
--     (the companion screens call Stop() from onLeaveScreen)
--   * the player dies
--   * the terminal computer is picked up / removed
--   * the terminal square loses power
--
-- API:
--   KIPN.ClaimCraftSound.Start()     -- crafting begins
--   KIPN.ClaimCraftSound.Complete()  -- claim artifact issued
--   KIPN.ClaimCraftSound.Fail()      -- request declined
--   KIPN.ClaimCraftSound.Stop()      -- abandoned (no tail)

KIPN = KIPN or {}

KIPN.ClaimCraftSound =
    KIPN.ClaimCraftSound or {}

local Cue = KIPN.ClaimCraftSound

local START_SOUND = "KIPN_ClaimStart"
local LOOP_SOUND = "KIPN_ClaimLOOP"
local END_SOUND = "KIPN_ClaimEnd"
local FAIL_SOUND = "KIPN_Error"

local SOUND_RADIUS = 10

-- Hard cap: if neither Complete() nor Fail() lands within this many
-- real milliseconds of Start() (screen abandoned without a leave
-- hook, server never answers, ...), the loop is force-stopped so it
-- can never become a stuck infinite drone. Comfortably longer than
-- the largest configurable client craft wait (the *ClaimCraftSeconds
-- sandbox options cap at 300s) plus a server round trip -- this is a
-- stuck-state backstop, not a normal-path limiter.
local MAX_LOOP_MS = 360000

local state = {
    loopId = nil,
    startedAtMs = nil,
    startSquare = nil,
}

--------------------------------------------------------------------
-- LOGGING
--------------------------------------------------------------------

local function logError(message)

    if KIPN.Logger and KIPN.Logger.Error then

        KIPN.Logger.Error(
            "KIPN_ClaimCraftSound: " .. tostring(message)
        )

        return
    end

    print(
        "[KIPN CLAIM CRAFT SOUND] ERROR: "
        .. tostring(message)
    )
end

--------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------

-- Real elapsed wall-clock time (not a frame-tick count), used by the
-- watchdog's stuck-state backstop. PZ exposes no bare `getRuntimeMs`
-- global -- the other terminal screens (KIPN_BootScreen,
-- KIPN_ServerStats, ...) each define this same local wrapper over
-- getTimestampMs(), failing closed to 0 when it is unavailable.
local function getRuntimeMs()

    if not _G.getTimestampMs then
        return 0
    end

    local ok, result =
        pcall(function()
            return _G.getTimestampMs()
        end)

    if ok and type(result) == "number" then
        return result
    end

    return 0
end

local function currentSquare()

    local player =
        getPlayer
        and getPlayer()

    return player
        and player:getSquare()
        or nil
end

-- Is there still a KIPN-recognized computer object on `square`?
-- Used by the watchdog so a mid-craft pickup / disassemble of the
-- terminal computer cuts the loop even though the companion screen
-- (which lives on regardless) never fires onLeaveScreen.
local function squareHasComputer(square)

    if not square or not square.getObjects then
        return false
    end

    if not (KIPN.Shared and KIPN.Shared.IsComputerObjectSprite) then
        -- Can't tell -- don't cut on this rule.
        return true
    end

    local ok, found =
        pcall(function()

            local objects = square:getObjects()

            if not objects then
                return false
            end

            for i = 0, objects:size() - 1 do

                local obj = objects:get(i)

                if obj
                    and KIPN.Shared.IsComputerObjectSprite(obj)
                then
                    return true
                end
            end

            return false
        end)

    return ok and found == true
end

local function onTick()

    -- Watchdog -- only meaningful while a loop is active.
    if not state.loopId then

        if Events and Events.OnTick then
            Events.OnTick.Remove(onTick)
        end

        return
    end

    -- Stuck-state backstop.
    if not state.startedAtMs
        or getRuntimeMs() - state.startedAtMs >= MAX_LOOP_MS
    then
        Cue.Stop()

        return
    end

    -- Player died mid-craft -> cut, no tail.
    local player =
        getPlayer
        and getPlayer()
        or nil

    if not player
        or (player.isDead and player:isDead())
    then
        Cue.Stop()

        return
    end

    -- Terminal square lost power mid-craft -> cut, no tail.
    if KIPN.Shared
        and KIPN.Shared.HasSquareElectricity
        and not KIPN.Shared.HasSquareElectricity(state.startSquare)
    then
        Cue.Stop()

        return
    end

    -- Terminal computer picked up / removed mid-craft -> cut, no tail.
    if not squareHasComputer(state.startSquare) then
        Cue.Stop()

        return
    end
end

-- Vanilla Events.OnObjectAboutToBeRemoved -- fires the instant a
-- world object is picked up / scrapped, so a pickup of the terminal
-- computer cuts the loop on the same tick rather than waiting for
-- the onTick square scan.
local function onObjectAboutToBeRemoved(object)

    if not state.loopId or not object then
        return
    end

    local ok, err =
        pcall(function()

            if not (KIPN.Shared and KIPN.Shared.IsComputerObjectSprite) then
                return
            end

            if not KIPN.Shared.IsComputerObjectSprite(object) then
                return
            end

            local square =
                object.getSquare
                and object:getSquare()
                or nil

            -- Only our terminal square's computer counts. If we
            -- somehow never recorded the start square, fall back to
            -- cutting on any computer removal.
            if state.startSquare
                and square ~= state.startSquare
            then
                return
            end

            Cue.Stop()
        end)

    if not ok then
        logError("onObjectAboutToBeRemoved(): " .. tostring(err))
    end
end

local function addWatchdog()

    if Events and Events.OnTick then
        Events.OnTick.Remove(onTick)
        Events.OnTick.Add(onTick)
    end

    if Events and Events.OnObjectAboutToBeRemoved then
        Events.OnObjectAboutToBeRemoved.Remove(onObjectAboutToBeRemoved)
        Events.OnObjectAboutToBeRemoved.Add(onObjectAboutToBeRemoved)
    end
end

local function removeWatchdog()

    if Events and Events.OnTick then
        Events.OnTick.Remove(onTick)
    end

    if Events and Events.OnObjectAboutToBeRemoved then
        Events.OnObjectAboutToBeRemoved.Remove(onObjectAboutToBeRemoved)
    end
end

local function stopLoop()

    if not state.loopId then
        return
    end

    local id = state.loopId

    state.loopId = nil
    state.startedAtMs = nil
    state.startSquare = nil

    removeWatchdog()

    pcall(function()
        getSoundManager():StopSound(id)
    end)
end

local function playOneShot(soundName)

    local square = currentSquare()

    if not square then
        return
    end

    pcall(function()
        getSoundManager():PlayWorldSound(
            soundName,
            square,
            0,
            SOUND_RADIUS,
            1,
            false
        )
    end)
end

--------------------------------------------------------------------
-- START
--
-- Begins (or restarts) the claim-craft cue from the player's
-- current square: the KIPN_ClaimStart one-shot plus the
-- KIPN_ClaimLOOP loop. Idempotent.
--------------------------------------------------------------------

function Cue.Start()

    local ok, err =
        pcall(function()

            stopLoop()

            local square = currentSquare()

            if not square then
                return
            end

            -- One-shot opener.
            pcall(function()
                getSoundManager():PlayWorldSound(
                    START_SOUND,
                    square,
                    0,
                    SOUND_RADIUS,
                    1,
                    false
                )
            end)

            -- Loop underneath for the craft wait.
            local id =
                getSoundManager():PlayWorldSound(
                    LOOP_SOUND,
                    true,
                    square,
                    0,
                    SOUND_RADIUS,
                    1,
                    false
                )

            if not id then
                return
            end

            state.loopId = id
            state.startedAtMs = getRuntimeMs()
            state.startSquare = square

            addWatchdog()
        end)

    if not ok then
        logError("Start(): " .. tostring(err))
    end
end

--------------------------------------------------------------------
-- COMPLETE
--
-- Crafting finished successfully: stop the loop and play
-- KIPN_ClaimEnd once as the tail.
--------------------------------------------------------------------

function Cue.Complete()

    local ok, err =
        pcall(function()

            stopLoop()

            playOneShot(END_SOUND)
        end)

    if not ok then
        logError("Complete(): " .. tostring(err))
    end
end

--------------------------------------------------------------------
-- FAIL
--
-- Request declined by the server: stop the loop and play the error
-- cue in place of the tail.
--------------------------------------------------------------------

function Cue.Fail()

    local ok, err =
        pcall(function()

            stopLoop()

            playOneShot(FAIL_SOUND)
        end)

    if not ok then
        logError("Fail(): " .. tostring(err))
    end
end

--------------------------------------------------------------------
-- STOP
--
-- Abandoned mid-craft (screen closed / navigated away, player died,
-- computer picked up, power lost): silence the loop with no tail.
--------------------------------------------------------------------

function Cue.Stop()

    local ok, err = pcall(stopLoop)

    if not ok then
        logError("Stop(): " .. tostring(err))
    end
end

print("[KIPN CLAIM CRAFT SOUND] Module loaded.")
