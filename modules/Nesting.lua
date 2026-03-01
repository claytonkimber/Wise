-- Nesting.lua
-- Centralizes all nesting rules, options, and conditionals for Wise interfaces.
-- Inspired by OPie's sub-collection model (rotation modes, open triggers, scroll navigation).
local addonName, Wise = ...

---------------------------------------------------------------------------
-- 1. Nesting Rotation Modes
--    Determines how a nested interface resolves which child action to display
--    when the parent slot is activated. Mirrors OPie's per-slice rotation modes.
---------------------------------------------------------------------------
Wise.NESTING_ROTATION_MODES = {
    {
        value = "jump",
        label = "Jump (Open)",
        desc = "Opens the nested interface directly when clicked.",
        tooltip = "The parent slot acts as a portal. Clicking it toggles the child interface visible, showing all its actions.",
    },
    {
        value = "cycle",
        label = "Cycle",
        desc = "Scroll through the nested interface's actions one at a time.",
        tooltip = "Each scroll advances to the next action in the child interface. The parent slot displays the current action and fires it on click.",
    },
    {
        value = "shuffle",
        label = "Shuffle",
        desc = "Randomize order, then cycle through without repeats.",
        tooltip = "Actions in the child interface are shuffled into a random order, then cycled through sequentially until all have been used.",
    },
    {
        value = "random",
        label = "Random",
        desc = "Pick a random action from the nested interface each time.",
        tooltip = "Each activation picks a random action from the child interface. May repeat before all actions have been used.",
    },
    {
        value = "priority",
        label = "Priority",
        desc = "Use the first action whose conditions match.",
        tooltip = "Evaluates child actions in order (1, 2, 3...). The first one whose conditions are met is displayed and fired.",
    },
}

---------------------------------------------------------------------------
-- 2. Nesting Layout Rules
--    Defines which layout combinations are allowed for parent -> child nesting.
--    Each rule returns true if the child is ALLOWED to nest into the parent.
---------------------------------------------------------------------------
local NESTING_LAYOUT_RULES = {}

-- Circle -> Circle: always allowed
NESTING_LAYOUT_RULES["circle_circle"] = function(parentGroup, childGroup)
    return true
end

-- Circle -> Box (line only): allowed if child is a line (1D box)
NESTING_LAYOUT_RULES["circle_box"] = function(parentGroup, childGroup)
    local isLine = (childGroup.boxWidth == 1 or childGroup.boxHeight == 1)
    return isLine
end

-- Box -> Circle: not allowed (circles can only nest into circles)
NESTING_LAYOUT_RULES["box_circle"] = function(parentGroup, childGroup)
    return false
end

-- Box -> Box: only line-into-line with perpendicular axes
NESTING_LAYOUT_RULES["box_box"] = function(parentGroup, childGroup)
    local parentIsLine = (parentGroup.boxWidth == 1 or parentGroup.boxHeight == 1)
    local childIsLine = (childGroup.boxWidth == 1 or childGroup.boxHeight == 1)
    if not childIsLine then return false end
    if not parentIsLine then return false end
    local pAxis = parentGroup.fixedAxis or "x"
    local cAxis = childGroup.fixedAxis or "x"
    return pAxis ~= cAxis
end

-- List -> List: allowed
NESTING_LAYOUT_RULES["list_list"] = function(parentGroup, childGroup)
    return true
end


-- Button -> anything: buttons are single-action, no nesting
NESTING_LAYOUT_RULES["button_circle"] = function() return false end
NESTING_LAYOUT_RULES["button_box"] = function() return false end
NESTING_LAYOUT_RULES["button_button"] = function() return false end
NESTING_LAYOUT_RULES["circle_button"] = function() return false end
NESTING_LAYOUT_RULES["box_button"] = function() return false end

