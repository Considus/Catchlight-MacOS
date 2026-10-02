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

- First run (D-327), as `OnboardingView` on iOS, shown until an account exists; `?first-run` replays it. The desktop needs no phone: Welcome, then either "Create my Privacy phrase" (Local or Cloud, the Local warning, the 12 words, confirm three of them, two pages of basics, done) or "I already use Catchlight" (type the 12 words, then connect the cloud folder). The copy is the phone's, adapted where a desktop differs. Unlike the phone, the Cloud path chooses the folder during setup. The device and backup names come from one `PLATFORM` setting so Windows and Linux can swap theirs in. The words are placeholders: Core generates and checks the real phrase (BIP-39, with its checksum), and the shell owns the Keychain and the folder picker, so the prototype only checks the shape of what is typed. No paywall: the desktop is free.
- One window, split (D-312), with no dividing lines (D-319). Default: Dailies left, the Script area in the middle, Scripts right. The Layout button, beside the window controls where macOS puts the sidebar control, puts each section left, middle or right, or hides it; one section always stays on screen.
- Dailies opens at the iPhone's 393 × 852 proportion of the window height. Side sections resize by dragging their inner edge; the Script area takes the spare width. ⌃⌘S hides or restores Dailies, ⌃⌘L Scripts.
- The Dailies dock, as `BottomDockView` on iOS: Add Take, the Storyboard (∠), Sequence and Search. The heading reads DAILIES, SEQUENCE, SEARCH or STORYBOARD to match.
  - **Sequence** turns the dock into four filter toggles: Important, Notes, Tasks and Reminders, each filling with its quadrant colour when on. A long press or right-click on Tasks gives done only, and on Reminders expired only; doing it again returns to plain on. Notes clears Tasks and Reminders, and either of those clears Notes. Every active toggle must hold. It is a live filter and nothing is saved.
  - **Search** turns the dock into Cancel, a field and the magnifier. The query starts empty and narrows the timeline as you type, matching the Take's text regardless of case; Return keeps the results.
  - There is no exit button, as on iOS: click the heading, empty timeline or the blank part of a month row to return. Escape does the same here.
  - **A month label** filters to that month in any mode; it lights with a × and a second click clears it. The pinned Obie is never filtered.
  - **The Storyboard** lists every Take with an unticked item, the Obie included, with no month rows; its menu is Mark Done, Important and Delete. × or Escape closes it.
