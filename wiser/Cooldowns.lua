local addonName, Wise = ...

-- Register property hook for CooldownWiser interfaces
function Wise:InitializeCooldownWiser()
    -- Initialize hook for CooldownWiser
    Wise.PropertyHooks = Wise.PropertyHooks or {}
    Wise.PropertyHooks["CooldownWiser"] = {
        suppress = {
            Actions = false, -- We want to allow editing actions to add decimal slots
            Rename = true, -- Usually shouldn't rename Wiser interfaces
        },
        inject = {
            Bottom = function(panel, group, y)
                local tinsert = table.insert
                local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
                check:SetSize(24, 24)
                check:SetPoint("TOPLEFT", 10, y)
                check.text = check:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                check.text:SetPoint("LEFT", check, "RIGHT", 4, 1)
                check.text:SetText("Hide Game Interface")
                check:SetChecked(group.hideNativeInterface or false)

                check:SetScript("OnClick", function(self)
                    group.hideNativeInterface = self:GetChecked()
                    Wise:UpdateCooldownWiser(Wise.selectedGroup, group.viewerName)
                end)

                tinsert(panel.controls, check)
                tinsert(panel.controls, check.text)

                return y - 30
            end
        }
    }
end

-- Initialize the property hook
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event)
    Wise:InitializeCooldownWiser()
end)

function Wise:UpdateCooldownWiser(groupName, viewerName)
    local group = WiseDB.groups[groupName]
    if not group then return end

    local viewer = _G[viewerName]
    if not viewer then return end

    group.viewerName = viewerName

    if not InCombatLockdown() then
        if group.hideNativeInterface then
            viewer:Hide()
        else
            viewer:Show()
        end
    end

    local spells = {}
    if viewer.GetChildren then
        local children = { viewer:GetChildren() }
        table.sort(children, function(a, b)
            return (a.layoutIndex or 0) < (b.layoutIndex or 0)
        end)

        for _, child in ipairs(children) do
            if child:IsShown() then
                 local spellID = child.spellID
                 if not spellID and child.cooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                     local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(child.cooldownID)
                     if info then spellID = info.spellID end
                 end

                 if spellID then
                      local alreadyExists = false
                      for _, s in ipairs(spells) do
                          if s == spellID then alreadyExists = true break end
                      end
                      if not alreadyExists then
                          table.insert(spells, spellID)
                      end
                 end
            end
        end
    end

    if Wise.MigrateGroupToActions then
        Wise:MigrateGroupToActions(group)
    end

    group.actions = group.actions or {}
    group.dynamic = true
    group.propertyType = "CooldownWiser"

    -- Replace all integer (auto-loaded) slots with the viewer's current spells 1:1.
    -- Viewer spell 1 → Slot 1, viewer spell 2 → Slot 2, etc.
    -- User-added decimal slots (e.g. 1.1, 2.5) are preserved untouched.

    -- 1. Remove all existing integer slots (auto-loaded content from previous spec)
    local keysToRemove = {}
    for slotIdx in pairs(group.actions) do
        if type(slotIdx) == "number" and slotIdx == math.floor(slotIdx) then
            table.insert(keysToRemove, slotIdx)
        end
    end
    for _, k in ipairs(keysToRemove) do
        group.actions[k] = nil
    end

    -- 2. Write current viewer spells into integer slots 1..N
    for i = 1, #spells do
        local spellID = spells[i]
        group.actions[i] = {
            { type = "spell", value = spellID, autoLoaded = true }
        }
    end

    if Wise.UpdateGroupDisplay and Wise.frames[groupName] and Wise.frames[groupName]:IsShown() then
        Wise:UpdateGroupDisplay(groupName)
    end
end
