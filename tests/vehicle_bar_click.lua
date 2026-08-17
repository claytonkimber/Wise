-- wow-ui-sim tests for the unskinned-vehicle click bug (2026-08-17).
--
-- Symptom: on the Gnarldor Isle war turtle the replacement bar showed the
-- CORRECT four icons but the buttons did nothing. The display path is pure page
-- arithmetic off C_ActionBar.GetVehicleBarIndex() (Wise:ResolveBarActionID), so
-- it is right for every kind of special bar. The CLICK path binds a frame by
-- NAME, and that is where the two vehicle kinds diverge:
--
--   * SKINNED vehicle   → LE_ACTIONBAR_STATE_OVERRIDE, spells on
--                         OverrideActionBarButton<N>.
--   * UNSKINNED vehicle → LE_ACTIONBAR_STATE_MAIN, MainActionBar merely repaged
--                         to GetVehicleBarIndex(), spells on ActionButton<N>.
--
-- (Both pinned by wow-ui-sim's own Blizzard_ActionBarController behaviour tests:
-- behavior_update_vehicle_skinned.rs and
-- behavior_update_vehicle_unskinned_uses_vehicle_index.rs.)
--
-- [vehicleui] is true for BOTH kinds, so the old macro — which bound
-- OverrideActionBarButton<N> behind [vehicleui] — named an unmounted frame on
-- the turtle. [overridebar] (= HasOverrideActionBar()) is the real skinned test;
-- it was confirmed false in-client while mounted on the turtle.

local function withOverrideButtons(count, fn)
	local saved = {}
	for i = 1, 32 do
		saved[i] = _G["OverrideActionBarButton" .. i]
	end
	for i = 1, 32 do
		if i <= count then
			local name = "OverrideActionBarButton" .. i
			_G[name] = {
				GetName = function()
					return name
				end,
			}
		else
			_G["OverrideActionBarButton" .. i] = nil
		end
	end
	Wise:ResetOverrideBarButtonCount()

	local ok, err = pcall(fn)

	for i = 1, 32 do
		_G["OverrideActionBarButton" .. i] = saved[i]
	end
	Wise:ResetOverrideBarButtonCount()

	if not ok then
		error(err, 0)
	end
end

-- Split the macro into its conditional lines so assertions can talk about
-- "the line that fires under condition X" rather than exact whitespace.
local function macroLines(macro)
	local lines = {}
	for line in tostring(macro):gmatch("[^\n]+") do
		table.insert(lines, line)
	end
	return lines
end

local function lineFor(macro, cond)
	for _, line in ipairs(macroLines(macro)) do
		if line:find(cond, 1, true) then
			return line
		end
	end
	return nil
end

-- Find all lines routed by a bar token.
local function routeLines(macro, token)
	local matches = {}
	for _, line in ipairs(macroLines(macro)) do
		for group in line:gmatch("%[([^%]]*)%]") do
			for part in group:gmatch("[^,]+") do
				if part:match("^%s*(.-)%s*$") == token then
					table.insert(matches, line)
					break
				end
			end
		end
	end
	return matches
end

local function routeLine(macro, token)
	local lines = routeLines(macro, token)
	return lines[1]
end

-- ── The unskinned vehicle must reach ActionButton<N> ────────────────────────

