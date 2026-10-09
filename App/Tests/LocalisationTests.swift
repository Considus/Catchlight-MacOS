import XCTest
import WebKit

/// The page's localisation (`ui/i18n.js` and `ui/l10n/Localizable.xcstrings`): `t()` looks a
/// sentence up in the language the shell names, fills its placeholders, picks the plural form for
/// the count, and falls back to English; and the real page reads in that language.
final class LocalisationTests: XCTestCase {
    private var dir: URL!
    private var bridge: ShellBridge!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-l10n-\(UUID())/Catchlight")
    }

    override func tearDown() {
        bridge = nil
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    /// The real page, with an account (so it opens on the main window), in `language`.
    private func page(language: String) throws -> WebViewHarness {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        bridge = ShellBridge()
        bridge.vault = vault
        bridge.language = language
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)
        return harness
    }

    /// The catalog's text for `key` in `lang` (a plural's `form`), read here rather than written
    /// into the test, so a reworded translation doesn't break it.
    private func catalog(_ key: String, _ lang: String, form: String? = nil) throws -> String {
        let url = WebViewHarness.repoUI.appendingPathComponent("l10n/Localizable.xcstrings")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entry = try XCTUnwrap((root["strings"] as? [String: Any])?[key] as? [String: Any], "no \(key) in the catalog")
        let loc = try XCTUnwrap((entry["localizations"] as? [String: Any])?[lang] as? [String: Any], "no \(lang) for \(key)")
        let unit = form.flatMap { ((loc["variations"] as? [String: Any])?["plural"] as? [String: Any])?[$0] as? [String: Any] } ?? loc
        return try XCTUnwrap((unit["stringUnit"] as? [String: Any])?["value"] as? String)
    }

    private func js(_ harness: WebViewHarness, _ expression: String) throws -> String? {
        try harness.run("return \(expression);", in: self) as? String
    }

    func testTLooksUpFillsPlaceholdersAndPicksThePluralInTheShellsLanguage() throws {
        let harness = try page(language: "de")
        XCTAssertEqual(try js(harness, "L10N.lang"), "de")
        XCTAssertEqual(try js(harness, "document.documentElement.lang"), "de")
        // Lookup.
        XCTAssertEqual(try js(harness, "t('Cancel')"), try catalog("Cancel", "de"))
        XCTAssertNotEqual(try js(harness, "t('Cancel')"), "Cancel")
        // Placeholders, by position.
        let created = try catalog("Created on %1$@ at %2$@", "de")
        XCTAssertEqual(try js(harness, "t('Created on %1$@ at %2$@', 'DAY', 'TIME')"),
                       created.replacingOccurrences(of: "%1$@", with: "DAY").replacingOccurrences(of: "%2$@", with: "TIME"))
        // A plural: each count gets its own form.
        let key = "%lld Takes changed on another device."
        XCTAssertEqual(try js(harness, "t('\(key)', 1)"), try catalog(key, "de", form: "one").replacingOccurrences(of: "%lld", with: "1"))
        XCTAssertEqual(try js(harness, "t('\(key)', 3)"), try catalog(key, "de", form: "other").replacingOccurrences(of: "%lld", with: "3"))
        // Two counts in one sentence, each with its own plural (the catalog's substitutions).
        let both = try XCTUnwrap(try js(harness, "t('%1$lld Takes and %2$lld Scripts changed on another device.', 1, 2)"))
        XCTAssertTrue(both.contains("1") && both.contains("2") && !both.contains("%"), both)
        // A key the catalog doesn't hold reads as its English.
        XCTAssertEqual(try js(harness, "t('Not in the catalog: %@', 'x')"), "Not in the catalog: x")
    }

    func testEnglishIsTheFallbackAndHasItsOwnPlurals() throws {
        // A language the app doesn't have reads English, whatever the browser engine prefers.
        let harness = try page(language: "xx")
        XCTAssertEqual(try js(harness, "L10N.lang"), "en")
        XCTAssertEqual(try js(harness, "t('Cancel')"), "Cancel")
        XCTAssertEqual(try js(harness, "t('%lld Takes changed on another device.', 1)"), "1 Take changed on another device.")
        XCTAssertEqual(try js(harness, "t('%lld Takes changed on another device.', 2)"), "2 Takes changed on another device.")
        XCTAssertEqual(try js(harness, "t('%1$lld Takes and %2$lld Scripts changed on another device.', 1, 2)"), "1 Take and 2 Scripts changed on another device.")
        // The device's language tag to the catalog's language.
        XCTAssertEqual(try js(harness, "JSON.stringify(['zh-TW', 'zh-HK', 'zh-CN', 'pt', 'pt-PT', 'pt-AO', 'nn-NO', 'no', 'de-AT', 'en-GB', 'xx'].map(L10N.match))"),
                       #"["zh-Hant","zh-Hant","zh-Hans","pt-BR","pt-PT","pt-PT","nb","nb","de","en",null]"#)
    }

    func testTheRealPageReadsInGermanWhenTheShellSaysSo() throws {
        let harness = try page(language: "de")
        // Text painted by JavaScript: the empty Dailies, and a dock button's label.
        XCTAssertEqual(try js(harness, "document.querySelector('#takes .first-take p').textContent"), try catalog("Your first Take is waiting.", "de"))
        XCTAssertEqual(try js(harness, "document.querySelector('#takes-dock [data-act=add]').getAttribute('aria-label')"), try catalog("Add Take", "de"))
        // Static text in index.html, through data-i18n.
        XCTAssertEqual(try js(harness, "document.querySelector('#search').placeholder"), try catalog("Search Scripts", "de"))
        // The native menu bar is built from the page's model, so it reads German too.
        XCTAssertEqual(try js(harness, "catchlightMenu.model()[1].title"), try catalog("File", "de"))
        // Settings.
        XCTAssertEqual(try js(harness, "(openSettings(), document.querySelector('#settings .page-heading').textContent)"), try catalog("Settings", "de"))
    }

    /// A place named "Current location" is stored in English whatever the language, as the iPhone
    /// stores it (its address lookup replaces only that exact name), and shown translated.
    func testCurrentLocationIsStoredInEnglishAndShownTranslated() throws {
        let harness = try page(language: "de")
        let result = try harness.run("""
            const take = { id: newId(), at: new Date().toISOString(), isNote: true, blocks: [{ k: 'text', text: 'x' }] };
            openReminder(take, null);
            rs.tab = 'place'; paintReminder();
            rsheet.querySelector('[data-r=current]').click();
            const field = rsheet.querySelector('[data-r=name]').value;
            rsheet.querySelector('[data-r=done]').click();
            return JSON.stringify([take.reminder.name, field, reminderLine(take.reminder)]);
            """, in: self) as? String
        let german = try catalog("Current location", "de")
        let shown = try XCTUnwrap(result.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] })
        XCTAssertEqual(shown[0], "Current location")
        XCTAssertEqual(shown[1], german)
        XCTAssertTrue(shown[2].hasPrefix(german), shown[2])
    }

    /// The built-in English in i18n.js says what the catalog's English says, so a page whose
    /// catalog didn't load still reads "1 Take changed on another device." and "View".
    func testTheBuiltInEnglishMatchesTheCatalog() throws {
        let harness = try page(language: "en")
        let mismatches = try harness.run("""
            const cat = JSON.parse(await (await fetch('l10n/Localizable.xcstrings')).text()).strings;
            const out = [];
            for (const [key, entry] of Object.entries(cat)) {
              if (!entry.localizations?.en) continue;
              const specs = [...key.matchAll(/%(?:(\\d+)\\$)?(@|lld)/g)].map((m, i) => [m[1] ? +m[1] - 1 : i, m[2]]);
              for (const counts of [[1, 1], [2, 1], [1, 2], [3, 3]]) {
                const args = [];
                let c = 0;
                for (const [pos, type] of specs) args[pos] = type === '@' ? 'x' : counts[c++ % 2];
                if (t(key, ...args) !== t.fallback(key, ...args)) out.push(key + ' ' + JSON.stringify(args) + ': ' + t(key, ...args) + ' / ' + t.fallback(key, ...args));
              }
            }
            return JSON.stringify(out);
            """, in: self) as? String
        XCTAssertEqual(mismatches, "[]")
        XCTAssertEqual(try js(harness, "t.fallback('%lld Takes changed on another device.', 1)"), "1 Take changed on another device.")
        XCTAssertEqual(try js(harness, "t.fallback('View menu')"), "View")
    }

    /// The native text: `String(localized:)` reads German from the German folder the catalog
    /// builds, and the language the shell gives the page is one the bundle has.
    func testTheNativeStringsReadGermanFromTheGermanFolder() throws {
        let bundle = Bundle(for: LocalisationTests.self)
        let de = try XCTUnwrap(bundle.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)), "no de.lproj built")
        let url = WebViewHarness.repoUI.deletingLastPathComponent().appendingPathComponent("App/Resources/Localizable.xcstrings")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entry = try XCTUnwrap((root["strings"] as? [String: Any])?["Catchlight is locked"] as? [String: Any])
        let german = try XCTUnwrap(((entry["localizations"] as? [String: Any])?["de"] as? [String: Any]).flatMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String })
        XCTAssertEqual(String(localized: "Catchlight is locked", bundle: de), german)
        XCTAssertNotEqual(german, "Catchlight is locked")
        XCTAssertTrue(bundle.localizations.contains(ShellBridge.language(from: bundle)), bundle.localizations.description)
    }

    /// The catalog holds every key the page and the native code use, in all 18 languages, and
    /// every translation keeps the English placeholders (scripts/l10n/check_catalogs.py).
    func testTheCatalogsAreCompleteAndKeepTheirPlaceholders() throws {
        let repo = WebViewHarness.repoUI.deletingLastPathComponent()
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("no python3 on this machine") }
        let process = Process()
        process.executableURL = python
        process.arguments = [repo.appendingPathComponent("scripts/l10n/check_catalogs.py").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("0 problems"), text)
    }
}
