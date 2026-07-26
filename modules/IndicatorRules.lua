local addonName, Wise = ...

-- Per-action indicator rules -------------------------------------------------
-- Generalises the old global, Resto-only "Abundance Colors, Glows & Sounds" into
-- a PER-ACTION feature: any action can carry `action.indicatorRules` — a list of
-- { operator, value, color, glow, sound } rows matched against that action's own
-- live aura-stack count. The matched rule colors the button border, optionally
-- glows it, shows the count, and fires an Oxed sound on the rising edge. Rules are
-- authored in the slot configurator's node properties window (alongside Conditions,
-- Availability, Audio Cue). Shared sound/dropdown helpers come from modules/Audio.lua.

local tinsert = table.insert
local OXED_SOUND_NONE = Wise.OXED_SOUND_NONE

-- Bumped on behavior changes so live diagnostics can confirm which revision the
-- client actually loaded (see the abundance-combat-probe in MechanicQueue).
Wise.INDICATOR_RULES_REV = 4

local BOLD_COLORS = {
	{ name = "Red", r = 1, g = 0, b = 0 },
	{ name = "Green", r = 0, g = 1, b = 0 },
	{ name = "Blue", r = 0, g = 0, b = 1 },
	{ name = "Yellow", r = 1, g = 1, b = 0 },
	{ name = "Orange", r = 1, g = 0.5, b = 0 },
	{ name = "Purple", r = 0.6, g = 0.1, b = 0.9 },
	{ name = "Cyan", r = 0, g = 1, b = 1 },
	{ name = "Magenta", r = 1, g = 0, b = 1 },
	{ name = "White", r = 1, g = 1, b = 1 },
	{ name = "Pink", r = 1, g = 0.5, b = 0.7 },
}

local function GetColorRGB(colorName)
	for _, c in ipairs(BOLD_COLORS) do
		if c.name == colorName then
			return c.r, c.g, c.b
		end
	end
	return 1, 1, 1
end

-- What a rule WATCHES. Numeric metrics use operator+value; boolean metrics match
-- when their state is true (no operator/value). Order here is the dropdown order.
-- `numeric` decides whether the operator+value controls show in the UI.
--
-- "Aura stacks" is DELIBERATELY ABSENT. Under 12.0.7 combat secrecy a stack count
-- is displayable but not inspectable (see the Combat Aura Secrecy section in
-- AGENTS.md), so a stacks-driven colour/glow/sound can never fire in combat —
-- which is the only time it would matter. Offering it produces an indicator that
-- silently does nothing in a raid, so the option is withdrawn rather than shipped
-- broken. The stack COUNT still displays on the button corner; only branching on
-- it is gone. Everything cooldown- or usability-derived is unaffected: those read
-- fine in combat.
local METRICS = {
	{ key = "charges", label = "Charges", numeric = true },
	{ key = "available", label = "Available (off CD)", numeric = false },
	{ key = "cooldown", label = "On cooldown", numeric = false },
	{ key = "buff_active", label = "Buff active", numeric = false },
	{ key = "buff_missing", label = "Buff missing", numeric = false },
}
local METRIC_LABELS = {}
local METRIC_IS_NUMERIC = {}
for _, m in ipairs(METRICS) do
	METRIC_LABELS[m.key] = m.label
	METRIC_IS_NUMERIC[m.key] = m.numeric
end
local DEFAULT_METRIC = "available"

-- Rules authored against the withdrawn "stacks" metric — either explicitly, or
-- as the legacy shape that carried NO metric field and meant stacks by default.
-- These must go INERT, not fall through to DEFAULT_METRIC: silently re-reading
-- an "Abundance <= 2" rule as "available <= 2" would colour the button off an
-- unrelated condition, which is worse than the rule simply not firing.
local function IsRetiredRule(rule)
	local m = rule.metric
	if m == nil or m == "stacks" then
		return true
	end
	return METRIC_LABELS[m] == nil
end

local function RuleMetric(rule)
	local m = rule.metric
	if m and METRIC_LABELS[m] then
		return m
	end
	return DEFAULT_METRIC
