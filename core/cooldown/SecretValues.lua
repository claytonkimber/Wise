-- core/cooldown/SecretValues.lua
--
-- Client-capability probes, countdown-text formatting, and the secret-value-safe
-- read primitives -- extracted from the top of core/GUI.lua.
--
-- These belong together because they all exist to serve one problem: from WoW
-- 11.1+/12.0+ a cooldown's start/duration can be a "secret number" that THROWS
-- on any arithmetic, comparison, or even tostring(). Everything here is either
-- a probe for what the current client can do about that, or a primitive that
-- reads such a value without letting it escape.
--
-- Two conventions in this file are load-bearing, both for the same reason --
-- these run on the per-button cooldown/charge paths, thousands of times per
-- second in combat, where closure churn dominated the addon's GC profile:
--
--   * rawIndex and checkSecret are hoisted to file scope and handed to pcall by
--     REFERENCE, with arguments forwarded (pcall(f, a, b)). Wrapping them in an
--     inline closure allocates on every call; this allocates nothing.
--   * SafeReadField takes a TABLE AND KEY, not an already-read value, because
--     reading `tbl.key` is itself what throws on a secret field. Pair it with
--     CleanSecretNumber: CleanSecretNumber(SafeReadField(t, k)).
--
-- CleanSecretNumber returns nil for a secret value -- nil means "unknown", not
-- "zero". Callers must not coerce it to 0; see wiser/Cursor.lua for the same
-- `if svOk and isSecret` shape.
--
-- Loaded before core/GUI.lua, which binds these as upvalues.

local addonName, Wise = ...

local _G = _G
local strformat = string.format
local ceil = math.ceil
local tonumber = tonumber
local tostring = tostring
local pcall = pcall
local CreateFrame = CreateFrame
local UIParent = UIParent
local C_StringUtil = C_StringUtil
local GetBuildInfo = GetBuildInfo
local select = select
local type = type

-- Capability flags for patch-12.0.5+ cooldown APIs. The `ignoreGCD` second arg on
-- GetSpellCooldownDuration / GetActionCooldownDuration arrived in interface 120005;
-- we can't introspect arity, so gate on the interface number (extra arg is ignored
-- as a no-op on clients that don't support it, but gating keeps intent explicit).
local INTERFACE_VERSION = select(4, GetBuildInfo()) or 0
local HAS_IGNORE_GCD = INTERFACE_VERSION >= 120005
Wise.HAS_IGNORE_GCD = HAS_IGNORE_GCD

-- 12.0.5 native countdown formatters: Cooldown:SetCountdownFormatter lets us style
-- the built-in (combat / secret-mode) countdown text to match Wise's own out-of-
-- combat format, instead of being stuck with Blizzard's default whole-second look.
-- Probe by method presence (more robust than a version number for widget methods).
local HAS_COUNTDOWN_FORMATTER = false
-- 12.0.5 Cooldown:SetCountdownMillisecondsThreshold(seconds): below the given
-- remaining time, Blizzard's native countdown text shows one decimal place.
-- We use it on the combat / secret-mode path so the built-in text ticks as
-- smoothly as our out-of-combat decimal format. Method is protected; probe by
-- presence and always pcall the call site.
local HAS_COUNTDOWN_MS_THRESHOLD = false
do
	local probe = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
	HAS_COUNTDOWN_FORMATTER = type(probe.SetCountdownFormatter) == "function"
		and type(C_StringUtil) == "table"
		and type(C_StringUtil.CreateSecondsFormatter) == "function"
	HAS_COUNTDOWN_MS_THRESHOLD = type(probe.SetCountdownMillisecondsThreshold) == "function"
	probe:Hide()
	probe:SetParent(nil)
end
Wise.HAS_COUNTDOWN_FORMATTER = HAS_COUNTDOWN_FORMATTER
Wise.HAS_COUNTDOWN_MS_THRESHOLD = HAS_COUNTDOWN_MS_THRESHOLD


-- Countdown text format. The 12.0.5 patch can render cooldown text in two styles:
--   "short"    — bare number, no unit   (9, 30, 5, 1)   [default]
--   "extended" — number + 1-letter unit (9s, 30s, 5m, 1h)
-- This is resolved per group (with global fallback) via GetGroupDisplaySettings,
-- and the same convention is applied to both the out-of-combat numeric path (where
-- Wise writes its own text) and the combat / secret-mode path (where Blizzard's
-- native countdown drives the text via SetCountdownFormatter).
local COUNTDOWN_FORMAT_DEFAULT = "short"
Wise.COUNTDOWN_FORMAT_DEFAULT = COUNTDOWN_FORMAT_DEFAULT

-- Below this many seconds remaining, the countdown shows one decimal place
-- (e.g. 2.9, 0.4) so it ticks smoothly like Blizzard's native cooldown text,
-- instead of jumping a whole second at a time. Matches Blizzard's default
-- decimal threshold. The combat / secret-mode path mirrors this via
-- Cooldown:SetCountdownMillisecondsThreshold (see below).
local COUNTDOWN_DECIMAL_THRESHOLD = 3
Wise.COUNTDOWN_DECIMAL_THRESHOLD = COUNTDOWN_DECIMAL_THRESHOLD

