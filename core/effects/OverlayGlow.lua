-- core/effects/OverlayGlow.lua
--
-- The modern proc glow, extracted from core/GUI.lua. Mirrors Blizzard's
-- ActionButtonSpellAlertTemplate: a one-shot "start burst" flipbook that hands
-- off to a 1s looping flipbook -- the exact visual the default action bars show
-- for spell-activation procs.
--
-- Overlays are pooled (glowUnusedOverlays); Hide returns one to the pool rather
-- than destroying it, so a button that procs repeatedly does not churn frames.
--
-- OWNERSHIP is the subtle part of this file. TWO independent systems drive
-- glows on the same button -- the proc engine (UpdateButtonUsability /
-- IsSpellOverlayed in core/GUI.lua) and the indicator rules engine
-- (modules/IndicatorRules.lua, per-rule "Glow" flag). Every Show/Hide carries
-- an owner tag, and the overlay is torn down only when NO owner still wants it.
-- Without that, the rules engine's unconditional per-pass HideOverlayGlow
-- destroyed the proc engine's glow on every event burst, and the re-shown
-- overlay replayed its entrance animation -- a constant, oversized ~1 Hz pulse
-- instead of a steady glow. If you touch Show/Hide, preserve the owner set.
--
-- Public API: Wise:ShowOverlayGlow(frame, targetRegion, owner)
--             Wise:HideOverlayGlow(frame, owner)
-- Called from modules/DragAndDrop.lua, modules/IndicatorRules.lua,
-- modules/Demo.lua and the usability pass in core/GUI.lua.
--
-- Loaded before core/GUI.lua, which binds the hover helpers from its sibling.

local addonName, Wise = ...

local CreateFrame = CreateFrame
local UIParent = UIParent
local table = table
local next = next

local glowUnusedOverlays = {}
local glowNumOverlays = 0

local function OverlayGlow_OnShow(self)
	-- Fresh attach plays the entrance burst; a re-show after a transient parent
	-- hide (layout refresh / ring close) resumes the steady loop instead —
	-- _burstPending is consumed by the first play so the burst can't re-pop.
	-- NOTE: frame._wiseGlowOn on the BUTTON still tracks the proc engine's
	-- intent to glow and is managed only by UpdateButtonUsability.
	if self.ProcStartAnim:IsPlaying() or self.ProcLoopAnim:IsPlaying() then
		return
	end
	if self._burstPending then
		self._burstPending = nil
		self.ProcStart:Show()
		self.ProcLoop:Hide()
		self.ProcStartAnim:Play()
	else
		self.ProcStart:Hide()
		self.ProcLoop:Show()
		self.ProcLoopAnim:Play()
	end
end

local function OverlayGlow_OnHide(self)
	-- Transient parent hide (layout/refresh pass), NOT proc end: stop (don't
	-- finish) the animations and keep the overlay attached — OnShow resumes the
	-- loop. No teardown here means no entrance-animation replay when the button
	-- comes back.
	if self.ProcStartAnim:IsPlaying() then
		self.ProcStartAnim:Stop()
	end
	if self.ProcLoopAnim:IsPlaying() then
		self.ProcLoopAnim:Stop()
	end
end

