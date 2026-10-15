-- Spaces each player's requests to a suite without ever losing one. A request
-- that arrives before the suite's gap has passed waits in that player's queue
-- and runs as soon as it may, so a quick double click, a sequence of test
-- steps or Run every test never meets a silently ignored or rejected request.
LilBubbyPacer = LilBubbyPacer or { queues = {}, last = {} }
local Q = LilBubbyPacer

Q.LIMIT = 30 -- queued requests per player and suite; more is someone hammering

local function key(player, lane)
    local ok, name = pcall(function() return player:getUsername() end)
    return lane .. ":" .. tostring(ok and name or player)
end

local function drain(id, now)
    local queue = Q.queues[id]
    while queue and #queue.items > 0 and now - (Q.last[id] or -1000000) >= queue.gap do
        local fn = table.remove(queue.items, 1)
        Q.last[id] = now
        local ok, err = pcall(fn)
        if not ok then print("[LilBubbyPacer] " .. id .. " request failed: " .. tostring(err)) end
    end
    if queue and #queue.items == 0 then Q.queues[id] = nil end
end

-- Runs fn now, or after `gap` ms have passed since this player's previous
-- request in `lane`. Returns false only when the queue is full.
function Q.Run(player, lane, gap, fn)
    local id = key(player, lane)
    local queue = Q.queues[id]
    if not queue then
        queue = { gap = gap, items = {} }
        Q.queues[id] = queue
    end
    if #queue.items >= Q.LIMIT then
        print("[LilBubbyPacer] " .. id .. " queue full; request dropped")
        return false
    end
    queue.items[#queue.items + 1] = fn
    drain(id, getTimestampMs())
    return true
end

function Q.Pending(player, lane)
    local queue = Q.queues[key(player, lane)]
    return queue and #queue.items or 0
end

Events.OnTick.Add(function()
    local now
    for id in pairs(Q.queues) do
        now = now or getTimestampMs()
        drain(id, now)
    end
end)

return LilBubbyPacer
