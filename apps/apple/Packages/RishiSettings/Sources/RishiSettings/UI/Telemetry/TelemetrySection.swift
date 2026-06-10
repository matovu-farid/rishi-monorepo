import SwiftUI
import RishiUIKit

/// SET-02 — Privacy / telemetry section. Toggle is bound to a local
/// `@State` mirror that hydrates from the store on `task` and writes back
/// on `onChange`. The store invokes `TelemetrySink.setEnabled(_:)` so the
/// app layer can mute Sentry immediately.
public struct TelemetrySection: View {

    @State private var optedIn: Bool = true
    private let store: any TelemetryStore

    public init(store: any TelemetryStore) {
        self.store = store
    }

    public var body: some View {
        Section {
            Toggle("Share anonymous usage data", isOn: $optedIn)
                .accessibilityIdentifier("settings-telemetry-toggle")
                .onChange(of: optedIn) { _, new in
                    Task { await store.setOptedIn(new) }
                }
                .task {
                    optedIn = await store.optedIn()
                }
        } header: {
            Text("Privacy")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        } footer: {
            Text("We use Sentry to capture crash reports and basic usage metrics so we can fix bugs. No book content, no highlights, no chat messages are ever sent.")
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textSecondary)
        }
    }
}
