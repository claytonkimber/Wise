local addonName, Wise = ...

-- Cursor: a resource ring drawn at the mouse cursor.
--
-- ORIGINAL PURPOSE (2026-08-31): settle whether UnitPower("player") is readable
-- under 12.1 combat secrecy. UltimateMouseCursor gates its power AND health
-- rings behind `if CURRENT_API >= 120000 then return end`
-- (UltimateMouseCursor.lua:1142 and :1208), disabling both outright on 12.x.
-- That gate is blanket-by-version, so it was unknown whether the underlying
-- API is actually withheld.
--
-- RESULT (2026-08-31): it IS withheld. UnitPower("player") returns a SECRET
-- NUMBER even in the open world, out of combat, on your own character.
-- Calibration via `/wise cursor probe` confirmed issecretvalue is a valid
-- discriminator on this client (literal 42, 0, "hello" and nil all report
-- READABLE), so the secret verdict is the API's answer, not a probe fault.
-- UMC's blanket version gate was correct, if bluntly implemented.
--
-- The prior expectation was that this would work, on the reasoning that
-- C_Secrets.ShouldAurasBeSecret() concerns AURA data and 12.0 secrecy targets
-- what you can learn about OTHER units. That reasoning was wrong: self-resource
-- reads are secret too. This is exactly the class of assumption the Abundance
-- investigation (see AGENTS.md) warns about.
--
-- CONSEQUENCE: a cursor resource ring cannot be built on UnitPower on 12.1.
-- Any future attempt needs a different data source — a secure/restricted
-- widget that the client fills in itself (the same shape as the 12.1
-- AuraContainer/AuraButton fix), not an addon-side numeric read.
--
-- Scope: Guardian Druid rage. Guardian is the useful case because Bear Form
-- changes the power type at runtime (UNIT_DISPLAYPOWER), so an implementation
-- that caches powerType at login renders the wrong resource after every shift.
-- That transition is part of what is being tested.
--
-- IMPORTANT: this module reads ONLY "player" resource state. It performs no
-- aura scan. The 12.0.7 taint storm came from scanning shared aura records in
-- combat, which spread Wise taint into data Blizzard's own CooldownViewer then
-- compared against. UnitPower on yourself touches none of that. Do not extend
-- this module to aura reads without revisiting that history.

local Cursor = {}
Wise.Cursor = Cursor

-- ─── Tunables ────────────────────────────────────────────────────────

local RING_SIZE = 64 -- diameter in px
local RING_THICKNESS = 0.14 -- fraction of the radius used by the filled band
local CURSOR_OFFSET_X = 0
local CURSOR_OFFSET_Y = 0
local SEGMENTS = 48 -- wedges around the ring; higher = smoother, costlier

-- Rage red, matching UMC's own table (UltimateMouseCursor.lua:1231) so a
-- side-by-side comparison is not confounded by a colour difference.
local RAGE_COLOR = { r = 1.00, g = 0.00, b = 0.00 }
local BG_COLOR = { r = 0.10, g = 0.10, b = 0.10, a = 0.55 }

-- Enum.PowerType.Rage is 1. Hardcoded rather than read from the enum table so
-- the module still functions if that table is ever reshaped; the value is
-- stable and is the same constant UMC uses.
local POWER_TYPE_RAGE = 1

-- ─── Secrecy probing ─────────────────────────────────────────────────

-- Reuse the hardened approach from core/Compat121.lua and
-- modules/IndicatorRules.lua rather than rolling a second secrecy test.
-- `issecretvalue` is the ONLY reliable check: a tostring→tonumber round-trip
-- does NOT detect a secret (tostring returns a SECRET STRING that explodes on
-- the next comparison). See AGENTS.md "Numeric Taint Stripping".
local hasSecretPrimitives = Wise.Compat and Wise.Compat.hasSecretPrimitives
local _issecretvalue = _G.issecretvalue

