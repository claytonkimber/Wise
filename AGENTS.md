# Wise Addon: Technical Constitution

## Keeping This File Current (MANDATORY)

This file is the shared contract between the agents working on Wise (Claude Code,
Gemini, Jules) and the human. An agent that solves a problem and leaves the
knowledge only in a chat transcript has done half the work: the next agent — or
the next model — starts from zero and re-derives, or worse, re-breaks it.

**Write it down when the learning is durable.** The test is not "was this hard?"
but "would someone reasonably do the wrong thing without knowing this?"

Record here:

- **A behaviour of the WoW client that contradicts the obvious assumption** —
  an API that returns secret/nil where you'd expect a value, a call that silently
  no-ops, a version gate. These are the most expensive things to rediscover
  because the code looks correct.
- **An invariant that spans files** — "these three tables must agree", "this
  field must be carried through that filter". Anything a future edit can break
  from a distance, where the failure surfaces somewhere else.
- **A design decision with a rejected alternative** — especially a feature
  deliberately *not* shipped, or a route already tested and closed. Without the
  "we tried that, here's why it can't work", it gets re-attempted.
- **A tool's real behaviour vs its documented behaviour** — where the sim, the
  scanners, or CodeSight lie or mislead.

Do **not** record: one-off bug fixes with no general lesson, routine
troubleshooting steps, restatements of what the code plainly says, or a
changelog entry (that is what `CHANGELOG.md` and git history are for).

**Rules of upkeep:**

1. **Correct in place; never append a contradiction.** When a measurement
   supersedes an earlier claim, *delete the wrong claim* and say what replaced
   it. Two conflicting paragraphs are worse than none — the reader cannot tell
   which is current. (See the Combat Aura Secrecy section: an earlier, wrong
   theory was deleted outright rather than left alongside the correction.)
2. **Date and attribute measured facts.** Client behaviour is version-specific.
   A claim about secrecy or an API shape should say when it was measured and on
   what build, so a later patch can invalidate it honestly.
3. **Say what was tested and what was assumed.** "Verified in-game 12.1" and
   "inferred from PTR notes" carry different weight for the next agent deciding
   whether to trust it.
4. **A code comment pointing at `AGENTS.md "<Section>"` must resolve.** Several
   modules cross-reference sections by name; if you rename or remove one, fix
   the referring comments (`grep -rn 'AGENTS.md' --include='*.lua'`).
5. **Prune.** If a section describes a workaround for a bug the client has since
   fixed, or a file that no longer exists, remove it. Stale guidance is followed
   just as faithfully as current guidance.

**For cross-project learnings** (the simulator, Mechanic, Perfy), put the fact in
the project it belongs to and cross-reference rather than duplicating — a copy
drifts. Simulator behaviour goes in `_dev_/wow-ui-sim/AGENTS.md`; how *Wise* uses
those tools stays here.

## Project Goal
A high-performance World of Warcraft (Retail 11.0+) using pure LUA. Only use libraries if they provide a significant improvement in performance or usability.

## Tech Stack
- Language: Lua (WoW-variant)
- Framework:
- IDE: Antigravity 2026
- Agent Trio: Claude Code (Logic), Jules (Background Ops), Gemini (Arch)
- Tooling: Mechanic (addon lifecycle automation — MCP when connected, otherwise the
  file-queue bridge below); CodeSight MCP (structural map; see its section for current
  limits); wow-ui-sim (headless WoW client for UI-layout & visual verification);
  Perfy (`_dev_/Perfy`, flame-graph profiler for the live addon) — each has its own
  section below
- Docs: this file is the shared agent contract — see "Keeping This File Current"

### Code Editing & Token Efficiency: Direct Replacements & Diffs (MANDATORY)

**This policy applies to every agent working in this repository (Claude Code, Gemini, Jules, etc.):**

- **Always use git diffs and direct replacements instead of Python scripts.** When making changes to any file, always use direct text/block replacement tools (e.g. `replace_file_content`, `multi_replace_file_content`) or standard git diffs/patches.
- **Never write or execute ad-hoc Python scripts to edit files.** Creating temporary Python scripts or one-liners to perform search-and-replace, regex edits, or file rewrites wastes context tokens, incurs unnecessary execution round-trips, risks formatting/newline drift, and leaves extraneous scratch files in the workspace. Direct, targeted replacements and git diffs are significantly more token-efficient, transparent, and deterministic.

### Module Sizing & Architectural Granularity (MANDATORY)

**The aim for modules across this addon is to stay under the size threshold where file length impedes accurate, efficient LLM agent comprehension and modification:**

- **Target Module Size (100–300 lines):** Monolithic files (e.g., 2,000+ lines) must be broken up where possible into focused, single-responsibility modules of approximately 100–300 lines.
- **Why Granularity Matters for LLM Pair Programming:**
  - **Context Window & Token Efficiency:** Compact files can be viewed, analyzed, and edited without saturating context or incurring huge token penalties from chunk offsets.
  - **Pinpoint Editing Accuracy:** Targeted direct replacements (`replace_file_content`) are much more reliable, deterministic, and resilient against misaligned blocks in smaller modules.
  - **Debugging & Isolation:** Decoupled 100–300 line files make localized debugging, unit testing, and sandbox execution (`sandbox-exec`) vastly simpler, faster, and less error-prone.
