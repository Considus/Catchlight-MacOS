import Foundation
import CatchlightCore

/// Edits whose save failed as the app locked, kept across the lock (owner, 2026-11-20: "Hold it,
/// give it back", ISSUE-292). Each changed Take or Script is sealed by Core's `TakeCrypto` under
/// its own item key, as the store seals it, and held in memory only: nothing is written to disk,
/// and nothing is readable once the lock drops the master key. With it is sealed the version the
/// page last read (its base), so the save after the unlock tells a change sync made since from
/// one typed here, as any save does. The unlock opens them and hands them back to the page,
/// which saves them again; each list's are wiped once a save of it succeeds, not before, so a page
/// that ends before saving gets them again. Quitting wipes them all.
struct HeldEdits {
    private struct Sealed {
        let id: UUID
        let script: Bool
        var data: Data
        /// The page's base, sealed; nil for an item new since the page read the library.
        var base: Data?
    }
    private var sealed: [Sealed] = []

    /// Refused edits that couldn't be held or opened again. The unlock says a save failed rather
    /// than let them vanish without a word.
    private(set) var lost = 0

    var isEmpty: Bool { sealed.isEmpty && lost == 0 }
    var count: Int { sealed.count }
    /// The sealed bytes, for the tests that check nothing readable is held.
    var sealedData: [Data] { sealed.flatMap { [$0.data] + ($0.base.map { [$0] } ?? []) } }

    /// Every item in the page's refused lists that differs from the version the page read
    /// (`generation`, its snapshot), sealed with that version. An item the page didn't change is
    /// not held, so sync's newer text for it stands. With no snapshot to compare, the store is
    /// the base. A deletion that failed is not typing, so it isn't held: the item is still stored.
    static func seal(takes: [[String: Any]]?, takesGeneration: Int? = nil, scripts: [[String: Any]]?,
                     scriptsGeneration: Int? = nil, library: Library, keys: KeyHierarchy, now: Date = Date()) -> HeldEdits {
        let crypto = TakeCrypto(keys: keys)
        var held = HeldEdits()
        for (list, page, generation) in [(Library.PageList.takes, takes, takesGeneration), (.scripts, scripts, scriptsGeneration)] {
            let snapshot = generation.flatMap(library.snapshotBase(generation:))
            for item in page ?? [] {
                let id = (item["id"] as? String).flatMap(UUID.init(uuidString:))
                let stored = id.flatMap { try? library.store.take(id: $0) }
                if let stored, !list.holds(stored) { continue }   // the other kind's id: never written over
                let base = snapshot.map { snapshot in id.flatMap { snapshot[$0] } } ?? stored
                do {
                    let take = try list.core(from: item, existing: base, now: now)
                    if take == base { continue }
                    held.sealed.append(Sealed(id: take.id, script: list == .scripts, data: try crypto.seal(take),
                                              base: try base.map(crypto.seal)))
                } catch {
                    held.lost += 1
                }
            }
        }
        return held
    }

    /// The held items as the page shows them, Takes and Scripts apart, with the base each is
    /// saved against, and how many were lost: any that won't open are counted rather than shown
    /// wrong, with those never held. One the store already holds as typed was saved before the
    /// page ended: it is listed in `saved`, not given back.
    func open(keys: KeyHierarchy, library: Library) -> (takes: [[String: Any]], scripts: [[String: Any]],
                                                        bases: [UUID: Take?], saved: [UUID], lost: Int) {
        let crypto = TakeCrypto(keys: keys)
        var takes: [[String: Any]] = [], scripts: [[String: Any]] = [], bases: [UUID: Take?] = [:], saved: [UUID] = []
        var failed = lost
        for item in sealed {
            do {
                let take = try crypto.open(item.data, takeUUID: item.id)
                if try library.store.take(id: item.id) == take { saved.append(item.id); continue }
                let base = try item.base.map { try crypto.open($0, takeUUID: item.id) }
                bases[item.id] = .some(base)
                if take.isScript { scripts.append(ScriptTranslation.page(from: take)) }
                else { takes.append(try TakeTranslation.page(from: take)) }
            } catch {
                failed += 1
            }
        }
        return (takes, scripts, bases, saved, failed)
    }

    /// Adds what a later lock held, each replacing any held before with the same id, which is wiped.
    mutating func merge(_ newer: HeldEdits) {
        let ids = Set(newer.sealed.map(\.id))
        wipe { ids.contains($0.id) }
        sealed += newer.sealed
        lost += newer.lost
    }

    /// Wipes the held items of one list, once a save of it has succeeded.
    mutating func saved(scripts: Bool) { wipe { $0.script == scripts } }

    /// Wipes the items the store already holds as typed.
    mutating func forget(_ ids: [UUID]) { let ids = Set(ids); wipe { ids.contains($0.id) } }

    /// The lost count has been reported.
    mutating func lossReported() { lost = 0 }

    /// Zeroes the sealed bytes, then lets them go.
    mutating func wipe() {
        wipe { _ in true }
        lost = 0
    }

    private mutating func wipe(where matches: (Sealed) -> Bool) {
        for index in sealed.indices where matches(sealed[index]) {
            sealed[index].data.resetBytes(in: 0..<sealed[index].data.count)
            if let count = sealed[index].base?.count { sealed[index].base?.resetBytes(in: 0..<count) }
        }
        sealed.removeAll(where: matches)
    }
}
