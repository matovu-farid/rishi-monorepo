//
//  DeepLinkRouter.swift
//  rishi
//
//  Phase 12 Plan 12-03 — pure-Swift URL → DeepLinkDestination resolver.
//
//  No side effects, no IO, no actors. `RootView.onOpenURL` hands a URL in
//  and dispatches the returned destination. Universal-Link smoke depends
//  on the worker hosting `apple-app-site-association` at
//  rishi.fidexa.org/.well-known/apple-app-site-association
//  (WORKER-TICKETS Ticket 2) — the iOS-side wiring is complete here.
//
//  Recognised schemes:
//    rishi://...                    custom scheme (always ours)
//    https://rishi.fidexa.org/...   Universal Link (worker AASA ticket)
//
//  Recognised paths:
//    rishi://auth/callback?token=...
//    rishi://sharing/join?token=...
//    rishi://book/<uuid>
//    rishi://conversation/<uuid>
//    https://rishi.fidexa.org/auth/callback?token=...
//    https://rishi.fidexa.org/sharing/join?token=...
//    https://rishi.fidexa.org/app/book/<uuid>
//    https://rishi.fidexa.org/app/conversation/<uuid>
//

import Foundation
import RishiCore

struct DeepLinkRouter: Sendable {

    /// Apex host that owns Universal Link routing. Lowercased before
    /// comparison so a clipboard-pasted upper-case URL still resolves.
    static let universalHost = "rishi.fidexa.org"

    /// Custom URL scheme registered in Info.plist (CFBundleURLTypes).
    static let customScheme  = "rishi"

    func route(_ url: URL) -> DeepLinkDestination {
        guard let scheme = url.scheme?.lowercased() else { return .unknown }
        switch scheme {
        case Self.customScheme:
            return routeCustomScheme(url)
        case "https":
            guard url.host?.lowercased() == Self.universalHost else { return .unknown }
            return routeUniversalLink(url)
        default:
            return .unknown
        }
    }

    // MARK: - Custom scheme

    private func routeCustomScheme(_ url: URL) -> DeepLinkDestination {
        let host = url.host?.lowercased() ?? ""
        let path = url.path

        switch (host, path) {
        case ("auth", "/callback"):
            return .authCallback(token: queryToken(url) ?? "")

        case ("sharing", "/join"):
            return .shareRedeem(token: queryToken(url) ?? "")

        case ("book", _):
            return parseUUIDPath(path).map(DeepLinkDestination.openBook) ?? .unknown

        case ("conversation", _):
            return parseUUIDPath(path).map(DeepLinkDestination.openConversation) ?? .unknown

        default:
            return .unknown
        }
    }

    // MARK: - Universal Link

    private func routeUniversalLink(_ url: URL) -> DeepLinkDestination {
        // Apple normalises Universal Link paths so the leading "/" is always
        // present. Splitting on "/" and dropping empties gives the route
        // components in order.
        //
        // We tuple the first three slots so we can pattern-match with `let`
        // bindings — Swift array literal patterns don't support inline let.
        let parts = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        switch parts {
        case ["auth", "callback"]:
            return .authCallback(token: queryToken(url) ?? "")

        case ["sharing", "join"]:
            return .shareRedeem(token: queryToken(url) ?? "")

        case _ where parts.count == 3 && parts[0] == "app" && parts[1] == "book":
            return UUID(uuidString: parts[2]).map(DeepLinkDestination.openBook) ?? .unknown

        case _ where parts.count == 3 && parts[0] == "app" && parts[1] == "conversation":
            return UUID(uuidString: parts[2]).map(DeepLinkDestination.openConversation) ?? .unknown

        default:
            return .unknown
        }
    }

    // MARK: - Helpers

    private func queryToken(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "token" })?
            .value
    }

    private func parseUUIDPath(_ path: String) -> UUID? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return UUID(uuidString: trimmed)
    }
}
