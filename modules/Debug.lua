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
    f:SetSize(600, 400)
    f:SetPoint("CENTER")
    f:Hide()
    f.TitleText:SetText("Wise Debug Tests")
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
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetPoint("TOPRIGHT", 0, 0)
    title:SetJustifyH("LEFT")
    title:SetText("Select a test...")
    f.TestTitle = title

    local instructions = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    instructions:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -20)
    instructions:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", 0, 50)
    instructions:SetJustifyH("LEFT")
    instructions:SetJustifyV("TOP")
    f.TestInstructions = instructions

    local runBtn = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate")
    runBtn:SetSize(120, 30)
    runBtn:SetPoint("BOTTOMLEFT", 0, 0)
    runBtn:SetText("Run Test")
    runBtn:Disable()
    f.TestRunButton = runBtn

    f.TestButtons = {}
end

function Wise:PopulateDebugTests()
    local content = Wise.DebugFrame.TestListContent
    local runBtn = Wise.DebugFrame.TestRunButton
    local title = Wise.DebugFrame.TestTitle
    local inst = Wise.DebugFrame.TestInstructions

    -- Hide old buttons
    if Wise.DebugFrame.TestButtons then
        for _, b in ipairs(Wise.DebugFrame.TestButtons) do
            b:Hide()
        end
    end

    Wise.DebugFrame.TestButtons = {}

    local tests = {}
    -- Find tests in _G
    for name, value in pairs(_G) do
        if type(name) == "string" and name:find("^WiseDebugTest_") then
            -- Verify it's a frame with KeyValues (which are accessed via table indexing if they're a frame)
            if type(value) == "table" and value.GetObjectType and value:GetObjectType() == "Frame" then
                table.insert(tests, value)
            end
        end
    end

    -- Sort tests by name for consistent UI
    table.sort(tests, function(a, b)
        return (a:GetName() or "") < (b:GetName() or "")
    end)

    local yOffset = 0
    for i, testFrame in ipairs(tests) do
        local testName = testFrame.testName or testFrame:GetName() or ("Test " .. i)
        local testInstructions = testFrame.instructions or "No instructions provided."
        local testAction = testFrame.action or "print('No action defined.')"

        local btn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        btn:SetSize(180, 24)
        btn:SetPoint("TOPLEFT", 0, yOffset)
        btn:SetText(testName)

        btn:SetScript("OnClick", function()
            title:SetText(testName)
            inst:SetText(testInstructions)
            runBtn:Enable()
            runBtn:SetScript("OnClick", function()
                print("|cff00ccff[Wise Debug]|r Running Test: " .. testName)
                runLua(testAction)
            end)
        end)

        table.insert(Wise.DebugFrame.TestButtons, btn)
        yOffset = yOffset - 26
    end

    content:SetHeight(math.abs(yOffset))
end
