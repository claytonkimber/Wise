local addonName, Wise = ...

local tinsert = table.insert

-- Tool template name (appears in sidebar Tools section)
Wise.ADDON_MAGIC_TEMPLATE = "Addon Magic"

-- ============================================================================
-- Data Initialization
-- ============================================================================

-- Addon Magic stores its slots in WiseDB.addonMagicSlots
-- Each slot: { addons = {"AddonName1", "AddonName2"}, name = "My Bundle" }
local function EnsureData()
    if not WiseDB then return end
    WiseDB.addonMagicSlots = WiseDB.addonMagicSlots or {}
end

-- ============================================================================
-- Execution: Enable addons and reload
-- ============================================================================

function Wise:ExecuteAddonMagic(slotIndex)
    EnsureData()
    local slot = WiseDB.addonMagicSlots[slotIndex]
    if not slot or not slot.addons or #slot.addons == 0 then return end

    local addonsToDisable = {}
    local playerChar = UnitName("player")

    for _, addon in ipairs(slot.addons) do
        addon = strtrim(addon)
        if addon ~= "" then
            -- Only track it to be disabled if it was currently disabled
            local enableState = C_AddOns.GetAddOnEnableState(playerChar, addon)
            if enableState == 0 then
                tinsert(addonsToDisable, addon)
            end
            C_AddOns.EnableAddOn(addon)
        end
    end

    if #addonsToDisable > 0 then
        WiseDB.addonsToDisable = addonsToDisable
    end
    ReloadUI()
end

-- Login hook: disable previously magic-loaded addons
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event)
    if WiseDB and WiseDB.addonsToDisable then
        for _, addon in ipairs(WiseDB.addonsToDisable) do
            C_AddOns.DisableAddOn(addon)
        end
        WiseDB.addonsToDisable = nil
    end
end)

-- ============================================================================
-- Middle Panel: Addon Magic Slots View
-- ============================================================================

