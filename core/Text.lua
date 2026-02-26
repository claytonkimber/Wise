-- Text.lua: Unified Text Layer Module
-- Provides 9-position text anchoring for keybinds, charges, and custom text on buttons.
local _, Wise = ...

-- Valid anchor positions (3x3 grid)
Wise.TEXT_POSITIONS = {
    "TOPLEFT", "TOP", "TOPRIGHT",
    "LEFT", "CENTER", "RIGHT",
    "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT",
}

-- Offset table: {anchor, offsetX, offsetY, justifyH}
local POSITION_MAP = {
    TOPLEFT     = { "TOPLEFT",     2,  -2, "LEFT"   },
    TOP         = { "TOP",         0,  -2, "CENTER" },
    TOPRIGHT    = { "TOPRIGHT",   -2,  -2, "RIGHT"  },
    LEFT        = { "LEFT",        2,   0, "LEFT"   },
    CENTER      = { "CENTER",      0,   0, "CENTER" },
    RIGHT       = { "RIGHT",      -2,   0, "RIGHT"  },
    BOTTOMLEFT  = { "BOTTOMLEFT",  2,   2, "LEFT"   },
    BOTTOM      = { "BOTTOM",      0,   2, "CENTER" },
    BOTTOMRIGHT = { "BOTTOMRIGHT",-2,   2, "RIGHT"  },
}

--- Position a FontString at one of the 9 anchor points on its parent.
--- Forces an immediate visual refresh so changes are visible without movement.
---@param fs FontString
---@param position string  One of the TEXT_POSITIONS keys
---@param extraX? number   Additional X offset (default 0)
---@param extraY? number   Additional Y offset (default 0)
function Wise:Text_ApplyPosition(fs, position, extraX, extraY)
    local info = POSITION_MAP[position]
    if not info then info = POSITION_MAP["BOTTOMRIGHT"] end -- safe fallback
    local anchor, ox, oy, justify = info[1], info[2], info[3], info[4]
    local wasShown = fs:IsShown()
    fs:Hide()
    fs:ClearAllPoints()
    fs:SetPoint(anchor, fs:GetParent(), anchor, (ox + (extraX or 0)), (oy + (extraY or 0)))
    fs:SetJustifyH(justify)
    if wasShown then fs:Show() end
end

--- Create the three Text FontStrings on a button (count, keybind, customText).
--- Call once during button creation. Safe to call again (skips if already set up).
---@param btn Button
function Wise:Text_CreateFontStrings(btn)
    if btn._textReady then return end

    -- Charges / Item Count
    if not btn.count then
        btn.count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    end

    -- Keybind
    if not btn.keybind then
        btn.keybind = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        btn.keybind:SetShadowOffset(1, -1)
    end

    -- Countdown (new)
    if not btn.countdown then
        btn.countdown = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        -- Default to center, but will be updated by Text_UpdateCountdown
    end

    -- Custom Text (stub – not populated yet, but the FontString is ready)
    if not btn.customText then
        btn.customText = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    end

    btn._textReady = true
end

--- Apply charge/count text position, font, and value on a button.
--- Reads group settings for position and size.
---@param btn Button
---@param groupName string
---@param count number         The numeric count to display
---@param isChargeSpell boolean Whether this spell is a charge-based spell
function Wise:Text_UpdateCharges(btn, groupName, count, isChargeSpell)
    local _, _, fontPath, _, _, _, chargeTextSize, chargeTextPosition, _, _, _, _, _, _, showChargeText = Wise:GetGroupDisplaySettings(groupName)

    if not showChargeText then
        btn.count:Hide()
        return
    end

    local pos = chargeTextPosition or "TOP"
    Wise:Text_ApplyPosition(btn.count, pos)
    btn.count:SetFont(fontPath, chargeTextSize, "OUTLINE")

    if isChargeSpell then
        btn.count:SetText(count)
        btn.count:Show()
    elseif count > 1 then
        btn.count:SetText(count)
        btn.count:Show()
    else
        btn.count:Hide()
    end
end

--- Apply keybind text position, font, and value on a button.
--- Reads group settings for position and size.
---@param btn Button
---@param groupName string
---@param showKeybinds boolean
function Wise:Text_UpdateKeybind(btn, groupName, showKeybinds)
    if not btn.keybind then return end

    if not showKeybinds then
        btn.keybind:Hide()
        return
    end

    local _, _, _, _, kbPos, kbSize = Wise:GetGroupDisplaySettings(groupName)
    local text = Wise.GetKeybind and Wise:GetKeybind(groupName, btn.slot) or nil

    if text then
        btn.keybind:SetText(text)
        local fontPath = WiseDB.settings.font or "Fonts\\FRIZQT__.TTF"
        btn.keybind:SetFont(fontPath, kbSize, "OUTLINE")

        local pos = kbPos or "BOTTOM"
        Wise:Text_ApplyPosition(btn.keybind, pos)
        btn.keybind:Show()
    else
        btn.keybind:Hide()
    end
end

--- Set custom text on a button (stub for future use).
---@param btn Button
---@param text string|nil
---@param position? string  Defaults to "CENTER"
function Wise:Text_UpdateCustomText(btn, text, position)
    if not btn.customText then return end

    if text and text ~= "" then
        local fontPath = WiseDB.settings.font or "Fonts\\FRIZQT__.TTF"
        local textSize = (WiseDB.settings and WiseDB.settings.textSize) or 12
        btn.customText:SetFont(fontPath, textSize, "OUTLINE")
        Wise:Text_ApplyPosition(btn.customText, position or "CENTER")
        btn.customText:SetText(text)
        btn.customText:Show()

    else
        btn.customText:Hide()
    end
end

--- Apply countdown text position, font, and value on a button.
--- Reads group settings for position and size.
---@param btn Button
---@param groupName string
---@param text string
function Wise:Text_UpdateCountdown(btn, groupName, text)
    if not btn.countdown then
        -- Create it if missing (should be created in CreateFontStrings, but safe fallback)
        btn.countdown = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    end
    
    local _, _, fontPath, _, _, _, _, _, countdownTextSize, countdownTextPosition, _, _, _, _, _, showCountdownText = Wise:GetGroupDisplaySettings(groupName)
    
    if not showCountdownText then
        btn.countdown:Hide()
        return
    end

    local pos = countdownTextPosition or "CENTER"
    Wise:Text_ApplyPosition(btn.countdown, pos)
    btn.countdown:SetFont(fontPath, countdownTextSize, "OUTLINE")
    
    if text and text ~= "" then
        btn.countdown:SetText(text)
        btn.countdown:Show()
    else
        btn.countdown:Hide()
    end
end