-- Is this value unreadable?
--   true  = the client says it is secret
--   false = the client says it is readable
--   nil   = could not determine; caller must fall through to the round-trip
--
-- An ERROR from issecretvalue means "no answer", NOT "secret" — matching
-- CleanSecretNumber in core/GUI.lua, which uses `if svOk and isSecret`.
-- (Calibration later showed this client does NOT throw on ordinary values:
-- it answers cleanly for literals and reports UnitPower results as genuinely
-- secret. The distinction is kept anyway; it costs nothing and a future patch
-- may change the behaviour.)
local function IsSecretValue(v)
	if not _issecretvalue then
		return nil
	end
	local ok, res = pcall(_issecretvalue, v)
	if not ok then
		return nil -- no answer; let the round-trip decide
	end
	return res and true or false
end

-- Plain number from a possibly-secret value; nil when secret/unreadable.
-- Mirrors SecretSafeNumber in modules/IndicatorRules.lua. Note there is no
-- direct nil or type check on `v` before the pcall: even `v == nil` is a
-- comparison a true secret may refuse, so the round-trip inside the pcall
-- handles every case instead.
local _ssnVal
local function SecretSafeNumberProbe()
	return tonumber(tostring(_ssnVal))
end
local function SecretSafeNumber(v)
	if IsSecretValue(v) == true then
		return nil
	end
	_ssnVal = v
	local ok, n = pcall(SecretSafeNumberProbe)
	_ssnVal = nil
	if ok then
		return n
	end
	return nil
end

-- ─── Test telemetry ──────────────────────────────────────────────────

-- What the probe has observed; reported by `/wise cursor`. Deliberately counts
-- rather than logs: this updates on every power tick, and a per-tick print in
-- combat is its own kind of problem.
Cursor.stats = {
	reads = 0, -- UpdateRing calls that attempted a read
	okReads = 0, -- reads that yielded a usable number
	secretReads = 0, -- reads refused as secret
	lastValue = nil, -- last good current value
	lastMax = nil, -- last good max value
	lastSecretAt = nil, -- GetTime() of the most recent secret read
	firstSecretContext = nil, -- instance type where secrecy first appeared
	powerType = nil, -- last observed power type
	powerTypeOK = nil, -- last observed: is the active power type rage?
	-- What issecretvalue() itself said about the raw value, kept separate from
	-- whether the number survived conversion.
	saidSecret = 0, -- client answered "secret"
	saidReadable = 0, -- client answered "readable"
	saidUnknown = 0, -- issecretvalue errored / unavailable
	formID = nil, -- last observed shapeshift form ID (diagnostic only)
	-- StatusBar pass-through experiment (`/wise cursor bar`): can a widget
	-- CONSUME a secret value the addon is not allowed to inspect?
	barMinMaxOK = 0,
	barMinMaxFail = 0,
	barValueOK = 0,
	barValueFail = 0,
	barFirstError = nil, -- first error message from a rejected SetValue
	barHoldsSecret = nil, -- does GetValue() hand the secret back?
}

-- ─── Frame construction ──────────────────────────────────────────────

local ringFrame
local wedges = {}
local barFrame

