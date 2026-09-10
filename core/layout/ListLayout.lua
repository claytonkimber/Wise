-- core/layout/ListLayout.lua
--
-- The "list" display type, extracted from Wise:ApplyLayout in core/GUI.lua.
--
-- This one branch was ~200 of ApplyLayout's ~440 lines -- far more than the
-- other four layout types combined -- because a list is the only layout that
-- has to MEASURE before it can place. Icons, text labels, keybind text and
-- cooldown timers all share a row, so it runs two passes: the first sets each
-- label and records the widest string, the second aligns every row against
-- that maximum. The other types (button/line/box/circle) compute a position
-- per index and are done in a single pass, which is why they stayed inline.
--
-- Everything the branch needs is passed in rather than read back off the
-- frame, so this stays a pure placement routine: `invertOrder` in particular
-- is resolved by ApplyLayout's prologue (it depends on growth direction, not
-- on the list itself) and must not be re-derived here.
--
-- Loaded before core/GUI.lua, which calls it through Wise.Layout.ApplyList.

local addonName, Wise = ...

local math = math

-- Shared table for the layout helpers core/GUI.lua calls directly.
local L = Wise.Layout or {}
Wise.Layout = L

-- Place `count` buttons as a vertical text list.
--   frame       the group frame being laid out
--   buttons     frame.buttons (the live array, not a copy)
--   count       how many entries of `buttons` are in play; the array keeps
--               stale entries past this point, so never use #buttons here
--   groupName   for GetGroupDisplaySettings (font, text size, count position)
--   iconSize    resolved icon size, inherited for nested children
--   invertOrder true when the interface grows upward, so row 1 sits at the
--               bottom; resolved by the caller from growth direction
local function ApplyListLayout(frame, buttons, count, groupName, iconSize, invertOrder)
	-- Vertical text-based list
	local _, textSize, fontPath = Wise:GetGroupDisplaySettings(groupName)
	local listPadding = 8 -- default line padding
	local anchorPoint = "CENTER"
	if groupName and WiseDB.groups[groupName] then
		if WiseDB.groups[groupName].padding then
			listPadding = WiseDB.groups[groupName].padding
		end
		if WiseDB.groups[groupName].anchor and WiseDB.groups[groupName].anchor.point then
			anchorPoint = WiseDB.groups[groupName].anchor.point
		end
	end
	-- Nested list children: override anchor and text align from nesting logic
	if frame.nestedListAnchor then
		anchorPoint = frame.nestedListAnchor
	end
	local listIconSize = iconSize
	local contentHeight = math.max(textSize, listIconSize)
	local lineHeight = contentHeight + listPadding
	local maxTextWidth = 0

	-- Alignment (Pre-calculate for loop)
	local textAlign = (WiseDB.groups[groupName] and WiseDB.groups[groupName].textAlign) or "right"
	-- Nested list children: override text align
	if frame.nestedTextAlign then
		textAlign = frame.nestedTextAlign
	end

	local dy = -lineHeight
	local startY = 0
	local totalH = math.max(count - 1, 0) * lineHeight

	if anchorPoint:find("BOTTOM") then
		dy = lineHeight
		startY = 0
	elseif anchorPoint:find("TOP") then
		dy = -lineHeight
		startY = 0
	else -- CENTER vertically
		dy = -lineHeight
		startY = totalH / 2
	end

	for i = 1, count do
		local idx = i - 1
		if invertOrder then
			idx = count - i
		end
		buttons[i].targetX = 0
		buttons[i].targetY = startY + idx * dy
		buttons[i]:SetPoint("CENTER", buttons[i].targetX, buttons[i].targetY)
		buttons[i]:SetSize(150, lineHeight) -- Wider for text

		-- Create or update text label
		if not buttons[i].textLabel then
			buttons[i].textLabel = buttons[i]:CreateFontString(nil, "OVERLAY")
		end

		-- Apply global font settings
		buttons[i].textLabel:SetFont(fontPath, textSize, "")

		buttons[i].textLabel:ClearAllPoints()
		buttons[i].icon:ClearAllPoints()
		buttons[i].icon:SetSize(listIconSize, listIconSize)

		-- Icon fixed at center (spine) - icons never move regardless of text position
		buttons[i].icon:SetPoint("CENTER", 0, 0)

		-- Re-anchor count text to the icon using Text
		if buttons[i].count and buttons[i].groupName then
			local _, _, _, _, _, _, _, cPos = Wise:GetGroupDisplaySettings(buttons[i].groupName)
			Wise:Text_ApplyPosition(buttons[i].count, cPos or "TOP")
		end

		if textAlign == "right" then
			-- Text Right (Left Aligned)
			buttons[i].textLabel:SetPoint("LEFT", buttons[i].icon, "RIGHT", 5, 0)
			buttons[i].textLabel:SetJustifyH("LEFT")
		else
			-- Text Left (Right Aligned)
			buttons[i].textLabel:SetPoint("RIGHT", buttons[i].icon, "LEFT", -5, 0)
			buttons[i].textLabel:SetJustifyH("RIGHT")
		end

		-- Get action name
		local btn = buttons[i]
		if btn.actionData then
			local name = Wise:GetActionName(btn.actionType, btn.actionValue, btn.actionData)
			btn.textLabel:SetText(name)
		end
		buttons[i].textLabel:Show()

		-- Measure Width (Always measure, maxTextWidth used for sizing)
		local w = buttons[i].textLabel:GetStringWidth()
		if w > maxTextWidth then
			maxTextWidth = w
		end
	end

	-- Second pass: Align Timers and Lines
	local timerOffset = 0
	if textAlign == "right" then
		-- IconHalf + Gap + Text + Gap
		timerOffset = (listIconSize / 2) + 5 + maxTextWidth + 8
	else
		-- IconHalf + Gap
		timerOffset = (listIconSize / 2) + 8
	end

	for i = 1, count do
		-- Timer Label
		if not buttons[i].timerLabel then
			buttons[i].timerLabel = buttons[i]:CreateFontString(nil, "OVERLAY")
			buttons[i].timerLabel:SetJustifyH("LEFT")
		end
		-- Apply global font settings to timer label
		buttons[i].timerLabel:SetFont(fontPath, textSize, "")

		buttons[i].timerLabel:ClearAllPoints()
		-- Anchor relative to icon center (spine), not button center
		buttons[i].timerLabel:SetPoint("LEFT", buttons[i].icon, "CENTER", timerOffset, 0)
		-- Hide initially
		buttons[i].timerLabel:SetText("")

		-- Red Line
		if not buttons[i].redLine then
			buttons[i].redLine = buttons[i]:CreateTexture(nil, "ARTWORK")
			buttons[i].redLine:SetColorTexture(1, 0, 0, 0.8)
			buttons[i].redLine:SetHeight(1) -- Thin line
		end

		buttons[i].redLine:ClearAllPoints()
		buttons[i].redLine:SetPoint("RIGHT", buttons[i].timerLabel, "LEFT", -5, 0)
		buttons[i].redLine:SetWidth(0)
		buttons[i].redLine:Hide()
	end

	-- Resize button frame to fit actual content, not symmetric padding
	-- leftSide/rightSide = distance from icon center to content edge on each side
	local rightSide = timerOffset + 35 -- Timer text width (~30px) + small margin
	local leftSide = listIconSize / 2 -- At minimum, the icon half
	if textAlign == "left" then
		leftSide = (listIconSize / 2) + 5 + maxTextWidth + 5
	end
	local totalWidth = leftSide + rightSide
	-- Shift button center so icon stays at the visual spine (original targetX)
	local centerShift = (rightSide - leftSide) / 2

	for i = 1, count do
		-- Update targetX to include the shift (used by slide animation)
		buttons[i].targetX = buttons[i].targetX + centerShift
		buttons[i]:ClearAllPoints()
		buttons[i]:SetPoint("CENTER", buttons[i].targetX, buttons[i].targetY)
		buttons[i]:SetSize(totalWidth, lineHeight)
		-- Offset icon back so it stays at the visual spine
		buttons[i].icon:ClearAllPoints()
		buttons[i].icon:SetPoint("CENTER", -centerShift, 0)
	end
end

L.ApplyList = ApplyListLayout
