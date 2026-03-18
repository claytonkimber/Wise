local addonName, Wise = ...

local tinsert = table.insert

Wise.SPEC_AND_EQUIP_TEMPLATE = "Spec and Equipment Changer"

function Wise:CreateSpecAndEquipPropertiesPanel(panel, startY)
    local y = startY or -10
    local width = panel:GetWidth() - 20

    -- Description
    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", 10, y)
    desc:SetWidth(width)
    desc:SetJustifyH("LEFT")
    desc:SetText("Quickly switch your Talent Loadout and Equipment Set simultaneously.\nNote: You must be out of combat.")
    tinsert(panel.controls, desc)

    y = y - 50

    -- State tracking for dropdowns
    panel.selectedTalentConfigID = panel.selectedTalentConfigID or nil
    panel.selectedTalentName = panel.selectedTalentName or "Select Talent Loadout..."

    panel.selectedEquipmentSetID = panel.selectedEquipmentSetID or nil
    panel.selectedEquipmentName = panel.selectedEquipmentName or "Select Equipment Set..."

    -- === 1. Talent Loadout Selection ===
    local talentLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    talentLabel:SetPoint("TOPLEFT", 10, y)
    talentLabel:SetText("1. Select Talent Loadout:")
    tinsert(panel.controls, talentLabel)

    y = y - 20

    local talentBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    talentBtn:SetSize(width, 24)
    talentBtn:SetPoint("TOPLEFT", 10, y)
    talentBtn:SetText(panel.selectedTalentName)
    tinsert(panel.controls, talentBtn)

    talentBtn:SetScript("OnClick", function(self)
        if self.dropdown and self.dropdown:IsShown() then
            self.dropdown:Hide()
            return
        end

        if not self.dropdown then
            local d = CreateFrame("Frame", nil, self, "BackdropTemplate")
            self.dropdown = d

            d:SetSize(width, 200)
            d:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
            d:SetFrameStrata("DIALOG")
            d:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 16,
                insets = { left = 5, right = 5, top = 5, bottom = 5 }
            })

            local scroll = CreateFrame("ScrollFrame", nil, d, "UIPanelScrollFrameTemplate")
            scroll:SetPoint("TOPLEFT", 8, -8)
            scroll:SetPoint("BOTTOMRIGHT", -28, 8)

            local content = CreateFrame("Frame", nil, scroll)
            content:SetSize(width-40, 400)
            scroll:SetScrollChild(content)

            -- Populate Talent Loadouts
            local configIDs = C_ClassTalents and C_ClassTalents.GetConfigIDsByClass and C_ClassTalents.GetConfigIDsByClass(select(3, UnitClass("player"))) or {}
            local innerY = 0

            for _, configID in ipairs(configIDs) do
                local configInfo = C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(configID)
                if configInfo and configInfo.name then
                    local b = CreateFrame("Button", nil, content)
                    b:SetSize(width-40, 20)
                    b:SetPoint("TOPLEFT", 0, -innerY)
                    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

                    local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    t:SetPoint("LEFT", 5, 0)
                    t:SetText(configInfo.name)

                    b:SetScript("OnClick", function()
                        panel.selectedTalentConfigID = configID
                        panel.selectedTalentName = configInfo.name
                        self:SetText(configInfo.name)
                        d:Hide()
                    end)

                    innerY = innerY + 20
                end
            end

            if innerY == 0 then
                local t = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                t:SetPoint("TOPLEFT", 5, 0)
                t:SetText("No saved loadouts found.")
                innerY = 20
            end

            content:SetHeight(innerY)
        end
        self.dropdown:Show()
    end)

    y = y - 40

    -- === 2. Equipment Set Selection ===
    local equipLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    equipLabel:SetPoint("TOPLEFT", 10, y)
    equipLabel:SetText("2. Select Equipment Set:")
    tinsert(panel.controls, equipLabel)

    y = y - 20

    local equipBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    equipBtn:SetSize(width, 24)
    equipBtn:SetPoint("TOPLEFT", 10, y)
    equipBtn:SetText(panel.selectedEquipmentName)
    tinsert(panel.controls, equipBtn)

    equipBtn:SetScript("OnClick", function(self)
        if self.dropdown and self.dropdown:IsShown() then
            self.dropdown:Hide()
            return
        end

        if not self.dropdown then
            local d = CreateFrame("Frame", nil, self, "BackdropTemplate")
            self.dropdown = d

            d:SetSize(width, 200)
            d:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
            d:SetFrameStrata("DIALOG")
            d:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 16,
                insets = { left = 5, right = 5, top = 5, bottom = 5 }
            })

            local scroll = CreateFrame("ScrollFrame", nil, d, "UIPanelScrollFrameTemplate")
            scroll:SetPoint("TOPLEFT", 8, -8)
            scroll:SetPoint("BOTTOMRIGHT", -28, 8)

            local content = CreateFrame("Frame", nil, scroll)
            content:SetSize(width-40, 400)
            scroll:SetScrollChild(content)

            -- Populate Equipment Sets
            local setIDs = C_EquipmentManager and C_EquipmentManager.GetEquipmentSetIDs and C_EquipmentManager.GetEquipmentSetIDs() or {}
            local innerY = 0

            for _, setID in ipairs(setIDs) do
                local name = C_EquipmentManager and C_EquipmentManager.GetEquipmentSetInfo and C_EquipmentManager.GetEquipmentSetInfo(setID)
                if name then
                    local b = CreateFrame("Button", nil, content)
                    b:SetSize(width-40, 20)
                    b:SetPoint("TOPLEFT", 0, -innerY)
                    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

                    local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    t:SetPoint("LEFT", 5, 0)
                    t:SetText(name)

                    b:SetScript("OnClick", function()
                        panel.selectedEquipmentSetID = setID
                        panel.selectedEquipmentName = name
                        self:SetText(name)
                        d:Hide()
                    end)

                    innerY = innerY + 20
                end
            end

            if innerY == 0 then
                local t = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                t:SetPoint("TOPLEFT", 5, 0)
                t:SetText("No saved equipment sets found.")
                innerY = 20
            end

            content:SetHeight(innerY)
        end
        self.dropdown:Show()
    end)

    y = y - 40

    -- === 3. Execute Switch Action ===
    local switchBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
    switchBtn:SetSize(140, 30)
    switchBtn:SetPoint("TOPLEFT", 10, y)
    switchBtn:SetText("Switch")
    tinsert(panel.controls, switchBtn)

    local statusText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("LEFT", switchBtn, "RIGHT", 10, 0)
    statusText:SetText("")
    tinsert(panel.controls, statusText)

    switchBtn:SetScript("OnClick", function()
        if InCombatLockdown() then
            statusText:SetText("|cffff0000Cannot swap in combat|r")
            return
        end

        if not panel.selectedTalentConfigID then
            statusText:SetText("|cffff0000Select Talent Loadout|r")
            return
        end

        if not panel.selectedEquipmentSetID then
            statusText:SetText("|cffff0000Select Equipment Set|r")
            return
        end

        -- Execute Swap
        local talentSuccess = nil
        if C_ClassTalents and C_ClassTalents.LoadConfig then
            talentSuccess = C_ClassTalents.LoadConfig(panel.selectedTalentConfigID, true)
        end

        -- If talent load logic is missing, fallback to success so gear swaps
        if talentSuccess == nil or (Enum and Enum.TraitConfigCommitError and talentSuccess == Enum.TraitConfigCommitError.None) or talentSuccess == true then
             if C_EquipmentManager and C_EquipmentManager.UseEquipmentSet then
                 C_EquipmentManager.UseEquipmentSet(panel.selectedEquipmentSetID)
             end
             local msg = string.format("Switching to %s with %s gear.", panel.selectedTalentName, panel.selectedEquipmentName)
             print("|cff00ccff[Wise]|r " .. msg)
             statusText:SetText("|cff00ff00" .. msg .. "|r")
        else
             statusText:SetText("|cffff0000Failed to load talent config|r")
        end
    end)

    panel:SetHeight(math.abs(y) + 50)
    return y
end