- **Incremental Refactoring:** When touching or adding to large existing files (such as `core/GUI.lua`), actively look for opportunities to carve out self-contained systems (e.g., specific overlay panels, animation handlers, widget builders, or discrete event drivers) into separate submodules registered in `Wise.toc`.

### Mechanic Usage Policy (token cost)

Mechanic tool calls return very large outputs and burn context tokens fast. **Use Mechanic sparingly:**

- Prefer local/built-in alternatives first: Read/Grep/Glob for navigation, `luacheck`/`stylua` via the shell for lint/format, and your own knowledge of the WoW API before reaching for `api-search`/`api-info`.
- Reserve Mechanic for what only it can do: in-game execution (`lua-queue`/`lua-results`/`addon-output`), sandbox runs with WoW API stubs, and the security/deprecation scanners before a release.
- Run the heavy scanners (`addon-security`, `addon-deprecations`, `addon-deadcode`, `addon-complexity`) once per change-set as a pre-merge gate, not after every edit.
- Never call Mechanic tools speculatively or "just to check" — each call should answer a specific question you cannot answer locally.

### Mechanic: the file-queue bridge (when the MCP is not connected)

**The Mechanic MCP is frequently NOT connected in Claude Code sessions.** When
`mcp__mechanic__*` tools are unavailable, in-game evaluation is still possible —
via a file, which is the path that actually gets used in practice:

- Write `MECHANIC_LUA_QUEUE = { { label = "...", code = [==[ ... ]==] } }` into
  `_dev_/!Mechanic/MechanicQueue.lua`. It executes at `!Mechanic`'s
  `ADDON_LOADED` **on every login and `/reload`** until the file is reset to
  `MECHANIC_LUA_QUEUE = {}`. Reset it when you are done, or your probe keeps
  firing for the rest of the user's play session.
- **It runs before other addons load.** Wrap any probe that inspects Wise (or
  any addon) in `C_Timer.After(n, ...)` — a probe that reads `Wise.VDC` at
  `ADDON_LOADED` sees `nil` and reports a false negative.
- Synchronous return values land in
  `MechanicDB.profiles.Default.luaEvalResults`; **deferred probes must print to
  chat and/or stash into `MechanicDB.profiles.Default.<key>` themselves.**
  SavedVariables are written **at logout**, so a probe result cannot be read back
  until the user exits or reloads.
- Read results from
  `WTF/Account/CLAYTONKIMBER/SavedVariables/!Mechanic.lua`.
- **This is a request to the human, not a self-service tool.** Queuing a probe
  requires the user to reload and, for SavedVariables results, to log out. Batch
  everything you want to learn into one probe rather than iterating one question
  per reload.

### Perfy: flame-graph profiling of the live addon

`_dev_/Perfy` is a fork of Perfy (branch `midnight-compat`) — a Lua flame-graph
profiler. Perfy's core APIs survived the 12.0 API break intact; the fork exists
for toolchain/compat fixes, not a rewrite. It is declared an **optional**
dependency, never a required one.

**Full workflow lives in `tools/README-profiling.md` — read it before profiling.**
`tools/perfy-profile.ps1` instruments the **real** addon at its real path (no
copies, no junction swapping), so what you profile is exactly what runs.

The non-obvious parts worth knowing before you start:

- **Instrumentation rewrites `.lua`/`.toc` files in place, so "restore" means
  git.** Uncommitted tracked changes block `-Instrument`; `-Force` auto-stashes
  and `-Restore` pops that exact stash back by commit sha. Untracked files are
  never touched. `-Restore` is idempotent and safe after a failed run.
- **`/reload` after `/perfy stop` is REQUIRED** — that is what writes the capture
  to disk. Skipping it loses the run.
- **30 seconds is the recommended capture.** The analyzer is the binding
  constraint (~400 bytes of RAM per trace entry: 30s ≈ 2.2M entries ≈ 0.8 GB;
  240s+ tends to OOM), and the client grows ~1 GB/min while tracing because
  Perfy disables the GC to keep measurements clean. **Longer is not better** — a
  long capture averages away the thing you are hunting.
- **Captures are not comparable unless you control the conditions.** Perfy's own
  instrumentation inflates absolute numbers, so only compare runs to each other,
  and only with matched duration, visible button count (the dominant scaling
  factor), and activity level. Wait a few seconds after `/reload` before starting
  so the one-time rebuild does not land in the trace.
- **Choosing between profilers:** `/wise cpu` (see Performance) is the cheap
  first stop for "is Wise costing anything, and where — frames or handlers".
  Reach for Perfy when you need a **call-graph attribution** of that cost, since
  it names the actual functions. Do not instrument to answer a question
  `/wise cpu` already answers.

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

#### Simulator gotchas that have cost real debugging time

These are behaviours of the sim itself, not of Wise. A green suite here is not
proof of a working addon, and a red one is not always your bug.

- **Use the `12.0.7` image for `run-tests`, not `12.1.0`.** The same tree scores
  82/82 on 12.0.7 and 80/82 on 12.1.0: `compat121.lua` explicitly asserts the
  12.1 intrinsics are **absent**, which is true on 12.0.7 and false on 12.1.0, so
  the newer image inverts the test's expectations. Do not debug those two —
  switch images.
- **A failing sync test prints no failure text — the file just vanishes from the
  output** while its failures still count in the total. To see *why* one failed,
  run the assertions at **file scope** and `error()`: the load-error branch does
  print, with full text. Delete the probe file afterwards.
