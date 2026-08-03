@testable import rishi
import Testing
import CoreGraphics


// Locks the library grid's fixed-width contract. Cover height is intentionally
// derived from each cover's aspect ratio.
@Suite("LibraryGrid tile sizing")
struct LibraryGridSizingTests {

    @Test("Tile width is a fixed, positive constant")
    func tileWidthIsFixedPositive() {
        #expect(LibraryGrid.coverWidth == 150)
    }
}
