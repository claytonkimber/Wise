-- Unit test for vehicle/override bar fallback fix

local Wise = {}

-- Load modules
local function loadModule(file)
	local fn, err = loadfile(file)
	if not fn then
		error("Failed to load " .. file .. ": " .. tostring(err))
	end
	fn("Wise", Wise)
end

-- Minimal WoW environment stubs for standalone testing
-- Minimal WoW environment stubs for standalone testing
_G.GetBuildInfo = function()
	return "12.0.7", "60000", "Aug 26 2026", 120007
end
_G.GetExtraBarIndex = function()
	return 19
end
_G.GetCVarBool = function()
	return false
end
_G.InCombatLockdown = function()
	return false
end
local function makeStubFrame()
	local f = {}
	local methods = {
		"SetSize", "SetPoint", "ClearAllPoints", "SetParent", "GetParent",
		"RegisterEvent", "UnregisterEvent", "RegisterUnitEvent", "SetScript", "GetScript",
		"Show", "Hide", "IsShown", "SetAttribute", "GetAttribute",
		"SetWidth", "SetHeight", "GetWidth", "GetHeight", "SetAlpha",
		"EnableMouse", "RegisterForClicks", "RegisterForDrag",
		"HookScript", "SetFrameRef", "GetFrameRef", "GetName"
	}
	for _, m in ipairs(methods) do
		f[m] = function() return f end
	end
	f.CreateTexture = function()
		return {
			SetAllPoints = function() end,
			SetTexture = function() end,
			SetTexCoord = function() end,
			Show = function() end,
			Hide = function() end,
			SetDesaturated = function() end,
			SetAlpha = function() end,
			SetVertexColor = function() end,
		}
	end
	f.CreateFontString = function()
		return {
			SetPoint = function() end,
			SetFont = function() end,
			SetText = function() end,
			SetTextColor = function() end,
			SetJustifyH = function() end,
			Show = function() end,
			Hide = function() end,
		}
	end
	return f
end
_G.CreateFrame = function() return makeStubFrame() end
_G.UIParent = makeStubFrame()
_G.UIErrorsFrame = makeStubFrame()
_G.C_Timer = {
	After = function(t, fn) end,
	NewTicker = function() return { Cancel = function() end } end,
}
_G.hooksecurefunc = function() end
_G.SecureHandlerWrapScript = function() end
_G.RegisterStateDriver = function() end
_G.UnregisterStateDriver = function() end
_G.strtrim = function(s)
	return s and s:match("^%s*(.-)%s*$") or ""
end
_G.tinsert = table.insert
_G.tonumber = tonumber
_G.tostring = tostring
_G.type = type
_G.pairs = pairs
_G.ipairs = ipairs
_G.select = select
_G.C_Spell = {
	GetSpellInfo = function(id)
		if id == 106839 or id == "Skull Bash" then
			return { spellID = 106839, name = "Skull Bash", iconID = 236302 }
		elseif id == 740 or id == "Tranquility" then
			return { spellID = 740, name = "Tranquility", iconID = 136107 }
		elseif id == 460002 or id == "Switch Flight Style" then
			return { spellID = 460002, name = "Switch Flight Style", iconID = 555666 }
		elseif id == 361584 or id == "Whirling Surge" then
			return { spellID = 361584, name = "Whirling Surge", iconID = 777888 }
		end
		return nil
	end,
	GetSpellSubtext = function() return nil end,
}
_G.C_Item = {
	GetItemInfo = function() return nil end,
	GetItemInfoInstant = function() return nil end,
}
_G.C_ActionBar = {
	GetVehicleBarIndex = function() return 16 end,
	GetOverrideBarIndex = function() return 18 end,
	GetTempShapeshiftBarIndex = function() return 17 end,
	IsPossessBarVisible = function() return false end,
}
_G.NUM_ACTIONBAR_BUTTONS = 12

local envState = {
	canexitvehicle = false,
	overridebar = false,
	possessbar = false,
	["bonusbar:5"] = false,
}

_G.SecureCmdOptionParse = function(condStr)
	if not condStr or condStr == "" then
		return ""
	end
	for clause in condStr:gmatch("[^;]+") do
		local clean = strtrim(clause)
		local target = clean:gsub("%b[]", "")
		target = strtrim(target)

		local hasBrackets = clean:find("%[")
		if not hasBrackets then
			return target
		end

		for group in clean:gmatch("%[([^%]]*)%]") do
			local ok = true
			for token in group:gmatch("[^,]+") do
				token = strtrim(token)
				local neg = token:sub(1, 2) == "no"
				local base = neg and token:sub(3) or token
				local val = envState[base] or false
				if neg then val = not val end
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
	return envState.canexitvehicle
