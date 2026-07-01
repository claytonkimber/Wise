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
local METRICS = {
	{ key = "stacks", label = "Aura stacks", numeric = true },
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
-- Legacy rules (and the Abundance migration) have no metric → treat as stacks,
-- which is the behavior they were authored against.
local DEFAULT_METRIC = "stacks"

local function RuleMetric(rule)
	local m = rule.metric or DEFAULT_METRIC
	if METRIC_LABELS[m] then
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

-- Per-spell live state, computed ONCE per pass and shared by every rule on that
-- spell. The buff is read by spellID first, then by NAME — many spells apply an
-- aura with a DIFFERENT id than the cast spell (Abundance casts 207383 but its buff
-- is 203864), and the aura name matches the spell name, so name resolves both.
local function ResolveSpellState(spellID, name, action)
	local stacks = 0
	local buffActive = false
	local aura = spellID and C_UnitAuras.GetPlayerAuraBySpellID(spellID)
	if not aura and name and C_UnitAuras.GetAuraDataBySpellName then
		aura = C_UnitAuras.GetAuraDataBySpellName("player", name)
	end
	if aura then
		buffActive = true
		stacks = aura.applications or aura.charges or 1
	end
	local charges = 0
	if spellID and C_Spell and C_Spell.GetSpellCharges then
		local info = C_Spell.GetSpellCharges(spellID)
		if info and info.currentCharges then
			charges = info.currentCharges
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
	-- actually be cast. Falls back to the cooldown-only check if the API is missing.
	local usable
	if spellID and C_Spell and C_Spell.IsSpellUsable then
		usable = (C_Spell.IsSpellUsable(spellID)) and true or false
	else
		usable = known and not onCooldown
	end
	return {
		stacks = stacks,
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
	local metric = RuleMetric(rule)
	if metric == "stacks" then
		return Wise:EvaluateNumericRule(st.stacks, rule.operator, rule.value)
	elseif metric == "charges" then
		return Wise:EvaluateNumericRule(st.charges, rule.operator, rule.value)
	elseif metric == "available" then
		return st.available == true
	elseif metric == "cooldown" then
		return st.onCooldown == true
	elseif metric == "buff_active" then
		return st.buffActive == true
	elseif metric == "buff_missing" then
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
	if metric == "stacks" then
		return math.abs(st.stacks - (tonumber(rule.value) or 0))
	elseif metric == "charges" then
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

-- Stack count to DISPLAY on the button (the little corner number). Only meaningful
-- for stacking auras; hidden (0) otherwise.
local function GetDisplayStacks(st)
	return st and st.stacks or 0
end

-- Resolve an entry's current (matchedRule, displayStacks, cdRemaining, cdStart).
-- Honors the node's macro condition (e.g. [combat]) — when it isn't met the indicator
-- is inert (no match → no border/sound), so the cue tracks the slot's own gating.
local function ResolveEntry(entry)
	if entry.condition and Wise.EvalConditionExact and not Wise:EvalConditionExact(entry.condition) then
		return nil, 0, nil, 0
	end
	local st = ResolveSpellState(entry.spellID, entry.name, entry.action)
	return FindMatchedRule(entry.rules, st), GetDisplayStacks(st), st.cdRemaining, st.cdStart
end

-- Best default metric for a NEW rule on this action, so the user rarely has to
-- change it: a spell that currently shows a stacking aura → "stacks"; a charge
-- spell → "charges"; everything else (most spells, e.g. Raze) → "available", which
-- is the universally-meaningful "off cooldown / usable" state. The metric is still
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
	-- Currently-applied stacking aura (>1 application) → it's a stacking spell.
	local aura = C_UnitAuras.GetPlayerAuraBySpellID(sid)
	if not aura and action.name and C_UnitAuras.GetAuraDataBySpellName then
		aura = C_UnitAuras.GetAuraDataBySpellName("player", action.name)
	end
	if aura and (aura.applications or 0) > 1 then
		return "stacks"
	end
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
				"What this rule watches on this spell (stacks, charges, availability, buff state)."
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
		local matched, _, _, cdStart = ResolveEntry(entry)
		lastMatchByEntry[entry] = matched
		lastCdStartByEntry[entry] = cdStart or 0
	end
end

-- Resolve the ruled entry that applies to a button. Match by the button's tracked
-- spellID first, then by spell NAME — a /cast Abundance custom_macro button has no
-- resolved spellID (the name doesn't resolve via C_Spell), so fall back to scanning
-- its live macro text / action value for a ruled spell name.
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
		Wise:HideOverlayGlow(b)
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
		Wise:ShowOverlayGlow(b)
	else
		Wise:HideOverlayGlow(b)
	end
end

local function ApplyCount(b, count)
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
	Wise:HideOverlayGlow(b)
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
		local matched, stacks, cdRemaining, cdStart = ResolveEntry(entry)
		entry._matched = matched
		entry._stacks = stacks
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
					ApplyCount(btn, entry._stacks or 0)
					if visualClone then
						ApplyBorder(visualClone, entry._matched)
						ApplyCount(visualClone, entry._stacks or 0)
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
