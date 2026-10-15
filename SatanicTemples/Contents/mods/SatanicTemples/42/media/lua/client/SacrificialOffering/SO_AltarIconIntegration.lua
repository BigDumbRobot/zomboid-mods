require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Logger"
require "ISUI/ISInventoryPage"

local SO = SacrificialOffering

-- Loot-window button icon for altar containers: a red skull-and-crossbones.
-- Ships as a loose texture at media/textures/SO_Skull.png. Falls back to the
-- the vanilla skull icon, so the button is never blank.
local ICON_CANDIDATES = { "SO_Skull", "media/textures/SO_Skull.png", "Item_Skull" }
local ALTAR_ICON = nil
local loggedIcon, loggedFire = false, false
local originalAddContainerButton = ISInventoryPage.addContainerButton

local function validTexture(texture)
    if not texture then return false end
    local width = 0
    pcall(function() width = texture:getWidth() or texture:getWidthOrig() or 0 end)
    return width > 0
end

local function getAltarIcon()
    if ALTAR_ICON == nil then
        for _, name in ipairs(ICON_CANDIDATES) do
            local texture = getTexture(name)
            if validTexture(texture) then
                ALTAR_ICON = texture
                if not loggedIcon then
                    loggedIcon = true
                    SO.Logger.Debug("Altar container icon resolved", { texture = name })
                end
                break
            end
        end
        if ALTAR_ICON == nil then
            ALTAR_ICON = false
            if not loggedIcon then
                loggedIcon = true
                SO.Logger.Warn("No altar container icon texture could be loaded", {
                    tried = table.concat(ICON_CANDIDATES, ", "),
                })
            end
        end
    end
    return ALTAR_ICON or nil
end

local function altarHalf(container)
    if not container or container:getType() ~= SO.ALTAR_CONTAINER_TYPE then return false end
    local parent = container:getParent()
    if not parent then return false end

    local md = parent.getModData and parent:getModData()
    local kind = md and md[SO.MOD_DATA.FIXTURE_KIND]
    if md and md[SO.MOD_DATA.PROTECTED]
        and (kind == SO.FIXTURE.ALTAR or kind == SO.FIXTURE.ALTAR_BACK) then
        return kind
    end

    local objectName = parent.getName and parent:getName()
    local containerName = container:getCustomName()
    if objectName ~= SO.ALTAR_NAME and containerName ~= SO.ALTAR_NAME then return false end

    -- Legacy fixtures predate protection tags but retain their altar name and
    -- vanilla dumpster sprites. Requiring that name avoids changing ordinary
    -- dumpsters that use the same container type and artwork.
    local sprite = parent.getSprite and parent:getSprite()
    local spriteName = sprite and sprite:getName()
    if spriteName == "trashcontainers_01_8" then return SO.FIXTURE.ALTAR end
    if spriteName == "trashcontainers_01_9" then return SO.FIXTURE.ALTAR_BACK end
    return "legacy-altar"
end

local function resetVisibleAltars(page, stage)
    if stage == "begin" then
        page.SO_VisibleAltarButtons = {}
        page.SO_VisibleAltarButtonCount = 0
    end
end

if not ISInventoryPage.SO_AltarIconInstalled then
    function ISInventoryPage:addContainerButton(container, texture, name, tooltip)
        local half = altarHalf(container)
        if half and not loggedFire then
            loggedFire = true
            SO.Logger.Debug("Altar container button intercepted", { half = tostring(half) })
        end
        local visible = self.SO_VisibleAltarButtons
        if half and visible then
            -- Never render more than one button for either dumpster half, even
            -- while a client still has legacy duplicates awaiting server repair.
            if visible[half] then return visible[half] end
            if (self.SO_VisibleAltarButtonCount or 0) >= 2 then
                return visible[SO.FIXTURE.ALTAR] or visible[SO.FIXTURE.ALTAR_BACK]
                    or visible["legacy-altar"]
            end
        end

        local button = originalAddContainerButton(self, container, texture, name, tooltip)
        if half then
            self.SO_VisibleAltarButtons = self.SO_VisibleAltarButtons or {}
            self.SO_VisibleAltarButtons[half] = button
            self.SO_VisibleAltarButtonCount = (self.SO_VisibleAltarButtonCount or 0) + 1
        end
        local icon = half and getAltarIcon()
        if icon and button then
            button:setImage(icon)
            button:setTextureRGBA(1.0, 1.0, 1.0, 1.0)
        end
        return button
    end
    Events.OnRefreshInventoryWindowContainers.Add(resetVisibleAltars)
    ISInventoryPage.SO_AltarIconInstalled = true
end

return true
