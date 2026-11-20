import AppKit
import CatchlightAppleStorage
import CryptoKit
import Security
import WebKit
import XCTest

/// The lock in the running window, as the iPhone's RootView and AppModel drive it: relock saves the
/// open edit and shows the lock screen with nothing decrypted in the page, an unlock reopens the
/// library and the lock screen fades away, a cancelled unlock offers Try Again, time away past
/// Settings → Lock after locks on return, the screen locking locks at once, and a Take opened from a
/// notification while locked opens once unlocked.
final class LockWiringTests: XCTestCase {
    /// Secrets in memory that can be told to refuse, as a cancelled Touch ID or password prompt does.
    private final class RefusingSecrets: Secrets {
        private let memory = MemorySecrets()
        var refuse = false
        private(set) var asked = 0
        var hasAccount: Bool { memory.hasAccount }
        func storePhrase(_ words: [String]) throws { try memory.storePhrase(words) }
        func storeMasterKey(_ raw: Data) throws { try memory.storeMasterKey(raw) }
        func masterKey(reason: String) throws -> SymmetricKey {
            asked += 1
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
    private var secrets: RefusingSecrets!
    private var vault: Vault!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var controllers: [MainWindowController] = []
    private let takeID = UUID()
    private let savedText = "Written before the lock"

    override func setUpWithError() throws {
        suite = "catchlight-lock-wiring-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-lock-\(UUID())/Catchlight")
        secrets = RefusingSecrets()
        vault = Vault(secrets: secrets, directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        _ = try vault.library!.saveTakes([["id": takeID.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true,
                                           "blocks": [["k": "text", "text": savedText]]]])
    }

    override func tearDown() {
        controllers.forEach { $0.window?.close() }
        controllers = []
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func controller() -> MainWindowController {
        let mirror = LibraryMirror(reminders: MacReminders(centre: FakeCentre()), spotlight: RecordingSpotlightIndexer(), defaults: defaults)
        let lock = AppLock(defaults: defaults, now: { [unowned self] in self.now })
        let made = MainWindowController(vault: vault, notifications: FakeCentre(), mirror: mirror, defaults: defaults,
                                        uiRoot: WebViewHarness.repoUI, lock: lock)
        made.webView.configuration.userContentController.addUserScript(WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controllers.append(made)
        pageIsLoaded(made)
        return made
    }

    /// Spins the run loop until the controller's web view has finished loading the app's page.
    private func pageIsLoaded(_ controller: MainWindowController) {
        let deadline = Date().addingTimeInterval(30)
        func loaded() -> Bool {
            !controller.webView.isLoading && controller.webView.url?.absoluteString == MainWindowController.startURL.absoluteString
        }
        while !loaded() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(loaded(), "the page did not load")
    }

    private func runInPage(_ controller: MainWindowController, _ body: String) -> Any? {
        var outcome: Result<Any, Error>?
        controller.webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { outcome = $0 }
        let deadline = Date().addingTimeInterval(20)
        while outcome == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return try? outcome?.get()
    }

    /// Spins the run loop until `expression` is true in the page (a page mid-reload answers false).
    @discardableResult
    private func pageBecomes(_ controller: MainWindowController, _ expression: String, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !controller.webView.isLoading, runInPage(controller, "return !!(\(expression));") as? Bool == true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail(message, file: file, line: line)
        return false
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
        pageBecomes(controller, "document.querySelector('#lock')", "the page does not show the lock screen")
    }

    private func savedTexts() throws -> [String] {
        let library = try XCTUnwrap(vault.library, "the library is not open")
        return try library.pageTakes().flatMap { ($0["blocks"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String } }
    }

    private var isLocked: Bool { if case .locked = vault.state { return true } else { return false } }

    private func post(_ name: Notification.Name) { NotificationCenter.default.post(name: name, object: NSApp) }

    // MARK: Relock

    func testRelockSavesTheOpenEditThenShowsTheLockScreen() throws {
        secrets.refuse = true   // a stray activation of the test process must not unlock it again
        let live = controller()
        XCTAssertEqual(runInPage(live, """
            beginEdit(takes[0]);
            rows.children[0].querySelector('.etext').textContent = 'Typed, not saved';
            return takes[0].blocks[0].text;
            """) as? String, savedText, "the edit is not saved before the relock, or the test proves nothing")

        relock(live)

        XCTAssertTrue(isLocked, "the vault is not locked")
        let page = runInPage(live, "return JSON.stringify({ locked: !!catchlightLibrary.locked, takes: takes.length, text: document.body.innerText });") as? String
        let shown = try XCTUnwrap(page.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        XCTAssertEqual(shown["locked"] as? Bool, true)
        XCTAssertEqual(shown["takes"] as? Int, 0, "a locked page holds no Takes")
        let text = try XCTUnwrap(shown["text"] as? String)
        XCTAssertFalse(text.contains("Typed, not saved"), "the locked page shows the edit")
        XCTAssertFalse(text.contains(savedText), "the locked page shows a Take")
        XCTAssertTrue(text.contains("Catchlight is locked"))

        secrets.refuse = false
        _ = try vault.start()
        XCTAssertEqual(try savedTexts(), ["Typed, not saved"], "the open edit was not saved before the lock")
    }

    // MARK: Unlock

    func testUnlockReopensAndTheLockFadesAway() throws {
        let live = controller()
        secrets.refuse = true
        relock(live)
        secrets.refuse = false

        _ = runInPage(live, "document.querySelector('#lock .lock-button').click(); return true;")

        pageBecomes(live, "catchlightLibrary.unlocked === true && !catchlightLibrary.locked && !document.querySelector('#lock')",
                    "the page did not reload unlocked")
        XCTAssertNotNil(vault.library, "the library is not open")
        XCTAssertNil(live.bridge.lockFailure)
        XCTAssertEqual(runInPage(live, "return takes.map(t => t.blocks[0].text).join();") as? String, savedText)
    }

    func testACancelledUnlockShowsTryAgain() throws {
        let live = controller()
        secrets.refuse = true
        relock(live)
        let askedBefore = secrets.asked

        // Coming back with the vault locked asks at once, as the iPhone does on return.
        post(NSApplication.didBecomeActiveNotification)

        spin(until: { live.bridge.lockFailure != nil }, "the unlock was not attempted")
        XCTAssertEqual(live.bridge.lockFailure, "cancelled")
        XCTAssertEqual(secrets.asked, askedBefore + 1)
        pageBecomes(live, "document.querySelector('#lock .lock-button')?.textContent === 'Try Again'",
                    "the page does not open on Try Again")
        XCTAssertTrue(isLocked)

        // A failure is showing: coming back again leaves it to the Try Again button.
        post(NSApplication.didBecomeActiveNotification)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(secrets.asked, askedBefore + 1, "a failure showing was asked again without the button")

        // Try Again that works clears the failure.
        secrets.refuse = false
        _ = runInPage(live, "document.querySelector('#lock .lock-button').click(); return true;")
        pageBecomes(live, "catchlightLibrary.unlocked === true && !document.querySelector('#lock')", "Try Again did not unlock")
        XCTAssertNil(live.bridge.lockFailure)
    }

    // MARK: Triggers

    func testAwayLongerThanLockAfterLocksOnReturn() throws {
        defaults.set("60", forKey: AppLock.lockAfterKey)
        let live = controller()
        secrets.refuse = true   // the unlock asked for on return is cancelled, so the lock stays to be seen
        post(NSApplication.didResignActiveNotification)
        now += 61
        post(NSApplication.didBecomeActiveNotification)

        spin(until: { self.isLocked }, "the vault did not lock on return")
        pageBecomes(live, "document.querySelector('#lock')", "the page does not show the lock screen")
        spin(until: { live.bridge.lockFailure == "cancelled" }, "the unlock was not asked for on return")
    }

    func testAShortTripStaysUnlocked() throws {
        defaults.set("60", forKey: AppLock.lockAfterKey)
        let live = controller()
        let askedBefore = secrets.asked
        post(NSApplication.didResignActiveNotification)
        now += 59
        post(NSApplication.didBecomeActiveNotification)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertNotNil(vault.library, "a short trip locked the library")
        XCTAssertEqual(secrets.asked, askedBefore, "a short trip asked for the user")
        XCTAssertEqual(runInPage(live, "return !document.querySelector('#lock') && takes.length === 1;") as? Bool, true)
    }

    func testTheScreenLockingLocksAtOnce() throws {
        defaults.set("3600", forKey: AppLock.lockAfterKey)
        let live = controller()
        secrets.refuse = true
        // What the observer of com.apple.screenIsLocked calls. Posting the real distributed
        // notification would reach every app on this Mac.
        live.screenDidLock(Notification(name: MainWindowController.screenLockedNotification))

        spin(until: { self.isLocked }, "the screen locking did not lock the library")
        pageBecomes(live, "document.querySelector('#lock')", "the page does not show the lock screen")
    }

    // MARK: A Take opened while locked

    func testATakeOpenedWhileLockedOpensAfterUnlock() throws {
        let live = controller()
        secrets.refuse = true
        relock(live)

        live.openTake(takeID)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(isLocked)

        secrets.refuse = false
        _ = runInPage(live, "document.querySelector('#lock .lock-button').click(); return true;")
        pageBecomes(live, "document.activeElement?.closest?.('[data-take]')?.dataset.take?.toLowerCase() === '\(takeID.uuidString.lowercased())'",
                    "the Take opened while locked did not open after the unlock")
    }
}
