import XCTest
import WebKit
import CatchlightCore

/// The conflict screen in the real `ui/`, over a real queue and an encrypted library: the banner,
/// the two versions, and each choice written to the store (owner, 2026-10-05: keep this Mac's,
/// the other device's, or both).
final class ConflictScreenTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-conflicts-\(UUID())", isDirectory: true)
        suite = "catchlight.tests.\(UUID())"
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    /// A library holding "Mine" with a waiting conflict against "From the iPhone", and the page on it.
    private func setUp(with harnessOut: inout WebViewHarness?) throws -> (Vault, SyncService, UUID) {
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Library"))
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let store = vault.library!.store
        var local = Take(blocks: [.text(TextBlock(text: "Mine, edited on the Mac"))])
        try store.upsert(local)
        local = try store.take(id: local.id)!
        var remote = local
        remote.blocks = [.text(TextBlock(text: "From the iPhone"))]
        let sync = SyncService(vault: vault, folder: SyncFolder(defaults: UserDefaults(suiteName: suite)!), defaults: UserDefaults(suiteName: suite)!)
        sync.conflicts.enqueue([(local: local, remote: remote)])

        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.vault = vault
        bridge.sync = sync
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)
        objc_setAssociatedObject(harness, "bridge", bridge, .OBJC_ASSOCIATION_RETAIN)
        harnessOut = harness
        return (vault, sync, local.id)
    }

    func testTheBannerAndKeepTheOtherVersion() throws {
        var h: WebViewHarness?
        let (vault, sync, id) = try setUp(with: &h)
        let harness = h!

        let banner = try harness.run("""
            for (let i = 0; i < 100 && conflictBanner.hidden; i++) await new Promise(r => setTimeout(r, 50));
            return conflictBanner.hidden ? null : conflictBanner.textContent.trim();
            """, in: self) as? String
        XCTAssertEqual(banner, "1 Take changed on another device.Review")

        let panels = try harness.run("""
            conflictBanner.querySelector('[data-cf="review"]').click();
            return JSON.stringify([...conflictSheet.querySelectorAll('.cf-version')].map(b => [b.querySelector('.cf-label').textContent, b.querySelector('.cf-body').textContent]));
            """, in: self) as? String
        XCTAssertEqual(panels, #"[["Local","Mine, edited on the Mac"],["Cloud","From the iPhone"]]"#)
        try snapshot(harness, name: "conflict-sheet")

        let after = try harness.run("""
            const keep = () => conflictSheet.querySelector('[data-cf="keep"]');
            const disabledBefore = keep().disabled;
            conflictSheet.querySelector('[data-side="remote"]').click();
            keep().click();
            for (let i = 0; i < 100 && !conflictBanner.hidden; i++) await new Promise(r => setTimeout(r, 50));
            return JSON.stringify([disabledBefore, conflictBanner.hidden, takes.map(t => t.blocks[0].text)]);
            """, in: self) as? String
        XCTAssertEqual(after, #"[true,true,["From the iPhone"]]"#, "Keep is off until a version is picked; then the banner goes and the page shows the kept version")
        XCTAssertEqual(try vault.library!.store.take(id: id)?.plainText, "From the iPhone")
        XCTAssertEqual(sync.conflicts.count, 0)
    }

    func testKeepBothLeavesTwoTakes() throws {
        var h: WebViewHarness?
        let (vault, sync, id) = try setUp(with: &h)
        let harness = h!

        let shown = try harness.run("""
            for (let i = 0; i < 100 && conflictBanner.hidden; i++) await new Promise(r => setTimeout(r, 50));
            openConflicts();
            conflictSheet.querySelector('[data-cf="both"]').click();
            for (let i = 0; i < 100 && takes.length < 2; i++) await new Promise(r => setTimeout(r, 50));
            return JSON.stringify(takes.map(t => t.blocks[0].text).sort());
            """, in: self) as? String
        XCTAssertEqual(shown, #"["From the iPhone","Mine, edited on the Mac"]"#)
        XCTAssertEqual(try vault.library!.store.take(id: id)?.plainText, "Mine, edited on the Mac", "this Mac's version keeps its id")
        XCTAssertEqual(try vault.library!.store.allTakes().count, 2)
        XCTAssertEqual(sync.conflicts.count, 0)
    }

    func testSkipForNowLeavesItWaiting() throws {
        var h: WebViewHarness?
        let (vault, sync, id) = try setUp(with: &h)
        let harness = h!

        let state = try harness.run("""
            for (let i = 0; i < 100 && conflictBanner.hidden; i++) await new Promise(r => setTimeout(r, 50));
            openConflicts();
            conflictSheet.querySelector('[data-cf="skip"]').click();
            return JSON.stringify([conflictSheet.textContent.includes('All caught up.'), conflictBanner.hidden]);
            """, in: self) as? String
        XCTAssertEqual(state, "[true,false]", "skipped out of the sheet, still counted in the banner")
        XCTAssertEqual(sync.conflicts.count, 1)
        XCTAssertEqual(try vault.library!.store.take(id: id)?.plainText, "Mine, edited on the Mac")
    }

    /// Owner, 2026-10-07: "The file shouldn't update or edit until the conflict is resolved." The
    /// row says why and opening it asks to resolve the conflict first; a change that reaches it
    /// anyway is put back by the save, and the shell refuses one sent straight to it. Resolving
    /// releases it.
    func testAWaitingTakeIsReadOnlyUntilTheChoice() throws {
        var h: WebViewHarness?
        let (vault, sync, id) = try setUp(with: &h)
        let harness = h!

        let state = try harness.run("""
            for (let i = 0; i < 100 && conflictBanner.hidden; i++) await new Promise(r => setTimeout(r, 50));
            const t = takes[0];
            beginEdit(t);
            const editing = !!draft;
            const notice = alertBox.open ? alertBox.querySelector('h2').textContent : null;
            alertBox.close();
            const note = document.querySelector(`[data-take="${t.id}"] .held-note`)?.textContent ?? null;
            const menu = takeMenu(t.id).map(i => i[0]);
            t.blocks[0].text = 'Changed anyway'; t.modifiedAt = Date.now(); saveTakes(); renderTakes();
            const shown = takes[0].blocks[0].text;
            alertBox.close();
            const r = await window.webkit.messageHandlers.catchlight.postMessage({ cmd: 'save', kind: 'takes', generation: catchlightBridge.library.generation,
              list: [{ ...takes[0], blocks: [{ k: 'text', text: 'Straight to the shell' }], modifiedAt: Date.now() }] });
            return JSON.stringify([editing, notice, note, menu, shown, r.held?.length ?? 0]);
            """, in: self) as? String
        XCTAssertEqual(state, #"[false,"Resolve the conflict first","Changed on another device. Choose a version to edit it.",["Expand Take","Export Take","Review Conflict…"],"Mine, edited on the Mac",1]"#)
        XCTAssertEqual(try vault.library!.store.take(id: id)?.plainText, "Mine, edited on the Mac")
        try snapshot(harness, name: "held-take")

        let released = try harness.run("""
            await resolveConflict(conflictList[0].id, 'local');
            beginEdit(takes[0]);
            const editing = !!draft;
            discardEdit();
            return JSON.stringify([editing, document.querySelector('.card .held-note') === null]);
            """, in: self) as? String
        XCTAssertEqual(released, "[true,true]")
        XCTAssertEqual(sync.conflicts.count, 0)
    }

    /// Code review of the hold: the held copy the page puts back is the STORED version, from the
    /// queue, never the page's own list, which may carry an edit the shell refused or never got.
    func testTheHeldCopyIsTheStoredVersionNotThePagesEdit() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Library"))
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let store = vault.library!.store
        let id = UUID()
        _ = try vault.library!.saveTakes([["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true,
                                           "blocks": [["k": "text", "text": "Stored"]]]])
        let sync = SyncService(vault: vault, folder: SyncFolder(defaults: UserDefaults(suiteName: suite)!), defaults: UserDefaults(suiteName: suite)!)
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.vault = vault
        bridge.sync = sync
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)

        // The page holds an edit the shell never wrote (a save refused, or still on its way)...
        _ = try harness.run("takes[0].blocks[0].text = 'Unsaved edit'; return true;", in: self)
        // ...when a pass finds the conflict.
        let stored = try store.take(id: id)!
        var remote = stored
        remote.blocks = [.text(TextBlock(text: "From the iPhone"))]
        sync.conflicts.enqueue([(local: stored, remote: remote)])

        let shown = try harness.run("""
            await loadConflicts();
            const after = takes[0].blocks[0].text;
            if (alertBox.open) alertBox.close();
            saveTakes();
            await window.webkit.messageHandlers.catchlight.postMessage({ cmd: 'ping' });
            if (alertBox.open) alertBox.close();
            return JSON.stringify([after, takes[0].blocks[0].text]);
            """, in: self) as? String
        XCTAssertEqual(shown, #"["Stored","Stored"]"#)
        XCTAssertEqual(try store.take(id: id)?.plainText, "Stored")
        _ = bridge
    }

    /// Code review of the hold: a choice made against one pair never applies to a newer one that
    /// replaced it meanwhile (a pass running when Keep was pressed). It is refused, the store is
    /// left alone, and the sheet shows the newer pair to choose again.
    func testAChoiceIsRefusedIfThePairChangedMeanwhile() throws {
        var h: WebViewHarness?
        let (vault, sync, id) = try setUp(with: &h)
        let harness = h!
        _ = try harness.run("""
            for (let i = 0; i < 100 && conflictBanner.hidden; i++) await new Promise(r => setTimeout(r, 50));
            openConflicts();
            conflictSheet.querySelector('[data-side="remote"]').click();
            return true;
            """, in: self)
        var pair = sync.conflicts.pending[0]
        pair.remote.blocks = [.text(TextBlock(text: "From the iPhone, edited again"))]
        pair.remote.modifiedAt = Date(timeIntervalSinceNow: 30)
        sync.conflicts.enqueue([pair])

        let state = try harness.run("""
            const until = async (done, ms) => { const end = Date.now() + ms; while (!done() && Date.now() < end) await new Promise(r => setTimeout(r, 50)); };
            conflictSheet.querySelector('[data-cf="keep"]').click();
            await until(() => alertBox.open, 4000);
            const title = alertBox.open ? alertBox.querySelector('h2').textContent : null;
            if (alertBox.open) alertBox.close();
            await until(() => conflictSheet.textContent.includes('edited again'), 4000);
            return JSON.stringify([title, conflictSheet.querySelector('[data-side="remote"] .cf-body')?.textContent ?? null]);
            """, in: self) as? String
        XCTAssertEqual(state, #"["The versions changed","From the iPhone, edited again"]"#)
        XCTAssertEqual(try vault.library!.store.take(id: id)?.plainText, "Mine, edited on the Mac", "nothing written")
        XCTAssertEqual(sync.conflicts.count, 1)
    }

    /// Local review: a pick made against one pair must not carry over when a sync replaces it.
    func testAPickIsClearedWhenTheVersionsChange() throws {
        var h: WebViewHarness?
        let (_, sync, _) = try setUp(with: &h)
        let harness = h!
        _ = try harness.run("""
            for (let i = 0; i < 100 && conflictBanner.hidden; i++) await new Promise(r => setTimeout(r, 50));
            openConflicts();
            conflictSheet.querySelector('[data-side="remote"]').click();
            return true;
            """, in: self)
        var pair = sync.conflicts.pending[0]
        pair.remote.blocks = [.text(TextBlock(text: "From the iPhone, edited again"))]
        sync.conflicts.enqueue([pair])
        let state = try harness.run("""
            await loadConflicts();
            return JSON.stringify([conflictSheet.querySelector('[data-side="remote"] .cf-body').textContent,
                                   conflictSheet.querySelector('.cf-version.picked') !== null,
                                   conflictSheet.querySelector('[data-cf="keep"]').disabled]);
            """, in: self) as? String
        XCTAssertEqual(state, #"["From the iPhone, edited again",false,true]"#)
    }

    /// M3b step 2: a Take made a Script here, edited as a Take elsewhere (Catchlight-Core#22 reports
    /// it as a conflict). The screen says Script and shows each side in its own kind; keeping the
    /// other version makes it a Take again.
    func testAScriptPairShowsAsAScriptAndKeepingTheOtherMakesItATake() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Library"))
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let store = vault.library!.store
        let id = UUID()
        let local = try ScriptTranslation.core(from: ["id": id.uuidString, "at": "2026-07-01T09:00:00.000Z", "mode": "a4", "blocks": ["# Winter series", "- [ ] Frame size"]], existing: nil)
        try store.upsert(local)
        let remote = Take(id: id, createdAt: local.createdAt, modifiedAt: Date(), blocks: [.text(TextBlock(text: "Winter series, edited on the iPhone"))])
        let sync = SyncService(vault: vault, folder: SyncFolder(defaults: UserDefaults(suiteName: suite)!), defaults: UserDefaults(suiteName: suite)!)
        sync.conflicts.enqueue([(local: try store.take(id: id)!, remote: remote)])

        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.vault = vault
        bridge.sync = sync
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)

        let shown = try harness.run("""
            for (let i = 0; i < 100 && conflictBanner.hidden; i++) await new Promise(r => setTimeout(r, 50));
            openConflicts();
            return JSON.stringify([conflictBanner.querySelector('span').textContent, conflictSheet.querySelector('.cf-guide').textContent.split(' were')[0],
              ...[...conflictSheet.querySelectorAll('.cf-version')].map(b => [b.querySelector('.cf-label').textContent, b.querySelector('.cf-body').textContent])]);
            """, in: self) as? String
        XCTAssertEqual(shown, ##"["1 Script changed on another device.","These Scripts",["Local · Script","# Winter series\n- [ ] Frame size"],["Cloud · Take","Winter series, edited on the iPhone"]]"##)
        try snapshot(harness, name: "conflict-sheet-script")

        let after = try harness.run("""
            conflictSheet.querySelector('[data-side="remote"]').click();
            conflictSheet.querySelector('[data-cf="keep"]').click();
            for (let i = 0; i < 100 && !takes.length; i++) await new Promise(r => setTimeout(r, 50));
            return JSON.stringify([takes.map(t => t.blocks[0].text), scripts.length]);
            """, in: self) as? String
        XCTAssertEqual(after, #"[["Winter series, edited on the iPhone"],0]"#)
        XCTAssertNil(try store.take(id: id)?.kind)
        XCTAssertEqual(sync.conflicts.count, 0)
    }

    /// Evidence for the PR: the sheet as drawn, saved beside the test results.
    private func snapshot(_ harness: WebViewHarness, name: String) throws {
        let done = expectation(description: "snapshot")
        var image: NSImage?
        harness.webView.takeSnapshot(with: nil) { img, _ in image = img; done.fulfill() }
        wait(for: [done], timeout: 20)
        guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("catchlight-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
