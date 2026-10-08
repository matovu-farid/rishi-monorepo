import Foundation
import ReadiumShared

struct PDFNarrationCursor: Equatable, Sendable {
    let page: Int
    let ordinal: Int
}

struct PDFNarrationTarget: Sendable {
    let page: Int
    let ordinal: Int
    let paragraphStart: Int?
    let locator: Locator
}

/// Confines a read-only publication snapshot to detached PDF skip lookup.
/// The lookup does not mutate the manifest or close the publication; this
/// wrapper does not establish general thread safety for Readium objects.
final class PDFPublicationSendableBox: @unchecked Sendable {
    let publication: Publication
    /// Opaque lifetime retention only; detached work never calls this object.
    let sourceLifetime: AnyObject?
    init(_ publication: Publication, sourceLifetime: AnyObject? = nil) {
        self.publication = publication
        self.sourceLifetime = sourceLifetime
    }
}

/// Immutable inputs captured on the UI owner before detached content lookup.
struct PDFNarrationLookupInput: Sendable {
    let publicationBox: PDFPublicationSendableBox
    let documentURL: URL
    let baseLocator: Locator
    let sourceEffects: (any BookSourceEffectAdmitting)?
    let sourceAccessPermit: BookSourceAccessPermit?

    @MainActor
    init(
        publication: Publication,
        documentURL: URL,
        baseLocator: Locator,
        sourceLifetime: AnyObject? = nil,
        sourceEffects: (any BookSourceEffectAdmitting)? = nil,
        sourceAccessPermit: BookSourceAccessPermit? = nil
    ) {
        publicationBox = PDFPublicationSendableBox(publication, sourceLifetime: sourceLifetime)
        self.documentURL = documentURL
        self.baseLocator = baseLocator
        self.sourceEffects = sourceEffects
        self.sourceAccessPermit = sourceAccessPermit
    }
}

/// Resolves relative PDF narration targets without owning playback or navigation.
enum PDFNarrationTargetResolver {
    static func resolve(
        input: PDFNarrationLookupInput,
        cursor: PDFNarrationCursor,
        delta: Int
    ) async -> PDFNarrationTarget? {
        await Task.detached(priority: .userInitiated) {
            let publicationBox = input.publicationBox
            let documentURL = input.documentURL
            let base = input.baseLocator
            let sourceEffects = input.sourceEffects
            let sourceAccessPermit = input.sourceAccessPermit
            let publication = publicationBox.publication
            let paragraphMap = PDFNarrationParagraphMap(
                documentURL: documentURL,
                sourceLifetime: publicationBox.sourceLifetime,
                sourceEffects: sourceEffects,
                sourceAccessPermit: sourceAccessPermit
            )
            let tokenizer = CustomTTSTokenizer.tokenizePDF(
                defaultLanguage: publication.metadata.language,
                paragraphMap: paragraphMap
            )
            let pageLocator = base.copy(locations: {
                $0.fragments = ["page=\(cursor.page)"]
            })
            guard let content = publication.content(from: pageLocator) else { return nil }
            let iterator = content.iterator()
            guard let currentPageContent = try? await iterator.next(),
                  let tokenized = try? tokenizer(currentPageContent),
                  let currentText = tokenized.first as? TextContentElement else { return nil }
            let segments = currentText.segments
            let index = segments.firstIndex {
                $0.locator.locations.otherLocations[CustomTTSTokenizer.PDFLocatorMetadata.utteranceOrdinal]?.integer == cursor.ordinal
            }
            if let index {
                let adjacentIndex = index + delta
                if segments.indices.contains(adjacentIndex) {
                    let segment = segments[adjacentIndex]
                    let ordinal = segment.locator.locations.otherLocations[
                        CustomTTSTokenizer.PDFLocatorMetadata.utteranceOrdinal
                    ]?.integer ?? adjacentIndex
                    return PDFNarrationTarget(
                        page: cursor.page,
                        ordinal: ordinal,
                        paragraphStart: segment.locator.locations.otherLocations[
                            CustomTTSTokenizer.PDFLocatorMetadata.paragraphStartUTF16
                        ]?.integer,
                        locator: segment.locator
                    )
                }
            }

            while true {
                let adjacentPage = delta > 0
                    ? try? await iterator.next()
                    : try? await iterator.previous()
                guard let adjacentPage,
                      let adjacentElements = try? tokenizer(adjacentPage),
                      let adjacentText = adjacentElements.first as? TextContentElement else { return nil }
                guard !adjacentText.segments.isEmpty else { continue }
                let segment = delta > 0 ? adjacentText.segments[0] : adjacentText.segments[adjacentText.segments.count - 1]
                let page = segment.locator.locations.page ?? (cursor.page + delta)
                let ordinal = segment.locator.locations.otherLocations[
                    CustomTTSTokenizer.PDFLocatorMetadata.utteranceOrdinal
                ]?.integer ?? 0
                return PDFNarrationTarget(
                    page: page,
                    ordinal: ordinal,
                    paragraphStart: segment.locator.locations.otherLocations[
                        CustomTTSTokenizer.PDFLocatorMetadata.paragraphStartUTF16
                    ]?.integer,
                    locator: segment.locator
                )
            }
        }.value
    }
}
