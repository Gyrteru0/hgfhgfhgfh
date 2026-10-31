
local C = require("bots/nevermore/constants")
local S = require("bots/nevermore/souls")

local U = {}

function U.IsAttackingAction(bot)
    if not bot or not bot.GetCurrentActionType then return false end
    local act = bot:GetCurrentActionType()
    return act == BOT_ACTION_TYPE_ATTACK
        or (BOT_ACTION_TYPE_ATTACKUNIT ~= nil and act == BOT_ACTION_TYPE_ATTACKUNIT)
end

local SAFE_DISTANCE = C.SAFE_DISTANCE or {
    MIN_DISTANCE_FROM_ENEMY = 750,
    MIN_DISTANCE_CRITICAL   = 950,
    CRITICAL_HP_FACTOR      = 1.05,
    KILL_THREAT_FACTOR      = 1.20,
    SINGLE_KILL_FACTOR      = 1.10,
}

local function Atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    if x > 0 then return math.atan(y / x) end
    if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
    if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
    if x == 0 and y > 0 then return math.pi / 2 end
    if x == 0 and y < 0 then return -math.pi / 2 end
    return 0
end

local function Clamp(v, minValue, maxValue)
    if v < minValue then return minValue end
    if v > maxValue then return maxValue end
    return v
end

function U.CanQuery(unit)
    local t = type(unit)
    if t ~= "table" and t ~= "userdata" then return false end
    local ok, alive = pcall(function() return unit.IsAlive ~= nil and unit:IsAlive() end)
    if not ok or not alive then return false end
    local okS, seen = pcall(function() return unit.CanBeSeen == nil or unit:CanBeSeen() end)
    if not okS or not seen then return false end
    return true
end

function U.MergeLists(list1, list2)
    local result = {}
    if list1 then for _, v in pairs(list1) do table.insert(result, v) end end
    if list2 then for _, v in pairs(list2) do table.insert(result, v) end end
    return result
end

function U.DistanceBetweenLocations(a, b)
    if not a or not b then return math.huge end
    local dx = a.x - b.x
    local dy = a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- Cosine of the 2D angle between `unit`'s current facing direction and `targetLoc - unit:GetLocation()`.
-- Used by proactive Raze band-edge intercepts (`bot_nevermore.lua`) and facing-cone solvers.
function U.FacingCos(unit, targetLoc)
    if not unit or not targetLoc or not unit.GetLocation or not unit.GetFacing then return -1.0 end
    local uLoc = unit:GetLocation()
    if not uLoc then return -1.0 end
    local dx = (targetLoc.x or 0) - (uLoc.x or 0)
    local dy = (targetLoc.y or 0) - (uLoc.y or 0)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-4 then return 1.0 end
    local rad = math.rad(unit:GetFacing() or 0)
    return (math.cos(rad) * dx + math.sin(rad) * dy) / len
end

function U.GetRazeLabelByDistance(dist, radius)
    radius = radius or C.RAZE.STRICT_RADIUS
    local candidates = {
        { label = "near", center = C.RAZE.NEAR_CENTER },
        { label = "mid",  center = C.RAZE.MID_CENTER  },
        { label = "far",  center = C.RAZE.FAR_CENTER  },
    }
    local bestLabel = nil
    local bestDiff = math.huge
    for _, v in ipairs(candidates) do
        local diff = math.abs(dist - v.center)
        if diff < bestDiff then
            bestDiff = diff
            bestLabel = v.label
        end
    end
    if bestDiff <= radius then
        return bestLabel, bestDiff
    end
    return nil, bestDiff
end

function U.GetRazeCenterByLabel(label)
    if label == "near" then return C.RAZE.NEAR_CENTER end
    if label == "mid"  then return C.RAZE.MID_CENTER end
    if label == "far"  then return C.RAZE.FAR_CENTER end
    return nil
end


function U.GetTeamFountain(team)
    return team == TEAM_RADIANT and C.POSITIONS.MID_FOUNTAIN_RADIANT or C.POSITIONS.MID_FOUNTAIN_DIRE
end

function U.GetFountain(bot)
    return U.GetTeamFountain(bot:GetTeam())
end

-- =============================================================================
-- Exact 30.000 Hz Source 2 Discrete Attacker, Projectile & Ballistic Engine
-- =============================================================================
-- Verified empirically across all 4 Dota 2 7.41f 1v1 mid .dem replays:
--   1. In real server.so, m_flLastAttackTime updates ONLY at attack point /
--      projectile launch / melee impact (launch_srv - round(lat * 30) == 0 in
--      99.7% of all attacks), NEVER at swing start.
--   2. In real server.so, _G.ACTIVITY_ATTACK is nil while GetAnimActivity()
--      returns raw Source 2 Activity IDs 1503 / 1504 / 1505.
--   3. In real server.so, GetAttackPoint() returns unscaled KV attack point
--      (0.50 on SF), while real windup duration = base_ap * (spa / bat).
--   4. CProjectileManager steps tracking projectiles at 30 Hz with collision
--      condition dist2D <= step + targetHalfHull (12.0u creeps, 72.0u towers):
--        - Unlaunched projectile flight ticks:  max(1, ceil((d - r) / step))
--        - In-flight projectile ticks remaining: max(0, ceil((d - r) / step) - 1)

U._unitTrack = setmetatable({}, { __mode = "k" })
U._dmgCache  = setmetatable({}, { __mode = "k" })
U._ownWindupRatio = nil -- Self-calibrates on Shot #1 for 0-tick empirical windup lock

local function IsAttackAnim(act)
    if not act then return false end
    if act == 1503 or act == 1504 or act == 1505 then return true end
    if ACTIVITY_ATTACK ~= nil and act == ACTIVITY_ATTACK then return true end
    if ACTIVITY_ATTACK2 ~= nil and act == ACTIVITY_ATTACK2 then return true end
    return false
end
U.IsAttackAnim = IsAttackAnim

local function GetUnitBATAndBaseAP(u)
    if not u then return 1.0, 0.5 end
    if u.IsTower and u:IsTower() then
        local tap = (u.GetAttackPoint and u:GetAttackPoint())
        if tap == nil then tap = 0.0 end
        return 0.90, tap
    end
    local nm = (u.GetUnitName and u:GetUnitName()) or ""
    if nm:find("nevermore") or nm:find("shadow_fiend") then
        local ap = (u.GetAttackPoint and u:GetAttackPoint()) or 0.50
        return 1.60, ap
    elseif nm:find("siege") then
        return 2.70, 0.70
    elseif nm:find("ranged") then
        return 1.00, 0.50
    elseif nm:find("melee") or nm:find("flagbearer") then
        return 1.00, 0.467
    end
    local ap = (u.GetAttackPoint and u:GetAttackPoint()) or 0.50
    local spa = (u.GetSecondsPerAttack and u:GetSecondsPerAttack()) or 1.0
    return math.max(0.8, spa), ap
end
U.GetUnitBATAndBaseAP = GetUnitBATAndBaseAP

function U.GetExactWindupTicks(u, isOwnBot)
    local spa = (u and u.GetSecondsPerAttack and u:GetSecondsPerAttack()) or 1.0
    if spa <= 0 then spa = 1.0 end
    if isOwnBot and U._ownWindupRatio then
        return math.max(1, math.floor(U._ownWindupRatio * spa * 30.0 + 0.5))
    end
    local bat, baseAP = GetUnitBATAndBaseAP(u)
    return math.max(1, math.ceil(baseAP * (spa / bat) * 30.0 - 1e-6))
end

function U.GetProjectileSpeedOf(u)
    if not u then return 0 end
    if u.IsTower and u:IsTower() then return 750 end
    local ps = u.GetAttackProjectileSpeed and u:GetAttackProjectileSpeed() or 0
    if ps and ps > 0 then return ps end
    local nm = (u.GetUnitName and u:GetUnitName()) or ""
    if nm:find("siege") then return 1100 end
    if nm:find("ranged") then return 900 end
    if nm:find("nevermore") then return 1200 end
    return 0
end

function U.GetTargetHitRadius(target)
    if target and target.IsTower and target:IsTower() then return 72.0 end
    return (C.BALLISTIC and C.BALLISTIC.DEFAULT_HIT_RADIUS) or 12.0
end

-- Exact flight ticks from a new launch at `fromLoc` to `target`
function U.CalcLaunchFlightTicks(fromLoc, target, speed)
    if not speed or speed <= 0 then return 0 end
    local tLoc = target:GetLocation()
    local dx, dy = tLoc.x - fromLoc.x, tLoc.y - fromLoc.y
    local dist = math.sqrt(dx * dx + dy * dy)
    local step = speed / 30.0
    local r = U.GetTargetHitRadius(target)
    return math.max(1, math.ceil(math.max(0.0, dist - r) / step - 1e-9))
end

-- Exact remaining server ticks for an ALREADY IN-FLIGHT tracking projectile at `projLoc`
function U.CalcInFlightRemainingTicks(projLoc, target, speed)
    if not speed or speed <= 0 then return 0 end
    local tLoc = target:GetLocation()
    local dx, dy = tLoc.x - projLoc.x, tLoc.y - projLoc.y
    local dist = math.sqrt(dx * dx + dy * dy)
    local step = speed / 30.0
    local r = U.GetTargetHitRadius(target)
    return math.max(0, math.ceil(math.max(0.0, dist - r) / step - 1e-9) - 1)
end

-- Persistent Stat-Keyed Exact Integer `[rawMin, rawMax]` Sampler (`9056469656.dem` `tk=7662` Fix):
-- Valve's C++ Lua API exposes NO `GetBaseDamageVariance()`, and re-sampling `36` Monte-Carlo rolls every tick
-- (`30 Hz = 1800 resets/min`) had a `1 - (1 - (6/7)^36)^1800 = 99.91%/min` probability of throwing `lo = true_min + 1`,
-- making SF fire on `70 HP` with `69` min-roll (`1 HP` sliver stolen by T1 at `tk=7662`!).
-- Persisting `[lo, hi]` keyed by `(level, necromastery_souls, inventory_sig)` with `96` initial rolls reduces
-- false `+1` optimistic drift to `3.6e-7` (`0.000036%`) across both live C++ and custom benchmark spreads!
function U.SampleRawDamageRange(u)
    if not u or not u.GetAttackDamage then return 50, 54, 52 end
    local isHero = u.IsHero and u:IsHero()
    local statSig = nil
    if isHero then
        local lvl = (u.GetLevel and u:GetLevel()) or 0
        local modCnt = (u.NumModifiers and u:NumModifiers()) or 0
        local souls = 0
        for i = 0, modCnt - 1 do
            if u:GetModifierName(i) == "modifier_nevermore_necromastery" then
                souls = u:GetModifierStackCount(i) or 0
                break
            end
        end
        local invSig = 0
        if u.GetItemInSlot then
            for s = 0, 5 do
                local okI, it = pcall(u.GetItemInSlot, u, s)
                if okI and it then
                    local nm = it:GetName() or "x"
                    local h = 0
                    for bi = 1, #nm do
                        h = (h * 33 + string.byte(nm, bi)) % 1048576
                    end
                    if nm == "item_power_treads" and it.GetPowerTreadsStat then
                        local okPT, pt = pcall(it.GetPowerTreadsStat, it)
                        if okPT and type(pt) == "number" then h = (h * 7 + pt + 1) % 1048576 end
                    end
                    invSig = (invSig * 131 + h) % 65536
                end
            end
        end
        statSig = lvl * 134217728 + souls * 131072 + invSig * 2 + (modCnt % 2)
        local rec = U._dmgCache[u]
        if rec and rec.sig == statSig then
            local v1 = u:GetAttackDamage() or rec.avg
            local v2 = u:GetAttackDamage() or v1
            if v1 >= rec.lo - 1 and v1 <= rec.hi + 1 then
                if v1 < rec.lo then rec.lo = v1 end
                if v2 < rec.lo then rec.lo = v2 end
                if v1 > rec.hi then rec.hi = v1 end
                if v2 > rec.hi then rec.hi = v2 end
                rec.avg = (rec.lo + rec.hi) * 0.5
                return rec.lo, rec.hi, rec.avg
            end
        end
    else
        local modCnt = (u.NumModifiers and u:NumModifiers()) or 0
        statSig = -1000 - modCnt
        local rec = U._dmgCache[u]
        if rec and rec.sig == statSig then
            local v1 = u:GetAttackDamage() or rec.avg
            if v1 >= rec.lo and v1 <= rec.hi then
                return rec.lo, rec.hi, rec.avg
            end
        end
    end
    local lo, hi = math.huge, -math.huge
    local nSamples = 192
    for _ = 1, nSamples do
        local v = u:GetAttackDamage() or 0
        if v < lo then lo = v end
        if v > hi then hi = v end
    end
    local var = 0
    if u.GetBaseDamageVariance then
        local ok, vv = pcall(u.GetBaseDamageVariance, u)
        if ok and type(vv) == "number" then var = vv end
    end
    if hi == lo and var > 0 then
        lo = lo - var
        hi = hi + var
    elseif var > 0 and (var * 2) > (hi - lo) then
        local mid = math.floor((lo + hi) * 0.5 + 0.5)
        lo = math.min(lo, mid - var)
        hi = math.max(hi, mid + var)
    end
    local avg = (lo + hi) * 0.5
    U._dmgCache[u] = { t = GameTime(), sig = statSig, lo = lo, hi = hi, avg = avg }
    return lo, hi, avg
end

-- Exact Source 2 C++ integer damage floor with full Attack Class vs Defense Class table:
-- C++ `target:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL)` computes armor mitigation ONLY and omits
-- Source 2 attack-class multipliers (`Piercing` 150% vs non-siege creeps / 50% vs heroes / 35% vs Reinforced;
-- `Runty` 75% vs heroes / 70% vs Reinforced; `Reinforced` 250% vs Reinforced; `Hero` 50% vs Reinforced).
function U.GetAttackClassMultiplier(attacker, target)
    if not attacker or not target then return 1.0 end
    local aHero = attacker.IsHero and attacker:IsHero() or false
    local aTower = attacker.IsTower and attacker:IsTower() or false
    local aCreep = attacker.IsCreep and attacker:IsCreep() or false
    local aName = (attacker.GetUnitName and attacker:GetUnitName()) or ""
    local aSiege = string.find(aName, "siege", 1, true) ~= nil

    local tHero = target.IsHero and target:IsHero() or false
    local tTower = (target.IsTower and target:IsTower()) or (target.IsBuilding and target:IsBuilding()) or false
    local tCreep = target.IsCreep and target:IsCreep() or false
    local tName = (target.GetUnitName and target:GetUnitName()) or ""
    local tSiege = string.find(tName, "siege", 1, true) ~= nil
    local tReinforced = tTower or tSiege

    if aHero then
        return tReinforced and 0.50 or 1.00
    elseif aTower or aSiege then
        return tReinforced and 2.50 or 1.00
    elseif aCreep then
        local isRangedCreep = string.find(aName, "ranged", 1, true) ~= nil
            or ((attacker.GetAttackRange and (attacker:GetAttackRange() or 100) > 300) and not aSiege)
        if isRangedCreep then
            if tReinforced then return 0.35 end
            if tHero then return 0.50 end
            if tCreep then return 1.50 end
            return 1.00
        else
            if tReinforced then return 0.70 end
            if tHero then return 0.75 end
            return 1.00
        end
    end
    return 1.00
end

function U.CalcExactIntDamage(attacker, target, rawDmg)
    if not attacker or not target then return 0 end
    rawDmg = rawDmg or (attacker.GetAttackDamage and attacker:GetAttackDamage()) or 0
    if rawDmg <= 0 then return 0 end
    local classMult = U.GetAttackClassMultiplier(attacker, target)
    local scaled = target:GetActualIncomingDamage(rawDmg, DAMAGE_TYPE_PHYSICAL) * classMult
    return math.max(1, math.floor(scaled + 1e-6))
end

local function ObserveSingleUnit(u, curTick, isOwnBot)
    if not u or not U.CanQuery(u) then return end
    local rec = U._unitTrack[u]
    if not rec then
        rec = {
            wasAnim = false, startTick = nil, launchTick = nil,
            lastLAT = -100, lastLaunchTick = nil, lastCycle = 0, target = nil,
            lastX = nil, lastY = nil, lastPosTick = nil, estVx = 0, estVy = 0,
        }
        U._unitTrack[u] = rec
    end
    local uLoc = u.GetLocation and u:GetLocation() or nil
    if uLoc and uLoc.x and uLoc.y then
        if rec.lastPosTick and curTick > rec.lastPosTick and (curTick - rec.lastPosTick) <= 12 then
            local dt = (curTick - rec.lastPosTick) / 30.0
            rec.estVx = (uLoc.x - rec.lastX) / dt
            rec.estVy = (uLoc.y - rec.lastY) / dt
        elseif not rec.lastPosTick or (curTick - rec.lastPosTick) > 12 then
            rec.estVx, rec.estVy = 0, 0
        end
        rec.lastX, rec.lastY, rec.lastPosTick = uLoc.x, uLoc.y, curTick
    end
    local spa = (u.GetSecondsPerAttack and u:GetSecondsPerAttack()) or 1.0
    if spa <= 0 then spa = 1.0 end
    local wTicks = U.GetExactWindupTicks(u, isOwnBot)

    -- 1. Check m_flLastAttackTime edge first (stamps EXACT server tick of projectile launch / melee impact!)
    local lat = nil
    if u.GetLastAttackTime then
        local ok, v = pcall(u.GetLastAttackTime, u)
        if ok and type(v) == "number" and v > 0 then lat = v end
    end
    if lat and lat > rec.lastLAT + 0.004 then
        local actualLaunchTick = math.floor(lat * 30.0 + 0.5)
        if isOwnBot and rec.startTick and (actualLaunchTick - rec.startTick) >= 1 and (actualLaunchTick - rec.startTick) <= 28 then
            U._ownWindupRatio = (actualLaunchTick - rec.startTick) / (spa * 30.0)
            wTicks = actualLaunchTick - rec.startTick
        end
        rec.lastLAT = lat
        rec.lastLaunchTick = actualLaunchTick
        rec.wasAnim = false
        rec.startTick = nil
        rec.launchTick = nil
    end

    -- 2. Check attack animation edge (GetAnimActivity == 1503/1504/1505)
    -- CRITICAL SOURCE 2 ENGINE LAW: Backswing keeps act == 1503 across cooldown!
    -- A unit CANNOT begin a new windup before (lastLaunchTick + periodTicks - wTicks)!
    local periodTicks = math.max(1, math.floor(spa * 30.0 + 0.5))
    local minNewWindupStart = rec.lastLaunchTick and (rec.lastLaunchTick + periodTicks - wTicks) or -999999
    local act = u.GetAnimActivity and u:GetAnimActivity() or 0
    local cyc = u.GetAnimCycle and u:GetAnimCycle() or 0
    local curTarget = u.GetAttackTarget and u:GetAttackTarget() or nil
    if IsAttackAnim(act) and curTick >= minNewWindupStart then
        if (not rec.wasAnim) or (curTarget ~= nil and curTarget ~= rec.target) or (cyc + 0.04 < rec.lastCycle) then
            local estStart = (cyc <= 0.001) and (curTick - 1) or (curTick - math.floor(cyc * spa * 30.0 + 0.5))
            if estStart < minNewWindupStart then
                estStart = minNewWindupStart
            end
            rec.startTick = estStart
            rec.launchTick = estStart + wTicks
            rec.wasAnim = true
        end
        rec.lastCycle = cyc
        if curTarget then rec.target = curTarget end
    else
        rec.wasAnim = false
        rec.startTick = nil
        rec.launchTick = nil
        rec.lastCycle = 0
    end
end

U._enemyMaxHpTrack = { lvl = nil, knownMax = 0, backpackDropAt = -1000 }

function U.ObserveEnemyMaxHp(enemy)
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return end
    local enMax = math.max(1, enemy:GetMaxHealth() or 600)
    local enLvl = (enemy.GetLevel and enemy:GetLevel()) or 1
    local tr = U._enemyMaxHpTrack
    if tr.lvl ~= enLvl then
        tr.lvl = enLvl
        tr.knownMax = enMax
        tr.backpackDropAt = -1000
    elseif enMax >= tr.knownMax then
        tr.knownMax = enMax
        tr.backpackDropAt = -1000
    elseif tr.knownMax - enMax >= 110 then
        if tr.backpackDropAt < 0 then
            tr.backpackDropAt = GameTime()
        end
    end
end

-- Returns hidden MaxHP missing from enemy's active inventory due to backpacked Bracers/Treads.
function U.GetEnemyHiddenMaxHp(enemy)
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return 0 end
    U.ObserveEnemyMaxHp(enemy)
    local enMax = math.max(1, enemy:GetMaxHealth() or 600)
    local diff = (U._enemyMaxHpTrack.knownMax or enMax) - enMax
    if diff >= 110 then return diff end
    return 0
end

-- Returns enemy's effective HP after accounting for backpacked Bracer reactivation over `horizon` seconds:
--   * For immediate bursts (`horizon <= 3.0s`), enemy dies at current `enHp` BEFORE 6s backpack reactivation finishes!
--   * For longer trades (`horizon > 3.0s`) or active Salve sustain, scales `enHp` to full `knownMax` pool.
function U.GetEnemyEffectiveCombatHp(enemy, horizon)
    if not enemy or not U.CanQuery(enemy) then return 0 end
    local enHp = enemy:GetHealth() or 0
    local enMax = math.max(1, enemy:GetMaxHealth() or 600)
    local hidden = U.GetEnemyHiddenMaxHp(enemy)
    if hidden <= 0 then return enHp end
    if (horizon or 0) > 3.0 or enemy:HasModifier("modifier_flask_healing") then
        return enHp * ((enMax + hidden) / enMax)
    end
    return enHp
end

function U.SafeGetIncomingProjectiles(unit)
    if not unit or not unit.GetIncomingTrackingProjectiles then return {} end
    local ok, projs = pcall(unit.GetIncomingTrackingProjectiles, unit)
    if ok and type(projs) == "table" then return projs end
    return {}
end

-- Returns `(vx, vy)` 2D velocity of `unit` in world units/sec (NEVER nil!).
-- Uses `unit:GetVelocity()` via `pcall` first, falling back to `ObserveSingleUnit` finite differences
-- (`auto-20261031-1939` `tk=13686..14298` 6th-minute freeze root-cause fix!).
function U.EstimateEnemyVelocity(unit)
    if not unit or not U.CanQuery(unit) then return 0, 0 end
    if unit.GetVelocity then
        local okV, v = pcall(unit.GetVelocity, unit)
        if okV and v and type(v.x) == "number" and type(v.y) == "number" then
            if math.abs(v.x) > 0.5 or math.abs(v.y) > 0.5 then
                return v.x, v.y
            end
        end
    end
    local rec = U._unitTrack and U._unitTrack[unit]
    if rec and type(rec.estVx) == "number" and type(rec.estVy) == "number" then
        return rec.estVx, rec.estVy
    end
    return 0, 0
end

-- Adaptive post-cancel anti-bait gate (`v5.2.0` G4 6:54-7:00 fix):
-- Only active within `C.RAZE.JUKE.WINDOW` (12s) after an anti-miss hero coil S-cancel (`U._lastHeroRazeCancel`),
-- requiring enough radial slack inside the 250u Raze circle that the enemy cannot step out before `0.55s` impact.
function U.RazeJukeOK(bot, ability, enemy, isLethal)
    if not bot or not ability or not enemy or not U.CanQuery(enemy) then return true end
    local jk = (C.RAZE and C.RAZE.JUKE) or {}
    local win = jk.WINDOW or 12.0
    local lastCancel = U._lastHeroRazeCancel or -1000
    if (GameTime() - lastCancel) > win then
        return true
    end
    local data = U.GetRazeAbilityData(ability)
    if not data then return true end
    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    local dist = U.DistanceBetweenLocations(bLoc, eLoc)
    local rEff = (C.RAZE.HIT_RADIUS or 250) + (jk.HULL or 24)
    local edgeDist = rEff - math.abs(dist - data.center)
    if edgeDist <= 0 then return false end
    local enMS = math.max(250, enemy:GetCurrentMovementSpeed() or 305)
    local vx, vy = U.EstimateEnemyVelocity(enemy)
    local spd = math.sqrt((vx or 0) * (vx or 0) + (vy or 0) * (vy or 0))
    local needSec = (spd > 35) and (jk.SLACK_MOVING or 0.33) or (jk.SLACK_STILL or 0.25)
    if isLethal then
        needSec = needSec * (jk.LETHAL_MULT or 0.50)
    end
    local slackSec = edgeDist / enMS
    return slackSec >= needSec