-- The ring is built from SEGMENTS wedge textures arranged in a circle, each
-- shown or hidden according to the fill fraction. This is the cheap approach:
-- no custom art, no per-frame texture-coordinate maths, and it degrades to a
-- coarse but correct ring at low SEGMENTS. A single rotating texture would
-- look smoother but needs a mask asset that Wise/Media does not ship.
local function BuildRing()
	if ringFrame then
		return ringFrame
	end

	ringFrame = CreateFrame("Frame", "WiseCursorRing", UIParent)
	ringFrame:SetSize(RING_SIZE, RING_SIZE)
	ringFrame:SetFrameStrata("TOOLTIP")
	-- Anchor once at build time. UpdatePosition re-anchors every frame, but it
	-- early-returns while the frame is hidden, so without this the frame would
	-- have no anchor at all the first time UpdateRing calls Show() — an
	-- unanchored frame has undefined position and renders nowhere.
	ringFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	ringFrame:Hide()

	local radius = RING_SIZE / 2
	local midR = radius * (1 - RING_THICKNESS / 2)
	-- Square dots sized off the band width. Deliberately NOT rotated: a
	-- SetColorTexture texture has no meaningful texture coordinates for
	-- SetRotation to act on (every working SetRotation in this addon is on a
	-- FILE texture — see modules/editmode.lua and SlotConfigurator.lua), and
	-- rotating one either no-ops or collapses the quad. That was why the first
	-- version of this ring drew nothing. Unrotated squares at the right radius
	-- read fine as a ring at this size.
	local dotSize = math.max(3, radius * RING_THICKNESS * 2)

	for i = 1, SEGMENTS do
		-- Start at 12 o'clock and grow clockwise: matches how nearly every
		-- resource ring in the wild reads.
		local angle = (i - 0.5) / SEGMENTS * 2 * math.pi
		local x = math.sin(angle) * midR
		local y = math.cos(angle) * midR

		local bg = ringFrame:CreateTexture(nil, "BACKGROUND")
		bg:SetColorTexture(BG_COLOR.r, BG_COLOR.g, BG_COLOR.b, BG_COLOR.a)
		bg:SetSize(dotSize, dotSize)
		bg:SetPoint("CENTER", ringFrame, "CENTER", x, y)

		local tex = ringFrame:CreateTexture(nil, "ARTWORK")
		tex:SetColorTexture(RAGE_COLOR.r, RAGE_COLOR.g, RAGE_COLOR.b, 1)
		tex:SetSize(dotSize, dotSize)
		tex:SetPoint("CENTER", ringFrame, "CENTER", x, y)
		tex:Hide()
		wedges[i] = tex
	end

	return ringFrame
end

