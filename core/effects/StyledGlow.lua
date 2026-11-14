-- core/effects/StyledGlow.lua
--
-- Glow styles beyond the proc flipbook, drawn by LibCustomGlow-1.0
-- (Libs/LibCustomGlow-1.0: the upstream MIT release, vendored unmodified).
-- OverlayGlow.lua remains THE proc glow. This file is for drivers that must
-- look different from a proc so the player can tell them apart; the first
-- user is the Assisted Combat suggestion glow (core/effects/AssistGlow.lua).
--
-- Every styled glow carries a KEY naming its driver. Different keys on the same
-- button coexist, and they also coexist with the proc overlay: LibCustomGlow
-- draws on its own child frames. The one exception is the "button" style,
-- which LibCustomGlow keeps one-per-frame (ButtonGlow takes no key). Only one
-- driver should use it.
--
-- Without the library (a stripped or broken install), every style falls back
-- to the proc flipbook through OverlayGlow's owner set, with the key as the
-- owner. That keeps the owner bookkeeping correct: hiding a styled glow never
-- tears down a real proc glow.
--
-- Public API: Wise:ShowStyledGlow(frame, style, key, color)
--             Wise:HideStyledGlow(frame, key)
--             Wise.GLOW_STYLES / Wise.GLOW_STYLE_LABELS (settings UI order)
--             Wise.Effects.GroupSetting(groupName, key, default)
--
-- Loaded after OverlayGlow.lua (fallback) and after the Libs block (library).

local addonName, Wise = ...

local LibStub = LibStub
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)

local GLOW_STYLES = { "pixel", "autocast", "button", "proc" }
local GLOW_STYLE_LABELS = {
	pixel = "Pixel",
	autocast = "Autocast",
	button = "Button glow",
	proc = "Proc",
}
local DEFAULT_STYLE = "pixel"
Wise.GLOW_STYLES = GLOW_STYLES
Wise.GLOW_STYLE_LABELS = GLOW_STYLE_LABELS
Wise.HAS_CUSTOM_GLOW = LCG ~= nil

-- LibCustomGlow's ProcGlow_Start setmetatable()s the options table it is given
-- and reads key/color from it. One reused table, refilled per call, keeps the
-- start path allocation-free (starts only happen on a state change anyway).
local procOptions = { key = "", color = nil }

local function StartStyle(frame, style, key, color)
	if not LCG then
		Wise:ShowOverlayGlow(frame, nil, key)
		return
	end
	if style == "pixel" then
		-- 8 lines, 0.25 Hz, auto length, 2px thick, no border: LibCustomGlow's
		-- own defaults apart from the thickness.
		LCG.PixelGlow_Start(frame, color, 8, 0.25, nil, 2, 0, 0, false, key)
	elseif style == "autocast" then
		LCG.AutoCastGlow_Start(frame, color, 4, 0.125, 1, 0, 0, key)
	elseif style == "button" then
		LCG.ButtonGlow_Start(frame, color)
	else
		procOptions.key = key
		procOptions.color = color
		LCG.ProcGlow_Start(frame, procOptions)
	end
end

local function StopStyle(frame, style, key)
	if not LCG then
		Wise:HideOverlayGlow(frame, key)
		return
	end
	if style == "pixel" then
		LCG.PixelGlow_Stop(frame, key)
	elseif style == "autocast" then
		LCG.AutoCastGlow_Stop(frame, key)
	elseif style == "button" then
		LCG.ButtonGlow_Stop(frame)
	else
		LCG.ProcGlow_Stop(frame, key)
	end
end

-- Idempotent: a frame already lit in this style for this key is left alone, so
-- a driver can call Show every pass without restarting the animation. A style
-- change restarts the glow in the new style. color is LibCustomGlow's
-- {r, g, b, a} table (nil = the style's default colour); a colour change alone
-- does not restart a lit glow.
function Wise:ShowStyledGlow(frame, style, key, color)
	if not frame then
		return
	end
	if not GLOW_STYLE_LABELS[style] then
		style = DEFAULT_STYLE
	end
	local active = frame.__WiseStyledGlows
	if not active then
		active = {}
		frame.__WiseStyledGlows = active
	end
	local current = active[key]
	if current == style then
		return
	end
	if current then
		StopStyle(frame, current, key)
	end
	active[key] = style
	StartStyle(frame, style, key, color)
end

function Wise:HideStyledGlow(frame, key)
	local active = frame and frame.__WiseStyledGlows
	local current = active and active[key]
	if not current then
		return
	end
	active[key] = nil
	StopStyle(frame, current, key)
end

-- Per-interface effect setting with the same tri-state override as showGlows in
-- GetGroupDisplaySettings: a non-nil value on the group wins, otherwise the
-- global setting, otherwise `default`. Kept out of GetGroupDisplaySettings on
-- purpose -- that returns ~20 values positionally, and every new one shifts
-- the call sites that unpack it.
local Effects = Wise.Effects or {}
Wise.Effects = Effects
function Effects.GroupSetting(groupName, key, default)
	local db = WiseDB
	local value = db and db.settings and db.settings[key]
	local group = groupName and db and db.groups and db.groups[groupName]
	if group and group[key] ~= nil then
		value = group[key]
	end
	if value == nil then
		return default
	end
	return value
end

-- True when the setting is on globally or overridden on for any interface, so a
-- driver can stay completely idle when nobody uses it.
function Effects.AnyGroupEnables(key, default)
	local db = WiseDB
	if not db then
		return false
	end
	local global = db.settings and db.settings[key]
	if global == nil then
		global = default
	end
	if global then
		return true
	end
	for _, group in pairs(db.groups or {}) do
		if group[key] == true then
			return true
		end
	end
	return false
end