end

local function ObserveTowerProjectilesOnList(list, curTick)
    for _, c in pairs(list or {}) do
        if U.CanQuery(c) and c:IsAlive() and (c:GetHealth() or 0) > 0 then
            for _, p in pairs(U.SafeGetIncomingProjectiles(c)) do
                local tw = p and p.caster
                if p.is_attack and tw and U.CanQuery(tw) and tw.IsTower and tw:IsTower() then
                    ObserveSingleUnit(tw, curTick, false)
                    local tRec = U._unitTrack[tw]
                    -- Only infer from mid-air bolts when C++ `GetLastAttackTime()` does not stamp towers (`lastLAT <= 0`)
                    if tRec and (tRec.lastLAT or -100) <= 0 then
                        local dFromTw = (p.location and tw.GetLocation)
                            and U.DistanceBetweenLocations(tw:GetLocation(), p.location) or 0
                        local isNewBolt = (tRec.projTrackTarget ~= c)
                            or (curTick > (tRec.lastProjSeenTick or -100) + 2)
                            or (tRec.lastProjDistFromTower and dFromTw < tRec.lastProjDistFromTower - 35)
                        if isNewBolt then
                            local tSpeed = U.GetProjectileSpeedOf(tw)
                            if tSpeed <= 0 then tSpeed = 750 end
                            local launchedAgo = math.min(20, math.floor(dFromTw / (tSpeed / 30.0) + 0.5))
                            tRec.lastLaunchTick = curTick - launchedAgo
                        end
                        local tSpa = (tw.GetSecondsPerAttack and tw:GetSecondsPerAttack()) or 0.90
                        if tSpa <= 0.1 then tSpa = 0.90 end
                        tRec.lastProjSeenTick = curTick
                        tRec.lastProjDistFromTower = dFromTw
                        tRec.projTrackTarget = c
                        tRec.inferredTowerTarget = c
                        tRec.inferredTowerTargetUntil = (tRec.lastLaunchTick or curTick) + math.ceil(tSpa * 30.0) + 6
                    end
                end
            end
        end
    end
end

function U.ObserveWorldTick(bot, s)
    local curTick = math.floor(GameTime() * 30.0 + 0.5)
    if U._lastObservedTick and curTick < U._lastObservedTick - 5 then
        U._unitTrack = {}
        U._dmgCache = {}
        U._lastObservedTick = nil
        U._enemyMaxHpTrack = { lvl = nil, knownMax = 0, backpackDropAt = -1000 }
        U._lastHeroRazeCancel = -1000
    end
    if U._lastObservedTick == curTick then return end
    U._lastObservedTick = curTick
    ObserveSingleUnit(bot, curTick, true)
    if s.enemy then
        ObserveSingleUnit(s.enemy, curTick, false)
        U.ObserveEnemyMaxHp(s.enemy)
    end
    for _, c in pairs(s.enemyCreeps or {}) do ObserveSingleUnit(c, curTick, false) end
    for _, c in pairs(s.allyCreeps or {}) do ObserveSingleUnit(c, curTick, false) end
    for _, t in pairs(s.enemyTowers or {}) do ObserveSingleUnit(t, curTick, false) end
    for _, t in pairs(s.allyTowers or {}) do ObserveSingleUnit(t, curTick, false) end
    ObserveTowerProjectilesOnList(s.enemyCreeps, curTick)
    ObserveTowerProjectilesOnList(s.allyCreeps, curTick)
    for _, t in pairs(s.allyTowers or {}) do
        local tRec = U._unitTrack[t]
        if tRec and tRec.inferredTowerTarget then
            local tc = tRec.inferredTowerTarget
            if not U.CanQuery(tc) or not tc:IsAlive() or (tc:GetHealth() or 0) <= 0
                or curTick > (tRec.inferredTowerTargetUntil or -1) then
                tRec.inferredTowerTarget = nil
            end
        end
    end
    for _, t in pairs(s.enemyTowers or {}) do
        local tRec = U._unitTrack[t]
        if tRec and tRec.inferredTowerTarget then
            local tc = tRec.inferredTowerTarget
            if not U.CanQuery(tc) or not tc:IsAlive() or (tc:GetHealth() or 0) <= 0
                or curTick > (tRec.inferredTowerTargetUntil or -1) then
                tRec.inferredTowerTarget = nil
            end
        end
    end
end

local function AttackerScheduleTicks(atk, target, curTick)
    ObserveSingleUnit(atk, curTick, false)
    local rec = U._unitTrack[atk]
    local spa = (atk.GetSecondsPerAttack and atk:GetSecondsPerAttack()) or 1.0
    if spa <= 0 then spa = 1.0 end
    local periodTicks = math.max(1, math.floor(spa * 30.0 + 0.5))
    local wTicks = U.GetExactWindupTicks(atk, false)
    local pSpeed = U.GetProjectileSpeedOf(atk)
    local fTicks = (pSpeed > 0) and U.CalcLaunchFlightTicks(atk:GetLocation(), target, pSpeed) or 0

    if rec and rec.wasAnim and rec.launchTick and rec.launchTick >= curTick then
        local kLaunch = rec.launchTick - curTick
        return kLaunch + fTicks, periodTicks, true, fTicks, pSpeed > 0
    end

    if rec and rec.lastLaunchTick and (curTick - rec.lastLaunchTick) <= periodTicks + 6 then
        local nextLaunch = rec.lastLaunchTick + periodTicks
        local kLaunch = math.max(1, nextLaunch - curTick)
        return kLaunch + fTicks, periodTicks, true, fTicks, pSpeed > 0
    end

    local d = GetUnitToLocationDistance(atk, target:GetLocation())
    local rng = (atk.GetAttackRange and atk:GetAttackRange()) or 150
    local walkTicks = 0
    if d > rng + 24 and not (atk.IsTower and atk:IsTower()) then
        local ms = math.max(100, (atk.GetCurrentMovementSpeed and atk:GetCurrentMovementSpeed()) or 325)
        walkTicks = math.ceil((d - rng) / (ms / 30.0))
    end
    return walkTicks + wTicks + fTicks, periodTicks, false, fTicks, pSpeed > 0
end

function U.WithHypotheticalDamage(ctx, damage)
    local copy = {}
    for k, v in pairs(ctx) do copy[k] = v end
    copy.hp = ctx.hp - damage
    return copy
end

function U.BeginPredictionFrame()
    U._predictionFrame = { time = GameTime(), targets = {} }
end

function U.GetTargetPredictionContext(target, all_attackers)
    local now = GameTime()
    local curTick = math.floor(now * 30.0 + 0.5)
    local frame = U._predictionFrame
    local cached = frame and frame.time == now and frame.targets[target]
    if cached and cached.attackers == all_attackers then return cached.ctx end

    local ctx = {
        hp = target:GetHealth(),
        maxHP = target:GetMaxHealth(),
        regen = target:GetHealthRegen() or 0,
        projs = U.SafeGetIncomingProjectiles(target),
        dps = 0,
        hits = {},
        scheduled = {},
        projDmg = {},
        projectileHits = {},
    }

    local selfBot = (type(GetBot) == "function") and GetBot() or nil
    U._lastProjCaster = U._lastProjCaster or {}
    local minInFlightByCaster = {}

    for _, projectile in pairs(ctx.projs) do
        local caster = projectile.caster
        if projectile.is_attack and projectile.location then
            local cInfo = nil
            if caster and U.CanQuery(caster) then
                local speed = U.GetProjectileSpeedOf(caster)
                if speed <= 0 then speed = 900 end
                local rawLo, rawHi, rawAvg = U.SampleRawDamageRange(caster)
                local dLo = U.CalcExactIntDamage(caster, target, rawLo)
                local dHi = U.CalcExactIntDamage(caster, target, rawHi)
                local dAvg = U.CalcExactIntDamage(caster, target, rawAvg)
                local isTw = (caster.IsTower and caster:IsTower()) and true or false
                cInfo = {
                    speed = speed, dLo = dLo, dHi = dHi, dAvg = dAvg,
                    caster = caster,
                    isOwnBot = (caster == selfBot) and true or false,
                    isHero = (caster.IsHero and caster:IsHero()) and true or false,
                    tower = isTw,
                }
                U._lastProjCaster[caster] = cInfo
            elseif caster and U._lastProjCaster[caster] then
                -- `A05` Post-Death Orphan Projectile Preservation: caster just died while its bolt is still in flight!
                cInfo = U._lastProjCaster[caster]
            end
            if cInfo then
                local kRem = U.CalcInFlightRemainingTicks(projectile.location, target, cInfo.speed)
                if cInfo.caster and (not minInFlightByCaster[cInfo.caster] or kRem < minInFlightByCaster[cInfo.caster]) then
                    minInFlightByCaster[cInfo.caster] = kRem
                end
                table.insert(ctx.projectileHits, {
                    k = kRem,
                    t = kRem / 30.0,
                    dmg = cInfo.dAvg,
                    dmgLo = cInfo.dLo,
                    dmgHi = cInfo.dHi,
                    caster = cInfo.caster,
                    isOwnBot = cInfo.isOwnBot,
                    isHero = cInfo.isHero,
                    tower = cInfo.tower,
                })
            end
        end
    end

    if all_attackers then
        for _, atk in pairs(all_attackers) do
            if atk and U.CanQuery(atk) and atk ~= selfBot then
                local isTw = (atk.IsTower and atk:IsTower()) and true or false
                local atkTarget = atk.GetAttackTarget and atk:GetAttackTarget() or nil
                if not atkTarget and isTw then
                    local tRec = U._unitTrack and U._unitTrack[atk]
                    if tRec and tRec.inferredTowerTarget == target and curTick <= (tRec.inferredTowerTargetUntil or -1) then
                        atkTarget = target
                    end
                end
                if atkTarget == target then
                    local rawLo, rawHi, rawAvg = U.SampleRawDamageRange(atk)
                    if rawAvg > 0 then
                        local dmgLo = U.CalcExactIntDamage(atk, target, rawLo)
                        local dmgHi = U.CalcExactIntDamage(atk, target, rawHi)
                        local kImp, periodTicks, certain, fTicks, isRanged = AttackerScheduleTicks(atk, target, curTick)
                        -- Never double-count an already in-flight tower bolt from `ctx.projectileHits`:
                        local inFlightK = isTw and minInFlightByCaster[atk] or nil
                        if inFlightK and kImp < inFlightK + math.floor(periodTicks * 0.65) then
                            kImp = inFlightK + periodTicks
                        end
                        local fragile = (not isTw) and ((atk:GetHealth() or 999) <= 28)
                        local isHero = (atk.IsHero and atk:IsHero()) and true or false
                        if isHero then ctx.contested = true end
                        ctx.scheduled[atk] = true
                        table.insert(ctx.hits, {
                            k = kImp,
                            t = kImp / 30.0,
                            periodTicks = periodTicks,
                            period = periodTicks / 30.0,
                            dmgLo = dmgLo,
                            dmgHi = dmgHi,
                            certain = certain,
                            fragile = fragile,
                            hero = isHero,
                            ranged = isRanged,
                            tower = isTw,
                            slackTicks = 0,
                            slack = 0.0,
                        })
                    end
                end
            end
        end
    end

    if frame and frame.time == now then
        frame.targets[target] = { attackers = all_attackers, ctx = ctx }
    end
    return ctx
end

function U.PredictHPWithContext(ctx, target, time_in_future, mode)
    if ctx.hp <= 0 then return 0 end
    mode = mode or "avg"
    local kTarget = math.max(0, math.floor(time_in_future * 30.0 + 0.0001))
    -- Tick-step simulation with absorbing death state (`A02`/`A11`: `hp <= 0` returns `0` immediately with ZERO post-death regen!)
    local drop = {}
    for _, hit in ipairs(ctx.projectileHits or {}) do
        if not hit.isOwnBot and hit.k >= 0 and hit.k <= kTarget then
            local d = (mode == "max") and hit.dmgLo or ((mode == "min") and hit.dmgHi or hit.dmg)
            drop[hit.k] = (drop[hit.k] or 0) + d
        end
    end

    if ctx.hits then
        for _, h in ipairs(ctx.hits) do
            if not h.hero or mode == "min" then
                local dmg
                if mode == "max" then dmg = h.fragile and 0 or h.dmgLo
                elseif mode == "min" then dmg = h.dmgHi
                else dmg = math.floor((h.dmgLo + h.dmgHi) * 0.5) end
                local k = h.k
                if not h.certain then
                    if mode == "max" then k = k + (h.slackTicks or 0)
                    elseif mode == "avg" then k = k + math.floor((h.slackTicks or 0) * 0.5) end
                end
                while k <= kTarget do
                    if k >= 0 then
                        drop[k] = (drop[k] or 0) + dmg
                    end
                    k = k + h.periodTicks
                end
            end
        end
    end

    local cumDmg = 0
    local maxHP = math.max(1, ctx.maxHP or ctx.hp)
    local regRate = ctx.regen or 0
    for k = 0, kTarget do
        local regAtK = math.floor(regRate * (k / 30.0) + 1e-9)
        local curBefore = math.min(maxHP, ctx.hp + regAtK) - cumDmg
        if curBefore <= 0 then return 0 end
        cumDmg = cumDmg + (drop[k] or 0)
        local curAfter = math.min(maxHP, ctx.hp + regAtK) - cumDmg
        if curAfter <= 0 then return 0 end
    end
    return math.min(maxHP, ctx.hp + math.floor(regRate * (kTarget / 30.0) + 1e-9)) - cumDmg
end

function U.HasLasthitWindow(ctx, target, my_dmg, min_time)
    min_time = min_time or 0
    local minK = math.ceil(min_time * 30.0)
    for k = 0, 120 do
        local hp = U.PredictHPWithContext(ctx, target, k / 30.0, "avg")
        if hp <= 0 then
            return false
        elseif hp <= my_dmg and k >= minK then
            return true
        end
    end
    return false
end

function U.SFDamageRange(bot, target)
    local rawMin, rawMax, rawAvg = U.SampleRawDamageRange(bot)
    local actualMin = U.CalcExactIntDamage(bot, target, rawMin)
    local actualMax = U.CalcExactIntDamage(bot, target, rawMax)
    local actualAvg = U.CalcExactIntDamage(bot, target, rawAvg)
    return { min = actualMin, max = actualMax, avg = actualAvg }
end

function U.GetEffectiveDamageAndMargin(bot, target, attackersCount)
    local range = U.SFDamageRange(bot, target)
    return range.min, 0
end

function U.GetExactBallisticTicks(bot, target, customLoc)
    local bLoc = customLoc or bot:GetLocation()
    local tLoc = target:GetLocation()
    local dx, dy = tLoc.x - bLoc.x, tLoc.y - bLoc.y
    local dist = math.sqrt(dx * dx + dy * dy)
    local range = (bot:GetAttackRange() or 525) + 24
    local ms = math.max(100, bot:GetCurrentMovementSpeed() or 305)
    local pSpeed = math.max(1, U.GetProjectileSpeedOf(bot))

    local walkTicks = 0
    local shotLoc = bLoc
    if dist > range then
        walkTicks = math.ceil((dist - range + 8) / (ms / 30.0))
        local ux, uy = dx / dist, dy / dist
        shotLoc = Vector(tLoc.x - ux * (range - 8), tLoc.y - uy * (range - 8), bLoc.z or 128)
    end

    local wantYaw = math.deg(math.atan2(dy, dx)) % 360
    local curYaw = (bot.GetFacing and bot:GetFacing()) or wantYaw
    local angDiff = math.abs(((wantYaw - curYaw + 180) % 360) - 180)
    local cone = (C.BALLISTIC and C.BALLISTIC.ATTACK_FACING_CONE) or 11.5
    local degPerTick = math.deg(((C.BALLISTIC and C.BALLISTIC.SF_TURN_RATE) or 0.90) / 0.03 * (1.0 / 30.0))
    -- In Source 2 step_physics, 1 turn step executes BEFORE facing cone check on the order tick itself!
    local turnTicks = (walkTicks == 0 and angDiff > degPerTick + cone) and math.ceil((angDiff - degPerTick - cone) / degPerTick) or 0

    local curTick = math.floor(GameTime() * 30.0 + 0.5)
    local rec = U._unitTrack[bot]
    local spa = bot:GetSecondsPerAttack() or 1.25
    local cdRemTicks = 0
    if rec and rec.lastLaunchTick then
        local periodTicks = math.ceil(spa * 30.0 - 1e-4)
        cdRemTicks = math.max(0, (rec.lastLaunchTick + periodTicks) - curTick)
    else
        local last = bot.GetLastAttackTime and bot:GetLastAttackTime() or -100
        if last > 0 then
            cdRemTicks = math.max(0, math.ceil((last + spa - GameTime()) * 30.0 - 1e-4))
        end
    end

    local wTicks = U.GetExactWindupTicks(bot, true)
    local fTicks = U.CalcLaunchFlightTicks(shotLoc, target, pSpeed)
    local launchTicks = math.max(walkTicks + turnTicks + wTicks, cdRemTicks)
    local totalTicks = launchTicks + fTicks
    return totalTicks, launchTicks, wTicks, fTicks, turnTicks, walkTicks, cdRemTicks
end

function U.GetAttackImpactWindow(bot, target)
    local totalTicks = U.GetExactBallisticTicks(bot, target)
    local t = totalTicks / 30.0
    return t, t
end

function U.LastHitImpactFits(earliest, latest, opening, closing)
    if opening < 0 or opening >= 999 then return false end
    return earliest >= opening - 0.001 and (not closing or latest <= closing)
end

function U.GetExactKillableInfo(bot, target, attackers)
    local isAlly = (target:GetTeam() == bot:GetTeam())
    local maxHP = math.max(1, target:GetMaxHealth())
    local sfDmg = U.SFDamageRange(bot, target)
    local myMinDmg = sfDmg.min
    local myOptThresh = myMinDmg
    local ctx = U.GetTargetPredictionContext(target, attackers)

    for _, ph in ipairs(ctx.projectileHits or {}) do
        if ph.isOwnBot then
            local hpAtMyProj = U.PredictHPWithContext(ctx, target, ph.k / 30.0, "avg")
            if hpAtMyProj <= myOptThresh then
                return -2, -2, 999, true, ctx
            end
        end
    end

    local H = 120
    local pessDrop, avgDrop, optDrop, projOpenTick = {}, {}, {}, {}
    for k = 0, H do
        pessDrop[k] = 0; avgDrop[k] = 0; optDrop[k] = 0
    end

    for _, ph in ipairs(ctx.projectileHits or {}) do
        if not ph.isOwnBot and ph.k >= 0 and ph.k <= H then
            pessDrop[ph.k] = pessDrop[ph.k] + ph.dmgLo
            avgDrop[ph.k]  = avgDrop[ph.k]  + ph.dmg
            optDrop[ph.k]  = optDrop[ph.k]  + ph.dmgHi
            projOpenTick[ph.k] = true
        end
    end

    for _, h in ipairs(ctx.hits or {}) do
        local kOpt = h.k
        while kOpt <= H do
            optDrop[kOpt] = optDrop[kOpt] + h.dmgHi
            kOpt = kOpt + h.periodTicks
        end
        if not h.hero then
            local kP = h.k
            local dP = h.fragile and 0 or h.dmgLo
            while kP <= H do
                pessDrop[kP] = pessDrop[kP] + dP
                if h.ranged then projOpenTick[kP] = true end
                kP = kP + h.periodTicks
            end
            local kA = h.k
            local dA = math.floor((h.dmgLo + h.dmgHi) * 0.5 + 0.5)
            while kA <= H do
                avgDrop[kA] = avgDrop[kA] + dA
                if h.ranged then projOpenTick[kA] = true end
                kA = kA + h.periodTicks
            end
        end
    end

    local hasTowerAttacker = false
    for _, ph in ipairs(ctx.projectileHits or {}) do
        if ph.tower then hasTowerAttacker = true end
    end
    for _, h in ipairs(ctx.hits or {}) do
        if h.tower then hasTowerAttacker = true end
    end

    local hpP, hpA, hpO = ctx.hp, ctx.hp, ctx.hp
    local hpAAt = {}
    local kOpenP, kOpenA, kClose = nil, nil, nil
    local regenPerTick = (ctx.regen or 0) / 30.0
    local regAcc = 0.0

    for k = 0, H do
        if k > 0 then
            regAcc = regAcc + regenPerTick
            if regAcc >= 1.0 then
                local add = math.floor(regAcc)
                regAcc = regAcc - add
                if hpP > 0 then hpP = math.min(maxHP, hpP + add) end
                if hpA > 0 then hpA = math.min(maxHP, hpA + add) end
                if hpO > 0 then hpO = math.min(maxHP, hpO + add) end
            end
        end
        hpP = hpP - pessDrop[k]
        hpA = hpA - avgDrop[k]
        hpO = hpO - optDrop[k]
        hpAAt[k] = hpA

        local denyLegalP = (not isAlly) or (hpP * 2 < maxHP)
        local denyLegalA = (not isAlly) or (hpA * 2 < maxHP)

        if not kOpenP and hpP > 0 and hpP <= myOptThresh and denyLegalP then
            kOpenP = k
        end
        -- Bayes-optimal single-step arrival gate on lane waves; under T1 double min-roll protection:
        if not kOpenA and hpA > 0 and hpA <= myOptThresh and denyLegalA then
            kOpenA = k
        end
        if not kClose and hpA <= 0 then
            kClose = k
        end
    end

    -- Under-T1 Double Min-Roll Theorem (`tk=7662` `162 - 92 = 70 -> 1 HP` Fix!):
    -- When a tower attacks (`92..97` spread, `24.5`-tick cooldown), pre-launching BEFORE the tower hit on `kOpenA`
    -- when `hpP > myMinDmg` (`162 - 92 = 70 > 69`) leaves `1 HP` 40% of the time if T1 rolls minimum!
    -- If SF's post-hit reaction (`wT + fT`) easily fits inside T1's 24.5-tick reload (`effClose - kOpenA >= totalNow + 2`),
    -- wait until `kOpenP` (or until the T1 bolt actually lands at `k = 0`) so we NEVER pre-burn a shot into `1 HP`!
    local kOpen = kOpenA
    if hasTowerAttacker and kOpenA and kOpenA > 0 and (not kOpenP or kOpenP > kOpenA) then
        local totalNow = U.GetExactBallisticTicks(bot, target)
        local closeCheck = kClose or 999
        if (closeCheck - kOpenA) >= (totalNow + 2) then
            kOpen = kOpenP -- wait for guaranteed `hpP <= myMinDmg` (or actual post-hit `k = 0` observation!)
        end
    end

    local gamble = false
    if not kOpen then
        -- If already past penultimate tower hit (`ctx.hp <= sfDmg.max + 12` and `kClose <= 25`), fire our last shot
        -- immediately rather than stand idle watching our own T1 execute the creep (`Demo 2` `0:45.37` `50 HP` melee fix!).
        local sfMaxDmg = (sfDmg.avg or myMinDmg) * 2 - myMinDmg
        if ctx.hp > 0 and ctx.hp <= (sfMaxDmg + 12) and kClose and kClose <= 25 and hasTowerAttacker then
            return 0, 0, kClose, true, ctx
        end
        if kClose then
            return -1, -1, kClose, true, ctx
        end
        return 999, 999, 999, false, ctx
    end

    -- Source 2 C++ `CDOTA_ProjectileManager::Think` Reverse-Slot Iteration Law (`9056469656.dem` `tk=5374` & `tk=7630`!):
    -- In `libserver.so`, `m_Projectiles` is walked back-to-front (`i = Count - 1 .. 0`) BEFORE melee `AnimEvent` swings.
    -- Aiming at `kOpen` when `kOpen > 0` makes SF's newer projectile resolve FIRST on pre-hit HP (`118 -> 57`, `130 -> 62`),
    -- handing the kill straight to T1 on the exact same tick!
    -- Targeting `kOpen + 1` whenever `(kOpen + 1) < effClose` lands strictly `+1` tick (`+0.033s`, 100% inside `0–0.033s`!)
    -- AFTER the opening blow with ZERO same-tick slot race and ZERO non-lethal `EarlyHit`s!
    local effClose = kClose or 999

    local kTargetImpact = kOpen
    if kOpen > 0 then
        local leadStep = (not hasTowerAttacker and isAlly) and 2 or 1
        if (kOpen + leadStep) < effClose then
            local hpNext = hpAAt[kOpen + leadStep] or 0
            local denyLegalNext = (not isAlly) or (hpNext * 2 < maxHP)
            if hpNext > 0 and hpNext <= myOptThresh and denyLegalNext then
                kTargetImpact = kOpen + leadStep
            end
        end
        if kTargetImpact == kOpen and (kOpen + 1) < effClose then
            local hpNext1 = hpAAt[kOpen + 1] or 0
            local denyLegalNext1 = (not isAlly) or (hpNext1 * 2 < maxHP)
            if hpNext1 > 0 and hpNext1 <= myOptThresh and denyLegalNext1 then
                kTargetImpact = kOpen + 1
            end
        end
    end

    if effClose <= kOpen then
        effClose = kOpen + 1
    end

    return kOpen, kTargetImpact, effClose, gamble, ctx