-- Shared text helper for the out-of-combat numeric path. `rem` is a plain number
-- of seconds remaining; `format` is "short" or "extended".
local function FormatWiseCountdownText(rem, format)
	-- Sub-threshold: one decimal place for a smooth, native-feeling tick.
	-- Clamp at 0 so we never print "-0.0" on the frame the cooldown expires.
	if rem < COUNTDOWN_DECIMAL_THRESHOLD then
		if rem < 0 then
			rem = 0
		end
		if format == "extended" then
			return strformat("%.1fs", rem)
		end
		return strformat("%.1f", rem)
	end
	if format == "extended" then
		if rem >= 3600 then
			return strformat("%dh", ceil(rem / 3600))
		elseif rem >= 60 then
			return strformat("%dm", ceil(rem / 60))
		else
			return strformat("%ds", ceil(rem))
		end
	end
	-- "short": bare number, no unit.
	if rem >= 3600 then
		return strformat("%d", ceil(rem / 3600))
	elseif rem >= 60 then
		return strformat("%d", ceil(rem / 60))
	else
		return strformat("%d", ceil(rem))
	end
end
Wise.FormatWiseCountdownText = FormatWiseCountdownText

-- Lazily-built shared SecondsFormatter objects for the combat / secret-mode path,
-- one per format style, reused across all buttons. We can't compute remaining time
-- in combat (secret numbers), so we hand Blizzard's native countdown a formatter
-- that mirrors our own text convention.
--   extended → Enum.SecondsFormatterAbbreviation.OneLetter (9s / 5m / 1h)
--   short    → nil formatter (Blizzard default: whole seconds, no unit) — matches
--              our bare-number look for the sub-minute durations that dominate the
--              combat/secret path. (longer combat cooldowns are rare; best-effort.)
local _wiseSecondsFormatters = {}
local function GetWiseCountdownFormatter(format)
	if not HAS_COUNTDOWN_FORMATTER then
		return nil
	end
	if format ~= "extended" then
		-- "short" maps to the native default formatter (nil).
		return nil
	end
	local cached = _wiseSecondsFormatters[format]
	if cached == nil then
		local ok, fmt = pcall(C_StringUtil.CreateSecondsFormatter)
		if ok and fmt then
			-- OneLetter abbreviation → "9s" / "5m" / "1h", matching the extended
			-- numeric path. Guard each setter: the method set has shifted between
			-- builds, and a missing one shouldn't nil out the whole formatter.
			local abbrev = _G.Enum and _G.Enum.SecondsFormatterAbbreviation
			if abbrev and abbrev.OneLetter ~= nil and fmt.SetDefaultAbbreviation then
				pcall(fmt.SetDefaultAbbreviation, fmt, abbrev.OneLetter)
			end
			if fmt.SetStripIntervalWhitespace then
				local ws = _G.Enum and _G.Enum.SecondsFormatterIntervalWhitespace
				if ws and ws.StripIgnoreLocale ~= nil then
					pcall(fmt.SetStripIntervalWhitespace, fmt, ws.StripIgnoreLocale)
				end
			end
		end
		cached = (ok and fmt) or false
		_wiseSecondsFormatters[format] = cached
	end
	return cached or nil
end

local issecretvalue = issecretvalue or (_G and _G.issecretvalue)

-- Helper: Safely read a field from a table that may contain secret number values.
-- Returns the raw value only if it can be accessed without error.
-- Accepts a table and a key (string) rather than the already-read value,
-- because even *reading* the field `table.key` can crash on secret values.
-- Indexing helper hoisted out of SafeReadField: passing it to pcall along with
-- the arguments avoids allocating a fresh closure on every read. SafeReadField
-- runs on the per-button cooldown/charge paths many thousands of times per
-- second in combat, so the closure churn was showing up in GC pressure.
local function rawIndex(tbl, key)
	return tbl[key]
end

-- Secret-value probe hoisted for the same reason as rawIndex: passed to pcall
-- by reference so no closure is allocated per call.
local function checkSecret(val)
	return issecretvalue and issecretvalue(val)
end

local function SafeReadField(tbl, key)
	local ok, val = pcall(rawIndex, tbl, key)
	if not ok then
		return nil
	end
	return val
end

-- Helper: Clean secret number values in WoW 11.1+/12.0+ to prevent comparison errors in tainted execution.
-- Pass the *containing table* and *key* instead of the value directly when the
-- field might be secret; use CleanSecretNumber(SafeReadField(t, k)) together.
local function CleanSecretNumber(val)
	if val == nil then
		return nil
	end
	-- Fast-path: issecretvalue() is available in WoW 12.0+
	-- checkSecret is hoisted (see rawIndex above) so this pcall doesn't allocate
	-- a closure — CleanSecretNumber runs on every charge/cooldown field read.
	local svOk, isSecret = pcall(checkSecret, val)
	if svOk and isSecret then
		return nil
	end
	-- tostring() on a secret value will also throw, so wrap it too
	local ok, str = pcall(tostring, val)
	if ok and str then
		return tonumber(str)
	end
	return nil
end

-- Published for core/GUI.lua, which binds all of these as upvalues.
local CD = Wise.CooldownUtil or {}
Wise.CooldownUtil = CD
CD.FormatWiseCountdownText = FormatWiseCountdownText
CD.GetWiseCountdownFormatter = GetWiseCountdownFormatter
CD.SafeReadField = SafeReadField
CD.CleanSecretNumber = CleanSecretNumber
CD.COUNTDOWN_FORMAT_DEFAULT = COUNTDOWN_FORMAT_DEFAULT
CD.COUNTDOWN_DECIMAL_THRESHOLD = COUNTDOWN_DECIMAL_THRESHOLD
