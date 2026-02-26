local addonName, Wise = ...

Wise.Demo = {}

-- State
local currentStepIndex = 0
local demoActive = false
local timerTicker = nil
local lastCreatedGroup = nil
local tutorialClosedOnce = false  -- tracks if user closed options for the "try it" step

-- Constants
local CHECK_INTERVAL = 0.5

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Find a control in the properties panel by text match
local function FindControl(textPattern, controlType)
    if not Wise.OptionsFrame or not Wise.OptionsFrame.Right or not Wise.OptionsFrame.Right.Content then return nil end
    local controls = Wise.OptionsFrame.Right.Content.controls
    if not controls then return nil end

    for i, ctrl in ipairs(controls) do
        if ctrl:IsShown() then
            local text = nil
            if ctrl.GetText then text = ctrl:GetText() end
            if not text and ctrl.text and ctrl.text.GetText then text = ctrl.text:GetText() end

            if text and string.find(string.lower(text), string.lower(textPattern), 1, true) then
                if not controlType or ctrl:IsObjectType(controlType) then
                    return ctrl
                else
                    -- Pattern matches but type doesn't. Check adjacent controls.
                    -- Checks NEXT control (common for labels preceding buttons/inputs)
                    local nextCtrl = controls[i+1]
                    if nextCtrl and nextCtrl:IsShown() and (not controlType or nextCtrl:IsObjectType(controlType)) then
                        return nextCtrl
                    end
                    -- Checks PREVIOUS control (common for help text/hints following buttons)
                    local prevCtrl = controls[i-1]
                    if prevCtrl and prevCtrl:IsShown() and (not controlType or prevCtrl:IsObjectType(controlType)) then
                        return prevCtrl
                    end
                end
            end
        end
    end
    return nil
end

-- Find a sidebar button by group name
local function FindSidebarButton(namePattern)
    if not namePattern or namePattern == "" then return nil end
    local f = Wise.OptionsFrame
    if not f or not f.Sidebar or not f.Sidebar.Content then return nil end
    local buttons = f.Sidebar.Content.buttons
    if not buttons then return nil end

    for _, btn in ipairs(buttons) do
        if btn:IsShown() and btn.label then
            local text = btn.label:GetText()
            if text then
                local cleanText = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
                cleanText = string.gsub(cleanText, "|r", "")
                if string.find(string.lower(cleanText), string.lower(namePattern), 1, true) then
                    return btn
                end
            end
        end
    end
    return nil
end

-- Find a picker filter button by name
local function FindPickerButton(namePattern)
    local picker = Wise.EmbeddedPicker
    if not picker or not picker.SpellFilterButtons then return nil end

    for name, btn in pairs(picker.SpellFilterButtons) do
        if string.find(string.lower(name), string.lower(namePattern), 1, true) then
            return btn
        end
    end
    return nil
end

-- Glow helpers (safe nil checks)
local function Glow(frame)
    if frame and frame.IsObjectType and frame:IsObjectType("Frame") and Wise.ShowOverlayGlow then
        Wise:ShowOverlayGlow(frame)
    end
end

local function Unglow(frame)
    if frame and frame.IsObjectType and frame:IsObjectType("Frame") and Wise.HideOverlayGlow then
        Wise:HideOverlayGlow(frame)
    end
end

--------------------------------------------------------------------------------
-- Scroll Indicator (animated arrow that tells the user to scroll down)
--------------------------------------------------------------------------------
local scrollIndicator = nil

local function CreateScrollIndicator()
    if scrollIndicator then return scrollIndicator end

    local f = CreateFrame("Frame", "WiseTutorialScrollIndicator", UIParent)
    f:SetSize(80, 40)
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(9998)
    f:Hide()

    -- Arrow texture (downward pointing)
    f.Arrow = f:CreateTexture(nil, "ARTWORK")
    f.Arrow:SetSize(24, 24)
    f.Arrow:SetPoint("LEFT", 0, 0)
    f.Arrow:SetTexture("Interface\\BUTTONS\\Arrow-Down-Up")

    -- "Scroll" text
    f.Text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.Text:SetPoint("LEFT", f.Arrow, "RIGHT", 4, 0)
    f.Text:SetText("|cffFFD100Scroll|r")

    -- Bounce animation
    f.bounceGroup = f:CreateAnimationGroup()
    f.bounceGroup:SetLooping("BOUNCE")

    local translate = f.bounceGroup:CreateAnimation("Translation")
    translate:SetOffset(0, -8)
    translate:SetDuration(0.5)
    translate:SetSmoothing("IN_OUT")

    scrollIndicator = f
    return f
