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

-- ─── Special-bar click macro ────────────────────────────────────────────
-- There are TWO kinds of vehicle and Blizzard routes them to DIFFERENT frames
-- (ActionBarController_UpdateAll):
--
--   * SKINNED vehicle (UnitVehicleSkin ~= nil, e.g. the Xeronia drake, a
--     Mechagon shredder) — state flips to LE_ACTIONBAR_STATE_OVERRIDE and the
--     abilities sit on OverrideActionBarButton<N>.
--   * UNSKINNED vehicle (no custom art, e.g. the Gnarldor Isle war turtle) —
--     state stays LE_ACTIONBAR_STATE_MAIN and Blizzard merely repages
--     MainActionBar to C_ActionBar.GetVehicleBarIndex(); the abilities sit on
--     the ordinary ActionButton<N>.
--
-- [vehicleui] is true for BOTH, so it cannot discriminate. Binding
-- OverrideActionBarButton<N> behind [vehicleui] therefore names a frame that is
-- not mounted on an unskinned vehicle: the icon is right (ResolveBarActionID is
-- pure page arithmetic off GetVehicleBarIndex and works for both) while the
-- click silently no-ops — the same "tooltip right, button dead" split as the
-- out-of-range index bug above, arriving through a different door.
--
-- [overridebar] IS the skinned test: it maps to HasOverrideActionBar(), which
-- returns false on an unskinned vehicle (confirmed in-client on the war turtle).
-- Ordering the override line first therefore claims skinned vehicles and true
-- override bars, and lets the [vehicleui] line catch the unskinned case.
--
-- Emitting BOTH lines keeps the choice inside the secure macro, evaluated at
-- click time. A Lua-side probe would be a snapshot needing a rebind on
-- UPDATE_VEHICLE_ACTIONBAR — which is exactly what combat lockdown forbids.
--
-- `extraCond` adds caller conditions (e.g. an exclusive slot's negations) to each
-- route; nil for the plain case.
--
-- These must be MERGED INTO each route's bracket group, never concatenated in
-- front of it. Multiple groups are an OR, so "[nooverridebar,novehicleui]" +
-- "[overridebar]" reads as "no bar up OR override up" — a clause that fires
-- precisely when the slot should be dormant, which silently killed every button.
-- ANDing means one group per (caller group x route) pair.
local function MergeConditionGroups(extraCond, routeToken)
	if not extraCond or extraCond == "" then
		return "[" .. routeToken .. "]"
	end
	local out = {}
	for group in extraCond:gmatch("%[([^%]]*)%]") do
		group = group:match("^%s*(.-)%s*$")
		if group == "" then
			out[#out + 1] = "[" .. routeToken .. "]"
		else
			out[#out + 1] = "[" .. group .. "," .. routeToken .. "]"
		end
	end
	if #out == 0 then
		-- Unbracketed caller input (e.g. "nocombat").
		return "[" .. extraCond:match("^%s*(.-)%s*$") .. "," .. routeToken .. "]"
	end
	return table.concat(out)
end

function Wise:BuildSpecialBarClickMacro(idx, extraCond)
	idx = tonumber(idx) or 1
	-- The override half is bound by the override bar's real (shorter) button
	-- count; the ActionButton half keeps the full 1-12 main-bar range.
	local ovrIdx = Wise:IsValidOverrideBarIndex(idx) and idx or 1
	local mainIdx = (idx >= 1 and idx <= NUM_ACTIONBAR_BUTTONS) and idx or 1
	return "/click "
		.. MergeConditionGroups(extraCond, "overridebar")
		.. " OverrideActionBarButton"
		.. ovrIdx
		.. "\n/click "
		.. MergeConditionGroups(extraCond, "vehicleui")
		.. " OverrideActionBarButton"
		.. ovrIdx
		.. "\n/click "
		.. MergeConditionGroups(extraCond, "vehicleui")
		.. " ActionButton"
		.. mainIdx
		.. "\n/click "
		.. MergeConditionGroups(extraCond, "possessbar")
		.. " OverrideActionBarButton"
		.. ovrIdx
		.. "\n/click "
		.. MergeConditionGroups(extraCond, "possessbar")
		.. " PossessButton"
		.. ovrIdx
		.. "\n/click "
		.. MergeConditionGroups(extraCond, "possessbar")
		.. " ActionButton"
		.. mainIdx
		.. "\n/click "
		.. MergeConditionGroups(extraCond, "bonusbar:5")
		.. " OverrideActionBarButton"
		.. ovrIdx
		.. "\n/click "
		.. MergeConditionGroups(extraCond, "bonusbar:5")
		.. " PossessButton"
		.. ovrIdx
		.. "\n/click "
		.. MergeConditionGroups(extraCond, "bonusbar:5")
		.. " ActionButton"
		.. mainIdx
end



