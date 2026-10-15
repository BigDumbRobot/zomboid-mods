require "LilBubbyShowcase"
require "ISUI/ISContextMenu"
require "TimedActions/ISInventoryTransferAction"
require "SatanicTemplesTest_World"

-- Satanic Temples full test: builds a test temple beside the player and works
-- through every kind of sacrifice attempt -- rare items, recipes, animal
-- carcasses and heads, other players' corpses, your own corpse, junk, zombie
-- corpses, greed past the life's tiers, an empty altar, an unlit fire, standing
-- too far away -- and checks that no verdict is revealed before the ritual
-- ends, that walking away cannot escape wrath, that the altar smoke is harmless,
-- the skeletons' katanas, the theft punishment, the map toggle, the integrity
-- repair pass and the real Make a Sacrifice button with its full ritual.
-- A separate entry kills the character and checks the new one recovers.
-- World changes are made by the server in multiplayer (SatanicTemplesTest_Server.lua).
local MODULE = SatanicTemplesTest.MODULE
local results = {}
local runner = nil
local replies = {}
local nextId = 0
local NEW_LIFE = { forename = "Temple", surname = "Test" }

local function SO() return SacrificialOffering end

local function show(playerNum, text)
    results[playerNum] = text
    print("[" .. MODULE .. "] " .. text)
    LilBubbyShowcase.ReportIndex(playerNum, "satanic", text)
end

local function progress(player, text)
    LilBubbyShowcase.Report(player, "satanic", text, true)
    print("[" .. MODULE .. "] " .. text)
end

local function waitMs(ms)
    local deadline = getTimestampMs() + ms
    while getTimestampMs() < deadline do coroutine.yield() end
end

local function waitFor(ms, fn, what)
    local deadline = getTimestampMs() + ms
    local previous = LilBubbyStatus and LilBubbyStatus.notes[0]
    if what and LilBubbyStatus then LilBubbyStatus.Note(0, what) end
    local value
    while true do
        value = fn()
        if value or getTimestampMs() > deadline then break end
        coroutine.yield()
    end
    if what and LilBubbyStatus then LilBubbyStatus.notes[0] = previous end
    return value or nil
end

local OP_TEXT = { setup = "building the test temple", prepare = "setting up the altar", offer = "making the offering",
    busy = "making two offerings", state = "reading the temple", repair = "damaging and repairing the temple",
    relicReady = "healing you", heal = "healing you", cleanup = "removing the test temple" }

-- Runs a world operation where the world is authoritative.
local function op(player, name, args)
    args = args or {}
    if not isClient() then
        local ok, result = pcall(SatanicTemplesTest.World[name], player, args)
        if not ok then return { error = tostring(result) } end
        return result or {}
    end
    nextId = nextId + 1
    args.id = nextId
    sendClientCommand(player, MODULE, name, args)
    local id = nextId
    local reply = waitFor(20000, function() return replies[id] end, OP_TEXT[name] and ("Waiting for the server: " .. OP_TEXT[name]))
    replies[id] = nil
    return reply or { error = "no reply from the server in 20 s" }
end

-- Helpers ----------------------------------------------------------------------

-- Movement is the client's to make, in single player and multiplayer alike.
local function teleport(player, x, y, z)
    player:setX(x); player:setY(y); player:setZ(z)
    player:setLastX(x); player:setLastY(y); player:setLastZ(z)
end

-- Beside the altar, where a player stands to offer. dy moves further south.
local function stand(player, temple, dx, dy)
    teleport(player, temple.altar.x + 0.5 + (dx or 0), temple.altar.y + 1.5 + (dy or 0), temple.altar.z)
end

local function altarLoaded(temple)
    local a = temple.altar
    return getCell():getGridSquare(a.x, a.y, a.z) ~= nil
end

local function lastResult(state)
    for i = #(state.results or {}), 1, -1 do
        local r = state.results[i]
        if r.translation ~= "IGUI_SO_ZoneCreated" then return r end
    end
    return nil
end

local function has(list, fullType)
    for _, value in ipairs(list or {}) do if value == fullType then return true end end
    return false
end

local function orangeLights()
    local lamps, n = getCell():getLamppostPositions(), 0
    for i = 0, lamps:size() - 1 do
        local l = lamps:get(i)
        if math.abs(l:getR() - 1.0) < 0.01 and math.abs(l:getG() - 0.45) < 0.01 then n = n + 1 end
    end
    return n
