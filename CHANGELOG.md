# Changelog

Sorry for the long gap between updates — real life, work, and holidays kept me away from this for a while. Back on it now.

## [1.0.20260722] - 2026-07-22

### Fixed
- **Proc glows no longer pulse oversized — and now look exactly like Blizzard's.** Two systems shared one glow overlay per button with no ownership: the indicator-rules engine called `HideOverlayGlow` unconditionally on every coalesced pass (any button without a matching rule — e.g. Regrowth on a Guardian, whose Abundance rule never matches in bear form), destroying the proc engine's glow on every aura/cooldown event; the proc engine then re-attached it and replayed the entrance animation, whose outer glow starts at ~2.8x the button. Show/Hide now carry an owner tag (`proc`/`rule`/`generic`) and the overlay is only torn down when no owner still wants it.
- **Glow visual modernized** from the legacy Wrath-era spark/ants overlay (LibButtonGlow adaptation) to Blizzard's current `ActionButtonSpellAlertTemplate` flipbook: one start burst, then a steady 1s loop at 1.4x button size — identical to the default action bars. Proc end hides instantly (as Blizzard does) instead of fading, and transient parent hides pause/resume the loop in place instead of tearing down and re-popping. Also removes the per-frame `OnUpdate` ants animation per active glow (small combat CPU win).

## [1.0.20260707] - 2026-07-07