end

local function IsNumericMetric(metricKey)
	return METRIC_IS_NUMERIC[metricKey] == true
end

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

local _recastCdStart, _recastLastCdStart
local function SafeCheckRecast()
	return _recastCdStart > _recastLastCdStart
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

-- Find the tracked aura's CURRENT auraInstanceID by live enumeration.
--
-- In combat spellId is secret, so the aura cannot be identified by id. What IS
-- available: auraInstanceID is plain even in combat, and the aura's SLOT is
-- stable for the lifetime of a given application. So we remember which slot the
-- aura occupied when we last identified it out of combat, and in combat we read
-- the instance id out of that same slot.
--
-- This is best-effort by design. A slot can be reused by a different aura, which
-- would point the display-count call at the wrong aura — the cost is a wrong or
-- absent number in the button corner, never a wrong CAST (nothing here feeds the
-- secure path). It self-corrects on the next out-of-combat pass.
-- Last known instance id per action, used ONLY to prefer the same aura instance
-- across passes when several candidates match. Never trusted on its own.
local lastAuraInstance = setmetatable({}, { __mode = "k" })

local _slotUnit, _slotIdx
local function ReadSlotAuraProbe()
	return C_UnitAuras.GetAuraDataBySlot(_slotUnit, _slotIdx)
end

local _dcUnit, _dcInst
local function DisplayCountProbe()
	-- min=1/max=99: "does this instance have a count at all". The RETURN is a
	-- possibly-secret string and must never be compared — only its presence is
	-- used, and presence is what identifies a stacking aura.
	return C_UnitAuras.GetAuraApplicationDisplayCount(_dcUnit, _dcInst, 1, 99)
end
local function InstanceHasCount(inst)
	if not (C_UnitAuras.GetAuraApplicationDisplayCount and inst) then
		return false
	end
	_dcUnit, _dcInst = "player", inst
	local ok, c = pcall(DisplayCountProbe)
	_dcUnit, _dcInst = nil, nil
	-- type() is safe on a secret; == is not.
	return ok and type(c) ~= "nil"
end

-- Find the tracked aura's CURRENT auraInstanceID by scanning the live aura list.
--
-- Re-scans EVERY pass rather than caching a slot. Abundance is reapplied
-- constantly in combat, and each reapplication is a NEW aura instance in a
-- possibly different slot — a slot learned once goes stale, which showed up as a
-- counter that could fall but never climb.
--
-- Identification without spellId (secret in combat): take player-cast helpful
-- auras whose instance the display-count API will answer for. Only a stacking
-- aura has a display count, which narrows the field sharply. Where several
-- qualify, prefer the instance we used last pass so the number stays stable.
local function ResolveLiveAuraInstance(spellID, action)
	if not (C_UnitAuras and C_UnitAuras.GetAuraSlots and C_UnitAuras.GetAuraDataBySlot) then
		return nil
	end
	local previous = action and lastAuraInstance[action]
	local slots = { C_UnitAuras.GetAuraSlots("player", "HELPFUL") }
	local firstMatch = nil
	for i = 2, #slots do
		_slotUnit, _slotIdx = "player", slots[i]
		local ok, aura = pcall(ReadSlotAuraProbe)
		_slotUnit, _slotIdx = nil, nil
		if ok and aura then
			-- These two flags stay PLAIN in combat (verified in live aura dumps),
			-- so they can be tested directly.
			local mine = (aura.isFromPlayerOrPlayerPet == true)
			local inst = mine and SecretSafeNumber(aura.auraInstanceID) or nil
			if inst and InstanceHasCount(inst) then
				if inst == previous then
					return inst -- same instance as last pass: strongest signal
				end
				if not firstMatch then
					firstMatch = inst
				end
			end
		end
	end
	if firstMatch and action then
		lastAuraInstance[action] = firstMatch
	end
	return firstMatch
