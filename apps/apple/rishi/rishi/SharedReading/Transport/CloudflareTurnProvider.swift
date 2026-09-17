@preconcurrency import LiveKitWebRTC

struct CloudflareTurnProvider {
    let iceServers: [LKRTCIceServer]

    init(credentials: SharedReadingTurnCredentials) {
        self.iceServers = Self.iceServers(from: credentials)
    }

    static func iceServers(from credentials: SharedReadingTurnCredentials) -> [LKRTCIceServer] {
        credentials.iceServers.compactMap { server in
            guard !server.urls.isEmpty else { return nil }
            return LKRTCIceServer(
                urlStrings: server.urls,
                username: server.username,
                credential: server.credential
            )
        }
    }
}
