@testable import rishi
//
//  PageTextTests.swift
//  RishiCoreTests — Phase 27 plan 27-01
//
//  Type-shape tests for PageText / TextItem. These pin the public surface
//  used downstream by Phase 27-04 (RepetitionFooterStrategy) and 27-05
//  (FootnoteDetector), both of which live in RishiCore and read these
//  values produced by PDFLayoutExtractor in RishiReader.
//

import Testing
import Foundation
import CoreGraphics


@Suite("PageText / TextItem")
struct PageTextTests {

    @Test("TextItem stores text, frame, and fontSize verbatim")
    func textItemStoresFields() {
        let item = TextItem(
            text: "Hello",
            frame: CGRect(x: 1, y: 2, width: 3, height: 4),
            fontSize: 12
        )
        #expect(item.text == "Hello")
        #expect(item.frame == CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(item.fontSize == 12)
    }

    @Test("PageText stores pageIndex, frame, and items")
    func pageTextStoresFields() {
        let item = TextItem(
            text: "Body",
            frame: CGRect(x: 0, y: 100, width: 50, height: 12),
            fontSize: 12
        )
        let page = PageText(
            pageIndex: 7,
            frame: CGRect(x: 0, y: 0, width: 240, height: 320),
            items: [item]
        )
        #expect(page.pageIndex == 7)
        #expect(page.frame.width == 240)
        #expect(page.frame.height == 320)
        #expect(page.items.count == 1)
        #expect(page.items.first?.text == "Body")
    }

    @Test("TextItem and PageText are Equatable")
    func equality() {
        let a = TextItem(text: "x", frame: .zero, fontSize: 10)
        let b = TextItem(text: "x", frame: .zero, fontSize: 10)
        let c = TextItem(text: "y", frame: .zero, fontSize: 10)
        #expect(a == b)
        #expect(a != c)

        let p1 = PageText(pageIndex: 0, frame: .zero, items: [a])
        let p2 = PageText(pageIndex: 0, frame: .zero, items: [b])
        let p3 = PageText(pageIndex: 1, frame: .zero, items: [a])
        #expect(p1 == p2)
        #expect(p1 != p3)
    }

    @Test("TextItem and PageText are Sendable (compile-time check)")
    func sendable() async {
        let item = TextItem(text: "s", frame: .zero, fontSize: 11)
        let page = PageText(pageIndex: 0, frame: .zero, items: [item])
        // Capturing into a detached Task requires Sendable conformance.
        await Task.detached {
            _ = item
            _ = page
        }.value
    }
}
