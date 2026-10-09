#!/usr/bin/env python3
"""Check the two String Catalogs against the code that reads them.

    python3 scripts/l10n/check_catalogs.py          # every check; exit 1 lists each problem
    python3 scripts/l10n/check_catalogs.py --keys   # print the keys the code uses, one per line

The page (`ui/`) reads `ui/l10n/Localizable.xcstrings` through `t()` (ui/i18n.js); the native
menus and alerts read `App/Resources/Localizable.xcstrings` through `String(localized:)`. For
each catalog it fails when:

- a key the code uses is missing from the catalog (a `t('…')` or `L10N.t('…')` literal in
  ui/*.js, a `data-i18n` text or `data-i18n-attrs` attribute in ui/index.html, a
  `String(localized: "…")` literal in App/Sources);
- the catalog holds a key no code uses (a stale key is a translation nobody sees);
- a key lacks one of the 18 languages, or one of the CLDR plural categories a language needs
  (pl one/few/many/other, fr one/many/other, ja other…), in a plural or a substitution;
- a translation's placeholders differ from the English: same type at each position, in every
  plural form and substitution (`%1$@ … %2$lld` may reorder `%@ … %lld`). A dropped or retyped
  placeholder garbles or crashes at run time, and nothing else would say so.

Standard library only; run it with any python3.
"""
import html.parser
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LANGUAGES = ["es", "fr", "de", "zh-Hans", "zh-Hant", "da", "nl", "fi", "it", "ja", "nb", "pl",
             "pt-BR", "pt-PT", "sv", "th", "tr", "ko"]
# The CLDR plural categories each language needs for whole numbers, as Intl.PluralRules and
# Foundation choose them. A plural or substitution missing one would fall back to `other`.
PLURAL_CATEGORIES = {
    **{l: {"one", "other"} for l in ("en", "de", "da", "nl", "fi", "nb", "sv", "tr")},
    **{l: {"one", "many", "other"} for l in ("es", "fr", "it", "pt-BR", "pt-PT")},
    "pl": {"one", "few", "many", "other"},
    **{l: {"other"} for l in ("ja", "ko", "th", "zh-Hans", "zh-Hant")},
}
UI_CATALOG = os.path.join(REPO, "ui", "l10n", "Localizable.xcstrings")
APP_CATALOG = os.path.join(REPO, "App", "Resources", "Localizable.xcstrings")

# A JS string literal as the first argument of t( or L10N.t(: '…', "…" or a `…` with no ${}.
JS_CALL = re.compile(r"""(?<![\w$.])(?:L10N\.)?t\(\s*('(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"|`(?:[^`\\$]|\\.)*`)""")
SWIFT_CALL = re.compile(r'String\(localized:\s*"((?:[^"\\]|\\.)*)"')
SPEC = re.compile(r"%(?:(\d+)\$)?(#@\w+@|l{0,2}[@dDuUxXoOfeEgGcCsSp]|%)")


def js_unescape(literal):
    body = literal[1:-1]
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), body)


def ui_keys():
    keys = {}
    ui = os.path.join(REPO, "ui")
    for name in sorted(os.listdir(ui)):
        if not name.endswith(".js") or name == "i18n.js":   # i18n.js holds only examples, in comments
            continue
        text = open(os.path.join(ui, name), encoding="utf-8").read()
        for m in JS_CALL.finditer(text):
            keys.setdefault(js_unescape(m.group(1)), f"ui/{name}:{text.count(chr(10), 0, m.start()) + 1}")

    class Page(html.parser.HTMLParser):
        def __init__(self):
            super().__init__()
            self.stack = []

        def handle_starttag(self, tag, attrs):
            a = dict(attrs)
            for attr in (a.get("data-i18n-attrs") or "").split():
                keys.setdefault(a.get(attr) or "", f"ui/index.html {tag} {attr}")
            self.stack.append([tag, "data-i18n" in a, ""])

        def handle_endtag(self, tag):
            while self.stack:
                t, wanted, text = self.stack.pop()
                if wanted:
                    keys.setdefault(text.strip(), f"ui/index.html <{t}>")
                if self.stack:
                    self.stack[-1][2] += text
                if t == tag:
                    break

        def handle_data(self, data):
            if self.stack:
                self.stack[-1][2] += data

    Page().feed(open(os.path.join(ui, "index.html"), encoding="utf-8").read())
    keys.pop("", None)
    return keys


