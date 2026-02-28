-- GUI.lua
local addonName, Wise = ...

-- Helper: Resolve per-group display settings with fallback to global
local _G = _G
local GetTime = GetTime
local strformat = string.format
local ceil = math.ceil
local floor = math.floor
local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring
local tonumber = tonumber
local CreateFrame = CreateFrame
local UIParent = UIParent
local GetCursorPosition = GetCursorPosition
local InCombatLockdown = InCombatLockdown
local C_Spell = C_Spell
local C_Item = C_Item
local C_SpellActivationOverlay = C_SpellActivationOverlay
local SecureHandlerWrapScript = SecureHandlerWrapScript
local RegisterStateDriver = RegisterStateDriver

function Wise:GetGroupDisplaySettings(groupName)
    local group = groupName and WiseDB.groups[groupName]
    local settings = WiseDB.settings or {}
    
    local globalIconSize = settings.iconSize or 30
    local globalTextSize = settings.textSize or 12
    local globalFont = settings.font or "Fonts\\FRIZQT__.TTF"
    local globalIconStyle = settings.iconStyle or "rounded"
    
    local iconSize = globalIconSize
    local textSize = globalTextSize
    local fontPath = globalFont
    local iconStyle = globalIconStyle
    
    if group then
        if group.iconSize then iconSize = group.iconSize end
        if group.textSize then textSize = group.textSize end
        if group.font then fontPath = group.font end
        if group.iconStyle then iconStyle = group.iconStyle end
    end
    
    local showKeybinds = (group and group.showKeybinds ~= nil and group.showKeybinds) or (group and group.showKeybinds == nil and settings.showKeybinds) or (not group and settings.showKeybinds)
    local keybindPosition = (group and group.keybindPosition) or settings.keybindPosition
    local keybindTextSize = (group and group.keybindTextSize) or settings.keybindTextSize
    local chargeTextSize = (group and group.chargeTextSize) or settings.chargeTextSize or 12
    local chargeTextPosition = (group and group.chargeTextPosition) or settings.chargeTextPosition or "TOP"
    
    local countdownTextSize = (group and group.countdownTextSize) or settings.countdownTextSize or 12
    local countdownTextPosition = (group and group.countdownTextPosition) or settings.countdownTextPosition or "CENTER"

    -- Tri-state logic for overrides: nil = global, true/false = override
    local showGlows = settings.showGlows
    if group and group.showGlows ~= nil then showGlows = group.showGlows end
    if showGlows == nil then showGlows = true end -- Default true

    local showBuffs = settings.showBuffs
    if group and group.showBuffs ~= nil then showBuffs = group.showBuffs end
    if showBuffs == nil then showBuffs = false end -- Default false
    
    local showGCD = settings.showGCD
    if group and group.showGCD ~= nil then showGCD = group.showGCD end
    if showGCD == nil then showGCD = true end -- Default true

    local showChargeText = settings.showChargeText
    if group and group.showChargeText ~= nil then showChargeText = group.showChargeText end
    if showChargeText == nil then showChargeText = true end

    local showCountdownText = settings.showCountdownText
    if group and group.showCountdownText ~= nil then showCountdownText = group.showCountdownText end
    if showCountdownText == nil then showCountdownText = true end

    return iconSize, textSize, fontPath, showKeybinds, keybindPosition, keybindTextSize, chargeTextSize, chargeTextPosition, countdownTextSize, countdownTextPosition, showGlows, showBuffs, iconStyle, showGCD, showChargeText, showCountdownText
end

function Wise:CreateGroup(name, type)
    if not WiseDB.groups[name] then
        WiseDB.groups[name] = {
            type = type or "circle",
            dynamic = false,
            actions = {},
            anchor = {point = "CENTER", x = 0, y = 0},
            visibilitySettings = {},
            keybindSettings = {},
        }
    end
    
    -- Ensure display is created and updated
    Wise:UpdateGroupDisplay(name)
    local f = Wise.frames[name]
    if f then
        f:Show()
        -- Apply Edit Mode if active (skip for mouse-anchored)
        local group = name and WiseDB.groups[name]
        if Wise.editMode and group and group.anchorMode ~= "mouse" then
            Wise:SetFrameEditMode(f, name, true)
        end
    end

    Wise:UpdateOptionsUI()
end

function Wise:DeleteGroup(name)
    local f = Wise.frames[name]
    if f then
        if InCombatLockdown() then
            print("|cff00ccff[Wise]|r Cannot delete interface in combat (protected).")
            return
        end
        f:Hide()
        if f.toggleBtn then f.toggleBtn:Hide() end
        if f.visualDisplay then f.visualDisplay:Hide() end
        -- Unregister events/scripts to stop updates
        f:SetScript("OnUpdate", nil)
        if f.Anchor then f.Anchor:SetScript("OnUpdate", nil) end
        
        -- Clear from internal frame registry
        Wise.frames[name] = nil
    end
    
    WiseDB.groups[name] = nil
    Wise:UpdateOptionsUI()
end

Wise.frames = {}

-- Central Cooldown Update Frame
Wise.CooldownUpdateFrame = CreateFrame("Frame")
Wise.ActiveCooldownButtons = {}
Wise.CooldownUpdateFrame:Hide()

Wise.CooldownUpdateFrame:SetScript("OnUpdate", function(self, elapsed)
    local now = GetTime()
    local hasActive = false
    
    for btn, info in pairs(Wise.ActiveCooldownButtons) do
        hasActive = true
        local start = info.start
        local duration = info.duration
        local groupName = info.groupName
        local isListMode = info.isListMode
        
        local rem = 0
        local success, val = pcall(function() return (start + duration) - now end)
        if success then rem = val end
        
        if rem <= 0 then
            Wise.ActiveCooldownButtons[btn] = nil
            
            -- Cooldown Finished
            if isListMode then
                if btn.timerLabel then btn.timerLabel:SetText("") end
                if btn.redLine then btn.redLine:SetWidth(0); btn.redLine:Hide() end
                if btn.cooldown then btn.cooldown:SetAlpha(0) end
            else
                Wise:Text_UpdateCountdown(btn, groupName, "")
                -- Sync Visual Clone
                local meta = Wise.buttonMeta and Wise.buttonMeta[btn]
                local vClone = (meta and meta.visualClone) or btn.visualClone
                if vClone then
                     Wise:Text_UpdateCountdown(vClone, groupName, "")
                end
            end
        else
            -- Update Text
            if isListMode then
                local m = floor(rem / 60)
                local s = floor(rem % 60)
                local text = strformat("%d:%02d", m, s)
                if info.lastText ~= text then
                    if btn.timerLabel then btn.timerLabel:SetText(text) end
                    info.lastText = text
                end
                
                local maxWidth = 50 -- Fixed width for now, should be dynamic if possible
                if btn.redLine then 
                     local pct = rem / duration
                     if pct > 1 then pct = 1 end
                     btn.redLine:SetWidth(maxWidth * pct) 
                end
            else
                -- Standard Mode
                local text = ""
                if rem >= 3600 then
                    text = strformat("%dh", ceil(rem / 3600))
                elseif rem >= 60 then
                    text = strformat("%dm", ceil(rem / 60))
                else
                    text = strformat("%d", ceil(rem))
                end
                
                if info.lastText ~= text then
                    Wise:Text_UpdateCountdown(btn, groupName, text)
                    -- Sync Visual Clone
                    local meta = Wise.buttonMeta and Wise.buttonMeta[btn]
                    local vClone = (meta and meta.visualClone) or btn.visualClone
                    if vClone then
                        Wise:Text_UpdateCountdown(vClone, groupName, text)
                    end
                    info.lastText = text
                end
            end
        end
    end
    
    if not hasActive then
        self:Hide()
    end
end)


-- ============================================================================
-- Glow Overlay Implementation (Adapted from LibButtonGlow-1.0)
-- ============================================================================
local glowUnusedOverlays = {}
local glowNumOverlays = 0

local function OverlayGlowAnimOutFinished(animGroup)
    local overlay = animGroup:GetParent()
    local frame = overlay:GetParent()
    overlay:Hide()
    table.insert(glowUnusedOverlays, overlay)
    frame.__WiseOverlay = nil
end

local function OverlayGlow_OnHide(self)
    if self.animOut:IsPlaying() then
        self.animOut:Stop()
        OverlayGlowAnimOutFinished(self.animOut)
    end
end

local function OverlayGlow_OnUpdate(self, elapsed)
    AnimateTexCoords(self.ants, 256, 256, 48, 48, 22, elapsed, 0.01)
    -- we need some threshold to avoid dimming the glow during the gdc
    -- (removed cooldown check to avoid taint error "attempt to compare secret number")
    self:SetAlpha(1.0)
end

local function CreateScaleAnim(group, target, order, duration, x, y, delay)
    local scale = group:CreateAnimation("Scale")
    scale:SetTarget(target)
    scale:SetOrder(order)
    scale:SetDuration(duration)
    scale:SetScale(x, y)
    if delay then scale:SetStartDelay(delay) end
end

local function CreateAlphaAnim(group, target, order, duration, fromAlpha, toAlpha, delay)
    local alpha = group:CreateAnimation("Alpha")
    alpha:SetTarget(target)
    alpha:SetOrder(order)
    alpha:SetDuration(duration)
    alpha:SetFromAlpha(fromAlpha)
    alpha:SetToAlpha(toAlpha)
    if delay then alpha:SetStartDelay(delay) end
end

local function AnimIn_OnPlay(group)
    local frame = group:GetParent()
    local frameWidth, frameHeight = frame:GetSize()
    frame.spark:SetSize(frameWidth, frameHeight)
    frame.spark:SetAlpha(0.3)
    frame.innerGlow:SetSize(frameWidth / 2, frameHeight / 2)
    frame.innerGlow:SetAlpha(1.0)
    frame.innerGlowOver:SetAlpha(1.0)
    frame.outerGlow:SetSize(frameWidth * 2, frameHeight * 2)
    frame.outerGlow:SetAlpha(1.0)
    frame.outerGlowOver:SetAlpha(1.0)
    frame.ants:SetSize(frameWidth * 0.85, frameHeight * 0.85)
    frame.ants:SetAlpha(0)
    frame:Show()
end

local function AnimIn_OnFinished(group)
    local frame = group:GetParent()
    local frameWidth, frameHeight = frame:GetSize()
    frame.spark:SetAlpha(0)
    frame.innerGlow:SetAlpha(0)
    frame.innerGlow:SetSize(frameWidth, frameHeight)
    frame.innerGlowOver:SetAlpha(0.0)
    frame.outerGlow:SetSize(frameWidth, frameHeight)
    frame.outerGlowOver:SetAlpha(0.0)
    frame.outerGlowOver:SetSize(frameWidth, frameHeight)
    frame.ants:SetAlpha(1.0)
end

local function CreateOverlayGlow()
    glowNumOverlays = glowNumOverlays + 1
    local name = "WiseButtonGlowOverlay" .. tostring(glowNumOverlays)
    local overlay = CreateFrame("Frame", name, UIParent)

    -- spark
    overlay.spark = overlay:CreateTexture(name .. "Spark", "BACKGROUND")
    overlay.spark:SetPoint("CENTER")
    overlay.spark:SetAlpha(0)
    overlay.spark:SetTexture([[Interface\SpellActivationOverlay\IconAlert]])
    overlay.spark:SetTexCoord(0.00781250, 0.61718750, 0.00390625, 0.26953125)

    -- inner glow
    overlay.innerGlow = overlay:CreateTexture(name .. "InnerGlow", "ARTWORK")
    overlay.innerGlow:SetPoint("CENTER")
    overlay.innerGlow:SetAlpha(0)
    overlay.innerGlow:SetTexture([[Interface\SpellActivationOverlay\IconAlert]])
    overlay.innerGlow:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)

    -- inner glow over
    overlay.innerGlowOver = overlay:CreateTexture(name .. "InnerGlowOver", "ARTWORK")
    overlay.innerGlowOver:SetPoint("TOPLEFT", overlay.innerGlow, "TOPLEFT")
    overlay.innerGlowOver:SetPoint("BOTTOMRIGHT", overlay.innerGlow, "BOTTOMRIGHT")
    overlay.innerGlowOver:SetAlpha(0)
    overlay.innerGlowOver:SetTexture([[Interface\SpellActivationOverlay\IconAlert]])
    overlay.innerGlowOver:SetTexCoord(0.00781250, 0.50781250, 0.53515625, 0.78515625)

    -- outer glow
    overlay.outerGlow = overlay:CreateTexture(name .. "OuterGlow", "ARTWORK")
    overlay.outerGlow:SetPoint("CENTER")
    overlay.outerGlow:SetAlpha(0)
    overlay.outerGlow:SetTexture([[Interface\SpellActivationOverlay\IconAlert]])
    overlay.outerGlow:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)

    -- outer glow over
    overlay.outerGlowOver = overlay:CreateTexture(name .. "OuterGlowOver", "ARTWORK")
    overlay.outerGlowOver:SetPoint("TOPLEFT", overlay.outerGlow, "TOPLEFT")
    overlay.outerGlowOver:SetPoint("BOTTOMRIGHT", overlay.outerGlow, "BOTTOMRIGHT")
    overlay.outerGlowOver:SetAlpha(0)
    overlay.outerGlowOver:SetTexture([[Interface\SpellActivationOverlay\IconAlert]])
    overlay.outerGlowOver:SetTexCoord(0.00781250, 0.50781250, 0.53515625, 0.78515625)

    -- ants
    overlay.ants = overlay:CreateTexture(name .. "Ants", "OVERLAY")
    overlay.ants:SetPoint("CENTER")
    overlay.ants:SetAlpha(0)
    overlay.ants:SetTexture([[Interface\SpellActivationOverlay\IconAlertAnts]])

    -- setup antimations
    overlay.animIn = overlay:CreateAnimationGroup()
    CreateScaleAnim(overlay.animIn, overlay.spark,          1, 0.2, 1.5, 1.5)
    CreateAlphaAnim(overlay.animIn, overlay.spark,          1, 0.2, 0, 1)
    CreateScaleAnim(overlay.animIn, overlay.innerGlow,      1, 0.3, 2, 2)
    CreateScaleAnim(overlay.animIn, overlay.innerGlowOver,  1, 0.3, 2, 2)
    CreateAlphaAnim(overlay.animIn, overlay.innerGlowOver,  1, 0.3, 1, 0)
    CreateScaleAnim(overlay.animIn, overlay.outerGlow,      1, 0.3, 0.5, 0.5)
    CreateScaleAnim(overlay.animIn, overlay.outerGlowOver,  1, 0.3, 0.5, 0.5)
    CreateAlphaAnim(overlay.animIn, overlay.outerGlowOver,  1, 0.3, 1, 0)
    CreateScaleAnim(overlay.animIn, overlay.spark,          1, 0.2, 2/3, 2/3, 0.2)
    CreateAlphaAnim(overlay.animIn, overlay.spark,          1, 0.2, 1, 0, 0.2)
    CreateAlphaAnim(overlay.animIn, overlay.innerGlow,      1, 0.2, 1, 0, 0.3)
    CreateAlphaAnim(overlay.animIn, overlay.ants,           1, 0.2, 0, 1, 0.3)
    overlay.animIn:SetScript("OnPlay", AnimIn_OnPlay)
    overlay.animIn:SetScript("OnFinished", AnimIn_OnFinished)

    overlay.animOut = overlay:CreateAnimationGroup()
    CreateAlphaAnim(overlay.animOut, overlay.outerGlowOver, 1, 0.2, 0, 1)
    CreateAlphaAnim(overlay.animOut, overlay.ants,          1, 0.2, 1, 0)
    CreateAlphaAnim(overlay.animOut, overlay.outerGlowOver, 2, 0.2, 1, 0)
    CreateAlphaAnim(overlay.animOut, overlay.outerGlow,     2, 0.2, 1, 0)
    overlay.animOut:SetScript("OnFinished", OverlayGlowAnimOutFinished)

    -- scripts
    overlay:SetScript("OnUpdate", OverlayGlow_OnUpdate)
    overlay:SetScript("OnHide", OverlayGlow_OnHide)

    return overlay
end

local function GetOverlayGlow()
    local overlay = table.remove(glowUnusedOverlays)
    if not overlay then
        overlay = CreateOverlayGlow()
    end
    return overlay
end

function Wise:ShowOverlayGlow(frame)
    if frame.__WiseOverlay then
        if frame.__WiseOverlay.animOut:IsPlaying() then
            frame.__WiseOverlay.animOut:Stop()
            frame.__WiseOverlay.animIn:Play()
        end
    else
        local overlay = GetOverlayGlow()
        local frameWidth, frameHeight = frame:GetSize()
        overlay:SetParent(frame)
        overlay:SetFrameLevel(frame:GetFrameLevel() + 5)
        overlay:ClearAllPoints()
        --Make the height/width available before the next frame:
        overlay:SetSize(frameWidth * 1.4, frameHeight * 1.4)
        overlay:SetPoint("TOPLEFT", frame, "TOPLEFT", -frameWidth * 0.2, frameHeight * 0.2)
        overlay:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", frameWidth * 0.2, -frameHeight * 0.2)
        overlay.animIn:Play()
        frame.__WiseOverlay = overlay
    end
end

function Wise:HideOverlayGlow(frame)
    if frame.__WiseOverlay then
        if frame.__WiseOverlay.animIn:IsPlaying() then
            frame.__WiseOverlay.animIn:Stop()
        end
        if frame:IsVisible() then
            frame.__WiseOverlay.animOut:Play()
        else
            OverlayGlowAnimOutFinished(frame.__WiseOverlay.animOut)
        end
    end
end
-- ============================================================================

-- WiseStateDriver: Central secure handler for cross-interface visibility.
-- Holds boolean state ("active"/"inactive") for each interface and propagates
-- changes to all registered group frames so [wise:interfaceName] conditionals work.
local WiseStateDriver = CreateFrame("Frame", "WiseAddonStateDriver", UIParent, "SecureHandlerBaseTemplate")
Wise.WiseStateDriver = WiseStateDriver
WiseStateDriver:SetAttribute("frameCount", 0)

-- Secure snippet: Toggle the state for a given group name, then update all frames.
WiseStateDriver:SetAttribute("ToggleState", [[
    local name = ...
    local current = self:GetAttribute("state_" .. name) or "inactive"
    local newState = (current == "active") and "inactive" or "active"
    self:SetAttribute("state_" .. name, newState)
    self:RunAttribute("UpdateAll")
]])

-- Secure snippet: Iterate all registered frames and trigger their UpdateWiseState.
WiseStateDriver:SetAttribute("UpdateAll", [[
    local count = self:GetAttribute("frameCount") or 0
    for i = 1, count do
        local frame = self:GetFrameRef("Group_" .. i)
        if frame then
            frame:RunAttribute("UpdateWiseState")
        end
    end
]])

-- Secure snippet: Explicitly set state for a group (fixes desync issues)
WiseStateDriver:SetAttribute("SetState", [[
    local name, state = ...
    local current = self:GetAttribute("state_" .. name)
    if current ~= state then
        self:SetAttribute("state_" .. name, state)
        self:RunAttribute("UpdateAll")
    end
]])

-- Secure snippet: Allow insecure code (Lua) to trigger SetState via attribute change
WiseStateDriver:SetAttribute("_onattribute-wisesetstate", [[
    if not value then return end
    local name, state = strsplit(":", value)
    if name and state then
        self:RunAttribute("SetState", name, state)
    end
]])

