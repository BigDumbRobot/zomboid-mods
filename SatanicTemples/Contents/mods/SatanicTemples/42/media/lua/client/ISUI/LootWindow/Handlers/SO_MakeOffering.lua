require "ISUI/LootWindow/ISLootWindowObjectControlHandler"
require "ISUI/LootWindow/ISLootWindowContainerControls"
require "Camping/CCampfireSystem"
require "TimedActions/ISTimedActionQueue"
require "luautils"
require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Sandbox"
require "SacrificialOffering/SO_RecipeParser"
require "SacrificialOffering/SO_ClientState"
require "SacrificialOffering/SO_Sound"
require "SacrificialOffering/SO_OfferingAction"

local SO = SacrificialOffering
local NEARBY_ANIMAL_RADIUS_TILES = 1

ISLootWindowObjectControlHandler_SO_MakeOffering = ISLootWindowObjectControlHandler:derive("ISLootWindowObjectControlHandler_SO_MakeOffering")
local Handler = ISLootWindowObjectControlHandler_SO_MakeOffering
Handler.Type = "SacrificialOffering.MakeOffering"

local function isAltar(object, container)
    if not object or not container or container:getType() ~= SO.ALTAR_CONTAINER_TYPE then return false end
    local md = object:getModData()
    if not md or md[SO.MOD_DATA.PROTECTED] ~= true then return false end
    local kind = md[SO.MOD_DATA.FIXTURE_KIND]
    return kind == SO.FIXTURE.ALTAR or kind == SO.FIXTURE.ALTAR_BACK
end

local function pairedAltarContainer(object)
    local square = object and object:getSquare()
    local md = object and object:getModData()
    if not square or not md then return nil end

    local kind = md[SO.MOD_DATA.FIXTURE_KIND]
    local pairY
    if kind == SO.FIXTURE.ALTAR then
        pairY = square:getY() - 1
    elseif kind == SO.FIXTURE.ALTAR_BACK then
        pairY = square:getY() + 1
    else
        return nil
    end

    local pairSquare = getCell():getGridSquare(square:getX(), pairY, square:getZ())
    if not pairSquare then return nil end
    local objects = pairSquare:getObjects()
    for index = 0, objects:size() - 1 do
        local candidate = objects:get(index)
        local candidateMd = candidate and candidate:getModData()
        local container = candidate and candidate:getContainer()
        if candidateMd
            and candidateMd[SO.MOD_DATA.PROTECTED] == true
            and candidateMd[SO.MOD_DATA.ALTAR_ID] == md[SO.MOD_DATA.ALTAR_ID]
            and isAltar(candidate, container) then
            return container
        end
    end
    return nil
end

local function isIntactAnimalBody(body)
    local ok, intact = pcall(function()
        if not body:isAnimal() or body:isAnimalSkeleton() or not body:hasAnimalParts() then return false end
        local md = body:getModData()
        return not md or (md.skeleton ~= true and md.skinned ~= true and md.headless ~= true)
    end)
    return ok and intact == true
end

local function isIntactAnimalItem(item)
    if not item or item:getFullType() ~= "Base.CorpseAnimal" then return false end
    local ok, body = pcall(function() return item:getDeadBodyObject() end)
    return ok and isIntactAnimalBody(body)
end

local function hasNearbyAnimalOffering(object)
    local square = object and object:getSquare()
    local md = object and object:getModData()
    if not square or not md then return false end
    local pairY = md[SO.MOD_DATA.FIXTURE_KIND] == SO.FIXTURE.ALTAR
        and square:getY() - 1 or square:getY() + 1
    local centers = {
        { x = square:getX(), y = square:getY(), z = square:getZ() },
        { x = square:getX(), y = pairY, z = square:getZ() },
    }
    local seenSquares = {}

    for _, center in ipairs(centers) do
        for dx = -NEARBY_ANIMAL_RADIUS_TILES, NEARBY_ANIMAL_RADIUS_TILES do
            for dy = -NEARBY_ANIMAL_RADIUS_TILES, NEARBY_ANIMAL_RADIUS_TILES do
                local candidate = getCell():getGridSquare(center.x + dx, center.y + dy, center.z)
                if candidate and not seenSquares[candidate] then
                    seenSquares[candidate] = true
                    local bodies = candidate:getStaticMovingObjects()
                    for index = 0, bodies:size() - 1 do
                        if isIntactAnimalBody(bodies:get(index)) then return true end
                    end
                    local worldObjects = candidate:getWorldObjects()
                    for index = 0, worldObjects:size() - 1 do
                        local ok, item = pcall(function() return worldObjects:get(index):getItem() end)
                        if ok and isIntactAnimalItem(item) then return true end
                    end
                end
            end
        end
    end
    return false
