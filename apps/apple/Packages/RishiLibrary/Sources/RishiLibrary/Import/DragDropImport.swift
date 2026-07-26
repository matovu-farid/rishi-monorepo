import SwiftUI
import RishiCore
import RishiUIKit
import UniformTypeIdentifiers

/// SwiftUI view modifier that wires `.dropDestination(for: URL.self)` to the
/// shared `ImportCoordinator`. Filters incoming URLs by extension up-front so
/// the visual drop indicator only highlights when at least one item is a
/// supported book file.
struct LibraryDropDestination: ViewModifier {

    public let coordinator: ImportCoordinator
    public let onImported: @MainActor (_ outcomes: [ImportCoordinator.ImportOutcome]) -> Void

    @State private var isTargeted = false

    public init(
        coordinator: ImportCoordinator,
        onImported: @escaping @MainActor (_ outcomes: [ImportCoordinator.ImportOutcome]) -> Void
    ) {
        self.coordinator = coordinator
        self.onImported = onImported
    }

    public func body(content: Content) -> some View {
        // `URL` conforms to `Transferable` on iOS 16+/macOS 13+/Catalyst 16+,
        // so we can drop in `URL.self` directly — no custom UTType registration
        // required for inter-app drops from Files / Finder.
        ZStack {
            content

            if isTargeted {
                RoundedRectangle(cornerRadius: RishiRadius.large, style: .continuous)
                    .fill(RishiColor.accent.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: RishiRadius.large, style: .continuous)
                            .strokeBorder(
                                RishiColor.accent,
                                style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                            )
                        VStack(spacing: RishiSpacing.s) {
                            Image(systemName: "books.vertical.fill")
                                .font(RishiTypography.titleL)
                            Text("Drop books to import")
                                .font(RishiTypography.titleM)
                            Text("EPUB and PDF files are supported")
                                .font(RishiTypography.body)
                                .foregroundStyle(RishiColor.textSecondary)
                        }
                        .foregroundStyle(RishiColor.accent)
                    }
                    .padding(RishiSpacing.m)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        #if targetEnvironment(macCatalyst)
            .onDrop(
                of: [UTType.fileURL.identifier, UTType.item.identifier],
                isTargeted: $isTargeted
            ) { providers in
                guard !providers.isEmpty else { return false }
                Task {
                    let urls = await Self.urls(from: providers)
                    let supported = ImportCoordinator.filterSupported(urls)
                    guard !supported.isEmpty else { return }
                    let outcomes = await coordinator.importBooks(supported)
                    onImported(outcomes)
                    Self.removeTemporaryCopies(urls)
                }
                return true
            }
        #else
            .dropDestination(for: URL.self) { urls, _ in
                let supported = ImportCoordinator.filterSupported(urls)
                guard !supported.isEmpty else { return false }
                Task {
                    let outcomes = await coordinator.importBooks(supported)
                    onImported(outcomes)
                }
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
        #endif
    }

    #if targetEnvironment(macCatalyst)
        private static func urls(from providers: [NSItemProvider]) async -> [URL] {
            var urls: [URL] = []
            for provider in providers {
                let url = await Self.url(from: provider)
                if let url {
                    urls.append(url)
                }
            }
            return urls
        }

        private static func url(from provider: NSItemProvider) async -> URL? {
            let preferredTypes = [
                UTType.fileURL.identifier,
                UTType.pdf.identifier,
                UTType.item.identifier
            ]
            let typeIdentifiers = preferredTypes.filter {
                provider.registeredTypeIdentifiers.contains($0)
            } + provider.registeredTypeIdentifiers.filter {
                !preferredTypes.contains($0)
            }

            for typeIdentifier in typeIdentifiers {
                let url = await withCheckedContinuation {
                    (continuation: CheckedContinuation<URL?, Never>) in
                    provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) {
                        temporaryURL, _ in
                        guard let temporaryURL else {
                            continuation.resume(returning: nil)
                            return
                        }

                        // Apple deletes the provider URL when this completion
                        // handler returns. Copy it before resuming so the
                        // importer can safely read it asynchronously.
                        let destination = FileManager.default.temporaryDirectory
                            .appendingPathComponent("RishiDrop-\(UUID().uuidString)-\(temporaryURL.lastPathComponent)")
                        do {
                            try FileManager.default.copyItem(at: temporaryURL, to: destination)
                            continuation.resume(returning: destination)
                        } catch {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let url { return url }
            }
            return nil
        }

        private static func removeTemporaryCopies(_ urls: [URL]) {
            for url in urls where url.lastPathComponent.hasPrefix("RishiDrop-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    #endif
}

extension View {
    /// Attach drag-and-drop import to any container (typically the LibraryGrid
    /// root). On iPad accepts inter-app drops from Files split-view; on Mac
    /// Catalyst accepts drops from Finder. No-op on iPhone (the system has no
    /// drop affordance in single-app mode).
    public func libraryDropDestination(
        coordinator: ImportCoordinator,
        onImported: @escaping @MainActor ([ImportCoordinator.ImportOutcome]) -> Void
    ) -> some View {
        modifier(LibraryDropDestination(coordinator: coordinator, onImported: onImported))
    }
}

import RishiUIKit

@MainActor
private enum DragDropPreviewFixtures {
    static let userId: UserID = UUID()

    static func makeCoordinator() -> ImportCoordinator {
        final class EmptyBookStore: BookStore, Sendable {
            func books(for userId: UserID) async throws -> [Book] { [] }
            func book(_ id: BookID) async throws -> Book? { nil }
            func upsert(_ book: Book) async throws {}
            func delete(_ id: BookID) async throws {}
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DragDropPreview-\(UUID().uuidString)", isDirectory: true)
        let storage = BookFileStorage(
            rootURL: tmp,
            bookStore: EmptyBookStore(),
            coverExtractors: [:]
        )
        let capturedUserId = userId
        return ImportCoordinator(
            storage: storage,
            currentUserId: { capturedUserId }
        )
    }
}

private struct DragDropPreviewHost: View {
    let coordinator: ImportCoordinator

    var body: some View {
        VStack(spacing: RishiSpacing.l) {
            Image(systemName: "tray.and.arrow.down")
                .font(RishiTypography.titleXL)
                .foregroundStyle(RishiColor.textMuted)
            Text("Drop EPUB or PDF here")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
            Text("This area accepts inter-app drops from Files or Finder.")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RishiSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RishiColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: RishiRadius.medium, style: .continuous)
                .strokeBorder(RishiColor.divider, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(RishiSpacing.l)
        )
        .libraryDropDestination(coordinator: coordinator) { _ in }
    }
}

#Preview("Drop target - idle") {
    DragDropPreviewHost(coordinator: DragDropPreviewFixtures.makeCoordinator())
        .padding(RishiSpacing.l)
        .background(RishiColor.background)
}

#Preview("Drop target - dark") {
    DragDropPreviewHost(coordinator: DragDropPreviewFixtures.makeCoordinator())
        .padding(RishiSpacing.l)
        .background(RishiColor.background)
        .preferredColorScheme(.dark)
}
