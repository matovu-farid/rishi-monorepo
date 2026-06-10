import SwiftUI
import RishiUIKit

/// Read-only About section. Reads version + build from
/// `Bundle.main.infoDictionary` so the value updates automatically with
/// every release.
public struct AboutSection: View {

    public init() {}

    public var body: some View {
        Section {
            HStack {
                Text("Version")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary)
                Spacer()
                Text(versionString)
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.textSecondary)
                    .accessibilityIdentifier("settings-about-version")
            }
            HStack {
                Text("Copyright")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary)
                Spacer()
                Text("© Fidexa, Inc.")
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.textSecondary)
            }
        } header: {
            Text("About")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

#Preview("About") {
    Form {
        AboutSection()
    }
}
