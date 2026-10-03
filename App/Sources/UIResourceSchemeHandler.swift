import Foundation
import WebKit

/// Serves `catchlight://app/<path>` from the bundle's `ui` folder, so the page
/// has a stable origin and never sees a file-system URL.
final class UIResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "catchlight"
    static let host = "app"

    private let root: URL

    init(root: URL? = Bundle.main.resourceURL?.appendingPathComponent("ui", isDirectory: true)) {
        self.root = (root ?? URL(fileURLWithPath: "/nonexistent")).standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        guard url.host == Self.host, let file = resolve(url.path) else {
            respond(urlSchemeTask, url: url, status: 404, mimeType: "text/plain", data: Data("Not found".utf8))
            return
        }
        do {
            let data = try Data(contentsOf: file)
            respond(urlSchemeTask, url: url, status: 200, mimeType: Self.mimeType(for: file.pathExtension), data: data)
        } catch {
            respond(urlSchemeTask, url: url, status: 404, mimeType: "text/plain", data: Data("Not found".utf8))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Every response is sent synchronously in `start`, so there is nothing to cancel.
    }

    /// Maps a URL path to a file inside `root`, refusing anything that escapes it.
    func resolve(_ path: String) -> URL? {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let candidate = root.appendingPathComponent(relative.isEmpty ? "index.html" : relative).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return candidate
    }

    static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "txt", "md": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, mimeType: String, data: Data) {
        let headers = [
            "Content-Type": mimeType,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
