-- States.lua
local addonName, Wise = ...

local _G = _G
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local string = string
local table = table
local type = type
local inserter = table.insert
local concat = table.concat
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer
local GameTooltip = GameTooltip
local CreateFrame = CreateFrame

local CONFLICT_STRATEGIES = {
    { value = "priority", label = "Priority", desc = "First matching condition wins (by order)" },
    { value = "sequence", label = "Sequence", desc = "Cycle through matching states on each use" },
    { value = "random",   label = "Random",   desc = "Randomly pick among matching states" },
}

-- Helper to negate a conditional
function Wise:NegateConditional(cond)
    if not cond or cond == "" then return nil end
    -- Remove brackets if present
    local cleaned = cond:gsub("^%[", ""):gsub("%]$", "")
    
    local results = {}
    for part in cleaned:gmatch("[^,]+") do
        part = part:match("^%s*(.-)%s*$") -- trim
        if part:sub(1, 2) == "no" then
            table.insert(results, part:sub(3))
        else
            table.insert(results, "no" .. part)
        end
    end
    
    return "[" .. table.concat(results, ", ") .. "]"
end

-- Helper to parse conditions into a set
local function GetConditionParts(condStr)
    if not condStr or condStr == "" then return {} end
    local cleaned = condStr:gsub("^%[", ""):gsub("%]$", "")
    local parts = {}
    for part in cleaned:gmatch("[^,]+") do
        part = part:match("^%s*(.-)%s*$") -- trim
        parts[part] = true
    end
    return parts
end

-- Check if two sets of conditions are mutually exclusive
local function AreMutuallyExclusive(partsA, partsB)
    -- They are exclusive if A has a condition whose negation is in B, or vice-versa
    for condA in pairs(partsA) do
        local negation = condA:sub(1, 2) == "no" and condA:sub(3) or ("no" .. condA)
        if partsB[negation] then return true end
    end
    for condB in pairs(partsB) do
        local negation = condB:sub(1, 2) == "no" and condB:sub(3) or ("no" .. condB)
        if partsA[negation] then return true end
    end
    return false
end

-- Check if a slot has conflicting conditionals (more than one action applicable to the current character)
function Wise:HasConflictingConditionals(actions)
    if not actions then return false end
    
    local allowedActions = {}
    -- Only count numeric indices (actions) that are allowed for the current character
    for i = 1, #actions do
        local action = actions[i]
        if type(action) == "table" and Wise:IsActionAllowed(action) then
            table.insert(allowedActions, action)
        end
    end
    
    if #allowedActions <= 1 then return false end

    -- Check if any pair of actions is NOT mutually exclusive
    local hasConflict = false
    for i = 1, #allowedActions do
        local partsA = GetConditionParts(allowedActions[i].conditions)
        for j = i + 1, #allowedActions do
            local partsB = GetConditionParts(allowedActions[j].conditions)
            if not AreMutuallyExclusive(partsA, partsB) then
                hasConflict = true
                break
            end
        end
        if hasConflict then break end
    end
    return hasConflict
end

function Wise:ComputeEffectiveConditions(states, stateIdx)
    local state = states[stateIdx]
    local baseCond = state.conditions or ""
    
    local exclusions = {}
    for i, s in ipairs(states) do
        if i ~= stateIdx and s.exclusive and s.conditions and s.conditions ~= "" then
            local negated = Wise:NegateConditional(s.conditions)
            if negated then
                local inner = string.match(negated, "^%[(.+)%]$") or negated
                table.insert(exclusions, inner)
            end
        end
    end
    
    if #exclusions == 0 then return baseCond end
    local exStr = table.concat(exclusions, ",")
    
    if baseCond == "" then return "[" .. exStr .. "]" end
    
    local result = ""
    for bracket in string.gmatch(baseCond, "%[([^%]]*)%]") do
        if bracket == "" then
            result = result .. "[" .. exStr .. "]"
        else
            result = result .. "[" .. bracket .. "," .. exStr .. "]"
        end
    end
    if result == "" then
        result = "[" .. baseCond .. "," .. exStr .. "]"
    end
    return result