end
_G.UnitHasVehicleUI = function(unit)
	return envState.canexitvehicle
end
_G.HasVehicleActionBar = function()
	return envState.canexitvehicle
end
_G.HasOverrideActionBar = function()
	return envState.overridebar
end
_G.HasTempShapeshiftActionBar = function()
	return envState.possessbar
end
_G.GetBonusBarOffset = function()
	return envState["bonusbar:5"] and 5 or 0
end

local actionTextures = {}
_G.GetActionTexture = function(actionID)
	return actionTextures[actionID]
end

Wise.IsValidOverrideBarIndex = function(self, idx)
	local n = tonumber(idx)
	return n and n >= 1 and n <= 12
end
Wise.IsActionAllowed = function(self, a)
	return true
end
Wise.GetActionIcon = function(self, aType, aVal, aData)
	if aType == "spell" then
		local s = C_Spell.GetSpellInfo(aVal)
		return s and s.iconID
	end
	return aData and aData.icon or 134400
end
Wise.SanitizeMacroCondition = function(self, c) return c or "" end
Wise.GetOverrideSpellID = function(self, id) return id end

Wise.Compat = {
	WrapAuraWidget = function() end,
	GateOnUpdate = function() end,
	SetOnUpdateWhenVisible = function() end,
}
loadModule("modules/States.lua")
loadModule("core/GUI.lua")
loadModule("modules/Actions.lua")
loadModule("modules/SlotConfigurator.lua")

-- =========================================================================
-- TEST 1: NegateConditional
-- =========================================================================
print("Running TEST 1: NegateConditional...")
assert(Wise:NegateConditional("[combat]") == "[nocombat]", "combat negate failed")
assert(Wise:NegateConditional("[nocombat]") == "[combat]", "nocombat negate failed")
local negated = Wise:NegateConditional("[overridebar][canexitvehicle]")
assert(negated == "[nooverridebar,nocanexitvehicle]", "multi-group negate failed, got: " .. tostring(negated))
local negatedPos = Wise:NegateConditional("[possessbar][bonusbar:5]")
assert(negatedPos == "[nopossessbar,nobonusbar:5]", "possess negate failed, got: " .. tostring(negatedPos))
print("  TEST 1 PASSED!")

-- =========================================================================
-- TEST 2: ComputeEffectiveConditions with special-bar overlap rule
-- =========================================================================
print("Running TEST 2: ComputeEffectiveConditions...")
local states = {
	{ type = "action", value = 134, conditions = "[overridebar][canexitvehicle]", exclusive = true },
	{ type = "action", value = 122, conditions = "[possessbar][bonusbar:5]", exclusive = true },
	{ type = "spell", value = 106839, conditions = "", exclusive = false },
}

local c1 = Wise:ComputeEffectiveConditions(states, 1)
local c2 = Wise:ComputeEffectiveConditions(states, 2)
local c3 = Wise:ComputeEffectiveConditions(states, 3)

assert(c1 == "[overridebar][canexitvehicle]", "State 1 negated state 2 erroneously: " .. tostring(c1))
assert(c2 == "[possessbar][bonusbar:5]", "State 2 negated state 1 erroneously: " .. tostring(c2))
assert(c3:find("nooverridebar", 1, true) and c3:find("nocanexitvehicle", 1, true) and c3:find("nopossessbar", 1, true) and c3:find("nobonusbar:5", 1, true),
	"State 3 must inherit all special bar negations, got: " .. tostring(c3))
print("  TEST 2 PASSED!")

-- =========================================================================
-- TEST 3: FilterMacroTextForCharacter with graph nodes
-- =========================================================================
print("Running TEST 3: FilterMacroTextForCharacter...")
local compiledAction = {
	type = "misc",
	value = "custom_macro",
	pathNodeIds = { 1, 2, 3 },
}
local graph = {
	nodes = {
		{ id = 1, action = { type = "action", value = 134, conditions = "[overridebar][canexitvehicle]", exclusive = true }, condition = "[overridebar][canexitvehicle]" },
		{ id = 2, action = { type = "action", value = 122, conditions = "[possessbar][bonusbar:5]", exclusive = true }, condition = "[possessbar][bonusbar:5]" },
		{ id = 3, action = { type = "spell", value = 106839, conditions = "", exclusive = false }, condition = "" },
	},
}

