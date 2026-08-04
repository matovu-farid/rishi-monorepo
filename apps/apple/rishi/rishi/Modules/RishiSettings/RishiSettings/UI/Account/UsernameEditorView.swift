import SwiftUI

public struct UsernameEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let onSave: (String) async throws -> User

    public init(
        username: String?,
        onSave: @escaping (String) async throws -> User
    ) {
        _draft = State(initialValue: username ?? "")
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings-account-username-editor")
                } footer: {
                    Text("3–30 lowercase letters, numbers, or underscores.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settings-account-username-error")
                    }
                }
            }
            .navigationTitle("Username")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView()
                }
            }
        }
    }

    private func save() async {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isSaving else { return }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            _ = try await onSave(value)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
