DMMMPProbeResult = (function()
    local p = getPlayer()
    local out = {}
    local inv = p:getInventory():getItems()
    for i = 0, inv:size() - 1 do
        local it = inv:get(i)
        if it:getFullType() == "Base.Map" then out[#out + 1] = "INV " .. it:getName() .. " id=" .. it:getID() .. " dmm=" .. tostring(it:getModData().DMM_IsDeathMap) end
    end
    local sq = p:getCurrentSquare()
    for dx = -2, 2 do for dy = -2, 2 do
        local s = getCell():getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
        local objs = s and s:getWorldObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            local it = objs:get(i):getItem()
            out[#out + 1] = "GROUND " .. it:getName() .. " id=" .. it:getID() .. " dmm=" .. tostring(it:getModData().DMM_IsDeathMap)
        end
    end end
    return table.concat(out, " | ")
end)()
