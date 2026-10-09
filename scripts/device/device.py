#!/usr/bin/env python3
"""Build Catchlight for Mac into the copy Mark runs, and read its diagnostics.

    python3 scripts/device/device.py status
    python3 scripts/device/device.py install [--ref origin/main] [--launch]
    python3 scripts/device/device.py logs [--crashes] [--out DIR]

The Mac is its own test device, so nothing goes over a cable. Mark runs the copy in
~/Applications/Catchlight.app.

`install` builds a clean Debug copy of one git ref in a throwaway worktree (the
shared checkout is never touched), quits the running app, swaps the new build into
~/Applications, and fails unless the installed copy reports the commit that was
built. The previous copy is kept until the new one checks out, then deleted; on a
failure it is put back.

`logs` reads the diagnostics log from the app's sandbox container and writes it as
the same readable text the iPhone app's Export produces. `--crashes` adds
Catchlight's crash reports from ~/Library/Logs/DiagnosticReports.

Needs Xcode 26+ and xcodegen. Standard library only. Every build and git call has a
hard deadline, and each leg prints its exit code.
"""

import argparse
import datetime as dt
import fcntl
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

BUNDLE_ID = "com.considus.catchlight.mac"
SCHEME = "Catchlight"
APP_DEST = os.path.expanduser("~/Applications/Catchlight.app")
# CatchlightCore's DiagnosticsLog writes to Application Support inside the sandbox.
DIAG_PATH = os.path.expanduser(
    f"~/Library/Containers/{BUNDLE_ID}/Data/Library/Application Support/catchlight-diagnostics.json")
CRASH_DIR = os.path.expanduser("~/Library/Logs/DiagnosticReports")
BUILD_ROOT = os.path.expanduser("~/CatchlightBuild")
# Foundation's JSONEncoder writes a Date as seconds since this reference date.
APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)

# Deadlines, in seconds. A clean universal Debug build with its packages takes
# several minutes; quitting the app waits for it to save.
BUILD_TIMEOUT = 1800
GIT_TIMEOUT = 120
XCODEGEN_TIMEOUT = 120
QUIT_TIMEOUT = 30


class Failure(Exception):
    """A step that failed, with a message that says what to do about it."""


def run(cmd, timeout, cwd=None, label=None, check=True):
    """Run a command, print its exit code, and return (code, stdout). Raise on failure."""
    name = label or os.path.basename(cmd[0])
    try:
        proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        raise Failure(f"{cmd[0]} is not installed or not on PATH")
    except subprocess.TimeoutExpired:
        print(f"[{name}] exit=timeout after {timeout}s")
        raise Failure(f"{name} did not finish within {timeout}s")
    print(f"[{name}] exit={proc.returncode}")
    if check and proc.returncode != 0:
        # xcodebuild writes compile errors to stdout, so show the end of both streams.
        tail = []
        for stream in (proc.stdout, proc.stderr):
            lines = (stream or "").strip().splitlines()[-15:]
            if lines:
                tail.append("\n".join(lines))
        raise Failure(f"{name} failed (exit {proc.returncode}):\n" + "\n---\n".join(tail))
    return proc.returncode, proc.stdout


# ---- pure helpers (unit-tested in test_device.py) -------------------------

def entry_line(entry):
    """One diagnostics entry as the iPhone app's Export writes it, in local time."""
    when = (APPLE_EPOCH + dt.timedelta(seconds=float(entry["timestamp"]))).astimezone()
    return f"{when:%Y-%m-%d %H:%M:%S}  [{entry['category']}]  {entry['message']}"


def diagnostics_text(entries):
    """The whole log as text, oldest first."""
    ordered = sorted(entries, key=lambda e: float(e["timestamp"]))
    return "\n".join(entry_line(e) for e in ordered) + ("\n" if ordered else "")


CRASH_NAME = re.compile(r"(^|[_-])catchlight", re.IGNORECASE)


def catchlight_crashes(paths):
    """The crash reports (relative paths) that belong to the app.

    A report is named after its process, sometimes with a prefix such as
    ExcUserFault_, and older ones sit in a Retired/ subfolder.
    """
    return sorted(p for p in paths
                  if p.endswith(".ips") and CRASH_NAME.search(os.path.basename(p)))


