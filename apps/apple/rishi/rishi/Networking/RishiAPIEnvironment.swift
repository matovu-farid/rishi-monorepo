import Foundation

enum RishiAPIEnvironmentMode: String, Sendable, Equatable {
    case production

    #if DEBUG
    case liveE2E
    #endif
}

/// The only application-level source of Worker endpoint selection.
///
/// The HTTP endpoint is used by WorkerClient and specialized API clients. The
/// WebSocket endpoint is the canonical production sharing Worker endpoint and
/// is retained here for diagnostics and endpoint validation.
struct RishiAPIEnvironment: Sendable, Equatable {
    let mode: RishiAPIEnvironmentMode
    let httpBaseURL: URL
    let sharingWebSocketURL: URL

    init?(
        mode: RishiAPIEnvironmentMode,
        httpBaseURL: URL,
        sharingWebSocketURL: URL
    ) {
        guard Self.isValidHTTPBaseURL(httpBaseURL),
              Self.isValidWebSocketBaseURL(sharingWebSocketURL)
        else { return nil }
        self.mode = mode
        self.httpBaseURL = httpBaseURL
        self.sharingWebSocketURL = sharingWebSocketURL
    }

    static func load(
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RishiAPIEnvironment? {
        #if DEBUG
        if environment["RISHI_UITEST"] == "1",
           environment["RISHI_E2E_REAL_AUTH"] == "1" {
            guard environment["RISHI_E2E_API_BASE_URL"] == Self.liveE2EHTTPBaseURLString,
                  environment["RISHI_E2E_SHARING_WS_URL"] == Self.liveE2EWebSocketURLString,
                  let httpURL = URL(string: Self.liveE2EHTTPBaseURLString),
                  let webSocketURL = URL(string: Self.liveE2EWebSocketURLString)
            else { return nil }

            return RishiAPIEnvironment(
                mode: .liveE2E,
                httpBaseURL: httpURL,
                sharingWebSocketURL: webSocketURL
            )
        }
        #endif

        // Debug builds intentionally use the same production backend as
        // Release builds. This prevents a missing local Worker or local
        // database/auth configuration from masquerading as an app failure.
        let mode: RishiAPIEnvironmentMode = .production

        let configuredHTTP = info["RishiAPIBaseURL"] as? String
        let configuredWebSocket = info["RishiSharingWebSocketURL"] as? String

        let httpString = configuredHTTP
        let webSocketString = configuredWebSocket

        guard let httpString,
              let webSocketString,
              let httpURL = URL(string: httpString),
              let webSocketURL = URL(string: webSocketString)
        else { return nil }

        return RishiAPIEnvironment(
            mode: mode,
            httpBaseURL: httpURL,
            sharingWebSocketURL: webSocketURL
        )
    }

    #if DEBUG
    private static let liveE2EHTTPBaseURLString = "https://api-e2e.fidexa.org"
    private static let liveE2EWebSocketURLString = "wss://sharing-e2e.fidexa.org"
    #endif

    private static func isValidHTTPBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.query == nil,
              url.fragment == nil
        else { return false }
        return true
    }

    private static func isValidWebSocketBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              url.host != nil,
              url.query == nil,
              url.fragment == nil
        else { return false }
        return true
    }
}
