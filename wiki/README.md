# Wise — Action Bar Addon for World of Warcraft

Wise is a flexible, account-wide action bar addon for World of Warcraft (Retail 11.0+). Instead of maintaining separate profiles for each character, you configure interfaces once and they adapt automatically — showing the right actions for your current class, spec, talents, form, or any other game condition.

## What makes Wise different

- **Account-wide by default.** One setup works across every character. Slots are filtered per-character based on conditions you define, so a "gap-closer" button shows Charge on your Warrior and Blink on your Mage without any profile swapping.
- **Multiple layout types.** Circles, grids, horizontal/vertical bars, text lists, and single buttons — choose what makes sense for each use case.
- **Context-sensitive slots.** Each slot can hold multiple states (actions), with a priority/sequence/random conflict strategy. A single button can cast different spells depending on spec, mod keys, aura state, or any WoW macro conditional.
- **Nested interfaces.** Slots can open child interfaces (sub-menus, rings, bars) on hover or click, using a secure direct-toggle that works in combat.
- **Smart auto-populating interfaces.** Built-in "Wiser" interfaces auto-populate professions, forms, specs, and menu panels for every character without manual setup.

---

## Getting Started

| | |
|---|---|
| [Setting up your first interface](Basics/Setup.md) | Create an interface, add actions, assign keybinds |
| [Action Types](Basics/ActionTypes.md) | Every kind of action a slot can perform |
| [Visibility Settings](Basics/Visibility.md) | Control when interfaces show and hide |
| [Keybinds](Basics/Keybinds.md) | Interface-level and slot-level hotkeys, trigger modes |
| [Moving Interfaces (Edit Mode)](Basics/EditMode.md) | Drag to reposition, pixel nudgers |
| [Wiser Interfaces](Basics/WiserInterfaces.md) | Auto-populating built-in interfaces |

## Advanced

| | |
|---|---|
| [Context-Sensitive Slots (States)](Advanced/States.md) | Multiple actions per slot, conflict strategies |
| [Nested Interfaces](Advanced/Nesting.md) | Sub-menus, jump / button / embedded nesting modes |
| [Conditionals Reference](Advanced/Conditionals.md) | Every available conditional — built-in and Wise-specific |
| [Macros](Advanced/Macros.md) | Unlimited custom macros with real-time icon resolution |
| [Spec & Equipment Changer](Advanced/SpecAndEquip.md) | One-click spec + talent loadout + gear set switching |
| [Smart Items](Advanced/SmartItems.md) | Dynamic item bars that update from your bags automatically |
| [Importing and Exporting](Advanced/ImportExport.md) | Share and back up interface configurations |

---

## Quick Reference

**Open options:** `/wise`
**Toggle Blizzard bars:** `/wise hidebars`
**Enter Edit Mode:** Click the **Edit Mode** button in the top-right of the options window
**Delete an interface:** `/wise delete InterfaceName`
