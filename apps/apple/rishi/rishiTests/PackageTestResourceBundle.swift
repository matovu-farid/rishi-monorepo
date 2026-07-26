@testable import rishi
import Foundation

enum PackageTestResourceBundle {
    static let bundle = Bundle(for: PackageTestBundleToken.self)
}

private final class PackageTestBundleToken {}
