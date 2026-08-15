local addonName, Wise = ...
Wise.Polyfill = {}

-- C_Spell.IsSpellUsable Polyfill
if not (C_Spell and C_Spell.IsSpellUsable) then
	Wise.Polyfill.IsSpellUsable = function(spellID)
		return IsUsableSpell(spellID)
	end
else
	Wise.Polyfill.IsSpellUsable = C_Spell.IsSpellUsable
end

-- Helper to ensure we always have a valid function to call
function Wise:IsSpellUsable(spell)
	return Wise.Polyfill.IsSpellUsable(spell)
end

-- Polyfill modern C_ActionBar namespace functions into global scope if missing
if not _G.HasOverrideActionBar then
	_G.HasOverrideActionBar = function()
		return C_ActionBar and C_ActionBar.HasOverrideActionBar and C_ActionBar.HasOverrideActionBar() or false
	end
end

if not _G.HasVehicleActionBar then
	_G.HasVehicleActionBar = function()
		return C_ActionBar and C_ActionBar.HasVehicleActionBar and C_ActionBar.HasVehicleActionBar() or false
	end
end

if not _G.HasTempShapeshiftActionBar then
	_G.HasTempShapeshiftActionBar = function()
		return C_ActionBar and C_ActionBar.HasTempShapeshiftActionBar and C_ActionBar.HasTempShapeshiftActionBar()
			or false
	end
end

if not _G.GetOverrideBarIndex then
	_G.GetOverrideBarIndex = function()
		return C_ActionBar and C_ActionBar.GetOverrideBarIndex and C_ActionBar.GetOverrideBarIndex() or nil
	end
end

if not _G.GetVehicleBarIndex then
	_G.GetVehicleBarIndex = function()
		return C_ActionBar and C_ActionBar.GetVehicleBarIndex and C_ActionBar.GetVehicleBarIndex() or nil
	end
end

if not _G.GetTempShapeshiftBarIndex then
	_G.GetTempShapeshiftBarIndex = function()
		return C_ActionBar and C_ActionBar.GetTempShapeshiftBarIndex and C_ActionBar.GetTempShapeshiftBarIndex() or nil
	end
end

-- ─── Override bar button count ──────────────────────────────────────
-- How many OverrideActionBarButton<N> frames Blizzard actually creates.
-- This is NOT NUM_ACTIONBAR_BUTTONS (12): the override bar is a separate,
-- shorter frame. Clamping override indices against 12 lets a slot build
-- "/click OverrideActionBarButton9" for a frame that does not exist — a
-- /click naming a missing frame is a silent no-op that the client reports
-- as "You can't do that right now", while the DISPLAY path (pure index
-- arithmetic in ResolveBarActionID) still resolves a plausible action id.
-- That split is exactly the "tooltip right, button dead" symptom.
--
-- Probed rather than hardcoded so it self-corrects if Blizzard changes the
-- count. Counts CONTIGUOUSLY from 1 and stops at the first gap, so a stray
-- high-numbered frame from another addon can't inflate the bound.
local function ProbeOverrideBarButtonCount()
	local n = 0
	for i = 1, 32 do
		if _G["OverrideActionBarButton" .. i] then
			n = i
		else
			break
		end
	end
	return n
end

-- At file scope the Blizzard frames may not exist yet (load order), so treat
-- a zero probe as "unknown" and fall back to the historical 8. Wise:GetOverrideBarButtonCount
-- re-probes on demand and caches the first non-zero answer.
local OVERRIDE_BAR_BUTTON_FALLBACK = 8
local overrideBarButtonCount = ProbeOverrideBarButtonCount()

--- Number of usable OverrideActionBarButton<N> frames.
-- Re-probes until it gets a non-zero answer, then caches. Safe to call in
-- combat (pure frame-existence lookups, no secure writes).
function Wise:GetOverrideBarButtonCount()
	if overrideBarButtonCount == 0 then
		overrideBarButtonCount = ProbeOverrideBarButtonCount()
	end
	if overrideBarButtonCount == 0 then
		return OVERRIDE_BAR_BUTTON_FALLBACK
	end
	return overrideBarButtonCount
end

--- Drop the cached probe result so the next query re-counts. Blizzard creates the
-- override bar frames lazily, so a count taken before they exist must not stick.
-- Also used by the test suite to probe against a stubbed frame set.
function Wise:ResetOverrideBarButtonCount()
	overrideBarButtonCount = 0
end

--- True if index N names a real override bar button.
function Wise:IsValidOverrideBarIndex(idx)
	idx = tonumber(idx)
	if not idx or idx < 1 or idx ~= math.floor(idx) then
		return false
	end
	return idx <= Wise:GetOverrideBarButtonCount()
end
