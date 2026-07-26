#if !canImport(UIKit)
/// Compile-only `AccessibilityProviding` for the non-UIKit (macOS dev
/// host) branch. `UIAccessibility` is unavailable outside iOS / Catalyst
/// so we hand back a fixed `false` — preview content never has VoiceOver
/// running. Shared by `PDFReaderScreen` and `ReaderScreen`.
@MainActor
final class PreviewAccessibility: AccessibilityProviding {
    var isVoiceOverRunning: Bool { false }
}
#endif
