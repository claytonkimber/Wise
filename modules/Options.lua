-- Options.lua
local addonName, Wise = ...

function Wise:CreateOptionsFrame()
    local f = CreateFrame("Frame", "WiseOptionsFrame", UIParent, "PortraitFrameTemplate")
    f:Hide()
    f:SetSize(850, 500)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetTitle("Wise Options")
    
    -- Set the Wise tree logo in the portrait
    local portraitTex = nil
    if f.PortraitContainer and f.PortraitContainer.portrait then
        portraitTex = f.PortraitContainer.portrait
    elseif f.portrait then
        portraitTex = f.portrait
    end
    if portraitTex then
        portraitTex:SetTexture("Interface\\AddOns\\Wise\\Media\\WiseLogo")
        portraitTex:SetTexCoord(-0.031, 1.051, -0.020, 1.062)
    end
    
    Wise.OptionsFrame = f
    -- Note: NOT added to UISpecialFrames so it stays open when other panels are opened

    -- 1. Sidebar (Group List)
    f.Sidebar = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    f.Sidebar:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -60)
    f.Sidebar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 40) -- Anchor to bottom (tabs area)
    f.Sidebar:SetWidth(200)

    -- Sticky "New Wise Interface" button at top of sidebar
    f.Sidebar.AddBtn = CreateFrame("Button", nil, f.Sidebar, "GameMenuButtonTemplate")
    f.Sidebar.AddBtn:SetSize(180, 24)
    f.Sidebar.AddBtn:SetText("New Wise Interface")
    f.Sidebar.AddBtn:SetPoint("TOP", f.Sidebar, "TOP", 0, -20)
    Wise:AddTooltip(f.Sidebar.AddBtn, "Create a new custom interface (ring, bar, grid).")
    f.Sidebar.AddBtn:SetScript("OnClick", function()
        StaticPopup_Show("WISE_CREATE_GROUP")
    end)

    -- 2. Middle (Button List / Action Picker)
    f.Middle = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    f.Middle:SetPoint("TOPLEFT", f.Sidebar, "TOPRIGHT", 5, 0)
    f.Middle:SetPoint("BOTTOMLEFT", f.Sidebar, "BOTTOMRIGHT", 5, 0)
    f.Middle:SetWidth(300)

    -- Sticky "Add New Slot" button at top of middle panel
    f.Middle.AddSlotBtn = CreateFrame("Button", nil, f.Middle, "GameMenuButtonTemplate")
    f.Middle.AddSlotBtn:SetSize(180, 24)
    f.Middle.AddSlotBtn:SetText("Add New Slot")
    f.Middle.AddSlotBtn:SetPoint("TOP", f.Middle, "TOP", 0, -20)
    Wise:AddTooltip(f.Middle.AddSlotBtn, "Add a new action slot to the selected interface.")

    -- Filter Buttons (Anchored to Top Edge of Middle Column)
    f.Middle.FilterButtons = {}
    local filterWidth = 300 -- Match Middle column width
    local btnWidth = filterWidth / 5
    -- We want them to sit ON the top edge. 
    -- f.Middle is an InsetFrame. We anchor to its TOPLEFT but shift up.
    -- Parent to f so they aren't clipped or inside the inset.
    
    local filters = {"global", "class", "spec", "talent_build", "character"}
    local labels = {global="Global", class="Class", spec="Spec", talent_build="Build", character="Char"}
    
    for i, filter in ipairs(filters) do
        local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        btn:SetSize(btnWidth, 20)
        -- Align 0 to width. 
        -- f.Middle TopLeft is 5px right of Sidebar. 
        -- We anchor directly to f.Middle for ease.
        btn:SetPoint("BOTTOMLEFT", f.Middle, "TOPLEFT", (i-1)*btnWidth, 0)
        btn:SetText(labels[filter])
        Wise:AddTooltip(btn, "Show " .. labels[filter] .. " actions.")
        
        btn:SetScript("OnClick", function()
             Wise.ActionFilter = filter
             Wise:UpdateFilterButtons()
             Wise:RefreshActionsView(f.Middle.Content)
        end)
        f.Middle.FilterButtons[filter] = btn
    end

    -- 3. Right (Properties)
    f.Right = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    f.Right:SetPoint("TOPLEFT", f.Middle, "TOPRIGHT", 5, 0)
    f.Right:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 40) -- Anchor to bottom (tabs area)

    -- 4. Tab Strip
    f.TabStrip = CreateFrame("Frame", nil, f)
    f.TabStrip:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 10)
    f.TabStrip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    f.TabStrip:SetHeight(25)

    -- Edit Mode Button (bottom-right, inline with tabs)
    f.EditModeBtn = CreateFrame("Button", nil, f.TabStrip, "GameMenuButtonTemplate")
    f.EditModeBtn:SetSize(140, 24)
    f.EditModeBtn:SetText("Edit Mode")
    f.EditModeBtn:SetPoint("RIGHT", f.TabStrip, "RIGHT", 0, 0)
    Wise:AddTooltip(f.EditModeBtn, "Open WoW's Edit Mode to reposition Wise interfaces.")
    f.EditModeBtn:SetScript("OnClick", function()
        Wise:ToggleEditMode()
    end)

    -- Define Views
    f.Views = {}
    f.Views.Editor = { f.Sidebar, f.Middle, f.Right }

    -- Create Other Views
    -- Conditionals View
    f.Views.Conditionals = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    f.Views.Conditionals:SetPoint("TOPLEFT", 10, -30)
    f.Views.Conditionals:SetPoint("BOTTOMRIGHT", -10, 40)
    f.Views.Conditionals:Hide()
    
    f.Views.Conditionals.Title = f.Views.Conditionals:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.Views.Conditionals.Title:SetPoint("TOP", 0, -10)
    f.Views.Conditionals.Title:SetText("Built-in Macro Conditionals")

    f.Views.Conditionals.Scroll = CreateFrame("ScrollFrame", nil, f.Views.Conditionals, "UIPanelScrollFrameTemplate")
    f.Views.Conditionals.Scroll:SetPoint("TOPLEFT", 10, -30)
    f.Views.Conditionals.Scroll:SetPoint("BOTTOMRIGHT", -30, 10)
    
    f.Views.Conditionals.Content = CreateFrame("Frame", nil, f.Views.Conditionals.Scroll)
    f.Views.Conditionals.Content:SetSize(800, 400)
    f.Views.Conditionals.Scroll:SetScrollChild(f.Views.Conditionals.Content)

    -- States View (Removed)

    -- Settings View
    f.Views.Settings = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    f.Views.Settings:SetPoint("TOPLEFT", 10, -30)
    f.Views.Settings:SetPoint("BOTTOMRIGHT", -10, 40)
    f.Views.Settings:Hide()
    
    -- ScrollFrame for Settings (REMOVED: Now handled inside PopulateSettingsView with split layout)
    -- f.Views.Settings is the panel passed to PopulateSettingsView

    -- Info View
    f.Views.Info = Wise:CreateInfoView(f)

    -- Tabs Logic
    local tabs = {
        { name = "Editor", view = "Editor" },
        { name = "Conditionals", view = "Conditionals" },
        { name = "Settings", view = "Settings" },
        { name = "Info", view = "Info" },
    }
    
    f.TabButtons = {}
    local tabWidth = 100
    local startX = 10
    
    for i, tabDef in ipairs(tabs) do
        local tabBtn = CreateFrame("Button", nil, f.TabStrip, "GameMenuButtonTemplate")
        tabBtn:SetSize(tabWidth, 24)
        tabBtn:SetPoint("LEFT", startX + (i-1)*(tabWidth + 5), 0)
        tabBtn:SetText(tabDef.name)
        
        tabBtn:SetScript("OnClick", function()
             Wise:SetTab(tabDef.view)
        end)
        
        f.TabButtons[tabDef.view] = tabBtn
    end

    Wise:SetTab("Editor")

    -- Headers
    f.Sidebar.Title = f.Sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.Sidebar.Title:SetPoint("TOP", 0, -5)
    f.Sidebar.Title:SetText("Wise Interfaces")

    f.Middle.Title = f.Middle:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.Middle.Title:SetPoint("TOP", 0, -5)
    f.Middle.Title:SetText("Slots and Actions")
    
    -- Main "Add Action" Button removed (Moved to new Actions View)

    f.Right.Title = f.Right:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.Right.Title:SetPoint("TOP", 0, -5)
    f.Right.Title:SetText("Properties")

    -- ScrollFrames (anchored below sticky buttons)
    f.Sidebar.Scroll = CreateFrame("ScrollFrame", nil, f.Sidebar, "UIPanelScrollFrameTemplate")
    f.Sidebar.Scroll:SetPoint("TOPLEFT", f.Sidebar.AddBtn, "BOTTOMLEFT", -10, -5)
    f.Sidebar.Scroll:SetPoint("BOTTOMRIGHT", -25, 5)
    f.Sidebar.Content = CreateFrame("Frame", nil, f.Sidebar.Scroll)
    f.Sidebar.Content:SetSize(175, 400)
    f.Sidebar.Scroll:SetScrollChild(f.Sidebar.Content)

    f.Middle.Scroll = CreateFrame("ScrollFrame", nil, f.Middle, "UIPanelScrollFrameTemplate")
    f.Middle.Scroll:SetPoint("TOPLEFT", f.Middle, "TOPLEFT", 5, -75)
    f.Middle.Scroll:SetPoint("BOTTOMRIGHT", -25, 5)
    f.Middle.Content = CreateFrame("Frame", nil, f.Middle.Scroll)
    f.Middle.Content:SetSize(260, 400)
    f.Middle.Scroll:SetScrollChild(f.Middle.Content)

    f.Right.Scroll = CreateFrame("ScrollFrame", nil, f.Right, "UIPanelScrollFrameTemplate")
    f.Right.Scroll:SetPoint("TOPLEFT", 0, -25)
    f.Right.Scroll:SetPoint("BOTTOMRIGHT", -25, 25)
    f.Right.Content = CreateFrame("Frame", nil, f.Right.Scroll)
    f.Right.Content:SetSize(250, 400) -- Initial Width
    f.Right.Scroll:SetScrollChild(f.Right.Content)

    
    -- Note: "Create Group" button is now f.Sidebar.AddBtn (sticky)
    -- Note: "Edit Mode" button is now f.EditModeBtn in TabStrip



    Wise:RefreshGroupList()
    Wise:RefreshActionsView(f.Middle.Content)
    Wise:UpdateFilterButtons()
    Wise:RefreshPropertiesPanel()
