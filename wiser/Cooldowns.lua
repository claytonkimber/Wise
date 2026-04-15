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

-- Hook Blizzard viewer Layout so we re-sync whenever the viewer rebuilds its
-- children (spec change, reload, talent swap, etc.).  This eliminates all
-- timing guesswork — we read the children right after Blizzard finishes
-- populating them.
do
    local hookedViewers = {}
    local pendingResync = {}

    function Wise:HookCooldownViewerLayout(viewerName, groupName)
        if hookedViewers[viewerName] then return end
        local viewer = _G[viewerName]
        if not viewer then return end
        hookedViewers[viewerName] = true

        hooksecurefunc(viewer, "Layout", function()
            -- Debounce: Layout can fire many times in quick succession
            if pendingResync[groupName] then return end
            pendingResync[groupName] = true
            C_Timer.After(0, function()
                pendingResync[groupName] = nil
                -- Skip during combat: spell list can't change mid-fight and
                -- frame properties may be secret values that crash table ops.
                if InCombatLockdown() then return end
                local group = WiseDB and WiseDB.groups[groupName]
                if not group or not group.viewerName then return end
                Wise:_ReadCooldownViewer(groupName, group.viewerName)
            end)
        end)
    end
end

function Wise:UpdateCooldownWiser(groupName, viewerName)
    local group = WiseDB.groups[groupName]
    if not group then return end

    local viewer = _G[viewerName]
    if not viewer then return end

    group.viewerName = viewerName

    -- Hook the viewer's Layout so future rebuilds (spec change, etc.) auto-sync
    if Wise.HookCooldownViewerLayout then
        Wise:HookCooldownViewerLayout(viewerName, groupName)
    end

    -- If the viewer is hidden (e.g. "Hide Game Interface" is on), we must
    -- temporarily show it so Blizzard populates its children for the current
    -- spec, then defer the read to give Layout() a frame to run.
    local needsTempShow = group.hideNativeInterface and not viewer:IsShown()
    if needsTempShow and not InCombatLockdown() then
        viewer:Show()
        -- Defer: let Blizzard's Layout run, then read children and re-hide
        C_Timer.After(0, function()
            Wise:_ReadCooldownViewer(groupName, viewerName)
            if not InCombatLockdown() and group.hideNativeInterface then
                viewer:Hide()
            end
        end)
        return
    end

    if not InCombatLockdown() then
        if group.hideNativeInterface then
            viewer:Hide()
        else
            viewer:Show()
        end
    end

    Wise:_ReadCooldownViewer(groupName, viewerName)
end

-- Internal: read spells from a Blizzard CooldownViewer and sync to group actions
function Wise:_ReadCooldownViewer(groupName, viewerName)
    -- Frame child properties (spellID, layoutIndex) are secret values during
    -- combat that cannot be used as table keys or in comparisons. Defer the
    -- sync until combat ends — the spell list cannot change mid-fight anyway.
    if InCombatLockdown() then
        Wise._pendingViewerSync = Wise._pendingViewerSync or {}
        Wise._pendingViewerSync[groupName] = viewerName
        return
    end

    local group = WiseDB.groups[groupName]
    if not group then return end

    local viewer = _G[viewerName]
    if not viewer then return end

    local spells = {}
    local seen = {}
    if viewer.GetChildren then
        local children = { viewer:GetChildren() }
        table.sort(children, function(a, b)
            local ai = tonumber(a.layoutIndex) or 0
            local bi = tonumber(b.layoutIndex) or 0
            return ai < bi
        end)

        for _, child in ipairs(children) do
            if child:IsShown() then
                 local spellID = child.spellID
                 if not spellID and child.GetSpellID then
                     spellID = child:GetSpellID()
                 end
                 if not spellID and child.cooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                     local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(child.cooldownID)
                     if info then spellID = info.spellID end
                 end

                 if spellID then
                      -- tonumber(tostring(...)) forces a fresh untainted number. Plain tonumber()
                      -- on an already-numeric value returns the same (possibly tainted) value,
                      -- which is why we route through tostring first. Secrets cannot be used as
                      -- table keys or in comparisons, so we skip any value that can't be converted.
                      spellID = tonumber(tostring(spellID))
                      if spellID then
                          -- Normalize to override spell so base+override don't appear as two entries
                          local resolvedID = Wise:GetOverrideSpellID(spellID) or spellID
                          resolvedID = tonumber(tostring(resolvedID))
                          if resolvedID and not seen[resolvedID] then
                              seen[resolvedID] = true
                              table.insert(spells, resolvedID)
                          end
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

    if Wise.UpdateGroupDisplay and Wise.frames[groupName] then
        Wise:UpdateGroupDisplay(groupName)
    end
end
