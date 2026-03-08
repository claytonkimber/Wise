local addonName, Wise = ...

-- Improved Edit Mode Implementation
-- Features: Visual overlay, grid snapping, center lines, group name label.
-- Native Edit Mode integration with selection popup for anchor/offset controls.

local _G = _G
local CreateFrame = CreateFrame
local EditModeManagerFrame = EditModeManagerFrame
local UIParent = UIParent
local pairs = pairs
local ipairs = ipairs
local math = math
local floor = math.floor
local print = print
local tostring = tostring
local tonumber = tonumber
local InCombatLockdown = InCombatLockdown
local ShowUIPanel = ShowUIPanel
local HideUIPanel = HideUIPanel

-- Selection popup state
local selectionPopup = nil
local selectedEditFrame = nil
local selectedEditName = nil

-- ============================================================
-- Selection Popup: X/Y offset controls
-- ============================================================

local function ApplyOffsetFromPopup()
    if not selectionPopup or not selectedEditFrame or not selectedEditName then return end
    if InCombatLockdown() then
        print("|cffff0000Wise:|r Cannot reposition during combat.")
        return
    end

    local f = selectedEditFrame
    local name = selectedEditName
    local group = WiseDB.groups[name]
    if not group then return end

    local point = (group.anchor and group.anchor.point) or "CENTER"
    local x = tonumber(selectionPopup.xBox:GetText()) or 0
    local y = tonumber(selectionPopup.yBox:GetText()) or 0

    -- Save to DB (relativePoint matches point for manual entry)
    group.anchor = { point = point, relativePoint = point, x = x, y = y }

    -- Reposition live via Anchor proxy
    if f.Anchor then
        f.Anchor:ClearAllPoints()
        f.Anchor:SetPoint(point, UIParent, point, x, y)
        f:ClearAllPoints()
        f:SetPoint(point, f.Anchor, point)
    end
end

