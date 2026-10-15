-- KIPN_ZoneAdminUI.lua
--
-- In-game admin tool for defining KIPN world zones (Government
-- Building / Car Dealership / Custom).
--
-- WHY THIS EXISTS INSTEAD OF A SANDBOX-SETTINGS MAP OVERLAY:
-- Project Zomboid's Sandbox Settings screen only renders scalar
-- widgets (checkboxes, sliders, dropdowns, text fields) — it has
-- no canvas/map rendering hook, so a clickable map can't live
-- inside that screen. This panel is a normal in-game UI instead.
--
-- WORKFLOW:
--   1. Admin opens this panel (see trigger in
--      KIPN_ZoneAdminTrigger.lua).
--   2. Admin sets Corner A / Corner B either by:
--        a) Clicking "Draw on Map", which opens a full-screen map
--           overlay (KIPN_ZoneAdminMapUI.lua) backed by the game's
--           own world map renderer -- click once per corner, drag
--           to pan, scroll to zoom, exactly like the vanilla map.
--        b) Walking to each corner in the world and clicking
--           "Mark Here" for that corner.
--   3. Admin picks a zone type from the dropdown.
--   4. Admin clicks "Create Zone", which sends the request to the
--      server for validation + persistence via WorldRegistry.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISComboBox"
require "KIPN_ZoneAdminMapUI"

KIPN = KIPN or {}
KIPN.Client = KIPN.Client or {}

KIPN_ZoneAdminUI = ISPanel:derive("KIPN_ZoneAdminUI")

local MODULE_NAME = "KIPN_ZoneAdmin"

local ZONE_TYPE_OPTIONS = {
    { text = "Government Building", value = "government" },
    { text = "Car Dealership", value = "dealership" },
    { text = "Custom", value = "custom" },
    { text = "Do Not Claim Zone", value = "do_not_claim" },
}

local ZONE_TYPE_LABELS = {}
for _, option in ipairs(ZONE_TYPE_OPTIONS) do
    ZONE_TYPE_LABELS[option.value] = option.text
end

-- Mirrors WorldRegistry.CombatPolicies / CombatPolicyLabels.
-- Kept as a plain client-side list (rather than reaching into
-- server-only WorldRegistry) since this panel only needs the
-- string values to send back to the server, which validates
-- them authoritatively regardless.
--
-- The ambient default everywhere is full PvP damage -- these are
-- the only two ways to deviate from it, drawn as their own
-- independent zones. "(none / clear policy)" is only offered in
-- the existing-zone management dropdown below (to remove a policy
-- from a zone and let it fall back to the ambient default), not
-- when creating a new combat zone.
local COMBAT_POLICY_OPTIONS = {
    { text = "(none / clear policy)", value = false },
    { text = "PvE Zone (no PvP damage)", value = "PVE" },
    { text = "Melee Zone (melee only, no ranged)", value = "MELEE_PVP" },
}

------------------------------------------------------------
-- SINGLETON ACCESS
------------------------------------------------------------

function KIPN_ZoneAdminUI.Toggle()
    if KIPN_ZoneAdminUI.instance and KIPN_ZoneAdminUI.instance:getIsVisible() then
        KIPN_ZoneAdminUI.instance:removeFromUIManager()
        return
    end

    if not KIPN_ZoneAdminUI.instance then
        local screenW = getCore():getScreenWidth()
        local screenH = getCore():getScreenHeight()

        local width = 340
        local height = 560

        local panel = KIPN_ZoneAdminUI:new(
            (screenW / 2) - (width / 2),
            (screenH / 2) - (height / 2),
            width,
            height
        )

        panel:initialise()
        panel:instantiate()

        KIPN_ZoneAdminUI.instance = panel
    end

    KIPN_ZoneAdminUI.instance:addToUIManager()
    KIPN_ZoneAdminUI.instance:bringToTop()
    KIPN_ZoneAdminUI.instance:onRefreshPositionZone()
end

------------------------------------------------------------
-- CONSTRUCTION
------------------------------------------------------------

