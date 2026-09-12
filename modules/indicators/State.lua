-- modules/indicators/State.lua
--
-- Resolving an action's live state, and doing it without tripping over secret
-- values.
-- See modules/indicators/Metrics.lua for how this directory is laid out.
--
-- SECRET VALUES are the whole difficulty here. In combat, cooldown fields and
-- aura counts can be secret numbers that throw on arithmetic, comparison, or
-- tostring(). Every probe in this file is a HOISTED pcall body handed to pcall
-- by reference with its scratch upvalues set beforehand -- never an inline
-- closure, which would allocate on every button on every pass. Same shape and
-- same reason as core/cooldown/SecretValues.lua.
--
-- "Aura stacks" is deliberately NOT an offerable metric. Measured on live 12.0.7
-- (build 68887), GetAuraApplicationDisplayCount returns a SECRET string in
-- combat for every minDisplayCount, and comparing a secret throws. It gates
-- correctly out of combat, but a rule that only works out of combat is worse
-- than no rule; the machinery that tried has been removed.
--
-- Loaded after Metrics.lua.

local addonName, Wise = ...

local _G = _G

local IR = Wise.IndicatorRules
local RuleMetric = IR.RuleMetric
local IsNumericMetric = IR.IsNumericMetric
local METRIC_IS_NUMERIC = IR.METRIC_IS_NUMERIC
local DEFAULT_METRIC = IR.DEFAULT_METRIC
local IsRetiredRule = IR.IsRetiredRule

-- Hoisted pcall bodies with scratch upvalues, handed to pcall BY REFERENCE so no
-- closure is allocated per button per pass. They MUST live in the same file as
-- the code that sets the scratch values: across a file boundary the setter would
-- write a global while the probe read its own nil local.
local _scdStart, _scdDuration, _scdNow
local function SafeCheckCD()
	if _scdDuration and _scdDuration > 1.5 then
		local rem = (_scdStart + _scdDuration) - _scdNow
		if rem > 0 then
			return rem
		end
	end
	return nil
end

local _usableSpellID
local function SafeCheckUsable()
	return (C_Spell.IsSpellUsable(_usableSpellID)) and true or false
end


-- ---- 12.0.7 display-count machinery ------------------------------------------
-- C_UnitAuras.GetAuraApplicationDisplayCount(unit, auraInstanceID, min, max)
-- returns a STRING meant to be handed straight to FontString:SetText.
--
-- It is used ONLY to display the count. Threshold inference from it is
-- impossible and the machinery that attempted it has been removed: measured on
-- live 12.0.7 (build 68887), in combat the return is a SECRET string for every
-- value of minDisplayCount, and comparing a secret throws. Out of combat it
-- gates correctly, but a rule that only works out of combat is worse than none.
-- Hence "Aura stacks" is no longer an offerable metric; see METRICS above.

-- Cast spell -> buff aura id seeds for spells whose buff has a DIFFERENT id than
-- the cast. Learned mappings are persisted per-action as action.trackedAuraID, so
-- this table only needs the ids we already know. NOTE: the Abundance buff id in
-- the live 12.0.7 client is 207640, CONFIRMED by the Mechanic probe on 2026-07-05
-- ("byTracked=hit apps=12 name=Abundance" out of combat, and 207640 appearing in
-- the full player-aura enumeration). The 203864 id the retired Abundance module
-- used was stale data from an older client and never matched anything here.
local KNOWN_AURA_IDS = {
	[207383] = 207640, -- Abundance
}


-- 12.0 secret-value primitives. `issecretvalue` / `issecrettable` are real
-- client globals (they sit beside issecure/issecurevalue in the API list) and
-- answer "is this readable?" directly, returning a plain boolean. Guarded so a
-- client without them falls back to the round-trip below.
local _issecretvalue = _G.issecretvalue

-- Is this value unreadable? Plain true/false; treats a refusal as secret.
local function IsSecretValue(v)
	if _issecretvalue then
		local ok, res = pcall(_issecretvalue, v)
		if ok then
			return res and true or false
		end
		return true
	end
	return nil -- unknown: caller falls through to the round-trip
end

-- Plain number from a possibly-secret value; nil when truly secret/unreadable.
--
-- WHY NOT tostring alone: tostring(secret) does NOT throw — it returns a SECRET
-- STRING, which then explodes on the next comparison. Three separate probe
-- crashes during the 12.0.7 investigation came from trusting the round-trip to
-- surface secrets. tonumber() is what actually collapses one to nil, and
-- issecretvalue() short-circuits the whole dance when available.
local _ssnVal
local function SecretSafeNumberProbe()
	return tonumber(tostring(_ssnVal))
end
local function SecretSafeNumber(v)
	-- Ask the client first when it can answer.
	local secret = IsSecretValue(v)
	if secret == true then
		return nil
	end
	-- No direct nil/type checks on v here: even `v == nil` is a comparison a true
	-- secret may refuse. The pcall'd round-trip handles every case — nil converts
	-- to nil, plain numbers convert to themselves, secrets either throw (caught)
	-- or fail tonumber (nil).
	_ssnVal = v
	local ok, n = pcall(SecretSafeNumberProbe)
	_ssnVal = nil
	if ok then
		return n
	end
	return nil
