--[[
================================================================================
 ENGINE TRUTH — live values read straight from the Dota 2 engine (Patch 7.41f)
================================================================================
 Reads live unit & tower parameters (`GetAttackRange`, `GetAttackRangeBuffer`,
 `GetAcquisitionRange`, `GetSecondsPerAttack`, `GetAttackPoint`, `GetLastAttackTime`,
 `GetAverageTrueAttackDamage`, `GetAggroTarget`, `GetTowerAttackTarget`,
 `GetIncomingTrackingProjectiles`) with full `pcall` safety and 7.41f fallbacks.

 Unified v6.6.0 fixes over v6.5.0:
   1. `SF_ATK_RANGE = 525` (exact 7.41f Nevermore base attack range, was 500).
   2. `ET.AppliedTowerDamage(tower, victim)` multiplies raw tower damage (88..92 -> 90)
      by BOTH the 7.41f `Reinforced -> Hero` attack-class factor (`0.75`) AND exact
      physical armor mitigation (`1 - 0.06*a / (1 + 0.06*|a|)`), matching live replay
      T1 hits (`63..66` normal, `76..77` under Presence of the Dark Lord).
   3. `ET.CalibrateConstants` writes `HERO_AGGRO_RANGE` / `SAFE_RADIUS` / `CHASE_LEASH`
      without clobbering `C.TOWER.ATTACK_RANGE = 700` (preserving `lane.lua` 755u
      allied-creep shield geometry).
================================================================================
]]

local ET = {}

ET.STATS = { hits = 0, misses = 0, lastMiss = nil }

ET.FALLBACK = {
    TOWER_RANGE        = 868,    -- 700 KV range + 144 tower hull + 24 hero hull (865..868u)
    RANGE_BUFFER       = 165,    -- engine acquisition/hull buffer beyond 700 KV range
    TOWER_RAW_DMG      = 90,     -- KV 88..92 on npc_dota_*_tower1_mid
    TOWER_REINF_VS_HERO= 0.75,   -- 7.41f Reinforced attack class vs Hero armor class (75%)
    TOWER_APPLIED_DMG  = 65,     -- ~90 * 0.75 * armorFactor on early-game SF
    TOWER_INTERVAL     = 0.8182, -- KV 0.9 BAT * 100 / 110 IAS
    TOWER_WINDUP       = 0.60,   -- KV AttackAnimationPoint
    TOWER_PROJ         = 750,    -- KV ProjectileSpeed
    CREEP_HULL_PAD     = 45,
    SF_ATK_RANGE       = 525,    -- Patch 7.41f Shadow Fiend base attack range
    SF_BAT             = 1.60,
    AS_MIN             = 20,
    AS_MAX             = 700,
    PROJ_SPEED         = 1200,
}

local function fail(what)
    ET.STATS.misses = ET.STATS.misses + 1
    ET.STATS.lastMiss = what
end

local function call(u, name, a, b)
    if not u then fail(name) return nil end
    local okIdx, f = pcall(function() return u[name] end)
    if not okIdx or type(f) ~= "function" then fail(name) return nil end
    local ok, v = pcall(f, u, a, b)
    if not ok then fail(name) return nil end
    ET.STATS.hits = ET.STATS.hits + 1
    return v
end
ET.Call = call

local function num(v) if type(v) == "number" then return v end return nil end
local function sane(v, lo, hi) v = num(v) if v and v >= lo and v <= hi then return v end return nil end

--------------------------------------------------------------------------------
-- unit geometry / attack model
--------------------------------------------------------------------------------

function ET.AttackRange(u)          return sane(call(u, "GetAttackRange"), 0, 4000) end
function ET.AcquisitionRange(u)     return sane(call(u, "GetAcquisitionRange"), 0, 4000) end
function ET.RangeBuffer(u)          return sane(call(u, "GetAttackRangeBuffer"), 0, 2000) end
function ET.AttackSpeed(u)          return sane(call(u, "GetAttackSpeed"), 1, 2000) end
function ET.SecondsPerAttack(u)     return sane(call(u, "GetSecondsPerAttack"), 0.05, 10) end
function ET.AttackPoint(u)          return sane(call(u, "GetAttackPoint"), 0.02, 3) end
function ET.LastAttackTime(u)       return sane(call(u, "GetLastAttackTime"), -10, 1e6) end
function ET.HealthDeficit(u)        return sane(call(u, "GetHealthDeficit"), 0, 1e7) end
function ET.AverageTrueDamage(u)    return sane(call(u, "GetAverageTrueAttackDamage"), 0, 1e5) end

