//
//  FeatureFlags.swift
//  rishi
//
//  Compile-time feature flags. Relocated out of `AppDependencies.swift`
//  (plan 34-14 SRP split) so the composition root holds only service wiring,
//  not feature-flag policy. Behaviour-preserving move — the enum is unchanged.
//

// MARK: - Feature flags (Phase 8)

/// Compile-time feature flags. Phase 8 ships Read Aloud behind a flag that
/// is ON in DEBUG (TestFlight + dev) and OFF in Release (App Store builds)
/// until UAT confirms the read-aloud pipeline meets quality bar.
enum FeatureFlags {
    /// TTS / Read Aloud surfaces (reader toolbar button, controls sheet,
    /// voice + speed picker). Gated to DEBUG until Phase 8 UAT closes.
    static var readAloud: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