end

-- NOTE: no nested-field helper here on purpose. Indexing a SECRET TABLE (e.g.
-- aura.points[1]) throws outright, and issecretvalue cannot catch that — it
-- reports on values, not on whether their container can be indexed. That is
-- what `issecrettable` is for. Wise currently reads no such field, so adding
-- the helper now would be dead code; if one is ever read, guard it with
-- `issecrettable` BEFORE indexing rather than pcall'ing after the fact.

-- REMOVED (2026-08-09): the in-combat aura-slot scan (GetAuraSlots +
-- GetAuraDataBySlot over every player HELPFUL aura, probing the display-count
-- API to identify the tracked instance). Two reasons, either fatal on its own:
--
-- 1. Taint storm. The scan ran on every UNIT_AURA in combat. In content where
--    aura data is secret (M+/raid/PvP) it spread 'Wise' taint into the shared
--    aura records; Blizzard's CooldownViewer — reading the same records off the
--    same UNIT_AURA — then threw "secret value ... while execution tainted by
--    'Wise'" on ITS OWN comparisons (~14k errors captured in one M+10, see
--    !BugGrabber session 9, 2026-08-09). Wise never appeared on those stacks:
--    the pcall wrappers hid Wise's errors but did nothing about the taint.
-- 2. Dead in 12.1. Aura access by index/slot/instanceID hard Lua-errors for
--    addons whenever auras are secret; only by-spellID/by-name lookups survive.
--
-- Consequence: when the by-id/by-name lookups fail in combat (secret context),
-- stacks are UNKNOWN and the count hides. The 12.1 replacement is the sanctioned
-- AuraContainer/AuraButton display path (AddAuraSlot + SetApplicationCount /
-- ApplicationBar): the client renders the live count itself, addon code never
-- touches the data. Do NOT reintroduce enumeration here.

-- Per-spell live state, computed ONCE per pass and shared by every rule on that
-- spell. Read order: learned/seeded buff aura id, then cast id, then name (the
-- name path only resolves out of combat). When EVERY read fails IN combat, the
-- aura may be hidden rather than missing — stacks/buff state become UNKNOWN
-- (stacksKnown=false) instead of a false "0", and the instance handle learned
-- out of combat is exposed for the sanctioned display-count path.
local function ResolveSpellState(spellID, name, action)
	local stacks = 0
	local buffActive = false
	local stacksKnown = true
	local countInstID = nil
	local auraID = (action and tonumber(action.trackedAuraID)) or (spellID and KNOWN_AURA_IDS[spellID])
	local aura = auraID and C_UnitAuras.GetPlayerAuraBySpellID(auraID)
	if not aura and spellID then
		aura = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
	end
	if not aura and name and C_UnitAuras.GetAuraDataBySpellName then
		aura = C_UnitAuras.GetAuraDataBySpellName("player", name)
	end
	if aura then
		buffActive = true
		stacks = SecretSafeNumber(aura.applications) or SecretSafeNumber(aura.charges) or 1
		if action then
			if not action.trackedAuraID then
				local id = SecretSafeNumber(aura.spellId)
				if id then
					action.trackedAuraID = id
				end
			end
		end
	elseif InCombatLockdown() then
		-- Every lookup above failed in combat: the aura's identifying fields are
		-- secret, or the aura is genuinely absent — undecidable from here. Stacks
		-- become UNKNOWN (stacksKnown=false) and the corner count hides. We do NOT
		-- hunt for the instance by enumerating aura slots (see the removal note
		-- above ResolveSpellState), and a handle learned out of combat is stale by
		-- the first sample (instance ids rotate on combat entry), so countInstID
		-- stays nil.
		stacksKnown = false
	end
	local charges = 0
	if spellID and C_Spell and C_Spell.GetSpellCharges then
		local info = C_Spell.GetSpellCharges(spellID)
		if info then
			-- Charge counts are secret in combat; a raw secret stored here would
			-- blow up the bare comparisons in EvaluateNumericRule. (No direct nil
			-- check on the field — SecretSafeNumber handles nil and secrets alike.)
			charges = SecretSafeNumber(info.currentCharges) or 0
		end
	end
	local known = spellID and Wise:IsActionKnown("spell", spellID) or false
	local onCooldown = spellID and Wise:IsActionOnCooldown("spell", spellID, action) or false
	-- Seconds until usable again (to schedule a precise off-cooldown wake — see below)
	-- plus the cooldown START time, which we use to detect a FRESH cooldown between
	-- samples: when a spell is recast (or proc-reset) the start time advances, telling
	-- us a new available-edge is coming even if our sampling never caught the trough.
	local cdRemaining, cdStart = nil, 0
	if spellID and C_Spell and C_Spell.GetSpellCooldown then
		local ci = C_Spell.GetSpellCooldown(spellID)
		if ci and ci.startTime then
			cdStart = ci.startTime
			_scdStart, _scdDuration, _scdNow = ci.startTime, ci.duration, GetTime()
			local ok, rem = pcall(SafeCheckCD)
			if ok and rem then
				cdRemaining = rem
			end
		end
	end
	-- "Usable right now" via the API that also accounts for resources (rage/etc.), not
	-- just cooldown — so a rage-gated spell isn't reported "available" when it can't
	-- actually be cast. IsSpellUsable can return a secret in combat, and even taking
	-- the truthiness of a secret can throw — probe inside a pcall'd closure and fall
	-- back to the cooldown-only check when the read is refused or the API is missing.
	local usable
	local probedUsable = false
	if spellID and C_Spell and C_Spell.IsSpellUsable then
		_usableSpellID = spellID
		local ok, u = pcall(SafeCheckUsable)
		_usableSpellID = nil
		if ok then
			usable = u
			probedUsable = true
		end
	end
	if not probedUsable then
		usable = known and not onCooldown
	end
	return {
		stacks = stacks,
		stacksKnown = stacksKnown,
		countInstID = countInstID,
		charges = charges,
		buffActive = buffActive,
		onCooldown = onCooldown,
		cdRemaining = cdRemaining,
		cdStart = cdStart,
		available = known and usable,
	}
