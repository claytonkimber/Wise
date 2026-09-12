-- modules/nesting/Layout.lua
--
-- What a child inherits, where it sits in the frame stack, which way it opens,
-- and how to walk the tree.
-- See modules/nesting/Rules.lua for how this directory is laid out.
--
-- ApplyNestingInheritance only fills values the user has NOT set explicitly --
-- it must never clobber a deliberate choice, which is why it tests for presence
-- rather than assigning unconditionally.
--
-- GetNestedStrata exists because a child that renders behind its parent is
-- unusable: it climbs STRATA_ORDER so a child is always one band above the
-- parent that opened it, clamping at TOOLTIP rather than overflowing.
--
-- Loaded after Conditionals.lua.

local addonName, Wise = ...
---------------------------------------------------------------------------
-- 6. Nesting Inheritance Rules
--    Defines which parent properties are inherited or overridden on children.
---------------------------------------------------------------------------
Wise.NESTING_INHERITANCE = {
	-- key = property path, inherit = default inherit behavior, override = forced value or nil
	{ key = "visibilitySettings.toggleOnPress", inherit = false, override = true },
	{ key = "visibilitySettings.baseVisibility", inherit = false, override = "ALWAYS_HIDDEN" },
	{ key = "visibilitySettings.hideOnUse", inherit = true, override = nil },
	{ key = "animation", inherit = true, override = nil },
	{ key = "iconSize", inherit = true, override = nil },
	{ key = "textSize", inherit = true, override = nil },
}

--- Apply nesting inheritance from a parent group to a child group.
--- Only modifies values that haven't been explicitly set by the user.
--- @param parentGroup table Parent group data
--- @param childGroup table Child group data (modified in-place)
function Wise:ApplyNestingInheritance(parentGroup, childGroup)
	if not parentGroup or not childGroup then
		return
	end

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
for i, s in ipairs(STRATA_ORDER) do
	STRATA_INDEX[s] = i
end

--- Get the appropriate frame strata for a group based on nesting depth.
--- @param groupName string
--- @param baseStrata string The strata before nesting adjustment
--- @return string strata
function Wise:GetNestedStrata(groupName, baseStrata)
	local depth = Wise:GetNestingDepth(groupName)
	if depth <= 0 then
		return baseStrata
	end

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
	{ value = "auto", label = "Auto", desc = "Automatically choose direction based on screen position" },
	{ value = "up", label = "Up", desc = "Open child interface above the parent button" },
	{ value = "down", label = "Down", desc = "Open child interface below the parent button" },
	{ value = "left", label = "Left", desc = "Open child interface to the left of the parent button" },
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
	if not parentButton then
		return "up"
	end

	local screenW, screenH = GetScreenWidth(), GetScreenHeight()
	local scale = parentButton:GetEffectiveScale()
	local cx, cy = parentButton:GetCenter()
	if not cx or not cy then
		return "up"
	end

	cx = cx * scale
	cy = cy * scale

	local spaceUp = screenH - cy
	local spaceDown = cy
	local spaceRight = screenW - cx
	local spaceLeft = cx

	local maxSpace = math.max(spaceUp, spaceDown, spaceLeft, spaceRight)
	if maxSpace == spaceUp then
		return "up"
	elseif maxSpace == spaceDown then
		return "down"
	elseif maxSpace == spaceRight then
		return "right"
	else
		return "left"
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
	if not WiseDB or not WiseDB.groups then
		return children
	end

	local parentGroup = WiseDB.groups[parentName]
	if not parentGroup or not parentGroup.actions then
		return children
	end

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

