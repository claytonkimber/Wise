local addonName, Wise = ...

-- Constants
local NUM_ACTION_BARS = 13
local SLOTS_PER_BAR = 12
local tinsert = table.insert

Wise.BAR_COPY_TEMPLATE = "Bar Copy Tool"

-- UI Constants
local PADDING = 10
local GAP = 20

-- Special Bar Configurations
-- Maps UI Button Index (9-13) to specific Action Bar Pages (7-11/12)
Wise.SpecialBars = {
    [9] = { name = "Druid Forms / Rogue Stealth", condition = "[bonusbar:1][bonusbar:3]", page = 7 }, -- Page 7 (73-84)
    [10] = { name = "Class Stances / Overrides", condition = "[bonusbar:2][bonusbar:4]", page = 9 }, -- Page 9 (97-108) (Bear Form commonly)
    [11] = { name = "Override Bar", condition = "[overridebar]", page = 12 }, -- Page 12 (133-144) (Often Override)
    [12] = { name = "Possess Bar", condition = "[possessbar]", page = 13 }, -- Page 13 (145-156) (Often Possess)
    [13] = { name = "Dragonriding / Skyriding", condition = "[bonusbar:5][advflyable][flying]", page = 11 }, -- Page 11 (121-132) (Skyriding)
    [14] = { name = "Cooldown Manager Bar", isAddon = true, viewerName = "EssentialCooldownViewer" },
    [15] = { name = "Utilities Bar", isAddon = true, viewerName = "UtilityCooldownViewer" },
}

function Wise:CreateBarCopyPropertiesPanel(panel, startY)
    local y = startY or -10
    local width = panel:GetWidth() - 20

    -- Description
    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", 10, y)
    desc:SetWidth(width)
    desc:SetJustifyH("LEFT")
    desc:SetText("Copy actions from a Blizzard Action Bar to a Wise Interface.\n\nActions will be APPENDED to the target interface.")
    tinsert(panel.controls, desc)

    y = y - 60

    -- === Source Selection ===
    local sourceLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sourceLabel:SetPoint("TOPLEFT", 10, y)
    sourceLabel:SetText("1. Select Source Bar:")
    tinsert(panel.controls, sourceLabel)

    y = y - 20

    -- Source Buttons Grid (1-8)
    panel.SourceButtons = panel.SourceButtons or {}
    local btnSize = 24
    local btnGap = 4

    for i = 1, 8 do
        local btn = panel.SourceButtons[i]
        if not btn then
            btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
            btn:SetSize(btnSize, btnSize)
            btn:SetText(tostring(i))

            btn:SetScript("OnClick", function()
                panel.selectedSource = i
                if panel.ConditionEdit then
                    panel.ConditionEdit:SetText("")
                end
                Wise:UpdateBarCopyUI(panel)
            end)

            tinsert(panel.SourceButtons, btn)
            tinsert(panel.controls, btn)
        end

        btn:Show()
        btn:SetPoint("TOPLEFT", 10 + ((i-1)*(btnSize+btnGap)), y)
    end

    y = y - 40

    -- Special Bars List (9-13)
    local specLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    specLabel:SetPoint("TOPLEFT", 10, y)
    specLabel:SetText("Special Bars:")
    tinsert(panel.controls, specLabel)

    y = y - 20

    for i = 9, 15 do
        local btn = panel.SourceButtons[i]
        if not btn then
            btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")

            btn:SetScript("OnClick", function()
                panel.selectedSource = i
                if panel.ConditionEdit then
                    local cond = (Wise.SpecialBars[i] and Wise.SpecialBars[i].condition) or ""
                    panel.ConditionEdit:SetText(cond)
                end
                Wise:UpdateBarCopyUI(panel)
            end)

            tinsert(panel.SourceButtons, btn)
            tinsert(panel.controls, btn)
        end

        local info = Wise.SpecialBars[i]
        btn:Show()
        btn:SetSize(width, 24)
        btn:SetPoint("TOPLEFT", 10, y)

        -- Custom label for left alignment
        if not btn.specialLabel then
             btn.specialLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
             btn.specialLabel:SetPoint("LEFT", 10, 0)
        end
        if info and info.isAddon then
            btn.specialLabel:SetText(info.name or "Unknown")
        else
            btn.specialLabel:SetText("Bar " .. i .. ": " .. (info and info.name or "Unknown"))
        end
        btn:SetText("") -- Clear default center text

        y = y - 28
    end

    y = y - 20

    -- === Target Selection ===
    local targetLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    targetLabel:SetPoint("TOPLEFT", 10, y)
    targetLabel:SetText("2. Select Target Interface:")
    tinsert(panel.controls, targetLabel)

    y = y - 20

    -- Target Dropdown (Simple scrollable list or dropdown)
    -- Since we are in the properties panel which is narrow, a dropdown button is better.

    local targetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    targetBtn:SetSize(width, 24)
    targetBtn:SetPoint("TOPLEFT", 10, y)
    targetBtn:SetText(panel.selectedTarget or "Select Interface...")
    tinsert(panel.controls, targetBtn)

    targetBtn:SetScript("OnClick", function(self)
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
            content:SetSize(width-40, 400) -- Dynamic height
            scroll:SetScrollChild(content)

            -- Populate
            local groups = {}
            if WiseDB and WiseDB.groups then
                for name, data in pairs(WiseDB.groups) do
                    if not data.isWiser then
                        table.insert(groups, name)
                    end
                end
            end
            table.sort(groups)

            local innerY = 0
            for _, name in ipairs(groups) do
                local b = CreateFrame("Button", nil, content)
                b:SetSize(width-40, 20)
                b:SetPoint("TOPLEFT", 0, -innerY)
                b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

                local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                t:SetPoint("LEFT", 5, 0)
                t:SetText(name)

                b:SetScript("OnClick", function()
                    panel.selectedTarget = name
                    self:SetText(name)
                    d:Hide()
                    Wise:UpdateBarCopyUI(panel)
                end)

                innerY = innerY + 20
            end
            content:SetHeight(innerY)
        end
        self.dropdown:Show()
    end)

    y = y - 40

    -- === Visibility Conditional ===
    local condLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    condLabel:SetPoint("TOPLEFT", 10, y)
    condLabel:SetText("3. Visibility Condition (Optional):")
    tinsert(panel.controls, condLabel)

    y = y - 20

    local condEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    condEdit:SetSize(width, 24)
    condEdit:SetPoint("TOPLEFT", 15, y)
    condEdit:SetAutoFocus(false)
    panel.ConditionEdit = condEdit
    tinsert(panel.controls, condEdit)

    y = y - 40

    -- === Execute Button ===
    local copyBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
    copyBtn:SetSize(140, 30)
    copyBtn:SetPoint("TOPLEFT", 10, y)
    copyBtn:SetText("Copy & Append")
    tinsert(panel.controls, copyBtn)

    local statusText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("LEFT", copyBtn, "RIGHT", 10, 0)
    statusText:SetText("")
    tinsert(panel.controls, statusText)

    copyBtn:SetScript("OnClick", function()
        if not panel.selectedSource then
            statusText:SetText("|cffff0000Select Source|r")
            return
        end
        if not panel.selectedTarget then
            statusText:SetText("|cffff0000Select Target|r")
            return
        end

        local customCond = panel.ConditionEdit:GetText()
        local count = Wise:CopyBar(panel.selectedSource, panel.selectedTarget, customCond)
        statusText:SetText("|cff00ff00Added " .. count .. " actions.|r")

        -- If user is viewing the target interface in the middle panel, refresh it?
        -- But currently they are viewing the Bar Copy tool.
    end)

    Wise:UpdateBarCopyUI(panel)

    panel:SetHeight(math.abs(y) + 50)
    return y
