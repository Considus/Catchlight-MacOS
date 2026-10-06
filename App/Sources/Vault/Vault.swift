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

    enum Failure: Error, LocalizedError {
        case invalidPhrase
        case noAccount
        /// Second device failed and the old key could not be put back, so the new key was removed:
        /// the library is closed and only a restore with the existing phrase reopens it.
        case restoreNeeded

        var errorDescription: String? {
            switch self {
            case .invalidPhrase: return "That isn't a valid Privacy phrase."
            case .noAccount: return "There is no account on this Mac."
            case .restoreNeeded: return "Catchlight couldn't finish adding this Mac and has locked your Takes to keep them safe. Quit Catchlight, open it again, and choose I already use Catchlight with your current Privacy phrase. Your Takes will be there."
            }
        }
    }

    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "vault")

    let secrets: Secrets
    /// `~/Library/Containers/com.considus.catchlight.mac/Data/Library/Application Support/Catchlight`
    /// under the sandbox. Kept out of Time Machine (D-340): the Takes in it are encrypted, but
    /// restoring a backup onto another Mac would carry them there without the key's consent.
    let directory: URL
    private(set) var state: State = .noAccount
    /// The open account's master key. It is in memory anyway (the library's keys come from it);
    /// keeping the bytes lets a failed Second device put the old key back without a prompt.
    private var openKey: Data?

    init(secrets: Secrets, directory: URL) {
        self.secrets = secrets
        self.directory = directory
    }

    static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Catchlight", isDirectory: true)
    }

    var library: Library? { if case .open(let l) = state { return l } else { return nil } }
    /// The open account's keys, for the sync engine (M3). Nil when locked or with no account.
    var keys: KeyHierarchy? {
        guard library != nil, let openKey else { return nil }
        return KeyHierarchy(masterKeyBytes: openKey)
    }

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
        openKey = key.withUnsafeBytes { Data($0) }
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
        let previous = state, previousKey = openKey
        state = .noAccount   // the open library, if any, belongs to the account being replaced
        do {
            if let previousKey {
                // Replacing an open account: the key first, because the old one is in memory and
                // can go back. Phrase first would leave the new words beside the old key if the
                // key write failed, and the old words can't be read back without a prompt.
                try secrets.storeMasterKey(raw)
                do { try secrets.storePhrase(words) } catch {
                    do { try secrets.storeMasterKey(previousKey) } catch {
                        // The new key now sits beside the old phrase. Remove it: with no key the
                        // next launch is first run, and restoring with the phrase the owner has
                        // reopens this library. A key beside the wrong phrase has no way back.
                        // The session closes too, so nothing more is written that the next
                        // launch couldn't open until the restore; the page says what to do.
                        Self.log.fault("the old key could not be put back; the new key is removed so the phrase restores this library")
                        secrets.deleteMasterKey()
                        throw Failure.restoreNeeded
                    }
                    throw error
                }
            } else {
                // A new account: the phrase first (D-253), so a key never exists without one.
                try secrets.storePhrase(words)
                try secrets.storeMasterKey(raw)
            }
        } catch {
            // Put the old library back where it opens. Keep it open (the page stays on the old
            // account) unless its key is gone, in which case it stays closed until the restore.
            if let aside, !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.moveItem(at: aside, to: directory)
            }
            if case Failure.restoreNeeded = error { openKey = nil } else { state = previous }
            throw error
        }
        openKey = raw
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
        // Earlier libraries first and this one last: if anything fails, the open library and the
        // key that opens it are both still there. A folder that can't be listed stops it too.
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        let earlier = try fm.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix("\(directory.lastPathComponent)-before-") }
        for name in earlier { try fm.removeItem(at: parent.appendingPathComponent(name)) }
        // Closed only once its files are gone: if removing them fails, the account stays open.
        let previous = state
        state = .noAccount
        do { if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) } }
        catch { state = previous; throw error }
        secrets.deleteAll()
        openKey = nil
    }

    // MARK: Private

    private func openLibrary(keys: KeyHierarchy) throws -> Library {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.excludeFromBackup(directory)
        let store = try EncryptedTakeStore(keys: keys, directoryURL: directory)
        let scripts = try ScriptVault(keys: keys, directory: directory.appendingPathComponent("Scripts", isDirectory: true))
        let library = Library(store: store, scripts: scripts)
        library.moveScriptsIn()
        return library
    }

    /// Whether the library on disk, if there is one, opens under `keys`: every Take decrypts,
    /// and if there are Scripts, at least one opens. Nothing on disk counts as opening (there is
    /// nothing to protect).
    private func existingLibraryOpens(with keys: KeyHierarchy) -> Bool {
        let fm = FileManager.default
        let database = directory.appendingPathComponent("Database/catchlight.db")
        if fm.fileExists(atPath: database.path) {
            // Sequences too: a library with no Takes left still holds them, sealed under its key.
            // The Takes and Sequences decide: all must decrypt, and if there are any, that settles
            // it, so damaged Scripts never move readable Takes aside. Only a library holding
            // neither falls back to its Scripts.
            do {
                let store = try EncryptedTakeStore(keys: keys, directoryURL: directory)
                let takes = try store.allTakes(), sequences = try store.allSequences()
                if !takes.isEmpty || !sequences.isEmpty { return true }
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