end

local function clientSkeleton(pos)
    local sq = getCell():getGridSquare(pos.x, pos.y, pos.z)
    local objects = sq and sq:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        local o = objects:get(i)
        local md = o:getModData()
        if md.SO_Protected and md.SO_FixtureKind == "mannequin" then return o end
    end
end

local function makeOfferingButton(player, temple)
    local sq = getCell():getGridSquare(temple.altar.x, temple.altar.y, temple.altar.z)
    local objects = sq and sq:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        local o = objects:get(i)
        if o:getModData().SO_FixtureKind == "altar" then
            local h = ISLootWindowObjectControlHandler_SO_MakeOffering:new()
            h.object, h.container, h.playerObj, h.playerNum = o, o:getContainer(), player, player:getPlayerNum()
            return h
        end
    end
end

local function describe(before, after, r)
    return string.format("result=%s health %.0f->%.0f xp %.0f->%.0f altar=[%s]",
        r and r.translation or "none", before.health or -1, after.health or -1,
        before.xp or -1, after.xp or -1, table.concat(after.items or {}, ","))
end

-- One offering case: prepare the altar, make the offering, wait, read.
local function offering(player, temple, prepare, stage, waitAfter)
    stand(player, temple)
    local prep = op(player, "prepare", prepare)
    if prep.error then return nil, nil, prep.error end
    local before = op(player, "state", { since = prep.mark })
    local offer = op(player, "offer", { stage = stage or "both" })
    if offer.error then return nil, nil, offer.error end
    waitMs(waitAfter or 800)
    local after = op(player, "state", { since = prep.mark, tx = offer.tx })
    after.tx = offer.tx
    after.mark = prep.mark
    return before, after, nil, prep
end

-- Flows -------------------------------------------------------------------------

local WRATH_WAIT = 2500

