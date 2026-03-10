# Changelog

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