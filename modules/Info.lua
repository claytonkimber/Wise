-- Info.lua
local addonName, Wise = ...

function Wise:CreateInfoView(parent)
    local f = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
    f:SetPoint("TOPLEFT", 10, -30)
    f:SetPoint("BOTTOMRIGHT", -10, 40)
    f:Hide()
    
    f.Title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.Title:SetPoint("TOP", 0, -10)
    f.Title:SetText("Info")
     
    -- Use SimpleHTML for clickable links
    f.Content = CreateFrame("SimpleHTML", nil, f)
    f.Content:SetPoint("TOPLEFT", 20, -40)
    f.Content:SetPoint("BOTTOMRIGHT", -20, 20)
    
    -- Define fonts for SimpleHTML
    local h1Font, h1Height, h1Flags = GameFontNormalHuge:GetFont()
    f.Content:SetFont("h1", h1Font, h1Height, h1Flags)
    
    local h2Font, h2Height, h2Flags = GameFontNormalLarge:GetFont()
    f.Content:SetFont("h2", h2Font, h2Height, h2Flags)
    
    local pFont, pHeight, pFlags = GameFontHighlight:GetFont()
    f.Content:SetFont("p", pFont, pHeight, pFlags)
 

    -- Handle hyperlinks
    f.Content:SetScript("OnHyperlinkClick", function(self, link, text, button)
        if link:sub(1, 4) == "http" then
            -- Show popup to copy URL
            if not StaticPopupDialogs["WISE_COPY_URL"] then
                StaticPopupDialogs["WISE_COPY_URL"] = {
                    text = "Press Ctrl+C to copy the link:",
                    button1 = "Close",
                    OnShow = function(self)
                        -- Try to find the edit box safely
                        local editBox = self.editBox
                        if not editBox and self.GetName then
                            editBox = _G[self:GetName().."EditBox"]
                        end
                        
                        if editBox then
                            editBox:SetFocus()
                            -- We can't highlight text yet because it hasn't been set by the caller
                            -- The caller will handle SetText and HighlightText
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
            
            -- Pass URL to the dialog
            local dialog = StaticPopup_Show("WISE_COPY_URL")
            if dialog then
                 local editBox = dialog.editBox or _G[dialog:GetName().."EditBox"]
                 if editBox then
                     editBox:SetText(link)
                     editBox:SetFocus()
                     editBox:HighlightText()
                 end
            end
        end
    end)
    
    local version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "Unknown"
    local author = C_AddOns.GetAddOnMetadata(addonName, "Author") or "Wise"
    
    f.Content:SetText(string.format([[
        <html><body>
        <h1>Wise Addon</h1>
        <p>Version: %s</p>
        <p>Author: %s</p>
        <br/>
        <h2>Credits</h2>
        <p>Created with love by the Wise team.</p>
        <p>To Foxlit for their amazing work on <a href="https://www.curseforge.com/wow/addons/opie">|cff33ccffOPie|r</a>, which is the basis of this work</p>
        <br/>
        <h2>Acknowledgements</h2>
        <p>This project includes samples from the following amazing addons:</p>
        <p>- <a href="https://www.curseforge.com/wow/addons/cooldownmanagercentered">|cff33ccffCooldownManagerCentered|r</a> by WilduTools</p>
        <p>- <a href="https://www.curseforge.com/wow/addons/enhance-qol">|cff33ccffEnhanceQoL|r</a> by R41Z0R</p>
        <p>- <a href="https://www.curseforge.com/wow/addons/opie">|cff33ccffOPie|r</a> by Foxlit</p>
        <p>- <a href="https://www.curseforge.com/wow/addons/cooldownhighlighter">|cff33ccffCooldownHighlighter|r</a> by Owenwilson</p>
        <p>- <a href="https://www.curseforge.com/wow/addons/procglows">|cff33ccffProcGlows|r</a> by muleyo</p>
        <br/>
        <h2>Support Development</h2>
        <p>If you enjoy this addon, consider buying me a coffee!</p>
        <p><a href="https://ko-fi.com/wiseaddon">|cff33ccffhttps://ko-fi.com/wiseaddon|r</a></p>
        </body></html>
    ]], version, author))
    
    -- Debug Checkbox (Moved to TabStrip area)
    -- Parent to TabStrip so it sits inline with the tabs
    if parent.TabStrip then
        f.DebugCheck = CreateFrame("CheckButton", nil, parent.TabStrip, "UICheckButtonTemplate")
        f.DebugCheck:SetPoint("RIGHT", parent.TabStrip, "RIGHT", 0, 0)
    else
        -- Fallback if TabStrip not found (should not happen based on Options.lua)
        f.DebugCheck = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        f.DebugCheck:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -10, 10)
    end
    
    f.DebugCheck:SetSize(24, 24) -- Standardize size
    f.DebugCheck:Hide() -- Start hidden, matching Info view state
    
    -- Text on Left
    f.DebugCheck.text:ClearAllPoints()
    f.DebugCheck.text:SetPoint("RIGHT", f.DebugCheck, "LEFT", -5, 0)
    f.DebugCheck.text:SetText("Enable Debug Mode")
    
    f.DebugCheck:SetChecked(WiseDB.settings.debug)
    
    f.DebugCheck:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        WiseDB.settings.debug = checked
        print("|cff00ccff[Wise]|r Debug mode " .. (checked and "enabled" or "disabled"))
    end)

    -- Bug Report Button
    f.BugReportBtn = CreateFrame("Button", nil, f.DebugCheck:GetParent(), "UIPanelButtonTemplate")
    f.BugReportBtn:SetSize(100, 24)
    f.BugReportBtn:SetText("Bug Report")
    -- Anchor to the left of the Debug Checkbox text
    f.BugReportBtn:SetPoint("RIGHT", f.DebugCheck.text, "LEFT", -10, 0)
    f.BugReportBtn:Hide()

    f.BugReportBtn:SetScript("OnClick", function()
        if Wise.ShowBugReportWindow then
            Wise:ShowBugReportWindow()
        else
            print("|cff00ccff[Wise]|r Bug Report module not loaded.")
        end
    end)
    
    -- Manage Visibility: Only show when Info view is shown
    f:HookScript("OnShow", function()
        f.DebugCheck:Show()
        f.BugReportBtn:Show()
    end)
    
    f:HookScript("OnHide", function()
        f.DebugCheck:Hide()
        f.BugReportBtn:Hide()
    end)
    
    -- Play Demo Button
    local demoBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    demoBtn:SetSize(120, 24)
    demoBtn:SetText("Play Tutorial")
    demoBtn:SetPoint("BOTTOMLEFT", 20, 10)
    demoBtn:SetScript("OnClick", function()
        if Wise.Demo then 
            -- Force stop to reset state in case it's stuck or finished
            Wise.Demo:Stop()

            -- Close options to ensure Step 1 (Welcome on UIParent) is visible and makes sense
            if Wise.OptionsFrame then Wise.OptionsFrame:Hide() end

            -- Start Demo
            Wise.Demo:Start()
        else
            print("|cff00ccff[Wise]|r Demo module not loaded.")
        end
    end)
    
    return f
end
