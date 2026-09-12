-- modules/indicators/Paint.lua
--
-- The runtime pass: border, glow, count and edge-triggered sound on each button.
-- See modules/indicators/Model.lua for how this directory is laid out.
--
-- SECRET VALUES: the aura-stack count can be a secret number in combat, which
-- throws on arithmetic or tostring(). SecretCountProbe is the hoisted pcall body
-- that reads it safely -- passed to pcall BY REFERENCE so no closure is
-- allocated per button per pass. Same shape, and same reason, as the cooldown
-- primitives in core/cooldown/SecretValues.lua.
--
-- The sound fires on the RISING EDGE only, which is what lastMatchByEntry in
-- Index.lua is for: a rule that still matches on the next pass must stay silent.
--
-- Loaded last in modules/indicators/.

local addonName, Wise = ...

local IR = Wise.IndicatorRules
local GetColorRGB = IR.GetColorRGB
local ResolveEntry = IR.ResolveEntry
local rulesBySpell = IR.rulesBySpell
local lastMatchByEntry = IR.lastMatchByEntry
local lastCdStartByEntry = IR.lastCdStartByEntry
local ButtonEntry = IR.ButtonEntry
local OXED_SOUND_NONE = IR.OXED_SOUND_NONE

-- Hoisted pcall body; see the note in State.lua. Lives here because the line
-- that sets its scratch upvalues is in this file.
local _recastCdStart, _recastLastCdStart
local function SafeCheckRecast()
	return _recastCdStart > _recastLastCdStart
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
	local tStart = debugprofilestop()
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
	if Wise._inCombatExitTransition and Wise._cpuExitStats and tStart then
		Wise._cpuExitStats.indicatorsMs = (Wise._cpuExitStats.indicatorsMs or 0) + (debugprofilestop() - tStart)
	end
end

-- Coalesce event bursts: one scan on the next frame (AGENTS.md Rule 12 #2).
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
