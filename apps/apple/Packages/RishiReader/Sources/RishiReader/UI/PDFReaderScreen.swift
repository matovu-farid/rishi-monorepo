import SwiftUI
import RishiCore
import RishiUIKit

/// Top-level SwiftUI screen for reading a PDF.
///
/// Composes:
///   - `PDFReaderView` (UIKit-gated PDFKit wrapper, plan 05-05)
///   - `PDFReaderToolbar` (close + title)
///   - `PDFPageIndicator` (floating page count)
///
/// Layered in later waves:
///   - 05-06 — highlight palette toolbar + selection menu
///   - 05-07 — TOC sheet, theme picker, library integration
///
/// macOS dev-host renders a stub label; Mac Catalyst hits the UIKit branch.
@MainActor
public struct PDFReaderScreen: View {

    private let viewModel: PDFReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chromeVisible: Bool = true

    public init(viewModel: PDFReaderViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            background

            #if canImport(UIKit)
            PDFReaderView(viewModel: viewModel)
                .ignoresSafeArea()
                .onTapGesture {
                    chromeVisible.toggle()
                }
                .rishiAnimation(RishiMotion.standard, reduce: reduceMotion)
            #else
            // Native macOS dev-host stub for compile-only — ship hits the
            // UIKit branch above on iOS + Mac Catalyst.
            Text("PDFReaderView is iOS / Mac Catalyst only")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)
            #endif

            if chromeVisible {
                VStack {
                    PDFReaderToolbar(
                        title: viewModel.book.title,
                        onClose: {
                            Task {
                                await viewModel.flush()
                                dismiss()
                            }
                        }
                    )
                    Spacer()
                    PDFPageIndicator(
                        currentPage: viewModel.pageIndex + 1,
                        totalPages: viewModel.totalPages
                    )
                    .padding(.bottom, RishiSpacing.m)
                }
                .transition(.opacity)
            }
        }
        .task { await viewModel.load() }
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
