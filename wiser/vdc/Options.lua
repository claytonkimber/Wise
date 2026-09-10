-- wiser/vdc/Options.lua
--
-- The Disenchant/Convert properties panel.
-- See wiser/vdc/Core.lua for the wiser's design notes.
--
-- MIGRATION NOTE: `propertyType` here is "VendorDisenchantConvert" and the
-- SavedVariables keys keep their `vdc*` spelling, even though the Vendor slot is
-- gone. propertyType is the key MigrateLegacyGroups matches on, so renaming it
-- would strand every existing user's saved settings. Leave it.
--
-- Loaded after Slots.lua, before Events.lua.

local addonName, Wise = ...

local VDC = Wise.VDC

-- ---------------------------------------------------------------------------
-- Options panel
-- ---------------------------------------------------------------------------

-- Build a labelled numeric entry bound to one filter key. Committing the value
-- triggers a refresh so the bar reflects the new filter immediately.
local function addNumericFilter(panel, group, filters, key, label, y, suffix)
	local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("TOPLEFT", 10, y)
	text:SetText(label)
	tinsert(panel.controls, text)

	local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	box:SetSize(70, 20)
	box:SetPoint("TOPLEFT", 150, y + 4)
	box:SetAutoFocus(false)
	box:SetNumeric(false)
	box:SetText(tostring(filters[key] or 0))

	local function commit(self)
		local value = tonumber(self:GetText()) or 0
		if value < 0 then
			value = 0
		end
		filters[key] = value
		self:SetText(tostring(value))
		self:ClearFocus()
		Wise.VDC:Refresh()
	end

	box:SetScript("OnEnterPressed", commit)
	box:SetScript("OnEditFocusLost", commit)
	box:SetScript("OnEscapePressed", function(self)
		self:SetText(tostring(filters[key] or 0))
		self:ClearFocus()
	end)
	tinsert(panel.controls, box)

	if suffix then
		local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		hint:SetPoint("LEFT", box, "RIGHT", 4, 0)
		hint:SetText(suffix)
		tinsert(panel.controls, hint)
	end

	return y - 26
end

