import CoreGraphics
import RishiReader
import SwiftUI

#if targetEnvironment(macCatalyst)
import UIKit

enum PDFReaderWindowLayout {
    case singlePage
    case continuous
    case twoPage

    init(setting: PDFViewModeSetting) {
        switch setting {
        case .twoPage: self = .twoPage
        case .continuous: self = .continuous
        case .singlePage: self = .singlePage
        case .automatic: self = .continuous
        }
    }
}

@MainActor
protocol PDFReaderWindowSizing {
    func applyInitialSize(for layout: PDFReaderWindowLayout)
    func resize(for layout: PDFReaderWindowLayout)
}

@MainActor
final class CatalystPDFReaderWindowSizing: PDFReaderWindowSizing {
    static let singlePageSize = CGSize(width: 820, height: 1080)
    static let continuousSize = CGSize(width: 1100, height: 900)
    static let twoPageSize = CGSize(width: 1440, height: 960)

    private let scene: UIWindowScene?

    init(scene: UIWindowScene? = nil) {
        self.scene = scene
    }

    func applyInitialSize(for layout: PDFReaderWindowLayout) {
        resize(for: layout)
    }

    func resize(for layout: PDFReaderWindowLayout) {
        guard let windowScene = scene ?? activeWindowScene else { return }
        guard let window = windowScene.windows.first(where: { $0.isKeyWindow })
            ?? windowScene.windows.first else { return }

        let target: CGSize
        switch layout {
        case .continuous: target = Self.continuousSize
        case .singlePage: target = Self.singlePageSize
        case .twoPage: target = Self.twoPageSize
        }
        let minimum = windowScene.sizeRestrictions?.minimumSize ?? .zero
        let size = CGSize(
            width: max(target.width, minimum.width),
            height: max(target.height, minimum.height)
        )
        var frame = window.frame
        frame.size = size
        frame.origin.x = max(frame.origin.x, 0)
        frame.origin.y = max(frame.origin.y, 0)
        window.frame = frame
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

#endif
