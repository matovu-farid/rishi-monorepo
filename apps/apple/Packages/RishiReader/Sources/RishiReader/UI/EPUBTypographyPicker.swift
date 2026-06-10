import SwiftUI
import RishiCore
import RishiUIKit

/// Sheet that lets the user tune body-text typography for an EPUB:
/// font family (system / serif / sans / dyslexic), font size (slider),
/// and line height (slider). Every change writes through
/// ``ReaderSettingsStore`` so the choice survives close + reopen.
///
/// Persistence shape mirrors ``PDFThemePicker``: the picker mutates the
/// passed-in `Binding<ReaderTypography>` so the navigator sees the change
/// immediately (the screen's `.onChange` re-submits Readium preferences),
/// then asynchronously calls `setTypography(_:for:)`.
public struct EPUBTypographyPicker: View {

    @Binding public var typography: ReaderTypography
    public let bookId: BookID
    public let store: any ReaderSettingsStore
    public let onClose: () -> Void

    public init(
        typography: Binding<ReaderTypography>,
        bookId: BookID,
        store: any ReaderSettingsStore,
        onClose: @escaping () -> Void
    ) {
        self._typography = typography
        self.bookId = bookId
        self.store = store
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: RishiSpacing.l) {

                // MARK: Font family

                Text("Font")
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.textPrimary)
                HStack(spacing: RishiSpacing.s) {
                    ForEach(ReaderFontFamily.allCases, id: \.self) { family in
                        familyButton(family)
                    }
                }

                // MARK: Font size

                Text("Size: \(Int(typography.fontSize.points)) pt")
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.textPrimary)
                Slider(
                    value: Binding(
                        get: { typography.fontSize.points },
                        set: { newVal in
                            typography.fontSize = ReaderFontSize(points: newVal)
                            persist()
                        }
                    ),
                    in: ReaderFontSize.min...ReaderFontSize.max,
                    step: 1
                )
                .tint(RishiColor.accent)
                .accessibilityLabel("Font size")

                // MARK: Line height

                Text(String(format: "Line height: %.1f", typography.lineHeight.multiplier))
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.textPrimary)
                Slider(
                    value: Binding(
                        get: { typography.lineHeight.multiplier },
                        set: { newVal in
                            typography.lineHeight = ReaderLineHeight(multiplier: newVal)
                            persist()
                        }
                    ),
                    in: ReaderLineHeight.min...ReaderLineHeight.max,
                    step: 0.1
                )
                .tint(RishiColor.accent)
                .accessibilityLabel("Line height")

                Spacer()
            }
            .padding(RishiSpacing.m)
            .navigationTitle("Typography")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    @ViewBuilder
    private func familyButton(_ family: ReaderFontFamily) -> some View {
        let isSelected = family == typography.fontFamily
        Button {
            typography.fontFamily = family
            persist()
        } label: {
            Text(family.label)
                .font(RishiTypography.body)
                .foregroundStyle(isSelected ? RishiColor.surfaceElevated : RishiColor.textPrimary)
                .padding(.horizontal, RishiSpacing.m)
                .padding(.vertical, RishiSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: RishiRadius.small)
                        .fill(isSelected ? RishiColor.accent : RishiColor.surfaceElevated)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Font \(family.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func persist() {
        let snapshot = typography
        let bookId = self.bookId
        let store = self.store
        Task { await store.setTypography(snapshot, for: bookId) }
    }
}

private final class EPUBTypographyPreviewStore: ReaderSettingsStore, @unchecked Sendable {
    func theme(for bookId: BookID) async -> ReaderTheme { .default }
    func setTheme(_ theme: ReaderTheme, for bookId: BookID) async { }
    func typography(for bookId: BookID) async -> ReaderTypography { .default }
    func setTypography(_ typography: ReaderTypography, for bookId: BookID) async { }
}

private struct EPUBTypographyPickerPreviewHost: View {
    @State var typography: ReaderTypography
    var body: some View {
        EPUBTypographyPicker(
            typography: $typography,
            bookId: UUID(),
            store: EPUBTypographyPreviewStore(),
            onClose: {}
        )
    }
}

#Preview("Defaults") {
    EPUBTypographyPickerPreviewHost(typography: .default)
}

#Preview("Serif large") {
    EPUBTypographyPickerPreviewHost(
        typography: ReaderTypography(
            fontFamily: .serif,
            fontSize: ReaderFontSize(points: 22),
            lineHeight: ReaderLineHeight(multiplier: 1.6)
        )
    )
}

#Preview("Dyslexic compact") {
    EPUBTypographyPickerPreviewHost(
        typography: ReaderTypography(
            fontFamily: .dyslexic,
            fontSize: ReaderFontSize(points: 14),
            lineHeight: ReaderLineHeight(multiplier: 1.2)
        )
    )
}
