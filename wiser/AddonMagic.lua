local addonName, Wise = ...

local tinsert = table.insert

-- Template name (used as key for the Wiser interface)
Wise.ADDON_MAGIC_TEMPLATE = "Addon Loading Magic"

-- ============================================================================
-- Data Initialization
-- ============================================================================

-- Addon Loading Magic stores its slots in WiseDB.addonMagicSlots
-- Each slot: { id = 7, addons = {"AddonName1", "AddonName2"}, name = "My Bundle" }
--
-- The whole system is one rule:
--
--     enabled = baseline + (addons of every active slot)
--
-- "Baseline" is what the user enabled in the client's own addon list; it is
-- always loaded and Wise never disables it. Pressing a slot adds it to the
-- active set (an on-demand excursion above baseline); pressing it again removes
-- it. ANY other reload — manual /reload, logout, relog, error reload — drops the
-- whole active set and returns to baseline. That is why the active set is
-- cleared at PLAYER_LOGIN rather than persisted: falling back to system level is
-- the default, and staying loaded is the thing that requires an explicit press.
--
-- Slots are identified by a stable `id`, never by array index: deleting a slot
-- table.removes it and shifts every later index, which would silently re-point
-- the active set at the wrong slots.
local function EnsureData()
	if not WiseDB then
		return
	end
	WiseDB.addonMagicSlots = WiseDB.addonMagicSlots or {}

	-- Backfill stable ids for slots saved before ids existed.
	local maxID = WiseDB.addonMagicNextID or 0
	for _, slot in ipairs(WiseDB.addonMagicSlots) do
		if slot.id and slot.id > maxID then
			maxID = slot.id
		end
	end
	for _, slot in ipairs(WiseDB.addonMagicSlots) do
		if not slot.id then
			maxID = maxID + 1
			slot.id = maxID
		end
	end
	WiseDB.addonMagicNextID = maxID

	-- Active slot ids for THIS session. Session-scoped by design (see above):
	-- PLAYER_LOGIN wipes it, so a reload that isn't a press lands on baseline.
	Wise.addonMagicActive = Wise.addonMagicActive or {}
end

-- Allocates the next stable slot id.
function Wise:NextAddonMagicSlotID()
	EnsureData()
	WiseDB.addonMagicNextID = (WiseDB.addonMagicNextID or 0) + 1
	return WiseDB.addonMagicNextID
end

-- Is this slot part of the current excursion?
--
-- This is stored state (Wise.addonMagicActive), NOT derived from which addons
-- are currently checked — the press un-checks them immediately after loading, so
-- the checkboxes say nothing about what is active. Keeping the set is what lets
-- a later press rebuild the union of ALL active slots and stack them.
function Wise:IsAddonMagicSlotActive(slotIndex)
	EnsureData()
	local slot = WiseDB.addonMagicSlots and WiseDB.addonMagicSlots[slotIndex]
	if not slot or not slot.id then
		return false
	end
	return Wise.addonMagicActive[slot.id] == true
end

-- ============================================================================
-- Slot State
-- ============================================================================

-- A slot's addon can go missing after it was selected (uninstalled, renamed, or
-- a folder that only exists on another machine). C_AddOns.GetAddOnInfo returns
-- nil for a name the client doesn't know about, which is what separates
-- "missing" from merely "not enabled".
function Wise:IsAddonInstalled(addon)
	addon = strtrim(addon or "")
	if addon == "" then
		return false
	end
	local name = C_AddOns.GetAddOnInfo(addon)
	return name ~= nil
end

-- Returns state, missing
--   state   -- "empty" (no addons picked), "missing" (>=1 selection is not
--              installed), "loaded" (this slot is active), or "unloaded"
--   missing -- array of the uninstalled addon names, only when state == "missing"
--
-- "loaded" means THIS SLOT IS ACTIVE — not merely that its addons are loaded.
-- Those differ once slots overlap: if slot A and slot B share WeakAuras and only
-- A was pressed, B's addons are partly loaded but B was never pressed, so B must
-- stay unhighlighted. Reading IsAddOnLoaded here would light B up spuriously.
--
-- "missing" outranks "unloaded" but NOT "loaded": an active slot whose addon was
-- uninstalled mid-excursion still needs to render as active so it can be pressed
-- off. Blocking that would strand it highlighted until a manual reload.
function Wise:GetAddonMagicSlotState(slotIndex)
	EnsureData()
	local slot = WiseDB and WiseDB.addonMagicSlots and WiseDB.addonMagicSlots[slotIndex]
	if not slot or not slot.addons or #slot.addons == 0 then
		return "empty"
	end

	local missing = nil
	for _, addon in ipairs(slot.addons) do
		addon = strtrim(addon)
		if addon ~= "" and not Wise:IsAddonInstalled(addon) then
			missing = missing or {}
			tinsert(missing, addon)
		end
	end

	if Wise:IsAddonMagicSlotActive(slotIndex) then
		-- Still report the missing list so the tooltip can name them.
		return "loaded", missing
	end
	if missing then
		return "missing", missing
	end
	return "unloaded"
