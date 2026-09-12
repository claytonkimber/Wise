-- modules/nesting/Rules.lua
--
-- Nesting vocabulary and the legality matrix. Split out of modules/Nesting.lua
-- on the numbered section boundaries that file already carried:
--
--   Rules         this file -- modes (S1) and the layout legality matrix (S2)
--   Options       depth guard (S3) and per-slot options (S4)
--   Conditionals  the nesting conditionals (S5)
--   Layout        inheritance (S6), strata (S7), open direction (S8),
--                 descendants (S9), summary (S10)
--   Position      where a child frame actually lands
--   CloseMonitor  the hover-close Schmitt trigger
--
-- Load Rules first (NESTING_LAYOUT_RULES backs IsNestingAllowed), then the rest
-- in the order above. Every function attaches to Wise, so nothing beyond that
-- ordering matters.
--
-- WHY THE MATRIX IS ASYMMETRIC: circle-into-circle is always fine, but
-- box-into-circle is not -- a circle's children fan out radially, and a 2D box
-- child has no single direction to fan from. Line-into-line is allowed only
-- with perpendicular axes, for the same reason: a line child sharing its
-- parent's axis would overlap it. Buttons never accept children at all; they
-- are single-action by definition.
--
-- Centralizes all nesting rules, options, and conditionals for Wise interfaces.
-- Modeled on a sub-collection design (rotation modes, open triggers, scroll navigation).

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
	if not childIsLine then
		return false
	end
	if not parentIsLine then
		return false
	end
	local pAxis = parentGroup.fixedAxis or "x"
	local cAxis = childGroup.fixedAxis or "x"
	return pAxis ~= cAxis
end

-- List -> List: allowed
NESTING_LAYOUT_RULES["list_list"] = function(parentGroup, childGroup)
	return true
end

-- Button -> anything: buttons are single-action, no nesting
NESTING_LAYOUT_RULES["button_circle"] = function()
	return false
end
NESTING_LAYOUT_RULES["button_box"] = function()
	return false
end
NESTING_LAYOUT_RULES["button_button"] = function()
	return false
end
NESTING_LAYOUT_RULES["circle_button"] = function()
	return false
end
NESTING_LAYOUT_RULES["box_button"] = function()
	return false
end

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

