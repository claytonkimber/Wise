-- modules/nesting/Position.lua
--
-- Where a nested child frame actually lands on screen.
-- See modules/nesting/Rules.lua for how this directory is laid out.
--
-- COMBAT: positioning uses the child's INSECURE Anchor frame, never the secure
-- frame itself, which is what lets a nested interface open during combat
-- lockdown. Moving the secure frame would be a protected action; moving its
-- anchor is not.
--
-- GetButton1Offset is the fiddly part. A child frame is positioned by its
-- CENTRE, but what the player expects to line up with the parent button is the
-- child's FIRST BUTTON -- and where button 1 sits relative to that centre
-- depends on the child's layout (circle, line, box, list), its icon size, and
-- how many buttons it has. Computing that offset is what makes the child appear
-- to grow out of the button that opened it.
--
-- Loaded after Layout.lua.

local addonName, Wise = ...
-- Helper: Position a nested child group relative to the parent button that opened it.
-- Uses the child's insecure Anchor frame so it works even during combat.

-- Compute where button 1 will be positioned relative to the child frame center
-- for non-circle layouts. Replicates the index-1 math from ApplyLayout.
local function GetButton1Offset(childFrame, childGroup, childIconSize, buttonCount)
	local layoutType = childFrame.effectiveDisplayType or "circle"

	if layoutType == "line" then
		local linePadding = (childGroup and childGroup.padding) or 5
		local anchorPoint = (childGroup and childGroup.anchor and childGroup.anchor.point) or "CENTER"
		local orientation = (childGroup and childGroup.lineOrientation) or "horizontal"
		-- Nested line children: use overrides from nesting logic
		if childFrame.nestedLineOrientation then
			orientation = childFrame.nestedLineOrientation
		end
		if childFrame.nestedLineAnchor then
			anchorPoint = childFrame.nestedLineAnchor
		end
		local spacing = childIconSize + linePadding
		local invertOrder = childGroup and childGroup.invertOrder

		local dx, dy = 0, 0
		local startX, startY = 0, 0
		local count = buttonCount or 1

		if orientation == "horizontal" then
			if anchorPoint:find("RIGHT") then
				dx = -spacing
			elseif anchorPoint:find("LEFT") then
				dx = spacing
			else
				dx = spacing
				startX = -(math.max(count - 1, 0) * spacing) / 2
			end
		else
			if anchorPoint:find("BOTTOM") then
				dy = spacing
			elseif anchorPoint:find("TOP") then
				dy = -spacing
			else
				dy = -spacing
				startY = (math.max(count - 1, 0) * spacing) / 2
			end
		end

		local idx = invertOrder and (count - 1) or 0
		return startX + idx * dx, startY + idx * dy
	elseif layoutType == "box" then
		local fixedAxis = (childGroup and childGroup.fixedAxis) or "x"
		local boxW = (childGroup and childGroup.boxWidth) or 3
		local boxH = (childGroup and childGroup.boxHeight) or 3
		local boxPaddingX = (childGroup and childGroup.paddingX) or 5
		local boxPaddingY = (childGroup and childGroup.paddingY) or 5
		local anchorPoint = (childGroup and childGroup.anchor and childGroup.anchor.point) or "CENTER"
		local invertOrder = childGroup and childGroup.invertOrder
		local spacingX = childIconSize + boxPaddingX
		local spacingY = childIconSize + boxPaddingY
		local count = buttonCount or 1

		local cols, rows
		if fixedAxis == "x" then
			cols = math.max(1, boxW)
			rows = math.ceil(count / cols)
		else
			rows = math.max(1, boxH)
			cols = math.ceil(count / rows)
		end
		if cols < 1 then
			cols = 1
		end

		local totalH = (rows - 1) * spacingY
		local dirX = 1
		local dirY = -1
		if anchorPoint:find("RIGHT") then
			dirX = -1
		end
		if anchorPoint:find("BOTTOM") then
			dirY = 1
		end

		local startY = 0
		if not anchorPoint:find("TOP") and not anchorPoint:find("BOTTOM") then
			startY = (dirY == -1) and (totalH / 2) or (-totalH / 2)
		end

		local posIndex = invertOrder and (count - 1) or 0
		local r = math.floor(posIndex / cols)
		local c = posIndex % cols

		local itemsInThisRow = cols
		if r == rows - 1 then
			local rem = count % cols
			if rem > 0 then
				itemsInThisRow = rem
			end
		end

		local rowWidth = (itemsInThisRow - 1) * spacingX
		local startX = 0
		if not anchorPoint:find("LEFT") and not anchorPoint:find("RIGHT") then
			startX = (dirX == 1) and (-rowWidth / 2) or (rowWidth / 2)
		end

		return startX + (c * spacingX * dirX), startY + (r * spacingY * dirY)
	elseif layoutType == "list" then
		local listPadding = (childGroup and childGroup.padding) or 8
		local anchorPoint = (childGroup and childGroup.anchor and childGroup.anchor.point) or "CENTER"
		-- Nested list children: use anchor override from nesting logic
		if childFrame.nestedListAnchor then
			anchorPoint = childFrame.nestedListAnchor
		end
		local invertOrder = childGroup and childGroup.invertOrder
		local _, textSize = Wise:GetGroupDisplaySettings(childFrame.groupName or "")
		local contentHeight = math.max(textSize or 12, childIconSize)
		local lineHeight = contentHeight + listPadding
		local count = buttonCount or 1

		local dy = -lineHeight
		local startY = 0
		local totalH = math.max(count - 1, 0) * lineHeight

		if anchorPoint:find("BOTTOM") then
			dy = lineHeight
		elseif anchorPoint:find("TOP") then
			dy = -lineHeight
		else
			dy = -lineHeight
			startY = totalH / 2
		end

		local idx = invertOrder and (count - 1) or 0
		return 0, startY + idx * dy
	end

	return 0, 0
