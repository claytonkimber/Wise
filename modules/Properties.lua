local addonName, Wise = ...
local tinsert = table.insert

StaticPopupDialogs["WISE_BINDING_ERROR"] = {
    text = "|cffff0000%s|r",
    button1 = "OK",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function Wise:ValidateMouseWheelBinding(group, isSlot)
    if isSlot then
         return false, "Direct slot bindings require a button release event, which Mouse Wheel does not support."
    end

    -- Group Binding Logic
    local trigger = (group.keybindSettings and group.keybindSettings.trigger) or "release_mouseover"
    local held = group.visibilitySettings and group.visibilitySettings.held
    local toggle = group.visibilitySettings and group.visibilitySettings.toggleOnPress

    if held then
        return false, "Mouse Wheel inputs cannot be used with 'Hold to Show' (requires release)."
    end

    if trigger == "press" then
        return true
    end

    if toggle then
        -- Toggle mode usually forces trigger="none", but effectively works on press
        return true
    end

    -- Default triggers (release_mouseover, release_repeat) require release
    return false, "Mouse Wheel inputs can only be used with 'Toggle on Press' (no trigger) or 'On Key Press' trigger methods."
end

local function CreateConditionValidator(editBox, panel)
    local status = CreateFrame("Button", nil, panel)
    status:SetSize(20, 20)
    status:SetPoint("LEFT", editBox, "RIGHT", 5, 0)

    status.icon = status:CreateTexture(nil, "ARTWORK")
    status.icon:SetAllPoints()
    status:Hide()

    local function UpdateStatus()
        local text = editBox:GetText()
        if not Wise.ValidateVisibilityCondition then return end

        local isValid, err = Wise:ValidateVisibilityCondition(text)

        if isValid then
            if text ~= "" then
                status.icon:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
                status:Show()
                status.isValid = true
                status.tooltip = "Valid Condition"
            else
                status:Hide()
                status.isValid = true
                status.tooltip = nil
            end
        else
            status.icon:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
            status:Show()
            status.isValid = false
            status.tooltip = err
        end
    end

    editBox:HookScript("OnTextChanged", UpdateStatus)
    editBox:HookScript("OnShow", UpdateStatus)

    status:SetScript("OnEnter", function(self)
        if self.tooltip then
             GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
             if self.isValid then
                 GameTooltip:SetText(self.tooltip, 0, 1, 0)
             else
                 GameTooltip:SetText("Invalid Condition", 1, 0, 0)
                 GameTooltip:AddLine(self.tooltip, 1, 1, 1)
             end
             GameTooltip:Show()
        end
    end)
    status:SetScript("OnLeave", GameTooltip_Hide)

    UpdateStatus()
    return status
end

StaticPopupDialogs["WISE_CONFIRM_BINDING_OVERWRITE"] = {
    text = "Key '%s' is currently bound to '%s'. Use anyway?",
    button1 = "Yes",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if data.oldOwner then
            Wise:ClearKeybind(data.oldOwner, data.oldSlot)
        end
        if data.isSlotBinding then
            data.group.actions[data.slotIdx].keybind = data.key
        else
            data.group.binding = data.key
        end
        Wise:UpdateBindings()
        if data.btn then
            data.btn:SetText(data.key)
        end
        Wise:UpdateOptionsUI()
    end,
    OnCancel = function(self, data)
        -- Revert text
        if data.btn then
            if data.isSlotBinding then
                data.btn:SetText(data.group.actions[data.slotIdx].keybind or "None")
            else
                data.btn:SetText(data.group.binding or "None")
            end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

function Wise:CheckBindingConflict(key, group, slotIdx, isSlotBinding, btn)
    local oldOwner, oldSlot = Wise:FindKeybindOwner(key)
    if oldOwner then
        local ownerText = oldOwner
        if oldSlot then
            ownerText = oldOwner .. " (Slot " .. oldSlot .. ")"
        end
        -- If it's the exact same binding, do nothing special
        if oldOwner == Wise.selectedGroup and oldSlot == slotIdx then
             return false -- No conflict with itself
        end

        local data = {
            key = key,
            group = group,
            slotIdx = slotIdx,
            isSlotBinding = isSlotBinding,
            oldOwner = oldOwner,
            oldSlot = oldSlot,
            btn = btn
        }
        StaticPopup_Show("WISE_CONFIRM_BINDING_OVERWRITE", key, ownerText, data)
        return true
    end
    return false
end

local function UpdateConditionStr(str, token, enable)
    str = str or ""
    -- Simple check if token exists
    local exists = str:find(token, 1, true)

    if enable then
        if not exists then
            if str == "" then return token end
            return str .. " " .. token
        end
    else
        if exists then
            -- Escape special characters in token for pattern matching
            local escapedToken = token:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
            -- Remove token and potential surrounding spaces
            str = str:gsub("%s*" .. escapedToken .. "%s*", " ")
            -- Trim result
            str = str:gsub("^%s+", ""):gsub("%s+$", "")
        end
    end
    return str
end

Wise.PropertyHooks = {}

-- Register property hooks for specific group types
-- hookData = {
--    suppress = { ["PropName"] = true, ... },
--    inject = { ["PostName"] = function(panel, group, y) ... end, ... }
-- }
function Wise:RegisterPropertyHook(key, hookData)
    Wise.PropertyHooks[key] = hookData
end

function Wise:GetPropertyHook(group)
    if group.isSmartItem then return Wise.PropertyHooks["SmartItem"] end
    if group.isWiser then return Wise.PropertyHooks["Wiser"] end
    -- Check for custom type property?
    if group.propertyType and Wise.PropertyHooks[group.propertyType] then
        return Wise.PropertyHooks[group.propertyType]
    end
    return nil
end

function Wise:RefreshPropertiesPanel()
    if not Wise.OptionsFrame or not Wise.OptionsFrame.Right then return end

    local panel = Wise.OptionsFrame.Right.Content
    -- Clear/Hide existing controls
    if panel.controls then
        for _, ctrl in ipairs(panel.controls) do ctrl:Hide() end
    end
    panel.controls = panel.controls or {}

    -- Embedded picker mode: show picker in the right panel
    if Wise.pickingAction then
        Wise.OptionsFrame.Right.Title:SetText("Choose Action")

        -- Hide the main scroll frame
        if Wise.OptionsFrame.Right.Scroll then
            Wise.OptionsFrame.Right.Scroll:Hide()
        end

        -- Create/Show dedicated host frame for action picker
        if not Wise.OptionsFrame.Right.PickerHost then
            local host = CreateFrame("Frame", nil, Wise.OptionsFrame.Right)
            host:SetAllPoints(Wise.OptionsFrame.Right)
            host:SetFrameLevel(Wise.OptionsFrame.Right:GetFrameLevel() + 5)
            host.controls = {}
            Wise.OptionsFrame.Right.PickerHost = host
        end

        -- Clear/Hide existing host controls
        if Wise.OptionsFrame.Right.PickerHost.controls then
            for _, ctrl in ipairs(Wise.OptionsFrame.Right.PickerHost.controls) do ctrl:Hide() end
        end
        Wise.OptionsFrame.Right.PickerHost:Show()

        Wise:CreateEmbeddedPicker(Wise.OptionsFrame.Right.PickerHost)
        return
    else
        -- Normal mode: Show scroll frame (if not picking icon)
        if not Wise.pickingIcon and Wise.OptionsFrame.Right.Scroll then
            Wise.OptionsFrame.Right.Scroll:Show()
        end
        if Wise.OptionsFrame.Right.PickerHost then
            Wise.OptionsFrame.Right.PickerHost:Hide()
        end
    end

    -- Icon Picker mode
    if Wise.pickingIcon then
        Wise.OptionsFrame.Right.Title:SetText("Choose Icon")

        -- Hide the main scroll frame
        if Wise.OptionsFrame.Right.Scroll then
            Wise.OptionsFrame.Right.Scroll:Hide()
        end

        -- Create/Show dedicated overlay frame
        if not Wise.OptionsFrame.Right.IconPickerHost then
            local host = CreateFrame("Frame", nil, Wise.OptionsFrame.Right)
            host:SetAllPoints(Wise.OptionsFrame.Right)
            host:SetFrameLevel(Wise.OptionsFrame.Right:GetFrameLevel() + 5) -- Ensure on top
            Wise.OptionsFrame.Right.IconPickerHost = host
        end
        Wise.OptionsFrame.Right.IconPickerHost:Show()

        Wise:CreateIconPicker(Wise.OptionsFrame.Right.IconPickerHost)
        return
    else
        -- Normal mode: Restore scroll frame
        if Wise.OptionsFrame.Right.Scroll then
            Wise.OptionsFrame.Right.Scroll:Show()
        end
        if Wise.OptionsFrame.Right.IconPickerHost then
            Wise.OptionsFrame.Right.IconPickerHost:Hide()
        end
    end

    -- Reset embedded picker reference when not picking
    Wise.EmbeddedPicker = nil

    -- Special case: Smart Item template is selected (Template Creator)
    if Wise.selectedGroup == Wise.SMART_ITEM_TEMPLATE then
        Wise.OptionsFrame.Right.Title:SetText("Smart Item")

        local y = -30

        -- Call the Smart Item settings panel function
        if Wise.CreateSmartItemSettingsPanel then
            y = Wise:CreateSmartItemSettingsPanel(panel, nil, y)
        else
            local msgLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            msgLabel:SetPoint("TOPLEFT", 10, y)
            msgLabel:SetWidth(200)
            msgLabel:SetJustifyH("LEFT")
            msgLabel:SetText("|cffff6600Smart Item module not loaded.|r")
            tinsert(panel.controls, msgLabel)
        end

        panel:SetHeight(math.abs(y) + 50)
        return
    end

    -- Special case: Bar Copy Tool
    if Wise.BAR_COPY_TEMPLATE and Wise.selectedGroup == Wise.BAR_COPY_TEMPLATE then
        Wise.OptionsFrame.Right.Title:SetText("Bar Copy Tool")

        local y = -30

        if Wise.CreateBarCopyPropertiesPanel then
             Wise:CreateBarCopyPropertiesPanel(panel, y)
        else
             local msgLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
             msgLabel:SetPoint("TOPLEFT", 10, y)
             msgLabel:SetText("Bar Copy module not loaded.")
             tinsert(panel.controls, msgLabel)
        end
        return
    end

    local group = Wise.selectedGroup and WiseDB.groups[Wise.selectedGroup]

    -- Check Validation
    if group then
        local isValid, err = Wise:ValidateGroup(Wise.selectedGroup)
        if not isValid then
             Wise.OptionsFrame.Right.Title:SetText("Corrupted Interface")

             local y = -30
             local warnLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontRed")
             warnLabel:SetPoint("TOPLEFT", 10, y)
             warnLabel:SetWidth(200)
             warnLabel:SetJustifyH("LEFT")
             warnLabel:SetText("This interface has corrupted or outdated data:\n" .. (err or "Unknown Error"))
             tinsert(panel.controls, warnLabel)

             y = y - 60

             local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
             resetBtn:SetSize(140, 24)
             resetBtn:SetPoint("TOPLEFT", 10, y)
             resetBtn:SetText("Reset Interface")
             resetBtn:SetScript("OnClick", function()
                 StaticPopupDialogs["WISE_CONFIRM_RESET"] = {
                    text = "Are you sure you want to reset '" .. Wise.selectedGroup .. "'? All actions in this interface will be lost.",
                    button1 = "Reset",
                    button2 = "Cancel",
                    OnAccept = function()
                        -- Reset to default clean state
                        WiseDB.groups[Wise.selectedGroup] = {
                            type = "circle",
                            dynamic = false,
                            actions = {},
                            anchor = {point = "CENTER", x = 0, y = 0},
                            visibilitySettings = {},
                            keybindSettings = {},
                            interaction = "toggle"
                        }
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                        Wise:UpdateOptionsUI()
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = true,
                }
                StaticPopup_Show("WISE_CONFIRM_RESET")
             end)
             tinsert(panel.controls, resetBtn)

             panel:SetHeight(math.abs(y) + 50)
             return
        end
    end

    if not group then
        Wise.OptionsFrame.Right.Title:SetText("Properties")
        panel:SetHeight(80)
        return
    end

    Wise.OptionsFrame.Right.Title:SetText("Properties")

    local y = -30

    if Wise.selectedSlot and Wise.selectedState then
        y = Wise:RenderActionProperties(panel, group, Wise.selectedSlot, Wise.selectedState, y)
    elseif Wise.selectedSlot then
        y = Wise:RenderSlotProperties(panel, group, Wise.selectedSlot, y)
    else
        y = Wise:RenderGroupProperties(panel, group, y)
    end

    panel:SetHeight(math.abs(y) + 50)
end

function Wise:RenderActionProperties(panel, group, slotIdx, stateIdx, y)
    Wise:MigrateGroupToActions(group)
    if not group.actions[slotIdx] then return y end
    local action = group.actions[slotIdx][stateIdx]
    if not action then return y end

    local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 10, y)
    label:SetText("Action (Slot " .. slotIdx .. " State " .. stateIdx .. "):")
    tinsert(panel.controls, label)

    y = y - 20

    local valueLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    valueLabel:SetPoint("TOPLEFT", 10, y)
    valueLabel:SetWidth(180)
    valueLabel:SetJustifyH("LEFT")
    local actionName = Wise:GetActionName(action.type, action.value, action)
    valueLabel:SetText(actionName)
    tinsert(panel.controls, valueLabel)

    y = y - 25
    local pickBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
    pickBtn:SetSize(140, 22)
    pickBtn:SetPoint("TOPLEFT", 10, y)
    pickBtn:SetText("Change Action")
    pickBtn:SetScript("OnClick", function()
        Wise.pickingAction = true
        Wise.PickerCallback = function(type, value, extra)
            action.type = type
            action.value = value

            -- Update Category/Metadata if changing action
            local newCategory = "global"
            if extra and extra.category then newCategory = extra.category end
            action.category = newCategory

            -- Update Source Spec
            if extra and extra.sourceSpecID then
                action.addedBySpec = extra.sourceSpecID
            elseif newCategory == "class" then
                action.addedBySpec = nil
            else
                -- Default to current spec if spec-specific but not provided?
                -- Or keep existing? Safer to reset to current spec if it's a spec spell
                if newCategory == "spec" then
                    local currentSpec = GetSpecialization()
                    action.addedBySpec = currentSpec and GetSpecializationInfo(currentSpec) or nil
                else
                    action.addedBySpec = nil
                end
            end

            -- Reset/Update Class/Char info
            local _, pClass = UnitClass("player")
            action.addedByClass = pClass
            action.addedByCharacter = UnitName("player") .. "-" .. GetRealmName()

            if extra then
                 if extra.icon then action.icon = extra.icon end
                 if extra.name then action.name = extra.name end
            end
            Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
            Wise:RefreshPropertiesPanel()
            C_Timer.After(0, function()
                if not InCombatLockdown() then
                    Wise:UpdateGroupDisplay(Wise.selectedGroup)
                end
            end)
        end
        Wise.PickerCurrentCategory = "Spell"
        Wise:RefreshPropertiesPanel()
    end)
    tinsert(panel.controls, pickBtn)

    y = y - 35

    -- Conditions Input (e.g. [combat], [mod:shift])
    local condLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    condLabel:SetPoint("TOPLEFT", 10, y)
    condLabel:SetText("Conditions (e.g. [combat]):")
    tinsert(panel.controls, condLabel)

    y = y - 20
    local condEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    condEdit:SetSize(180, 20)
    condEdit:SetPoint("TOPLEFT", 14, y)
    condEdit:SetAutoFocus(false)
    condEdit:SetText(action.conditions or "")
    condEdit:SetCursorPosition(0)

    local function UpdateCondData(self)
        local text = self:GetText()
        action.conditions = (text ~= "") and text or nil
        if Wise.RefreshActionsView and Wise.OptionsFrame and Wise.OptionsFrame.Middle then
             Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
        end
    end

    local function CommitCond(self)
        UpdateCondData(self)
        C_Timer.After(0, function()
            if not InCombatLockdown() then
                Wise:UpdateGroupDisplay(Wise.selectedGroup)
            end
        end)
    end

    condEdit:SetScript("OnTextChanged", function(self)
        UpdateCondData(self)
    end)

    condEdit:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    condEdit:SetScript("OnEditFocusLost", function(self)
        CommitCond(self)
    end)
    condEdit:SetScript("OnEscapePressed", function(self)
        self:SetText(action.conditions or "")
        self:ClearFocus()
        UpdateCondData(self) -- Revert visual state
    end)
    tinsert(panel.controls, condEdit)
    tinsert(panel.controls, CreateConditionValidator(condEdit, panel))

    y = y - 25
    local condNote = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    condNote:SetPoint("TOPLEFT", 10, y)
    condNote:SetWidth(200)
    condNote:SetJustifyH("LEFT")
    condNote:SetText("Leave empty for 'always active'. Uses WoW macro conditionals.")
    tinsert(panel.controls, condNote)

    -- Exclusive Condition Checkbox
    if group.actions[slotIdx] and #group.actions[slotIdx] > 1 then
        y = y - 25
        local excCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        excCheck:SetPoint("TOPLEFT", 10, y)
        excCheck:SetChecked(action.exclusive or false)
        excCheck.text = excCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        excCheck.text:SetPoint("LEFT", excCheck, "RIGHT", 5, 0)
        excCheck.text:SetText("Exclusive condition")
        
        excCheck:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Exclusive Condition", 1, 1, 1)
            GameTooltip:AddLine("Checking this prevents other states in this slot from activating when this condition is met by silently appending its inverse.", nil, nil, nil, true)
            GameTooltip:Show()
        end)
        excCheck:SetScript("OnLeave", GameTooltip_Hide)
        
        excCheck:SetScript("OnClick", function(self)
            action.exclusive = self:GetChecked() and true or false
            Wise:RefreshPropertiesPanel()
            C_Timer.After(0, function()
                if not InCombatLockdown() then
                    Wise:UpdateGroupDisplay(Wise.selectedGroup)
                end
            end)
        end)
        tinsert(panel.controls, excCheck)
        tinsert(panel.controls, excCheck.text)
        y = y - 26
        
        -- Compute inherited exclusions to show greyed out
        local states = group.actions[slotIdx]
        local exclusions = {}
        if Wise.NegateConditional then
            for i, s in ipairs(states) do
                if i ~= stateIdx and s.exclusive and s.conditions and s.conditions ~= "" then
                    local negated = Wise:NegateConditional(s.conditions)
                    if negated then
                        local inner = string.match(negated, "^%[(.+)%]$") or negated
                        table.insert(exclusions, inner)
                    end
                end
            end
        end
        if #exclusions > 0 then
            y = y - 5
            local inhLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            inhLabel:SetPoint("TOPLEFT", 14, y)
            inhLabel:SetWidth(180)
            inhLabel:SetJustifyH("LEFT")
            inhLabel:SetText("Inherits Exclusions: [" .. table.concat(exclusions, ",") .. "]")
            tinsert(panel.controls, inhLabel)
            y = y - 20
        end
    else
        y = y - 30
    end

    y = y - 5

    -- Category selector (Radial Picker / Radio Buttons)
    local catLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    catLabel:SetPoint("TOPLEFT", 10, y)
    catLabel:SetText("Visibility Restriction:")
    tinsert(panel.controls, catLabel)

    y = y - 22
    local currentCat = action.category or "global"

    -- Check Permissions
    local canModify = true
    local _, playerClass = UnitClass("player")

    if action.addedByClass and action.addedByClass ~= playerClass then
        -- If the action is explicitly "global" category, anyone can modify it (and take ownership)
        if currentCat == "global" then
             canModify = true
        else
             -- It's restricted (Class, Spec, etc.) and we are wrong class
             canModify = false
        end
    end

    if not canModify then
        -- Add Lock Icon
        local lock = panel:CreateTexture(nil, "OVERLAY")
        lock:SetTexture("Interface\\PetBattles\\PetBattle-LockIcon")
        lock:SetSize(14, 14)
        lock:SetPoint("LEFT", catLabel, "RIGHT", 5, 0)
        tinsert(panel.controls, lock)

        -- Enable mouse for tooltip (Textures can't have scripts)
        local lockBtn = CreateFrame("Button", nil, panel)
        lockBtn:SetAllPoints(lock)

        lockBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Restricted", 1, 0.2, 0.2)
            GameTooltip:AddLine("Only " .. (action.addedByClass or "owner") .. "s can modify this.", 1, 1, 1)
            GameTooltip:Show()
        end)
        lockBtn:SetScript("OnLeave", GameTooltip_Hide)
        tinsert(panel.controls, lockBtn)
    end

    for _, catValue in ipairs(Wise.Categories) do
        local radio = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
        radio:SetPoint("TOPLEFT", 10, y)
        radio:SetChecked(currentCat == catValue)

        if not canModify then
            radio:Disable()
            radio:SetAlpha(0.5)
        end

        radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)

        -- Build Label with Context Suffix
        local labelText = Wise.CategoryLabels[catValue] or catValue:upper()
        local suffix = ""

        if currentCat == catValue then
            -- Use stored values if this is the currently selected option
            if catValue == "global" then
                 suffix = action.addedByCharacter
                 if suffix and string.find(suffix, "-") then
                     suffix = string.match(suffix, "^(.-)%-")
                 end
            elseif catValue == "class" then
                 suffix = action.addedByClass
            elseif catValue == "spec" then
                 if action.addedBySpec then
                     local _, specName = GetSpecializationInfoByID(action.addedBySpec)
                     suffix = specName
                 end
            elseif catValue == "talent_build" then
                suffix = action.addedByTalentBuild
            elseif catValue == "character" then
                suffix = action.addedByCharacter
                if suffix and string.find(suffix, "-") then
                     suffix = string.match(suffix, "^(.-)%-")
                end
            end
        else
            -- Use current player values (Potential) for other options
            if catValue == "global" then
                suffix = UnitName("player")
            elseif catValue == "class" then
                suffix = select(2, UnitClass("player"))
            elseif catValue == "spec" then
                local specIdx = GetSpecialization()
                if specIdx then
                    suffix = select(2, GetSpecializationInfo(specIdx))
                end
            elseif catValue == "talent_build" then
                suffix = (Wise.characterInfo and Wise.characterInfo.talentBuild) or ""
                if (not suffix or suffix == "" or suffix == select(2, GetSpecializationInfo(GetSpecialization()))) then
                     -- If cached suffix is missing or just the spec name, try a fresh direct lookup
                     if C_ClassTalents and C_ClassTalents.GetStarterBuildActive and C_ClassTalents.GetStarterBuildActive() then
                         suffix = "Starter Build"
                     else
                         local specID = GetSpecialization()
                         local specInfoID = specID and GetSpecializationInfo(specID)
                         local configID = C_ClassTalents and C_ClassTalents.GetLastSelectedConfigID and specInfoID and C_ClassTalents.GetLastSelectedConfigID(specInfoID)
                         if configID then
                             local configInfo = C_Traits.GetConfigInfo(configID)
                             if configInfo then suffix = configInfo.name end
                         end
                     end
                end
            elseif catValue == "character" then
                suffix = UnitName("player")
            end
        end

        if suffix and suffix ~= "" then
            labelText = labelText .. " |cffff8800(" .. suffix .. ")|r"
        end
        radio.text:SetText(labelText)

        radio:SetScript("OnClick", function(self)
            action.category = catValue

            -- Record Current State into Action Metadata
            local _, pClass = UnitClass("player")
            action.addedByClass = pClass
            action.addedByCharacter = UnitName("player") .. "-" .. GetRealmName()
            local sIdx = GetSpecialization()
            action.addedBySpec = sIdx and GetSpecializationInfo(sIdx) or nil
            if Wise.characterInfo then
                action.addedByTalentBuild = Wise.characterInfo.talentBuild
            end

            Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
            Wise:RefreshPropertiesPanel()
            C_Timer.After(0, function()
                if not InCombatLockdown() then
                    Wise:UpdateGroupDisplay(Wise.selectedGroup)
                end
            end)
        end)
        tinsert(panel.controls, radio)
        tinsert(panel.controls, radio.text)
        y = y - 22
    end

    y = y - 10

    -- Remove Action button
    local removeBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
    removeBtn:SetSize(140, 22)
    removeBtn:SetPoint("TOPLEFT", 10, y)
    removeBtn:SetText("Remove Action")
    if removeBtn.GetFontString then
        local rs = removeBtn:GetFontString()
        if rs then rs:SetTextColor(1, 0.2, 0.2) end
    end
    removeBtn:SetScript("OnClick", function()
        Wise:RemoveActionFromSlot(Wise.selectedGroup, Wise.selectedSlot, Wise.selectedState)
        -- Selection might be invalid now, so verify
        local g = WiseDB.groups[Wise.selectedGroup]
         if not g.actions[Wise.selectedSlot] or not g.actions[Wise.selectedSlot][Wise.selectedState] then
              Wise.selectedSlot = nil
              Wise.selectedState = nil
         end
        Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
        Wise:RefreshPropertiesPanel()
        C_Timer.After(0, function()
            if not InCombatLockdown() then
                Wise:UpdateGroupDisplay(Wise.selectedGroup)
            end
        end)
    end)
    tinsert(panel.controls, removeBtn)

    y = y - 35

    -- Nesting Options (for interface actions)
    if action.type == "interface" then
        local nestLine = panel:CreateTexture(nil, "OVERLAY")
        nestLine:SetColorTexture(0.3, 0.3, 0.3, 0.5)
        nestLine:SetHeight(1)
        nestLine:SetPoint("TOPLEFT", 10, y)
        nestLine:SetPoint("RIGHT", -10, y)
        tinsert(panel.controls, nestLine)

        y = y - 15
        local nestHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nestHeader:SetPoint("TOPLEFT", 10, y)
        nestHeader:SetText("Nesting Options")
        tinsert(panel.controls, nestHeader)

        y = y - 22
        local nestOpts = Wise:GetNestingOptions(action) or {}

        -- Open Button radios
        local obLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        obLabel:SetPoint("TOPLEFT", 10, y)
        obLabel:SetText("Open Button:")
        tinsert(panel.controls, obLabel)
        y = y - 20
        for _, entry in ipairs(Wise.NESTING_OPEN_BUTTONS) do
            local radio = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
            radio:SetPoint("TOPLEFT", 10, y)
            radio:SetChecked(nestOpts.openNestedButton == entry.value)
            radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)
            radio.text:SetText(entry.label)
            radio:SetScript("OnClick", function()
                Wise:SetNestingOption(action, "openNestedButton", entry.value)
                Wise:RefreshPropertiesPanel()
                C_Timer.After(0, function()
                    if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    end
                end)
            end)
            tinsert(panel.controls, radio)
            tinsert(panel.controls, radio.text)
            y = y - 22
        end

        y = y - 8
        -- Rotation Mode radios
        local rmLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        rmLabel:SetPoint("TOPLEFT", 10, y)
        rmLabel:SetText("Rotation Mode:")
        tinsert(panel.controls, rmLabel)
        y = y - 20
        for _, entry in ipairs(Wise.NESTING_ROTATION_MODES) do
            local radio = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
            radio:SetPoint("TOPLEFT", 10, y)
            radio:SetChecked(nestOpts.rotationMode == entry.value)
            radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)
            radio.text:SetText(entry.label)
            radio:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(entry.label, 1, 1, 1)
                GameTooltip:AddLine(entry.tooltip, nil, nil, nil, true)
                GameTooltip:Show()
            end)
            radio:SetScript("OnLeave", GameTooltip_Hide)
            radio:SetScript("OnClick", function()
                Wise:SetNestingOption(action, "rotationMode", entry.value)
                Wise:RefreshPropertiesPanel()
                C_Timer.After(0, function()
                    if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    end
                end)
            end)
            tinsert(panel.controls, radio)
            tinsert(panel.controls, radio.text)
            y = y - 22
        end

        y = y - 8
        -- Open Direction radios
        local odLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        odLabel:SetPoint("TOPLEFT", 10, y)
        odLabel:SetText("Open Direction:")
        tinsert(panel.controls, odLabel)
        y = y - 20
        for _, entry in ipairs(Wise.NESTING_OPEN_DIRECTIONS) do
            local radio = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
            radio:SetPoint("TOPLEFT", 10, y)
            radio:SetChecked(nestOpts.openDirection == entry.value)
            radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)
            radio.text:SetText(entry.label)
            radio:SetScript("OnClick", function()
                Wise:SetNestingOption(action, "openDirection", entry.value)
                Wise:RefreshPropertiesPanel()
                C_Timer.After(0, function()
                    if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    end
                end)
            end)
            tinsert(panel.controls, radio)
            tinsert(panel.controls, radio.text)
            y = y - 22
        end

        y = y - 8
        -- Checkboxes
        local checkboxes = {
            { key = "closeParentOnOpen",  label = "Close parent on open" },
            { key = "showGhostIndicator", label = "Show ghost indicator" },
            { key = "anchorToParentSlot", label = "Anchor to parent slot" },
        }
        for _, cb in ipairs(checkboxes) do
            local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
            check:SetPoint("TOPLEFT", 10, y)
            check:SetChecked(nestOpts[cb.key] or false)
            check.text = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            check.text:SetPoint("LEFT", check, "RIGHT", 5, 0)
            check.text:SetText(cb.label)
            check:SetScript("OnClick", function(self)
                Wise:SetNestingOption(action, cb.key, self:GetChecked() and true or false)
                C_Timer.After(0, function()
                    if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    end
                end)
            end)
            tinsert(panel.controls, check)
            tinsert(panel.controls, check.text)
            y = y - 26
        end

        y = y - 10
    end

    -- Custom Macro Editor
    if action.value == "custom_macro" and Wise.CreateMacroEditor then
         local line = panel:CreateTexture(nil, "OVERLAY")
         line:SetColorTexture(0.3, 0.3, 0.3, 0.5)
         line:SetHeight(1)
         line:SetPoint("TOPLEFT", 10, y)
         line:SetPoint("RIGHT", -10, y)
         tinsert(panel.controls, line)

         y = y - 15
         y = Wise:CreateMacroEditor(panel, action, y)
    end

    return y
