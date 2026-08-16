import Testing
@testable import rishi

@Suite("Account change fencing")
@MainActor
struct AccountChangeTransactionTests {
    @Test("the generation fence is committed before the drain task")
    func beginsSynchronously() async throws {
        let dependencies = AppDependencies()
        let previousGeneration = dependencies.accountGeneration
        let transaction = try dependencies.beginAccountChange()
        #expect(transaction.expectedAccountGeneration == previousGeneration + 1)
        #expect(dependencies.accountGeneration == transaction.expectedAccountGeneration)
        await transaction.drain.value
    }
}
