# Wise Addon: Technical Constitution

## Project Goal
A high-performance World of Warcraft (Retail 11.0+) using pure LUA. Only use libraries if they provide a significant improvement in performance or usability.

## Tech Stack
- Language: Lua (WoW-variant)
- Framework:
- IDE: Antigravity 2026
- Agent Trio: Claude Code (Logic), Jules (Background Ops), Gemini (Arch)
- Tooling: Mechanic MCP (addon lifecycle automation); CodeSight MCP (codebase structure / blast-radius analysis)

### Mechanic Usage Policy (token cost)

Mechanic tool calls return very large outputs and burn context tokens fast. **Use Mechanic sparingly:**

- Prefer local/built-in alternatives first: Read/Grep/Glob for navigation, `luacheck`/`stylua` via the shell for lint/format, and your own knowledge of the WoW API before reaching for `api-search`/`api-info`.
- Reserve Mechanic for what only it can do: in-game execution (`lua-queue`/`lua-results`/`addon-output`), sandbox runs with WoW API stubs, and the security/deprecation scanners before a release.
- Run the heavy scanners (`addon-security`, `addon-deprecations`, `addon-deadcode`, `addon-complexity`) once per change-set as a pre-merge gate, not after every edit.
- Never call Mechanic tools speculatively or "just to check" — each call should answer a specific question you cannot answer locally.

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

These insecure updates are safe to run from event handlers, `OnShow`, or tickers. **Prefer event-driven updates over polling tickers** (see Rule 12) — these operations are safe *when* they run, but running them on a fast unconditional ticker is the dominant avoidable CPU cost.

### Rule 12: Drive Updates From Events, Not Polling Tickers (Performance)

Insecure UI updates are safe (Rule 10), but a `C_Timer.NewTicker` that re-runs a per-button refresh loop several times per second — forever, whether or not anything changed — is the single largest source of avoidable idle CPU in this addon. A profiling pass measured one such 0.2s per-group ticker at ~22 ms/sec, ~80% of Wise's total idle cost.

**The rules:**

1. **Default to events.** Dynamic icon/cooldown/state refreshes are driven by a central event frame (`DynamicRefreshDriver` in `core/GUI.lua`). A group registers its refresh closure on `f._dynamicRefresh` + `Wise._dynamicGroups[f]`; the driver runs it only when a relevant event fires (`ACTIONBAR_*`, `UPDATE_*_ACTIONBAR`, `UPDATE_EXTRA_ACTIONBAR`, `SPELL_UPDATE_*`, `UPDATE_SHAPESHIFT_FORM`, `PLAYER_SPECIALIZATION_CHANGED`, `SPELLS_CHANGED`, `PLAYER_TARGET_CHANGED`, `UPDATE_MOUSEOVER_UNIT`, vehicle events, `BAG_UPDATE_COOLDOWN`). Add new dynamic state to the driver's event list, don't add a ticker.

2. **Coalesce event bursts.** Many events fire together (stance + spec + bar swap on a single action). Funnel them through a one-frame-deferred `C_Timer.After(0)` flag so a burst costs one refresh pass, not N.

3. **Skip in combat, flush on exit.** Refreshes that touch secure attributes no-op in combat anyway — don't even schedule them while `InCombatLockdown()`; register `PLAYER_REGEN_ENABLED` to flush a single refresh on combat exit.

4. **Poll only the genuinely event-less.** The only inputs with no event are modifier keys (`[mod:shift]`). Flag just those groups (`f._needsPoll`) and serve them from one shared slow ticker (0.3s), not a ticker per group. Groups without modifier conditions poll zero times.

5. **Gate per-frame `OnUpdate` on visibility.** A mouse-follow / cursor-tracking `OnUpdate` must `if not frame:IsShown() then return end` — `OnShow` handles positioning on appear, so tracking while hidden is pure waste.

6. **Zero-allocation hot loops.** In any per-frame or high-frequency loop, hoist closures out of the loop (reuse one closure with scratch upvalues rather than allocating per iteration); only call `SetTexture`/`SetAttribute`/etc. when the value actually changed (cache the last value and compare). The taint-safe `pcall(closure)` pattern for secret-number arithmetic must reuse a single hoisted closure, never `pcall(function() ... end)` inside a loop.

