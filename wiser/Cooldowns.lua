local addonName, Wise = ...

-- Bit set in a cooldown's `flags` (CooldownViewerCooldownInfo) when the Cooldown
-- Manager treats it as "not displayed" — i.e. assigned to the category but hidden
-- from the actual bar by default (maintenance/rotational abilities like Moonfire,
-- Prowl, Regrowth, Rake, Ironfur). The category set (GetCooldownViewerCategorySet)
-- returns these alongside the displayed ones, so the hidden-viewer fallback must
-- filter them out to mirror the CDM exactly. Enum.CooldownViewerCooldownFlag is not
-- exposed to addons, so we test the literal bit (verified live: every default-hidden
-- ability reports flags=2, every displayed cooldown reports flags=0).
local COOLDOWN_FLAG_HIDDEN = 0x2

-- True when the cooldown info marks the spell as not-displayed in the CDM. Uses
-- bit.band so additional flag bits (e.g. flags=2 is "hidden"; other bits may appear)
-- don't break the test.
local function isCooldownHidden(info)
	if not info or not info.flags then
		return false
	end
	return bit.band(info.flags, COOLDOWN_FLAG_HIDDEN) ~= 0
end

-- Register property hook for CooldownWiser interfaces
function Wise:InitializeCooldownWiser()
	-- Initialize hook for CooldownWiser
	Wise.PropertyHooks = Wise.PropertyHooks or {}
	Wise.PropertyHooks["CooldownWiser"] = {
		suppress = {
			Actions = false, -- We want to allow editing actions to add decimal slots
			Rename = true, -- Usually shouldn't rename Wiser interfaces
		},
		inject = {
			Bottom = function(panel, group, y)
				local tinsert = table.insert
				local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
				check:SetSize(24, 24)
				check:SetPoint("TOPLEFT", 10, y)
				check.text = check:CreateFontString(nil, "OVERLAY", "GameFontNormal")
				check.text:SetPoint("LEFT", check, "RIGHT", 4, 1)
				check.text:SetText("Hide Game Interface")
				check:SetChecked(group.hideNativeInterface or false)

				check:SetScript("OnClick", function(self)
					group.hideNativeInterface = self:GetChecked()
					Wise:UpdateCooldownWiser(Wise.selectedGroup, group.viewerName)
				end)

				tinsert(panel.controls, check)
				tinsert(panel.controls, check.text)

				return y - 30
			end,
		},
	}
end

-- Initialize the property hook
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event)
	Wise:InitializeCooldownWiser()
end)

-- Hook Blizzard viewer Layout so we re-sync whenever the viewer rebuilds its
-- children (spec change, reload, talent swap, etc.).  This eliminates all
-- timing guesswork — we read the children right after Blizzard finishes
-- populating them.
do
	local hookedViewers = {}
	local pendingResync = {}

	function Wise:HookCooldownViewerLayout(viewerName, groupName)
		if hookedViewers[viewerName] then
			return
		end
		local viewer = _G[viewerName]
		if not viewer then
			return
		end
		hookedViewers[viewerName] = true

		hooksecurefunc(viewer, "Layout", function()
			-- Debounce: Layout can fire many times in quick succession
			if pendingResync[groupName] then
				return
			end
			pendingResync[groupName] = true
			C_Timer.After(0, function()
				pendingResync[groupName] = nil
				-- Skip during combat: spell list can't change mid-fight and
				-- frame properties may be secret values that crash table ops.
				if InCombatLockdown() then
					return
				end
				local group = WiseDB and WiseDB.groups[groupName]
				if not group or not group.viewerName then
					return
				end
				Wise:_ReadCooldownViewer(groupName, group.viewerName)
			end)
		end)
	end
end

function Wise:UpdateCooldownWiser(groupName, viewerName)
	local group = WiseDB.groups[groupName]
	if not group then
		return
	end

	local viewer = _G[viewerName]
	if not viewer then
		return
	end

	group.viewerName = viewerName

	-- Hook the viewer's Layout so future rebuilds (spec change, etc.) auto-sync
	if Wise.HookCooldownViewerLayout then
		Wise:HookCooldownViewerLayout(viewerName, groupName)
	end

	-- Read the spell list into Wise's mirrored group. Visibility of the native
	-- viewer is owned separately by Wise:SetViewerVisibility (Edit Mode setting);
	-- we do NOT show/hide the frame here. Read the children first while they're
	-- still populated, THEN apply the hide setting so a freshly-hidden viewer
	-- doesn't blank out before we've mirrored its spells.
	Wise:_ReadCooldownViewer(groupName, viewerName)

	if Wise.SetViewerVisibility then
		Wise:SetViewerVisibility(viewerName, group.hideNativeInterface)
	end
end

