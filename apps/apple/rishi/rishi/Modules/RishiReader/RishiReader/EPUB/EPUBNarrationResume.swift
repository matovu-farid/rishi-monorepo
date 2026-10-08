import Foundation
@preconcurrency import ReadiumShared

/// A target confirmed in the same iterator that a fresh synthesizer will use.
public struct EPUBNarrationResumePlan: @unchecked Sendable {
    public let startingHref: String
    public let selection: Locator.Text
    public let targetOrdinal: Int
}

public enum EPUBNarrationResumePlanner {
    @MainActor
    public static func prepare(publication: Publication, from locator: Locator) async throws -> EPUBNarrationResumePlan? {
        guard let iterator = publication.content(from: locator)?.iterator() else { return nil }
        return try await scan(from: locator) { try await iterator.next() }
    }

    /// Direct iterator access keeps errors finite: Readium's sequence helper
    /// retries failed iteration recursively, which is unsuitable for preflight.
    @MainActor
    static func scan(
        from locator: Locator, maximumElements: Int = 64, maximumTextBytes: Int = 256 * 1024,
        next: () async throws -> ContentElement?
    ) async throws -> EPUBNarrationResumePlan? {
        guard let highlight = locator.text.highlight, !highlight.isEmpty else { return nil }
        var textBytes = 0
        for ordinal in 0..<maximumElements {
            try Task.checkCancellation()
            let element: ContentElement?
            do { element = try await next() }
            catch is CancellationError { throw CancellationError() }
            catch { return nil }
            try Task.checkCancellation()
            guard let element, element.locator.href == locator.href else { return nil }
            textBytes += (element as? TextualContentElement)?.text?.utf8.count ?? 0
            guard textBytes <= maximumTextBytes else { return nil }
            if CustomTTSTokenizer.trimming(element, before: locator.text, requireContext: true) != nil {
                return EPUBNarrationResumePlan(startingHref: locator.href.string, selection: locator.text, targetOrdinal: ordinal)
            }
        }
        return nil
    }
}

/// Shared by all tokenizer closures returned by one Readium factory. Every
/// invocation counts, including elements without speech text.
public final class EPUBNarrationSelectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let plan: EPUBNarrationResumePlan?
    private let fallbackSelection: Locator.Text?
    private var ordinal = 0
    private var consumed = false

    public init(plan: EPUBNarrationResumePlan?, fallbackSelection: Locator.Text?) {
        self.plan = plan
        self.fallbackSelection = fallbackSelection
    }

    private func selectedContent(_ content: ContentElement) -> ContentElement? {
        lock.withLock {
            guard !consumed else { return content }
            defer { ordinal += 1 }
            if let plan {
                guard content.locator.href.string == plan.startingHref else {
                    consumed = true
                    return content
                }
                if ordinal < plan.targetOrdinal { return nil }
                consumed = true
                return CustomTTSTokenizer.trimming(content, before: plan.selection) ?? content
            }
            // No confirmed target means zero skips. Preserve best-effort trim
            // of the first actual text element, including final-resource EOF.
            guard content is TextContentElement else { return content }
            consumed = true
            guard let fallbackSelection else { return content }
            return CustomTTSTokenizer.trimming(content, before: fallbackSelection) ?? content
        }
    }

    public func tokenizer(defaultLanguage: Language?, granularity: CustomTTSTokenizer.Granularity = .paragraph) -> ContentTokenizer {
        let tokenizer = CustomTTSTokenizer.tokenize(defaultLanguage: defaultLanguage, granularity: granularity)
        return { [self] content in
            guard let selected = selectedContent(content) else { return [] }
            return try tokenizer(selected)
        }
    }
}
