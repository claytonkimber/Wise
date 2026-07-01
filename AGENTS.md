# Wise Addon: Technical Constitution

## Project Goal
A high-performance World of Warcraft (Retail 11.0+) using pure LUA. Only use libraries if they provide a significant improvement in performance or usability.

## Tech Stack
- Language: Lua (WoW-variant)
- Framework:
- IDE: Antigravity 2026
- Agent Trio: Claude Code (Logic), Jules (Background Ops), Gemini (Arch)
- Tooling: Mechanic MCP (addon lifecycle automation); CodeSight MCP (codebase structure / blast-radius analysis); wow-ui-sim (headless WoW client for UI-layout & visual verification — see its own section)

### Mechanic Usage Policy (token cost)

Mechanic tool calls return very large outputs and burn context tokens fast. **Use Mechanic sparingly:**

- Prefer local/built-in alternatives first: Read/Grep/Glob for navigation, `luacheck`/`stylua` via the shell for lint/format, and your own knowledge of the WoW API before reaching for `api-search`/`api-info`.
- Reserve Mechanic for what only it can do: in-game execution (`lua-queue`/`lua-results`/`addon-output`), sandbox runs with WoW API stubs, and the security/deprecation scanners before a release.
- Run the heavy scanners (`addon-security`, `addon-deprecations`, `addon-deadcode`, `addon-complexity`) once per change-set as a pre-merge gate, not after every edit.
- Never call Mechanic tools speculatively or "just to check" — each call should answer a specific question you cannot answer locally.

### UI & Visual Verification (wow-ui-sim)

`wow-ui-sim` is a headless WoW UI client (Rust) that loads the real Blizzard base UI plus Wise and renders/inspects frames **without launching the game**. It lives at `Interface/_dev_/wow-ui-sim` and runs as a Docker image (`wow-ui-sim:12.0.7`). It is the only tool in this stack that can observe **actual frame geometry and rendered pixels** out-of-client.

**Use it ONLY when a task needs out-of-client UI ground truth, specifically:**
- **UI placement / anchoring** — verifying a frame's resolved position, size, anchor point, strata, or parent after an edit-mode / layout change (`dump-tree` returns the computed frame tree with coordinates).
- **Graphics / visual issues** — confirming a texture, mask, atlas crop, color, or layer order actually renders as intended (`screenshot` produces a `.webp` of the rendered UI).
- **Layout refinements** — before/after comparison of a positioning or sizing tweak, where "does it look right" can't be answered by reading Lua.
- **Headless regression of load-time behavior** — `run-tests Wise` runs `Wise/tests/smoke.lua` (addon loads clean, globals present); `lua-errors` dumps unique Lua errors as JSON.

**Do NOT invoke it unless the task is in that scope.** It is a multi-second Docker run (and `screenshot` renders a full frame), far heavier than reading code or running luacheck. Logic, API-signature, taint, and dependency questions never need it — answer those locally or with Mechanic. If a change is purely non-visual (a conditional, a data structure, an event wiring), there is no reason to start the simulator.

**How to run** (Bash tool; PowerShell is unavailable in-session):
```bash
DOCKER="/c/Program Files/Docker/Docker/resources/bin/docker.exe"
WISE="C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\Wise"

# tests / frame geometry / lua errors (no extra mounts)
MSYS_NO_PATHCONV=1 "$DOCKER" run --rm \
  -v "${WISE}:/app/Interface/AddOns/Wise" \
  wow-ui-sim:12.0.7 <command>      # run-tests Wise | dump-tree [-f Filter] | lua-errors

# screenshot — also mount a host output dir, then Read the .webp back
OUTDIR="<some scratch dir>"; mkdir -p "$OUTDIR"
MSYS_NO_PATHCONV=1 "$DOCKER" run --rm \
  -v "${WISE}:/app/Interface/AddOns/Wise" \
  -v "${OUTDIR}:/out" \
  wow-ui-sim:12.0.7 screenshot -o /out/wise.webp
```
- `MSYS_NO_PATHCONV=1` stops git-bash mangling the `:/app/...` mount path.
- **`screenshot` renders via software Vulkan (Mesa lavapipe) baked into the image** — no GPU/`--gpus` needed, deterministic, ~1600x1200 `.webp`. The `XDG_RUNTIME_DIR is invalid` warning it prints is harmless (offscreen render, no Wayland session). Read the resulting `.webp` to see the rendered UI.
- New UI test cases go in `Wise/tests/*.lua` using the simulator's `test(...)`/`async_test(...)` + `assertEquals` framework — this is separate from the in-client `tests.xml` QA checklist.

