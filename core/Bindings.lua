-- Bindings.lua: Centralized keybind retrieval for Wise
local addonName, Wise = ...

-- Returns display text and raw key for a given group slot.
-- Hierarchy: 1) Slot-specific binding, 2) Interface-level binding (slot 1 only), 3) WoW keybinding fallback
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

    -- 1.5. Interface-level binding (slot 1 only) if no slot-specific binding exists
    if slotIndex == 1 and group.binding and group.binding ~= "" then
        return Wise:FormatKeybindText(group.binding), group.binding
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

-- Format raw keybind text for display (e.g. ALT-Q -> A-Q)
function Wise:FormatKeybindText(text)
    if not text then return nil end
    text = text:gsub("ALT%-", "A-")
    text = text:gsub("CTRL%-", "C-")
    text = text:gsub("SHIFT%-", "S-")
    text = text:gsub("SPACE", "Spc")
    text = text:gsub("MOUSEWHEELUP", "MwU")
    text = text:gsub("MOUSEWHEELDOWN", "MwD")
    text = text:gsub("MIDDLEMOUSE", "M3")
    text = text:gsub("BUTTON4", "M4")
    text = text:gsub("BUTTON5", "M5")
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
        return "WoW Action: " .. existingAction, "SYSTEM"
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