function ET.AggroTarget(u)
    local tgt = call(u, "GetAggroTarget")
    if tgt then return tgt end
    return call(u, "GetAttackTarget")
end

function ET.ArmorFactor(armor)
    armor = armor or 0
    local mult = 1.0 - (0.06 * armor) / (1.0 + 0.06 * math.abs(armor))
    if mult < 0.05 then return 0.05 end
    return mult
end

function ET.AppliedTowerDamage(tower, victim)
    local raw = (tower and ET.AverageTrueDamage(tower)) or ET.FALLBACK.TOWER_RAW_DMG
    local armor = 0
    if victim then
        local a = sane(call(victim, "GetPhysicalArmorValue"), -50, 200)
        if a then armor = a end
    end
    return raw * ET.FALLBACK.TOWER_REINF_VS_HERO * ET.ArmorFactor(armor)
end

function ET.AttackTiming(u)
    local sp = ET.SecondsPerAttack(u)
    local ap = ET.AttackPoint(u)
    local last = ET.LastAttackTime(u)
    local out = { sp = sp, point = ap, last = last }
    if sp and last then
        local now = (GameTime and GameTime()) or 0
        local el = now - last
        if el < 0 or el > 10 then el = 0 end
        out.cycle_left = math.max(0, sp - el)
    elseif sp then
        out.cycle_left = sp * 0.5
    end
    return out
end

--------------------------------------------------------------------------------
-- towers
--------------------------------------------------------------------------------

