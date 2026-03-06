# Nested Interfaces

Wise allows you to nest interfaces inside other interfaces. This is perfect for organizing related actions or creating sub-menus. For example, you could have a "Mounts" button on your main bar that, when hovered over, opens a ring of all your favorite mounts.

## How to Nest an Interface

1. Create the parent interface (e.g., "Main Bar").
2. Create the child interface you want to nest (e.g., "Mount Ring").
3. In the Options Panel, select the parent interface.
4. Go to the **Properties** tab and click the **Action** button on the slot where you want the child interface to appear.
5. In the Action Picker, look for the **Interface** category (or use the search bar).
6. Select the child interface ("Mount Ring") from the list.
7. The slot in the parent interface will now display the child interface's icon.

## How Nested Interfaces Behave

*   **Trigger:** When you interact with the parent slot (usually by hovering over it, but this can be configured), the child interface will appear.
*   **Anchoring:** The child interface is anchored to its parent slot. You cannot move a nested interface using Edit Mode.
*   **Visibility:** The child interface inherits visibility rules from the parent, but you can also configure specific visibility conditions for the child interface itself in its Settings tab. If a nested child only has visibility inherited from its parent, it might be considered "Disabled" until the parent triggers it.
*   **Icons:** The icon for the parent slot will dynamically update to reflect the first active action in the nested child interface (or a custom icon if set).

## Important Considerations

*   **Cyclic Nesting:** Wise prevents you from nesting an interface inside itself (e.g., Interface A -> Interface B -> Interface A). This is to avoid infinite loops and crashes.
*   **Recursion Limit:** There is a maximum recursion depth limit for nested interfaces.
*   **Combat Lockout:** Keep in mind that secure frame changes (like showing/hiding interfaces) might be restricted during combat depending on how you've set up the triggers. Ensure your visibility conditions and triggers are configured appropriately for combat if needed.
