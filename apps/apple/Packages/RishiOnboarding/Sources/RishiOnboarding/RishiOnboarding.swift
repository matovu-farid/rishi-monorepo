import Foundation

/// RishiOnboarding — Feature-layer package owning the first-run flow shown
/// before authentication:
/// welcome → mic primer → voice language chooser → first reader hint.
/// Book setup is presented later from the authenticated library.
///
/// Depends DOWN on RishiCore (User), RishiUIKit (tokens),
/// RishiLibrary (shared book models/installers), and RishiLogging.
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
