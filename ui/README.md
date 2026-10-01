# Desktop UI

The interface shared by every desktop build (Mac, Windows, Linux) and later iPad: plain HTML, CSS and JavaScript loaded by a thin native shell (WKWebView, WebView2, WebKitGTK). See D-267, D-318 and `Desktop_App_Scope` in the workspace.

**Status: first-cut prototype.** Placeholder data, no sync, no native shell. It exists to settle the look and the feel of typing before any platform code is written.

## Rules that keep it portable

- No framework, no bundler, no build step. Files load as they are.
- No platform-only web features. If something needs the OS (menus, drag to Finder, the folder picker, the keychain), it goes through the shell bridge, which does not exist yet.
- Design tokens mirror `Catchlight-iOS/Catchlight/UI/Theme/CatchlightTheme.swift`. As-Built wins (D-274): if this file and the iOS code disagree, the iOS code is right.
- `localStorage` here is a prototype convenience only. Real data goes through `CatchlightCore`.

## Running it

Serve the folder and open it in any browser:

```bash
python3 -m http.server 8851 -d ui
```

In the Claude desktop app the preview config is `catchlight-macos-ui`.

## What the prototype covers

- One window, split (D-312), with no dividing lines (D-319). Default: Dailies left, the Script area in the middle, Scripts right. The Layout button puts each section left, middle or right, or hides it; one section always stays on screen.
- Dailies opens at the iPhone's 393 × 852 proportion of the window height. Side sections resize by dragging their inner edge; the Script area takes the spare width. ⌃⌘S hides or restores Dailies, ⌃⌘L Scripts.
- Both docks carry the Angle button; on the Scripts dock it is a placeholder.
- Script list mirrors Dailies, with Preview, Spacing and Sort as on iOS.
- Script editor: one view, markdown formatted inline as you type. The block being edited shows its markers dimmed, every other block shows the result. `- [ ]` is a real checkbox.
- Page mode per Script: Continuous, A4 or US Letter (D-314), new Scripts defaulting by region.
- Right-click a Take: Expand into a Script. Right-click a Script: Make this a Take (D-313).
- Scene follows the system, or Night or Daylight from the toolbar.

## Known gaps

Tables, Take editing in the sidebar, the Focus-ring, undo across blocks, and caret placement on click is approximate (the edited face is wider by its markers).

## Fonts

Cormorant Garamond and DM Sans, both under the SIL Open Font License 1.1, copied from `Catchlight-Site/fonts/`. The licence text still has to be added beside them before any release.
