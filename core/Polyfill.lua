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
