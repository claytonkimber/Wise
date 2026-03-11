-- Dispatcher.lua: Secure Action Button Dispatcher for Mouse Input
-- Intercepts Middle Click (Button3), Button4, Button5 etc. using
-- the OPie-style "Dispatcher Pattern" — a dedicated transparent overlay
-- with SecureActionButtonTemplate that handles clicks without taint.
local addonName, Wise = ...

local CreateFrame = CreateFrame
local UIParent = UIParent
local InCombatLockdown = InCombatLockdown
local SecureHandlerWrapScript = SecureHandlerWrapScript
local RegisterStateDriver = RegisterStateDriver
local UnregisterStateDriver = UnregisterStateDriver
local SetOverrideBindingClick = SetOverrideBindingClick
local ClearOverrideBindings = ClearOverrideBindings
local pairs = pairs
local tostring = tostring

-- ─── Module Table ──────────────────────────────────────────────────
local Dispatcher = {}
Wise.Dispatcher = Dispatcher

-- Registered action callbacks (insecure side, keyed by actionID)
Dispatcher.actions = {}
-- Registered bindings: { ["BUTTON3"] = "some_action", ... }
Dispatcher.bindings = {}

-- ─── 1. Base Dispatcher Frame ──────────────────────────────────────
-- A SecureActionButton that sits at the bottom of the frame stack.
-- It never shows visually but receives forwarded clicks via override bindings.
local dispatcherBtn = CreateFrame(
    "Button",
    "WiseDispatcher",
    UIParent,
    "SecureActionButtonTemplate, SecureHandlerAttributeTemplate"
)
dispatcherBtn:SetSize(1, 1)
dispatcherBtn:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
dispatcherBtn:RegisterForClicks("AnyUp", "AnyDown")
dispatcherBtn:EnableMouse(true)
dispatcherBtn:EnableMouseWheel(true)
-- Keep the frame from blocking input — it's invisible and tiny.
dispatcherBtn:SetFrameStrata("LOW")

Dispatcher.frame = dispatcherBtn

-- ─── 2. Input Mapping (secure side) ───────────────────────────────
-- Maps the internal WoW button names that arrive in OnClick to
-- canonical key strings used in override bindings.
local BUTTON_MAP_SNIPPET = [[
    local _bmap = newtable()
    _bmap["LeftButton"]   = "BUTTON1"
    _bmap["RightButton"]  = "BUTTON2"
    _bmap["MiddleButton"] = "BUTTON3"
    _bmap["Button4"]      = "BUTTON4"
    _bmap["Button5"]      = "BUTTON5"
    _bmap["Button6"]      = "BUTTON6"
    _bmap["Button7"]      = "BUTTON7"
    _bmap["Button8"]      = "BUTTON8"
]]

-- ─── 3. PreClick Secure Snippet ───────────────────────────────────
-- Runs in the restricted secure environment BEFORE the action fires.
-- Reads the pressed button, maps it to a canonical key, then looks up
-- the registered action attributes (type/spell/item/macrotext) stored
-- as "binding-<KEY>-type", "binding-<KEY>-spell", etc.
local preClickSnippet = BUTTON_MAP_SNIPPET .. [[
    -- Map the raw button name to canonical key
    local rawBtn = button or "LeftButton"
    local key = _bmap[rawBtn] or rawBtn

    -- Build modifier prefix from tracked attributes (set by insecure OnUpdate)
    local mods = ""
    if self:GetAttribute("_dispatch_shift") then mods = mods .. "SHIFT-" end
    if self:GetAttribute("_dispatch_ctrl") then mods = mods .. "CTRL-" end
    if self:GetAttribute("_dispatch_alt") then mods = mods .. "ALT-" end

    local fullKey = mods .. key

    if down then
        -- On key-down: look up the bound action for this button
        -- Try modifier+key first, then plain key as fallback
        local lookupKey = fullKey
        local actionType = self:GetAttribute("bind-" .. fullKey .. "-type")
        if not actionType then
            lookupKey = key
            actionType = self:GetAttribute("bind-" .. key .. "-type")
        end

        if actionType then
            self:SetAttribute("type", actionType)
            self:SetAttribute("spell", self:GetAttribute("bind-" .. lookupKey .. "-spell"))
            self:SetAttribute("item", self:GetAttribute("bind-" .. lookupKey .. "-item"))
            self:SetAttribute("macrotext", self:GetAttribute("bind-" .. lookupKey .. "-macrotext"))
            self:SetAttribute("_dispatch_active", lookupKey)
        else
            -- No action registered for this button — suppress
            self:SetAttribute("type", nil)
            self:SetAttribute("_dispatch_active", nil)
        end
    else
        -- On key-up: clear to prevent double-triggers
        self:SetAttribute("type", nil)
        self:SetAttribute("spell", nil)
        self:SetAttribute("item", nil)
        self:SetAttribute("macrotext", nil)
        self:SetAttribute("_dispatch_active", nil)
    end
]]

