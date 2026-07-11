import Foundation

/// RishiOnboarding — Feature-layer package owning the first-run flow:
/// welcome → sign-in (reuses Phase-3 SIWA + Google flows via AuthService)
/// → import or sample book (reuses Phase-4 SampleBookInstaller) → first
/// reader hint. ONB-02: mic primer and voice language chooser shown before
/// entering the app.
///
/// Depends DOWN on RishiCore (User, AuthService), RishiUIKit (tokens),
/// RishiAuth (RishiAuthService), RishiLibrary (SampleBookInstaller),
/// RishiLogging.
///
/// Does NOT depend on RishiVoice / RishiSync — the primers are stand-alone
/// rationale screens that DEFER the actual permission request to the app
/// layer (mic request belongs to RishiVoice's `AVAudioApplication`; voice
/// language belongs to an app-level user preference stored in UserDefaults).
/// Primer presents rationale → invokes a closure → app layer triggers the
/// system permission dialog.
enum RishiOnboarding {
    /// Semantic version of the Feature surface. Bump on breaking API changes.
    static let version = "0.1.0-scaffold"
}
