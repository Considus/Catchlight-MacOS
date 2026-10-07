import Foundation
import CatchlightCore
import os

/// The open library: Takes and Scripts in Core's `TakeStore`, a Script being a Take of kind Script
/// (D-265, D-326, M3b). Scripts saved before M3b sit in the `ScriptVault` until `moveScriptsIn`
/// moves them over. The page saves its whole Take list at once (`saveTakes()` in `ui/takes.js`),
/// and its whole Script list the same way, so a save is a diff, and it is a diff
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
        /// Takes the page changed that sync had changed too since the page's snapshot: the page's
        /// version is written, and each pair goes to the conflict screen, where the user keeps
        /// this Mac's version, the synced one, or both (owner, 2026-10-05).
        var conflicts: [(local: Take, remote: Take)] = []
        /// Takes the page deleted that sync had changed since: the change wins and the Take stays.
        var keptOverDelete: [UUID] = []
        /// Items the page changed or deleted while they wait for a conflict choice: refused, and
        /// the stored version stands (owner, 2026-10-07: "The file shouldn't update or edit until
        /// the conflict is resolved"). A new Obie is refused too while the current one waits,
        /// because writing it would demote the waiting one.
        var held: [String] = []

        static func == (a: SaveReport, b: SaveReport) -> Bool {
            a.upserted == b.upserted && a.deleted == b.deleted && a.unchanged == b.unchanged
                && a.rejected == b.rejected && a.keptOverDelete == b.keptOverDelete && a.held == b.held
                && a.conflicts.map(\.local) == b.conflicts.map(\.local)
                && a.conflicts.map(\.remote) == b.conflicts.map(\.remote)
        }
    }

    enum Failure: Error, LocalizedError, Equatable {
        /// The page's list came from a snapshot too old to diff against. Nothing is written.
        case staleSnapshot(Int)
        /// The item is waiting for a conflict choice, and nothing changes it until then.
        case held(UUID)
        var errorDescription: String? {
            switch self {
            case .staleSnapshot: return "the page's copy of your Takes is out of date"
            case .held: return "it changed on another device too, and is waiting for you to choose a version"
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

    /// The page's two lists. Each holds one kind; an item of a kind the page doesn't know (a newer
    /// client's) is in neither and never touched.
    enum PageList {
        case takes, scripts
        func holds(_ take: Take) -> Bool { self == .takes ? take.kind == nil : take.isScript }
        func core(from page: [String: Any], existing: Take?, now: Date) throws -> Take {
            self == .takes ? try TakeTranslation.core(from: page, existing: existing, now: now)
                : try ScriptTranslation.core(from: page, existing: existing, now: now)
        }
    }

    init(store: TakeStore, scripts: ScriptVault) {
        self.store = store
        self.scripts = scripts
    }

    /// Every Take and Script in the page's shape, oldest first (as the store returns them), as a
    /// new snapshot.
    func snapshot() throws -> (generation: Int, takes: [[String: Any]], scripts: [[String: Any]]) {
        let all = try store.allTakes()
        let takes = try all.filter(PageList.takes.holds).map(TakeTranslation.page(from:))
        let scripts = all.filter(PageList.scripts.holds).map(ScriptTranslation.page(from:))
        Self.lastGeneration += 1
        generation = Self.lastGeneration
        snapshots[generation] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        if snapshots.count > Self.snapshotsKept, let oldest = snapshots.keys.min() { snapshots[oldest] = nil }
        return (generation, takes, scripts)
    }

    func pageTakes() throws -> [[String: Any]] { try snapshot().takes }
    func pageScripts() throws -> [[String: Any]] { try snapshot().scripts }

    func saveTakes(_ page: [[String: Any]], generation: Int? = nil, now: Date = Date(), holding held: Set<UUID> = [],
                   keepConflict: ((local: Take, remote: Take)) throws -> Void = { _ in }) throws -> SaveReport {
        try save(page, as: .takes, generation: generation, now: now, holding: held, keepConflict: keepConflict)
    }

    func saveScripts(_ page: [[String: Any]], generation: Int? = nil, now: Date = Date(), syncing: Bool = true, holding held: Set<UUID> = [],
                     keepConflict: ((local: Take, remote: Take)) throws -> Void = { _ in }) throws -> SaveReport {
        try save(page, as: .scripts, generation: generation, now: now, syncing: syncing, holding: held, keepConflict: keepConflict)
    }

    /// - Parameter generation: the snapshot the page's list came from; nil means the newest.
    /// - Parameter keepConflict: called for a Take changed here and by sync, BEFORE anything is
    ///   written, so the other version is kept (on disk, by the conflict queue) before this Mac's
    ///   edit replaces it in the store. If it throws, the save writes nothing and fails.
    /// - Parameter syncing: false when this list's deletions must stay on this Mac: Scripts while
    ///   they don't sync. A deletion record carries no kind, so one sent for a Script made from a
    ///   synced Take would delete that Take on every other device (Greptile on Catchlight-Core#22).
    /// - Parameter held: the items waiting for a conflict choice (`ConflictQueue`, skipped ones
    ///   included). A change to one, or its deletion, is refused and reported in `held`; the page
    ///   refuses them first, so this is the backstop for a save already on its way when the
    ///   conflict was found. Resolving the conflict (`ConflictQueue.resolve`) is the only write.
    func save(_ page: [[String: Any]], as list: PageList, generation: Int? = nil, now: Date = Date(), syncing: Bool = true,
              holding held: Set<UUID> = [],
              keepConflict: ((local: Take, remote: Take)) throws -> Void = { _ in }) throws -> SaveReport {
        let gen = generation ?? self.generation
        // A Takes save reads the whole store, because upserting an Obie changes another Take. A
        // Scripts save comes 250 ms after every pause in typing, so it reads only the items it
        // names, one at a time (code review: decrypting every Take on each pause stalls typing).
        let all: [UUID: Take]? = list == .takes || (snapshots[gen] == nil && gen == 0)
            ? Dictionary(uniqueKeysWithValues: try store.allTakes().map { ($0.id, $0) }) : nil
        var fetched: [UUID: Take?] = [:]
        func stored(_ id: UUID) throws -> Take? {
            if let all { return all[id] }
            if let hit = fetched[id] { return hit }
            let take = try store.take(id: id)
            fetched[id] = .some(take)
            return take
        }
        var base: [UUID: Take]
        if let known = snapshots[gen] { base = known }
        else if gen == 0, let all { base = all }   // no snapshot yet: the store is what the page was given
        else { throw Failure.staleSnapshot(gen) }

        var report = SaveReport()
        var seen = Set<UUID>()
        var changed: [Take] = []
        for item in page {
            let id = (item["id"] as? String).flatMap(UUID.init(uuidString:))
            if let id { seen.insert(id) }
            // An id the store holds as the other kind is never written over from this list: the
            // page would be turning a Script into a Take, or back, by copying over it.
            if let id, let held = try stored(id) ?? base[id], !list.holds(held) {
                report.rejected.append(item["id"] as? String ?? "?")
                Self.log.error("a save named an item of the other kind; it is left as it is")
                continue
            }
            let was = id.flatMap { base[$0] }
            let take: Take
            do { take = try list.core(from: item, existing: was, now: now) } catch {
                report.rejected.append(item["id"] as? String ?? "?")
                Self.log.error("a Take did not translate: \(String(describing: error), privacy: .public)")
                continue
            }
            if was != nil, take == was { report.unchanged += 1; continue }
            if held.contains(take.id) {
                report.held.append(item["id"] as? String ?? "?")
                Self.log.info("a save changed an item waiting for a conflict choice; it is left as it is")
                continue
            }
            // Writing an Obie demotes the current one; while that one waits for a conflict choice
            // it can't change, so the new Obie is refused rather than written as something else.
            if take.isObie, !held.isEmpty, let obie = try all.map({ $0.values.first(where: \.isObie) }) ?? store.currentObie(),
               obie.id != take.id, held.contains(obie.id) {
                report.held.append(item["id"] as? String ?? "?")
                Self.log.info("a save made a new Obie while the Obie waits for a conflict choice; it is left as it is")
                continue
            }
            if let now = try stored(take.id), let was, now != was, now != take {
                // Both changed it: the page's edit is written, and the user chooses on the
                // conflict screen, as for a conflict sync finds.
                report.conflicts.append((local: take, remote: now))
                Self.log.info("a Take changed here and elsewhere: sent to the conflict screen")
            }
            changed.append(take)
        }
        // Each conflict is kept before anything is written: the write replaces the other version.
        for pair in report.conflicts { try keepConflict(pair) }
        // The Obie last: upserting it demotes any other, so the page's choice is the one that stands.
        for take in changed.sorted(by: { !$0.isObie && $1.isObie }) {
            try store.upsert(take)
            base[take.id] = take
            report.upserted += 1
        }
        // Only Takes the page was given and no longer sends are deletions; a rejected Take keeps
        // its stored version, and a Take sync added since the snapshot was never the page's.
        for (id, was) in base where list.holds(was) && !seen.contains(id) {
            if held.contains(id) {
                // Kept in the snapshot too: the page's next save, which may still lack it, is refused again.
                report.held.append(id.uuidString.lowercased())
                continue
            }
            base[id] = nil
            guard let now = try stored(id) else { continue }   // already gone
            if now != was {
                report.keptOverDelete.append(id)   // changed elsewhere since: the change wins
                continue
            }
            try store.delete(id: id)
            if !syncing { try store.purgeTombstones(ids: [id]) }
            report.deleted += 1
        }
        // What this save did to the store is now what the page holds, including what the store
        // did on its own (upserting an Obie demotes the old one and moves its timestamp). A Take
        // changed elsewhere since the snapshot keeps its snapshot version, so the next save still
        // sees that change as not the page's.
        // A Take sync deleted keeps its snapshot version too: dropping it would make the page's
        // next save, which still lists it, read as a new Take and bring it back.
        let written = Set(changed.map(\.id))
        if list == .takes, report.upserted + report.deleted > 0, let before = all {
            let after = Dictionary(uniqueKeysWithValues: try store.allTakes().map { ($0.id, $0) })
            for (id, was) in base where written.contains(id) || (before[id] != nil && before[id] == was) {
                base[id] = after[id]
            }
        } else {
            for id in written { base[id] = try store.take(id: id) }
        }
        snapshots[gen] = base
        return report
    }

    /// Imported notes (`NoteImport`), written as they are: Takes, or Scripts from a Catchlight
    /// export. The page sees them on its next refresh; its older snapshot doesn't hold them, so a
    /// save from it leaves them alone. One that can't be written is counted and the rest go on,
    /// as the iPhone's `importTakes`.
    /// An imported Obie comes in as a standard Take while the current Obie waits for a conflict
    /// choice (`held`), since writing it would demote the waiting one.
    func importItems(_ items: [Take], holding held: Set<UUID> = []) -> (takes: Int, scripts: Int, failed: Int) {
        var takes = 0, scripts = 0, failed = 0
        let obieHeld = !held.isEmpty && ((try? store.currentObie())??.id).map(held.contains) == true
        for var item in items {
            item.normaliseActivityFloor()
            if obieHeld { item.isObie = false }
            do { try store.upsert(item) } catch { failed += 1; continue }
            if item.isScript { scripts += 1 } else { takes += 1 }
        }
        return (takes, scripts, failed)
    }

    /// Take ⇄ Script as a change of kind on the same id (D-313): no copy and no deletion record,
    /// so sync sends one item whose kind changed. `page` is the item in its new list's shape. It is
    /// laid over the stored item, so what the page doesn't model (block ids, a reminder) is kept;
    /// a Script is never the Obie. Every kept snapshot takes the new version, so the old list's
    /// next save doesn't read it as deleted, nor the new list's as new.
    /// - Parameter generation: the snapshot the page's copy came from (nil: the newest). If sync
    ///   changed the item since, that version goes to `keepConflict` before anything is written,
    ///   as a save's does, so the change of kind never replaces it unseen.
    /// - Parameter held: the items waiting for a conflict choice; changing one's kind throws `held`.
    @discardableResult
    func changeKind(_ page: [String: Any], to list: PageList, generation: Int? = nil, now: Date = Date(),
                    holding held: Set<UUID> = [],
                    keepConflict: ((local: Take, remote: Take)) throws -> Void = { _ in }) throws -> Take {
        guard let idString = page["id"] as? String, let id = UUID(uuidString: idString) else {
            throw TakeTranslation.Failure.badID(String(describing: page["id"]))
        }
        if held.contains(id) { throw Failure.held(id) }
        let gen = generation ?? self.generation
        guard gen == 0 || snapshots[gen] != nil else { throw Failure.staleSnapshot(gen) }
        let stored = try store.take(id: id)
        let was = snapshots[gen]?[id]
        var base = stored
        base?.kind = list == .scripts ? ManifestEntry.Kind.script : nil
        if list == .scripts { base?.isObie = false }
        // A Take from a Script carries only its text (`takeFromScript`), and a Take's translation
        // reads a missing reminder or flag as removed. What the page didn't send comes from the
        // stored item instead: its reminder, Important, its place in a manual order (Greptile on #56).
        var incoming = page
        if list == .takes, let base {
            incoming = try TakeTranslation.page(from: base)
            incoming["id"] = page["id"]
            incoming["blocks"] = page["blocks"]
            if let at = page["at"] { incoming["at"] = at }
            if let note = page["isNote"] { incoming["isNote"] = note }
            incoming.removeValue(forKey: "modifiedAt")
        }
        var item = try list.core(from: incoming, existing: base, now: now)
        // A change of kind is an edit: it must be the newest version everywhere.
        item.modifiedAt = max(ISO8601.truncateToMilliseconds(now), (stored?.modifiedAt ?? .distantPast).addingTimeInterval(0.001))
        if let stored, let was, stored != was { try keepConflict((local: item, remote: stored)) }
        try store.upsert(item)
        for g in snapshots.keys { snapshots[g]?[id] = item }
        Self.log.info("an item changed kind")
        return item
    }

    /// Scripts saved before M3b, one sealed file each, move into the store with the same id. A
    /// file goes only once the store holds its Script and it reads back the same; a file that
    /// won't open, or whose id the store already holds as something else, stays where it is.
    /// Returns how many moved.
    @discardableResult
    func moveScriptsIn(now: Date = Date()) -> Int {
        let files: [[String: Any]]
        do { files = try scripts.all() } catch {
            Self.log.error("the Scripts folder could not be read: \(String(describing: error), privacy: .public)")
            return 0
        }
        var moved = 0
        for page in files {
            guard let id = (page["id"] as? String).flatMap(UUID.init(uuidString:)) else { continue }
            do {
                let script: Take
                if let held = try store.take(id: id) {
                    guard held.isScript else {
                        Self.log.error("a Script's id is already a Take; its file is kept")
                        continue
                    }
                    script = held   // moved before, and the file not removed: it goes now
                } else {
                    script = try ScriptTranslation.core(from: page, existing: nil, now: now)
                    try store.upsert(script)
                }
                guard try store.take(id: id) == script else {
                    Self.log.error("a Script did not read back as written; its file is kept")
                    continue
                }
                try scripts.remove(id)
                moved += 1
            } catch {
                Self.log.error("a Script did not move into the library and its file is kept: \(String(describing: error), privacy: .public)")
            }
        }
        if moved > 0 { Self.log.info("\(moved) Scripts moved into the library") }
        return moved
    }
}
