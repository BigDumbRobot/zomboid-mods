require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Sandbox"
require "SacrificialOffering/SO_ZoneCompatibility"
require "SacrificialOffering/SO_ClientState"
require "SacrificialOffering/SO_Announce"
require "ISUI/AdminPanel/ZoneEditor/MultiplayerZoneEditorMode_Safehouse"
require "ISUI/AdminPanel/ISAddSafeZoneUI"
require "ISUI/ISWorldObjectContextMenu"

local SO = SacrificialOffering
SO.ClientZoneRules = SO.ClientZoneRules or {}
local Rules = SO.ClientZoneRules

local function safehouseRect(safehouse)
    local x1, y1 = safehouse:getX(), safehouse:getY()
    local x2 = safehouse.getX2 and safehouse:getX2() or x1 + safehouse:getW()
    local y2 = safehouse.getY2 and safehouse:getY2() or y1 + safehouse:getH()
    return SO.Util.NormalizeRect(x1, y1, x2, y2)
end

-- A temple may not be drawn over another temple, a player Safehouse, or an
-- opted-in third-party managed zone. It intentionally coexists with vanilla
-- Non-PVP zones and never modifies any zone it overlaps.
function Rules.CheckTemplePlacement(rect, ignoreZoneId)
    local minimum, maximum = SO.Sandbox.ZoneSizeRange()
    local width, height = rect.x2 - rect.x1, rect.y2 - rect.y1
    if width < minimum or height < minimum or width > maximum or height > maximum then return false, "size" end
    if SO.Client.IntersectsTemple(rect, ignoreZoneId) then return false, "temple" end

    local safehouses = SafeHouse.getSafehouseList()
    for index = 0, safehouses:size() - 1 do
        if SO.Util.RectsIntersect(rect, safehouseRect(safehouses:get(index))) then return false, "safehouse" end
    end

    local overlap, provider = SO.ZoneCompatibility.CheckExternalOverlap(rect)
    if overlap then return false, provider end
    return true, nil
end

function Rules.BlockedClaimMessage()
    SO.Announce.Show(getText("IGUI_SO_ClaimOverlap"), "bad")
end

local function buildingRect(square)
    if not square or not square:getBuilding() then return nil end
    local definition = square:getBuilding():getDef()
    if not definition then return nil end
    local ok, rect = pcall(function()
        local x1, y1 = definition:getX(), definition:getY()
        local x2 = definition.getX2 and definition:getX2() or x1 + definition:getW()
        local y2 = definition.getY2 and definition:getY2() or y1 + definition:getH()
        return SO.Util.NormalizeRect(x1, y1, x2, y2)
    end)
    return ok and rect or nil
end

-- Safehouses and temples are kept mutually exclusive, but only by refusing the
-- overlapping claim -- nothing existing is ever removed or resized.
if not Rules.Patched then
    Rules.Patched = true

    local oldSafehouseNew = MultiplayerZoneEditorMode_Safehouse.isNewZoneValid
    function MultiplayerZoneEditorMode_Safehouse:isNewZoneValid(x1, y1, x2, y2)
        if not oldSafehouseNew(self, x1, y1, x2, y2) then return false end
        return not SO.Client.IntersectsTemple(SO.Util.NormalizeRect(x1, y1, x2, y2))
    end

    local oldTakeSafehouse = ISWorldObjectContextMenu.onTakeSafeHouse
    function ISWorldObjectContextMenu.onTakeSafeHouse(worldobjects, square, player)
        local rect = buildingRect(square)
        if rect and SO.Client.IntersectsTemple(rect) then
            Rules.BlockedClaimMessage()
            return
        end
        return oldTakeSafehouse(worldobjects, square, player)
    end

    local oldSafeButtons = ISAddSafeZoneUI.updateButtons
    function ISAddSafeZoneUI:updateButtons()
        oldSafeButtons(self)
        local rect = SO.Util.NormalizeRect(self.X1, self.Y1, self.X2 + 1, self.Y2 + 1)
        if rect and SO.Client.IntersectsTemple(rect) then self.ok.enable = false end
    end

    SO.Logger.Debug("Safehouse/temple mutual-exclusion guards installed")
end

return Rules
