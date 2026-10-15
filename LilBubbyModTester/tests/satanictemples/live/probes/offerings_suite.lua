-- Satanic Temples: every sacrifice attempt type, run live in single-player.
-- Starts an OnTick-paced sequence; each case prints
--   [STOffer] PASS|FAIL | <case> | <detail>
-- and the run ends with [STOffer] DONE pass=N fail=M. The temple is left
-- standing with a lit campfire so a person can make offerings afterwards.
STProbeResult = (function()
    local SO = SacrificialOffering
    local L = {}
    STOffer = L

    local WOODWORK = tostring(Perks.Woodwork)
    local VICTIM = "user:harnessvictim"

    -- Record every result the server sends (SP: SendResult calls the client directly).
    L.results = {}
    if not STOfferOrigSendResult then STOfferOrigSendResult = SO.ZoneService.SendResult end
    SO.ZoneService.SendResult = function(player, resultType, translation, fields)
        L.results[#L.results + 1] = { type = resultType, translation = translation, fields = fields or {} }
        return STOfferOrigSendResult(player, resultType, translation, fields)
    end

    local function p() return getPlayer() end
    local function record() return SO.Storage.GetPlayer(SO.PlayerLedger.GetIdentity(p())) end
    local function woodXP() return p():getXp():getXP(Perks.Woodwork) end
    local function health() return p():getBodyDamage():getOverallBodyHealth() end

    ------------------------------------------------------------------ temple
    local function ensureZone()
        local zones = SO.Storage.Get().zones
        if #zones > 0 then return zones[1] end
        local cell = getCell()
        local px, py = math.floor(p():getX()), math.floor(p():getY())
        local function clear(x, y)
            local sq = cell:getGridSquare(x, y, 0)
            return sq and sq:isOutside() and sq:getFloor() and not sq:isSolid() and not sq:isSolidTrans() and sq:isFree(false)
        end
        local function ok(x, y)
            for dx = -6, 6 do for dy = -14, 0 do if not clear(x + dx, y + dy) then return false end end end
            return true
        end
        for r = 0, 60 do
            for dx = -r, r do for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r and ok(px + dx, py + dy) then
                    local x, y = px + dx, py + dy
                    p():setX(x + 0.5); p():setY(y + 0.5); p():setLastX(x + 0.5); p():setLastY(y + 0.5)
                    SO.ZoneService.Create(p(), { x1 = x - 6, y1 = y - 14, x2 = x + 7, y2 = y - 1, name = "Live Test Temple" })
                    return SO.Storage.Get().zones[1]
                end
            end end
        end
        return nil
    end
    local zone = ensureZone()
    if not zone or not zone.fixtures then return "no temple could be created" end
    L.zone = zone
    local front = zone.fixtures.altar
    local back = zone.fixtures.altarBack

    local function containers()
        local fo = SO.Fixtures.FindTaggedObject(front.x, front.y, front.z, SO.FIXTURE.ALTAR)
        local bo = SO.Fixtures.FindTaggedObject(back.x, back.y, back.z, SO.FIXTURE.ALTAR_BACK)
        return fo and fo:getContainer(), bo and bo:getContainer(), fo
    end
    local function altarCount()
        local a, b = containers()
        return (a and a:getItems():size() or 0) + (b and b:getItems():size() or 0)
    end
    local function altarHas(fullType)
        local a, b = containers()
        local shortType = (fullType:gsub("^Base%.", ""))
        return (a and a:containsType(shortType)) or (b and b:containsType(shortType)) or false
    end
    local function nearAltarSquares(fn)
        for _, c in ipairs({ front, back }) do
            for dx = -1, 1 do for dy = -1, 1 do
                local sq = getCell():getGridSquare(c.x + dx, c.y + dy, c.z)
                if sq then fn(sq) end
            end end
        end
    end
    local function clearAltar()
        local a, b = containers()
        for _, c in ipairs({ a, b }) do
            if c then while c:getItems():size() > 0 do c:DoRemoveItem(c:getItems():get(0)) end end
        end
        nearAltarSquares(function(sq)
            local bodies = sq:getStaticMovingObjects()
            for i = bodies:size() - 1, 0, -1 do
                local o = bodies:get(i)
                if instanceof(o, "IsoDeadBody") then sq:removeCorpse(o, false) end
            end
        end)
    end
    local function add(fullType, n)
        local a = containers()
        for _ = 1, n or 1 do a:AddItem(fullType) end
    end
    local function fire(lit)
        local c = zone.fixtures.campfire
        local cf = SCampfireSystem.instance:getLuaObjectAt(c.x, c.y, c.z)
        if not cf then return false end
        if lit then
            cf:setFuel(600)
            cf:lightFire()
        else
            cf:putOut()
        end
        return cf.isLit == lit
    end
    local function stand(dx, dy)
        local x, y = front.x + 0.5 + (dx or 0), front.y + 1.5 + (dy or 0)
        p():setX(x); p():setY(y); p():setZ(front.z); p():setLastX(x); p():setLastY(y); p():setLastZ(front.z)
    end
    local function heal() p():getBodyDamage():RestoreToFullHealth() end

    ------------------------------------------------------------------ ledger
    -- A fresh life with `xp` Carpentry XP lost to the previous death.
    local function fakeDeath(xp)
        local rec = record()
        rec.lastDeathMs = 0
        SO.PlayerLedger.RecordDeath(p(), "harness")
        rec.awaitingRespawn = false
        rec.bestXP[WOODWORK] = woodXP() + (xp or 5000)
    end
    -- Nothing lost: every personal best equals the current XP.
    local function noGap()
        local current = SO.PlayerLedger.ReadXP(p())
        local rec = record()
        rec.lastDeathMs = 0
        SO.PlayerLedger.RecordDeath(p(), "harness")
        rec.awaitingRespawn = false
        for k, v in pairs(current) do rec.bestXP[k] = v end
    end

    ------------------------------------------------------------------ corpses
    local function spawnZombieBody(x, y, z)
        local list = addZombiesInOutfit(x, y, z, 1, nil, 0)
        local zombie = list and list:size() > 0 and list:get(0)
        if not zombie then return nil end
        local body = IsoDeadBody.new(zombie, false)
        pcall(function() zombie:removeFromWorld(); zombie:removeFromSquare() end)
        return body
    end
    -- Human corpse item in the altar. owner=nil -> plain zombie corpse.
    local function addHumanCorpse(owner)
        local sq = getCell():getGridSquare(front.x + 2, front.y + 1, front.z)
        local body = spawnZombieBody(sq:getX(), sq:getY(), sq:getZ())
        if not body then return false end
        if owner then
            local md = body:getModData()
            md[SO.MOD_DATA.CORPSE_OWNER] = owner
            md[SO.MOD_DATA.CORPSE_ONLINE_ID] = -1
            md[SO.MOD_DATA.CORPSE_PLAYER_NAME] = owner == VICTIM and "Harness Victim" or "Myself"
        end
        local item = body:getItem()
        if owner then
            local imd = item:getModData()
            imd[SO.MOD_DATA.CORPSE_OWNER] = owner
            imd[SO.MOD_DATA.CORPSE_ONLINE_ID] = -1
            pcall(function() item:storeInByteData(body) end)
        end
        body:getSquare():removeCorpse(body, false)
        local a = containers()
        a:AddItem(item)
        return true
    end
    -- Intact animal carcass on the ground beside the altar.
    local function addAnimalCarcass(preferred)
        local defs = getAllAnimalsDefinitions()
        local def
        for i = 0, defs:size() - 1 do
            local d = defs:get(i)
            if d:getAnimalType() == preferred then def = d end
        end
        def = def or defs:get(0)
        local breed = def:getBreeds():get(0)
        local x, y, z = front.x + 1, front.y, front.z
        local animal = addAnimal(getCell(), x, y, z, def:getAnimalType(), breed, false)
        animal:addToWorld()
        local body = IsoDeadBody.new(animal, false)
        pcall(function() animal:removeFromWorld(); animal:removeFromSquare() end)
        return body ~= nil, def:getAnimalType()
    end

    ------------------------------------------------------------------ offering
    local seq = 0
    local function args()
        seq = seq + 1
        return { tx = "harness-" .. seq .. "-" .. getTimestampMs(), zoneId = zone.id, x = front.x, y = front.y, z = front.z }
    end
    -- The server half of the ritual: Begin at channel start, Make at completion.
    local function offer(ctx)
        ctx.mark = #L.results
        ctx.h0, ctx.xp0 = health(), woodXP()
        local a = args()
        ctx.tx = a.tx
        SO.OfferingService.Begin(p(), a)
        if not SO.OfferingService.PendingWrath[a.tx] then SO.OfferingService.Make(p(), a) end
    end
    local function last(ctx)
        for i = #L.results, (ctx.mark or 0) + 1, -1 do
            local r = L.results[i]
            if r.translation ~= "IGUI_SO_ZoneCreated" then return r end
        end
        return nil
    end
    local function describe(ctx)
        local r = last(ctx)
        return string.format("result=%s health %.0f->%.0f xp %.0f->%.0f altarItems=%d",
            r and r.translation or "none", ctx.h0 or -1, health(), ctx.xp0 or -1, woodXP(), altarCount())
    end
    local function expect(ctx, translation)
        local r = last(ctx)
        return r ~= nil and r.translation == translation
    end
    local function makeOfferingHandler()
        local _, _, altarObj = containers()
        local h = ISLootWindowObjectControlHandler_SO_MakeOffering:new()
        h.object = altarObj
        h.container = altarObj:getContainer()
        h.playerObj = p()
        h.playerNum = 0
        return h
    end

    local T = SO.TRANSLATION
    local WRATH_WAIT = 6000

    ------------------------------------------------------------------ cases
    local cases = {
        { name = "Standing in the altar smoke and ritual wisp does no damage",
          prep = function() clearAltar() end,
          act = function(c)
              c.h0 = health()
              SO.Effects.Play({ effect = SO.EFFECT.WRATH_SMOKE, x = front.x, y = front.y, z = front.z })
              SO.Effects.Play({ effect = SO.EFFECT.TRANCE, x = math.floor(p():getX()), y = math.floor(p():getY()), z = front.z })
          end,
          wait = 6000,
          check = function(c)
              local sq = p():getCurrentSquare()
              local burningFlag = sq and sq:getProperties():has(IsoFlagType.burning)
              return math.abs(health() - c.h0) < 1 and not p():isOnFire() and not burningFlag,
                  string.format("health %.1f->%.1f onFire=%s squareBurning=%s", c.h0, health(),
                      tostring(p():isOnFire()), tostring(burningFlag))
          end },

        { name = "Junk offering: the denied sound starts, nothing else happens until the end",
          prep = function() clearAltar(); fire(true); stand(); heal(); add("Base.Plank") end,
          act = function(c)
              c.mark = #L.results
              c.h0, c.xp0 = health(), woodXP()
              c.cue = nil
              if not STOfferOrigFirstBeat then STOfferOrigFirstBeat = SO.Sound.HandleFirstBeat end
              SO.Sound.HandleFirstBeat = function(a) c.cue = a and a.outcome; return STOfferOrigFirstBeat(a) end
              L.pendingArgs = args()
              SO.OfferingService.Begin(p(), L.pendingArgs)
          end,
          wait = 1500,
          check = function(c)
              SO.Sound.HandleFirstBeat = STOfferOrigFirstBeat
              local pending = SO.OfferingService.PendingRituals[L.pendingArgs.tx]
              return last(c) == nil and altarHas("Base.Plank")
                  and c.cue == SO.SOUND_OUTCOME.FAILURE and pending ~= nil and pending.verdict.valid == false,
                  describe(c) .. " cue=" .. tostring(c.cue) .. " committed=" .. tostring(pending and pending.verdict.reason)
          end },

        { name = "...and the wrath lands only when the ritual completes",
          act = function(c)
              c.mark = #L.results
              c.h0, c.xp0 = health(), woodXP()
              SO.OfferingService.Make(p(), L.pendingArgs)
          end,
          wait = 1500,
          check = function(c) return expect(c, T.WRATH) and health() < c.h0 and altarCount() == 0, describe(c) end,
          post = heal },

        { name = "Good offering: nothing revealed at start, success at the end",
          prep = function() clearAltar(); fakeDeath(5000); add("Base.Katana") end,
          act = function(c)
              c.mark = #L.results
              c.h0, c.xp0 = health(), woodXP()
              local a = args()
              SO.OfferingService.Begin(p(), a)
              c.midResult, c.midKatana = last(c), altarHas("Base.Katana")
              SO.OfferingService.Make(p(), a)
          end,
          check = function(c)
              return c.midResult == nil and c.midKatana and expect(c, T.SUCCESS_ITEM) and woodXP() > c.xp0,
                  describe(c) .. " revealedEarly=" .. tostring(c.midResult ~= nil)
          end },

        { name = "Walked away from a junk offering: wrath still lands at ritual end",
          prep = function() clearAltar(); heal(); add("Base.Plank") end,
          act = function(c)
              c.mark = #L.results
              c.h0, c.xp0 = health(), woodXP()
              local a = args()
              SO.OfferingService.Begin(p(), a)
              c.early = last(c)
              -- Fast-forward the abandoned ritual to its end instead of waiting 52 s.
              local pending = SO.OfferingService.PendingRituals[a.tx]
              if pending then pending.elapsedMs = 1e9 end
          end,
          wait = 2000,
          check = function(c)
              return c.early == nil and expect(c, T.WRATH) and health() < c.h0 and altarCount() == 0,
                  describe(c) .. " revealedEarly=" .. tostring(c.early ~= nil)
          end,
          post = heal },

        { name = "Empty altar is refused",
          prep = function() clearAltar(); fire(true); stand(); heal() end,
          act = offer,
          check = function(c) return expect(c, "IGUI_SO_AltarEmpty"), describe(c) end },

        { name = "Campfire out: offering refused, item kept",
          prep = function() clearAltar(); add("Base.Katana"); fire(false); stand() end,
          act = offer,
          check = function(c) return expect(c, "IGUI_SO_FireNotLit") and altarHas("Base.Katana"), describe(c) end,
          post = function() fire(true) end },

        { name = "Too far from the altar: refused, item kept",
          prep = function() clearAltar(); add("Base.Katana"); stand(0, 5) end,
          act = offer,
          check = function(c) return expect(c, "IGUI_SO_TooFar") and altarHas("Base.Katana"), describe(c) end,
          post = function() stand() end },

        { name = "Rare item with nothing to recover: refused, item kept",
          prep = function() clearAltar(); noGap(); add("Base.Katana") end,
          act = offer,
          check = function(c) return expect(c, T.NO_RECOVERY) and altarHas("Base.Katana"), describe(c) end },

        { name = "Rare item (katana) restores XP",
          prep = function() clearAltar(); fakeDeath(5000); add("Base.Katana") end,
          act = offer,
          check = function(c)
              return expect(c, T.SUCCESS_ITEM) and woodXP() > c.xp0 and altarCount() == 0, describe(c)
          end },

        { name = "Rare recipe (assault rifle + 3 magazines) restores XP",
          prep = function() clearAltar(); add("Base.AssaultRifle"); add("Base.556Clip", 3) end,
          act = offer,
          check = function(c)
              return expect(c, T.SUCCESS_ITEM) and woodXP() > c.xp0 and altarCount() == 0, describe(c)
          end },

        { name = "Rare item past the life's full recovery: greed wrath",
          prep = function()
              clearAltar(); heal()
              local rec = record()
              rec.recoveryStrengthGeneration = rec.deathGeneration
              rec.recoveryStrengthRedeemed = 100
              add("Base.Sledgehammer")
          end,
          act = offer, wait = WRATH_WAIT,
          check = function(c)
              local r = last(c)
              return r and r.translation == T.WRATH and r.fields.greedTranslation ~= nil and health() < c.h0,
                  describe(c) .. " greed=" .. tostring(r and r.fields.greedTranslation)
          end },

        { name = "Animal carcass beside the altar restores XP",
          prep = function(c) clearAltar(); heal(); fakeDeath(5000); c.ok, c.animal = addAnimalCarcass("cow") end,
          act = offer,
          check = function(c)
              return c.ok and expect(c, T.SUCCESS_ITEM) and woodXP() > c.xp0,
                  describe(c) .. " animal=" .. tostring(c.animal)
          end },

        { name = "Animal head restores XP",
          prep = function() clearAltar(); add("Base.Cow_Head_Angus") end,
          act = offer,
          check = function(c) return expect(c, T.SUCCESS_ITEM) and woodXP() > c.xp0, describe(c) end },

        { name = "Animal offering past the animal cap: minor greed wrath",
          prep = function()
              clearAltar(); heal()
              local rec = record()
              rec.recoveryStrengthGeneration = rec.deathGeneration
              rec.recoveryStrengthRedeemed = SO.Sandbox.RecoveryStrength("item")
              add("Base.Cow_Head_Angus")
          end,
          act = offer, wait = WRATH_WAIT,
          check = function(c)
              local r = last(c)
              return r and r.translation == T.MINOR_WRATH and r.fields.greedTranslation ~= nil,
                  describe(c) .. " greed=" .. tostring(r and r.fields.greedTranslation)
          end },

        { name = "Animal head mixed with junk: wrath",
          prep = function() clearAltar(); heal(); fakeDeath(5000); add("Base.Cow_Head_Angus"); add("Base.Nails") end,
          act = offer, wait = WRATH_WAIT,
          check = function(c) return expect(c, T.WRATH) and health() < c.h0 and altarCount() == 0, describe(c) end },

        { name = "Junk item (plank): wrath, item consumed",
          prep = function() clearAltar(); heal(); add("Base.Plank") end,
          act = offer, wait = WRATH_WAIT,
          check = function(c)
              local lost = c.h0 - health()
              local lo, hi = SO.Sandbox.WrathRange()
              return expect(c, T.WRATH) and altarCount() == 0 and lost >= lo - 1,
                  describe(c) .. string.format(" lost=%.0f range=%d-%d", lost, lo, hi)
          end },

        { name = "Zombie corpse: wrath",
          prep = function(c) clearAltar(); heal(); c.ok = addHumanCorpse(nil) end,
          act = offer, wait = WRATH_WAIT,
          check = function(c) return c.ok and expect(c, T.WRATH), describe(c) end },

        { name = "Another player's corpse: full recovery",
          prep = function(c) clearAltar(); heal(); fakeDeath(5000); c.ok = addHumanCorpse(VICTIM) end,
          act = offer,
          check = function(c)
              local r = last(c)
              return c.ok and r and (r.translation == T.SUCCESS_CORPSE or r.translation == T.SUCCESS_CORPSE_PRIZE)
                  and woodXP() > c.xp0,
                  describe(c) .. " strength=" .. tostring(r and r.fields.recoveryStrength)
          end },

        { name = "Same victim's corpse again (new life): still accepted",
          prep = function(c) clearAltar(); fakeDeath(5000); c.ok = addHumanCorpse(VICTIM) end,
          act = offer,
          check = function(c)
              local r = last(c)
              local uses = record().playerCorpseSacrifices[VICTIM]
              return c.ok and r and (r.translation == T.SUCCESS_CORPSE or r.translation == T.SUCCESS_CORPSE_PRIZE),
                  describe(c) .. " strength=" .. tostring(r and r.fields.recoveryStrength) .. " victimUses=" .. tostring(uses)
          end },

        { name = "Own corpse: self-corpse punishment",
          prep = function(c) clearAltar(); heal(); c.ok = addHumanCorpse(SO.PlayerLedger.GetIdentity(p())) end,
          act = offer, wait = WRATH_WAIT,
          check = function(c)
              local fractures, parts = 0, p():getBodyDamage():getBodyParts()
              for i = 0, parts:size() - 1 do if parts:get(i):getFractureTime() > 0 then fractures = fractures + 1 end end
              return c.ok and expect(c, T.SELF_CORPSE) and health() < c.h0,
                  describe(c) .. " fractures=" .. fractures
          end,
          post = heal },

        { name = "Second offering while wrath is pending: altar busy",
          prep = function() clearAltar(); heal(); add("Base.Plank") end,
          act = function(c)
              offer(c)
              c.mark2 = #L.results
              add("Base.Plank")
              local a = args()
              SO.OfferingService.Begin(p(), a)
              local r = L.results[#L.results]
              c.busy = #L.results > c.mark2 and r.translation == T.BUSY
          end,
          wait = WRATH_WAIT,
          check = function(c) return c.busy == true, describe(c) .. " busy=" .. tostring(c.busy) end,
          post = function() clearAltar(); heal() end },

        { name = "Katana theft: lightning flash, exactly 50% health, deep wounds",
          prep = function(c)
              clearAltar(); heal()
              SO.RelicService.lastStrikeAt = {}
              c.flashes = 0
              if not STOfferOrigLightning then STOfferOrigLightning = SO.Lightning.Play end
              SO.Lightning.Play = function(a) c.flashes = c.flashes + 1; return STOfferOrigLightning(a) end
              local pos = zone.fixtures.mannequins[2]
              p():setX(pos.x + 1.5); p():setY(pos.y + 0.5); p():setLastX(pos.x + 1.5); p():setLastY(pos.y + 0.5)
              c.skeleton = SO.Fixtures.FindTaggedObject(pos.x, pos.y, pos.z, SO.FIXTURE.MANNEQUIN)
          end,
          act = function(c)
              c.mark = #L.results
              c.h0, c.xp0 = health(), woodXP()
              local sc = c.skeleton:getContainer()
              c.valid = ISInventoryTransferAction:new(p(), sc:getItems():get(0), sc, p():getInventory()):isValid()
              -- Read at once: the deep wounds start bleeding straight away.
              c.hAfter = health()
          end,
          wait = 1500,
          check = function(c)
              local deep, parts = 0, p():getBodyDamage():getBodyParts()
              for i = 0, parts:size() - 1 do if parts:get(i):isDeepWounded() then deep = deep + 1 end end
              local lostPct = (c.h0 - (c.hAfter or health())) / c.h0 * 100
              return c.valid == false and c.flashes == 1 and math.abs(lostPct - 50) < 1 and deep >= 2
                  and c.skeleton:getContainer():getItems():size() == 2,
                  string.format("%s lost=%.1f%% deep=%d flashes=%d", describe(c), lostPct, deep, c.flashes)
          end,
          post = function() SO.Lightning.Play = STOfferOrigLightning; heal(); stand() end },

        { name = "Map: temples visible and toggle survives a map rebuild",
          act = function(c)
              local I = SO.WorldMapIntegration
              I.Showing = false
              I.Toggle({})
              c.showing = I.Showing
              c.zones = #(SO.Client.Zones or {})
          end,
          check = function(c)
              return c.showing == true and c.zones >= 1,
                  "showing=" .. tostring(c.showing) .. " clientZones=" .. tostring(c.zones)
          end },

        { name = "Real Make Offering button + full ritual channel (katana)",
          prep = function(c)
              clearAltar(); heal(); fakeDeath(5000); add("Base.Katana"); stand()
              c.visible = makeOfferingHandler():shouldBeVisible()
          end,
          act = function(c)
              c.mark = #L.results
              c.h0, c.xp0 = health(), woodXP()
              makeOfferingHandler():perform()
          end,
          wait = 55000,
          check = function(c)
              return c.visible and expect(c, T.SUCCESS_ITEM) and woodXP() > c.xp0,
                  describe(c) .. " buttonVisible=" .. tostring(c.visible)
          end },

        { name = "Ritual broken by walking away: nothing consumed",
          prep = function() clearAltar(); fakeDeath(5000); add("Base.Katana"); stand() end,
          act = function(c)
              c.mark = #L.results
              c.h0, c.xp0 = health(), woodXP()
              makeOfferingHandler():perform()
              c.leaveAt = getTimestampMs() + 6000
          end,
          during = function(c)
              if c.leaveAt and getTimestampMs() >= c.leaveAt then c.leaveAt = nil; stand(0, 6) end
          end,
          wait = 12000,
          check = function(c)
              local running = SO_OfferingRitualAction.IsActive(p())
              return not running and altarHas("Base.Katana") and woodXP() == c.xp0 and last(c) == nil,
                  describe(c) .. " ritualStillRunning=" .. tostring(running)
          end,
          post = function() stand() end },

        { name = "Wrath kills a badly hurt player (dying is allowed)",
          expectDeath = true,
          prep = function(c)
              clearAltar(); add("Base.Plank")
              p():getXp():AddXP(Perks.Woodwork, 3000)
              SO.PlayerLedger.UpdateBest(p())
              c.identity = SO.PlayerLedger.GetIdentity(p())
              c.generation = record().deathGeneration
              c.bestBefore = record().bestXP[WOODWORK]
              L.beforeDeath = c
              p():getBodyDamage():ReduceGeneralHealth(92)
          end,
          act = offer, wait = 8000,
          check = function(c)
              local rec = SO.Storage.GetPlayer(c.identity)
              return c.died == true,
                  string.format("died=%s deathGeneration %s->%s best=%s",
                      tostring(c.died), tostring(c.generation), tostring(rec.deathGeneration), tostring(c.bestBefore))
          end },

        { name = "After dying: the new character recovers lost XP at the altar",
          prep = function() clearAltar(); add("Base.Katana") end,
          act = offer,
          check = function(c)
              local before = L.beforeDeath or {}
              local now = SO.PlayerLedger.GetIdentity(p())
              return expect(c, T.SUCCESS_ITEM) and woodXP() > c.xp0,
                  describe(c) .. " identityBefore=" .. tostring(before.identity) .. " identityNow=" .. tostring(now)
          end },
    }

    ------------------------------------------------------------------ runner
    L.cases, L.index, L.state, L.due, L.pass, L.fail = cases, 0, "next", 0, 0, 0
    L.retried, L.deaths = {}, 0
    local function say(line) print("[STOffer] " .. line) end
    -- On-screen instructions for whoever is watching the game window.
    local function banner(text) STStatus = text end
    local function finish()
        L.state = "done"
        clearAltar(); heal(); fire(true); stand()
        say(string.format("DONE pass=%d fail=%d deaths=%d (temple left standing, campfire lit)", L.pass, L.fail, L.deaths))
        banner(string.format("TESTS FINISHED (%d passed, %d failed). You can play now - the temple fire is lit.", L.pass, L.fail))
    end
    L.tick = function()
        if L.state == "done" then return end
        local now = getTimestampMs()
        local case = L.cases[L.index]
        -- Dying is a normal outcome in this mod: pause, tell the watcher what to
        -- do, and pick up again once a new character exists.
        local pl = getPlayer()
        if not pl or pl:isDead() then
            if L.state ~= "dead" then
                L.deadFrom, L.state = L.state, "dead"
                L.deaths = L.deaths + 1
                say("DIED | during test " .. L.index .. (case and (": " .. case.name) or "") .. " (allowed; waiting for a new character)")
                banner("Your character died (that's allowed). Click through the death screen and create any new character - the tests continue by themselves.")
            end
            return
        end
        if L.state == "dead" then
            -- The new character spawns somewhere else: bring them back and wait
            -- until the temple's area has loaded before carrying on.
            stand()
            L.state, L.due, L.respawnGiveUp = "respawned", now + 3000, now + 45000
            banner("Welcome back - bringing you to the temple. Hands off again, please.")
            return
        end
        if L.state == "respawned" then
            if now < L.due then return end
            if not containers() and now < L.respawnGiveUp then
                stand()
                L.due = now + 1000
                return
            end
            heal(); fire(true); stand()
            if case and case.expectDeath then
                L.ctx.died = true
                L.state, L.due = "wait", now
            elseif case and not L.retried[L.index] then
                L.retried[L.index] = true
                say("RETRY | " .. case.name .. " (the character died during it)")
                L.index = L.index - 1
                L.state = "next"
            else
                if case then
                    L.fail = L.fail + 1
                    say("FAIL | " .. case.name .. " | the character died during it twice")
                end
                L.state = "next"
            end
            return
        end
        if L.state == "wait" and case and case.during then pcall(case.during, L.ctx) end
        if now < L.due then return end
        if L.state == "next" then
            L.index = L.index + 1
            case = L.cases[L.index]
            if not case then return finish() end
            L.ctx = {}
            -- Every test starts from full health beside the lit altar.
            heal(); fire(true); stand()
            banner(string.format("AUTOMATED TEST %d of %d - hands off, keep this window in front.   Now: %s", L.index, #L.cases, case.name))
            local ok, err = pcall(function()
                if case.prep then case.prep(L.ctx) end
                case.act(L.ctx)
            end)
            if not ok then
                L.fail = L.fail + 1
                say("FAIL | " .. case.name .. " | setup error: " .. tostring(err))
                L.due = now + 300
                return
            end
            L.state, L.due = "wait", now + (case.wait or 800)
        elseif L.state == "wait" then
            local ok, passed, detail = pcall(case.check, L.ctx)
            if ok and passed then L.pass = L.pass + 1 else L.fail = L.fail + 1 end
            say((ok and passed and "PASS" or "FAIL") .. " | " .. case.name .. " | " .. tostring(ok and detail or passed))
            if case.post then pcall(case.post, L.ctx) end
            L.state, L.due = "next", now + 500
        end
    end
    -- Ticked by STLiveStart's boot-registered poll handler.
    say("START " .. #cases .. " cases, temple " .. tostring(zone.id))
    return "started " .. #cases .. " cases"
end)()
