import Foundation
import CryptoKit
import CatchlightCore
import CatchlightAppleStorage
import os

/// Sync on the Mac (M3): Core's `SyncEngine` over the open library, the account's keys and the
/// chosen folder, as the iPhone builds it (`Wiring.makeSyncEngine`, `BackgroundSyncCoordinator`).
///
/// One pass at a time, off the main thread; a request while a pass is running is answered as
/// skipped, because the running pass already covers it and the engine is idempotent. Takes only:
/// the engine skips Scripts in the folder and the Mac's Scripts stay in their own files until
/// M3b. When the page should sync (launch, after a save, Sync Now) is the page's to decide,
/// because the sync setting lives there.
final class SyncService {
    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "sync")
    static let deviceIdKey = "syncDeviceId"

    let vault: Vault
    let folder: SyncFolder
    /// The queue for the library that is open now. A new library (first run, Second device) gets
    /// its own, read from its own folder.
    var conflicts: ConflictQueue {
        let library = vault.library.map(ObjectIdentifier.init)
        if library != queueLibrary {
            queueLibrary = library
            queue_ = ConflictQueue(directory: library == nil ? nil : vault.directory.appendingPathComponent("Conflicts", isDirectory: true),
                                   keys: vault.keys)
        }
        return queue_
    }
    private var queue_ = ConflictQueue()
    private var queueLibrary: ObjectIdentifier?
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.considus.catchlight.mac.sync", qos: .utility)
    /// Main thread only.
    private(set) var isSyncing = false
    /// Work that must not overlap a pass (a page save, the account commands, the flush on quit),
    /// run in order once the pass ends. Main thread only.
    private var waiting: [() -> Void] = []
    private let cancelLock = NSLock()
    private var cancelled = false

    init(vault: Vault, folder: SyncFolder, defaults: UserDefaults = .standard) {
        self.vault = vault
        self.folder = folder
        self.defaults = defaults
    }

    /// A stable id for this install, which the engine's lock and manifest name. Made once.
    var deviceId: UUID {
        if let s = defaults.string(forKey: Self.deviceIdKey), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: Self.deviceIdKey)
        return id
    }

    /// Nil when there is nothing to sync: no open library, or no folder that opens. Opening the
    /// folder can block on a cloud provider, so `run` calls this off the main thread.
    func makeEngine() -> SyncEngine? {
        guard let library = vault.library, let keys = vault.keys else { return nil }
        return makeEngine(store: library.store, keys: keys)
    }

    private func makeEngine(store: TakeStore, keys: KeyHierarchy) -> SyncEngine? {
        guard let cloud = folder.open() else { return nil }
        // The Import folder, there from the start as the iPhone makes it (owner 2026-06-22).
        cloud.ensureSubfolder("Import")
        return SyncEngine(store: store, cloud: cloud, keys: keys, deviceId: deviceId)
    }

    /// Run `work` now if no pass is running, else once it ends. A page save diffs against the store
    /// and then writes; a pass writing the store in between would slip past the conflict check, and
    /// Erase everything must never remove the library under a pass. Main thread only.
    func whenIdle(_ work: @escaping () -> Void) {
        if isSyncing { waiting.append(work) } else { work() }
    }

    /// Ask a running pass to stop at its next Take (quitting). The engine is crash-safe, and an
    /// interrupted pass carries on cleanly next time.
    func cancel() {
        cancelLock.lock(); cancelled = true; cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelled
    }

    enum Outcome {
        /// Nothing ran: a pass is already running, or there is no folder or open library.
        case skipped
        case finished(SyncReport)
        case failed(Error)
    }

    /// Run one pass. `done` is called on the main thread. Call from the main thread.
    func run(_ done: @escaping (Outcome) -> Void) {
        guard !isSyncing, let library = vault.library, let keys = vault.keys, folder.hasFolder else { return done(.skipped) }
        isSyncing = true
        cancelLock.lock(); cancelled = false; cancelLock.unlock()
        let store = library.store
        queue.async { [self] in
            let outcome: Outcome
            if let engine = makeEngine(store: store, keys: keys) {
                do { outcome = .finished(try engine.sync(isCancelled: { self.isCancelled })) } catch { outcome = .failed(error) }
            } else {
                outcome = .skipped   // the folder no longer opens; the page shows none at the next launch
            }
            DispatchQueue.main.async { [self] in
                isSyncing = false
                defer {
                    let work = waiting
                    waiting = []
                    work.forEach { $0() }
                }
                if case .finished(let report) = outcome {
                    conflicts.enqueue(report.conflicts)
                    conflicts.enqueueUnverified(report.unverified)
                    Self.log.info("sync: \(report.applied.count) applied, \(report.deletedLocally.count) deleted, \(report.uploaded.count) uploaded, \(report.conflicts.count) conflicts")
                } else if case .failed(let error) = outcome {
                    Self.log.error("sync failed: \(String(describing: error), privacy: .public)")
                }
                done(outcome)
            }
        }
    }

    /// The notice the page shows for a failed pass, in the iPhone's words (`Notice.message`), or
    /// nil for a failure the user never sees (no folder: local-only is a choice, not a fault).
    static func notice(for error: Error) -> String? {
        if error is CancellationError { return nil }   // stopped on purpose (quitting)
        if let sync = error as? SyncError {
            switch sync {
            case .manifestSignatureInvalid: return "Sync paused. Your cloud data looks unexpected. No changes were made locally."
            case .noCloudFolderConfigured: return nil
            default: return "Sync encountered a problem and will retry."
            }
        }
        if let lock = error as? SyncLockError, case .heldByOtherDevice = lock {
            return "Another device is syncing. Catchlight will retry automatically."
        }
        return "Sync encountered a problem and will retry."
    }
}

