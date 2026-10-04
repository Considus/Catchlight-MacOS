import Foundation
import CatchlightCore

/// The one place a Take crosses between the page's shape (`ui/takes.js`) and Core's.
///
/// The page models only what it edits. Everything else a Core Take carries (block ids, a
/// reminder's delivery state and notification id, a place reminder's coordinates, attachments,
/// `isSeeded`, the schema version) is kept by laying the page's edit over the stored Take rather
/// than rebuilding one from the page. Both directions go through Core's own JSON coder, so a
/// field Core sets only while decoding (`TimeReminder.anchorDay`) round-trips too.
///
/// Page Take: `{id, at, modifiedAt?, blocks:[{k:'text'|'check', text, done?}], isNote,
/// isImportant?, obie?, manualOrder?, reminder?}`, where `reminder` is
/// `{kind:'time', when, done, allDay, notify, repeat, weekdays, anchorDay?}` or
/// `{kind:'place', name, mode:'arrive'|'leave', radius, notify, done, lat, lon}`.
/// `at` is an ISO string, `modifiedAt` epoch milliseconds, `manualOrder` epoch seconds (as Core).
enum TakeTranslation {
    enum Failure: Error, Equatable {
        case notAnObject
        case badID(String)
        case badDate(String)
        case badReminder(String)
    }

    // MARK: Core → page

    static func page(from take: Take) throws -> [String: Any] {
        var out: [String: Any] = [
            "id": take.id.uuidString.lowercased(),
            "at": ISO8601.string(from: take.createdAt),
            "modifiedAt": (take.modifiedAt.timeIntervalSince1970 * 1000).rounded(),
            "isNote": take.isNote,
            "isImportant": take.isImportant,
            "obie": take.isObie,
            "blocks": take.blocks.map { block -> [String: Any] in
                switch block {
                case .text(let b): return ["k": "text", "text": b.text]
                case .check(let c): return ["k": "check", "text": c.text, "done": c.isComplete]
                }
            },
        ]
        if let order = take.manualOrder { out["manualOrder"] = order }
        if let r = take.timeReminder {
            var reminder: [String: Any] = [
                "kind": "time", "when": ISO8601.string(from: r.scheduledDate), "done": r.isDone,
                "allDay": r.isAllDay, "notify": r.alarmEnabled, "repeat": r.recurrence.rawValue,
                "weekdays": r.weekdays.sorted(),
            ]
            if let day = r.anchorDay { reminder["anchorDay"] = day }
            out["reminder"] = reminder
        } else if let p = take.locationReminder {
            var reminder: [String: Any] = [
                "kind": "place", "mode": p.triggerOnArrival ? "arrive" : "leave",
                "radius": p.radiusMetres, "notify": p.alarmEnabled, "done": p.isDone,
                "lat": p.latitude, "lon": p.longitude,
            ]
            if let name = p.locationName { reminder["name"] = name }
            out["reminder"] = reminder
        }
        return out
    }

    // MARK: page → Core

