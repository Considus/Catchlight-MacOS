# Agent notes

For a coding agent working in this repo. People start with [`README.md`](README.md) (its non-negotiables first) and [`CONTRIBUTING.md`](CONTRIBUTING.md); this file does not repeat them. Read [`ui/README.md`](ui/README.md) before touching `ui/`. How each part of the shell works is in the header comment of its file in `App/Sources/`.

## Build

- **Leave the crypto contract and the file format to Catchlight-Core.** A Take written on the Mac must open on the iPhone.
- **Keep `ui/` free of any framework, build step or platform-only web feature:** Windows, Linux and the iPad share it.
- **Edit `project.yml`, never `Catchlight.entitlements` or `Info.plist`:** XcodeGen rewrites both from it. XcodeGen generates the project from `project.yml`; the `.xcodeproj` is not checked in.
- **Keep the network client entitlement.** WebKit's helpers crash under the sandbox without it and the window stays blank; the content rule list and navigation policy still block every web address.
- **Pass `ONLY_ACTIVE_ARCH=NO` on the command line for a universal build.** The project setting misses the package targets, and the app's other slice fails with "Unable to find module dependency: 'CatchlightCore'". Debug is universal; Release is arm64 only.
- **Sign for the team (automatic signing).** `keychain-access-groups` is restricted on macOS: without the provisioning profile the data-protection keychain answers -34018. Xcode needs an Apple ID signed in (Settings ▸ Accounts) and the Mac registered; `-allowProvisioningUpdates` fetches the profile. CI builds unsigned, and its tests use `MemorySecrets`.

```bash
brew install xcodegen            # once
xcodegen generate
BUILD_DIR="$HOME/CatchlightBuild"   # outside the repo
xcodebuild -scheme Catchlight -configuration Debug -derivedDataPath "$BUILD_DIR/mac" -allowProvisioningUpdates ONLY_ACTIVE_ARCH=NO build
```

## Test

```bash
APP="$BUILD_DIR/mac/Build/Products/Debug/Catchlight.app"
lipo -info "$APP/Contents/MacOS/Catchlight"          # x86_64 arm64
codesign -dv --entitlements - "$APP"                 # flags include runtime
open "$APP"
xcodebuild test -scheme Catchlight -configuration Debug -derivedDataPath "$BUILD_DIR/mac" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES | grep -E "Executed|items checked"
```

Read the test **count**, not the word "passed": every `func test` in `App/Tests/` plus Core's 31 `TakeStoreContractTests`. Under heavy CPU load the tests that load the real page fail intermittently, on `main` too; rerun on an idle machine before reading such a failure as real.

Proving the shell by hand (launch arguments, logs, the menu bar, a blank window) is in [`App/README.md`](App/README.md).

**Localisation:** Swift's own text is `String(localized: "…")`, literal inside the call, in `App/Resources/Localizable.xcstrings`; the page's is in `ui/l10n/` (`ui/README.md`, "Localisation"). Bridge replies and `Library` and `ConflictQueue` error details stay English, because `ui/conflicts.js` matches "changed while you were choosing". The test scheme runs in English; a test that wants another language sets `ShellBridge.language`. After touching a string, run `python3 scripts/l10n/check_catalogs.py`.

`ui/tlds.js` is generated: after Core's TLD list changes, run `scripts/generate_tlds_js.py` and commit the result.

## Ship

1. Once per clone: `git config core.hooksPath hooks`. `hooks/pre-commit` refuses a commit on `main`; `hooks/commit-msg` refuses a Claude attribution footer or an em or en dash.
2. Check nobody is on the work; branch from `origin/main`:

   ```bash
   git fetch origin
   gh pr list -R Considus/Catchlight-MacOS
   git checkout -b <type>/<short-name> origin/main
   ```

3. Stage by explicit path, never `git add -A` or `git commit -a`.
4. Fill [`.github/pull_request_template.md`](.github/pull_request_template.md), with the test count and, for `ui/`, screenshots in Night and Daylight.