end

function U.GetTimeToKillable(bot, target, attackers)
    local kOpen, _, effClose, gamble = U.GetExactKillableInfo(bot, target, attackers)
    if kOpen == -2 or kOpen == 999 then return 999, 999, false end
    if kOpen == -1 then return -1, effClose / 30.0, true end
    return kOpen / 30.0, (effClose >= 999 and 999 or effClose / 30.0), gamble
end

function U.GetActiveItemByName(unit, name)
    if not unit or not name then return nil end
    if unit.FindItemSlot then
        local okS, slot = pcall(unit.FindItemSlot, unit, name)
        if okS and type(slot) == "number" and slot >= 0 and slot <= 5 then
            local okI, item = pcall(unit.GetItemInSlot, unit, slot)
            if okI and item then
                if not item.IsFullyCastable then return item end
                local okC, castable = pcall(item.IsFullyCastable, item)
                if okC and castable then return item end
                if not okC then return item end
            end
        end
        if okS then return nil end
    end
    for i = 0, 5 do
        local okI, item = pcall(unit.GetItemInSlot, unit, i)
        if okI and item then
            local okN, nm = pcall(item.GetName, item)
            if okN and nm == name then
                if not item.IsFullyCastable then return item end
                local okC, castable = pcall(item.IsFullyCastable, item)
                if okC and castable then return item end
                if not okC then return item end
            end
        end
    end
    return nil
end

-- (21.10) The item is called item_tpscroll in the scripts but the demo entity reports
-- item_teleport_scroll (CDOTA_Item_TeleportScroll). The bot only matched "tpscroll", so in a real
-- match GetTPScroll() returned nil -> HandleReturnTP bought a SECOND scroll instead of using the one
-- in the inventory. In demo 0154 this is visible: charges 1 -> 2 -> 3 after the two deaths while the
-- hero walked from the fountain for 33 s with a full scroll in slot 15. Accept both names.
local function IsTPName(nm)
    if type(nm) ~= "string" then return false end
    return nm:find("tpscroll") ~= nil or nm:find("teleport_scroll") ~= nil
end

local function TPFromHandle(item)
    if not item then return nil end
    local okN, nm = pcall(function() return item:GetName() end)
    if okN and IsTPName(nm) then return item end
    return nil
end

function U.GetTPScroll(bot)
    if not bot then return nil, -1 end
    local fallback, fallbackSlot = nil, -1
    local function consider(h, sl)
        local it = TPFromHandle(h)
        if not it then return nil end
        local okC, ch = pcall(function() return it:GetCurrentCharges() end)
        if okC and type(ch) == "number" and ch <= 0 then
            return nil
        end
        local okCast, castable = pcall(function() return it:IsFullyCastable() end)
        if okCast and castable then
            return it
        end
        if not fallback then
            fallback, fallbackSlot = it, sl
        end
        return nil
    end

    -- 1. Check dedicated TP slot (15..20) & active inventory (0..5) BEFORE backpack/stash (6..14)!
    for _, i in ipairs({ 15, 16, 17, 0, 1, 2, 3, 4, 5, 18, 19, 20 }) do
        local okI, item = pcall(function() return bot:GetItemInSlot(i) end)
        if okI then
            local ready = consider(item, i)
            if ready then return ready, i end
        end
    end
    -- 2. Check ability handle (dedicated TP scroll in Source 2 C++ is also exposed as an ability handle)
    for _, nm in ipairs({ "item_tpscroll", "item_teleport_scroll" }) do
        local okA, ab = pcall(function() return bot:GetAbilityByName(nm) end)
        if okA then
            local ready = consider(ab, 15)
            if ready then return ready, 15 end
        end
    end
    -- 3. Check FindItemSlot & remaining slots (backpack 6..8, stash 9..14)
    for _, nm in ipairs({ "item_tpscroll", "item_teleport_scroll" }) do
        local ok, slot = pcall(function() return bot:FindItemSlot(nm) end)
        if ok and type(slot) == "number" and slot >= 0 then
            local okI, item = pcall(function() return bot:GetItemInSlot(slot) end)
            if okI then
                local ready = consider(item, slot)
                if ready then return ready, slot end
            end
        end
    end
    for i = 6, 14 do
        local okI, item = pcall(function() return bot:GetItemInSlot(i) end)
        if okI then
            local ready = consider(item, i)
            if ready then return ready, i end
        end
    end
    return fallback, fallbackSlot
end

-- Returns true if the hero OR personal courier already holds ANY teleport scroll (>= 1 charge,
-- regardless of slot 0..20, stash, backpack, cooldown, or courier transit).
function U.HasAnyTPScroll(bot)
    if not bot then return false end
    local tp = U.GetTPScroll(bot)
    if tp then return true end
    if type(GetNumCouriers) == "function" and type(GetCourier) == "function" then
        local okPid, pid = pcall(function() return bot:GetPlayerID() end)
        if okPid and pid ~= nil then
            for i = 0, GetNumCouriers() - 1 do
                local courier = GetCourier(i)
                if courier and not courier:IsNull() and courier:GetPlayerID() == pid then
                    for slot = 0, 8 do
                        local okI, item = pcall(function() return courier:GetItemInSlot(slot) end)
                        if okI then
                            local it = TPFromHandle(item)
                            if it then
                                local okC, ch = pcall(function() return it:GetCurrentCharges() end)
                                if not okC or type(ch) ~= "number" or ch >= 1 then
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

-- The enemy is teleporting (an item_tpscroll channel). SF has no other channels, so
-- IsChanneling without an active ability name also counts as a TP.
function U.IsEnemyTPChanneling(enemy)
    if not enemy then return false end
    local okC, ch = pcall(function() return enemy:IsChanneling() end)
    if not okC or not ch then return false end
    local okA, ab = pcall(function() return enemy:GetCurrentActiveAbility() end)
    if okA and ab then
        local okN, nm = pcall(function() return ab:GetName() end)
        if okN and not IsTPName(nm) then return false end
    end
    return true
end

function U.GetConsumableManaBurst(unit)
    if not unit then return 0 end
    local burst = 0
    burst = burst + U.GetMangoMana(unit) -- By charges
    return burst
end

-- Main inventory only (`0..5`) unless `includeBackpack == true`: backpack (`6..8`) items have a 6s
-- activation lock and CANNOT provide instant survival heal/mana during a combat race!
function U.GetStickCharges(unit, includeBackpack)
    if not unit then return 0 end
    local best = 0
    local maxSlot = includeBackpack and 8 or 5
    for i = 0, maxSlot do
        local okI, item = pcall(unit.GetItemInSlot, unit, i)
        if okI and item then
            local okN, name = pcall(item.GetName, item)
            if okN and (name == "item_magic_wand" or name == "item_magic_stick") then
                if includeBackpack or (not item.IsFullyCastable) or item:IsFullyCastable() then
                    local charges = (item.GetCurrentCharges and item:GetCurrentCharges()) or 0
                    if charges > best then best = charges end
                end
            end
        end
    end
    return best
end

function U.GetFaerieFireHeal(unit)
    if not unit or not U.CanQuery(unit) then return 0 end
    local ff = U.GetActiveItemByName(unit, "item_faerie_fire")
    if ff and ((not ff.IsFullyCastable) or ff:IsFullyCastable()) then
        return 85
    end
    return 0
end

function U.GetEffectiveEnemyHP(enemy, horizon)
    if not enemy or not U.CanQuery(enemy) then return 9999 end
    local hp = enemy:GetHealth() or 0
    local ff = U.GetFaerieFireHeal(enemy)
    local stick = U.GetStickCharges(enemy, false) * 15
    local regen = math.max(0, (enemy.GetHealthRegen and enemy:GetHealthRegen() or 0)) * math.max(0, horizon or 0)
    return hp + ff + stick + regen
end

local CUMULATIVE_XP_BY_LVL = {
    [1] = 0, [2] = 240, [3] = 640, [4] = 1160,
    [5] = 1760, [6] = 2440, [7] = 3200, [8] = 4000,
}

function U.InferRazeLevel(unit)
    if not unit or not U.CanQuery(unit) then return 0 end
    if unit.GetAbilityByName then
        local okQ, q = pcall(unit.GetAbilityByName, unit, "nevermore_shadowraze1")
        if okQ and q and q.GetLevel then
            local qLvl = q:GetLevel() or 0
            if qLvl > 0 then return math.min(4, qLvl) end
        end
    end
    local uName = (unit.GetUnitName and unit:GetUnitName()) or ""
    if string.find(uName, "nevermore", 1, true) then
        local lvl = (unit.GetLevel and unit:GetLevel()) or 1
        if lvl >= 7 then return 4 end
        if lvl >= 5 then return 3 end
        if lvl >= 3 then return 2 end
        return 1
    end
    return 0
end

function U.IsOutRazedTier(bot, enemy)
    if not bot or not enemy or not U.CanQuery(enemy) then return false end
    return U.InferRazeLevel(enemy) > U.InferRazeLevel(bot)
end

function U.IsNearLevelSpike(bot, enemy)
    if not bot then return false end
    local myLvl = bot:GetLevel() or 1
    local nextLvl = myLvl + 1
    if not (nextLvl == 2 or nextLvl == 3 or nextLvl == 5 or nextLvl == 7) then
        return false
    end
    local enLvl = (enemy and U.CanQuery(enemy) and enemy:GetLevel()) or myLvl
    local xpFn = bot.GetXP or bot.GetCurrentXP
    if xpFn then
        local okX, curXp = pcall(xpFn, bot)
        local targetXp = CUMULATIVE_XP_BY_LVL[nextLvl]
        if okX and type(curXp) == "number" and targetXp and curXp > 0 and curXp < targetXp then
            if (targetXp - curXp) <= 125 and myLvl <= enLvl then
                return true
            end
        end
    end
    if myLvl < enLvl and bot.GetNearbyLaneCreeps then
        local okC, ec = pcall(bot.GetNearbyLaneCreeps, bot, 1050, true)
        if okC and ec and #ec >= 1 then
            return true
        end
    end
    return false
end

function U.HasRazeStackTalent(unit)
    if not unit or not unit.GetAbilityByName then return false end
    local ok, t = pcall(unit.GetAbilityByName, unit, "special_bonus_unique_nevermore_7")
    if ok and t and t.GetLevel and (t:GetLevel() or 0) > 0 then
        return true
    end
    return false
end

function U.GetSpellAmpMult(unit)
    if not unit or not U.CanQuery(unit) then return 1.0 end
    if unit.GetSpellAmp then
        local ok, amp = pcall(unit.GetSpellAmp, unit)
        if ok and type(amp) == "number" and amp > 0 then
            if amp > 1.5 then amp = amp * 0.01 end
            return 1.0 + math.min(0.50, amp)
        end
    end
    if U.GetActiveItemByName(unit, "item_yasha_and_kaya") or U.GetActiveItemByName(unit, "item_kaya_and_sange") then
        return 1.12
    end
    if U.GetActiveItemByName(unit, "item_kaya") then
        return 1.10
    end
    return 1.0
end

-- Mangoes stack as charges in one slot: count the CHARGES (each = +100 mana, eaten
-- instantly), not "has the item = +100". Main inventory only (0-5): you cannot eat from the backpack.
-- For the enemy hero - the same slot walk (the Bot API exposes the items of a visible hero).
function U.GetMangoCharges(unit)
    if not unit then return 0 end
    local total = 0
    for i = 0, 5 do
        local okI, item = pcall(unit.GetItemInSlot, unit, i)
        if okI and item then
            local okN, name = pcall(item.GetName, item)
            if okN and name == "item_enchanted_mango" then
                local ch = 1
                if item.GetCurrentCharges then
                    local okC, c = pcall(item.GetCurrentCharges, item)
                    if okC and type(c) == "number" and c > 0 then ch = c end
                end
                total = total + ch
            end
        end
    end
    if total > 4 then total = 4 end
    return total
end

function U.GetMangoMana(unit)
    return U.GetMangoCharges(unit) * 100
end

function U.GetPotentialManaForRaze(unit)
    if not unit then return 0 end
    local mana = unit:GetMana() or 0
    mana = mana + U.GetConsumableManaBurst(unit)
    local charges = U.GetStickCharges(unit)
    if charges > 0 then
        mana = mana + charges * 15
    end
    return mana
end

function U.HasBoots(unit)
    if not unit then return false end
    return U.HasItem(unit, "item_boots") or U.HasItem(unit, "item_power_treads")
end

function U.HasItem(unit, item_name)
    if not unit then return false end
    if not U.CanQuery(unit) and not unit:IsBot() then return false end
    for i = 0, 8 do -- inventory + backpack (the stash/TP slot is not counted)
        local item = unit:GetItemInSlot(i)
        if item and item:GetName() == item_name then return true end
    end
    return false
end

local STACKABLE_CONSUMABLES = {
    ["item_enchanted_mango"] = true,
    ["item_flask"]           = true,
    ["item_faerie_fire"]     = true,
    ["item_ward_observer"]   = true,
    ["item_tpscroll"]        = true,
}

function U.GetItemCount(unit, item_name)
    if not unit then return 0 end
    if not U.CanQuery(unit) and not unit:IsBot() then return 0 end
    local count = 0
    local useCharges = STACKABLE_CONSUMABLES[item_name] or false
    for i = 0, 8 do
        local item = unit:GetItemInSlot(i)
        if item and item:GetName() == item_name then
            if useCharges and item.GetCurrentCharges then
                local okC, ch = pcall(item.GetCurrentCharges, item)
                count = count + ((okC and type(ch) == "number" and ch > 0) and ch or 1)
            else
                count = count + 1
            end
        end
    end
    return count
end

function U.GetLaneItemPower(unit)
    if not unit then return 0 end
    local score = 0
    score = score + U.GetItemCount(unit, "item_bracer") * 0.90
    score = score + U.GetItemCount(unit, "item_magic_wand") * 0.35
    score = score + U.GetItemCount(unit, "item_magic_stick") * 0.20
    if U.HasItem(unit, "item_boots") then score = score + 0.25 end
    if U.HasItem(unit, "item_power_treads") then score = score + 0.50 end
    if U.HasItem(unit, "item_kaya") then score = score + 1.00 end
    if U.HasItem(unit, "item_dragon_lance") then score = score + 0.90 end
    return score
end

-- Unified Total-Order Item Slot Priority (`auto-20261023-1329-start-ShaNachnetsya.dem` `tk=9902..11852` Fix!):
-- Both `U.ManageInventorySlots` AND `H.EnsureConsumableReady` MUST share this exact strict total order so
-- swapping items between active slots `0..5` and Backpack `6..8` is mathematically 100% ACYCLIC (`0` infinite
-- swap loops!), keeping BOTH `item_enchanted_mango` (when low MP) AND `item_tango` (when missing HP) simultaneously
-- ready in active slots `0..5` while temporarily parking low-tier stat components (`Circlet` / `Gauntlets` / `Branch`).
function U.GetEffectiveItemPriority(bot, nm)
    if not nm then return 0 end
    if nm == "item_ward_observer" then return 999 end
    local hp = (bot and bot.GetHealth and bot:GetHealth()) or 600
    local maxHP = math.max(1, (bot and bot.GetMaxHealth and bot:GetMaxHealth()) or 600)
    local hpPct = hp / maxHP
    local missingHP = maxHP - hp
    local mana = (bot and bot.GetMana and bot:GetMana()) or 300
    local lowHPFlask = hpPct < ((C.REGEN or {}).FLASK_PULL_HP_PCT or 0.60) or missingHP >= 280
    if nm == "item_flask" and lowHPFlask then
        return 95
    end
    if nm == "item_enchanted_mango" and mana < 175 then
        return 58
    end
    if nm == "item_tango" and (missingHP >= 115 or hpPct <= 0.82)
        and not (bot and bot.HasModifier and (bot:HasModifier("modifier_tango_heal") or bot:HasModifier("modifier_flask_healing"))) then
        return 56
    end
    if nm == "item_faerie_fire" and hpPct <= 0.24 then
        return 62
    end
    return (C.ITEM_PRIORITY and C.ITEM_PRIORITY[nm]) or 10
end

function U.ManageInventorySlots(bot)
    for bpSlot = 6, 8 do
        local bpItem = bot:GetItemInSlot(bpSlot)
        if bpItem then
            local bpPrio = U.GetEffectiveItemPriority(bot, bpItem:GetName())
            local worstSlot = -1
            local worstPrio = 9999
            local hasEmptySlot = false
            for invSlot = 0, 5 do
                local invItem = bot:GetItemInSlot(invSlot)
                if not invItem then
                    hasEmptySlot = true
                    worstSlot = invSlot
                    break
                else
                    local invPrio = U.GetEffectiveItemPriority(bot, invItem:GetName())
                    if invPrio < worstPrio then
                        worstPrio = invPrio
                        worstSlot = invSlot
                    end
                end
            end
            if hasEmptySlot or bpPrio > worstPrio then
                bot:ActionImmediate_SwapItems(bpSlot, worstSlot)
                return
            end
        end
    end
end


function U.IsEnemyCastingRaze(enemy)
    if not U.CanQuery(enemy) then return false end
    local r1 = enemy:GetAbilityByName("nevermore_shadowraze1")
    local r2 = enemy:GetAbilityByName("nevermore_shadowraze2")
    local r3 = enemy:GetAbilityByName("nevermore_shadowraze3")
    if (r1 and r1:IsInAbilityPhase()) or
       (r2 and r2:IsInAbilityPhase()) or
       (r3 and r3:IsInAbilityPhase()) then
        return true
    end
    return false
end

function U.EnemyHasRaze(enemy)
    if not U.CanQuery(enemy) then return false end
    local r1 = enemy:GetAbilityByName("nevermore_shadowraze1")
    if r1 and r1:GetLevel() > 0 then return true end
    local r2 = enemy:GetAbilityByName("nevermore_shadowraze2")
    if r2 and r2:GetLevel() > 0 then return true end
    local r3 = enemy:GetAbilityByName("nevermore_shadowraze3")
    if r3 and r3:GetLevel() > 0 then return true end
    return false
end

U._razeTracker = {
    enemies = {},
    lastMissTime = -math.huge,
    lastMissEntindex = nil,
}

local function _getEnemyRazeTrackerEntry(enemy)
    if not enemy then return nil end
    local key = (enemy.GetPlayerID and enemy:GetPlayerID()) or tostring(enemy)
    if key == nil or (type(key) == "number" and key < 0) then key = tostring(enemy) end
    local entry = U._razeTracker.enemies[key]
    if not entry then
        entry = {
            wasCasting = false,
            lastPhaseEndTime = -math.huge,
            pendingMissCheck = false,
            pendingLabel = nil,
            prevDebuffStacks = 0,
            prevDebuffRemain = 0,
            lastHitLabel = nil,
            lastHitTime = -math.huge,
        }
        U._razeTracker.enemies[key] = entry
    end
    return entry
end

function U.UpdateEnemyRazeMissTracker(bot, enemy)
    if not U.CanQuery(enemy) then return end
    local entry = _getEnemyRazeTrackerEntry(enemy)
    if not entry then return end

    local now = GameTime()
    local casting = U.IsEnemyCastingRaze(enemy)
    local stacksNow = U.GetShadowrazeDebuff(bot) or 0
    local previousStacks = entry.observedStacks or stacksNow
    if casting and not entry.wasCasting then
        entry.hitDuringCast = false
        entry.pendingLabel = nil
        for i, label in ipairs({"near", "mid", "far"}) do
            local ab = enemy:GetAbilityByName("nevermore_shadowraze" .. i)
            if ab and ab:IsInAbilityPhase() then entry.pendingLabel = label; break end
        end
    end
    local hitNow = stacksNow > previousStacks
    if hitNow then
        entry.lastHitTime = now
        entry.lastHitLabel = entry.pendingLabel
            or U.GetRazeLabelByDistance(GetUnitToLocationDistance(enemy, bot:GetLocation()), C.RAZE.HIT_RADIUS)
        entry.hitDuringCast = true
        entry.pendingMissCheck = false
    end
    entry.observedStacks = stacksNow

    if entry.wasCasting and not casting then
        entry.lastPhaseEndTime = now
        entry.pendingMissCheck = not entry.hitDuringCast
        entry.prevDebuffStacks = previousStacks
        local castDist = GetUnitToLocationDistance(enemy, bot:GetLocation())
        entry.pendingLabel = entry.pendingLabel or U.GetRazeLabelByDistance(castDist, C.RAZE.HIT_RADIUS)
    end

    entry.wasCasting = casting

    if entry.pendingMissCheck then
        local stacksNow = U.GetShadowrazeDebuff(bot) or 0
        if stacksNow > entry.prevDebuffStacks then
            entry.pendingMissCheck = false
            entry.lastHitLabel = entry.pendingLabel
                or U.GetRazeLabelByDistance(GetUnitToLocationDistance(enemy, bot:GetLocation()), C.RAZE.HIT_RADIUS)
            entry.lastHitTime = now
            entry.pendingLabel = nil
        elseif (now - entry.lastPhaseEndTime) >= C.RAZE.MISS_DETECT_WINDOW then
            entry.pendingMissCheck = false
            U._razeTracker.lastMissTime = now
            U._razeTracker.lastMissEntindex = (enemy.GetPlayerID and enemy:GetPlayerID()) or nil
            entry.pendingLabel = nil
        end
    end
end

function U.HasEnemyMissedRazeRecently()
    return (GameTime() - (U._razeTracker.lastMissTime or -math.huge)) <= C.RAZE.MISS_ADVANTAGE_TIME
end


function U.GetRecentEnemyRazeHitLabel(enemy)
    if not enemy then return nil end
    local entry = _getEnemyRazeTrackerEntry(enemy)
    if not entry then return nil end
    return entry.lastHitLabel
end

function U.GetRecentEnemyRazeHitAge(enemy)
    if not enemy then return math.huge end
    local entry = _getEnemyRazeTrackerEntry(enemy)
    if not entry then return math.huge end
    return GameTime() - (entry.lastHitTime or -math.huge)
