# WoW Forever Port Plan

Target client: **WoW Forever beta 1.60.1.70009**, interface **`16001`**, codename
**Camelot**. It is installed alongside retail at
`C:\Program Files (x86)\World of Warcraft\_classic_beta_` (Battle.net product
`wow_classic_beta`). Launch is 2026-11-04. The install path may change at launch.

Written 2026-09-26. Phases 1–2 were implemented the same day. Phase 0's
`/wise client` checks passed in-client that evening; the manual checks are still
pending. Phase 3 has its two measured bugs fixed (class IDs and loadout type).
Phase 5 has its AGENTS.md section.

Sources:
- Blizzard UI source, `forever` branch: https://github.com/Gethe/wow-ui-source/tree/forever
  (1.60.1 (70009), 2026-09-24). This was diffed against the cached live 12.1.0 tree.
- https://news.blizzard.com/en-us/article/24304160/the-world-of-warcraft-forever-beta-now-live
- https://github.com/McTalian-WoW-Addons/RPGLootFeed/pull/617 (interface 16001)
- https://github.com/Thunderz96/forever-addon-kit (third-party porting notes, **unverified**)
- https://github.com/BigWigsMods/packager/pull/202 (packager Forever support)

---

## What Forever is, for Wise's purposes

Forever is **not a Classic client**. It runs the modern Mainline UI and API: Edit
Mode, CooldownViewer, `C_Secrets` combat secrecy, DurationObjects and `C_*`
namespaces. A diff of the generated API docs found that only **15** documented live
12.1 APIs are missing on Forever. Wise uses **none** of them. **None** of the ~50
events Wise registers is missing either. So this is a narrow port. Three things
break:

1. **Retail's deprecation shims don't load.** Forever's game type is `camelot`.
   TOC gates written `mainline` / `standard` exclude it, so the whole
   `Blizzard_Deprecated*` family is absent. Examples are
   `Blizzard_DeprecatedSpecialization` (`## AllowLoadGameType: classic, standard`)
   and `Blizzard_DeprecatedItemScript`/`CurrencyScript` (not shipped). Bare globals
   such as `GetSpecialization`, `GetSpecializationInfo`, `GetItemCount`,
   `GetItemInfo`, `IsEquippedItem`, `GetItemIcon` and `GetCoinTextureString` are
   therefore **nil**. The namespaced functions they aliased (`C_SpecializationInfo.*`,
   `C_Item.*`, `C_CurrencyInfo.*`) exist on **both** clients with identical
   signatures, because the shims were plain `X = C_Foo.X` aliases.
   *This is a latent retail bug too:* on retail those shims load only while the
   `loadDeprecationFallbacks` CVar is on.
2. **The interface number reads as ancient.** `select(4, GetBuildInfo())` is `16001`,
   so every `>= 1xxxxx` gate decides "old client". `WOW_PROJECT_ID` is
   `WOW_PROJECT_MAINLINE` (1), measured in-client, so the project ID cannot tell
   Forever from retail.
3. **Content differs.** There are 9 classes with **non-contiguous IDs** (1–5, 7–9,
   11; measured). Each class has one class-named "spec" with a new ID (Druid =
   1484, measured). Talent configs use `Enum.TraitConfigType.CamelotCombat` (4,
   measured). Spells have ranks. There is a `MultiCastActionBarFrame` totem bar.
   Retail-only systems (delves, M+, housing) exist as API but are inert.

---

## Phase 0 — In-client verification (run first)

### Results: measured in-client 2026-09-26, build 1.60.1 (70009), Druid

These come from `WiseDB.clientReports`, which `/wise client` writes to
`_classic_beta_\WTF\Account\<account>\SavedVariables\Wise.lua`.

| Check | Result |
|---|---|
| Identity | interface `16001`, `WOW_PROJECT_ID=1` (**confirmed** mainline), `IS_FOREVER=true`, experience preset `Modern` (1), `Enum.GameMode.Standard` = 1 |
| SavedVariables round-trip | **Works.** The counter went 1 → 2 across `/reload`. The third-party "never read back" report does not apply to 70009. |
| Retail shim globals | **All absent**, confirming the Phase 1 premise |
| Undocumented natives Wise calls bare | **34/34 present** |
| `HAS_IGNORE_GCD` | `true` |
| Spec | Index 1, ID **1484**, name **"Druid"**: Forever has one class-named "spec" per class. `C_SpecializationInfo.IsSpecSelectionEnabled()` **throws** when called with no args (not used by Wise). |
| Classes | `GetNumClasses()` = **9**, but the IDs are **1–5, 7–9, 11** (no 6 = DK). A `1..GetNumClasses()` loop **skips Druid** and visits the nil hole at 6. **Fixed**, see Phase 3. |
| Talent config | Active config type **4 = `CamelotCombat`**; `Combat` = 1. **Fixed**, see Phase 3. |
| Frames | All present, **including `ZoneAbilityFrame`** (despite the `mainline` TOC gate) and `MultiCastActionBarFrame` |

