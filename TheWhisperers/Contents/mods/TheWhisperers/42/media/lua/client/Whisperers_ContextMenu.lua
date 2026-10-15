-- The Whisperers: right-click options for corpses, guts, heads and masks.
require "ISUI/ISWorldObjectContextMenu"
require "ISUI/ISInventoryPaneContextMenu"
require "Whisperers_Gear"
require "TimedActions/Whisp_ButcherCorpseAction"
require "TimedActions/Whisp_RemoveHeadAction"
require "TimedActions/Whisp_CutFaceAction"
require "TimedActions/Whisp_SmearGutsAction"
require "TimedActions/Whisp_SkinCorpseAction"
require "TimedActions/Whisp_RepairMaskAction"

local W = Whisperers
local G = W.Gear

local function tip(option, key, arg)
    local tooltip = ISWorldObjectContextMenu.addToolTip()
    tooltip.description = arg ~= nil and getText(key, arg) or getText(key)
    option.toolTip = tooltip
    return tooltip
end

local function disable(option, key, arg)
    option.notAvailable = true
    tip(option, key, arg)
end

local function transfer(player, item)
    ISInventoryPaneContextMenu.transferIfNeeded(player, item)
end

-- Corpse actions ---------------------------------------------------------

local function onButcher(player, body, knife)
    if not luautils.walkAdj(player, body:getSquare()) then return end
    ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), knife, true)
    ISTimedActionQueue.add(Whisp_ButcherCorpseAction:new(player, body, knife))
end

local function onRemoveHead(player, body, weapon)
    if not luautils.walkAdj(player, body:getSquare()) then return end
    ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), weapon, true, weapon:isTwoHandWeapon())
    ISTimedActionQueue.add(Whisp_RemoveHeadAction:new(player, body, weapon))
end

local function onSkin(player, body, knife, tool, claspType)
    if not luautils.walkAdj(player, body:getSquare()) then return end
    transfer(player, tool)
    ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), knife, true)
    ISTimedActionQueue.add(Whisp_SkinCorpseAction:new(player, body, knife, tool, claspType))
end

local CLASS_KEY = {
    rare = "IGUI_Whisp_OneBlow",
    long = "IGUI_Whisp_Blows",
    axe = "IGUI_Whisp_Blows",
    short = "IGUI_Whisp_Stabs",
}

local function addCorpseMenu(player, context, body)
    local root = context:addOption(getText("IGUI_Whisp_CorpseMenu"))
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(root, sub)

    -- Guts
    local knife = G.butcherKnife(player)
    local opt = sub:addOption(getText("IGUI_Whisp_Butcher"), player, onButcher, body, knife)
    if not G.canButcher(body) then
        disable(opt, G.isSkinned(body) and "IGUI_Whisp_TipSkinned" or "IGUI_Whisp_TipGutted")
    elseif not knife then
        disable(opt, "IGUI_Whisp_TipNeedButcherKnife")
    else
        tip(opt, "IGUI_Whisp_TipButcher")
    end

    -- Head
    local tools = G.headTools(player)
    local headOpt = sub:addOption(getText("IGUI_Whisp_RemoveHead"))
    if not G.canBehead(body) then
        disable(headOpt, G.isSkinned(body) and "IGUI_Whisp_TipSkinned" or "IGUI_Whisp_TipHeadless")
    elseif #tools == 0 then
        disable(headOpt, "IGUI_Whisp_TipNeedHeadBlade")
    else
        local headSub = ISContextMenu:getNew(sub)
        sub:addSubMenu(headOpt, headSub)
        for _, weapon in ipairs(tools) do
            local cls = G.bladeClass(weapon)
            local blows = G.headBlows(player, weapon)
            local label = weapon:getDisplayName() .. " - " .. getText(CLASS_KEY[cls], blows)
            local wOpt = headSub:addOption(label, player, onRemoveHead, body, weapon)
            if cls == "short" then tip(wOpt, "IGUI_Whisp_TipShortBladeTiring") end
        end
    end

    -- Skin suit
    local tool = G.findSewingTool(player)
    local claspType = G.findClasp(player, Whisp_SkinCorpseAction.Sets)
    local suitOpt = sub:addOption(getText("IGUI_Whisp_Skin"), player, onSkin, body, knife, tool, claspType)
    if not G.canSkin(body) then
        disable(suitOpt, "IGUI_Whisp_TipSkinned")
    elseif not Whisp_SkinCorpseAction.meetsSkills(player) then
        disable(suitOpt, "IGUI_Whisp_TipSuitSkills", W.Get("SuitTailoring") .. "/" .. W.Get("SuitButchering"))
    elseif not knife then
        disable(suitOpt, "IGUI_Whisp_TipNeedButcherKnife")
    elseif not tool or not claspType then
        disable(suitOpt, "IGUI_Whisp_TipSuitMaterials")
    else
        local t = tip(suitOpt, "IGUI_Whisp_TipSkin")
        if G.isNail(tool) then t.description = t.description .. " <LINE> " .. getText("IGUI_Whisp_TipNailDamage", W.Get("NailDamage")) end
    end
end

-- Inventory actions --------------------------------------------------------

local function onSmear(player, gutsList)
    for _, guts in ipairs(gutsList) do
        transfer(player, guts)
        ISTimedActionQueue.add(Whisp_SmearGutsAction:new(player, guts))
    end
