-- Debug.lua
local addonName, Wise = ...

-- Helper for evaluating strings as Lua code
local function runLua(code)
    local f, err = loadstring(code)
    if f then
        local success, result = pcall(f)
        if not success then
            print("|cff00ccff[Wise Debug Test Error]|r", result)
        end
    else
        print("|cff00ccff[Wise Debug Test Compile Error]|r", err)
    end
end

-- Debug Helper
function Wise:DebugPrint(...)
    if WiseDB and WiseDB.settings and WiseDB.settings.debug then
        local msg = string.format(...)
        print("|cff00ccff[Wise Debug]|r", msg)

        if Wise.LogFrame then
            local timestamp = date("%H:%M:%S")
            local current = Wise.LogFrame:GetText() or ""
            -- Basic truncation to avoid memory issues (keep last 5000 chars roughly)
            if #current > 10000 then
                 current = current:sub(-5000)
            end
            Wise.LogFrame:SetText(current .. "\n[" .. timestamp .. "] " .. msg)
            -- Auto scroll to bottom
            if Wise.LogFrame:GetParent() then
                 Wise.LogFrame:GetParent():SetVerticalScroll(Wise.LogFrame:GetParent():GetVerticalScrollRange())
            end
        end
    end
end

function Wise:InitializeDebug()
    if not Wise.DebugFrame then
        Wise.DebugResults = {}
        Wise:CreateDebugUI()
    end

    -- Load the visibility based on settings
    Wise:ToggleDebugInterface(WiseDB.settings.debug)
end

function Wise:ToggleDebugInterface(show)
    if Wise.DebugFrame then
        if show then
            Wise.DebugFrame:Show()
            Wise:PopulateDebugTests()
        else
            Wise.DebugFrame:Hide()
        end
    end
end

