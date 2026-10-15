require "ISUI/ISPanel"
require "ISUI/ISInventoryItem"
require "ISUI/ISInventoryPage"
require "SVSBT_Client"

local Client = SVSBT.Client
local Shared = SVSBT.Shared
local Config = SVSBT.Config
local Logger = SVSBT.Logger

SVSBTTrapOverlay = ISPanel:derive("SVSBTTrapOverlay")
SVSBTTrapOverlay.Instance = SVSBTTrapOverlay.Instance or nil

function SVSBTTrapOverlay:initialise()
    local run = Logger.Begin("SVSBTTrapOverlay.initialise")
    ISPanel.initialise(self)
    self:noBackground()

    if self.javaObject and type(self.javaObject.setConsumeMouseEvents) == "function" then
        self.javaObject:setConsumeMouseEvents(false)
    end

    Logger.Finish(run, true)
end

-- Keep declining handlers as a precaution. The zero-sized Java bounds below
-- are essential: Lua isMouseOver/false handlers do not bypass UIElement's
-- top-level isPointOver occlusion checks.
function SVSBTTrapOverlay:onMouseDown() return false end
function SVSBTTrapOverlay:onMouseUp() return false end
function SVSBTTrapOverlay:onMouseDownOutside() return false end
function SVSBTTrapOverlay:onMouseUpOutside() return false end
function SVSBTTrapOverlay:onRightMouseDown() return false end
function SVSBTTrapOverlay:onRightMouseUp() return false end
function SVSBTTrapOverlay:onRightMouseDownOutside() return false end
function SVSBTTrapOverlay:onRightMouseUpOutside() return false end
function SVSBTTrapOverlay:onMouseMove() return false end
function SVSBTTrapOverlay:onMouseMoveOutside() return false end
function SVSBTTrapOverlay:onMouseWheel() return false end
function SVSBTTrapOverlay:isMouseOver() return false end

function SVSBTTrapOverlay:prerender()
    -- Transparent overlay: drawing occurs in render only.
end

-- Resolves whose eyes a UI element is drawing for. Vanilla inventory
-- panes/pages carry a player index in .player (ISInventoryPage.lua) and some
-- panels an IsoPlayer in .chr, so walk a short parent chain for either before
-- falling back to player one -- split-screen player two must be gated on
-- their OWN magazine reading, not player one's.
local function uiPlayer(element)
    local ok, found = pcall(function()
        local node = element

        for _ = 1, 4 do
            if node == nil then break end
            if node.chr ~= nil then return node.chr end
            if type(node.player) == "number" then return getSpecificPlayer(node.player) end
            if node.player ~= nil then return node.player end
            node = node.parent
        end

        return nil
    end)

    if ok and found then return found end
    return getSpecificPlayer(0) or getPlayer()
end

local function canRender(player, record)
    local run = Logger.Begin("SVSBTTrapOverlay.canRender", record.trapId)
    local result = player ~= nil

    if result and Config.Get("VisibleIndicatorsCurrentFloorOnly") then
        result = math.floor(player:getZ()) == math.floor(tonumber(record.z) or -99)
    end

    local square = result and getCell():getGridSquare(math.floor(record.x), math.floor(record.y), math.floor(record.z)) or nil

    if result and Config.Get("VisibleIndicatorsRequireLOS") then
        result = square ~= nil and square:isCanSee(player:getPlayerNum())
    end

    Logger.Finish(run, true, "visible=" .. tostring(result))
    return result
end

local biologicalMistFrames = {}

-- Vanilla smoke sprites from the base game's Tiles1x.pack (the same 4-frame
-- "Smoke_01_0".."Smoke_01_3" animation vanilla fire uses), loaded by bare
-- name and tinted with the same drawTextureScaled color-multiply every
-- other overlay in this file uses.
local function biologicalMistTexture(frameIndex)
    local texture = biologicalMistFrames[frameIndex]

    if texture == nil then
        texture = getTexture("Smoke_01_" .. tostring(frameIndex)) or false
        biologicalMistFrames[frameIndex] = texture
    end

    return texture or nil
end

-- Projects the on-screen width/height of one tile at the current camera
-- zoom by measuring real iso-to-screen deltas rather than assuming a fixed
-- pixel size -- isoToScreenX/Y already account for zoom, so two projected
-- points a known tile-step apart give an exact, zoom-correct span.
local function tileScreenSpan(playerNum, tx, ty, tz)
    local x0 = isoToScreenX(playerNum, tx + 0.5, ty + 0.5, tz)
    local y0 = isoToScreenY(playerNum, tx + 0.5, ty + 0.5, tz)
    local x1 = isoToScreenX(playerNum, tx + 1.5, ty - 0.5, tz)
    local y1 = isoToScreenY(playerNum, tx + 1.5, ty + 1.5, tz)
    return math.abs(x1 - x0), math.abs(y1 - y0)
