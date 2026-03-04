import re

with open("modules/DragAndDrop.lua", "r") as f:
    content = f.read()

# Modify StartDragHighlight
# Find Wise:StartDragHighlight function
highlight_func = '''function Wise:StartDragHighlight()
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
end'''

new_highlight_func = '''function Wise:StartDragHighlight()
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
end'''

content = content.replace(highlight_func, new_highlight_func)

# Modify StopDragHighlight
stop_highlight_func = '''function Wise:StopDragHighlight()
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
end'''

new_stop_highlight_func = '''function Wise:StopDragHighlight()
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
end'''

content = content.replace(stop_highlight_func, new_stop_highlight_func)

with open("modules/DragAndDrop.lua", "w") as f:
    f.write(content)