-- Internal: read spells from a Blizzard CooldownViewer and sync to group actions
function Wise:_ReadCooldownViewer(groupName, viewerName)
	-- Frame child properties (spellID, layoutIndex) are secret values during
	-- combat that cannot be used as table keys or in comparisons. Defer the
	-- sync until combat ends — the spell list cannot change mid-fight anyway.
	if InCombatLockdown() then
		Wise._pendingViewerSync = Wise._pendingViewerSync or {}
		Wise._pendingViewerSync[groupName] = viewerName
		return
	end

	local group = WiseDB.groups[groupName]
	if not group then
		return
	end

	local viewer = _G[viewerName]
	if not viewer then
		return
	end

	local spells = {}
	local seen = {}

	local function addSpell(spellID)
		if not spellID then
			return
		end
		-- tonumber(tostring(...)) forces a fresh untainted number. Plain tonumber()
		-- on an already-numeric value returns the same (possibly tainted) value,
		-- which is why we route through tostring first. Secrets cannot be used as
		-- table keys or in comparisons, so we skip any value that can't be converted.
		spellID = tonumber(tostring(spellID))
		if not spellID then
			return
		end
		-- Normalize to override spell so base+override don't appear as two entries
		local resolvedID = Wise:GetOverrideSpellID(spellID) or spellID
		resolvedID = tonumber(tostring(resolvedID))
		if resolvedID and not seen[resolvedID] then
			seen[resolvedID] = true
			table.insert(spells, resolvedID)
		end
	end

	-- The viewer's CHILDREN are the ground truth of what the Cooldown Manager
	-- actually DISPLAYS — already excludes the "Not Displayed" spells, off-spec
	-- spells, etc. The category API (GetCooldownViewerCategorySet) does NOT: it
	-- returns every cooldown assigned to the category including not-displayed ones.
	-- So we prefer the children and cache the resulting cooldownID list per spec,
	-- falling back to the cache (then the category set) only when no children are
	-- readable — see the readFromChildren branch below.
	--
	-- A laid-out cooldown item carries a stable cooldownID. NOTE (12.0.7): when the
	-- viewer is hidden (hideNativeInterface), Blizzard now CLEARS the children's
	-- cooldownID (and IsShown() goes false), so a hidden viewer yields no readable
	-- children at all — we must fall back to the cached cooldownID list below. We key
	-- "this child is a real item" off cooldownID rather than IsShown()/GetSpellID
	-- (the GetSpellID method exists on spare frames too, which previously made every
	-- frame look displayed and suppressed the cache fallback).
	local function childIsDisplayed(child)
		return child.cooldownID ~= nil
	end

	local displayedCooldownIDs = {}
	-- True only when the children actually yielded at least one usable spell, so an
	-- empty/hidden viewer (no readable children) correctly falls through to the cache
	-- replay instead of overwriting the persisted set with nothing.
	local readFromChildren = false
	if viewer.GetChildren then
		local children = { viewer:GetChildren() }
		table.sort(children, function(a, b)
			local ai = tonumber(a.layoutIndex) or 0
			local bi = tonumber(b.layoutIndex) or 0
			return ai < bi
		end)

		for _, child in ipairs(children) do
			if childIsDisplayed(child) then
				local spellID

				-- Prefer the cooldown-info's representative spell over child:GetSpellID().
				-- "System dynamic" cooldowns (Flying Serpent Kick, Wild Charge, ...) carry
				-- a linkedSpellIDs array of per-form/context variants; child:GetSpellID()
				-- returns whichever ONE is active right now, so it bakes an arbitrary
				-- variant into the slot. info.overrideSpellID/spellID is the stable spell
				-- the Cooldown Manager treats as the slot's identity, so we use that.
				if
					child.cooldownID
					and C_CooldownViewer
					and C_CooldownViewer.GetCooldownViewerCooldownInfo
				then
					local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(child.cooldownID)
					if info then
						spellID = info.overrideSpellID or info.spellID
					end
				end

				-- Fallbacks for entries with no cooldownID (older clients / static slots).
				if not spellID then
					spellID = child.spellID
				end
				if not spellID and child.GetSpellID then
					spellID = child:GetSpellID()
				end

				local cid = tonumber(tostring(child.cooldownID))
				if cid then
					table.insert(displayedCooldownIDs, cid)
				end
				if spellID then
					readFromChildren = true
				end
				addSpell(spellID)
			end
		end
	end

	if readFromChildren then
		-- Persist the displayed cooldownID list (keyed per spec) so we can repopulate
		-- the mirror after the viewer is hidden — including across logins where the
		-- viewer loads already-hidden and never populates children.
		group.displayedCooldownIDs = group.displayedCooldownIDs or {}
		local specIndex = GetSpecialization()
		group.displayedCooldownIDs[specIndex or 0] = displayedCooldownIDs
	elseif C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
		-- Children yielded nothing — the viewer is hidden (12.0.7 clears children's
		-- cooldownID when hidden) or not laid out yet.
		--
		-- Prefer the CATEGORY SET. It's independent of viewer visibility AND always
		-- reflects the CURRENT character: GetCooldownViewerCategorySet(cat, false)
		-- returns the learned cooldowns for this character's spec, and isKnown drops
		-- the rest. The set also includes cooldowns the CDM hides by default (flags
		-- bit 0x2 — Moonfire, Prowl, Ironfur, ...), which the visible viewer's children
		-- never show, so we additionally drop isCooldownHidden() to mirror the CDM 1:1.
		-- We deliberately do NOT use the per-spec displayedCooldownIDs cache
		-- as the primary source here — it is keyed by spec INDEX only, so a Guardian
		-- Druid (spec 3) and a Shadow Priest (spec 3) collide and the cache leaks the
		-- wrong class's cooldowns into the other (this is exactly the FSK-on-Druid /
		-- stale-Utilities bug). The category set has no such ambiguity.
		local readFromCategory = false
		if C_CooldownViewer.GetCooldownViewerCategorySet and Enum and Enum.CooldownViewerCategory then
			local categoryByViewer = {
				EssentialCooldownViewer = Enum.CooldownViewerCategory.Essential,
				UtilityCooldownViewer = Enum.CooldownViewerCategory.Utility,
			}
			local category = categoryByViewer[viewerName]
			if category then
				local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category, false)
				if ok and ids then
					readFromCategory = true
					for _, cid in ipairs(ids) do
						local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cid)
						if info and info.isKnown and not isCooldownHidden(info) then
							addSpell(info.overrideSpellID or info.spellID)
						end
					end
				end
			end
		end

		-- Last resort (pre-12.0.5 clients with no category API): replay this spec's
		-- cached displayed set. Subject to the spec-index collision noted above, so
		-- only used when the category API is entirely unavailable.
		if not readFromCategory and group.displayedCooldownIDs then
			local specIndex = GetSpecialization() or 0
			local cached = group.displayedCooldownIDs[specIndex]
			if cached then
				for _, cid in ipairs(cached) do
					local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cid)
					if info and info.isKnown and not isCooldownHidden(info) then
						addSpell(info.overrideSpellID or info.spellID)
					end
				end
			end
		end
	end

	if Wise.MigrateGroupToActions then
		Wise:MigrateGroupToActions(group)
	end

	group.actions = group.actions or {}
	-- CooldownWiser groups must stay static. Dynamic mode collapses on-cooldown
	-- and unknown actions, which makes the bar resize as cooldowns tick — and
	-- we can't resize during combat anyway because of secure-frame lockdown.
	-- Slot count can still change when the auto-loaded spell list changes
	-- (spec/talent swap re-runs this function and rewrites integer slots).
	group.dynamic = false
	group.propertyType = "CooldownWiser"

	-- Bail out of the destructive rewrite if we resolved NO spells. At login the
	-- Blizzard viewer's children are often not laid out yet (readFromChildren=false)
	-- and the per-spec cache may be empty, so `spells` comes back empty. Wiping the
	-- integer slots here would blank the interface (it then looks like it "didn't
	-- show up"). Instead, leave the existing slots untouched and schedule a retry —
	-- the viewer's Layout hook will also fire once it populates. This is the 12.0.7
	-- login-timing regression fix.
	if #spells == 0 then
		Wise:_RetryCooldownViewerSync(groupName, viewerName)
		return
	end

	-- Replace all integer (auto-loaded) slots with the viewer's current spells 1:1.
	-- Viewer spell 1 → Slot 1, viewer spell 2 → Slot 2, etc.
	-- User-added decimal slots (e.g. 1.1, 2.5) are preserved untouched.

	-- 1. Remove all existing integer slots (auto-loaded content from previous spec)
	local keysToRemove = {}
	for slotIdx in pairs(group.actions) do
		if type(slotIdx) == "number" and slotIdx == math.floor(slotIdx) then
			table.insert(keysToRemove, slotIdx)
		end
	end
	for _, k in ipairs(keysToRemove) do
		group.actions[k] = nil
	end

	-- 2. Write current viewer spells into integer slots 1..N
	for i = 1, #spells do
		local spellID = spells[i]
		group.actions[i] = {
			{ type = "spell", value = spellID, autoLoaded = true },
		}
	end

	-- A successful read clears any pending retry for this group.
	if Wise._cooldownSyncRetry then
		Wise._cooldownSyncRetry[groupName] = nil
	end

	if Wise.UpdateGroupDisplay and Wise.frames[groupName] then
		Wise:UpdateGroupDisplay(groupName)
	end
end

-- Retry a viewer sync a few times after an empty read (viewer children not laid out
-- yet at login). Bounded so we don't spin forever if the viewer is legitimately empty
-- (e.g. a spec with no utility cooldowns). Combat is skipped — the spell list can't
-- change mid-fight and secret frame values would crash table ops.
function Wise:_RetryCooldownViewerSync(groupName, viewerName)
	Wise._cooldownSyncRetry = Wise._cooldownSyncRetry or {}
	local attempts = (Wise._cooldownSyncRetry[groupName] or 0) + 1
	Wise._cooldownSyncRetry[groupName] = attempts
	if attempts > 5 then
		return
	end
	C_Timer.After(0.5 * attempts, function()
		if InCombatLockdown() then
			return
		end
		local group = WiseDB and WiseDB.groups and WiseDB.groups[groupName]
		if group and group.viewerName then
			Wise:_ReadCooldownViewer(groupName, group.viewerName)
		end
	end)
end
