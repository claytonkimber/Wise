-- wiser/vdc/Actions.lua
--
-- Turning a chosen item into a click: the destroy-confirmation safety net, the
-- secure button attributes, and cast tracking.
-- See wiser/vdc/Core.lua for the wiser's design notes.
--
-- SECURITY, and the reason BuildDisenchantMacro is not a macro: each slot is a
-- secure button written OUT OF COMBAT ONLY, using type="spell" plus
-- target-bag/target-slot attributes. There is deliberately no macrotext -- 11.x
-- removed macrotext execution of protected actions, and a bare `/use <bag>
-- <slot>` would EQUIP a wearable item instead of feeding it to the spell.
--
-- BuildConvertMacro alternates between distinct source items on consecutive
-- presses because different salvage spells sit on different cooldowns and GCDs;
-- alternating lets a second conversion fire while the first is still on GCD.
--
-- The confirm button is an opt-in safety net, not a bypass: it does not suppress
-- Blizzard's destroy popup. On each PreClick it looks up whichever recognised
-- popup is actually visible via StaticPopup_Visible() and points itself at that
-- popup's own button1; when none is up it clears its attributes and does nothing.
--
-- Loaded after Scan.lua, before Slots.lua.

local addonName, Wise = ...

local VDC = Wise.VDC

local SALVAGE = VDC.SALVAGE
local DISENCHANT_SPELL_ID = VDC.DISENCHANT_SPELL_ID

-- ---------------------------------------------------------------------------
-- Destroy-confirmation dismissal (opt-in safety net)
-- ---------------------------------------------------------------------------

-- The "equipping this item will bind it to you" prompt is GONE by construction:
-- the slots cast via type="spell" + target-bag/target-slot, so there is no /use
-- line that could equip anything (see BuildDisenchantMacro).
--
-- What can still appear is Blizzard's DESTROY confirmation on soulbound gear
-- ("Disenchanting will destroy it"). StaticPopup buttons are protected, so Lua
-- cannot click them from an event handler — the click must come from a macro
-- line on a real hardware press.
--
-- The naive version of this ("/click StaticPopup1Button1") is WRONG twice over:
--   * StaticPopup1 is whichever dialog happens to occupy slot 1. If anything else
--     is open — a trade, a summon, a ready check — the macro clicks THAT dialog's
--     first button instead. Blind-confirming an arbitrary popup is exactly the
--     kind of accident this feature must not cause.
--   * The relevant popup may not be showing at all on any given press.
--
-- Instead this mirrors the approach WarPlan uses for the same problem: a
-- dedicated button that, on each PreClick, looks up the REAL popup by name via
-- StaticPopup_Visible() and points itself at that popup's own button1. When none
-- of the recognised popups is up it clears its attributes and does nothing.
local confirmButton

local DESTROY_POPUPS = {
	"CONFIRM_DESTROY_ITEM",
	"CONFIRM_LOOT_DISTRIBUTION",
	"USE_BIND",
	"EQUIP_BIND",
	"AUTOEQUIP_BIND",
}

function VDC:GetConfirmButton()
	if confirmButton then
		return confirmButton
	end

	local name = "WiseVDCConfirmBindButton"
	local b = CreateFrame("Button", name, nil, "SecureActionButtonTemplate")
	b:RegisterForClicks("AnyUp")
	b:Hide()

	b:SetScript("PreClick", function(self)
		if InCombatLockdown() then
			return
		end
		-- Resolve which recognised popup (if any) is actually on screen, and aim
		-- at its real accept button. Anything else showing is left strictly alone.
		local target
		for _, popupName in ipairs(DESTROY_POPUPS) do
			local _, frame = StaticPopup_Visible(popupName)
			if frame and frame.button1 and frame.button1:IsShown() then
				target = frame.button1:GetName()
				break
			end
		end
		if target then
			self:SetAttribute("type", "click")
			self:SetAttribute("clickbutton", _G[target])
		else
			self:SetAttribute("type", nil)
			self:SetAttribute("clickbutton", nil)
		end
	end)

	b:SetScript("PostClick", function(self)
		if InCombatLockdown() then
			return
		end
		self:SetAttribute("type", nil)
		self:SetAttribute("clickbutton", nil)
	end)

	confirmButton = b
	return b
end

-- ---------------------------------------------------------------------------
-- Macro construction
-- ---------------------------------------------------------------------------