-- ─── 4. PostClick Secure Snippet ──────────────────────────────────
-- Runs AFTER the action fires. Resets all transient attributes
-- so the button is clean for the next press.
local postClickSnippet = [[
    self:SetAttribute("type", nil)
    self:SetAttribute("spell", nil)
    self:SetAttribute("item", nil)
    self:SetAttribute("macrotext", nil)
    self:SetAttribute("_dispatch_active", nil)
]]

-- Wire up PreClick and PostClick
SecureHandlerWrapScript(dispatcherBtn, "PreClick", dispatcherBtn, preClickSnippet)
SecureHandlerWrapScript(dispatcherBtn, "PostClick", dispatcherBtn, postClickSnippet)

-- ─── 5. Binding Proxy (Combat State Driver) ──────────────────────
-- A lightweight secure frame that tracks combat state.
-- On entering combat, existing bindings are locked in.
-- On leaving combat, bindings can be refreshed/cleared.
local bindProxy = CreateFrame("Frame", "WiseDispatcherBindProxy", UIParent, "SecureHandlerStateTemplate")
bindProxy:SetSize(1, 1)
bindProxy:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)

Dispatcher.bindProxy = bindProxy

-- State driver: "combat" → "1" in combat, "0" out of combat
RegisterStateDriver(bindProxy, "combat", "[combat] 1; 0")

-- When combat state changes, update a flag attribute
bindProxy:SetAttribute("_onstate-combat", [[
    local inCombat = (newstate == "1")
    self:SetAttribute("inCombat", inCombat)
    -- Bindings can only be modified out of combat (WoW restriction),
    -- so we just track state here. The insecure callback handles refresh.
]])

-- Insecure callback: refresh bindings when leaving combat
bindProxy:SetScript("OnAttributeChanged", function(self, key, value)
    if key == "state-combat" and value == "0" then
        -- Leaving combat — refresh all dispatcher bindings
        Dispatcher:ApplyBindings()
    end
end)

-- ─── 6. Modifier Tracking (Insecure Side) ────────────────────────
-- Track modifier state for the secure snippet to read.
-- Updated via OnUpdate on the dispatcher frame for simplicity.
local modTracker = CreateFrame("Frame")
modTracker:SetScript("OnUpdate", function()
    if InCombatLockdown() then return end
    dispatcherBtn:SetAttribute("_dispatch_shift", IsShiftKeyDown() and true or nil)
    dispatcherBtn:SetAttribute("_dispatch_ctrl", IsControlKeyDown() and true or nil)
    dispatcherBtn:SetAttribute("_dispatch_alt", IsAltKeyDown() and true or nil)
end)

-- ─── 7. Public API ────────────────────────────────────────────────

--- Register an action to a specific button key.
-- @param key string: Canonical key string (e.g. "BUTTON3", "SHIFT-BUTTON4")
-- @param actionType string: "spell", "item", "macro", "macrotext", etc.
-- @param actionValue string: The spell name, item name, or macro text.
-- @param callback function (optional): Insecure callback fired on use.
function Dispatcher:RegisterAction(key, actionType, actionValue, callback)
    if not key or not actionType then return end

    -- Store for later re-application
    self.bindings[key] = {
        type = actionType,
        value = actionValue,
        callback = callback,
    }

    -- Apply immediately if possible
    if not InCombatLockdown() then
        self:ApplyBinding(key)
    end
end

--- Unregister an action from a specific button key.
-- @param key string: Canonical key string (e.g. "BUTTON3")
function Dispatcher:UnregisterAction(key)
    if not key then return end
    self.bindings[key] = nil

    if not InCombatLockdown() then
        -- Clear the secure attributes
        dispatcherBtn:SetAttribute("bind-" .. key .. "-type", nil)
        dispatcherBtn:SetAttribute("bind-" .. key .. "-spell", nil)
        dispatcherBtn:SetAttribute("bind-" .. key .. "-item", nil)
        dispatcherBtn:SetAttribute("bind-" .. key .. "-macrotext", nil)
        -- Re-apply all bindings (clears the override binding for this key)
        self:ApplyBindings()
    end