function Wise:InitializeVDCProperties()
	Wise.PropertyHooks = Wise.PropertyHooks or {}
	Wise.PropertyHooks["VendorDisenchantConvert"] = {
		suppress = {
			Actions = true, -- Slots are generated from bag contents, not hand-edited.
			Rename = true,
		},
		inject = {
			Bottom = function(panel, group, y)
				local VDCref = Wise.VDC

				local provider = VDCref:GetPriceProvider()
				local status = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
				status:SetPoint("TOPLEFT", 10, y)
				status:SetWidth(220)
				status:SetJustifyH("LEFT")
				if provider then
					status:SetText("Price data: |cff00ff00" .. provider .. "|r")
				else
					status:SetText("|cffff6600Requires TradeSkillMaster, ProfitProphet, or Auctionator.|r")
				end
				tinsert(panel.controls, status)
				y = y - 30

				-- One collapsible-style block of filters per slot, in bar order, so
				-- both are configured from the single interface's panel.
				for index, slotKey in ipairs(VDCref.SLOT_ORDER) do
					local filters = VDCref:GetFilters(group, slotKey)
					local queued = VDCref.slotCounts and VDCref.slotCounts[slotKey]

					local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
					header:SetPoint("TOPLEFT", 10, y)
					header:SetText(string.format("Slot %d — %s", index, slotKey))
					tinsert(panel.controls, header)

					if queued then
						local countFS = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
						countFS:SetPoint("LEFT", header, "RIGHT", 6, 0)
						countFS:SetText(string.format("(%d queued)", queued))
						tinsert(panel.controls, countFS)
					end
					y = y - 22

					y = addNumericFilter(panel, group, filters, "minValue", "Minimum gain (gold)", y, "g")
					y = addNumericFilter(panel, group, filters, "minMargin", "Minimum margin", y, "%")
					y = addNumericFilter(panel, group, filters, "minQuality", "Min quality (0-5)", y)
					y = addNumericFilter(panel, group, filters, "maxQuality", "Max quality (0=any)", y)
					y = addNumericFilter(panel, group, filters, "minILvl", "Min item level", y)
					y = addNumericFilter(panel, group, filters, "maxILvl", "Max item level (0=any)", y)
					y = addNumericFilter(panel, group, filters, "maxItems", "Max items queued", y)

				-- Disenchant-only: what the mat value is measured against.
				if slotKey == VDCref.SLOT_DISENCHANT then
					local imCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
					imCheck:SetSize(24, 24)
					imCheck:SetPoint("TOPLEFT", 10, y)
					imCheck:SetChecked(filters.ignoreMarket or false)
					imCheck:SetScript("OnClick", function(self)
						filters.ignoreMarket = self:GetChecked()
						Wise.VDC:Refresh()
					end)
					tinsert(panel.controls, imCheck)

					local imLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
					imLabel:SetPoint("LEFT", imCheck, "RIGHT", 4, 0)
					imLabel:SetText("Ignore auction price")
					tinsert(panel.controls, imLabel)
					y = y - 26

					local imNote = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
					imNote:SetWidth(210)
					imNote:SetPoint("TOPLEFT", 14, y)
					imNote:SetJustifyH("LEFT")
					imNote:SetText(
						"For gear bought to disenchant: compare mat value against vendor price only. Leave off for loot you might resell."
					)
					tinsert(panel.controls, imNote)
					y = y - 42
				end

					-- Disenchant-only: where to mail items when not an enchanter.
					if slotKey == VDCref.SLOT_DISENCHANT then
						local mailLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
						mailLabel:SetPoint("TOPLEFT", 10, y)
						mailLabel:SetText("Mail to (non-enchanters)")
						tinsert(panel.controls, mailLabel)
						y = y - 22

						local mailBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
						mailBox:SetSize(180, 20)
						mailBox:SetPoint("TOPLEFT", 14, y)
						mailBox:SetAutoFocus(false)
						mailBox:SetText(group.vdcMailTarget or "")
						local function commitMail(self)
							group.vdcMailTarget = self:GetText()
							self:ClearFocus()
							Wise.VDC:Refresh()
						end
						mailBox:SetScript("OnEnterPressed", commitMail)
						mailBox:SetScript("OnEditFocusLost", commitMail)
						tinsert(panel.controls, mailBox)
						y = y - 30
					end

					y = y - 10
				end

				-- Equipment-set protection. Default ON: gear the player deliberately
				-- saved into a set is almost never meant to be destroyed, and
				-- disenchanting is irreversible.
				if group.vdcProtectEquipmentSets == nil then
					group.vdcProtectEquipmentSets = true
				end
				local setCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
				setCheck:SetSize(24, 24)
				setCheck:SetPoint("TOPLEFT", 10, y)
				setCheck:SetChecked(group.vdcProtectEquipmentSets)
				setCheck:SetScript("OnClick", function(self)
					group.vdcProtectEquipmentSets = self:GetChecked()
					Wise.VDC:Refresh()
				end)
				tinsert(panel.controls, setCheck)

				local setLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				setLabel:SetPoint("LEFT", setCheck, "RIGHT", 4, 0)
				setLabel:SetText("Never destroy equipment-set gear")
				tinsert(panel.controls, setLabel)
				y = y - 30

				-- Skip list (populated by right-clicking a slot).
				local ignoredCount = 0
				for _ in pairs(Wise.VDC:GetIgnored(group)) do
					ignoredCount = ignoredCount + 1
				end

				local skipLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
				skipLabel:SetPoint("TOPLEFT", 10, y)
				skipLabel:SetWidth(210)
				skipLabel:SetJustifyH("LEFT")
				skipLabel:SetText(
					ignoredCount == 0 and "No skipped items. Right-click a slot to skip its top item."
						or string.format("%d item(s) skipped by right-click.", ignoredCount)
				)
				tinsert(panel.controls, skipLabel)
				y = y - 30

				if ignoredCount > 0 then
					local clearBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
					clearBtn:SetSize(140, 22)
					clearBtn:SetPoint("TOPLEFT", 10, y)
					clearBtn:SetText("Clear skip list")
					clearBtn:SetScript("OnClick", function()
						wipe(Wise.VDC:GetIgnored(group))
						Wise.VDC:Refresh()
						Wise:UpdateOptionsUI()
					end)
					tinsert(panel.controls, clearBtn)
					y = y - 30
				end

				-- Bind-confirmation auto-dismiss (applies to Disenchant + Convert).
				local bindCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
				bindCheck:SetSize(24, 24)
				bindCheck:SetPoint("TOPLEFT", 10, y)
				bindCheck:SetChecked(group.vdcAutoConfirmBind or false)
				bindCheck:SetScript("OnClick", function(self)
					group.vdcAutoConfirmBind = self:GetChecked()
					Wise.VDC:Refresh()
				end)
				tinsert(panel.controls, bindCheck)

				local bindLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				bindLabel:SetPoint("LEFT", bindCheck, "RIGHT", 4, 0)
				bindLabel:SetText("Auto-confirm destroy prompt")
				tinsert(panel.controls, bindLabel)
				y = y - 26

				local bindNote = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
				bindNote:SetWidth(210)
				bindNote:SetPoint("TOPLEFT", 14, y)
				bindNote:SetJustifyH("LEFT")
				bindNote:SetText(
					"Binds a key that clears Blizzard's destroy confirmation on soulbound gear. Only ever clicks that exact dialog, and only on a press you make."
				)
				tinsert(panel.controls, bindNote)
				y = y - 46

				local refreshBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
				refreshBtn:SetSize(140, 22)
				refreshBtn:SetPoint("TOPLEFT", 10, y)
				refreshBtn:SetText("Rescan Bags")
				refreshBtn:SetScript("OnClick", function()
					Wise.VDC:Refresh()
				end)
				tinsert(panel.controls, refreshBtn)
				y = y - 32

				return y
			end,
		},
	}
end
