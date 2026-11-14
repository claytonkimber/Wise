-- wow-ui-sim tests for the vehicle / override / possess bar macro pipeline.
--
-- Ported from the standalone lua5.1 script tests/test_vehicle_bar_fix.lua, which
-- could not run under the simulator (no `loadfile`) and clobbered globals at file
-- scope. Covers, end to end:
--   Wise:NegateConditional            (modules/States.lua)
--   Wise:ComputeEffectiveConditions   (modules/States.lua)
--   Wise:FilterMacroTextForCharacter  (modules/SlotConfigurator.lua)
--   Wise:ResolveMacroData             (modules/Actions.lua)
--   Wise:GetSecureAttributes          (core/GUI.lua)
--
-- Stubbing rules (see AGENTS.md "Simulator gotchas"): only APIs the code reads
-- at CALL time are stubbed. C_* namespaces are patched field by field, never
-- replaced. Everything a helper stubs is restored afterwards, even on failure.

-- The bar-state APIs ResolveMacroData / ResolveBarActionID read at call time, and
-- the C_ActionBar fields next to them.
local GLOBAL_STUBS = {
	"SecureCmdOptionParse",
	"CanExitVehicle",
	"UnitHasVehicleUI",
	"HasVehicleActionBar",
	"HasOverrideActionBar",
	"HasTempShapeshiftActionBar",
	"GetBonusBarOffset",
	"GetActionTexture",
}
local C_ACTIONBAR_STUBS = {
	"HasVehicleActionBar",
	"HasOverrideActionBar",
	"HasTempShapeshiftActionBar",
	"GetVehicleBarIndex",
	"GetOverrideBarIndex",
	"GetTempShapeshiftBarIndex",
	"IsPossessBarVisible",
}

local SPELLS = {
	[106839] = { spellID = 106839, name = "Skull Bash", iconID = 236302 },
	[740] = { spellID = 740, name = "Tranquility", iconID = 136107 },
	[460002] = { spellID = 460002, name = "Switch Flight Style", iconID = 555666 },
	[361584] = { spellID = 361584, name = "Whirling Surge", iconID = 777888 },
}
local SPELLS_BY_NAME = {}
for _, info in pairs(SPELLS) do
	SPELLS_BY_NAME[info.name] = info
end

-- The TestFramework's assert* helpers take no failure message, so assertions that
-- carry diagnostic detail (the offending value) go through this instead.
local function check(cond, msg)
	if not cond then
		error(msg or "assertion failed", 2)
	end
end

local function trim(s)
	return s and s:match("^%s*(.-)%s*$") or ""
end

