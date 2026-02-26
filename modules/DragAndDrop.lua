local addonName, Wise = ...

-- ============================================================================
-- Drag and Drop Handler
-- ============================================================================

function Wise:OnDragReceive(groupName, slotIndex)
    if WiseDB.settings.enableDragDrop == false then return end
    local type, id, subType, param4 = GetCursorInfo()
    
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
             -- Iterate skill lines to find where this slot lives
             -- Note: C_SpellBook doesn't have a direct "GetSkillLineForSlot" AFAIK,
             -- we have to iterate ranges.
             local numSkillLines = C_SpellBook.GetNumSpellBookSkillLines()
             for i = 1, numSkillLines do
                 local info = C_SpellBook.GetSpellBookSkillLineInfo(i)
                 if info and info.itemIndexOffset and info.numSpellBookItems then
                     if bookSlot > info.itemIndexOffset and bookSlot <= (info.itemIndexOffset + info.numSpellBookItems) then
                         -- Found the skill line
                         local currentSpec = GetSpecialization()
                         local currentSpecID = currentSpec and GetSpecializationInfo(currentSpec) or nil

                         if info.specID then
                             category = "spec"
                             sourceSpecID = info.specID
                         elseif info.name == "General" then
                             category = "global"
                         else
                             -- Class line (no spec ID, not General)
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
             Wise:ReplaceSlotAction(groupName, slotIndex, "spell", finalSpellID, category, extra)
             ClearCursor()
        end
        
    elseif type == "item" then
        -- GetCursorInfo returns: "item", itemID, itemLink
        Wise:ReplaceSlotAction(groupName, slotIndex, "item", id)
        ClearCursor()
        
    elseif type == "macro" then
        -- GetMacroInfo(index) returns name, icon, body.
        local name = GetMacroInfo(id)
        if name then
            Wise:ReplaceSlotAction(groupName, slotIndex, "macro", name)
            ClearCursor()
        end
        
    elseif type == "mount" then
        -- "mount", mountID
        Wise:ReplaceSlotAction(groupName, slotIndex, "mount", id)
        ClearCursor()
        
    elseif type == "battlepet" then
        -- "battlepet", petID
        Wise:ReplaceSlotAction(groupName, slotIndex, "battlepet", id)
        ClearCursor()
        
    elseif type == "equipmentset" then
        -- "equipmentset", setID
         local name = C_EquipmentSet.GetEquipmentSetInfo(id)
         if name then
            Wise:ReplaceSlotAction(groupName, slotIndex, "equipmentset", name)
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
