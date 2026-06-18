local addonName, Wise = ...

local BOLD_COLORS = {
	{ name = "Red", r = 1, g = 0, b = 0 },
	{ name = "Green", r = 0, g = 1, b = 0 },
	{ name = "Blue", r = 0, g = 0, b = 1 },
	{ name = "Yellow", r = 1, g = 1, b = 0 },
	{ name = "Orange", r = 1, g = 0.5, b = 0 },
	{ name = "Purple", r = 0.6, g = 0.1, b = 0.9 },
	{ name = "Cyan", r = 0, g = 1, b = 1 },
	{ name = "Magenta", r = 1, g = 0, b = 1 },
	{ name = "White", r = 1, g = 1, b = 1 },
	{ name = "Pink", r = 1, g = 0.5, b = 0.7 },
}

local function GetColorRGB(colorName)
	for _, c in ipairs(BOLD_COLORS) do
		if c.name == colorName then
			return c.r, c.g, c.b
		end
	end
	return 1, 1, 1 -- Fallback to White
end

local function EvaluateRule(count, rule)
	local op = rule.operator
	local val = tonumber(rule.value) or 0
	if op == "<" then
		return count < val
	elseif op == "=" then
		return count == val
	elseif op == ">" then
		return count > val
	elseif op == "<=" then
		return count <= val
	elseif op == ">=" then
		return count >= val
	elseif op == "!=" then
		return count ~= val
	end
	return false
end

local function GetAbundanceSettings()
	if not WiseDB then
		return nil
	end
	WiseDB.settings = WiseDB.settings or {}
	if WiseDB.settings.abundanceExperiment == nil then
		WiseDB.settings.abundanceExperiment = {
			rules = {
				{ operator = "<=", value = 3, color = "Red", glow = false },
				{ operator = ">=", value = 6, color = "Green", glow = false },
			},
		}
	elseif WiseDB.settings.abundanceExperiment.rules == nil then
		local oldLow = WiseDB.settings.abundanceExperiment.lowerLimit or 3
		local oldHigh = WiseDB.settings.abundanceExperiment.upperLimit or 6
		WiseDB.settings.abundanceExperiment.rules = {
			{ operator = "<=", value = oldLow, color = "Red", glow = false },
			{ operator = ">=", value = oldHigh, color = "Green", glow = false },
		}
		WiseDB.settings.abundanceExperiment.lowerLimit = nil
		WiseDB.settings.abundanceExperiment.upperLimit = nil
	end
	return WiseDB.settings.abundanceExperiment
end

