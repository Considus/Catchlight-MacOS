# Proving a change

The unit tests and the build checks are in [`AGENTS.md`](../AGENTS.md), under Test. This is how to prove the running app, and the page, by hand.

## Unit tests under load

On a heavily loaded machine WebKit's GPU process can be killed as unresponsive in the test runner, and the harness (`Tests/WebViewHarness.swift`) retries a stalled page load once. The tests that load the real page still fail intermittently under heavy CPU load, on `main` too. Rerun on an idle machine before reading a failure there as real.

## Launch arguments

Debug builds take launch arguments for proving the shell, listed in the header of `Sources/DebugLaunch.swift`. None exist in Release.

```bash
open "$APP" --args -CLDebugAccount YES -CLDebugNoExternalOpen YES -CLDebugEval 'return shell.systemInfo()'
/usr/bin/log show --last 2m --info --predicate 'subsystem == "com.considus.catchlight.mac"'
```

- In zsh, `log` is a builtin: use `/usr/bin/log`.
- Info lines need `--info`, and `log show` may not have kept them. `/usr/bin/log stream --info --predicate ...`, running while the app does, is reliable.
- Without `-CLDebugAccount` the app uses the real Keychain and the real library: on your Mac, your own notes.
- To see another language: `open "$APP" --args -CLDebugAccount YES -AppleLanguages '(de)'`.

## The menu bar

System Events can read and drive the menu bar (it needs Accessibility for the app running `osascript`):

```bash
osascript -e 'tell application "System Events" to tell process "Catchlight" to get name of every menu bar item of menu bar 1'
osascript -e 'tell application "System Events" to tell process "Catchlight" to click menu item "Storyboard" of menu 1 of menu bar item "View" of menu bar 1'
```

A menu item's tick is its `AXMenuItemMarkChar` attribute, which reflects the page's pushed model, so a click followed by reading the tick proves the round trip. Make the app frontmost (`set frontmost of process "Catchlight" to true`) before sending keystrokes.

## A blank window

- Look for WebKit process crashes in the log: `/usr/bin/log show --last 2m --predicate 'process == "Catchlight"' | grep processDidTerminate`.
- Debug builds set `isInspectable`, so Safari's Develop menu can inspect the page.
- "Catchlight could not start its web view safely" means the content rule list did not compile, and the log says why.
- The page's `localStorage` and the library live in the app's container (`~/Library/Containers/com.considus.catchlight.mac/`), separate from the browser's. `localStorage` holds only view settings. Takes, Scripts and the phrase never go there.

## The page in a browser

Serve `ui/` as [`ui/README.md`](../ui/README.md) says under "Running it", and prove a change with a screenshot in Night and in Daylight. Clear the `cl.*` keys from `localStorage` afterwards, so the placeholder data is back to its defaults.
