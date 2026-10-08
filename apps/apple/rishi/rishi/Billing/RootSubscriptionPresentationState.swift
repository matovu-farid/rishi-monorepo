import Foundation

/// Root's native sheet lifetime outlives the account's visible presentation.
/// Keep its original dismissal receipt until the native callback claims it.
struct RootSubscriptionPresentationState {
    struct Presentation: Identifiable {
        let id = UUID()
        let snapshot: CredentialSnapshot
    }

    struct DismissalReceipt: Equatable {
        let presentationID: UUID
        let lease: CredentialLease
        var confirmsPurchase = false
    }

    private(set) var active: Presentation?
    private(set) var nativeDismissalReceipt: DismissalReceipt?
    private(set) var pending: Presentation?
    private(set) var isPresented = false
    private(set) var showsConfirmation = false
    private var confirmationAdmission: DismissalReceipt?

    var pendingConfirmation: Bool {
        nativeDismissalReceipt?.confirmsPurchase == true
    }

    mutating func request(_ snapshot: CredentialSnapshot, authority: SessionCredentialAuthority) {
        _ = authority.performIfCurrent(snapshot.lease) {
            if isPresented, active?.snapshot.lease == snapshot.lease {
                return // Coalesce requests for the same requested/visible sheet.
            }
            if nativeDismissalReceipt != nil {
                pending = Presentation(snapshot: snapshot)
                isPresented = false
                return
            }
            admit(Presentation(snapshot: snapshot))
        }
    }

    mutating func setPresented(_ presented: Bool) {
        // A binding dismissal must retain the native callback's original owner.
        if !presented {
            isPresented = false
            if nativeDismissalReceipt == nil { active = nil }
        }
    }

    /// The native item content acknowledges its own immutable presentation.
    /// A request alone cannot require a native dismissal callback.
    mutating func presentationDidAppear(_ presented: Presentation, authority: SessionCredentialAuthority) {
        // Once recorded, appearance is idempotent: it cannot reopen a
        // closing cover or adopt another item's identity/confirmation.
        guard nativeDismissalReceipt == nil else { return }
        nativeDismissalReceipt = DismissalReceipt(presentationID: presented.id, lease: presented.snapshot.lease)
        guard active?.id == presented.id, isPresented,
              authority.isCurrent(presented.snapshot.lease) else {
            // An obsolete native item appeared after its request was retired.
            // Close that exact item and retain a newer staged request for its
            // eventual dismissal, rather than adopt the newer identity.
            if let active, active.id != presented.id { pending = active }
            active = nil
            isPresented = false
            nativeDismissalReceipt?.confirmsPurchase = false
            return
        }
    }

    /// Called under SubscriptionsView's original-lease authority admission.
    /// Only inspect local presentation identity here; never reenter that lock.
    mutating func purchaseCompleted(presentationID: UUID) {
        guard active?.id == presentationID,
              nativeDismissalReceipt?.presentationID == presentationID else { return }
        nativeDismissalReceipt?.confirmsPurchase = true
        isPresented = false
    }

    mutating func retireForAccountFence() {
        active = nil
        pending = nil
        isPresented = false
        showsConfirmation = false
        confirmationAdmission = nil
        // The native cover may still dismiss later. Retain just its original
        // ID/lease, without the outgoing session snapshot or confirmation.
        nativeDismissalReceipt?.confirmsPurchase = false
    }

    mutating func claimNativeDismissal(authority: SessionCredentialAuthority) -> DismissalReceipt? {
        guard var receipt = nativeDismissalReceipt else { return nil }
        receipt.confirmsPurchase = receipt.confirmsPurchase && active?.id == receipt.presentationID
        nativeDismissalReceipt = nil
        active = nil
        isPresented = false
        confirmationAdmission = receipt.confirmsPurchase ? receipt : nil
        let next = pending
        pending = nil
        if let next {
            _ = authority.performIfCurrent(next.snapshot.lease) { admit(next) }
        }
        return receipt
    }

    mutating func finishDismissal(_ receipt: DismissalReceipt, authority: SessionCredentialAuthority) {
        _ = authority.performIfCurrent(receipt.lease) {
            guard receipt.confirmsPurchase, confirmationAdmission == receipt,
                  active == nil, nativeDismissalReceipt == nil else { return }
            confirmationAdmission = nil
            showsConfirmation = true
        }
    }

    mutating func dismissConfirmation() { showsConfirmation = false }

    private mutating func admit(_ presentation: Presentation) {
        active = presentation
        isPresented = true
        showsConfirmation = false
        confirmationAdmission = nil
    }
}