-- Run fn(env) with the vehicle/override/possess world faked. `env` is mutable:
-- the stubs read it at call time, so a test can flip env.canexitvehicle etc.
-- between assertions. Fields:
--   canexitvehicle  also drives UnitHasVehicleUI / HasVehicleActionBar
--   overridebar     HasOverrideActionBar
--   possessbar      HasTempShapeshiftActionBar
--   bonusbar5       GetBonusBarOffset() == 5
--   textures        { [actionID] = icon } for GetActionTexture
--   buttons         how many OverrideActionBarButton<N> frames exist (default 12)
--   allowActions    Wise:IsActionAllowed returns true for everything
local function withVehicleEnv(env, fn)
	env.textures = env.textures or {}
	local buttons = env.buttons or 12

	local savedG = {}
	for _, k in ipairs(GLOBAL_STUBS) do
		savedG[k] = _G[k]
	end
	local savedC = {}
	if C_ActionBar then
		for _, k in ipairs(C_ACTIONBAR_STUBS) do
			savedC[k] = C_ActionBar[k]
		end
	end
	local savedSpellInfo = C_Spell.GetSpellInfo
	local savedIsActionAllowed = Wise.IsActionAllowed
	local savedFrames = {}
	for i = 1, 32 do
		savedFrames[i] = _G["OverrideActionBarButton" .. i]
	end

	_G.SecureCmdOptionParse = function(condStr)
		if not condStr or condStr == "" then
			return ""
		end
		local live = {
			canexitvehicle = env.canexitvehicle,
			overridebar = env.overridebar,
			possessbar = env.possessbar,
			["bonusbar:5"] = env.bonusbar5,
		}
		for clause in condStr:gmatch("[^;]+") do
			local clean = trim(clause)
			local target = trim((clean:gsub("%b[]", "")))
			if not clean:find("%[") then
				return target
			end
			for group in clean:gmatch("%[([^%]]*)%]") do
				local ok = true
				for token in group:gmatch("[^,]+") do
					token = trim(token)
					local neg = token:sub(1, 2) == "no"
					local base = neg and token:sub(3) or token
					local val = live[base] or false
					if neg then
						val = not val
					end
					if not val then
						ok = false
						break
					end
				end
				if ok then
					return target
				end
			end
		end
		return ""
	end
	_G.CanExitVehicle = function()
		return env.canexitvehicle or false
	end
	_G.UnitHasVehicleUI = function()
		return env.canexitvehicle or false
	end
	_G.HasVehicleActionBar = function()
		return env.canexitvehicle or false
	end
	_G.HasOverrideActionBar = function()
		return env.overridebar or false
	end
	_G.HasTempShapeshiftActionBar = function()
		return env.possessbar or false
	end
	_G.GetBonusBarOffset = function()
		return env.bonusbar5 and 5 or 0
	end
	_G.GetActionTexture = function(actionID)
		return env.textures[actionID]
	end
	if C_ActionBar then
		C_ActionBar.HasVehicleActionBar = _G.HasVehicleActionBar
		C_ActionBar.HasOverrideActionBar = _G.HasOverrideActionBar
		C_ActionBar.HasTempShapeshiftActionBar = _G.HasTempShapeshiftActionBar
		C_ActionBar.GetVehicleBarIndex = function()
			return 16
		end
		C_ActionBar.GetOverrideBarIndex = function()
			return 18
		end
		C_ActionBar.GetTempShapeshiftBarIndex = function()
			return 17
		end
		C_ActionBar.IsPossessBarVisible = function()
			return env.possessbar or false
		end
	end
	C_Spell.GetSpellInfo = function(idOrName)
		return SPELLS[idOrName] or SPELLS_BY_NAME[idOrName]
	end
	if env.allowActions then
		Wise.IsActionAllowed = function()
			return true
		end
	end
	-- Wise:GetOverrideBarButtonCount caches its first non-zero probe, so clear it
	-- around the body to force a re-probe against the stubbed frame set.
	for i = 1, 32 do
		if i <= buttons then
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

	local ok, err = pcall(fn, env)

	for _, k in ipairs(GLOBAL_STUBS) do
		_G[k] = savedG[k]
	end
	if C_ActionBar then
		for _, k in ipairs(C_ACTIONBAR_STUBS) do
			C_ActionBar[k] = savedC[k]
		end
	end
	C_Spell.GetSpellInfo = savedSpellInfo
	Wise.IsActionAllowed = savedIsActionAllowed
	for i = 1, 32 do
		_G["OverrideActionBarButton" .. i] = savedFrames[i]
	end
	Wise:ResetOverrideBarButtonCount()

	if not ok then
		error(err, 0)
	end
end

-- The per-button macros the slot configurator compiles for a Druid-style bar:
-- vehicle/override line, possess line, then the class fallback.
local btn1Macro =
	"#showtooltip\n/click [overridebar][canexitvehicle] OverrideActionBarButton1\n/click [possessbar][bonusbar:5] ActionButton1\n/cast [nooverridebar,nocanexitvehicle] Tranquility"
local btn2Macro =
	"#showtooltip\n/click [overridebar][canexitvehicle] OverrideActionBarButton2\n/click [possessbar][bonusbar:5] ActionButton2\n/cast [nooverridebar,nocanexitvehicle] Skull Bash"

-- ── NegateConditional ───────────────────────────────────────────────────────

test("NegateConditional: single tokens flip with and without the no prefix", function()
	check(Wise:NegateConditional("[combat]") == "[nocombat]", "combat negate failed")
	check(Wise:NegateConditional("[nocombat]") == "[combat]", "nocombat negate failed")
end)

test("NegateConditional: multiple groups become one AND of negated tokens", function()
	local negated = Wise:NegateConditional("[overridebar][canexitvehicle]")
	check(negated == "[nooverridebar,nocanexitvehicle]", "multi-group negate failed, got: " .. tostring(negated))
end)

test("NegateConditional: bonusbar has no negation form and is omitted", function()
	-- [nobonusbar:5] is invalid syntax in WoW macros and poisons the whole bracket.
	local negatedPos = Wise:NegateConditional("[possessbar][bonusbar:5]")
	check(negatedPos == "[nopossessbar]", "possess negate failed, got: " .. tostring(negatedPos))
	check(not tostring(negatedPos):find("bonusbar", 1, true), "bonusbar must never be negated, got: " .. tostring(negatedPos))
end)

