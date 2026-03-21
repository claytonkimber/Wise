# Visibility Settings

Visibility controls when an interface is shown on your screen. Wise evaluates visibility conditions every 0.2 seconds using a background ticker, so interfaces respond quickly to game state changes.

> **Important:** An interface with no visibility settings configured is considered **disabled** — it won't load or appear in-game at all. You must configure at least one visibility rule.

## Configuring visibility

1. Open the Options Panel (`/wise`)
2. Select your interface in the left sidebar
3. Click the **Settings** tab
4. Scroll down to the **Visibility** section

## Easy-mode checkboxes

These cover the most common use cases without writing any conditionals:

| Checkbox | Behavior |
|---|---|
| **Always Show** | Interface is always visible when loaded |
| **In Combat** | Show when you enter combat |
| **Out of Combat** | Show when you leave combat |
| **Hold to Show** | Only visible while holding the assigned keybind. Releasing the key hides the interface and executes the button under your cursor (if any). |
| **Toggle on Press** | Pressing the assigned keybind toggles the interface on/off |

**Hold** and **Toggle** require a keybind to be set in the Keybind section. See [Keybinds](Keybinds.md).

## Custom conditionals

For anything beyond the checkboxes, use the **Custom Show** and **Custom Hide** fields. These accept standard WoW macro conditional syntax.

**Custom Show** — the interface appears when any of these conditions are met.
**Custom Hide** — the interface is hidden when any of these conditions are met, overriding the show rules.

### Examples

| Goal | Conditional |
|---|---|
| Show only while mounted | `[mounted]` |
| Show only while in a shapeshift form | `[form:1]` or `[bonusbar:1]` |
| Show only outdoors | `[outdoors]` |
| Show only in a raid instance | `[instance:raid]` |
| Show only while in your main spec | `[spec:1]` |
| Show only while holding Alt | `[mod:alt]` |
| Hide while dead | `[dead]` (in the Hide field) |

See [Conditionals Reference](../Advanced/Conditionals.md) for the full list of available conditions, including Wise-specific ones like `[bank]`, `[undermouse]`, and `[zoneability]`.

## How show and hide interact

Wise evaluates them in this order:

1. Check **Custom Hide** — if any hide condition is true, the interface is hidden regardless of show conditions.
2. Check **Custom Show** — if any show condition is true, show the interface.
3. Check Easy-mode checkboxes (combat, out-of-combat, etc.).
4. If nothing matches, the interface hides.

This means **Hide always wins** over Show, which is useful for suppressing an interface in specific situations (e.g., show always except `[dead]`).

## Dynamic filtering (per-character visibility)

Beyond showing/hiding the whole interface, you can also control which **slots** are visible per character using state conditions. Each slot's states can be restricted to specific classes, specs, talents, or characters — slots whose conditions don't match the current character simply don't appear.

This is what makes Wise account-wide: you configure one interface with states for every class you play, and each character only sees the relevant slots.

See [Context-Sensitive Slots](../Advanced/States.md) for details.

## Inherited visibility

When a child interface is nested inside a parent, it inherits the parent's visibility rules. The child can additionally define its own show/hide conditions on top of the inherited ones.

See [Nested Interfaces](../Advanced/Nesting.md) for nesting details.
