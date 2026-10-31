-- scripts/vscripts/bots/item_purchase_nevermore.lua

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local K = require("bots/nevermore/combat")
local P = require("bots/nevermore/positioning")

local PurchaseTable = {
    "item_ward_observer",
    "item_tango",
    "item_branches",
    "item_circlet",
    "item_circlet",
    "item_enchanted_mango",
    "item_faerie_fire",

    -- Strictly 2x Bracer FIRST (+10 STR = +220 HP, +6 DMG, +2 HP/s + Bracer-backpack regen amp),
    -- THEN Boots of Speed, and STRAIGHT into full Power Treads (`item_magic_stick` strictly forbidden!).
    "item_gauntlets", "item_recipe_bracer",
    "item_gauntlets", "item_recipe_bracer",
    "item_boots",

    -- Straight into Power Treads with Belt of Strength FIRST (+132 HP in lane!) then Gloves of Haste
    "item_belt_of_strength",
    "item_gloves",

    "item_blade_of_alacrity", "item_belt_of_strength", "item_recipe_dragon_lance",

    "item_staff_of_wizardry", "item_robe", "item_recipe_kaya"
}

-- Per-bot purchase state (keyed by player ID)
local BotPurchaseState = {}

local function GetBotState(bot)
    local pid = bot:GetPlayerID()
    if pid == nil or pid < 0 then
        return nil
    end

    if not BotPurchaseState[pid] then
        BotPurchaseState[pid] = {
            currentItemIndex = 1,
            lastSalveBuyTime = -1000,
            lastMangoBuyTime = -1000,
            extraMango = 0,
            extraSalve = 0,
            recoveryWindowAt = -1000,
            recoverySpent = 0,
            lastRecoveryBuy = -1000,
            lastShopAttempt = -1000,
            bought5MinWard = false,
            lastCourierCallTime = -1000,
            resolvedCourierSlot = nil,
            trySlotOffset = 0,
            lastEnemySeenAt = -1000,
            lastEnemyHp = nil,
            lastEnemyMaxHp = nil,
            lastEnemyLvl = nil,
            enKnownMaxHp = nil,
            lastEnemyHasSalve = false,
            lastEnemyRegen = 2.0,
        }
    end

    return BotPurchaseState[pid]
end