local function CreateOverlayGlow()
	glowNumOverlays = glowNumOverlays + 1
	local overlay = CreateFrame("Frame", "WiseButtonGlowOverlay" .. glowNumOverlays, UIParent)

	-- One-shot entrance burst. Blizzard authors this art 150px against a 42px
	-- button; ShowOverlayGlow sizes it with the same ratio.
	overlay.ProcStart = overlay:CreateTexture(nil, "ARTWORK")
	overlay.ProcStart:SetBlendMode("ADD")
	overlay.ProcStart:SetAtlas("UI-HUD-ActionBar-Proc-Start-Flipbook")
	overlay.ProcStart:SetPoint("CENTER")

	-- Steady looping glow filling the overlay (1.4x the button, the same
	-- footprint as Blizzard's SpellActivationAlert).
	overlay.ProcLoop = overlay:CreateTexture(nil, "ARTWORK")
	overlay.ProcLoop:SetAtlas("UI-HUD-ActionBar-Proc-Loop-Flipbook")
	overlay.ProcLoop:SetAlpha(0)
	overlay.ProcLoop:SetAllPoints()

	overlay.ProcLoopAnim = overlay:CreateAnimationGroup()
	overlay.ProcLoopAnim:SetLooping("REPEAT")
	overlay.ProcLoopAnim:SetToFinalAlpha(true)
	local loopAlpha = overlay.ProcLoopAnim:CreateAnimation("Alpha")
	loopAlpha:SetChildKey("ProcLoop")
	loopAlpha:SetFromAlpha(1)
	loopAlpha:SetToAlpha(1)
	loopAlpha:SetDuration(0.001)
	loopAlpha:SetOrder(0)
	local loopFlipbook = overlay.ProcLoopAnim:CreateAnimation("FlipBook")
	loopFlipbook:SetChildKey("ProcLoop")
	loopFlipbook:SetDuration(1)
	loopFlipbook:SetOrder(0)
	loopFlipbook:SetFlipBookRows(6)
	loopFlipbook:SetFlipBookColumns(5)
	loopFlipbook:SetFlipBookFrames(30)
	loopFlipbook:SetFlipBookFrameWidth(0)
	loopFlipbook:SetFlipBookFrameHeight(0)

	overlay.ProcStartAnim = overlay:CreateAnimationGroup()
	overlay.ProcStartAnim:SetToFinalAlpha(true)
	-- The 1→1 alpha looks pointless but is load-bearing: with SetToFinalAlpha
	-- the burst texture would otherwise stay at its finished alpha (0) on every
	-- replay; the explicit from-alpha reapplies at Play().
	local startAlphaIn = overlay.ProcStartAnim:CreateAnimation("Alpha")
	startAlphaIn:SetChildKey("ProcStart")
	startAlphaIn:SetDuration(0.001)
	startAlphaIn:SetOrder(0)
	startAlphaIn:SetFromAlpha(1)
	startAlphaIn:SetToAlpha(1)
	local startFlipbook = overlay.ProcStartAnim:CreateAnimation("FlipBook")
	startFlipbook:SetChildKey("ProcStart")
	startFlipbook:SetDuration(0.7)
	startFlipbook:SetOrder(1)
	startFlipbook:SetFlipBookRows(6)
	startFlipbook:SetFlipBookColumns(5)
	startFlipbook:SetFlipBookFrames(30)
	startFlipbook:SetFlipBookFrameWidth(0)
	startFlipbook:SetFlipBookFrameHeight(0)
	local startAlphaOut = overlay.ProcStartAnim:CreateAnimation("Alpha")
	startAlphaOut:SetChildKey("ProcStart")
	startAlphaOut:SetDuration(0.001)
	startAlphaOut:SetOrder(2)
	startAlphaOut:SetFromAlpha(1)
	startAlphaOut:SetToAlpha(0)
	overlay.ProcStartAnim:SetScript("OnFinished", function(group)
		local f = group:GetParent()
		f.ProcLoop:Show()
		f.ProcLoopAnim:Play()
	end)

	overlay:SetScript("OnShow", OverlayGlow_OnShow)
	overlay:SetScript("OnHide", OverlayGlow_OnHide)
	overlay:Hide()

	return overlay
end

local function GetOverlayGlow()
	local overlay = table.remove(glowUnusedOverlays)
	if not overlay then
		overlay = CreateOverlayGlow()
	end
	return overlay
end

-- owner names the driver ("proc", "rule"; nil = "generic" for config-time UI
-- like drag-and-drop and the settings demo). Show records the owner; Hide
-- removes it and only tears the overlay down once no owner wants the glow.
function Wise:ShowOverlayGlow(frame, targetRegion, owner)
	local owners = frame.__WiseGlowOwners
	if not owners then
		owners = {}
		frame.__WiseGlowOwners = owners
	end
	owners[owner or "generic"] = true
	if frame.__WiseOverlay then
		return -- already lit; a redundant Show must not replay any animation
	end
	targetRegion = targetRegion or frame
	local overlay = GetOverlayGlow()
	local targetWidth, targetHeight = targetRegion:GetSize()
	overlay:SetParent(frame)
	overlay:SetFrameLevel(frame:GetFrameLevel() + 5)
	overlay:ClearAllPoints()
	-- 1.4x the button, matching Blizzard's spell alert footprint. SetSize makes
	-- the dimensions available before the anchors resolve on the next frame.
	overlay:SetSize(targetWidth * 1.4, targetHeight * 1.4)
	overlay:SetPoint("TOPLEFT", targetRegion, "TOPLEFT", -targetWidth * 0.2, targetHeight * 0.2)
	overlay:SetPoint("BOTTOMRIGHT", targetRegion, "BOTTOMRIGHT", targetWidth * 0.2, -targetHeight * 0.2)
	overlay.ProcStart:SetSize(targetWidth * 150 / 42, targetHeight * 150 / 42)
	overlay._burstPending = true
	frame.__WiseOverlay = overlay
	overlay:Show()
end

function Wise:HideOverlayGlow(frame, owner)
	local owners = frame.__WiseGlowOwners
	if owners then
		owners[owner or "generic"] = nil
		if next(owners) then
			return -- another driver still wants this glow lit
		end
	end
	local overlay = frame.__WiseOverlay
	if overlay then
		-- Blizzard hides the spell alert instantly on proc end; matching that
		-- also leaves no fade-out window for a re-Show to race against.
		overlay:Hide()
		overlay:ClearAllPoints()
		overlay:SetParent(UIParent)
		overlay._burstPending = nil
		frame.__WiseOverlay = nil
		table.insert(glowUnusedOverlays, overlay)
	end
end
