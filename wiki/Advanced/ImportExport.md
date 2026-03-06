# Importing and Exporting Interfaces

Wise allows you to share your complex interface configurations with others, or back them up, using an import/export string format.

## Exporting an Interface

1.  Open the Wise Options Panel (`/wise`).
2.  Select the interface you want to share.
3.  Click the **Export** button (usually located in the top right or near the interface name).
4.  A text box will appear with a long string of characters. This is the Base64 encoded representation of your interface data.
5.  Copy this string to your clipboard (`Ctrl+C` or `Cmd+C`).

## Importing an Interface

1.  Open the Wise Options Panel (`/wise`).
2.  Click the **Import** button (often near the 'Create New' section).
3.  Paste the string you copied earlier into the text box (`Ctrl+V` or `Cmd+V`).
4.  Click **Import**.

## Handling Import Conflicts

If you try to import an interface that has the same name as one you already have, Wise will detect the conflict.

1.  A popup window (`WISE_IMPORT_RENAME`) will appear.
2.  It will display the name of the conflicting interface.
3.  You can choose to:
    *   **Rename:** Type a new name in the text box and click **Import**.
    *   **Skip:** Click **Skip** to ignore this interface and proceed with the rest of the import (if multiple interfaces were in the string).

## Important Note on OPie Imports

If you are trying to import an OPie configuration, Wise **cannot** decompress OPie strings that begin with the header `oetohH7`.

To import an OPie configuration into Wise, you must first export it from OPie using the **'Snapshot > Copy as Lua'** option to generate an uncompressed, compatible string.
