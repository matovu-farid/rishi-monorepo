//
//  Purchase.swift
//  rishiTests
//
//  Created by Farid Matovu on 27/06/2026.
//

import Testing
import RishiBilling
import StoreKit

enum PurchaseTestError:Error {
    case NoProducts
}
struct Purchase {

    @Test func TestPurchase() async throws {

        // Arrange
        let store = await Store.shared
        await store.loadProducts()
        let products = await store.products
        guard let product = products.first else {
            throw PurchaseTestError.NoProducts
        }
    

        // Act
        let result = try await product.purchase()
      
      
        var isSuccess:Bool
        switch result{
            
        case .success(_):
            isSuccess = true
            
         default:
            isSuccess = false
        }
        // Assert
        #expect(isSuccess, "The purchase failed" )
    }

}