end

-- Does one rule match the current spell state?
local function RuleMatches(rule, st)
	if IsRetiredRule(rule) then
		return false
	end
	local metric = RuleMetric(rule)
	if metric == "charges" then
		return Wise:EvaluateNumericRule(st.charges, rule.operator, rule.value)
	elseif metric == "available" then
		return st.available == true
	elseif metric == "cooldown" then
		return st.onCooldown == true
	elseif metric == "buff_active" then
		-- buffActive=true is provable even for a hidden aura (instance read hit);
		-- when state is unknown (hidden, no handle) this stays false — unprovable.
		return st.buffActive == true
	elseif metric == "buff_missing" then
		if not st.stacksKnown and not st.buffActive then
			return false -- hidden-vs-missing undecidable: don't claim "missing"
		end
		return st.buffActive == false
	end
	return false
end

-- Among all matching rules, the MOST SPECIFIC wins: for a numeric metric that's the
-- rule whose threshold is closest to the live count (so >=8 beats >=3 at 8 stacks —
-- this is what makes a high-stack sound/color win over a broad low rule, the original
-- Abundance behavior). Boolean metrics are treated as distance 0 (a precise state).
-- Ties fall back to list order, so the up/down arrows still give a deterministic
-- override.
local function RuleDistance(rule, st)
	local metric = RuleMetric(rule)
	if metric == "charges" then
		return math.abs(st.charges - (tonumber(rule.value) or 0))
	end
	return 0
end

local function FindMatchedRule(rules, st)
	if not rules then
		return nil
	end
	local best, bestDist
	for _, rule in ipairs(rules) do
		if RuleMatches(rule, st) then
			local dist = RuleDistance(rule, st)
			if not best or dist < bestDist then
				best, bestDist = rule, dist
			end
		end
	end
	return best
end

-- Resolve an entry's current (matchedRule, spellState). Honors the node's macro
-- condition (e.g. [combat]) — when it isn't met the indicator is inert (no match →
-- no border/sound), so the cue tracks the slot's own gating. Returns (nil, nil)
-- when gated; callers must treat a nil state as "no data this pass".
local function ResolveEntry(entry)
	if entry.condition and Wise.EvalConditionExact and not Wise:EvalConditionExact(entry.condition) then
		return nil, nil
	end
	local st = ResolveSpellState(entry.spellID, entry.name, entry.action)
	return FindMatchedRule(entry.rules, st), st
end

-- Best default metric for a NEW rule on this action, so the user rarely has to
-- change it: a charge spell → "charges"; everything else (most spells, e.g. Raze)
-- → "available", which is the universally-meaningful "off cooldown / usable"
-- state and reads correctly in combat. The metric is still
-- a per-rule dropdown the user can change.
local function DefaultMetricForAction(action)
	if not action or action.type ~= "spell" then
		return DEFAULT_METRIC
	end
	local sid = tonumber(action.value)
	if not sid then
		local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(action.value)
		sid = info and info.spellID
	end
	if not sid then
		return "available"
	end
	-- NOTE: no stacking-aura branch here any more. "Aura stacks" was withdrawn as
	-- a metric (it cannot be evaluated in combat), so suggesting it would hand the
	-- user a rule that never fires.
	-- Multi-charge spell → charges is the natural numeric metric.
	if C_Spell and C_Spell.GetSpellCharges then
		local ci = C_Spell.GetSpellCharges(sid)
		if ci and (ci.maxCharges or 0) > 1 then
			return "charges"
		end
	end
	return "available"
end


-- Published for Render.lua, Index.lua and Paint.lua.
IR.ResolveEntry = ResolveEntry
IR.DefaultMetricForAction = DefaultMetricForAction
