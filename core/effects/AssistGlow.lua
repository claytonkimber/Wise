-- core/effects/AssistGlow.lua
--
-- "Blizzard's suggestion" glow: lights every Wise button that holds the spell
-- C_AssistedCombat.GetNextCastSpell() recommends (Blizzard's Assisted Combat,
-- the one-button rotation helper). In 12.x it is the one rotation signal an
-- addon can still read in combat, because the client computes it.
--
-- Display only. Nothing here touches secure attributes or bindings, so it runs
-- freely in combat (AGENTS.md Rule 10).
--
-- WHY THIS POLLS (Rule 12 exception): there is no event for "the suggestion
-- changed". Blizzard's own AssistedCombatManager (Blizzard_ActionBar/Mainline,
-- read 2026-11-13) polls GetNextCastSpell from an OnUpdate every
-- `assistedCombatIconUpdateRate` seconds (CVar, clamped 0..1). We mirror that,
-- but the poll:
--   * runs only while the feature is on for some interface, the API reports
--     Assisted Combat available for this spec, and the player is in combat or
--     has an attackable target -- otherwise the driver frame is hidden and its
--     OnUpdate never fires;
--   * allocates nothing per tick (two match sets are swapped, never rebuilt);
--   * calls Show/Hide only for buttons whose lit state changed.
--
-- checkForVisibleButton is FALSE on purpose. Blizzard passes true, which limits
-- the answer to spells on Blizzard's VISIBLE action buttons -- and Wise often
-- hides those bars, which would make the suggestion vanish.
--
-- Settings: showAssistGlow (default off), assistGlowStyle (default "pixel"),
-- both with per-interface overrides via Wise.Effects.GroupSetting.

local addonName, Wise = ...

local _G = _G
local pairs = pairs
local pcall = pcall
local wipe = wipe
local tonumber = tonumber
local CreateFrame = CreateFrame

local Effects = Wise.Effects
local GroupSetting = Effects.GroupSetting
local AnyGroupEnables = Effects.AnyGroupEnables

local GLOW_KEY = "WiseAssist"
-- Cyan, so it never reads as a (gold) proc glow.
local GLOW_COLOR = { 0.35, 0.85, 1, 1 }
local DEFAULT_RATE = 0.2
local MIN_RATE = 0.05

local issecretvalue = _G.issecretvalue

-- Button -> visual clone (or true) for every button currently lit. `nextLit` is
-- the scratch set for the pass being computed; the two are swapped, not rebuilt.
local lit, nextLit = {}, {}

-- Suggestion cache: base/override relatives only change when the suggestion does.
local lastSpell, lastBase, lastOverride

local driver = CreateFrame("Frame")
driver:Hide()
local elapsedSince, rate = 0, DEFAULT_RATE

local function ReadRate()
	local raw = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("assistedCombatIconUpdateRate")
	local value = tonumber(raw)
	if not value or value < MIN_RATE then
		return value and MIN_RATE or DEFAULT_RATE
	end
	if value > 1 then
		return 1
	end
	return value
end

-- The suggested spell, or nil when there is none, the API is missing, it
-- errors, or the answer is unreadable. Resolved through the namespace at call
-- time so tests can stub its fields.
local function ReadSuggestion()
	local api = _G.C_AssistedCombat
	local fn = api and api.GetNextCastSpell
	if not fn then
		return nil
	end
	local ok, spellID = pcall(fn, false)
	if not ok then
		return nil
	end
	-- Secret check BEFORE any comparison: even `== nil` may throw on a secret
	-- (AGENTS.md "Self-Resource Secrecy"). Blizzard's docs do not mark this
	-- return secret; the check is cheap insurance against that changing.
	if issecretvalue and issecretvalue(spellID) then
		return nil
	end
	return tonumber(spellID)
end

local function IsAssistAvailable()
	local api = _G.C_AssistedCombat
	local fn = api and api.IsAvailable
	if not fn then
		return false
	end
	local ok, available = pcall(fn)
	return ok and available == true
end

local function Relatives(spellID)
	local base, override
	if _G.FindBaseSpellByID then
		local ok, id = pcall(_G.FindBaseSpellByID, spellID)
		base = ok and id or nil
	end
	if C_Spell and C_Spell.GetOverrideSpell then
		local ok, id = pcall(C_Spell.GetOverrideSpell, spellID)
		override = ok and id or nil
	end
	return base, override