### Fixed
- **Cooldown swipes / usability tint restored on graph-compiled buttons.** 12.0.7 broke name-based spell resolution for talent/passive spells, so `ResolveMacroData` returned nothing for compiled macros and `meta.spellID` was nil on every slot-configurator button — no cooldown swipe, no usable/OOM tint on the whole kit. Compiled states now resolve their spell from the SOURCE graph node's numeric id (`Wise:ResolveCompiledStateSpellID`, walking the step's path leaf→root) whenever macro-text resolution fails.
- **Sequence/waterfall slot icons no longer freeze during combat.** The event dispatcher deliberately schedules no dynamic refresh in combat (perf, `1ac54d4`), so a sequence slot's icon stopped tracking the secure `isa_seq` pointer mid-fight — the press cast the RIGHT next spell but the button showed a stale one all fight. A press-scoped PostClick hook now resyncs that button's group on the next frame; all secure writes stay self-guarded (`canSetAttrs`), so this is combat-safe and costs nothing while not pressing.
- **Indicator rules stopped lying in combat.** 12.0.7 hides rotationally-relevant player auras (e.g. Abundance's buff 207640) from ALL addon reads during combat — by id, by name, and from enumeration (verified live 2026-07-05). Stacks were silently read as 0, which lit the `<=N` rule red for entire fights and made `>=N` sounds impossible. Hidden now means UNKNOWN: numeric stack rules and buff-missing rules no longer match on unreadable data.
- **In-combat Abundance counter via the sanctioned display API (experimental).** The buff's `auraInstanceID` is learned while it is visible (prehot Rejuvs before the pull) and kept for the fight; in combat the counter is driven by `C_UnitAuras.GetAuraApplicationDisplayCount` — whose secret string goes straight into `SetText` — and rule thresholds by its `minDisplayCount` nil/non-nil signal (self-validated once per session with an impossible `min=999` probe; disabled if the API misbehaves). Every step is pcall-guarded and degrades to the previous hide-the-count behavior. The `>=8` stack sound can fire in combat again **if** the live client honors these APIs — pending the armed Mechanic probe run.
- Corrected the Abundance cast→buff seed to the live client's buff id **207640** (the old `203864` was stale data from an older client and never matched).

## [1.0.20260705] - 2026-07-05

### Fixed
- Action picker usage dots: spells used on slot-configurator graph nodes now clear their dot again. Graph-authored slots compile every node into `misc/custom_macro` states, so `GetActiveRotationSpells` never saw them as plain spell states — every used spell showed the yellow "referenced in a macro" dot (or red when the compiled macro line didn't name-match). The collector now also walks `slotStates.graph.nodes` and registers node spells as bound.
- Indicator rules button matching hardened: `ButtonEntry` also scans a multi-state slot's sibling states (spell value and macro text), so an indicator stays bound if the shown state flips to a step whose macro doesn't mention the ruled spell.
- Indicator rules learn the buff's real aura id from the first successful lookup (persisted as `action.trackedAuraID`) instead of querying the CAST spell id (Abundance casts 207383; the buff is a different id). This restored the counter **out of combat** — in-combat reads turned out to be blocked entirely by 12.0.7 (see 1.0.20260707 above).

## [1.0.20260702] - 2026-07-02

### Fixed
- Audio Cue "Spell ready" trigger now gates on `C_Spell.IsSpellUsable` (matching the IndicatorRules "available" metric) instead of an off-cooldown-only check. A proc-gated override like Maul→Raze reports not-usable while its proc is down, so the cue no longer fires almost constantly on the low-cooldown base spell.
- Charge count text no longer shows a permanent "1" on single-charge spells (e.g. Mangle). Spells are only treated as charge spells when `maxCharges > 1`, matching Blizzard's default action-button convention.

## [1.0.20260619] - 2026-06-19

### Changed
- Slot configurator (Nodes view): connecting two action nodes is now **click-to-connect** instead of drag-and-drop. Click a node's connection dot to arm it (a line follows the cursor), then click the target card to connect. Click empty canvas — or the armed dot again — to cancel. This prevents the previous issue where a mid-drag release could strand a connection off-screen.

## [1.0.20260618] - 2026-06-18

### Changed
- Reworked the action filter into a cumulative scope waterfall: **All → Class → Spec → Build → Character**. Each level shows everything usable at that scope or broader, mirroring runtime visibility (Role remains as an orthogonal cross-cutting filter). The former "Talents" filter is now "Build".

### Added
- New `build:<configID>` visibility tag binding an action to a specific talent loadout; visible only while that loadout is the active config (`Wise:MatchesRestrictionTag`).
- `Wise:GetActionScopeRank` derives an action's scope tier purely from its `visibilityEnable` tags, so legacy configs sort correctly with no data rewrite.

### Fixed
- One-time, idempotent backfill (`scopeWaterfallBackfillV1`) runs every saved interface through the canonical migrator so pre-tag/imported actions gain equivalent scope tags and never break under the new waterfall.
- The Character filter is now exclusive: it shows only actions explicitly pinned to the current character (`char:` tag or legacy character category) instead of every unrestricted action, so "Char" is no longer a near-duplicate of "All".

## [1.0.20260423] - 2026-05-31

### Fixed
- Bypassed class restriction checks for actions with global category (such as custom macros, toys, mounts, items, and neutral spells like Single-Button Assistant), ensuring they properly display under toon-scoped filters (Class, Role, Spec) for all characters.

## [1.0.20260423] - 2026-05-31

### Fixed
- Restricted spec: tags in roleTagDecision to specs belonging to the player's class to prevent spells from other classes (e.g. Starfall) from appearing under the Role filter.


## [1.0.20260423] - 2026-04-23

- [Feature] Add Buff and Debuff wipe interfaces with tracking and configuration
- [Feature] Add ability to name individual slots
- [Feature] Overhaul Addons wiser interface with functional action and properties integration
- [Feature] Add cooldown timer swipes to Cooldown wiser interfaces
- [Feature] Support WoW 12.0.5 (TOC Interface: 120000, 120001, 120005)
- [Fix] Honor `visibilityEnable` tags over spellbook autoclassification in class, role, and spec filters
- [Fix] Fix duplicate spell entries surfacing in Cooldown wiser
- [Fix] Fix utilities and cooldowns not repopulating correctly when swapping specs
- [Fix] Additional taint stripping hardening in core and Cooldown wiser paths

## [1.0.20260404] - 2026-04-04

- [Feature] Add "Addons" Wiser Interface for browsing and launching addon configuration panels
- [Feature] Implement DataBroker and Addon configuration categories in Action Picker [WIP]
- [Feature] Add Edit Mode Layouts Wiser interface with layout switching support
- [Feature] Add Edit Mode layout options to UI Visibility controls
- [Feature] Add option to selectively hide UI during puzzle events (e.g., Delves puzzles) [WIP]
- [Fix] Fix Smart Item tool breaking due to regression
- [Fix] Fix skyriding spells not resolving correctly and spell counter display
- [Fix] Fix spell builder filter regression
- [Fix] Fix wipers not aligning to mask textures
- [Fix] Fix sizing issue in interface layouts
- [Fix] Disable hover highlights and scale effects for hidden empty slots
- [Fix] Fix hotkey display and partial visibility issues across multiple interfaces
- [Fix] Fix action visibility filter logic allowing cross-category restriction overrides
- [Fix] Fix ADDON_ACTION_BLOCKED errors by disabling Edit Mode modifications during combat
- [Changed] Rename "Override" bars to "Special Action" bars and reorganize miscellaneous items
- [Changed] Expand UI visibility button options
- [Chore] Comprehensive wiki documentation overhaul
- [Chore] Integrate Mechanic MCP tooling for addon lifecycle automation

## [1.0.20260327] - 2026-03-27

- [Feature] Add Enabled/Disabled Opacity controls (global in Settings + per-interface override in Properties)
- [Feature] Inactive interfaces can remain visible at reduced opacity instead of fully hiding
- [Feature] Secure gatekeeper supports opacity-based fade for inactive state (combat-safe)
- [Feature] Add "Empty Slot" option to Miscellaneous actions for explicitly clearing slots
- [Feature] Dynamic groups now track cooldown state changes to promptly add/remove slots
- [Fix] Default tooltips to enabled for new installs
- [Fix] Move Debug.lua outside packager debug block so DebugPrint is always available
- [Fix] Add no-op DebugPrint fallback in Wise.lua to prevent errors when Debug.lua is stripped
- [Fix] Fix Smart Item interfaces showing "corrupted or outdated data" by allowing actionless groups in validation
- [Fix] Fix error in RefreshActionsView when opening Smart Item interfaces with no actions table

## [1.0.20260325] - 2026-03-25

- [Feature] Adopt WoW 11.1+ DurationObject API for combat-safe cooldown swipes on spells
- [Feature] Extend press-and-hold trigger to all layout types, firing the hovered slot's action
- [Feature] Add charge-spell recharge tracking via `GetSpellChargeDuration`
- [Feature] Add "Explore Advanced Functionality" step to the tutorial before the finale
- [Fix] Harden cooldown countdown timer against secret numbers with pcall fallbacks
- [Fix] Prevent press trigger from toggling interface visibility instead of casting
- [Fix] Stop CooldownWiser interfaces from hiding actions that are on cooldown
- [Fix] Fix hover scale flicker by scaling icon/hotkey/count textures instead of the button frame
- [Fix] Fix line layout slot overlap on hover by raising FrameLevel
- [Fix] Tighten list layout button hit area to match visible content
- [Fix] Show "Slot Keybind" placeholder in properties when no slot is selected
- [Improve] Tutorial: smarter scroll indicator direction, better step targeting, sidebar auto-scroll, clearer hint text
- [Chore] Wrap debug files in `#@debug@` packager directives for clean releases

## [1.0.20260324] - 2026-03-24

- [Feature] Add Slot Configurator with visual condition picker
- [Feature] Add preliminary press-and-hold support for interface buttons
- [Perf] Optimize Bar Copy Tool by eliminating N+1 API pattern and reducing loop complexity
- [Perf] Improve mouseover performance
- [Fix] Squash multiple sources of taint across secure handlers
- [Fix] Fix single-button assistant sluggishness
- [Fix] Fix visibility filter not updating when selecting a different interface
- [Fix] Fix availability filters and global filters not applying correctly
- [Fix] Prevent deletion of dynamically loaded Wiser interfaces that would be repopulated

## [1.0.20260321] - 2026-03-21

- [Feature] Add Spec and Equipment Changer tool module to Wiser Interfaces
- [Feature] Implement two-column visibility restriction picker with plain English summaries and tree-like navigation
- [Perf] Optimize `Wise:GetTransportation` performance by caching `string.lower` results
- [Fix] Resolve override/vehicle bar icons and correctly hide empty bar slots
- [Fix] Add 'Leave Vehicle' button to Override bars category in the action picker
- [Fix] Fix UI text overlap and update terminology for availability filtering (Show/Hide rules)
- [Fix] Add robustness with nil checks for `C_EquipmentManager`, `C_ClassTalents`, and `C_Traits` APIs to avoid internal errors
- [Fix] Fix visibility show/hide rules and layout clobbering in the properties panel

## [1.0.20260317] - 2026-03-17

- [Feature] Overhaul nesting system with three top-level modes: Jump (Open), Button, and Embedded
- [Feature] Add Button sub-modes (Cycle, Random, Priority) for resolving child actions on parent slots
- [Feature] Embedded nesting mode injects child actions directly into parent layout with automatic rebuild propagation
- [Feature] Add custom name property to states for clearer identification
- [Feature] Allow specific Wiser interfaces in the action picker
- [Feature] Add 'Hide Game Interface' toggle for Cooldowns wiser interface
- [Fix] Fix BUTTON3 (middle mouse) bindings silently failing by passing correct mouseClick arg to SetOverrideBindingClick
- [Fix] Fix spell override resolution for skyriding abilities (Whirling Surge, etc.) using GetOverrideSpellID
- [Fix] Fall back to stored display name when C_Spell.GetSpellInfo fails, preventing broken /cast macros
- [Fix] Broaden IsActionKnown to check bidirectional spell override matching
- [Fix] Fix Dispatcher ApplyBinding to pass key as 5th arg for mouse button input
- [Fix] Fix Cooldowns and Utilities auto-loaded spells disappearing
- [Fix] Fix cooldown spell visual state by storing exact integer spellIDs
- [Fix] Fix spec bleed for dynamically loaded auto-spells in Cooldowns
- [Fix] Fix persistence, spec bleed, and visual issues in dynamic Cooldowns & Utilities
- [Fix] Fix nesting open direction, positioning, and cascade close behavior
- [Fix] Fix Extra Action Button and Zone Ability missing clickbutton handling on release mouseover
- [Fix] Fix Zone Ability and others failing on Release Mouseover due to background ticker
- [Fix] Fix error when comparing secret number aura duration
- [Fix] Ensure deleted interfaces are removed from parent groups
- [Fix] Align visibility and interface style checkboxes to a single column
- [Fix] Correct overlapping elements in properties panel
- [Fix] Fix Cooldowns and Utilities decimal slots not persisting through relogs
- [Fix] Fix multiple sources of taint
- [Fix] Fix XML parser warning in tests.xml
- [Chore] Make tests.xml transparent to deployments

## [1.0.20260312] - 2026-03-12

- [Feature] Enhance debug QA UI with persistent results and LLM export
- [Feature] Add Copy To Clipboard button to debug export UI
- [Feature] Make debug mode persistent and add tests UI
- [Feature] Add a spec chooser for multi-spec action restrictions
- [Feature] Add secure mouse button dispatcher for Button3/4/5 input
- [Feature] Replace build condition with multi-picker talent visibility logic
- [Feature] Support hexagon and octagon button mask shapes
- [Feature] Add custom generated WOW-inspired icons for audio toggles
- [Feature] Output audio state changes to chat and add to miscellaneous actions
- [Fix] Replace protected CopyToClipboard with manual copy selection
- [Fix] Ensure spec picker can open in properties panel
- [Fix] Display keybind text properly for dynamic and animated interface buttons
- [Fix] Stop tutorial items from remaining highlighted
- [Fix] Fix transparent background in spell picker category dropdown
- [Fix] Prevent Masque from overriding button styles when disabled
- [Fix] Separate unit vs ground markers to fix marker bugs
- [Fix] Restrict drag-and-drop on Cooldowns/Utilities and fix list highlights

## [1.0.20260310] - 2026-03-10

- [Feature] Reimplement Cooldowns and Utilities Wiser Interfaces
- [Feature] Add floating Exit Edit Mode button for quicker workflow
- [Feature] Add decimal slots and box defaults for Cooldowns/Utilities
- [Fix] Prevent UI disappearance after WoW-forced interface hides (quest dialogues, cutscenes, dungeon transitions)
- [Fix] Close native Edit Mode from floating exit button
- [Fix] Fix edit mode dragging for Cooldowns/Utilities

## [1.0.20260308] - 2026-03-08

- [Feature] Implement automatic layout growth direction based on anchor point
- [Feature] Replace center crosshairs with interactive 9-point anchor circles in edit mode
- [Feature] Add Interface conditionals to Conditionals tab
- [Feature] Implement Addon Loading Magic (AML) for conditional addon loading and state management
- [Feature] Add `[aml:slotname]` conditional support for interface visibility and action slots
- [Feature] Wise Logo Color Palette added for design consistency in GUI modules
- [Feature] Add "Invisible" icon style for layout placeholders to allow cleaner UI designs
- [Fix] Correct layout offset drift and refine UI growth indicators
- [Fix] Correctly align, perfectly center, and scale anchor indicator rings
- [Fix] Handle invalid negations for `@` targeting conditionals and optimize condition exclusivity checks
- [Fix] Remove raw macro command from inline macro tooltips and display correct names for tradeskill tooltips
- [Fix] Resolved action icon and visibility issues for overrides and PossessBar/Vehicle states
- [Fix] Macro icon selector now correctly opens manual selection when clicking the question mark icon
- [Fix] Remove 10px inset from cooldown wipers (GCD animation) for seamless edge-to-edge rendering
- [Fix] Improved state persistence and reload behavior for Addon Loading Magic slots
- [Fix] Corrected tooltip resolution for vehicle and overridden actions

## [1.0.20260306] - 2026-03-06

- [Feature] Replace hardcoded class spells with programmatic spell override resolution (e.g. Maul→Raze) across all UI surfaces
- [Feature] Drag-to-reorder for slots and states in the Actions panel, replacing arrow buttons
- [Feature] Wiki documentation for the addon covering basics and advanced topics
- [Fix] Spell override resolution, PetActionBar taint, and category detection
- [Fix] Interface visibility in edit mode for undermouse conditions
- [Fix] Store base spell IDs so overrides update automatically on spec change

## [1.0.20260305] - 2026-03-05

- [Feature] Add [undermouse] visibility conditional for showing interfaces on mouseover
- [Feature] Add lock capability to interfaces to prevent accidental modifications
- [Fix] Zone abilities and extra action button not working correctly
- [Fix] ADDON_ACTION_BLOCKED error by avoiding SetPoint on secure proxy anchors in combat
- [Fix] Drag-drop and binding text overlapping with lock icon
- [Fix] Improved [undermouse] performance and added combat restriction notifications

## [1.0.20260304] - 2026-03-04

- [Feature] Drag and drop support for adding and overriding action slots in the options menu and UI buttons
- [Feature] Wise-only Edit Mode button for configuring Wise interfaces without triggering the built-in WoW Edit Mode overlay
- [Fix] Drag and drop now correctly appends or overrides slots based on drop target location
- [Fix] Edit Mode snapping improved for a more comfortable positioning experience
- [Fix] Hammer of Light (Paladin Hero talent) now discoverable in the spell picker via hardcoded Spell ID