local function CreateSelectionPopup()
    if selectionPopup then return selectionPopup end

    local popup = CreateFrame("Frame", "WiseEditModePopup", UIParent, "BackdropTemplate")
    popup:SetSize(150, 130)
    popup:SetFrameStrata("TOOLTIP")
    popup:SetFrameLevel(200)
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
    popup:SetClampedToScreen(true)
    popup:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })
    popup:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    popup:Hide()

    -- Title
    popup.title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    popup.title:SetPoint("TOP", 0, -10)
    popup.title:SetText("Position")
    popup.title:SetTextColor(0, 1, 1)

    -- Close Button
    popup.closeBtn = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
    popup.closeBtn:SetPoint("TOPRIGHT", -2, -2)
    popup.closeBtn:SetSize(20, 20)

    -- X/Y Offset Controls
    local controlsX = 15
    local controlsY = -30

    -- X Offset
    local xLabel = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    xLabel:SetPoint("TOPLEFT", controlsX, controlsY)
    xLabel:SetText("X Offset")
    xLabel:SetTextColor(0.8, 0.8, 0.8)

    local xRow = CreateFrame("Frame", nil, popup)
    xRow:SetSize(110, 24)
    xRow:SetPoint("TOPLEFT", controlsX, controlsY - 14)

    local xMinus = CreateFrame("Button", nil, xRow, "UIPanelButtonTemplate")
    xMinus:SetSize(22, 22)
    xMinus:SetPoint("LEFT", 0, 0)
    xMinus:SetText("-")
    xMinus:SetScript("OnClick", function()
        local val = (tonumber(popup.xBox:GetText()) or 0) - 1
        popup.xBox:SetText(tostring(floor(val)))
        ApplyOffsetFromPopup()
    end)

    popup.xBox = CreateFrame("EditBox", nil, xRow, "InputBoxTemplate")
    popup.xBox:SetSize(50, 22)
    popup.xBox:SetPoint("LEFT", xMinus, "RIGHT", 4, 0)
    popup.xBox:SetAutoFocus(false)
    popup.xBox:SetNumeric(false)
    popup.xBox:SetJustifyH("CENTER")
    popup.xBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        ApplyOffsetFromPopup()
    end)
    popup.xBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local xPlus = CreateFrame("Button", nil, xRow, "UIPanelButtonTemplate")
    xPlus:SetSize(22, 22)
    xPlus:SetPoint("LEFT", popup.xBox, "RIGHT", 4, 0)
    xPlus:SetText("+")
    xPlus:SetScript("OnClick", function()
        local val = (tonumber(popup.xBox:GetText()) or 0) + 1
        popup.xBox:SetText(tostring(floor(val)))
        ApplyOffsetFromPopup()
    end)

    -- Y Offset
    local yLabelY = controlsY - 44
    local yLabel = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    yLabel:SetPoint("TOPLEFT", controlsX, yLabelY)
    yLabel:SetText("Y Offset")
    yLabel:SetTextColor(0.8, 0.8, 0.8)

    local yRow = CreateFrame("Frame", nil, popup)
    yRow:SetSize(110, 24)
    yRow:SetPoint("TOPLEFT", controlsX, yLabelY - 14)

    local yMinus = CreateFrame("Button", nil, yRow, "UIPanelButtonTemplate")
    yMinus:SetSize(22, 22)
    yMinus:SetPoint("LEFT", 0, 0)
    yMinus:SetText("-")
    yMinus:SetScript("OnClick", function()
        local val = (tonumber(popup.yBox:GetText()) or 0) - 1
        popup.yBox:SetText(tostring(floor(val)))
        ApplyOffsetFromPopup()
    end)

    popup.yBox = CreateFrame("EditBox", nil, yRow, "InputBoxTemplate")
    popup.yBox:SetSize(50, 22)
    popup.yBox:SetPoint("LEFT", yMinus, "RIGHT", 4, 0)
    popup.yBox:SetAutoFocus(false)
    popup.yBox:SetNumeric(false)
    popup.yBox:SetJustifyH("CENTER")
    popup.yBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        ApplyOffsetFromPopup()
    end)
    popup.yBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local yPlus = CreateFrame("Button", nil, yRow, "UIPanelButtonTemplate")
    yPlus:SetSize(22, 22)
    yPlus:SetPoint("LEFT", popup.yBox, "RIGHT", 4, 0)
    yPlus:SetText("+")
    yPlus:SetScript("OnClick", function()
        local val = (tonumber(popup.yBox:GetText()) or 0) + 1
        popup.yBox:SetText(tostring(floor(val)))
        ApplyOffsetFromPopup()
    end)

    -- Arrow key nudging support
    popup:SetPropagateKeyboardInput(true)
    popup:SetScript("OnKeyDown", function(self, key)
        if not selectedEditFrame then
            self:SetPropagateKeyboardInput(true)
            return
        end
        local dx, dy = 0, 0
        local step = IsShiftKeyDown() and 10 or 1
        if key == "LEFT" then dx = -step
        elseif key == "RIGHT" then dx = step
        elseif key == "UP" then dy = step
        elseif key == "DOWN" then dy = -step
        else
            self:SetPropagateKeyboardInput(true)
            return
        end
        self:SetPropagateKeyboardInput(false)
        local curX = tonumber(popup.xBox:GetText()) or 0
        local curY = tonumber(popup.yBox:GetText()) or 0
        popup.xBox:SetText(tostring(floor(curX + dx)))
        popup.yBox:SetText(tostring(floor(curY + dy)))
        ApplyOffsetFromPopup()
    end)

    selectionPopup = popup
    return popup
end

local function ShowSelectionPopup(f, name)
    local popup = CreateSelectionPopup()
    selectedEditFrame = f
    selectedEditName = name

    -- Populate with current offset data
    local group = WiseDB.groups[name]
    local anchor = group and group.anchor or { point = "CENTER", x = 0, y = 0 }

    popup.xBox:SetText(tostring(floor(anchor.x or 0)))
    popup.yBox:SetText(tostring(floor(anchor.y or 0)))
    popup.title:SetText(name)

    -- Position popup near the selected frame
    popup:ClearAllPoints()
    local cx, cy = f:GetCenter()
    local uiW = UIParent:GetWidth()
    if cx then
        if cx < uiW * 0.6 then
            popup:SetPoint("LEFT", f, "RIGHT", 10, 0)
        else
            popup:SetPoint("RIGHT", f, "LEFT", -10, 0)
        end
    else
        popup:SetPoint("CENTER")
    end

    popup:Show()

    -- Highlight selected overlay border
    if f.EditModeOverlay then
        f.EditModeOverlay:SetBackdropBorderColor(1, 1, 0, 1) -- Yellow for selected
    end
