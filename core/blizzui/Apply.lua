-- core/blizzui/Apply.lua
--
-- The public entry points that actually carry out Blizzard-UI hiding -- extracted
-- from Wise.lua. Registry.lua says what can be hidden, Hiding.lua says how; this
-- file is what Settings and the event handlers call.
--
--   Wise:SetViewerVisibility  one CooldownViewer, via its Edit Mode "Visible
--                             Setting" -- Blizzard's own always/in-combat/hidden
--                             dropdown, so it persists through login and is
--                             combat-aware without Wise driving it
--   Wise:SetActionBarVisibility  one action bar, same mechanism
--   Wise:ReapplyAllHiding     re-assert everything after a layout change
--   Wise:UpdateBlizzardUI     the full pass: read settings, resolve the puzzle
--                             exception, route each frame to its technique
--
-- COMBAT is the constraint throughout. Edit Mode setting changes are protected,
-- so none of this can run during lockdown -- UpdateBlizzardUI sets
-- Wise.pendingBlizzardUIUpdate and returns, and the PLAYER_REGEN_ENABLED handler
-- in Wise.lua replays it. A caller that ignores that flag will silently no-op in
-- combat rather than erroring.
--
-- Loaded last in core/blizzui/, after Hiding.lua.

local addonName, Wise = ...

local _G = _G
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local type = type
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer
local EnumUtil = EnumUtil
local UIParent = UIParent
local RegisterStateDriver = RegisterStateDriver
local UnregisterStateDriver = UnregisterStateDriver

local IsPuzzleActive = Wise.IsPuzzleActive

local BZ = Wise.BlizzUI or {}
Wise.BlizzUI = BZ
local hiddenParent = BZ.hiddenParent
local reparentFrames = BZ.reparentFrames
local editModeBarFrames = BZ.editModeBarFrames

-- Drive a CooldownViewer frame's Edit Mode "Visible Setting" — the same
-- always/in-combat/hidden dropdown the player sees in Edit Mode. This is
-- Blizzard's own combat-aware visibility system, so it persists through login,
-- combat, and reloads natively (no alpha hacks or per-combat re-apply needed).
--
-- `hidden` true  -> set VisibleSetting = Hidden
-- `hidden` false -> set VisibleSetting = Always
--
-- Returns true on success. Cannot run during combat lockdown (Edit Mode setting
-- changes are protected), so callers must apply out of combat.
function Wise:SetViewerVisibility(viewerName, hidden)
	if InCombatLockdown() then
		return false
	end
	local viewer = _G[viewerName]
	if not viewer then
		return false
	end
	if not (Enum and Enum.EditModeCooldownViewerSetting and Enum.CooldownViewerVisibleSetting) then
		return false
	end

	local settingKey = Enum.EditModeCooldownViewerSetting.VisibleSetting
	local value = hidden and Enum.CooldownViewerVisibleSetting.Hidden or Enum.CooldownViewerVisibleSetting.Always

	-- Already at the target value? Nothing to do (avoids redundant layout dirtying).
	if viewer.GetSettingValue then
		local ok, cur = pcall(viewer.GetSettingValue, viewer, settingKey)
		if ok and cur == value then
			return true
		end
	end

	-- Apply the change the way the in-game Edit Mode dropdown does, so it's
	-- recorded in the active layout and persists. The exact setter has churned
	-- across patches, so try the known paths in order and verify via
	-- GetSettingValue (confirmed present on these frames).
	local applied = false
	if EditModeManagerFrame and EditModeManagerFrame.OnSystemSettingChange then
		pcall(EditModeManagerFrame.OnSystemSettingChange, EditModeManagerFrame, viewer, settingKey, value)
		applied = true
	end
	if not applied and viewer.SetSettingValue then
		pcall(viewer.SetSettingValue, viewer, settingKey, value)
		applied = true
	end

	-- Make sure the visual state reflects the new setting immediately.
	if viewer.UpdateShownState then
		pcall(viewer.UpdateShownState, viewer)
	end

	-- Verify it actually took.
	if viewer.GetSettingValue then
		local ok, cur = pcall(viewer.GetSettingValue, viewer, settingKey)
		return ok and cur == value
	end
	return applied