/// Conflicts waiting for the user. Unlike the iPhone's (`ConflictQueue`, in memory), each pending
/// pair is also kept on disk, sealed: a save that finds a conflict writes this Mac's version, and
/// the pass after it uploads that version, so the other device's version may exist nowhere but
/// here until the user chooses. Quitting must not lose it. One file per Take in the library's
/// `Conflicts` folder, AES-256-GCM under Core's per-item key for the Take's id, with the format
/// named in the additional data so it can never be opened as anything else (as `ScriptVault`).
/// The folder sits inside the library, so Erase everything removes it and a library moved aside
/// takes it along. A resolved conflict is stamped as a fresh edit so the next push makes the
/// chosen version the newest everywhere.
///
/// Unverified copies stay in memory, as on the iPhone: the engine never writes them, so the next
/// pass finds them again.
final class ConflictQueue {
    static let format = Data("catchlight.mac.conflict.v1".utf8)
    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "sync")

    private(set) var pending: [(local: Take, remote: Take)] = []
    private(set) var unverified: [UnverifiedCopy] = []
    private let directory: URL?
    private let keys: KeyHierarchy?

    var count: Int { pending.count + unverified.count }

    /// - Parameters: `directory` and `keys` both nil keeps the queue in memory only (no library open).
    init(directory: URL? = nil, keys: KeyHierarchy? = nil) {
        self.directory = directory
        self.keys = keys
        guard let directory, let keys else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "conflict" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            do { pending.append(try Self.open(Data(contentsOf: url), id: id, keys: keys)) } catch {
                // Kept as it is, never deleted: it may hold the only copy of the other version.
                Self.log.error("a waiting conflict did not open and is kept: \(url.lastPathComponent, privacy: .public)")
            }
        }
    }

    /// An incoming pair replaces a pending one for the same Take, so the choice is always made
    /// against the newest versions.
    func enqueue(_ pairs: [(local: Take, remote: Take)]) {
        for pair in pairs {
            if let i = pending.firstIndex(where: { $0.local.id == pair.local.id }) { pending[i] = pair }
            else { pending.append(pair) }
            persist(pair)
        }
    }

    func enqueueUnverified(_ items: [UnverifiedCopy]) {
        for item in items {
            if let i = unverified.firstIndex(where: { $0.id == item.id }) { unverified[i] = item }
            else { unverified.append(item) }
        }
    }

    enum Choice: String { case local, remote, both }

    /// Write the user's choice (owner, 2026-10-05: keep this Mac's version, the other device's, or
    /// both). The kept version is stamped as a fresh edit so the next push makes it the newest
    /// everywhere and the conflict doesn't come back. Keep both keeps this Mac's version on its id
    /// and the other beside it as a new Take. The waiting file goes only once everything is written.
    @discardableResult
    func resolve(id: UUID, choice: Choice, store: TakeStore, now: Date = Date()) throws -> Take? {
        guard let i = pending.firstIndex(where: { $0.local.id == id }) else { return nil }
        let pair = pending[i]
        var kept = choice == .remote ? pair.remote : pair.local
        kept.modifiedAt = now
        try store.upsert(kept)
        var copy: Take?
        if choice == .both {
            var other = Self.copy(of: pair.remote)
            other.modifiedAt = now
            try store.upsert(other)
            copy = other
        }
        pending.remove(at: i)
        if let url = fileURL(id) { try? FileManager.default.removeItem(at: url) }
        return copy
    }

    /// The other device's version as a Take of its own: a new id, a new notification id for its
    /// reminder so the two never cancel each other, and never the Obie (as Core's `SyncEngine.fork`).
    static func copy(of take: Take) -> Take {
        let id = UUID()
        var reminder = take.timeReminder
        reminder?.notificationIdentifier = id.uuidString
        return Take(id: id, createdAt: take.createdAt, modifiedAt: take.modifiedAt,
                    blocks: take.blocks, contentType: take.contentType, isNote: take.isNote,
                    isObie: false, timeReminder: reminder,
                    locationReminder: take.locationReminder, attachments: take.attachments,
                    isSeeded: false, isImportant: take.isImportant, manualOrder: take.manualOrder)
    }

    // MARK: On disk

    private struct Pair: Codable { let local: Take; let remote: Take }

    private func fileURL(_ id: UUID) -> URL? {
        directory?.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("conflict")
    }

    private func persist(_ pair: (local: Take, remote: Take)) {
        guard let directory, let keys, let url = fileURL(pair.local.id) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.seal(pair, keys: keys).write(to: url, options: .atomic)
        } catch {
            Self.log.fault("a waiting conflict could not be kept on disk: \(String(describing: error), privacy: .public)")
        }
    }

    static func seal(_ pair: (local: Take, remote: Take), keys: KeyHierarchy) throws -> Data {
        let plain = try PlatformJSON.encode(Pair(local: pair.local, remote: pair.remote))
        let id = pair.local.id
        return try AES.GCM.seal(plain, using: keys.itemKey(takeUUID: id), authenticating: format + Data(id.uuidString.utf8)).combined!
    }

    static func open(_ sealed: Data, id: UUID, keys: KeyHierarchy) throws -> (local: Take, remote: Take) {
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plain = try AES.GCM.open(box, using: keys.itemKey(takeUUID: id), authenticating: format + Data(id.uuidString.utf8))
        let pair = try PlatformJSON.decode(Pair.self, from: plain)
        return (pair.local, pair.remote)
    }
}
