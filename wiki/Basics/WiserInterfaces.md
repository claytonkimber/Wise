# Wiser Interfaces

Wiser Interfaces are built-in smart interfaces that automatically populate their actions for your current character. You don't configure their contents manually — Wise does it for you, and they update whenever your character changes specs, learns professions, or logs in.

All Wiser Interfaces appear in the left sidebar of the Options Panel with a distinct color. You configure their **layout and visibility** like any other interface, but their **action slots are managed automatically**.

---

## Available Wiser Interfaces

### Professions

Automatically detects every profession and secondary skill your current character has (including Fishing, Cooking, Archaeology) and creates a toggle button for each. Clicking a button opens or closes that profession window — press it again to close it.

Updates whenever you learn a new profession or log in on a different character.

### Menu Bar

A replacement for WoW's default micro-menu. Contains buttons for:

- Menu (main game menu)
- Shop
- Adventure Guide
- Collections
- Group Finder
- Guild
- Housing
- Quest Log
- Achievements
- Spellbook / Abilities
- Talents
- Professions
- Character Info

Works with any layout type — a Circle makes a compact quick-access ring; a List gives you a labeled vertical menu.

### Forms

Detects your current class's shapeshift forms and stances (Druid forms, Warrior stances, Rogue stealth, Demon Hunter Metamorphosis, etc.) and creates buttons for each. Updates automatically when you change specs or when talents add/remove available forms.

### Specs

Shows your non-active specializations with a one-click swap. The currently active spec is omitted. Clicking a spec button switches you to it immediately.

Updates when you change specs so it always reflects the currently unselected ones.

### Spec & Equipment Changer

A multi-slot interface for switching spec, talent loadout, and gear set simultaneously with a single button press. Each slot can be configured with a spec, a talent loadout name, and an equipment set name — clicking the slot swaps all three in the correct order.

See [Spec & Equipment Changer](../Advanced/SpecAndEquip.md) for setup details.

### Addon Loading Magic

Creates buttons that toggle addon loading/unloading by name. Useful for managing addons that you only want running in specific contexts (e.g., a raid addon you load just before progression night).

Each slot represents one addon. Clicking it toggles the addon's enabled state; the button reflects current status.

### Cooldowns *(hidden by default)*

A pre-configured box layout (4-wide grid) for tracking major cooldowns. Disabled by default — enable it in its Visibility settings when you want it.

### Utilities *(hidden by default)*

A pre-configured box layout (2-wide grid) for utility/defensive cooldowns. Disabled by default.

---

## Customizing Wiser Interfaces

While you cannot edit the auto-generated slots directly, you can fully customize:

- **Layout type** — change Circle to Box, List, Line, etc.
- **Appearance** — icon size, padding, font, keybind display
- **Visibility** — when and how the interface shows (see [Visibility Settings](Visibility.md))
- **Position** — drag in Edit Mode or use nudgers
- **Keybind** — assign a hotkey to show/hide or hold-trigger the interface

To configure a Wiser Interface:
1. Click it in the left sidebar
2. Use the **Settings** tab for layout, appearance, position, visibility, and keybind

---

## Enabling disabled Wiser Interfaces

Cooldowns and Utilities are hidden by default. To enable them:

1. Click the interface in the sidebar
2. Go to **Settings** → **Visibility**
3. Check **Always Show**, or set a custom show conditional

All other Wiser Interfaces are enabled automatically but require a visibility setting before they'll appear in-game — they won't show until you tell them when to be visible.
