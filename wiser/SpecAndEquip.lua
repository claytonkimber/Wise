local addonName, Wise = ...

local tinsert = table.insert

-- ============================================================================
-- Data Initialization
-- ============================================================================

-- Spec and Equipment Changer stores its slots in WiseDB.specEquipSlots
-- Each slot: { name = "My Tank Setup", specIndex = 2, talentConfigID = 12345, equipmentSetName = "Tank Set", icon = texturePath, keybind = "ALT-F1" }
local function EnsureData()
    if not WiseDB then return end
    WiseDB.specEquipSlots = WiseDB.specEquipSlots or {}
end

-- ============================================================================
-- Execution: Switch spec/loadout and equip gear
-- ============================================================================

function Wise:ExecuteSpecEquip(slotIndex)
    EnsureData()
    local slot = WiseDB.specEquipSlots[slotIndex]
    if not slot then return end

    if InCombatLockdown() then
        print("|cff00ccff[Wise]|r |cffff0000Cannot switch in combat.|r")
        return
    end

    local parts = {}

    -- Spec switch
    if slot.specIndex then
        local currentSpec = GetSpecialization()
        if slot.specIndex ~= currentSpec then
            local setSpecFn = C_SpecializationInfo and C_SpecializationInfo.SetSpecialization or SetSpecialization
            if setSpecFn then
                setSpecFn(slot.specIndex)
            end
            local _, specName = GetSpecializationInfo(slot.specIndex)
            tinsert(parts, specName or ("Spec " .. slot.specIndex))
        end
    end

    -- Talent loadout switch
    if slot.talentConfigID then
        if C_ClassTalents and C_ClassTalents.LoadConfig then
            C_ClassTalents.LoadConfig(slot.talentConfigID, true)
            local configInfo = C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(slot.talentConfigID)
            if configInfo and configInfo.name then
                tinsert(parts, configInfo.name)
            end
        end
    end

    -- Equipment set switch
    if slot.equipmentSetName then
        if C_EquipmentSet then
            local setID = C_EquipmentSet.GetEquipmentSetID(slot.equipmentSetName)
            if setID then
                C_EquipmentSet.UseEquipmentSet(setID)
                tinsert(parts, slot.equipmentSetName .. " gear")
            end
        end
    end

    if #parts > 0 then
        print("|cff00ccff[Wise]|r Switching to " .. table.concat(parts, " + ") .. ".")
    end
end

-- ============================================================================
-- Properties Panel: Chooser for Selected Slot
-- ============================================================================

