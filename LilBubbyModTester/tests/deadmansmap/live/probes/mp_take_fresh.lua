-- Fresh loot-panel lookup and transfer of the first item matching DMMMPTakeWhat.
DMMMPProbeResult = (function()
    local p = getPlayer()
    local loot = getPlayerLoot(0)
    loot:refreshBackpacks()
    local found
    for _, b in ipairs(loot.backpacks) do
        local items = b.inventory and b.inventory:getItems()
        for i = 0, (items and items:size() or 0) - 1 do
            local it = items:get(i)
            if (DMMMPTakeWhat == "death" and it:getModData().DMM_IsDeathMap) or (DMMMPTakeWhat == "vanilla" and it:getFullType() == "Base.Map" and not it:getModData().DMM_IsDeathMap) then found = it end
        end
    end
    if not found then return "not found in loot panel: " .. tostring(DMMMPTakeWhat) end
    DMMMPProbeItem = found
    local src = found:getContainer()
    ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(p, found, src, p:getInventory()))
    return "queued " .. found:getName() .. " srcHasItem=" .. tostring(src:contains(found))
end)()
