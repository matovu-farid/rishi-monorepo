@testable import rishi
//


//

//






import Testing
import Foundation

@Suite("ReaderPositionSyncBinding signpost instrumentation")
struct PositionSyncBindingSignpostTests {

    

    private static func bindingSource(_ name: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let rishiTestsDir = testFile.deletingLastPathComponent()
        let projectDir = rishiTestsDir.deletingLastPathComponent()
        let readerDir = projectDir.appendingPathComponent("rishi/Reader", isDirectory: true)
        let fileURL = readerDir.appendingPathComponent(name)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    

    @Test("Reader binding imports os.signpost + declares positionSyncSignposter")
    func test_readerBindingDeclaresSignposter() throws {
        let source = try Self.bindingSource("ReaderPositionSyncBinding.swift")
        #expect(source.contains("import os.signpost"))
        #expect(source.contains("OSSignposter("))
        #expect(source.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(source.contains("category: \"position-sync\""))
    }

    @Test("Reader binding wraps poll body with begin/endInterval")
    func test_readerBindingEmitsSignpost() throws {
        let source = try Self.bindingSource("ReaderPositionSyncBinding.swift")
        #expect(source.contains("reader.position.poll.tick"))
        #expect(source.contains("beginInterval"))
        #expect(source.contains("endInterval"))
    }

    @Test("Reader binding preserves the 250ms poll cadence")
    func test_pollCadencePreserved() throws {
        let source = try Self.bindingSource("ReaderPositionSyncBinding.swift")
        #expect(source.contains("250_000_000"))
    }
}