function Wise:CreateDebugUI()
    local f = CreateFrame("Frame", "WiseDebugFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(750, 500)
    f:SetPoint("CENTER")
    f:Hide()
    f.TitleText:SetText("Wise Debug Tests & LLM QA")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    Wise.DebugFrame = f

    -- Left panel for list of tests
    local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f.InsetBg, "TOPLEFT", 10, -10)
    scrollFrame:SetPoint("BOTTOMLEFT", f.InsetBg, "BOTTOMLEFT", 10, 10)
    scrollFrame:SetWidth(200)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(200, 10)
    scrollFrame:SetScrollChild(content)

    f.TestListContent = content

    -- Right panel for instructions and action
    local rightPanel = CreateFrame("Frame", nil, f)
    rightPanel:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 20, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", f.InsetBg, "BOTTOMRIGHT", -10, 10)

    local title = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 0, -10)
    title:SetPoint("TOPRIGHT", 0, -10)
    title:SetJustifyH("LEFT")
    title:SetText("Select a test...")
    f.TestTitle = title

    local instructions = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    instructions:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -20)
    instructions:SetPoint("BOTTOMRIGHT", rightPanel, "TOPRIGHT", 0, -150)
    instructions:SetJustifyH("LEFT")
    instructions:SetJustifyV("TOP")
    instructions:SetWordWrap(true)
    f.TestInstructions = instructions

    -- QA Output EditBox
    local notesLabel = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    notesLabel:SetPoint("TOPLEFT", instructions, "BOTTOMLEFT", 0, -20)
    notesLabel:SetText("Test Results / Notes (for LLM):")
    notesLabel:SetJustifyH("LEFT")

    local editScroll = CreateFrame("ScrollFrame", nil, rightPanel, "UIPanelScrollFrameTemplate")
    editScroll:SetPoint("TOPLEFT", notesLabel, "BOTTOMLEFT", 0, -5)
    editScroll:SetPoint("RIGHT", -25, 0)
    editScroll:SetHeight(120)

    local editBox = CreateFrame("EditBox", nil, editScroll)
    editBox:SetMultiLine(true)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetWidth(editScroll:GetWidth() - 10)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editScroll:SetScrollChild(editBox)

    f.TestNotes = editBox

    -- EditBox requires fixing size dynamically
    editBox:SetScript("OnCursorChanged", function(self)
        local vs = editScroll:GetVerticalScrollRange()
        if vs > 0 then
            editScroll:SetVerticalScroll(vs)
        end
    end)
    editBox:SetScript("OnTextChanged", function(self)
        if Wise.CurrentTestName then
            Wise.DebugResults[Wise.CurrentTestName] = Wise.DebugResults[Wise.CurrentTestName] or {}
            Wise.DebugResults[Wise.CurrentTestName].notes = self:GetText()
        end
    end)

    -- Status Checkboxes
    local passCheck = CreateFrame("CheckButton", nil, rightPanel, "UICheckButtonTemplate")
    passCheck:SetPoint("TOPLEFT", editScroll, "BOTTOMLEFT", 0, -10)
    passCheck.text:SetText("PASS")

    local failCheck = CreateFrame("CheckButton", nil, rightPanel, "UICheckButtonTemplate")
    failCheck:SetPoint("LEFT", passCheck.text, "RIGHT", 20, 0)
    failCheck.text:SetText("FAIL")

    passCheck:SetScript("OnClick", function(self)
        if self:GetChecked() then failCheck:SetChecked(false) end
        if Wise.CurrentTestName then
            Wise.DebugResults[Wise.CurrentTestName] = Wise.DebugResults[Wise.CurrentTestName] or {}
            Wise.DebugResults[Wise.CurrentTestName].status = self:GetChecked() and "PASS" or "NONE"
        end
    end)

    failCheck:SetScript("OnClick", function(self)
        if self:GetChecked() then passCheck:SetChecked(false) end
        if Wise.CurrentTestName then
            Wise.DebugResults[Wise.CurrentTestName] = Wise.DebugResults[Wise.CurrentTestName] or {}
            Wise.DebugResults[Wise.CurrentTestName].status = self:GetChecked() and "FAIL" or "NONE"
        end
    end)

    f.PassCheck = passCheck
    f.FailCheck = failCheck

    -- Action Buttons
    local runBtn = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate")
    runBtn:SetSize(100, 30)
    runBtn:SetPoint("BOTTOMLEFT", 0, 10)
    runBtn:SetText("Run Test")
    runBtn:Disable()
    f.TestRunButton = runBtn

    local clearBtn = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate")
    clearBtn:SetSize(100, 30)
    clearBtn:SetPoint("LEFT", runBtn, "RIGHT", 10, 0)
    clearBtn:SetText("Clear Test")
    clearBtn:Disable()
    f.TestClearButton = clearBtn

    -- Export Button
    local exportBtn = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate")
    exportBtn:SetSize(120, 30)
    exportBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    exportBtn:SetText("Export to LLM")
    exportBtn:SetScript("OnClick", function()
        Wise:ExportTestResults()
    end)

    f.TestButtons = {}
end