- **Never stub the global `print` in a test helper.** The runner reports failures
  through it, so a helper that silences `print` swallows every later file's
  failure output and makes a red suite look green.
- **`--exec-lua` is the fastest way to see a failure.** It is a **global** flag,
  not a `run-tests` option, so pair it with a cheap subcommand:
  `--exec-lua '<code>' dump-tree -f NoSuchFrame`. Its `print` output *does*
  reach the output, unlike per-test failure text. A host mount for a script file
  often will not resolve — inline the code rather than using `@/path`.
- **Sim absence ≠ API removal.** `GetUnitSpeed` reads nil under the sim but
  exists in the live client. Before "fixing" a nil API the sim reports, check
  whether other live addons call it, and guard defensively
  (`local fn = Localized or _G.Name`) rather than migrating to a replacement that
  may not exist.
- **Hoisted upvalues defeat `_G` stubbing.** `core/GUI.lua` hoists
  `local InCombatLockdown = InCombatLockdown` at the top, so a test that stubs
  `_G.InCombatLockdown` silently exercises the **live** path and passes for the
  wrong reason. Where a test must control such a value, add an explicit seam
  (e.g. `Wise._forceCombatSampling`, nil in normal play) and **mutation-test** to
  prove the guarded branch is actually reached. APIs resolved at call time
  (`_G.Foo` *inside* the function) remain stubbable.
- **Frame globals and `C_*` namespaces cannot be replaced from test code.**
  `MerchantFrame = {...}` or `_G.C_UnitAuras = {stub}` silently do nothing —
  both resolve through the sim's registries. Patch **fields** on the existing
  table (`C_UnitAuras.GetPlayerAuraBySpellID = stub`) and restore the originals
  afterwards; for frames use `_G.MerchantFrame`, or just `:Show()`/`:Hide()` the
  real one and restore its prior state.
- **Only three non-Blizzard addons exist in the sim:** `Wise`, `TestFramework`,
  `__BuiltIn`. A test needing a second real installed addon must use
  `TestFramework` — anything else returns nil from `C_AddOns.GetAddOnInfo` and
  silently changes what the code under test does.
- **`OnGamePadButtonDown`/`OnGamePadStick` are not recognised script handlers**
  in the sim and throw on `SetScript`, though real WoW and ConsolePort both rely
  on them. See the Gamepad section — the `pcall` lives in the addon code.
- **UIPanel mutual exclusivity is not modelled.** The sim does not reproduce the
  real panel manager's area competition (opening `CharacterFrame` should close
  `MerchantFrame`; they share the "left" slot). A passing suite is not proof that
  code touching two `UIPanelWindows`-registered frames together is safe — verify
  that class of interaction against Blizzard source or in-game.
- **Known harmless noise:** Blizzard `MoneyFormatter`/`GameTooltipConstants`
  errors (`Enum.CurrencyType`, `MoneyFormatterUtil` nil) are pre-existing sim
  gaps, not addon faults.
- **Docker Desktop must be running first** (`Start-Process "C:\Program
  Files\Docker\Docker\Docker Desktop.exe"`, ~1 min to become ready). If the
  daemon is down, the run fails with a `npipe:////./pipe/dockerDesktopLinuxEngine`
  connect error — that is the daemon, not your test.

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
2. **Direct replacements over Python scripts** — Always use git diffs and direct editor replacements (`replace_file_content`, `multi_replace_file_content`) instead of Python scripts to modify files, conserving tokens and execution steps.
3. **Reach for Mechanic** for API truth, in-game runs, and pre-merge static scans (used sparingly per the policy above).
4. **Reach for wow-ui-sim** only for the UI-layout / visual / load-time questions in its scope — when "does it look/sit right" genuinely can't be read from the code.
5. **Never run both for the same question.** If you can answer it statically or via API lookup, don't boot the sim; if you need pixels or resolved geometry, the sim is the *only* answer and Mechanic won't help.

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

`tonumber(n)` on an already-numeric tainted value is an **identity operation — it does NOT strip taint.** Only a string→number round-trip or arithmetic produces a fresh, untainted value. When a number originates from a secure frame/API (CooldownViewer children, action bar buttons, spec info, `C_Spell` override/lookup results) and will be used as a table key, in a comparison, or passed back through user code, route it through **`tonumber(tostring(value))`**, not plain `tonumber(value)`.

**Taint ≠ secrecy, and the round-trip does NOT reliably detect a secret.** `tostring(secret)` does *not* throw — it returns a **secret string**, which survives the round-trip and only explodes on the *next* comparison, far from the real cause. Verified in isolation: given a secret, `tonumber(tostring(v))` alone yields a readable number; only `issecretvalue` rejects it.

Use the client primitives instead — **`issecretvalue(v)`** for values, **`issecrettable(t)` before indexing** a possibly-secret table (indexing one throws, and `issecretvalue` cannot catch that). Both are real 12.0 globals, beside `issecure`/`issecurevalue`. Guard for their absence and keep the round-trip as fallback. See `SecretSafeNumber` in `modules/IndicatorRules.lua`.

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

