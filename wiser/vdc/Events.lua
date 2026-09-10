-- wiser/vdc/Events.lua
--
-- Load-time registration: events, the right-click hook, and the
-- [available:<slot>] provider.
-- See wiser/vdc/Core.lua for the wiser's design notes.
--
-- This file has LOAD-TIME SIDE EFFECTS, so it loads LAST in wiser/vdc/ -- after
-- every function it wires up exists.
--
-- Refreshes are debounced through refreshTimer: BAG_UPDATE_DELAYED arrives in
-- bursts (a mass loot, a vendor sweep) and a rebuild is not cheap, so a burst
-- costs one rebuild rather than N (AGENTS.md Rule 12: coalesce, never poll).
--
-- The destroy path is the deliberate exception. It CANCELS the pending debounce
-- and re-scans on the NEXT frame, because the item is removed as the cast
-- completes and reading the container on the same frame still returns the old
-- contents.
--
-- Loaded last in wiser/vdc/.

local addonName, Wise = ...

local VDC = Wise.VDC


-- Bag changes, mail state, and combat exit all re-arm the slots.
-- Debounced so a mass loot or a vendor-sell sweep costs one rebuild, not N
-- (AGENTS.md Rule 12: coalesce event bursts, never poll).
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
-- Item data arrives asynchronously. At login most bag items are UNCACHED, and an
-- uncached item is skipped by the scan (C_Item.GetItemInfo returns nil), so the
-- first pass can legitimately find nothing. Without this the queue then sat empty
-- until some unrelated event happened to re-trigger a scan — which is why the
-- interface only appeared after visiting a mailbox or moving an item.
-- GET_ITEM_INFO_RECEIVED fires as each item resolves; it is debounced and
-- self-limiting (see the handler) so a login burst costs one rescan, not hundreds.
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
-- Mail only: the disenchant fallback attaches items with the mailbox open. No
-- MERCHANT_* registration — with the Vendor slot gone, nothing here reacts to a
-- merchant window, and refreshing on it was pure wasted work.
eventFrame:RegisterEvent("MAIL_SHOW")
eventFrame:RegisterEvent("MAIL_CLOSED")
-- Saving/deleting an equipment set changes what the protection filter excludes.
eventFrame:RegisterEvent("EQUIPMENT_SETS_CHANGED")
-- Cast completion. The destroyed item leaves the bags the instant the cast ends,
-- but BAG_UPDATE_DELAYED lands later and the generic 1s debounce delays it
-- further — which left the tooltip showing an item that no longer exists. These
-- fire the rebuild immediately instead. UNIT_SPELLCAST_SUCCEEDED is the "it
-- worked" signal; the STOP/INTERRUPTED pair clears the in-flight guard so a
-- cancelled cast doesn't leave the queue frozen until the next bag event.
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

local refreshTimer
eventFrame:SetScript("OnEvent", function(_, event, unit, castGUID, spellID)
	if event == "PLAYER_LOGIN" then
		-- Deliberate 3s delay before the first bag scan. This is a TRADE, not an
		-- oversight — do not "optimise" it away:
		--   * TSM/ProfitProphet are still loading their price databases at login.
		--     Scanning earlier reads missing prices, which silently produces an
		--     empty or wrong queue rather than a late one.
		--   * Item info is often uncached this early; uncached items are skipped
		--     for the pass, so an early scan would drop items until the next bag
		--     event anyway.
		--   * A full bag scan competes with everything else loading at login.
		--     Deferring keeps reload lag off the critical path.
		-- The visible cost is that the interface appears a few seconds after
		-- reload; with [available] seeded it simply stays hidden until then.
		C_Timer.After(3, function()
			VDC:Initialize()
			-- Bounded retries after the first scan. Item info resolves
			-- asynchronously, so the 3s pass can still see uncached items and come
			-- back empty. GET_ITEM_INFO_RECEIVED normally covers this, but it only
			-- fires for items the client actually requests — these retries make the
			-- interface appear on its own rather than waiting for the player to
			-- open a mailbox or move an item. They stop as soon as anything is
			-- queued, so a genuinely empty bag costs three cheap scans and no more.
			for _, delay in ipairs({ 3, 6, 10 }) do
				C_Timer.After(delay, function()
					if InCombatLockdown() or not VDC.slotCounts then
						return
					end
					for _, slotKey in ipairs(VDC.SLOT_ORDER) do
						if (VDC.slotCounts[slotKey] or 0) > 0 then
							return -- already populated; nothing to chase
						end
					end
					VDC:Refresh()
				end)
			end
		end)
		return
	end

	if event == "PLAYER_REGEN_ENABLED" then
		if not VDC.pendingRefresh then
			return
		end
		VDC.pendingRefresh = nil
	end

	-- Item data resolving. This fires once per item and can burst in the hundreds
	-- at login, so it is rate-limited two ways: it only matters while we still
	-- have nothing queued (once the lists are populated, BAG_UPDATE_DELAYED and
	-- the cast events own refreshing), and it rides the same 1s debounce below.
	if event == "GET_ITEM_INFO_RECEIVED" then
		if not VDC.slotCounts then
			-- Not initialised yet; the login timer will do the first scan.
			return
		end
		local anyQueued = false
		for _, slotKey in ipairs(VDC.SLOT_ORDER) do
			if (VDC.slotCounts[slotKey] or 0) > 0 then
				anyQueued = true
				break
			end
		end
		if anyQueued then
			return
		end
	end

	if InCombatLockdown() then
		VDC.pendingRefresh = true
		return
	end

	-- Cast finished: rebuild NOW rather than waiting out the bag-event debounce.
	-- Only for the spells this module drives, so an unrelated cast doesn't
	-- trigger a bag scan.
	if
		event == "UNIT_SPELLCAST_SUCCEEDED"
		or event == "UNIT_SPELLCAST_STOP"
		or event == "UNIT_SPELLCAST_INTERRUPTED"
	then
		if not VDC:IsDestroySpellID(spellID) then
			return
		end
		-- Cancel any queued debounce so we don't rebuild twice for one destroy.
		if refreshTimer then
			refreshTimer:Cancel()
			refreshTimer = nil
		end
		VDC.pendingRefresh = nil
		-- One frame of slack: the item is removed as the cast completes, and
		-- reading the container on the same frame can still see the old contents.
		C_Timer.After(0, function()
			if not InCombatLockdown() then
				VDC:Refresh()
			end
		end)
		return
	end

	if refreshTimer then
		return
	end
	refreshTimer = C_Timer.NewTimer(1, function()
		refreshTimer = nil
		VDC:Refresh()
	end)
end)