-- Disenchant: cast Disenchant on the top item when the player is an enchanter.
-- Otherwise, when the mail window is open, attach the items and send them to the
-- configured enchanter alt.
function VDC:BuildDisenchantMacro(list, group)
	if #list == 0 then
		return nil
	end
	local entry = list[1]
	local spellInfo = C_Spell.GetSpellInfo(DISENCHANT_SPELL_ID)
	local spellName = spellInfo and spellInfo.name

	if entry.hasEnchanting and spellName then
		-- Applied via type="spell" + target-bag/target-slot, NOT macrotext.
		--
		-- This is the only sanctioned way to cast a spell onto a specific bag
		-- item. The modern (11.x+) engine REMOVED macrotext execution of
		-- protected actions, so the old "/cast Disenchant" + "/use <bag> <slot>"
		-- macro is forbidden ("only available to the Blizzard UI"). Worse, when
		-- the /cast half was suppressed the /use half still ran on its own, and
		-- "/use <bag> <slot>" on a wearable item EQUIPS it — which is exactly
		-- what raised the "equipping this item will bind it to you" prompt on
		-- every press.
		--
		-- With target-bag/target-slot, SecureActionButton_OnClick casts the spell
		-- and, once SpellCanTargetItem() is true, calls UseContainerItem(bag,
		-- slot) itself. There is no /use line and therefore no equip path and no
		-- bind prompt. Spam safety comes free: the button re-casts the same spell
		-- at the same target, and a press during the cast is simply ignored.
		--
		-- (target-item is NOT this — it routes to SpellTargetItem, which wants an
		-- item NAME.)
		-- Store the spell ID, not the name. type="spell" accepts either, but
		-- Wise:IsActionKnown resolves a name back to an ID via
		-- C_Spell.GetSpellInfo — unreliable for Disenchant — and a failed resolve
		-- marks the action unknown, which greys the icon out.
		return {
			secureType = "spell",
			secureValue = DISENCHANT_SPELL_ID,
			attributes = {
				["target-bag"] = entry.bag,
				["target-slot"] = entry.slot,
			},
		}
	end

	-- Mail fallback. Attaching items and sending mail is not protected, so this
	-- runs as a /run body driven by the module's own helper.
	local recipient = group and group.vdcMailTarget
	if not recipient or recipient == "" then
		return nil
	end
	return { secureType = "macro", secureValue = "/run Wise.VDC:MailDisenchantables()" }
end

