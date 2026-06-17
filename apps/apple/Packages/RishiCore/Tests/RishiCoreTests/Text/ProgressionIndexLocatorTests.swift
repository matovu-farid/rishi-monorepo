//
//  ProgressionIndexLocatorTests.swift
//  RishiCoreTests
//
//  Focused coverage for the unit extracted out of ParagraphChunker in plan
//  34-12. The full behavior is also exercised through
//  `ParagraphChunker.startIndex(...)`; these assert the extracted type directly.
//

import Testing
@testable import RishiCore

@Suite("ProgressionIndexLocator.startIndex(forProgression:count:)")
struct ProgressionIndexLocatorTests {

    @Test("progression 0 / nil / negative all start at paragraph 0")
    func startStaysAtZeroForResourceStart() {
        #expect(ProgressionIndexLocator.startIndex(forProgression: 0, count: 10) == 0)
        #expect(ProgressionIndexLocator.startIndex(forProgression: nil, count: 10) == 0)
        #expect(ProgressionIndexLocator.startIndex(forProgression: -0.5, count: 10) == 0)
    }

    @Test("mid-resource progression maps to floor(progression * count)")
    func midProgressionFloors() {
        #expect(ProgressionIndexLocator.startIndex(forProgression: 0.25, count: 8) == 2)
        #expect(ProgressionIndexLocator.startIndex(forProgression: 0.5, count: 8) == 4)
        #expect(ProgressionIndexLocator.startIndex(forProgression: 0.99, count: 8) == 7)
    }

    @Test("progression >= 1 clamps to the last paragraph, never out of range")
    func fullProgressionClampsToLast() {
        #expect(ProgressionIndexLocator.startIndex(forProgression: 1.0, count: 8) == 7)
        #expect(ProgressionIndexLocator.startIndex(forProgression: 5.0, count: 8) == 7)
    }

    @Test("empty resource yields 0 (no crash)")
    func emptyResourceIsZero() {
        #expect(ProgressionIndexLocator.startIndex(forProgression: 0.5, count: 0) == 0)
    }

    @Test("non-finite progression (nan/inf) degrades to 0")
    func nonFiniteIsZero() {
        #expect(ProgressionIndexLocator.startIndex(forProgression: .nan, count: 8) == 0)
        #expect(ProgressionIndexLocator.startIndex(forProgression: .infinity, count: 8) == 0)
    }

    @Test("ParagraphChunker.startIndex forwards to the same result")
    func chunkerForwardsToLocator() {
        for progression in [nil, 0.0, 0.25, 0.5, 0.99, 1.0, 5.0, Double.nan] {
            for count in [0, 1, 8, 100] {
                #expect(
                    ParagraphChunker.startIndex(forProgression: progression, count: count)
                        == ProgressionIndexLocator.startIndex(forProgression: progression, count: count)
                )
            }
        }
    }
}
