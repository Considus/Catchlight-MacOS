import CatchlightCore
import XCTest

final class ShellBridgeLockTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var dir: URL!

    override func setUp() {
        suiteName = "catchlight-bridge-lock-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-bridge-lock-\(UUID())/Catchlight")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func lockedVault() throws -> Vault {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        _ = try vault.library!.saveTakes([["id": UUID().uuidString, "at": "2026-07-01T09:00:00Z", "isNote": true,
                                           "blocks": [["k": "text", "text": "Private words"]]]])
        vault.lock()
        return vault
    }

    /// The object the library script puts on the page, decoded.
    private func library(_ bridge: ShellBridge) throws -> [String: Any] {
        let source = bridge.injectedLibrary().source
        let prefix = "window.catchlightLibrary = ", json = String(source.dropFirst(prefix.count).dropLast())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func page(with bridge: ShellBridge) -> WebViewHarness {
        let harness = WebViewHarness(root: WebViewHarness.repoUI, ruleList: nil)
        bridge.install(in: harness.webView.configuration.userContentController)
        harness.load("index.html", in: self)
        return harness
    }

    /// What the bridge answers a command: the value, or `error:` and the reason.
    private func send(_ command: String, to harness: WebViewHarness) throws -> Any? {
        try harness.run("""
            try { return await window.webkit.messageHandlers.catchlight.postMessage(\(command)); }
            catch (e) { return 'error:' + (e.message || e); }
            """, in: self)
    }

    func testALockedLibraryHasNoTakesAndNeverOffersFirstRun() throws {
        let bridge = ShellBridge()
        bridge.vault = try lockedVault()
        let value = try library(bridge)
        XCTAssertEqual(value["account"] as? Bool, true)
        XCTAssertEqual(value["locked"] as? Bool, true)
        XCTAssertEqual((value["takes"] as? [Any])?.count, 0)
        XCTAssertEqual((value["scripts"] as? [Any])?.count, 0)
        XCTAssertNil(value["newPhrase"])
        XCTAssertNil(value["lockFailure"])
        XCTAssertNotNil(value["syncScripts"])
        XCTAssertFalse(bridge.injectedLibrary().source.contains("Private words"))
    }

    func testTheFailureRidesWithTheLockedLibrary() throws {
        let bridge = ShellBridge()
        bridge.vault = try lockedVault()
        bridge.lockFailure = "unopenable"
        XCTAssertEqual(try library(bridge)["lockFailure"] as? String, "unopenable")
        bridge.lockFailure = "cancelled"
        XCTAssertEqual(try library(bridge)["lockFailure"] as? String, "cancelled")
    }

    func testJustUnlockedIsSentOnce() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        let bridge = ShellBridge()
        bridge.vault = vault
        XCTAssertNil(try library(bridge)["unlocked"])
        bridge.justUnlocked = true
        XCTAssertEqual(try library(bridge)["unlocked"] as? Bool, true)
        XCTAssertFalse(bridge.justUnlocked)
        XCTAssertNil(try library(bridge)["unlocked"])
    }

    func testUnlockAnswersWhatTheWindowSays() throws {
        let bridge = ShellBridge()
        bridge.vault = try lockedVault()
        let harness = page(with: bridge)
        XCTAssertEqual(try send("{cmd: 'unlock'}", to: harness) as? String, "error:no lock in this build")
        var answer: String?
        bridge.unlock = { done in done(answer) }
        XCTAssertTrue(try send("{cmd: 'unlock'}", to: harness) is NSNull)
        answer = "cancelled"
        XCTAssertEqual(try send("{cmd: 'unlock'}", to: harness) as? String, "error:cancelled")
        answer = "unopenable"
        XCTAssertEqual(try send("{cmd: 'unlock'}", to: harness) as? String, "error:unopenable")
    }

    func testLockAfterIsStoredOnlyForTheFiveChoices() throws {
        let bridge = ShellBridge()
        bridge.defaults = defaults
        let harness = page(with: bridge)
        for seconds in ["30", "60", "300", "1800", "3600"] {
            _ = try send("{cmd: 'setLockAfter', seconds: \(seconds)}", to: harness)
            XCTAssertEqual(defaults.string(forKey: AppLock.lockAfterKey), seconds)
        }
        _ = try send("{cmd: 'setLockAfter', seconds: '300'}", to: harness)
        for bad in ["45", "'45'", "0", "-60", "'soon'", "null"] {
            _ = try send("{cmd: 'setLockAfter', seconds: \(bad)}", to: harness)
            XCTAssertEqual(defaults.string(forKey: AppLock.lockAfterKey), "300", "\(bad) was stored")
        }
    }

    func testASaveWhileLockedIsRefused() throws {
        let vault = try lockedVault()
        let bridge = ShellBridge()
        bridge.vault = vault
        let harness = page(with: bridge)
        let reply = try send("""
            {cmd: 'save', kind: 'takes', list: [{id: '\(UUID().uuidString)', at: '2026-07-02T09:00:00Z', isNote: true, blocks: [{k: 'text', text: 'New'}]}]}
            """, to: harness)
        XCTAssertEqual(reply as? String, "error:locked")
        guard case .open(let library) = try vault.start() else { return XCTFail("did not reopen") }
        XCTAssertEqual(try library.snapshot().takes.count, 1, "the refused save wrote a Take")
    }
}
