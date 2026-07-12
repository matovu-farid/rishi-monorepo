import Foundation
import RishiCore
import RishiReader

enum ReaderDocumentURL {
    static func url(for book: Book) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(book.fileURL)
    }
}

extension PDFReaderViewModel {
    @MainActor
    static func make(book: Book, userId: UserID, services: BootstrappedServices) -> PDFReaderViewModel {
        PDFReaderViewModel(book: book, userId: userId, documentURL: ReaderDocumentURL.url(for: book),
                           positionStore: services.positionStore)
    }
}

extension ReaderViewModel {
    @MainActor
    static func make(book: Book, userId: UserID, services: BootstrappedServices) -> ReaderViewModel {
        ReaderViewModel(book: book, userId: userId, documentURL: ReaderDocumentURL.url(for: book),
                            positionStore: services.positionStore)
    }
}
