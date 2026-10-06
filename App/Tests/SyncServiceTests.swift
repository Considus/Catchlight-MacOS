import XCTest
import CatchlightCore

/// Sync on the Mac through Core's real engine and a real folder on disk: two Macs on one account
/// (the same phrase) sharing one folder, as two devices share a cloud folder. What crosses is
/// Core's own envelope and manifest, the same bytes the iPhone reads.
final class SyncServiceTests: XCTestCase {
    private var root: URL!
    private var suites: [String] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-sync-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Cloud"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        try? FileManager.default.removeItem(at: root)
    }

    /// A Mac with its own library and settings, on the account `words` opens, synced to the shared folder.
    private func mac(_ name: String, words: [String], syncScripts: Bool = false) throws -> SyncService {
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent(name))
        try vault.createAccount(words: words, restored: true)
        let suite = "catchlight.tests.\(UUID())"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(syncScripts, forKey: SyncService.syncScriptsKey)
        let folder = SyncFolder(defaults: defaults)
        folder.pick = { [root] _, done in done(root!.appendingPathComponent("Cloud")) }
        folder.choose(in: nil) { _ in }
        return SyncService(vault: vault, folder: folder, defaults: defaults)
    }

    private func sync(_ service: SyncService) throws -> SyncReport {
        let done = expectation(description: "sync")
        var result: SyncService.Outcome = .skipped
        service.run { result = $0; done.fulfill() }
        wait(for: [done], timeout: 60)
        switch result {
        case .finished(let report): return report
        case .failed(let error): throw error
        case .skipped: throw XCTSkip("sync was skipped")
        }
    }

    private func write(_ text: String, id: UUID = UUID(), on service: SyncService) throws -> UUID {
        _ = try service.vault.library!.saveTakes(try service.vault.library!.pageTakes() + [
            ["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true, "blocks": [["k": "text", "text": text]]]])
        return id
    }

    private func writeScript(_ text: String, id: UUID = UUID(), on service: SyncService) throws -> UUID {
        _ = try service.vault.library!.saveScripts(try service.vault.library!.pageScripts() + [
            ["id": id.uuidString, "at": "2026-07-01T09:00:00.000Z", "mode": "a4", "blocks": [text, "- [ ] Frame size"]]])
        return id
    }

    /// M3b, with the switch off (Script_Sync_Proposal, decision A): a Script in the library never
    /// reaches the folder, so a phone from before 2026-10-01 can never see one. Takes still sync.
    func testScriptsStayOnThisMacUntilTheSwitchIsOn() throws {
        let words = try Vault.newPhrase()
        let a = try mac("A", words: words), b = try mac("B", words: words)
        let script = try writeScript("# Winter series", on: a)
        let take = try write("A Take", on: a)

        XCTAssertEqual(try sync(a).uploaded, [take])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Cloud").path)
        XCTAssertFalse(files.contains { $0.lowercased().hasPrefix(script.uuidString.lowercased()) }, "no Script in the folder: \(files)")
        _ = try sync(a)   // and not by a later pass either (the engine's self-heal step)
        XCTAssertEqual(try sync(b).applied, [take])
        XCTAssertEqual(try b.vault.library!.pageScripts().count, 0)
        XCTAssertEqual(try a.vault.library!.pageScripts().count, 1, "the Script stays on Mac A")
    }

    func testWithTheSwitchOnAScriptCrossesToTheOtherMac() throws {
        let words = try Vault.newPhrase()
        let a = try mac("A", words: words, syncScripts: true), b = try mac("B", words: words, syncScripts: true)
        let id = try writeScript("# Winter series", on: a)
        XCTAssertEqual(try sync(a).uploaded, [id])
        XCTAssertEqual(try sync(b).applied, [id])
        let onB = try b.vault.library!.pageScripts()
        XCTAssertEqual(onB.map { $0["blocks"] as? [String] }, [["# Winter series", "- [ ] Frame size"]])
        XCTAssertEqual(onB.first?["mode"] as? String, "a4")
        XCTAssertEqual(try b.vault.library!.pageTakes().count, 0, "and it is a Script there, not a Take")
    }

    /// The real page: Sync Now brings in a Script another Mac wrote, and the Scripts list shows it.
    func testSyncNowOnThePageShowsAScriptFromAnotherMac() throws {
        let words = try Vault.newPhrase()
        let a = try mac("A", words: words, syncScripts: true), b = try mac("B", words: words, syncScripts: true)
        _ = try writeScript("# From Mac A", on: a)
        _ = try sync(a)

        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.vault = b.vault
        bridge.syncFolder = b.folder
        bridge.sync = b
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)

        let shown = try harness.run("""
            localStorage.setItem('cl.account', JSON.stringify({ ...(JSON.parse(localStorage.getItem('cl.account')) || {}), folder: '~/Cloud' }));
            settings.syncMode = 'manual';
            const r = await catchlightBridge.sync('manual');
            for (let i = 0; i < 100 && !scripts.length; i++) await new Promise(r => setTimeout(r, 50));
            return JSON.stringify([r.applied, scripts.map(s => s.blocks[0]), document.querySelector('#scripts [data-script] .body')?.textContent ?? null]);
            """, in: self) as? String
        XCTAssertEqual(shown, ##"[1,["# From Mac A"],"From Mac A\nFrame size"]"##)
    }

    /// Greptile on #55: the page learns whether Scripts sync even when no library is open yet
    /// (first run), because it keeps that object once the account is made.
    func testThePageKnowsScriptsSyncBeforeTheAccountExists() throws {
        let suite = "catchlight.tests.\(UUID())"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: SyncService.syncScriptsKey)
        let bridge = ShellBridge()
        bridge.vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("New"))
        bridge.sync = SyncService(vault: bridge.vault!, folder: SyncFolder(defaults: defaults), defaults: defaults)
        XCTAssertTrue(bridge.injectedLibrary().source.contains(#""syncScripts":true"#))
    }

    func testATakeWrittenOnOneMacArrivesOnTheOther() throws {
        let words = try Vault.newPhrase()
        let a = try mac("A", words: words), b = try mac("B", words: words)
        let id = try write("Written on Mac A", on: a)

        XCTAssertEqual(try sync(a).uploaded, [id])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Cloud").path)
        XCTAssertTrue(files.contains("\(id.uuidString).clk") || files.contains("\(id.uuidString.lowercased()).clk"), "the encrypted Take is in the folder: \(files)")
        XCTAssertTrue(files.contains("Import"), "the Import folder is made, as on the iPhone")

        XCTAssertEqual(try sync(b).applied, [id])
        XCTAssertEqual(try b.vault.library!.store.take(id: id)?.plainText, "Written on Mac A")
    }

    func testNothingInTheFolderIsReadable() throws {
        let a = try mac("A", words: try Vault.newPhrase())
        _ = try write("A secret line", on: a)
        _ = try sync(a)
        let cloud = root.appendingPathComponent("Cloud")
        for name in try FileManager.default.contentsOfDirectory(atPath: cloud.path) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cloud.appendingPathComponent(name).path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let data = try Data(contentsOf: cloud.appendingPathComponent(name))
            XCTAssertNil(data.range(of: Data("A secret line".utf8)), "\(name) holds the Take's text in the clear")
        }
    }

    func testAConflictIsQueuedAndKeepBothReachesBothMacs() throws {
        let words = try Vault.newPhrase()
        let a = try mac("A", words: words), b = try mac("B", words: words)
        let id = try write("Original", on: a)
        _ = try sync(a); _ = try sync(b)

        // Both Macs change the same Take before either syncs again.
        func edit(_ s: SyncService, _ text: String) throws {
            var take = try s.vault.library!.store.take(id: id)!
            take.blocks = [.text(TextBlock(text: text))]
            take.modifiedAt = Date()
            try s.vault.library!.store.upsert(take)
        }
        try edit(a, "Edited on A")
        try edit(b, "Edited on B")
        _ = try sync(a)
        let report = try sync(b)

        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertEqual(b.conflicts.pending.count, 1)
        XCTAssertEqual(try b.vault.library!.store.take(id: id)?.plainText, "Edited on B", "B's version stands until the choice")

        let copy = try XCTUnwrap(try b.conflicts.resolve(id: id, choice: .both, store: b.vault.library!.store))
        XCTAssertEqual(b.conflicts.count, 0)
        _ = try sync(b); _ = try sync(a)
        for mac in [a, b] {
            let texts = Set(try mac.vault.library!.store.allTakes().map(\.plainText))
            XCTAssertEqual(texts, ["Edited on B", "Edited on A"])
            XCTAssertEqual(try mac.vault.library!.store.take(id: copy.id)?.plainText, "Edited on A")
        }
        XCTAssertTrue(try sync(b).conflicts.isEmpty, "a resolved conflict does not come back")
    }

    func testKeepThisMacsOrTheOtherVersion() throws {
        let store = try Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Q")).with { try $0.createAccount(words: try Vault.newPhrase(), restored: true) }.library!.store
        let queue = ConflictQueue()
        var local = Take(blocks: [.text(TextBlock(text: "Mac"))])
        try store.upsert(local)
        local = try store.take(id: local.id)!
        var remote = local
        remote.blocks = [.text(TextBlock(text: "iPhone"))]

        queue.enqueue([(local: local, remote: remote)])
        try queue.resolve(id: local.id, choice: .local, store: store, now: Date(timeIntervalSinceNow: 5))
        XCTAssertEqual(try store.take(id: local.id)?.plainText, "Mac")
        XCTAssertGreaterThan(try store.take(id: local.id)!.modifiedAt, local.modifiedAt, "stamped as a fresh edit so it wins the next push")

        queue.enqueue([(local: local, remote: remote)])
        try queue.resolve(id: local.id, choice: .remote, store: store, now: Date(timeIntervalSinceNow: 10))
        XCTAssertEqual(try store.take(id: local.id)?.plainText, "iPhone")
        XCTAssertEqual(try store.allTakes().count, 1)
    }

    /// The real page: Sync Now through the bridge brings in a Take another Mac wrote, and the page
    /// shows it.
    func testSyncNowOnThePageShowsATakeFromAnotherMac() throws {
        let words = try Vault.newPhrase()
        let a = try mac("A", words: words), b = try mac("B", words: words)
        _ = try write("From Mac A", on: a)
        _ = try sync(a)

        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.vault = b.vault
        bridge.syncFolder = b.folder
        bridge.sync = b
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)

        let shown = try harness.run("""
            localStorage.setItem('cl.account', JSON.stringify({ ...(JSON.parse(localStorage.getItem('cl.account')) || {}), folder: '~/Cloud' }));
            settings.syncMode = 'manual';
            const r = await catchlightBridge.sync('manual');
            for (let i = 0; i < 100 && !takes.some(t => t.blocks[0]?.text === 'From Mac A'); i++) await new Promise(r => setTimeout(r, 50));
            return JSON.stringify([r.applied, takes.map(t => t.blocks[0]?.text)]);
            """, in: self) as? String
        XCTAssertEqual(shown, #"[1,["From Mac A"]]"#)
    }

    /// #code-review: a save arriving during a pass must not interleave with it (a pass writing the
    /// store between the save's read and write would slip past the conflict check). It runs once
    /// the pass ends, in order.
    func testWorkArrivingDuringAPassRunsAfterIt() throws {
        let a = try mac("A", words: try Vault.newPhrase())
        _ = try write("Something to sync", on: a)
        var order: [String] = []
        let done = expectation(description: "both")
        done.expectedFulfillmentCount = 2
        a.run { _ in order.append("sync"); done.fulfill() }
        XCTAssertTrue(a.isSyncing)
        a.whenIdle { order.append("save"); done.fulfill() }
        XCTAssertEqual(order, [], "nothing runs while the pass is going")
        wait(for: [done], timeout: 60)
        XCTAssertEqual(order, ["sync", "save"])
        var ran = false
        a.whenIdle { ran = true }
        XCTAssertTrue(ran, "with no pass running, work runs at once")
    }

    /// #52 review (Greptile): a waiting conflict may hold the only copy of the other device's
    /// version, so it is kept on disk, sealed, and survives a relaunch; resolving it removes it.
    func testAWaitingConflictSurvivesARelaunch() throws {
        let words = try Vault.newPhrase()
        let a = try mac("A", words: words), b = try mac("B", words: words)
        let id = try write("Original", on: a)
        _ = try sync(a); _ = try sync(b)
        for (s, text) in [(a, "Edited on A"), (b, "Edited on B")] {
            var take = try s.vault.library!.store.take(id: id)!
            take.blocks = [.text(TextBlock(text: text))]
            take.modifiedAt = Date()
            try s.vault.library!.store.upsert(take)
        }
        _ = try sync(a); _ = try sync(b)
        XCTAssertEqual(b.conflicts.pending.count, 1)

        let folder = b.vault.directory.appendingPathComponent("Conflicts")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1)
        let sealed = try Data(contentsOf: folder.appendingPathComponent(files[0]))
        XCTAssertNil(sealed.range(of: Data("Edited on A".utf8)), "kept sealed, never in the clear")

        // A relaunch: a new SyncService over the same library reads the waiting pair back.
        let relaunched = SyncService(vault: b.vault, folder: b.folder)
        XCTAssertEqual(relaunched.conflicts.pending.first?.remote.plainText, "Edited on A")
        try relaunched.conflicts.resolve(id: id, choice: .remote, store: b.vault.library!.store)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        XCTAssertEqual(SyncService(vault: b.vault, folder: b.folder).conflicts.count, 0)
    }

    /// #52 review (Greptile): a pass asked for while one runs (a save written once it ended) gets
    /// one more pass afterwards, so the save reaches the cloud without waiting for the next trigger.
    func testASyncAskedForDuringAPassRunsOnceMoreAfterIt() throws {
        let a = try mac("A", words: try Vault.newPhrase())
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.vault = a.vault
        bridge.syncFolder = a.folder
        bridge.sync = a
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)

        let passes = try harness.run("""
            localStorage.setItem('cl.account', JSON.stringify({ ...(JSON.parse(localStorage.getItem('cl.account')) || {}), folder: '~/Cloud' }));
            settings.syncMode = 'manual';
            const h = window.webkit.messageHandlers.catchlight, post = h.postMessage.bind(h);
            let n = 0;
            h.postMessage = m => m.cmd === 'sync' ? post(m).then(r => { n++; return r; }) : post(m);   // passes that have answered
            const first = catchlightBridge.sync('manual');
            const second = catchlightBridge.sync('manual');   // Sync Now during a pass
            await first;
            await second;   // resolves only once the follow-up pass has answered
            const atSecond = n;
            await new Promise(r => setTimeout(r, 300));
            return atSecond * 10 + n;
            """, in: self) as? Int
        XCTAssertEqual(passes, 22, "one pass, then exactly one more, and the second request waits for it")
    }

    /// #53 review (Claude): Local means this Mac's version as it is NOW. An edit made after the
    /// conflict was queued must not be replaced by the older queued copy.
    func testKeepLocalKeepsAnEditMadeAfterTheConflict() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("E"))
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let store = vault.library!.store
        var local = Take(blocks: [.text(TextBlock(text: "Mac, first"))])
        try store.upsert(local)
        local = try store.take(id: local.id)!
        var remote = local
        remote.blocks = [.text(TextBlock(text: "iPhone"))]
        let queue = ConflictQueue()
        queue.enqueue([(local: local, remote: remote)])

        var later = local
        later.blocks = [.text(TextBlock(text: "Mac, edited again"))]
        later.modifiedAt = Date(timeIntervalSinceNow: 2)
        try store.upsert(later)

        try queue.resolve(id: local.id, choice: .local, store: store, now: Date(timeIntervalSinceNow: 5))
        XCTAssertEqual(try store.take(id: local.id)?.plainText, "Mac, edited again")

        queue.enqueue([(local: local, remote: remote)])
        let copy = try XCTUnwrap(try queue.resolve(id: local.id, choice: .both, store: store, now: Date(timeIntervalSinceNow: 10)))
        XCTAssertEqual(try store.take(id: local.id)?.plainText, "Mac, edited again", "Keep both keeps the current one too")
        XCTAssertEqual(try store.take(id: copy.id)?.plainText, "iPhone")
    }

    func testNoFolderMeansNoSync() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("L"))
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let suite = "catchlight.tests.\(UUID())"; suites.append(suite)
        let service = SyncService(vault: vault, folder: SyncFolder(defaults: UserDefaults(suiteName: suite)!))
        XCTAssertNil(service.makeEngine())
        let done = expectation(description: "answered")
        service.run { if case .skipped = $0 { done.fulfill() } }
        wait(for: [done], timeout: 5)
    }
}

private extension Vault {
    func with(_ body: (Vault) throws -> Void) rethrows -> Vault { try body(self); return self }
}