    /// The page's Take laid over `existing` (the stored version, if any). `now` stamps
    /// `modifiedAt` when the content changed and the page did not move it on itself, because
    /// sync settles conflicts by `modifiedAt` and an edit that keeps the old stamp would lose.
    static func core(from page: [String: Any], existing: Take?, now: Date = Date()) throws -> Take {
        guard let idString = page["id"] as? String else { throw Failure.badID("missing") }
        guard let id = UUID(uuidString: idString) else { throw Failure.badID(idString) }
        if let existing, existing.id != id { throw Failure.badID("\(idString) laid over \(existing.id)") }

        // Start from the stored Take's own JSON, so every field the page doesn't model survives.
        var json: [String: Any]
        if let existing {
            json = try object(PlatformJSON.encode(existing))
        } else {
            json = ["schemaVersion": Take.currentSchemaVersion, "contentType": "blocks/v2",
                    "attachments": [Any](), "isSeeded": false]
        }
        json["id"] = id.uuidString

        guard let atString = page["at"] as? String, let created = parseDate(atString) else {
            throw Failure.badDate("at: \(String(describing: page["at"]))")
        }
        json["createdAt"] = ISO8601.string(from: created)
        json["isNote"] = page["isNote"] as? Bool ?? false
        json["isObie"] = page["obie"] as? Bool ?? false
        json["isImportant"] = (page["isImportant"] as? Bool ?? false) || (page["obie"] as? Bool ?? false)
        if let order = page["manualOrder"] as? Double { json["manualOrder"] = order } else { json.removeValue(forKey: "manualOrder") }
        json["blocks"] = blocks(from: page["blocks"], reusingIDsFrom: existing?.blocks ?? [])
        try applyReminder(page["reminder"], to: &json, takeID: id)

        // modifiedAt: the page's stamp when it has one; otherwise the stored one. Decided after
        // the content comparison below.
        let pageModified = (page["modifiedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        json["modifiedAt"] = ISO8601.string(from: pageModified ?? existing?.modifiedAt ?? created)

        var take = try PlatformJSON.decode(Take.self, from: JSONSerialization.data(withJSONObject: json))
        if let existing, take != existing, take.modifiedAt <= existing.modifiedAt {
            take.modifiedAt = max(now, existing.modifiedAt.addingTimeInterval(0.001))
        }
        return take
    }

    // MARK: Pieces

    /// Page blocks to Core's JSON, reusing a stored block's id where the block is still there.
    /// The page has no block ids (its editor rebuilds blocks from the screen), and Core uses them
    /// only for on-screen identity, so a match is: the same kind and text first, then the same
    /// kind at the same position. A new block gets a new id.
    static func blocks(from value: Any?, reusingIDsFrom stored: [TakeBlock]) -> [[String: Any]] {
        let page = (value as? [[String: Any]]) ?? []
        var free = stored
        func take(where match: (TakeBlock) -> Bool) -> UUID? {
            guard let i = free.firstIndex(where: match) else { return nil }
            return free.remove(at: i).id
        }
        // Pass 1: exact matches, so an unchanged block keeps its id wherever it moved.
        var ids: [UUID?] = page.map { b in
            let text = b["text"] as? String ?? ""
            return (b["k"] as? String) == "check"
                ? take { if case .check(let c) = $0 { return c.text == text } else { return false } }
                : take { if case .text(let t) = $0 { return t.text == text } else { return false } }
        }
        // Pass 2: an edited block keeps the id of the stored block of the same kind at its place.
        for (i, b) in page.enumerated() where ids[i] == nil {
            let isCheck = (b["k"] as? String) == "check"
            if i < stored.count, let j = free.firstIndex(where: { $0.id == stored[i].id }) {
                let candidate = free[j]
                if case .check = candidate, isCheck { ids[i] = free.remove(at: j).id }
                else if case .text = candidate, !isCheck { ids[i] = free.remove(at: j).id }
            }
        }
        return page.enumerated().map { i, b in
            let id = (ids[i] ?? UUID()).uuidString
            let text = b["text"] as? String ?? ""
            return (b["k"] as? String) == "check"
                ? ["kind": "check", "id": id, "text": text, "isComplete": b["done"] as? Bool ?? false]
                : ["kind": "text", "id": id, "text": text]
        }
    }

    private static func applyReminder(_ value: Any?, to json: inout [String: Any], takeID: UUID) throws {
        guard let r = value as? [String: Any] else {
            json.removeValue(forKey: "timeReminder")
            json.removeValue(forKey: "locationReminder")
            return
        }
        let kind = r["kind"] as? String ?? "time"   // the prototype's legacy {when, done} is a time reminder
        switch kind {
        case "time":
            guard let whenString = r["when"] as? String, let when = parseDate(whenString) else {
                throw Failure.badReminder("time reminder without a valid when")
            }
            var t = (json["timeReminder"] as? [String: Any]) ?? [:]
            let moved = (t["scheduledDate"] as? String).flatMap(parseDate) != ISO8601.truncateToMilliseconds(when)
            t["scheduledDate"] = ISO8601.string(from: when)
            t["notificationIdentifier"] = t["notificationIdentifier"] ?? takeID.uuidString
            if moved { t["isDelivered"] = false }
            t["isDone"] = r["done"] as? Bool ?? false
            t["isAllDay"] = r["allDay"] as? Bool ?? false
            t["alarmEnabled"] = r["notify"] as? Bool ?? true
            t["recurrence"] = r["repeat"] as? String ?? "none"
            t["weekdays"] = (r["weekdays"] as? [Int]) ?? []
            if let day = r["anchorDay"] as? Int { t["anchorDay"] = day } else { t.removeValue(forKey: "anchorDay") }
            json["timeReminder"] = t
            json.removeValue(forKey: "locationReminder")
        case "place":
            // The Mac can't make a place reminder (no coordinates), only carry one made on the
            // iPhone. Without stored coordinates there is nothing Core can hold.
            guard var p = json["locationReminder"] as? [String: Any] else {
                throw Failure.badReminder("place reminder with no stored coordinates")
            }
            // Coordinates stay as the iPhone set them; what the picker shows can be edited.
            p["isDone"] = r["done"] as? Bool ?? false
            p["alarmEnabled"] = r["notify"] as? Bool ?? true
            if let name = r["name"] as? String {
                if name.isEmpty { p.removeValue(forKey: "locationName") } else { p["locationName"] = name }
            }
            if let mode = r["mode"] as? String { p["triggerOnArrival"] = mode != "leave" }
            if let radius = r["radius"] as? Double { p["radiusMetres"] = radius }
            json["locationReminder"] = p
            json.removeValue(forKey: "timeReminder")
        default:
            throw Failure.badReminder("unknown kind \(kind)")
        }
    }

    static func parseDate(_ string: String) -> Date? {
        if let d = ISO8601.date(from: string) { return ISO8601.truncateToMilliseconds(d) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string).map(ISO8601.truncateToMilliseconds)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notAnObject }
        return o
    }
}
