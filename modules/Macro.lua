local addonName, Wise = ...

-- Macro.lua: Handles Custom Macro logic and UI

function Wise:GetMacroText(action)
	return action.macroText or ""
end

-- ============================================================================
-- Slash command validation
-- ============================================================================
--
-- Catches typos (/taget, /casst) that would otherwise compile into a macro that
-- silently does nothing when pressed.
--
-- WHY IT IS NOT A LIST: /cast, /use, /target and friends live in SecureCmdList,
-- a C-side table that enumerates as EMPTY (`for k in pairs(SecureCmdList)` yields
-- 0 keys on 12.1), so the valid set cannot be walked. IsSecureCmd(cmd) probes it
-- by name instead, which is what OPie's Rewire does for the same reason.
-- Addon commands come from SlashCmdList, whose aliases are NOT table keys but
-- numbered globals (SLASH_TARGET2 == "/tar"), so those need expanding.
--
-- WHY IT IS LAZY: addons register their slash commands while loading, so a table
-- built at PLAYER_LOGIN would miss them and false-warn on valid commands. This
-- builds on first use — the macro editor, which is only reachable from the
-- options panel, long after every addon has loaded.
local aliasCache, aliasCacheBuilt = {}, false

local function BuildAliasCache()
	aliasCache, aliasCacheBuilt = {}, true
	if type(SlashCmdList) ~= "table" then
		return
	end
	for k in pairs(SlashCmdList) do
		for n = 1, 20 do
			local v = _G["SLASH_" .. k .. n]
			if type(v) ~= "string" then
				break
			end
			aliasCache[v:lower()] = true
		end
	end
end

-- Rebuilt on demand: an addon loaded on demand (LoadOnDemand) can add commands
-- after the cache was built, so the options panel drops it to stay accurate.
function Wise:InvalidateSlashCommandCache()
	aliasCacheBuilt = false
end

-- True if `cmd` (leading slash included) is a command the client will act on.
function Wise:IsKnownSlashCommand(cmd)
	if type(cmd) ~= "string" or cmd == "" then
		return false
	end
	cmd = cmd:lower()
	-- Secure/macro commands (/cast, /target, /use …) — probe, cannot enumerate.
	if IsSecureCmd and IsSecureCmd(cmd) then
		return true
	end
	if type(SlashCmdList) == "table" and SlashCmdList[cmd:sub(2):upper()] then
		return true
	end
	if not aliasCacheBuilt then
		BuildAliasCache()
	end
	return aliasCache[cmd] == true
end

-- Every unrecognized command in a macro body, in order, deduped.
-- Returns nil when everything is recognized (or nothing looks like a command),
-- so callers can treat "no news" as good news.
function Wise:FindUnknownSlashCommands(macroText)
	if type(macroText) ~= "string" then
		return nil
	end
	local unknown, seen
	for line in macroText:gmatch("[^\r\n]+") do
		local cmd = line:match("^%s*(/%a[%w]*)")
		if cmd then
			local lower = cmd:lower()
			seen = seen or {}
			if not seen[lower] and not Wise:IsKnownSlashCommand(cmd) then
				seen[lower] = true
				unknown = unknown or {}
				table.insert(unknown, cmd)
			end
		end
	end
	return unknown
end

function Wise:SetMacroText(action, text)
	action.macroText = text
	-- Auto-rename if currently default
	if not action.name or action.name == "Custom Macro" then
		local class = UnitClass("player")
		local spec = GetSpecialization()
		local specID = spec and GetSpecializationInfo(spec)
		local _, specName = specID and GetSpecializationInfoByID(specID)
		if class and specName then
			action.name = string.format("Macro - %s %s", class, specName)
		end
	end
end