--- Check whether a child group can nest into a parent group based on layout rules.
--- @param parentGroup table The parent group data from WiseDB.groups
--- @param childGroup table The child group data from WiseDB.groups
--- @return boolean allowed
--- @return string|nil reason Human-readable rejection reason
function Wise:IsNestingAllowed(parentGroup, childGroup)
    if not parentGroup or not childGroup then
        return false, "Missing group data."
    end
    if childGroup.isWiser then
        return false, "Wiser interfaces cannot be nested."
    end

    local parentType = parentGroup.type or "circle"
    local childType = childGroup.type or "circle"
    local key = parentType .. "_" .. childType

    local rule = NESTING_LAYOUT_RULES[key]
    if not rule then
        return false, string.format("Unknown layout combination: %s -> %s", parentType, childType)
    end

    local allowed = rule(parentGroup, childGroup)
    if not allowed then
        -- Build a meaningful reason
        if childType == "circle" and parentType ~= "circle" then
            return false, "Circles can only nest into other circles."
        elseif childType == "box" then
            local childIsLine = (childGroup.boxWidth == 1 or childGroup.boxHeight == 1)
            if not childIsLine then
                return false, "Grid boxes cannot be nested. Only line boxes (1 row or 1 column) can."
            else
                return false, "Line boxes must be perpendicular to their parent line."
            end
        elseif parentType == "button" or childType == "button" then
            return false, "Button layouts do not support nesting."
        end
        return false, "Nesting not allowed for this layout combination."
    end

    return true, nil
end

---------------------------------------------------------------------------
-- 3. Nesting Depth & Recursion Guard
--    Prevents infinite nesting loops and enforces a maximum depth.
---------------------------------------------------------------------------
Wise.NESTING_MAX_DEPTH = 5

--- Walk the parent chain for a group and return the nesting depth.
--- Returns 0 if the group has no parent.
--- Returns -1 if a cycle is detected.
--- @param groupName string
--- @return number depth
--- @return table chain Ordered list of ancestor names (root first)
function Wise:GetNestingDepth(groupName)
    local visited = {}
    local chain = {}
    local current = groupName
    while current do
        if visited[current] then
            return -1, chain -- cycle detected
        end
        visited[current] = true
        local parentName = Wise:GetParentInfo(current)
        if parentName then
            table.insert(chain, 1, parentName)
            current = parentName
        else
            break
        end
    end
    return #chain, chain
end

--- Check if adding childName as a nested interface inside parentName would create a cycle.
--- @param parentName string
--- @param childName string
--- @return boolean wouldCycle
function Wise:WouldCreateNestingCycle(parentName, childName)
    if parentName == childName then return true end
    -- Walk up from parentName; if we find childName, it would form a cycle
    local visited = {}
    local current = parentName
    while current do
        if current == childName then return true end
        if visited[current] then return false end -- already a cycle in the data, but not involving childName
        visited[current] = true
        current = Wise:GetParentInfo(current)
    end
    return false
end

---------------------------------------------------------------------------
-- 4. Per-Slot Nesting Options (stored on the action data)
--    These are the configurable properties for an "interface" action.
---------------------------------------------------------------------------
Wise.NESTING_DEFAULTS = {
    rotationMode = "jump",          -- Default: open the nested interface
    openNestedButton = "BUTTON1",   -- Which button opens the nested interface
    openOnHover = false,            -- Open nested interface when hovering (instead of click)
    closeOnLeave = true,            -- Close nested interface when mouse leaves parent
    closeParentOnOpen = false,      -- Close parent interface when child opens
    inheritHideOnUse = true,        -- Child inherits parent's hideOnUse setting
    showGhostIndicator = true,      -- Show a visual indicator that this slot opens a sub-interface
    anchorToParentSlot = true,      -- Position child relative to the parent button that opened it
    openDirection = "auto",         -- "auto", "up", "down", "left", "right" - where child appears
    nestedInterfaceType = "default", -- "default", "circle", "line", "box", "list", "button"
}

--- Get the effective nesting options for an interface action, merging defaults.
--- @param actionData table The action entry (type="interface")
--- @return table options Merged nesting options
function Wise:GetNestingOptions(actionData)
    if not actionData or actionData.type ~= "interface" then return nil end
    local opts = {}
    for k, v in pairs(Wise.NESTING_DEFAULTS) do
        if actionData.nestingOptions and actionData.nestingOptions[k] ~= nil then
            opts[k] = actionData.nestingOptions[k]
        else
            opts[k] = v
        end
    end
    return opts
end