**Diagnostics:** `/wise cpu start` → wait → `/wise cpu` measures a time-boxed delta of Wise-owned frames (tagged via `_wiseProfileName`), splitting cost into "in frames" vs "elsewhere (tickers/handlers)". Use it before/after any perf change. For a one-time hitch the instant combat starts (which a sustained window averages away), `/wise cpu enter` arms a `PLAYER_REGEN_DISABLED` probe that times the combat-enter frame (`debugprofilestop` delta) and ranks per-addon CPU across it, separating Wise's share from Blizzard's unavoidable secure-frame re-eval; re-run it to print the breakdown, `/wise cpu enter clear` to reset. Similarly, `/wise cpu leave` (or `/wise cpu exit`) arms a `PLAYER_REGEN_ENABLED` probe that measures the combat-exit frame and subsequent deferred frame (dynamic refresh pass, indicators), ranking per-addon CPU and isolating Wise's internal routines (`UpdateAllCooldowns`, `RefreshAllDynamicGroups`, `UpdateGroupDisplay`, `ResetSequences`). All of this requires `scriptProfile=1` (the command enables it; needs one `/reload` to take effect) and is session-only (no SavedVariables writes).

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

CodeSight is a local, patched MCP that maps Wise's structure. Because WoW addons
share one global `Wise.*` table instead of importing by path, CodeSight has a
**Tier 2 patch** that builds a namespace symbol graph (which file reads a
`Wise.Foo`/`Wise:Foo` that another file defines).

**Status (verified 2026-09-02): installed, patched, and running — but blast
radius has saturated and is currently NOT trustworthy as a risk signal.**

- The scan itself works. `node node_modules/codesight/dist/index.js .` completes
  in ~100ms, detects the project as `lua` (proving the patch is applied — stock
  CodeSight calls Wise a JavaScript project), and picks up all 97 files
  including everything added since June (`Compat121`, `Filters`,
  `IndicatorRules`, `AudioCues`, `SlotConfigurator`, `wiser/Cursor`,
  `wiser/DisenchantConvert`).
- **Blast radius has degenerated to a binary answer.** As the addon grew, the
  graph became fully connected at the default 3-hop depth, so nearly every
  non-leaf file now returns *the entire addon*. Measured 2026-09-02:
  `core/Polyfill.lua` 47, `core/Text.lua` 47, `modules/Audio.lua` 48, and
  `wiser/Cursor.lua` **47** — even though `Cursor.lua` is a self-contained probe
  module whose only dependent is the `/wise cursor` slash command in `Wise.lua`.
  True leaves (`core/Dispatcher.lua`, `bench.lua`, `tests/smoke.lua`) still
  correctly return 0.
- **Therefore: a large blast-radius number means nothing — do not use it to
  judge whether a change is risky.** It no longer distinguishes `core/Polyfill`
  (genuinely foundational) from a leaf module. Only the `0` answer still carries
  information: it reliably means "nothing reads this file's symbols."
  *(Earlier revisions of this file cited `Polyfill ~26` / `Text ~25` as evidence
  the tool discriminates. Those counts are stale and that conclusion no longer
  holds; they have been removed rather than left to mislead.)*
- **What CodeSight is still good for:** the one-shot orientation map
  (`codesight_get_summary`), the hot-files ranking (`codesight_get_hot_files`) —
  ordering is still meaningful even where absolute counts are not — and
  confirming a file is genuinely unreferenced before deleting it.
- **To answer "what could this change break", read the code.** `Grep` for the
  specific `Wise.Foo` symbol you are changing. That is precise, cheap, and
  currently more reliable than the graph.
- **After editing addon `.lua`/`.toc` files** the MCP serves a cached scan — call
  `mcp__codesight__codesight_refresh` (or re-run the CLI) so the map reflects
  your changes. The map at `.codesight/` is gitignored and regenerates freely.
- **Scope:** CodeSight answers *structural* questions. For *API-level* WoW
  analysis (taint, deprecations, API signatures) use Mechanic — complementary,
  not interchangeable.

**If blast radius is worth repairing**, the lever is in the patch, not upstream:
lower the traversal depth (3 hops is what saturates it) and/or lower
`WOW_HUB_DEFINE_THRESHOLD` in `dist/detectors/graph.js` so more shared-state
symbols are treated as hubs and excluded. Re-measure against a known leaf like
`wiser/Cursor.lua` (expected: a small number, not 47) and a known hub like
`core/Polyfill.lua`; the tool is only useful again when those two differ.

### Maintaining CodeSight (MANDATORY when editing its source)

CodeSight's WoW Lua support lives entirely in a **patch**, not upstream. It is
versioned in git but **excluded from CurseForge packaging** (listed in `.pkgmeta`
`ignore:`), so never add CodeSight files to `Wise.toc` or expect them in the
shipped `.zip`.

- The patch is `patches/codesight+1.14.0.patch`; it modifies only
  `node_modules/codesight/dist/scanner.js` (Lua/`.toc` detection) and
  `dist/detectors/graph.js` (the symbol graph). `node_modules/` and `.codesight/`
  are gitignored and regenerate via `npm install`, which re-applies the patch
  through the `postinstall` hook.
- **If you edit anything under `node_modules/codesight/dist/`, you MUST
  regenerate the patch** or the change is lost on the next `npm install`: with
  node on PATH (`export PATH="/c/Program Files/nodejs:$PATH"` in git-bash, since
  `patch-package` shells out to bare `node`), run `npx patch-package codesight`,
  then commit the updated `patches/codesight+1.14.0.patch`.
