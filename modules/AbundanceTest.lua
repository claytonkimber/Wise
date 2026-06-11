local addonName, Wise = ...

-- Ensure settings subtable exists
if not WiseDB then
	-- In case this runs before DB initialization, we handle it in Initialize/event below
else
	WiseDB.settings = WiseDB.settings or {}
	if WiseDB.settings.abundanceExperiment == nil then
		WiseDB.settings.abundanceExperiment = {
			lowerLimit = 3,
			upperLimit = 6,
		}
	end
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

	local settings = WiseDB and WiseDB.settings and WiseDB.settings.abundanceExperiment
	local lowerLimit = settings and settings.lowerLimit or 3
	local upperLimit = settings and settings.upperLimit or 6

	local count = 0
	if isRestoDruid then
		count = GetAbundanceCount()
	end

	for name, frame in pairs(Wise.frames) do
		if frame.buttons then
			for _, btn in ipairs(frame.buttons) do
				local meta = Wise.buttonMeta[btn]
				local isAbundanceBtn = false

				if meta and meta.actionType == "spell" and meta.actionValue then
					if meta.isAbundanceBtn == nil then
						local spellName
						local valNum = tonumber(meta.actionValue)
						if valNum then
							local spellInfo = C_Spell.GetSpellInfo(valNum)
							spellName = spellInfo and spellInfo.name
						else
							spellName = meta.actionValue
						end
						meta.isAbundanceBtn = (spellName == "Abundance")
					end
					isAbundanceBtn = meta.isAbundanceBtn
				end

				if isAbundanceBtn then
					local visualClone = meta and meta.visualClone or btn.visualClone

					local function applyBorder(b)
						if not b then
							return
						end
						if not isRestoDruid then
							if b.abundanceBorder then
								b.abundanceBorder:Hide()
							end
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

						if count <= lowerLimit then
							b.abundanceBorder:SetVertexColor(1, 0, 0, 1) -- Red
							b.abundanceBorder:Show()
						elseif count >= upperLimit then
							b.abundanceBorder:SetVertexColor(0, 1, 0, 1) -- Green
							b.abundanceBorder:Show()
						else
							b.abundanceBorder:Hide()
						end
					end

					applyBorder(btn)
					if visualClone then
						applyBorder(visualClone)
					end
				else
					if btn.abundanceBorder then
						btn.abundanceBorder:Hide()
					end
					local visualClone = meta and meta.visualClone or btn.visualClone
					if visualClone and visualClone.abundanceBorder then
						visualClone.abundanceBorder:Hide()
					end
				end
			end
		end
	end
end

function Wise:RenderAbundanceProperties(panel, action, y)
	WiseDB.settings = WiseDB.settings or {}
	WiseDB.settings.abundanceExperiment = WiseDB.settings.abundanceExperiment
		or {
			lowerLimit = 3,
			upperLimit = 6,
		}
	local settings = WiseDB.settings.abundanceExperiment

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
	titleLabel:SetText("|cffffcc00Abundance Experiment (Resto Druid)|r")
	tinsert(panel.controls, titleLabel)

	y = y - 22
	local lowerLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	lowerLabel:SetPoint("TOPLEFT", 10, y)
	lowerLabel:SetText("Lower Limit (Red Border):")
	tinsert(panel.controls, lowerLabel)

	y = y - 18
	local lowerEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	lowerEdit:SetSize(100, 20)
	lowerEdit:SetPoint("TOPLEFT", 14, y)
	lowerEdit:SetAutoFocus(false)
	lowerEdit:SetText(tostring(settings.lowerLimit or 3))
	lowerEdit:SetNumeric(true)
	tinsert(panel.controls, lowerEdit)

	y = y - 25
	local upperLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	upperLabel:SetPoint("TOPLEFT", 10, y)
	upperLabel:SetText("Upper Limit (Green Border):")
	tinsert(panel.controls, upperLabel)

	y = y - 18
	local upperEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	upperEdit:SetSize(100, 20)
	upperEdit:SetPoint("TOPLEFT", 14, y)
	upperEdit:SetAutoFocus(false)
	upperEdit:SetText(tostring(settings.upperLimit or 6))
	upperEdit:SetNumeric(true)
	tinsert(panel.controls, upperEdit)

	local function SaveSettings()
		local low = tonumber(lowerEdit:GetText()) or 3
		local high = tonumber(upperEdit:GetText()) or 6
		settings.lowerLimit = low
		settings.upperLimit = high
		Wise:UpdateAbundanceBorders()
	end

	lowerEdit:SetScript("OnTextChanged", SaveSettings)
	lowerEdit:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
	end)
	lowerEdit:SetScript("OnEscapePressed", function(self)
		self:SetText(tostring(settings.lowerLimit))
		self:ClearFocus()
	end)

	upperEdit:SetScript("OnTextChanged", SaveSettings)
	upperEdit:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
	end)
	upperEdit:SetScript("OnEscapePressed", function(self)
		self:SetText(tostring(settings.upperLimit))
		self:ClearFocus()
	end)

	return y - 10
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
	Wise:UpdateAbundanceBorders()
end)

-- Hook state/cooldown changes to refresh border on spell swaps
hooksecurefunc(Wise, "UpdateButtonState", function(self, btn)
	Wise:UpdateAbundanceBorders()
end)

hooksecurefunc(Wise, "UpdateButtonCooldown", function(self, btn)
	Wise:UpdateAbundanceBorders()
end)
