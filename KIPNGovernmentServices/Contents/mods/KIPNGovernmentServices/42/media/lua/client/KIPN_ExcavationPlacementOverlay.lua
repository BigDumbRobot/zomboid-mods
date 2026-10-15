-- KIPN_ExcavationPlacementOverlay.lua
--
-- Mouse-driven placement mode for establishing an excavation claim.
--
-- Activated by client/KIPN_ExcavationClaimMenu.lua's "Claim Land"
-- context menu option. Renders a translucent rectangle, sized to
-- the purchased claim tier, that follows the mouse across the
-- actual isometric game world (not a flat map). Left-click sends
-- the hovered tile as a PROPOSED target to
-- KIPN.Shared.Commands.CLAIM_EXCAVATION; the server
-- (KIPN_PropertyClaimService.lua's handleClaimExcavationCommand) is
-- the sole authority on whether that location can actually be claimed
-- -- it independently re-validates distance from the player,
-- ownership, zone restrictions, and claim artifact possession.
--
-- Escape or right-click cancels placement without sending anything.
--
-- Cursor conversion and rendering use the same Build 42 paths as the
-- game's area-selection UIs:
--   * screen -> world: ISCoordConversion.ToWorld()
--   * world highlight: addAreaHighlightForPlayer() from render()
--
-- Area-highlight end coordinates are exclusive, while claim rectangles
-- are inclusive. The render call therefore uses x2 + 1 and y2 + 1.

if isServer() then
    return
end

require "ISUI/ISPanel"

if not KIPN then
    error(
        "[KIPN_ExcavationPlacementOverlay] "
        .. "KIPN core is not initialized."
    )
end

if not KIPN.Shared then
    error(
        "[KIPN_ExcavationPlacementOverlay] "
        .. "KIPN_Shared is not initialized."
    )
end

KIPN_ExcavationPlacementOverlay =
    ISPanel:derive("KIPN_ExcavationPlacementOverlay")

local instance = nil

-- The player who last submitted a claim, kept outside the overlay
-- instance (which is torn down immediately on submit) so the
-- server-response listener below still has someone to :Say() the
-- result to.
local lastClaimPlayer = nil

-- Placement preview activation is deferred until the client receives
-- the current admin-configured Small / Medium / Large tier table from
-- the authoritative server.
local pendingActivationPlayer = nil
local pendingActivationSizeClass = nil

-- Last authoritative tier table received from the server during this
-- client session. Reused for subsequent placement attempts so a failed
-- claim cannot strand the player waiting on another tier-data response.
local cachedExcavationTiers = nil

-- Timestamp for measuring the server round trip after a placement submit.
local lastClaimRequestStartedAtMs = nil

-- One compact run log is emitted when a placement session ends. Individual
-- milestones still print immediately, while this summary makes it possible
-- to see the whole activation -> preview -> submit/cancel path at a glance.
local metaRunLog = nil

local function nowMs()
    if type(getTimestampMs) == "function" then
        return getTimestampMs()
    end

    return math.floor(os.clock() * 1000)
end

local function log(message)
    local text = tostring(message)
    print("[KIPN EXCAVATION PLACEMENT] " .. text)

    if metaRunLog then
        table.insert(
            metaRunLog.entries,
            tostring(nowMs() - metaRunLog.startedAtMs) .. "ms=" .. text
        )
    end
end

local function beginMetaRun(sizeClass)
    metaRunLog = {
        startedAtMs = nowMs(),
        entries = {},
    }

    log("Placement run started | class=" .. tostring(sizeClass))
end

local function finishMetaRun(outcome)
    if not metaRunLog then
        return
    end

    local totalMs = nowMs() - metaRunLog.startedAtMs
    local entries = table.concat(metaRunLog.entries, " | ")

    print(
        "[KIPN EXCAVATION PLACEMENT META TIME RUN LOG] "
        .. "outcome=" .. tostring(outcome)
        .. " | totalMs=" .. tostring(totalMs)
        .. (entries ~= "" and " | " .. entries or "")
    )

    metaRunLog = nil
end

local function logClaimRoundTrip(outcome, detail)
    local elapsed = lastClaimRequestStartedAtMs
        and (nowMs() - lastClaimRequestStartedAtMs)
        or "unknown"

    print(
        "[KIPN EXCAVATION PLACEMENT META TIME RUN LOG] "
        .. "operation=claim_round_trip"
        .. " | outcome=" .. tostring(outcome)
        .. " | totalMs=" .. tostring(elapsed)
        .. (detail and " | detail=" .. tostring(detail) or "")
    )

    lastClaimRequestStartedAtMs = nil
end

local function normalizeSizeClass(value)

    if type(value) ~= "string" then
        return nil
    end

    local normalized =
        string.lower(value)

    if normalized == "small"
        or normalized == "medium"
        or normalized == "large"
    then
        return normalized
    end

    return nil

end

local function findTierByClass(tiers, sizeClass)

    local wanted =
        normalizeSizeClass(sizeClass)

    if not wanted
        or type(tiers) ~= "table"
    then
        return nil
    end

    for _, tier in ipairs(tiers) do

        if type(tier) == "table"
            and normalizeSizeClass(tier.id) == wanted
        then

            local width =
                tonumber(tier.widthTiles)

            local height =
                tonumber(tier.heightTiles)

            if width
                and height
                and width > 0
                and height > 0
            then

                return {
                    id = wanted,
                    label = tier.label,
                    widthTiles = math.floor(width),
                    heightTiles = math.floor(height),
                    price = tier.price,
                }

            end

        end

    end

    return nil

end

--------------------------------------------------------------------
-- COORDINATE CONVERSION
--------------------------------------------------------------------

local coordinateErrorLogged = false

local function screenToWorld(z)
    if not ISCoordConversion
        or type(ISCoordConversion.ToWorld) ~= "function"
    then
        if not coordinateErrorLogged then
            coordinateErrorLogged = true
            log("ISCoordConversion.ToWorld is unavailable; preview paused.")
        end

        return nil, nil
    end

    local ok, worldX, worldY = pcall(
        ISCoordConversion.ToWorld,
        getMouseXScaled(),
        getMouseYScaled(),
        math.floor(z)
    )

    if not ok then
        if not coordinateErrorLogged then
            coordinateErrorLogged = true
            log("ISCoordConversion.ToWorld failed: " .. tostring(worldX))
        end

        return nil, nil
    end

    coordinateErrorLogged = false
    return worldX, worldY
end

--------------------------------------------------------------------
-- CLAIM RECTANGLE
--
-- Mirrors server/KIPN_PropertyClaimService.lua's getExcavationTargetRect()
-- centering math exactly, so the preview matches what the server
-- will actually compute from the same anchor tile.
--------------------------------------------------------------------

local function computeRect(anchorX, anchorY, width, height)

    local halfWidth =
        math.floor(width / 2)

    local halfHeight =
        math.floor(height / 2)

    return {

        x1 = anchorX - halfWidth,

        y1 = anchorY - halfHeight,

        x2 = anchorX - halfWidth + width - 1,

        y2 = anchorY - halfHeight + height - 1,

    }

end

--------------------------------------------------------------------
-- LAND VALIDITY
--
-- Mirrors server/KIPN_PropertyClaimService.lua's isSquareValidExcavationLand()
-- exactly: not part of a building, not water. This is a best-effort
-- client-side preview only -- the server independently re-validates
-- every square authoritatively when the claim is actually submitted
-- (see handleClaimExcavationCommand).
--
-- IMPORTANT: do NOT add an isSolid() check here. square:isSolid()
-- is true for any square with a solid object on it -- trees,
-- bushes, rocks, fences -- which covers most outdoor terrain and
-- would block placement almost everywhere the server would actually
-- allow it.
--------------------------------------------------------------------

local function isSquareWater(square)

    if not square then
        return false
    end

    local floor =
        type(square.getFloor) == "function"
        and square:getFloor()
        or nil

    if floor
        and type(floor.getSprite) == "function"
    then

        local sprite =
            floor:getSprite()

        local properties =
            sprite
            and type(sprite.getProperties) == "function"
            and sprite:getProperties()
            or nil

        if properties
            and type(properties.has) == "function"
            and properties:has(IsoFlagType.water)
        then
            return true
        end

    end

    -- Some water tiles/objects expose the water flag on an object
    -- sprite rather than only on the square's floor sprite.
    local objects =
        type(square.getObjects) == "function"
        and square:getObjects()
        or nil

    if objects then

        for i = 0, objects:size() - 1 do

            local object =
                objects:get(i)

            local sprite =
                object
                and type(object.getSprite) == "function"
                and object:getSprite()
                or nil

            local properties =
                sprite
                and type(sprite.getProperties) == "function"
                and sprite:getProperties()
                or nil

            if properties
                and type(properties.has) == "function"
                and (
                    properties:has(IsoFlagType.water)
                    or properties:has(IsoFlagType.taintedWater)
                )
            then
                return true
            end

        end

    end

    return false

end

local function isSquareValidForExcavation(square)

    if not square then
        return false,
            "square_unavailable"
    end

    local okOutside,
        outside =
        pcall(
            function()
                return square:isOutside()
            end
        )

    if not okOutside
        or outside ~= true
    then
        return false,
            "indoors"
    end

    local okWater,
        water =
        pcall(
            isSquareWater,
            square
        )

    if okWater
        and water == true
    then
        return false,
            "water"
    end

    return true,
        nil

end

local function isRectValidForExcavation(rect, z)

    for scanX = rect.x1, rect.x2 do

        for scanY = rect.y1, rect.y2 do

            local square =
                getCell():getGridSquare(
                    scanX,
                    scanY,
                    z
                )

            local valid,
                reason =
                isSquareValidForExcavation(
                    square
                )

            if not valid then

                return false,
                    reason,
                    scanX,
                    scanY

            end

        end

    end

    return true,
        nil,
        nil,
        nil

end

local function refreshHoverSquare(overlay)
    if not overlay or not overlay.player then
        return
    end

    local z = math.floor(overlay.player:getZ())
    local worldX, worldY = screenToWorld(z)

    if not worldX or not worldY then
        overlay.hoverSquare = nil
        overlay.rectValid = false
        overlay.rectInvalidReason = "coordinate_conversion_unavailable"
        overlay.rectInvalidX = nil
        overlay.rectInvalidY = nil
        return
    end

    local hoverSquare = getCell():getGridSquare(
        math.floor(worldX),
        math.floor(worldY),
        z
    )

    if hoverSquare == overlay.hoverSquare then
        return
    end

    overlay.hoverSquare = hoverSquare

    if not hoverSquare then
        overlay.rectValid = false
        overlay.rectInvalidReason = "square_unavailable"
        overlay.rectInvalidX = nil
        overlay.rectInvalidY = nil
        return
    end

    local rect = computeRect(
        hoverSquare:getX(),
        hoverSquare:getY(),
        overlay.tierWidth,
        overlay.tierHeight
    )

    overlay.rectValid,
        overlay.rectInvalidReason,
        overlay.rectInvalidX,
        overlay.rectInvalidY =
        isRectValidForExcavation(rect, hoverSquare:getZ())
end

--------------------------------------------------------------------
-- ACTIVATE / DEACTIVATE
--------------------------------------------------------------------

local function openPlacementOverlay(
    player,
    sizeClass,
    tierData
)

    if not player
        or not tierData
    then
        log("openPlacementOverlay() rejected missing player or tier data.")
        finishMetaRun("missing_tier_data")
        return false
    end

    local tierWidth =
        tonumber(tierData.widthTiles)

    local tierHeight =
        tonumber(tierData.heightTiles)

    if not tierWidth
        or not tierHeight
        or tierWidth <= 0
        or tierHeight <= 0
    then

        if player.Say then
            player:Say(
                "Failed to resolve excavation size tier dimensions."
            )
        end

        log("openPlacementOverlay() rejected invalid tier dimensions.")
        finishMetaRun("invalid_tier_dimensions")
        return false
    end

    tierWidth =
        math.floor(tierWidth)

    tierHeight =
        math.floor(tierHeight)

    if instance then
        KIPN_ExcavationPlacementOverlay.Deactivate("replaced")
    end

    local overlay =
        KIPN_ExcavationPlacementOverlay:new(
            0,
            0,
            getCore():getScreenWidth(),
            getCore():getScreenHeight(),
            player,
            tierWidth,
            tierHeight
        )

    overlay:initialise()
    overlay.tierLabel =
        tierData.label
        or tostring(sizeClass)

    overlay.sizeClass =
        sizeClass

    overlay:addToUIManager()
    overlay:setAlwaysOnTop(true)

    instance = overlay

    log(
        "Placement activated | class=" ..
        tostring(sizeClass) ..
        " | dimensions=" ..
        tostring(tierWidth) ..
        "x" ..
        tostring(tierHeight)
    )

    if player.Say then

        player:Say(
            "Placement mode: left-click to claim this location, "
            .. "ESC or right-click to cancel."
        )
    end

    return true

end

function KIPN_ExcavationPlacementOverlay.Activate(
    player,
    sizeClass
)

    if instance then
        KIPN_ExcavationPlacementOverlay.Deactivate("replaced_by_new_activation")
    elseif metaRunLog then
        finishMetaRun("restarted_before_open")
    end

    beginMetaRun(sizeClass)

    if not player then
        log("Activate() rejected missing player.")
        finishMetaRun("missing_player")
        return
    end

    local normalizedClass =
        normalizeSizeClass(sizeClass)

    if not normalizedClass then

        if player.Say then
            player:Say(
                "This Excavation Permit has an invalid size class."
            )
        end

        log("Activate() rejected invalid size class=" .. tostring(sizeClass))
        finishMetaRun("invalid_size_class")
        return
    end

    if not KIPN.Shared
        or not KIPN.Shared.Commands
        or not KIPN.Shared.Commands.GET_EXCAVATION_SIZE_TIERS
    then

        if player.Say then
            player:Say(
                "Excavation size configuration is unavailable."
            )
        end

        log(
            "Activate() FAILED: GET_EXCAVATION_SIZE_TIERS command unavailable."
        )

        finishMetaRun("tier_command_unavailable")
        return
    end

    local cachedTier =
        findTierByClass(
            cachedExcavationTiers,
            normalizedClass
        )

    if cachedTier then

        log(
            "Using cached tier dimensions | class=" ..
            tostring(normalizedClass)
        )

        openPlacementOverlay(
            player,
            normalizedClass,
            cachedTier
        )

        return

    end

    pendingActivationPlayer =
        player

    pendingActivationSizeClass =
        normalizedClass

    log(
        "Requesting current tier dimensions | class=" ..
        tostring(normalizedClass)
    )

    sendClientCommand(
        "KIPN",
        KIPN.Shared.Commands.GET_EXCAVATION_SIZE_TIERS,
        {}
    )

end

function KIPN_ExcavationPlacementOverlay.Deactivate(reason)

    local outcome = reason or "closed"

    if not instance then
        finishMetaRun(outcome)
        return
    end

    local oldInstance =
        instance

    instance =
        nil

    oldInstance.hoverSquare =
        nil

    oldInstance.rectValid =
        false

    oldInstance.rectInvalidReason =
        nil

    oldInstance.rectInvalidX =
        nil

    oldInstance.rectInvalidY =
        nil

    oldInstance:removeFromUIManager()

    log("Placement deactivated | reason=" .. tostring(outcome))
    finishMetaRun(outcome)

end

--------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------

function KIPN_ExcavationPlacementOverlay:initialise()

    ISPanel.initialise(self)

    self.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    self.moveWithMouse = false

    self:setWantKeyEvents(true)

end

--------------------------------------------------------------------
-- AUTO-CANCEL
--
-- Placement mode is a precise, deliberate action (lining up a
-- purchased claim rectangle against the world) -- sprinting, aiming
-- a weapon, or opening the world map all mean the player's attention
-- and mouse/camera control has moved elsewhere, so the pending
-- selection is dropped rather than left active (and potentially
-- submitted against whatever happens to be under the mouse once
-- they return). Escape and right-click already cancel explicitly
-- (see onKeyPress()/onRightMouseDown() below) -- this covers the
-- cases that don't go through either of those.
--------------------------------------------------------------------

function KIPN_ExcavationPlacementOverlay:update()

    ISPanel.update(self)

    if not self.player then
        return
    end

    local shouldCancel =
        false

    local cancelReason =
        nil

    if self.player.isSprinting
        and self.player:isSprinting()
    then

        shouldCancel = true
        cancelReason = "sprinting"

    elseif self.player.isAiming
        and self.player:isAiming()
    then

        shouldCancel = true
        cancelReason = "aiming"

    elseif _G.ISWorldMap_instance
        and _G.ISWorldMap_instance.getIsVisible
        and _G.ISWorldMap_instance:getIsVisible()
    then

        shouldCancel = true
        cancelReason = "the map was opened"

    elseif type(getPlayerInventory) == "function"
        and getPlayerInventory(self.playerNum)
        and getPlayerInventory(self.playerNum):getIsVisible()
        and not getPlayerInventory(self.playerNum).isCollapsed
    then

        shouldCancel = true
        cancelReason = "the inventory was opened"

    elseif type(getPlayerLoot) == "function"
        and getPlayerLoot(self.playerNum)
        and getPlayerLoot(self.playerNum):getIsVisible()
        and not getPlayerLoot(self.playerNum).isCollapsed
    then

        shouldCancel = true
        cancelReason = "a container was opened"

    end

    if shouldCancel then

        if self.player.Say then

            self.player:Say(
                "Excavation placement cancelled -- "
                .. cancelReason
                .. "."
            )
        end

        KIPN_ExcavationPlacementOverlay.Deactivate(
            "auto_cancel_" .. tostring(cancelReason)
        )

        return

    end

    -- Refreshing here makes the preview appear immediately and keeps it
    -- accurate while the camera moves, even if the mouse itself is still.
    refreshHoverSquare(self)

end

function KIPN_ExcavationPlacementOverlay:new(
    x,
    y,
    width,
    height,
    player,
    tierWidth,
    tierHeight
)

    local o =
        ISPanel:new(x, y, width, height)

    setmetatable(o, self)
    self.__index = self

    o.player = player
    o.playerNum = player:getPlayerNum()
    o.tierWidth = tierWidth
    o.tierHeight = tierHeight
    o.hoverSquare = nil
    o.rectValid = false
    o.rectInvalidReason = nil
    o.rectInvalidX = nil
    o.rectInvalidY = nil
    o.highlightStarted = false

    return o

end

--------------------------------------------------------------------
-- MOUSE
--------------------------------------------------------------------

function KIPN_ExcavationPlacementOverlay:onMouseMove(_dx, _dy)

    refreshHoverSquare(self)

    return true

end

function KIPN_ExcavationPlacementOverlay:onMouseDown(_x, _y)

    if not self.hoverSquare then
        return true
    end

    if not self.rectValid then

        local reason =
            self.rectInvalidReason
            or "invalid"

        if self.player and self.player.Say then

            local message =
                "That excavation area is not valid."

            if reason == "indoors" then
                message =
                    "That excavation area contains an indoor tile."
            elseif reason == "water" then
                message =
                    "That excavation area contains water."
            elseif reason == "square_unavailable" then
                message =
                    "That excavation area contains an unavailable tile."
            end

            self.player:Say(message)

        end

        log(
            "Placement rejected client-side | reason=" ..
            tostring(reason) ..
            " | x=" ..
            tostring(self.rectInvalidX) ..
            " | y=" ..
            tostring(self.rectInvalidY)
        )

        KIPN_ExcavationPlacementOverlay.Deactivate(
            "invalid_area_" .. tostring(reason)
        )

        return true

    end

    lastClaimPlayer =
        self.player

    lastClaimRequestStartedAtMs = nowMs()

    log(
        "Submitting proposed claim anchor | x="
        .. tostring(self.hoverSquare:getX())
        .. " | y=" .. tostring(self.hoverSquare:getY())
        .. " | z=" .. tostring(self.hoverSquare:getZ())
    )

    sendClientCommand(
        "KIPN",
        KIPN.Shared.Commands.CLAIM_EXCAVATION,
        {
            targetX = self.hoverSquare:getX(),
            targetY = self.hoverSquare:getY(),
            targetZ = self.hoverSquare:getZ(),
        }
    )

    KIPN_ExcavationPlacementOverlay.Deactivate("submitted")

    return true

end

function KIPN_ExcavationPlacementOverlay:onRightMouseDown(_x, _y)

    if self.player and self.player.Say then
        self.player:Say("Excavation placement cancelled.")
    end

    KIPN_ExcavationPlacementOverlay.Deactivate("right_click_cancel")

    return true

end

function KIPN_ExcavationPlacementOverlay:onKeyPress(key)

    if key == Keyboard.KEY_ESCAPE then

        if self.player and self.player.Say then
            self.player:Say("Excavation placement cancelled.")
        end

        KIPN_ExcavationPlacementOverlay.Deactivate("escape_cancel")

        return true
    end

    return false

end

--------------------------------------------------------------------
-- RENDER
--------------------------------------------------------------------

function KIPN_ExcavationPlacementOverlay:prerender()
    -- The world-space highlight is queued from render() below. This pass
    -- remains UI-only and intentionally draws the placement status text.
    if not self.hoverSquare then
        return
    end

    local statusText = "Left-click to claim ("

    if not self.rectValid then
        local reason = self.rectInvalidReason
        if reason == "indoors" then
            statusText = "BLOCKED -- contains an indoor tile ("
        elseif reason == "water" then
            statusText = "BLOCKED -- contains water ("
        elseif reason == "square_unavailable" then
            statusText = "BLOCKED -- tile unavailable ("
        else
            statusText = "BLOCKED -- invalid area ("
        end
    end

    self:drawText(
        statusText
            .. (self.tierLabel or tostring(self.tierWidth) .. " x " .. tostring(self.tierHeight))
            .. ") -- ESC/right-click to cancel",
        20, 20, 1, 1, 1, 1, UIFont.Small
    )
end

local highlightErrorLogged = false

function KIPN_ExcavationPlacementOverlay:render()
    if not self.hoverSquare then
        return
    end

    local rect = computeRect(
        self.hoverSquare:getX(),
        self.hoverSquare:getY(),
        self.tierWidth,
        self.tierHeight
    )

    if type(addAreaHighlightForPlayer) ~= "function" then
        if not highlightErrorLogged then
            highlightErrorLogged = true
            log("addAreaHighlightForPlayer is unavailable; preview cannot render.")
        end

        return
    end

    local r, g, b, a = 0.20, 0.48, 1.00, 0.38
    if not self.rectValid then
        r, g, b, a = 1.00, 0.12, 0.12, 0.46
    end

    local ok, renderError = pcall(
        addAreaHighlightForPlayer,
        self.playerNum,
        rect.x1,
        rect.y1,
        rect.x2 + 1,
        rect.y2 + 1,
        math.floor(self.hoverSquare:getZ()),
        r,
        g,
        b,
        a
    )

    if not ok then
        if not highlightErrorLogged then
            highlightErrorLogged = true
            log("Area-highlight render failed: " .. tostring(renderError))
        end

        return
    end

    highlightErrorLogged = false

    if not self.highlightStarted then
        self.highlightStarted = true
        log(
            "Area highlight active | player=" .. tostring(self.playerNum)
            .. " | z=" .. tostring(math.floor(self.hoverSquare:getZ()))
        )
    end
end

--------------------------------------------------------------------
-- MOUSE PASSTHROUGH
--
-- This overlay is a full-screen capture surface -- it must not let
-- clicks fall through to whatever is behind it while active.
--------------------------------------------------------------------

function KIPN_ExcavationPlacementOverlay:onMouseUp(_x, _y)
    return true
end

--------------------------------------------------------------------
-- SERVER RESPONSE
--
-- The submitted claim above is fire-and-forget from onMouseDown's
-- point of view. The server independently re-validates everything
-- (see handleClaimExcavationCommand) and can still reject it even
-- when this client-side preview showed the area as valid (already
-- claimed a moment ago, quota reached, artifact invalid, restricted
-- zone, etc), so the result is reported to the player here.
--------------------------------------------------------------------

local function onServerResponse(module, command, args)

    if module ~= "KIPN" then
        return
    end

    if not KIPN.Shared
        or not KIPN.Shared.Commands
        or command ~= KIPN.Shared.Commands.SERVER_RESPONSE
    then
        return
    end

    local event =
        args and args.event

    ------------------------------------------------------------
    -- CURRENT ADMIN-ASSIGNED EXCAVATION DIMENSIONS
    ------------------------------------------------------------

    if event ==
        KIPN.Shared.ResponseEvents.EXCAVATION_SIZE_TIERS_DATA
    then

        local data =
            args and args.data

        if data
            and type(data.tiers) == "table"
        then
            cachedExcavationTiers =
                data.tiers

            log(
                "Received authoritative tier data | count="
                .. tostring(#data.tiers)
            )
        end

        if not pendingActivationPlayer
            or not pendingActivationSizeClass
        then
            return
        end

        local player =
            pendingActivationPlayer

        local sizeClass =
            pendingActivationSizeClass

        pendingActivationPlayer =
            nil

        pendingActivationSizeClass =
            nil

        local tierData =
            findTierByClass(
                data and data.tiers,
                sizeClass
            )

        if not tierData then

            log(
                "Tier response FAILED to resolve class=" ..
                tostring(sizeClass)
            )

            if player.Say then
                player:Say(
                    "Failed to resolve excavation size tier dimensions."
                )
            end

            finishMetaRun("tier_not_found")
            return
        end

        openPlacementOverlay(
            player,
            sizeClass,
            tierData
        )

        return
    end

    ------------------------------------------------------------
    -- TIER LOOKUP ERROR
    ------------------------------------------------------------

    if event == KIPN.Shared.ResponseEvents.ERROR
        and pendingActivationPlayer
        and args
        and args.data
        and args.data.command ==
            KIPN.Shared.Commands.GET_EXCAVATION_SIZE_TIERS
    then

        local player =
            pendingActivationPlayer

        pendingActivationPlayer =
            nil

        pendingActivationSizeClass =
            nil

        log(
            "Server rejected excavation tier lookup | reason=" ..
            tostring(args.data.reason or "unknown")
        )

        if player.Say then
            player:Say(
                "Unable to load excavation size configuration."
            )
        end

        finishMetaRun("tier_lookup_rejected")
        return
    end

    ------------------------------------------------------------
    -- OWNERSHIP CLAIM RESPONSE
    ------------------------------------------------------------

    if event ==
        KIPN.Shared.ResponseEvents.EXCAVATION_CLAIM_SUCCESSFUL
    then

        log("Server accepted excavation claim.")
        logClaimRoundTrip("accepted")

        if lastClaimPlayer and lastClaimPlayer.Say then
            lastClaimPlayer:Say(
                "Land claim successful."
            )
        end

        lastClaimPlayer =
            nil

    elseif event == KIPN.Shared.ResponseEvents.ERROR
        and args
        and args.data
        and args.data.command ==
            KIPN.Shared.Commands.CLAIM_EXCAVATION
    then

        local reason = args.data.reason or "unknown reason"

        log("Server rejected excavation claim | reason=" .. tostring(reason))
        logClaimRoundTrip("rejected", reason)

        if lastClaimPlayer and lastClaimPlayer.Say then
            lastClaimPlayer:Say(
                "Land claim failed: "
                .. tostring(reason)
            )
        end

        lastClaimPlayer =
            nil

    end

end

if Events.OnServerCommand then

    Events.OnServerCommand.Add(onServerResponse)

end

print("[KIPN] Excavation Placement Overlay client loaded")
