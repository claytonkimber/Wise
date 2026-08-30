local addonName, Wise = ...

-- ============================================================================
-- Tooltip Module
-- Handles generic and Wise-specific tooltip logic
-- ============================================================================

-- Generic Tooltip Helper
-- Adds a static text tooltip to any frame
function Wise:AddTooltip(frame, text, anchor)
	if not frame then
		return
	end

	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
		GameTooltip:SetText(text, nil, nil, nil, nil, true)
		GameTooltip:Show()
	end)

	frame:HookScript("OnLeave", function(self)
		GameTooltip:Hide()
	end)
end

-- Interface Tooltip Logic
-- Dynamically shows tooltip based on button content (spell, item, macro, etc.)
-- Respects the 'showTooltips' setting

-- Populate a tooltip for an action record / metadata.
-- Returns true if the tooltip was populated, false if empty or unhandled.
function Wise:PopulateActionTooltip(tooltip, owner, actionType, actionValue, actionData, meta)
	if not tooltip or not owner then
		return false
	end

	-- Empty slots are invisible space maintainers — no tooltip
	if actionType == "empty" then
		return false
	end

	-- Custom tooltip function on the action data
	if actionData and actionData.tooltipFunc then
		local ok = pcall(actionData.tooltipFunc, actionValue)
		if ok then
			return true
		end
	end

	-- Module-supplied tooltip. An action can carry `tooltipProvider`, the name
	-- of a handler registered via Wise:RegisterTooltipProvider. This lets a
	-- generated slot describe what it will actually DO (e.g. the queue of items
	-- a Disenchant slot will work through) instead of the raw spell tooltip its
	-- secure type implies. The provider owns the whole tooltip when it returns
	-- true; returning false falls through to the normal type dispatch.
	local providerName = actionData and actionData.tooltipProvider
	if providerName and Wise.TooltipProviders and Wise.TooltipProviders[providerName] then
		local ok, handled = pcall(Wise.TooltipProviders[providerName], tooltip, owner, actionData, meta)
		if ok and handled then
			return true
		end
	end

	local type = actionType
	local value = actionValue
	local data = actionData

	if type == "action" then
		local aID = tonumber(value)
		if aID then
			local realID = Wise:ResolveBarActionID(aID)
			tooltip:SetAction(realID)
		else
			tooltip:SetText("Unknown Action", 1, 1, 1)
		end
		return true
	elseif type == "spell" then
		local spellID = (meta and meta.spellID)

		if not spellID then
			if tonumber(value) then
				spellID = Wise:GetOverrideSpellID(tonumber(value)) or tonumber(value)
			else
				local overrideValue = Wise:GetOverrideSpellID(value) or value
				local info = C_Spell.GetSpellInfo(overrideValue)
				if info then
					spellID = info.spellID
				end
			end
		end

		if spellID then
			tooltip:SetSpellByID(spellID)
		else
			tooltip:SetText(value or "Unknown Spell", 1, 1, 1)
		end
		return true
	elseif type == "item" or type == "toy" then
		local itemID = (meta and meta.itemID)
		if not itemID then
			itemID = tonumber(value)
		end

		if itemID then
			tooltip:SetItemByID(itemID)
		else
			-- Try hyperlink or name
			local link = select(2, C_Item.GetItemInfo(value))
			if link then
				tooltip:SetHyperlink(link)
			else
				tooltip:SetText(value or "Unknown Item", 1, 1, 1)
			end
		end
		return true
	elseif type == "macro" then
		local title = (data and data.customName) or (data and data.name) or (meta and meta.name)
		if _G.type(value) == "string" and string.sub(value, 1, 1) == "/" then
			tooltip:SetText(title or "Macro", 1, 1, 1)
		elseif value == nil or value == "" then
			-- An Addons slot with no command assigned yet. Name the addon and
			-- say what to do about it rather than printing "Macro: nil".
			tooltip:SetText(title or "Unassigned", 1, 1, 1)
			tooltip:AddLine("No command assigned", 1, 0.5, 0.5)
			tooltip:AddLine("Click to choose a command for this addon.", 0.8, 0.8, 0.8, true)
		else
			tooltip:SetText(title or ("Macro: " .. tostring(value)), 1, 1, 1)
			local _, _, body = GetMacroInfo(value)
			if body then
				tooltip:AddLine(body, 0.8, 0.8, 0.8, true)
			end
		end
		return true
	elseif type == "custom_macro" then
		tooltip:SetText("Custom Macro", 1, 1, 1)
		if data and data.macroText then
			tooltip:AddLine(data.macroText, 0.8, 0.8, 0.8, true)
		end
		return true
	elseif type == "mount" then
		local mountID = tonumber(value)
		if C_MountJournal and mountID then
			local name, spellID, _, _, _, _, _, _, _, _, isCollected = C_MountJournal.GetMountInfoByID(mountID)
			if spellID then
				tooltip:SetSpellByID(spellID)
			else
				tooltip:SetText(name or "Mount " .. mountID, 1, 1, 1)
			end

			if isCollected ~= nil then
				if isCollected then
					tooltip:AddLine("Collected", 0, 1, 0)
				else
					tooltip:AddLine("Not Collected", 1, 0, 0)
				end
			end
		else
			tooltip:SetText("Mount: " .. tostring(value), 1, 1, 1)
		end
		return true
	elseif type == "battlepet" then
		tooltip:SetText("Pet: " .. tostring(value), 1, 1, 1)
		return true
	elseif type == "equipmentset" then
		tooltip:SetText("Equipment Set: " .. tostring(value), 1, 1, 1)
		return true
	elseif type == "interface" then
		tooltip:SetText("Open Interface: " .. tostring(value), 1, 0.82, 0)
		return true
	elseif type == "uipanel" then
		local label = tostring(value):gsub("^%l", string.upper) -- Capitalize
		tooltip:SetText("Toggle " .. label, 1, 1, 1)
		return true
	elseif type == "misc" then
		local hasAction = false
		if value == "custom_macro" then
			-- Multi-action / graph slot: resolve the live (per-character) macro to
			-- the spell/item/action it currently evaluates to so the tooltip shows
			-- the real ability instead of the literal "custom_macro" placeholder.
			local mText = (data and data.macroText) or (meta and meta.actionData and meta.actionData.macroText)
			local rType, rVal = Wise:ResolveMacroData(mText)
			if rType == "spell" and rVal then
				tooltip:SetSpellByID(rVal)
				hasAction = true
			elseif rType == "item" and rVal then
				tooltip:SetItemByID(rVal)
				hasAction = true
			elseif rType == "action" and rVal then
				tooltip:SetAction(Wise:ResolveBarActionID(rVal))
				hasAction = true
			end
			if not hasAction then
				-- Nothing resolvable (e.g. all lines off-spec / off-cooldown gated,
				-- or an override/possess-bar compiled step while no such bar is
				-- active, like [flying] slot 1 with no vehicle/override bar up).
				-- The button itself falls back to the "?" placeholder icon in this
				-- state (see GUI.lua isPlaceholderIcon); mirror that here: nothing
				-- meaningful in the slot means no tooltip, instead of dumping the
				-- internal compiled macro source at the player.
				local hasCustomName = data and data.name and data.name ~= "" and data.name ~= "Empty"
				if hasCustomName then
					tooltip:SetText(data.name, 1, 1, 1)
					hasAction = true
				else
					return false
				end
			end
		elseif value == "extrabutton" and data and data.showTooltip then
			if HasExtraActionBar and HasExtraActionBar() then
				tooltip:SetAction(Wise.EXTRA_ACTION_BUTTON_SLOT)
				hasAction = true
			end
		elseif value == "zoneability" and data and data.showTooltip then
			local zoneBtn = Wise:GetZoneAbilitySpellButton()
			if zoneBtn and zoneBtn.spellID then
				tooltip:SetSpellByID(zoneBtn.spellID)
				hasAction = true
			end
		elseif value == "overridebar" and data and data.showTooltip then
			-- Per-button: resolve THIS slot's override button, not always button 1.
			local realID = Wise:ResolveMiscBarActionID(meta, 133)
			if
				(HasOverrideActionBar and HasOverrideActionBar())
				or (HasVehicleActionBar and HasVehicleActionBar())
				or (HasTempShapeshiftActionBar and HasTempShapeshiftActionBar())
			then
				tooltip:SetAction(realID)
				hasAction = true
			end
		elseif value == "possessbar" and data and data.showTooltip then
			local realID = Wise:ResolveMiscBarActionID(meta, 121)
			if
				(HasOverrideActionBar and HasOverrideActionBar())
				or (HasVehicleActionBar and HasVehicleActionBar())
				or (HasTempShapeshiftActionBar and HasTempShapeshiftActionBar())
			then
				tooltip:SetAction(realID)
				hasAction = true
			end
		end
		if not hasAction then
			local label = value
			if value == "hearthstone" then
				label = "Hearthstone"
			elseif value == "extrabutton" then
				label = "Extra Action Button"
			elseif value == "zoneability" then
				label = "Zone Ability"
			elseif value == "overridebar" then
				label = "Override Bar"
			elseif value == "possessbar" then
				label = "Possess Bar"
			elseif value == "leave_vehicle" then
				label = "Leave Vehicle"
			elseif tostring(value):match("^spec_") then
				local val = tonumber(tostring(value):match("^spec_(%d+)"))
				local name
				if val then
					if val <= 10 then
						local _, sName = GetSpecializationInfo(val)
						name = sName
					elseif GetSpecializationInfoByID then
						local _, sName = GetSpecializationInfoByID(val)
						name = sName
					end
				end
				label = "Activate " .. (name or ("Spec " .. (val or "?")))
			elseif tostring(value):match("^lootspec_") then
				local id = tonumber(tostring(value):match("^lootspec_(%d+)"))
				local name
				if id and GetSpecializationInfoByID then
					_, name = GetSpecializationInfoByID(id)
				end
				label = "Set Loot Spec: " .. (name or (id or "?"))
			elseif tostring(value):match("^addon_magic_") then
				local amIdx = tonumber(tostring(value):match("^addon_magic_(%d+)"))
				if amIdx and WiseDB.addonMagicSlots and WiseDB.addonMagicSlots[amIdx] then
					local slot = WiseDB.addonMagicSlots[amIdx]
					label = slot.name or ("Slot " .. amIdx)
					tooltip:SetText(label, 1, 0.82, 0)
					local count = slot.addons and #slot.addons or 0
					if count == 0 then
						tooltip:AddLine("No addons selected", 0.6, 0.6, 0.6)
					elseif count == 1 then
						tooltip:AddLine("1 addon", 0.8, 0.8, 0.8)
					else
						tooltip:AddLine(count .. " addons", 0.8, 0.8, 0.8)
					end

					local amState, amMissing = Wise:GetAddonMagicSlotState(amIdx)
					if amState == "loaded" then
						tooltip:AddLine(" ")
						tooltip:AddLine("Loaded — click to unload and reload", 0.4, 1, 0.4)
						tooltip:AddLine("Any other reload also unloads it.", 0.6, 0.6, 0.6)
						if amMissing then
							tooltip:AddLine(" ")
							tooltip:AddLine("Uninstalled since loading:", 1, 0.2, 0.2)
							for _, a in ipairs(amMissing) do
								tooltip:AddLine("  " .. a, 1, 0.4, 0.4)
							end
						end
					elseif amState == "missing" then
						tooltip:AddLine(" ")
						tooltip:AddLine("Not installed:", 1, 0.2, 0.2)
						for _, a in ipairs(amMissing) do
							tooltip:AddLine("  " .. a, 1, 0.4, 0.4)
						end
						tooltip:AddLine("Edit this slot to remove them.", 0.6, 0.6, 0.6)
					elseif amState == "unloaded" then
						tooltip:AddLine(" ")
						tooltip:AddLine("Click to load and reload", 0.8, 0.8, 0.8)
					end
					hasAction = true
				else
					label = "Addon Magic Slot"
				end
			end

			if not hasAction then
				tooltip:SetText(label, 1, 1, 1)
			end
		end
		return true
	elseif value ~= nil then
		-- Fallback
		tooltip:SetText(tostring(value), 1, 1, 1)
		return true
	end

	return false