end

-- Create the UI configuration frame for state conflict resolution
function Wise:CreateStateConfigurationFrame(parent, group, slotIndex)
    if not group or not group.actions or not group.actions[slotIndex] then return nil end
    local actions = group.actions[slotIndex]
    
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetWidth(parent:GetWidth() - 20)
    
    local y = -5
    
    -- Title / Explainer
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", 0, y)
    title:SetText("Conflict Strategy:")
    
    y = y - 18
    
    local desc = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    desc:SetPoint("TOPLEFT", 0, y)
    desc:SetWidth(frame:GetWidth())
    desc:SetJustifyH("LEFT")
    desc:SetText("Multiple actions are defined for this slot. Choose how to decide which action to use when their conditions overlap.")
    
    y = y - 35
    
    local currentStrategy = actions.conflictStrategy or "priority"
    
    frame.controls = {}

    for _, strat in ipairs(CONFLICT_STRATEGIES) do
        local radio = CreateFrame("CheckButton", nil, frame, "UIRadioButtonTemplate")
        radio:SetPoint("TOPLEFT", 10, y)
        radio:SetChecked(currentStrategy == strat.value)
        
        radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)
        radio.text:SetText(strat.label)
        
        radio:SetScript("OnClick", function()
             actions.conflictStrategy = strat.value
             -- Refresh parent to update radio states
             if Wise.RefreshPropertiesPanel then Wise:RefreshPropertiesPanel() end
             
             C_Timer.After(0, function()
                 if not InCombatLockdown() then
                     Wise:UpdateGroupDisplay(Wise.selectedGroup)
                 end
             end)
        end)
        
        -- Tooltip
        radio:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(strat.label, 1, 1, 1)
            GameTooltip:AddLine(strat.desc, nil, nil, nil, true)
            
            -- Add detailed explanation based on strategy
            GameTooltip:AddLine(" ")
            if strat.value == "priority" then
                GameTooltip:AddLine("Checks actions in order (1, 2, 3...). The first one that matches its conditions is used.", 0.8, 0.8, 0.8, true)
            elseif strat.value == "sequence" then
                 GameTooltip:AddLine("Cycles through matching actions one by one on each press (1 -> 2 -> 3 -> 1...).", 0.8, 0.8, 0.8, true)
            elseif strat.value == "random" then
                 GameTooltip:AddLine("Picks a random action from those that match their conditions.", 0.8, 0.8, 0.8, true)
            end
            
            GameTooltip:Show()
        end)
        radio:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        
        tinsert(frame.controls, radio)
        
        y = y - 22
    end
    
    if currentStrategy == "sequence" then
        local resetCheck = CreateFrame("CheckButton", nil, frame, "InterfaceOptionsCheckButtonTemplate")
        resetCheck:SetPoint("TOPLEFT", 10, y)
        resetCheck:SetChecked(actions.resetOnCombat)
        resetCheck.Text:SetText("Reset to state 1 when combat ends")
        resetCheck.Text:SetFontObject("GameFontHighlightSmall")
        
        resetCheck:SetScript("OnClick", function(self)
            actions.resetOnCombat = self:GetChecked()
            C_Timer.After(0, function()
                 if not InCombatLockdown() then
                     Wise:UpdateGroupDisplay(Wise.selectedGroup)
                 end
            end)
        end)
        
        tinsert(frame.controls, resetCheck)
        y = y - 25
    end

    -- Suppress errors checkbox (available for all conflict strategies with multiple states)
    local suppressCheck = CreateFrame("CheckButton", nil, frame, "InterfaceOptionsCheckButtonTemplate")
    suppressCheck:SetPoint("TOPLEFT", 10, y)
    suppressCheck:SetChecked(actions.suppressErrors)
    suppressCheck.Text:SetText("Suppress all errors")
    suppressCheck.Text:SetFontObject("GameFontHighlightSmall")

    suppressCheck:SetScript("OnClick", function(self)
        actions.suppressErrors = self:GetChecked()
        C_Timer.After(0, function()
            if not InCombatLockdown() then
                Wise:UpdateGroupDisplay(Wise.selectedGroup)
            end
        end)
    end)

    tinsert(frame.controls, suppressCheck)
    y = y - 25

    -- Suggestions
    local allowedActions = {}
    for i = 1, #actions do
        local action = actions[i]
        if type(action) == "table" and Wise:IsActionAllowed(action) then
            table.insert(allowedActions, { action = action, index = i })
        end
    end

    local suggestions = {}
    for i = 1, #allowedActions do
        local a = allowedActions[i]
        local partsA = GetConditionParts(a.action.conditions)
        
        for j = 1, #allowedActions do
            if i ~= j then
                local b = allowedActions[j]
                local partsB = GetConditionParts(b.action.conditions)
                
                if not AreMutuallyExclusive(partsA, partsB) then
                    -- Suggest negating A's unique conditions in B if A comes first or if B is empty
                    -- For now, let's just suggest negating whatever is in A that isn't in B
                    for condA in pairs(partsA) do
                        local negation = condA:sub(1, 2) == "no" and condA:sub(3) or ("no" .. condA)
                        if not partsB[negation] then
                            suggestions[j] = suggestions[j] or {}
                            suggestions[j][negation] = true
                        end
                    end
                end
            end
        end
    end

    local hasSuggestions = false
    for idx, conds in pairs(suggestions) do
        hasSuggestions = true
        break
    end

    if hasSuggestions then
        y = y - 10
        local sugTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sugTitle:SetPoint("TOPLEFT", 0, y)
        sugTitle:SetText("Suggestions to resolve conflicts:")
        y = y - 15

        for idx, conds in pairs(suggestions) do
            local actionRef = allowedActions[idx]
            local list = {}
            for c in pairs(conds) do table.insert(list, "[" .. c .. "]") end

            local aName = Wise:GetActionName(actionRef.action.type, actionRef.action.value, actionRef.action)
            local sug = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            sug:SetPoint("TOPLEFT", 10, y)
            sug:SetWidth(frame:GetWidth() - 20)
            sug:SetJustifyH("LEFT")
            sug:SetText(string.format("%s: Add %s", aName, table.concat(list, ", ")))

            y = y - (sug:GetStringHeight() + 2)
        end
    end

    if currentStrategy == "sequence" and #actions > 0 then
        y = y - 10
        local seqTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        seqTitle:SetPoint("TOPLEFT", 0, y)
        seqTitle:SetText("Sequence Execution Plan:")
        y = y - 15
        
        local steps = {}
        local currentStep = {}
        for i = 1, #actions do
            local a = actions[i]
            local aName = Wise:GetActionName(a.type, a.value, a) or "Unknown"
            local _, _, isOffGcd = Wise:GetCastTimeText(a.type, a.value)
            
            table.insert(currentStep, aName .. (isOffGcd and " (Off-GCD)" or ""))
            if not isOffGcd then
                table.insert(steps, currentStep)
                currentStep = {}
            end
        end
        if #currentStep > 0 then
            table.insert(steps, currentStep)
        end
        
        for idx, step in ipairs(steps) do
            local seqText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            seqText:SetPoint("TOPLEFT", 10, y)
            seqText:SetWidth(frame:GetWidth() - 20)
            seqText:SetJustifyH("LEFT")
            seqText:SetText(string.format("Press %d: %s", idx, table.concat(step, " + ")))
            y = y - (seqText:GetStringHeight() + 2)
        end
    end

    frame:SetHeight(math.abs(y) + 5)
    return frame
end
