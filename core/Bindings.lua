-- Bindings.lua: Centralized keybind retrieval for Wise
local addonName, Wise = ...

-- Display strings for Bindings.xml actions. Blizzard's Key Bindings UI (and
-- ConsolePort_Config, which reads the same globals) look these up by name
-- when rendering the "WISE" binding category, including its Gamepad tab.
BINDING_HEADER_WISE = "Wise"
BINDING_NAME_WISE_OPEN_OPTIONS = "Toggle Wise Options"

-- True once ConsolePort (the gamepad-navigation addon) is detected loaded.
-- Set on ADDON_LOADED/PLAYER_LOGIN in Wise.lua. Kept here so any module can
-- gate ConsolePort-specific calls (e.g. icon glyphs) without re-checking
-- IsAddOnLoaded itself. Frame registration (below) doesn't need this check —
-- ConsolePort:AddInterfaceCursorFrame is itself safe to call unconditionally.
Wise.HasConsolePort = false

function Wise:DetectConsolePort()
	Wise.HasConsolePort = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("ConsolePort"))
		or (IsAddOnLoaded and IsAddOnLoaded("ConsolePort"))
		or false
	return Wise.HasConsolePort
end

-- Registers a frame with ConsolePort's virtual-cursor interface stack (its
-- public API, ConsolePort/API.lua:143) so the gamepad cursor can scan into
-- it and land on its buttons/widgets. Deferred internally via
-- EventUtil.ContinueOnAddOnLoaded, so this is safe to call at any time,
-- including before ConsolePort_Cursor (or ConsolePort itself) has loaded,
-- and is a no-op if ConsolePort was never installed at all.
function Wise:RegisterConsolePortFrame(f)
	if not f or not _G.ConsolePort or not _G.ConsolePort.AddInterfaceCursorFrame then
		return
	end
	_G.ConsolePort:AddInterfaceCursorFrame(f)
end

-- Wires the standard "click to capture a binding" flow onto a button widget:
-- keyboard keys, mouse buttons, optionally mousewheel, and gamepad buttons.
-- Centralizes what was previously duplicated across several call sites in
-- modules/Properties.lua so gamepad capture only needed adding once.
--
-- OnGamePadButtonDown wiring is wrapped in pcall: it's a normal Blizzard
-- frame script (relied on by ConsolePort itself), but is guarded defensively
-- since capture must still work via keyboard/mouse on any client/environment
-- that doesn't support it.
--
-- opts:
--   getCurrentText()      -> string shown when capture is cancelled
--   allowMouseWheel       -> bool, wire OnMouseWheel as MOUSEWHEELUP/DOWN
--   validateKey(fullKey)  -> optional function(fullKey) -> isValid, err
--   isSlotBinding, group, slotIdx -> forwarded to Wise:CheckBindingConflict
--   onBound(fullKey)      -> called once a non-conflicting key is accepted
--   onInvalid(err)        -> called when validateKey rejects the input
function Wise:StartKeybindCapture(widget, opts)
	widget:EnableKeyboard(true)
	widget:EnableGamePadButton(true)
	if opts.allowMouseWheel then
		widget:EnableMouseWheel(true)
	end

	local function StopCapture()
		widget:EnableKeyboard(false)
		widget:EnableGamePadButton(false)
		if opts.allowMouseWheel then
			widget:EnableMouseWheel(false)
		end
		widget:SetScript("OnKeyDown", nil)
		pcall(widget.SetScript, widget, "OnGamePadButtonDown", nil)
		widget:SetScript("OnMouseWheel", nil)
		widget:SetScript("OnMouseDown", nil)
	end

	local function FinishCapture(key)
		if not key then
			return
		end

		if key == "ESCAPE" then
			StopCapture()
			if opts.onCancelled then
				opts.onCancelled()
			else
				widget:SetText(opts.getCurrentText() or "None")
			end
			return
		end

		if key:find("SHIFT") or key:find("CTRL") or key:find("ALT") then
			return
		end

		local mods = ""
		if IsAltKeyDown() then
			mods = mods .. "ALT-"
		end
		if IsControlKeyDown() then
			mods = mods .. "CTRL-"
		end
		if IsShiftKeyDown() then
			mods = mods .. "SHIFT-"
		end

		local fullKey = mods .. key

		if opts.validateKey then
			local isValid, err = opts.validateKey(fullKey)
			if not isValid then
				StopCapture()
				if opts.onCancelled then
					opts.onCancelled()
				else
					widget:SetText(opts.getCurrentText() or "None")
				end
				if opts.onInvalid then
					opts.onInvalid(err)
				end
				return
			end
		end

		StopCapture()

		if Wise:CheckBindingConflict(fullKey, opts.group, opts.slotIdx, opts.isSlotBinding, widget) then
			return
		end

		opts.onBound(fullKey)
	end

	widget:SetScript("OnKeyDown", function(_, key)
		FinishCapture(key)
	end)

	pcall(widget.SetScript, widget, "OnGamePadButtonDown", function(_, button)
		FinishCapture(button)
	end)

	if opts.allowMouseWheel then
		widget:SetScript("OnMouseWheel", function(_, delta)
			FinishCapture(delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN")
		end)
	end

	widget:SetScript("OnMouseDown", function(_, button)
		if button == "LeftButton" or button == "RightButton" then
			return
		end
		local key = button
		if button == "MiddleButton" then
			key = "BUTTON3"
		elseif button == "Button4" then
			key = "BUTTON4"
		elseif button == "Button5" then
			key = "BUTTON5"
		end
		FinishCapture(key)
	end)
end

-- Returns display text and raw key for a given group slot.
-- Hierarchy: 1) Slot-specific binding, 2) WoW keybinding fallback
function Wise:GetKeybind(groupName, slotIndex)
	if not groupName then
		return nil
	end
	local group = WiseDB.groups[groupName]
	if not group then
		return nil
	end

	-- 1. Slot-specific binding
	if group.actions and group.actions[slotIndex] then
		local slotKey = group.actions[slotIndex].keybind
		if slotKey and slotKey ~= "" then
			return Wise:FormatKeybindText(slotKey), slotKey
		end
	end

	-- 2. Check for nested interface bindings
	if group.actions and group.actions[slotIndex] then
		for _, state in ipairs(group.actions[slotIndex]) do
			if state.type == "interface" then
				local targetGroupName = state.value
				local targetGroup = WiseDB.groups[targetGroupName]
				if targetGroup then
					-- 2a. Explicit Interface Binding
					if targetGroup.binding and targetGroup.binding ~= "" then
						return Wise:FormatKeybindText(targetGroup.binding), targetGroup.binding
					end

					-- 2b. Check for ANY slot binding
					if targetGroup.actions then
						for _, actionList in pairs(targetGroup.actions) do
							if actionList.keybind and actionList.keybind ~= "" then
								return "**", "**" -- Double asterisk indicates "slots bound below"
							end
						end
					end
				end
			end
		end
	end

	-- 3. WoW keybinding fallback (check if button has a WoW binding)
	local f = Wise.frames[groupName]
	if f and f.buttons then
		for _, btn in ipairs(f.buttons) do
			if btn.slot == slotIndex and btn:GetName() then
				local key = GetBindingKey("CLICK " .. btn:GetName() .. ":LeftButton")
				if key then
					return Wise:FormatKeybindText(key), key
				end
			end
		end
	end

	return nil
