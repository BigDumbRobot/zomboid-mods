require "LilBubbyStatus"

-- "Test will begin in N...", shown in the status banner while a start is
-- held up (ingredients or materials still on their way). It never delays
-- anything and stays hidden for a hold-up that ends within a moment.
LilBubbyCountdown = LilBubbyCountdown or {}
local C = LilBubbyCountdown

function C.Start(key, seconds, label) LilBubbyStatus.Countdown(key, seconds, label) end
function C.Stop(key) LilBubbyStatus.StopCountdown(key) end

-- Drop a countdown whose time ran out without a Stop.
if Events and Events.OnTick then
    Events.OnTick.Add(function()
        local now
        for key, entry in pairs(LilBubbyStatus.countdowns) do
            now = now or getTimestampMs()
            if now > entry.untilMs + 1000 then C.Stop(key) end
        end
    end)
end

return LilBubbyCountdown
