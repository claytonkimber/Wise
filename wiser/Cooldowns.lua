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

	-- Read the spell list into Wise's mirrored group. Visibility of the native
	-- viewer is owned separately by Wise:SetViewerVisibility (Edit Mode setting);
	-- we do NOT show/hide the frame here.
	Wise:_ReadCooldownViewer(groupName, viewerName)

	if Wise.SetViewerVisibility then
		Wise:SetViewerVisibility(viewerName, group.hideNativeInterface)
	end
end

-- Internal: read spells from a Blizzard CooldownViewer and sync to group actions
function Wise:_ReadCooldownViewer(groupName, viewerName)
	-- C_CooldownViewer's spellID/cooldownID values can be secret during combat
	-- (cannot be used as table keys or in comparisons). Defer the sync until
	-- combat ends — the spell list cannot change mid-fight anyway.
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

	-- We source the spell list ENTIRELY from the C_CooldownViewer API, never by
	-- reading the Blizzard viewer's frame children. hooksecurefunc()'ing the
	-- viewer's Layout and iterating GetChildren() (the previous approach) reads
	-- protected frame properties (cooldownID, layoutIndex, GetSpellID) on a
	-- secure Blizzard frame — AGENTS.md Rule 8 forbids this because it spreads
	-- 'Wise' taint onto those frames' tables. That taint then surfaces later as
	-- "attempted to index a table that cannot be accessed while tainted" deep in
	-- Blizzard's own CacheCooldownValues/CheckCacheCooldownValuesFromSpellCooldown,
	-- unrelated to anything Wise directly touches at that point.
	--
	-- GetCooldownViewerCategorySet(category, false) returns the learned cooldowns
	-- for this character's CURRENT spec (isKnown drops the rest), sourced from the
	-- same ordered data provider Blizzard's viewer itself reads from — independent
	-- of viewer visibility, so no children-populated timing to chase. It also
	-- includes cooldowns the CDM hides by default (flags bit 0x2 — Moonfire, Prowl,
	-- Ironfur, ...), which we drop via isCooldownHidden() to mirror the CDM 1:1.
	local readFromCategory = false
	if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet and C_CooldownViewer.GetCooldownViewerCooldownInfo and Enum and Enum.CooldownViewerCategory then
		local categoryByViewer = {
			EssentialCooldownViewer = Enum.CooldownViewerCategory.Essential,
			UtilityCooldownViewer = Enum.CooldownViewerCategory.Utility,
		}
		local category = categoryByViewer[viewerName]
		if category then
			local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category, false)
			if ok and ids then
				readFromCategory = true
				local displayedCooldownIDs = {}
				for _, cid in ipairs(ids) do
					local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cid)
					if info and info.isKnown and not isCooldownHidden(info) then
						local numericCid = tonumber(tostring(cid))
						if numericCid then
							table.insert(displayedCooldownIDs, numericCid)
						end
						addSpell(info.overrideSpellID or info.spellID)
					end
				end
				-- Persist the displayed cooldownID list (keyed per spec) so we can
				-- repopulate the mirror if the category API is ever unavailable
				-- (see the pre-12.0.5 fallback below).
				group.displayedCooldownIDs = group.displayedCooldownIDs or {}
				local specIndex = GetSpecialization()
				group.displayedCooldownIDs[specIndex or 0] = displayedCooldownIDs
			end
		end
	end

	-- Last resort (pre-12.0.5 clients with no category API): replay this spec's
	-- cached displayed set. Keyed by spec INDEX only, so a Guardian Druid (spec 3)
	-- and a Shadow Priest (spec 3) could collide — acceptable only as a fallback
	-- of last resort since the category API above has no such ambiguity.
	if not readFromCategory and group.displayedCooldownIDs and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
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
	-- category set may not be populated yet and the per-spec cache may be empty,
	-- so `spells` comes back empty. Wiping the integer slots here would blank the
	-- interface (it then looks like it "didn't show up"). Instead, leave the
	-- existing slots untouched and schedule a retry via _RetryCooldownViewerSync.
	-- This is the 12.0.7 login-timing regression fix.
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
