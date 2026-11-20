import AppKit
import CatchlightAppleStorage
import CryptoKit
import Security
import WebKit
import UserNotifications
import XCTest

/// The lock in the running window, as the iPhone's RootView and AppModel drive it: relock saves the
/// open edit and shows the lock screen with nothing decrypted in the page, an unlock reopens the
/// library and the lock screen fades away, a cancelled unlock offers Try Again, time away past
/// Settings → Lock after locks on return, the screen locking locks at once, and a Take opened from a
/// notification while locked opens once unlocked.
final class LockWiringTests: XCTestCase {
    /// Secrets in memory that can be told to refuse, as a cancelled Touch ID or password prompt does.
    /// The window asks off the main thread, so what the prompt shares with the test is behind a lock.
    /// `gate`, when set, holds the prompt open until the test signals it.
    private final class RefusingSecrets: Secrets {
        private let memory = MemorySecrets()
        private let guarded = NSLock()
        private var refusing = false, count = 0
        private var refusalError: Error = KeychainError.retrieveFailed(errSecUserCanceled)
        private var held: DispatchSemaphore?
        var refuse: Bool {
            get { guarded.withLock { refusing } }
            set { guarded.withLock { refusing = newValue } }
        }
        /// What a refusal throws: a cancelled prompt unless the test says otherwise.
        var refusal: Error {
            get { guarded.withLock { refusalError } }
            set { guarded.withLock { refusalError = newValue } }
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
            if refuse { throw refusal }
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

    /// A notification centre that runs `onAsk` once, the first time the reminders are reconciled
    /// after it is set: the moment a relock's flush has saved and is mirroring, before it locks.
    private final class HookedCentre: NotificationCentre {
        var onAsk: (() -> Void)?
        func add(_ request: UNNotificationRequest) {}
        func removePending(_ ids: [String]) {}
        func removeDelivered(_ ids: [String]) {}
        func removeAll() {}
        func pendingIdentifiers(_ done: @escaping ([String]) -> Void) {
            let ask = onAsk
            onAsk = nil
            ask?()
            done([])
        }
        func deliveredIdentifiers(_ done: @escaping ([String]) -> Void) { done([]) }
        func authorizationStatus(_ done: @escaping (UNAuthorizationStatus) -> Void) { done(.authorized) }
        func requestAuthorization(_ done: @escaping (Bool) -> Void) { done(true) }
    }
    private var centre = HookedCentre()

    private func controller() -> MainWindowController {
        let mirror = LibraryMirror(reminders: MacReminders(centre: centre), spotlight: RecordingSpotlightIndexer(), defaults: defaults)
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

    /// ISSUE-292: a relock whose last save fails (here refused, as a full disk refuses it) must
    /// not lose what was typed. The control checks the save really failed;
    /// the last assertion is what the owner's "never lose user data" asks for.
    func testAnEditWhoseSaveFailsAtTheLockSurvivesTheUnlock() throws {
        let live = controller()
        XCTAssertEqual(runInPage(live, """
            beginEdit(takes[0]);
            rows.children[0].querySelector('.etext').textContent = 'Typed, not saved';
            return takes[0].blocks[0].text;
            """) as? String, savedText, "the edit is already saved, so the test proves nothing")

        // Every save the page sends is refused, as the shell answers when the disk is full. The
        // library keeps its file open, so folder permissions can't force this: the refusal is
        // made where the page hears it. The reload at the lock drops this override.
        XCTAssertEqual(runInPage(live, """
            const h = window.webkit.messageHandlers.catchlight, real = h.postMessage.bind(h);
            h.postMessage = m => m.cmd === 'save' ? Promise.reject(new Error('The disk is full.')) : real(m);
            return h.postMessage !== real;
            """) as? Bool, true, "the save refusal is not in place")

        secrets.refuse = true
        relock(live)
        XCTAssertTrue(isLocked, "the vault is not locked")

        secrets.refuse = false
        _ = runInPage(live, "document.querySelector('#lock .lock-button').click(); return true;")
        pageBecomes(live, "catchlightLibrary.unlocked === true && !catchlightLibrary.locked && !document.querySelector('#lock')",
                    "the page did not reload unlocked")

        XCTAssertEqual(try savedTexts(), [savedText], "the forced failure didn't stop the save, so the test proves nothing")
        let shown = runInPage(live, "return document.body.innerText;") as? String ?? ""
        XCTAssertTrue(shown.contains("Typed, not saved"), "the typing is gone after the unlock (ISSUE-292)")
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

    // MARK: The login prompt

    /// The Mac's login prompt makes the app inactive while it is up. Going away then is not time
    /// away: coming back after it, however long it took, leaves the library open.
    func testTheLoginPromptTakingTheAppAwayDoesNotRelock() throws {
        defaults.set("60", forKey: AppLock.lockAfterKey)
        let live = controller()
        secrets.refuse = true
        relock(live)
        secrets.refuse = false
        let gate = DispatchSemaphore(value: 0)
        secrets.gate = gate
        let askedBefore = secrets.asked

        _ = runInPage(live, "document.querySelector('#lock .lock-button').click(); return true;")
        spin(until: { self.secrets.asked == askedBefore + 1 }, "the prompt did not come up")
        post(NSApplication.didResignActiveNotification)
        now += 61
        gate.signal()
        pageBecomes(live, "catchlightLibrary.unlocked === true && !document.querySelector('#lock')", "the unlock did not finish")
        // A relock now would ask again on return: refusing keeps it locked, so it shows.
        secrets.gate = nil
        secrets.refuse = true
        post(NSApplication.didBecomeActiveNotification)
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        XCTAssertNotNil(vault.library, "coming back from the login prompt relocked the library")
        XCTAssertEqual(secrets.asked, askedBefore + 1, "coming back from the login prompt asked again")
        XCTAssertEqual(runInPage(live, "return !document.querySelector('#lock');") as? Bool, true)
    }

    /// Time away noted before an unlock is spent by it: the next return doesn't relock at once.
    func testAnUnlockForgetsTheTimeAway() throws {
        defaults.set("60", forKey: AppLock.lockAfterKey)
        let live = controller()
        secrets.refuse = true
        relock(live)
        secrets.refuse = false
        post(NSApplication.didResignActiveNotification)
        now += 61

        var answer: String?? = .none
        live.unlock { answer = .some($0) }
        spin(until: { answer != nil }, "the unlock did not answer")
        XCTAssertEqual(answer, .some(nil))
        // A relock waits for the page to save first, so the page must have loaded for one to show.
        pageBecomes(live, "catchlightLibrary.unlocked === true && !document.querySelector('#lock')", "the unlock did not reload the page")
        // A relock now would ask again on return: refusing keeps it locked, so it shows.
        secrets.refuse = true
        let askedAfter = secrets.asked
        post(NSApplication.didBecomeActiveNotification)
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        XCTAssertNotNil(vault.library, "the return after an unlock relocked the library")
        XCTAssertEqual(secrets.asked, askedAfter, "the return after an unlock asked again")
    }

    /// While the shell asks on its own, the lock screen says so, as the iPhone's does.
    func testTheUnlockAskedOnReturnShowsAuthenticating() throws {
        let live = controller()
        secrets.refuse = true
        relock(live)
        secrets.refuse = false
        let gate = DispatchSemaphore(value: 0)
        secrets.gate = gate
        let askedBefore = secrets.asked
        defer { gate.signal() }

        post(NSApplication.didBecomeActiveNotification)
        spin(until: { self.secrets.asked == askedBefore + 1 }, "the unlock was not asked for on return")
        pageBecomes(live, """
            document.querySelector('#lock .lock-message')?.textContent === 'Authenticating…'
              && document.querySelector('#lock .lock-button')?.textContent === 'Unlocking…'
              && document.querySelector('#lock .lock-button')?.disabled === true
            """, "the lock screen does not show Authenticating while the shell asks")
        gate.signal()
        pageBecomes(live, "catchlightLibrary.unlocked === true && !document.querySelector('#lock')", "the unlock did not finish")
    }

    // MARK: Unlock answers

    /// Any key error is a cancel, as on the iPhone ("Couldn't unlock..."): a missing key too, which
    /// must not tell the user to restart, where a launch with no key would offer first run.
    func testAMissingKeyAnswersCancelledAndStaysLocked() throws {
        let live = controller()
        secrets.refuse = true
        relock(live)
        secrets.refusal = KeychainError.notFound

        var answer: String?? = .none
        live.unlock { answer = .some($0) }
        spin(until: { answer != nil }, "the unlock did not answer")
        XCTAssertEqual(answer, .some("cancelled"))
        XCTAssertTrue(isLocked, "a missing key left the vault \(vault.state)")
    }

    /// A key that reads but a library that doesn't open: the restart message.
    func testALibraryThatWontOpenAnswersUnopenable() throws {
        let live = controller()
        secrets.refuse = true
        relock(live)
        secrets.refuse = false
        // A file where the library folder should be: opening it can't make the folder.
        try FileManager.default.moveItem(at: dir, to: dir.deletingLastPathComponent().appendingPathComponent("aside"))
        try Data().write(to: dir)

        var answer: String?? = .none
        live.unlock { answer = .some($0) }
        spin(until: { answer != nil }, "the unlock did not answer")
        XCTAssertEqual(answer, .some("unopenable"))
        XCTAssertTrue(isLocked, "a library that won't open left the vault \(vault.state)")
    }

    /// A second ask while the prompt is up waits for the same answer: one prompt, two replies.
    func testASecondUnlockWhileOneRunsSharesItsAnswer() throws {
        let live = controller()
        secrets.refuse = true
        relock(live)
        secrets.refuse = false
        let gate = DispatchSemaphore(value: 0)
        secrets.gate = gate
        let askedBefore = secrets.asked

        var answers: [String?] = []
        live.unlock { answers.append($0) }
        spin(until: { self.secrets.asked == askedBefore + 1 }, "the prompt did not come up")
        live.unlock { answers.append($0) }
        gate.signal()
        spin(until: { answers.count == 2 }, "both asks were not answered")

        XCTAssertEqual(answers, [nil, nil])
        XCTAssertEqual(secrets.asked, askedBefore + 1, "the second ask prompted again")
        XCTAssertNotNil(vault.library)
    }

    // MARK: Takes on their way during a relock

    /// A click whose Take was waiting for the page to load is held over the lock, not spent on the
    /// lock screen, where the Take isn't.
    func testATakeWaitingForThePageOpensAfterTheUnlock() throws {
        let live = controller()
        secrets.refuse = true
        live.takeOpener.pageDidUnload()   // as while the page reloads
        live.openTake(takeID)
        relock(live)

        secrets.refuse = false
        _ = runInPage(live, "document.querySelector('#lock .lock-button').click(); return true;")
        pageBecomes(live, "document.activeElement?.closest?.('[data-take]')?.dataset.take?.toLowerCase() === '\(takeID.uuidString.lowercased())'",
                    "the Take waiting for the page did not open after the unlock")
    }

    /// A click while the relock saves the page is held too: the page it would open in is going.
    func testATakeOpenedDuringTheRelockOpensAfterTheUnlock() throws {
        let live = controller()
        secrets.refuse = true
        var done = false
        live.relock { done = true }
        live.openTake(takeID)
        spin(until: { done }, "relock did not finish")
        pageBecomes(live, "document.querySelector('#lock')", "the page does not show the lock screen")

        secrets.refuse = false
        _ = runInPage(live, "document.querySelector('#lock .lock-button').click(); return true;")
        pageBecomes(live, "document.activeElement?.closest?.('[data-take]')?.dataset.take?.toLowerCase() === '\(takeID.uuidString.lowercased())'",
                    "the Take opened during the relock did not open after the unlock")
    }

    // MARK: Sync during a relock

    /// A pass the old page starts after the flush has saved still runs with the open library's
    /// keys: the library closes only once it has ended.
    func testARelockWaitsForASyncPassStartedDuringItsFlush() throws {
        let live = controller()
        secrets.refuse = true
        let folder = SyncFolder(defaults: defaults)
        let cloud = dir.deletingLastPathComponent().appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        folder.pick = { _, done in done(cloud) }
        folder.choose(in: nil) { _ in }
        let sync = SyncService(vault: vault, folder: folder, defaults: defaults)
        live.bridge.sync = sync

        var ran = false, openAtEnd: Bool?
        centre.onAsk = {
            sync.run { outcome in
                // The relock cancels it at its next Take, so it may end cancelled: it still ran.
                if case .skipped = outcome {} else { ran = true }
                openAtEnd = self.vault.library != nil
            }
        }
        relock(live)

        spin(until: { openAtEnd != nil }, "the sync pass did not end")
        XCTAssertTrue(ran, "the pass did not run, so the test proves nothing")
        XCTAssertEqual(openAtEnd, true, "the library closed under a running sync pass")
        XCTAssertTrue(isLocked)
    }
}