local function CreateLocalDropdown(parent, width, height, currentText, items, onSelect)
	local btn = CreateFrame("Button", nil, parent, "GameMenuButtonTemplate")
	btn:SetSize(width, height)
	btn:SetText(currentText)

	btn:SetScript("OnClick", function(self)
		if self.dropdown and self.dropdown:IsShown() then
			self.dropdown:Hide()
			return
		end

		if parent.activeDropdown and parent.activeDropdown ~= self.dropdown then
			parent.activeDropdown:Hide()
		end

		if not self.dropdown then
			local d = CreateFrame("Frame", nil, self, "BackdropTemplate")
			self.dropdown = d
			parent.activeDropdown = d

			local itemHeight = 20
			local dropdownHeight = (#items * itemHeight) + 10
			d:SetSize(width + 20, dropdownHeight)
			d:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
			d:SetFrameStrata("DIALOG")
			d:SetBackdrop({
				bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
				edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
				tile = true,
				tileSize = 32,
				edgeSize = 12,
				insets = { left = 4, right = 4, top = 4, bottom = 4 },
			})

			for i, val in ipairs(items) do
				local itemBtn = CreateFrame("Button", nil, d)
				itemBtn:SetSize(width + 12, itemHeight - 2)
				itemBtn:SetPoint("TOPLEFT", 4, -((i - 1) * itemHeight + 5))
				itemBtn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

				itemBtn.text = itemBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				itemBtn.text:SetPoint("LEFT", 5, 0)
				itemBtn.text:SetJustifyH("LEFT")
				itemBtn.text:SetText(tostring(val))

				itemBtn:SetScript("OnClick", function()
					self:SetText(tostring(val))
					d:Hide()
					onSelect(val)
				end)
			end
			tinsert(parent.controls, d)
		end
		self.dropdown:Show()
	end)

	tinsert(parent.controls, btn)
	return btn
end

local function GetAbundanceCount()
	-- Abundance spell ID is 203864
	local aura = C_UnitAuras.GetPlayerAuraBySpellID(203864)
	if not aura then
		aura = C_UnitAuras.GetAuraDataBySpellName("player", "Abundance")
	end
	if aura then
		return aura.applications or aura.charges or 1
	end
	return 0
end

function Wise:UpdateAbundanceBorders()
	if not Wise.frames or not Wise.buttonMeta then
		return
	end

	-- Resto Druid check: Druid (class) + Restoration (specID 105)
	local isRestoDruid = Wise.characterInfo and Wise.characterInfo.class == "DRUID" and Wise.characterInfo.specID == 105

	-- Spec gate: the only character that gets ANY visible Abundance UI is a Resto
	-- Druid. For everyone else this whole O(N) button scan does nothing but hide
	-- borders that were never created — so skip it entirely. The one exception is
	-- the transition OUT of Resto (respec): run a single cleanup pass to hide any
	-- borders/glows we left behind, then latch off. Wise._abundanceActive is set
	-- true below whenever we actually touch abundance UI, so this stays cheap.
	if not isRestoDruid then
		if not Wise._abundanceActive then
			return
		end
		Wise._abundanceActive = false -- this pass clears it; subsequent calls bail above
	else
		Wise._abundanceActive = true
	end

	local settings = GetAbundanceSettings()
	local rules = settings and settings.rules

	local count = 0
	if isRestoDruid then
		count = GetAbundanceCount()
	end

	for name, frame in pairs(Wise.frames) do
		if frame.buttons then
			for _, btn in ipairs(frame.buttons) do
				local meta = Wise.buttonMeta[btn]
				local isAbundanceBtn = false

				if meta then
					-- Recompute each pass — a custom_macro slot's resolved spell can change
					-- per character / per live-filter, so the cached flag can't be trusted
					-- across refreshes. Detection covers BOTH plain spell buttons AND
					-- graph-compiled custom_macro buttons (whose resolved spell is stored
					-- in meta.spellID/baseSpellID), so the configurator's Abundance slot
					-- still lights up.
					local ABUNDANCE_ID = 203864
					if meta.baseSpellID == ABUNDANCE_ID or meta.spellID == ABUNDANCE_ID then
						isAbundanceBtn = true
					elseif meta.actionType == "spell" and meta.actionValue then
						local valNum = tonumber(meta.actionValue)
						local spellName
						if valNum then
							local spellInfo = C_Spell.GetSpellInfo(valNum)
							spellName = spellInfo and spellInfo.name
						else
							spellName = meta.actionValue
						end
						isAbundanceBtn = (spellName == "Abundance")
					elseif meta.actionType == "misc" and meta.actionValue == "custom_macro" then
						-- Fall back to scanning the (live, filtered) macro text for Abundance.
						local mt = meta.actionData and meta.actionData.macroText
						if mt and mt:find("Abundance", 1, true) then
							isAbundanceBtn = true
						end
					end
				end

				if isAbundanceBtn then
					local visualClone = meta and meta.visualClone or btn.visualClone

					local function applyCount(b)
						if not b then
							return
						end
						if not b.abundanceCount then
							b.abundanceCount = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
							b.abundanceCount:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
							b.abundanceCount:SetJustifyH("RIGHT")
						end
						if isRestoDruid and count > 0 then
							b.abundanceCount:SetText(tostring(count))
							b.abundanceCount:Show()
						else
							b.abundanceCount:Hide()
						end
					end

					local function applyBorder(b)
						if not b then
							return
						end
						if not isRestoDruid then
							if b.abundanceBorder then
								b.abundanceBorder:Hide()
							end
							Wise:HideOverlayGlow(b)
							return
						end

						if not b.abundanceBorder then
							b.abundanceBorder = b:CreateTexture(nil, "BORDER")
							b.abundanceBorder:SetTexture("Interface\\Buttons\\WHITE8x8")
						end

						-- Adjust size to be slightly larger than the button for an outer outline look
						local width, height = b:GetSize()
						b.abundanceBorder:SetSize(width + 4, height + 4)
						b.abundanceBorder:SetPoint("CENTER", b, "CENTER", 0, 0)

						-- Apply shape mask matching button style (circular, hexagonal, octagonal, etc.)
						if b.styleMask then
							if not b.abundanceBorderMask then
								b.abundanceBorderMask = b:CreateMaskTexture()
							end
							b.abundanceBorderMask:SetTexture(
								b.styleMask:GetTexture(),
								"CLAMPTOBLACKADDITIVE",
								"CLAMPTOBLACKADDITIVE"
							)
							b.abundanceBorderMask:SetAllPoints(b.abundanceBorder)
							b.abundanceBorder:AddMaskTexture(b.abundanceBorderMask)
						else
							if b.abundanceBorderMask then
								b.abundanceBorder:RemoveMaskTexture(b.abundanceBorderMask)
							end
						end

						local matchedRule = nil
						if rules then
							for _, rule in ipairs(rules) do
								if EvaluateRule(count, rule) then
									matchedRule = rule
									break
								end
							end
						end

						if matchedRule then
							local r, g, bColor = GetColorRGB(matchedRule.color)
							b.abundanceBorder:SetVertexColor(r, g, bColor, 1)
							b.abundanceBorder:Show()
							if matchedRule.glow then
								Wise:ShowOverlayGlow(b)
							else
								Wise:HideOverlayGlow(b)
							end
						else
							b.abundanceBorder:Hide()
							Wise:HideOverlayGlow(b)
						end
					end

					applyBorder(btn)
					applyCount(btn)
					if visualClone then
						applyBorder(visualClone)
						applyCount(visualClone)
					end
				else
					if btn.abundanceBorder then
						btn.abundanceBorder:Hide()
					end
					if btn.abundanceCount then
						btn.abundanceCount:Hide()
					end
					Wise:HideOverlayGlow(btn)
					local visualClone = meta and meta.visualClone or btn.visualClone
					if visualClone then
						if visualClone.abundanceBorder then
							visualClone.abundanceBorder:Hide()
						end
						if visualClone.abundanceCount then
							visualClone.abundanceCount:Hide()
						end
						Wise:HideOverlayGlow(visualClone)
					end
				end
			end
		end
	end
end

function Wise:RenderAbundanceProperties(panel, action, y)
	local settings = GetAbundanceSettings()
	if not settings then
		return y
	end
	local rules = settings.rules

	y = y - 10
	local line = panel:CreateTexture(nil, "OVERLAY")
	line:SetColorTexture(0.3, 0.3, 0.3, 0.5)
	line:SetHeight(1)
	line:SetPoint("TOPLEFT", 10, y)
	line:SetPoint("RIGHT", -10, y)
	tinsert(panel.controls, line)

	y = y - 15
	local titleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	titleLabel:SetPoint("TOPLEFT", 10, y)
	titleLabel:SetText("|cffffcc00Abundance Colors & Glows|r")
	tinsert(panel.controls, titleLabel)

	y = y - 20
	local condLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	condLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, y)
	condLabel:SetText("Cond")
	tinsert(panel.controls, condLabel)

	local colorLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	colorLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 88, y)
	colorLabel:SetText("Color")
	tinsert(panel.controls, colorLabel)

	local glowLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	glowLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 150, y)
	glowLabel:SetText("Glow")
	tinsert(panel.controls, glowLabel)

	local colorNames = {}
	for _, c in ipairs(BOLD_COLORS) do
		tinsert(colorNames, c.name)
	end

	for i, rule in ipairs(rules) do
		y = y - 24

		-- Operator Dropdown
		local opBtn = CreateLocalDropdown(
			panel,
			40,
			20,
			rule.operator,
			{ "<", "=", ">", "<=", ">=", "!=" },
			function(val)
				rule.operator = val
				Wise:UpdateAbundanceBorders()
			end
		)
		opBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, y)

		-- Value Input
		local valEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
		valEdit:SetSize(28, 20)
		valEdit:SetPoint("TOPLEFT", panel, "TOPLEFT", 55, y)
		valEdit:SetAutoFocus(false)
		valEdit:SetText(tostring(rule.value or 0))
		valEdit:SetNumeric(true)
		valEdit:SetScript("OnTextChanged", function(self)
			local val = tonumber(self:GetText()) or 0
			rule.value = val
			Wise:UpdateAbundanceBorders()
		end)
		valEdit:SetScript("OnEnterPressed", function(self)
			self:ClearFocus()
		end)
		valEdit:SetScript("OnEscapePressed", function(self)
			self:SetText(tostring(rule.value))
			self:ClearFocus()
		end)
		tinsert(panel.controls, valEdit)

		-- Color Dropdown
		local colorBtn = CreateLocalDropdown(panel, 60, 20, rule.color, colorNames, function(val)
			rule.color = val
			Wise:UpdateAbundanceBorders()
		end)
		colorBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 88, y)

		-- Glow Checkbox
		local glowCb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		glowCb:SetSize(20, 20)
		glowCb:SetPoint("TOPLEFT", panel, "TOPLEFT", 153, y)
		glowCb:SetChecked(rule.glow == true)
		glowCb:SetScript("OnClick", function(self)
			rule.glow = self:GetChecked() and true or false
			Wise:UpdateAbundanceBorders()
		end)
		Wise:AddTooltip(glowCb, "Enable spell glow overlay (marching ants) when this condition is met.")
		tinsert(panel.controls, glowCb)

		-- Up button
		local upBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		upBtn:SetSize(16, 20)
		upBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 178, y)
		upBtn:SetText("^")
		if i == 1 then
			upBtn:Disable()
		else
			upBtn:SetScript("OnClick", function()
				local temp = rules[i]
				rules[i] = rules[i - 1]
				rules[i - 1] = temp
				Wise:UpdateAbundanceBorders()
				Wise:RefreshPropertiesPanel()
			end)
		end
		tinsert(panel.controls, upBtn)

		-- Down button
		local downBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		downBtn:SetSize(16, 20)
		downBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 196, y)
		downBtn:SetText("v")
		if i == #rules then
			downBtn:Disable()
		else
			downBtn:SetScript("OnClick", function()
				local temp = rules[i]
				rules[i] = rules[i + 1]
				rules[i + 1] = temp
				Wise:UpdateAbundanceBorders()
				Wise:RefreshPropertiesPanel()
			end)
		end
		tinsert(panel.controls, downBtn)

		-- Delete button
		local delBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		delBtn:SetSize(16, 20)
		delBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 214, y)
		delBtn:SetText("x")
		local btnText = delBtn:GetFontString()
		if btnText then
			btnText:SetTextColor(1, 0.2, 0.2)
		end
		delBtn:SetScript("OnClick", function()
			table.remove(rules, i)
			Wise:UpdateAbundanceBorders()
			Wise:RefreshPropertiesPanel()
		end)
		tinsert(panel.controls, delBtn)
	end

	y = y - 24
	local addBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	addBtn:SetSize(100, 22)
	addBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, y)
	addBtn:SetText("Add Rule")
	addBtn:SetScript("OnClick", function()
		tinsert(rules, { operator = "<=", value = 3, color = "Red", glow = false })
		Wise:UpdateAbundanceBorders()
		Wise:RefreshPropertiesPanel()
	end)
	tinsert(panel.controls, addBtn)
	y = y - 26

	return y