Still to do: the manual checks in step 4 below.

Deploy: `_classic_beta_\Interface\AddOns\Wise` is a **junction** to `_dev_\Wise`,
the same pattern as retail, so dev edits are live on `/reload` in both clients.

1. Log in and run **`/wise client`**. It prints the checks below and bumps a
   SavedVariables counter.
2. `/reload`, then run **`/wise client`** again. **The run counter must have gone
   up.** A third-party report says the beta client writes SavedVariables and never
   reads them back. If the counter resets, that is a client bug that blocks every
   addon, and Wise cannot fix it.
3. Read the report:
   - `IS_FOREVER` should be `true`. Check the build and interface, `WOW_PROJECT_ID`
     and the Forever-only `C_GameRules.GetForeverExperiencePreset`.
   - Retail shim globals such as `GetSpecialization` and `GetItemCount` should read
     **nil**. That confirms the Phase 1 premise.
   - The undocumented natives Wise relies on (`GetClassInfo`, `GetNumClasses`,
     `GetSpecializationInfoByID`, `GetFlyoutInfo`, ...) should read present. Any
     `MISSING` line is a new Phase 3 item.
   - Current spec index and ID, and whether spec selection is enabled.
   - The active talent config's `TraitConfigType`. Expect `CamelotCombat`, which
     is the Phase 3 loadout fix.
   - Which class IDs return nil from `GetClassInfo`.
   - Whether `ZoneAbilityFrame`, `MultiCastActionBarFrame`, `MainActionBar` and
     `OverrideActionBar` exist.
4. Manual checks:
   - Put a ranked spell such as Fireball on a Wise bar. Casting should use the
     **highest** rank, because spell buttons cast by name
     (`core/GUI.lua` `secureValue = castName or ...`).
   - Open Options and the Slot Configurator. Test a spec-filtered action, an item
     with a count, a macro and a mount. Hide the Blizzard bars. Enter Edit Mode.
     Fight a mob to test secret cooldowns.
   - Capture any Lua errors. Reportedly the client stops delivering errors after
     100 in a session, so fix from the first error down.

## Phase 1 — Load blockers  ✅ implemented

