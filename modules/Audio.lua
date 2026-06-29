local addonName, Wise = ...

-- Shared audio helpers ------------------------------------------------------
-- Centralises Oxed Hub sound integration + the threshold operator so BOTH the
-- Abundance stack indicator (AbundanceTest.lua) and the general per-node Audio
-- Cue feature (AudioCues.lua) use one implementation. OxedHub exposes itself as a
-- global (its Core.lua does `_G["OxedHub"] = OxedHub`). We read its generated
-- sound catalog and reuse its Sounds:Play() so we respect the user's Oxed channel
-- + cooldown. Everything degrades gracefully to nil/no-op when OxedHub isn't
-- installed or hasn't loaded yet, so Wise never hard-depends on it.

local tinsert = table.insert

-- Sentinel stored on a cue/rule meaning "no sound".
Wise.OXED_SOUND_NONE = ""

local function GetOxedCatalog()
	local oxed = _G.OxedHub
	return oxed and oxed.GENERATED_SOUND_CATALOG or nil
end

-- Returns a display label for a stored sound id (or nil if unset/unknown).
function Wise:GetOxedSoundLabel(soundId)
	if not soundId or soundId == Wise.OXED_SOUND_NONE then
		return nil
	end
	local catalog = GetOxedCatalog()
	local entry = catalog and catalog[soundId]
	if entry then
		-- Catalog names sometimes carry an "OxedHub " prefix; strip it for display.
		local name = entry.name or soundId
		return (name:gsub("^OxedHub%s+", ""))
	end
	-- Stored id we can't resolve (OxedHub not loaded, or sound removed). Show the
	-- raw id so the user still sees *something* rather than a blank dropdown.
	return soundId
end

-- Build { categoryName -> { {id=, label=}, ... } } sorted, plus an ordered list
-- of category names. Cached per catalog identity so we don't rebuild every panel
-- render. Returns nil if the catalog isn't available.
local oxedSoundsCache = nil
local oxedSoundsCacheSrc = nil
function Wise:GetOxedSoundsByCategory()
	local catalog = GetOxedCatalog()
	if not catalog then
		return nil, nil
	end
	if oxedSoundsCache and oxedSoundsCacheSrc == catalog then
		return oxedSoundsCache.byCat, oxedSoundsCache.order
	end

	local byCat = {}
	for id, entry in pairs(catalog) do
		local cat = (entry.category and entry.category ~= "" and entry.category) or "Other"
		byCat[cat] = byCat[cat] or {}
		local name = entry.name or id
		tinsert(byCat[cat], { id = id, label = (name:gsub("^OxedHub%s+", "")) })
	end

	local order = {}
	for cat, list in pairs(byCat) do
		table.sort(list, function(a, b)
			return a.label:lower() < b.label:lower()
		end)
		tinsert(order, cat)
	end
	table.sort(order)

	oxedSoundsCache = { byCat = byCat, order = order }
	oxedSoundsCacheSrc = catalog
	return byCat, order
end

-- Play a stored sound id through OxedHub (respects its channel + cooldown).
-- No-op if OxedHub/Sounds isn't available or the id is unset. Pure insecure
-- (PlaySoundFile under the hood) so it is safe to call in combat.
function Wise:PlayOxedSound(soundId)
	if not soundId or soundId == Wise.OXED_SOUND_NONE then
		return
	end
	local oxed = _G.OxedHub
	if oxed and oxed.Sounds and oxed.Sounds.Play then
		oxed.Sounds:Play(soundId)
	end
end

-- Numeric comparison shared by the Abundance rules and the threshold audio cue.
function Wise:EvaluateNumericRule(count, operator, value)
	local val = tonumber(value) or 0
	if operator == "<" then
		return count < val
	elseif operator == "=" then
		return count == val
	elseif operator == ">" then
		return count > val
	elseif operator == "<=" then
		return count <= val
	elseif operator == ">=" then
		return count >= val
	elseif operator == "!=" then
		return count ~= val
	end
	return false
end

-- Simple single-level dropdown of string `items`; calls onSelect(value) on pick.
-- `parent` must carry a `.controls` array (cleanup) and may carry `.activeDropdown`.
function Wise:CreateSimpleDropdown(parent, width, height, currentText, items, onSelect)
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

