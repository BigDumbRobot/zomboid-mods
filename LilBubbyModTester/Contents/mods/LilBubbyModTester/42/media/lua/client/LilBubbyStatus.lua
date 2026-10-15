require "ISUI/ISUIElement"

-- A banner at the top of the screen for as long as a test runs, so the player
-- can always tell the test is working and what it is doing:
--   title:  which test, a spinner and the total running time
--   big:    the current step (the suite's latest progress message), or
--           "Test will begin in N..." while a start is held up
--   small:  what is happening this moment, with how long it has taken:
--           travelling, crafting, your character's timed action, a note from
--           the suite, or waiting for the server's answer
-- It never delays anything; it only describes what is already going on.
LilBubbyStatus = LilBubbyStatus or {}
local St = LilBubbyStatus

St.GRACE_MS = 750     -- a test or countdown that ends sooner never shows
St.FINISHED_MS = 3000 -- how long "Test finished" stays up
St.SERVER_MS = 500    -- a server answer slower than this is shown as a wait
St.runs = St.runs or {}
St.countdowns = St.countdowns or {}
St.pending = St.pending or {}
St.notes = St.notes or {}

local function nowMs()
    local ok, ms = pcall(function() return getTimestampMs() end)
    if ok and type(ms) == "number" then return ms end
    return os.time() * 1000
end

local function firstLine(text)
    return (tostring(text or ""):match("^%s*([^\n]*)") or ""):gsub("%s+$", "")
end

local function suiteName(id)
    local mod = LilBubbyShowcase and LilBubbyShowcase.ModById and LilBubbyShowcase.ModById(id)
    return mod and mod.name or tostring(id)
end

------------------------------------------------------------
-- What is going on (called by the showcase, the suites and the helpers)
------------------------------------------------------------

-- A test was started from the showcase (or by Run every test).
function St.Begin(index, id, name)
    local now = nowMs()
    St.runs[index] = { id = id, name = name, since = now, step = "Starting " .. tostring(name), stepSince = now }
    St.notes[index] = nil
    St.finished = nil
end

-- A progress message: the new current step.
function St.Step(index, id, text)
    local line = firstLine(text)
    if line == "" or line:find("^STARTED:") then return end
    local run = St.runs[index]
    if not run then
        -- Run every test reports its own steps between tests.
        if not (LilBubbyAutoRun and LilBubbyAutoRun.Running and LilBubbyAutoRun.Running()) then return end
        run = { id = id, name = suiteName(id), since = nowMs(), auto = true }
        St.runs[index] = run
    end
    run.step, run.stepSince = line, nowMs()
    St.notes[index] = nil
end

-- A result for the running test: the test is over.
function St.End(index, id, text)
    local run = St.runs[index]
    if not run or (run.id ~= id and not run.auto) then return end
    local now = nowMs()
    St.runs[index] = nil
    St.notes[index] = nil
    St.pending[index] = nil
    if now - run.since >= St.GRACE_MS then
        local verdict = firstLine(text):match("^(%u+)") or ""
        St.finished = { index = index, name = run.name, verdict = verdict, untilMs = now + St.FINISHED_MS }
    end
end

-- A suite describing a wait it is in the middle of ("Waiting for the zombie
-- to land"). nil clears it. Cleared automatically by the next step.
function St.Note(player, text)
    local index = type(player) == "number" and player or (player and player.getPlayerNum and player:getPlayerNum()) or 0
    St.notes[index] = text and { text = text, since = nowMs() } or nil
end

-- Command traffic: a request is outstanding until the server answers.
function St.Sent(index, module, command)
    St.pending[index] = { command = tostring(command), since = nowMs() }
end

function St.Received(index)
    St.pending[index] = nil
end

-- A real deadline the player has to act on: at zero the test gives up, so
-- the seconds mean something. Never used for "something might happen soon".
function St.Countdown(key, seconds, label)
    local now = nowMs()
    St.countdowns[key] = { untilMs = now + seconds * 1000, showMs = now, label = label }
end

function St.StopCountdown(key)
    St.countdowns[key] = nil
end

------------------------------------------------------------
-- Describing the moment
------------------------------------------------------------

local ACTIONS = { ISReadABook = "reading", ISHandcraftAction = "crafting", ISBuildIsoEntity = "building",
    ISBuildAction = "building", ISWalkToTimedAction = "walking", ISEnterVehicle = "getting into the vehicle",
    ISInventoryTransferAction = "moving items", ISGrabItemAction = "picking up items" }

-- ISReadABook -> "reading"; anything else ISSomeThingAction -> "Some Thing"
local function humanize(kind)
    kind = tostring(kind or "")
    if ACTIONS[kind] then return ACTIONS[kind] end
    kind = kind:gsub("^IS", ""):gsub("TimedAction$", ""):gsub("Action$", "")
    kind = kind:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2")
    return kind
end

local function timedAction(player)
    if not (ISTimedActionQueue and ISTimedActionQueue.getTimedActionQueue) then return end
    local ok, text = pcall(function()
        local queue = ISTimedActionQueue.getTimedActionQueue(player)
        local action = queue and queue.queue and queue.queue[1]
        if not action then return end
        local what = humanize(action.Type)
        if action.item and action.item.getDisplayName then what = what .. ": " .. action.item:getDisplayName() end
        local delta = action.action and action.action.getJobDelta and action.action:getJobDelta()
        local left = #queue.queue - 1
        return "Your character is busy (" .. what .. ")"
            .. (delta and delta > 0 and string.format(", %d%% done", math.floor(delta * 100)) or "")
            .. (left > 0 and (", " .. left .. " more queued") or "")
    end)
    return ok and text or nil
end

-- The most specific description of what is happening right now, and since when.
function St.Detail(index, player, now)
    local T = LilBubbyTeleport
    local travel = T and T.travels and player and T.travels[player]
    if travel then
        local ok, left = pcall(function()
            local dx, dy = travel.x + 0.5 - player:getX(), travel.y + 0.5 - player:getY()
            return math.sqrt(dx * dx + dy * dy)
        end)
        if ok and travel.hop then
            return string.format("Travelling to the test spot: %d tiles to go (short hops keep the server's anti-cheat happy)",
                math.floor(left))
        end
        return "Teleporting to the test spot"
    end
    if player and player.isDead and player:isDead() then
        return "Waiting for your new character (create one if the respawn screen stays up)"
    end
    local job = LilBubbyCraft and LilBubbyCraft.jobs and player and LilBubbyCraft.jobs[player]
    if job then
        if job.waiting then return "Waiting for the ingredients to reach your inventory", job.since end
        local action = timedAction(player)
        return "Crafting " .. tostring(job.output) .. (job.attempts > 1 and (" (attempt " .. job.attempts .. ")") or "")
            .. (action and (": " .. action:gsub("^Your character is busy ", "")) or ""), job.since
    end
    local action = player and timedAction(player)
    if action then return action end
    local note = St.notes[index]
    if note then return note.text, note.since end
    local pending = St.pending[index]
    if pending and now - pending.since >= St.SERVER_MS then
        return "Waiting for the server to answer (" .. pending.command .. ")", pending.since
    end
end

------------------------------------------------------------
-- The banner
------------------------------------------------------------

local function activeCountdown(now)
    local entry
    for _, e in pairs(St.countdowns) do
        if now >= e.showMs and (not entry or e.untilMs < entry.untilMs) then entry = e end
    end
    return entry
end

local function autoRunning()
    return LilBubbyAutoRun and LilBubbyAutoRun.Running and LilBubbyAutoRun.Running() or false
end

-- What the banner shows now, or nil to hide it. Split out so it can be checked
-- without the game's UI.
function St.Lines(index, player, now)
    local run = St.runs[index]
    local countdown = activeCountdown(now)
    if run and not run.auto and now - run.since < St.GRACE_MS and not countdown then run = nil end
    if not run and not countdown and not autoRunning() then
        local done = St.finished
        if done and done.index == index and now < done.untilMs then
            return { title = "lilBubby test finished: " .. tostring(done.name),
                big = "Test finished" .. (done.verdict ~= "" and (": " .. done.verdict) or ""),
                small = "Results are in the strip in the bottom-left corner", verdict = done.verdict }
        end
        return nil
    end
    local spinner = ({ "|", "/", "-", "\\" })[math.floor(now / 250) % 4 + 1]
    local title = "lilBubby test running " .. spinner
    if autoRunning() then title = "Run every test " .. spinner end
    if run then title = title .. "  " .. tostring(run.name) end
    local lines = { title = title }
    if countdown then
        -- A deadline on the player: the seconds are the time left to act.
        lines.big = countdown.label
        lines.small = "You have " .. math.max(0, math.ceil((countdown.untilMs - now) / 1000)) .. " seconds"
        return lines
    end
    lines.big = run and run.step or "Getting the next test ready"
    lines.small = St.Detail(index, player, now) or "Working on this step"
    return lines
end

-- Without the game's UI (offline checks) the tracking above still works.
if not ISUIElement then return LilBubbyStatus end

St.Banner = ISUIElement:derive("LilBubbyStatusBanner")
local B = St.Banner

function B:new()
    local width = math.min(900, getCore():getScreenWidth() - 40)
    local o = ISUIElement.new(self, math.floor((getCore():getScreenWidth() - width) / 2), 40, width, 110)
    o.anchorTop = true
    return o
end

function B:onMouseDown() return false end
function B:isMouseOver() return false end

local function fit(font, text, width)
    local manager = getTextManager()
    if manager:MeasureStringX(font, text) <= width then return text end
    while #text > 0 and manager:MeasureStringX(font, text .. "...") > width do text = text:sub(1, -2) end
    return text .. "..."
end

function B:render()
    local index = 0
    local lines = St.Lines(index, getSpecificPlayer(index), nowMs())
    if not lines then return end
    local manager = getTextManager()
    local big = UIFont.Large
    local hSmall, hBig = manager:getFontHeight(UIFont.Small), manager:getFontHeight(big)
    local hMedium = manager:getFontHeight(UIFont.Medium)
    local inner = self.width - 40
    local texts = { fit(UIFont.Small, lines.title, inner), fit(big, lines.big, inner),
        lines.small and fit(UIFont.Medium, lines.small, inner) or nil }
    local width = 0
    width = math.max(manager:MeasureStringX(UIFont.Small, texts[1]), manager:MeasureStringX(big, texts[2]),
        texts[3] and manager:MeasureStringX(UIFont.Medium, texts[3]) or 0) + 40
    local height = 12 + hSmall + 4 + hBig + (texts[3] and (4 + hMedium) or 0) + 12
    local left, centre = (self.width - width) / 2, self.width / 2
    local border = { 0.65, 0.5, 0.95 }
    if lines.verdict == "PASS" then border = { 0.45, 0.88, 0.45 }
    elseif lines.verdict and lines.verdict ~= "" then border = { 1, 0.42, 0.42 } end
    self:drawRect(left, 0, width, height, 0.7, 0, 0, 0)
    self:drawRectBorder(left, 0, width, height, 0.9, border[1], border[2], border[3])
    local y = 12
    self:drawTextCentre(texts[1], centre, y, 0.8, 0.72, 1, 1, UIFont.Small)
    y = y + hSmall + 4
    self:drawTextCentre(texts[2], centre, y, 1, 0.95, 0.6, 1, big)
    y = y + hBig + 4
    if texts[3] then self:drawTextCentre(texts[3], centre, y, 0.88, 0.88, 0.88, 1, UIFont.Medium) end
end

-- One banner, added on the first tick and always on top; it draws nothing
-- when no test is running.
if Events and Events.OnTick then
    Events.OnTick.Add(function()
        if St.instance then
            -- Keep it above windows opened later.
            if St.Lines(0, getSpecificPlayer(0), nowMs()) then St.instance:bringToTop() end
            return
        end
        St.instance = B:new()
        St.instance:initialise()
        St.instance:addToUIManager()
    end)
end

return LilBubbyStatus