function Wise:CreateSpecEquipPropertiesPanel(panel, slotIndex, y)
    EnsureData()
    local slot = WiseDB.specEquipSlots[slotIndex]
    if not slot then return y end

    local width = panel:GetWidth() - 20
    local currentSpec = GetSpecialization()
    local isCurrentSpec = (slot.specIndex == nil or slot.specIndex == currentSpec)

    -- Slot Name Editor
    local nameLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetPoint("TOPLEFT", 10, y)
    nameLabel:SetText("Slot Name:")
    tinsert(panel.controls, nameLabel)
    y = y - 20

    local nameEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    nameEdit:SetSize(200, 24)
    nameEdit:SetPoint("TOPLEFT", 15, y)
    nameEdit:SetAutoFocus(false)
    nameEdit:SetText(slot.name or "")
    nameEdit:SetScript("OnEnterPressed", function(self)
        slot.name = self:GetText()
        self:ClearFocus()
        if Wise.UpdateWiserInterfaces then
            Wise:UpdateWiserInterfaces()
        end
    end)
    nameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    tinsert(panel.controls, nameEdit)
    y = y - 30

    -- Delete Slot Button
    local delBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    delBtn:SetSize(140, 24)
    delBtn:SetPoint("TOPLEFT", 10, y)
    delBtn:SetText("Delete Slot")
    local btnText = delBtn:GetFontString()
    if btnText then btnText:SetTextColor(1, 0.2, 0.2) end

    delBtn:SetScript("OnClick", function()
        StaticPopupDialogs["WISE_CONFIRM_DELETE_SE_SLOT"] = {
            text = "Delete '" .. (slot.name or ("Slot " .. slotIndex)) .. "'?",
            button1 = "Delete",
            button2 = "Cancel",
            OnAccept = function()
                table.remove(WiseDB.specEquipSlots, slotIndex)
                Wise.selectedSlot = nil
                Wise.selectedState = nil
                if Wise.UpdateWiserInterfaces then
                    Wise:UpdateWiserInterfaces()
                end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
        }
        StaticPopup_Show("WISE_CONFIRM_DELETE_SE_SLOT")
    end)
    tinsert(panel.controls, delBtn)
    y = y - 35

    -- Separator
    local sep = panel:CreateTexture(nil, "ARTWORK")
    sep:SetSize(width, 1)
    sep:SetPoint("TOPLEFT", 10, y)
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    tinsert(panel.controls, sep)
    y = y - 15

    -- === 1. Specialization Selection ===
    local specLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    specLabel:SetPoint("TOPLEFT", 10, y)
    specLabel:SetText("Specialization (optional):")
    tinsert(panel.controls, specLabel)
    y = y - 20

    local numSpecs = GetNumSpecializations and GetNumSpecializations() or 0

    -- "None" option
    local noneCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    noneCheck:SetPoint("TOPLEFT", 10, y)
    noneCheck:SetChecked(slot.specIndex == nil)
    noneCheck.text = noneCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    noneCheck.text:SetPoint("LEFT", noneCheck, "RIGHT", 5, 0)
    noneCheck.text:SetText("No spec change")
    tinsert(panel.controls, noneCheck)
    tinsert(panel.controls, noneCheck.text)
    y = y - 25

    local specChecks = {noneCheck}

    for i = 1, numSpecs do
        local specID, specName, _, specIcon = GetSpecializationInfo(i)
        if specID and specName then
            local sCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
            sCheck:SetPoint("TOPLEFT", 10, y)
            sCheck:SetChecked(slot.specIndex == i)

            local icon = sCheck:CreateTexture(nil, "ARTWORK")
            icon:SetSize(16, 16)
            icon:SetPoint("LEFT", sCheck, "RIGHT", 5, 0)
            icon:SetTexture(specIcon)

            sCheck.text = sCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            sCheck.text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
            local label = specName
            if i == currentSpec then
                label = label .. " |cff00ff00(current)|r"
            end
            sCheck.text:SetText(label)

            sCheck.specIdx = i
            tinsert(specChecks, sCheck)
            tinsert(panel.controls, sCheck)
            tinsert(panel.controls, icon)
            tinsert(panel.controls, sCheck.text)
            y = y - 25
        end
    end

    -- Radio behavior for spec checks
    for _, check in ipairs(specChecks) do
        check:SetScript("OnClick", function(self)
            for _, other in ipairs(specChecks) do
                other:SetChecked(false)
            end
            self:SetChecked(true)
            slot.specIndex = self.specIdx or nil
            if Wise.UpdateWiserInterfaces then
                Wise:UpdateWiserInterfaces()
            end
        end)
    end

    y = y - 10

    -- === 2. Talent Loadout Selection ===
    local tlLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tlLabel:SetPoint("TOPLEFT", 10, y)
    if isCurrentSpec then
        tlLabel:SetText("Talent Loadout (optional):")
    else
        tlLabel:SetText("Talent Loadout (optional):")
    end
    tinsert(panel.controls, tlLabel)
    y = y - 20

    if not isCurrentSpec then
        -- Show greyed-out message when a different spec is selected
        local _, targetSpecName = GetSpecializationInfo(slot.specIndex)
        local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        note:SetPoint("TOPLEFT", 30, y)
        note:SetWidth(width - 40)
        note:SetJustifyH("LEFT")
        note:SetText("Switch to " .. (targetSpecName or "the selected spec") .. " first to choose a loadout.\nThe loadout picker only shows loadouts for your current spec.")
        tinsert(panel.controls, note)
        local noteHeight = note:GetStringHeight() or 20
        y = y - noteHeight - 10

        -- If a loadout was previously selected, show it greyed out
        if slot.talentConfigID then
            local configInfo = C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(slot.talentConfigID)
            local savedName = configInfo and configInfo.name or ("Config " .. slot.talentConfigID)
            local prev = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            prev:SetPoint("TOPLEFT", 30, y)
            prev:SetText("Previously selected: " .. savedName)
            tinsert(panel.controls, prev)
            y = y - 20

            -- Clear button
            local clearBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
            clearBtn:SetSize(100, 20)
            clearBtn:SetPoint("TOPLEFT", 30, y)
            clearBtn:SetText("Clear")
            clearBtn:SetScript("OnClick", function()
                slot.talentConfigID = nil
                if Wise.UpdateWiserInterfaces then
                    Wise:UpdateWiserInterfaces()
                end
            end)
            tinsert(panel.controls, clearBtn)
            y = y - 25
        end
    else
        -- Current spec — show the loadout picker
        local specIndex = GetSpecialization()
        local specID = specIndex and GetSpecializationInfo(specIndex)
        local savedConfigs = {}
        if specID and C_ClassTalents then
            if C_ClassTalents.GetConfigIDsBySpecID then
                savedConfigs = C_ClassTalents.GetConfigIDsBySpecID(specID) or {}
            end
            if #savedConfigs == 0 and C_ClassTalents.GetConfigIDsByClass then
                local classID = select(3, UnitClass("player"))
                local allConfigs = C_ClassTalents.GetConfigIDsByClass(classID) or {}
                for _, cid in ipairs(allConfigs) do
                    local info = C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(cid)
                    if info and info.name and info.name ~= "" and info.type == (Enum and Enum.TraitConfigType and Enum.TraitConfigType.Combat) then
                        tinsert(savedConfigs, cid)
                    end
                end
            end
        end

        -- "None" option for talent
        local tlNoneCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        tlNoneCheck:SetPoint("TOPLEFT", 10, y)
        tlNoneCheck:SetChecked(slot.talentConfigID == nil)
        tlNoneCheck.text = tlNoneCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tlNoneCheck.text:SetPoint("LEFT", tlNoneCheck, "RIGHT", 5, 0)
        tlNoneCheck.text:SetText("No loadout change")
        tinsert(panel.controls, tlNoneCheck)
        tinsert(panel.controls, tlNoneCheck.text)
        y = y - 25

        local tlChecks = {tlNoneCheck}

        for _, configID in ipairs(savedConfigs) do
            local configInfo = C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(configID)
            if configInfo and configInfo.name and configInfo.name ~= "" then
                local tCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
                tCheck:SetPoint("TOPLEFT", 10, y)
                tCheck:SetChecked(slot.talentConfigID == configID)

                tCheck.text = tCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                tCheck.text:SetPoint("LEFT", tCheck, "RIGHT", 5, 0)
                tCheck.text:SetText(configInfo.name)

                tCheck.configID = configID
                tinsert(tlChecks, tCheck)
                tinsert(panel.controls, tCheck)
                tinsert(panel.controls, tCheck.text)
                y = y - 25
            end
        end

        if #savedConfigs == 0 then
            local noLoadouts = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            noLoadouts:SetPoint("TOPLEFT", 30, y)
            noLoadouts:SetText("No saved loadouts for current spec.")
            tinsert(panel.controls, noLoadouts)
            y = y - 20
        end

        -- Radio behavior for talent checks
        for _, check in ipairs(tlChecks) do
            check:SetScript("OnClick", function(self)
                for _, other in ipairs(tlChecks) do
                    other:SetChecked(false)
                end
                self:SetChecked(true)
                slot.talentConfigID = self.configID or nil
                if Wise.UpdateWiserInterfaces then
                    Wise:UpdateWiserInterfaces()
                end
            end)
        end
    end

    y = y - 10

    -- === 3. Equipment Set Selection ===
    local eqLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    eqLabel:SetPoint("TOPLEFT", 10, y)
    eqLabel:SetText("Equipment Set (optional):")
    tinsert(panel.controls, eqLabel)
    y = y - 20

    -- "None" option for equipment
    local eqNoneCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    eqNoneCheck:SetPoint("TOPLEFT", 10, y)
    eqNoneCheck:SetChecked(slot.equipmentSetName == nil)
    eqNoneCheck.text = eqNoneCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    eqNoneCheck.text:SetPoint("LEFT", eqNoneCheck, "RIGHT", 5, 0)
    eqNoneCheck.text:SetText("No gear change")
    tinsert(panel.controls, eqNoneCheck)
    tinsert(panel.controls, eqNoneCheck.text)
    y = y - 25

    local eqChecks = {eqNoneCheck}

    local setIDs = C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs and C_EquipmentSet.GetEquipmentSetIDs() or {}
    for _, setID in ipairs(setIDs) do
        local name, setIcon = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if name then
            local eCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
            eCheck:SetPoint("TOPLEFT", 10, y)
            eCheck:SetChecked(slot.equipmentSetName == name)

            if setIcon then
                local icon = eCheck:CreateTexture(nil, "ARTWORK")
                icon:SetSize(16, 16)
                icon:SetPoint("LEFT", eCheck, "RIGHT", 5, 0)
                icon:SetTexture(setIcon)

                eCheck.text = eCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                eCheck.text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
                eCheck.text:SetText(name)
                tinsert(panel.controls, icon)
            else
                eCheck.text = eCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                eCheck.text:SetPoint("LEFT", eCheck, "RIGHT", 5, 0)
                eCheck.text:SetText(name)
            end

            eCheck.setName = name
            eCheck.setIcon = setIcon
            tinsert(eqChecks, eCheck)
            tinsert(panel.controls, eCheck)
            tinsert(panel.controls, eCheck.text)
            y = y - 25
        end
    end

    if #setIDs == 0 then
        local noSets = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noSets:SetPoint("TOPLEFT", 30, y)
        noSets:SetText("No saved equipment sets.")
        tinsert(panel.controls, noSets)
        y = y - 20
    end

    -- Radio behavior for equipment checks
    for _, check in ipairs(eqChecks) do
        check:SetScript("OnClick", function(self)
            for _, other in ipairs(eqChecks) do
                other:SetChecked(false)
            end
            self:SetChecked(true)
            slot.equipmentSetName = self.setName or nil
            if self.setIcon then
                slot.icon = self.setIcon
            end
            if Wise.UpdateWiserInterfaces then
                Wise:UpdateWiserInterfaces()
            end
        end)
    end

    y = y - 10
    return y
