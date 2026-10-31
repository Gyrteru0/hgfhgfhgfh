--[[
================================================================================
 WAR CORE v1.1 (Patch 7.41f Exact) — Predictive Duel Simulator for SF 1v1 Mid
================================================================================
 Pure Lua 5.1 forward simulator (zero Dota API calls).

 Unified v6.6.0 fixes over v6.5.0:
   1. Exact Patch 7.41f constants:
        RAZE_BASE      = { 85, 150, 215, 280 }
        RAZE_STACK     = { 35, 50, 65, 80 }
        STACK_DURATION = 6.0s (7.41e/f debuff duration)
        ATK_RANGE      = 525u
        TOWER_DMG      = 65 post-class/armor fallback
   2. Emergency burst heal (`faerie` +85 HP, `stick_charges` * 15 HP/MP) simulated
      accurately on both heroes (`9068560663.dem` 01:53 fix).
   3. Fixed undeclared global `worstPlan` leak in `WAR.Evaluate`.
================================================================================
]]

local WAR = {}

local C = {
    DT              = 1.0 / 30.0,

    RAZE_MANA       = 75,
    RAZE_CD         = 9.0,
    RAZE_CAST       = 0.55,
    RAZE_DIST       = { 200, 450, 700 },
    RAZE_RADIUS     = 250,
    RAZE_BASE       = { 85, 150, 215, 280 },
    RAZE_STACK      = { 35, 50, 65, 80 },
    RAZE_PER_SOUL   = 2,
    STACK_DURATION  = 6.0,
    MAX_STACKS      = 4,

    ATK_RANGE       = 525,
    ATK_POINT       = 0.50,
    PROJ_SPEED      = 1200,
    BAT             = 1.60,
    TURN_RATE       = 5.0,
    MAGIC_RESIST    = 0.25,

    TOWER_RANGE     = 868,
    TOWER_LEASH     = 1080,
    TOWER_DMG       = 65,
    TOWER_INTERVAL  = 0.8182,
    TOWER_WINDUP    = 0.60,
    TOWER_PROJECTILE= 750,
    TOWER_FIRST     = 0.35,

    HORIZON         = 3.4,
    INCOMING_LAND   = 0.18,

    CREEP = {
        melee  = { dmg = 21.0, bat = 1.0, range = 100, proj = 0,    hp = 550 },
        ranged = { dmg = 23.5, bat = 1.0, range = 500, proj = 900,  hp = 300 },
        siege  = { dmg = 40.5, bat = 3.0, range = 690, proj = 1100, hp = 935 },
        flag   = { dmg = 21.0, bat = 1.0, range = 100, proj = 0,    hp = 550 },
        HULL_PAD = 45,
    },

    W_HP            = 1.0,
    W_MANA          = 0.28,
    W_TOWER         = 0.0,
    W_STAND         = 0.45,
    DEATH_COST      = 1.0e6,
    KILL_BONUS      = 3.2e5,
    SAFE_HP_ABS     = 105,
}
WAR.C = C

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function distance(ax, ay, bx, by) local dx, dy = ax - bx, ay - by return math.sqrt(dx * dx + dy * dy) end

WAR.clamp = clamp
WAR.dist = distance

--------------------------------------------------------------------------------
-- damage model (Patch 7.41f exact)
--------------------------------------------------------------------------------
function WAR.RazeDamage(level, stacks, souls, stackTalent)
    level = clamp(level or 1, 1, 4)
    local d = C.RAZE_BASE[level]
    d = d + (stacks or 0) * (C.RAZE_STACK[level] + (stackTalent or 0))
    d = d + (souls or 0) * C.RAZE_PER_SOUL
    return d
end

function WAR.RazeApplied(level, stacks, souls, mr, stackTalent)
    mr = mr or C.MAGIC_RESIST
    return WAR.RazeDamage(level, stacks, souls, stackTalent) * (1.0 - mr)
end

function WAR.VolleyDamage(level, stacks, souls, n, mr, stackTalent)
    local total, st = 0, stacks or 0
    for _ = 1, (n or 0) do
        total = total + WAR.RazeApplied(level, st, souls, mr, stackTalent)
        st = math.min(C.MAX_STACKS, st + 1)
    end
    return total
end

