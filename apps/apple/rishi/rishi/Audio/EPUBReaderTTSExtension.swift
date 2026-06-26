
import Foundation
import RishiReader


@MainActor
private final class EPUBReadAloudIndexStore {
    var storage: [ObjectIdentifier: Int] = [:]
}

@MainActor
private let epubReadAloudIndexStore = EPUBReadAloudIndexStore()

extension EPUBReaderViewModel {


    @MainActor
    public var currentReadAloudPassageIndex: Int? {
        get { epubReadAloudIndexStore.storage[ObjectIdentifier(self)] }
        set {
            let key = ObjectIdentifier(self)
            if let newValue {
                epubReadAloudIndexStore.storage[key] = newValue
            } else {
                epubReadAloudIndexStore.storage.removeValue(forKey: key)
            }
            
            self.theme = self.theme
        }
    }

    
    
    
    
    
    
    
}
