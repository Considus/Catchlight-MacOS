import AppKit
import CatchlightAppleStorage
import CatchlightCore
import CryptoKit
import Security
import WebKit
import XCTest

/// Locking crossfades from the notes to the lock screen (RootView: easeInOut 0.4, opacity), the
/// notes staying readable only for the length of the fade and gone from the page and its memory
/// once the library has closed.
final class LockFadeTests: XCTestCase {
    private final class RefusingSecrets: Secrets, @unchecked Sendable {
        private let memory = MemorySecrets()
        private let guarded = NSLock()
        private var refusing = true
        var refuse: Bool {
            get { guarded.withLock { refusing } }
            set { guarded.withLock { refusing = newValue } }
        }
        var hasAccount: Bool { memory.hasAccount }
        func storePhrase(_ words: [String]) throws { try memory.storePhrase(words) }
        func storeMasterKey(_ raw: Data) throws { try memory.storeMasterKey(raw) }
        func masterKey(reason: String) throws -> SymmetricKey {
            if refuse { throw KeychainError.retrieveFailed(errSecUserCanceled) }
            return try memory.masterKey(reason: reason)
        }
        func phrase(reason: String) -> [String]? { memory.phrase(reason: reason) }
        func deleteMasterKey() { memory.deleteMasterKey() }
        func deleteAll() { memory.deleteAll() }
    }

    private var defaults: UserDefaults!
    private var suite: String!
    private var dir: URL!
    private var vault: Vault!
    private var controllers: [MainWindowController] = []
    private let words = "Words only the notes hold"

    override func setUpWithError() throws {
        suite = "catchlight-lock-fade-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-lock-fade-\(UUID())/Catchlight")
        vault = Vault(secrets: RefusingSecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        _ = try vault.library!.saveTakes([["id": UUID().uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true,
                                           "blocks": [["k": "text", "text": words]]]])
    }

    override func tearDown() {
        controllers.forEach { $0.window?.close() }
        controllers = []
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func controller() -> MainWindowController {
        let mirror = LibraryMirror(reminders: MacReminders(centre: FakeCentre()), spotlight: RecordingSpotlightIndexer(), defaults: defaults)
        let made = MainWindowController(vault: vault, notifications: FakeCentre(), mirror: mirror, defaults: defaults,
                                        uiRoot: WebViewHarness.repoUI, lock: AppLock(defaults: defaults))
        made.webView.configuration.userContentController.addUserScript(WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controllers.append(made)
        made.window?.orderFront(nil)   // a page that is not on screen runs no animations
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

    private var isLocked: Bool { if case .locked = vault.state { return true } else { return false } }

    private func relock(_ controller: MainWindowController) {
        var done = false
        controller.relock { done = true }
        spin(until: { done }, "relock did not finish")
    }

    /// The page isn't painted on screen here, so no animation runs on its own (as the other look
    /// tests do): the fade is ended by hand 150 ms after it starts, and the shell must wait for that.
    private func endTheFadeAfter150ms(_ live: MainWindowController) {
        _ = runInPage(live, """
            const start = window.catchlightLockFade;
            window.catchlightLockFade = () => {
              const done = start();
              setTimeout(() => document.getAnimations().forEach(a => a.finish()), 150);
              return done;
            };
            return true;
            """)
    }

    /// The lock layer's animation in the page, as the page reports it.
    private let lockAnimation = """
        const a = document.getAnimations().find(a => a.effect?.target?.id === 'lock');
        if (!a) return null;
        const t = a.effect.getTiming();
        return JSON.stringify({ duration: t.duration, easing: t.easing, state: a.playState });
        """

    func testTheLockFadesInOverTheNotesAndTheLibraryClosesAfterIt() throws {
        let live = controller()
        endTheFadeAfter150ms(live)
        var seen: String?, notes: Bool?, open: Bool?, openMidFade: Bool?
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [unowned self] in openMidFade = self.vault.library != nil }
        live.beforeRelockClose = { [unowned self] in
            seen = self.runInPage(live, self.lockAnimation) as? String
            notes = self.runInPage(live, "return document.body.innerText.includes('\(self.words)');") as? Bool
            open = self.vault.library != nil
        }

        relock(live)

        let shown = try XCTUnwrap(seen.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }, "no lock layer was animated before the library closed")
        XCTAssertEqual(shown["duration"] as? Int, 400)
        XCTAssertEqual(shown["easing"] as? String, "ease-in-out")
        XCTAssertEqual(shown["state"] as? String, "finished", "the library closed before the fade ended")
        XCTAssertEqual(notes, true, "the notes were not shown under the fade")
        XCTAssertEqual(open, true, "the library closed during the fade")
        XCTAssertEqual(openMidFade, true, "the library was closed while the fade was still running")
        XCTAssertTrue(isLocked)
    }

    func testNothingDecryptedRemainsAndThePageReloaded() throws {
        let live = controller()
        _ = runInPage(live, "window.oldDocument = true; return true;")
        endTheFadeAfter150ms(live)

        relock(live)
        spin(until: { self.runInPage(live, "return !!document.querySelector('#lock');") as? Bool == true }, "the page does not show the lock screen")

        XCTAssertEqual(runInPage(live, "return window.oldDocument === undefined;") as? Bool, true, "the old page was not reloaded")
        XCTAssertEqual(runInPage(live, "return document.body.innerText.includes('\(words)');") as? Bool, false)
        XCTAssertEqual(runInPage(live, "return JSON.stringify(window.catchlightLibrary).includes('\(words)');") as? Bool, false)
        XCTAssertEqual(runInPage(live, "return document.documentElement.innerHTML.includes('\(words)');") as? Bool, false)
    }

    func testAFadedRelockReloadsOnTheLockScreenWithoutFadingItInAgain() throws {
        let live = controller()
        endTheFadeAfter150ms(live)
        relock(live)
        spin(until: { self.runInPage(live, "return !!document.querySelector('#lock');") as? Bool == true }, "the page does not show the lock screen")
        XCTAssertNil(runInPage(live, lockAnimation) as? String, "the lock screen faded in a second time")
        XCTAssertFalse(live.bridge.justLocked, "the flag was not spent by the load")
    }

    func testAColdLoadOfTheLockScreenStillFadesIn() throws {
        vault.lock()
        let live = controller()
        spin(until: { self.runInPage(live, "return !!document.querySelector('#lock');") as? Bool == true }, "the page does not show the lock screen")
        let shown = runInPage(live, lockAnimation) as? String
        XCTAssertNotNil(shown, "a cold launch does not fade the lock screen in")
    }

    func testAPageThatNeverAnswersTheFadeStillLocksWithinTheTimeout() throws {
        let live = controller()
        live.fadeTimeout = 0.5
        _ = runInPage(live, "window.hung = new Promise(() => {}); window.catchlightLockFade = () => window.hung; return true;")
        let started = Date()

        relock(live)

        XCTAssertTrue(isLocked)
        let took = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(took, 0.5, "it did not wait for the fade")
        XCTAssertLessThan(took, 4, "it waited past the timeout")
    }

    func testTheScreenLockingDoesNotWaitForAFade() throws {
        let live = controller()
        live.fadeTimeout = 20
        _ = runInPage(live, "window.hung = new Promise(() => {}); window.catchlightLockFade = () => window.hung; return true;")
        let started = Date()

        live.screenDidLock(Notification(name: MainWindowController.screenLockedNotification))
        spin(until: { self.isLocked }, "the screen locking did not lock the library")

        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the screen lock waited for the fade")
    }
}