end

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
			-- Record the instance we positively identified here (spellId is
			-- readable on this path). Combat uses it only as a tie-breaker when
			-- several candidates match — never as the sole handle, since a new
			-- application means a new instance id.
			local inst = SecretSafeNumber(aura.auraInstanceID)
			if inst then
				lastAuraInstance[action] = inst
			end
		end
	elseif InCombatLockdown() then
		-- In combat the aura is NOT hidden — it still enumerates. Its identifying
		-- fields (spellId/name/applications) are secret, which is why every lookup
		-- above failed, but auraInstanceID stays PLAIN and readable. So the handle
		-- must be read LIVE from the current enumeration.
		--
		-- Do NOT use a handle learned out of combat: instance ids rotate on combat
		-- entry (measured — an id captured pre-pull is stale by the first sample).
		-- Stacks stay UNKNOWN either way: the count is displayable via SetText but
		-- not readable, so never claim a number here.
		stacksKnown = false
		countInstID = ResolveLiveAuraInstance(spellID, action)
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

-- =========================================================================
-- UI: rendered inside the node properties panel (SlotConfigurator.lua).
-- Reads/writes action.indicatorRules. `commit` re-exports + re-renders.
-- =========================================================================
function Wise:RenderIndicatorRules(panel, action, y, commit)
	commit = commit or function() end
	if type(action) ~= "table" then
		return y
	end
	action.indicatorRules = action.indicatorRules or {}
	local rules = action.indicatorRules

	local function changed()
		Wise:RebuildIndicatorRules()
		Wise:ScheduleIndicatorUpdate()
		commit()
	end

	y = y - 10
	local divider = panel:CreateTexture(nil, "OVERLAY")
	divider:SetColorTexture(0.3, 0.3, 0.3, 0.5)
	divider:SetHeight(1)
	divider:SetPoint("TOPLEFT", 10, y)
	divider:SetPoint("RIGHT", -10, y)
	tinsert(panel.controls, divider)

	y = y - 15
	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 10, y)
	title:SetText("|cffffcc00Colors, Glows & Sounds|r")
	tinsert(panel.controls, title)

	y = y - 14
	local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	sub:SetPoint("TOPLEFT", 10, y)
	sub:SetWidth(240)
	sub:SetJustifyH("LEFT")
	sub:SetText("Color/glow this button and play a sound based on what each rule watches.")
	tinsert(panel.controls, sub)

	local colorNames = {}
	for _, c in ipairs(BOLD_COLORS) do
		tinsert(colorNames, c.name)
	end
	local metricNames = {}
	for _, m in ipairs(METRICS) do
		tinsert(metricNames, m.label)
	end

	for i, rule in ipairs(rules) do
		local metricKey = RuleMetric(rule)
		local numeric = IsNumericMetric(metricKey)

		-- Row 1: which metric this rule watches, + reorder/delete buttons.
		y = y - 26
		local metricBtn = Wise:CreateSimpleDropdown(
			panel,
			130,
			20,
			METRIC_LABELS[metricKey],
			metricNames,
			function(label)
				for _, m in ipairs(METRICS) do
					if m.label == label then
						rule.metric = m.key
						break
					end
				end
				changed()
				Wise:RefreshPropertiesPanel() -- show/hide the operator+value row
			end
		)
		metricBtn:SetPoint("TOPLEFT", 10, y)
		if Wise.AddTooltip then
			Wise:AddTooltip(
				metricBtn,
				"What this rule watches on this spell (charges, availability, buff state)."
			)
		end

		local upBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		upBtn:SetSize(16, 20)
		upBtn:SetPoint("TOPLEFT", 178, y)
		upBtn:SetText("^")
		if i == 1 then
			upBtn:Disable()
		else
			upBtn:SetScript("OnClick", function()
				rules[i], rules[i - 1] = rules[i - 1], rules[i]
				changed()
				Wise:RefreshPropertiesPanel()
			end)
		end
		tinsert(panel.controls, upBtn)

		local downBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		downBtn:SetSize(16, 20)
		downBtn:SetPoint("TOPLEFT", 196, y)
		downBtn:SetText("v")
		if i == #rules then
			downBtn:Disable()
		else
			downBtn:SetScript("OnClick", function()
				rules[i], rules[i + 1] = rules[i + 1], rules[i]
				changed()
				Wise:RefreshPropertiesPanel()
			end)
		end
		tinsert(panel.controls, downBtn)

		local delBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		delBtn:SetSize(16, 20)
		delBtn:SetPoint("TOPLEFT", 214, y)
		delBtn:SetText("x")
		local btnText = delBtn:GetFontString()
		if btnText then
			btnText:SetTextColor(1, 0.2, 0.2)
		end
		delBtn:SetScript("OnClick", function()
			table.remove(rules, i)
			changed()
			Wise:RefreshPropertiesPanel()
		end)
		tinsert(panel.controls, delBtn)

		-- Row 2 (numeric metrics only): operator + threshold value.
		if numeric then
			y = y - 24
			local opBtn = Wise:CreateSimpleDropdown(
				panel,
				44,
				20,
				rule.operator or ">=",
				{ "<", "=", ">", "<=", ">=", "!=" },
				function(val)
					rule.operator = val
					changed()
				end
			)
			opBtn:SetPoint("TOPLEFT", 24, y)

			local valEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
			valEdit:SetSize(40, 20)
			valEdit:SetPoint("TOPLEFT", 76, y)
			valEdit:SetAutoFocus(false)
			valEdit:SetText(tostring(rule.value or 0))
			valEdit:SetNumeric(true)
			valEdit:SetScript("OnTextChanged", function(self)
				rule.value = tonumber(self:GetText()) or 0
			end)
			valEdit:SetScript("OnEditFocusLost", changed)
			valEdit:SetScript("OnEnterPressed", function(self)
				self:ClearFocus()
			end)
			valEdit:SetScript("OnEscapePressed", function(self)
				self:SetText(tostring(rule.value or 0))
				self:ClearFocus()
			end)
			tinsert(panel.controls, valEdit)
		end

		-- Row 3: color + glow (what to do when the rule matches).
		y = y - 24
		local colorBtn = Wise:CreateSimpleDropdown(panel, 70, 20, rule.color, colorNames, function(val)
			rule.color = val
			changed()
		end)
		colorBtn:SetPoint("TOPLEFT", 24, y)

		local glowCb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		glowCb:SetSize(20, 20)
		glowCb:SetPoint("TOPLEFT", 104, y)
		glowCb:SetChecked(rule.glow == true)
		glowCb:SetScript("OnClick", function(self)
			rule.glow = self:GetChecked() and true or false
			changed()
		end)
		tinsert(panel.controls, glowCb)
		local glowText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		glowText:SetPoint("LEFT", glowCb, "RIGHT", 2, 0)
		glowText:SetText("Glow")
		tinsert(panel.controls, glowText)

		-- Row 4: sound + preview.
		y = y - 22
		local soundLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		soundLabel:SetPoint("TOPLEFT", 24, y - 3)
		soundLabel:SetText("Sound")
		tinsert(panel.controls, soundLabel)

		local soundBtn = Wise:CreateSoundDropdown(panel, 150, 20, rule.sound, function(val)
			rule.sound = val
			-- No visual refresh here: picking a sound shouldn't re-fire the transition gate.
			commit()
		end)
		soundBtn:SetPoint("TOPLEFT", 52, y)
		if Wise.AddTooltip then
			Wise:AddTooltip(
				soundBtn,
				"Play an Oxed Hub sound when this condition is first met. Hover a sound to preview it."
			)
		end

		local previewBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		previewBtn:SetSize(24, 20)
		previewBtn:SetPoint("TOPLEFT", 206, y)
		previewBtn:SetText(">")
		previewBtn:SetScript("OnClick", function()
			Wise:PlayOxedSound(rule.sound)
		end)
		if Wise.AddTooltip then
			Wise:AddTooltip(previewBtn, "Preview the selected sound.")
		end
		tinsert(panel.controls, previewBtn)
	end

	y = y - 24
	local addBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	addBtn:SetSize(100, 22)
	addBtn:SetPoint("TOPLEFT", 10, y)
	addBtn:SetText("Add Rule")
	addBtn:SetScript("OnClick", function()
		local metric = DefaultMetricForAction(action)
		tinsert(rules, { metric = metric, operator = ">=", value = 1, color = "Green", glow = false, sound = "" })
		changed()
		Wise:RefreshPropertiesPanel()
	end)
	tinsert(panel.controls, addBtn)
	y = y - 26

	return y