--- Set a nesting option on an action, creating the nestingOptions table if needed.
--- @param actionData table The action entry (type="interface")
--- @param key string Option key
--- @param value any Option value
function Wise:SetNestingOption(actionData, key, value)
    if not actionData or actionData.type ~= "interface" then return end
    if Wise.NESTING_DEFAULTS[key] == nil then return end -- unknown option
    actionData.nestingOptions = actionData.nestingOptions or {}
    if value == Wise.NESTING_DEFAULTS[key] then
        actionData.nestingOptions[key] = nil -- don't store defaults
    else
        actionData.nestingOptions[key] = value
    end
    -- Clean up empty table
    if next(actionData.nestingOptions) == nil then
        actionData.nestingOptions = nil
    end
end

---------------------------------------------------------------------------
-- 5. Nesting Conditionals
--    Conditions that depend on the nesting relationship between interfaces.
--    These extend the existing WoW macro conditional system.
---------------------------------------------------------------------------
Wise.nestingConditionals = {
    { type = "header", text = "Nesting State" },
    {
        name = "wise:groupName",
        desc = "True when a specific Wise interface is currently visible/active",
        skipeval = true,
    },
    {
        name = "wise:parent",
        desc = "True when the current interface's parent is visible",
        skipeval = true,
    },
    {
        name = "wise:nested",
        desc = "True when the current interface is nested inside another",
    },
    {
        name = "wise:root",
        desc = "True when the current interface is a root (not nested)",
    },

    { type = "header", text = "Nesting Depth" },
    {
        name = "wise:depth:0",
        desc = "True when the interface is at root level (depth 0)",
    },
    {
        name = "wise:depth:1",
        desc = "True when the interface is at nesting depth 1",
    },
    {
        name = "wise:depth:2+",
        desc = "True when the interface is at nesting depth 2 or more",
    },

    { type = "header", text = "Nesting Interaction" },
    {
        name = "wise:childopen",
        desc = "True when any child interface of this group is currently visible",
    },
    {
        name = "wise:childopen:groupName",
        desc = "True when a specific child interface is currently visible",
        skipeval = true,
    },
    {
        name = "wise:sibling",
        desc = "True when a sibling interface (same parent) is visible",
    },
}

--- Evaluate a nesting-specific conditional for a given group.
--- @param condName string The conditional name (e.g. "wise:parent", "wise:depth:1")
--- @param groupName string The group being evaluated
--- @return boolean|nil result True/false if evaluable, nil if not a nesting conditional
function Wise:EvaluateNestingConditional(condName, groupName)
    if not condName or not groupName then return nil end

    local lower = condName:lower()

    -- wise:groupName - check if a specific group is visible
    if lower:match("^wise:") and not lower:match("^wise:parent") and not lower:match("^wise:nested")
       and not lower:match("^wise:root") and not lower:match("^wise:depth")
       and not lower:match("^wise:childopen") and not lower:match("^wise:sibling") then
        local targetGroup = condName:match("^wise:(.+)$")
        if targetGroup and Wise.groupFrames and Wise.groupFrames[targetGroup] then
            return Wise.groupFrames[targetGroup]:IsShown()
        end
        return false
    end

    -- wise:parent - is the parent visible?
    if lower == "wise:parent" then
        local parentName = Wise:GetParentInfo(groupName)
        if parentName and Wise.groupFrames and Wise.groupFrames[parentName] then
            return Wise.groupFrames[parentName]:IsShown()
        end
        return false
    end

    -- wise:nested - is this group nested?
    if lower == "wise:nested" then
        local parentName = Wise:GetParentInfo(groupName)
        return parentName ~= nil
    end

    -- wise:root - is this group a root (not nested)?
    if lower == "wise:root" then
        local parentName = Wise:GetParentInfo(groupName)
        return parentName == nil
    end

    -- wise:depth:N
    local depthStr = lower:match("^wise:depth:(.+)$")
    if depthStr then
        local depth = Wise:GetNestingDepth(groupName)
        if depthStr:match("%+$") then
            local minDepth = tonumber(depthStr:match("^(%d+)"))
            return minDepth and depth >= minDepth
        else
            local exactDepth = tonumber(depthStr)
            return exactDepth and depth == exactDepth
        end
    end

    -- wise:childopen / wise:childopen:groupName
    local childTarget = lower:match("^wise:childopen:(.+)$")
    if childTarget then
        if Wise.groupFrames and Wise.groupFrames[childTarget] then
            return Wise.groupFrames[childTarget]:IsShown()
        end
        return false
    end
    if lower == "wise:childopen" then
        -- Check if any child of this group is visible
        if WiseDB and WiseDB.groups then
            for childName, childGroup in pairs(WiseDB.groups) do
                local parentName = Wise:GetParentInfo(childName)
                if parentName == groupName and Wise.groupFrames and Wise.groupFrames[childName] then
                    if Wise.groupFrames[childName]:IsShown() then
                        return true
                    end
                end
            end
        end
        return false
    end

    -- wise:sibling - any sibling (same parent) is visible
    if lower == "wise:sibling" then
        local myParent = Wise:GetParentInfo(groupName)
        if not myParent then return false end
        if WiseDB and WiseDB.groups then
            for siblingName, _ in pairs(WiseDB.groups) do
                if siblingName ~= groupName then
                    local sibParent = Wise:GetParentInfo(siblingName)
                    if sibParent == myParent and Wise.groupFrames and Wise.groupFrames[siblingName] then
                        if Wise.groupFrames[siblingName]:IsShown() then
                            return true
                        end
                    end
                end
            end
        end
        return false
    end

    return nil -- not a nesting conditional