end

local function ShowScrollIndicator(targetControl)
    local f = CreateScrollIndicator()

    -- Anchor to the right side of the properties scroll frame
    f:ClearAllPoints()
    if Wise.OptionsFrame and Wise.OptionsFrame.Right then
        f:SetPoint("BOTTOMRIGHT", Wise.OptionsFrame.Right, "BOTTOMRIGHT", -30, 10)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 200, -100)
    end

    f:Show()
    f.bounceGroup:Play()

    -- Also try to auto-scroll to the target control
    if targetControl and Wise.OptionsFrame and Wise.OptionsFrame.Right and Wise.OptionsFrame.Right.Scroll then
        local scroll = Wise.OptionsFrame.Right.Scroll
        local content = Wise.OptionsFrame.Right.Content
        if content and targetControl.GetTop and content.GetTop then
            local contentTop = content:GetTop()
            local ctrlTop = targetControl:GetTop()
            if contentTop and ctrlTop then
                local offset = contentTop - ctrlTop - 40 -- 40px padding from top
                if offset < 0 then offset = 0 end
                local maxScroll = scroll:GetVerticalScrollRange() or 0
                if offset > maxScroll then offset = maxScroll end
                scroll:SetVerticalScroll(offset)
            end
        end
    end
end

local function HideScrollIndicator()
    if scrollIndicator then
        scrollIndicator.bounceGroup:Stop()
        scrollIndicator:Hide()
    end
end

-- Ensure the group-level properties panel is showing for the user's interface
local function EnsureGroupSelected()
    if not demoActive or not lastCreatedGroup then return end
    
    local needsRefresh = false
    if Wise.selectedGroup ~= lastCreatedGroup then
        Wise.selectedGroup = lastCreatedGroup
        needsRefresh = true
    end
    
    if Wise.selectedSlot ~= nil or Wise.selectedState ~= nil then
        Wise.selectedSlot = nil
        Wise.selectedState = nil
        needsRefresh = true
    end
    
    if needsRefresh and Wise.RefreshPropertiesPanel then 
        Wise:RefreshPropertiesPanel() 
    end
end

-- Ensure a specific slot+state is selected so properties show action-level controls
local function EnsureSlotSelected(slotIdx, stateIdx)
    Wise.selectedSlot = slotIdx
    Wise.selectedState = stateIdx or 1
    if Wise.RefreshPropertiesPanel then Wise:RefreshPropertiesPanel() end
end

