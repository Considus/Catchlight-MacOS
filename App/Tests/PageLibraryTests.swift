import XCTest
import WebKit
import CatchlightCore
import SQLite3

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
        let id = UUID()
        _ = try vault.library!.saveTakes([["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": "Kept"]]]])
        // A Take whose sealed payload no longer opens: the library can't be read.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("Database/catchlight.db").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE takes SET payload = x'00';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let (harness, bridge) = page(with: vault)

        XCTAssertTrue(bridge.libraryUnreadable)
        let result = try harness.run("""
            try { await window.webkit.messageHandlers.catchlight.postMessage({cmd: 'save', kind: 'takes', list: []}); return 'saved'; }
            catch (e) { return 'refused'; }
            """, in: self) as? String
        XCTAssertEqual(result, "refused")
        XCTAssertEqual(try vault.library!.store.tombstones().count, 0, "nothing was deleted")
    }

    /// Greptile on #43: a restore saved the page's empty list over the library it had reopened.
    func testARestoreShowsTheReopenedLibraryAndSavesNothingOverIt() throws {
        let words = try Vault.newPhrase()
        let earlier = Vault(secrets: MemorySecrets(), directory: dir)
        try earlier.createAccount(words: words, restored: false)
        let id = UUID()
        _ = try earlier.library!.saveTakes([["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": "Still here"]]]])

        // The Keychain is gone, the library is not: first run, restore with the same phrase.
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.start()
        let (harness, bridge) = page(with: vault)
        _ = bridge
        let shown = try harness.run("""
            fr.restore = true; fr.restoreWords = \(String(data: try JSONSerialization.data(withJSONObject: words), encoding: .utf8)!);
            fr.storage = 'local';
            await finish();
            \(settle)
            return JSON.stringify(takes.map(t => t.blocks[0].text));
            """, in: self) as? String
        XCTAssertEqual(shown, #"["Still here"]"#)
        XCTAssertNotNil(try vault.library!.store.take(id: id))
        XCTAssertEqual(try vault.library!.store.tombstones().count, 0)
    }

    /// Owner, 2026-10-04: quitting with the editor open lost the Take. The shell's flush saves
    /// what is on screen, Take and Script alike.
    func testFlushSavesATakeStillOpenInTheEditor() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let (harness, bridge) = page(with: vault)
        _ = bridge
        let flushed = try harness.run("""
            newTake();
            rows.querySelector('.etext').textContent = 'Typed, never closed';
            return await window.catchlightBridge.flush();
            """, in: self) as? Bool
        XCTAssertEqual(flushed, true)
        let stored = try vault.library!.store.allTakes()
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue("\(stored[0].blocks)".contains("Typed, never closed"))
    }

    /// #43 review: a reload after a WebContent crash ran the launch snapshot, and the next save
    /// deleted every Take written since. The reload now rebuilds the snapshot first.
    func testAReloadShowsTheLibraryAsItIsNowNotAsItWasAtLaunch() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let (harness, bridge) = page(with: vault)
        _ = try harness.run("""
            newTake(); rows.querySelector('.etext').textContent = 'Written after launch';
            return await window.catchlightBridge.flush();
            """, in: self)
        XCTAssertEqual(try vault.library!.store.allTakes().count, 1)

        bridge.refreshUserScripts(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)
        let shown = try harness.run("return JSON.stringify(takes.map(t => t.blocks[0].text));", in: self) as? String
        XCTAssertEqual(shown, #"["Written after launch"]"#)
    }

    /// #43 review: a Take the shell couldn't read was reported to the page as saved.
    func testARejectedTakeIsShownToTheUser() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let (harness, bridge) = page(with: vault)
        _ = bridge
        let title = try harness.run("""
            await window.catchlightBridge.save('takes', [{ id: crypto.randomUUID(), at: 'not a date', isNote: true, blocks: [] }]);
            \(settle)
            return document.querySelector('#alert, dialog[open]')?.querySelector('h2')?.textContent ?? null;
            """, in: self) as? String
        XCTAssertEqual(title, "A Take wasn't saved")
    }

    /// #44 review (Greptile): once the library is locked, a refused save must not look saved.
    func testARefusedSaveIsShownAtOnce() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let (harness, bridge) = page(with: vault)
        _ = bridge
        try vault.eraseEverything()   // the shell's library is gone; the page still holds its lists
        let title = try harness.run("""
            takes.push({ id: crypto.randomUUID(), at: new Date().toISOString(), isNote: true, blocks: [{ k: 'text', text: 'After the lock' }] });
            saveTakes();
            \(settle)
            await new Promise(r => setTimeout(r, 50));
            return document.querySelector('dialog[open] h2')?.textContent ?? null;
            """, in: self) as? String
        XCTAssertEqual(title, "That change wasn't saved")
    }

    /// #44 review (Greptile): a save warning must wait for an open dialog, not replace it.
    func testASaveWarningWaitsForAnOpenDialog() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let (harness, bridge) = page(with: vault)
        _ = bridge
        try vault.eraseEverything()
        let titles = try harness.run("""
            ask('Delete this Take?', 'This cannot be undone.', [['Delete', null, 'danger'], ['Cancel', null, 'cancel']]);
            takes.push({ id: crypto.randomUUID(), at: new Date().toISOString(), isNote: true, blocks: [{ k: 'text', text: 'x' }] });
            saveTakes();
            \(settle)
            await new Promise(r => setTimeout(r, 50));
            const first = document.querySelector('dialog[open] h2')?.textContent;
            document.querySelector('dialog[open]').close();
            await new Promise(r => setTimeout(r, 50));
            return JSON.stringify([first, document.querySelector('dialog[open] h2')?.textContent ?? null]);
            """, in: self) as? String
        XCTAssertEqual(titles, #"["Delete this Take?","That change wasn't saved"]"#)
    }
    // MARK: M3: sync writes the store while the page holds its list

    private func syncAdds(_ text: String, to vault: Vault) throws -> UUID {
        let take = Take(blocks: [.text(TextBlock(text: text))], isNote: true)
        try vault.library!.store.upsert(take)
        return take.id
    }

    func testAPageSaveKeepsATakeSyncAddedAndARefreshShowsIt() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let id = UUID()
        _ = try vault.library!.saveTakes([["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true,
                                           "blocks": [["k": "text", "text": "Mine"]]]])
        let (harness, bridge) = page(with: vault)
        _ = bridge
        let fromPhone = try syncAdds("From the iPhone", to: vault)

        _ = try harness.run("""
            takes[0].blocks[0].text = 'Mine, edited'; takes[0].modifiedAt = Date.now(); saveTakes();
            \(settle) return true;
            """, in: self)
        XCTAssertNotNil(try vault.library!.store.take(id: fromPhone), "the page's save must not delete a Take it never saw")
        XCTAssertEqual(try vault.library!.store.take(id: id)?.plainText, "Mine, edited")

        let shown = try harness.run("""
            await catchlightBridge.refresh();
            return JSON.stringify(takes.map(t => t.blocks[0].text).sort());
            """, in: self) as? String
        XCTAssertEqual(shown, #"["From the iPhone","Mine, edited"]"#)
    }

    func testARefreshWaitsForTheTakeBeingEdited() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        _ = try vault.library!.saveTakes([["id": UUID().uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true,
                                           "blocks": [["k": "text", "text": "Mine"]]]])
        let (harness, bridge) = page(with: vault)
        _ = bridge
        _ = try syncAdds("From the iPhone", to: vault)

        let during = try harness.run("""
            beginEdit(takes[0]);
            const applied = await catchlightBridge.refresh();
            return JSON.stringify([applied, takes.length]);
            """, in: self) as? String
        XCTAssertEqual(during, "[false,1]", "nothing replaces the list while a Take is open")

        let after = try harness.run("""
            commitEdit();
            \(settle)
            await new Promise(r => setTimeout(r, 50));
            return takes.length;
            """, in: self) as? Int
        XCTAssertEqual(after, 2, "the refresh that waited goes once the edit ends")
    }
}