-- ── ComputeEffectiveConditions ──────────────────────────────────────────────

local function specialBarStates()
	return {
		{ type = "action", value = 134, conditions = "[overridebar][canexitvehicle]", exclusive = true },
		{ type = "action", value = 122, conditions = "[possessbar][bonusbar:5]", exclusive = true },
		{ type = "spell", value = 106839, conditions = "", exclusive = false },
	}
end

test("ComputeEffectiveConditions: special bar states do not negate each other", function()
	local states = specialBarStates()
	local c1 = Wise:ComputeEffectiveConditions(states, 1)
	local c2 = Wise:ComputeEffectiveConditions(states, 2)
	check(c1 == "[overridebar][canexitvehicle]", "State 1 negated state 2 erroneously: " .. tostring(c1))
	check(c2 == "[possessbar][bonusbar:5]", "State 2 negated state 1 erroneously: " .. tostring(c2))
end)

test("ComputeEffectiveConditions: fallback inherits only valid special bar negations", function()
	local states = specialBarStates()
	local c3 = Wise:ComputeEffectiveConditions(states, 3)
	check(
		c3:find("nooverridebar", 1, true)
			and c3:find("nocanexitvehicle", 1, true)
			and c3:find("nopossessbar", 1, true)
			and not c3:find("nobonusbar", 1, true),
		"State 3 must inherit valid special bar negations, got: " .. tostring(c3)
	)
end)

-- ── FilterMacroTextForCharacter ─────────────────────────────────────────────

test("FilterMacroTextForCharacter: override line present, class spell gated on nocanexitvehicle", function()
	withVehicleEnv({ allowActions = true }, function()
		local compiledAction = {
			type = "misc",
			value = "custom_macro",
			pathNodeIds = { 1, 2, 3 },
		}
		local graph = {
			nodes = {
				{
					id = 1,
					action = { type = "action", value = 134, conditions = "[overridebar][canexitvehicle]", exclusive = true },
					condition = "[overridebar][canexitvehicle]",
				},
				{
					id = 2,
					action = { type = "action", value = 122, conditions = "[possessbar][bonusbar:5]", exclusive = true },
					condition = "[possessbar][bonusbar:5]",
				},
				{
					id = 3,
					action = { type = "spell", value = 106839, conditions = "", exclusive = false },
					condition = "",
				},
			},
		}

		local macroText = Wise:FilterMacroTextForCharacter(compiledAction, graph)
		check(macroText ~= nil, "FilterMacroTextForCharacter returned no macro text")

		check(
			macroText:find("/click %[[^%]]*canexitvehicle[^%]]*%] OverrideActionBarButton2"),
			"Override line missing, got: " .. macroText
		)
		check(
			macroText:find("/cast %[.*nocanexitvehicle.*%] Skull Bash"),
			"Skull bash must be gated on nocanexitvehicle, got: " .. macroText
		)
	end)
end)

-- ── ResolveMacroData ────────────────────────────────────────────────────────

test("ResolveMacroData: War Turtle slot 1 resolves the vehicle ability", function()
	-- Slot 1 (181 on vehicle page 16) has Turtle Strike. Base slot 1 holds Wrath,
	-- which must never be picked up while the vehicle is active.
	withVehicleEnv({
		canexitvehicle = true,
		textures = { [181] = 132145, [1] = 222333, [2] = 222444 },
	}, function()
		local t1, v1, i1 = Wise:ResolveMacroData(btn1Macro)
		check(
			t1 == "action" and v1 == 133 and i1 == 132145,
			"Button 1 must resolve Turtle Strike, got: " .. tostring(t1) .. ", " .. tostring(v1) .. ", " .. tostring(i1)
		)
	end)
end)

test("ResolveMacroData: War Turtle empty slot 2 resolves to nil, never base bar spells", function()
	-- Slot 2 (182 on vehicle page 16) is EMPTY. Base slot 2 holds Moonfire.
	withVehicleEnv({
		canexitvehicle = true,
		textures = { [181] = 132145, [182] = nil, [1] = 222333, [2] = 222444 },
	}, function()
		local t2, v2, i2 = Wise:ResolveMacroData(btn2Macro)
		check(
			t2 == nil and v2 == nil and i2 == nil,
			"Button 2 must resolve to nil (empty slot, NEVER Wrath/Moonfire), got: "
				.. tostring(t2)
				.. ", "
				.. tostring(v2)
				.. ", "
				.. tostring(i2)
		)
	end)
end)

