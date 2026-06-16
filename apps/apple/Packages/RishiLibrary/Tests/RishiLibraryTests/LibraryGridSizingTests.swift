import Testing
import CoreGraphics
@testable import RishiLibrary

// Locks the fixed-tile contract: every library grid cell is the same size on
// every platform, and the height follows the 2:3 book-cover proportion. This
// is what keeps a single cover from expanding to fill a wide Mac window.
@Suite("LibraryGrid tile sizing")
struct LibraryGridSizingTests {

    @Test("Tile height is the 2:3 portrait of its fixed width")
    func tileHeightIsTwoThirdsPortrait() {
        #expect(LibraryGrid.coverHeight == LibraryGrid.coverWidth * 1.5)
    }

    @Test("Tile width is a fixed, positive constant")
    func tileWidthIsFixedPositive() {
        #expect(LibraryGrid.coverWidth == 150)
    }
}