end

-- Drive an Edit Mode action bar's "Visible Setting" — the action-bar analog of
-- SetViewerVisibility above. Used instead of reparenting/alpha-hacking the secure
-- bar frame, which permanently taints it (an insecure SetParent/SetAlpha on e.g.
-- PetActionBar makes Blizzard's later protected PetActionBar:Update -> Hide ->
-- SetShownBase get blocked, e.g. on a /target macro). Edit Mode visibility is
-- Blizzard's own combat-aware system, so it persists through login/combat/reload
-- and never taints the frame.
--
-- `hidden` true  -> VisibleSetting = Hidden
-- `hidden` false -> VisibleSetting = Always
--
-- Cannot run during combat lockdown (Edit Mode changes are protected), so callers
-- must apply out of combat. Returns true on success.
function Wise:SetActionBarVisibility(barName, hidden)
	if InCombatLockdown() then
		return false
	end
	local bar = _G[barName]
	if not bar then
		return false
	end
	if not (Enum and Enum.EditModeActionBarSetting and Enum.ActionBarVisibleSetting) then
		return false
	end

	local settingKey = Enum.EditModeActionBarSetting.VisibleSetting
	local value = hidden and Enum.ActionBarVisibleSetting.Hidden or Enum.ActionBarVisibleSetting.Always

	-- Already at the target value? Nothing to do (avoids redundant layout dirtying).
	if bar.GetSettingValue then
		local ok, cur = pcall(bar.GetSettingValue, bar, settingKey)
		if ok and cur == value then
			return true
		end
	end

	-- Apply it the way the in-game Edit Mode dropdown does, so it's recorded in
	-- the active layout and persists.
	local applied = false
	if EditModeManagerFrame and EditModeManagerFrame.OnSystemSettingChange then
		pcall(EditModeManagerFrame.OnSystemSettingChange, EditModeManagerFrame, bar, settingKey, value)
		applied = true
	end
	if not applied and bar.SetSettingValue then
		pcall(bar.SetSettingValue, bar, settingKey, value)
		applied = true
	end

	-- Refresh visual state immediately. Action bars don't all expose
	-- UpdateShownState (PetActionBar does not), so call it only if present.
	if bar.UpdateShownState then
		pcall(bar.UpdateShownState, bar)
	end

	-- Verify it actually took.
	if bar.GetSettingValue then
		local ok, cur = pcall(bar.GetSettingValue, bar, settingKey)
		return ok and cur == value
	end
	return applied
end

-- Apply all four "hide" settings via Edit Mode VisibleSetting. Called at login
-- and from the post-login safety-net timers (the layout engine settles
-- asynchronously after PLAYER_LOGIN).
function Wise:ReapplyAllHiding()
	if InCombatLockdown() then
		return
	end
	Wise:SetViewerVisibility("BuffIconCooldownViewer", WiseDB.settings.hideTrackedBuffs)
	Wise:SetViewerVisibility("BuffBarCooldownViewer", WiseDB.settings.hideTrackedBars)
	-- Pet bar: same Edit Mode path (taint-free). Honour hidePetBar + puzzle-hide.
	do
		local blizz = WiseDB.settings.blizzardUI or {}
		local petHidden = blizz["hidePetBar"] or (blizz["hidePuzzleUI"] and IsPuzzleActive and IsPuzzleActive())
		Wise:SetActionBarVisibility("PetActionBar", petHidden)
	end
	if WiseDB.groups["Cooldowns"] then
		Wise:SetViewerVisibility(
			WiseDB.groups["Cooldowns"].viewerName or "EssentialCooldownViewer",
			WiseDB.groups["Cooldowns"].hideNativeInterface
		)
	end
	if WiseDB.groups["Utilities"] then
		Wise:SetViewerVisibility(
			WiseDB.groups["Utilities"].viewerName or "UtilityCooldownViewer",
			WiseDB.groups["Utilities"].hideNativeInterface
		)
	end
end

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
				if editModeBarFrames[frameName] then
					-- Hide via Blizzard's Edit Mode VisibleSetting (taint-free).
					Wise:SetActionBarVisibility(frameName, shouldHide)
				elseif reparentFrames[frameName] then
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
