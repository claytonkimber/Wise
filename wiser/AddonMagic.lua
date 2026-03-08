local addonName, Wise = ...

local tinsert = table.insert

-- Template name (used as key for the Wiser interface)
Wise.ADDON_MAGIC_TEMPLATE = "Addon Loading Magic"

-- ============================================================================
-- Data Initialization
-- ============================================================================

-- Addon Loading Magic stores its slots in WiseDB.addonMagicSlots
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

    local allLoaded = true
    for _, addon in ipairs(slot.addons) do
        addon = strtrim(addon)
        if addon ~= "" and not C_AddOns.IsAddOnLoaded(addon) then
            allLoaded = false
            break
        end
    end

    if allLoaded then
        ReloadUI()
        return
    end

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
-- Properties Panel: Addon Picker for Selected Slot (addon_magic action)
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
        -- Rebuild the Wiser group so button names update
        if Wise.UpdateWiserInterfaces then
            Wise:UpdateWiserInterfaces()
        end
    end)
    nameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    tinsert(panel.controls, nameEdit)
    y = y - 30

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

    -- Delete Slot Button
    local delBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    delBtn:SetSize(140, 24)
    delBtn:SetPoint("TOPLEFT", 10, y)
    delBtn:SetText("Delete Slot")
    local btnText = delBtn:GetFontString()
    if btnText then btnText:SetTextColor(1, 0.2, 0.2) end

    delBtn:SetScript("OnClick", function()
        StaticPopupDialogs["WISE_CONFIRM_DELETE_AM_SLOT"] = {
            text = "Delete '" .. (slot.name or ("Slot " .. slotIndex)) .. "' and its addon selections?",
            button1 = "Delete",
            button2 = "Cancel",
            OnAccept = function()
                table.remove(WiseDB.addonMagicSlots, slotIndex)
                Wise.selectedSlot = nil
                Wise.selectedState = nil
                -- Rebuild the Wiser group
                if Wise.UpdateWiserInterfaces then
                    Wise:UpdateWiserInterfaces()
                end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
        }
        StaticPopup_Show("WISE_CONFIRM_DELETE_AM_SLOT")
    end)
    tinsert(panel.controls, delBtn)
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

                -- Rebuild the Wiser group to update sub-text/counts
                if Wise.UpdateWiserInterfaces then
                    Wise:UpdateWiserInterfaces()
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
-- Hook RefreshActionsView to customize Add Slot for Addon Loading Magic
-- ============================================================================

local origRefreshActionsView = Wise.RefreshActionsView
function Wise:RefreshActionsView(container)
    -- Call the original first
    if origRefreshActionsView then
        origRefreshActionsView(self, container)
    end

    -- If Addon Loading Magic is selected, override the Add Slot button behavior
    local isAM = (Wise.selectedGroup == Wise.ADDON_MAGIC_TEMPLATE)

    -- Hide/show filter buttons
    if Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.FilterButtons then
        for _, btn in pairs(Wise.OptionsFrame.Middle.FilterButtons) do
            if isAM then
                btn:Hide()
            elseif Wise.currentTab == "Editor" then
                btn:Show()
            end
        end
    end

    if isAM then
        local addSlotBtn = Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.AddSlotBtn
        if addSlotBtn then
            addSlotBtn:Enable()
            addSlotBtn:SetScript("OnClick", function()
                EnsureData()
                local nextSlot = #WiseDB.addonMagicSlots + 1
                WiseDB.addonMagicSlots[nextSlot] = { addons = {}, name = "Slot " .. nextSlot }
                -- Rebuild the Wiser group to pick up the new slot
                if Wise.UpdateWiserInterfaces then
                    Wise:UpdateWiserInterfaces()
                end
            end)
        end
    end
end

-- ============================================================================
-- Hook UpdateBindings to sync AM keybinds back to persistent storage
-- ============================================================================

local origUpdateBindings = Wise.UpdateBindings
function Wise:UpdateBindings()
    -- Call the original binding logic
    if origUpdateBindings then
        origUpdateBindings(self)
    end

    -- Sync AM slot keybinds from group.actions back to WiseDB.addonMagicSlots
    EnsureData()
    local group = WiseDB.groups[Wise.ADDON_MAGIC_TEMPLATE]
    if group and group.actions and WiseDB.addonMagicSlots then
        for i, slot in ipairs(WiseDB.addonMagicSlots) do
            if group.actions[i] then
                slot.keybind = group.actions[i].keybind or nil
            end
        end
    end
end