end

-- ============================================================================
-- Execution: toggle a slot, enable the union, reload, then un-check
-- ============================================================================

-- The checkbox state (GetAddOnEnableState) and the loaded state (IsAddOnLoaded)
-- are independent: DisableAddOn un-checks an addon that is still running, and a
-- reload rebuilds the loaded set from the checkboxes.
--
-- That gives the whole design in one move — ENABLE, RELOAD, IMMEDIATELY UNCHECK:
--
--   * A press checks the union of every active slot, reloads (so the union is
--     what loads), then un-checks everything it added.
--   * The checkboxes are therefore back to system state the moment the excursion
--     is running. A manual /reload, a logout, a crash — anything that reloads
--     without going through a press — loads exactly the system set. No detection
--     and no clean-up pass is needed, because nothing was left checked.
--   * Pressing a slot off is just a press with a smaller union, so the same
--     path handles load, unload, and stacking.
--
-- This is why the previous approach had to be abandoned: it un-checked reactively
-- (at ADDON_LOADED, after the fact), which needed a second reload to take effect
-- — and ReloadUI is protected, so an addon cannot do that outside a click.
local function ApplyActiveSetAndReload()
	-- 0. Flush any un-check still pending from the previous press. It normally
	--    runs shortly after login, but a press before then would otherwise sample
	--    those addons as "already enabled", never re-queue them, and leave them
	--    checked for good — turning a temporary load into a permanent one.
	if Wise.ApplyPendingAddonMagicUncheck then
		Wise.ApplyPendingAddonMagicUncheck()
	end

	-- 1. Build the union of every active slot, recording each addon's enable
	--    state BEFORE we touch it. Order matters: reading the state after
	--    EnableAddOn would report everything as enabled, so nothing would ever
	--    be recognised as ours and the un-check list would always be empty.
	local playerChar = UnitName("player")
	local union, toUncheck = {}, {}
	for i, slot in ipairs(WiseDB.addonMagicSlots) do
		if Wise:IsAddonMagicSlotActive(i) and slot.addons then
			for _, addon in ipairs(slot.addons) do
				addon = strtrim(addon)
				-- Only ever touch installed addons; EnableAddOn on an unknown
				-- name errors in some clients.
				if addon ~= "" and not union[addon] and Wise:IsAddonInstalled(addon) then
					union[addon] = true
					-- Anything the user already had checked is NOT ours to
					-- un-check later, or a slot sharing an addon with their
					-- normal list would silently erode that list.
					-- Argument order is (name, character); the legacy global was
					-- reversed, and that way returns 0 for every addon.
					if C_AddOns.GetAddOnEnableState(addon, playerChar) == 0 then
						tinsert(toUncheck, addon)
					end
					C_AddOns.EnableAddOn(addon)
				end
			end
		end
	end

	-- 2. Remember what to un-check once the reload lands.
	WiseDB.addonMagicUncheck = (#toUncheck > 0) and toUncheck or nil

	-- 3. Hand the active set forward so the highlights survive the reload.
	local pending = {}
	for id in pairs(Wise.addonMagicActive) do
		tinsert(pending, id)
	end
	WiseDB.addonMagicPending = pending

	ReloadUI()
end

function Wise:ExecuteAddonMagic(slotIndex)
	EnsureData()
	local slot = WiseDB.addonMagicSlots[slotIndex]
	if not slot or not slot.addons or #slot.addons == 0 then
		return
	end

	local state, missing = Wise:GetAddonMagicSlotState(slotIndex)

	if state == "loaded" then
		-- Toggle off, then re-apply. The union shrinks, so the reload comes back
		-- without this slot's exclusive addons — while anything a still-active
		-- slot claims stays in the union and survives. That is the refcount rule,
		-- and it falls out of rebuilding the union rather than needing its own
		-- bookkeeping.
		Wise.addonMagicActive[slot.id] = nil
		ApplyActiveSetAndReload()
		return
	end

	-- Load direction: refuse a bundle that can't come back whole, and name the
	-- missing addons so the user can fix the selection instead of guessing.
	if state == "missing" then
		print(
			"|cffff4040[Wise]|r '"
				.. (slot.name or ("Slot " .. slotIndex))
				.. "' is missing: "
				.. table.concat(missing, ", ")
		)
		return
	end

	Wise.addonMagicActive[slot.id] = true
	ApplyActiveSetAndReload()
end

-- ============================================================================
-- Login: restore the highlights and un-check what the press added
-- ============================================================================

-- Runs on ADDON_LOADED, not at file scope: WiseDB is a SavedVariable that
-- Wise.lua populates in its own ADDON_LOADED handler, so at file scope it is
-- still nil and the pending set would never be read (the excursion would come
-- back unhighlighted even though its addons loaded).
local function RestoreAddonMagic()
	if not WiseDB then
		return
	end
	EnsureData()

	-- A press hands its active set forward; anything else (manual reload, relog)
	-- has none, which correctly means "nothing is active".
	Wise.addonMagicActive = {}
	if WiseDB.addonMagicPending then
		for _, id in ipairs(WiseDB.addonMagicPending) do
			Wise.addonMagicActive[id] = true
		end
		WiseDB.addonMagicPending = nil
	end

	-- Legacy fields from older versions of this feature: drain and drop.
	if WiseDB.addonsToDisable then
		for _, addon in ipairs(WiseDB.addonsToDisable) do
			C_AddOns.DisableAddOn(addon)
		end
		WiseDB.addonsToDisable = nil
	end
	WiseDB.addonMagicBaseline = nil
	WiseDB.addonMagicReverting = nil
end

Wise.RestoreAddonMagic = RestoreAddonMagic

-- Un-check what the press enabled. The addons are already loaded for this
-- session, so this only affects what loads NEXT time — which is the whole trick:
-- from here on, any reload that is not a press lands on system state without
-- needing to detect anything.
--
-- Deliberately runs LATE (PLAYER_LOGIN, after a frame), not on Wise's own
-- ADDON_LOADED. Other addons check whether their dependencies are ENABLED during
-- their startup — TSM warns "AppHelper is installed but not enabled" — and Wise
-- loads early, so un-checking at ADDON_LOADED pulled the state out from under
-- them before they ever looked. Enable state is only consulted at startup, so
-- deferring past it is safe; the reload behaviour is unchanged because the
-- un-check still lands well before the user can reload.
local function ApplyPendingUncheck()
	if not WiseDB or not WiseDB.addonMagicUncheck then
		return
	end
	for _, addon in ipairs(WiseDB.addonMagicUncheck) do
		C_AddOns.DisableAddOn(addon)
	end
	WiseDB.addonMagicUncheck = nil
end

Wise.ApplyPendingAddonMagicUncheck = ApplyPendingUncheck

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		-- Only once, for Wise itself: WiseDB exists from here on.
		if arg1 == addonName then
			RestoreAddonMagic()
			self:UnregisterEvent("ADDON_LOADED")
		end
		return
	end

	-- PLAYER_LOGIN: every addon has loaded and run its own startup checks.
	-- One more frame of slack for anything that defers its check to OnUpdate.
	C_Timer.After(0, ApplyPendingUncheck)

	-- Highlights render from the active set, so refresh once the UI exists.
	if Wise.UpdateAllStates then
		Wise:UpdateAllStates()
	end
end)