def bundle_build(app_path):
    """(short version, build stamp) from an app bundle's Info.plist, or None if absent."""
    plist = os.path.join(app_path, "Contents", "Info.plist")
    if not os.path.isfile(plist):
        return None
    with open(plist, "rb") as f:
        info = plistlib.load(f)
    return info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")


# ---- commands -------------------------------------------------------------

def repo_root():
    here = os.path.dirname(os.path.abspath(__file__))
    return run(["git", "-C", here, "rev-parse", "--show-toplevel"], GIT_TIMEOUT,
               label="git toplevel")[1].strip()


def app_running():
    code, out = run(["osascript", "-e", f'application id "{BUNDLE_ID}" is running'],
                    QUIT_TIMEOUT, label="osascript is-running")
    return out.strip() == "true"


def cmd_status(args):
    build = bundle_build(args.dest)
    root = repo_root()
    run(["git", "-C", root, "fetch", "--quiet", "origin", "main"], GIT_TIMEOUT, label="git fetch")
    main = run(["git", "-C", root, "rev-parse", "--short", "origin/main"], GIT_TIMEOUT,
               label="git rev-parse")[1].strip()
    if build is None:
        print(f"Catchlight is not installed at {args.dest}.")
        return 1
    version, stamp = build
    print(f"installed: {version} ({stamp}) at {args.dest}  ·  origin/main: {main}")
    if stamp == main:
        print("The Mac has the latest main.")
        return 0
    code, out = run(["git", "-C", root, "rev-list", "--count", f"{stamp}..origin/main"],
                    GIT_TIMEOUT, label="git rev-list", check=False)
    if code == 0:
        print(f"The installed copy is {out.strip()} commits behind origin/main.")
    else:
        print(f"The installed build stamp {stamp!r} is not a commit this repo knows "
              "(a build from before the stamp existed, or a dirty one): install a fresh one.")
    return 0


