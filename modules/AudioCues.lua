local addonName, Wise = ...

-- Per-node Audio Cue feature -------------------------------------------------
-- Lets a configurator node play an Oxed sound when a watched condition becomes
-- true — a general "audio as an indicator" (the WeakAura-style sound the user
-- wanted, working in combat). Config is stored on `action.audioCue`; the runtime
-- below watches the relevant events, coalesces bursts, and fires the sound on the
-- RISING EDGE of the condition (once per proc/threshold-cross, not every tick).
-- Pure insecure code (sound + aura/cooldown reads) so it is combat-safe — audio
-- is not a protected action in WoW (OxedHub plays via PlaySoundFile/"Master").
--
-- Patterns mirror the Abundance indicator (modules/AbundanceTest.lua): a dirty
-- flag + C_Timer.After(0) coalescer (AGENTS.md Rule 9 #2) and a transition gate
-- so a held condition doesn't re-trigger. Shared sound + dropdown helpers come
-- from modules/Audio.lua.

local tinsert = table.insert
local OXED_SOUND_NONE = Wise.OXED_SOUND_NONE

-- Trigger types, in dropdown order. The leading "None" disables the cue.
local TRIGGERS = {
	{ key = "none", label = "None" },
	{ key = "buff_gained", label = "Buff/proc gained" },
	{ key = "spell_ready", label = "Spell ready (off cooldown)" },
	{ key = "threshold", label = "Stack/resource threshold" },
	{ key = "buff_missing", label = "Buff missing / expiring" },
}
local THRESHOLD_OPERATORS = { "<", "=", ">", "<=", ">=", "!=" }

local function TriggerLabel(key)
	for _, t in ipairs(TRIGGERS) do
		if t.key == key then
			return t.label
		end
	end
	return "None"
end

-- Resolve a node action's spellID (the cue's default aura/cooldown target).
local function ActionSpellID(action)
	if not action or action.type ~= "spell" then
		return nil
	end
	local v = action.value
	local n = tonumber(v)
	if n then
		return n
	end
	local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(v)
	return info and info.spellID or nil
end

