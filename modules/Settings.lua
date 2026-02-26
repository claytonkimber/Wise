local addonName, Wise = ...

function Wise:PopulateSettingsView(panel)
    if not panel then return end
    
    -- Clear existing children to avoid duplicates on refresh
    if panel.children then
        for _, child in ipairs(panel.children) do
            child:Hide()
        end
    end
    panel.children = {}

    -- Create split layout if not exists
    if not panel.leftScroll then
        -- Left Panel (General) - ScrollFrame
        local leftScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
        leftScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -10)
        leftScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOM", -30, 10)

        local leftChild = CreateFrame("Frame", nil, leftScroll)
        leftChild:SetSize(350, 500)
        leftScroll:SetScrollChild(leftChild)

        leftScroll:SetScript("OnSizeChanged", function(self, w, h)
            leftChild:SetWidth(w)
        end)

        panel.leftScroll = leftScroll
        panel.leftChild = leftChild

        -- Right Panel (Visual) - ScrollFrame
        local rightScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
        rightScroll:SetPoint("TOPLEFT", panel, "TOP", 5, -10)
        rightScroll:SetPoint("BOTTOMRIGHT", -30, 10)
        
        local rightChild = CreateFrame("Frame", nil, rightScroll)
        rightChild:SetSize(350, 500) -- Initial size
        rightScroll:SetScrollChild(rightChild)
        
        -- Update child width when scroll frame resizes
        rightScroll:SetScript("OnSizeChanged", function(self, w, h)
            rightChild:SetWidth(w)
        end)
        
        panel.rightScroll = rightScroll
        panel.rightChild = rightChild
        
        -- Separator
        local sep = panel:CreateLine()
        sep:SetStartPoint("TOP", 0, -20)
        sep:SetEndPoint("BOTTOM", 0, 20)
        sep:SetColorTexture(0.3, 0.3, 0.3, 0.5)
        sep:SetThickness(1)
        panel.separator = sep
    end
    
    panel.leftScroll:Show()
    panel.rightScroll:Show()

    local leftContent = panel.leftChild
    local rightContent = panel.rightChild
    local panelWidth = 350 

    -- Helper to add child to specific content frame and track Y
    local function AddToContent(contentFrame, child, x, y)
        child:SetParent(contentFrame)
        child:ClearAllPoints()
        child:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", x, y)
        table.insert(panel.children, child)
    end
    
    -- === LEFT PANEL: GENERAL SETTINGS ===
    local ly = -10
    local lx = 10
    
    local generalHeader = leftContent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    generalHeader:SetPoint("TOP", leftContent, "TOP", 0, ly) 
    generalHeader:SetText("General Settings")
    table.insert(panel.children, generalHeader)
    ly = ly - 40
    
    -- Minimap Button
    local mmBtn = CreateFrame("CheckButton", nil, leftContent, "UICheckButtonTemplate")
    AddToContent(leftContent, mmBtn, lx, ly)
    mmBtn:SetChecked(not WiseDB.settings.minimap.hide)
    mmBtn.text = mmBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    mmBtn.text:SetPoint("LEFT", mmBtn, "RIGHT", 5, 0)
    mmBtn.text:SetText("Show Minimap Button")
    mmBtn:SetScript("OnClick", function(self)
        local show = self:GetChecked()
        WiseDB.settings.minimap.hide = not show
        if Wise.UpdateMinimapButton then
            Wise:UpdateMinimapButton()
        end
    end)
    table.insert(panel.children, mmBtn.text)
    ly = ly - 30

    -- Drag and Drop
    local ddBtn = CreateFrame("CheckButton", nil, leftContent, "UICheckButtonTemplate")
    AddToContent(leftContent, ddBtn, lx, ly)
    ddBtn:SetChecked(WiseDB.settings.enableDragDrop ~= false) -- Default true
    ddBtn.text = ddBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ddBtn.text:SetPoint("LEFT", ddBtn, "RIGHT", 5, 0)
    ddBtn.text:SetText("Enable Drag and Drop")
    ddBtn:SetScript("OnClick", function(self)
        WiseDB.settings.enableDragDrop = self:GetChecked()
    end)
    table.insert(panel.children, ddBtn.text)
    ly = ly - 40

    -- Interface Tooltips
    local tipsBtn = CreateFrame("CheckButton", nil, leftContent, "UICheckButtonTemplate")
    AddToContent(leftContent, tipsBtn, lx, ly)
    tipsBtn:SetChecked(WiseDB.settings.showTooltips)
    tipsBtn.text = tipsBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tipsBtn.text:SetPoint("LEFT", tipsBtn, "RIGHT", 5, 0)
    tipsBtn.text:SetText("Show Interface Tooltips")
    tipsBtn:SetScript("OnClick", function(self)
        WiseDB.settings.showTooltips = self:GetChecked()
    end)
    table.insert(panel.children, tipsBtn.text)
    ly = ly - 40

    -- Import/Export
    local ieHeader = leftContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    addToContent = function(c, child, x, y) child:SetParent(c); child:ClearAllPoints(); child:SetPoint("TOPLEFT", x, y); table.insert(panel.children, child); end
    -- Redefining helper cleanly
    
    local importBtn = CreateFrame("Button", nil, leftContent, "GameMenuButtonTemplate")
    importBtn:SetSize(panelWidth - 20, 24)
    AddToContent(leftContent, importBtn, lx, ly)
    importBtn:SetText("Import Interface")
    importBtn:SetScript("OnClick", function()
        StaticPopupDialogs["WISE_IMPORT"] = {
            text = "Paste an import string below:",
            button1 = "Import",
            button2 = "Cancel",
            hasEditBox = true,
            editBoxWidth = 350,
            OnShow = function(self)
                local eb = self.EditBox or self.editBox; if not eb then return end
                eb:SetText("")
                eb:SetFocus()
            end,
            OnAccept = function(self)
                local eb = self.EditBox or self.editBox; local text = eb and eb:GetText()
                if text and text ~= "" then
                    local ok, msg, conflicts = Wise:ImportInterfaces(text, false)
                    if ok then
                        print("|cff00ccff[Wise]|r " .. msg)
                        if Wise.UpdateOptionsUI then Wise:UpdateOptionsUI() end
                        if conflicts and #conflicts > 0 then
                            Wise:ProcessImportConflicts(conflicts)
                        end
                    else
                        print("|cff00ccff[Wise]|r Import failed: " .. (msg or "unknown error"))
                    end
                end
            end,
            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                StaticPopup_OnClick(parent, 1)
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        StaticPopup_Show("WISE_IMPORT")
    end)
    ly = ly - 30

    local exportAllBtn = CreateFrame("Button", nil, leftContent, "GameMenuButtonTemplate")
    exportAllBtn:SetSize(panelWidth - 20, 24)
    AddToContent(leftContent, exportAllBtn, lx, ly)
    exportAllBtn:SetText("Export All Custom")
    exportAllBtn:SetScript("OnClick", function()
        local names = {}
        for name, group in pairs(WiseDB.groups) do
            if not group.isWiser then
                names[#names+1] = name
            end
        end
        if #names == 0 then
            print("|cff00ccff[Wise]|r No custom interfaces to export.")
            return
        end
        local encoded = Wise:ExportInterfaces(names)
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
    ly = ly - 30

    -- === BLIZZARD UI VISIBILITY ===
    ly = ly - 20
    local blizHeader = leftContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    blizHeader:SetPoint("TOP", leftContent, "TOP", 0, ly)
    blizHeader:SetText("Blizzard Action Bars")
    table.insert(panel.children, blizHeader)
    ly = ly - 30

    -- Explanation and Button for Other Bars
    local otherBarsText = leftContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    AddToContent(leftContent, otherBarsText, lx, ly)
    otherBarsText:SetWidth(panelWidth - 20)
    otherBarsText:SetJustifyH("LEFT")
    otherBarsText:SetText("Action Bars 2-8 can be hidden in Game Settings > Action Bars.")
    table.insert(panel.children, otherBarsText)
    ly = ly - 30



    if Wise.BlizzardFrames then
        for _, info in ipairs(Wise.BlizzardFrames) do
            local cb = CreateFrame("CheckButton", nil, leftContent, "UICheckButtonTemplate")
            AddToContent(leftContent, cb, lx, ly)
            -- Note: We store "hide" settings, so checked = hide
            cb:SetChecked(WiseDB.settings.blizzardUI and WiseDB.settings.blizzardUI[info.key])

            cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            cb.text:SetPoint("LEFT", cb, "RIGHT", 5, 0)
            cb.text:SetText("Hide " .. info.label)

            cb:SetScript("OnClick", function(self)
                local checked = self:GetChecked()
                if not WiseDB.settings.blizzardUI then WiseDB.settings.blizzardUI = {} end
                WiseDB.settings.blizzardUI[info.key] = checked



                if Wise.UpdateBlizzardUI then
                    Wise:UpdateBlizzardUI()
                end
            end)

            -- Important: Add cb to panel.children for cleanup
            table.insert(panel.children, cb.text)
            -- Note: AddToContent already adds 'child' (cb) to panel.children.
            -- However, cb.text is created separately and anchored to cb, but we want it hidden too.
            -- AddToContent does: table.insert(panel.children, child)
            -- So cb is handled. We just need to handle cb.text if it's not a child of cb (it is child of cb in template usually? No, regions).
            -- In UICheckButtonTemplate, text is often a region.
            -- Here we created it: cb.text = cb:CreateFontString(nil, "OVERLAY", ...)
            -- It is attached to cb. If cb hides, text hides.
            -- But we inserted cb.text into panel.children in the snippet.
            -- Wait, AddToContent adds 'cb'.
            -- We also insert 'cb.text' manually in the code.
            -- If we insert it, it will be hidden by the loop at top of function.
            -- If we don't, and it's parented to 'cb', it hides when 'cb' hides.
            -- Let's check if 'cb' is parent of 'cb.text'.
            -- cb.text = cb:CreateFontString... YES.
            -- So hiding cb hides text.
            -- BUT, previous code had `table.insert(panel.children, cb.text)`.
            -- Is that necessary? Only if we want to explicitly track it.
            -- Since AddToContent tracks cb, and cb owns text, we might not need to track text separately.
            -- However, let's keep it consistent with other elements.
            -- But wait, `AddToContent` uses `table.insert`.
            -- The previous code block for Blizzard Frames:
            --   local cb = CreateFrame...
            --   AddToContent(..., cb, ...)  <-- Adds cb to children
            --   ...
            --   table.insert(panel.children, cb.text) <-- Adds text to children
            -- This seems redundant but safe.
            -- The code review concern was: "fails to insert the checkbox frame `cb` itself".
            -- But `AddToContent` DOES insert it.
            -- Let's verify `AddToContent`.
            -- local function AddToContent(contentFrame, child, x, y) ... table.insert(panel.children, child) end
            -- So `cb` IS inserted.
            -- The reviewer might have missed that.
            -- I will double check if I missed anything else.
            ly = ly - 30
        end
    end

    leftContent:SetHeight(math.abs(ly) + 20)

    -- === RIGHT PANEL: VISUAL SETTINGS ===
    local ry = -10
    local rx = 10
    
    local visualHeader = rightContent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    visualHeader:SetPoint("TOP", rightContent, "TOP", 0, ry)
    visualHeader:SetText("Global Visual Settings")
    table.insert(panel.children, visualHeader)
    ry = ry - 40

    -- Icon Style
    local styleLabel = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, styleLabel, rx, ry)
    local styleLabelText = "Icon Style:"
    if C_AddOns and C_AddOns.IsAddOnLoaded("Masque") then
        styleLabelText = styleLabelText .. " |cffff0000(being overridden by Masque)|r"
    else
        styleLabelText = styleLabelText .. " |cffaaaaaa(more with Masque addon)|r"
    end
    styleLabel:SetText(styleLabelText)
    ry = ry - 20

    local styles = {
        {val="rounded", text="Rounded"},
        {val="square", text="Square"},
        {val="round", text="Round"}
    }
    local startY = ry
    for i, styleMode in ipairs(styles) do
        local radio = CreateFrame("CheckButton", nil, rightContent, "UIRadioButtonTemplate")
        local col = (i-1) % 3
        AddToContent(rightContent, radio, rx + (col * 80), startY)
        radio:SetChecked((WiseDB.settings.iconStyle or "rounded") == styleMode.val)
        radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        radio.text:SetPoint("LEFT", radio, "RIGHT", 2, 0)
        radio.text:SetText(styleMode.text)

        radio:SetScript("OnClick", function(self)
            WiseDB.settings.iconStyle = styleMode.val
            Wise:PopulateSettingsView(panel)
            C_Timer.After(0.1, function()
               if not InCombatLockdown() then
                   for name in pairs(WiseDB.groups) do Wise:UpdateGroupDisplay(name) end
               end
            end)
        end)
        table.insert(panel.children, radio.text)
    end
    ry = ry - 40

    -- Icon Size
    local iconLabel = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, iconLabel, rx, ry)
    iconLabel:SetText("Icon Size:")
    ry = ry - 20
    
    local iconSlider = CreateFrame("Slider", nil, rightContent, "OptionsSliderTemplate")
    AddToContent(rightContent, iconSlider, rx+10, ry)
    iconSlider:SetSize(panelWidth - 40, 16)
    iconSlider:SetMinMaxValues(16, 64)
    iconSlider:SetValue(WiseDB.settings.iconSize or 30)
    iconSlider:SetValueStep(2)
    iconSlider:SetObeyStepOnDrag(true)
    iconSlider.Low:SetText("16")
    iconSlider.High:SetText("64")
    iconSlider.Text:SetText(tostring(WiseDB.settings.iconSize or 30))
    iconSlider:SetScript("OnValueChanged", function(self, value)
        local size = math.floor(value)
        WiseDB.settings.iconSize = size
        self.Text:SetText(tostring(size))
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then
                for name in pairs(WiseDB.groups) do Wise:UpdateGroupDisplay(name) end
            end
        end)
    end)
    ry = ry - 40

    -- Text Size
    local textLabel = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, textLabel, rx, ry)
    textLabel:SetText("Text Size:")
    ry = ry - 20
    
    local textSlider = CreateFrame("Slider", nil, rightContent, "OptionsSliderTemplate")
    AddToContent(rightContent, textSlider, rx+10, ry)
    textSlider:SetSize(panelWidth - 40, 16)
    textSlider:SetMinMaxValues(8, 24)
    textSlider:SetValue(WiseDB.settings.textSize or 12)
    textSlider:SetValueStep(1)
    textSlider:SetObeyStepOnDrag(true)
    textSlider.Low:SetText("8")
    textSlider.High:SetText("24")
    textSlider.Text:SetText(tostring(WiseDB.settings.textSize or 12))
    textSlider:SetScript("OnValueChanged", function(self, value)
        local size = math.floor(value)
        WiseDB.settings.textSize = size
        self.Text:SetText(tostring(size))
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then
                for name in pairs(WiseDB.groups) do Wise:UpdateGroupDisplay(name) end
            end
        end)
    end)
    ry = ry - 40

    -- Font
    local fontLabel = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, fontLabel, rx, ry)
    fontLabel:SetText("Font:")
    ry = ry - 25

    -- Build Content --
    local validFonts = {}
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local lsmFonts = LSM:HashTable("font")
        if lsmFonts then
            for name, path in pairs(lsmFonts) do
                table.insert(validFonts, { name = name, path = path })
            end
        end
        table.sort(validFonts, function(a, b) return a.name < b.name end)
    end
    if #validFonts == 0 then
        local defaultFonts = {
            { name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
            { name = "Arial Narrow", path = "Fonts\\ARIALN.TTF" },
            { name = "Morpheus", path = "Fonts\\MORPHEUS.TTF" },
            { name = "Skurri", path = "Fonts\\SKURRI.TTF" },
            { name = "2002", path = "Fonts\\2002.TTF" },
            { name = "2002 Bold", path = "Fonts\\2002B.TTF" },
            { name = "Friz Quadrata (CYR)", path = "Fonts\\FRIZQT___CYR.TTF" },
        }
        -- Simple check
        local testFrame = CreateFrame("Frame")
        local testFont = testFrame:CreateFontString(nil, "OVERLAY")
        for _, f in ipairs(defaultFonts) do
            if testFont:SetFont(f.path, 12, "") then
                table.insert(validFonts, f)
            end
        end
        if #validFonts == 0 then
            validFonts = {{ name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" }}
        end
    end
    
    local currentFontName = "Friz Quadrata"
    local currentFontPath = WiseDB.settings.font or "Fonts\\FRIZQT__.TTF"
    for _, f in ipairs(validFonts) do
        if f.path == currentFontPath then currentFontName = f.name; break end
    end
    if currentFontName == "Friz Quadrata" and currentFontPath ~= "Fonts\\FRIZQT__.TTF" then
        currentFontName = currentFontPath:match("([^\\]+)$") or currentFontPath
    end
    
    local fontBtn = CreateFrame("Button", nil, rightContent, "GameMenuButtonTemplate")
    fontBtn:SetSize(panelWidth - 20, 24)
    AddToContent(rightContent, fontBtn, rx+10, ry)
    fontBtn:SetText(currentFontName)
    fontBtn:SetScript("OnClick", function(self)
        if self.dropdown and self.dropdown:IsShown() then self.dropdown:Hide(); return end
        if not self.dropdown then
            local d = CreateFrame("Frame", nil, self, "BackdropTemplate")
            self.dropdown = d
            local itemHeight = 22
            local maxVisible = 10
            local visibleCount = math.min(#validFonts, maxVisible)
            local dropdownHeight = (visibleCount * itemHeight) + 20
            local needsScroll = #validFonts > maxVisible
            d:SetSize(240, dropdownHeight)
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
                scrollContent:SetSize(195, itemHeight * #validFonts)
                scrollFrame:SetScrollChild(scrollContent)
                scrollFrame:SetVerticalScroll(0)
            else
                scrollContent = CreateFrame("Frame", nil, d)
                scrollContent:SetPoint("TOPLEFT", 8, -8)
                scrollContent:SetPoint("BOTTOMRIGHT", -8, 8)
            end
            
            for i, f in ipairs(validFonts) do
                local btn = CreateFrame("Button", nil, scrollContent)
                btn:SetSize(195, itemHeight - 2)
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
                    WiseDB.settings.font = f.path
                    self:SetText(f.name)
                    d:Hide()
                    C_Timer.After(0.1, function()
                        if not InCombatLockdown() then
                            for name in pairs(WiseDB.groups) do
                                Wise:UpdateGroupDisplay(name)
                            end
                        end
                    end)
                end)
                btn:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 1, 1) end)
                btn:SetScript("OnLeave", function(self) self.text:SetTextColor(1, 0.82, 0) end)
            end
        end
        self.dropdown:Show()
    end)
    ry = ry - 40

    -- Keybinds
    local kbHeader = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, kbHeader, rx, ry)
    kbHeader:SetText("Keybind Display")
    ry = ry - 30
    
    local showKb = CreateFrame("CheckButton", nil, rightContent, "UICheckButtonTemplate")
    AddToContent(rightContent, showKb, rx, ry)
    showKb:SetChecked(WiseDB.settings.showKeybinds)
    showKb.text = showKb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    showKb.text:SetPoint("LEFT", showKb, "RIGHT", 5, 0)
    showKb.text:SetText("Show")
    showKb:SetScript("OnClick", function(self)
        WiseDB.settings.showKeybinds = self:GetChecked()
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then
                for name in pairs(WiseDB.groups) do Wise:UpdateGroupDisplay(name) end
                
                -- Force text refresh on all active buttons to apply standard bind visuals
                if Wise.frames then
                    for groupName, f in pairs(Wise.frames) do
                        local _, _, _, showKeybinds = Wise:GetGroupDisplaySettings(groupName)
                        if f.buttons then
                            for _, btn in ipairs(f.buttons) do
                                Wise:Text_UpdateKeybind(btn, groupName, showKeybinds)
                            end
                        end
                    end
                end
            end
        end)
    end)
    table.insert(panel.children, showKb.text)
    ry = ry - 30

    local kbPosLabel = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, kbPosLabel, rx, ry)
    kbPosLabel:SetText("Position:")
    ry = ry - 20
    
    local positions = {
        {val="TOPLEFT", text="TL"}, {val="TOP", text="T"}, {val="TOPRIGHT", text="TR"},
        {val="LEFT", text="L"}, {val="CENTER", text="C"}, {val="RIGHT", text="R"},
        {val="BOTTOMLEFT", text="BL"}, {val="BOTTOM", text="B"}, {val="BOTTOMRIGHT", text="BR"},
    }
    local startY = ry
    for i, posMode in ipairs(positions) do
        local radio = CreateFrame("CheckButton", nil, rightContent, "UIRadioButtonTemplate")
        local col = (i-1) % 3
        local row = math.floor((i-1) / 3)
        AddToContent(rightContent, radio, rx + (col * 60), startY - (row * 20))
        radio:SetChecked(WiseDB.settings.keybindPosition == posMode.val)
        radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        radio.text:SetPoint("LEFT", radio, "RIGHT", 2, 0)
        radio.text:SetText(posMode.text)
        
        radio:SetScript("OnClick", function(self)
            WiseDB.settings.keybindPosition = posMode.val
            Wise:PopulateSettingsView(panel)
            C_Timer.After(0.1, function()
               if not InCombatLockdown() then
                   for name in pairs(WiseDB.groups) do Wise:UpdateGroupDisplay(name) end
               end
            end)
        end)
        table.insert(panel.children, radio.text)
    end
    ry = ry - 70
    
    local kbSizeLabel = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, kbSizeLabel, rx, ry)
    kbSizeLabel:SetText("Size:")
    ry = ry - 20
    
    local kbSizeSlider = CreateFrame("Slider", nil, rightContent, "OptionsSliderTemplate")
    AddToContent(rightContent, kbSizeSlider, rx+10, ry)
    kbSizeSlider:SetSize(panelWidth - 40, 16)
    kbSizeSlider:SetMinMaxValues(8, 24)
    kbSizeSlider:SetValue(WiseDB.settings.keybindTextSize or 10)
    kbSizeSlider:SetValueStep(1)
    kbSizeSlider:SetObeyStepOnDrag(true)
    kbSizeSlider.Low:SetText("8")
    kbSizeSlider.High:SetText("24")
    kbSizeSlider.Text:SetText(tostring(WiseDB.settings.keybindTextSize or 10))
    kbSizeSlider:SetScript("OnValueChanged", function(self, value)
        WiseDB.settings.keybindTextSize = math.floor(value)
        self.Text:SetText(tostring(WiseDB.settings.keybindTextSize))
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then
                 for name in pairs(WiseDB.groups) do Wise:UpdateGroupDisplay(name) end
            end
        end)
    end)
    ry = ry - 40

    -- Charge Text
    local chargeHeader = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, chargeHeader, rx, ry)
    chargeHeader:SetText("Charge Text Display")
    ry = ry - 30
    
    local showChargeText = CreateFrame("CheckButton", nil, rightContent, "UICheckButtonTemplate")
    AddToContent(rightContent, showChargeText, rx, ry)
    if WiseDB.settings.showChargeText == nil then WiseDB.settings.showChargeText = true end
    showChargeText:SetChecked(WiseDB.settings.showChargeText)
    showChargeText.text = showChargeText:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    showChargeText.text:SetPoint("LEFT", showChargeText, "RIGHT", 5, 0)
    showChargeText.text:SetText("Show")
    showChargeText:SetScript("OnClick", function(self)
        WiseDB.settings.showChargeText = self:GetChecked()
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then
                for name in pairs(WiseDB.groups) do Wise:UpdateGroupDisplay(name) end
                if Wise.UpdateAllCharges then Wise:UpdateAllCharges() end
            end
        end)
    end)
    table.insert(panel.children, showChargeText.text)
    ry = ry - 30

    local chargePosLabel = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, chargePosLabel, rx, ry)
    chargePosLabel:SetText("Position:")
    ry = ry - 20
    
    local chargePos = WiseDB.settings.chargeTextPosition or "TOP"
    local chargeStartY = ry
    for i, posMode in ipairs(positions) do
        local radio = CreateFrame("CheckButton", nil, rightContent, "UIRadioButtonTemplate")
        local col = (i-1) % 3
        local row = math.floor((i-1) / 3)
        AddToContent(rightContent, radio, rx + (col * 60), chargeStartY - (row * 20))
        radio:SetChecked(chargePos == posMode.val)
        radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        radio.text:SetPoint("LEFT", radio, "RIGHT", 2, 0)
        radio.text:SetText(posMode.text)
        
        radio:SetScript("OnClick", function(self)
            WiseDB.settings.chargeTextPosition = posMode.val
            Wise:PopulateSettingsView(panel) 
            C_Timer.After(0.1, function()
                if not InCombatLockdown() then
                    for name in pairs(WiseDB.groups) do Wise:UpdateGroupDisplay(name) end
                end
            end)
        end)
        table.insert(panel.children, radio.text)
    end
    ry = ry - 70
    
    local chargeSizeLabel = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, chargeSizeLabel, rx, ry)
    chargeSizeLabel:SetText("Size:")
    ry = ry - 20
    
    local chargeSizeSlider = CreateFrame("Slider", nil, rightContent, "OptionsSliderTemplate")
    AddToContent(rightContent, chargeSizeSlider, rx+10, ry)
    chargeSizeSlider:SetSize(panelWidth - 40, 16)
    chargeSizeSlider:SetMinMaxValues(8, 24)
    chargeSizeSlider:SetValue(WiseDB.settings.chargeTextSize or 12)
    chargeSizeSlider:SetValueStep(1)
    chargeSizeSlider:SetObeyStepOnDrag(true)
    chargeSizeSlider.Low:SetText("8")
    chargeSizeSlider.High:SetText("24")
    chargeSizeSlider.Text:SetText(tostring(WiseDB.settings.chargeTextSize or 12))
    chargeSizeSlider:SetScript("OnValueChanged", function(self, value)
        WiseDB.settings.chargeTextSize = math.floor(value)
        self.Text:SetText(tostring(WiseDB.settings.chargeTextSize))
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then
                 for name in pairs(WiseDB.groups) do Wise:UpdateGroupDisplay(name) end
            end
        end)
    end)
    ry = ry - 40
    
    -- Countdown Text
    local cdHeader = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, cdHeader, rx, ry)
    cdHeader:SetText("Countdown Text Display")
    ry = ry - 30
    
    local showCountdownText = CreateFrame("CheckButton", nil, rightContent, "UICheckButtonTemplate")
    AddToContent(rightContent, showCountdownText, rx, ry)
    if WiseDB.settings.showCountdownText == nil then WiseDB.settings.showCountdownText = true end
    showCountdownText:SetChecked(WiseDB.settings.showCountdownText)
    showCountdownText.text = showCountdownText:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    showCountdownText.text:SetPoint("LEFT", showCountdownText, "RIGHT", 5, 0)
    showCountdownText.text:SetText("Show")
    showCountdownText:SetScript("OnClick", function(self)
        WiseDB.settings.showCountdownText = self:GetChecked()
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then
                if Wise.UpdateAllCooldowns then Wise:UpdateAllCooldowns() end
            end
        end)
    end)
    table.insert(panel.children, showCountdownText.text)
    ry = ry - 30

    local cdPosLabel = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, cdPosLabel, rx, ry)
    cdPosLabel:SetText("Position:")
    ry = ry - 20
    
    local cdPos = WiseDB.settings.countdownTextPosition or "CENTER"
    local cdStartY = ry
    for i, posMode in ipairs(positions) do
        local radio = CreateFrame("CheckButton", nil, rightContent, "UIRadioButtonTemplate")
        local col = (i-1) % 3
        local row = math.floor((i-1) / 3)
        AddToContent(rightContent, radio, rx + (col * 60), cdStartY - (row * 20))
        radio:SetChecked(cdPos == posMode.val)
        radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        radio.text:SetPoint("LEFT", radio, "RIGHT", 2, 0)
        radio.text:SetText(posMode.text)
        
        radio:SetScript("OnClick", function(self)
            WiseDB.settings.countdownTextPosition = posMode.val
            Wise:PopulateSettingsView(panel) 
            C_Timer.After(0.1, function()
                if not InCombatLockdown() then Wise:UpdateAllCooldowns() end
            end)
        end)
        table.insert(panel.children, radio.text)
    end
    ry = ry - 70
    
    local cdSizeLabel = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, cdSizeLabel, rx, ry)
    cdSizeLabel:SetText("Size:")
    ry = ry - 20
    
    local cdSizeSlider = CreateFrame("Slider", nil, rightContent, "OptionsSliderTemplate")
    AddToContent(rightContent, cdSizeSlider, rx+10, ry)
    cdSizeSlider:SetSize(panelWidth - 40, 16)
    cdSizeSlider:SetMinMaxValues(8, 24)
    cdSizeSlider:SetValue(WiseDB.settings.countdownTextSize or 12)
    cdSizeSlider:SetValueStep(1)
    cdSizeSlider:SetObeyStepOnDrag(true)
    cdSizeSlider.Low:SetText("8")
    cdSizeSlider.High:SetText("24")
    cdSizeSlider.Text:SetText(tostring(WiseDB.settings.countdownTextSize or 12))
    cdSizeSlider:SetScript("OnValueChanged", function(self, value)
        WiseDB.settings.countdownTextSize = math.floor(value)
        self.Text:SetText(tostring(WiseDB.settings.countdownTextSize))
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then Wise:UpdateAllCooldowns() end
        end)
    end)
    ry = ry - 40
    
    -- Proc Glows
    local glowHeader = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, glowHeader, rx, ry)
    glowHeader:SetText("Proc Glows")
    ry = ry - 20
    
    local showGlows = CreateFrame("CheckButton", nil, rightContent, "UICheckButtonTemplate")
    AddToContent(rightContent, showGlows, rx, ry)
    showGlows:SetChecked(WiseDB.settings.showGlows)
    showGlows.text = showGlows:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    showGlows.text:SetPoint("LEFT", showGlows, "RIGHT", 5, 0)
    showGlows.text:SetText("Show Proc Glows")
    showGlows:SetScript("OnClick", function(self)
        WiseDB.settings.showGlows = self:GetChecked()
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then Wise:UpdateAllUsability() end
        end)
    end)
    table.insert(panel.children, showGlows.text)
    ry = ry - 40

    -- Buff Durations
    local buffHeader = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, buffHeader, rx, ry)
    buffHeader:SetText("Buff Durations")
    ry = ry - 20
    
    local showBuffs = CreateFrame("CheckButton", nil, rightContent, "UICheckButtonTemplate")
    AddToContent(rightContent, showBuffs, rx, ry)
    showBuffs:SetChecked(WiseDB.settings.showBuffs)
    showBuffs.text = showBuffs:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    showBuffs.text:SetPoint("LEFT", showBuffs, "RIGHT", 5, 0)
    showBuffs.text:SetText("Show Buff Durations on Buttons")
    showBuffs:SetScript("OnClick", function(self)
        WiseDB.settings.showBuffs = self:GetChecked()
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then Wise:UpdateAllCooldowns() end
        end)
    end)
    table.insert(panel.children, showBuffs.text)
    ry = ry - 40

    -- GCD Indicators
    local gcdHeader = rightContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    AddToContent(rightContent, gcdHeader, rx, ry)
    gcdHeader:SetText("GCD Indicators")
    ry = ry - 20

    local showGCD = CreateFrame("CheckButton", nil, rightContent, "UICheckButtonTemplate")
    AddToContent(rightContent, showGCD, rx, ry)
    -- Default to true if nil
    local currentGCD = WiseDB.settings.showGCD
    if currentGCD == nil then currentGCD = true end
    showGCD:SetChecked(currentGCD)
    showGCD.text = showGCD:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    showGCD.text:SetPoint("LEFT", showGCD, "RIGHT", 5, 0)
    showGCD.text:SetText("Show Global Cooldown Indicators")
    showGCD:SetScript("OnClick", function(self)
        WiseDB.settings.showGCD = self:GetChecked()
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then Wise:UpdateAllCooldowns() end
        end)
    end)
    table.insert(panel.children, showGCD.text)
    ry = ry - 40

    rightContent:SetHeight(math.abs(ry) + 20)
end
