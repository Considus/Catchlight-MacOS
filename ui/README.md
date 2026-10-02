# Desktop UI

The interface shared by every desktop build (Mac, Windows, Linux) and later iPad: plain HTML, CSS and JavaScript loaded by a thin native shell (WKWebView, WebView2, WebKitGTK). See D-267, D-318 and `Desktop_App_Scope` in the workspace.

**Status: first-cut prototype.** Placeholder data, no sync, no native shell. It exists to settle the look and the feel of typing before any platform code is written.

## Rules that keep it portable

- No framework, no bundler, no build step. Files load as they are.
- No platform-only web features. If something needs the OS (menus, drag to Finder, the folder picker, the keychain), it goes through the shell bridge, which does not exist yet.
- Design tokens mirror `Catchlight-iOS/Catchlight/UI/Theme/CatchlightTheme.swift`. As-Built wins (D-274): if this file and the iOS code disagree, the iOS code is right.
- `localStorage` here is a prototype convenience only. Real data goes through `CatchlightCore`.
- Touch-ready (D-320): every control has a hit area of at least 44 × 44, extended invisibly with `::after` where it should look smaller; a long press does what a right-click does; checklist rows are 44 tall under a coarse pointer. A new control must pass the 44px hit probe before it merges.

## Running it

Serve the folder and open it in any browser:

```bash
python3 -m http.server 8851 -d ui
```

In the Claude desktop app the preview config is `catchlight-macos-ui`.

## What the prototype covers

- One window, split (D-312), with no dividing lines (D-319). Default: Dailies left, the Script area in the middle, Scripts right. The Layout button, beside the window controls where macOS puts the sidebar control, puts each section left, middle or right, or hides it; one section always stays on screen.
- Dailies opens at the iPhone's 393 × 852 proportion of the window height. Side sections resize by dragging their inner edge; the Script area takes the spare width. ⌃⌘S hides or restores Dailies, ⌃⌘L Scripts.
- Both docks carry the Angle button; on the Scripts dock it is a placeholder.
- The Iris leans back 24° with its cast shadow, and the beam crosses only its top half, hidden by the card below and its centre on the card's top edge, and a rim catchlight that turns with the Iris's height on screen, west at the top to north at the bottom, parked under Reduce Motion (IrisDepth, TimelineBeam.swift and TakeCircleView.swift on iOS).
- Editing a Take (D-324), as `KeyboardTakeEditor` does on iOS: click a card's text and it floats above the editor bar, growing upward, with the list dimmed to 14% and the dock replaced by the bar (× discard, reminder, Important or Shot List, Done). Clicking outside, Escape and ⌘S save; only × discards. A blank Take is not kept, and an edit that changes nothing writes nothing (D-250). Checklists follow `BlockEditor`: Return in an item adds one, Return on an empty item leaves the list, Backspace on an empty row removes it. `takes.js` holds all of Dailies.
- The Focus-ring: click a card's Iris. Four Marks fan out at R = 68 (Note, Task, Remind, Important), the card lifted over a 90% veil. A Take is never "none": with Task and Remind off, Note comes back on. Turning Remind on asks when; Cancel turns it off. Turning Task on from the list opens the editor on the new item. Hold an Iris for 0.45s to make that Take the Obie.
- The Take menu (right-click, or long press on touch): Mark Done, Make Important, Make Obie, Expand into a Script, Delete Take (asks twice in place).
- Script list mirrors Dailies, with Preview, Spacing and Sort as on iOS.
- Under each heading, as in DailiesView: a 12px fade the list dissolves into; in Dailies a pinned Obie that never scrolls, with a solid zone down to its card instead of the fade.
- Script editor: one view, markdown formatted inline as you type. The block being edited shows its markers dimmed, every other block shows the result. `- [ ]` is a real checkbox.
- Page mode per Script: Continuous, A4 or US Letter (D-314), new Scripts defaulting by region, chosen from the page button at the right of the toolbar.
- Right-click a Take: Expand into a Script. Right-click a Script: Make this a Take (D-313).
- Scene follows the system, or Night or Daylight from the toolbar.
- The open Script's title is the Script area's heading, in the same place, size and face as DAILIES and SCRIPTS; the toolbar carries no title.

## Known gaps

Tables, swipe actions on Take rows, the Shot List Angle, Expand/Collapse and Export in the Take menu, dragging checklist items (the handles are drawn but inert), a reminder picker beyond a plain date-and-time field (no repeats or places), undo across blocks, and caret placement on click is approximate (the edited face is wider by its markers). Turning a Script into a Take and back keeps fenced code blocks whole, but a Shift+Enter line break inside an ordinary block comes back as two blocks.

## Fonts

Cormorant Garamond and DM Sans, both under the SIL Open Font License 1.1, copied from `Catchlight-Site/fonts/`. The licence text for each family is beside them (`fonts/OFL-*.txt`) and listed in the repo's `NOTICE`.
