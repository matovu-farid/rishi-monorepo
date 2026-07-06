import SwiftUI
import RishiCore

/// SwiftUI view modifier that wires `.dropDestination(for: URL.self)` to the
/// shared `ImportCoordinator`. Filters incoming URLs by extension up-front so
/// the visual drop indicator only highlights when at least one item is a
/// supported book file.
struct LibraryDropDestination: ViewModifier {

    public let coordinator: ImportCoordinator
    public let onImported: @MainActor (_ outcomes: [ImportCoordinator.ImportOutcome]) -> Void

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
        content.dropDestination(for: URL.self) { urls, _ in
            let supported = ImportCoordinator.filterSupported(urls)
            guard !supported.isEmpty else { return false }
            // KEEP: Phase 20 audit — `importBooks` is actor-bound, so the
            // body already runs off the MainActor caller via the `await`
            // suspension. A bare `Task { }` keeps the fire-and-forget shape
            // while preserving cancellation / priority inheritance from the
            // calling SwiftUI view.
            Task {
                let outcomes = await coordinator.importBooks(supported)
                onImported(outcomes)
            }
            return true
        } isTargeted: { _ in
            // Visual targeting handled by the caller view; no-op here.
        }
    }
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