end

local function MatchesSuggestion(meta, spellID)
	local sid, bid = meta.spellID, meta.baseSpellID
	if not sid and not bid then
		return false
	end
	return sid == spellID
		or bid == spellID
		or (lastBase ~= nil and bid == lastBase)
		or (lastOverride ~= nil and sid == lastOverride)
end

local function GlowStyleFor(groupName)
	return GroupSetting(groupName, "assistGlowStyle", "pixel")
end

local function Light(btn, clone, style)
	Wise:ShowStyledGlow(btn, style, GLOW_KEY, GLOW_COLOR)
	if clone then
		Wise:ShowStyledGlow(clone, style, GLOW_KEY, GLOW_COLOR)
	end
end

local function Unlight(btn, clone)
	Wise:HideStyledGlow(btn, GLOW_KEY)
	if clone and clone ~= true then
		Wise:HideStyledGlow(clone, GLOW_KEY)
	end
end

-- One pass: work out which buttons should glow and apply only the differences.
-- `restyle` re-applies the style to buttons that stay lit (settings change).
local function Refresh(restyle)
	local spellID = ReadSuggestion()
	if spellID ~= lastSpell then
		lastSpell = spellID
		if spellID then
			lastBase, lastOverride = Relatives(spellID)
		else
			lastBase, lastOverride = nil, nil
		end
	end

	wipe(nextLit)
	local metaByButton = Wise.buttonMeta
	if spellID and metaByButton then
		for btn, meta in pairs(metaByButton) do
			if MatchesSuggestion(meta, spellID) and GroupSetting(btn.groupName, "showAssistGlow", false) then
				nextLit[btn] = meta.visualClone or btn.visualClone or true
			end
		end
	end

	for btn, clone in pairs(nextLit) do
		if restyle or not lit[btn] then
			Light(btn, clone ~= true and clone or nil, GlowStyleFor(btn.groupName))
		end
	end
	for btn, clone in pairs(lit) do
		if not nextLit[btn] then
			Unlight(btn, clone)
		end
	end
	lit, nextLit = nextLit, lit
end

local function ClearAll()
	for btn, clone in pairs(lit) do
		Unlight(btn, clone)
	end
	wipe(lit)
	lastSpell, lastBase, lastOverride = nil, nil, nil
end

driver:SetScript("OnUpdate", function(_, elapsed)
	elapsedSince = elapsedSince + elapsed
	if elapsedSince < rate then
		return
	end
	elapsedSince = 0
	Refresh(false)
end)

local function WantsToRun()
	if not AnyGroupEnables("showAssistGlow", false) or not IsAssistAvailable() then
		return false
	end
	if _G.InCombatLockdown() then
		return true
	end
	return _G.UnitExists("target") and _G.UnitCanAttack("player", "target") and true or false
end

-- Re-check whether the driver should run. Called on the gate events below and
-- by the settings UI. `restyle` forces lit buttons to pick up a style change.
function Wise:RefreshAssistGlow(restyle)
	if WantsToRun() then
		rate = ReadRate()
		elapsedSince = 0
		driver:Show()
		Refresh(restyle)
	else
		driver:Hide()
		ClearAll()
	end
end

local gate = CreateFrame("Frame")
gate:RegisterEvent("PLAYER_ENTERING_WORLD")
gate:RegisterEvent("PLAYER_REGEN_DISABLED")
gate:RegisterEvent("PLAYER_REGEN_ENABLED")
gate:RegisterEvent("PLAYER_TARGET_CHANGED")
gate:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
gate:RegisterEvent("SPELLS_CHANGED")
gate:SetScript("OnEvent", function()
	Wise:RefreshAssistGlow(false)
end)

-- Test seams (tests/assist_glow.lua): run one pass synchronously and inspect state.
Wise.AssistGlow = {
	Refresh = Refresh,
	ClearAll = ClearAll,
	IsLit = function(btn)
		return lit[btn] ~= nil
	end,
	IsRunning = function()
		return driver:IsShown()
	end,
	GLOW_KEY = GLOW_KEY,
}
