import Foundation

#if canImport(UIKit)
import UIKit
#endif

public enum UsernameClipboard {
    public static func copy(_ username: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = username
#endif
    }
}
