-- Vanilla "Check Map" on the floor map from a fresh Ground-panel lookup.
DMMMPProbeResult = (function()
    local loot = getPlayerLoot(0)
    loot:refreshBackpacks()
    local found
    for _, b in ipairs(loot.backpacks) do
        local items = b.inventory and b.inventory:getItems()
        for i = 0, (items and items:size() or 0) - 1 do
            local it = items:get(i)
            if it:getFullType() == "Base.Map" then found = it end
        end
    end
    if not found then return "no map in loot panel" end
    DMMMPOpened = nil
    if not DMMMPOrigNew then DMMMPOrigNew = ISMap.new end
    ISMap.new = function(...) local o = DMMMPOrigNew(...); DMMMPOpened = o; return o end
    ISInventoryPaneContextMenu.onCheckMap(found, 0)
    return "Check Map on " .. found:getName()
end)()
