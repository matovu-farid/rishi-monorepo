import Foundation

/// Production-grade sink consulted by `Log.event(...)` and `Log.error(...)`.
///
/// Sinks are **class-bound** (`AnyObject`) so the registry can deduplicate by
/// identity and remove by reference. Implementations must be safe to call from
/// arbitrary threads: `Log.event` is invoked from MainActor, custom actors,
/// `Task.detached`, and GCD queues across the codebase. Typical sinks wrap
/// their internal mutation in a serial `DispatchQueue` or actor and return
/// quickly from `record(...)`.
///
/// `record(...)` is `nonisolated` (no `@MainActor`) — the call site never
/// hops; the sink owns its own serialization.
public protocol LogSink: AnyObject, Sendable {
    /// Receive a log event. Must not block the caller; spool to a serial
    /// queue / actor before performing IO.
    func record(name: String, level: LogLevel, data: [String: String]?)
}
