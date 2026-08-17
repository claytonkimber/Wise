-- wow-ui-sim tests for special-bar slot VISIBILITY (2026-08-17).
--
-- Companion to tests/vehicle_bar_click.lua. That file pins where a special-bar
-- slot's click GOES; this one pins whether the slot is SHOWN at all.

local function findItem(items, name)
	for _, it in ipairs(items) do
		if it.name == name then
			return it
		end
	end
	return nil
end

local REQUIRED_STATES = { "overridebar", "vehicleui" }

test("GetSpecialActionbars: override slots also match on an unskinned vehicle and are exclusive", function()
	local items = Wise:GetSpecialActionbars()
	for _, name in ipairs({ "Override Bar Button 1", "Override Bar Button 4" }) do
		local item = findItem(items, name)
		assert(item, name .. " must exist")
		assertEquals(true, item.exclusive, name .. " must be exclusive")
		for _, state in ipairs(REQUIRED_STATES) do
			assert(
				(item.conditions or ""):find(state, 1, true),
				name .. " must match under [" .. state .. "]; got: " .. tostring(item.conditions)
			)
		end
	end
end)

test("GetSpecialActionbars: possess slots and override slots exist and are exclusive", function()
	local items = Wise:GetSpecialActionbars()
	local possess = findItem(items, "Possess Bar Button 1")
	local override = findItem(items, "Override Bar Button 1")
	assert(possess and override, "both slot kinds must exist")
	assertEquals(true, possess.exclusive, "possess slot must be exclusive")
	assertEquals(true, override.exclusive, "override slot must be exclusive")
	assertEquals("[possessbar][bonusbar:5]", possess.conditions)
	assertEquals("[overridebar][vehicleui]", override.conditions)
end)

test("ComputeEffectiveConditions: bar states stay separate bracket groups", function()
	local states = { { type = "action", value = 133, conditions = "[overridebar][vehicleui]" } }
	local cond = Wise:ComputeEffectiveConditions(states, 1)
	local groups = 0
	for _ in cond:gmatch("%[([^%]]*)%]") do
		groups = groups + 1
	end
	assertEquals(2, groups)
	for _, state in ipairs(REQUIRED_STATES) do
		assert(cond:find("%[" .. state .. "%]"), state .. " must be its own group: " .. cond)
	end
end)

local function withBarState(state, fn)
	local saved = {
		HasVehicleActionBar = _G.HasVehicleActionBar,
		HasOverrideActionBar = _G.HasOverrideActionBar,
		HasTempShapeshiftActionBar = _G.HasTempShapeshiftActionBar,
		IsPossessBarVisible = _G.IsPossessBarVisible,
		HasBonusActionBar = _G.HasBonusActionBar,
		GetBonusBarOffset = _G.GetBonusBarOffset,
		UnitInVehicle = _G.UnitInVehicle,
		UnitHasVehicleUI = _G.UnitHasVehicleUI,
		C_ActionBar = _G.C_ActionBar,
	}
	_G.HasVehicleActionBar = function()
		return state.vehicle or false
	end
	_G.HasOverrideActionBar = function()
		return state.override or false
	end
	_G.HasTempShapeshiftActionBar = function()
		return state.shapeshift or false
	end
	_G.IsPossessBarVisible = function()
		return state.possess or false
	end
	_G.HasBonusActionBar = function()
		return state.bonus or false
	end
	_G.GetBonusBarOffset = function()
		return state.bonusOffset or (state.possess and 5 or 0)
	end
	_G.UnitInVehicle = function()
		return state.unitInVehicle or false
	end
	_G.UnitHasVehicleUI = function(unit)
		return (unit == "player" and state.vehicleUI) or false
	end
	_G.C_ActionBar = {
		IsPossessBarVisible = function()
			return state.possess or false
		end,
	}

	local ok, err = pcall(fn)

	for k, v in pairs(saved) do
		_G[k] = v
	end
	if not ok then
		error(err, 0)
	end
end

test("HasAnySpecialActionBar: false only when no special bar is up", function()
	withBarState({}, function()
		assertEquals(false, Wise:HasAnySpecialActionBar())
	end)
	withBarState({ vehicle = true }, function()
		assertEquals(true, Wise:HasAnySpecialActionBar())
	end)
	withBarState({ override = true }, function()
		assertEquals(true, Wise:HasAnySpecialActionBar())
	end)
	withBarState({ shapeshift = true }, function()
		assertEquals(true, Wise:HasAnySpecialActionBar())
	end)
	withBarState({ possess = true }, function()
		assertEquals(true, Wise:HasAnySpecialActionBar())
	end)
	withBarState({ vehicleUI = true }, function()
		assertEquals(true, Wise:HasAnySpecialActionBar())
	end)
end)

