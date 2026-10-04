import Foundation
import CryptoKit
import CatchlightCore
import os

/// Scripts on this Mac, one sealed file each in `Scripts/`.
///
/// Core has no Script model yet: it knows a Script only as a manifest entry kind the iPhone
/// skips (D-315). Until M3 settles how a Script travels in the cloud folder, the Mac keeps the
/// page's own Script JSON, sealed with AES-256-GCM under the per-item key Core derives for the
/// Script's id, so a Script is never on disk as plain-text. The additional data names the format,
/// so a Script file can never be opened as a Take or the other way round.
final class ScriptVault {
    enum Failure: Error, Equatable {
        case badID(String)
        case notAnObject
    }

    static let format = Data("catchlight.mac.script.v1".utf8)

    private let keys: KeyHierarchy
    let directory: URL
    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "scripts")
    /// Files that would not open. They are kept, never overwritten by a save that doesn't name
    /// their id and never deleted, so one damaged file costs that Script and nothing else.
    private(set) var unreadable: Set<String> = []

    init(keys: KeyHierarchy, directory: URL) throws {
        self.keys = keys
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func all() throws -> [[String: Any]] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sealed" }
        return files.compactMap { url -> [String: Any]? in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            do { return try open(Data(contentsOf: url), id: id) } catch {
                unreadable.insert(url.lastPathComponent)
                Self.log.error("a Script did not open and is kept as it is: \(url.lastPathComponent, privacy: .public)")
                return nil
            }
        }
        .sorted { ($0["at"] as? String ?? "") < ($1["at"] as? String ?? "") }
    }

    /// Replace the stored set with `scripts`: write each one that changed, remove the rest.
    func replaceAll(with scripts: [[String: Any]]) throws {
        var keep = Set<String>()
        for script in scripts {
            guard let idString = script["id"] as? String, let id = UUID(uuidString: idString) else {
                throw Failure.badID(String(describing: script["id"]))
            }
            let url = fileURL(id)
            keep.insert(url.lastPathComponent)
            if let current = try? open(Data(contentsOf: url), id: id), NSDictionary(dictionary: current).isEqual(to: script) { continue }
            try seal(script, id: id).write(to: url, options: .atomic)
        }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "sealed" && !keep.contains(url.lastPathComponent) && !unreadable.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func seal(_ script: [String: Any], id: UUID) throws -> Data {
        let plain = try JSONSerialization.data(withJSONObject: script, options: [.sortedKeys])
        let box = try AES.GCM.seal(plain, using: keys.itemKey(takeUUID: id), authenticating: Self.format + Data(id.uuidString.utf8))
        return box.combined!
    }

    func open(_ sealed: Data, id: UUID) throws -> [String: Any] {
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plain = try AES.GCM.open(box, using: keys.itemKey(takeUUID: id), authenticating: Self.format + Data(id.uuidString.utf8))
        guard let object = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw Failure.notAnObject }
        return object
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("sealed")
    }
}