end

function Wise:PositionNestedChild(childFrame, childName, parentName)
	local parentFrame = Wise.frames and Wise.frames[parentName]
	if not parentFrame then
		return
	end

	-- Find which parent button is the interface action pointing to this child
	local parentBtn = nil
	if parentFrame.buttons then
		for _, btn in ipairs(parentFrame.buttons) do
			if btn:IsShown() and btn:GetAttribute("isa_interface_target") == childName then
				parentBtn = btn
				break
			end
		end
	end

	-- Get the parent frame's center (the hub of the parent circle)
	local parentCx, parentCy = parentFrame:GetCenter()
	if not parentCx or not parentCy then
		return
	end

	local parentScale = parentFrame:GetEffectiveScale()
	local uiScale = UIParent:GetEffectiveScale()

	-- Parent center in UIParent coords
	local parentUiX = (parentCx * parentScale) / uiScale
	local parentUiY = (parentCy * parentScale) / uiScale

	-- Calculate offset: position child so button 1 aligns with the parent button
	local offsetX, offsetY = 0, 0
	if parentBtn then
		local btnOffX = parentBtn.targetX or 0
		local btnOffY = parentBtn.targetY or 0

		-- Convert from parent frame coords to UIParent coords
		local dx = btnOffX * parentScale / uiScale
		local dy = btnOffY * parentScale / uiScale

		local childGroupName = childFrame.groupName
		local childGroup = childGroupName and WiseDB.groups[childGroupName]
		local childIconSize = childFrame.inheritedIconSize
			or (childGroup and childGroup.iconSize)
			or (WiseDB.settings and WiseDB.settings.iconSize)
			or 30

		local layoutType = childFrame.effectiveDisplayType or "circle"

		if layoutType == "circle" then
			-- Circle: push center outward so button 1 (rotated inward) aligns
			local dist = math.sqrt(dx * dx + dy * dy)
			if dist > 0.1 then
				local nx = dx / dist
				local ny = dy / dist

				local childCircleRadius = (childGroup and childGroup.circleRadius) or (childIconSize * 2)

				offsetX = dx + nx * childCircleRadius
				offsetY = dy + ny * childCircleRadius

				local offsetAngleDeg = math.deg(math.atan2(ny, nx))
				childFrame.nestedCircleRotation = offsetAngleDeg + 90
			end
		else
			-- Line/Box/List: compute where button 1 lands relative to child center,
			-- then position child center so button 1 sits at the parent button.
			-- childCenter = parentBtnPos - button1Offset
			local buttonCount = (childFrame.buttons and #childFrame.buttons) or 1
			local btn1OffX, btn1OffY = GetButton1Offset(childFrame, childGroup, childIconSize, buttonCount)

			-- btn1Off is in child frame coords; convert to UIParent coords
			local childScale = childFrame:GetEffectiveScale()
			local btn1UiX = btn1OffX * childScale / uiScale
			local btn1UiY = btn1OffY * childScale / uiScale

			offsetX = dx - btn1UiX
			offsetY = dy - btn1UiY

			local parentLayoutType = parentFrame.effectiveDisplayType or "circle"

			-- Line/List or List/List: offset child by 1 icon space in the open direction
			-- so the child's text doesn't overlap the parent's icons/text
			if layoutType == "list" and (parentLayoutType == "line" or parentLayoutType == "list") then
				local anchor = childFrame.nestedListAnchor or "TOP"
				local iconSpace = childIconSize * parentScale / uiScale

				if anchor == "TOP" then
					-- Opening downward: shift child down by 1 icon
					offsetY = offsetY - iconSpace
				elseif anchor == "BOTTOM" then
					-- Opening upward: shift child up by 1 icon
					offsetY = offsetY + iconSpace
				elseif anchor == "LEFT" then
					-- Opening rightward: shift child right by 1 icon
					offsetX = offsetX + iconSpace
				elseif anchor == "RIGHT" then
					-- Opening leftward: shift child left by 1 icon
					offsetX = offsetX - iconSpace
				end

				-- For list/list: also offset past the parent's text to avoid overlap
				if parentLayoutType == "list" then
					local parentGroup = WiseDB.groups[parentName]
					local parentTextAlign = (parentGroup and parentGroup.textAlign) or "right"
					-- Use parent's nestedTextAlign if it has one (for deeply nested lists)
					if parentFrame.nestedTextAlign then
						parentTextAlign = parentFrame.nestedTextAlign
					end
					local parentIconSize = parentFrame.inheritedIconSize
						or (parentGroup and parentGroup.iconSize)
						or (WiseDB.settings and WiseDB.settings.iconSize)
						or 30

					local maxParentTextWidth = 0
					if parentFrame.buttons then
						for _, pBtn in ipairs(parentFrame.buttons) do
							if pBtn.textLabel and pBtn:IsShown() then
								local tw = pBtn.textLabel:GetStringWidth() or 0
								if tw > maxParentTextWidth then
									maxParentTextWidth = tw
								end
							end
						end
					end

					local textOffset = (parentIconSize / 2) + 5 + maxParentTextWidth + 20

					if parentTextAlign == "right" then
						offsetX = offsetX + (textOffset * parentScale / uiScale)
					else
						offsetX = offsetX - (textOffset * parentScale / uiScale)
					end
				end
			end

			-- Clear any circle rotation from a previous layout
			childFrame.nestedCircleRotation = nil
		end
	end

	local uiX = parentUiX + offsetX
	local uiY = parentUiY + offsetY

	-- Move the proxy anchor (only safe out of combat since it anchors a secure frame)
	if childFrame.Anchor and not InCombatLockdown() then
		childFrame.Anchor:ClearAllPoints()
		childFrame.Anchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT", uiX, uiY)
	end

	-- Also move the secure frame directly (only safe out of combat)
	if not InCombatLockdown() then
		childFrame:ClearAllPoints()
		childFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", uiX, uiY)
	end

	-- Re-apply layout with the computed rotation so buttons fan outward (circle only)
	local effectiveType = childFrame.effectiveDisplayType or "circle"
	if effectiveType == "circle" and childFrame.nestedCircleRotation and not InCombatLockdown() then
		local childGroupName = childFrame.groupName
		local btnCount = 0
		if childFrame.buttons then
			for _, btn in ipairs(childFrame.buttons) do
				if btn:IsShown() then
					btnCount = btnCount + 1
				end
			end
		end
		if btnCount > 0 then
			Wise:ApplyLayout(childFrame, effectiveType, btnCount, childGroupName)
		end
	end

	Wise:DebugPrint(
		"PositionNestedChild: child=%s parent=%s parentBtn=%s offset=%.1f,%.1f uiX=%.1f uiY=%.1f rot=%.1f",
		childName,
		parentName,
		parentBtn and parentBtn:GetName() or "NONE",
		offsetX,
		offsetY,
		uiX,
		uiY,
		childFrame.nestedCircleRotation or 0
	)
end
