-- Nesting.lua
-- Centralizes all nesting rules, options, and conditionals for Wise interfaces.
-- Inspired by OPie's sub-collection model (rotation modes, open triggers, scroll navigation).
local addonName, Wise = ...

---------------------------------------------------------------------------
-- 1. Nesting Modes
--    Two top-level modes: Jump (Open) opens the child interface,
--    Button resolves a child action on the parent slot.
---------------------------------------------------------------------------
Wise.NESTING_MODES = {
    {
        value = "jump",
        label = "Jump (Open)",
        desc = "Opens the nested interface directly when clicked or hovered.",
        tooltip = "The parent slot acts as a portal. It toggles the child interface visible, showing all its actions in the chosen layout.",
    },
    {
        value = "button",
        label = "Button",
        desc = "Resolves a child action directly on the parent slot.",
        tooltip = "The parent slot displays and fires a single action from the child interface, determined by the selected button mode (Cycle, Random, or Priority).",
    },
    {
        value = "embedded",
        label = "Embedded",
        desc = "Injects the child's actions directly into the parent.",
        tooltip = "The child interface's actions are silently merged into the parent's slot list. The child never shows as a separate frame. When the child updates (e.g. a Smart Bar refresh), the parent updates automatically.",
    },
}

-- Sub-modes for Button nesting mode
Wise.NESTING_BUTTON_MODES = {
    {
        value = "cycle",
        label = "Cycle",
        desc = "Scroll through the nested interface's actions one at a time.",
        tooltip = "Each scroll advances to the next action in the child interface. The parent slot displays the current action and fires it on click.",
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

-- Legacy compatibility: map old rotation modes to the new structure
-- "jump" -> nesting mode "jump"
-- "cycle", "shuffle", "random", "priority" -> nesting mode "button" with buttonMode = value
-- "shuffle" maps to "cycle" (shuffle was cycle with randomized order)

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
    rotationMode = "jump",          -- "jump" or "button" (top-level nesting mode)
    buttonMode = "cycle",           -- Sub-mode for button: "cycle", "random", "priority"
    keepOpenAfterUse = false,       -- Keep child interface open after using an action
    inheritHideOnUse = true,        -- Child inherits parent's hideOnUse setting
    openDirection = "auto",         -- "auto", "up", "down", "left", "right" - where child appears
    nestedInterfaceType = "default", -- "default", "circle", "line", "box", "list"
    nestedInterfaceStyle = "default", -- "default" (inherit), "dynamic" (hide unavailable), "static" (grey out unavailable)
    nestedTextAlign = "auto",       -- "auto", "right", "left" - text side for nested list children
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
    -- Migrate legacy rotationMode values: cycle/shuffle/random/priority -> button + buttonMode
    local rm = opts.rotationMode
    if rm == "cycle" or rm == "shuffle" or rm == "random" or rm == "priority" then
        opts.buttonMode = (rm == "shuffle") and "cycle" or rm
        opts.rotationMode = "button"
        -- Persist migration
        if actionData.nestingOptions then
            actionData.nestingOptions.rotationMode = "button"
            actionData.nestingOptions.buttonMode = opts.buttonMode
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
-- 8b. (Removed — nesting always opens on hover)
---------------------------------------------------------------------------

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

-- Helper: Position a nested child group relative to the parent button that opened it.
-- Uses the child's insecure Anchor frame so it works even during combat.

-- Compute where button 1 will be positioned relative to the child frame center
-- for non-circle layouts. Replicates the index-1 math from ApplyLayout.
local function GetButton1Offset(childFrame, childGroup, childIconSize, buttonCount)
    local layoutType = childFrame.effectiveDisplayType or "circle"

    if layoutType == "line" then
        local linePadding = (childGroup and childGroup.padding) or 5
        local anchorPoint = (childGroup and childGroup.anchor and childGroup.anchor.point) or "CENTER"
        local orientation = (childGroup and childGroup.lineOrientation) or "horizontal"
        -- Nested line children: use overrides from nesting logic
        if childFrame.nestedLineOrientation then
            orientation = childFrame.nestedLineOrientation
        end
        if childFrame.nestedLineAnchor then
            anchorPoint = childFrame.nestedLineAnchor
        end
        local spacing = childIconSize + linePadding
        local invertOrder = childGroup and childGroup.invertOrder

        local dx, dy = 0, 0
        local startX, startY = 0, 0
        local count = buttonCount or 1

        if orientation == "horizontal" then
            if anchorPoint:find("RIGHT") then
                dx = -spacing
            elseif anchorPoint:find("LEFT") then
                dx = spacing
            else
                dx = spacing
                startX = -(math.max(count - 1, 0) * spacing) / 2
            end
        else
            if anchorPoint:find("BOTTOM") then
                dy = spacing
            elseif anchorPoint:find("TOP") then
                dy = -spacing
            else
                dy = -spacing
                startY = (math.max(count - 1, 0) * spacing) / 2
            end
        end

        local idx = invertOrder and (count - 1) or 0
        return startX + idx * dx, startY + idx * dy

    elseif layoutType == "box" then
        local fixedAxis = (childGroup and childGroup.fixedAxis) or "x"
        local boxW = (childGroup and childGroup.boxWidth) or 3
        local boxH = (childGroup and childGroup.boxHeight) or 3
        local boxPaddingX = (childGroup and childGroup.paddingX) or 5
        local boxPaddingY = (childGroup and childGroup.paddingY) or 5
        local anchorPoint = (childGroup and childGroup.anchor and childGroup.anchor.point) or "CENTER"
        local invertOrder = childGroup and childGroup.invertOrder
        local spacingX = childIconSize + boxPaddingX
        local spacingY = childIconSize + boxPaddingY
        local count = buttonCount or 1

        local cols, rows
        if fixedAxis == "x" then
            cols = math.max(1, boxW)
            rows = math.ceil(count / cols)
        else
            rows = math.max(1, boxH)
            cols = math.ceil(count / rows)
        end
        if cols < 1 then cols = 1 end

        local totalH = (rows - 1) * spacingY
        local dirX = 1
        local dirY = -1
        if anchorPoint:find("RIGHT") then dirX = -1 end
        if anchorPoint:find("BOTTOM") then dirY = 1 end

        local startY = 0
        if not anchorPoint:find("TOP") and not anchorPoint:find("BOTTOM") then
            startY = (dirY == -1) and (totalH / 2) or (-totalH / 2)
        end

        local posIndex = invertOrder and (count - 1) or 0
        local r = math.floor(posIndex / cols)
        local c = posIndex % cols

        local itemsInThisRow = cols
        if r == rows - 1 then
            local rem = count % cols
            if rem > 0 then itemsInThisRow = rem end
        end

        local rowWidth = (itemsInThisRow - 1) * spacingX
        local startX = 0
        if not anchorPoint:find("LEFT") and not anchorPoint:find("RIGHT") then
            startX = (dirX == 1) and (-rowWidth / 2) or (rowWidth / 2)
        end

        return startX + (c * spacingX * dirX), startY + (r * spacingY * dirY)

    elseif layoutType == "list" then
        local listPadding = (childGroup and childGroup.padding) or 8
        local anchorPoint = (childGroup and childGroup.anchor and childGroup.anchor.point) or "CENTER"
        -- Nested list children: use anchor override from nesting logic
        if childFrame.nestedListAnchor then
            anchorPoint = childFrame.nestedListAnchor
        end
        local invertOrder = childGroup and childGroup.invertOrder
        local _, textSize = Wise:GetGroupDisplaySettings(childFrame.groupName or "")
        local contentHeight = math.max(textSize or 12, childIconSize)
        local lineHeight = contentHeight + listPadding
        local count = buttonCount or 1

        local dy = -lineHeight
        local startY = 0
        local totalH = math.max(count - 1, 0) * lineHeight

        if anchorPoint:find("BOTTOM") then
            dy = lineHeight
        elseif anchorPoint:find("TOP") then
            dy = -lineHeight
        else
            dy = -lineHeight
            startY = totalH / 2
        end

        local idx = invertOrder and (count - 1) or 0
        return 0, startY + idx * dy
    end

    return 0, 0
end

function Wise:PositionNestedChild(childFrame, childName, parentName)
    local parentFrame = Wise.frames and Wise.frames[parentName]
    if not parentFrame then return end

    -- Find which parent button is the interface action pointing to this child
    local parentBtn = nil
    if parentFrame.buttons then
        for _, btn in ipairs(parentFrame.buttons) do
            if btn:IsShown() and btn:GetAttribute("isa_interface_target") == childName then
                parentBtn = btn
                break
            end
        end
    end

    -- Get the parent frame's center (the hub of the parent circle)
    local parentCx, parentCy = parentFrame:GetCenter()
    if not parentCx or not parentCy then return end

    local parentScale = parentFrame:GetEffectiveScale()
    local uiScale = UIParent:GetEffectiveScale()

    -- Parent center in UIParent coords
    local parentUiX = (parentCx * parentScale) / uiScale
    local parentUiY = (parentCy * parentScale) / uiScale

    -- Calculate offset: position child so button 1 aligns with the parent button
    local offsetX, offsetY = 0, 0
    if parentBtn then
        local btnOffX = parentBtn.targetX or 0
        local btnOffY = parentBtn.targetY or 0

        -- Convert from parent frame coords to UIParent coords
        local dx = btnOffX * parentScale / uiScale
        local dy = btnOffY * parentScale / uiScale

        local childGroupName = childFrame.groupName
        local childGroup = childGroupName and WiseDB.groups[childGroupName]
        local childIconSize = childFrame.inheritedIconSize
            or (childGroup and childGroup.iconSize)
            or (WiseDB.settings and WiseDB.settings.iconSize)
            or 30

        local layoutType = childFrame.effectiveDisplayType or "circle"

        if layoutType == "circle" then
            -- Circle: push center outward so button 1 (rotated inward) aligns
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist > 0.1 then
                local nx = dx / dist
                local ny = dy / dist

                local childCircleRadius = (childGroup and childGroup.circleRadius)
                    or (childIconSize * 2)

                offsetX = dx + nx * childCircleRadius
                offsetY = dy + ny * childCircleRadius

                local offsetAngleDeg = math.deg(math.atan2(ny, nx))
                childFrame.nestedCircleRotation = offsetAngleDeg + 90
            end
        else
            -- Line/Box/List: compute where button 1 lands relative to child center,
            -- then position child center so button 1 sits at the parent button.
            -- childCenter = parentBtnPos - button1Offset
            local buttonCount = (childFrame.buttons and #childFrame.buttons) or 1
            local btn1OffX, btn1OffY = GetButton1Offset(childFrame, childGroup, childIconSize, buttonCount)

            -- btn1Off is in child frame coords; convert to UIParent coords
            local childScale = childFrame:GetEffectiveScale()
            local btn1UiX = btn1OffX * childScale / uiScale
            local btn1UiY = btn1OffY * childScale / uiScale

            offsetX = dx - btn1UiX
            offsetY = dy - btn1UiY

            local parentLayoutType = parentFrame.effectiveDisplayType or "circle"

            -- Line/List or List/List: offset child by 1 icon space in the open direction
            -- so the child's text doesn't overlap the parent's icons/text
            if layoutType == "list" and (parentLayoutType == "line" or parentLayoutType == "list") then
                local anchor = childFrame.nestedListAnchor or "TOP"
                local iconSpace = childIconSize * parentScale / uiScale

                if anchor == "TOP" then
                    -- Opening downward: shift child down by 1 icon
                    offsetY = offsetY - iconSpace
                elseif anchor == "BOTTOM" then
                    -- Opening upward: shift child up by 1 icon
                    offsetY = offsetY + iconSpace
                elseif anchor == "LEFT" then
                    -- Opening rightward: shift child right by 1 icon
                    offsetX = offsetX + iconSpace
                elseif anchor == "RIGHT" then
                    -- Opening leftward: shift child left by 1 icon
                    offsetX = offsetX - iconSpace
                end

                -- For list/list: also offset past the parent's text to avoid overlap
                if parentLayoutType == "list" then
                    local parentGroup = WiseDB.groups[parentName]
                    local parentTextAlign = (parentGroup and parentGroup.textAlign) or "right"
                    -- Use parent's nestedTextAlign if it has one (for deeply nested lists)
                    if parentFrame.nestedTextAlign then
                        parentTextAlign = parentFrame.nestedTextAlign
                    end
                    local parentIconSize = parentFrame.inheritedIconSize
                        or (parentGroup and parentGroup.iconSize)
                        or (WiseDB.settings and WiseDB.settings.iconSize)
                        or 30

                    local maxParentTextWidth = 0
                    if parentFrame.buttons then
                        for _, pBtn in ipairs(parentFrame.buttons) do
                            if pBtn.textLabel and pBtn:IsShown() then
                                local tw = pBtn.textLabel:GetStringWidth() or 0
                                if tw > maxParentTextWidth then maxParentTextWidth = tw end
                            end
                        end
                    end

                    local textOffset = (parentIconSize / 2) + 5 + maxParentTextWidth + 20

                    if parentTextAlign == "right" then
                        offsetX = offsetX + (textOffset * parentScale / uiScale)
                    else
                        offsetX = offsetX - (textOffset * parentScale / uiScale)
                    end
                end
            end

            -- Clear any circle rotation from a previous layout
            childFrame.nestedCircleRotation = nil
        end
    end

    local uiX = parentUiX + offsetX
    local uiY = parentUiY + offsetY

    -- Move the proxy anchor (only safe out of combat since it anchors a secure frame)
    if childFrame.Anchor and not InCombatLockdown() then
        childFrame.Anchor:ClearAllPoints()
        childFrame.Anchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT", uiX, uiY)
    end

    -- Also move the secure frame directly (only safe out of combat)
    if not InCombatLockdown() then
        childFrame:ClearAllPoints()
        childFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", uiX, uiY)
    end

    -- Re-apply layout with the computed rotation so buttons fan outward (circle only)
    local effectiveType = childFrame.effectiveDisplayType or "circle"
    if effectiveType == "circle" and childFrame.nestedCircleRotation and not InCombatLockdown() then
        local childGroupName = childFrame.groupName
        local btnCount = 0
        if childFrame.buttons then
            for _, btn in ipairs(childFrame.buttons) do
                if btn:IsShown() then btnCount = btnCount + 1 end
            end
        end
        if btnCount > 0 then
            Wise:ApplyLayout(childFrame, effectiveType, btnCount, childGroupName)
        end
    end

    Wise:DebugPrint("PositionNestedChild: child=%s parent=%s parentBtn=%s offset=%.1f,%.1f uiX=%.1f uiY=%.1f rot=%.1f",
        childName, parentName, parentBtn and parentBtn:GetName() or "NONE", offsetX, offsetY, uiX, uiY, childFrame.nestedCircleRotation or 0)
end

-- Close monitoring for hover-opened nested interfaces.
-- Uses a Schmitt trigger approach: a tight inner zone keeps the interface
-- open (hysteresis ON), while a larger outer zone is required before it
-- closes (hysteresis OFF). This prevents flickering at boundaries.
function Wise:StartNestedCloseOnLeave(childFrame, childName, parentInstanceId)
    -- Cancel any existing watcher
    if childFrame.nestedCloseTicker then
        childFrame.nestedCloseTicker:Cancel()
        childFrame.nestedCloseTicker = nil
    end
    if childFrame._outsideClickFrame then
        childFrame._outsideClickFrame:Hide()
    end

    local parentFrame = Wise.frames and Wise.frames[parentInstanceId]
    local ownerButtonName = childFrame.ownerButtonName
    local parentToggleBtn = childFrame.parentToggleBtn

    -- Thresholds (pixels)
    local BUTTON_PAD = 8   -- per-button pad for non-circle layouts
    local LINE_PAD = 15    -- extra boundary for line/box layouts
    local CIRCLE_EXTRA = 15 -- extra radius beyond buttons for circle layouts

    -- Helper: check if mouse is over any button in a frame's button list
    local function isOverButtons(frame, pad)
        if not frame or not frame.buttons then return false end
        for _, btn in ipairs(frame.buttons) do
            if btn:IsShown() and btn:IsMouseOver(pad, -pad, -pad, pad) then
                return true
            end
        end
        return false
    end

    -- Helper: check if mouse is within a circle centered on a frame
    local function isWithinCircle(frame, radius)
        local cx, cy = frame:GetCenter()
        if not cx then return false end
        local scale = frame:GetEffectiveScale()
        local mx, my = GetCursorPosition()
        mx, my = mx / scale, my / scale
        local dx, dy = mx - cx, my - cy
        return (dx * dx + dy * dy) <= (radius * radius)
    end

    -- Layout-aware area check for a single frame
    local function isOverFrameArea(frame, extra)
        if not frame or not frame.buttons then return false end
        local layoutType = frame.effectiveDisplayType or "circle"
        if layoutType == "circle" then
            -- Compute effective radius: distance from center to button edge + padding
            local maxDist = 0
            for _, btn in ipairs(frame.buttons) do
                if btn:IsShown() then
                    local bx, by = btn:GetCenter()
                    local fx, fy = frame:GetCenter()
                    if bx and fx then
                        local dx, dy = bx - fx, by - fy
                        local dist = (dx * dx + dy * dy) ^ 0.5
                        local btnHalf = (btn:GetWidth() or 40) / 2
                        if dist + btnHalf > maxDist then
                            maxDist = dist + btnHalf
                        end
                    end
                end
            end
            return isWithinCircle(frame, maxDist + extra)
        else
            -- Line/box/list/button: use per-button hitbox with extra padding
            return isOverButtons(frame, BUTTON_PAD + extra)
        end
    end

    -- Is mouse over the child interface area (or its descendants)?
    local function isOverChildArea(extra)
        if isOverFrameArea(childFrame, extra) then return true end
        local descendants = Wise:GetAllDescendants(childFrame.groupName or childName)
        for _, descName in ipairs(descendants) do
            local descFrame = Wise.frames and Wise.frames[descName]
            if descFrame and descFrame:IsShown() and isOverFrameArea(descFrame, extra) then
                return true
            end
        end
        return false
    end

    -- Is mouse over the owning interface button on the parent?
    local function isOverOwnerButton()
        if not parentFrame or not parentFrame.buttons then return false end
        for _, btn in ipairs(parentFrame.buttons) do
            if btn:IsShown() and btn:GetName() == ownerButtonName and btn:IsMouseOver() then
                return true
            end
        end
        return false
    end

    -- Is mouse over a DIFFERENT (non-owner) parent button?
    local function isOverOtherParentButton()
        if not parentFrame or not parentFrame.buttons then return false end
        for _, btn in ipairs(parentFrame.buttons) do
            if btn:IsShown() and btn:GetName() ~= ownerButtonName and btn:IsMouseOver() then
                return true
            end
        end
        return false
    end

    local function closeChild()
        if not InCombatLockdown() then
            childFrame:SetAttribute("state-manual", "hide")
            local driver = Wise.WiseStateDriver
            if driver then
                driver:SetAttribute("wisesetstate", childName .. ":inactive")
            end
        end
        if childFrame.nestedCloseTicker then
            childFrame.nestedCloseTicker:Cancel()
            childFrame.nestedCloseTicker = nil
        end
    end

    local leaveTicks = 0
    local LEAVE_GRACE = 1   -- 1 tick × 0.05s = 0.05s after leaving outer zone
    local startupTicks = 0
    local STARTUP_DELAY = 4  -- 4 ticks × 0.05s = 0.2s startup immunity

    childFrame.nestedCloseTicker = C_Timer.NewTicker(0.05, function()
        if not childFrame:IsShown() then
            if childFrame.nestedCloseTicker then
                childFrame.nestedCloseTicker:Cancel()
                childFrame.nestedCloseTicker = nil
            end
            return
        end

        startupTicks = startupTicks + 1
        if startupTicks <= STARTUP_DELAY then return end

        -- Core logic: child stays open only when mouse is over the owner button OR child buttons.
        -- If mouse is on neither, close (with Schmitt trigger on child area only).

        -- For non-circle parents: if mouse is hovering a different parent button, close immediately.
        -- This gives crisp selection behavior for list/line/box parents.
        local parentLayoutType = parentFrame and parentFrame.effectiveDisplayType or "circle"
        if parentLayoutType ~= "circle" and isOverOtherParentButton() then
            closeChild()
            return
        end

        local onOwner = isOverOwnerButton()
        if onOwner then
            -- Over the parent slot that owns this child — keep open, reset
            leaveTicks = 0
            return
        end

        -- Not on owner button — check child area with Schmitt trigger
        -- Circle layouts get generous padding; line/box/list get tight padding
        local childLayoutType = childFrame.effectiveDisplayType or "circle"
        local innerExtra, outerExtra
        if childLayoutType == "circle" then
            innerExtra = CIRCLE_EXTRA
            outerExtra = CIRCLE_EXTRA + LINE_PAD
        else
            -- Tight buffer for non-circle children (just button padding)
            innerExtra = BUTTON_PAD
            outerExtra = BUTTON_PAD + 4
        end

        if isOverChildArea(innerExtra) then
            leaveTicks = 0
        elseif isOverChildArea(outerExtra) then
            -- Hysteresis band: hold steady (don't reset, don't increment)
        else
            -- Outside everything — close quickly
            leaveTicks = leaveTicks + 1
            if leaveTicks >= LEAVE_GRACE then
                closeChild()
            end
        end
    end)
end

-- Helper: Close all child interfaces of a group (cascade close)
function Wise:CloseChildInterfaces(groupName)
    if InCombatLockdown() then return end
    local children = Wise:GetChildInterfaces(groupName)
    for _, childName in ipairs(children) do
        local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[childName]
        -- Skip Wiser interfaces: they manage their own visibility independently
        -- and should not be cascade-closed when a parent hides
        if childGroup and childGroup.isWiser then
            -- Do not cascade close Wiser interfaces
        else
            local childFrame = Wise.frames and Wise.frames[childName]
            if childFrame and childFrame:IsShown() then
                childFrame:SetAttribute("state-manual", "hide")
                local driver = Wise.WiseStateDriver
                if driver then
                    driver:SetAttribute("wisesetstate", childName .. ":inactive")
                end
            end
        end
    end
end