end

function U.IsSecondStackDangerActive(bot, enemy)
    if not U.CanQuery(enemy) then return false, nil end
    local stacks, rem_time = U.GetShadowrazeDebuff(bot)
    if stacks < 1 or rem_time <= C.RAZE.RETREAT_MIN_REMAIN then
        return false, nil
    end
    local hitLabel = U.GetRecentEnemyRazeHitLabel(enemy)
    if not hitLabel then return false, nil end
    return true, hitLabel
end

-- Is it safe for me to be in band label (at ~center(label) I stand in HIS
-- label band). It is safe while HIS copy of that band is on cooldown / unlearned / out of mana: he has nothing
-- to answer with. This is more precise than the old rule "only the band he hit us with last is safe".
function U.IsBandSafeForMe(enemy, label, marginSec)
    local K = U._K
    if not K or not K.BandSafeFromEnemy then return false end
    return K.BandSafeFromEnemy(enemy, label, marginSec or (C.RAZE.CAST_POINT + 0.15))
end



function U.IsEnemyHighValueRegen(enemy)
    if not U.CanQuery(enemy) then return false end
    if enemy:HasModifier("modifier_flask_healing") then return true end
    if enemy:HasModifier("modifier_clarity_potion") then return true end
    if enemy:HasModifier("modifier_bottle_regeneration") then return true end
    return false
end

function U.GetPlaystyle(bot, enemy, allyCreeps, enemyCreeps)
    if not U.CanQuery(enemy) then return "NEUTRAL" end

    local score = 0
    local myLvl = bot:GetLevel() or 1
    local eLvl = enemy:GetLevel() or 1
    score = score + (myLvl - eLvl) * 1.5

    local myRazeLvl = U.InferRazeLevel(bot)
    local eRazeLvl = U.InferRazeLevel(enemy)
    local outRazed = (eRazeLvl > myRazeLvl)
    local nearSpike = U.IsNearLevelSpike(bot, enemy)
    if myRazeLvl > eRazeLvl then score = score + 3.0 end
    if myRazeLvl < eRazeLvl then score = score - 3.5 end

    local myHpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local eHpPct = enemy:GetHealth() / math.max(1, enemy:GetMaxHealth())
    score = score + (myHpPct - eHpPct) * 3.2
    if bot:GetHealth() < 400 then score = score - 2.0 end
    if enemy:GetHealth() < 350 then score = score + 0.8 end

    local eTotalMana = (enemy:GetMana() or 0) + U.GetMangoMana(enemy) + (U.GetStickCharges(enemy) * 15)
    local myTotalMana = (bot:GetMana() or 0) + U.GetMangoMana(bot) + (U.GetStickCharges(bot) * 15)
    if myTotalMana >= 150 and eTotalMana < 75 then score = score + 2.0 end
    if eTotalMana >= 150 and myTotalMana < 75 then score = score - 1.5 end

    -- Strict Pro Level/Raze-Tier Discipline:
    -- NEVER return `"AGGRESSIVE"` when enemy SF has a strictly higher Shadowraze tier (e.g. 150 vs 85 base!)
    -- or L2 Presence of the Dark Lord over L1, unless enemy is literally one coil from death!
    if (outRazed or (myLvl == 1 and eLvl >= 2)) and not (eHpPct < 0.22 and myTotalMana >= 75 and myHpPct > 0.35) then
        return "PASSIVE"
    end

    local soulDmgDiff = S.GetSoulDamageBonus(bot) - S.GetSoulDamageBonus(enemy)
    score = score + Clamp(soulDmgDiff / 14.0, -2.5, 2.5)

    local itemPowerDiff = U.GetLaneItemPower(bot) - U.GetLaneItemPower(enemy)
    score = score + Clamp(itemPowerDiff, -2.0, 2.0)

    local allyCount = allyCreeps and #allyCreeps or 0
    local enemyCount = enemyCreeps and #enemyCreeps or 0
    score = score + ((allyCount - enemyCount) * 0.25)

    if U.HasEnemyMissedRazeRecently() and not outRazed and myLvl >= eLvl then
        score = score + 3.0
    end
    if U.HasItem(bot, "item_power_treads") and not U.HasBoots(enemy) then
        score = score + 2.5
    end

    if nearSpike and score < 3.5 then
        return (score <= -2.0) and "PASSIVE" or "NEUTRAL"
    end

    if score <= -2.0 then
        return "PASSIVE"
    elseif score >= 0.8 and myLvl >= eLvl then
        return "AGGRESSIVE"
    else
        return "NEUTRAL"
    end
end

U._domActive = false
U._domSince = -100

-- Single-Authority Schmitt-Hysteresis Lane Dominance Detector (`v7.5.0` `9070559899.dem` Zoning & CS+Deny Freeze):
-- Returns `true` ONLY when SF holds a decisive, safe advantage over a live rival (surviving highground FoW peekaboo
-- via Salve-safe `enemyLastHealth + absent * 32` bound) with allied wave support, outside enemy T1 range, and free of
-- dangerous raze stacks or multi-creep aggro. Shared by `positioning.lua`, `lasthit.lua`, `intent.lua`, and `bot_nevermore.lua`
-- so ALL subsystems agree on the exact same forward posture with ZERO internal tug-of-war or jitter!
function U.IsLaneDominant(bot, s, race)
    local function drop()
        U._domActive = false
        return false
    end
    if not bot or not bot:IsAlive() then return drop() end
    if bot.HasModifier and bot:HasModifier("modifier_flask_healing") then return drop() end
    if U._State and (U._State.goingToFountain or U._State.emergencyRetreat) then return drop() end

    s = s or (U._W and U._W.s) or nil
    race = race or (U._K and U._K._race) or nil
    if s and s.enemyAlive == false then return drop() end
    if s and s.incomingEnemyTPs and #s.incomingEnemyTPs > 0 then return drop() end

    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local myHpPct = myHp / myMaxHp
    if myHp < 390 or myHpPct < 0.46 then return drop() end

    local bLoc = bot:GetLocation()
    if s and s.enemyT1Alive ~= false and s.enemyT1Loc then
        if U.DistanceBetweenLocations(bLoc, s.enemyT1Loc) < 900 then return drop() end
    end

    local allyCreeps = (s and s.allyCreeps) or {}
    local enemyCreeps = (s and s.enemyCreeps) or {}
    local allyCount, enemyCount, creepsOnMe = 0, 0, 0
    for _, ac in pairs(allyCreeps) do
        if ac and ac:IsAlive() then allyCount = allyCount + 1 end
    end
    for _, ec in pairs(enemyCreeps) do
        if ec and ec:IsAlive() then
            enemyCount = enemyCount + 1
            if ec.GetAttackTarget and ec:GetAttackTarget() == bot then
                creepsOnMe = creepsOnMe + 1
            end
        end
    end
    if allyCount < 1 or enemyCount > allyCount + 2 then return drop() end
    if creepsOnMe >= 2 or (creepsOnMe >= 1 and myHp < 560) then return drop() end

    local myLvl = (bot.GetLevel and bot:GetLevel()) or 1
    local eh = (s and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()) and s.enemy or nil
    local enHp, enLvl, enPotMana, outRazed
    if eh then
        enHp = eh:GetHealth() or 9999
        enLvl = (eh.GetLevel and eh:GetLevel()) or myLvl
        enPotMana = U.GetPotentialManaForRaze(eh)
        outRazed = U.IsOutRazedTier(bot, eh)
    elseif s and (s.enemyAbsentFor or 99) <= 6.0 and s.enemyLastHealth ~= nil then
        local absent = math.max(0, s.enemyAbsentFor or 0)
        local enMax = s.enemyLastMaxHealth or myMaxHp
        -- Salve-safe upper bound (`+32 HP/s` covers even an instant fogged Healing Salve!)
        enHp = math.min(enMax, s.enemyLastHealth + absent * 32.0)
        enLvl = s.enemyLastLevel or myLvl
        enPotMana = (s.enemyLastMana or 150) + absent * 3.0
        outRazed = (enLvl >= 7 and myLvl < 7) or (enLvl >= 5 and myLvl < 5) or (enLvl >= 3 and myLvl < 3)
    else
        return drop()
    end

    if outRazed or (myLvl == 1 and enLvl >= 2) then return drop() end
    if race and race.valid and (race.heCanKillNow or race.heCanKillSoon) then return drop() end

    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    if (myStacks or 0) >= 2 and (myRem or 0) > 0.40 then return drop() end
    if (myStacks or 0) >= 1 and (myRem or 0) > 0.50 and enPotMana >= 75 and myHp < enHp + 360 then
        return drop()
    end

    local now = GameTime()
    if U._domSince and now < U._domSince then
        U._domActive = false
        U._domSince = -100
    end
    local myPotMana = (bot:GetMana() or 0) + U.GetMangoMana(bot)
    local edge = (race and race.valid and race.edge) or 0

    if not U._domActive then
        if myHp < 430 or myHpPct < 0.52 then return false end
        local enterOk = (myHp >= enHp + 205 and myHp >= enHp * 1.30)
            or (myLvl > enLvl and myHp >= enHp * 0.94 and myPotMana >= 80)
            or (enHp <= 265 and myHp >= 440)
            or (edge >= 150 and myHp >= enHp * 0.95 and myPotMana >= 140)
            or (enPotMana < 75 and myPotMana >= 145 and myHp >= enHp - 25 and myHp >= 480)
        if enterOk then
            U._domActive = true
            U._domSince = now
            return true
        end
        return false
    end

    local dwellHold = ((now - (U._domSince or -100)) < 2.2) and (myHp >= enHp * 0.90)
    local holdOk = dwellHold
        or (myHp >= enHp + 115 and myHp >= enHp * 1.16)
        or (myLvl > enLvl and myHp >= enHp * 0.85 and myPotMana >= 75)
        or (enHp <= 330 and myHp >= 410)
        or (edge >= 75 and myHp >= enHp * 0.88 and myPotMana >= 75)
        or (enPotMana < 75 and myPotMana >= 85 and myHp >= enHp - 45)
    if not holdOk then
        return drop()
    end
    return true
end

function U.GetShadowrazeDebuff(unit)
    if not unit then return 0, 0, -1 end
    if unit.GetModifierByName and unit.HasModifier and unit:HasModifier("modifier_nevermore_shadowraze_debuff") then
        local idx = unit:GetModifierByName("modifier_nevermore_shadowraze_debuff")
        if idx and idx >= 0 then
            local stacks = unit:GetModifierStackCount(idx) or 0
            local remaining = unit:GetModifierRemainingDuration(idx) or 0
            if stacks > 0 then
                return stacks, remaining, idx
            end
        end
    end
    local numModifiers = unit:NumModifiers()
    if numModifiers and numModifiers > 0 then
        for i = 0, numModifiers - 1 do
            local modName = unit:GetModifierName(i)
            if modName == "modifier_nevermore_shadowraze_debuff" then
                local stacks = unit:GetModifierStackCount(i) or 0
                local remaining = unit:GetModifierRemainingDuration(i) or 0
                return stacks, remaining, i
            end
        end
    end
    return 0, 0, -1
end

-- Position prediction from the REAL velocity (GetVelocity), not "facing x max speed".
-- The old version assumed that a standing enemy (e.g. finishing a creep) moves ~190 units
-- toward his facing in 0.62 s -> razes at a standing enemy missed systematically.
function U.PredictPosition(unit, delay)
    local loc = unit:GetLocation()
    if not loc then return loc end
    delay = delay or 0
    local vel = nil
    if unit.GetVelocity then
        local ok, v = pcall(unit.GetVelocity, unit)
        if ok and v and v.x then vel = v end
    end
    if vel then
        local sp = math.sqrt(vel.x * vel.x + vel.y * vel.y)
        if sp < 40 then return loc end
        local maxSp = unit:GetCurrentMovementSpeed() or 0
        local vx, vy = vel.x, vel.y
        if maxSp > 0 and sp > maxSp * 1.05 then
            vx, vy = vx / sp * maxSp, vy / sp * maxSp
        end
        local stability = 1
        if unit.GetMovementDirectionStability then
            stability = unit:GetMovementDirectionStability() or 1
        end
        if stability < 0.5 then delay = delay * 0.5 end
        -- Reversal smoothing is per unit and per frame: midpoint/landing queries
        -- must use the same estimate, regardless of their call order.
        U._motionHistory = U._motionHistory or setmetatable({}, {__mode = "k"})
        local hist = U._motionHistory[unit]
        local nowT = GameTime()
        if not hist or hist.t ~= nowT then
            local scale = 1
            if hist and nowT > hist.t and nowT - hist.t <= 0.35 then
                local pmag = math.sqrt(hist.rawX * hist.rawX + hist.rawY * hist.rawY)
                if pmag > 40 and sp > 40 and (hist.rawX * vel.x + hist.rawY * vel.y) / (pmag * sp) < 0.7 then
                    scale = 0.6
                    vx, vy = vx * 0.6 + hist.rawX * 0.4, vy * 0.6 + hist.rawY * 0.4
                end
            end
            local smoothSpeed = math.sqrt(vx * vx + vy * vy)
            if maxSp > 0 and smoothSpeed > maxSp then
                vx, vy = vx / smoothSpeed * maxSp, vy / smoothSpeed * maxSp
            end
            hist = {t = nowT, rawX = vel.x, rawY = vel.y, vx = vx, vy = vy, scale = scale}
            U._motionHistory[unit] = hist
        end
        vx, vy, delay = hist.vx, hist.vy, delay * hist.scale
        return Vector(loc.x + vx * delay, loc.y + vy * delay, loc.z)
    end
    -- Native extrapolation also handles standing units; facing alone is not velocity.
    if unit.GetExtrapolatedLocation then
        local ok, predicted = pcall(unit.GetExtrapolatedLocation, unit, delay)
        if ok and predicted then return predicted end
    end
    -- Last-resort fallback for API variants without motion queries.
    local stability = 1
    if unit.GetMovementDirectionStability then
        stability = unit:GetMovementDirectionStability() or 1
    end
    if stability < 0.5 then return loc end
    local speed = unit:GetCurrentMovementSpeed() or 0
    local facingRad = math.rad(unit:GetFacing() or 0)
    return Vector(
        loc.x + math.cos(facingRad) * speed * delay,
        loc.y + math.sin(facingRad) * speed * delay,
        loc.z
    )
end

function U.GetAngleDifference(bot, targetLoc)
    local botLoc = bot:GetLocation()
    local facing = bot:GetFacing()
    local angleToTarget = math.deg(Atan2(targetLoc.y - botLoc.y, targetLoc.x - botLoc.x))
    if angleToTarget < 0 then angleToTarget = angleToTarget + 360 end
    local diff = math.abs(facing - angleToTarget)
    if diff > 180 then diff = 360 - diff end
    return diff
end

function U.GetRazeAbilityData(ability)
    if not ability then return nil end
    local name = ability:GetName()
    if name == "nevermore_shadowraze1" then return { center = C.RAZE.NEAR_CENTER, label = "near" } end
    if name == "nevermore_shadowraze2" then return { center = C.RAZE.MID_CENTER,  label = "mid" } end
    if name == "nevermore_shadowraze3" then return { center = C.RAZE.FAR_CENTER,  label = "far" } end
    return nil
end

function U.GetFacingVector(unit)
    local rad = math.rad(unit:GetFacing() or 0)
    return Vector(math.cos(rad), math.sin(rad), 0)
end

function U.GetRazeCircleCenter(bot, centerDistance)
    local loc = bot:GetLocation()
    local forward = U.GetFacingVector(bot)
    return Vector(
        loc.x + forward.x * centerDistance,
        loc.y + forward.y * centerDistance,
        loc.z
    )
end

function U.GetRazeHitErrorWithCurrentFacing(bot, targetLoc, centerDistance)
    local center = U.GetRazeCircleCenter(bot, centerDistance)
    return U.DistanceBetweenLocations(center, targetLoc)
end

function U.GetRazeHitErrorWithDesiredFacing(bot, targetLoc, centerDistance)
    local dist = GetUnitToLocationDistance(bot, targetLoc)
    return math.abs(dist - centerDistance)
end

function U.IsRazeAbilityCastable(bot, ability)
    if not ability or not ability:IsFullyCastable() then return false end
    return bot:GetMana() >= 75
end

-- Robust raze aiming. The raze circle (R=250) must cover the enemy both where he is
-- NOW and where he will be after delay if he keeps moving. We aim at the middle
-- of the segment between those points. A single predicted point caused systematic misses:
-- the enemy stopped - a "forward" miss (the raze landed where he "should have arrived"), the enemy walked/accelerated
-- after our decision - a "backward" miss.
-- Returns: errAim (the worst error with a perfect turn toward aim), errFacing (the same
-- at the CURRENT facing - the raze flies where we look), aim (the aim point), pPred.
-- Three points (now / middle of the cast / landing) and aiming at the middle of the widest
-- pair. An enemy turning during the cast is covered better, and one leaving the circle during the
-- cast is filtered out by the growing worst error - instead of casting "after him" and missing.
function U.RobustRazeErrors(bot, target, center, delay)
    local land = C.RAZE.CAST_POINT + (C.RAZE.LAND_LEAD or 0.08)
    delay = delay or C.RAZE.PREDICT_DELAY
    if delay < land then delay = land end
    local botLoc = bot:GetLocation()
    local pNow = target:GetLocation()
    local pMid = U.PredictPosition(target, delay * 0.5) or pNow
    local pPred = U.PredictPosition(target, delay) or pNow

    local function Dist2(a, b)
        local ax, ay = a.x - b.x, a.y - b.y
        return ax * ax + ay * ay
    end
    local dEnd, dMidA, dMidB = Dist2(pNow, pPred), Dist2(pNow, pMid), Dist2(pMid, pPred)
    local pa, pb = pNow, pPred
    if dMidA > dEnd and dMidA >= dMidB then
        pa, pb = pNow, pMid
    elseif dMidB > dEnd and dMidB > dMidA then
        pa, pb = pMid, pPred
    end
    local aim = Vector((pa.x + pb.x) * 0.5, (pa.y + pb.y) * 0.5, pNow.z)

    local dx, dy = aim.x - botLoc.x, aim.y - botLoc.y
    local d = math.sqrt(dx * dx + dy * dy)
    local ux, uy
    if d < 1 then
        local f = U.GetFacingVector(bot)
        ux, uy = f.x, f.y
    else
        ux, uy = dx / d, dy / d
    end
    local function worst(cx, cy)
        local e1 = math.sqrt((pNow.x - cx) * (pNow.x - cx) + (pNow.y - cy) * (pNow.y - cy))
        local e2 = math.sqrt((pMid.x - cx) * (pMid.x - cx) + (pMid.y - cy) * (pMid.y - cy))
        local e3 = math.sqrt((pPred.x - cx) * (pPred.x - cx) + (pPred.y - cy) * (pPred.y - cy))
        local m = e1
        if e2 > m then m = e2 end
        if e3 > m then m = e3 end
        return m
    end
    local errAim = worst(botLoc.x + ux * center, botLoc.y + uy * center)
    local f = U.GetFacingVector(bot)
    local errFacing = worst(botLoc.x + f.x * center, botLoc.y + f.y * center)
    return errAim, errFacing, aim, pPred
end

-- Will the raze hit at the CURRENT facing (robustly: for both the current and the predicted point).
-- The third value is the aim point (for turning), not the "predicted position" as before.
function U.WillRazeHit(bot, ability, target, delay, strict)
    if not ability or not target or not target:IsAlive() then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data then return false end
    local errAim, errFacing, aim = U.RobustRazeErrors(bot, target, data.center, delay or C.RAZE.CAST_POINT)
    local limit = strict and C.RAZE.STRICT_RADIUS or (C.RAZE.HIT_RADIUS - (C.RAZE.ROBUST_MARGIN or 30))
    return errFacing <= limit, errFacing, aim, errAim
end