### Choosing the tool: wow-ui-sim vs Mechanic (token efficiency)

These two are **complementary, not overlapping** — they answer different questions, so pick by what you actually need and don't run both for one question:

| Question you have | Tool | Why |
|---|---|---|
| Where does this frame end up? What's its anchor/size/strata after my change? | **wow-ui-sim** `dump-tree` | Only it computes real resolved frame geometry from the loaded UI. |
| Does this texture/mask/atlas/color render correctly? | **wow-ui-sim** `screenshot` | Only it produces actual rendered pixels. |
| Does the addon load without Lua errors at startup? | **wow-ui-sim** `run-tests`/`lua-errors` | Real Blizzard base UI + full load sequence, no game client. |
| Is this WoW API real / what's its signature / is it deprecated? | **Mechanic** `api-search`/`api-info`/`addon-deprecations` | Mechanic owns the version-pinned API + deprecation DB; the sim doesn't answer API-shape questions. |
| Does this isolated Lua logic behave correctly (no rendering)? | **Mechanic** `sandbox-exec` | Quick API-stubbed logic check; far lighter than booting the sim. |
| Run a snippet inside my **actual** running game and read output? | **Mechanic** `lua-queue`/`lua-results`/`addon-output` | In-client execution — the sim is out-of-client, it can't see live game state. |
| Taint / combat-lockdown / security audit; dead code; complexity; format/lint. | **Mechanic** scanners | Static analyzers; nothing visual, no sim needed. |

**Strong points.** Mechanic = the *static + in-client + API-knowledge* layer (API DB, deprecations, security/taint/dead-code/complexity scanners, sandbox logic runs, real-game execution & output capture, asset/atlas pipeline). wow-ui-sim = the *out-of-client rendering + real-frame-geometry* layer (computed layout, rendered pixels, full base-UI load).

**Rules of thumb for a robust, token-cheap workflow:**
1. **Default to neither** — Read/Grep/Glob + your WoW knowledge + shell `luacheck`/`stylua` answer most questions for free.
2. **Reach for Mechanic** for API truth, in-game runs, and pre-merge static scans (used sparingly per the policy above).
3. **Reach for wow-ui-sim** only for the UI-layout / visual / load-time questions in its scope — when "does it look/sit right" genuinely can't be read from the code.
4. **Never run both for the same question.** If you can answer it statically or via API lookup, don't boot the sim; if you need pixels or resolved geometry, the sim is the *only* answer and Mechanic won't help.

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
- **A *global* secure hook (e.g. `hooksecurefunc("RegisterStateDriver", ...)`) fires for every caller in the game, not just Wise's own frames.** Running Wise's closure inside Blizzard's own secure call stack (e.g. compact unit-frame health-color updates during `GROUP_ROSTER_UPDATE`) taints frames Wise never manages, surfacing as `"secret number value"` compare errors deep in Blizzard code. Any global secure hook MUST early-out via a cheap name/identity check (e.g. a precomputed `managedDriverNames` hash set) **before** touching any secure API or doing real work — never run the hook body "just to check" on every frame.

### Numeric Taint Stripping

`tonumber(n)` on an already-numeric tainted value is an **identity operation — it does NOT strip taint.** Only a string→number round-trip or arithmetic produces a fresh, untainted value. When a number originates from a secure frame/API (CooldownViewer children, action bar buttons, spec info, `C_Spell` override/lookup results) and will be used as a table key, in a comparison, or passed back through user code, route it through **`tonumber(tostring(value))`**, not plain `tonumber(value)` — and guard against `nil` since true secrets won't convert.

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

