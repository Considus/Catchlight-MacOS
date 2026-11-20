import AppKit
import CatchlightAppleStorage
import CatchlightCore
import CryptoKit
import Security
import WebKit
import XCTest

/// The review's fixes to the lock: a relock leaves no keys or decrypted conflicts in the sync, the
/// shell refuses account commands while locked, the page stops taking input once the relock's
/// save is done, and the Mac's screen unlocking asks for the user as the iPhone does on return.
final class LockHardeningTests: XCTestCase {
    /// Secrets in memory that count how often the phrase is read and can refuse the key.
    private final class CountingSecrets: Secrets, @unchecked Sendable {
        private let memory = MemorySecrets()
        private let guarded = NSLock()
        private var refusing = false, phraseReads = 0, keyAsks = 0
        var refuse: Bool {
            get { guarded.withLock { refusing } }
            set { guarded.withLock { refusing = newValue } }
        }
        var phrasesRead: Int { guarded.withLock { phraseReads } }
        var asked: Int { guarded.withLock { keyAsks } }
        var hasAccount: Bool { memory.hasAccount }
        func storePhrase(_ words: [String]) throws { try memory.storePhrase(words) }
        func storeMasterKey(_ raw: Data) throws { try memory.storeMasterKey(raw) }
        func masterKey(reason: String) throws -> SymmetricKey {
            guarded.withLock { keyAsks += 1 }
            if refuse { throw KeychainError.retrieveFailed(errSecUserCanceled) }
            return try memory.masterKey(reason: reason)
        }
        func phrase(reason: String) -> [String]? {
            guarded.withLock { phraseReads += 1 }
            return memory.phrase(reason: reason)
        }
        func deleteMasterKey() { memory.deleteMasterKey() }
        func deleteAll() { memory.deleteAll() }
    }

    private var defaults: UserDefaults!
    private var suite: String!
    private var dir: URL!
    private var secrets: CountingSecrets!
    private var vault: Vault!
    private var controllers: [MainWindowController] = []
    private let takeID = UUID()

    override func setUpWithError() throws {
        suite = "catchlight-lock-hardening-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-lock-hard-\(UUID())/Catchlight")
        secrets = CountingSecrets()
        vault = Vault(secrets: secrets, directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        _ = try vault.library!.saveTakes([["id": takeID.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true,
                                           "blocks": [["k": "text", "text": "Private words"]]]])
    }

