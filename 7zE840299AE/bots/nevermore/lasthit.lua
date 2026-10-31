local L = {}

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

L._prepCreep = nil
L._prepStartLAT = -100
L._prepExpire = 0

local RAZE_SPECS = {
    { slot = "nevermore_shadowraze1", idx = 0, dist = 200, radius = 250 },
    { slot = "nevermore_shadowraze2", idx = 1, dist = 450, radius = 250 },
    { slot = "nevermore_shadowraze3", idx = 2, dist = 700, radius = 250 },
}

local function BuildAllAttackers(bot, enemyCreeps, allyCreeps, enemyTowers, allyTowers, enemyHero)
    local enemySide = {} -- Units attacking OUR creeps (for denies)
    local allySide  = {} -- Units attacking ENEMY creeps (for last hits)
    for _, c in pairs(enemyCreeps or {}) do
        if U.CanQuery(c) then enemySide[#enemySide + 1] = c end
    end
    for _, t in pairs(enemyTowers or {}) do
        if U.CanQuery(t) then enemySide[#enemySide + 1] = t end
    end
    if enemyHero and U.CanQuery(enemyHero) then
        enemySide[#enemySide + 1] = enemyHero
        allySide[#allySide + 1]   = enemyHero -- Rival denies count on contested enemy creeps!
    end
    for _, c in pairs(allyCreeps or {}) do
        if U.CanQuery(c) then allySide[#allySide + 1] = c end
    end
    for _, t in pairs(allyTowers or {}) do
        if U.CanQuery(t) then allySide[#allySide + 1] = t end
    end
    return allySide, enemySide
end
L.BuildAllAttackers = BuildAllAttackers

-- True when the opposing mid hero has zero coil mana (`< 75`), is not mid-cast, and stands well outside
-- physical right-click reach (`> enAtkRange + 150 = 675u`) while we hold enough HP (`>= max(135, 1.6x auto)`):
-- prevents conceding uncontested CS or under-tower prep when the enemy literally cannot punish us!
function L.EnemyCannotPunishLane(bot, enemyHero, hp)
    if not enemyHero or not U.CanQuery(enemyHero) or not enemyHero:IsAlive() then return false end
    local enPotMana = U.GetPotentialManaForRaze(enemyHero) or 0
    if enPotMana >= 75 then return false end
    if enemyHero.IsUsingAbility and enemyHero:IsUsingAbility() then return false end
    local d = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local enAtkRange = (enemyHero.GetAttackRange and enemyHero:GetAttackRange()) or 525
    if d <= enAtkRange + 150 then return false end
    local raw = ((enemyHero.GetAttackDamage and enemyHero:GetAttackDamage()) or 55) + 4
    local enOneAuto = bot.GetActualIncomingDamage and bot:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL) or raw
    return (hp or bot:GetHealth() or 0) >= math.max(135, enOneAuto * 1.6)
end

local function IsPositionLethalFromEnemy(bot, checkLoc, enemyHero, race, isDeny)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local hp = bot:GetHealth()
    local maxHP = math.max(1, bot:GetMaxHealth())
    local hpPct = hp / maxHP
    local bLoc = bot:GetLocation()
    local eLoc = enemyHero:GetLocation()
    local d = U.DistanceBetweenLocations(checkLoc, eLoc)
    local dNow = U.DistanceBetweenLocations(bLoc, eLoc)
    local enPotMana = U.GetPotentialManaForRaze(enemyHero)
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    myStacks = myStacks or 0
    myRem = myRem or 0

    -- 0. Shadowraze Debuff Stack Discipline (`R1_2039` `01:59.73` + `auto-20261022-2237` Death #1 `05:39.03` Root Cause!):
    --   (a) With >= 2 active stacks (`myRem > 0.35s`) and enemy `enPotMana >= 75` (INCLUDING Mango/Stick!),
    --       a 3rd coil hits for `210..380+` magic damage up to `950u` — NEVER turn around toward a creep inside `965u`!
    --   (b) With 1 active stack (`myRem > 0.20s` — INCLUDING fresh `7.8s` stack right after `Shadowraze3` hit at `05:38.80`!):
    --       NEVER step forward inside enemy's READY remaining bands (`W <= 715u` / `Q <= 475u` when `enPotMana >= 75`)!
    --       Conversely, if enemy just spent `Z` (`700u` on `10s` CD), `[720u..900u]` is 100% safe for ranged CS!
    local lrCheck = U.SolveLethalRace(bot, enemyHero, U._W and U._W.s or nil)
    if lrCheck and lrCheck.winsFirstKill then
        return false
    end

    local K = U._K
    if myStacks >= 2 and myRem > 0.35 and enPotMana >= 75 and not (race and race.valid and race.canKillNow) then
        if d < 965 then return true end
    end
    if myStacks == 1 and myRem > 0.20 and enPotMana >= 75 and not (race and race.valid and race.canKillNow) then
        local readyReach = (K and K.EnemyMinSafeDistance and K.EnemyMinSafeDistance(enemyHero, 0.8)) or 760
        local forbidDist = (myRem <= 2.15) and math.max(760, readyReach) or math.min(725, readyReach)
        if d < forbidDist then return true end
    end

    -- 1. NEVER walk into an actively casting enemy Shadowraze circle when raze puts us in combo range or < 55% HP!
    if enemyHero:IsUsingAbility() then
        local eFace = (enemyHero.GetFacing and enemyHero:GetFacing()) or 0
        local rad = math.rad(eFace)
        for _, rz in ipairs({ 200, 450, 700 }) do
            local spot = Vector(eLoc.x + math.cos(rad) * rz, eLoc.y + math.sin(rad) * rz, eLoc.z or 128)
            if U.DistanceBetweenLocations(checkLoc, spot) <= 255 then
                local oneR = (race and race.valid and race.oneRaze) or 220
                if hp <= oneR * 1.85 or hpPct <= 0.58 or myStacks >= 1 then
                    return true
                end
            end
        end
    end
    -- 2. Exact Reachable Burst Check at `checkLoc` over the CS strike window (`0.85s` — NEVER false-blocking safe CS at `700..850u`!):
    if K and K.EnemyBurstVs and not (race and race.valid and race.canKillNow) then
        local burstAtCheck = K.EnemyBurstVs(bot, enemyHero, d, 0.85, false)
        if burstAtCheck + 35 >= hp then
            return true
        end
    end
    local myPotMana = (K and K.MyManaBudget and K.MyManaBudget(bot, true)) or (bot:GetMana() or 0)
    local enCastable = (K and K.EnemyCastableRazeCount and K.EnemyCastableRazeCount(enemyHero, 2.5)) or 0
    local enOneAuto = (K and K.AttackDamageVs and K.AttackDamageVs(enemyHero, bot)) or 52

    -- 2B. Dry-Mana vs Multi-Raze Execution Guard (`9069188041.dem` `02:01.0` 3-Raze & `02:11.8` 2-Raze Near-Death Fix!):
    -- When we have `< 75` potential mana (ZERO Razes to trade back!), NEVER walk inside `R2+R3` overlap (`< 735u`)
    -- if enemy's ready `2` Razes + 1 auto kill us (`288 HP` at `10 MP`!), and NEVER walk inside `< 660u` if enemy's
    -- ready `3` Razes + 1 auto kill us (`437 HP` at `68 MP` vs `296 MP` Lvl-3 SF!). Ranged CS from `>= 740u` stays open!
    if myPotMana < 75 and enCastable >= 2 and not (race and race.valid and race.canKillNow) then
        local twoCastR = (K and K.EnemyCastableRazeDamage and K.EnemyCastableRazeDamage(bot, enemyHero, 2, nil, 2.5)) or 0
        if hp <= twoCastR + enOneAuto + 30 and d < 735 then
            return true
        end
        if enCastable >= 3 then
            local threeCastR = (K and K.EnemyCastableRazeDamage and K.EnemyCastableRazeDamage(bot, enemyHero, 3, nil, 2.5)) or 0
            if hp <= threeCastR + enOneAuto + 25 and d < 660 then
                return true
            end
        end
    end

    if race and race.valid and not race.canKillNow and not (race.canKillSoon and (race.edge or 0) >= -25) then
        if race.heCanKillNow then
            if d < math.max(780, (race.minSafeDist or 860) - 55) then return true end
        elseif race.heCanKillSoon and not race.canKillSoon then
            local twoR = race.twoRaze or ((race.oneRaze or 180) * 2.2)
            local outLeveledOrBootless = race.heHasBootsLead or ((enemyHero:GetLevel() or 1) > (bot:GetLevel() or 1))
            if outLeveledOrBootless and hp <= twoR + 95 then
                if d < 715 then return true end
            elseif hp <= twoR + 40 and d < 640 then
                return true
            end
        end
    end

    -- 2C. Level-Spike & Out-Razed Tier Respect (`auto-20261031-0230` `00:59.3` Lvl 1 vs Lvl 2, `01:51.1` & `02:00.4` Lvl 2 vs Lvl 3 Fix!):
    --   * At Lvl 1 vs Lvl 2+, enemy has `Necromastery + Raze` while we have 0 Necromastery (`43` dmg) — NEVER step into `d < 605`
    --     when below `430 HP` or surrounded by enemy creeps!
    --   * When down a Raze tier (`Lvl 2 vs Lvl 3` = `69` vs `124+161 = 285` dmg!), NEVER walk forward into `R2` (`d < 720u`)
    --     to deny an allied creep (`isDeny == true`), nor enter `d < 695u` when enemy holds `>= 2` castable Razes!
    local myLvlNow = (bot.GetLevel and bot:GetLevel()) or 1
    local enLvlNow = (enemyHero.GetLevel and enemyHero:GetLevel()) or 1
    local outLeveledNow = enLvlNow > myLvlNow
    local outRazedNow = (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemyHero)) or (myLvlNow == 1 and enLvlNow >= 2)
    if outLeveledNow and not (race and race.valid and race.canKillNow) then
        local wsCheck = U._W and U._W.s
        local nearEnemyCreeps = 0
        for _, ec in pairs((wsCheck and wsCheck.enemyCreeps) or {}) do
            if U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(checkLoc, ec:GetLocation()) <= 285 then
                nearEnemyCreeps = nearEnemyCreeps + 1
            end
        end
        if myLvlNow == 1 and (hp <= 430 or nearEnemyCreeps >= 2) and d < 605 then
            return true
        end
        if outRazedNow and enCastable >= 1 then
            local twoCastOut = (K and K.EnemyCastableRazeDamage and K.EnemyCastableRazeDamage(bot, enemyHero, 2, nil, 2.5))
                or ((K and K.EnemyRazeDamage and K.EnemyRazeDamage(bot, enemyHero, 2)) or 260)
            if isDeny and d < dNow - 12 and d < 725 and hp <= twoCastOut + enOneAuto * 1.5 + 150 then
                return true
            end
            if enCastable >= 2 and d < 695 and hp <= twoCastOut + enOneAuto + 265 then
                return true
            end
        end
    end

    -- 3. Low-HP lethal burst & close physical execution fallback (`auto-20261031-0230` `02:08.3` `180 HP` vs `68 MP` Lvl-3 SF Fix!):
    --    Even if `enPotMana < 75`, walking inside `<= 665u` at `<= 3.25` right-clicks of HP hands enemy lethal physical autos!
    local enRangeCheck = (enemyHero.GetAttackRange and enemyHero:GetAttackRange()) or 525
    if hp <= math.max(210, enOneAuto * 3.25) and not (race and race.valid and race.canKillNow) then
        if d < enRangeCheck + 145 then return true end
    end
    if hpPct <= 0.36 and enPotMana >= 150 then
        if d < 595 then return true end
    end
    -- 4. No Walk-Through-Enemy for Out-of-Range Back-Wave Creep (`R1_2039` `02:35` & `R2_2044` `02:31` Fix!):
    -- If reaching `checkLoc` requires WALKING closer to a live non-lethal `enemyHero` (`moveDist > 25` & `d < dNow - 15`),
    -- NEVER walk straight through `enemyHero` (`d < 340`) or into active right-click focus when behind in HP!
    local moveDist = U.DistanceBetweenLocations(bLoc, checkLoc)
    local enHp = enemyHero:GetHealth() or 999
    if moveDist > 25 and d < dNow - 15 and enHp > 205 then
        if d < 340 then return true end
        local beingHit = (enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.5))
        -- `v4.2.0` Equal-State Stand-Ground Rule (`Demo 2` 25-concession fix!):
        -- NEVER abandon every creep in `560u` on EVEN or WINNING HP (`hp >= enHp - 95` or `hp > 430`)!
        if beingHit and d < 560 and ((hp < enHp - 95 and hp <= 430) or hp <= 285) then
            return true
        end
    end
    return false
end
L.IsPositionLethalFromEnemy = IsPositionLethalFromEnemy

-- Evaluate every enemy & ally creep on exact 30 Hz integer trajectory ticks
function L.ScanCreepCandidates(bot, enemyCreeps, allyCreeps, allySideAttackers, enemySideAttackers, enemyHero, race)
    local candidates = {}

    local function evalList(list, isDeny, attackers)
        local curTickScan = math.floor(GameTime() * 30.0 + 0.5)
        local ownRec = U._unitTrack[bot]
        local curAtkTarget = (bot.GetAttackTarget and bot:GetAttackTarget()) or nil
        for _, c in pairs(list or {}) do
            if U.CanQuery(c) and c:GetHealth() > 0 then
                local kOpen, kTargetImpact, effClose, gamble, ctx = U.GetExactKillableInfo(bot, c, attackers)
                if kOpen ~= -2 then -- -2 = already fatally struck by our own mid-air projectile!
                    local totalT, launchT, wT, fT, turnT, walkT, cdT = U.GetExactBallisticTicks(bot, c)
                    -- `A01` Mid-Swing Preservation: keep remaining `(launchTick - curTick) + fT` ONLY inside `SelectBestRightClickPlan`
                    -- reachability check (`effT <= effClose + 1`) while `ExecutePhaseLockedCS` uses pristine `totalT`!
                    local activeRemT = nil
                    if ownRec and ownRec.wasAnim and ownRec.launchTick and ownRec.launchTick >= curTickScan and curAtkTarget == c then
                        activeRemT = (ownRec.launchTick - curTickScan) + fT
                    end
                    local bLoc = bot:GetLocation()
                    local cLoc = c:GetLocation()
                    local distNow = U.DistanceBetweenLocations(bLoc, cLoc)
                    local reqLoc = bLoc
                    local maxR = (bot:GetAttackRange() or 525) + 18
                    if distNow > maxR then
                        reqLoc = cLoc + (bLoc - cLoc):Normalized() * (maxR - 12)
                    end
                    local lethalRightClick = IsPositionLethalFromEnemy(bot, reqLoc, enemyHero, race, isDeny)
                    local nm = c:GetUnitName() or ""
                    local isRangedCreep = nm:find("ranged") ~= nil
                    local isSiegeCreep  = nm:find("siege") ~= nil
                    candidates[#candidates + 1] = {
                        creep = c,
                        isDeny = isDeny,
                        isRanged = isRangedCreep,
                        isSiege = isSiegeCreep,
                        kOpen = kOpen,
                        kTargetImpact = kTargetImpact,
                        effClose = effClose,
                        gamble = gamble,
                        ctx = ctx,
                        totalT = totalT,
                        activeRemT = activeRemT,
                        launchT = launchT,
                        wT = wT,
                        fT = fT,
                        turnT = turnT,
                        walkT = walkT,
                        cdT = cdT,
                        distNow = distNow,
                        lethalRightClick = lethalRightClick,
                    }
                end
            end
        end
    end

    evalList(enemyCreeps, false, allySideAttackers)
    evalList(allyCreeps, true, enemySideAttackers)
    return candidates
end

-- Select optimal right-click target with strict Last-Hit > Deny collision arbitration
function L.SelectBestRightClickPlan(bot, candidates, siegingEnemyT1)
    local spaTicks = math.ceil((bot:GetSecondsPerAttack() or 1.25) * 30.0)
    -- Earliest enemy last-hit opening & closing ticks so a deny NEVER steals attack cooldown from an imminent last hit!
    local earliestEnemyOpen = 9999
    local earliestEnemyClose = 9999
    local earliestEnemyTotal = 18
    for _, cand in ipairs(candidates) do
        if not cand.isDeny and not cand.lethalRightClick and cand.kOpen >= 0 and cand.kOpen < 900 then
            local effT = cand.activeRemT or cand.totalT
            if effT <= cand.effClose + 1 and cand.kOpen < earliestEnemyOpen then
                earliestEnemyOpen = cand.kOpen
                earliestEnemyClose = cand.effClose
                earliestEnemyTotal = cand.totalT
            end
        end
    end

    local best = nil
    local bestScore = -1e9

    local isDominantCS = (not siegingEnemyT1) and U.IsLaneDominant and U.IsLaneDominant(bot, nil, nil) or false
    local denyMaxSlack = siegingEnemyT1 and 3 or (isDominantCS and 16 or 8)
    for _, cand in ipairs(candidates) do
        local effT = cand.activeRemT or cand.totalT
        local horizonOk = (not cand.isDeny and cand.kOpen >= 0 and cand.kOpen <= 68)
            or (cand.isDeny and cand.kOpen >= 0 and (cand.kTargetImpact - cand.totalT) <= denyMaxSlack)
        if not cand.lethalRightClick and horizonOk then
            if effT <= cand.effClose + 1 then
                local blocksEnemyLH = false
                if cand.isDeny and earliestEnemyOpen < 900 then
                    local denyLaunch = (cand.activeRemT ~= nil)
                        and math.max(0, cand.activeRemT - cand.fT)
                        or math.max(cand.launchT, cand.kTargetImpact - cand.fT)
                    local nextReadyImpact = denyLaunch + spaTicks + earliestEnemyTotal
                    local latestSafeEnemyImpact = math.max(earliestEnemyOpen + 2, math.min(earliestEnemyOpen + 10, earliestEnemyClose))
                    if nextReadyImpact > latestSafeEnemyImpact then
                        blocksEnemyLH = true
                    end
                end

                if not blocksEnemyLH then
                    -- Exact Urgency Score:
                    -- 1. Enemy Last-Hit strongly beats simultaneous Deny (+400 priority)
                    -- 2. Earlier kTargetImpact comes first so multiple creeps in sequence get 100% chained!
                    -- 3. Ranged / Flagbearer / Siege tie-break bonus + Soul-Economy bonus below Necromastery cap
                    local typePrio = cand.isDeny and 0.0 or 400.0
                    local valueBonus = (cand.isRanged or cand.isSiege) and 22.0 or 0.0
                    local gamblePen = cand.gamble and -6.0 or 0.0
                    local soulBonus = 0.0
                    if not cand.isDeny then
                        local S = U._S
                        if S and S.GetSouls then
                            local mySouls = S.GetSouls(bot) or 0
                            local cap = (S.GetMaxSouls and S.GetMaxSouls(bot)) or ((C.LASTHIT and C.LASTHIT.SOUL_CAP) or 20)
                            if mySouls < cap then
                                soulBonus = ((C.LASTHIT and C.LASTHIT.SOUL_LH_BONUS) or 14.0)
                                    * (1.0 - math.min(1.0, mySouls / math.max(1, cap)) * 0.5)
                            end
                        end
                    end
                    local score = typePrio + valueBonus + gamblePen + soulBonus - (cand.kTargetImpact * 3.0)
                    if score > bestScore then
                        bestScore = score
                        best = cand
                    end
                end
            end
        end
    end

    return best
end

-- Backwards-compatible public helper used by legacy callers in bot_nevermore.lua
function L.GetBestTarget(bot, enemyCreeps, allyCreeps, enemyAttackers, allyAttackers, enemyNearWave)
    U.BeginPredictionFrame()
    local cands = L.ScanCreepCandidates(bot, enemyCreeps, allyCreeps, allyAttackers, enemyAttackers, nil, nil)
    local best = L.SelectBestRightClickPlan(bot, cands, true)
    if best then
        return best.creep, best.isDeny, best
    end
    return nil, false, nil
end

-- Dual-Value Shadowraze CS (`Enemy Hero + Creep in Same 250u Coil`) + Exact Pre-Impact Alive Check:
-- Verified on live replay `auto-20261021-1713-start-ShaNachnetsya.dem` (`tk=14946 -> 14950 -> 14964`):
--   1. NEVER waste Shadowraze on a solo creep when the enemy hero is NOT inside that same 250u coil!
--   2. ONLY cast Shadowraze for CS when:
--      (A) PRIMARY DUAL-VALUE COIL (`heroInSameCoil == true`): `enemyHero` is alive, visible,
--          AND inside `235u` of `rSpot` BOTH right now AND at impact (`+0.55s`), taking BOTH
--          the +43g creep last-hit AND full Hero Shadowraze nuke + stack in a single 75-mana cast!
--      (B) SIMULTANEOUS MULTI-CREEP RESCUE (`multiKills >= 2` with `mana >= 165`): 2+ enemy creeps
--          dying simultaneously in the same 250u circle that right-click cooldown CANNOT reach both.
--   3. STRICT PRE-IMPACT ALIVE CHECK: `hpAlive > 10` at `(castTotalT - 1)` ticks is MANDATORY
--      (NO `or cand.effClose >= castTotalT` bypass!) so we NEVER start a 0.55s coil on a creep
--      already doomed to an incoming tower/creep projectile (`tk=14950`), AND every cast invokes
--      `startRazeCb(ab, c, rSpot, 250, true)` for 0-tick `Action_ClearActions(true)` S-cancel!
function L.TryRazeSecureCS(bot, candidates, enemyHero, startRazeCb)
    local mana = bot:GetMana() or 0
    if mana < 75 then return false end
    local razeCastTicks = (C.BALLISTIC and C.BALLISTIC.RAZE_CAST_TICKS) or 17
    local bLoc = bot:GetLocation()
    local curYaw = (bot.GetFacing and bot:GetFacing()) or 0
    local degPerTick = math.deg((C.BALLISTIC and C.BALLISTIC.SF_TURN_RATE) or 0.90)
    local hasHero = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
    -- Stack-Discipline Self-Root Guard (`R1_2039` `01:59.73` Fix!):
    -- NEVER self-root `0.55s` casting a non-hero-kill creep raze when:
    --   (a) we carry `>= 2` enemy raze stacks (`myRem > 0.3s`), OR
    --   (b) our 1st enemy raze stack is `<= 2.20s` from expiring completely while enemy can follow up with `W`/`Q`!
    if hasHero then
        local mySt, myRem = U.GetShadowrazeDebuff(bot)
        local enPotMana = U.GetPotentialManaForRaze(enemyHero)
        local dHero = U.DistanceBetweenLocations(bLoc, enemyHero:GetLocation())
        if enPotMana >= 75 then
            if (mySt or 0) >= 2 and (myRem or 0) > 0.30 and dHero < 1020 then
                return false
            end
            if (mySt or 0) == 1 and (myRem or 0) > 0.20 and (myRem or 0) <= 2.20 and dHero < 810 then
                return false
            end
        end
    end

    local bestAb, bestCand, bestSpot, bestAng, bestScore = nil, nil, nil, 0, -1
    local outRazed = hasHero and U.IsOutRazedTier and U.IsOutRazedTier(bot, enemyHero) or false
    for _, cand in ipairs(candidates) do
        if not cand.isDeny and cand.creep and U.CanQuery(cand.creep)
            and cand.creep:IsAlive() and cand.creep:GetHealth() > 0 then
            local c = cand.creep
            local cLoc = c:GetLocation()
            local d = U.DistanceBetweenLocations(bLoc, cLoc)

            for _, spec in ipairs(RAZE_SPECS) do
                if math.abs(d - spec.dist) <= (spec.radius - 16) then
                    local ab = bot:GetAbilityByName(spec.slot)
                    if ab and ab:IsFullyCastable() then
                        local baseDmg = U.GetRazeDamage(bot, ab)
                        local magicDmg = math.floor(c:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL))

                        -- Solve BOTH direct creep yaw AND 2D Dual-Value midpoint yaw (`0.5 * (cLoc + hPred)`)
                        -- so off-axis `Creep + Hero` pairs inside the same 250u Shadowraze circle are NEVER missed!
                        local aimYaws = {}
                        local creepYaw = math.deg(math.atan2(cLoc.y - bLoc.y, cLoc.x - bLoc.x)) % 360
                        if hasHero then
                            local roughPred = U.PredictPosition(enemyHero, razeCastTicks / 30.0)
                            local mx = 0.5 * (cLoc.x + roughPred.x)
                            local my = 0.5 * (cLoc.y + roughPred.y)
                            if math.abs(mx - bLoc.x) > 1 or math.abs(my - bLoc.y) > 1 then
                                aimYaws[#aimYaws + 1] = math.deg(math.atan2(my - bLoc.y, mx - bLoc.x)) % 360
                            end
                        end
                        aimYaws[#aimYaws + 1] = creepYaw

                        for _, wantYaw in ipairs(aimYaws) do
                            local ang = math.abs(((wantYaw - curYaw + 180) % 360) - 180)
                            local turnT = (ang > 11.5) and math.ceil((ang - 11.5) / degPerTick) or 0
                            local castTotalT = turnT + razeCastTicks
                            local tImpact = castTotalT / 30.0
                            local tBefore = math.max(0.033, (castTotalT - 1) / 30.0)
                            local hpAtCast = U.PredictHPWithContext(cand.ctx, c, tImpact, "max")
                            local hpAlive  = U.PredictHPWithContext(cand.ctx, c, tBefore, "min")
                            local rad = math.rad(wantYaw)
                            local rSpot = Vector(bLoc.x + math.cos(rad) * spec.dist, bLoc.y + math.sin(rad) * spec.dist, bLoc.z or 128)

                            if hpAlive > 10 and hpAtCast > 0 and hpAtCast <= magicDmg
                                and U.DistanceBetweenLocations(rSpot, cLoc) <= 240 then
                                local heroInSameCoil = false
                                if hasHero then
                                    local hNow = enemyHero:GetLocation()
                                    local hPred = U.PredictPosition(enemyHero, tImpact)
                                    if U.DistanceBetweenLocations(rSpot, hNow) <= 240
                                        and U.DistanceBetweenLocations(rSpot, hPred) <= 230 then
                                        heroInSameCoil = true
                                    end
                                end

                                -- AoE Splash Safety + Multi-Creep Kill Count across all enemy creeps
                                local ruinsOtherCreep = false
                                local multiKills = 1
                                for _, oc in ipairs(candidates) do
                                    if not oc.isDeny and oc.creep ~= c and U.CanQuery(oc.creep) and oc.creep:IsAlive() then
                                        if U.DistanceBetweenLocations(rSpot, oc.creep:GetLocation()) <= 255 then
                                            local oDmg = math.floor(oc.creep:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL))
                                            local oRem = oc.creep:GetHealth() - oDmg
                                            local oMin = U.SFDamageRange(bot, oc.creep).min
                                            if oRem <= 0 then
                                                multiKills = multiKills + 1
                                            elseif oRem > 0 and oRem <= oMin + 28 then
                                                ruinsOtherCreep = true
                                                break
                                            end
                                        end
                                    end
                                end

                                local rightClickImpossible = cand.lethalRightClick
                                    or (cand.kOpen == -1 and cand.effClose >= castTotalT)
                                    or (cand.kOpen >= 0 and cand.totalT > cand.effClose + 1)
                                local allowDoubleCreepRescue = (not heroInSameCoil)
                                    and multiKills >= 2
                                    and rightClickImpossible
                                    and mana >= 165
                                -- Pro Anti-Freeze & Contested-Deny Ranged-Creep Rescue:
                                --   1. When zoned (`d >= 530` or `outRazed`) and right-click cannot reach, rescue with `E` (or `W` at `>= 530u`).
                                --   2. When rival SF stands inside deny reach (`<= 560u` of ranged creep) with a physical damage lead
                                --      (`enDenyAvg >= myMin + 8`) and the ranged creep has ALREADY entered rival SF's legal 1-shot deny zone
                                --      (`myMin + 4 < cHp <= enDenyAvg + 10` & `< 50%` MaxHP), execute it with Raze before rival SF denies +69 XP!
                                local allowZonedRangedRescue = (not heroInSameCoil)
                                    and cand.isRanged
                                    and (spec.slot == "nevermore_shadowraze3" or (spec.slot == "nevermore_shadowraze2" and d >= 530))
                                    and rightClickImpossible
                                    and (outRazed or d >= 530)
                                    and mana >= 145
                                local allowContestedRangedDenySteal = false
                                if (not heroInSameCoil) and cand.isRanged and hasHero and mana >= 150
                                    and (spec.slot == "nevermore_shadowraze2" or spec.slot == "nevermore_shadowraze3") then
                                    local cHpNow = c:GetHealth() or 999
                                    local cMaxHp = math.max(1, c:GetMaxHealth() or 300)
                                    if cHpNow * 2 < cMaxHp and U.DistanceBetweenLocations(enemyHero:GetLocation(), cLoc) <= 560 then
                                        local myMinR = U.SFDamageRange(bot, c).min
                                        local enDenyAvg = U.SFDamageRange(enemyHero, c).avg
                                        if enDenyAvg >= myMinR + 8 and cHpNow > myMinR + 4 and cHpNow <= enDenyAvg + 10 then
                                            allowContestedRangedDenySteal = true
                                        end
                                    end
                                end

                                if not ruinsOtherCreep
                                    and (heroInSameCoil or allowDoubleCreepRescue or allowZonedRangedRescue or allowContestedRangedDenySteal) then
                                    local score = (heroInSameCoil and 1000 or (allowDoubleCreepRescue and 240 or 180))
                                        + multiKills * 90
                                        + (cand.isRanged and 55 or 20)
                                        - turnT * 8
                                    if score > bestScore then
                                        bestAb = ab
                                        bestCand = cand
                                        bestSpot = rSpot
                                        bestAng = ang
                                        bestScore = score
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if bestAb and bestCand and bestSpot then
        if bestAng > degPerTick + 11.5 then
            bot:Action_MoveToLocation(bLoc + (bestSpot - bLoc):Normalized() * 28)
        else
            if startRazeCb then
                startRazeCb(bestAb, bestCand.creep, bestSpot, 250, true)
            else
                bot:Action_UseAbility(bestAb)
            end
        end
        return true
    end
    return false
end

-- Exact Algebraic Under-Tower HP Prep Solver (Zero Over-Attack Guarantee via m_flLastAttackTime lock)
function L.TryUnderTowerPrep(bot, enemyCreeps, allyCreeps, allySideAttackers, enemySideAttackers, allyTowers, enemyTowers, candidates, enemyHero, race)
    local curLAT = (bot.GetLastAttackTime and bot:GetLastAttackTime()) or -100
    if L._prepExpire and GameTime() < L._prepExpire - 2.0 then
        L._prepCreep = nil
        L._prepExpire = 0
    end
    -- CRITICAL (`9056469656.dem` `01:20` Root Cause!):
    -- Valve C++ `CDOTA_BaseNPC::StartAttack` stamps `m_flLastAttackTime` on TICK 1 of windup (`0.46s` BEFORE launch!),
    -- so checking `curLAT > L._prepStartLAT` S-cancelled 100% of under-tower prep swings on frame 2 without firing 1 bolt!
    -- Instead, detect actual projectile release directly from `L._prepCreep:GetIncomingTrackingProjectiles()` (`p.caster == bot`)!
    if L._prepCreep then
        local launched = false
        if U.CanQuery(L._prepCreep) then
            for _, p in pairs(U.SafeGetIncomingProjectiles(L._prepCreep)) do
                if p.is_attack and p.caster == bot then
                    launched = true
                    break
                end
            end
        end
        if not U.CanQuery(L._prepCreep) or GameTime() > L._prepExpire or launched then
            if launched then
                bot:Action_ClearActions(true)
            end
            L._prepCreep = nil
            L._prepExpire = 0
        else
            -- Keep finishing the single locked prep swing unless an urgent CS just opened
            return true
        end
    end

    local spaTicks = math.ceil((bot:GetSecondsPerAttack() or 1.25) * 30.0)
    -- Never start a prep hit if ANY creep needs a real last hit / deny within spaTicks + 16 ticks!
    for _, cand in ipairs(candidates) do
        if cand.kOpen >= 0 and cand.kOpen <= spaTicks + 16 and not cand.lethalRightClick then
            return false
        end
    end

    -- Never distract SF from executing a low-HP enemy hero (`<= 350 HP`, e.g. `S29` `02:32.92` `284 HP` ramp brawl!),
    -- nor swing prep hits while low HP & being poked (`2:48` fix!)
    if enemyHero and U.CanQuery(enemyHero) and (enemyHero:GetHealth() or 9999) <= 350
        and GetUnitToLocationDistance(bot, enemyHero:GetLocation()) <= 700 then
        return false
    end
    local beingPokedNow = enemyHero and U.CanQuery(enemyHero)
        and ((enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.8)))
    if beingPokedNow and (bot:GetHealth() or 9999) <= 380 then
        return false
    end

    -- Exact 1- & 2-Step Ballistic Modular Under-Tower Prep (`9056469656.dem` `01:20` Lvl 2 `58..64` vs `550 HP` Fix!):
    -- Why `k in {1, 2}` prep steps is mandatory under T1:
    --   - At Lvl 2 (`myMin = 58, myAvg = 61`) vs `550 HP` melee under T1 (`tDmg = 97`):
    --     * `0` preps -> `550 - 5*97 = 65 HP > 58` (T1 steals 3/3 melee creeps at `01:20`!).
    --     * `1` prep  -> `550 - 61 - 4*97 = 101 HP` -> `101 - 97 = 4 HP` (still needs a 2nd prep!).
    --     * `2` preps -> `550 - 2*61 - 4*97 = 40 HP` inside `[5, 56]` -> `100%` clean 1-shot CS!
    --   - Meanwhile, on Ranged creeps (`300 - 2*109 = 82 <= 84` or `300 - 3*97 = 9 <= 58`), `rem0` ALREADY lies in
    --     `[1, myMin]`, so `remNow > myMin` is `false` -> `0` preps fired, NEVER breaking an already clean 1-shot!
    local mySpa = (bot.GetSecondsPerAttack and bot:GetSecondsPerAttack()) or 1.25
    for _, t in pairs(allyTowers or {}) do
        if U.CanQuery(t) then
            local _, _, towerRawAvg = U.SampleRawDamageRange(t)
            local tSpa = (t.GetSecondsPerAttack and t:GetSecondsPerAttack()) or 0.818
            if tSpa <= 0.1 then tSpa = 0.818 end
            local okTT, tCurTarget = false, nil
            if t.GetAttackTarget then okTT, tCurTarget = pcall(t.GetAttackTarget, t) end
            if not okTT then tCurTarget = nil end
            if not tCurTarget then
                local curTickPrep = math.floor(GameTime() * 30.0 + 0.5)
                local tRec = U._unitTrack and U._unitTrack[t]
                if tRec and tRec.inferredTowerTarget and U.CanQuery(tRec.inferredTowerTarget)
                    and tRec.inferredTowerTarget:IsAlive() and curTickPrep <= (tRec.inferredTowerTargetUntil or -1) then
                    tCurTarget = tRec.inferredTowerTarget
                end
            end
            local towerActivelyFiring = (tCurTarget ~= nil)
            if not towerActivelyFiring then
                for _, c in pairs(enemyCreeps or {}) do
                    if U.CanQuery(c) then
                        for _, p in pairs(U.SafeGetIncomingProjectiles(c)) do
                            if p.is_attack and p.caster == t then towerActivelyFiring = true; break end
                        end
                    end
                    if towerActivelyFiring then break end
                end
            end

            -- CRITICAL (`9056469656.dem` `01:20` Fix!): NEVER prep unless `t` is ACTUALLY firing at creeps,
            -- and sort strictly by C++ `CDOTA_BaseNPC_Tower` kill order (`tCurTarget` first, then closest to `t`)!
            local orderedUnderT1 = {}
            if towerActivelyFiring then
                for _, c in pairs(enemyCreeps or {}) do
                    if U.CanQuery(c) then
                        local dT = GetUnitToLocationDistance(t, c:GetLocation())
                        if dT <= 730 then
                            orderedUnderT1[#orderedUnderT1 + 1] = { c = c, d = dT, active = (c == tCurTarget) }
                        end
                    end
                end
            end
            table.sort(orderedUnderT1, function(a, b)
                if a.active ~= b.active then return a.active end
                return a.d < b.d
            end)

            for _, entry in ipairs(orderedUnderT1) do
                local c = entry.c
                -- `auto-20261023-1329-start-ShaNachnetsya.dem` `tk=6182..6240` Fix:
                -- NEVER ignore an enemy hero right-clicking us inside `<= 640u` while our T1 is busy shooting creeps
                -- (`tCurTarget ~= enemyHero`)! Yield immediately so `HandleAntiFreeHarassRetaliation` punishes him!
                local enemyFreeHittingUs = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
                    and tCurTarget ~= enemyHero
                    and GetUnitToLocationDistance(bot, enemyHero:GetLocation()) <= 640
                    and ((enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
                        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.35)))
                local safePrepPos = L.EnemyCannotPunishLane(bot, enemyHero, bot:GetHealth())
                    or not IsPositionLethalFromEnemy(bot, bot:GetLocation(), enemyHero, race)
                if not enemyFreeHittingUs and safePrepPos then
                    local tDmg = U.CalcExactIntDamage(t, c, towerRawAvg)
                    local sfRange = U.SFDamageRange(bot, c)
                    local myMin, myAvg = sfRange.min, sfRange.avg
                    -- Account for ALL projectiles ALREADY in flight (`tower` AND `bot` prep bolt!)
                    local hpEff = c:GetHealth()
                    local hasTowerBoltInAir = false
                    for _, p in pairs(U.SafeGetIncomingProjectiles(c)) do
                        if p.is_attack then
                            if p.caster == t then
                                hpEff = hpEff - tDmg
                                hasTowerBoltInAir = true
                            elseif p.caster == bot then
                                hpEff = hpEff - myAvg
                            end
                        end
                    end
                    if tDmg > 0 and hpEff > myMin + 6 then
                        local kShotsRaw = math.max(1, math.floor(hpEff / tDmg))
                        -- Exact Stochastic Drift + Creep Regen Margin (`+0.5 HP/s` regen + T1 min-roll spread over `kShots`!):
                        -- Without this margin, `550 - 5*96 = 70 <= 71` and `300 - 2*108 = 84 <= 84` looked "safe",
                        -- then `+2 HP` creep regen + T1 low rolls pushed actual post-T1 HP to `74..76` & `87 HP`,
                        -- leaving `1–5 HP` slivers on EVERY creep under T1 (`s30_probe`: `c4: 87 -> 1 HP` at `tk=5768`!)!
                        -- Also guard against the opposite edge (`remNow <= 8`, where a high T1 roll `98` kills `98 -> 0` directly!).
                        local driftMargin = math.min(18, kShotsRaw * 2 + 4)
                        local safeNoPrepCeil = math.max(8, myMin - driftMargin)
                        local remNow = hpEff % tDmg
                        if remNow == 0 then remNow = tDmg end
                        if remNow > safeNoPrepCeil then
                            local totalTicksNow = U.GetExactBallisticTicks(bot, c)
                            local upperClean = math.max(8, myMin - math.min(12, kShotsRaw * 2 + 2))
                            local bestPrep = false
                            for nPreps = 1, 2 do
                                local hpAfterN = hpEff - nPreps * myAvg
                                -- STRICT INVARIANT (`v4.2.0` `Demo 2` `0:45.37` `550/150/50 HP` @ `tDmg=100, myAvg=47` Fix!):
                                -- `hpAfterN >= tDmg + 2` and `remN >= 2` unlock exact algebraic preps on BOTH `550 -> 503`
                                -- (`503 % 100 = 3 + regen = 5..8 HP`) AND `150 -> 103` (`103 - 98 = 5 HP`) while still guaranteeing
                                -- at least `1` full non-lethal T1 bolt survives (`EarlyHit == 0`)!
                                if hpAfterN >= tDmg + 2 then
                                    local remN = hpAfterN % tDmg
                                    if remN == 0 then remN = tDmg end
                                    if remN >= 2 and remN <= upperClean then
                                        local towerShotsToOpen = math.max(1, math.floor((hpAfterN - remN) / tDmg + 0.5))
                                        local timeUntilSteal = entry.active
                                            and ((towerShotsToOpen + 0.70) * tSpa)
                                            or ((towerShotsToOpen + 2.0) * tSpa)
                                        local reloadNeed = nPreps * mySpa + (totalTicksNow / 30.0) + 0.05
                                        if timeUntilSteal >= reloadNeed then
                                            bestPrep = true
                                            break
                                        end
                                    end
                                end
                            end
                            if bestPrep then
                                L._prepCreep = c
                                L._prepStartLAT = curLAT
                                L._prepExpire = GameTime() + 1.1
                                bot:Action_AttackUnit(c, true)
                                return true
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

-- Exact 30.000 Hz Zero-Cancel Phase-Locked Ballistic Controller (`0–1` Tick Arrival, `0` Fake Swing Cancels!)
function L.ExecutePhaseLockedCS(bot, plan, s, P)
    local target = plan.creep
    local curTick = math.floor(GameTime() * 30.0 + 0.5)    local rec = U._unitTrack[bot]
    local dmgRange = U.SFDamageRange(bot, target)
    local myMinDmg = dmgRange.min
    local maxHP = math.max(1, target:GetMaxHealth())

    -- 1. If our bot is ALREADY mid-windup on `target`, inspect exact arrival tick of THIS active swing!
    -- CRITICAL SOURCE 2 INTRA-TICK LAW (`9058240714.dem` `2:50`, `2:59` & `val = 1..18 HP` slivers fix!):
    -- `CProjectileManager` delivers SF's bolt AT THE START of tick `predImpact` BEFORE same-tick creep melee hits,
    -- so true HP upon bolt impact is the HP at the end of tick `(predImpact - 1)` (`hpBeforeSameTickHits`)!
    if rec and rec.wasAnim and rec.launchTick and rec.launchTick >= curTick and bot:GetAttackTarget() == target then
        local predImpact = (rec.launchTick - curTick) + plan.fT
        local hpAtPred = (predImpact <= 0)
            and target:GetHealth()
            or U.PredictHPWithContext(plan.ctx, target, (predImpact - 1) / 30.0, "max")
        local hpAtPredMin = U.PredictHPWithContext(plan.ctx, target, predImpact / 30.0, "min")
        local legalDeny = (not plan.isDeny) or (hpAtPred * 2 < maxHP)

        -- If target is ALREADY provably dead BEFORE our projectile arrives (`hpAtPred == 0`), S-cancel on tick 0 (`S11`)!
        if hpAtPred <= 0 and hpAtPredMin <= 0 then
            bot:Action_ClearActions(true)
            return true
        end

        -- THIS SWING IS LOCKED ON TARGET TO HIT IN [0, 1] TICKS OF KILLABLE (`A07`: AND alive before `effClose + 1`) -> DO NOT TOUCH IT!
        if (predImpact >= plan.kTargetImpact and predImpact <= (plan.effClose or 999) + 1)
            or (hpAtPred > 0 and hpAtPred <= myMinDmg and legalDeny) then
            return true
        end

        -- ONLY abort an already-started swing if the creep unexpectedly stopped taking damage and our bolt
        -- would genuinely arrive BEFORE killable threshold (`hpAtPred > myMinDmg`)!
        if (rec.launchTick - curTick) <= 1 then
            bot:Action_ClearActions(true)
            return true
        end
        return true
    end

    -- 2. Not mid-windup on `target` right now: compute exact integer slack `freshDelta`
    local freshDelta = plan.kTargetImpact - plan.totalT
    local nowG = GameTime()
    local liveEnemy = s and s.enemy
    local hasLiveEnemy = liveEnemy and U.CanQuery(liveEnemy) and liveEnemy:IsAlive()
    local dLiveEnemy = hasLiveEnemy and GetUnitToLocationDistance(bot, liveEnemy:GetLocation()) or 9999

    -- Two-Phase CS Slack Weaving (`v5.0.0` Pro Mid Upgrade — fixes `1000+` right-click deficit & silent `E` coils):
    --   * COMMIT PHASE (`freshDelta <= 18` for enemy CS, `<= 10` for ally deny): 100% sacred phase-lock (`0` missed CS!).
    --   * SLACK PHASE (`freshDelta >= 19` for enemy CS, `>= 11` for ally deny): compute `freeSlackSec = (freshDelta - 4) / 30`
    --     and yield (`return false` with `L._imminentCS == false`) whenever ANY safe combat/punish action fits inside the
    --     slack window BEFORE we must pre-align & start our CS swing!
    local enemyPokingDuringWait = hasLiveEnemy and dLiveEnemy <= 965
        and ((liveEnemy.GetAttackTarget and liveEnemy:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(liveEnemy, 1.45)))
    local alreadySwingingAtHero = hasLiveEnemy and U.IsAttackingAction(bot) and bot:GetAttackTarget() == liveEnemy
    local commitCutoff = plan.isDeny and 10 or 18
    local mySpaNow = math.max(0.65, bot:GetSecondsPerAttack() or 1.55)
    if freshDelta > commitCutoff and hasLiveEnemy then
        local freeSlackSec = (freshDelta - 4) / 30.0
        local enemySalving = U.IsEnemyHighValueRegen and U.IsEnemyHighValueRegen(liveEnemy) and dLiveEnemy <= 965
        -- Shadowraze weave does NOT put basic attack on cooldown (`0.55s` cast point), so `freeSlackSec >= 0.72` suffices!
        local enemyRootedCS = U.IsAttackingAction(liveEnemy)
            and (not liveEnemy.GetAttackTarget or liveEnemy:GetAttackTarget() ~= bot)
            and dLiveEnemy <= 740 and freeSlackSec >= 0.72 and (bot:GetMana() or 0) >= 130
        local myAtkReady = (nowG - (bot:GetLastAttackTime() or -100)) >= (mySpaNow * 0.90)
        local aggroCdActive = nowG < (((U._State and U._State.myCreepAggroCdUntil) or 0) - 0.25)
        local nearestEnemyCreepD = 9999
        for _, ec in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if dc < nearestEnemyCreepD then nearestEnemyCreepD = dc end
            end
        end
        -- `v7.0.0` CS-Preservation Fix (`ShaNachnetsya.dem` 16 CS vs 17 Dire-T1 CS root cause!):
        -- Right-clicking the enemy hero puts SF's basic attack on its FULL `mySpaNow` (~1.45s) cooldown,
        -- so hero right-click weaves MUST require `freeSlackSec >= mySpaNow + 0.38` (NEVER `mySpaNow * 0.45`!)
        -- AND zero creep-aggro pull (`aggroCdActive or nearestEnemyCreepD > 502`, NEVER overridden by `enMana < 75`!).
        local zeroAggroPokeReady = myAtkReady and freeSlackSec >= (mySpaNow + 0.38)
            and dLiveEnemy <= (bot:GetAttackRange() or 525) + 55
            and (aggroCdActive or nearestEnemyCreepD > 502)
            and not (U.IsOutRazedTier and U.IsOutRazedTier(bot, liveEnemy))
            and (bot:GetHealth() or 0) >= 280
        local dominantZonePunish = false
        if freeSlackSec >= 0.80 and dLiveEnemy <= 835
            and U.IsLaneDominant and U.IsLaneDominant(bot, s, nil) then
            local eLocSlack = liveEnemy:GetLocation()
            local dWaveSlack = 9999
            for _, ac in pairs((s and s.allyCreeps) or {}) do
                if U.CanQuery(ac) and ac:IsAlive() then
                    local dw = U.DistanceBetweenLocations(ac:GetLocation(), eLocSlack)
                    if dw < dWaveSlack then dWaveSlack = dw end
                end
            end
            if dWaveSlack <= 790 then
                local manaSlack = bot:GetMana() or 0
                local razeInBand = false
                if manaSlack >= 135 or (manaSlack >= 75 and (liveEnemy:GetHealth() or 999) <= 360) then
                    for _, spec in ipairs({
                        { "nevermore_shadowraze1", 200 },
                        { "nevermore_shadowraze2", 450 },
                        { "nevermore_shadowraze3", 700 },
                    }) do
                        local abS = bot:GetAbilityByName(spec[1])
                        if abS and abS:GetLevel() > 0 and abS:IsCooldownReady() and math.abs(dLiveEnemy - spec[2]) <= 195 then
                            razeInBand = true
                            break
                        end
                    end
                end
                local lightWavePoke = myAtkReady and freeSlackSec >= (mySpaNow + 0.38)
                    and dLiveEnemy <= (bot:GetAttackRange() or 525) + 50
                    and #((s and s.enemyCreeps) or {}) <= 2
                if razeInBand or lightWavePoke then
                    dominantZonePunish = true
                end
            end
        end
        local safePokeAnswer = enemyPokingDuringWait and (freeSlackSec >= (mySpaNow + 0.32) or (bot:GetHealth() or 999) <= 245)
        if safePokeAnswer or enemySalving or enemyRootedCS or zeroAggroPokeReady or dominantZonePunish then
            return false
        end
    end
    if (enemyPokingDuringWait and (bot:GetHealth() or 999) <= 245)
        or (alreadySwingingAtHero and freshDelta >= math.ceil((mySpaNow + 0.30) * 30)) then
        return false
    end

    -- Source 2 Lane Creep Aggro & Ranged-Creep Reset Physics (`v5.0.0`):
    --   1. During the `2.30s` forced protective chase (`nowG < myCreepChaseUntil`), A-clicking an allied creep CANNOT drop
    --      aggro in Source 2 — kite back `435u` instead of wasting a tick attacking our own creep!
    --   2. An enemy ranged creep (`500u` range) NEVER re-evaluates `Condition 1/3` unless forced to move (`dc > 505u`)!
    local creepsAggroOnMeDuringWait = false
    local rangedAggroCreep = nil
    local recentCreepHitWait = (bot.WasRecentlyDamagedByCreep and bot:WasRecentlyDamagedByCreep(0.85)) or false
    if s and s.enemyCreeps then
        for _, ec in pairs(s.enemyCreeps) do
            if U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if (ec.GetAttackTarget and ec:GetAttackTarget() == bot) or (recentCreepHitWait and dc <= 215) then
                    creepsAggroOnMeDuringWait = true
                    local ecRange = (ec.GetAttackRange and ec:GetAttackRange()) or 100
                    if ecRange > 300 and dc <= 505 then
                        rangedAggroCreep = ec
                    end
                end
            end
        end
    end
    local chaseLockedNow = nowG < (((U._State and U._State.myCreepChaseUntil) or 0) - 0.08)
    if creepsAggroOnMeDuringWait and not chaseLockedNow and freshDelta >= 8 and s and s.allyCreeps then
        if rangedAggroCreep and freshDelta >= 18 then
            local rcLoc = rangedAggroCreep:GetLocation()
            local fnt = P.GetFountain(bot)
            local stepOut = rcLoc + (fnt - rcLoc):Normalized() * 520
            if U.DistanceBetweenLocations(stepOut, target:GetLocation()) <= (bot:GetAttackRange() or 525) + 45 then
                bot:Action_MoveToLocation(stepOut)
                return true
            end
        end
        if L._lastDeaggroAt and nowG < L._lastDeaggroAt then
            L._lastDeaggroAt = -100
        end
        if nowG >= (L._lastDeaggroAt or -100) + 1.30 then
            local maxDeaggroReach = (bot:GetAttackRange() or 525) + 35
            local bestAlly, bestAllyDist = nil, math.huge
            for _, ac in pairs(s.allyCreeps) do
                if U.CanQuery(ac) and ac:IsAlive() and ac ~= target and (ac:GetHealth() or 0) > 65 then
                    local da = GetUnitToLocationDistance(bot, ac:GetLocation())
                    if da <= maxDeaggroReach and da < bestAllyDist then
                        bestAllyDist, bestAlly = da, ac
                    end
                end
            end
            if bestAlly then
                L._lastDeaggroAt = nowG
                bot:Action_AttackUnit(bestAlly, true)
                return true
            end
        end
    end

    -- Helper: ensure slack positioning (`optPos`) NEVER pulls SF forward into lethal enemy range or onto enemy ramp
    -- (`auto-20261031-0230` `01:00.3`, `01:51.7`, `02:01.4`, `02:08.3` Root-Cause Fix!)
    local function sanitizeSlackOptPos(optPos)
        if not optPos then return nil end
        local bCur = bot:GetLocation()
        local cCur = target:GetLocation()
        local fnt = P.GetFountain(bot)
        if (enemyPokingDuringWait or creepsAggroOnMeDuringWait) then
            optPos = cCur + (fnt - cCur):Normalized() * math.min(460, (bot:GetAttackRange() or 525) - 40)
        end
        if s and #(s.enemyCreeps or {}) == 0 and s.enemyT1Alive ~= false and s.enemyT1Loc
            and U.DistanceBetweenLocations(optPos, s.enemyT1Loc) < 610 then
            optPos = s.enemyT1Loc + (fnt - s.enemyT1Loc):Normalized() * 610
        end
        if hasLiveEnemy then
            local eCur = liveEnemy:GetLocation()
            local dNowE = U.DistanceBetweenLocations(bCur, eCur)
            local dOptE = U.DistanceBetweenLocations(optPos, eCur)
            local inReachAlready = U.DistanceBetweenLocations(bCur, cCur) <= (bot:GetAttackRange() or 525) - 18
            local cautiousState = ((bot:GetHealth() or 999) <= 390)
                or ((liveEnemy:GetLevel() or 1) > (bot:GetLevel() or 1))
                or (U.IsOutRazedTier and U.IsOutRazedTier(bot, liveEnemy))
                or (((U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(bot)) or 0) >= 1)
            if inReachAlready and cautiousState and dOptE < dNowE - 18 then
                return nil
            end
            local raceRef = (U._K and U._K._lastRace) or nil
            if IsPositionLethalFromEnemy(bot, optPos, liveEnemy, raceRef, plan.isDeny) then
                local maxBack = cCur + (fnt - cCur):Normalized() * math.max(415, (bot:GetAttackRange() or 525) - 20)
                if not IsPositionLethalFromEnemy(bot, maxBack, liveEnemy, raceRef, plan.isDeny) then
                    optPos = maxBack
                else
                    return nil
                end
            end
        end
        return optPos
    end

    -- Move off river lowground (`25%` uphill miss!) or to contested safe stance (`415–480u` behind allied wave) while we have slack —
    -- UNLESS low-HP (`<= 42%`) vs a spell-ready enemy during early slack (`freshDelta >= 14`), where holding safe spacing avoids edge-dance oscillation!
    local lowHpHoldBack = hasLiveEnemy
        and ((bot:GetHealth() or 999) <= (bot:GetMaxHealth() or 600) * 0.42)
        and ((liveEnemy:GetMana() or 0) >= 75)
        and (freshDelta >= 14)
    local slackPosMode = (U.IsLaneDominant and U.IsLaneDominant(bot, s, nil)) and "AGGRESSIVE" or "NEUTRAL"
    if freshDelta >= 7 and not lowHpHoldBack and P and P.GetLasthitPosition then
        local optPos = sanitizeSlackOptPos(P.GetLasthitPosition(bot, s.enemyCreeps, s.allyCreeps, target, slackPosMode))
        if optPos and U.DistanceBetweenLocations(bot:GetLocation(), optPos) > 32 then
            bot:Action_MoveToLocation(optPos)
            return true
        end
    end

    -- Exact firing tick (`freshDelta <= 0` AND `A04` `< 50% HP` legal deny check): ONE clean swing -> ZERO self-cancels!
    local denyLegalRightNow = (not plan.isDeny) or ((target:GetHealth() or maxHP) * 2 < maxHP)
    if freshDelta <= 0 and denyLegalRightNow then
        bot:Action_AttackUnit(target, true)
        return true
    end

    -- Pre-align hero yaw to `0.00 deg` toward `target` smoothly WITHOUT fake attack-swing spam (`0` `SCancel`!):
    -- Align strictly at `freshDelta >= 3` down to `<= 2.5 deg` so on ticks `freshDelta == 2, 1, 0` hero stands dead-still at `0.0 deg`!
    local bLoc = bot:GetLocation()
    local cLoc = target:GetLocation()
    local wantYaw = math.deg(math.atan2(cLoc.y - bLoc.y, cLoc.x - bLoc.x)) % 360
    local curYaw = (bot.GetFacing and bot:GetFacing()) or wantYaw
    local angErr = math.abs(((wantYaw - curYaw + 180) % 360) - 180)

    if freshDelta >= 3 and angErr > 5.5 and U.DistanceBetweenLocations(bLoc, cLoc) > 125 then
        bot:Action_MoveToLocation(bLoc + (cLoc - bLoc):Normalized() * 15)
        return true
    end

    if freshDelta >= 4 and P and P.GetLasthitPosition then
        local optPos = sanitizeSlackOptPos(P.GetLasthitPosition(bot, s.enemyCreeps, s.allyCreeps, target, slackPosMode))
        if optPos and U.DistanceBetweenLocations(bLoc, optPos) > 28 then
            bot:Action_MoveToLocation(optPos)
            return true
        end
    end

    if U.IsAttackingAction(bot) then
        bot:Action_ClearActions(true)
    end
    return true
end

-- Non-mutating peek at the highest-priority securable CS plan (`v5.2.0` helper for `HandleCreepTankDrop` & `war_director`):
-- Returns `bestPlan, etaSec` when an enemy CS or ally deny opens within the sacred window.
function L.PeekBestPlan(bot, s)
    if not bot or not s then return nil, 999 end
    local enemyCreeps = s.enemyCreeps or {}
    local allyCreeps  = s.allyCreeps or {}
    if #enemyCreeps == 0 and #allyCreeps == 0 then return nil, 999 end
    U.BeginPredictionFrame()
    local allySideAtk, enemySideAtk = BuildAllAttackers(
        bot, enemyCreeps, allyCreeps, s.enemyTowers, s.allyTowers, s.enemy
    )
    local siegingEnemyT1 = (s.enemyT1Alive and s.enemyT1Loc and GetUnitToLocationDistance(bot, s.enemyT1Loc) <= 1150) and true or false
    local allowDenies = (not siegingEnemyT1) and (s.enemyAlive ~= false)
    local candidates = L.ScanCreepCandidates(
        bot, enemyCreeps, allowDenies and allyCreeps or {}, allySideAtk, enemySideAtk, s.enemy, nil
    )
    local plan = L.SelectBestRightClickPlan(bot, candidates, siegingEnemyT1)
    if not plan then return nil, 999 end
    local deltaTicks = math.max(0, (plan.kTargetImpact or 0) - (plan.totalT or 0))
    return plan, deltaTicks / 30.0
end

-- Master Top-Priority 30.000 Hz Sacred CS & Spacing Entry Point
function L.RunSacredCS(bot, s, race, P, startRazeCb)
    L._imminentCS = false
    local enemyCreeps = s.enemyCreeps or {}
    local allyCreeps  = s.allyCreeps or {}
    local enemyHero   = s.enemy
    if #enemyCreeps == 0 and #allyCreeps == 0 then
        return false, false
    end

    U.BeginPredictionFrame()
    local allySideAtk, enemySideAtk = BuildAllAttackers(
        bot, enemyCreeps, allyCreeps, s.enemyTowers, s.allyTowers, enemyHero
    )
    -- Smart 1v1 Ally Deny Policy (`9055695956.dem` `6:05` + `9056774541.dem` `01:45` + `9058240714.dem` `2:50` & `2:59` Fix!):
    --   1. When the rival hero is DEAD on the scoreboard (`s.enemyAlive == false`), NEVER deny our own creeps (`0` XP denied; crash wave!).
    --   2. Whenever the rival hero is ALIVE (`s.enemyAlive ~= false`) and we are NOT inside enemy T1 siege range (`> 1150u`),
    --      ALWAYS allow 100% ally denies EVEN WHEN `enemyVisible == false` (`9058240714.dem` `2:50` ranged & `2:59` melee: rival
    --      stood invisibly in fog at `(-1586, -995)`, `d = 1003u` drinking Salve for `17s` and soaked 100% full XP because the
    --      old `s.enemyAbsentFor <= 3.0` gate disabled all ally denies after 3.0s in fog!).
    --   3. While actively sieging enemy T1 (`<= 1150u`), require `>= 2` live ally shield creeps inside `755u` of enemy T1 AND
    --      snap to deny within `<= 3` slack ticks inside `SelectBestRightClickPlan` so tower DPS never stalls!
    local siegingEnemyT1 = (s.enemyT1Alive and s.enemyT1Loc and GetUnitToLocationDistance(bot, s.enemyT1Loc) <= 1150) and true or false
    local allowAllyDenies
    if siegingEnemyT1 then
        local enemyNearSiegedT1 = (s.enemyAlive ~= false)
            and ((s.enemyVisible and (s.enemyDist or 9999) <= 1650)
                or (not s.enemyVisible and (s.enemyAbsentFor or 0) <= 3.0))
        local shieldCreeps = 0
        if enemyNearSiegedT1 then
            for _, ac in pairs(allyCreeps) do
                if U.CanQuery(ac) and (ac:GetHealth() or 0) > 25
                    and GetUnitToLocationDistance(ac, s.enemyT1Loc) <= 755 then
                    shieldCreeps = shieldCreeps + 1
                end
            end
        end
        allowAllyDenies = enemyNearSiegedT1 and (shieldCreeps >= 2)
    else
        -- Outside enemy T1 siege, ALWAYS deny low-HP allied lane creeps whenever rival is alive (`100%` XP deny + wave equilibrium!)
        allowAllyDenies = (s.enemyAlive ~= false)
    end
    local candidates = L.ScanCreepCandidates(
        bot, enemyCreeps, allowAllyDenies and allyCreeps or {}, allySideAtk, enemySideAtk, enemyHero, race
    )

    -- 1. First execute Dual-Value Hero+Creep Shadowraze (or 2+ simultaneous creep rescue) with S-cancel hook!
    if L.TryRazeSecureCS(bot, candidates, enemyHero, startRazeCb) then
        return true, true
    end

    L._imminentCS = false
    for _, cand in ipairs(candidates) do
        if not cand.isDeny and cand.kOpen ~= nil and cand.kOpen >= 0 and (cand.kTargetImpact - cand.totalT) <= 18 then
            L._imminentCS = true
            break
        end
    end

    -- 2. Select highest-priority right-click last-hit / deny within the sacred horizon
    local bestPlan = L.SelectBestRightClickPlan(bot, candidates, siegingEnemyT1)
    if bestPlan then
        local planDelta = bestPlan.kTargetImpact - bestPlan.totalT
        local recNow = U._unitTrack and U._unitTrack[bot]
        local midSwingOnPlan = recNow and recNow.wasAnim and bot:GetAttackTarget() == bestPlan.creep
        local planCommitCutoff = bestPlan.isDeny and 10 or 18
        local actedCS = L.ExecutePhaseLockedCS(bot, bestPlan, s, P)
        L._imminentCS = midSwingOnPlan or (actedCS and planDelta <= planCommitCutoff) or false
        if actedCS then
            return true, true
        end
        return false, true
    end

    -- 3. Low-HP Safe Lane Spacing (Strict One-Sided Minimum-Distance Floor -> ZERO Oscillation!):
    --   * FoW Low-HP / Active-Salve Guard (`v5.2.0`): when wounded (`<= 28% HP`) or actively healing with Salve while
    --     the live enemy SF is unseen in highground FoW, anchor behind `allyT1` instead of walking into river coils!
    --   * One-Sided Floor (`targetGap = 810..860 < war_director.RELEASE_DIST = 950`):
    --     - When `d < targetGap`: step back cleanly toward fixed `P.GetBehindT1` anchor!
    --     - When `d >= targetGap`: NEVER pull inward to `eLoc + dir * 900` (eliminates the `29.5 rev/min` oscillator!).
    local hp = bot:GetHealth()
    local hpPctNow = hp / math.max(1, bot:GetMaxHealth() or 600)
    if (not enemyHero or not U.CanQuery(enemyHero)) and s.enemyAlive ~= false
        and (#enemyCreeps > 0 or #allyCreeps > 0)
        and (bot:HasModifier("modifier_flask_healing") or (hpPctNow <= 0.28 and (s.enemyAbsentFor or 99) <= 8.0)) then
        -- `9069188041.dem` `03:44.1` Death #2 Fix: NEVER walk 620u backward SW toward `GetBehindT1(210)` when already deeper!
        local nearbyFogThreat = s.enemyLastLoc and ((s.enemyAbsentFor or 99) <= 3.5)
            and (U.DistanceBetweenLocations(bot:GetLocation(), s.enemyLastLoc) <= 980)
        local safeT1
        if P and P.GetRetreatAnchor then
            safeT1 = P.GetRetreatAnchor(bot, nearbyFogThreat and 480 or 210, nearbyFogThreat and 280 or 0)
        else
            safeT1 = (P and P.GetBehindT1 and P.GetBehindT1(bot, 210)) or P.GetFountain(bot)
        end
        if safeT1 and U.DistanceBetweenLocations(bot:GetLocation(), safeT1) > 35 then
            bot:Action_MoveToLocation(safeT1)
        elseif U.IsAttackingAction(bot) then
            bot:Action_ClearActions(true)
        end
        return true, false
    end
    local enemyManaAvail = (enemyHero and U.CanQuery(enemyHero))
        and ((enemyHero:GetMana() or 0) + U.GetMangoMana(enemyHero)) or 0
    local canFinishEnemy = enemyHero and U.CanQuery(enemyHero)
        and (U.SolveLethalRace(bot, enemyHero, s).winsFirstKill
            or U.CanQuickTurnKillWithRaze(bot, enemyHero)
            or U.CanOneShotEnemyHero(bot, enemyHero)
            or (enemyHero:GetHealth() <= U.GetNRazeDamage(bot, enemyHero, 1) + 75 and (bot:GetMana() or 0) >= 75)
            or (race and race.valid and race.canKillNow))
    local enAtkAdv = (enemyHero and U.CanQuery(enemyHero) and U._K and U._K.AttackDamageVs and U._K.AttackDamageVs(enemyHero, bot)) or 54
    local enManaRegenSoon = (enemyHero and U.CanQuery(enemyHero) and enemyHero.GetManaRegen and (enemyHero:GetManaRegen() or 1.0) * 2.5) or 2.5
    local myDomSoulAtk = enemyHero and U.CanQuery(enemyHero) and hp >= math.max(230, enAtkAdv * 4.0) and U._K and U._K.AttackDamageVs
        and U._K.AttackDamageVs(bot, enemyHero) >= U._K.AttackDamageVs(enemyHero, bot) + 10
        and hp >= (enemyHero:GetHealth() or 999) * 0.76
    -- `auto-20261031-0230` `02:08.1` Death #2 Fix:
    -- NEVER claim `weHoldDryAdvantage` at `180 HP` vs `334 HP / 68 MP` Lvl-3 SF (`3` right-clicks from death, or `2.5s` from `75 MP`!)!
    local weHoldDryAdvantage = (enemyManaAvail + enManaRegenSoon < 75)
        and (hp >= math.max(255, enAtkAdv * 4.2))
        and (myDomSoulAtk
            or canFinishEnemy
            or (hp >= math.max(260, (enemyHero and U.CanQuery(enemyHero) and enemyHero:GetHealth() or 999) * 0.82)
                and (bot:GetMana() or 0) >= 75))
    local pokedLow = enemyHero and U.CanQuery(enemyHero) and hp >= 155 and hp <= 345
        and not canFinishEnemy and not weHoldDryAdvantage
        and ((enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.8)))
    local myStacksNow, myStacksRemNow = U.GetShadowrazeDebuff(bot)
    local twoStackLethalWait = enemyHero and U.CanQuery(enemyHero) and not canFinishEnemy
        and (myStacksNow or 0) >= 2 and (myStacksRemNow or 0) > 0.35 and enemyManaAvail >= 75
        and hp <= ((race and race.valid and race.oneRaze) or 200) + 110
    if enemyHero and U.CanQuery(enemyHero) and not canFinishEnemy and not weHoldDryAdvantage
        and not (not twoStackLethalWait and L.EnemyCannotPunishLane(bot, enemyHero, hp))
        and ((hp >= 165 and hp <= 295) or pokedLow or twoStackLethalWait) and (#enemyCreeps > 0 or #allyCreeps > 0) then
        local lethalRace = race and race.valid and (race.heCanKillSoon or race.losingHard)
        if not lethalRace or pokedLow or twoStackLethalWait then
            local eLoc = enemyHero:GetLocation()
            local bLoc = bot:GetLocation()
            local d = U.DistanceBetweenLocations(bLoc, eLoc)
            local targetGap = twoStackLethalWait and 955 or (pokedLow and 810 or 860)
            if d < targetGap then
                local behindT1 = (P and P.GetRetreatAnchor and P.GetRetreatAnchor(bot, 210, 0))
                    or (P and P.GetBehindT1 and P.GetBehindT1(bot, 210))
                    or P.GetFountain(bot)
                local safeAnchor
                if U.DistanceBetweenLocations(behindT1, eLoc) > d + 40 and U.DistanceBetweenLocations(bLoc, behindT1) > 35 then
                    safeAnchor = behindT1
                else
                    local away = (bLoc - eLoc)
                    if away:Length2D() < 1 then away = (P.GetFountain(bot) - bLoc) end
                    safeAnchor = bLoc + away:Normalized() * (targetGap - d + 85)
                end
                safeAnchor = U.SteerAroundObstacles(bot, safeAnchor, s)
                if U.DistanceBetweenLocations(bLoc, safeAnchor) > 32 then
                    bot:Action_MoveToLocation(safeAnchor)
                elseif U.IsAttackingAction(bot) then
                    bot:Action_ClearActions(true)
                end
                return true, false
            elseif d <= 1160 or bot:HasModifier("modifier_flask_healing") or hp < 210 then
                if U.IsAttackingAction(bot) then
                    bot:Action_ClearActions(true)
                end
                return true, false
            else
                local xpAnchor = U.SteerAroundObstacles(bot, eLoc + (bLoc - eLoc):Normalized() * 1040, s)
                if U.DistanceBetweenLocations(bLoc, xpAnchor) > 40 then
                    bot:Action_MoveToLocation(xpAnchor)
                end
                return true, false
            end
        end
    end

    -- 4. No CS needed in next ~1.70s and safe from low-HP hero focus: solve exact algebraic Under-Tower HP Prep hits!
    if L.TryUnderTowerPrep(bot, enemyCreeps, allyCreeps, allySideAtk, enemySideAtk, s.allyTowers, s.enemyTowers, candidates, enemyHero, race) then
        return true, false
    end

    -- 4.25. Pro Dual-Value Ranged-Creep Prep (`1` auto -> `Shadowraze` kills ranged creep + hits rival SF!):
    -- When no CS is imminent, we have `>= 90` mana + ready `W`/`E`, and an unattacked enemy ranged creep stands near
    -- `enemyHero` (`<= 360u`) with `razeDmg < hp <= razeDmg + myAvgDmg + 12`, land ONE setup right-click from behind
    -- our wave so the very next tick/second `TryRazeSecureCS` scores a guaranteed +54g/+69XP + Hero Stack Dual Coil!
    if enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
        and (bot:GetMana() or 0) >= 90 and (bot:GetHealth() or 0) >= 340 then
        local nowPrep = GameTime()
        local mySpa = math.max(0.65, bot:GetSecondsPerAttack() or 1.55)
        if (nowPrep - (bot:GetLastAttackTime() or -100)) >= mySpa * 0.95 then
            local wAb = bot:GetAbilityByName("nevermore_shadowraze2")
            local eAb = bot:GetAbilityByName("nevermore_shadowraze3")
            local refAb = (wAb and wAb:IsFullyCastable() and wAb) or (eAb and eAb:IsFullyCastable() and eAb) or nil
            if refAb then
                local rRaw = U.GetRazeDamage(bot, refAb, 0)
                local eLoc = enemyHero:GetLocation()
                for _, ec in pairs(enemyCreeps) do
                    if U.CanQuery(ec) and ec:IsAlive() then
                        local nm = ec:GetUnitName() or ""
                        local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                        if string.find(nm, "ranged", 1, true) and dc <= (bot:GetAttackRange() or 525) + 25
                            and U.DistanceBetweenLocations(ec:GetLocation(), eLoc) <= 360 then
                            local rMagic = math.floor(ec:GetActualIncomingDamage(rRaw, DAMAGE_TYPE_MAGICAL))
                            local myAvg = U.SFDamageRange(bot, ec).avg
                            local cHp = ec:GetHealth() or 999
                            if cHp > rMagic + 8 and cHp <= rMagic + myAvg + 10 then
                                bot:Action_AttackUnit(ec, true)
                                return true, true
                            end
                        end
                    end
                end
            end
        end
    end

    -- 4.5. `v5.0.0` Source 2 Creep-Aggro Reset & Kite-Back During Idle Wait (respects `2.3s` chase lock & `515u` ranged reset!):
    do
        local creepsHittingMe, closestAggroCreep, rangedAggroIdle, minAggroDist = 0, nil, nil, math.huge
        local recentCreepHit = (bot.WasRecentlyDamagedByCreep and bot:WasRecentlyDamagedByCreep(0.95)) or false
        for _, ec in pairs(enemyCreeps) do
            if U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if (ec.GetAttackTarget and ec:GetAttackTarget() == bot) or (recentCreepHit and dc <= 215) then
                    creepsHittingMe = creepsHittingMe + 1
                    if dc < minAggroDist then
                        minAggroDist, closestAggroCreep = dc, ec
                    end
                    if ((ec.GetAttackRange and ec:GetAttackRange()) or 100) > 300 and dc <= 505 then
                        rangedAggroIdle = ec
                    end
                end
            end
        end
        local allyShieldNear = 0
        for _, ac in pairs(allyCreeps) do
            if U.CanQuery(ac) and ac:IsAlive() and GetUnitToLocationDistance(bot, ac:GetLocation()) <= 360 then
                allyShieldNear = allyShieldNear + 1
            end
        end
        local lowOrMultiTank = (creepsHittingMe >= 2)
            or (creepsHittingMe >= 1 and ((bot:GetHealth() or 999) < (bot:GetMaxHealth() or 999) * 0.85 or allyShieldNear == 0))
        if lowOrMultiTank and closestAggroCreep then
            local nowT = GameTime()
            local chaseLocked = nowT < (((U._State and U._State.myCreepChaseUntil) or 0) - 0.08)
            local maxDeaggroReachIdle = (bot:GetAttackRange() or 525) + 35
            local bestAlly, bestAllyDist = nil, math.huge
            for _, ac in pairs(allyCreeps) do
                if U.CanQuery(ac) and ac:IsAlive() and (ac:GetHealth() or 0) > 55 then
                    local da = GetUnitToLocationDistance(bot, ac:GetLocation())
                    if da <= maxDeaggroReachIdle and da < bestAllyDist then
                        bestAllyDist, bestAlly = da, ac
                    end
                end
            end
            if L._lastDeaggroAt and nowT < L._lastDeaggroAt then
                L._lastDeaggroAt = -100
            end
            if not chaseLocked and not rangedAggroIdle and bestAlly and nowT >= (L._lastDeaggroAt or -100) + 1.35 then
                L._lastDeaggroAt = nowT
                bot:Action_AttackUnit(bestAlly, true)
                return true, true
            end
            local fnt = P.GetFountain(bot)
            local refLoc = rangedAggroIdle and rangedAggroIdle:GetLocation()
                or (bestAlly and bestAlly:GetLocation() or closestAggroCreep:GetLocation())
            local padBack = rangedAggroIdle and 525 or (bestAlly and 265 or 355)
            local kiteAnchor = U.SteerAroundObstacles(bot, refLoc + (fnt - refLoc):Normalized() * padBack, s)
            if kiteAnchor and U.DistanceBetweenLocations(bot:GetLocation(), kiteAnchor) > 25 then
                bot:Action_MoveToLocation(kiteAnchor)
                return true, true
            end
        end
    end

    -- 4.75. Dominance Equilibrium Freeze & Safe `< 50% HP` Pre-Deny (`v7.5.0`):
    -- When dominating the lane and the rival is ALREADY zoned back (`> 830u` or hiding in FoW) with no enemy CS opening
    -- inside `mySpa + 0.55s`, chip any `< 50% HP` allied creep whose post-hit HP STILL exceeds `enHeroMaxDmg + 28`!
    -- Pulls the creep equilibrium toward our highground and accelerates our own denies with ZERO risk of feeding a CS!
    if allowAllyDenies and not siegingEnemyT1 and U.IsLaneDominant and U.IsLaneDominant(bot, s, race) then
        local enemyFarEnough = (not enemyHero) or (not U.CanQuery(enemyHero))
            or (GetUnitToLocationDistance(bot, enemyHero:GetLocation()) > 830)
        if enemyFarEnough then
            local nowPD = GameTime()
            local mySpaPD = math.max(0.65, bot:GetSecondsPerAttack() or 1.35)
            local needClearTicks = math.ceil((mySpaPD + 0.55) * 30.0)
            local enemyCSOpeningSoon = false
            for _, cand in ipairs(candidates) do
                if not cand.isDeny and cand.kOpen ~= nil and cand.kOpen >= 0 and cand.kOpen <= needClearTicks then
                    enemyCSOpeningSoon = true
                    break
                end
            end
            if not enemyCSOpeningSoon and (nowPD - (bot:GetLastAttackTime() or -100)) >= mySpaPD * 0.95 then
                local enHeroRawDmg = (enemyHero and U.CanQuery(enemyHero) and enemyHero:GetAttackDamage())
                    or (s and s.enemyLastAttackDmg) or 82
                for _, ac in pairs(allyCreeps) do
                    if U.CanQuery(ac) and ac:IsAlive() then
                        local hpA = ac:GetHealth() or 999
                        local maxHpA = math.max(1, ac:GetMaxHealth() or 550)
                        local da = GetUnitToLocationDistance(bot, ac:GetLocation())
                        if (hpA * 2 < maxHpA) and da <= (bot:GetAttackRange() or 525) + 15 then
                            local myDmgRange = U.SFDamageRange(bot, ac)
                            local enHeroDmg = ac:GetActualIncomingDamage(enHeroRawDmg + 6, DAMAGE_TYPE_PHYSICAL)
                            local incomingCreepDps = 0
                            for _, ec in pairs(enemyCreeps) do
                                if U.CanQuery(ec) and ec:IsAlive() and ec.GetAttackTarget and ec:GetAttackTarget() == ac then
                                    incomingCreepDps = incomingCreepDps + 22
                                end
                            end
                            local hpAfterReload = hpA - myDmgRange.max - incomingCreepDps * (mySpaPD + 0.25)
                            if hpAfterReload >= math.max(enHeroDmg + 28, myDmgRange.min + 14) then
                                bot:Action_AttackUnit(ac, true)
                                return true, true
                            end
                        end
                    end
                end
            end
        end
    end

    -- 5. Uncontested Wave Equilibrium Stance Discipline:
    -- When uncontested (enemy absent / dead / TPing), hold crisp 175u highground CS anchor
    -- across the entire wave so walkTicks == 0 and fTicks == 4 on 100% of creeps; when an
    -- enemy hero IS live in lane and no creep opens within 68 ticks, yield to combat/spacing!
    local siegingEnemyT1Now = s.enemyT1Alive and s.enemyT1Loc and #allyCreeps >= 1
        and GetUnitToLocationDistance(bot, s.enemyT1Loc) <= 1120
    local damagedAllyDenySoon = false
    if allowAllyDenies then
        for _, ac in pairs(allyCreeps) do
            if U.CanQuery(ac) and (ac:GetHealth() or 0) > 0 and ac:GetHealth() < ac:GetMaxHealth() * 0.58 then
                damagedAllyDenySoon = true
                break
            end
        end
    end
    if not siegingEnemyT1Now and (not enemyHero or not U.CanQuery(enemyHero))
        and (#enemyCreeps >= 2 or damagedAllyDenySoon) and P and P.GetLasthitPosition then
        local anchor = P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, "NEUTRAL")
        if anchor then anchor = U.SteerAroundObstacles(bot, anchor, s) end
        if anchor and U.DistanceBetweenLocations(bot:GetLocation(), anchor) > 32 then
            bot:Action_MoveToLocation(anchor)
        elseif U.IsAttackingAction(bot) then
            bot:Action_ClearActions(true)
        end
        return true, true
    end

    -- Check whether any creep is below 72% HP so `HandlePriorityPush` does NOT blind-auto-attack mid-wave!
    local waveHasDamagedCreep = false
    for _, c in pairs(enemyCreeps) do
        if U.CanQuery(c) and c:GetHealth() < c:GetMaxHealth() * 0.72 then
            waveHasDamagedCreep = true
            break
        end
    end
    for _, c in pairs(allyCreeps) do
        if U.CanQuery(c) and c:GetHealth() < c:GetMaxHealth() * 0.65 then
            waveHasDamagedCreep = true
            break
        end
    end
    return false, waveHasDamagedCreep
end

return L