end

-- Show a tooltip on GameTooltip for any UI owner frame
function Wise:ShowActionTooltip(owner, actionType, actionValue, actionData, anchor, meta)
	if not owner then
		return
	end
	GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
	local shown = Wise:PopulateActionTooltip(GameTooltip, owner, actionType, actionValue, actionData, meta)
	if shown then
		GameTooltip:Show()
	else
		GameTooltip:Hide()
	end
end

function Wise:AddInterfaceTooltip(btn)
	if not btn then
		return
	end

	btn:HookScript("OnEnter", function(self)
		-- Check setting
		if not WiseDB.settings.showTooltips then
			return
		end

		-- Empty slots are invisible space maintainers — no tooltip
		if self.actionType == "empty" then
			return
		end

		-- Prioritize Metadata (Reliable cache from GUI.lua)
		local meta = Wise.buttonMeta and Wise.buttonMeta[self]
		local type = (meta and meta.actionType) or self.actionType
		local value = (meta and meta.actionValue) or self.actionValue
		local data = (meta and meta.actionData) or self.actionData

		Wise:ShowActionTooltip(self, type, value, data, "ANCHOR_CURSOR", meta)
	end)

	btn:HookScript("OnLeave", function(self)
		GameTooltip:Hide()
	end)
end

-- Register a named tooltip handler that actions can opt into via
-- actionData.tooltipProvider. The handler receives (tooltip, button, actionData,
-- meta) and returns true when it has fully populated the tooltip itself.
Wise.TooltipProviders = Wise.TooltipProviders or {}

function Wise:RegisterTooltipProvider(name, fn)
	Wise.TooltipProviders[name] = fn
end

function Wise:InitTooltips()
	-- Placeholder for any tooltip-specific initialization
	-- (e.g. hooking GameTooltip if needed, though usually not required)
end