-- The follow-up experiment: secrets are designed to be USABLE for display,
-- just not inspectable. A StatusBar owns its fill rendering client-side, so if
-- SetValue accepts a secret number, the client can draw a rage bar the addon
-- itself is never allowed to read. This is the same shape as the 12.1
-- AuraContainer/AuraButton fix: hand the secret to a widget, let the client
-- do the looking.
local function BuildBar()
	if barFrame then
		return barFrame
	end

	barFrame = CreateFrame("StatusBar", "WiseCursorBar", UIParent)
	barFrame:SetSize(RING_SIZE, 10)
	barFrame:SetFrameStrata("TOOLTIP")
	barFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -48)
	-- WHITE8X8 is a stock file texture; SetStatusBarColor tints it. (A file
	-- texture, not SetColorTexture — same lesson as the ring's SetRotation.)
	barFrame:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	barFrame:SetStatusBarColor(RAGE_COLOR.r, RAGE_COLOR.g, RAGE_COLOR.b, 1)

	local bg = barFrame:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(BG_COLOR.r, BG_COLOR.g, BG_COLOR.b, BG_COLOR.a)

	barFrame:SetMinMaxValues(0, 100)
	barFrame:SetValue(0)
	barFrame:Hide()
	return barFrame
end

-- Feed the raw UnitPower results straight into the StatusBar. THE VALUES ARE
-- NEVER INSPECTED on the way through: no comparison, no arithmetic, no
-- tostring — any of those would throw on a secret and would also invalidate
-- the experiment, which is precisely "does pass-through work?". Every widget
-- call is pcall'd and counted instead.
local function FeedBar()
	if not (Cursor.barMode and barFrame) then
		return
	end
	local s = Cursor.stats

	local rawCur = UnitPower("player", POWER_TYPE_RAGE)
	local rawMax = UnitPowerMax("player", POWER_TYPE_RAGE)

	local okMM = pcall(barFrame.SetMinMaxValues, barFrame, 0, rawMax)
	if okMM then
		s.barMinMaxOK = s.barMinMaxOK + 1
	else
		s.barMinMaxFail = s.barMinMaxFail + 1
		-- Keep the bar usable on a fixed range; rage max is 100 for Guardian
		-- in practice, and a slightly wrong range still shows fill movement.
		pcall(barFrame.SetMinMaxValues, barFrame, 0, 100)
	end

	local okV, err = pcall(barFrame.SetValue, barFrame, rawCur)
	if okV then
		s.barValueOK = s.barValueOK + 1
		-- One-time: does the widget hand the secret back out? Informative
		-- either way — "holds secret" means round-trips through widgets are
		-- not a laundering hole (good for Blizzard, expected), while a plain
		-- number here would be surprising and worth knowing.
		if s.barHoldsSecret == nil then
			local okG, held = pcall(barFrame.GetValue, barFrame)
			if okG then
				s.barHoldsSecret = IsSecretValue(held)
			end
		end
	else
		s.barValueFail = s.barValueFail + 1
		if not s.barFirstError then
			local okS, msg = pcall(tostring, err)
			s.barFirstError = okS and msg or "<unprintable>"
		end
	end

	barFrame:Show()
end

-- ─── Reads ───────────────────────────────────────────────────────────

-- Should the rage ring be showing?
--
-- Asks the ACTIVE POWER TYPE rather than the shapeshift form ID. The first
-- version compared GetShapeshiftFormID() against a hardcoded 5, which was a
-- guess: that API returns global form IDs (EnhanceQoL and UMC both compare it
-- against 27/29 for Dragonriding), not the small per-class index, so the
-- comparison never matched and the ring stayed hidden in combat even though
-- rendering worked. Power type is also the thing that actually matters here —
-- if the player is on rage, a rage ring is correct regardless of which form
-- produced it.
--
-- UnitPowerType is recorded even when it does not match, so `/wise cursor`
-- can report what the client really returned.
local function ShouldShowRing()
	local ok, pType = pcall(UnitPowerType, "player")
	if not ok then
		return false
	end
	Cursor.stats.powerType = pType
	local okF, formID = pcall(GetShapeshiftFormID)
	Cursor.stats.formID = okF and formID or nil
	return pType == POWER_TYPE_RAGE
end

-- Read rage as plain numbers, or nil, nil when the client withheld them.
--
-- THIS IS THE TEST. Every read goes through SecretSafeNumber so a secret value
-- collapses to nil instead of propagating into a comparison and throwing.
local function ReadRage()
	local stats = Cursor.stats
	stats.reads = stats.reads + 1

	local rawCur = UnitPower("player", POWER_TYPE_RAGE)
	local rawMax = UnitPowerMax("player", POWER_TYPE_RAGE)

	-- Record what the client said about the raw value, separately from whether
	-- we could turn it into a number. These are different questions, and
	-- conflating them is what made the first run unreadable.
	local verdict = IsSecretValue(rawCur)
	if verdict == true then
		stats.saidSecret = stats.saidSecret + 1
	elseif verdict == false then
		stats.saidReadable = stats.saidReadable + 1
	else
		stats.saidUnknown = stats.saidUnknown + 1
	end

	local cur = SecretSafeNumber(rawCur)
	local max = SecretSafeNumber(rawMax)

	if cur == nil or max == nil then
		stats.secretReads = stats.secretReads + 1
		stats.lastSecretAt = GetTime()
		if not stats.firstSecretContext then
			local okI, _, instanceType = pcall(GetInstanceInfo)
			stats.firstSecretContext = okI and (instanceType or "none") or "unknown"
		end
		return nil, nil
	end

	stats.okReads = stats.okReads + 1
	-- Only record a reading the ring could actually draw. max <= 0 happens
	-- transiently (mid-shift, or a spec with no rage pool) and would otherwise
	-- overwrite the last real value with 0/0, making the report look like a
	-- successful read of nothing.
	if max > 0 then
		stats.lastValue = cur
		stats.lastMax = max
	end
	return cur, max
end

-- ─── Rendering ───────────────────────────────────────────────────────

local function UpdateRing()
	if not ringFrame then
		return
	end

	-- Test mode owns the ring; leave its forced fill alone until it is toggled
	-- off, otherwise the next power event would immediately hide it again.
	if Cursor.testMode then
		return
	end

	if not ShouldShowRing() then
		ringFrame:Hide()
		return
	end

	local cur, max = ReadRage()
	if not cur or not max or max <= 0 then
		-- Secret or unavailable: hide rather than draw a stale or zeroed ring.
		-- A wrong ring is worse than no ring, because an empty one reads as
		-- "no rage" rather than "no data".
		ringFrame:Hide()
		return
	end

	local pct = cur / max
	if pct < 0 then
		pct = 0
	elseif pct > 1 then
		pct = 1
	end

	local filled = math.floor(pct * SEGMENTS + 0.5)
	for i = 1, SEGMENTS do
		if i <= filled then
			wedges[i]:Show()
		else
			wedges[i]:Hide()
		end
	end

	ringFrame:Show()
end

-- Follow the cursor. GetCursorPosition() returns coordinates in the scaled
-- backbuffer space, so divide by the frame's effective scale before placing.
local function PlaceAtCursor(frame, offsetY)
	if not frame or not frame:IsShown() then
		return
	end
	local x, y = GetCursorPosition()
	local scale = frame:GetEffectiveScale()
	if not scale or scale == 0 then
		return
	end
	frame:ClearAllPoints()
	frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale + CURSOR_OFFSET_X, y / scale + CURSOR_OFFSET_Y + offsetY)
