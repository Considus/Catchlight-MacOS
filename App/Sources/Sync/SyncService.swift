import Foundation
import CryptoKit
import CatchlightCore
import CatchlightAppleStorage
import os

/// Sync on the Mac (M3): Core's `SyncEngine` over the open library, the account's keys and the
/// chosen folder, as the iPhone builds it (`Wiring.makeSyncEngine`, `BackgroundSyncCoordinator`).
///
/// One pass at a time, off the main thread; a request while a pass is running is answered as
/// skipped, because the running pass already covers it and the engine is idempotent. Scripts are
/// in the same library and sync only once `syncScripts` is on. When the page should sync (launch, after a save, Sync Now) is the page's to decide,
/// because the sync setting lives there.
final class SyncService {
    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "sync")
    static let deviceIdKey = "syncDeviceId"
    /// Whether Scripts go to the sync folder (Script_Sync_Proposal, decision A). Off until the
    /// owner turns it on, once every phone reading the folder runs a build from 2026-10-01 or later:
    /// an older phone shows a Script as a Take and turns it back into one when it saves it.
    /// Off, the Mac keeps its Scripts in its library and Core's engine never uploads one.
    static let syncScriptsKey = "syncScripts"

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

    var holdsScripts: Bool { defaults.bool(forKey: Self.syncScriptsKey) }

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
        return SyncEngine(store: store, cloud: cloud, keys: keys, deviceId: deviceId,
                          holdsScripts: holdsScripts)
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
        // Every Take waiting for the user's choice, skipped ones included (owner, 2026-10-07): the
        // pass never uploads one, nor writes the folder's version over it or deletes it.
        let held = conflicts.heldIDs
        queue.async { [self] in
            let outcome: Outcome
            if let engine = makeEngine(store: store, keys: keys) {
                do { outcome = .finished(try engine.sync(isCancelled: { self.isCancelled }, holding: held)) } catch { outcome = .failed(error) }
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
                    // A waiting Take whose other side another device turned into a Script this Mac
                    // doesn't hold (`syncScripts` off): Core leaves it as it is and names it on
                    // every pass. The pair can no longer be resolved by re-stamping it, which would
                    // send the choice into the Script (Catchlight-Core#29).
                    conflicts.markConverted(report.heldConverted)
                    conflicts.enqueueUnverified(report.unverified)
                    // A waiting Take another device turned into a Script has left this Mac (Core
                    // releases it, or keeps this Mac's edit as a new Take): its pair goes too, so
                    // no conflict stays waiting for a Take that isn't here.
                    conflicts.release(Set(report.deletedLocally + report.forkedFromScripts))
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
            case .manifestSignatureInvalid: return String(localized: "Sync paused. Your cloud data looks unexpected. No changes were made locally.")
            case .noCloudFolderConfigured: return nil
            default: return String(localized: "Sync encountered a problem and will retry.")
            }
        }
        if let lock = error as? SyncLockError, case .heldByOtherDevice = lock {
            return String(localized: "Another device is syncing. Catchlight will retry automatically.")
        }
        return String(localized: "Sync encountered a problem and will retry.")
    }
}