end

-- ============================================================================
-- Hook RefreshActionsView to customize Add Slot for Spec and Equipment Changer
-- ============================================================================

local origRefreshActionsView = Wise.RefreshActionsView
function Wise:RefreshActionsView(container)
    -- Call the original first
    if origRefreshActionsView then
        origRefreshActionsView(self, container)
    end

    local isSE = (Wise.selectedGroup == "Spec and Equipment Changer")

    -- Hide filter buttons when viewing this interface
    if Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.FilterButtons then
        for _, btn in pairs(Wise.OptionsFrame.Middle.FilterButtons) do
            if isSE then
                btn:Hide()
            elseif Wise.currentTab == "Editor" then
                btn:Show()
            end
        end
    end

    if isSE then
        local addSlotBtn = Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.AddSlotBtn
        if addSlotBtn then
            addSlotBtn:Enable()
            addSlotBtn:SetScript("OnClick", function()
                EnsureData()
                local nextSlot = #WiseDB.specEquipSlots + 1
                WiseDB.specEquipSlots[nextSlot] = {
                    name = "Slot " .. nextSlot,
                    specIndex = nil,
                    talentConfigID = nil,
                    equipmentSetName = nil,
                    icon = nil,
                }
                if Wise.UpdateWiserInterfaces then
                    Wise:UpdateWiserInterfaces()
                end
            end)
        end
    end
end

-- ============================================================================
-- Hook UpdateBindings to sync keybinds back to persistent storage
-- ============================================================================

local origUpdateBindings = Wise.UpdateBindings
function Wise:UpdateBindings()
    -- Call the original binding logic
    if origUpdateBindings then
        origUpdateBindings(self)
    end

    -- Sync keybinds from group.actions back to WiseDB.specEquipSlots
    EnsureData()
    local group = WiseDB.groups["Spec and Equipment Changer"]
    if group and group.actions and WiseDB.specEquipSlots then
        for i, slot in ipairs(WiseDB.specEquipSlots) do
            if group.actions[i] then
                slot.keybind = group.actions[i].keybind or nil
            end
        end
    end
end
