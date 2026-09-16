@testable import rishi
import Foundation
import Testing


@Suite("DeterministicBookID")
struct DeterministicBookIDTests {

    @Test func sameInputsProduceEqualNonNilId() {
        let a = DeterministicBookID.make(title: "Alice in Wonderland", author: "Lewis Carroll", format: .epub)
        let b = DeterministicBookID.make(title: "Alice in Wonderland", author: "Lewis Carroll", format: .epub)
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func caseAndWhitespaceDifferencesCollapseToSameId() {
        let canonical = DeterministicBookID.make(title: "Alice in Wonderland", author: "Lewis Carroll", format: .epub)
        let noisyTitle = DeterministicBookID.make(title: "  ALICE   in   Wonderland ", author: "Lewis Carroll", format: .epub)
        let noisyAuthor = DeterministicBookID.make(title: "Alice in Wonderland", author: "  lewis   CARROLL ", format: .epub)
        #expect(noisyTitle == canonical)
        #expect(noisyAuthor == canonical)
    }

    @Test func differentFormatProducesDifferentId() {
        let epub = DeterministicBookID.make(title: "Alice in Wonderland", author: "Lewis Carroll", format: .epub)
        let pdf = DeterministicBookID.make(title: "Alice in Wonderland", author: "Lewis Carroll", format: .pdf)
        #expect(epub != nil)
        #expect(pdf != nil)
        #expect(epub != pdf)
    }

    @Test func differentAuthorProducesDifferentId() {
        let carroll = DeterministicBookID.make(title: "Alice in Wonderland", author: "Lewis Carroll", format: .epub)
        let other = DeterministicBookID.make(title: "Alice in Wonderland", author: "Someone Else", format: .epub)
        #expect(carroll != other)
    }

    @Test func nilOrEmptyTitleReturnsNil() {
        #expect(DeterministicBookID.make(title: nil, author: "Lewis Carroll", format: .epub) == nil)
        #expect(DeterministicBookID.make(title: "", author: "Lewis Carroll", format: .epub) == nil)
        #expect(DeterministicBookID.make(title: "   \t  ", author: "Lewis Carroll", format: .epub) == nil)
    }

    @Test func producedIdIsValidVersion5UUID() {
        let id = DeterministicBookID.make(title: "Alice in Wonderland", author: "Lewis Carroll", format: .epub)
        #expect(id != nil)
        guard let id else { return }
        #expect((id.uuid.6 & 0xF0) == 0x50)   // version 5
        #expect((id.uuid.8 & 0xC0) == 0x80)   // RFC 4122 variant
    }
}
