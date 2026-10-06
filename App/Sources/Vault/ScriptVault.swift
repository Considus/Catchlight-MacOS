import Foundation
import CryptoKit
import CatchlightCore
import os

/// Scripts as the Mac kept them before M3b, one sealed file each in `Scripts/`. They now live in
/// the library as Takes of kind Script, and `Library.moveScriptsIn` moves each file's Script there
/// at launch; what is left here is a file that would not open, kept as it is.
///
/// Each file holds the page's own Script JSON, sealed with AES-256-GCM under the per-item key Core derives for the
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

    /// Remove one Script's file, once the library holds it (`Library.moveScriptsIn`).
    func remove(_ id: UUID) throws {
        let url = fileURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
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