end

local function UpdatePosition()
	PlaceAtCursor(ringFrame, 0)
	-- The experiment bar rides just below the cursor so ring and bar can be
	-- compared side by side.
	PlaceAtCursor(barFrame, -44)
end

-- ─── Events ──────────────────────────────────────────────────────────

local driver = CreateFrame("Frame")

-- Position tracking must be per-frame (the cursor emits no event), but the
-- VALUE only changes on power events. Keeping the two apart means the
-- expensive path stays event-driven and the per-frame path only moves a frame.
driver:SetScript("OnUpdate", function()
	UpdatePosition()
end)

driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
driver:RegisterUnitEvent("UNIT_MAXPOWER", "player")
-- The Guardian-specific one: Bear Form swaps the active power type, and
-- without this the ring keeps rendering the pre-shift resource.
driver:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player")
driver:RegisterEvent("UPDATE_SHAPESHIFT_FORM")

driver:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_ENTERING_WORLD" then
		BuildRing()
	end

	local stats = Cursor.stats
	stats.powerTypeOK = ShouldShowRing()

	UpdateRing()
	FeedBar()
	UpdatePosition()
end)

-- NOTE: deliberately NOT calling Compat.SetOnUpdateWhenVisible(driver) here.
-- "RunWhenVisible" gates the OnUpdate on the DRIVER's own visibility, and the
-- driver is an event-only frame that is never Show()n — so on 12.1 the client
-- would correctly stop running it and the ring would never move. The cheap
-- gate that actually applies is the IsShown() early-return in UpdatePosition,
-- which costs one boolean check per frame while the ring is hidden.

-- ─── Report ──────────────────────────────────────────────────────────