end

local function HideSelectionPopup()
    if selectionPopup then
        selectionPopup:Hide()
    end
    -- Restore previous selection's border color
    if selectedEditFrame and selectedEditFrame.EditModeOverlay then
        selectedEditFrame.EditModeOverlay:SetBackdropBorderColor(0, 1, 1, 0.8)
    end
    selectedEditFrame = nil
    selectedEditName = nil
end

-- Sync popup fields after a drag operation
local function SyncPopupAfterDrag(f, name)
    if not selectionPopup or not selectionPopup:IsShown() then return end
    if selectedEditFrame ~= f then return end
    local group = WiseDB.groups[name]
    if not group or not group.anchor then return end
    selectionPopup.xBox:SetText(tostring(floor(group.anchor.x or 0)))
    selectionPopup.yBox:SetText(tostring(floor(group.anchor.y or 0)))
end

-- ============================================================
-- Edit Mode Overlay
-- ============================================================

-- Helper: Create Edit Mode Overlay
local function CreateEditModeOverlay(f, name)
    if f.EditModeOverlay then return f.EditModeOverlay end

    local overlay = CreateFrame("Frame", nil, f, "BackdropTemplate")
    overlay:SetFrameLevel(f:GetFrameLevel() + 10) -- Ensure it's on top

    -- Semi-transparent background
    overlay:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    overlay:SetBackdropColor(0, 0, 0, 0.6)
    overlay:SetBackdropBorderColor(0, 1, 1, 0.8) -- Cyan border

    -- Anchor Points
    overlay.anchors = {}
    local anchorPositions = {
        "TOPLEFT", "TOP", "TOPRIGHT",
        "LEFT", "CENTER", "RIGHT",
        "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT"
    }

    local group = WiseDB.groups[name]
    local isCircle = group and group.type == "circle"
    local currentAnchor = (group and group.anchor and group.anchor.point) or "CENTER"

    for _, pos in ipairs(anchorPositions) do
        if not isCircle or pos == "CENTER" then
            local btn = CreateFrame("Button", nil, overlay)
            btn:SetSize(12, 12)
            btn:SetPoint("CENTER", overlay, pos)
            btn:SetFrameLevel(overlay:GetFrameLevel() + 5)

            -- Normal texture (ring)
            local nt = btn:CreateTexture(nil, "BACKGROUND")
            nt:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
            nt:SetPoint("CENTER", 0, 0)
            nt:SetSize(36, 36)
            nt:SetVertexColor(1, 0.82, 0) -- Gold
            btn:SetNormalTexture(nt)

            -- Checked/Active texture (filled)
            local ct = btn:CreateTexture(nil, "OVERLAY")
            ct:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
            ct:SetSize(10, 10)
            ct:SetPoint("CENTER", 0, 0)
            ct:SetVertexColor(1, 0.82, 0, 0.8) -- Gold filled
            btn.activeTexture = ct

            if currentAnchor == pos then
                ct:Show()
            else
                ct:Hide()
            end

            -- Highlight texture
            local ht = btn:CreateTexture(nil, "HIGHLIGHT")
            ht:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
            ht:SetBlendMode("ADD")
            ht:SetAllPoints(nt)
            btn:SetHighlightTexture(ht)

            btn.pos = pos
            overlay.anchors[pos] = btn

            btn:SetScript("OnClick", function(self)
                local grp = WiseDB.groups[name]
                if not grp then return end

                -- Update active state visually
                for _, a in pairs(overlay.anchors) do
                    a.activeTexture:Hide()
                end
                self.activeTexture:Show()

                -- We need to keep the frame in the same visual location when changing its anchor.
                -- Calculate the current visual center.
                local cx, cy = f:GetCenter()
                if not cx or not cy then return end
                local ux, uy = UIParent:GetCenter()

                local eff = f:GetEffectiveScale()
                local uEff = UIParent:GetEffectiveScale()

                local xOfs = ((cx * eff) - (ux * uEff)) / uEff
                local yOfs = ((cy * eff) - (uy * uEff)) / uEff

                local point = pos
                local relativePoint = pos

                -- First we place f.Anchor exactly at the new relativePoint coordinate
                -- and adjust x/y offset so its center is still at cx, cy visually
                -- Wait, a better way is to keep f.Anchor at its current center-based position,
                -- and just change how 'f' anchors to 'f.Anchor'.
                -- Let's stick to WoW's standard: f.Anchor represents the relative coordinate on UIParent.
                -- Actually, if point=relativePoint, xOfs and yOfs calculated relative to center aren't right.
                -- Let's just update how f anchors to f.Anchor.
                -- Wait, the standard in this file is:
                -- f.Anchor is attached to UIParent
                -- f is attached to f.Anchor.

                -- Let's look at OnDragStop in editmode.lua:
                -- It sets f:SetPoint(point, relativeTo, relativePoint, xOfs, yOfs)
                -- and then f.Anchor:SetPoint(point, relativeTo, relativePoint, xOfs, yOfs)
                -- and then f:SetPoint("CENTER", f.Anchor, "CENTER") -- This was hardcoded to CENTER!
                -- Wait, the original OnDragStop in editmode.lua hardcodes:
                -- local point, relativeTo, relativePoint = "CENTER", UIParent, "CENTER"
                -- So the anchor is ALWAYS CENTER to CENTER in the original code, it never supported other points.

                -- To support this, we should just let the user change the *internal* anchor of f relative to f.Anchor.
                -- Wait, in OnDragStop:
                -- f.Anchor:SetPoint("CENTER", UIParent, "CENTER", xOfs, yOfs)
                -- f:SetPoint(pos, f.Anchor, "CENTER")

                -- Let's just update the DB with the new anchor point, and we'll apply it.
                -- Actually we just want the frame to grow from 'pos' instead of 'CENTER'.
                -- And we want to maintain its visual position, so we should recalculate the x/y offset based on the new point.

                local left = f:GetLeft()
                local right = f:GetRight()
                local top = f:GetTop()
                local bottom = f:GetBottom()

                local uiW = UIParent:GetWidth()
                local uiH = UIParent:GetHeight()

                local newX, newY = 0, 0
                -- Recalculate x/y offsets relative to the new point so the frame stays in the same visual location.

                local scaledLeft = (left * eff) / uEff
                local scaledRight = (right * eff) / uEff
                local scaledTop = (top * eff) / uEff
                local scaledBottom = (bottom * eff) / uEff
                local scaledCx = (cx * eff) / uEff
                local scaledCy = (cy * eff) / uEff

                if pos:find("LEFT") then newX = scaledLeft
                elseif pos:find("RIGHT") then newX = scaledRight - uiW
                else newX = scaledCx - (uiW / 2) end

                if pos:find("BOTTOM") then newY = scaledBottom
                elseif pos:find("TOP") then newY = scaledTop - uiH
                else newY = scaledCy - (uiH / 2) end

                grp.anchor = { point = pos, relativePoint = pos, x = newX, y = newY }

                if f.Anchor then
                    f.Anchor:ClearAllPoints()
                    f.Anchor:SetPoint(pos, UIParent, pos, newX, newY)
                    f:ClearAllPoints()
                    -- Anchor the frame to the Anchor proxy using the same point
                    f:SetPoint(pos, f.Anchor, pos)
                end

                -- Sync popup if shown
                if selectionPopup and selectedEditFrame == f and selectionPopup:IsShown() then
                    SyncPopupAfterDrag(f, name)
                end
            end)

            -- Prevent clicks from falling through to overlay drag
            btn:SetScript("OnMouseDown", function() end)
            btn:SetScript("OnMouseUp", function() end)
        end
    end

    -- Group Name Label
    overlay.label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    overlay.label:SetText(name)
    overlay.label:SetTextColor(0, 1, 1, 1)

    -- Enable mouse on overlay for click detection and drag forwarding
    overlay:EnableMouse(true)
    overlay:RegisterForDrag("LeftButton")

    overlay:SetScript("OnUpdate", function(self)
        local _, cy = self:GetCenter()
        if not cy then return end
        local screenHeight = (UIParent and UIParent:GetHeight()) or 768
        self.label:ClearAllPoints()
        if cy > screenHeight / 2 then
            self.label:SetPoint("TOP", self, "BOTTOM", 0, -2)
        else
            self.label:SetPoint("BOTTOM", self, "TOP", 0, 2)
        end
    end)

    -- Forward drags from overlay to parent frame (with tracking to distinguish click vs drag)
    overlay:SetScript("OnDragStart", function(self)
        self.isDragging = true
        f:StartMoving()
    end)
    overlay:SetScript("OnDragStop", function(self)
        self.isDragging = false
        -- Trigger the parent's OnDragStop handler
        local handler = f:GetScript("OnDragStop")
        if handler then handler(f) end
    end)

    -- Click to show selection popup (only on clean click, not after drag)
    overlay:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and not self.isDragging then
            ShowSelectionPopup(f, name)
        end
    end)

    f.EditModeOverlay = overlay
    return overlay