end

-- =========================================================================
-- Runtime: spellID -> rules map + per-button border/glow/count + sound on edge.
-- =========================================================================

-- spellID -> { rules, action, spellID, name }, built from every graph node carrying
-- indicatorRules this character is allowed to use. `name` lets us (a) match a button
-- whose resolved spellID is nil (a /cast Abundance custom_macro — the name doesn't
-- resolve by C_Spell so meta.baseSpellID is nil) and (b) read the buff by NAME, since
-- the aura a spell APPLIES often has a different id than the cast spell (Abundance
-- casts 207383 but the buff aura is 203864). Rebuilt on spec/login/config change.
local rulesBySpell = {}
-- lowercase spell name -> the same entry, for name-based button matching.
local rulesByName = {}
-- entry -> last matched rule (transition gate so sound fires once per entry).
local lastMatchByEntry = {}
-- entry -> cooldown START time we last saw. A change means the spell was recast (or
-- proc-reset), so a held "available" match should re-fire on the new cycle even if
-- our sampling never observed the on-cooldown trough between casts.
local lastCdStartByEntry = {}

-- Returns spellID, spellName for an action's spell (resolving name<->id either way).
local function ActionSpell(action)
	if not action or action.type ~= "spell" then
		return nil, nil
	end
	local n = tonumber(action.value)
	if n then
		local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(n)
		return n, info and info.name or action.name
	end
	local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(action.value)
	if info then
		return info.spellID, info.name
	end
	return nil, action.value
