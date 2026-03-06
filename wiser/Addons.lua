local addonName, Wise = ...

Wise.ADDON_VIS_TEMPLATE = "Addon visibility"

function Wise:EnsureAddonVisGroup()
    if not WiseDB or not WiseDB.groups then return end
    local name = Wise.ADDON_VIS_TEMPLATE
    if not WiseDB.groups[name] then
        Wise:CreateGroup(name, "circle")
        WiseDB.groups[name].enabled = false
    end
    local g = WiseDB.groups[name]
    -- Migration: strip isWiser if it was set previously
    g.isWiser = nil
    g.isAddonVisibility = true
end

function Wise:UpdateAddonsWiserInterface()
    Wise:EnsureAddonVisGroup()
end
