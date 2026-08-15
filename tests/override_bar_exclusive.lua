-- wow-ui-sim tests for the two override-bar bugs fixed 2026-08-12.
--
-- Bug 1 — every misc "overridebar"/"possessbar" button resolved base slot
-- 133/121, so N such buttons on one bar all showed button 1's icon, cooldown
-- and tooltip. They still FIRED correctly (the click path binds
-- OverrideActionBarButton<N> by name), which is why the symptom was
-- "right tooltip, wrong icon" on some buttons but not others.
-- Wise:ResolveMiscBarActionID must map meta.overrideIndex → the right slot.
--
-- Bug 2 — a slot whose [overridebar] state is marked `exclusive` alongside an
-- unconditional fallback state (e.g. "Override Bar Button 6" + Dash) never hid
-- while the override bar was up. The visibility driver treated the
-- unconditional state as an always-matches fallback and skipped the driver
-- entirely, even though ComputeEffectiveConditions had already negated it.
-- Exclusivity was honoured for CASTING but not for DISPLAY.

-- Stub exactly `count` OverrideActionBarButton<N> frames, run fn, then restore.
-- Wise:GetOverrideBarButtonCount caches its first non-zero probe, so the cache is
-- cleared around the body to force a re-probe against the stubbed set.
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

local function withBarState(state, fn)
	local saved = {
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

	for k, v in pairs(saved) do
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

-- ── Bug 1: per-button resolution ────────────────────────────────────────────

test("ResolveMiscBarActionID: each override button resolves its OWN slot", function()
	withOverrideButtons(8, function()
		withBarState({ override = true, overridePage = 18 }, function()
			-- Override page 18 → slots 205-216. Button N must land on 204 + N,
			-- NOT all collapse onto 205 (the pre-fix behaviour).
			assertEquals(205, Wise:ResolveMiscBarActionID({ overrideIndex = 1 }, 133))
			assertEquals(206, Wise:ResolveMiscBarActionID({ overrideIndex = 2 }, 133))
			assertEquals(207, Wise:ResolveMiscBarActionID({ overrideIndex = 3 }, 133))
			assertEquals(212, Wise:ResolveMiscBarActionID({ overrideIndex = 8 }, 133))
		end)
	end)
end)

-- ── Bug 3: index past the last real override button ─────────────────────────
-- A slot whose index exceeded the override bar's button count built a
-- "/click OverrideActionBarButton<N>" for a frame that does not exist. The click
-- silently no-ops ("You can't do that right now") while the DISPLAY path — pure
-- index arithmetic — still resolved a valid-looking action id, so the button
-- showed a correct icon and tooltip but could not be used at all.

test("GetOverrideBarButtonCount: counts the real frames, stopping at the first gap", function()
	withOverrideButtons(8, function()
		assertEquals(8, Wise:GetOverrideBarButtonCount())
	end)
	withOverrideButtons(6, function()
		assertEquals(6, Wise:GetOverrideBarButtonCount())
	end)
end)

test("GetOverrideBarButtonCount: a gap stops the count (stray high frame ignored)", function()
	withOverrideButtons(5, function()
		-- A frame well past the contiguous run must not inflate the bound.
		_G["OverrideActionBarButton12"] = { GetName = function() return "OverrideActionBarButton12" end }
		Wise:ResetOverrideBarButtonCount()
		assertEquals(5, Wise:GetOverrideBarButtonCount())
		_G["OverrideActionBarButton12"] = nil
	end)
end)

test("IsValidOverrideBarIndex: rejects indices past the last real button", function()
	withOverrideButtons(8, function()
		assertEquals(true, Wise:IsValidOverrideBarIndex(1))
		assertEquals(true, Wise:IsValidOverrideBarIndex(8))
		-- 9-12 exist on the MAIN bar (NUM_ACTIONBAR_BUTTONS) but not here. These
		-- are the indices that used to pass the old clamp and build a dead /click.
		assertEquals(false, Wise:IsValidOverrideBarIndex(9))
		assertEquals(false, Wise:IsValidOverrideBarIndex(12))
		assertEquals(false, Wise:IsValidOverrideBarIndex(0))
		assertEquals(false, Wise:IsValidOverrideBarIndex(nil))
	end)
end)

test("IsValidOverrideBarIndex: tracks a shorter bar without code changes", function()
	withOverrideButtons(6, function()
		assertEquals(true, Wise:IsValidOverrideBarIndex(6))
		-- 7 and 8 are valid on an 8-button bar but must be rejected on a 6-button
		-- one — the whole point of probing instead of hardcoding.
		assertEquals(false, Wise:IsValidOverrideBarIndex(7))
		assertEquals(false, Wise:IsValidOverrideBarIndex(8))
	end)
end)

test("ResolveMiscBarActionID: out-of-range index falls back to button 1", function()
	withOverrideButtons(8, function()
		withBarState({ override = true, overridePage = 18 }, function()
			-- 9 passed the old NUM_ACTIONBAR_BUTTONS clamp and resolved to 213,
			-- pairing a live tooltip with a /click that could never fire.
			assertEquals(205, Wise:ResolveMiscBarActionID({ overrideIndex = 9 }, 133))
			assertEquals(205, Wise:ResolveMiscBarActionID({ overrideIndex = 12 }, 133))
		end)
	end)
end)

test("ResolveMiscBarActionID: possess buttons resolve per-button too", function()
	withBarState({ vehicle = true, vehiclePage = 16 }, function()
		-- Vehicle page 16 → slots 181-192.
		assertEquals(181, Wise:ResolveMiscBarActionID({ overrideIndex = 1 }, 121))
		assertEquals(184, Wise:ResolveMiscBarActionID({ overrideIndex = 4 }, 121))
	end)
end)

test("ResolveMiscBarActionID: missing/invalid index falls back to button 1", function()
	withBarState({ override = true, overridePage = 18 }, function()
		assertEquals(205, Wise:ResolveMiscBarActionID(nil, 133))
		assertEquals(205, Wise:ResolveMiscBarActionID({}, 133))
		assertEquals(205, Wise:ResolveMiscBarActionID({ overrideIndex = 0 }, 133))
		assertEquals(205, Wise:ResolveMiscBarActionID({ overrideIndex = 99 }, 133))
	end)
end)

test("ResolveMiscBarActionID: no special bar leaves the base slot untouched", function()
	withBarState({}, function()
		assertEquals(135, Wise:ResolveMiscBarActionID({ overrideIndex = 3 }, 133))
		assertEquals(123, Wise:ResolveMiscBarActionID({ overrideIndex = 3 }, 121))
	end)
end)

-- ── Bug 2: exclusivity must reach the visibility driver ─────────────────────

-- This mirrors the real saved config: an exclusive [overridebar] state, an
-- exclusive [possessbar] state, and a plain unconditional spell fallback.
local function overrideSlotStates()
	return {
		{ type = "action", value = 138, conditions = "[overridebar]", exclusive = true },
		{ type = "action", value = 126, conditions = "[possessbar]", exclusive = true },
		{ type = "spell", value = 1850 }, -- Dash: no conditions
	}
end

test("ComputeEffectiveConditions: unconditional fallback inherits the negations", function()
	local states = overrideSlotStates()
	local cond = Wise:ComputeEffectiveConditions(states, 3)
	-- The fallback must NOT stay unconditional — it has to carry
	-- [nooverridebar,nopossessbar], which is what lets the driver hide the
	-- slot while the override bar is up.
	assert(cond ~= "", "fallback state must not remain unconditional")
	assert(
		cond:find("nooverridebar", 1, true),
		"fallback must inherit nooverridebar, got: " .. tostring(cond)
	)
	assert(
		cond:find("nopossessbar", 1, true),
		"fallback must inherit nopossessbar, got: " .. tostring(cond)
	)
end)

test("ComputeEffectiveConditions: the exclusive states keep their own condition", function()
	local states = overrideSlotStates()
	local ovr = Wise:ComputeEffectiveConditions(states, 1)
	assert(ovr:find("overridebar", 1, true), "override state lost its condition: " .. tostring(ovr))
	-- It must not negate ITSELF, only the other exclusive state.
	assert(not ovr:find("nooverridebar", 1, true), "override state negated itself: " .. tostring(ovr))
end)
