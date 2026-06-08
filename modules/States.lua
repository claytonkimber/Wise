-- States.lua
local addonName, Wise = ...

local pairs = pairs
local ipairs = ipairs
local string = string
local table = table

-- Helper to negate a conditional
function Wise:NegateConditional(cond)
	if not cond or cond == "" then
		return nil
	end
	-- Remove brackets if present
	local cleaned = cond:gsub("^%[", ""):gsub("%]$", "")

	local results = {}
	for part in cleaned:gmatch("[^,]+") do
		part = part:match("^%s*(.-)%s*$") -- trim
		if not string.find(part, "@") then
			if part:sub(1, 2) == "no" then
				table.insert(results, part:sub(3))
			else
				table.insert(results, "no" .. part)
			end
		end
	end

	return "[" .. table.concat(results, ", ") .. "]"
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

	if #exclusions == 0 then
		return baseCond
	end
	local exStr = table.concat(exclusions, ",")

	if baseCond == "" then
		return "[" .. exStr .. "]"
	end

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
