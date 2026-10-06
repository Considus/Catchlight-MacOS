import AppKit
import UniformTypeIdentifiers
import CatchlightCore
import CatchlightAppleStorage

/// Import notes as Takes (M3), as the iPhone's `ImportCoordinator`: Markdown, plain text and RTF
/// files, from the `Import` folder inside the sync folder (drop files there from any device, then
/// Import Notes) or from files the user picks (Import from a File, no sync folder needed). Each
/// file goes through Core's `TakeImporter.parseDocument`, which splits a Catchlight export back
/// into its Takes (and Scripts) and makes one Take of any other note.
///
/// Parsing never touches the library; `Library.importItems` writes what it returns. Nothing here
/// logs, because note content is sensitive (as the iPhone).
enum NoteImport {
    static let folderName = "Import"
    static let extensions: Set<String> = ["md", "markdown", "txt", "text", "rtf"]

    struct Outcome {
        var items: [Take] = []
        /// Importable files seen.
        var scanned = 0
        /// Files that were empty or unreadable.
        var skipped = 0
    }

    enum Failure: Error { case folderUnreadable }

    /// Every importable file in the sync folder's `Import` folder, made if missing. `cloud` holds
    /// the folder's security scope for as long as it lives.
    static func parseImportFolder(_ cloud: FileCloudFolder) throws -> Outcome {
        cloud.ensureSubfolder(folderName)
        let folder = cloud.folderURL.appendingPathComponent(folderName, isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { throw Failure.folderUnreadable }
        let files = items
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return parse(files)
    }

    /// Files the user picked; the open panel's grant covers reading them.
    static func parse(_ files: [URL]) -> Outcome {
        var outcome = Outcome()
        for url in files {
            outcome.scanned += 1
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let text = decodeText(data, isRTF: url.pathExtension.lowercased() == "rtf") else {
                outcome.skipped += 1
                continue
            }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let parsed = TakeImporter.parseDocument(text, fileDate: date)
            if parsed.isEmpty { outcome.skipped += 1 } else { outcome.items += parsed }
        }
        return outcome
    }

    /// The iPhone's decode chain (`ImportCoordinator.decodeText`): RTF through NSAttributedString,
    /// so only the words come through; otherwise UTF-8, then NSString's detection (a UTF-16 file
    /// from Windows Notepad), then Latin-1 last, because it decodes any bytes at all.
    static func decodeText(_ data: Data, isRTF: Bool) -> String? {
        if isRTF {
            return (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                            documentAttributes: nil))?.string
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        var converted: NSString?
        let detected = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        if detected != 0, let converted { return converted as String }
        return String(data: data, encoding: .isoLatin1)
    }

    /// The open panel for Import from a File: several files, Markdown, plain text or RTF. Answers
    /// the chosen files, or nil when cancelled.
    static func pickFiles(in window: NSWindow?, _ done: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.plainText, .text, .rtf]
        for ext in ["md", "markdown"] { if let t = UTType(filenameExtension: ext) { types.append(t) } }
        panel.allowedContentTypes = types
        panel.prompt = "Import"
        let finish: (NSApplication.ModalResponse) -> Void = { done($0 == .OK ? panel.urls : nil) }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }
}
