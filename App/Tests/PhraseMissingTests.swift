import XCTest
import CryptoKit

/// The shell tells the page when the key opened the library but no Privacy phrase is stored
/// (the iPhone's `AppModel.phraseMissing`), and only then.
final class PhraseMissingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catchlight-mac-phrase-\(UUID())", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func library(_ vault: Vault) throws -> [String: Any] {
        let bridge = ShellBridge()
        bridge.vault = vault
        let source = bridge.injectedLibrary().source
        let json = try XCTUnwrap(source.range(of: "window.catchlightLibrary = ").map { String(source[$0.upperBound...].dropLast()) })
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testAnAccountWithItsPhraseSaysNothing() throws {
        let vault = Vault(secrets: MemorySecrets(), directory: root)
        try vault.createAccount(words: try Vault.newPhrase(), restored: true)
        XCTAssertNil(try library(vault)["phraseMissing"])
    }

    func testAKeyWithoutAPhraseIsSaid() throws {
        let made = MemorySecrets()
        let first = Vault(secrets: made, directory: root)
        try first.createAccount(words: try Vault.newPhrase(), restored: true)
        let key = try made.masterKey(reason: "test").withUnsafeBytes { Data($0) }
        let secrets = MemorySecrets()
        try secrets.storeMasterKey(key)   // the key alone, as an install that lost its phrase
        let vault = Vault(secrets: secrets, directory: root)
        try vault.start()
        XCTAssertNotNil(vault.library, "the key still opens the library")
        XCTAssertEqual(try library(vault)["phraseMissing"] as? Bool, true)
    }

    func testALockedLibrarySaysNothing() throws {
        let made = MemorySecrets()
        try Vault(secrets: made, directory: root).createAccount(words: try Vault.newPhrase(), restored: true)
        let secrets = MemorySecrets()
        try secrets.storeMasterKey(try made.masterKey(reason: "test").withUnsafeBytes { Data($0) })
        let vault = Vault(secrets: secrets, directory: root)
        try vault.start()
        vault.lock()
        XCTAssertNil(try library(vault)["phraseMissing"], "nothing about the account until it is unlocked")
    }
}
