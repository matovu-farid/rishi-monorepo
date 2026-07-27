import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Wraps `UIDocumentPickerViewController` so SwiftUI callers can mount the
/// Files-app picker as a sheet. On dismissal, `onPicked(urls)` is invoked
/// on the main actor with the user's selection (empty array on cancel).
///
/// SwiftUI's first-party `.fileImporter(...)` is available but the UIKit
/// path is preferred per FEATURES.md "Files app integration" because:
///   - returns multiple URLs in one call (multi-select)
///   - explicit `asCopy: true` semantics — the system hands us a URL into a
///     temp copy in the app's container, so we never have to maintain a
///     long-lived security-scoped resource on the user's original file
///     (PITFALLS Pitfall 36 / file-import gotcha).
public struct DocumentPickerView: UIViewControllerRepresentable {

    public let onPicked: @MainActor ([URL]) -> Void

    public init(onPicked: @escaping @MainActor ([URL]) -> Void) {
        self.onPicked = onPicked
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .mobi and .azw3 have no system UTType — users on iOS pick those via
        // "All files" / the share-sheet from the Mail or Files app.
        let types: [UTType] = [
            .epub,
            .pdf,
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    public final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: @MainActor ([URL]) -> Void

        init(onPicked: @escaping @MainActor ([URL]) -> Void) {
            self.onPicked = onPicked
        }

        public func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            Log.event(
                "library.import.document_picker.success",
                data: [
                    "count": String(urls.count),
                    "files": urls.map(\.lastPathComponent).joined(separator: ",")
                ]
            )
            // UIKit delegate callbacks already arrive on the main thread,
            // but the @MainActor isolation is satisfied explicitly via Task.
            let snapshot = urls
            // KEEP: UIKit delegate callback; explicit @MainActor hop to
            // satisfy the @MainActor isolation on `onPicked` from a
            // non-isolated NSObject method.
            Task { @MainActor in onPicked(snapshot) }
        }

        public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Log.event("library.import.document_picker.cancelled", level: .warning)
            // KEEP: UIKit delegate callback; explicit @MainActor hop.
            Task { @MainActor in onPicked([]) }
        }
    }
}

#Preview("Document picker - sheet host") {
    DocumentPickerPreviewHost()
}

#Preview("Document picker - dark") {
    DocumentPickerPreviewHost()
        .preferredColorScheme(.dark)
}

private struct DocumentPickerPreviewHost: View {
    @State private var isPresented = false
    @State private var lastSelection: [URL] = []

    var body: some View {
        VStack(spacing: 16) {
            Button("Open Document Picker") {
                isPresented = true
            }
            .buttonStyle(.borderedProminent)

            if lastSelection.isEmpty {
                Text("No files picked yet")
            } else {
                VStack(alignment: .leading) {
                    ForEach(lastSelection, id: \.self) { url in
                        Text(url.lastPathComponent)
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $isPresented) {
            DocumentPickerView { urls in
                lastSelection = urls
                isPresented = false
            }
        }
    }
}

#else

/// Dev-host (macOS / non-UIKit) shell so the type still compiles under
/// `swift test`. Real callers only mount this view from iOS / Mac Catalyst.
public struct DocumentPickerView: View {
    public let onPicked: ([URL]) -> Void

    public init(onPicked: @escaping ([URL]) -> Void) {
        self.onPicked = onPicked
    }

    public var body: some View {
        Text("Document Picker is only available on iOS / Mac Catalyst")
    }
}

#Preview("Document picker - macOS stub") {
    DocumentPickerView { _ in }
        .padding()
}

#endif