-- =========================================================================
-- UI: rendered inside the node properties panel (SlotConfigurator.lua).
-- `panel` carries .controls / .activeDropdown; `commit` re-exports + renders.
-- Returns the updated y cursor.
-- =========================================================================
function Wise:RenderAudioCueProperties(panel, action, y, commit)
	commit = commit or function() end

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
	title:SetText("|cffffcc00Audio Cue|r")
	tinsert(panel.controls, title)

	-- Re-render this whole section in place when the trigger type changes so the
	-- relevant sub-controls (operator/value, expire-within) show/hide.
	local function refresh()
		Wise:RefreshPropertiesPanel()
	end

	local cue = action.audioCue
	local trigger = (cue and cue.trigger) or "none"

	y = y - 22
	local trigLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	trigLabel:SetPoint("TOPLEFT", 10, y)
	trigLabel:SetText("When:")
	tinsert(panel.controls, trigLabel)

	local triggerNames = {}
	for _, t in ipairs(TRIGGERS) do
		tinsert(triggerNames, t.label)
	end
	local trigBtn = Wise:CreateSimpleDropdown(panel, 180, 20, TriggerLabel(trigger), triggerNames, function(label)
		-- Map the chosen label back to its key.
		local chosen = "none"
		for _, t in ipairs(TRIGGERS) do
			if t.label == label then
				chosen = t.key
				break
			end
		end
		if chosen == "none" then
			action.audioCue = nil
		else
			action.audioCue = action.audioCue or {}
			action.audioCue.trigger = chosen
		end
		commit()
		Wise:RebuildAudioCues()
		refresh()
	end)
	trigBtn:SetPoint("TOPLEFT", 55, y + 3)

	if trigger == "none" or not cue then
		y = y - 26
		local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		hint:SetPoint("TOPLEFT", 10, y)
		hint:SetWidth(240)
		hint:SetJustifyH("LEFT")
		hint:SetText("Pick a trigger to play a sound when this action's condition fires (works in combat).")
		tinsert(panel.controls, hint)
		return y - 14
	end

	-- Sound picker (shared two-level Oxed dropdown).
	y = y - 26
	local soundLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	soundLabel:SetPoint("TOPLEFT", 10, y)
	soundLabel:SetText("Sound:")
	tinsert(panel.controls, soundLabel)

	local soundBtn = Wise:CreateSoundDropdown(panel, 150, 20, cue.sound, function(val)
		cue.sound = val
		commit()
		Wise:RebuildAudioCues()
	end)
	soundBtn:SetPoint("TOPLEFT", 55, y + 3)

	-- Threshold: operator + value.
	if trigger == "threshold" then
		y = y - 28
		local opLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		opLabel:SetPoint("TOPLEFT", 10, y)
		opLabel:SetText("Stacks")
		tinsert(panel.controls, opLabel)

		local opBtn = Wise:CreateSimpleDropdown(panel, 44, 20, cue.operator or ">=", THRESHOLD_OPERATORS, function(val)
			cue.operator = val
			commit()
			Wise:RebuildAudioCues()
		end)
		opBtn:SetPoint("TOPLEFT", 55, y + 3)

		local valEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
		valEdit:SetSize(40, 20)
		valEdit:SetPoint("TOPLEFT", 108, y + 3)
		valEdit:SetAutoFocus(false)
		valEdit:SetNumeric(true)
		valEdit:SetText(tostring(cue.value or 0))
		valEdit:SetScript("OnTextChanged", function(self)
			cue.value = tonumber(self:GetText()) or 0
		end)
		valEdit:SetScript("OnEditFocusLost", function()
			commit()
			Wise:RebuildAudioCues()
		end)
		valEdit:SetScript("OnEnterPressed", function(self)
			self:ClearFocus()
		end)
		valEdit:SetScript("OnEscapePressed", function(self)
			self:SetText(tostring(cue.value or 0))
			self:ClearFocus()
		end)
		tinsert(panel.controls, valEdit)

		y = y - 22
		local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		note:SetPoint("TOPLEFT", 10, y)
		note:SetWidth(240)
		note:SetJustifyH("LEFT")
		note:SetText("Counts this action's aura stacks (or combo points if it has none).")
		tinsert(panel.controls, note)
	elseif trigger == "buff_missing" then
		y = y - 28
		local expLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		expLabel:SetPoint("TOPLEFT", 10, y)
		expLabel:SetText("Within (s):")
		tinsert(panel.controls, expLabel)

		local expEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
		expEdit:SetSize(40, 20)
		expEdit:SetPoint("TOPLEFT", 75, y + 3)
		expEdit:SetAutoFocus(false)
		expEdit:SetNumeric(true)
		expEdit:SetText(tostring(cue.expireWithin or 0))
		expEdit:SetScript("OnTextChanged", function(self)
			cue.expireWithin = tonumber(self:GetText()) or 0
		end)
		expEdit:SetScript("OnEditFocusLost", function()
			commit()
			Wise:RebuildAudioCues()
		end)
		expEdit:SetScript("OnEnterPressed", function(self)
			self:ClearFocus()
		end)
		expEdit:SetScript("OnEscapePressed", function(self)
			self:SetText(tostring(cue.expireWithin or 0))
			self:ClearFocus()
		end)
		tinsert(panel.controls, expEdit)

		y = y - 22
		local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		note:SetPoint("TOPLEFT", 10, y)
		note:SetWidth(240)
		note:SetJustifyH("LEFT")
		note:SetText("Fires when this action's buff drops, or is within N seconds of expiring (0 = on drop).")
		tinsert(panel.controls, note)
	end

	return y - 14
end

-- =========================================================================
-- Runtime: armed-cue list + event-driven, coalesced, rising-edge sound fire.
-- =========================================================================

-- Flat list of cues this character should watch: { action=, cue=, spellID=, state= }.
-- Rebuilt on spec/login/config change so off-spec nodes never fire (IsActionAllowed).
local armedCues = {}
local EvaluateCue -- forward declaration (defined below; used to seed state here)

