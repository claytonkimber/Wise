# Nested Interfaces

Nesting lets you embed one Wise interface inside a slot of another. This is how you build sub-menus, layered rings, and context menus without cluttering your main layouts.

A **parent** interface has a slot whose action type is **Interface**, pointing to a **child** interface. How the child behaves depends on the **nesting mode** you choose.

---

## How to nest an interface

1. Create both the parent and child interfaces
2. Select the parent interface → **Properties** tab
3. On the slot where you want the child, click **Action** to open the Action Picker
4. In the Action Picker, choose the **Interface** category
5. Select the child interface from the list
6. Choose the nesting mode (Jump, Button, or Embedded)

---

## Nesting modes

### Jump (Open)

Clicking the parent slot opens the child interface as a separate frame next to the parent slot. This is the classic sub-menu behavior.

The child interface opens in a direction relative to the slot:
- **Auto** — Wise picks the best direction based on screen position
- **Up / Down / Left / Right** — fixed direction

**Keep Open** option: if enabled, the child interface stays open after you click an action inside it. Normally it closes when you fire an action.

The parent slot's icon reflects the first active action in the child interface.

**Hover close:** If **Close on Leave** is enabled, the child interface auto-closes when your cursor leaves the area (with a small proximity grace zone to prevent accidental closes).

This mode is combat-safe: Wise uses a direct frame reference toggle rather than `/click` macro calls, so it works reliably in and out of combat.

### Button

The parent slot acts as if it *is* the child interface — it resolves and fires one action from the child's slot list directly. The child frame never opens visually; it's just a pool of actions the parent draws from.

Three sub-modes control which action the parent fires:

| Sub-mode | Behavior |
|---|---|
| **Cycle** | Advances through child actions in order on each press. Scroll the mouse wheel while hovering to manually cycle. |
| **Random** | Each press picks a random action from the child's slot list. |
| **Priority** | Uses the first child action whose conditions are currently met (same as Priority conflict strategy for states). |

Button mode is powerful for things like a single "Mount" button that cycles through your favorite mounts, or a "Potion" button that always picks the most relevant consumable based on conditions.

### Embedded

Child actions are silently merged into the parent's slot list at build time. The child frame is never created — the parent simply gains extra slots. This is invisible to the player; it looks like the parent just has more buttons.

**When to use embedded:**
- You want a "shared" set of actions (e.g., utility spells available to all your characters) merged into every interface without maintaining them separately.
- You want to compose a complex bar from multiple smaller logical groups.

**Auto-rebuild:** When the child interface's slots change, the parent automatically rebuilds to include the updated content. The `_embeddedParents` tracking table handles this for you.

---

## Nesting rules and restrictions

Not all layout combinations are allowed. Wise enforces these rules to prevent layout conflicts:

| Parent type | Allowed child type |
|---|---|
| Circle | Circle, or a line-type Box |
| Box (line) | Box (line, perpendicular axis) |
| List | List |
| Button | Not allowed as a parent |

Circles cannot nest into Boxes (except as children of the Box's circular sub-ring). This prevents layout geometry conflicts.

**Maximum depth:** 5 levels deep. Wise stops nesting beyond this to prevent performance issues.

**Cycle detection:** Wise prevents circular nesting (A → B → A). If you try to nest an interface that would create a loop, Wise rejects it with an error.

---

## Positioning nested children

Nested child interfaces cannot be moved with Edit Mode — they are anchored to their parent slot.

Wise uses a secure **Anchor proxy** for positioning so child frames can be repositioned even in combat without taint.

**Open direction** controls which side of the parent slot the child expands toward (Up/Down/Left/Right/Auto).

---

## Hover animations

Nested child interfaces always use a **slide-in animation** (expanding from center) when they open, even if the parent interface has animations disabled.

When you hover over a slot that has a nested child:
- The slot scales up slightly (5%)
- A dim glow appears around the icon to signal it opens a sub-menu

---

## Cascading close behavior

When a parent interface is closed (hidden), it also hides all of its open child interfaces. This cascade happens via the secure PreClick handler and is reliable in combat.

**Exception:** a parent in Hold mode does NOT cascade-close children when it detects the parent just opened a child — it checks the `state-manual` attribute to prevent premature closure.

---

## Mouse wheel cycling (Button mode)

In **Button/Cycle** mode, hovering over the parent slot and scrolling the mouse wheel advances through the child's actions. This is how you "browse" the pool before clicking.

---

## Visibility inheritance

A nested child inherits its parent's visibility rules. If the parent is hidden, the child is also hidden regardless of the child's own visibility settings.

The child can additionally define its own visibility conditions (shown in the child interface's Settings tab). These are applied on top of the inherited parent conditions.

---

## Example: hover ring of rings

```
Main Bar (Box, always show)
  Slot 1: "Spells"    → Jump → Spell Ring (Circle)
  Slot 2: "Mounts"    → Jump → Mount Ring (Circle)
  Slot 3: "Items"     → Jump → Item Ring (Circle)
  Slot 4: "Utility"   → Jump → Utility Bar (Line)
```

Hovering over any slot on the Main Bar opens its child ring next to it. Each child ring can itself have nested interfaces for deeper organization.
