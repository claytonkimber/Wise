# Patch 12.0.5 / 12.0.7 API Modernization Plan

Branch: `feature/patch-12.0.5-api-modernization`
Live build at time of writing: **12.0.5.67823** (TOC bumped to include `120007`).

Sources:
- https://warcraft.wiki.gg/wiki/Patch_12.0.5/API_changes
- https://warcraft.wiki.gg/wiki/Patch_12.0.7/API_changes

Every item is guarded by a capability check (`if API and API.NewThing then`) so the
addon still loads and behaves correctly on pre-12.0.5 clients. No hard dependency
on the new APIs.

---

## 1. `ignoreGCD` on cooldown-duration APIs  — HIGH value, contained

**What changed:** `C_Spell.GetSpellCooldownDuration(spellID, ignoreGCD)` and
`C_ActionBar.GetActionCooldownDuration(slot, ignoreGCD)` gained a second arg. When
`true`, the returned DurationObject excludes the GCD sweep.

**Where:** `core/GUI.lua:7249-7340` (the spell branch and its visual-clone mirror).

**Current behavior:** We read `cdInfo.isOnGCD`, then *if* `isOnGCD and not showGCD`
we `clearCD()`; otherwise we paint the full duration (which includes the GCD).

**Plan:**
- When `showGCD == false`, call `GetSpellCooldownDuration(spellID, true)` and paint
  that object directly. No GCD detection, no `clearCD` branch, no swipe re-paint
  churn from GCD ticks.
- When `showGCD == true`, keep the existing call (`ignoreGCD` omitted / `false`).
- Keep `isOnGCD` only for the swipe-*color* dimming (7266-7272) — that's cosmetic
  and still wants to know "is this just a GCD".
- Capability guard: detect arg support once at load via a feature flag
  (`Wise._hasIgnoreGCD`), since we can't introspect arity. Probe by calling with the
  arg inside pcall on a known spell at login, or just gate on the 120005 interface
  number from the TOC/`select(4, GetBuildInfo())`.

**Risk:** Low. Pure read API. Fallback is current code path.

---

## 2. Zero-span duration object when fully charged — MED value

**What changed:** `C_Spell.GetSpellChargeDuration` / `C_ActionBar.GetActionChargeDuration`
return a **zero-span** DurationObject at max charges, and zero-span objects are now
"considered fully elapsed."

**Where:** `core/GUI.lua:7274-7340` (charge branch + clone mirror), and the manual
`cooldownStartTime`/`cooldownDuration` reads at 7280-7289.

**Plan:**
- Stop reconstructing `start`/`duration` from `chargeInfo` just to decide whether to
  paint. Hand the charge DurationObject straight to `SetCooldownFromDurationObject`;
  a fully-charged spell now yields a zero-span object the frame renders as empty.
- Removes two `SafeReadField` + two `CleanSecretNumber` calls per charge button per
  update — less secret-number laundering (see memory `wow-taint-stripping`).
- Keep the numeric `start`/`duration` capture **only** if the countdown-text tracker
  still needs it (see item 3 — may become moot).

**Risk:** Low-med. Verify a 2-charge spell at full charges shows no swipe, and a
partially-recharging one shows the recharge sweep.

**OUTCOME (implemented):** No behavioral change was warranted. The charge branch
already hands the DurationObject straight to the Cooldown frame, so zero-span-at-max
renders empty automatically — there was never a manual "fully charged → clear" branch
to delete. The `SafeReadField`/`CleanSecretNumber` reconstruction is NOT dead: those
numbers feed the swipe-repaint cache (skips redundant repaints) and the countdown
tracker, not the render. Removing it would INCREASE repaints. Resolved as a comment
documenting the zero-span guarantee; code left intact.

---

## 3. Native countdown formatters — MED/HIGH value (CPU)

**What changed:**
- `Cooldown:SetCountdownFormatter(formatter)` / `GetCountdownFormatter`
- `Cooldown:SetCountdownMillisecondsThreshold(ms)` — sub-threshold times show one
  decimal place
- `C_StringUtil.CreateSecondsFormatter`, `CreateAbbreviatedNumberFormatter`,
  `CreateNumericRuleFormatter`
- `DurationObject:FormatRemainingDuration` / `FormatElapsedDuration` / `FormatTotalDuration`

**Where:**
- The per-frame countdown loop: `Wise.CooldownUpdateFrame:SetScript("OnUpdate", ...)`
  at `core/GUI.lua:736-870+`. Today it iterates every active button each frame,
  `pcall`s arithmetic (`ComputeCooldownRemaining`), and falls back to Blizzard's
  built-in countdown in combat (`_wiseBlizzCDActive`, 818-836).
- CooldownWiser viewers (`wiser/Cooldowns.lua`).

**Plan (phased):**
- **3a.** Build a shared `SecondsFormatter` once (respecting `countdownTextSize` /
  position is unaffected — formatting is text only). Configure decimals via
  `SetCountdownMillisecondsThreshold`.
