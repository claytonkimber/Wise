local addonName, Wise = ...

-- ============================================================================
-- Drag and Drop Handler
-- ============================================================================

function Wise:OnDragReceive(groupName, slotIndex, isAppend, stateIndex)
	if WiseDB.settings.enableDragDrop == false then
		return
	end
	-- NOTE: `type` shadows the Lua built-in for the rest of this function, so never
	-- call type() below this line — use the hoisted `luaType` alias instead.
	local luaType = _G.type
	local type, id, subType, param4 = GetCursorInfo()

	if WiseDB.groups[groupName] and WiseDB.groups[groupName].isLocked then
		return
	end

	if (groupName == "Cooldowns" or groupName == "Utilities") and slotIndex then
		if math.floor(slotIndex) == slotIndex then
			return -- Prevent dropping onto integer/default slots for these groups
		end
	end

	-- Helper: route to append, replace-state, or replace-slot.
	-- A drop on the slot body (no stateIndex, not isAppend) used to nuke every
	-- existing state. That's destructive without confirmation, so when the
	-- slot already has states we append instead — only an empty slot gets the
	-- single-action replace path.
	local function applyAction(actionType, actionValue, category, extra)
		if isAppend then
			Wise:AddAction(groupName, slotIndex, actionType, actionValue, category, extra)
			Wise:UpdateGroupDisplay(groupName)
			Wise:UpdateOptionsUI()
		elseif stateIndex then
			Wise:ReplaceStateAction(groupName, slotIndex, stateIndex, actionType, actionValue, category, extra)
		else
			local group = WiseDB.groups[groupName]
			local existing = group and group.actions and group.actions[slotIndex]
			if luaType(existing) == "table" and #existing > 0 then
				Wise:AddAction(groupName, slotIndex, actionType, actionValue, category, extra)
				Wise:UpdateGroupDisplay(groupName)
				Wise:UpdateOptionsUI()
			else
				Wise:ReplaceSlotAction(groupName, slotIndex, actionType, actionValue, category, extra)
			end
		end
	end

	if type == "spell" then
		-- Standard GetCursorInfo for spell: "spell", slotIndex, bookType, spellID
		local _, bookSlot, bookType, spellID = GetCursorInfo()

		local finalSpellID = spellID

		if not finalSpellID and bookSlot then
			if C_SpellBook and C_SpellBook.GetSpellBookItemInfo then
				local bank = Enum.SpellBookSpellBank.Player
				if bookType == "pet" or bookType == BOOKTYPE_PET or bookType == Enum.SpellBookSpellBank.Pet then
					bank = Enum.SpellBookSpellBank.Pet
				end
				local info = C_SpellBook.GetSpellBookItemInfo(bookSlot, bank)
				if info then
					finalSpellID = info.spellID
				end
			elseif GetSpellInfo then
				local _, _, _, _, _, _, sID = GetSpellInfo(bookSlot, bookType)
				finalSpellID = sID
			end
		end

		if finalSpellID then
			-- Categorize the spell by scanning the spellbook for its skill line
			local category, sourceSpecID = Wise:ResolveSpellCategory(finalSpellID)
			local extra = {}
			if sourceSpecID then
				extra.sourceSpecID = sourceSpecID
			end
			applyAction("spell", finalSpellID, category, extra)
			ClearCursor()
		end
	elseif type == "item" then
		applyAction("item", id)
		ClearCursor()
	elseif type == "macro" then
		local name = GetMacroInfo(id)
		if name then
			applyAction("macro", name)
			ClearCursor()
		end
	elseif type == "mount" then
		applyAction("mount", id)
		ClearCursor()
	elseif type == "battlepet" then
		applyAction("battlepet", id)
		ClearCursor()
	elseif type == "equipmentset" then
		local name = C_EquipmentSet.GetEquipmentSetInfo(id)
		if name then
			applyAction("equipmentset", name)
			ClearCursor()
		end
	end
end

-- ============================================================================
-- Drag and Drop Highlighting
-- ============================================================================

