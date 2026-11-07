import XCTest
import WebKit
import CatchlightCore

/// Cloud copies that failed their check (`UnverifiedCopy`), on the conflict screen as on the
/// iPhone: keep this Mac's, keep (or recover) the cloud copy, or skip for now. Never held.
final class UnverifiedCopyTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-unverified-\(UUID())", isDirectory: true)
        suite = "catchlight.tests.\(UUID())"
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func take(_ text: String, modified: Date) -> Take {
        var t = Take(blocks: [.text(TextBlock(text: text))])
        t.modifiedAt = modified
        return t
    }

    private func memoryStore() throws -> (Vault, TakeStore) {
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Library"))
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        return (vault, vault.library!.store)
    }

    func testKeepingThisMacsSideStampsItAfterTheCloudCopy() throws {
        let (_, store) = try memoryStore()
        let now = Date()
        let local = take("Mine", modified: now.addingTimeInterval(-100))
        var cloud = local
        cloud.blocks = [.text(TextBlock(text: "Cloud"))]
        cloud.modifiedAt = now.addingTimeInterval(500)   // a device whose clock runs ahead
        let queue = ConflictQueue()
        queue.enqueueUnverified([UnverifiedCopy(id: local.id, local: local, cloud: cloud)])

        try queue.keepLocalUnverified(id: local.id, store: store, now: now)

        let kept = try XCTUnwrap(try store.take(id: local.id))
        XCTAssertEqual(kept.plainText, "Mine")
        XCTAssertGreaterThan(kept.modifiedAt, cloud.modifiedAt)
        XCTAssertTrue(queue.unverified.isEmpty)
    }

    func testRecoveringACloudOnlyCopyWritesItIntoAnEmptyStore() throws {
        let (_, store) = try memoryStore()
        let cloud = take("Only in the cloud", modified: Date().addingTimeInterval(-50))
        let queue = ConflictQueue()
        queue.enqueueUnverified([UnverifiedCopy(id: cloud.id, local: nil, cloud: cloud)])

        try queue.keepCloudUnverified(id: cloud.id, store: store)

        XCTAssertEqual(try store.take(id: cloud.id)?.plainText, "Only in the cloud")
        XCTAssertTrue(queue.unverified.isEmpty)
    }

    func testSkippingWritesNothingAndRemovesIt() throws {
        let (_, store) = try memoryStore()
        let cloud = take("Skipped", modified: Date())
        let queue = ConflictQueue()
        queue.enqueueUnverified([UnverifiedCopy(id: cloud.id, local: nil, cloud: cloud)])

        queue.skipUnverified(id: cloud.id)

        XCTAssertTrue(queue.unverified.isEmpty)
        XCTAssertNil(try store.take(id: cloud.id))
    }

    /// A library with one unverified item of each shape, and the page on it.
    private func pageWithThreeShapes(_ harnessOut: inout WebViewHarness?) throws -> (Vault, SyncService, [UUID]) {
        let (vault, store) = try memoryStore()
        let now = Date()
        var both = take("Both: this Mac", modified: now.addingTimeInterval(-300))
        try store.upsert(both)
        both = try XCTUnwrap(try store.take(id: both.id))
        var bothCloud = both
        bothCloud.blocks = [.text(TextBlock(text: "Both: the cloud copy"))]
        var onlyLocal = take("Only this Mac", modified: now.addingTimeInterval(-200))
        try store.upsert(onlyLocal)
        onlyLocal = try XCTUnwrap(try store.take(id: onlyLocal.id))
        let onlyCloud = take("Only the cloud", modified: now.addingTimeInterval(-100))

        let sync = SyncService(vault: vault, folder: SyncFolder(defaults: UserDefaults(suiteName: suite)!), defaults: UserDefaults(suiteName: suite)!)
        sync.conflicts.enqueueUnverified([
            UnverifiedCopy(id: both.id, local: both, cloud: bothCloud),
            UnverifiedCopy(id: onlyLocal.id, local: onlyLocal, cloud: nil),
            UnverifiedCopy(id: onlyCloud.id, local: nil, cloud: onlyCloud)])

        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.vault = vault
        bridge.sync = sync
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)
        objc_setAssociatedObject(harness, "bridge", bridge, .OBJC_ASSOCIATION_RETAIN)
        harnessOut = harness
        return (vault, sync, [both.id, onlyLocal.id, onlyCloud.id])
    }

    func testTheBridgeListsAnUnverifiedItemAndKeepsThisMacsSide() throws {
        var h: WebViewHarness?
        let (vault, sync, ids) = try pageWithThreeShapes(&h)
        let harness = h!

        let listed = try harness.run("""
            const all = await catchlightBridge.conflicts();
            const e = all.find(c => c.id === \(Self.js(ids[0])));
            return JSON.stringify([e.unverified, e.local?.blocks?.[0]?.text, e.cloud?.blocks?.[0]?.text, all.length]);
            """, in: self) as? String
        XCTAssertEqual(listed, #"[true,"Both: this Mac","Both: the cloud copy",3]"#)

        let answer = try harness.run("return await catchlightBridge.resolveUnverified(\(Self.js(ids[0])), 'local');", in: self) as? Bool
        XCTAssertEqual(answer, true)
        XCTAssertEqual(try vault.library!.store.take(id: ids[0])?.plainText, "Both: this Mac")
        XCTAssertEqual(sync.conflicts.unverified.count, 2)
    }

    func testThePageShowsThreeCardsEachWithSkipForNow() throws {
        var h: WebViewHarness?
        let (vault, sync, ids) = try pageWithThreeShapes(&h)
        let harness = h!

        let shape = try harness.run("""
            for (let i = 0; i < 100 && conflictBanner.hidden; i++) await new Promise(r => setTimeout(r, 50));
            openConflicts();
            const cards = [...conflictSheet.querySelectorAll('.cf-item')];
            return JSON.stringify({
              cards: cards.length,
              skips: cards.filter(c => c.querySelector('[data-cf="skip"]')).length,
              guide: conflictSheet.textContent.includes("didn't pass their check. Nothing changes on this Mac until you choose."),
              recover: conflictSheet.textContent.includes('Recover this Take?'),
              held: [...heldIds]
            });
            """, in: self) as? String
        XCTAssertEqual(shape, #"{"cards":3,"skips":3,"guide":true,"recover":true,"held":[]}"#, "three cards, and unverified items are not held")

        // Recover the cloud-only Take: the page reloads its lists and shows it.
        let shown = try harness.run("""
            conflictSheet.querySelector('[data-cf="keep"][data-side="cloud"]').click();
            for (let i = 0; i < 100 && !takes.some(t => t.blocks[0].text === 'Only the cloud'); i++) await new Promise(r => setTimeout(r, 50));
            return takes.some(t => t.blocks[0].text === 'Only the cloud');
            """, in: self) as? Bool
        XCTAssertEqual(shown, true)
        XCTAssertEqual(try vault.library!.store.take(id: ids[2])?.plainText, "Only the cloud")

        // Skip for now writes nothing and drops the item.
        _ = try harness.run("""
            conflictSheet.querySelector('.cf-item [data-cf="skip"]').click();
            for (let i = 0; i < 100 && conflictList.length > 1; i++) await new Promise(r => setTimeout(r, 50));
            return true;
            """, in: self)
        XCTAssertEqual(sync.conflicts.unverified.count, 1)
    }

    private static func js(_ id: UUID) -> String { "'\(id.uuidString.lowercased())'" }
}