function U.GetBestRaze(bot, target, mode, isLethalChase, forceExtend)
    if bot:GetMana() < 75 then return nil, nil, nil end
    if not U.CanQuery(target) then return nil, nil, nil end

    isLethalChase = isLethalChase or false
    forceExtend = forceExtend or false

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")

    local stacks, rem_time = U.GetShadowrazeDebuff(target)
    local lowHpFinish = target:GetHealth() <= 380
    local lethalWithTwo = U.GetTwoRazeDamage(bot, target) >= target:GetHealth() * 0.95
    -- "Lethal with two" - only with razes that are REALLY available (cooldowns/mana), otherwise
    -- the "finish mode" engaged with one raze left and produced risky casts
    local Rk = U._K and U._K._race
    if Rk and Rk.valid then lethalWithTwo = Rk.canKillSoon end
    local interruptRegen = U.IsEnemyHighValueRegen(target)
    local enemyMissed = U.HasEnemyMissedRazeRecently()
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, target)
    local mustKillNow = lethalWithTwo or lowHpFinish or isLethalChase or forceExtend

    -- The rule "one stack and more than EXTEND_AT until it expires -> do not cast" was REMOVED. It postponed
    -- the second raze by ~3 s for the sake of "extending" the stack while a leaving enemy left all
    -- the bands in that time: the second stack (free, he cannot answer) was lost. Now the second/third raze goes
    -- out immediately if it covers robustly; mana discipline belongs to the caller (HarassManaOK/followUp).

    local predLoc = U.PredictPosition(target, C.RAZE.PREDICT_DELAY)
    local myDist = GetUnitToLocationDistance(bot, predLoc)
    local bootsAdvantage = U.HasBoots(bot) and not U.HasBoots(target)
    local robustMargin = C.RAZE.ROBUST_MARGIN or 30
    local targetStationary = true
    if target.GetVelocity then
        local okV, tv = pcall(target.GetVelocity, target)
        if okV and tv and tv.x then
            targetStationary = math.sqrt(tv.x * tv.x + tv.y * tv.y) < 60
        end
    end
    -- He is leaving us carrying our stack - the finish must be the far band
    local enemyFleeing = (U._K and U._K.IsEnemyMovingAway(bot, target)) or false

    local candidates = {
        { ability = q, center = C.RAZE.NEAR_CENTER, label = "near" },
        { ability = w, center = C.RAZE.MID_CENTER,  label = "mid"  },
        { ability = e, center = C.RAZE.FAR_CENTER,  label = "far"  },
    }

    local best = nil
    local bestScore = math.huge

    for _, candidate in ipairs(candidates) do
        local ability = candidate.ability
        local data = U.GetRazeAbilityData(ability)
        if data and U.IsRazeAbilityCastable(bot, ability) then
            local allow = true

            -- The band ban is now cooldown-driven: a band is safe while HIS copy of that
            -- band is on cooldown (nothing to answer with). The old "only the band he
            -- hit us with last" is kept as a fallback - the tracker may have missed the cast.
            if secondStackActive and data.label ~= safeReplyLabel
                and not U.IsBandSafeForMe(target, data.label, C.RAZE.CAST_POINT + 0.15) then
                allow = false
            end

            if data.label == "far" and mode == "NEUTRAL" and stacks == 0
               and not secondStackActive
               and not U.IsEnemyCastingRaze(target)
               and not interruptRegen and not enemyMissed and not mustKillNow then
                allow = false
            end

            if allow then
                -- Robust error: the worst of the two points (now / after PREDICT_DELAY) when aiming
                -- at their middle. The limit is the circle radius minus a margin; for finishing/extending/answering
                -- the margin is smaller (not missing the chance matters more), for harass - larger (not missing matters more).
                local errAim, errFacing, aimLoc = U.RobustRazeErrors(bot, target, data.center, C.RAZE.PREDICT_DELAY)
                local plannedError = errAim
                local limit = C.RAZE.HIT_RADIUS - robustMargin
                if targetStationary then
                    -- A standing enemy may start moving during the cast: a margin from the circle edge is needed
                    -- (100 u ~ 0.33 s of his walking); such an enemy at the band edge is not touched
                    limit = C.RAZE.HIT_RADIUS - 100
                    -- Finishing a stack (the enemy is already hit, the stack has >= 1.2 s) - a softer margin (60 u):
                    -- the value of a hit is higher and the "robust" error already accounts for both points
                    if stacks > 0 and rem_time >= (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2) then
                        limit = C.RAZE.HIT_RADIUS - 60
                    end
                end
                -- "Pure" harass (not a finish, not an answer to his raze, not a stack): a reacting enemy
                -- leaves the circle during the cast (0.55 s ~ 150 u) if it is < ~110 u from the circle edge. So for
                -- harass we require errAim <= 160 (closer to the band centre) instead of 220 "at the edge".
                local followUpStack = stacks > 0 and rem_time >= (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2)
                if not (mustKillNow or forceExtend or interruptRegen or secondStackActive or followUpStack) then
                    limit = math.min(limit, C.RAZE.HIT_RADIUS - (C.RAZE.HARASS_MARGIN or 90))
                end
                if mustKillNow or forceExtend or interruptRegen or secondStackActive then
                    limit = C.RAZE.HIT_RADIUS - 10
                    -- A STANDING enemy at the band edge reacts to the cast animation (0.55 s = 150+ u
                    -- of walking): if this raze does not kill him on its own, keep the margin from the edge -
                    -- otherwise the cycle "cast at the edge -> he stepped -> cancel -> cast" (and a miss in game).
                    local killNow = Rk and Rk.valid and Rk.canKillNow
                    if targetStationary and not killNow and not forceExtend and not isLethalChase and not secondStackActive then
                        limit = math.min(limit, C.RAZE.HIT_RADIUS - 70)
                    end
                end
                local gamble = false
                -- Betting "on the prediction" only when this raze really decides it (kills him
                -- now / a lethal chase / extends the stack), not merely "he has low HP":
                -- otherwise the bot threw a raze at the circle edge at a standing 380 HP enemy and missed.
                local gambleWorth = isLethalChase or forceExtend or (Rk and Rk.valid and Rk.canKillNow)
                if plannedError > limit and gambleWorth then
                    -- Finish: we do not cover robustly - allow a bet on the prediction (as before)
                    local predOnly = U.GetRazeHitErrorWithDesiredFacing(bot, predLoc, data.center)
                    if predOnly <= C.RAZE.HIT_RADIUS then
                        plannedError = predOnly
                        limit = C.RAZE.HIT_RADIUS
                        aimLoc = predLoc
                        errFacing = U.GetRazeHitErrorWithCurrentFacing(bot, predLoc, data.center)
                        gamble = true
                    end
                end

                if data.label == "near" and not isLethalChase and not forceExtend then
                    local realDist = GetUnitToLocationDistance(bot, aimLoc)
                    if realDist > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then
                        plannedError = math.huge
                    end
                end

                if data.label == "near" and not mustKillNow then
                    if U.HasStackAndShouldFearNear(bot, target) then
                        plannedError = math.huge
                    end
                end

                if plannedError <= limit then
                    local score = plannedError
                    if gamble then score = score + 60 end

                    if secondStackActive and safeReplyLabel and data.label == safeReplyLabel then
                        score = score - 140
                    elseif stacks == 0 and not mustKillNow then
                        if mode == "AGGRESSIVE" then
                            -- Opening with the far band: we cast from beyond his auto attack and his
                            -- near bands; if he closes, mid meets him, if he backs off he is already hit
                            if data.label == "far" then score = score - 60 end
                            if data.label == "mid" then score = score - 40 end
                            if data.label == "near" then score = score + 10 end
                        else
                            if data.label == "mid" then score = score - 60 end
                            if data.label == "far" then score = score + 20 end
                            if data.label == "near" then score = score + 10 end
                        end
                    else
                        local distDiff = math.abs(myDist - data.center)
                        score = score - math.max(0, 80 - distDiff * 0.5)
                        if stacks >= C.FINISH.MIN_STACKS_FOR_CLOSE and data.label == "near" then
                            score = score - 80
                        end
                    end

                    if forceExtend and bootsAdvantage then
                        if data.label == "far" then score = score + 120 end
                        if data.label == "mid" then score = score - 90 end
                    elseif forceExtend and not bootsAdvantage then
                        if data.label == "mid" then score = score - 30 end
                    end

                    -- A leaving enemy with a stack is caught by the far band (he runs into it
                    -- himself), mid is second. A near band on a runner is almost a miss.
                    if enemyFleeing and stacks > 0 then
                        if data.label == "far" then score = score - 90 end
                        if data.label == "mid" then score = score - 20 end
                    end

                    if mustKillNow then
                        score = score - 200
                        local distDiff2 = math.abs(myDist - data.center)
                        if distDiff2 < 80 then score = score - 50 end
                    elseif forceExtend then
                        score = score - 150
                    elseif stacks > 0 and rem_time <= C.RAZE.EXTEND_AT + 0.6 then
                        score = score - 110
                    elseif stacks >= 2 then
                        score = score - 45
                    end

                    if interruptRegen then score = score - 130 end
                    if enemyMissed then score = score - 55 end

                    if score < bestScore then
                        bestScore = score
                        best = { ability = ability, data = data, aimLoc = aimLoc, limit = limit, errFacing = errFacing }
                    end
                end
            end
        end
    end

    if best then
        -- The raze flies where we look: if at the current facing the circle covers both points
        -- (with a small margin) - cast immediately, otherwise turn toward the aim point.
        -- The cast threshold equals the candidate threshold (otherwise a "dead zone": after turning
        -- errFacing == plannedError in (limit-15, limit] -> TURN every tick, no cast - the bot jitters)
        if best.errFacing <= best.limit then
            return best.ability, "CAST", best.aimLoc
        end
        return best.ability, "TURN", best.aimLoc
    end

    return nil, nil, nil
end

function U.GetRazeSetupPosition(bot, target)
    if not U.CanQuery(target) then return nil end

    local targetLoc = U.PredictPosition(target, 0.35)
    local botLoc = bot:GetLocation()
    local myDist = GetUnitToLocationDistance(bot, targetLoc)
    local stacks = U.GetShadowrazeDebuff(target)
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, target)
    local bestCenter = nil
    local bestScore = math.huge
    local bootsAdvantage = U.HasBoots(bot) and not U.HasBoots(target)

    local abilities = {
        bot:GetAbilityByName("nevermore_shadowraze2"),
        bot:GetAbilityByName("nevermore_shadowraze3"),
        bot:GetAbilityByName("nevermore_shadowraze1"),
    }
    local targetFleeing = (U._K and U._K.IsEnemyMovingAway(bot, target)) or false
    for _, ability in ipairs(abilities) do
        local data = U.GetRazeAbilityData(ability)
        if data and U.IsRazeAbilityCastable(bot, ability) then
            local distDiff = math.abs(myDist - data.center)
            local score = distDiff
            if stacks == 0 then
                if data.label == "mid" then score = score - 80 end
                if data.label == "far" then score = score + 30 end
                if data.label == "near" then score = score + 20 end
            else
                if data.label == "mid" then score = score - 15 end
            end
            if data.label == "near" and U.HasStackAndShouldFearNear(bot, target) then
                score = score + 9999
            end
            if bootsAdvantage then
                if data.label == "far" then score = score + 80 end
                if data.label == "mid" then score = score - 50 end
            end
            -- A leaving enemy with a stack is caught with the far band
            if targetFleeing and stacks > 0 then
                if data.label == "far" then score = score - 140 end
                if data.label == "mid" then score = score - 30 end
            end
            -- With a stack on us we only stand in a band whose copy is on his cooldown
            if secondStackActive then
                if data.label == safeReplyLabel then
                    score = score - 70
                elseif not U.IsBandSafeForMe(target, data.label, C.RAZE.CAST_POINT + 0.15) then
                    score = score + 9999
                end
            end
            if score < bestScore then
                bestScore = score
                bestCenter = data.center
            end
        end
    end

    if not bestCenter then bestCenter = C.RAZE.MID_CENTER end

    local dir = botLoc - targetLoc
    if U.DistanceBetweenLocations(botLoc, targetLoc) < 1 then
        dir = U.GetFountain(bot) - botLoc
    end
    dir = dir:Normalized()
    return targetLoc + dir * bestCenter
end

-- Does the enemy have a raze ready within the next horizon seconds (by the cast phase tracker) and the mana for it.
-- IsFullyCastable does not see the cooldown of enemy abilities, so we trust only the tracker;
-- if the tracker is not connected - assume there is a raze (conservative).
function U.EnemyCanUseRaze(enemy, horizon)
    if not U.CanQuery(enemy) then return false end
    if not U.EnemyHasRaze(enemy) then return false end
    if U._K then
        local n = U._K.EnemyReadyRazeCount(enemy, horizon or 1.0, true)
        return n > 0
    end
    local totalMana = enemy:GetMana() + U.GetMangoMana(enemy)
    return totalMana >= 75
end

function U.GetRetreatPositionFromEnemySF(bot, enemy)
    local botLoc = bot:GetLocation()
    local enemyLoc = enemy:GetLocation()
    local fountain = U.GetFountain(bot)
    local away = botLoc - enemyLoc
    if U.DistanceBetweenLocations(botLoc, enemyLoc) < 1 then
        away = fountain - botLoc
    end
    away = away:Normalized()
    local toFountain = (fountain - botLoc):Normalized()
    return botLoc + away * 680 + toFountain * 360
end

-- Should we retreat because of raze stacks on us. The decision uses the enemy's available burst
-- (cooldown tracker + mana + band reach) and absolute HP, not "by default".
-- Returns shouldRetreat, retreatLoc, reason.
function U.ShouldRetreatFromEnemyRazeStack(bot, enemy)
    if not U.CanQuery(enemy) then return false, nil end
    if not U.EnemyHasRaze(enemy) then return false, nil end
    local K = U._K
    if not K then
        -- Fallback without the tracker: the old behaviour
        local dist0 = GetUnitToLocationDistance(enemy, bot:GetLocation())
        local stacks0, rem0 = U.GetShadowrazeDebuff(bot)
        if stacks0 >= 2 and rem0 > C.RAZE.RETREAT_MIN_REMAIN and dist0 <= (C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS) then
            return true, U.GetRetreatPositionFromEnemySF(bot, enemy), "legacy"
        end
        return false, nil
    end

    local dist = GetUnitToLocationDistance(enemy, bot:GetLocation())
    local hp = bot:GetHealth()
    local R = K._race
    if not (R and R.valid) then R = K.Race(bot, enemy, false) end

    -- 1) his available burst kills me and I cannot kill him "right now" -> leave
    if R.heCanKillSoon and not R.canKillNow then
        return true, U.GetRetreatPositionFromEnemySF(bot, enemy), "lethal burst"
    end

    -- 2) I stand deep inside his READY band: one of his razes takes a big chunk of HP and the trade
    -- is against me -> back off to the "hedge" edge of the band (not to the fountain and not past all bands).
    -- The fear conditions were tightened in FearBandPredicate (a stack on us or >= 45 % HP per raze);
    -- and we do not retreat while already at our own T1 (nowhere further to go - the tower will punish him).
    local nearOwnT1 = false
    local ownT1 = (U._W and U._W.s and U._W.s.allyT1) or nil
    if ownT1 then
        local okL, tl = pcall(ownT1.GetLocation, ownT1)
        if okL and tl and U.DistanceBetweenLocations(tl, bot:GetLocation()) <= 400 then nearOwnT1 = true end
    end
    -- The enemy's closing speed (>0 - walking at me). At equal running speed he will not catch
    -- a LEAVING bot but will catch a STANDING one: the retreat threshold and step length grow by his closing
    -- speed (previously: a 60-100 u step, the bot stopped, the enemy came right up to the band and
    -- landed a 2nd/3rd raze - "the bot was in no hurry to back off").
    local approach = U.EnemyApproachSpeed(bot, enemy)
    local band = K.EnemyReadyBandAt(enemy, dist, 1.0) or K.EnemyReadyBandAt(enemy, dist - approach * 0.7, 1.0)
    -- 2b) I have a fresh stack, he stands in his READY band and the trade is against me ->
    -- do not let him build a 2nd/3rd/4th stack: leave past the edge of his ready bands before the stack
    -- expires (6 s). Exception - a favourable trade or a guaranteed kill.
    -- A "favourable trade" only if I can really answer (mana >= 75 and a raze ready):
    -- previously a bot with 66 mana considered the trade favourable, stood still and collected 3 stacks.
    -- The "at our own T1" exception was removed for 2b - backing off behind the tower is always possible.
    local stackedFresh = false
    do
        local st, rem = U.GetShadowrazeDebuff(bot)
        stackedFresh = (st or 0) >= 1 and (rem or 0) >= 1.0
    end
    if band and stackedFresh and not R.canKillSoon and not U.IsStackTradeFavorable(bot, R) then
        local safe = K.EnemyMinSafeDistance(enemy, 1.0)
        local trigger = safe + approach * 0.7
        if safe > 0 and dist < trigger - 20 then
            local botLoc = bot:GetLocation()
            local enemyLoc = enemy:GetLocation()
            local away = botLoc - enemyLoc
            if dist < 1 then away = U.GetFountain(bot) - botLoc end
            away = away:Normalized()
            local toFountain = (U.GetFountain(bot) - botLoc):Normalized()
            local need = math.max(0, safe - dist) + 40 + approach * 1.2
            if approach > 60 and need < 300 then need = 300 end
            return true, botLoc + away * need * 0.7 + toFountain * need * 0.3, "stacked, in ready band"
        end
    end
    if band and not nearOwnT1 and U.FearBandPredicate(bot, enemy, R) then
        local safe = K.EnemyDodgeableDistance(enemy, 1.0)
        if dist < safe + approach * 0.7 - 20 then
            local botLoc = bot:GetLocation()
            local enemyLoc = enemy:GetLocation()
            local away = botLoc - enemyLoc
            if dist < 1 then away = U.GetFountain(bot) - botLoc end
            away = away:Normalized()
            local toFountain = (U.GetFountain(bot) - botLoc):Normalized()
            local need = math.max(0, safe - dist) + 40 + approach * 1.2
            return true, botLoc + away * need * 0.7 + toFountain * need * 0.3, "in ready band"
        end
    end

    return false, nil
end

-- The enemy's closing speed on me (u/s, > 0 - walking at me; 0 - standing/leaving/sideways).
function U.EnemyApproachSpeed(bot, enemy)
    if not U.CanQuery(enemy) or not enemy.GetVelocity then return 0 end
    local okV, v = pcall(enemy.GetVelocity, enemy)
    if not okV or not v then return 0 end
    local vx, vy = v.x or 0, v.y or 0
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed < 60 then return 0 end
    local botLoc = bot:GetLocation()
    local enLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(botLoc, enLoc)
    if d < 1 then return 0 end
    local ax, ay = (botLoc.x - enLoc.x) / d, (botLoc.y - enLoc.y) / d
    local toward = vx * ax + vy * ay
    if toward <= 0 then return 0 end
    return toward
end

-- A "favourable trade with a stack on me": an edge >= 60, my HP >= his AND I can really answer
-- with a raze (mana >= 75, at least one of my razes is ready within ~2.5 s and reaches him).
function U.IsStackTradeFavorable(bot, R)
    if not (R and R.valid) then return false end
    if R.canKillSoon then return true end
    if R.edge < 60 or R.myHp < R.enHp then return false end
    if (bot:GetMana() or 0) < 75 then return false end
    if (R.myRazesSoon or 0) < 1 then return false end
    return true
end

-- The single "band fear" predicate: one of his razes >= 30% of my HP, the trade is against me,
-- and I cannot kill him back with one raze.
function U.FearBandPredicate(bot, enemy, R)
    local K = U._K
    if not K or not (R and R.valid) then return false end
    local oneRaze = K.EnemyRazeDamage(bot, enemy, 1)
    local myOneRaze = U.GetNRazeDamage(bot, enemy, 1)
    local canKillBack = myOneRaze >= enemy:GetHealth() and K.MyReadyRazeCount(bot, true) > 0
    if canKillBack then return false end
    if R.edge >= 0 then return false end
    local hp = bot:GetHealth()
    -- Without a stack on us, one of his razes is an unpleasant but not critical trade; "band fear"
    -- (backing off past the edge of his far band = ~900 from him) without a stack drove a weaker bot
    -- off the lane on any enemy step forward and caused "to the tower and back" twitching. Now fear
    -- only applies with a stack (the next raze has the bonus) or if one raze takes >= 45 % HP.
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    local stackedMe = (myStacks or 0) >= 1 and (myRem or 0) >= 1.0
    if stackedMe then return oneRaze >= hp * 0.30 end
    return oneRaze >= hp * 0.45
end

-- The minimum distance to the enemy that our "fear" currently demands (0 = no restriction).
-- The same predicate is used by: the band retreat, approaching the enemy, the last-hit position and
-- the final position - so different handlers do not pull the bot in different directions (oscillation).
-- "Mid band fear" (dry mana against his raze / he reached level 2 first / he is
-- faster on boots) - RealThink sets the flag every tick. While it is active the minimum distance
-- to the enemy = the outer edge of his mid band: we do not enter the band for a creep PROACTIVELY instead of
-- "went for the creep -> got scared -> ran 1000 away -> came back for the creep" in a loop.
U._midFear = false
U.MID_FEAR_DIST = C.RAZE.MID_CENTER + 210 + 40

function U.GetFearMinDist(bot, enemy)
    local K = U._K
    if not K or not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return 0 end
    local R = K._race
    local best = U._midFear and U.MID_FEAR_DIST or 0
    if not (R and R.valid) then return best end
    if R.heCanKillSoon and not R.canKillNow then return math.max(best, K.EnemyMinSafeDistance(enemy, 1.0)) end
    if U.FearBandPredicate(bot, enemy, R) then return math.max(best, K.EnemyDodgeableDistance(enemy, 1.0)) end
    return best
end

-- A short step past the edge of his mid band (instead of a ~1000 retreat toward the fountain from
-- GetRetreatPositionFromEnemySF): the step is only as long as needed, slightly toward the fountain.
function U.GetMidBandExitPosition(bot, enemy)
    local botLoc, enemyLoc = bot:GetLocation(), enemy:GetLocation()
    local fountain = U.GetFountain(bot)
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local toFountain = (fountain - botLoc):Normalized()
    local away = (dist > 1) and (botLoc - enemyLoc):Normalized() or toFountain
    local dir = (away * 0.75 + toFountain * 0.25):Normalized()
    local approach = U.EnemyApproachSpeed(bot, enemy)
    local need = (U.MID_FEAR_DIST + 60) - dist + 55 + approach * 0.85
    if need < 225 then need = 225 end
    return botLoc + dir * need
end

-- Power Treads. 0 = strength, 1 = agility, 2 = intelligence (the engine Attributes enum);
-- the in-game switch order is strength -> intelligence -> agility -> strength. We keep the state here:
-- fields on the bot handle cannot be written reliably from the bot script, so the previous
-- implementation (bot._pt_state) effectively never switched the boots.
U._pt = { stat = nil, lastSwitch = -1000 }

local PT_NEXT = { [0] = 2, [2] = 1, [1] = 0 }

local function GetPowerTreadsItem(bot)
    if not bot or not bot.FindItemSlot then return nil end
    local okS, slot = pcall(bot.FindItemSlot, bot, "item_power_treads")
    if not okS or type(slot) ~= "number" or slot < 0 or slot > 5 then return nil end
    local okI, pt = pcall(bot.GetItemInSlot, bot, slot)
    if not okI or not pt then return nil end
    local okC, ready = pcall(pt.IsFullyCastable, pt)
    if okC and ready == false then return nil end
    return pt
end

local function GetPowerTreadsStat(pt)
    if type(pt.GetPowerTreadsStat) == "function" then
        local ok, v = pcall(pt.GetPowerTreadsStat, pt)
        if ok and type(v) == "number" and v >= 0 and v <= 2 then
            U._pt.stat = v
            return v
        end
    end
    if U._pt.stat == nil then U._pt.stat = (C.TREADS and C.TREADS.STRENGTH) or 0 end
    return U._pt.stat
end

-- One switch order per SWITCH_COOLDOWN and only if the attribute really differs.
-- Returns true when the order was issued (it takes the tick - the cast/move goes on the next one).
function U.SwitchTreadsTo(bot, targetStat, opts)
    if type(targetStat) ~= "number" then return false end
    local pt = GetPowerTreadsItem(bot)
    if not pt then return false end
    local cfg = C.TREADS or {}
    opts = opts or {}
    local now = GameTime()
    local hold = opts.hold or (cfg.SWITCH_COOLDOWN or 0.35)
    if now < (U._pt.lastSwitch or -1000) + hold then return false end
    local cur = GetPowerTreadsStat(pt)
    if cur == targetStat then return false end
    -- One order = one step along the strength -> intelligence -> agility -> strength cycle. If two steps
    -- are needed but a second order cannot be spent in combat (we are about to raze) - skip the switch.
    if opts.oneUseOnly and (PT_NEXT[cur] or -1) ~= targetStat then return false end
    local ok = pcall(bot.Action_UseAbility, bot, pt)
    if not ok then return false end
    U._pt.stat = PT_NEXT[cur] or targetStat
    U._pt.lastSwitch = now
    return true
end

-- mode: "CAST" (intelligence before a raze) / "SURVIVE" (strength) / "FIGHT" (agility).
function U.UpdatePowerTreads(bot, mode, opts)
    local cfg = C.TREADS or {}
    local want
    if mode == "CAST" then
        want = cfg.INTELLIGENCE
    elseif mode == "SURVIVE" then
        want = cfg.STRENGTH
    elseif mode == "FIGHT" then
        want = cfg.AGILITY
    else
        return false
    end
    if want == nil then return false end
    -- Intelligence raises the mana CEILING (and the pool itself when switching), so the switch
    -- makes sense even at full mana - otherwise the boots would never reach intelligence by raze time.
    return U.SwitchTreadsTo(bot, want, opts)
end

function U.GetRazeSetupPositionForAbility(bot, target, centerDistance)
    if not target then return bot:GetLocation() end
    local targetLoc = U.PredictPosition(target, 0.35)
    local botLoc = bot:GetLocation()
    local dir = botLoc - targetLoc
    if U.DistanceBetweenLocations(botLoc, targetLoc) < 1 then
        dir = U.GetFountain(bot) - botLoc
    end
    dir = dir:Normalized()
    return targetLoc + dir * centerDistance
end

local RAZE_BASE_BY_LVL  = (C.RAZE and C.RAZE.BASE_DAMAGE)  or { 85, 150, 215, 280 }
local RAZE_STACK_BY_LVL = (C.RAZE and C.RAZE.STACK_DAMAGE) or { 35, 50, 65, 80 }

-- Raw raze damage: exact Patch 7.41f base (85/150/215/280) + stacks*(35/50/65/80 + Lvl10 +30 talent) + souls*2,
-- scaled by Spell Amp (GetSpellAmp / Kaya), with KV fallback when C++ GetSpecialValueInt returns 0!
function U.GetRazeRawDamage(ability, stacks, souls, caster)
    if not ability then return 0 end
    local lvl = ability:GetLevel() or 0
    if lvl <= 0 then return 0 end
    local baseDmg = ability:GetSpecialValueInt("shadowraze_damage") or 0
    if baseDmg <= 0 then baseDmg = RAZE_BASE_BY_LVL[math.min(4, lvl)] or 85 end
    local stackDmg = ability:GetSpecialValueInt("stack_bonus_damage") or 0
    if stackDmg <= 0 then
        stackDmg = RAZE_STACK_BY_LVL[math.min(4, lvl)] or 35
        if caster and U.HasRazeStackTalent(caster) then
            stackDmg = stackDmg + ((C.RAZE and C.RAZE.TALENT_STACK_BONUS) or 30)
        end
    end
    local perSoul = ability:GetSpecialValueInt("damage_per_soul") or 0
    if not perSoul or perSoul <= 0 then perSoul = (C.RAZE and C.RAZE.DAMAGE_PER_SOUL) or 2 end
    local raw = baseDmg + (stacks or 0) * stackDmg + (souls or 0) * perSoul
    if caster then
        raw = raw * U.GetSpellAmpMult(caster)
    end
    return raw