end

function Wise:SetFrameEditMode(f, name, enabled)
    if not f then return end

    if enabled then
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")

        -- Raise Strata to ensure visibility over Edit Mode blockers
        if not f.originalStrata then
            f.originalStrata = f:GetFrameStrata()
        end
        f:SetFrameStrata("DIALOG")

        -- Show Overlay
        local overlay = CreateEditModeOverlay(f, name)
        overlay:Show()

        -- Hide existing simple texture if present (legacy support)
        if f.texture then f.texture:Hide() end

        -- Calculate actual bounding box for overlay size and clamp insets
        local cLeft, cRight, cTop, cBottom = 0, 0, 0, 0
        local fLeft = f:GetLeft()
        local fRight = f:GetRight()
        local fTop = f:GetTop()
        local fBottom = f:GetBottom()

        local minLeft, maxRight, maxTop, minBottom
        if fLeft and fRight and fTop and fBottom and f.buttons then
            local groupData = WiseDB.groups[name]
            local isList = groupData and groupData.type == "list"

            for _, btn in ipairs(f.buttons) do
                if btn:IsShown() then
                    local bLeft, bRight, bTop, bBottom

                    if isList then
                        local regions = { btn.icon, btn.textLabel, btn.timerLabel, btn.count, btn.keybind }
                        for _, r in ipairs(regions) do
                            if r and r:IsShown() then
                                local valid = true
                                if type(r.GetText) == "function" then
                                    local txt = r:GetText()
                                    if not txt or txt == "" then valid = false end
                                end
                                if valid then
                                    local rL = r:GetLeft()
                                    local rR = r:GetRight()
                                    local rT = r:GetTop()
                                    local rB = r:GetBottom()
                                    if rL and (not bLeft or rL < bLeft) then bLeft = rL end
                                    if rR and (not bRight or rR > bRight) then bRight = rR end
                                    if rT and (not bTop or rT > bTop) then bTop = rT end
                                    if rB and (not bBottom or rB < bBottom) then bBottom = rB end
                                end
                            end
                        end
                    end

                    if not bLeft then
                        bLeft = btn:GetLeft()
                        bRight = btn:GetRight()
                        bTop = btn:GetTop()
                        bBottom = btn:GetBottom()
                    end

                    if bLeft and (not minLeft or bLeft < minLeft) then minLeft = bLeft end
                    if bRight and (not maxRight or bRight > maxRight) then maxRight = bRight end
                    if bTop and (not maxTop or bTop > maxTop) then maxTop = bTop end
                    if bBottom and (not minBottom or bBottom < minBottom) then minBottom = bBottom end
                end
            end
        end

        if not minLeft and fLeft then
            minLeft = fLeft
            maxRight = fRight
            maxTop = fTop
            minBottom = fBottom
        end

        if fLeft and minLeft and maxRight and maxTop and minBottom then
            -- Insets are relative to the frame's edges
            cLeft = minLeft - fLeft
            cRight = maxRight - fRight
            cTop = maxTop - fTop
            cBottom = minBottom - fBottom

            f:SetClampRectInsets(cLeft, cRight, cTop, cBottom)

            -- Sizing and positioning the overlay exactly to the bounding box
            local width = maxRight - minLeft
            local height = maxTop - minBottom
            if width < 10 then width = 10 end
            if height < 10 then height = 10 end

            overlay:ClearAllPoints()
            overlay:SetSize(width + 4, height + 4) -- small padding

            local cx = (minLeft + maxRight) / 2
            local cy = (minBottom + maxTop) / 2
            local fCenterX = fLeft + (fRight - fLeft) / 2
            local fCenterY = fBottom + (fTop - fBottom) / 2

            overlay:SetPoint("CENTER", f, "CENTER", cx - fCenterX, cy - fCenterY)
        else
            f:SetClampRectInsets(0, 0, 0, 0)
            overlay:ClearAllPoints()
            overlay:SetAllPoints(f)
        end
        f:SetClampedToScreen(true)

        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()

            -- To avoid anchor drifting due to WOW's StopMoving resolving
            -- randomly to TOPLEFT/BOTTOMLEFT etc., we force the anchor
            -- to represent the exact CENTER relative to UIParent's CENTER.
            local cx, cy = self:GetCenter()
            local ux, uy = UIParent:GetCenter()
            
            local eff = self:GetEffectiveScale()
            local uEff = UIParent:GetEffectiveScale()
            
            local xOfs = ((cx * eff) - (ux * uEff)) / uEff
            local yOfs = ((cy * eff) - (uy * uEff)) / uEff
            
            -- Instead of hardcoding CENTER, retrieve the current anchor point from DB
            local group = WiseDB.groups[name]
            local point = (group and group.anchor and group.anchor.point) or "CENTER"
            local relativeTo = UIParent
            local relativePoint = point

            -- Recalculate x/y offset based on the selected point
            local left = self:GetLeft()
            local right = self:GetRight()
            local top = self:GetTop()
            local bottom = self:GetBottom()

            local uiW = UIParent:GetWidth()
            local uiH = UIParent:GetHeight()

            local scaledLeft = (left * eff) / uEff
            local scaledRight = (right * eff) / uEff
            local scaledTop = (top * eff) / uEff
            local scaledBottom = (bottom * eff) / uEff
            local scaledCx = (cx * eff) / uEff
            local scaledCy = (cy * eff) / uEff

            local newX, newY = 0, 0
            if point:find("LEFT") then newX = scaledLeft
            elseif point:find("RIGHT") then newX = scaledRight - uiW
            else newX = scaledCx - (uiW / 2) end

            if point:find("BOTTOM") then newY = scaledBottom
            elseif point:find("TOP") then newY = scaledTop - uiH
            else newY = scaledCy - (uiH / 2) end

            local xOfs = newX
            local yOfs = newY

            -- Grid Snapping Logic (skip in Wise-only edit mode where no grid is shown)
            local snapped = false
            if not Wise.wiseOnlyEditMode and EditModeManagerFrame and EditModeManagerFrame.Grid and EditModeManagerFrame.Grid:IsShown() then
                local spacing = 4 -- Small snap distance for precise placement
                if spacing > 0 then
                    xOfs = floor(xOfs / spacing + 0.5) * spacing
                    yOfs = floor(yOfs / spacing + 0.5) * spacing
                    snapped = true
                end
            end
            
            self:ClearAllPoints()
            self:SetPoint(point, relativeTo, relativePoint, xOfs, yOfs)

            -- Update Saved Variables (include relativePoint for accurate restoration)
            if group and group.anchorMode ~= "mouse" then
                group.anchor = {point=point, relativePoint=relativePoint, x=xOfs, y=yOfs}
            end

            -- Sync Anchor frame to new position (snapped or not)
            if self.Anchor then
                self.Anchor:ClearAllPoints()
                self.Anchor:SetPoint(point, relativeTo, relativePoint, xOfs, yOfs)

                self:ClearAllPoints()
                self:SetPoint(point, self.Anchor, point)
            end

            -- Sync popup values if showing for this frame
            SyncPopupAfterDrag(self, name)
        end)

        -- Disable interaction with internal buttons to prevent accidental clicks while moving
        if f.buttons then
            for _, btn in ipairs(f.buttons) do btn:EnableMouse(false) end
        end
    else
        f:EnableMouse(false)
        f:SetMovable(false)
        f:RegisterForDrag() -- Clear drag registration
        f:SetClampedToScreen(false)
        f:SetClampRectInsets(0, 0, 0, 0)

        -- Restore Strata
        if f.originalStrata then
            f:SetFrameStrata(f.originalStrata)
            f.originalStrata = nil
        end

        -- Hide Overlay
        if f.EditModeOverlay then
            f.EditModeOverlay:Hide()
        end
        if f.texture then f.texture:Hide() end

        f:SetScript("OnDragStart", nil)
        f:SetScript("OnDragStop", nil)

        -- Restore button interaction
        if f.buttons then
            for _, btn in ipairs(f.buttons) do btn:EnableMouse(true) end
        end
    end
