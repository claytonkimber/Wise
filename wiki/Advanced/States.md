# Context-Sensitive Slots (Multiple States)

The most powerful feature of Wise is the ability to give a single slot **multiple states** — different actions that activate based on conditions. This is what makes one interface work across all your characters without profiles.

---

## What is a state?

A state is one possible action a slot can perform, paired with conditions that determine when it's active. Each slot evaluates its states in order and uses the **first one whose conditions are met**.

Think of a slot as a layered decision:

```
Slot: "Gap Closer"
  State 1: Charge          → [warrior, spec:1] (Arms Warrior)
  State 2: Intercept       → [warrior, spec:2] (Fury Warrior)
  State 3: Blink           → [mage]
  State 4: Disengage       → [hunter]
  State 5: (no conditions) → Rocket Boots  ← fallback
```

Log in on your Mage? The button shows Blink. Log in on your Hunter? It shows Disengage. No matching character? It falls back to Rocket Boots.

---

## Conflict strategies

When multiple states' conditions are true at the same time, the **conflict strategy** determines which one wins:

### Priority *(default)*

States are checked top-to-bottom. The first state with a true condition is used. This is the standard behavior and works well for most cases.

### Sequence

States cycle through in order on each button press. Only states whose conditions are currently true participate in the cycle. Useful for rotating through multiple cooldowns on one button.

Optional: **Reset on combat start** — the cycle resets back to state 1 when you enter combat, so you always start from the top.

### Random

Each press picks a random state from those whose conditions are currently met. Useful for randomizing taunts, emotes, mount groups, or any scenario where you want variety.

---

## Adding states to a slot

1. Open the Options Panel (`/wise`)
2. Select your interface → **Properties** tab
3. On the slot you want, click the **+** button to add a new state
4. Click the **Action** button on the new state row to assign an action
5. Click the **gear icon** on the state to set its conditions

---

## Configuring state conditions

Click the **gear icon** (or the conditions field) on any state to open its settings:

### Availability filters (checkboxes)

These are simple per-character filters that Wise evaluates at login and when your character changes:

| Filter | What it restricts to |
|---|---|
| **Class** | Only show for characters of a specific class |
| **Role** | Only show for a specific role (tank, healer, DPS) |
| **Spec** | Only show for a specific specialization |
| **Talent Build** | Only show when a specific saved talent loadout is active |
| **Character** | Only show for a specific character name + realm |

You can combine these — e.g., "Mage + Fire Spec" only matches Fire Mages.

### Macro conditionals

For real-time conditions (things that change during play), use the **Conditionals** field. Enter standard WoW macro conditional syntax:

```
[mod:shift]        → only when Shift is held
[combat]           → only in combat
[stealth]          → only while stealthed
[form:2]           → only in bear form (Druid)
[spec:1]           → only in spec 1
```

Multiple conditions in one bracket are AND'd: `[mod:shift,combat]` means "Shift held AND in combat."

See [Conditionals Reference](Conditionals.md) for every available conditional.

---

## State ordering matters (Priority mode)

In Priority mode, order determines which state wins when multiple conditions are true.

**Best practice:** put the most specific conditions at the top, and the broadest fallback at the bottom (often with no conditions, so it's always active as a default).

Bad order (fallback fires immediately, specific states never checked):
```
State 1: Mount           (no conditions)
State 2: Charge          [warrior]
State 3: Blink           [mage]
```

Correct order:
```
State 1: Charge          [warrior]
State 2: Blink           [mage]
State 3: Mount           (no conditions — fallback)
```

You can drag state rows to reorder them using the grip handle on the left.

---

## Drag and drop

- **Replace:** Drag a spell/item from your spellbook or bags onto an existing state's Action button to replace it.
- **Append:** Drag onto the **+** button of a slot to add a new state at the bottom with that action pre-filled.

---

## Automatic spell override resolution

Wise resolves talent-upgraded spells automatically. If a talent replaces a spell (e.g., a Hero Talent modifying a core ability), you don't need a separate state — just assign the base spell and Wise handles the upgrade at runtime. The button will show the upgraded icon and cast the correct spell.

---

## Suppressing errors

If a state's action isn't available (wrong spec, item not in bags, etc.) and the button is pressed, WoW normally plays an error sound and shows a message. You can disable this per-slot with **Suppress Errors** in the state settings — useful for fallback states that you intentionally might not have available.

---

## Example: universal utility button

```
Slot: "Utility"
Conflict strategy: Priority

State 1: Soulstone         [warlock]
State 2: Rebirth           [druid]
State 3: Raise Ally        [deathknight]
State 4: Heroism           [shaman]
State 5: Bloodlust         [shaman, spec:2]
State 6: Time Warp         [mage]
State 7: Healthstone       (no conditions — fallback)
```

One button. Works differently on every relevant class. Defaults to Healthstone on anything else.
