local addonName, Wise = ...

-- ============================================================================
-- Tooltip Module
-- Handles generic and Wise-specific tooltip logic
-- ============================================================================

-- Generic Tooltip Helper
-- Adds a static text tooltip to any frame
function Wise:AddTooltip(frame, text, anchor)
    if not frame then return end

    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
        GameTooltip:SetText(text, nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)

    frame:HookScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
end

-- Interface Tooltip Logic
-- Dynamically shows tooltip based on button content (spell, item, macro, etc.)
-- Respects the 'showTooltips' setting
function Wise:AddInterfaceTooltip(btn)
    if not btn then return end

    btn:HookScript("OnEnter", function(self)
        -- Check setting
        if not WiseDB.settings.showTooltips then return end

        -- Determine Anchor
        -- Using ANCHOR_CURSOR to avoid obscuring other ring buttons
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")

        -- Prioritize Metadata (Reliable cache from GUI.lua)
        local meta = Wise.buttonMeta and Wise.buttonMeta[self]
        local type = (meta and meta.actionType) or self.actionType
        local value = (meta and meta.actionValue) or self.actionValue
        local data = (meta and meta.actionData) or self.actionData

        if type == "spell" then
            local spellID = (meta and meta.spellID)

            if not spellID then
                if tonumber(value) then
                    spellID = tonumber(value)
                else
                    local info = C_Spell.GetSpellInfo(value)
                    if info then spellID = info.spellID end
                end
            end

            if spellID then
                GameTooltip:SetSpellByID(spellID)
            else
                GameTooltip:SetText(value or "Unknown Spell", 1, 1, 1)
            end

        elseif type == "item" or type == "toy" then
            local itemID = (meta and meta.itemID)
            if not itemID then itemID = tonumber(value) end

            if itemID then
                GameTooltip:SetItemByID(itemID)
            else
                -- Try hyperlink or name
                local link = select(2, C_Item.GetItemInfo(value))
                if link then
                    GameTooltip:SetHyperlink(link)
                else
                    GameTooltip:SetText(value or "Unknown Item", 1, 1, 1)
                end
            end

        elseif type == "macro" then
            GameTooltip:SetText("Macro: " .. tostring(value), 1, 1, 1)
            local name, icon, body = GetMacroInfo(value)
            if body then
                GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true)
            end

        elseif type == "custom_macro" then
            GameTooltip:SetText("Custom Macro", 1, 1, 1)
            if data and data.macroText then
                GameTooltip:AddLine(data.macroText, 0.8, 0.8, 0.8, true)
            end

        elseif type == "mount" then
            local mountID = tonumber(value)
            if C_MountJournal and mountID then
                 local name, spellID, _, _, _, _, _, _, _, _, isCollected = C_MountJournal.GetMountInfoByID(mountID)
                 if spellID then
                     GameTooltip:SetSpellByID(spellID)
                 else
                     GameTooltip:SetText(name or "Mount " .. mountID, 1, 1, 1)
                 end

                 if isCollected ~= nil then
                     if isCollected then
                         GameTooltip:AddLine("Collected", 0, 1, 0)
                     else
                         GameTooltip:AddLine("Not Collected", 1, 0, 0)
                     end
                 end
            else
                GameTooltip:SetText("Mount: " .. tostring(value), 1, 1, 1)
            end

        elseif type == "battlepet" then
             GameTooltip:SetText("Pet: " .. tostring(value), 1, 1, 1)
             -- Advanced pet tooltip logic requires speciesID, mostly handled by specialized addons or convoluted API

        elseif type == "equipmentset" then
             GameTooltip:SetText("Equipment Set: " .. tostring(value), 1, 1, 1)

        elseif type == "interface" then
             GameTooltip:SetText("Open Interface: " .. tostring(value), 1, 0.82, 0)

        elseif type == "uipanel" then
             local label = value:gsub("^%l", string.upper) -- Capitalize
             GameTooltip:SetText("Toggle " .. label, 1, 1, 1)

        elseif type == "misc" then
             local label = value
             if value == "hearthstone" then label = "Hearthstone"
             elseif value == "extrabutton" then label = "Extra Action Button"
             elseif value == "zoneability" then label = "Zone Ability"
             elseif value == "leave_vehicle" then label = "Leave Vehicle"
             elseif value:match("^spec_") then
                 local val = tonumber(value:match("^spec_(%d+)"))
                 local name
                 if val then
                     if val <= 10 then
                         local _, sName = GetSpecializationInfo(val)
                         name = sName
                     elseif GetSpecializationInfoByID then
                         local _, sName = GetSpecializationInfoByID(val)
                         name = sName
                     end
                 end
                 label = "Activate " .. (name or ("Spec " .. (val or "?")))
             elseif value:match("^lootspec_") then
                 local id = tonumber(value:match("^lootspec_(%d+)"))
                 local name
                 if id and GetSpecializationInfoByID then
                     _, name = GetSpecializationInfoByID(id)
                 end
                 label = "Set Loot Spec: " .. (name or (id or "?"))
             end

             GameTooltip:SetText(label, 1, 1, 1)

        else
             -- Fallback
             GameTooltip:SetText(tostring(value), 1, 1, 1)
        end

        GameTooltip:Show()
    end)

    btn:HookScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
end

function Wise:InitTooltips()
    -- Placeholder for any tooltip-specific initialization
    -- (e.g. hooking GameTooltip if needed, though usually not required)
end