end

function Wise:UpdateBarCopyUI(panel)
    if not panel.SourceButtons then return end

    for i, btn in ipairs(panel.SourceButtons) do
        if panel.selectedSource == i then
            btn:LockHighlight()
            -- Optionally tint
        else
            btn:UnlockHighlight()
        end
    end
end

function Wise:CopyBar(barIndex, targetGroupName, customCondition)
    if not barIndex or not targetGroupName then return 0 end
    local group = WiseDB.groups[targetGroupName]
    if not group then return 0 end

    -- Determine slot range
    -- Check for special page mapping first
    local page = barIndex
    local special = Wise.SpecialBars[barIndex]
    
    if special and special.isAddon then
        return Wise:CopyFromViewer(barIndex, special.viewerName, targetGroupName, customCondition)
    end

    if special and special.page then
        page = special.page
    end

    local startSlot = (page - 1) * SLOTS_PER_BAR + 1
    local endSlot = startSlot + SLOTS_PER_BAR - 1

    -- Determine conditionals (Use custom if provided, otherwise default to special bar logic)
    local condition = customCondition
    if condition == nil and special then
        condition = special.condition
    end

    local extraData = nil
    if condition and condition ~= "" then
         extraData = { conditions = condition }
    end

    local copiedCount = 0

    Wise:MigrateGroupToActions(group)

    for i = 0, (SLOTS_PER_BAR - 1) do
        local barSlot = startSlot + i
        local targetSlot = i + 1 -- Target slots 1-12 directly

        local actionType, id, subType = GetActionInfo(barSlot)
        local wiseType = nil
        local wiseValue = nil

        -- Clone extraData for each action (if we modify it)
        local thisExtra = nil
        if extraData then
            thisExtra = {}
            for k,v in pairs(extraData) do thisExtra[k] = v end
        end

        if actionType and id then
            if actionType == "spell" then
                wiseType = "spell"
                wiseValue = id -- spellID

            elseif actionType == "item" then
                wiseType = "item"
                wiseValue = id -- itemID

            elseif actionType == "macro" then
                wiseType = "macro"
                -- id is macroID
                local name, icon, body = GetMacroInfo(id)
                if name then
                    wiseValue = name
                    thisExtra = thisExtra or {}
                    thisExtra.icon = icon
                end

            elseif actionType == "summonmount" or actionType == "mount" then
                wiseType = "mount"
                wiseValue = id -- mountID

            elseif actionType == "summonpet" then
                wiseType = "battlepet"
                wiseValue = id -- petGUID

            elseif actionType == "companion" then
                if subType == "MOUNT" then
                    wiseType = "mount"
                    wiseValue = id
                elseif subType == "PET" then
                    wiseType = "battlepet"
                    wiseValue = id
                end

            elseif actionType == "equipmentset" then
                wiseType = "equipmentset"
                wiseValue = id -- name

            end
        end

        if wiseType and wiseValue then
            -- Valid action: Add to specific target slot, inserting at the top (index 1)
            Wise:AddAction(targetGroupName, targetSlot, wiseType, wiseValue, "global", thisExtra, 1)
            copiedCount = copiedCount + 1
        else
            -- Empty slot: Add Spacer to preserve spacing
            -- Use custom_macro type with empty text and specific empty slot icon
            local spacerData = {
                icon = "Interface\\Buttons\\UI-EmptySlot",
                name = "Empty",
                macroText = ""
            }
            if condition then
                spacerData.conditions = condition
            end

            Wise:AddAction(targetGroupName, targetSlot, "misc", "custom_macro", "global", spacerData, 1)
            copiedCount = copiedCount + 1
        end
    end

    if copiedCount > 0 then
        -- Update the group display to reflect changes
         C_Timer.After(0, function()
             if not InCombatLockdown() then Wise:UpdateGroupDisplay(targetGroupName) end
         end)
    end

    return copiedCount
