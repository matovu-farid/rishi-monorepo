










import SwiftUI





struct SettingsSheet: View {

    let dependencies: SettingsContentDependencies
    let user: User

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsContent(
            dependencies: dependencies,
            user: user,
            onDismiss: { dismiss() }
        )
    }
}

#Preview("Default") {
    SettingsScreenPreviewHost()
}

#Preview("Dark") {
    SettingsScreenPreviewHost()
        .preferredColorScheme(.dark)
}
