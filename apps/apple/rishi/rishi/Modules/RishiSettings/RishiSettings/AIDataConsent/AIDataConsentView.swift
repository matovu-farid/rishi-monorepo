import SwiftUI

public struct AIDataConsentView: View {
    public let onAllow: () -> Void
    public let onNotNow: () -> Void
    @State private var isShowingDetails = false

    public init(onAllow: @escaping () -> Void, onNotNow: @escaping () -> Void) {
        self.onAllow = onAllow
        self.onNotNow = onNotNow
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(DataUseConsentDisclosure.summaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    DisclosureGroup(
                        DataUseConsentDisclosure.detailsTitle,
                        isExpanded: $isShowingDetails
                    ) {
                        VStack(alignment: .leading, spacing: 14) {
                            disclosureSection(
                                title: "Rishi cloud sync",
                                items: DataUseConsentDisclosure.cloudSyncItems.map { Text($0.capitalized) }
                            )

                            disclosureSection(
                                title: "AI providers",
                                items: DataUseConsentDisclosure.aiProviderItems.map { Text($0) }
                            )

                            Text(DataUseConsentDisclosure.purposeText)
                            Text(DataUseConsentDisclosure.retentionText)
                                .foregroundStyle(.secondary)

                            Link("Read our Privacy Policy", destination: DataUseConsentDisclosure.privacyPolicyURL)
                                .accessibilityIdentifier("data-use-consent-privacy")
                        }
                        .font(.footnote)
                        .padding(.top, 10)
                    }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("data-use-consent-details")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle(DataUseConsentDisclosure.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button("Allow data use", action: onAllow)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("data-use-consent-allow")

                    Button("Not now", action: onNotNow)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("data-use-consent-not-now")
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func disclosureSection(title: String, items: [Text]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label {
                    item
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
