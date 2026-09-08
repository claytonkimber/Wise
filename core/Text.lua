-- Text.lua: Unified Text Layer Module
-- Provides 9-position text anchoring for keybinds, charges, and custom text on buttons.
local _, Wise = ...

-- Valid anchor positions (3x3 grid)
Wise.TEXT_POSITIONS = {
	"TOPLEFT",
	"TOP",
	"TOPRIGHT",
	"LEFT",
	"CENTER",
	"RIGHT",
	"BOTTOMLEFT",
	"BOTTOM",
	"BOTTOMRIGHT",
}

-- Offset table: {anchor, offsetX, offsetY, justifyH}
local POSITION_MAP = {
	TOPLEFT = { "TOPLEFT", 2, -2, "LEFT" },
	TOP = { "TOP", 0, -2, "CENTER" },
	TOPRIGHT = { "TOPRIGHT", -2, -2, "RIGHT" },
	LEFT = { "LEFT", 2, 0, "LEFT" },
	CENTER = { "CENTER", 0, 0, "CENTER" },
	RIGHT = { "RIGHT", -2, 0, "RIGHT" },
	BOTTOMLEFT = { "BOTTOMLEFT", 2, 2, "LEFT" },
	BOTTOM = { "BOTTOM", 0, 2, "CENTER" },
	BOTTOMRIGHT = { "BOTTOMRIGHT", -2, 2, "RIGHT" },
}

--- Position a FontString at one of the 9 anchor points on its parent.
--- Forces an immediate visual refresh so changes are visible without movement.
---@param fs FontString
---@param position string  One of the TEXT_POSITIONS keys
---@param extraX? number   Additional X offset (default 0)
---@param extraY? number   Additional Y offset (default 0)
function Wise:Text_ApplyPosition(fs, position, extraX, extraY)
	local info = POSITION_MAP[position]
	if not info then
		info = POSITION_MAP["BOTTOMRIGHT"]
	end -- safe fallback
	local anchor, ox, oy, justify = info[1], info[2], info[3], info[4]
	local wasShown = fs:IsShown()
	fs:Hide()
	fs:ClearAllPoints()
	fs:SetPoint(anchor, fs:GetParent(), anchor, (ox + (extraX or 0)), (oy + (extraY or 0)))
	fs:SetJustifyH(justify)
	if wasShown then
		fs:Show()
	end
end

--- Position and show a gamepad-glyph texture at the same anchor points used
--- for keybind text (see POSITION_MAP), sized off the keybind font size.
---@param tex Texture
---@param position string
---@param icon string  Atlas name or texture path (see Wise:GetGamepadIcon)
---@param isAtlas boolean
---@param kbSize number
function Wise:Text_ApplyGamepadIcon(tex, position, icon, isAtlas, kbSize)
	local info = POSITION_MAP[position] or POSITION_MAP["BOTTOMRIGHT"]
	local anchor, ox, oy = info[1], info[2], info[3]
	local size = (kbSize or 12) + 4
	tex:ClearAllPoints()
	tex:SetSize(size, size)
	tex:SetPoint(anchor, tex:GetParent(), anchor, ox, oy)
	if isAtlas then
		tex:SetAtlas(icon)
	else
		tex:SetTexture(icon)
	end
	tex:Show()
end

--- Create the three Text FontStrings on a button (count, keybind, customText).
--- Call once during button creation. Safe to call again (skips if already set up).
---@param btn Button
function Wise:Text_CreateFontStrings(btn)
	if btn._textReady then
		return
	end

	-- Create an overlay frame above the cooldown so text is never hidden by the swipe
	if not btn._textOverlay then
		btn._textOverlay = CreateFrame("Frame", nil, btn)
		btn._textOverlay:SetAllPoints()
		btn._textOverlay:SetFrameLevel((btn.cooldown and btn.cooldown:GetFrameLevel() or btn:GetFrameLevel()) + 2)
	end
	local overlay = btn._textOverlay

	-- Charges / Item Count
	if not btn.count then
		btn.count = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	end

	-- Keybind (slot-level)
	if not btn.keybind then
		btn.keybind = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		btn.keybind:SetShadowOffset(1, -1)
	end
	-- Gamepad glyph shown instead of btn.keybind's text when the slot's
	-- binding is a PAD* key and ConsolePort can supply a device-accurate icon.
	if not btn.keybindGamepadIcon then
		btn.keybindGamepadIcon = overlay:CreateTexture(nil, "OVERLAY")
	end

	-- Interface Keybind (group-level toggle binding)
	if not btn.interfaceKeybind then
		btn.interfaceKeybind = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		btn.interfaceKeybind:SetShadowOffset(1, -1)
	end
	if not btn.interfaceKeybindGamepadIcon then
		btn.interfaceKeybindGamepadIcon = overlay:CreateTexture(nil, "OVERLAY")
	end

	-- Countdown (new)
	if not btn.countdown then
		btn.countdown = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		-- Default to center, but will be updated by Text_UpdateCountdown
	end

	-- Custom Text (stub – not populated yet, but the FontString is ready)
	if not btn.customText then
		btn.customText = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	end

	-- Buff stack counter (separate from charges so both can coexist)
	if not btn.buffStack then
		btn.buffStack = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		btn.buffStack:SetShadowOffset(1, -1)
	end

	btn._textReady = true