test("ResolveMacroData: dismounting the War Turtle falls back to the class spells", function()
	withVehicleEnv({
		canexitvehicle = false,
		textures = { [181] = 132145, [1] = 222333, [2] = 222444 },
	}, function()
		local t1, v1, i1 = Wise:ResolveMacroData(btn1Macro)
		check(
			t1 == "spell" and v1 == 740 and i1 == 136107,
			"Button 1 off vehicle must resolve Tranquility, got: " .. tostring(t1)
		)

		local t2, v2, i2 = Wise:ResolveMacroData(btn2Macro)
		check(
			t2 == "spell" and v2 == 106839 and i2 == 236302,
			"Button 2 off vehicle must resolve Skull Bash, got: " .. tostring(t2)
		)
	end)
end)

test("ResolveMacroData: possess vehicle (possessbar + bonusbar:5 + canexitvehicle)", function()
	withVehicleEnv({
		possessbar = true,
		bonusbar5 = true,
		canexitvehicle = true,
		textures = { [181] = 999111 },
	}, function()
		local t5, v5, i5 = Wise:ResolveMacroData(btn1Macro)
		check(
			t5 == "action" and v5 == 133 and i5 == 999111,
			"Possess vehicle must resolve spell 1, got: " .. tostring(t5) .. ", " .. tostring(v5) .. ", " .. tostring(i5)
		)

		local t5b = Wise:ResolveMacroData(btn2Macro)
		check(t5b == nil, "Possess vehicle slot 2 must be nil (empty), got: " .. tostring(t5b))
	end)
end)

test("ResolveMacroData: skinned vehicle (overridebar + canexitvehicle)", function()
	withVehicleEnv({
		overridebar = true,
		canexitvehicle = true,
		textures = { [181] = 888222 },
	}, function()
		local t6, v6, i6 = Wise:ResolveMacroData(btn1Macro)
		check(
			t6 == "action" and v6 == 133 and i6 == 888222,
			"Skinned vehicle must resolve spell 1, got: " .. tostring(t6) .. ", " .. tostring(v6) .. ", " .. tostring(i6)
		)
	end)
end)

-- ── GetSecureAttributes: slots 7 and 8 ──────────────────────────────────────

test("GetSecureAttributes: slots 7 and 8 click their own override buttons (not button 1)", function()
	withVehicleEnv({}, function()
		local _, _, s7Val =
			Wise:GetSecureAttributes({ type = "action", value = 139, conditions = "[overridebar][canexitvehicle]" }, "ActionBar", 7)
		check(
			tostring(s7Val):find("OverrideActionBarButton7"),
			"Slot 7 must click OverrideActionBarButton7, got: " .. tostring(s7Val)
		)

		local _, _, s8Val =
			Wise:GetSecureAttributes({ type = "action", value = 140, conditions = "[overridebar][canexitvehicle]" }, "ActionBar", 8)
		check(
			tostring(s8Val):find("OverrideActionBarButton8"),
			"Slot 8 must click OverrideActionBarButton8, got: " .. tostring(s8Val)
		)
	end)
end)

-- ── Empty vehicle slots: no question marks ──────────────────────────────────

test("ResolveMacroData: empty vehicle slots resolve to nil icons (no question marks)", function()
	-- Skinned vehicle up, but slots 5 and 7 hold nothing.
	withVehicleEnv({ overridebar = true, canexitvehicle = true }, function()
		local btn5Macro =
			"#showtooltip\n/click [overridebar][canexitvehicle] OverrideActionBarButton5\n/click [possessbar][bonusbar:5] ActionButton5"
		local _, _, i5 = Wise:ResolveMacroData(btn5Macro)
		check(i5 == nil, "Slot 5 icon must be nil (hidden), got: " .. tostring(i5))

		local btn7Macro =
			"#showtooltip\n/click [overridebar][canexitvehicle] OverrideActionBarButton7\n/click [possessbar][bonusbar:5] ActionButton7"
		local _, _, i7 = Wise:ResolveMacroData(btn7Macro)
		check(i7 == nil, "Slot 7 icon must be nil (hidden), got: " .. tostring(i7))
	end)
end)

