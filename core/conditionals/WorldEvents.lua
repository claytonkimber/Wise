-- core/conditionals/WorldEvents.lua
--
-- State about the wider game world rather than the player: which client flavour
-- is running, which in-game holidays are live, and whether a boss encounter is
-- in progress. Each function answers one question and returns plain values;
-- token parsing belongs to EvalToken.lua.
--
--   [game]       GetGameFlavor     "modern" | "remix" | "forever" | "forever/hc"
--   [holiday]    GetActiveHolidays event-calendar cache, refreshed lazily
--   [encounter]  GetActiveEncounter  ENCOUNTER_START/END bookkeeping
--
-- Two of the three are event-fed caches sharing one small frame (worldEventFrame)
-- with no ticker, per AGENTS.md Rule 12. The flavour resolver reads its inputs
-- (Wise.IS_FOREVER, C_GameRules, PlayerGetTimerunningSeasonID) off their owners
-- at call time rather than hoisting them, so a test can flip any of them.
--
-- Calendar data is only readable out of combat, so a read in lockdown serves the
-- last cache instead of refreshing. The calendar is never moved to another
-- month (C_Calendar.SetMonth would yank the player's open Calendar window): the
-- month offset is computed relative to whatever month is currently set, and a
-- refresh is skipped when that is more than a month away from today.
--
-- Loaded after Environment.lua and before EvalToken.lua.

local addonName, Wise = ...

local type = type
local pcall = pcall
local tostring = tostring
local tonumber = tonumber
local ipairs = ipairs
local GetTime = GetTime
local CreateFrame = CreateFrame

local E = Wise.CondEngine or {}
Wise.CondEngine = E

-- ── [game] ────────────────────────────────────────────────────────────

-- "/"-joined so ArgMatchesAny matches either half: Hardcore is "forever/hc",
-- which satisfies both [game:forever] and [game:hc]. Every API is guarded; a
-- missing one counts as false. No closures: pcall gets the function directly.
local function GetGameFlavor()
	if Wise.IS_FOREVER then
		local rules = _G.C_GameRules
		local isHardcore = rules and rules.IsHardcoreActive
		if type(isHardcore) == "function" then
			local ok, active = pcall(isHardcore)
			if ok and active then
				return "forever/hc"
			end
		end
		return "forever"
	end
	-- Timerunning (Remix) is a seasonal retail mode, not a separate client.
	local seasonFn = _G.PlayerGetTimerunningSeasonID
	if type(seasonFn) == "function" then
		local ok, season = pcall(seasonFn)
		if ok and season and season ~= 0 then
			return "remix"
		end
	end
	return "modern"
end

-- ── [holiday] ─────────────────────────────────────────────────────────

-- Tracked world events: short token, long alias, Holidays.db2 IDs, and the
-- calendar icon fileIDs (start / ongoing / end) used when an entry carries no
-- usable eventID. Anything else on the calendar still matches by title or ID,
-- but does not count for a bare [holiday].
local TRACKED = {
	{ short = "veil", long = "winterveil", ids = { 141 }, icons = { 235485, 235484, 235482 } },
	{ short = "brew", long = "brewfest", ids = { 372 }, icons = { 235442, 235441, 235440 } },
	{ short = "hend", long = "hallowsend", ids = { 324, 1405 }, icons = { 235462, 235461, 235460 } },
	{ short = "fire", long = "midsummer", ids = { 341 }, icons = { 235474, 235473, 235472 } },
	{ short = "east", long = "noblegarden", ids = { 181 }, icons = { 235477, 235476, 235475 } },
	{ short = "luna", long = "lunarfestival", ids = { 327 }, icons = { 235471, 235470, 235469 } },
	{ short = "love", long = "loveair", ids = { 335, 423 }, icons = { 235468, 235467, 235466 } },
}
local TRACKED_BY_ID, TRACKED_BY_ICON = {}, {}
for _, entry in ipairs(TRACKED) do
	for _, id in ipairs(entry.ids) do
		TRACKED_BY_ID[id] = entry
	end
	for _, icon in ipairs(entry.icons) do
		TRACKED_BY_ICON[icon] = entry
	end
end

local HOLIDAY_MAX_AGE = 300 -- seconds before a clean cache is re-read anyway

local EMPTY = {}
local holidayValue = "" -- "/"-joined ids, titles and tracked tokens, for ArgMatchesAny
local holidayTracked = EMPTY -- array of active tracked short tokens
local holidayDirty = true
local holidayStamp = 0
local calendarOpened = false

-- CalendarTime -> one sortable number (YYYYMMDDhhmm). Compared with plain < and
-- <=, so there is no sign convention to get backwards.
local function TimeKey(t)
	if type(t) ~= "table" or not t.year then
		return nil
	end
	return (((t.year * 100 + (t.month or 0)) * 100 + (t.monthDay or 0)) * 100 + (t.hour or 0)) * 100
		+ (t.minute or 0)
end

-- Is this calendar entry running right now? A missing bound counts as open on
-- that side, so an entry with no times is active for the day it is listed on.
local function IsRunningNow(event, nowKey)
	local startKey, endKey = TimeKey(event.startTime), TimeKey(event.endTime)
	if startKey and startKey > nowKey then
		return false
	end
	if endKey and endKey <= nowKey then
		return false
	end
	return true
end

-- Re-read today's holiday entries. Returns nothing and leaves the cache alone
-- when the calendar is unavailable or its set month is too far away to address
-- with GetDayEvent's offset; errors propagate to the pcall in GetActiveHolidays.
local function RefreshHolidays()
	local cal, dt = _G.C_Calendar, _G.C_DateAndTime
	if not (cal and dt and cal.GetMonthInfo and cal.GetNumDayEvents and cal.GetDayEvent) then
		return
	end
	local now = dt.GetCurrentCalendarTime and dt.GetCurrentCalendarTime()
	local set = cal.GetMonthInfo(0)
	if not (now and set and now.year and set.year) then
		return
	end
	local offset = (now.year - set.year) * 12 + (now.month - set.month)
	if offset > 1 or offset < -1 then
		return
	end
	local nowKey = TimeKey(now)
	local day = now.monthDay

	local seen, parts, tracked = {}, {}, {}
	local function add(piece)
		if piece ~= nil and piece ~= "" and not seen[piece] then
			seen[piece] = true
			parts[#parts + 1] = piece
		end
	end
	for i = 1, cal.GetNumDayEvents(offset, day) or 0 do
		local event = cal.GetDayEvent(offset, day, i)
		if event and event.calendarType == "HOLIDAY" and IsRunningNow(event, nowKey) then
			local eventID = tonumber(event.eventID)
			if eventID then
				add(tostring(eventID))
			end
			if type(event.title) == "string" then
				add(event.title:lower())
			end
			local entry = (eventID and TRACKED_BY_ID[eventID]) or TRACKED_BY_ICON[event.iconTexture]
			if entry then
				add(entry.short)
				add(entry.long)
				if not tracked[entry.short] then
					tracked[entry.short] = true
					tracked[#tracked + 1] = entry.short
				end
			end
		end
	end
	holidayValue = table.concat(parts, "/")
	holidayTracked = #tracked > 0 and tracked or EMPTY
end

-- Cache read. Returns the match string and the array of active tracked tokens.
-- Refreshes only when marked dirty or stale, and never in lockdown.
local function GetActiveHolidays()
	local now = GetTime()
	if (holidayDirty or now - holidayStamp > HOLIDAY_MAX_AGE) and not _G.InCombatLockdown() then
		holidayDirty = false
		holidayStamp = now
		if not pcall(RefreshHolidays) then
			holidayValue, holidayTracked = "", EMPTY
		end
	end
	return holidayValue, holidayTracked
end

local function InvalidateHolidays()
	holidayDirty = true
end

-- ── [encounter] ───────────────────────────────────────────────────────

local encounterActive = false
local encounterID, encounterName, encounterValue = nil, nil, nil

local function ClearEncounter()
	encounterActive = false
	encounterID, encounterName, encounterValue = nil, nil, nil
end

local function StartEncounter(id, name)
	encounterActive = true
	encounterID = tonumber(id)
	encounterName = type(name) == "string" and name:lower() or nil
	-- "<id>/e-<id>/<name>": an encounter matches by bare ID, "e-" + ID, or name.
	if encounterID then
		encounterValue = encounterID .. "/e-" .. encounterID .. (encounterName and ("/" .. encounterName) or "")
	else
		encounterValue = encounterName
	end
end

-- Returns id, nameLower, active, matchValue. `active` is the real answer: after
-- a /reload mid-fight the encounter is known to be running but not which one,
-- so id is nil while active is true. With nothing running: nil, nil, false, nil.
local function GetActiveEncounter()
	return encounterID, encounterName, encounterActive, encounterValue
end

-- ── Shared event frame ────────────────────────────────────────────────

local function OnWorldEvent(_, event, arg1, arg2)
	if event == "ENCOUNTER_START" then
		StartEncounter(arg1, arg2)
	elseif event == "ENCOUNTER_END" then
		ClearEncounter()
	elseif event == "PLAYER_ENTERING_WORLD" then
		holidayDirty = true
		if not calendarOpened then
			-- Asks the client to load this month's entries; fires
			-- CALENDAR_UPDATE_EVENT_LIST when they arrive.
			calendarOpened = true
			local cal = _G.C_Calendar
			if cal and cal.OpenCalendar then
				pcall(cal.OpenCalendar)
			end
		end
		-- arg2 is isReloadingUi. A zone change or login cannot be mid-fight from
		-- Wise's point of view; a reload can, and no ENCOUNTER_START will refire.
		if not arg2 then
			ClearEncounter()
		elseif not encounterActive then
			local inProgress = _G.IsEncounterInProgress
			if type(inProgress) == "function" and inProgress() then
				encounterActive = true
			end
		end
	elseif event == "CALENDAR_UPDATE_EVENT_LIST" then
		holidayDirty = true
	elseif event == "PLAYER_REGEN_ENABLED" then
		local inProgress = _G.IsEncounterInProgress
		if encounterActive and type(inProgress) == "function" and not inProgress() then
			ClearEncounter()
		end
	end
end

-- One small event frame, no ticker. Registration is pcall'd per event so a
-- client that lacks one of these names cannot take the rest down.
local worldEventFrame = CreateFrame("Frame")
worldEventFrame:SetScript("OnEvent", OnWorldEvent)
for _, event in ipairs({
	"PLAYER_ENTERING_WORLD",
	"CALENDAR_UPDATE_EVENT_LIST",
	"ENCOUNTER_START",
	"ENCOUNTER_END",
	"PLAYER_REGEN_ENABLED",
}) do
	pcall(worldEventFrame.RegisterEvent, worldEventFrame, event)
end

-- Published to the engine's internals for EvalToken.lua.
E.GetGameFlavor = GetGameFlavor
E.GetActiveHolidays = GetActiveHolidays
E.InvalidateHolidays = InvalidateHolidays
E.GetActiveEncounter = GetActiveEncounter
E.worldEventFrame = worldEventFrame