end

function Wise:RebuildIndicatorRules()
	wipe(rulesBySpell)
	wipe(rulesByName)
	if not WiseDB or not WiseDB.groups then
		return
	end
	for _, group in pairs(WiseDB.groups) do
		if type(group.actions) == "table" then
			for _, states in pairs(group.actions) do
				if type(states) == "table" then
					local graph = states.graph
					if graph and type(graph.nodes) == "table" then
						for _, node in ipairs(graph.nodes) do
							local a = node.action
							if
								a
								and type(a.indicatorRules) == "table"
								and #a.indicatorRules > 0
								and Wise:IsActionAllowed(a)
							then
								local sid, sname = ActionSpell(a)
								if sid then
									-- Carry the node's macro condition (e.g. [combat]) so the indicator
									-- only fires while that condition is met — matching the slot's own
									-- gating, so the availability sound doesn't blare out of combat.
									local cond = node.condition
									if type(cond) ~= "string" or cond == "" then
										cond = nil
									end
									local entry = {
										rules = a.indicatorRules,
										action = a,
										spellID = sid,
										name = sname,
										condition = cond,
									}
									rulesBySpell[sid] = entry
									if sname then
										rulesByName[sname:lower()] = entry
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- Seed the transition gate to each entry's CURRENT match WITHOUT firing, so a
	-- rebuild (login / zone / spec / config edit) never blares the sound just because
	-- the spell happens to already be available/matched. Sound then fires only on a
	-- genuine match change during play. wipe the gate tables first — old entry tables
	-- are gone after the rebuild above.
	wipe(lastMatchByEntry)
	wipe(lastCdStartByEntry)
	for _, entry in pairs(rulesBySpell) do
		local matched, st = ResolveEntry(entry)
		lastMatchByEntry[entry] = matched
		lastCdStartByEntry[entry] = (st and st.cdStart) or 0
	end
end

