-- core/effects/HoverIndication.lua
--
-- Hover feedback on ring buttons, extracted from core/GUI.lua: a subtle glow
-- plus a 5% scale bump while the cursor is over a button. Deliberately a
-- lightweight overlay -- no ants, no spark, 50% brightness -- so it reads as
-- "you are pointing at this" and never competes with the proc glow next door
-- in OverlayGlow.lua.
--
-- Empty slots are excluded: IsHiddenEmptySlot checks Wise.buttonMeta rather
-- than the button's own actionType, because a slot's meta is the authoritative
-- record while btn.actionType can lag a rebuild.
--
-- Public API: Wise:AddHoverIndication(btn) wires OnEnter/OnLeave on a button.
-- The three helpers are also published on Wise.Effects for core/GUI.lua, whose
-- CreateGroupFrame drives hover state directly on the ring's own enter/leave
-- handlers instead of per-button scripts.
--
-- Loaded after OverlayGlow.lua and before core/GUI.lua.

local addonName, Wise = ...

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown

-- Shared table for the visual-effect helpers core/GUI.lua still calls directly.
local FX = Wise.Effects or {}
Wise.Effects = FX

local HOVER_SCALE = 1.05
local HOVER_GLOW_ALPHA = 0.5

local function IsHiddenEmptySlot(btn)
	local btnMeta = Wise.buttonMeta and Wise.buttonMeta[btn]
	local btnActionType = (btnMeta and btnMeta.actionType) or btn.actionType
	return btnActionType == "empty"
end

local function CreateHoverGlow(parent)
	local glow = CreateFrame("Frame", nil, parent)
	glow:SetFrameLevel(parent:GetFrameLevel() + 3)
	glow:SetAllPoints(parent)

	glow.inner = glow:CreateTexture(nil, "ARTWORK")
	glow.inner:SetPoint("CENTER")
	glow.inner:SetTexture([[Interface\SpellActivationOverlay\IconAlert]])
	glow.inner:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
	glow.inner:SetBlendMode("ADD")
	glow.inner:SetAlpha(HOVER_GLOW_ALPHA)

	glow.outer = glow:CreateTexture(nil, "ARTWORK")
	glow.outer:SetPoint("CENTER")
	glow.outer:SetTexture([[Interface\SpellActivationOverlay\IconAlert]])
	glow.outer:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
	glow.outer:SetBlendMode("ADD")
	glow.outer:SetAlpha(HOVER_GLOW_ALPHA * 0.6)

	glow:Hide()
	return glow
end

local function ShowHoverGlow(btn)
	if IsHiddenEmptySlot(btn) then
		return
	end

	if not btn._hoverGlow then
		btn._hoverGlow = CreateHoverGlow(btn)
	end
	-- For list layouts, anchor glow to the icon only (not the wide text button)
	local parentFrame = btn:GetParent()
	local isListLayout = parentFrame and parentFrame.effectiveDisplayType == "list"
	if isListLayout and btn.icon then
		local iw, ih = btn.icon:GetSize()
		btn._hoverGlow:ClearAllPoints()
		btn._hoverGlow:SetPoint("CENTER", btn.icon, "CENTER")
		btn._hoverGlow:SetSize(iw, ih)
		btn._hoverGlow.inner:SetSize(iw * 1.2, ih * 1.2)
		btn._hoverGlow.outer:SetSize(iw * 1.5, ih * 1.5)
	else
		local w, h = btn:GetSize()
		btn._hoverGlow:ClearAllPoints()
		btn._hoverGlow:SetAllPoints(btn)
		btn._hoverGlow.inner:SetSize(w * 1.2, h * 1.2)
		btn._hoverGlow.outer:SetSize(w * 1.5, h * 1.5)
	end
	btn._hoverGlow:Show()
end

local function HideHoverGlow(btn)
	if btn._hoverGlow then
		btn._hoverGlow:Hide()
	end
end

local function ApplyHoverScale(btn, scale)
	if IsHiddenEmptySlot(btn) then
		return
	end

	if btn.icon then
		btn.icon:SetScale(scale)
	end
	if btn.hotkey then
		btn.hotkey:SetScale(scale)
	end
	if btn.count then
		btn.count:SetScale(scale)
	end
end

function Wise:AddHoverIndication(btn)
	if not btn then
		return
	end

	btn:HookScript("OnEnter", function(self)
		if IsHiddenEmptySlot(self) then
			return
		end

		local parentFrame = self:GetParent()
		local isListLayout = parentFrame and parentFrame.effectiveDisplayType == "list"
		local isLineLayout = parentFrame and parentFrame.effectiveDisplayType == "line"
		if not isListLayout then
			-- Scale icon texture by 5% (not the button frame, to avoid hit-rect flicker)
			ApplyHoverScale(self, HOVER_SCALE)
		end
		-- Raise FrameLevel on line layout to prevent slot overlap
		if isLineLayout and not InCombatLockdown() then
			self._savedFrameLevel = self:GetFrameLevel()
			self:SetFrameLevel(self:GetFrameLevel() + 5)
		end
		-- Show dim glow (overlay frame, not protected)
		ShowHoverGlow(self)
	end)

	btn:HookScript("OnLeave", function(self)
		-- Reset icon scale
		ApplyHoverScale(self, 1.0)
		-- Restore FrameLevel on line layout
		if self._savedFrameLevel and not InCombatLockdown() then
			self:SetFrameLevel(self._savedFrameLevel)
			self._savedFrameLevel = nil
		end
		-- Hide glow
		HideHoverGlow(self)
	end)
end

-- Published for core/GUI.lua's CreateGroupFrame, which applies hover state from
-- the ring frame's own OnEnter/OnLeave rather than per-button scripts.
FX.ShowHoverGlow = ShowHoverGlow
FX.HideHoverGlow = HideHoverGlow
FX.ApplyHoverScale = ApplyHoverScale
FX.HOVER_SCALE = HOVER_SCALE
