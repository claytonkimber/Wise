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
