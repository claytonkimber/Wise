# Context-Sensitive Slots (Multiple States)

One of Wise's most powerful features is the ability to assign multiple "States" to a single slot in your interface. This allows a single button to perform different actions depending on specific conditions (like your class, spec, talents, or even macro conditionals like `[mod:shift]`).

Instead of creating separate bars or profiles for every character, you configure a slot once, and it intelligently decides what to do.

## How States Work

Think of a slot as a priority list of actions. Wise evaluates the states from top to bottom. The **first** state whose conditions are met is the one that becomes active on that button.

For example, you could have a single slot configured like this:

1.  **State 1:** Cast *Moonfire* (Condition: Druid, Balance Spec)
2.  **State 2:** Cast *Chomp* (Condition: Druid, Feral Spec)
3.  **State 3:** Cast *Eye Beam* (Condition: Demon Hunter, Havoc Spec)
4.  **State 4:** Use *Healthstone* (Condition: `[mod:shift]`)
5.  **State 5:** Cast *Mount* (No conditions - Default fallback)

If you log into your Havoc Demon Hunter and press Shift, the button will use a Healthstone (State 4 overrides State 5, but State 3 is skipped because you are holding Shift, wait, no, actually State 3 is checked *first*. Let's fix that logic: If you want Shift to override, it must be higher in the list!).

Let's re-order for a better example:

1.  **State 1:** Use *Healthstone* (Condition: `[mod:shift]`)
2.  **State 2:** Cast *Moonfire* (Condition: Druid, Balance Spec)
3.  **State 3:** Cast *Chomp* (Condition: Druid, Feral Spec)
4.  **State 4:** Cast *Eye Beam* (Condition: Demon Hunter, Havoc Spec)
5.  **State 5:** Cast *Mount* (No conditions - Default fallback)

Now, if you hold Shift on *any* character, it uses a Healthstone. If you don't hold Shift, it checks your class/spec. If you are a Havoc DH, it casts Eye Beam. If none of the specific conditions match, it casts your Mount.

## Adding States to a Slot

1.  Open the Wise Options Panel (`/wise`).
2.  Select your interface and go to the **Properties** tab.
3.  On the slot you want to modify, click the **"+"** button next to the primary Action button to "Add State".
4.  A new row will appear below the primary action for that slot.
5.  Click the **Action** button on this new state to choose what it does.

## Configuring State Conditions

Once you've added a state, you need to tell Wise *when* it should be active. Click the small **Gear Icon** next to the state's Action button to open its settings.

Here you can set restrictions:

*   **Class:** Only active for a specific class (e.g., Mage, Warrior).
*   **Spec:** Only active for a specific specialization (e.g., Fire Mage, Protection Warrior).
*   **Talent Build:** Only active when a specific talent loadout is active.
*   **Character:** Only active for a specific character name and realm.
*   **Macro Conditionals:** The most flexible option. You can enter standard WoW macro conditionals like `[stealth]`, `[combat]`, `[flyable]`, `[mod:alt]`, or Wise's custom conditionals (see [Custom Conditionals](Conditionals.md)).

## Drag and Drop

You can drag and drop spells/items directly from your spellbook or bags onto a slot in the Wise Options Panel.

*   **Replace:** Dragging onto the primary Action button will replace the current action.
*   **Append:** Dragging onto the **"+"** (Add State) button will automatically create a new state at the bottom of the list with that action.

## Important Note on Dynamic Spell Replacement

Wise automatically handles spell replacements due to talents (e.g., Paladin's 'Wake of Ashes' becoming 'Hammer of Light'). You usually don't need to create separate states for these; just set the base spell, and Wise will update the icon and action dynamically when the talent is active.
