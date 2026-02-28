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

    -- Save to DB
    group.anchor = { point = point, x = x, y = y }

    -- Reposition live via Anchor proxy
    if f.Anchor then
        f.Anchor:ClearAllPoints()
        f.Anchor:SetPoint(point, UIParent, point, x, y)
        f:ClearAllPoints()
        f:SetPoint("CENTER", f.Anchor, "CENTER")
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
    overlay:SetAllPoints(f)
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

    -- Center Lines (Crosshair)
    local lineThickness = 1
    local lineLength = 20 -- Length from center

    -- Horizontal Line
    overlay.hLine = overlay:CreateTexture(nil, "OVERLAY")
    overlay.hLine:SetColorTexture(0, 1, 1, 0.5)
    overlay.hLine:SetHeight(lineThickness)
    overlay.hLine:SetPoint("LEFT", overlay, "CENTER", -lineLength, 0)
    overlay.hLine:SetPoint("RIGHT", overlay, "CENTER", lineLength, 0)

    -- Vertical Line
    overlay.vLine = overlay:CreateTexture(nil, "OVERLAY")
    overlay.vLine:SetColorTexture(0, 1, 1, 0.5)
    overlay.vLine:SetWidth(lineThickness)
    overlay.vLine:SetPoint("TOP", overlay, "CENTER", 0, lineLength)
    overlay.vLine:SetPoint("BOTTOM", overlay, "CENTER", 0, -lineLength)

    -- Group Name Label
    overlay.label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    overlay.label:SetPoint("BOTTOM", overlay, "TOP", 0, 2)
    overlay.label:SetText(name)
    overlay.label:SetTextColor(0, 1, 1, 1)

    -- Enable mouse on overlay for click detection and drag forwarding
    overlay:EnableMouse(true)
    overlay:RegisterForDrag("LeftButton")

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

        -- Calculate clamp insets to prevent off-screen placement during drag
        local cLeft, cRight, cTop, cBottom = 0, 0, 0, 0
        local fLeft = f:GetLeft()
        local fRight = f:GetRight()
        local fTop = f:GetTop()
        local fBottom = f:GetBottom()

        if fLeft and fRight and fTop and fBottom and f.buttons then
            local minLeft = fLeft
            local maxRight = fRight
            local maxTop = fTop
            local minBottom = fBottom

            for _, btn in ipairs(f.buttons) do
                if btn:IsShown() then
                    local bLeft = btn:GetLeft()
                    local bRight = btn:GetRight()
                    local bTop = btn:GetTop()
                    local bBottom = btn:GetBottom()
                    if bLeft and bLeft < minLeft then minLeft = bLeft end
                    if bRight and bRight > maxRight then maxRight = bRight end
                    if bTop and bTop > maxTop then maxTop = bTop end
                    if bBottom and bBottom < minBottom then minBottom = bBottom end
                end
            end

            -- Insets are relative to the frame's edges
            cLeft = minLeft - fLeft
            cRight = fRight - maxRight
            cTop = fTop - maxTop
            cBottom = minBottom - fBottom
        end

        f:SetClampRectInsets(cLeft, cRight, cTop, cBottom)
        f:SetClampedToScreen(true)

        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()

            -- Grid Snapping Logic
            local snapped = false
            if EditModeManagerFrame and EditModeManagerFrame.Grid and EditModeManagerFrame.Grid:IsShown() then
                local spacing = 20 -- Default fallback
                if EditModeManagerFrame.GetGridSpacing then
                    spacing = EditModeManagerFrame:GetGridSpacing()
                elseif EditModeManagerFrame.Grid.gridSpacing then
                    spacing = EditModeManagerFrame.Grid.gridSpacing
                end

                if spacing and spacing > 0 then
                    -- Simple round to nearest grid line
                    xOfs = floor(xOfs / spacing + 0.5) * spacing
                    yOfs = floor(yOfs / spacing + 0.5) * spacing

                    self:ClearAllPoints()
                    self:SetPoint(point, relativeTo, relativePoint, xOfs, yOfs)
                    snapped = true
                end
            end

            -- Update Saved Variables
            if WiseDB.groups[name] and WiseDB.groups[name].anchorMode ~= "mouse" then
                WiseDB.groups[name].anchor = {point=point, x=xOfs, y=yOfs}
            end

            -- Sync Anchor frame to new position (snapped or not)
            if self.Anchor then
                self.Anchor:ClearAllPoints()
                self.Anchor:SetPoint(point, relativeTo, relativePoint, xOfs, yOfs)

                self:ClearAllPoints()
                self:SetPoint("CENTER", self.Anchor, "CENTER")
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

function Wise:EnterEditMode()
    Wise.editMode = true
    if WiseDB and WiseDB.groups then
        for name, group in pairs(WiseDB.groups) do
            local f = Wise.frames[name]
            -- Only enable edit mode for non-mouse anchored groups
            if f and Wise.SetFrameEditMode and group.anchorMode ~= "mouse" then
                if not Wise:IsGroupDisabled(group) then
                    Wise:SetFrameEditMode(f, name, true)
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
    if WiseDB and WiseDB.groups then
        for name, group in pairs(WiseDB.groups) do
            local f = Wise.frames[name]
            if f and Wise.SetFrameEditMode then
                Wise:SetFrameEditMode(f, name, false)
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
