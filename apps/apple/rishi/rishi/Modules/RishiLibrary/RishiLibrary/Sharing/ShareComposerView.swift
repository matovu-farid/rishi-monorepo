import SwiftUI

public struct ShareComposerView: View {
    private let service: SharePackageService
    private let bookIDs: [BookID]
    private let kind: ShareKind
    private let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var access: ShareAccess = .oneTime
    @State private var response: SharePackageResponse?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var idempotencyKeys: [String: String] = [:]
    @State private var loadGeneration = UUID()

    private var preparedLinkTaskID: String {
        [kind.rawValue, access.rawValue, bookIDs.map(\.uuidString).sorted().joined(separator: ",")]
            .joined(separator: "|")
    }

    public init(
        service: SharePackageService,
        bookIDs: [BookID],
        kind: ShareKind,
        onCompleted: @escaping () -> Void = {}
    ) {
        self.service = service
        self.bookIDs = bookIDs
        self.kind = kind
        self.onCompleted = onCompleted
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Books") {
                    Text("\(bookIDs.count) \(bookIDs.count == 1 ? "book" : "books")")
                        .accessibilityIdentifier("share-book-count")
                }

                Section("Link access") {
                    Picker("Link type", selection: $access) {
                        Text("One-time").tag(ShareAccess.oneTime)
                        Text("Public").tag(ShareAccess.public)
                    }
                    .pickerStyle(.segmented)
                    Text(access == .oneTime
                        ? "The first person who opens this link can add the book. Later attempts will be told that the link has already been used."
                        : "Anyone with this link can add the book to their library.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if let link = response?.link, let url = URL(string: link) {
                        ShareLink(item: url) {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("share-link-button")
                    } else if kind == .single && isWorking {
                        Label("Loading prepared link…", systemImage: "link")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("share-link-loading")
                    } else {
                        Button(kind == .single ? "Try Again" : "Create Share Link") { create() }
                        .disabled(isWorking)
                    }
                } footer: {
                    Text("The link expires in seven days.")
                }

                if let preview = response?.preview {
                    Section("Ready to share") {
                        Text("From \(preview.senderName) · \(preview.count) books")
                        ForEach(preview.items) { item in
                            VStack(alignment: .leading) {
                                Text(item.title)
                                if let author = item.author, !author.isEmpty {
                                    Text(author).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let message = errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Share Books")
            .task(id: preparedLinkTaskID) {
                guard kind == .single else { return }
                let generation = UUID()
                await MainActor.run { loadGeneration = generation }
                loadPreparedLink(for: access, generation: generation)
            }
            .onChange(of: access) { _, newAccess in
                response = nil
                errorMessage = nil
                loadGeneration = UUID()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onCompleted()
                        dismiss()
                    }
                }
            }
            .overlay { if isWorking { ProgressView() } }
        }
    }

    private func create() {
        isWorking = true
        errorMessage = nil
        let requestedAccess = access
        let requestedGeneration = loadGeneration
        let requestScope = [access.rawValue, kind.rawValue, bookIDs.map(\.uuidString).sorted().joined(separator: ",")].joined(separator: "|")
        let idempotencyKey = idempotencyKeys[requestScope] ?? UUID().uuidString
        idempotencyKeys[requestScope] = idempotencyKey
        Task {
            do {
                let result = try await service.createShare(
                    bookIDs: bookIDs,
                    kind: kind,
                    access: access,
                    idempotencyKey: idempotencyKey
                )
                await MainActor.run {
                    guard requestedAccess == access, requestedGeneration == loadGeneration else { return }
                    response = result
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    guard requestedAccess == access, requestedGeneration == loadGeneration else { return }
                    if case let RishiError.network(code, _) = error,
                       code == "SHARE_BOOK_NOT_READY" {
                        errorMessage = "Some selected books are not synced or use an unsupported format. Sync them and try again."
                    } else {
                        errorMessage = "Could not create the share. Please sync and try again."
                    }
                    isWorking = false
                }
            }
        }
    }

    private func loadPreparedLink(for requestedAccess: ShareAccess, generation: UUID) {
        isWorking = true
        Task {
            do {
                let result = try await service.createShare(
                    bookIDs: bookIDs,
                    kind: .single,
                    access: requestedAccess
                )
                await MainActor.run {
                    guard generation == loadGeneration, requestedAccess == access else { return }
                    response = result
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    guard generation == loadGeneration, requestedAccess == access else { return }
                    errorMessage = "Could not prepare the share link. Try again."
                    isWorking = false
                }
            }
        }
    }
}