local function flow(player)
    local report = SatanicTemplesTest.newReport("Satanic Temples test")
    local T = SO().TRANSLATION
    local wasInvisible = player:isInvisible()
    -- Zombies would muddy every health measurement; the tester is hidden from them.
    player:setInvisible(true)

    -- The showcase has moved you beside the designated test temple.
    progress(player, "Satanic Temples test: readying the designated test temple")
    local temple = op(player, "setup", {})
    if not report:check("Test temple ready", temple.error == nil, temple.error) then
        player:setInvisible(wasInvisible); return report
    end
    stand(player, temple)
    waitFor(15000, function() return altarLoaded(temple) end, "Waiting for the temple to load")
    waitMs(2500)

    -- The temple ---------------------------------------------------------------
    local state = op(player, "state", {})
    local skeletonsOk, parts = true, {}
    for i, s in ipairs(state.skeletons or {}) do
        local ok = not s.missing and s.script == "MannequinSkeleton01" and s.worn == 0 and s.katanas == 2 and s.items == 2
        skeletonsOk = skeletonsOk and ok
        parts[#parts + 1] = i .. ":" .. tostring(s.script) .. "/" .. tostring(s.katanas)
    end
    report:check("Three bare skeletons, two katanas each", skeletonsOk and #(state.skeletons or {}) == 3, table.concat(parts, " "))
    report:check("Jack-o'-lanterns placed around the altar", state.lanterns == state.lanternSpots and state.lanterns > 0,
        state.lanterns .. " of " .. tostring(state.lanternSpots))
    waitMs(2000)
    report:check("Jack-o'-lanterns glow", orangeLights() >= (state.lanternSpots or 1), orangeLights() .. " orange lights")

    -- The smoke that fills the altar during every ritual must not hurt anyone.
    progress(player, "Satanic Temples test: standing in the altar smoke")
    op(player, "heal", {})
    local h0 = player:getBodyDamage():getOverallBodyHealth()
    SO().Effects.Play({ effect = SO().EFFECT.WRATH_SMOKE, x = temple.altar.x, y = temple.altar.y, z = temple.altar.z })
    SO().Effects.Play({ effect = SO().EFFECT.TRANCE, x = math.floor(player:getX()), y = math.floor(player:getY()), z = temple.altar.z })
    waitMs(6000)
    local sq = player:getCurrentSquare()
    local burning = sq and sq:getProperties():has(IsoFlagType.burning)
    report:check("Altar smoke and ritual wisp are harmless",
        math.abs(player:getBodyDamage():getOverallBodyHealth() - h0) < 1 and not player:isOnFire() and not burning,
        string.format("health %.1f->%.1f onFire=%s squareBurning=%s", h0, player:getBodyDamage():getOverallBodyHealth(),
            tostring(player:isOnFire()), tostring(burning)))

    -- Nothing is revealed until the ritual ends -----------------------------------
    progress(player, "Satanic Temples test: a junk offering, ritual starting")
    local firstBeat
    local originalFirstBeat = SO().Sound.HandleFirstBeat
    SO().Sound.HandleFirstBeat = function(a) firstBeat = a and a.outcome; return originalFirstBeat(a) end
    local before, after, err = offering(player, temple, { items = { "Base.Plank" } }, "begin", 1500)
    SO().Sound.HandleFirstBeat = originalFirstBeat
    if err then report:error("Junk offering", err) else
        report:check("Junk offering: the denied sound starts, nothing else happens until the end",
            lastResult(after) == nil and has(after.items, "Base.Plank") and after.pending and after.pending.valid == false
                and (firstBeat == nil or firstBeat == SO().SOUND_OUTCOME.FAILURE),
            "cue=" .. tostring(firstBeat) .. " committed=" .. tostring(after.pending and after.pending.reason))
        local made = op(player, "offer", { stage = "make", tx = after.tx })
        waitMs(WRATH_WAIT)
        local done = op(player, "state", { since = after.mark })
        local r = lastResult(done)
        report:check("...and the wrath lands only when the ritual completes",
            made.error == nil and r and r.translation == T.WRATH and done.health < after.health and #done.items == 0,
            describe(after, done, r))
    end

    progress(player, "Satanic Temples test: a good offering, ritual starting")
    before, after, err = offering(player, temple, { death = "fake", items = { "Base.Katana" } }, "begin", 800)
    if err then report:error("Good offering", err) else
        local hidden = lastResult(after) == nil and has(after.items, "Base.Katana")
        op(player, "offer", { stage = "make", tx = after.tx })
        waitMs(800)
        local done = op(player, "state", { since = after.mark })
        local r = lastResult(done)
        report:check("Good offering: nothing revealed at the start, success at the end",
            hidden and r and r.translation == T.SUCCESS_ITEM and done.xp > before.xp, describe(before, done, r))
    end

    progress(player, "Satanic Temples test: walking away from a junk offering")
    before, after, err = offering(player, temple, { items = { "Base.Plank" } }, "abandon", WRATH_WAIT)
    if err then report:error("Walk away", err) else
        local r = lastResult(after)
        report:check("Walking away from a junk offering cannot escape the wrath",
            r and r.translation == T.WRATH and after.health < before.health and #after.items == 0, describe(before, after, r))
    end

    -- Refusals ----------------------------------------------------------------------
    local function refusal(name, prepare, expected, keeps, setup)
        progress(player, "Satanic Temples test: " .. name)
        if setup then setup() end
        local b, a, e = offering(player, temple, prepare, "both", 800)
        if e then report:error(name, e); return end
        local r = lastResult(a)
        report:check(name, r and r.translation == expected and (keeps == nil or has(a.items, keeps)), describe(b, a, r))
    end
    refusal("Empty altar is refused", {}, "IGUI_SO_AltarEmpty")
    refusal("Unlit campfire: refused, item kept", { fire = false, items = { "Base.Katana" } }, "IGUI_SO_FireNotLit", "Base.Katana")
    do
        progress(player, "Satanic Temples test: too far from the altar")
        stand(player, temple)
        local prep = op(player, "prepare", { items = { "Base.Katana" } })
        stand(player, temple, 0, 5)
        local offer = op(player, "offer", {})
        waitMs(800)
        local a = op(player, "state", { since = prep.mark })
        local r = lastResult(a)
        report:check("Too far from the altar: refused, item kept",
            offer.error == nil and r and r.translation == "IGUI_SO_TooFar" and has(a.items, "Base.Katana"), describe(a, a, r))
        stand(player, temple)
    end
    refusal("Rare item with nothing to recover: refused, item kept", { death = "none", items = { "Base.Katana" } },
        T.NO_RECOVERY, "Base.Katana")

    -- Successful offerings --------------------------------------------------------
    local function success(name, prepare, expected, extra)
        progress(player, "Satanic Temples test: " .. name)
        local b, a, e, prep = offering(player, temple, prepare, "both", 800)
        if e then report:error(name, e); return end
        local r = lastResult(a)
        local ok = r and (r.translation == expected or (expected == T.SUCCESS_CORPSE and r.translation == T.SUCCESS_CORPSE_PRIZE))
            and a.xp > b.xp and prep.made ~= false
        report:check(name, ok, describe(b, a, r) .. (extra and extra(a, r, prep) or ""))
    end
    success("Rare item (katana) restores XP", { death = "fake", items = { "Base.Katana" } }, T.SUCCESS_ITEM)
    success("Rare recipe (assault rifle + 3 magazines) restores XP",
        { items = { "Base.AssaultRifle", "Base.556Clip", "Base.556Clip", "Base.556Clip" } }, T.SUCCESS_ITEM)
    success("Animal carcass beside the altar restores XP", { death = "fake", animal = "cow" }, T.SUCCESS_ITEM,
        function(a, r, prep) return " animal=" .. tostring(prep.animal) end)
    success("Animal head restores XP", { items = { "Base.Cow_Head_Angus" } }, T.SUCCESS_ITEM)
    success("Another player's corpse: full recovery", { death = "fake", corpse = "victim" }, T.SUCCESS_CORPSE,
        function(a, r) return " strength=" .. tostring(r and r.strength) end)
    success("Same victim's corpse in a later life: still accepted", { death = "fake", corpse = "victim" }, T.SUCCESS_CORPSE,
        function(a, r) return " strength=" .. tostring(r and r.strength) .. " victimUses=" .. tostring(a.victimUses) end)

    -- Punishments -----------------------------------------------------------------
    local function wrath(name, prepare, expected, extra)
        progress(player, "Satanic Temples test: " .. name)
        local b, a, e, prep = offering(player, temple, prepare, "both", WRATH_WAIT)
        if e then report:error(name, e); return end
        local r = lastResult(a)
        local lost = (b.health or 0) - (a.health or 0)
        local ok = r and r.translation == expected and #a.items == 0 and lost > 0
        local detail = describe(b, a, r) .. string.format(" rolled=%s lost=%.0f", tostring(r and r.damage), lost)
        if extra then
            local more, text = extra(a, r, lost)
            ok = ok and more
            detail = detail .. (text or "")
        end
        report:check(name, ok, detail)
        op(player, "heal", {})
    end
    local function lossMatchesRoll(a, r, lost)
        -- The loss is the roll plus the injuries' own bleeding at most, never a
        -- death from full health.
        return not a.dead and r and r.damage and lost <= r.damage + 15, ""
    end
    wrath("Rare item past the life's full recovery: greed wrath", { death = "fake", redeemed = 100, items = { "Base.Sledgehammer" } },
        T.WRATH, function(a, r, lost)
            local ok = lossMatchesRoll(a, r, lost)
            return ok and r.greed ~= nil, " greed=" .. tostring(r and r.greed)
        end)
    wrath("Animal offering past the animal cap: minor greed wrath",
        { death = "fake", redeemed = SO().Sandbox.RecoveryStrength("item"), items = { "Base.Cow_Head_Angus" } },
        T.MINOR_WRATH, function(a, r, lost)
            local ok = lossMatchesRoll(a, r, lost)
            return ok and r.greed ~= nil, " greed=" .. tostring(r and r.greed)
        end)
    wrath("Animal head mixed with junk: wrath", { death = "fake", items = { "Base.Cow_Head_Angus", "Base.Nails" } }, T.WRATH, lossMatchesRoll)
    wrath("Junk item (plank): wrath within its damage range", { items = { "Base.Plank" } }, T.WRATH, function(a, r, lost)
        local ok = lossMatchesRoll(a, r, lost)
        local lo, hi = SO().Sandbox.WrathRange()
        return ok and r.damage >= lo and r.damage <= hi, string.format(" range=%d-%d", lo, hi)
    end)
    wrath("Zombie corpse: wrath", { corpse = "zombie" }, T.WRATH, lossMatchesRoll)
    wrath("Own corpse: self-corpse punishment with broken bones", { corpse = "self" }, T.SELF_CORPSE,
        function(a) return not a.dead and a.fractures > 0, " fractures=" .. tostring(a.fractures) end)

    progress(player, "Satanic Temples test: a second offering while a verdict is due")
    stand(player, temple)
    op(player, "prepare", { items = { "Base.Plank" } })
    local busy = op(player, "busy", {})
    report:check("Second offering while a verdict is due: altar busy", busy.busy == true, busy.error or tostring(busy.busy))
    waitMs(WRATH_WAIT)
    op(player, "heal", {})

    -- The skeletons' katanas --------------------------------------------------------
    progress(player, "Satanic Temples test: trying to take a skeleton's katana")
    op(player, "relicReady", {})
    local pos = temple.mannequins[2]
    teleport(player, pos.x + 1.5, pos.y + 0.5, pos.z)
    waitMs(500)
    local skeleton = clientSkeleton(pos)
    local flashes = 0
    local originalFlash = SO().Lightning.Play
    SO().Lightning.Play = function(a) flashes = flashes + 1; return originalFlash(a) end
    local b = op(player, "state", {})
    local takeValid = skeleton and ISInventoryTransferAction:new(player, skeleton:getContainer():getItems():get(0),
        skeleton:getContainer(), player:getInventory()):isValid()
    waitMs(2000)
    SO().Lightning.Play = originalFlash
    local a = op(player, "state", {})
    local lostPct = b.health > 0 and (b.health - a.health) / b.health * 100 or 0
    -- Exactly half is taken; the deep wounds then bleed a little before the read.
    report:check("Katana theft: refused, lightning flash, half your health, deep wounds",
        skeleton ~= nil and takeValid == false and flashes == 1 and lostPct >= 49 and lostPct <= 65 and a.deep >= 2
            and a.skeletons[2] and a.skeletons[2].katanas == 2,
        string.format("allowed=%s flashes=%d lost=%.1f%% deep=%d katanasLeft=%s", tostring(takeValid), flashes, lostPct,
            a.deep or -1, tostring(a.skeletons[2] and a.skeletons[2].katanas)))
    op(player, "heal", {})
    stand(player, temple)

    -- Map --------------------------------------------------------------------------
    local map = SO().WorldMapIntegration
    local wasShowing = map.Showing
    map.Showing = false
    map.Toggle({})
    report:check("World map: temples can be shown, and the toggle survives a respawn",
        map.Showing == true and #(SO().Client.Zones or {}) >= 1, "zones known=" .. #(SO().Client.Zones or {}))
    map.Showing = wasShowing

    -- Integrity pass -----------------------------------------------------------------
    progress(player, "Satanic Temples test: damaging the temple and letting it repair")
    local fix = op(player, "repair", {})
    report:check("Integrity pass restocks katanas, converts an old mannequin and replaces pumpkins, once",
        fix.error == nil and fix.katanas == 2 and fix.script == "MannequinSkeleton01" and fix.m3katanas == 2
            and fix.lantern == 1 and fix.lanternSpots > 0 and fix.secondPassKatanas == 2 and fix.secondPassLantern == 1,
        fix.error or string.format("katanas=%s script=%s pumpkin=%s second pass: katanas=%s pumpkin=%s",
            tostring(fix.katanas), tostring(fix.script), tostring(fix.lantern), tostring(fix.secondPassKatanas),
            tostring(fix.secondPassLantern)))

    -- The real button and ritual -------------------------------------------------------
    progress(player, "Satanic Temples test: the Make a Sacrifice button and the full ritual (about a minute)")
    stand(player, temple)
    local prep = op(player, "prepare", { death = "fake", items = { "Base.Katana" } })
    waitMs(1000)
    local button = makeOfferingButton(player, temple)
    local visible = button and button:shouldBeVisible()
    b = op(player, "state", { since = prep.mark })
    if button then button:perform() end
    local finished = waitFor(70000, function()
        local s = op(player, "state", { since = prep.mark })
        return lastResult(s) and s
    end, "The ritual is running: stay put")
    local r = finished and lastResult(finished)
    report:check("Make a Sacrifice button and full ritual: XP restored at the end",
        visible and r and r.translation == T.SUCCESS_ITEM and finished.xp > b.xp,
        "buttonVisible=" .. tostring(visible) .. " " .. describe(b, finished or b, r))

    progress(player, "Satanic Temples test: breaking a ritual by walking away")
    stand(player, temple)
    prep = op(player, "prepare", { death = "fake", items = { "Base.Katana" } })
    waitMs(1000)
    b = op(player, "state", { since = prep.mark })
    button = makeOfferingButton(player, temple)
    if button then button:perform() end
    waitMs(6000)
    stand(player, temple, 0, 6)
    waitMs(3000)
    a = op(player, "state", { since = prep.mark })
    report:check("Walking away from a good offering breaks it: nothing taken, nothing given",
        not SO_OfferingRitualAction.IsActive(player) and has(a.items, "Base.Katana") and a.xp == b.xp and lastResult(a) == nil,
        describe(b, a, lastResult(a)))

    op(player, "prepare", { clear = true })
    stand(player, temple)
    player:setInvisible(wasInvisible)
    report:info("Look around", "The test temple stays beside you with its campfire lit. "
        .. "Clean up my test temple removes it and everything in it.")
    return report
end

local function respawn(report, deadPlayer, playerNum)
    waitFor(15000, function() return ISPostDeathUI.instance and ISPostDeathUI.instance[playerNum] end,
        "Waiting for the death screen to open")
    local ok, err = pcall(function() ISPostDeathUI.instance[playerNum]:onRespawn() end)
    local creation = ok and waitFor(20000, function() return CoopCharacterCreation.instance end,
        "Pressing Respawn: waiting for character creation to open")
    if creation then
        waitFor(5000, function() return CoopMapSpawnSelect.instance end, "Waiting for the spawn selection")
        ok, err = pcall(function()
            CoopMapSpawnSelect.instance:useDefaultSpawnRegion()
            creation.charCreationMain.forenameEntry:setText(NEW_LIFE.forename)
            creation.charCreationMain.surnameEntry:setText(NEW_LIFE.surname)
            creation:accept()
        end)
    end
    if not ok or not creation then
        report:info("Automatic respawn unavailable", tostring(err or "character creation did not open")
            .. ". Create your new character yourself; the test continues when it spawns.")
    end
    return waitFor(600000, function()
        local candidate = getSpecificPlayer(playerNum)
        return candidate and candidate ~= deadPlayer and not candidate:isDead() and candidate
    end, (ok and creation) and "Creating the new character and waiting for it to spawn"
        or "Create your new character yourself: the test continues when it spawns")
end

-- Dies to the Dark Lord's wrath, respawns, and recovers the lost skill at the altar.
local function deathFlow(player)
    local report = SatanicTemplesTest.newReport("Satanic Temples death and recovery")
    local T = SO().TRANSLATION
    local playerNum = player:getPlayerNum()
    player:setInvisible(true)
    local temple = op(player, "setup", {})
    if not report:check("Test temple ready", temple.error == nil, temple.error) then return report end
    stand(player, temple)
    waitFor(15000, function() return altarLoaded(temple) end, "Waiting for the temple to load")

    progress(player, "Satanic Temples death test: offering junk while badly hurt")
    local prep = op(player, "prepare", { items = { "Base.Plank" }, xpBoost = 3000, reduceHealth = 92 })
    local before = op(player, "state", { since = prep.mark })
    op(player, "offer", {})
    local died = waitFor(20000, function() return player:isDead() end, "The Dark Lord's wrath is landing")
    if not report:check("Wrath kills a badly hurt player", died == true, string.format("health %.0f", before.health or -1)) then
        return report
    end
    local newPlayer = respawn(report, player, playerNum)
    if not report:check("New character spawned", newPlayer ~= nil, "no new character within 10 minutes") then return report end
    newPlayer:setInvisible(true)
    stand(newPlayer, temple)
    waitFor(30000, function() return altarLoaded(temple) end, "Bringing you back to the temple")
    waitMs(2000)
    prep = op(newPlayer, "prepare", { items = { "Base.Katana" } })
    local b = op(newPlayer, "state", { since = prep.mark })
    op(newPlayer, "offer", {})
    waitMs(1000)
    local a = op(newPlayer, "state", { since = prep.mark })
    local r = lastResult(a)
    report:check("The new character recovers the lost skill at the altar",
        r and r.translation == T.SUCCESS_ITEM and a.xp > b.xp,
        describe(b, a, r) .. " identity before=" .. tostring(before.identity) .. " after=" .. tostring(a.identity))
    newPlayer:setInvisible(false)
    return report
end

local function cleanupFlow(player)
    local report = SatanicTemplesTest.newReport("Satanic Temples cleanup")
    local reply = op(player, "cleanup", {})
    report:check("Test temple cleared for the next player", reply.error == nil,
        reply.error or (reply.cleared and "the designated temple stays" or "there is no test temple"))
    return report
end

-- Reads the test temple without changing anything.
local function inspect(player)
    local report = SatanicTemplesTest.newReport("My test temple")
    local state = op(player, "state", {})
    if state.error then
        report:info("Temple", state.error)
    else
        for i, s in ipairs(state.skeletons or {}) do
            report:info("Skeleton " .. i, s.missing and "missing" or (tostring(s.script) .. ", " .. s.katanas .. " katana(s)"))
        end
        report:info("Jack-o'-lanterns", state.lanterns .. " of " .. tostring(state.lanternSpots))
        report:info("On the altar", #state.items > 0 and table.concat(state.items, ", ") or "nothing")
    end
    show(player:getPlayerNum(), report:text())
end

-- Runner ------------------------------------------------------------------------

local function stepRunner()
    if not runner then return end
    local ok, result = coroutine.resume(runner.co)
    if not ok then
        runner.report = runner.report or SatanicTemplesTest.newReport("Satanic Temples test")
        runner.report:error("Test error", tostring(result))
        result = runner.report
    end
    if not ok or coroutine.status(runner.co) == "dead" then
        local playerNum = runner.playerNum
        runner = nil
        show(playerNum, result and result:text() or "Satanic Temples test ended without a report.")
    end
end

local function start(player, fn)
    if runner then
        show(player:getPlayerNum(), "A Satanic Temples test is already running.")
        return
    end
    if player:getVehicle() then
        show(player:getPlayerNum(), "BLOCKED: Exit your vehicle first.")
        return
    end
    runner = { co = coroutine.create(fn), playerNum = player:getPlayerNum() }
    local ok, result = coroutine.resume(runner.co, player)
    if not ok or coroutine.status(runner.co) == "dead" then
        local playerNum = runner.playerNum
        runner = nil
        show(playerNum, ok and result:text() or ("ERROR: " .. tostring(result)))
    end
end

local function submenu(context, label)
    local option = context:getOptionFromName(label)
    if option and option.subOption then return context:getSubMenu(option.subOption) end
    option = option or context:addOption(label)
    local menu = LilBubbyShowcase.NewMenu()
    context:addSubMenu(option, menu)
    return menu
end

LilBubbyShowcase.Register("satanic", function(index, context, objects, test)
    if test or not SatanicTemplesTest.available() then return end
    local player = getSpecificPlayer(index)
    if not player or player:isDead() then return end
    local tester = submenu(context, "lilBubby's Big ol Mod Tester")
    local suite = submenu(tester, "Satanic Temples tests")
    -- Moves you to the designated test temple, spawns corpses and a carcass, and hurts you.
    suite:addOption("Run the full Satanic Temples test (at the designated test temple)", player, function(p) start(p, flow) end).site = "temple"
    -- Kills your character, respawns a new one and recovers its skill.
    suite:addOption("Die and recover at the altar (kills your character)", player, function(p) start(p, deathFlow) end).site = "temple"
    suite:addOption("Check my test temple", player, inspect)
    suite:addOption("Clean up my test temple", player, function(p) start(p, cleanupFlow) end)
    suite:addOption("Show last result", player, function(p)
        show(p:getPlayerNum(), results[p:getPlayerNum()] or "The full test builds a test temple beside you and works "
            .. "through every kind of sacrifice, the skeletons' katanas, the map, the repair pass and a full ritual.")
    end)
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE or command ~= "reply" or type(args) ~= "table" or not args.id then return end
    replies[args.id] = args
end)

Events.OnTickEvenPaused.Add(stepRunner)
Events.OnFETick.Add(stepRunner)
