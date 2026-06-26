










import SwiftUI
import RishiCore




struct SettingsSheet: View {

    let services: BootstrappedServices
    let user: User

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsContent(
            services: services,
            user: user,
            onDismiss: { dismiss() }
        )
    }
}

#Preview("Default") {
    PreviewPlaceholder(
        title: "Settings",
        subtitle: "Account, Subscription, Reader Defaults, Audio, Sync, Privacy.",
        variant: "Default"
    )
}

#Preview("Dark") {
    PreviewPlaceholder(
        title: "Settings",
        subtitle: "Account, Subscription, Reader Defaults, Audio, Sync, Privacy.",
        variant: "Dark"
    )
    .preferredColorScheme(.dark)
}