-- Two-level sound picker: top-level lists Oxed categories; selecting a category
-- opens a scrollable sub-panel of that category's sounds. onSelect is called with
-- the chosen sound id (or OXED_SOUND_NONE for "None"). Returns the trigger button.
-- `parent` must be a frame carrying a `.controls` array (for cleanup) and may carry
-- a `.activeDropdown` field used to close a sibling dropdown when this one opens.
function Wise:CreateSoundDropdown(parent, width, height, currentSoundId, onSelect)
	local btn = CreateFrame("Button", nil, parent, "GameMenuButtonTemplate")
	btn:SetSize(width, height)
	btn:SetText(Wise:GetOxedSoundLabel(currentSoundId) or "None")

	local function CloseMenus(self)
		if self.subMenu then
			self.subMenu:Hide()
		end
		if self.dropdown then
			self.dropdown:Hide()
		end
	end

	btn:SetScript("OnClick", function(self)
		if self.dropdown and self.dropdown:IsShown() then
			CloseMenus(self)
			return
		end

		if parent.activeDropdown and parent.activeDropdown ~= self.dropdown then
			parent.activeDropdown:Hide()
		end

		local byCat, order = Wise:GetOxedSoundsByCategory()
		if not byCat then
			-- OxedHub not loaded/installed — tell the user instead of opening empty.
			print("|cffffcc00Wise:|r Oxed Hub not detected; install/enable it to pick custom sounds.")
			return
		end

		-- Rebuild the menu each open so it reflects the live catalog and current value.
		if self.dropdown then
			self.dropdown:Hide()
			self.dropdown = nil
		end
		if self.subMenu then
			self.subMenu:Hide()
			self.subMenu = nil
		end

		local catHeight = 18
		-- "None" pseudo-category + one row per real category.
		local rows = #order + 1
		local d = CreateFrame("Frame", nil, self, "BackdropTemplate")
		self.dropdown = d
		parent.activeDropdown = d
		d:SetSize(150, (rows * catHeight) + 10)
		d:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
		d:SetFrameStrata("FULLSCREEN_DIALOG")
		d:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true,
			tileSize = 32,
			edgeSize = 12,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		tinsert(parent.controls, d)

		local function MakeCatRow(index, label, onClick)
			local row = CreateFrame("Button", nil, d)
			row:SetSize(138, catHeight - 2)
			row:SetPoint("TOPLEFT", 6, -((index - 1) * catHeight + 5))
			row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
			row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.text:SetPoint("LEFT", 4, 0)
			row.text:SetJustifyH("LEFT")
			row.text:SetText(label)
			row:SetScript("OnClick", onClick)
			return row
		end

		-- Row 1: clear selection.
		MakeCatRow(1, "|cff888888None|r", function()
			self:SetText("None")
			CloseMenus(self)
			onSelect(Wise.OXED_SOUND_NONE)
		end)

		for ci, cat in ipairs(order) do
			local list = byCat[cat]
			MakeCatRow(ci + 1, string.format("%s (%d) >", cat, #list), function()
				if self.subMenu then
					self.subMenu:Hide()
					self.subMenu = nil
				end

				-- Scrollable sub-panel of this category's sounds.
				local sub = CreateFrame("Frame", nil, d, "BackdropTemplate")
				self.subMenu = sub
				local subHeight = 240
				sub:SetSize(190, subHeight)
				sub:SetPoint("TOPLEFT", d, "TOPRIGHT", 2, 0)
				sub:SetFrameStrata("FULLSCREEN_DIALOG")
				sub:SetBackdrop({
					bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
					edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
					tile = true,
					tileSize = 32,
					edgeSize = 12,
					insets = { left = 4, right = 4, top = 4, bottom = 4 },
				})
				tinsert(parent.controls, sub)

				local scroll = CreateFrame("ScrollFrame", nil, sub, "UIPanelScrollFrameTemplate")
				scroll:SetPoint("TOPLEFT", 8, -8)
				scroll:SetPoint("BOTTOMRIGHT", -28, 8)
				local content = CreateFrame("Frame", nil, scroll)
				content:SetSize(150, #list * 18)
				scroll:SetScrollChild(content)

				for si, entry in ipairs(list) do
					local sRow = CreateFrame("Button", nil, content)
					sRow:SetSize(150, 16)
					sRow:SetPoint("TOPLEFT", 0, -((si - 1) * 18))
					sRow:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
					local txt = sRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
					txt:SetPoint("LEFT", 2, 0)
					txt:SetPoint("RIGHT", -2, 0)
					txt:SetJustifyH("LEFT")
					txt:SetWordWrap(false)
					txt:SetText(entry.label)
					-- Preview on hover so the user can audition before committing.
					sRow:SetScript("OnEnter", function()
						Wise:PlayOxedSound(entry.id)
					end)
					sRow:SetScript("OnClick", function()
						self:SetText(entry.label)
						CloseMenus(self)
						onSelect(entry.id)
					end)
				end
			end)
		end

		d:Show()
	end)

	tinsert(parent.controls, btn)
	return btn
end