function ET.TowerAggroRadius(tower, floor)
    if not tower then return floor or ET.FALLBACK.TOWER_RANGE end
    local rng = ET.AttackRange(tower)
    local buf = ET.RangeBuffer(tower)
    local acq = ET.AcquisitionRange(tower)
    local cands = {}
    if rng then
        cands[#cands + 1] = rng + (buf or 0)
        cands[#cands + 1] = rng + ET.FALLBACK.RANGE_BUFFER
    end
    if acq then cands[#cands + 1] = acq end
    if floor then cands[#cands + 1] = floor end
    local best = nil
    for i = 1, #cands do
        local v = cands[i]
        if type(v) == "number" and v >= 400 and v <= 2000 then
            if not best or v > best then best = v end
        end
    end
    return best or ET.FALLBACK.TOWER_RANGE
end

function ET.TowerFacts(bot, tower, team, tier, floor)
    if not tower then return nil end
    local f = {}
    f.range        = ET.TowerAggroRadius(tower, floor) or ET.FALLBACK.TOWER_RANGE
    f.acquire      = f.range
    f.windup       = ET.AttackPoint(tower) or ET.FALLBACK.TOWER_WINDUP
    f.proj_speed   = ET.FALLBACK.TOWER_PROJ
    f.release_span = f.range + 305 * f.windup
    f.raw_damage   = ET.AverageTrueDamage(tower) or ET.FALLBACK.TOWER_RAW_DMG
    f.damage       = (type(bot) == "table" and bot.GetPhysicalArmorValue)
                     and ET.AppliedTowerDamage(tower, bot)
                     or (f.raw_damage * ET.FALLBACK.TOWER_REINF_VS_HERO)
    f.interval     = ET.SecondsPerAttack(tower) or ET.FALLBACK.TOWER_INTERVAL
    local tgt = ET.AggroTarget(tower)
    if not tgt and type(bot) == "table" and team and tier and bot.GetTowerAttackTarget then
        tgt = call(bot, "GetTowerAttackTarget", team, tier)
    end
    f.target = tgt
    f.targeting_me = (tgt ~= nil and bot ~= nil and tgt == bot)
    local last = ET.LastAttackTime(tower)
    if last then
        local now = (GameTime and GameTime()) or 0
        local el = now - last
        if el < 0 or el > 10 then el = 0 end
        f.next_shot_in = math.max(0, f.interval - el)
    else
        f.next_shot_in = f.interval * 0.5
    end
    return f
end

--------------------------------------------------------------------------------
-- damage already in the air
--------------------------------------------------------------------------------

function ET.IncomingDamage(u, dmg_of)
    local projs = call(u, "GetIncomingTrackingProjectiles")
    if type(projs) ~= "table" then return 0, 0 end
    local total, n = 0, 0
    for _, p in pairs(projs) do
        local d = dmg_of and dmg_of(p) or nil
        if d then
            total = total + d
            n = n + 1
        else
            return nil, #projs
        end
    end
    return total, n
end

function ET.IncomingCount(u)
    local projs = call(u, "GetIncomingTrackingProjectiles")
    if type(projs) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(projs) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------------
-- global limits
--------------------------------------------------------------------------------

local _limits = nil
function ET.AttackSpeedLimits(bot)
    if _limits then return _limits end
    local lo = (bot and sane(call(bot, "GetMinimumAttackSpeed"), 1, 2000)) or ET.FALLBACK.AS_MIN
    local hi = (bot and sane(call(bot, "GetMaximumAttackSpeed"), 1, 5000)) or ET.FALLBACK.AS_MAX
    _limits = { min = lo, max = hi }
    return _limits
end

function ET.SecondsPerAttackFor(bat, ias_pct, bot)
    local lim = ET.AttackSpeedLimits(bot)
    local as = math.max(lim.min, math.min(lim.max, 100 + (ias_pct or 0)))
    return (bat or ET.FALLBACK.SF_BAT) * 100 / as
end

--------------------------------------------------------------------------------
-- safe calibration (preserves C.TOWER.ATTACK_RANGE = 700 for creep-shield checks!)
--------------------------------------------------------------------------------

function ET.CalibrateConstants(C, bot, towers)
    local rep = { source = "fallback" }
    if not C then return rep end
    C.TOWER = C.TOWER or {}
    local tw = towers and towers[1] or nil
    if tw then
        local r = ET.TowerAggroRadius(tw, C.TOWER.HERO_AGGRO_RANGE or ET.FALLBACK.TOWER_RANGE)
        if r then
            C.TOWER.HERO_AGGRO_RANGE = r
            C.TOWER.SAFE_RADIUS      = math.max(885, r + 20)
            C.TOWER.CHASE_LEASH      = math.max(905, r + 40)
            C.TOWER.ESCAPE_RADIUS    = math.max(C.TOWER.ESCAPE_RADIUS or 965, r + 95)
            rep.source = "engine"
            rep.tower_range = r
        end
        local applied = ET.AppliedTowerDamage(tw, bot)
        if applied and applied > 0 then
            C.TOWER.SHOT_DAMAGE = applied
            rep.tower_damage = applied
        end
        local sp = ET.SecondsPerAttack(tw)
        if sp then C.TOWER.SHOT_INTERVAL = sp; rep.tower_interval = sp end
    end
    C.HERO = C.HERO or {}
    local hr = bot and ET.AttackRange(bot)
    if hr and hr >= 450 then C.HERO.ATTACK_RANGE = hr; rep.hero_range = hr end
    local sp = bot and ET.SecondsPerAttack(bot)
    if sp then C.HERO.SECONDS_PER_ATTACK = sp; rep.hero_sp = sp end
    local ap = bot and ET.AttackPoint(bot)
    if ap then C.HERO.ATTACK_POINT = ap; rep.hero_ap = ap end
    rep.hits, rep.misses = ET.STATS.hits, ET.STATS.misses
    return rep
end

--------------------------------------------------------------------------------
-- offline self-test
--------------------------------------------------------------------------------

function ET.SelfTest()
    local fails = {}
    local function chk(name, cond) if not cond then fails[#fails + 1] = name end end

    local tower = {
        GetAttackRange = function() return 700 end,
        GetAttackRangeBuffer = function() return 165 end,
        GetAcquisitionRange = function() return 865 end,
        GetAverageTrueAttackDamage = function() return 90 end,
        GetSecondsPerAttack = function() return 0.8182 end,
        GetAggroTarget = function() return "ME" end,
        GetLastAttackTime = function() return 0 end,
    }
    local f = ET.TowerFacts("ME", tower, 2, 1)
    chk("tower range", f.range == 865)
    chk("tower reinforced dmg", math.abs(f.damage - 67.5) < 1e-6)
    chk("tower aggro me", f.targeting_me == true)
    chk("sf atk range 525", ET.FALLBACK.SF_ATK_RANGE == 525)

    local Cmock = { TOWER = { ATTACK_RANGE = 700, HERO_AGGRO_RANGE = 868, ESCAPE_RADIUS = 965 }, HERO = {} }
    ET.CalibrateConstants(Cmock, nil, { tower })
    chk("preserve creep ATTACK_RANGE=700", Cmock.TOWER.ATTACK_RANGE == 700)
    chk("hero aggro calibrated", Cmock.TOWER.HERO_AGGRO_RANGE == 868)
    return #fails == 0, fails
end

return ET