--------------------------------------------------------------------------------
-- unit normalisation & emergency burst consumables
--------------------------------------------------------------------------------
function WAR.Prep(u)
    u = u or {}
    u.hp = u.hp or 1
    u.hp_max = u.hp_max or u.hp
    u.mana = u.mana or 0
    u.dmg = u.dmg or 0
    u.souls = u.souls or 0
    u.raze_level = u.raze_level or 0
    u.stack_talent = u.stack_talent or 0
    u.raze_ready = u.raze_ready or { 0, 0, 0 }
    u.atk_range = u.atk_range or C.ATK_RANGE
    u.atk_ready = u.atk_ready or 0
    u.ms = u.ms or 305
    u.regen_hp = u.regen_hp or 0
    u.regen_mana = u.regen_mana or 0
    u.magic_resist = u.magic_resist or C.MAGIC_RESIST
    u.alive = (u.alive ~= false)
    u.stacks = u.stacks or 0
    u.stack_t = u.stack_t or -1e9
    u.facing = u.facing or 0
    u.cast_until = u.cast_until or -1
    u.aim_x, u.aim_y = u.aim_x, u.aim_y
    u.atk_until = u.atk_until or -1
    u.proj = {}
    u.incoming = u.incoming or 0
    u.incoming_at = u.incoming_at or C.INCOMING_LAND
    u.pending_raze = nil
    u.stick_charges = u.stick_charges or 0
    u.mango = u.mango and true or false
    u.faerie = u.faerie and true or false
    u.faerie_used = false
    u.stick_used = false
    u.mango_used = false
    return u
end

local function try_emergency_heal(u)
    if not u.alive then return end
    if u.stick_charges and u.stick_charges > 0 and not u.stick_used and u.hp <= u.hp_max * 0.30 then
        local gain = u.stick_charges * 15
        u.hp = math.min(u.hp_max, u.hp + gain)
        u.mana = u.mana + gain
        u.stick_used = true
    end
    if u.faerie and not u.faerie_used and u.hp <= math.max(110, u.hp_max * 0.22) then
        u.hp = math.min(u.hp_max, u.hp + 85)
        u.faerie_used = true
    end
end

local function apply_damage(victim, dmg, now)
    if not victim or not victim.alive or dmg <= 0 then return end
    victim.hp = victim.hp - dmg
    victim.hp_taken = (victim.hp_taken or 0) + dmg
    if victim.hp <= 0 then
        -- Pop unused Faerie/Stick right BEFORE lethal hit (mirrors emergency consumable reflex!)
        if victim.stick_charges and victim.stick_charges > 0 and not victim.stick_used then
            local gain = victim.stick_charges * 15
            victim.hp = victim.hp + gain
            victim.mana = victim.mana + gain
            victim.stick_used = true
        end
        if victim.hp <= 0 and victim.faerie and not victim.faerie_used then
            victim.hp = victim.hp + 85
            victim.faerie_used = true
        end
    end
    if victim.hp <= 0 then
        victim.hp = 0
        victim.alive = false
        victim.died_at = now
    else
        try_emergency_heal(victim)
    end
end

local function clone_unit(u)
    local c = {}
    for k, v in pairs(u) do
        if k == "proj" or k == "pending_raze" or k == "pending_attack" then
            -- re-initialised below
        elseif type(v) == "table" then
            if k == "raze_ready" then c[k] = { v[1] or 0, v[2] or 0, v[3] or 0 }
            else local n = {} for kk, vv in pairs(v) do n[kk] = vv end c[k] = n end
        else
            c[k] = v
        end
    end
    c.proj = {}
    c.pending_raze = nil
    c.pending_attack = nil
    return c
end

local function clone_plan(p)
    local c = {}
    for k, v in pairs(p or {}) do c[k] = v end
    return c
end

--------------------------------------------------------------------------------
-- readiness
--------------------------------------------------------------------------------
function WAR.Affordable(u, _now)
    local mana = u.mana or 0
    if not u.stick_used then mana = mana + (u.stick_charges or 0) * 15 end
    if u.mango and not u.mango_used then mana = mana + 100 end
    return math.floor((mana + (u.regen_mana or 0) * 1.0) / C.RAZE_MANA)
end

function WAR.ReadyCount(u, now)
    local n = 0
    for i = 1, 3 do if (u.raze_ready[i] or 0) <= now then n = n + 1 end end
    local budget = WAR.Affordable(u, now)
    if n > budget then n = budget end
    return n
end

