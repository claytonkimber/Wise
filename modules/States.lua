-- States.lua
local addonName, Wise = ...

local pairs = pairs
local ipairs = ipairs
local string = string
local table = table

-- Helper to negate a conditional.
--
-- Multiple bracket groups are an OR ("[a][b]" = a OR b), so the negation is an
-- AND of the negated groups — one bracket holding every negated token. Stripping
-- only the outermost brackets and splitting on commas silently mangled
-- multi-group input: "[overridebar][vehicleui]" became the single blob
-- "overridebar][vehicleui", whose first token alone got negated, yielding
-- "[nooverridebar][vehicleui]" — a condition that still MATCHES under
-- [vehicleui]. An exclusive special-bar state plus a plain fallback therefore
-- showed the fallback on top of a live vehicle bar.
function Wise:NegateConditional(cond)
	if not cond or cond == "" then
		return nil
	end

	local results = {}
	local seen = {}
	local function negateToken(part)
		part = part:match("^%s*(.-)%s*$") -- trim
		if part == "" or string.find(part, "@") then
			return
		end
		local negated
		if part:sub(1, 2) == "no" then
			negated = part:sub(3)
		else
			negated = "no" .. part
		end
		-- The same token can appear in several groups; emit it once.
		if not seen[negated] then
			seen[negated] = true
			table.insert(results, negated)
		end
	end

	local sawGroup = false
	for group in cond:gmatch("%[([^%]]*)%]") do
		sawGroup = true
		for part in group:gmatch("[^,]+") do
			negateToken(part)
		end
	end
	-- Bare, unbracketed input (e.g. "combat") still negates.
	if not sawGroup then
		for part in cond:gmatch("[^,]+") do
			negateToken(part)
		end
	end

	if #results == 0 then
		return nil
	end

	return "[" .. table.concat(results, ",") .. "]"
end

function Wise:ComputeEffectiveConditions(states, stateIdx)
	local state = states[stateIdx]
	local baseCond = state.conditions or ""

	local exclusions = {}
	for i, s in ipairs(states) do
		if i ~= stateIdx and s.exclusive and s.conditions and s.conditions ~= "" and s.conditions ~= baseCond then
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