end

function Wise:RenderSlotProperties(panel, group, slotIdx, y)
    Wise:MigrateGroupToActions(group)
    local slot = group.actions[slotIdx]

    if slot then
         local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
         label:SetPoint("TOPLEFT", 10, y)
         label:SetText("Slot " .. slotIdx .. " Properties:")
         tinsert(panel.controls, label)
         y = y - 30

         -- Keybind UI
         local kbLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
         kbLabel:SetPoint("TOPLEFT", 10, y)
         kbLabel:SetText("Direct Keybind (Right Click to Clear):")
         tinsert(panel.controls, kbLabel)
         y = y - 20

         local bindBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
         bindBtn:SetSize(140, 22)
         bindBtn:SetPoint("TOPLEFT", 10, y)
         bindBtn:SetText(slot.keybind or "None")

         bindBtn:RegisterForClicks("AnyUp")
         bindBtn:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                slot.keybind = nil
                Wise:UpdateBindings()
                Wise:UpdateOptionsUI()
            elseif button == "LeftButton" then
                self:SetText("Press Key...")
                self:EnableKeyboard(true)
                self:EnableMouseWheel(true)

                local function FinishSlotBinding(key)
                    if not key then return end

                    if key == "ESCAPE" then
                        self:EnableKeyboard(false)
                        self:EnableMouseWheel(false)
                        self:SetScript("OnKeyDown", nil)
                        self:SetScript("OnMouseWheel", nil)
                        self:SetText(slot.keybind or "None")
                        return
                    end

                    if key:find("SHIFT") or key:find("CTRL") or key:find("ALT") then return end

                    local mods = ""
                    if IsAltKeyDown() then mods = mods .. "ALT-" end
                    if IsControlKeyDown() then mods = mods .. "CTRL-" end
                    if IsShiftKeyDown() then mods = mods .. "SHIFT-" end

                    -- Check MouseWheel Validation
                    if key == "MOUSEWHEELUP" or key == "MOUSEWHEELDOWN" then
                        local isValid, err = Wise:ValidateMouseWheelBinding(group, true)
                        if not isValid then
                            StaticPopup_Show("WISE_BINDING_ERROR", err)
                            self:EnableKeyboard(false)
                            self:EnableMouseWheel(false)
                            self:SetScript("OnKeyDown", nil)
                            self:SetScript("OnMouseWheel", nil)
                            self:SetText(slot.keybind or "None")
                            return
                        end
                    end

                    local fullKey = mods .. key
                    self:EnableKeyboard(false)
                    self:EnableMouseWheel(false)
                    self:SetScript("OnKeyDown", nil)
                    self:SetScript("OnMouseWheel", nil)

                    if Wise:CheckBindingConflict(fullKey, group, slotIdx, true, self) then
                        return
                    end

                    slot.keybind = fullKey
                    self:SetText(fullKey)

                    Wise:UpdateBindings()
                    Wise:UpdateOptionsUI()
                end

                self:SetScript("OnKeyDown", function(self, key)
                    FinishSlotBinding(key)
                end)

                self:SetScript("OnMouseWheel", function(self, delta)
                    local key = (delta > 0) and "MOUSEWHEELUP" or "MOUSEWHEELDOWN"
                    FinishSlotBinding(key)
                end)
            end
         end)
         tinsert(panel.controls, bindBtn)
         y = y - 30

         local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
         note:SetPoint("TOPLEFT", 10, y)
         note:SetWidth(200)
         note:SetJustifyH("LEFT")
         note:SetText("This keybind directly triggers this slot.")
         tinsert(panel.controls, note)
         y = y - 40

         -- Conflicting Conditionals / State Configuration
         if Wise:HasConflictingConditionals(slot) then
             local stateFrame = Wise:CreateStateConfigurationFrame(panel, group, slotIdx)
             if stateFrame then
                 stateFrame:SetPoint("TOPLEFT", 10, y)
                 tinsert(panel.controls, stateFrame)
                 y = y - stateFrame:GetHeight() - 20
             end
         end

         -- Delete Slot Button
         local delBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
         delBtn:SetSize(140, 24)
         delBtn:SetPoint("TOPLEFT", 10, y)
         delBtn:SetText("Delete Slot")
         local btnText = delBtn:GetFontString()
         if btnText then btnText:SetTextColor(1, 0.2, 0.2) end

         delBtn:SetScript("OnClick", function()
             StaticPopupDialogs["WISE_CONFIRM_DELETE_SLOT"] = {
                text = "Delete Slot " .. slotIdx .. " and all its actions?",
                button1 = "Delete",
                button2 = "Cancel",
                OnAccept = function()
                    Wise:RemoveSlot(Wise.selectedGroup, slotIdx)
                    Wise.selectedSlot = nil
                    Wise:UpdateBindings()
                    Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
                    Wise:RefreshPropertiesPanel()
                    C_Timer.After(0, function()
                         if not InCombatLockdown() then Wise:UpdateGroupDisplay(Wise.selectedGroup) end
                    end)
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
            StaticPopup_Show("WISE_CONFIRM_DELETE_SLOT")
         end)
         tinsert(panel.controls, delBtn)
    else
         local label = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
         label:SetPoint("TOPLEFT", 10, y)
         label:SetText("Slot not found.")
         tinsert(panel.controls, label)
    end

    return y
end

function Wise:RenderGroupProperties(panel, group, y)
    local hook = Wise:GetPropertyHook(group)
    local suppress = hook and hook.suppress or {}
    local inject = hook and hook.inject or {}

    -- Rename Interface (Custom Only or Wiser if not suppressed)
    if (not group.isWiser and not suppress.Rename) or (group.isWiser and not suppress.Rename) then
         -- For standard Wiser, we usually suppress renaming, but let's check flag
         if not group.isWiser then
             local nameLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
             nameLabel:SetPoint("TOPLEFT", 10, y)
             nameLabel:SetText("Interface Name:")
             tinsert(panel.controls, nameLabel)

             y = y - 20
             local nameEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
             nameEdit:SetSize(180, 20)
             nameEdit:SetPoint("TOPLEFT", 14, y)
             nameEdit:SetAutoFocus(false)
             nameEdit:SetText(Wise.selectedGroup or "")
             nameEdit:SetCursorPosition(0)

             local statusBtn = CreateFrame("Button", nil, panel)
             statusBtn:SetSize(20, 20)
             statusBtn:SetPoint("LEFT", nameEdit, "RIGHT", 5, 0)
             statusBtn.icon = statusBtn:CreateTexture(nil, "ARTWORK")
             statusBtn.icon:SetAllPoints()
             statusBtn:Hide()

             local function ValidateName(newName)
                  local oldName = Wise.selectedGroup

                  if not newName then return false end

                  if newName == oldName then
                      return false, nil, false, "No change"
                  end

                  if newName:match("^%s*$") then
                      return true, "Interface\\RAIDFRAME\\ReadyCheck-NotReady", false, "Name cannot be empty."
                  end

                  if WiseDB.groups[newName] then
                      return true, "Interface\\RAIDFRAME\\ReadyCheck-NotReady", false, "Name '"..newName.."' is already taken."
                  end

                  if InCombatLockdown() then
                      return true, "Interface\\RAIDFRAME\\ReadyCheck-NotReady", false, "Cannot rename in combat."
                  end

                  return true, "Interface\\RAIDFRAME\\ReadyCheck-Ready", true, nil
             end

             local function UpdateStatus()
                 local text = nameEdit:GetText()
                 local show, texture, isValid, msg = ValidateName(text)

                 if show then
                     statusBtn:Show()
                     statusBtn.icon:SetTexture(texture)
                     statusBtn.isValid = isValid
                     statusBtn.errorMsg = msg
                 else
                     statusBtn:Hide()
                     statusBtn.isValid = false
                     statusBtn.errorMsg = nil
                 end
             end

             nameEdit:SetScript("OnTextChanged", function(self)
                 UpdateStatus()
             end)

             local function AttemptRename()
                 local text = nameEdit:GetText()
                 local _, _, isValid, msg = ValidateName(text)

                 if isValid then
                     local newName = text
                     local oldName = Wise.selectedGroup

                     -- Rename Group
                     WiseDB.groups[newName] = WiseDB.groups[oldName]
                     WiseDB.groups[oldName] = nil
                     Wise.selectedGroup = newName

                     -- Cleanup Old Frame
                     local oldF = Wise.frames[oldName]
                     if oldF then
                         oldF:Hide()
                         if oldF.visualDisplay then oldF.visualDisplay:Hide() end
                         oldF:SetScript("OnUpdate", nil)
                         if oldF.Anchor then oldF.Anchor:SetScript("OnUpdate", nil) end
                         UnregisterStateDriver(oldF, "visibility")
                         Wise.frames[oldName] = nil
                     end

                     -- Create New Frame
                     Wise:UpdateGroupDisplay(newName)

                     -- Update Bindings (since button name changed)
                     Wise:UpdateBindings()

                     -- Refresh UI
                     Wise:UpdateOptionsUI()
                 elseif msg then
                     -- Show Tooltip on failure
                     GameTooltip:SetOwner(statusBtn, "ANCHOR_RIGHT")
                     GameTooltip:SetText("Cannot Rename", 1, 0, 0)
                     GameTooltip:AddLine(msg, 1, 1, 1)
                     GameTooltip:Show()
                 elseif text == Wise.selectedGroup then
                     nameEdit:ClearFocus()
                 end
             end

             nameEdit:SetScript("OnEnterPressed", AttemptRename)
             nameEdit:SetScript("OnEditFocusLost", AttemptRename)
             nameEdit:SetScript("OnEscapePressed", function(self)
                 self:SetText(Wise.selectedGroup or "")
                 self:ClearFocus()
                 UpdateStatus()
             end)

             statusBtn:SetScript("OnClick", AttemptRename)

             statusBtn:SetScript("OnEnter", function(self)
                 if self.errorMsg then
                      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                      GameTooltip:SetText("Cannot Rename", 1, 0, 0)
                      GameTooltip:AddLine(self.errorMsg, 1, 1, 1)
                      GameTooltip:Show()
                 elseif self.isValid then
                      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                      GameTooltip:SetText("Click to Rename", 0, 1, 0)
                      GameTooltip:Show()
                 end
             end)

             statusBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

             tinsert(panel.controls, nameEdit)
             tinsert(panel.controls, statusBtn)

             -- Initial update
             UpdateStatus()
             y = y - 30
         end
    end

    if inject.PostRename then
        y = inject.PostRename(panel, group, y)
    end

    -- Smart Item generated interface specific properties
    if group.isSmartItem and Wise.CreateSmartItemRefreshButton then
        y = Wise:CreateSmartItemRefreshButton(panel, group, Wise.selectedGroup, y)
    end

    -- Wiser Interface specific headers
    if group.isWiser then
         -- Ensure availability struct exists (migration/safety)
         if not group.availability then
             group.availability = { mode = "NONE", characters = {} }
             if group.enabled ~= nil then
                 if group.enabled then group.availability.mode = "ALL" end
                 group.enabled = nil
             end
         end
         y = y - 5 -- Small spacer
    end

    -- Logic enforcement:
    if group.binding then
         group.visibility = nil
         if not group.interaction then group.interaction = "toggle" end
    else
         group.interaction = nil
         if not group.visibility then group.visibility = "always" end
    end

    if not suppress.InterfaceMode then
        local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("TOPLEFT", 10, y)
        label:SetText("Interface Mode:")
        tinsert(panel.controls, label)

        y = y - 20

        -- Radial Picker for Interface Mode (Radio Buttons)
        local currentType = group.type or "circle"
        local modeTypes = {
            { value = "circle", label = "Circle" },
            { value = "button", label = "Button" },
            { value = "box",    label = "Box" },
            { value = "line",   label = "Line" },
            { value = "list",   label = "List" },
        }

        for _, modeInfo in ipairs(modeTypes) do
            local radio = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
            radio:SetPoint("TOPLEFT", 10, y)
            radio:SetChecked(currentType == modeInfo.value)
            radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)

            local label = modeInfo.label
            if modeInfo.value == "circle" and C_AddOns and C_AddOns.IsAddOnLoaded("Masque") then
                label = label .. " |cffff8800(Masque)|r"
            end
            radio.text:SetText(label)

            radio:SetScript("OnClick", function(self)
                group.type = modeInfo.value
                Wise:RefreshPropertiesPanel()
                C_Timer.After(0, function()
                    if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    end
                end)
            end)
            tinsert(panel.controls, radio)
            tinsert(panel.controls, radio.text)
            y = y - 22
        end
    end

    if not suppress.InterfaceStyle then
        -- Interface Style Header
        local styleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        styleLabel:SetPoint("TOPLEFT", 10, y)
        styleLabel:SetText("Interface Style:")
        tinsert(panel.controls, styleLabel)

        y = y - 25

        -- Dynamic Checkbox
        local dynamicCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        dynamicCheck:SetPoint("TOPLEFT", 10, y)
        dynamicCheck:SetChecked(group.dynamic or false)
        tinsert(panel.controls, dynamicCheck)

        local dynamicLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        dynamicLabel:SetPoint("LEFT", dynamicCheck, "RIGHT", 5, 0)
        dynamicLabel:SetText("Dynamic")
        tinsert(panel.controls, dynamicLabel)

        -- Static Checkbox
        local staticCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        staticCheck:SetPoint("LEFT", dynamicLabel, "RIGHT", 25, 0)
        staticCheck:SetChecked(not group.dynamic)
        tinsert(panel.controls, staticCheck)

        local staticLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        staticLabel:SetPoint("LEFT", staticCheck, "RIGHT", 5, 0)
        staticLabel:SetText("Static")
        tinsert(panel.controls, staticLabel)

        -- Logic for mutually exclusive checkboxes
        dynamicCheck:SetScript("OnClick", function(self)
            if self:GetChecked() then
                group.dynamic = true
                staticCheck:SetChecked(false)
            else
                -- Force one to be checked
                self:SetChecked(true)
                group.dynamic = true
            end

            Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
             -- Defer secure frame update
            C_Timer.After(0, function()
                if not InCombatLockdown() then
                    Wise:UpdateGroupDisplay(Wise.selectedGroup)
                end
            end)
        end)

        staticCheck:SetScript("OnClick", function(self)
            if self:GetChecked() then
                group.dynamic = false
                dynamicCheck:SetChecked(false)
            else
                -- Force one to be checked
                self:SetChecked(true)
                group.dynamic = false
            end

            Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
             -- Defer secure frame update
            C_Timer.After(0, function()
                if not InCombatLockdown() then
                    Wise:UpdateGroupDisplay(Wise.selectedGroup)
                end
            end)
        end)

        y = y - 30

        -- Animation checkbox
        local animCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        animCheck:SetPoint("TOPLEFT", 10, y)
        animCheck:SetChecked(group.animation or false)
        animCheck:SetScript("OnClick", function(self)
            group.animation = self:GetChecked()
        end)
        tinsert(panel.controls, animCheck)

        local animLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        animLabel:SetPoint("LEFT", animCheck, "RIGHT", 5, 0)
        animLabel:SetText("Animate")
        tinsert(panel.controls, animLabel)

        -- Invert Order checkbox
        local invertCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        invertCheck:SetPoint("LEFT", animLabel, "RIGHT", 15, 0)
        invertCheck:SetChecked(group.invertOrder or false)
        invertCheck:SetScript("OnClick", function(self)
            group.invertOrder = self:GetChecked()
            Wise:RefreshPropertiesPanel()
            C_Timer.After(0, function()
                if not InCombatLockdown() then
                    Wise:UpdateGroupDisplay(Wise.selectedGroup)
                end
            end)
        end)
        tinsert(panel.controls, invertCheck)

        local invertLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        invertLabel:SetPoint("LEFT", invertCheck, "RIGHT", 5, 0)
        invertLabel:SetText("Invert Order")
        tinsert(panel.controls, invertLabel)

        y = y - 30

        if group.type == "line" then
             local dirLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
             dirLabel:SetPoint("TOPLEFT", 10, y)
             dirLabel:SetText("Growth Direction:")
             tinsert(panel.controls, dirLabel)

             y = y - 22

             -- Radial Picker for Growth Direction (Radio Buttons)
             local currentDir = group.growthDirection or "right"
             local dirTypes = {
                 { value = "right", label = "Right" },
                 { value = "left",  label = "Left" },
                 { value = "up",    label = "Up" },
                 { value = "down",  label = "Down" },
             }

             for _, dirInfo in ipairs(dirTypes) do
                 local radio = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
                 radio:SetPoint("TOPLEFT", 10, y)
                 radio:SetChecked(currentDir == dirInfo.value)
                 radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                 radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)
                 radio.text:SetText(dirInfo.label)

                 radio:SetScript("OnClick", function(self)
                     group.growthDirection = dirInfo.value
                     Wise:RefreshPropertiesPanel()
                     C_Timer.After(0, function()
                         if not InCombatLockdown() then
                             Wise:UpdateGroupDisplay(Wise.selectedGroup)
                         end
                     end)
                 end)
                 tinsert(panel.controls, radio)
                 tinsert(panel.controls, radio.text)
                 y = y - 22
             end
        elseif group.type == "list" then
             local alignLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
             alignLabel:SetPoint("TOPLEFT", 10, y)
             alignLabel:SetText("Text Position:")
             tinsert(panel.controls, alignLabel)

             y = y - 22

             -- Radial Picker for Text Alignment (Radio Buttons)
             local currentAlign = group.textAlign or "right"

             local alignTypes = {
                 { value = "right", label = "Right of Icon" },
                 { value = "left",  label = "Left of Icon" },
             }

             for _, alignInfo in ipairs(alignTypes) do
                 local radio = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
                 radio:SetPoint("TOPLEFT", 10, y)
                 radio:SetChecked(currentAlign == alignInfo.value)
                 radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                 radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)
                 radio.text:SetText(alignInfo.label)

                 radio:SetScript("OnClick", function(self)
                     group.textAlign = alignInfo.value
                     Wise:RefreshPropertiesPanel()
                     C_Timer.After(0, function()
                         if not InCombatLockdown() then
                             Wise:UpdateGroupDisplay(Wise.selectedGroup)
                         end
                     end)
                 end)
                 tinsert(panel.controls, radio)
                 tinsert(panel.controls, radio.text)
                 y = y - 22
             end
        elseif group.type == "box" then

             -- Box Configuration Header
             local boxLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
             boxLabel:SetPoint("TOPLEFT", 10, y)
             boxLabel:SetText("Box Layout:")
             tinsert(panel.controls, boxLabel)
             y = y - 40

             -- Defaults
             if not group.boxWidth then group.boxWidth = 3 end
             if not group.boxHeight then group.boxHeight = 3 end
             if group.fixedAxis == nil then group.fixedAxis = "x" end -- 'x' or 'y'

             -- X Dimension Slider
             local xSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
             xSlider:SetPoint("TOPLEFT", 10, y)
             xSlider:SetSize(120, 16)
             xSlider:SetMinMaxValues(2, 10)
             xSlider:SetValue(group.boxWidth)
             xSlider:SetValueStep(1)
             xSlider:SetObeyStepOnDrag(true)
             xSlider.Low:SetText("2")
             xSlider.High:SetText("10")
             xSlider.Text:SetText("Width: " .. group.boxWidth)
             xSlider:SetScript("OnValueChanged", function(self, value)
                 group.boxWidth = math.floor(value)
                 self.Text:SetText("Width: " .. group.boxWidth)
                 C_Timer.After(0, function() Wise:UpdateGroupDisplay(Wise.selectedGroup) end)
             end)
             tinsert(panel.controls, xSlider)

             -- Fixed X Checkbox
             local fixedX = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
             fixedX:SetPoint("LEFT", xSlider, "RIGHT", 10, 0)
             fixedX:SetChecked(group.fixedAxis == "x")
             fixedX.text = fixedX:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
             fixedX.text:SetPoint("LEFT", fixedX, "RIGHT", 5, 0)
             fixedX.text:SetText("Fixed")
             fixedX:SetScript("OnClick", function(self)
                 if self:GetChecked() then
                     group.fixedAxis = "x"
                     Wise:RefreshPropertiesPanel()
                 else
                     -- Can't uncheck directly, must check other. But for UX, re-checking ensures state.
                     self:SetChecked(true)
                 end
                 C_Timer.After(0, function() Wise:UpdateGroupDisplay(Wise.selectedGroup) end)
             end)
             tinsert(panel.controls, fixedX)
             tinsert(panel.controls, fixedX.text)

             y = y - 45

             -- Y Dimension Slider
             local ySlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
             ySlider:SetPoint("TOPLEFT", 10, y)
             ySlider:SetSize(120, 16)
             ySlider:SetMinMaxValues(2, 10)
             ySlider:SetValue(group.boxHeight)
             ySlider:SetValueStep(1)
             ySlider:SetObeyStepOnDrag(true)
             ySlider.Low:SetText("2")
             ySlider.High:SetText("10")
             ySlider.Text:SetText("Height: " .. group.boxHeight)
             ySlider:SetScript("OnValueChanged", function(self, value)
                 group.boxHeight = math.floor(value)
                 self.Text:SetText("Height: " .. group.boxHeight)
                 C_Timer.After(0, function() Wise:UpdateGroupDisplay(Wise.selectedGroup) end)
             end)
             tinsert(panel.controls, ySlider)

             -- Fixed Y Checkbox
             local fixedY = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
             fixedY:SetPoint("LEFT", ySlider, "RIGHT", 10, 0)
             fixedY:SetChecked(group.fixedAxis == "y")
             fixedY.text = fixedY:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
             fixedY.text:SetPoint("LEFT", fixedY, "RIGHT", 5, 0)
             fixedY.text:SetText("Fixed")
             fixedY:SetScript("OnClick", function(self)
                 if self:GetChecked() then
                     group.fixedAxis = "y"
                     Wise:RefreshPropertiesPanel()
                 else
                     self:SetChecked(true)
                 end
                 C_Timer.After(0, function() Wise:UpdateGroupDisplay(Wise.selectedGroup) end)
             end)
             tinsert(panel.controls, fixedY)
             tinsert(panel.controls, fixedY.text)

             y = y - 40
        end

        y = y - 35
    end

    if not suppress.DisplaySettings then
        -- =============================================
        -- PER-INTERFACE DISPLAY SETTINGS (Override Global)
        -- =============================================
        local displayHeader = panel:CreateTexture(nil, "ARTWORK")
        displayHeader:SetColorTexture(1, 1, 1, 0.2)
        displayHeader:SetSize(200, 1)
        displayHeader:SetPoint("TOPLEFT", 10, y)
        tinsert(panel.controls, displayHeader)
        y = y - 15

        local resetGlobalBtn -- Pre-declare for visibility in UpdateDisplayStatus

        local displayLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        displayLabel:SetPoint("TOPLEFT", 10, y)
        displayLabel:SetText("Display Settings:")
        tinsert(panel.controls, displayLabel)

        -- Show "(Custom)" or "(Global)" indicator
        local displayHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        displayHint:SetPoint("LEFT", displayLabel, "RIGHT", 8, 0)
        local hasOverride = group.iconStyle or group.iconSize or group.textSize or group.font or (group.showKeybinds ~= nil) or group.keybindPosition or group.keybindTextSize or group.chargeTextSize or group.chargeTextPosition
        displayHint:SetText(hasOverride and "|cffff8800(Custom)|r" or "|cff00cc00(Global)|r")
        tinsert(panel.controls, displayHint)

        y = y - 25

        -- Per-Interface Icon Style
        local piStyleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piStyleLabel:SetPoint("TOPLEFT", 10, y)

        local piLabelText = "Icon Style:" .. (group.iconStyle and " |cffff8800(Custom)|r" or "")
        if C_AddOns and C_AddOns.IsAddOnLoaded("Masque") then
            piLabelText = piLabelText .. " |cffff0000(being overridden by Masque)|r"
        else
            piLabelText = piLabelText .. " |cffaaaaaa(more with Masque addon)|r"
        end
        piStyleLabel:SetText(piLabelText)
        tinsert(panel.controls, piStyleLabel)

        y = y - 22
        local effectiveIconStyle = group.iconStyle or (WiseDB.settings and WiseDB.settings.iconStyle) or "rounded"

        local styles = {
            {val="rounded", text="Rounded"},
            {val="square", text="Square"},
            {val="round", text="Round"}
        }

        for _, styleMode in ipairs(styles) do
             local radio = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
             radio:SetPoint("TOPLEFT", 10, y)
             radio:SetChecked(effectiveIconStyle == styleMode.val)
             radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
             radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)
             radio.text:SetText(styleMode.text)

             radio:SetScript("OnClick", function(self)
                 group.iconStyle = styleMode.val
                 Wise:RefreshPropertiesPanel() -- To update label (Custom)
                 C_Timer.After(0.1, function() Wise:UpdateGroupDisplay(Wise.selectedGroup) end)
             end)
             tinsert(panel.controls, radio)
             tinsert(panel.controls, radio.text)
             y = y - 22
        end

        y = y - 10

        -- Per-Interface Icon Size
        local piIconLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piIconLabel:SetPoint("TOPLEFT", 10, y)
        local effectiveIconSize = group.iconSize or (WiseDB.settings and WiseDB.settings.iconSize) or 30

        local function UpdateDisplayStatus()
            local over = group.iconStyle or group.iconSize or group.textSize or group.font or (group.showKeybinds ~= nil) or group.keybindPosition or group.keybindTextSize or group.chargeTextSize or group.chargeTextPosition or group.countdownTextSize or group.countdownTextPosition or (group.showGCD ~= nil) or (group.showChargeText ~= nil) or (group.showCountdownText ~= nil)
            displayHint:SetText(over and "|cffff8800(Custom)|r" or "|cff00cc00(Global)|r")

            local piLabelText = "Icon Style:" .. (group.iconStyle and " |cffff8800(Custom)|r" or "")
            if C_AddOns and C_AddOns.IsAddOnLoaded("Masque") then
                piLabelText = piLabelText .. " |cffff0000(being overridden by Masque)|r"
            else
                piLabelText = piLabelText .. " |cffaaaaaa(more with Masque addon)|r"
            end
            piStyleLabel:SetText(piLabelText)
            piIconLabel:SetText("Icon Size:" .. (group.iconSize and " |cffff8800(Custom)|r" or ""))
            -- Note: Other labels (Text/Font) will be updated via the full refresh on font change,
            -- but for sliders we update their specific label here.

            if over then
                resetGlobalBtn:Enable()
            else
                resetGlobalBtn:Disable()
            end
        end

        piIconLabel:SetText("Icon Size:" .. (group.iconSize and " |cffff8800(Custom)|r" or ""))
        tinsert(panel.controls, piIconLabel)

        y = y - 22
        local piIconSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
        piIconSlider:SetPoint("TOPLEFT", 10, y)
        piIconSlider:SetSize(180, 16)
        piIconSlider:SetMinMaxValues(16, 64)
        piIconSlider:SetValue(effectiveIconSize)
        piIconSlider:SetValueStep(2)
        piIconSlider:SetObeyStepOnDrag(true)
        piIconSlider.Low:SetText("16")
        piIconSlider.High:SetText("64")
        piIconSlider.Text:SetText(tostring(effectiveIconSize))
        piIconSlider:SetScript("OnValueChanged", function(self, value)
            local size = math.floor(value)
            group.iconSize = size
            self.Text:SetText(tostring(size))
            UpdateDisplayStatus()
            C_Timer.After(0.1, function()
                if not InCombatLockdown() then
                    Wise:UpdateGroupDisplay(Wise.selectedGroup)
                end
            end)
        end)
        tinsert(panel.controls, piIconSlider)

        y = y - 40

        -- Per-Interface Text Size
        local piTextLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piTextLabel:SetPoint("TOPLEFT", 10, y)
        local effectiveTextSize = group.textSize or (WiseDB.settings and WiseDB.settings.textSize) or 12
        piTextLabel:SetText("Text Size:" .. (group.textSize and " |cffff8800(Custom)|r" or ""))
        tinsert(panel.controls, piTextLabel)

        y = y - 22
        local piTextSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
        piTextSlider:SetPoint("TOPLEFT", 10, y)
        piTextSlider:SetSize(180, 16)
        piTextSlider:SetMinMaxValues(8, 24)
        piTextSlider:SetValue(effectiveTextSize)
        piTextSlider:SetValueStep(1)
        piTextSlider:SetObeyStepOnDrag(true)
        piTextSlider.Low:SetText("8")
        piTextSlider.High:SetText("24")
        piTextSlider.Text:SetText(tostring(effectiveTextSize))
        piTextSlider:SetScript("OnValueChanged", function(self, value)
            local size = math.floor(value)
            group.textSize = size
            self.Text:SetText(tostring(size))

            -- Manual update for Text Label
            piTextLabel:SetText("Text Size:" .. (group.textSize and " |cffff8800(Custom)|r" or ""))
            UpdateDisplayStatus()

            C_Timer.After(0.1, function()
                if not InCombatLockdown() then
                    Wise:UpdateGroupDisplay(Wise.selectedGroup)
                end
            end)
        end)
        tinsert(panel.controls, piTextSlider)

        y = y - 40

        -- Per-Interface Font Selection
        local piFontLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piFontLabel:SetPoint("TOPLEFT", 10, y)
        piFontLabel:SetText("Font:" .. (group.font and " |cffff8800(Custom)|r" or ""))
        tinsert(panel.controls, piFontLabel)
        y = y - 22

        -- Build font list dynamically (same approach as global)
        local piValidFonts = {}
        local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

        if LSM then
            local lsmFonts = LSM:HashTable("font")
            if lsmFonts then
                for fname, fpath in pairs(lsmFonts) do
                    table.insert(piValidFonts, { name = fname, path = fpath })
                end
            end
            table.sort(piValidFonts, function(a, b) return a.name < b.name end)
        end

        if #piValidFonts == 0 then
            local defaultFonts = {
                { name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
                { name = "Arial Narrow", path = "Fonts\\ARIALN.TTF" },
                { name = "Morpheus", path = "Fonts\\MORPHEUS.TTF" },
                { name = "Skurri", path = "Fonts\\SKURRI.TTF" },
                { name = "2002", path = "Fonts\\2002.TTF" },
                { name = "2002 Bold", path = "Fonts\\2002B.TTF" },
                { name = "Friz Quadrata (CYR)", path = "Fonts\\FRIZQT___CYR.TTF" },
            }

            local testFrame = CreateFrame("Frame")
            local testFont = testFrame:CreateFontString(nil, "OVERLAY")

            for _, f in ipairs(defaultFonts) do
                local success = testFont:SetFont(f.path, 12, "")
                if success then
                    table.insert(piValidFonts, f)
                end
            end

            if #piValidFonts == 0 then
                piValidFonts = {{ name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" }}
            end
        end

        -- Determine effective font
        local effectiveFontPath = group.font or (WiseDB.settings and WiseDB.settings.font) or "Fonts\\FRIZQT__.TTF"
        local currentPiFontName = "Friz Quadrata"
        for _, f in ipairs(piValidFonts) do
            if f.path == effectiveFontPath then
                currentPiFontName = f.name
                break
            end
        end
        if currentPiFontName == "Friz Quadrata" and effectiveFontPath ~= "Fonts\\FRIZQT__.TTF" then
            local filename = effectiveFontPath:match("([^\\]+)$") or effectiveFontPath
            currentPiFontName = filename
        end

        local piFontBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
        piFontBtn:SetSize(180, 22)
        piFontBtn:SetPoint("TOPLEFT", 10, y)
        piFontBtn:SetText(currentPiFontName)
        piFontBtn:SetScript("OnClick", function(self)
            if self.dropdown and self.dropdown:IsShown() then
                self.dropdown:Hide()
                return
            end

            if not self.dropdown then
                local d = CreateFrame("Frame", nil, self, "BackdropTemplate")
                self.dropdown = d

                local itemHeight = 22
                local maxVisible = 10
                local visibleCount = math.min(#piValidFonts, maxVisible)
                local dropdownHeight = (visibleCount * itemHeight) + 20
                local needsScroll = #piValidFonts > maxVisible

                d:SetSize(220, dropdownHeight)
                d:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
                d:SetFrameStrata("DIALOG")
                d:SetBackdrop({
                    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                    tile = true, tileSize = 32, edgeSize = 16,
                    insets = { left = 5, right = 5, top = 5, bottom = 5 }
                })

                local scrollContent

                if needsScroll then
                    local scrollFrame = CreateFrame("ScrollFrame", nil, d, "UIPanelScrollFrameTemplate")
                    scrollFrame:SetPoint("TOPLEFT", 8, -8)
                    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)

                    scrollContent = CreateFrame("Frame", nil, scrollFrame)
                    scrollContent:SetSize(175, itemHeight * #piValidFonts)
                    scrollFrame:SetScrollChild(scrollContent)
                    scrollFrame:SetVerticalScroll(0)
                else
                    scrollContent = CreateFrame("Frame", nil, d)
                    scrollContent:SetPoint("TOPLEFT", 8, -8)
                    scrollContent:SetPoint("BOTTOMRIGHT", -8, 8)
                end

                for i, f in ipairs(piValidFonts) do
                    local btn = CreateFrame("Button", nil, scrollContent)
                    btn:SetSize(175, itemHeight - 2)
                    btn:SetPoint("TOPLEFT", 0, -((i - 1) * itemHeight))
                    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

                    btn.text = btn:CreateFontString(nil, "OVERLAY")
                    btn.text:SetPoint("LEFT", 5, 0)
                    btn.text:SetPoint("RIGHT", -5, 0)
                    btn.text:SetJustifyH("LEFT")
                    btn.text:SetFont(f.path, 12, "")
                    btn.text:SetText(f.name)
                    btn.text:SetTextColor(1, 0.82, 0)

                    btn:SetScript("OnClick", function()
                        group.font = f.path
                        self:SetText(f.name)
                        d:Hide()
                        C_Timer.After(0.1, function()
                            if not InCombatLockdown() then
                                Wise:UpdateGroupDisplay(Wise.selectedGroup)
                            end
                        end)
                        -- Refresh to show "(Custom)" label
                        Wise:RefreshPropertiesPanel()
                    end)

                    btn:SetScript("OnEnter", function(self)
                        self.text:SetTextColor(1, 1, 1)
                    end)
                    btn:SetScript("OnLeave", function(self)
                        self.text:SetTextColor(1, 0.82, 0)
                    end)
                end
            end
            self.dropdown:Show()
        end)
        tinsert(panel.controls, piFontBtn)

        y = y - 35

        -- Per-Interface Keybind Settings
        local piKbLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piKbLabel:SetPoint("TOPLEFT", 10, y)
        piKbLabel:SetText("Keybinds:" .. ( (group.showKeybinds~=nil or group.keybindPosition or group.keybindTextSize) and " |cffff8800(Custom)|r" or ""))
        tinsert(panel.controls, piKbLabel)
        y = y - 22

        -- Show Checkbox
        local piShowKb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        piShowKb:SetPoint("TOPLEFT", 10, y)
        -- Tri-state logic: nil = global, true/false = override
        local currentShow = group.showKeybinds
        if currentShow == nil then currentShow = WiseDB.settings.showKeybinds end
        piShowKb:SetChecked(currentShow)

        piShowKb.text = piShowKb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        piShowKb.text:SetPoint("LEFT", piShowKb, "RIGHT", 5, 0)
        piShowKb.text:SetText("Show")
        piShowKb:SetScript("OnClick", function(self)
            group.showKeybinds = self:GetChecked()
            UpdateDisplayStatus() -- Updates Reset Button
            Wise:RefreshPropertiesPanel() -- To update label (Custom)
            C_Timer.After(0.1, function() Wise:UpdateGroupDisplay(Wise.selectedGroup) end)
        end)
        tinsert(panel.controls, piShowKb)
        tinsert(panel.controls, piShowKb.text)

        y = y - 30

        -- Position
        local piKbPosLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piKbPosLabel:SetPoint("TOPLEFT", 10, y)
        local effectiveKbPos = group.keybindPosition or WiseDB.settings.keybindPosition or "TOP"
        piKbPosLabel:SetText("Position: " .. effectiveKbPos)
        tinsert(panel.controls, piKbPosLabel)
        y = y - 22

        local kbPositions = {
            {val="TOPLEFT", text="Top Left"}, {val="TOP", text="Top"}, {val="TOPRIGHT", text="Top Right"},
            {val="LEFT", text="Left"}, {val="CENTER", text="Center"}, {val="RIGHT", text="Right"},
            {val="BOTTOMLEFT", text="Bottom Left"}, {val="BOTTOM", text="Bottom"}, {val="BOTTOMRIGHT", text="Bottom Right"},
        }
        for _, posMode in ipairs(kbPositions) do
             local radio = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
             radio:SetPoint("TOPLEFT", 10, y)
             radio:SetChecked(effectiveKbPos == posMode.val)
             radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
             radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)
             radio.text:SetText(posMode.text)

             radio:SetScript("OnClick", function(self)
                 group.keybindPosition = posMode.val
                 -- Refresh to update label/check and Reset button
                 Wise:RefreshPropertiesPanel()
                 C_Timer.After(0.1, function() Wise:UpdateGroupDisplay(Wise.selectedGroup) end)
             end)
             tinsert(panel.controls, radio)
             tinsert(panel.controls, radio.text)
             y = y - 22
        end

        y = y - 10

        -- Size
        local piKbSizeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piKbSizeLabel:SetPoint("TOPLEFT", 10, y)
        local effectiveKbSize = group.keybindTextSize or WiseDB.settings.keybindTextSize or 10
        piKbSizeLabel:SetText("Size: " .. effectiveKbSize)
        tinsert(panel.controls, piKbSizeLabel)
        y = y - 22

        local piKbSizeSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
        piKbSizeSlider:SetPoint("TOPLEFT", 10, y)
        piKbSizeSlider:SetSize(180, 16)
        piKbSizeSlider:SetMinMaxValues(8, 24)
        piKbSizeSlider:SetValue(effectiveKbSize)
        piKbSizeSlider:SetValueStep(1)
        piKbSizeSlider:SetObeyStepOnDrag(true)
        piKbSizeSlider.Low:SetText("8")
        piKbSizeSlider.High:SetText("24")
        piKbSizeSlider.Text:SetText(tostring(effectiveKbSize))
        piKbSizeSlider:SetScript("OnValueChanged", function(self, value)
            local size = math.floor(value)
            group.keybindTextSize = size
            self.Text:SetText(tostring(size))
            piKbSizeLabel:SetText("Size: " .. size)
            UpdateDisplayStatus()
            C_Timer.After(0.1, function() Wise:UpdateGroupDisplay(Wise.selectedGroup) end)
        end)
        tinsert(panel.controls, piKbSizeSlider)

        y = y - 35

        -- Per-Interface Charge Text Settings
        local piChargeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piChargeLabel:SetPoint("TOPLEFT", 10, y)
        piChargeLabel:SetText("Charge Text:" .. ( (group.chargeTextSize or group.chargeTextPosition or group.showChargeText ~= nil) and " |cffff8800(Custom)|r" or ""))
        tinsert(panel.controls, piChargeLabel)
        y = y - 22

        -- Show Checkbox
        local piShowCharge = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        piShowCharge:SetPoint("TOPLEFT", 10, y)
        local currentShowCharge = group.showChargeText
        if currentShowCharge == nil then currentShowCharge = WiseDB.settings.showChargeText end
        if currentShowCharge == nil then currentShowCharge = true end
        piShowCharge:SetChecked(currentShowCharge)

        piShowCharge.text = piShowCharge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        piShowCharge.text:SetPoint("LEFT", piShowCharge, "RIGHT", 5, 0)
        piShowCharge.text:SetText("Show")
        piShowCharge:SetScript("OnClick", function(self)
            group.showChargeText = self:GetChecked()
            UpdateDisplayStatus() -- Updates Reset Button
            Wise:RefreshPropertiesPanel() -- To update label (Custom)
            C_Timer.After(0.1, function() 
                if not InCombatLockdown() then Wise:UpdateGroupDisplay(Wise.selectedGroup) end
                if Wise.UpdateAllCharges then Wise:UpdateAllCharges() end
            end)
        end)
        tinsert(panel.controls, piShowCharge)
        tinsert(panel.controls, piShowCharge.text)

        y = y - 30

        -- Position
        local piChargePosLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piChargePosLabel:SetPoint("TOPLEFT", 10, y)
        local effectiveChargePos = group.chargeTextPosition or WiseDB.settings.chargeTextPosition or "BOTTOMRIGHT"
        piChargePosLabel:SetText("Position: " .. effectiveChargePos)
        tinsert(panel.controls, piChargePosLabel)
        y = y - 22

        local piChargePositions = {
            {val="TOPLEFT", text="Top Left"}, {val="TOP", text="Top"}, {val="TOPRIGHT", text="Top Right"},
            {val="LEFT", text="Left"}, {val="CENTER", text="Center"}, {val="RIGHT", text="Right"},
            {val="BOTTOMLEFT", text="Bottom Left"}, {val="BOTTOM", text="Bottom"}, {val="BOTTOMRIGHT", text="Bottom Right"},
        }
        for _, posMode in ipairs(piChargePositions) do
             local radio = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
             radio:SetPoint("TOPLEFT", 10, y)
             radio:SetChecked(effectiveChargePos == posMode.val)
             radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
             radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)
             radio.text:SetText(posMode.text)

             radio:SetScript("OnClick", function(self)
                 group.chargeTextPosition = posMode.val
                 -- Refresh to update label/check and Reset button
                 Wise:RefreshPropertiesPanel()
                 if not InCombatLockdown() then
                     Wise:UpdateGroupDisplay(Wise.selectedGroup)
                 end
             end)
             tinsert(panel.controls, radio)
             tinsert(panel.controls, radio.text)
             y = y - 22
        end

        y = y - 10

        -- Size
        local piChargeSizeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piChargeSizeLabel:SetPoint("TOPLEFT", 10, y)
        local effectiveChargeSize = group.chargeTextSize or WiseDB.settings.chargeTextSize or 12
        piChargeSizeLabel:SetText("Size: " .. effectiveChargeSize)
        tinsert(panel.controls, piChargeSizeLabel)
        y = y - 22

        local piChargeSizeSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
        piChargeSizeSlider:SetPoint("TOPLEFT", 10, y)
        piChargeSizeSlider:SetSize(180, 16)
        piChargeSizeSlider:SetMinMaxValues(8, 24)
        piChargeSizeSlider:SetValue(effectiveChargeSize)
        piChargeSizeSlider:SetValueStep(1)
        piChargeSizeSlider:SetObeyStepOnDrag(true)
        piChargeSizeSlider.Low:SetText("8")
        piChargeSizeSlider.High:SetText("24")
        piChargeSizeSlider.Text:SetText(tostring(effectiveChargeSize))
        piChargeSizeSlider:SetScript("OnValueChanged", function(self, value)
            local size = math.floor(value)
            group.chargeTextSize = size
            self.Text:SetText(tostring(size))
            piChargeSizeLabel:SetText("Size: " .. size)
            UpdateDisplayStatus()
            C_Timer.After(0.1, function() Wise:UpdateGroupDisplay(Wise.selectedGroup) end)
        end)
        tinsert(panel.controls, piChargeSizeSlider)

        y = y - 35

        -- Per-Interface Countdown Text Settings
        local piCountdownLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piCountdownLabel:SetPoint("TOPLEFT", 10, y)
        piCountdownLabel:SetText("Countdown Text:" .. ( (group.countdownTextSize or group.countdownTextPosition or group.showCountdownText ~= nil) and " |cffff8800(Custom)|r" or ""))
        tinsert(panel.controls, piCountdownLabel)
        y = y - 22

        -- Show Checkbox
        local piShowCountdown = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        piShowCountdown:SetPoint("TOPLEFT", 10, y)
        local currentShowCountdown = group.showCountdownText
        if currentShowCountdown == nil then currentShowCountdown = WiseDB.settings.showCountdownText end
        if currentShowCountdown == nil then currentShowCountdown = true end
        piShowCountdown:SetChecked(currentShowCountdown)

        piShowCountdown.text = piShowCountdown:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        piShowCountdown.text:SetPoint("LEFT", piShowCountdown, "RIGHT", 5, 0)
        piShowCountdown.text:SetText("Show")
        piShowCountdown:SetScript("OnClick", function(self)
            group.showCountdownText = self:GetChecked()
            UpdateDisplayStatus() -- Updates Reset Button
            Wise:RefreshPropertiesPanel() -- To update label (Custom)
            C_Timer.After(0.1, function() 
                if not InCombatLockdown() and Wise.UpdateAllCooldowns then Wise:UpdateAllCooldowns() end
            end)
        end)
        tinsert(panel.controls, piShowCountdown)
        tinsert(panel.controls, piShowCountdown.text)

        y = y - 30

        -- Position
        local piCountdownPosLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piCountdownPosLabel:SetPoint("TOPLEFT", 10, y)
        local effectiveCountdownPos = group.countdownTextPosition or WiseDB.settings.countdownTextPosition or "CENTER"
        piCountdownPosLabel:SetText("Position: " .. effectiveCountdownPos)
        tinsert(panel.controls, piCountdownPosLabel)
        y = y - 22

        -- Re-use charge text positions list as they are standard compass points
        for _, posMode in ipairs(piChargePositions) do
             local radio = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
             radio:SetPoint("TOPLEFT", 10, y)
             radio:SetChecked(effectiveCountdownPos == posMode.val)
             radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
             radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)
             radio.text:SetText(posMode.text)

             radio:SetScript("OnClick", function(self)
                 group.countdownTextPosition = posMode.val
                 -- Refresh to update label/check and Reset button
                 Wise:RefreshPropertiesPanel()
                 if not InCombatLockdown() then
                     Wise:UpdateGroupDisplay(Wise.selectedGroup)
                 end
             end)
             tinsert(panel.controls, radio)
             tinsert(panel.controls, radio.text)
             y = y - 22
        end

        y = y - 10

        -- Size
        local piCountdownSizeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piCountdownSizeLabel:SetPoint("TOPLEFT", 10, y)
        local effectiveCountdownSize = group.countdownTextSize or WiseDB.settings.countdownTextSize or 12
        piCountdownSizeLabel:SetText("Size: " .. effectiveCountdownSize)
        tinsert(panel.controls, piCountdownSizeLabel)
        y = y - 22

        local piCountdownSizeSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
        piCountdownSizeSlider:SetPoint("TOPLEFT", 10, y)
        piCountdownSizeSlider:SetSize(180, 16)
        piCountdownSizeSlider:SetMinMaxValues(8, 24)
        piCountdownSizeSlider:SetValue(effectiveCountdownSize)
        piCountdownSizeSlider:SetValueStep(1)
        piCountdownSizeSlider:SetObeyStepOnDrag(true)
        piCountdownSizeSlider.Low:SetText("8")
        piCountdownSizeSlider.High:SetText("24")
        piCountdownSizeSlider.Text:SetText(tostring(effectiveCountdownSize))
        piCountdownSizeSlider:SetScript("OnValueChanged", function(self, value)
            local size = math.floor(value)
            group.countdownTextSize = size
            self.Text:SetText(tostring(size))
            piCountdownSizeLabel:SetText("Size: " .. size)
            UpdateDisplayStatus()
            C_Timer.After(0.1, function() Wise:UpdateGroupDisplay(Wise.selectedGroup) end)
        end)
        tinsert(panel.controls, piCountdownSizeSlider)

        y = y - 35

        -- Per-Interface GCD Setting
        local piGCDLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        piGCDLabel:SetPoint("TOPLEFT", 10, y)
        piGCDLabel:SetText("Show GCD:" .. (group.showGCD ~= nil and " |cffff8800(Custom)|r" or ""))
        tinsert(panel.controls, piGCDLabel)
        y = y - 22

        local piShowGCD = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        piShowGCD:SetPoint("TOPLEFT", 10, y)

        local currentShowGCD = group.showGCD
        if currentShowGCD == nil then
             currentShowGCD = WiseDB.settings.showGCD
             if currentShowGCD == nil then currentShowGCD = true end
        end
        piShowGCD:SetChecked(currentShowGCD)

        piShowGCD.text = piShowGCD:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        piShowGCD.text:SetPoint("LEFT", piShowGCD, "RIGHT", 5, 0)
        piShowGCD.text:SetText("Show")
        piShowGCD:SetScript("OnClick", function(self)
            group.showGCD = self:GetChecked()
            UpdateDisplayStatus() -- Updates Reset Button
            Wise:RefreshPropertiesPanel() -- To update label (Custom)
            C_Timer.After(0.1, function() Wise:UpdateAllCooldowns() end)
        end)
        tinsert(panel.controls, piShowGCD)
        tinsert(panel.controls, piShowGCD.text)

        y = y - 30

        -- Reset to Global Settings Button
        resetGlobalBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        resetGlobalBtn:SetSize(180, 22)
        resetGlobalBtn:SetPoint("TOPLEFT", 10, y)
        resetGlobalBtn:SetText("Reset to Global Settings")

        -- Initial State Check
        if not group.iconStyle and not group.iconSize and not group.textSize and not group.font and group.showKeybinds == nil and not group.keybindPosition and not group.keybindTextSize and not group.chargeTextSize and not group.chargeTextPosition and not group.countdownTextSize and not group.countdownTextPosition and group.showGCD == nil and group.showChargeText == nil and group.showCountdownText == nil then
            resetGlobalBtn:Disable()
        end

        resetGlobalBtn:SetScript("OnClick", function()
            group.iconStyle = nil
            group.iconSize = nil
            group.textSize = nil
            group.font = nil
            group.showKeybinds = nil
            group.keybindPosition = nil
            group.keybindTextSize = nil
            group.showChargeText = nil
            group.chargeTextSize = nil
            group.chargeTextPosition = nil
            group.showCountdownText = nil
            group.countdownTextSize = nil
            group.countdownTextPosition = nil
            group.showGCD = nil

            C_Timer.After(0.1, function()
                if not InCombatLockdown() then
                    Wise:UpdateGroupDisplay(Wise.selectedGroup)
                end
            end)
            Wise:RefreshPropertiesPanel()
        end)
        tinsert(panel.controls, resetGlobalBtn)

        y = y - 30
    end

    if not suppress.Padding then
        -- =============================================
        -- PADDING / SPACING SETTINGS (based on layout type)
        -- =============================================
        if group.type == "line" or group.type == "list" then
            -- Single Padding Slider
            local padLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            padLabel:SetPoint("TOPLEFT", 10, y)
            local currentPadding = group.padding or (group.type == "list" and 8 or 5)
            padLabel:SetText("Padding: " .. currentPadding)
            tinsert(panel.controls, padLabel)

            y = y - 22
            local padSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
            padSlider:SetPoint("TOPLEFT", 10, y)
            padSlider:SetSize(180, 16)
            padSlider:SetMinMaxValues(0, 40)
            padSlider:SetValue(currentPadding)
            padSlider:SetValueStep(1)
            padSlider:SetObeyStepOnDrag(true)
            padSlider.Low:SetText("0")
            padSlider.High:SetText("40")
            padSlider.Text:SetText(tostring(currentPadding))
            padSlider:SetScript("OnValueChanged", function(self, value)
                local v = math.floor(value)
                group.padding = v
                padLabel:SetText("Padding: " .. v)
                self.Text:SetText(tostring(v))
                C_Timer.After(0.1, function()
                    if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    end
                end)
            end)
            tinsert(panel.controls, padSlider)
            y = y - 40

        elseif group.type == "box" then
            -- X Padding Slider
            local padXLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            padXLabel:SetPoint("TOPLEFT", 10, y)
            local currentPadX = group.paddingX or 5
            padXLabel:SetText("X Padding: " .. currentPadX)
            tinsert(panel.controls, padXLabel)

            y = y - 22
            local padXSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
            padXSlider:SetPoint("TOPLEFT", 10, y)
            padXSlider:SetSize(180, 16)
            padXSlider:SetMinMaxValues(0, 40)
            padXSlider:SetValue(currentPadX)
            padXSlider:SetValueStep(1)
            padXSlider:SetObeyStepOnDrag(true)
            padXSlider.Low:SetText("0")
            padXSlider.High:SetText("40")
            padXSlider.Text:SetText(tostring(currentPadX))
            padXSlider:SetScript("OnValueChanged", function(self, value)
                local v = math.floor(value)
                group.paddingX = v
                padXLabel:SetText("X Padding: " .. v)
                self.Text:SetText(tostring(v))
                C_Timer.After(0.1, function()
                    if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    end
                end)
            end)
            tinsert(panel.controls, padXSlider)
            y = y - 40

            -- Y Padding Slider
            local padYLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            padYLabel:SetPoint("TOPLEFT", 10, y)
            local currentPadY = group.paddingY or 5
            padYLabel:SetText("Y Padding: " .. currentPadY)
            tinsert(panel.controls, padYLabel)

            y = y - 22
            local padYSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
            padYSlider:SetPoint("TOPLEFT", 10, y)
            padYSlider:SetSize(180, 16)
            padYSlider:SetMinMaxValues(0, 40)
            padYSlider:SetValue(currentPadY)
            padYSlider:SetValueStep(1)
            padYSlider:SetObeyStepOnDrag(true)
            padYSlider.Low:SetText("0")
            padYSlider.High:SetText("40")
            padYSlider.Text:SetText(tostring(currentPadY))
            padYSlider:SetScript("OnValueChanged", function(self, value)
                local v = math.floor(value)
                group.paddingY = v
                padYLabel:SetText("Y Padding: " .. v)
                self.Text:SetText(tostring(v))
                C_Timer.After(0.1, function()
                    if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    end
                end)
            end)
            tinsert(panel.controls, padYSlider)
            y = y - 40

        elseif group.type == "circle" then
            -- Radius Slider
            local effectiveIconSize = group.iconSize or (WiseDB.settings and WiseDB.settings.iconSize) or 30
            local actionCount = 0
            if group.actions then
                for _ in pairs(group.actions) do actionCount = actionCount + 1 end
            end
            if actionCount < 2 then actionCount = 2 end -- Prevent division by zero
            local minRadius = math.ceil(effectiveIconSize / (2 * math.sin(math.pi / actionCount)))
            if minRadius < effectiveIconSize then minRadius = effectiveIconSize end -- Absolute floor

            local currentRadius = group.circleRadius or (effectiveIconSize * 2)
            if currentRadius < minRadius then currentRadius = minRadius end

            local radLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            radLabel:SetPoint("TOPLEFT", 10, y)
            radLabel:SetText("Radius: " .. currentRadius)
            tinsert(panel.controls, radLabel)

            y = y - 22
            local radSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
            radSlider:SetPoint("TOPLEFT", 10, y)
            radSlider:SetSize(180, 16)
            radSlider:SetMinMaxValues(minRadius, 200)
            radSlider:SetValue(currentRadius)
            radSlider:SetValueStep(1)
            radSlider:SetObeyStepOnDrag(true)
            radSlider.Low:SetText(tostring(minRadius))
            radSlider.High:SetText("200")
            radSlider.Text:SetText(tostring(currentRadius))
            radSlider:SetScript("OnValueChanged", function(self, value)
                local v = math.floor(value)
                group.circleRadius = v
                radLabel:SetText("Radius: " .. v)
                self.Text:SetText(tostring(v))
                C_Timer.After(0.1, function()
                    if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    end
                end)
            end)
            tinsert(panel.controls, radSlider)
            y = y - 40

            -- Rotation Slider (0-359 degrees)
            local currentRotation = group.circleRotation or 0
            local rotLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            rotLabel:SetPoint("TOPLEFT", 10, y)
            rotLabel:SetText("Rotation: " .. currentRotation .. "\194\176")
            tinsert(panel.controls, rotLabel)

            y = y - 22
            local rotSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
            rotSlider:SetPoint("TOPLEFT", 10, y)
            rotSlider:SetSize(180, 16)
            rotSlider:SetMinMaxValues(0, 359)
            rotSlider:SetValue(currentRotation)
            rotSlider:SetValueStep(1)
            rotSlider:SetObeyStepOnDrag(true)
            rotSlider.Low:SetText("0\194\176")
            rotSlider.High:SetText("359\194\176")
            rotSlider.Text:SetText(tostring(currentRotation) .. "\194\176")
            rotSlider:SetScript("OnValueChanged", function(self, value)
                local v = math.floor(value)
                group.circleRotation = v
                rotLabel:SetText("Rotation: " .. v .. "\194\176")
                self.Text:SetText(tostring(v) .. "\194\176")
                C_Timer.After(0.1, function()
                    if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    end
                end)
            end)
            tinsert(panel.controls, rotSlider)
            y = y - 40
        end
    end

    if not suppress.AnchorMode then
        -- Anchor Mode
        local anchorLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        anchorLabel:SetPoint("TOPLEFT", 10, y)
        anchorLabel:SetText("Anchor Mode:")
        tinsert(panel.controls, anchorLabel)

        y = y - 20
        local anchorBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
        anchorBtn:SetSize(140, 22)
        anchorBtn:SetPoint("TOPLEFT", 10, y)
        anchorBtn:SetText((group.anchorMode or "fixed"):upper())
        anchorBtn:SetScript("OnClick", function()
            local modes = {"fixed", "mouse"}
            local current = group.anchorMode or "fixed"
            local nextIndex = current == "fixed" and 2 or 1
            group.anchorMode = modes[nextIndex]
            Wise:RefreshPropertiesPanel()
            C_Timer.After(0, function()
                if not InCombatLockdown() then
                    Wise:UpdateGroupDisplay(Wise.selectedGroup)
                end
            end)
        end)
        tinsert(panel.controls, anchorBtn)

        -- Reset Position button (resets to CENTER 0,0)
        y = y - 25
        local resetBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
        resetBtn:SetSize(140, 22)
        resetBtn:SetPoint("TOPLEFT", 10, y)
        resetBtn:SetText("Reset Position")
        Wise:AddTooltip(resetBtn, "Reset this interface to the center of the screen.")
        resetBtn:SetScript("OnClick", function()
            if InCombatLockdown() then
                print("|cffff0000Wise:|r Cannot reposition during combat.")
                return
            end
            group.anchor = { point = "CENTER", x = 0, y = 0 }
            local f = Wise.frames[Wise.selectedGroup]
            if f and f.Anchor then
                f.Anchor:ClearAllPoints()
                f.Anchor:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                f:ClearAllPoints()
                f:SetPoint("CENTER", f.Anchor, "CENTER")
            end
            Wise:RefreshPropertiesPanel()
        end)
        tinsert(panel.controls, resetBtn)

        -- Mouse offset sliders (only show if mouse mode)
        if group.anchorMode == "mouse" then
            y = y - 25

            -- X Offset
            local xOffsetLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            xOffsetLabel:SetPoint("TOPLEFT", 10, y)
            xOffsetLabel:SetText("X Offset: " .. (group.mouseOffsetX or 0))
            tinsert(panel.controls, xOffsetLabel)

            y = y - 18
            local xSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
            xSlider:SetPoint("TOPLEFT", 10, y)
            xSlider:SetSize(160, 16)
            xSlider:SetMinMaxValues(-100, 100)
            xSlider:SetValue(group.mouseOffsetX or 0)
            xSlider:SetValueStep(5)
            xSlider:SetObeyStepOnDrag(true)
            xSlider.Low:SetText("-100")
            xSlider.High:SetText("100")
            xSlider.Text:SetText("")
            xSlider:SetScript("OnValueChanged", function(self, value)
                group.mouseOffsetX = math.floor(value)
                xOffsetLabel:SetText("X Offset: " .. group.mouseOffsetX)
            end)
            tinsert(panel.controls, xSlider)

            y = y - 25

            -- Y Offset
            local yOffsetLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            yOffsetLabel:SetPoint("TOPLEFT", 10, y)
            yOffsetLabel:SetText("Y Offset: " .. (group.mouseOffsetY or 0))
            tinsert(panel.controls, yOffsetLabel)

            y = y - 18
            local ySlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
            ySlider:SetPoint("TOPLEFT", 10, y)
            ySlider:SetSize(160, 16)
            ySlider:SetMinMaxValues(-100, 100)
            ySlider:SetValue(group.mouseOffsetY or 0)
            ySlider:SetValueStep(5)
            ySlider:SetObeyStepOnDrag(true)
            ySlider.Low:SetText("-100")
            ySlider.High:SetText("100")
            ySlider.Text:SetText("")
            ySlider:SetScript("OnValueChanged", function(self, value)
                group.mouseOffsetY = math.floor(value)
                yOffsetLabel:SetText("Y Offset: " .. group.mouseOffsetY)
            end)
            tinsert(panel.controls, ySlider)

            y = y - 10
        end
    end

    if Wise.selectedSlot and group.actions and group.actions[Wise.selectedSlot] then
         y = y - 30

         local slotLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
         slotLabel:SetPoint("TOPLEFT", 10, y)
         slotLabel:SetText("Slot " .. Wise.selectedSlot .. " Keybind:")
         tinsert(panel.controls, slotLabel)
         y = y - 20

         local slotBindBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
         slotBindBtn:SetSize(140, 22)
         slotBindBtn:SetPoint("TOPLEFT", 10, y)
         local slotBind = group.actions[Wise.selectedSlot].keybind
         slotBindBtn:SetText(slotBind or "None")

         slotBindBtn:RegisterForClicks("AnyUp")
         slotBindBtn:SetScript("OnClick", function(self, button)
             if button == "RightButton" then
                 group.actions[Wise.selectedSlot].keybind = nil
                 Wise:UpdateBindings() -- Update bindings logic
                 self:SetText("None")
             else
                 self:SetText("Press Key...")
                 self:EnableKeyboard(true)
                 self:SetScript("OnKeyDown", function(self, key)
                     if key == "ESCAPE" then
                         self:EnableKeyboard(false)
                         self:SetScript("OnKeyDown", nil)
                         self:SetText(group.actions[Wise.selectedSlot].keybind or "None")
                         return
                     end
                     if key:find("SHIFT") or key:find("CTRL") or key:find("ALT") then return end

                     local mods = ""
                     if IsAltKeyDown() then mods = mods .. "ALT-" end
                     if IsControlKeyDown() then mods = mods .. "CTRL-" end
                     if IsShiftKeyDown() then mods = mods .. "SHIFT-" end

                     local fullKey = mods .. key
                     self:EnableKeyboard(false)
                     self:SetScript("OnKeyDown", nil)

                     if Wise:CheckBindingConflict(fullKey, group, Wise.selectedSlot, true, self) then
                         return
                     end

                     group.actions[Wise.selectedSlot].keybind = fullKey
                     self:SetText(fullKey)

                     Wise:UpdateBindings()
                 end)
             end
         end)
         tinsert(panel.controls, slotBindBtn)

         -- Hint
         local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
         hint:SetPoint("LEFT", slotBindBtn, "RIGHT", 5, 0)
         hint:SetText( (group.keybindSettings and group.keybindSettings.nested) and "[Nested]" or "[Global]" )
         tinsert(panel.controls, hint)

         y = y - 10
    end

    y = y - 30

    if not suppress.Visibility then
        -- Visibility Section
        -- (Top Spacer)
        y = y - 10

        -- Easy Mode Header
        local visLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        visLabel:SetPoint("TOPLEFT", 10, y)
        visLabel:SetText("Visibility (Easy Mode):")
        tinsert(panel.controls, visLabel)

        y = y - 25

        --------------------------------------------------
        -- VISIBILITY MODE LOGIC
        --------------------------------------------------

        local function GetVisibilityMode()
            local s = group.visibilitySettings.customShow or ""
            local h = group.visibilitySettings.customHide or ""
            local held = group.visibilitySettings.held
            local toggle = group.visibilitySettings.toggleOnPress

            -- Strict checks for preset modes
            if s == "[always]" and h == "" and not held and not toggle then return "always" end
            if h == "[always]" and s == "" and not held and not toggle then return "hidden" end
            if s == "[combat]" and h == "" and not held and not toggle then return "combat" end
            if s == "[nocombat]" and h == "" and not held and not toggle then return "nocombat" end

            local groupToken = "[wise:" .. (Wise.selectedGroup or "Group") .. "]"
            if held and s == groupToken and not toggle then return "held" end
            if toggle and s == groupToken and not held then return "toggle" end

            return nil -- Custom or mixed state
        end

        local function SetVisibilityMode(mode, enable)
            -- 1. Clear everything first (Enforce Exclusivity)
            group.visibilitySettings.customShow = ""
            group.visibilitySettings.customHide = ""
            group.visibilitySettings.held = false
            group.visibilitySettings.toggleOnPress = false
            -- Note: We DON'T clear hideOnUse here, handled separately or by mode

            if not enable then
                -- Just cleared, done
                return
            end

            -- 2. Apply Mode
            if mode == "always" then
                group.visibilitySettings.customShow = "[always]"
            elseif mode == "hidden" then
                group.visibilitySettings.customHide = "[always]"
            elseif mode == "combat" then
                group.visibilitySettings.customShow = "[combat]"
            elseif mode == "nocombat" then
                group.visibilitySettings.customShow = "[nocombat]"
            elseif mode == "held" then
                local groupToken = "[wise:" .. (Wise.selectedGroup or "Group") .. "]"
                group.visibilitySettings.customShow = groupToken
                group.visibilitySettings.held = true

                -- Enforce trigger compatibility
                if group.keybindSettings and group.keybindSettings.trigger == "press" then
                     group.keybindSettings.trigger = "release_mouseover"
                end
            elseif mode == "toggle" then
                local groupToken = "[wise:" .. (Wise.selectedGroup or "Group") .. "]"
                group.visibilitySettings.customShow = groupToken
                group.visibilitySettings.toggleOnPress = true

                -- Force NONE Trigger for Toggle Mode
                if not group.keybindSettings then group.keybindSettings = {} end
                group.keybindSettings.trigger = "none"
            end
        end

        local currentMode = GetVisibilityMode()

        local function CreateCheckLogic(check, mode)
            check:SetChecked(currentMode == mode)
            check:SetScript("OnClick", function(self)
                SetVisibilityMode(mode, self:GetChecked())
                Wise:RefreshPropertiesPanel()

                C_Timer.After(0, function()
                   if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                        -- Force refresh Edit Mode state if needed (e.g. disabled -> hide overlay)
                        if Wise.editMode then
                            local f = Wise.frames[Wise.selectedGroup]
                            if f and Wise.SetFrameEditMode and Wise:IsGroupDisabled(group) then
                                Wise:SetFrameEditMode(f, Wise.selectedGroup, false)
                            elseif f and Wise.SetFrameEditMode and not Wise:IsGroupDisabled(group) then
                                -- Re-enable if it became enabled
                                Wise:SetFrameEditMode(f, Wise.selectedGroup, true)
                            end
                        end
                        -- Refresh sidebar list to update enabled/disabled colors
                        Wise:RefreshGroupList()
                   end
                end)
            end)
        end

        -- Row 1: Always Vis | Always Hide
        local chkAlwaysVis = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        chkAlwaysVis:SetPoint("TOPLEFT", 10, y)
        chkAlwaysVis.text = chkAlwaysVis:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        chkAlwaysVis.text:SetPoint("LEFT", chkAlwaysVis, "RIGHT", 5, 0)
        chkAlwaysVis.text:SetText("Always Visible")
        CreateCheckLogic(chkAlwaysVis, "always")
        tinsert(panel.controls, chkAlwaysVis)
        tinsert(panel.controls, chkAlwaysVis.text)

        local chkAlwaysHide = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        chkAlwaysHide:SetPoint("LEFT", chkAlwaysVis.text, "RIGHT", 15, 0)
        chkAlwaysHide.text = chkAlwaysHide:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        chkAlwaysHide.text:SetPoint("LEFT", chkAlwaysHide, "RIGHT", 5, 0)
        chkAlwaysHide.text:SetText("Always Hidden")
        CreateCheckLogic(chkAlwaysHide, "hidden")
        tinsert(panel.controls, chkAlwaysHide)
        tinsert(panel.controls, chkAlwaysHide.text)

        y = y - 25

        -- Row 2: Combat | No Combat
        local chkCombat = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        chkCombat:SetPoint("TOPLEFT", 10, y)
        chkCombat.text = chkCombat:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        chkCombat.text:SetPoint("LEFT", chkCombat, "RIGHT", 5, 0)
        chkCombat.text:SetText("Show In Combat")
        CreateCheckLogic(chkCombat, "combat")
        tinsert(panel.controls, chkCombat)
        tinsert(panel.controls, chkCombat.text)

        local chkOOC = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        chkOOC:SetPoint("LEFT", chkCombat.text, "RIGHT", 15, 0)
        chkOOC.text = chkOOC:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        chkOOC.text:SetPoint("LEFT", chkOOC, "RIGHT", 5, 0)
        chkOOC.text:SetText("Show Out of Combat")
        CreateCheckLogic(chkOOC, "nocombat")
        tinsert(panel.controls, chkOOC)
        tinsert(panel.controls, chkOOC.text)

        y = y - 30

        -- Row 3: Keybind Interactions (Only if Binding Exists)
        if group.binding then
             local visIntLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
             visIntLabel:SetPoint("TOPLEFT", 10, y)
             visIntLabel:SetText("Keybind Interaction (Visibility):")
             tinsert(panel.controls, visIntLabel)
             y = y - 20

             local chkHeld = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
             chkHeld:SetPoint("TOPLEFT", 10, y)
             chkHeld.text = chkHeld:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
             chkHeld.text:SetPoint("LEFT", chkHeld, "RIGHT", 5, 0)
             chkHeld.text:SetText("Hold to Show")
             CreateCheckLogic(chkHeld, "held")
             tinsert(panel.controls, chkHeld)
             tinsert(panel.controls, chkHeld.text)
             y = y - 22

             local chkToggle = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
             chkToggle:SetPoint("TOPLEFT", 10, y)
             chkToggle.text = chkToggle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
             chkToggle.text:SetPoint("LEFT", chkToggle, "RIGHT", 5, 0)
             chkToggle.text:SetText("Toggle on Press")
             CreateCheckLogic(chkToggle, "toggle")
             tinsert(panel.controls, chkToggle)
             tinsert(panel.controls, chkToggle.text)
             y = y - 22

             -- Hide on Action (Dependent on Toggle)
             if currentMode == "toggle" then
                local chkHideUse = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
                chkHideUse:SetPoint("TOPLEFT", 30, y) -- Indented
                chkHideUse.text = chkHideUse:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                chkHideUse.text:SetPoint("LEFT", chkHideUse, "RIGHT", 5, 0)
                chkHideUse.text:SetText("Hide on Action")
                chkHideUse:SetChecked(group.visibilitySettings.hideOnUse == true)
                chkHideUse:SetScript("OnClick", function(self)
                     group.visibilitySettings.hideOnUse = self:GetChecked()
                     -- No refresh needed for logic change logic, just redraw?
                     -- Actually refresh ensures consistency
                end)
                tinsert(panel.controls, chkHideUse)
                tinsert(panel.controls, chkHideUse.text)
                y = y - 22
             else
                group.visibilitySettings.hideOnUse = false
             end

             -- Nested Keybinds (Only if Toggle + Hide on Action are ON)
             if currentMode == "toggle" and group.visibilitySettings.hideOnUse then
                 local chkNested = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
                 chkNested:SetPoint("TOPLEFT", 10, y - 22)
                 chkNested.text = chkNested:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                 chkNested.text:SetPoint("LEFT", chkNested, "RIGHT", 5, 0)
                 chkNested.text:SetText("Nested Keybinds")

                 if not group.keybindSettings then group.keybindSettings = {} end
                 chkNested:SetChecked(group.keybindSettings.nested == true)

                 chkNested:SetScript("OnClick", function(self)
                      group.keybindSettings.nested = self:GetChecked()
                      Wise:UpdateBindings() -- Need to update binding logic
                      Wise:RefreshPropertiesPanel()
                      C_Timer.After(0, function() if not InCombatLockdown() then Wise:UpdateGroupDisplay(Wise.selectedGroup) end end)
                 end)
                 tinsert(panel.controls, chkNested)
                 tinsert(panel.controls, chkNested.text)
                 y = y - 22 -- Space for nested
             else
                 if group.keybindSettings then group.keybindSettings.nested = false end
             end

             y = y - 10
        end

        -- Custom Show / Hide (Hard Mode)
        local hardLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        hardLabel:SetPoint("TOPLEFT", 10, y)
        hardLabel:SetText("Visibility (Hard Mode):")
        tinsert(panel.controls, hardLabel)
        y = y - 25

        local customShowLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        customShowLabel:SetPoint("TOPLEFT", 10, y)
        customShowLabel:SetText("Custom Show Condition:")
        tinsert(panel.controls, customShowLabel)
        y = y - 18

        local customShowEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        customShowEdit:SetSize(200, 24) -- slightly taller
        customShowEdit:SetPoint("TOPLEFT", 14, y)
        customShowEdit:SetAutoFocus(false)
        customShowEdit:SetText((group.visibilitySettings and group.visibilitySettings.customShow) or "")
        customShowEdit:SetCursorPosition(0)

        local function SaveCustomShow(self)
            if not group.visibilitySettings then group.visibilitySettings = {} end
            local newText = self:GetText()
            if group.visibilitySettings.customShow == newText then return end
            group.visibilitySettings.customShow = newText

            Wise:RefreshPropertiesPanel() -- This will update checkboxes based on the new text
            C_Timer.After(0, function()
                if not InCombatLockdown() then
                    Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    if Wise.editMode then
                        local f = Wise.frames[Wise.selectedGroup]
                        if f and Wise.SetFrameEditMode then
                            Wise:SetFrameEditMode(f, Wise.selectedGroup, not Wise:IsGroupDisabled(group))
                        end
                    end
                    -- Refresh sidebar list to update enabled/disabled colors
                    Wise:RefreshGroupList()
                end
            end)
        end

        customShowEdit:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
            SaveCustomShow(self)
        end)
        customShowEdit:SetScript("OnEditFocusLost", function(self)
            SaveCustomShow(self)
        end)
        customShowEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

        tinsert(panel.controls, customShowEdit)
        tinsert(panel.controls, CreateConditionValidator(customShowEdit, panel))
        y = y - 35

        local customHideLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        customHideLabel:SetPoint("TOPLEFT", 10, y)
        customHideLabel:SetText("Custom Hide Condition:")
        tinsert(panel.controls, customHideLabel)
        y = y - 18

        local customHideEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        customHideEdit:SetSize(200, 24) -- slightly taller
        customHideEdit:SetPoint("TOPLEFT", 14, y)
        customHideEdit:SetAutoFocus(false)
        customHideEdit:SetText((group.visibilitySettings and group.visibilitySettings.customHide) or "")
        customHideEdit:SetCursorPosition(0)

        local function SaveCustomHide(self)
            if not group.visibilitySettings then group.visibilitySettings = {} end
            local newText = self:GetText()
            if group.visibilitySettings.customHide == newText then return end
            group.visibilitySettings.customHide = newText

            Wise:RefreshPropertiesPanel()
            C_Timer.After(0, function()
                if not InCombatLockdown() then
                    Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    if Wise.editMode then
                        local f = Wise.frames[Wise.selectedGroup]
                        if f and Wise.SetFrameEditMode then
                            Wise:SetFrameEditMode(f, Wise.selectedGroup, not Wise:IsGroupDisabled(group))
                        end
                    end
                    -- Refresh sidebar list to update enabled/disabled colors
                    Wise:RefreshGroupList()
                end
            end)
        end

        customHideEdit:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
            SaveCustomHide(self)
        end)
        customHideEdit:SetScript("OnEditFocusLost", function(self)
            SaveCustomHide(self)
        end)
        customHideEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

        tinsert(panel.controls, customHideEdit)
        tinsert(panel.controls, CreateConditionValidator(customHideEdit, panel))
        y = y - 30

        -- Header / Spacer
        local header = panel:CreateTexture(nil, "ARTWORK")
        header:SetColorTexture(1, 1, 1, 0.2)
        header:SetSize(200, 1)
        header:SetPoint("TOPLEFT", 10, y)
        tinsert(panel.controls, header)
        y = y - 20
    end

    if not suppress.Keybind then
        -- KEYBIND SECTION
        local kbLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        kbLabel:SetPoint("TOPLEFT", 10, y)
        kbLabel:SetText("Keybind (Right Click to Clear):")
        tinsert(panel.controls, kbLabel)

        y = y - 20
        local bindBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
        bindBtn:SetSize(140, 22)
        bindBtn:SetPoint("TOPLEFT", 10, y)
        local currentBind = group.binding
        bindBtn:SetText(currentBind or "None")

        bindBtn:RegisterForClicks("AnyUp")
        bindBtn:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                group.binding = nil
                Wise:UpdateBindings()
                Wise:UpdateOptionsUI()
            elseif button == "LeftButton" then
                self:SetText("Press Key...")
                self:EnableKeyboard(true)
                self:EnableMouseWheel(true)

                local function FinishBinding(key)
                    if not key then return end

                    if key == "ESCAPE" then
                        self:EnableKeyboard(false)
                        self:EnableMouseWheel(false)
                        self:SetScript("OnKeyDown", nil)
                        self:SetScript("OnMouseWheel", nil)
                        Wise:RefreshPropertiesPanel()
                        return
                    end

                    if key:find("SHIFT") or key:find("CTRL") or key:find("ALT") then
                        return
                    end

                    local mods = ""
                    if IsAltKeyDown() then mods = mods .. "ALT-" end
                    if IsControlKeyDown() then mods = mods .. "CTRL-" end
                    if IsShiftKeyDown() then mods = mods .. "SHIFT-" end

                    -- Check MouseWheel Validation
                    if key == "MOUSEWHEELUP" or key == "MOUSEWHEELDOWN" then
                        -- If this is an initial binding (no previous binding), auto-fix settings
                        if not group.binding or group.binding == "" then
                            if not group.keybindSettings then group.keybindSettings = {} end
                            group.keybindSettings.trigger = "press"
                            if group.visibilitySettings then
                                group.visibilitySettings.held = false
                            end
                        end

                        local isValid, err = Wise:ValidateMouseWheelBinding(group, false)
                        if not isValid then
                            StaticPopup_Show("WISE_BINDING_ERROR", err)
                            self:EnableKeyboard(false)
                            self:EnableMouseWheel(false)
                            self:SetScript("OnKeyDown", nil)
                            self:SetScript("OnMouseWheel", nil)
                            Wise:RefreshPropertiesPanel()
                            return
                        end
                    end

                    local fullKey = mods .. key
                    self:EnableKeyboard(false)
                    self:EnableMouseWheel(false)
                    self:SetScript("OnKeyDown", nil)
                    self:SetScript("OnMouseWheel", nil)

                    if Wise:CheckBindingConflict(fullKey, group, nil, false, self) then
                        return
                    end

                    group.binding = fullKey

                    Wise:UpdateBindings()
                    Wise:UpdateOptionsUI()
                end

                self:SetScript("OnKeyDown", function(self, key)
                    FinishBinding(key)
                end)

                self:SetScript("OnMouseWheel", function(self, delta)
                    local key = (delta > 0) and "MOUSEWHEELUP" or "MOUSEWHEELDOWN"
                    FinishBinding(key)
                end)
            end
        end)
        tinsert(panel.controls, bindBtn)
        y = y - 30

        -- Show Interactions only if Keybind exists
        if group.binding then
             -- Separator
             local div = panel:CreateTexture(nil, "ARTWORK")
             div:SetColorTexture(1, 1, 1, 0.2)
             div:SetSize(200, 1)
             div:SetPoint("TOPLEFT", 10, y)
             tinsert(panel.controls, div)
             y = y - 20

            local function IsTriggerAllowed(triggerVal)
                -- Toggle Mode Rule: ONLY "none" is allowed
                if group.visibilitySettings.toggleOnPress then
                    return triggerVal == "none"
                end

                if triggerVal == "press" then
                    -- Only allowed for "button" type interfaces
                    return (group.type == "button")
                elseif triggerVal == "release_mouseover" or triggerVal == "release_repeat" then
                    -- Only allowed for NON-"button" type interfaces
                    return (group.type ~= "button")
                end
                -- "none" is always allowed
                return true
            end

            y = y - 10

            local actIntLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            actIntLabel:SetPoint("TOPLEFT", 10, y)
            actIntLabel:SetText("Keybind Trigger method:")
            tinsert(panel.controls, actIntLabel)
            y = y - 20

            -- 4-Way Radio Buttons for Trigger Mode
            local function CreateRadio(label, triggerValue)
                local check = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
                check:SetPoint("TOPLEFT", 10, y)

                -- Normalize current trigger
                local currentTrigger = (group.keybindSettings and group.keybindSettings.trigger) or "release_mouseover"
                -- Legacy fallback
                if currentTrigger == "release_mouseover" and group.keybindSettings and group.keybindSettings.repeatPrevious then
                     currentTrigger = "release_repeat"
                end

                check:SetChecked(currentTrigger == triggerValue)

                check.text = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                check.text:SetPoint("LEFT", check, "RIGHT", 5, 0)
                check.text:SetText(label)

                -- Disable if not allowed (e.g. "press" on non-button)
                if not IsTriggerAllowed(triggerValue) then
                    check:Disable()
                    check:SetAlpha(0.5)
                    check.text:SetTextColor(0.5, 0.5, 0.5)

                    -- Force unchecked if disabled to prevent confusing double-selection in UI
                    check:SetChecked(false)
                else
                    check:Enable()
                    check:SetAlpha(1)
                    check.text:SetTextColor(1, 1, 1) -- Normal color (actually usually handled by template, but ensuring white/standard)
                end

                check:SetScript("OnClick", function(self)
                     if not IsTriggerAllowed(triggerValue) then
                         self:SetChecked(false)
                         return
                     end

                     if not group.keybindSettings then group.keybindSettings = {} end

                     group.keybindSettings.trigger = triggerValue
                     group.keybindSettings.repeatPrevious = false

                     -- Rule: Press -> Disable Hold to Show
                     if triggerValue == "press" then
                         if group.visibilitySettings.held then
                             group.visibilitySettings.held = false
                             local token = "[wise:" .. (Wise.selectedGroup or "Group") .. "]"
                             group.visibilitySettings.customShow = UpdateConditionStr(group.visibilitySettings.customShow, token, false)
                         end
                     end

                     Wise:RefreshPropertiesPanel()
                     C_Timer.After(0, function()
                        if not InCombatLockdown() then Wise:UpdateGroupDisplay(Wise.selectedGroup) end
                     end)
                end)

                tinsert(panel.controls, check)
                tinsert(panel.controls, check.text)
                y = y - 22
            end

            CreateRadio("On Key Press", "press")
            CreateRadio("On Key Release @ Mouseover", "release_mouseover")
            CreateRadio("On Key Release with repeat if no change", "release_repeat")
            CreateRadio("None", "none")

        else
            local help = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            help:SetPoint("TOPLEFT", 10, y)
            help:SetText("(Assign a keybind to configure interactions)")
            help:SetTextColor(0.5, 0.5, 0.5)
            tinsert(panel.controls, help)
            y = y - 20
        end

        -- Right click hint
        local clearHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        clearHint:SetPoint("LEFT", bindBtn, "RIGHT", 5, 0)
        clearHint:SetText("(right click to clear)")
        tinsert(panel.controls, clearHint)

        y = y - 30
    end

    if inject.Bottom then
        y = inject.Bottom(panel, group, y)
    end

    if not suppress.Actions then
        -- Export Interface Button (custom interfaces only)
        if not group.isWiser then
            local exportBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
            exportBtn:SetSize(140, 22)
            exportBtn:SetPoint("TOPLEFT", 10, y)
            exportBtn:SetText("Export Interface")
            exportBtn:SetScript("OnClick", function()
                local name = Wise.selectedGroup
                if not name or not WiseDB.groups[name] then return end
                local encoded = Wise:ExportInterfaces({name})
                StaticPopupDialogs["WISE_EXPORT"] = {
                    text = "Copy the export string below (Ctrl+A, Ctrl+C):",
                    button1 = "Close",
                    hasEditBox = true,
                    editBoxWidth = 350,
                    OnShow = function(self)
                        local eb = self.EditBox or self.editBox; if not eb then return end
                        eb:SetText(encoded)
                        eb:HighlightText()
                        eb:SetFocus()
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = true,
                    preferredIndex = 3,
                }
                StaticPopup_Show("WISE_EXPORT")
            end)
            tinsert(panel.controls, exportBtn)
            y = y - 26
        end

        if group.isWiser then
             -- Duplicate Button for Wiser Groups
             local dupBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
             dupBtn:SetSize(140, 22)
             dupBtn:SetPoint("TOPLEFT", 10, y)
             dupBtn:SetText("Duplicate Interface")
             dupBtn:SetScript("OnClick", function()
                 local newName = Wise.selectedGroup .. " - copy"
                 local conflictCount = 1
                 while WiseDB.groups[newName] do
                     conflictCount = conflictCount + 1
                     newName = Wise.selectedGroup .. " - copy " .. conflictCount
                 end

                 -- Deep Copy
                 local source = WiseDB.groups[Wise.selectedGroup]
                 local newGroup = {}
                 -- Helper recursive copy
                 local function deepCopy(t)
                     local copy = {}
                     for k, v in pairs(t) do
                         if type(v) == "table" then
                             copy[k] = deepCopy(v)
                         else
                             copy[k] = v
                         end
                     end
                     return copy
                 end
                 newGroup = deepCopy(source)

                 newGroup.isWiser = nil -- It's now a custom custom group
                 WiseDB.groups[newName] = newGroup

                 Wise:UpdateGroupDisplay(newName)
                 Wise.selectedGroup = newName
                 Wise:RefreshGroupList()
                 Wise:RefreshPropertiesPanel()
             end)
             tinsert(panel.controls, dupBtn)

             -- Reset to Default Button for Wiser Groups
             y = y - 25
             local resetBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
             resetBtn:SetSize(140, 22)
             resetBtn:SetPoint("TOPLEFT", 10, y)
             resetBtn:SetText("Reset to Default")
             resetBtn:SetScript("OnClick", function()
                 StaticPopupDialogs["WISE_CONFIRM_RESET"] = {
                    text = "Reset '" .. Wise.selectedGroup .. "' to default configuration?",
                    button1 = "Yes",
                    button2 = "No",
                    OnAccept = function()
                        -- Determine which type of Wiser interface this is and regenerate it
                        -- Simply calling UpdateWiserInterfaces will regenerate all, which is fine and safe
                        -- But first we must clear the current buttons to ensure clean slate
                        local g = WiseDB.groups[Wise.selectedGroup]
                        if g then g.buttons = {} end

                        Wise:UpdateWiserInterfaces()

                        C_Timer.After(0.5, function()
                             Wise:UpdateGroupDisplay(Wise.selectedGroup)
                             Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
                             Wise:RefreshPropertiesPanel()
                        end)
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = true,
                    preferredIndex = 3,
                }
                StaticPopup_Show("WISE_CONFIRM_RESET")
             end)
             tinsert(panel.controls, resetBtn)

        else
            -- Delete Group Button
            local delBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
            delBtn:SetSize(140, 22)
            delBtn:SetPoint("TOPLEFT", 10, y)
            delBtn:SetText("Delete Interface")
            delBtn:SetScript("OnClick", function()
                 StaticPopupDialogs["WISE_CONFIRM_DELETE"] = {
                    text = "Delete group '" .. Wise.selectedGroup .. "'?",
                    button1 = "Yes",
                    button2 = "No",
                    OnAccept = function()
                        Wise:DeleteGroup(Wise.selectedGroup)
                        Wise.selectedGroup = nil
                        Wise:RefreshGroupList()
                        Wise:RefreshPropertiesPanel()
                        Wise:UpdateOptionsUI()
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = true,
                    preferredIndex = 3,
                }
                StaticPopup_Show("WISE_CONFIRM_DELETE")
            end)
            tinsert(panel.controls, delBtn)
        end
        y = y - 40
    end

    return y
end
