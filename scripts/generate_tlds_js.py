#!/usr/bin/env python3
"""Regenerate ui/tlds.js from the TLD list in a Catchlight-Core checkout.

    python3 scripts/generate_tlds_js.py [path/to/Catchlight-Core]

The Core path defaults to `../Catchlight-Core`, the sibling of this repo. The
script reads `Sources/CatchlightCore/Text/TLDList.swift` there and writes the
same set, in the same order, as the prototype's `TLDS` set. It never contacts
IANA: Core's `Scripts/generate_tld_list.py` is the only thing that does, so
refresh Core first and then run this.
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join("Sources", "CatchlightCore", "Text", "TLDList.swift")
OUT = os.path.join(REPO, "ui", "tlds.js")

NUMBER_WORDS = {1: "one", 2: "two", 3: "three", 4: "four", 5: "five",
                6: "six", 7: "seven", 8: "eight", 9: "nine", 10: "ten"}


def read_swift(path):
    """The TLDs (in file order), IANA version and excluded endings from TLDList.swift."""
    with open(path, encoding="utf-8") as handle:
        source = handle.read()

    version = re.search(r'ianaVersion\s*=\s*"(\d+)"', source)
    if not version:
        raise SystemExit(f"{path}: no ianaVersion")

    # Only the array literal, so a TLD named in a comment cannot be counted.
    body = source.split("static let all: Set<String> = [", 1)
    if len(body) != 2:
        raise SystemExit(f"{path}: could not find the TLD array")
    tlds = re.findall(r'"([a-z0-9-]+)"', body[1].split("]", 1)[0])
    if len(tlds) < 1000:
        raise SystemExit(f"{path}: only {len(tlds)} TLDs parsed, expected >1000")
    if len(set(tlds)) != len(tlds):
        raise SystemExit(f"{path}: the TLD array has duplicates")

    # The header names the excluded endings, e.g. "(.java, .md, .mov, .zip)".
    header = source.split("import Foundation", 1)[0]
    excluded = re.search(r"\((\.[a-z0-9-]+(?:, \.[a-z0-9-]+)*)\)", header)
    if not excluded:
        raise SystemExit(f"{path}: could not find the excluded endings in the header")
    return tlds, version.group(1), excluded.group(1).split(", ")


def render(tlds, version, excluded):
    count = NUMBER_WORDS.get(len(excluded), str(len(excluded)))
    return (
        "'use strict';\n"
        f"// GENERATED from Catchlight-Core {SWIFT} (IANA {version}).\n"
        "// Do not edit by hand: run scripts/generate_tlds_js.py so the two lists can't drift. "
        f"{len(tlds)} top-level\n"
        f"// domains, without the {count} left out there as file extensions "
        f"({', '.join(excluded)}).\n"
        f"const TLDS = new Set('{' '.join(tlds)}'.split(' '));\n"
    )


def main():
    core = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, os.pardir, "Catchlight-Core")
    path = os.path.normpath(os.path.join(core, SWIFT))
    if not os.path.isfile(path):
        print(f"generate_tlds_js: no TLDList.swift at {path}\n"
              "Pass the path to a Catchlight-Core checkout.", file=sys.stderr)
        return 2

    tlds, version, excluded = read_swift(path)
    with open(OUT, "w", encoding="utf-8") as handle:
        handle.write(render(tlds, version, excluded))
    print(f"wrote {os.path.relpath(OUT, REPO)}: {len(tlds)} TLDs (IANA {version}), "
          f"excluded {', '.join(excluded)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