function Wise:CreateGroupFrame(name)
    if Wise.frames[name] then return Wise.frames[name] end
    
    local f = CreateFrame("Frame", "WiseGroup_"..name, UIParent, "SecureHandlerStateTemplate, SecureHandlerShowHideTemplate")
    f:SetSize(50, 50)
    f:EnableMouse(false) -- Default to click-through (enabled only in Edit Mode)
    
    -- Proxy Anchor Pattern:
    -- Create an insecure anchor frame that we can move freely (even in combat).
    -- The Secure Group is anchored to this proxy.
    -- This allows "spawn at mouse" logic to work in combat (mostly).
    f.Anchor = CreateFrame("Frame", nil, UIParent)
    f.Anchor:SetSize(1, 1)
    f.Anchor:SetPoint("CENTER")
    
    f:ClearAllPoints()
    f:SetPoint("CENTER", f.Anchor, "CENTER") 
    f.buttons = {}
    
    -- Visual anchor for Edit Mode
    f.texture = f:CreateTexture(nil, "BACKGROUND")
    f.texture:SetAllPoints()
    f.texture:SetColorTexture(0, 0, 0, 0.5)
    f.texture:Hide()
    
    -- Secure Toggle Button (Hidden)
    -- Secure Toggle Button (Hidden but active)
    -- Must be parented to UIParent (or similar) so it doesn't get hidden when 'f' is hidden by State Driver
    local toggleBtn = CreateFrame("Button", "WiseGroupToggle_"..name, UIParent, "SecureActionButtonTemplate, SecureHandlerAttributeTemplate")
    toggleBtn:RegisterForClicks("AnyDown", "AnyUp")
    -- SecureHandlerAttributeTemplate provides SetFrameRef via SecureHandler_OnLoad mixin
    
    -- Debug Attribute Changes (insecure script, safe to print)
    toggleBtn:SetScript("OnAttributeChanged", function(self, key, value)
        -- Debug Attribute Changes (Cleaned up)
    end)
    
    -- Keep small size to ensure pressAndHoldAction valid
    toggleBtn:SetSize(2, 2)
    toggleBtn:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)

    local gatekeeper = [[
        local game = self:GetAttribute("state-game") or "hide"
        local manual = self:GetAttribute("state-manual") or "hide"
        local custom = self:GetAttribute("state-custom") or "hide"
        local wiseShow = self:GetAttribute("state-wise-show") or "hide"
        local wiseHide = self:GetAttribute("state-wise-hide") or "hide"

        local willShow = false
        if (game == "show" or manual == "show" or custom == "show" or wiseShow == "show") and (wiseHide ~= "show") then
            willShow = true
            self:Show()
        else
            willShow = false
            self:Hide()
        end
        
        local groupName = self:GetAttribute("wiseGroupName")
        local driver = self:GetFrameRef("WiseStateDriver")
        
        if driver and groupName then
             local driverState = willShow and "active" or "inactive"
             driver:RunAttribute("SetState", groupName, driverState)
        end
    ]]
    f:SetAttribute("wiseGroupName", name)
    f:SetAttribute("_onstate-game", gatekeeper)
    f:SetAttribute("_onstate-manual", gatekeeper)
    f:SetAttribute("_onstate-custom", gatekeeper)
    f:SetAttribute("_onstate-wise-show", gatekeeper)
    f:SetAttribute("_onstate-wise-hide", gatekeeper)
    
    -- Support for Nested Keybinds (Active only when shown)
    f:SetAttribute("_onshow", [[
        local nested = self:GetAttribute("nestedKeybinds")
        if nested then
            local max = self:GetAttribute("nested_max_keys") or 100 
            for i = 1, max do
                local key = self:GetAttribute("nested_key_" .. i)
                local btnName = self:GetAttribute("nested_btn_name_" .. i)
                
                if key and btnName then
                    self:SetBindingClick(true, key, btnName)
                end
            end
        end
    ]])
    
    f:SetAttribute("_onhide", [[
        self:ClearBindings()
    ]])

    -- Inline condition resolver for secure restricted environment (no 'function' keyword allowed).
    -- _rv_ref must be set before this block runs; it sets _rv_t, _rv_s, _rv_i, _rv_m.
    local RESOLVE_BLOCK = [[
        do
            local _rc = _rv_ref:GetAttribute("isa_count") or 0
            _rv_t = _rv_ref:GetAttribute("type")
            _rv_s = _rv_ref:GetAttribute("spell")
            _rv_i = _rv_ref:GetAttribute("item")
            _rv_m = _rv_ref:GetAttribute("macrotext")
            if _rc > 1 then
                local _conflict = _rv_ref:GetAttribute("isa_conflict") or "priority"
                local _matches = newtable()
                for _ci = 1, _rc do
                    local _cond = _rv_ref:GetAttribute("isa_cond_" .. _ci) or ""
                    if _cond == "" then
                        tinsert(_matches, _ci)
                    else
                        local _cr = SecureCmdOptionParse(_cond .. " true; false")
                        if _cr == "true" then
                            tinsert(_matches, _ci)
                        end
                    end
                end
                if #_matches > 0 then
                    local _chosen = nil
                    if _conflict == "priority" or _conflict == "sequence" then
                        local _startIdx = 1
                        if _conflict == "sequence" then
                            local _seq = _rv_ref:GetAttribute("isa_seq") or 1
                            _startIdx = nil
                            for _mi = 1, #_matches do
                                if _matches[_mi] >= _seq then
                                    _startIdx = _mi
                                    break
                                end
                            end
                            if not _startIdx then _startIdx = 1 end
                        end
                        _chosen = _matches[_startIdx]
                        local _newMacro = ""
                        local _nextIdx = _startIdx
                        for _si = _startIdx, #_matches do
                            local _m = _matches[_si]
                            local _mt = _rv_ref:GetAttribute("isa_type_" .. _m)
                            local _ms = _rv_ref:GetAttribute("isa_spell_" .. _m)
                            local _mi = _rv_ref:GetAttribute("isa_item_" .. _m)
                            local _mm = _rv_ref:GetAttribute("isa_macrotext_" .. _m)
                            local _mc = _rv_ref:GetAttribute("isa_cond_" .. _m) or ""
                            local _mo = _rv_ref:GetAttribute("isa_offgcd_" .. _m) or 0
                            local _prefix = (_mc ~= "") and (_mc .. " ") or ""
                            local _line = ""
                            if _mt == "spell" then
                                _line = "/cast " .. _prefix .. _ms
                            elseif _mt == "item" or _mt == "toy" then
                                _line = "/use " .. _prefix .. _mi
                            elseif _mt == "macro" then
                                _line = (_mm and _mm ~= "") and _mm or ""
                            end
                            if _line ~= "" then
                                if _newMacro == "" then
                                    _newMacro = "#showtooltip\n" .. _line
                                else
                                    _newMacro = _newMacro .. "\n" .. _line
                                end
                            end
                            _nextIdx = _si + 1
                            if _mo ~= 1 then
                                break
                            end
                        end
                        _rv_t = "macro"
                        _rv_s = nil
                        _rv_i = nil
                        _rv_m = _newMacro
                        if _conflict == "sequence" then
                            local _lastM = _matches[_nextIdx - 1]
                            _rv_ref:SetAttribute("isa_seq", _lastM + 1)
                        end
                    elseif _conflict == "random" then
                        _chosen = _matches[math.random(#_matches)]
                    end
                    if _chosen and _conflict == "random" then
                        _rv_t = _rv_ref:GetAttribute("isa_type_" .. _chosen)
                        _rv_s = _rv_ref:GetAttribute("isa_spell_" .. _chosen)
                        _rv_i = _rv_ref:GetAttribute("isa_item_" .. _chosen)
                        _rv_m = _rv_ref:GetAttribute("isa_macrotext_" .. _chosen)
                    end
                end
            end
            -- Nesting: Handle interface buttons directly in secure context.
            -- Jump mode: toggle the child group frame directly (bypasses /click).
            -- Rotation modes: resolve a child action instead of /click.
            if _rv_ref:GetAttribute("isa_is_interface") then
                local _nm = _rv_ref:GetAttribute("isa_nest_mode") or "jump"
                if _nm == "jump" then
                    -- Direct toggle: find the child group via frame ref
                    local _childName = _rv_ref:GetAttribute("isa_interface_target")
                    if _childName then
                        local _childGroup = self:GetFrameRef("nested_" .. _childName)
                        if _childGroup then
                            local _cManual = _childGroup:GetAttribute("state-manual") or "hide"
                            local _cTarget = (_cManual == "show") and "hide" or "show"
                            _childGroup:SetAttribute("state-manual", _cTarget)
                            local _driver = self:GetFrameRef("WiseStateDriver")
                            if _driver and _childName then
                                _driver:RunAttribute("SetState", _childName, (_cTarget == "show") and "active" or "inactive")
                            end
                        end
                    end
                    -- Clear the action so /click macro doesn't also fire
                    _rv_t = nil
                    _rv_s = nil
                    _rv_i = nil
                    _rv_m = nil
                elseif _nm ~= "jump" then
                    local _nc = _rv_ref:GetAttribute("isa_nest_count") or 0
                    if _nc > 0 then
                        local _nmatches = newtable()
                        for _ni = 1, _nc do
                            local _ncond = _rv_ref:GetAttribute("isa_nest_cond_" .. _ni) or ""
                            if _ncond == "" then
                                tinsert(_nmatches, _ni)
                            else
                                local _ncr = SecureCmdOptionParse(_ncond .. " true; false")
                                if _ncr == "true" then
                                    tinsert(_nmatches, _ni)
                                end
                            end
                        end
                        if #_nmatches > 0 then
                            local _nchosen = nil
                            if _nm == "priority" then
                                _nchosen = _nmatches[1]
                            elseif _nm == "cycle" or _nm == "shuffle" then
                                local _nseq = _rv_ref:GetAttribute("isa_nest_seq") or 1
                                local _nStartIdx = nil
                                for _ni = 1, #_nmatches do
                                    if _nmatches[_ni] >= _nseq then
                                        _nStartIdx = _ni
                                        break
                                    end
                                end
                                if not _nStartIdx then _nStartIdx = 1 end
                                _nchosen = _nmatches[_nStartIdx]
                                _rv_ref:SetAttribute("isa_nest_seq", _nchosen + 1)
                            elseif _nm == "random" then
                                _nchosen = _nmatches[math.random(#_nmatches)]
                            end
                            if _nchosen then
                                _rv_t = _rv_ref:GetAttribute("isa_nest_type_" .. _nchosen)
                                _rv_s = _rv_ref:GetAttribute("isa_nest_spell_" .. _nchosen)
                                _rv_i = _rv_ref:GetAttribute("isa_nest_item_" .. _nchosen)
                                _rv_m = _rv_ref:GetAttribute("isa_nest_macrotext_" .. _nchosen)
                            end
                        end
                    end
                end
            end
        end
    ]]

    -- Store RESOLVE_BLOCK on Wise table so UpdateGroupDisplay can reuse the same code
    Wise.RESOLVE_BLOCK = RESOLVE_BLOCK

    local snippet = [[
        local f = self:GetFrameRef("group")
        local trigger = self:GetAttribute("trigger") or "release_mouseover"
        local layoutType = self:GetAttribute("layoutType") or "circle"
        local heldMode = self:GetAttribute("visibleWhenHeld")
        local toggleMode = self:GetAttribute("toggleOnPress")
        local hideOnUse = self:GetAttribute("hideOnUse")

        -- Shared resolve variables (set by RESOLVE_BLOCK)
        local _rv_ref, _rv_t, _rv_s, _rv_i, _rv_m

        -- 'down' is provided by the SecureHandlerWrapScript environment
        if down then
            self:SetAttribute("debug_msg", "Key DOWN. Trigger="..tostring(trigger).." Layout="..tostring(layoutType).." Button="..tostring(button))
            -- VISIBILITY LOGIC (Key Down)
            if heldMode then
                 f:SetAttribute("state-manual", "show")
            elseif toggleMode then
                 local f = self:GetFrameRef("group")
                 local currentManual = f:GetAttribute("state-manual") or "hide"
                 local targetState = (currentManual == "show") and "hide" or "show"

                 f:SetAttribute("state-manual", targetState)
            end

            -- EXECUTION LOGIC (Press)
            if trigger == "press" then
                if layoutType == "button" then
                    local targetRef = nil
                    local count = self:GetAttribute("buttonCount") or 0

                    for i = 1, count do
                        local ref = self:GetFrameRef("btn" .. i)
                        if ref then
                            targetRef = ref
                            break
                        end
                    end

                    if targetRef then
                        self:SetAttribute("debug_msg", "Press+Button: Firing target " .. tostring(targetRef))
                        self:SetAttribute("pressAndHoldAction", 1)

                        _rv_ref = targetRef
                        ]] .. RESOLVE_BLOCK .. [[
                        self:SetAttribute("type", _rv_t)
                        self:SetAttribute("spell", _rv_s)
                        self:SetAttribute("item", _rv_i)
                        self:SetAttribute("macrotext", _rv_m)
                        if hideOnUse then f:SetAttribute("state-manual", "hide") end
                    else
                        self:SetAttribute("debug_msg", "Press+Button: No valid target found. Count="..count)
                    end
                else
                    self:SetAttribute("debug_msg", "Press Ignored: Layout is '"..tostring(layoutType).."' (must be 'button')")
                    self:SetAttribute("type", nil)
                    self:SetAttribute("pressAndHoldAction", nil)
                end
            else
                self:SetAttribute("type", nil)
                self:SetAttribute("pressAndHoldAction", nil)
            end
        else
            -- Read hoveredButton BEFORE hiding the frame (hiding clears hover via OnLeave)
            local _pre_hovered = self:GetAttribute("hoveredButton")

            -- VISIBILITY LOGIC (Key Up)
            if heldMode then
                f:SetAttribute("state-manual", "hide")
            end

            -- EXECUTION LOGIC (Release)
            if trigger == "release_mouseover" then
                 local hovered = _pre_hovered
                 if hovered then
                    local ref = self:GetFrameRef(hovered)
                    if ref then
                        _rv_ref = ref
                        ]] .. RESOLVE_BLOCK .. [[

                        self:SetAttribute("type", _rv_t)
                        self:SetAttribute("spell", _rv_s)
                        self:SetAttribute("item", _rv_i)
                        self:SetAttribute("macrotext", _rv_m)

                        self:SetAttribute("ul_type", _rv_t)
                        self:SetAttribute("ul_spell", _rv_s)
                        self:SetAttribute("ul_item", _rv_i)
                        self:SetAttribute("ul_macrotext", _rv_m)

                        if hideOnUse then f:SetAttribute("state-manual", "hide") end
                    end
                 else
                    self:SetAttribute("type", nil)
                    self:SetAttribute("spell", nil)
                    self:SetAttribute("item", nil)
                    self:SetAttribute("macrotext", nil)
                 end
            elseif trigger == "release_repeat" then
                 local hovered = _pre_hovered
                 if hovered then
                    local ref = self:GetFrameRef(hovered)
                    if ref then
                        _rv_ref = ref
                        ]] .. RESOLVE_BLOCK .. [[

                        self:SetAttribute("type", _rv_t)
                        self:SetAttribute("spell", _rv_s)
                        self:SetAttribute("item", _rv_i)
                        self:SetAttribute("macrotext", _rv_m)

                        self:SetAttribute("ul_type", _rv_t)
                        self:SetAttribute("ul_spell", _rv_s)
                        self:SetAttribute("ul_item", _rv_i)
                        self:SetAttribute("ul_macrotext", _rv_m)

                        if hideOnUse then f:SetAttribute("state-manual", "hide") end
                    end
                 else
                    local t = self:GetAttribute("ul_type")
                    if t then
                         self:SetAttribute("type", t)
                         self:SetAttribute("spell", self:GetAttribute("ul_spell"))
                         self:SetAttribute("item", self:GetAttribute("ul_item"))
                         self:SetAttribute("macrotext", self:GetAttribute("ul_macrotext"))
                         if hideOnUse then f:SetAttribute("state-manual", "hide") end
                    else
                         self:SetAttribute("type", nil)
                    end
                 end
            else
                 self:SetAttribute("type", nil)
                 self:SetAttribute("spell", nil)
                 self:SetAttribute("item", nil)
                 self:SetAttribute("macrotext", nil)
            end
        end
    ]]

    -- Use PreClick so attributes are set BEFORE the action executes
    SecureHandlerWrapScript(toggleBtn, "PreClick", toggleBtn, snippet)
    toggleBtn:SetFrameRef("group", f)
    toggleBtn:SetFrameRef("WiseStateDriver", WiseStateDriver)
    toggleBtn:SetAttribute("groupName", name)

    -- Error suppression: check ANY button in this group for isa_suppress before the action fires.
    -- For keybind presses on button layouts, hoveredButton is nil, so we must check all group buttons.
    toggleBtn:HookScript("PreClick", function(self)
        local groupName = self:GetAttribute("groupName")
        if groupName and Wise.frames[groupName] then
            for _, btn in ipairs(Wise.frames[groupName].buttons) do
                if btn:GetAttribute("isa_suppress") == 1 then
                    Wise:BeginErrorSuppression()
                    return
                end
            end
        end
    end)

    f.toggleBtn = toggleBtn
    f.groupName = name  -- Store for animation lookup
    f.isClosing = false -- Flag to track closing animation in progress
    

    
    -- OnUpdate for continuous mouse following (when in mouse anchor mode)
    local function MouseFollowOnUpdate(self)
        if self.mouseAnchorLocked then return end -- Locked in place on keydown (for hold/toggle modes)
        
        local group = WiseDB.groups[self.groupName]
        if not group or group.anchorMode ~= "mouse" then return end
        
        local x, y = GetCursorPosition()
        local offsetX = group.mouseOffsetX or 0
        local offsetY = group.mouseOffsetY or 0
        
        -- Position frame at cursor using BOTTOMLEFT (raw pixel coords)
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x + offsetX, y + offsetY)
    end
    
    -- Module 2: Blocker Strategy
    -- Prevent "Invisible Walls" by enabling mouse only when shown.
    f:SetScript("OnShow", function(self)
        if self.isClosing then return end 
        
        local group = WiseDB.groups[self.groupName]
        
        if group and group.anchorMode == "mouse" then
            -- Position immediately at cursor (works in combat via Proxy Anchor)
            
            -- Get cursor position and correct for UI scale (like UltimateMouseCursor)
            local cursorX, cursorY = GetCursorPosition()
            local uiScale = UIParent:GetScale()
            local frameScale = self:GetScale()
            
            -- Apply scale correction and offsets
            local correctedX = (cursorX / uiScale) / frameScale
            local correctedY = (cursorY / uiScale) / frameScale
            local offsetX = (group.mouseOffsetX or 0) / frameScale
            local offsetY = (group.mouseOffsetY or 0) / frameScale
            
            -- Move the PROXY ANCHOR, not the secure frame
            if self.Anchor then
                self.Anchor:ClearAllPoints()
                self.Anchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT", correctedX + offsetX, correctedY + offsetY)
            end
            
            -- Move the SECURE FRAME (Only safe out of combat)
            if not InCombatLockdown() then
                 self:ClearAllPoints()
                 self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", correctedX + offsetX, correctedY + offsetY)
            end
            
            -- For hold/toggle modes, lock position so user can hover over buttons
            -- For "always visible" button mode, keep following mouse
            local layoutType = group.type or "circle"
            local mode = group.interaction or "toggle"
            if (layoutType == "button" and mode == "press_visible") or (group.visibility == "always" or group.visibility == "combat") then
                -- Always visible: continuously follow mouse
                self.mouseAnchorLocked = false
            else
                -- Hold/toggle popup: lock in place for selection
                self.mouseAnchorLocked = true
            end
        end
        
        -- Nested Interface Positioning (Jump Mode):
        -- Position this child group relative to the parent button that opened it.
        -- Skip nesting behaviors for Wiser interfaces (they are never legitimately nested
        -- and should not be subject to cascade close, close-on-leave, or parent positioning).
        if group and group.anchorMode ~= "mouse" and not group.isWiser then
            local parentName, parentGroup = Wise:GetParentInfo(self.groupName)
            if parentName and parentGroup then
                Wise:PositionNestedChild(self, self.groupName, parentName)

                -- closeParentOnOpen: hide parent when child opens
                if not InCombatLockdown() then
                    Wise:HandleCloseParentOnOpen(self.groupName, parentName)
                end

                -- Auto-close on leave: start monitoring mouse proximity
                Wise:StartNestedCloseOnLeave(self, self.groupName, parentName)
            end
        end

        -- Button manipulation (ClearAllPoints/SetPoint on secure buttons) is protected
        if InCombatLockdown() then return end

        if group and group.animation then
            -- Animate: slide buttons from center to target
            Wise:PlaySlideAnimation(self, true)
        else
            -- No animation: place buttons directly at target positions
            for _, btn in ipairs(self.buttons or {}) do
                if btn:IsShown() then
                    btn:ClearAllPoints()
                    btn:SetPoint("CENTER", btn.targetX or 0, btn.targetY or 0)
                end
            end

        end
        
        -- Fix for button selection on spawn (OnEnter doesn't fire if appearing under mouse)
        -- Skip if animating, as movement will naturally trigger OnEnter
        if not InCombatLockdown() and self.buttons and not (group and group.animation) then
             local found = nil
             for _, btn in ipairs(self.buttons) do
                 if btn:IsShown() and btn:IsMouseOver() then
                     found = btn:GetName()
                     break
                 end
             end
             -- Force update the attribute
             if self.toggleBtn then
                 self.toggleBtn:SetAttribute("hoveredButton", found) 
             end
        end
    end)
    
    f:SetScript("OnHide", function(self)
        -- Cancel nested close-on-leave ticker
        if self.nestedCloseTicker then
            self.nestedCloseTicker:Cancel()
            self.nestedCloseTicker = nil
        end

        -- Cascade close child interfaces ONLY if this is a deliberate close
        -- (not a held-mode release, which may have just opened a child via nesting)
        local group2 = WiseDB.groups[self.groupName]
        local isHeld = group2 and group2.visibilitySettings and group2.visibilitySettings.held
        local customShow2 = group2 and group2.visibilitySettings and group2.visibilitySettings.customShow or ""
        local autoHeld2 = customShow2:find("wise:", 1, true)
        if not isHeld and not autoHeld2 then
            Wise:CloseChildInterfaces(self.groupName)
        end

        local group = WiseDB.groups[self.groupName]

        -- For mouse anchor mode: unlock and keep tracking while hidden
        -- This allows the frame to appear at cursor position on next show
        if group and group.anchorMode == "mouse" then
            self.mouseAnchorLocked = false
            -- Keep OnUpdate running to track mouse position while hidden
        else
            self:SetScript("OnUpdate", nil)
        end

        if self.isClosing then
            -- This is the final hide after animation completed - allow it and reset flag
            self.isClosing = false
            return
        end

        local group = WiseDB.groups[self.groupName]
        if group and group.animation and not InCombatLockdown() then
            -- Intercept hide: show again, animate close, then truly hide
            self.isClosing = true
            self:Show()
            Wise:PlaySlideAnimation(self, false, function()
                -- isClosing stays true so the Hide() call below passes through OnHide
                self:Hide()
            end)
        end
    end)
    
    -- Register with WiseStateDriver for cross-interface visibility
    local driver = WiseStateDriver
    f:SetFrameRef("WiseStateDriver", driver)

    local count = (driver:GetAttribute("frameCount") or 0) + 1
    driver:SetAttribute("frameCount", count)
    driver:SetFrameRef("Group_" .. count, f)
    f:SetAttribute("wiseDriverIndex", count)

    -- Secure snippet on each frame: evaluate [wise:] dependencies and set state-wise-show / state-wise-hide
    f:SetAttribute("UpdateWiseState", [[
        local driver = self:GetFrameRef("WiseStateDriver")
        if not driver then return end

        local deps = self:GetAttribute("wise_dependencies") or ""
        if deps == "" then return end

        local shouldShow = false
        local shouldHide = false
        local myName = self:GetAttribute("wiseGroupName")

        -- Parse comma-separated dependency list
        for dep in deps:gmatch("[^,]+") do
            local depState = driver:GetAttribute("state_" .. dep) or "inactive"
            local isShowDep = self:GetAttribute("wise_dep_show_" .. dep)
            local isHideDep = self:GetAttribute("wise_dep_hide_" .. dep)

            if depState == "active" then
                if isShowDep then shouldShow = true end
                if isHideDep then shouldHide = true end
            end
        end

        self:SetAttribute("state-wise-show", shouldShow and "show" or "hide")
        self:SetAttribute("state-wise-hide", shouldHide and "show" or "hide")
    ]])

    Wise.frames[name] = f
    return f
end


-- Module 1: The Visibility Engine (Helper)
function Wise:BuildVisibilityDriver(f, group)
    local showStr = group.visibilitySettings.customShow or ""
    local hideStr = group.visibilitySettings.customHide or ""
    local name = f:GetAttribute("wiseGroupName") or ""

    -- Parse [wise:name] dependencies from show/hide strings
    -- Store as attributes so the secure UpdateWiseState snippet can evaluate them
    -- Clear old dependency attributes first (handles reconfiguration)
    local oldDeps = f:GetAttribute("wise_dependencies") or ""
    for oldDep in oldDeps:gmatch("[^,]+") do
        f:SetAttribute("wise_dep_show_" .. oldDep, nil)
        f:SetAttribute("wise_dep_hide_" .. oldDep, nil)
    end

    local deps = {}
    local depSet = {}

    for dep in showStr:gmatch("%[%s*wise:([^%],]+)") do
        dep = dep:match("^%s*(.-)%s*$") -- trim
        if string.lower(dep) ~= string.lower(name) then
            if not depSet[dep] then
                depSet[dep] = true
                table.insert(deps, dep)
            end
            f:SetAttribute("wise_dep_show_" .. dep, true)
        end
    end

    for dep in hideStr:gmatch("%[%s*wise:([^%],]+)") do
        dep = dep:match("^%s*(.-)%s*$") -- trim
        if string.lower(dep) ~= string.lower(name) then
            if not depSet[dep] then
                depSet[dep] = true
                table.insert(deps, dep)
            end
            f:SetAttribute("wise_dep_hide_" .. dep, true)
        end
    end

    f:SetAttribute("wise_dependencies", table.concat(deps, ","))

    -- Helper: replacements (convert [always] to [])
    -- [always] is user-friendly for "true". In macro syntax, [] is true.
    -- [wise:name] is a placeholder for Manual State. We strip it from Driver (so Driver=Hide), letting Manual State control visibility.
    local function Sanitize(str)
        if not str then return "" end
        
        -- 1. Remove solitary [wise:...] blocks entirely FIRST
        -- Handle separators to avoid parsing errors
        -- Replace [wise:...] with nothing, then clean up semicolons
        str = str:gsub("%s*%[%s*wise:[^%]]+%]%s*", "") 
        
        -- Clean up semicolons (e.g. "; ;" -> ";")
        str = str:gsub(";", " ; ") -- padding
        str = str:gsub("%s+", " ") -- normalize spaces
        str = str:gsub("%s*;%s*", "; ") -- normalize semicolons
        str = str:gsub("^;%s*", "") -- remove leading
        str = str:gsub(";%s*$", "") -- remove trailing
        str = str:gsub("; ;", ";") -- remove doubles
        
        -- 2. Strip wise:name content inside mixed brackets (e.g. [mod:shift, wise:dev])
        -- (This handles "AND" logic inside single brackets)
        str = str:gsub("wise:[^,^%]]+,?", "") -- Remove "wise:name," or "wise:name"
        str = str:gsub(",?%s*wise:[^,^%]]+", "") -- Remove ", wise:name"
        
        -- 3. Convert [always] to []
        str = str:gsub("%[always%]", "[]") 
        str = str:gsub("%[always, ", "[") 
        
        -- Final Clean
        str = str:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        
        return str
    end
    
    local function SanitizeCustom(str)
         if not str then return "" end
         -- Replace known custom conditionals that cause secure driver errors check
         -- We replace them with a condition that is impossible to meet securely if it's the only one, 
         -- effectively removing it from the secure driver's consideration (letting Lua handle it via state-custom).
         -- Actually, if we remove it, the secure driver might default to show/hide incorrectly.
         
         -- Strategy: Convert [warbandbank] to [actionbar:99] (False).
         -- If [warbandbank] is true, Lua sets state-custom=show. Gateway shows.
         -- If [warbandbank] is false, Lua sets state-custom=hide. Gateway hides (assuming state-game is hide).
         -- state-game sees [actionbar:99]. False. Hides.
         
         str = str:gsub("guildbank", "actionbar:99")
         -- "bank" is a substring of others, so replace it last or be careful about boundaries.
         -- Use patterns to match whole word?
         str = str:gsub("%[bank%]", "[actionbar:99]")
         str = str:gsub("bank", "actionbar:99") -- A bit aggressive but likely safe for standard secure options (banking isn't one)
         str = str:gsub("mailbox", "actionbar:99")
         
         return str
    end
    
    showStr = Sanitize(showStr)
    hideStr = Sanitize(hideStr)
    
    showStr = SanitizeCustom(showStr)
    hideStr = SanitizeCustom(hideStr)

    -- Apply defaults AFTER sanitization (wise: tags and custom conditionals are now stripped).
    -- If both strings are effectively empty, set showStr based on interaction mode / base visibility.
    -- Hold/Toggle modes always default to hidden (state-manual controls visibility via hotkey).
    -- Only press_visible mode respects base visibility for the state-game driver.
    if showStr == "" and hideStr == "" then
        local mode = group.interaction or "toggle"
        local base = group.visibilitySettings.baseVisibility
        local isHeldOrToggle = (group.visibilitySettings.held or group.visibilitySettings.toggleOnPress)

        if isHeldOrToggle then
            -- Hold/Toggle: driver stays empty → defaults to "hide"
            -- Visibility is controlled by state-manual via hotkey
        elseif mode == "press_visible" then
            if base == "COMBAT_ONLY" then
                showStr = "[combat]"
            elseif base == "NO_COMBAT_ONLY" then
                showStr = "[nocombat]"
            else
                showStr = "[]"
            end
        end
    end

    -- Construct Driver
    -- Logic: Hide conditions take precedence? Standard convention is typically Deny > Allow?
    -- If user has "Hide in Combat" and "Show on Shift". If I am in Combat+Shift:
    -- If Hide First: [combat] hide; [mod:shift] show; ... -> Hides.
    -- If Show First: [mod:shift] show; [combat] hide; ... -> Shows.
    -- Given the UI separates them, we need a deterministic order. 
    -- Let's do HIDE then SHOW.
    
    local parts = {}
    
    if hideStr ~= "" then
        table.insert(parts, hideStr .. " hide")
    end
    
    -- Only add 'show' if we have a valid condition string (e.g. [mod:shift]) or explicit [always] ([])
    -- If Sanitize returned "", it means we stripped [wise:name] and had nothing left.
    -- In that case, we want the driver to default to HIDE (waiting for manual).
    if showStr ~= "" then
        table.insert(parts, showStr .. " show")
    end
    
    -- Default fallback if nothing matches
    table.insert(parts, "hide")
    
    local driverString = table.concat(parts, "; ")
    -- Note: We don't need to force "; hide" at the end because we explicitly added "hide" to parts list
    -- But just to be safe if table.concat does something weird with empty parts (it doesn't)
    
    RegisterStateDriver(f, "game", driverString)
    return driverString
end

-- Helper: Compute secure attributes for a given action data table
-- Returns secureType, secureAttr, secureValue
function Wise:GetSecureAttributes(actionData, conditions)
    local aType = actionData.type
    local aValue = actionData.value
    local hasCond = conditions and conditions ~= ""

    local secureType = "macro"
    local secureAttr = "macrotext"
    local secureValue = ""

    if aType == "spell" then
        -- Resolve spell name for use in commands
        local spellName
        local n = tonumber(aValue)
        if n then
            local info = C_Spell.GetSpellInfo(n)
            spellName = (info and info.name) or n
        else
            spellName = aValue
        end
        if hasCond then
            secureType = "macro"
            secureAttr = "macrotext"
            secureValue = "/cast " .. conditions .. " " .. spellName
        else
            secureType = "spell"
            secureAttr = "spell"
            secureValue = spellName
        end
    elseif aType == "item" or aType == "toy" then
        if hasCond then
            secureType = "macro"
            secureAttr = "macrotext"
            local n = tonumber(aValue)
            local itemRef = n and ("item:" .. n) or aValue
            secureValue = "/use " .. conditions .. " " .. itemRef
        else
            secureType = "item"
            secureAttr = "item"
            local n = tonumber(aValue)
            if n then
                secureValue = "item:" .. n
            else
                secureValue = aValue
            end
        end
    elseif aType == "macro" then
        secureType = "macro"
        if string.sub(aValue, 1, 1) == "/" then
            secureAttr = "macrotext"
        else
            secureAttr = "macro"
        end
        secureValue = aValue
    elseif aType == "mount" then
        if C_MountJournal then
            local mountName, spellID = C_MountJournal.GetMountInfoByID(aValue)
            if hasCond then
                secureType = "macro"
                secureAttr = "macrotext"
                if spellID then
                    local info = C_Spell.GetSpellInfo(spellID)
                    local castName = (info and info.name) or spellID
                    secureValue = "/cast " .. conditions .. " " .. castName
                else
                    secureValue = "/use " .. conditions .. " " .. (mountName or "")
                end
            else
                if spellID then
                    secureType = "spell"
                    secureAttr = "spell"
                    secureValue = spellID
                else
                    secureValue = "/use " .. (mountName or "")
                end
            end
        end
    elseif aType == "battlepet" then
        secureValue = "/summonpet " .. (aValue or "")
    elseif aType == "equipped" then
        if hasCond then
            secureValue = "/use " .. conditions .. " " .. (aValue or 1)
        else
            secureValue = "/use " .. (aValue or 1)
        end
    elseif aType == "equipmentset" then
        secureValue = "/equipset " .. (aValue or "")
    elseif aType == "raidmarker" then
        secureValue = "/wm " .. (aValue or 0)
    elseif aType == "uivisibility" then
        secureType = "macro"
        secureAttr = "macrotext"

        local element, state = strsplit(":", aValue)
        local frameName

        if element == "minimap" then frameName = "MinimapCluster"
        elseif element == "micromenu" then frameName = "MicroMenuContainer"
        elseif element == "bags" then frameName = "BagsBar"
        elseif element == "xpbar" or element == "repbar" then frameName = "StatusTrackingBarManager"
        elseif element == "objectives" then frameName = "ObjectiveTrackerFrame"
        elseif element == "player" then frameName = "PlayerFrame"
        elseif element == "target" then frameName = "TargetFrame"
        elseif element == "buffs" then frameName = "BuffFrame"
        elseif element == "debuffs" then frameName = "DebuffFrame"
        end

        if element == "chat" then
             local op = ""
             if state == "show" then op = "ChatFrame1:Show(); if GeneralDockManager then GeneralDockManager:Show() end"
             elseif state == "hide" then op = "ChatFrame1:Hide(); if GeneralDockManager then GeneralDockManager:Hide() end"
             elseif state == "toggle" then op = "local v=not ChatFrame1:IsShown(); ChatFrame1:SetShown(v); if GeneralDockManager then GeneralDockManager:SetShown(v) end"
             end
             if op ~= "" then
                 secureValue = "/run if ChatFrame1 then " .. op .. " end"
             end
        elseif frameName then
             local op = ""
             if state == "show" then op = ":Show()"
             elseif state == "hide" then op = ":Hide()"
             elseif state == "toggle" then op = ":SetShown(not " .. frameName .. ":IsShown())"
             end

             if op ~= "" then
                 secureValue = "/run if " .. frameName .. " then " .. frameName .. op .. " end"
             end
        end

    elseif aType == "uipanel" then
        local microButtons = {
            achievements = "AchievementMicroButton",
            questlog = "QuestLogMicroButton",
            groupfinder = "LFDMicroButton",
            adventureguide = "EJMicroButton",
            collections = "CollectionsMicroButton",
            shop = "StoreMicroButton",
            professions = "ProfessionMicroButton",
            housing = "HousingMicroButton",
        }

        local btnName = microButtons[aValue]
        local btnFrame = btnName and _G[btnName]

        if not btnFrame and btnName then
            if _G.MicroMenuContainer and _G.MicroMenuContainer[btnName] then
                btnFrame = _G.MicroMenuContainer[btnName]
            elseif _G.MicroMenu and _G.MicroMenu[btnName] then
                btnFrame = _G.MicroMenu[btnName]
            end
        end

        if btnFrame then
            secureType = "click"
            secureAttr = "clickbutton"
            secureValue = btnFrame
        else
            local scripts = {
                character = "ToggleCharacter('PaperDollFrame')",
                spellbook = "C_AddOns.LoadAddOn('Blizzard_PlayerSpells');if PlayerSpellsUtil and PlayerSpellsUtil.ToggleSpellBookFrame then PlayerSpellsUtil.ToggleSpellBookFrame() end",
                talents = "C_AddOns.LoadAddOn('Blizzard_PlayerSpells');if PlayerSpellsUtil and PlayerSpellsUtil.ToggleClassTalentOrSpecFrame then PlayerSpellsUtil.ToggleClassTalentOrSpecFrame() end",
                specialization = "C_AddOns.LoadAddOn('Blizzard_PlayerSpells');local f=PlayerSpellsFrame;if f then if f:IsShown() then HideUIPanel(f) else ShowUIPanel(f);if f.TabSystem then f.TabSystem:SetTab(1) end end end",
                collections = "if ToggleCollectionsJournal then ToggleCollectionsJournal() end",
                map = "if ToggleWorldMap then ToggleWorldMap() end",
                groupfinder = "if PVEFrame_ToggleFrame then PVEFrame_ToggleFrame() end",
                adventureguide = "if EncounterJournal_OpenJournal then EncounterJournal_OpenJournal() end",
                achievements = "if ToggleAchievementFrame then ToggleAchievementFrame() end",
                guild = "if ToggleCommunitiesFrame then ToggleCommunitiesFrame() elseif ToggleGuildFrame then ToggleGuildFrame() end",
                menu = "ToggleFrame(GameMenuFrame)",
                shop = "if ToggleStoreUI then ToggleStoreUI() end",
                questlog = "if ToggleQuestLog then ToggleQuestLog() end",
                professions = "if ToggleProfessionsBook then ToggleProfessionsBook() end",
                housing = "if ToggleHousingDashboard then ToggleHousingDashboard() elseif HousingFramesUtil and HousingFramesUtil.ToggleHousingDashboard then HousingFramesUtil.ToggleHousingDashboard() elseif C_Housing and C_Housing.ToggleHousingDashboard then C_Housing.ToggleHousingDashboard() end",
                bag_backpack = "ToggleBackpack()",
                bag_1 = "ToggleBag(1)",
                bag_2 = "ToggleBag(2)",
                bag_3 = "ToggleBag(3)",
                bag_4 = "ToggleBag(4)",
                bag_reagent = "ToggleBag(5)",
                bag_all = "ToggleAllBags()",
                collections_mounts = "if ToggleCollectionsJournal then ToggleCollectionsJournal(1) end",
                collections_pets = "if ToggleCollectionsJournal then ToggleCollectionsJournal(2) end",
                collections_toys = "if ToggleCollectionsJournal then ToggleCollectionsJournal(3) end",
                collections_heirlooms = "if ToggleCollectionsJournal then ToggleCollectionsJournal(4) end",
                collections_appearances = "if ToggleCollectionsJournal then ToggleCollectionsJournal(5) end",
                social = "if ToggleFriendsFrame then ToggleFriendsFrame(1) end",
                social_friends = "if ToggleFriendsFrame then ToggleFriendsFrame(1) end",
                social_who = "if ToggleFriendsFrame then ToggleFriendsFrame(2) end",
                social_raid = "if ToggleFriendsFrame then ToggleFriendsFrame(3) end",
                pvp = "if TogglePVPUI then TogglePVPUI() elseif PVEFrame_ToggleFrame then PVEFrame_ToggleFrame('PVPUIFrame') end",
                dungeons = "PVEFrame_ToggleFrame('GroupFinderFrame')",
                mythicplus = "if PVEFrame and PVEFrame:IsShown() and PVEFrame.activeTabIndex == 3 then HideUIPanel(PVEFrame) else ShowUIPanel(PVEFrame) PVEFrame_ShowFrame('ChallengesFrame') end",
                reputation = "ToggleCharacter('ReputationFrame')",
                currency = "ToggleCharacter('TokenFrame')",
                statistics = "AchievementFrame_LoadUI() AchievementFrame_ToggleAchievementFrame(true)",
                map_size = "if ToggleWorldMap then ToggleWorldMap() end",
                map_zone = "if ToggleBattlefieldMap then ToggleBattlefieldMap() end",
                map_minimap = "if Minimap then if Minimap:IsShown() then Minimap:Hide() else Minimap:Show() end end",
                garrison = "if ExpansionLandingPageMinimapButton then ExpansionLandingPageMinimapButton.Click(ExpansionLandingPageMinimapButton) elseif GarrisonLandingPageMinimapButton then GarrisonLandingPageMinimapButton.Click(GarrisonLandingPageMinimapButton) end",
            }
            if scripts[aValue] then
                secureValue = "/run " .. scripts[aValue]
            end
        end
    elseif aType == "misc" then
        if aValue == "hearthstone" then
            secureType = "item"
            secureAttr = "item"
            secureValue = "Hearthstone"
        elseif aValue == "extrabutton" then
            secureType = "click"
            secureAttr = "clickbutton"
            secureValue = _G["ExtraActionButton1"]
        elseif aValue == "zoneability" then
            secureType = "click"
            secureAttr = "clickbutton"
            local zoneFrame = _G["ZoneAbilityFrame"]
            if zoneFrame and zoneFrame.SpellButton then
                secureValue = zoneFrame.SpellButton
            end
        elseif aValue == "leave_vehicle" then
            secureType = "macro"
            secureAttr = "macrotext"
            secureValue = "/leavevehicle"
        elseif aValue == "custom_macro" then
            secureType = "macro"
            secureAttr = "macrotext"
            secureValue = actionData.macroText or ""
        elseif aValue:match("^spec_") then
            local val = tonumber(aValue:match("^spec_(%d+)"))
            local specIndex = val
            if val and val > 10 then
                specIndex = 1
                for i = 1, GetNumSpecializations() do
                    local id = GetSpecializationInfo(i)
                    if id == val then
                        specIndex = i
                        break
                    end
                end
            end
            secureType = "macro"
            secureAttr = "macrotext"
            secureValue = "/run local func = C_SpecializationInfo and C_SpecializationInfo.SetSpecialization or SetSpecialization; if func then func(" .. specIndex .. ") else print('[Wise] SetSpecialization API not found') end"
        elseif aValue:match("^lootspec_") then
            local specID = tonumber(aValue:match("^lootspec_(%d+)"))
            secureType = "macro"
            secureAttr = "macrotext"
            secureValue = "/run local func = C_SpecializationInfo and C_SpecializationInfo.SetLootSpecialization or SetLootSpecialization; if func then func(" .. specID .. ") else print('[Wise] SetLootSpecialization API not found') end"
        end
    elseif aType == "interface" then
        -- Toggle the target interface via its secure toggle button.
        -- Must use macro+macrotext because the toggleBtn PreClick snippet
        -- only copies type/spell/item/macrotext (not clickbutton).
        secureType = "macro"
        secureAttr = "macrotext"
        secureValue = "/click WiseGroupToggle_" .. aValue
    elseif aType == "empty" then
        secureType = nil
        secureAttr = nil
        secureValue = nil
    end

    return secureType, secureAttr, secureValue
end

-- Helper: Evaluate slot conditions (insecure context) for icon updates
function Wise:EvaluateSlotConditions(states, conflictStrategy, btn)
    local matches = {}
    for i, state in ipairs(states) do
        local cond = Wise:ComputeEffectiveConditions(states, i)
        if cond == "" then
            tinsert(matches, i)
        else
            local result = SecureCmdOptionParse(cond .. " true; false")
            if result == "true" then
                tinsert(matches, i)
            end
        end
    end

    if #matches == 0 then return 1 end

    if conflictStrategy == "sequence" then
        local seq = (btn and btn:GetAttribute("isa_seq")) or 1
        local startIdx = nil
        for i = 1, #matches do
            if matches[i] >= seq then
                startIdx = i
                break
            end
        end
        if not startIdx then startIdx = 1 end
        return matches[startIdx]
    elseif conflictStrategy == "random" then
        return matches[math.random(#matches)]
    else
        -- priority (default)
        return matches[1]
    end
end

-- Helper: Find if a group is nested inside another group as an "interface" action.
-- Returns parentName, parentGroup or nil if not nested.
function Wise:GetParentInfo(groupName)
    if not WiseDB or not WiseDB.groups then return nil, nil end
    for name, group in pairs(WiseDB.groups) do
        if name ~= groupName and group.actions then
            for slotIdx, states in pairs(group.actions) do
                if type(slotIdx) == "number" and type(states) == "table" then
                    for _, action in ipairs(states) do
                        if action.type == "interface" and action.value == groupName then
                            return name, group
                        end
                    end
                end
            end
        end
        -- Also check legacy buttons
        if name ~= groupName and group.buttons then
            for _, action in ipairs(group.buttons) do
                if action.type == "interface" and action.value == groupName then
                    return name, group
                end
            end
        end
    end
    return nil, nil
end

-- Helper: Store a child group's resolved actions on a parent interface button
-- so the secure RESOLVE_BLOCK can execute them for rotation modes.
function Wise:StoreChildActionsOnButton(btn, childGroupName, nestMode)
    -- Clear previous child attributes
    local prevCount = btn:GetAttribute("isa_nest_count") or 0
    for ci = 1, prevCount do
        btn:SetAttribute("isa_nest_type_" .. ci, nil)
        btn:SetAttribute("isa_nest_spell_" .. ci, nil)
        btn:SetAttribute("isa_nest_item_" .. ci, nil)
        btn:SetAttribute("isa_nest_macrotext_" .. ci, nil)
        btn:SetAttribute("isa_nest_cond_" .. ci, nil)
    end
    btn:SetAttribute("isa_nest_count", 0)

    if nestMode == "jump" then return end -- Jump mode uses /click, no child attrs needed

    local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[childGroupName]
    if not childGroup or not childGroup.actions then return end

    -- Collect child slots in order
    local slots = {}
    for slotIdx, states in pairs(childGroup.actions) do
        if type(slotIdx) == "number" and type(states) == "table" then
            table.insert(slots, { index = slotIdx, states = states })
        end
    end
    table.sort(slots, function(a, b) return a.index < b.index end)

    local nestIdx = 0
    for _, slotInfo in ipairs(slots) do
        local states = slotInfo.states
        -- For single-state slots, use the action directly
        -- For multi-state slots, resolve to the currently active one (insecure)
        local activeState = 1
        if #states > 1 then
            local conflictStrategy = states.conflictStrategy or "priority"
            activeState = Wise:EvaluateSlotConditions(states, conflictStrategy, nil) or 1
        end
        local action = states[activeState]
        if action and action.type and action.type ~= "interface" then
            nestIdx = nestIdx + 1
            local sType, sAttr, sValue = Wise:GetSecureAttributes(action, action.conditions)
            local spellVal = (sAttr == "spell") and tostring(sValue) or ""
            local itemVal = (sAttr == "item") and tostring(sValue) or ""
            local macroVal = (sAttr == "macrotext" or sAttr == "macro") and tostring(sValue) or ""
            btn:SetAttribute("isa_nest_type_" .. nestIdx, sType)
            btn:SetAttribute("isa_nest_spell_" .. nestIdx, spellVal)
            btn:SetAttribute("isa_nest_item_" .. nestIdx, itemVal)
            btn:SetAttribute("isa_nest_macrotext_" .. nestIdx, macroVal)
            btn:SetAttribute("isa_nest_cond_" .. nestIdx, action.conditions or "")
        end
    end
    btn:SetAttribute("isa_nest_count", nestIdx)
    -- Initialize sequence counter for cycle/shuffle
    if not btn:GetAttribute("isa_nest_seq") then
        btn:SetAttribute("isa_nest_seq", 1)
    end
    -- For shuffle mode, randomize the order by shuffling the attributes
    if nestMode == "shuffle" and nestIdx > 1 then
        -- Fisher-Yates shuffle of the nest attributes
        for si = nestIdx, 2, -1 do
            local sj = math.random(si)
            if si ~= sj then
                -- Swap si and sj
                local tmpT = btn:GetAttribute("isa_nest_type_" .. si)
                local tmpS = btn:GetAttribute("isa_nest_spell_" .. si)
                local tmpI = btn:GetAttribute("isa_nest_item_" .. si)
                local tmpM = btn:GetAttribute("isa_nest_macrotext_" .. si)
                local tmpC = btn:GetAttribute("isa_nest_cond_" .. si)
                btn:SetAttribute("isa_nest_type_" .. si, btn:GetAttribute("isa_nest_type_" .. sj))
                btn:SetAttribute("isa_nest_spell_" .. si, btn:GetAttribute("isa_nest_spell_" .. sj))
                btn:SetAttribute("isa_nest_item_" .. si, btn:GetAttribute("isa_nest_item_" .. sj))
                btn:SetAttribute("isa_nest_macrotext_" .. si, btn:GetAttribute("isa_nest_macrotext_" .. sj))
                btn:SetAttribute("isa_nest_cond_" .. si, btn:GetAttribute("isa_nest_cond_" .. sj))
                btn:SetAttribute("isa_nest_type_" .. sj, tmpT)
                btn:SetAttribute("isa_nest_spell_" .. sj, tmpS)
                btn:SetAttribute("isa_nest_item_" .. sj, tmpI)
                btn:SetAttribute("isa_nest_macrotext_" .. sj, tmpM)
                btn:SetAttribute("isa_nest_cond_" .. sj, tmpC)
            end
        end
        btn:SetAttribute("isa_nest_seq", 1) -- Reset after shuffle
    end
end

-- Helper: Get the icon for the current rotation action on an interface button.
-- For cycle/shuffle, shows the NEXT action. For random/priority, shows best match.
function Wise:GetRotationIcon(btn, childGroupName, nestMode)
    local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[childGroupName]
    if not childGroup or not childGroup.actions then return nil end

    -- Collect child slots in order
    local slots = {}
    for slotIdx, states in pairs(childGroup.actions) do
        if type(slotIdx) == "number" and type(states) == "table" then
            table.insert(slots, { index = slotIdx, states = states })
        end
    end
    table.sort(slots, function(a, b) return a.index < b.index end)

    -- Build list of valid (non-interface) child actions with resolved states
    local actions = {}
    for _, slotInfo in ipairs(slots) do
        local states = slotInfo.states
        local activeState = 1
        if #states > 1 then
            local cs = states.conflictStrategy or "priority"
            activeState = Wise:EvaluateSlotConditions(states, cs, nil) or 1
        end
        local action = states[activeState]
        if action and action.type and action.type ~= "interface" then
            table.insert(actions, action)
        end
    end

    if #actions == 0 then return nil end

    local chosen = nil
    if nestMode == "priority" then
        -- Show first action whose conditions match
        for _, action in ipairs(actions) do
            local cond = action.conditions or ""
            if cond == "" then
                chosen = action
                break
            else
                local result = SecureCmdOptionParse(cond .. " true; false")
                if result == "true" then
                    chosen = action
                    break
                end
            end
        end
        if not chosen then chosen = actions[1] end
    elseif nestMode == "cycle" or nestMode == "shuffle" then
        -- Show the action at current sequence position
        local seq = btn:GetAttribute("isa_nest_seq") or 1
        local idx = ((seq - 1) % #actions) + 1
        chosen = actions[idx]
    elseif nestMode == "random" then
        -- For random, just show the first action (can't predict)
        chosen = actions[1]
    end

    if chosen then
        return Wise:GetActionIcon(chosen.type, chosen.value, chosen)
    end
    return nil
end

-- Helper: Position a nested child group relative to the parent button that opened it.
-- Uses the child's insecure Anchor frame so it works even during combat.
function Wise:PositionNestedChild(childFrame, childName, parentName)
    local parentFrame = Wise.frames and Wise.frames[parentName]
    if not parentFrame then return end

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

    -- Fallback to parent frame center if no specific button found
    local anchorFrame = parentBtn or parentFrame

    -- Resolve open direction from the action's nesting options
    local direction = "auto"
    if parentBtn then
        direction = parentBtn:GetAttribute("isa_open_direction") or "auto"
    end
    direction = Wise:ResolveOpenDirection(anchorFrame, direction)

    -- Get the anchor frame's center in screen coordinates
    local cx, cy = anchorFrame:GetCenter()
    if not cx or not cy then return end

    local uiScale = UIParent:GetScale()
    local frameScale = childFrame:GetScale()
    local correctedX = cx / frameScale
    local correctedY = cy / frameScale

    -- Offset based on direction (use parent icon size as spacing)
    local spacing = (parentBtn and parentBtn:GetWidth() or 50) + 10
    if direction == "up" then
        correctedY = correctedY + spacing / frameScale
    elseif direction == "down" then
        correctedY = correctedY - spacing / frameScale
    elseif direction == "right" then
        correctedX = correctedX + spacing / frameScale
    elseif direction == "left" then
        correctedX = correctedX - spacing / frameScale
    end
    -- "center" keeps the same position

    -- Move the proxy anchor (safe even in combat)
    if childFrame.Anchor then
        childFrame.Anchor:ClearAllPoints()
        childFrame.Anchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT", correctedX, correctedY)
    end

    -- Also move the secure frame directly (only safe out of combat)
    if not InCombatLockdown() then
        childFrame:ClearAllPoints()
        childFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", correctedX, correctedY)
    end
end

-- Helper: Start a ticker that closes the nested child when the mouse leaves
-- both the child group and the parent group. Respects closeOnLeave nesting option.
function Wise:StartNestedCloseOnLeave(childFrame, childName, parentName)
    -- Cancel any existing ticker
    if childFrame.nestedCloseTicker then
        childFrame.nestedCloseTicker:Cancel()
        childFrame.nestedCloseTicker = nil
    end

    -- Find the interface action data to check closeOnLeave option
    local parentGroup = WiseDB and WiseDB.groups and WiseDB.groups[parentName]
    if not parentGroup or not parentGroup.actions then return end

    local closeOnLeave = true -- default
    for _, states in pairs(parentGroup.actions) do
        if type(states) == "table" then
            for _, action in ipairs(states) do
                if action.type == "interface" and action.value == childName then
                    local opts = Wise:GetNestingOptions(action)
                    if opts then
                        closeOnLeave = opts.closeOnLeave
                    end
                    break
                end
            end
        end
    end

    if not closeOnLeave then return end

    local parentFrame = Wise.frames and Wise.frames[parentName]
    local leaveDelay = 0 -- grace frames before closing
    local leaveCount = 0
    local LEAVE_THRESHOLD = 3 -- ticks (~0.6s) before closing

    childFrame.nestedCloseTicker = C_Timer.NewTicker(0.2, function()
        if not childFrame:IsShown() then
            if childFrame.nestedCloseTicker then
                childFrame.nestedCloseTicker:Cancel()
                childFrame.nestedCloseTicker = nil
            end
            return
        end

        -- Check if mouse is over any child button or the child frame itself
        local overChild = childFrame:IsMouseOver(20, -20, -20, 20) -- slight padding
        local overParent = parentFrame and parentFrame:IsShown() and parentFrame:IsMouseOver(20, -20, -20, 20)

        if overChild or overParent then
            leaveCount = 0
        else
            leaveCount = leaveCount + 1
            if leaveCount >= LEAVE_THRESHOLD then
                -- Close the child interface
                if not InCombatLockdown() then
                    childFrame:SetAttribute("state-manual", "hide")
                    -- Notify the state driver
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
        end
    end)
end

-- Helper: Hide the parent group if closeParentOnOpen is enabled for this nesting.
function Wise:HandleCloseParentOnOpen(childName, parentName)
    local parentGroup = WiseDB and WiseDB.groups and WiseDB.groups[parentName]
    if not parentGroup or not parentGroup.actions then return end

    for _, states in pairs(parentGroup.actions) do
        if type(states) == "table" then
            for _, action in ipairs(states) do
                if action.type == "interface" and action.value == childName then
                    local opts = Wise:GetNestingOptions(action)
                    if opts and opts.closeParentOnOpen then
                        local parentFrame = Wise.frames and Wise.frames[parentName]
                        if parentFrame and parentFrame:IsShown() and not InCombatLockdown() then
                            parentFrame:SetAttribute("state-manual", "hide")
                        end
                    end
                    return
                end
            end
        end
    end
end

-- Helper: Close all child interfaces of a group (cascade close)
function Wise:CloseChildInterfaces(groupName)
    if InCombatLockdown() then return end
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

function Wise:UpdateGroupDisplay(name)
    -- Protect against combat execution (SecureStateDriver, SetPoint, etc.)
    if InCombatLockdown() then
        Wise.pendingUpdates = Wise.pendingUpdates or {}
        Wise.pendingUpdates[name] = true
        return
    end

    local group = WiseDB.groups[name]
    if not group then return end
    
    local f = Wise:CreateGroupFrame(name)
    
    -- Apply Anchor (only for fixed mode or initial positioning)
    -- Mouse mode will reposition via OnUpdate
    -- Determine if this is the "Always Visible + Mouse" mode
    -- Determine if this is the "Always Visible + Mouse" mode
    local layoutType = group.type or "circle"
    local mode = group.interaction or "toggle"
    
    -- Check Availability override (Wiser interfaces)
    if not Wise:IsGroupAvailable(name) then
        RegisterStateDriver(f, "visibility", "hide")
        f:Hide()
        return
    else
        -- Clear any previous "visibility" hide driver that may have been registered
        -- when the group was unavailable. Without this, the "visibility" state driver
        -- permanently overrides all other visibility logic (game, manual, custom, etc.).
        UnregisterStateDriver(f, "visibility")
    end

    -- Migration: Ensure baseVisibility is set if missing
    if not group.visibilitySettings then group.visibilitySettings = {} end
    if not group.visibilitySettings.baseVisibility then
        if group.visibilitySettings.always then group.visibilitySettings.baseVisibility = "ALWAYS_VISIBLE"
        elseif group.visibilitySettings.combat then group.visibilitySettings.baseVisibility = "COMBAT_ONLY"
        elseif group.visibilitySettings.nocombat then group.visibilitySettings.baseVisibility = "NO_COMBAT_ONLY"
        else group.visibilitySettings.baseVisibility = "ALWAYS_HIDDEN" end
    end
    
    -- Ensure defaults
    group.keybindSettings = group.keybindSettings or { trigger = "press" }

    -- Nested Interface Detection (used for strata, toggleOnPress, visibility)
    local parentName, parentGroup = Wise:GetParentInfo(name)

    -- Apply nested inheritance BEFORE visibility driver (driver reads toggleOnPress)
    -- Skip for Wiser interfaces: they manage their own visibility and should not
    -- be forced to ALWAYS_HIDDEN or toggleOnPress by nesting detection.
    if parentName and parentGroup and not group.isWiser then
        -- Nested interfaces must toggle on press to respond to /click from parent.
        -- Even if the group has its own keybind, toggleOnPress is needed because
        -- /click simulates a full down+up and held mode would flash-and-hide.
        if not group.visibilitySettings.toggleOnPress then
            group.visibilitySettings.toggleOnPress = true
        end
        -- Default to ALWAYS_HIDDEN so visibility is controlled by toggle only
        if group.visibilitySettings.baseVisibility ~= "ALWAYS_HIDDEN" then
            group.visibilitySettings.baseVisibility = "ALWAYS_HIDDEN"
        end
        -- If parent uses hideOnUse, inherit it so nested interface closes parent chain
        if parentGroup.visibilitySettings and parentGroup.visibilitySettings.hideOnUse then
            if group.visibilitySettings.hideOnUse == nil then
                group.visibilitySettings.hideOnUse = true
            end
        end
    end

    -- Module 1: Apply Visibility Engine
    local driverString = Wise:BuildVisibilityDriver(f, group)

    -- Apply Strata based on anchor mode and nesting depth
    local baseStrata = (group.anchorMode == "mouse") and "TOOLTIP" or "MEDIUM"
    -- Nested interfaces must render above their parent so their buttons are clickable
    if parentName then
        if baseStrata == "MEDIUM" then
            baseStrata = "HIGH"
        end
    end
    if Wise.editMode then
        f.originalStrata = baseStrata
    else
        f:SetFrameStrata(baseStrata)
    end
    
    -- Gatekeeper Logic: Union of all visibility sources, with wise-hide override
    local gatekeeper = [[
        local game = self:GetAttribute("state-game") or "hide"
        local manual = self:GetAttribute("state-manual") or "hide"
        local custom = self:GetAttribute("state-custom") or "hide"
        local wiseShow = self:GetAttribute("state-wise-show") or "hide"
        local wiseHide = self:GetAttribute("state-wise-hide") or "hide"

        local willShow = false
        if (game == "show" or manual == "show" or custom == "show" or wiseShow == "show") and (wiseHide ~= "show") then
            willShow = true
            self:Show()
        else
            willShow = false
            self:Hide()
        end
        
        local groupName = self:GetAttribute("wiseGroupName")
        local driver = self:GetFrameRef("WiseStateDriver")
        
        if driver and groupName then
             local driverState = willShow and "active" or "inactive"
             driver:RunAttribute("SetState", groupName, driverState)
        end
    ]]
    f:SetAttribute("_onstate-game", gatekeeper)
    f:SetAttribute("_onstate-manual", gatekeeper)
    f:SetAttribute("_onstate-custom", gatekeeper)
    f:SetAttribute("_onstate-wise-show", gatekeeper)
    f:SetAttribute("_onstate-wise-hide", gatekeeper)

    -- Initialize Manual and Wise State if missing (Prevent reset on config update)
    if not InCombatLockdown() then
        if not f:GetAttribute("state-manual") then f:SetAttribute("state-manual", "hide") end
        if not f:GetAttribute("state-wise-show") then f:SetAttribute("state-wise-show", "hide") end
        if not f:GetAttribute("state-wise-hide") then f:SetAttribute("state-wise-hide", "hide") end
    end

    -- Custom Visibility Logic (Immediate + Ticker)
    local function CheckCustomVisibility()
         if InCombatLockdown() then return false end
         local showStr = (group.visibilitySettings and group.visibilitySettings.customShow) or ""
         local hideStr = (group.visibilitySettings and group.visibilitySettings.customHide) or ""
         
         -- Helper: Get Bank Type State
         local isBankOpen = BankFrame and BankFrame:IsShown()
         local isGuildBank = GuildBankFrame and GuildBankFrame:IsShown()
         local isMailbox = MailFrame and MailFrame:IsShown()

         local customShow = false
         
         -- Use separate IFs to allow OR logic if multiple are present
         -- Use brackets %[name%] to prevent substring matches (e.g. 'bank' inside 'guildbank')
         
         if showStr:find("guildbank") then
              if isGuildBank then customShow = true end
         end
         
         if showStr:find("%[bank%]") or showStr:find("%f[%a]bank%f[%a]") then
              if isBankOpen then customShow = true end
         end
         
         if showStr:find("mailbox") then
              if isMailbox then customShow = true end
         end
         
         -- Evaluate Hide (Overrides Show)
         if hideStr:find("guildbank") then
              if isGuildBank then customShow = false end
         end
         
         if hideStr:find("%[bank%]") or hideStr:find("%f[%a]bank%f[%a]") then
              if isBankOpen then customShow = false end
         end

         if hideStr:find("mailbox") then
              if isMailbox then customShow = false end
         end

         return customShow
    end

    -- Initial Custom Check
    local initialCustomState = "hide"
    if CheckCustomVisibility() then 
        initialCustomState = "show"
        if not InCombatLockdown() then f:SetAttribute("state-custom", "show") end
    else
        if not InCombatLockdown() then f:SetAttribute("state-custom", "hide") end
    end

    -- Ticker for updates
    if not f.customVisTicker then
        f.customVisTicker = C_Timer.NewTicker(0.5, function()
             local isShow = CheckCustomVisibility()
             local current = f:GetAttribute("state-custom")
             local target = isShow and "show" or "hide"
             if current ~= target and not InCombatLockdown() then
                 f:SetAttribute("state-custom", target)
             end
        end)
    end

    -- Check if combat visible for mouse tracking
    -- Use raw strings to determine intent
    local rawShow = group.visibilitySettings.customShow or ""
    local rawHide = group.visibilitySettings.customHide or ""
    
    local showInCombat = rawShow:find("%[%]") or rawShow:find("%[always%]") or rawShow:find("%[combat%]")
    local hideInCombat = rawHide:find("%[%]") or rawHide:find("%[always%]") or rawHide:find("%[combat%]")
    
    local isCombatVisible = (showInCombat and not hideInCombat)
    local isAlwaysVisibleMouse = isCombatVisible and (group.anchorMode == "mouse")

    local rawShowStr = group.visibilitySettings.customShow or ""
    local groupToken = "wise:" .. name
    local autoHeld = rawShowStr:find(groupToken, 1, true)
    
    if not InCombatLockdown() then
        -- Force correct visibility synchronously
        -- Don't trust f:GetAttribute("state-game") immediately after RegisterStateDriver as it may be stale.
        -- We calculate what it SHOULD be using the driver string we just built.
        local gameResult = SecureCmdOptionParse_Internal and SecureCmdOptionParse_Internal(driverString) or SecureCmdOptionParse(driverString)
        -- Note: driverString is formatted as "cond show; hide". SecureCmdOptionParse returns "show" or "hide" (or nil->hide).
        
        local gameState = (gameResult == "show") and "show" or "hide"
        local manualState = f:GetAttribute("state-manual") or "hide"
        local customState = initialCustomState
        
        local base = group.visibilitySettings.baseVisibility

        -- Mirror Gatekeeper Logic: Union (OR) with wise-hide override
        local wiseShowState = f:GetAttribute("state-wise-show") or "hide"
        local wiseHideState = f:GetAttribute("state-wise-hide") or "hide"

        local shouldShow = false
        if manualState == "show" then shouldShow = true end
        if customState == "show" then shouldShow = true end
        if gameState == "show" then shouldShow = true end
        if wiseShowState == "show" then shouldShow = true end

        if wiseHideState == "show" then shouldShow = false end

        if shouldShow then
            f:Show()
        else
            f:Hide()
        end
    end
    
    -- Setup Visual Mirror (Insecure frame for combat display)
    if not f.visualDisplay then
         f.visualDisplay = CreateFrame("Frame", nil, UIParent)
         f.visualDisplay:SetSize(50, 50) -- Match group size
         f.visualDisplay.buttons = {}
    end
    
    -- Anchor Visual Display to Proxy (so it follows mouse in combat)
    f.visualDisplay:ClearAllPoints()
    f.visualDisplay:SetPoint("CENTER", f.Anchor, "CENTER")
    f.visualDisplay:SetScale(f:GetScale()) -- Sync scale
    f.visualDisplay:SetFrameStrata(f:GetFrameStrata()) -- Sync strata
    
    -- Event Handler to toggle visual display in combat
    f.visualDisplay:SetScript("OnEvent", function(self, event)
        if isAlwaysVisibleMouse then
            if event == "PLAYER_REGEN_DISABLED" then
                self:Show()
                -- Make the stuck secure frame invisible but active for keybinds
                f:SetAlpha(0)
            elseif event == "PLAYER_REGEN_ENABLED" then
                self:Hide()
                f:SetAlpha(1)
            end
        else
            self:Hide()
            f:SetAlpha(1)
        end
    end)
    f.visualDisplay:RegisterEvent("PLAYER_REGEN_DISABLED")
    f.visualDisplay:RegisterEvent("PLAYER_REGEN_ENABLED")
    
    -- Initial State
    if InCombatLockdown() and isAlwaysVisibleMouse then
        f.visualDisplay:Show()
        f:SetAlpha(0)
    else
        f.visualDisplay:Hide()
        f:SetAlpha(1)
    end
    
    -- ... (Positioning Logic for Proxy Anchor) ...

    -- Apply Anchor (only for fixed mode or initial positioning)
    -- Mouse mode will reposition via OnUpdate
    if group.anchorMode ~= "mouse" then
        -- Static Mode: Restore anchor to f.Anchor
        if not InCombatLockdown() then
             -- Ensure f is anchored to f.Anchor
             -- (We might have detached it in Mouse mode)
             f:ClearAllPoints()
             f:SetPoint("CENTER", f.Anchor, "CENTER")
        end
    
        -- Position f.Anchor acting as the actual position holder
        -- Use full 5-parameter SetPoint to preserve the exact coordinate system from edit mode.
        -- After dragging, WoW anchors as TOPLEFT→BOTTOMLEFT (absolute screen coords), so we
        -- must restore with the same relativePoint to avoid position shifts on edit mode exit.
        f.Anchor:ClearAllPoints()
        if group.anchor then
            local point = group.anchor.point or "CENTER"
            local relPoint = group.anchor.relativePoint or point
            f.Anchor:SetPoint(point, UIParent, relPoint, group.anchor.x or 0, group.anchor.y or 0)
        else
            f.Anchor:SetPoint("CENTER")
        end
        f.Anchor:SetScript("OnUpdate", nil)
        f:SetScript("OnUpdate", nil)
    else
        -- Mouse anchor mode: set up continuous mouse tracking
        
        -- Break dependency on f.Anchor so we can move it (and visualDisplay) in combat
        if not InCombatLockdown() then
            f:ClearAllPoints()
             -- Set initial point to prevent jumping
            local cursorX, cursorY = GetCursorPosition()
            local uiScale = UIParent:GetScale() or 1
            local frameScale = f:GetScale() or 1
            local correctedX = (cursorX / uiScale) / frameScale
            local correctedY = (cursorY / uiScale) / frameScale
            f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", correctedX, correctedY)
        end
        
        -- Attach to ANCHOR frame so it runs even if secure frame is hidden (combat)
        local function MouseFollowUpdate()
            -- Closure captures 'f' and 'group'
            if f.mouseAnchorLocked then return end
            
            -- Get cursor position and correct for UI scale (like UltimateMouseCursor)
            local cursorX, cursorY = GetCursorPosition()
            local uiScale = UIParent:GetScale() or 1
            local frameScale = f:GetScale() or 1
            
            -- Apply scale correction and offsets
            local correctedX = (cursorX / uiScale) / frameScale
            local correctedY = (cursorY / uiScale) / frameScale
            local offsetX = (group.mouseOffsetX or 0) / frameScale
            local offsetY = (group.mouseOffsetY or 0) / frameScale
            
            -- Move the PROXY ANCHOR (Insecure, safe to move in combat NOW that f is detached)
            if f.Anchor then
                f.Anchor:ClearAllPoints()
                f.Anchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT", correctedX + offsetX, correctedY + offsetY)
            end
            
            -- Move the SECURE FRAME (Only safe out of combat)
            if not InCombatLockdown() then
                 f:ClearAllPoints()
                 f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", correctedX + offsetX, correctedY + offsetY)
            end
        end
        
        -- Determine if should lock or follow continuously
        if isAlwaysVisibleMouse then
            -- Always visible: continuously follow mouse
            f.mouseAnchorLocked = false
        else
            -- Hold/toggle modes: will lock when shown
            -- If currently hidden (startup), allow tracking (unlocked) so it's ready at cursor
            if f:IsShown() then
                f.mouseAnchorLocked = true
            else
                f.mouseAnchorLocked = false
            end
        end
        
        f.Anchor:SetScript("OnUpdate", MouseFollowUpdate)
        f:SetScript("OnUpdate", nil) -- Ensure secure frame doesn't run it
    end
    
    if f.toggleBtn then
        -- Default trigger: release_mouseover (standard ring behavior)
        -- We will support explicit selection in options later, but for now map 'press' correctly.
        local derivedTrigger = (group.keybindSettings and group.keybindSettings.trigger) or "release_mouseover"
        -- Legacy support: if repeatPrevious is explicitly true, upgrade to release_repeat
        if derivedTrigger == "release_mouseover" and group.keybindSettings and group.keybindSettings.repeatPrevious then
             derivedTrigger = "release_repeat"
        end

        f.toggleBtn:SetAttribute("trigger", derivedTrigger)
        f.toggleBtn:SetAttribute("repeatPrevious", (group.keybindSettings and group.keybindSettings.repeatPrevious))

        -- Set visibleWhenHeld if explicit OR auto-detected from [wise:Name]
        -- CRITICAL: If Toggle On Press is enabled, we MUST NOT enable visibleWhenHeld,
        -- because visibleWhenHeld causes the frame to hide on release.
        local isHeld = group.visibilitySettings.held or autoHeld
        if group.visibilitySettings.toggleOnPress then isHeld = false end

        f.toggleBtn:SetAttribute("visibleWhenHeld", isHeld)

        f.toggleBtn:SetAttribute("toggleOnPress", group.visibilitySettings.toggleOnPress)
        f.toggleBtn:SetAttribute("hideOnUse", group.visibilitySettings.hideOnUse)
        f.toggleBtn:SetAttribute("layoutType", group.type or "circle")
        f.toggleBtn:SetAttribute("openNestedButton", group.nestingOpenButton or "BUTTON1")

        Wise:DebugPrint(string.format("Group '%s' Config: trigger='%s', held='%s', toggle='%s', repeat='%s'", 
            name, 
            derivedTrigger, 
            tostring(f.toggleBtn:GetAttribute("visibleWhenHeld")), 
            tostring(group.visibilitySettings.toggleOnPress),
            tostring(group.keybindSettings and group.keybindSettings.repeatPrevious)
        ))
    end

    -- Build list of actions to display (Slots -> Active State)
    
    -- Ensure data migration (Transform legacy .buttons to .actions if needed)
    if Wise.MigrateGroupToActions then Wise:MigrateGroupToActions(group) end

    local actionsToShow = {}
    
    if group.actions then
        -- Gather sorted slots
        local slots = {}
        for slotIdx, states in pairs(group.actions) do
            table.insert(slots, {index = slotIdx, states = states})
        end
        table.sort(slots, function(a,b) return a.index < b.index end)

        for _, slotInfo in ipairs(slots) do
            local slotIdx = slotInfo.index
            local states = slotInfo.states

            -- Filter states based on Visibility Logic (Class/Spec/etc)
            -- This ensures we only generate secure attributes for actions that are valid for this character.
            local validStates = {}
            -- Copy conflictStrategy if present (though usually passed separately)
            validStates.conflictStrategy = states.conflictStrategy 
            validStates.resetOnCombat = states.resetOnCombat
            validStates.suppressErrors = states.suppressErrors            
            for _, state in ipairs(states) do
                if Wise:IsActionAllowed(state) then
                     table.insert(validStates, state)
                end
            end

            if #validStates > 0 then
                -- Evaluate conditions to pick the active state from VALID states
                local conflictStrategy = validStates.conflictStrategy or "priority"
                local chosenIdx = Wise:EvaluateSlotConditions(validStates, conflictStrategy, nil)
                local actionData = chosenIdx and validStates[chosenIdx] or validStates[1]
    
                if actionData then
                    -- Check category metadata filter ONLY for the options UI, not the bar renderer itself.
                    local shouldShow = true
                    -- Check if spell/item is known
                    local isKnown = Wise:IsActionKnown(actionData.type, actionData.value)
    
                    if group.dynamic then
                        -- For dynamic groups, collapse "Spacer" actions (empty custom macros)
                        -- A spacer is misc/custom_macro with either no name/macrotext or explicitly named "Empty"
                        local isSpacer = (actionData.type == "misc" and actionData.value == "custom_macro") and
                                         (actionData.name == "Empty" or (not actionData.macroText or actionData.macroText == ""))

                        if shouldShow and isKnown and not isSpacer then
                            table.insert(actionsToShow, {data = actionData, known = true, categoryMatch = true, slot = slotIdx, states = validStates, conflictStrategy = conflictStrategy, suppressErrors = validStates.suppressErrors, activeState = chosenIdx})
                        end
                    else
                        -- Static interfaces: preserve slot positions to prevent collapsing.
                        if Wise.editMode or isKnown then
                            table.insert(actionsToShow, {data = actionData, known = isKnown, categoryMatch = true, slot = slotIdx, states = validStates, conflictStrategy = conflictStrategy, resetOnCombat = validStates.resetOnCombat, suppressErrors = validStates.suppressErrors, activeState = chosenIdx})
                        else
                            -- Action not known on this character: insert empty placeholder to hold the slot position
                            table.insert(actionsToShow, {data = {type="empty", value=nil}, known = true, categoryMatch = true, slot = slotIdx})
                        end
                    end
                end
            elseif not group.dynamic then
                -- Static interfaces: always preserve empty slots (no collapsing)
                table.insert(actionsToShow, {data = {type="empty", value=nil}, known = true, categoryMatch = true, slot = slotIdx})
            end
        end
    end
    -- Fallback for legacy if not migrated (safety)
    if not group.actions and group.buttons then
         for i, actionData in ipairs(group.buttons) do
            local shouldShow = Wise:ShouldShowAction(actionData)
            local isKnown = Wise:IsActionKnown(actionData.type, actionData.value)
            if group.dynamic then
                if shouldShow and isKnown then table.insert(actionsToShow, {data = actionData, known = true, categoryMatch = true, slot = i}) end
            else
                table.insert(actionsToShow, {data = actionData, known = isKnown, categoryMatch = shouldShow, slot = i})
            end
         end
    end
    
    Wise:DebugPrint(string.format("Group '%s': actionsToShow count = %d", name, #actionsToShow))

    -- Create/Update Buttons
    local iconSize, _, _, _, _, _, _, _, _, _, _, _, iconStyle = Wise:GetGroupDisplaySettings(name)

    for i, actionInfo in ipairs(actionsToShow) do
        local actionData = actionInfo.data
        local isKnown = actionInfo.known
        
        local btn = f.buttons[i]
        if not btn then
            btn = CreateFrame("Button", "WiseGroup_"..name.."_Btn"..i, f, "SecureActionButtonTemplate")
            btn:SetSize(iconSize, iconSize)
            btn:RegisterForClicks("AnyUp", "AnyDown") 
            
            -- Icon
            btn.icon = btn:CreateTexture(nil, "ARTWORK")
            btn.icon:SetAllPoints()
            
            -- Cooldown frame (standard WoW cooldown sweep)
            btn.cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
            btn.cooldown:SetAllPoints()
            btn.cooldown:SetDrawEdge(true)
            btn.cooldown:SetDrawSwipe(true)
            btn.cooldown:SetHideCountdownNumbers(false)
            
            -- Text layers (count, keybind, customText) via Text module
            Wise:Text_CreateFontStrings(btn)
            
            tinsert(f.buttons, btn)

            -- Masque Support
            if Wise.MasqueGroup then
                Wise.MasqueGroup:AddButton(btn, {
                    Icon = btn.icon,
                    Cooldown = btn.cooldown,
                    Count = btn.count,
                    HotKey = btn.keybind,
                })
            end
            
            -- Tooltip support
            Wise:AddInterfaceTooltip(btn)

            -- Secure hover tracking
            SecureHandlerWrapScript(btn, "OnEnter", f.toggleBtn, [[ owner:SetAttribute("hoveredButton", self:GetName()) ]])
            SecureHandlerWrapScript(btn, "OnLeave", f.toggleBtn, [[ owner:SetAttribute("hoveredButton", nil) ]])
            

            -- Debug hooks removed to prevent secret value errors




            -- Drag and Drop Support
            Wise:DebugPrint("Registering OnReceiveDrag for " .. btn:GetName())
            
            -- Ensure button can receive mouse events 
            btn:EnableMouse(true)
            btn:RegisterForClicks("AnyUp", "AnyDown")
            
            -- Register for drag to be safe
            btn:RegisterForDrag("LeftButton") 
            
            btn:SetScript("OnReceiveDrag", function(self)
                Wise:OnDragReceive(name, self.slot)
            end)

            btn:SetScript("OnMouseUp", function(self, button)
                 -- Check if cursor has item; if so, OnReceiveDrag SHOULD have fired.
                 local type = GetCursorInfo()
                 if type then
                     -- Fallback?
                     Wise:OnDragReceive(name, self.slot)
                 else
                     -- Normal click
                     -- print("Wise Debug: OnMouseUp fired (No Cursor)")
                 end
            end)
            
            f.toggleBtn:SetFrameRef(btn:GetName(), btn)
            f.toggleBtn:SetFrameRef("btn" .. i, btn)
        end
        
        -- Explicitly clear btn2 ref if we only have 1 button (to avoid stale refs from recycled frames)
        -- MOVED outside loop for clarity
        -- if #actionsToShow == 1 then
        --      f.toggleBtn:SetAttribute("frameref-btn2", nil)
        -- end
        
        btn:Show()
        btn.slot = actionInfo.slot -- Store slot for binding reference
        -- Always apply current global icon size (for existing buttons too)
        btn:SetSize(iconSize, iconSize)
        
        -- Compute secure attributes via helper
        local aType = actionData.type
        local aValue = actionData.value
        local secureType, secureAttr, secureValue = Wise:GetSecureAttributes(actionData, actionData.conditions)

        -- Reset Attributes
        btn:SetAttribute("type", nil)
        btn:SetAttribute("spell", nil)
        btn:SetAttribute("item", nil)
        btn:SetAttribute("macro", nil)
        btn:SetAttribute("macrotext", nil)
        btn:SetAttribute("clickbutton", nil)

        btn:SetAttribute("type", secureType)
        if secureType then
            btn:SetAttribute(secureAttr, secureValue)
        end

        -- Mark interface buttons with nesting attributes
        if aType == "interface" then
            btn:SetAttribute("isa_is_interface", true)
            btn:SetAttribute("isa_interface_target", aValue)
            local nestOpts = Wise:GetNestingOptions(actionData)
            if nestOpts then
                btn:SetAttribute("isa_open_button", nestOpts.openNestedButton or "BUTTON1")
                btn:SetAttribute("isa_open_direction", nestOpts.openDirection or "auto")
            end

            -- Set frame ref from parent toggleBtn to child group frame (for direct toggle in secure snippet)
            local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[aValue]
            if childGroup then
                -- Ensure child frame exists (CreateGroupFrame is idempotent)
                local childFrame = Wise:CreateGroupFrame(aValue)
                if childFrame then
                    f.toggleBtn:SetFrameRef("nested_" .. aValue, childFrame)
                end
            end

            -- Store child group's actions for rotation modes (cycle/shuffle/random/priority)
            local nestMode = (nestOpts and nestOpts.rotationMode) or "jump"
            btn:SetAttribute("isa_nest_mode", nestMode)
            Wise:StoreChildActionsOnButton(btn, aValue, nestMode)
        else
            btn:SetAttribute("isa_is_interface", nil)
            btn:SetAttribute("isa_interface_target", nil)
            btn:SetAttribute("isa_open_button", nil)
            btn:SetAttribute("isa_open_direction", nil)
            btn:SetAttribute("isa_nest_mode", nil)
            btn:SetAttribute("isa_nest_count", nil)
        end

        -- Store all states as secure attributes for condition evaluation
        local allStates = actionInfo.states
        local stateCount = allStates and #allStates or 1
        if stateCount > 1 then
            for sIdx = 1, stateCount do
                local stateAction = allStates[sIdx]
                if stateAction then
                    local computedCond = Wise:ComputeEffectiveConditions(allStates, sIdx)
                    local sType, sAttr, sValue = Wise:GetSecureAttributes(stateAction, computedCond)
                    -- Only store string-safe values for secure snippets (clickbutton is a frame ref)
                    local spellVal = (sAttr == "spell") and tostring(sValue) or ""
                    local itemVal = (sAttr == "item") and tostring(sValue) or ""
                    local macroVal = (sAttr == "macrotext" or sAttr == "macro") and tostring(sValue) or ""
                    local _, _, isOffGcd = Wise:GetCastTimeText(stateAction.type, stateAction.value)
                    btn:SetAttribute("isa_type_" .. sIdx, sType)
                    btn:SetAttribute("isa_spell_" .. sIdx, spellVal)
                    btn:SetAttribute("isa_item_" .. sIdx, itemVal)
                    btn:SetAttribute("isa_macrotext_" .. sIdx, macroVal)
                    btn:SetAttribute("isa_cond_" .. sIdx, computedCond)
                    btn:SetAttribute("isa_offgcd_" .. sIdx, isOffGcd and 1 or 0)
                end
            end
            btn:SetAttribute("isa_count", stateCount)
            btn:SetAttribute("isa_conflict", actionInfo.conflictStrategy or "priority")
            btn:SetAttribute("isa_suppress", actionInfo.suppressErrors and 1 or 0)
            btn:SetAttribute("isa_action_on_down", GetCVarBool("ActionButtonUseKeyDown"))
            btn:SetAttribute("isa_seq", 1)

            -- PreClick secure snippet: uses the SAME RESOLVE_BLOCK as the keybind path
            -- to guarantee identical condition evaluation, sequencing, and macro generation.
            if not btn.isaConditionWrapped then
                local condSnippet = [[
                    local downOnly = self:GetAttribute("isa_action_on_down")
                    if (down and not downOnly) or (not down and downOnly) then return end
                    
                    local _rv_ref = self
                    local _rv_t, _rv_s, _rv_i, _rv_m
                ]] .. Wise.RESOLVE_BLOCK .. [[
                    if _rv_t then
                        self:SetAttribute("type", _rv_t)
                        self:SetAttribute("spell", _rv_s)
                        self:SetAttribute("item", _rv_i)
                        self:SetAttribute("macrotext", _rv_m)
                    end
                ]]
                SecureHandlerWrapScript(btn, "PreClick", btn, condSnippet)
                btn.isaConditionWrapped = true

                -- Error suppression hook (insecure, once per button)
                btn:HookScript("PreClick", function(self)
                    if self:GetAttribute("isa_suppress") == 1 then
                        Wise:BeginErrorSuppression()
                    end
                end)
            end
        else
            -- Single state: clear multi-state attributes
            btn:SetAttribute("isa_count", 0)
        end

        Wise:DebugPrint(string.format("  Btn%d: SecureType='%s' Attr='%s' Value='%s' States=%d",
            i,
            tostring(secureType),
            tostring(secureAttr),
            tostring(secureValue):gsub("\n", "\\n"):sub(1, 50),
            stateCount
        ))
        
        -- Update Icon
        local texture = Wise:GetActionIcon(aType, aValue, actionData)

        -- Custom Macro Dynamic Resolution (Initial)
        local resolvedType, resolvedValue, resolvedIcon
        if aType == "misc" and aValue == "custom_macro" then
             resolvedType, resolvedValue, resolvedIcon = Wise:ResolveMacroData(actionData.macroText)
             if resolvedIcon then texture = resolvedIcon end
        end

        btn.icon:SetTexture(texture)
        
        Wise:ApplyIconStyle(btn, iconStyle)

        -- Store action info for cooldown tracking
        btn.actionType = aType
        btn.actionValue = aValue
        btn.actionData = actionData -- needed for ApplyLayout text
        
        -- Calculate spellID for cooldown tracking
        local spellID, itemID
        if aType == "spell" then
            local spellInfo = C_Spell.GetSpellInfo(aValue)
            if spellInfo then
                spellID = spellInfo.spellID
            end
        elseif aType == "item" or aType == "toy" then
            itemID = aValue
        elseif aType == "mount" and C_MountJournal then
            local _, mSpellID = C_MountJournal.GetMountInfoByID(aValue)
            spellID = mSpellID
        elseif aType == "misc" and aValue == "custom_macro" and resolvedType then
             if resolvedType == "spell" then
                 local info = C_Spell.GetSpellInfo(resolvedValue)
                 if info then spellID = info.spellID end
             elseif resolvedType == "item" then
                 itemID = resolvedValue
             end
        end
        
        -- Store in metadata (safe for combat)
        Wise.buttonMeta = Wise.buttonMeta or {}
        Wise.buttonMeta[btn] = {
            spellID = spellID,
            itemID = itemID,
            actionType = aType,
            actionValue = aValue,
            actionData = actionData,
            states = allStates,
            conflictStrategy = actionInfo.conflictStrategy,
            resetOnCombat = actionInfo.resetOnCombat,
            activeState = actionInfo.activeState or 1,
        }
        btn.groupName = name -- Store for Text lookups
        
        -- Update cooldown immediately
        Wise:UpdateButtonCooldown(btn)
        
        -- Apply visual state for known/unknown and category match
        local categoryMatch = actionInfo.categoryMatch
        local isValid = isKnown and categoryMatch
        btn.isValid = isValid
        
        if isValid then
            -- Initial state saturated; Usability check will refine this later
            btn.icon:SetDesaturated(false)
            btn.icon:SetAlpha(1)
        else
            btn.icon:SetDesaturated(true)
            btn.icon:SetAlpha(0.5)
        end
        
        -- Update count (items, consumable spells, and spell charges)
        local count = 0
        local isChargeSpell = false
        if aType == "item" or aType == "toy" then
            -- Smart Item Source Check
            -- Parse ID if "item:123"
            local itemVal = aValue
             if type(itemVal) == "string" and itemVal:match("^item:(%d+)") then
                 itemVal = tonumber(itemVal:match("^%a+:(%d+)"))
            end
            
            if group.smartSources then
                 local bagCount = GetItemCount(itemVal, false)
                 local bankCount = (GetItemCount(itemVal, true) or 0) - bagCount
                 if bankCount < 0 then bankCount = 0 end
                 
                 if group.smartSources.bags then
                     count = count + bagCount
                 end
                 if group.smartSources.bank then
                     count = count + bankCount
                 end
                 -- Warband/Guild counts not generically available via synchronous API yet
            else
                 count = GetItemCount(itemVal, true) 
            end
        elseif aType == "spell" then
            -- Check for spell charges first
            if spellID then
                local chargeInfo = C_Spell.GetSpellCharges(spellID)
                if chargeInfo and chargeInfo.maxCharges and chargeInfo.maxCharges > 1 then
                    count = chargeInfo.currentCharges
                    isChargeSpell = true
                end
            end
            -- Fallback to consumable spell count if not a charge spell
            if not isChargeSpell and IsConsumableSpell and IsConsumableSpell(aValue) then
                count = GetSpellCount(aValue)
            end
        end
        
        -- Apply charge/count text via Text
        Wise:Text_UpdateCharges(btn, name, count, isChargeSpell)
    end
    
    -- Sync Visual Display Buttons
    if f.visualDisplay then
        local visualIconSize, _, _, _, _, _, _, _, _, _, _, _, visualIconStyle = Wise:GetGroupDisplaySettings(name)
        for i, actionInfo in ipairs(actionsToShow) do
             local actionData = actionInfo.data
             local isKnown = actionInfo.known
             local categoryMatch = actionInfo.categoryMatch
             
             local vBtn = f.visualDisplay.buttons[i]
             if not vBtn then
                 vBtn = CreateFrame("Button", nil, f.visualDisplay)
                 vBtn:SetSize(visualIconSize, visualIconSize)
                 vBtn:EnableMouse(false) -- Not clickable
                 vBtn.icon = vBtn:CreateTexture(nil, "ARTWORK")
                 vBtn.icon:SetAllPoints()
                 vBtn.cooldown = CreateFrame("Cooldown", nil, vBtn, "CooldownFrameTemplate")
                 vBtn.cooldown:SetAllPoints()
                 vBtn.cooldown:SetDrawEdge(true)
                 vBtn.cooldown:SetDrawSwipe(true)
                 vBtn.cooldown:SetHideCountdownNumbers(false)
                 
                 -- Text layers via Text module
                 Wise:Text_CreateFontStrings(vBtn)
                 
                 tinsert(f.visualDisplay.buttons, vBtn)

                 -- Masque Support
                 if Wise.MasqueGroup then
                    Wise.MasqueGroup:AddButton(vBtn, {
                        Icon = vBtn.icon,
                        Cooldown = vBtn.cooldown,
                        Count = vBtn.count,
                        HotKey = vBtn.keybind,
                    })
                 end

                 -- Tooltip support
                 Wise:AddInterfaceTooltip(vBtn)
             end
             vBtn:Show()
             -- Always apply current global icon size
             vBtn:SetSize(visualIconSize, visualIconSize)
             
             -- Apply visuals
             local texture = Wise:GetActionIcon(actionData.type, actionData.value, actionData)
             vBtn.icon:SetTexture(texture)
             
             -- Update action data for tooltips
             vBtn.actionType = actionData.type
             vBtn.actionValue = actionData.value
             vBtn.actionData = actionData

             Wise:ApplyIconStyle(vBtn, visualIconStyle)

             -- Link to real button for cooldown sync
             local realBtn = f.buttons[i]
             if realBtn then
                 realBtn.visualClone = vBtn -- Soft deprecated, keeping for now
                 if Wise.buttonMeta and Wise.buttonMeta[realBtn] then
                     Wise.buttonMeta[realBtn].visualClone = vBtn
                 end
             end
             
             -- Apply Desaturation (same as real button)
             if isKnown and categoryMatch then
                vBtn.icon:SetDesaturated(false)
                vBtn.icon:SetAlpha(1)
             else
                vBtn.icon:SetDesaturated(true)
                vBtn.icon:SetAlpha(0.5)
             end
             
             -- Sync count (mirror position, font, and text from real button)
             local realBtn = f.buttons[i]
             if realBtn and realBtn.count and realBtn.count:IsShown() then
                 vBtn.count:SetText(realBtn.count:GetText())
                 vBtn.count:SetFont(realBtn.count:GetFont())
                 vBtn.count:ClearAllPoints()
                 local p, r, rp, x, y = realBtn.count:GetPoint()
                 if p then
                     vBtn.count:SetPoint(p, vBtn, p, x, y)
                 else
                     vBtn.count:SetPoint("BOTTOMRIGHT", -2, 2)
                 end
                 vBtn.count:Show()
             else
                 vBtn.count:Hide()
             end
             
             -- Sync keybind
             if realBtn and realBtn.keybind and realBtn.keybind:IsShown() then
                 vBtn.keybind:SetText(realBtn.keybind:GetText())
                 vBtn.keybind:SetFont(realBtn.keybind:GetFont())
                 vBtn.keybind:ClearAllPoints()
                 
                 local p, r, rp, x, y = realBtn.keybind:GetPoint()
                 if p then
                     vBtn.keybind:SetPoint(p, r, rp, x, y)
                 else
                     -- Fallback if GetPoint returns nil (shouldn't happen if Shown, but safe)
                     vBtn.keybind:SetPoint("TOP", 0, -2)
                 end
                 vBtn.keybind:Show()
             else
                 vBtn.keybind:Hide()
             end
        end
        -- Hide unused
        for i = #actionsToShow + 1, #f.visualDisplay.buttons do
             f.visualDisplay.buttons[i]:Hide()
        end
        
        -- Apply Layout to Visual Display
        Wise:ApplyLayout(f.visualDisplay, group.type, #actionsToShow, name)
    end
    
    -- Hide unused buttons
    for i = #actionsToShow + 1, #f.buttons do
        f.buttons[i]:Hide()
    end

    -- Cleanup Stale Refs (Critical for Single Button Fallback)
    -- Set the total count so the snippet knows how far to check
    f.toggleBtn:SetAttribute("buttonCount", #actionsToShow)

    -- IMPORTANT: Clear old references if the list got shorter
    local maxExisting = f.toggleBtn:GetAttribute("maxButtonRefs") or 0
    if maxExisting > #actionsToShow then
        for i = #actionsToShow + 1, maxExisting do
            Wise:DebugPrint("Cleanup: Clearing frameref-btn"..i)
            f.toggleBtn:SetAttribute("frameref-btn" .. i, nil)
        end
    end
    f.toggleBtn:SetAttribute("maxButtonRefs", #actionsToShow)
    
    -- Setup Nested Keybind Attributes (on 'f' - the Show/Hide frame)
    local nested = (group.keybindSettings and group.keybindSettings.nested)
    f:SetAttribute("nestedKeybinds", nested)
    
    -- Always update attributes to keep them in sync
    if nested then
        for i, actionInfo in ipairs(actionsToShow) do
            local btn = f.buttons[i]
            local slotKey = group.actions[actionInfo.slot] and group.actions[actionInfo.slot].keybind
            
            f:SetAttribute("nested_key_"..i, slotKey) -- Set or Clear (if nil)
            f:SetAttribute("nested_btn_name_"..i, btn:GetName())
        end
    end
    
    -- Cleanup Stale Keys
    local maxKeys = f:GetAttribute("nested_max_keys") or 0
    if maxKeys > #actionsToShow then
         for i = #actionsToShow + 1, maxKeys do
             f:SetAttribute("nested_key_"..i, nil)
             f:SetAttribute("nested_btn_name_"..i, nil)
         end
    end
    f:SetAttribute("nested_max_keys", #actionsToShow)
    
    Wise:ApplyLayout(f, group.type, #actionsToShow, name)
    
    -- Sync Edit Mode state (skip for mouse-anchored)
    if Wise.editMode and group.anchorMode ~= "mouse" then
        Wise:SetFrameEditMode(f, name, true)
        f:Show()
    else
        Wise:SetFrameEditMode(f, name, false)
    end
    
    -- Sync Cooldowns and Usability once after setup
    for _, btn in ipairs(f.buttons) do
        Wise:UpdateButtonCooldown(btn)
        Wise:UpdateButtonUsability(btn)
    end
    
    -- Condition evaluation ticker for multi-state and interface icon updates
    if f.conditionTicker then f.conditionTicker:Cancel() end
    local needsTicker = false
    for _, btn in ipairs(f.buttons) do
        if btn:IsShown() then
            local meta = Wise.buttonMeta[btn]
            if meta then
                if (meta.states and #meta.states > 1) or meta.actionType == "interface" then
                    needsTicker = true
                    break
                end
                if meta.actionType == "misc" and meta.actionValue == "custom_macro" then
                    needsTicker = true
                    break
                end
            end
        end
    end
    if needsTicker then
        f.conditionTicker = C_Timer.NewTicker(0.2, function()
            local canSetAttrs = not InCombatLockdown()
            for _, btn in ipairs(f.buttons) do
                if btn:IsShown() then
                    local meta = Wise.buttonMeta[btn]
                    if not meta then -- skip
                    elseif meta.actionType == "misc" and meta.actionValue == "custom_macro" then
                         -- Update Custom Macro
                         local mType, mVal, mIcon = Wise:ResolveMacroData(meta.actionData.macroText)
                         if mType then
                             btn.icon:SetTexture(mIcon)
                             local vClone = meta.visualClone or btn.visualClone
                             if vClone and vClone.icon then
                                 vClone.icon:SetTexture(mIcon)
                             end

                             local spellID, itemID
                             if mType == "spell" then
                                 local info = C_Spell.GetSpellInfo(mVal)
                                 if info then spellID = info.spellID end
                             elseif mType == "item" then
                                 itemID = mVal
                             end
                             meta.spellID = spellID
                             meta.itemID = itemID

                             Wise:UpdateButtonCooldown(btn)
                             Wise:UpdateButtonUsability(btn)
                         else
                             -- Reset to default
                             local defaultIcon = 134400 -- Question Mark
                             btn.icon:SetTexture(defaultIcon)
                             local vClone = meta.visualClone or btn.visualClone
                             if vClone and vClone.icon then vClone.icon:SetTexture(defaultIcon) end

                             meta.spellID = nil
                             meta.itemID = nil

                             Wise:UpdateButtonCooldown(btn)
                             Wise:UpdateButtonUsability(btn)
                         end
                    elseif meta.actionType == "interface" then
                        -- Update interface icon dynamically (reflects child's current active action)
                        local nestMode = btn:GetAttribute("isa_nest_mode") or "jump"
                        if nestMode ~= "jump" then
                            -- For rotation modes, show the NEXT action that would fire
                            local rotIcon = Wise:GetRotationIcon(btn, meta.actionValue, nestMode)
                            if rotIcon then
                                btn.icon:SetTexture(rotIcon)
                                local vClone = meta.visualClone or btn.visualClone
                                if vClone and vClone.icon then
                                    vClone.icon:SetTexture(rotIcon)
                                end
                            end
                        else
                            local newIcon = Wise:GetActionIcon("interface", meta.actionValue)
                            if newIcon then
                                btn.icon:SetTexture(newIcon)
                                local vClone = meta.visualClone or btn.visualClone
                                if vClone and vClone.icon then
                                    vClone.icon:SetTexture(newIcon)
                                end
                            end
                        end
                        -- Refresh child action attributes when not in combat
                        if canSetAttrs and nestMode ~= "jump" then
                            Wise:StoreChildActionsOnButton(btn, meta.actionValue, nestMode)
                        end
                    elseif meta.states and #meta.states > 1 then
                        local chosen = Wise:EvaluateSlotConditions(meta.states, meta.conflictStrategy, btn)
                        if chosen and chosen ~= meta.activeState then
                            meta.activeState = chosen
                            local state = meta.states[chosen]
                            if state then
                                btn.icon:SetTexture(Wise:GetActionIcon(state.type, state.value, state))
                                btn.actionType = state.type
                                btn.actionValue = state.value
                                btn.actionData = state

                                -- Update secure attributes when not in combat
                                -- BUT NOT for sequence strategy: the PreClick secure snippet
                                -- manages type/macrotext exclusively for sequences.
                                if canSetAttrs and meta.conflictStrategy ~= "sequence" then
                                    local sType, sAttr, sValue = Wise:GetSecureAttributes(state, state.conditions)
                                    btn:SetAttribute("type", nil)
                                    btn:SetAttribute("spell", nil)
                                    btn:SetAttribute("item", nil)
                                    btn:SetAttribute("macro", nil)
                                    btn:SetAttribute("macrotext", nil)
                                    btn:SetAttribute("clickbutton", nil)
                                    btn:SetAttribute("type", sType)
                                    btn:SetAttribute(sAttr, sValue)
                                end

                                -- Update cooldown tracking for new active state
                                local spellID, itemID
                                if state.type == "spell" then
                                    local info = C_Spell.GetSpellInfo(state.value)
                                    if info then spellID = info.spellID end
                                elseif state.type == "item" or state.type == "toy" then
                                    itemID = state.value
                                elseif state.type == "mount" and C_MountJournal then
                                    local _, mSpellID = C_MountJournal.GetMountInfoByID(state.value)
                                    spellID = mSpellID
                                end
                                meta.spellID = spellID
                                meta.itemID = itemID
                                meta.actionType = state.type
                                meta.actionValue = state.value
                                meta.actionData = state
                                Wise:UpdateButtonCooldown(btn)
                            end
                        end
                    end
                end
            end
        end)
    end

    -- Ensure bindings are active (fixes potential staleness on new groups)
    if Wise.UpdateBindings then Wise:UpdateBindings() end
end

-- Metadata storage to avoid reading SecureFrames in combat
Wise.buttonMeta = {}

function Wise:ApplyIconStyle(btn, style)
    if not btn or not btn.icon then return end

    -- Skip Wise styling if Masque is loaded
    if Wise.MasqueGroup then return end

    style = style or "rounded"

    -- Clear previous mask if exists
    if btn.styleMask then
        btn.icon:RemoveMaskTexture(btn.styleMask)
        btn.styleMask:Hide()
    end

    if style == "rounded" then
        -- Default WoW Icon (slightly rounded square)
        btn.icon:SetTexCoord(0, 1, 0, 1)
    elseif style == "square" then
        -- Zoom in to remove rounded borders
        btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    elseif style == "round" then
        -- Apply circular mask
        if not btn.styleMask then
            btn.styleMask = btn:CreateMaskTexture()
            btn.styleMask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
            btn.styleMask:SetAllPoints(btn.icon)
        end
        btn.styleMask:Show()
        btn.icon:AddMaskTexture(btn.styleMask)
        btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

function Wise:ApplyLayout(frame, type, count, groupName)
    frame.buttons = frame.buttons or {}
    local buttons = frame.buttons
    local iconSize, _, _, showKeybinds = Wise:GetGroupDisplaySettings(groupName)
    
    -- Try to extract group name if not provided (fallback for legacy/secure frames)
    if not groupName and frame:GetName() then
        groupName = frame:GetName():match("WiseGroup_(.+)")
        -- Handle _Visual suffix if present (though we should pass explicit name)
        if groupName and groupName:match("_Visual$") then
            groupName = groupName:gsub("_Visual$", "")
        end
    end

    local invertOrder = false
    if groupName and WiseDB.groups[groupName] and WiseDB.groups[groupName].invertOrder then
        invertOrder = true
    end
    
    -- Ensure all buttons are shown initially
    for i=1, count do
        local btn = buttons[i]
        btn:Show()
        
        -- Update Keybind Display via Text
        Wise:Text_UpdateKeybind(btn, groupName, showKeybinds)
        
        -- If this is a visual clone, ensure its keybind text is also synchronized
        if btn.visualClone and btn.visualClone.keybind then
             if btn.keybind and btn.keybind:IsShown() then
                 btn.visualClone.keybind:SetText(btn.keybind:GetText())
                 btn.visualClone.keybind:SetFont(btn.keybind:GetFont())
                 btn.visualClone.keybind:ClearAllPoints()
                 local p, r, rp, x, y = btn.keybind:GetPoint()
                 if p then btn.visualClone.keybind:SetPoint(p, r, rp, x, y) end
                 btn.visualClone.keybind:Show()
             else
                 btn.visualClone.keybind:Hide()
             end
        end
    end

    if type == "button" then
        for i=1, count do
            local btn = buttons[i]
            if i == 1 then
                btn:Show()
                buttons[i].targetX = 0
                buttons[i].targetY = 0
                buttons[i]:SetPoint("CENTER", 0, 0)
            else
                buttons[i]:Hide()
                buttons[i].targetX = 0
                buttons[i].targetY = 0
            end
        end
    elseif type == "line" then
        local growDir = "right"
        local linePadding = 5 -- default padding between buttons
        if groupName and WiseDB.groups[groupName] then
            growDir = WiseDB.groups[groupName].growthDirection or "right"
            if WiseDB.groups[groupName].padding then
                linePadding = WiseDB.groups[groupName].padding
            end
        end
        local spacing = iconSize + linePadding
        
        local dx, dy = 0, 0
        if growDir == "right" then dx = spacing
        elseif growDir == "left" then dx = -spacing
        elseif growDir == "up" then dy = spacing
        elseif growDir == "down" then dy = -spacing
        end

        for i=1, count do
            local idx = i - 1
            if invertOrder then idx = count - i end
            buttons[i].targetX = idx * dx
            buttons[i].targetY = idx * dy
            buttons[i]:SetPoint("CENTER", buttons[i].targetX, buttons[i].targetY)
        end
    elseif type == "box" then
        local fixedAxis = "x"
        local boxW = 3
        local boxH = 3
        local boxPaddingX = 5 -- default X padding
        local boxPaddingY = 5 -- default Y padding
        
        if groupName and WiseDB.groups[groupName] then
            local g = WiseDB.groups[groupName]
            fixedAxis = g.fixedAxis or "x"
            boxW = g.boxWidth or 3
            boxH = g.boxHeight or 3
            if g.paddingX then boxPaddingX = g.paddingX end
            if g.paddingY then boxPaddingY = g.paddingY end
        end
        local spacingX = iconSize + boxPaddingX
        local spacingY = iconSize + boxPaddingY
        
        local cols, rows
        if fixedAxis == "x" then
            cols = math.max(1, boxW) -- Safety
            rows = math.ceil(count / cols)
        else
            rows = math.max(1, boxH) -- Safety
            cols = math.ceil(count / rows)
        end
        if cols < 1 then cols = 1 end -- Double safety if rows calculation results in 0 cols (count=0)
        
        -- Grid centering logic:
        -- Center the grid around (0,0).
        local totalH = (rows - 1) * spacingY
        local startY = totalH / 2
        
        for i=1, count do
            local posIndex = i - 1
            if invertOrder then posIndex = count - i end

            local r = math.floor(posIndex / cols)
            local c = posIndex % cols
            
            local itemsInThisRow = cols
            if r == rows - 1 then
                local rem = count % cols
                if rem > 0 then itemsInThisRow = rem end
            end
            
            local rowIdx = c
            
            local rowWidth = (itemsInThisRow - 1) * spacingX
            local startX = -(rowWidth / 2)
            
            buttons[i].targetX = startX + (rowIdx * spacingX)
            buttons[i].targetY = startY - (r * spacingY)
            
            buttons[i]:SetPoint("CENTER", buttons[i].targetX, buttons[i].targetY)
        end
    elseif type == "list" then
        -- Vertical text-based list
        local iconSize, textSize, fontPath = Wise:GetGroupDisplaySettings(groupName)
        local listPadding = 8 -- default line padding
        if groupName and WiseDB.groups[groupName] and WiseDB.groups[groupName].padding then
            listPadding = WiseDB.groups[groupName].padding
        end
        local listIconSize = iconSize
        local contentHeight = math.max(textSize, listIconSize)
        local lineHeight = contentHeight + listPadding
        local maxTextWidth = 0
        -- groupName is now passed as argument
        
        -- Alignment (Pre-calculate for loop)
        local textAlign = (WiseDB.groups[groupName] and WiseDB.groups[groupName].textAlign) or "right"

        for i=1, count do
            local idx = i - 1
            if invertOrder then idx = count - i end
            buttons[i].targetX = 0
            buttons[i].targetY = -idx * lineHeight
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
            if w > maxTextWidth then maxTextWidth = w end
        end
        
        -- Second pass: Align Timers and Lines
        local timerOffset = 0
        if textAlign == "right" then
             -- IconHalf + Gap + Text + Gap
             timerOffset = (listIconSize / 2) + 5 + maxTextWidth + 40 
        else
             -- IconHalf + Gap
             timerOffset = (listIconSize / 2) + 40
        end
        
        for i=1, count do
            -- Timer Label
            if not buttons[i].timerLabel then 
                 buttons[i].timerLabel = buttons[i]:CreateFontString(nil, "OVERLAY")
                 buttons[i].timerLabel:SetJustifyH("LEFT")
            end
            -- Apply global font settings to timer label
            buttons[i].timerLabel:SetFont(fontPath, textSize, "")
            
            buttons[i].timerLabel:ClearAllPoints()
            -- Anchor relative to CENTER of button (where Icon is)
            buttons[i].timerLabel:SetPoint("LEFT", buttons[i], "CENTER", timerOffset, 0)
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
        
        -- Resize button frame to encompass everything
        -- Since Icon is CENTERED, we need width to cover the widest side * 2
        local maxSide = timerOffset + 50 -- Timer is usually furthest right
        if textAlign == "left" then
             local leftSide = (listIconSize / 2) + 5 + maxTextWidth + 10
             if leftSide > maxSide then maxSide = leftSide end
        end
        local totalWidth = maxSide * 2
        
        for i=1, count do
             buttons[i]:SetSize(totalWidth, lineHeight) 
        end
    else -- circle
        -- Configurable radius with minimum to prevent overlap
        local circleRadius, circleRotation
        if groupName and WiseDB.groups[groupName] then
            circleRadius = WiseDB.groups[groupName].circleRadius
            circleRotation = WiseDB.groups[groupName].circleRotation or 0
        end
        -- Default radius if not set
        if not circleRadius then
            circleRadius = iconSize * 2
        end
        if not circleRotation then circleRotation = 0 end
        local step = 360 / max(count, 1)
        for i=1, count do
            local angle
            if invertOrder then
                angle = -(i-1) * step + circleRotation
            else
                angle = (i-1) * step + circleRotation
            end
            local rad = math.rad(angle + 90)
            buttons[i].targetX = math.cos(rad) * circleRadius
            buttons[i].targetY = math.sin(rad) * circleRadius
            buttons[i]:SetPoint("CENTER", buttons[i].targetX, buttons[i].targetY)
            buttons[i]:SetSize(iconSize, iconSize) -- Reset size to global setting
            buttons[i].icon:ClearAllPoints()
            buttons[i].icon:SetAllPoints()
            if buttons[i].textLabel then
                buttons[i].textLabel:Hide()
            end
        end
    end
    
    -- Reset non-list buttons to normal size
    if type ~= "list" then
        for i=1, count do
            buttons[i]:SetSize(iconSize, iconSize)
            buttons[i].icon:ClearAllPoints()
            buttons[i].icon:SetAllPoints()
            if buttons[i].textLabel then
                buttons[i].textLabel:Hide()
            end
            -- Reset count anchor back to button frame using Text positioning
            if buttons[i].count and buttons[i].groupName then
                local _, _, _, _, _, _, _, cPos = Wise:GetGroupDisplaySettings(buttons[i].groupName)
                Wise:Text_ApplyPosition(buttons[i].count, cPos or "TOP")
            elseif buttons[i].count then
                buttons[i].count:ClearAllPoints()
                buttons[i].count:SetPoint("TOP", buttons[i], "TOP", 0, -2)
            end
        end
    end
end

function Wise:PlaySlideAnimation(frame, isOpening, onComplete)
    local animatingCount = 0
    local completedCount = 0
    
    for _, btn in ipairs(frame.buttons) do
        if btn:IsShown() or not isOpening then
            animatingCount = animatingCount + 1
            
            if not btn.animGroup then
                btn.animGroup = btn:CreateAnimationGroup()
                btn.animTranslate = btn.animGroup:CreateAnimation("Translation")
                btn.animTranslate:SetDuration(0.15)
                btn.animTranslate:SetSmoothing("OUT")
            end
            
            if isOpening then
                -- Opening: slide from center to target position
                btn:ClearAllPoints()
                btn:SetPoint("CENTER", 0, 0)
                btn.animTranslate:SetOffset(btn.targetX or 0, btn.targetY or 0)
                btn.animGroup:SetScript("OnFinished", function()
                    -- Skip button manipulation if in combat (secure frame protection)
                    if not InCombatLockdown() then
                        btn:ClearAllPoints()
                        btn:SetPoint("CENTER", btn.targetX or 0, btn.targetY or 0)
                    end
                    completedCount = completedCount + 1
                    if completedCount >= animatingCount and onComplete then
                        onComplete()
                    end
                end)
            else
                -- Closing: slide from target position back to center
                btn:ClearAllPoints()
                btn:SetPoint("CENTER", btn.targetX or 0, btn.targetY or 0)
                btn.animTranslate:SetOffset(-(btn.targetX or 0), -(btn.targetY or 0))
                btn.animGroup:SetScript("OnFinished", function()
                    -- Skip button manipulation if in combat (secure frame protection)
                    if not InCombatLockdown() then
                        btn:ClearAllPoints()
                        btn:SetPoint("CENTER", 0, 0)
                    end
                    completedCount = completedCount + 1
                    if completedCount >= animatingCount and onComplete then
                        onComplete()
                    end
                end)
            end
            btn.animGroup:Play()
        end
    end
    
    -- If no buttons to animate, call callback immediately
    if animatingCount == 0 and onComplete then
        onComplete()
    end
end

function Wise:ActivateGroup(name)
    local f = Wise.frames[name]
    if not f then Wise:UpdateGroupDisplay(name) f = Wise.frames[name] end
    
    if f.toggleBtn then
        f.toggleBtn:Click()
    else
        if f:IsShown() then
            f:Hide()
        else
            f:Show()
            -- Animation is handled by OnShow script
        end
    end
end

Wise.BindingFrame = CreateFrame("Frame")
function Wise:UpdateBindings()
    if InCombatLockdown() then return end
    ClearOverrideBindings(Wise.BindingFrame)
    
    for name, group in pairs(WiseDB.groups) do
        -- 1. Group Toggle Binding
        if group.binding and string.len(group.binding) > 0 then
            -- "WiseGroupToggle_"..name is the global name of the secure button
            SetOverrideBindingClick(Wise.BindingFrame, true, group.binding, "WiseGroupToggle_"..name)
        end
        
        -- 2. Slot Bindings (Direct Mode only)
        -- Nested bindings are handled by the SecureFrame itself (via attributes)
        local f = Wise.frames[name]
        local _, _, _, showKeybinds = Wise:GetGroupDisplaySettings(name)

        if group.actions then
            local nested = (group.keybindSettings and group.keybindSettings.nested)
            if not nested then
                for slotIdx, actionList in pairs(group.actions) do
                    if actionList.keybind and string.len(actionList.keybind) > 0 then
                        -- Find button matching this slot
                        if f and f.buttons then
                            local foundBtn = nil
                            for _, btn in ipairs(f.buttons) do
                                if btn:IsShown() and btn.slot == slotIdx then
                                    foundBtn = btn
                                    break
                                end
                            end
                            
                            if foundBtn and _G[foundBtn:GetName()] then
                                SetOverrideBindingClick(Wise.BindingFrame, true, actionList.keybind, foundBtn:GetName())
                            end
                        end
                    end
                end
            end
        end

        -- 3. Refresh Keybind UI Text
        if f and f.buttons then
            for _, btn in ipairs(f.buttons) do
                if btn:IsShown() then
                    Wise:Text_UpdateKeybind(btn, name, showKeybinds)
                end
            end
        end
    end
end


-- Cooldown Update Functions
-- Cooldown Update Functions
function Wise:UpdateButtonCooldown(btn)
    if not btn or not btn.cooldown then return end
    
    -- Retrieve metadata safely
    local meta = Wise.buttonMeta and Wise.buttonMeta[btn]
    
    local spellID = (meta and meta.spellID) or btn.spellID
    local itemID = (meta and meta.itemID) or btn.itemID
    local visualClone = (meta and meta.visualClone) or btn.visualClone
    
    local start, duration = 0, 0
    
    if spellID then
        local cooldownInfo = C_Spell.GetSpellCooldown(spellID)
        if cooldownInfo then
            start = cooldownInfo.startTime or 0
            duration = cooldownInfo.duration or 0
        end
    elseif itemID then
        start, duration = C_Item.GetItemCooldown(itemID)
        start = start or 0
        duration = duration or 0
    end
    
    start = start or 0
    duration = duration or 0
    
    -- Buff Duration Override (Cooldown Manager Style)
    local isBuffActive = false
    local _, _, _, _, _, _, _, _, _, _, _, showBuffs, _, showGCD = Wise:GetGroupDisplaySettings(btn.groupName)

    -- GCD Check (Hide if showGCD is false)
    if not showGCD then
        local isGCD = false

        -- Use Global API for GCD reference (sometimes cleaner regarding struct/table taint)
        local gcdStart, gcdDuration = 0, 0
        local gcdMS = 0
        if GetSpellBaseCooldown then
            local _cdMS, _gcdMS = GetSpellBaseCooldown(spellID)
            gcdMS = _gcdMS or 0
        end
        if GetSpellCooldown then
             gcdStart, gcdDuration = GetSpellCooldown(61304)
        elseif C_Spell.GetSpellCooldown then
             local info = C_Spell.GetSpellCooldown(61304)
             if info then gcdStart, gcdDuration = info.startTime, info.duration end
        end

        -- Wrap logic in pcall to avoid "secret number" comparison errors (e.g. start > 0)
        local success = pcall(function()
            if start > 0 and duration > 0 then
                if gcdDuration and gcdDuration > 0 then
                    -- Only check duration match. Ignore start time (avoids secret number diff/taint)
                    -- Start time is the protected value in combat; duration is typically safe.
                    if math.abs(duration - gcdDuration) < 0.1 then
                        isGCD = true
                    end
                end
            end
        end)

        -- If pcall failed or check succeeded
        if success and isGCD then
             start = 0
             duration = 0
        end
    end
    
    if showBuffs and spellID then
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
        
        -- Fallback: Check by Name if ID fails (common for buffs with different IDs than cast)
        -- Also try iterating if direct lookup fails (sometimes GetPlayerAuraBySpellID is picky)
        if not aura then
             local spellName = C_Spell.GetSpellName(spellID)
             if spellName then
                 aura = C_UnitAuras.GetAuraDataBySpellName("player", spellName)
             end
        end
        
        -- Deprecated: Target Debuff Scanning removed due to taint issues.
        -- We only track player buffs now.
        
        if aura and aura.expirationTime and aura.duration and aura.duration > 0 then
            -- Override cooldown display with buff/debuff duration
            start = aura.expirationTime - aura.duration
            duration = aura.duration
            isBuffActive = true
        end
    end
    
    if btn.cooldown.SetSwipeColor then
         btn.cooldown:SetSwipeColor(0, 0, 0, 0.8) -- Reset to default blackish
    end
    
    btn.cooldown:SetCooldown(start, duration)
    
    if visualClone and visualClone.cooldown then
        visualClone.cooldown:SetCooldown(start, duration)
        visualClone.cooldown:Show()
    end
    
    -- Handle Countdown Text
    local parent = btn:GetParent()
    local isListMode = false
    local groupName = btn.groupName
    if parent and parent.groupName and WiseDB.groups[parent.groupName] then
        isListMode = (WiseDB.groups[parent.groupName].type == "list")
        if not groupName then groupName = parent.groupName end
    end
    
    -- 1. Hide Standard Blizzard Numbers (All Modes)
    btn.cooldown:SetHideCountdownNumbers(true)
    if visualClone and visualClone.cooldown then
        visualClone.cooldown:SetHideCountdownNumbers(true)
    end
    
    -- Safely check cooldown state
    local isActive = false
    local success, result = pcall(function()
        return (start and start > 0) and (duration and duration > 0) and (GetTime() < (start + duration))
    end)
    if success then isActive = result end

    -- Clear old OnUpdate script (crucial for migration/performance)
    btn:SetScript("OnUpdate", nil)

    if isActive then
         -- Register with Central Handler
         Wise.ActiveCooldownButtons[btn] = {
             start = start,
             duration = duration,
             groupName = groupName,
             isListMode = isListMode,
             isBuffActive = isBuffActive,
             lastText = ""
         }
         Wise.CooldownUpdateFrame:Show()
         
         if isListMode then
             btn.cooldown:SetAlpha(0) -- Hide swipe in list mode
             if btn.timerLabel then 
                btn.timerLabel:Show()
                if isBuffActive then
                    btn.timerLabel:SetTextColor(0, 1, 0) -- Green text for buffs
                else
                    btn.timerLabel:SetTextColor(1, 1, 1) -- White text for cooldowns
                end
             end
             if btn.redLine then 
                btn.redLine:Show() 
                if isBuffActive then
                    btn.redLine:SetVertexColor(0, 1, 0) -- Green line for buffs
                else
                    btn.redLine:SetVertexColor(1, 0, 0) -- Red line for cooldowns
                end
             end
         else
             btn.cooldown:SetAlpha(1) -- Show swipe in normal mode
             -- Optional: Color the swipe or text for buffs?
             -- The cooldown frame itself doesn't easily support color changes without replacing texture.
             -- But we can color the text.
         end
    else
         -- Not Active / Finished
         Wise.ActiveCooldownButtons[btn] = nil
         
         if isListMode then
             if btn.timerLabel then btn.timerLabel:SetText("") end
             if btn.redLine then btn.redLine:SetWidth(0); btn.redLine:Hide() end
             btn.cooldown:SetAlpha(0) 
         else
             btn.cooldown:SetAlpha(1)
             Wise:Text_UpdateCountdown(btn, groupName, "")
              -- Sync Visual Clone if present
              local meta = Wise.buttonMeta and Wise.buttonMeta[btn]
              local vClone = (meta and meta.visualClone) or btn.visualClone
              if vClone then
                   Wise:Text_UpdateCountdown(vClone, groupName, "")
              end
         end
    end
end

function Wise:UpdateAllCooldowns()
    for name, frame in pairs(Wise.frames) do
        -- Skip if group data is missing (stale frame check)
        if not WiseDB.groups[name] then
            Wise.frames[name] = nil
        elseif frame.buttons then
            for _, btn in ipairs(frame.buttons) do
                -- Check visibility safely. 
                -- Note: btn:IsShown() on secure frame is safe.
                local meta = Wise.buttonMeta and Wise.buttonMeta[btn]
                local visualClone = (meta and meta.visualClone) or btn.visualClone
                
                if btn:IsShown() or (visualClone and visualClone:IsShown()) then
                    Wise:UpdateButtonCooldown(btn)
                end
            end
        end
    end
end

-- Charge Count Update Functions
function Wise:UpdateButtonCharges(btn)
    if not btn or not btn.count then return end
    
    local meta = Wise.buttonMeta and Wise.buttonMeta[btn]
    if not meta then return end
    
    local spellID = meta.spellID
    local actionType = meta.actionType
    
    -- Only update charge-based spells
    if actionType ~= "spell" or not spellID then return end
    
    local chargeInfo = C_Spell.GetSpellCharges(spellID)
    local isValidCharge = false
    local currentCharges = 0
    
    local success = pcall(function()
        if chargeInfo and chargeInfo.maxCharges and chargeInfo.maxCharges > 1 then
            isValidCharge = true
            currentCharges = chargeInfo.currentCharges
        end
    end)
    
    if success and isValidCharge then
        -- Re-apply position and font via Text (ensures settings changes are reflected)
        local groupName = btn.groupName
        if groupName then
            local _, _, fontPath, _, _, _, chargeTextSize, chargeTextPosition, _, _, _, _, _, _, showChargeText = Wise:GetGroupDisplaySettings(groupName)
            if not showChargeText then
                btn.count:Hide()
                local visualClone = (meta and meta.visualClone) or btn.visualClone
                if visualClone and visualClone.count then
                    visualClone.count:Hide()
                end
                return
            end
            Wise:Text_ApplyPosition(btn.count, chargeTextPosition or "TOP")
            btn.count:SetFont(fontPath, chargeTextSize, "OUTLINE")
        end
        
        btn.count:SetText(currentCharges)
        btn.count:Show()
        
        -- Sync visual clone
        local visualClone = (meta and meta.visualClone) or btn.visualClone
        if visualClone and visualClone.count then
            visualClone.count:SetText(currentCharges)
            -- Mirror position from real button
            visualClone.count:ClearAllPoints()
            local p, r, rp, x, y = btn.count:GetPoint()
            if p then
                visualClone.count:SetPoint(p, visualClone, p, x, y)
            end
            visualClone.count:Show()
        end
    end
end

function Wise:UpdateAllCharges()
    for name, frame in pairs(Wise.frames) do
        -- Skip if group data is missing (stale frame check)
        if not WiseDB.groups[name] then
            Wise.frames[name] = nil
        elseif frame.buttons then
            for _, btn in ipairs(frame.buttons) do
                local meta = Wise.buttonMeta and Wise.buttonMeta[btn]
                local visualClone = (meta and meta.visualClone) or btn.visualClone
                
                if btn:IsShown() or (visualClone and visualClone:IsShown()) then
                    Wise:UpdateButtonCharges(btn)
                end
            end
        end
    end
end


-- Usability Update Functions
function Wise:UpdateButtonUsability(btn)
    if not btn or not btn.icon then return end
    
    -- If permanently disabled (filtered/unknown), do not touch
    if btn.isValid == false then return end
    
    -- Retrieve metadata safely
    local meta = Wise.buttonMeta and Wise.buttonMeta[btn]
    
    local spellID = (meta and meta.spellID) or btn.spellID
    local itemID = (meta and meta.itemID) or btn.itemID
    local visualClone = (meta and meta.visualClone) or btn.visualClone
    local vIcon = visualClone and visualClone.icon
    
    local isUsable, noMana = true, false
    
    -- Module 4: API Compatibility (Polyfill)
    if spellID then
        isUsable, noMana = Wise:IsSpellUsable(spellID)
    elseif itemID then
        if C_Item and C_Item.IsUsableItem then
             isUsable, noMana = C_Item.IsUsableItem(itemID)
        else
             isUsable, noMana = IsUsableItem(itemID)
        end
    end

    if isUsable then
        btn.icon:SetDesaturated(false)
        btn.icon:SetVertexColor(1, 1, 1)
        btn.icon:SetAlpha(1)
        if vIcon then
            vIcon:SetDesaturated(false)
            vIcon:SetVertexColor(1, 1, 1)
            vIcon:SetAlpha(1)
        end
    elseif noMana then
        -- Blue tint for OOM
        btn.icon:SetDesaturated(false)
        btn.icon:SetVertexColor(0.5, 0.5, 1.0)
        btn.icon:SetAlpha(1)
        if vIcon then
            vIcon:SetDesaturated(false)
            vIcon:SetVertexColor(0.5, 0.5, 1.0)
            vIcon:SetAlpha(1)
        end
    else
        btn.icon:SetAlpha(0.3) -- Lower alpha to make it harder to see
        if vIcon then
            vIcon:SetDesaturated(true)
            vIcon:SetVertexColor(1, 1, 1)
            vIcon:SetAlpha(0.3)
        end
    end

    -- Proc Glow Handling
    local _, _, _, _, _, _, _, _, _, _, showGlows = Wise:GetGroupDisplaySettings(btn.groupName)
    
    local shouldGlow = false
    if showGlows and spellID then
        shouldGlow = C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed(spellID)
    end
    
    if shouldGlow then
        Wise:ShowOverlayGlow(btn)
        if visualClone then Wise:ShowOverlayGlow(visualClone) end
    else
        Wise:HideOverlayGlow(btn)
        if visualClone then Wise:HideOverlayGlow(visualClone) end
    end
end

function Wise:UpdateAllUsability()
    for name, frame in pairs(Wise.frames) do
        -- Skip if group data is missing (stale frame check)
        if not WiseDB.groups[name] then
            Wise.frames[name] = nil
        elseif frame.buttons then
            for _, btn in ipairs(frame.buttons) do
                -- Check visibility safely
                local meta = Wise.buttonMeta and Wise.buttonMeta[btn]
                local visualClone = (meta and meta.visualClone) or btn.visualClone
                
                if btn:IsShown() or (visualClone and visualClone:IsShown()) then
                    Wise:UpdateButtonUsability(btn)
                end
            end
        end
    end
end

-- Error Suppression System
-- When a Wise button with "Suppress all errors" is clicked, temporarily prevent
-- UIErrorsFrame from receiving UI_ERROR_MESSAGE at all (no text, no sound).
do
    local suppressing = false
    local ERROR_FILTER_DURATION = 0.5
    local savedErrorSpeech = nil

    -- Hook AddMessage to catch any error text that bypasses the event system
    local origAddMessage = UIErrorsFrame.AddMessage
    UIErrorsFrame.AddMessage = function(self, ...)
        if suppressing then return end
        return origAddMessage(self, ...)
    end

    function Wise:BeginErrorSuppression()
        if suppressing then return end
        suppressing = true

        -- 1. Block red error text via event
        UIErrorsFrame:UnregisterEvent("UI_ERROR_MESSAGE")
        UIErrorsFrame:Clear()

        -- 2. Block error speech/voice ("That is still recharging", etc.)
        savedErrorSpeech = GetCVarBool("Sound_EnableErrorSpeech")
        SetCVar("Sound_EnableErrorSpeech", 0)

        -- Re-enable after a short window
        C_Timer.After(ERROR_FILTER_DURATION, function()
            UIErrorsFrame:RegisterEvent("UI_ERROR_MESSAGE")
            -- Restore error speech to whatever the user had it set to
            if savedErrorSpeech then
                SetCVar("Sound_EnableErrorSpeech", 1)
            end
            suppressing = false
        end)
    end
end

-- Cooldown & Usability Event Handler
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
-- Usability events
eventFrame:RegisterEvent("SPELL_UPDATE_USABLE")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("UNIT_AURA") 
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
eventFrame:SetScript("OnEvent", function(self, event, unit)
    if event == "UNIT_AURA" then
        if unit == "target" or unit == "player" then
            Wise:UpdateAllUsability()
            Wise:UpdateAllCooldowns()
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        Wise:UpdateAllUsability()
        Wise:UpdateAllCooldowns()
    elseif event == "SPELL_UPDATE_USABLE" then
        Wise:UpdateAllUsability()
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        Wise:UpdateAllUsability()
    elseif event == "SPELL_UPDATE_CHARGES" then
        Wise:UpdateAllCharges()
    else
        -- Cooldown events
        Wise:UpdateAllCooldowns()
        Wise:UpdateAllCharges()
        -- Also check usability on CD update (sometimes related?) 
        -- Optimization: usually not needed, but safe to do if not spammy.
    end
end)

-- Flash Animation for Immediate Feedback
function Wise:FlashGroup(groupName)
    local f = Wise.frames[groupName]
    if not f then return end

    if not f.flashAnim then
        f.flashAnim = f:CreateAnimationGroup()
        f.flashAnim:SetLooping("NONE")

        -- Flash Out (Fade to 50%)
        local a1 = f.flashAnim:CreateAnimation("Alpha")
        a1:SetOrder(1)
        a1:SetDuration(0.2)
        a1:SetFromAlpha(1)
        a1:SetToAlpha(0.3)
        a1:SetSmoothing("OUT")

        -- Flash In (Back to 100%)
        local a2 = f.flashAnim:CreateAnimation("Alpha")
        a2:SetOrder(2)
        a2:SetDuration(0.3)
        a2:SetFromAlpha(0.3)
        a2:SetToAlpha(1)
        a2:SetSmoothing("IN")
    end

    if f:IsShown() then
        f.flashAnim:Stop()
        f.flashAnim:Play()
    end

    -- Also flash the visual display if active (combat + mouse mode)
    if f.visualDisplay and f.visualDisplay:IsShown() then
         if not f.visualDisplay.flashAnim then
            f.visualDisplay.flashAnim = f.visualDisplay:CreateAnimationGroup()
            -- Mirror animation
            local a1 = f.visualDisplay.flashAnim:CreateAnimation("Alpha")
            a1:SetOrder(1); a1:SetDuration(0.2); a1:SetFromAlpha(1); a1:SetToAlpha(0.3); a1:SetSmoothing("OUT")
            local a2 = f.visualDisplay.flashAnim:CreateAnimation("Alpha")
            a2:SetOrder(2); a2:SetDuration(0.3); a2:SetFromAlpha(0.3); a2:SetToAlpha(1); a2:SetSmoothing("IN")
         end
         f.visualDisplay.flashAnim:Stop()
         f.visualDisplay.flashAnim:Play()
    end
end

-- Pending Update Handler
local pendingFrame = CreateFrame("Frame")
pendingFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
pendingFrame:SetScript("OnEvent", function(self, event)
    if Wise.pendingUpdates then
        local updates = Wise.pendingUpdates
        Wise.pendingUpdates = nil -- Clear first to avoid loops if errors occur
        

        for name, _ in pairs(updates) do
            Wise:UpdateGroupDisplay(name)
        end
    end
end)



function Wise:ResetSequences()
    if InCombatLockdown() or not Wise.buttonMeta then return end
    
    for btn, meta in pairs(Wise.buttonMeta) do
        if meta.conflictStrategy == "sequence" and meta.resetOnCombat then
            btn:SetAttribute("isa_seq", 1)
            -- Trigger an immediate evaluation to update the icon
            if meta.states and #meta.states > 1 then
                local chosen = Wise:EvaluateSlotConditions(meta.states, "sequence", btn)
                if chosen then
                    meta.activeState = chosen
                    local state = meta.states[chosen]
                    if state then
                        btn.icon:SetTexture(Wise:GetActionIcon(state.type, state.value, state))
                        btn.actionType = state.type
                        btn.actionValue = state.value
                        btn.actionData = state
                        
                        local sType, sAttr, sValue = Wise:GetSecureAttributes(state, state.conditions)
                        btn:SetAttribute("type", nil)
                        btn:SetAttribute("spell", nil)
                        btn:SetAttribute("item", nil)
                        btn:SetAttribute("macro", nil)
                        btn:SetAttribute("macrotext", nil)
                        btn:SetAttribute("clickbutton", nil)
                        btn:SetAttribute("type", sType)
                        btn:SetAttribute(sAttr, sValue)
                    end
                end
            end
        end
    end
end
