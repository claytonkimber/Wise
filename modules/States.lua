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
-- [vehicleui].
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
		-- WoW macro conditionals like [bonusbar:N], [bar:N], [actionbar:N] do not have
		-- a "no" negation form in the WoW client (e.g. [nobonusbar:5] is invalid syntax
		-- and causes the entire condition bracket to fail). Omit them from negation.
		if part:find("^bonusbar") or part:find("^bar") or part:find("^actionbar") then
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

local function isSpecialBarState(s)
	if not s then
		return false
	end
	local c = s.conditions or s.condition or ""
	if
		c:find("overridebar", 1, true)
		or c:find("vehicleui", 1, true)
		or c:find("canexitvehicle", 1, true)
		or c:find("possessbar", 1, true)
		or c:find("bonusbar:5", 1, true)
	then
		return true
	end
	local aType = s.type
	local aVal = tonumber(s.value)
	if aType == "action" and aVal and aVal >= 121 and aVal <= 156 then
		return true
	end
	if aType == "misc" and (s.value == "overridebar" or s.value == "possessbar") then
		return true
	end
	return false
end

function Wise:ComputeEffectiveConditions(states, stateIdx)
	local state = states[stateIdx]
	if not state then
		return ""
	end
	local baseCond = state.conditions or state.condition or ""
	local isCurSpecial = isSpecialBarState(state)

	local exclusions = {}
	local seenExclusions = {}
	for i, s in ipairs(states) do
		if i ~= stateIdx and s.exclusive and s.conditions and s.conditions ~= "" and s.conditions ~= baseCond then
			local isOtherSpecial = isSpecialBarState(s)
			-- Special bar states (overridebar, vehicleui, possessbar, bonusbar:5) describe
			-- overlapping special vehicle/override bar states and must NOT negate each other
			-- (a possess vehicle raises both [possessbar] and [vehicleui]).
			-- They ONLY negate non-special-bar fallback states (class spells, items, etc.).
			if not (isCurSpecial and isOtherSpecial) then
				local negated = Wise:NegateConditional(s.conditions)
				if negated then
					local inner = string.match(negated, "^%[(.+)%]$") or negated
					for token in inner:gmatch("[^,]+") do
						token = token:match("^%s*(.-)%s*$")
						if token ~= "" and not seenExclusions[token] then
							seenExclusions[token] = true
							table.insert(exclusions, token)
						end
					end
				end
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
