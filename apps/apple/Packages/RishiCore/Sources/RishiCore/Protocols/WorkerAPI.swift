import Foundation

/// Marker protocol — Phase 2 RishiAPI package adds the real method surface
/// (auth endpoints, sync endpoints, billing, audio, realtime, sessions).
/// Kept here so feature packages can declare `any WorkerAPI` dependencies today
/// without coupling to GRDB or URLSession types.
public protocol WorkerAPI: Sendable {}
