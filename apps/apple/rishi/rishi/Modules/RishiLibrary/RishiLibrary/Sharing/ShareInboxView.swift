import SwiftUI

public struct ShareInboxView: View {
    private let service: SharePackageService
    private let onAccepted: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var shares: [SharePreview] = []
    @State private var loading = true
    @State private var acceptingID: String?
    @State private var errorMessage: String?
    @State private var confirmationMessage: String?

    public init(
        service: SharePackageService,
        onAccepted: @escaping () async -> Void = {}
    ) {
        self.service = service
        self.onAccepted = onAccepted
    }

    public var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if shares.isEmpty {
                    ContentUnavailableView(
                        "No Shared Books",
                        systemImage: "tray",
                        description: Text("Books shared with your username will appear here.")
                    )
                } else {
                    List(shares) { share in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("From \(share.senderName)").font(.headline)
                            Text("\(share.count) \(share.count == 1 ? "book" : "books")")
                                .foregroundStyle(.secondary)
                            Text("Expires \(share.expiresAt, style: .relative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(share.items.prefix(3)) { item in
                                Text(item.title).font(.subheadline)
                            }
                            Button(acceptingID == share.id ? "Accepting…" : "Accept all") {
                                accept(share)
                            }
                            .disabled(acceptingID != nil)
                            .accessibilityLabel("Accept all shared books from \(share.senderName)")
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Shared with You")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .alert("Sharing", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Books imported", isPresented: Binding(
                get: { confirmationMessage != nil },
                set: { if !$0 { confirmationMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(confirmationMessage ?? "")
            }
        }
    }

    private func load() async {
        do {
            let result = try await service.inbox()
            await MainActor.run {
                shares = result
                loading = false
            }
        } catch {
            await MainActor.run {
                loading = false
                errorMessage = "Could not load shared books."
            }
        }
    }

    private func accept(_ share: SharePreview) {
        acceptingID = share.id
        Task {
            do {
                let importedCount = try await service.accept(packageID: share.id)
                await onAccepted()
                await MainActor.run {
                    shares.removeAll { $0.id == share.id }
                    acceptingID = nil
                    confirmationMessage = "Imported \(importedCount) \(importedCount == 1 ? "book" : "books")."
                }
            } catch {
                await MainActor.run {
                    acceptingID = nil
                    errorMessage = "Could not import these books. You can try again."
                }
            }
        }
    }
}
