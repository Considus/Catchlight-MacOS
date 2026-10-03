import Foundation
import CryptoKit
import CatchlightAppleStorage

/// Where the master key and the Privacy phrase live. The app uses the Keychain; tests and the
/// Debug `-CLDebugAccount` launch use memory, because the data-protection keychain needs a signed,
/// entitled process and CI builds unsigned.
protocol Secrets: AnyObject {
    /// Whether this Mac holds an account. Never prompts.
    var hasAccount: Bool { get }
    func storePhrase(_ words: [String]) throws
    func storeMasterKey(_ raw: Data) throws
    /// Asks for the user (Touch ID or the login password) on the Keychain path.
    func masterKey(reason: String) throws -> SymmetricKey
    func phrase(reason: String) -> [String]?
    func deleteAll()
}

/// The shared Keychain code from Catchlight-AppleStorage, as the iPhone uses it: items never
/// sync, open only while the Mac is unlocked, and need user presence.
final class KeychainSecrets: Secrets {
    var hasAccount: Bool { MasterKeyKeychain.exists() }
    func storePhrase(_ words: [String]) throws { try MnemonicKeychain.store(words) }
    func storeMasterKey(_ raw: Data) throws { try MasterKeyKeychain.store(raw) }
    func masterKey(reason: String) throws -> SymmetricKey { try MasterKeyKeychain.retrieve(reason: reason) }
    func phrase(reason: String) -> [String]? { MnemonicKeychain.retrieve(reason: reason) }
    func deleteAll() {
        MasterKeyKeychain.delete()
        MnemonicKeychain.delete()
    }
}

/// Secrets held in memory for the life of the process.
final class MemorySecrets: Secrets {
    private var words: [String]?
    private var raw: Data?
    var hasAccount: Bool { raw != nil }
    func storePhrase(_ words: [String]) throws { self.words = words }
    func storeMasterKey(_ raw: Data) throws { self.raw = raw }
    func masterKey(reason: String) throws -> SymmetricKey {
        guard let raw else { throw KeychainError.notFound }
        return SymmetricKey(data: raw)
    }
    func phrase(reason: String) -> [String]? { words }
    func deleteAll() { words = nil; raw = nil }
}
