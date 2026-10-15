DMMMPProbeResult = (function()
    local p = getPlayer()
    local loot = getPlayerLoot(0)
    loot:refreshBackpacks()
    local found
    for _, b in ipairs(loot.backpacks) do
        local items = b.inventory and b.inventory:getItems()
        for i = 0, (items and items:size() or 0) - 1 do
            local it = items:get(i)
            if it:getModData().DMM_IsDeathMap then found = it end
        end
    end
    if not found then return "no death map in loot panel" end
    DMMMPProbeItem = found
    local action = ISInventoryTransferUtil.newInventoryTransferAction(p, found, found:getContainer(), p:getInventory())
    ISTimedActionQueue.add(action)
    return "queued transfer of " .. found:getName() .. " id=" .. tostring(found:getID()) .. " from " .. found:getContainer():getType()
        .. " worldItem=" .. tostring(found:getWorldItem() ~= nil)
end)()
