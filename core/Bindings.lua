-- Bindings.lua: Centralized keybind retrieval for Wise
local addonName, Wise = ...

-- Returns display text and raw key for a given group slot.
-- Hierarchy: 1) Slot-specific binding, 2) WoW keybinding fallback
function Wise:GetKeybind(groupName, slotIndex)
    if not groupName then return nil end
    local group = WiseDB.groups[groupName]
    if not group then return nil end

    -- 1. Slot-specific binding
    if group.actions and group.actions[slotIndex] then
        local slotKey = group.actions[slotIndex].keybind
        if slotKey and slotKey ~= "" then
            return Wise:FormatKeybindText(slotKey), slotKey
        end
    end

    -- 2. Check for nested interface bindings
    if group.actions and group.actions[slotIndex] then
        for _, state in ipairs(group.actions[slotIndex]) do
            if state.type == "interface" then
                local targetGroupName = state.value
                local targetGroup = WiseDB.groups[targetGroupName]
                if targetGroup then
                    -- 2a. Explicit Interface Binding
                    if targetGroup.binding and targetGroup.binding ~= "" then
                        return Wise:FormatKeybindText(targetGroup.binding), targetGroup.binding
                    end

                    -- 2b. Check for ANY slot binding
                    if targetGroup.actions then
                        for _, actionList in pairs(targetGroup.actions) do
                            if actionList.keybind and actionList.keybind ~= "" then
                                return "**", "**" -- Double asterisk indicates "slots bound below"
                            end
                        end
                    end
                end
            end
        end
    end

    -- 3. WoW keybinding fallback (check if button has a WoW binding)
    local f = Wise.frames[groupName]
    if f and f.buttons then
        for _, btn in ipairs(f.buttons) do
            if btn.slot == slotIndex and btn:GetName() then
                local key = GetBindingKey("CLICK " .. btn:GetName() .. ":LeftButton")
                if key then
                    return Wise:FormatKeybindText(key), key
                end
            end
        end
    end

    return nil
end

-- Returns the group-level (interface toggle) binding text for display on buttons.
-- This is the keybind that shows/hides the entire interface.
function Wise:GetInterfaceKeybind(groupName)
    if not groupName then return nil end
    local group = WiseDB.groups[groupName]
    if not group then return nil end

    if group.binding and group.binding ~= "" then
        return Wise:FormatKeybindText(group.binding), group.binding
    end

    return nil
end

-- Format raw keybind text for display (max 3 chars)
-- Compound modifier+mouse patterns handled first to stay within 3 chars
function Wise:FormatKeybindText(text)
    if not text then return nil end
    -- 1. Compound: modifier + mousewheel
    text = text:gsub("ALT%-MOUSEWHEELUP", "AMWU")
    text = text:gsub("ALT%-MOUSEWHEELDOWN", "AMWD")
    text = text:gsub("CTRL%-MOUSEWHEELUP", "CMWU")
    text = text:gsub("CTRL%-MOUSEWHEELDOWN", "CMWD")
    text = text:gsub("SHIFT%-MOUSEWHEELUP", "SMWU")
    text = text:gsub("SHIFT%-MOUSEWHEELDOWN", "SMWD")
    -- 2. Compound: modifier + mouse button (e.g. SHIFT-BUTTON3 -> S3)
    text = text:gsub("ALT%-BUTTON(%d)", "A%1")
    text = text:gsub("CTRL%-BUTTON(%d)", "C%1")
    text = text:gsub("SHIFT%-BUTTON(%d)", "S%1")
    text = text:gsub("ALT%-MIDDLEMOUSE", "A3")
    text = text:gsub("CTRL%-MIDDLEMOUSE", "C3")
    text = text:gsub("SHIFT%-MIDDLEMOUSE", "S3")
    -- 3. Simple replacements
    text = text:gsub("ALT%-", "A-")
    text = text:gsub("CTRL%-", "C-")
    text = text:gsub("SHIFT%-", "S-")
    text = text:gsub("SPACE", "Spc")
    text = text:gsub("MOUSEWHEELUP", "MWU")
    text = text:gsub("MOUSEWHEELDOWN", "MWD")
    text = text:gsub("MIDDLEMOUSE", "M3")
    text = text:gsub("BUTTON3", "M3")
    text = text:gsub("BUTTON4", "M4")
    text = text:gsub("BUTTON5", "M5")
    text = text:gsub("MINUS", "-")
    text = text:gsub("EQUALS", "=")
    text = text:gsub("NUMPADMINUS", "N-")
    text = text:gsub("NUMPADEQUALS", "N=")
    text = text:gsub("NUMPADPLUS", "N+")
    text = text:gsub("NUMPADMULTIPLY", "N*")
    text = text:gsub("NUMPADDIVIDE", "N/")
    text = text:gsub("NUMPADDECIMAL", "N.")
    text = text:gsub("NUMPAD(%d)", "N%1")
    text = text:gsub("PAGEUP", "PU")
    text = text:gsub("PAGEDOWN", "PD")
    text = text:gsub("INSERT", "Ins")
    text = text:gsub("DELETE", "Del")
    text = text:gsub("HOME", "Hm")
    text = text:gsub("END", "End")
    text = text:gsub("BACKSPACE", "BS")
    text = text:gsub("CAPSLOCK", "Caps")
    text = text:gsub("NUMLOCK", "Num")
    return text
end

function Wise:FindKeybindOwner(key)
    if not key or key == "" then return nil, nil end
    for groupName, group in pairs(WiseDB.groups) do
        if group.binding == key then
            return groupName, nil
        end
        if group.actions then
            for slotIdx, actionList in pairs(group.actions) do
                if actionList.keybind == key then
                    return groupName, slotIdx
                end
            end
        end
    end

    -- Check WoW global bindings
    local existingAction = GetBindingAction(key)
    if existingAction and existingAction ~= "" then
        return existingAction, "SYSTEM"
    end

    return nil, nil
end

function Wise:ClearKeybind(groupName, slotIdx)
    local group = WiseDB.groups[groupName]
    if not group then return end
    if slotIdx then
        if group.actions and group.actions[slotIdx] then
            group.actions[slotIdx].keybind = nil
        end
    else
        group.binding = nil
    end
end

-- Returns binding text specifically for the interface list (sidebar).
-- Returns explicit interface binding if exists, otherwise "**" if any slot is bound.
function Wise:GetInterfaceListBindingText(groupName)
    if not groupName then return nil end
    local group = WiseDB.groups[groupName]
    if not group then return nil end

    -- 1. Explicit Interface Binding
    if group.binding and group.binding ~= "" then
        return Wise:FormatKeybindText(group.binding)
    end

    -- 2. Check for ANY slot binding
    if group.actions then
        for _, actionList in pairs(group.actions) do
            if actionList.keybind and actionList.keybind ~= "" then
                return "**" -- Double asterisk indicates "slots bound below"
            end
        end
    end

    return nil
end
