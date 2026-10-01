# Agent notes

For a coding agent working in this repo. `README.md` and `CONTRIBUTING.md` are the human documents and are not duplicated here; read the non-negotiables in the README first.

Every task moves through four beats: isolate on a branch, build, prove with evidence, ship a PR carrying that evidence.

## State of the repo

No native app target, no build chain and no CI yet, so `main` protection requires a PR but no status checks. `ui/` holds the first-cut interface prototype (plain HTML/CSS/JS, placeholder data); read `ui/README.md` before touching it. The interface is shared with Windows, Linux and iPad (D-318), so keep it free of framework, build step and platform-only web features. When CI lands, add its job names as required checks on `main` in the same PR that adds the workflow, and fill in the Build and Prove sections below.

The macOS app follows `Considus/Catchlight-iOS`, which holds `CatchlightCore` (data model, sync format, crypto). How this app consumes that core is an open decision; do not pick one without the owner.

## Isolate

`Repos/` is one checkout shared by every concurrent session, so `HEAD` may be on another session's branch when you arrive. Check, then branch from the named ref:

```bash
git fetch origin
gh pr list -R Considus/Catchlight-MacOS
git checkout -b <type>/<short-name> origin/main
```

Stage by explicit path. Never `git add -A` or `git commit -a`. Read `git --no-optional-locks status --porcelain` before committing.

A fresh clone needs the committed hooks wired up once:

```bash
git config core.hooksPath hooks
```

`hooks/pre-commit` refuses commits on `main`; `hooks/commit-msg` refuses Claude attribution footers.

## Build

The non-negotiables in `README.md` are constraints, not house style: zero knowledge with nothing transmitted off the device, `kSecAttrSynchronizable: false` on every Keychain item, encryption always on, offline-first.

The crypto contract (domain-separation strings, derivation parameters, envelope format) is frozen and owned by `Catchlight-iOS/Sources/CatchlightCore/Crypto/`. A Take written on the Mac must open on the iPhone. Never re-implement or alter those bytes here.

No third-party dependencies without agreeing it first.

## Prove

For `ui/`, serve it (`python3 -m http.server 8851 -d ui`, or the `catchlight-macos-ui` preview config) and prove changes in the browser with a screenshot in Night and Daylight. Clear `cl.*` keys from `localStorage` afterwards so the placeholder data is back to its defaults.

## Ship

Run `/code-review` locally before opening the PR. Label `greptile` (filter in `.greptile/config.json`) only on a PR that changes behaviour (budgeted, 30 a month across the org). Every PR also gets one automatic Claude review (`.github/workflows/claude-review.yml`).