end

function Wise:ToggleWiseOnlyEditMode()
    if Wise.editMode then
        Wise.wiseOnlyEditMode = false
        Wise:ExitEditMode()
    else
        Wise.wiseOnlyEditMode = true
        Wise:EnterEditMode()
    end
end

function Wise:EnterEditMode()
    Wise.editMode = true
    if WiseDB and WiseDB.groups then
        for name, group in pairs(WiseDB.groups) do
            local f = Wise.frames[name]
            if f and Wise.SetFrameEditMode then
                -- Skip disabled interfaces and mouse-anchored groups in all edit modes
                if Wise:IsGroupDisabled(group, name) or group.anchorMode == "mouse" then
                    Wise:SetFrameEditMode(f, name, false)
                    if not InCombatLockdown() then f:SetAttribute("state-editmode", "hide") end
                else
                    Wise:SetFrameEditMode(f, name, true)
                    if not InCombatLockdown() then f:SetAttribute("state-editmode", "show") end
                    f:Show()
                    if f.Anchor then f.Anchor:SetScript("OnUpdate", nil) end
                end
            end
        end
    end
end

function Wise:ExitEditMode()
    HideSelectionPopup()
    Wise.editMode = false
    Wise.wiseOnlyEditMode = false
    if WiseDB and WiseDB.groups then
        for name, group in pairs(WiseDB.groups) do
            local f = Wise.frames[name]
            if f and Wise.SetFrameEditMode then
                Wise:SetFrameEditMode(f, name, false)
                if not InCombatLockdown() then f:SetAttribute("state-editmode", "hide") end
            end
            -- Force visibility refresh for ALL frames
            if Wise.UpdateGroupDisplay then
                 Wise:UpdateGroupDisplay(name)
            end
        end
    end
end

function Wise:ToggleEditMode()
    if Wise.editMode then
        -- Already in edit mode - exit by hiding native Edit Mode panel
        if EditModeManagerFrame and EditModeManagerFrame:IsShown() then
            HideUIPanel(EditModeManagerFrame)
        else
            -- Fallback: exit directly if native panel isn't visible
            Wise:ExitEditMode()
        end
    else
        -- Open native Edit Mode (fires "EditMode.Enter" callback → EnterEditMode)
        if EditModeManagerFrame then
            ShowUIPanel(EditModeManagerFrame)
        else
            -- Fallback: enter directly if native frame unavailable
            Wise:EnterEditMode()
        end
    end
end

-- Register Callbacks
if EventRegistry then
    EventRegistry:RegisterCallback("EditMode.Enter", Wise.EnterEditMode, Wise)
    EventRegistry:RegisterCallback("EditMode.Exit", Wise.ExitEditMode, Wise)
end
