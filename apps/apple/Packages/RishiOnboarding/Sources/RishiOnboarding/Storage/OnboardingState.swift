import Foundation

/// Persisted onboarding flags. ONB-01 + ONB-02. Reading is sync (UserDefaults
/// scalar reads are thread-safe); mutation is async to keep a future GRDB /
/// iCloud-KVS migration painless.
public protocol OnboardingState: Sendable {
    func hasCompletedOnboarding() async -> Bool
    func setHasCompletedOnboarding(_ value: Bool) async

    func primerShownMic() async -> Bool
    func setPrimerShownMic(_ value: Bool) async

    func primerShownNotifications() async -> Bool
    func setPrimerShownNotifications(_ value: Bool) async
}

/// UserDefaults-backed implementation. Defaults to `.standard`; tests pass a
/// scratch suite so they don't pollute the host defaults.
///
/// @unchecked Sendable justified: holds `let defaults: UserDefaults`, which
/// is non-Sendable under Swift 6 strict concurrency despite Apple's documented
/// thread safety for the scalar accessors used here. Mirrors the same pattern
/// across the codebase (UserDefaultsReaderSettingsStore, etc.).
public final class UserDefaultsOnboardingState: OnboardingState, @unchecked Sendable {

    fileprivate static let keyCompleted    = "onboarding.completed"
    fileprivate static let keyPrimerMic    = "onboarding.primer.mic"
    fileprivate static let keyPrimerNotifs = "onboarding.primer.notifications"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func hasCompletedOnboarding() async -> Bool {
        defaults.bool(forKey: Self.keyCompleted)
    }
    public func setHasCompletedOnboarding(_ value: Bool) async {
        defaults.set(value, forKey: Self.keyCompleted)
    }

    public func primerShownMic() async -> Bool {
        defaults.bool(forKey: Self.keyPrimerMic)
    }
    public func setPrimerShownMic(_ value: Bool) async {
        defaults.set(value, forKey: Self.keyPrimerMic)
    }

    public func primerShownNotifications() async -> Bool {
        defaults.bool(forKey: Self.keyPrimerNotifs)
    }
    public func setPrimerShownNotifications(_ value: Bool) async {
        defaults.set(value, forKey: Self.keyPrimerNotifs)
    }
}

/// Test/preview-only in-memory implementation.
actor InMemoryOnboardingState: OnboardingState {
    private var completed = false
    private var mic = false
    private var notifs = false

    public init() {}

    public func hasCompletedOnboarding() async -> Bool { completed }
    public func setHasCompletedOnboarding(_ value: Bool) async { completed = value }
    public func primerShownMic() async -> Bool { mic }
    public func setPrimerShownMic(_ value: Bool) async { mic = value }
    public func primerShownNotifications() async -> Bool { notifs }
    public func setPrimerShownNotifications(_ value: Bool) async { notifs = value }
}