- **3b.** For buttons using Blizzard's native countdown FontString (the combat path
  we already reparent at 822-836), call `SetCountdownFormatter` so the native text
  matches our style — and let the frame drive its own text. This lets us **stop
  running the OnUpdate arithmetic for those buttons**, shrinking the hot loop.
- **3c.** CooldownWiser: route viewer countdown text through the same formatter.
- Keep the manual loop as the pre-12.0.5 fallback (capability-gated).

**Risk:** Med. This touches the most performance-sensitive loop. Do it last, behind a
flag, and A/B with `/wise cpu`. Visual parity (decimals under N seconds, abbreviation
for minutes) must be verified against current look.

---

## 4. Restored CPU profiling functions — LOW effort, dev-only

**What changed (12.0.7):** `GetFunctionCPUUsage()`, `GetScriptCPUUsage()`,
`GetEventCPUUsage()` restored.

**Where:** `/wise cpu` harness — `Wise.lua:2381-2487` (currently `debugprofilestop()`
+ `UpdateAddOnCPUUsage()` + `GetAddOnCPUUsage`, whole-addon granularity only).

**Plan:**
- Add an optional per-function / per-script breakdown to `/wise cpu` and the
  combat-enter probe, so we attribute a hitch to a specific function, not just "Wise."
- Strictly dev tooling; capability-gated, no player-facing change.

**Risk:** None (diagnostics only).

---

## 5. `SpellIdentifier` typing + secret-rename hygiene — LOW, audit only

**What changed:**
- `C_ActionBar.FindSpellActionButtons` / `HasSpellActionButtons` / `IsOnBarOrSpecialBar`
  now take a `SpellIdentifier` (name/link/ID) instead of bare number. **We don't call
  any of these today** (grep: 0 hits) — note for future use, no action.
- Secret restriction renames: `SecretWhenSpellCooldownRestricted` →
  `SecretWhenCooldownsRestricted` on `GetSpellCooldown/Charges/CastCount/...`.
  Behavior identical. Our `CleanSecretNumber`/`SafeReadField` wrappers already handle
  the values; just confirm nothing keys off the old annotation name.
- **12.0.7 button-state secrets:** `Button:GetButtonState`/`IsEnabled` gained
  `Enum.SecretAspect.ButtonState`. Audit any non-secure read of a secure button's
  state in combat.

**Risk:** Low. Mostly verification.

**OUTCOME (audited, no changes needed):**
- `SecretWhen*` annotation names: 0 references in Wise code. Values are read through
  `SafeReadField` / `CleanSecretNumber`, which are annotation-name-agnostic — the
  rename is transparent to us.
- `GetButtonState`: 0 call sites anywhere in Wise.
- `IsEnabled()`: only 2 hits, both in the exui lib — `DropDown.lua:14` (insecure
  dropdown widget, mouse-click) and `ScrollBar.lua:197` (a method *definition*).
  Neither reads a secure action button's state in combat.
- Net exposure to the 12.0.7 button-state secret change: none. (The earlier "18 hits"
  estimate was a miscount — it was the combined grep dominated by the safe
  SafeReadField/CleanSecretNumber wrappers, not real button-state reads.)

---

## Sequencing

1. **Item 4** (CPU profiling) — trivial, unlocks measurement for item 3.
2. **Item 1** (`ignoreGCD`) — contained, high value, easy to verify.
3. **Item 2** (zero-span charges) — contained, builds on item 1's branch edits.
4. **Item 5** (audit) — verification pass.
5. **Item 3** (native formatters) — last, behind a flag, measured against item 4.

Each item = its own commit. Test via `mcp__mechanic__addon-test` / busted where the
logic is unit-testable; live-verify the cooldown visuals in-game.

---

## Deferred / separate task

**Hide-interface-on-puzzle-game (priority: tertiary / nice-to-have).** Goal: hide
Wise bars + native UI while a quest puzzle-game is open, restore on close.

Findings (2026-06-16, "Unravel the Magical Ward", Unraveling quest):
- The puzzle does NOT create a new named frame, and a *visibility* diff of existing
  named frames showed only nameplates + `Angleur_ToyBoxOverlay` going hidden — i.e.
  the puzzle UI is a UIWidget / anonymous-pooled / fullscreen overlay, not a hookable
  named frame. Frame-chasing is a dead end here.
- The reliable signal is an AURA on the player named **"Unravel the Magic Ward"**.
  Present during the puzzle, removed when it ends.

Planned hook (when revisited): on `UNIT_AURA`(player), if the player has that aura's
spellID → call Wise's existing combat-guarded hide path (`Wise.lua:2002-2059`,
`BlizzardFrames` + reparent); on removal → restore. ~15 lines, taint-free.
TODO: capture the aura's spellID (`/dump AuraUtil.FindAuraByName("Unravel the Magic Ward","player")`).

Note: most in-game minigames already hide the UI themselves, so this is low urgency.