end

--- Apply a single binding to the secure frame.
-- @param key string: The canonical key (e.g. "BUTTON3")
function Dispatcher:ApplyBinding(key)
    local info = self.bindings[key]
    if not info then return end
    if InCombatLockdown() then return end

    local secureType = info.type
    local secureAttr = nil
    local secureValue = info.value

    -- Map action types to the correct secure attribute
    if secureType == "spell" then
        secureAttr = "spell"
    elseif secureType == "item" then
        secureAttr = "item"
    elseif secureType == "macro" or secureType == "macrotext" then
        secureType = "macro"
        secureAttr = "macrotext"
    end

    dispatcherBtn:SetAttribute("bind-" .. key .. "-type", secureType)
    if secureAttr then
        dispatcherBtn:SetAttribute("bind-" .. key .. "-" .. secureAttr, secureValue)
    end

    -- Set the override binding so WoW routes this key to our dispatcher
    SetOverrideBindingClick(dispatcherBtn, false, key, "WiseDispatcher")
end

--- Apply all registered bindings. Called on init and when leaving combat.
function Dispatcher:ApplyBindings()
    if InCombatLockdown() then return end

    -- Clear all existing override bindings on our proxy
    ClearOverrideBindings(dispatcherBtn)

    -- Re-apply each registered binding
    for key, _ in pairs(self.bindings) do
        self:ApplyBinding(key)
    end
end

--- Clear all dispatcher bindings.
function Dispatcher:ClearAll()
    if InCombatLockdown() then return end

    -- Clear secure attributes before wiping the table
    for key, _ in pairs(self.bindings) do
        dispatcherBtn:SetAttribute("bind-" .. key .. "-type", nil)
        dispatcherBtn:SetAttribute("bind-" .. key .. "-spell", nil)
        dispatcherBtn:SetAttribute("bind-" .. key .. "-item", nil)
        dispatcherBtn:SetAttribute("bind-" .. key .. "-macrotext", nil)
    end

    self.bindings = {}
    ClearOverrideBindings(dispatcherBtn)
end

-- ─── 8. Hardware Button Mapping Helper ────────────────────────────
-- Convenience table mapping human-readable names to canonical keys.
Dispatcher.HardwareButtons = {
    ["MiddleClick"]  = "BUTTON3",
    ["Mouse4"]       = "BUTTON4",
    ["Mouse5"]       = "BUTTON5",
    ["Mouse6"]       = "BUTTON6",
    ["Mouse7"]       = "BUTTON7",
    ["Mouse8"]       = "BUTTON8",
    ["WheelUp"]      = "MOUSEWHEELUP",
    ["WheelDown"]    = "MOUSEWHEELDOWN",
}

--- Register an action using a human-readable button name.
-- @param buttonName string: e.g. "MiddleClick", "Mouse4", "Mouse5"
-- @param actionType string: "spell", "item", "macrotext"
-- @param actionValue string: The spell/item/macro text
-- @param modifier string (optional): "SHIFT", "CTRL", "ALT", or combo "SHIFT-CTRL"
function Dispatcher:BindHardwareButton(buttonName, actionType, actionValue, modifier)
    local key = self.HardwareButtons[buttonName]
    if not key then
        -- Try using the buttonName directly as a key (e.g. "BUTTON3")
        key = buttonName
    end

    if modifier and modifier ~= "" then
        key = modifier .. "-" .. key
    end

    self:RegisterAction(key, actionType, actionValue)
end

--- Unregister a hardware button binding.
-- @param buttonName string: e.g. "MiddleClick", "Mouse4"
-- @param modifier string (optional): "SHIFT", "CTRL", "ALT"
function Dispatcher:UnbindHardwareButton(buttonName, modifier)
    local key = self.HardwareButtons[buttonName]
    if not key then
        key = buttonName
    end

    if modifier and modifier ~= "" then
        key = modifier .. "-" .. key
    end

    self:UnregisterAction(key)
end

-- ─── 9. Insecure Callback Relay ──────────────────────────────────
-- Watch for attribute changes that signal an action was dispatched,
-- then fire the insecure callback if one was registered.
dispatcherBtn:SetScript("OnAttributeChanged", function(self, key, value)
    if key == "_dispatch_active" and value then
        local info = Dispatcher.bindings[value]
        if info and info.callback then
            info.callback(value, info.type, info.value)
        end
    end
end)