end

function Wise:UpdateFilterButtons()
    local btns = Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.FilterButtons
    if not btns then return end
    
    local current = Wise.ActionFilter or "global"
    for filter, btn in pairs(btns) do
        if filter == current then
            btn:SetEnabled(false) -- Active state
        else
            btn:SetEnabled(true)
        end
    end
end

function Wise:UpdateOptionsUI()
    if Wise.OptionsFrame and Wise.OptionsFrame:IsShown() then
        Wise:RefreshGroupList()
        Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
        Wise:RefreshPropertiesPanel()
        
        -- Refresh Conditionals if active (for one-off updates, though OnUpdate handles live)
        if Wise.currentTab == "Conditionals" then
             Wise:UpdateConditionalsValues()
        end
    end
end

function Wise:SetTab(viewName)
    local f = Wise.OptionsFrame
    if not f or not f.Views then return end
    
    Wise.currentTab = viewName
    
    for name, view in pairs(f.Views) do
        local show = (name == viewName)
        if type(view) == "table" and view.IsObjectType == nil then
             -- It's a list of frames
             for _, frame in ipairs(view) do
                 if show then frame:Show() else frame:Hide() end
             end
        else
             -- It's a single frame
             if show then view:Show() else view:Hide() end
        end
        
        -- Update Tab Button State
        local btn = f.TabButtons[name]
        if btn then
            if show then
                btn:Disable() 
            else
                btn:Enable()
            end
        end
    end
    
    -- Show/hide EditMode button only in Editor tab
    if f.EditModeBtn then
        if viewName == "Editor" then
            f.EditModeBtn:Show()
        else
            f.EditModeBtn:Hide()
        end
    end

    -- Show/Hide Filter Buttons (Global, Class, etc.)
    -- They are parented to the main frame, so we must manually toggle them.
    if f.Middle and f.Middle.FilterButtons then
        for _, btn in pairs(f.Middle.FilterButtons) do
            if viewName == "Editor" then
                btn:Show()
            else
                btn:Hide()
            end
        end
    end

    if viewName == "Conditionals" then
        Wise:UpdateConditionalsTab()
    else
        -- Stop updating conditionals when not visible
        f.Views.Conditionals:SetScript("OnUpdate", nil)
    end
    
    if viewName == "Settings" and Wise.PopulateSettingsView then
        -- Only populate if not already populated? Or refresh? Refresh is safer.
        -- But PopulateSettingsView clears children, so it's fine.
        -- Just check if we need to do it only once or on every show.
        -- Let's do it on show to ensure state is fresh.
        Wise:PopulateSettingsView(f.Views.Settings)
    end

    if viewName == "States" then
        -- Wise:RefreshStatesView(f.Views.States) -- Removed
    end