function Wise:RefreshAddonMagicSlotsView(container)
    EnsureData()

    -- Cleanup
    if container.amSlots then
        for _, frame in ipairs(container.amSlots) do frame:Hide() end
    end
    if container.emptyLabel then container.emptyLabel:Hide() end
    container.amSlots = container.amSlots or {}

    -- Update AddSlotBtn
    local addSlotBtn = Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.AddSlotBtn
    if addSlotBtn then
        addSlotBtn:Enable()
        addSlotBtn:SetScript("OnClick", function()
            EnsureData()
            local nextSlot = #WiseDB.addonMagicSlots + 1
            WiseDB.addonMagicSlots[nextSlot] = { addons = {}, name = "Slot " .. nextSlot }
            Wise.selectedAMSlot = nextSlot
            Wise:RefreshAddonMagicSlotsView(container)
            Wise:RefreshPropertiesPanel()
        end)
    end

    local slots = WiseDB.addonMagicSlots
    if not slots or #slots == 0 then
        if not container.emptyLabel then
            container.emptyLabel = container:CreateFontString(nil, "OVERLAY", "GameFontDisable")
            container.emptyLabel:SetText("No addon slots defined.\nClick 'Add New Slot' to create one.")
        end
        container.emptyLabel:ClearAllPoints()
        container.emptyLabel:SetPoint("TOP", 0, -10)
        container.emptyLabel:Show()
        return
    end

    local y = -10

    for sIdx, slot in ipairs(slots) do
        local slotFrame = container.amSlots[sIdx]
        if not slotFrame then
            slotFrame = CreateFrame("Button", nil, container, "BackdropTemplate")
            slotFrame:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 12,
                insets = { left = 2, right = 2, top = 2, bottom = 2 }
            })
            slotFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
            slotFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            slotFrame:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

            slotFrame.icon = slotFrame:CreateTexture(nil, "ARTWORK")
            slotFrame.icon:SetSize(28, 28)
            slotFrame.icon:SetPoint("LEFT", 5, 0)

            slotFrame.label = slotFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            slotFrame.label:SetPoint("LEFT", slotFrame.icon, "RIGHT", 8, 6)
            slotFrame.label:SetJustifyH("LEFT")
            slotFrame.label:SetWidth(170)
            slotFrame.label:SetWordWrap(false)

            slotFrame.subLabel = slotFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            slotFrame.subLabel:SetPoint("TOPLEFT", slotFrame.label, "BOTTOMLEFT", 0, -2)
            slotFrame.subLabel:SetJustifyH("LEFT")
            slotFrame.subLabel:SetWidth(170)
            slotFrame.subLabel:SetWordWrap(false)

            -- Delete button
            slotFrame.deleteBtn = CreateFrame("Button", nil, slotFrame, "UIPanelCloseButton")
            slotFrame.deleteBtn:SetSize(20, 20)
            slotFrame.deleteBtn:SetPoint("TOPRIGHT", -2, -2)

            tinsert(container.amSlots, slotFrame)
        end

        slotFrame:Show()
        slotFrame:SetSize(240, 44)
        slotFrame:SetPoint("TOPLEFT", 5, y)
        slotFrame.slotID = sIdx

        slotFrame.icon:SetTexture("Interface\\Icons\\INV_Misc_EngGizmos_11")
        slotFrame.label:SetText(slot.name or ("Slot " .. sIdx))

        local addonCount = slot.addons and #slot.addons or 0
        if addonCount == 0 then
            slotFrame.subLabel:SetText("|cff888888No addons selected|r")
        elseif addonCount == 1 then
            slotFrame.subLabel:SetText("|cffaaaaaa" .. slot.addons[1] .. "|r")
        else
            slotFrame.subLabel:SetText("|cffaaaaaa" .. addonCount .. " addons|r")
        end

        -- Selection highlight
        if Wise.selectedAMSlot == sIdx then
            slotFrame:LockHighlight()
            slotFrame:SetBackdropBorderColor(1, 0.82, 0, 1)
        else
            slotFrame:UnlockHighlight()
            slotFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        end

        slotFrame:SetScript("OnClick", function()
            Wise.selectedAMSlot = sIdx
            Wise:RefreshAddonMagicSlotsView(container)
            Wise:RefreshPropertiesPanel()
        end)

        slotFrame.deleteBtn:SetScript("OnClick", function()
            table.remove(WiseDB.addonMagicSlots, sIdx)
            if Wise.selectedAMSlot == sIdx then
                Wise.selectedAMSlot = nil
            elseif Wise.selectedAMSlot and Wise.selectedAMSlot > sIdx then
                Wise.selectedAMSlot = Wise.selectedAMSlot - 1
            end
            Wise:RefreshAddonMagicSlotsView(container)
            Wise:RefreshPropertiesPanel()
        end)

        slotFrame:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(slot.name or ("Slot " .. sIdx), 1, 1, 1)
            if slot.addons and #slot.addons > 0 then
                for _, a in ipairs(slot.addons) do
                    local _, title = C_AddOns.GetAddOnInfo(a)
                    GameTooltip:AddLine((title or a), 0.8, 0.8, 0.8)
                end
            else
                GameTooltip:AddLine("No addons selected", 0.5, 0.5, 0.5)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click to select, then configure in Properties.", 0, 1, 0, true)
            GameTooltip:Show()
        end)
        slotFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

        y = y - 48
    end

    container:SetHeight(math.abs(y) + 20)
end

-- ============================================================================
-- Properties Panel: Addon Picker for Selected Slot
-- ============================================================================