--------------------------------------------------------------------------------
-- Tutorial Steps
--------------------------------------------------------------------------------
local Steps = {

    ---------------------------------------------------------------------------
    -- PHASE 1: Getting Started
    ---------------------------------------------------------------------------

    -- 1. Welcome popup - ask user to type /wise
    {
        text = "Welcome to Wise!\n\nTo begin, open the Options panel by typing /wise in chat.",
        target = function() return UIParent end,
        point = HelpTip.Point.Center,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            if not StaticPopupDialogs["WISE_TUTORIAL_START"] then
                StaticPopupDialogs["WISE_TUTORIAL_START"] = {
                    text = "Welcome to the Wise Tutorial!\n\nTo begin, please open the Options panel by typing:\n\n|cff00ff00/wise|r",
                    button1 = "Cancel Tutorial",
                    OnAccept = function()
                        Wise.Demo:Stop(false)
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = false,
                    preferredIndex = 3,
                }
            end
            StaticPopup_Show("WISE_TUTORIAL_START")
        end,
        onExit = function()
            StaticPopup_Hide("WISE_TUTORIAL_START")
            if Wise.SetTab then Wise:SetTab("Editor") end
        end,
        check = function()
            return Wise.OptionsFrame and Wise.OptionsFrame:IsShown()
        end,
    },

    -- 2. Go to Settings tab for minimap
    {
        text = "Let's enable the Minimap button for quick access.\n\nClick the 'Settings' tab.",
        target = function()
            if Wise.OptionsFrame and Wise.OptionsFrame.TabButtons then
                return Wise.OptionsFrame.TabButtons["Settings"]
            end
            return Wise.OptionsFrame
        end,
        point = HelpTip.Point.TopEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            local btn = Wise.OptionsFrame and Wise.OptionsFrame.TabButtons and Wise.OptionsFrame.TabButtons["Settings"]
            Glow(btn)
        end,
        onExit = function()
            local btn = Wise.OptionsFrame and Wise.OptionsFrame.TabButtons and Wise.OptionsFrame.TabButtons["Settings"]
            Unglow(btn)
        end,
        check = function()
            return Wise.currentTab == "Settings"
        end,
        skipIf = function()
            return WiseDB.settings.minimap and not WiseDB.settings.minimap.hide
        end,
    },

    -- 3. Check the minimap checkbox
    {
        text = "Check 'Show Minimap Button' to enable it.",
        target = function()
            if Wise.OptionsFrame and Wise.OptionsFrame.Views and Wise.OptionsFrame.Views.Settings then
                local content = Wise.OptionsFrame.Views.Settings
                if content.children then
                    for _, ctrl in ipairs(content.children) do
                        if ctrl:IsObjectType("CheckButton") and ctrl.text and ctrl.text:GetText() == "Show Minimap Button" then
                            return ctrl
                        end
                    end
                end
            end
            return Wise.OptionsFrame
        end,
        point = HelpTip.Point.RightEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            if Wise.OptionsFrame and Wise.OptionsFrame.Views and Wise.OptionsFrame.Views.Settings then
                local content = Wise.OptionsFrame.Views.Settings
                if content.children then
                    for _, ctrl in ipairs(content.children) do
                        if ctrl:IsObjectType("CheckButton") and ctrl.text and ctrl.text:GetText() == "Show Minimap Button" then
                            Glow(ctrl)
                        end
                    end
                end
            end
        end,
        onExit = function()
            if Wise.OptionsFrame and Wise.OptionsFrame.Views and Wise.OptionsFrame.Views.Settings then
                local content = Wise.OptionsFrame.Views.Settings
                if content.children then
                    for _, ctrl in ipairs(content.children) do
                        if ctrl:IsObjectType("CheckButton") and ctrl.text and ctrl.text:GetText() == "Show Minimap Button" then
                            Unglow(ctrl)
                        end
                    end
                end
            end
        end,
        check = function()
            return WiseDB.settings.minimap and not WiseDB.settings.minimap.hide
        end,
        skipIf = function()
            return WiseDB.settings.minimap and not WiseDB.settings.minimap.hide
        end,
    },

    -- 4. Close the window
    {
        text = "Great! Now close this window and reopen it using the Minimap button.",
        target = function()
            if Wise.OptionsFrame.CloseButton and Wise.OptionsFrame.CloseButton:IsShown() then
                return Wise.OptionsFrame.CloseButton
            end
            return Wise.OptionsFrame
        end,
        point = function()
            if Wise.OptionsFrame.CloseButton and Wise.OptionsFrame.CloseButton:IsShown() then
                return HelpTip.Point.LeftEdgeCenter
            end
            return HelpTip.Point.TopEdgeCenter
        end,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            if Wise.OptionsFrame.CloseButton then Glow(Wise.OptionsFrame.CloseButton) end
        end,
        onExit = function()
            if Wise.OptionsFrame.CloseButton then Unglow(Wise.OptionsFrame.CloseButton) end
        end,
        check = function()
            return not Wise.OptionsFrame:IsShown()
        end,
    },

    -- 5. Click minimap button
    {
        text = "Click the Wise minimap button to reopen the panel.",
        target = function()
            local btn = _G["LibDBIcon10_Wise"]
            return btn or UIParent
        end,
        point = HelpTip.Point.BottomEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            local btn = _G["LibDBIcon10_Wise"]
            Glow(btn)
        end,
        onExit = function()
            local btn = _G["LibDBIcon10_Wise"]
            Unglow(btn)
            if Wise.SetTab then Wise:SetTab("Editor") end
        end,
        check = function()
            return Wise.OptionsFrame and Wise.OptionsFrame:IsShown()
        end,
    },

    ---------------------------------------------------------------------------
    -- PHASE 2: Your First Interface
    ---------------------------------------------------------------------------

    -- 6. Create a new interface
    {
        text = "Let's create your first Interface.\n\nClick 'New Wise Interface' in the sidebar.",
        target = function()
            return Wise.OptionsFrame.Sidebar.AddBtn or Wise.OptionsFrame.Sidebar
        end,
        point = HelpTip.Point.RightEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            local btn = Wise.OptionsFrame and Wise.OptionsFrame.Sidebar and Wise.OptionsFrame.Sidebar.AddBtn
            Glow(btn)
        end,
        onExit = function()
            local btn = Wise.OptionsFrame and Wise.OptionsFrame.Sidebar and Wise.OptionsFrame.Sidebar.AddBtn
            Unglow(btn)
        end,
        check = function()
            return StaticPopup_Visible("WISE_CREATE_GROUP")
        end,
    },

    -- 7. Name it and click Create
    {
        text = "Type a name for your interface (e.g. 'My Spells') and click Accept.",
        target = function() return _G["StaticPopup1"] or UIParent end,
        point = HelpTip.Point.TopEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            lastCreatedGroup = nil
        end,
        check = function()
            return lastCreatedGroup ~= nil
        end,
    },

    -- 8. Select your new interface in the sidebar
    {
        text = "Your interface was created! Click it in the sidebar under 'Custom' to select it.",
        target = function()
            return Wise.OptionsFrame.Sidebar
        end,
        point = HelpTip.Point.RightEdgeTop,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            local btn = FindSidebarButton(lastCreatedGroup)
            Glow(btn)
        end,
        onExit = function()
            local btn = FindSidebarButton(lastCreatedGroup)
            Unglow(btn)
        end,
        check = function()
            return Wise.selectedGroup == lastCreatedGroup
        end,
    },

    -- 9. Add first slot
    {
        text = "Your interface is empty. Let's add an action slot.\n\nClick 'Add New Slot'.",
        target = function()
            return Wise.OptionsFrame.Middle.AddSlotBtn or Wise.OptionsFrame.Middle
        end,
        point = HelpTip.Point.RightEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            local btn = Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.AddSlotBtn
            Glow(btn)
        end,
        onExit = function()
            local btn = Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.AddSlotBtn
            Unglow(btn)
        end,
        check = function()
            local g = WiseDB.groups[Wise.selectedGroup]
            return g and g.actions and #g.actions >= 1
        end,
    },

    -- 10. Click "Change Action" to open the picker
    {
        text = "Now let's assign a spell to this slot.\n\nClick 'Change Action' in the Properties panel on the right.",
        target = function()
            return Wise.OptionsFrame.Right
        end,
        point = HelpTip.Point.LeftEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            if not Wise.selectedSlot then
                Wise.selectedSlot = 1
                Wise.selectedState = 1
                if Wise.RefreshPropertiesPanel then Wise:RefreshPropertiesPanel() end
            end
            local btn = FindControl("Change Action", "Button")
            Glow(btn)
        end,
        onExit = function()
            local btn = FindControl("Change Action", "Button")
            Unglow(btn)
        end,
        check = function()
            return Wise.pickingAction
        end,
    },

    -- 11. Pick any spell
    {
        text = "Browse or search for a spell you use often, then click it to assign it.\n\nTry the 'In-Spec' filter to see your current specialization's spells.",
        target = function()
            -- EmbeddedPicker is a plain table, not a Frame - use the Right panel host
            if Wise.OptionsFrame and Wise.OptionsFrame.Right and Wise.OptionsFrame.Right.PickerHost then
                return Wise.OptionsFrame.Right.PickerHost
            end
            return Wise.OptionsFrame.Right
        end,
        point = HelpTip.Point.LeftEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            local btn = FindPickerButton("In-Spec")
            Glow(btn)
        end,
        onExit = function()
            local btn = FindPickerButton("In-Spec")
            Unglow(btn)
        end,
        check = function()
            local g = WiseDB.groups[Wise.selectedGroup]
            local action = g and g.actions and g.actions[1] and g.actions[1][1]
            return action and action.type and action.type ~= "empty"
        end,
    },

    -- 12. Drag & drop a second action
    {
        text = "You can also add actions by dragging!\n\nOpen your Spellbook (P), then drag any spell onto the 'Add New Slot' area in the middle column.",
        target = function()
            return Wise.OptionsFrame.Middle.AddSlotBtn or Wise.OptionsFrame.Middle
        end,
        point = HelpTip.Point.RightEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            local btn = Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.AddSlotBtn
            Glow(btn)
        end,
        onExit = function()
            local btn = Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.AddSlotBtn
            Unglow(btn)
        end,
        check = function()
            local g = WiseDB.groups[Wise.selectedGroup]
            return g and g.actions and #g.actions >= 2
        end,
        skipIf = function()
            return WiseDB.settings.enableDragDrop == false
        end,
    },

    ---------------------------------------------------------------------------
    -- PHASE 3: Make It Visible
    ---------------------------------------------------------------------------

    -- 13. Set a keybind
    {
        text = "Your interface needs a way to appear!\n\nClick the Keybind button and press a key (e.g. Z or a mouse button).\n\nYou may need to scroll down in the properties panel.",
        target = function()
            return Wise.OptionsFrame.Right
        end,
        point = HelpTip.Point.LeftEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            -- Make sure group-level properties are showing
            EnsureGroupSelected()
            
            -- Wait longer to ensure the UI has updated its layout coordinates and frame sizes
            C_Timer.After(0.1, function()
                local btn = FindControl("Keybind", "Button") 
                         or FindControl("Assign a keybind", "Button")
                         or FindControl("None", "Button")
                         or FindControl("Press", "Button")

                if btn then
                    Glow(btn)
                    ShowScrollIndicator(btn)
                end
            end)
        end,
        onExit = function()
            local btn = FindControl("None", "Button") or FindControl("Keybind", "Button")
            Unglow(btn)
            HideScrollIndicator()
        end,
        check = function()
            local g = WiseDB.groups[lastCreatedGroup]
            return g and g.binding and g.binding ~= ""
        end,
    },

    -- 14. Set visibility to "Hold to Show"
    {
        text = "Now choose how the keybind works.\n\nCheck 'Hold to Show' so your interface appears while you hold the key.\n\nScroll down if you don't see it.",
        target = function()
            return Wise.OptionsFrame.Right
        end,
        point = HelpTip.Point.LeftEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            EnsureGroupSelected()
            C_Timer.After(0.1, function()
                local btn = FindControl("Hold to Show", "CheckButton")
                Glow(btn)
                ShowScrollIndicator(btn)
            end)
        end,
        onExit = function()
            local btn = FindControl("Hold to Show", "CheckButton")
            Unglow(btn)
            HideScrollIndicator()
        end,
        check = function()
            local g = WiseDB.groups[lastCreatedGroup]
            return g and g.visibilitySettings and g.visibilitySettings.held == true
        end,
    },

    -- 15. Close options and try the keybind
    {
        text = "Let's try it out!\n\nClose this window, then hold your keybind to see your interface appear. Move your mouse over a spell and release to cast it.",
        target = function()
            if Wise.OptionsFrame.CloseButton and Wise.OptionsFrame.CloseButton:IsShown() then
                return Wise.OptionsFrame.CloseButton
            end
            return Wise.OptionsFrame
        end,
        point = HelpTip.Point.TopEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            tutorialClosedOnce = false
            if Wise.OptionsFrame.CloseButton then Glow(Wise.OptionsFrame.CloseButton) end
        end,
        onExit = function()
            if Wise.OptionsFrame.CloseButton then Unglow(Wise.OptionsFrame.CloseButton) end
        end,
        check = function()
            return Wise.OptionsFrame and not Wise.OptionsFrame:IsShown()
        end,
    },

    -- 15b. Prompt to reopen settings
    {
        text = "Try holding your keybind to see your interface!\n\nWhen you're ready to continue, reopen settings with |cff00ff00/wise|r or the minimap button.",
        target = function() return UIParent end,
        point = HelpTip.Point.TopEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            local btn = _G["LibDBIcon10_Wise"]
            Glow(btn)
        end,
        onExit = function()
            local btn = _G["LibDBIcon10_Wise"]
            Unglow(btn)
            -- Restore editor tab and select the tutorial group
            if Wise.SetTab then Wise:SetTab("Editor") end
            if lastCreatedGroup then
                Wise.selectedGroup = lastCreatedGroup
                if Wise.UpdateOptionsUI then Wise:UpdateOptionsUI() end
            end
        end,
        check = function()
            return Wise.OptionsFrame and Wise.OptionsFrame:IsShown()
        end,
    },

    ---------------------------------------------------------------------------
    -- PHASE 4: Layout & Positioning
    ---------------------------------------------------------------------------

    -- 16. Change layout to Line
    {
        text = "Wise supports different layouts.\n\nSelect your interface in the sidebar, then change the Interface Mode from 'Circle' to 'Line' in the properties panel.",
        target = function()
            return Wise.OptionsFrame.Right
        end,
        point = HelpTip.Point.LeftEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            -- Make sure our tutorial group is selected and showing group props
            if Wise.selectedGroup ~= lastCreatedGroup then
                Wise.selectedGroup = lastCreatedGroup
                if Wise.UpdateOptionsUI then Wise:UpdateOptionsUI() end
            end
            EnsureGroupSelected()
            local btn = FindControl("Line", "CheckButton")
            Glow(btn)
            ShowScrollIndicator(btn)
        end,
        onExit = function()
            local btn = FindControl("Line", "CheckButton")
            Unglow(btn)
            HideScrollIndicator()
        end,
        check = function()
            local g = WiseDB.groups[lastCreatedGroup]
            return g and g.type == "line"
        end,
    },

    -- 17. Toggle Edit Mode ON
    {
        text = "Now let's position your interface on screen.\n\nClick 'Edit Mode' to start dragging.",
        target = function()
            return Wise.OptionsFrame.EditModeBtn or Wise.OptionsFrame
        end,
        point = HelpTip.Point.TopEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            Glow(Wise.OptionsFrame.EditModeBtn)
        end,
        onExit = function()
            Unglow(Wise.OptionsFrame.EditModeBtn)
        end,
        check = function()
            return Wise.editMode == true
        end,
    },

    -- 18. Drag & lock
    {
        text = "Drag your interface to your preferred position.\n\nWhen you're happy, click 'Edit Mode' again to lock it in place.",
        target = function()
            return Wise.OptionsFrame.EditModeBtn or Wise.OptionsFrame
        end,
        point = HelpTip.Point.TopEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            Glow(Wise.OptionsFrame.EditModeBtn)
        end,
        onExit = function()
            Unglow(Wise.OptionsFrame.EditModeBtn)
        end,
        check = function()
            return Wise.editMode == false
        end,
    },

    ---------------------------------------------------------------------------
    -- PHASE 5: Multi-State (Advanced Preview)
    ---------------------------------------------------------------------------

    -- 19. Add a second state to slot 1
    {
        text = "A slot can hold multiple actions that swap based on conditions!\n\nClick the '+' button on Slot 1 to add a second state.",
        target = function()
            return Wise.OptionsFrame.Middle
        end,
        point = HelpTip.Point.RightEdgeTop,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            local slots = Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.Content and Wise.OptionsFrame.Middle.Content.slots
            local btn = slots and slots[1] and slots[1].AddStateBtn
            Glow(btn)
        end,
        onExit = function()
            local slots = Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.Content and Wise.OptionsFrame.Middle.Content.slots
            local btn = slots and slots[1] and slots[1].AddStateBtn
            Unglow(btn)
        end,
        check = function()
            local g = WiseDB.groups[Wise.selectedGroup]
            return g and g.actions and g.actions[1] and #g.actions[1] >= 2
        end,
    },

    -- 20. Pick a second spell for that state
    {
        text = "Pick a different spell for this second state.\n\nThis could be an Off-Spec ability, a utility, or anything you like.",
        target = function()
            if Wise.OptionsFrame and Wise.OptionsFrame.Right and Wise.OptionsFrame.Right.PickerHost then
                return Wise.OptionsFrame.Right.PickerHost
            end
            return Wise.OptionsFrame.Right
        end,
        point = HelpTip.Point.LeftEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        check = function()
            local g = WiseDB.groups[Wise.selectedGroup]
            local action = g and g.actions and g.actions[1] and g.actions[1][2]
            return action and action.type and action.type ~= "empty"
        end,
    },

    -- 21. Set a condition on the first state
    {
        text = "Now let's make them swap automatically.\n\nClick on the FIRST state in Slot 1, then type [combat] in the Conditions field.\n\nThis means that spell will only be active during combat.",
        target = function()
            return Wise.OptionsFrame.Right
        end,
        point = HelpTip.Point.LeftEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            -- Select slot 1, state 1 to show its conditions
            EnsureSlotSelected(1, 1)
            local btn = FindControl("Conditions", "EditBox")
            Glow(btn)
            ShowScrollIndicator(btn)
        end,
        onExit = function()
            local btn = FindControl("Conditions", "EditBox")
            Unglow(btn)
            HideScrollIndicator()
        end,
        check = function()
            local g = WiseDB.groups[Wise.selectedGroup]
            local action = g and g.actions and g.actions[1] and g.actions[1][1]
            return action and action.conditions and action.conditions ~= ""
        end,
    },

    ---------------------------------------------------------------------------
    -- PHASE 6: Explore Built-ins & Finale
    ---------------------------------------------------------------------------

    -- 22. Look at a Wiser interface
    {
        text = "Wise comes with built-in 'Wiser' interfaces that auto-populate.\n\nClick the 'Specs' interface in the sidebar to see one.",
        target = function()
            return Wise.OptionsFrame.Sidebar
        end,
        point = HelpTip.Point.RightEdgeTop,
        buttonStyle = HelpTip.ButtonStyle.None,
        onEnter = function()
            local btn = FindSidebarButton("Specs")
            Glow(btn)
        end,
        onExit = function()
            local btn = FindSidebarButton("Specs")
            Unglow(btn)
        end,
        check = function()
            return Wise.selectedGroup == "Specs"
        end,
    },

    -- 23. Finale
    {
        text = "Tutorial Complete!\n\nYou've learned the basics of Wise:\n"
            .. "- Creating interfaces and adding action slots\n"
            .. "- Using the picker and drag-and-drop\n"
            .. "- Binding keys and visibility modes\n"
            .. "- Changing layouts and positioning\n"
            .. "- Multi-state slots with conditions\n\n"
            .. "Keep exploring! Try:\n"
            .. "- Nesting interfaces inside each other\n"
            .. "- The Bar Copy and Smart Item tools\n"
            .. "- Import/Export to share setups\n"
            .. "- The Conditionals tab for a full reference",
        target = function()
            return Wise.OptionsFrame
        end,
        point = HelpTip.Point.TopEdgeCenter,
        buttonStyle = HelpTip.ButtonStyle.GotIt,
        check = function()
            return false -- only advances via GotIt button
        end,
    },
}