end

function U.GetNRazeDamage(bot, target, razeCount)
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return 0 end
    if not target or not target:IsAlive() then return 0 end
    local stacks = U.GetShadowrazeDebuff(target) or 0
    local souls = S.GetSouls(bot)
    local totalDmg = 0
    for i = 1, (razeCount or 1) do
        local rawDmg = U.GetRazeRawDamage(q, stacks + (i - 1), souls, bot)
        totalDmg = totalDmg + target:GetActualIncomingDamage(rawDmg, DAMAGE_TYPE_MAGICAL)
    end
    return totalDmg
end

function U.GetTwoRazeDamage(bot, target)
    return U.GetNRazeDamage(bot, target, 2)
end

function U.CanKillEnemyWithTwoRazes(bot, enemy)
    if not bot or not enemy or not U.CanQuery(enemy) then return false end
    return U.GetTwoRazeDamage(bot, enemy) >= enemy:GetHealth()
end

function U.EnemyHasTwoRazeManaThreat(enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if not U.EnemyHasRaze(enemy) then return false end
    local manaThreat = U.GetPotentialManaForRaze(enemy)
    if manaThreat >= ((C.BOOT_FEAR and C.BOOT_FEAR.TWO_RAZE_MANA_COST) or 150) then
        return true
    end
    local charges = U.GetStickCharges(enemy)
    if charges >= ((C.BOOT_FEAR and C.BOOT_FEAR.STICK_CHARGES_THREAT) or 10) then
        return true
    end
    return false
end

function U.ShouldFearBootsMidRaze(bot, enemy)
    if not bot or not enemy or not U.CanQuery(enemy) then return false end
    if U.HasBoots(bot) then return false end
    if not U.HasBoots(enemy) then return false end
    if U._K and U._K.BandSafeFromEnemy(enemy, "mid", 1.2) then return false end
    if U.CanKillEnemyWithTwoRazes(bot, enemy) then return false end
    if not U.EnemyHasTwoRazeManaThreat(enemy) then return false end
    -- `v4.2.0` Equal-State Stand-Ground Rule (`Demo 2` 25-concession fix):
    -- Never auto-flee from a Boots SF on healthy/equal resources when we carry our own raze mana & survive 2 razes,
    -- UNLESS enemy also outlevels/outdamages us or already holds a stack on us!
    local myHp = bot:GetHealth() or 0
    local enHp = enemy:GetHealth() or 999
    local mySt = U.GetShadowrazeDebuff(bot) or 0
    local outclassed = ((enemy:GetLevel() or 1) > (bot:GetLevel() or 1))
        or ((mySt or 0) >= 1)
        or ((enemy:GetAttackDamage() or 50) >= (bot:GetAttackDamage() or 50) + 16)
    local twoEn = U.GetEnemyRazeBurstDamage(bot, enemy, 2)
    if not outclassed and myHp >= enHp * 0.84 and myHp > twoEn + 115 and U.GetPotentialManaForRaze(bot) >= 150 then
        return false
    end
    return true
end

-- The enemy raze burst on me. razeCount = nil -> as many as he really has available
-- (by the cooldown tracker + mana, a 2.5 s horizon, accounting for band reach).
function U.GetEnemyRazeBurstDamage(bot, enemy, razeCount)
    if not U.CanQuery(enemy) then return 0 end
    local eq = enemy:GetAbilityByName("nevermore_shadowraze1")
    if not eq or eq:GetLevel() == 0 then return 0 end
    if razeCount == nil then
        if U._K then
            local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
            local dmg = U._K.EnemyBurstVs(bot, enemy, dist, 2.5, false)
            return dmg
        end
        razeCount = 2
    end
    local myStacks = U.GetShadowrazeDebuff(bot) or 0
    local souls = S.GetSouls(enemy)
    local totalDmg = 0
    for i = 1, razeCount do
        local rawDmg = U.GetRazeRawDamage(eq, myStacks + (i - 1), souls)
        totalDmg = totalDmg + bot:GetActualIncomingDamage(rawDmg, DAMAGE_TYPE_MAGICAL)
    end
    return totalDmg
end

function U.HasAnyHealing(bot)
    if bot:HasModifier("modifier_flask_healing") then return true end
    if bot:HasModifier("modifier_tango_heal") then return true end
    if U.HasItem(bot, "item_flask") then return true end
    if U.HasItem(bot, "item_tango") then return true end
    return false
end

function U.IsActivelyHealing(bot)
    if bot:HasModifier("modifier_flask_healing") then return true end
    if bot:HasModifier("modifier_tango_heal") then return true end
    return false
end

function U.IsCourierBringSalve(bot)
    local n = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
    for ci = 0, n - 1 do
        local courier = GetCourier(ci)
        if courier and (not courier.IsNull or not courier:IsNull()) and courier:IsAlive()
            and (not courier.GetTeam or courier:GetTeam() == bot:GetTeam())
            and (type(GetCourierState) ~= "function" or GetCourierState(courier) == COURIER_STATE_DELIVERING_ITEMS) then
            local hasSalve = false
            for i = 0, 8 do
                local okI, item = pcall(courier.GetItemInSlot, courier, i)
                if okI and item and item:GetName() == "item_flask" then
                    hasSalve = true
                    break
                end
            end
            if hasSalve then
                local courierLoc = courier:GetLocation()
                local dist = U.DistanceBetweenLocations(bot:GetLocation(), courierLoc)
                if dist <= C.EMERGENCY.COURIER_SEARCH_RANGE then
                    return true, courierLoc
                end
            end
        end
    end
    return false, nil
end

function U.GetEmergencyRetreatReason(bot, enemyHero)
    local hp = bot:GetHealth()
    if U.HasAnyHealing(bot) then return nil end
    -- NEVER walk back to Fountain while the opposing hero is DEAD (`v5.2.0` + `bot_unbeatable` post-kill stay-in-lane fix!):
    if U._W and U._W.s and U._W.s.enemyAlive == false then return nil end
    -- In 1v1 Solo Mid, losing friendly Mid T1 = instant Ancient destruction (`tk=21442` BAR 9:10 bug!):
    -- NEVER walk away from a low-HP friendly Mid T1 (`<= 420 HP`) while an enemy hero/wave threatens it
    -- unless literally 1 right-click from giving up the winning kill (`hp <= 105`)!
    local ownT1 = (U._W and U._W.s and U._W.s.allyT1) or nil
    if ownT1 and hp > 105 then
        local okA, alive = pcall(ownT1.IsAlive, ownT1)
        local okH, tHp = pcall(ownT1.GetHealth, ownT1)
        local okL, tLoc = pcall(ownT1.GetLocation, ownT1)
        if okA and alive and okH and tHp and tHp <= 420 and okL and tLoc then
            local threatened = (enemyHero and U.CanQuery(enemyHero) and U.DistanceBetweenLocations(tLoc, enemyHero:GetLocation()) <= 1350)
            if not threatened and U._W and U._W.s then
                for _, c in pairs(U._W.s.enemyCreeps or {}) do
                    if U.CanQuery(c) and U.DistanceBetweenLocations(tLoc, c:GetLocation()) <= 1250 then
                        threatened = true
                        break
                    end
                end
            end
            if threatened then return nil end
        end
    end
    local threatAvail, threatBase = 0, 0
    local myStacks, myRemain = U.GetShadowrazeDebuff(bot)
    if enemyHero and U.CanQuery(enemyHero) then
        if U._K then
            local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            threatAvail = U._K.EnemyBurstVs(bot, enemyHero, dist, 2.5, false)
            threatBase = U._K.EnemyBurstVs(bot, enemyHero, dist, 2.5, false, 0)
        else
            threatAvail = U.GetEnemyRazeBurstDamage(bot, enemyHero, 2)
            threatBase = threatAvail
        end
    elseif U._W and U._W.s and U._W.s.enemyAlive ~= false then
        -- `auto-20261031-1939` `07:13` (`tk=16106..16114` at `(2393, 2251)`) Death #2 Root-Cause Fix:
        -- When retreating toward Fountain puts the live enemy SF outside `1600u` vision (`enemyHero == nil`),
        -- NEVER collapse `threatBase` to `0` and wipe `State.emergencyRetreat` behind T2 at `202..225 HP`!
        local alreadyRetreating = (U._State and U._State.emergencyRetreat == "FOUNTAIN") and true or false
        local deepBehindOwnT1 = false
        if ownT1 then
            local okTL, tLoc2 = pcall(ownT1.GetLocation, ownT1)
            if okTL and tLoc2 and GetUnitToLocationDistance(bot, tLoc2) >= 1200 then
                deepBehindOwnT1 = true
            end
        end
        local hpPctFoW = hp / math.max(1, bot:GetMaxHealth())
        if alreadyRetreating or deepBehindOwnT1 or hpPctFoW <= 0.24 then
            local estEnLvl = (U._enemyMaxHpTrack and U._enemyMaxHpTrack.lvl) or (bot:GetLevel() or 1)
            local estRazeTier = (estEnLvl >= 5) and 3 or ((estEnLvl >= 3) and 2 or 1)
            local rawRaze = ({ 85, 150, 215 })[estRazeTier] + 24
            threatBase = bot:GetActualIncomingDamage(rawRaze, DAMAGE_TYPE_MAGICAL)
            threatAvail = threatBase
        end
    end
    local isInKillRange = false
    local hpPct = hp / math.max(1, bot:GetMaxHealth())
    if threatBase > 0 and hp <= threatBase * C.EMERGENCY.SINGLE_RAZE_FACTOR and hpPct <= 0.55 then isInKillRange = true end
    -- Patch 7.41f: `modifier_nevermore_shadowraze_debuff` lasts 6.0s (not 8.0s), so any stack with `> 1.65s` left is live lethal threat!
    if threatAvail > 0 and hp <= threatAvail * C.EMERGENCY.SINGLE_RAZE_FACTOR and (myStacks or 0) > 0 and (myRemain or 0) > 1.65
        and hpPct <= 0.60 then
        isInKillRange = true
    end
    if hp <= C.EMERGENCY.MIN_HP_ABSOLUTE then isInKillRange = true end
    if not isInKillRange then return nil end
    -- NEVER walk 2,500u halfway back to base (`(2508, 58)` at BAR 9:10!) to "meet" a flying courier:
    -- only step to meet the courier when it is ALREADY right behind our T1 (`<= 550u` away)!
    local courierHasSalve, courierLoc = U.IsCourierBringSalve(bot)
    if courierHasSalve and courierLoc then
        local dist = U.DistanceBetweenLocations(bot:GetLocation(), courierLoc)
        if dist <= 550 then
            return "COURIER", courierLoc
        end
    end
    local lvl = bot:GetLevel() or 1
    local goPct = (lvl >= 6) and 0.40 or 0.30
    if hpPct <= goPct or hp <= C.EMERGENCY.MIN_HP_ABSOLUTE then
        if U.EnemyResourcesAsWeak(bot, enemyHero, hpPct) then return nil end
        return "FOUNTAIN", nil
    end
    return nil
end

-- "The enemy has exactly as few resources as we do".
-- True when he cannot kill us with his available burst, his HP% is not above ours (within
-- the margin) and he can pay for no more razes than we can. In that situation a fountain trip is
-- a gift: he takes the wave, the XP and the lane for free.
function U.EnemyResourcesAsWeak(bot, enemy, myHpPct)
    local cfg = C.FOUNTAIN or {}
    if cfg.SYMMETRIC_ENABLE == false then return false end
    if not enemy or not U.CanQuery(enemy) then return false end
    if not U.EnemyHasRaze(enemy) then return false end
    local hpPct = myHpPct or ((bot:GetHealth() or 0) / math.max(1, bot:GetMaxHealth() or 1))
    if hpPct <= (cfg.SYMMETRIC_FLOOR_PCT or 0.12) then return false end
    if (bot:GetHealth() or 0) <= (cfg.SYMMETRIC_MIN_HP or 110) then return false end
    local K = U._K
    local R = K and K._race
    -- we can only stay on a reliable trade calculation: without it we do not know whether he kills us
    if not (R and R.valid) then return false end
    if R.heCanKillSoon then return false end
    local eHpPct = (enemy:GetHealth() or 0) / math.max(1, enemy:GetMaxHealth() or 1)
    if eHpPct > hpPct + (cfg.SYMMETRIC_HP_GAP or 0.10) then return false end
    if K.EnemyRazeBudget(enemy, true) > K.MyRazeBudget(bot, true) then return false end
    return true
end

-- The death threat from the enemy's available burst (cooldown tracker + mana + band reach).
function U.IsInEnemyRazeKillThreat(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local hp = bot:GetHealth()
    if U._K then
        local R = U._K._race
        if R and R.valid then
            return R.heCanKillSoon
        end
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local dmg = U._K.EnemyBurstVs(bot, enemyHero, dist, 2.5, false)
        return dmg > 0 and hp <= dmg
    end
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local threat2 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 2)
    if threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.SINGLE_KILL_FACTOR then return true end
    if threat2 > 0 and hp <= threat2 * SAFE_DISTANCE.KILL_THREAT_FACTOR then return true end
    return false
end

-- Choose a passable endpoint beyond nearby trees. The engine finds the path;
-- passability alone is not a claim that the straight segment is traversable.
function U.GetRetreatWaypoint(bot, direction)
    local origin = bot:GetLocation()
    local fnt = U.GetFountain(bot)
    local toFnt = fnt and (fnt - origin) or direction
    local fntLen = math.sqrt(toFnt.x * toFnt.x + toFnt.y * toFnt.y)
    local fntDir = (fntLen > 1) and Vector(toFnt.x / fntLen, toFnt.y / fntLen, 0) or direction:Normalized()
    local side = Vector(-direction.y, direction.x, 0)
    for _, length in ipairs({900, 1200, 1500, 600}) do
        for _, offset in ipairs({0, 0.4, -0.4, 0.8, -0.8}) do
            local stepVec = (direction + side * offset):Normalized() * length
            local target = origin + stepVec
            local fwd = stepVec.x * fntDir.x + stepVec.y * fntDir.y
            local dirAlign = stepVec.x * direction.x + stepVec.y * direction.y
            if (fwd >= length * 0.25 or dirAlign >= length * 0.70)
                and (type(IsLocationPassable) ~= "function" or IsLocationPassable(target)) then
                return target
            end
        end
    end
    return fnt
end

function U.GetSafeDistancePosition(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return nil end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local hp = bot:GetHealth()
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local isCritical = (threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.CRITICAL_HP_FACTOR)
    local minDist = SAFE_DISTANCE.MIN_DISTANCE_FROM_ENEMY
    if U._K then
        -- outside all his ready bands
        local safe = U._K.EnemyMinSafeDistance(enemyHero, 2.5)
        if safe > minDist then minDist = safe end
    end
    if isCritical then
        minDist = math.max(minDist, SAFE_DISTANCE.MIN_DISTANCE_CRITICAL or 950)
    end
    if dist >= minDist then return nil end
    local fountain = U.GetFountain(bot)
    local away = botLoc - enemyLoc
    if dist < 1 then away = fountain - botLoc end
    away = away:Normalized()
    local toFountain = (fountain - botLoc):Normalized()
    local moveAmount = minDist - dist + 80
    -- Flee strictly AWAY from the enemy. A tilt toward the fountain is allowed only when the fountain
    -- is roughly where we are running anyway (dot > 0.2). Otherwise (the fountain is behind the enemy -
    -- we are cut off) the fountain component pulled the path TOWARD the enemy: the run came out crooked,
    -- a "to the creeps and back" zigzag.
    local dot = away.x * toFountain.x + away.y * toFountain.y
    if dot > 0.2 then
        local awayWeight = isCritical and 0.5 or 0.7
        local fountainWeight = isCritical and 0.5 or 0.3
        local cand = botLoc + away * moveAmount * awayWeight + toFountain * moveAmount * fountainWeight
        if type(IsLocationPassable) ~= "function" or IsLocationPassable(cand) then
            return cand
        end
    end
    return U.GetRetreatWaypoint(bot, away)
end

function U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    if bot:GetMana() < 75 then return false, nil end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false, nil end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and hitLabel ~= "near" then return false, nil end
    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < C.FINISH.MIN_HP_PCT_FOR_CLOSE then return false, nil end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks < C.FINISH.MIN_STACKS_FOR_CLOSE then return false, nil end
    if rem_time <= 0.3 then return false, nil end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or not U.IsRazeAbilityCastable(bot, q) then return false, nil end
    local razeDmg = U.GetRazeRawDamage(q, stacks, S.GetSouls(bot))
    local actualDmg = enemyHero:GetActualIncomingDamage(razeDmg, DAMAGE_TYPE_MAGICAL)
    local enemyHP = enemyHero:GetHealth()
    local atkDmg = bot:GetAttackDamage() or 0
    local actualAtk = enemyHero:GetActualIncomingDamage(atkDmg, DAMAGE_TYPE_PHYSICAL)
    if actualDmg >= enemyHP * 0.85 or (actualDmg + actualAtk) >= enemyHP then
        local botLoc = bot:GetLocation()
        local enemyLoc = enemyHero:GetLocation()
        local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
        if dist <= C.FINISH.CLOSE_APPROACH_RANGE then
            local dir = (enemyLoc - botLoc):Normalized()
            local approachLoc = enemyLoc - dir * C.RAZE.NEAR_CENTER
            return true, approachLoc
        end
    end
    return false, nil
end

function U.ShouldForceSalve(bot)
    if bot:HasModifier("modifier_flask_healing") then return false end
    if bot:HasModifier("modifier_tango_heal") then return false end
    local hpPct = bot:GetHealth() / bot:GetMaxHealth()
    if hpPct > C.FORCED_SALVE.HP_PCT_THRESHOLD then return false end
    local flask = U.GetActiveItemByName(bot, "item_flask")
    if not flask then return false end
    return true
end

U._lastAllyCreepHP = {}

function U.UpdateAllyCreepHealthTracking(allyCreeps)
    local newTracker = {}
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local key = tostring(c)
            newTracker[key] = {
                hp = c:GetHealth(),
                prevHp = (U._lastAllyCreepHP[key] and U._lastAllyCreepHP[key].hp) or c:GetHealth(),
                unit = c,
            }
        end
    end
    U._lastAllyCreepHP = newTracker
end

function U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero)
    if not enemyTowers or #enemyTowers == 0 then return false end
    if not allyCreeps or #allyCreeps == 0 then return false end
    local t1Tower = nil
    for _, tower in pairs(enemyTowers) do
        if tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                t1Tower = tower
                break
            end
        end
    end
    if not t1Tower then
        t1Tower = enemyTowers[1]
        if not t1Tower or not t1Tower:IsAlive() then return false end
    end
    local botDist = GetUnitToLocationDistance(bot, t1Tower:GetLocation())
    if botDist > 1000 then return false end
    -- Source 2 C++ `CDOTA_BaseNPC_Tower` Sticky-Target Law (`9055695956.dem` `6:05` `tk=14088..14460`):
    -- Once `t1Tower:GetAttackTarget()` is ALREADY locked on a live allied creep (`HP >= 145`) OR Siege Catapult (`HP >= 245`
    -- at `827u`, or Glyphed), attacking the tower NEVER pulls aggro onto SF until that current target drops to its last shot!
    if t1Tower.GetAttackTarget and (not t1Tower.CanBeSeen or t1Tower:CanBeSeen()) then
        local okT, tgt = pcall(t1Tower.GetAttackTarget, t1Tower)
        if okT and tgt and tgt ~= bot then
            for _, c in pairs(allyCreeps) do
                if c == tgt and c:IsAlive() then
                    local nm = c:GetUnitName() or ""
                    local isS = nm:find("siege") or nm:find("catapult")
                    local minSafeHp = isS and 245 or 145
                    local glyphed = c.HasModifier and c:HasModifier("modifier_fountain_glyph")
                    if glyphed or (c:GetHealth() or 0) >= minSafeHp then
                        return false
                    end
                end
            end
        end
    end
    local towerAggroRadius = 800
    local allyNearTower = {}
    for _, c in pairs(allyCreeps) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege then
                if GetUnitToLocationDistance(t1Tower, c:GetLocation()) <= towerAggroRadius then
                    table.insert(allyNearTower, c)
                end
            end
        end
    end
    if #allyNearTower == 1 then
        local creep = allyNearTower[1]
        local key = tostring(creep)
        local tracked = U._lastAllyCreepHP[key]
        if tracked then
            if creep:GetHealth() < tracked.prevHp then
                if enemyHero and U.CanQuery(enemyHero) then
                    local twoRazeDmg = U.GetTwoRazeDamage(bot, enemyHero)
                    local atkDmg = bot:GetAttackDamage() or 0
                    local enemyHp = enemyHero:GetHealth()
                    if (twoRazeDmg + atkDmg * 2) >= enemyHp and bot:GetMana() > 150 then
                        return false
                    end
                end
                return true
            end
        end
        if creep:GetHealth() < 200 then
            if enemyHero and U.CanQuery(enemyHero) then
                local twoRazeDmg = U.GetTwoRazeDamage(bot, enemyHero)
                local atkDmg = bot:GetAttackDamage() or 0
                local enemyHp = enemyHero:GetHealth()
                if (twoRazeDmg + atkDmg * 2) >= enemyHp and bot:GetMana() > 150 then
                    return false
                end
            end
            return true
        end
    end
    if #allyNearTower == 0 and botDist < 850 then
        return true
    end
    return false
end

U._lastGlyphTime = -math.huge

function U.IsGlyphAvailable(bot)
    local now = GameTime()
    if now < C.GLYPH.AVAILABLE_AT then return false end
    if GetGlyphCooldown and type(GetGlyphCooldown) == "function" then
        local cd = GetGlyphCooldown()
        if cd and cd > 0 then return false end
    else
        if (now - U._lastGlyphTime) < C.GLYPH.COOLDOWN then return false end
    end
    return true
end

function U.UseGlyph(bot)
    if bot.ActionImmediate_Glyph then
        bot:ActionImmediate_Glyph()
    elseif Glyph then
        Glyph()
    else
        return false
    end
    U._lastGlyphTime = GameTime()
    return true
end

U._allyTowerHpTrack = {}

function U.ShouldUseGlyphDefensive(bot, allyTowers)
    local now = GameTime()
    local snap = U._W and U._W.s or nil
    -- Always update tower HP loss tracking every tick even if Glyph isn't checked below
    for _, tw in pairs(allyTowers or {}) do
        if U.CanQuery(tw) then
            local curH = tw:GetHealth() or 0
            local tr = U._allyTowerHpTrack[tw]
            if not tr or now < (tr.lastAt or 0) then
                tr = { lastHp = curH, damagedAt = -100, lastAt = now }
                U._allyTowerHpTrack[tw] = tr
            else
                if curH < tr.lastHp then
                    tr.damagedAt = now
                end
                tr.lastHp = curH
                tr.lastAt = now
            end
        end
    end
    if not U.IsGlyphAvailable(bot) then return false end
    for _, tower in pairs(allyTowers or {}) do
        if U.CanQuery(tower) then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                local hp = tower:GetHealth()
                local maxHp = math.max(1, tower:GetMaxHealth())
                local hpPct = hp / maxHp
                if hpPct <= C.GLYPH.T1_HP_PCT_THRESHOLD or hp <= C.GLYPH.T1_HP_ABS_THRESHOLD then
                    local projs = U.SafeGetIncomingProjectiles(tower)
                    local tr = U._allyTowerHpTrack[tower]
                    local recentlyLostHp = tr and ((now - (tr.damagedAt or -100)) <= 1.6) or false
                    local isUnderAttack = (projs and #projs > 0) or recentlyLostHp
                    local tLoc = tower:GetLocation()
                    if not isUnderAttack and tLoc then
                        local allyShieldNear, enemyInTowerRange, siegeNear = 0, 0, false
                        if snap then
                            for _, ac in pairs(snap.allyCreeps or {}) do
                                if U.CanQuery(ac) and ac:IsAlive() and U.DistanceBetweenLocations(tLoc, ac:GetLocation()) <= 820 then
                                    allyShieldNear = allyShieldNear + 1
                                end
                            end
                            for _, ec in pairs(snap.enemyCreeps or {}) do
                                if U.CanQuery(ec) and ec:IsAlive() then
                                    local dEc = U.DistanceBetweenLocations(tLoc, ec:GetLocation())
                                    local ecName = ec:GetUnitName() or ""
                                    if dEc <= 850 and (ecName:find("siege") or ecName:find("catapult")) then
                                        siegeNear = true
                                    end
                                    if dEc <= 760 then
                                        enemyInTowerRange = enemyInTowerRange + 1
                                    end
                                end
                            end
                            local heroInRange = snap.enemy and U.CanQuery(snap.enemy) and snap.enemy:IsAlive()
                                and U.DistanceBetweenLocations(tLoc, snap.enemy:GetLocation()) <= 780
                            if heroInRange or siegeNear
                                or (enemyInTowerRange >= 1 and (allyShieldNear == 0 or enemyInTowerRange >= allyShieldNear + 2 or hp <= 360)) then
                                isUnderAttack = true
                            end
                        elseif bot and bot.IsBot and bot:IsBot() and GetUnitToLocationDistance(bot, tLoc) <= 1500 then
                            local okA, nearAllies = pcall(bot.GetNearbyLaneCreeps, bot, 1500, false)
                            if okA and nearAllies then
                                for _, ac in pairs(nearAllies) do
                                    if U.CanQuery(ac) and U.DistanceBetweenLocations(tLoc, ac:GetLocation()) <= 820 then
                                        allyShieldNear = allyShieldNear + 1
                                    end
                                end
                            end
                            local okC, nearbyEnemies = pcall(bot.GetNearbyLaneCreeps, bot, 1500, true)
                            if okC and nearbyEnemies then
                                for _, ec in pairs(nearbyEnemies) do
                                    if U.CanQuery(ec) then
                                        local dEc = U.DistanceBetweenLocations(tLoc, ec:GetLocation())
                                        local ecName = ec:GetUnitName() or ""
                                        if dEc <= 850 and (ecName:find("siege") or ecName:find("catapult")) then
                                            siegeNear = true
                                        end
                                        if dEc <= 760 then
                                            enemyInTowerRange = enemyInTowerRange + 1
                                        end
                                    end
                                end
                            end
                            if siegeNear or (enemyInTowerRange >= 1 and (allyShieldNear == 0 or enemyInTowerRange >= allyShieldNear + 2 or hp <= 360)) then
                                isUnderAttack = true
                            end
                        end
                    end
                    if isUnderAttack then return true end
                end
            end
        end
    end
    return false
end

function U.ShouldUseGlyphForKillDive(bot, enemyHero, enemyTowers, allyTowers, allyCreeps)
    if not U.IsGlyphAvailable(bot) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local twoRazeDmg = U.GetTwoRazeDamage(bot, enemyHero)
    local atkDmg = bot:GetAttackDamage() or 0
    local enemyHp = enemyHero:GetHealth()
    if not ((twoRazeDmg + atkDmg * 2) >= enemyHp and bot:GetMana() >= 150) then
        return false
    end
    -- Only during an ONGOING finish: the burst available right now (ready razes + a hit) kills,
    -- and we are really attacking/aiming at him. "Two razes by formula" on an accidental entry under the tower
    -- (the tower was hitting our creep) burned the glyph without a kill attempt.
    if not (C.GLYPH and C.GLYPH.DIVE_REQUIRE_KILL_NOW == false) then
        local K = U._K
        local R = K and K._race
        if not (R and R.valid and R.canKillNow) then return false end
        local engaged = false
        local okT, tgt = pcall(bot.GetAttackTarget, bot)
        if okT and tgt == enemyHero then engaged = true end
        if not engaged and bot:IsUsingAbility() then engaged = true end
        if not engaged and U._engagedCheck and U._engagedCheck(bot, enemyHero) then engaged = true end
        if not engaged then return false end
    end
    local enemyLoc = enemyHero:GetLocation()
    local t1Tower = nil
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                if GetUnitToLocationDistance(tower, enemyLoc) <= C.GLYPH.KILL_DIVE_RANGE then
                    t1Tower = tower
                    break
                end
            end
        end
    end
    if not t1Tower then return false end
    local hasAllyCreepUnderT1 = false
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            if GetUnitToLocationDistance(t1Tower, c:GetLocation()) <= 750 then
                hasAllyCreepUnderT1 = true
                break
            end
        end
    end
    if not hasAllyCreepUnderT1 then
        return false
    end
    local botDist = GetUnitToLocationDistance(bot, enemyLoc)
    if botDist > 1100 then return false end
    local botUnderTower = false
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot, tower:GetLocation()) <= 880 then
            botUnderTower = true
            break
        end
    end
    if not botUnderTower then return false end
    return true
end



-- Fear the near band (do not close to near distance) if I have stacks and his NEAR raze
-- is ready (tracker) and he has the mana; his near raze must also be significant (>= 25% HP) or
-- the trade must be against me.
function U.HasStackAndShouldFearNear(bot, enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(bot)
    if stacks < 1 then return false end
    if rem_time <= C.RAZE.RETREAT_MIN_REMAIN then return false end
    local K = U._K
    if K then
        if not K.EnemyRazeReady("near", 1.2) then return false end
        if K.EnemyManaBudget(enemy, true) < 75 then return false end
        local oneRaze = K.EnemyRazeDamage(bot, enemy, 1)
        local R = K._race
        local edge = (R and R.valid) and R.edge or 0
        if oneRaze < bot:GetHealth() * 0.25 and edge >= 0 then return false end
        return true
    end
    if not U.EnemyCanUseRaze(enemy) then return false end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemy)
    if stacks == 1 and secondStackActive and hitLabel == "near" then
        return false
    end
    return true
end

function U.GetMinDistWithStack(bot, enemy)
    local fear = U.GetFearMinDist(bot, enemy)
    -- With a fresh stack (and a bad trade) the position is outside ALL his ready bands,
    -- not just outside the near one (see rule 2b in ShouldRetreatFromEnemyRazeStack)
    local K = U._K
    if K and U.CanQuery(enemy) then
        local st, rem = U.GetShadowrazeDebuff(bot)
        if (st or 0) >= 1 and (rem or 0) >= 1.0 then
            local R = K._race
            local favorable = U.IsStackTradeFavorable(bot, R)
            if not favorable then
                local outOfBands = K.EnemyMinSafeDistance(enemy, 1.0)
                if outOfBands > fear then fear = outOfBands end
            end
        end
    end
    if not U.HasStackAndShouldFearNear(bot, enemy) then return fear end
    return math.max(fear, (C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.MIN_DISTANCE) or 470)
end

function U.ClampMinDistFromEnemy(bot, enemy, loc)
    if not enemy or not U.CanQuery(enemy) then return loc end
    local minDist = U.GetMinDistWithStack(bot, enemy)
    -- Level 1-3 Anti-Bullseye Spacing (`0:00` vs `ShaNachnetsya` Theorem):
    -- At `ms = 305` (no Boots), `305 * 0.55s = 167.75u < 250u` — parking idle at `380..545u` in an even/losing lane
    -- puts us inside `Shadowraze2` (`450u`) bullseye. NEVER apply this clamp when enemy `mid` raze is on CD OR when
    -- we hold a decisive trade/kill lead (`edge >= 85`, `hpDiff >= 150`, `canKillSoon`, or `hunting` — otherwise
    -- a winning SF with `305 MS` is blocked from stepping inside its own `500u` attack / `450u` `W` kill range!).
    local K = U._K
    local R = K and K._race
    local midSafe = K and K.BandSafeFromEnemy and K.BandSafeFromEnemy(enemy, "mid", 1.0)
    local soulRightClickLead = K and K.AttackDamageVs and K.EnemyRazeDamage
        and ((enemy:GetMana() or 0) + U.GetMangoMana(enemy)) < 150
        and K.AttackDamageVs(bot, enemy) >= K.AttackDamageVs(enemy, bot) + 12
        and ((bot:GetHealth() or 0) - K.EnemyRazeDamage(bot, enemy, 1)) >= 255
    local pressingLead = (R and R.valid and not R.heCanKillSoon
        and (R.canKillNow or R.canKillSoon or (U._State and U._State.hunting)
            or (R.edge or 0) >= 85 or (R.hpDiff or 0) >= 150))
        or soulRightClickLead
    -- `v3.9.0` Right-Click Reciprocation Window (`4 vs 25` autos fix):
    -- Only hold `568u` anti-`W` spacing when our attack is on cooldown OR we already carry a stack; whenever our
    -- right-click is ready (`dt >= spa * 0.85`) and we are healthy (`>= 68% HP`, `0` stacks), allow `488u` poke reach!
    local atkReadyNow = (GameTime() - (bot:GetLastAttackTime() or -100)) >= ((bot:GetSecondsPerAttack() or 1.6) * 0.85)
    local healthyZeroStack = ((U.GetShadowrazeDebuff(bot) or 0) == 0)
        and ((bot:GetHealth() or 0) >= (bot:GetMaxHealth() or 1) * 0.68)
    local eLocNow = enemy:GetLocation()
    local wouldStepIntoRiver = false
    if loc and eLocNow then
        if type(GetHeightLevel) == "function" then
            wouldStepIntoRiver = (GetHeightLevel(loc) or 0) < (GetHeightLevel(eLocNow) or 0)
        elseif type(GetLocationHeight) == "function" then
            wouldStepIntoRiver = ((GetLocationHeight(loc) or 0) + 50 < (GetLocationHeight(eLocNow) or 0))
        else
            wouldStepIntoRiver = (((loc.z or 0) + 50) < (eLocNow.z or 0))
        end
    end
    local outRazedNow = U.IsOutRazedTier(bot, enemy)
    if (wouldStepIntoRiver or outRazedNow or (not midSafe and not pressingLead and not (atkReadyNow and healthyZeroStack)))
        and U.EnemyHasRaze(enemy) and (enemy:GetMana() or 0) >= 75 and (bot:GetCurrentMovementSpeed() or 305) < 338 then
        minDist = math.max(minDist, 568)
    end
    -- Right-Click Disadvantage Spacing (`R2_2044` `02:38.67..02:44.00` `(-5, 93)` 11-Free-Auto Pacing Fix!):
    -- Even when enemy SF is out of mana (`< 75 MP`), if we are strictly losing the right-click race (`myHp < enHp - 25`
    -- without soul dominance), NEVER let passive lane anchors park inside `enemyAttackRange (500u)` (`182u` face-tank)!
    local myHpNow = bot:GetHealth() or 0
    local enHpNow = enemy:GetHealth() or 999
    local losingDryRightClick = not pressingLead
        and myHpNow < enHpNow - 25
        and not (K and K.AttackDamageVs and K.AttackDamageVs(bot, enemy) >= K.AttackDamageVs(enemy, bot) + 7)
    if losingDryRightClick then
        minDist = math.max(minDist, (enemy:GetAttackRange() or 500) + 105)
    end
    if minDist <= 0 then return loc end
    local enemyLoc = enemy:GetLocation()
    local dist = U.DistanceBetweenLocations(loc, enemyLoc)
    if dist >= minDist then return loc end
    -- CRITICAL VECTOR ORIENTATION LAW (`R2_2044` `03:53..03:56` Triple-Coil Walk-Up & `02:39` 11-Auto Pacing Fix!):
    -- Previously `dir = (loc - enemyLoc):Normalized()` pointed toward RADIANT (`yaw = 216..232 deg`, BEHIND `enemy`!)
    -- whenever `loc` (from creeps behind a forward-zoning enemy SF) lay on the enemy side of `enemyLoc`, making
    -- `ClampMinDistFromEnemy` order SF to run STRAIGHT THROUGH `enemyHero` (`d = 54..221u`)!
    -- Always keep the clamped point strictly in our Fountain hemisphere (`dot(rawDir, homeDir) >= 0.45`)!
    local homeDir = (U.GetFountain(bot) - enemyLoc):Normalized()
    local dir = homeDir
    if dist >= 1 then
        local rawDir = (loc - enemyLoc):Normalized()
        local dot = rawDir.x * homeDir.x + rawDir.y * homeDir.y
        if dot >= 0.45 then
            dir = rawDir
        end
    end
    local pad = (minDist == 568) and 8 or (((C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.RETREAT_BUFFER) or 60))
    return enemyLoc + dir * (minDist + pad)
end

function U.CanOneShotEnemyHero(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    local atkDmg = bot:GetAttackDamage() or 0
    local actualDmg = enemyHero:GetActualIncomingDamage(atkDmg, DAMAGE_TYPE_PHYSICAL)
    if actualDmg >= enemyHero:GetHealth() then
        return true, "ATTACK"
    end
    return false, nil
end

function U.CanKillEnemyWithOneRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    local mana = bot:GetMana() + (U.GetStickCharges(bot) * 15) + U.GetMangoMana(bot)
    if mana < 75 then return false, nil end
    if bot:IsSilenced() or bot:IsStunned() or bot:IsHexed() then return false, nil end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    local candidates = {
        { ability = q, label = "near" },
        { ability = w, label = "mid" },
        { ability = e, label = "far" },
    }

    for _, c in ipairs(candidates) do
        local ability = c.ability
        if ability and ability:GetLevel() > 0 and ability:IsCooldownReady() then
            local willHit = U.WillRazeHit(bot, ability, enemyHero, C.RAZE.CAST_POINT, false)
            local oneRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
            if willHit and oneRazeDmg >= enemyHero:GetHealth() then
                return true, c.label
            end
        end
    end
    return false, nil
end

function U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    local mana = bot:GetMana() + (U.GetStickCharges(bot) * 15) + U.GetMangoMana(bot)
    if mana < 75 then return false, nil end
    if bot:IsSilenced() or bot:IsStunned() or bot:IsHexed() then return false, nil end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    local candidates = {
        { ability = q, label = "near" },
        { ability = w, label = "mid" },
        { ability = e, label = "far" },
    }

    for _, c in ipairs(candidates) do
        local ability = c.ability
        if ability and ability:GetLevel() > 0 and ability:IsCooldownReady() then
            -- Shadow Fiend turn rate in Dota 2 7.41f = `0.9 rad / 0.03s = 51.57 deg/tick` (`180 deg` in `0.105s` = 3 ticks!):
            -- NEVER reject `angleDiff > 115 deg` while kiting (`9056469656.dem` `04:08.5s` & `W6 08:02.0` turn-and-fire `E`!).
            local rawPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
            local angleDiff = U.GetAngleDifference(bot, rawPred)
            local turnDelay = math.max(0, angleDiff - (C.RAZE.MAX_ANGLE_TO_CAST or 8)) / 1547.0
            local castDt = C.RAZE.CAST_POINT + turnDelay
            local _, _, _, errAim = U.WillRazeHit(bot, ability, enemyHero, castDt, false)
            local limit = (C.RAZE.HIT_RADIUS or 250) - (C.RAZE.ROBUST_MARGIN or 30)
            local data = U.GetRazeAbilityData(ability)
            local predImpact = U.PredictPosition(enemyHero, castDt)
            local dNow = U.DistanceBetweenLocations(bot:GetLocation(), enemyHero:GetLocation())
            local enAtkRange = (enemyHero.GetAttackRange and enemyHero:GetAttackRange()) or 525
            -- Stationary-attacker clamp (`9070149539.dem` `tk=9674` & `tk=12312`): an enemy hero already inside
            -- his attack range actively swinging at us (`GetAttackTarget() == bot`) stands planted during windup
            -- instead of continuing to run through us — never false-reject lethal `Raze3` at `495..560u`!
            local plantedOnUs = (enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
                and dNow <= enAtkRange + 25
            local dImpact = data and (plantedOnUs and dNow or U.DistanceBetweenLocations(bot:GetLocation(), predImpact)) or 9999
            local landsCleanOnImpact = data and (math.abs(dImpact - data.center) <= (C.RAZE.HIT_RADIUS or 250) - 24)
            if (errAim and errAim <= limit) or landsCleanOnImpact then
                local oneRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
                if oneRazeDmg >= enemyHero:GetHealth() then
                    return true, c.label
                end
            end
        end
    end
    return false, nil
end

-- Exact `v5.0.0` Unified Patch 7.41f Shadowraze Damage Formula (`85/150/215/280` + `(35/50/65/80 + Lvl10 +30) * stacks` + `2 * souls` * SpellAmp)
function U.GetRazeDamage(bot, ab, stacksOverride)
    if not ab then return 85 end
    local lvl = math.max(1, math.min(4, ab:GetLevel() or 1))
    local base = 0
    if ab.GetSpecialValueInt then
        local ok, v = pcall(ab.GetSpecialValueInt, ab, "shadowraze_damage")
        if ok and type(v) == "number" then base = v end
    end
    local BASE_TBL = (C.RAZE and C.RAZE.BASE_DAMAGE) or { 85, 150, 215, 280 }
    local STACK_TBL = (C.RAZE and C.RAZE.STACK_DAMAGE) or { 35, 50, 65, 80 }
    if base <= 0 then base = BASE_TBL[lvl] or 85 end
    local stackBonus = STACK_TBL[lvl] or 35
    if ab.GetSpecialValueInt then
        local okS, sv = pcall(ab.GetSpecialValueInt, ab, "stack_bonus_damage")
        if okS and type(sv) == "number" and sv > 0 then
            stackBonus = sv
        elseif bot and U.HasRazeStackTalent(bot) then
            stackBonus = stackBonus + ((C.RAZE and C.RAZE.TALENT_STACK_BONUS) or 30)
        end
    elseif bot and U.HasRazeStackTalent(bot) then
        stackBonus = stackBonus + ((C.RAZE and C.RAZE.TALENT_STACK_BONUS) or 30)
    end
    local souls = 0
    if bot and bot.NumModifiers then
        local mc = bot:NumModifiers() or 0
        for i = 0, mc - 1 do
            if bot:GetModifierName(i) == "modifier_nevermore_necromastery" then
                souls = bot:GetModifierStackCount(i) or 0
                break
            end
        end
    end
    local stacks = stacksOverride or 0
    local raw = base + stacks * stackBonus + souls * ((C.RAZE and C.RAZE.DAMAGE_PER_SOUL) or 2)
    return raw * U.GetSpellAmpMult(bot)
end

-- Smooth Analytic Obstacle-Steering Vector Field (`Demo 1` `2:47` & `4:10`, `Demo 2` `7:14` Fix!):
-- Eliminates BOTH:
--   (a) Own/Enemy T1 collision hull pinning (`B=(396,537)` -> `Dire T1=(524,652)`, `T1=172u, vB=0.0` for `1.02s`!), and
--   (b) Head-on allied/enemy creep wave body-blocking during retreats/positioning (`vB=0.0` for `0.60s` = `185u` lost!).
U._towerBypassMem = U._towerBypassMem or {}
U._creepBypassMem = U._creepBypassMem or {}

local function _SegDistSq(ax, ay, bx, by, px, py)
    local vx, vy = bx - ax, by - ay
    local wx, wy = px - ax, py - ay
    local len2 = vx * vx + vy * vy
    if len2 < 1e-6 then return wx * wx + wy * wy, 0.0 end
    local t = (wx * vx + wy * vy) / len2
    if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
    local dx, dy = px - (ax + vx * t), py - (ay + vy * t)
    return dx * dx + dy * dy, t
end

function U.SteerAroundObstacles(bot, rawGoal, s)
    if not bot or not rawGoal then return rawGoal end
    local bLoc = bot:GetLocation()
    if not bLoc then return rawGoal end
    local gx, gy, gz = rawGoal.x, rawGoal.y, rawGoal.z or bLoc.z or 256
    local stepDx, stepDy = gx - bLoc.x, gy - bLoc.y
    local stepLen = math.sqrt(stepDx * stepDx + stepDy * stepDy)
    if stepLen < 55 then return rawGoal end

    local now = (type(GameTime) == "function" and GameTime()) or 0
    local snap = s or (U._W and U._W.s) or nil
    local enemyLoc = (snap and snap.enemy and U.CanQuery(snap.enemy)) and snap.enemy:GetLocation() or nil

    -- 1. Tangential Bypass Around Allied & Enemy T1 Tower Collision Hulls (`R_hull = 168u`, `R_hit = 178u`, `R_bypass = 208u`)
    -- Exact C++ geometry: T1 hull (`144u`) + Hero hull (`24u`) = `168.0u` (`Demo 1` `4:10` stalled at `172.07u` with `dSeg = 0.8u`,
    -- while `DIRE_T1_CLOSE` sits cleanly outside at `210.0u`!). Only steer when path segment actually pierces `< 178u`!
    local ownT1Loc = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1
    if snap and snap.allyT1 and U.CanQuery(snap.allyT1) then
        local okL, tl = pcall(snap.allyT1.GetLocation, snap.allyT1)
        if okL and tl then ownT1Loc = tl end
    end
    local towersToClear = { ownT1Loc }
    if snap and snap.enemyT1Alive ~= false and snap.enemyT1Loc then
        towersToClear[2] = snap.enemyT1Loc
    end

    local mx0, my0 = stepDx / stepLen, stepDy / stepLen
    for ti = 1, #towersToClear do
        local tLoc = towersToClear[ti]
        if tLoc then
            -- Never place destination inside the physical `182u` tower collision cylinder: push it FORWARD along `m`!
            local dgX, dgY = gx - tLoc.x, gy - tLoc.y
            local dg = math.sqrt(dgX * dgX + dgY * dgY)
            if dg < 182 then
                gx = tLoc.x + mx0 * 205
                gy = tLoc.y + my0 * 205
                stepDx, stepDy = gx - bLoc.x, gy - bLoc.y
                stepLen = math.sqrt(stepDx * stepDx + stepDy * stepDy)
                mx0, my0 = stepDx / stepLen, stepDy / stepLen
            end

            -- Exact Euclidean Tangent Bypass around `R = 174u` (`144u` tower + `24u` hero + `6u` skin):
            -- Deflects ONLY by the minimum angle `asin(R/D) - asin(|latT|/D)` needed to graze outside `R = 174u`:
            --   * Head-on T1 (`Demo 1` `4:10`, `D=185, |lat|=0.8`): `~52 deg` instant full-speed slide around T1!
            --   * Offset retreat (`S22`, `D=372, |lat|=83`): `14.9 deg` (`cos=0.966`, `860u` gap in `1.15s`, `0` reversals)!
            local rx, ry = tLoc.x - bLoc.x, tLoc.y - bLoc.y
            local dBotT = math.sqrt(rx * rx + ry * ry)
            local fwdT = rx * mx0 + ry * my0
            local nx0, ny0 = -my0, mx0
            local latT = rx * nx0 + ry * ny0
            local rClear = 174.0
            if dBotT <= 250 and fwdT > 8 and fwdT < stepLen + 15 and dBotT > 20 and math.abs(latT) < rClear then
                local mem = U._towerBypassMem[ti]
                local side = (mem and now >= mem.setAt and now < mem.untilT) and mem.side or nil
                if not side then
                    if math.abs(latT) > 45 then
                        side = (latT > 0) and -1 or 1
                    else
                        local fnt = U.GetFountain(bot)
                        local cLx, cLy = bLoc.x + nx0 * 160, bLoc.y + ny0 * 160
                        local cRx, cRy = bLoc.x - nx0 * 160, bLoc.y - ny0 * 160
                        local sL = -math.sqrt((fnt.x - cLx) ^ 2 + (fnt.y - cLy) ^ 2)
                        local sR = -math.sqrt((fnt.x - cRx) ^ 2 + (fnt.y - cRy) ^ 2)
                        if enemyLoc then
                            sL = sL + math.sqrt((cLx - enemyLoc.x) ^ 2 + (cLy - enemyLoc.y) ^ 2) * 0.25
                            sR = sR + math.sqrt((cRx - enemyLoc.x) ^ 2 + (cRy - enemyLoc.y) ^ 2) * 0.25
                        end
                        side = (sL >= sR) and 1 or -1
                    end
                    U._towerBypassMem[ti] = { side = side, setAt = now, untilT = now + 1.15 }
                end
                local sinNeed = math.min(0.80, rClear / dBotT)
                local sinCurr = math.min(0.79, math.abs(latT) / dBotT)
                local deltaAng = math.max(0.06, math.asin(sinNeed) - math.asin(sinCurr))
                local ca, sa = math.cos(side * deltaAng), math.sin(side * deltaAng)
                local ux = mx0 * ca - my0 * sa
                local uy = mx0 * sa + my0 * ca
                local reach = math.min(stepLen, 240)
                local wp = Vector(bLoc.x + ux * reach, bLoc.y + uy * reach, gz)
                if type(IsLocationPassable) ~= "function" or IsLocationPassable(wp) then
                    return wp
                end
            end
        end
    end
    -- Also return the forward-pushed destination when `dg < 182` shifted `(gx, gy)` clear of the tower hull!
    if math.abs(gx - rawGoal.x) > 1 or math.abs(gy - rawGoal.y) > 1 then
        return Vector(gx, gy, gz)
    end

    -- 2. Smooth Tangential Lane-Creep Corridor Steering on Real Retreats/Transits (`stepLen >= 195u`, `Demo 1` `2:47` Fix!)
    -- Strictly requires `>= 2` clustered creeps blocking the corridor OR active `modifier_flask_healing`, so short lane
    -- last-hit positioning micro-steps (`< 195u`) are 100% untouched!
    local activeSalveNow = bot.HasModifier and bot:HasModifier("modifier_flask_healing")
    if snap and stepLen >= (activeSalveNow and 115 or 205) then
        local mx, my = stepDx / stepLen, stepDy / stepLen
        local lx, ly = -my, mx
        local blockedAhead = 0
        local loadL, loadR = 0.0, 0.0

        local function scanList(list)
            for _, c in pairs(list or {}) do
                if U.CanQuery(c) and c:IsAlive() then
                    local cl = c:GetLocation()
                    local rx, ry = cl.x - bLoc.x, cl.y - bLoc.y
                    local fwd = rx * mx + ry * my
                    local lat = rx * lx + ry * ly
                    if fwd > 4 and fwd < math.min(stepLen - 20, 165) then
                        if math.abs(lat) < 58 then
                            blockedAhead = blockedAhead + 1
                        end
                        if lat >= -20 and lat < 220 then
                            loadL = loadL + (230 - math.abs(lat))
                        end
                        if lat <= 20 and lat > -220 then
                            loadR = loadR + (230 - math.abs(lat))
                        end
                    end
                end
            end
        end
        scanList(snap.allyCreeps)
        scanList(snap.enemyCreeps)

        if blockedAhead >= (activeSalveNow and 1 or 2) then
            local cMem = U._creepBypassMem[1]
            local side = (cMem and now >= cMem.setAt and now < cMem.untilT) and cMem.side or nil
            if not side then
                if enemyLoc then
                    local dL = math.sqrt((bLoc.x + lx * 150 - enemyLoc.x) ^ 2 + (bLoc.y + ly * 150 - enemyLoc.y) ^ 2)
                    local dR = math.sqrt((bLoc.x - lx * 150 - enemyLoc.x) ^ 2 + (bLoc.y - ly * 150 - enemyLoc.y) ^ 2)
                    loadL = loadL - math.min(180, dL * 0.22)
                    loadR = loadR - math.min(180, dR * 0.22)
                end
                side = (loadL <= loadR) and 1 or -1
                U._creepBypassMem[1] = { side = side, setAt = now, untilT = now + 0.50 }
            end
            local fwdStep = math.min(stepLen, 205)
            local latPush = math.min(155, 105 + blockedAhead * 22)
            local steered = Vector(
                bLoc.x + mx * fwdStep + lx * (side * latPush),
                bLoc.y + my * fwdStep + ly * (side * latPush),
                gz
            )
            if type(IsLocationPassable) ~= "function" or IsLocationPassable(steered) then
                return steered
            end
        end
    end

    return Vector(gx, gy, gz)
end

-- `v4.2.0` Strict Raw-Velocity Shadowraze Reach Gate (`Demo 1` `0:44.47` `d = 1050u` Max-Range Miss Fix!):
-- Prevents starting a Shadowraze when a moving-away enemy hero will exit `[center - 232, center + 232]` over `CAST_POINT + 0.08s`
-- under raw un-damped velocity (where `PredictPosition`'s `0.6x` reversal damping previously underestimated retreat by `75u`!).
function U.WillRazeStrictlyCoverMovingTarget(bot, ability, target)
    if not bot or not ability or not target or not U.CanQuery(target) then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data then return false end
    local bLoc = bot:GetLocation()
    local tLoc = target:GetLocation()
    local dNow = U.DistanceBetweenLocations(bLoc, tLoc)
    if dNow < 1 then return data.center <= 235 end

    local vx, vy = 0, 0
    if target.GetVelocity then
        local okV, v = pcall(target.GetVelocity, target)
        if okV and v and v.x then vx, vy = v.x or 0, v.y or 0 end
    end
    local spd = math.sqrt(vx * vx + vy * vy)
    local ax, ay = (tLoc.x - bLoc.x) / dNow, (tLoc.y - bLoc.y) / dNow
    local awaySpd = vx * ax + vy * ay
    local dt = (C.RAZE.CAST_POINT or 0.55) + 0.08
    local rawLand = Vector(tLoc.x + vx * dt, tLoc.y + vy * dt, tLoc.z)
    local dRawLand = U.DistanceBetweenLocations(bLoc, rawLand)

    -- Hard outer/inner kinematic gate: an enemy retreating away at `> 45 u/s` MUST stay strictly inside `center + 224u` (`924u` max)!
    local maxAllowedErr = (awaySpd > 45) and (C.RAZE.HIT_RADIUS - 26) or (C.RAZE.HIT_RADIUS - 12)
    if math.abs(dRawLand - data.center) > maxAllowedErr then
        return false
    end
    return true
end

-- `v4.2.0` Anti-Creep-Sliver Guard for Non-Lethal Hero Coils (`Demo 2` `0:47.67` `86 -> 3 HP` Ranged Creep Fix!):
-- Returns `true` when casting a non-lethal hero harass raze right now would leave an enemy lane creep at `1..32 HP`
-- under allied creep/tower fire during SF's `0.55s` cast animation (gifting the CS away instead of waiting `0.3s` for
-- a clean Dual-Value `Hero + Creep` kill!).
function U.HeroRazeRuinsCreepCS(bot, ability, aimLoc, targetHero, s)
    if not bot or not ability or not targetHero or not U.CanQuery(targetHero) then return false end
    local snap = s or (U._W and U._W.s)
    if not snap or not snap.enemyCreeps or #snap.enemyCreeps == 0 then return false end
    -- Never hold back a lethal/near-lethal hero coil or active multi-stack combo!
    local myOneRaze = U.GetNRazeDamage(bot, targetHero, 1)
    if (targetHero:GetHealth() or 9999) <= myOneRaze * 1.65
        or (U.GetShadowrazeDebuff(targetHero) or 0) >= 1
        or (bot:GetHealth() or 999) <= 280 then
        return false
    end
    local data = U.GetRazeAbilityData(ability)
    if not data then return false end
    local bLoc = bot:GetLocation()
    local ref = aimLoc or targetHero:GetLocation()
    local dx, dy = ref.x - bLoc.x, ref.y - bLoc.y
    local dl = math.sqrt(dx * dx + dy * dy)
    if dl < 1 then return false end
    local cx, cy = bLoc.x + (dx / dl) * data.center, bLoc.y + (dy / dl) * data.center
    local baseDmg = U.GetRazeDamage(bot, ability, 0)
    local hasAlliedFire = (#(snap.allyCreeps or {}) > 0) or (snap.allyT1 ~= nil)
    if not hasAlliedFire then return false end

    for _, c in pairs(snap.enemyCreeps) do
        if U.CanQuery(c) and c:IsAlive() then
            local cl = c:GetLocation()
            if math.sqrt((cl.x - cx) ^ 2 + (cl.y - cy) ^ 2) <= 255 then
                local mDmg = math.floor(c:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL))
                local remHp = (c:GetHealth() or 0) - mDmg
                if remHp > 0 and remHp <= 32 then
                    return true
                end
            end
        end
    end
    return false
end

-- Exact `v4.2.0` First-Kill Time-To-Kill (`TTK_bot < TTK_enemy`) Race Solver
-- Covers:
--   * Close low-HP finishes (`0119` `00:24.83` @ `42 HP` & `05:25.43` @ `90 HP`),
--   * Dominant Soul-Lead / Dry-Mana Enemy Right-Click Duels (`Demo 1` `3:55`: `20` vs `11` souls, `204 HP` vs `212 HP, 36 MP`!),
--   * Multi-Stack `Q->W->E` Combo Finishes (`Demo 2` `7:41`: `enStacks >= 1` 2nd/3rd stack kill!).
function U.SolveLethalRace(bot, enemy, s)
    local NO_WIN = {
        winsFirstKill = false,
        tKillHim = 999,
        tKillMe = 0,
        enDmgBeforeDeath = 99999,
        myEhp = 0,
        marginHp = -99999,
        needEmergencyHeal = false,
    }
    if not bot or not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return NO_WIN end
    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(bLoc, eLoc)
    local atkRange = (bot:GetAttackRange() or 500)
    if d > math.max(atkRange + 165, 935) then return NO_WIN end

    if s and s.enemyTowers then
        local aggroRad = (C.TOWER and C.TOWER.AGGRO_RADIUS) or 868
        for _, tw in pairs(s.enemyTowers) do
            if tw and tw:IsAlive() and GetUnitToLocationDistance(tw, bLoc) < aggroRad then
                local hasShield = false
                for _, ac in pairs(s.allyCreeps or {}) do
                    if U.CanQuery(ac) and ac:IsAlive() and (ac:GetHealth() or 0) > 45
                        and GetUnitToLocationDistance(tw, ac:GetLocation()) < GetUnitToLocationDistance(tw, bLoc) then
                        hasShield = true
                        break
                    end
                end
                if not hasShield and (bot:GetHealth() or 0) < 310 then
                    return NO_WIN
                end
            end
        end
    end

    local Kref = U._K or package.loaded["bots/nevermore/combat"]
    local myHitFactor = ((eLoc.z or 0) - (bLoc.z or 0) >= 90) and 0.75 or 1.0
    local myPhys, enPhys
    if Kref and Kref.AttackDamageVs then
        myPhys = math.max(30, Kref.AttackDamageVs(bot, enemy) * myHitFactor)
        enPhys = math.max(32, Kref.AttackDamageVs(enemy, bot))
    else
        local myRawLo = U.SampleRawDamageRange(bot)
        local _, enRawHi = U.SampleRawDamageRange(enemy)
        myPhys = math.max(30, enemy:GetActualIncomingDamage(myRawLo, DAMAGE_TYPE_PHYSICAL) * myHitFactor)
        enPhys = math.max(32, bot:GetActualIncomingDamage(enRawHi, DAMAGE_TYPE_PHYSICAL))
    end
    local mySpa = math.max(0.45, bot:GetSecondsPerAttack() or 1.25)
    local enSpa = math.max(0.45, enemy:GetSecondsPerAttack() or 1.25)
    local projFlight = d / 1200.0
    local lastAtkDt = GameTime() - (bot:GetLastAttackTime() or -100)
    local firstSwingWait = math.max(0.0, mySpa - lastAtkDt)
    local firstHitT = firstSwingWait + mySpa * 0.34 + projFlight
    if d > atkRange + 20 then
        local ms = math.max(250, bot:GetCurrentMovementSpeed() or 305)
        firstHitT = firstHitT + (d - atkRange) / ms
    end

    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, (bot.GetMaxHealth and bot:GetMaxHealth()) or myHp)
    local faerieHeal = U.GetActiveItemByName(bot, "item_faerie_fire") and 85 or 0
    local stickHeal = 0
    local stickCharges = U.GetStickCharges and U.GetStickCharges(bot) or 0
    if stickCharges > 0 and (U.GetActiveItemByName(bot, "item_magic_stick") or U.GetActiveItemByName(bot, "item_magic_wand")) then
        stickHeal = stickCharges * 15
    end
    local instantHeal = faerieHeal + stickHeal
    local myEffHp = myHp + instantHeal

    local enHp = enemy:GetHealth() or 9999
    local enFaerie = U.GetFaerieFireHeal(enemy)
    local enStick = (U.GetStickCharges and U.GetStickCharges(enemy, false) or 0) * 15
    local enEffHp = enHp + enFaerie + enStick
    local enMana = (enemy:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(enemy) or 0) + enStick
    local enemyIsDry = (enMana < 75)
    local myPhysUnpenalized = myPhys / myHitFactor
    local trueOneShotDry = enemyIsDry and (enEffHp <= myPhysUnpenalized * 1.06)

    local allyDpsOnEnemy = 0
    if s then
        for _, ac in pairs(s.allyCreeps or {}) do
            if U.CanQuery(ac) and ac:IsAlive() and ac.GetAttackTarget and ac:GetAttackTarget() == enemy then
                allyDpsOnEnemy = allyDpsOnEnemy + 11.0
            end
        end
        if s.allyT1 and U.CanQuery(s.allyT1) and s.allyT1:IsAlive()
            and s.allyT1.GetAttackTarget and s.allyT1:GetAttackTarget() == enemy then
            allyDpsOnEnemy = allyDpsOnEnemy + 65.0
        end
    end

    local potMana = (bot:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(bot) or 0) + stickCharges * 15
    local centeredRazeDmg = 0
    local stepBackFarRazeDmg = 0
    local twoBandComboDmg = 0
    local qAb = bot:GetAbilityByName("nevermore_shadowraze1")
    local wAb = bot:GetAbilityByName("nevermore_shadowraze2")
    local eAb = bot:GetAbilityByName("nevermore_shadowraze3")
    local qReady = qAb and qAb:GetLevel() > 0 and qAb:IsCooldownReady() or false
    local wReady = wAb and wAb:GetLevel() > 0 and wAb:IsCooldownReady() or false
    local eReady = eAb and eAb:GetLevel() > 0 and eAb:IsCooldownReady() or false
    if potMana >= 75 and not bot:IsSilenced() then
        for _, spec in ipairs({
            { qReady, 200, "q" },
            { wReady, 450, "w" },
            { eReady, 700, "e" },
        }) do
            if spec[1] then
                if math.abs(d - spec[2]) <= 220 then
                    centeredRazeDmg = math.max(centeredRazeDmg, U.GetNRazeDamage(bot, enemy, 1))
                elseif spec[3] == "e" and d >= 280 and d < 480 then
                    -- Short step-back from `[280..480u] -> 495u` unlocks lethal `Raze3` (`Demo 2` `7:41` 3-stack finish!)
                    stepBackFarRazeDmg = U.GetNRazeDamage(bot, enemy, 1)
                end
            end
        end
        if potMana >= 150 then
            local hasMidFarCombo = wReady and eReady and (d >= 360 and d <= 760)
            local hasNearMidCombo = qReady and wReady and (d >= 130 and d <= 520)
            if hasMidFarCombo or hasNearMidCombo then
                twoBandComboDmg = U.GetNRazeDamage(bot, enemy, 2)
            end
        end
    end

    -- When enemy has `< 75 MP` (`0` coils possible — `Demo 1` `3:55` `36 MP` & `9058240714.dem` `2:04.5` `50 HP`!),
    -- extend reach to `atkRange + 235` for genuine 1-shot finishes (`50 HP` at `600..651u`!) so SF never aborts First Blood!
    local maxRaceHorizon = enemyIsDry and 4.55 or 2.65
    local maxSwings = enemyIsDry and 4 or 3
    local maxAutoReach = trueOneShotDry and (atkRange + 235) or (atkRange + 155)
    local tKillHim = 999
    if d <= maxAutoReach then
        for nHits = 1, maxSwings do
            local tHit = firstHitT + (nHits - 1) * mySpa
            if tHit <= maxRaceHorizon then
                local hitDmg = (nHits == 1 and trueOneShotDry) and myPhysUnpenalized or (nHits * myPhys)
                local dmgTotal = hitDmg + allyDpsOnEnemy * math.max(0, tHit - 0.10)
                if dmgTotal >= enEffHp + (enemy:GetHealthRegen() or 1.5) * tHit then
                    tKillHim = math.min(tKillHim, (nHits == 1 and myHitFactor < 1.0) and (tHit + 0.30 * mySpa) or tHit)
                    break
                end
            end
        end
    end
    if centeredRazeDmg > 0 then
        local tRaze = 0.62
        if centeredRazeDmg + allyDpsOnEnemy * 0.45 >= enEffHp then
            tKillHim = math.min(tKillHim, tRaze)
        elseif twoBandComboDmg > 0 and twoBandComboDmg + allyDpsOnEnemy * 1.1 >= enEffHp + 3 then
            tKillHim = math.min(tKillHim, 1.48)
        elseif d <= atkRange + 120 and centeredRazeDmg + myPhys + allyDpsOnEnemy * 1.0 >= enEffHp + 4 then
            tKillHim = math.min(tKillHim, math.max(tRaze + 0.42, firstHitT))
        elseif d <= atkRange + 95 and centeredRazeDmg + 2 * myPhys >= enEffHp + 6 and (tRaze + 0.40 + mySpa) <= maxRaceHorizon then
            tKillHim = math.min(tKillHim, tRaze + 0.40 + mySpa)
        end
    elseif stepBackFarRazeDmg > 0 then
        local stepTime = math.max(0.10, (495 - d) / math.max(250, bot:GetCurrentMovementSpeed() or 305))
        local tStepRaze = stepTime + 0.62
        if stepBackFarRazeDmg >= enEffHp and tStepRaze <= 1.45 then
            tKillHim = math.min(tKillHim, tStepRaze)
        end
    end

    if tKillHim > maxRaceHorizon then return NO_WIN end

    local window = tKillHim + (enemyIsDry and 0.05 or 0.15)
    -- Exact enemy swing count inside `[0, window]`: includes walk-in time when `d > enAtkRange` (`9069188041.dem` `03:40` `d=695u` Fix!)
    local enHitFactor = ((bLoc.z or 0) - (eLoc.z or 0) >= 90) and 0.75 or 1.0
    local enAtkRange = (enemy.GetAttackRange and enemy:GetAttackRange()) or 525
    local enWalkInT = (d > enAtkRange + 25)
        and ((d - enAtkRange - 15) / math.max(250, (enemy.GetCurrentMovementSpeed and enemy:GetCurrentMovementSpeed()) or 305))
        or 0.0
    local enFirstImpact = enWalkInT + 0.46 + (math.min(d, enAtkRange + 25) / 1200.0)
    local enAutoCount = (window >= enFirstImpact) and (1 + math.floor((window - enFirstImpact) / enSpa)) or 0
    local maxEnemyDmg = enAutoCount * (enPhys * enHitFactor)
    local imminentBurst09s = (enFirstImpact <= 0.90) and (enPhys * enHitFactor) or 0
    if not enemyIsDry then
        if Kref and Kref.EnemyBurstVs then
            -- `EnemyBurstVs` already sums enemy Razes + interwoven right-clicks over `window`
            local burstWin = Kref.EnemyBurstVs(bot, enemy, d, math.max(0.65, window), false)
            maxEnemyDmg = math.max(maxEnemyDmg, burstWin)
            imminentBurst09s = math.max(imminentBurst09s, Kref.EnemyBurstVs(bot, enemy, d, 0.85, false))
        else
            local nCoils = math.min(2, math.floor(enMana / 75))
            local freeAutoT = math.max(0.0, window - nCoils * 0.55)
            local interAutos = (freeAutoT >= enFirstImpact) and (1 + math.floor((freeAutoT - enFirstImpact) / enSpa)) or 0
            maxEnemyDmg = math.max(maxEnemyDmg, nCoils * 145 + interAutos * (enPhys * enHitFactor))
            imminentBurst09s = math.max(imminentBurst09s, 145 + (enPhys * enHitFactor))
        end
    end
    if s then
        local aggroOffCd = GameTime() >= (((U._State and U._State.myCreepAggroCdUntil) or 0) - 0.15)
        local willRightClickHero = (tKillHim > 0.68) and not trueOneShotDry
        for _, ec in pairs(s.enemyCreeps or {}) do
            if U.CanQuery(ec) and ec:IsAlive() then
                if ec.GetAttackTarget and ec:GetAttackTarget() == bot then
                    maxEnemyDmg = maxEnemyDmg + 18.0 * math.max(1.0, window)
                    imminentBurst09s = imminentBurst09s + 15.0
                elseif willRightClickHero and aggroOffCd and GetUnitToLocationDistance(ec, bLoc) <= 520 then
                    -- Source 2 Type 1 protective creep aggro (`500u` trigger, `2.3s` forced chase):
                    -- multi-swing right-click chases trigger every enemy creep within 520u!
                    local cRng = (ec.GetAttackRange and ec:GetAttackRange()) or 100
                    local dc = GetUnitToLocationDistance(ec, bLoc)
                    local walkLag = (dc > cRng + 24) and ((dc - cRng) / 325.0) or 0
                    local activeSec = math.max(0.0, math.min(2.3, window - walkLag))
                    maxEnemyDmg = maxEnemyDmg + 13.5 * activeSec
                end
            end
        end
        if s.enemyT1 and U.CanQuery(s.enemyT1) and s.enemyT1:IsAlive()
            and ((s.enemyT1.GetAttackTarget and s.enemyT1:GetAttackTarget() == bot)
                or (willRightClickHero and GetUnitToLocationDistance(s.enemyT1, bLoc) <= ((C.TOWER and C.TOWER.AGGRO_RADIUS) or 868)
                    and #(s.allyCreeps or {}) == 0)) then
            maxEnemyDmg = maxEnemyDmg + 95.0 * math.ceil(window / 0.85)
            imminentBurst09s = imminentBurst09s + 95.0
        end
    end

    local minMargin = trueOneShotDry and 12 or 20
    local margin = myEffHp - maxEnemyDmg
    if margin >= minMargin then
        -- `9058240714.dem` `1:54.03` Root-Cause Fix:
        -- NEVER burn `item_faerie_fire` (`-2` permanent attack damage!) at `353/758 = 46.6% HP` just because `window = 4.55s`
        -- accumulates 4.5s of future damage! `Faerie Fire` fires ONLY at `<= 15%` max HP OR true `<= 0.85s` imminent lethal!
        local needStickHeal = (stickHeal > 0) and (myHp <= maxEnemyDmg + 38)
        local needFaerieHeal = (faerieHeal > 0) and ((myHp <= math.max(95, myMaxHp * 0.15)) or (myHp <= imminentBurst09s + 22))
        return {
            winsFirstKill = true,
            tKillHim = tKillHim,
            tKillMe = 999,
            enDmgBeforeDeath = maxEnemyDmg,
            myEhp = myEffHp,
            marginHp = margin,
            needStickHeal = needStickHeal,
            needFaerieHeal = needFaerieHeal,
            needEmergencyHeal = needStickHeal or needFaerieHeal,
        }
    end
    return {
        winsFirstKill = false,
        tKillHim = tKillHim,
        tKillMe = window,
        enDmgBeforeDeath = maxEnemyDmg,
        myEhp = myEffHp,
        marginHp = margin,
        needStickHeal = false,
        needFaerieHeal = false,
        needEmergencyHeal = false,
    }
end


U.DEBUG = false


return U
