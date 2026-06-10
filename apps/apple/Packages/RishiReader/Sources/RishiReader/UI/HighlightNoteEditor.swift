import SwiftUI
import RishiUIKit

/// Modal sheet for attaching / editing a note on a highlight.
///
/// Shown after the user taps "Add Note" in ``HighlightContextMenu`` (the
/// highlight is created first, then the editor edits it). Uses a
/// `NavigationStack` for the standard Save / Cancel toolbar layout.
///
/// All padding / fonts / colors route through RishiUIKit tokens.
public struct HighlightNoteEditor: View {

    @Binding public var note: String
    /// Short excerpt of the highlighted text, displayed as a non-editable
    /// preview at the top of the editor.
    public let snippet: String
    public let onSave: () -> Void
    public let onCancel: () -> Void

    public init(
        note: Binding<String>,
        snippet: String,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._note = note
        self.snippet = snippet
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: RishiSpacing.m) {
                Text(snippet)
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.textSecondary)
                    .padding(RishiSpacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: RishiRadius.small)
                            .fill(RishiColor.surfaceElevated)
                    )

                TextEditor(text: $note)
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary)
                    .padding(RishiSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: RishiRadius.small)
                            .stroke(RishiColor.divider, lineWidth: 1)
                    )
                    .frame(minHeight: 140)

                Spacer()
            }
            .padding(RishiSpacing.m)
            .navigationTitle("Note")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                }
            }
        }
    }
}

private struct HighlightNoteEditorPreviewHost: View {
    @State var note: String
    let snippet: String
    var body: some View {
        HighlightNoteEditor(
            note: $note,
            snippet: snippet,
            onSave: {},
            onCancel: {}
        )
    }
}

#Preview("Empty note") {
    HighlightNoteEditorPreviewHost(
        note: "",
        snippet: "But the Hatter said, 'I want a clean cup: let's all move one place on.'"
    )
}

#Preview("With existing note") {
    HighlightNoteEditorPreviewHost(
        note: "Reminds me of the Mad Tea-Party — circular reasoning at work.",
        snippet: "But the Hatter said, 'I want a clean cup: let's all move one place on.'"
    )
}

#Preview("Long snippet") {
    HighlightNoteEditorPreviewHost(
        note: "",
        snippet: "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness, it was the epoch of belief, it was the epoch of incredulity."
    )
}