--------------------------------------------------------------------------------
-- Overlay Frame (Persistent Tutorial Controls at top of screen)
--------------------------------------------------------------------------------
local overlayFrame = nil
local function CreateOverlay()
    if overlayFrame then return overlayFrame end

    local f = CreateFrame("Frame", "WiseTutorialOverlay", UIParent, "BackdropTemplate")
    f:SetSize(320, 100)
    f:SetPoint("TOP", 0, -10)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(9000)

    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    -- Logo
    f.Logo = f:CreateTexture(nil, "ARTWORK")
    f.Logo:SetSize(40, 40)
    f.Logo:SetPoint("LEFT", 20, 5)
    f.Logo:SetTexture("Interface\\AddOns\\Wise\\Media\\WiseLogo")
    f.Logo:SetTexCoord(-0.031, 1.051, -0.020, 1.062)

    -- Step counter
    f.StepText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.StepText:SetPoint("TOPLEFT", f.Logo, "TOPRIGHT", 10, -2)
    f.StepText:SetTextColor(0.7, 0.7, 0.7)
    f.StepText:SetText("Step 1 / " .. #Steps)

    -- Stop Button
    f.StopBtn = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
    f.StopBtn:SetSize(140, 26)
    f.StopBtn:SetPoint("TOPRIGHT", -15, -15)
    f.StopBtn:SetText("Stop Tutorial")
    f.StopBtn:SetScript("OnClick", function()
        if f.DontShowCheck and f.DontShowCheck:GetChecked() then
            WiseDB.tutorialComplete = true
        end
        Wise.Demo:Stop(false)
    end)

    -- Don't Show Again Checkbox
    f.DontShowCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.DontShowCheck:SetSize(24, 24)
    f.DontShowCheck:SetPoint("TOPRIGHT", f.StopBtn, "BOTTOMRIGHT", 0, -4)

    f.DontShowCheck.text:SetText("Don't show again")
    f.DontShowCheck.text:ClearAllPoints()
    f.DontShowCheck.text:SetPoint("RIGHT", f.DontShowCheck, "LEFT", -5, 0)

    overlayFrame = f
    return f
end

-- Update the step counter text
local function UpdateOverlayStep(index)
    if overlayFrame and overlayFrame.StepText then
        overlayFrame.StepText:SetText("Step " .. index .. " / " .. #Steps)
    end
end

--------------------------------------------------------------------------------
-- Core Demo Logic
--------------------------------------------------------------------------------

function Wise.Demo:Start()
    if demoActive then return end
    demoActive = true
    currentStepIndex = 1
    tutorialClosedOnce = false
    lastCreatedGroup = nil

    local overlay = CreateOverlay()
    if overlay.DontShowCheck then
        overlay.DontShowCheck:SetChecked(WiseDB.tutorialComplete)
    end
    overlay:Show()
    UpdateOverlayStep(1)

    -- Start Polling
    if timerTicker then timerTicker:Cancel() end
    timerTicker = C_Timer.NewTicker(CHECK_INTERVAL, function()
        Wise.Demo:CheckStep()
    end)

    Wise.Demo:ShowStep(currentStepIndex)
end

-- Hook CreateGroup to capture the name of newly created groups
local origCreateGroup = Wise.CreateGroup
function Wise:CreateGroup(name, groupType)
    if demoActive then
        lastCreatedGroup = name
    end
    return origCreateGroup(Wise, name, groupType)
end

function Wise.Demo:Stop(finished)
    demoActive = false
    if timerTicker then timerTicker:Cancel() end
    HelpTip:HideAllSystem("WiseDemo")
    HideScrollIndicator()

    if overlayFrame then overlayFrame:Hide() end

    if finished then
        WiseDB.tutorialComplete = true
        print("|cff00ccff[Wise]|r Tutorial complete! Enjoy building your interfaces.")
    end
end

function Wise.Demo:ShowStep(index)
    if index > #Steps then
        self:Stop(true)
        return
    end

    local step = Steps[index]

    -- Check for skip
    if step.skipIf and step.skipIf() then
        currentStepIndex = index + 1
        self:ShowStep(currentStepIndex)
        return
    end

    UpdateOverlayStep(index)

    if step.onEnter then step.onEnter() end

    local target = step.target()
    if not target then
        -- Target not available yet, wait for next poll
        return
    end

    local targetPoint = type(step.point) == "function" and step.point() or step.point
    local info = {
        text = step.text,
        buttonStyle = step.buttonStyle,
        targetPoint = targetPoint or HelpTip.Point.TopEdgeCenter,
        system = "WiseDemo",
        onAcknowledge = function()
            if step.buttonStyle == HelpTip.ButtonStyle.GotIt then
                self:Advance()
            end
        end,
        callbackArg = nil,
    }

    HelpTip:Show(target, info)

    -- Force HelpTip to TOOLTIP strata so it is never obstructed
    if HelpTip.framePool and HelpTip.framePool.activeObjects then
        for frame, _ in pairs(HelpTip.framePool.activeObjects) do
            if frame:IsShown() and frame.system == "WiseDemo" then
                frame:SetFrameStrata("TOOLTIP")
                frame:SetFrameLevel(9999)
            end
        end
    end
end

function Wise.Demo:CheckStep()
    if not demoActive then return end

    local step = Steps[currentStepIndex]
    if not step then return end

    -- Re-show the HelpTip if the target reappeared after being hidden
    -- Guard: only call IsShowing on valid WoW Frame objects (must have IsObjectType)
    local target = step.target()
    if target and target.IsObjectType then
        if not HelpTip:IsShowing(target, step.text) then
            if target.IsShown and target:IsShown() then
                self:ShowStep(currentStepIndex)
            end
        end
    end

    -- Re-force strata every tick to guarantee visibility
    if HelpTip.framePool and HelpTip.framePool.activeObjects then
        for frame, _ in pairs(HelpTip.framePool.activeObjects) do
            if frame:IsShown() and frame.system == "WiseDemo" then
                frame:SetFrameStrata("TOOLTIP")
                frame:SetFrameLevel(9999)
            end
        end
    end

    if step.check and step.check() then
        self:Advance()
    end
end

function Wise.Demo:Advance()
    local step = Steps[currentStepIndex]
    if step and step.onExit then step.onExit() end

    -- Hide tip on current target
    if step then
        local target = step.target()
        if target then HelpTip:Hide(target, step.text) end
    end

    currentStepIndex = currentStepIndex + 1
    self:ShowStep(currentStepIndex)
end

-- Hook ToggleOptions to always default to Editor tab
local origToggleOptions = Wise.ToggleOptions
function Wise.ToggleOptions(self)
    if origToggleOptions then origToggleOptions(self) end
    if Wise.OptionsFrame and Wise.OptionsFrame:IsShown() and Wise.SetTab then
        Wise:SetTab("Editor")
    end
end
