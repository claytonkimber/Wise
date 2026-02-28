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
                type = "misc",
                value = "custom_macro",
                macroText = "/cast " .. (spellName or ""),
                name = spellName or "",
                icon = icon,
                category = "global",
                extra = { formID = i }
            })
        end
    end

    if Wise.frames[name] and Wise.frames[name]:IsShown() then
        Wise:UpdateGroupDisplay(name)
    end

    Wise:UpdateFormsCheckedState()
end

function Wise:UpdateFormsCheckedState()
    local name = "Forms"
    local f = Wise.frames[name]
    if not f or not f.buttons then return end

    for _, btn in ipairs(f.buttons) do
        local meta = Wise.buttonMeta and Wise.buttonMeta[btn]
        local actionData = meta and meta.actionData or btn.actionData

        if actionData and actionData.extra and actionData.extra.formID then
            local _, active = GetShapeshiftFormInfo(actionData.extra.formID)
            btn:SetChecked(active)

            local vClone = meta and meta.visualClone or btn.visualClone
            if vClone then
                vClone:SetChecked(active)
            end
        else
            btn:SetChecked(false)
            local vClone = meta and meta.visualClone or btn.visualClone
            if vClone then
                vClone:SetChecked(false)
            end
        end
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

-- Register Event to handle dynamic stance switching and data loading
local formEventFrame = CreateFrame("Frame")
formEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
formEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORMS")

formEventFrame:SetScript("OnEvent", function(self, event)
    if event == "UPDATE_SHAPESHIFT_FORMS" then
        -- This event fires when stances are added/removed (e.g. loading screen/spec change)
        if Wise.UpdateFormsInterface then
            Wise:UpdateFormsInterface()
        end
    elseif event == "UPDATE_SHAPESHIFT_FORM" then
        -- This event fires when the player shifts in/out of a stance
        if Wise.UpdateFormsCheckedState then
            Wise:UpdateFormsCheckedState()
        end
    end
end)
