import Foundation
import PDFKit

/// A private PDFKit document and immutable page-range cache for narration.
/// PDFKit and the cache are accessed together under one synchronous lock;
/// callers receive value ranges and tokenize after this method returns.
public final class PDFNarrationParagraphMap: @unchecked Sendable {
    private let lock = NSLock()
    private let document: PDFDocument?
    /// Keeps provider/security-scoped bytes available for all lazy PDF page
    /// access performed by narration.
    private let sourceLifetime: AnyObject?
    private let sourceEffects: (any BookSourceEffectAdmitting)?
    private let sourceAccessPermit: BookSourceAccessPermit?
    private var cache: [Int: CachedPage] = [:]

    private struct CachedPage {
        let text: String
        let result: PDFReadAloudParagraphs.ParagraphRangeResult
    }

    public init(
        documentURL: URL,
        sourceLifetime: AnyObject? = nil,
        sourceEffects: (any BookSourceEffectAdmitting)? = nil,
        sourceAccessPermit: BookSourceAccessPermit? = nil
    ) {
        let sourceAdmission: SourceEffectAdmission?
        do {
            sourceAdmission = try Self.admit(sourceEffects, permit: sourceAccessPermit)
        } catch {
            document = nil
            self.sourceLifetime = sourceLifetime
            self.sourceEffects = sourceEffects
            self.sourceAccessPermit = sourceAccessPermit
            return
        }
        defer { sourceAdmission?.release() }
        let loadedDocument = PDFDocument(url: documentURL)
        let validationAdmission: SourceEffectAdmission?
        do {
            validationAdmission = try Self.admit(sourceEffects, permit: sourceAccessPermit)
        } catch {
            document = nil
            self.sourceLifetime = sourceLifetime
            self.sourceEffects = sourceEffects
            self.sourceAccessPermit = sourceAccessPermit
            return
        }
        validationAdmission?.release()
        document = loadedDocument
        self.sourceLifetime = sourceLifetime
        self.sourceEffects = sourceEffects
        self.sourceAccessPermit = sourceAccessPermit
    }

    /// `page` is the 1-based page number from a Readium PDF locator.
    public func paragraphRanges(page: Int, pageText: String) -> PDFReadAloudParagraphs.ParagraphRangeResult {
        let admission: SourceEffectAdmission?
        do {
            admission = try sourceAdmission()
        } catch {
            return .unavailable
        }
        defer { admission?.release() }
        let result: PDFReadAloudParagraphs.ParagraphRangeResult = lock.withLock {
            guard page > 0, let document, let pdfPage = document.page(at: page - 1) else {
                return .unavailable
            }
            if let cached = cache[page], cached.text == pageText {
                return cached.result
            }
            guard pdfPage.string == pageText else { return .unavailable }
            let result = PDFReadAloudParagraphs.paragraphRanges(from: pdfPage, pageText: pageText)
            cache[page] = CachedPage(text: pageText, result: result)
            return result
        }
        let validationAdmission: SourceEffectAdmission?
        do {
            validationAdmission = try sourceAdmission()
        } catch {
            return .unavailable
        }
        validationAdmission?.release()
        return result
    }

    private func sourceAdmission() throws -> SourceEffectAdmission? {
        try Self.admit(sourceEffects, permit: sourceAccessPermit)
    }

    private static func admit(
        _ effects: (any BookSourceEffectAdmitting)?,
        permit: BookSourceAccessPermit?
    ) throws -> SourceEffectAdmission? {
        switch (effects, permit) {
        case (nil, nil): return nil
        case let (.some(effects), .some(permit)): return try effects.admit(permit)
        default: throw BookSourceAccessError.unknownSource
        }
    }
}