def swift_keys():
    """String(localized:) literals, each `\\(…)` read as the placeholder Xcode would write."""
    keys = {}
    root = os.path.join(REPO, "App", "Sources")
    for folder, _, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            text = open(path, encoding="utf-8").read()
            for m in SWIFT_CALL.finditer(text):
                key = re.sub(r"\\\((String\(describing:[^)]*\))\)", "%@", m.group(1))
                key = re.sub(r"\\\([^)]*\)", "%lld", key)
                key = re.sub(r'\\(.)', r"\1", key)
                keys.setdefault(key, f"{os.path.relpath(path, REPO)}:{text.count(chr(10), 0, m.start()) + 1}")
    return keys


def signature(text):
    """Placeholder types by position, e.g. {1: '@', 2: 'lld'}; '%%' is not one."""
    sig, auto = {}, 0
    for m in SPEC.finditer(text):
        if m.group(2) == "%":
            continue
        auto += 1
        sig[int(m.group(1)) if m.group(1) else auto] = m.group(2)
    return sig


def expanded(loc):
    """Each full text a localisation can produce, with its substitutions written in as typed
    placeholders, so the result compares with the English key."""
    if "stringUnit" in loc:
        bases = [("", loc["stringUnit"]["value"])]
    else:
        bases = [(f"plural.{form}", v["stringUnit"]["value"])
                 for form, v in loc.get("variations", {}).get("plural", {}).items()]
    out = []
    for label, base in bases:
        subs = loc.get("substitutions", {})
        texts = [(label, base)]
        for name, sub in subs.items():
            spec = sub.get("formatSpecifier", "lld")
            pos = sub.get("argNum", 1)
            nxt = []
            for lab, text in texts:
                for form, v in sub.get("variations", {}).get("plural", {}).items():
                    piece = re.sub(r"%(?:\d+\$)?arg", f"%{pos}${spec}", v["stringUnit"]["value"])
                    nxt.append((f"{lab} {name}.{form}".strip(), re.sub(r"%(?:\d+\$)?#@" + name + "@", piece, text)))
            texts = nxt
        out.extend(texts)
    return out


def check(catalog_path, used, label):
    problems = []
    data = json.load(open(catalog_path, encoding="utf-8"))
    strings = data["strings"]
    for key, where in sorted(used.items()):
        if key not in strings:
            problems.append(f"{label}: missing from the catalog: {key!r} ({where})")
    for key in sorted(set(strings) - set(used)):
        problems.append(f"{label}: no code uses {key!r}")
    for key, entry in sorted(strings.items()):
        locs = entry.get("localizations", {})
        want = signature(key)
        en_forms = locs.get("en", {}).get("variations", {}).get("plural")
        if en_forms is not None and not PLURAL_CATEGORIES["en"] <= set(en_forms):
            problems.append(f"{label}: en {key!r} lacks plural forms")
        if "en" in locs:
            for lab, text in expanded(locs["en"]):
                if signature(text) != want and text != key:
                    if not set(signature(text).items()) <= set(want.items()):
                        problems.append(f"{label}: en {lab} {key!r}: placeholders {signature(text)} != {want}")
        for lang in LANGUAGES:
            loc = locs.get(lang)
            if not loc:
                problems.append(f"{label}: {lang} missing for {key!r}")
                continue
            need = PLURAL_CATEGORIES[lang]
            forms = loc.get("variations", {}).get("plural")
            if forms is not None and not need <= set(forms):
                problems.append(f"{label}: {lang} {key!r} lacks plural forms {sorted(need - set(forms))}")
            for sub, s in loc.get("substitutions", {}).items():
                got = set(s.get("variations", {}).get("plural", {}))
                if not need <= got:
                    problems.append(f"{label}: {lang} {key!r} substitution {sub} lacks forms {sorted(need - got)}")
            texts = expanded(loc)
            if not texts:
                problems.append(f"{label}: {lang} has no text for {key!r}")
            for lab, text in texts:
                got = signature(text)
                # A singular form may leave its count out ("Un Take", "one note"), never another placeholder.
                ok = got == want or (lab and "one" in lab and set(got.items()) <= set(want.items())
                                      and all(want[p] in ("lld", "d") for p in set(want) - set(got)))
                if not ok:
                    problems.append(f"{label}: {lang} {lab} {key!r}\n    want {want}, got {got}: {text!r}")
    return problems, len(used), len(strings)


def main(argv):
    ui, app = ui_keys(), swift_keys()
    if "--keys" in argv:
        for k in sorted(ui):
            print(json.dumps(k, ensure_ascii=False))
        print("---")
        for k in sorted(app):
            print(json.dumps(k, ensure_ascii=False))
        return 0
    problems = []
    for path, used, label in ((UI_CATALOG, ui, "ui"), (APP_CATALOG, app, "app")):
        p, n_used, n_cat = check(path, used, label)
        problems += p
        print(f"{label}: {n_used} keys in the code, {n_cat} in {os.path.relpath(path, REPO)}")
    for p in problems:
        print(p)
    print(f"{len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
