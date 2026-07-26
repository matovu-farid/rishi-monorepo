import SwiftUI


/// Mac Catalyst presentation host for the reader's content panels (TOC,
/// theme/typography pickers, highlight-note editor).
///
/// On iOS these panels are shown with a native `.sheet`, which tears down
/// cleanly when its bound state is set to nil. On Mac Catalyst the same
/// `.sheet` is bridged to a UIKit form-sheet ("popup"); setting the bound
/// state to nil updates SwiftUI's state but does NOT reliably dismiss the
/// underlying UIKit modal, so the panel lingers until an unrelated
/// re-render forces it away. Presenting the panel as an in-body SwiftUI
/// overlay instead avoids the UIKit modal entirely: showing/hiding is pure
/// view-tree diffing (the same mechanism the TTS player + page-indicator
/// overlays already use reliably on Mac), so dismissal is immediate.
struct ReaderModalOverlay<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            // Dimmed scrim — tap outside the card to dismiss, mirroring the
            // form-sheet dimming the panel replaces.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            content()
                .frame(maxWidth: 460, maxHeight: 620)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: RishiRadius.large, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: RishiRadius.large, style: .continuous))
                .shadow(radius: RishiSpacing.m)
                .padding(RishiSpacing.xl)
        }
    }
}

extension View {
    /// Presents a reader content panel from an `Identifiable` item binding.
    /// iOS uses a native `.sheet`; Mac Catalyst uses a SwiftUI overlay so the
    /// panel dismisses reliably (see ``ReaderModalOverlay``). The `content`
    /// closure is identical on both platforms.
    @ViewBuilder
    func readerSheet<Item: Identifiable, SheetContent: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        overlay {
            if let value = item.wrappedValue {
                ReaderModalOverlay(onDismiss: { item.wrappedValue = nil }) {
                    content(value)
                }
            }
        }
        #else
        sheet(item: item, content: content)
        #endif
    }
}