def cmd_install(args):
    os.makedirs(BUILD_ROOT, exist_ok=True)
    # One install at a time: sessions run side by side.
    lock = open(os.path.join(BUILD_ROOT, "mac-install.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise Failure("another Mac install is running; wait for it to finish and run this again")
    try:
        return install_locked(args)
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def install_locked(args):
    root = repo_root()
    run(["git", "-C", root, "fetch", "--quiet", "origin"], GIT_TIMEOUT, label="git fetch")
    # ^{commit} so an annotated tag resolves to the commit the stamp script will see.
    sha = run(["git", "-C", root, "rev-parse", "--short", f"{args.ref}^{{commit}}"], GIT_TIMEOUT,
              label="git rev-parse")[1].strip()
    print(f"building {args.ref} at {sha}")

    run(["git", "-C", root, "worktree", "prune"], GIT_TIMEOUT, label="git worktree prune")
    work = tempfile.mkdtemp(prefix=f"mac-{sha}-", dir=BUILD_ROOT)
    src = os.path.join(work, "src")
    derived = os.path.join(work, "dd")  # fresh derived data, so the stamp applies
    run(["git", "-C", root, "worktree", "add", "--detach", src, sha], GIT_TIMEOUT,
        label="git worktree add")
    try:
        run(["xcodegen", "generate"], XCODEGEN_TIMEOUT, cwd=src, label="xcodegen")
        run(["xcodebuild", "-scheme", SCHEME, "-configuration", "Debug",
             "-derivedDataPath", derived, "-allowProvisioningUpdates", "ONLY_ACTIVE_ARCH=NO",
             "build"], BUILD_TIMEOUT, cwd=src, label="xcodebuild")
        built = os.path.join(derived, "Build", "Products", "Debug", "Catchlight.app")
        if bundle_build(built) is None:
            raise Failure(f"the build reported success but {built} is missing")
        swap_in(built, args.dest, sha)
    finally:
        cleanup_worktree(root, src, work)

    print(f"Build {sha} ({args.ref}) is installed at {args.dest}.")
    if args.launch:
        run(["open", args.dest], QUIT_TIMEOUT, label="open")
        print("Opened the new build.")
    return 0


def swap_in(built, dest, sha):
    """Quit the app, replace dest with built, check the stamp, roll back on failure."""
    if app_running():
        run(["osascript", "-e", f'tell application id "{BUNDLE_ID}" to quit'],
            QUIT_TIMEOUT, label="osascript quit")
        if app_running():
            raise Failure("Catchlight did not quit (an unsaved prompt?): close it and run this again")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    backup = None
    if os.path.exists(dest):
        backup = dest + ".previous"
        shutil.rmtree(backup, ignore_errors=True)
        os.rename(dest, backup)
    try:
        run(["ditto", built, dest], GIT_TIMEOUT, label="ditto")
        build = bundle_build(dest)
        if build is None or build[1] != sha:
            raise Failure(f"the installed copy reports build {build[1] if build else 'none'}, "
                          f"not {sha}")
    except Failure:
        shutil.rmtree(dest, ignore_errors=True)
        if backup:
            os.rename(backup, dest)
            print("[rollback] the previous copy is back in place")
        raise
    if backup:
        shutil.rmtree(backup, ignore_errors=True)


def cleanup_worktree(root, src, work):
    """Remove the build's worktree and folder without hiding an earlier failure."""
    try:
        run(["git", "-C", root, "worktree", "remove", "--force", src], GIT_TIMEOUT,
            label="git worktree remove")
    except Failure as exc:
        print(f"[cleanup] {exc}; removing the folder and pruning instead")
    shutil.rmtree(work, ignore_errors=True)
    try:
        run(["git", "-C", root, "worktree", "prune"], GIT_TIMEOUT, label="git worktree prune")
    except Failure as exc:
        print(f"[cleanup] {exc}")


def cmd_logs(args):
    stamp = dt.datetime.now().strftime("%Y-%m-%d-%H%M%S")
    out_dir = args.out or os.path.join(BUILD_ROOT, "mac-logs", stamp)
    os.makedirs(out_dir, exist_ok=True)
    build = bundle_build(args.dest)
    label = build[1] if build else "not installed"

    if not os.path.isfile(DIAG_PATH):
        print(f"No diagnostics log yet at {DIAG_PATH} (installed build: {label}). "
              "The log appears once a build that writes it has run.")
        entries = []
    else:
        try:
            with open(DIAG_PATH) as f:
                entries = json.load(f)
        except PermissionError:
            raise Failure("macOS refused access to the app's container: allow this terminal "
                          "under System Settings > Privacy & Security > App Management or Full Disk Access")
        shutil.copy2(DIAG_PATH, os.path.join(out_dir, "catchlight-diagnostics.json"))
        text_path = os.path.join(out_dir, "catchlight-diagnostics.txt")
        with open(text_path, "w") as f:
            f.write(diagnostics_text(entries))
        print(f"{len(entries)} log entries (installed build {label}) -> {text_path}")

    if args.crashes:
        found = []
        if os.path.isdir(CRASH_DIR):
            found = [os.path.relpath(os.path.join(d, f), CRASH_DIR)
                     for d, _, files in os.walk(CRASH_DIR) for f in files]
        mine = catchlight_crashes(found)
        for rel in mine:
            shutil.copy2(os.path.join(CRASH_DIR, rel), os.path.join(out_dir, os.path.basename(rel)))
        print(f"{len(mine)} Catchlight crash report(s)" + (": " + ", ".join(mine) if mine else ""))

    tail = diagnostics_text(entries).splitlines()[-args.tail:]
    if tail:
        print(f"--- last {len(tail)} entries ---")
        print("\n".join(tail))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--dest", default=APP_DEST, help=f"the installed copy (default {APP_DEST})")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status", parents=[common], help="which build is installed, against origin/main")
    p_install = sub.add_parser("install", parents=[common], help="clean-build a ref and install it")
    p_install.add_argument("--ref", default="origin/main", help="git ref to build (default origin/main)")
    p_install.add_argument("--launch", action="store_true", help="open the new build afterwards")
    p_logs = sub.add_parser("logs", parents=[common], help="read the diagnostics log (and crashes)")
    p_logs.add_argument("--crashes", action="store_true", help="also copy Catchlight crash reports")
    p_logs.add_argument("--out", help="folder to write into (default ~/CatchlightBuild/mac-logs/<time>)")
    p_logs.add_argument("--tail", type=int, default=20, help="how many recent entries to print")
    args = parser.parse_args(argv)
    try:
        return {"status": cmd_status, "install": cmd_install, "logs": cmd_logs}[args.command](args)
    except Failure as exc:
        print(f"FAILED: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
