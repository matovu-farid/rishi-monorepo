import Foundation

/// Telemetry opt-in surface for SET-02.
///
/// `optedIn` defaults to TRUE on first run (matches Sentry-on-by-default in
/// Phase-1 wiring per STATE.md). Toggling OFF persists FALSE and invokes
/// `TelemetrySink.setEnabled(_:)` so the app layer can mute Sentry
/// breadcrumbs / events immediately through the application-owned lifecycle.
///
/// RishiSettings deliberately does NOT import Sentry — the sink seam lets
/// AppDependencies (11-06) wire the SDK without dragging it into a Feature
/// package.
public protocol TelemetryStore: Sendable {
    func optedIn() async -> Bool
    func setOptedIn(_ value: Bool) async
}

/// App-layer hook that actually flips the SDK on/off. RishiSettings doesn't
/// import Sentry — the sink is provided by AppDependencies in 11-06.
public protocol TelemetrySink: Sendable {
    func setEnabled(_ enabled: Bool) async
}

/// No-op sink for unit tests / previews.
public struct NoOpTelemetrySink: TelemetrySink {
    public init() {}
    public func setEnabled(_ enabled: Bool) async {}
}

/// Default UserDefaults-backed store. The sink is invoked synchronously
/// after persistence so a toggle-off can't be observed in a partial state.
///
/// @unchecked Sendable justified: holds `let defaults: UserDefaults`, which
/// is non-Sendable under Swift 6 strict concurrency despite the documented
/// thread-safe scalar accessors.
public final class UserDefaultsTelemetryStore: TelemetryStore, @unchecked Sendable {

    /// Persistence key. Stable wire identifier — DO NOT rename without a
    /// migration; the value is read on every app launch by AppDependencies.
    public static let storageKey = "telemetry.optedIn"

    private let defaults: UserDefaults
    private let sink: any TelemetrySink

    public init(defaults: UserDefaults = .standard, sink: any TelemetrySink = NoOpTelemetrySink()) {
        self.defaults = defaults
        self.sink = sink
        // First-run default = TRUE. If the key is absent, write TRUE explicitly
        // so subsequent `bool(forKey:)` reads return true (the default for an
        // absent bool key is false, which would silently opt the user out).
        if defaults.object(forKey: Self.storageKey) == nil {
            defaults.set(true, forKey: Self.storageKey)
        }
    }

    public func optedIn() async -> Bool {
        defaults.bool(forKey: Self.storageKey)
    }

    public func setOptedIn(_ value: Bool) async {
        defaults.set(value, forKey: Self.storageKey)
        await sink.setEnabled(value)
    }
}

/// In-memory impl for tests + previews.
actor InMemoryTelemetryStore: TelemetryStore {
    private var value: Bool
    public init(initial: Bool = true) { self.value = initial }
    public func optedIn() async -> Bool { value }
    public func setOptedIn(_ value: Bool) async { self.value = value }
}