-- Inspect whether a queryable enemy hero owns `item_flask` (active/backpack/stash) or has `modifier_flask_healing`.
local function UnitHasHealingSalve(enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if enemy.HasModifier then
        local okM, hasMod = pcall(enemy.HasModifier, enemy, "modifier_flask_healing")
        if okM and hasMod then return true end
    end
    if enemy.GetItemInSlot then
        for s = 0, 14 do
            local okI, it = pcall(enemy.GetItemInSlot, enemy, s)
            if okI and it and it.GetName and it:GetName() == "item_flask" then
                return true
            end
        end
    end
    return false
end

-- Update cached observation of the opposing mid hero (handles backpacked Bracers via `enKnownMaxHp`).
local function UpdateObservedEnemy(bot, state, now)
    local enemy = nil
    local Wmod = package.loaded["bots/nevermore/world"]
    if Wmod and Wmod.s and Wmod.s.enemy and U.CanQuery(Wmod.s.enemy) then
        enemy = Wmod.s.enemy
    elseif bot.GetNearbyHeroes then
        local near = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
        if near and near[1] and U.CanQuery(near[1]) then
            enemy = near[1]
        end
    end

    if enemy and enemy:IsAlive() then
        if enemy.GetPlayerID then
            local okP, ePid = pcall(enemy.GetPlayerID, enemy)
            if okP and type(ePid) == "number" and ePid >= 0 then
                state.lastEnemyPid = ePid
            end
        end
        local enHp = enemy:GetHealth() or 0
        local enMax = math.max(1, enemy:GetMaxHealth() or 600)
        local enLvl = (enemy.GetLevel and enemy:GetLevel()) or 1
        if state.lastEnemyLvl ~= enLvl then
            state.lastEnemyLvl = enLvl
            state.enKnownMaxHp = enMax
        else
            state.enKnownMaxHp = math.max(state.enKnownMaxHp or enMax, enMax)
        end
        local trueMax = state.enKnownMaxHp or enMax
        local trueHp = enHp
        if trueMax - enMax >= 110 and enMax > 0 then
            trueHp = enHp * (trueMax / enMax)
        end
        state.lastEnemySeenAt = now
        state.lastEnemyHp = trueHp
        state.lastEnemyMaxHp = trueMax
        state.lastEnemyHasSalve = UnitHasHealingSalve(enemy)
        local okR, reg = false, nil
        if enemy.GetHealthRegen then okR, reg = pcall(enemy.GetHealthRegen, enemy) end
        state.lastEnemyRegen = (okR and type(reg) == "number" and reg >= 0) and reg or 2.2
    end
end

-- Live enemy-death check (`9069188041.dem` `01:11.6` First Blood Fix):
-- `ItemPurchaseThink()` can run BEFORE `Think()` (`W.Update`) on the exact kill tick, so query `IsHeroAlive`
-- directly in addition to `W.s.enemyAlive == false`!
local function IsEnemyDeadRightNow(bot, state)
    local Wmod = package.loaded["bots/nevermore/world"]
    if Wmod and Wmod.s and Wmod.s.enemyAlive == false then
        return true
    end
    if type(IsHeroAlive) == "function" then
        local enPid = (state and state.lastEnemyPid) or (Wmod and Wmod.s and Wmod.s.enemyPlayerId)
        if type(enPid) == "number" and enPid >= 0 then
            local ok, alive = pcall(IsHeroAlive, enPid)
            if ok and alive == false then return true end
        elseif bot and type(GetTeamPlayers) == "function" then
            local enemyTeam = (bot:GetTeam() == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
            local okT, pids = pcall(GetTeamPlayers, enemyTeam)
            if okT and type(pids) == "table" and #pids == 1 then
                local ok, alive = pcall(IsHeroAlive, pids[1])
                if ok and alive == false then return true end
            end
        end
    end
    return false
end

-- `v7.0.0` / `v7.1.0` Salve Purchase Discipline:
-- NEVER buy `item_flask` when the live enemy hero has approximately the same HP (or even less HP) as the bot
-- AND the enemy does NOT have a Healing Salve (`item_flask` or active `modifier_flask_healing`)!
function NevermoreEnemyBlocksSalveBuy(bot, state, now)
    if not bot or not state then return false end
    now = now or GameTime()
    if IsEnemyDeadRightNow(bot, state) then
        return false -- Enemy is dead & respawning full at Fountain -> post-kill reset Salve is allowed
    end
    UpdateObservedEnemy(bot, state, now)
    local dt = now - (state.lastEnemySeenAt or -1000)
    if not state.lastEnemyHp or dt < 0 or dt > 10.0 then
        return false
    end
    if state.lastEnemyHasSalve then
        return false -- Enemy owns or is actively drinking a Salve -> matching sustain is allowed
    end
    local enMax = math.max(1, state.lastEnemyMaxHp or 600)
    local enHp = math.min(enMax, state.lastEnemyHp + dt * (state.lastEnemyRegen or 2.2))
    local enPct = enHp / enMax

    local myHp = bot:GetHealth() or 0
    local myMax = math.max(1, bot:GetMaxHealth() or 600)
    local myPct = myHp / myMax

    local cfg = C.CONSUMABLE_BUY or {}
    local eqAbs = cfg.EQUAL_HP_ABS or 165
    local eqPct = cfg.EQUAL_HP_PCT or 0.17

    local approxSameHp = (math.abs(myHp - enHp) <= eqAbs) or (math.abs(myPct - enPct) <= eqPct)
    local enemyEvenLower = (enHp < myHp) and (enPct <= myPct)
    return approxSameHp or enemyEvenLower
end

function NevermoreGetPurchaseOrder()
    local copy = {}
    for i = 1, #PurchaseTable do copy[i] = PurchaseTable[i] end
    return copy
end

function ItemPurchaseThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    local state = GetBotState(bot)
    if not state then return end
    if GameTime() < state.lastShopAttempt then
        state.lastShopAttempt = -1000
        state.lastCourierCallTime = -1000
        state.lastSalveBuyTime = -1000
        state.lastMangoBuyTime = -1000
        state.recoveryWindowAt = GameTime()
        state.resolvedCourierSlot = nil
        state.trySlotOffset = 0
        state.lastEnemySeenAt = -1000
    end
    if GameTime() - state.lastShopAttempt < 0.25 then return end
    state.lastShopAttempt = GameTime()
    local now = GameTime()
    local gold = bot:GetGold()

    UpdateObservedEnemy(bot, state, now)

    -- 0. WARD AT 4:30 (270 seconds) — never buy a duplicate if starting ward is still in inventory!
    if DotaTime() >= 270 and not state.bought5MinWard then
        local alreadyHasWard = false
        for s = 0, 14 do
            local it = bot:GetItemInSlot(s)
            if it and it:GetName() == "item_ward_observer" then alreadyHasWard = true; break end
        end
        if alreadyHasWard then
            state.bought5MinWard = true
        else
            local wRes = bot:ActionImmediate_PurchaseItem("item_ward_observer")
            if wRes == (PURCHASE_ITEM_SUCCESS or 0) then
                state.bought5MinWard = true
                gold = bot:GetGold()
            end
        end
    end

    -- Inventory + stash + dedicated TP slot + team courier: do not duplicate an item in delivery.
    local function owns(name)
        if name == "item_tpscroll" or name == "item_teleport_scroll" then
            return U.HasAnyTPScroll(bot)
        end
        for i = 0, 20 do
            local ok, it = pcall(bot.GetItemInSlot, bot, i)
            if ok and it and it:GetName() == name then return true end
        end
        local myPid = bot:GetPlayerID()
        local nCour = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
        for i = 0, nCour - 1 do
            local courier = GetCourier(i)
            if courier and not courier:IsNull() then
                local cPid = courier.GetPlayerID and courier:GetPlayerID() or -1
                local foreignOwner = (cPid >= 0 and cPid ~= myPid)
                local mine = (not foreignOwner) and ((cPid == myPid)
                    or (state.resolvedCourierSlot ~= nil and i == state.resolvedCourierSlot)
                    or (nCour == 1 and (not courier.GetTeam or courier:GetTeam() == bot:GetTeam())))
                if mine then
                    for slot = 0, 8 do
                        local ok, it = pcall(courier.GetItemInSlot, courier, slot)
                        if ok and it and it:GetName() == name then return true end
                    end
                end
            end
        end
        return false
    end

    local function countOwned(name)
        local total = 0
        for i = 0, 20 do
            local ok, it = pcall(bot.GetItemInSlot, bot, i)
            if ok and it and it:GetName() == name then
                local ch = (it.GetCurrentCharges and it:GetCurrentCharges()) or 0
                total = total + (ch > 0 and ch or 1)
            end
        end
        local myPid = bot:GetPlayerID()
        local nCour = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
        for i = 0, nCour - 1 do
            local courier = GetCourier(i)
            if courier and not courier:IsNull() then
                local cPid = courier.GetPlayerID and courier:GetPlayerID() or -1
                local foreignOwner = (cPid >= 0 and cPid ~= myPid)
                local mine = (not foreignOwner) and ((cPid == myPid)
                    or (state.resolvedCourierSlot ~= nil and i == state.resolvedCourierSlot)
                    or (nCour == 1 and (not courier.GetTeam or courier:GetTeam() == bot:GetTeam())))
                if mine then
                    for slot = 0, 8 do
                        local ok, it = pcall(courier.GetItemInSlot, courier, slot)
                        if ok and it and it:GetName() == name then
                            local ch = (it.GetCurrentCharges and it:GetCurrentCharges()) or 0
                            total = total + (ch > 0 and ch or 1)
                        end
                    end
                end
            end
        end
        return total
    end

    local cfg = C.CONSUMABLE_BUY or {}
    if now - state.recoveryWindowAt >= (cfg.RECOVERY_WINDOW or 150) then
        state.recoveryWindowAt = now
        state.recoverySpent = 0
    end
    local fntLoc = P.GetFountain(bot)
    local ownT1Loc = P.GetT1Tower and P.GetT1Tower(bot) or nil
    local missingHP = bot:GetMaxHealth() - bot:GetHealth()
    local hpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local distToFountain = fntLoc and GetUnitToLocationDistance(bot, fntLoc) or 99999
    local distToOwnT1 = ownT1Loc and GetUnitToLocationDistance(bot, ownT1Loc) or 0
    local t1ToFountain = (ownT1Loc and fntLoc) and U.DistanceBetweenLocations(ownT1Loc, fntLoc) or 8600
    -- Include deep behind-T2 Fountain walk (`>= 1500u` behind Mid T1 toward Fountain at `<= 36% HP` with 0 active regen,
    -- e.g. `auto-20261031-1939` `(2393, 2251)` = `2460u` behind T1) so SF finishes the free Fountain heal
    -- and saves `100g` toward `500g` `item_boots` instead of stranding a Salve in stash!
    local deepWalkingToFountain = (distToOwnT1 >= 1500)
        and (distToFountain <= t1ToFountain - 1350)
        and (hpPctNow <= 0.36)
        and not bot:HasModifier("modifier_flask_healing")
        and not bot:HasModifier("modifier_tango_heal")
    local nearFountain = bot:HasModifier("modifier_fountain_aura_buff")
        or (distToFountain <= 2000)
        or deepWalkingToFountain

    local recoveryBought = false
    -- Only real death agony blocks stash buys (`9069188041.dem` `01:11.6` First Blood Fix:
    -- when the enemy hero JUST DIED (`enemyDeadNow == true`) and no tower is hitting us, `80 HP` is a WON duel,
    -- NOT incoming death — buy post-kill `Salve` BEFORE Section 2 spends FB gold on components!)
    local agonyHp = cfg.AGONY_HP or 115
    local enemyDeadNow = IsEnemyDeadRightNow(bot, state)
    local incomingLethalOrDying = (bot:GetHealth() <= agonyHp
        and ((not enemyDeadNow and bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(1.5))
            or (bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.5))))
    local hasBootsOwned = owns("item_boots") or owns("item_power_treads")
    local dtimeNow = DotaTime()
    local bothBracersDone = (state.currentItemIndex or 1) > 11
    local postDoubleBracerCritical = (not hasBootsOwned)
        and ((state.currentItemIndex or 1) >= 12 or dtimeNow >= 330)
        and (hpPctNow <= 0.32)
    local preBootsSalveCap = (cfg.PRE_BOOTS_SALVES or 2) + (postDoubleBracerCritical and 1 or 0)
    local maxExtraSalves = hasBootsOwned
        and math.min(5, 3 + math.floor(math.max(0, dtimeNow - 300) / 180))
        or preBootsSalveCap
    -- Stick-free Mango fuel curve (`9070559899.dem` `03:00–09:20` 380s zero-Mango drought fix!):
    -- Without Magic Stick, Enchanted Mango is SF's primary coil/zoning fuel; scale smoothly with game clock
    -- (naturally bounded by Dota 2 shop stock `GetItemStockCount("item_enchanted_mango")`).
    local preBootsMangoCap = (cfg.PRE_BOOTS_MANGOES or 4) + (bothBracersDone and 1 or 0)
    local maxExtraMangoes = (hasBootsOwned or dtimeNow >= 270)
        and math.min(10, 5 + math.floor(math.max(0, dtimeNow - 180) / 70))
        or preBootsMangoCap

    local salveBlockedByEqualEnemy = NevermoreEnemyBlocksSalveBuy(bot, state, now)

    -- 1A. Allowed Healing Salve (strictly blocked when enemy has ~equal/lower HP and no Salve!):
    -- Hold gold when `<= 100g` shy of completing a `2x Bracer` component (`currentItemIndex <= 11`) ONLY while
    -- `hpPctNow > 0.38`; at critical `hpPctNow <= 0.38` (`9070149539.dem` `01:33` `36 HP` Fix!), ALWAYS override
    -- the component hold so SF never walks `50s` back to Fountain instead of ordering a `100g` Salve!
    if dtimeNow > 0 and not nearFountain and not incomingLethalOrDying then
        local salveCD = math.max(cfg.RECOVERY_COOLDOWN or 20, cfg.SALVE_CD or 42)
        local hasTangoBuff = bot:HasModifier("modifier_tango_heal")
        local tangoRemHeal = hasTangoBuff and 95 or 0
        local needsSalveDespiteTango = ((missingHP - tangoRemHeal) >= 340)
            or (hpPctNow <= 0.36)
            or (not hasTangoBuff and hpPctNow <= 0.48)
        local nextCoreItem = (state.currentItemIndex <= 11) and PurchaseTable[state.currentItemIndex] or nil
        local nextCoreCost = nextCoreItem and GetItemCost(nextCoreItem) or 0
        local flaskCost = GetItemCost("item_flask")
        local coreHoldBlocksSalve = (nextCoreCost > 0)
            and (hpPctNow > 0.38)
            and (not enemyDeadNow)
            and (gold >= nextCoreCost - 100)
            and (gold < nextCoreCost + flaskCost)
        if not salveBlockedByEqualEnemy
            and not coreHoldBlocksSalve
            and state.extraSalve < maxExtraSalves
            and needsSalveDespiteTango
            and not bot:HasModifier("modifier_flask_healing")
            and not owns("item_flask")
            and now - state.lastSalveBuyTime >= salveCD then
            local cost = flaskCost
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_flask") > 0
            if inStock and gold >= cost then
                local result = bot:ActionImmediate_PurchaseItem("item_flask")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastRecoveryBuy = now
                    state.lastSalveBuyTime = now
                    state.extraSalve = state.extraSalve + 1
                    gold = bot:GetGold()
                end
            end
        end

        -- 1B. Priority Coil-Fuel Mango (Stick-free `v7.5.0` upgrade):
        -- Order BEFORE courier takes 14s to fly out: `< 95` budget during 2x Bracer, `< 145` budget (`< 2` coils!)
        -- after 2x Bracer, plus 2nd Mango in the SAME courier batch when deeply dry (`< 65 MP` & `missing >= 220`)!
        local mangoCD = cfg.MANGO_CD or 20
        local curMana = bot:GetMana() or 0
        local maxMana = bot:GetMaxMana() or 300
        local manaBudget = K.MyManaBudget(bot, true)
        local ownedMangoes = countOwned("item_enchanted_mango")
        local wantUrgentMango = bothBracersDone and (manaBudget < 145) or (manaBudget < 95)
        local bootsAlmostReady = (state.currentItemIndex == 12) and (not hasBootsOwned)
            and (gold >= 440) and (gold < 565) and (curMana >= 75)
        local bracerAlmostReady = (not bothBracersDone) and (nextCoreCost > 0)
            and (gold >= nextCoreCost - 55) and (gold < nextCoreCost + 65) and (curMana >= 75)
        if not recoveryBought
            and wantUrgentMango
            and not bootsAlmostReady
            and not bracerAlmostReady
            and state.extraMango < maxExtraMangoes
            and now - state.lastMangoBuyTime >= mangoCD
            and hpPctNow >= 0.28
            and ownedMangoes == 0 then
            local cost = GetItemCost("item_enchanted_mango")
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_enchanted_mango") > 0
            if inStock and gold >= cost then
                local result = bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastRecoveryBuy = now
                    state.lastMangoBuyTime = now
                    state.extraMango = state.extraMango + 1
                    ownedMangoes = ownedMangoes + 1
                    gold = bot:GetGold()
                    -- Double-Mango Courier Batch when deeply dry (`< 65 MP`, `missing >= 220`, post-2xBracer):
                    -- 1 Mango (`+100 MP`) barely leaves 1 coil after 14s flight; stacking 2 Mangoes restores `+200 MP`!
                    local inStock2 = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_enchanted_mango") > 0
                    local wontDelayBoots = hasBootsOwned or (gold < 440) or (gold >= 565)
                    if bothBracersDone and curMana < 65 and (maxMana - curMana) >= 220
                        and state.extraMango < maxExtraMangoes and inStock2 and wontDelayBoots and gold >= cost then
                        local res2 = bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
                        if res2 == (PURCHASE_ITEM_SUCCESS or 0) then
                            state.recoverySpent = state.recoverySpent + cost
                            state.extraMango = state.extraMango + 1
                            gold = bot:GetGold()
                        end
                    end
                end
            end
        end
    end

    -- 2. STRICT MAIN BUILD PROGRESSION: 2x Bracer FIRST (indices 8..11), THEN Boots (index 12), STRAIGHT into Power Treads!
    -- Buy ALL affordable sequential build items on the SAME tick (`up to 5`) BEFORE dispatching the courier so
    -- First-Blood gold never dispatches `recipe_bracer` alone while stranding `gauntlets` 0.25s later!
    for _ = 1, 5 do
        local nextItem = PurchaseTable[state.currentItemIndex]
        if not nextItem or gold < GetItemCost(nextItem) then
            break
        end
        local result = bot:ActionImmediate_PurchaseItem(nextItem)
        if result == (PURCHASE_ITEM_SUCCESS or 0) then
            state.currentItemIndex = state.currentItemIndex + 1
            gold = bot:GetGold()
        else
            gold = bot:GetGold()
            break
        end
    end

    -- 2B. Post-Bracer / Spare-Gold Proactive Mango & Fallback Sustain (runs AFTER Section 2 so ready core items buy FIRST!)
    if dtimeNow > 0 and not nearFountain and not incomingLethalOrDying and not recoveryBought then
        local mangoCD = math.min(cfg.MANGO_CD or 20, 18)
        local bothBracersOrdered = state.currentItemIndex > 11
        local nextBuild = PurchaseTable[state.currentItemIndex]
        local reserve = bothBracersOrdered and 0 or (nextBuild and GetItemCost(nextBuild) or 0)
        local curMana2 = bot:GetMana() or 0
        local maxMana2 = bot:GetMaxMana() or 300
        local ownedMangoes2 = countOwned("item_enchanted_mango")
        local bootsCloseHold = (state.currentItemIndex == 12) and (not (owns("item_boots") or owns("item_power_treads")))
            and (gold >= 420)
        local allowSecondProactive = bothBracersOrdered and (ownedMangoes2 == 1) and (curMana2 < 85) and ((maxMana2 - curMana2) >= 210)
        if state.extraMango < maxExtraMangoes
            and not bootsCloseHold
            and now - state.lastMangoBuyTime >= mangoCD
            and (K.MyManaBudget(bot, true) < 190 or curMana2 < 145)
            and (maxMana2 - curMana2) >= 115
            and hpPctNow >= 0.28
            and (ownedMangoes2 == 0 or allowSecondProactive) then
            local cost = GetItemCost("item_enchanted_mango")
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_enchanted_mango") > 0
            if inStock and gold >= cost + reserve then
                local result = bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastRecoveryBuy = now
                    state.lastMangoBuyTime = now
                    state.extraMango = state.extraMango + 1
                    gold = bot:GetGold()
                end
            end
        end

        local interval = bothBracersOrdered and 85 or 115
        if not recoveryBought
            and not salveBlockedByEqualEnemy
            and now - state.lastSalveBuyTime >= interval
            and hpPctNow < 0.35
            and not bot:HasModifier("modifier_flask_healing")
            and state.extraSalve < maxExtraSalves
            and not owns("item_flask") then
            local cost = GetItemCost("item_flask")
            local salveReserve = math.max(180, nextBuild and GetItemCost(nextBuild) or 0)
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_flask") > 0
            if inStock and gold >= cost + salveReserve then
                local result = bot:ActionImmediate_PurchaseItem("item_flask")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    state.lastSalveBuyTime = now
                    state.extraSalve = state.extraSalve + 1
                    gold = bot:GetGold()
                end
            end
        end
    end

    -- 3. SMART PERSONAL COURIER (`9069188041.dem` `eid=1462` vs `eid=2094` 5-Courier Fix):
    -- NEVER latch `resolvedCourierSlot` onto a Beastmaster's personal courier delivering `item_ring_of_protection`,
    -- and NEVER rotate `trySlotOffset` onto Beastmasters' personal couriers (which C++ ignores for SF's stash)!
    if GameTime() - state.lastCourierCallTime > 0.35 then
        local pid = bot:GetPlayerID()
        if pid < 0 then return end

        local numCouriers = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
        if numCouriers <= 0 then return end

        local function isBeastmasterCourier(c)
            if not c or c:IsNull() or not c.GetItemInSlot then return false end
            for slot = 0, 8 do
                local okI, it = pcall(c.GetItemInSlot, c, slot)
                if okI and it and it.GetName and it:GetName() == "item_ring_of_protection" then
                    return true
                end
            end
            return false
        end

        local myCourier = nil
        for i = 0, numCouriers - 1 do
            local c = GetCourier(i)
            if c and not c:IsNull() and c.GetPlayerID and c:GetPlayerID() == pid then
                myCourier = c
                state.resolvedCourierSlot = i
                break
            end
        end

        if not myCourier then
            local baseIdx = 0
            if type(GetTeamPlayers) == "function" then
                local okT, teamPlayers = pcall(GetTeamPlayers, bot:GetTeam())
                if okT and type(teamPlayers) == "table" then
                    for index, id in ipairs(teamPlayers) do
                        if id == pid then
                            baseIdx = index - 1
                            break
                        end
                    end
                end
            end
            if baseIdx >= 0 and baseIdx < numCouriers then
                local cBase = GetCourier(baseIdx)
                local cBasePid = (cBase and not cBase:IsNull() and cBase.GetPlayerID) and cBase:GetPlayerID() or -1
                if cBase and not cBase:IsNull() and (cBasePid < 0 or cBasePid == pid)
                    and (not cBase.GetTeam or cBase:GetTeam() == bot:GetTeam())
                    and not isBeastmasterCourier(cBase) then
                    myCourier = cBase
                    state.resolvedCourierSlot = baseIdx
                end
            end
            if not myCourier then
                for i = 0, numCouriers - 1 do
                    local c = GetCourier(i)
                    local cPid = (c and not c:IsNull() and c.GetPlayerID) and c:GetPlayerID() or -1
                    if c and not c:IsNull() and (cPid < 0 or cPid == pid)
                        and (not c.GetTeam or c:GetTeam() == bot:GetTeam())
                        and not isBeastmasterCourier(c) then
                        myCourier = c
                        break
                    end
                end
            end
        end

        if myCourier and not myCourier:IsNull() then
            local state_c = GetCourierState(myCourier)
            local canBurst = COURIER_ACTION_BURST and ((bot.GetLevel and bot:GetLevel()) or 1) >= 10
            local stashItemsCount = 0
            local onlyWardInStash = true
            local urgentCourier = false
            local stashHasFlask = false
            local stashHasGauntlets = false
            local courierHasFlask = false

            for i = 9, 14 do
                local item = bot:GetItemInSlot(i)
                if item then
                    stashItemsCount = stashItemsCount + 1
                    local nm = item:GetName()
                    if nm ~= "item_ward_observer" then
                        onlyWardInStash = false
                    end
                    if nm == "item_gauntlets" then
                        stashHasGauntlets = true
                    end
                    if nm == "item_flask" then
                        stashHasFlask = true
                    end
                    if nm == "item_flask" or nm == "item_boots" or nm == "item_power_treads" or nm == "item_enchanted_mango" then
                        urgentCourier = true
                    end
                end
            end

            local courierItemsCount = 0
            for slot = 0, 8 do
                local okI, cItem = pcall(myCourier.GetItemInSlot, myCourier, slot)
                if okI and cItem then
                    courierItemsCount = courierItemsCount + 1
                    local nm = cItem:GetName()
                    if nm == "item_flask" then courierHasFlask = true end
                    if nm == "item_flask" or nm == "item_boots" or nm == "item_power_treads" or nm == "item_enchanted_mango" then
                        urgentCourier = true
                    end
                end
            end

            local hasStash = stashItemsCount > 0 or (bot.GetStashValue and (bot:GetStashValue() or 0) > 0)
            local hasOnCourier = courierItemsCount > 0 or (bot.GetCourierValue and (bot:GetCourierValue() or 0) > 0)
            local courierDistFnt = fntLoc and GetUnitToLocationDistance(myCourier, fntLoc) or math.huge
            local courierAtShopPickupRange = courierDistFnt <= 1050
            local courierNearBase = courierDistFnt <= 1850
            -- NEVER hold back `gauntlets` when `recipe_bracer` is ALREADY owned or on courier (completes Bracer #1!),
            -- AND never starve SF of `+3 STR (+66 HP, +3 DMG)` for `41-92s` (`auto-20261031-0230` `00:36-02:08` Fix):
            -- batch solo `gauntlets` for at most `18s` while healthy (`> 68% HP`), then dispatch immediately!
            if stashHasGauntlets then
                if not state.gauntletsStashSince or now < state.gauntletsStashSince then
                    state.gauntletsStashSince = now
                end
            else
                state.gauntletsStashSince = nil
            end
            local gauntletsWaitedLong = state.gauntletsStashSince and ((now - state.gauntletsStashSince) >= 18.0) or false
            local gauntletsCompletesBracerNow = stashHasGauntlets and owns("item_recipe_bracer")
            local onlySoloGauntlets = (stashItemsCount == 1) and stashHasGauntlets
                and not gauntletsCompletesBracerNow and not gauntletsWaitedLong
                and (hpPctNow > 0.68) and not hasOnCourier
                and not urgentCourier and (DotaTime() < 300)
            local holdBatch = (stashItemsCount == 1 and onlyWardInStash) or onlySoloGauntlets
            -- Only turn back an outbound `DELIVERING_ITEMS` courier (`needFlaskTurnback`); if `RETURNING_TO_BASE`,
            -- wait until it actually enters `courierAtShopPickupRange` (`<= 1050u`) instead of spamming 28x!
            local needFlaskTurnback = (state_c == COURIER_STATE_DELIVERING_ITEMS)
                and stashHasFlask and not courierHasFlask
                and not U.HasItem(bot, "item_flask") and not bot:HasModifier("modifier_flask_healing")
                and ((hpPctNow <= 0.68 and courierDistFnt <= 3800) or courierDistFnt <= 2200)
            local needShortBatchTurnback = courierNearBase and state_c == COURIER_STATE_DELIVERING_ITEMS
            if hasStash and not holdBatch then
                if state_c == COURIER_STATE_IDLE or state_c == COURIER_STATE_AT_BASE
                    or (state_c == COURIER_STATE_RETURNING_TO_BASE and courierAtShopPickupRange)
                    or needFlaskTurnback or needShortBatchTurnback then
                    bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS)
                    if urgentCourier and canBurst then
                        pcall(bot.ActionImmediate_Courier, bot, myCourier, COURIER_ACTION_BURST)
                    end
                    state.lastCourierCallTime = GameTime()
                end
            elseif hasOnCourier and (state_c == COURIER_STATE_IDLE or state_c == COURIER_STATE_AT_BASE
                or state_c == COURIER_STATE_RETURNING_TO_BASE) then
                bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TRANSFER_ITEMS)
                if urgentCourier and canBurst then
                    pcall(bot.ActionImmediate_Courier, bot, myCourier, COURIER_ACTION_BURST)
                end
                state.lastCourierCallTime = GameTime()
            end
        end
    end
end
