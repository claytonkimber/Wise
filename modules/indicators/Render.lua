-- modules/indicators/Render.lua
--
-- The indicator-rules editor, rendered inside the node properties panel
-- (modules/SlotConfigurator.lua). Reads and writes action.indicatorRules.
-- See modules/indicators/Model.lua for how this directory is laid out.
--
-- `commit` is the caller's re-export-and-re-render callback: this file must call
-- it after any edit, or the change stays in the panel and never reaches the
-- live buttons.
--
-- Loaded after Model.lua.

local addonName, Wise = ...

local tinsert = table.insert

local IR = Wise.IndicatorRules
local BOLD_COLORS = IR.BOLD_COLORS
local GetColorRGB = IR.GetColorRGB
local METRICS = IR.METRICS
local METRIC_LABELS = IR.METRIC_LABELS
local RuleMetric = IR.RuleMetric
local IsNumericMetric = IR.IsNumericMetric
local DefaultMetricForAction = IR.DefaultMetricForAction

-- =========================================================================
-- UI: rendered inside the node properties panel (SlotConfigurator.lua).
-- Reads/writes action.indicatorRules. `commit` re-exports + re-renders.
-- =========================================================================
function Wise:RenderIndicatorRules(panel, action, y, commit)
	commit = commit or function() end
	if type(action) ~= "table" then
		return y
	end
	action.indicatorRules = action.indicatorRules or {}
	local rules = action.indicatorRules

	local function changed()
		Wise:RebuildIndicatorRules()
		Wise:ScheduleIndicatorUpdate()
		commit()
	end

	y = y - 10
	local divider = panel:CreateTexture(nil, "OVERLAY")
	divider:SetColorTexture(0.3, 0.3, 0.3, 0.5)
	divider:SetHeight(1)
	divider:SetPoint("TOPLEFT", 10, y)
	divider:SetPoint("RIGHT", -10, y)
	tinsert(panel.controls, divider)

	y = y - 15
	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 10, y)
	title:SetText("|cffffcc00Colors, Glows & Sounds|r")
	tinsert(panel.controls, title)

	y = y - 14
	local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	sub:SetPoint("TOPLEFT", 10, y)
	sub:SetWidth(240)
	sub:SetJustifyH("LEFT")
	sub:SetText("Color/glow this button and play a sound based on what each rule watches.")
	tinsert(panel.controls, sub)

	local colorNames = {}
	for _, c in ipairs(BOLD_COLORS) do
		tinsert(colorNames, c.name)
	end
	local metricNames = {}
	for _, m in ipairs(METRICS) do
		tinsert(metricNames, m.label)
	end

	for i, rule in ipairs(rules) do
		local metricKey = RuleMetric(rule)
		local numeric = IsNumericMetric(metricKey)

		-- Row 1: which metric this rule watches, + reorder/delete buttons.
		y = y - 26
		local metricBtn = Wise:CreateSimpleDropdown(
			panel,
			130,
			20,
			METRIC_LABELS[metricKey],
			metricNames,
			function(label)
				for _, m in ipairs(METRICS) do
					if m.label == label then
						rule.metric = m.key
						break
					end
				end
				changed()
				Wise:RefreshPropertiesPanel() -- show/hide the operator+value row
			end
		)
		metricBtn:SetPoint("TOPLEFT", 10, y)
		if Wise.AddTooltip then
			Wise:AddTooltip(
				metricBtn,
				"What this rule watches on this spell (charges, availability, buff state)."
			)
		end

		local upBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		upBtn:SetSize(16, 20)
		upBtn:SetPoint("TOPLEFT", 178, y)
		upBtn:SetText("^")
		if i == 1 then
			upBtn:Disable()
		else
			upBtn:SetScript("OnClick", function()
				rules[i], rules[i - 1] = rules[i - 1], rules[i]
				changed()
				Wise:RefreshPropertiesPanel()
			end)
		end
		tinsert(panel.controls, upBtn)

		local downBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		downBtn:SetSize(16, 20)
		downBtn:SetPoint("TOPLEFT", 196, y)
		downBtn:SetText("v")
		if i == #rules then
			downBtn:Disable()
		else
			downBtn:SetScript("OnClick", function()
				rules[i], rules[i + 1] = rules[i + 1], rules[i]
				changed()
				Wise:RefreshPropertiesPanel()
			end)
		end
		tinsert(panel.controls, downBtn)

		local delBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		delBtn:SetSize(16, 20)
		delBtn:SetPoint("TOPLEFT", 214, y)
		delBtn:SetText("x")
		local btnText = delBtn:GetFontString()
		if btnText then
			btnText:SetTextColor(1, 0.2, 0.2)
		end
		delBtn:SetScript("OnClick", function()
			table.remove(rules, i)
			changed()
			Wise:RefreshPropertiesPanel()
		end)
		tinsert(panel.controls, delBtn)

		-- Row 2 (numeric metrics only): operator + threshold value.
		if numeric then
			y = y - 24
			local opBtn = Wise:CreateSimpleDropdown(
				panel,
				44,
				20,
				rule.operator or ">=",
				{ "<", "=", ">", "<=", ">=", "!=" },
				function(val)
					rule.operator = val
					changed()
				end
			)
			opBtn:SetPoint("TOPLEFT", 24, y)

			local valEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
			valEdit:SetSize(40, 20)
			valEdit:SetPoint("TOPLEFT", 76, y)
			valEdit:SetAutoFocus(false)
			valEdit:SetText(tostring(rule.value or 0))
			valEdit:SetNumeric(true)
			valEdit:SetScript("OnTextChanged", function(self)
				rule.value = tonumber(self:GetText()) or 0
			end)
			valEdit:SetScript("OnEditFocusLost", changed)
			valEdit:SetScript("OnEnterPressed", function(self)
				self:ClearFocus()
			end)
			valEdit:SetScript("OnEscapePressed", function(self)
				self:SetText(tostring(rule.value or 0))
				self:ClearFocus()
			end)
			tinsert(panel.controls, valEdit)
		end

		-- Row 3: color + glow (what to do when the rule matches).
		y = y - 24
		local colorBtn = Wise:CreateSimpleDropdown(panel, 70, 20, rule.color, colorNames, function(val)
			rule.color = val
			changed()
		end)
		colorBtn:SetPoint("TOPLEFT", 24, y)

		local glowCb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		glowCb:SetSize(20, 20)
		glowCb:SetPoint("TOPLEFT", 104, y)
		glowCb:SetChecked(rule.glow == true)
		glowCb:SetScript("OnClick", function(self)
			rule.glow = self:GetChecked() and true or false
			changed()
		end)
		tinsert(panel.controls, glowCb)
		local glowText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		glowText:SetPoint("LEFT", glowCb, "RIGHT", 2, 0)
		glowText:SetText("Glow")
		tinsert(panel.controls, glowText)

		-- Row 4: sound + preview.
		y = y - 22
		local soundLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		soundLabel:SetPoint("TOPLEFT", 24, y - 3)
		soundLabel:SetText("Sound")
		tinsert(panel.controls, soundLabel)

		local soundBtn = Wise:CreateSoundDropdown(panel, 150, 20, rule.sound, function(val)
			rule.sound = val
			-- No visual refresh here: picking a sound shouldn't re-fire the transition gate.
			commit()
		end)
		soundBtn:SetPoint("TOPLEFT", 52, y)
		if Wise.AddTooltip then
			Wise:AddTooltip(
				soundBtn,
				"Play an Oxed Hub sound when this condition is first met. Hover a sound to preview it."
			)
		end

		local previewBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		previewBtn:SetSize(24, 20)
		previewBtn:SetPoint("TOPLEFT", 206, y)
		previewBtn:SetText(">")
		previewBtn:SetScript("OnClick", function()
			Wise:PlayOxedSound(rule.sound)
		end)
		if Wise.AddTooltip then
			Wise:AddTooltip(previewBtn, "Preview the selected sound.")
		end
		tinsert(panel.controls, previewBtn)
	end

	y = y - 24
	local addBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	addBtn:SetSize(100, 22)
	addBtn:SetPoint("TOPLEFT", 10, y)
	addBtn:SetText("Add Rule")
	addBtn:SetScript("OnClick", function()
		local metric = DefaultMetricForAction(action)
		tinsert(rules, { metric = metric, operator = ">=", value = 1, color = "Green", glow = false, sound = "" })
		changed()
		Wise:RefreshPropertiesPanel()
	end)
	tinsert(panel.controls, addBtn)
	y = y - 26

	return y
end

