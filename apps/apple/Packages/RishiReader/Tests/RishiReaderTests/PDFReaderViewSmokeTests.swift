import Testing
import Foundation
import PDFKit
import RishiCore
import RishiTesting
@testable import RishiReader

@Suite("PDFReaderView smoke", .serialized)
struct PDFReaderViewSmokeTests {

    @Test("VM-driven document property is reachable after load")
    func vmDocumentReachable() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent("smoke-\(UUID().uuidString).pdf")
        try FixtureBuilders.writeMultiPagePDF(to: url, pageCount: 3, withOutline: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let book = Book(userId: UUID(), title: "Smoke", formatType: .pdf, fileURL: "x")
        let vm = PDFReaderViewModel(
            book: book, userId: UUID(),
            documentURL: url, positionStore: InMemoryPositionStore()
        )
        await vm.load()
        #expect(vm.document != nil)
        #expect(vm.totalPages == 3)

        #if canImport(UIKit)
        // PDFReaderView is a value type — instantiating it does not touch
        // UIKit (no makeUIView until the SwiftUI host adds it to a hierarchy),
        // so we can construct it in a unit-test environment to verify the
        // initializer + Bindable wiring compile against the VM contract.
        let view = PDFReaderView(viewModel: vm)
        _ = view  // suppress unused-warning
        #endif
    }
}
