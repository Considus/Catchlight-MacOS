import XCTest
import CryptoKit
import CatchlightAppleStorage
import WebKit
import CatchlightCore

/// Import notes (M3), as the iPhone's `ImportCoordinator`: the decode chain, a folder of mixed
/// files, and the real page importing from the sync folder's Import folder and from picked files.
final class NoteImportTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-import-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Cloud/Import"), withIntermediateDirectories: true)
        suite = "catchlight.tests.\(UUID())"
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private var importFolder: URL { root.appendingPathComponent("Cloud/Import") }

    // MARK: Decoding

    func testDecodeUTF8UTF16AndLatin1() throws {
        XCTAssertEqual(NoteImport.decodeText(Data("Café ☕".utf8), isRTF: false), "Café ☕")
        var utf16 = Data([0xFF, 0xFE]); utf16.append("Notepad".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(NoteImport.decodeText(utf16, isRTF: false), "Notepad")
        XCTAssertEqual(NoteImport.decodeText(Data([0x43, 0x61, 0x66, 0xE9]), isRTF: false), "Café")
    }

    func testRTFComesThroughAsItsWordsOnly() throws {
        let rtf = Data(#"{\rtf1\ansi{\fonttbl\f0 Helvetica;}\f0\b Bold\b0  and plain}"#.utf8)
        XCTAssertEqual(NoteImport.decodeText(rtf, isRTF: true)?.trimmingCharacters(in: .whitespacesAndNewlines), "Bold and plain")
    }

    // MARK: A folder

    func testAFolderOfNotesAndAnExport() throws {
        try "# Shopping\n- [ ] Milk".write(to: importFolder.appendingPathComponent("b-list.md"), atomically: true, encoding: .utf8)
        try "A plain note".write(to: importFolder.appendingPathComponent("a-note.txt"), atomically: true, encoding: .utf8)
        try "".write(to: importFolder.appendingPathComponent("c-empty.md"), atomically: true, encoding: .utf8)
        try "not a note".write(to: importFolder.appendingPathComponent("d-image.png"), atomically: true, encoding: .utf8)
        // A Catchlight export of a Take and a Script splits back into both.
        let take = Take(blocks: [.text(TextBlock(text: "Exported Take"))])
        var script = Take(blocks: [.text(TextBlock(text: "# Exported Script"))], kind: ManifestEntry.Kind.script)
        script.pageMode = Take.PageMode.a4
        try TakeExporter.export([take, script]).write(to: importFolder.appendingPathComponent("e-export.md"), atomically: true, encoding: .utf8)

        let files = try FileManager.default.contentsOfDirectory(at: importFolder, includingPropertiesForKeys: nil)
            .filter { NoteImport.extensions.contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let outcome = NoteImport.parse(files)
        XCTAssertEqual(outcome.scanned, 4, "the .png is never read")
        XCTAssertEqual(outcome.skipped, 1, "the empty file")
        XCTAssertEqual(outcome.items.count, 4)
        XCTAssertEqual(outcome.items.filter(\.isScript).count, 1, "a Script exported as one comes back as a Script")
        XCTAssertEqual(outcome.items.first(where: \.isScript)?.pageMode, Take.PageMode.a4)
    }

    /// Claude review on #57: a note the library can't write is counted, never lost silently.
    func testANoteTheLibraryCannotWriteIsCounted() throws {
        let keys = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
        let store = FailingStore(try EncryptedTakeStore(keys: keys, directoryURL: root.appendingPathComponent("Failing")))
        let library = Library(store: store, scripts: try ScriptVault(keys: keys, directory: root.appendingPathComponent("Failing/Scripts")))
        store.failUpserts = true
        let done = library.importItems([Take(blocks: [.text(TextBlock(text: "one"))]), Take(blocks: [.text(TextBlock(text: "two"))])])
        XCTAssertEqual(done.takes, 0)
        XCTAssertEqual(done.failed, 2)
    }

    // MARK: The real page

    private func page(folder: Bool) throws -> (WebViewHarness, Vault, ShellBridge) {
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Library"))
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let defaults = UserDefaults(suiteName: suite)!
        let syncFolder = SyncFolder(defaults: defaults)
        if folder {
            syncFolder.pick = { [root] _, done in done(root!.appendingPathComponent("Cloud")) }
            syncFolder.choose(in: nil) { _ in }
        }
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.vault = vault
        bridge.syncFolder = syncFolder
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)
        return (harness, vault, bridge)
    }

    /// Run an import from the page, answer its confirmation, and return the message it ends on.
    private func run(_ js: String, in harness: WebViewHarness) throws -> String? {
        try harness.run("""
            \(js);
            const proceed = [...document.querySelectorAll('dialog[open] button')].find(b => b.textContent === 'Proceed');
            if (proceed) proceed.click();
            for (let i = 0; i < 100; i++) {
              const p = document.querySelector('dialog[open] p')?.textContent ?? '';
              if (p && !p.startsWith('Any items')) return p;
              await new Promise(r => setTimeout(r, 50));
            }
            return null;
            """, in: self) as? String
    }

    func testImportNotesFromTheImportFolder() throws {
        try "First note".write(to: importFolder.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
        try "Second note".write(to: importFolder.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        let (harness, vault, bridge) = try page(folder: true)
        _ = bridge
        XCTAssertEqual(try run("importNotes()", in: harness), "Import successful. 2 Takes added to your timeline.")
        let texts = try vault.library!.store.allTakes().map(\.plainText).sorted()
        XCTAssertEqual(texts, ["First note", "Import successful. 2 Takes added.", "Second note"])
        let shown = try harness.run("return takes.length;", in: self) as? Int
        XCTAssertEqual(shown, 3, "the page shows them")
    }

    func testImportNotesWithNoFolderSaysSo() throws {
        let (harness, _, bridge) = try page(folder: false)
        _ = bridge
        XCTAssertEqual(try run("importNotes()", in: harness), "Set up Cloud Storage first. The Import folder lives inside your sync folder.")
    }

    func testAnEmptyImportFolderSaysSo() throws {
        let (harness, vault, bridge) = try page(folder: true)
        _ = bridge
        XCTAssertEqual(try run("importNotes()", in: harness), "No recognised markdown or text files found in the Import folder.")
        XCTAssertEqual(try vault.library!.store.allTakes().count, 0)
    }

    func testImportFromAFileNeedsNoFolder() throws {
        let file = root.appendingPathComponent("picked.md")
        try "Picked note".write(to: file, atomically: true, encoding: .utf8)
        let (harness, vault, bridge) = try page(folder: false)
        bridge.pickImportFiles = { _, done in done([file]) }
        XCTAssertEqual(try run("importFromFile()", in: harness), "Import successful. 1 Take added to your timeline.")
        XCTAssertTrue(try vault.library!.store.allTakes().contains { $0.plainText == "Picked note" })
    }
}