-- `/wise cursor test` — force the ring on at a fixed fill, bypassing both the
-- Bear Form check and the power read. Separates "does it draw?" from "is the
-- API readable?", so a blank screen can be diagnosed without shifting form or
-- generating rage. Call again to turn it off.
function Cursor:ToggleTest(pct)
	BuildRing()
	self.testMode = not self.testMode

	if not self.testMode then
		ringFrame:Hide()
		print("|cff00ccff[Wise cursor]|r test ring OFF")
		return
	end

	pct = tonumber(pct) or 0.66
	if pct < 0 then
		pct = 0
	elseif pct > 1 then
		pct = 1
	end

	local filled = math.floor(pct * SEGMENTS + 0.5)
	for i = 1, SEGMENTS do
		if i <= filled then
			wedges[i]:Show()
		else
			wedges[i]:Hide()
		end
	end
	ringFrame:Show()
	UpdatePosition()

	print(
		("|cff00ccff[Wise cursor]|r test ring ON at %d%% (%d/%d dots). Move the mouse."):format(
			pct * 100,
			filled,
			SEGMENTS
		)
	)
end

-- `/wise cursor` — what the probe actually observed.
-- `/wise cursor bar` — toggle the StatusBar pass-through experiment.
--
-- WHAT TO LOOK FOR IN GAME: a thin red bar riding below the cursor. If its
-- fill visibly tracks your rage while `/wise cursor` shows SetValue accepting
-- the values, the display path works and a real resource display can be built
-- on widgets fed secrets. If SetValue is rejected (or the fill never moves),
-- the widget path is blocked too and the feature is closed off entirely.
function Cursor:ToggleBar()
	BuildBar()
	self.barMode = not self.barMode

	if not self.barMode then
		barFrame:Hide()
		print("|cff00ccff[Wise cursor]|r bar experiment OFF")
		return
	end

	FeedBar()
	UpdatePosition()
	print("|cff00ccff[Wise cursor]|r bar experiment ON - generate rage, watch the bar under the cursor,")
	print("|cff00ccff[Wise cursor]|r then run /wise cursor for the pass-through verdict.")
end

-- `/wise cursor probe` — interrogate issecretvalue directly.
--
-- The live run reported secret:66 / readable:0 / no-answer:0 in the OPEN
-- WORLD, where no combat secrecy should apply. Two readings fit that:
--   (a) UnitPower genuinely returns secret values everywhere on 12.1, or
--   (b) issecretvalue returns truthy for things that are not actually secret,
--       making the probe useless as a discriminator.
--
-- This distinguishes them by asking issecretvalue about values whose status we
-- already know. A literal 42 is definitionally not secret; if the client calls
-- it secret, the probe is the problem and every "secret" verdict is worthless.
function Cursor:Probe()
	local P = function(fmt, ...)
		print("|cff00ccff[Wise cursor]|r " .. string.format(fmt, ...))
	end

	P("--- issecretvalue calibration ---")
	if not _issecretvalue then
		P("issecretvalue is not available on this client.")
		return
	end

	-- Known-good controls, then the real reads.
	local cases = {
		{ "literal 42", 42 },
		{ "literal 0", 0 },
		{ "literal string", "hello" },
		{ "nil", nil },
		{ "UnitPower(player)", UnitPower("player") },
		{ "UnitPower(player, 1)", UnitPower("player", POWER_TYPE_RAGE) },
		{ "UnitPowerMax(player, 1)", UnitPowerMax("player", POWER_TYPE_RAGE) },
		{ "UnitHealth(player)", UnitHealth("player") },
		{ "GetTime()", GetTime() },
	}

	for _, case in ipairs(cases) do
		local label, value = case[1], case[2]
		local ok, res = pcall(_issecretvalue, value)
		local verdict
		if not ok then
			verdict = "|cffffcc00ERROR|r (" .. tostring(res):sub(1, 40) .. ")"
		elseif res then
			verdict = "|cffff4444secret|r"
		else
			verdict = "|cff44ff44readable|r"
		end
		-- NEVER touch a value the client just called secret. tostring() on a
		-- secret returns a SECRET STRING, and any operation on that string
		-- (:sub, .., string.format) throws "attempt to index a secret string
		-- value". Only stringify values reported readable; for secrets, print a
		-- fixed literal and never let the value near string machinery.
		local shown
		if ok and res then
			shown = "<secret>"
		else
			local okS, str = pcall(tostring, value)
			if okS then
				local okSub, trimmed = pcall(string.sub, str, 1, 20)
				shown = okSub and trimmed or "<unprintable>"
			else
				shown = "<unprintable>"
			end
		end
		P("  %-24s -> %s   raw=%s", label, verdict, shown)
	end

	P("If 'literal 42' reports secret, issecretvalue is not a usable")
	P("discriminator here and the secret counts above mean nothing.")
