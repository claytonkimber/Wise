local addonName, Wise = ...

function Wise:UpdateAddonVisibility()
    if not WiseDB or not WiseDB.groups then return end
    local addonsGroup = WiseDB.groups["Addon visibility"]
    if not addonsGroup then return end

    local showCond = addonsGroup.visibilitySettings and addonsGroup.visibilitySettings.customShow or ""
    local hideCond = addonsGroup.visibilitySettings and addonsGroup.visibilitySettings.customHide or ""

    for _, action in ipairs(addonsGroup.buttons or {}) do
        if action.type == "uivisibility" then
            local addon = action.value
            if addon == "AllTheThings" and _G.AllTheThingsWindow then
                -- How to set visibility state dynamically using Wise's conditions?
            end
        end
    end
end
