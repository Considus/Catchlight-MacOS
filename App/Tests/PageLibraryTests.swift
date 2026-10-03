import XCTest
import WebKit
import CatchlightCore

/// The real `ui/` in a WKWebView with the real bridge and a Vault on a temporary folder: what the
/// page shows comes out of the encrypted library, and what it saves goes back into it.
final class PageLibraryTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-page-\(UUID())/Catchlight")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func page(with vault: Vault) -> (WebViewHarness, ShellBridge) {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.vault = vault
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)
        return (harness, bridge)
    }

    /// A message round trip: the bridge answers in order, so every save sent before it is written.
    private let settle = "await window.webkit.messageHandlers.catchlight.postMessage({cmd: 'validatePhrase', words: []});"

    func testThePageShowsTheLibraryAndSavesEditsBackIntoIt() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let id = UUID()
        _ = try vault.library!.saveTakes([["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true,
                                           "blocks": [["k": "text", "text": "From the library"]]]])
        let (harness, bridge) = page(with: vault)
        _ = bridge

        let shown = try harness.run("return JSON.stringify(takes.map(t => t.blocks[0].text));", in: self) as? String
        XCTAssertEqual(shown, #"["From the library"]"#)
        XCTAssertEqual(try harness.run("return localStorage.getItem('cl.takes2');", in: self) as? NSNull, NSNull(), "Takes must not reach localStorage")

        _ = try harness.run("""
            takes[0].blocks[0].text = 'Edited on the Mac'; takes[0].modifiedAt = Date.now(); saveTakes();
            \(settle) return true;
            """, in: self)
        XCTAssertEqual(try vault.library!.store.take(id: id)?.blocks.first.map { "\($0)" }.map { $0.contains("Edited on the Mac") }, true)
    }

    func testFirstRunMakesTheAccountAndSeedsTheLibrary() throws {
        let secrets = MemorySecrets()
        let vault = Vault(secrets: secrets, directory: dir)
        try vault.start()
        let (harness, bridge) = page(with: vault)
        _ = bridge

        let result = try harness.run("""
            fr.words = shell.newPhrase();
            const valid = await shell.phraseLooksValid(fr.words);
            fr.storage = 'local';
            await finish();
            \(settle)
            return JSON.stringify({ count: fr.words.length, valid, account: localStorage.getItem('cl.account') });
            """, in: self) as? String
        let json = try XCTUnwrap(result.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        XCTAssertEqual(json["count"] as? Int, 12)
        XCTAssertEqual(json["valid"] as? Bool, true)
        XCTAssertFalse((json["account"] as? String ?? "").contains("phrase"), "the phrase must not reach localStorage")

        XCTAssertTrue(secrets.hasAccount)
        let seeds = try XCTUnwrap(vault.library).store.allTakes()
        XCTAssertEqual(seeds.count, 5)
        XCTAssertEqual(seeds.filter(\.isObie).count, 1)
        XCTAssertNotNil(seeds.first { $0.timeReminder != nil })
    }

    func testAnUnreadableLibraryRefusesEverySave() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        try vault.library!.saveScripts([["id": UUID().uuidString, "at": "2026-06-12", "mode": "a4", "blocks": ["Kept"]]])
        try Data("not a sealed box".utf8).write(to: vault.library!.scripts.directory.appendingPathComponent("\(UUID().uuidString.lowercased()).sealed"))
        let (harness, bridge) = page(with: vault)

        XCTAssertTrue(bridge.libraryUnreadable)
        let result = try harness.run("""
            try { await window.webkit.messageHandlers.catchlight.postMessage({cmd: 'save', kind: 'scripts', list: []}); return 'saved'; }
            catch (e) { return 'refused'; }
            """, in: self) as? String
        XCTAssertEqual(result, "refused")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.library!.scripts.directory.path).count, 2, "nothing was deleted")
    }
}
