import Foundation
import RishiCore

/// Persisted per-account "has this account seen the no-card trial explainer"
/// flag. Deliberately separate from `OnboardingState` (device-scoped, no
/// user ID) because the no-card explainer is about an *account's* trial
/// entitlement, not this *device's* first-run wizard: a second account
/// signing in on the same device must see it again, and the same account
/// restoring on a new device must not.
public protocol TrialOnboardingState: Sendable {
    func hasSeenNoCardIntro(userId: UserID) async -> Bool
    func setHasSeenNoCardIntro(_ value: Bool, userId: UserID) async
}

/// UserDefaults-backed implementation. Key pattern matches
/// `UserDefaultsTTSSettingsStore.key(for:)` — `"<namespace>.<userId>"`.
///
/// @unchecked Sendable justified: holds `let defaults: UserDefaults`, which
/// is non-Sendable under Swift 6 strict concurrency despite Apple's documented
/// thread safety for the scalar accessors used here. Mirrors the same pattern
/// as `UserDefaultsOnboardingState` / `UserDefaultsTTSSettingsStore`.
public final class UserDefaultsTrialOnboardingState: TrialOnboardingState, @unchecked Sendable {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func hasSeenNoCardIntro(userId: UserID) async -> Bool {
        defaults.bool(forKey: Self.key(for: userId))
    }

    public func setHasSeenNoCardIntro(_ value: Bool, userId: UserID) async {
        defaults.set(value, forKey: Self.key(for: userId))
    }

    static func key(for userId: UserID) -> String {
        "onboarding.noCardTrial.seen.\(userId.uuidString)"
    }
}

/// Test/preview-only in-memory implementation.
public actor InMemoryTrialOnboardingState: TrialOnboardingState {
    private var seen: Set<UserID> = []

    public init() {}

    public func hasSeenNoCardIntro(userId: UserID) async -> Bool {
        seen.contains(userId)
    }

    public func setHasSeenNoCardIntro(_ value: Bool, userId: UserID) async {
        if value { seen.insert(userId) } else { seen.remove(userId) }
    }
}
