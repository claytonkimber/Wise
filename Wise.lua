local addonName, addon = ...
Wise = addon

-- Core Globals/Utilities
local _G = _G
local date = date
local ipairs = ipairs
local pairs = pairs
local print = print
local select = select
local string = string
local table = table
local type = type
local unpack = unpack
local tonumber = tonumber
local tostring = tostring

-- WoW APIs
local C_AddOns = C_AddOns
local C_ClassTalents = C_ClassTalents
local C_CooldownViewer = C_CooldownViewer
local C_Item = C_Item
local C_Macro = C_Macro
local C_Spell = C_Spell
local C_Timer = C_Timer
local C_TradeSkillUI = C_TradeSkillUI
local C_Traits = C_Traits
local CreateFrame = CreateFrame
local GetBindingKey = GetBindingKey
local GetCursorPosition = GetCursorPosition
local GetMacroInfo = GetMacroInfo
local GetNumSpecializations = GetNumSpecializations
local GetProfessionInfo = GetProfessionInfo
local GetProfessions = GetProfessions
local GetRealmName = GetRealmName
local GetSpecialization = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local StaticPopupDialogs = StaticPopupDialogs
local StaticPopup_Show = StaticPopup_Show
local UnitClass = UnitClass
local UnitName = UnitName

Wise.characterInfo = {}

-- No-op fallback so calls to DebugPrint never error if Debug.lua isn't loaded
if not Wise.DebugPrint then
	function Wise:DebugPrint() end
end

function Wise:GetOverrideSpellID(spellID)
	if not spellID then
		return nil
	end
	if type(spellID) == "string" then
		local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
		if info and info.spellID then
			spellID = info.spellID
		else
			return spellID
		end
	end
	-- Taint-strip: Blizzard's C_Spell.GetOverrideSpell / FindSpellOverrideByID can
	-- return tainted numbers post-combat. tonumber(n) on a number is identity, so
	-- we route through tostring→tonumber to force a fresh, untainted value that is
	-- safe to use as a table key or in comparisons.
	if C_Spell and C_Spell.GetOverrideSpell then
		local ok, result = pcall(C_Spell.GetOverrideSpell, spellID)
		if ok and result then
			return tonumber(tostring(result)) or spellID
		end
		return spellID
	elseif FindSpellOverrideByID then
		local result = FindSpellOverrideByID(spellID)
		if result then
			return tonumber(tostring(result)) or spellID
		end
		return spellID
	end
	return spellID
end

-- Update Function - Core Info
function Wise:UpdateCharacterInfo(sourceEvent)
	local _, className = UnitClass("player")
	self.characterInfo.class = className

	local specIndex = GetSpecialization()
	if specIndex then
		local specID, _, _, _, role = GetSpecializationInfo(specIndex)
		self.characterInfo.specID = specID
		self.characterInfo.role = role
	end

	-- Get active talent loadout name
	if C_ClassTalents and C_ClassTalents.GetActiveConfigID then
		if C_ClassTalents.GetStarterBuildActive and C_ClassTalents.GetStarterBuildActive() then
			self.characterInfo.talentBuild = "Starter Build"
		else
			local specID = GetSpecialization()
			local specInfoID = specID and GetSpecializationInfo(specID)
			local configID = C_ClassTalents.GetLastSelectedSavedConfigID
				and specInfoID
				and C_ClassTalents.GetLastSelectedSavedConfigID(specInfoID)

			if not configID then
				configID = C_ClassTalents.GetLastSelectedConfigID
					and specInfoID
					and C_ClassTalents.GetLastSelectedConfigID(specInfoID)
			end

			-- Fallback to currently active config ID if no last selected ID found
			if not configID then
				configID = C_ClassTalents.GetActiveConfigID()
			end

			if configID then
				local configInfo = C_Traits.GetConfigInfo(configID)
				if configInfo and configInfo.name then
					self.characterInfo.talentBuild = configInfo.name
				end
			end
		end
	end

	-- Update Wiser Interfaces whenever character info changes (e.g. spec change updates Specs list)
	if Wise.UpdateWiserInterfaces then
		local isSpecChange = (sourceEvent == "PLAYER_SPECIALIZATION_CHANGED")
		Wise:UpdateWiserInterfaces(isSpecChange)
	end
end

-- Force-refresh all displays, cooldowns, usability, and visual state.
-- Called after spec changes and deferred talent loadouts to ensure nothing is stale.
function Wise:ForceRefreshAllDisplays()
	if InCombatLockdown() then
		return
	end

	-- Re-sync cooldown/utility wiser groups from Blizzard's viewer frames
	if Wise.UpdateCooldownWiser then
		if WiseDB.groups["Cooldowns"] then
			local viewerName = WiseDB.groups["Cooldowns"].viewerName or "EssentialCooldownViewer"
			Wise:UpdateCooldownWiser("Cooldowns", viewerName)
		end
		if WiseDB.groups["Utilities"] then
			local viewerName = WiseDB.groups["Utilities"].viewerName or "UtilityCooldownViewer"
			Wise:UpdateCooldownWiser("Utilities", viewerName)
		end
	end

	-- Rebuild all group displays
	if WiseDB and WiseDB.groups then
		for name, _ in pairs(WiseDB.groups) do
			if Wise.UpdateGroupDisplay then
				Wise:UpdateGroupDisplay(name)
			end
		end
	end

	-- Refresh all real-time visual state
	if Wise.UpdateAllOverrideIcons then
		Wise:UpdateAllOverrideIcons()
	end
	if Wise.UpdateAllCooldowns then
		Wise:UpdateAllCooldowns()
	end
	if Wise.UpdateAllCharges then
		Wise:UpdateAllCharges()
	end
	if Wise.UpdateAllUsability then
		Wise:UpdateAllUsability()
	end
	if Wise.UpdateAllStates then
		Wise:UpdateAllStates()
	end
	if Wise.UpdateInterfaceIcons then
		Wise:UpdateInterfaceIcons()
	end
end

-- IsGroupAvailable (Needs to be early for updates)
function Wise:IsGroupAvailable(groupName)
	local group = WiseDB.groups[groupName]
	if not group then
		return false
	end

	-- Wiser Interfaces: Always available (visibility controlled by easy/hard mode settings)
	-- Must be checked FIRST, before enabled/availability, because Wiser groups may have
	-- enabled=false (legacy default) or availability.mode="NONE" (from Properties migration)
	-- that would incorrectly mark them unavailable.
	if group.isWiser then
		if groupName == "Forms" then
			local numForms = GetNumShapeshiftForms()
			return numForms and numForms > 0
		end
		return true
	end

	-- If no availability struct (e.g. custom groups or old version), default to enabled/true
	if not group.availability then
		-- respecting old 'enabled' flag if present, otherwise true
		if group.enabled ~= nil then
			return group.enabled
		end
		return true
	end

	local avail = group.availability
	if avail.mode == "ALL" then
		return true
	elseif avail.mode == "NONE" then
		return false
	else
		-- Check per-character
		local key = UnitName("player") .. "-" .. GetRealmName()
		return avail.characters[key] == true
	end
end

-- Helper: check if a specific string exists in an array
local function Contains(tbl, val)
	if not tbl then
		return false
	end
	for _, v in ipairs(tbl) do
		if v == val then
			return true
		end
	end
	return false
end

-- Helper: check if the current character matches a specific restriction tag
function Wise:MatchesRestrictionTag(tag)
	if not tag then
		return false
	end

	if tag == "global" then
		return true
	elseif tag == "role:TANK" then
		return self.characterInfo.role == "TANK"
	elseif tag == "role:HEALER" then
		return self.characterInfo.role == "HEALER"
	elseif tag == "role:DAMAGER" then
		return self.characterInfo.role == "DAMAGER"
	elseif tag:match("^class:") then
		local reqClass = tag:sub(7)
		return self.characterInfo.class == reqClass
	elseif tag:match("^spec:") then
		local reqSpec = tonumber(tag:sub(6))
		return self.characterInfo.specID == reqSpec
	elseif tag:match("^talent:") then
		local reqTalent = tonumber(tag:sub(8))
		return IsPlayerSpell(reqTalent) or IsSpellKnownOrOverridesKnown(reqTalent)
	elseif tag:match("^char:") then
		local reqChar = tag:sub(6)
		local charKey = UnitName("player") .. "-" .. GetRealmName()
		return charKey == reqChar
	end
	return false
end

function Wise:IsActionAllowed(action)
	local enables = action.visibilityEnable or {}
	local disables = action.visibilityDisable or {}
	local isAllowed = false

	-- If there are ANY enables, default to false. Must match one to become true.
	-- If NO enables, default to true.
	if #enables > 0 then
		-- Group enables by prefix
		local catEnables = {}
		for _, tag in ipairs(enables) do
			local prefix = tag:match("^([^:]+):") or tag
			catEnables[prefix] = catEnables[prefix] or {}
			table.insert(catEnables[prefix], tag)
		end

		isAllowed = true
		for prefix, tags in pairs(catEnables) do
			local prefixMatched = false

			if prefix == "global" then
				prefixMatched = true
			else
				for _, tag in ipairs(tags) do
					if self:MatchesRestrictionTag(tag) then
						prefixMatched = true
						break
					end
				end
			end

			if not prefixMatched then
				isAllowed = false
				break
			end
		end
	else
		isAllowed = true
	end

	-- If allowed so far, check disables. Any match makes it false.
	if isAllowed and #disables > 0 then
		for _, tag in ipairs(disables) do
			if self:MatchesRestrictionTag(tag) then
				isAllowed = false
				break
			end
		end
	end

	return isAllowed
end

-- Helper: Check if interface is "Disabled" (no user-configured visibility settings)
-- Nested children whose only visibility comes from nesting inheritance are still disabled.
function Wise:IsGroupDisabled(group, groupName)
	if not group then
		return true
	end
	local s = group.visibilitySettings and group.visibilitySettings.customShow
	local h = group.visibilitySettings and group.visibilitySettings.customHide
	local held = group.visibilitySettings and group.visibilitySettings.held
	local toggle = group.visibilitySettings and group.visibilitySettings.toggleOnPress

	local hasS = (s and s ~= "")
	local hasH = (h and h ~= "")

	if not hasS and not hasH and not held and not toggle then
		return true
	end

	-- If toggle is the only setting and this is a nested child, it was inherited — treat as disabled
	if toggle and not hasS and not hasH and not held and groupName then
		local parentName = Wise:GetParentInfo(groupName)
		if parentName then
			return true
		end
	end

	return false
end

function Wise:ShouldLoadAction(action, group)
	-- If not dynamic, load all actions
	if not group.dynamic then
		return true
	end

	return self:IsActionAllowed(action)
end

function Wise:GetFilteredActions(group)
	local filtered = {}
	for i, action in ipairs(group.buttons) do
		if Wise:ShouldLoadAction(action, group) then
			table.insert(filtered, { index = i, action = action })
		end
	end
	return filtered
end