end

---------------------------------------------------------------------------
-- 6. Nesting Inheritance Rules
--    Defines which parent properties are inherited or overridden on children.
---------------------------------------------------------------------------
Wise.NESTING_INHERITANCE = {
    -- key = property path, inherit = default inherit behavior, override = forced value or nil
    { key = "visibilitySettings.toggleOnPress",   inherit = false, override = true },
    { key = "visibilitySettings.baseVisibility",  inherit = false, override = "ALWAYS_HIDDEN" },
    { key = "visibilitySettings.hideOnUse",       inherit = true,  override = nil },
    { key = "animation",                          inherit = true,  override = nil },
    { key = "iconSize",                           inherit = true,  override = nil },
    { key = "textSize",                           inherit = true,  override = nil },
}

--- Apply nesting inheritance from a parent group to a child group.
--- Only modifies values that haven't been explicitly set by the user.
--- @param parentGroup table Parent group data
--- @param childGroup table Child group data (modified in-place)
function Wise:ApplyNestingInheritance(parentGroup, childGroup)
    if not parentGroup or not childGroup then return end

    for _, rule in ipairs(Wise.NESTING_INHERITANCE) do
        local keys = {}
        for segment in rule.key:gmatch("[^%.]+") do
            table.insert(keys, segment)
        end

        -- Forced overrides always apply
        if rule.override ~= nil then
            local target = childGroup
            for i = 1, #keys - 1 do
                target[keys[i]] = target[keys[i]] or {}
                target = target[keys[i]]
            end
            target[keys[#keys]] = rule.override

        -- Inherited values apply only if child hasn't set them
        elseif rule.inherit then
            local parentVal = parentGroup
            for _, k in ipairs(keys) do
                if type(parentVal) == "table" then
                    parentVal = parentVal[k]
                else
                    parentVal = nil
                    break
                end
            end

            if parentVal ~= nil then
                local childTarget = childGroup
                for i = 1, #keys - 1 do
                    childTarget[keys[i]] = childTarget[keys[i]] or {}
                    childTarget = childTarget[keys[i]]
                end
                if childTarget[keys[#keys]] == nil then
                    childTarget[keys[#keys]] = parentVal
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- 7. Strata Resolution for Nested Interfaces
--    Ensures child interfaces render above their parents.
---------------------------------------------------------------------------
local STRATA_ORDER = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
local STRATA_INDEX = {}
for i, s in ipairs(STRATA_ORDER) do STRATA_INDEX[s] = i end

--- Get the appropriate frame strata for a group based on nesting depth.
--- @param groupName string
--- @param baseStrata string The strata before nesting adjustment
--- @return string strata
function Wise:GetNestedStrata(groupName, baseStrata)
    local depth = Wise:GetNestingDepth(groupName)
    if depth <= 0 then return baseStrata end

    local idx = STRATA_INDEX[baseStrata] or 3 -- default MEDIUM
    local newIdx = math.min(idx + depth, #STRATA_ORDER)
    return STRATA_ORDER[newIdx]
end

---------------------------------------------------------------------------
-- 8. Open Direction Resolution
--    Determines which direction a child interface should open relative to
--    the parent button that triggered it.
---------------------------------------------------------------------------
local OPEN_DIRECTIONS = {
    { value = "auto",  label = "Auto",  desc = "Automatically choose direction based on screen position" },
    { value = "up",    label = "Up",    desc = "Open child interface above the parent button" },
    { value = "down",  label = "Down",  desc = "Open child interface below the parent button" },
    { value = "left",  label = "Left",  desc = "Open child interface to the left of the parent button" },
    { value = "right", label = "Right", desc = "Open child interface to the right of the parent button" },
    { value = "center", label = "Center", desc = "Center child interface on the parent button" },
}

Wise.NESTING_OPEN_DIRECTIONS = OPEN_DIRECTIONS

---------------------------------------------------------------------------
-- 8b. Nesting Open Buttons
--     Which mouse/key button opens the nested interface.
---------------------------------------------------------------------------
Wise.NESTING_OPEN_BUTTONS = {
    { value = "BUTTON1",  label = "Left Click",     desc = "Open nested interface with left mouse button" },
    { value = "BUTTON3",  label = "Middle Mouse",   desc = "Open nested interface with middle mouse button" },
    { value = "keybind",  label = "Parent Keybind",  desc = "Open nested interface with the parent group's keybind" },
}

--- Resolve the open direction for a nested interface.
--- When set to "auto", picks the direction with the most screen space.
--- @param parentButton frame The parent button frame
--- @param direction string Configured direction ("auto", "up", "down", "left", "right", "center")
--- @return string resolvedDirection
function Wise:ResolveOpenDirection(parentButton, direction)
    if direction and direction ~= "auto" then
        return direction
    end

    -- Auto: pick the direction with the most available screen space
    if not parentButton then return "up" end

    local screenW, screenH = GetScreenWidth(), GetScreenHeight()
    local scale = parentButton:GetEffectiveScale()
    local cx, cy = parentButton:GetCenter()
    if not cx or not cy then return "up" end

    cx = cx * scale
    cy = cy * scale

    local spaceUp = screenH - cy
    local spaceDown = cy
    local spaceRight = screenW - cx
    local spaceLeft = cx

    local maxSpace = math.max(spaceUp, spaceDown, spaceLeft, spaceRight)
    if maxSpace == spaceUp then return "up"
    elseif maxSpace == spaceDown then return "down"
    elseif maxSpace == spaceRight then return "right"
    else return "left"
    end
end

---------------------------------------------------------------------------
-- 9. Utility: Collect All Children / Descendants
---------------------------------------------------------------------------

--- Get the immediate child group names of a parent group.
--- @param parentName string
--- @return table children Array of child group names
function Wise:GetChildInterfaces(parentName)
    local children = {}
    if not WiseDB or not WiseDB.groups then return children end

    local parentGroup = WiseDB.groups[parentName]
    if not parentGroup or not parentGroup.actions then return children end

    for slotIdx, states in pairs(parentGroup.actions) do
        if type(slotIdx) == "number" and type(states) == "table" then
            for _, action in ipairs(states) do
                if action.type == "interface" then
                    table.insert(children, action.value)
                end
            end
        end
    end
    return children
end

--- Get all descendants (children, grandchildren, etc.) of a parent group.
--- @param parentName string
--- @return table descendants Array of descendant group names
function Wise:GetAllDescendants(parentName)
    local descendants = {}
    local visited = {}
    local queue = { parentName }

    while #queue > 0 do
        local current = table.remove(queue, 1)
        if not visited[current] then
            visited[current] = true
            local children = Wise:GetChildInterfaces(current)
            for _, child in ipairs(children) do
                if not visited[child] then
                    table.insert(descendants, child)
                    table.insert(queue, child)
                end
            end
        end
    end
    return descendants
end

---------------------------------------------------------------------------
-- 10. Nesting Summary (for UI display / debugging)
---------------------------------------------------------------------------

--- Build a summary of the nesting tree starting from a root group.
--- Returns a table of { name, depth, parentName, childCount } entries.
--- @param rootName string
--- @return table tree
function Wise:GetNestingTree(rootName)
    local tree = {}
    local function walk(name, depth, parent)
        local children = Wise:GetChildInterfaces(name)
        table.insert(tree, {
            name = name,
            depth = depth,
            parentName = parent,
            childCount = #children,
        })
        for _, child in ipairs(children) do
            walk(child, depth + 1, name)
        end
    end
    walk(rootName, 0, nil)
    return tree
end
