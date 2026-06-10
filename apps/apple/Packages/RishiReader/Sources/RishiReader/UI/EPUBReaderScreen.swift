import SwiftUI
import RishiCore
import RishiUIKit

/// Top-level SwiftUI screen for reading an EPUB.
///
/// Composes:
///   - ``EPUBReaderView`` (UIKit-gated Readium navigator wrapper)
///   - ``EPUBReaderToolbar`` (close + title + TOC/typography/theme buttons)
///   - ``EPUBProgressIndicator`` (floating bottom percent chip)
///
/// Behavior parallels ``PDFReaderScreen``:
///   - ZStack(reader, chrome) with tap-to-toggle chrome.
///   - On `.task`, calls `await viewModel.load()` and hydrates theme +
///     typography from the (optional) ``ReaderSettingsStore``.
///   - On dismiss, calls `await viewModel.flush()` BEFORE `dismiss()` so
///     the final locator persists.
///
/// TOC / theme / typography sheet plumbing lands in Plan 06-06. The
/// closures are intentionally empty placeholders here; the toolbar already
/// hides them behind `isPublicationLoaded` so users can't fire blank UI.
///
/// On macOS dev hosts (non-Catalyst, no UIKit), the reader area renders a
/// compile-only stub label — ship targets always hit the UIKit branch.
@MainActor
public struct EPUBReaderScreen: View {

    private let viewModel: EPUBReaderViewModel
    /// Optional injection: when `nil`, the screen runs against an ephemeral
    /// settings store (no persistence). Production wiring in
    /// `AppDependencies` passes a `UserDefaultsReaderSettingsStore`.
    private let readerSettingsStore: (any ReaderSettingsStore)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chromeVisible: Bool = true

    public init(
        viewModel: EPUBReaderViewModel,
        readerSettingsStore: (any ReaderSettingsStore)? = nil
    ) {
        self.viewModel = viewModel
        self.readerSettingsStore = readerSettingsStore
    }

    public var body: some View {
        ZStack {
            background

            #if canImport(UIKit)
            EPUBReaderView(viewModel: viewModel)
                .ignoresSafeArea()
                .onTapGesture {
                    chromeVisible.toggle()
                }
                .rishiAnimation(RishiMotion.standard, reduce: reduceMotion)
            #else
            // macOS dev-host stub for compile-only — ship hits the UIKit
            // branch above on iOS + Mac Catalyst.
            Text("EPUB reader requires iOS or Mac Catalyst")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)
            #endif

            if chromeVisible {
                VStack {
                    EPUBReaderToolbar(
                        title: viewModel.title.isEmpty ? viewModel.book.title : viewModel.title,
                        isPublicationLoaded: viewModel.publication != nil,
                        onClose: {
                            Task {
                                await viewModel.flush()
                                dismiss()
                            }
                        },
                        onShowTOC: { /* wired in 06-06 */ },
                        onShowTheme: { /* wired in 06-06 */ },
                        onShowTypography: { /* wired in 06-06 */ }
                    )
                    Spacer()
                    EPUBProgressIndicator(
                        totalProgression: viewModel.latestLocator?.locations.totalProgression
                    )
                    .padding(.bottom, RishiSpacing.m)
                }
                .transition(.opacity)
            }
        }
        .task {
            await viewModel.load()
            if let settings = readerSettingsStore {
                viewModel.theme = await settings.theme(for: viewModel.book.id)
                viewModel.typography = await settings.typography(for: viewModel.book.id)
            }
        }
        #if !os(macOS)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    private var background: some View {
        switch viewModel.theme {
        case .light: RishiColor.readerBackgroundLight.ignoresSafeArea()
        case .sepia: RishiColor.readerBackgroundSepia.ignoresSafeArea()
        case .dark:  RishiColor.readerBackgroundDark.ignoresSafeArea()
        }
    }
}
