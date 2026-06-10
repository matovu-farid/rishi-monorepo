import Testing
import Foundation
@testable import RishiReader
import RishiCore
import RishiLibrary

@Suite("RishiReader package smoke")
struct PackageSmokeTests {

    @Test("Version string is the scaffold marker")
    func versionStringIsScaffoldMarker() {
        #expect(RishiReader.version == "0.1.0-scaffold")
    }

    @Test("RishiCore Book is reachable from the test target")
    func rishiCoreBookIsReachable() {
        let book = Book(
            userId: UUID(),
            title: "Smoke",
            formatType: .pdf,
            fileURL: "Books/smoke/smoke.pdf"
        )
        #expect(book.title == "Smoke")
        #expect(book.formatType == .pdf)
    }

    @Test("RishiLibrary BookFileStorage type is reachable")
    func rishiLibraryBookFileStorageIsReachable() {
        // We only check the type is linkable — full integration lives in 05-07.
        let typeName = String(describing: BookFileStorage.self)
        #expect(typeName == "BookFileStorage")
    }
}
