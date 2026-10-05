import Foundation
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
    let conflicts = ConflictQueue()
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

/// Conflicts waiting for the user, as the iPhone keeps them (`ConflictQueue`): not saved to disk,
/// because the next sync finds the same ones again. A conflict is resolved by writing the chosen
/// version stamped as a fresh edit, so the next push makes it the newest everywhere.
final class ConflictQueue {
    private(set) var pending: [(local: Take, remote: Take)] = []
    private(set) var unverified: [UnverifiedCopy] = []

    var count: Int { pending.count + unverified.count }

    /// An incoming pair replaces a pending one for the same Take, so the choice is always made
    /// against the newest versions.
    func enqueue(_ pairs: [(local: Take, remote: Take)]) {
        for pair in pairs {
            if let i = pending.firstIndex(where: { $0.local.id == pair.local.id }) { pending[i] = pair }
            else { pending.append(pair) }
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
    /// and the other beside it as a new Take.
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
}
