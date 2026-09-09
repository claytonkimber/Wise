-- core/conditionals/ZoneAbility.lua
--
-- Zone-ability detection, extracted from core/GUI.lua.
--
-- One question, asked from three places: is a zone ability genuinely active
-- right now? Actions.lua asks it for the dynamic-availability snapshot, the
-- [zoneability] custom conditional asks it for visibility, and the usability
-- pass asks it before dimming a zone-ability slot. All three route here so the
-- stale-button trap below is handled once instead of three times.
--
-- The trap: SpellButtonContainer's children keep a stale `.spellID` and stay
-- :IsShown() after the ability goes away (exiting the G-99 Breakneck in
-- Undermine is the reproducible case), so a button-only check leaves the Wise
-- slot stuck visible. C_ZoneAbility.GetActiveAbilities() is authoritative and
-- drops the ability immediately, so it is the cross-check on every path.
--
-- Loaded before the rest of core/conditionals — EvalToken.lua's [zoneability]
-- branch calls into the internals table this file populates.

local addonName, Wise = ...

local ipairs = ipairs
local C_ZoneAbility = C_ZoneAbility

-- Shared internals table for the conditional engine. The four files under
-- core/conditionals/ hand each other locals through this table rather than
-- through _G; nothing outside the engine should read it (public entry points
-- are the Wise:* methods each file defines).
local E = Wise.CondEngine or {}
Wise.CondEngine = E

-- Returns a lookup set { [spellID] = true } of the zone abilities the game
-- currently considers active for this zone, via C_ZoneAbility.GetActiveAbilities().
-- This is the AUTHORITATIVE signal: the SpellButtonContainer's child buttons retain
-- a stale .spellID and stay :IsShown() after the zone ability goes away (e.g. exiting
-- the G-99 Breakneck in Undermine), so checking the button alone leaves the Wise slot
-- stuck visible. GetActiveAbilities drops the ability the moment it's no longer
-- available. canBeSecret=false, so it's safe to read in combat. Returns nil if the
-- API is unavailable (older client) — callers then fall back to the button check.
local function GetActiveZoneAbilitySet()
	if not (C_ZoneAbility and C_ZoneAbility.GetActiveAbilities) then
		return nil
	end
	local active = C_ZoneAbility.GetActiveAbilities()
	if not active then
		return nil
	end
	local set = {}
	for _, info in ipairs(active) do
		if info and info.spellID then
			set[info.spellID] = true
		end
	end
	return set
end

-- True if `child` is a zone-ability button whose spell is genuinely active right now.
-- Combines the button's own shown state (so a ZoneAbilityFrame hidden by Wise's
-- "Hide Zone Ability" setting still counts — children keep IsShown()) with the
-- authoritative active-ability set (so a stale child from a previous zone does NOT).
-- `activeSet` is the result of GetActiveZoneAbilitySet(); when nil (API missing) we
-- fall back to the legacy shown-only behavior.
local function IsZoneAbilityButtonActive(child, activeSet)
	if not (child and child.spellID and child:IsShown()) then
		return false
	end
	if activeSet then
		return activeSet[child.spellID] == true
	end
	return true
end

-- Helper: Get the first active spell button from ZoneAbilityFrame.
-- Modern WoW (11.0+) uses SpellButtonContainer with dynamic children
-- instead of a direct .SpellButton child.
local function GetZoneAbilitySpellButton()
	local zoneFrame = _G["ZoneAbilityFrame"]
	if not zoneFrame then
		return nil
	end
	-- Modern: SpellButtonContainer with dynamic children
	if zoneFrame.SpellButtonContainer then
		local children = { zoneFrame.SpellButtonContainer:GetChildren() }
		for _, child in ipairs(children) do
			if child.spellID and child:IsShown() then
				return child
			end
		end
		-- Return first child even if not shown (for secure click binding)
		for _, child in ipairs(children) do
			if child.spellID then
				return child
			end
		end
	end
	-- Legacy fallback: direct SpellButton
	if zoneFrame.SpellButton then
		return zoneFrame.SpellButton
	end
	return nil
end

-- Returns true if a zone ability is genuinely active (has a valid, currently-active
-- spell AND its button is shown). The shown check alone is NOT enough: child buttons
-- retain a stale .spellID and stay :IsShown() after the zone ability goes away (e.g.
-- exiting the G-99 Breakneck), so we cross-check against C_ZoneAbility's authoritative
-- active set via IsZoneAbilityButtonActive. We deliberately keep IsShown() (not
-- IsVisible()) so Wise's "Hide Zone Ability" setting — which hides ZoneAbilityFrame
-- itself while the child keeps its shown flag — still reports the ability as active.
local function IsZoneAbilityActive()
	local zoneFrame = _G["ZoneAbilityFrame"]
	if not zoneFrame then
		return false
	end
	local activeSet = GetActiveZoneAbilitySet()
	if zoneFrame.SpellButtonContainer then
		local children = { zoneFrame.SpellButtonContainer:GetChildren() }
		for _, child in ipairs(children) do
			if IsZoneAbilityButtonActive(child, activeSet) then
				return true
			end
		end
	end
	if zoneFrame.SpellButton then
		return IsZoneAbilityButtonActive(zoneFrame.SpellButton, activeSet)
	end
	return false
end

-- Exposed for other modules (Actions.lua IsActionKnown) so the dynamic-availability
-- snapshot uses the same authoritative C_ZoneAbility-backed check as everything else.
function Wise:IsZoneAbilityActive()
	return IsZoneAbilityActive()
end

-- Expose on Wise table for use in other modules (Actions.lua)
function Wise:GetZoneAbilitySpellButton()
	return GetZoneAbilitySpellButton()
end

-- Published to the engine's internals for EvalToken.lua ([zoneability]).
E.IsZoneAbilityActive = IsZoneAbilityActive
E.GetZoneAbilitySpellButton = GetZoneAbilitySpellButton
