local p = getPlayer()
local q = ISTimedActionQueue.getTimedActionQueue(p)
DMMMPProbeResult = p and ("at " .. math.floor(p:getX()) .. "," .. math.floor(p:getY()) .. " dead=" .. tostring(p:isDead())
    .. " queue=" .. tostring(q and q.queue and #q.queue) .. " state=" .. tostring(p:getCurrentState())
    .. " admin=" .. tostring(p:getRole() and p:getRole():getName())) or "no player"
