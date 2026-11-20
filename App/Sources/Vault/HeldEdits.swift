import Foundation
import CatchlightCore

/// Edits whose save failed as the app locked, kept across the lock (owner, 2026-11-20: "Hold it,
/// give it back", ISSUE-292). Each changed Take or Script is sealed by Core's `TakeCrypto` under
/// its own item key, as the store seals it, and held in memory only: nothing is written to disk,
/// and nothing is readable once the lock drops the master key. The unlock opens them and hands
/// them back to the page, which saves them again; then they are wiped. Quitting wipes them too.
struct HeldEdits {
    private struct Sealed { let id: UUID; var data: Data }
    private var sealed: [Sealed] = []

    /// Refused edits that couldn't be held or opened again. The unlock says a save failed rather
    /// than let them vanish without a word.
    private(set) var lost = 0

    var isEmpty: Bool { sealed.isEmpty && lost == 0 }
    var count: Int { sealed.count }
    /// The sealed bytes, for the tests that check nothing readable is held.
    var sealedData: [Data] { sealed.map(\.data) }

    /// Every item in the page's refused lists that differs from what the store holds, sealed.
    /// A deletion that failed is not typing, so it isn't held: the item is still in the store.
    static func seal(takes: [[String: Any]]?, scripts: [[String: Any]]?, library: Library, keys: KeyHierarchy,
                     now: Date = Date()) -> HeldEdits {
        let crypto = TakeCrypto(keys: keys)
        var held = HeldEdits()
        for (list, page) in [(Library.PageList.takes, takes), (.scripts, scripts)] {
            for item in page ?? [] {
                let id = (item["id"] as? String).flatMap(UUID.init(uuidString:))
                let stored = id.flatMap { try? library.store.take(id: $0) }
                if let stored, !list.holds(stored) { continue }   // the other kind's id: never written over
                do {
                    let take = try list.core(from: item, existing: stored, now: now)
                    if take == stored { continue }
                    held.sealed.append(Sealed(id: take.id, data: try crypto.seal(take)))
                } catch {
                    held.lost += 1
                }
            }
        }
        return held
    }

    /// The held items as the page shows them, Takes and Scripts apart, and how many were lost:
    /// any that won't open are counted rather than shown wrong, with those never held.
    func open(keys: KeyHierarchy) -> (takes: [[String: Any]], scripts: [[String: Any]], lost: Int) {
        let crypto = TakeCrypto(keys: keys)
        var takes: [[String: Any]] = [], scripts: [[String: Any]] = [], failed = lost
        for item in sealed {
            do {
                let take = try crypto.open(item.data, takeUUID: item.id)
                if take.isScript { scripts.append(ScriptTranslation.page(from: take)) }
                else { takes.append(try TakeTranslation.page(from: take)) }
            } catch {
                failed += 1
            }
        }
        return (takes, scripts, failed)
    }

    /// Zeroes the sealed bytes, then lets them go.
    mutating func wipe() {
        for index in sealed.indices {
            sealed[index].data.resetBytes(in: 0..<sealed[index].data.count)
        }
        sealed = []
        lost = 0
    }
}