function Wise:ExportTestResults()
    local out = "## Wise Addon QA Results\n\n"
    for testName, result in pairs(Wise.DebugResults) do
        out = out .. "### " .. testName .. "\n"
        out = out .. "**Status**: " .. (result.status or "NOT RUN") .. "\n"
        out = out .. "**Notes**:\n" .. (result.notes or "None") .. "\n\n"
    end

    if not Wise.DebugExportFrame then
        local f = CreateFrame("Frame", "WiseDebugExportFrame", UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(600, 450)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f.TitleText:SetText("Export QA Results to LLM")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)

        local info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        info:SetPoint("TOP", 0, -30)
        info:SetText("Press Ctrl+C to copy the text below.")

        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", f.InsetBg, "TOPLEFT", 10, -40)
        scroll:SetPoint("BOTTOMRIGHT", f.InsetBg, "BOTTOMRIGHT", -30, 10)

        local editBox = CreateFrame("EditBox", nil, scroll)
        editBox:SetMultiLine(true)
        editBox:SetFontObject("ChatFontNormal")
        editBox:SetWidth(scroll:GetWidth())
        editBox:SetAutoFocus(true)
        editBox:SetScript("OnEscapePressed", function(self) f:Hide() end)
        scroll:SetScrollChild(editBox)

        editBox:SetScript("OnCursorChanged", function(self)
            local vs = scroll:GetVerticalScrollRange()
            if vs > 0 then
                scroll:SetVerticalScroll(vs)
            end
        end)

        f.EditBox = editBox
        Wise.DebugExportFrame = f
    end

    Wise.DebugExportFrame.EditBox:SetText(out)
    Wise.DebugExportFrame:Show()
    Wise.DebugExportFrame.EditBox:HighlightText()
    Wise.DebugExportFrame.EditBox:SetFocus()
end

function Wise:PopulateDebugTests()
    local content = Wise.DebugFrame.TestListContent
    local runBtn = Wise.DebugFrame.TestRunButton
    local clearBtn = Wise.DebugFrame.TestClearButton
    local title = Wise.DebugFrame.TestTitle
    local inst = Wise.DebugFrame.TestInstructions
    local notesBox = Wise.DebugFrame.TestNotes
    local passC = Wise.DebugFrame.PassCheck
    local failC = Wise.DebugFrame.FailCheck

    -- Find tests in _G
    local tests = {}
    for name, value in pairs(_G) do
        if type(name) == "string" and name:find("^WiseDebugTest_") then
            -- Verify it's a frame with KeyValues
            if type(value) == "table" and value.GetObjectType and value:GetObjectType() == "Frame" then
                table.insert(tests, value)
            end
        end
    end

    -- Sort tests by name for consistent UI
    table.sort(tests, function(a, b)
        return (a:GetName() or "") < (b:GetName() or "")
    end)

    Wise.DebugFrame.TestButtons = Wise.DebugFrame.TestButtons or {}
    local buttons = Wise.DebugFrame.TestButtons

    local yOffset = 0
    for i, testFrame in ipairs(tests) do
        local testName = testFrame.testName or testFrame:GetName() or ("Test " .. i)
        local testInstructions = testFrame.instructions or "No instructions provided."
        local testAction = testFrame.action or "print('No action defined.')"
        local testClearAction = testFrame.clearAction

        -- Fix escaped newlines in XML
        if type(testInstructions) == "string" then
            testInstructions = string.gsub(testInstructions, "\\n", "\n")
        end

        local btn = buttons[i]
        if not btn then
            btn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
            btn:SetSize(180, 24)
            buttons[i] = btn
        end

        btn:SetPoint("TOPLEFT", 0, yOffset)
        btn:SetText(testName)
        btn:Show()

        btn:SetScript("OnClick", function()
            Wise.CurrentTestName = testName
            title:SetText(testName)
            inst:SetText(testInstructions)

            -- Load saved result data
            local r = Wise.DebugResults[testName] or {}
            notesBox:SetText(r.notes or "")
            passC:SetChecked(r.status == "PASS")
            failC:SetChecked(r.status == "FAIL")

            runBtn:Enable()
            runBtn:SetScript("OnClick", function()
                print("|cff00ccff[Wise QA]|r Running Test: " .. testName)
                runLua(testAction)
            end)

            if testClearAction then
                clearBtn:Enable()
                clearBtn:SetScript("OnClick", function()
                    print("|cff00ccff[Wise QA]|r Clearing Test: " .. testName)
                    runLua(testClearAction)
                end)
            else
                clearBtn:Disable()
            end
        end)

        yOffset = yOffset - 26
    end

    -- Hide unused buttons from previous pool
    for i = #tests + 1, #buttons do
        buttons[i]:Hide()
    end

    content:SetHeight(math.abs(yOffset))
end
