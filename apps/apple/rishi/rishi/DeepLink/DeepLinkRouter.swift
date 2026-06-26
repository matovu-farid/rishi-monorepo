

import Foundation
import RishiCore

struct DeepLinkRouter: Sendable {


    static let universalHost = "rishi.fidexa.org"

    
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

    

    private func routeUniversalLink(_ url: URL) -> DeepLinkDestination {
        
        
        
        //
        
        
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
