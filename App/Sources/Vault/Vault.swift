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

    /// No account, or the library opened. Asks for the user once, when there is an account.
    ///
    /// It asks for the key straight away rather than checking that it exists first: on a Mac
    /// without a Secure Enclave the key item itself carries user presence, so the existence
    /// check prompted too, and a launch asked for the password twice (owner, 2026-10-04). A
    /// missing item answers not-found without a prompt, and only that means no account; a
    /// cancelled prompt is an error, never "no account", so it can't lead to a new phrase.
    @discardableResult
    /// macOS puts `reason` inside its own sentence ("Catchlight is trying to unlock your Takes."),
    /// so it starts lower case.
    func start(reason: String = "unlock your Takes") throws -> State {
        state = .locked
        let key: SymmetricKey
        do { key = try secrets.masterKey(reason: reason) }
        catch KeychainError.notFound { state = .noAccount; return state }
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

    /// Store the phrase, then the key, then open the library. A library already on disk stays
    /// only when it is a restore AND the phrase's key opens it; otherwise it is moved aside,
    /// never deleted, because a different key can't read it and nothing may be lost on the way in.
    /// `restored` comes from the page, so it is checked against the disk rather than trusted.
    func createAccount(words: [String], restored: Bool) throws {
        let words = Self.cleaned(words)
        let raw: Data
        do { raw = try PhraseRecovery.recoverMasterKey(from: words, bip39: try Self.englishBIP39()) }
        catch { throw Failure.invalidPhrase }
        let keys = KeyHierarchy(masterKeyBytes: raw)
        let aside = (restored && existingLibraryOpens(with: keys)) ? nil : try moveAsideExistingLibrary()
        let previous = state
        state = .noAccount   // the open library, if any, belongs to the account being replaced
        do {
            try secrets.storePhrase(words)
            try secrets.storeMasterKey(raw)
        } catch {
            // The old key is still in the Keychain, so put its library back where it opens.
            // The page stays on the old account, so its library stays open too.
            if let aside, !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.moveItem(at: aside, to: directory)
            }
            state = previous
            throw error
        }
        state = .open(try openLibrary(keys: KeyHierarchy(masterKeyBytes: raw)))
        Self.log.info("account created (restored: \(restored, privacy: .public))")
    }

    /// Settings ▸ Second device: this Mac takes the account the phrase opens. Nothing is erased.
    /// The Keychain items are replaced in place (update-or-add), and the library stays if the
    /// phrase opens it, else it is moved aside; if a Keychain write fails, it is moved back.
    func replaceAccount(words: [String]) throws {
        try createAccount(words: words, restored: true)
    }

    func phrase() -> [String]? { secrets.phrase(reason: "show your Privacy phrase") }

    /// Settings ▸ Erase everything: the library, any earlier library moved aside, then the
    /// Keychain items, as the iPhone's reset. The files go first: if removing one fails, the key
    /// that opens them is still there.
    func eraseEverything() throws {
        state = .noAccount
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        let parent = directory.deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix("\(directory.lastPathComponent)-before-") {
            try fm.removeItem(at: parent.appendingPathComponent(name))
        }
        secrets.deleteAll()
    }

    // MARK: Private

    private func openLibrary(keys: KeyHierarchy) throws -> Library {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.excludeFromBackup(directory)
        let store = try EncryptedTakeStore(keys: keys, directoryURL: directory)
        let scripts = try ScriptVault(keys: keys, directory: directory.appendingPathComponent("Scripts", isDirectory: true))
        return Library(store: store, scripts: scripts)
    }

    /// Whether the library on disk, if there is one, opens under `keys`: every Take decrypts,
    /// and if there are Scripts, at least one opens. Nothing on disk counts as opening (there is
    /// nothing to protect).
    private func existingLibraryOpens(with keys: KeyHierarchy) -> Bool {
        let fm = FileManager.default
        let database = directory.appendingPathComponent("Database/catchlight.db")
        if fm.fileExists(atPath: database.path) {
            // Sequences too: a library with no Takes left still holds them, sealed under its key.
            do {
                let store = try EncryptedTakeStore(keys: keys, directoryURL: directory)
                _ = try store.allTakes()
                _ = try store.allSequences()
            } catch {
                Self.log.info("the Takes on disk do not open with this phrase; the library will be moved aside")
                return false
            }
        }
        let scriptsDir = directory.appendingPathComponent("Scripts", isDirectory: true)
        let sealed = ((try? fm.contentsOfDirectory(atPath: scriptsDir.path)) ?? []).filter { $0.hasSuffix(".sealed") }
        if !sealed.isEmpty {
            guard let vault = try? ScriptVault(keys: keys, directory: scriptsDir), let opened = try? vault.all(), !opened.isEmpty else {
                Self.log.info("the Scripts on disk do not open with this phrase; the library will be moved aside")
                return false
            }
        }
        return true
    }

    /// Where it went, or nil when there was nothing to move.
    @discardableResult
    private func moveAsideExistingLibrary() throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              let contents = try? fm.contentsOfDirectory(atPath: directory.path), !contents.isEmpty else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = directory.deletingLastPathComponent().appendingPathComponent("Catchlight-before-\(stamp)", isDirectory: true)
        try fm.moveItem(at: directory, to: aside)
        try? Self.excludeFromBackup(aside)
        Self.log.info("an earlier library was moved aside to \(aside.lastPathComponent, privacy: .public)")
        return aside
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
