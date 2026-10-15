local p = getPlayer()
local q = ISTimedActionQueue.getTimedActionQueue(p)
local o = DMMMPOpened
DMMMPProbeResult = "opened=" .. tostring(o ~= nil) .. " visible=" .. tostring(o and o.wrap and o.wrap:isVisible())
    .. " queue=" .. tostring(q and q.queue and #q.queue) .. (q and q.queue and q.queue[1] and (" first=" .. tostring(q.queue[1].Type)) or "")