**Diagnostics:** `/wise cpu start` → wait → `/wise cpu` measures a time-boxed delta of Wise-owned frames (tagged via `_wiseProfileName`), splitting cost into "in frames" vs "elsewhere (tickers/handlers)". Use it before/after any perf change. For a one-time hitch the instant combat starts (which a sustained window averages away), `/wise cpu enter` arms a `PLAYER_REGEN_DISABLED` probe that times the combat-enter frame (`debugprofilestop` delta) and ranks per-addon CPU across it, separating Wise's share from Blizzard's unavoidable secure-frame re-eval; re-run it to print the breakdown, `/wise cpu enter clear` to reset. All of this requires `scriptProfile=1` (the command enables it; needs one `/reload` to take effect) and is session-only (no SavedVariables writes).

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
- **UI-Layout / Visual Verification:** For out-of-client checks of frame placement, anchoring, or rendered graphics (and headless load-time regression), use the `wow-ui-sim` Docker image — see "UI & Visual Verification (wow-ui-sim)" above for when (UI placement / graphics / refinements only) and how. Do not invoke it for non-visual logic, API, or taint questions.

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
- **Slot Configurator overlay invariant:** the embedded slot configurator (`modules/Properties.lua`/`modules/SlotConfigurator.lua`) renders popups (condition picker, node properties, availability filter, icon picker) as separate right-half overlay hosts. **Exactly one overlay host may be visible at a time**, enforced by (1) a `HideAllConfiguratorOverlays()` helper called before any overlay shows itself, and (2) each popup opener clearing the *other* overlays' flags. The configurator's own chrome (header divider, toolbar) must also hide whenever any overlay flag is set, or it visually bleeds around the popup. When adding a new overlay, wire it into both mechanisms.

## Addon Specifics
- **Conditionals Validation:** `Wise:ValidateVisibilityCondition` in core/Conditionals.lua enforces security by disallowing newline (\n) and carriage return (\r) characters to prevent macro command injection.
- **Talent Visibility:** Talent visibility requirements (stored in `action.talentRequirements`) are displayed as a comma-separated list of resolved spell names using `C_Spell.GetSpellInfo(spellID)`.
- **Interface Conditionals:** Interface conditionals (e.g., `[wise:groupName]`) and Addon Loading Magic conditionals (e.g., `[aml:slotname]`) are dynamically generated and evaluated in `core/Conditionals.lua`.
- **Specializations:** Action visibility based on specializations uses the 'spec' category. The `action.specRequirements` field stores a table of required spec IDs.
- **Nesting Cycles:** `Wise:WouldCreateNestingCycle` in `modules/Nesting.lua` proactively prevents circular interface nesting by traversing the hierarchy via `Wise:GetParentInfo`.

### Graph Slots / Compiled `custom_macro` Steps

Slot Configurator "graph" nodes (`type="spell"`, `value=spellID`, `icon=textureID`) get compiled into bar-ready `type="misc"`, `value="custom_macro"` entries with a `macroText` body. Several non-obvious rules govern this pipeline — violating any of them reintroduces bugs that have already shipped and been fixed once:

