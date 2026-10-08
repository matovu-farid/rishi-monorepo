import Foundation
import Testing
@testable import rishi

@MainActor
@Suite("Error observer presentation state")
struct ErrorObserverPresentationStateTests {
    @Test("a visible private error blocks presentation")
    func visiblePrivateErrorBlocks() {
        let state = ErrorObserverPresentationState()
        state.error = NSError(domain: "test", code: 1)

        #expect(state.isBlocking(customerError: nil, storeError: nil))
    }

    @Test("a dismissed alert remains blocked while restore is active")
    func dismissedAlertWithActiveRestoreBlocks() {
        let state = ErrorObserverPresentationState()
        state.error = NSError(domain: "test", code: 1)
        state.beginRestore()
        state.error = nil

        #expect(state.isBlocking(customerError: nil, storeError: nil))
    }

    @Test("restore result is published before activity ends")
    func restoreResultOutlivesRestoreActivity() {
        let state = ErrorObserverPresentationState()
        state.beginRestore()
        state.error = NSError(domain: "restore", code: 2)
        state.endRestore()

        #expect(state.activeRestoreCount == 0)
        #expect(state.isBlocking(customerError: nil, storeError: nil))
    }

    @Test("failed restore is represented by the blocking private error")
    func failedRestoreBlocksWithPublishedError() {
        let state = ErrorObserverPresentationState()
        state.beginRestore()
        state.error = NSError(domain: "RishiBilling", code: 1)
        state.endRestore()

        #expect(state.error != nil)
        #expect(state.isBlocking(customerError: nil, storeError: nil))
    }

    @Test("finishing one restore does not release another active restore")
    func overlappingRestoresAreCounted() {
        let state = ErrorObserverPresentationState()
        state.beginRestore()
        state.beginRestore()
        state.endRestore()

        #expect(state.activeRestoreCount == 1)
        #expect(state.isBlocking(customerError: nil, storeError: nil))

        state.endRestore()
        #expect(state.activeRestoreCount == 0)
        #expect(!state.isBlocking(customerError: nil, storeError: nil))
    }

    @Test("eligible source errors block before the change handler publishes them")
    func eligibleIncomingSourceErrorBlocksBeforeHandler() {
        let state = ErrorObserverPresentationState()

        #expect(state.isBlocking(
            customerError: .invalidTransaction,
            storeError: nil
        ))
        #expect(state.isBlocking(
            customerError: .entitlementSyncFailed,
            storeError: nil
        ))
        #expect(state.isBlocking(
            customerError: nil,
            storeError: .invalidTransaction
        ))
    }

    @Test("initial source errors are treated as handled on appearance")
    func initialErrorsDoNotPublishAnAlert() {
        let state = ErrorObserverPresentationState()
        state.initializeHandledErrors(
            customerError: .invalidTransaction,
            storeError: .invalidTransaction
        )

        #expect(state.error == nil)
        #expect(!state.isBlocking(
            customerError: .invalidTransaction,
            storeError: .invalidTransaction
        ))
    }

    @Test("reappearance initialization cannot consume a later customer error")
    func repeatedInitializationPreservesCustomerTransition() {
        let state = ErrorObserverPresentationState()
        state.initializeHandledErrors(customerError: nil, storeError: nil)

        #expect(state.isBlocking(customerError: .invalidTransaction, storeError: nil))
        state.initializeHandledErrors(
            customerError: .invalidTransaction,
            storeError: nil
        )

        #expect(state.isBlocking(customerError: .invalidTransaction, storeError: nil))
    }

    @Test("reappearance initialization cannot consume a later store error")
    func repeatedInitializationPreservesStoreTransition() {
        let state = ErrorObserverPresentationState()
        state.initializeHandledErrors(customerError: nil, storeError: nil)

        #expect(state.isBlocking(customerError: nil, storeError: .invalidTransaction))
        state.initializeHandledErrors(
            customerError: nil,
            storeError: .invalidTransaction
        )

        #expect(state.isBlocking(customerError: nil, storeError: .invalidTransaction))
    }

    @Test("nil transition allows the same eligible source error to recur")
    func nilThenSameErrorCanRecur() {
        let state = ErrorObserverPresentationState()
        state.initializeHandledErrors(customerError: .invalidTransaction, storeError: nil)
        state.recordHandledCustomerError(nil)

        #expect(state.isBlocking(customerError: .invalidTransaction, storeError: nil))
    }

    @Test("an ineligible source transition is recorded without blocking")
    func ineligibleTransitionDoesNotBlock() {
        let state = ErrorObserverPresentationState()
        state.recordHandledCustomerError(.failedToFetchPersistedData)

        #expect(!state.isBlocking(
            customerError: .failedToFetchPersistedData,
            storeError: nil
        ))
    }

    @Test("dismissing an already handled unchanged source error restores safety")
    func handledUnchangedErrorCanBeDismissed() {
        let state = ErrorObserverPresentationState()
        state.recordHandledCustomerError(.invalidTransaction)
        state.error = NSError(domain: "test", code: 1)
        state.error = nil

        #expect(!state.isBlocking(
            customerError: .invalidTransaction,
            storeError: nil
        ))
    }

    @Test("store source error becomes eligible again after an intervening nil")
    func storeErrorCanRecurAfterNil() {
        let state = ErrorObserverPresentationState()
        state.initializeHandledErrors(customerError: nil, storeError: .invalidTransaction)
        state.recordHandledStoreError(nil)

        #expect(state.isBlocking(customerError: nil, storeError: .invalidTransaction))
    }
}
