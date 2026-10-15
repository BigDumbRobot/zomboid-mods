-- Prevent vanilla furniture pickup/rotation/scrapping from moving a
-- server-registered PO Box away from its authoritative coordinates.
-- Admin removal remains available through KIPN_ZoneAdminTrigger.

require "Moveables/ISMoveableSpriteProps"

local function isProtected(object)
    if not object or type(object.getModData) ~= "function" then
        return false
    end

    local modData = object:getModData()
    return modData and modData.KIPNProtectedMoveable == true
end

local function squareHasProtectedObject(square)
    if not square or type(square.getObjects) ~= "function" then
        return false
    end

    local objects = square:getObjects()
    if not objects then return false end

    for index = 0, objects:size() - 1 do
        if isProtected(objects:get(index)) then
            return true
        end
    end

    return false
end

local function isProtectedMoveable(object, square)
    return isProtected(object)
        or squareHasProtectedObject(square)
end

if not ISMoveableSpriteProps._KIPNPOBoxProtected then
    ISMoveableSpriteProps._KIPNPOBoxProtected = true

    local originalCanPickUp = ISMoveableSpriteProps.canPickUpMoveable
    function ISMoveableSpriteProps:canPickUpMoveable(character, square, object)
        if isProtectedMoveable(object, square) then return false end
        return originalCanPickUp(self, character, square, object)
    end

    local originalCanRotate = ISMoveableSpriteProps.canRotateMoveable
    function ISMoveableSpriteProps:canRotateMoveable(square, object, originalProps)
        if isProtectedMoveable(object, square) then return false end
        return originalCanRotate(self, square, object, originalProps)
    end

    local originalCanScrap = ISMoveableSpriteProps.canScrapObject
    function ISMoveableSpriteProps:canScrapObject(character)
        if isProtected(self.object) then
            return {
                canScrap = false,
                craftValid = false,
                haveTool = false,
                haveTool2 = false,
            }, 0, nil
        end
        return originalCanScrap(self, character)
    end
end

print("[KIPN] PO Box move/scrap protection loaded")
