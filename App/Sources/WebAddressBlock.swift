import Foundation
import WebKit

/// The hard block on web addresses (owner decision for M1): the page is the bundled `ui/` and
/// nothing else. Two layers, each enough on its own:
///
/// - `ruleListJSON`, a `WKContentRuleList` that blocks every resource load (fetch, XHR, images,
///   fonts, scripts, frames, WebSockets) whose URL is not the app's own scheme;
/// - `NavigationRule`, the navigation policy, which cancels every navigation off
///   `catchlight://` and sends a link the user follows to the default browser instead.
enum WebAddressBlock {
    static let ruleListIdentifier = "catchlight-web-address-block"

    /// Schemes exempt from the block: the app's own, and the in-page ones whose content never
    /// leaves the device. WebKit applies content rules to http(s) and ws(s) loads; the
    /// exemptions say so explicitly rather than relying on it.
    static let allowedSchemes = [UIResourceSchemeHandler.scheme, "data", "blob", "about"]

    /// Block everything, then exempt `allowedSchemes`, one rule each: a content rule's
    /// `url-filter` has no alternation, and a list using `|` fails to compile.
    static var ruleListJSON: String {
        let block = #"{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}}"#
        let exempt = allowedSchemes.map { #"{"trigger": {"url-filter": "^\#($0):"}, "action": {"type": "ignore-previous-rules"}}"# }
        return "[" + ([block] + exempt).joined(separator: ",") + "]"
    }

    /// Compiles the rule list. The window loads nothing until this succeeds.
    static func compile(completion: @escaping (Result<WKContentRuleList, Error>) -> Void) {
        guard let store = WKContentRuleListStore.default() else {
            completion(.failure(CocoaError(.featureUnsupported)))
            return
        }
        store.compileContentRuleList(forIdentifier: ruleListIdentifier, encodedContentRuleList: ruleListJSON) { list, error in
            if let list {
                completion(.success(list))
            } else {
                completion(.failure(error ?? CocoaError(.featureUnsupported)))
            }
        }
    }
}

/// What the window does with a navigation, decided from the URL alone so it can be tested.
enum NavigationRule: Equatable {
    case allow
    case openExternally(URL)
    case cancel

    /// Schemes the default browser or mail app may be asked to open.
    static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// - Parameters:
    ///   - url: where the navigation goes.
    ///   - userFollowedLink: the user clicked a link, or the page asked for a new window
    ///     (`target=_blank`, `window.open`). Anything else off the app's scheme, such as a
    ///     script setting `location`, is cancelled without opening anything.
    static func decide(_ url: URL?, userFollowedLink: Bool) -> NavigationRule {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if scheme == UIResourceSchemeHandler.scheme { return .allow }
        // An empty frame or srcdoc stays in the page and loads nothing.
        if scheme == "about", ["blank", "srcdoc"].contains(url.absoluteString.dropFirst("about:".count).lowercased()) {
            return .allow
        }
        if userFollowedLink, externalSchemes.contains(scheme) { return .openExternally(url) }
        return .cancel
    }
}