function Wise:CreateMacroEditor(panel, action, y)
	-- 1. Macro Name Editor
	local nameLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	nameLabel:SetPoint("TOPLEFT", 10, y)
	nameLabel:SetText("Macro Name:")
	table.insert(panel.controls, nameLabel)

	y = y - 20
	local nameEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	nameEdit:SetSize(220, 20)
	nameEdit:SetPoint("TOPLEFT", 14, y)
	nameEdit:SetAutoFocus(false)
	nameEdit:SetText(action.name or "Custom Macro")
	nameEdit:SetCursorPosition(0)

	nameEdit:SetScript("OnTextChanged", function(self, isUserInput)
		if not isUserInput then
			return
		end
		local text = self:GetText()
		if text and text ~= "" then
			action.name = text
		else
			action.name = nil -- Revert to default
		end

		-- Targeted refresh to avoid focus loss in properties panel
		if Wise.OptionsFrame and Wise.OptionsFrame:IsShown() then
			Wise:RefreshGroupList()
			if Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.Content then
				Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
			end
		end
	end)

	nameEdit:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
	end)

	table.insert(panel.controls, nameEdit)
	y = y - 35

	-- 1.5 Icon Picker
	local iconLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	iconLabel:SetPoint("TOPLEFT", 10, y)
	iconLabel:SetText("Icon:")
	table.insert(panel.controls, iconLabel)

	local iconBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
	iconBtn:SetSize(32, 32)
	iconBtn:SetPoint("LEFT", iconLabel, "RIGHT", 10, 0)

	iconBtn.icon = iconBtn:CreateTexture(nil, "ARTWORK")
	iconBtn.icon:SetAllPoints()

	local function UpdateIconDisplay()
		local tex = action.icon
		if not tex then
			tex = Wise:GetActionIcon(action.type, action.value, action)
		end
		iconBtn.icon:SetTexture(tex)
	end
	UpdateIconDisplay()

	iconBtn:SetScript("OnClick", function()
		Wise:OpenIconPicker(function(type, value)
			-- The icon picker returns "icon" as type and the texture path/ID as value.
			-- A nil value means resetting to the default/dynamic icon.
			if type == "icon" then
				action.icon = value
				UpdateIconDisplay()
				Wise:UpdateGroupDisplay(Wise.selectedGroup)
				if Wise.UpdateOptionsUI then
					Wise:UpdateOptionsUI()
				end
			end
		end)
	end)
	iconBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
	table.insert(panel.controls, iconBtn)

	y = y - 40

	-- 2. Macro Body Editor
	local bodyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	bodyLabel:SetPoint("TOPLEFT", 10, y)
	bodyLabel:SetText("Macro Command:")
	table.insert(panel.controls, bodyLabel)

	y = y - 20

	local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	scrollFrame:SetSize(200, 150)
	scrollFrame:SetPoint("TOPLEFT", 10, y)

	local editBox = CreateFrame("EditBox", nil, scrollFrame)
	editBox:SetMultiLine(true)
	editBox:SetSize(180, 200)
	-- Replace editBox:SetFont(...) with this:
	editBox:SetFontObject("ChatFontNormal")
	editBox:SetTextColor(1, 1, 1, 1)
	-- Ensure the cursor and shadow don't interfere
	editBox:SetShadowOffset(1, -1)
	editBox:SetShadowColor(0, 0, 0, 0.5)
	editBox:Enable()
	editBox:SetAutoFocus(false)
	editBox:SetTextInsets(5, 5, 5, 5)

	-- Background for EditBox
	local bg = CreateFrame("Frame", nil, scrollFrame, "BackdropTemplate")
	bg:SetPoint("TOPLEFT", -5, 5)
	bg:SetPoint("BOTTOMRIGHT", 25, -5) -- Extend to cover scrollbar area
	bg:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	bg:SetBackdropColor(0.1, 0.1, 0.1, 1)
	bg:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

	scrollFrame:SetScrollChild(editBox)

	-- FORCE the editbox to a higher level so it's not behind the background
	editBox:SetFrameLevel(scrollFrame:GetFrameLevel() + 2)
	editBox:SetText(action.macroText or "")

	-- Character Count
	local charCount = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	charCount:SetPoint("TOPRIGHT", bg, "BOTTOMRIGHT", -5, -2)
	charCount:SetText("0/255")
	table.insert(panel.controls, charCount)

	-- Unknown-command notice. Sits under the body box and only takes space when
	-- there is something to say. This WARNS, it does not block: the macro still
	-- saves and still compiles. A command this check does not recognize is far
	-- more likely to be an addon command registered late than a real mistake,
	-- and silently discarding a macro is the failure mode this whole area of the
	-- code has been bitten by repeatedly.
	local cmdWarning = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	cmdWarning:SetPoint("TOPLEFT", bg, "BOTTOMLEFT", 5, -2)
	cmdWarning:SetPoint("RIGHT", bg, "RIGHT", -60, 0)
	cmdWarning:SetJustifyH("LEFT")
	cmdWarning:SetTextColor(1, 0.82, 0)
	cmdWarning:SetText("")
	table.insert(panel.controls, cmdWarning)

	local function UpdateCommandWarning(text)
		local unknown = Wise.FindUnknownSlashCommands and Wise:FindUnknownSlashCommands(text)
		if unknown and #unknown > 0 then
			cmdWarning:SetText(
				(#unknown == 1 and "Unrecognized command: " or "Unrecognized commands: ")
					.. table.concat(unknown, ", ")
			)
		else
			cmdWarning:SetText("")
		end
	end

	local function UpdateCharCount(text)
		local count = string.len(text or "")
		charCount:SetText(count .. "/255")
		if count > 255 then
			charCount:SetTextColor(1, 0, 0, 1) -- Red
		else
			charCount:SetTextColor(1, 1, 1, 1) -- White
		end
		UpdateCommandWarning(text)
	end

	-- Helper: Strip colors for saving
	function Wise:StripMacroColors(text)
		if not text then
			return ""
		end
		text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
		text = text:gsub("|r", "")
		return text
	end

	-- Helper: Resolve {{spell:ID}} and Highlight known spells
	function Wise:ResolveAndColorMacro(text)
		if not text then
			return ""
		end

		-- 1. Resolve {{spell:ID}} tags
		text = text:gsub("{{spell:(%d+)}}", function(idStr)
			local id = tonumber(idStr)
			local name = nil
			local valid = false

			if C_Spell.DoesSpellExist(id) then
				name = C_Spell.GetSpellName(id)
				valid = true
			elseif GetItemInfo(id) then
				name = GetItemInfo(id)
				valid = true
			end

			if valid and name then
				-- Valid: Blue
				return "|cff00ccff" .. name .. "|r"
			else
				-- Invalid: Red
				return "|cffff0000Unknown(" .. idStr .. ")|r"
			end
		end)

		-- 2. Highlight existing spell names in /cast commands?
		-- This is complex because we don't know for sure what is a spell name vs macro condition
		-- Simple approach: Look for lines starting with /cast or /use
		-- And try to verify the last token?
		-- Regex for basic match: (/cast%s+)(.*)
		-- We won't auto-color user typed text continuously as it interferes with typing (color codes inserted while typing = mess)
		-- We only do the {{spell:ID}} resolution which is a distinct replacement action.

		return text
	end

	editBox:SetScript("OnTextChanged", function(self, isUserInput)
		local rawText = self:GetText()

		-- Check for resolution triggers (only resolve tags, don't force color on everything constantly)
		if rawText:find("{{spell:%d+}}") then
			local resolved = Wise:ResolveAndColorMacro(rawText)
			if resolved ~= rawText then
				-- Update text and keep cursor?
				-- Since this usually happens on paste, cursor behavior is less critical
				self:SetText(resolved)
				rawText = resolved -- proceed with resolved text
			end
		end

		-- Clean text for storage
		local cleanText = Wise:StripMacroColors(rawText)

		Wise:SetMacroText(action, cleanText)

		UpdateCharCount(cleanText)

		-- Auto-rename text field if it changed
		if action.name and nameEdit:GetText() ~= action.name then
			nameEdit:SetText(action.name)
		end

		Wise:UpdateGroupDisplay(Wise.selectedGroup)

		-- If user is typing, we might want to refresh the list if the name auto-changed
		if isUserInput then
			-- We don't want to refresh the whole properties panel here as it would lose focus
			-- but we MUST refresh the list if the name changed.
			if Wise.OptionsFrame and Wise.OptionsFrame:IsShown() then
				Wise:RefreshGroupList()
				if Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.Content then
					Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
				end
			end
		end
	end)

	-- Initial Update (Apply initial resolution/coloring)
	local initialText = action.macroText or ""
	local resolvedInitial = Wise:ResolveAndColorMacro(initialText)
	editBox:SetText(resolvedInitial)
	if initialText ~= resolvedInitial then
		-- Update saved state if resolution happened immediately (e.g. legacy data)
		Wise:SetMacroText(action, Wise:StripMacroColors(resolvedInitial))
	end
	UpdateCharCount(Wise:StripMacroColors(resolvedInitial))

	editBox:SetScript("OnCursorChanged", function(self, x, y, w, h)
		-- Handle scrolling
	end)
	editBox:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)

	table.insert(panel.controls, scrollFrame)
	table.insert(panel.controls, bg) -- Add bg to controls to hide it later

	y = y - 160

	return y
end