end

-- Returns the group-level (interface toggle) binding text for display on buttons.
-- This is the keybind that shows/hides the entire interface.
function Wise:GetInterfaceKeybind(groupName)
	if not groupName then
		return nil
	end
	local group = WiseDB.groups[groupName]
	if not group then
		return nil
	end

	if group.binding and group.binding ~= "" then
		return Wise:FormatKeybindText(group.binding), group.binding
	end

	return nil
end

-- Format raw keybind text for display (max 3 chars)
-- Compound modifier+mouse patterns handled first to stay within 3 chars
function Wise:FormatKeybindText(text)
	if not text then
		return nil
	end
	-- 1. Compound: modifier + mousewheel
	text = text:gsub("ALT%-MOUSEWHEELUP", "AMWU")
	text = text:gsub("ALT%-MOUSEWHEELDOWN", "AMWD")
	text = text:gsub("CTRL%-MOUSEWHEELUP", "CMWU")
	text = text:gsub("CTRL%-MOUSEWHEELDOWN", "CMWD")
	text = text:gsub("SHIFT%-MOUSEWHEELUP", "SMWU")
	text = text:gsub("SHIFT%-MOUSEWHEELDOWN", "SMWD")
	-- 2. Compound: modifier + mouse button (e.g. SHIFT-BUTTON3 -> S3)
	text = text:gsub("ALT%-BUTTON(%d)", "A%1")
	text = text:gsub("CTRL%-BUTTON(%d)", "C%1")
	text = text:gsub("SHIFT%-BUTTON(%d)", "S%1")
	text = text:gsub("ALT%-MIDDLEMOUSE", "A3")
	text = text:gsub("CTRL%-MIDDLEMOUSE", "C3")
	text = text:gsub("SHIFT%-MIDDLEMOUSE", "S3")
	-- 3. Simple replacements
	text = text:gsub("ALT%-", "A-")
	text = text:gsub("CTRL%-", "C-")
	text = text:gsub("SHIFT%-", "S-")
	text = text:gsub("SPACE", "Spc")
	text = text:gsub("MOUSEWHEELUP", "MWU")
	text = text:gsub("MOUSEWHEELDOWN", "MWD")
	text = text:gsub("MIDDLEMOUSE", "M3")
	text = text:gsub("BUTTON3", "M3")
	text = text:gsub("BUTTON4", "M4")
	text = text:gsub("BUTTON5", "M5")
	text = text:gsub("MINUS", "-")
	text = text:gsub("EQUALS", "=")
	text = text:gsub("NUMPADMINUS", "N-")
	text = text:gsub("NUMPADEQUALS", "N=")
	text = text:gsub("NUMPADPLUS", "N+")
	text = text:gsub("NUMPADMULTIPLY", "N*")
	text = text:gsub("NUMPADDIVIDE", "N/")
	text = text:gsub("NUMPADDECIMAL", "N.")
	text = text:gsub("NUMPAD(%d)", "N%1")
	text = text:gsub("PAGEUP", "PU")
	text = text:gsub("PAGEDOWN", "PD")
	text = text:gsub("INSERT", "Ins")
	text = text:gsub("DELETE", "Del")
	text = text:gsub("HOME", "Hm")
	text = text:gsub("END", "End")
	text = text:gsub("BACKSPACE", "BS")
	text = text:gsub("CAPSLOCK", "Caps")
	text = text:gsub("NUMLOCK", "Num")
	-- 4. Gamepad (PAD*) tokens — plain-text fallback for when ConsolePort
	-- isn't present to render a device-accurate glyph instead (see
	-- Wise:GetGamepadIcon). Face buttons keep their numeric PAD1-4 form;
	-- named buttons get a short label.
	text = text:gsub("PADDUP", "D+U")
	text = text:gsub("PADDDOWN", "D+D")
	text = text:gsub("PADDLEFT", "D+L")
	text = text:gsub("PADDRIGHT", "D+R")
	text = text:gsub("PADLSHOULDER", "LB")
	text = text:gsub("PADRSHOULDER", "RB")
	text = text:gsub("PADLTRIGGER", "LT")
	text = text:gsub("PADRTRIGGER", "RT")
	text = text:gsub("PADLSTICK", "L3")
	text = text:gsub("PADRSTICK", "R3")
	text = text:gsub("PADFORWARD", "Bk")
	text = text:gsub("PADBACK", "Sel")
	text = text:gsub("PADSYSTEM", "Sys")
	text = text:gsub("PADSOCIAL", "Soc")
	text = text:gsub("PAD(%d)", "Pad%1")
	return text