function KIPN_ZoneAdminUI:new(x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.moveWithMouse = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.85 }
    o.borderColor = { r = 1, g = 1, b = 1, a = 0.4 }

    o.cornerA = nil
    o.cornerB = nil

    -- "permission" (Government/Dealership/Custom -- what
    -- a location IS) or "combat" (PVE/Melee damage policy -- opt-in,
    -- orthogonal, and drawn as its own independent shape so it can
    -- freely overlap a permission zone). See KIPN_WorldRegistry.lua's
    -- "COMBAT POLICIES" header comment for the orthogonality this
    -- mirrors.
    o.zoneCategory = "permission"

    o.lastZones = {}
    o.positionZoneMatches = {}
    o.positionZoneId = nil

    return o
end

------------------------------------------------------------
-- CHILDREN
------------------------------------------------------------

function KIPN_ZoneAdminUI:createChildren()
    local pad = 10
    local y = pad
    local rowHeight = 30

    -- Title
    self.titleLabel = ISLabel:new(pad, y, rowHeight, "KIPN Zone Admin", 1, 1, 1, 1, UIFont.Medium, true)
    self:addChild(self.titleLabel)
    y = y + rowHeight

    -- Close button
    self.closeButton = ISButton:new(self.width - 30, 6, 20, 20, "X", self, KIPN_ZoneAdminUI.onClose)
    self:addChild(self.closeButton)

    -- Draw on map button
    self.drawOnMapButton = ISButton:new(pad, y, self.width - (pad * 2), 26, "Draw on Map", self, KIPN_ZoneAdminUI.onDrawOnMap)
    self:addChild(self.drawOnMapButton)
    y = y + 26 + 6

    -- Corner A row
    self.cornerALabel = ISLabel:new(pad, y, rowHeight, "Corner A: not set", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.cornerALabel)
    self.cornerAButton = ISButton:new(self.width - 110, y - 4, 100, 24, "Mark Here", self, KIPN_ZoneAdminUI.onMarkCornerA)
    self:addChild(self.cornerAButton)
    y = y + rowHeight

    -- Corner B row
    self.cornerBLabel = ISLabel:new(pad, y, rowHeight, "Corner B: not set", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.cornerBLabel)
    self.cornerBButton = ISButton:new(self.width - 110, y - 4, 100, 24, "Mark Here", self, KIPN_ZoneAdminUI.onMarkCornerB)
    self:addChild(self.cornerBButton)
    y = y + rowHeight + 6

    ------------------------------------------------------------
    -- ZONE CATEGORY
    --
    -- Permission zones (Government/Dealership/Custom)
    -- and Combat zones (PVE / Melee) are independent, freely-overlapping
    -- shapes -- see the "zoneCategory" comment in :new(). Each
    -- category shows only the dropdown relevant to it.
    ------------------------------------------------------------

    self.categoryLabel = ISLabel:new(pad, y, rowHeight, "New Zone Type:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.categoryLabel)
    y = y + rowHeight

    local halfW = (self.width - (pad * 2) - 6) / 2

    self.permissionCategoryButton = ISButton:new(pad, y, halfW, 24, "Permission Zone", self, KIPN_ZoneAdminUI.onCategoryChanged)
    self.permissionCategoryButton.internal = "permission"
    self:addChild(self.permissionCategoryButton)

    self.combatCategoryButton = ISButton:new(pad + halfW + 6, y, halfW, 24, "Combat Zone", self, KIPN_ZoneAdminUI.onCategoryChanged)
    self.combatCategoryButton.internal = "combat"
    self:addChild(self.combatCategoryButton)
    y = y + 24 + 6

    -- Zone type dropdown (Permission Zone category only)
    self.typeLabel = ISLabel:new(pad, y, rowHeight, "Zone Type:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.typeLabel)
    y = y + rowHeight

    self.typeCombo = ISComboBox:new(pad, y, self.width - (pad * 2), 24, self, KIPN_ZoneAdminUI.onTypeChanged)
    for _, option in ipairs(ZONE_TYPE_OPTIONS) do
        self.typeCombo:addOptionWithData(option.text, option.value)
    end
    self.typeCombo:setSelected(1)
    self:addChild(self.typeCombo)
    self.selectedZoneType = ZONE_TYPE_OPTIONS[1].value
    y = y + rowHeight + 6

    -- Combat/damage-zone policy dropdown (Combat Zone category only)
    self.policyLabel = ISLabel:new(pad, y, rowHeight, "Combat Policy:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.policyLabel)
    y = y + rowHeight

    self.policyCombo = ISComboBox:new(pad, y, self.width - (pad * 2), 24, self, KIPN_ZoneAdminUI.onPolicyChanged)
    for _, option in ipairs(COMBAT_POLICY_OPTIONS) do
        self.policyCombo:addOptionWithData(option.text, option.value)
    end
    self.policyCombo:setSelected(1)
    self:addChild(self.policyCombo)
    self.selectedCombatPolicy = COMBAT_POLICY_OPTIONS[1].value
    y = y + rowHeight + 10

    self:updateCategoryVisibility()

    -- Status label
    self.statusLabel = ISLabel:new(pad, y, rowHeight, "", 1, 0.85, 0.3, 1, UIFont.Small, true)
    self:addChild(self.statusLabel)
    y = y + rowHeight

    -- Create button
    self.createButton = ISButton:new(pad, y, self.width - (pad * 2), 28, "Create Zone", self, KIPN_ZoneAdminUI.onCreateZone)
    self:addChild(self.createButton)
    y = y + 28 + 14

    ------------------------------------------------------------
    -- EXISTING-ZONE POLICY MANAGEMENT
    --
    -- Operates on whichever zone(s) the local player is
    -- currently standing in, resolved client-side from the
    -- last ListZones snapshot purely for display/selection
    -- convenience. The server re-validates admin status and the
    -- zoneId independently on every SetZoneCombatPolicy /
    -- DeactivateZone request -- this panel grants no authority
    -- by itself.
    ------------------------------------------------------------

    self.sectionLabel = ISLabel:new(pad, y, rowHeight, "Zones At My Position:", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.sectionLabel)
    self.refreshButton = ISButton:new(self.width - 90, y - 4, 80, 22, "Refresh", self, KIPN_ZoneAdminUI.onRefreshPositionZone)
    self:addChild(self.refreshButton)
    y = y + rowHeight

    -- Permission zones and combat-policy zones now routinely stack
    -- (that's the point of drawing them as independent shapes), so
    -- this is a picker over every zone at the current position, not
    -- just whichever happened to be listed first.
    self.positionZoneCombo = ISComboBox:new(pad, y, self.width - (pad * 2), 24, self, KIPN_ZoneAdminUI.onPositionZoneComboChanged)
    self.positionZoneCombo:addOptionWithData("(not checked yet)", nil)
    self.positionZoneCombo:setSelected(1)
    self:addChild(self.positionZoneCombo)
    y = y + rowHeight

    self.positionPolicyCombo = ISComboBox:new(pad, y, self.width - (pad * 2), 24, self, KIPN_ZoneAdminUI.onPositionPolicyChanged)
    for _, option in ipairs(COMBAT_POLICY_OPTIONS) do
        self.positionPolicyCombo:addOptionWithData(option.text, option.value)
    end
    self.positionPolicyCombo:setSelected(1)
    self:addChild(self.positionPolicyCombo)
    self.selectedPositionPolicy = COMBAT_POLICY_OPTIONS[1].value
    y = y + rowHeight + 6

    self.applyPolicyButton = ISButton:new(pad, y, self.width - (pad * 2), 26, "Apply Policy To This Zone", self, KIPN_ZoneAdminUI.onApplyPositionPolicy)
    self.applyPolicyButton:setEnable(false)
    self:addChild(self.applyPolicyButton)
    y = y + 26 + 6

    self.deactivateButton = ISButton:new(pad, y, self.width - (pad * 2), 26, "Deactivate This Zone", self, KIPN_ZoneAdminUI.onDeactivatePositionZone)
    self.deactivateButton:setEnable(false)
    self:addChild(self.deactivateButton)
end

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------

local function getLocalPlayerSquarePosition()
    local player = getSpecificPlayer(0)

    if not player then
        return nil
    end

    local ok, square = pcall(function() return player:getSquare() end)

    if not ok or not square then
        return nil
    end

    return {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
    }
end

function KIPN_ZoneAdminUI:setStatus(text)
    if self.statusLabel then
        self.statusLabel:setName(text or "")
    end
end

function KIPN_ZoneAdminUI:setCorners(cornerA, cornerB)
    self.cornerA = cornerA
    self.cornerB = cornerB
    self.cornerALabel:setName(string.format("Corner A: (%d, %d, %d)", cornerA.x, cornerA.y, cornerA.z))
    self.cornerBLabel:setName(string.format("Corner B: (%d, %d, %d)", cornerB.x, cornerB.y, cornerB.z))
end

------------------------------------------------------------
-- ZONE CATEGORY
------------------------------------------------------------

function KIPN_ZoneAdminUI:updateCategoryVisibility()
    local isPermission = self.zoneCategory == "permission"

    self.typeLabel:setVisible(isPermission)
    self.typeCombo:setVisible(isPermission)
    self.policyLabel:setVisible(not isPermission)
    self.policyCombo:setVisible(not isPermission)

    self.permissionCategoryButton.borderColor =
        isPermission
        and { r = 0.3, g = 0.9, b = 0.3, a = 1 }
        or { r = 0.4, g = 0.4, b = 0.4, a = 1 }

    self.combatCategoryButton.borderColor =
        (not isPermission)
        and { r = 0.3, g = 0.9, b = 0.3, a = 1 }
        or { r = 0.4, g = 0.4, b = 0.4, a = 1 }
end

function KIPN_ZoneAdminUI:onCategoryChanged(button)
    self.zoneCategory = button.internal
    self:updateCategoryVisibility()
    self:setStatus("")
end

------------------------------------------------------------
-- EVENT HANDLERS
------------------------------------------------------------

function KIPN_ZoneAdminUI:onClose()
    self:removeFromUIManager()
end

function KIPN_ZoneAdminUI:onDrawOnMap()
    local panel = self

    self:removeFromUIManager()

    KIPN_ZoneAdminMapUI.Open({
        existingZones = panel.lastZones,
        onClose = function()
            panel:addToUIManager()
            panel:bringToTop()
        end,
        onConfirm = function(cornerA, cornerB)
            panel:setCorners(cornerA, cornerB)
            panel:setStatus("Corners set from map.")
        end,
        onUpdateExisting = function(zoneId, label, geometry)
            local player = getSpecificPlayer(0)

            if not player then
                panel:setStatus("No local player found.")
                return
            end

            panel:setStatus("Updating zone...")

            sendClientCommand(player, MODULE_NAME, "UpdateZone", {
                zoneId = zoneId,
                label = label,
                geometry = geometry,
            })
        end,
    })
end

function KIPN_ZoneAdminUI:onMarkCornerA()
    local pos = getLocalPlayerSquarePosition()

    if not pos then
        self:setStatus("Could not read your current position.")
        return
    end

    self.cornerA = pos
    self.cornerALabel:setName(string.format("Corner A: (%d, %d, %d)", pos.x, pos.y, pos.z))
    self:setStatus("")
end

function KIPN_ZoneAdminUI:onMarkCornerB()
    local pos = getLocalPlayerSquarePosition()

    if not pos then
        self:setStatus("Could not read your current position.")
        return
    end

    self.cornerB = pos
    self.cornerBLabel:setName(string.format("Corner B: (%d, %d, %d)", pos.x, pos.y, pos.z))
    self:setStatus("")
end

function KIPN_ZoneAdminUI:onTypeChanged()
    local selected = self.typeCombo.options[self.typeCombo.selected]

    if selected then
        self.selectedZoneType = selected.data
    end
end

function KIPN_ZoneAdminUI:onPolicyChanged()
    local selected = self.policyCombo.options[self.policyCombo.selected]

    if selected then
        self.selectedCombatPolicy = selected.data
    end
end

function KIPN_ZoneAdminUI:onCreateZone()
    if not self.cornerA or not self.cornerB then
        self:setStatus("Mark both corners first.")
        return
    end

    local zoneType
    local combatPolicy

    if self.zoneCategory == "combat" then
        -- Combat zones carry no permission capabilities of their
        -- own (WorldRegistry.DefaultCapabilities["custom"] is
        -- empty) -- they exist purely to attach a PVE or Melee
        -- policy to a shape, which is why they're free to overlap a
        -- Government/Dealership zone drawn over the
        -- same ground.
        zoneType = "custom"
        combatPolicy = self.selectedCombatPolicy or nil

        if not combatPolicy then
            self:setStatus("Choose PvE or Melee for this combat zone.")
            return
        end
    else
        zoneType = self.selectedZoneType
        combatPolicy = nil

        if not zoneType then
            self:setStatus("Choose a zone type.")
            return
        end
    end

    local player = getSpecificPlayer(0)

    if not player then
        self:setStatus("No local player found.")
        return
    end

    self:setStatus("Submitting...")

    sendClientCommand(player, MODULE_NAME, "CreateZone", {
        zoneType = zoneType,
        cornerA = self.cornerA,
        cornerB = self.cornerB,
        combatPolicy = combatPolicy,
    })
end

------------------------------------------------------------
-- EXISTING-ZONE POLICY MANAGEMENT
------------------------------------------------------------

local function isPositionInsideZoneGeometry(x, y, z, geometry)
    if type(geometry) ~= "table" then
        return false
    end

    local z1 = geometry.z1 or 0
    local z2 = geometry.z2 or z1

    return x >= geometry.x1 and x <= geometry.x2
        and y >= geometry.y1 and y <= geometry.y2
        and z >= z1 and z <= z2
end

function KIPN_ZoneAdminUI:onRefreshPositionZone()
    local player = getSpecificPlayer(0)

    if not player then
        self:setStatus("No local player found.")
        return
    end

    self.pendingPositionRefresh = true
    self:setStatus("Checking zones at your position...")

    sendClientCommand(player, MODULE_NAME, "ListZones", {})
end

function KIPN_ZoneAdminUI:onPositionPolicyChanged()
    local selected = self.positionPolicyCombo.options[self.positionPolicyCombo.selected]

    if selected then
        self.selectedPositionPolicy = selected.data
    end
end

function KIPN_ZoneAdminUI:onPositionZoneComboChanged()
    local selected = self.positionZoneCombo.options[self.positionZoneCombo.selected]

    self.positionZoneId = selected and selected.data or nil

    local hasZone = self.positionZoneId ~= nil
    self.applyPolicyButton:setEnable(hasZone)
    self.deactivateButton:setEnable(hasZone)
end

function KIPN_ZoneAdminUI:onApplyPositionPolicy()
    if not self.positionZoneId then
        self:setStatus("Refresh first to select a zone.")
        return
    end

    local player = getSpecificPlayer(0)

    if not player then
        self:setStatus("No local player found.")
        return
    end

    self:setStatus("Applying policy...")

    sendClientCommand(player, MODULE_NAME, "SetZoneCombatPolicy", {
        zoneId = self.positionZoneId,
        combatPolicy = self.selectedPositionPolicy or false,
    })
end

function KIPN_ZoneAdminUI:onDeactivatePositionZone()
    if not self.positionZoneId then
        self:setStatus("Refresh first to select a zone.")
        return
    end

    local player = getSpecificPlayer(0)

    if not player then
        self:setStatus("No local player found.")
        return
    end

    self:setStatus("Deactivating zone...")

    sendClientCommand(player, MODULE_NAME, "DeactivateZone", {
        zoneId = self.positionZoneId,
    })
end

------------------------------------------------------------
-- SERVER RESPONSE
------------------------------------------------------------

local function onServerCommand(module, command, args)
    if module ~= MODULE_NAME then
        return
    end

    local panel = KIPN_ZoneAdminUI.instance

    if command == "CreateZoneResult" then
        if not panel then return end

        if args.success then
            panel:setStatus("Zone created: " .. tostring(args.zoneId))
            panel.cornerA = nil
            panel.cornerB = nil
            panel.cornerALabel:setName("Corner A: not set")
            panel.cornerBLabel:setName("Corner B: not set")

            -- Keep the map editor's existing-zone picker current so
            -- the newly created zone can immediately be renamed or
            -- resized without a manual position refresh.
            panel.pendingPositionRefresh = false
            local player = getSpecificPlayer(0)
            if player then
                sendClientCommand(player, MODULE_NAME, "ListZones", {})
            end
        else
            panel:setStatus("Failed: " .. tostring(args.reason))
        end

    elseif command == "ListZonesResult" then
        if not panel then return end

        if not args.success then
            if panel.pendingPositionRefresh then
                panel.pendingPositionRefresh = false
                panel:setStatus("Failed to list zones: " .. tostring(args.reason))
            end

            return
        end

        -- Cached regardless of pendingPositionRefresh: this is also
        -- what's shown as context on the map overlay (onDrawOnMap),
        -- so it should stay current whenever a listing comes back.
        panel.lastZones = args.zones or {}

        if not panel.pendingPositionRefresh then return end

        panel.pendingPositionRefresh = false

        local pos = getLocalPlayerSquarePosition()

        if not pos then
            panel:setStatus("Could not read your current position.")
            return
        end

        local matches = {}

        for _, zone in ipairs(panel.lastZones) do
            if zone.active ~= false and
               isPositionInsideZoneGeometry(pos.x, pos.y, pos.z, zone.geometry) then
                matches[#matches + 1] = zone
            end
        end

        panel.positionZoneMatches = matches
        panel.positionZoneCombo:clear()

        if #matches == 0 then
            panel.positionZoneCombo:addOptionWithData("(no zones here)", nil)
            panel.positionZoneCombo:setSelected(1)
            panel.positionZoneId = nil
            panel.applyPolicyButton:setEnable(false)
            panel.deactivateButton:setEnable(false)
            panel:setStatus("")
            return
        end

        -- Overlapping zones (e.g. a Dealership permission zone with
        -- a Melee combat zone drawn over it) both show up here, each
        -- independently selectable for Apply Policy / Deactivate.
        for _, zone in ipairs(matches) do
            local typeLabel = ZONE_TYPE_LABELS[zone.type] or tostring(zone.type)

            panel.positionZoneCombo:addOptionWithData(
                string.format("%s [%s]", typeLabel, tostring(zone.combatPolicy or "no policy")),
                zone.id
            )
        end

        panel.positionZoneCombo:setSelected(1)
        panel:onPositionZoneComboChanged()
        panel:setStatus(string.format("%d zone(s) at your position.", #matches))

    elseif command == "SetZoneCombatPolicyResult" then
        if not panel then return end

        if args.success then
            panel:setStatus("Policy updated: " .. tostring(args.combatPolicy or "cleared"))
            panel:onRefreshPositionZone()
        else
            panel:setStatus("Failed: " .. tostring(args.reason))
        end

    elseif command == "DeactivateZoneResult" then
        if not panel then return end

        if args.success then
            panel:setStatus("Zone deactivated: " .. tostring(args.zoneId))
            panel:onRefreshPositionZone()
        else
            panel:setStatus("Failed: " .. tostring(args.reason))
        end

    elseif command == "UpdateZoneResult" then
        if not panel then return end

        if args.success then
            panel:setStatus("Zone updated: " .. tostring(args.zoneId))

            -- Refresh the map-edit snapshot without replacing the
            -- success message with the position-checking status.
            panel.pendingPositionRefresh = false
            local player = getSpecificPlayer(0)
            if player then
                sendClientCommand(player, MODULE_NAME, "ListZones", {})
            end
        else
            panel:setStatus("Failed: " .. tostring(args.reason))
        end
    end
end

Events.OnServerCommand.Add(onServerCommand)

print("[KIPN] Zone Admin UI loaded")
