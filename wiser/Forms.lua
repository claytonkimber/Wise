local addonName, addon = ...
local Wise = addon

function Wise:UpdateFormsInterface()
    if not WiseDB or not WiseDB.groups then return end

    local name = "Forms"

    -- If no forms available, and the group doesn't exist, don't create it
    local numForms = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0
    if numForms == 0 and not WiseDB.groups[name] then
        return
    end

    local created = false
    if not WiseDB.groups[name] then
        Wise:CreateGroup(name, "list")
        WiseDB.groups[name].enabled = false
        created = true
    end

    local g = WiseDB.groups[name]

    if created then
        g.iconSize = 36
        g.textSize = 12
        g.padding = 2
        g.dynamic = true
    end

    g.isWiser = true
    g.buttons = {}
    g.actions = nil

    for i = 1, numForms do
        local icon, active, castable, spellID = GetShapeshiftFormInfo(i)
        if spellID then
            local spellName
            if C_Spell and C_Spell.GetSpellInfo then
                local info = C_Spell.GetSpellInfo(spellID)
                spellName = info and info.name
            elseif GetSpellInfo then
                spellName = GetSpellInfo(spellID)
            end

            table.insert(g.buttons, {
                type = "spell",
                value = spellID,
                name = spellName or "",
                icon = icon,
                category = "global"
            })
        end
    end

    if Wise.frames[name] and Wise.frames[name]:IsShown() then
        Wise:UpdateGroupDisplay(name)
    end
end

-- Hook into UpdateWiserInterfaces to refresh forms
local origUpdateWiserInterfaces = Wise.UpdateWiserInterfaces
function Wise:UpdateWiserInterfaces(isSpecChange)
    if origUpdateWiserInterfaces then
        origUpdateWiserInterfaces(self, isSpecChange)
    end
    Wise:UpdateFormsInterface()
end
