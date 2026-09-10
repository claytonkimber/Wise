-- wiser/vdc/Slots.lua
--
-- What the player sees: the queue tooltip, and rebuilding the two slots from a
-- fresh scan.
-- See wiser/vdc/Core.lua for the wiser's design notes.
--
-- The tooltip deliberately shows the QUEUE rather than the spell. A default
-- tooltip here would describe Disenchanting or Prospecting -- useless for
-- deciding whether to press the button. Showing what the next press destroys,
-- and what is behind it, lets the player spot something they did not mean to
-- lose BEFORE clicking. That is the whole point of the panel.
--
-- Refresh is out-of-combat only: writing action data leads to secure attribute
-- writes downstream (AGENTS.md Rule 1). Callers that might fire in combat must
-- defer, which is what the event handling in Setup.lua does.
--
-- Loaded after Actions.lua, before Setup.lua.

local addonName, Wise = ...

local VDC = Wise.VDC

local SLOT_EMPTY_ICON = VDC.SLOT_EMPTY_ICON

-- ---------------------------------------------------------------------------
-- Slot population
-- ---------------------------------------------------------------------------

-- Rebuild the interface's two slots from a fresh bag scan. Out of combat only —
-- writing action data leads to secure attribute writes downstream.
function VDC:Refresh()
	if InCombatLockdown() then
		self.pendingRefresh = true
		return
	end
	-- Never rewrite the actions while a Disenchant/prospect/mill is in flight.
	-- Destroying an item fires BAG_UPDATE_DELAYED mid-cast; rebuilding here would
	-- repoint the button at a different bag slot underneath the running cast, so
	-- the press that lands next would act on an item the player never chose.
	--
	-- The normal wake-up is UNIT_SPELLCAST_SUCCEEDED/STOP/INTERRUPTED, which fires
	-- the rebuild the moment the cast ends. This short retry is only a safety net
	-- for a cast that ends without any of those reaching us; keep it well under
	-- one GCD so a stale queue can never sit visible in the tooltip.
	if self:IsDestroyCastInProgress() then
		self.pendingRefresh = true
		C_Timer.After(0.2, function()
			if VDC.pendingRefresh then
				VDC.pendingRefresh = nil
				VDC:Refresh()
			end
		end)
		return
	end
	if not (WiseDB and WiseDB.groups) then
		return
	end
	if not self:IsAvailable() then
		return
	end

	local group = WiseDB.groups[self.GROUP_NAME]
	if not group then
		return
	end

	local disenchant, convert = self:ScanBags()

	local lists = {
		[self.SLOT_DISENCHANT] = disenchant,
		[self.SLOT_CONVERT] = convert,
	}
	local builders = {
		[self.SLOT_DISENCHANT] = self.BuildDisenchantMacro,
		[self.SLOT_CONVERT] = self.BuildConvertMacro,
	}

	-- Rebuild every slot from scratch. The interface is NOT dynamic (see
	-- EnsureGroups), so slot indices stay stable at 1/2/3 and the bar keeps its
	-- shape even when a slot has nothing to offer.
	group.actions = {}
	group.slotNames = group.slotNames or {}
	self.slotCounts = {}
	-- Keep the resolved lists so the tooltip can show the live queue without
	-- re-scanning bags on every mouseover.
	self.lastLists = lists

	for index, slotKey in ipairs(self.SLOT_ORDER) do
		local list = lists[slotKey]
		-- Builders return a descriptor: { secureType, secureValue, attributes }.
		-- Disenchant/Convert use type="spell" + target-bag/target-slot (the only
		-- sanctioned way to cast onto a bag item); the mail fallback uses a macro.
		local action = builders[slotKey](self, list, group)
		group.slotNames[index] = slotKey
		self.slotCounts[slotKey] = #list

		local top = list[1]
		if action and top then
			group.actions[index] = {
				{
					type = action.secureType == "spell" and "spell" or "macro",
					value = action.secureValue,
					secureAttributes = action.attributes,
					-- Name carries the queue depth and the gain of the top item, so
					-- the tooltip answers "what will this press do, and how many are
					-- waiting" without opening the bags.
					name = string.format(
						"%s: %s (%d queued, +%s)",
						slotKey,
						top.itemLink,
						#list,
						GetCoinTextureString(math.floor(top.gain or 0))
					),
					icon = C_Item.GetItemIconByID(top.itemID),
					category = "global",
					autoLoaded = true,
					-- Show the queue instead of the raw spell tooltip, and let the
					-- right-click handler know which slot it is acting on.
					tooltipProvider = "VDC",
					vdcSlot = slotKey,
					-- Disenchant/Prospecting/Milling are spell-TARGETING casts:
					-- C_Spell.IsSpellUsable reports false until something is on the
					-- targeting cursor, so the usability pass would grey the icon
					-- permanently. The slot's real "can I press this" answer is the
					-- per-slot condition below, so skip the spell-usability check.
					alwaysUsable = true,
					-- Disenchant/Prospecting/Milling live on PROFESSION skill lines,
					-- not the Player spell bank Wise:IsActionKnown scans, and
					-- IsPlayerSpell reports false for them. Unknown actions are
					-- desaturated AND dropped outright from a dynamic group, so the
					-- slot must opt out of that check.
					alwaysKnown = true,
					-- These conditions gate VISIBILITY only. Without this flag they
					-- would also be baked into the secure action, turning the cast
					-- into "/cast [actionbar:99] Disenchant" (always-false) and
					-- discarding target-bag/target-slot — a button that shows but
					-- does nothing.
					visibilityOnlyConditions = true,
					-- Per-slot gate: this button shows only while THIS slot has
					-- something queued. The group is dynamic, so the renderer
					-- evaluates this and drops the slot when it does not match.
					conditions = string.format("[available:%s]", slotKey),
				},
			}
		else
			-- Nothing qualifies for this slot. Keep an entry so the slot still
			-- exists (and stays configurable), but gate it on the same per-slot
			-- condition — which is false right now, so the dynamic renderer drops
			-- the button entirely instead of showing a dead icon.
			group.actions[index] = {
				{
					type = "macro",
					value = "",
					name = slotKey .. ": nothing matches the current filters",
					icon = SLOT_EMPTY_ICON[slotKey],
					category = "global",
					autoLoaded = true,
					tooltipProvider = "VDC",
					vdcSlot = slotKey,
					alwaysUsable = true,
					alwaysKnown = true,
					visibilityOnlyConditions = true,
					conditions = string.format("[available:%s]", slotKey),
				},
			}
		end
	end

	if Wise.frames[self.GROUP_NAME] then
		Wise:UpdateGroupDisplay(self.GROUP_NAME)
		-- Buttons may have been rebuilt by the display update, so re-attach the
		-- right-click handler (guarded per button, so this is idempotent).
		self:HookSlotRightClick()
	end

	-- Redraw a tooltip that is already on screen. Rebuilding the lists does not
	-- touch an open GameTooltip, so without this the player keeps reading the
	-- pre-cast queue — including the item that was just destroyed — until they
	-- move the mouse off the button and back on.
	self:RefreshOpenTooltip()
