local p = getPlayer()
local q = ISTimedActionQueue.getTimedActionQueue(p)
local names = {}
for _, a in ipairs(q and q.queue or {}) do
    names[#names + 1] = tostring(a.Type) .. "(started=" .. tostring(a.action ~= nil) .. ", valid=" .. tostring(pcall(function() return a:isValid() end) and a:isValid()) .. ")"
end
local it = DMMMPProbeItem
DMMMPProbeResult = "queue=[" .. table.concat(names, ", ") .. "] carried=" .. tostring(it and p:getInventory():contains(it, true))
    .. " itemContainer=" .. tostring(it and it:getContainer() and it:getContainer():getType())
