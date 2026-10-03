import Foundation
import CryptoKit
import CatchlightCore
import CatchlightAppleStorage
import os

/// The account on this Mac: the Privacy phrase, the master key, and the encrypted library they
/// open. First run follows the iPhone's (`OnboardingViewModel.finishOnboarding`): the phrase is
/// stored before the key (D-253), so the app can't believe it has an account until the phrase is
/// already safe.
final class Vault {
    enum State {
        case noAccount
        case locked
        case open(Library)
    }

    enum Failure: Error {
        case invalidPhrase
        case noAccount
    }

    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "vault")

    let secrets: Secrets
    /// `~/Library/Containers/com.considus.catchlight.mac/Data/Library/Application Support/Catchlight`
    /// under the sandbox. Kept out of Time Machine (D-340): the Takes in it are encrypted, but
    /// restoring a backup onto another Mac would carry them there without the key's consent.
    let directory: URL
    private(set) var state: State = .noAccount

    init(secrets: Secrets, directory: URL) {
        self.secrets = secrets
        self.directory = directory
    }

    static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Catchlight", isDirectory: true)
    }

    var library: Library? { if case .open(let l) = state { return l } else { return nil } }

    // MARK: Launch

    /// No account, or the library opened. Asks for the user when there is an account.
    @discardableResult
    func start(reason: String = "Unlock your Takes") throws -> State {
        guard secrets.hasAccount else { state = .noAccount; return state }
        state = .locked
        let key = try secrets.masterKey(reason: reason)
        state = .open(try openLibrary(keys: KeyHierarchy(masterKey: key)))
        return state
    }

    // MARK: First run

    static func englishBIP39() throws -> BIP39 { BIP39(wordlist: try EnglishWordlist.load()) }

    /// Twelve words with no word repeated, as the iPhone offers (it retries up to 32 times).
    static func newPhrase() throws -> [String] {
        let bip39 = try englishBIP39()
        var words = try bip39.generateMnemonic()
        for _ in 0..<32 where Set(words).count != words.count { words = try bip39.generateMnemonic() }
        return words
    }

    static func isValid(_ words: [String]) -> Bool {
        guard let bip39 = try? englishBIP39() else { return false }
        return (try? bip39.validate(mnemonic: cleaned(words))) != nil
    }

    /// Store the phrase, then the key, then open the library. `restored` keeps an existing
    /// library in place (the same phrase opens it); a new phrase moves any old one aside, since
    /// a different key can't read it and it should never be deleted on the way in.
    func createAccount(words: [String], restored: Bool) throws {
        let words = Self.cleaned(words)
        let raw: Data
        do { raw = try PhraseRecovery.recoverMasterKey(from: words, bip39: try Self.englishBIP39()) }
        catch { throw Failure.invalidPhrase }
        if !restored { try moveAsideExistingLibrary() }
        try secrets.storePhrase(words)
        try secrets.storeMasterKey(raw)
        state = .open(try openLibrary(keys: KeyHierarchy(masterKeyBytes: raw)))
        Self.log.info("account created (restored: \(restored, privacy: .public))")
    }

    func phrase() -> [String]? { secrets.phrase(reason: "Show your Privacy phrase") }

    /// Settings ▸ Erase everything: the Keychain items and the library, as the iPhone's reset.
    func eraseEverything() throws {
        state = .noAccount
        secrets.deleteAll()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Private

    private func openLibrary(keys: KeyHierarchy) throws -> Library {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.excludeFromBackup(directory)
        let store = try EncryptedTakeStore(keys: keys, directoryURL: directory)
        let scripts = try ScriptVault(keys: keys, directory: directory.appendingPathComponent("Scripts", isDirectory: true))
        return Library(store: store, scripts: scripts)
    }

    private func moveAsideExistingLibrary() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              let contents = try? fm.contentsOfDirectory(atPath: directory.path), !contents.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = directory.deletingLastPathComponent().appendingPathComponent("Catchlight-before-\(stamp)", isDirectory: true)
        try fm.moveItem(at: directory, to: aside)
        try? Self.excludeFromBackup(aside)
        Self.log.info("an earlier library was moved aside to \(aside.lastPathComponent, privacy: .public)")
    }

    static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try url.setResourceValues(values)
    }

    static func cleaned(_ words: [String]) -> [String] {
        words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    }
}