end

-- The live sample's real warning: a green haze over every tile it can
-- actually gas, matching the exact circular radius Service.processBiological
-- Agent uses to decide who gets exposed, not a floating icon on the jar
-- itself. Drawn only while genuinely Armed -- a placed-but-unopened or
-- already-spent sample gives no visual tell at all.
local function drawBiologicalMist(panel, player, record)
    local radius = tonumber(record.radius) or 0
    if radius <= 0 then return 0 end

    local playerNum = player:getPlayerNum()
    local baseX, baseY, baseZ = math.floor(record.x), math.floor(record.y), math.floor(record.z)
    local tileW, tileH = tileScreenSpan(playerNum, baseX, baseY, baseZ)
    if tileW <= 0 or tileH <= 0 then return 0 end

    local ms = type(getTimestampMs) == "function" and getTimestampMs() or 0
    local span = math.ceil(radius)
    local drawn = 0

    for dx = -span, span do
        for dy = -span, span do
            local tx, ty = baseX + dx, baseY + dy
            local distance = Shared.Distance(tx + 0.5, ty + 0.5, record.x + 0.5, record.y + 0.5)

            if distance <= radius then
                -- Desync each tile's frame off its own position so the whole
                -- cloud doesn't pulse in lockstep like one giant sprite.
                local frame = math.floor((ms / 220) + (tx * 2) + (ty * 3)) % 4
                local mist = biologicalMistTexture(frame)

                if mist then
                    local sx = isoToScreenX(playerNum, tx + 0.5, ty + 0.5, baseZ)
                    local sy = isoToScreenY(playerNum, tx + 0.5, ty + 0.5, baseZ)
                    local w, h = tileW * 1.9, tileH * 3.4
                    panel:drawTextureScaled(mist, sx - (w / 2), sy - (h * 0.62), w, h,
                        0.22, 0.85, 0.32, 0.42)
                    drawn = drawn + 1
                end
            end
        end
    end

    return drawn
end

function SVSBTTrapOverlay:render()
    local run = Logger.Begin("SVSBTTrapOverlay.render")
    local player = getSpecificPlayer(0) or getPlayer()

    if not player then
        Logger.Finish(run, true, "no player")
        return
    end

    local scale = Config.Get("FloorTrapIconScale")
    local indicator = self.indicatorTexture or getTexture("media/textures/SVSBT_TrapIndicator.png")
    local tripWire = self.tripWireTexture or getTexture("media/textures/Item_SVSBT_Tripwire.png")
    self.indicatorTexture = indicator
    self.tripWireTexture = tripWire
    local drawn = 0

    for _, record in ipairs(Client.Visible or {}) do
        if canRender(player, record) then
            local sx = isoToScreenX(player:getPlayerNum(), record.x + 0.5, record.y + 0.5, record.z)
            local sy = isoToScreenY(player:getPlayerNum(), record.x + 0.5, record.y + 0.5, record.z)

            -- Water bucket, shotgun, nail board, bear trap: all real floor
            -- traps now, each a real world item sitting on the ground --
            -- the engine already renders the item's own sprite natively, no
            -- custom draw needed here at all. Only the trip wire (no real
            -- world item, just two virtual stakes) and the admin overlay
            -- below need anything drawn.
            if record.kind == Shared.Kind.TripWire and tripWire and record.x2 ~= nil and record.y2 ~= nil
                and Config.Get("TripWireVisible") then
                -- The mod's own trip wire art, drawn once at the midpoint
                -- between the two stakes -- not a generic rope/danger icon,
                -- and not duplicated at each end.
                local midX = (record.x + record.x2) / 2 + 0.5
                local midY = (record.y + record.y2) / 2 + 0.5
                local mx = isoToScreenX(player:getPlayerNum(), midX, midY, record.z)
                local my = isoToScreenY(player:getPlayerNum(), midX, midY, record.z)
                -- Exactly 32x32 screen pixels, always. Not scaled by the
                -- camera (drawTextureScaled is screen space, so only the
                -- midpoint above moves with the view) and not by
                -- FloorTrapIconScale either -- zooming must never change how
                -- big this sprite is.
                self:drawTextureScaled(tripWire, mx - 16, my - 16, 32, 32, 1, 1, 1, 1)
                drawn = drawn + 1
            elseif Shared.VehicleKinds[record.kind] then
                -- Vehicle devices are never shown as a world icon; the
                -- warning belongs only in the Vehicle Mechanics menu
                -- (SVSBT_MechanicsUI), which already draws it there.
            elseif record.kind == Shared.Kind.BiologicalSample then
                -- No floating warning icon, admin or not -- the green mist
                -- over every tile it can actually gas (drawn only once truly
                -- Armed) is the entire warning for this trap.
                if record.state == Shared.State.Armed and not record.armPending then
                    drawn = drawn + drawBiologicalMist(self, player, record)
                end
            elseif record.admin and indicator and record.kind ~= Shared.Kind.ExplosiveMailbox
                and Shared.ShowsWarningIndicator(player, record.kind) then
                self:drawTextureScaled(indicator, sx - 12 * scale, sy - (42 * scale),
                    24 * scale, 24 * scale, 0.92, 0.55, 0.25, 1.0)
                drawn = drawn + 1
            end
            -- No large world-space danger icon for a rigged mailbox, admin or
            -- not -- the tell lives on the mailbox's own icon in the world
            -- inventory UI instead (patchWorldContainerIcon below), the same
            -- small, in-context way contaminated literature is marked.
        end
    end

    Logger.Finish(run, true, "drawn=" .. tostring(drawn))