end

--- Apply charge/count text position, font, and value on a button.
--- Reads group settings for position and size.
---@param btn Button
---@param groupName string
---@param count number         The numeric count to display
---@param isChargeSpell boolean Whether this spell is a charge-based spell
function Wise:Text_UpdateCharges(btn, groupName, count, isChargeSpell)
	local _, _, fontPath, _, _, _, chargeTextSize, chargeTextPosition, _, _, _, _, _, _, showChargeText =
		Wise:GetGroupDisplaySettings(groupName)

	if not showChargeText then
		btn.count:Hide()
		return
	end

	local pos = chargeTextPosition or "TOP"
	Wise:Text_ApplyPosition(btn.count, pos)
	btn.count:SetFont(fontPath, chargeTextSize, "OUTLINE")

	if isChargeSpell then
		btn.count:SetText(count)
		btn.count:Show()
	elseif count > 1 then
		btn.count:SetText(count)
		btn.count:Show()
	else
		btn.count:Hide()
	end
end

--- Apply keybind text position, font, and value on a button.
--- Reads group settings for position and size.
---@param btn Button
---@param groupName string
---@param showKeybinds boolean
---@param kbPos string|nil pre-resolved keybind position (optional)
---@param kbSize number|nil pre-resolved keybind text size (optional)
function Wise:Text_UpdateKeybind(btn, groupName, showKeybinds, kbPos, kbSize)
	if not btn.keybind then
		return
	end

	if not showKeybinds then
		btn.keybind:Hide()
		if btn.keybindGamepadIcon then
			btn.keybindGamepadIcon:Hide()
		end
		return
	end

	-- Callers looping over many buttons in one group pass the already-resolved
	-- settings; only pay for the lookup when they didn't.
	if kbPos == nil or kbSize == nil then
		local _, _, _, _, p, sz = Wise:GetGroupDisplaySettings(groupName)
		kbPos = kbPos or p
		kbSize = kbSize or sz
	end
	local text, rawKey = Wise.GetKeybind and Wise:GetKeybind(groupName, btn.slot) or nil

	local pos = kbPos or "BOTTOM"
	local icon, isAtlas = Wise.GetGamepadIcon and Wise:GetGamepadIcon(rawKey) or nil

	if icon and btn.keybindGamepadIcon then
		btn.keybind:Hide()
		Wise:Text_ApplyGamepadIcon(btn.keybindGamepadIcon, pos, icon, isAtlas, kbSize)
	elseif text then
		if btn.keybindGamepadIcon then
			btn.keybindGamepadIcon:Hide()
		end
		btn.keybind:SetText(text)
		local fontPath = WiseDB.settings.font or "Fonts\\FRIZQT__.TTF"
		btn.keybind:SetFont(fontPath, kbSize, "OUTLINE")
		Wise:Text_ApplyPosition(btn.keybind, pos)
		btn.keybind:Show()
	else
		btn.keybind:Hide()
		if btn.keybindGamepadIcon then
			btn.keybindGamepadIcon:Hide()
		end
	end
end