- `dist/` files are **minified/bundled** — `grep` for a constant like
  `WOW_HUB_DEFINE_THRESHOLD` reports "Binary file matches". Use
  `grep -a` (or `strings`) to read them.
- The hub threshold (symbols defined in ≥4 files are skipped as shared mutable
  state) and namespace-token detection live in `graph.js`; tune there if the
  symbol graph over- or under-connects after the addon's structure changes.
- If CodeSight is bumped off `1.14.0`, the patch filename version must match the
  installed version — re-run `npx patch-package codesight` after the bump.

## Verification Workflow
- **WoW API:** Assume Retail 11.0+ (The War Within/Midnight) API names. Only when genuinely unsure of a signature, use `mcp__mechanic__api-search` / `mcp__mechanic__api-info` for a specific API — avoid `mcp__mechanic__api-list` namespace browsing, which returns huge outputs (see Mechanic Usage Policy).
- **Automated Tests:** Do not write custom automated tests for the addon, as executing and passing them requires the actual World of Warcraft game client to be running.
- **tests.xml Workflow:** Every bug fix, feature, or test must add a debugging/testing procedure to `tests.xml`. Before every merge, review `tests.xml` to check if existing tests are still needed, ensuring the file stays clean and unpolluted.
- **Syntax Validation:** Use `mcp__mechanic__addon-lint` (Luacheck) to validate Lua syntax and catch code quality issues. Use `mcp__mechanic__addon-validate` to validate the `.toc` file for common issues before release.
- **Unit Testing:** Unit tests that mock core APIs via monkey-patching should be excluded from `Wise.toc` and should always restore the original functions immediately after execution to prevent side effects in the production environment.
- **Sandbox Testing:** Use `mcp__mechanic__sandbox-exec` to test Lua code with WoW API stubs without launching the game. This is the preferred method for quick validation of logic.
- **In-Game Testing:** Use `mcp__mechanic__lua-queue` to queue Lua snippets for in-game execution (requires `/reload` in WoW), then `mcp__mechanic__lua-results` to read the output. Use `mcp__mechanic__addon-output` to get the latest errors, test results, and console output from the game. **When the Mechanic MCP is not connected — which is common in Claude Code sessions — use the file-queue bridge instead** (see "Mechanic: the file-queue bridge"). Either way this needs the human to reload, so batch your questions into one probe.
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

### Combat Aura Secrecy (12.0.7) — measured, build 68887

Established by seven in-game probes on 2026-07-26. **Earlier notes claiming
12.0.7 "hides rotationally-relevant auras from all reads in combat" are WRONG
and were deleted — that theory was inferred from reads that also failed out of
combat.** What actually happens:

- **Auras still enumerate in combat** (`GetAuraSlots` / `GetAuraDataBySlot`
  return the aura table normally) — **but enumerating is FORBIDDEN in Wise
  anyway.** The enumeration itself is what spread 'Wise' taint into the shared
  aura records: Blizzard's CooldownViewer reads the same records off the same
  `UNIT_AURA` and threw ~14k "secret value ... while execution tainted by
  'Wise'" errors across one M+10 (2026-08-09, !BugGrabber session 9 — Wise on
  none of the stacks; pcall hides the error, not the taint). Normal combat
  doesn't detonate because full aura secrecy is scoped to M+/raid/PvP-style
  content, so the taint sits silent until it meets a secret. In **12.1** the
  question is moot: slot/index/instanceID aura access hard Lua-errors for
  addons whenever auras are secret; only by-spellID/by-name lookups survive.
- **Individual FIELDS become secret**: `spellId`, `name`, `applications`,
  `points`, `duration`, `expirationTime`. `auraInstanceID`, `isHelpful`,
  `isFromPlayerOrPlayerPet` stay **plain**. `C_Secrets.ShouldAurasBeSecret`
  flips `false`→`true` on combat entry, so this is deliberate, not a bug.
- **Therefore every by-identity lookup fails in combat** — `GetPlayerAuraBySpellID`
  cannot match a plain ID against a secret `spellId`. Do not "fix" this by
  trying another lookup order; they all fail for the same reason.
- **`auraInstanceID` values rotate on combat entry**, so a handle learned
  pre-pull does NOT survive. Any "learn the instance out of combat, use it in
  combat" design is dead on arrival.
- **`GetAuraApplicationDisplayCount(unit, inst, min, max)`**: `minDisplayCount`
  gates correctly **out of combat** (1 stack → `min1="1"`, `min2=""`) — note the
  miss is a **plain empty string, not nil**, so `c == nil` is wrong twice over
  (`""` is truthy, and comparing a secret throws). **In combat every threshold
  returns a secret regardless of N**, so no threshold can be inferred.

**Net rule: in combat a stack count is DISPLAYABLE but not INSPECTABLE.**
`FontString:SetText(secret)` is accepted and the client renders it — this is why
the Abundance counter works. **`StatusBar:SetMinMaxValues`/`SetValue` also accept
raw secret numbers and the client renders the fill correctly** (measured live
2026-09-01 via `/wise cursor bar`; an earlier note here claiming `SetValue` is
*refused* was wrong and has been removed). Widget pass-through is therefore the
general escape hatch: hand the secret to a widget, never inspect it.
Anything that *branches* on the value (border colour, glow, threshold sounds)
cannot work in combat and must degrade to "unknown" — never to 0, which lights
`<=N` rules for an entire fight. Out of combat, everything works normally.

