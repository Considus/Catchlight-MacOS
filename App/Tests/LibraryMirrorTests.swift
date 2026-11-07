import CatchlightCore
import UserNotifications
import XCTest

final class RecordingSpotlightIndexer: SpotlightIndexing, @unchecked Sendable {
    var exposure: SpotlightExposure = .none
    var indexed: [UUID] = []
    var deindexed: [UUID] = []
    var deindexAllCount = 0

    func index(_ take: Take) { indexed.append(take.id) }
    func deindex(takeID: UUID) { deindexed.append(takeID) }
    func deindexAll() { deindexAllCount += 1 }
}

final class LibraryMirrorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let centre = FakeCentre()
    private let spotlight = RecordingSpotlightIndexer()
    private var dir: URL!

    override func setUp() {
        suiteName = "catchlight-mirror-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-mirror-\(UUID())/Catchlight")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func mirror() -> LibraryMirror {
        LibraryMirror(reminders: MacReminders(centre: centre), spotlight: spotlight, defaults: defaults)
    }

    private func take(kind: String? = nil) -> Take {
        Take(blocks: [.textLine("A note")], kind: kind)
    }

    func testExposureDefaultsToNone() {
        XCTAssertEqual(mirror().exposure, .none)
    }

    func testTheTextLevelsAreLockedToType() {
        let m = mirror()
        m.setExposure("all")
        XCTAssertEqual(m.exposure, .type)
        XCTAssertEqual(defaults.string(forKey: LibraryMirror.spotlightKey), "type")
        m.setExposure("firstLine")
        XCTAssertEqual(m.exposure, .type)
        m.setExposure("none")
        XCTAssertEqual(m.exposure, .none)
        XCTAssertEqual(defaults.string(forKey: LibraryMirror.spotlightKey), "none")
    }

    func testAStoredLevelIsRead() {
        defaults.set("type", forKey: LibraryMirror.spotlightKey)
        XCTAssertEqual(mirror().exposure, .type)
    }

    func testAtTypeOnlyTakesAreIndexedNotScripts() {
        let m = mirror()
        m.setExposure("type")
        let a = take(), b = take(), script = take(kind: "script")
        m.refresh(takes: [a, b, script])
        XCTAssertEqual(Set(spotlight.indexed), [a.id, b.id])
        XCTAssertEqual(spotlight.exposure, .type)
    }

    func testATakeThatIsGoneIsDeindexed() {
        let m = mirror()
        m.setExposure("type")
        let a = take(), b = take()
        m.refresh(takes: [a, b])
        m.refresh(takes: [a])
        XCTAssertEqual(spotlight.deindexed, [b.id])
    }

    func testSwitchingToNoneClearsSpotlightOnce() {
        let m = mirror()
        m.setExposure("type")
        m.refresh(takes: [take()])
        m.setExposure("none")
        XCTAssertEqual(spotlight.deindexAllCount, 1)
        m.refresh(takes: [take()])
        XCTAssertEqual(spotlight.deindexAllCount, 1, "not on every refresh")
        XCTAssertEqual(spotlight.indexed.count, 1, "nothing is indexed at none")
    }

    func testAChangeOfLevelRunsTheLastRefreshAgain() {
        let m = mirror()
        let a = take()
        m.refresh(takes: [a])
        XCTAssertTrue(spotlight.indexed.isEmpty)
        m.setExposure("type")
        XCTAssertEqual(spotlight.indexed, [a.id])
    }

    func testRefreshReconcilesReminders() {
        let m = mirror()
        centre.pending = [UUID().uuidString]
        m.refresh(takes: [])
        XCTAssertEqual(centre.removedPending.count, 1)
    }

    func testSeveralChangesInOneTurnRefreshOnce() {
        let bridge = ShellBridge()
        let ran = expectation(description: "the hook ran")
        var count = 0
        bridge.libraryChanged = { count += 1; ran.fulfill() }
        bridge.notifyLibraryChanged()
        bridge.notifyLibraryChanged()
        bridge.notifyLibraryChanged()
        wait(for: [ran], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(count, 1)
    }

    func testTwoChangesTenthsApartRefreshOnceAfterTheSecond() {
        let bridge = ShellBridge()
        XCTAssertEqual(bridge.libraryChangeDelay, 0.5)
        var ranAt: Date?
        let ran = expectation(description: "the hook ran")
        bridge.libraryChanged = { XCTAssertNil(ranAt); ranAt = Date(); ran.fulfill() }
        bridge.notifyLibraryChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let second = Date()
        bridge.notifyLibraryChanged()
        // 0.4 s after the second change, which is past 0.5 s after the first: still waiting.
        RunLoop.main.run(until: second.addingTimeInterval(0.4))
        XCTAssertNil(ranAt, "the second change restarts the wait")
        wait(for: [ran], timeout: 5)
        XCTAssertGreaterThanOrEqual(try! XCTUnwrap(ranAt).timeIntervalSince(second), 0.49)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
    }

    func testAPendingChangeCanBeTakenForQuitting() {
        let bridge = ShellBridge()
        bridge.libraryChanged = { XCTFail("a change taken for quitting must not run later") }
        XCTAssertFalse(bridge.takePendingLibraryChange())
        bridge.notifyLibraryChanged()
        XCTAssertTrue(bridge.takePendingLibraryChange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
    }

    func testAnEraseGivesAnEmptyList() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        XCTAssertNil(LibraryMirror.takes(from: nil), "no vault: nothing to mirror")
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        XCTAssertEqual(LibraryMirror.takes(from: vault)?.count, 0)
        try vault.eraseEverything()
        XCTAssertEqual(LibraryMirror.takes(from: vault)?.count, 0, "an erased account mirrors an empty library")
    }

    // MARK: Through the page

    private func page(with vault: Vault) -> (WebViewHarness, ShellBridge) {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        let bridge = ShellBridge()
        bridge.vault = vault
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)
        return (harness, bridge)
    }

    private let settle = "await window.webkit.messageHandlers.catchlight.postMessage({cmd: 'validatePhrase', words: []});"

    func testASaveFromThePageCallsLibraryChangedOnce() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        _ = try vault.library!.saveTakes([["id": UUID().uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true,
                                           "blocks": [["k": "text", "text": "From the library"]]]])
        let (harness, bridge) = page(with: vault)
        var count = 0
        let ran = expectation(description: "the hook ran")
        bridge.libraryChanged = { count += 1; ran.fulfill() }
        _ = try harness.run("""
            takes[0].blocks[0].text = 'Edited'; takes[0].modifiedAt = Date.now(); saveTakes();
            \(settle) return true;
            """, in: self)
        wait(for: [ran], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(count, 1)
    }

    func testEraseEverythingFromThePageRefreshesWithAnEmptyList() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let (harness, bridge) = page(with: vault)
        bridge.libraryChangeDelay = 0.05
        var seen: [Take]?
        let ran = expectation(description: "the hook ran")
        bridge.libraryChanged = { seen = LibraryMirror.takes(from: vault); ran.fulfill() }
        _ = try harness.run("""
            await window.webkit.messageHandlers.catchlight.postMessage({cmd: 'eraseEverything'});
            return true;
            """, in: self)
        wait(for: [ran], timeout: 5)
        XCTAssertEqual(seen?.count, 0)
    }

    func testChangeKindFromThePageCallsLibraryChanged() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let id = UUID()
        _ = try vault.library!.saveTakes([["id": id.uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true,
                                           "blocks": [["k": "text", "text": "Becomes a Script"]]]])
        let (harness, bridge) = page(with: vault)
        bridge.libraryChangeDelay = 0.05
        var count = 0
        let ran = expectation(description: "the hook ran")
        bridge.libraryChanged = { count += 1; ran.fulfill() }
        _ = try harness.run("""
            await catchlightBridge.changeKind(JSON.parse(JSON.stringify(takes[0])), 'scripts');
            return true;
            """, in: self)
        wait(for: [ran], timeout: 5)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(try XCTUnwrap(vault.library!.store.take(id: id)).isScript, "the change was written")
    }

    func testSetSpotlightFromThePageReachesTheMirror() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let (harness, bridge) = page(with: vault)
        let m = mirror()
        bridge.setSpotlight = m.setExposure
        let reply = try harness.run("""
            const r = await window.webkit.messageHandlers.catchlight.postMessage({cmd: 'setSpotlight', level: 'type'});
            return r;
            """, in: self)
        XCTAssertEqual(reply as? Bool, true)
        XCTAssertEqual(m.exposure, .type)
        XCTAssertEqual(defaults.string(forKey: LibraryMirror.spotlightKey), "type")
    }
}