- **`/cast` does not accept a bare numeric spell ID in retail.** `/cast [cond] 12345` parses without error but **casts nothing** — only `/cast [cond] SpellName` fires. This only bites the *conditional* branch of compiled macro text (the unconditional branch uses `type="spell"`, which does accept IDs). Any code generating conditional `/cast` lines must emit the resolved spell **name**, not the ID.
- **Compiled `custom_macro` steps MUST carry `pathNodeIds`.** `UpdateGroupDisplay` (`core/GUI.lua`) only re-filters a step per-character when `pathNodeIds` is present; without it the step fires its canonical macro text verbatim with no availability check, which can leak an off-spec/off-class cast. A step with no `pathNodeIds` but whose slot has a `graph` key is dropped at runtime rather than trusted (hand-authored Custom Macros are exempt — their slot has no `graph` key).
- **Icon resolution priority:** the bar button icon comes from `ResolveMacroData`/`GetActionIcon`, which can return `nil` for untalented/unknown spells (`C_Spell.GetSpellInfo` fails) — the stored **node icon is the ground-truth fallback** and must be carried through `FilterMacroTextForCharacter` (as `liveIcon`/`copy.icon`) to the button renderer, which prefers `actionData.icon` over the live-resolved icon.
- **Override/possess-bar action nodes (`type="action"`, `value` = a raw slot number 121-156) store a literal placeholder icon** (`"Interface\Icons\INV_Misc_QuestionMark"`, numeric `134400`) because the real icon can only be known at runtime via `GetActionTexture()` once `HasOverrideActionBar()`/`HasVehicleActionBar()`/`HasTempShapeshiftActionBar()` is true (see `Wise:ResolveBarActionID`, `core/GUI.lua`). Any icon-priority code must treat this placeholder (both the numeric `134400` AND the `inv_misc_questionmark` path-string form) as "no real icon" and fall through to the next candidate — checking only one form re-introduces a `?` icon bug.
- **GCD display coloring must never influence the secure sequencer.** Every configurator-compiled step is on-GCD by construction (one action per press); a shared helper that resolves "what does this macro actually cast" for GCD-color display purposes must not also feed the secure `isa_offgcd_*` attribute that drives multi-step stacking, or steps silently collapse/stop advancing.

### CooldownViewer Integration (`wiser/Cooldowns.lua`)

- **`C_CooldownViewer` child frames do not reliably expose `cooldownID`** when the native Cooldown Manager viewer is hidden (`hideNativeInterface=true`) — as of 12.0.7, hidden children report `cooldownID=nil`. Detect "did this child actually yield a spell" by checking `child.cooldownID ~= nil`, never by the mere presence of a `GetSpellID` method (every frame has one).
- **The hidden-viewer fallback must filter on the `flags` bit, not just `isKnown`.** `C_CooldownViewer.GetCooldownViewerCategorySet(cat, false)` returns every learned in-spec cooldown, including ones the user/CDM marked "Not Displayed" — `info.isKnown` does not exclude them. `Enum.CooldownViewerCooldownFlag` isn't addon-exposed; test the literal bit (`bit.band(info.flags, 0x2) ~= 0` = hidden).
- **A cache keyed only by spec *index*** (not spec ID) **collides across classes** that share an index (e.g. Guardian Druid and Shadow Priest are both spec-index 3) — key any per-spec cooldown cache by spec ID.
- **Dynamic/linked cooldowns** (`linkedSpellIDs` non-empty, e.g. Flying Serpent Kick / Wild Charge) represent several per-form spell variants; resolving via the child frame's `GetSpellID()` returns one arbitrary currently-active variant. Prefer the cooldown info's `overrideSpellID or spellID` as the representative spell.
- Never let an empty read (0 spells) destructively overwrite an existing populated interface — guard with a `#spells==0` check and a bounded retry before wiping.

## Performance
- **In-game profiler:** `/wise cpu start`, play/idle ~30s, then `/wise cpu` reports a time-boxed CPU delta for Wise-owned frames (split into "in frames" vs "elsewhere"). Requires the `scriptProfile` CVar (the command enables it + prompts a reload on first use). This is the source of truth for idle cost — addon-CPU displays misattribute `UIParent`/child time to whichever addon parents those frames.
- **Design rule:** Updates are event-driven, not ticker-polled — see Rule 12. The central `DynamicRefreshDriver` (`core/GUI.lua`) is where dynamic-group refresh events are registered; add new triggers there rather than introducing tickers.
- **Baselines:** Use `mcp__mechanic__perf-baseline` to record memory/CPU baselines after stable releases. Use `mcp__mechanic__perf-compare` to check for regressions against the baseline after changes.
- **Reports:** Use `mcp__mechanic__perf-report` to view performance history and trends.

## Research
- **Web Search:** Use `mcp__mechanic__research-query` to search the web for addon development information, WoW API behavior, and best practices when documentation is insufficient.
- **SavedVariables:** Use `mcp__mechanic__sv-parse` to extract data from WoW SavedVariables files after game sessions for debugging or data analysis.
