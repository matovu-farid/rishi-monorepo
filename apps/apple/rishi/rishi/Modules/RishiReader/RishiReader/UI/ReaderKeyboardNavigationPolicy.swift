#if canImport(UIKit)
import ReadiumNavigator

enum ReaderKeyboardNavigationAction: Equatable {
    case pageForward
    case pageBackward
    case scrollUp
    case scrollDown
    case consume
    case passThrough
}

enum ReaderKeyboardNavigationPolicy {
    static func showsPDFViewModeMenu(isPDF: Bool) -> Bool {
        isPDF
    }

    static func action(
        for key: Key,
        isPDF: Bool,
        pdfViewMode: PDFViewModeSetting
    ) -> ReaderKeyboardNavigationAction {
        if !isPDF {
            switch key {
            case .arrowLeft: return .pageBackward
            case .arrowRight: return .pageForward
            default: return .passThrough
            }
        }

        switch pdfViewMode {
        case .automatic, .continuous:
            switch key {
            case .arrowUp: return .scrollUp
            case .arrowDown: return .scrollDown
            case .arrowLeft, .arrowRight: return .consume
            default: return .passThrough
            }
        case .singlePage, .twoPage:
            switch key {
            case .arrowLeft: return .pageBackward
            case .arrowRight: return .pageForward
            default: return .passThrough
            }
        }
    }
}
#endif
