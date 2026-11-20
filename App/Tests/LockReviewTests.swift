import AppKit
import CatchlightAppleStorage
import CatchlightCore
import CryptoKit
import Security
import WebKit
import XCTest

/// The PR review's findings on the lock: an unlock the screen lock overtook does not open the
/// library, a relock leaves no decrypted Takes in the mirror, and a Take whose open is waiting out
/// a busy page is held over a relock.
final class LockReviewTests: XCTestCase {
    /// Secrets in memory whose prompt the test can hold open (`gate`) and that can refuse.
    private final class GatedSecrets: Secrets, @unchecked Sendable {
        private let memory = MemorySecrets()
        private let guarded = NSLock()
        private var refusing = false, count = 0
        private var held: DispatchSemaphore?
        var refuse: Bool {
            get { guarded.withLock { refusing } }
            set { guarded.withLock { refusing = newValue } }
        }
        var asked: Int { guarded.withLock { count } }
        var gate: DispatchSemaphore? {
            get { guarded.withLock { held } }
            set { guarded.withLock { held = newValue } }
        }
        var hasAccount: Bool { memory.hasAccount }
        func storePhrase(_ words: [String]) throws { try memory.storePhrase(words) }
        func storeMasterKey(_ raw: Data) throws { try memory.storeMasterKey(raw) }
        func masterKey(reason: String) throws -> SymmetricKey {
            guarded.withLock { count += 1 }
            gate?.wait()
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
    private var secrets: GatedSecrets!
    private var vault: Vault!
    private var centre: FakeCentre!
    private var spotlight: RecordingSpotlightIndexer!
    private var mirror: LibraryMirror!
    private var controllers: [MainWindowController] = []
    private let takeID = UUID()
    private let words = "Words only the library holds"

    override func setUpWithError() throws {
        suite = "catchlight-lock-review-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-lock-review-\(UUID())/Catchlight")
        secrets = GatedSecrets()
        vault = Vault(secrets: secrets, directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        // A Take with a reminder three days out, so the notification centre holds one of ours.
        let reminder = TimeReminder(scheduledDate: Date().addingTimeInterval(3 * 86_400), notificationIdentifier: takeID.uuidString,
                                    alarmEnabled: true, isDone: false, isAllDay: false, recurrence: .none)
        try vault.library!.store.upsert(Take(id: takeID, blocks: [.textLine(words)], timeReminder: reminder))
        centre = FakeCentre()
        spotlight = RecordingSpotlightIndexer()
        mirror = LibraryMirror(reminders: MacReminders(centre: centre), spotlight: spotlight, defaults: defaults)
    }

    override func tearDown() {
        controllers.forEach { $0.window?.close() }
        controllers = []
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func controller() -> MainWindowController {
        let made = MainWindowController(vault: vault, notifications: FakeCentre(), mirror: mirror, defaults: defaults,
                                        uiRoot: WebViewHarness.repoUI, lock: AppLock(defaults: defaults))
        made.webView.configuration.userContentController.addUserScript(WKUserScript(source: "localStorage.clear();", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        made.fadeTimeout = 0.2   // no fade is under test here
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

    /// Waits for a page opened on the locked library (the old page may still show a `#lock` of its own).
    private func lockScreenLoads(_ live: MainWindowController, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        spin(until: { !live.webView.isLoading && self.runInPage(live, "return window.catchlightLibrary?.locked === true && !!document.querySelector('#lock');") as? Bool == true },
             message, file: file, line: line)
    }

    private func relock(_ live: MainWindowController) {
        var done = false
        live.relock { done = true }
        spin(until: { done }, "relock did not finish")
        lockScreenLoads(live, "the page does not show the lock screen")
    }

    private var isLocked: Bool { if case .locked = vault.state { return true } else { return false } }

    // MARK: B. The screen locking while the login prompt is up

    /// The Mac's screen locks while the prompt of an unlock is still up: the answer that comes back
    /// later belongs to an unlock the lock has overtaken. The library stays locked, the page shows
    /// the plain lock screen (no failure) and the ask is answered "cancelled".
    func testAnUnlockTheScreenLockOvertookLeavesTheLibraryLocked() throws {
        let live = controller()
        secrets.refuse = true
        relock(live)
        secrets.refuse = false
        let gate = DispatchSemaphore(value: 0)
        secrets.gate = gate
        defer { gate.signal() }
        let askedBefore = secrets.asked

        var answers: [String?] = []
        _ = runInPage(live, "document.querySelector('#lock .lock-button').click(); return true;")
        spin(until: { self.secrets.asked == askedBefore + 1 }, "the prompt did not come up")
        live.unlock { answers.append($0) }   // the same ask, so the test sees its answer

        live.screenDidLock(Notification(name: MainWindowController.screenLockedNotification))
        gate.signal()
        spin(until: { answers.count == 1 }, "the unlock was not answered")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))   // a reload with the library would have started by now

        XCTAssertEqual(answers, ["cancelled"], "the overtaken unlock was not answered cancelled")
        XCTAssertTrue(isLocked, "the unlock the screen lock overtook opened the library")
        XCTAssertNil(live.bridge.lockFailure, "an overtaken unlock is not a failure")
        lockScreenLoads(live, "the page does not show the lock screen")
        let page = runInPage(live, """
            return JSON.stringify({ takes: takes.length, text: document.body.innerText.includes('\(words)'),
              button: document.querySelector('#lock .lock-button').textContent,
              message: document.querySelector('#lock .lock-message').textContent });
            """) as? String
        let shown = try XCTUnwrap(page.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        XCTAssertEqual(shown["takes"] as? Int, 0, "a Take is in the page")
        XCTAssertEqual(shown["text"] as? Bool, false, "a Take's words are in the page")
        XCTAssertEqual(shown["button"] as? String, "Unlock", "the page does not show the plain locked state")
        XCTAssertEqual(shown["message"] as? String, "Authenticate to open your Takes.")
    }

    // MARK: C. The mirror forgets the Takes

    func testARelockLeavesNoTakesInTheMirrorAndTheRemindersStay() throws {
        let live = controller()
        spin(until: { self.mirror.holdsTakes && !self.centre.pending.isEmpty }, "the mirror did not read the library, or the test proves nothing")
        let pending = Set(centre.pending)
        let spotlightBefore = (spotlight.deindexAllCount, spotlight.deindexed)
        secrets.refuse = true

        relock(live)

        XCTAssertFalse(mirror.holdsTakes, "the mirror still holds the decrypted Takes after the relock")
        // The relock's save reconciles once more (ours removed and added again); what is scheduled stays.
        XCTAssertEqual(Set(centre.pending), pending, "the relock changed the scheduled reminders")
        XCTAssertEqual(centre.removeAllCount, 0, "the relock removed every reminder")
        XCTAssertEqual(spotlight.deindexAllCount, spotlightBefore.0, "the relock cleared the Spotlight index")
        XCTAssertEqual(spotlight.deindexed, spotlightBefore.1, "the relock took a Take out of Spotlight")
    }

    /// A background read already running when the Takes are forgotten does not bring them back.
    func testAReadThatFinishesAfterForgettingDoesNotRefillTheMirror() throws {
        let take = try XCTUnwrap(vault.library?.store.allTakes().first)
        let reading = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        mirror.mirror(using: {
            reading.signal()
            release.wait()
            return [take]
        }, inBackground: true)
        reading.wait()
        let pending = centre.pending

        mirror.forgetTakes()
        release.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertFalse(mirror.holdsTakes, "a read in flight refilled the mirror after it forgot the Takes")
        XCTAssertEqual(centre.pending, pending, "forgetting the Takes changed the scheduled reminders")
    }

    // MARK: D. A Take whose open is waiting out a busy page

    func testATakeWaitingToRetryOnABusyPageIsWithdrawn() {
        var calls: [String] = []
        var scheduled: [() -> Void] = []
        let opener = TakeOpener(callPage: { id, reply in calls.append(id); reply("busy") },
                                schedule: { _, work in scheduled.append(work) })
        opener.pageDidLoad()
        let id = UUID()
        opener.open(id)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(scheduled.count, 1, "the busy page's retry was not scheduled, or the test proves nothing")

        XCTAssertEqual(opener.withdrawWaiting(), id, "the Take waiting for its retry was not withdrawn")
        scheduled.forEach { $0() }
        XCTAssertEqual(calls.count, 1, "the withdrawn Take was still opened by its retry")
        XCTAssertNil(opener.withdrawWaiting(), "it was withdrawn twice")
    }

    func testATakeThatOpenedIsNotWithdrawn() {
        let opener = TakeOpener(callPage: { _, reply in reply("opened") }, schedule: { _, _ in })
        opener.pageDidLoad()
        opener.open(UUID())
        XCTAssertNil(opener.withdrawWaiting(), "a Take already open was held over the relock")
    }

    /// Through the window: the relock holds the Take its busy page was retrying, and the unlock opens it.
    func testATakeRetryingOnABusyPageOpensAfterTheUnlock() throws {
        let live = controller()
        // The page is busy (a sheet owns the keyboard) until the lock, so the open waits out its retry.
        _ = runInPage(live, "window.realOpenTake = window.catchlightOpenTake; window.catchlightOpenTake = () => 'busy'; return true;")
        live.openTake(takeID)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        secrets.refuse = true
        relock(live)
        // Long enough for a retry still scheduled to reach the lock screen, where the Take isn't.
        RunLoop.current.run(until: Date().addingTimeInterval(TakeOpener.retryDelay + 0.5))

        secrets.refuse = false
        _ = runInPage(live, "document.querySelector('#lock .lock-button').click(); return true;")
        spin(until: { !live.webView.isLoading && self.runInPage(live, "return document.activeElement?.closest?.('[data-take]')?.dataset.take?.toLowerCase() === '\(takeID.uuidString.lowercased())';") as? Bool == true },
             "the Take retrying on a busy page did not open after the unlock")
    }
}
