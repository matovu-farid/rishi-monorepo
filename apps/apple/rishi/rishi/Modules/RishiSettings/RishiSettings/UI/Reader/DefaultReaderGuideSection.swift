import SwiftUI

struct DefaultReaderGuideSection: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("EPUB and PDF are separate choices. Set Rishi for each file type you want it to open.")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary)

                instruction(
                    title: "iPhone and iPad with iOS or iPadOS 26 or later",
                    detail: "In Files, touch and hold an EPUB or PDF, tap Get Info, then Always Open With and choose Rishi. Choose whether this applies to the selected file or all files of that type. Repeat for the other file type if you want."
                )

                instruction(
                    title: "iPhone and iPad with iOS or iPadOS 18.4–25",
                    detail: "In Files, use Share or Open in Rishi for each EPUB or PDF you want to read. These versions do not offer the Always Open With choice."
                )

                instruction(
                    title: "Mac",
                    detail: "In Finder, select an EPUB, choose File > Get Info, set Open with to Rishi, then choose Change All. Repeat with a PDF to set its default separately."
                )
            }
            .padding(.vertical, 4)
        } header: {
            Text("Make Rishi your default reader")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }

    private func instruction(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(RishiTypography.body.weight(.semibold))
                .foregroundStyle(RishiColor.textPrimary)
            Text(detail)
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textSecondary)
        }
    }
}