end

-- Returns a texture/atlas for a gamepad keybind via ConsolePort's device-
-- accurate glyph set, or nil if ConsolePort isn't loaded or the key isn't a
-- PAD* binding. Callers should fall back to FormatKeybindText's plain-text
-- abbreviation when this returns nil.
function Wise:GetGamepadIcon(key)
	if not Wise.HasConsolePort or not key or not key:find("^PAD") then
		return nil
	end
	local ok, ConsolePort = pcall(function()
		return _G.ConsolePort
	end)
	if not ok or not ConsolePort or not ConsolePort.GetData then
		return nil
	end
	local db = ConsolePort:GetData()
	local device = db and db.Gamepad and db.Gamepad.GetActiveDevice and db.Gamepad:GetActiveDevice()
	if not device or not device.GetIconForButton then
		return nil
	end
	local icon, isAtlas = device:GetIconForButton(key)
	return icon, isAtlas
end

function Wise:FindKeybindOwner(key)
	if not key or key == "" then
		return nil, nil
	end
	for groupName, group in pairs(WiseDB.groups) do
		if group.binding == key then
			return groupName, nil
		end
		if group.actions then
			for slotIdx, actionList in pairs(group.actions) do
				if actionList.keybind == key then
					return groupName, slotIdx
				end
			end
		end
	end

	-- Check WoW global bindings
	local existingAction = GetBindingAction(key)
	if existingAction and existingAction ~= "" then
		return existingAction, "SYSTEM"
	end

	return nil, nil
end

function Wise:ClearKeybind(groupName, slotIdx)
	local group = WiseDB.groups[groupName]
	if not group then
		return
	end
	if slotIdx then
		if group.actions and group.actions[slotIdx] then
			group.actions[slotIdx].keybind = nil
		end
	else
		group.binding = nil
	end
end

-- Returns binding text specifically for the interface list (sidebar).
-- Returns explicit interface binding if exists, otherwise "**" if any slot is bound.
function Wise:GetInterfaceListBindingText(groupName)
	if not groupName then
		return nil
	end
	local group = WiseDB.groups[groupName]
	if not group then
		return nil
	end

	-- 1. Explicit Interface Binding
	if group.binding and group.binding ~= "" then
		return Wise:FormatKeybindText(group.binding)
	end

	-- 2. Check for ANY slot binding
	if group.actions then
		for _, actionList in pairs(group.actions) do
			if actionList.keybind and actionList.keybind ~= "" then
				return "**" -- Double asterisk indicates "slots bound below"
			end
		end
	end

	return nil
end