Routes already tested and closed, so nobody re-runs them: lookup by buff/cast
ID/name, full enumeration, pre-learned instance handles, the display-count API
with and without `maxDisplayCount`, `minDisplayCount` gating, the `C_Secrets`
namespace, `C_CooldownViewer` (carries no aura data for Abundance), Blizzard's
rendered CDM FontStrings, `tonumber` coercion into `SetValue`, and
`SetText`→`GetText` laundering. The in-combat slot-scan resolver
(`ResolveLiveAuraInstance`) was itself removed 2026-08-09 for tainting the
shared aura records (see above) — the corner count now hides in combat when
by-id/by-name reads fail, by design.

**12.1 path forward (from PTR API notes):** the sanctioned replacement is the
new `AuraContainer`/`AuraButton` intrinsics — `AddAuraSlot(slotKey,
filterString, options)` to bind a filtered aura, `SetApplicationCount` /
`ApplicationBar` to render live stack counts client-side. The addon styles and
anchors the widget; it never sees the data (AuraButtons are forbidden to
tainted code while auras are secret, so configure out of combat). This is the
route to a working in-combat Abundance counter. Also 12.1: `UNIT_AURA` carries
a fully-secret payload (never index it), and some spells are whitelisted
non-secret — if Abundance lands on that list, plain `GetPlayerAuraBySpellID`
reads work again in combat.

### CooldownViewer Integration (`wiser/Cooldowns.lua`)

- **`C_CooldownViewer` child frames do not reliably expose `cooldownID`** when the native Cooldown Manager viewer is hidden (`hideNativeInterface=true`) — as of 12.0.7, hidden children report `cooldownID=nil`. Detect "did this child actually yield a spell" by checking `child.cooldownID ~= nil`, never by the mere presence of a `GetSpellID` method (every frame has one).
- **The hidden-viewer fallback must filter on the `flags` bit, not just `isKnown`.** `C_CooldownViewer.GetCooldownViewerCategorySet(cat, false)` returns every learned in-spec cooldown, including ones the user/CDM marked "Not Displayed" — `info.isKnown` does not exclude them. `Enum.CooldownViewerCooldownFlag` isn't addon-exposed; test the literal bit (`bit.band(info.flags, 0x2) ~= 0` = hidden).
- **A cache keyed only by spec *index*** (not spec ID) **collides across classes** that share an index (e.g. Guardian Druid and Shadow Priest are both spec-index 3) — key any per-spec cooldown cache by spec ID.
- **Dynamic/linked cooldowns** (`linkedSpellIDs` non-empty, e.g. Flying Serpent Kick / Wild Charge) represent several per-form spell variants; resolving via the child frame's `GetSpellID()` returns one arbitrary currently-active variant. Prefer the cooldown info's `overrideSpellID or spellID` as the representative spell.
- Never let an empty read (0 spells) destructively overwrite an existing populated interface — guard with a `#spells==0` check and a bounded retry before wiping.

### Patch 12.1 Readiness (`core/Compat121.lua`)

*(This is the section `core/Compat121.lua` cross-references by name. Keep it in sync.)*

The `.toc` ships one build for every supported interface version
(`120000..120100`), so every 12.1-only call needs a guard. `core/Compat121.lua`
is the single place those guards live — **detection and thin wrappers only; no
behaviour is switched on merely because a capability exists.** Callers opt in.
One place to read to answer "what does Wise do differently on 12.1?", and one
place to delete when 12.0.x support is dropped.

- **Probe the capability, not the template name.** `CreateFrame` with an unknown
  template does **not** throw — it silently returns an ordinary `Frame`
  (verified in wow-ui-sim 12.0.7). A name-only probe for `AuraContainerTemplate`
  therefore reports a **false positive on every 12.0.x client**, sending callers
  down the 12.1 path to fail at the first `AddAuraSlot`. `Compat.hasAuraWidgets`
  creates the frame and then checks `type(frame.AddAuraSlot) == "function"`.
  This generalises: for any new intrinsic, test the method.
- **`Compat.AreAurasSecret()` is deliberately conservative.** It prefers
  `C_Secrets.ShouldAurasBeSecret()`; the `InCombatLockdown()` fallback
  *over-reports* secrecy in open-world combat, where reads would have worked.
  Callers must treat `true` as "don't trust aura reads", **never** as "hide the
  UI" — over-reporting must cost accuracy, not function.
- **Aura widgets must be created and configured OUT OF COMBAT.**
  `AuraContainer`/`AuraButton` carry Forbidden Aspects while auras are secret
  (script handlers, event registration and input APIs all refuse tainted
  callers), so `Compat.CanUseAuraWidgets()` gates on `not InCombatLockdown()` as
  well as on the intrinsics existing. Showing/hiding afterwards is fine.
- **Why the widget route works where reads do not:** the client owns the number
  and renders it, so Wise never touches — and never taints — the aura record.
  Contrast the removed 12.0.7 slot-scan resolver (see Combat Aura Secrecy).
  By-spellID addressing is the access path that survives secrecy in 12.1; index,
  slot and instanceID lookups hard Lua-error while auras are secret.