end

function SVSBTTrapOverlay:new()
    local run = Logger.Begin("SVSBTTrapOverlay.new")
    -- UIManager tests Java isPointOver before dispatching wheel input. A
    -- full-screen top-level panel makes lower panels fail that test, even
    -- with consumeMouseEvents=false and onMouseWheel returning false.
    -- Zero bounds never hit the mouse. UIElement still calls render(), and
    -- our unclipped, parentless panel draws indicators in screen coordinates.
    local overlay = ISPanel.new(self, 0, 0, 0, 0)
    overlay.moveWithMouse = false
    overlay.wantMouseEvents = false
    Logger.Finish(run, true)
    return overlay
end

local function createOverlay()
    local run = Logger.Begin("SVSBT_Render.createOverlay")

    if SVSBTTrapOverlay.Instance then
        SVSBTTrapOverlay.Instance:setWidth(0)
        SVSBTTrapOverlay.Instance:setHeight(0)
        Logger.Finish(run, true, "existing")
        return SVSBTTrapOverlay.Instance
    end

    local overlay = SVSBTTrapOverlay:new()
    overlay:initialise()
    overlay:addToUIManager()
    SVSBTTrapOverlay.Instance = overlay
    Logger.Finish(run, true, "created")
    return overlay
end

if Events and Events.OnGameStart then Events.OnGameStart.Add(createOverlay) end

-- ISInventoryItem.renderItemIcon is the single draw point every item icon
-- goes through (inventory list rows, tooltips, loot windows), so wrapping
-- it once marks a contaminated document/magazine everywhere its icon
-- appears.
--
-- ISInventoryPane draws the read/equipped/broken/frozen/poison/favorite
-- icons in the bottom-left corner after renderItemIcon returns, so the
-- warning goes in the top-right corner at full opacity with no tint, the
-- same way vanilla draws its overlay icons.
local function patchItemIcon()
    local run = Logger.Begin("SVSBT_Render.patchItemIcon")

    if not ISInventoryItem or ISInventoryItem.SVSBT_OriginalRenderItemIcon then
        Logger.Finish(run, true, "already patched or unavailable")
        return false
    end

    ISInventoryItem.SVSBT_OriginalRenderItemIcon = ISInventoryItem.renderItemIcon

    function ISInventoryItem.renderItemIcon(self, item, x, y, alpha, w, h)
        local result = ISInventoryItem.SVSBT_OriginalRenderItemIcon(self, item, x, y, alpha, w, h)
        local ok, contaminated = pcall(function()
            return item and type(item.getModData) == "function" and item:getModData().SVSBT_Contaminated == true
        end)

        if not ok then
            Logger.Error("SVSBT_Render.renderItemIcon", "contamination check crashed: " .. tostring(contaminated))
            return result
        end

        if contaminated then
            -- Spotting a doctored document is knowledge out of MAD Magazine
            -- No. 5 -- anyone who never read it just sees an ordinary sheet
            -- of paper and finds out the hard way.
            local viewer = uiPlayer(self)
            local shows = Shared.ShowsWarningIndicator(viewer, Shared.Kind.AnthraxDocument)

            if shows and type(self.drawTextureScaled) == "function" then
                local warning = SVSBTTrapOverlay.Instance and SVSBTTrapOverlay.Instance.indicatorTexture
                    or getTexture("media/textures/SVSBT_TrapIndicator.png")
                local size = math.max(8, math.min(16, (tonumber(w) or tonumber(h) or 32) * 0.4))
                local px = (tonumber(x) or 0) + (tonumber(w) or size) - size
                local py = tonumber(y) or 0
                self:drawTextureScaled(warning, px, py, size, size, 1, 1, 1, 1)
            end
        end

        return result
    end

    Logger.Finish(run, true, "patched")
    return true
