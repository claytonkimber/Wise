# Moving Interfaces (Edit Mode)

Wise has its own Edit Mode for repositioning interfaces visually on your screen. All active interfaces are shown simultaneously so you can lay them out relative to each other.

## Entering Edit Mode

Click the **Edit Mode** button in the top-right corner of the Options Panel. A large **Exit Edit Mode** button appears in the center of your screen confirming you're in Edit Mode.

All active interfaces (those with visibility settings configured) appear on screen with a colored bounding-box overlay for dragging.

## Dragging interfaces

Click and hold the colored overlay of any interface, then drag it to the desired position. Release to drop it there. The position is saved automatically.

> Nested (child) interfaces cannot be moved in Edit Mode — they are anchored to their parent slot. Their position is determined by the parent layout and the configured **Open Direction**.

## Exiting Edit Mode

Click **Exit Edit Mode** in the center of your screen. All positions are saved to your SavedVariables.

## Precise positioning (nudgers)

For pixel-perfect placement without entering Edit Mode:

1. Select your interface in the sidebar
2. Click the **Settings** tab
3. In the **Position** section, you'll see X and Y coordinate fields
4. Click the **+** / **−** arrows to move one pixel at a time, or type a value directly

You can also change the **Anchor Point** (e.g. CENTER, BOTTOMLEFT, TOPRIGHT). The interface is positioned relative to that anchor point on the screen.

| Anchor | Interface positions its... |
|---|---|
| CENTER | center at the X/Y coordinates |
| BOTTOMLEFT | bottom-left corner at X/Y |
| TOPRIGHT | top-right corner at X/Y |

## Resetting position

Set X and Y to 0 and anchor to CENTER to return the interface to the middle of the screen.

## WoW native Edit Mode compatibility

Wise interfaces are compatible with the built-in WoW Edit Mode (`Escape → Edit Mode`). However, Wise's own Edit Mode is recommended for moving Wise interfaces, as it provides overlay feedback specific to Wise's layout types (especially circles and lists where the bounding box makes more sense).
