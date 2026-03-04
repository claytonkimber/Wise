local addonName, Wise = ...

-- ============================================================================
-- Drag and Drop Handler
-- ============================================================================

function Wise:OnDragReceive(groupName, slotIndex, isAppend, stateIndex)
    if WiseDB.settings.enableDragDrop == false then return end
    local type, id, subType, param4 = GetCursorInfo()

    -- Helper: route to append, replace-state, or replace-slot
    local function applyAction(actionType, actionValue, category, extra)
        if isAppend then
            Wise:AddAction(groupName, slotIndex, actionType, actionValue, category, extra)
            Wise:UpdateGroupDisplay(groupName)
            Wise:UpdateOptionsUI()
        elseif stateIndex then
            Wise:ReplaceStateAction(groupName, slotIndex, stateIndex, actionType, actionValue, category, extra)
        else
            Wise:ReplaceSlotAction(groupName, slotIndex, actionType, actionValue, category, extra)
        end
    end

    if type == "spell" then
        -- Standard GetCursorInfo for spell: "spell", slotIndex, bookType, spellID
        local _, bookSlot, bookType, spellID = GetCursorInfo()

        local finalSpellID = spellID
        local category = "global"
        local sourceSpecID = nil

        if not finalSpellID and bookSlot then
             if C_SpellBook and C_SpellBook.GetSpellBookItemInfo then
                 local info = C_SpellBook.GetSpellBookItemInfo(bookSlot, bookType)
                 if info then finalSpellID = info.spellID end
             elseif GetSpellInfo then
                 local _, _, _, _, _, _, sID = GetSpellInfo(bookSlot, bookType)
                 finalSpellID = sID
             end
        end

        -- Categorize the spell using SpellBook Info
        if finalSpellID and bookSlot and C_SpellBook and C_SpellBook.GetSpellBookItemType then
             local numSkillLines = C_SpellBook.GetNumSpellBookSkillLines()
             for i = 1, numSkillLines do
                 local info = C_SpellBook.GetSpellBookSkillLineInfo(i)
                 if info and info.itemIndexOffset and info.numSpellBookItems then
                     if bookSlot > info.itemIndexOffset and bookSlot <= (info.itemIndexOffset + info.numSpellBookItems) then
                         local currentSpec = GetSpecialization()
                         local currentSpecID = currentSpec and GetSpecializationInfo(currentSpec) or nil

                         if info.specID then
                             category = "spec"
                             sourceSpecID = info.specID
                         elseif info.name == "General" then
                             category = "global"
                         else
                             category = "class"
                         end
                         break
                     end
                 end
             end
        end

        if finalSpellID then
             local extra = {}
             if sourceSpecID then extra.sourceSpecID = sourceSpecID end
             applyAction("spell", finalSpellID, category, extra)
             ClearCursor()
        end

    elseif type == "item" then
        applyAction("item", id)
        ClearCursor()

    elseif type == "macro" then
        local name = GetMacroInfo(id)
        if name then
            applyAction("macro", name)
            ClearCursor()
        end

    elseif type == "mount" then
        applyAction("mount", id)
        ClearCursor()

    elseif type == "battlepet" then
        applyAction("battlepet", id)
        ClearCursor()

    elseif type == "equipmentset" then
         local name = C_EquipmentSet.GetEquipmentSetInfo(id)
         if name then
            applyAction("equipmentset", name)
            ClearCursor()
         end
    end
end

-- ============================================================================
-- Drag and Drop Highlighting
-- ============================================================================

function Wise:StartDragHighlight()
    -- Only if not in combat (secure frames cannot be modified in combat)
    if InCombatLockdown() then return end
    if WiseDB.settings.enableDragDrop == false then return end

    for groupName, f in pairs(Wise.frames) do
        if f:IsShown() and f.buttons then
             for _, btn in ipairs(f.buttons) do
                 if btn:IsShown() then
                     Wise:ShowOverlayGlow(btn)
                     -- Optional: set a distinct color or texture?
                     -- For now, reusing the existing "proc glow" is easiest,
                     -- but ideally we'd use a different visual to distinguish "drop target" vs "proc".
                     -- Let's stick to the glow for now as requested.
                 end
             end
        end
    end

    -- Options Interface Highlight
    if Wise.OptionsFrame and Wise.OptionsFrame:IsShown() and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.Content and Wise.OptionsFrame.Middle.Content.slots then
        for _, slot in ipairs(Wise.OptionsFrame.Middle.Content.slots) do
            if slot:IsShown() then
                slot:SetBackdropBorderColor(0, 1, 0, 1) -- Green outline for slots
                if slot.ActionButtons then
                    for _, btn in ipairs(slot.ActionButtons) do
                        if btn:IsShown() then
                            -- maybe glow the buttons? or just the slot is fine.
                            -- Let's glow the buttons to be explicit
                            Wise:ShowOverlayGlow(btn)
                        end
                    end
                end
                if slot.AddStateBtn and slot.AddStateBtn:IsShown() then
                     Wise:ShowOverlayGlow(slot.AddStateBtn)
                end
            end
        end
    end
end

function Wise:StopDragHighlight()
    -- Clear glows from all buttons
    -- Note: This might clear legitimate proc glows too! 
    -- We should perhaps only clear if we instigated it, or just refresh usability after drop.
    
    for groupName, f in pairs(Wise.frames) do
        if f.buttons then
             for _, btn in ipairs(f.buttons) do
                 -- Check if this button actually has a proc? If so, don't hide.
                 -- For simplicity, hide all, then trigger usability update to restore procs.
                 Wise:HideOverlayGlow(btn)
             end
        end
    end

    -- Options Interface Highlight Removal
    if Wise.OptionsFrame and Wise.OptionsFrame:IsShown() and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.Content and Wise.OptionsFrame.Middle.Content.slots then
        for _, slot in ipairs(Wise.OptionsFrame.Middle.Content.slots) do
            if slot:IsShown() then
                -- Restore selected color or default
                if Wise.selectedSlot == slot.slotID then
                    slot:SetBackdropBorderColor(1, 0.8, 0, 1) -- Gold Selected
                else
                    slot:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                end

                if slot.ActionButtons then
                    for _, btn in ipairs(slot.ActionButtons) do
                        if btn:IsShown() then
                            Wise:HideOverlayGlow(btn)
                        end
                    end
                end
                if slot.AddStateBtn and slot.AddStateBtn:IsShown() then
                     Wise:HideOverlayGlow(slot.AddStateBtn)
                end
            end
        end
    end
    
    -- Restore legitimate proc glows
    C_Timer.After(0.1, function()
        Wise:UpdateAllUsability()
    end)
end

-- Drag Tracker Frame
local dragTracker = CreateFrame("Frame")
dragTracker:RegisterEvent("CURSOR_CHANGED")
dragTracker:SetScript("OnEvent", function(self, event)
    if InCombatLockdown() then return end
    
    local cursorType = GetCursorInfo()
    if cursorType then
        -- Cursor has something tracked
        Wise:StartDragHighlight()
    else
        Wise:StopDragHighlight()
    end
end)