**Diagnostics:** `/wise cpu start` → wait → `/wise cpu` measures a time-boxed delta of Wise-owned frames (tagged via `_wiseProfileName`), splitting cost into "in frames" vs "elsewhere (tickers/handlers)". Use it before/after any perf change.

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

### Automated Security Analysis

Use `mcp__mechanic__addon-security` to detect combat lockdown violations, taint risks, and unsafe eval patterns. Run it once as a pre-merge gate when a change-set touched secure frame code or visibility logic — not after every edit (see Mechanic Usage Policy). This complements the manual checklist below.

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
- **Optimization:** Optimize performance where possible, e.g., pre-parsing condition strings or using O(1) lookups in `modules/States.lua`. For per-frame/recurring work, follow Rule 12: event-driven over polling, coalesce bursts, gate `OnUpdate` on visibility, and keep hot loops zero-allocation.
- **Formatting:** Use `mcp__mechanic__addon-format` (StyLua) to auto-format code to match project style guidelines.
- **Deprecations:** Use `mcp__mechanic__addon-deprecations` to scan for deprecated API calls that need updating for current and upcoming WoW versions.
- **Dead Code:** Use `mcp__mechanic__addon-deadcode` to detect unused functions, orphaned files, and dead exports.
- **Complexity:** Use `mcp__mechanic__addon-complexity` to detect deep nesting, long functions, and magic numbers.

## Codebase Navigation (CodeSight MCP)

CodeSight is a local, patched MCP that maps Wise's structure. Because WoW addons share one global `Wise.*` table instead of importing by path, CodeSight has a **Tier 2 patch** that builds a namespace symbol graph (which file reads a `Wise.Foo`/`Wise:Foo` that another file defines). Use it to orient before edits — it is faster and cheaper than grepping the whole tree.

- **Before changing a foundational file**, run `mcp__codesight__codesight_get_blast_radius` (file path) to see which files depend on it. This answers "what could this change break." Verified examples: editing `core/Polyfill.lua` affects ~26 files, `core/Text.lua` ~25; a leaf or internally-wired file like `core/Dispatcher.lua` correctly returns 0. A `0` result means no *symbol* dependents — trust it, don't grep again "just in case."
- **To find the load-bearing files**, use `mcp__codesight__codesight_get_hot_files` (most depended-upon: `Wise.lua`, `core/Polyfill`, `core/Text`, `core/Bindings`, `core/GUI`, `modules/States`).
- **For a one-shot overview**, use `mcp__codesight__codesight_get_summary`.
- **After editing addon `.lua`/`.toc` files**, the MCP serves a cached scan — call `mcp__codesight__codesight_refresh` so blast-radius/hot-files reflect your changes.
- **Scope:** CodeSight answers *structural* questions (load order, who-depends-on-whom). For *API-level* WoW analysis (taint, deprecations, API signatures) use the Mechanic tools below — the two are complementary, not interchangeable.

### Maintaining CodeSight (MANDATORY when editing its source)

CodeSight's WoW Lua support lives entirely in a **patch**, not upstream. It is versioned in git but **excluded from CurseForge packaging** (listed in `.pkgmeta` `ignore:`), so never add CodeSight files to `Wise.toc` or expect them in the shipped `.zip`.

- The patch is `patches/codesight+1.14.0.patch`; it modifies only `node_modules/codesight/dist/scanner.js` (Lua/`.toc` detection) and `dist/detectors/graph.js` (the symbol graph). `node_modules/` and `.codesight/` are gitignored and regenerate via `npm install`, which re-applies the patch through the `postinstall` hook.
- **If you edit anything under `node_modules/codesight/dist/`, you MUST regenerate the patch** or the change is lost on the next `npm install`: with node on PATH (`export PATH="/c/Program Files/nodejs:$PATH"` in git-bash, since `patch-package` shells out to bare `node`), run `npx patch-package codesight`, then commit the updated `patches/codesight+1.14.0.patch`.
- The hub threshold (symbols defined in ≥4 files are skipped as shared mutable state) and namespace-token detection live in `graph.js`; tune there if the symbol graph over- or under-connects after the addon's structure changes.