test("BuildSpecialBarClickMacro: [vehicleui] routes to both OverrideActionBarButton and ActionButton", function()
	withOverrideButtons(8, function()
		local macro = Wise:BuildSpecialBarClickMacro(3)
		local vehicleLines = routeLines(macro, "vehicleui")
		assert(#vehicleLines >= 2, "macro must contain at least 2 [vehicleui] lines, got: " .. tostring(macro))
		assert(
			vehicleLines[1]:find("OverrideActionBarButton3", 1, true),
			"[vehicleui] first line must click OverrideActionBarButton3: " .. vehicleLines[1]
		)
		assert(
			vehicleLines[2]:find("ActionButton3", 1, true),
			"[vehicleui] second line must click ActionButton3: " .. vehicleLines[2]
		)
	end)
end)

-- ── The skinned vehicle / true override bar still reaches the override bar ──

test("BuildSpecialBarClickMacro: [overridebar] still binds OverrideActionBarButton", function()
	withOverrideButtons(8, function()
		local macro = Wise:BuildSpecialBarClickMacro(3)
		local ovrLine = routeLine(macro, "overridebar")
		assert(ovrLine, "macro must contain an [overridebar] line, got: " .. tostring(macro))
		assert(
			ovrLine:find("OverrideActionBarButton3", 1, true),
			"[overridebar] must click OverrideActionBarButton3: " .. ovrLine
		)
	end)
end)

test("BuildSpecialBarClickMacro: [overridebar] is ordered before [vehicleui]", function()
	withOverrideButtons(8, function()
		-- Supply caller conditions too: the ordering must hold once they are
		-- merged into each group, which is the shape an exclusive slot produces.
		local macro = Wise:BuildSpecialBarClickMacro(1, "[nocombat]")
		local ovrLine, vehLine = routeLine(macro, "overridebar"), routeLine(macro, "vehicleui")
		local ovrAt, vehAt
		for i, line in ipairs(macroLines(macro)) do
			if line == ovrLine then
				ovrAt = ovrAt or i
			end
			if line == vehLine then
				vehAt = vehAt or i
			end
		end
		assert(ovrAt and vehAt, "macro must contain both lines")
		-- A skinned vehicle raises BOTH [overridebar] and [vehicleui]. The
		-- override line must win, or skinned vehicles would fall through to the
		-- main bar — re-breaking the Xeronia drake case fixed on 2026-08-12.
		assert(
			ovrAt < vehAt,
			"[overridebar] must precede [vehicleui] so skinned vehicles keep the override bar"
		)
	end)
end)

-- ── Per-frame index bounds ──────────────────────────────────────────────────

test("BuildSpecialBarClickMacro: each half clamps to its OWN frame range", function()
	withOverrideButtons(6, function()
		-- 8 is past this 6-button override bar, but is a perfectly real
		-- ActionButton. Clamping both halves to the override count would send the
		-- unskinned vehicle to the wrong ability; clamping neither would rebuild
		-- the dead-/click bug. Each half needs its own bound.
		local macro = Wise:BuildSpecialBarClickMacro(8)
		local ovrLine = routeLine(macro, "overridebar")
		local vehLines = routeLines(macro, "vehicleui")
		assert(
			ovrLine:find("OverrideActionBarButton1", 1, true),
			"out-of-range override index must fall back to button 1"
		)
		assert(
			vehLines[2]:find("ActionButton8", 1, true),
			"ActionButton8 is real on the main bar and must be preserved"
		)
	end)
end)

test("BuildSpecialBarClickMacro: caller conditions MERGE into each route group", function()
	withOverrideButtons(8, function()
		local macro = Wise:BuildSpecialBarClickMacro(2, "[nocombat]")
		for _, line in ipairs(macroLines(macro)) do
			assert(line:find("nocombat", 1, true), "every line must carry the caller's condition: " .. line)
			-- Must be ANDed INTO the route's group, not concatenated in front of
			-- it. "[nocombat][overridebar]" is an OR — the bare "[nocombat]" clause
			-- alone would fire the line with no bar up at all, which is what killed
			-- every button when an exclusive slot supplied negations.
			assert(
				not line:find("[nocombat]", 1, true),
				"caller condition must not be its own OR group: " .. line
			)
		end
		assert(lineFor(macro, "[nocombat,overridebar]"), "expected merged override group: " .. macro)
		assert(lineFor(macro, "[nocombat,vehicleui]"), "expected merged vehicle group: " .. macro)
		assert(lineFor(macro, "[nocombat,possessbar]"), "expected merged possess group: " .. macro)
		assert(lineFor(macro, "[nocombat,bonusbar:5]"), "expected merged bonusbar group: " .. macro)
	end)
end)

test("BuildSpecialBarClickMacro: multi-group caller conditions stay ANDed", function()
	withOverrideButtons(8, function()
		-- An exclusive slot supplies several groups (an OR). Each must be ANDed
		-- with the route token separately, giving one group per pair — never a
		-- bare caller group that fires on its own.
		local macro = Wise:BuildSpecialBarClickMacro(1, "[nocombat][mounted]")
		for _, line in ipairs(macroLines(macro)) do
			for group in line:gmatch("%[([^%]]*)%]") do
				assert(
					group:find("overridebar", 1, true)
						or group:find("vehicleui", 1, true)
						or group:find("possessbar", 1, true)
						or group:find("bonusbar:5", 1, true),
					"every group must carry a route token, got [" .. group .. "] in: " .. line
				)
			end
		end
	end)
end)

test("BuildSpecialBarClickMacro: missing/invalid index falls back to button 1", function()
	withOverrideButtons(8, function()
		for _, bad in ipairs({ 0, -1, 99 }) do
			local macro = Wise:BuildSpecialBarClickMacro(bad)
			local ovrLine = routeLine(macro, "overridebar")
			local vehLines = routeLines(macro, "vehicleui")
			assert(
				ovrLine:find("OverrideActionBarButton1", 1, true),
				"invalid index " .. bad .. " must clamp the override half to 1"
			)
			assert(
				vehLines[2]:find("ActionButton1", 1, true),
				"invalid index " .. bad .. " must clamp the main half to 1"
			)
		end
		-- nil index (a slot built before overrideIndex existed) behaves as 1.
		local nilVehLines = routeLines(Wise:BuildSpecialBarClickMacro(nil), "vehicleui")
		assert(
			nilVehLines[2]:find("ActionButton1", 1, true),
			"nil index must behave as button 1"
		)
	end)
end)

