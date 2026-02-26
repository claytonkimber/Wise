local addonName, Wise = ...

-- Helper: URL Encode
local function urlEncode(str)
    if (str) then
        str = string.gsub (str, "\n", "\r\n")
        str = string.gsub (str, "([^%w %-%_%.%~])",
            function (c) return string.format ("%%%02X", string.byte(c)) end)
        str = string.gsub (str, " ", "+")
    end
    return str
end

function Wise:CreateBugReportWindow()
    if Wise.BugReportFrame then return Wise.BugReportFrame end

    local f = CreateFrame("Frame", "WiseBugReportFrame", UIParent, "PortraitFrameTemplate")
    f:Hide()
    f:SetSize(600, 500)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetTitle("Wise Bug Report")

    -- Portrait
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

    Wise.BugReportFrame = f

    -- Instructions
    f.Instructions = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.Instructions:SetPoint("TOPLEFT", 20, -40)
    f.Instructions:SetPoint("TOPRIGHT", -20, -40)
    f.Instructions:SetJustifyH("LEFT")
    f.Instructions:SetText("Please describe the issue you are experiencing below:")

    -- EditBox Container (ScrollFrame)
    f.Scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    f.Scroll:SetPoint("TOPLEFT", 20, -70)
    f.Scroll:SetPoint("BOTTOMRIGHT", -40, 80)

    -- EditBox
    f.EditBox = CreateFrame("EditBox", nil, f.Scroll)
    f.EditBox:SetMultiLine(true)
    f.EditBox:SetSize(520, 400) -- Initial size
    f.EditBox:SetFontObject(ChatFontNormal)
    f.EditBox:SetAutoFocus(false)
    f.Scroll:SetScrollChild(f.EditBox)

    -- Backdrop for visual clarity
    f.Scroll.Backdrop = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.Scroll.Backdrop:SetPoint("TOPLEFT", f.Scroll, -5, 5)
    f.Scroll.Backdrop:SetPoint("BOTTOMRIGHT", f.Scroll, 25, -5)
    f.Scroll.Backdrop:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    f.Scroll.Backdrop:SetBackdropColor(0, 0, 0, 0.5)

    -- Generate Button
    f.GenerateBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.GenerateBtn:SetSize(250, 30)
    f.GenerateBtn:SetPoint("BOTTOM", 0, 30)
    f.GenerateBtn:SetText("Press this button to file bug")

    f.GenerateBtn:SetScript("OnClick", function()
        Wise:GenerateBugReportLink()
    end)

    -- Subtext
    f.Subtext = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.Subtext:SetPoint("TOP", f.GenerateBtn, "BOTTOM", 0, -5)
    f.Subtext:SetText("(Copies a link to your clipboard to paste in browser)")

    return f
end

function Wise:ShowBugReportWindow()
    local f = Wise:CreateBugReportWindow()
    -- Reset Instructions
    f.Instructions:SetText("Please describe the issue you are experiencing below:")
    f:Show()
    f.EditBox:SetFocus()
end

function Wise:CaptureRuntimeState()
    local state = {}

    -- 1. GUI State
    state.gui = {
        optionsOpen = Wise.OptionsFrame and Wise.OptionsFrame:IsShown(),
        currentTab = Wise.currentTab,
        selectedGroup = Wise.selectedGroup,
        selectedSlot = Wise.selectedSlot,
        editMode = Wise.editMode,
    }

    -- 2. Interface States
    state.interfaces = {}
    if Wise.frames then
        for name, frame in pairs(Wise.frames) do
            local fState = {
                shown = frame:IsShown(),
                alpha = frame:GetAlpha(),
                scale = frame:GetScale(),
                strata = frame:GetFrameStrata(),
                -- Secure Attributes
                attr_game = frame:GetAttribute("state-game"),
                attr_manual = frame:GetAttribute("state-manual"),
                attr_custom = frame:GetAttribute("state-custom"),
                attr_wise_show = frame:GetAttribute("state-wise-show"),
                attr_wise_hide = frame:GetAttribute("state-wise-hide"),
                attr_dependencies = frame:GetAttribute("wise_dependencies"),
            }
            state.interfaces[name] = fState
        end
    end

    -- 3. Conditionals
    state.conditionals = {}
    local function CheckList(list, listName)
        if not list then return end
        for _, item in ipairs(list) do
            if item.type ~= "header" then
                local isActive = false
                if item.combatRestricted and InCombatLockdown() then
                    isActive = "RESTRICTED"
                elseif item.skipeval then
                    isActive = "SKIPPED"
                elseif listName == "wise" then
                    -- Custom Wise check
                    if Wise.EvaluateCustomCondition then
                         isActive = Wise:EvaluateCustomCondition(item.name)
                    end
                else
                    -- Standard SecureCmdOptionParse
                    local result = SecureCmdOptionParse(string.format("[%s] true; false", item.name))
                    isActive = (result == "true")
                end

                if isActive == true then
                    table.insert(state.conditionals, item.name)
                elseif isActive == "RESTRICTED" then
                    table.insert(state.conditionals, item.name .. " (Restricted)")
                end
            end
        end
    end

    CheckList(Wise.builtinConditionals, "builtin")
    CheckList(Wise.opieConditionals, "wise")

    -- 4. System State
    state.system = {
        combat = InCombatLockdown(),
        affectingCombat = UnitAffectingCombat("player"),
        zone = GetRealZoneText(),
        subzone = GetSubZoneText(),
        spec = GetSpecialization(),
        specID = GetSpecializationInfo(GetSpecialization() or 0),
        mounted = IsMounted(),
        indoors = IsIndoors(),
        outdoors = IsOutdoors(),
        stealth = IsStealthed(),
        flying = IsFlying(),
        swimming = IsSwimming(),
        resting = IsResting(),
    }

    -- 5. Debug Log (Last 2000 chars)
    if Wise.LogFrame and Wise.LogFrame.GetText then
        local log = Wise.LogFrame:GetText()
        if log and #log > 0 then
            state.debugLog = log:sub(-2000)
        end
    end

    return state
