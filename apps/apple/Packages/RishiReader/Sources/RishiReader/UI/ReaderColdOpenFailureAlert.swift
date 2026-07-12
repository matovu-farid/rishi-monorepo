import SwiftUI

/// Native cold-open-failure presentation for the reader screens. Replaces the
/// prior custom full-page `ReaderColdOpenFailureOverlay` with a stock SwiftUI
/// `.alert` so a failed `load()` surfaces as a system alert. The only action
/// ("OK") — as well as any other dismissal route (tap-outside, hardware Esc on
/// Mac Catalyst) — invokes `onDismiss`, which the reader screens wire to
/// `@Environment(\.dismiss)` so confirming the alert pops the reader back to
/// the library. Shared by `PDFReaderScreen` and `ReaderScreen`.
extension View {
    /// Presents a native failure alert whenever `reason` is non-nil.
    ///
    /// - Parameters:
    ///   - bookTitle: title shown in the alert heading ("Could not open …").
    ///   - reason: the failure reason; non-nil drives presentation, `nil`
    ///     keeps the alert dismissed.
    ///   - onDismiss: invoked once when the alert is dismissed (OK tapped or
    ///     the binding is otherwise cleared). The reader screens pop to the
    ///     library here.
    func readerColdOpenFailureAlert(
        bookTitle: String,
        reason: String?,
        onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(
            ReaderColdOpenFailureAlertModifier(
                bookTitle: bookTitle,
                reason: reason,
                onDismiss: onDismiss
            )
        )
    }
}

/// Drives a stock `.alert` off a `String?` reason. The `isPresented` binding's
/// setter only ever receives `false` (SwiftUI does not set it to `true`); when
/// it does, we forward to `onDismiss` so the single OK action and any
/// system-driven dismissal both pop the reader.
private struct ReaderColdOpenFailureAlertModifier: ViewModifier {
    let bookTitle: String
    let reason: String?
    let onDismiss: () -> Void

    private var isPresented: Binding<Bool> {
        Binding(
            get: { reason != nil },
            set: { presented in
                if !presented {
                    onDismiss()
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content.alert(
            "Could not open \(bookTitle)",
            isPresented: isPresented,
            presenting: reason
        ) { _ in
            Button("OK") { onDismiss() }
        } message: { reason in
            Text(reason)
        }
    }
}
