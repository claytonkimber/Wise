1. **Understand Issue**: The indicator crosshairs extend beyond the box. We need to anchor them to the edges of the overlay. Also, the top and right clamp insets are incorrect, causing extra padding and preventing the frame from reaching the screen edges.
2. **Fix Crosshairs**: Update `hLine` and `vLine` points to anchor to the `LEFT/RIGHT` and `TOP/BOTTOM` of the overlay, instead of extending out a fixed `lineLength`.
3. **Fix Clamp Insets**: The `SetClampRectInsets` logic for `cRight` and `cTop` needs to be investigated and corrected.