## Verification Workflow
- **WoW API:** Assume Retail 11.0+ (The War Within/Midnight) API names. Only when genuinely unsure of a signature, use `mcp__mechanic__api-search` / `mcp__mechanic__api-info` for a specific API — avoid `mcp__mechanic__api-list` namespace browsing, which returns huge outputs (see Mechanic Usage Policy).
- **Automated Tests:** Do not write custom automated tests for the addon, as executing and passing them requires the actual World of Warcraft game client to be running.
- **tests.xml Workflow:** Every bug fix, feature, or test must add a debugging/testing procedure to `tests.xml`. Before every merge, review `tests.xml` to check if existing tests are still needed, ensuring the file stays clean and unpolluted.
- **Syntax Validation:** Use `mcp__mechanic__addon-lint` (Luacheck) to validate Lua syntax and catch code quality issues. Use `mcp__mechanic__addon-validate` to validate the `.toc` file for common issues before release.
- **Unit Testing:** Unit tests that mock core APIs via monkey-patching should be excluded from `Wise.toc` and should always restore the original functions immediately after execution to prevent side effects in the production environment.
- **Sandbox Testing:** Use `mcp__mechanic__sandbox-exec` to test Lua code with WoW API stubs without launching the game. This is the preferred method for quick validation of logic.
- **In-Game Testing:** Use `mcp__mechanic__lua-queue` to queue Lua snippets for in-game execution (requires `/reload` in WoW), then `mcp__mechanic__lua-results` to read the output. Use `mcp__mechanic__addon-output` to get the latest errors, test results, and console output from the game.

## Textures and Media
- **TGA Format:** Custom `.tga` mask textures for WoW must be saved as uncompressed 32-bit TGA files with an 8-bit alpha channel (RGBA), where the mask shape is opaque white and the background is transparent black.
- **Media Path:** Custom textures (like alpha masks for button shapes) are stored in the `Media/` directory as `.tga` files and referenced in code as `Interface\AddOns\Wise\Media\<FileName>.tga`.
- **Texture Wrapping:** Custom alpha mask textures used with `CreateMaskTexture()` require specific texture wrapping mode arguments `"CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE"` in `SetTexture()` to apply correctly without edge bleeding.
- **Dynamic Masking:** When dynamically applying mask textures to UI elements, ensure `SetTexture(...)` is called outside of the initial `CreateMaskTexture()` creation block so that texture changes update visually at runtime.
- **Generation:** The development environment supports generating custom `.tga` media files using Python's `Pillow` library. Install via `python3 -m pip install pillow --break-system-packages` if missing.
- **Asset Pipeline:** Use `mcp__mechanic__assets-sync` to convert PNG source assets to TGA and sync them to the addon. Use `mcp__mechanic__assets-list` to list current assets.
- **Atlas Icons:** Use `mcp__mechanic__atlas-search` to find Blizzard UI atlas icons by name pattern when selecting icons for UI elements.

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

## Performance
- **In-game profiler:** `/wise cpu start`, play/idle ~30s, then `/wise cpu` reports a time-boxed CPU delta for Wise-owned frames (split into "in frames" vs "elsewhere"). Requires the `scriptProfile` CVar (the command enables it + prompts a reload on first use). This is the source of truth for idle cost — addon-CPU displays misattribute `UIParent`/child time to whichever addon parents those frames.
- **Design rule:** Updates are event-driven, not ticker-polled — see Rule 12. The central `DynamicRefreshDriver` (`core/GUI.lua`) is where dynamic-group refresh events are registered; add new triggers there rather than introducing tickers.
- **Baselines:** Use `mcp__mechanic__perf-baseline` to record memory/CPU baselines after stable releases. Use `mcp__mechanic__perf-compare` to check for regressions against the baseline after changes.
- **Reports:** Use `mcp__mechanic__perf-report` to view performance history and trends.

## Research
- **Web Search:** Use `mcp__mechanic__research-query` to search the web for addon development information, WoW API behavior, and best practices when documentation is insufficient.
- **SavedVariables:** Use `mcp__mechanic__sv-parse` to extract data from WoW SavedVariables files after game sessions for debugging or data analysis.