function WAR.ReadyLabels(u, now, horizon)
    local out = {}
    for i = 1, 3 do
        if (u.raze_ready[i] or 0) <= now + (horizon or 0) then out[#out + 1] = i end
    end
    return out
end

function WAR.Burst(attacker, victim, horizon, now, opts)
    if not attacker or (attacker.raze_level or 0) <= 0 then return 0, 0 end
    now = now or 0
    local n = 0
    for i = 1, 3 do
        if (attacker.raze_ready[i] or 0) <= now + horizon then n = n + 1 end
    end
    local budget = WAR.Affordable(attacker, now)
    if budget < n then n = budget end
    if n > 3 then n = 3 end
    if opts and opts.max and n > opts.max then n = opts.max end
    if not victim or n <= 0 then return 0, n end
    local total, st = 0, victim.stacks or 0
    local lvl = attacker.raze_level
    local mr = victim.magic_resist or C.MAGIC_RESIST
    for _ = 1, n do
        total = total + WAR.RazeApplied(lvl, st, attacker.souls, mr, attacker.stack_talent)
        st = math.min(C.MAX_STACKS, st + 1)
    end
    return total, n
end

--------------------------------------------------------------------------------
-- aiming & step simulation
--------------------------------------------------------------------------------
function WAR.FindShot(u, foe, now, minQuality)
    if (u.raze_level or 0) <= 0 or not foe or not foe.alive then return nil end
    local effMana = (u.mana or 0) + ((u.mango and not u.mango_used) and 100 or 0)
        + ((not u.stick_used) and ((u.stick_charges or 0) * 15) or 0)
    if effMana < C.RAZE_MANA then return nil end

    local locked = (foe.atk_until and foe.atk_until > now) or (foe.cast_until and foe.cast_until > now)
    local lockTime = 0
    if foe.atk_until and foe.atk_until > now then lockTime = foe.atk_until - now end
    if foe.cast_until and foe.cast_until > now then lockTime = math.max(lockTime, foe.cast_until - now) end
    local escape = locked and math.max(0, (foe.ms or 305) * math.max(0, C.RAZE_CAST - lockTime))
                           or ((foe.ms or 305) * C.RAZE_CAST)

    local tx = foe.x + (foe.vx or 0) * C.RAZE_CAST
    local ty = foe.y + (foe.vy or 0) * C.RAZE_CAST
    local dd = distance(u.x, u.y, tx, ty)

    local best, bestSlack = nil, -1e9
    for i = 1, 3 do
        if (u.raze_ready[i] or 0) <= now then
            local err = math.abs(dd - C.RAZE_DIST[i])
            local slack = (C.RAZE_RADIUS - 18) - err - escape
            if slack > bestSlack then
                best, bestSlack = i, slack
            end
        end
    end
    if not best then return nil end
    local quality = "poor"
    if locked and bestSlack > -180 then quality = "lock" end
    if bestSlack >= 0 then quality = locked and "lock" or "solid" end
    if bestSlack >= 60 then quality = "clean" end
    minQuality = minQuality or "solid"
    local rank = { poor = 0, solid = 1, lock = 2, clean = 3 }
    if rank[quality] < rank[minQuality] then return nil, bestSlack, quality end
    return best, bestSlack, quality
end

local function start_attack(u, tgt, now)
    local d = distance(u.x, u.y, tgt.x, tgt.y)
    if d > (u.atk_range or C.ATK_RANGE) + 25 then return false end
    if u.atk_ready > now or u.cast_until > now then return false end
    if u.pending_attack then return false end
    u.atk_until = now + C.ATK_POINT
    u.pending_attack = {
        t = now + C.ATK_POINT, dmg = u.dmg, target = tgt,
        ready = now + math.max(0.85, C.BAT * 0.78),
    }
    return true
end

local function resolve_pending_attack(u, now)
    local a = u.pending_attack
    if not a or a.t > now then return end
    u.pending_attack = nil
    u.atk_ready = a.ready
    local t = a.target
    if not t or not t.alive then return end
    local d = distance(u.x, u.y, t.x, t.y)
    u.proj[#u.proj + 1] = { t = now + d / C.PROJ_SPEED, dmg = a.dmg, target = t }
end

local function cancel_attack(u)
    if u.pending_attack then
        u.pending_attack = nil
        u.atk_until = -1
        return true
    end
    return false
end

local function apply_projectiles(u, now)
    local keep = {}
    for i = 1, #u.proj do
        local p = u.proj[i]
        if p.t <= now then
            apply_damage(p.target, p.dmg, now)
        else
            keep[#keep + 1] = p
        end
    end
    u.proj = keep
end

local function resolve_raze(u, now)
    local p = u.pending_raze
    if not p or p.t > now then return end
    u.pending_raze = nil
    local tgt = p.target
    if not tgt or not tgt.alive then return end
    local d = C.RAZE_DIST[p.idx]
    local cx = u.x + math.cos(u.facing) * d
    local cy = u.y + math.sin(u.facing) * d
    if distance(cx, cy, tgt.x, tgt.y) <= C.RAZE_RADIUS then
        apply_damage(tgt, p.dmg, now)
        tgt.stacks = math.min(C.MAX_STACKS, (tgt.stacks or 0) + 1)
        tgt.stack_t = now
        tgt.last_raze_hit_at = now
        tgt.hit_by_raze = (tgt.hit_by_raze or 0) + 1
    else
        u.raze_missed = (u.raze_missed or 0) + 1
    end
end

local function step_toward(u, gx, gy, dt, now)
    if not u.alive then return end
    if u.cast_until > now then return end
    if u.atk_until and u.atk_until > now then return end
    local d = distance(u.x, u.y, gx, gy)
    if d < 2 then return end
    local step = math.min(d, u.ms * dt)
    local nx, ny = (gx - u.x) / d, (gy - u.y) / d
    u.x = u.x + nx * step
    u.y = u.y + ny * step
    u.vx, u.vy = nx * u.ms, ny * u.ms
    if u.atk_until <= now then u.facing = math.atan2(ny, nx) end
end

local function control(u, foe, plan, now, dt)
    if not u.alive then return "dead" end

    local hold = plan.hold_dist or 440
    local pol = plan.raze_policy or "none"
    local attackOn = plan.attack ~= false
    if plan.adaptive and foe and foe.alive then
        local foeEff = foe.hp + ((foe.faerie and not foe.faerie_used) and 85 or 0)
        local myEff = u.hp + ((u.faerie and not u.faerie_used) and 85 or 0)
        local canFinish = (WAR.Burst(u, foe, 1.6, now) + u.dmg * 2) >= foeEff
        local inDanger = (WAR.Burst(foe, u, 1.6, now) + foe.dmg * 2) >= myEff
        if canFinish then
            hold = math.min(hold, 260)
            pol = "burst"
            attackOn = true
        elseif inDanger and plan.punish_danger ~= false then
            hold = math.max(hold, 620)
        end
    end

    if u.cast_until > now then
        if u.aim_x and u.aim_y then
            local want = math.atan2(u.aim_y - u.y, u.aim_x - u.x)
            local diff = want - u.facing
            while diff > math.pi do diff = diff - 2 * math.pi end
            while diff < -math.pi do diff = diff + 2 * math.pi end
            local maxTurn = C.TURN_RATE * dt
            u.facing = u.facing + clamp(diff, -maxTurn, maxTurn)
        end
        return "casting"
    end

    local d = foe and foe.alive and distance(u.x, u.y, foe.x, foe.y) or 1e9

    if plan.dodge ~= false and foe and foe.alive and foe.cast_until > now and foe.cast_label then
        local bandD = C.RAZE_DIST[foe.cast_label] or 450
        local cx = foe.x + math.cos(foe.facing) * bandD
        local cy = foe.y + math.sin(foe.facing) * bandD
        local dc = distance(u.x, u.y, cx, cy)
        if dc <= C.RAZE_RADIUS + 15 then
            if plan.cancel_dodge ~= false then cancel_attack(u) end
            local rx, ry = u.x - cx, u.y - cy
            local rl = math.sqrt(rx * rx + ry * ry)
            if rl < 1e-3 then rx, ry, rl = 1, 0, 1 end
            step_toward(u, u.x + (rx / rl) * 180, u.y + (ry / rl) * 180, dt, now)
            return "dodge"
        end
    end

    local want, quality = false, nil
    if pol == "burst" then
        want, quality = true, (plan.raze_quality or "solid")
    elseif pol == "single" then
        want, quality = (now - (u.last_volley_at or -1e9) > 2.0), (plan.raze_quality or "solid")
    elseif pol == "trade" then
        local hisReady = (foe and WAR.ReadyCount(foe, now)) or 0
        local myBurst = WAR.Burst(u, foe, 2.2, now)
        local hisBurst = foe and WAR.Burst(foe, u, 2.2, now) or 0
        want = (hisReady == 0)
            or (myBurst >= 0.85 * hisBurst and myBurst > 0)
            or (foe and foe.hp < (plan.finish_hp or 260))
        if foe and foe.cast_until and foe.cast_until > now then want = true end
        quality = (hisReady == 0) and (plan.raze_quality or "solid") or "poor"
    elseif pol == "lethal" then
        want = foe and (WAR.Burst(u, foe, 1.8, now) >= foe.hp + 25)
        quality = "poor"
    elseif pol == "answer" then
        want = (foe and foe.last_raze_hit_at and now - foe.last_raze_hit_at <= 0.7) or false
        quality = "poor"
    end
    if want and foe and foe.alive then
        local idx = WAR.FindShot(u, foe, now, quality)
        if idx then
            if u.mana < C.RAZE_MANA and u.mango and not u.mango_used then
                u.mana = u.mana + 100
                u.mango_used = true
            end
            if u.mana < C.RAZE_MANA and (u.stick_charges or 0) > 0 and not u.stick_used then
                local g = u.stick_charges * 15
                u.mana = u.mana + g
                u.hp = math.min(u.hp_max, u.hp + g)
                u.stick_used = true
            end
            if u.mana >= C.RAZE_MANA then
                local stacks = foe.stacks or 0
                local dmg = WAR.RazeApplied(u.raze_level, stacks, u.souls, foe.magic_resist, u.stack_talent)
                u.mana = u.mana - C.RAZE_MANA
                u.raze_ready[idx] = now + C.RAZE_CD
                u.cast_until = now + C.RAZE_CAST
                u.cast_label = idx
                u.razes_cast = (u.razes_cast or 0) + 1
                u.last_volley_at = now
                u.aim_x = foe.x + (foe.vx or 0) * C.RAZE_CAST
                u.aim_y = foe.y + (foe.vy or 0) * C.RAZE_CAST
                u.pending_raze = { t = now + C.RAZE_CAST, idx = idx, dmg = dmg, target = foe }
                return "raze"
            end
        end
    end

    if plan.flee then
        step_toward(u, plan.flee_x or u.x, plan.flee_y or u.y, dt, now)
        return "flee"
    end
    if foe and foe.alive then
        if plan.engage ~= false then
            if d > hold + 45 then
                local k = (d - hold) / d
                step_toward(u, u.x + (foe.x - u.x) * k, u.y + (foe.y - u.y) * k, dt, now)
            elseif d < hold - 120 then
                local k = (hold - d) / d
                step_toward(u, u.x - (foe.x - u.x) * k, u.y - (foe.y - u.y) * k, dt, now)
            end
        end
        if attackOn and d <= (u.atk_range or C.ATK_RANGE) + 25 and u.atk_until <= now then
            if start_attack(u, foe, now) then return "attack" end
        end
    end
    return "hold"
end

function WAR.Simulate(state, myPlan, hisPlan, horizon)
    horizon = horizon or C.HORIZON
    local t0 = state.t or 0
    local me = WAR.Prep(clone_unit(state.me))
    local him = WAR.Prep(clone_unit(state.him))
    if state.me_stacks then me.stacks = state.me_stacks; me.stack_t = t0 end
    if state.him_stacks then him.stacks = state.him_stacks; him.stack_t = t0 end

    if (me.incoming or 0) > 0 then
        him.proj[#him.proj + 1] = { t = t0 + (me.incoming_at or C.INCOMING_LAND), dmg = me.incoming, target = me }
    end
    if (him.incoming or 0) > 0 then
        me.proj[#me.proj + 1] = { t = t0 + (him.incoming_at or C.INCOMING_LAND), dmg = him.incoming, target = him }
    end

    local mp = clone_plan(myPlan)
    local hp = clone_plan(hisPlan)
    local tower = state.tower
    local ownTower = state.own_tower
    local me0, him0 = me.hp, him.hp

    local dt = state.dt or C.DT
    local steps = math.floor(horizon / dt + 0.5)
    local aggroMe, aggroHim = false, false
    local windup = (tower and tower.windup) or C.TOWER_WINDUP
    local projSpeed = (tower and tower.proj_speed) or C.TOWER_PROJECTILE
    local ownWindup = (ownTower and ownTower.windup) or C.TOWER_WINDUP
    local ownProjSpeed = (ownTower and ownTower.proj_speed) or C.TOWER_PROJECTILE
    local qMe, qHim = {}, {}
    local function queue_shot(q, fire_t, dmg, dist, wu, ps)
        q[#q + 1] = {
            t = fire_t + (wu or C.TOWER_WINDUP) + dist / math.max(1, ps or C.TOWER_PROJECTILE),
            dmg = dmg,
        }
    end
    local function apply_shots(q, t, victim)
        local keep = {}
        for i = 1, #q do
            local e = q[i]
            if e.t <= t then
                if victim.alive then
                    victim.tower_hits = (victim.tower_hits or 0) + 1
                    apply_damage(victim, e.dmg, t)
                end
            else
                keep[#keep + 1] = e
            end
        end
        return keep
    end

    local tFirst = (tower and tower.next_shot) or C.TOWER_FIRST
    local nextMe, nextHim = t0 + tFirst, t0 + C.TOWER_FIRST
    local waveAggroUntil = -1
    local aggroCdUntil = state.my_aggro_cd_until or 0
    local t = t0

    for i = 0, steps do
        t = t0 + i * dt
        if me.alive then me.hp = math.min(me.hp_max, me.hp + me.regen_hp * dt) end
        if him.alive then him.hp = math.min(him.hp_max, him.hp + him.regen_hp * dt) end

        if me.alive and him.alive then
            control(me, him, mp, t, dt)
            control(him, me, hp, t, dt)
            if state.enemy_wave and mp.attack and distance(me.x, me.y, him.x, him.y) <= (me.atk_range or C.ATK_RANGE) + 35 then
                if t >= aggroCdUntil then
                    for w = 1, #state.enemy_wave do
                        local cw = state.enemy_wave[w]
                        if distance(me.x, me.y, cw.x, cw.y) <= 500 then
                            waveAggroUntil = math.max(waveAggroUntil, t + 2.3)
                            aggroCdUntil = t + 3.0
                            break
                        end
                    end
                end
            end
        elseif me.alive then
            if mp.flee then step_toward(me, mp.flee_x or me.x, mp.flee_y or me.y, dt, t) end
        elseif him.alive then
            if hp.flee then step_toward(him, hp.flee_x or him.x, hp.flee_y or him.y, dt, t) end
        end

        qMe = apply_shots(qMe, t, me)
        qHim = apply_shots(qHim, t, him)
        resolve_pending_attack(me, t)
        resolve_pending_attack(him, t)
        resolve_raze(me, t)
        resolve_raze(him, t)
        apply_projectiles(me, t)
        apply_projectiles(him, t)

        if t - me.stack_t > C.STACK_DURATION then me.stacks = 0 end
        if t - him.stack_t > C.STACK_DURATION then him.stacks = 0 end

        if me.alive then
            if state.enemy_wave then
                local dynWaveDps = 0
                local chaseExtra = (waveAggroUntil > t) and (315 * math.min(1.4, math.max(0, t - t0))) or 0
                for w = 1, #state.enemy_wave do
                    local cw = state.enemy_wave[w]
                    local dc = distance(me.x, me.y, cw.x, cw.y)
                    local reach = (cw.range or 100) + 45
                    if cw.aggro_me and dc <= reach + 260 then
                        dynWaveDps = dynWaveDps + cw.dps
                    elseif waveAggroUntil > t and dc <= reach + chaseExtra then
                        dynWaveDps = dynWaveDps + cw.dps
                    elseif dc <= math.min(reach, 155) and mp.engage then
                        dynWaveDps = dynWaveDps + cw.dps * 0.65
                    end
                end
                if dynWaveDps > 0 then apply_damage(me, dynWaveDps * dt, t) end
            elseif (state.creep_dps_on_me or 0) > 0 then
                apply_damage(me, state.creep_dps_on_me * dt, t)
            end
        end
        if him.alive and (state.creep_dps_on_him or 0) > 0 then
            apply_damage(him, state.creep_dps_on_him * dt, t)
        end

        if tower and me.alive then
            local d = distance(me.x, me.y, tower.x, tower.y)
            if tower.aggro_me then aggroMe = true end
            if d <= (tower.range or C.TOWER_RANGE) then aggroMe = true end
            if aggroMe and d > C.TOWER_LEASH then aggroMe = false end
            if aggroMe and t >= nextMe then
                nextMe = t + (tower.interval or C.TOWER_INTERVAL)
                queue_shot(qMe, t, (tower.dmg or C.TOWER_DMG), d, windup, projSpeed)
            end
        end
        if ownTower and him.alive then
            local d = distance(him.x, him.y, ownTower.x, ownTower.y)
            if ownTower.aggro_me then aggroHim = true end
            if d <= (ownTower.range or C.TOWER_RANGE) then aggroHim = true end
            if aggroHim and d > C.TOWER_LEASH then aggroHim = false end
            if aggroHim and t >= nextHim then
                nextHim = t + (ownTower.interval or C.TOWER_INTERVAL)
                queue_shot(qHim, t, (ownTower.dmg or C.TOWER_DMG), d, ownWindup, ownProjSpeed)
            end
        end

        if not me.alive or not him.alive then
            for j = i + 1, steps do
                t = t0 + j * dt
                if me.alive and mp.flee then step_toward(me, mp.flee_x or me.x, mp.flee_y or me.y, dt, t) end
                if him.alive and hp.flee then step_toward(him, hp.flee_x or him.x, hp.flee_y or him.y, dt, t) end
                if tower and me.alive then
                    local d = distance(me.x, me.y, tower.x, tower.y)
                    if tower.aggro_me then aggroMe = true end
                    if d <= (tower.range or C.TOWER_RANGE) then aggroMe = true end
                    if aggroMe and d > C.TOWER_LEASH then aggroMe = false end
                    if aggroMe and t >= nextMe then
                        nextMe = t + (tower.interval or C.TOWER_INTERVAL)
                        queue_shot(qMe, t, (tower.dmg or C.TOWER_DMG), d, windup, projSpeed)
                    end
                    qMe = apply_shots(qMe, t, me)
                    if not me.alive then break end
                end
            end
            break
        end
    end

    local res = {
        my_hp = me.hp, his_hp = him.hp,
        my_dead = not me.alive, his_dead = not him.alive,
        dealt = him0 - him.hp,
        taken = me0 - me.hp,
        mana_left = me.mana,
        razes_cast = me.razes_cast or 0,
        my_x = me.x, my_y = me.y,
        his_x = him.x, his_y = him.y,
        t_end = t,
        horizon = horizon,
        tower_hits_taken = me.tower_hits or 0,
    }
    res.net = res.dealt - res.taken
    return res
end

--------------------------------------------------------------------------------
-- plan generation & minimax evaluation
--------------------------------------------------------------------------------
function WAR.MyPlans(_state, opts)
    opts = opts or {}
    local plans = {}
    -- Order `500, 700, 260` + `"none", "trade", "burst"` so equal-utility ties (e.g. 0 razes / OOM!)
    -- ALWAYS resolve to `hold500_none` (`HOLD` at max attack range) instead of `hold250_burst` (`W2 02:28` fix)!
    local holds = opts.holds or { 500, 700, 260 }
    local pols = opts.pols or { "none", "trade", "burst" }
    for _, h in ipairs(holds) do
        for _, p in ipairs(pols) do
            plans[#plans + 1] = {
                name = string.format("hold%d_%s", h, p),
                hold_dist = h, raze_policy = p, engage = true, attack = true,
            }
        end
    end
    if opts.flee_points then
        for i, fp in ipairs(opts.flee_points) do
            plans[#plans + 1] = {
                name = "flee" .. i, flee = true, flee_x = fp.x, flee_y = fp.y,
                raze_policy = opts.flee_pol or "lethal", attack = false, engage = false,
            }
        end
    end
    return plans
end

function WAR.HisPlans(state, opts)
    opts = opts or {}
    local plans = {
        { name = "aggressive", hold_dist = 320, raze_policy = "burst", engage = true, attack = true, adaptive = true },
        { name = "reactive",   hold_dist = 440, raze_policy = "trade", engage = true, attack = true,
          adaptive = true, cancel_dodge = true, raze_quality = "lock" },
        { name = "passive",    hold_dist = 700, raze_policy = "none",  engage = false, attack = true },
    }
    local hf = opts.his_flee or state.his_flee
    if hf then
        plans[#plans + 1] = {
            name = "retreat_tower", flee = true, flee_x = hf.x, flee_y = hf.y,
            attack = false, engage = false, raze_policy = "lethal",
        }
    end
    return plans
end

local function utility(state, res)
    local me, him = state.me, state.him
    local u = 0
    if res.my_dead then u = u - C.DEATH_COST end
    if res.his_dead then u = u + C.KILL_BONUS end
    u = u + C.W_HP * ((him.hp - res.his_hp) - (me.hp - res.my_hp))
    u = u + C.W_MANA * (res.mana_left - me.mana)
    local mePct = res.my_hp / math.max(1, me.hp_max)
    local himTrueMax = math.max(1, him.true_hp_max or him.hp_max)
    local himScale = himTrueMax / math.max(1, him.hp_max)
    local himPct = (res.his_hp * himScale) / himTrueMax
    u = u + C.W_STAND * (mePct - himPct) * math.max(me.hp_max, himTrueMax)
    return u
end
WAR.Utility = utility

function WAR.Evaluate(state, opts)
    opts = opts or {}
    local myPlans = WAR.MyPlans(state, opts)
    local hisPlans = WAR.HisPlans(state, opts)
    local horizon = opts.horizon or C.HORIZON
    state.dt = opts.dt or C.DT

    local scored = {}
    for _, mp in ipairs(myPlans) do
        local worst, best, sum, n = nil, nil, 0, 0
        local worstUtil = 1e18
        local dieCount = 0
        local killAll = true
        for _, hp in ipairs(hisPlans) do
            local r = WAR.Simulate(state, mp, hp, horizon)
            local u = utility(state, r)
            sum = sum + u; n = n + 1
            if u < worstUtil then worstUtil = u; worst = r end
            if not best or u > utility(state, best) then best = r end
            if r.my_dead then dieCount = dieCount + 1 end
            if not r.his_dead then killAll = false end
        end
        scored[#scored + 1] = {
            plan = mp,
            worstUtil = worstUtil,
            avgUtil = sum / n,
            worst = worst,
            best = best,
            dieCount = dieCount,
            dieProb = dieCount / n,
            killAll = killAll,
        }
    end

    for _, s in ipairs(scored) do
        if s.dieCount == 0 and s.killAll then
            return {
                mode = "KILL", plan = s.plan, ev = s.worst,
                worst = s.worst, score = s.worstUtil,
                why = "guaranteed kill under every enemy response",
            }
        end
    end

    local bestSafe
    for _, s in ipairs(scored) do
        if s.dieCount == 0 and (not bestSafe or s.worstUtil > bestSafe.worstUtil) then
            bestSafe = s
        end
    end

    if not bestSafe then
        local lowest = 1
        for _, s in ipairs(scored) do if s.dieProb < lowest then lowest = s.dieProb end end
        local cand
        for _, s in ipairs(scored) do
            if s.dieProb <= lowest + 1e-9 and (not cand or s.worstUtil > cand.worstUtil) then cand = s end
        end
        if cand and cand.dieProb > 0 then
            return {
                mode = "ESCAPE", plan = cand.plan, ev = cand.worst, worst = cand.worst,
                score = cand.worstUtil, danger = true,
                why = "every plan risks death: minimise loss",
            }
        end
    end

    local s = bestSafe
    local mode = "HOLD"
    -- NEVER emit `TRADE` on a plan that casts 0 Razes (`W2 02:28` dry-mana 6 MP suicide fix!):
    if (s.plan.raze_policy == "burst" or s.plan.raze_policy == "trade" or s.plan.raze_policy == "lethal")
        and (s.worst.razes_cast or 0) > 0 then
        mode = "TRADE"
    end
    if s.plan.flee then mode = "ESCAPE" end

    if mode == "TRADE" and (s.worst.his_hp - s.worst.my_hp) <= 0 and (s.worst.net or 0) <= 0 then
        for _, c in ipairs(scored) do
            if c.dieCount == 0 and c.plan.raze_policy == "none" and c.worstUtil > s.worstUtil then
                s = c; mode = "HOLD"; break
            end
        end
    end

    return {
        mode = mode, plan = s.plan, ev = s.worst, worst = s.worst,
        avg = s.avgUtil, score = s.worstUtil,
        why = "best worst-case safe plan",
    }
end

function WAR.SelfTest()
    local fails = {}
    local function check(name, got, want, tol)
        tol = tol or 1e-6
        if math.abs(got - want) > tol then
            fails[#fails + 1] = string.format("%s: got %.3f want %.3f", name, got, want)
        end
    end
    -- Patch 7.41f: L1 base 85 * 0.75 = 63.75
    check("raze L1 base 7.41f", WAR.RazeApplied(1, 0, 0, 0.25), 63.75)
    -- Patch 7.41f: L4 base 280 + 2*80 + 10*2 = 460 * 0.75 = 345.0
    check("raze L4 stacked 7.41f", WAR.RazeApplied(4, 2, 10, 0.25), 345.0)
    -- Patch 7.41f: volley of 3 at L3 (215/65), 8 souls (+16): (231 + 296 + 361) * 0.75 = 666.0
    check("volley3 7.41f", WAR.VolleyDamage(3, 0, 8, 3, 0.25), 666.0)
    return #fails == 0, fails
end

return WAR
