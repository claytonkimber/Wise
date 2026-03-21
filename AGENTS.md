# Wise Addon: Technical Constitution

## Project Goal
A high-performance World of Warcraft (Retail 11.0+) using pure LUA. Only use libraries if they provide a significant improvement in performance or usability.

## Tech Stack
- Language: Lua (WoW-variant)
- Framework:
- IDE: Antigravity 2026
- Agent Trio: Claude Code (Logic), Jules (Background Ops), Gemini (Arch)

## Taint Avoidance (MANDATORY)

WoW's taint system tracks which code "touched" a value or frame. If addon (tainted) code modifies a protected value, the client blocks the action and throws an "action blocked" error. Every rule below exists to prevent taint from propagating into the secure execution path. **These rules are non-negotiable — violating any of them can silently break combat functionality.**

### The Two Worlds: Secure vs Insecure

All addon code executes in one of two contexts. Never mix them.

| | Secure (Restricted) | Insecure (Normal Lua) |
|---|---|---|
| **Runs in** | `SecureHandlerWrapScript` snippets, `_onstate-*`, `_onshow`, `_onhide` attribute handlers | Regular scripts (`OnClick`, `OnUpdate`, `OnShow`, `OnHide`), tickers, event handlers |
| **Can do** | `self:GetAttribute()`, `SetAttribute()`, `GetFrameRef()`, `SetBindingClick()`, `ClearBindings()`, `SecureCmdOptionParse()`, `newtable()`, `tinsert()`, `math.*`, `string.*` (subset), `owner:*` | Full Lua standard library, all WoW API calls, frame creation, texture manipulation |
| **Cannot do** | Call `function` keyword, access global addon tables, call WoW C API, create frames | Modify secure frame attributes during combat, show/hide secure frames during combat |
| **Data bridge** | Read/write via `GetAttribute()`/`SetAttribute()` on the frame itself | Read via `GetAttribute()` anytime; write via `SetAttribute()` only out of combat |

### Rule 1: Guard Every Secure Frame Mutation with `InCombatLockdown()`

Any code that calls `SetAttribute()`, `Show()`, `Hide()`, `SetParent()`, `SetPoint()` (directly on a secure frame), `RegisterStateDriver()`, `UnregisterStateDriver()`, `SetOverrideBindingClick()`, or `ClearOverrideBindings()` on a **secure frame** MUST be wrapped:

```lua
if InCombatLockdown() then return end
frame:SetAttribute("type", "spell")
```

**No exceptions.** If a code path can theoretically reach a secure mutation, it must be gated. This includes callbacks, event handlers, and timer functions that may fire during combat.

### Rule 2: Never Use the `function` Keyword in Restricted Snippets

The WoW restricted execution environment forbids the `function` keyword entirely. To reuse logic across secure snippets, use Lua string concatenation to inline a code block:

```lua
local SHARED_BLOCK = [[
    do
        local count = self:GetAttribute("count") or 0
        -- shared logic here
    end
]]

SecureHandlerWrapScript(btn, "PreClick", btn, [[
    ]] .. SHARED_BLOCK .. [[
    -- additional PreClick logic
]])
```

Wrap reusable inline blocks in `do ... end` to avoid variable name collisions.

### Rule 3: Communicate Between Worlds via Attributes Only

Secure snippets cannot access addon tables, upvalues, or globals. The ONLY data bridge is frame attributes:

```lua
-- Insecure side (out of combat): write data as attributes
btn:SetAttribute("isa_spell_1", "Fireball")
btn:SetAttribute("isa_cond_1", "[harm,nodead]")
btn:SetAttribute("isa_count", 1)

-- Secure side (PreClick snippet): read and act on attributes
local spell = self:GetAttribute("isa_spell_1")
local cond = self:GetAttribute("isa_cond_1")
```

**Never** store complex Lua tables as attributes. Flatten data into indexed key patterns (e.g., `isa_type_1`, `isa_type_2`, ..., `isa_count`).

### Rule 4: Use Frame References, Not `/click` Commands

To toggle or interact with another secure frame from a secure snippet, use `SetFrameRef()` + `GetFrameRef()`:

```lua
-- Insecure setup (out of combat):
parentBtn:SetFrameRef("child_group", childFrame)

-- Secure snippet:
local child = self:GetFrameRef("child_group")
if child then
    child:SetAttribute("state-manual", "show")
end
```

**Never** use `/click FrameName` in macrotext to trigger other secure frames — this is an unreliable taint vector.

### Rule 5: Proxy Anchor Pattern for Combat-Safe Positioning

Secure frames cannot be repositioned during combat. Use an insecure proxy anchor:

```lua
-- Creation (one-time):
local anchor = CreateFrame("Frame", nil, UIParent)  -- insecure, freely movable
local secureFrame = CreateFrame("Frame", name, UIParent, "SecureHandlerStateTemplate")
secureFrame:SetPoint("CENTER", anchor, "CENTER")     -- secure frame follows anchor

-- Runtime (even in combat):
anchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)  -- moves the insecure anchor
-- secureFrame follows automatically without any secure mutation
```

