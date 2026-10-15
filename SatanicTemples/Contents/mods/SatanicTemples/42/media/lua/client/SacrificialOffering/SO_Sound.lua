require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Logger"

-- Server-cued ritual audio, played from the start of the ritual. SatanThinks
-- opens every ritual; the server's first cue names the verdict's sound, which
-- follows at once (the long SacrificeAccepted track layers under SatanThinks)
-- or, for Denied and PlayerCorpse, as SatanThinks ends. The ritual's result
-- only clears the state when it arrives at the end.

local SO = SacrificialOffering
SO.Sound = SO.Sound or {}
local Sound = SO.Sound

local SOUND_THINKS = "STemple_SatanThinks"
local SOUND_ACCEPTED = "STemple_SacrificeAccepted"
local SOUND_DENIED = "STemple_SacrificeDenied"
local SOUND_PLAYER_CORPSE = "STemple_PlayerCorpse"

-- Success deliberately layers SatanThinks and SacrificeAccepted, so retain all
-- current handles instead of replacing one sound with the next.
local activeHandles = {}
-- A verdict sound waiting for SatanThinks to finish: { name, at }.
local queued = nil
local THINKS_MS = 5000
-- True from "player clicks Make a Sacrifice" until the server rules on the offer.
Sound.ritualPending = false
Sound.ritualTx = nil
Sound.firstBeatPlayed = false

local function localSoundManager()
    return getSoundManager and getSoundManager() or nil
end

local function stopActive()
    local manager = localSoundManager()
    if manager then
        for _, handle in ipairs(activeHandles) do
            if handle and handle ~= 0 and manager:isPlayingUISound(handle) then manager:stopUISound(handle) end
        end
    end
    activeHandles = {}
    queued = nil
end

local function playOneShot(name)
    local manager = localSoundManager()
    if not manager then
        SO.Logger.Warn("Cannot play ritual sound without the UI sound manager", { sound = name })
        return false
    end
    local ok, handle = pcall(function() return manager:playUISound(name) end)
    if not ok then
        SO.Logger.Error("Failed to play ritual sound", { sound = name, error = tostring(handle) })
        return false
    end
    if not handle or handle == 0 then
        SO.Logger.Warn("Ritual sound was not registered or has no playable clip", { sound = name })
        return false
    end
    activeHandles[#activeHandles + 1] = handle
    return true
end

local function matchesPendingTransaction(tx)
    return Sound.ritualPending and tx ~= nil and tostring(tx) == Sound.ritualTx
end

-- Start silently; the server's first-beat cue arrives after it has inspected the
-- offering, preventing an unknown failure from playing the accepted sound.
function Sound.BeginRitual(tx)
    stopActive()
    Sound.ritualPending = true
    Sound.ritualTx = tx ~= nil and tostring(tx) or nil
    Sound.firstBeatPlayed = false
end

function Sound.HandleFirstBeat(args)
    if not args or not matchesPendingTransaction(args.tx) then return end
    if Sound.firstBeatPlayed then return end
    Sound.firstBeatPlayed = true
    playOneShot(SOUND_THINKS)
    if args.outcome == SO.SOUND_OUTCOME.SUCCESS_ITEM then
        playOneShot(SOUND_ACCEPTED)
    elseif args.outcome == SO.SOUND_OUTCOME.FAILURE then
        queued = { name = SOUND_DENIED, at = getTimestampMs() + THINKS_MS }
    elseif args.outcome == SO.SOUND_OUTCOME.PLAYER_CORPSE then
        queued = { name = SOUND_PLAYER_CORPSE, at = getTimestampMs() + THINKS_MS }
    end
end

-- The ritual's result arrives when it ends; its sound has already played from
-- the start. Only a result for a ritual that never got its first cue (an
-- instant action) plays the verdict here.
function Sound.ResolveRitual(args)
    if not args or not matchesPendingTransaction(args.tx) then return end
    local cueHeard = Sound.firstBeatPlayed
    Sound.ritualPending = false
    Sound.ritualTx = nil
    Sound.firstBeatPlayed = false
    if cueHeard then return end

    stopActive()
    if args.soundOutcome == SO.SOUND_OUTCOME.FAILURE then
        playOneShot(SOUND_DENIED)
    elseif args.soundOutcome == SO.SOUND_OUTCOME.PLAYER_CORPSE then
        playOneShot(SOUND_PLAYER_CORPSE)
    elseif args.soundOutcome == SO.SOUND_OUTCOME.SUCCESS_ITEM then
        playOneShot(SOUND_ACCEPTED)
    end
end

-- The ritual was abandoned before the server ruled on it (the player walked out
-- of range). Silence the chant; no denial sound - nothing was judged.
function Sound.CancelRitual()
    Sound.ritualPending = false
    Sound.ritualTx = nil
    Sound.firstBeatPlayed = false
    stopActive()
end

-- A corpse holds no chant: if the supplicant dies mid-ritual, kill the sound
-- instead of letting it ring out over their body.
local function onPlayerDeath(player)
    if player and player:isLocalPlayer() then
        Sound.ritualPending = false
        Sound.ritualTx = nil
        Sound.firstBeatPlayed = false
        stopActive()
    end
end

Events.OnPlayerDeath.Add(onPlayerDeath)

local function playQueued()
    if queued and getTimestampMs() >= queued.at then
        local name = queued.name
        queued = nil
        playOneShot(name)
    end
end
Events.OnTick.Add(playQueued)

return Sound