-- ============================================================================
-- Properties Panel: Addon Picker for Selected Slot (addon_magic action)
-- ============================================================================

function Wise:CreateAddonMagicPropertiesPanel(panel, slotIndex, y)
	EnsureData()
	local slot = WiseDB.addonMagicSlots[slotIndex]
	if not slot then
		return y
	end

	-- Slot Name Editor
	local nameLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	nameLabel:SetPoint("TOPLEFT", 10, y)
	nameLabel:SetText("Slot Name:")
	tinsert(panel.controls, nameLabel)
	y = y - 20

	local nameEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	nameEdit:SetSize(200, 24)
	nameEdit:SetPoint("TOPLEFT", 15, y)
	nameEdit:SetAutoFocus(false)
	nameEdit:SetText(slot.name or "")
	nameEdit:SetScript("OnEnterPressed", function(self)
		slot.name = self:GetText()
		self:ClearFocus()
		-- Rebuild the Wiser group so button names update
		if Wise.UpdateWiserInterfaces then
			Wise:UpdateWiserInterfaces()
		end
	end)
	nameEdit:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	tinsert(panel.controls, nameEdit)
	y = y - 30

	-- Execute Button — label and enabled state track the slot's current state
	local execBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
	execBtn:SetSize(200, 28)
	execBtn:SetPoint("TOPLEFT", 10, y)
	tinsert(panel.controls, execBtn)

	local execState = Wise:GetAddonMagicSlotState(slotIndex)
	if execState == "loaded" then
		-- Stays enabled even if an addon went missing mid-excursion, or the slot
		-- would be stuck loaded with no way to switch it off.
		execBtn:SetText("Unload Addons & Reload")
	elseif execState == "missing" then
		execBtn:SetText("|cffff4040Missing Addons|r")
		execBtn:Disable()
	else
		execBtn:SetText("Load Addons & Reload")
	end

	local addonCount = slot.addons and #slot.addons or 0
	if addonCount == 0 then
		execBtn:Disable()
	end

	execBtn:SetScript("OnClick", function()
		Wise:ExecuteAddonMagic(slotIndex)
	end)
	y = y - 35

	-- Delete Slot Button
	local delBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	delBtn:SetSize(140, 24)
	delBtn:SetPoint("TOPLEFT", 10, y)
	delBtn:SetText("Delete Slot")
	local btnText = delBtn:GetFontString()
	if btnText then
		btnText:SetTextColor(1, 0.2, 0.2)
	end

	delBtn:SetScript("OnClick", function()
		StaticPopupDialogs["WISE_CONFIRM_DELETE_AM_SLOT"] = {
			text = "Delete '" .. (slot.name or ("Slot " .. slotIndex)) .. "' and its addon selections?",
			button1 = "Delete",
			button2 = "Cancel",
			OnAccept = function()
				-- Drop it from the active set first, or the next press would
				-- rebuild the union from a slot that no longer exists.
				if slot.id then
					Wise.addonMagicActive[slot.id] = nil
				end
				table.remove(WiseDB.addonMagicSlots, slotIndex)
				Wise.selectedSlot = nil
				Wise.selectedState = nil
				-- Rebuild the Wiser group
				if Wise.UpdateWiserInterfaces then
					Wise:UpdateWiserInterfaces()
				end
			end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
		}
		StaticPopup_Show("WISE_CONFIRM_DELETE_AM_SLOT")
	end)
	tinsert(panel.controls, delBtn)
	y = y - 35

	-- Separator
	local sep = panel:CreateTexture(nil, "ARTWORK")
	sep:SetSize(200, 1)
	sep:SetPoint("TOPLEFT", 10, y)
	sep:SetColorTexture(0.4, 0.4, 0.4, 0.6)
	tinsert(panel.controls, sep)
	y = y - 10

	-- Addon Selection
	local alabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	alabel:SetPoint("TOPLEFT", 10, y)
	alabel:SetText("Select Addons to Load:")
	tinsert(panel.controls, alabel)
	y = y - 20

	slot.addons = slot.addons or {}
	local selectedMap = {}
	for _, v in ipairs(slot.addons) do
		selectedMap[v] = true
	end

	-- Removes one addon from the slot and refreshes dependent UI.
	local function RemoveAddon(name)
		local newAddons = {}
		for _, existing in ipairs(slot.addons) do
			if existing ~= name then
				tinsert(newAddons, existing)
			end
		end
		slot.addons = newAddons
		if Wise.UpdateWiserInterfaces then
			Wise:UpdateWiserInterfaces()
		end
	end

	-- Missing selections are listed first and are the only way to clear them:
	-- the checkbox list below only walks installed addons, so an uninstalled
	-- name would otherwise be stuck in the slot with no UI to remove it.
	local _, amMissing = Wise:GetAddonMagicSlotState(slotIndex)
	if amMissing then
		local mLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		mLabel:SetPoint("TOPLEFT", 10, y)
		mLabel:SetText("|cffff4040Missing (not installed):|r")
		tinsert(panel.controls, mLabel)
		y = y - 20

		for _, missingName in ipairs(amMissing) do
			local mText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			mText:SetPoint("TOPLEFT", 15, y)
			mText:SetText("|cffff8080" .. missingName .. "|r")
			tinsert(panel.controls, mText)

			local mRemove = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
			mRemove:SetSize(70, 20)
			mRemove:SetPoint("TOPLEFT", 190, y + 4)
			mRemove:SetText("Remove")
			mRemove.addonName = missingName
			mRemove:SetScript("OnClick", function(self)
				RemoveAddon(self.addonName)
				-- Rebuild the panel so this row disappears
				if Wise.RefreshPropertiesPanel then
					Wise:RefreshPropertiesPanel()
				end
			end)
			tinsert(panel.controls, mRemove)
			y = y - 24
		end
		y = y - 10
	end

	local numAddons = C_AddOns.GetNumAddOns()
	for i = 1, numAddons do
		local name, title = C_AddOns.GetAddOnInfo(i)
		-- Skip Blizzard default addons and Wise itself
		if not name:match("^Blizzard_") and name ~= "Wise" then
			local aCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
			aCheck:SetPoint("TOPLEFT", 10, y)
			aCheck:SetChecked(selectedMap[name] or false)
			aCheck.text = aCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			aCheck.text:SetPoint("LEFT", aCheck, "RIGHT", 5, 0)
			aCheck.text:SetText(title or name)

			aCheck.addonName = name
			aCheck:SetScript("OnClick", function(self)
				local isChecked = self:GetChecked()
				RemoveAddon(self.addonName)
				if isChecked then
					tinsert(slot.addons, self.addonName)
					if Wise.UpdateWiserInterfaces then
						Wise:UpdateWiserInterfaces()
					end
				end
			end)

			tinsert(panel.controls, aCheck)
			tinsert(panel.controls, aCheck.text)
			y = y - 25
		end
	end

	y = y - 10
	return y