function Wise:CreateAddonMagicPropertiesPanel(panel, slotIndex, y)
    EnsureData()
    local slot = WiseDB.addonMagicSlots[slotIndex]
    if not slot then return y end

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
        if Wise.OptionsFrame and Wise.OptionsFrame.Middle then
            Wise:RefreshAddonMagicSlotsView(Wise.OptionsFrame.Middle.Content)
        end
    end)
    nameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    tinsert(panel.controls, nameEdit)
    y = y - 30

    -- Keybind UI
    local kbLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    kbLabel:SetPoint("TOPLEFT", 10, y)
    kbLabel:SetText("Keybind (Right Click to Clear):")
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

            local function FinishSlotBinding(key)
                if not key then return end

                if key == "ESCAPE" then
                    self:EnableKeyboard(false)
                    self:SetScript("OnKeyDown", nil)
                    self:SetScript("OnMouseDown", nil)
                    self:SetText(slot.keybind or "None")
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
                self:SetScript("OnMouseDown", nil)

                -- Check conflicts
                if Wise:CheckBindingConflict(fullKey, nil, "addon_magic_"..slotIndex, false, self) then
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

            self:SetScript("OnMouseDown", function(self, button)
                local key = button
                if key == "LeftButton" then key = "BUTTON1"
                elseif key == "RightButton" then key = "BUTTON2"
                elseif key == "MiddleButton" then key = "BUTTON3"
                else
                    local num = key:match("Button(%d+)")
                    if num then key = "BUTTON" .. num end
                end
                FinishSlotBinding(key)
            end)
        end
    end)
    tinsert(panel.controls, bindBtn)
    y = y - 35

    -- Execute Button
    local execBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
    execBtn:SetSize(200, 28)
    execBtn:SetPoint("TOPLEFT", 10, y)
    execBtn:SetText("Load Addons & Reload")
    tinsert(panel.controls, execBtn)

    local addonCount = slot.addons and #slot.addons or 0
    if addonCount == 0 then
        execBtn:Disable()
    end

    execBtn:SetScript("OnClick", function()
        Wise:ExecuteAddonMagic(slotIndex)
    end)
    y = y - 35

    -- Separator
    local sep = panel:CreateTexture(nil, "ARTWORK")
    sep:SetSize(200, 1)
    sep:SetPoint("TOPLEFT", 10, y)
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    tinsert(panel.controls, sep)
    y = y - 10

    -- Addon Selection
    local alabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    alabel:SetPoint("TOPLEFT", 10, y)
    alabel:SetText("Select Addons to Load:")
    tinsert(panel.controls, alabel)
    y = y - 20

    slot.addons = slot.addons or {}
    local selectedMap = {}
    for _, v in ipairs(slot.addons) do selectedMap[v] = true end

    local numAddons = C_AddOns.GetNumAddOns()
    for i = 1, numAddons do
        local name, title = C_AddOns.GetAddOnInfo(i)
        -- Skip Blizzard default addons and Wise itself
        if not name:match("^Blizzard_") and name ~= "Wise" then
            local aCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
            aCheck:SetPoint("TOPLEFT", 10, y)
            aCheck:SetChecked(selectedMap[name] or false)
            aCheck.text = aCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            aCheck.text:SetPoint("LEFT", aCheck, "RIGHT", 5, 0)
            aCheck.text:SetText(title or name)

            aCheck.addonName = name
            aCheck:SetScript("OnClick", function(self)
                local isChecked = self:GetChecked()
                local newAddons = {}
                for _, existing in ipairs(slot.addons) do
                    if existing ~= self.addonName then
                        tinsert(newAddons, existing)
                    end
                end
                if isChecked then
                    tinsert(newAddons, self.addonName)
                end
                slot.addons = newAddons

                -- Refresh slots view to update counts
                if Wise.OptionsFrame and Wise.OptionsFrame.Middle then
                    Wise:RefreshAddonMagicSlotsView(Wise.OptionsFrame.Middle.Content)
                end
            end)

            tinsert(panel.controls, aCheck)
            tinsert(panel.controls, aCheck.text)
            y = y - 25
        end
    end

    y = y - 10
    return y
end

-- ============================================================================
-- Hook RefreshActionsView to show Addon Magic slots
-- ============================================================================

local origRefreshActionsView = Wise.RefreshActionsView
function Wise:RefreshActionsView(container)
    -- Clean up addon magic slots when switching away
    if container.amSlots then
        for _, frame in ipairs(container.amSlots) do frame:Hide() end
    end

    -- Hide/show filter buttons based on whether a tool is selected
    local isToolSelected = (Wise.selectedGroup == Wise.ADDON_MAGIC_TEMPLATE)
    if Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.FilterButtons then
        for _, btn in pairs(Wise.OptionsFrame.Middle.FilterButtons) do
            if isToolSelected then
                btn:Hide()
            elseif Wise.currentTab == "Editor" then
                btn:Show()
            end
        end
    end

    if isToolSelected then
        -- Hide normal slots
        if container.slots then
            for _, slot in ipairs(container.slots) do slot:Hide() end
        end
        if container.emptyLabel then container.emptyLabel:Hide() end

        Wise:RefreshAddonMagicSlotsView(container)
        return
    end

    if origRefreshActionsView then
        origRefreshActionsView(self, container)
    end
end
