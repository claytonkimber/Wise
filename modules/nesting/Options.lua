-- modules/nesting/Options.lua
--
-- The recursion guard and the per-slot nesting options.
-- See modules/nesting/Rules.lua for how this directory is laid out.
--
-- TWO SEPARATE SAFETY CHECKS, and they catch different things:
--   * GetNestingDepth / NESTING_MAX_DEPTH bounds how deep a chain may go, so a
--     legal but absurd tree cannot be built.
--   * WouldCreateNestingCycle catches A -> B -> A, which no depth limit can --
--     a cycle would recurse forever, not merely deeply.
-- Both must pass before a nesting is accepted; neither subsumes the other.
--
-- Options live on the ACTION DATA, not the group, because the same child
-- interface can be nested from several parent slots with different open
-- triggers and rotation modes at each one.
--
-- Loaded after Rules.lua.

local addonName, Wise = ...
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
	if parentName == childName then
		return true
	end
	-- Walk up from parentName; if we find childName, it would form a cycle
	local visited = {}
	local current = parentName
	while current do
		if current == childName then
			return true
		end
		if visited[current] then
			return false
		end -- already a cycle in the data, but not involving childName
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
	rotationMode = "jump", -- "jump" or "button" (top-level nesting mode)
	buttonMode = "cycle", -- Sub-mode for button: "cycle", "random", "priority"
	keepOpenAfterUse = false, -- Keep child interface open after using an action
	inheritHideOnUse = true, -- Child inherits parent's hideOnUse setting
	openDirection = "auto", -- "auto", "up", "down", "left", "right" - where child appears
	nestedInterfaceType = "default", -- "default", "circle", "line", "box", "list"
	nestedInterfaceStyle = "default", -- "default" (inherit), "dynamic" (hide unavailable), "static" (grey out unavailable)
	nestedTextAlign = "auto", -- "auto", "right", "left" - text side for nested list children
}

--- Get the effective nesting options for an interface action, merging defaults.
--- @param actionData table The action entry (type="interface")
--- @return table options Merged nesting options
function Wise:GetNestingOptions(actionData)
	if not actionData or actionData.type ~= "interface" then
		return nil
	end
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
	if not actionData or actionData.type ~= "interface" then
		return
	end
	if Wise.NESTING_DEFAULTS[key] == nil then
		return
	end -- unknown option
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

