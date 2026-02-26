local addonName, Wise = ...

-- Macro.lua: Handles Custom Macro logic and UI

function Wise:GetMacroText(action)
    return action.macroText or ""
end

function Wise:SetMacroText(action, text)
    action.macroText = text
    -- Auto-rename if currently default
    if not action.name or action.name == "Custom Macro" then
        local class = UnitClass("player")
        local spec = GetSpecialization()
        local specID = spec and GetSpecializationInfo(spec)
        local _, specName = specID and GetSpecializationInfoByID(specID)
        if class and specName then
             action.name = string.format("Macro - %s %s", class, specName)
        end
    end
end

function Wise:CreateMacroEditor(panel, action, y)
    -- 1. Macro Name Editor
    local nameLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameLabel:SetPoint("TOPLEFT", 10, y)
    nameLabel:SetText("Macro Name:")
    table.insert(panel.controls, nameLabel)
    
    y = y - 20
    local nameEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    nameEdit:SetSize(220, 20)
    nameEdit:SetPoint("TOPLEFT", 14, y)
    nameEdit:SetAutoFocus(false)
    nameEdit:SetText(action.name or "Custom Macro")
    nameEdit:SetCursorPosition(0)
    
    nameEdit:SetScript("OnTextChanged", function(self, isUserInput)
        if not isUserInput then return end
        local text = self:GetText()
        if text and text ~= "" then
            action.name = text
        else
            action.name = nil -- Revert to default
        end
        
        -- Targeted refresh to avoid focus loss in properties panel
        if Wise.OptionsFrame and Wise.OptionsFrame:IsShown() then
            Wise:RefreshGroupList()
            if Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.Content then
                Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
            end
        end
    end)
    
    nameEdit:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    
    table.insert(panel.controls, nameEdit)
    y = y - 35

    -- 1.5 Icon Picker
    local iconLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    iconLabel:SetPoint("TOPLEFT", 10, y)
    iconLabel:SetText("Icon:")
    table.insert(panel.controls, iconLabel)

    local iconBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    iconBtn:SetSize(32, 32)
    iconBtn:SetPoint("LEFT", iconLabel, "RIGHT", 10, 0)
    
    iconBtn.icon = iconBtn:CreateTexture(nil, "ARTWORK")
    iconBtn.icon:SetAllPoints()
    
    local function UpdateIconDisplay()
        local tex = action.icon
        if not tex then            
            tex = Wise:GetActionIcon(action.type, action.value, action)
        end
        iconBtn.icon:SetTexture(tex)
    end
    UpdateIconDisplay()
    
    iconBtn:SetScript("OnClick", function()
        Wise:OpenIconPicker(function(type, value)
            -- The icon picker returns "icon" as type and the texture path/ID as value
            if type == "icon" and value then
                action.icon = value
                UpdateIconDisplay()
                Wise:UpdateGroupDisplay(Wise.selectedGroup)
                if Wise.UpdateOptionsUI then
                    Wise:UpdateOptionsUI()
                end
            end
        end)
    end)
    iconBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    table.insert(panel.controls, iconBtn)
    
    y = y - 40 

    -- 2. Macro Body Editor
    local bodyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bodyLabel:SetPoint("TOPLEFT", 10, y)
    bodyLabel:SetText("Macro Command:")
    table.insert(panel.controls, bodyLabel)
    
    y = y - 20
    
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetSize(200, 150)
    scrollFrame:SetPoint("TOPLEFT", 10, y)
    
    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetSize(180, 200)
    -- Replace editBox:SetFont(...) with this:
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetTextColor(1, 1, 1, 1)
    -- Ensure the cursor and shadow don't interfere
    editBox:SetShadowOffset(1, -1)
    editBox:SetShadowColor(0, 0, 0, 0.5)
    editBox:Enable()
    editBox:SetAutoFocus(false) 
    editBox:SetTextInsets(5, 5, 5, 5)

    
    -- Background for EditBox
    local bg = CreateFrame("Frame", nil, scrollFrame, "BackdropTemplate")
    bg:SetPoint("TOPLEFT", -5, 5)
    bg:SetPoint("BOTTOMRIGHT", 25, -5) -- Extend to cover scrollbar area
    bg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    bg:SetBackdropColor(0.1, 0.1, 0.1, 1)
    bg:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    
