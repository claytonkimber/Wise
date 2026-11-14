-- tests/world_event_conditionals.lua
-- [game] flavours, [holiday], [encounter]/[encount], [ownbuff]/[owndebuff].
-- Asserts the three tables agree for every new token, then each token's logic.
-- Every API is stubbed as a FIELD on its existing namespace (or on _G for bare
-- globals) and restored afterwards, even when the body fails; a namespace is
-- created only if the sim lacks it, and removed again.

local E = Wise.CondEngine

-- Install stubs, run fn, always restore. Each stub is { namespace, key, value }
-- where namespace is a table, "_G" for bare globals, or a global namespace name.
local function withStubs(stubs, fn)
	local saved, created = {}, {}
	for _, stub in ipairs(stubs) do
		local ns = stub[1]
		if type(ns) == "string" then
			local name = ns
			ns = _G[name]
			if ns == nil then
				_G[name] = {}
				ns = _G[name]
				created[#created + 1] = name
			end
		end
		saved[#saved + 1] = { ns, stub[2], ns[stub[2]] }
		ns[stub[2]] = stub[3]
	end
	local ok, err = pcall(fn)
	for i = #saved, 1, -1 do
		saved[i][1][saved[i][2]] = saved[i][3]
	end
	for _, name in ipairs(created) do
		_G[name] = nil
	end
	E.InvalidateHolidays()
	if not ok then
		error(err, 0)
	end
end

local function eval(token)
	return E.EvalCustomToken(token)
end

local function ct(year, month, day, hour, minute)
	return { year = year, month = month, monthDay = day, hour = hour or 0, minute = minute or 0 }
end

-- ── Table agreement ───────────────────────────────────────────────────

local NEW_TOKENS = { "holiday", "encounter", "encount", "ownbuff", "owndebuff" }
local SAMPLEABLE = { ownbuff = true, owndebuff = true }

test("WorldConditionals:new tokens are in all three tables and validate", function()
	for _, token in ipairs(NEW_TOKENS) do
		assertEquals(true, E.CUSTOM_VIS_CONDITIONALS[token], "CUSTOM_VIS_CONDITIONALS " .. token)
		for _, str in ipairs({ "[" .. token .. "]", "[no" .. token .. "]", "[" .. token .. ":x/y]" }) do
			local ok, err = Wise:ValidateVisibilityCondition(str)
			assertEquals(true, ok, str .. " should validate: " .. tostring(err))
		end
		if SAMPLEABLE[token] then
			assertEquals(true, E.COMBAT_SAMPLED[token], "COMBAT_SAMPLED " .. token)
		else
			assertEquals(nil, E.COMBAT_SAMPLED[token], "not combat-sampled: " .. token)
		end
	end
	local listed = {}
	local encounterDesc
	for _, item in ipairs(Wise.extendedConditionals) do
		local base = item.name and item.name:match("^([^:]+)")
		if base then
			listed[base] = true
			if base == "encounter" then
				encounterDesc = item.desc
			end
		end
	end
	for _, token in ipairs({ "holiday", "encounter", "ownbuff", "owndebuff", "game" }) do
		assertEquals(true, listed[token], "display list entry " .. token)
	end
	-- The alias is documented on the encounter row rather than listed separately.
	assertEquals(true, encounterDesc:find("encount", 1, true) ~= nil, "alias mentioned in display desc")
end)

test("WorldConditionals:[x] and [nox] disagree for every new token", function()
	for _, token in ipairs(NEW_TOKENS) do
		for _, arg in ipairs({ "", ":Thing" }) do
			assertEquals(true, eval(token .. arg) ~= eval("no" .. token .. arg), token .. arg)
		end
	end
end)

-- ── [game] ────────────────────────────────────────────────────────────

test("WorldConditionalsgame: modern, remix, forever and forever+hc", function()
	local state = { hardcore = false, season = nil }
	withStubs({
		{ Wise, "IS_FOREVER", false },
		{ "C_GameRules", "IsHardcoreActive", function() return state.hardcore end },
		{ "_G", "PlayerGetTimerunningSeasonID", function() return state.season end },
	}, function()
		-- Retail, no Timerunning.
		assertEquals("modern", E.GetGameFlavor())
		assertEquals(true, eval("game:modern"))
		assertEquals(false, eval("game:remix"))
		assertEquals(false, eval("game:forever"))
		assertEquals(true, eval("game"), "bare [game] is always true")
		assertEquals(false, eval("nogame:modern"))
		assertEquals(true, eval("nogame:forever"))
		state.season = 0
		assertEquals("modern", E.GetGameFlavor(), "season 0 is not Timerunning")

		-- Retail Timerunning.
		state.season = 2
		assertEquals("remix", E.GetGameFlavor())
		assertEquals(true, eval("game:remix"))
		assertEquals(false, eval("game:modern"))
		assertEquals(true, eval("game:modern/remix"), "alternatives")

		-- Forever. Hardcore only counts there, and Timerunning does not.
		Wise.IS_FOREVER = true
		state.hardcore = false
		assertEquals("forever", E.GetGameFlavor())
		assertEquals(true, eval("game:forever"))
		assertEquals(false, eval("game:modern"), "[game:modern] is false on Forever")
		assertEquals(false, eval("game:remix"))
		assertEquals(false, eval("game:hc"))
		assertEquals(true, eval("nogame:modern"))
		state.hardcore = true
		assertEquals("forever/hc", E.GetGameFlavor())
		assertEquals(true, eval("game:forever"))
		assertEquals(true, eval("game:hc"))
		assertEquals(false, eval("game:modern"))

		-- Retail ignores a hardcore flag.
		Wise.IS_FOREVER = false
		state.season = nil
		assertEquals(false, eval("game:hc"))
	end)
end)

test("WorldConditionalsgame: absent or throwing APIs count as false", function()
	withStubs({
		{ Wise, "IS_FOREVER", true },
		{ "C_GameRules", "IsHardcoreActive", nil },
		{ "_G", "PlayerGetTimerunningSeasonID", function() error("boom") end },
	}, function()
		assertEquals("forever", E.GetGameFlavor())
		Wise.IS_FOREVER = false
		local ok, flavor = pcall(E.GetGameFlavor)
		assertEquals(true, ok, "throwing season API contained")
		assertEquals("modern", flavor)
		_G.PlayerGetTimerunningSeasonID = nil
		assertEquals("modern", E.GetGameFlavor())
	end)
end)

test("WorldConditionalsgame: options value shows flavor and build", function()
	withStubs({
		{ Wise, "IS_FOREVER", true },
		{ "C_GameRules", "IsHardcoreActive", function() return true end },
	}, function()
		local value = Wise:GetConditionalValue("game:version")
		assertEquals(true, value:find("^forever/hc %(") ~= nil, "got " .. tostring(value))
	end)
end)

-- ── [holiday] ─────────────────────────────────────────────────────────

-- `state.events` is what the calendar reports for today. `calls` records the
-- (offset, day) GetNumDayEvents was asked for.
local function newCalendar()
	return {
		now = ct(2026, 11, 14, 12, 0),
		set = { year = 2026, month = 11 },
		events = {},
		calls = {},
		opened = 0,
	}
end

local function withCalendar(state, fn)
	withStubs({
		{ "C_DateAndTime", "GetCurrentCalendarTime", function() return state.now end },
		{ "C_Calendar", "GetMonthInfo", function() return state.set end },
		{ "C_Calendar", "GetNumDayEvents", function(offset, day)
			state.calls[#state.calls + 1] = { offset, day }
			return #state.events
		end },
		{ "C_Calendar", "GetDayEvent", function(_, _, i) return state.events[i] end },
		{ "C_Calendar", "OpenCalendar", function() state.opened = state.opened + 1 end },
	}, function()
		E.InvalidateHolidays()
		fn()
	end)
end

local function holiday(fields)
	fields.calendarType = fields.calendarType or "HOLIDAY"
	return fields
end

test("WorldConditionalsholiday: tracked event active by eventID", function()
	local state = newCalendar()
	state.events = {
		holiday({
			eventID = 372,
			title = "Brewfest",
			startTime = ct(2026, 11, 10, 0, 1),
			endTime = ct(2026, 11, 20, 0, 1),
		}),
	}
	withCalendar(state, function()
		assertEquals(true, eval("holiday"), "bare [holiday]")
		assertEquals(false, eval("noholiday"))
		assertEquals(true, eval("holiday:brew"))
		assertEquals(true, eval("holiday:brewfest"))
		assertEquals(true, eval("holiday:BREWFEST"), "case-insensitive")
		assertEquals(true, eval("holiday:372"))
		assertEquals(true, eval("holiday:veil/brew"), "alternatives")
		assertEquals(false, eval("holiday:veil"))
		assertEquals(false, eval("holiday:love"))
		assertEquals(true, eval("noholiday:veil"))
		assertEquals("brew", Wise:GetConditionalValue("holiday"))
		-- Asked about today in the current month (set month = now).
		assertEquals(0, state.calls[1][1], "month offset")
		assertEquals(14, state.calls[1][2], "day")
	end)
end)

test("WorldConditionalsholiday: tracked event active by calendar icon alone", function()
	local state = newCalendar()
	state.events = { holiday({ title = "Some Unlocalised Name", iconTexture = 235441 }) }
	withCalendar(state, function()
		assertEquals(true, eval("holiday"))
		assertEquals(true, eval("holiday:brew"))
		assertEquals(true, eval("holiday:brewfest"))
		assertEquals(false, eval("holiday:372"), "no eventID, so the ID form is absent")
		assertEquals(false, eval("holiday:luna"))
	end)
end)

test("WorldConditionalsholiday: start and end window, end exclusive", function()
	local state = newCalendar()
	withCalendar(state, function()
		local function check(startTime, endTime, expected, label)
			state.events = { holiday({ eventID = 141, title = "Feast of Winter Veil", startTime = startTime, endTime = endTime }) }
			E.InvalidateHolidays()
			assertEquals(expected, eval("holiday:veil"), label)
			assertEquals(expected, eval("holiday"), label .. " (bare)")
		end
		check(ct(2026, 11, 14, 18, 0), ct(2026, 11, 20, 0, 0), false, "starts later today")
		check(ct(2026, 11, 14, 12, 1), ct(2026, 11, 20, 0, 0), false, "starts a minute from now")
		check(ct(2026, 11, 14, 12, 0), ct(2026, 11, 20, 0, 0), true, "starts exactly now")
		check(ct(2026, 11, 1, 0, 0), ct(2026, 11, 14, 8, 0), false, "ended this morning")
		check(ct(2026, 11, 1, 0, 0), ct(2026, 11, 14, 12, 0), false, "ends exactly now")
		check(ct(2026, 11, 1, 0, 0), ct(2026, 11, 14, 12, 1), true, "ends a minute from now")
		check(ct(2026, 10, 30, 0, 0), ct(2027, 1, 2, 0, 0), true, "spans a year boundary")
		check(ct(2025, 12, 30, 0, 0), ct(2026, 1, 2, 0, 0), false, "ended last year")
		check(nil, nil, true, "no times at all")
		check(nil, ct(2026, 11, 14, 8, 0), false, "no start, already ended")
		check(ct(2026, 11, 14, 18, 0), nil, false, "no end, not started")
	end)
end)

test("WorldConditionalsholiday: untracked holidays match by title and ID, not bare", function()
	local state = newCalendar()
	state.events = {
		holiday({ eventID = 9999, title = "Darkmoon Faire" }),
		-- A non-holiday entry must be ignored even with a tracked ID.
		{ calendarType = "PLAYER", eventID = 372, title = "Guild Brew Night" },
	}
	withCalendar(state, function()
		assertEquals(false, eval("holiday"), "bare [holiday] needs a tracked event")
		assertEquals(true, eval("noholiday"))
		assertEquals(true, eval("holiday:darkmoon faire"))
		assertEquals(true, eval("holiday:Darkmoon Faire"))
		assertEquals(true, eval("holiday:9999"))
		assertEquals(false, eval("holiday:brew"), "PLAYER events are not holidays")
		assertEquals(false, eval("holiday:guild brew night"))
		assertEquals("None", Wise:GetConditionalValue("holiday"))
	end)
end)

test("WorldConditionalsholiday: several active events, tracked token list", function()
	local state = newCalendar()
	state.events = {
		holiday({ eventID = 324, title = "Hallow's End" }),
		holiday({ eventID = 1405, title = "Hallow's End" }),
		holiday({ eventID = 335, title = "Love is in the Air" }),
	}
	withCalendar(state, function()
		assertEquals(true, eval("holiday:hend"))
		assertEquals(true, eval("holiday:1405"))
		assertEquals(true, eval("holiday:love/east"))
		assertEquals(false, eval("holiday:east"))
		assertEquals("hend, love", Wise:GetConditionalValue("holiday"))
	end)
end)

test("WorldConditionalsholiday: offset beyond one month keeps the old cache", function()
	local state = newCalendar()
	state.events = { holiday({ eventID = 372, title = "Brewfest" }) }
	withCalendar(state, function()
		assertEquals(true, eval("holiday:brew"))

		state.events = {}
		state.set = { year = 2026, month = 8 } -- offset 3
		E.InvalidateHolidays()
		assertEquals(true, eval("holiday:brew"), "stale cache kept at offset 3")
		state.set = { year = 2025, month = 11 } -- offset 12
		E.InvalidateHolidays()
		assertEquals(true, eval("holiday:brew"), "stale cache kept at offset 12")
		state.set = { year = 2026, month = 12 } -- offset -1
		E.InvalidateHolidays()
		assertEquals(false, eval("holiday:brew"), "offset -1 refreshes")

		state.events = { holiday({ eventID = 372, title = "Brewfest" }) }
		state.set = { year = 2026, month = 10 } -- offset +1
		state.calls = {}
		E.InvalidateHolidays()
		assertEquals(true, eval("holiday:brew"), "offset +1 refreshes")
		assertEquals(1, state.calls[1][1], "offset passed to the calendar")

		-- Year rollover: December's calendar set while it is January.
		state.now = ct(2027, 1, 2, 12, 0)
		state.set = { year = 2026, month = 12 }
		state.calls = {}
		E.InvalidateHolidays()
		eval("holiday")
		assertEquals(1, state.calls[1][1], "Dec -> Jan is offset 1")
	end)
end)

test("WorldConditionalsholiday: cache is served until invalidated; not refreshed in combat", function()
	local state = newCalendar()
	state.events = { holiday({ eventID = 372, title = "Brewfest" }) }
	local inCombat = false
	withStubs({ { "_G", "InCombatLockdown", function() return inCombat end } }, function()
		withCalendar(state, function()
			assertEquals(true, eval("holiday:brew"))
			state.events = {}
			assertEquals(true, eval("holiday:brew"), "clean cache is not re-read")

			local handler = E.worldEventFrame:GetScript("OnEvent")
			assertNotNil(handler, "event frame has an OnEvent handler")
			inCombat = true
			handler(E.worldEventFrame, "CALENDAR_UPDATE_EVENT_LIST")
			assertEquals(true, eval("holiday:brew"), "no refresh while in combat")
			inCombat = false
			assertEquals(false, eval("holiday:brew"), "refreshed once combat ends")

			-- PLAYER_ENTERING_WORLD marks it dirty too.
			state.events = { holiday({ eventID = 181, title = "Noblegarden" }) }
			handler(E.worldEventFrame, "PLAYER_ENTERING_WORLD", false, false)
			assertEquals(true, eval("holiday:east"))
		end)
	end)
end)

test("WorldConditionalsholiday: calendar opened at most once, errors mean no holidays", function()
	local state = newCalendar()
	state.events = { holiday({ eventID = 372, title = "Brewfest" }) }
	withCalendar(state, function()
		local handler = E.worldEventFrame:GetScript("OnEvent")
		handler(E.worldEventFrame, "PLAYER_ENTERING_WORLD", false, false)
		local afterFirst = state.opened
		assertEquals(true, afterFirst <= 1, "first world entry opens the calendar once at most")
		handler(E.worldEventFrame, "PLAYER_ENTERING_WORLD", false, false)
		assertEquals(afterFirst, state.opened, "never opened a second time")

		assertEquals(true, eval("holiday:brew"))
		C_Calendar.GetNumDayEvents = function() error("boom") end
		E.InvalidateHolidays()
		local ok, value = pcall(eval, "holiday:brew")
		assertEquals(true, ok, "throwing calendar contained")
		assertEquals(false, value, "error leaves no holidays")
		assertEquals(false, eval("holiday"))
	end)
end)

-- ── [encounter] ───────────────────────────────────────────────────────

local function withEncounterEnv(inProgress, fn)
	local handler = E.worldEventFrame:GetScript("OnEvent")
	assertNotNil(handler, "event frame has an OnEvent handler")
	local frame = E.worldEventFrame
	local function fire(...)
		handler(frame, ...)
	end
	fire("ENCOUNTER_END")
	withStubs({ { "_G", "IsEncounterInProgress", function() return inProgress.value end } }, function()
		local ok, err = pcall(fn, fire)
		fire("ENCOUNTER_END")
		if not ok then
			error(err, 0)
		end
	end)
end

test("WorldConditionalsencounter: START, match forms, END", function()
	withEncounterEnv({ value = false }, function(fire)
		assertEquals(false, eval("encounter"))
		assertEquals(true, eval("noencounter"))

		fire("ENCOUNTER_START", 2837, "Ulgrax the Devourer", 16, 20)
		for _, token in ipairs({
			"encounter",
			"encount",
			"encounter:2837",
			"encount:2837",
			"encounter:e-2837",
			"encounter:Ulgrax the Devourer",
			"encounter:ULGRAX THE DEVOURER",
			"encounter:1/2837",
			"encounter:e-1/e-2837",
		}) do
			assertEquals(true, eval(token), token)
			assertEquals(false, eval("no" .. token), "no" .. token)
		end
		assertEquals(false, eval("encounter:1234"))
		assertEquals(false, eval("encounter:e-1234"))
		assertEquals(false, eval("encounter:Rasha'nan"))
		local id, name, active = E.GetActiveEncounter()
		assertEquals(2837, id)
		assertEquals("ulgrax the devourer", name)
		assertEquals(true, active)
		assertEquals("ulgrax the devourer (2837)", Wise:GetConditionalValue("encounter"))

		fire("ENCOUNTER_END", 2837, "Ulgrax the Devourer", 16, 20, 1)
		assertEquals(false, eval("encounter"))
		assertEquals(false, eval("encounter:2837"))
		assertEquals(false, eval("encounter:e-2837"))
		assertEquals(false, eval("encounter:Ulgrax the Devourer"))
		assertEquals(true, eval("noencounter"))
		assertEquals(nil, (E.GetActiveEncounter()))
		assertEquals("None", Wise:GetConditionalValue("encounter"))
	end)
end)

test("WorldConditionalsencounter: zoning clears it, a new START replaces it", function()
	withEncounterEnv({ value = false }, function(fire)
		fire("ENCOUNTER_START", 2837, "Ulgrax the Devourer")
		fire("ENCOUNTER_START", 2900, "Queen Ansurek")
		assertEquals(false, eval("encounter:2837"))
		assertEquals(true, eval("encounter:2900"))
		fire("PLAYER_ENTERING_WORLD", false, false)
		assertEquals(false, eval("encounter"), "not a reload: cleared")
	end)
end)

test("WorldConditionalsencounter: /reload mid-fight is bare-only until it ends", function()
	local inProgress = { value = true }
	withEncounterEnv(inProgress, function(fire)
		fire("PLAYER_ENTERING_WORLD", false, true)
		assertEquals(true, eval("encounter"), "bare [encounter] true after reload")
		assertEquals(true, eval("encount"))
		assertEquals(false, eval("encounter:2837"), "id unknown: specific args false")
		assertEquals(false, eval("encounter:ulgrax the devourer"))
		assertEquals(true, eval("noencounter:2837"))
		local id, name, active = E.GetActiveEncounter()
		assertEquals(nil, id)
		assertEquals(nil, name)
		assertEquals(true, active)
		assertEquals("In progress", Wise:GetConditionalValue("encounter"))

		-- Combat ends while the client still says a fight is on: keep the state.
		fire("PLAYER_REGEN_ENABLED")
		assertEquals(true, eval("encounter"), "still in progress")
		-- Client reports it over: clear.
		inProgress.value = false
		fire("PLAYER_REGEN_ENABLED")
		assertEquals(false, eval("encounter"))
	end)
end)

test("WorldConditionalsencounter: reload with nothing in progress, and API absent", function()
	local inProgress = { value = false }
	withEncounterEnv(inProgress, function(fire)
		fire("PLAYER_ENTERING_WORLD", false, true)
		assertEquals(false, eval("encounter"), "reload outside a fight")

		-- A known encounter survives REGEN_ENABLED only while the client agrees.
		fire("ENCOUNTER_START", 2837, "Ulgrax the Devourer")
		fire("PLAYER_REGEN_ENABLED")
		assertEquals(false, eval("encounter"), "IsEncounterInProgress false clears it")

		_G.IsEncounterInProgress = nil
		fire("ENCOUNTER_START", 2837, "Ulgrax the Devourer")
		fire("PLAYER_REGEN_ENABLED")
		assertEquals(true, eval("encounter"), "no API: state left alone")
		local ok = pcall(fire, "PLAYER_ENTERING_WORLD", false, true)
		assertEquals(true, ok, "reload without the API does not error")
		assertEquals(true, eval("encounter:2837"), "known encounter kept across a reload")
	end)
end)

-- ── [ownbuff] / [owndebuff] ───────────────────────────────────────────

test("WorldConditionalsownbuff: queries the target with a PLAYER filter", function()
	local seen = {}
	local auras = { helpful = "Rejuvenation", harmful = "Rip" }
	withStubs({
		{ "_G", "UnitExists", function(unit) return unit == "target" end },
		{
			"C_UnitAuras",
			"GetAuraDataByIndex",
			function(unit, index, filter)
				seen[#seen + 1] = { unit = unit, filter = filter }
				if index ~= 1 then
					return nil
				end
				if filter:find("HELPFUL", 1, true) then
					return { name = auras.helpful }
				end
				return { name = auras.harmful }
			end,
		},
	}, function()
		assertEquals(true, eval("ownbuff:Rejuvenation"))
		assertEquals(true, eval("ownbuff:rejuvenation/Lifebloom"), "alternatives, any case")
		assertEquals(false, eval("ownbuff:Rip"))
		assertEquals(false, eval("noownbuff:Rejuvenation"))
		assertEquals(true, eval("owndebuff:Rip"))
		assertEquals(false, eval("owndebuff:Rejuvenation"))
		assertEquals(true, eval("noowndebuff:Rejuvenation"))
		assertEquals(false, eval("ownbuff"), "an argument is required, as for [buff]")

		assertEquals(true, #seen > 0, "aura API was queried")
		for _, call in ipairs(seen) do
			assertEquals("target", call.unit)
			assertEquals(true, call.filter:find("PLAYER", 1, true) ~= nil, "filter " .. call.filter)
		end
		assertEquals("HELPFUL|PLAYER", seen[1].filter)
		local sawHarmful = false
		for _, call in ipairs(seen) do
			if call.filter == "HARMFUL|PLAYER" then
				sawHarmful = true
			end
		end
		assertEquals(true, sawHarmful, "owndebuff uses HARMFUL|PLAYER")
	end)
end)

test("WorldConditionalsownbuff: no target means false", function()
	withStubs({
		{ "_G", "UnitExists", function() return false end },
		{ "C_UnitAuras", "GetAuraDataByIndex", function() return { name = "Rip" } end },
	}, function()
		assertEquals(false, eval("owndebuff:Rip"))
		assertEquals(true, eval("noowndebuff:Rip"))
	end)
end)