function Wise:RebuildAudioCues()
	wipe(armedCues)
	if not WiseDB or not WiseDB.groups then
		return
	end
	for _, group in pairs(WiseDB.groups) do
		if type(group.actions) == "table" then
			for _, states in pairs(group.actions) do
				if type(states) == "table" then
					-- Cues live on the graph nodes' actions (the configurator's unit of
					-- editing). Walk the slot graph if present; fall back to the compiled
					-- states for hand-authored slots.
					local graph = states.graph
					if graph and type(graph.nodes) == "table" then
						for _, node in ipairs(graph.nodes) do
							local a = node.action
							if
								a
								and type(a.audioCue) == "table"
								and a.audioCue.trigger
								and a.audioCue.trigger ~= "none"
								and a.audioCue.sound
								and a.audioCue.sound ~= OXED_SOUND_NONE
								and Wise:IsActionAllowed(a)
							then
								tinsert(
									armedCues,
									{ action = a, cue = a.audioCue, spellID = ActionSpellID(a), state = false }
								)
							end
						end
					end
				end
			end
		end
	end
	-- Seed each cue's state to its CURRENT value without firing, so a condition
	-- already true at rebuild time (a buff already up on login, or just-edited in
	-- the configurator) doesn't blare spuriously. Sound only fires on a later
	-- false→true transition. EvaluateCue is safe here (we never reach RebuildAudioCues
	-- before the whole file has loaded).
	for _, entry in ipairs(armedCues) do
		entry.state = EvaluateCue(entry)
	end
end

-- Current boolean state of one cue (true = condition met right now).
function EvaluateCue(entry)
	local cue = entry.cue
	local trigger = cue.trigger
	local spellID = entry.spellID

	if trigger == "spell_ready" then
		if not spellID then
			return false
		end
		if not Wise:IsActionKnown("spell", spellID) then
			return false
		end
		return not Wise:IsActionOnCooldown("spell", spellID, entry.action)
	elseif trigger == "buff_gained" then
		if not spellID then
			return false
		end
		return C_UnitAuras.GetPlayerAuraBySpellID(spellID) ~= nil
	elseif trigger == "buff_missing" then
		if not spellID then
			return false
		end
		local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
		if not aura then
			return true -- buff absent → "missing" condition is met
		end
		local within = tonumber(cue.expireWithin) or 0
		if within > 0 and aura.expirationTime and aura.expirationTime > 0 then
			return (aura.expirationTime - GetTime()) <= within
		end
		return false
	elseif trigger == "threshold" then
		local count = 0
		if spellID then
			local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
			if aura and aura.applications and aura.applications > 0 then
				count = aura.applications
			else
				-- No stacking aura: fall back to combo points (the common "resource".)
				count = UnitPower("player", Enum.PowerType.ComboPoints) or 0
			end
		end
		return Wise:EvaluateNumericRule(count, cue.operator or ">=", cue.value or 0)
	end
	return false
end

-- Evaluate every armed cue; fire its sound only on the false→true transition.
function Wise:RefreshAudioCues()
	for _, entry in ipairs(armedCues) do
		local now = EvaluateCue(entry)
		if now and not entry.state then
			Wise:PlayOxedSound(entry.cue.sound)
		end
		entry.state = now
	end
end

-- Coalesce event bursts: one scan on the next frame instead of one per event.
local audioCuesDirty = false
function Wise:ScheduleAudioCueUpdate()
	if audioCuesDirty then
		return
	end
	audioCuesDirty = true
	C_Timer.After(0, function()
		audioCuesDirty = false
		Wise:RefreshAudioCues()
	end)
end

local audioCueFrame = CreateFrame("Frame")
audioCueFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
audioCueFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
audioCueFrame:RegisterUnitEvent("UNIT_AURA", "player")
audioCueFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
audioCueFrame:RegisterEvent("SPELL_UPDATE_USABLE")
audioCueFrame:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
audioCueFrame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_SPECIALIZATION_CHANGED" then
		Wise:RebuildAudioCues() -- seeds cue state without firing
		return
	end
	Wise:ScheduleAudioCueUpdate()
end)
