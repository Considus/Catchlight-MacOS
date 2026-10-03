import AppKit
import WebKit
import os

/// What the Mac reports about itself, for About and Report an Issue (`shell.systemInfo`).
enum SystemInfo {
    /// `15.8`, or `15.8.1` when there is a patch number.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The hardware model identifier, such as `Mac16,1` (`sysctl hw.model`).
    static var model: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: buffer)
    }
}

/// The page's way into Swift: one `WKScriptMessageHandlerWithReply` named `catchlight`, in the
/// page content world, and a script injected at document start that hands the page the values
/// it reads synchronously. The page's half is `ui/bridge.js`.
///
/// Messages are `{cmd, ...}`:
/// - `menu {model}`: the menu model as JSON, pushed whenever it may have changed;
/// - `copy {text}`: write plain text to the clipboard;
/// - `openURL {url}`: open an http(s) or mailto address in the default app;
/// - `dragWindow`, `titlebarDoubleClick`: the page's toolbar standing in for the title bar.
final class ShellBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "catchlight"
    private static let log = Logger(subsystem: "com.considus.catchlight.mac", category: "bridge")

    weak var window: NSWindow?
    var onMenuModel: (([MenuEntry]) -> Void)?
    var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Defines `window.catchlightShell` before any of the page's own scripts run, with the values
    /// baked in, so `shell.systemInfo()` stays synchronous.
    static func injectedValues() -> WKUserScript {
        let values: [String: String] = ["platform": "mac", "osName": "macOS", "osVersion": SystemInfo.osVersion, "model": SystemInfo.model]
        let json = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let source = "window.catchlightShell = Object.freeze(\(json));"
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    func install(in controller: WKUserContentController) {
        controller.addUserScript(Self.injectedValues())
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.name)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        // Only the app's own page may use the bridge.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == UIResourceSchemeHandler.scheme,
              let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            replyHandler(nil, "refused")
            return
        }
        switch cmd {
        case "menu":
            guard let json = body["model"] as? String else { return replyHandler(nil, "menu needs a model") }
            do {
                onMenuModel?(try .decode(json: json))
                replyHandler(true, nil)
            } catch {
                Self.log.error("menu model did not decode: \(String(describing: error), privacy: .public)")
                replyHandler(nil, "menu model did not decode")
            }
        case "copy":
            guard let text = body["text"] as? String else { return replyHandler(nil, "copy needs text") }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            replyHandler(pasteboard.setString(text, forType: .string), nil)
        case "openURL":
            guard let string = body["url"] as? String,
                  case .openExternally(let url) = NavigationRule.decide(URL(string: string), userFollowedLink: true) else {
                return replyHandler(nil, "not an address the browser or mail app opens")
            }
            openExternally(url)
            replyHandler(true, nil)
        case "dragWindow":
            // The mouse is still down: hand the drag to the window server as the title bar would.
            if let window, let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseDragged].contains(event.type) {
                window.performDrag(with: event)
            }
            replyHandler(true, nil)
        case "titlebarDoubleClick":
            // What a double-click on a title bar does, as set in System Settings ▸ Desktop & Dock.
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window?.performMiniaturize(nil)
            case "None": break
            default: window?.performZoom(nil)
            }
            replyHandler(true, nil)
        default:
            replyHandler(nil, "unknown command \(cmd)")
        }
    }
}
