import CatchlightAppleStorage
import CryptoKit
import XCTest

/// `start()` is the launch's one ask: not-found means no account, a key opens the library. The
/// lock screen asks in two steps instead (`readKey` off the main thread, `open(with:)` on it), so
/// only the prompt leaves the main thread and the vault is changed on main alone.
final class VaultStartTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-start-\(UUID())/Catchlight")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func isNoAccount(_ state: Vault.State) -> Bool { if case .noAccount = state { return true } else { return false } }
    private func isLocked(_ state: Vault.State) -> Bool { if case .locked = state { return true } else { return false } }

    func testStartWithNoKeyIsNoAccount() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        XCTAssertTrue(isNoAccount(try vault.start()))
        XCTAssertTrue(isNoAccount(vault.state))
        XCTAssertNil(vault.library)
    }

    func testStartWithAKeyOpensTheLibrary() throws {
        let secrets = MemorySecrets()
        try Vault(secrets: secrets, directory: dir).createAccount(words: try Vault.newPhrase(), restored: false)
        let vault = Vault(secrets: secrets, directory: dir)
        guard case .open = try vault.start() else { return XCTFail("start did not open the library") }
        XCTAssertNotNil(vault.library)
        XCTAssertNotNil(vault.keys)
    }

    func testReadingTheKeyChangesNothingAndOpeningWithItOpens() throws {
        let secrets = MemorySecrets()
        let vault = Vault(secrets: secrets, directory: dir)
        try vault.createAccount(words: try Vault.newPhrase(), restored: false)
        vault.lock()

        let key = try vault.readKey()
        XCTAssertTrue(isLocked(vault.state), "reading the key changed the vault")
        try vault.open(with: key)
        XCTAssertNotNil(vault.library)
        XCTAssertNotNil(vault.keys)
    }

    func testReadingWithNoKeyThrowsNotFound() {
        let vault = Vault(secrets: MemorySecrets(), directory: dir)
        XCTAssertThrowsError(try vault.readKey()) { error in
            guard case KeychainError.notFound = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(isNoAccount(vault.state))
    }
}