--- Apply interface-level keybind text on a button.
--- Shows the group's toggle binding (group.binding) on each button.
---@param btn Button
---@param groupName string
---@param showInterfaceKeybind boolean
function Wise:Text_UpdateInterfaceKeybind(btn, groupName, showInterfaceKeybind)
	if not btn.interfaceKeybind then
		return
	end

	if not showInterfaceKeybind then
		btn.interfaceKeybind:Hide()
		if btn.interfaceKeybindGamepadIcon then
			btn.interfaceKeybindGamepadIcon:Hide()
		end
		return
	end

	local _, _, _, _, kbPos, kbSize = Wise:GetGroupDisplaySettings(groupName)
	local text, rawKey = Wise.GetInterfaceKeybind and Wise:GetInterfaceKeybind(groupName) or nil

	local pos = kbPos or "BOTTOM"
	local icon, isAtlas = Wise.GetGamepadIcon and Wise:GetGamepadIcon(rawKey) or nil

	if icon and btn.interfaceKeybindGamepadIcon then
		btn.interfaceKeybind:Hide()
		Wise:Text_ApplyGamepadIcon(btn.interfaceKeybindGamepadIcon, pos, icon, isAtlas, kbSize)
	elseif text then
		if btn.interfaceKeybindGamepadIcon then
			btn.interfaceKeybindGamepadIcon:Hide()
		end
		btn.interfaceKeybind:SetText(text)
		local fontPath = WiseDB.settings.font or "Fonts\\FRIZQT__.TTF"
		btn.interfaceKeybind:SetFont(fontPath, kbSize, "OUTLINE")
		Wise:Text_ApplyPosition(btn.interfaceKeybind, pos)
		btn.interfaceKeybind:Show()
	else
		btn.interfaceKeybind:Hide()
		if btn.interfaceKeybindGamepadIcon then
			btn.interfaceKeybindGamepadIcon:Hide()
		end
	end
end

--- Set custom text on a button (stub for future use).
---@param btn Button
---@param text string|nil
---@param position? string  Defaults to "CENTER"
function Wise:Text_UpdateCustomText(btn, text, position)
	if not btn.customText then
		return
	end

	if text and text ~= "" then
		local fontPath = WiseDB.settings.font or "Fonts\\FRIZQT__.TTF"
		local textSize = (WiseDB.settings and WiseDB.settings.textSize) or 12
		btn.customText:SetFont(fontPath, textSize, "OUTLINE")
		Wise:Text_ApplyPosition(btn.customText, position or "CENTER")
		btn.customText:SetText(text)
		btn.customText:Show()
	else
		btn.customText:Hide()
	end
end

--- Apply buff stack counter position, font, and value on a button.
--- Renders into btn.buffStack, which is independent from btn.count (charges),
--- so stacks and charges can be shown in different corners simultaneously.
---@param btn Button
---@param groupName string
---@param stacks number|nil  Active buff stack count (nil/0/1 hides)
function Wise:Text_UpdateBuffStack(btn, groupName, stacks)
	if not btn.buffStack then
		local parent = btn._textOverlay or btn
		btn.buffStack = parent:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		btn.buffStack:SetShadowOffset(1, -1)
	end

	local _, _, fontPath, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, showBuffStacks, buffStackPosition, buffStackTextSize =
		Wise:GetGroupDisplaySettings(groupName)

	if not showBuffStacks or not stacks or stacks <= 1 then
		btn.buffStack:Hide()
		return
	end

	local pos = buffStackPosition or "TOPRIGHT"
	Wise:Text_ApplyPosition(btn.buffStack, pos)
	btn.buffStack:SetFont(fontPath, buffStackTextSize or 12, "OUTLINE")
	btn.buffStack:SetText(stacks)
	btn.buffStack:Show()
end

--- Apply countdown text position, font, and value on a button.
--- Reads group settings for position and size.
---@param btn Button
---@param groupName string
---@param text string
function Wise:Text_UpdateCountdown(btn, groupName, text)
	if not btn.countdown then
		-- Create it if missing (should be created in CreateFontStrings, but safe fallback)
		local parent = btn._textOverlay or btn
		btn.countdown = parent:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	end

	local _, _, fontPath, _, _, _, _, _, countdownTextSize, countdownTextPosition, _, _, _, _, _, showCountdownText =
		Wise:GetGroupDisplaySettings(groupName)

	if not showCountdownText then
		btn.countdown:Hide()
		return
	end

	local pos = countdownTextPosition or "CENTER"
	Wise:Text_ApplyPosition(btn.countdown, pos)
	btn.countdown:SetFont(fontPath, countdownTextSize, "OUTLINE")

	if text and text ~= "" then
		btn.countdown:SetText(text)
		btn.countdown:Show()
	else
		btn.countdown:Hide()
	end
end
