-- KIPN_ExcavationBoundaryOverlay.lua
--
-- Client-only visualization of the local player's established excavation
-- claims. This file never creates, validates, consumes, releases, or mutates
-- a claim. It only requests the player's authoritative claim records and
-- queues one-tile-wide world highlights around nearby excavation rectangles.

if isServer() then
    return
end

require "ISUI/ISPanel"
require "KIPN_Shared"

KIPN_ExcavationBoundaryOverlay =
    KIPN_ExcavationBoundaryOverlay or {}

local BoundaryRenderer =
    ISPanel:derive("KIPN_ExcavationBoundaryRenderer")

local claims = {}
local overlayEnabled = true
local tickCounter = 0
local rendererInstance = nil
local requestStartedAtMs = nil
local requestReason = nil
local renderErrorLogged = false

local REQUEST_EVERY_TICKS = 600
local PROXIMITY_TILES = 12

local function nowMs()
    if type(getTimestampMs) == "function" then
        return getTimestampMs()
    end

    return math.floor(os.clock() * 1000)
end

local function log(message)
    print("[KIPN EXCAVATION BOUNDS] " .. tostring(message))
end

local function logMetaRun(outcome, detail)
    local elapsed = requestStartedAtMs
        and (nowMs() - requestStartedAtMs)
        or "unknown"

    print(
        "[KIPN EXCAVATION BOUNDS META TIME RUN LOG] "
        .. "operation=refresh_claims"
        .. " | reason=" .. tostring(requestReason or "unknown")
        .. " | outcome=" .. tostring(outcome)
        .. " | totalMs=" .. tostring(elapsed)
        .. (detail and " | " .. tostring(detail) or "")
    )

    requestStartedAtMs = nil
    requestReason = nil
end

local function requestClaims(reason)
    if not KIPN.Shared
        or not KIPN.Shared.Commands
        or not KIPN.Shared.Commands.GET_MY_CLAIMS
    then
        log("Claim refresh skipped: GET_MY_CLAIMS is unavailable.")
        return false
    end

    requestStartedAtMs = nowMs()
    requestReason = reason or "unspecified"

    log("Requesting authoritative claims | reason=" .. requestReason)

    sendClientCommand(
        "KIPN",
        KIPN.Shared.Commands.GET_MY_CLAIMS,
        {}
    )

    return true
end

local function distanceToRect(px, py, claim)
    local x1 = tonumber(claim and claim.rectX1)
    local y1 = tonumber(claim and claim.rectY1)
    local x2 = tonumber(claim and claim.rectX2)
    local y2 = tonumber(claim and claim.rectY2)

    if not x1 or not y1 or not x2 or not y2 then
        return math.huge
    end

    local dx = px < x1 and (x1 - px)
        or (px > x2 and (px - x2) or 0)

    local dy = py < y1 and (y1 - py)
        or (py > y2 and (py - y2) or 0)

    return math.max(dx, dy)
end

local function isNearby(claim, player)
    if not claim
        or claim.type ~= "excavation"
        or not player
    then
        return false
    end

    local claimZ = tonumber(claim.locationZ or 0)
    if not claimZ
        or math.floor(claimZ) ~= math.floor(player:getZ())
    then
        return false
    end

    return distanceToRect(
        player:getX(),
        player:getY(),
        claim
    ) <= PROXIMITY_TILES
end

local function queueAreaHighlight(
    playerNum,
    x1,
    y1,
    x2Exclusive,
    y2Exclusive,
    z,
    r,
    g,
    b,
    a
)
    local ok, renderError = pcall(
        addAreaHighlightForPlayer,
        playerNum,
        x1,
        y1,
        x2Exclusive,
        y2Exclusive,
        z,
        r,
        g,
        b,
        a
    )

    if not ok then
        if not renderErrorLogged then
            renderErrorLogged = true
            log("Area-highlight render failed: " .. tostring(renderError))
        end

        return false
    end

    renderErrorLogged = false
    return true
end

local function queueClaimOutline(playerNum, claim)
    local x1 = tonumber(claim.rectX1)
    local y1 = tonumber(claim.rectY1)
    local x2 = tonumber(claim.rectX2)
    local y2 = tonumber(claim.rectY2)
    local z = tonumber(claim.locationZ or 0)

    if not x1 or not y1 or not x2 or not y2 or not z then
        return false
    end

    x1 = math.floor(x1)
    y1 = math.floor(y1)
    x2 = math.floor(x2)
    y2 = math.floor(y2)
    z = math.floor(z)

    if x2 < x1 or y2 < y1 then
        return false
    end

    -- addAreaHighlightForPlayer() uses exclusive x2/y2 coordinates.
    -- Four thin rectangles create a one-tile perimeter without filling the
    -- entire established claim. Cyan distinguishes owned bounds from the
    -- blue/red placement preview.
    local r, g, b, a = 0.20, 0.85, 0.95, 0.42
    local queued = queueAreaHighlight(
        playerNum, x1, y1, x2 + 1, y1 + 1, z, r, g, b, a
    )

    if y2 ~= y1 then
        queued = queueAreaHighlight(
            playerNum, x1, y2, x2 + 1, y2 + 1, z, r, g, b, a
        ) or queued
    end

    local interiorY1 = y1 + 1
    local interiorY2Exclusive = y2

    if interiorY1 < interiorY2Exclusive then
        queued = queueAreaHighlight(
            playerNum,
            x1,
            interiorY1,
            x1 + 1,
            interiorY2Exclusive,
            z,
            r,
            g,
            b,
            a
        ) or queued

        if x2 ~= x1 then
            queued = queueAreaHighlight(
                playerNum,
                x2,
                interiorY1,
                x2 + 1,
                interiorY2Exclusive,
                z,
                r,
                g,
                b,
                a
            ) or queued
        end
    end

    return queued
