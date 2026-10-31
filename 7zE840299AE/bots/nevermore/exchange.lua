--[[
================================================================================
 EXCHANGE — Patch 7.41f Shadow Fiend Mirror Exchange Evaluator (Pure Lua 5.1)
================================================================================
 Pure-Lua forecast & cast-lock reaction evaluator for 1v1 Shadow Fiend exchanges.

 Unified v6.6.0 fixes over v6.5.0:
   1. Exact Patch 7.41f Shadowraze formula:
        Base  = { 85, 150, 215, 280 }
        Stack = { 35, 50, 65, 80 } (+30 with Lvl 10 stack talent)
        Souls = +2 * caster.souls (fixes v6.5.0 bug that used victim.souls!)
      plus existing `modifier_nevermore_shadowraze_debuff` stacks on the target.
   2. Critical `X.ExitPoint` geometry fix: NEVER negates `(ux, uy)` with `step = need + pad`
      (which walked straight INTO the center `(cx, cy)` of the enemy Raze circle when
      our tower lay behind `(cx, cy)`!). Guarantees `dist(exitPt, centre) >= RADIUS + pad`.
   3. Accounts for instant emergency heal (`item_faerie_fire` +85 HP, Stick/Wand charges)
      in `lethal` and `loses_sustain` checks (`9068560663.dem` 01:53 fix).
================================================================================
]]

local X = {}

X.C = {
    BANDS              = { 200, 450, 700 },
    RADIUS             = 250,
    CAST               = 0.55,
    CD                 = 9.0,
    MANA               = 75,
    MS                 = 305,
    WINDOW             = 2.2,
    REACH              = 950,
    RAZE_BASE          = { 85, 150, 215, 280 },
    RAZE_STACK         = { 35, 50, 65, 80 },
    RAZE_PER_SOUL      = 2,
    MAX_STACKS         = 4,
    MAGIC_RESIST       = 0.25,
    ATK_INTERVAL       = 0.78,
    SUSTAIN            = 5.2,
    SUSTAIN_PAD        = 0.82,
    PANIC_HP           = 0.20,
    PANIC_HP_BRAWL     = 0.32,
    ATK_REACH          = 565, -- 525 base attack range + hull/step
    TOWER_DPS          = 80,
    TOWER_TRUST        = 0.72,
    CREEP_TOL          = 0.16,
    BRAWL_EDGE         = 1.14,
    ENTER_MARGIN       = 0.42,
    ENTER_MARGIN_TOWER = 0.10,
    MIN_P              = 0.12,
    CLOSE_STEP         = 175,
    CLOSE_STEPS        = 2,
    PANIC_HP_PCT       = 0.28,
}

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

function X.Slack(dist, band, escape)
    return X.C.RADIUS - math.abs(dist - band) - escape
end

function X.HitProb(slack)
    if slack >= 60 then return 0.95 end
    if slack >= 0 then return 0.75 end
    if slack >= -80 then return 0.45 end
    if slack >= -160 then return 0.20 end
    return 0.03
end