- **`Compat.SetOnUpdateWhenVisible(frame)`** asks the client to stop dispatching
  a hidden frame's `OnUpdate` entirely (12.1 `SetOnUpdateMode`). It is a safe
  no-op pre-12.1, so **keep the handler's own early-return** (Rule 12 #5) rather
  than relying on it.
- `/wise compat` prints `Compat.GetReport()` — what this client actually
  supports, including `aurasSecretNow`.

### Self-Resource Secrecy (12.1) — measured 2026-08-31

**`UnitPower("player")` returns a SECRET NUMBER — in the open world, out of
combat, on your own character.** Established by `wiser/Cursor.lua`, a probe
module built specifically to settle the question.

- The prior expectation was that this would work, reasoning that
  `C_Secrets.ShouldAurasBeSecret()` concerns *aura* data and that 12.0 secrecy
  targets what you can learn about *other* units. **That reasoning was wrong:
  self-resource reads are secret too.** This is exactly the class of assumption
  the Abundance investigation warns about — verify, do not infer.
- The verdict is the API's, not a probe fault: `/wise cursor probe` calibrates
  `issecretvalue` against literals (`42`, `0`, `"hello"` and `nil` all report
  READABLE) before trusting its answer on `UnitPower`. Calibrate any future
  secrecy probe the same way.
- UltimateMouseCursor gates its power *and* health rings behind
  `if CURRENT_API >= 120000 then return end`, disabling both outright on 12.x.
  That blanket version gate turns out to be **correct**, if bluntly implemented.
- **Consequence: no addon-side numeric read of self-resources works in 12.1** —
  no amount of `pcall` hygiene helps, because the number never reaches addon
  code. **But the display path WORKS** (confirmed live 2026-09-01):
  `StatusBar:SetMinMaxValues`/`SetValue` accept the raw secret numbers and the
  client renders the fill correctly — `/wise cursor bar` is the working proof.
  So a resource display IS buildable, but **only as pass-through**: hand the
  secret to a widget and never inspect it. No percent math, no thresholds, no
  value-derived colours — anything needing the number itself stays impossible.
  (Survival inside instanced content — delve/M+ — is still untested.)
- `wiser/Cursor.lua` reads **only** `"player"` resource state and performs no
  aura scan, deliberately: the 12.0.7 taint storm came from scanning shared aura
  records. Do not extend it to aura reads without revisiting that history.

**`issecretvalue` is the only reliable secrecy test.** A `tostring`→`tonumber`
round-trip does **not** detect a secret — `tostring` returns a *secret string*
that explodes on the next comparison. An **error from `issecretvalue` means "no
answer", not "secret"**. And there is no safe `v == nil` pre-check: even
comparing a true secret can throw, so the round-trip goes inside the `pcall`.
See also "Numeric Taint Stripping".

### Custom Conditionals: the Three-Table Rule

Wise implements ~58 visibility tokens WoW's secure state driver does not
understand (`[bank]`, `[mailbox]`, `[zoneability]`, `[undermouse]`,
`[available]`, plus ~35 ported from OPie: zone, instance/in, race, buff/debuff,
moving, ready, combo, and so on).

- **Three tables must agree, and only one of them actually dispatches.**
  `CUSTOM_VIS_CONDITIONALS` (`core/GUI.lua`) is the authority — a token **must**
  be listed there to have any effect. `VALID_CONDITIONALS`
  (`core/Conditionals.lua`) accepts/rejects in the editor, and
  `extendedConditionals` is the displayed reference list. **A token present in
  the latter two but missing from the first passes validation, falls through to
  `SecureCmdOptionParse`, and silently evaluates false forever** — the options UI
  advertises a conditional that does nothing. This has shipped once already (a
  branch reset lost the evaluator while leaving the UI lists intact). When adding
  or removing a token, edit all three.
- **Do not add a token for something an existing one can express.** `[delve]`
  began as its own token and was folded into `instance`/`in` as a synonym
  (`[instance:delve]`, `[in:delve]`, via `C_DelvesUI.HasActiveDelve`): a second
  token for "narrow down scenario content" meant authors had to know about two
  overlapping tokens, and the options tab showed two rows for one underlying
  state. `[instance:scenario]` still matches all scenario content, delves
  included.
- **Never list a conditional that is not implemented.** `[cleanse]`, `[near:]`
  and `[bar:n]` were advertised but never built, and were dropped rather than
  left as false advertising.
- **Negation is not universal.** `NegateConditional` must not emit
  `[nobonusbar:5]` — `bonusbar` has no negation prefix in WoW macros, and the
  invalid token poisons the whole condition string.
- **Combat freeze/thaw:** tokens whose inputs cannot be read in combat are
  *sampled* at `PLAYER_REGEN_DISABLED` and frozen for its duration
  (`Wise.SampleCombatConditionals`), then released at `PLAYER_REGEN_ENABLED`.
  Each `pcall` is isolated so one bad token cannot break combat entry.
- **`[available]` is provider-backed.** A module owning a dynamically-populated
  interface registers `Wise:RegisterAvailabilityProvider(groupName, fn)`;
  interfaces with no registered provider report available whenever they hold any
  action, so `[available]` stays meaningful on ordinary bars too.

### Indicator Rules and Withdrawn Features (`modules/IndicatorRules.lua`)

Per-action rules (`action.indicatorRules`: operator/value/color/glow/sound)
matched against that action's own live state — the generalisation of the old
global, Resto-only "Abundance Colors, Glows & Sounds".