end

function BoundaryRenderer:new(player)
    -- A tiny, transparent UI element is enough to receive render() every
    -- frame. It does not draw UI pixels; it only queues world highlights.
    local o = ISPanel:new(0, 0, 1, 1)
    setmetatable(o, self)
    self.__index = self

    o.playerNum = player:getPlayerNum()
    o.lastNearbyCount = -1
    return o
end

function BoundaryRenderer:initialise()
    ISPanel.initialise(self)

    self.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.borderColor = { r = 0, g = 0, b = 0, a = 0 }

    if self.setConsumeMouseEvents then
        self:setConsumeMouseEvents(false)
    end
end

function BoundaryRenderer:prerender()
    -- Intentionally empty: no panel background or border.
end

function BoundaryRenderer:render()
    if not overlayEnabled then
        if self.lastNearbyCount ~= 0 then
            self.lastNearbyCount = 0
            log("Boundary renderer idle: overlay is disabled.")
        end

        return
    end

    if type(addAreaHighlightForPlayer) ~= "function" then
        if not renderErrorLogged then
            renderErrorLogged = true
            log("addAreaHighlightForPlayer is unavailable; bounds cannot render.")
        end

        return
    end

    local player = getSpecificPlayer(self.playerNum) or getPlayer()
    if not player then
        return
    end

    local nearbyCount = 0

    for _, claim in ipairs(claims) do
        if isNearby(claim, player)
            and queueClaimOutline(self.playerNum, claim)
        then
            nearbyCount = nearbyCount + 1
        end
    end

    if nearbyCount ~= self.lastNearbyCount then
        self.lastNearbyCount = nearbyCount
        log(
            "Boundary render state changed | nearbyClaims="
            .. tostring(nearbyCount)
            .. " | player=" .. tostring(self.playerNum)
            .. " | z=" .. tostring(math.floor(player:getZ()))
        )
    end
end

local function ensureRenderer(player)
    if not player then
        return false
    end

    if rendererInstance then
        rendererInstance.playerNum = player:getPlayerNum()
        return true
    end

    rendererInstance = BoundaryRenderer:new(player)
    rendererInstance:initialise()
    rendererInstance:addToUIManager()
    rendererInstance:setAlwaysOnTop(true)

    log(
        "Boundary renderer created | player="
        .. tostring(rendererInstance.playerNum)
    )

    return true
end

local function onServerCommand(module, command, args)
    if module ~= "KIPN"
        or not KIPN.Shared
        or not KIPN.Shared.Commands
        or command ~= KIPN.Shared.Commands.SERVER_RESPONSE
        or not args
    then
        return
    end

    local event = args.event

    if event == KIPN.Shared.ResponseEvents.MY_CLAIMS_DATA then
        claims = type(args.data) == "table" and args.data or {}

        log("Authoritative claim cache replaced | count=" .. tostring(#claims))
        logMetaRun("received", "claimCount=" .. tostring(#claims))
        return
    end

    -- Refresh immediately after the placement service confirms a new claim;
    -- the periodic refresh remains a fallback for releases and other changes.
    if event == KIPN.Shared.ResponseEvents.EXCAVATION_CLAIM_SUCCESSFUL then
        requestClaims("claim_success")
    end
end

local function onPlayerUpdate(player)
    if not player or player ~= getPlayer() then
        return
    end

    ensureRenderer(player)

    tickCounter = tickCounter + 1
    if tickCounter < REQUEST_EVERY_TICKS then
        return
    end

    tickCounter = 0
    requestClaims("periodic")
end

local function toggleBounds()
    overlayEnabled = not overlayEnabled

    log("Overlay toggled | enabled=" .. tostring(overlayEnabled))

    local player = getPlayer()
    if player and player.Say then
        player:Say(
            overlayEnabled
            and "Excavation bounds enabled."
            or "Excavation bounds hidden."
        )
    end
end

local function onFillWorldObjectContextMenu(
    playerNum,
    context,
    _worldobjects,
    test
)
    if test or not context then
        return
    end

    local player = getSpecificPlayer(playerNum)
    if not player then
        return
    end

    local nearClaim = false
    for _, claim in ipairs(claims) do
        if isNearby(claim, player) then
            nearClaim = true
            break
        end
    end

    if not nearClaim then
        return
    end

    context:addOption(
        overlayEnabled
        and "Hide Excavation Bounds"
        or "Show Excavation Bounds",
        nil,
        toggleBounds
    )
end

local function onCreatePlayer(_index, player)
    local localPlayer = player or getPlayer()
    ensureRenderer(localPlayer)
    requestClaims("player_created")
end

local function onGameStart()
    local player = getPlayer()
    ensureRenderer(player)
    requestClaims("game_start")
end

KIPN_ExcavationBoundaryOverlay.RequestClaims = requestClaims
KIPN_ExcavationBoundaryOverlay.SetEnabled = function(enabled)
    overlayEnabled = enabled == true
    log("Overlay enabled state set | enabled=" .. tostring(overlayEnabled))
end
KIPN_ExcavationBoundaryOverlay.IsEnabled = function()
    return overlayEnabled
end

if Events.OnServerCommand then
    Events.OnServerCommand.Add(onServerCommand)
end

if Events.OnPlayerUpdate then
    Events.OnPlayerUpdate.Add(onPlayerUpdate)
end

if Events.OnFillWorldObjectContextMenu then
    Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
end

if Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(onCreatePlayer)
end

if Events.OnGameStart then
    Events.OnGameStart.Add(onGameStart)
end

local loadedPlayer = getPlayer()
if loadedPlayer then
    ensureRenderer(loadedPlayer)
    requestClaims("script_load")
end

log("Client excavation boundary overlay loaded.")