local macroText, slotCond, liveIcon = Wise:FilterMacroTextForCharacter(compiledAction, graph)
print("Generated MacroText:\n" .. macroText)

assert(macroText:find("/click %[[^%]]*canexitvehicle[^%]]*%] OverrideActionBarButton2"), "Override line missing")
assert(macroText:find("/cast %[.*nocanexitvehicle.*%] Skull Bash"), "Skull bash must be gated on nocanexitvehicle, got: " .. macroText)
print("  TEST 3 PASSED!")

-- =========================================================================
-- TEST 4: ResolveMacroData on War Turtle (Slot 1 active, Slot 2 empty)
-- =========================================================================
print("Running TEST 4: ResolveMacroData on War Turtle...")

-- Slot 1 (181 on vehicle page 16) has Turtle Strike
-- Slot 2 (182 on vehicle page 16) is EMPTY (nil)
-- Base slot 1 (1) has Wrath (222333)
actionTextures[181] = 132145 -- Turtle Strike icon
actionTextures[182] = nil    -- Empty slot
actionTextures[1] = 222333   -- Wrath (base ActionButton1)
actionTextures[2] = 222444   -- Moonfire (base ActionButton2)

-- War Turtle active:
envState.canexitvehicle = true
envState.overridebar = false
envState.possessbar = false

-- Button 1 macro
local btn1Macro = "#showtooltip\n/click [overridebar][canexitvehicle] OverrideActionBarButton1\n/click [possessbar][bonusbar:5] ActionButton1\n/cast [nooverridebar,nocanexitvehicle] Tranquility"
local t1, v1, i1 = Wise:ResolveMacroData(btn1Macro)
assert(t1 == "action" and v1 == 133 and i1 == 132145, "Button 1 must resolve Turtle Strike, got: " .. tostring(t1) .. ", " .. tostring(v1) .. ", " .. tostring(i1))

-- Button 2 macro
local btn2Macro = "#showtooltip\n/click [overridebar][canexitvehicle] OverrideActionBarButton2\n/click [possessbar][bonusbar:5] ActionButton2\n/cast [nooverridebar,nocanexitvehicle] Skull Bash"
local t2, v2, i2 = Wise:ResolveMacroData(btn2Macro)
assert(t2 == nil and v2 == nil and i2 == nil, "Button 2 must resolve to nil (empty slot, NEVER Wrath/Moonfire), got: " .. tostring(t2) .. ", " .. tostring(v2) .. ", " .. tostring(i2))

-- Dismount War Turtle (normal world):
envState.canexitvehicle = false

local t1_off, v1_off, i1_off = Wise:ResolveMacroData(btn1Macro)
assert(t1_off == "spell" and v1_off == 740 and i1_off == 136107, "Button 1 off vehicle must resolve Tranquility, got: " .. tostring(t1_off))

local t2_off, v2_off, i2_off = Wise:ResolveMacroData(btn2Macro)
assert(t2_off == "spell" and v2_off == 106839 and i2_off == 236302, "Button 2 off vehicle must resolve Skull Bash, got: " .. tostring(t2_off))

print("  TEST 4 PASSED!")

-- =========================================================================
-- TEST 5: Possess vehicle (possessbar + bonusbar:5 + canexitvehicle)
-- =========================================================================
print("Running TEST 5: Possess vehicle...")
envState.possessbar = true
envState["bonusbar:5"] = true
envState.canexitvehicle = true
envState.overridebar = false

actionTextures[181] = 999111 -- Possess vehicle spell 1
local t5, v5, i5 = Wise:ResolveMacroData(btn1Macro)
assert(t5 == "action" and v5 == 133 and i5 == 999111, "Possess vehicle must resolve spell 1, got: " .. tostring(t5) .. ", " .. tostring(v5) .. ", " .. tostring(i5))

local t5_2, v5_2, i5_2 = Wise:ResolveMacroData(btn2Macro)
assert(t5_2 == nil, "Possess vehicle slot 2 must be nil (empty), got: " .. tostring(t5_2))
print("  TEST 5 PASSED!")

-- =========================================================================
-- TEST 6: Skinned vehicle (overridebar + canexitvehicle)
-- =========================================================================
print("Running TEST 6: Skinned vehicle...")
envState.possessbar = false
envState["bonusbar:5"] = false
envState.canexitvehicle = true
envState.overridebar = true

