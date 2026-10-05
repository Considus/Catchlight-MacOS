import Foundation
import CatchlightCore
import os

/// The open library: Takes in Core's `TakeStore`, Scripts in the `ScriptVault`. The page saves its
/// whole Take list at once (`saveTakes()` in `ui/takes.js`), so a save is a diff, and it is a diff
/// against the SNAPSHOT the page's list came from, never against the store. Sync (M3) writes to
/// the store while the page holds its list; diffing against the store would read every Take sync
/// added as one the page deleted, and every Take sync updated as a page edit to undo. Against the
/// snapshot, only what the page itself changed is written, and the rest of the store is left alone.
///
/// Each snapshot has a generation. The page sends the generation its list came from with every
/// save, because a save it sent just before taking a newer snapshot still describes the older one.
///
/// An empty list is a real answer (the last Take deleted); the protection against saving over a
/// library the page never saw is the bridge's, which refuses saves when the library failed to load.
final class Library {
    struct SaveReport: Equatable {
        var upserted = 0
        var deleted = 0
        var unchanged = 0
        /// Takes the page sent that could not be translated; the stored version is left alone.
        var rejected: [String] = []
        /// Takes the page changed that sync had changed too since the page's snapshot. The
        /// page's version is kept and the synced one is kept beside it as a copy (ids of the copies).
        var keptBoth: [UUID] = []
        /// Takes the page deleted that sync had changed since: the change wins and the Take stays.
        var keptOverDelete: [UUID] = []
    }

    enum Failure: Error, LocalizedError, Equatable {
        /// The page's list came from a snapshot too old to diff against. Nothing is written.
        case staleSnapshot(Int)
        var errorDescription: String? {
            switch self {
            case .staleSnapshot: return "the page's copy of your Takes is out of date"
            }
        }
    }

    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "library")
    /// How many snapshots are kept to diff against. A page saves against the newest or the one
    /// before; more is headroom.
    private static let snapshotsKept = 8

    let store: TakeStore
    let scripts: ScriptVault
    /// The newest snapshot's generation. 0 is the store as the library opened, before any snapshot.
    private(set) var generation = 0
    /// Generations come from one counter for the whole process, so a library opened by Second
    /// device or a restore never hands out a number the page might still hold from the last one:
    /// a save naming another library's snapshot is refused rather than diffed against the wrong Takes.
    private static var lastGeneration = 0
    private var snapshots: [Int: [UUID: Take]] = [:]

    init(store: TakeStore, scripts: ScriptVault) {
        self.store = store
        self.scripts = scripts
    }

    /// Every Take in the page's shape, oldest first (as the store returns them), as a new snapshot.
    func snapshot() throws -> (generation: Int, takes: [[String: Any]]) {
        let all = try store.allTakes()
        let pages = try all.map(TakeTranslation.page(from:))
        Self.lastGeneration += 1
        generation = Self.lastGeneration
        snapshots[generation] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        if snapshots.count > Self.snapshotsKept, let oldest = snapshots.keys.min() { snapshots[oldest] = nil }
        return (generation, pages)
    }

    func pageTakes() throws -> [[String: Any]] { try snapshot().takes }

    /// - Parameter generation: the snapshot the page's list came from; nil means the newest.
    func saveTakes(_ page: [[String: Any]], generation: Int? = nil, now: Date = Date()) throws -> SaveReport {
        let gen = generation ?? self.generation
        let stored = Dictionary(uniqueKeysWithValues: try store.allTakes().map { ($0.id, $0) })
        var base: [UUID: Take]
        if let known = snapshots[gen] { base = known }
        else if gen == 0 { base = stored }   // no snapshot yet: the store is what the page was given
        else { throw Failure.staleSnapshot(gen) }

        var report = SaveReport()
        var seen = Set<UUID>()
        var changed: [Take] = []
        for item in page {
            let id = (item["id"] as? String).flatMap(UUID.init(uuidString:))
            if let id { seen.insert(id) }
            do {
                let was = id.flatMap { base[$0] }
                let take = try TakeTranslation.core(from: item, existing: was, now: now)
                if was != nil, take == was { report.unchanged += 1; continue }
                if let now = stored[take.id], let was, now != was, now != take {
                    // Both changed it: keep the page's edit, and the synced version as a copy.
                    let copy = Self.copy(of: now)
                    try store.upsert(copy)
                    report.keptBoth.append(copy.id)
                    Self.log.info("a Take changed here and elsewhere: both versions kept")
                }
                changed.append(take)
            } catch {
                report.rejected.append(item["id"] as? String ?? "?")
                Self.log.error("a Take did not translate: \(String(describing: error), privacy: .public)")
            }
        }
        // The Obie last: upserting it demotes any other, so the page's choice is the one that stands.
        for take in changed.sorted(by: { !$0.isObie && $1.isObie }) {
            try store.upsert(take)
            base[take.id] = take
            report.upserted += 1
        }
        // Only Takes the page was given and no longer sends are deletions; a rejected Take keeps
        // its stored version, and a Take sync added since the snapshot was never the page's.
        for (id, was) in base where !seen.contains(id) {
            base[id] = nil
            guard let now = stored[id] else { continue }   // already gone
            if now != was {
                report.keptOverDelete.append(id)   // changed elsewhere since: the change wins
                continue
            }
            try store.delete(id: id)
            report.deleted += 1
        }
        // What this save did to the store is now what the page holds, including what the store
        // did on its own (upserting an Obie demotes the old one and moves its timestamp). A Take
        // changed elsewhere since the snapshot keeps its snapshot version, so the next save still
        // sees that change as not the page's.
        // A Take sync deleted keeps its snapshot version too: dropping it would make the page's
        // next save, which still lists it, read as a new Take and bring it back.
        if report.upserted + report.deleted > 0 {
            let after = Dictionary(uniqueKeysWithValues: try store.allTakes().map { ($0.id, $0) })
            let written = Set(changed.map(\.id))
            for (id, was) in base where written.contains(id) || (stored[id] != nil && stored[id] == was) {
                base[id] = after[id]
            }
        }
        snapshots[gen] = base
        return report
    }

    /// The synced version kept beside the page's edit: a new id, and a new notification id for its
    /// reminder so the two never cancel each other (as Core's own fork, `SyncEngine.fork`).
    private static func copy(of take: Take) -> Take {
        let id = UUID()
        var reminder = take.timeReminder
        reminder?.notificationIdentifier = id.uuidString
        return Take(id: id, createdAt: take.createdAt, modifiedAt: take.modifiedAt,
                    blocks: take.blocks, contentType: take.contentType, isNote: take.isNote,
                    isObie: false, timeReminder: reminder,
                    locationReminder: take.locationReminder, attachments: take.attachments,
                    isSeeded: false, isImportant: take.isImportant, manualOrder: take.manualOrder)
    }

    func pageScripts() throws -> [[String: Any]] { try scripts.all() }

    func saveScripts(_ page: [[String: Any]]) throws { try scripts.replaceAll(with: page) }
}