end

function Wise:CopyFromViewer(barIndex, viewerName, targetGroupName, customCondition)
    local copiedCount = 0
    local group = WiseDB.groups[targetGroupName]
    if not group then return 0 end

    local special = Wise.SpecialBars[barIndex]
    local condition = customCondition
    if condition == nil and special then
        condition = special.condition
    end

    local extraData = nil
    if condition and condition ~= "" then
         extraData = { conditions = condition }
    end

    local spells = {}
    local viewer = _G[viewerName]
    if viewer and viewer.GetChildren then
        local children = { viewer:GetChildren() }
        -- Sort by layoutIndex if possible to maintain order
        table.sort(children, function(a, b) 
            return (a.layoutIndex or 0) < (b.layoutIndex or 0) 
        end)
        
        for _, child in ipairs(children) do
            if child:IsShown() then
                 local spellID = child.spellID
                 if not spellID and child.cooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                     local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(child.cooldownID)
                     if info then spellID = info.spellID end
                 end
                 
                 if spellID then
                      local alreadyExists = false
                      for _, s in ipairs(spells) do
                          if s == spellID then alreadyExists = true break end
                      end
                      if not alreadyExists then
                          table.insert(spells, spellID)
                      end
                 end
            end
        end
    end

    Wise:MigrateGroupToActions(group)

    for i, spellID in ipairs(spells) do
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.name and info.iconID then
            local thisExtra = nil
            if extraData then
                thisExtra = {}
                for k,v in pairs(extraData) do thisExtra[k] = v end
            end
            
            -- Add to slot 1 so it prepends iteratively or can just append by passing the specific index, 
            -- actually targetSlot could be just slot 1 to append? Wait, AddAction inserts at slot 1.
            -- We want to append them maybe?
            -- To preserve order from viewer, we should insert at index 1 in reverse, or append.
            -- Since AddAction with index=1 prepends, we do reverse insertion.
        end
    end

    -- Insert in reverse to preserve order if prepending at index 1
    for i = #spells, 1, -1 do
        local spellID = spells[i]
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.name and info.iconID then
            local thisExtra = nil
            if extraData then
                thisExtra = {}
                for k,v in pairs(extraData) do thisExtra[k] = v end
            end

            Wise:AddAction(targetGroupName, 1, "spell", info.name, "global", thisExtra, 1)
            copiedCount = copiedCount + 1
        end
    end

    if copiedCount > 0 then
         C_Timer.After(0, function()
             if not InCombatLockdown() then Wise:UpdateGroupDisplay(targetGroupName) end
         end)
    end

    return copiedCount
end
