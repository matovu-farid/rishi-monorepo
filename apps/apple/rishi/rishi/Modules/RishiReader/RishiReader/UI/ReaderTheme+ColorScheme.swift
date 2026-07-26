import SwiftUI

extension ReaderTheme {
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .matchDevice: return nil
        case .dark: return .dark
        case .light, .sepia: return .light
        }
    }
}
