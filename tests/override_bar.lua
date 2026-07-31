-- wow-ui-sim tests for the override/vehicle bar slot resolution.
--
-- Wise:ResolveBarActionID must mirror Blizzard's ActionBarController_UpdateAll
-- priority: HasVehicleActionBar() FIRST, then HasOverrideActionBar(), then
-- HasTempShapeshiftActionBar(). Both vehicle and override flags can be true at
-- the same time (e.g. the Xeronia drake in the Archival Assault delve); the
-- actions live on the VEHICLE page then, and picking the override page reads
-- empty slots (blank icons on Wise's replacement bar).
--
-- Sim caveats (see _dev_ AGENTS.md / memory): C_* namespaces cannot be
-- replaced wholesale — patch FIELDS on the existing table and restore them.
-- Plain function globals (HasVehicleActionBar etc.) CAN be swapped via _G.

local function withBarState(state, fn)
	local savedG = {
		HasVehicleActionBar = _G.HasVehicleActionBar,
		HasOverrideActionBar = _G.HasOverrideActionBar,
		HasTempShapeshiftActionBar = _G.HasTempShapeshiftActionBar,
	}
	local savedC = {}
	local cFields = {
		"HasVehicleActionBar",
		"HasOverrideActionBar",
		"HasTempShapeshiftActionBar",
		"GetVehicleBarIndex",
		"GetOverrideBarIndex",
		"GetTempShapeshiftBarIndex",
	}
	if C_ActionBar then
		for _, k in ipairs(cFields) do
			savedC[k] = C_ActionBar[k]
		end
	end

	_G.HasVehicleActionBar = function()
		return state.vehicle or false
	end
	_G.HasOverrideActionBar = function()
		return state.override or false
	end
	_G.HasTempShapeshiftActionBar = function()
		return state.shapeshift or false
	end
	if C_ActionBar then
		C_ActionBar.HasVehicleActionBar = _G.HasVehicleActionBar
		C_ActionBar.HasOverrideActionBar = _G.HasOverrideActionBar
		C_ActionBar.HasTempShapeshiftActionBar = _G.HasTempShapeshiftActionBar
		C_ActionBar.GetVehicleBarIndex = function()
			return state.vehiclePage or 16
		end
		C_ActionBar.GetOverrideBarIndex = function()
			return state.overridePage or 18
		end
		C_ActionBar.GetTempShapeshiftBarIndex = function()
			return state.shapeshiftPage or 17
		end
	end

	local ok, err = pcall(fn)

	for k, v in pairs(savedG) do
		_G[k] = v
	end
	if C_ActionBar then
		for _, k in ipairs(cFields) do
			C_ActionBar[k] = savedC[k]
		end
	end

	if not ok then
		error(err, 0)
	end
end

-- Page N buttons occupy slots (N-1)*12+1 .. N*12.
test("ResolveBarActionID: vehicle page wins when BOTH vehicle and override bars are up", function()
	withBarState({ vehicle = true, override = true, vehiclePage = 16, overridePage = 18 }, function()
		-- slot 133 = OverrideActionBarButton1 → vehicle page 16 → slot 181
		assertEquals(181, Wise:ResolveBarActionID(133))
		-- slot 144 = button 12 → 192
		assertEquals(192, Wise:ResolveBarActionID(144))
	end)
end)

test("ResolveBarActionID: override page used when only the override bar is up", function()
	withBarState({ vehicle = false, override = true, overridePage = 18 }, function()
		-- slot 133 → override page 18 → slot 205
		assertEquals(205, Wise:ResolveBarActionID(133))
	end)
end)

test("ResolveBarActionID: temp shapeshift page used when it is the only special bar", function()
	withBarState({ shapeshift = true, shapeshiftPage = 17 }, function()
		-- slot 133 → shapeshift page 17 → slot 193
		assertEquals(193, Wise:ResolveBarActionID(133))
	end)
end)

test("ResolveBarActionID: no special bar leaves the raw slot untouched", function()
	withBarState({}, function()
		assertEquals(133, Wise:ResolveBarActionID(133))
		assertEquals(121, Wise:ResolveBarActionID(121))
		-- non-special slots always pass through
		assertEquals(5, Wise:ResolveBarActionID(5))
	end)
end)
