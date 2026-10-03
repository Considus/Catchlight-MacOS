import AppKit
import WebKit

/// The one window: a WKWebView showing the bundled ui/ through the
/// `catchlight://` scheme (UIResourceSchemeHandler), never `file://`.
final class MainWindowController: NSWindowController, WKNavigationDelegate {
    static let startURL = URL(string: "\(UIResourceSchemeHandler.scheme)://\(UIResourceSchemeHandler.host)/index.html")!
    private static let frameAutosaveName = "CatchlightMainWindow"

    private let webView: WKWebView

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(UIResourceSchemeHandler(), forURLScheme: UIResourceSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true   // Safari ▸ Develop, debug builds only
        }
        #endif

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Catchlight"
        window.minSize = NSSize(width: 900, height: 600)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        // Restore the last frame; centre the default size on first launch.
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        super.init(window: window)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: Self.startURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The page only ever navigates within the bundle. Anything else is refused
    // here; opening links in the browser is M1's (`links.js`, NSWorkspace).
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == UIResourceSchemeHandler.scheme || scheme == "about" ? .allow : .cancel)
    }
}