end

-- Re-run the OnEnter of whichever of our buttons the mouse is currently over, so
-- an open queue tooltip reflects the new lists immediately.
function VDC:RefreshOpenTooltip()
	if not (GameTooltip and GameTooltip:IsShown()) then
		return
	end
	local owner = GameTooltip.GetOwner and GameTooltip:GetOwner()
	if not (owner and owner.GetScript) then
		return
	end
	-- Only redraw for our own slots; never touch another addon's tooltip.
	local meta = Wise.buttonMeta and Wise.buttonMeta[owner]
	local data = (meta and meta.actionData) or owner.actionData
	if not (data and data.tooltipProvider == "VDC") then
		return
	end
	local onEnter = owner:GetScript("OnEnter")
	if onEnter then
		onEnter(owner)
	end
end

-- ---------------------------------------------------------------------------
-- Interface creation and events
-- ---------------------------------------------------------------------------

-- Migration: earlier builds shipped (a) three separate interfaces, then (b) one
-- combined "Disenchant/Vendor/Convert". Fold any saved settings forward and
-- remove the stale groups so upgrading users don't keep dead bars around.
local LEGACY_GROUPS = { "Vendor", "Disenchant", "Convert", "Disenchant/Vendor/Convert" }

function VDC:MigrateLegacyGroups(group)
	if group.vdcMigratedNoVendor_v2 then
		return
	end
	for _, legacyName in ipairs(LEGACY_GROUPS) do
		local legacy = WiseDB.groups[legacyName]
		-- Only touch groups this module created, never a same-named user bar.
		if legacy and legacy.propertyType == "VendorDisenchantConvert" and legacy ~= group then
			if legacy.vdcFilters then
				group.vdcFilters = group.vdcFilters or {}
				-- Carry forward only the slots that still exist. The Vendor slot is
				-- gone (too many variables to resolve behind one click), so its saved
				-- filters are intentionally dropped rather than migrated.
				for _, slotKey in ipairs(VDC.SLOT_ORDER) do
					if legacy.vdcFilters[slotKey] and not group.vdcFilters[slotKey] then
						group.vdcFilters[slotKey] = legacy.vdcFilters[slotKey]
					end
				end
			end
			if legacy.vdcMailTarget and legacy.vdcMailTarget ~= "" then
				group.vdcMailTarget = group.vdcMailTarget or legacy.vdcMailTarget
			end
			if legacy.vdcAutoConfirmBind ~= nil and group.vdcAutoConfirmBind == nil then
				group.vdcAutoConfirmBind = legacy.vdcAutoConfirmBind
			end
			-- Preserve where the user had placed the old bar.
			if legacy.anchor and not group.vdcInheritedAnchor then
				group.anchor = legacy.anchor
				group.vdcInheritedAnchor = true
			end
			WiseDB.groups[legacyName] = nil
			if Wise.frames[legacyName] then
				Wise.frames[legacyName]:Hide()
				Wise.frames[legacyName] = nil
			end
		end
	end
	-- Drop any Vendor filters saved directly on this group by an earlier version.
	if group.vdcFilters then
		group.vdcFilters.Vendor = nil
	end
	group.vdcMigratedCombined_v1 = true
	group.vdcMigratedNoVendor_v2 = true
