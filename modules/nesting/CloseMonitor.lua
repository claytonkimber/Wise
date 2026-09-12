-- modules/nesting/CloseMonitor.lua
--
-- Keeping a hover-opened child open while the cursor is plausibly heading for
-- it, and closing it once it clearly is not.
-- See modules/nesting/Rules.lua for how this directory is laid out.
--
-- SCHMITT TRIGGER, and the asymmetry is the whole point: a tight inner zone
-- keeps the interface open, while a larger outer zone must be crossed before it
-- closes. A single boundary would flicker -- the cursor sitting exactly on the
-- edge would open and close the child every frame. Two thresholds with a gap
-- between them make that impossible. Do not "simplify" these to one radius.
--
-- Loaded last in modules/nesting/.

local addonName, Wise = ...

-- Close monitoring for hover-opened nested interfaces.
-- Uses a Schmitt trigger approach: a tight inner zone keeps the interface
-- open (hysteresis ON), while a larger outer zone is required before it
-- closes (hysteresis OFF). This prevents flickering at boundaries.
function Wise:StartNestedCloseOnLeave(childFrame, childName, parentInstanceId)
	-- Cancel any existing watcher
	if childFrame.nestedCloseTicker then
		childFrame.nestedCloseTicker:Cancel()
		childFrame.nestedCloseTicker = nil
	end
	if childFrame._outsideClickFrame then
		childFrame._outsideClickFrame:Hide()
	end

	local parentFrame = Wise.frames and Wise.frames[parentInstanceId]
	local ownerButtonName = childFrame.ownerButtonName
	local parentToggleBtn = childFrame.parentToggleBtn

	-- Thresholds (pixels)
	local BUTTON_PAD = 8 -- per-button pad for non-circle layouts
	local LINE_PAD = 15 -- extra boundary for line/box layouts
	local CIRCLE_EXTRA = 15 -- extra radius beyond buttons for circle layouts

	-- Helper: check if mouse is over any button in a frame's button list
	local function isOverButtons(frame, pad)
		if not frame or not frame.buttons then
			return false
		end
		for _, btn in ipairs(frame.buttons) do
			if btn:IsShown() and btn:IsMouseOver(pad, -pad, -pad, pad) then
				return true
			end
		end
		return false
	end

	-- Helper: check if mouse is within a circle centered on a frame
	local function isWithinCircle(frame, radius)
		local cx, cy = frame:GetCenter()
		if not cx then
			return false
		end
		local scale = frame:GetEffectiveScale()
		local mx, my = GetCursorPosition()
		mx, my = mx / scale, my / scale
		local dx, dy = mx - cx, my - cy
		return (dx * dx + dy * dy) <= (radius * radius)
	end

	-- Layout-aware area check for a single frame
	local function isOverFrameArea(frame, extra)
		if not frame or not frame.buttons then
			return false
		end
		local layoutType = frame.effectiveDisplayType or "circle"
		if layoutType == "circle" then
			-- Compute effective radius: distance from center to button edge + padding
			local maxDist = 0
			for _, btn in ipairs(frame.buttons) do
				if btn:IsShown() then
					local bx, by = btn:GetCenter()
					local fx, fy = frame:GetCenter()
					if bx and fx then
						local dx, dy = bx - fx, by - fy
						local dist = (dx * dx + dy * dy) ^ 0.5
						local btnHalf = (btn:GetWidth() or 40) / 2
						if dist + btnHalf > maxDist then
							maxDist = dist + btnHalf
						end
					end
				end
			end
			return isWithinCircle(frame, maxDist + extra)
		else
			-- Line/box/list/button: use per-button hitbox with extra padding
			return isOverButtons(frame, BUTTON_PAD + extra)
		end
	end

	-- Is mouse over the child interface area (or its descendants)?
	local function isOverChildArea(extra)
		if isOverFrameArea(childFrame, extra) then
			return true
		end
		local descendants = Wise:GetAllDescendants(childFrame.groupName or childName)
		for _, descName in ipairs(descendants) do
			local descFrame = Wise.frames and Wise.frames[descName]
			if descFrame and descFrame:IsShown() and isOverFrameArea(descFrame, extra) then
				return true
			end
		end
		return false
	end

	-- Is mouse over the owning interface button on the parent?
	local function isOverOwnerButton()
		if not parentFrame or not parentFrame.buttons then
			return false
		end
		for _, btn in ipairs(parentFrame.buttons) do
			if btn:IsShown() and btn:GetName() == ownerButtonName and btn:IsMouseOver() then
				return true
			end
		end
		return false
	end

	-- Is mouse over a DIFFERENT (non-owner) parent button?
	local function isOverOtherParentButton()
		if not parentFrame or not parentFrame.buttons then
			return false
		end
		for _, btn in ipairs(parentFrame.buttons) do
			if btn:IsShown() and btn:GetName() ~= ownerButtonName and btn:IsMouseOver() then
				return true
			end
		end
		return false
	end

	local function closeChild()
		if not InCombatLockdown() then
			childFrame:SetAttribute("state-manual", "hide")
			local driver = Wise.WiseStateDriver
			if driver then
				driver:SetAttribute("wisesetstate", childName .. ":inactive")
			end
		end
		if childFrame.nestedCloseTicker then
			childFrame.nestedCloseTicker:Cancel()
			childFrame.nestedCloseTicker = nil
		end
	end

	local leaveTicks = 0
	local LEAVE_GRACE = 1 -- 1 tick × 0.05s = 0.05s after leaving outer zone
	local startupTicks = 0
	local STARTUP_DELAY = 4 -- 4 ticks × 0.05s = 0.2s startup immunity

	childFrame.nestedCloseTicker = C_Timer.NewTicker(0.05, function()
		if not childFrame:IsShown() then
			if childFrame.nestedCloseTicker then
				childFrame.nestedCloseTicker:Cancel()
				childFrame.nestedCloseTicker = nil
			end
			return
		end

		startupTicks = startupTicks + 1
		if startupTicks <= STARTUP_DELAY then
			return
		end

		-- Core logic: child stays open only when mouse is over the owner button OR child buttons.
		-- If mouse is on neither, close (with Schmitt trigger on child area only).

		-- For non-circle parents: if mouse is hovering a different parent button, close immediately.
		-- This gives crisp selection behavior for list/line/box parents.
		local parentLayoutType = parentFrame and parentFrame.effectiveDisplayType or "circle"
		if parentLayoutType ~= "circle" and isOverOtherParentButton() then
			closeChild()
			return
		end

		local onOwner = isOverOwnerButton()
		if onOwner then
			-- Over the parent slot that owns this child — keep open, reset
			leaveTicks = 0
			return
		end

		-- Not on owner button — check child area with Schmitt trigger
		-- Circle layouts get generous padding; line/box/list get tight padding
		local childLayoutType = childFrame.effectiveDisplayType or "circle"
		local innerExtra, outerExtra
		if childLayoutType == "circle" then
			innerExtra = CIRCLE_EXTRA
			outerExtra = CIRCLE_EXTRA + LINE_PAD
		else
			-- Tight buffer for non-circle children (just button padding)
			innerExtra = BUTTON_PAD
			outerExtra = BUTTON_PAD + 4
		end

		if isOverChildArea(innerExtra) then
			leaveTicks = 0
		elseif isOverChildArea(outerExtra) then
			-- Hysteresis band: hold steady (don't reset, don't increment)
		else
			-- Outside everything — close quickly
			leaveTicks = leaveTicks + 1
			if leaveTicks >= LEAVE_GRACE then
				closeChild()
			end
		end
	end)
end

-- Helper: Close all child interfaces of a group (cascade close)
function Wise:CloseChildInterfaces(groupName)
	if InCombatLockdown() then
		return
	end
	local children = Wise:GetChildInterfaces(groupName)
	for _, childName in ipairs(children) do
		local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[childName]
		-- Skip Wiser interfaces: they manage their own visibility independently
		-- and should not be cascade-closed when a parent hides
		if childGroup and childGroup.isWiser then
			-- Do not cascade close Wiser interfaces
		else
			local childFrame = Wise.frames and Wise.frames[childName]
			if childFrame and childFrame:IsShown() then
				childFrame:SetAttribute("state-manual", "hide")
				local driver = Wise.WiseStateDriver
				if driver then
					driver:SetAttribute("wisesetstate", childName .. ":inactive")
				end
			end
		end
	end
end