1. **TOC**: `16001` was added to `## Interface`. This stays a single TOC: no
   `_Camelot.toc`, because Blizzard hasn't confirmed a suffix and the packager
   dropped its detection (PR #202). The retail client ignores the extra number.
2. **Shim globals → namespaced APIs.** Files that already cached the function at
   file scope now use `local X = C_Foo and C_Foo.X`: nil-safe at load under the
   standalone harness, with **no** bare-global fallback, since that fallback is what
   the luacheck guard catches. Other call sites call `C_Foo.X(...)` inline. Two dead
   fallbacks in `modules/Actions.lua` were deleted: bare `GetItemInfo` after
   `C_Item.GetItemInfo`, and bare `GetItemIcon` after `C_Item.GetItemIconByID`. On
   retail the shim was the same function, so they could never succeed where the
   first call failed; on Forever they would have thrown. Nothing is written into
   `_G`, because defining globals from addon code taints any Blizzard caller
   (AGENTS.md Rule 8).
   - Specs, 56 call sites: `Wise.lua`, `core/Conditionals.lua`, `core/Filters.lua`,
     `core/GUI.lua`, `modules/Actions.lua`, `modules/BugReport.lua`,
     `modules/Macro.lua`, `modules/Properties.lua`, `modules/Tooltips.lua`,
     `wiser/Cooldowns.lua`, `wiser/SpecAndEquip.lua`.
   - Items and currency: `core/GUI.lua` (`GetItemCount` ×6),
     `modules/Actions.lua` (`GetItemCount`, and the dead `GetItemInfo`/`GetItemIcon`
     fallbacks), `modules/Macro.lua` (`GetItemInfo`), `wiser/SmartItem.lua`
     (`GetItemCount`, `IsEquippedItem`), and `wiser/vdc/Actions.lua` and
     `wiser/vdc/Slots.lua` (`GetCoinTextureString`).
3. **Regression guard**: `.luacheckrc` strips these names from the generated
   `WoWGlobals.luacheckrc` list, which must not be hand-edited, so luacheck flags any
   reintroduction as an undefined global.

## Phase 2 — Interface-number gates  ✅ implemented

1. **`core/Client.lua`** (new, loads before `Wise.lua`) owns flavour detection:
   `Wise.IS_FOREVER` is true for interface 16000–19999 and either
   `WOW_PROJECT_ID == WOW_PROJECT_MAINLINE` or the Forever-only
   `C_GameRules.GetForeverExperiencePreset`. The same file hosts `/wise client`.
2. **`core/cooldown/SecretValues.lua`**: `HAS_IGNORE_GCD` gated on
   `INTERFACE_VERSION >= 120005` and so read **false** on Forever, even though
   Forever's `C_Spell.GetSpellCooldownDuration` documents `ignoreGCD`. Every button
   would have painted GCD swipes. It is now `>= 120005 or Wise.IS_FOREVER`.
3. **`Libs/exui/IconSelector.lua`** (vendored): `MODERN = COMPAT > 10e4` read false,
   so the icon picker dropped its icon masks and used the classic close-button
   layout. It now also accepts the mainline project ID. The change is marked as a
   local patch.

Rule going forward: **never compare the interface number to decide "modern client".**
Probe the capability, or use `Wise.IS_FOREVER` for genuinely Forever-specific
behaviour.

## Phase 3 — Content differences (partly done)

- **Class IDs** ✅ (2026-09-26): `Wise.Client.GetClassIDs()` (`core/Client.lua`)
  scans for real class IDs until it has found `GetNumClasses()` of them. It replaced
  `for i = 1, GetNumClasses()` in `modules/Properties.lua` (the Classes filter tree)
  and in `wiser/SpecAndEquip.lua` (the class-restriction label), plus the hardcoded
  `for classID = 1, 13` in `wiser/SpecAndEquip.lua` (the slot-class resolver).
  On retail it returns 1..13, identical to the old loops. Player-spec loops
  (`1..GetNumSpecializations()`) are unaffected.
- **Talent loadouts** ✅ (2026-09-26): the `wiser/SpecAndEquip.lua` loadout list
  now accepts `Wise.Client.IsCombatTraitConfigType(type)`, i.e. `Combat` or
  `CamelotCombat`. Needs an in-client check that saved Forever loadouts appear.
- **Specs**: Forever has one class-named "spec" per class (Druid = 1484). The spec
  UI will show a single entry, which is fine. Spec-restricted actions imported from
  a retail profile carry retail spec IDs and will be filtered out. Accept that and
  document it; each install has its own WTF.
- **Spell ranks**: casting is by name, so it is fine. Icon, cooldown and usability
  reads keyed on a stored low-rank ID may lag after training a new rank. Verify
  before building anything. `C_SpellBook.IsSpellBookItemLowRank` exists if needed.
- **Blizzard UI hiding** (`core/blizzui/Registry.lua`): `ZoneAbilityFrame`
  **does** exist on Forever (measured), so no change is needed. Consider a new
  toggle for `MultiCastActionBarFrame` (the shaman totem bar; exists on Forever). The Midnight puzzle-aura toggle
  is meaningless on Forever.
- **Retail-only content** (delves, M+, housing, the Abundance/Resto features):
  conditionals must return false rather than error. Optionally hide these options
  when `Wise.IS_FOREVER`.
- **Macro bodies** reportedly return with trailing whitespace. Audit the body
  readers in `modules/Actions.lua` for `$`-anchored patterns.

## Phase 4 — Testing

- **Retail regression (done 2026-09-26 for Phases 1–2)**:
  `wow-ui-sim:12.0.7 run-tests Wise` gives **81/90 on both HEAD and the patched
  tree**, with the same failing files. `copy_paste_nodes.lua` and `tooltips.lua` fail
  silently, and `test_vehicle_bar_fix.lua` has a load error. All three are
  **pre-existing**. The standalone `test_vehicle_bar_fix.lua` has been stale since
  the cooldown-primitive extraction: it loads `core/GUI.lua` without
  `core/cooldown/SecretValues.lua`, so `CooldownUtil` is nil. AGENTS.md's "82/82"
  figure is out of date. Under the retail sim, `/wise client` reports
  `IS_FOREVER=false`, `HAS_IGNORE_GCD=true`, 34/34 native globals present and no
  section errors. `core/Client.lua` was also exercised in a plain-Lua harness across
  Forever, retail, Classic Era and edge interface values. luacheck is not installed
  locally; the `.luacheckrc` filter was verified by evaluating the config (2248 → 2241
  globals).
- **In-client checklist**: `tests.xml` → `WiseDebugTest_ForeverClient`.
- **Forever**: wow-ui-sim has **no Forever profile**; its Cargo features are retail
  API epochs only. Building one from the Gethe `forever` branch is a separate
  project and not planned. Forever is verified in-client via Phase 0 plus a
  `tests.xml` checklist.

## Phase 5 — Ship and document

- **Packaging**: BigWigs packager v2.6.1 knows Forever as a CurseForge game version,
  but auto-detection by interface/suffix was removed pending Blizzard confirmation.
  After the first tagged build, confirm the file is tagged for Forever. If it is
  not, set it manually on CurseForge.
- **AGENTS.md**: the "WoW Forever (Camelot) Support" section and the Project Goal
  line are done. Correct them once `/wise client` has run in-client. CHANGELOG and
  README are still to do.

## Open decisions

1. **First-release scope.** The recommendation is Phases 1–2 plus the class-loop and
   `CamelotCombat` fixes from Phase 3. The rest can be follow-ups.
2. **Retail-only options on Forever**: hide them or leave them inert? The
   recommendation is to hide Zone Ability and Puzzle UI and leave the rest.
3. **Totem bar hide toggle**: yes or no?