end

function Wise:GenerateBugReportLink()
    local f = Wise.BugReportFrame
    local description = f.EditBox:GetText() or ""

    -- Gather Info
    local info = {
        version = C_AddOns.GetAddOnMetadata(addonName, "Version"),
        wow_version = GetBuildInfo(),
        date = date(),
        character = Wise.characterInfo,
    }

    -- Capture Runtime State
    local runtime = Wise:CaptureRuntimeState()

    -- Serialize Settings & Groups & Runtime
    local exportData = {
        settings = WiseDB.settings,
        groups = WiseDB.groups,
        info = info,
        runtime = runtime,
        description = description
    }

    local serialized = Wise:Serialize(exportData)

    -- Construct Body
    -- Simplified format for readability, user copies serialized blob anyway
    local body = "**Description:**\n" .. description .. "\n\n" ..
                 "**Environment:**\n" ..
                 "Version: " .. (info.version or "?") .. "\n" ..
                 "WoW: " .. (info.wow_version or "?") .. "\n" ..
                 "Combat: " .. tostring(runtime.system.combat) .. "\n" ..
                 "Zone: " .. (runtime.system.zone or "?") .. "\n\n" ..
                 "**Active Conditionals:**\n" .. table.concat(runtime.conditionals, ", ") .. "\n\n" ..
                 "**Serialized Data:**\n```\n" .. serialized .. "\n```"

    local encodedBody = urlEncode(body)
    local baseUrl = "https://github.com/claytonkimber/Wise/issues/new"

    -- We can't easily predict the exact encoded length without encoding it,
    -- but encodedBody:len() gives us the payload size.
    -- Browser URL limits vary, safe bet ~2000 total.
    local payloadLen = encodedBody:len()
    local urlLen = baseUrl:len() + 6 + payloadLen -- +6 for "?body="

    local finalUrl = baseUrl .. "?body=" .. encodedBody
    local message = "Press Ctrl+C to copy the link:"

    if urlLen > 2000 then
        -- Too long for direct link
        finalUrl = baseUrl
        message = "Report too long for link. Copy text below, then use link:"

        -- Replace EditBox content with full body for manual copy
        f.EditBox:SetText(body)
        f.EditBox:HighlightText()
        f.EditBox:SetFocus()

        f.Instructions:SetText("|cffff0000Report too long for direct link!|r Please copy the text below and paste it into the GitHub issue body.")
    end

    -- Show Copy Popup
    if not StaticPopupDialogs["WISE_COPY_URL"] then
        StaticPopupDialogs["WISE_COPY_URL"] = {
            text = "Press Ctrl+C to copy the link:",
            button1 = "Close",
            hasEditBox = true,
            editBoxWidth = 350,
            OnShow = function(self)
                local editBox = self.EditBox or self.editBox or _G[self:GetName().."EditBox"]
                if editBox then
                    editBox:SetFocus()
                    editBox:HighlightText()
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
    end

    local dialog = StaticPopup_Show("WISE_COPY_URL")
    if dialog then
         if message ~= "Press Ctrl+C to copy the link:" then
             local textObj = _G[dialog:GetName().."Text"]
             if textObj then textObj:SetText(message) end
         end

         local editBox = dialog.EditBox or dialog.editBox or _G[dialog:GetName().."EditBox"]
         if editBox then
             editBox:SetText(finalUrl)
             editBox:SetFocus()
             editBox:HighlightText()
         end
    end
end