-- Convert: alternate between distinct source items on each press.
--
-- Different salvage spells have independent cooldowns and the GCD applies per
-- cast, so firing the same source twice in a row stalls on the GCD. Rotating
-- through the available sources lets the next press act on a different spell
-- immediately.
--
-- Uses the same type="spell" + target-bag/target-slot path as Disenchant (see
-- BuildDisenchantMacro) — no macrotext, so no /use line that could equip the
-- source item, and no bind prompt. The rotation advances on each rebuild, so
-- holding the key chains conversions across different salvage spells.
function VDC:BuildConvertMacro(list, group)
	if #list == 0 then
		return nil
	end
	-- Advance the rotation pointer, wrapping over the current candidate count.
	self.convertIndex = ((self.convertIndex or 0) % #list) + 1
	local entry = list[self.convertIndex]
	local spellName, spellID = self:GetSalvageSpellName(entry.itemLink, entry.kind)
	if not (spellName and spellID) then
		return nil
	end
	-- ID, not name — see BuildDisenchantMacro.
	return {
		secureType = "spell",
		secureValue = spellID,
		attributes = {
			["target-bag"] = entry.bag,
			["target-slot"] = entry.slot,
		},
	}
end

-- Attach and send disenchantable items to the configured enchanter. Mail APIs are
-- insecure, so this is a normal Lua path. Only runs with the mail window open.
function VDC:MailDisenchantables()
	local group = WiseDB.groups[self.GROUP_NAME]
	local recipient = group and group.vdcMailTarget
	if not recipient or recipient == "" then
		print("|cff00ccff[Wise]|r Set a Disenchant mail target in the interface options first.")
		return
	end
	if not (MailFrame and MailFrame:IsShown()) then
		print("|cff00ccff[Wise]|r Open your mailbox to send disenchantables.")
		return
	end

	-- ScanBags now returns disenchant FIRST (the vendor list is gone), so this
	-- takes the first return, not the second.
	local list = self:ScanBags()
	if #list == 0 then
		print("|cff00ccff[Wise]|r No disenchantable items match the current filters.")
		return
	end

	-- One mail carries up to 12 attachments.
	local attached = 0
	for _, entry in ipairs(list) do
		if attached >= 12 then
			break
		end
		C_Container.UseContainerItem(entry.bag, entry.slot)
		attached = attached + 1
	end

	if attached > 0 then
		SendMail(recipient, "Disenchant", "")
		print(string.format("|cff00ccff[Wise]|r Sent %d item(s) to %s.", attached, recipient))
	end
end

-- ---------------------------------------------------------------------------
-- Cast tracking
-- ---------------------------------------------------------------------------

-- Is the player currently casting one of the destroy-style spells this module
-- drives? Used to hold off macro rebuilds so a spammed button cannot have its
-- target swapped mid-cast.
function VDC:IsDestroyCastInProgress()
	if not (UnitCastingInfo and UnitChannelInfo) then
		return false
	end
	local castName = UnitCastingInfo("player")
	if not castName then
		castName = UnitChannelInfo("player")
	end
	if not castName then
		return false
	end
	return self.destroySpellNames and self.destroySpellNames[castName] or false
end

-- Is this the spell ID of a destroy cast this module drives? Used to filter
-- UNIT_SPELLCAST_* so an unrelated cast never triggers a bag scan.
function VDC:IsDestroySpellID(spellID)
	if not spellID then
		return false
	end
	return self.destroySpellIDs and self.destroySpellIDs[spellID] or false
end

-- Cache the localized names AND the IDs of every spell that counts as a destroy
-- cast, so both checks are hash lookups rather than per-call spell resolution.
function VDC:BuildDestroySpellNameCache()
	local names, ids = {}, {}
	local function add(spellID)
		if not spellID then
			return
		end
		ids[spellID] = true
		local info = C_Spell.GetSpellInfo(spellID)
		if info and info.name then
			names[info.name] = true
		end
	end
	add(DISENCHANT_SPELL_ID)
	for _, spells in pairs(SALVAGE) do
		add(spells.prospect)
		add(spells.mill)
	end
	self.destroySpellNames = names
	self.destroySpellIDs = ids
end

-- ---------------------------------------------------------------------------
-- Tooltip
-- ---------------------------------------------------------------------------

-- The secure action is type="spell", so the default tooltip would show the
-- Disenchant/Prospecting spell — useless for deciding whether to press it. This
-- provider shows the actual QUEUE instead: what the next press destroys, then
-- everything behind it, so the player can spot something they don't want to lose
-- before clicking.
local MAX_TOOLTIP_ROWS = 12

function VDC:BuildSlotTooltip(tooltip, button, actionData)
	local slotKey = actionData and actionData.vdcSlot
	if not slotKey then
		return false
	end
	local list = self.lastLists and self.lastLists[slotKey]

	tooltip:SetText(slotKey, 1, 0.82, 0)

	if not list or #list == 0 then
		tooltip:AddLine("Nothing matches the current filters.", 0.6, 0.6, 0.6)
		return true
	end

	tooltip:AddLine(
		slotKey == self.SLOT_CONVERT and "Next conversion, then the queue:" or "Next to disenchant, then the queue:",
		0.8, 0.8, 0.8
	)
	tooltip:AddLine(" ")

	local shown = math.min(#list, MAX_TOOLTIP_ROWS)
	for i = 1, shown do
		local entry = list[i]
		local label = entry.itemLink or "?"
		local gain = GetCoinTextureString(math.floor(entry.gain or 0))
		if i == 1 then
			-- Mark the head of the queue: this is what the next press acts on.
			tooltip:AddDoubleLine("> " .. label, gain, 0.4, 1, 0.4, 1, 0.82, 0)
		else
			tooltip:AddDoubleLine("   " .. label, gain, 0.9, 0.9, 0.9, 0.8, 0.7, 0.3)
		end
	end

	if #list > shown then
		tooltip:AddLine(string.format("...and %d more", #list - shown), 0.6, 0.6, 0.6)
	end

	tooltip:AddLine(" ")
	tooltip:AddLine("Right-click: skip the top item from now on", 1, 0.5, 0.5)

	local group = WiseDB.groups[self.GROUP_NAME]
	local ignoredCount = 0
	if group and group.vdcIgnored then
		for _ in pairs(group.vdcIgnored) do
			ignoredCount = ignoredCount + 1
		end
	end
	if ignoredCount > 0 then
		tooltip:AddLine(string.format("%d item(s) skipped — clear in options", ignoredCount), 0.6, 0.6, 0.6)
	end

	return true
end

-- Right-click a slot to drop its top item from the queue. The secure button has
-- no type2 attribute, so a right-click fires no protected action and this
-- insecure PostClick is free to handle it.
function VDC:HandleSlotRightClick(slotKey)
	local group = WiseDB.groups[self.GROUP_NAME]
	if not group then
		return
	end
	local list = self.lastLists and self.lastLists[slotKey]
	local entry = list and list[1]
	if not entry then
		return
	end

	self:SetIgnored(group, entry.itemID, true)
	print(string.format(
		"|cff00ccff[Wise]|r Skipping %s. Clear the skip list in the interface options.",
		entry.itemLink or ("item " .. tostring(entry.itemID))
	))

	-- Rebuild so the slot immediately advances to the next candidate. Refresh
	-- redraws any open tooltip itself (RefreshOpenTooltip).
	self:Refresh()
end

