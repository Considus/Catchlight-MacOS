#!/usr/bin/env python3
"""Tests for the pure parts of device.py: log text, crash filtering, reading a bundle.

    python3 scripts/device/test_device.py

Building, installing and quitting the app are proved by running the commands.
"""

import os
import plistlib
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


class MalformedLog(unittest.TestCase):
    def test_a_bad_entry_is_shown_raw_and_sorted_last(self):
        saved = os.environ.get("TZ")
        os.environ["TZ"] = "UTC"
        __import__("time").tzset()
        try:
            text = device.diagnostics_text([{"category": "storage"},
                                            {"timestamp": 0, "category": "storage", "message": "ok"}])
        finally:
            if saved is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = saved
            __import__("time").tzset()
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