end






function Wise:RefreshGroupList()
    local container = Wise.OptionsFrame.Sidebar.Content
    -- Clear existing buttons/headers
    if container.buttons then
        for _, btn in ipairs(container.buttons) do btn:Hide() end
    end
    if container.headers then
        for _, hdr in ipairs(container.headers) do hdr:Hide() end
    end
    container.buttons = container.buttons or {}
    container.headers = container.headers or {}

    local y = -5

    -- === 1. Custom Section ===
    local customHdr = container.headers[1]
    if not customHdr then
        customHdr = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLeft")
        tinsert(container.headers, customHdr)
    end
    customHdr:Show()
    customHdr:ClearAllPoints()
    customHdr:SetPoint("TOPLEFT", 10, y)
    customHdr:SetText("Custom")
    y = y - 18

    -- Filter and Sort Groups
    local customGroups = {}
    local wiserGroups = {}
    
    for name, data in pairs(WiseDB.groups) do
        if data.isWiser then
            table.insert(wiserGroups, name)
        else
            table.insert(customGroups, name)
        end
    end
    table.sort(customGroups)
    table.sort(wiserGroups)

    -- Custom Groups List
    local btnIndex = 1
    for _, name in ipairs(customGroups) do
        local data = WiseDB.groups[name]
        local btn = container.buttons[btnIndex]
        if not btn then
            btn = CreateFrame("Button", nil, container, "BackdropTemplate")
            btn:SetSize(165, 40)
            
            -- Icon
            btn.icon = btn:CreateTexture(nil, "ARTWORK")
            btn.icon:SetSize(32, 32)
            btn.icon:SetPoint("LEFT", 5, 0)
            
            -- Label
            btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            btn.label:SetPoint("LEFT", btn.icon, "RIGHT", 10, 0)
            btn.label:SetJustifyH("LEFT")
            btn.label:SetWidth(110)
            btn.label:SetWordWrap(false)

            -- Keybind Label
            btn.kbLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.kbLabel:SetPoint("RIGHT", btn.icon, "LEFT", -5, 0)
            btn.kbLabel:SetJustifyH("RIGHT")
            btn.kbLabel:SetTextColor(1, 1, 1, 1) -- White
            
            -- Highlight
            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            
            tinsert(container.buttons, btn)
        end

        if not btn.errorIcon then
             btn.errorIcon = btn:CreateTexture(nil, "OVERLAY")
             btn.errorIcon:SetSize(16, 16)
             btn.errorIcon:SetPoint("BOTTOMRIGHT", btn.icon, "BOTTOMRIGHT", 4, -4)
             btn.errorIcon:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
             btn.errorIcon:Hide()
        end

        btn:Show()
        btn:SetPoint("TOPLEFT", 25, y)

        -- Determine Icon (Use first action's icon or default)
        local iconTexture = 134400
        if data.buttons and data.buttons[1] then
            iconTexture = Wise:GetActionIcon(data.buttons[1].type, data.buttons[1].value)
        end
        btn.icon:SetTexture(iconTexture)
        
        local hasVisErrors = Wise:HasVisibilityErrors(name)

        if hasVisErrors then
            btn.label:SetText("|cffff0000" .. name .. "|r")
            btn.errorIcon:Show()
        else
            btn.label:SetText(name)
            btn.errorIcon:Hide()
            if Wise:IsGroupDisabled(data) then
                btn.label:SetTextColor(0.5, 0.5, 0.5) -- Gray for disabled
            else
                btn.label:SetTextColor(1, 0.82, 0) -- Standard Gold
            end
        end

        -- Keybind
        local keyText = Wise:GetInterfaceListBindingText(name)
        if keyText then
            btn.kbLabel:SetText(keyText)
            btn.kbLabel:Show()
        else
            btn.kbLabel:Hide()
        end
        
        -- Logic for selection highlight
        if Wise.selectedGroup == name then
             btn:LockHighlight()
        else
             btn:UnlockHighlight()
        end
        
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(name, 1, 1, 1)
            GameTooltip:AddLine("Custom Interface", 0.8, 0.8, 1)
            if data.type then
                GameTooltip:AddLine("Type: " .. data.type, 0.7, 0.7, 0.7)
            end
            if hasVisErrors then
                GameTooltip:AddLine("Contains invalid conditionals", 1, 0, 0)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self) GameTooltip:Hide() end)

        btn:SetScript("OnClick", function()
            Wise.selectedGroup = name
            Wise.selectedSlot = nil
            Wise.selectedState = nil
            Wise:UpdateOptionsUI()
        end)
        
        y = y - 42
        btnIndex = btnIndex + 1
    end


    -- === 2. Wiser Interfaces Section ===
    y = y - 10
    local wiserHdr = container.headers[2]
    if not wiserHdr then
        wiserHdr = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLeft")
        tinsert(container.headers, wiserHdr)
    end
    wiserHdr:Show()
    wiserHdr:ClearAllPoints()
    wiserHdr:SetPoint("TOPLEFT", 10, y)
    wiserHdr:SetText("Wiser Interfaces")
    y = y - 18

    -- Wiser Groups List

    for _, name in ipairs(wiserGroups) do
         local data = WiseDB.groups[name]
         local btn = container.buttons[btnIndex]
         if not btn then
            btn = CreateFrame("Button", nil, container, "BackdropTemplate")
            btn:SetSize(165, 40)
            
            btn.icon = btn:CreateTexture(nil, "ARTWORK")
            btn.icon:SetSize(32, 32)
            btn.icon:SetPoint("LEFT", 5, 0)
            
            btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            btn.label:SetPoint("LEFT", btn.icon, "RIGHT", 10, 0)
            btn.label:SetJustifyH("LEFT")
            btn.label:SetWidth(110)
            btn.label:SetWordWrap(false)

            -- Keybind Label
            btn.kbLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.kbLabel:SetPoint("RIGHT", btn.icon, "LEFT", -5, 0)
            btn.kbLabel:SetJustifyH("RIGHT")
            btn.kbLabel:SetTextColor(1, 1, 1, 1) -- White
            
            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            
            tinsert(container.buttons, btn)
         end

         if not btn.errorIcon then
             btn.errorIcon = btn:CreateTexture(nil, "OVERLAY")
             btn.errorIcon:SetSize(16, 16)
             btn.errorIcon:SetPoint("BOTTOMRIGHT", btn.icon, "BOTTOMRIGHT", 4, -4)
             btn.errorIcon:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
             btn.errorIcon:Hide()
         end

         btn:Show()
         btn:SetPoint("TOPLEFT", 25, y)


         local isValid, err = Wise:ValidateGroup(data and name or "")
         
         local iconTexture = 134400
         if not isValid then
             iconTexture = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"
         elseif data.actions then
             -- Try to find first action icon
             for sIdx, slot in pairs(data.actions) do
                 if slot[1] then
                     iconTexture = Wise:GetActionIcon(slot[1].type, slot[1].value, slot[1])
                     break
                 end
             end
         elseif data.buttons and data.buttons[1] then
             -- Fallback for old data (should be caught by invalid but just in case)
             iconTexture = Wise:GetActionIcon(data.buttons[1].type, data.buttons[1].value)
         end
         
         btn.icon:SetTexture(iconTexture)
         
         local hasVisErrors = Wise:HasVisibilityErrors(name)

         if not isValid then
             btn.label:SetText("|cffff0000" .. name .. "|r")
             btn.errorIcon:Hide() -- Icon already shows alert
         elseif hasVisErrors then
             btn.label:SetText("|cffff0000" .. name .. "|r")
             btn.errorIcon:Show()
         else
             btn.label:SetText(name)
             if Wise:IsGroupDisabled(data) then
                 btn.label:SetTextColor(0.5, 0.5, 0.5) -- Gray for disabled
             else
                 btn.label:SetTextColor(1, 0.82, 0) -- Standard Gold
             end
         end

         -- Keybind
         local keyText = Wise:GetInterfaceListBindingText(name)
         if keyText then
             btn.kbLabel:SetText(keyText)
             btn.kbLabel:Show()
         else
             btn.kbLabel:Hide()
         end
         
         if Wise.selectedGroup == name then
              btn:LockHighlight()
         else
              btn:UnlockHighlight()
         end
         
         btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(name, 1, 1, 1)
            GameTooltip:AddLine("Wiser Interface (Built-in)", 0, 1, 0)
            if data and data.type then
                GameTooltip:AddLine("Type: " .. data.type, 0.7, 0.7, 0.7)
            end
            if not isValid then
                GameTooltip:AddLine(err or "Invalid", 1, 0, 0)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self) GameTooltip:Hide() end)

         btn:SetScript("OnClick", function()
             Wise.selectedGroup = name
             Wise.selectedSlot = nil
             Wise.selectedState = nil
             Wise:UpdateOptionsUI()
         end)
         
         y = y - 42
         btnIndex = btnIndex + 1
    end
    
    -- === 3. Tools Section ===
    y = y - 10
    local toolsHdr = container.headers[3]
    if not toolsHdr then
        toolsHdr = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLeft")
        tinsert(container.headers, toolsHdr)
    end
    toolsHdr:Show()
    toolsHdr:ClearAllPoints()
    toolsHdr:SetPoint("TOPLEFT", 10, y)
    toolsHdr:SetText("Tools")
    y = y - 18

    -- Smart Item Tool (Always show, placeholder if missing Syndicator)
    local isSyndicator = Wise:IsSyndicatorAvailable()

    local smartBtn = container.buttons[btnIndex]
    if not smartBtn then
        smartBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
        smartBtn:SetSize(165, 40)

        smartBtn.icon = smartBtn:CreateTexture(nil, "ARTWORK")
        smartBtn.icon:SetSize(32, 32)
        smartBtn.icon:SetPoint("LEFT", 5, 0)

        smartBtn.label = smartBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        smartBtn.label:SetPoint("LEFT", smartBtn.icon, "RIGHT", 10, 0)
        smartBtn.label:SetJustifyH("LEFT")
        smartBtn.label:SetWidth(110)
        smartBtn.label:SetWordWrap(false)

        -- Keybind Label
        smartBtn.kbLabel = smartBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        smartBtn.kbLabel:SetPoint("RIGHT", smartBtn.icon, "LEFT", -5, 0)
        smartBtn.kbLabel:SetJustifyH("RIGHT")
        smartBtn.kbLabel:SetTextColor(1, 1, 1, 1) -- White

        smartBtn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

        tinsert(container.buttons, smartBtn)
    end
    smartBtn:Show()
    smartBtn:SetPoint("TOPLEFT", 25, y)

    -- Special icon for Smart Item (bag icon)
    smartBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10_Blue")

    if isSyndicator then
        smartBtn.icon:SetDesaturated(false)
        smartBtn.label:SetText(Wise.SMART_ITEM_TEMPLATE or "Smart Item")

        -- Keybind
        local keyText = Wise:GetInterfaceListBindingText(Wise.SMART_ITEM_TEMPLATE)
        if keyText then
            smartBtn.kbLabel:SetText(keyText)
            smartBtn.kbLabel:Show()
        else
            smartBtn.kbLabel:Hide()
        end

        if Wise.selectedGroup == Wise.SMART_ITEM_TEMPLATE then
             smartBtn:LockHighlight()
        else
             smartBtn:UnlockHighlight()
        end

        smartBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Smart Item", 1, 1, 1)
            GameTooltip:AddLine("Dynamic item button that shows count from bags/bank.", 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        smartBtn:SetScript("OnLeave", function(self) GameTooltip:Hide() end)

        smartBtn:SetScript("OnClick", function()
            Wise.selectedGroup = Wise.SMART_ITEM_TEMPLATE
            Wise.selectedSlot = nil
            Wise.selectedState = nil
            Wise:UpdateOptionsUI()
        end)
    else
        -- Disabled State
        smartBtn.icon:SetDesaturated(true)
        smartBtn.label:SetText("Smart Item |cffaaaaaa(Missing)|r")
        smartBtn.kbLabel:Hide()
        smartBtn:UnlockHighlight()

        smartBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Smart Item Tool", 1, 1, 1)
            GameTooltip:AddLine("Functionality requires Syndicator or Baganator addon.", 1, 0, 0, true)
            GameTooltip:AddLine("Click to get download link.", 0, 1, 0)
            GameTooltip:Show()
        end)
        smartBtn:SetScript("OnLeave", function(self) GameTooltip:Hide() end)

        smartBtn:SetScript("OnClick", function()
            if not StaticPopupDialogs["WISE_COPY_URL"] then
                StaticPopupDialogs["WISE_COPY_URL"] = {
                    text = "Press Ctrl+C to copy the link:",
                    button1 = "Close",
                    OnShow = function(self)
                        local editBox = self.editBox or _G[self:GetName().."EditBox"]
                        if editBox then
                            editBox:SetFocus()
                            editBox:HighlightText()
                        end
                    end,
                    hasEditBox = true,
                    editBoxWidth = 350,
                    EditBoxOnEnterPressed = function(self)
                        local parent = self:GetParent()
                        StaticPopup_OnClick(parent, 1)
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = true,
                    preferredIndex = 3,
                }
            end

            local link = "https://www.curseforge.com/wow/addons/syndicator"
            local dialog = StaticPopup_Show("WISE_COPY_URL")
            if dialog then
                 local editBox = dialog.editBox or _G[dialog:GetName().."EditBox"]
                 if editBox then
                     editBox:SetText(link)
                     editBox:SetFocus()
                     editBox:HighlightText()
                 end
            end
        end)
    end

    y = y - 42
    btnIndex = btnIndex + 1

    -- Bar Copy Tool
    if Wise.BAR_COPY_TEMPLATE then
        local barBtn = container.buttons[btnIndex]
        if not barBtn then
            barBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
            barBtn:SetSize(165, 40)

            barBtn.icon = barBtn:CreateTexture(nil, "ARTWORK")
            barBtn.icon:SetSize(32, 32)
            barBtn.icon:SetPoint("LEFT", 5, 0)

            barBtn.label = barBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            barBtn.label:SetPoint("LEFT", barBtn.icon, "RIGHT", 10, 0)
            barBtn.label:SetJustifyH("LEFT")
            barBtn.label:SetWidth(110)
            barBtn.label:SetWordWrap(false)

            -- Keybind Label
            barBtn.kbLabel = barBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            barBtn.kbLabel:SetPoint("RIGHT", barBtn.icon, "LEFT", -5, 0)
            barBtn.kbLabel:SetJustifyH("RIGHT")
            barBtn.kbLabel:SetTextColor(1, 1, 1, 1) -- White

            barBtn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

            tinsert(container.buttons, barBtn)
        end
        barBtn:Show()
        barBtn:SetPoint("TOPLEFT", 25, y)

        barBtn.icon:SetTexture("Interface\\Icons\\Spell_Holy_BorrowedTime")
        barBtn.label:SetText(Wise.BAR_COPY_TEMPLATE)

        barBtn.kbLabel:Hide()

        if Wise.selectedGroup == Wise.BAR_COPY_TEMPLATE then
             barBtn:LockHighlight()
        else
             barBtn:UnlockHighlight()
        end

        barBtn:SetScript("OnClick", function()
            Wise.selectedGroup = Wise.BAR_COPY_TEMPLATE
            Wise.selectedSlot = nil
            Wise.selectedState = nil
            Wise:UpdateOptionsUI()
        end)

        y = y - 42
        btnIndex = btnIndex + 1
    end

    -- Hide unused buttons
    for k = btnIndex, #container.buttons do
         container.buttons[k]:Hide()
    end
    -- Hide unused headers
    for k = 4, #container.headers do
        container.headers[k]:Hide()
    end
    
    container:SetHeight(math.abs(y) + 20)
end

-- Old RefreshActionList removed.


StaticPopupDialogs["WISE_CREATE_GROUP"] = {
    text = "Enter new Wise Interface name:",
    button1 = "Create",
    button2 = "Cancel",
    hasEditBox = true,
    OnAccept = function(self)
        local editBox = self.EditBox or self.editBox
        if not editBox then return end
        local text = editBox:GetText()
        if text and text ~= "" then
            Wise:CreateGroup(text)
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