end

-- Coalesced refresh. The hooks below fire PER BUTTON, and UpdateAllCooldowns()
-- (which re-runs many times per second in combat) calls UpdateButtonCooldown for
-- every visible button — so calling UpdateAbundanceBorders() directly from each
-- hook made one cooldown pass cost N full N-button scans (O(N^2)). Instead we set
-- a dirty flag and run a single scan on the next frame (C_Timer.After(0)), so an
-- entire burst collapses to one pass. (AGENTS.md Rule 9 #2: coalesce event bursts.)
local abundanceDirty = false
function Wise:ScheduleAbundanceUpdate()
	if abundanceDirty then
		return
	end
	abundanceDirty = true
	C_Timer.After(0, function()
		abundanceDirty = false
		Wise:UpdateAbundanceBorders()
	end)
end

-- Event tracking frame
local abundanceEventFrame = CreateFrame("Frame")
abundanceEventFrame:RegisterEvent("UNIT_AURA")
abundanceEventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
abundanceEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
abundanceEventFrame:SetScript("OnEvent", function(self, event, unit)
	if event == "UNIT_AURA" and unit ~= "player" then
		return
	end
	Wise:ScheduleAbundanceUpdate()
end)

-- Hook state/cooldown changes to refresh border on spell swaps. Both fire per
-- button; route them through the coalescer so a full UpdateAllCooldowns pass
-- triggers exactly one Abundance scan instead of one per button.
hooksecurefunc(Wise, "UpdateButtonState", function(self, btn)
	Wise:ScheduleAbundanceUpdate()
end)

hooksecurefunc(Wise, "UpdateButtonCooldown", function(self, btn)
	Wise:ScheduleAbundanceUpdate()
end)