test("ResolveBarActionID: possess ids fall through onto action bar 12", function()
	withBarState({}, function()
		assertEquals(121, Wise:ResolveBarActionID(121))
		assertEquals(132, Wise:ResolveBarActionID(132))
		assertEquals(133, Wise:ResolveBarActionID(133))
	end)
end)

local BAD_DEFAULT = "[overridebar][vehicleui][possessbar]"
local function runMigration(group)
	local OVERRIDE_COND = "[overridebar][vehicleui]"
	local function needsMigration(cond)
		return cond == "[overridebar]" or cond == BAD_DEFAULT
	end
	local function migrateEntry(entry)
		local action = entry and entry.action or entry
		local v = tonumber(action and action.value)
		local isOverrideSlot = action and action.type == "action" and v and v >= 133 and v <= 144
		local isOverrideMisc = action and action.type == "misc" and action.value == "overridebar"
		if isOverrideSlot or isOverrideMisc then
			action.exclusive = true
			if entry then
				entry.exclusive = true
			end
			if needsMigration(action.conditions) then
				action.conditions = OVERRIDE_COND
				if entry and needsMigration(entry.condition) then
					entry.condition = OVERRIDE_COND
				end
			end
		end
		local POSSESS_COND = "[possessbar][bonusbar:5]"
		local isPossessSlot = action and action.type == "action" and v and v >= 121 and v <= 132
		local isPossessMisc = action and action.type == "misc" and action.value == "possessbar"
		if isPossessSlot or isPossessMisc then
			action.exclusive = true
			if entry then
				entry.exclusive = true
			end
			if
				action.conditions == BAD_DEFAULT
				or action.conditions == "[possessbar]"
				or action.conditions == "[bonusbar:5]"
				or action.conditions == "[overridebar][vehicleui]"
				or needsMigration(action.conditions)
			then
				action.conditions = POSSESS_COND
				if entry then
					entry.condition = POSSESS_COND
				end
			end
		end
	end
	for _, slotStates in pairs(group.actions or {}) do
		if type(slotStates) == "table" then
			for _, entry in ipairs(slotStates) do
				migrateEntry(entry)
			end
			if slotStates.graph and type(slotStates.graph.nodes) == "table" then
				for _, node in ipairs(slotStates.graph.nodes) do
					migrateEntry(node)
				end
			end
		end
	end
end

test("migration: graph-shaped slots are migrated, not just array-shaped ones", function()
	local group = {
		actions = {
			[6] = {
				{
					condition = "[overridebar]",
					action = { type = "action", value = 138, conditions = "[overridebar]" },
				},
			},
			[1] = {
				graph = {
					nodes = {
						{
							condition = "[overridebar]",
							action = { type = "action", value = 133, conditions = "[overridebar]" },
						},
					},
				},
			},
		},
	}
	runMigration(group)
	assertEquals("[overridebar][vehicleui]", group.actions[6][1].action.conditions)
	assertEquals("[overridebar][vehicleui]", group.actions[1].graph.nodes[1].action.conditions)
	assertEquals("[overridebar][vehicleui]", group.actions[1].graph.nodes[1].condition)
end)

test("migration: possess states are migrated to [possessbar][bonusbar:5]", function()
	local group = {
		actions = {
			[1] = {
				graph = {
					nodes = {
						{
							condition = "[possessbar]",
							action = { type = "action", value = 121, conditions = "[possessbar]" },
						},
					},
				},
			},
		},
	}
	runMigration(group)
	assertEquals("[possessbar][bonusbar:5]", group.actions[1].graph.nodes[1].action.conditions)
end)

test("migration: repairs the bad [overridebar][vehicleui][possessbar] default", function()
	local group = {
		actions = {
			[6] = {
				{
					condition = "[overridebar][vehicleui][possessbar]",
					action = {
						type = "action",
						value = 138,
						conditions = "[overridebar][vehicleui][possessbar]",
					},
				},
				{
					condition = "[possessbar]",
					action = { type = "action", value = 126, conditions = "[possessbar]" },
				},
			},
		},
	}
	runMigration(group)
	assertEquals("[overridebar][vehicleui]", group.actions[6][1].action.conditions)
	assertEquals("[overridebar][vehicleui]", group.actions[6][1].condition)
	assertEquals("[possessbar][bonusbar:5]", group.actions[6][2].action.conditions)
end)

test("migration: a possess state carrying the bad default is migrated to [possessbar][bonusbar:5]", function()
	local group = {
		actions = {
			[6] = {
				{
					condition = "[overridebar][vehicleui][possessbar]",
					action = {
						type = "action",
						value = 126,
						conditions = "[overridebar][vehicleui][possessbar]",
					},
				},
			},
		},
	}
	runMigration(group)
	assertEquals("[possessbar][bonusbar:5]", group.actions[6][1].action.conditions)
end)

