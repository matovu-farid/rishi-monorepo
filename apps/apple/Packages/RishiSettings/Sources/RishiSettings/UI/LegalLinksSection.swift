import SwiftUI
import RishiUIKit
#if canImport(SafariServices) && canImport(UIKit)
import SafariServices
import UIKit
#endif

/// IAP-08 / Plan 13-10 — Required legal-link rows for App Review compliance.
///
/// Renders the "Legal" Settings section with three rows mandated by App
/// Review Guideline 3.1.2(a) for any subscription app:
///
///   1. Subscription Terms
///   2. Privacy Policy
///   3. Terms of Use
///
/// Each row presents its URL via ``SafariSheet`` (an `SFSafariViewController`
/// wrapped in `UIViewControllerRepresentable`). Links do NOT bounce the
/// user out to the external Safari app, and do NOT use a hand-rolled
/// WebKit view — `SFSafariViewController` is the App Review-blessed
/// pattern for in-app legal content.
///
/// URLs are pinned to `rishi.fidexa.org/legal/*`, which the anti-steering
/// CI guard (`check-anti-steering.sh`) treats as non-billing legal
/// disclosures (i.e. not steering language).
public struct LegalLinksSection: View {
    @State private var sheetURL: IdentifiedURL?

    /// Canonical legal-page URLs. Update here if the marketing site moves.
    /// MUST stay on `rishi.fidexa.org/legal/*` — the anti-steering allow
    /// pattern matches that path prefix.
    public enum LegalLink: String, CaseIterable, Identifiable {
        case subscriptionTerms = "https://rishi.fidexa.org/legal/subscription-terms"
        case privacyPolicy     = "https://rishi.fidexa.org/legal/privacy"
        case termsOfUse        = "https://rishi.fidexa.org/legal/terms"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .subscriptionTerms: return "Subscription Terms"
            case .privacyPolicy:     return "Privacy Policy"
            case .termsOfUse:        return "Terms of Use"
            }
        }

        public var systemImage: String {
            switch self {
            case .subscriptionTerms: return "doc.text.fill"
            case .privacyPolicy:     return "lock.fill"
            case .termsOfUse:        return "doc.plaintext"
            }
        }
    }

    public init() {}

    public var body: some View {
        Section("Legal") {
            ForEach(LegalLink.allCases) { link in
                Button {
                    if let url = URL(string: link.rawValue) {
                        sheetURL = IdentifiedURL(url: url)
                    }
                } label: {
                    HStack {
                        Image(systemName: link.systemImage)
                            .foregroundStyle(RishiColor.accent)
                            .frame(width: 28)
                        Text(link.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }
                .accessibilityHint("Opens \(link.title) in an in-app browser")
                .accessibilityIdentifier("legal-link-\(link.rawValue)")
            }
        }
        .sheet(item: $sheetURL) { wrapper in
            SafariSheet(url: wrapper.url)
        }
    }
}

/// `Identifiable` URL wrapper so SwiftUI `.sheet(item:)` can present a
/// fresh sheet each time the user taps a row. Each instance gets a unique
/// UUID — equal URLs intentionally do NOT collapse to one identity, so
/// tapping the same row twice still re-presents the sheet (matches the
/// HIG expectation for legal disclosures).
public struct IdentifiedURL: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public init(url: URL) { self.url = url }
}

/// SwiftUI wrapper around `SFSafariViewController`. On iOS + Mac Catalyst,
/// presents the system in-app browser. On pure macOS (AppKit, non-Catalyst)
/// `SafariServices` is unavailable, so the `#else` branch ships a no-op
/// stub for compile-time completeness — that branch is unreachable in
/// practice because the hosting SwiftUI `.sheet` API is also unavailable
/// on the same target.
public struct SafariSheet: UIViewControllerRepresentable {
    public let url: URL
    public init(url: URL) { self.url = url }

    #if canImport(SafariServices) && canImport(UIKit)
    public func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true
        return SFSafariViewController(url: url, configuration: config)
    }

    public func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
    #else
    // AppKit (pure macOS) fallback stub: no `SFSafariViewController` exists
    // here. The hosting SwiftUI `.sheet(item:)` modifier path is unreachable
    // on this target, so this stub only needs to satisfy the protocol's
    // associated type requirements at compile time.
    public typealias UIViewControllerType = NSObject
    public func makeUIViewController(context: Context) -> NSObject { NSObject() }
    public func updateUIViewController(_ vc: NSObject, context: Context) {}
    #endif
}

#Preview("LegalLinksSection") {
    Form {
        LegalLinksSection()
    }
}