--[[ Exact Patch 7.41f Shadowraze applied damage for ONE hit:
     `level` (1..4), `souls` (CASTER's souls), `stacks` (current debuff stacks on VICTIM),
     `mr` (victim magic resist, default 0.25), `stackBonusTalent` (+30 if Lvl 10 talent). ]]--
function X.RazeDamage(level, souls, stacks, mr, stackBonusTalent)
    if not level or level <= 0 then return 0 end
    local lv = clamp(level, 1, 4)
    local base = X.C.RAZE_BASE[lv] or 85
    local perStack = (X.C.RAZE_STACK[lv] or 35) + (stackBonusTalent or 0)
    local raw = base + (souls or 0) * X.C.RAZE_PER_SOUL + (stacks or 0) * perStack
    return raw * (1.0 - (mr or X.C.MAGIC_RESIST))
end

--[[ Expected volley damage `u` puts into `v` at `dist` over `X.C.WINDOW`. ]]--
function X.Volley(u, v, dist, opts)
    opts = opts or {}
    local C = X.C
    if not u or not u.rlvl or u.rlvl <= 0 then return 0, 0, {} end
    local escape = opts.escape
    if escape == nil then
        escape = math.max(0, ((v and v.ms) or C.MS) * C.CAST)
    end
    local mana = (u.mana or 0) + (u.mana_regen or 0) * C.WINDOW
        + ((u.mango and 100) or 0) + ((u.stick_charges or 0) * 15)
    local total, n, probs = 0, 0, {}
    local curStacks = (v and v.stacks) or 0
    local mr = (v and v.mr) or C.MAGIC_RESIST
    for i = 1, 3 do
        local cd = (u.cd and u.cd[i]) or 0
        local p = X.HitProb(X.Slack(dist, C.BANDS[i], escape))
        if cd <= C.WINDOW and mana >= C.MANA and p > C.MIN_P then
            mana = mana - C.MANA
            n = n + 1
            local d = X.RazeDamage(u.rlvl, u.souls or 0, curStacks, mr, u.stack_talent)
            total = total + d * p
            if p >= 0.45 then
                curStacks = math.min(C.MAX_STACKS, curStacks + 1)
            end
            probs[#probs + 1] = { band = i, p = p, dmg = d }
        end
    end
    return total, n, probs
end

function X.Forecast(st)
    local C = X.C
    local me, him = st.me, st.him
    local dist = st.dist or 9999
    local escMe  = (me.cast_left and me.cast_left > 0.1) and 0 or
                   math.max(0, (me.ms or C.MS) * C.CAST)
    local escHim = (st.locked and st.locked > 0.1) and 0 or
                   math.max(0, (him.ms or C.MS) * C.CAST)

    local my_rz, my_n, my_p, my_d = 0, 0, {}, dist
    local his_rz, his_n, his_p, his_d = 0, 0, {}, dist
    for k = 0, C.CLOSE_STEPS do
        local d = math.max(C.BANDS[1], dist - k * C.CLOSE_STEP)
        local a, an, ap = X.Volley(me, him, d, { escape = escHim })
        if a > my_rz then my_rz, my_n, my_p, my_d = a, an, ap, d end
        local b, bn, bp = X.Volley(him, me, d, { escape = escMe })
        if b > his_rz then his_rz, his_n, his_p, his_d = b, bn, bp, d end
    end

    -- Sequential 2-band step combo (`9069188041.dem` `03:38.9-03:44.1` Death #2 Fix):
    -- `X.Volley` evaluates a single static distance `d`, missing `R3 (700) -> R2 (450)` or `R2 (450) -> R1 (200)`
    -- across a single 165u step over `WINDOW = 2.2s` (`2 * 0.55s = 1.10s` cast time + `0.54s` walk)!
    local function twoBandStepVolley(u, v, curDist, esc)
        if not u or (u.rlvl or 0) <= 0 then return 0, 0 end
        local potMana = (u.mana or 0) + (u.mana_regen or 0) * C.WINDOW
            + ((u.mango and 100) or 0) + ((u.stick_charges or 0) * 15)
        if potMana < C.MANA * 2 then return 0, 0 end
        local bestCombo = 0
        local mr = (v and v.mr) or C.MAGIC_RESIST
        local s0 = (v and v.stacks) or 0
        local pairs = { { 3, 2 }, { 2, 1 } }
        for pi = 1, 2 do
            local b1, b2 = pairs[pi][1], pairs[pi][2]
            local cd1 = (u.cd and u.cd[b1]) or 0
            local cd2 = (u.cd and u.cd[b2]) or 0
            if cd1 <= 0.25 and cd2 <= C.WINDOW then
                local p1 = X.HitProb(X.Slack(curDist, C.BANDS[b1], esc))
                local dAfterStep = math.max(C.BANDS[1], curDist - 185)
                local p2 = X.HitProb(X.Slack(dAfterStep, C.BANDS[b2], esc))
                if p1 >= 0.70 and p2 >= 0.45 then
                    local dmg1 = X.RazeDamage(u.rlvl, u.souls or 0, s0, mr, u.stack_talent)
                    local dmg2 = X.RazeDamage(u.rlvl, u.souls or 0, math.min(C.MAX_STACKS, s0 + 1), mr, u.stack_talent)
                    local ev = dmg1 * p1 + dmg2 * p2
                    if ev > bestCombo then bestCombo = ev end
                end
            end
        end
        return bestCombo, (bestCombo > 0 and 2 or 0)
    end
    local myComboRz, myComboN = twoBandStepVolley(me, him, dist, escHim)
    if myComboRz > my_rz then my_rz, my_n = myComboRz, math.max(my_n, myComboN) end
    local hisComboRz, hisComboN = twoBandStepVolley(him, me, dist, escMe)
    if hisComboRz > his_rz then his_rz, his_n = hisComboRz, math.max(his_n, hisComboN) end

    -- Note: `me.dmg` and `him.dmg` passed by `war_director` are ALREADY post-armor
    -- (`K.AttackDamageVs`), so do NOT double-discount by 0.72 unless `raw_dmg` is flagged!
    local dmgMult = st.raw_dmg and 0.76 or 0.92 -- 0.92 accounts for occasional uphill/turn delay
    local atk_me, atk_him = 0, 0
    local swings = math.max(0, math.floor(C.WINDOW / C.ATK_INTERVAL))
    if dist <= C.ATK_REACH then
        atk_me  = (me.dmg or 0)  * swings * dmgMult
        atk_him = (him.dmg or 0) * swings * dmgMult
    end

    local cr_me  = (st.creep_dps_on_me or 0)  * C.WINDOW
    local cr_him = (st.creep_dps_on_him or 0) * C.WINDOW
    local tw_him = ((st.tower_on_him or 0) * C.TOWER_TRUST) * C.WINDOW
    local tw_me  = ((st.tower_on_me or 0) * C.TOWER_TRUST) * C.WINDOW

    local my_total  = my_rz  + atk_me + cr_him * 0.5 + tw_him
    local his_total = his_rz + atk_him + cr_me + tw_me

    local meBurstHeal  = ((me.faerie and 85) or 0) + ((me.stick_charges or 0) * 15)
    local himBurstHeal = ((him.faerie and 85) or 0) + ((him.stick_charges or 0) * 15)
    local meEffHp  = math.max(1, (me.hp or 1) + meBurstHeal - (me.incoming or 0))
    local himEffHp = math.max(1, (him.hp or 1) + himBurstHeal - (him.incoming or 0))

    local f = {
        my_raze = my_rz, his_raze = his_rz,
        my_atk = atk_me, his_atk = atk_him, creep_on_me = cr_me,
        my_n = my_n, his_n = his_n, my_probs = my_p, his_probs = his_p,
        my_at_dist = my_d, his_at_dist = his_d,
        my_total = my_total, his_total = his_total,
        net = my_total - his_total,
        my_hp = meEffHp, his_hp = himEffHp,
        locked = (st.locked or 0) > 0.1,
    }
    f.my_open = (my_n > 0 and my_total > 0)
    f.lethal = (my_total >= himEffHp) and (dist <= C.REACH)

    local dps_him = ((him.dmg or 0) * dmgMult) / C.ATK_INTERVAL + (st.creep_dps_on_me or 0)
        + ((st.tower_on_me or 0) * C.TOWER_TRUST)
    local dps_me  = ((me.dmg or 0) * dmgMult) / C.ATK_INTERVAL + (st.creep_dps_on_him or 0)
        + ((st.tower_on_him or 0) * C.TOWER_TRUST)
    f.dps_me, f.dps_him = dps_me, dps_him
    f.tower_on_him, f.tower_on_me = tw_him, tw_me
    f.pressure_me  = atk_me + tw_him + cr_him * 0.5
    f.pressure_him = atk_him + cr_me + tw_me
    f.creep_share  = meEffHp > 0 and (cr_me / meEffHp) or 0
    f.his_sustain = dps_him * C.SUSTAIN
    f.my_sustain  = dist <= (C.ATK_REACH + 80) and dps_me * C.SUSTAIN or 0
    f.can_brawl_kill = (dist <= C.ATK_REACH + 75) and (himEffHp <= (me.dmg or 0) * 2.15 + my_rz)
        and (meEffHp > (him.dmg or 0) * 1.35 + his_rz)
    f.loses_sustain = (f.his_sustain > 0)
        and (meEffHp < f.his_sustain * C.SUSTAIN_PAD)
        and not f.can_brawl_kill
        and not (himEffHp <= f.my_sustain + f.my_raze)
    return f
end

function X.Verdict(st)
    local C = X.C
    local f = X.Forecast(st)
    local me = st.me
    local hp_pct = (f.my_hp or me.hp or 1) / math.max(1, me.hp_max or 1)
    local v, why

    -- `9068560663.dem` 01:53 & `9069188041.dem` 03:40 Fix:
    -- NEVER force DISENGAGE when enemy is finishable in <= 2 swings/raze, OR when a dry (`his_n == 0`) enemy
    -- is outside right-click reach (`dist > ATK_REACH + 25`) while we have free unanswered Raze (`my_n > 0`)!
    local freeDryPokeSafe = (f.his_n == 0) and (f.my_n > 0)
        and (st.dist and st.dist > C.ATK_REACH + 25)
        and ((f.tower_on_me or 0) <= 0) and ((f.creep_on_me or 0) <= 25)
    if f.lethal or f.can_brawl_kill then
        v, why = (f.my_n > 0 and "ENTER" or "BRAWL"), "enemy inside immediate finish threshold"
    elseif hp_pct <= C.PANIC_HP and not freeDryPokeSafe then
        v, why = "DISENGAGE", "below panic effective HP"
    elseif f.loses_sustain and st.dist and st.dist <= C.ATK_REACH + 90 then
        v, why = "DISENGAGE", "we lose sustained close right-click fight"
    elseif f.my_n == 0 and f.his_n == 0 then
        if hp_pct <= C.PANIC_HP_BRAWL and f.pressure_him > f.pressure_me then
            v, why = "DISENGAGE", "manaless brawl with enemy wave pressure"
        elseif f.pressure_me > 0 and f.pressure_me >= C.BRAWL_EDGE * math.max(1, f.pressure_him) then
            v, why = "BRAWL", "manaless right-click + creep/tower advantage"
        elseif st.dist and st.dist > C.ATK_REACH then
            v, why = "HOLD", "both out of mana and out of reach"
        else
            v, why = "REFUSE", "manaless brawl favors enemy"
        end
    elseif f.my_n == 0 then
        if st.dist and st.dist >= C.REACH + 40 then
            v, why = "HOLD", "out of raze reach: farm safely"
        elseif hp_pct <= 0.45 and f.his_raze >= f.my_hp * 0.45 then
            v, why = "DISENGAGE", "no raze ready and enemy burst threatens us"
        else
            v, why = "REFUSE", "no raze ready: avoid initiating trade"
        end
    elseif f.creep_share > C.CREEP_TOL and f.my_raze < 0.85 * math.max(1, f.his_total) then
        v, why = "REFUSE", "standing in heavy enemy creep wave"
    elseif f.his_n == 0 then
        -- `auto-20261031-0230` `02:08` & `01:01` Fix:
        -- When enemy has 0 coils (`< 75 MP` or on CD) inside right-click range (`<= ATK_REACH + 45`),
        -- NEVER return `ENTER` (`hold_dist = 460`) if we lose the close physical trade (`loses_sustain` or `<= 3.3` autos)!
        local closePhysDanger = st.dist and st.dist <= (C.ATK_REACH + 45)
            and (f.loses_sustain or ((f.my_hp or 0) <= ((st.him and st.him.dmg) or 55) * 3.3 and not f.lethal and not f.can_brawl_kill))
        if closePhysDanger then
            v, why = "DISENGAGE", "enemy dry on mana but wins close right-click race"
        else
            v, why = "ENTER", "enemy cannot answer with razes"
        end
    elseif f.locked and f.my_raze > 0 then
        v, why = "PUNISH", "enemy pinned in 0.55s cast/attack windup"
    elseif f.net >= (f.tower_on_him > 0 and C.ENTER_MARGIN_TOWER or C.ENTER_MARGIN)
                    * math.max(1, f.his_total) then
        v, why = "ENTER", "exchange EV favors us"
    else
        v, why = "REFUSE", "enemy burst beats ours: hold spacing & CS"
    end
    f.verdict, f.why = v, why
    return f
end

function X.BestBand(dist, u, v, opts)
    local C = X.C
    opts = opts or {}
    local escape = opts.escape
    if escape == nil then
        escape = math.max(0, ((v and v.ms) or C.MS) * C.CAST)
    end
    local best, bestP, bestSlack = nil, -1, nil
    local mana = u.mana or 0
    for i = 1, 3 do
        local cd = (u.cd and u.cd[i]) or 0
        if cd <= (opts.window or 0.2) and mana >= C.MANA then
            local s = X.Slack(dist, C.BANDS[i], escape)
            local p = X.HitProb(s)
            if p > bestP then best, bestP, bestSlack = i, p, s end
        end
    end
    return best, bestP, bestSlack
end

function X.SafeDistance(him, opts)
    opts = opts or {}
    local C = X.C
    local reach = C.BANDS[1]
    for i = 3, 1, -1 do
        local cd = (him.cd and him.cd[i]) or 0
        if cd <= (opts.window or 1.2) then
            reach = C.BANDS[i]
            break
        end
    end
    return reach + C.RADIUS + (opts.pad or 65)
end

function X.Reaction(dist, band, me, him, opts)
    local C = X.C
    opts = opts or {}
    local centre = C.BANDS[band] or 450
    local need = C.RADIUS - math.abs(dist - centre)
    local step = (me.ms or C.MS) * C.CAST * (opts.efficiency or 0.85)
    local idx, p = X.BestBand(dist, me, him, { escape = 0, window = 0.15 })
    if idx and p >= (opts.answer_p or 0.70) then return "answer", idx, p end
    if need <= step then return "dodge", nil, 0 end
    return "eat", nil, 0
end

function X.React(dist, band, remaining, me, him, opts)
    opts = opts or {}
    local C = X.C
    local centre = C.BANDS[band] or 450
    local need = C.RADIUS - math.abs(dist - centre)
    if need <= 0 then return "clear", nil, 0 end
    local hp_pct = (me.hp or 1) / math.max(1, me.hp_max or 1)
    local panic = opts.panic or C.PANIC_HP
    local t = math.max(0, (remaining or C.CAST) - 0.05)
    local step = (me.ms or C.MS) * t * (opts.efficiency or 0.90)

    local idx, p = X.BestBand(dist, me, him, { escape = 0, window = 0.15 })
    local can_answer = (idx ~= nil) and (p or 0) >= 0.70
    local his_hit = (him and him.raze_dmg) or 150
    local broke = (hp_pct <= panic) or ((me.hp or 0) <= his_hit * 1.20)

    local can_step = need <= step
    local mySingleRaze = X.RazeDamage(me.rlvl or 0, me.souls or 0, (him and him.stacks) or 0)
    local can_kill = him and (him.hp or 1e9) <= mySingleRaze * 0.96
    local dominant = hp_pct >= (opts.trade_hp or 0.55)
    if can_answer and not broke and (can_kill or dominant or not can_step) then
        return "answer", nil, idx
    end
    if can_step then return "step", nil, 0 end
    if can_answer and not broke then return "answer", nil, idx end
    if me.dmg and dist <= (opts.atk_reach or C.ATK_REACH) and not broke then
        return "trade", nil, 0
    end
    return "eat", nil, 0
end

--[[ Guaranteed-outward radial exit from circle `(cx, cy)` of radius `X.C.RADIUS`:
     Fixes v6.5.0 sign-flip bug that stepped TOWARD `(cx, cy)` when `safe` lay behind `(cx, cy)`! ]]--
function X.ExitPoint(x, y, cx, cy, _need, safe, pad)
    local rTarget = X.C.RADIUS + (pad or 38)
    local dx, dy = x - cx, y - cy
    local d = math.sqrt(dx * dx + dy * dy)
    local ux, uy
    if d < 1e-3 then
        if safe then
            local sx, sy = safe.x - cx, safe.y - cy
            local sl = math.sqrt(sx * sx + sy * sy)
            if sl > 1e-3 then ux, uy = sx / sl, sy / sl else ux, uy = 1, 0 end
        else
            ux, uy = 1, 0
        end
        return cx + ux * rTarget, cy + uy * rTarget
    end
    ux, uy = dx / d, dy / d
    local baseAngle = math.atan2(uy, ux)
    if not safe then
        return cx + ux * rTarget, cy + uy * rTarget
    end

    -- Test pure radial exit (`0 deg`) and gentle angular offsets (`+-22 deg`, `+-42 deg`) on the outer boundary
    -- `cx + cos(a)*rTarget`, keeping step cost tight while biasing gently toward `safe`!
    local bestPx, bestPy = cx + ux * rTarget, cy + uy * rTarget
    local bestCost = 1e18
    local offsets = { 0, 0.38, -0.38, 0.72, -0.72 }
    for i = 1, #offsets do
        local a = baseAngle + offsets[i]
        local px = cx + math.cos(a) * rTarget
        local py = cy + math.sin(a) * rTarget
        local stepLen = math.sqrt((px - x) * (px - x) + (py - y) * (py - y))
        local dSafe = math.sqrt((px - safe.x) * (px - safe.x) + (py - safe.y) * (py - safe.y))
        -- Never allow an offset that adds more than +42u of extra walk inside the 0.55s dodge window!
        if stepLen <= (rTarget - d) + 42 then
            local cost = stepLen + dSafe * 0.18
            if cost < bestCost then
                bestCost = cost
                bestPx, bestPy = px, py
            end
        end
    end
    return bestPx, bestPy
end

function X.ShouldAttack(me, him, dist, opts)
    opts = opts or {}
    if not me or not him then return false end
    if dist > (opts.reach or X.C.ATK_REACH) then return false end
    local hp_pct = (me.hp or 1) / math.max(1, me.hp_max or 1)
    if hp_pct <= (opts.panic or X.C.PANIC_HP) then return false end
    if (me.hp or 0) <= (him.dmg or 60) * (opts.min_swings or 2.0)
        and (him.hp or 999) > (me.dmg or 50) * 1.15 then
        return false
    end
    return true
end

function X.SelfTest()
    local fails = {}
    local function chk(name, cond) if not cond then fails[#fails + 1] = name end end
    -- 7.41f L1 base 85 * 0.75 = 63.75
    chk("7.41f raze L1", math.abs(X.RazeDamage(1, 0, 0, 0.25) - 63.75) < 1e-6)
    -- ExitPoint MUST always lie >= RADIUS + pad outside circle center EVEN when `safe` is on the opposite side!
    local px, py = X.ExitPoint(100, 0, 0, 0, 150, { x = -1000, y = 0 }, 40)
    local outDist = math.sqrt(px * px + py * py)
    chk("ExitPoint never walks into circle center", outDist >= 289.0)
    return #fails == 0, fails
end

return X