end

-- Every gut carried, freshest first, so the fewest get used.
local function carriedGuts(player)
    local items = player:getInventory():getAllTypeRecurse(G.Types.Guts)
    local list = {}
    for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
    table.sort(list, function(a, b) return G.gutsCapacity(a) > G.gutsCapacity(b) end)
    return list
end

-- Keep smearing until camouflage is full or the guts run out.
local function onSmearAll(player)
    for _, guts in ipairs(carriedGuts(player)) do
        transfer(player, guts)
        ISTimedActionQueue.add(Whisp_SmearGutsAction:new(player, guts, true))
    end
end

local function onCutFace(player, head, knife)
    transfer(player, head)
    transfer(player, knife)
    ISTimedActionQueue.add(Whisp_CutFaceAction:new(player, head, knife))
end

local function onRepairMask(player, mask, tool, claspType)
    transfer(player, mask)
    transfer(player, tool)
    ISTimedActionQueue.add(Whisp_RepairMaskAction:new(player, mask, tool, claspType))
end

local function unpack(items)
    local list = {}
    for _, v in ipairs(items) do
        if instanceof(v, "InventoryItem") then
            list[#list + 1] = v
        elseif type(v) == "table" and v.items then
            -- First entry of a stack is a duplicate header.
            for i = 2, #v.items do list[#list + 1] = v.items[i] end
            if #v.items == 1 then list[#list + 1] = v.items[1] end
        end
    end
    return list
end

local function onInventoryMenu(playerNum, context, items)
    if not W.Get("Enabled") then return end
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end

    local guts, heads, masks = {}, {}, {}
    for _, it in ipairs(unpack(items)) do
        local t = it:getFullType()
        if t == G.Types.Guts then guts[#guts + 1] = it
        elseif t == G.Types.Head then heads[#heads + 1] = it
        elseif t == G.Types.Mask then masks[#masks + 1] = it end
    end

    if #guts > 0 then
        local opt = context:addOption(getText("IGUI_Whisp_Smear"), player, onSmear, { guts[1] })
        tip(opt, "IGUI_Whisp_TipSmear", W.Get("GutsSmearEfficiency"))
        local carried = #carriedGuts(player)
        if carried > 1 then
            local allOpt = context:addOption(getText("IGUI_Whisp_SmearAll", carried), player, onSmearAll)
            if W.camoStrength(W.measureGore(player)) >= 1 then
                disable(allOpt, "IGUI_Whisp_TipFullyGored")
            else
                tip(allOpt, "IGUI_Whisp_TipSmearAll", W.Get("FullGorePercent"))
            end
        end
    end

    local head = heads[1]
    if head and not head:getModData().WhispFaceless then
        local blades = G.shortBlades(player)
        local opt = context:addOption(getText("IGUI_Whisp_CutFace"))
        if #blades == 0 then
            disable(opt, "IGUI_Whisp_TipNeedShortBlade")
        else
            local sub = ISContextMenu:getNew(context)
            context:addSubMenu(opt, sub)
            for _, knife in ipairs(blades) do
                local bOpt = sub:addOption(knife:getDisplayName(), player, onCutFace, head, knife)
                local dmg = math.floor(Whisp_CutFaceAction.baseDamage(player, knife) * 100 + 0.5)
                tip(bOpt, "IGUI_Whisp_TipCutFace", dmg)
            end
        end
    end

    local mask = masks[1]
    if mask and mask:getCondition() < mask:getConditionMax() then
        local tool = G.findSewingTool(player)
        local claspType = G.findClasp(player, 1)
        local opt = context:addOption(getText("IGUI_Whisp_RepairMask"), player, onRepairMask, mask, tool, claspType)
        if player:getPerkLevel(Perks.Tailoring) < W.Get("MaskRepairTailoring") then
            disable(opt, "IGUI_Whisp_TipRepairSkill", W.Get("MaskRepairTailoring"))
        elseif not tool or not claspType then
            disable(opt, "IGUI_Whisp_TipMaskMaterials")
        elseif G.isNail(tool) then
            tip(opt, "IGUI_Whisp_TipNailDamage", W.Get("NailDamage"))
        end
    end
end

-- World: corpses under the cursor, and guts lying on the ground.
local function onWorldMenu(playerNum, context, worldobjects, test)
    if not W.Get("Enabled") then return end
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end

    local body = ISWorldObjectContextMenu.fetchVars and ISWorldObjectContextMenu.fetchVars.body
    if body and G.isHumanCorpse(body) then
        if test then return true end
        addCorpseMenu(player, context, body)
    end

    local guts = {}
    local seen = {}
    for _, obj in ipairs(worldobjects) do
        local sq = obj.getSquare and obj:getSquare()
        if sq and not seen[sq] then
            seen[sq] = true
            local wobs = sq:getWorldObjects()
            for i = 0, wobs:size() - 1 do
                local item = wobs:get(i):getItem()
                if item and item:getFullType() == G.Types.Guts then guts[#guts + 1] = item end
            end
        end
    end
    if #guts > 0 then
        if test then return true end
        context:addOption(getText("IGUI_Whisp_Smear"), player, onSmear, { guts[1] })
    end
end

Events.OnFillInventoryObjectContextMenu.Add(onInventoryMenu)
Events.OnFillWorldObjectContextMenu.Add(onWorldMenu)