    override func tearDown() {
        controllers.forEach { $0.window?.close() }
        controllers = []
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func controller() -> MainWindowController {
        let mirror = LibraryMirror(reminders: MacReminders(centre: FakeCentre()), spotlight: RecordingSpotlightIndexer(), defaults: defaults)
        let lock = AppLock(defaults: defaults)
        let made = MainWindowController(vault: vault, notifications: FakeCentre(), mirror: mirror, defaults: defaults,
                                        uiRoot: WebViewHarness.repoUI, lock: lock)
        made.webView.configuration.userContentController.addUserScript(WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controllers.append(made)
        let deadline = Date().addingTimeInterval(30)
        func loaded() -> Bool { !made.webView.isLoading && made.webView.url?.absoluteString == MainWindowController.startURL.absoluteString }
        while !loaded() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(loaded(), "the page did not load")
        return made
    }

    private func runInPage(_ controller: MainWindowController, _ body: String) -> Any? {
        var outcome: Result<Any, Error>?
        controller.webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { outcome = $0 }
        let deadline = Date().addingTimeInterval(20)
        while outcome == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return try? outcome?.get()
    }

    private func spin(until condition: () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func relock(_ controller: MainWindowController) {
        var done = false
        controller.relock { done = true }
        spin(until: { done }, "relock did not finish")
    }

    private var isLocked: Bool { if case .locked = vault.state { return true } else { return false } }

    // MARK: 1. The sync forgets the closed library

    func testARelockLeavesNoKeysOrConflictsInTheSync() throws {
        secrets.refuse = true
        let live = controller()
        let sync = try XCTUnwrap(live.bridge.sync)
        let local = Take(blocks: [.text(TextBlock(text: "Mine"))])
        var remote = local
        remote.blocks = [.text(TextBlock(text: "Theirs"))]
        sync.conflicts.enqueue([(local: local, remote: remote)])
        XCTAssertTrue(sync.cachedQueue.holdsKeys, "the queue holds no keys before the relock, or the test proves nothing")
        XCTAssertEqual(sync.cachedQueue.pending.count, 1)

        relock(live)

        XCTAssertTrue(isLocked)
        XCTAssertFalse(sync.cachedQueue.holdsKeys, "the sync still holds the closed library's keys")
        XCTAssertTrue(sync.cachedQueue.pending.isEmpty, "the sync still holds decrypted conflicts")
    }

    // MARK: 2. Account commands while locked

    private func lockedBridge() throws -> ShellBridge {
        vault.lock()
        let bridge = ShellBridge()
        bridge.vault = vault
        return bridge
    }

    private func page(with bridge: ShellBridge) -> WebViewHarness {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)
        return harness
    }

    private func send(_ command: String, to harness: WebViewHarness) throws -> Any? {
        try harness.run("""
            try { return await window.webkit.messageHandlers.catchlight.postMessage(\(command)); }
            catch (e) { return 'error:' + (e.message || e); }
            """, in: self)
    }

    /// Every file under the library folder with its size and bytes' digest.
    private func folderContents() -> [String: String] {
        var seen: [String: String] = [:]
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return seen }
        for case let url as URL in files {
            let data = (try? Data(contentsOf: url)) ?? Data()
            seen[url.path] = "\(data.count):\(SHA256.hash(data: data).description)"
        }
        return seen
    }

    func testAccountCommandsAreRefusedWhileLocked() throws {
        let bridge = try lockedBridge()
        let harness = page(with: bridge)
        let before = folderContents()
        XCTAssertFalse(before.isEmpty)
        let words = try Vault.newPhrase()
        let wordsJSON = String(data: try JSONSerialization.data(withJSONObject: words), encoding: .utf8)!
        let commands = [
            "{cmd: 'createAccount', words: \(wordsJSON), restored: true}",
            "{cmd: 'replaceAccount', words: \(wordsJSON)}",
            "{cmd: 'eraseEverything'}",
            "{cmd: 'revealPhrase'}",
        ]
        for command in commands {
            XCTAssertEqual(try send(command, to: harness) as? String, "error:locked", "\(command) was not refused")
        }
        XCTAssertEqual(folderContents(), before, "a refused command changed the library folder")
        XCTAssertEqual(secrets.phrasesRead, 0, "a refused command read the phrase")
        XCTAssertTrue(isLocked)
        XCTAssertTrue(secrets.hasAccount, "a refused command removed the account")
    }

    // MARK: 3. Typing during a relock

    func testThePageStopsTakingInputOnceTheRelockHasSaved() throws {
        secrets.refuse = true
        let live = controller()
        XCTAssertEqual(runInPage(live, "return document.getElementById('app').inert;") as? Bool, false)
        var sawInert: Bool?
        live.beforeRelockClose = { [unowned self] in
            // Between the save and the reload: the page is still the open one.
            sawInert = self.runInPage(live, "return document.getElementById('app').inert;") as? Bool
        }

        relock(live)

        XCTAssertEqual(sawInert, true, "the page still took input after the relock's save")
    }

    // MARK: 4. The Mac's screen unlocking

    func testTheScreenUnlockingAsksForTheUserWhenLockedAndActive() throws {
        let live = controller()
        secrets.refuse = true
        relock(live)
        live.isAppActive = { true }
        let askedBefore = secrets.asked

        // What the observer of com.apple.screenIsUnlocked calls. Posting the real distributed
        // notification would reach every app on this Mac.
        live.screenDidUnlock(Notification(name: MainWindowController.screenUnlockedNotification))

        spin(until: { live.bridge.lockFailure == "cancelled" }, "the unlock was not asked for")
        XCTAssertEqual(secrets.asked, askedBefore + 1)
    }

    func testTheScreenUnlockingAsksNothingOfAnAppInTheBackground() throws {
        let live = controller()
        secrets.refuse = true
        relock(live)
        live.isAppActive = { false }
        let askedBefore = secrets.asked

        live.screenDidUnlock(Notification(name: MainWindowController.screenUnlockedNotification))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(secrets.asked, askedBefore, "a background app asked for the user")
        XCTAssertNil(live.bridge.lockFailure)
    }

    func testTheScreenUnlockingLeavesAShowingFailureToTryAgain() throws {
        let live = controller()
        secrets.refuse = true
        relock(live)
        live.bridge.lockFailure = "cancelled"
        live.isAppActive = { true }
        let askedBefore = secrets.asked

        live.screenDidUnlock(Notification(name: MainWindowController.screenUnlockedNotification))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(secrets.asked, askedBefore, "a failure showing was asked again without the button")
    }

    func testTheScreenUnlockingLeavesAnOpenLibraryAlone() throws {
        let live = controller()
        live.isAppActive = { true }
        let askedBefore = secrets.asked

        live.screenDidUnlock(Notification(name: MainWindowController.screenUnlockedNotification))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(secrets.asked, askedBefore)
        XCTAssertNotNil(vault.library)
    }
}
