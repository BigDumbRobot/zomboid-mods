local p = getPlayer()
WhispProbeResult = p and ("at " .. math.floor(p:getX()) .. "," .. math.floor(p:getY()) .. " outside=" .. tostring(p:isOutside()) .. " weight=" .. tostring(p:getInventoryWeight())) or "no player"