### Rule 6: Separate State Drivers from Custom Conditions

`RegisterStateDriver()` accepts only **native WoW macro conditionals** (`[combat]`, `[spec:1]`, `[mounted]`, etc.). Custom addon conditions (bank open, undermouse proximity, addon-specific states) must be evaluated in insecure tickers and pushed to the secure frame via `SetAttribute()`:

```lua
-- CORRECT: Native conditionals in state driver
RegisterStateDriver(frame, "game", "[combat] show; hide")

-- CORRECT: Custom conditions in insecure ticker
C_Timer.NewTicker(0.5, function()
    if InCombatLockdown() then return end
    local state = IsBankOpen() and "show" or "hide"
    frame:SetAttribute("state-custom", state)
end)

-- WRONG: Custom function in state driver string (will taint)
-- RegisterStateDriver(frame, "game", "[combat] show; " .. myAddonCheck())
```

### Rule 7: Reset Attributes Before Reassignment

When changing a button's action, always clear ALL action attributes before setting the new ones. Stale attributes from a previous action type can cause the wrong action to fire:

```lua
btn:SetAttribute("type", nil)
btn:SetAttribute("spell", nil)
btn:SetAttribute("item", nil)
btn:SetAttribute("macro", nil)
btn:SetAttribute("macrotext", nil)

btn:SetAttribute("type", newType)
btn:SetAttribute(newAttr, newValue)
```

### Rule 8: Never Hook, Replace, or Read Protected Blizzard Frames

- **No `hooksecurefunc()`** on Blizzard secure functions unless absolutely necessary and fully understood.
- **No reading** of protected frame properties (e.g., iterating `ActionBarFrame` children) — this spreads taint to your addon's call stack.
- **No `getglobal()`** on Blizzard frame names during combat — use `_G[name]` only out of combat and cache the reference.
- **No overwriting** Blizzard globals or metatable methods.

### Rule 9: Use `SecureCmdOptionParse()` for Condition Evaluation in Restricted Context

Inside secure snippets, `SecureCmdOptionParse()` is the only way to evaluate WoW macro conditionals:

```lua
-- Inside a secure snippet:
local cond = self:GetAttribute("isa_cond_1")
if cond then
    local result = SecureCmdOptionParse(cond)
    if result and result ~= "" then
        -- condition matched
    end
end
```

This function is available in the restricted environment and evaluates standard WoW conditionals (`[combat]`, `[spec:1]`, `[mod:shift]`, etc.) without taint.

### Rule 10: Insecure UI Updates Are Always Safe

The following operations are always safe in insecure context, even referencing secure frames:

- `btn:GetAttribute("type")` — reading attributes never taints
- `SetTexture()`, `SetText()`, `SetVertexColor()` — texture/font updates on any frame
- `SetCooldown()`, `SetDesaturated()` — visual state changes
- `GetCursorInfo()` — reading drag-and-drop state
- `C_Spell.GetSpellInfo()`, `C_Item.GetItemInfo()` — API data lookups
- `CreateFrame()` for non-secure frames (UI chrome, options panels, tooltips)

Use insecure tickers (0.2s–0.5s) to update icons, cooldowns, usability, and visual state on secure buttons without risk.

### Rule 11: Bindings Must Use Secure Channels

Override bindings (`SetOverrideBindingClick`) must be set from insecure code out of combat, OR from secure `_onshow`/`_onhide` handlers:

```lua
-- Secure _onshow: safe to set bindings
f:SetAttribute("_onshow", [[
    local key = self:GetAttribute("keybind_1")
    local btnName = self:GetAttribute("btn_name_1")
    if key and btnName then
        self:SetBindingClick(true, key, btnName)
    end
]])

-- Secure _onhide: always clean up
f:SetAttribute("_onhide", [[
    self:ClearBindings()
]])
```

**Never** set override bindings from an insecure `OnShow` script during combat — use the secure attribute handler instead.

### Quick Reference: Taint Danger Checklist

Before merging any code, verify:

- [ ] Every `SetAttribute()` on a secure frame is gated by `if InCombatLockdown() then return end`
- [ ] No `function` keyword appears in any string passed to `SecureHandlerWrapScript` or set as `_onstate-*`/`_onshow`/`_onhide` attribute
- [ ] No secure snippet references global addon tables (`Wise`, `WiseDB`, etc.)
- [ ] No `/click FrameName` used for inter-frame communication (use `SetFrameRef`/`GetFrameRef` instead)
- [ ] All action attributes cleared before reassignment (type, spell, item, macro, macrotext)
- [ ] Custom conditions evaluated in insecure tickers, not inside `RegisterStateDriver()` strings
- [ ] No `hooksecurefunc()` on Blizzard protected functions
- [ ] No direct `SetPoint()`/`Show()`/`Hide()` on secure frames without combat check
- [ ] Override bindings set only from secure handlers or out-of-combat insecure code
- [ ] Inline shared logic uses string concatenation + `do...end` blocks, not `function` definitions

