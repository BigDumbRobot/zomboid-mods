-- The Whisperers: looking out through a dead face's eye holes. A worn face
-- mask blurs everything past MaskClearRadius tiles, like going without your
-- glasses. Borrows vanilla's search-mode overlay and steps aside while the
-- player is foraging, since search mode drives the overlay then.
require "Whisperers_Gear"

local W = Whisperers
local G = W.Gear

local CHECK_MS = 250
local DARKNESS = 0.15   -- a faint vignette from the eye holes

local lastMs = 0
local blurring = {}     -- [playerNum] = true while the mask owns the overlay

local function foraging(player)
    local m = ISSearchManager and ISSearchManager.players and ISSearchManager.players[player]
    return m ~= nil and (m.isSearchMode or m.isEffectOverlay)
end

local function wantsBlur(player)
    return player and not player:isDead() and W.Get("Enabled")
        and W.Get("MaskVisionBlur") > 0 and G.wornMask(player) ~= nil
end

local function update(playerNum, player)
    local sm = getSearchMode()
    if wantsBlur(player) and not foraging(player) then
        local psm = sm:getSearchModeForPlayer(playerNum)
        local blur = W.Get("MaskVisionBlur") / 100
        local radius = W.Get("MaskClearRadius")
        psm:getBlur():setTargets(blur, blur)
        psm:getDesat():setTargets(0, 0)
        psm:getRadius():setTargets(radius, radius)
        psm:getGradientWidth():setTargets(2, 2)
        psm:getDarkness():setTargets(DARKNESS, DARKNESS)
        sm:setEnabled(playerNum, true)
        blurring[playerNum] = true
    elseif blurring[playerNum] then
        blurring[playerNum] = nil
        if not (player and foraging(player)) then sm:setEnabled(playerNum, false) end
    end
end

local function onTick()
    local now = getTimestampMs()
    if now - lastMs < CHECK_MS then return end
    lastMs = now
    for playerNum = 0, 3 do
        update(playerNum, getSpecificPlayer(playerNum))
    end
end

Events.OnTick.Add(onTick)
