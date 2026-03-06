local addonName, Wise = ...

local tinsert = table.insert

-- Inject Action into Picker
local origGetMisc = Wise.GetMiscellaneous
function Wise:GetMiscellaneous(filter)
    local items = {}
    if origGetMisc then
        items = origGetMisc(self, filter)
    end
    tinsert(items, {name="Addon Magic", val="addon_magic", icon="Interface\\Icons\\INV_Misc_EngGizmos_11", type="misc"})
    return items
end

-- Inject Action Name Resolver
local origGetActionName = Wise.GetActionName
function Wise:GetActionName(actionType, value, extraData)
    if actionType == "misc" and value == "addon_magic" then
        return "Addon Magic"
    end
    if origGetActionName then
        return origGetActionName(self, actionType, value, extraData)
    end
    return value
end

-- Inject Secure Action Resolver
local origGetSecureAttributes = Wise.GetSecureAttributes
function Wise:GetSecureAttributes(aType, aValue, name, actionData, spellID)
    if aType == "misc" and aValue == "addon_magic" then
        local addonListStr = actionData.addons and table.concat(actionData.addons, ",") or ""
        return "macro", "macrotext", "/run Wise:ExecuteAddonMagic('" .. addonListStr .. "')"
    end
    if origGetSecureAttributes then
        return origGetSecureAttributes(self, aType, aValue, name, actionData, spellID)
    end
    return nil, nil, nil
end

-- Execution Function
function Wise:ExecuteAddonMagic(addonStr)
    if not addonStr or addonStr == "" then return end

    local addonsToDisable = {}
    for addon in addonStr:gmatch("[^,]+") do
        addon = strtrim(addon)
        if addon ~= "" then
            C_AddOns.EnableAddOn(addon)
            table.insert(addonsToDisable, addon)
        end
    end

    if #addonsToDisable > 0 then
        WiseDB.addonsToDisable = addonsToDisable
        ReloadUI()
    end
end

-- Login hook to disable previously magic-loaded addons
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, ...)
    if WiseDB and WiseDB.addonsToDisable then
        for _, addonName in ipairs(WiseDB.addonsToDisable) do
            C_AddOns.DisableAddOn(addonName)
        end
        WiseDB.addonsToDisable = nil
    end
end)

-- Properties UI implementation
function Wise:CreateAddonMagicPropertiesPanel(panel, action, y)
    local alabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    alabel:SetPoint("TOPLEFT", 10, y)
    alabel:SetText("Select Addons to Load:")
    tinsert(panel.controls, alabel)
    y = y - 20

    action.addons = action.addons or {}
    local selectedMap = {}
    for _, v in ipairs(action.addons) do selectedMap[v] = true end

    local numAddons = C_AddOns.GetNumAddOns()
    for i = 1, numAddons do
        local name, title = C_AddOns.GetAddOnInfo(i)
        -- Skip Blizzard default addons and Wise itself
        if not name:match("^Blizzard_") and name ~= "Wise" then
            local aCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
            aCheck:SetPoint("TOPLEFT", 10, y)
            aCheck:SetChecked(selectedMap[name] or false)
            aCheck.text = aCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            aCheck.text:SetPoint("LEFT", aCheck, "RIGHT", 5, 0)
            aCheck.text:SetText(title or name)

            aCheck.addonName = name
            aCheck:SetScript("OnClick", function(self)
                local isChecked = self:GetChecked()
                local newAddons = {}
                local added = false
                for _, existing in ipairs(action.addons) do
                    if existing ~= self.addonName then
                        table.insert(newAddons, existing)
                    elseif existing == self.addonName and isChecked then
                        table.insert(newAddons, existing)
                        added = true
                    end
                end
                if isChecked and not added then
                    table.insert(newAddons, self.addonName)
                end
                action.addons = newAddons

                C_Timer.After(0, function()
                    if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    end
                end)
            end)

            tinsert(panel.controls, aCheck)
            tinsert(panel.controls, aCheck.text)
            y = y - 25
        end
    end
    y = y - 10
    return y
end