end

local function hasOffering(object, container)
    if not container:getItems():isEmpty() then return true end
    local paired = pairedAltarContainer(object)
    if paired ~= nil and not paired:getItems():isEmpty() then return true end
    return hasNearbyAnimalOffering(object)
end

local function assignedCampfireIsLit(object)
    local md = object:getModData()
    local x, y, z = tonumber(md[SO.MOD_DATA.CAMPFIRE_X]), tonumber(md[SO.MOD_DATA.CAMPFIRE_Y]), tonumber(md[SO.MOD_DATA.CAMPFIRE_Z])
    if not x or not y or not z or not CCampfireSystem.instance then return false end
    local campfire = CCampfireSystem.instance:getLuaObjectAt(x, y, z)
    return campfire ~= nil and campfire.isLit == true
end

function Handler:shouldBeVisible()
    if not isAltar(self.object, self.container) then return false end
    if not hasOffering(self.object, self.container) then return false end
    return assignedCampfireIsLit(self.object)
end

local function itemDisplayName(fullType)
    local ok, name = pcall(getItemNameFromFullType, fullType)
    if ok and name and name ~= "" then return name end
    return fullType
end

local function describeSacrifices()
    local lines = { getText("IGUI_SO_SacrificeTooltip") }
    local recipes = SO.RecipeParser.Parse(SO.Sandbox.String("AcceptableItemRecipes"))
    for _, recipe in ipairs(recipes) do
        local parts = {}
        for _, part in ipairs(recipe.parts) do
            local name = itemDisplayName(part.fullType)
            parts[#parts + 1] = part.count > 1 and (tostring(part.count) .. "x " .. name) or name
        end
        if #parts > 0 then lines[#lines + 1] = "   - " .. table.concat(parts, " + ") end
    end
    lines[#lines + 1] = getText("IGUI_SO_SacrificeTooltip_Corpse")
    lines[#lines + 1] = getText("IGUI_SO_SacrificeTooltip_CorpseRepeat")
    lines[#lines + 1] = getText("IGUI_SO_SacrificeTooltip_SelfCorpse")
    lines[#lines + 1] = getText("IGUI_SO_SacrificeTooltip_Animal")
    lines[#lines + 1] = getText("IGUI_SO_SacrificeTooltip_Quality")
    lines[#lines + 1] = getText("IGUI_SO_SacrificeTooltip_Upgrade")
    if SO.Sandbox.Boolean("PlayerCorpsePrizeEnabled") then
        lines[#lines + 1] = getText("IGUI_SO_SacrificeTooltip_Prize")
    end
    return table.concat(lines, "\n")
end

function Handler:getControl()
    self.control = self:getButtonControl(getText("IGUI_SO_MakeOffering"))
    self.control:setTooltip(describeSacrifices())
    return self.control
end

function Handler:handleJoypadContextMenu(context)
    self:addJoypadContextMenuOption(context, getText("IGUI_SO_MakeOffering"))
end

function Handler:perform()
    if isGamePaused() or not self.playerObj or not isAltar(self.object, self.container) then return end
    if self.playerObj:getVehicle() then return end
    local now = SO.Util.NowMs()
    if self.lastRequestAt and now - self.lastRequestAt < 1000 then return end
    self.lastRequestAt = now
    if SO_OfferingRitualAction.IsActive(self.playerObj) then return end

    local square = self.object:getSquare()
    local md = self.object:getModData()
    local args = {
        tx = SO.Util.NewTransactionId("offering", self.playerObj),
        zoneId = md[SO.MOD_DATA.ZONE_ID],
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
    }
    -- Walk to the altar, then channel the recovery ritual. Build 42 mirrors the
    -- action to the server, which adjudicates the offering when it completes.
    if luautils.walkAdj(self.playerObj, square) then
        ISTimedActionQueue.add(SO_OfferingRitualAction:new(self.playerObj, self.object, args))
    end
end

function Handler:new()
    local object = ISLootWindowObjectControlHandler.new(self)
    object.altColor = true
    return object
end

ISLootWindowContainerControls.AddHandler(Handler, true)

return Handler
