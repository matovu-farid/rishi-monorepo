import Foundation



extension PDFReaderViewModel {
    @MainActor
    static func make(
        book: Book,
        userId: UserID,
        positionStore: any PositionStore,
        syncEngine: SyncEngine,
        sourceLease: BookSourceLease,
        unpackedCache: EPUBUnpackedCache
    ) -> PDFReaderViewModel {
        PDFReaderViewModel(book: book, userId: userId, documentURL: sourceLease.url,
                           positionStore: positionStore,
                           sourceLifetime: sourceLease,
                           sourceAccessPermit: sourceLease.sourceAccessPermit,
                           sourceEffects: sourceLease.effectAuthority,
                           sourceInvalidationSignal: sourceLease.owner.invalidation,
                           onPositionChanged: { [syncEngine, sourceLease] bookId in
                               guard let admission = try? sourceLease.effectAuthority.admit(sourceLease.sourceAccessPermit) else { return }
                               defer { admission.release() }
                               await syncEngine.markPositionDirty(bookId)
                           })
    }
}

extension ReaderViewModel {
    @MainActor
    static func make(
        book: Book,
        userId: UserID,
        positionStore: any PositionStore,
        sourceLease: BookSourceLease,
        unpackedCache: EPUBUnpackedCache
    ) -> ReaderViewModel {
        ReaderViewModel(book: book, userId: userId, documentURL: sourceLease.url,
                        positionStore: positionStore,
                        sourceLifetime: sourceLease,
                        sourceAccessPermit: sourceLease.sourceAccessPermit,
                        sourceEffects: sourceLease.effectAuthority,
                        sourceInvalidationSignal: sourceLease.owner.invalidation,
                        loader: PublicationLoader(unpackedCache: unpackedCache, cachePolicy: sourceLease.cachePolicy))
    }
}