end

if Events and Events.OnGameStart then Events.OnGameStart.Add(patchItemIcon) end

-- Whichever container a rigged explosive parcel is hiding in gets a small
-- warning drawn ON ITS OWN TAB ICON in the inventory panel's container list
-- (ContainerButtonIcons in ISInventoryPage.lua) instead
-- of a large world-space danger icon -- the same "in-context, not in-world"
-- treatment as the contaminated literature overlay above.
local function containerHousesRiggedParcel(container)
    if not container or type(container.getParent) ~= "function" then return false end
    local parent = container:getParent()
    if not parent or not Shared.IsMailbox(parent) or type(parent.getSquare) ~= "function" then return false end
    local square = parent:getSquare()
    if not square then return false end
    -- The exact tile this specific container sits on -- not a 1.5-tile
    -- radius, which lit up every OTHER mailbox/trash can nearby too,
    -- armed or not, real or not.
    local px, py, pz = math.floor(square:getX()), math.floor(square:getY()), math.floor(square:getZ())

    for _, record in ipairs(Client.Visible or {}) do
        if record.kind == Shared.Kind.ExplosiveMailbox and record.state == "armed"
            and math.floor(tonumber(record.z) or -99) == pz
            and math.floor(tonumber(record.x) or -99) == px
            and math.floor(tonumber(record.y) or -99) == py then
            return true
        end
    end

    for _, record in pairs(Client.KnownTraps or {}) do
        if record.kind == Shared.Kind.ExplosiveMailbox and record.state == "armed"
            and math.floor(tonumber(record.z) or -99) == pz
            and math.floor(tonumber(record.x) or -99) == px
            and math.floor(tonumber(record.y) or -99) == py then
            return true
        end
    end

    return false
end

local function patchWorldContainerIcon()
    local run = Logger.Begin("SVSBT_Render.patchWorldContainerIcon")

    if not ISInventoryPage or ISInventoryPage.SVSBT_OriginalAddContainerButton then
        Logger.Finish(run, true, "already patched or unavailable")
        return false
    end

    ISInventoryPage.SVSBT_OriginalAddContainerButton = ISInventoryPage.addContainerButton

    -- ISInventoryPage pools and reuses these button objects across
    -- different containers (self.buttonPool), so the warning can't be
    -- decided once per button. Wrap render EXACTLY ONCE per button object
    -- and re-check the CURRENT container on every draw via
    -- button.inventory, which vanilla updates on every reuse.
    function ISInventoryPage:addContainerButton(container, texture, name, tooltip)
        local button = ISInventoryPage.SVSBT_OriginalAddContainerButton(self, container, texture, name, tooltip)

        if button and type(button.render) == "function" and not button.SVSBT_OriginalRender then
            button.SVSBT_OriginalRender = button.render

            function button:render()
                self.SVSBT_OriginalRender(self)
                local ok, rigged = pcall(containerHousesRiggedParcel, self.inventory)
                -- Recognizing a rigged parcel takes MAD Magazine No. 4; to
                -- everyone else the mailbox tab looks like any other.
                local shows = ok and rigged
                    and Shared.ShowsWarningIndicator(uiPlayer(self), Shared.Kind.ExplosiveMailbox)

                if shows then
                    local ok2 = pcall(function()
                        local warning = SVSBTTrapOverlay.Instance and SVSBTTrapOverlay.Instance.indicatorTexture
                            or getTexture("media/textures/SVSBT_TrapIndicator.png")
                        local size = math.max(6, math.min(12, self.width * 0.35))
                        self:drawTextureScaled(warning, self.width - size, self.height - size,
                            size, size, 1, 1, 1, 1)
                    end)
                    if not ok2 then
                        Logger.Error("SVSBT_Render.containerButton.render", "overlay draw failed")
                    end
                end
            end
        end

        return button
    end

    Logger.Finish(run, true, "patched")
    return true
end

if Events and Events.OnGameStart then Events.OnGameStart.Add(patchWorldContainerIcon) end

Logger.Info("SVSBT_Render.load", "visible-trap and door-rope overlay initialized")

return SVSBTTrapOverlay