-- Resolve the ruled entry that applies to a button. Match by the button's tracked
-- spellID first, then by spell NAME — a /cast Abundance custom_macro button has no
-- resolved spellID (the name doesn't resolve via C_Spell), so fall back to scanning
-- its live macro text / action value for a ruled spell name.
local function StateEntry(state)
	if type(state) ~= "table" then
		return nil
	end
	if state.type == "spell" and state.value then
		local sid = tonumber(state.value)
		if sid and rulesBySpell[sid] then
			return rulesBySpell[sid]
		end
		if type(state.value) == "string" then
			local e = rulesByName[state.value:lower()]
			if e then
				return e
			end
		end
	end
	if next(rulesByName) and type(state.macroText) == "string" then
		local lower = state.macroText:lower()
		for nameLower, entry in pairs(rulesByName) do
			if lower:find(nameLower, 1, true) then
				return entry
			end
		end
	end
	return nil
end

local function ButtonEntry(meta)
	if not meta then
		return nil
	end
	local sid = meta.baseSpellID or meta.spellID
	if sid and rulesBySpell[sid] then
		return rulesBySpell[sid]
	end
	-- Name-based fallback for custom_macro / unresolved-spell buttons.
	if next(rulesByName) then
		if meta.actionType == "spell" and type(meta.actionValue) == "string" then
			local e = rulesByName[meta.actionValue:lower()]
			if e then
				return e
			end
		end
		local mt = meta.actionData and meta.actionData.macroText
		if mt then
			local lower = mt:lower()
			for nameLower, entry in pairs(rulesByName) do
				if lower:find(nameLower, 1, true) then
					return entry
				end
			end
		end
	end
	-- A multi-state slot displays only ONE state at a time (meta.actionData), but
	-- the ruled action may live on a sibling state. E.g. AtMouse compiles to a
	-- "[combat] Survival Instincts" step plus an "Abundance" step: entering combat
	-- flips the shown state to the first, and matching only the active state would
	-- detach the Abundance indicator exactly when its stacks matter. Scan every
	-- state so the indicator stays bound to the slot that can cast the spell.
	if type(meta.states) == "table" then
		for _, state in ipairs(meta.states) do
			local e = StateEntry(state)
			if e then
				return e
			end
		end
	end
	return nil
end

local function ApplyBorder(b, matchedRule)
	if not b then
		return
	end
	if not matchedRule then
		if b.indicatorBorder then
			b.indicatorBorder:Hide()
		end
		-- "rule" owner: releases only this engine's claim on the glow — a proc
		-- glow owned by UpdateButtonUsability stays lit (no per-pass teardown).
		Wise:HideOverlayGlow(b, "rule")
		return
	end
	if not b.indicatorBorder then
		b.indicatorBorder = b:CreateTexture(nil, "BORDER")
		b.indicatorBorder:SetTexture("Interface\\Buttons\\WHITE8x8")
	end
	local width, height = b:GetSize()
	b.indicatorBorder:SetSize(width + 4, height + 4)
	b.indicatorBorder:SetPoint("CENTER", b, "CENTER", 0, 0)
	-- Match the button's shape mask (circular/hex/etc.) so the outline follows it.
	if b.styleMask then
		if not b.indicatorBorderMask then
			b.indicatorBorderMask = b:CreateMaskTexture()
		end
		b.indicatorBorderMask:SetTexture(b.styleMask:GetTexture(), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
		b.indicatorBorderMask:SetAllPoints(b.indicatorBorder)
		b.indicatorBorder:AddMaskTexture(b.indicatorBorderMask)
	elseif b.indicatorBorderMask then
		b.indicatorBorder:RemoveMaskTexture(b.indicatorBorderMask)
	end
	local r, g, bc = GetColorRGB(matchedRule.color)
	b.indicatorBorder:SetVertexColor(r, g, bc, 1)
	b.indicatorBorder:Show()
	if matchedRule.glow then
		Wise:ShowOverlayGlow(b, nil, "rule")
	else
		Wise:HideOverlayGlow(b, "rule")
	end
end

-- Hoisted closure for the secret-count display path (fetch + SetText must share
-- one pcall: any step may refuse a secret value).
--
-- NOTE: `c == nil` here would be a bug, not a guard. For a secret return the
-- comparison itself throws, the pcall swallows it, and the count silently hides
-- — the exact opposite of what the check intends. type() is safe on secrets
-- (it reports the underlying type without reading the value), so it is the only
-- way to reject a genuine absence while letting a secret through to SetText.
-- Measured against live 12.0.7 build 68887; see the StacksAtLeast header.
local _secretCountFS, _secretCountInst
local function SecretCountProbe()
	local c = C_UnitAuras.GetAuraApplicationDisplayCount("player", _secretCountInst, 1)
	if type(c) == "nil" then
		error("no-display-count", 0)
	end
	_secretCountFS:SetText(c)
end

local function ApplyCount(b, count, instID)
	if not b then
		return
	end
	if not b.indicatorCount then
		b.indicatorCount = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		b.indicatorCount:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
		b.indicatorCount:SetJustifyH("RIGHT")
	end
	if count and count > 0 then
		b.indicatorCount:SetText(tostring(count))
		b.indicatorCount:Show()
	elseif instID and C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
		-- 12.0.7 sanctioned display path for a combat-hidden aura: the count string
		-- may be SECRET — readable by nothing, but designed to be handed straight to
		-- FontString:SetText. Fetch + set inside ONE pcall'd closure; any refusal
		-- (aura gone, API blocked, SetText rejecting the value) falls back to hiding
		-- the count — exactly the old behavior.
		_secretCountFS, _secretCountInst = b.indicatorCount, instID
		local ok = pcall(SecretCountProbe)
		_secretCountFS, _secretCountInst = nil, nil
		if ok then
			b.indicatorCount:Show()
		else
			b.indicatorCount:Hide()
		end
	else
		b.indicatorCount:Hide()
	end
end

local function ClearButton(b)
	if not b then
		return
	end
	if b.indicatorBorder then
		b.indicatorBorder:Hide()
	end
	if b.indicatorCount then
		b.indicatorCount:Hide()
	end
	Wise:HideOverlayGlow(b, "rule")
end

-- One-shot wake-up that fires shortly after the soonest tracked cooldown expires,
-- so "available" transitions are caught without an event. We keep at most one timer
-- pending and only (re)arm it for an EARLIER expiry — a later pass with a longer
-- cooldown shouldn't push the wake-up back. The timer just re-runs the engine.
local cdWakeAt = nil
local function ScheduleCooldownWake(remaining)
	if not remaining or remaining <= 0 then
		return
	end
	local wakeAt = GetTime() + remaining + 0.05
	if cdWakeAt and wakeAt >= cdWakeAt then
		return -- an equal/earlier wake is already pending
	end
	cdWakeAt = wakeAt
	C_Timer.After(remaining + 0.05, function()
		cdWakeAt = nil
		Wise:ScheduleIndicatorUpdate()
	end)
end

function Wise:UpdateIndicatorRules()
	if not Wise.frames or not Wise.buttonMeta then
		return
	end

	-- Sound transition gate is per-entry and must fire exactly once per pass, so
	-- resolve each ruled spell's state + matched rule up front (before the per-button
	-- visual loop, which can touch a spell's buttons more than once via clones).
	local seen = {}
	local soonestCd = nil
	for _, entry in pairs(rulesBySpell) do
		local matched, st = ResolveEntry(entry)
		local cdRemaining = st and st.cdRemaining
		local cdStart = st and st.cdStart
		entry._matched = matched
		-- Corner-number inputs: a readable count when we have one, otherwise the
		-- instance handle so ApplyCount can route through the sanctioned
		-- display-count API (12.0.7 hides the aura itself in combat).
		entry._stacks = (st and st.stacksKnown and st.stacks) or 0
		entry._countInstID = st and not st.stacksKnown and st.countInstID or nil
		seen[entry] = true
		-- Track the soonest cooldown expiry so we can wake exactly when a spell comes
		-- off cooldown (SPELL_UPDATE_COOLDOWN doesn't reliably fire at cooldown END).
		if cdRemaining and (not soonestCd or cdRemaining < soonestCd) then
			soonestCd = cdRemaining
		end
		-- Fire when the matched rule CHANGES, OR when the rule is still matched but the
		-- spell was recast/proc-reset since we last fired (its cooldown start advanced).
		-- The latter catches a fast available→cast→available cycle whose on-cooldown
		-- trough our sampling collapsed — without it, a frequently-recast spell like
		-- Raze only sounds on its first availability, then stays "matched" and silent.
		cdStart = cdStart or 0
		local lastStart = lastCdStartByEntry[entry] or 0
		local recast = false
		if matched then
			_recastCdStart, _recastLastCdStart = cdStart, lastStart
			local ok, res = pcall(SafeCheckRecast)
			if ok then
				recast = res
			end
		end
		if matched ~= lastMatchByEntry[entry] or recast then
			lastMatchByEntry[entry] = matched
			lastCdStartByEntry[entry] = cdStart
			if matched and matched.sound and matched.sound ~= OXED_SOUND_NONE then
				Wise:PlayOxedSound(matched.sound)
			end
		else
			-- Keep the latest cooldown start even when not firing, so a later genuine
			-- recast is measured against the correct baseline.
			lastCdStartByEntry[entry] = cdStart
		end
	end
	-- Drop transition state for entries that no longer exist (rebuilt away).
	for entry in pairs(lastMatchByEntry) do
		if not seen[entry] then
			lastMatchByEntry[entry] = nil
			lastCdStartByEntry[entry] = nil
		end
	end

	-- Schedule a single wake-up just after the soonest cooldown finishes, so the
	-- off-cooldown ("available") transition fires even without an event. The +0.05s
	-- margin avoids re-reading a cooldown that's a frame from expiring.
	ScheduleCooldownWake(soonestCd)

	for _, frame in pairs(Wise.frames) do
		if frame.buttons then
			for _, btn in ipairs(frame.buttons) do
				local meta = Wise.buttonMeta[btn]
				local entry = ButtonEntry(meta)
				local visualClone = meta and meta.visualClone or btn.visualClone
				if entry then
					ApplyBorder(btn, entry._matched)
					ApplyCount(btn, entry._stacks or 0, entry._countInstID)
					if visualClone then
						ApplyBorder(visualClone, entry._matched)
						ApplyCount(visualClone, entry._stacks or 0, entry._countInstID)
					end
				else
					ClearButton(btn)
					ClearButton(visualClone)
				end
			end
		end
	end
end

-- Coalesce event bursts: one scan on the next frame (AGENTS.md Rule 9 #2).
local indicatorDirty = false
function Wise:ScheduleIndicatorUpdate()
	if indicatorDirty then
		return
	end
	indicatorDirty = true
	C_Timer.After(0, function()
		indicatorDirty = false
		Wise:UpdateIndicatorRules()
	end)
end

local indicatorFrame = CreateFrame("Frame")
indicatorFrame:RegisterUnitEvent("UNIT_AURA", "player")
indicatorFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
indicatorFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- Cooldown/usable changes drive the "available"/"cooldown"/"charges" metrics. A
-- cooldown FINISHING is timer-based and doesn't always re-fire UpdateButtonCooldown,
-- so register these directly (same reason AudioCues does) or the off-cooldown sound
-- transition is missed.
indicatorFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
indicatorFrame:RegisterEvent("SPELL_UPDATE_USABLE")
indicatorFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
-- Combat start/end so a [combat]-gated indicator re-evaluates the moment the
-- condition flips (otherwise the entering-combat transition waits for the next
-- aura/cooldown event and the sound is late/missed).
indicatorFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
indicatorFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
indicatorFrame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
		Wise:RebuildIndicatorRules()
	end
	Wise:ScheduleIndicatorUpdate()
end)

-- The button visuals can change out from under us on spell swaps / cooldown passes;
-- repaint then too (coalesced). Mirrors the old Abundance hooks.
hooksecurefunc(Wise, "UpdateButtonState", function()
	Wise:ScheduleIndicatorUpdate()
end)
hooksecurefunc(Wise, "UpdateButtonCooldown", function()
	Wise:ScheduleIndicatorUpdate()
end)
