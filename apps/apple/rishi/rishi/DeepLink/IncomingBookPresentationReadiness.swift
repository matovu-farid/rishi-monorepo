import Foundation
import Observation

/// Per-window, fail-closed snapshot of every presentation owner that can cover
/// an incoming reader route.
@MainActor
@Observable
final class IncomingBookPresentationReadiness {
    enum Source: CaseIterable, Hashable, Sendable {
        case root
        case signedInView
        case signedInContent
        case libraryTab
        case libraryRoot
    }

    enum Blocker: String, CaseIterable, Hashable, Sendable {
        case authentication, onboarding, trial, workflow, subscription, positionAlert, incomingError
        case username, accountDeletion, accountError, identityMismatch
        case consent, conversation, voice, voiceError
        case libraryLoad, idleFirstBookPrompt, promptDismissal, promptImport, picker, settings
        case conversations, paywall, subscriptionConfirmation, readingSessions, sharedReader, importError
        case operation, selection, shareComposer, sharedReadingComposer, sharedReadingConfirmation
        case invitation, deleteConfirmation

        // Granular spellings let each mounted owner publish its whole blocker
        // set without collapsing independent lifecycle states into one bit.
        case signedOutOrLoading, recovery, onboardingPresentation, trialCover, trialClaim
        case workflowAlert, workflowToken, pendingInvitation, redemption
        case catalystSubscriptionSheet, pendingSubscriptionConfirmation, manageSubscriptionPresenter
        case catalystUsernameEditor, accountDeletionConfirmation, accountDeletionInProgress
        case unresolvedConsent, consentSheet, conversationSheet, voicePresenter
        case voiceFailure, firstBookPrompt, firstPromptImport, firstPromptReopen
        case documentPicker, subscriptionPresentation, subscriptionConfirmationAlert
        case sharedReadingSession, activeImport, activeDeletion, selectionMode
        case sharedReadingSwitchConfirmation, creatorInvitation
    }

    let sceneID: UUID
    private(set) var identity: LibraryAccountIdentity?
    private(set) var revision: UInt64 = 0
    private(set) var incomingReaderRoutePresented = false

    private var reports: [Source: Report] = [:]
    private var ownerTokens: [Source: UUID] = [:]

    @discardableResult
    func claimOwnership(of source: Source) -> UUID {
        let token = UUID()
        ownerTokens[source] = token
        reports.removeValue(forKey: source)
        if source == .libraryTab { incomingReaderRoutePresented = false }
        advanceRevision()
        return token
    }

    private struct Report {
        let identity: LibraryAccountIdentity?
        let blockers: Set<Blocker>
    }

    init(sceneID: UUID, identity: LibraryAccountIdentity?) {
        self.sceneID = sceneID
        self.identity = identity
    }

    func updateIdentity(_ identity: LibraryAccountIdentity?) {
        guard self.identity != identity else { return }
        self.identity = identity
        reports.removeAll()
        incomingReaderRoutePresented = false
        advanceRevision()
    }

    func report(_ source: Source, identity: LibraryAccountIdentity?, blockers: Set<Blocker>, owner: UUID? = nil) {
        if let activeOwner = ownerTokens[source], owner != activeOwner { return }
        if ownerTokens[source] == nil, owner != nil { return }
        guard identity == self.identity else {
            reports.removeValue(forKey: source)
            advanceRevision()
            return
        }
        reports[source] = Report(identity: identity, blockers: blockers)
        advanceRevision()
    }

    func withdraw(_ source: Source, owner: UUID? = nil) {
        if let activeOwner = ownerTokens[source], owner != activeOwner { return }
        if ownerTokens[source] == nil, owner != nil { return }
        reports.removeValue(forKey: source)
        if let owner {
            ownerTokens.removeValue(forKey: source)
            if source == .libraryTab { incomingReaderRoutePresented = false }
        }
        advanceRevision()
    }

    func setIncomingReaderRoutePresented(_ presented: Bool, owner: UUID?) {
        guard let owner, ownerTokens[.libraryTab] == owner else { return }
        guard incomingReaderRoutePresented != presented else { return }
        incomingReaderRoutePresented = presented
        advanceRevision()
    }

    func isReady(for identity: LibraryAccountIdentity) -> Bool {
        readiness(for: identity, allowingPrompt: false)
    }

    func isReadyForPreclaim(for identity: LibraryAccountIdentity) -> Bool {
        readiness(for: identity, allowingPrompt: true)
    }

    private func readiness(for identity: LibraryAccountIdentity, allowingPrompt: Bool) -> Bool {
        guard self.identity == identity, reports.count == Source.allCases.count else { return false }
        for source in Source.allCases {
            guard let report = reports[source], report.identity == identity else { return false }
            if report.blockers.isEmpty { continue }
            guard allowingPrompt,
                  source == .libraryTab,
                  report.blockers == [.idleFirstBookPrompt] else { return false }
        }
        return true
    }

    private func advanceRevision() {
        revision &+= 1
    }
}
