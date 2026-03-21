# Changelog

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