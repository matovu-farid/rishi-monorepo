import SwiftUI

public struct ShareComposerView: View {
    private let service: SharePackageService
    private let bookIDs: [BookID]
    private let kind: ShareKind
    private let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var response: SharePackageResponse?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var idempotencyKeys: [String: String] = [:]

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

                Section("Share with a Rishi username") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Recipient username")
                    Button("Share with Username") {
                        create(delivery: .username)
                    }
                    .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                }

                Section {
                    if let link = response?.link, let url = URL(string: link) {
                        ShareLink(item: url) {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("share-link-button")
                    } else {
                        Button("Create Share Link") {
                            create(delivery: .link)
                        }
                        .disabled(isWorking)
                    }
                } footer: {
                    Text("The link can be claimed once and expires in seven days.")
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

    private func create(delivery: ShareDelivery) {
        isWorking = true
        errorMessage = nil
        let recipient = delivery == .username
            ? username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : ""
        let requestScope = [delivery.rawValue, recipient, kind.rawValue, bookIDs.map(\.uuidString).sorted().joined(separator: ",")].joined(separator: "|")
        let idempotencyKey = idempotencyKeys[requestScope] ?? UUID().uuidString
        idempotencyKeys[requestScope] = idempotencyKey
        Task {
            do {
                let result = try await service.createShare(
                    bookIDs: bookIDs,
                    kind: kind,
                    delivery: delivery,
                    recipientUsername: delivery == .username ? username : nil,
                    idempotencyKey: idempotencyKey
                )
                await MainActor.run {
                    response = result
                    isWorking = false
                }
            } catch {
                await MainActor.run {
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
}