test("NegateConditional: multiple bracket groups collapse into ONE negated group", function()
	local negated = Wise:NegateConditional("[overridebar][vehicleui]")
	local groups = 0
	for _ in negated:gmatch("%[([^%]]*)%]") do
		groups = groups + 1
	end
	assertEquals(1, groups)
	for _, state in ipairs({ "overridebar", "vehicleui" }) do
		assert(negated:find("no" .. state, 1, true), "missing no" .. state .. ": " .. negated)
	end
end)

test("NegateConditional: single group and bare input still negate", function()
	assertEquals("[nocombat]", Wise:NegateConditional("[combat]"))
	assertEquals("[combat]", Wise:NegateConditional("[nocombat]"))
	assertEquals("[nocombat]", Wise:NegateConditional("combat"))
end)

test("NegateConditional: a repeated token is emitted once", function()
	local negated = Wise:NegateConditional("[combat][combat,mounted]")
	local count = 0
	for _ in negated:gmatch("nocombat") do
		count = count + 1
	end
	assertEquals(1, count)
	assert(negated:find("nomounted", 1, true), "missing nomounted: " .. negated)
end)

local function realSlotStates()
	return {
		{ type = "action", value = 133, conditions = "[overridebar][vehicleui]", exclusive = true },
		{ type = "action", value = 121, conditions = "[possessbar][bonusbar:5]", exclusive = true },
		{ type = "spell", value = 740 },
	}
end

test("ComputeEffectiveConditions: a fallback negates every widened bar state", function()
	local cond = Wise:ComputeEffectiveConditions(realSlotStates(), 3)
	assert(cond ~= "", "fallback must not remain unconditional")
	for _, state in ipairs({ "overridebar", "vehicleui", "possessbar", "bonusbar:5" }) do
		assert(
			cond:find("no" .. state, 1, true),
			"fallback must inherit no" .. state .. ", got: " .. cond
		)
	end
end)

test("ComputeEffectiveConditions: the exclusive state keeps its own conditions", function()
	local cond = Wise:ComputeEffectiveConditions(realSlotStates(), 1)
	for _, state in ipairs({ "overridebar", "vehicleui" }) do
		assert(cond:find(state, 1, true), "exclusive state lost " .. state .. ": " .. cond)
		assert(
			not cond:find("no" .. state, 1, true),
			"exclusive state negated itself on " .. state .. ": " .. cond
		)
	end
end)

test("migration: sets exclusive=true on all override and possess entries", function()
	local group = {
		actions = {
			[1] = {
				graph = {
					nodes = {
						{ action = { type = "action", value = 133, conditions = "[overridebar]" } },
						{ action = { type = "action", value = 121, conditions = "[possessbar]" } },
					},
				},
			},
			[6] = {
				{ action = { type = "action", value = 138, conditions = "[overridebar]" } },
			},
		},
	}
	runMigration(group)
	assertEquals(true, group.actions[1].graph.nodes[1].action.exclusive)
	assertEquals(true, group.actions[1].graph.nodes[1].exclusive)
	assertEquals(true, group.actions[1].graph.nodes[2].action.exclusive)
	assertEquals(true, group.actions[1].graph.nodes[2].exclusive)
	assertEquals("[possessbar][bonusbar:5]", group.actions[1].graph.nodes[2].action.conditions)
	assertEquals(true, group.actions[6][1].action.exclusive)
	assertEquals(true, group.actions[6][1].exclusive)
end)

test("FilterMacroTextForCharacter: auto-treats special bar nodes as exclusive", function()
	local origAllowed = Wise.IsActionAllowed
	Wise.IsActionAllowed = function()
		return true
	end

	local state = {
		type = "misc",
		value = "custom_macro",
		pathNodeIds = { 1, 2, 3 },
	}
	local graph = {
		nodes = {
			{ id = 1, action = { type = "action", value = 133 }, condition = "[overridebar][vehicleui]" },
			{ id = 2, action = { type = "action", value = 121 }, condition = "[possessbar]" },
			{ id = 3, action = { type = "spell", value = 740 }, condition = "" },
		},
	}
	local liveMacro = Wise:FilterMacroTextForCharacter(state, graph)
	Wise.IsActionAllowed = origAllowed

	assert(liveMacro, "liveMacro must be generated")
	assert(
		liveMacro:find("nooverridebar", 1, true) and liveMacro:find("nopossessbar", 1, true),
		"fallback spell must inherit negation of special bar states even when node exclusive was nil: " .. liveMacro
	)
end)