## Coding Standards
- **Locals First:** Always use `local` variables for functions and data to avoid global namespace pollution.
- **Naming:** Use CamelCase for global table `Wise` and functions; use camelCase for local variables.
- **Frames:** Prefer modern `Mixins` over legacy XML templates when possible.
- **Table Management:** When clearing tables, use the built-in `wipe(table)` function to safely and efficiently clear the contents without creating memory garbage collection overhead.
- **Code Organization:** To prevent bloating `Wise.lua`, large default configurations and standard loadout bars (such as the Demo bar) should be created as separate files in the `modules/` directory and dynamically hooked into `Wise.lua` for initialization and resets.
- **Optimization:** Optimize performance where possible, e.g., pre-parsing condition strings or using O(1) lookups in `modules/States.lua`.

## Verification Workflow
- **WoW API:** Assume Retail 11.0+ (The War Within/Midnight) API names.
- **Automated Tests:** Do not write custom automated tests for the addon, as executing and passing them requires the actual World of Warcraft game client to be running.
- **tests.xml Workflow:** Every bug fix, feature, or test must add a debugging/testing procedure to `tests.xml`. Before every merge, review `tests.xml` to check if existing tests are still needed, ensuring the file stays clean and unpolluted.
- **Syntax Validation:** The development/shell environment for this repository lacks a native Lua interpreter by default. To perform syntax validation for Lua files, install luajit (`sudo apt-get install -y luajit`) and run `luajit -bl <file>`.
- **Unit Testing:** Unit tests that mock core APIs via monkey-patching should be excluded from `Wise.toc` and should always restore the original functions immediately after execution to prevent side effects in the production environment.

## Textures and Media
- **TGA Format:** Custom `.tga` mask textures for WoW must be saved as uncompressed 32-bit TGA files with an 8-bit alpha channel (RGBA), where the mask shape is opaque white and the background is transparent black.
- **Media Path:** Custom textures (like alpha masks for button shapes) are stored in the `Media/` directory as `.tga` files and referenced in code as `Interface\AddOns\Wise\Media\<FileName>.tga`.
- **Texture Wrapping:** Custom alpha mask textures used with `CreateMaskTexture()` require specific texture wrapping mode arguments `"CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE"` in `SetTexture()` to apply correctly without edge bleeding.
- **Dynamic Masking:** When dynamically applying mask textures to UI elements, ensure `SetTexture(...)` is called outside of the initial `CreateMaskTexture()` creation block so that texture changes update visually at runtime.
- **Generation:** The development environment supports generating custom `.tga` media files using Python's `Pillow` library. Install via `python3 -m pip install pillow --break-system-packages` if missing.

## UI Specifics
- **Solid Backgrounds:** When creating solid backgrounds for UI frames in WoW using `BackdropTemplate`, use `Interface\Buttons\WHITE8X8` combined with `SetBackdropColor(r, g, b, a)` for a fully opaque, customizable background.
- **Secure Custom Actions:** To execute arbitrary Lua code securely for custom actions in `core/GUI.lua`, they are implemented as macros by setting `secureType = "macro"`, `secureAttr = "macrotext"`, and using a `/run` command in `secureValue`.
- **Edit Mode Positioning:** When dynamically changing a frame's anchor point during edit mode in `modules/editmode.lua`, the x/y offsets must be recalculated using `GetEffectiveScale()` relative to `UIParent`. Position calculations must use the proxy anchor's center (`f.Anchor:GetCenter()`) rather than the frame's geometric center.
- **Main Options Frame:** `WiseOptionsFrame` is explicitly excluded from `UISpecialFrames` to ensure it remains open when other standard WoW panels are opened. Elements reacting to its visibility should utilize `HookScript("OnShow")` and `HookScript("OnHide")` on the frame directly.

## Addon Specifics
- **Conditionals Validation:** `Wise:ValidateVisibilityCondition` in core/Conditionals.lua enforces security by disallowing newline (\n) and carriage return (\r) characters to prevent macro command injection.
- **Talent Visibility:** Talent visibility requirements (stored in `action.talentRequirements`) are displayed as a comma-separated list of resolved spell names using `C_Spell.GetSpellInfo(spellID)`.
- **Interface Conditionals:** Interface conditionals (e.g., `[wise:groupName]`) and Addon Loading Magic conditionals (e.g., `[aml:slotname]`) are dynamically generated and evaluated in `core/Conditionals.lua`.
- **Specializations:** Action visibility based on specializations uses the 'spec' category. The `action.specRequirements` field stores a table of required spec IDs.
- **Nesting Cycles:** `Wise:WouldCreateNestingCycle` in `modules/Nesting.lua` proactively prevents circular interface nesting by traversing the hierarchy via `Wise:GetParentInfo`.