-- ── Slots 7 and 8 on a vehicle with class fallbacks ─────────────────────────

local slot7FullMacro =
	"#showtooltip\n/click [overridebar][canexitvehicle] OverrideActionBarButton7\n/click [canexitvehicle] OverrideActionBarButton7\n/click [possessbar][bonusbar:5] ActionButton7\n/cast [nooverridebar,nocanexitvehicle,nopossessbar,nobonusbar:5] Switch Flight Style"
local slot8FullMacro =
	"#showtooltip\n/click [overridebar][canexitvehicle] OverrideActionBarButton8\n/click [canexitvehicle] OverrideActionBarButton8\n/click [possessbar][bonusbar:5] ActionButton8\n/cast [nooverridebar,nocanexitvehicle,nopossessbar,nobonusbar:5] Whirling Surge"

test("ResolveMacroData: slots 7 and 8 on a 6-button vehicle never fall through to class spells", function()
	-- Only 6 OverrideActionBarButton frames exist, so 7 and 8 are past the bar.
	withVehicleEnv({ canexitvehicle = true, buttons = 6 }, function()
		local t7, v7, i7 = Wise:ResolveMacroData(slot7FullMacro)
		check(
			t7 == nil and v7 == nil and i7 == nil,
			"Slot 7 on vehicle must be nil/empty, but got: " .. tostring(t7) .. ", " .. tostring(v7)
		)

		local t8, v8, i8 = Wise:ResolveMacroData(slot8FullMacro)
		check(
			t8 == nil and v8 == nil and i8 == nil,
			"Slot 8 on vehicle must be nil/empty, but got: " .. tostring(t8) .. ", " .. tostring(v8)
		)
	end)
end)

test("ResolveMacroData: a texture behind a nonexistent override button is not trusted", function()
	-- Same as above, but the action slots behind buttons 7 and 8 report an icon
	-- (187/188 on vehicle page 16). With no such frame the /click could never
	-- fire, so the display must stay empty rather than show a dead button.
	withVehicleEnv({
		canexitvehicle = true,
		buttons = 6,
		textures = { [187] = 555111, [188] = 555222 },
	}, function()
		local t7, v7, i7 = Wise:ResolveMacroData(slot7FullMacro)
		check(
			t7 == nil and v7 == nil and i7 == nil,
			"Slot 7 past the bar must be nil/empty, but got: " .. tostring(t7) .. ", " .. tostring(v7)
		)
		local t8, v8, i8 = Wise:ResolveMacroData(slot8FullMacro)
		check(
			t8 == nil and v8 == nil and i8 == nil,
			"Slot 8 past the bar must be nil/empty, but got: " .. tostring(t8) .. ", " .. tostring(v8)
		)
	end)
end)

test("ResolveMacroData: slot 7 dismounted resolves the class fallback", function()
	withVehicleEnv({ canexitvehicle = false, buttons = 6 }, function()
		local t7, v7 = Wise:ResolveMacroData(slot7FullMacro)
		check(
			t7 == "spell" and v7 == 460002,
			"Slot 7 dismounted must resolve Switch Flight Style, got: " .. tostring(t7)
		)
	end)
end)

test("withVehicleEnv: restores every global and field it stubbed", function()
	local before = {}
	for _, k in ipairs(GLOBAL_STUBS) do
		before[k] = _G[k]
	end
	local beforeSpell = C_Spell.GetSpellInfo
	local beforeAllowed = Wise.IsActionAllowed
	local beforeFrame = _G.OverrideActionBarButton1

	withVehicleEnv({ allowActions = true, buttons = 3 }, function()
		check(_G.SecureCmdOptionParse ~= before.SecureCmdOptionParse, "SecureCmdOptionParse was not stubbed")
	end)
	-- Also restored when the body throws.
	local ok = pcall(withVehicleEnv, {}, function()
		error("boom")
	end)
	assertEquals(false, ok)

	for _, k in ipairs(GLOBAL_STUBS) do
		check(_G[k] == before[k], k .. " was not restored")
	end
	check(C_Spell.GetSpellInfo == beforeSpell, "C_Spell.GetSpellInfo was not restored")
	check(Wise.IsActionAllowed == beforeAllowed, "Wise.IsActionAllowed was not restored")
	check(_G.OverrideActionBarButton1 == beforeFrame, "OverrideActionBarButton1 was not restored")
end)
