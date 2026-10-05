import AppKit
import CatchlightAppleStorage
import os

/// The cloud folder the user picked for sync (M3), held as a security-scoped bookmark so the
/// sandboxed app can reach it again after a relaunch. The page only ever sees its path, to show;
/// the bookmark, and with it the access, stays here.
///
/// The iPhone keeps its bookmark the same way (`Wiring.makeCloudFolder`), through the same
/// `FileCloudFolder` from Catchlight-AppleStorage.
final class SyncFolder {
    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "sync")
    static let bookmarkKey = "syncFolderBookmark"

    private let defaults: UserDefaults
    /// Shows the open panel and answers with the chosen folder, or nil if cancelled. Replaced in
    /// tests, which can't drive a panel.
    var pick: (NSWindow?, @escaping (URL?) -> Void) -> Void = SyncFolder.openPanel

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasFolder: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }

    /// The folder, ready for the sync engine, or nil when none is chosen or the bookmark no longer
    /// resolves (the folder was deleted, say). A stale bookmark is re-made from the folder it still
    /// found, as the system asks, so it keeps working.
    func open() -> FileCloudFolder? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        do {
            let folder = try FileCloudFolder(bookmark: bookmark)
            if folder.bookmarkWasStale, let fresh = try? FileCloudFolder.makeBookmark(for: folder.folderURL) {
                defaults.set(fresh, forKey: Self.bookmarkKey)
                Self.log.info("the sync folder's bookmark was stale and has been renewed")
            }
            return folder
        } catch {
            Self.log.error("the sync folder did not open: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The chosen folder's path for the page to show, with the home folder as `~`, or nil.
    var displayPath: String? {
        guard let folder = open() else { return nil }
        return Self.display(folder.folderURL)
    }

    /// Ask the user for a folder. On a choice the bookmark is stored and the path returned; on
    /// cancel nothing changes and nil is returned. A folder that can't be bookmarked is an error,
    /// never a quiet cancel, so the page can say why it didn't stick.
    func choose(in window: NSWindow?, completion: @escaping (Result<String?, Error>) -> Void) {
        pick(window) { [weak self] url in
            guard let self, let url else { return completion(.success(nil)) }
            do {
                self.defaults.set(try FileCloudFolder.makeBookmark(for: url), forKey: Self.bookmarkKey)
                Self.log.info("a sync folder was chosen")
                completion(.success(Self.display(url)))
            } catch {
                Self.log.error("no bookmark for the chosen folder: \(String(describing: error), privacy: .public)")
                completion(.failure(error))
            }
        }
    }

    func forget() {
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    // MARK: Private

    private static func openPanel(_ window: NSWindow?, _ done: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder in iCloud Drive, Dropbox or any cloud you use. Catchlight keeps only encrypted files there."
        let finish: (NSApplication.ModalResponse) -> Void = { done($0 == .OK ? panel.url : nil) }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// `/Users/<name>/…` as `~/…`. The sandbox moves NSHomeDirectory into the container, so the
    /// real home comes from the user database.
    static func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return path }
        let home = String(cString: dir)
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