- **"Aura stacks" is deliberately absent from the metric list.** Under combat
  secrecy a stack count is *displayable but not inspectable*, so a stacks-driven
  colour/glow/sound can never fire in combat — the only time it would matter.
  **Shipping it would produce an indicator that silently does nothing in a raid,
  so the option is withdrawn rather than shipped broken.** The stack count still
  *displays* on the button corner; only branching on it is gone. Everything
  cooldown- or usability-derived (charges, available, on-cooldown, buff
  active/missing) reads fine in combat and is unaffected.
  **Do not "restore" the stacks metric** without first proving a readable source.
- `Wise.INDICATOR_RULES_REV` is bumped on behaviour changes so an in-game probe
  can confirm which revision the client actually loaded — invaluable when a fix
  appears not to work and the real cause is a stale load.

### Gamepad / ConsolePort Support (`core/Bindings.lua`)

- **`Bindings.xml` is deliberately absent from `Wise.toc`.** The client
  auto-loads any root-level file named exactly `Bindings.xml` for every enabled
  addon, independent of the `.toc` — listing it there would register the bindings
  **twice**. It declares `BINDING_HEADER_WISE`/`BINDING_NAME_*`, which both
  Blizzard's Key Bindings UI (including its Gamepad tab) and `ConsolePort_Config`
  read from the same globals.
- **`Wise:StartKeybindCapture` is the single capture path** (keyboard, mouse,
  mousewheel, gamepad), centralised from several duplicated call sites in
  `modules/Properties.lua` so gamepad capture only needed adding once. New
  binding widgets go through it rather than re-implementing capture.
- **`SetScript(..., "OnGamePadButtonDown", ...)` is wrapped in `pcall` in the
  addon itself, not just in tests.** Real WoW and ConsolePort both rely on that
  handler existing on any frame, but **wow-ui-sim rejects it as an invalid script
  handler** — the pcall makes gamepad capture degrade to keyboard/mouse under the
  sim instead of throwing. `EnableGamePadButton(true)` itself needs no guard.
- **`Wise:RegisterConsolePortFrame(f)`** adds a frame to ConsolePort's virtual
  cursor stack. It is safe to call unconditionally and at any time — including
  before ConsolePort has loaded, or when it is not installed at all.
  `Wise.HasConsolePort` exists for gating ConsolePort-*specific* extras (such as
  icon glyphs), not for this call.

### Disenchant/Convert (`wiser/DisenchantConvert.lua`)

A wiser interface that queues bag items worth destroying, priced from whichever
auction-house data addon is present.

- **Pricing is provider-ranked and every provider is optional:** `TSM_API` →
  `PP` (ProfitProphet) → `Auctionator`, each detected by probing for the actual
  function (`TSM_API.GetCustomPriceValue`, `PP.Destroying.deValueOf`,
  `Auctionator.API.v1`), with every call `pcall`-wrapped. The interface must stay
  functional with none of them installed.
- **Salvage spells are per-expansion, and batch sizes changed.** The base
  Prospecting/Milling spells no longer work on current-expansion ore/herbs, so
  the spell IDs are keyed by expansion. **Milling consumed 5 through
  Dragonflight but eats 10 in TWW and Midnight** — a hardcoded 5 silently
  under-counts what a cast will consume.
- **The reagent bag is NOT covered by `NUM_TOTAL_EQUIPPED_BAG_SLOTS`.** Scanning
  `BACKPACK_CONTAINER..NUM_TOTAL_EQUIPPED_BAG_SLOTS` misses it entirely; append
  `Enum.BagIndex.ReagentBag` explicitly.
- Equipment-set protection and the `ignoreMarket` filter exist so the queue can
  never propose destroying gear the player has assigned to an equipment set.
- Each slot is a secure button written **out of combat only**, and the queue
  refreshes on coalesced events rather than a ticker (Rule 12).

## Performance
- **In-game profiler:** `/wise cpu start`, play/idle ~30s, then `/wise cpu` reports a time-boxed CPU delta for Wise-owned frames (split into "in frames" vs "elsewhere"). Requires the `scriptProfile` CVar (the command enables it + prompts a reload on first use). This is the source of truth for idle cost — addon-CPU displays misattribute `UIParent`/child time to whichever addon parents those frames.
- **Design rule:** Updates are event-driven, not ticker-polled — see Rule 12. The central `DynamicRefreshDriver` (`core/GUI.lua`) is where dynamic-group refresh events are registered; add new triggers there rather than introducing tickers.
- **Baselines:** Use `mcp__mechanic__perf-baseline` to record memory/CPU baselines after stable releases. Use `mcp__mechanic__perf-compare` to check for regressions against the baseline after changes.
- **Reports:** Use `mcp__mechanic__perf-report` to view performance history and trends.
- **Call-graph profiling:** when `/wise cpu` says *that* something is expensive but not *what*, instrument with Perfy (`tools/perfy-profile.ps1`, workflow in `tools/README-profiling.md` and the Perfy section above). Restore with `-Restore` when done — instrumentation rewrites source files in place.

## Research
- **Web Search:** Use `mcp__mechanic__research-query` to search the web for addon development information, WoW API behavior, and best practices when documentation is insufficient.
- **SavedVariables:** Use `mcp__mechanic__sv-parse` to extract data from WoW SavedVariables files after game sessions for debugging or data analysis.