end

function VDC:EnsureGroups()
	local name = self.GROUP_NAME
	if not WiseDB.groups[name] then
		Wise:CreateGroup(name, "circle")
		WiseDB.groups[name].enabled = false
	end
	local group = WiseDB.groups[name]
	group.isWiser = true
	group.propertyType = "VendorDisenchantConvert"

	-- Dynamic: each slot shows only when IT has something to do. Only dynamic
	-- groups evaluate per-slot conditions, which is what lets [available:<slot>]
	-- hide an idle Disenchant button while Convert is showing. The bar does
	-- reflow as a result — that is the intended trade: a button that cannot do
	-- anything is worse than a stable position.
	group.dynamic = true

	self:MigrateLegacyGroups(group)

	for _, slotKey in ipairs(self.SLOT_ORDER) do
		self:GetFilters(group, slotKey)
	end

	-- Protect equipment-set gear by default. Set here (not in the options panel)
	-- so it holds for players who never open the panel — destroying saved gear is
	-- irreversible, so the safe default must not depend on the UI being visited.
	if group.vdcProtectEquipmentSets == nil then
		group.vdcProtectEquipmentSets = true
	end

	-- Default visibility: show out of combat only while something is actionable.
	-- Seeded once so the interface is useful immediately; the user is free to edit
	-- or clear it afterwards (vdcSeededVisibility_v1 stops us re-applying it).
	if not group.vdcSeededVisibility_v1 then
		group.visibilitySettings = group.visibilitySettings or {}
		if not group.visibilitySettings.customShow or group.visibilitySettings.customShow == "" then
			group.visibilitySettings.customShow = "[nocombat,available]"
		end
		group.vdcSeededVisibility_v1 = true
	end
end

function VDC:Initialize()
	if not (WiseDB and WiseDB.groups) then
		return
	end
	self:BuildDestroySpellNameCache()
	self:EnsureGroups()

	-- Availability, answered at two scopes:
	--   [available]            — the interface as a whole (any slot has a match),
	--                            which drives whether the bar shows at all.
	--   [available:Disenchant] — that ONE slot, which drives whether that button
	--                            shows. Each slot carries this as its per-slot
	--                            condition, so Convert appearing never drags an
	--                            empty Disenchant button onto the bar with it.
	Wise:RegisterAvailabilityProvider(self.GROUP_NAME, function(_, key)
		if not VDC.slotCounts then
			return false
		end
		if key then
			return (VDC.slotCounts[key] or 0) > 0
		end
		for _, slotKey in ipairs(VDC.SLOT_ORDER) do
			if (VDC.slotCounts[slotKey] or 0) > 0 then
				return true
			end
		end
		return false
	end)

	-- Queue tooltip, opted into per-action via actionData.tooltipProvider.
	if Wise.RegisterTooltipProvider then
		Wise:RegisterTooltipProvider("VDC", function(tooltip, button, actionData)
			return VDC:BuildSlotTooltip(tooltip, button, actionData)
		end)
	end

	self:HookSlotRightClick()
	Wise:InitializeVDCProperties()
	self:Refresh()
end

-- Attach the right-click handler to this interface's buttons. Re-run after each
-- display rebuild because buttons are recreated. PostClick is insecure and fires
-- after the secure action (which does nothing on button 2, since no type2 is set).
function VDC:HookSlotRightClick()
	local frame = Wise.frames and Wise.frames[self.GROUP_NAME]
	if not (frame and frame.buttons) then
		return
	end
	for _, btn in ipairs(frame.buttons) do
		if not btn._vdcRightClickHooked then
			btn:HookScript("PostClick", function(self_btn, mouseButton, down)
				-- Buttons register AnyUp+AnyDown; act on the up edge only.
				if down or mouseButton ~= "RightButton" then
					return
				end
				local meta = Wise.buttonMeta and Wise.buttonMeta[self_btn]
				local data = (meta and meta.actionData) or self_btn.actionData
				local slotKey = data and data.vdcSlot
				if slotKey then
					VDC:HandleSlotRightClick(slotKey)
				end
			end)
			btn._vdcRightClickHooked = true
		end
	end
end