end

function Cursor:Report()
	local s = self.stats
	local P = function(fmt, ...)
		print("|cff00ccff[Wise cursor]|r " .. string.format(fmt, ...))
	end

	P("--- UnitPower secrecy probe ---")
	P("issecretvalue available: %s", tostring(hasSecretPrimitives and true or false))
	P(
		"on rage: %s   powerType: %s (rage=%d)   formID: %s",
		tostring(s.powerTypeOK),
		tostring(s.powerType),
		POWER_TYPE_RAGE,
		tostring(s.formID)
	)
	P("reads: %d   usable: %d   unusable: %d", s.reads, s.okReads, s.secretReads)
	P(
		"issecretvalue said -> secret: %d   readable: %d   no-answer: %d",
		s.saidSecret,
		s.saidReadable,
		s.saidUnknown
	)

	if s.lastValue and s.lastMax then
		P("last rage: %s / %s", tostring(s.lastValue), tostring(s.lastMax))
	else
		P("last rage: <none read yet>")
	end

	-- Only a POSITIVE answer from the client counts as evidence of secrecy.
	-- A no-answer means the probe could not tell, which is not the same thing.
	if s.saidSecret > 0 then
		P("|cffff4444CLIENT REPORTED SECRET IN:|r %s (last at %.1f)", tostring(s.firstSecretContext), s.lastSecretAt or 0)
		P("=> UnitPower IS withheld. UMC's version gate was justified.")
		P("   Calibration confirmed issecretvalue is a valid discriminator")
		P("   (literals report readable), so this is the API, not the probe.")
	elseif s.okReads > 0 then
		P("|cff44ff44No secret reads.|r UnitPower('player') is readable.")
		P("=> UMC's CURRENT_API >= 120000 gate is over-broad; the API works.")
	elseif s.reads > 0 then
		P("|cffffcc00Reads happened but none produced a number.|r")
		P("=> Probe fault, not secrecy - check the no-answer count above.")
	else
		P("No reads yet - get on rage and generate some.")
	end

	-- StatusBar pass-through verdict, once the experiment has run at all.
	if (s.barValueOK + s.barValueFail) > 0 then
		P("--- StatusBar pass-through ---")
		P("SetMinMaxValues ok/fail: %d/%d   SetValue ok/fail: %d/%d", s.barMinMaxOK, s.barMinMaxFail, s.barValueOK, s.barValueFail)
		if s.barHoldsSecret ~= nil then
			P("GetValue() hands the secret back: %s", tostring(s.barHoldsSecret))
		end
		if s.barFirstError then
			P("first rejection: %s", s.barFirstError)
		end
		if s.barValueOK > 0 and s.barValueFail == 0 then
			P("|cff44ff44Widget ACCEPTED the secret values.|r")
			P("=> If the bar fill visibly tracks rage, the display path is")
			P("   viable: build the ring on widgets fed secrets, never on reads.")
		elseif s.barValueOK == 0 then
			P("|cffff4444Widget REJECTED the secret values.|r")
			P("=> Display path blocked too; the feature is closed to addons.")
		else
			P("|cffffcc00Mixed accept/reject|r - likely context-dependent; note where each happened.")
		end
	end

	local okI, _, instanceType = pcall(GetInstanceInfo)
	P("current instance type: %s (test in M+/raid to be conclusive)", okI and tostring(instanceType) or "?")
end
