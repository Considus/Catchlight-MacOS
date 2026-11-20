import XCTest
import CatchlightAppleStorage

final class AppLockTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var clock: Date!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "AppLockTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func appLock(lockAfter: Any? = 60) -> AppLock {
        if let lockAfter { defaults.set(lockAfter, forKey: AppLock.lockAfterKey) }
        return AppLock(defaults: defaults, now: { self.clock })
    }

    private func awayFor(_ seconds: TimeInterval, _ lock: AppLock) -> Bool {
        lock.noteWentAway()
        clock = clock.addingTimeInterval(seconds)
        return lock.shouldLockOnReturn()
    }

    // MARK: Vault.lock()

    func testLockClosesTheLibraryAndStartReopensIt() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Library"))
        try vault.createAccount(words: try Vault.newPhrase(), restored: false)
        XCTAssertNotNil(vault.library)
        vault.lock()
        XCTAssertNil(vault.library)
        XCTAssertNil(vault.keys)
        try vault.start()
        XCTAssertNotNil(vault.library)
    }

    func testLockWithNoAccountDoesNothing() {
        let vault = Vault(secrets: MemorySecrets(), directory: root.appendingPathComponent("Library"))
        vault.lock()
        guard case .noAccount = vault.state else { return XCTFail("state changed: \(vault.state)") }
    }

    // MARK: The away timer

    func testReturnBeforeTheGraceStaysUnlocked() {
        XCTAssertFalse(awayFor(59, appLock(lockAfter: 60)))
    }

    func testReturnAfterTheGraceLocks() {
        XCTAssertTrue(awayFor(60, appLock(lockAfter: 60)))
    }

    func testTheSettingIsReadFreshEachTime() {
        let lock = appLock(lockAfter: 60)
        lock.noteWentAway()
        defaults.set(300, forKey: AppLock.lockAfterKey)
        clock = clock.addingTimeInterval(120)
        XCTAssertEqual(lock.lockAfter, 300)
        XCTAssertFalse(lock.shouldLockOnReturn())
    }

    func testNoTimestampNeverLocks() {
        XCTAssertFalse(appLock().shouldLockOnReturn())
    }

    func testTheTimestampIsConsumed() {
        let lock = appLock(lockAfter: 60)
        XCTAssertTrue(awayFor(120, lock))
        XCTAssertFalse(lock.shouldLockOnReturn())
    }

    func testAMissingOrOddSettingMeansOneMinute() {
        XCTAssertEqual(appLock(lockAfter: nil).lockAfter, 60)
        for odd: Any in [45, "soon", "", -30.0, 0] {
            XCTAssertEqual(appLock(lockAfter: odd).lockAfter, 60, "\(odd)")
        }
        for allowed in [30, 60, 300, 1800, 3600] {
            XCTAssertEqual(appLock(lockAfter: "\(allowed)").lockAfter, Double(allowed))
            XCTAssertEqual(appLock(lockAfter: Double(allowed)).lockAfter, Double(allowed))
        }
    }
}