scrollFrame:SetScrollChild(editBox)
    
    -- FORCE the editbox to a higher level so it's not behind the background
    editBox:SetFrameLevel(scrollFrame:GetFrameLevel() + 2)
    editBox:SetText(action.macroText or "")
    
    -- Character Count
    local charCount = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    charCount:SetPoint("TOPRIGHT", bg, "BOTTOMRIGHT", -5, -2)
    charCount:SetText("0/255")
    table.insert(panel.controls, charCount)

    local function UpdateCharCount(text)
        local count = string.len(text or "")
        charCount:SetText(count .. "/255")
        if count > 255 then
            charCount:SetTextColor(1, 0, 0, 1) -- Red
        else
            charCount:SetTextColor(1, 1, 1, 1) -- White
        end
    end

    -- Helper: Strip colors for saving
    function Wise:StripMacroColors(text)
        if not text then return "" end
        text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
        text = text:gsub("|r", "")
        return text
    end

    -- Helper: Resolve {{spell:ID}} and Highlight known spells
    function Wise:ResolveAndColorMacro(text)
        if not text then return "" end
        
        -- 1. Resolve {{spell:ID}} tags
        text = text:gsub("{{spell:(%d+)}}", function(idStr)
            local id = tonumber(idStr)
            local name = nil
            local valid = false
            
            if C_Spell.DoesSpellExist(id) then
                name = C_Spell.GetSpellName(id)
                valid = true
            elseif GetItemInfo(id) then
                name = GetItemInfo(id)
                valid = true
            end
            
            if valid and name then
                -- Valid: Blue
                return "|cff00ccff" .. name .. "|r" 
            else
                -- Invalid: Red
                return "|cffff0000Unknown(" .. idStr .. ")|r"
            end
        end)
        
        -- 2. Highlight existing spell names in /cast commands?
        -- This is complex because we don't know for sure what is a spell name vs macro condition
        -- Simple approach: Look for lines starting with /cast or /use
        -- And try to verify the last token?
        -- Regex for basic match: (/cast%s+)(.*)
        -- We won't auto-color user typed text continuously as it interferes with typing (color codes inserted while typing = mess)
        -- We only do the {{spell:ID}} resolution which is a distinct replacement action.
        
        return text
    end

    editBox:SetScript("OnTextChanged", function(self, isUserInput)
        local rawText = self:GetText()
        
        -- Check for resolution triggers (only resolve tags, don't force color on everything constantly)
        if rawText:find("{{spell:%d+}}") then
             local resolved = Wise:ResolveAndColorMacro(rawText)
             if resolved ~= rawText then
                 -- Update text and keep cursor?
                 -- Since this usually happens on paste, cursor behavior is less critical
                 self:SetText(resolved)
                 rawText = resolved -- proceed with resolved text
             end
        end
        
        -- Clean text for storage
        local cleanText = Wise:StripMacroColors(rawText)
        
        Wise:SetMacroText(action, cleanText)
        
        UpdateCharCount(cleanText)

        -- Auto-rename text field if it changed
        if action.name and nameEdit:GetText() ~= action.name then
            nameEdit:SetText(action.name)
        end
        
        Wise:UpdateGroupDisplay(Wise.selectedGroup)
        
        -- If user is typing, we might want to refresh the list if the name auto-changed
        if isUserInput then
            -- We don't want to refresh the whole properties panel here as it would lose focus
            -- but we MUST refresh the list if the name changed.
            if Wise.OptionsFrame and Wise.OptionsFrame:IsShown() then
                 Wise:RefreshGroupList()
                 if Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.Content then
                      Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
                 end
            end
        end
    end)
    
    -- Initial Update (Apply initial resolution/coloring)
    local initialText = action.macroText or ""
    local resolvedInitial = Wise:ResolveAndColorMacro(initialText)
    editBox:SetText(resolvedInitial)
    if initialText ~= resolvedInitial then
         -- Update saved state if resolution happened immediately (e.g. legacy data)
         Wise:SetMacroText(action, Wise:StripMacroColors(resolvedInitial))
    end
    UpdateCharCount(Wise:StripMacroColors(resolvedInitial))
    
    editBox:SetScript("OnCursorChanged", function(self, x, y, w, h)
        -- Handle scrolling
    end)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    table.insert(panel.controls, scrollFrame)
    table.insert(panel.controls, bg) -- Add bg to controls to hide it later
    
    y = y - 160
    
    return y
end
