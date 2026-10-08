import Foundation

enum TrialRootPresentation: Equatable {
    case none
    case claimedTrialIntro(UUID)
    case other
}

struct TrialChildSafety: Equatable {
    var signedIn = false
    var consent = false
    var conversation = false
    var voice = false
    var libraryReady = false
    var libraryModal = false
    var firstBookFlowActive = false

    var isSafe: Bool {
        signedIn && consent && conversation && voice && libraryReady && libraryModal && !firstBookFlowActive
    }
}

struct TrialIntroPresentationSnapshot: Equatable {
    var hostID: UUID
    var identity: LibraryAccountIdentity?
    var revision: UInt64
    var hostActive: Bool
    var sceneActive: Bool
    var rootPathEmpty: Bool
    var sharedReaderAbsent: Bool
    var catalystReaderWindowsAbsent: Bool
    var rootPresentation: TrialRootPresentation
    var child: TrialChildSafety?
    var restoreActive: Bool
    var nativePresentationActive: Bool

    var permitsCheck: Bool {
        guard let identity, hostActive, sceneActive, rootPathEmpty, sharedReaderAbsent,
              catalystReaderWindowsAbsent, rootPresentation == .none,
              let child, child.isSafe, !restoreActive, !nativePresentationActive else { return false }
        return true
    }

    func permitsAppearance(claimID: UUID, identity expected: LibraryAccountIdentity, revision expectedRevision: UInt64) -> Bool {
        guard self.identity == expected, revision == expectedRevision,
              rootPresentation == .claimedTrialIntro(claimID) else { return false }
        var copy = self
        copy.rootPresentation = .none
        return copy.permitsCheck
    }
}

enum NoCardTrialPresentationPolicy {
    static func signedInSourceIsSafe(
        accountMatches: Bool,
        catalystModelAvailable: Bool = true,
        usernameEditorPresented: Bool = false,
        accountDeleteConfirmationPresented: Bool = false,
        accountDeleteErrorPresented: Bool = false
    ) -> Bool {
        accountMatches && catalystModelAvailable && !usernameEditorPresented
            && !accountDeleteConfirmationPresented && !accountDeleteErrorPresented
    }

    static func permitsCheck(_ snapshot: TrialIntroPresentationSnapshot) -> Bool {
        snapshot.permitsCheck
    }

    static func permitsAppearance(
        _ snapshot: TrialIntroPresentationSnapshot,
        claimID: UUID,
        identity: LibraryAccountIdentity,
        revision: UInt64
    ) -> Bool {
        snapshot.permitsAppearance(claimID: claimID, identity: identity, revision: revision)
    }

    static func rootPresentation(
        trialCoverPresented: Bool,
        trialClaimID: UUID?,
        competingPresentationActive: Bool
    ) -> TrialRootPresentation {
        if competingPresentationActive { return .other }
        guard trialCoverPresented else { return .none }
        guard let trialClaimID else { return .other }
        return .claimedTrialIntro(trialClaimID)
    }

    static func shouldRetryAfterSafetyRevisionChange(
        outcome: TrialIntroPresentationCoordinator.Outcome,
        attemptedRevision: UInt64,
        currentSnapshot: TrialIntroPresentationSnapshot?,
        hasPendingReadiness: Bool
    ) -> Bool {
        guard hasPendingReadiness,
              let currentSnapshot,
              currentSnapshot.permitsCheck,
              currentSnapshot.revision != attemptedRevision else { return false }
        return outcome == .factsChanged || outcome == .cancelled
    }

    static func shouldSettleAttempt(
        attemptIdentity: LibraryAccountIdentity,
        currentIdentity: LibraryAccountIdentity?,
        pendingReadyIdentity: LibraryAccountIdentity?
    ) -> Bool {
        currentIdentity == attemptIdentity && pendingReadyIdentity == attemptIdentity
    }

    static func isCurrentAttempt(completedAttemptID: UUID, activeAttemptID: UUID?) -> Bool {
        completedAttemptID == activeAttemptID
    }
}
