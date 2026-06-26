

import Foundation
import PDFKit
import RishiReader


@MainActor
private final class PDFReadAloudIndexStore {
    var storage: [ObjectIdentifier: Int] = [:]
}

@MainActor
private let pdfReadAloudIndexStore = PDFReadAloudIndexStore()

extension PDFReaderViewModel {


    @MainActor
    public var currentReadAloudPassageIndex: Int? {
        get { pdfReadAloudIndexStore.storage[ObjectIdentifier(self)] }
        set {
            let key = ObjectIdentifier(self)
            if let newValue {
                pdfReadAloudIndexStore.storage[key] = newValue
            } else {
                pdfReadAloudIndexStore.storage.removeValue(forKey: key)
            }
            
            
            self.theme = self.theme
        }
    }


    public nonisolated func paragraphsForReadAloud(document: PDFDocument, currentPageIndex: Int) -> [String] {
        guard let page = document.page(at: currentPageIndex) else { return [] }
        
        
        
        return PDFReadAloudParagraphs.paragraphs(from: page)
    }
}
