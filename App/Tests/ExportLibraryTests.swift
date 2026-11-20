import AppKit
import WebKit
import XCTest
import CatchlightCore

/// Export (Settings ▸ Export Takes, the menu, Start over, the No Privacy phrase strip) writes the
/// whole library through Core's exporter, the iPhone's format with its data block, so every Take
/// and every Script comes back through Import from a file with its marks (owner, 2026-11-20:
/// "Both", the export before Start over saves Scripts as well as Takes).
final class ExportLibraryTests: XCTestCase {
    private var root: URL!
    private var keep: [AnyObject] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-export-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        keep = []
    }

    private let day: TimeInterval = 86_400
    private let base = Date(timeIntervalSince1970: 1_793_000_000)   // November 2026, a fixed moment

    /// A library holding a Take with every mark, a checklist, a reminder and a Script.
    private func library() throws -> (Vault, [Take]) {
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Library-\(UUID())"))
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let marked = Take(createdAt: base, modifiedAt: base + 60, blocks: [.text(TextBlock(text: "Every mark"))],
                          isObie: true, isImportant: true, manualOrder: 2.5)
        let checklist = Take(createdAt: base + day, modifiedAt: base + day,
                             blocks: [.check(ChecklistItem(text: "Milk", isComplete: true)), .check(ChecklistItem(text: "Eggs"))])
        let id = UUID()
        let reminder = Take(id: id, createdAt: base + 2 * day, modifiedAt: base + 2 * day, blocks: [.text(TextBlock(text: "Call Sam"))],
                            timeReminder: TimeReminder(scheduledDate: base + 20 * day, notificationIdentifier: id.uuidString))
        let script = Take(createdAt: base + 3 * day, modifiedAt: base + 3 * day,
                          blocks: [.text(TextBlock(text: "# Winter series")), .text(TextBlock(text: "Twelve prints, one per month."))],
                          kind: ManifestEntry.Kind.script, pageMode: Take.PageMode.a4)
        for take in [marked, checklist, reminder, script] { try vault.library!.store.upsert(take) }
        return (vault, [marked, checklist, reminder, script])
    }

    /// The page on that library, its save panel answering `target`.
    private func page(_ vault: Vault, chooses target: URL?) -> WebViewHarness {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil, privateStorage: true)
        let bridge = ShellBridge()
        bridge.vault = vault
        bridge.pickSaveURL = { _, _, done in done(target) }
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)
        keep += [bridge, harness]
        return harness
    }

    private func waitForFile(_ url: URL) {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testTheExportBringsBackEveryTakeAndScriptWithItsMarks() throws {
        let (vault, made) = try library()
        let target = root.appendingPathComponent("export.md")
        let reply = try page(vault, chooses: target).run("return await window.catchlightBridge.shell.exportLibrary('catchlight-2026-11-20.md');", in: self) as? [String: Bool]
        XCTAssertEqual(reply, ["saved": true])
        waitForFile(target)

        let back = NoteImport.parse([target]).items
        XCTAssertEqual(back.count, 4, "three Takes and the Script")
        func find(_ text: String) throws -> Take { try XCTUnwrap(back.first { $0.plainText.contains(text) }, text) }

        let marked = try find("Every mark")
        XCTAssertTrue(marked.isImportant, "Important survives")
        XCTAssertTrue(marked.isObie, "Obie survives")
        XCTAssertEqual(marked.manualOrder, 2.5, "the manual order survives")
        XCTAssertEqual(marked.createdAt, made[0].createdAt)
        XCTAssertFalse(marked.isScript)

        let checklist = try find("Milk")
        XCTAssertEqual(checklist.blocks.compactMap { if case .check(let c) = $0 { return "\(c.text):\(c.isComplete)" } else { return nil } }, ["Milk:true", "Eggs:false"])

        let reminder = try find("Call Sam")
        XCTAssertEqual(reminder.timeReminder?.scheduledDate, made[2].timeReminder?.scheduledDate)

        let script = try find("Winter series")
        XCTAssertTrue(script.isScript, "a Script comes back as a Script")
        XCTAssertEqual(script.pageMode, Take.PageMode.a4)
        XCTAssertEqual(script.plainText, made[3].plainText)

        // And all the way in: a fresh account imports the file and shows the Script among its Scripts.
        // Its own folder: the first page is still open on the first library and may still write to it.
        let fresh = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Fresh"))
        try fresh.createAccount(words: try Vault.newPhrase(), restored: false)
        let counts = fresh.library!.importItems(back)
        XCTAssertEqual(counts.takes, 3); XCTAssertEqual(counts.scripts, 1); XCTAssertEqual(counts.failed, 0)
        let snapshot = try fresh.library!.snapshot()
        XCTAssertEqual(snapshot.scripts.count, 1)
        XCTAssertEqual(snapshot.takes.count, 3)
    }

    func testCancelledWritesNothing() throws {
        let (vault, _) = try library()
        let reply = try page(vault, chooses: nil).run("return await window.catchlightBridge.shell.exportLibrary('a.md');", in: self) as? [String: Bool]
        XCTAssertEqual(reply, ["cancelled": true])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".md") }, [])
    }

    func testNoOpenLibraryRefuses() throws {
        let (vault, _) = try library()
        let harness = page(vault, chooses: root.appendingPathComponent("x.md"))
        vault.lock()
        let reply = try harness.run("try { await window.catchlightBridge.shell.exportLibrary('a.md'); return 'resolved'; } catch (e) { return String(e); }", in: self) as? String
        XCTAssertNotEqual(reply, "resolved", "a locked library exports nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("x.md").path))
    }

    /// Every way to export the whole library goes through the shell's exporter, after the page has
    /// sent its last edit (a Take being typed, a Script's pending save).
    func testEachExportSavesTheLastEditFirstThenAsksTheShell() throws {
        for (name, trigger) in [
            ("Settings row", "openSettings(); document.querySelector('[data-open=\"export\"]').click();"),
            ("Start over", "startOver(); [...alertBox.querySelectorAll('button')].find(b => b.textContent === 'Export Takes and Scripts').click();"),
            ("menu", "catchlightMenu.run('exportTakes');"),
            ("No Privacy phrase strip", "exportReadable(); [...alertBox.querySelectorAll('button')].find(b => b.textContent === 'Export anyway').click();"),
        ] {
            let (vault, _) = try library()
            let target = root.appendingPathComponent("\(UUID()).md")
            let harness = page(vault, chooses: target)
            _ = try harness.run("""
                takes.find(t => t.blocks?.[0]?.text === 'Call Sam').blocks[0].text = 'Call Sam today'; saveTakes();
                \(trigger)
                return 0;
                """, in: self)
            waitForFile(target)
            let written = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
            XCTAssertTrue(written.contains("<!-- catchlight:data"), "\(name): Core's format, with its data block")
            XCTAssertTrue(written.contains("Winter series"), "\(name): the Scripts are in it")
            XCTAssertTrue(written.contains("Call Sam today"), "\(name): the last edit is in it")
        }
    }
}