end

-- ============================================================================
-- Hook RefreshActionsView to customize Add Slot for Addon Loading Magic
-- ============================================================================

local origRefreshActionsView = Wise.RefreshActionsView
function Wise:RefreshActionsView(container)
	-- Call the original first
	if origRefreshActionsView then
		origRefreshActionsView(self, container)
	end

	-- If Addon Loading Magic is selected, override the Add Slot button behavior
	local isAM = (Wise.selectedGroup == Wise.ADDON_MAGIC_TEMPLATE)

	-- Hide/show filter buttons
	if Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.FilterButtons then
		for _, btn in pairs(Wise.OptionsFrame.Middle.FilterButtons) do
			if isAM then
				btn:Hide()
			elseif Wise.currentTab == "Editor" then
				btn:Show()
			end
		end
	end

	if isAM then
		local addSlotBtn = Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.AddSlotBtn
		if addSlotBtn then
			addSlotBtn:Enable()
			addSlotBtn:SetScript("OnClick", function()
				EnsureData()
				local nextSlot = #WiseDB.addonMagicSlots + 1
				WiseDB.addonMagicSlots[nextSlot] = {
					id = Wise:NextAddonMagicSlotID(),
					addons = {},
					name = "Slot " .. nextSlot,
				}
				-- Rebuild the Wiser group to pick up the new slot
				if Wise.UpdateWiserInterfaces then
					Wise:UpdateWiserInterfaces()
				end
			end)
		end
	end
end

-- ============================================================================
-- Hook UpdateBindings to sync AM keybinds back to persistent storage
-- ============================================================================

local origUpdateBindings = Wise.UpdateBindings
function Wise:UpdateBindings()
	-- Call the original binding logic
	if origUpdateBindings then
		origUpdateBindings(self)
	end

	-- Sync AM slot keybinds from group.actions back to WiseDB.addonMagicSlots
	EnsureData()
	local group = WiseDB.groups[Wise.ADDON_MAGIC_TEMPLATE]
	if group and group.actions and WiseDB.addonMagicSlots then
		for i, slot in ipairs(WiseDB.addonMagicSlots) do
			if group.actions[i] then
				slot.keybind = group.actions[i].keybind or nil
			end
		end
	end
end
