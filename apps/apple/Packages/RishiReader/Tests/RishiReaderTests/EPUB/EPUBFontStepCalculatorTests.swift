import Testing
import Foundation
@testable import RishiReader

/// Behavior tests for the font-step math extracted from ``EPUBReaderScreen``
/// (Plan 34-03, SRP). Pure logic — no Readium / UIKit dependency, so it runs
/// on every host.
@Suite("EPUB font-step calculator")
struct EPUBFontStepCalculatorTests {

    @Test("Positive delta increases size by pointsPerStep per step")
    func positiveDelta() {
        let start = ReaderFontSize(points: 16)
        let stepped = EPUBFontStepCalculator.step(from: start, delta: 1)
        #expect(stepped.points == 16 + EPUBFontStepCalculator.pointsPerStep)
    }

    @Test("Negative delta decreases size by pointsPerStep per step")
    func negativeDelta() {
        let start = ReaderFontSize(points: 20)
        let stepped = EPUBFontStepCalculator.step(from: start, delta: -1)
        #expect(stepped.points == 20 - EPUBFontStepCalculator.pointsPerStep)
    }

    @Test("Multi-step delta scales by the step count")
    func multiStep() {
        let start = ReaderFontSize(points: 16)
        let stepped = EPUBFontStepCalculator.step(from: start, delta: 3)
        #expect(stepped.points == 16 + 3 * EPUBFontStepCalculator.pointsPerStep)
    }

    @Test("Zero delta is a no-op returning the same size")
    func zeroDeltaNoOp() {
        let start = ReaderFontSize(points: 18)
        let stepped = EPUBFontStepCalculator.step(from: start, delta: 0)
        #expect(stepped.points == start.points)
    }

    @Test("Result is clamped to the upper bound")
    func clampsUpper() {
        let start = ReaderFontSize(points: ReaderFontSize.max)
        let stepped = EPUBFontStepCalculator.step(from: start, delta: 5)
        #expect(stepped.points == ReaderFontSize.max)
    }

    @Test("Result is clamped to the lower bound")
    func clampsLower() {
        let start = ReaderFontSize(points: ReaderFontSize.min)
        let stepped = EPUBFontStepCalculator.step(from: start, delta: -5)
        #expect(stepped.points == ReaderFontSize.min)
    }

    @Test("pointsPerStep preserves the historical 2pt step constant")
    func stepConstant() {
        #expect(EPUBFontStepCalculator.pointsPerStep == 2.0)
    }
}
