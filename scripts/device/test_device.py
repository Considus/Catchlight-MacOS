#!/usr/bin/env python3
"""Tests for the pure parts of device.py: log text, crash filtering, reading a bundle.

    python3 scripts/device/test_device.py

Building, installing and quitting the app are proved by running the commands.
"""

import os
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import device  # noqa: E402


class DiagnosticsText(unittest.TestCase):
    def setUp(self):
        self._tz = os.environ.get("TZ")
        os.environ["TZ"] = "UTC"
        time.tzset()

    def tearDown(self):
        if self._tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = self._tz
        time.tzset()

    def test_reference_date_and_order(self):
        # 0 s is 2001-01-01 00:00:00 UTC (Foundation's reference date);
        # 812678400 s later is 2026-10-03 00:00:00 UTC.
        entries = [{"timestamp": 812678400, "category": "sync", "message": "pass complete"},
                   {"timestamp": 0, "category": "storage", "message": "[CCIOS-101] first"}]
        self.assertEqual(device.diagnostics_text(entries),
                         "2001-01-01 00:00:00  [storage]  [CCIOS-101] first\n"
                         "2026-10-03 00:00:00  [sync]  pass complete\n")

    def test_a_bad_entry_is_shown_raw_and_sorted_last(self):
        text = device.diagnostics_text([{"category": "storage"},
                                        {"timestamp": 0, "category": "storage", "message": "ok"}])
        self.assertEqual(text, '2001-01-01 00:00:00  [storage]  ok\n'
                               '(malformed entry) {"category": "storage"}\n')


class CrashFilter(unittest.TestCase):
    def test_keeps_only_catchlight_reports(self):
        paths = ["Catchlight-2026-10-03-202322.ips", "Retired/Catchlight-2026-09-01-080000.ips",
                 "com.apple.WebKit.WebContent-2026-10-03-202330.ips", "NotCatchlight-2026.ips",
                 "Catchlight-2026-10-03.diag"]
        self.assertEqual(device.catchlight_crashes(paths),
                         ["Catchlight-2026-10-03-202322.ips", "Retired/Catchlight-2026-09-01-080000.ips"])


class BundleBuild(unittest.TestCase):
    def test_reads_version_and_stamp(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = os.path.join(tmp, "Catchlight.app")
            os.makedirs(os.path.join(app, "Contents"))
            with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
                plistlib.dump({"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "3b5246e"}, f)
            self.assertEqual(device.bundle_build(app), ("0.1.0", "3b5246e"))

    def test_missing_bundle_is_none(self):
        self.assertIsNone(device.bundle_build("/nonexistent/Catchlight.app"))


def fake_app(path, stamp):
    os.makedirs(os.path.join(path, "Contents"))
    with open(os.path.join(path, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": stamp}, f)


class SwapIn(unittest.TestCase):
    """The previous copy survives a failed or interrupted install."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dest = os.path.join(self.tmp.name, "Applications", "Catchlight.app")
        self.built = os.path.join(self.tmp.name, "built", "Catchlight.app")
        fake_app(self.dest, "aaaaaaa")
        self._running, device.app_running = device.app_running, lambda: False

    def tearDown(self):
        device.app_running = self._running
        self.tmp.cleanup()

    def test_good_build_replaces_the_copy(self):
        fake_app(self.built, "bbbbbbb")
        device.swap_in(self.built, self.dest, "bbbbbbb")
        self.assertEqual(device.bundle_build(self.dest), ("0.1.0", "bbbbbbb"))
        self.assertFalse(os.path.exists(self.dest + ".previous"))

    def test_wrong_stamp_puts_the_previous_copy_back(self):
        fake_app(self.built, "ccccccc")
        with self.assertRaises(device.Failure):
            device.swap_in(self.built, self.dest, "bbbbbbb")
        self.assertEqual(device.bundle_build(self.dest), ("0.1.0", "aaaaaaa"))

    def test_interrupt_mid_copy_puts_the_previous_copy_back(self):
        fake_app(self.built, "bbbbbbb")
        real_run = device.run

        def interrupted(cmd, *a, **k):
            if cmd[0] == "ditto":
                raise KeyboardInterrupt
            return real_run(cmd, *a, **k)
        device.run = interrupted
        try:
            with self.assertRaises(KeyboardInterrupt):
                device.swap_in(self.built, self.dest, "bbbbbbb")
        finally:
            device.run = real_run
        self.assertEqual(device.bundle_build(self.dest), ("0.1.0", "aaaaaaa"))

    def test_a_copy_stranded_at_previous_is_recovered_not_deleted(self):
        os.rename(self.dest, self.dest + ".previous")
        fake_app(self.built, "ccccccc")
        with self.assertRaises(device.Failure):
            device.swap_in(self.built, self.dest, "bbbbbbb")
        self.assertEqual(device.bundle_build(self.dest), ("0.1.0", "aaaaaaa"))


class AgainstTheInstalled(unittest.TestCase):
    """check_against_installed on a throwaway repo: A is the older commit, B the newer."""
    @classmethod
    def setUpClass(cls):
        cls.repo = tempfile.mkdtemp()
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")

        def git(*a):
            return subprocess.run(["git", "-C", cls.repo, *a], capture_output=True, text=True, check=True, env=env).stdout.strip()
        git("init", "-q", "-b", "main")
        for name in ("a", "b"):
            open(os.path.join(cls.repo, name + ".txt"), "w").write(name)
            git("add", "-A")
            git("commit", "-q", "-m", name)
            setattr(cls, name, git("rev-parse", "--short", "HEAD"))

    def check(self, stamp, sha, **kw):
        device.check_against_installed(self.repo, ("1.0", stamp), sha, **kw)

    def test_an_older_build_than_the_installed_one_is_refused(self):
        with self.assertRaises(device.Failure) as caught:
            self.check(self.b, self.a)
        self.assertIn("downgrade", str(caught.exception))

    def test_the_flag_the_same_build_and_a_newer_one_pass(self):
        self.check(self.b, self.a, allow_downgrade=True)
        self.check(self.b, self.b)
        self.check(self.a, self.b)

    def test_a_dirty_stamp_is_compared_by_its_commit(self):
        with self.assertRaises(device.Failure):
            self.check(self.b + "+dirty", self.a)
        self.check(self.a + "+dirty", self.b)

    def test_a_pre_stamp_unknown_or_missing_build_installs_fresh(self):
        self.check("1", self.a)
        self.check("deadbee+dirty", self.a)
        self.check("deadbee", self.a)
        device.check_against_installed(self.repo, None, self.a)


if __name__ == "__main__":
    unittest.main(verbosity=2)
