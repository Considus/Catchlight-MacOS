import Foundation
import CatchlightCore

/// The one place a Script crosses between the page's shape (`ui/app.js`) and Core's. A Script is
/// a Take of kind Script (D-265, D-326), so it lives in the same store and syncs through the same
/// engine; this file only says how the page's lines map onto Core's blocks.
///
/// Page Script: `{id, at, mode: 'continuous'|'a4'|'letter', blocks: [String]}`. Each page block is
/// one line of markdown, or a fenced code block or table kept whole. In Core, a `- [ ] text` or
/// `- [x] text` line is a checklist item (Desktop_App_Scope §6b); every other page block is one
/// text block, its markdown kept as typed. `at` is an ISO string, as a Take's; a Script saved
/// before M3b carries a date only, read as that day's local midnight. The page's `pageCount` is
/// worked out on screen and never stored.
///
/// As for a Take, the page's edit is laid over the stored item through Core's own JSON coder, so
/// what the page doesn't model (block ids, a reminder kept from when it was a Take) survives.
enum ScriptTranslation {
    enum Failure: Error, Equatable {
        case badID(String)
        case badDate(String)
    }

    /// `- [ ] text`, `- [x] text` (or `*`, or `X`), as the page reads a checklist line.
    private static let check = try! NSRegularExpression(pattern: #"^[-*] \[( |x|X)\] (.*)$"#)

    // MARK: Core → page

    static func page(from take: Take) -> [String: Any] {
        [
            "id": take.id.uuidString.lowercased(),
            "at": ISO8601.string(from: take.createdAt),
            "mode": take.pageMode ?? Take.PageMode.continuous,
            "blocks": take.blocks.map { block -> String in
                switch block {
                case .text(let b): return b.text
                case .check(let c): return "- [\(c.isComplete ? "x" : " ")] \(c.text)"
                }
            },
        ]
    }

    // MARK: page → Core

    static func core(from page: [String: Any], existing: Take?, now: Date = Date()) throws -> Take {
        guard let idString = page["id"] as? String else { throw Failure.badID("missing") }
        guard let id = UUID(uuidString: idString) else { throw Failure.badID(idString) }
        if let existing, existing.id != id { throw Failure.badID("\(idString) laid over \(existing.id)") }

        var json: [String: Any]
        if let existing {
            json = (try JSONSerialization.jsonObject(with: PlatformJSON.encode(existing)) as? [String: Any]) ?? [:]
        } else {
            json = ["schemaVersion": Take.currentSchemaVersion, "contentType": "blocks/v2",
                    "attachments": [Any](), "isSeeded": false, "isNote": false, "isObie": false, "isImportant": false]
        }
        json["id"] = id.uuidString
        json["kind"] = ManifestEntry.Kind.script

        let atString = page["at"] as? String ?? ""
        let created: Date
        if let full = TakeTranslation.parseDate(atString) { created = full }
        else if let day = localDay(atString) {
            // A date-only `at` names a day, not a moment: the stored moment stands if it is that day.
            if let existing, localDayString(existing.createdAt) == atString { created = existing.createdAt } else { created = day }
        } else { throw Failure.badDate("at: \(atString)") }
        json["createdAt"] = ISO8601.string(from: created)

        let mode = page["mode"] as? String
        if let mode, mode != Take.PageMode.continuous { json["pageMode"] = mode } else { json.removeValue(forKey: "pageMode") }

        let lines = (page["blocks"] as? [Any])?.map { $0 as? String ?? "" } ?? []
        let pageBlocks = lines.map { line -> [String: Any] in
            let range = NSRange(line.startIndex..., in: line)
            if let m = check.firstMatch(in: line, range: range),
               let mark = Range(m.range(at: 1), in: line), let text = Range(m.range(at: 2), in: line) {
                return ["k": "check", "text": String(line[text]), "done": line[mark] != " "]
            }
            return ["k": "text", "text": line]
        }
        json["blocks"] = TakeTranslation.blocks(from: pageBlocks, reusingIDsFrom: existing?.blocks ?? [])
        json["modifiedAt"] = ISO8601.string(from: existing?.modifiedAt ?? now)

        var take = try PlatformJSON.decode(Take.self, from: JSONSerialization.data(withJSONObject: json))
        // The page doesn't stamp a Script's edits: a content change gets a new modifiedAt here,
        // because sync settles conflicts by it.
        if let existing, take != existing, take.modifiedAt <= existing.modifiedAt {
            take.modifiedAt = max(ISO8601.truncateToMilliseconds(now), existing.modifiedAt.addingTimeInterval(0.001))
        }
        return take
    }

    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private static func localDay(_ string: String) -> Date? {
        string.count == 10 ? dayFormatter().date(from: string) : nil
    }

    private static func localDayString(_ date: Date) -> String { dayFormatter().string(from: date) }
}
