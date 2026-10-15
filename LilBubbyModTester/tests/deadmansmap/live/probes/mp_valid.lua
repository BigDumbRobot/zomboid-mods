DMMMPProbeResult = (function()
    local p = getPlayer()
    local it = DMMMPProbeItem
    if not it then return "no item" end
    local src = it:getContainer()
    local a = ISInventoryTransferUtil.newInventoryTransferAction(p, it, src, p:getInventory())
    local ok, valid = pcall(function() return a:isValid() end)
    local inv = p:getInventory():getItems()
    local names = {}
    for i = 0, inv:size() - 1 do names[#names + 1] = inv:get(i):getFullType() end
    return "isValid=" .. tostring(ok and valid or valid) .. " srcType=" .. tostring(src and src:getType())
        .. " srcHasItem=" .. tostring(src and src:contains(it)) .. " srcParentSq=" .. tostring(src and src:getSourceGrid() ~= nil)
        .. " weight=" .. tostring(p:getInventoryWeight()) .. "/" .. tostring(p:getMaxWeight())
        .. " inv=" .. table.concat(names, ",")
end)()