-- Update Wiser Interfaces
function Wise:UpdateWiserInterfaces(isSpecChange)
	if not WiseDB or not WiseDB.groups then
		return
	end

	-- Helper to ensure group exists with Wiser flag
	local function EnsureWiserGroup(name, defaultType, defaults)
		local created = false
		if not WiseDB.groups[name] then
			Wise:CreateGroup(name, defaultType or "circle")
			WiseDB.groups[name].enabled = false -- Default to unchecked for Wiser interfaces
			created = true
		end
		local g = WiseDB.groups[name]

		if created and defaults then
			if type(defaults) == "function" then
				defaults(g)
			else
				for k, v in pairs(defaults) do
					g[k] = v
				end
			end
		end

		-- Migration: Force Menu Bar defaults if not already migrated
		if name == "Menu Bar" and not g.migrated_defaults_v1 then
			if defaults then
				if type(defaults) == "function" then
					defaults(g)
				else
					for k, v in pairs(defaults) do
						g[k] = v
					end
				end
			end
			g.migrated_defaults_v1 = true
		end

		-- Migration: Force Cooldowns/Utilities to box layout if not already migrated
		if (name == "Cooldowns" or name == "Utilities") and not g.migrated_box_v1 then
			if defaults then
				if type(defaults) == "function" then
					defaults(g)
				else
					for k, v in pairs(defaults) do
						g[k] = v
					end
				end
			end
			g.migrated_box_v1 = true
		end

		-- Migration: Spec and Equipment Changer must NOT be dynamic.
		-- An earlier build set dynamic=true (migrated_dynamic_v1) to get per-slot class
		-- filtering, but dynamic groups break the [undermouse] show path so the panel never
		-- appeared on hover. Class filtering is handled by per-button visibilityEnable tags
		-- instead. This corrective migration (v2) clears the stale dynamic flag.
		if name == "Spec and Equipment Changer" and not g.migrated_dynamic_v2 then
			g.dynamic = false
			g.migrated_dynamic_v2 = true
		end

		g.isWiser = true -- Mark as Wiser
		if name ~= "Cooldowns" and name ~= "Utilities" and name ~= "Spec and Equipment Changer" then
			g.buttons = {} -- Clear for rebuild
			g.actions = nil -- Clear actions to force migration from new buttons list
			g.migratedToActions = nil -- Allow re-migration from fresh buttons
		end

		-- Store metadata for context (helper for debugging/future features)
		local _, className = UnitClass("player")
		g.class = className
		g.specID = GetSpecializationInfo(GetSpecialization())

		return g
	end

	-- 1. Professions
	local profGroup = EnsureWiserGroup("Professions", "circle")
	local profs = { GetProfessions() } -- prof1, prof2, arch, fish, cook
	for _, index in ipairs(profs) do
		if index then
			local name, icon, _, _, _, _, skillLine, _, _, _ = GetProfessionInfo(index)
			if name and skillLine then
				-- Generate toggle macro
				local macroText = string.format(
					"/run local i=C_TradeSkillUI.GetBaseProfessionInfo(); if i and i.professionID==%d then C_TradeSkillUI.CloseTradeSkill() else C_TradeSkillUI.OpenTradeSkill(%d) end",
					skillLine,
					skillLine
				)

				table.insert(profGroup.buttons, {
					type = "macro",
					value = macroText,
					name = name, -- Store name for tooltip/display
					icon = icon, -- Explicit icon since macro won't have it by default
					category = "global",
				})
			end
		end
	end
	-- Trigger display update if this group is active/shown
	if Wise.frames["Professions"] and Wise.frames["Professions"]:IsShown() then
		Wise:UpdateGroupDisplay("Professions")
	end

	-- 2. Menu Bar
	local menuGroup = EnsureWiserGroup("Menu Bar", "circle", { iconSize = 28, textSize = 12, padding = 7 })
	-- Menu, Shop, Adventure Guide, Warband Collections, Group Finder, Guild & Communities, Housing Dashboard, Quest Log, Achievements, Spellbook, Talents, Professions, Character Info
	local menuItems = {
		{ type = "uipanel", value = "menu" },
		{ type = "uipanel", value = "shop" },
		{ type = "uipanel", value = "adventureguide" },
		{ type = "uipanel", value = "collections" },
		{ type = "uipanel", value = "groupfinder" },
		{ type = "uipanel", value = "guild" },
		{ type = "uipanel", value = "housing" },
		{ type = "uipanel", value = "questlog" },
		{ type = "uipanel", value = "achievements" },
		{ type = "uipanel", value = "talents" },
		{ type = "uipanel", value = "professions" },
		{ type = "uipanel", value = "character" },
	}
	for _, item in ipairs(menuItems) do
		table.insert(menuGroup.buttons, {
			type = item.type,
			value = item.value,
			category = "global",
		})
	end
	if Wise.frames["Menu Bar"] and Wise.frames["Menu Bar"]:IsShown() then
		Wise:UpdateGroupDisplay("Menu Bar")
	end

	-- 3. Forms (Shapeshift / Stances)
	local formGroup = EnsureWiserGroup("Forms", "circle")
	local numForms = GetNumShapeshiftForms()
	if numForms and numForms > 0 then
		for i = 1, numForms do
			local icon, isActive, isCastable, spellID = GetShapeshiftFormInfo(i)
			if icon then
				local formName
				if spellID then
					local info = C_Spell.GetSpellInfo(spellID)
					formName = info and info.name
				end
				formName = formName or ("Form " .. i)
				table.insert(formGroup.buttons, {
					type = "misc",
					value = "form_" .. i,
					name = formName,
					icon = icon,
					category = "global",
				})
			end
		end
	end
	if Wise.frames["Forms"] then
		Wise:UpdateGroupDisplay("Forms")
	end

	-- 4. Specs
	local specGroup = EnsureWiserGroup("Specs", "circle")
	local numSpecs = GetNumSpecializations()
	local currentSpecIndex = GetSpecialization()

	for i = 1, numSpecs do
		if i ~= currentSpecIndex then
			local id, name, _, icon = GetSpecializationInfo(i)
			if id then
				table.insert(specGroup.buttons, {
					type = "misc",
					value = "spec_" .. i, -- Use Index for simpler macro
					name = name,
					icon = icon,
					category = "global",
				})
			end
		end
	end
	if Wise.frames["Specs"] and Wise.frames["Specs"]:IsShown() then
		Wise:UpdateGroupDisplay("Specs")
	end

	-- 5. Addon Loading Magic
	local amGroup = EnsureWiserGroup("Addon Loading Magic", "circle")
	WiseDB.addonMagicSlots = WiseDB.addonMagicSlots or {}
	for i, slot in ipairs(WiseDB.addonMagicSlots) do
		local slotName = slot.name or ("Slot " .. i)
		local addonCount = slot.addons and #slot.addons or 0
		local subText
		if addonCount == 0 then
			subText = "No addons selected"
		elseif addonCount == 1 then
			subText = slot.addons[1]
		else
			subText = addonCount .. " addons"
		end
		table.insert(amGroup.buttons, {
			type = "misc",
			value = "addon_magic_" .. i,
			name = slotName,
			icon = "Interface\\Icons\\INV_Misc_EngGizmos_11",
			category = "global",
		})
	end
	-- Immediately migrate buttons to actions so keybinds can be restored
	if Wise.MigrateGroupToActions then
		Wise:MigrateGroupToActions(amGroup)
	end
	amGroup.actions = amGroup.actions or {}
	-- Restore per-slot keybinds from canonical storage (WiseDB.addonMagicSlots)
	for i, slot in ipairs(WiseDB.addonMagicSlots) do
		if slot.keybind and slot.keybind ~= "" and amGroup.actions[i] then
			amGroup.actions[i].keybind = slot.keybind
		end
	end
	if Wise.frames["Addon Loading Magic"] and Wise.frames["Addon Loading Magic"]:IsShown() then
		Wise:UpdateGroupDisplay("Addon Loading Magic")
	end
	-- 6. Spec and Equipment Changer (persistent slots — only rebuild when slot count changes)
	-- NOTE: This group is intentionally NOT dynamic. Per-slot class filtering is handled by
	-- the "class:DRUID"-style visibilityEnable tags on each button (same mechanism the Specs
	-- interface uses). Making it dynamic breaks the [undermouse] show path, so the panel would
	-- never appear on hover (only "Always Show" would surface it).
	local specEquipGroup = EnsureWiserGroup("Spec and Equipment Changer", "circle")
	WiseDB.specEquipSlots = WiseDB.specEquipSlots or {}

	-- Check if rebuild is needed (slot count changed vs current buttons)
	local seNeedsRebuild = not specEquipGroup.actions
		or not specEquipGroup.buttons
		or #specEquipGroup.buttons ~= #WiseDB.specEquipSlots

	-- Also rebuild if any slot name/icon/class restriction changed
	if not seNeedsRebuild and specEquipGroup.buttons then
		for i, slot in ipairs(WiseDB.specEquipSlots) do
			local btn = specEquipGroup.buttons[i]
			local expectedCategory = slot.class and "class" or "global"
			local expectedIcon = slot.icon or "Interface\\Icons\\Inv_misc_gear_01"
			if not slot.icon and slot.specIndex then
				local _, _, _, specIcon = GetSpecializationInfo(slot.specIndex)
				if specIcon then
					expectedIcon = specIcon
				end
			end
			local hasClassEnable = false
			if btn and btn.visibilityEnable then
				for _, enableVal in ipairs(btn.visibilityEnable) do
					if slot.class and enableVal == "class:" .. slot.class then
						hasClassEnable = true
						break
					end
				end
			end
			if
				not btn
				or btn.name ~= (slot.name or ("Slot " .. i))
				or btn.icon ~= expectedIcon
				or btn.category ~= expectedCategory
				or (slot.class and not hasClassEnable)
				or (not slot.class and btn.visibilityEnable and #btn.visibilityEnable > 0)
			then
				seNeedsRebuild = true
				break
			end
		end
	end

	if seNeedsRebuild then
		specEquipGroup.buttons = {}
		specEquipGroup.actions = nil
		specEquipGroup.migratedToActions = nil

		for i, slot in ipairs(WiseDB.specEquipSlots) do
			local slotName = slot.name or ("Slot " .. i)

			-- Pick the best icon: stored > spec icon > default gear
			local slotIcon = slot.icon or "Interface\\Icons\\Inv_misc_gear_01"
			if not slot.icon and slot.specIndex then
				local _, _, _, specIcon = GetSpecializationInfo(slot.specIndex)
				if specIcon then
					slotIcon = specIcon
				end
			end

			local enables = {}
			local category = "global"
			if slot.class then
				table.insert(enables, "class:" .. slot.class)
				category = "class"
			end

			table.insert(specEquipGroup.buttons, {
				type = "misc",
				value = "spec_equip_" .. i,
				name = slotName,
				icon = slotIcon,
				category = category,
				visibilityEnable = enables,
			})
		end
		-- Migrate buttons to actions so keybinds can be restored
		if Wise.MigrateGroupToActions then
			Wise:MigrateGroupToActions(specEquipGroup)
		end
		specEquipGroup.actions = specEquipGroup.actions or {}
		-- Restore per-slot keybinds from canonical storage
		for i, slot in ipairs(WiseDB.specEquipSlots) do
			if slot.keybind and slot.keybind ~= "" and specEquipGroup.actions[i] then
				specEquipGroup.actions[i].keybind = slot.keybind
			end
		end
		if Wise.frames["Spec and Equipment Changer"] and Wise.frames["Spec and Equipment Changer"]:IsShown() then
			Wise:UpdateGroupDisplay("Spec and Equipment Changer")
		end
	end

	-- 7. Edit Mode Layouts
	local editModeGroup = EnsureWiserGroup("Edit Mode Layouts", "circle")
	-- Always include the two built-in presets
	table.insert(editModeGroup.buttons, {
		type = "uivisibility",
		value = "editmode:Modern",
		name = "Edit Mode: Modern",
		icon = "Interface\\Icons\\INV_Misc_EngGizmos_17",
		category = "global",
	})
	table.insert(editModeGroup.buttons, {
		type = "uivisibility",
		value = "editmode:Classic",
		name = "Edit Mode: Classic",
		icon = "Interface\\Icons\\INV_Misc_EngGizmos_17",
		category = "global",
	})
	-- Add all custom layouts
	if C_EditMode and C_EditMode.GetLayouts then
		local layoutInfo = C_EditMode.GetLayouts()
		if layoutInfo and layoutInfo.layouts then
			for _, layout in ipairs(layoutInfo.layouts) do
				if layout.layoutName then
					table.insert(editModeGroup.buttons, {
						type = "uivisibility",
						value = "editmode:" .. layout.layoutName,
						name = "Edit Mode: " .. layout.layoutName,
						icon = "Interface\\Icons\\INV_Misc_EngGizmos_17",
						category = "global",
					})
				end
			end
		end
	end
	if Wise.frames["Edit Mode Layouts"] and Wise.frames["Edit Mode Layouts"]:IsShown() then
		Wise:UpdateGroupDisplay("Edit Mode Layouts")
	end

	-- 8. Cooldowns (default: box layout, width 4, fixed anchor)
	local cooldownsGroup = EnsureWiserGroup("Cooldowns", "box", { type = "box", boxWidth = 4 })
	if Wise.UpdateCooldownWiser then
		Wise:UpdateCooldownWiser("Cooldowns", "EssentialCooldownViewer")
	end

	-- 9. Utilities (default: box layout, width 2, fixed anchor)
	local utilitiesGroup = EnsureWiserGroup("Utilities", "box", { type = "box", boxWidth = 2 })
	if Wise.UpdateCooldownWiser then
		Wise:UpdateCooldownWiser("Utilities", "UtilityCooldownViewer")
	end

	-- 9. Addons (Dynamic list of all Addon configurations and DataBroker plugins)
	local addonsGroup = EnsureWiserGroup("Addons", "circle")
	addonsGroup.isLocked = true -- Make it uneditable by the user
	addonsGroup.buttons = {} -- Clear previous buttons
	if Wise.GetAddons then
		local addonItems = Wise:GetAddons()
		for _, item in ipairs(addonItems) do
			table.insert(addonsGroup.buttons, item)
		end
	end
	if Wise.frames["Addons"] and Wise.frames["Addons"]:IsShown() then
		Wise:UpdateGroupDisplay("Addons")
	end

	-- Refresh Options UI if open to show new/updated groups
	if Wise.UpdateOptionsUI then
		Wise:UpdateOptionsUI()
	end
end

-- Initialize Function
function Wise:Initialize()
	-- Masque Support
	if LibStub then
		local Masque = LibStub("Masque", true)
		if Masque then
			Wise.MasqueGroup = Masque:Group("Wise")
		end
	end

	print("|cff00ccffWise|r Loaded. Type /wise to open options.")

	-- Log to MechanicLib debug buffer (visible even when debug mode is off)
	if Wise.debugBuffer then
		local tocVersion = C_AddOns.GetAddOnMetadata(addonName, "Version") or "unknown"
		table.insert(Wise.debugBuffer, { msg = "Wise v" .. tocVersion .. " initialized", time = GetTime() })
	end
	if Wise.MechanicLib and Wise.MechanicLib.Log then
		Wise.MechanicLib:Log(
			"Wise",
			"Initialized",
			Wise.MechanicLib.Categories and Wise.MechanicLib.Categories.CORE or nil
		)
	end

	-- Cache current character info
	if Wise.UpdateCharacterInfo then
		Wise:UpdateCharacterInfo()
	end

	-- Restore Groups
	if WiseDB.groups then
		for name, data in pairs(WiseDB.groups) do
			Wise:UpdateGroupDisplay(name)
			if Wise.frames[name] then
				-- Visibility is handled by UpdateGroupDisplay via State Driver
			end
		end
	end

	if Wise.UpdateBindings then
		Wise:UpdateBindings()
	end

	-- Track Known Characters
	if not WiseDB.knownCharacters then
		WiseDB.knownCharacters = {}
	end
	local charKey = UnitName("player") .. "-" .. GetRealmName()
	if not WiseDB.knownCharacters[charKey] then
		WiseDB.knownCharacters[charKey] = true
	end

	if Wise.InitializeMinimap then
		Wise:InitializeMinimap()
	end

	-- Fix for the "Hider" Bug in 11.0.1+
	-- If default Blizzard buff/debuff trackers are hidden, the game stops scanning auras for AddOns.
	-- We keep them functionally "active" but set Alpha to 0 so they scan invisibly.
	if BuffIconCooldownViewer then
		BuffIconCooldownViewer:SetAlpha(WiseDB.settings.hideTrackedBuffs and 0 or 1)
	end
	if BuffBarCooldownViewer then
		BuffBarCooldownViewer:SetAlpha(WiseDB.settings.hideTrackedBars and 0 or 1)
	end

	if Wise.UpdateMouseWheelState then
		Wise:UpdateMouseWheelState()
	end
end

-- Import/Export Serialization
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function Base64Encode(data)
	return (
		(data:gsub(".", function(x)
			local r, b = "", x:byte()
			for i = 8, 1, -1 do
				r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0")
			end
			return r
		end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
			if #x < 6 then
				return ""
			end
			local c = 0
			for i = 1, 6 do
				c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
			end
			return B64:sub(c + 1, c + 1)
		end) .. ({ "", "==", "=" })[#data % 3 + 1]
	)
end

local function Base64Decode(data)
	data = data:gsub("[^" .. B64 .. "=]", "")
	return (
		data:gsub(".", function(x)
			if x == "=" then
				return ""
			end
			local r, f = "", (B64:find(x) - 1)
			for i = 6, 1, -1 do
				r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
			end
			return r
		end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
			if #x ~= 8 then
				return ""
			end
			local c = 0
			for i = 1, 8 do
				c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0)
			end
			return string.char(c)
		end)
	)
end

local function DeserializeTable(str)
	local pos = 1
	local len = #str
	local depth = 0
	local maxDepth = 50
	local maxItems = 10000

	local function skipWhitespace()
		while pos <= len do
			local char = str:sub(pos, pos)
			if char == " " or char == "\t" or char == "\n" or char == "\r" then
				pos = pos + 1
			else
				break
			end
		end
	end

	local parseValue

	local function parseString()
		local quote = str:sub(pos, pos)
		pos = pos + 1
		local res = {}
		while pos <= len do
			local char = str:sub(pos, pos)
			if char == quote then
				pos = pos + 1
				return table.concat(res)
			elseif char == "\\" then
				pos = pos + 1
				if pos > len then
					break
				end
				local esc = str:sub(pos, pos)
				if esc == "n" then
					table.insert(res, "\n")
				elseif esc == "r" then
					table.insert(res, "\r")
				elseif esc == "t" then
					table.insert(res, "\t")
				elseif esc == "\\" then
					table.insert(res, "\\")
				elseif esc == '"' then
					table.insert(res, '"')
				elseif esc == "'" then
					table.insert(res, "'")
				elseif esc:match("%d") then
					local ddd = str:sub(pos, pos + 2):match("^%d+")
					table.insert(res, string.char(tonumber(ddd)))
					pos = pos + #ddd - 1
				else
					table.insert(res, esc)
				end
				pos = pos + 1
			else
				table.insert(res, char)
				pos = pos + 1
			end
		end
		error("Unterminated string")
	end

	local function parseNumber()
		local s, e = str:find("%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
		if not s or s ~= pos then
			error("Invalid number")
		end
		local numStr = str:sub(s, e)
		local val = tonumber(numStr)
		if not val then
			error("Invalid number literal: " .. numStr)
		end
		pos = e + 1
		return val
	end

	local function parseTable()
		depth = depth + 1
		if depth > maxDepth then
			error("Nested too deep")
		end

		pos = pos + 1 -- skip '{'
		local t = {}
		local count = 0
		local nextIndex = 1

		while pos <= len do
			skipWhitespace()
			if pos > len then
				break
			end
			local char = str:sub(pos, pos)
			if char == "}" then
				pos = pos + 1
				depth = depth - 1
				return t
			end

			count = count + 1
			if count > maxItems then
				error("Table too large")
			end

			local key, val
			if char == "[" then
				pos = pos + 1
				key = parseValue()
				skipWhitespace()
				if str:sub(pos, pos) ~= "]" then
					error("Expected ]")
				end
				pos = pos + 1
				skipWhitespace()
				if str:sub(pos, pos) ~= "=" then
					error("Expected =")
				end
				pos = pos + 1
				val = parseValue()
				t[key] = val
			else
				val = parseValue()
				skipWhitespace()
				if pos <= len and str:sub(pos, pos) == "=" then
					key = val
					pos = pos + 1
					val = parseValue()
					t[key] = val
				else
					t[nextIndex] = val
					nextIndex = nextIndex + 1
				end
			end

			skipWhitespace()
			if str:sub(pos, pos) == "," or str:sub(pos, pos) == ";" then
				pos = pos + 1
			end
		end
		error("Unterminated table")
	end

	parseValue = function()
		skipWhitespace()
		if pos > len then
			error("Unexpected end of input")
		end
		local char = str:sub(pos, pos)
		if char == "{" then
			return parseTable()
		elseif char == '"' or char == "'" then
			return parseString()
		elseif char == "-" or char:match("%d") then
			return parseNumber()
		elseif str:sub(pos, pos + 3) == "true" then
			pos = pos + 4
			return true
		elseif str:sub(pos, pos + 4) == "false" then
			pos = pos + 5
			return false
		elseif str:sub(pos, pos + 2) == "nil" then
			pos = pos + 3
			return nil
		else
			error("Unexpected character: " .. char)
		end
	end

	local ok, result = pcall(parseValue)
	if ok then
		return result
	else
		error(result)
	end
end

local function SerializeTable(val, indent)
	indent = indent or 0
	local pad = string.rep(" ", indent)
	if type(val) == "table" then
		local parts = {}
		local isArray = (#val > 0)
		if isArray then
			for _, v in ipairs(val) do
				parts[#parts + 1] = pad .. "  " .. SerializeTable(v, indent + 2)
			end
		else
			local keys = {}
			for k in pairs(val) do
				keys[#keys + 1] = k
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			for _, k in ipairs(keys) do
				local keyStr
				if type(k) == "number" then
					keyStr = "[" .. k .. "]"
				else
					keyStr = "[" .. string.format("%q", k) .. "]"
				end
				parts[#parts + 1] = pad .. "  " .. keyStr .. "=" .. SerializeTable(val[k], indent + 2)
			end
		end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
	elseif type(val) == "string" then
		return string.format("%q", val)
	elseif type(val) == "number" or type(val) == "boolean" then
		return tostring(val)
	else
		return "nil"
	end
end

function Wise:Serialize(data)
	local str = SerializeTable(data)
	return Base64Encode(str)
end

function Wise:Deserialize(dataString)
	if not dataString or dataString == "" then
		return nil, "Empty string"
	end
	local decoded = Base64Decode(dataString)
	if not decoded or decoded == "" then
		return nil, "Failed to decode Base64"
	end

	-- Safe deserialization: use a restricted parser instead of loadstring
	local ok, result = pcall(DeserializeTable, decoded)
	if not ok then
		return nil, "Parse error: " .. tostring(result)
	end
	if type(result) ~= "table" then
		return nil, "Invalid data: expected table"
	end

	return result
end

function Wise:ValidateImportGroup(data)
	if type(data) ~= "table" then
		return false
	end
	-- Ensure required fields exist with sensible defaults
	if not data.type then
		data.type = "circle"
	end
	if not data.actions then
		data.actions = {}
	end
	if not data.visibilitySettings then
		data.visibilitySettings = {}
	end
	if not data.keybindSettings then
		data.keybindSettings = {}
	end
	if not data.anchor then
		data.anchor = { point = "CENTER", x = 0, y = 0 }
	end
	-- Strip potentially dangerous fields
	data.binding = nil -- Don't import keybinds (could conflict)
	return true
end

function Wise:ExportInterfaces(names)
	local exportData = { version = 1, groups = {} }
	for _, name in ipairs(names) do
		local group = WiseDB.groups[name]
		if group then
			-- Deep copy to avoid modifying original
			exportData.groups[name] = Wise:DeepCopy(group)
		end
	end
	return Wise:Serialize(exportData)
end

function Wise:ImportInterfaces(dataString, overwrite)
	local data, err = Wise:Deserialize(dataString)
	if not data then
		return false, err
	end

	if not data.version then
		return false, "Missing version field"
	end
	if data.version > 1 then
		return false, "Unsupported version: " .. data.version .. ". Please update Wise."
	end
	if type(data.groups) ~= "table" then
		return false, "Invalid data: missing groups"
	end

	local imported = 0
	local conflicts = {}
	for name, groupData in pairs(data.groups) do
		if Wise:ValidateImportGroup(groupData) then
			if not WiseDB.groups[name] or overwrite then
				WiseDB.groups[name] = groupData
				Wise:UpdateGroupDisplay(name)
				imported = imported + 1
			else
				conflicts[#conflicts + 1] = { name = name, data = groupData }
			end
		end
	end

	return true, imported .. " interface(s) imported.", conflicts
end

function Wise:ProcessImportConflicts(conflicts)
	if not conflicts or #conflicts == 0 then
		return
	end
	local index = 1

	StaticPopupDialogs["WISE_IMPORT_RENAME"] = {
		text = 'Interface "%s" already exists.\nEnter a new name to import it:',
		button1 = "Import",
		button2 = "Skip",
		hasEditBox = true,
		editBoxWidth = 350,
		OnShow = function(self)
			local eb = self.EditBox or self.editBox
			if not eb then
				return
			end
			local conflict = conflicts[index]
			eb:SetText(conflict.name .. " - imported")
			eb:HighlightText()
			eb:SetFocus()
		end,
		OnAccept = function(self)
			local eb = self.EditBox or self.editBox
			local newName = eb and eb:GetText()
			if newName and newName ~= "" then
				if WiseDB.groups[newName] then
					print('|cff00ccff[Wise]|r "' .. newName .. '" also exists. Skipped.')
				else
					WiseDB.groups[newName] = conflicts[index].data
					Wise:UpdateGroupDisplay(newName)
					print('|cff00ccff[Wise]|r Imported as "' .. newName .. '".')
					if Wise.UpdateOptionsUI then
						Wise:UpdateOptionsUI()
					end
				end
			end
			index = index + 1
			if index <= #conflicts then
				C_Timer.After(0.1, function()
					StaticPopup_Show("WISE_IMPORT_RENAME", conflicts[index].name)
				end)
			end
		end,
		OnCancel = function()
			index = index + 1
			if index <= #conflicts then
				C_Timer.After(0.1, function()
					StaticPopup_Show("WISE_IMPORT_RENAME", conflicts[index].name)
				end)
			end
		end,
		EditBoxOnEnterPressed = function(self)
			local parent = self:GetParent()
			StaticPopup_OnClick(parent, 1)
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}

	StaticPopup_Show("WISE_IMPORT_RENAME", conflicts[1].name)
end

function Wise:DeepCopy(orig)
	if type(orig) ~= "table" then
		return orig
	end
	local copy = {}
	for k, v in pairs(orig) do
		copy[Wise:DeepCopy(k)] = Wise:DeepCopy(v)
	end
	return copy
end

-- Core Event Handler Frame
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("TRAIT_CONFIG_UPDATED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("UPDATE_BINDINGS")
frame:RegisterEvent("UPDATE_SHAPESHIFT_FORMS")
frame:RegisterEvent("EDIT_MODE_LAYOUTS_UPDATED")

function frame:OnEvent(event, arg1)
	if event == "ADDON_LOADED" and arg1 == addonName then
		if not WiseDB then
			WiseDB = {
				groups = {},
				settings = {
					minimap = { hide = true },
					debug = false,
					iconSize = 30,
					textSize = 12,
					font = "Fonts\\FRIZQT__.TTF",
					showKeybinds = false,
					showInterfaceKeybind = false,
					keybindPosition = "BOTTOM",
					keybindTextSize = 10,
					chargeTextSize = 12,
					chargeTextPosition = "TOP",
					showChargeText = true,
					-- Countdown Text Defaults
					countdownTextSize = 12,
					countdownTextPosition = "CENTER",
					showCountdownText = true,
					showGlows = true, -- Default: Enable Proc Glows
					showBuffs = false, -- Default: Disable Buff Durations
					enableDragDrop = true, -- Default: Enable Drag and Drop
					showTooltips = true, -- Default: Enable Interface Tooltips
					hideTrackedBars = false,
					hideTrackedBuffs = false,
				},
			}
		end
		-- Ensure global settings exist for existing users
		if WiseDB.settings then
			if WiseDB.settings.hideTrackedBars == nil then
				WiseDB.settings.hideTrackedBars = false
			end
			if WiseDB.settings.hideTrackedBuffs == nil then
				WiseDB.settings.hideTrackedBuffs = false
			end
			if WiseDB.settings.showTooltips == nil then
				WiseDB.settings.showTooltips = true
			end
			if WiseDB.settings.iconSize == nil then
				WiseDB.settings.iconSize = 30
			end
			if WiseDB.settings.textSize == nil then
				WiseDB.settings.textSize = 12
			end
			if WiseDB.settings.font == nil then
				WiseDB.settings.font = "Fonts\\FRIZQT__.TTF"
			end
			if WiseDB.settings.showKeybinds == nil then
				WiseDB.settings.showKeybinds = false
			end
			if WiseDB.settings.keybindPosition == nil then
				WiseDB.settings.keybindPosition = "BOTTOM"
			end
			if WiseDB.settings.showInterfaceKeybind == nil then
				WiseDB.settings.showInterfaceKeybind = false
			end
			if WiseDB.settings.keybindTextSize == nil then
				WiseDB.settings.keybindTextSize = 10
			end
			if WiseDB.settings.chargeTextSize == nil then
				WiseDB.settings.chargeTextSize = 12
			end
			if WiseDB.settings.chargeTextPosition == nil then
				WiseDB.settings.chargeTextPosition = "TOP"
			end
			if WiseDB.settings.showChargeText == nil then
				WiseDB.settings.showChargeText = true
			end
			-- Countdown Text Defaults
			if WiseDB.settings.countdownTextSize == nil then
				WiseDB.settings.countdownTextSize = 12
			end
			if WiseDB.settings.countdownTextPosition == nil then
				WiseDB.settings.countdownTextPosition = "CENTER"
			end
			if WiseDB.settings.showCountdownText == nil then
				WiseDB.settings.showCountdownText = true
			end
			if WiseDB.settings.enableDragDrop == nil then
				WiseDB.settings.enableDragDrop = true
			end
			-- Ensure blizzardUI settings table exists for existing users
			if not WiseDB.settings.blizzardUI then
				WiseDB.settings.blizzardUI = {}
			end
		end
		-- Ensure settings.debug exists for existing users
		if WiseDB.settings and WiseDB.settings.debug == nil then
			WiseDB.settings.debug = false
		end
		-- Migrate iconStyle "invisible" to hideEmptySlots
		if WiseDB.settings and WiseDB.settings.iconStyle == "invisible" then
			WiseDB.settings.iconStyle = "rounded"
			WiseDB.settings.hideEmptySlots = true
		end
		if WiseDB.groups then
			for _, g in pairs(WiseDB.groups) do
				if g.iconStyle == "invisible" then
					g.iconStyle = nil
					g.hideEmptySlots = true
				end
				-- Migration: old nesting code incorrectly forced toggleOnPress=true
				-- on groups that were also used as nested children. Clear the conflict
				-- if the group has held=true (user intended held mode).
				if g.visibilitySettings and g.visibilitySettings.held and g.visibilitySettings.toggleOnPress then
					g.visibilitySettings.toggleOnPress = false
				end
			end
		end
		-- Register with MechanicLib for full Mechanic integration
		local MechanicLib = LibStub and LibStub("MechanicLib-1.0", true)
		if MechanicLib then
			local tocVersion = C_AddOns.GetAddOnMetadata(addonName, "Version") or "unknown"

			-- Debug buffer for Mechanic console
			Wise.debugBuffer = Wise.debugBuffer or {}

			MechanicLib:Register("Wise", {
				version = tocVersion,

				-- Console: expose debug buffer for Mechanic's pull model
				getDebugBuffer = function()
					return Wise.debugBuffer
				end,
				clearDebugBuffer = function()
					if Wise.debugBuffer then
						wipe(Wise.debugBuffer)
					end
				end,

				-- Inspect: register key frames for Mechanic's frame watch list
				inspect = {
					getWatchFrames = function()
						local frames = {}
						if Wise.frames then
							for groupName, f in pairs(Wise.frames) do
								table.insert(frames, {
									label = "Group: " .. groupName,
									frame = f,
									property = "Visibility",
								})
							end
						end
						if Wise.DebugFrame then
							table.insert(frames, {
								label = "Debug Panel",
								frame = Wise.DebugFrame,
								property = "Visibility",
							})
						end
						return frames
					end,
				},

				-- Tools: quick actions panel in Mechanic's Tools tab
				tools = {
					createPanel = function(container)
						Wise:CreateMechanicToolsPanel(container)
					end,
				},

				-- Settings exposed in Mechanic UI
				settings = {
					debugMode = {
						type = "toggle",
						name = "Debug Mode",
						get = function()
							return WiseDB and WiseDB.settings and WiseDB.settings.debug
						end,
						set = function(v)
							if WiseDB and WiseDB.settings then
								WiseDB.settings.debug = v
								if Wise.ToggleDebugInterface then
									Wise:ToggleDebugInterface(v)
								end
							end
						end,
					},
					showKeybinds = {
						type = "toggle",
						name = "Show Keybinds",
						get = function()
							return WiseDB and WiseDB.settings and WiseDB.settings.showKeybinds
						end,
						set = function(v)
							if WiseDB and WiseDB.settings then
								WiseDB.settings.showKeybinds = v
							end
						end,
					},
				},
			})
			Wise.MechanicLib = MechanicLib
		end

		-- Initialize modules if needed
		self:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_LOGIN" then
		-- One-time repair: early Slot Configurator builds compiled custom_macro
		-- actions with raw numeric spell/item IDs in /cast and /use lines, which
		-- silently cast nothing.  Rebuild every graph-compiled slot from its stored
		-- graph so the macros become castable (also clears the [[..]] bracket bug).
		-- Run here (not ADDON_LOADED) so spell-name APIs are reliable, and before
		-- Initialize so the bars bind the repaired macros. Guarded to run once.
		if WiseDB then
			WiseDB.migrations = WiseDB.migrations or {}
			if not WiseDB.migrations.compiledMacroIDsToNames then
				if Wise.RepairCompiledSlotFromGraph and WiseDB.groups then
					local repaired = 0
					for _, g in pairs(WiseDB.groups) do
						if type(g.actions) == "table" then
							for slotKey, slotActions in pairs(g.actions) do
								if type(slotKey) == "number" and Wise:RepairCompiledSlotFromGraph(slotActions) then
									repaired = repaired + 1
								end
							end
						end
					end
					WiseDB.migrations.compiledMacroIDsToNames = true
					if repaired > 0 then
						Wise:DebugPrint("Repaired " .. repaired .. " configurator slot(s) with ID-based macros")
					end
				end

				-- One-time RE-repair: an earlier build baked per-character availability
				-- (IsActionAllowed) into the stored macro, so the login migration above
				-- froze whichever character ran it into the SHARED slot data — corrupting
				-- multi-character slots (e.g. AtMouse showed wrong/stale icons on other
				-- specs/chars). The compiler now produces CANONICAL, all-character macros
				-- and filters live per character at display time. Rebuild every graph slot
				-- once more from its preserved graph to restore the canonical macros.
				if not WiseDB.migrations.canonicalMacroRecompileV2 then
					if Wise.RepairCompiledSlotFromGraph and WiseDB.groups then
						local rerepaired = 0
						for _, g in pairs(WiseDB.groups) do
							if type(g.actions) == "table" then
								for slotKey, slotActions in pairs(g.actions) do
									if type(slotKey) == "number" and Wise:RepairCompiledSlotFromGraph(slotActions) then
										rerepaired = rerepaired + 1
									end
								end
							end
						end
						WiseDB.migrations.canonicalMacroRecompileV2 = true
						if rerepaired > 0 then
							Wise:DebugPrint("Recompiled " .. rerepaired .. " configurator slot(s) to canonical macros")
						end
					end
				end

				-- One-time recompile for slots whose compiled steps predate pathNodeIds.
				-- Such steps can't be re-filtered per character at runtime, so the engine
				-- falls back to firing their stored macroText with no availability check —
				-- meaning an off-spec/off-class step (e.g. a Disc-only Single-Button
				-- Assistant) fires on a character that should never see it. Recompiling
				-- from the preserved graph regenerates steps WITH pathNodeIds so live
				-- filtering applies. Runs independently of the migrations above (their flag
				-- may already be set on profiles created before this fix existed).
				if not WiseDB.migrations.pathNodeIdsRecompileV3 then
					if Wise.RepairCompiledSlotFromGraph and WiseDB.groups then
						local fixed = 0
						for _, g in pairs(WiseDB.groups) do
							if type(g.actions) == "table" then
								for slotKey, slotActions in pairs(g.actions) do
									if type(slotKey) == "number" and type(slotActions) == "table" then
										-- Only slots that have a graph AND at least one compiled
										-- step missing pathNodeIds need rebuilding.
										local needs = false
										if slotActions.graph then
											for _, st in ipairs(slotActions) do
												if
													type(st) == "table"
													and st.type == "misc"
													and st.value == "custom_macro"
													and not st.pathNodeIds
												then
													needs = true
													break
												end
											end
										end
										if needs and Wise:RepairCompiledSlotFromGraph(slotActions) then
											fixed = fixed + 1
										end
									end
								end
							end
						end
						WiseDB.migrations.pathNodeIdsRecompileV3 = true
						if fixed > 0 then
							Wise:DebugPrint("Recompiled " .. fixed .. " slot(s) missing pathNodeIds")
						end
					end
				end
			end
		end
		if Wise.Initialize then
			Wise:Initialize()
		end
		if Wise.RegisterBlizzardUIHooks then
			Wise:RegisterBlizzardUIHooks()
		end
		if Wise.UpdateBlizzardUI then
			Wise:UpdateBlizzardUI()
			-- Safety-net: Blizzard's Edit Mode layout engine applies layouts
			-- asynchronously during reload, often AFTER PLAYER_LOGIN. Re-apply
			-- our hiding after a delay to override any late Blizzard resets.
			C_Timer.After(1, function()
				if not InCombatLockdown() and Wise.UpdateBlizzardUI then
					Wise:UpdateBlizzardUI()
				end
			end)
			C_Timer.After(3, function()
				if not InCombatLockdown() and Wise.UpdateBlizzardUI then
					Wise:UpdateBlizzardUI()
				end
			end)
		end

		-- Initialize Debug Interface if enabled
		if Wise.InitializeDebug then
			Wise:InitializeDebug()
		end

		-- Repair saved mouse-anchor offsets that would park a persistently
		-- visible interface under the cursor (blocking all clicks). Deferred
		-- so group frames exist and have been laid out with real sizes.
		C_Timer.After(2, function()
			if Wise.SanitizeMouseAnchorOffsets then
				Wise:SanitizeMouseAnchorOffsets()
			end
		end)

		-- Trigger Demo if first time
		if not WiseDB.tutorialComplete and Wise.Demo then
			C_Timer.After(2, function()
				Wise.Demo:Start()
			end)
		end
	elseif
		event == "PLAYER_SPECIALIZATION_CHANGED"
		or event == "TRAIT_CONFIG_UPDATED"
		or event == "PLAYER_ENTERING_WORLD"
		or event == "SPELLS_CHANGED"
		or event == "UPDATE_SHAPESHIFT_FORMS"
		or event == "EDIT_MODE_LAYOUTS_UPDATED"
	then
		-- These events fire in bursts spread across multiple frames during spec
		-- transitions (especially SPELLS_CHANGED). Debounce into a single
		-- refresh so interfaces settle once instead of thrashing.

		-- Lightweight cache update — always safe to run immediately
		local _, className = UnitClass("player")
		Wise.characterInfo.class = className
		local specIndex = GetSpecialization()
		if specIndex then
			local specID, _, _, _, role = GetSpecializationInfo(specIndex)
			Wise.characterInfo.specID = specID
			Wise.characterInfo.role = role
		end

		-- Bump generation and schedule a single debounced full refresh.
		-- Every new event resets the timer so we wait for the burst to end.
		Wise._specRefreshGeneration = (Wise._specRefreshGeneration or 0) + 1
		local gen = Wise._specRefreshGeneration

		C_Timer.After(0.5, function()
			if Wise._specRefreshGeneration ~= gen then
				return
			end
			-- Full character info + wiser interfaces rebuild
			if Wise.UpdateCharacterInfo then
				Wise:UpdateCharacterInfo("DEBOUNCED_SPEC_REFRESH")
			end
			Wise:ForceRefreshAllDisplays()
			if Wise.UpdateBlizzardUI then
				Wise:UpdateBlizzardUI()
			end
			if Wise.UpdateOptionsUI then
				Wise:UpdateOptionsUI()
			end
			if Wise.pickingAction and Wise.EmbeddedPicker and Wise.PickerRefresh then
				local search = Wise.EmbeddedPicker.Search
				Wise:PickerRefresh(search and search:GetText() or "")
			end
		end)
	elseif event == "PLAYER_REGEN_ENABLED" then
		-- Process pending updates that were blocked during combat
		if Wise.pendingUpdates then
			for name, _ in pairs(Wise.pendingUpdates) do
				if Wise.UpdateGroupDisplay then
					Wise:UpdateGroupDisplay(name)
				end
			end
			Wise.pendingUpdates = nil
		end
		if Wise.ResetSequences then
			Wise:ResetSequences()
		end
		if Wise.pendingBlizzardUIUpdate then
			if Wise.UpdateBlizzardUI then
				Wise:UpdateBlizzardUI()
			end
		end
		-- Flush any CooldownViewer syncs that were deferred during combat
		if Wise._pendingViewerSync then
			local pending = Wise._pendingViewerSync
			Wise._pendingViewerSync = nil
			for groupName, viewerName in pairs(pending) do
				if Wise._ReadCooldownViewer then
					Wise:_ReadCooldownViewer(groupName, viewerName)
				end
			end
		end
	elseif event == "UPDATE_BINDINGS" then
		if Wise.UpdateBindings then
			Wise:UpdateBindings()
		end
	end
end
frame:SetScript("OnEvent", frame.OnEvent)

-- Update icons for buttons that use "interface" action type (nested interfaces).
-- Called on events that may change the nested interface's content (spec change, spells changed, etc.)
function Wise:UpdateInterfaceIcons()
	if not Wise.frames or not Wise.buttonMeta then
		return
	end
	for groupName, f in pairs(Wise.frames) do
		if f.buttons then
			for _, btn in ipairs(f.buttons) do
				if btn:IsShown() then
					local meta = Wise.buttonMeta[btn]
					if meta and meta.actionType == "interface" then
						local newIcon = Wise:GetActionIcon("interface", meta.actionValue)
						if newIcon then
							btn.icon:SetTexture(newIcon)
						end
					end
				end
			end
		end
	end
end

function Wise:OpenPicker(callback)
	Wise.pickingAction = true
	Wise.pickingIcon = false
	Wise.PickerCallback = callback
	Wise.PickerCurrentCategory = "Spell"
	Wise:RefreshPropertiesPanel()
end

function Wise:OpenIconPicker(callback)
	if C_AddOns.IsAddOnLoaded("LargerMacroIconSelection") then
		Wise:OpenMacroPopupPicker(callback)
	else
		Wise.pickingAction = false
		Wise.pickingIcon = true
		Wise.PickerCallback = callback
		Wise:RefreshPropertiesPanel()
	end
end

function Wise:OpenMacroPopupPicker(callback)
	if not C_AddOns.IsAddOnLoaded("Blizzard_MacroUI") then
		C_AddOns.LoadAddOn("Blizzard_MacroUI")
	end

	if not MacroPopupFrame then
		return
	end

	-- Capture original state locally to ensure safe restoration
	local origParent = MacroPopupFrame:GetParent()
	local origStrata = MacroPopupFrame:GetFrameStrata()
	local origPoint = { MacroPopupFrame:GetPoint() } -- Basic capture of primary point

	local origOnAccept = MacroPopupFrame.OnAccept
	local origOnCancel = MacroPopupFrame.OnCancel
	local origOnHide = MacroPopupFrame:GetScript("OnHide")
	local origUpdateWidth = MacroPopupFrame.UpdateMacroFramePanelWidth

	local restored = false
	local function RestoreState()
		if restored then
			return
		end
		restored = true

		-- Restore frame hierarchy and position (frame is already hiding)
		MacroPopupFrame:SetParent(origParent)
		MacroPopupFrame:SetFrameStrata(origStrata)
		MacroPopupFrame:ClearAllPoints()
		if origPoint[1] then
			MacroPopupFrame:SetPoint(unpack(origPoint))
		end

		MacroPopupFrame.OnAccept = origOnAccept
		MacroPopupFrame.OnCancel = origOnCancel

		if origUpdateWidth then
			MacroPopupFrame.UpdateMacroFramePanelWidth = origUpdateWidth
		end

		-- Restore original OnHide but do NOT call it — Blizzard's handler
		-- expects internal icon-selector state we never initialized.
		if origOnHide then
			MacroPopupFrame:SetScript("OnHide", origOnHide)
		else
			MacroPopupFrame:SetScript("OnHide", nil)
		end
	end

	-- Override UpdateMacroFramePanelWidth to prevent taint/errors when MacroFrame is hidden
	MacroPopupFrame.UpdateMacroFramePanelWidth = function() end

	-- Reparent and Anchor for Visibility
	MacroPopupFrame:SetParent(Wise.OptionsFrame)
	MacroPopupFrame:SetFrameStrata("DIALOG")
	MacroPopupFrame:ClearAllPoints()
	-- Anchor to the right of the options frame ("popout")
	MacroPopupFrame:SetPoint("TOPLEFT", Wise.OptionsFrame, "TOPRIGHT", 0, 0)

	-- Ensure restoration on Hide (covers ESC key and Cancel button)
	MacroPopupFrame:SetScript("OnHide", function(self)
		RestoreState()
	end)

	MacroPopupFrame.OnAccept = function(self)
		local iconTexture = nil

		-- Try 1: selectedIcon property (set by LargerMacroIconSelection)
		if MacroPopupFrame.selectedIcon then
			iconTexture = MacroPopupFrame.selectedIcon
		end

		-- Try 2: Modern Blizzard IconSelector API (Retail 11.0+)
		if not iconTexture and MacroPopupFrame.IconSelector then
			local selector = MacroPopupFrame.IconSelector
			if selector.GetSelectedIndex then
				local idx = selector:GetSelectedIndex()
				if idx then
					-- Use the data provider if available
					if selector.iconDataProvider and selector.iconDataProvider.GetIconByIndex then
						iconTexture = selector.iconDataProvider:GetIconByIndex(idx)
					else
						-- Fall back to macro icon list lookup
						local icons = C_Macro and C_Macro.GetMacroIcons and C_Macro.GetMacroIcons()
						if icons and icons[idx] then
							iconTexture = icons[idx]
						end
					end
				end
			end
		end

		-- Try 3: Read texture from the selected-icon display area
		if not iconTexture and MacroPopupFrame.BorderBox then
			local area = MacroPopupFrame.BorderBox.SelectedIconArea
			if area then
				local btn = area.SelectedIconButton
				if btn then
					local icon = btn.Icon or btn.icon
					if icon and icon.GetTexture then
						iconTexture = icon:GetTexture()
					end
				end
			end
		end

		-- Hide triggers OnHide which calls RestoreState
		MacroPopupFrame:Hide()

		if callback then
			-- Note: iconTexture can be nil, which means the '?' (Dynamic/Default) icon was selected.
			callback("icon", iconTexture)
		end
	end

	MacroPopupFrame.OnCancel = function(self)
		MacroPopupFrame:Hide()
	end

	MacroPopupFrame:Show()
end

-- HUD Edit Mode Integration

Wise.BlizzardFrames = {
	-- Action Bar 1: MainMenuBarArtFrame (art background), ActionButton1..12 (buttons)
	-- We avoid hiding MainMenuBar itself because it contains XP/Rep bars (StatusTrackingBarManager) and MicroMenu in some modes.
	-- Additional decorative art (end caps, background) is handled separately in UpdateBlizzardUI.
	{ key = "hideActionBar1", label = "Action Bar 1", frames = { "MainMenuBarArtFrame" } },
	{ key = "hideStanceBar", label = "Stance Bar", frames = { "StanceBar" } },
	{ key = "hidePetBar", label = "Pet Bar", frames = { "PetActionBar" } },
	{ key = "hideOverrideBar", label = "Override Bar", frames = { "OverrideActionBar" } },
	{ key = "hideMicroMenu", label = "Micro Menu", frames = { "MicroMenuContainer", "MicroMenu" } },
	{ key = "hideBagsBar", label = "Bags Bar", frames = { "BagsBar", "BagBarExpandable" } },
	{ key = "hideExtraActionBar", label = "Extra Action Button", frames = { "ExtraActionBarFrame" } },
	{ key = "hideZoneAbility", label = "Zone Ability Button", frames = { "ZoneAbilityFrame" } },
	{ key = "hidePuzzleUI", label = "Puzzle Event UI", frames = {} },
}

-- Hook into Edit Mode to re-apply visibility when exiting Edit Mode
if EditModeManagerFrame then
	EditModeManagerFrame:HookScript("OnHide", function()
		if Wise.UpdateBlizzardUI then
			-- Delay slightly to let Blizzard UI finish its layout updates
			C_Timer.After(0.1, function()
				Wise:UpdateBlizzardUI()
			end)
		end
	end)
end

Wise.managedFrames = Wise.managedFrames or {}

-- Programmatic check for an active puzzle event
-- Puzzles generally give the player an Override Action Bar but do NOT put them
-- in a traditional vehicle or possess state.
-- Auras that put the player into a quest puzzle/minigame that renders its own UI
-- (UIWidget / fullscreen overlay) WITHOUT triggering an override action bar — so
-- HasOverrideActionBar() alone misses them. Matched by spellId (locale-independent).
-- Add more puzzle aura spellIds here as they're found.
local PUZZLE_AURA_SPELLIDS = {
	[1293367] = true, -- "Unravel the Magical Ward" — Unraveling quest (Midnight)
}

local function HasPuzzleAura()
	for i = 1, 40 do
		local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
		if not aura then
			break
		end
		if aura.spellId and PUZZLE_AURA_SPELLIDS[aura.spellId] then
			return true
		end
	end
	return false
end

local function IsPuzzleActive()
	local inVehicle = UnitInVehicle("player") or UnitHasVehicleUI("player")
	if inVehicle then
		return false
	end
	local hasOverride = HasOverrideActionBar and HasOverrideActionBar()
	local isPossess = IsPossessBarVisible and IsPossessBarVisible()
	if hasOverride and not isPossess then
		return true
	end
	-- Aura-driven puzzles (no override bar): e.g. "Unravel the Magic Ward".
	return HasPuzzleAura()
end

local lastPuzzleState = false

-- Event frame for puzzle UI hiding
local puzzleEventFrame = CreateFrame("Frame")
puzzleEventFrame:RegisterEvent("UPDATE_UI_WIDGET")
puzzleEventFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
puzzleEventFrame:RegisterEvent("ACTIONBAR_UPDATE_STATE")
puzzleEventFrame:RegisterEvent("UNIT_ENTERED_VEHICLE")
puzzleEventFrame:RegisterEvent("UNIT_EXITED_VEHICLE")
-- Aura-driven puzzles (e.g. "Unravel the Magic Ward") have no override bar, so
-- watch player auras too. UNIT_AURA fires frequently — gate on a real state change.
puzzleEventFrame:RegisterUnitEvent("UNIT_AURA", "player")
puzzleEventFrame:SetScript("OnEvent", function(self, event, ...)
	local currentState = IsPuzzleActive()
	local stateChanged = (currentState ~= lastPuzzleState)
	lastPuzzleState = currentState

	if
		stateChanged
		or event == "UNIT_ENTERED_VEHICLE"
		or event == "UNIT_EXITED_VEHICLE"
		or event == "UPDATE_BONUS_ACTIONBAR"
	then
		if Wise.UpdateBlizzardUI then
			Wise:UpdateBlizzardUI()
		end
	end
end)

-- Secure, parentless hidden frame for reparenting Blizzard frames.
-- Using nil parent (parentless) + SecureFrameTemplate avoids:
--   1. UIParent layout resets re-showing hidden children during reload
--   2. Taint propagation from insecure -> secure frame parenting
local hiddenParent = CreateFrame("Frame", "WiseHiddenParent", nil, "SecureFrameTemplate")
hiddenParent:Hide()
Wise.hiddenParent = hiddenParent

local inSetParentHook = false
local function HookSetParent(frame, shouldHideFunc)
	if not frame or not frame.SetParent then
		return
	end
	hooksecurefunc(frame, "SetParent", function(self, parent)
		if inSetParentHook then
			return
		end
		if InCombatLockdown() then
			return
		end
		if shouldHideFunc() then
			if parent ~= hiddenParent then
				if not Wise.managedFrames[self] then
					Wise.managedFrames[self] = { originalParent = parent }
				elseif type(Wise.managedFrames[self]) == "table" then
					Wise.managedFrames[self].originalParent = parent
				end
				inSetParentHook = true
				self:SetParent(hiddenParent)
				inSetParentHook = false
			end
		end
	end)
end

local function shouldHideAB1()
	local settings = WiseDB and WiseDB.settings and WiseDB.settings.blizzardUI or {}
	local puzzleActive = settings["hidePuzzleUI"] and IsPuzzleActive and IsPuzzleActive()
	return settings["hideActionBar1"] or not not puzzleActive
end

local function shouldHidePet()
	local settings = WiseDB and WiseDB.settings and WiseDB.settings.blizzardUI or {}
	local puzzleActive = settings["hidePuzzleUI"] and IsPuzzleActive and IsPuzzleActive()
	return settings["hidePetBar"] or not not puzzleActive
end

local function shouldHideOverride()
	local settings = WiseDB and WiseDB.settings and WiseDB.settings.blizzardUI or {}
	return settings["hideOverrideBar"]
end

local hooksRegistered = false
function Wise:RegisterBlizzardUIHooks()
	if hooksRegistered then
		return
	end
	hooksRegistered = true

	for i = 1, 12 do
		local btn = _G["ActionButton" .. i]
		if btn then
			HookSetParent(btn, shouldHideAB1)
		end
	end

	if PetActionBar then
		HookSetParent(PetActionBar, shouldHidePet)
		PetActionBar:HookScript("OnShow", function(self)
			if InCombatLockdown() then
				return
			end
			if shouldHidePet() then
				self:SetParent(hiddenParent)
				self:SetAlpha(0)
			end
		end)
	end

	if OverrideActionBar then
		HookSetParent(OverrideActionBar, shouldHideOverride)
		OverrideActionBar:HookScript("OnShow", function(self)
			if InCombatLockdown() then
				return
			end
			if shouldHideOverride() then
				self:SetParent(hiddenParent)
				self:SetAlpha(0)
			end
		end)
	end
end

-- Frames that taint when hidden via RegisterStateDriver (e.g. PetActionBar calls SetShownBase)
-- OverrideActionBar has its own show/hide animations and state driver that conflict with RegisterStateDriver,
-- causing a pulsing effect. Reparenting avoids this.
local reparentFrames = {
	PetActionBar = true,
	OverrideActionBar = true,
}

-- Determine whether a given frame name should currently be hidden based on user settings.
-- Used by the global RegisterStateDriver/UnregisterStateDriver hooks to re-assert
-- our "hide" driver when Blizzard's Edit Mode layout engine resets state drivers.
local function shouldHideFrame(frameName)
	local settings = WiseDB and WiseDB.settings and WiseDB.settings.blizzardUI or {}
	for _, info in ipairs(Wise.BlizzardFrames) do
		if settings[info.key] then
			for _, fn in ipairs(info.frames) do
				if fn == frameName then
					return true
				end
			end
		end
	end
	-- Also check Action Bar 1 buttons individually
	if settings["hideActionBar1"] then
		for i = 1, 12 do
			if frameName == "ActionButton" .. i then
				return true
			end
		end
	end
	return false
end

-- Global hooks to intercept Blizzard (or other addons) resetting our visibility state drivers.
-- Edit Mode applies layouts asynchronously during reload, clearing drivers we set.
-- These hooks re-assert "hide" on any managed frame whose driver is being changed.
local inRegisterHook = false
hooksecurefunc("RegisterStateDriver", function(frame, header, state)
	if inRegisterHook or InCombatLockdown() then
		return
	end
	if header ~= "visibility" then
		return
	end
	local frameName = frame and frame.GetName and frame:GetName()
	if not frameName then
		return
	end
	-- Only intercept non-reparent frames (reparent frames use SetParent instead)
	if reparentFrames[frameName] then
		return
	end
	if shouldHideFrame(frameName) and state ~= "hide" then
		inRegisterHook = true
		RegisterStateDriver(frame, "visibility", "hide")
		inRegisterHook = false
	end
end)

hooksecurefunc("UnregisterStateDriver", function(frame, header)
	if inRegisterHook or InCombatLockdown() then
		return
	end
	if header ~= "visibility" then
		return
	end
	local frameName = frame and frame.GetName and frame:GetName()
	if not frameName then
		return
	end
	if reparentFrames[frameName] then
		return
	end
	if shouldHideFrame(frameName) then
		inRegisterHook = true
		RegisterStateDriver(frame, "visibility", "hide")
		inRegisterHook = false
	end
end)

function Wise:UpdateBlizzardUI()
	if InCombatLockdown() then
		Wise.pendingBlizzardUIUpdate = true
		return
	end

	local settings = WiseDB.settings.blizzardUI or {}

	local puzzleActive = false
	if settings["hidePuzzleUI"] then
		puzzleActive = IsPuzzleActive()
	end

	if not InCombatLockdown() and Wise.frames then
		for _, f in pairs(Wise.frames) do
			if puzzleActive then
				f:SetAttribute("state-wise-hide", "show")
			else
				f:SetAttribute("state-wise-hide", "hide")
			end
		end
	end

	for _, info in ipairs(Wise.BlizzardFrames) do
		local shouldHide = settings[info.key]
			or (
				settings["hidePuzzleUI"]
				and puzzleActive
				and info.key ~= "hideOverrideBar"
				and info.key ~= "hideZoneAbility"
			)
		for _, frameName in ipairs(info.frames) do
			local frame = _G[frameName]
			if frame then
				if reparentFrames[frameName] then
					-- Reparent to hidden frame to avoid taint from RegisterStateDriver
					if shouldHide then
						if not Wise.managedFrames[frame] then
							Wise.managedFrames[frame] = { originalParent = frame:GetParent() }
						end
						frame:SetParent(hiddenParent)
						frame:SetAlpha(0)
					elseif Wise.managedFrames[frame] then
						local savedParent = Wise.managedFrames[frame].originalParent or UIParent
						frame:SetParent(savedParent)
						frame:SetAlpha(1)
						if frame.Show then
							frame:Show()
						end
						Wise.managedFrames[frame] = nil
					end
				else
					if shouldHide then
						RegisterStateDriver(frame, "visibility", "hide")
						Wise.managedFrames[frame] = true
					elseif Wise.managedFrames[frame] then
						UnregisterStateDriver(frame, "visibility")
						if frame.Show then
							frame:Show()
						end
						Wise.managedFrames[frame] = nil
					end
				end
			end
		end
	end

	-- Special handling for Action Bar 1: buttons + decorative art elements
	local hideAB1 = settings["hideActionBar1"] or (settings["hidePuzzleUI"] and puzzleActive)

	-- Action Buttons 1-12
	-- Reparent instead of RegisterStateDriver to avoid tainting secure attributes
	-- (pressAndHoldAction etc.) on Blizzard action buttons in 11.0+.
	for i = 1, 12 do
		local btn = _G["ActionButton" .. i]
		if btn then
			if hideAB1 then
				if not Wise.managedFrames[btn] then
					Wise.managedFrames[btn] = { originalParent = btn:GetParent() }
				end
				btn:SetParent(hiddenParent)
				btn:SetAlpha(0)
				btn:EnableMouse(false)
			elseif Wise.managedFrames[btn] then
				local savedParent = Wise.managedFrames[btn].originalParent or UIParent
				btn:SetParent(savedParent)
				btn:SetAlpha(1)
				btn:EnableMouse(true)
				if btn.Show then
					btn:Show()
				end
				Wise.managedFrames[btn] = nil
			end
		end
	end

	if MainActionBar then
		if hideAB1 then
			MainActionBar:SetAlpha(0)
			MainActionBar:EnableMouse(false)
			Wise.managedFrames[MainActionBar] = true
		elseif Wise.managedFrames[MainActionBar] then
			MainActionBar:SetAlpha(1)
			MainActionBar:EnableMouse(true)
			Wise.managedFrames[MainActionBar] = nil
		end
	end

	-- Decorative art elements (end caps / dragon-gryphon art, background, page number)
	-- These may be child frames or textures that aren't covered by MainMenuBarArtFrame alone.
	local artElements = {
		_G["MainMenuBarArtFrameBackground"],
		_G["ActionBarPageNumber"],
		MainMenuBar and MainMenuBar.EndCaps,
		MainMenuBar and MainMenuBar.BorderArt,
		MainMenuBarArtFrame and MainMenuBarArtFrame.LeftEndCap,
		MainMenuBarArtFrame and MainMenuBarArtFrame.RightEndCap,
		MainMenuBarArtFrame and MainMenuBarArtFrame.PageNumber,
		MainActionBar and MainActionBar.EndCaps,
		MainActionBar and MainActionBar.BorderArt,
		MainActionBar and MainActionBar.ActionBarPageNumber,
	}
	for _, element in ipairs(artElements) do
		if element then
			if hideAB1 then
				element:SetAlpha(0)
				if element.Hide then
					element:Hide()
				end
				Wise.managedArtElements = Wise.managedArtElements or {}
				Wise.managedArtElements[element] = true
			elseif Wise.managedArtElements and Wise.managedArtElements[element] then
				element:SetAlpha(1)
				if element.Show then
					element:Show()
				end
				Wise.managedArtElements[element] = nil
			end
		end
	end

	Wise.pendingBlizzardUIUpdate = false
end

-- Slash Command Handler
SLASH_WISE1 = "/wise"
SlashCmdList["WISE"] = function(msg)
	local cmd, arg = msg:match("^(%S*)%s*(.*)")

	if cmd == "hidebars" then
		if not WiseDB.settings.minimap then
			WiseDB.settings.minimap = { hide = true }
		end
		local newState = true -- Default toggle on

		if arg == "off" then
			newState = false
		elseif arg == "on" then
			newState = true
		else
			-- Toggle all based on first one? Or just toggle all ON?
			-- Let's make it toggle: if any are visible, hide all. If all hidden, show all.
			local anyVisible = false
			for _, info in ipairs(Wise.BlizzardFrames) do
				if not WiseDB.settings.blizzardUI[info.key] then
					anyVisible = true
					break
				end
			end
			newState = anyVisible -- If any visible, hide all (true). If all hidden, show all (false).
		end

		for _, info in ipairs(Wise.BlizzardFrames) do
			WiseDB.settings.blizzardUI[info.key] = newState
		end

		Wise:UpdateBlizzardUI()

		-- Refresh UI if open
		if
			Wise.PopulateSettingsView
			and Wise.OptionsFrame
			and Wise.OptionsFrame:IsShown()
			and Wise.currentTab == "Settings"
		then
			Wise:PopulateSettingsView(Wise.OptionsFrame.Views.Settings)
		end

		print("|cff00ccff[Wise]|r Blizzard Bars " .. (newState and "Hidden" or "Shown"))
		return
	end

	if cmd == "puzzledbg" then
		-- Diagnostic: dump player buffs + puzzle-detection state so we can see
		-- exactly why the puzzle hide does/doesn't fire. Run it INSIDE the puzzle.
		print("|cff00ccff[Wise puzzle]|r --- player HELPFUL auras ---")
		for i = 1, 40 do
			local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
			if not a then
				break
			end
			print(("  [%d] %s  (spellId=%s)"):format(i, tostring(a.name), tostring(a.spellId)))
		end
		local settings = WiseDB.settings.blizzardUI or {}
		print(("|cff00ccff[Wise puzzle]|r hidePuzzleUI setting = %s"):format(tostring(settings["hidePuzzleUI"])))
		print(("|cff00ccff[Wise puzzle]|r IsPuzzleActive() = %s"):format(tostring(IsPuzzleActive())))
		print(("|cff00ccff[Wise puzzle]|r HasOverrideActionBar() = %s"):format(tostring(HasOverrideActionBar and HasOverrideActionBar())))
		local n = 0
		if Wise.frames then
			for _, f in pairs(Wise.frames) do
				n = n + 1
				if n <= 3 then
					print(("  frame[%s] state-wise-hide = %s"):format(
						tostring(f.GetName and f:GetName()), tostring(f:GetAttribute("state-wise-hide"))))
				end
			end
		end
		print(("|cff00ccff[Wise puzzle]|r Wise.frames count = %d"):format(n))
		return
	end

	if cmd == "delete" then
		if arg == "" then
			print("|cff00ccff[Wise]|r Usage: /wise delete [interface name]")
			return
		end
		if WiseDB.groups[arg] then
			if InCombatLockdown() then
				print("|cff00ccff[Wise]|r Cannot delete interface in combat.")
				return
			end
			Wise:DeleteGroup(arg)
			print("|cff00ccff[Wise]|r Interface '" .. arg .. "' deleted.")
		else
			print("|cff00ccff[Wise]|r Interface '" .. arg .. "' not found.")
		end
		return
	end

	if cmd == "debug" then
		print("|cff00ccff[Wise Debug]|r Checking Bindings...")
		if WiseDB and WiseDB.groups then
			for name, group in pairs(WiseDB.groups) do
				local toggleName = "WiseGroupToggle_" .. name
				local key = GetBindingKey("CLICK " .. toggleName .. ":LeftButton")
				print(string.format("Group '%s': ToggleButton='%s' Key='%s'", name, toggleName, tostring(key)))

				-- Check for keybind properties directly
				print(
					string.format(
						"  Props: bind='%s' keybind='%s' hotkey='%s' trigger='%s'",
						tostring(group.bind),
						tostring(group.keybind),
						tostring(group.hotkey),
						tostring(group.trigger)
					)
				)
			end
		end
		return
	end

	if cmd == "cpu" then
		-- Delta-based CPU profiler for Wise's OWN frames.
		--   /wise cpu start  → reset counters, mark t0
		--   (play/idle ~30s)
		--   /wise cpu        → report ms used SINCE start, as a rate (ms/sec)
		-- Cumulative-since-login is useless for finding live cost (global frames
		-- like UIParent dominate it), so we always measure a window instead.
		if GetCVar("scriptProfile") ~= "1" then
			-- scriptProfile is a CVar that only takes effect after a reload, so the
			-- best any single command can do is enable it + tell the user to reload
			-- and re-run the SAME command. Tailor the follow-up to which sub-command
			-- was asked for so re-enabling is a clean one-liner to repeat.
			SetCVar("scriptProfile", "1")
			local again = "/wise cpu"
			if arg == "enter" or arg == "enter clear" then
				again = "/wise cpu enter"
			elseif arg == "start" then
				again = "/wise cpu start"
			end
			print(
				"|cff00ccff[Wise]|r CPU profiling was OFF. Enabled it — |cffffd700/reload|r, then run"
					.. " |cffffd700" .. again .. "|r again."
			)
			return
		end

		if arg == "start" then
			ResetCPUUsage()
			Wise._cpuT0 = GetTime()
			Wise._cpuBaseTotal = 0
			print("|cff00ccff[Wise CPU]|r Counters reset. Play/idle ~30s, then run |cffffd700/wise cpu|r.")
			return
		end

		-- Per-event combat-ENTER spike profiler.
		--   /wise cpu enter        → arm a PLAYER_REGEN_DISABLED hook + show captured spikes
		--   /wise cpu enter clear  → wipe captured samples
		-- A sustained window (the default report) averages a one-time hitch away,
		-- so a stutter that only happens the instant combat starts is invisible to
		-- it. This times the single combat-enter frame (debugprofilestop delta) and
		-- diffs per-addon CPU across that frame to rank who caused the hitch.
		-- Samples are session-only (not saved) to avoid SavedVariables bloat.
		if arg == "enter" or arg == "enter clear" then
			if arg == "enter clear" then
				Wise._cpuEnterSamples = nil
				print("|cff00ccff[Wise CPU]|r Combat-enter samples cleared.")
				return
			end

			if not Wise._cpuEnterFrame then
				local ef = CreateFrame("Frame")
				ef._wiseProfileName = "CpuEnterProbe"
				ef:RegisterEvent("PLAYER_REGEN_DISABLED")
				ef:SetScript("OnEvent", function()
					if GetCVar("scriptProfile") ~= "1" then
						return
					end
					local t0 = debugprofilestop()
					UpdateAddOnCPUUsage()
					local before = {}
					local n = C_AddOns.GetNumAddOns() or 0
					for i = 1, n do
						if C_AddOns.IsAddOnLoaded(i) then
							before[i] = GetAddOnCPUUsage(i) or 0
						end
					end
					-- Next-frame callback runs after this frame's OnEvent handlers and
					-- Blizzard's secure-frame re-evaluation have executed, so the delta
					-- captures the whole combat-enter hitch.
					C_Timer.After(0, function()
						local frameMs = debugprofilestop() - t0
						UpdateAddOnCPUUsage()
						local rows, sum = {}, 0
						for i = 1, n do
							if before[i] then
								local d = (GetAddOnCPUUsage(i) or 0) - before[i]
								if d > 0 then
									rows[#rows + 1] = { name = (C_AddOns.GetAddOnInfo(i)), ms = d }
									sum = sum + d
								end
							end
						end
						table.sort(rows, function(a, b)
							return a.ms > b.ms
						end)
						Wise._cpuEnterSamples = Wise._cpuEnterSamples or {}
						local top = {}
						for i = 1, math.min(6, #rows) do
							top[i] = rows[i]
						end
						table.insert(Wise._cpuEnterSamples, { frameMs = frameMs, addonSum = sum, top = top })
						while #Wise._cpuEnterSamples > 10 do
							table.remove(Wise._cpuEnterSamples, 1)
						end
					end)
				end)
				Wise._cpuEnterFrame = ef
				print(
					"|cff00ccff[Wise CPU]|r Combat-enter probe |cff00ff00armed|r. Engage/leave/re-engage a few"
						.. " times, then run |cffffd700/wise cpu enter|r again to see the spike breakdown."
				)
			end

			local samples = Wise._cpuEnterSamples
			if not samples or #samples == 0 then
				print("|cff00ccff[Wise CPU]|r No combat-enter samples yet — go into combat, then re-run.")
				return
			end

			print(string.format("|cff00ccff[Wise CPU]|r Last %d combat-enter frame(s):", #samples))
			for i = #samples, math.max(1, #samples - 4), -1 do
				local s = samples[i]
				local wiseMs = 0
				local parts = {}
				for _, r in ipairs(s.top) do
					if r.name == "Wise" then
						wiseMs = r.ms
					end
					parts[#parts + 1] = string.format("%s:%.1f", r.name, r.ms)
				end
				local blizzMs = s.frameMs - s.addonSum
				print(
					string.format(
						"  |cffffd700%.1f ms|r frame  (Wise |cff00ff00%.2f|r, addons %.1f, Blizz/secure ~%.1f)  %s",
						s.frameMs,
						wiseMs,
						s.addonSum,
						blizzMs > 0 and blizzMs or 0,
						table.concat(parts, ", ")
					)
				)
			end
			print(
				"  |cff999999Blizz/secure = frame minus addon CPU: WoW re-evaluating secure frames"
					.. " on combat lockdown (unavoidable, scales with total state drivers).|r"
			)
			return
		end

		-- Per-FUNCTION breakdown (12.0.7 restored GetFunctionCPUUsage).
		--   /wise cpu funcs  → rank Wise's own methods (Wise.*) by CPU since start.
		-- Fills the gap the per-frame report flags: cost in tickers / hooked scripts
		-- that GetFrameCPUUsage can't see, but which ARE Wise:Method() calls.
		if arg == "funcs" then
			if type(GetFunctionCPUUsage) ~= "function" then
				print("|cff00ccff[Wise CPU]|r GetFunctionCPUUsage unavailable on this client (needs 12.0.7+).")
				return
			end
			local window = Wise._cpuT0 and (GetTime() - Wise._cpuT0) or 0
			if window < 1 then
				print("|cff00ccff[Wise CPU]|r Run |cffffd700/wise cpu start|r first, wait, then |cffffd700/wise cpu funcs|r.")
				return
			end
			local rows = {}
			for key, val in pairs(Wise) do
				if type(val) == "function" then
					-- GetFunctionCPUUsage(func, includeSubroutines) → totalMs, callCount
					local ok, ms, calls = pcall(GetFunctionCPUUsage, val, false)
					if ok and ms and ms > 0 then
						rows[#rows + 1] = { name = "Wise:" .. key, ms = ms, calls = calls or 0 }
					end
				end
			end
			table.sort(rows, function(a, b)
				return a.ms > b.ms
			end)
			if #rows == 0 then
				print("|cff00ccff[Wise CPU]|r No Wise:Method() CPU recorded in this window (cost may be in local closures).")
				return
			end
			print(string.format("|cff00ccff[Wise CPU]|r Top Wise methods over %.0fs (self time, excl. subroutines):", window))
			for i = 1, math.min(14, #rows) do
				print(string.format(
					"  %2d. |cffffd700%.3f ms/s|r  %s  |cff999999(%d calls)|r",
					i, rows[i].ms / window, rows[i].name, rows[i].calls))
			end
			return
		end

		local window = Wise._cpuT0 and (GetTime() - Wise._cpuT0) or 0
		if window < 1 then
			print("|cff00ccff[Wise CPU]|r Run |cffffd700/wise cpu start|r first, wait, then |cffffd700/wise cpu|r.")
			return
		end

		UpdateAddOnCPUUsage()
		local total = GetAddOnCPUUsage("Wise") or 0

		-- Walk every Wise-owned frame (named "Wise*" or tagged _wiseProfileName)
		-- that has ANY script (OnUpdate or OnEvent). GetFrameCPUUsage(f, true)
		-- returns total time spent in all of the frame's scripts.
		local rows = {}
		local accounted = 0
		local f = EnumerateFrames()
		while f do
			local hasScript = f.GetScript and (f:GetScript("OnUpdate") or f:GetScript("OnEvent"))
			if hasScript then
				local nm = (f.GetName and f:GetName()) or nil
				local tag = f._wiseProfileName
				local isWise = tag or (nm and nm:find("^Wise"))
				if isWise then
					local ms = GetFrameCPUUsage and GetFrameCPUUsage(f, true) or 0
					if ms and ms > 0 then
						-- Note which script types this frame has, to hint at the source.
						local kinds = ""
						if f:GetScript("OnUpdate") then
							kinds = kinds .. "U"
						end
						if f:GetScript("OnEvent") then
							kinds = kinds .. "E"
						end
						rows[#rows + 1] = { name = (tag or nm) .. " [" .. kinds .. "]", ms = ms }
						accounted = accounted + ms
					end
				end
			end
			f = EnumerateFrames(f)
		end

		table.sort(rows, function(a, b)
			return a.ms > b.ms
		end)

		print(
			string.format(
				"|cff00ccff[Wise CPU]|r Over %.0fs: addon |cffffd700%.3f ms/s|r total, |cff00ff00%.3f ms/s|r in frames, |cffff5555%.3f ms/s|r elsewhere (tickers/handlers).",
				window,
				total / window,
				accounted / window,
				(total - accounted) / window
			)
		)
		for i = 1, math.min(14, #rows) do
			print(string.format("  %2d. |cffffd700%.3f ms/s|r  %s", i, rows[i].ms / window, rows[i].name))
		end
		if (total - accounted) / window > 1 then
			print(
				"  |cffff5555Most cost is NOT in frames|r → it's in C_Timer tickers or hooked scripts."
					.. " Likely a NewTicker or a hooked Blizzard frame."
			)
			if type(GetFunctionCPUUsage) == "function" then
				print(
					"  |cff999999Try |cffffd700/wise cpu funcs|cff999999 to attribute it to specific Wise methods.|r"
				)
			end
		end
		print(
			"  |cff999999For a one-time stutter the instant combat starts, use |cffffd700/wise cpu enter|cff999999.|r"
		)
		return
	end

	if cmd == "demo" then
		if arg == "reset" then
			WiseDB.tutorialComplete = false
			print("|cff00ccff[Wise]|r Tutorial reset. Reload UI or type '/wise demo start' to begin.")
		elseif arg == "start" then
			if Wise.Demo then
				Wise.Demo:Start()
			end
		elseif arg == "stop" then
			if Wise.Demo then
				Wise.Demo:Stop()
			end
		else
			print("|cff00ccff[Wise]|r Usage: /wise demo [start|stop|reset]")
		end
		return
	end

	if cmd == "resolve" then
		Wise.debugResolve = not Wise.debugResolve
		print(
			"|cff00ccff[Wise]|r Resolve debug "
				.. (Wise.debugResolve and "|cff00ff00ON|r — press keys to see what fires" or "|cffff0000OFF|r")
		)
		return
	end

	if cmd == "bugreport" then
		if Wise.ShowBugReportWindow then
			Wise:ShowBugReportWindow()
		else
			print("|cff00ccff[Wise]|r Bug Report module not loaded.")
		end
		return
	end

	if Wise.ToggleOptions then
		Wise:ToggleOptions()
	else
		print("|cff00ccff[Wise]|r Options not loaded properly.")
	end
end

-- Mechanic Tools Panel (shown in Mechanic's Tools tab)
function Wise:CreateMechanicToolsPanel(container)
	local function CreateToolButton(parent, x, y, width, text, onClick)
		local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
		btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
		btn:SetSize(width, 24)
		btn:SetText(text)
		btn:SetScript("OnClick", onClick)
		return btn
	end

	local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 10, -10)
	title:SetText("Wise Tools")

	local desc = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	desc:SetPoint("TOPLEFT", 10, -35)
	desc:SetText("Quick actions for Wise action bar addon.")

	-- Row 1: Options & Edit Mode
	local row1Label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row1Label:SetPoint("TOPLEFT", 10, -65)
	row1Label:SetText("Panels:")

	CreateToolButton(container, 80, -60, 120, "Open Options", function()
		if Wise.ToggleOptions then
			Wise:ToggleOptions()
		end
	end)

	CreateToolButton(container, 205, -60, 120, "Toggle Edit Mode", function()
		if not InCombatLockdown() and Wise.ToggleEditMode then
			Wise:ToggleEditMode()
		else
			print("|cff00ccffWise:|r Cannot toggle edit mode in combat.")
		end
	end)

	-- Row 2: Debug
	local row2Label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row2Label:SetPoint("TOPLEFT", 10, -100)
	row2Label:SetText("Debug:")

	CreateToolButton(container, 80, -95, 120, "Toggle Debug", function()
		if WiseDB and WiseDB.settings then
			WiseDB.settings.debug = not WiseDB.settings.debug
			if Wise.ToggleDebugInterface then
				Wise:ToggleDebugInterface(WiseDB.settings.debug)
			end
			print("|cff00ccffWise:|r Debug " .. (WiseDB.settings.debug and "ON" or "OFF"))
		end
	end)

	CreateToolButton(container, 205, -95, 120, "Bug Report", function()
		if Wise.ShowBugReportWindow then
			Wise:ShowBugReportWindow()
		end
	end)

	-- Row 3: Interfaces info
	local row3Label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row3Label:SetPoint("TOPLEFT", 10, -135)
	row3Label:SetText("Info:")

	CreateToolButton(container, 80, -130, 120, "List Interfaces", function()
		if WiseDB and WiseDB.groups then
			local count = 0
			for name, g in pairs(WiseDB.groups) do
				local status = (Wise.frames and Wise.frames[name] and Wise.frames[name]:IsShown())
						and "|cff00ff00shown|r"
					or "|cffff0000hidden|r"
				print(string.format("|cff00ccffWise:|r  %s [%s] %s", name, g.type or "?", status))
				count = count + 1
			end
			print(string.format("|cff00ccffWise:|r %d interface(s) total.", count))
		end
	end)

	CreateToolButton(container, 205, -130, 120, "Demo Tour", function()
		if Wise.Demo then
			Wise.Demo:Start()
		end
	end)

	local footer = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	footer:SetPoint("BOTTOM", 0, 10)
	footer:SetText("Use /wise for more options.")
end

function Wise:ToggleOptions()
	if not Wise.OptionsFrame then
		Wise:CreateOptionsFrame()
	end
	if Wise.OptionsFrame:IsShown() then
		Wise.OptionsFrame:Hide()
	else
		Wise.OptionsFrame:Show()
	end
end

-- Validation System
function Wise:ValidateGroup(groupName)
	local group = WiseDB.groups[groupName]
	if not group then
		return false, "Reference missing"
	end

	-- Check basic types
	if type(group) ~= "table" then
		return false, "Corrupted Data (Not a table)"
	end
	if type(group.type) ~= "string" then
		return false, "Missing 'type'"
	end

	-- Check structure
	if group.buttons and not group.actions then
		if group.isWiser or group.isSmartItem then
			return true -- Wiser/Smart Item interfaces use buttons, not actions
		else
			return false, "Old Data (Migration Needed)"
		end
	end

	if type(group.actions) ~= "table" then
		-- Smart Item interfaces don't use actions; they populate dynamically
		if group.isSmartItem then
			return true
		end
		return false, "Missing 'actions' table"
	end

	-- Check for mixed keys in actions (indicative of corruption)
	-- Also ensure anchor is valid
	if not group.anchor or type(group.anchor) ~= "table" then
		return false, "Missing anchor data"
	end

	-- Validate Slots
	for k, v in pairs(group.actions) do
		if type(k) == "number" and type(v) ~= "table" then
			return false, "Corrupted Slot " .. k
		end
	end

	return true
end
