-- modules/nesting/Conditionals.lua
--
-- The nesting conditionals -- [nested], [parent:name], [depth:n] and friends.
-- See modules/nesting/Rules.lua for how this directory is laid out.
--
-- These are evaluated against the LIVE nesting tree rather than saved settings,
-- because what matters is which parent actually opened this child right now.
-- The same interface nested under two parents answers [parent:...] differently
-- depending on the path it was opened through.
--
-- Loaded after Options.lua.

local addonName, Wise = ...
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
	if not condName or not groupName then
		return nil
	end

	local lower = condName:lower()

	-- wise:groupName - check if a specific group is visible
	if
		lower:match("^wise:")
		and not lower:match("^wise:parent")
		and not lower:match("^wise:nested")
		and not lower:match("^wise:root")
		and not lower:match("^wise:depth")
		and not lower:match("^wise:childopen")
		and not lower:match("^wise:sibling")
	then
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
		if not myParent then
			return false
		end
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

