-- core/blizzui/Hiding.lua
--
-- The mechanics of hiding a Blizzard frame without tainting it -- extracted from
-- Wise.lua. Three techniques, and picking the wrong one for a given frame is the
-- classic bug here:
--
--   1. REPARENT to a parentless secure frame (reparentFrames). Used where a state
--      driver would fight Blizzard's own show/hide and cause a visible pulse.
--      hiddenParent is parentless + SecureFrameTemplate deliberately: that avoids
--      UIParent layout resets re-showing children on reload, and avoids taint
--      propagating from an insecure parent into a secure frame.
--   2. EDIT MODE VisibleSetting (editModeBarFrames). PetActionBar is the reason
--      this category exists -- reparenting or alpha-hacking it still taints the
--      secure frame and blocks PetActionBar:Update -> SetShownBase on something as
--      ordinary as a /target macro. Blizzard's own setting is taint-free.
--   3. STATE DRIVER for everything else.
--
-- The hooks at the bottom are what make hiding stick. Blizzard re-parents and
-- re-registers its own frames on layout events, which would silently undo our
-- hiding; HookSetParent and the RegisterStateDriver/UnregisterStateDriver hooks
-- re-assert it. inRegisterHook guards against recursing into our own call.
--
-- Loaded after Registry.lua, before Apply.lua.

local addonName, Wise = ...

local _G = _G
local ipairs = ipairs
local type = type
local table = table
local CreateFrame = CreateFrame
local UIParent = UIParent
local InCombatLockdown = InCombatLockdown
local RegisterStateDriver = RegisterStateDriver
local UnregisterStateDriver = UnregisterStateDriver
local hooksecurefunc = hooksecurefunc

local IsPuzzleActive = Wise.IsPuzzleActive

-- Shared internals for Apply.lua, which needs the frame categories and the
-- hidden parent to carry out the actual show/hide pass.
local BZ = Wise.BlizzUI or {}
Wise.BlizzUI = BZ


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

-- (Pet bar hide decision is handled inline where it's applied — it now goes
-- through Edit Mode VisibleSetting, not the SetParent hooks, so no shared
-- shouldHidePet helper is needed.)

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

	-- PetActionBar is intentionally NOT hooked here. Reparenting/alpha-hacking the
	-- secure pet bar taints it (blocking PetActionBar:Update -> SetShownBase on a
	-- /target macro). It is hidden via Blizzard's Edit Mode VisibleSetting in
	-- Wise:SetActionBarVisibility (driven from UpdateBlizzardUI / ReapplyAllHiding),
	-- which is combat-aware and taint-free, so no OnShow re-assert hook is needed.

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
-- NOTE: PetActionBar is NOT here — reparenting/alpha-hacking it still taints the secure
-- frame (blocking PetActionBar:Update -> SetShownBase on e.g. a /target macro). It is
-- hidden via Blizzard's Edit Mode VisibleSetting instead (Wise:SetActionBarVisibility).
local reparentFrames = {
	OverrideActionBar = true,
}

-- Frames hidden through Blizzard's Edit Mode VisibleSetting (taint-free) rather
-- than reparenting or a visibility state driver. See Wise:SetActionBarVisibility.
local editModeBarFrames = {
	PetActionBar = true,
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

-- Set of EVERY frame name Wise ever manages via a visibility state driver.
-- The global RegisterStateDriver/UnregisterStateDriver hooks below fire on EVERY
-- such call in the entire game — including Blizzard's own churn on compact party/
-- raid unit frames during GROUP_ROSTER_UPDATE. Executing Wise's Lua closure inside
-- that secure call stack taints the execution path, and that taint then bleeds into
-- CompactUnitFrame_UpdateHealthColor, which reads "secret" health-bar colors and
-- errors comparing them ("compare local 'oldR' (a secret number value, while
-- execution tainted by 'Wise')"). To avoid touching that path at all, the hooks
-- early-out via a single hash lookup BEFORE calling any frame method or secure API
-- for any frame Wise does not manage. This set is the union of:
--   * every frame listed in Wise.BlizzardFrames (excluding reparent frames, which
--     use SetParent rather than state drivers)
--   * ActionButton1..12 (hidden individually for hideActionBar1)
local managedDriverNames = {}
for _, info in ipairs(Wise.BlizzardFrames) do
	for _, fn in ipairs(info.frames) do
		if not reparentFrames[fn] then
			managedDriverNames[fn] = true
		end
	end
end
for i = 1, 12 do
	managedDriverNames["ActionButton" .. i] = true
end

-- Global hooks to intercept Blizzard (or other addons) resetting our visibility state drivers.
-- Edit Mode applies layouts asynchronously during reload, clearing drivers we set.
-- These hooks re-assert "hide" on any managed frame whose driver is being changed.
local inRegisterHook = false

-- Cheap, taint-safe early-out shared by both hooks. Returns the frame's name only
-- when the frame is one Wise manages; otherwise returns nil so the caller bails
-- immediately without touching secure APIs (InCombatLockdown, RegisterStateDriver)
-- or running shouldHideFrame on frames we don't own (e.g. compact unit frames).
local function managedDriverFrameName(frame, header)
	if inRegisterHook then
		return nil
	end
	if header ~= "visibility" then
		return nil
	end
	local frameName = frame and frame.GetName and frame:GetName()
	if not frameName or not managedDriverNames[frameName] then
		return nil
	end
	return frameName
end

hooksecurefunc("RegisterStateDriver", function(frame, header, state)
	local frameName = managedDriverFrameName(frame, header)
	if not frameName then
		return
	end
	if InCombatLockdown() then
		return
	end
	if shouldHideFrame(frameName) and state ~= "hide" then
		inRegisterHook = true
		RegisterStateDriver(frame, "visibility", "hide")
		inRegisterHook = false
	end
end)

hooksecurefunc("UnregisterStateDriver", function(frame, header)
	local frameName = managedDriverFrameName(frame, header)
	if not frameName then
		return
	end
	if InCombatLockdown() then
		return
	end
	if shouldHideFrame(frameName) then
		inRegisterHook = true
		RegisterStateDriver(frame, "visibility", "hide")
		inRegisterHook = false
	end
end)

-- Published for Apply.lua.
BZ.hiddenParent = hiddenParent
BZ.reparentFrames = reparentFrames
BZ.editModeBarFrames = editModeBarFrames
