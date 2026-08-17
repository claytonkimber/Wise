-- wow-ui-sim tests for exclusivity INSIDE a graph slot (2026-08-17).
--
-- A slot's states can be stored two ways, and exclusivity has to mean the same
-- thing in both:
--
--   * array slot  — discrete states; the engine calls ComputeEffectiveConditions
--                   per state, so an exclusive [overridebar] state makes every
--                   later state inherit [nooverridebar].
--   * graph slot  — every node is compiled into ONE custom_macro whose lines are
--                   built by Wise:FilterMacroTextForCharacter.
--
-- The graph path built each line from the node's RAW condition and never
-- consulted ComputeEffectiveConditions, so an exclusive override/vehicle node did
-- not suppress the later /cast lines. On a vehicle the slot fired (and showed)
-- the character's own spell even though the exclusive vehicle state matched —
-- the reported "slots 5 and 6 show the normal Guardian spells on the turtle".
--
-- Real shape (see the WTF ActionBar group): an exclusive override state, an
-- exclusive possess state, then plain spell fallbacks.

local function graphSlot()
	return {
		nodes = {
			{
				id = 1,
				condition = "[overridebar][vehicleui]",
				action = {
					type = "action",
					value = 133,
					exclusive = true,
					conditions = "[overridebar][vehicleui]",
				},
			},
			{
				id = 2,
				condition = "[possessbar]",
				action = { type = "action", value = 121, exclusive = true, conditions = "[possessbar]" },
			},
			{
				id = 3,
				condition = "",
				action = { type = "spell", value = 740, conditions = "" }, -- Tranquility
			},
		},
	}
end

local function compiledStep()
	return { type = "misc", value = "custom_macro", pathNodeIds = { 1, 2, 3 }, macroText = "" }
end

local function macroFor(graph)
	local text = Wise:FilterMacroTextForCharacter(compiledStep(), graph)
	return text or ""
end

local function lineWith(macro, needle)
	for line in macro:gmatch("[^\n]+") do
		if line:find(needle, 1, true) then
			return line
		end
	end
	return nil
end

test("FilterMacroTextForCharacter: the fallback line inherits the exclusions", function()
	local macro = macroFor(graphSlot())
	local castLine = lineWith(macro, "/cast")
	assert(castLine, "expected a /cast fallback line in: " .. macro)
	-- THE regression: this line used to be a bare "/cast Tranquility", so it
	-- fired and rendered while a vehicle bar was up.
	for _, token in ipairs({ "nooverridebar", "novehicleui" }) do
		assert(
			castLine:find(token, 1, true),
			"fallback must inherit " .. token .. ", got: " .. castLine
		)
	end
end)

test("FilterMacroTextForCharacter: the exclusive node keeps its own condition", function()
	local macro = macroFor(graphSlot())
	local clickLine = lineWith(macro, "OverrideActionBarButton")
	assert(clickLine, "expected the override /click line in: " .. macro)
	assert(clickLine:find("overridebar", 1, true), "override line lost its condition: " .. clickLine)
	-- It must not negate ITSELF — only the other exclusive node.
	assert(not clickLine:find("nooverridebar", 1, true), "override line negated itself: " .. clickLine)
	assert(not clickLine:find("novehicleui", 1, true), "override line negated itself: " .. clickLine)
end)

test("FilterMacroTextForCharacter: a slot with no exclusive node is unchanged", function()
	-- Plain multi-spell slots must not suddenly grow negations.
	local graph = {
		nodes = {
			{ id = 1, condition = "", action = { type = "spell", value = 740, conditions = "" } },
			{ id = 2, condition = "", action = { type = "spell", value = 1850, conditions = "" } },
		},
	}
	local macro = macroFor(graph)
	assert(not macro:find("no", 1, true) or not macro:find("nooverridebar", 1, true), "unexpected negation in: " .. macro)
end)

test("FilterMacroTextForCharacter: node.condition outranks the stored copy", function()
	-- The picker's action.conditions can lag an edited node; the node's own
	-- condition is the authority the engine compiled from.
	local graph = {
		nodes = {
			{
				id = 1,
				condition = "[overridebar][vehicleui]",
				action = {
					type = "action",
					value = 133,
					exclusive = true,
					-- Stale stored copy from before the migration.
					conditions = "[overridebar]",
				},
			},
			{ id = 2, condition = "", action = { type = "spell", value = 740, conditions = "" } },
		},
	}
	local castLine = lineWith(macroFor(graph), "/cast")
	assert(castLine, "expected a /cast line")
	assert(
		castLine:find("novehicleui", 1, true),
		"fallback must inherit novehicleui from the NODE condition, got: " .. castLine
	)
end)