- On the Scripts dock the Angle button is a placeholder.
- The Iris leans back 24° with its cast shadow, and the beam crosses only its top half, hidden by the card below and its centre on the card's top edge, and a rim catchlight that turns with the Iris's height on screen, west at the top to north at the bottom, parked under Reduce Motion (IrisDepth, TimelineBeam.swift and TakeCircleView.swift on iOS).
- Swipe a Take, as `SwipeActionRow` on iOS: right for Done or Not done (only on a Take that can be marked done), left for Delete. It snaps open at 42, a swipe past half the row (or 1.6 × 42) acts at once, and past 42 the card moves at half speed. With Confirm before deleting on it asks first and the row stays if the answer is no; with it off the card slides away and the row goes with it. A click on an open card closes it without opening the editor, and opening another row closes the first. The Obie swipes too; the Storyboard does not. A finger, pen or mouse drags; on a trackpad a two-finger horizontal scroll does the same.
- Drag a checklist item by its ≡ handle in the editor, as `BlockEditorViewController`: it starts on the first movement, lifts to 1.02 with no shadow, and a gap moves to where it will land, neighbours sliding aside. Text blocks have no handle but count as places to land. ⌥↑ and ⌥↓ move an item past the next checklist item, as VoiceOver's Move up and Move down. The order is saved with the edit, so a drag that ends where it began writes nothing (D-250).
- Editing a Take (D-324), as `KeyboardTakeEditor` does on iOS: click a card's text and it floats above the editor bar, growing upward, with the list dimmed to 14% and the dock replaced by the bar (× discard, reminder, Important or Shot List, Done). Clicking outside, Escape and ⌘S save; only × discards. A blank Take is not kept, and an edit that changes nothing writes nothing (D-250). Checklists follow `BlockEditor`: Return in an item adds one, Return on an empty item leaves the list, Backspace on an empty row removes it. `takes.js` holds all of Dailies.
- The Focus-ring: click a card's Iris. Four Marks fan out at R = 68 (Note, Task, Remind, Important), the card lifted over a 90% veil. A Take is never "none": with Task and Remind off, Note comes back on. Turning Remind on asks when; Cancel turns it off. Turning Task on from the list opens the editor on the new item. Hold an Iris for 0.45s to make that Take the Obie.
- The Take menu (right-click, or long press on touch): Expand or Collapse Take, Mark Done, Make Important, Make Obie, Export Take, Expand into a Script, Delete Take (asks twice in place). An expanded Take ignores Preview and shows in full; the list is kept per device. Export writes TakeExporter's Markdown to `catchlight-<date>.md`, without the trailing data block, which is Core's to write; the shells will hand it to a save panel or share sheet, and the prototype downloads it.
- Script list mirrors Dailies. Its View, Preview and Order are in Settings → Script timeline; the Scripts dock's view button opens Settings there.
- Settings, as `SettingsView` on iOS: a sheet of grouped cards that slides up over the window, opened by ⌘, (the shells add the menu item), a swipe up on the Dailies dock as on iOS, or the Scripts dock's view button. Every choice is a dropdown showing its value on the right; × or Escape closes it, and Escape steps back out of a sub-screen first. The desktop gives each pane its own section (owner, 2026-10-02):
  - **Appearance:** Mode (System, Light, Dark, the same as the toolbar's scene button) and Scenes, coming soon.
  - **Dailies:** View, Preview, Order, Arrangement and Creation date, as iOS's Takes settings. Creation date reads "Created on 01/07/2026 at 14:39" in the viewer's locale, on the card when Always and in the editor when Editor only or Always. Manual hides the month rows; arranging by hand is not built yet.
  - **Script timeline:** View, Preview and Order for the Scripts list.
  - **Script area:** Text size, the page for New Scripts (the region's paper by default, or Continuous, A4 or US Letter) and Spelling.
  - **Reminders, Security, System and Support**, as on iOS, less Spotlight & Siri, Writing Tools and Subscription (the desktop is free). Default timing sets where a new reminder starts. Confirm before deleting off makes Delete act on the first click. Sub-screens: Cloud Storage (folder, Remove, Sync mode), About, Privacy phrase (hold to reveal), Second device (the same phrase grid as first run) and Notice History. Start over exports if you choose, then erases the prototype's data and returns to first run.
- Under each heading, as in DailiesView: a 12px fade the list dissolves into; in Dailies a pinned Obie that never scrolls, with a solid zone down to its card instead of the fade.
- Script editor: one view, markdown formatted inline as you type. The block being edited shows its markers dimmed, every other block shows the result. `- [ ]` is a real checkbox.
  - **A click lands on the character clicked.** It is measured in the formatted face, then mapped across the markers the source face adds, starting after the block's own prefix (`- [x] `, `# `, a code fence). A table maps cell by cell. Right beside an inline marker (`**`, `` ` ``, a link) the caret can land either side of it.
  - **Undo spans the whole Script:** ⌘Z, ⇧⌘Z (or ⌃Y), or the Edit menu. Typing is one step until a second's pause. Splitting, merging, ticking and starting a table are a step each. The browser's own undo can't cross blocks, so the editor keeps its own.
  - **Tables** (decision I) use pipe syntax as one block. Type a header row such as `| Item | Size |` and press Enter: the separator and a first row follow. Enter adds a row (on the header or separator, after the separator), and Enter on an empty row leaves the table. Colons in the separator align a column. It shows as a table, and as its pipes while being edited.
  - **Turning a Script into a Take and back** keeps blocks whole. Code blocks and tables keep their lines. A Shift+Enter break inside a block travels as markdown's line break (two spaces before the newline), which the phone doesn't show. Spaces typed at the end of a block are dropped, so they can't read as a break, and a line that starts a block of its own (a list item, heading, quote, fence or table row) never joins the line before, nor does anything join a heading. The exception is a break inside a checklist item: the phone's item is one line, so what follows the break comes back as its own block.
- Page mode per Script: Continuous, A4 or US Letter (D-314), new Scripts defaulting by region, chosen from the page button at the right of the toolbar.
- Right-click a Take: Expand into a Script. Right-click a Script: Make this a Take (D-313).
- Scene follows the system, or Night or Daylight from the toolbar.
- The open Script's title is the Script area's heading, in the same place, size and face as DAILIES and SCRIPTS; the toolbar carries no title.

## Known gaps

Spotlight & Siri and Writing Tools rows (macOS has both; not yet decided), the native behind Lock after, Auto-Delete, Snooze, Follow-up reminders, Notifications, Import and Export diagnostics (stored or stubbed until the shell exists), Touch ID before Privacy phrase and Start over, pairing with another device (D-327 makes it a later convenience), Windows and Linux backup wording, the Shot List Angle, dragging Takes into a manual order, the repeating-reminder delete choice, a reminder picker beyond a plain date-and-time field (no repeats or places), editing a table cell by cell (it is edited as its pipe source), and images in a Script (deferred by decision I).

## Fonts

Cormorant Garamond and DM Sans, both under the SIL Open Font License 1.1, copied from `Catchlight-Site/fonts/`. The licence text for each family is beside them (`fonts/OFL-*.txt`) and listed in the repo's `NOTICE`.