actionTextures[181] = 888222 -- Skinned vehicle spell 1
local t6, v6, i6 = Wise:ResolveMacroData(btn1Macro)
assert(t6 == "action" and v6 == 133 and i6 == 888222, "Skinned vehicle must resolve spell 1, got: " .. tostring(t6) .. ", " .. tostring(v6) .. ", " .. tostring(i6))
print("  TEST 6 PASSED!")

-- =========================================================================
-- TEST 7: Slots 7 and 8 button indices (Must NOT duplicate button 1)
-- =========================================================================
print("Running TEST 7: Slots 7 and 8 button indices...")
local s7Type, s7Attr, s7Val = Wise:GetSecureAttributes({ type = "action", value = 139, conditions = "[overridebar][canexitvehicle]" }, "ActionBar", 7)
assert(s7Val:find("OverrideActionBarButton7"), "Slot 7 must click OverrideActionBarButton7, got: " .. tostring(s7Val))

local s8Type, s8Attr, s8Val = Wise:GetSecureAttributes({ type = "action", value = 140, conditions = "[overridebar][canexitvehicle]" }, "ActionBar", 8)
assert(s8Val:find("OverrideActionBarButton8"), "Slot 8 must click OverrideActionBarButton8, got: " .. tostring(s8Val))
print("  TEST 7 PASSED!")

-- =========================================================================
-- TEST 8: Empty vehicle slots resolve to nil (no question marks)
-- =========================================================================
print("Running TEST 8: Empty vehicle slots have no question marks...")
local btn5Macro = "#showtooltip\n/click [overridebar][canexitvehicle] OverrideActionBarButton5\n/click [possessbar][bonusbar:5] ActionButton5"
local t5, v5, i5 = Wise:ResolveMacroData(btn5Macro)
assert(i5 == nil, "Slot 5 icon must be nil (hidden), got: " .. tostring(i5))

local btn7Macro = "#showtooltip\n/click [overridebar][canexitvehicle] OverrideActionBarButton7\n/click [possessbar][bonusbar:5] ActionButton7"
local t7, v7, i7 = Wise:ResolveMacroData(btn7Macro)
assert(i7 == nil, "Slot 7 icon must be nil (hidden), got: " .. tostring(i7))
print("  TEST 8 PASSED!")

-- =========================================================================
-- TEST 9: Slots 7 and 8 on vehicle with class fallbacks (Must NOT fall through to class spells)
-- =========================================================================
print("Running TEST 9: Slots 7 and 8 on vehicle with class fallbacks...")
-- Frame count is 6 (so 7 and 8 are > 6)
Wise.GetOverrideBarButtonCount = function() return 6 end

envState.canexitvehicle = true
envState.overridebar = false
envState.possessbar = false

local slot7FullMacro = "#showtooltip\n/click [overridebar][canexitvehicle] OverrideActionBarButton7\n/click [canexitvehicle] OverrideActionBarButton7\n/click [possessbar][bonusbar:5] ActionButton7\n/cast [nooverridebar,nocanexitvehicle,nopossessbar,nobonusbar:5] Switch Flight Style"

local t9_7, v9_7, i9_7 = Wise:ResolveMacroData(slot7FullMacro)
assert(t9_7 == nil and v9_7 == nil and i9_7 == nil, "Slot 7 on vehicle must be nil/empty, but got: " .. tostring(t9_7) .. ", " .. tostring(v9_7))

local slot8FullMacro = "#showtooltip\n/click [overridebar][canexitvehicle] OverrideActionBarButton8\n/click [canexitvehicle] OverrideActionBarButton8\n/click [possessbar][bonusbar:5] ActionButton8\n/cast [nooverridebar,nocanexitvehicle,nopossessbar,nobonusbar:5] Whirling Surge"

local t9_8, v9_8, i9_8 = Wise:ResolveMacroData(slot8FullMacro)
assert(t9_8 == nil and v9_8 == nil and i9_8 == nil, "Slot 8 on vehicle must be nil/empty, but got: " .. tostring(t9_8) .. ", " .. tostring(v9_8))

-- Dismount:
envState.canexitvehicle = false
local t9_7_off, v9_7_off, i9_7_off = Wise:ResolveMacroData(slot7FullMacro)
assert(t9_7_off == "spell" and v9_7_off == 460002, "Slot 7 dismounted must resolve Switch Flight Style, got: " .. tostring(t9_7_off))

print("  TEST 9 PASSED!")

print("\nALL UNIT TESTS PASSED SUCCESSFULLY!")
