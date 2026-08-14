-- Tests for Wise:SetViewerVisibility (Wise.lua).
--
-- Guards the 12.1 forbidden-table rule: never let a Wise-driven call reach a
-- CooldownViewer layout refresh. See AGENTS.md "Forbidden Tables on
-- CooldownViewer (12.1)".
--
-- The dangerous call is EditModeManagerFrame:OnSystemSettingChange. It is
-- CORRECT to call it when the setting actually changes — that is what gives
-- Wise native Edit Mode persistence — but a REDUNDANT call (target value
-- already applied) buys nothing and still runs the refresh chain tainted.
-- These tests pin "only call it when the value actually changes".

local function MakeViewer(name, visibleSetting)
	local viewer = CreateFrame("Frame", name, UIParent)
	-- nil models a viewer Edit Mode has not populated yet (early login).
	viewer.visibleSetting = visibleSetting
	return viewer
end

-- Swap in a recording EditModeManagerFrame and a stub for InCombatLockdown,
-- run fn, then restore. Returns the number of OnSystemSettingChange calls.
local function CountSettingChanges(fn)
	local savedEMM = _G.EditModeManagerFrame
	local savedICL = _G.InCombatLockdown

	local calls = 0
	_G.EditModeManagerFrame = {
		OnSystemSettingChange = function()
			calls = calls + 1
		end,
	}
	_G.InCombatLockdown = function()
		return false
	end

	local ok, err = pcall(fn)

	_G.EditModeManagerFrame = savedEMM
	_G.InCombatLockdown = savedICL

	if not ok then
		error(err, 0)
	end
	return calls
end

local ALWAYS = Enum.CooldownViewerVisibleSetting.Always
local HIDDEN = Enum.CooldownViewerVisibleSetting.Hidden

test("SetViewerVisibility: applies the change when the value differs", function()
	-- The load-bearing case: a real transition must still drive Edit Mode, or
	-- Wise loses the visibility feature entirely.
	_G.WiseTestViewerA = MakeViewer("WiseTestViewerA", ALWAYS)
	local calls = CountSettingChanges(function()
		Wise:SetViewerVisibility("WiseTestViewerA", true)
	end)
	assertEquals(1, calls)
end)

test("SetViewerVisibility: skips a redundant call when already at target", function()
	-- Already Always, asked for Always (hidden=false). Nothing to do.
	_G.WiseTestViewerB = MakeViewer("WiseTestViewerB", ALWAYS)
	local calls = CountSettingChanges(function()
		Wise:SetViewerVisibility("WiseTestViewerB", false)
	end)
	assertEquals(0, calls)
end)

test("SetViewerVisibility: skips a redundant call when already Hidden", function()
	_G.WiseTestViewerC = MakeViewer("WiseTestViewerC", HIDDEN)
	local calls = CountSettingChanges(function()
		Wise:SetViewerVisibility("WiseTestViewerC", true)
	end)
	assertEquals(0, calls)
end)

test("SetViewerVisibility: no Edit Mode call when visibleSetting is unpopulated", function()
	-- THE REGRESSION (BugGrabber session 5, 2026-08-13).
	--
	-- ReapplyAllHiding runs at PLAYER_LOGIN and again on +1s/+3s timers, because
	-- Edit Mode applies layouts asynchronously. On the earliest pass the viewer
	-- exists but Edit Mode has not populated `visibleSetting`, so it is nil.
	--
	-- The redundancy guard reads `viewer.visibleSetting ~= nil and ... == value`,
	-- which FAILS OPEN on nil: it cannot prove the value differs, so it applies
	-- anyway. For the overwhelmingly common default (hideTrackedBuffs = false →
	-- target Always, which is also the viewer's actual state) that call is pure
	-- redundancy, and it taints BuffIconCooldownViewer. The taint is persistent:
	-- Blizzard's own later UNIT_AURA refresh then throws from
	-- RegisterAuraInstanceIDItemFrame with Wise nowhere on the stack.
	--
	-- With state unknown, the safe action is to do NOTHING and let a later pass
	-- (when Edit Mode has populated the field) decide.
	_G.WiseTestViewerD = MakeViewer("WiseTestViewerD", nil)
	local calls = CountSettingChanges(function()
		Wise:SetViewerVisibility("WiseTestViewerD", false)
	end)
	assertEquals(0, calls)
end)

test("SetViewerVisibility: unpopulated viewer is not reported as applied", function()
	-- It must not claim success either — a caller that trusts `true` would stop
	-- retrying and the setting would never land once Edit Mode populates.
	_G.WiseTestViewerE = MakeViewer("WiseTestViewerE", nil)
	local result
	CountSettingChanges(function()
		result = Wise:SetViewerVisibility("WiseTestViewerE", true)
	end)
	assertFalse(result)
end)

test("SetViewerVisibility: refuses to run in combat", function()
	-- Edit Mode setting changes are protected.
	_G.WiseTestViewerF = MakeViewer("WiseTestViewerF", ALWAYS)
	local savedICL = _G.InCombatLockdown
	_G.InCombatLockdown = function()
		return true
	end
	local result = Wise:SetViewerVisibility("WiseTestViewerF", true)
	_G.InCombatLockdown = savedICL
	assertFalse(result)
end)

test("SetViewerVisibility: never calls GetSettingValue on a viewer", function()
	-- Method dispatch through the setting map on a frame that owns forbidden
	-- tables is itself a tainted index (AGENTS.md). Reading the plain field is
	-- the sanctioned route, so a call here is a regression.
	_G.WiseTestViewerG = MakeViewer("WiseTestViewerG", ALWAYS)
	local touched = false
	_G.WiseTestViewerG.GetSettingValue = function()
		touched = true
		return ALWAYS
	end
	CountSettingChanges(function()
		Wise:SetViewerVisibility("WiseTestViewerG", true)
	end)
	assertFalse(touched)
end)

test("SetViewerVisibility: never calls UpdateShownState on a viewer", function()
	-- The original detonator: UpdateShownState -> OnShow -> RefreshLayout ->
	-- RefreshData -> RegisterAuraInstanceIDItemFrame -> forbidden table.
	_G.WiseTestViewerH = MakeViewer("WiseTestViewerH", ALWAYS)
	local touched = false
	_G.WiseTestViewerH.UpdateShownState = function()
		touched = true
	end
	CountSettingChanges(function()
		Wise:SetViewerVisibility("WiseTestViewerH", true)
	end)
	assertFalse(touched)
end)