function Wise:StartDragHighlight()
	-- Only if not in combat (secure frames cannot be modified in combat)
	if InCombatLockdown() then
		return
	end
	if WiseDB.settings.enableDragDrop == false then
		return
	end

	Wise.isDragging = true

	for groupName, f in pairs(Wise.frames) do
		if f:IsShown() and f.buttons then
			for _, btn in ipairs(f.buttons) do
				if btn:IsShown() and not (WiseDB.groups[groupName] and WiseDB.groups[groupName].isLocked) then
					local skipHighlight = false
					if (groupName == "Cooldowns" or groupName == "Utilities") and btn.slot then
						if math.floor(btn.slot) == btn.slot then
							skipHighlight = true
						end
					end
					if not skipHighlight then
						if WiseDB.groups[groupName] and WiseDB.groups[groupName].type == "list" and btn.icon then
							Wise:ShowOverlayGlow(btn, btn.icon)
						else
							Wise:ShowOverlayGlow(btn)
						end
					end
				end
			end
		end
	end

	-- Options Interface Highlight
	if
		Wise.OptionsFrame
		and Wise.OptionsFrame:IsShown()
		and Wise.OptionsFrame.Middle
		and Wise.OptionsFrame.Middle.Content
		and Wise.OptionsFrame.Middle.Content.slots
	then
		local isRestrictedGroup = (Wise.selectedGroup == "Cooldowns" or Wise.selectedGroup == "Utilities")
		for _, slot in ipairs(Wise.OptionsFrame.Middle.Content.slots) do
			if slot:IsShown() then
				local isRestrictedSlot = isRestrictedGroup and slot.slotID and (math.floor(slot.slotID) == slot.slotID)

				if not isRestrictedSlot then
					if slot.ActionButtons then
						for _, btn in ipairs(slot.ActionButtons) do
							if btn:IsShown() then
								Wise:ShowOverlayGlow(btn)
							end
						end
					end
					if slot.AddStateBtn and slot.AddStateBtn:IsShown() then
						Wise:ShowOverlayGlow(slot.AddStateBtn)
					end
				end
			end
		end
	end
end

function Wise:StopDragHighlight()
	Wise.isDragging = false

	-- Clear glows from all buttons
	-- Note: This might clear legitimate proc glows too!
	-- We should perhaps only clear if we instigated it, or just refresh usability after drop.

	for groupName, f in pairs(Wise.frames) do
		if f.buttons then
			for _, btn in ipairs(f.buttons) do
				-- Check if this button actually has a proc? If so, don't hide.
				-- For simplicity, hide all, then trigger usability update to restore procs.
				Wise:HideOverlayGlow(btn)
			end
		end
	end

	-- Options Interface Highlight Removal
	if
		Wise.OptionsFrame
		and Wise.OptionsFrame:IsShown()
		and Wise.OptionsFrame.Middle
		and Wise.OptionsFrame.Middle.Content
		and Wise.OptionsFrame.Middle.Content.slots
	then
		for _, slot in ipairs(Wise.OptionsFrame.Middle.Content.slots) do
			if slot:IsShown() then
				-- Restore selected color or default
				if Wise.selectedSlot == slot.slotID then
					slot:SetBackdropBorderColor(1, 0.8, 0, 1) -- Gold Selected
				else
					slot:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
				end

				if slot.ActionButtons then
					for _, btn in ipairs(slot.ActionButtons) do
						if btn:IsShown() then
							Wise:HideOverlayGlow(btn)
						end
					end
				end
				if slot.AddStateBtn and slot.AddStateBtn:IsShown() then
					Wise:HideOverlayGlow(slot.AddStateBtn)
				end
			end
		end
	end

	-- Restore legitimate proc glows
	C_Timer.After(0.1, function()
		Wise:UpdateAllUsability()
	end)
end

-- Record that a Wise button was just pressed. Any cursor change immediately
-- following is attributed to that button's own action (e.g. a spell-targeting
-- macro picking an item up) rather than to the user starting a drag.
function Wise:NoteButtonAction()
	Wise._lastButtonActionAt = GetTime()
end

-- Drag Tracker Frame
local dragTracker = CreateFrame("Frame")
dragTracker:RegisterEvent("CURSOR_CHANGED")
dragTracker:SetScript("OnEvent", function(self, event)
	if InCombatLockdown() then
		return
	end

	local cursorType = GetCursorInfo()
	if cursorType then
		-- Distinguish a genuine user drag from a cursor our OWN button action
		-- loaded. Spell-targeting macros ("/cast Disenchant" + "/use <bag>
		-- <slot>") pick the item up as part of casting; treating that as a drag
		-- makes the next press drop the item into the bar.
		--
		-- Wise:NoteButtonAction() stamps a timestamp on every Wise button press,
		-- so a CURSOR_CHANGED landing in that window is attributed to our own
		-- action rather than to the user.
		local lastAction = Wise._lastButtonActionAt or 0
		local selfInflicted = (GetTime() - lastAction) < 0.5
		Wise.userDragActive = not selfInflicted

		-- Cursor has something tracked
		Wise:StartDragHighlight()
	else
		Wise.userDragActive = false
		Wise:StopDragHighlight()
	end
end)
