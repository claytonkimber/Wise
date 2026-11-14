-- core/effects/RangeTint.lua
--
-- Out-of-range tint: a spell that cannot reach the current target gets a red
-- icon, like the default action bars and most bar addons.
--
-- This file only DECIDES range. It keeps `btn._wiseOutOfRange` up to date and
-- asks Wise:UpdateButtonUsability (core/GUI.lua) to repaint a button when that
-- flag flips. The usability pass stays the single place that colours an icon,
-- so range, out-of-mana blue and unusable dimming cannot fight each other.
--
-- WHY THIS POLLS (Rule 12 exception): spell range has no event. Blizzard's
-- ACTION_RANGE_CHECK_UPDATE covers action-bar SLOTS only (via
-- C_ActionBar.EnableActionRangeCheck), and most Wise buttons are not slots. The
-- check runs every RANGE_INTERVAL seconds, and only while a target exists and
-- the tint is on for some interface (the driver frame is hidden otherwise). It
-- repaints only buttons whose state changed, and allocates nothing per pass.
-- Target changes trigger an immediate pass.
--
-- Only spells and action-bar slots are checked. Items are deliberately left
-- out: C_Item.IsItemInRange is restricted in combat for many units, so an
-- item tint would be wrong exactly when it matters.
--
-- Range answers carry no secret annotation in Blizzard's 12.1.5 API docs. The
-- issecretvalue check stays anyway, so a change there means "no tint", never a
-- thrown comparison.
--
-- Setting: rangeTint (default ON, Blizzard parity), per-interface override via
-- Wise.Effects.GroupSetting.

local addonName, Wise = ...

local _G = _G
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local tonumber = tonumber
local CreateFrame = CreateFrame

local Effects = Wise.Effects
local GroupSetting = Effects.GroupSetting
local AnyGroupEnables = Effects.AnyGroupEnables

local RANGE_INTERVAL = 0.2

local issecretvalue = _G.issecretvalue

-- true / false / nil (no range, no valid target, or unreadable). Resolved
-- through the namespace at call time so tests can stub the fields.
local function PlainBool(ok, value)
	if not ok then
		return nil
	end
	if issecretvalue and issecretvalue(value) then
		return nil
	end
	if value == true or value == false then
		return value
	end
	return nil
end

local function SpellInRange(spellID)
	local fn = C_Spell and C_Spell.IsSpellInRange
	if not fn then
		return nil
	end
	return PlainBool(pcall(fn, spellID, "target"))
end

local function SlotInRange(slot)
	local fn = _G.IsActionInRange
	if not fn then
		return nil
	end
	return PlainBool(pcall(fn, slot))
end

local function RangeOf(meta)
	-- A ping macro (/pingspell Fireball) pings regardless of distance; tinting it
	-- red for the spell's range would misreport it (see PingFeedback.lua).
	if meta.pingFeedback then
		return nil
	end
	if meta.actionType == "action" then
		local slot = tonumber(meta.actionValue)
		if slot and Wise.ResolveBarActionID then
			return SlotInRange(Wise:ResolveBarActionID(slot))
		end
		return nil
	end
	if meta.spellID then
		return SpellInRange(meta.spellID)
	end
	return nil
end

local function IsButtonVisible(btn, meta)
	if btn:IsShown() then
		return true
	end
	local clone = (meta and meta.visualClone) or btn.visualClone
	return clone ~= nil and clone:IsShown()
end

-- One pass over every button. With hasTarget=false it only clears tints.
local function Pass(hasTarget)
	local metaByButton = Wise.buttonMeta
	for name, frame in pairs(Wise.frames or {}) do
		if frame.buttons then
			local enabled = hasTarget and GroupSetting(name, "rangeTint", true)
			for _, btn in ipairs(frame.buttons) do
				local out = false
				if enabled then
					local meta = metaByButton and metaByButton[btn]
					if meta and IsButtonVisible(btn, meta) then
						out = RangeOf(meta) == false
					end
				end
				if out ~= (btn._wiseOutOfRange == true) then
					btn._wiseOutOfRange = out or nil
					Wise:UpdateButtonUsability(btn)
				end
			end
		end
	end
end

local driver = CreateFrame("Frame")
driver:Hide()
local elapsedSince = 0
driver:SetScript("OnUpdate", function(_, elapsed)
	elapsedSince = elapsedSince + elapsed
	if elapsedSince < RANGE_INTERVAL then
		return
	end
	elapsedSince = 0
	Pass(true)
end)

-- Re-check whether the driver should run, and do one pass now. Called on the
-- events below and by the settings UI.
function Wise:RefreshRangeTint()
	local hasTarget = _G.UnitExists("target") and true or false
	if hasTarget and AnyGroupEnables("rangeTint", true) then
		elapsedSince = 0
		driver:Show()
		Pass(true)
	else
		driver:Hide()
		Pass(false)
	end
end

local gate = CreateFrame("Frame")
gate:RegisterEvent("PLAYER_ENTERING_WORLD")
gate:RegisterEvent("PLAYER_TARGET_CHANGED")
gate:SetScript("OnEvent", function()
	Wise:RefreshRangeTint()
end)

-- Test seams (tests/range_tint.lua).
Wise.RangeTint = {
	Pass = Pass,
	IsRunning = function()
		return driver:IsShown()
	end,
}
