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

    -- Get current spec ID for dynamically tagging newly loaded spells
    local specIndex = GetSpecialization()
    local currentSpecID = specIndex and GetSpecializationInfo(specIndex) or nil

    -- Iterate through the detected spells and add them if they don't already exist
    local numSpells = #spells
    for i = 1, numSpells do
        local spellID = spells[i]
        local info = C_Spell.GetSpellInfo(spellID)
        local name = info and info.name or tostring(spellID)

        -- Check if it already exists (by exact spellID or by name)
        local exists = false
        for slotIdx, states in pairs(group.actions) do
            if type(states) == "table" then
                for _, state in ipairs(states) do
                    if state.type == "spell" and (state.value == spellID or state.value == name) then
                        exists = true
                        state.autoLoaded = true
                        -- Upgrade to exact spellID if it was previously saved as a string name
                        if state.value == name and type(state.value) == "string" then
                            state.value = spellID
                        end

                        -- Convert legacy global auto-loaded spells to spec-restricted
                        if currentSpecID and state.category == "global" and state.autoLoaded then
                            state.category = "spec"
                            state.specRequirements = { currentSpecID }
                        -- If a spec restriction exists, append the current spec if missing
                        elseif currentSpecID and state.category == "spec" and type(state.specRequirements) == "table" then
                            local hasSpec = false
                            for _, id in ipairs(state.specRequirements) do
                                if id == currentSpecID then
                                    hasSpec = true
                                    break
                                end
                            end
                            if not hasSpec then
                                table.insert(state.specRequirements, currentSpecID)
                            end
                        end
                        break
                    end
                end
            end
            if exists then break end
        end

        if not exists then
            -- Find next available integer slot
            local nextSlot = 1
            while group.actions[nextSlot] ~= nil do
                nextSlot = nextSlot + 1
            end

            -- If we know the current spec, tag this spell to that spec
            if currentSpecID then
                group.actions[nextSlot] = {
                    { type = "spell", value = spellID, category = "spec", specRequirements = { currentSpecID }, autoLoaded = true }
                }
            else
                group.actions[nextSlot] = {
                    { type = "spell", value = spellID, category = "global", autoLoaded = true }
                }
            end
        end
    end

    if Wise.UpdateGroupDisplay and Wise.frames[groupName] and Wise.frames[groupName]:IsShown() then
        Wise:UpdateGroupDisplay(groupName)
    end
end