/// Conflicts waiting for the user. Unlike the iPhone's (`ConflictQueue`, in memory), each pending
/// pair is also kept on disk, sealed: a save that finds a conflict writes this Mac's version over
/// the one sync brought in, so the other device's version may exist nowhere but here until the
/// user chooses. Quitting must not lose it. Until the choice the Take is HELD (owner, 2026-10-07:
/// "The file shouldn't update or edit until the conflict is resolved"): `heldIDs` goes to every
/// sync pass, which neither uploads it nor writes over it, and to every save, which refuses to
/// change it; the page shows it read-only. Only `resolve` writes it. One file per Take in the library's
/// `Conflicts` folder, AES-256-GCM under Core's per-item key for the Take's id, with the format
/// named in the additional data so it can never be opened as anything else (as `ScriptVault`).
/// The folder sits inside the library, so Erase everything removes it and a library moved aside
/// takes it along. A resolved conflict is stamped as a fresh edit so the next push makes the
/// chosen version the newest everywhere.
///
/// A pair whose other side another device has since turned into a Script this Mac doesn't hold
/// (`SyncReport.heldConverted`, only with `syncScripts` off: with it on, the Script arrives as the
/// pair's other side) is CONVERTED, kept in its file across relaunches until it is resolved. Its
/// Take must never be re-stamped or written on its own id, or the next push sends the choice into
/// the Script: `resolve` offers only `.asNew` and `.letGo` for it, and refuses the usual choices.
///
/// Unverified copies stay in memory, as on the iPhone: the engine never writes them, so the next
/// pass finds them again.
final class ConflictQueue {
    static let format = Data("catchlight.mac.conflict.v1".utf8)
    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "sync")

    private(set) var pending: [(local: Take, remote: Take)] = []
    private(set) var unverified: [UnverifiedCopy] = []
    /// Which versions each pending pair holds, as a token the page sends back with the choice:
    /// a pass can replace the pair while a choice waits behind it, and a choice made against one
    /// pair must never apply to another. Changes whenever the pair does. In memory only.
    private var revisions: [UUID: String] = [:]

    /// Pairs whose other side another device turned into a Script this Mac doesn't hold. Kept in
    /// each pair's file, so it survives a relaunch, and cleared only by `resolve` or `release`.
    private(set) var converted: Set<UUID> = []

    enum Failure: Error, LocalizedError, Equatable {
        /// The pair changed after the page read it: nothing is written, and the user chooses again.
        case pairChanged
        /// A choice that doesn't fit the pair: a version picked for a converted pair, whose other
        /// side is a Script this Mac never reads, or `.asNew` / `.letGo` for an ordinary pair.
        case choiceDoesNotFit
        /// The Take changed between reading it and letting it go, so nothing was kept.
        case takeChanged
        var errorDescription: String? {
            switch self {
            case .pairChanged: return "the versions changed while you were choosing"
            case .choiceDoesNotFit: return "that choice does not fit this conflict"
            case .takeChanged: return "the Take changed while its conflict was resolved"
            }
        }
    }
    private let directory: URL?
    private let keys: KeyHierarchy?

    var count: Int { pending.count + unverified.count }

    /// Takes whose waiting conflict file doesn't open: `<id>.conflict`, or one already set aside
    /// as `<id>.<uuid>.unreadable`. Each stays held, as on the iPhone, so a damaged file never
    /// lifts the rule for its Take: it can't be shown or chosen, so the page says so instead.
    private(set) var damaged: Set<UUID> = []

    /// The Takes waiting for a choice, skipped ones included, and those whose conflict doesn't
    /// open: nothing but `resolve` changes them, and no sync pass uploads them.
    var heldIDs: Set<UUID> { Set(pending.map(\.local.id)).union(damaged) }

    /// - Parameters: `directory` and `keys` both nil keeps the queue in memory only (no library open).
    init(directory: URL? = nil, keys: KeyHierarchy? = nil) {
        self.directory = directory
        self.keys = keys
        guard let directory, let keys else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "unreadable" {
            if let id = Self.id(of: url) { damaged.insert(id) }
        }
        for url in files where url.pathExtension == "conflict" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            do {
                let file = try Self.openFile(Data(contentsOf: url), id: id, keys: keys)
                add(file.pair)
                if file.converted { converted.insert(id) }
            } catch {
                // Kept as it is, never deleted or written over (`write` moves it aside first): it
                // may hold the only copy of the other version. Its Take stays held.
                damaged.insert(id)
                Self.log.error("a waiting conflict did not open and is kept: \(url.lastPathComponent, privacy: .public)")
            }
        }
    }

    /// An incoming pair replaces a pending one for the same Take, so the choice is always made
    /// against the newest versions.
    func enqueue(_ pairs: [(local: Take, remote: Take)]) {
        for pair in pairs {
            add(pair)
            persist(pair)
        }
    }

    /// Lets go of what waits for these Takes, which have left this Mac (another device made them
    /// Scripts): the pair and its file go, and a damaged file is kept but renamed `.released`, so
    /// it no longer holds an id nothing has.
    func release(_ ids: Set<UUID>) {
        for id in ids where heldIDs.contains(id) {
            pending.removeAll { $0.local.id == id }
            revisions[id] = nil
            converted.remove(id)
            if let url = fileURL(id) {
                try? setAsideIfUnreadable(url, id: id)
                try? FileManager.default.removeItem(at: url)
            }
            for file in damagedFiles(id) {
                try? FileManager.default.moveItem(at: file, to: file.deletingPathExtension().appendingPathExtension("released"))
            }
            damaged.remove(id)
            Self.log.info("a waiting conflict was let go: its Take left this Mac")
        }
    }

    /// The token for the pair now waiting for `id`, or nil when none waits.
    func revision(_ id: UUID) -> String? { revisions[id] }

    /// Marks waiting pairs whose other side another device has turned into a Script this Mac
    /// doesn't hold (`SyncReport.heldConverted`, named on every pass while held). The mark is
    /// written to the pair's file, so it survives a relaunch, and the pair's revision changes, so
    /// a version picked before it can't be applied. An id with no readable pair is left alone.
    func markConverted(_ ids: [UUID]) {
        for id in ids where !converted.contains(id) {
            guard let pair = pending.first(where: { $0.local.id == id }) else { continue }
            converted.insert(id)
            revisions[id] = UUID().uuidString.lowercased()
            persist(pair)
        }
    }

    private func add(_ pair: (local: Take, remote: Take)) {
        if let i = pending.firstIndex(where: { $0.local.id == pair.local.id }) {
            if pending[i].local == pair.local && pending[i].remote == pair.remote { return }
            pending[i] = pair
        } else {
            pending.append(pair)
        }
        revisions[pair.local.id] = UUID().uuidString.lowercased()
    }

    /// One pair, written to disk FIRST: a save calls this before replacing the other version in
    /// the store, so if the write fails it throws and the save writes nothing. The page's edit is
    /// written and is this Mac's side of the pair; from here the Take is held like any other.
    func keep(_ pair: (local: Take, remote: Take)) throws {
        try write(pair)
        add(pair)
    }

    func enqueueUnverified(_ items: [UnverifiedCopy]) {
        for item in items {
            if let i = unverified.firstIndex(where: { $0.id == item.id }) { unverified[i] = item }
            else { unverified.append(item) }
        }
    }

    /// `.local`, `.remote` and `.both` for an ordinary pair; `.asNew` and `.letGo` for a converted
    /// one, whose other side is a Script this Mac never reads.
    enum Choice: String { case local, remote, both, asNew = "new", letGo }

    /// Write the user's choice (owner, 2026-10-05: keep this Mac's version, the other device's, or
    /// both). The kept version is stamped as a fresh edit so the next push makes it the newest
    /// everywhere and the conflict doesn't come back. Keep both keeps this Mac's version on its id
    /// and the other beside it as a new Take. The waiting file goes only once everything is written.
    /// - Parameter revision: the pair's token as the page read it (`revision(_:)`). If the pair
    ///   has changed since (a pass replaced it while the choice waited), nothing is written and
    ///   this throws `pairChanged`. Nil skips the check (tests that hold the pair themselves).
    @discardableResult
    func resolve(id: UUID, choice: Choice, store: TakeStore, revision: String? = nil, now: Date = Date()) throws -> Take? {
        guard let i = pending.firstIndex(where: { $0.local.id == id }) else { return nil }
        if let revision, revision != revisions[id] { throw Failure.pairChanged }
        let pair = pending[i]
        if converted.contains(id) != [.asNew, .letGo].contains(choice) { throw Failure.choiceDoesNotFit }
        if converted.contains(id) {
            let copy = try resolveConverted(pair, keepAsNew: choice == .asNew, store: store, now: now)
            finish(id)
            return copy
        }
        // This Mac's version is the Take as it is NOW. Saves can't change a held Take, so that is
        // the version the conflict was found against; reading the store still guards against
        // anything that wrote it outside a save. Only if it has gone does the copy stand in.
        let current = try store.take(id: id) ?? pair.local
        var kept = choice == .remote ? pair.remote : current
        kept.modifiedAt = now
        try store.upsert(kept)
        var copy: Take?
        if choice == .both {
            var other = Self.copy(of: pair.remote)
            other.modifiedAt = now
            try store.upsert(other)
            copy = other
        }
        finish(id)
        return copy
    }

    /// The pair is resolved: it, its mark and its file go. Only this pair's own file goes: one that
    /// doesn't open is set aside first, never removed.
    private func finish(_ id: UUID) {
        pending.removeAll { $0.local.id == id }
        revisions[id] = nil
        converted.remove(id)
        if let url = fileURL(id) {
            try? setAsideIfUnreadable(url, id: id)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A converted pair: the other side is now a Script on another device, which this Mac never
    /// reads. Nothing is written on the Take's own id, which the folder now lists as that Script.
    /// - Keep as new: this Mac's version is saved as a NEW Take, as Core's `SyncEngine.fork`
    ///   makes one: a new id, a new notification id for its reminder, its `createdAt` kept, and the
    ///   Obie only if the original was, applied once the original has gone. It is stamped as a
    ///   fresh edit so the next push uploads it. The original is then let go.
    /// - Let it go: the original leaves this Mac now, with no deletion record (`TakeStore.release`),
    ///   so it can't be edited into the Script before the next pass.
    /// Either way the Script in the folder is left exactly as the other device wrote it.
    private func resolveConverted(_ pair: (local: Take, remote: Take), keepAsNew: Bool,
                                  store: TakeStore, now: Date) throws -> Take? {
        let id = pair.local.id
        let current = try store.take(id: id)
        var copy: Take?
        if keepAsNew {
            var made = Self.copy(of: current ?? pair.local)
            made.modifiedAt = now
            try store.upsert(made)
            copy = made
        }
        if let current, try !store.release(id: id, ifNotModifiedAfter: current.modifiedAt) {
            // Changed between the read and the release: withdraw the copy and write nothing.
            if let copy { _ = try store.release(id: copy.id, ifNotModifiedAfter: copy.modifiedAt) }
            throw Failure.takeChanged
        }
        if let made = copy, (current ?? pair.local).isObie {
            try store.setObie(id: made.id, replaceExisting: true)
            copy = try store.take(id: made.id) ?? made
        }
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
                    isSeeded: false, isImportant: take.isImportant, manualOrder: take.manualOrder,
                    kind: take.kind, pageMode: take.pageMode)
    }

    // MARK: On disk

    /// `converted` is absent in files from before Core 1.5, which read as not converted.
    private struct Pair: Codable { let local: Take; let remote: Take; var converted: Bool? }

    /// The id a conflict file is named for: `<id>.conflict`, `<id>.<uuid>.unreadable`.
    static func id(of url: URL) -> UUID? {
        url.lastPathComponent.split(separator: ".").first.flatMap { UUID(uuidString: String($0)) }
    }

    private func damagedFiles(_ id: UUID) -> [URL] {
        guard let directory else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "unreadable" && Self.id(of: $0) == id }
    }

    private func fileURL(_ id: UUID) -> URL? {
        directory?.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("conflict")
    }

    private func persist(_ pair: (local: Take, remote: Take)) {
        do { try write(pair) } catch {
            Self.log.fault("a waiting conflict could not be kept on disk: \(String(describing: error), privacy: .public)")
        }
    }

    /// Writes the pair to its file. A file already there that doesn't open is moved aside first,
    /// never written over: it may hold the only copy of another version. If it can't be moved,
    /// this throws and writes nothing.
    private func write(_ pair: (local: Take, remote: Take)) throws {
        guard let directory, let keys, let url = fileURL(pair.local.id) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setAsideIfUnreadable(url, id: pair.local.id)
        try Self.seal(pair, converted: converted.contains(pair.local.id), keys: keys).write(to: url, options: .atomic)
    }

    /// A file at `url` that doesn't open as `id`'s pair goes to `<id>.<new uuid>.unreadable`
    /// beside it, which nothing reads back or removes.
    private func setAsideIfUnreadable(_ url: URL, id: UUID) throws {
        guard let keys, FileManager.default.fileExists(atPath: url.path) else { return }
        if (try? Self.open(Data(contentsOf: url), id: id, keys: keys)) != nil { return }
        let aside = url.deletingPathExtension().appendingPathExtension(UUID().uuidString.lowercased()).appendingPathExtension("unreadable")
        try FileManager.default.moveItem(at: url, to: aside)
        damaged.insert(id)
        Self.log.error("a waiting conflict that did not open was set aside: \(aside.lastPathComponent, privacy: .public)")
    }

    static func seal(_ pair: (local: Take, remote: Take), converted: Bool = false, keys: KeyHierarchy) throws -> Data {
        let plain = try PlatformJSON.encode(Pair(local: pair.local, remote: pair.remote, converted: converted ? true : nil))
        let id = pair.local.id
        return try AES.GCM.seal(plain, using: keys.itemKey(takeUUID: id), authenticating: format + Data(id.uuidString.utf8)).combined!
    }

    static func open(_ sealed: Data, id: UUID, keys: KeyHierarchy) throws -> (local: Take, remote: Take) {
        try openFile(sealed, id: id, keys: keys).pair
    }

    static func openFile(_ sealed: Data, id: UUID, keys: KeyHierarchy) throws -> (pair: (local: Take, remote: Take), converted: Bool) {
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plain = try AES.GCM.open(box, using: keys.itemKey(takeUUID: id), authenticating: format + Data(id.uuidString.utf8))
        let pair = try PlatformJSON.decode(Pair.self, from: plain)
        return ((pair.local, pair.remote), pair.converted == true)
    }
}
