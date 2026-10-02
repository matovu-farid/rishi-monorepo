import Foundation

/// Deliberately non-Codable: it is a short-lived presentation token and never
/// participates in state restoration or exposes share credentials.
struct SharedReadingReaderRoute: Hashable, Identifiable {
    let id: UUID
    let accountID: UUID
    let readerRoute: ReaderRoute
    let sessionID: String
}

@MainActor
struct SharedReadingReaderPresentation {
    let route: SharedReadingReaderRoute
    let context: SharedReadingReaderContext
}
